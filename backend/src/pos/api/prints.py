"""The print log on the wire. What is kept and why is in `pos.printing.log`; this is the shape of the calls.

All three want a manager's token, like the printers themselves.

- `GET /print/log?printer=&only=trouble&before=&limit=`: a page of the log, newest first. `prints` is the
  prints: each says what it was (`sort`, `kind`, `title`, `head`), the printer it was made for (`printer`,
  `name`, `address`), when (`at_ms`), where it stands (`status`: `printed`, `waiting`, or `lost` for one
  that was still waiting when the hub stopped), where and when it printed, the tries that failed and the last
  thing that went wrong, what happened to it one thing after the other (`events`), and for a reprint the
  print it repeats (`reprint_of`) and who asked (`by`). `printer` keeps the prints made for one printer (its
  id), `only=trouble` the ones a manager would look at (not printed, a try failed, printed at another
  printer). `next` is what to send as `before` for the page after, null at the end. `printers` are the
  printers as they stand now (a reprint may go to any of them), `keeps_days` how far back the log goes.
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

from ..printing.log import KEEP_DAYS, Before, Print
from ..printing.service import NoPrinter, NoSuchPrint, PrintService
from .auth import manager_from

TOPIC = "prints"
"""What the change feed says when the print log has something new to show."""


class ReprintIn(BaseModel):
    """The print to print again, by its job, and the printer to print it at when it is not its own."""

    job: str = Field(min_length=1, max_length=400)
    printer: str | None = Field(None, max_length=64, description="the id of another printer to print it at")


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

    def printers_out() -> list[dict[str, str]]:
        return [{"id": p.id, "name": printing.head(p), "address": p.address} for p in printing.printers]

    @app.get("/print/log")
    def read_print_log(
        printer: str | None = Query(None, max_length=64, description="the prints made for this printer, by its id"),
        only: str | None = Query(None, pattern="^trouble$", description="`trouble`: the ones to look at"),
        before: str | None = Query(None, max_length=500, description="`next` of the page before"),
        limit: int = Query(50, ge=1, le=200),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """A page of the print log, newest first (see the module)."""
        manager_from(app.state.tokens, authorization)
        found = printing.log.list(printer=printer, trouble=only == "trouble", before=_before(before), limit=limit + 1)
        page = found[:limit]
        return {
            "prints": [printing.seen(entry) for entry in page],
            "next": _mark(page[-1]) if len(found) > limit else None,
            "printers": printers_out(),
            "keeps_days": KEEP_DAYS,
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
