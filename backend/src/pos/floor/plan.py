"""Floor plan data and the live picture of it.

The plan is data (`data/floor.json`, or `POS_FLOOR`): rooms, and tables with a label, seat count, shape and
position in the plan's own frame, so the app can draw it at any size. Which tables are busy is never stored:
it is read from the open orders, whose `table` field holds the table id.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable
from dataclasses import asdict, dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any

from ..sync.oplog import OrderState

DEFAULT = Path(__file__).with_name("data") / "floor.json"

COURSES = (
    {"id": "drinks", "name": "Drinks"},
    {"id": "1", "name": "Appetizers"},
    {"id": "2", "name": "Entrees"},
    {"id": "3", "name": "Dessert"},
)
"""Courses a line can belong to. A line with no course fires with the first `fire`."""


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
            "courses": list(COURSES),
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


def table_status(orders: Iterable[OrderState], totals: dict[str, Decimal] | None = None) -> dict[str, list[dict]]:
    """Open checks by table id, oldest first: what the floor map colours and what a tap opens."""
    out: dict[str, list[dict]] = {}
    for state in orders:
        if state.status != "open":
            continue
        table = state.fields.get("table")
        if table in (None, ""):
            continue
        active = [line for line in state.lines.values() if line.status == "active"]
        courses = {line.course or "" for line in active}
        fired = set(state.fired)
        held = sorted(c for c in courses if "*" not in fired and c not in fired and c != "")
        out.setdefault(str(table), []).append(
            {
                "order_id": state.order_id,
                "guests": state.fields.get("guests"),
                "server": state.fields.get("server"),
                "opened_ms": state.first.wall_ms if state.first else None,
                "items": sum(line.qty for line in active),
                "fired": sorted(fired),
                "held": held,
                "total": str(totals.get(state.order_id)) if totals and state.order_id in totals else None,
            }
        )
    for checks in out.values():
        checks.sort(key=lambda c: c["opened_ms"] or 0)
    return out
