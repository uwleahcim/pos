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
        "add_line",  # data: line_id, item, qty?, seat?, course?, note?, request?, priced?
        "set_line",  # data: line_id + any line fields
        "void_line",  # data: line_id, reason? (removes a line the kitchen has not seen, voids one it has)
        "fire",  # data: course ("*" = everything); sends that course's lines not yet sent
        "close",
        "reopen",
        "void_order",  # data: reason?
        "discount",  # data: discount_id, reason, kind (percent|amount|comp), value?, line_id?, note?, applied_by?
        "remove_discount",  # data: discount_id
        "charge",  # data: charge_id, code (a charge rule), + the rule's snapshot the hub fills in
        "remove_charge",  # data: charge_id (a rule's code takes off the automatic charge it applies)
    }
)
"""Any kind may also carry `offline: true` in its data: the terminal stamped it while no backend answered
(ADR 6, capture-only mode). The replay ignores it; the printer heads the ticket "late" and reports list it.
A `discount`, `charge` or `remove_charge` may carry `approval`, a manager's token; the hub swaps it for
`approved_by` (who) before storing (pos.orders.adjustments)."""
ORDER_FIELDS = frozenset({"table", "guests", "note", "order_type", "server", "server_id", "ticket_no"})
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
    status: str = "active"  # active | removed (taken off before the kitchen saw it) | void (after)
    void_reason: str | None = None
    modified_after_fire: bool = False
    request: dict[str, Any] | None = None  # what the operator chose, so a screen can reopen the choices
    priced: dict[str, Any] | None = None  # the menu engine's snapshot at the time of sale, set by the hub
    fired_at: HLC | None = None  # the fire that sent this line to the kitchen
    stamps: dict[str, HLC] = field(default_factory=dict)

    @property
    def active(self) -> bool:
        return self.status == "active"


@dataclass
class Discount:
    """A price brought down after the engine set it: a percentage, an amount or a comp, on one line or
    the whole check, with its reason and who stood behind it. Removed ones stay, inactive, for the audit."""

    discount_id: str
    reason: str = ""
    kind: str = "percent"  # percent | amount | comp
    value: str = "0"
    line_id: str | None = None
    note: str = ""
    applied_by: str = ""
    approved_by: dict[str, Any] | None = None
    active: bool = True
    stamp: HLC | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "reason": self.reason,
            "kind": self.kind,
            "value": self.value,
            "line_id": self.line_id,
            "note": self.note,
            "applied_by": self.applied_by,
            "approved_by": self.approved_by,
            "active": self.active,
        }


@dataclass
class Charge:
    """A service charge staff put on (with the rule's snapshot the hub filled in), or an automatic one
    taken off: an inactive charge under a rule's code keeps that rule's charge off the check."""

    charge_id: str
    code: str = ""
    name: str = ""
    kind: str = "amount"  # percent | amount
    value: str = "0"
    tax_class: str = "service_charge"
    gratuity: bool = False
    applied_by: str = ""
    approved_by: dict[str, Any] | None = None
    active: bool = True
    stamp: HLC | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "name": self.name,
            "kind": self.kind,
            "value": self.value,
            "tax_class": self.tax_class,
            "gratuity": self.gratuity,
            "applied_by": self.applied_by,
            "approved_by": self.approved_by,
            "active": self.active,
        }


@dataclass
class OrderState:
    order_id: str
    status: str = "open"  # open | closed | void
    fields: dict[str, Any] = field(default_factory=dict)
    stamps: dict[str, HLC] = field(default_factory=dict)
    lines: dict[str, Line] = field(default_factory=dict)
    fired: dict[str, HLC] = field(default_factory=dict)  # course -> first fire stamp
    discounts: dict[str, Discount] = field(default_factory=dict)
    charges: dict[str, Charge] = field(default_factory=dict)
    applied: list[str] = field(default_factory=list)  # op ids in replay order
    first: HLC | None = None  # when the order was opened
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
                    "fired": line.fired_at is not None,
                    "request": line.request,
                    "priced": line.priced,
                }
                for line_id, line in sorted(self.lines.items())
            },
            "fired": {course: str(stamp) for course, stamp in sorted(self.fired.items())},
            "discounts": {did: d.as_json() for did, d in sorted(self.discounts.items())},
            "charges": {cid: c.as_json() for cid, c in sorted(self.charges.items())},
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
            request=data.get("request"),
            priced=data.get("priced"),
        )
        line.stamps = dict.fromkeys(LINE_FIELDS, op.hlc)
        line.modified_after_fire = state._fired_before(line.course)
        state.lines[line_id] = line

    elif kind == "set_line":
        line = state.lines.get(data["line_id"])
        if line is None or not line.active:
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
        if line.active:
            # Before the kitchen has it, a line just comes off the order (still in the log for the audit);
            # once it has been sent it is a void, which the kitchen is told about.
            line.status = "void" if line.fired_at is not None else "removed"
            line.void_reason = data.get("reason")
            if line.fired_at is not None:
                line.modified_after_fire = True

    elif kind == "fire":
        course = data.get("course", "*")
        state.fired.setdefault(course, op.hlc)
        for line in state.lines.values():
            if line.active and line.fired_at is None and (course == "*" or line.course == course):
                line.fired_at = op.hlc

    elif kind == "close":
        if state.status != "void":
            state.status = "closed"

    elif kind == "reopen":
        if state.status == "closed":
            state.status = "open"

    elif kind == "void_order":
        state.status = "void"

    elif kind == "discount":
        did = data["discount_id"]
        if did not in state.discounts:  # already there, or removed first: a removal always wins
            state.discounts[did] = Discount(
                discount_id=did,
                reason=str(data.get("reason", "")),
                kind=str(data.get("kind", "percent")),
                value=str(data.get("value", "0")),
                line_id=data.get("line_id"),
                note=str(data.get("note", "")),
                applied_by=str(data.get("applied_by", "")),
                approved_by=data.get("approved_by"),
                stamp=op.hlc,
            )

    elif kind == "remove_discount":
        did = data["discount_id"]
        discount = state.discounts.setdefault(did, Discount(discount_id=did, stamp=op.hlc))
        discount.active = False

    elif kind == "charge":
        cid = data["charge_id"]
        if cid not in state.charges:  # a removal always wins here too
            state.charges[cid] = Charge(
                charge_id=cid,
                code=str(data.get("code", cid)),
                name=str(data.get("name", "")),
                kind=str(data.get("kind", "amount")),
                value=str(data.get("value", "0")),
                tax_class=str(data.get("tax_class", "service_charge")),
                gratuity=bool(data.get("gratuity", False)),
                applied_by=str(data.get("applied_by", "")),
                approved_by=data.get("approved_by"),
                stamp=op.hlc,
            )

    elif kind == "remove_charge":
        cid = data["charge_id"]
        charge = state.charges.setdefault(cid, Charge(charge_id=cid, code=str(data.get("code", cid)), stamp=op.hlc))
        charge.active = False
        if data.get("approved_by") is not None:
            charge.approved_by = data["approved_by"]

    state.applied.append(op.op_id)
    if state.first is None:
        state.first = op.hlc
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
