"""The staff as a manager keeps them in the app: who is on the list, each one's role and PIN.

Until now the staff were a line in the hub's own file (`POS_STAFF` in `/opt/pos/.env`), changed in its
terminal and read when the hub starts. This module lets a manager add somebody, change a name, a role or a
PIN, and take somebody off, in the app (Location, Staff and PINs; docs/staff.md).

Whose list is in force (`StaffList.in_force`):

- **The hub's own**, as before, for as long as nothing was changed in the app: `POS_STAFF`, or the demo
  staff where the hub names nobody.
- **The app's**, from the first change on. That change takes the whole list over as it stands, with every
  PIN's salted hash, so nobody's PIN is typed again and none is read. From then on `POS_STAFF` is not read
  any more: the list is in the database, where the location's other hub finds it too.

What is kept of a person: an id that is never given twice, the name, the role, the PIN as a salted hash
(`pos.identity.staff.hash_pin`, as the hub always kept it in memory), who changed them last and when, and
where the PIN is from (`demo`, `hub` for the hub's file, `app`, `terminal` for `hubctl staff pin`).
Somebody taken off stays as a row without a PIN (`removed`): the history of what they did keeps their name,
and their id is nobody else's later.

The rules that keep a location from locking itself out, and one person from becoming another:

- A PIN is four digits, since the sign-in pad sends a PIN on its fourth, and it is one person's: a sign-in
  is a PIN and nothing else, so two people cannot have the same.
- The last manager or owner is neither taken off nor given another role (`last_manager`).
- Nobody takes themselves off or changes their own role (`yourself`): another manager does that.
- What touches an owner takes an owner (`owner_only`): changing one, taking one off, making one. A manager
  makes the first owner where there is none, and that may be themselves: the one change of their own role
  the list takes.

A PIN goes one way, into the hub. No answer, no log line and no refusal of this module carries one.
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg_pool import ConnectionPool

from ..sync.pgstore import ReadOnlyError
from .powers import ALWAYS, HANDED
from .staff import Staff

log = logging.getLogger(__name__)

ROLES = (*HANDED, "manager", "owner")
"""The roles a person can be given, in the order a screen offers them."""
PIN = re.compile(r"^[0-9]{4}$")
"""A PIN: four digits. The sign-in pad sends what was typed on the fourth, so a longer one could not be
typed there, and a shorter one is not sent."""
NAME_MOST = 40
STAFF_MOST = 200
"""The most people on one list. A sign-in tries the PIN against everybody's hash, one after the other."""
TERMINAL = "the hub's terminal"
"""Who a change is by when it was made with `hubctl`."""
_NUMBERED = re.compile(r"^s([0-9]{1,9})$")


class Refused(Exception):
    """A change the list does not take. `code`: `bad_value`, `pin_taken`, `name_taken`, `unknown_staff`,
    `last_manager`, `yourself`, `owner_only`, `not_allowed`, `full`. `message` says it in words, and never
    repeats a PIN."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Actor:
    """Who is changing the list: the manager whose session the call carries."""

    staff_id: str
    name: str


@dataclass(frozen=True)
class Member:
    """One person as the list keeps them."""

    staff_id: str
    name: str
    role: str
    pin_salt: str = ""
    pin_hash: str = ""
    removed: bool = False
    by: str = ""  # who changed them last, by name; nobody for somebody the hub's own file named
    at_ms: int = 0
    pin_from: str = "app"  # demo | hub | app | terminal
    pin_by: str = ""
    pin_at_ms: int = 0

    def staff(self) -> Staff:
        return Staff(self.staff_id, self.name, self.role, self.pin_salt, self.pin_hash)

    def __repr__(self) -> str:  # nothing a PIN could be worked out from ends up in a log by accident
        return f"Member({self.staff_id!r}, {self.name!r}, {self.role!r}, removed={self.removed})"


class StaffStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgStaffStore`."""

    def __init__(self) -> None:
        self._rows: dict[str, Member] = {}

    def all(self) -> list[Member]:
        """Everybody the app was ever told of, the ones taken off too, in the order they came."""
        return list(self._rows.values())

    def put(self, member: Member, *, taking_over: Sequence[Member] = ()) -> None:
        """Stores one person as they are now. `taking_over` are the people the hub's own file named, stored
        with them the first time: each only where the list does not hold that id yet."""
        for own in taking_over:
            self._rows.setdefault(own.staff_id, own)
        self._rows[member.staff_id] = member

    def mark(self) -> str:
        """Changes whenever a row does: how a hub notices what was changed on another one."""
        return ";".join(f"{m.staff_id}:{m.at_ms}:{int(m.removed)}:{m.role}:{m.name}" for m in self.all())


SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_member (
    staff_id   TEXT PRIMARY KEY,
    seq        BIGSERIAL,
    name       TEXT NOT NULL,
    role       TEXT NOT NULL,
    pin_salt   TEXT NOT NULL DEFAULT '',
    pin_hash   TEXT NOT NULL DEFAULT '',
    removed    BOOLEAN NOT NULL DEFAULT FALSE,
    by_name    TEXT NOT NULL DEFAULT '',
    at_ms      BIGINT NOT NULL DEFAULT 0,
    pin_from   TEXT NOT NULL DEFAULT 'app',
    pin_by     TEXT NOT NULL DEFAULT '',
    pin_at_ms  BIGINT NOT NULL DEFAULT 0
);
"""
_COLUMNS = "staff_id, name, role, pin_salt, pin_hash, removed, by_name, at_ms, pin_from, pin_by, pin_at_ms"


class PgStaffStore(StaffStore):
    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def all(self) -> list[Member]:
        try:
            with self._pool.connection() as conn:
                rows = conn.execute(f"SELECT {_COLUMNS} FROM staff_member ORDER BY seq").fetchall()  # noqa: S608
        except errors.UndefinedTable:  # a standby whose hub in charge is older than the list
            return []
        return [Member(r[0], r[1], r[2], r[3], r[4], bool(r[5]), r[6], int(r[7]), r[8], r[9], int(r[10])) for r in rows]

    def put(self, member: Member, *, taking_over: Sequence[Member] = ()) -> None:
        try:
            # one transaction: the list is taken over with the change that asked for it, or not at all
            with self._pool.connection() as conn:
                for own in taking_over:
                    conn.execute(
                        f"INSERT INTO staff_member ({_COLUMNS}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "  # noqa: S608
                        "ON CONFLICT (staff_id) DO NOTHING",
                        _values(own),
                    )
                conn.execute(
                    f"INSERT INTO staff_member ({_COLUMNS}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "  # noqa: S608
                    "ON CONFLICT (staff_id) DO UPDATE SET name = EXCLUDED.name, role = EXCLUDED.role, "
                    "pin_salt = EXCLUDED.pin_salt, pin_hash = EXCLUDED.pin_hash, removed = EXCLUDED.removed, "
                    "by_name = EXCLUDED.by_name, at_ms = EXCLUDED.at_ms, pin_from = EXCLUDED.pin_from, "
                    "pin_by = EXCLUDED.pin_by, pin_at_ms = EXCLUDED.pin_at_ms",
                    _values(member),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err


def _values(m: Member) -> tuple[object, ...]:
    return (
        m.staff_id,
        m.name,
        m.role,
        m.pin_salt,
        m.pin_hash,
        m.removed,
        m.by,
        m.at_ms,
        m.pin_from,
        m.pin_by,
        m.pin_at_ms,
    )


def default_staff_store() -> StaffStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    return PgStaffStore(dsn) if dsn else StaffStore()


def clean_name(raw: str) -> str:
    """A name as the list keeps it: one line, the spaces in it single. Raises `Refused` for none, for one
    too long for a button, and for one with anything in it that is not written."""
    if any(ord(letter) < 32 or ord(letter) == 127 for letter in raw):
        raise Refused("bad_value", "A name is one line of letters.")
    name = " ".join(raw.split())
    if not name:
        raise Refused("bad_value", "Everybody on the staff has a name.")
    if len(name) > NAME_MOST:
        raise Refused("bad_value", f"A name is {NAME_MOST} letters at most: it has to fit on a table.")
    return name


def clean_role(raw: str) -> str:
    if raw not in ROLES:
        raise Refused("bad_value", f"A role is one of: {', '.join(ROLES)}.")
    return raw


def clean_pin(raw: str) -> str:
    """A PIN as it may be set. The refusal says what a PIN is and never what was typed."""
    if not PIN.fullmatch(raw):
        raise Refused("bad_value", "A PIN is four digits.")
    return raw


class StaffList:
    """The staff of one location: the hub's own list until a manager changes anything in the app, and the
    app's from then on. `own` is what the hub's file gave (`pos.identity.staff.staff_from_env`) and `source`
    where that is from (`hub`, `demo`)."""

    def __init__(
        self,
        store: StaffStore | None = None,
        *,
        own: Sequence[Staff] = (),
        source: str = "hub",
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.store = store if store is not None else StaffStore()
        self._own = list(own)
        self._source = source
        self._now = now
        self._lock = threading.Lock()  # one change at a time: each is weighed against the list as it stands

    # --- reading ---------------------------------------------------------------------------------------------

    def _mine(self) -> list[Member]:
        """The hub's own people as the list would keep them."""
        return [Member(s.staff_id, s.name, s.role, s.pin_salt, s.pin_hash, pin_from=self._source) for s in self._own]

    def _read(self) -> tuple[list[Member], bool]:
        """Everybody, the ones taken off too, and whether that is the app's list."""
        rows = self.store.all()
        return (rows, True) if rows else (self._mine(), False)

    def source(self) -> str:
        """Where the list in force is from: `app`, or the hub's own (`hub`, `demo`)."""
        return "app" if self._read()[1] else self._source

    def members(self) -> list[Member]:
        """Everybody on the staff now, in the order they came."""
        return [m for m in self._read()[0] if not m.removed]

    def in_force(self) -> tuple[list[Staff], dict[str, str]]:
        """Who signs in, and who was on the staff once (id and name): what `Directory.use` takes."""
        everybody, kept = self._read()
        if not kept:
            return list(self._own), {}  # the hub's own people, exactly as it named them
        # a tag the hub's own list gave somebody stays theirs; the tags a manager hands out are kept elsewhere
        listed = {s.staff_id: s.tag_uid for s in self._own if s.tag_uid}
        return (
            [replace(m.staff(), tag_uid=listed.get(m.staff_id)) for m in everybody if not m.removed],
            {m.staff_id: m.name for m in everybody if m.removed},
        )

    def mark(self) -> str:
        return self.store.mark()

    # --- who may do what to whom -----------------------------------------------------------------------------

    @staticmethod
    def _acting(by: Actor | None, people: Sequence[Member]) -> Member | None:
        """The manager behind a change as the list has them now, or None for the hub's terminal. Raises
        `Refused` for somebody who is not on the list, or is no manager any more."""
        if by is None:
            return None
        acting = next((m for m in people if m.staff_id == by.staff_id), None)
        if acting is None or acting.role not in ALWAYS:
            raise Refused("not_allowed", "Only a manager or an owner changes the staff.")
        return acting

    @staticmethod
    def _owners(people: Sequence[Member]) -> bool:
        return any(m.role == "owner" for m in people)

    def may(self, by: Actor | None, member: Member) -> dict[str, object]:
        """What this manager may do to that person, for a screen to offer no more: `change` (the name, the
        PIN), `role`, `remove`, and `why` not (`owner_only`, `yourself`). For themselves `role` is only ever
        making themselves the owner, where the location has none."""
        people = self.members()
        acting = self._acting(by, people)
        if acting is not None and member.role == "owner" and acting.role != "owner":
            return {"change": False, "role": False, "remove": False, "why": "owner_only"}
        if acting is not None and acting.staff_id == member.staff_id:
            # their own role is another manager's to change, but for the first owner, who has to come from somewhere
            return {"change": True, "role": not self._owners(people), "remove": False, "why": "yourself"}
        return {"change": True, "role": True, "remove": True, "why": None}

    def roles_for(self, by: Actor | None) -> list[str]:
        """The roles this manager can give: all of them, but an owner's only for an owner, or where the
        location has none yet."""
        people = self.members()
        acting = self._acting(by, people)
        makes_owners = acting is None or acting.role == "owner" or not self._owners(people)
        return [role for role in ROLES if role != "owner" or makes_owners]

    # --- changing --------------------------------------------------------------------------------------------

    def add(self, name: str, role: str, pin: str, *, by: Actor | None) -> Member:
        """Somebody new, who signs in with that PIN from now on."""
        with self._lock:
            everybody, kept = self._read()
            people = [m for m in everybody if not m.removed]
            acting = self._acting(by, people)
            name, role = clean_name(name), clean_role(role)
            if role == "owner" and acting is not None and acting.role != "owner" and self._owners(people):
                raise Refused("owner_only", "Only an owner makes somebody an owner.")
            if len(people) >= STAFF_MOST:
                raise Refused("full", f"A list holds {STAFF_MOST} people at most. Take somebody off first.")
            self._name_free(name, people, None)
            salt, hashed = self._new_pin(pin, people, None)
            who, now = _who(by), self._now()
            member = Member(_next_id(everybody), name, role, salt, hashed, False, who, now, _pin_from(by), who, now)
            self.store.put(member, taking_over=() if kept else everybody)
        log.warning("staff: %s (%s) was added as %s by %s", member.name, member.staff_id, member.role, who)
        return member

    def change(
        self,
        staff_id: str,
        *,
        name: str | None = None,
        role: str | None = None,
        pin: str | None = None,
        by: Actor | None,
    ) -> Member:
        """A name, a role or a PIN changed, each only when it is given."""
        with self._lock:
            everybody, kept = self._read()
            people = [m for m in everybody if not m.removed]
            acting = self._acting(by, people)
            was = next((m for m in people if m.staff_id == staff_id), None)
            if was is None:
                raise Refused("unknown_staff", "Nobody on the staff has this id.")
            if was.role == "owner" and acting is not None and acting.role != "owner":
                raise Refused("owner_only", "Only an owner changes an owner.")
            now = was
            if name is not None and clean_name(name) != was.name:
                now = replace(now, name=clean_name(name))
                self._name_free(now.name, people, staff_id)
            if role is not None and clean_role(role) != was.role:
                if acting is not None and acting.staff_id == staff_id and (role != "owner" or self._owners(people)):
                    raise Refused("yourself", "Nobody changes their own role: another manager does that.")
                if role == "owner" and acting is not None and acting.role != "owner" and self._owners(people):
                    raise Refused("owner_only", "Only an owner makes somebody an owner.")
                now = replace(now, role=role)
                if not any((now if m.staff_id == staff_id else m).role in ALWAYS for m in people):
                    raise Refused("last_manager", f"{was.name} is the last manager here. Make somebody else one first.")
            who, at = _who(by), self._now()
            if pin is not None:
                salt, hashed = self._new_pin(pin, people, staff_id)
                now = replace(now, pin_salt=salt, pin_hash=hashed, pin_from=_pin_from(by), pin_by=who, pin_at_ms=at)
            if now == was:
                return was
            now = replace(now, by=who, at_ms=at)
            self.store.put(now, taking_over=() if kept else everybody)
        if now.name != was.name:
            log.warning("staff: %s (%s) is now called %s, changed by %s", was.name, staff_id, now.name, who)
        if now.role != was.role:
            log.warning(
                "staff: %s (%s) is now a %s, was a %s, changed by %s", now.name, staff_id, now.role, was.role, who
            )
        if pin is not None:
            log.warning("staff: the PIN of %s (%s) was changed by %s", now.name, staff_id, who)
        return now

    def remove(self, staff_id: str, *, by: Actor | None) -> Member:
        """Somebody left: they sign in no more. Their name stays with what they did, and their PIN is gone."""
        with self._lock:
            everybody, kept = self._read()
            people = [m for m in everybody if not m.removed]
            acting = self._acting(by, people)
            was = next((m for m in people if m.staff_id == staff_id), None)
            if was is None:
                raise Refused("unknown_staff", "Nobody on the staff has this id.")
            if was.role == "owner" and acting is not None and acting.role != "owner":
                raise Refused("owner_only", "Only an owner takes an owner off the staff.")
            if acting is not None and acting.staff_id == staff_id:
                raise Refused("yourself", "Nobody takes themselves off the staff: another manager does that.")
            if not any(m.role in ALWAYS for m in people if m.staff_id != staff_id):
                raise Refused("last_manager", f"{was.name} is the last manager here. Make somebody else one first.")
            who = _who(by)
            gone = replace(was, pin_salt="", pin_hash="", removed=True, by=who, at_ms=self._now())
            self.store.put(gone, taking_over=() if kept else everybody)
        log.warning("staff: %s (%s, %s) was taken off the staff by %s", was.name, staff_id, was.role, who)
        return gone

    @staticmethod
    def _name_free(name: str, people: Sequence[Member], but: str | None) -> None:
        taken = next((m for m in people if m.staff_id != but and m.name.casefold() == name.casefold()), None)
        if taken is not None:
            raise Refused(
                "name_taken", f"There is {_a(taken.name)} already. Add a letter of the last name to tell them apart."
            )

    @staticmethod
    def _new_pin(pin: str, people: Sequence[Member], but: str | None) -> tuple[str, str]:
        """The salt and the hash a new PIN is kept as. Refused when it is somebody else's: a sign-in is a PIN
        and nothing else, so the hub could not tell the two apart. The refusal says neither the PIN nor whose
        it is."""
        pin = clean_pin(pin)
        for other in people:
            if other.staff_id != but and other.pin_hash and other.staff().pin_matches(pin):
                raise Refused("pin_taken", "Somebody else has that PIN. Pick another.")
        fresh = Staff.with_pin("", "", "", pin)
        return fresh.pin_salt, fresh.pin_hash


def _who(by: Actor | None) -> str:
    return by.name if by is not None else TERMINAL


def _pin_from(by: Actor | None) -> str:
    return "app" if by is not None else "terminal"


def _a(name: str) -> str:
    return f"an {name}" if name[:1].lower() in "aeiou" else f"a {name}"


def _next_id(everybody: Sequence[Member]) -> str:
    """An id nobody has and nobody had: one more than the highest `s<number>` the list ever held."""
    taken = {m.staff_id for m in everybody}
    highest = max((int(found.group(1)) for m in everybody if (found := _NUMBERED.match(m.staff_id))), default=0)
    number = highest + 1
    while f"s{number}" in taken:
        number += 1
    return f"s{number}"


__all__ = [
    "NAME_MOST",
    "PIN",
    "ROLES",
    "STAFF_MOST",
    "TERMINAL",
    "Actor",
    "Member",
    "PgStaffStore",
    "Refused",
    "StaffList",
    "StaffStore",
    "clean_name",
    "clean_pin",
    "clean_role",
    "default_staff_store",
]
