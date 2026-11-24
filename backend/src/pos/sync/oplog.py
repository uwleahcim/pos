"""The order operation log.

Terminals never overwrite an order. They append operations; the current order is the replay of its
operations in clock order, and merging two copies is the union of their operations. Everything a
hub, a terminal or the cloud needs to agree on is in this module, so it can be tested like a calculator.
"""

from __future__ import annotations

import math
import re
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from .hlc import HLC

MAX_DRIFT_MS = 5 * 60 * 1000
"""An operation stamped further than this into the future is refused; the device must resync its clock."""

KINDS = frozenset(
    {
        "create",  # data: any order fields
        "set_field",  # data: any order fields
        # A dish that came from another check also names where from (`from`: order_id, line_id; the hub adds
        # that check's table) and, when the kitchen already has it, when it was sent (`sent`, a stamp).
        # data: line_id, item, qty?, seat?, course?, note?, rank?, request?, priced?, by?, by_id?, went_with? (the
        # dish whose suggestion this one was taken from: docs/goes-with.md)
        "add_line",
        # A dish going to another check (pos.orders.moves): this check lets it go, the other takes it with an
        # `add_line` that names where it came from. No void: the kitchen has cooked it or will, and it is
        # still to be paid for, over there.
        "move_line",  # data: line_id, to (order_id, line_id), by?, by_id?
        # data: line_id + any line fields (a drag on the check: course and rank), by?, by_id? (who, when it
        # changes how many: fewer of a dish the kitchen has not seen is in the report of dishes taken off)
        "set_line",
        # void_line removes a line the kitchen has not seen and voids one it has. A void of a sent line says
        # why (a reason from the location's list) and who (`by`, `by_id`); the hub adds the reason's name
        # and the manager who approved it (pos.orders.voids). Taking off an unsent line says who as well,
        # for the report of dishes taken off before sending (pos.orders.taken_off).
        "void_line",  # data: line_id, reason?, by?, by_id?, reason_name?, approved_by?
        "fire",  # data: course ("*" = everything); sends that course's lines not yet sent
        "close",
        "reopen",
        "void_order",  # data: reason?
        "discount",  # data: discount_id, reason, kind (percent|amount|comp), value?, line_id?, note?, applied_by?
        "remove_discount",  # data: discount_id
        "charge",  # data: charge_id, code (a charge rule), + the rule's snapshot the hub fills in
        "remove_charge",  # data: charge_id (a rule's code takes off the automatic charge it applies)
        # `check` names the one of a split table's checks the money was for (pos.orders.split)
        "pay",  # data: payment_id, method (cash|elsewhere|card), amount, tendered?, note?, by?, check?
        # An allergy a guest told the server of, for one seat or (no seat) the whole table: the allergens by
        # the menu's codes and whatever else was said, in words. One with neither takes the allergy off.
        "allergy",  # data: seat?, allergens?, note?, by?, by_id?
        # A station's screen says it has made dishes, or takes that back (pos.printing.screen). It is the
        # kitchen's own word beside the check: no dish, price or payment changes by it.
        "done",  # data: station, line_ids, done? (false takes it back), by?, by_id?
    }
)
"""Any kind may also carry `offline: true` in its data: the terminal stamped it while no backend answered
(ADR 6, capture-only mode). The replay ignores it; the printer heads the ticket "late" and reports list it.
A `discount`, `charge`, `remove_charge` or `void_line` may carry `approval`, a manager's token; the hub swaps
it for `approved_by` (who) before storing (pos.orders.adjustments, pos.orders.voids). So may a `set_field`
that marks the check tax exempt (pos.orders.exempt)."""
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
        "for_later",  # the customer named the time: a big order or a rush starts it sooner, never moves it
        # new | ready | out | picked_up. `out` is a delivery's alone: it left with a driver (docs/delivery.md)
        "stage",
        "locale",  # the customer's language for texts
        # How the table pays (pos.orders.split): {by: seat} a check for each seat, {by: dish} the dishes
        # put on checks by hand, {by: even, ways: n} the total in n equal parts; anything else is one check.
        "split",
        # The check every dish of this one went to when its table joined another's (an order id): this
        # check was closed empty, and its history says where to look.
        "merged_into",
        # A bar tab (true): a check opened with a name (`customer_name`) and no table. It is a tab until it is
        # given a table, when it becomes that table's check; the word stays, to say how the check began.
        "tab",
        # A check a manager marked exempt from sales tax (pos.orders.exempt): the organisation, the number of
        # its certificate, who marked it and the manager who approved. Only the hub writes it, after the PIN.
        "tax_exempt",
        # What goes in the bag with a to-go order (pos.orders.bag): the answer to the one question asked
        # before it is sent, {items: [{id, name, qty}]}. No items: nothing was wanted.
        "bag",
        # An order for an event (pos.orders.ahead): how many it feeds, how it leaves (pickup | delivery),
        # where it is brought when it is delivered, and a line about the event (set up by 11:30, side
        # door). The head count is not `guests`: that is a table's, which the reports count as covers and
        # the automatic charges go by, and neither is meant for an order that leaves in trays.
        "event_guests",
        "handover",
        "address",
        "event_note",
        # Who a delivery was handed to (docs/delivery.md): the driver's name and staff id, and when it left
        # (wall-clock ms). Deliveries handed over in one go carry the same `out_at`: that is a run.
        "driver",
        "driver_id",
        "out_at",
        # What a delivery costs the customer (pos.orders.delivery_fee): the band it was picked by and what
        # that band cost then, {by, up_to, amount, taxed}; {up_to: null, amount: "0.00"} is no fee on
        # purpose. A screen says only the band, and the hub fills in the rest. Charged only while the order
        # is a delivery.
        "delivery_fee",
        # An order that came from the restaurant's website (pos.online.place): where from, the website's
        # own number for it, how the customer chose to pay and what they were charged, {source, id, type,
        # payment, total}; and, of a restaurant with several accounts there, which one brought it, what the
        # restaurant calls it and that it is the one for testing, {account, store, test}. Only the hub
        # writes it.
        "online",
    }
)
ALLERGY_NOTE_MAX = 80
"""How long the words of an allergy may be: a line of a kitchen ticket and a little more."""
LINE_FIELDS = frozenset({"qty", "seat", "course", "note", "rank", "checks"})
"""`checks` is which of a split table's checks a dish is on (several: shared between them in equal parts).
Like `rank` it is the check's business alone: the kitchen hears nothing when a sent dish changes checks."""
MAX_CHECKS = 20
"""The most checks one table splits into: a check's number, and the ways of an even split, stop here."""
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
    # active | removed (taken off before the kitchen saw it, or gone to another check: `moved_to`) | void
    # (taken off after the kitchen had it)
    status: str = "active"
    void_reason: str | None = None
    # For a line voided after the kitchen had it: why (the reason's id and the name it had then), who
    # (`by`, `by_id`), the manager who approved it (`approved_by`, or None) and when (`at_ms`).
    voided: dict[str, Any] | None = None
    # For a line taken off before the kitchen saw it: who (`by`, `by_id`; empty from an app that did not
    # say), on which screen (`device`) and when (`at_ms`).
    removed: dict[str, Any] | None = None
    # Each time fewer of the dish were kept before it was sent: how many came off (`qty`), with the same
    # who, where and when. More of it again takes no cut back: both happened.
    cuts: list[dict[str, Any]] = field(default_factory=list)
    modified_after_fire: bool = False
    request: dict[str, Any] | None = None  # what the operator chose, so a screen can reopen the choices
    priced: dict[str, Any] | None = None  # the menu engine's snapshot at the time of sale, set by the hub
    replaces: str | None = None  # the line this one took the place of: an edit voids a line and adds the changed one
    by: str = ""  # who added it (name) and their staff id: several people can work one check, hands-free
    by_id: str | None = None
    # The dish (its item code) whose suggestion this one was added from, on the tray "Goes with ..."; None
    # for a dish rung any other way. It changes nothing about the line: a report reads it (docs/goes-with.md).
    went_with: str | None = None
    # The checks of a split table this dish was put on by hand, by number; None while nobody did, and
    # the split's own rule places it (its seat's check, or the first).
    checks: list[int] | None = None
    # For a dish that went to another check: where (`order_id`, `line_id` there), with who moved it, on
    # which screen and when. It is off this check like a removed one, whether the kitchen had it or not,
    # and it is no void and no dish taken off: it is on the other check, to be paid for there.
    moved_to: dict[str, Any] | None = None
    # For a dish that came from another check: `order_id`, `line_id` and the `table` that check stood at.
    moved_from: dict[str, Any] | None = None
    arrived_sent: bool = False  # it came already sent: the kitchen has it on a ticket of the other check
    # The stations whose screen marked this dish made, each with when (wall-clock ms); a station that took
    # its word back is not in it. `done_stamps` is the last word of each station, to tell which stands.
    done: dict[str, int] = field(default_factory=dict)
    done_stamps: dict[str, HLC] = field(default_factory=dict)
    added_at: HLC | None = None  # when it came onto the check: what a floor map times an unsent dish from
    fired_at: HLC | None = None  # the fire that sent this line to the kitchen
    stamps: dict[str, HLC] = field(default_factory=dict)

    @property
    def active(self) -> bool:
        return self.status == "active"

    @property
    def moved(self) -> bool:
        """Whether the dish went to another check (it is `removed` here, and neither voided nor taken off)."""
        return self.moved_to is not None


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
    # For a discount that came along with its dish from another check: `order_id`, `discount_id` there.
    carried_from: dict[str, Any] | None = None
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
            # only on a discount that came from another check: every other reads as it always did
            **({} if self.carried_from is None else {"from": self.carried_from}),
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
    check: int | None = None  # the check of a split table it was for; None: for the table
    stamp: HLC | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "method": self.method,
            "amount": self.amount,
            "tendered": self.tendered,
            "note": self.note,
            "by": self.by,
            # only on a payment that names one of a split table's checks: every other reads as it always did
            **({} if self.check is None else {"check": self.check}),
        }


