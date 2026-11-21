"""Contests for the staff on the wire. The rules live in `pos.orders.contest`; these are the calls.

- `GET /settings/contests`: the contests the location keeps, each as it was set up with what it counts called
  as the menu calls it today, its `state` (`coming`, `running`, `over`) and whether the staff's screens show
  it (`shown`: until a week after its last day); `today`, the day of service that is running; the `roles`
  that can take part, the `categories` one can count (each with a dish on sale, in the menu's order) and the
  `limits`. No number is in it: it is open like the other settings, so a screen knows whether there is a
  contest to offer.
- `PUT /settings/contests` `{contests: [...]}` (a manager's or an owner's token): the whole list. A contest
  without an `id` is new. The dish or the category of a new contest, or of one that now counts something
  else, has to be on the menu (422 `unknown_dish`, `unknown_category`); the hub writes down what it is
  called, who saved the contest and when.
- `GET /contests?staff_id=`: the contests the staff's screens show, as that person may see each: where it
  stands for them (`me`: their `place`, `count` and `amount`; null for somebody who does not take part), how
  many take part (`of`), who is in `front` by name, and every row (`standings`) only for a contest whose
  board is for everybody. Staff have no token: a screen passes who is signed in, as it does for the waste
  log. 404 `unknown_staff`.
- `GET /reports/contests/{id}` (the `reports` power): one contest with its whole board, `standings`, what
  those rows add up to (`total`) and what everybody else rang of the same (`others`). 404 `unknown_contest`.

Reading changes nothing and nothing is written down: who is ahead is added up from the checks each time,
through the same remembered sales as the sales report (`pos.orders.sales.SaleMemo`).
"""

from __future__ import annotations

from datetime import date
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from .. import localtime
from ..identity.staff import Directory
from ..menu.defs import Definitions
from ..orders.contest import (
    CONTESTS_MAX,
    NAME_MAX,
    NOTE_MAX,
    RECENT_DAYS,
    ROLES,
    STANDARD_ROLES,
    Board,
    Contest,
    boards,
    categories_on,
    clean_contests,
    contests_of,
)
from ..orders.sales import MAX_DAYS, span_ms
from ..settings import SettingStore
from ..sync.pgstore import ReadOnlyError
from .auth import holder_from, manager_from
from .sales import orders_between


class ContestIn(BaseModel):
    """One contest as a manager's screen sends it."""

    id: str | None = Field(None, max_length=64)
    name: str = ""
    note: str = ""
    counts: str = "sales"
    item: str | None = Field(None, max_length=200)
    category: str | None = Field(None, max_length=200)
    first: str = ""
    last: str = ""
    roles: list[str] | None = None
    board: str = "own"


class ContestsIn(BaseModel):
    contests: list[ContestIn] = Field(default_factory=list)


