"""Shipday's deliveries on the wire. The asking and the picture are `pos.shipday`; these are the calls
(docs/shipday.md).

- `GET /shipday`: Shipday's deliveries and drivers as the hub last heard of them.
  `on`: the hub has a key for Shipday; `read`: Shipday has answered at least once since the hub started
  (or since the key was typed); `trouble`: null, or why the last asking got no answer (`since_ms`,
  `reason`: `refused`, `limit`, `unreachable`, `slow`, `error`, `unreadable`, and `said` in words) while
  the rest stays as it was last heard; `eta`: whether Shipday says how far away a delivery is (`off`: not
  asked yet, `on`, `plan`: the account's plan has no such call).
  `orders`: the active ones, as Shipday lists them, each with Shipday's `id` and `number`, where it stands
  (`state`, Shipday's own word), the customer's `name`, `address` and `phone`, the `driver` who has it
  (`id`, `name`, `phone`) or null, its times in ms (`placed_ms`, `due_ms`, `assigned_ms`, `started_ms`,
  `picked_up_ms`, `arrived_ms`, `delivered_ms`), when it is expected there (`eta_ms`, or `eta_said` as
  Shipday wrote it), its amounts as text (`total`, `fee`, `tip`), `payment`, how many dishes (`items`),
  the `note` for the driver, the customer's `tracking` page, whether it was placed for later
  (`scheduled`), and `pos`: the check it is on the POS (`order_id`, `order_no`, `status`, `stage`, and
  `by`: how the two were put together, `number` or `phone`) or null when the hub finds none.
  `done`: the ones that left the list during this day of service, the last first, the same way, with
  `ended_ms` and the `state` Shipday gave them at the end (`GONE` when it did not say).
  `drivers`: every driver of the account, with `id`, `name`, `phone`, `on_shift`, `active` and how many
  active orders they have (`orders`).
  With `looking=true` the hub takes it that a screen shows the answer, and asks Shipday oftener for the
  next two minutes. Without, that somebody is at a terminal: it keeps asking once a minute, where a hub
  nobody has asked for ten minutes asks every five. Anyone at a terminal may read it, like the list of
  orders: it names customers and where their orders go, as that list does. 404 on a hub older than this.
- `POST /shipday/ask`: asks Shipday now, out of the hub's own turn: the screen's button. Not passed on to
  Shipday within ten seconds of the last asking (`soon` is then true). Answers `asked`, `answered`, `soon`,
  why it was not answered (`reason`, `said`) and the picture after it (`shipday`). 409 `no_key` on a hub
  without a key.

The key is one of the hub's (`shipday`; `pos.keys`, `pos.api.keys`): `GET /hub/keys` says how the asking
goes (`shipday`) and `POST /hub/shipday/try` tries the key.

Reading changes nothing on the POS and nothing in Shipday. No call here writes to Shipday.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from starlette.concurrency import run_in_threadpool

from .. import localtime
from ..keys import SHIPDAY, HubKeys
from ..shipday.board import ShipdayBoard
from ..shipday.client import Shipday
from ..shipday.match import OnPos, on_pos
from .sales import orders_between

log = logging.getLogger("pos.shipday")

TOPIC = "shipday"
"""What the change feed says when Shipday's deliveries or drivers read differently, or the key changed."""


def source_for(keys: HubKeys, **made_with: Any) -> Shipday | None:
    """What the hub asks Shipday with: the key in force, or nothing without one. `made_with` is handed to
    the client (the tests give it a stand-in for the internet)."""
    data = keys.data(SHIPDAY)
    return Shipday(data["key"], **made_with) if data is not None else None


def use_shipday(app: FastAPI) -> None:
    """The key in force now is the one Shipday is asked with: typed, replaced or removed while the hub runs.
    The asking starts with the first key, where the hub is serving."""
    board: ShipdayBoard = app.state.shipday
    was = board.configured
    board.use(source_for(app.state.keys, **app.state.shipday_made_with))
    if app.state.asks_shipday:
        board.start()  # nothing where it already runs, and nothing without a key
    if was != board.configured:
        log.warning("shipday: %s", "the hub asks it now" if board.configured else "no key now, nothing is asked")
    app.state.feed.changed(TOPIC)  # the screens say whether the hub reads Shipday


def deliveries_on_pos(app: FastAPI) -> list[OnPos]:
    """The POS's own deliveries of the day of service that is running, as the matching wants them."""
    store = app.state.store
    since, until = localtime.service_day(localtime.service_day_of(store.now_ms()))
    states = store.views(orders_between(app, since, until))
    return [delivery for state in states if (delivery := on_pos(state)) is not None]


def add_shipday(app: FastAPI) -> None:
    board: ShipdayBoard = app.state.shipday
    board.pos = lambda: deliveries_on_pos(app)
    board.on_change = lambda: app.state.feed.changed(TOPIC)

    @app.get("/shipday")
    def read_shipday(
        looking: bool = Query(False, description="a screen shows the answer: Shipday is asked oftener for a while"),
    ) -> dict[str, Any]:
        """Shipday's deliveries and drivers as the hub last heard of them, each delivery with the check it
        is on the POS."""
        board: ShipdayBoard = app.state.shipday
        if looking:
            board.watched()
        else:
            board.seen()
        return board.said()

    @app.post("/shipday/ask")
    async def ask_shipday() -> dict[str, Any]:
        """Asks Shipday now, as the hub does by itself every few seconds while a screen looks."""
        board: ShipdayBoard = app.state.shipday
        if not board.configured:
            raise HTTPException(409, {"error": "no_key", "message": "this hub has no key for Shipday yet"})
        board.watched()
        asked = await run_in_threadpool(board.ask_now)
        return {**asked, "shipday": await run_in_threadpool(board.said)}
