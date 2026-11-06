"""Staff tags for hands-free sign-in: an NFC badge or card held to a reader at the terminal. The reader works
in keyboard mode (USB or Bluetooth, on a Mac, an iPad, an iPhone or an Android tablet alike) and types the
tag's id and Enter; the app sends the id here and the hub says whose it is, in the shape a PIN sign-in has.
The hub keeps only the id (upper-cased, without separators), never what is printed on the badge: a tag is
one person's at a time, and a person has one tag; a new one replaces the old.
"""

from __future__ import annotations

import os
import re
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .staff import Directory, SignIn

TAG_UID = re.compile(r"^[A-Z0-9]{4,64}$")
"""A tag's id as a reader types it: hex (NFC, `04A2B3C4D5E6F7`) or decimal (125 kHz cards), 4 to 64 characters."""


def clean_tag_uid(raw: Any) -> str:
    """The id as the hub keeps it: upper-cased, spaces, colons and dashes dropped. Raises ValueError otherwise."""
    uid = re.sub(r"[\s:\-]", "", str(raw or "")).upper()
    if not TAG_UID.match(uid):
        raise ValueError("a tag id is 4 to 64 letters or digits")
    return uid


@dataclass(frozen=True)
class StaffTag:
    staff_id: str
    uid: str
    device: str | None  # the screen whose reader enrolled it
    created_at: float  # epoch seconds

    def summary(self) -> dict[str, Any]:
        """What the back office shows: that there is a tag, and its last characters to tell badges apart."""
        return {"enrolled": True, "ends": self.uid[-4:], "updated_at": self.created_at}


NO_TAG: dict[str, Any] = {"enrolled": False, "ends": None, "updated_at": 0.0}


class TagTaken(Exception):
    """The tag is already another staff member's: a badge is never two people's."""

    def __init__(self, staff_id: str) -> None:
        super().__init__(f"tag belongs to {staff_id}")
        self.staff_id = staff_id


class TagStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgTagStore`."""

    def __init__(self) -> None:
        self._tags: dict[str, StaffTag] = {}  # by staff id

    def assign(self, staff_id: str, uid: str, *, device: str | None = None) -> StaffTag:
        """Makes the tag this person's, replacing the one they had. Raises TagTaken when it is someone else's."""
        owner = self.staff_for(uid)
        if owner is not None and owner != staff_id:
            raise TagTaken(owner)
        tag = StaffTag(staff_id, uid, device, time.time())
        self._tags[staff_id] = tag
        return tag

    def forget(self, staff_id: str) -> int:
        return 1 if self._tags.pop(staff_id, None) is not None else 0

    def staff_for(self, uid: str) -> str | None:
        for tag in self._tags.values():
            if tag.uid == uid:
                return tag.staff_id
        return None

    def for_staff(self, staff_id: str) -> StaffTag | None:
        return self._tags.get(staff_id)

    def all(self) -> dict[str, StaffTag]:
        return dict(self._tags)


SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_tag (
    staff_id   TEXT PRIMARY KEY,
    uid        TEXT NOT NULL UNIQUE,
    device     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


class PgTagStore(TagStore):
    """The tags in PostgreSQL, read in bulk and kept for a few seconds between sign-ins."""

    CACHE_SECONDS = 5.0

    def __init__(self, dsn: str, *, pool_size: int = 2, clock: Callable[[], float] = time.monotonic) -> None:
        from psycopg.rows import tuple_row
        from psycopg_pool import ConnectionPool

        super().__init__()
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        self._clock = clock
        self._read_at: float | None = None
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def _refresh(self, *, force: bool = False) -> None:
        now = self._clock()
        if not force and self._read_at is not None and now - self._read_at < self.CACHE_SECONDS:
            return
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT staff_id, uid, device, EXTRACT(EPOCH FROM created_at) FROM staff_tag"
            ).fetchall()
        self._tags = {r[0]: StaffTag(r[0], r[1], r[2], float(r[3])) for r in rows}
        self._read_at = now

    def assign(self, staff_id: str, uid: str, *, device: str | None = None) -> StaffTag:
        from psycopg import errors

        from ..sync.pgstore import ReadOnlyError

        self._refresh(force=True)
        owner = self.staff_for(uid)
        if owner is not None and owner != staff_id:
            raise TagTaken(owner)
        try:
            with self._pool.connection() as conn:
                conn.execute(
                    "INSERT INTO staff_tag (staff_id, uid, device, created_at) VALUES (%s, %s, %s, now()) "
                    "ON CONFLICT (staff_id) DO UPDATE SET uid = EXCLUDED.uid, device = EXCLUDED.device, "
                    "created_at = now()",
                    (staff_id, uid, device),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        except errors.UniqueViolation as err:  # assigned to someone else between the look and the write
            raise TagTaken(self.staff_for(uid) or "?") from err
        self._refresh(force=True)
        tag = self._tags.get(staff_id)
        assert tag is not None
        return tag

    def forget(self, staff_id: str) -> int:
        from psycopg import errors

        from ..sync.pgstore import ReadOnlyError

        try:
            with self._pool.connection() as conn:
                cur = conn.execute("DELETE FROM staff_tag WHERE staff_id = %s", (staff_id,))
                gone = cur.rowcount
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        self._refresh(force=True)
        return gone

    def staff_for(self, uid: str) -> str | None:
        self._refresh()
        return super().staff_for(uid)

    def for_staff(self, staff_id: str) -> StaffTag | None:
        self._refresh()
        return super().for_staff(staff_id)

    def all(self) -> dict[str, StaffTag]:
        self._refresh()
        return super().all()


def default_tag_store() -> TagStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    return PgTagStore(dsn) if dsn else TagStore()


def sign_in_by_tag(store: TagStore, directory: Directory, raw_uid: Any, *, device: str) -> SignIn | None:
    """Whose tag this is: enrolled in the store, else listed with the staff member (POS_STAFF). None when nobody's
    or not a tag id at all."""
    try:
        uid = clean_tag_uid(raw_uid)
    except ValueError:
        return None
    staff_id = store.staff_for(uid)
    if staff_id is not None:
        found = directory.sign_in(staff_id, "tag", device=device)
        if found is not None:
            return found
    return directory.by_tag(uid, device=device)
