"""What GloriaFood says of an order after it is on the POS, turned into what the POS writes for it.

GloriaFood can hand an order over more than once (docs/online-orders.md, "What GloriaFood says of an order
afterwards"). Set to "Send every time an order is updated", its integration gives the hub the same order
again whenever something of it changes: somebody marked it ready in GloriaFood's own app (`ready`), or it
was cancelled (`status`). `ops_after` reads such a copy beside the order as it stands on the POS and gives
the operations that make the POS say the same. Nothing here stores or prints: the hub does that with what
comes back (`pos.api.online`), as it does with a screen's operations.

**Ready.** An order marked ready in GloriaFood's app is ready on the POS: its `stage` goes from `new` to
`ready`, as when somebody presses Ready at the counter. Only forward: an order that is out with a driver,
picked up or closed stays where it is, and one that is ready is never made not ready by a later copy. It is
one way, too: the POS can tell GloriaFood nothing, so an order marked ready on the POS is not ready there.

**Cancelled.** An order GloriaFood says is cancelled (or rejected, or missed: the words in `OFF`) after it
went on the POS is **voided**: every dish the kitchen has is voided with the reason "Cancelled in
GloriaFood", so the stations that had it get their VOID tickets and it is in the report of voids, and then
the check itself is voided, so it is out of the lists and out of the day's sales. A dish that was never
sent to the kitchen stays on the voided check, as on any check voided whole: what it was worth is counted
with the voided checks. This is the restaurant's choice (Mike, 2026-11-25: "Void it and tell the kitchen"),
where the other way would have been a mark on the order for a manager to act on. The POS takes GloriaFood's
word for it: nobody types a PIN, which is why it is told to a manager at once (`After.said`, and a slip
where the bags are packed).

Three orders are **not** voided by themselves, because a person has done something with them that a void
would undo behind their back: one money was taken for at the POS, one that was picked up or has left with a
driver, and one that is closed. They are marked (`online.status`) and told of, and stay as they are.

What the website took for a cancelled order is not given back by the POS: the payment stays on the voided
check, where the day's report counts it under money taken on voided checks, and whoever cancelled it gives
it back where it was taken.

A word of GloriaFood's for what became of an order that is none of the ones its pages list (`unknown`)
changes nothing on the POS: no order is voided, and none made ready, on a word nobody here has read. The
hub keeps the copy and logs the word.

Every operation here has a fixed id, so what GloriaFood says twice is written once.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from ..sync.hlc import HLC
from ..sync.oplog import Op, OrderState
from .inbox import ACCEPTED, PENDING, status_of
from .place import BY, DEVICE

REASON = "online_cancelled"
"""The reason a dish voided here carries, where a person's void carries one from the location's list."""
CANCELLED = "Cancelled in GloriaFood"
"""That reason in words, as the report of voids and the check's history say it."""
OFF = {"canceled": "cancelled", "cancelled": "cancelled", "rejected": "rejected", "timed_out": "missed"}
"""What GloriaFood calls an order that is not to be made (any more), and the word a person is told."""
HANDED_OVER = {"picked_up": "it was picked up", "out": "it has left with a driver"}
"""The stages a cancelled order is left in, with why, in words."""


def off(order: Mapping[str, Any]) -> str:
    """How an order as GloriaFood gave it is off, in a word for a person ("cancelled", "rejected",
    "missed"); nothing for one that is accepted or still waits to be. Nothing either for a word of
    GloriaFood's this does not know (`unknown`): an order that is on the POS is not voided on a word nobody
    here has read. (One that is not on the POS yet does not go on with such a word:
    `pos.online.place.unaccepted`.)"""
    return OFF.get(status_of(order).strip().lower(), "")


def unknown(order: Mapping[str, Any]) -> str:
    """GloriaFood's word for what became of an order, tidied, when it is one this does not know: neither
    accepted or waiting, nor one of the words for an order that is off. Nothing for a word it knows."""
    status = status_of(order).strip().lower()
    if status in (ACCEPTED, PENDING) or status in OFF:
        return ""
    return re.sub(r"[^a-z0-9_]", "", status)[:30] or "?"


