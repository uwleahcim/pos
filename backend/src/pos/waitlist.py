"""The waitlist: the parties waiting for a table.

A party is put on the list at the door with a name, how many they are, a phone number when they give one, and
the wait they were told (`quoted_minutes`). It waits in the order it came, and the screens colour its wait by
the time it was told: amber when that time is nearly up, red once it has passed. A party goes off the list by
sitting down (`seat`, with its table and the check opened for it) or by leaving (`leave`: it left, or nobody
answered when it was called). One that went off by mistake is put back where it stood (`back`).

The list is tonight's: what was added since the night began (`localtime.NIGHT_ENDS`). The names, numbers and
notes of earlier nights are taken off when a new night's first party is added; how many they were, how long
they waited and how it ended is kept, so the waits can be counted later.

A party is not a check and not a sale. Sitting it down opens a table's check the way a party walking in does,
and that check is where everything that is sold is kept. Kept in memory or in PostgreSQL.

**A suggested wait** (`suggestions`). What to tell the next party is worked out from how tonight's parties
waited: each place in line took so many minutes for the last parties that sat down, and so many parties are
in line now. Parties of about the same size are counted together (`SIZE_BANDS`), since they wait for the
same kind of table; where too few of a size have sat down, every size is. A party ahead that has already
waited longer than that says the wait is at least as long as theirs, where it is of the same size. It is
a suggestion for the screen to mark: the wait a party is told is still what the host taps.
"""

from __future__ import annotations

import os
import threading
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from typing import Any

from . import localtime

NAME_MAX = 24
"""The most letters of a party's name: what a host calls out."""
NOTE_MAX = 60
"""The most letters of the note on a party: a high chair, a booth, a birthday."""
PHONE_MAX = 24
PHONE_SHORTEST = 7
"""The fewest digits of a phone number that is one."""
MOST_GUESTS = 60
"""The largest party the list takes."""
MOST_QUOTE = 240
"""The longest wait a party can be told, in minutes."""
MOST_WAITING = 60
"""The most parties waiting at once."""
QUOTES = (5, 10, 15, 20, 30, 45, 60, 90)
"""The waits the screens offer as buttons, in minutes."""
AMBER_BEFORE_MIN = 5
"""A wait turns amber this many minutes before the time the party was told; it turns red at that time."""
SIZE_BANDS: tuple[tuple[int, int], ...] = ((1, 2), (3, 4), (5, 6), (7, MOST_GUESTS))
"""The sizes that wait for the same kind of table: a wait is suggested from the parties of its own band."""
SUGGEST_LAST = 6
"""A suggested wait goes by the last so many parties that sat down,"""
SUGGEST_WITHIN_MIN = 120
"""and only by the ones that sat down within so many minutes: the pace of lunch says nothing of dinner."""
SUGGEST_LIKE_NEEDS = 3
"""A band is counted on its own once so many of its parties have sat down."""
SUGGEST_NEEDS = 2
"""Short of that every size is counted together, and with fewer than this of any size nothing is suggested."""
WHYS: tuple[tuple[str, str], ...] = (("left", "Left"), ("no_show", "No-show"))
"""Why a party went off the list without a table: it left, or it was called and nobody came."""
WHY_NAMES = dict(WHYS)

MINUTE_MS = 60_000


