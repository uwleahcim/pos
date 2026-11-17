"""The day's report on the wire. The figures live in `pos.orders.day`; this is the shape of the calls.

- `GET /reports/day?day=YYYY-MM-DD` (manager token): the report for that day of service, four in the morning
  to four the next; without `day`, the day that is running. See `day_report` for every figure and how they
  add up. `clock` is the time clock's part where the location uses it (hours worked that day, how many
  people, shifts nobody clocked out of, and for the running day who is on the clock now), else null.
- `POST /reports/day/print` `{day, printer}` (manager token): the same figures on paper, at the printer
  asked for, else where the location's bills print. 409 `no_printer` when the location has none.

Reading a day changes nothing, and no day is closed: the report is reckoned again each time it is asked.
"""

from __future__ import annotations

from datetime import date
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from .. import localtime
from ..identity.tokens import Grant
from ..orders.day import day_report
from ..printing.day import day_paper
from ..printing.service import PrintService
from .auth import holder_from

DAY = r"^\d{4}-\d{2}-\d{2}$"


class PrintDayIn(BaseModel):
    """The day to print, and the printer this screen keeps for its bills (by id); either may be left out."""

    day: str | None = Field(None, pattern=DAY)
    printer: str | None = Field(None, max_length=64)


def add_day_report(app: FastAPI) -> None:
    def manager(authorization: str | None) -> Grant:
        return holder_from(app.state, authorization, "reports")

    def the_day(asked: str | None, now_ms: int) -> date:
        if asked is None:
            return localtime.service_day_of(now_ms)
        try:
            return date.fromisoformat(asked)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": "That is not a day."}) from err

    def clock_part(since: int, until: int, today: bool) -> dict[str, Any] | None:
        setting = app.state.settings.get("time_clock")
        if not setting["enabled"]:
            return None
        hours = app.state.clock.report(since, until, breaks_paid=setting["breaks_paid"])
        return {
            "worked_ms": hours["worked_ms"],
            "people": len(hours["people"]),
            "unended": hours["unended"],
            "on_now": [
                {
                    "staff_id": s["staff_id"],
                    "name": s["name"],
                    "role": s["role"],
                    "state": s["state"],
                    "in_ms": s["in_ms"],
                }
                for s in (hours["on_now"] if today else [])
            ],
        }

    def report_for(asked: str | None) -> dict[str, Any]:
        store = app.state.store
        now_ms = store.now_ms()
        day = the_day(asked, now_ms)
        since, until = localtime.service_day(day)
        # Every order opened before the day ended and touched since it began (the day's own, an older tab
        # paid that night), every order promised for the day (one rung earlier for it counts on it, even paid
        # and closed the day it was rung), and every order still open.
        entries = {e.order_id: e for e in store.index(active_since=since)}
        for entry in (*store.index(promised=(since, until)), *store.index(status="open")):
            entries.setdefault(entry.order_id, entry)
        picked = [e for e in entries.values() if e.first_ms is not None and e.first_ms < until]
        report = day_report(
            store.views(picked),
            day,
            taxes=app.state.taxes,
            rules=app.state.pricing,
            defs=app.state.menu.defs,
            now_ms=now_ms,
        )
        report["clock"] = clock_part(since, until, report["today"])
        return report

    @app.get("/reports/day")
    def read_day(
        day: str | None = Query(None, pattern=DAY, description="the day of service; the running one without it"),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """The day's report: sales, the money taken by how it was paid, the sales by menu and category, by
        kind of order, by who rang them in and by hour, what came off the checks, and what is still open."""
        manager(authorization)
        return report_for(day)

    @app.post("/reports/day/print", status_code=202)
    def print_day(body: PrintDayIn | None = None, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Prints the day's report where the location's bills print (or at `printer`); `printed_at` says
        which printer took it."""
        grant = manager(authorization)
        printing: PrintService = app.state.printing
        printer = printing.bill_printer(body.printer if body is not None else None)
        if printer is None:
            raise HTTPException(409, {"error": "no_printer", "message": "No printer is set up for this location."})
        report = report_for(body.day if body is not None else None)
        header = tuple(app.state.settings.get("bill")["header"])
        paper = day_paper(report, head=header, at=localtime.now(), by=grant.name)
        job = printing.queue(paper, printer)
        return {
            "job_id": job.job_id,
            "day": report["day"],
            "printed_at": {"id": printer.id, "name": printing.head(printer)},
        }
