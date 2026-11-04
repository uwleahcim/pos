"""Who is calling: the order a phone number placed today, for the terminal that picks up the call.

When a call is answered the app opens the caller's last order of the day, so a customer calling back about
an order lands on it; with none, the app starts a new phone order with the number. The hub finds the order,
not the terminal: numbers are compared by their digits (a caller ID of `+17815551234` is the form's
`781 555 1234`), today is the location's day (`POS_TIMEZONE`, as the order numbers count it), and the last
order is the one opened last, whatever was done to the others since. A voided order does not count; a closed
one does, so a call about an order already picked up still lands on it.
"""

from __future__ import annotations

import re
from datetime import date
from typing import Protocol

from .. import localtime
from ..sync.oplog import OrderState

_NOT_DIGITS = re.compile(r"\D")


class _Store(Protocol):
    def order_ids(self) -> list[str]: ...
    def state(self, order_id: str) -> OrderState: ...


def phone_digits(raw: object) -> str:
    """A number as digits only, without the North American country code: `+1 (781) 555-1234`,
    `17815551234` and `781 555 1234` are all `7815551234`. Nothing for no number."""
    digits = _NOT_DIGITS.sub("", str(raw or ""))
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    return digits


def last_order(store: _Store, phone: object, *, day: date) -> OrderState | None:
    """The order opened last on `day` by this number, or None: none opened, or the number is empty."""
    wanted = phone_digits(phone)
    if not wanted:
        return None
    last: OrderState | None = None
    for order_id in store.order_ids():
        state = store.state(order_id)
        if state.status == "void" or state.first is None:
            continue
        if phone_digits(state.fields.get("phone")) != wanted or localtime.day_of(state.first.wall_ms) != day:
            continue
        if last is None or state.first > last.first:
            last = state
    return last
