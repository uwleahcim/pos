"""Per-location settings a manager changes from the app and every terminal reads. Phase 1 holds one set,
`quotes`: how many minutes each channel promises a takeout order (architecture section 12, "Quote times":
set by hand until kitchen pacing quotes them in phase 2) and which channels may pay at pickup instead of
before the kitchen sees the order (counter mode pays first).

Stored like staff preferences: in memory on a laptop, in PostgreSQL on every hub and in the cloud.
"""

from __future__ import annotations

import copy
import os
from collections.abc import Mapping
from typing import Any

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .sync.pgstore import ReadOnlyError

CHANNELS = ("counter", "phone", "online", "delivery", "catering")
DEFAULTS: dict[str, dict[str, Any]] = {
    "quotes": {
        "minutes": {"counter": 15, "phone": 20, "online": 25, "delivery": 45},
        "pay_at_pickup": ["phone"],
    }
}


def clean_quotes(data: Mapping[str, Any]) -> dict[str, Any]:
    """The quote settings as the app may set them, checked. Raises ValueError on a bad value."""
    minutes = data.get("minutes") or {}
    if not isinstance(minutes, Mapping):
        raise ValueError("minutes must map a channel to minutes")
    out: dict[str, Any] = {"minutes": {}, "pay_at_pickup": []}
    for channel, value in minutes.items():
        if channel not in CHANNELS:
            raise ValueError(f"unknown channel {channel!r}; one of {', '.join(CHANNELS)}")
        try:
            number = int(value)
        except (TypeError, ValueError) as err:
            raise ValueError(f"minutes for {channel} must be a whole number") from err
        if not 0 <= number <= 24 * 60:
            raise ValueError(f"minutes for {channel} must be between 0 and a day")
        out["minutes"][channel] = number
    pay = data.get("pay_at_pickup", [])
    if not isinstance(pay, list | tuple):
        raise ValueError("pay_at_pickup must list channels")
    for channel in pay:
        if channel not in CHANNELS:
            raise ValueError(f"unknown channel {channel!r} in pay_at_pickup")
    out["pay_at_pickup"] = sorted(set(pay))
    return out


def _merged(key: str, stored: Mapping[str, Any] | None) -> dict[str, Any]:
    """What is stored over the defaults, one level deep (a channel left out keeps its default minutes)."""
    out = copy.deepcopy(DEFAULTS.get(key, {}))
    for name, value in (stored or {}).items():
        if isinstance(value, Mapping) and isinstance(out.get(name), dict):
            out[name] = {**out[name], **value}
        else:
            out[name] = copy.deepcopy(value)
    return out


class SettingStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgSettingStore`."""

    def __init__(self) -> None:
        self._data: dict[str, dict[str, Any]] = {}

    def get(self, key: str) -> dict[str, Any]:
        return _merged(key, self._data.get(key))

    def put(self, key: str, data: Mapping[str, Any]) -> dict[str, Any]:
        """Stores the whole set for `key` (checked by the caller); returns it with defaults filled in."""
        self._data[key] = dict(data)
        return self.get(key)


SCHEMA = """
CREATE TABLE IF NOT EXISTS setting (
    key        TEXT PRIMARY KEY,
    data       JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


class PgSettingStore(SettingStore):
    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def get(self, key: str) -> dict[str, Any]:
        with self._pool.connection() as conn:
            row = conn.execute("SELECT data FROM setting WHERE key = %s", (key,)).fetchone()
        return _merged(key, row[0] if row else None)

    def put(self, key: str, data: Mapping[str, Any]) -> dict[str, Any]:
        try:
            with self._pool.connection() as conn:
                row = conn.execute(
                    """
                    INSERT INTO setting (key, data) VALUES (%s, %s)
                    ON CONFLICT (key) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
                    RETURNING data
                    """,
                    (key, Jsonb(dict(data))),
                ).fetchone()
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return _merged(key, row[0] if row else None)


def default_settings() -> SettingStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    return PgSettingStore(dsn) if dsn else SettingStore()
