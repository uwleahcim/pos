"""Floor plan data and the live picture of it.

The plan is data (`data/floor.json`, or `POS_FLOOR`): rooms, and tables with a label, seat count, shape and
position in the plan's own frame, so the app can draw it at any size. Which tables are busy is never stored:
it is read from the open orders, whose `table` field holds the table id. The courses a line can belong to
are a location setting (`pos.settings`, key `coursing`), not part of the plan.

Each open check also says what its table is waiting on and since when (`check_timer`), read from the order
log's own stamps, so every screen draws the same timer ring around the table whatever its own clock says.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable, Sequence
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
    orders: Iterable[OrderState], totals: dict[str, Decimal] | None = None, courses: Sequence[str] = ()
) -> dict[str, list[dict]]:
    """Open checks by table id, oldest first: what the floor map colours and what a tap opens. `courses` are
    the course ids in the order the kitchen serves them, for the timer on a held course."""
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
            }
        )
    for checks in out.values():
        checks.sort(key=lambda c: c["opened_ms"] or 0)
    return out
