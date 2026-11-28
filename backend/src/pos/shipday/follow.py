"""What Shipday says of a delivery, turned into what the POS writes on its check.

The restaurant chose this (Mike, 2026-11-28, on the question whether a delivery's status in Shipday should
move its check on the POS): "Shipday moves the check", which the question put as "When a driver marks picked
up or delivered in Shipday, the check goes Out or Delivered by itself. The POS sends no second text, and a
check with money due stays open."

`ops_following` reads one of Shipday's deliveries beside the check the hub matched it to
(`pos.shipday.match`) and gives the operations that make the check say the same. Nothing here stores or
tells anybody: the hub does that with what comes back (`pos.api.shipday`), and sends no text for it.

**Picked up** (Shipday's `PICKED_UP`, and `READY_TO_DELIVER`, which is further along the same road): a check
that has not left goes **Out**, with Shipday's driver and the moment Shipday says it was picked up, as when
somebody taps Out and picks a driver (docs/delivery.md). The driver is Shipday's, not one of the POS's
staff: the name as Shipday has it, under an id that starts `shipday:`.

**Delivered** (`ALREADY_DELIVERED`): a check with nothing left to pay is marked delivered and **closed**, as
when somebody taps Delivered. One that never went Out on the POS goes Out first, so its history and the
day's runs say who took it. A check with **money still due stays open**, out with its driver: whoever takes
the money taps Delivered. What Shipday said is written on it (`shipday`), so a screen can say "Shipday:
delivered 18:55" beside what is still to pay.

**Failed, Incomplete**: nothing is moved. A person decides what becomes of the bag and the check; what
Shipday said is written on it for them to see.

The rules that keep it from doing harm:

- **Only forward, and only an open delivery.** A check that is closed or voided, one that is no delivery
  (any more), and one somebody marked delivered already stay as they are. A check that is Out already, with
  whoever, is not taken Out again.
- **Only what a person could have tapped.** A check the kitchen never had (nothing sent, not marked ready)
  is not moved: the POS's own Out refuses it too. What Shipday said is still written on it.
- **Once.** Every operation has a fixed id, so the hub writes each step of a delivery once however often
  it reads Shipday. What a person does on the POS afterwards stands: a bag that came back is not sent Out
  again because Shipday still says picked up (another driver picking it up is another step).
- **One way.** Nothing here tells Shipday anything.

Shipday's times are read as UTC from pages that show them without a zone (`pos.shipday.read`), so a moment
Shipday names is used only where it can be right (`_when`): otherwise the moment the hub heard of it.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import replace
from typing import Any

from ..sync.hlc import HLC
from ..sync.oplog import Op, OrderState, is_delivery
from .read import ALREADY_DELIVERED, FAILED_DELIVERY, INCOMPLETE, PICKED_UP, READY_TO_DELIVER

DEVICE = "shipday"
"""The device these operations are written by, and the node of the clock that stamps them."""
BY = "Shipday"
"""Who a check's history says did it."""
FIELD = "shipday"
"""The order field that keeps what Shipday last said, which only the hub writes."""
DRIVER = "shipday"
"""How the id of a driver who is Shipday's begins (`shipday:4012`): nobody of the POS's staff."""
NAMELESS = "Shipday driver"
"""What a driver is called whom Shipday did not name."""
ON_ITS_WAY = (PICKED_UP, READY_TO_DELIVER)
NOT_MADE = (FAILED_DELIVERY, INCOMPLETE)
FOLLOWED = (*ON_ITS_WAY, ALREADY_DELIVERED, *NOT_MADE)
"""Where a delivery stands in Shipday when the hub looks at its check at all."""
RECENT_MS = 45 * 60_000
"""How long ago a moment Shipday names may be for the POS to take its word for it. The hub hears of a step
within minutes. A moment further back, or one still to come, is more likely a clock read in the wrong zone
(which is off by an hour at least) than a delivery: then the POS says when it heard."""

OUT, DELIVERED, DUE, NOTED = "out", "delivered", "due", "noted"
"""What came of looking, for the hub's log: the check left; it was delivered and closed; it was delivered
and stays open for its money; only what Shipday said was written on it."""


def own_word(op: Op) -> Op:
    """An operation as a screen may send it: without `shipday`, which is the hub's alone to write."""
    if op.kind in ("create", "set_field") and FIELD in op.data:
        return replace(op, data={name: value for name, value in op.data.items() if name != FIELD})
    return op


