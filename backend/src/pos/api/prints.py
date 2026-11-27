"""The print log on the wire. What is kept and why is in `pos.printing.log`; this is the shape of the calls.

All three want a manager's token, like the printers themselves.

- `GET /print/log?printer=&only=trouble&type=&q=&before=&limit=`: a page of the log, newest first. `prints` is the
  prints: each says what it was (`sort`, `kind`, `title`, `head`), the printer it was made for (`printer`,
  `name`, `address`), when (`at_ms`), where it stands (`status`: `printed`, `waiting`, or `lost` for one
  that was still waiting when the hub stopped), where and when it printed, the tries that failed and the last
  thing that went wrong, what happened to it one thing after the other (`events`), and for a reprint the
  print it repeats (`reprint_of`) and who asked (`by`). `printer` keeps the prints made for one printer (its
  id), `only=trouble` the ones a manager would look at (not printed, a try failed, printed at another
  printer). `type` keeps the prints of one type: `kitchen` and `bar` (an order's tickets, by where their
  dishes are made; a ticket with dishes of both is under both), `bill`, `reprint` (whatever was printed again,
  which is under its own type as well) and `other` (the day's report, pack sheets, prep lists, bag labels,
  notices, test prints). `q` keeps the prints that have its words as they were typed, in either case: in
  what the log's line says of them (what they are called, what for, the stations, the printer, who asked for
  a reprint) or on a line of the paper (a dish, a server, a number; a number typed is a whole number, so
  "table 1" is not table 12); such a print says where on its paper the words were found (`found`, one line
  of it) when its line in the log does not show them. `next` is what to
  send as `before` for the page after, null at the end. `printers` are the printers as they stand now (a
  reprint may go to any of them), `keeps_days` how far back the log goes, and `types` the types this
  restaurant's log can be read by, in the order to offer them (`bar` only where the menu has a bar: see
  `bar_stations`). A hub from before the types sends no `types`, and ignores `type` and `q`.
- `GET /print/log/paper?job=`: one print and its paper, `pages`: the steps a screen draws it from
  (`pos.printing.script`), as it came out.
- `POST /print/log/reprint` `{job, printer}`: prints it again, at the printer it was made for or at
  `printer` (an id), headed REPRINT. 202 with the new print (`print`) and where it went (`printed_at`); 404
  `no_such_print` for a print the log no longer has, 409 `no_printer` when there is no printer to print it at.

The screens that have the log open are told when it changes (topic `prints` of the change feed).
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from ..menu.defs import Definitions
from ..orders.sales import ALCOHOL_CLASS
from ..printing.log import KEEP_DAYS, TYPES, Before, Print
from ..printing.service import NoPrinter, NoSuchPrint, PrintService
from .auth import manager_from

TOPIC = "prints"
"""What the change feed says when the print log has something new to show."""


class ReprintIn(BaseModel):
    """The print to print again, by its job, and the printer to print it at when it is not its own."""

    job: str = Field(min_length=1, max_length=400)
    printer: str | None = Field(None, max_length=64, description="the id of another printer to print it at")


def bar_stations(defs: Definitions) -> frozenset[str]:
    """The stations that are the bar's, from the menu: the ones where most of what is made is a drink of
    the bar (an item taxed as alcohol, or one of the bar's own shelves, `pos.menu.bar`). So the station the
    liquor, the wine, the beer and the cocktails print at is the bar's whatever it is called, and a sushi
    bar, a soda fountain and the takeout counter are not. The print log files a ticket by it."""
    made: dict[str, list[int]] = {}
    for item in defs.items.values():
        station = defs.inherited(item, "station") if item.active else None
        if not station:
            continue
        counted = made.setdefault(station, [0, 0])
        counted[0] += 1
        counted[1] += defs.inherited(item, "tax_class") == ALCOHOL_CLASS or bool(item.attrs.get("bar"))
    return frozenset(station for station, (dishes, drinks) in made.items() if drinks * 2 > dishes)


def _mark(entry: Print) -> str:
    return f"{entry.at_ms}:{entry.job_id}"


def _before(mark: str | None) -> Before | None:
    if mark is None:
        return None
    at, _, job = mark.partition(":")
    try:
        return int(at), job
    except ValueError as err:
        raise HTTPException(422, {"error": "bad_value", "message": "That is not a place in the log."}) from err


def add_print_log(app: FastAPI) -> None:
    printing: PrintService = app.state.printing
    # the screens with the log open read it again when a print is queued, fails for a new reason or prints
    printing.on_log = lambda: app.state.feed.changed(TOPIC)

    # A ticket is the bar's or the kitchen's by the menu, worked out once for each menu the hub sells from.
    kept: list[Any] = [None, frozenset()]

    def bars() -> frozenset[str]:
        defs = app.state.menu.defs
        if kept[0] is not defs:
            kept[0], kept[1] = defs, bar_stations(defs)
        return kept[1]

    printing.bar_stations = bars
    printing.catch_up_log()  # the prints a hub from before the types wrote, filed like the rest

    def types_out() -> list[str]:
        return [t for t in TYPES if t != "bar" or bars()]

    def printers_out() -> list[dict[str, str]]:
        return [{"id": p.id, "name": printing.head(p), "address": p.address} for p in printing.printers]

    @app.get("/print/log")
    def read_print_log(
        printer: str | None = Query(None, max_length=64, description="the prints made for this printer, by its id"),
        only: str | None = Query(None, pattern="^trouble$", description="`trouble`: the ones to look at"),
        type: str | None = Query(None, pattern=f"^({'|'.join(TYPES)})$", description="the prints of one type"),  # noqa: A002
        q: str | None = Query(None, max_length=100, description="the prints that have these words"),
        before: str | None = Query(None, max_length=500, description="`next` of the page before"),
        limit: int = Query(50, ge=1, le=200),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """A page of the print log, newest first (see the module)."""
        manager_from(app.state.tokens, authorization)
        found = printing.log.page(
            printer=printer, trouble=only == "trouble", type=type, q=q, before=_before(before), limit=limit + 1
        )
        page = found[:limit]
        return {
            "prints": [{**printing.seen(entry), **({"found": where} if where else {})} for entry, where in page],
            "next": _mark(page[-1][0]) if len(found) > limit else None,
            "printers": printers_out(),
            "keeps_days": KEEP_DAYS,
            "types": types_out(),
        }

    @app.get("/print/log/paper")
    def read_paper(job: str = Query(min_length=1, max_length=400), authorization: str | None = Header(None)):
        """One print with its paper as it came out, for a screen to draw."""
        manager_from(app.state.tokens, authorization)
        found = printing.paper(job)
        if found is None:
            raise HTTPException(404, {"error": "no_such_print", "message": "That print is no longer in the log."})
        entry, script = found
        return {**printing.seen(entry), "pages": script}

    @app.post("/print/log/reprint", status_code=202)
    def reprint(body: ReprintIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Prints a paper of the log again, headed REPRINT, and writes down who asked."""
        grant = manager_from(app.state.tokens, authorization)
        try:
            _, made = printing.reprint(body.job, printer=body.printer, by=grant.name)
        except NoSuchPrint as err:
            raise HTTPException(
                404, {"error": "no_such_print", "message": "That print is no longer in the log."}
            ) from err
        except NoPrinter as err:
            gone = "That printer is not set up any more." if body.printer else "Its printer is not set up any more."
            raise HTTPException(
                409, {"error": "no_printer", "message": f"{gone} Choose another one.", "printers": printers_out()}
            ) from err
        return {"print": printing.seen(made), "printed_at": {"id": made.printer, "name": made.name}}
