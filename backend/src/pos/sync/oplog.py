"""The order operation log.

Terminals never overwrite an order. They append operations; the current order is the replay of its
operations in clock order, and merging two copies is the union of their operations. Everything a
hub, a terminal or the cloud needs to agree on is in this module, so it can be tested like a calculator.
"""

from __future__ import annotations

import math
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from typing import Any

from .hlc import HLC

MAX_DRIFT_MS = 5 * 60 * 1000
"""An operation stamped further than this into the future is refused; the device must resync its clock."""

KINDS = frozenset(
    {
        "create",  # data: any order fields
        "set_field",  # data: any order fields
        "add_line",  # data: line_id, item, qty?, seat?, course?, note?, rank?, request?, priced?, by?, by_id?
        "set_line",  # data: line_id + any line fields (a drag on the check: course and rank)
        "void_line",  # data: line_id, reason? (removes a line the kitchen has not seen, voids one it has)
        "fire",  # data: course ("*" = everything); sends that course's lines not yet sent
        "close",
        "reopen",
        "void_order",  # data: reason?
        "discount",  # data: discount_id, reason, kind (percent|amount|comp), value?, line_id?, note?, applied_by?
        "remove_discount",  # data: discount_id
        "charge",  # data: charge_id, code (a charge rule), + the rule's snapshot the hub fills in
        "remove_charge",  # data: charge_id (a rule's code takes off the automatic charge it applies)
        "pay",  # data: payment_id, method (cash|elsewhere|card), amount, tendered?, note?, by?
    }
)
"""Any kind may also carry `offline: true` in its data: the terminal stamped it while no backend answered
(ADR 6, capture-only mode). The replay ignores it; the printer heads the ticket "late" and reports list it.
A `discount`, `charge` or `remove_charge` may carry `approval`, a manager's token; the hub swaps it for
`approved_by` (who) before storing (pos.orders.adjustments)."""
ORDER_FIELDS = frozenset(
    {
        "table",
        "guests",
        "note",
        "order_type",
        "server",
        "server_id",
        "ticket_no",
        # Counter mode and takeout (architecture section 12): the hub numbers the order, the terminal names the
        # customer, the channel it came in on, when it was promised for and how long was quoted.
        "order_no",
        "customer_name",
        "phone",
        "channel",  # counter | phone | online | delivery | catering
        "promised_at",  # wall-clock ms; a future order waits on the hub until its lead time
        "quoted_minutes",
        "stage",  # new | ready | picked_up
        "locale",  # the customer's language for texts
    }
)
LINE_FIELDS = frozenset({"qty", "seat", "course", "note", "rank"})
KITCHEN_FIELDS = frozenset({"qty", "seat", "course", "note"})
"""The line fields the kitchen cares about. Changing the quantity, seat or note of a line it has marks the
line modified; a line not sent yet counts as a late addition while its course has already gone. A line's
`rank` (its place on the check) is not one, and neither is the course of a line already sent: a dish the
kitchen has can be arranged freely on the check and keeps its place on the ticket it went out on."""


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
    rank: float = 0.0  # its place on the check: lines show, print and are charged in rank order
    status: str = "active"  # active | removed (taken off before the kitchen saw it) | void (after)
    void_reason: str | None = None
    modified_after_fire: bool = False
    request: dict[str, Any] | None = None  # what the operator chose, so a screen can reopen the choices
    priced: dict[str, Any] | None = None  # the menu engine's snapshot at the time of sale, set by the hub
    replaces: str | None = None  # the line this one took the place of: an edit voids a line and adds the changed one
    by: str = ""  # who added it (name) and their staff id: several people can work one check, hands-free
    by_id: str | None = None
    added_at: HLC | None = None  # when it came onto the check: what a floor map times an unsent dish from
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
class Payment:
    """Money taken on the order: cash at the counter, or settled elsewhere (a phone order paid through
    another system). Refunds and card payments through a provider come with the payments phase."""

    payment_id: str
    method: str = "cash"  # cash | elsewhere | card
    amount: str = "0"
    tendered: str | None = None  # cash handed over; the change is tendered - amount
    note: str = ""
    by: str = ""
    stamp: HLC | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "method": self.method,
            "amount": self.amount,
            "tendered": self.tendered,
            "note": self.note,
            "by": self.by,
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
    payments: dict[str, Payment] = field(default_factory=dict)
    applied: list[str] = field(default_factory=list)  # op ids in replay order
    first: HLC | None = None  # when the order was opened
    last: HLC | None = None

    def ordered_lines(self) -> list[Line]:
        """The lines as the check shows them: by rank (the order they were added, until a drag moves one)."""
        return sorted(self.lines.values(), key=lambda line: (line.rank, line.line_id))

    def current_line(self, line_id: str) -> str:
        """The line that stands for `line_id` now: itself while it is active, otherwise the line that took
        its place (an edit voids a line and adds the changed one with `replaces`), followed through any
        number of edits. A discount on a dish stays with the dish that way. Unknown ids come back as they are."""
        replaced_by: dict[str, str] = {}
        for line in self.ordered_lines():
            if line.replaces and (line.replaces not in replaced_by or line.active):
                replaced_by[line.replaces] = line.line_id
        seen: set[str] = set()
        while line_id in replaced_by and line_id not in seen:
            line = self.lines.get(line_id)
            if line is not None and line.active:
                break
            seen.add(line_id)
            line_id = replaced_by[line_id]
        return line_id

    def snapshot(self) -> dict[str, Any]:
        """A plain, comparable picture of the order; two replicas agree when their snapshots are equal. The
        lines come in check order."""
        return {
            "order_id": self.order_id,
            "status": self.status,
            "fields": dict(sorted(self.fields.items())),
            "lines": {
                line.line_id: {
                    "item": line.item,
                    "qty": line.qty,
                    "seat": line.seat,
                    "course": line.course,
                    "note": line.note,
                    "rank": line.rank,
                    "status": line.status,
                    "void_reason": line.void_reason,
                    "modified_after_fire": line.modified_after_fire,
                    "fired": line.fired_at is not None,
                    "request": line.request,
                    "priced": line.priced,
                    "replaces": line.replaces,
                    "by": line.by,
                    "by_id": line.by_id,
                }
                for line in self.ordered_lines()
            },
            "fired": {course: str(stamp) for course, stamp in sorted(self.fired.items())},
            "discounts": {did: d.as_json() for did, d in sorted(self.discounts.items())},
            "charges": {cid: c.as_json() for cid, c in sorted(self.charges.items())},
            "payments": {pid: p.as_json() for pid, p in sorted(self.payments.items())},
        }

    def _fired_before(self, course: str | None) -> bool:
        return "*" in self.fired or (course is not None and course in self.fired)

    def course_gone(self, course: str | None) -> bool:
        """Whether this course has already been sent to the kitchen: a dish under it that has not been is a
        late addition, not a dish being held for its turn."""
        return self._fired_before(course)


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
            replaces=data.get("replaces") if isinstance(data.get("replaces"), str) else None,
            by=str(data.get("by") or ""),
            by_id=data.get("by_id") if isinstance(data.get("by_id"), str) else None,
        )
        rank = _rank(data.get("rank"))
        if rank is None:  # after everything on the check so far
            rank = max((other.rank for other in state.lines.values()), default=0.0) + 1
        line.rank = rank
        line.stamps = dict.fromkeys(LINE_FIELDS, op.hlc)
        line.added_at = op.hlc
        line.modified_after_fire = state._fired_before(line.course)
        state.lines[line_id] = line

    elif kind == "set_line":
        line = state.lines.get(data["line_id"])
        if line is None or not line.active:
            return  # unknown line, or a void: a void always wins
        for name in LINE_FIELDS:
            if name in data and line.stamps.get(name, _MIN) <= op.hlc:
                value = _rank(data[name]) if name == "rank" else data[name]
                if value is None and name == "rank":
                    continue  # not a number: the line keeps its place
                setattr(line, name, value)
                line.stamps[name] = op.hlc
        if not KITCHEN_FIELDS & data.keys():
            return  # its place on the check alone: nothing the kitchen hears about
        if line.fired_at is None:
            # not sent yet: it is a late addition while it sits under a course that has already gone
            line.modified_after_fire = state._fired_before(line.course)
        elif (KITCHEN_FIELDS - {"course"}) & data.keys():
            # the kitchen is cooking it: a new quantity, seat or note is a change it hears about; a new
            # course on the check is not (Mike, 2026-11-02): the dish stays on the ticket it went out on
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

    elif kind == "pay":
        pid = data["payment_id"]
        if pid not in state.payments:  # the same payment sent twice is one payment
            state.payments[pid] = Payment(
                payment_id=pid,
                method=str(data.get("method", "cash")),
                amount=str(data.get("amount", "0")),
                tendered=None if data.get("tendered") is None else str(data["tendered"]),
                note=str(data.get("note", "")),
                by=str(data.get("by", "")),
                stamp=op.hlc,
            )

    state.applied.append(op.op_id)
    if state.first is None:
        state.first = op.hlc
    state.last = op.hlc


