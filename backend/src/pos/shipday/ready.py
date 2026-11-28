"""A check marked Ready on the POS, and Shipday told that its delivery is ready for pickup.

The restaurant chose this (Mike, 2026-11-28, on the question how Shipday's driver is told a delivery is ready
for pickup): "By itself when the check is Ready", which the question put as "When a delivery's check is
marked Ready on the POS, the hub tells Shipday it is ready for pickup. A button on the Shipday screen stays
for the odd one."

This is the one thing the hub tells Shipday by itself. Everything else it changes there is tapped by a
person on the Shipday screen (`pos.shipday.board`), and so is this one for a delivery the hub found no check
for, or one whose check nobody marks.

**Which delivery is told** (`waits`, and the hub's own part in `pos.api.shipday`): one Shipday lists that
has not been picked up there, that the hub matched to a check here (`pos.shipday.match`), whose check is an
open delivery standing at Ready, and that has not been told yet. Who marked the check Ready makes no
difference: a person at a screen, or the website's own word for it (`pos.online.after`).

**Once.** That Shipday was told is written on the check (`FIELD`: Shipday's id of the delivery and when),
by an operation with a fixed id, after Shipday answered that it is. Shipday's own list never says whether a
delivery was marked ready, so the check is where it is kept: a hub that restarted, and the location's other
hub, read it there and tell nothing twice. A check taken back from Ready and marked Ready again is not told
again: Shipday has no call that takes the word back, and it was told.

**Nothing else moves.** The check is Ready already; no text is sent (a delivery that is ready is brought,
the customer is not asked to come); and what Shipday says back moves the check as before
(`pos.shipday.follow`).

The same field is written when a person taps Ready for pickup on the Shipday screen and the delivery has a
check, so the check's history says who told Shipday and the hub does not tell it a second time.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any

from ..sync.hlc import HLC
from ..sync.oplog import Op, OrderState, is_delivery
from .follow import BY, DEVICE
from .follow import READY_FIELD as FIELD

# `FIELD` (`shipday_ready`) is the order field that keeps that Shipday was told a delivery is ready for
# pickup, which only the hub writes: `{id, at_ms, auto}`: Shipday's own id of the delivery, when Shipday
# answered that it is, and whether the hub told it by itself (a person tapped it otherwise).


def waits(state: OrderState) -> bool:
    """Whether a check is one whose delivery is ready for its driver: an open delivery marked Ready that
    has not left."""
    if state.first is None or state.status != "open" or not is_delivery(state.fields):
        return False
    return str(state.fields.get("stage") or "new") == "ready"


def told(fields: Mapping[str, Any]) -> tuple[int, int] | None:
    """What a check says Shipday was told: Shipday's id of the delivery and when; None where it was not, or
    where what is written cannot be read."""
    said = fields.get(FIELD)
    if not isinstance(said, Mapping):
        return None
    ident, at = said.get("id"), said.get("at_ms")
    for number in (ident, at):
        if not isinstance(number, int) or isinstance(number, bool):
            return None
    return int(ident), int(at)  # type: ignore[arg-type]


def op_id(order_id: str, delivery: int) -> str:
    """The id of the operation that writes on a check that Shipday was told of this delivery: one for a
    check and a delivery, whoever told and however often the hub looks."""
    return f"{order_id}:shipday-ready-{int(delivery)}"


def op_told(order_id: str, delivery: int, at_ms: int, *, by: str | None, stamp: Callable[[], HLC]) -> Op:
    """The operation that writes it on the check. `by` is who tapped Ready for pickup on the Shipday screen;
    None where the hub told Shipday by itself, which the check's history then says."""
    word = {"id": int(delivery), "at_ms": int(at_ms), "auto": by is None}
    return Op(op_id(order_id, delivery), order_id, stamp(), DEVICE, "set_field", {FIELD: word, "by": by or BY})


__all__ = ["FIELD", "op_id", "op_told", "told", "waits"]