def _when(said: Any, now_ms: int) -> int:
    """The moment Shipday names for a step, where it can be right; else now."""
    if isinstance(said, int) and not isinstance(said, bool) and 0 <= now_ms - said <= RECENT_MS:
        return said
    return now_ms


def can_leave(state: OrderState) -> bool:
    """Whether a check that has not left could be handed to a driver on the POS: it is packed, or the
    kitchen has some of it."""
    return str(state.fields.get("stage") or "new") == "ready" or bool(state.fired)


def ops_following(
    delivery: Mapping[str, Any],
    state: OrderState,
    *,
    due: Callable[[], bool],
    stamp: Callable[[], HLC],
    now_ms: int,
) -> tuple[tuple[Op, ...], str]:
    """The operations that make the check `state` say what Shipday says of `delivery` (as
    `pos.shipday.read.order_of` gives it, its driver named), and what they come to (`OUT`, `DELIVERED`,
    `DUE`, `NOTED`); nothing, and no word, where the check stays as it is. `due` says whether money is still
    to pay on the check, and is asked only for a delivery that was made. `stamp` stamps each operation.

    Every operation has a fixed id: the caller leaves out the ones its log already has."""
    said = delivery.get("state")
    if said not in FOLLOWED:
        return (), ""
    if state.first is None or state.status != "open" or not is_delivery(state.fields):
        return (), ""
    stage = str(state.fields.get("stage") or "new")
    if stage == "picked_up":
        return (), ""  # somebody marked it delivered already
    order_id, ident = state.order_id, int(delivery["id"])
    made: list[Op] = []

    def write(name: str, kind: str, data: dict[str, Any]) -> None:
        made.append(Op(f"{order_id}:shipday-{name}", order_id, stamp(), DEVICE, kind, data))

    def word(state_said: str, at: int) -> dict[str, Any]:
        return {"id": ident, "number": str(delivery.get("number") or ""), "state": state_said, "at_ms": at}

    def note(at: int) -> None:
        write(f"said-{ident}-{said}", "set_field", {FIELD: word(str(said), at), "by": BY})

    def leave(at: int) -> None:
        driver = delivery.get("driver")
        carrier = int(driver["id"]) if isinstance(driver, Mapping) else 0
        name = str(driver.get("name") or "").strip() if isinstance(driver, Mapping) else ""
        write(
            f"out-{ident}-{carrier}",
            "set_field",
            {
                "stage": "out",
                "driver": name or NAMELESS,
                "driver_id": f"{DRIVER}:{carrier}" if carrier else DRIVER,
                "out_at": at,
                "by": BY,
                FIELD: word(PICKED_UP, at),
            },
        )

    waits = stage != "out"  # it has not left on the POS
    if said in NOT_MADE:
        note(_when(delivery.get("ended_ms"), now_ms))
        return tuple(made), NOTED
    if waits and not can_leave(state):
        # the kitchen never had it: nobody could have sent it out on the POS, and the hub does not either
        note(_when(delivery.get("delivered_ms" if said == ALREADY_DELIVERED else "picked_up_ms"), now_ms))
        return tuple(made), NOTED
    if said in ON_ITS_WAY:
        if not waits:
            return (), ""  # out already, with whoever
        leave(_when(delivery.get("picked_up_ms"), now_ms))
        return tuple(made), OUT
    # delivered
    at = _when(delivery.get("delivered_ms"), now_ms)
    if waits:
        leave(min(_when(delivery.get("picked_up_ms"), now_ms), at))
    if due():
        note(at)
        return tuple(made), DUE
    write(f"delivered-{ident}", "set_field", {"stage": "picked_up", "by": BY, FIELD: word(ALREADY_DELIVERED, at)})
    write(f"closed-{ident}", "close", {"by": BY})
    return tuple(made), DELIVERED


__all__ = [
    "BY",
    "DELIVERED",
    "DEVICE",
    "DRIVER",
    "DUE",
    "FIELD",
    "FOLLOWED",
    "NAMELESS",
    "NOTED",
    "NOT_MADE",
    "ON_ITS_WAY",
    "OUT",
    "RECENT_MS",
    "can_leave",
    "ops_following",
    "own_word",
]