def is_tab(fields: Mapping[str, Any]) -> bool:
    """Whether an order with these fields is a bar tab that has not sat down: opened as a tab, eaten in, and
    at no table. Called by the name on it (`customer_name`), it is on no floor map; given a table, it is that
    table's check from then on."""
    eaten_in = str(fields.get("order_type") or "dine_in") == "dine_in"
    return fields.get("tab") is True and eaten_in and not fields.get("table")


def is_delivery(fields: Mapping[str, Any]) -> bool:
    """Whether an order with these fields is brought to the customer (docs/delivery.md): a to-go order whose
    `handover` is delivery, with the `address` it goes to. A table's check never is, whatever it carries."""
    to_go = str(fields.get("order_type") or "dine_in") != "dine_in"
    return to_go and fields.get("handover") == "delivery"


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
    # The allergies told at the table, by seat (0 is the whole table): `allergens` by the menu's codes, a
    # `note` in words, and who took it (`by`, `by_id`). The latest word on a seat stands; seats do not
    # overwrite each other, so two screens noting two seats both count.
    allergies: dict[int, dict[str, Any]] = field(default_factory=dict)
    allergy_stamps: dict[int, HLC] = field(default_factory=dict)
    applied: list[str] = field(default_factory=list)  # op ids in replay order
    first: HLC | None = None  # when the order was opened
    last: HLC | None = None
    closed_at: HLC | None = None  # when it was last closed (kept while it is reopened: `status` says which)

    @property
    def is_tab(self) -> bool:
        """A bar tab that has not sat down (`is_tab`)."""
        return is_tab(self.fields)

    @property
    def tab_name(self) -> str:
        """The name on the tab while this check is one, in one line; empty for any other check."""
        return " ".join(str(self.fields.get("customer_name") or "").split()) if self.is_tab else ""

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

    def allergy_list(self) -> list[dict[str, Any]]:
        """The allergies on the order, the table's first, then by seat."""
        return [self.allergies[seat] for seat in sorted(self.allergies)]

    def allergens_for(self, seat: int | None) -> list[str]:
        """The allergens a dish for this seat must be kept from: the table's and the seat's own, by code."""
        own = self.allergies.get(seat, {}) if seat else {}
        return list(dict.fromkeys([*self.allergies.get(0, {}).get("allergens", ()), *own.get("allergens", ())]))

    def allergy_conflicts(self, line: Line) -> list[str]:
        """The allergens noted for this line's seat or the table that the menu says its dish contains, as it
        was sold (`priced.contains`). Empty says only that the menu names none: it is no promise of a dish
        without them."""
        contains = set((line.priced or {}).get("contains") or ())
        return [code for code in self.allergens_for(line.seat) if code in contains]

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
                    "voided": line.voided,
                    "modified_after_fire": line.modified_after_fire,
                    "fired": line.fired_at is not None,
                    # when the kitchen got it: the clock of the screen that sent it. A dish that came over
                    # from another check already sent keeps the time it was sent there.
                    "sent_ms": line.fired_at.wall_ms if line.fired_at is not None else None,
                    "request": line.request,
                    "priced": line.priced,
                    "replaces": line.replaces,
                    "by": line.by,
                    "by_id": line.by_id,
                    "went_with": line.went_with,
                    "checks": line.checks,
                    "moved_to": line.moved_to,
                    "moved_from": line.moved_from,
                    "allergy": self.allergy_conflicts(line),
                    "done": dict(sorted(line.done.items())),
                }
                for line in self.ordered_lines()
            },
            "allergies": self.allergy_list(),
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
            went_with=_went_with(data.get("went_with")),
            checks=_checks(data.get("checks")),
        )
        if line.checks is None and line.replaces in state.lines:
            # an edit voids a dish and adds the changed one: it stays on the checks the dish was put on
            line.checks = state.lines[line.replaces].checks
        if line.went_with is None and line.replaces in state.lines:
            # and it is still the dish that was taken from a suggestion
            line.went_with = state.lines[line.replaces].went_with
        rank = _rank(data.get("rank"))
        if rank is None:  # after everything on the check so far
            rank = max((other.rank for other in state.lines.values()), default=0.0) + 1
        line.rank = rank
        line.stamps = dict.fromkeys(LINE_FIELDS, op.hlc)
        line.added_at = op.hlc
        line.modified_after_fire = state._fired_before(line.course)
        line.moved_from = _other(data.get("from"), "table", "tab")
        sent = _stamp(data.get("sent")) if line.moved_from is not None else None
        if sent is not None:
            # it came from another check already sent: the kitchen has it, on that check's ticket, so no
            # fire here sends it again and nothing about it is late
            line.fired_at, line.arrived_sent, line.modified_after_fire = sent, True, False
            # and what its stations had already made of it stays made: nothing comes back onto a screen
            line.done = _made(data.get("done"))
            line.done_stamps = dict.fromkeys(line.done, op.hlc)
        state.lines[line_id] = line

    elif kind == "set_line":
        line = state.lines.get(data["line_id"])
        if line is None or not line.active:
            return  # unknown line, or a void: a void always wins
        for name in LINE_FIELDS:
            if name in data and line.stamps.get(name, _MIN) <= op.hlc:
                value = _rank(data[name]) if name == "rank" else data[name]
                if name == "checks":
                    value = _checks(value)  # nothing usable puts the dish back where the split places it
                if value is None and name == "rank":
                    continue  # not a number: the line keeps its place
                if name == "qty" and line.fired_at is None:
                    # fewer of a dish the kitchen has not seen: they came off the check, and the log says so
                    fewer = _count(line.qty) - _count(value)
                    if fewer > 0:
                        line.cuts.append({"qty": fewer, **_who(op)})
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
                approved = data.get("approved_by")
                line.voided = {
                    "reason": data.get("reason"),
                    "reason_name": str(data.get("reason_name") or ""),
                    "by": str(data.get("by") or ""),
                    "by_id": data.get("by_id") if isinstance(data.get("by_id"), str) else None,
                    "approved_by": approved if isinstance(approved, dict) else None,
                    "at_ms": op.hlc.wall_ms,
                }
            else:
                line.removed = _who(op)

    elif kind == "move_line":
        line_id = data["line_id"]
        line = state.lines.get(line_id)
        if line is None:  # the move reached the log before its dish: the dish is gone when it comes
            line = Line(line_id=line_id, item=str(data.get("item") or ""))
            state.lines[line_id] = line
        to = _other(data.get("to"))
        if line.active and to is not None:
            line.status = "removed"
            line.moved_to = {**to, **_who(op)}

    elif kind == "allergy":
        seat = data.get("seat")
        key = seat if isinstance(seat, int) and not isinstance(seat, bool) and seat > 0 else 0
        if state.allergy_stamps.get(key, _MIN) <= op.hlc:
            state.allergy_stamps[key] = op.hlc
            listed = data.get("allergens")
            codes = [a.strip() for a in listed if isinstance(a, str)] if isinstance(listed, list | tuple) else []
            allergens = list(dict.fromkeys(code for code in codes if code))
            note = " ".join(str(data.get("note") or "").split())[:ALLERGY_NOTE_MAX]
            if allergens or note:
                state.allergies[key] = {
                    "seat": key or None,
                    "allergens": allergens,
                    "note": note,
                    "by": str(data.get("by") or ""),
                    "by_id": data.get("by_id") if isinstance(data.get("by_id"), str) else None,
                }
            else:
                state.allergies.pop(key, None)

    elif kind == "done":
        station, ids = data.get("station"), data.get("line_ids")
        if isinstance(station, str) and station and isinstance(ids, list | tuple):
            made = data.get("done") is not False
            for line_id in ids:
                line = state.lines.get(line_id) if isinstance(line_id, str) else None
                # the latest word of a station on a dish stands; a dish this check never had is not marked
                if line is None or line.done_stamps.get(station, _MIN) > op.hlc:
                    continue
                line.done_stamps[station] = op.hlc
                if made:
                    line.done[station] = op.hlc.wall_ms
                else:
                    line.done.pop(station, None)

    elif kind == "fire":
        course = data.get("course", "*")
        state.fired.setdefault(course, op.hlc)
        for line in state.lines.values():
            if line.active and line.fired_at is None and (course == "*" or line.course == course):
                line.fired_at = op.hlc

    elif kind == "close":
        if state.status == "open":
            state.closed_at = op.hlc  # a second close of a closed check changes nothing, its time neither
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
                carried_from=_other(data.get("from"), id_field="discount_id"),
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
                check=(_checks(data.get("check")) or [None])[0],
                stamp=op.hlc,
            )

    state.applied.append(op.op_id)
    if state.first is None:
        state.first = op.hlc
    state.last = op.hlc


