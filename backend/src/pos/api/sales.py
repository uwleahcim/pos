"""Sales over a span of days on the wire. The figures live in `pos.orders.sales`; this is the call.

- `GET /reports/sales?from=YYYY-MM-DD&to=YYYY-MM-DD` (manager token): `span`, the sales of those days of
  service, and `before`, the same figures for as many days the fewest whole weeks earlier
  (`pos.orders.sales.comparison`), to hold beside them. Without `from` and `to`, the day that is running;
  with one of them, that one day. 422 `bad_value` for a first day after the last, 422 `too_long` for more
  than `max_days` days.
- Each of the two carries `clock` where the location uses the time clock, else null: the hours worked on
  shifts that began in those days, by how many people, how many shifts nobody clocked out of, and
  `net_per_hour`, the net sales for each hour worked.

Reading it changes nothing and nothing is written down: both are reckoned from the log. What each check
comes to is remembered in memory while its log stays as it was (`pos.orders.sales.SaleMemo`), so the first
reading of a long span takes a few seconds and the next ones do not.
"""

from __future__ import annotations

from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query

from .. import localtime
from ..identity.tokens import Grant
from ..orders.sales import MAX_DAYS, SaleMemo, comparison, sales_reports, span_ms
from .auth import manager_from

DAY = r"^\d{4}-\d{2}-\d{2}$"
HOUR_MS = 3_600_000


def add_sales_report(app: FastAPI, memo: SaleMemo | None = None) -> None:
    memo = memo if memo is not None else SaleMemo()
    app.state.sale_memo = memo

    def manager(authorization: str | None) -> Grant:
        return manager_from(app.state.tokens, authorization)

    def a_day(asked: str) -> date:
        try:
            return date.fromisoformat(asked)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": "That is not a day."}) from err

    def the_span(first: str | None, last: str | None, now_ms: int) -> tuple[date, date]:
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

    def clock_part(since: int, until: int, net: str) -> dict[str, Any] | None:
        setting = app.state.settings.get("time_clock")
        if not setting["enabled"]:
            return None
        hours = app.state.clock.report(since, until, breaks_paid=setting["breaks_paid"])
        worked = hours["worked_ms"]
        each = (Decimal(net) * HOUR_MS / worked).quantize(Decimal("0.01"), ROUND_HALF_UP) if worked > 0 else None
        return {
            "worked_ms": worked,
            "people": len(hours["people"]),
            "unended": hours["unended"],
            "net_per_hour": None if each is None else str(each),
        }

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
        store = app.state.store
        now_ms = store.now_ms()
        span = the_span(first, last, now_ms)
        before = comparison(*span)
        since, until = span_ms(before[0], span[1])
        # Every order changed since the earlier span began (its own and the later span's, an older tab paid
        # in either), and every order promised for a day from then on (one rung long before counts on its
        # day), as long as it was opened before the later span ended.
        entries = {e.order_id: e for e in store.index(active_since=since)}
        for entry in store.index(promised=(since, until)):
            entries.setdefault(entry.order_id, entry)
        picked = [e for e in entries.values() if e.first_ms is not None and e.first_ms < until]
        sold = memo.sales(picked, store.views, taxes=app.state.taxes, rules=app.state.pricing)
        reports = sales_reports(sold, [span, before], defs=app.state.menu.defs, now_ms=now_ms)
        for report in reports:
            report["clock"] = clock_part(report["since_ms"], report["until_ms"], report["sales"]["net"])
        return {"span": reports[0], "before": reports[1], "max_days": MAX_DAYS, "now_ms": now_ms}
