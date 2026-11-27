"""Floor plan data and the live picture of it.

The plan is data (`data/floor.json`, or `POS_FLOOR`): rooms, and tables with a label, seat count, shape and
position in the plan's own frame, so the app can draw it at any size. Which tables are busy is never stored:
it is read from the open orders, whose `table` field holds the table id. The courses a line can belong to
are a location setting (`pos.settings`, key `coursing`), not part of the plan.

A manager can redraw the plan from the app's floor editor: the edited plan is a location setting
(`floor_plan`), checked by `clean_floor_plan`, and stands in for the file from then on (`plan_of`) until it
is put back.

Each open check also says what its table is waiting on and since when (`check_timer`), read from the order
log's own stamps, so every screen draws the same timer ring around the table whatever its own clock says.
"""

from __future__ import annotations

import json
import math
import os
import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import asdict, dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any

from ..sync.hlc import HLC
from ..sync.oplog import OrderState

DEFAULT = Path(__file__).with_name("data") / "floor.json"


@dataclass(frozen=True)
class Table:
    id: str
    label: str
    room: str
    x: float
    y: float
    w: float
    h: float
    seats: int
    shape: str = "rect"  # rect | round
    rotation: float = 0
    kind: str = "table"  # table | booth | counter


@dataclass
class FloorPlan:
    width: float
    height: float
    rooms: list[dict[str, Any]] = field(default_factory=list)
    tables: list[Table] = field(default_factory=list)

    def table(self, table_id: str) -> Table | None:
        return next((t for t in self.tables if t.id == table_id), None)

    def as_json(self) -> dict[str, Any]:
        return {
            "width": self.width,
            "height": self.height,
            "rooms": self.rooms,
            "tables": [asdict(t) for t in self.tables],
        }

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> FloorPlan:
        plan = cls(
            width=data["width"],
            height=data["height"],
            rooms=list(data.get("rooms", ())),
            tables=[Table(**{k: v for k, v in t.items() if k in Table.__dataclass_fields__}) for t in data["tables"]],
        )
        ids = [t.id for t in plan.tables]
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        if dupes:
            raise ValueError(f"floor plan: duplicate table ids {dupes}")
        rooms = {r["id"] for r in plan.rooms}
        strays = sorted(t.id for t in plan.tables if t.room not in rooms)
        if strays:
            raise ValueError(f"floor plan: tables in unknown rooms {strays}")
        return plan


def load_floor(path: str | None = None) -> FloorPlan:
    path = path if path is not None else os.environ.get("POS_FLOOR")
    return FloorPlan.from_json(json.loads(Path(path or DEFAULT).read_text(encoding="utf-8")))


def plan_of(state: Any) -> FloorPlan:
    """The floor plan as it stands now: the one a manager drew in the floor editor (the location setting
    `floor_plan`) when there is one, the plan the hub came with (`state.floor`) otherwise. `state` is the
    app's: its `settings` and its `floor`."""
    settings = getattr(state, "settings", None)
    saved = settings.get("floor_plan").get("plan") if settings is not None else None
    if not saved:
        return state.floor
    kept = getattr(state, "floor_drawn", None)
    if kept is None or kept[0] != saved:
        kept = (saved, FloorPlan.from_json(saved))
        state.floor_drawn = kept  # read on every poll of the map: parsed once per plan
    return kept[1]


TABLE_ID = re.compile(r"^[A-Za-z0-9_-]{1,24}$")
ROOM_ID = re.compile(r"^[A-Za-z0-9_-]{1,24}$")
SHAPES = ("rect", "round")
KINDS = ("table", "booth", "counter")
LABEL_MAX = 8
ROOM_NAME_MAX = 32
ROOMS_MAX = 24
TABLES_MAX = 400
SEATS_MAX = 60
SIDE_MIN, SIDE_MAX = 16, 1200
"""A table's sides in the plan's own units; the plan the hub comes with draws a seat at the bar 30 across and
a table for six 45 by 100."""
SPAN_MAX = 20000
"""How far apart two tables can be drawn, either way."""
MARGIN = 60
"""The room a plan keeps round its tables, and a room's frame round its own."""


