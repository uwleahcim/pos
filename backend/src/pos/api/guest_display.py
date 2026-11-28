"""The guest display on the wire (docs/guest-display.md). What a guest reads is worked out in
`pos.guest_display`; these are the calls.

- `POST /guest-display/showing` `{"device": "mac1", "order_id": "o-17"}`: the screen `mac1` has this order
  open now; `order_id` null, or left out, when it has none open any more. Every screen where orders are taken
  says it, whether a display is linked to it or not: it is one small call as an order is opened and one as
  it is left. News of it goes out on the change feed as the topic `showing`.
- `GET /guest-display?of=mac1`: what the display linked to `mac1` shows now. `showing` is the order that
  screen has open (null: none); `order` is that order as a guest reads it (`guest_view`), or null while
  there is nothing to show of it (no dish on it yet, an order the hub has not been sent yet, a voided one);
  `left` is the order that screen had open before (`order_id`) and whether it is paid in full now
  (`paid_in_full`), so the display can thank the guest whose order was paid and left in one tap, or null;
  `head` is the restaurant's own lines, as on its bills, for the display to greet with; `known` says whether
  the hub hears from that screen at all right now. A display holds the change feed open and reads this again
  when `showing` is told or the order it shows changes, so an answer that has not changed costs a 304.

Anyone at a terminal may read it, like an order's check: it is the check, with less on it.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

from fastapi import FastAPI, Query, Response
from fastapi.encoders import jsonable_encoder
from pydantic import BaseModel, Field

from .. import localtime
from ..devices import DevicesSeen
from ..guest_display import Showing, guest_view
from ..orders.check import check_for
from ..printing.bill import bill_for


class ShowingIn(BaseModel):
    """What a screen has open: `device` is its name, `order_id` the order, or null for none."""

    device: str = Field(min_length=1, max_length=120)
    order_id: str | None = Field(None, max_length=200)


def add_guest_display(app: FastAPI, head: Callable[[], tuple[str, ...]]) -> None:
    """`head` answers the restaurant's own lines as its bills carry them."""
    devices: DevicesSeen = app.state.devices

    def seen(order_id: str) -> dict[str, Any] | None:
        """An order as a guest reads it now, or None: the hub does not have it, or there is nothing to show."""
        state = app.state.store.view(order_id)
        if state is None:
            return None
        check = check_for(state, app.state.taxes, app.state.pricing)
        return guest_view(bill_for(check, state.fields, at=localtime.now()), state.fields, state.status)

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
        order_id, left_id = showing.of(of), showing.left(of)
        left = seen(left_id) if left_id is not None else None
        answer = {
            "of": of,
            "known": showing.known(of),
            "head": list(head()),
            "showing": order_id,
            "order": seen(order_id) if order_id is not None else None,
            "left": None
            if left_id is None
            else {"order_id": left_id, "paid_in_full": left is not None and left["paid_in_full"]},
        }
        body = json.dumps(answer, ensure_ascii=False, allow_nan=False, separators=(",", ":"), default=jsonable_encoder)
        return Response(body.encode("utf-8"), media_type="application/json")
