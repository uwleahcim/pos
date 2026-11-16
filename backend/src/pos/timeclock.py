"""The time clock: who is on the clock and since when, their breaks, and a log of everything that touched it.

A person clocks in and out with their own PIN or tag, and starts and ends a break the same way. A shift is
what lies between a clock-in and a clock-out. Hours are never rewritten in silence: a manager's correction
changes the shift and adds an entry to the log that says who changed what, from what to what, and why, so
the hours on a pay stub can be traced back to the punches behind them. A shift taken off is kept, marked,
with its reason. A shift nobody ended is closed when the night's service is over (`localtime.NIGHT_ENDS`)
and marked for a manager to look at: the hub cannot know when the person really left.

The hub's clock is the only clock: a punch is stamped when it reaches the hub, never with a time a screen
sends, so a device with the wrong time (or a patient hand) cannot move a punch.
"""

from __future__ import annotations

import os
import threading
import time
import uuid
from collections.abc import Callable, Collection, Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from typing import Any

from . import localtime

PUNCHES = ("in", "out", "break_start", "break_end")
"""What a person does at the clock themselves. The log also has `auto_out` (the hub closed a shift nobody
ended) and a manager's `add`, `edit` and `remove`."""

EARLY = timedelta(hours=3)
"""Somebody who clocks in this close to the end of the night (the prep cook at half past three) is starting
the next day, not ending this one: their shift is closed the night after if they never end it."""

SHIFT_MAX_MS = 24 * 60 * 60 * 1000
"""Longer than anybody works: a correction that makes a shift longer than a day has the wrong date on it."""
BREAKS_MAX = 20
REASON_MAX = 200
SLACK_MS = 60_000
"""How far ahead of the hub's clock a manager's correction may reach: a minute, for a watch that runs fast."""
UNENDED_DAYS = 14
"""How long the clock keeps telling a person that their last shift was never ended, until a manager fixes it."""


