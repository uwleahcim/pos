"""Online orders on the wire. The rules live in `pos.online`; these are the calls (docs/online-orders.md).

- `POST /online/push`: GloriaFood sends an order here the moment it is accepted, with this restaurant's key
  for pushes in the `Authorization` header. The body is what it answers when asked: `{"count": 1, "orders":
  [...]}` (one order by itself and a bare list are read too). The orders are written down and put on the
  POS before it is answered: 200 `{"received": n}`. An order that is here already, because the hub's asking
  brought it first or GloriaFood sent it twice, is the same order and nothing happens. Turned away: 404 on
  a hub with no key for pushes, 401 `refused` without the key (the body is not read), 413 `too_big`, 422
  `unreadable` (kept as it came, for a person), 503 `standby` on a hub that cannot write orders down, 503
  `not_written` when the database would not take one (it is held, and written at the next round). Nothing
  of what was sent is in an answer, and no reason: whoever knocks learns nothing.
- `GET /online/status`: how the online orders are doing: whether the hub has GloriaFood's key for asking
  (`configured`), whether its minute's round is running (`running`) and it can write orders down
  (`writable`), when GloriaFood was last asked and last answered (`asked_ms`, `answered_ms`) and why it did
  not (`last_failure`: `at_ms`, `reason`); whether it takes pushes (`push.configured`), when the last one
  came (`push.pushed_ms`) and the last one it turned away (`push.refused`: `at_ms`, `reason`, `count`
  since the hub started); today's orders by what became of them and by how they came first (`today`:
  `came`, `by_push`, `by_poll`, `placed`, `booked` (tables, into the reservation book), `kept`, `failed`,
  and `unread`: what GloriaFood sent that could not be read), how many are still to be put on the POS
  (`waiting`), and the ones a person should look at (`look`), each by GloriaFood's number (`id`), with its
  `kind`, `state`, how it came (`via`), the POS order it became (`order_id`) and what there is to say of it
  (`said`). Nothing of a customer is in it, and no key.
  `look` rows also say since when they are as they are (`at_ms`) and whether that is after somebody last
  looked (`new`; never for one that is still being tried, nor for a push that could not be read on a hub
  that also asks); `news` counts those, and `seen_ms` is when somebody last looked. `trouble` lists what is
  wrong right now, each with a `code` (`not_answering`: asking GloriaFood has failed for five minutes;
  `pushes_refused`: orders come only by the asking while pushes are turned away), `since_ms`, the `reason`
  and whether it is `urgent` (no order is reaching the POS).
- `POST /online/seen` (`{"by": "Mike"}`): somebody looked at the ones to look at. Nothing of them changes:
  they stay listed, and are no longer `new` on any screen. Answers with the status after it. Like a
  screen's operations it takes no token: it changes no order, no money and no setting anybody chose. 503
  `read_only` on a hub that cannot write.
- `POST /online/fetch`: asks GloriaFood now, as the hub does every minute by itself, and answers with what
  that round did (`asked`, `came`, `known`: here already, `placed`, `booked`, `kept`, `failed`), whether GloriaFood
  `answered` and the `reason` it did not, and the `status` after it. It is the button **Ask now** on the
  Online orders screen and `hubctl online fetch`. GloriaFood is not asked again within fifteen seconds of
  the last asking (`pos.online.service.ASK_GAP_MS`): then nothing is done and `soon` is true. Like the
  screens' other calls here it takes no token: it does what the hub's own minute does, no oftener than
  that. 409 `no_key` when the hub has no key for asking.
- `GET /online/orders/{id}`: one order as GloriaFood sent it, by GloriaFood's number, with everything of
  the customer taken out (`pos.online.place.hidden`): for looking at the shape of an order that went on
  wrong. 404 `unknown_order`; 410 `forgotten` once the order is older than the hub keeps it as it came.

Putting an order on the POS is this module's too (`add_online_orders` sets `OnlineOrders.put`): the
operations `pos.online.place` makes are numbered, stored and printed as a screen's are, by the same steps.
So is writing a table that was booked on the website into the reservation book (`OnlineOrders.book`): what
`pos.online.book` reads of it is handed to `Reservations.take`, once, and the screens that show the book are
told. No call here writes a reservation: a screen cannot make one up as the website's.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from ..online.book import BY as BOOKED_BY
from ..online.book import RESERVATION_TYPES, Booked, wanted
from ..online.door import body_of
from ..online.gloriafood import NAME, pushed
from ..online.inbox import Arrival
from ..online.place import DEVICE, CannotPlace, Placed, ext_id_of, hidden, ops_for, order_id_for
from ..online.service import SEVERAL, UNREADABLE, OnlineOrders, PushRefused
from ..orders.check import check_for
from ..orders.counts import holds
from ..reservations import Refused, Reservations
from ..sync.hlc import Clock
from ..sync.pgstore import ReadOnlyError

SEEN = "online_seen"
"""The setting that keeps when somebody last looked at the online orders to look at, and who."""
TOPIC = "online"
"""What the change feed says when there is something new to look at, or somebody looked."""
LOOK = "Look at it in GloriaFood's own app."
BOOK_TOPIC = "reservations"
"""What the change feed says when the reservation book changed (`pos.api.reservations`)."""
PUSH_ERRORS = {401: "refused", 404: "not_found", 422: "unreadable", 503: "standby"}
"""What a push that is turned away is answered, by status: one word, and nothing of why."""


class SeenIn(BaseModel):
    """Who looked at the online orders that need looking at."""

    by: str = Field("", max_length=80)


def add_online_orders(app: FastAPI, number_orders: Any) -> None:
    """Wires the online orders into the hub: how one is put on the POS, the slip for one somebody has to
    look at, and the calls above. `number_orders` is the hub's own numbering of to-go orders."""
    online: OnlineOrders = app.state.online
    clock = Clock(DEVICE, lambda: app.state.store.now_ms())

    def put(order: Mapping[str, Any]) -> Placed:
        store = app.state.store
        ext_id = ext_id_of(order)
        if ext_id is not None and store.entry(order_id_for(ext_id)) is not None:
            # It is on the POS: what became of it could not be written down the last time. One order.
            return Placed(order_id_for(ext_id), ())
        menu = app.state.menu
        menu.refresh()
        placed = ops_for(
            order,
            menu,
            stamp=clock.now,
            check_of=lambda state: check_for(state, app.state.taxes, app.state.pricing),
            rules=app.state.pricing,
            minutes=app.state.settings.get("quotes").get("minutes"),
            now_ms=store.now_ms(),
        )
        # Stored and taken off the numbers left as one step, like a screen's order. An online order is
        # never refused for a dish that ran out: it was sold, and somebody accepted it.
        with menu.counting():
            accepted = store.append(number_orders(app.state.numbers, list(placed.ops)))
            counted = menu.counts()
            if accepted and counted:
                menu.take({dish: n for dish, n in holds(store.state(placed.order_id), counted).items() if n})
        if accepted:
            app.state.feed.poke()  # the screens hear of it now, before the tickets print
            app.state.printing.on_ops(store.for_order, list(accepted))
            app.state.notifier.on_ops(store.for_order, list(accepted))
        return placed

    def book(order: Mapping[str, Any]) -> Booked:
        """A table booked on the website goes into the reservation book, once: under the website's own
        number for it, so one that is there already is the same one given again, and stands as a host left
        it. What the book's own rules refuse is said in the book's words, for a person to write in by hand."""
        reservations: Reservations = app.state.reservations
        want = wanted(order, now_ms=reservations.now_ms())
        try:
            booking, new = reservations.take(
                want.booking_id,
                want.name,
                want.size,
                want.at_ms,
                phone=want.phone,
                note=want.note,
                by_id=DEVICE,
                by=BOOKED_BY,
            )
        except Refused as err:
            raise CannotPlace(f"the book would not take it ({err.message.rstrip('.')})") from None
        if not new:
            return Booked(booking.booking_id)
        app.state.feed.changed(BOOK_TOPIC)  # the book and the floor map read it now
        return Booked(booking.booking_id, want.said, late=want.late)

    def notice(arrival: Arrival, said: str) -> None:
        """The slip for an order somebody has to look at: one that is not on the POS, or is on it and was
        not sent to the kitchen; and for a booked table that is not in the book, or came after its time."""
        number = f"Online order {arrival.ext_id}"
        if arrival.kind == UNREADABLE:
            words = [
                "ONLINE ORDERS: LOOK",
                "GloriaFood sent the hub something it could not read. There may be online orders in it that "
                "are not on the POS.",
                "Look at GloriaFood's own app and ring in by hand what is missing.",
            ]
        elif arrival.kind == SEVERAL:
            words = ["NOT ON THE POS", f"{said}.", "The hub lists them: sudo hubctl online status."]
        elif arrival.kind in RESERVATION_TYPES and arrival.state == "booked":
            words = [
                "RESERVATION CAME LATE",
                f"Online reservation {arrival.ext_id}: {said}.",
                "It is in the book now. See whether the party is here.",
            ]
        elif arrival.kind in RESERVATION_TYPES:
            words = [
                "NOT IN THE BOOK",
                f"Online reservation {arrival.ext_id}: {said}.",
                f"{LOOK} Write it into the book by hand if the table is still to come.",
            ]
        elif arrival.state == "placed":
            state = app.state.store.view(arrival.order_id) if arrival.order_id else None
            order_no = state.fields.get("order_no") if state is not None else None
            if isinstance(order_no, int):
                number = f"Online order #{order_no} ({arrival.ext_id})"
            words = [
                "NOT SENT TO THE KITCHEN",
                f"{number}: {said}.",
                "Send it from the order if it still has to be cooked. If it was rung in by hand meanwhile, "
                "void one of the two.",
            ]
        else:
            words = ["NOT ON THE POS", f"{number}: {said}.", f"{LOOK} Ring it in by hand if it still has to be made."]
        app.state.printing.notice(words, key=f"online:{arrival.source}:{arrival.ext_id}")

    def seen_ms() -> int:
        """When somebody last looked; never, where the settings cannot be read (everything is new then)."""
        try:
            at = app.state.settings.get(SEEN).get("at_ms")
        except Exception:  # noqa: BLE001 - how the online orders are doing is said without it
            return 0
        return at if isinstance(at, int) and not isinstance(at, bool) else 0

    def status() -> dict[str, Any]:
        return online.status(seen_ms())

    online.put = put
    online.book = book
    online.notice = notice
    online.news = lambda: app.state.feed.changed(TOPIC)  # the screens hear that there is something to look at

    @app.post("/online/push")
    async def online_push(request: Request) -> JSONResponse:
        """A push of GloriaFood's. Its key is looked at before a byte of the body is read."""
        try:
            online.admit(request.headers.get("authorization"))
            body = await body_of(request)
            if body is None:
                return JSONResponse({"error": "too_big"}, 413)
            done = await run_in_threadpool(online.push, lambda: pushed(body))
        except PushRefused as err:
            return JSONResponse({"error": PUSH_ERRORS[err.status]}, err.status)
        if done["unwritten"]:
            return JSONResponse({"error": "not_written"}, 503)
        return JSONResponse({"received": done["received"]})

    @app.get("/online/status")
    def online_status() -> dict[str, Any]:
        return status()

    @app.post("/online/seen")
    def online_seen(body: SeenIn) -> dict[str, Any]:
        """Somebody looked at the online orders to look at: from now on they are new on no screen."""
        looked = {"at_ms": online.now_ms(), "by": " ".join(body.by.split())}
        try:
            app.state.settings.put(SEEN, looked)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed(TOPIC)
        return status()

    @app.post("/online/fetch")
    def online_fetch() -> dict[str, Any]:
        if not online.configured:
            raise HTTPException(409, {"error": "no_key", "message": "This hub has no key for online orders."})
        return {**online.ask_now(), "status": status()}

    @app.get("/online/orders/{ext_id}")
    def online_order(ext_id: str) -> dict[str, Any]:
        arrival = online.inbox.get(online.source.name if online.source is not None else NAME, ext_id)
        if arrival is None:
            raise HTTPException(404, {"error": "unknown_order", "message": "No online order with that number."})
        if arrival.raw is None:
            raise HTTPException(410, {"error": "forgotten", "message": "That order is older than the hub keeps."})
        return {**arrival.about(), "order": hidden(arrival.raw)}
