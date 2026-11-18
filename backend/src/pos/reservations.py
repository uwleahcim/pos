"""Reservations: the tables booked ahead.

A reservation is a name, how many they are, the day and the time they come, and a phone number, a note and
a table held for them when there is one. The book is read a day at a time, in the order of the times. A
reservation leaves the book's list by sitting down (`seat`, with its table and the check opened for it), by
being cancelled, or by not showing (`cancel`); one that left by mistake is put back (`back`). `arrive` marks
a party that is here and waits for its table.

A day is a day of service: it runs to `localtime.NIGHT_ENDS` the next morning, so a table booked for half
past midnight on Friday is in Friday's book. Today and later days can be booked and changed; a day that is
over is only read. The names, numbers and notes are kept for `KEEP_DAYS` after the day, so a no-show can be
called back, and are taken off after that; how many they were, when, and how it ended is kept.

A reservation is not a check and not a sale, and no money is taken for one. Sitting it down opens a table's
check the way a party walking in does, and that check is where everything that is sold is kept. Kept in
memory or in PostgreSQL.
"""

from __future__ import annotations

import os
import re
import threading
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta
from datetime import time as clock
from typing import Any

from . import localtime

# What somebody types about a party is tidied the way the waitlist tidies it, and refused in its words.
from .waitlist import MOST_GUESTS, NAME_MAX, ReadOnlyError, Refused, _line, _phone, _size

__all__ = ["Booking", "BookStore", "PgBookStore", "ReadOnlyError", "Refused", "Reservations"]

NOTE_MAX = 80
"""The most letters of the note on a reservation: a birthday, a high chair, the booth by the window."""
MOST_AHEAD_DAYS = 366
"""How far ahead a table can be booked."""
MOST_A_DAY = 200
"""The most reservations standing in one day's book."""
KEEP_DAYS = 30
"""How long after its day a reservation keeps its name, number and note."""
HOLD_MIN = 90
"""How long a booked table is counted as taken, from the time it is booked for: two reservations of one
table closer together than this are told about each other."""
SOON_MIN = 15
"""A reservation is `soon` from this many minutes before its time."""
LATE_MIN = 15
"""A reservation nobody sat down or marked is `late` from this many minutes after its time."""
WHYS: tuple[tuple[str, str], ...] = (("cancelled", "Cancelled"), ("no_show", "No-show"))
"""How a reservation ends without a table: it was called off, or nobody came."""
WHY_NAMES = dict(WHYS)

MINUTE_MS = 60_000
_TIME = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")


@dataclass(frozen=True)
class Booking:
    """One reservation."""

    booking_id: str
    name: str
    size: int
    at_ms: int  # the time the table is booked for
    phone: str = ""
    note: str = ""
    table: str = ""  # the table held for them, when one was picked
    table_label: str = ""
    made_ms: int = 0  # when it was written into the book
    by_id: str = ""
    by: str = ""
    arrived_ms: int | None = None  # when they came in, for a party that waits for its table
    seated_ms: int | None = None
    seated_table: str = ""  # where they sat down, which need not be the table held
    seated_label: str = ""
    order_id: str = ""
    ended_ms: int | None = None  # when it was cancelled or marked a no-show
    ended_why: str = ""
    ended_by: str = ""  # who sat them down or took them out of the book

    @property
    def status(self) -> str:
        if self.seated_ms is not None:
            return "seated"
        return self.ended_why if self.ended_ms is not None else "booked"

    @property
    def day(self) -> date:
        """The day of service it is for."""
        return localtime.service_day_of(self.at_ms)

    @property
    def time(self) -> str:
        """The time it is for on the restaurant's clock, as "18:30"."""
        return datetime.fromtimestamp(self.at_ms / 1000, localtime.zone()).strftime("%H:%M")

    def as_json(self) -> dict[str, Any]:
        return {
            "id": self.booking_id,
            "name": self.name,
            "size": self.size,
            "phone": self.phone,
            "note": self.note,
            "at_ms": self.at_ms,
            "day": self.day.isoformat(),
            "time": self.time,
            "table": self.table,
            "table_label": self.table_label,
            "made_ms": self.made_ms,
            "by": self.by,
            "status": self.status,
            "soon_ms": self.at_ms - SOON_MIN * MINUTE_MS,
            "late_ms": self.at_ms + LATE_MIN * MINUTE_MS,
            "arrived_ms": self.arrived_ms,
            "seated_ms": self.seated_ms,
            "seated_table": self.seated_table,
            "seated_label": self.seated_label,
            "order_id": self.order_id,
            "ended_ms": self.ended_ms,
            "ended_by": self.ended_by,
        }


