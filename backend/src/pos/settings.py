"""Per-location settings a manager changes from the app and every terminal reads. Phase 1 holds these sets:

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
- `printers`: the kitchen printers (`pos/printing/service.py`): each with the stations it serves, its address,
  its language (escpos, star, or auto with the one it was found to speak) and the ids of the printers that
  take its tickets when it fails, in order;
  and `takeout_station`, the station a to-go order prints whole at (null for none). An empty list leaves the
  hub on `POS_PRINTERS`.
- `table_timers`: the timer ring around each table on the floor map (`pos/floor/plan.py`, `check_timer`):
  whether it is drawn, and for each thing a table can be waiting on (`sat`, `unsent`, `held`, `fired`) after
  how many minutes the ring warns and after how many it is overdue; 0 for never.
- `voids`: what voiding a dish the kitchen already has takes (`pos/orders/voids.py`): `approval`, whether a
  manager's PIN is needed (`manager`, the default) or a reason alone will do (`none`), and `reasons`, the
  short list the person voiding picks from, by name in the order the screen shows them. A void in the order
  log carries its reason's id and the name it had then, so a reason can be renamed or dropped later.
- `tickets`: what a kitchen ticket says about the other tickets of the same send (`PrintService.send`), each on
  to start: `numbered`, "Ticket 2 of 3" when more than one station is cooking, and `also_at`, the names of the
  other stations cooking ("Also at: Wok 2, Sushi Bar").

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

from .floor.plan import STAGES
from .printing.ticket import AUTO, DIALECTS
from .sync.pgstore import ReadOnlyError

CHANNELS = ("counter", "phone", "online", "delivery", "catering")
STANDARD_COURSES = [
    {"id": "drinks", "name": "Drinks"},
    {"id": "1", "name": "Appetizers"},
    {"id": "2", "name": "Entrees"},
    {"id": "3", "name": "Dessert"},
]
STANDARD_VOID_REASONS = [
    {"id": "guest-changed-mind", "name": "Guest changed mind"},
    {"id": "rung-in-wrong", "name": "Rung in wrong"},
    {"id": "kitchen-error", "name": "Kitchen error"},
    {"id": "out-of-stock", "name": "Out of stock"},
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
    "printers": {"printers": [], "takeout_station": "takeout"},
    # Minutes. Seated with no order, or dishes not sent: five to notice, ten is a guest left waiting. A held
    # course: the one before it has had a quarter of an hour. Everything sent: a nudge to look in on the
    # table, never overdue, since the hub does not hear when food reaches it.
    "table_timers": {
        "enabled": True,
        "stages": {
            "sat": {"warn": 5, "late": 10},
            "unsent": {"warn": 5, "late": 10},
            "held": {"warn": 15, "late": 25},
            "fired": {"warn": 25, "late": 0},
        },
    },
    "voids": {"approval": "manager", "reasons": STANDARD_VOID_REASONS},
    "tickets": {"numbered": True, "also_at": True},
}
AWAY_MAX = 3600
TIMER_MAX = 24 * 60
"""The longest a table timer can be set to, in minutes."""
STATION = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
"""A kitchen station's code as the menu names it (`wok1`, `takeout`)."""
PRINTER_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
ADDRESS = re.compile(r"^(?P<host>[A-Za-z0-9.-]{1,253})(?::(?P<port>\d{1,5}))?$")
"""A printer's address: a host name or IP, with a port when it is not 9100."""
EXTENSION = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
"""A PBX extension (the endpoint's name): digits as a rule, never spaces or slashes."""
DEVICE = re.compile(r"^[A-Za-z0-9]{1,40}$")
"""A device name as the app keeps it: letters and digits only."""
COURSE_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
"""A course's id: short, no spaces, never `*` (which a `fire` uses for every course)."""
COURSE_NAME_MAX = 40
VOID_APPROVALS = ("manager", "none")
"""Who stands behind a void of a sent dish: a manager's PIN on the spot, or nobody beyond the reason."""
VOID_REASON_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
VOID_REASON_NAME_MAX = 40
VOID_REASONS_MAX = 12
"""A screenful of buttons on a phone: the person voiding picks one at a glance."""
VOID_WORDS = frozenset({"void", "fewer", "changed"})
"""What a `void_line` said in place of a reason before reasons were asked, and what the void half of an edit
still says (`changed`): never a reason's id, so the reports can tell them apart."""


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


