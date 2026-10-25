"""The order operation log.

Terminals never overwrite an order. They append operations; the current order is the replay of its
operations in clock order, and merging two copies is the union of their operations. Everything a
hub, a terminal or the cloud needs to agree on is in this module, so it can be tested like a calculator.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any

from .hlc import HLC

MAX_DRIFT_MS = 5 * 60 * 1000
"""An operation stamped further than this into the future is refused; the device must resync its clock."""

KINDS = frozenset(
    {
        "create",  # data: any order fields
        "set_field",  # data: any order fields
        "add_line",  # data: line_id, item, qty?, seat?, course?, note?
        "set_line",  # data: line_id + any line fields
        "void_line",  # data: line_id, reason?
        "fire",  # data: course ("*" = everything)
        "close",
        "reopen",
        "void_order",  # data: reason?
    }
)
ORDER_FIELDS = frozenset({"table", "guests", "note", "order_type", "server", "ticket_no"})
LINE_FIELDS = frozenset({"qty", "seat", "course", "note"})


class ClockDriftError(ValueError):
    def __init__(self, op: Op, now_ms: int) -> None:
        super().__init__(f"op {op.op_id} is stamped {op.hlc.wall_ms - now_ms} ms in the future")
        self.op = op


@dataclass(frozen=True)
class Op:
    op_id: str
    order_id: str
    hlc: HLC
    device: str
    kind: str
    data: dict[str, Any] = field(default_factory=dict, compare=False)

    @property
    def sort_key(self) -> tuple[HLC, str]:
        return (self.hlc, self.op_id)


@dataclass
class Line:
    line_id: str
    item: str
    qty: int = 1
    seat: int | None = None
    course: str | None = None
    note: str = ""
    status: str = "active"  # active | void
    void_reason: str | None = None
    modified_after_fire: bool = False
    stamps: dict[str, HLC] = field(default_factory=dict)


@dataclass
class OrderState:
    order_id: str
    status: str = "open"  # open | closed | void
    fields: dict[str, Any] = field(default_factory=dict)
    stamps: dict[str, HLC] = field(default_factory=dict)
    lines: dict[str, Line] = field(default_factory=dict)
    fired: dict[str, HLC] = field(default_factory=dict)  # course -> first fire stamp
    applied: list[str] = field(default_factory=list)  # op ids in replay order
    last: HLC | None = None

    def snapshot(self) -> dict[str, Any]:
        """A plain, comparable picture of the order; two replicas agree when their snapshots are equal."""
        return {
            "order_id": self.order_id,
            "status": self.status,
            "fields": dict(sorted(self.fields.items())),
            "lines": {
                line_id: {
                    "item": line.item,
                    "qty": line.qty,
                    "seat": line.seat,
                    "course": line.course,
                    "note": line.note,
                    "status": line.status,
                    "void_reason": line.void_reason,
                    "modified_after_fire": line.modified_after_fire,
                }
                for line_id, line in sorted(self.lines.items())
            },
            "fired": {course: str(stamp) for course, stamp in sorted(self.fired.items())},
        }

    def _fired_before(self, course: str | None) -> bool:
        return "*" in self.fired or (course is not None and course in self.fired)


def apply(state: OrderState, op: Op) -> None:
    """Apply one operation. Callers apply operations in sort order; `replay` does that."""
    data = op.data
    kind = op.kind
    if kind not in KINDS:
        raise ValueError(f"unknown op kind {kind!r}")

    if kind in ("create", "set_field"):
        for name, value in data.items():
            if name in ORDER_FIELDS and state.stamps.get(name, _MIN) <= op.hlc:
                state.fields[name] = value
                state.stamps[name] = op.hlc

    elif kind == "add_line":
        line_id = data["line_id"]
        if line_id in state.lines:
            return  # already there, or voided first: a void always wins
        line = Line(
            line_id=line_id,
            item=data["item"],
            qty=int(data.get("qty", 1)),
            seat=data.get("seat"),
            course=data.get("course"),
            note=data.get("note", ""),
        )
        line.stamps = dict.fromkeys(LINE_FIELDS, op.hlc)
        line.modified_after_fire = state._fired_before(line.course)
        state.lines[line_id] = line

    elif kind == "set_line":
        line = state.lines.get(data["line_id"])
        if line is None or line.status == "void":
            return  # unknown line, or a void: a void always wins
        was_fired = state._fired_before(line.course)
        for name in LINE_FIELDS:
            if name in data and line.stamps.get(name, _MIN) <= op.hlc:
                setattr(line, name, data[name])
                line.stamps[name] = op.hlc
        if was_fired or state._fired_before(line.course):
            line.modified_after_fire = True

    elif kind == "void_line":
        line_id = data["line_id"]
        line = state.lines.get(line_id)
        if line is None:
            line = Line(line_id=line_id, item=data.get("item", ""))
            state.lines[line_id] = line
        if line.status != "void":
            line.status = "void"
            line.void_reason = data.get("reason")
            if state._fired_before(line.course):
                line.modified_after_fire = True

    elif kind == "fire":
        course = data.get("course", "*")
        state.fired.setdefault(course, op.hlc)

    elif kind == "close":
        if state.status != "void":
            state.status = "closed"

    elif kind == "reopen":
        if state.status == "closed":
            state.status = "open"

    elif kind == "void_order":
        state.status = "void"

    state.applied.append(op.op_id)
    state.last = op.hlc


_MIN = HLC(0, 0, "")


def replay(ops: Iterable[Op], order_id: str | None = None) -> OrderState:
    """The order described by a set of operations, however they arrived."""
    unique: dict[str, Op] = {}
    for op in ops:
        unique.setdefault(op.op_id, op)
    ordered = sorted(unique.values(), key=lambda op: op.sort_key)
    if order_id is None:
        order_id = ordered[0].order_id if ordered else ""
    state = OrderState(order_id=order_id)
    for op in ordered:
        if op.order_id != order_id:
            raise ValueError(f"op {op.op_id} belongs to order {op.order_id}, not {order_id}")
        apply(state, op)
    return state


class OpStore:
    """An append-only store of operations with a cursor, so peers can pull what they have not seen."""

    def __init__(self, physical: Callable[[], int] | None = None) -> None:
        self._ops: list[Op] = []
        self._ids: set[str] = set()
        self._physical = physical or (lambda: int(time.time() * 1000))

    @property
    def cursor(self) -> int:
        return len(self._ops)

    def __contains__(self, op_id: str) -> bool:
        return op_id in self._ids

    def __len__(self) -> int:
        return len(self._ops)

    def append(self, ops: Iterable[Op]) -> list[Op]:
        """Store new operations; duplicates are ignored. Returns the ones that were new."""
        now = self._physical()
        accepted: list[Op] = []
        for op in ops:
            if op.hlc.wall_ms > now + MAX_DRIFT_MS:
                raise ClockDriftError(op, now)
            if op.kind not in KINDS:
                raise ValueError(f"unknown op kind {op.kind!r}")
            if op.op_id in self._ids:
                continue
            self._ids.add(op.op_id)
            self._ops.append(op)
            accepted.append(op)
        return accepted

    def since(self, cursor: int, limit: int | None = None) -> list[Op]:
        end = None if limit is None else cursor + limit
        return self._ops[cursor:end]

    def for_order(self, order_id: str) -> list[Op]:
        return [op for op in self._ops if op.order_id == order_id]

    def order_ids(self) -> list[str]:
        return sorted({op.order_id for op in self._ops})

    def state(self, order_id: str) -> OrderState:
        return replay(self.for_order(order_id), order_id)

    def op_ids(self) -> frozenset[str]:
        return frozenset(self._ids)