class Refused(Exception):
    """The clock will not do this: `code` for a screen to act on, `message` for a person to read."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReadOnlyError(RuntimeError):
    """This database is a standby: the clock is kept on the primary."""


@dataclass(frozen=True)
class Break:
    start_ms: int
    end_ms: int | None = None

    def as_json(self) -> dict[str, Any]:
        return {"start_ms": self.start_ms, "end_ms": self.end_ms}


@dataclass(frozen=True)
class Shift:
    shift_id: str
    staff_id: str
    name: str
    role: str  # the job worked: the person's role when they clocked in
    in_ms: int
    out_ms: int | None = None
    breaks: tuple[Break, ...] = ()
    closed_by: str = ""  # nothing while it is open; then self | manager | system (nobody ended it)
    edited: bool = False  # a manager added it or corrected it
    removed: bool = False  # a manager took it off; kept, never counted

    @property
    def open(self) -> bool:
        return self.out_ms is None and not self.removed

    @property
    def on_break(self) -> bool:
        return self.open and bool(self.breaks) and self.breaks[-1].end_ms is None

    @property
    def unended(self) -> bool:
        """Nobody clocked out of it and no manager has put the real time on it yet."""
        return self.closed_by == "system" and not self.removed

    def span_ms(self, now_ms: int) -> int:
        return max(0, (self.out_ms if self.out_ms is not None else now_ms) - self.in_ms)

    def break_ms(self, now_ms: int) -> int:
        end = self.out_ms if self.out_ms is not None else now_ms
        return sum(max(0, (b.end_ms if b.end_ms is not None else end) - b.start_ms) for b in self.breaks)

    def worked_ms(self, now_ms: int, *, breaks_paid: bool) -> int:
        return self.span_ms(now_ms) - (0 if breaks_paid else self.break_ms(now_ms))

    def times(self) -> dict[str, Any]:
        """What a correction can change, as the log keeps it before and after."""
        return {"in_ms": self.in_ms, "out_ms": self.out_ms, "breaks": [b.as_json() for b in self.breaks]}

    def as_json(self, now_ms: int, *, breaks_paid: bool) -> dict[str, Any]:
        return {
            "shift_id": self.shift_id,
            "staff_id": self.staff_id,
            "name": self.name,
            "role": self.role,
            **self.times(),
            "state": "removed" if self.removed else "break" if self.on_break else "in" if self.open else "out",
            "closed_by": self.closed_by,
            "edited": self.edited,
            "removed": self.removed,
            "unended": self.unended,
            "span_ms": self.span_ms(now_ms),
            "break_ms": self.break_ms(now_ms),
            "worked_ms": self.worked_ms(now_ms, breaks_paid=breaks_paid),
        }


@dataclass(frozen=True)
class Entry:
    """One line of the log: what happened to a shift, when it was recorded, and who did it."""

    entry_id: str
    shift_id: str
    staff_id: str
    action: str  # in | out | break_start | break_end | auto_out | add | edit | remove
    at_ms: int
    by_id: str = ""  # the person themselves, a manager, or nobody for the hub
    by: str = ""
    device: str = ""
    reason: str = ""
    before: Mapping[str, Any] | None = None
    after: Mapping[str, Any] | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "entry_id": self.entry_id,
            "action": self.action,
            "at_ms": self.at_ms,
            "by_id": self.by_id,
            "by": self.by,
            "device": self.device,
            "reason": self.reason,
            "before": dict(self.before) if self.before is not None else None,
            "after": dict(self.after) if self.after is not None else None,
        }


def night_cutoff_ms(in_ms: int) -> int:
    """When a shift that began at `in_ms` is over for sure if nobody ended it: the next time the night ends
    (`localtime.NIGHT_ENDS`), or the one after for somebody who came in within `EARLY` of it."""
    began = datetime.fromtimestamp(in_ms / 1000, localtime.zone())
    end = localtime.night_end(began)
    if end - began < EARLY:
        end = localtime.night_end(end + timedelta(minutes=1))
    return int(end.timestamp() * 1000)


class ClockStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgClockStore`."""

    def __init__(self) -> None:
        self._shifts: dict[str, Shift] = {}
        self._log: list[Entry] = []
        self._lock = threading.RLock()

    def write(self, shift: Shift, entry: Entry) -> bool:
        """Keeps the shift as it now stands and adds the entry to the log, both or neither. False, with
        nothing written, when the log already has that entry (the same punch sent twice). Raises `Refused`
        when it would leave the person with two open shifts (two screens at the same moment)."""
        with self._lock:
            if any(e.entry_id == entry.entry_id for e in self._log):
                return False
            if shift.open and any(s.open and s.shift_id != shift.shift_id for s in self._of(shift.staff_id)):
                raise Refused("already_in", f"{shift.name} is already on the clock")
            self._shifts[shift.shift_id] = shift
            self._log.append(entry)
            return True

    def _of(self, staff_id: str) -> list[Shift]:
        return [s for s in self._shifts.values() if s.staff_id == staff_id]

    def shift(self, shift_id: str) -> Shift | None:
        with self._lock:
            return self._shifts.get(shift_id)

    def open_shifts(self) -> list[Shift]:
        with self._lock:
            return sorted((s for s in self._shifts.values() if s.open), key=lambda s: (s.in_ms, s.shift_id))

    def open_of(self, staff_id: str) -> Shift | None:
        with self._lock:
            return next((s for s in self._of(staff_id) if s.open), None)

    def began(self, since_ms: int, until_ms: int, *, staff_id: str | None = None) -> list[Shift]:
        """The shifts that began in `[since_ms, until_ms)`, the oldest first, the ones taken off included;
        one person's with `staff_id`."""
        with self._lock:
            found = [
                s
                for s in self._shifts.values()
                if since_ms <= s.in_ms < until_ms and (staff_id is None or s.staff_id == staff_id)
            ]
        return sorted(found, key=lambda s: (s.in_ms, s.shift_id))

    def log(self, shift_ids: Collection[str]) -> list[Entry]:
        """The log of these shifts, in the order it was written."""
        with self._lock:
            return [e for e in self._log if e.shift_id in shift_ids]

    def entry(self, entry_id: str) -> Entry | None:
        with self._lock:
            return next((e for e in self._log if e.entry_id == entry_id), None)