def clean_voids(data: Mapping[str, Any]) -> dict[str, Any]:
    """The void rules as the app may set them, checked: `approval` (`manager` or `none`) and `reasons`, a list
    of `{id, name}` in the order the screen shows them, at least one. A reason without an id is new on the
    screen and gets one from its name; ids never change after that, since voids in the order log carry
    them. Raises ValueError on a bad value."""
    approval = data.get("approval", "manager")
    if approval not in VOID_APPROVALS:
        raise ValueError("approval must be manager or none")
    raw = data.get("reasons") or []
    if not isinstance(raw, list | tuple) or not all(isinstance(entry, Mapping) for entry in raw):
        raise ValueError("reasons must be a list of {id, name}")
    if not raw:
        raise ValueError("voids need at least one reason to pick from")
    if len(raw) > VOID_REASONS_MAX:
        raise ValueError(f"at most {VOID_REASONS_MAX} reasons, so they fit one screen")
    names: set[str] = set()
    taken: set[str] = set(VOID_WORDS)
    for entry in raw:
        name = str(entry.get("name") or "").strip()
        if not name:
            raise ValueError("every reason needs a name")
        if len(name) > VOID_REASON_NAME_MAX:
            raise ValueError(f"a reason is at most {VOID_REASON_NAME_MAX} characters")
        if name.casefold() in names:
            raise ValueError(f"the reason {name!r} is listed twice")
        names.add(name.casefold())
        ident = entry.get("id")
        if ident not in (None, ""):
            if not isinstance(ident, str) or not VOID_REASON_ID.match(ident):
                raise ValueError(f"a reason id is letters, digits, - or _, not {ident!r}")
            if ident in VOID_WORDS:
                raise ValueError(f"the reason id {ident!r} is taken")
            if ident in taken:
                raise ValueError(f"the reason id {ident!r} is listed twice")
            taken.add(ident)
    reasons: list[dict[str, str]] = []
    for entry in raw:
        ident = entry.get("id")
        if ident in (None, ""):
            ident = _new_id(str(entry["name"]), taken, "reason")
            taken.add(ident)
        reasons.append({"id": str(ident), "name": str(entry["name"]).strip()})
    return {"approval": approval, "reasons": reasons}


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


def clean_tickets(data: Mapping[str, Any]) -> dict[str, Any]:
    """What the tickets of one send say about each other, as the app may set it: `numbered` and `also_at`, each
    true or false; one left out keeps its default. Raises ValueError on a bad value."""
    out = {}
    for name, default in DEFAULTS["tickets"].items():
        value = data.get(name, default)
        if not isinstance(value, bool):
            raise ValueError(f"{name} must be true or false")
        out[name] = value
    return out


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


def clean_table_timers(data: Mapping[str, Any]) -> dict[str, Any]:
    """The table timers as the app may set them, checked: `enabled`, and `stages`, for each of `sat`, `unsent`,
    `held` and `fired` the whole minutes after which the ring warns (`warn`) and is overdue (`late`); 0 turns
    that one off, and with both off the stage is not timed. A warning comes before overdue. A stage left out
    keeps the default. Raises ValueError on a bad value."""
    enabled = data.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be true or false")
    raw = data.get("stages") or {}
    if not isinstance(raw, Mapping):
        raise ValueError("stages must map a stage to its warn and late minutes")
    stages = copy.deepcopy(DEFAULTS["table_timers"]["stages"])
    for stage, times in raw.items():
        if stage not in STAGES:
            raise ValueError(f"unknown stage {stage!r}; one of {', '.join(STAGES)}")
        if not isinstance(times, Mapping):
            raise ValueError(f"the times for {stage} are its warn and late minutes")
        for name in ("warn", "late"):
            value = times.get(name, 0)
            if isinstance(value, bool) or not isinstance(value, int | float) or value != int(value):
                raise ValueError(f"the {name} time for {stage} must be a whole number of minutes")
            if not 0 <= value <= TIMER_MAX:
                raise ValueError(f"the {name} time for {stage} is 0 (never) to {TIMER_MAX} minutes")
            stages[stage][name] = int(value)
        if 0 < stages[stage]["late"] <= stages[stage]["warn"]:
            raise ValueError(f"the late time for {stage} must come after its warning")
    return {"enabled": enabled, "stages": stages}


def fallback_loop(fallbacks: Mapping[str, list[str]]) -> list[str] | None:
    """A way round the fallbacks that comes back to where it started, as the ids on it with the first one
    again at the end (`["a", "b", "a"]`: a falls back to b, b to a); None when there is none. Ids that are no
    printer's are passed over."""
    done: set[str] = set()

    def walk(ident: str, path: list[str]) -> list[str] | None:
        if ident in path:
            return [*path[path.index(ident) :], ident]
        if ident in done:
            return None
        for following in fallbacks.get(ident, ()):
            if following in fallbacks and (found := walk(following, [*path, ident])):
                return found
        done.add(ident)
        return None

    for start in fallbacks:
        if found := walk(start, []):
            return found
    return None


