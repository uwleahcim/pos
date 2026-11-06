"""Per-location settings a manager changes from the app and every terminal reads. Phase 1 holds two sets:

- `quotes`: how many minutes each channel promises a takeout order (architecture section 12, "Quote times":
  set by hand until kitchen pacing quotes them in phase 2) and which channels may pay at pickup instead of
  before the kitchen sees the order (counter mode pays first).
- `coursing`: whether dishes are coursed at all, the courses by name in the order the kitchen serves them
  (any number of them; the standard four to start) and which course a new dish goes to. A line in the order
  log carries only its course's id, so a course can be renamed or moved without touching any order.
- `desk_phones`: which screen each desk phone is linked to (a PBX extension to a device name), so a call
  taken on the phone opens the caller's order on that screen (`pos/phones/deskphones.py`).
- `faces`: whether staff may sign in by face at this location (`pos/identity/faces.py`); off until a manager
  turns it on, since the location decides that after its own legal review and the staff's consent.
- `presence`: hands-free switching. `switch`: whether a face recognised or a tag read while someone is signed
  in switches the screen to that person at once (on by default: a server walks up and orders); `away_seconds`:
  how long the camera may go without seeing the person signed in by face before the screen signs them out
  (0 keeps them signed in until someone else steps up or they sign out).

Stored like staff preferences: in memory on a laptop, in PostgreSQL on every hub and in the cloud.
"""

from __future__ import annotations

import copy
import itertools
import os
import re
from collections.abc import Mapping
from typing import Any

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .sync.pgstore import ReadOnlyError

CHANNELS = ("counter", "phone", "online", "delivery", "catering")
STANDARD_COURSES = [
    {"id": "drinks", "name": "Drinks"},
    {"id": "1", "name": "Appetizers"},
    {"id": "2", "name": "Entrees"},
    {"id": "3", "name": "Dessert"},
]
DEFAULTS: dict[str, dict[str, Any]] = {
    "quotes": {
        "minutes": {"counter": 15, "phone": 20, "online": 25, "delivery": 45},
        "pay_at_pickup": ["phone"],
    },
    "coursing": {"enabled": True, "default": "1", "courses": STANDARD_COURSES},
    "desk_phones": {"links": []},
    "faces": {"enabled": False},
    "presence": {"switch": True, "away_seconds": 60},
}
AWAY_MAX = 3600
EXTENSION = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
"""A PBX extension (the endpoint's name): digits as a rule, never spaces or slashes."""
DEVICE = re.compile(r"^[A-Za-z0-9]{1,40}$")
"""A device name as the app keeps it: letters and digits only."""
COURSE_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
"""A course's id: short, no spaces, never `*` (which a `fire` uses for every course)."""
COURSE_NAME_MAX = 40


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


def clean_coursing(data: Mapping[str, Any]) -> dict[str, Any]:
    """The coursing settings as the app may set them, checked: `enabled`, `courses` as a list of `{id, name}`
    in kitchen order, and `default`, the course a new dish goes to (the first course when not named). A
    course without an id is new on the screen and gets one from its name, unique among the rest; ids never
    change after that, since order lines carry them. Raises ValueError on a bad value."""
    enabled = data.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be true or false")
    raw = data.get("courses") or []
    if not isinstance(raw, list | tuple) or not all(isinstance(entry, Mapping) for entry in raw):
        raise ValueError("courses must be a list of {id, name}")
    names: set[str] = set()
    taken: set[str] = set()
    for entry in raw:
        name = str(entry.get("name") or "").strip()
        if not name:
            raise ValueError("every course needs a name")
        if len(name) > COURSE_NAME_MAX:
            raise ValueError(f"a course name is at most {COURSE_NAME_MAX} characters")
        if name.casefold() in names:
            raise ValueError(f"the course {name!r} is listed twice")
        names.add(name.casefold())
        ident = entry.get("id")
        if ident not in (None, ""):
            if not isinstance(ident, str) or not COURSE_ID.match(ident):
                raise ValueError(f"a course id is letters, digits, - or _, not {ident!r}")
            if ident in taken:
                raise ValueError(f"the course id {ident!r} is listed twice")
            taken.add(ident)
    courses: list[dict[str, str]] = []
    for entry in raw:
        ident = entry.get("id")
        if ident in (None, ""):
            ident = _new_course_id(str(entry["name"]), taken)
            taken.add(ident)
        courses.append({"id": str(ident), "name": str(entry["name"]).strip()})
    if enabled and not courses:
        raise ValueError("coursing needs at least one course, or turn it off")
    default = data.get("default")
    if default in (None, ""):
        default = courses[0]["id"] if courses else None
    elif not any(c["id"] == default for c in courses):
        raise ValueError(f"the default course {default!r} is not on the list")
    return {"enabled": enabled, "default": default, "courses": courses}


def clean_desk_phones(data: Mapping[str, Any]) -> dict[str, Any]:
    """The desk phone links as the app may set them, checked: `links`, a list of `{extension, device}`, each
    extension once (a phone rings one screen; a screen may have several phones). Raises ValueError on a bad
    value."""
    raw = data.get("links") or []
    if not isinstance(raw, list | tuple) or not all(isinstance(entry, Mapping) for entry in raw):
        raise ValueError("links must be a list of {extension, device}")
    links: list[dict[str, str]] = []
    seen: set[str] = set()
    for entry in raw:
        extension = str(entry.get("extension") or "").strip()
        device = str(entry.get("device") or "").strip()
        if not extension:
            raise ValueError("every link needs the phone's extension")
        if not EXTENSION.match(extension):
            raise ValueError(f"an extension is digits or letters, not {extension!r}")
        if not device:
            raise ValueError(f"the link for extension {extension} needs a device name")
        if not DEVICE.match(device):
            raise ValueError(f"a device name is letters and digits, as the app shows it, not {device!r}")
        if extension in seen:
            raise ValueError(f"extension {extension} is linked twice")
        seen.add(extension)
        links.append({"extension": extension, "device": device})
    return {"links": links}


def clean_presence(data: Mapping[str, Any]) -> dict[str, Any]:
    """The hands-free switching settings as the app may set them: `switch` on or off, `away_seconds` 0 (never)
    to an hour. Raises ValueError on a bad value."""
    switch = data.get("switch", True)
    if not isinstance(switch, bool):
        raise ValueError("switch must be true or false")
    away = data.get("away_seconds", 60)
    if isinstance(away, bool) or not isinstance(away, int | float) or away != int(away):
        raise ValueError("away_seconds must be a whole number of seconds")
    if not 0 <= away <= AWAY_MAX:
        raise ValueError(f"away_seconds is 0 (never) to {AWAY_MAX}")
    return {"switch": switch, "away_seconds": int(away)}


def _new_course_id(name: str, taken: set[str]) -> str:
    """An id from the name (`Soup & Salad` -> `soup-salad`), numbered when that one is taken."""
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:28] or "course"
    if base not in taken:
        return base
    return next(f"{base}-{n}" for n in itertools.count(2) if f"{base}-{n}" not in taken)


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
