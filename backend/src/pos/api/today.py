"""Today so far on the wire: one reading for a phone. The figures live in `pos.orders.day`,
`pos.orders.sales` and `pos.orders.today`; this is the call.

- `GET /reports/today` (a token whose holder may see the reports): `day`, the report of the day that is
  running exactly as `GET /reports/day` answers it (the sales so far, what is still open, what came off, who
  is on the clock), its `clock` with `net_per_hour` added; `before`, the sales of the same weekday a week
  earlier, the whole of it, as `GET /reports/sales` answers a span; `pace`, the dishes rung in by this
  time of day on both (`now`, `before`, and `before_ms`, the moment a week ago they are held against), so
  that tonight can be said to be ahead or behind; `per_check`, today's net sales for each check (null
  before the first); `hours`, each hour of the night with the dishes rung in it on both days (`now`,
  `before`), in the order a night runs; and `open`, the checks open at this moment added up (`count`, what
  they come to in `total`, what is not paid on them in `due`), tonight's and any left open from an earlier
  day.

Reading it changes nothing and nothing is written down. It is one call so that a phone on the restaurant's
Wi-Fi asks once, and asks again every half minute while somebody looks at it.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from fastapi import FastAPI, Header

from .. import localtime
from ..orders.day import ZERO
from ..orders.sales import comparison, sales_reports
from ..orders.today import RungMemo, rung_by, same_time
from .auth import holder_from
from .day import report_for
from .sales import clock_part, net_per_hour, orders_between


def hours_beside(now: list[dict[str, Any]], before: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The hours either day sold anything in, in the order a night runs (as a span's `hours` come: from the
    hour the night ends round to the hour before it, dishes with no time kept last), each with what the
    dishes rung in it sell for on both days."""

    def place(hour: int | None) -> int:
        return 24 if hour is None else (hour - localtime.NIGHT_ENDS.hour) % 24

    sold = {row["hour"]: row["amount"] for row in now}
    then = {row["hour"]: row["amount"] for row in before}
    return [
        {"hour": hour, "now": sold.get(hour, "0.00"), "before": then.get(hour, "0.00")}
        for hour in sorted({*sold, *then}, key=place)
    ]


def add_today(app: FastAPI, memo: RungMemo | None = None) -> None:
    """`GET /reports/today`. Added after the sales report, whose remembered sales it reads."""
    memo = memo if memo is not None else RungMemo()

    @app.get("/reports/today")
    def read_today(authorization: str | None = Header(None)) -> dict[str, Any]:
        """The day so far beside the same weekday a week ago: the day's report, that day's sales, and how
        far each had come by this time of day."""
        holder_from(app.state, authorization, "reports")
        store = app.state.store
        taxes, rules = app.state.taxes, app.state.pricing
        today = report_for(app)
        now_ms = today["now_ms"]
        day = localtime.service_day_of(now_ms)
        earlier = comparison(day, day)[0]
        if today["clock"] is not None:
            today["clock"]["net_per_hour"] = net_per_hour(today["sales"]["net"], today["clock"]["worked_ms"])

        # Every order of the week that can count on either day: the two days' own, and one rung long before
        # for either. The days between cost a look each and count for nothing.
        picked = orders_between(app, localtime.service_day(earlier)[0], today["until_ms"])
        sold = app.state.sale_memo.sales(picked, store.views, taxes=taxes, rules=rules)
        spans = [(day, day), (earlier, earlier)]
        so_far, before = sales_reports(sold, spans, defs=app.state.menu.defs, now_ms=now_ms)
        before["clock"] = clock_part(app, before["since_ms"], before["until_ms"], before["sales"]["net"])

        rungs = list(memo.each(picked, store.views, taxes=taxes, rules=rules))
        before_ms = same_time(now_ms, day, earlier)
        still_open = [*today["open"], *today["earlier"]]
        return {
            "now_ms": now_ms,
            "day": today,
            "before": before,
            "per_check": so_far["per_check"],
            "hours": hours_beside(so_far["hours"], before["hours"]),
            "open": {
                "count": len(still_open),
                "total": str(sum((Decimal(row["total"]) for row in still_open), ZERO)),
                "due": str(sum((Decimal(row["due"]) for row in still_open), ZERO)),
            },
            "pace": {
                "now": str(rung_by(rungs, day, now_ms + 1)),
                "before": str(rung_by(rungs, earlier, before_ms + 1)),
                "before_ms": before_ms,
            },
        }
