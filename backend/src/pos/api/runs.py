"""The drivers' runs on the wire. The reading lives in `pos.orders.runs`; this is the call.

- `GET /deliveries/runs?day=YYYY-MM-DD`: every driver who took a delivery out on that day of service, their
  runs in the order they left, and what became of each bag (`runs_report`); without `day`, the day that is
  running. Anyone at a terminal may read it, like the list of orders: it names the customers and where
  their orders went, as that list does, and holds no money.

Reading it changes nothing and nothing is written down: it is reckoned from the orders' own logs.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Query

from .. import localtime
from ..orders.runs import runs_report
from ..sync.oplog import is_delivery
from .day import DAY, the_day
from .sales import orders_between


def runs_for(app: FastAPI, asked: str | None = None) -> dict[str, Any]:
    """The runs as `GET /deliveries/runs` answers them, reckoned now: for the day asked, else the one that
    is running."""
    store = app.state.store
    now_ms = store.now_ms()
    day = the_day(asked, now_ms)
    since, until = localtime.service_day(day)
    entries = orders_between(app, since, until)
    # only what was ever brought to a customer: it is one now, or it once left with somebody
    brought = [
        state.order_id
        for state in store.views(entries)
        if is_delivery(state.fields) or state.fields.get("out_at") is not None
    ]
    return runs_report(((order_id, store.for_order(order_id)) for order_id in brought), day, now_ms=now_ms)


def add_runs(app: FastAPI) -> None:
    @app.get("/deliveries/runs")
    def read_runs(
        day: str | None = Query(None, pattern=DAY, description="the day of service; the running one without it"),
    ) -> dict[str, Any]:
        """A day's deliveries by who took them out. `drivers`: each driver with their `runs`, how many bags
        were `delivered`, came `back` or are still `out`, and the `list` of the runs, each with when it
        `left_ms`, when its last bag was marked (`ended_ms`, null while one is out), the `minutes` between
        and its `bags` (the order's number, name and address, its `outcome` and when that was marked). The
        totals count every driver; `no_driver` counts the deliveries marked delivered that day with nobody
        having taken them out. No amount of money is in it."""
        return runs_for(app, day)
