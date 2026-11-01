"""Counter-mode order numbers (architecture section 12): 1, 2, 3 ... through the day, given by the backend
when a takeout order's `create` arrives, so the number is on the ticket, on the list, in the ready text and
called at the shelf. A terminal never numbers an order itself: two terminals would pick the same one.

The backend scans the store once per day for the highest number already given (a restart, or a standby
hub promoted, picks up where the day was), then counts in memory. Hubs share one database, so they share
the count; the cloud counts on its own until the hub and cloud logs sync (phase 2), so a day could see a
number twice across the two while a location runs on the cloud. Numbers start again every day.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from datetime import date, datetime
from typing import Protocol

from ..sync.oplog import OrderState


class _Store(Protocol):
    def order_ids(self) -> list[str]: ...
    def state(self, order_id: str) -> OrderState: ...


class OrderNumbers:
    def __init__(self, store: _Store, *, today: Callable[[], date] = date.today) -> None:
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
        for order_id in self._store.order_ids():
            state = self._store.state(order_id)
            number = state.fields.get("order_no")
            if not isinstance(number, int) or state.first is None:
                continue
            if datetime.fromtimestamp(state.first.wall_ms / 1000).date() == day:
                last = max(last, number)
        return last
