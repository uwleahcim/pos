"""The push tokens the screens register: which device, which platform, a VoIP token (the phone in the app)
or a notification token (a desk-phone pick-up), and for a VoIP token the extension it wakes. Stored like the
location settings: in memory on a laptop, in PostgreSQL on the hubs and in the cloud.
"""

from __future__ import annotations

import re
import threading
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, replace
from typing import Any

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg_pool import ConnectionPool

from ..sync.pgstore import ReadOnlyError

PLATFORMS = ("ios", "android", "macos")
KINDS = ("voip", "alert")
TOKEN = re.compile(r"^[0-9a-f]{16,512}$")
"""A device token as Apple hands it out: bytes, written as lowercase hex."""


@dataclass(frozen=True)
class PushDevice:
    token: str
    device: str
    platform: str
    kind: str
    extension: str = ""
    env: str | None = None  # production | sandbox, once Apple has told; None until then
    seen_ms: int = 0


class PushDevices:
    """In memory: tests and a laptop. Every hub and the cloud use `PgPushDevices`."""

    def __init__(self, *, clock: Callable[[], float] = time.time) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._by_token: dict[str, PushDevice] = {}

    def put(self, device: PushDevice) -> PushDevice:
        """Registers (or refreshes) a token; a token moving to another device or extension follows it."""
        stamped = replace(device, seen_ms=int(self._clock() * 1000))
        with self._lock:
            old = self._by_token.get(device.token)
            if old is not None and stamped.env is None:
                stamped = replace(stamped, env=old.env)
            self._by_token[device.token] = stamped
        return stamped

    def remove(self, token: str) -> bool:
        with self._lock:
            return self._by_token.pop(token, None) is not None

    def set_env(self, token: str, env: str) -> None:
        """Apple answered on this environment: remembered, so the next push goes there first."""
        with self._lock:
            found = self._by_token.get(token)
            if found is not None and found.env != env:
                self._by_token[token] = replace(found, env=env)

    def all(self) -> list[PushDevice]:
        with self._lock:
            return sorted(self._by_token.values(), key=lambda d: (d.device.casefold(), d.kind, d.token))

    def for_extension(self, extension: str, kind: str = "voip") -> list[PushDevice]:
        return [d for d in self.all() if d.kind == kind and d.extension == extension]

    def for_device(self, device: str, kind: str = "alert") -> list[PushDevice]:
        wanted = device.casefold()
        return [d for d in self.all() if d.kind == kind and d.device.casefold() == wanted]

    def extensions(self, kind: str = "voip") -> set[str]:
        """The extensions some screen can be woken for."""
        return {d.extension for d in self.all() if d.kind == kind and d.extension}

    def counts(self) -> dict[str, int]:
        out = {kind: 0 for kind in KINDS}
        for d in self.all():
            out[d.kind] = out.get(d.kind, 0) + 1
        return out

    def listed(self) -> list[dict[str, Any]]:
        return [
            {
                "device": d.device,
                "platform": d.platform,
                "kind": d.kind,
                "extension": d.extension,
                "env": d.env,
                "token": d.token[:8] + "…",
                "seen_ms": d.seen_ms,
            }
            for d in self.all()
        ]


SCHEMA = """
CREATE TABLE IF NOT EXISTS push_device (
    token      TEXT PRIMARY KEY,
    device     TEXT NOT NULL,
    platform   TEXT NOT NULL,
    kind       TEXT NOT NULL,
    extension  TEXT NOT NULL DEFAULT '',
    env        TEXT,
    seen_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


class PgPushDevices(PushDevices):
    """The same calls in PostgreSQL, so both hubs (one the other's replica) know every screen's tokens."""

    def __init__(self, dsn: str, *, pool_size: int = 2, clock: Callable[[], float] = time.time) -> None:
        super().__init__(clock=clock)
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def put(self, device: PushDevice) -> PushDevice:
        try:
            with self._pool.connection() as conn:
                row = conn.execute(
                    """
                    INSERT INTO push_device (token, device, platform, kind, extension, env)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (token) DO UPDATE SET device = EXCLUDED.device, platform = EXCLUDED.platform,
                        kind = EXCLUDED.kind, extension = EXCLUDED.extension,
                        env = COALESCE(EXCLUDED.env, push_device.env), seen_at = now()
                    RETURNING env, (extract(epoch from seen_at) * 1000)::bigint
                    """,
                    (device.token, device.device, device.platform, device.kind, device.extension, device.env),
                ).fetchone()
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return replace(device, env=row[0], seen_ms=int(row[1])) if row else device

    def remove(self, token: str) -> bool:
        try:
            with self._pool.connection() as conn:
                return conn.execute("DELETE FROM push_device WHERE token = %s", (token,)).rowcount > 0
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def set_env(self, token: str, env: str) -> None:
        try:
            with self._pool.connection() as conn:
                conn.execute(
                    "UPDATE push_device SET env = %s WHERE token = %s AND env IS DISTINCT FROM %s", (env, token, env)
                )
        except errors.ReadOnlySqlTransaction:
            pass  # the standby learns it from the primary

    def all(self) -> list[PushDevice]:
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT token, device, platform, kind, extension, env, (extract(epoch from seen_at) * 1000)::bigint"
                " FROM push_device"
            ).fetchall()
        found = [PushDevice(r[0], r[1], r[2], r[3], r[4], r[5], int(r[6])) for r in rows]
        return sorted(found, key=lambda d: (d.device.casefold(), d.kind, d.token))


def clean_device(
    data: dict[str, Any], *, device_pattern: re.Pattern[str], extension_pattern: re.Pattern[str]
) -> PushDevice:
    """A registration as the app sends it, checked. Raises ValueError on a bad value."""
    token = str(data.get("token") or "").strip().lower()
    if not TOKEN.match(token):
        raise ValueError("token must be the device token in hex")
    device = str(data.get("device") or "").strip()
    if not device_pattern.match(device):
        raise ValueError(f"a device name is letters and digits, as the app shows it, not {device!r}")
    platform = str(data.get("platform") or "").strip().lower()
    if platform not in PLATFORMS:
        raise ValueError(f"platform must be one of {', '.join(PLATFORMS)}")
    kind = str(data.get("kind") or "").strip().lower()
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    extension = str(data.get("extension") or "").strip()
    if kind == "voip" and not extension:
        raise ValueError("a voip token needs the extension it wakes")
    if extension and not extension_pattern.match(extension):
        raise ValueError(f"an extension is digits or letters, not {extension!r}")
    return PushDevice(token, device, platform, kind, extension if kind == "voip" else "")


def default_push_devices() -> PushDevices:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    import os

    dsn = os.environ.get("DATABASE_URL")
    return PgPushDevices(dsn) if dsn else PushDevices()


def tokens_of(devices: Iterable[PushDevice]) -> list[str]:
    return [d.token for d in devices]