class Refused(Exception):
    """Something asked of the waitlist that it does not do, with a word for the code and a sentence for the
    person."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReadOnlyError(RuntimeError):
    """The database is a standby: nothing can be written here until it is promoted."""


@dataclass(frozen=True)
class Party:
    """One party on the list."""

    party_id: str
    name: str
    size: int
    phone: str = ""
    quoted_min: int | None = None  # the wait they were told, from when they were added; None: no time was given
    note: str = ""
    at_ms: int = 0  # when they were put on the list
    by_id: str = ""
    by: str = ""
    called_ms: int | None = None  # when they were told their table is ready
    seated_ms: int | None = None
    table: str = ""
    table_label: str = ""
    order_id: str = ""
    left_ms: int | None = None
    left_why: str = ""
    ended_by: str = ""  # who sat them down or took them off

    @property
    def status(self) -> str:
        return "seated" if self.seated_ms is not None else "left" if self.left_ms is not None else "waiting"

    @property
    def ended_ms(self) -> int | None:
        """When they went off the list; None while they wait."""
        return self.seated_ms if self.seated_ms is not None else self.left_ms

    @property
    def due_ms(self) -> int | None:
        """When the wait they were told is up; None when no time was given."""
        return None if self.quoted_min is None else self.at_ms + self.quoted_min * MINUTE_MS

    def as_json(self) -> dict[str, Any]:
        due = self.due_ms
        ended = self.ended_ms
        return {
            "id": self.party_id,
            "name": self.name,
            "size": self.size,
            "phone": self.phone,
            "quoted_minutes": self.quoted_min,
            "note": self.note,
            "at_ms": self.at_ms,
            "by": self.by,
            "called_ms": self.called_ms,
            "status": self.status,
            "due_ms": due,
            "amber_ms": None if due is None else max(self.at_ms, due - AMBER_BEFORE_MIN * MINUTE_MS),
            "seated_ms": self.seated_ms,
            "table": self.table,
            "table_label": self.table_label,
            "order_id": self.order_id,
            "left_ms": self.left_ms,
            "left_why": self.left_why,
            "ended_by": self.ended_by,
            "waited_minutes": None if ended is None else max(0, (ended - self.at_ms) // MINUTE_MS),
        }


class WaitStore:
    """The parties, in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._parties: dict[str, Party] = {}
        self._lock = threading.Lock()

    def put(self, party: Party) -> None:
        """Writes a party, new or changed."""
        with self._lock:
            self._parties[party.party_id] = party

    def get(self, party_id: str) -> Party | None:
        with self._lock:
            return self._parties.get(party_id)

    def since(self, since_ms: int) -> list[Party]:
        """The parties put on the list at or after `since_ms`, in the order they came."""
        with self._lock:
            found = [p for p in self._parties.values() if p.at_ms >= since_ms]
        return sorted(found, key=lambda p: p.at_ms)  # two of the same moment stay as they were written

    def forget(self, before_ms: int) -> None:
        """Takes the name, number and note off every party put on the list before `before_ms`."""
        with self._lock:
            for party_id, party in self._parties.items():
                if party.at_ms < before_ms and (party.name or party.phone or party.note):
                    self._parties[party_id] = replace(party, name="", phone="", note="")


SCHEMA = """
CREATE TABLE IF NOT EXISTS waitlist_party (
    seq         BIGSERIAL,
    party_id    TEXT PRIMARY KEY,
    name        TEXT NOT NULL DEFAULT '',
    size        INTEGER NOT NULL,
    phone       TEXT NOT NULL DEFAULT '',
    quoted_min  INTEGER,
    note        TEXT NOT NULL DEFAULT '',
    at_ms       BIGINT NOT NULL,
    by_id       TEXT NOT NULL DEFAULT '',
    by_name     TEXT NOT NULL DEFAULT '',
    called_ms   BIGINT,
    seated_ms   BIGINT,
    table_id    TEXT NOT NULL DEFAULT '',
    table_label TEXT NOT NULL DEFAULT '',
    order_id    TEXT NOT NULL DEFAULT '',
    left_ms     BIGINT,
    left_why    TEXT NOT NULL DEFAULT '',
    ended_by    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS waitlist_party_added ON waitlist_party (at_ms);
"""

_COLUMNS = (
    "party_id, name, size, phone, quoted_min, note, at_ms, by_id, by_name, called_ms, seated_ms, table_id, "
    "table_label, order_id, left_ms, left_why, ended_by"
)


def _int(value: Any) -> int | None:
    return None if value is None else int(value)


def _party_of(row: Sequence[Any]) -> Party:
    return Party(
        row[0],
        row[1],
        int(row[2]),
        row[3],
        _int(row[4]),
        row[5],
        int(row[6]),
        row[7],
        row[8],
        _int(row[9]),
        _int(row[10]),
        row[11],
        row[12],
        row[13],
        _int(row[14]),
        row[15],
        row[16],
    )