SCHEMA = """
CREATE TABLE IF NOT EXISTS clock_shift (
    shift_id  TEXT PRIMARY KEY,
    staff_id  TEXT NOT NULL,
    name      TEXT NOT NULL DEFAULT '',
    role      TEXT NOT NULL DEFAULT '',
    in_ms     BIGINT NOT NULL,
    out_ms    BIGINT,
    breaks    JSONB NOT NULL DEFAULT '[]'::jsonb,
    closed_by TEXT NOT NULL DEFAULT '',
    edited    BOOLEAN NOT NULL DEFAULT FALSE,
    removed   BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS clock_shift_began ON clock_shift (in_ms);
CREATE UNIQUE INDEX IF NOT EXISTS clock_shift_open ON clock_shift (staff_id) WHERE out_ms IS NULL AND NOT removed;
CREATE TABLE IF NOT EXISTS clock_log (
    seq      BIGSERIAL PRIMARY KEY,
    entry_id TEXT NOT NULL UNIQUE,
    shift_id TEXT NOT NULL,
    staff_id TEXT NOT NULL,
    action   TEXT NOT NULL,
    at_ms    BIGINT NOT NULL,
    by_id    TEXT NOT NULL DEFAULT '',
    by_name  TEXT NOT NULL DEFAULT '',
    device   TEXT NOT NULL DEFAULT '',
    reason   TEXT NOT NULL DEFAULT '',
    before   JSONB,
    after    JSONB
);
CREATE INDEX IF NOT EXISTS clock_log_shift ON clock_log (shift_id);
"""

_SHIFT = "shift_id, staff_id, name, role, in_ms, out_ms, breaks, closed_by, edited, removed"
_ENTRY = "entry_id, shift_id, staff_id, action, at_ms, by_id, by_name, device, reason, before, after"


def _shift_of(row: Sequence[Any]) -> Shift:
    breaks = tuple(Break(int(b["start_ms"]), None if b.get("end_ms") is None else int(b["end_ms"])) for b in row[6])
    out = None if row[5] is None else int(row[5])
    return Shift(row[0], row[1], row[2], row[3], int(row[4]), out, breaks, row[7], bool(row[8]), bool(row[9]))


def _entry_of(row: Sequence[Any]) -> Entry:
    return Entry(row[0], row[1], row[2], row[3], int(row[4]), row[5], row[6], row[7], row[8], row[9], row[10])


