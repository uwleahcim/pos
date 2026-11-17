"""The waste log: food that was made or bought and not sold.

The kitchen writes down a dish that was dropped, burnt, made wrong or thrown out at the end of the night:
what it was, how many, and why, with a reason from the location's own list (`settings.waste`). The hub
stamps the time and who wrote it. A manager reads the totals over a span of days: by day, by reason and by
dish.

An entry is words beside the orders. It is no check and no sale: nothing here reads, changes or takes
anything out of an order, a void, a comp or the sales, and nothing in the sales reads the waste. A dish a
guest was given free still goes on the check as a comp, with its reason and who approved it; a dish taken
off a check is still a void. The log only says what food was lost.

A dish is written with the price the menu had for it then (`each`), so the totals say what the waste would
have sold for. That is the menu's price, not what the food cost: the hub does not know the cost. Something
that is not a dish (a tray of rice, five pounds of chicken) is typed, and has no price.

An entry is never changed and never deleted. A mistaken one is struck out by the person who wrote it, the
same day, or by a manager: it stays readable, with who struck it and when, and counts in no total.
"""

from __future__ import annotations

import os
import threading
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from datetime import date, timedelta
from decimal import Decimal
from typing import Any

from . import localtime

NAME_MAX = 60
"""The most letters of what was wasted, when it is typed and not a dish of the menu."""
NOTE_MAX = 120
"""The most letters of the few words that may go with an entry."""
QTY_MAX = 999
"""The most of one thing in one entry."""
MOST_A_DAY = 500
"""The most entries one day of service takes: far past any kitchen's night, and the list stays readable."""
MAX_DAYS = 92
"""The longest span of days one report adds up: a quarter of a year."""


class Refused(Exception):
    """Something asked of the waste log that it does not do, with a word for the code and a sentence for the
    person."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReadOnlyError(RuntimeError):
    """The database is a standby: nothing can be written here until it is promoted."""


@dataclass(frozen=True)
class Wasted:
    """One entry of the waste log."""

    entry_id: str
    at_ms: int
    name: str  # the dish as the menu named it then ("General Tso's Chicken (Quart)"), or what was typed
    qty: int
    reason: str  # the reason's words as the location listed them then
    item: str | None = None  # the dish's code on the menu; None for something typed
    variant_id: str | None = None
    each: str | None = None  # the menu's price of one then; None for something typed or a dish with no price
    note: str = ""
    by_id: str = ""
    by: str = ""
    device: str = ""
    struck_ms: int | None = None  # when it was struck out; it stays readable
    struck_by: str = ""

    @property
    def value(self) -> Decimal | None:
        """What these would have sold for at the menu's price; None where there is no price."""
        return None if self.each is None else Decimal(self.each) * self.qty

    def as_json(self) -> dict[str, Any]:
        value = self.value
        return {
            "id": self.entry_id,
            "at_ms": self.at_ms,
            "day": localtime.service_day_of(self.at_ms).isoformat(),
            "name": self.name,
            "qty": self.qty,
            "reason": self.reason,
            "item": self.item,
            "variant_id": self.variant_id,
            "each": self.each,
            "value": None if value is None else str(value),
            "note": self.note,
            "by_id": self.by_id,
            "by": self.by,
            "struck_ms": self.struck_ms,
            "struck_by": self.struck_by,
        }