_MIN = HLC(0, 0, "")


def _who(op: Op) -> dict[str, Any]:
    """Who took a dish off the check before it was sent, on which screen and when, as the operation says."""
    by_id = op.data.get("by_id")
    return {
        "by": str(op.data.get("by") or ""),
        "by_id": by_id if isinstance(by_id, str) else None,
        "device": op.device,
        "at_ms": op.hlc.wall_ms,
    }


def _other(value: Any, *also: str, id_field: str = "line_id") -> dict[str, Any] | None:
    """Where on another check a dish (or with `id_field` a discount) is or was, as an operation names it:
    `order_id` and its id there, with whichever of `also` it says in words. None for anything else."""
    if not isinstance(value, dict):
        return None
    order_id, ident = value.get("order_id"), value.get(id_field)
    if not isinstance(order_id, str) or not order_id or not isinstance(ident, str) or not ident:
        return None
    out: dict[str, Any] = {"order_id": order_id, id_field: ident}
    for name in also:
        if isinstance(value.get(name), str):
            out[name] = value[name]
    return out


def _stamp(value: Any) -> HLC | None:
    """A stamp as an operation carries it in words, or None when it is not one."""
    if not isinstance(value, str):
        return None
    try:
        return HLC.parse(value)
    except ValueError:
        return None


