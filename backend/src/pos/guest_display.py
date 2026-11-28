"""The guest display: a screen turned to the customer that shows the order being rung up on the screen it is
linked to (docs/guest-display.md).

Two things make one. A screen where orders are taken says which order it has open (`Showing`), and the hub
turns that order into what a guest may read of it (`guest_view`): the bill, live. It is the same bill the
printer gets (`pos.printing.bill.bill_for`, from the check as the hub reckons it), so the screen facing the
guest says what the paper will say, to the cent, and no terminal adds anything up.

What is open on a screen is no part of an order and is written nowhere: it is kept in memory, as the screens
the hub hears from are (`pos.devices`). A hub that restarts knows of none until each screen says again, which
a screen does when it finds the hub again.

A display the room can read says less than the paper: no server, no address, no phone number, and of the name
on a to-go order or a bar tab only the first word, as the pickup board does. Whoever stands at the register
may not be whose order is open on it.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable, Mapping
from decimal import Decimal, InvalidOperation
from typing import Any

from .printing.bill import Bill
from .sync.oplog import is_tab

QUIET_MS = 60_000
"""A screen the hub has not heard from for this long has nothing open as far as a guest display goes: its app
was closed, its battery died, it was carried out of reach. Every running app is heard from every fifteen
seconds (`pos.devices`), so a minute is four of those missed."""


class Showing:
    """Which order each screen has open, as the screens say it, and which one it had open before that (`left`):
    a display thanks the guest whose paid order was just left. Screens are told apart as `DevicesSeen` tells
    them: by name, whatever the case. `heard` answers when the hub last heard from a screen (ms), or None."""

    def __init__(
        self,
        heard: Callable[[str], int | None] | None = None,
        *,
        clock: Callable[[], float] = time.time,
        quiet_ms: int = QUIET_MS,
    ) -> None:
        self._heard = heard
        self._clock = clock
        self._quiet_ms = quiet_ms
        self._open: dict[str, tuple[str, int]] = {}  # screen -> (order, when it said so)
        self._left: dict[str, str] = {}  # screen -> the order it had open before
        self._lock = threading.Lock()

    def say(self, device: str, order_id: str | None) -> bool:
        """The screen has this order open now, or none. True when that is news."""
        name = device.strip().casefold()
        if not name:
            return False
        now_ms = int(self._clock() * 1000)
        with self._lock:
            had = self._open.get(name)
            if had is not None and had[0] != order_id:
                self._left[name] = had[0]
            if not order_id:
                self._open.pop(name, None)
                return had is not None
            self._open[name] = (order_id, now_ms)
            return had is None or had[0] != order_id

    def of(self, device: str) -> str | None:
        """The order the screen has open, or None: it has none, or it said so and then fell silent."""
        name = device.strip().casefold()
        with self._lock:
            had = self._open.get(name)
        if had is None:
            return None
        order_id, said_ms = had
        if self._heard is None:  # nobody to ask whether the screen is still there: its word stands
            return order_id
        return order_id if self._lately(max(said_ms, self._heard(device) or 0)) else None

    def left(self, device: str) -> str | None:
        """The order the screen had open before the one it has now, or before it had none: the one it left
        last. None for a screen that never left one."""
        with self._lock:
            return self._left.get(device.strip().casefold())

    def known(self, device: str) -> bool:
        """Whether the hub hears from this screen now: what a display says of the screen it is linked to."""
        heard_ms = self._heard(device) if self._heard is not None else None
        return heard_ms is not None and self._lately(heard_ms)

    def _lately(self, at_ms: int) -> bool:
        return int(self._clock() * 1000) - at_ms <= self._quiet_ms


def first_name(name: Any) -> str:
    """The first word of a name: "Linda" of "Linda Chen". What a screen the room can read says of a customer."""
    words = str(name or "").split()
    return words[0] if words else ""


def _paid_in_full(bill: Bill) -> bool:
    if bill.due is None:
        return False
    try:
        return Decimal(bill.due.replace(",", "")) <= 0
    except InvalidOperation:
        return False


def guest_view(bill: Bill, fields: Mapping[str, Any], status: str) -> dict[str, Any] | None:
    """What a guest reads of an order, from its bill: the dishes with their choices and what each comes to,
    the sums under them (subtotal, each discount and charge, sales tax as one line), the total, what was
    paid and what is still due. None for an order with no dish on it yet, and for one that was voided: there
    is nothing to show a guest.

    `where` is the table, or the order's number; `detail` the first name on a to-go order or a tab. A row of
    words only (who a tax exemption is for, its certificate) is the paper's, not the room's."""
    if status == "void" or not bill.lines:
        return None
    named = is_tab(fields) or not fields.get("table")
    return {
        "order_id": bill.order_id,
        "where": bill.where,
        "detail": first_name(fields.get("customer_name")) if named else "",
        "lines": [
            {
                "qty": line.qty,
                "name": line.name,
                "amount": line.amount,
                "notes": [{"text": words, "depth": depth} for words, depth in line.notes],
            }
            for line in bill.lines
        ],
        "sums": [{"label": label.strip(), "amount": amount} for label, amount in bill.sums if amount],
        "total": bill.total,
        "paid": [{"label": label.strip(), "amount": amount} for label, amount in bill.paid],
        "due": bill.due,
        "paid_in_full": _paid_in_full(bill),
    }
