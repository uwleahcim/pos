"""Staff sign-in for phase 0: a list of staff with PINs, checked by the backend, never by the app.

PINs are stored as salted hashes. Five wrong tries on one device lock that device's PIN pad for a minute.
Tags and face signatures plug into the same `Directory` in the sign-in hardware spike.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass

LOCK_AFTER = 5
LOCK_SECONDS = 60.0

TAKES_TABLES = frozenset({"server", "bartender", "manager", "owner"})
"""The roles a table can be given to: the people who serve one."""
ASSIGNS_TABLES = frozenset({"host", "manager", "owner"})
"""The roles that seat a party for someone else, or hand a seated table to another server. Everyone who
takes tables gets a table by opening it themselves."""


@dataclass(frozen=True)
class Staff:
    staff_id: str
    name: str
    role: str  # server | bartender | host | manager | owner | kitchen | cashier
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
        self._clock = clock
        self._failures: dict[str, list[float]] = {}

    def __len__(self) -> int:
        return len(self._staff)

    def get(self, staff_id: str) -> Staff | None:
        return self._staff.get(staff_id)

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


def demo_directory() -> Directory:
    """Phase 0 staff. POS_STAFF overrides it: `id:name:role:pin,...` in the environment, never in the repo."""
    spec = os.environ.get("POS_STAFF")
    if spec:
        staff = []
        for entry in spec.split(","):
            staff_id, name, role, pin = entry.strip().split(":")
            staff.append(Staff.with_pin(staff_id, name, role, pin))
        return Directory(staff)
    return Directory(
        [
            Staff.with_pin("s1", "Amy", "server", "1111"),
            Staff.with_pin("s2", "Ben", "bartender", "2222"),
            Staff.with_pin("s3", "Mike", "manager", "9999"),
            Staff.with_pin("s4", "Holly", "host", "3333"),
        ]
    )


def roster(directory: Directory) -> list[dict[str, object]]:
    """The staff by name and role, for the screens that put a name to a table: who a table can be given to
    and who may give one. Nothing a sign-in is checked against (PIN, tag, face) is in it."""
    return [
        {
            "staff_id": s.staff_id,
            "name": s.name,
            "role": s.role,
            "takes_tables": s.role in TAKES_TABLES,
            "assigns_tables": s.role in ASSIGNS_TABLES,
        }
        for s in directory.all()
    ]
