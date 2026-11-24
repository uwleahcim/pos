"""Staff sign-in: a list of staff with PINs, checked by the backend, never by the app.

PINs are stored as salted hashes. Five wrong tries on one device lock that device's PIN pad for a minute.
Tags and face signatures plug into the same `Directory`.

Who is on the list: what a manager keeps in the app (Location, Staff and PINs; `pos.identity.staff_list`,
docs/staff.md) once anything was changed there, and until then the hub's own file (`POS_STAFF`), or the demo
staff. A hub has one `Directory` for as long as it runs, and a change of the staff is put into it where it
stands (`Directory.use`).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import secrets
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Any

from .powers import ALWAYS, HANDED, holds

log = logging.getLogger(__name__)

LOCK_AFTER = 5
LOCK_SECONDS = 60.0


@dataclass(frozen=True)
class Staff:
    staff_id: str
    name: str
    role: str  # server | bartender | host | manager | owner | kitchen | cashier | driver
    pin_salt: str
    pin_hash: str
    tag_uid: str | None = None  # NTAG 424 DNA uid, when enrolled

    @classmethod
    def with_pin(cls, staff_id: str, name: str, role: str, pin: str, *, tag_uid: str | None = None) -> Staff:
        salt = secrets.token_hex(8)
        return cls(staff_id, name, role, salt, hash_pin(pin, salt), tag_uid)

    def pin_matches(self, pin: str) -> bool:
        return hmac.compare_digest(self.pin_hash, hash_pin(pin, self.pin_salt))


def hash_pin(pin: str, salt: str) -> str:
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), salt.encode(), 50_000).hex()


@dataclass
class SignIn:
    staff_id: str
    name: str
    role: str
    method: str  # pin | tag | face
    device: str
    at: float


class Locked(Exception):
    def __init__(self, seconds_left: float) -> None:
        super().__init__(f"locked for {seconds_left:.0f} s")
        self.seconds_left = seconds_left


class Directory:
    """The staff of one location and the sign-in checks against it."""

    def __init__(self, staff: list[Staff], *, clock: Callable[[], float] = time.monotonic) -> None:
        self._staff = {s.staff_id: s for s in staff}
        self._gone: dict[str, str] = {}
        self._clock = clock
        self._failures: dict[str, list[float]] = {}

    def __len__(self) -> int:
        return len(self._staff)

    def use(self, staff: Iterable[Staff], gone: Mapping[str, str] | None = None) -> None:
        """The staff changed (a manager added somebody, a PIN, a role; somebody left): from now on these
        sign in and nobody else. `gone` are the people who were on the staff once, by id and name, for the
        history of what they did. The directory stays the one it was, since everything that asks who
        somebody is holds on to it, and a PIN pad that was locked stays locked."""
        # each a new dict put in place whole, so a sign-in that is going through the old one finishes on it
        self._staff = {s.staff_id: s for s in staff}
        self._gone = dict(gone or {})

    def get(self, staff_id: str) -> Staff | None:
        return self._staff.get(staff_id)

    def name_of(self, staff_id: str) -> str | None:
        """The name to put to an id in what was written down: of somebody on the staff, and of somebody who
        left it. Never a reason to let them do anything: that is `get`."""
        person = self._staff.get(staff_id)
        return person.name if person is not None else self._gone.get(staff_id)

    def all(self) -> list[Staff]:
        """Every staff member, as listed: the back office shows them by name."""
        return list(self._staff.values())

    def by_pin(self, pin: str, *, device: str) -> SignIn | None:
        """The staff member whose PIN this is, or None. Raises Locked after too many misses on `device`."""
        self._check_lock(device)
        for staff in self._staff.values():
            if staff.pin_matches(pin):
                self._failures.pop(device, None)
                return SignIn(staff.staff_id, staff.name, staff.role, "pin", device, self._clock())
        self._failures.setdefault(device, []).append(self._clock())
        return None

    def by_tag(self, tag_uid: str, *, device: str) -> SignIn | None:
        for staff in self._staff.values():
            if staff.tag_uid and hmac.compare_digest(staff.tag_uid, tag_uid):
                return SignIn(staff.staff_id, staff.name, staff.role, "tag", device, self._clock())
        return None

    def sign_in(self, staff_id: str, method: str, *, device: str) -> SignIn | None:
        """A sign-in for a staff member something else identified (a tag the hub keeps, a face): None when
        the person is no longer on the staff."""
        staff = self._staff.get(staff_id)
        if staff is None:
            return None
        return SignIn(staff.staff_id, staff.name, staff.role, method, device, self._clock())

    def _check_lock(self, device: str) -> None:
        now = self._clock()
        recent = [t for t in self._failures.get(device, []) if now - t < LOCK_SECONDS]
        self._failures[device] = recent
        if len(recent) >= LOCK_AFTER:
            raise Locked(LOCK_SECONDS - (now - recent[-1]))


def staff_from_env() -> tuple[list[Staff], str]:
    """The hub's own staff, and where they are from: `hub` for the list in `POS_STAFF`, `demo` for the demo
    staff, which signs in when the hub names nobody.

    `POS_STAFF` is `id:name:role:pin,...` in the environment, never in the repo (on a hub, a line in
    /opt/pos/.env). The list is the whole staff: whoever is not in it cannot sign in.

    A hub has to start whatever was typed there. An entry that does not read (not four parts, one of them
    empty, an id already taken) is left out and said in the log; a list in which nothing reads leaves the
    demo staff. A role the hub does not know and a list with no manager or owner in it are said in the log
    too, and kept: the first holds no power, the second leaves nobody to approve a void or open Location."""
    spec = os.environ.get("POS_STAFF")
    staff: dict[str, Staff] = {}
    for place, entry in enumerate((spec or "").split(","), 1):
        if not entry.strip():
            continue
        parts = [part.strip() for part in entry.split(":")]
        if len(parts) != 4 or not all(parts) or parts[0] in staff:
            # never the entry itself: there is a PIN in it
            log.warning("POS_STAFF: entry %d is left out (id:name:role:pin, each id once)", place)
            continue
        staff_id, name, role, pin = parts
        if role not in ALWAYS and role not in HANDED:
            log.warning("POS_STAFF: %s has the role %r, which holds no power here", name, role)
        staff[staff_id] = Staff.with_pin(staff_id, name, role, pin)
    if staff:
        if not any(s.role in ALWAYS for s in staff.values()):
            log.warning("POS_STAFF names no manager and no owner: nobody can approve a void or open Location")
        return list(staff.values()), "hub"
    if spec and spec.strip():
        log.warning("POS_STAFF names nobody the hub can read: the demo staff signs in")
    # Their PINs are in the guide, so they keep nobody out: the screen says so while one is in use (docs/staff.md).
    return [
        Staff.with_pin("s1", "Amy", "server", "1111"),
        Staff.with_pin("s2", "Ben", "bartender", "2222"),
        Staff.with_pin("s3", "Mike", "manager", "9999"),
        Staff.with_pin("s4", "Holly", "host", "3333"),
    ], "demo"


def demo_directory() -> Directory:
    """The hub's own staff as a directory (`staff_from_env`): what signs in until a manager changes the
    staff in the app."""
    return Directory(staff_from_env()[0])


def roster(directory: Directory, powers: Mapping[str, Any] | None = None) -> list[dict[str, object]]:
    """The staff by name and role, for the screens that put a name to a table: who a table can be given to
    (`take_tables` in the location's table of `powers`, `pos/identity/powers.py`: the people who serve one,
    to start the servers and the bartenders) and who may seat a party for someone else or hand a seated
    table over (`assign_tables`: to start the hosts). A manager and an owner do both. Everyone who takes
    tables gets one by opening it themselves. `delivers` says who a delivery can be handed to (`deliver`:
    to start the drivers, docs/delivery.md). With no table given, the standard one. Nothing a sign-in is
    checked against (PIN, tag, face) is in it."""
    return [
        {
            "staff_id": s.staff_id,
            "name": s.name,
            "role": s.role,
            "takes_tables": holds(powers, s.role, "take_tables"),
            "assigns_tables": holds(powers, s.role, "assign_tables"),
            "delivers": holds(powers, s.role, "deliver"),
        }
        for s in directory.all()
    ]