def _number(value: Any, what: str) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value):
        raise ValueError(f"{what} must be a number")
    return float(value)


def _slug(name: str, taken: set[str], fallback: str) -> str:
    """An id from a name ("Patio 2" gives `patio-2`), with a number after it when that one is taken."""
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:20] or fallback
    ident, n = base, 2
    while ident in taken:
        ident, n = f"{base}-{n}", n + 1
    return ident


def clean_floor_plan(data: Mapping[str, Any]) -> dict[str, Any]:
    """A floor plan as the floor editor may save it, checked; raises ValueError with the reason otherwise.

    `rooms`, in the order the map lists them: each a `name`, and an `id` once it has one (a room sent
    without is new and gets its id from its name). `tables`: each an `id` (the name orders carry: letters,
    figures, `-` and `_`), a `label` (what the map writes on it), the `room` it stands in, where its middle
    is (`x`, `y`) and how large it is (`w`, `h`) in the plan's own units, its `seats`, `shape` (rect or
    round), `rotation` in degrees and `kind` (table, booth or counter). A new table's room may be named by
    the room's place in `rooms` ("#0") while the room has no id yet.

    What is stored is drawn from the tables: they are moved together so the plan starts a margin from its
    corner, the plan is as wide and high as they need, and each room's frame is the one round its own
    tables (an empty room keeps a small frame of its own under the others), so an app that draws the
    frames it is given draws them right."""
    raw_rooms, raw_tables = data.get("rooms"), data.get("tables")
    if not isinstance(raw_rooms, list) or not raw_rooms:
        raise ValueError("a floor plan has at least one room")
    if len(raw_rooms) > ROOMS_MAX:
        raise ValueError(f"a floor plan has {ROOMS_MAX} rooms at most")
    if not isinstance(raw_tables, list):
        raise ValueError("tables must be a list")
    if len(raw_tables) > TABLES_MAX:
        raise ValueError(f"a floor plan has {TABLES_MAX} tables at most")

    rooms: list[dict[str, Any]] = []
    taken = {str(r.get("id")) for r in raw_rooms if isinstance(r, Mapping) and r.get("id")}
    names: set[str] = set()
    for at, room in enumerate(raw_rooms):
        if not isinstance(room, Mapping):
            raise ValueError("a room is its name and its id")
        name = " ".join(str(room.get("name") or "").split())
        if not name:
            raise ValueError("every room has a name")
        if len(name) > ROOM_NAME_MAX:
            raise ValueError(f"a room's name is {ROOM_NAME_MAX} letters at most: {name!r}")
        if name.lower() in names:
            raise ValueError(f"two rooms are called {name!r}")
        names.add(name.lower())
        ident = room.get("id")
        if ident:
            ident = str(ident)
            if not ROOM_ID.match(ident):
                raise ValueError(f"a room's id is letters, figures, - and _: {ident!r}")
            if any(r["id"] == ident for r in rooms):
                raise ValueError(f"two rooms have the id {ident!r}")
        else:
            ident = _slug(name, taken, f"room-{at + 1}")
            taken.add(ident)
        rooms.append({"id": ident, "name": name})
    by_place = {f"#{at}": room["id"] for at, room in enumerate(rooms)}
    room_ids = {room["id"] for room in rooms}

    tables: list[dict[str, Any]] = []
    seen: set[str] = set()
    for table in raw_tables:
        if not isinstance(table, Mapping):
            raise ValueError("a table is its id, label, room, place and size")
        ident = str(table.get("id") or "")
        if not TABLE_ID.match(ident):
            raise ValueError(f"a table's id is 1 to 24 letters, figures, - and _: {ident!r}")
        if ident in seen:
            raise ValueError(f"two tables have the id {ident!r}")
        seen.add(ident)
        label = " ".join(str(table.get("label") or "").split()) or ident
        if len(label) > LABEL_MAX:
            raise ValueError(f"a table's name is {LABEL_MAX} letters at most: {label!r}")
        room = str(table.get("room") or "")
        room = by_place.get(room, room)
        if room not in room_ids:
            raise ValueError(f"table {label} stands in a room the plan does not have")
        shape = table.get("shape", "rect")
        if shape not in SHAPES:
            raise ValueError(f"table {label}: its shape is one of {', '.join(SHAPES)}")
        kind = table.get("kind", "table")
        if kind not in KINDS:
            raise ValueError(f"table {label}: its kind is one of {', '.join(KINDS)}")
        seats = table.get("seats", 2)
        if isinstance(seats, bool) or not isinstance(seats, int | float) or seats != int(seats):
            raise ValueError(f"table {label}: its seats are a whole number")
        if not 1 <= seats <= SEATS_MAX:
            raise ValueError(f"table {label}: 1 to {SEATS_MAX} seats")
        w, h = (
            _number(table.get("w"), f"table {label}: its width"),
            _number(table.get("h"), f"table {label}: its depth"),
        )
        if shape == "round":
            w = h = min(w, h)
        if not (SIDE_MIN <= w <= SIDE_MAX and SIDE_MIN <= h <= SIDE_MAX):
            raise ValueError(f"table {label}: each side is {SIDE_MIN} to {SIDE_MAX} units")
        rotation = _number(table.get("rotation", 0), f"table {label}: its turn")
        rotation = 0.0 if shape == "round" else ((rotation + 180) % 360) - 180  # -180 up to 180
        tables.append(
            {
                "id": ident,
                "label": label,
                "room": room,
                "x": _number(table.get("x"), f"table {label}: where it stands"),
                "y": _number(table.get("y"), f"table {label}: where it stands"),
                "w": round(w, 2),
                "h": round(h, 2),
                "seats": int(seats),
                "shape": shape,
                "rotation": round(rotation, 2),
                "kind": kind,
            }
        )
    labels = [t["label"].lower() for t in tables]
    twice = sorted({t["label"] for t in tables if labels.count(t["label"].lower()) > 1})
    if twice:
        raise ValueError(f"two tables are called {twice[0]}")

    def reach(table: Mapping[str, Any]) -> tuple[float, float]:
        """Half the width and half the height of the upright frame that holds the table as it is turned."""
        turn = math.radians(table["rotation"])
        c, s = abs(math.cos(turn)), abs(math.sin(turn))
        return (table["w"] * c + table["h"] * s) / 2, (table["w"] * s + table["h"] * c) / 2

    def frame(of: Iterable[Mapping[str, Any]]) -> tuple[float, float, float, float] | None:
        boxes = [(t["x"] - rx, t["y"] - ry, t["x"] + rx, t["y"] + ry) for t in of for rx, ry in [reach(t)]]
        if not boxes:
            return None
        return min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)

    whole = frame(tables)
    if whole is None:
        width, height = 2.0 * MARGIN + 400, 2.0 * MARGIN + 300
    else:
        if whole[2] - whole[0] > SPAN_MAX or whole[3] - whole[1] > SPAN_MAX:
            raise ValueError("the tables are drawn too far apart")
        dx, dy = MARGIN - whole[0], MARGIN - whole[1]
        for table in tables:
            table["x"], table["y"] = round(table["x"] + dx, 2), round(table["y"] + dy, 2)
        width, height = round(whole[2] - whole[0] + 2 * MARGIN, 2), round(whole[3] - whole[1] + 2 * MARGIN, 2)
    empty = 0
    for room in rooms:
        own = frame(t for t in tables if t["room"] == room["id"])
        if own is None:
            # a room with no table yet: a small frame of its own, so an app that draws frames shows it
            own = (MARGIN + empty * 140.0, height, MARGIN + empty * 140.0 + 120, height + 80)
            empty += 1
        pad = MARGIN / 3
        room.update(
            x=round(own[0] - pad, 2),
            y=round(own[1] - pad, 2),
            w=round(own[2] - own[0] + 2 * pad, 2),
            h=round(own[3] - own[1] + 2 * pad, 2),
        )
    if empty:
        height = round(height + 80 + MARGIN, 2)
    return {"width": width, "height": height, "rooms": rooms, "tables": tables}