def _count(value: Any) -> int:
    """How many of a dish, as a terminal sent it; 0 for anything that is not a whole number."""
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


WENT_WITH_MAX = 120
"""The longest item code kept as the dish a suggestion was taken from."""


def _went_with(value: Any) -> str | None:
    """The dish a suggested one went with, as a terminal says it: an item code. None for anything else."""
    return value if isinstance(value, str) and 0 < len(value) <= WENT_WITH_MAX else None


def _checks(value: Any) -> list[int] | None:
    """The checks a terminal put a dish on, as numbers from 1 to `MAX_CHECKS`, each once, lowest first; one
    number alone counts as a list of one. None for anything else, and for none at all."""
    listed = value if isinstance(value, list | tuple) else [value]
    numbers = {n for n in listed if isinstance(n, int) and not isinstance(n, bool) and 1 <= n <= MAX_CHECKS}
    return sorted(numbers) or None


def _made(value: Any) -> dict[str, int]:
    """The stations that had made a dish before it changed checks, each with when, as the hub read them
    from the check it came from; anything else is nobody."""
    if not isinstance(value, dict):
        return {}
    return {
        station: at
        for station, at in value.items()
        if isinstance(station, str) and station and isinstance(at, int) and not isinstance(at, bool)
    }


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


_NOT_DIGITS = re.compile(r"\D")


