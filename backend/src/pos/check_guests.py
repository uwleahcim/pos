"""The guests of a check: who sat on which check, kept so the guest list can count them (docs/guest-list.md).

A guest is a phone number (`pos.customers`). Until this was kept, the guest list knew one guest of a check:
the number typed on it. A party the host seats from its reservation or from the waitlist left a number too,
and it sat down on a check; and when two tables are put together, the check that is emptied may carry a
number of its own. Each of those is a guest of the check they sit on, and is noted here:

- `reservation` and `waitlist`: the party the host seated on the check, by the id of its reservation or of
  its line of the waitlist, with the number and the name written there. It is noted when the party sits
  down, moved when its check is merged into another, and taken off when the party is put back in the book
  or on the list. A party that left no number is no guest of the list and is not noted.
- `check`: the number typed on a check that was merged into this one, by that check's id, so the guest of
  the emptied table is still a guest of the joined one.

The book keeps a reservation's name and number for thirty days and the waitlist a party's for a night; the
guest list reads a year. So what is noted here is kept longer than either, `KEEP_DAYS`, and no longer: it is
what the guest list counts a visit from, and nothing else reads it. It is on the hub only, it is on no
check, no bill and no kitchen ticket, and nothing sends it out. Whoever may read the guest list (`guests` in
the table of powers) reads what it comes to there; no other call hands a number out of it.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, replace
from typing import Any

from .guest_tags import NAME_MAX, clean_name

KEEP_DAYS = 400
"""How long a guest of a check is kept: the year the guest list reads, and a month to spare."""
SOURCES = ("reservation", "waitlist", "check")

_DAY_MS = 24 * 60 * 60 * 1000


@dataclass(frozen=True, slots=True)
class CheckGuest:
    """One guest of a check, beside the number typed on it."""

    source: str  # one of `SOURCES`
    source_id: str  # the reservation's id, the party's id, or the id of the check that was merged in
    order_id: str  # the check they sit on
    phone: str  # digits
    name: str
    at_ms: int  # when they sat down, or when their check was merged in


def guest_of(source: str, source_id: str, order_id: str, phone: str, name: object, at_ms: int) -> CheckGuest:
    """A guest as it may be kept: the name on one line and no longer than a line of the guest list."""
    return CheckGuest(source, source_id[:80], order_id[:80], phone[:40], clean_name(name)[:NAME_MAX], int(at_ms))


class CheckGuests:
    """Who sat on which check. In memory: tests and a laptop. Every hub and the cloud use `PgCheckGuests`."""

    def __init__(self) -> None:
        self._guests: dict[tuple[str, str], CheckGuest] = {}
        self._lock = threading.Lock()

    def put(self, guest: CheckGuest) -> None:
        """This party, or this merged check's number, sits on this check: noted, or noted afresh when it
        was noted before (a party sits on one check). What is older than `KEEP_DAYS` is let go."""
        with self._lock:
            self._guests[(guest.source, guest.source_id)] = guest
            before = guest.at_ms - KEEP_DAYS * _DAY_MS
            for key in [key for key, kept in self._guests.items() if kept.at_ms < before]:
                del self._guests[key]

    def drop(self, source: str, source_id: str) -> bool:
        """The party was put back in the book or on the list: it is no guest of a check. True when it was."""
        with self._lock:
            return self._guests.pop((source, source_id), None) is not None

    def follow(self, emptied: str, kept: str) -> int:
        """The check `emptied` was merged into `kept`: its guests sit on that one from now on. How many."""
        if not emptied or not kept or emptied == kept:
            return 0
        with self._lock:
            moved = [guest for guest in self._guests.values() if guest.order_id == emptied]
            for guest in moved:
                self._guests[(guest.source, guest.source_id)] = replace(guest, order_id=kept[:80])
            return len(moved)

    def on(self, order_ids: Iterable[str]) -> list[CheckGuest]:
        """The guests of these checks, the first to sit first."""
        wanted = set(order_ids)
        with self._lock:
            return _in_order(guest for guest in self._guests.values() if guest.order_id in wanted)

    def of_phone(self, phone: str) -> list[CheckGuest]:
        """Every check this number sat on, the first first."""
        with self._lock:
            return _in_order(guest for guest in self._guests.values() if guest.phone == phone)

    def since(self, at_ms: int) -> list[CheckGuest]:
        """Everybody who sat down on a check at or after `at_ms`, the first first."""
        with self._lock:
            return _in_order(guest for guest in self._guests.values() if guest.at_ms >= at_ms)


def _in_order(guests: Iterable[CheckGuest]) -> list[CheckGuest]:
    return sorted(guests, key=lambda guest: (guest.at_ms, guest.source, guest.source_id))


SCHEMA = """
CREATE TABLE IF NOT EXISTS check_guest (
    source    TEXT NOT NULL,
    source_id TEXT NOT NULL,
    order_id  TEXT NOT NULL,
    phone     TEXT NOT NULL,
    name      TEXT NOT NULL DEFAULT '',
    at_ms     BIGINT NOT NULL,
    PRIMARY KEY (source, source_id)
);
CREATE INDEX IF NOT EXISTS check_guest_order ON check_guest (order_id);
CREATE INDEX IF NOT EXISTS check_guest_phone ON check_guest (phone);
CREATE INDEX IF NOT EXISTS check_guest_at ON check_guest (at_ms);
"""

_COLUMNS = "source, source_id, order_id, phone, name, at_ms"


class ReadOnlyError(RuntimeError):
    """This database is a standby: the guests of a check are noted on the primary."""


class PgCheckGuests(CheckGuests):
    """The same calls, in PostgreSQL, so the guests are there after a restart and on the hub that takes over."""

    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        from psycopg.rows import tuple_row
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def _write(self, sql: str, args: Sequence[Any]) -> int:
        """One write, and how many rows it touched. On a hub that took over from one that ran before the
        guests were kept, the table is made first."""
        from psycopg import errors

        try:
            try:
                with self._pool.connection() as conn:
                    return conn.execute(sql, args).rowcount
            except errors.UndefinedTable:
                with self._pool.connection() as conn:
                    conn.execute(SCHEMA)
                    return conn.execute(sql, args).rowcount
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def _read(self, where: str, args: Sequence[Any]) -> list[CheckGuest]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute(
                    f"SELECT {_COLUMNS} FROM check_guest WHERE {where} ORDER BY at_ms, source, source_id", args
                ).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet
        return [CheckGuest(str(a), str(b), str(c), str(d), str(e), int(f)) for a, b, c, d, e, f in rows]

    def put(self, guest: CheckGuest) -> None:
        self._write(
            f"""
            INSERT INTO check_guest ({_COLUMNS}) VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (source, source_id) DO UPDATE
                SET order_id = EXCLUDED.order_id, phone = EXCLUDED.phone, name = EXCLUDED.name,
                    at_ms = EXCLUDED.at_ms
            """,
            (guest.source, guest.source_id, guest.order_id, guest.phone, guest.name, guest.at_ms),
        )
        self._write("DELETE FROM check_guest WHERE at_ms < %s", (guest.at_ms - KEEP_DAYS * _DAY_MS,))

    def drop(self, source: str, source_id: str) -> bool:
        return self._write("DELETE FROM check_guest WHERE source = %s AND source_id = %s", (source, source_id)) > 0

    def follow(self, emptied: str, kept: str) -> int:
        if not emptied or not kept or emptied == kept:
            return 0
        return self._write("UPDATE check_guest SET order_id = %s WHERE order_id = %s", (kept[:80], emptied))

    def on(self, order_ids: Iterable[str]) -> list[CheckGuest]:
        wanted = list(dict.fromkeys(order_ids))
        return self._read("order_id = ANY(%s)", (wanted,)) if wanted else []

    def of_phone(self, phone: str) -> list[CheckGuest]:
        return self._read("phone = %s", (phone,))

    def since(self, at_ms: int) -> list[CheckGuest]:
        return self._read("at_ms >= %s", (at_ms,))


def default_check_guests() -> CheckGuests:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgCheckGuests(dsn) if dsn else CheckGuests()