class PgClockStore(ClockStore):
    """The same calls, in PostgreSQL, so the clock is there after a restart and on the hub that takes over."""

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

    def write(self, shift: Shift, entry: Entry) -> bool:
        from psycopg import errors
        from psycopg.types.json import Jsonb

        def jsonb(value: Mapping[str, Any] | None) -> Jsonb | None:
            return None if value is None else Jsonb(dict(value))

        try:
            with self._pool.connection() as conn, conn.transaction():
                added = conn.execute(
                    f"INSERT INTO clock_log ({_ENTRY}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"
                    " ON CONFLICT (entry_id) DO NOTHING RETURNING seq",
                    (
                        entry.entry_id,
                        entry.shift_id,
                        entry.staff_id,
                        entry.action,
                        entry.at_ms,
                        entry.by_id,
                        entry.by,
                        entry.device,
                        entry.reason,
                        jsonb(entry.before),
                        jsonb(entry.after),
                    ),
                ).fetchone()
                if added is None:
                    return False
                conn.execute(
                    f"""
                    INSERT INTO clock_shift ({_SHIFT}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (shift_id) DO UPDATE SET
                        in_ms = EXCLUDED.in_ms, out_ms = EXCLUDED.out_ms, breaks = EXCLUDED.breaks,
                        closed_by = EXCLUDED.closed_by, edited = EXCLUDED.edited, removed = EXCLUDED.removed
                    """,
                    (
                        shift.shift_id,
                        shift.staff_id,
                        shift.name,
                        shift.role,
                        shift.in_ms,
                        shift.out_ms,
                        Jsonb([b.as_json() for b in shift.breaks]),
                        shift.closed_by,
                        shift.edited,
                        shift.removed,
                    ),
                )
        except errors.UniqueViolation as err:
            raise Refused("already_in", f"{shift.name} is already on the clock") from err
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return True

    def _shifts_where(self, where: str, args: Sequence[Any]) -> list[Shift]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute(
                    f"SELECT {_SHIFT} FROM clock_shift WHERE {where} ORDER BY in_ms, shift_id", args
                ).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet
        return [_shift_of(row) for row in rows]

    def shift(self, shift_id: str) -> Shift | None:
        return next(iter(self._shifts_where("shift_id = %s", (shift_id,))), None)

    def open_shifts(self) -> list[Shift]:
        return self._shifts_where("out_ms IS NULL AND NOT removed", ())

    def open_of(self, staff_id: str) -> Shift | None:
        return next(iter(self._shifts_where("staff_id = %s AND out_ms IS NULL AND NOT removed", (staff_id,))), None)

    def began(self, since_ms: int, until_ms: int, *, staff_id: str | None = None) -> list[Shift]:
        if staff_id is None:
            return self._shifts_where("in_ms >= %s AND in_ms < %s", (since_ms, until_ms))
        return self._shifts_where("in_ms >= %s AND in_ms < %s AND staff_id = %s", (since_ms, until_ms, staff_id))

    def _entries_where(self, where: str, args: Sequence[Any]) -> list[Entry]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute(f"SELECT {_ENTRY} FROM clock_log WHERE {where} ORDER BY seq", args).fetchall()
        except errors.UndefinedTable:
            return []
        return [_entry_of(row) for row in rows]

    def log(self, shift_ids: Collection[str]) -> list[Entry]:
        if not shift_ids:
            return []
        return self._entries_where("shift_id = ANY(%s)", (list(shift_ids),))

    def entry(self, entry_id: str) -> Entry | None:
        return next(iter(self._entries_where("entry_id = %s", (entry_id,))), None)


def default_clock_store() -> ClockStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgClockStore(dsn) if dsn else ClockStore()


def _reason(reason: object) -> str:
    said = " ".join(str(reason or "").split())
    if not said:
        raise Refused("reason_needed", "Say why: the log keeps it with the change")
    if len(said) > REASON_MAX:
        raise Refused("bad_reason", f"At most {REASON_MAX} letters for the reason")
    return said