STAGES = ("sat", "unsent", "held", "fired")
"""What a table can be waiting on, as the floor map times it (`check_timer`); the warning times for each are
a location setting (`pos.settings`, key `table_timers`)."""


def check_timer(state: OrderState, courses: Sequence[str] = ()) -> dict[str, Any] | None:
    """What an open check is waiting on, and since when (wall-clock ms, from the stamps in its log):

    - `sat`: nothing is on the check. Since it was opened (or since the last dish was sent, when every dish
      that went has been voided since).
    - `unsent`: dishes are on the check that the kitchen has not been sent and that are not being held for
      their turn: nothing has been sent at all, or their course has already gone. Since the first of them
      came onto the check. This is the forgotten Fire, so it goes before a held course.
    - `held`: something was sent and a later course waits its turn. Since the course before it went (the
      nearest earlier one in `courses`, the ids in the order the kitchen serves them; the last course to go
      when that cannot be told), or since the waiting course's first dish came onto the check when that was
      later: a main ordered after the starters were eaten has not been held all that while.
    - `fired`: everything on the check was sent. Since the last dish went: with no word from the kitchen on
      when food reached the table, this is how long the table has been left to itself.

    None for a check with no stamps at all (it has no operations, so it is not listed either)."""
    active = [line for line in state.lines.values() if line.active]
    waiting = [line for line in active if line.fired_at is None]

    def timer(stage: str, since: HLC | None) -> dict[str, Any] | None:
        since = since or state.first
        return None if since is None else {"stage": stage, "since_ms": since.wall_ms}

    def added(lines: Iterable[Any]) -> HLC | None:
        return min((line.added_at for line in lines if line.added_at is not None), default=None)

    if not active:
        return timer("sat", max([*state.fired.values(), *([state.first] if state.first else [])], default=None))
    if not waiting:
        return timer("fired", max(line.fired_at for line in active if line.fired_at is not None))
    late = [line for line in waiting if not state.fired or state.course_gone(line.course)]
    if late:
        return timer("unsent", added(late))
    rank = {course: at for at, course in enumerate(courses)}
    up_next = min((line.course for line in waiting), key=lambda course: rank.get(course, len(rank)))
    before = [(rank[c], stamp) for c, stamp in state.fired.items() if c in rank and rank[c] < rank.get(up_next, -1)]
    went = max(before)[1] if before else max(state.fired.values())
    came = added(line for line in waiting if line.course == up_next)
    return timer("held", went if came is None else max(went, came))


