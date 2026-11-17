"""The prep list and the pack sheet on the wire. The figures and the paper live in `pos.printing.prep` and
`pos.printing.pack`; this is the shape of the calls.

- `GET /orders/ahead/prep?day=YYYY-MM-DD`: what the orders ahead for that day of service need made, station
  by station (`prep_list`); without `day`, the day that is running. Anyone at a terminal may read it, like
  the list of orders ahead: it says dishes, not money.
- `POST /orders/ahead/prep/print` `{day, printer}`: the same on paper, at the printer asked for, else where
  the location's bills print. 409 `nothing_to_prep` for a day with no dish ahead, `no_printer` when the
  location has none.
- `POST /orders/{order_id}/pack-sheet` `{printer}`: the order's pack sheet as the order stands now, at the
  printer asked for, else the takeout station's, else where the location's bills print. 409 `not_to_go` for
  a table's order, `nothing_on_order` for one with no dish, `no_printer` when the location has none.

Reading or printing changes nothing on an order.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

from .. import localtime
from ..printing.prep import prep_list, prep_paper
from ..printing.service import PrintService, is_to_go
from .day import DAY, the_day


class PrintPrepIn(BaseModel):
    """The day to print, and the printer this screen keeps for its bills (by id); either may be left out."""

    day: str | None = Field(None, pattern=DAY)
    printer: str | None = Field(None, max_length=64)


class PrintPackIn(BaseModel):
    """The printer to print at (by id), when it is not where pack sheets usually print."""

    printer: str | None = Field(None, max_length=64)


def prep_for(app: FastAPI, asked: str | None = None) -> dict[str, Any]:
    """The prep list as `GET /orders/ahead/prep` answers it, reckoned now: for the day asked, else the one
    that is running."""
    store = app.state.store
    now_ms = store.now_ms()
    day = the_day(asked, now_ms)
    since, until = localtime.service_day(day)
    # the day's orders by their time, and every open order: a late one stands under the day it was for
    entries = {entry.order_id: entry for entry in store.index(promised=(since, until))}
    for entry in store.index(status="open"):
        entries.setdefault(entry.order_id, entry)
    printing: PrintService = app.state.printing
    return prep_list(
        store.views(list(entries.values())),
        day,
        now_ms=now_ms,
        takeout=printing.takeout_station(),
        station_names=printing.station_names() if printing.station_names is not None else {},
    )


def add_prep(app: FastAPI) -> None:
    def printed_at(printing: PrintService, printer: Any) -> dict[str, str]:
        return {"id": printer.id, "name": printing.head(printer)}

    @app.get("/orders/ahead/prep")
    def read_prep(
        day: str | None = Query(None, pattern=DAY, description="the day of service; the running one without it"),
    ) -> dict[str, Any]:
        """What the orders ahead for a day need made: its `orders`, and for each of the `stations` that cook
        for them the dishes added up (`rows`: `label`, `qty`, `first_ms` the earliest time one is for, and
        `ways`, how many are wanted some other way than plain). `dishes` counts what was rung in; `unsent`
        how many of those nobody sent to the kitchen yet."""
        return prep_for(app, day)

    @app.post("/orders/ahead/prep/print", status_code=202)
    def print_prep(body: PrintPrepIn | None = None) -> dict[str, Any]:
        """Prints the day's prep list where the location's bills print (or at `printer`); `printed_at` says
        which printer took it."""
        printing: PrintService = app.state.printing
        printer = printing.bill_printer(body.printer if body is not None else None)
        if printer is None:
            raise HTTPException(409, {"error": "no_printer", "message": "No printer is set up for this location."})
        prep = prep_for(app, body.day if body is not None else None)
        if not prep["dishes"]:
            raise HTTPException(
                409, {"error": "nothing_to_prep", "message": "No dish is on an order ahead for that day."}
            )
        job = printing.queue(prep_paper(prep, at=localtime.now()), printer)
        return {"job_id": job.job_id, "day": prep["day"], "printed_at": printed_at(printing, printer)}

    @app.post("/orders/{order_id}/pack-sheet", status_code=202)
    def print_pack_sheet(order_id: str, body: PrintPackIn | None = None) -> dict[str, Any]:
        """Prints the order's pack sheet: every dish on it as the order stands at this moment, with a box to
        tick, who it is for and when, what its event needs, the money and what else goes in the bag. An order
        of any status prints. `printed_at` says which printer took it."""
        state = app.state.store.view(order_id)
        if state is None:
            raise HTTPException(404, "no such order")
        if not is_to_go(state):
            raise HTTPException(409, {"error": "not_to_go", "message": "A pack sheet is for a to-go order."})
        printing: PrintService = app.state.printing
        if printing.pack_sheet(state) is None:
            raise HTTPException(409, {"error": "nothing_on_order", "message": "There is no dish on this order yet."})
        made = printing.print_pack(state, asked=body.printer if body is not None else None)
        if made is None:
            raise HTTPException(409, {"error": "no_printer", "message": "No printer is set up for this location."})
        job, printer = made
        return {"job_id": job.job_id, "printed_at": printed_at(printing, printer)}