def _ms(value: object, what: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise Refused("bad_time", f"{what} is not a time")
    return value


class TimeClock:
    """The clock's rules over a store: what a punch does, what a manager may correct, and the hours."""

    def __init__(self, store: ClockStore | None = None, *, now_ms: Callable[[], int] | None = None) -> None:
        self.store = store if store is not None else ClockStore()
        self._now = now_ms if now_ms is not None else (lambda: int(time.time() * 1000))

    def now_ms(self) -> int:
        return self._now()

    # --- closing what nobody ended -----------------------------------------------------------------------

    def sweep(self) -> list[Shift]:
        """Closes every shift still open after its night ended, at the hour the night ended, with a break
        left running ended there too. They are marked (`closed_by: system`) until a manager puts the real
        time on them. Called before anything is read, so no scheduler has to be awake at four in the morning."""
        now = self.now_ms()
        closed: list[Shift] = []
        for shift in self.store.open_shifts():
            cutoff = night_cutoff_ms(shift.in_ms)
            if now < cutoff:
                continue
            ended = self._close(shift, cutoff, "system")
            entry = Entry(
                f"auto:{shift.shift_id}", shift.shift_id, shift.staff_id, "auto_out", now, after=ended.times()
            )
            try:
                if self.store.write(ended, entry):
                    closed.append(ended)
            except ReadOnlyError:
                break  # a standby reads the clock as its primary left it
        return closed

    @staticmethod
    def _close(shift: Shift, at_ms: int, closed_by: str) -> Shift:
        breaks = shift.breaks
        if shift.on_break:
            breaks = (*breaks[:-1], replace(breaks[-1], end_ms=max(at_ms, breaks[-1].start_ms)))
        return replace(shift, out_ms=at_ms, breaks=breaks, closed_by=closed_by)

    # --- a person at the clock ---------------------------------------------------------------------------

    def state(self, staff_id: str, *, breaks_paid: bool = False, shift: Shift | None = None) -> dict[str, Any]:
        """Where a person stands: `out`, `in` or `break`, since when, and the shift they are on. `shift` is
        the one a punch just closed, so the answer to a clock-out can say what the shift came to. `unended`
        is their latest shift of the last `UNENDED_DAYS` days that nobody clocked out of and no manager has
        corrected yet: the clock tells them, so the manager hears of it before payday."""
        self.sweep()
        now = self.now_ms()
        current = self.store.open_of(staff_id)
        shown = current if current is not None else shift
        since = None
        if current is not None:
            since = current.breaks[-1].start_ms if current.on_break else current.in_ms
        recent = self.store.began(now - UNENDED_DAYS * 86_400_000, now + SLACK_MS, staff_id=staff_id)
        unended = next((s for s in reversed(recent) if s.unended), None)
        return {
            "state": "out" if current is None else "break" if current.on_break else "in",
            "since_ms": since,
            "now_ms": now,
            "shift": shown.as_json(now, breaks_paid=breaks_paid) if shown is not None else None,
            "unended": unended.as_json(now, breaks_paid=breaks_paid) if unended is not None else None,
        }

    def punch(
        self,
        staff_id: str,
        name: str,
        role: str,
        action: str,
        *,
        device: str = "",
        punch_id: str | None = None,
        breaks_paid: bool = False,
    ) -> dict[str, Any]:
        """One punch by the person themselves, stamped with the hub's clock. `punch_id` names the punch, so
        one sent twice (a retry on a bad network) counts once and is answered as done. Raises `Refused`
        when the punch does not fit where the person stands."""
        if action not in PUNCHES:
            raise Refused("bad_action", f"{action!r} is not something the clock does")
        self.sweep()
        entry_id = str(punch_id or uuid.uuid4())
        seen = self.store.entry(entry_id)
        if seen is not None:
            if seen.staff_id != staff_id or seen.action != action:
                raise Refused("bad_punch", "That punch was somebody else's")
            return {
                **self.state(staff_id, breaks_paid=breaks_paid, shift=self.store.shift(seen.shift_id)),
                "punched": action,
            }
        now = self.now_ms()
        current = self.store.open_of(staff_id)
        if action == "in":
            if current is not None:
                raise Refused("already_in", f"{name} is already on the clock")
            after = Shift(str(uuid.uuid4()), staff_id, name, role, now)
        else:
            if current is None:
                raise Refused("not_in", f"{name} is not on the clock")
            if action == "out":
                after = self._close(current, now, "self")
            elif action == "break_start":
                if current.on_break:
                    raise Refused("on_break", f"{name} is already on a break")
                if len(current.breaks) >= BREAKS_MAX:
                    raise Refused("too_many_breaks", f"At most {BREAKS_MAX} breaks in a shift")
                after = replace(current, breaks=(*current.breaks, Break(now)))
            else:
                if not current.on_break:
                    raise Refused("not_on_break", f"{name} is not on a break")
                last = current.breaks[-1]
                after = replace(current, breaks=(*current.breaks[:-1], replace(last, end_ms=max(now, last.start_ms))))
        entry = Entry(entry_id, after.shift_id, staff_id, action, now, staff_id, name, device)
        self.store.write(after, entry)
        return {**self.state(staff_id, breaks_paid=breaks_paid, shift=after), "punched": action}

    # --- a manager's corrections -------------------------------------------------------------------------

    def _checked(
        self,
        staff_id: str,
        name: str,
        in_ms: object,
        out_ms: object,
        breaks: object,
        *,
        shift_id: str | None,
    ) -> tuple[int, int | None, tuple[Break, ...]]:
        """The times of a shift as a manager wants them, checked: in before out, nothing in the future, no
        longer than a day, every break inside the shift and after the one before, and no time the person
        already has on another shift."""
        now = self.now_ms()
        began = _ms(in_ms, "The clock-in")
        ended = None if out_ms is None else _ms(out_ms, "The clock-out")
        if began > now + SLACK_MS or (ended is not None and ended > now + SLACK_MS):
            raise Refused("in_the_future", "A shift cannot be in the future")
        if ended is not None and ended <= began:
            raise Refused("out_before_in", "The clock-out has to be after the clock-in")
        if (ended if ended is not None else now) - began > SHIFT_MAX_MS:
            raise Refused("too_long", "A shift is at most 24 hours: check the dates")
        if ended is None and now >= night_cutoff_ms(began):
            raise Refused("needs_out", "That night is over: the shift needs its clock-out")
        raw = breaks if breaks is not None else []
        if not isinstance(raw, list | tuple) or not all(isinstance(b, Mapping) for b in raw):
            raise Refused("bad_breaks", "Breaks are a list of start and end times")
        if len(raw) > BREAKS_MAX:
            raise Refused("too_many_breaks", f"At most {BREAKS_MAX} breaks in a shift")
        kept: list[Break] = []
        edge = began
        for i, b in enumerate(raw):
            start = _ms(b.get("start_ms"), "A break's start")
            end = None if b.get("end_ms") is None else _ms(b.get("end_ms"), "A break's end")
            if end is None and (ended is not None or i != len(raw) - 1):
                raise Refused("bad_breaks", "Only the last break of a shift still running can be without its end")
            if start < edge or (end is not None and end < start):
                raise Refused("bad_breaks", "Each break is inside the shift and after the one before it")
            if (end if end is not None else start) > (ended if ended is not None else now + SLACK_MS):
                raise Refused("bad_breaks", "Each break is inside the shift and after the one before it")
            kept.append(Break(start, end))
            edge = end if end is not None else start
        until = ended if ended is not None else now
        for other in self.store.began(began - 2 * SHIFT_MAX_MS, until + 1, staff_id=staff_id):
            if other.removed or other.shift_id == shift_id:
                continue
            if ended is None and other.open:
                raise Refused("already_in", f"{name} is already on the clock")
            other_end = other.out_ms if other.out_ms is not None else now
            if other.in_ms < until and began < other_end:
                raise Refused("overlaps", f"{name} already has a shift over that time")
        return began, ended, tuple(kept)

    def add(
        self,
        staff_id: str,
        name: str,
        role: str,
        *,
        in_ms: object,
        out_ms: object = None,
        breaks: object = None,
        reason: object,
        by_id: str,
        by: str,
        device: str = "",
    ) -> Shift:
        """A shift a manager writes in, for somebody who never clocked in. With no `out_ms` the person is on
        the clock from `in_ms` and clocks out themselves."""
        why = _reason(reason)
        self.sweep()
        began, ended, kept = self._checked(staff_id, name, in_ms, out_ms, breaks, shift_id=None)
        shift = Shift(
            str(uuid.uuid4()), staff_id, name, role, began, ended, kept, "manager" if ended is not None else "", True
        )
        entry = Entry(
            str(uuid.uuid4()),
            shift.shift_id,
            staff_id,
            "add",
            self.now_ms(),
            by_id,
            by,
            device,
            why,
            None,
            shift.times(),
        )
        self.store.write(shift, entry)
        return shift

    def edit(
        self,
        shift_id: str,
        *,
        in_ms: object,
        out_ms: object = None,
        breaks: object = None,
        reason: object,
        by_id: str,
        by: str,
        device: str = "",
    ) -> Shift:
        """A manager's correction: the shift's times as they should be, all of them. The log keeps what they
        were. A shift given no `out_ms` is running again, for somebody clocked out by mistake."""
        why = _reason(reason)
        self.sweep()
        was = self.store.shift(shift_id)
        if was is None or was.removed:
            raise Refused("unknown_shift", "No such shift")
        began, ended, kept = self._checked(was.staff_id, was.name, in_ms, out_ms, breaks, shift_id=shift_id)
        if (began, ended, kept) == (was.in_ms, was.out_ms, was.breaks) and not was.unended:
            # the same times on a shift nobody ended are a manager saying that the hub's guess was right
            raise Refused("no_change", "Nothing was changed")
        closed_by = (
            "" if ended is None else was.closed_by if ended == was.out_ms and was.closed_by != "system" else "manager"
        )
        now = replace(was, in_ms=began, out_ms=ended, breaks=kept, closed_by=closed_by, edited=True)
        entry = Entry(
            str(uuid.uuid4()),
            shift_id,
            was.staff_id,
            "edit",
            self.now_ms(),
            by_id,
            by,
            device,
            why,
            was.times(),
            now.times(),
        )
        self.store.write(now, entry)
        return now

    def remove(self, shift_id: str, *, reason: object, by_id: str, by: str, device: str = "") -> Shift:
        """A manager takes a shift off (a punch made by mistake). It is kept, marked, and counts for nothing."""
        why = _reason(reason)
        was = self.store.shift(shift_id)
        if was is None or was.removed:
            raise Refused("unknown_shift", "No such shift")
        gone = replace(was, removed=True, edited=True)
        if gone.out_ms is None:  # taken off while it ran: it ends where it is taken off
            gone = replace(self._close(was, max(self.now_ms(), was.in_ms), "manager"), removed=True, edited=True)
        entry = Entry(
            str(uuid.uuid4()),
            shift_id,
            was.staff_id,
            "remove",
            self.now_ms(),
            by_id,
            by,
            device,
            why,
            was.times(),
            None,
        )
        self.store.write(gone, entry)
        return gone

    # --- the hours -----------------------------------------------------------------------------------------

    def on_now(self, *, breaks_paid: bool = False) -> list[dict[str, Any]]:
        self.sweep()
        now = self.now_ms()
        return [s.as_json(now, breaks_paid=breaks_paid) for s in self.store.open_shifts()]

    def report(self, since_ms: int, until_ms: int, *, breaks_paid: bool = False) -> dict[str, Any]:
        """The shifts that began in `[since_ms, until_ms)`, each with its log, and what they come to for each
        person: time worked, time on breaks, how many shifts, and how many of them nobody ended
        (`unended`: their hours are counted to the hour the night ended, which is more than was worked, until
        a manager corrects them). A shift taken off is listed, marked, and counted nowhere. `on_now` is who is
        on the clock at this moment, whenever their shift began."""
        self.sweep()
        now = self.now_ms()
        shifts = self.store.began(since_ms, until_ms)
        log: dict[str, list[dict[str, Any]]] = {}
        for entry in self.store.log({s.shift_id for s in shifts}):
            log.setdefault(entry.shift_id, []).append(entry.as_json())
        people: dict[str, dict[str, Any]] = {}
        for shift in shifts:
            if shift.removed:
                continue
            person = people.setdefault(
                shift.staff_id,
                {
                    "staff_id": shift.staff_id,
                    "name": shift.name,
                    "role": shift.role,
                    "worked_ms": 0,
                    "break_ms": 0,
                    "shifts": 0,
                    "unended": 0,
                    "open": 0,
                },
            )
            person["name"], person["role"] = shift.name, shift.role  # as the latest shift has them
            person["worked_ms"] += shift.worked_ms(now, breaks_paid=breaks_paid)
            person["break_ms"] += shift.break_ms(now)
            person["shifts"] += 1
            person["unended"] += 1 if shift.unended else 0
            person["open"] += 1 if shift.open else 0
        listed = sorted(people.values(), key=lambda p: (str(p["name"]).casefold(), p["staff_id"]))
        return {
            "since_ms": since_ms,
            "until_ms": until_ms,
            "now_ms": now,
            "breaks_paid": breaks_paid,
            "on_now": [s.as_json(now, breaks_paid=breaks_paid) for s in self.store.open_shifts()],
            "people": listed,
            "worked_ms": sum(p["worked_ms"] for p in listed),
            "break_ms": sum(p["break_ms"] for p in listed),
            "unended": sum(p["unended"] for p in listed),
            "shifts": [{**s.as_json(now, breaks_paid=breaks_paid), "log": log.get(s.shift_id, [])} for s in shifts],
        }
