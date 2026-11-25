"""Who is calling: the order a phone number placed today, for the terminal that picks up the call.

When a call is answered the app opens the caller's last order of the day, so a customer calling back about
an order lands on it; with none, the app starts a new phone order with the number. The hub finds the order,
not the terminal: numbers are compared by their digits (a caller ID of `+17815551234` is the form's
`781 555 1234`), today is the location's day (`POS_TIMEZONE`, as the order numbers count it), and the last
order is the one opened last, whatever was done to the others since. A voided order does not count; a closed
one does, so a call about an order already picked up still lands on it.

A table's check and a bar tab do not count either, whatever number is on them: the number a guest left at
the table is for the guest list (docs/guest-list.md, "A walk-in's number"), and somebody who ate in at noon
and rings in the evening rings for a new order.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date
from typing import Protocol

from .. import localtime
from ..sync.oplog import OrderEntry, OrderState, phone_digits

__all__ = ["last_order", "phone_digits"]


class _Store(Protocol):
    def index(self, *, opened_since: int | None = None) -> list[OrderEntry]: ...
    def views(self, entries: Sequence[OrderEntry]) -> list[OrderState]: ...


def last_order(store: _Store, phone: object, *, day: date) -> OrderState | None:
    """The order opened last on `day` by this number, or None: none opened, or the number is empty. Only the
    orders opened since that day began are looked at, from the log's index; what comes back is the store's
    shared replay, to read and not to change."""
    wanted = phone_digits(phone)
    if not wanted:
        return None
    last: OrderState | None = None
    for state in store.views(store.index(opened_since=localtime.start_ms(day))):
        if state.status == "void" or state.first is None:
            continue
        if str(state.fields.get("order_type") or "dine_in") == "dine_in":
            continue  # a table's check: the number on it is the guest list's, and no call is about it
        if phone_digits(state.fields.get("phone")) != wanted or localtime.day_of(state.first.wall_ms) != day:
            continue
        if last is None or state.first > last.first:
            last = state
    return last