class WasteStore:
    """The entries in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._entries: list[Wasted] = []  # in the order they were written
        self._lock = threading.Lock()

    def put(self, entry: Wasted) -> None:
        """Writes an entry: a new one goes last, one already there (struck out now) keeps its place."""
        with self._lock:
            for at, old in enumerate(self._entries):
                if old.entry_id == entry.entry_id:
                    self._entries[at] = entry
                    return
            self._entries.append(entry)

    def entry(self, entry_id: str) -> Wasted | None:
        with self._lock:
            return next((e for e in self._entries if e.entry_id == entry_id), None)

    def between(self, since_ms: int, until_ms: int) -> list[Wasted]:
        """The entries written from `since_ms` up to, not at, `until_ms`, in the order they were written."""
        with self._lock:
            return [e for e in self._entries if since_ms <= e.at_ms < until_ms]


SCHEMA = """
CREATE TABLE IF NOT EXISTS waste_entry (
    seq        BIGSERIAL PRIMARY KEY,
    entry_id   TEXT NOT NULL UNIQUE,
    at_ms      BIGINT NOT NULL,
    name       TEXT NOT NULL,
    qty        INTEGER NOT NULL,
    reason     TEXT NOT NULL,
    item       TEXT,
    variant_id TEXT,
    each       TEXT,
    note       TEXT NOT NULL DEFAULT '',
    by_id      TEXT NOT NULL DEFAULT '',
    by_name    TEXT NOT NULL DEFAULT '',
    device     TEXT NOT NULL DEFAULT '',
    struck_ms  BIGINT,
    struck_by  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS waste_entry_written ON waste_entry (at_ms);
"""

_COLUMNS = (
    "entry_id, at_ms, name, qty, reason, item, variant_id, each, note, by_id, by_name, device, struck_ms, struck_by"
)


def _entry_of(row: Sequence[Any]) -> Wasted:
    return Wasted(
        row[0],
        int(row[1]),
        row[2],
        int(row[3]),
        row[4],
        row[5],
        row[6],
        row[7],
        row[8],
        row[9],
        row[10],
        row[11],
        None if row[12] is None else int(row[12]),
        row[13],
    )


class PgWasteStore(WasteStore):
    """The same calls, in PostgreSQL, so the log is there after a restart and on the hub that takes over."""

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

    def _read(self, sql: str, args: Sequence[Any]) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                return conn.execute(sql, args).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet

    def put(self, entry: Wasted) -> None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                conn.execute(
                    f"INSERT INTO waste_entry ({_COLUMNS}) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    "ON CONFLICT (entry_id) DO UPDATE "
                    "SET struck_ms = EXCLUDED.struck_ms, struck_by = EXCLUDED.struck_by",
                    (
                        entry.entry_id,
                        entry.at_ms,
                        entry.name,
                        entry.qty,
                        entry.reason,
                        entry.item,
                        entry.variant_id,
                        entry.each,
                        entry.note,
                        entry.by_id,
                        entry.by,
                        entry.device,
                        entry.struck_ms,
                        entry.struck_by,
                    ),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def entry(self, entry_id: str) -> Wasted | None:
        rows = self._read(f"SELECT {_COLUMNS} FROM waste_entry WHERE entry_id = %s", (entry_id,))
        return _entry_of(rows[0]) if rows else None

    def between(self, since_ms: int, until_ms: int) -> list[Wasted]:
        rows = self._read(
            f"SELECT {_COLUMNS} FROM waste_entry WHERE at_ms >= %s AND at_ms < %s ORDER BY at_ms, seq",
            (since_ms, until_ms),
        )
        return [_entry_of(row) for row in rows]


def default_waste_store() -> WasteStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgWasteStore(dsn) if dsn else WasteStore()


def _line(value: object, most: int, what: str, *, needed: bool) -> str:
    """A few words somebody typed, on one line: the spaces tidied, nothing that cannot be printed."""
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise Refused("bad_text", f"{what} is words.")
    text = " ".join("".join(ch if ch.isprintable() else " " for ch in value).split())
    if needed and not text:
        raise Refused("no_text", f"{what} is needed.")
    if len(text) > most:
        raise Refused("long_text", f"{what} is {len(text)} letters long. It can have {most} at most.")
    return text


def _money(value: Decimal | None) -> str | None:
    return None if value is None else str(value.quantize(Decimal("0.01")))


def _total(entries: Sequence[Wasted]) -> dict[str, Any]:
    """What a set of entries comes to: how many things, what they would have sold for, and how many of
    them have no price to add."""
    priced = [e.value for e in entries if e.value is not None]
    return {
        "entries": len(entries),
        "count": sum(e.qty for e in entries),
        "value": _money(sum(priced, Decimal(0))),
        "unpriced": sum(e.qty for e in entries if e.value is None),
    }


class WasteLog:
    """The rules of the waste log, over a store."""

    def __init__(self, store: WasteStore | None = None, *, now_ms: Callable[[], int] | None = None) -> None:
        self.store = store if store is not None else WasteStore()
        self._now_ms = now_ms if now_ms is not None else lambda: int(time.time() * 1000)

    def now_ms(self) -> int:
        return self._now_ms()

    def log(
        self,
        *,
        name: object,
        qty: object,
        reason: object,
        reasons: Sequence[str],
        note: object = "",
        item: str | None = None,
        variant_id: str | None = None,
        each: Decimal | None = None,
        by_id: str,
        by: str,
        device: str = "",
    ) -> Wasted:
        """Somebody writes down what was wasted. `reasons` is the location's list: the entry keeps the
        reason's words as they are listed now. The hub's clock stamps it."""
        what = _line(name, NAME_MAX, "What was wasted", needed=True)
        if isinstance(qty, bool) or not isinstance(qty, int) or qty < 1:
            raise Refused("bad_qty", "How many is a whole number, 1 or more.")
        if qty > QTY_MAX:
            raise Refused("bad_qty", f"At most {QTY_MAX} in one entry.")
        listed = {r.casefold(): r for r in reasons}
        why = listed.get(str(reason or "").strip().casefold()) if isinstance(reason, str) else None
        if why is None:
            raise Refused("bad_reason", "Pick a reason from the list.")
        words = _line(note, NOTE_MAX, "The note", needed=False)
        now = self.now_ms()
        day = localtime.service_day_of(now)
        if len(self.store.between(*localtime.service_day(day))) >= MOST_A_DAY:
            raise Refused("too_many", f"{MOST_A_DAY} entries are in today's log already.")
        entry = Wasted(
            uuid.uuid4().hex,
            now,
            what,
            qty,
            why,
            item,
            variant_id,
            _money(each) if each is not None and each > 0 else None,
            words,
            by_id,
            by,
            device[:120],
        )
        self.store.put(entry)
        return entry

    def strike(self, entry_id: str, *, by_id: str, by: str, manager: bool) -> Wasted:
        """Strikes an entry out: the person who wrote it, on the day they wrote it, or a manager any day. It
        stays in the log, readable, with who struck it and when."""
        entry = self.store.entry(entry_id)
        if entry is None:
            raise Refused("unknown_entry", "There is no such entry.")
        if entry.struck_ms is not None:
            return entry
        now = self.now_ms()
        if not manager:
            if entry.by_id != by_id:
                raise Refused(
                    "not_yours", f"{entry.by or 'Somebody else'} wrote this one. They or a manager take it out."
                )
            if localtime.service_day_of(entry.at_ms) != localtime.service_day_of(now):
                raise Refused("past", "This is from an earlier day. A manager takes it out.")
        struck = replace(entry, struck_ms=now, struck_by=by)
        self.store.put(struck)
        return struck

    def day(self, day: date | None = None) -> dict[str, Any]:
        """One day of service: its entries, the newest first, the struck ones among them, and what the rest
        come to. Without a day, the one that is running."""
        now = self.now_ms()
        day = day if day is not None else localtime.service_day_of(now)
        entries = self.store.between(*localtime.service_day(day))
        standing = [e for e in entries if e.struck_ms is None]
        return {
            "day": day.isoformat(),
            "today": day == localtime.service_day_of(now),
            "entries": [e.as_json() for e in reversed(entries)],
            "total": _total(standing),
            "now_ms": now,
        }

    def report(self, first: date, last: date) -> dict[str, Any]:
        """A span of days of service added up: by day, by reason and by dish, each with how many and what
        they would have sold for; the struck entries count nowhere and are only numbered (`struck`)."""
        if first > last:
            raise Refused("bad_span", "The first day is after the last.")
        if (last - first).days + 1 > MAX_DAYS:
            raise Refused("too_long", f"At most {MAX_DAYS} days at a time.")
        since, _ = localtime.service_day(first)
        _, until = localtime.service_day(last)
        entries = self.store.between(since, until)
        standing = [e for e in entries if e.struck_ms is None]

        def grouped(key: Callable[[Wasted], str]) -> dict[str, list[Wasted]]:
            groups: dict[str, list[Wasted]] = {}
            for entry in standing:
                groups.setdefault(key(entry), []).append(entry)
            return groups

        def most_first(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
            # what cost the most first; things with no price by how many
            return sorted(rows, key=lambda r: (-Decimal(r["value"]), -r["count"], r["name"].casefold()))

        by_day = grouped(lambda e: localtime.service_day_of(e.at_ms).isoformat())
        days = [(first + timedelta(days=n)).isoformat() for n in range((last - first).days + 1)]
        # a dish is one line whatever was typed in capitals or not; two sizes of a dish are two lines
        by_dish = grouped(lambda e: e.variant_id or f"typed:{e.name.casefold()}")
        return {
            "from": first.isoformat(),
            "to": last.isoformat(),
            "total": _total(standing),
            "struck": len(entries) - len(standing),
            "days": [{"day": d, **_total(by_day.get(d, []))} for d in days],
            "reasons": most_first([{"name": k, **_total(v)} for k, v in grouped(lambda e: e.reason).items()]),
            "dishes": most_first(
                [
                    {"name": v[-1].name, "item": v[-1].item, "typed": v[-1].item is None, **_total(v)}
                    for v in by_dish.values()
                ]
            ),
            "max_days": MAX_DAYS,
            "now_ms": self.now_ms(),
        }