class PgWaitStore(WaitStore):
    """The same calls, in PostgreSQL, so the list is there after a restart and on the hub that takes over."""

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

    def put(self, party: Party) -> None:
        self._write(
            f"INSERT INTO waitlist_party ({_COLUMNS}) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
            "ON CONFLICT (party_id) DO UPDATE SET name = EXCLUDED.name, size = EXCLUDED.size, "
            "phone = EXCLUDED.phone, quoted_min = EXCLUDED.quoted_min, note = EXCLUDED.note, "
            "called_ms = EXCLUDED.called_ms, seated_ms = EXCLUDED.seated_ms, table_id = EXCLUDED.table_id, "
            "table_label = EXCLUDED.table_label, order_id = EXCLUDED.order_id, left_ms = EXCLUDED.left_ms, "
            "left_why = EXCLUDED.left_why, ended_by = EXCLUDED.ended_by",
            (
                party.party_id,
                party.name,
                party.size,
                party.phone,
                party.quoted_min,
                party.note,
                party.at_ms,
                party.by_id,
                party.by,
                party.called_ms,
                party.seated_ms,
                party.table,
                party.table_label,
                party.order_id,
                party.left_ms,
                party.left_why,
                party.ended_by,
            ),
        )

    def get(self, party_id: str) -> Party | None:
        rows = self._read(f"SELECT {_COLUMNS} FROM waitlist_party WHERE party_id = %s", (party_id,))
        return _party_of(rows[0]) if rows else None

    def since(self, since_ms: int) -> list[Party]:
        rows = self._read(f"SELECT {_COLUMNS} FROM waitlist_party WHERE at_ms >= %s ORDER BY at_ms, seq", (since_ms,))
        return [_party_of(row) for row in rows]

    def forget(self, before_ms: int) -> None:
        self._write(
            "UPDATE waitlist_party SET name = '', phone = '', note = '' "
            "WHERE at_ms < %s AND (name <> '' OR phone <> '' OR note <> '')",
            (before_ms,),
        )


def _in_line(party: Party, at_ms: int) -> bool:
    """Whether a party that was on the list at `at_ms` still stood in line for a table then: not off the list
    yet, and not yet told its table is ready."""
    return (party.ended_ms is None or party.ended_ms > at_ms) and (party.called_ms is None or party.called_ms > at_ms)


