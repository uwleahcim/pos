"""Sales over a span of days on the wire. The figures live in `pos.orders.sales`; this is the call.

- `GET /reports/sales?from=YYYY-MM-DD&to=YYYY-MM-DD` (manager token): `span`, the sales of those days of
  service, and `before`, the same figures for as many days the fewest whole weeks earlier
  (`pos.orders.sales.comparison`), to hold beside them. Without `from` and `to`, the day that is running;
  with one of them, that one day. 422 `bad_value` for a first day after the last, 422 `too_long` for more
  than `max_days` days.
- Each of the two carries `clock` where the location uses the time clock, else null: the hours worked on
  shifts that began in those days, by how many people, how many shifts nobody clocked out of, and
  `net_per_hour`, the net sales for each hour worked.

- `GET /reports/dishes?from=&to=` (manager token), the same days asked the same way: `dishes`, every dish
  sold in them or on the menu, most sold first, each with how many and for how much, the same for the days
  before (`before_count`, `before_amount`), its `sizes`, the names `typed` for an off-menu dish and its
  `options` (each under the `group` it belongs to); `categories`, the same added up by menu and category;
  and `span` and `before`, the days and what all their dishes come to (`pos.orders.dishes`).

Reading either changes nothing and nothing is written down: both are reckoned from the log. What each check
comes to is remembered in memory while its log stays as it was (`pos.orders.sales.SaleMemo`), so the first
reading of a long span takes a few seconds and the next ones do not, whichever of the two is read.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query

from .. import localtime
from ..identity.tokens import Grant
from ..orders.dishes import dishes_report
from ..orders.sales import MAX_DAYS, Sale, SaleMemo, comparison, sales_reports, span_ms
from ..sync.oplog import OrderEntry
from .auth import holder_from

DAY = r"^\d{4}-\d{2}-\d{2}$"
HOUR_MS = 3_600_000


def net_per_hour(net: str, worked_ms: int) -> str | None:
    """The net sales for each hour worked; None while nobody has worked any."""
    if worked_ms <= 0:
        return None
    return str((Decimal(net) * HOUR_MS / worked_ms).quantize(Decimal("0.01"), ROUND_HALF_UP))


def clock_part(app: FastAPI, since: int, until: int, net: str) -> dict[str, Any] | None:
    """The time clock's part of a span, where the location uses it: the hours worked on shifts that began
    in it, by how many people, the shifts nobody clocked out of, and the net sales for each hour worked."""
    setting = app.state.settings.get("time_clock")
    if not setting["enabled"]:
        return None
    hours = app.state.clock.report(since, until, breaks_paid=setting["breaks_paid"])
    return {
        "worked_ms": hours["worked_ms"],
        "people": len(hours["people"]),
        "unended": hours["unended"],
        "net_per_hour": net_per_hour(net, hours["worked_ms"]),
    }


def orders_between(app: FastAPI, since: int, until: int) -> list[OrderEntry]:
    """Every order that can count on a day of service between two moments, or was paid in one: changed
    since `since` (the days' own, an older tab paid in them) or promised for a time in between (one rung
    long before counts on its day), as long as it was opened before `until`."""
    store = app.state.store
    entries = {e.order_id: e for e in store.index(active_since=since)}
    for entry in store.index(promised=(since, until)):
        entries.setdefault(entry.order_id, entry)
    return [e for e in entries.values() if e.first_ms is not None and e.first_ms < until]


def a_day(asked: str) -> date:
    try:
        return date.fromisoformat(asked)
    except ValueError as err:
        raise HTTPException(422, {"error": "bad_value", "message": "That is not a day."}) from err


def the_span(first: str | None, last: str | None, now_ms: int) -> tuple[date, date]:
    """The days a report over a span was asked for (`from`, `to`): the day that is running when neither is
    given, that one day when one is. 422 for a first day after the last and for more than `MAX_DAYS` days."""
    if first is None and last is None:
        today = localtime.service_day_of(now_ms)
        return today, today
    days = (a_day(first or last or ""), a_day(last or first or ""))
    if days[0] > days[1]:
        raise HTTPException(422, {"error": "bad_value", "message": "The first day is after the last."})
    if (days[1] - days[0]).days + 1 > MAX_DAYS:
        raise HTTPException(
            422, {"error": "too_long", "message": f"At most {MAX_DAYS} days at a time.", "max_days": MAX_DAYS}
        )
    return days


def add_sales_report(app: FastAPI, memo: SaleMemo | None = None) -> None:
    memo = memo if memo is not None else SaleMemo()
    app.state.sale_memo = memo

    def manager(authorization: str | None) -> Grant:
        return holder_from(app.state, authorization, "reports")

    def sold_in(before: tuple[date, date], span: tuple[date, date]) -> Iterator[Sale]:
        """What each order comes to that can count in either span, or was paid in either."""
        store = app.state.store
        picked = orders_between(app, *span_ms(before[0], span[1]))
        return memo.sales(picked, store.views, taxes=app.state.taxes, rules=app.state.pricing)

    @app.get("/reports/sales")
    def read_sales(
        first: str | None = Query(None, alias="from", pattern=DAY, description="the first day of service"),
        last: str | None = Query(None, alias="to", pattern=DAY, description="the last day of service"),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """The sales of a span of days and of the days to hold beside it: checks, guests, the sales and what
        they come to, the average check and guest, how long a table stood, and the sales by day, by hour,
        by menu and category and by kind of order, with the money taken by how it was paid."""
        manager(authorization)
        now_ms = app.state.store.now_ms()
        span = the_span(first, last, now_ms)
        before = comparison(*span)
        reports = sales_reports(sold_in(before, span), [span, before], defs=app.state.menu.defs, now_ms=now_ms)
        for report in reports:
            report["clock"] = clock_part(app, report["since_ms"], report["until_ms"], report["sales"]["net"])
        return {"span": reports[0], "before": reports[1], "max_days": MAX_DAYS, "now_ms": now_ms}

    @app.get("/reports/dishes")
    def read_dishes(
        first: str | None = Query(None, alias="from", pattern=DAY, description="the first day of service"),
        last: str | None = Query(None, alias="to", pattern=DAY, description="the last day of service"),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """The dishes sold in a span of days and in the days to hold beside it: each dish with how many and
        for how much, its sizes and its options, and every dish on the menu that sold none."""
        manager(authorization)
        now_ms = app.state.store.now_ms()
        span = the_span(first, last, now_ms)
        before = comparison(*span)
        report = dishes_report(sold_in(before, span), span, before, defs=app.state.menu.defs, now_ms=now_ms)
        return {**report, "max_days": MAX_DAYS, "now_ms": now_ms}