def clean_printers(data: Mapping[str, Any]) -> dict[str, Any]:
    """The printers as the app may set them, checked: `printers`, a list of `{id, stations, address, dialect,
    detected, fallbacks}` in the order they stand (the first takes whatever has no printer of its own), and
    `takeout_station`. A printer prints for one station or several (`stations`; `station` alone, as an older
    app sends it, is a list of one, and what comes back carries both, `station` being the first). Its
    `dialect` is `escpos`, `star` or `auto`: with `auto` the tickets go out in the language the printer was
    found to speak, `detected` (what `POST /print/identify` said of it; ESC/POS until it has been told). A
    printer sent without an id (new on the screen) gets one; ids never change after that, since the other
    printers' fallbacks name them. Fallbacks may not go round in a loop (a printer falling back, directly or
    through others, to one that falls back to it). Raises ValueError on a bad value."""
    raw = data.get("printers") or []
    if not isinstance(raw, list | tuple) or not all(isinstance(entry, Mapping) for entry in raw):
        raise ValueError("printers must be a list of {id, stations, address, dialect, fallbacks}")
    taken: set[str] = set()
    for entry in raw:
        ident = entry.get("id")
        if ident in (None, ""):
            continue
        if not isinstance(ident, str) or not PRINTER_ID.match(ident):
            raise ValueError(f"a printer id is letters, digits, - or _, not {ident!r}")
        if ident in taken:
            raise ValueError(f"the printer id {ident!r} is listed twice")
        taken.add(ident)
    printers: list[dict[str, Any]] = []
    addresses: dict[str, str] = {}
    for entry in raw:
        listed = entry.get("stations") or [entry.get("station")]
        if not isinstance(listed, list | tuple):
            raise ValueError("a printer's stations are a list of station codes")
        stations = list(dict.fromkeys(str(code or "").strip() for code in listed))
        stations = [code for code in stations if code]
        if not stations:
            raise ValueError("every printer needs the station it prints for")
        for code in stations:
            if not STATION.match(code):
                raise ValueError(f"a station is a short code of letters, digits, - or _, not {code!r}")
        station = stations[0]
        address = str(entry.get("address") or "").strip()
        if not address:
            raise ValueError(f"the {station} printer needs its address")
        found = ADDRESS.match(address)
        if found is None or (found.group("port") and not 0 < int(found.group("port")) < 65536):
            raise ValueError(f"a printer address is a host or IP, with :port when it is not 9100, not {address!r}")
        if address.lower() in addresses:
            raise ValueError(
                f"the {addresses[address.lower()]} and {station} printers have the same address, {address}: "
                "one printer prints for several stations, so list them on one"
            )
        addresses[address.lower()] = station
        dialect = str(entry.get("dialect") or "escpos")
        if dialect not in (*DIALECTS, AUTO):
            languages = ", ".join((AUTO, *sorted(DIALECTS)))
            raise ValueError(f"the {station} printer's language is one of {languages}, not {dialect!r}")
        detected = entry.get("detected")
        ident = entry.get("id")
        if ident in (None, ""):
            ident = next(f"p{n}" for n in itertools.count(1) if f"p{n}" not in taken)
            taken.add(ident)
        fallbacks = entry.get("fallbacks") or []
        if not isinstance(fallbacks, list | tuple):
            raise ValueError(f"the {station} printer's fallbacks must list printer ids")
        printers.append(
            {
                "id": str(ident),
                "station": station,
                "stations": stations,
                "address": address,
                "dialect": dialect,
                "detected": detected if detected in DIALECTS else None,
                "fallbacks": [str(f) for f in fallbacks],
            }
        )
    for printer in printers:
        seen: list[str] = []
        for fallback in printer["fallbacks"]:
            if fallback == printer["id"]:
                raise ValueError(f"the {printer['station']} printer cannot be its own fallback")
            if fallback not in taken:
                raise ValueError(f"the {printer['station']} printer falls back to {fallback!r}, which is not a printer")
            if fallback in seen:
                raise ValueError(f"the {printer['station']} printer lists the fallback {fallback!r} twice")
            seen.append(fallback)
        printer["fallbacks"] = seen
    loop = fallback_loop({printer["id"]: printer["fallbacks"] for printer in printers})
    if loop:
        names = {printer["id"]: printer["station"] for printer in printers}
        said = f"the {names[loop[0]]} printer falls back to the {names[loop[1]]} printer"
        said += "".join(f", which falls back to the {names[ident]} printer" for ident in loop[2:])
        raise ValueError(f"the fallbacks go round in a loop: {said}. Take one of them out")
    takeout = data.get("takeout_station")
    if takeout in ("", None):
        takeout = None
    elif not isinstance(takeout, str) or not STATION.match(takeout):
        raise ValueError(f"the takeout station is a station code, not {takeout!r}")
    return {"printers": printers, "takeout_station": takeout}


def _new_course_id(name: str, taken: set[str]) -> str:
    return _new_id(name, taken, "course")


def _new_id(name: str, taken: set[str], kind: str) -> str:
    """An id from the name (`Soup & Salad` -> `soup-salad`), numbered when that one is taken; `kind` when
    the name has no letter or digit to make one from."""
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:28] or kind
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
