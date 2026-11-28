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

It also says two things the paper does not. It greets the guest by name (`greeting_name`, `host_view`): the
name tells them it is their order, and "welcome back" that they are known here. And, where the location
turned it on, it suggests a tip under the total (`tips_of`): amounts to read, worked out here like every
other figure, and nothing to tap.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable, Mapping
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any

from .printing.bill import Bill
from .sync.oplog import is_tab

_CENT = Decimal("0.01")
_TITLES = frozenset({"mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "madam"})
"""What stands before a name and is no name: "Mr. Wong" is greeted as Mr. Wong, not as Mr."""
_NO_NAMES = frozenset(
    {
        "walk", "walkin", "walk-in", "guest", "customer", "cash", "counter", "phone", "online", "web",
        "unknown", "none", "no", "na", "test", "to", "togo", "to-go", "pickup", "takeout", "take", "delivery",
        "order", "table", "bar", "tab", "doordash", "uber", "ubereats", "grubhub",
    }
)  # fmt: skip
"""What gets typed where a name goes when nobody gave one: nobody is greeted as "Walk" or "Guest"."""

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


def _a_name(word: str) -> bool:
    """Whether a word can be somebody's name: letters, in any script, with a hyphen, an apostrophe or a dot
    inside at most. "#12" and "T5" are not."""
    bare = word.replace("-", "").replace("'", "").replace("\u2019", "").replace(".", "")
    return bool(bare) and bare.isalpha() and bare.casefold() not in _NO_NAMES


def _as_written(word: str) -> str:
    """A name typed all in small letters or all in capitals, with its first letter large: "linda" and
    "LINDA" are Linda. One typed with care ("McKay", "DeShawn") stays as it is."""
    return word[:1].upper() + word[1:].lower() if word.islower() or (word.isupper() and len(word) > 1) else word


def greeting_name(name: Any) -> str:
    """What to call a guest on a screen the room can read: the first name ("Linda" of "Linda Chen"), or the
    title with the last name where they gave one ("Mr. Wong"). Empty where what was typed is no name
    ("Walk in", "Table 5", "#12"): better no name than a wrong one."""
    words = str(name or "").split()
    if not words:
        return ""
    if words[0].rstrip(".").casefold() in _TITLES:
        if len(words) < 2 or not _a_name(words[-1]):
            return ""
        title = words[0].rstrip(".")
        dot = "." if words[0].endswith(".") or title.casefold() in {"mr", "mrs", "ms", "mx", "dr", "prof"} else ""
        return f"{_as_written(title)}{dot} {_as_written(words[-1])}"
    return _as_written(words[0]) if _a_name(words[0]) else ""


def host_view(name: Any, *, back: bool = False) -> dict[str, Any] | None:
    """How a display greets the guest of an order: `name`, what to call them (may be empty), and `back`,
    whether they have been here before. None when there is neither: the display greets as it greets anyone."""
    called = greeting_name(name)
    return {"name": called, "back": bool(back)} if called or back else None


def _money(value: Any) -> Decimal:
    try:
        return Decimal(str(value or "0"))
    except InvalidOperation:
        return Decimal(0)


def tips_of(check: Mapping[str, Any], setting: Mapping[str, Any]) -> dict[str, Any] | None:
    """The tips a display suggests for a check, as the location set them (`guest_display` in `pos.settings`),
    or None: the location suggests none, the check already carries a gratuity (a large party's, an online
    order's tip: nobody is asked twice), or there is nothing to tip on.

    `base` is what the percentages are of: `before_tax`, the food and drink less comps and discounts, or
    `after_tax`, the check's total. `of` is that amount, and each of `rows` a percentage with what it comes
    to, to the cent."""
    if not setting.get("tips"):
        return None
    if any(charge.get("gratuity") and _money(charge.get("amount")) > 0 for charge in check.get("charges") or ()):
        return None
    base = str(setting.get("tip_base") or "before_tax")
    if base == "after_tax":
        of = _money(check.get("total"))
    else:
        base, of = "before_tax", _money(check.get("subtotal")) - _money(check.get("discount_total"))
    if of <= 0:
        return None
    return {
        "base": base,
        "of": f"{of.quantize(_CENT, rounding=ROUND_HALF_UP):,.2f}",
        "rows": [
            {
                "percent": int(percent),
                "amount": f"{(of * int(percent) / 100).quantize(_CENT, rounding=ROUND_HALF_UP):,.2f}",
            }
            for percent in setting.get("tip_percents") or ()
        ],
    }


def _paid_in_full(bill: Bill) -> bool:
    if bill.due is None:
        return False
    try:
        return Decimal(bill.due.replace(",", "")) <= 0
    except InvalidOperation:
        return False


def guest_view(
    bill: Bill, fields: Mapping[str, Any], status: str, *, tips: Mapping[str, Any] | None = None
) -> dict[str, Any] | None:
    """What a guest reads of an order, from its bill: the dishes with their choices and what each comes to,
    the sums under them (subtotal, each discount and charge, sales tax as one line), the total, what was
    paid and what is still due. None for an order with no dish on it yet, and for one that was voided: there
    is nothing to show a guest.

    `where` is the table, or the order's number; `detail` what to call whoever a to-go order or a tab is
    for (`greeting_name`: the first name, never "Walk" of "Walk in"). A row of
    words only (who a tax exemption is for, its certificate) is the paper's, not the room's. `tips` are the
    tips to suggest (`tips_of`), shown until the check is paid in full."""
    if status == "void" or not bill.lines:
        return None
    named = is_tab(fields) or not fields.get("table")
    paid_in_full = _paid_in_full(bill)
    return {
        "order_id": bill.order_id,
        "where": bill.where,
        "detail": greeting_name(fields.get("customer_name")) if named else "",
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
        "paid_in_full": paid_in_full,
        "tips": dict(tips) if tips is not None and not paid_in_full else None,
    }
