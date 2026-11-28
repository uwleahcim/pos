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
  `moves_checks`: whether what Shipday says moves those checks (below).
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

- `POST /shipday/orders/{id}/driver` `{staff_id, driver_id}`: gives a delivery nobody has to a driver, by
  Shipday's own ids of both. Shipday tells the driver.
- `POST /shipday/orders/{id}/driver/back` `{staff_id, driver_id}`: takes a delivery back from the driver the
  screen showed it with (`driver_id`), so that nobody has it.
- `POST /shipday/orders/{id}/status` `{staff_id, status, was}`: marks a delivery as it goes. `status` is one
  of Shipday's own words (`STARTED`, `PICKED_UP`, `READY_TO_DELIVER`, `ALREADY_DELIVERED`, `FAILED_DELIVERY`,
  `INCOMPLETE`) and one of the steps the picture lists for that delivery (`steps`); `was` is where the
  screen showed it standing.
- `POST /shipday/orders/{id}/ready` `{staff_id}`: tells Shipday the delivery is made and waits for its
  driver ("ready for pickup"), with a driver or without one, as long as it was not picked up. Shipday's
  list never says whether a delivery was marked so: `shown` is always false here, `done` is Shipday's own
  answer, and the hub remembers that it told (`ready_ms` on the delivery: in memory for the day, and
  written on the delivery's check where it has one, so a hub that restarted still knows).

  All four: the hub asks Shipday for its list first and sends nothing where the delivery no longer stands
  as the screen showed it; after the change it asks once more. The answer says `done` (Shipday made the
  change, as far as it said or its list shows), `sent` (it was asked to), `shown` (its list shows it), why
  not (`reason`: `not_listed`, `has_driver`, `no_driver`, `other_driver`, `on_its_way`, `unsure`,
  `unknown_driver`, `moved`, `not_a_step`, or a reason Shipday gave no answer for, or `rejected` and
  `not_found` when it would not; `said` in words; `told`: what Shipday itself said) and the picture after
  it (`shipday`). 409 `no_key` on a hub without a key, 404 `unknown_staff`.

  Who may: whoever is signed in, as anybody hands a bag to a driver on the POS's own Deliveries screen
  (docs/delivery.md). Staff have no token: a screen passes who is signed in (`staff_id`), as it does for
  the texts, and the hub writes down who asked, by Shipday's ids and with no customer.

`GET /shipday` lists what this hub changes in Shipday when asked (`can`: `driver`, `status`, `ready`), so a
screen offers nothing an older hub would not do, and of each delivery what it can be marked as from where
it stands (`steps`), whether it can be said ready for pickup (`can_ready`) and when this hub said so
(`ready_ms`, null where it did not).

- `GET /settings/shipday`, `PUT /settings/shipday` `{moves_checks, tells_ready}` (a manager's): whether
  what Shipday says of a delivery moves its check on the POS, and whether a check marked Ready on the POS
  tells Shipday its delivery is ready for pickup. Both on to start, which is the restaurant's choice. A
  `PUT` may name either or both: one it leaves out stays as it stands (an app from before the second switch
  sends the first alone). `GET /shipday` says both too (`moves_checks`, `tells_ready`).

**Shipday moves the check** (`follow`, `pos.shipday.follow`). After every round Shipday answered, the hub
looks at each delivery that is picked up, delivered, failed or incomplete there and has a check here: a
check that has not left goes Out with Shipday's driver, and a delivered one with nothing left to pay is
marked delivered and closed; one with money due stays open, with what Shipday said written on it. The
operations are stored as a screen's are, the screens are told, and **no text is sent**: Shipday tells the
customer itself.

**A check marked Ready tells Shipday** (`tell_ready`, `pos.shipday.ready`). After the same round, and at
once when a screen marks a delivery's check Ready (`mark_ready`, which brings the next round forward), the
hub looks at each delivery Shipday lists that is not picked up, has a check here that is open and marked
Ready, and was not told yet: Shipday is told it is ready for pickup, and that it was told is written on the
check, once (an operation with a fixed id), so neither a restart nor the location's other hub tells it
twice. A hub that stands by tells nothing. No text is sent. That is the one thing the POS tells Shipday by
itself: nothing else a person does to a check on the POS is told to Shipday.

The key is one of the hub's (`shipday`; `pos.keys`, `pos.api.keys`): `GET /hub/keys` says how the asking
goes (`shipday`) and `POST /hub/shipday/try` tries the key.

Reading changes nothing in Shipday. The four changes above are the only things the hub ever changes there:
three only because a person tapped exactly that, and ready for pickup also by itself for a check marked
Ready, while that setting is on. What Shipday says changes one thing on the POS: where a delivery's check
stands, as above, while its setting is on.
"""

from __future__ import annotations

import logging
import threading
from decimal import Decimal
from typing import Any, Literal

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field, StrictBool
from starlette.concurrency import run_in_threadpool

from .. import localtime
from ..identity.staff import Directory, Staff
from ..keys import SHIPDAY, HubKeys
from ..orders.check import check_for
from ..settings import SettingStore, clean_shipday
from ..shipday.board import ShipdayBoard
from ..shipday.client import Shipday
from ..shipday.follow import DELIVERED, DEVICE, DUE, FOLLOWED, NOTED, OUT, ops_following
from ..shipday.match import OnPos, on_pos
from ..shipday.ready import op_id as ready_op_id
from ..shipday.ready import op_told, waits
from ..sync.hlc import Clock
from ..sync.oplog import Op, is_delivery
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from
from .sales import orders_between

log = logging.getLogger("pos.shipday")

TOPIC = "shipday"
"""What the change feed says when Shipday's deliveries or drivers read differently, or the key changed."""


class DriverIn(BaseModel):
    staff_id: str = Field(max_length=120)
    driver_id: int = Field(ge=0, le=2**53)
    """Shipday's own id of the driver: the one to give it to, or the one it is taken back from."""


class MarkIn(BaseModel):
    staff_id: str = Field(max_length=120)
    status: Literal["STARTED", "PICKED_UP", "READY_TO_DELIVER", "ALREADY_DELIVERED", "FAILED_DELIVERY", "INCOMPLETE"]
    """What it is marked as, in Shipday's own word."""
    was: str = Field(max_length=40)
    """Where the screen showed it standing when the person tapped, in Shipday's own word."""


class ReadyIn(BaseModel):
    staff_id: str = Field(max_length=120)


class MovesIn(BaseModel):
    """Whether what Shipday says of a delivery moves its check on the POS, and whether a check marked Ready
    on the POS tells Shipday its delivery is ready for pickup. One that is left out stays as it stands."""

    moves_checks: StrictBool | None = None
    tells_ready: StrictBool | None = None


SETTING = "shipday"
SAID = {
    OUT: "is out, as Shipday says it was picked up",
    DELIVERED: "is delivered and closed, as Shipday says it was delivered",
    DUE: "stays open for the money due on it, though Shipday says it was delivered",
    NOTED: "stays as it is, with what Shipday says written on it",
}
"""What became of a check the hub looked at, for its log."""


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


def moves_checks(app: FastAPI) -> bool:
    """Whether what Shipday says moves a check here: the location's setting, on to start."""
    settings: SettingStore = app.state.settings
    return settings.get(SETTING)["moves_checks"] is True


def follow(app: FastAPI, clock: Clock) -> int:
    """Moves the POS's checks by what Shipday now says of their deliveries (`pos.shipday.follow`): picked
    up there is Out here, delivered there is Delivered here unless money is due. Called after every round
    Shipday answered. Answers how many checks it wrote on.

    What it writes is stored and told to the screens as a screen's own operations are, and the tickets
    hear of it. The texts do not: a check that leaves because Shipday says so sends its customer no "on its
    way", since Shipday tells them itself. Nothing is logged of a customer: a check by its number, a
    delivery by Shipday's id."""
    if not moves_checks(app):
        return 0
    board: ShipdayBoard = app.state.shipday
    store = app.state.store
    picture = board.said()
    wrote = 0
    for delivery in (*picture["orders"], *picture["done"]):
        on = delivery["pos"]
        if on is None or on["status"] != "open" or delivery["state"] not in FOLLOWED:
            continue
        state = store.view(on["order_id"])
        if state is None:
            continue
        if state.last is not None:
            clock.observe(state.last)  # after everything a screen wrote on it, whatever that screen's clock says
        ops, what = ops_following(
            delivery,
            state,
            due=lambda state=state: Decimal(check_for(state, app.state.taxes, app.state.pricing)["due"]) > 0,
            stamp=clock.now,
            now_ms=store.now_ms(),
        )
        fresh = [op for op in ops if op.op_id not in store]
        if not fresh:
            continue  # said already: each step of a delivery is written once
        try:
            accepted = store.append(fresh)
        except ReadOnlyError:
            return wrote  # a hub that stands by writes nothing: the one that serves does this
        if not accepted:
            continue
        wrote += 1
        app.state.feed.poke()  # the screens hear of it now
        app.state.printing.on_ops(store.for_order, list(accepted))
        # and no `notifier.on_ops`: no text goes out for what Shipday moved
        log.warning("shipday: check #%s %s (its order %s)", on["order_no"] or "?", SAID[what], delivery["id"])
    return wrote


def tells_ready(app: FastAPI) -> bool:
    """Whether a check marked Ready here tells Shipday its delivery is ready for pickup: the location's
    setting, on to start."""
    settings: SettingStore = app.state.settings
    return settings.get(SETTING)["tells_ready"] is True


def write_told(app: FastAPI, clock: Clock, order_id: str, delivery: int, at_ms: int, *, by: str | None) -> bool:
    """Writes on a check that Shipday was told its delivery is ready for pickup (`pos.shipday.ready`): once
    for a check and a delivery, whoever told. `by` is the person who tapped it; None where the hub told
    Shipday by itself. Stored and told to the screens as a screen's own operation is; no ticket and no text
    come of it. Answers whether it was written now."""
    store = app.state.store
    if ready_op_id(order_id, delivery) in store:
        return False
    state = store.view(order_id)
    if state is None or state.first is None:
        return False
    if state.last is not None:
        clock.observe(state.last)  # after everything a screen wrote on it
    try:
        accepted = store.append([op_told(order_id, delivery, at_ms, by=by, stamp=clock.now)])
    except ReadOnlyError:
        return False  # a hub that stands by writes nothing
    if accepted:
        app.state.feed.poke()
    return bool(accepted)


def tell_ready(app: FastAPI, clock: Clock) -> int:
    """Tells Shipday of every delivery whose check on the POS is marked Ready that it is ready for pickup
    (`pos.shipday.ready`), and writes on the check that it was told. Called after every round Shipday
    answered, inside that round. Answers how many it told.

    Only a delivery Shipday lists as not picked up, matched to a check here that is open and stands at
    Ready, and not told yet as far as the hub's memory and the check say. A hub that stands by tells
    nothing: the one that serves does. Nothing is logged of a customer."""
    if not tells_ready(app):
        return 0
    store = app.state.store
    if getattr(store, "role", "memory") == "replica":
        return 0
    board: ShipdayBoard = app.state.shipday
    told = 0
    for delivery in board.said()["orders"]:
        on = delivery["pos"]
        if on is None or on["status"] != "open" or on["stage"] != "ready" or not delivery["can_ready"]:
            continue
        ident = int(delivery["id"])
        if ready_op_id(on["order_id"], ident) in store:
            continue  # its check says it was told (and about another delivery since): once is once
        state = store.view(on["order_id"])
        if state is None or not waits(state):
            continue
        at = board.ready_by_itself(ident)
        if at is None:
            continue
        told += 1
        # Shipday was told. Where the check cannot be written on, the hub remembers it until it restarts
        wrote = write_told(app, clock, on["order_id"], ident, at, by=None)
        log.warning(
            "shipday: check #%s %s that Shipday was told it is ready (its order %s)",
            on["order_no"] or "?",
            "says" if wrote else "could not be written on to say",
            ident,
        )
    return told


def mark_ready(app: FastAPI, ops: list[Op]) -> None:
    """Operations a screen just stored: where one of them marks a delivery's check Ready, Shipday is asked
    and told now and not at the hub's next turn. Nothing where Shipday is not told by itself."""
    board: ShipdayBoard = app.state.shipday
    marked = [op.order_id for op in ops if op.kind == "set_field" and op.data.get("stage") == "ready"]
    if not marked or not board.configured or not tells_ready(app):
        return
    store = app.state.store
    for order_id in marked:
        state = store.view(order_id)
        if state is not None and is_delivery(state.fields):
            board.hurry()
            return


def add_shipday(app: FastAPI) -> None:
    board: ShipdayBoard = app.state.shipday
    board.pos = lambda: deliveries_on_pos(app)
    board.on_change = lambda: app.state.feed.changed(TOPIC)
    clock = Clock(DEVICE, lambda: app.state.store.now_ms())
    writing = threading.Lock()  # the clock stamps for one writer at a time: the round's, or a person's change

    def heard() -> None:
        """Shipday answered a round: its word moves the checks, and the checks marked Ready are told to it."""
        with writing:
            follow(app, clock)
            tell_ready(app, clock)

    board.on_round = heard

    def pictured() -> dict[str, Any]:
        """The picture as a screen is told it: the board's, whether it moves the checks, and whether a
        check marked Ready tells Shipday."""
        return {**board.said(), "moves_checks": moves_checks(app), "tells_ready": tells_ready(app)}

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
        return pictured()

    @app.post("/shipday/ask")
    async def ask_shipday() -> dict[str, Any]:
        """Asks Shipday now, as the hub does by itself every few seconds while a screen looks."""
        board: ShipdayBoard = app.state.shipday
        if not board.configured:
            raise HTTPException(409, {"error": "no_key", "message": "this hub has no key for Shipday yet"})
        board.watched()
        asked = await run_in_threadpool(board.ask_now)
        return {**asked, "shipday": await run_in_threadpool(pictured)}

    def asking(staff_id: str) -> tuple[ShipdayBoard, Staff]:
        """The board, and who asks for a change: somebody this hub knows."""
        board: ShipdayBoard = app.state.shipday
        directory: Directory = app.state.staff
        person = directory.get(staff_id)
        if person is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        if not board.configured:
            raise HTTPException(409, {"error": "no_key", "message": "this hub has no key for Shipday yet"})
        board.watched()
        return board, person

    @app.post("/shipday/orders/{order_id}/driver")
    async def give_to_driver(order_id: int, body: DriverIn) -> dict[str, Any]:
        """Gives a delivery nobody has to a driver. Shipday tells the driver."""
        board, person = asking(body.staff_id)
        answer = await run_in_threadpool(board.give, order_id, body.driver_id, by=person.name)
        return {**answer, "shipday": await run_in_threadpool(pictured)}

    @app.post("/shipday/orders/{order_id}/driver/back")
    async def take_back_from_driver(order_id: int, body: DriverIn) -> dict[str, Any]:
        """Takes a delivery back from the driver the screen showed it with: nobody has it then."""
        board, person = asking(body.staff_id)
        answer = await run_in_threadpool(board.take_back, order_id, body.driver_id, by=person.name)
        return {**answer, "shipday": await run_in_threadpool(pictured)}

    @app.post("/shipday/orders/{order_id}/status")
    async def mark_delivery(order_id: int, body: MarkIn) -> dict[str, Any]:
        """Marks a delivery as it goes: started, picked up, at the customer's, delivered, failed, incomplete."""
        board, person = asking(body.staff_id)
        answer = await run_in_threadpool(board.mark, order_id, body.status, body.was, by=person.name)
        return {**answer, "shipday": await run_in_threadpool(pictured)}

    @app.post("/shipday/orders/{order_id}/ready")
    async def ready_for_pickup(order_id: int, body: ReadyIn) -> dict[str, Any]:
        """Tells Shipday a delivery is made and waits for its driver."""
        board, person = asking(body.staff_id)

        def tell() -> dict[str, Any]:
            answer = board.ready(order_id, by=person.name)
            if answer["done"]:
                # written on its check where it has one: its history says who told Shipday, and the hub
                # does not tell it again by itself
                listed = next((each for each in board.said()["orders"] if each["id"] == order_id), None)
                if listed is not None and listed["pos"] is not None and listed["ready_ms"] is not None:
                    with writing:
                        write_told(app, clock, listed["pos"]["order_id"], order_id, listed["ready_ms"], by=person.name)
            return answer

        answer = await run_in_threadpool(tell)
        return {**answer, "shipday": await run_in_threadpool(pictured)}

    @app.get("/settings/shipday")
    def read_moves() -> dict[str, Any]:
        """Whether what Shipday says of a delivery moves its check on the POS (`moves_checks`), and whether
        a check marked Ready tells Shipday its delivery is ready for pickup (`tells_ready`): each on unless
        a manager turned it off."""
        settings: SettingStore = app.state.settings
        return settings.get(SETTING)

    @app.put("/settings/shipday")
    def write_moves(body: MovesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns either on or off; one the body does not name stays as it stands.

        `moves_checks` off: the hub still reads Shipday and shows it, and every check is moved by hand;
        what Shipday moved before stays as it is. On again, the hub acts on what Shipday says at its next
        reading, also of the deliveries it heard of meanwhile.

        `tells_ready` off: Shipday is told a delivery is ready only by the button on the Shipday screen.
        On again, the hub tells Shipday at its next reading of every delivery whose check stands at Ready
        and was not told, also the ones marked meanwhile."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        try:
            cleaned = clean_shipday(body.model_dump(), settings.get(SETTING))
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = settings.put(SETTING, cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        app.state.feed.changed(TOPIC)  # the Shipday screens say whether the checks follow
        return saved