_MIN = HLC(0, 0, "")


def _rank(value: Any) -> float | None:
    """A rank as a terminal sent it, or None when it is not a finite number (a sort must never fail on it)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


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


@dataclass(frozen=True)
class OrderEntry:
    """What the orders index keeps of one order, so a list can pick its orders without replaying the log:
    where it stands, when it was opened and when it last changed (wall-clock ms), and how far its history
    goes: `version`, the log's cursor when its newest operation arrived, and `tip`, that operation's id. The
    two move whenever the order changes and never otherwise, so an order replayed at one (version, tip) is
    good until they move. The tip is there for a hub whose database is rewound after a takeover: a cursor
    alone could come to mean another history."""

    order_id: str
    status: str
    first_ms: int | None
    last_ms: int | None
    version: int
    tip: str

    @staticmethod
    def of(state: OrderState, version: int, tip: str) -> OrderEntry:
        return OrderEntry(
            order_id=state.order_id,
            status=state.status,
            first_ms=state.first.wall_ms if state.first is not None else None,
            last_ms=state.last.wall_ms if state.last is not None else None,
            version=version,
            tip=tip,
        )

    def picked(self, status: str | None, opened_since: int | None, active_since: int | None) -> bool:
        """Whether a list asking for this status, opened since then and changed since then wants the order."""
        if status is not None and self.status != status:
            return False
        if opened_since is not None and (self.first_ms is None or self.first_ms < opened_since):
            return False
        return active_since is None or (self.last_ms is not None and self.last_ms >= active_since)


class Views:
    """Replayed orders, kept until they change: the screens ask for the open orders every two seconds, and
    an order nobody touched replays to the same thing every time. Each is kept under the (version, tip) it
    was replayed at, the least recently read go first, and what comes out is shared: read it, never change it
    (`state` on a store replays a fresh one for that)."""

    def __init__(self, keep: int = 2048) -> None:
        self._keep = keep
        self._kept: OrderedDict[str, tuple[int, str, OrderState]] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, entry: OrderEntry) -> OrderState | None:
        with self._lock:
            kept = self._kept.get(entry.order_id)
            if kept is None or (kept[0], kept[1]) != (entry.version, entry.tip):
                return None
            self._kept.move_to_end(entry.order_id)
            return kept[2]

    def put(self, order_id: str, version: int, tip: str, state: OrderState) -> None:
        with self._lock:
            self._kept[order_id] = (version, tip, state)
            self._kept.move_to_end(order_id)
            while len(self._kept) > self._keep:
                self._kept.popitem(last=False)


class OpStore:
    """An append-only store of operations with a cursor, so peers can pull what they have not seen, and an
    index of its orders (`index`, `entry`) with their replays kept until they change (`view`, `views`), so
    reading the open orders costs nothing while nothing changes."""

    def __init__(self, physical: Callable[[], int] | None = None) -> None:
        self._ops: list[Op] = []
        self._ids: set[str] = set()
        self._by_order: dict[str, list[Op]] = {}
        self._versions: dict[str, tuple[int, str]] = {}  # order -> the cursor and id of its newest arrival
        self._entries: dict[str, OrderEntry] = {}  # worked out when first asked for, again after a change
        self._views = Views()
        self._physical = physical or (lambda: int(time.time() * 1000))

    @property
    def cursor(self) -> int:
        return len(self._ops)

    def now_ms(self) -> int:
        """The store's wall clock, the one operations are checked against."""
        return self._physical()

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
            self._by_order.setdefault(op.order_id, []).append(op)
            self._versions[op.order_id] = (len(self._ops), op.op_id)
            accepted.append(op)
        return accepted

    def since(self, cursor: int, limit: int | None = None) -> list[Op]:
        end = None if limit is None else cursor + limit
        return self._ops[cursor:end]

    def arrivals(self, cursor: int, limit: int = 2000) -> list[tuple[int, str]]:
        """Where each operation after `cursor` landed and whose it is, oldest first: `(cursor, order id)`.
        What the change feed tells the screens, without reading the operations themselves."""
        return [(at, op.order_id) for at, op in enumerate(self._ops[cursor : cursor + limit], start=cursor + 1)]

    def for_order(self, order_id: str) -> list[Op]:
        return list(self._by_order.get(order_id, ()))

    def order_ids(self) -> list[str]:
        return sorted(self._by_order)

    def state(self, order_id: str) -> OrderState:
        """The order, replayed now: the caller's own copy, to change as it likes (`view` for a shared one)."""
        return replay(self.for_order(order_id), order_id)

    def op_ids(self) -> frozenset[str]:
        return frozenset(self._ids)

    def entry(self, order_id: str) -> OrderEntry | None:
        """The index's row for one order, or None for an order the log has never heard of."""
        stamp = self._versions.get(order_id)
        if stamp is None:
            return None
        entry = self._entries.get(order_id)
        if entry is None or (entry.version, entry.tip) != stamp:
            state = replay(self._by_order[order_id], order_id)
            entry = self._entries[order_id] = OrderEntry.of(state, *stamp)
            self._views.put(order_id, *stamp, state)
        return entry

    def index(
        self, *, status: str | None = None, opened_since: int | None = None, active_since: int | None = None
    ) -> list[OrderEntry]:
        """The orders that stand at `status`, were opened at or after `opened_since` and last changed at or
        after `active_since` (wall-clock ms), whichever of the three are given, by order id."""
        entries = (self.entry(order_id) for order_id in sorted(self._by_order))
        return [e for e in entries if e is not None and e.picked(status, opened_since, active_since)]

    def views(self, entries: Sequence[OrderEntry]) -> list[OrderState]:
        """The orders of these index rows, in the same order, each replayed only if it changed since it was
        last read. Shared: read them, never change them."""
        out: list[OrderState] = []
        for entry in entries:
            state = self._views.get(entry)
            if state is None:
                state = replay(self._by_order[entry.order_id], entry.order_id)
                self._views.put(entry.order_id, *self._versions[entry.order_id], state)
            out.append(state)
        return out

    def view(self, order_id: str) -> OrderState | None:
        """One order as it stands, replayed only if it changed since it was last read; None for an order the
        log has never heard of. Shared: read it, never change it."""
        entry = self.entry(order_id)
        return None if entry is None else self.views([entry])[0]