def phone_digits(raw: object) -> str:
    """A number as digits only, without the North American country code: `+1 (781) 555-1234`,
    `17815551234` and `781 555 1234` are all `7815551234`. Nothing for no number."""
    digits = _NOT_DIGITS.sub("", str(raw or ""))
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    return digits


def promised_ms(raw: Any) -> int | None:
    """The time an order is wanted for, as the index keeps it: wall-clock ms, None when the order has none
    or what it carries is no time at all (a screen can send anything: the index has to take it)."""
    if isinstance(raw, bool) or not isinstance(raw, int | float) or not 0 < raw < _NO_SUCH_TIME:
        return None
    return int(raw)


_NO_SUCH_TIME = 10**14  # wall-clock ms some three thousand years on: well inside what a calendar can say


@dataclass(frozen=True)
class OrderEntry:
    """What the orders index keeps of one order, so a list can pick its orders without replaying the log:
    where it stands, when it was opened and when it last changed (wall-clock ms), and how far its history
    goes: `version`, the log's cursor when its newest operation arrived, and `tip`, that operation's id. The
    two move whenever the order changes and never otherwise, so an order replayed at one (version, tip) is
    good until they move. The tip is there for a hub whose database is rewound after a takeover: a cursor
    alone could come to mean another history. `phone` is the customer's number as digits (`phone_digits`),
    empty for an order without one: what finds a caller's earlier orders, however old. `promised_ms` is the
    time an order is wanted for (its `promised_at`), None for one without: what finds the orders rung on
    an earlier day for a given one, whatever has happened to them since."""

    order_id: str
    status: str
    first_ms: int | None
    last_ms: int | None
    version: int
    tip: str
    phone: str = ""
    promised_ms: int | None = None

    @staticmethod
    def of(state: OrderState, version: int, tip: str) -> OrderEntry:
        return OrderEntry(
            order_id=state.order_id,
            status=state.status,
            first_ms=state.first.wall_ms if state.first is not None else None,
            last_ms=state.last.wall_ms if state.last is not None else None,
            version=version,
            tip=tip,
            phone=phone_digits(state.fields.get("phone")),
            promised_ms=promised_ms(state.fields.get("promised_at")),
        )

    def picked(
        self,
        status: str | None,
        opened_since: int | None,
        active_since: int | None,
        phone: str | None = None,
        promised: tuple[int, int] | None = None,
    ) -> bool:
        """Whether a list asking for this status, opened since then, changed since then, of this number
        (digits) and promised from one moment up to another wants the order."""
        if status is not None and self.status != status:
            return False
        if phone is not None and self.phone != phone:
            return False
        if promised is not None and (self.promised_ms is None or not promised[0] <= self.promised_ms < promised[1]):
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
        self,
        *,
        status: str | None = None,
        opened_since: int | None = None,
        active_since: int | None = None,
        phone: str | None = None,
        promised: tuple[int, int] | None = None,
    ) -> list[OrderEntry]:
        """The orders that stand at `status`, were opened at or after `opened_since`, last changed at or
        after `active_since` (wall-clock ms), carry the number `phone` (digits, see `phone_digits`) and are
        promised for a time from `promised[0]` up to, not at, `promised[1]`, whichever of the five are
        given, by order id."""
        entries = (self.entry(order_id) for order_id in sorted(self._by_order))
        return [e for e in entries if e is not None and e.picked(status, opened_since, active_since, phone, promised)]

    def with_phone(self) -> list[OrderEntry]:
        """Every order that carries a customer's number, however old, by order id: what a list of the
        customers is read from."""
        return [entry for entry in self.index() if entry.phone]

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