@dataclass(frozen=True)
class After:
    """What a later copy of an order changes on the POS."""

    ops: tuple[Op, ...] = ()
    said: str = ""  # what a manager should know of it; nothing when there is nothing to look at
    slip: bool = False  # whether a slip says so where the bags are packed
    voided: bool = False  # the POS voided the order

    def __bool__(self) -> bool:
        return bool(self.ops or self.said)


NOTHING = After()


def stands(state: OrderState) -> str:
    """Why an order that was cancelled is not voided by the hub itself, in words; nothing for one that is.
    A person has done something with it that a void would undo: taken money, handed it over, closed it."""
    order_id = state.order_id
    if any(payment_id != f"{order_id}:paid" for payment_id in state.payments):
        return "money was taken for it at the POS"
    stage = str(state.fields.get("stage") or "new")
    if stage in HANDED_OVER:
        return HANDED_OVER[stage]
    if state.status == "closed":
        return "it is closed"
    return ""


def ops_after(order: Mapping[str, Any], state: OrderState, *, stamp: Callable[[], HLC]) -> After:
    """What this copy of an order changes on the POS, where the order stands as `state`. `stamp` stamps
    each operation. Nothing for an order that is not on the POS as the hub's own, and nothing when the POS
    says it already."""
    online = state.fields.get("online")
    if state.first is None or not isinstance(online, Mapping):
        return NOTHING
    order_id = state.order_id
    made: list[Op] = []

    def write(name: str, kind: str, data: dict[str, Any]) -> None:
        made.append(Op(f"{order_id}:{name}", order_id, stamp(), DEVICE, kind, data))

    word = off(order)
    if word:
        status = status_of(order).strip().lower()  # one of `OFF`: GloriaFood's own word
        if online.get("status") == status:
            return NOTHING  # said already
        write(f"status-{status}", "set_field", {"online": {**online, "status": status}, "by": BY})
        if state.status == "void":
            return After(tuple(made))  # somebody voided it already: there is nothing left to tell
        why = stands(state)
        if why:
            return After(tuple(made), f"it was {word} in GloriaFood, and {why}: it is still on the POS", slip=True)
        sent = (line for line in state.ordered_lines() if line.active and line.fired_at is not None)
        for n, line in enumerate(sent, start=1):
            write(
                f"off-{n}",
                "void_line",
                {"line_id": line.line_id, "reason": REASON, "reason_name": CANCELLED, "by": BY},
            )
        write("off", "void_order", {"reason": CANCELLED, "by": BY})
        said = f"it was {word} in GloriaFood: the POS voided it"
        paid = state.payments.get(f"{order_id}:paid")  # what the website took, as the hub wrote it down
        if paid is not None:
            said += f"; the website took ${paid.amount} for it, which the POS does not give back"
        return After(tuple(made), said, slip=True, voided=True)

    if unknown(order):
        return NOTHING  # a word nobody here has read changes nothing, ready or not
    if order.get("ready") is True and state.status == "open" and "status" not in online:
        if str(state.fields.get("stage") or "new") == "new":
            # a delivery that is ready waits for its driver, a pickup for its customer: the same word
            write("ready", "set_field", {"stage": "ready", "by": BY})
            return After(tuple(made))
    return NOTHING


def slip_words(number: str, after_said: str, *, voided: bool, delivery: bool = False) -> list[str]:
    """The slip for a cancelled order, where the bags are packed: its headline, what happened, and what to
    do with the food."""
    if voided:
        last = "Stop making it. Do not send it out." if delivery else "Stop making it. Do not hand it over."
    else:
        last = "A manager decides what becomes of it: nothing was voided."
    return ["ONLINE ORDER CANCELLED", f"{number}: {after_said}.", last]


__all__ = ["CANCELLED", "NOTHING", "OFF", "REASON", "After", "off", "ops_after", "slip_words", "stands", "unknown"]
