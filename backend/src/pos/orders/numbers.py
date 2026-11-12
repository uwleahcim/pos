"""Counter-mode order numbers (architecture section 12): 1, 2, 3 ... through the day, given by the backend
when a takeout order's `create` arrives, so the number is on the ticket, on the list, in the ready text and
called at the shelf. A terminal never numbers an order itself: two terminals would pick the same one.

The backend looks through the day's orders once per day for the highest number already given (a restart,
or a standby hub promoted, picks up where the day was), then counts in memory. A day is the location's calendar day
(`POS_TIMEZONE`), not the hub's or the cloud's. Hubs share one database, so they share the count; the
cloud counts on its own until the hub and cloud logs sync (phase 2), so a day could see a number twice
across the two while a location runs on the cloud. Numbers start again every day.
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Sequence
from datetime import date
from typing import Protocol

from .. import localtime
from ..sync.oplog import OrderEntry, OrderState


class _Store(Protocol):
    def index(self, *, opened_since: int | None = None) -> list[OrderEntry]: ...
    def views(self, entries: Sequence[OrderEntry]) -> list[OrderState]: ...


class OrderNumbers:
    def __init__(self, store: _Store, *, today: Callable[[], date] = localtime.today) -> None:
        self._store = store
        self._today = today
        self._day: date | None = None
        self._last = 0
        self._lock = threading.Lock()

    def next(self) -> int:
        with self._lock:
            day = self._today()
            if day != self._day:
                self._day = day
                self._last = self._highest(day)
            self._last += 1
            return self._last

    def _highest(self, day: date) -> int:
        last = 0
        for state in self._store.views(self._store.index(opened_since=localtime.start_ms(day))):
            number = state.fields.get("order_no")
            if not isinstance(number, int) or state.first is None:
                continue
            if localtime.day_of(state.first.wall_ms) == day:
                last = max(last, number)
        return last
