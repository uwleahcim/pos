"""The stations' screens on the wire. What a screen lists is worked out in `pos.printing.screen`; these are
the calls.

- `GET /kitchen/screen?stations=wok,fryer`: the tickets the screen of those stations still has to make and
  the last ones it finished (`kitchen_screen`). Anyone at a terminal may read it, like the list of orders:
  it says dishes and tables, never money. A screen polls it, so an answer that has not changed costs a 304.
- `GET /settings/kitchen_screens`, `PUT /settings/kitchen_screens` (manager token): the minutes after which a
  ticket turns amber (`warn`) and red (`late`); 0 for never.

A cook marks a dish made with a `done` operation on the order, through `POST /orders/{id}/ops` like every
other change to an order (`pos.sync.oplog`): there is no call of its own for it.
"""

from __future__ import annotations

import json
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Response
from fastapi.encoders import jsonable_encoder
from pydantic import BaseModel

from ..printing.screen import KEEP_MS, kitchen_screen
from ..printing.service import PrintService
from ..settings import STATION, SettingStore, clean_kitchen_screens
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

STATIONS_MAX = 8
"""The most stations one screen stands for: two woks and a fryer, not the whole kitchen (that is the pass)."""
AHEAD_MS = 24 * 60 * 60 * 1000
"""How far ahead an order can be promised and still be looked at for the screens: the time quoted to make one
is minutes or hours, not days."""


class KitchenScreensIn(BaseModel):
    """After how many minutes in the kitchen a ticket turns amber and red; one left out keeps its value."""

    warn: int | None = None
    late: int | None = None


def add_kitchen(app: FastAPI) -> None:
    @app.get("/kitchen/screen")
    def read_kitchen_screen(
        stations: str = Query(max_length=300, description="the screen's stations by code, with commas between"),
    ) -> Response:
        """What the screen of these stations has to make: `tickets`, the longest in the kitchen first, each
        with whose it is, since when, and its `lines` as the paper ticket words them; `recent`, the last ones
        it finished; and `warn` and `late`, the minutes after which a ticket turns amber and red."""
        codes = list(dict.fromkeys(code.strip() for code in stations.split(",") if code.strip()))
        if not codes or len(codes) > STATIONS_MAX or not all(STATION.match(code) for code in codes):
            raise HTTPException(422, {"error": "bad_value", "message": "Name one to eight stations by their codes."})
        store = app.state.store
        now_ms = store.now_ms()
        # the open orders, the ones that changed while a ticket could still be on a screen (a to-go order
        # paid and closed is still being cooked), and the ones promised for about now (a catering order paid
        # and closed days ago)
        entries = {entry.order_id: entry for entry in store.index(status="open")}
        for more in (
            store.index(active_since=now_ms - KEEP_MS),
            store.index(promised=(now_ms - KEEP_MS, now_ms + AHEAD_MS)),
        ):
            for entry in more:
                entries.setdefault(entry.order_id, entry)
        printing: PrintService = app.state.printing
        settings: SettingStore = app.state.settings
        screen = kitchen_screen(
            store.views(list(entries.values())),
            codes,
            now_ms=now_ms,
            waiting=printing.not_yet(),
            takeout=printing.takeout_station(),
            skips=printing.skips,
            station_names=printing.station_names() if printing.station_names is not None else {},
            course_names=printing.course_names() if printing.course_names is not None else {},
            allergens=printing.allergen_names(),
            minutes=settings.get("kitchen_screens"),
        )
        body = json.dumps(screen, ensure_ascii=False, allow_nan=False, separators=(",", ":"), default=jsonable_encoder)
        return Response(body.encode("utf-8"), media_type="application/json")

    @app.get("/settings/kitchen_screens")
    def read_kitchen_screens() -> dict[str, Any]:
        """The colours of a ticket on a station's screen: the minutes it has been in the kitchen when it turns
        amber (`warn`) and red (`late`); 0 for never."""
        settings: SettingStore = app.state.settings
        return settings.get("kitchen_screens")

    @app.put("/settings/kitchen_screens")
    def write_kitchen_screens(body: KitchenScreensIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets when a ticket turns amber and red. Every station's screen follows at once."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        try:
            cleaned = clean_kitchen_screens({**settings.get("kitchen_screens"), **body.model_dump(exclude_none=True)})
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = settings.put("kitchen_screens", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return saved