def table_status(
    orders: Iterable[OrderState],
    totals: dict[str, Decimal] | None = None,
    courses: Sequence[str] = (),
    ready: Callable[[OrderState], dict[str, int]] | None = None,
) -> dict[str, list[dict]]:
    """Open checks by table id, oldest first: what the floor map colours and what a tap opens. `courses` are
    the course ids in the order the kitchen serves them, for the timer on a held course. `ready(order)` is
    what the kitchen has ready for a check (`pos.printing.made.ready_of`): `ready` and `ready_ms`, on the
    checks that have a dish waiting to be carried out and on no other."""
    out: dict[str, list[dict]] = {}
    for state in orders:
        if state.status != "open":
            continue
        table = state.fields.get("table")
        if table in (None, ""):
            continue
        active = [line for line in state.lines.values() if line.active]
        fired = {line.course or "" for line in active if line.fired_at is not None}
        held = sorted({line.course or "" for line in active if line.fired_at is None})
        out.setdefault(str(table), []).append(
            {
                "order_id": state.order_id,
                "guests": state.fields.get("guests"),
                "server": state.fields.get("server"),
                "server_id": state.fields.get("server_id"),
                "opened_ms": state.first.wall_ms if state.first else None,
                "items": sum(line.qty for line in active),
                "fired": sorted(fired),
                "held": held,
                "total": str(totals.get(state.order_id)) if totals and state.order_id in totals else None,
                "timer": check_timer(state, courses),
                **(ready(state) if ready is not None else {}),
            }
        )
    for checks in out.values():
        checks.sort(key=lambda c: c["opened_ms"] or 0)
    return out
