"""Which order on the POS a delivery in Shipday is.

The same delivery is in two places: GloriaFood hands an accepted order to the POS (`pos.online`) and to
Shipday, each by its own road, and neither tells the other. A screen that shows Shipday's deliveries wants
to say "this is check #12" beside one and open it, so the two are put together here, by what both carry:

1. **GloriaFood's number for the order.** The POS keeps it (`online.id`). Where the number Shipday knows
   the order by (`orderNumber`) is that number, or has it in it as a whole run of digits ("#1270166229"),
   it is the same order. Whether Shipday's GloriaFood link numbers its orders that way is not written
   anywhere that could be read: this is the hopeful case, and the next one is what carries the matching
   if it does not.
2. **The customer's phone number**, among the day's deliveries on the POS that the first rule left over.
   One delivery on the POS with that number is the order. Several (a customer who ordered twice) are told
   apart by the house number of the address; when that does not single one out, nothing is matched: a
   wrong check beside a delivery is worse than none.

An order on the POS is matched to one delivery at most, and a delivery to one order at most. A delivery
that matches nothing is simply not on the POS as far as the hub can tell (an order taken in Shipday by
hand, or one from another day), and a screen says so.

Only deliveries are looked at on the POS side (`pos.sync.oplog.is_delivery`), of the day of service that is
running, voided ones too: a delivery still out in Shipday whose check was voided on the POS is worth seeing.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from ..sync.oplog import OrderState, is_delivery, phone_digits

BY_NUMBER, BY_PHONE = "number", "phone"
ONLINE_ID_MIN = 6
"""A number of GloriaFood's shorter than this is not looked for inside Shipday's: "12" is in everything."""
PHONE_MIN = 7
_DIGITS = re.compile(r"\d+")
_HOUSE = re.compile(r"\s*#?\s*(\d+)")


@dataclass(frozen=True)
class OnPos:
    """A delivery on the POS, as far as the matching and a screen need it."""

    order_id: str
    order_no: int | None = None
    name: str = ""
    phone: str = ""  # digits only, as `phone_digits` gives them
    address: str = ""
    online_id: str = ""  # GloriaFood's number for it; empty for an order rung up at the POS
    status: str = "open"
    stage: str = ""

    def about(self, how: str) -> dict[str, Any]:
        """What a screen is told of the check a delivery is: enough to name it and open it."""
        return {
            "order_id": self.order_id,
            "order_no": self.order_no,
            "status": self.status,
            "stage": self.stage,
            "by": how,
        }


def on_pos(state: OrderState) -> OnPos | None:
    """An order of the POS's as the matching sees it; None for one that is not brought to the customer."""
    fields = state.fields
    if not is_delivery(fields):
        return None
    online = fields.get("online")
    number = fields.get("order_no")
    return OnPos(
        order_id=state.order_id,
        order_no=number if isinstance(number, int) and not isinstance(number, bool) else None,
        name=str(fields.get("customer_name") or ""),
        phone=phone_digits(fields.get("phone")),
        address=str(fields.get("address") or ""),
        online_id=str(online.get("id") or "").strip() if isinstance(online, Mapping) else "",
        status=state.status,
        stage=str(fields.get("stage") or ""),
    )


def _same_number(number: str, online_id: str) -> bool:
    if not online_id:
        return False
    bare = number.strip().lstrip("#").strip().casefold()
    if bare == online_id.casefold():
        return True
    return len(online_id) >= ONLINE_ID_MIN and online_id.isdigit() and online_id in _DIGITS.findall(number)


def _house(address: str) -> str:
    found = _HOUSE.match(address)
    return found.group(1) if found else ""


def matched(orders: Sequence[Mapping[str, Any]], deliveries: Sequence[OnPos]) -> dict[int, tuple[OnPos, str]]:
    """For each of Shipday's orders (as `pos.shipday.read.order_of` gives them) that is on the POS: the
    delivery it is there and how that was told (`number` or `phone`), by Shipday's id."""
    found: dict[int, tuple[OnPos, str]] = {}
    taken: set[str] = set()
    for order in orders:
        number = str(order.get("number") or "")
        if not number:
            continue
        same = [d for d in deliveries if d.order_id not in taken and _same_number(number, d.online_id)]
        if len(same) == 1:
            found[int(order["id"])] = (same[0], BY_NUMBER)
            taken.add(same[0].order_id)
    for order in orders:
        if int(order["id"]) in found:
            continue
        phone = phone_digits(order.get("phone"))
        if len(phone) < PHONE_MIN:
            continue
        # a voided check is the order only when nothing that still stands has the number
        same = [d for d in deliveries if d.order_id not in taken and d.phone == phone]
        standing = [d for d in same if d.status != "void"]
        same = standing or same
        if len(same) > 1:
            house = _house(str(order.get("address") or ""))
            same = [d for d in same if house and _house(d.address) == house]
        if len(same) == 1:
            found[int(order["id"])] = (same[0], BY_PHONE)
            taken.add(same[0].order_id)
    return found


__all__ = ["BY_NUMBER", "BY_PHONE", "OnPos", "matched", "on_pos"]