def _suggested(parties: Sequence[Party], own: Sequence[Party], now_ms: int, needs: int) -> dict[str, Any] | None:
    """The wait to tell a party that joins `parties` (in the order they came) at `now_ms`, `own` being the
    ones of its own size among them; None where fewer than `needs` of `parties` sat down lately."""
    lately = now_ms - SUGGEST_WITHIN_MIN * MINUTE_MS
    sat = [(place, p) for place, p in enumerate(parties) if p.seated_ms is not None and p.seated_ms >= lately]
    sat = sorted(sat, key=lambda found: found[1].seated_ms or 0)[-SUGGEST_LAST:]
    if len(sat) < needs:
        return None
    waited = places = 0
    for place, party in sat:
        waited += max(0, (party.seated_ms or party.at_ms) - party.at_ms)
        places += 1 + sum(1 for earlier in parties[:place] if _in_line(earlier, party.at_ms))
    # `waited / places` is what one place in line took: a party with two ahead of it waited for three places
    ahead = [p for p in parties if p.status == "waiting" and p.called_ms is None]
    pace_ms = (len(ahead) + 1) * waited // places
    # a table for eight that will not come says nothing of a table for two: only its own size holds it up
    slowest = [max(0, now_ms - p.at_ms) for p in own if p.status == "waiting" and p.called_ms is None]
    longest_ms = max(slowest, default=0)
    about = max(1, -(-max(pace_ms, longest_ms) // MINUTE_MS))  # to the whole minute above
    return {
        "minutes": next((quote for quote in QUOTES if quote >= about), QUOTES[-1]),
        "about_minutes": about,
        "by": "pace" if pace_ms >= longest_ms else "longest",
        "ahead": len(ahead),
        "each_minutes": max(1, round(waited / places / MINUTE_MS)),
        "longest_minutes": longest_ms // MINUTE_MS if slowest else None,
        "seated": len(sat),
    }


def suggestions(parties: Sequence[Party], now_ms: int) -> list[dict[str, Any]]:
    """The wait to tell a party that comes at `now_ms`, for each band of sizes (`from` to `to` guests) that
    tonight's `parties` say enough about; a band they say too little about is left out.

    `minutes` is the wait to tell, one of the waits the screens offer: the first that is not under
    `about_minutes`, what it was worked out as (the longest of them where that is longer still). It is worked
    out `by` the `pace`: the parties in line `ahead` (waiting, and not yet told their table is ready) and the
    newcomer take a place each, and a place took `each_minutes` for the last `seated` parties that sat down.
    `like` says the parties counted are the band's own; false where too few of them have sat down and every
    size was counted, the ones ahead too. Or it is worked out `by` the `longest` wait among the band's own
    parties ahead, `longest_minutes` (null with none of them ahead), where that is more: whoever comes now
    sits after them."""
    line = sorted(parties, key=lambda p: p.at_ms)  # in the order they came; the same moment stays as it was
    out: list[dict[str, Any]] = []
    for low, high in SIZE_BANDS:
        own = [p for p in line if low <= p.size <= high]
        found = _suggested(own, own, now_ms, SUGGEST_LIKE_NEEDS)
        like = found is not None
        if found is None:
            found = _suggested(line, own, now_ms, SUGGEST_NEEDS)
        if found is not None:
            out.append({"from": low, "to": high, "like": like, **found})
    return out


def default_wait_store() -> WaitStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgWaitStore(dsn) if dsn else WaitStore()


def _line(value: object, most: int, what: str, *, needed: bool = False) -> str:
    """One line somebody typed, tidied: what cannot be printed and the runs of blanks taken out."""
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise Refused("bad_text", f"{what} is words.")
    text = " ".join("".join(ch if ch.isprintable() else " " for ch in value).split())
    if needed and not text:
        raise Refused("no_name", f"{what} cannot be left empty.")
    if len(text) > most:
        raise Refused("long_text", f"{what} is {len(text)} letters long. It can have {most} at most.")
    return text


def _phone(value: object) -> str:
    """A phone number as it was typed, or nothing. It needs enough digits to be one."""
    text = _line(value, PHONE_MAX, "The phone number")
    if not text:
        return ""
    digits = sum(ch.isdigit() for ch in text)
    if digits < PHONE_SHORTEST or any(not (ch.isdigit() or ch in " +-().") for ch in text):
        raise Refused("bad_phone", f"A phone number has {PHONE_SHORTEST} digits or more, or is left empty.")
    return text


def _size(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MOST_GUESTS:
        raise Refused("bad_size", f"A party is 1 to {MOST_GUESTS} guests.")
    return value


def _quote(value: object) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MOST_QUOTE:
        raise Refused("bad_quote", f"The wait told is 1 to {MOST_QUOTE} minutes, or none.")
    return value


class Waitlist:
    """The rules of the waitlist, over a store."""

    def __init__(self, store: WaitStore | None = None, *, now_ms: Callable[[], int] | None = None) -> None:
        self.store = store if store is not None else WaitStore()
        self._now_ms = now_ms if now_ms is not None else lambda: int(time.time() * 1000)

    def now_ms(self) -> int:
        return self._now_ms()

    @staticmethod
    def _night_began(now_ms: int) -> int:
        return localtime.service_day(localtime.service_day_of(now_ms))[0]

    def _tonight(self, now_ms: int) -> list[Party]:
        return self.store.since(self._night_began(now_ms))

    def _party(self, party_id: str, now_ms: int) -> Party:
        party = self.store.get(party_id)
        if party is None or party.at_ms < self._night_began(now_ms):
            raise Refused("unknown_party", "This party is not on tonight's list.")
        return party

    def _waiting(self, party_id: str, now_ms: int) -> Party:
        party = self._party(party_id, now_ms)
        if party.status != "waiting":
            raise Refused("not_waiting", f"{party.name} is off the list. Put them back first.")
        return party

    def add(
        self,
        name: object,
        size: object,
        *,
        phone: object = "",
        quoted_minutes: object = None,
        note: object = "",
        by_id: str,
        by: str,
    ) -> Party:
        """A party is put on the list, behind the ones already waiting. The hub's clock says when."""
        now = self.now_ms()
        party = Party(
            uuid.uuid4().hex,
            _line(name, NAME_MAX, "The name", needed=True),
            _size(size),
            _phone(phone),
            _quote(quoted_minutes),
            _line(note, NOTE_MAX, "The note"),
            now,
            by_id,
            by,
        )
        began = self._night_began(now)
        if sum(1 for p in self.store.since(began) if p.status == "waiting") >= MOST_WAITING:
            raise Refused("too_many", f"{MOST_WAITING} parties are waiting already.")
        self.store.forget(began)  # the names and numbers of the nights before are not kept
        self.store.put(party)
        return party

    def change(
        self,
        party_id: str,
        name: object,
        size: object,
        *,
        phone: object = "",
        quoted_minutes: object = None,
        note: object = "",
    ) -> Party:
        """What a waiting party told the host is put right: its name, how many, its number, the wait it was
        told (still counted from when it came) and its note. Its place on the list stays."""
        party = self._waiting(party_id, self.now_ms())
        changed = replace(
            party,
            name=_line(name, NAME_MAX, "The name", needed=True),
            size=_size(size),
            phone=_phone(phone),
            quoted_min=_quote(quoted_minutes),
            note=_line(note, NOTE_MAX, "The note"),
        )
        if changed != party:
            self.store.put(changed)
        return changed

    def call(self, party_id: str, on: bool = True) -> Party:
        """A waiting party was told its table is ready (or was not after all). The first time counts: calling
        again leaves when it was first called."""
        now = self.now_ms()
        party = self._waiting(party_id, now)
        if on == (party.called_ms is not None):
            return party
        called = replace(party, called_ms=now if on else None)
        self.store.put(called)
        return called

    def seat(self, party_id: str, table: str, *, table_label: str = "", order_id: str = "", by: str = "") -> Party:
        """A waiting party sits down at `table`; `order_id` is the check opened for it. One already sat is
        left as it is: the first table counts."""
        now = self.now_ms()
        party = self._party(party_id, now)
        if party.status == "seated":
            return party
        if party.status != "waiting":
            raise Refused("not_waiting", f"{party.name} was taken off the list. Put them back first.")
        if not table:
            raise Refused("no_table", "Say which table they sit at.")
        seated = replace(
            party,
            seated_ms=now,
            table=table[:80],
            table_label=(table_label or table)[:40],
            order_id=order_id[:80],
            ended_by=by,
        )
        self.store.put(seated)
        return seated

    def leave(self, party_id: str, why: object = "left", *, by: str = "") -> Party:
        """A waiting party goes off the list without a table: it left, or nobody answered when it was called."""
        now = self.now_ms()
        if why not in WHY_NAMES:
            raise Refused("bad_why", "A party left, or it did not show.")
        party = self._party(party_id, now)
        if party.status == "left":
            return party
        if party.status != "waiting":
            raise Refused("not_waiting", f"{party.name} has a table already.")
        left = replace(party, left_ms=now, left_why=str(why), ended_by=by)
        self.store.put(left)
        return left

    def back(self, party_id: str) -> Party:
        """A party that went off the list tonight is put back where it stood: its wait still counts from
        when it came. A check opened for it is not touched."""
        now = self.now_ms()
        party = self._party(party_id, now)
        if party.status == "waiting":
            return party
        if sum(1 for p in self._tonight(now) if p.status == "waiting") >= MOST_WAITING:
            raise Refused("too_many", f"{MOST_WAITING} parties are waiting already.")
        waiting = replace(
            party, seated_ms=None, table="", table_label="", order_id="", left_ms=None, left_why="", ended_by=""
        )
        self.store.put(waiting)
        return waiting

    def suggest(self) -> dict[str, Any]:
        """The wait to tell a party that comes now, by how many they are (`suggestions`), with the waits the
        screens offer. It is read off the clock, so it is asked when a party is added and not with the list."""
        now = self.now_ms()
        return {"suggest": suggestions(self._tonight(now), now), "quotes": list(QUOTES)}

    def tonight(self) -> dict[str, Any]:
        """Tonight's list: who is `waiting`, in the order they came, and who went off it `earlier` (the last
        to go first), with the counts of both."""
        now = self.now_ms()
        parties = self._tonight(now)
        waiting = [p for p in parties if p.status == "waiting"]
        earlier = sorted((p for p in parties if p.status != "waiting"), key=lambda p: p.ended_ms or 0, reverse=True)
        seated = [p for p in earlier if p.status == "seated"]
        waits = [(p.seated_ms or p.at_ms) - p.at_ms for p in seated]
        return {
            "waiting": [p.as_json() for p in waiting],
            "earlier": [p.as_json() for p in earlier],
            "counts": {
                "waiting": len(waiting),
                "guests": sum(p.size for p in waiting),
                "seated": len(seated),
                "left": len(earlier) - len(seated),
                "average_wait_minutes": round(sum(waits) / len(waits) / MINUTE_MS) if waits else None,
            },
            "quotes": list(QUOTES),
            "whys": [{"id": key, "name": name} for key, name in WHYS],
            "most": MOST_WAITING,
            "most_guests": MOST_GUESTS,
            "name_max": NAME_MAX,
            "note_max": NOTE_MAX,
        }
