"""The guest display on the wire (docs/guest-display.md). What a guest reads is worked out in
`pos.guest_display`; these are the calls.

- `POST /guest-display/showing` `{"device": "mac1", "order_id": "o-17"}`: the screen `mac1` has this order
  open now; `order_id` null, or left out, when it has none open any more. Every screen where orders are taken
  says it, whether a display is linked to it or not: it is one small call as an order is opened and one as
  it is left. News of it goes out on the change feed as the topic `showing`.
- `GET /guest-display?of=mac1`: what the display linked to `mac1` shows now. `showing` is the order that
  screen has open (null: none); `order` is that order as a guest reads it (`guest_view`), or null while
  there is nothing to show of it (no dish on it yet, an order the hub has not been sent yet, a voided one);
  `left` is the order that screen had open before (`order_id`), whether it is paid in full now
  (`paid_in_full`) and what to call its guest (`name`), so the display can thank the guest whose order was
  paid and left in one tap, or null;
  `guest` is how to greet the guest of the order that screen has open: `name`, what to call them, and
  `back`, whether they have been here before; null when the order names nobody and carries no number that
  ordered before. It is there before the first dish is, so the display greets by name the moment the order
  is opened;
  `head` is the restaurant's own lines, as on its bills, for the display to greet with; `known` says whether
  the hub hears from that screen at all right now. A display holds the change feed open and reads this again
  when `showing` is told or the order it shows changes, so an answer that has not changed costs a 304.
- `GET /settings/guest_display`, `PUT /settings/guest_display` (manager token): what every guest display
  shows besides the order: `tips` (suggest a tip under the total; off until a manager turns it on),
  `tip_percents` (one to three whole percentages) and `tip_base` (`before_tax` or `after_tax`). An order's
  `tips` in the answer above are worked out from it (`pos.guest_display.tips_of`).

Who the guest is follows the guest list (docs/guest-list.md): the one who pays the check (`payer_of`), so
the number typed on the order, or the party seated on a table's check. "Back" means that number ordered
before, or sat on another check: read from the log's index, and kept for a minute, since a display reads
again with every dish.

Anyone at a terminal may read it, like an order's check: it is the check, with less on it.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Response
from fastapi.encoders import jsonable_encoder
from pydantic import BaseModel, Field

from .. import localtime
from ..customers import SHORTEST
from ..devices import DevicesSeen
from ..guest_display import Showing, guest_view, host_view, tips_of
from ..orders.check import check_for
from ..orders.guests import payer_of
from ..printing.bill import bill_for
from ..settings import SettingStore, clean_guest_display
from ..sync.oplog import OrderState, phone_digits
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

BACK_KEPT_S = 60.0
"""How long the hub keeps whether a number has been here before: a display reads again with every dish rung
in, and the answer changes only when an older order is voided."""


class ShowingIn(BaseModel):
    """What a screen has open: `device` is its name, `order_id` the order, or null for none."""

    device: str = Field(min_length=1, max_length=120)
    order_id: str | None = Field(None, max_length=200)


class GuestDisplayIn(BaseModel):
    """What the guest displays show besides the order; one left out keeps its value."""

    tips: bool | None = None
    tip_percents: list[int] | None = None
    tip_base: str | None = None


def add_guest_display(app: FastAPI, head: Callable[[], tuple[str, ...]]) -> None:
    """`head` answers the restaurant's own lines as its bills carry them."""
    devices: DevicesSeen = app.state.devices
    been: dict[tuple[str, str], tuple[float, bool]] = {}  # (order, number) -> (when asked, been here before)

    def seen(state: OrderState | None) -> dict[str, Any] | None:
        """An order as a guest reads it now, or None: the hub does not have it, or there is nothing to show."""
        if state is None:
            return None
        settings: SettingStore = app.state.settings
        check = check_for(state, app.state.taxes, app.state.pricing)
        return guest_view(
            bill_for(check, state.fields, at=localtime.now()),
            state.fields,
            state.status,
            tips=tips_of(check, settings.get("guest_display")),
        )

    def back(state: OrderState, phone: str) -> bool:
        """Whether this number ordered before this order was opened, or sat on another check."""
        if len(phone) < SHORTEST:
            return False
        now, key = time.monotonic(), (state.order_id, phone)
        kept = been.get(key)
        if kept is not None and now - kept[0] < BACK_KEPT_S:
            return kept[1]
        opened = state.first.wall_ms if state.first is not None else None
        answer = any(
            entry.order_id != state.order_id
            and entry.status != "void"
            and entry.first_ms is not None
            and (opened is None or entry.first_ms < opened)
            for entry in app.state.store.index(phone=phone)
        ) or any(guest.order_id != state.order_id for guest in app.state.check_guests.of_phone(phone))
        if len(been) > 500:
            been.clear()
        been[key] = (now, answer)
        return answer

    def host(state: OrderState | None) -> dict[str, Any] | None:
        """How to greet the guest of an order (`host_view`), or None: a voided order, or nobody to name. The
        guest is the one who pays the check, as the guest list has it: the number typed on the order, or the
        party seated on a table's check; with several parties and no word on who pays, nobody yet."""
        if state is None or state.status == "void":
            return None
        typed = phone_digits(state.fields.get("phone"))
        seated = app.state.check_guests.on({state.order_id})
        said = next((guest.phone for guest in seated if guest.pays), "")
        payer = payer_of(typed, [guest.phone for guest in seated], said)
        name: Any = state.fields.get("customer_name")
        party = next((guest for guest in seated if guest.phone == payer), None) if payer else None
        if party is not None and (payer != typed or not str(name or "").strip()):
            name = party.name
        elif seated and not payer and not typed:
            name = None  # several parties at the table and nobody said who pays: no name is the right one
        return host_view(name, back=back(state, payer) if payer else False)

    @app.get("/settings/guest_display")
    def read_guest_display_setting() -> dict[str, Any]:
        """What every guest display shows besides the order: whether it suggests a tip (`tips`), the
        percentages (`tip_percents`) and what they are percentages of (`tip_base`)."""
        settings: SettingStore = app.state.settings
        return settings.get("guest_display")

    @app.put("/settings/guest_display")
    def write_guest_display_setting(body: GuestDisplayIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets it. Every guest display follows at once."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        try:
            cleaned = clean_guest_display({**settings.get("guest_display"), **body.model_dump(exclude_none=True)})
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = settings.put("guest_display", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return saved

    @app.post("/guest-display/showing")
    def say_showing(body: ShowingIn) -> dict[str, Any]:
        """A screen says which order it has open, or that it has none. Answers what the hub now holds."""
        showing: Showing = app.state.showing
        devices.heard(body.device)
        order_id = (body.order_id or "").strip() or None
        if showing.say(body.device, order_id):
            app.state.feed.changed("showing")
        return {"device": body.device, "order_id": order_id}

    @app.get("/guest-display")
    def read_guest_display(
        of: str = Query(min_length=1, max_length=120, description="the screen the display is linked to, by name"),
    ) -> Response:
        """What a guest display linked to the screen `of` shows now (see the module)."""
        showing: Showing = app.state.showing
        store = app.state.store
        order_id, left_id = showing.of(of), showing.left(of)
        state = store.view(order_id) if order_id is not None else None
        gone = store.view(left_id) if left_id is not None else None
        left = seen(gone)
        left_host = host(gone)
        answer = {
            "of": of,
            "known": showing.known(of),
            "head": list(head()),
            "showing": order_id,
            "order": seen(state),
            "guest": host(state),
            "left": None
            if left_id is None
            else {
                "order_id": left_id,
                "paid_in_full": left is not None and left["paid_in_full"],
                "name": left_host["name"] if left_host is not None else "",
            },
        }
        body = json.dumps(answer, ensure_ascii=False, allow_nan=False, separators=(",", ":"), default=jsonable_encoder)
        return Response(body.encode("utf-8"), media_type="application/json")