class BookStore:
    """The reservations, in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._bookings: dict[str, Booking] = {}
        self._lock = threading.Lock()

    def put(self, booking: Booking) -> None:
        """Writes a reservation, new or changed."""
        with self._lock:
            self._bookings[booking.booking_id] = booking

    def get(self, booking_id: str) -> Booking | None:
        with self._lock:
            return self._bookings.get(booking_id)

    def between(self, from_ms: int, to_ms: int | None = None) -> list[Booking]:
        """The reservations for a time from `from_ms` up to `to_ms` (to the end of the book when None), in
        the order of their times; two for the same time stay in the order they were written."""
        with self._lock:
            found = [b for b in self._bookings.values() if b.at_ms >= from_ms and (to_ms is None or b.at_ms < to_ms)]
        return sorted(found, key=lambda b: b.at_ms)

    def forget(self, before_ms: int) -> None:
        """Takes the name, number and note off every reservation for a time before `before_ms`."""
        with self._lock:
            for booking_id, booking in self._bookings.items():
                if booking.at_ms < before_ms and (booking.name or booking.phone or booking.note):
                    self._bookings[booking_id] = replace(booking, name="", phone="", note="")


SCHEMA = """
CREATE TABLE IF NOT EXISTS reservation (
    seq          BIGSERIAL,
    booking_id   TEXT PRIMARY KEY,
    name         TEXT NOT NULL DEFAULT '',
    size         INTEGER NOT NULL,
    at_ms        BIGINT NOT NULL,
    phone        TEXT NOT NULL DEFAULT '',
    note         TEXT NOT NULL DEFAULT '',
    table_id     TEXT NOT NULL DEFAULT '',
    table_label  TEXT NOT NULL DEFAULT '',
    made_ms      BIGINT NOT NULL,
    by_id        TEXT NOT NULL DEFAULT '',
    by_name      TEXT NOT NULL DEFAULT '',
    arrived_ms   BIGINT,
    seated_ms    BIGINT,
    seated_table TEXT NOT NULL DEFAULT '',
    seated_label TEXT NOT NULL DEFAULT '',
    order_id     TEXT NOT NULL DEFAULT '',
    ended_ms     BIGINT,
    ended_why    TEXT NOT NULL DEFAULT '',
    ended_by     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS reservation_at ON reservation (at_ms);
"""

_COLUMNS = (
    "booking_id, name, size, at_ms, phone, note, table_id, table_label, made_ms, by_id, by_name, arrived_ms, "
    "seated_ms, seated_table, seated_label, order_id, ended_ms, ended_why, ended_by"
)
_CHANGING = (
    "name, size, at_ms, phone, note, table_id, table_label, arrived_ms, seated_ms, seated_table, seated_label, "
    "order_id, ended_ms, ended_why, ended_by"
).split(", ")


def _int(value: Any) -> int | None:
    return None if value is None else int(value)


def _booking_of(row: Sequence[Any]) -> Booking:
    return Booking(
        row[0],
        row[1],
        int(row[2]),
        int(row[3]),
        row[4],
        row[5],
        row[6],
        row[7],
        int(row[8]),
        row[9],
        row[10],
        _int(row[11]),
        _int(row[12]),
        row[13],
        row[14],
        row[15],
        _int(row[16]),
        row[17],
        row[18],
    )


class PgBookStore(BookStore):
    """The same calls, in PostgreSQL, so the book is there after a restart and on the hub that takes over."""

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

    def _write(self, sql: str, args: Sequence[Any]) -> None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                conn.execute(sql, args)
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def _read(self, sql: str, args: Sequence[Any]) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                return conn.execute(sql, args).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet

    def put(self, booking: Booking) -> None:
        self._write(
            f"INSERT INTO reservation ({_COLUMNS}) VALUES ({', '.join(['%s'] * 19)}) "
            "ON CONFLICT (booking_id) DO UPDATE SET "
            + ", ".join(f"{column} = EXCLUDED.{column}" for column in _CHANGING),
            (
                booking.booking_id,
                booking.name,
                booking.size,
                booking.at_ms,
                booking.phone,
                booking.note,
                booking.table,
                booking.table_label,
                booking.made_ms,
                booking.by_id,
                booking.by,
                booking.arrived_ms,
                booking.seated_ms,
                booking.seated_table,
                booking.seated_label,
                booking.order_id,
                booking.ended_ms,
                booking.ended_why,
                booking.ended_by,
            ),
        )

    def get(self, booking_id: str) -> Booking | None:
        rows = self._read(f"SELECT {_COLUMNS} FROM reservation WHERE booking_id = %s", (booking_id,))
        return _booking_of(rows[0]) if rows else None

    def between(self, from_ms: int, to_ms: int | None = None) -> list[Booking]:
        if to_ms is None:
            rows = self._read(f"SELECT {_COLUMNS} FROM reservation WHERE at_ms >= %s ORDER BY at_ms, seq", (from_ms,))
        else:
            rows = self._read(
                f"SELECT {_COLUMNS} FROM reservation WHERE at_ms >= %s AND at_ms < %s ORDER BY at_ms, seq",
                (from_ms, to_ms),
            )
        return [_booking_of(row) for row in rows]

    def forget(self, before_ms: int) -> None:
        self._write(
            "UPDATE reservation SET name = '', phone = '', note = '' "
            "WHERE at_ms < %s AND (name <> '' OR phone <> '' OR note <> '')",
            (before_ms,),
        )


def default_book_store() -> BookStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgBookStore(dsn) if dsn else BookStore()


def day_of(value: object) -> date:
    """A day as the screens name it: "2026-11-21"."""
    if isinstance(value, str):
        try:
            return date.fromisoformat(value.strip())
        except ValueError:
            pass
    raise Refused("bad_day", "The day is written like 2026-11-21.")


def _minute(value: object) -> int:
    """A time as the screens name it, "18:30", in minutes after midnight."""
    found = _TIME.match(value.strip()) if isinstance(value, str) else None
    if found is None:
        raise Refused("bad_time", "The time is written like 18:30.")
    return int(found.group(1)) * 60 + int(found.group(2))


def at_of(day: date, minute: int) -> int:
    """The moment a table is booked for: `minute` after midnight on the restaurant's clock, in `day`'s
    service. A time before the night ends is the small hours after that day's midnight."""
    at = datetime.combine(day, clock(minute // 60, minute % 60), localtime.zone())
    if at.time() < localtime.NIGHT_ENDS:
        at += timedelta(days=1)
    return int(at.timestamp() * 1000)


def day_words(day: date) -> str:
    """A day as a host says it: "Sat 21 Nov"."""
    return f"{day:%a} {day.day} {day:%b}"


class Reservations:
    """The rules of the reservation book, over a store."""

    def __init__(self, store: BookStore | None = None, *, now_ms: Callable[[], int] | None = None) -> None:
        self.store = store if store is not None else BookStore()
        self._now_ms = now_ms if now_ms is not None else lambda: int(time.time() * 1000)

    def now_ms(self) -> int:
        return self._now_ms()

    def today(self) -> date:
        """The day of service it is now."""
        return localtime.service_day_of(self.now_ms())

    def _of_day(self, day: date) -> list[Booking]:
        return self.store.between(*localtime.service_day(day))

    def _open(self, booking_id: str) -> Booking:
        """A reservation that can still be changed: one of today or a later day."""
        booking = self.store.get(booking_id)
        if booking is None:
            raise Refused("unknown_booking", "This reservation is not in the book.")
        if booking.day < self.today():
            raise Refused("day_over", f"This reservation was for {day_words(booking.day)}. That day is over.")
        return booking

    def _booked(self, booking_id: str) -> Booking:
        booking = self._open(booking_id)
        if booking.status != "booked":
            raise Refused("not_booked", f"{booking.name}'s reservation is not standing. Put it back first.")
        return booking

    def _when(self, day: object, at: object) -> int:
        """The moment a table is asked for, when the book takes it: today or a later day, a year ahead at
        most."""
        on = day_of(day)
        today = self.today()
        if on < today:
            raise Refused("past_day", "A table is booked for today or a later day.")
        if (on - today).days > MOST_AHEAD_DAYS:
            raise Refused("too_far", f"A table is booked {MOST_AHEAD_DAYS} days ahead at most.")
        return at_of(on, _minute(at))

    def _room(self, at_ms: int, but: str = "") -> None:
        """The day's book takes another reservation, or says it is full."""
        day = localtime.service_day_of(at_ms)
        standing = sum(1 for b in self._of_day(day) if b.status == "booked" and b.booking_id != but)
        if standing >= MOST_A_DAY:
            raise Refused("too_many", f"{day_words(day)} has {MOST_A_DAY} reservations already.")

    def add(
        self,
        name: object,
        size: object,
        day: object,
        at: object,
        *,
        phone: object = "",
        note: object = "",
        table: str = "",
        table_label: str = "",
        by_id: str,
        by: str,
    ) -> Booking:
        """A table is booked: `day` as "2026-11-21", `at` as "18:30" on the restaurant's clock."""
        now = self.now_ms()
        booking = Booking(
            uuid.uuid4().hex,
            _line(name, NAME_MAX, "The name", needed=True),
            _size(size),
            self._when(day, at),
            _phone(phone),
            _line(note, NOTE_MAX, "The note"),
            table[:80],
            (table_label or table)[:40],
            now,
            by_id,
            by,
        )
        self._room(booking.at_ms)
        # the names and numbers of the days long over are not kept
        self.store.forget(localtime.service_day(self.today() - timedelta(days=KEEP_DAYS))[0])
        self.store.put(booking)
        return booking

    def change(
        self,
        booking_id: str,
        name: object,
        size: object,
        day: object,
        at: object,
        *,
        phone: object = "",
        note: object = "",
        table: str = "",
        table_label: str = "",
    ) -> Booking:
        """A standing reservation is put right: its name, how many, the day and the time, its number, its
        note and the table held. A party that was marked as here is still here."""
        booking = self._booked(booking_id)
        changed = replace(
            booking,
            name=_line(name, NAME_MAX, "The name", needed=True),
            size=_size(size),
            at_ms=self._when(day, at),
            phone=_phone(phone),
            note=_line(note, NOTE_MAX, "The note"),
            table=table[:80],
            table_label=(table_label or table)[:40],
        )
        if changed.day != self.today():
            changed = replace(changed, arrived_ms=None)  # nobody is here for another day
        if changed != booking:
            if changed.day != booking.day:
                self._room(changed.at_ms, but=booking_id)
            self.store.put(changed)
        return changed

    def _today_only(self, booking: Booking, what: str) -> None:
        if booking.day != self.today():
            raise Refused("not_today", f"This reservation is for {day_words(booking.day)}. {what}")

    def arrive(self, booking_id: str, on: bool = True) -> Booking:
        """The party of a reservation of today came in and waits for its table (or did not after all). The
        first time counts."""
        booking = self._booked(booking_id)
        self._today_only(booking, "Nobody is here for it yet.")
        if on == (booking.arrived_ms is not None):
            return booking
        here = replace(booking, arrived_ms=self.now_ms() if on else None)
        self.store.put(here)
        return here

    def seat(self, booking_id: str, table: str, *, table_label: str = "", order_id: str = "", by: str = "") -> Booking:
        """The party of a reservation of today sits down at `table`; `order_id` is the check opened for it.
        One already sat is left as it is: the first table counts."""
        booking = self._open(booking_id)
        if booking.status == "seated":
            return booking
        if booking.status != "booked":
            raise Refused("not_booked", f"{booking.name}'s reservation was taken out of the book. Put it back first.")
        self._today_only(booking, "Change its day to seat the party now.")
        if not table:
            raise Refused("no_table", "Say which table they sit at.")
        seated = replace(
            booking,
            seated_ms=self.now_ms(),
            seated_table=table[:80],
            seated_label=(table_label or table)[:40],
            order_id=order_id[:80],
            ended_by=by,
        )
        self.store.put(seated)
        return seated

    def cancel(self, booking_id: str, why: object = "cancelled", *, by: str = "") -> Booking:
        """A reservation ends without a table: it was called off, or (today) nobody came."""
        if why not in WHY_NAMES:
            raise Refused("bad_why", "A reservation is cancelled, or the party did not show.")
        booking = self._open(booking_id)
        if booking.status == why:
            return booking
        if booking.status == "seated":
            raise Refused("not_booked", f"{booking.name} has a table already.")
        if why == "no_show":
            self._today_only(booking, "A party cannot be missed before its day.")
        ended = replace(booking, ended_ms=self.now_ms(), ended_why=str(why), ended_by=by)
        self.store.put(ended)
        return ended

    def back(self, booking_id: str) -> Booking:
        """A reservation that was seated, cancelled or marked a no-show stands in the book again, for the
        time it had. A check opened for it is not touched."""
        booking = self._open(booking_id)
        if booking.status == "booked":
            return booking
        self._room(booking.at_ms, but=booking_id)
        standing = replace(
            booking,
            seated_ms=None,
            seated_table="",
            seated_label="",
            order_id="",
            ended_ms=None,
            ended_why="",
            ended_by="",
        )
        self.store.put(standing)
        return standing

    @staticmethod
    def _clashes(booked: Sequence[Booking]) -> dict[str, Booking]:
        """For each standing reservation with a table held, the nearest other one that holds the same table
        within `HOLD_MIN` of it."""
        clashes: dict[str, Booking] = {}
        for booking in booked:
            if not booking.table:
                continue
            near = [
                other
                for other in booked
                if other.booking_id != booking.booking_id
                and other.table == booking.table
                and abs(other.at_ms - booking.at_ms) < HOLD_MIN * MINUTE_MS
            ]
            if near:
                clashes[booking.booking_id] = min(near, key=lambda other: abs(other.at_ms - booking.at_ms))
        return clashes

    def book(self, day: date | None = None, *, changed: Booking | None = None) -> dict[str, Any]:
        """A day's book (today's when `day` is None): the reservations still `booked`, in the order of their
        times, and the ones that ended `earlier` (sat down, cancelled, no-show; the last to end first), with
        the counts of each. `ahead` is every day from today on with a reservation standing, and how many.
        `changed` is the reservation a change was made to: it is answered as `booking`."""
        today = self.today()
        day = day if day is not None else today
        coming = self.store.between(localtime.service_day(today)[0])
        if day >= today:
            start, end = localtime.service_day(day)
            of_day = [b for b in coming if start <= b.at_ms < end]
        else:
            of_day = self._of_day(day)
        booked = [b for b in of_day if b.status == "booked"]
        earlier = sorted(
            (b for b in of_day if b.status != "booked"),
            key=lambda b: (b.seated_ms if b.seated_ms is not None else b.ended_ms) or 0,
            reverse=True,
        )
        clashes = self._clashes(booked)

        def out(booking: Booking) -> dict[str, Any]:
            clash = clashes.get(booking.booking_id)
            return {
                **booking.as_json(),
                "clash": None if clash is None else {"id": clash.booking_id, "name": clash.name, "at_ms": clash.at_ms},
            }

        ahead: dict[date, list[int]] = {}
        for booking in coming:
            if booking.status == "booked":
                count = ahead.setdefault(booking.day, [0, 0])
                count[0] += 1
                count[1] += booking.size
        return {
            "day": day.isoformat(),
            "today": today.isoformat(),
            "booked": [out(b) for b in booked],
            "earlier": [out(b) for b in earlier],
            "counts": {
                "booked": len(booked),
                "guests": sum(b.size for b in booked),
                "seated": sum(1 for b in earlier if b.status == "seated"),
                "cancelled": sum(1 for b in earlier if b.status == "cancelled"),
                "no_show": sum(1 for b in earlier if b.status == "no_show"),
            },
            "ahead": [
                {"day": on.isoformat(), "parties": count[0], "guests": count[1]} for on, count in sorted(ahead.items())
            ],
            "whys": [{"id": key, "name": name} for key, name in WHYS],
            "hold_minutes": HOLD_MIN,
            "most_guests": MOST_GUESTS,
            "most_ahead_days": MOST_AHEAD_DAYS,
            "name_max": NAME_MAX,
            "note_max": NOTE_MAX,
            **({} if changed is None else {"booking": out(changed)}),
        }