def add_contests(app: FastAPI) -> None:
    def kept() -> list[Contest]:
        return contests_of(app.state.settings.get("contests"))

    def today() -> date:
        return localtime.service_day_of(app.state.store.now_ms())

    def listing() -> dict[str, Any]:
        day, defs = today(), app.state.menu.defs
        return {
            "contests": [contest.about(day, defs) for contest in kept()],
            "today": day.isoformat(),
            "roles": list(ROLES),
            "standard_roles": list(STANDARD_ROLES),
            "categories": categories_on(defs),
            "limits": {
                "contests": CONTESTS_MAX,
                "name": NAME_MAX,
                "note": NOTE_MAX,
                "days": MAX_DAYS,
                "shown_days": RECENT_DAYS,
            },
        }

    def standing(contests: list[Contest]) -> dict[str, Board]:
        """Where each of these contests stands now, from every order that counts on one of their days."""
        if not contests:
            return {}
        store = app.state.store
        since, until = span_ms(min(c.first for c in contests), max(c.last for c in contests))
        picked = orders_between(app, since, until)
        sales = app.state.sale_memo.sales(picked, store.views, taxes=app.state.taxes, rules=app.state.pricing)
        directory: Directory = app.state.staff
        return boards(sales, contests, defs=app.state.menu.defs, staff=directory.all())

    def named(contest: Contest, before: Contest | None, defs: Definitions) -> str:
        """What the contest's dish or category is called, to write down beside it: the menu's name for it
        now. One the menu does not have is refused, unless the contest counted it already (a dish taken off
        the menu since leaves its contest as it was)."""
        if contest.counts == "sales":
            return ""
        code = contest.item if contest.counts == "dish" else contest.category
        known = defs.items.get(code or "") if contest.counts == "dish" else defs.categories.get(code or "")
        if known is not None:
            return defs.localizer.text(known.names, "en") or str(code)
        if before is not None and (before.counts, before.item, before.category) == (
            contest.counts,
            contest.item,
            contest.category,
        ):
            return before.what
        kind = "dish" if contest.counts == "dish" else "category"
        raise HTTPException(
            422,
            {"error": f"unknown_{kind}", "message": f"{contest.name}: that {kind} is not on the menu."},
        )

    @app.get("/settings/contests")
    def read_contests() -> dict[str, Any]:
        """The contests the location keeps and where each stands in time. No number is in it."""
        return listing()

    @app.put("/settings/contests")
    def write_contests(body: ContestsIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager or an owner sets the contests: the whole list, a new one without an id. Taking a contest
        out of the list ends it for everybody; no sale is touched either way."""
        grant = manager_from(app.state.tokens, authorization)
        try:
            cleaned = clean_contests(body.model_dump())
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        before = {contest.id: contest for contest in kept()}
        defs: Definitions = app.state.menu.defs
        now_ms = app.state.store.now_ms()
        stored: list[dict[str, Any]] = []
        for entry in cleaned["contests"]:
            contest = Contest.of(entry)
            if contest is None:  # it was just checked: this cannot be
                raise HTTPException(422, {"error": "bad_value", "message": "That contest does not read."})
            was = before.get(contest.id)
            entry["what"] = named(contest, was, defs)
            if was is not None and was.same_rules(contest):
                entry["set_by"], entry["set_ms"] = was.set_by, was.set_ms  # as it was: nobody changed it
            else:
                entry["set_by"], entry["set_ms"] = grant.name, now_ms
            stored.append(entry)
        settings: SettingStore = app.state.settings
        try:
            settings.put("contests", {"contests": stored})
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")  # every screen's menu offers the board, or stops offering it
        return listing()

    @app.get("/contests")
    def read_my_contests(staff_id: str = Query(min_length=1, max_length=120)) -> dict[str, Any]:
        """The contests on the staff's screens, as the person signed in may see each: their own number and
        place, who is in front, and the whole board only where the contest says everybody sees it."""
        directory: Directory = app.state.staff
        if directory.get(staff_id) is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        day, defs = today(), app.state.menu.defs
        shown = [contest for contest in kept() if contest.shown(day)]
        stand = standing([contest for contest in shown if contest.state(day) != "coming"])
        # not begun: who takes part is known already, and nothing counts yet
        coming = [contest for contest in shown if contest.id not in stand]
        stand.update(boards((), coming, defs=defs, staff=directory.all()))
        return {
            "contests": [{**contest.about(day, defs), **stand[contest.id].seen_by(staff_id)} for contest in shown],
            "today": day.isoformat(),
            "now_ms": app.state.store.now_ms(),
        }

    @app.get("/reports/contests/{contest_id}")
    def read_contest(contest_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """One contest with its whole board: everybody who takes part, the one in front first, what they
        add up to and what everybody else rang of the same."""
        holder_from(app.state, authorization, "reports")
        contest = next((c for c in kept() if c.id == contest_id), None)
        if contest is None:
            raise HTTPException(404, {"error": "unknown_contest", "message": "There is no such contest."})
        day = today()
        board = standing([contest])[contest.id]
        return {
            **contest.about(day, app.state.menu.defs),
            **board.whole(),
            "of": len(board.rows),
            "today": day.isoformat(),
            "now_ms": app.state.store.now_ms(),
        }
