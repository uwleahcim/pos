"""Shipday's deliveries and drivers as the hub last heard of them, and the asking that keeps them so.

A hub sits behind the restaurant's router, so Shipday cannot tell it anything (its webhooks want an address
on the internet): the hub asks. A round (`ShipdayBoard.round`) asks for the active orders, and once a minute
for the drivers; while a screen is looking at the answer (`watched`) there is a round every `FAST_SECONDS`,
and one every `SLOW_SECONDS` otherwise, for the few words on the home screen's button. Once no screen has
asked the hub about Shipday for `IDLE_AFTER_MS` (the restaurant is shut, or no terminal is on) a round comes
every `IDLE_SECONDS` only, and the first screen that asks again (`seen`) has Shipday asked at once. Nothing
is asked without a key.

What a round keeps, in memory only:

- **the active orders**, as `pos.shipday.read.order_of` reads them;
- **what became of the ones that left the list**: an order that is no longer active was delivered, failed,
  marked incomplete or deleted, and the list of active ones does not say which. Each is asked for once by
  its number (`Shipday.order`), a few rounds over if Shipday does not answer, and kept for the day of
  service with what Shipday said (`done`). One Shipday says nothing of, or still calls active, is kept as
  `GONE`: it left the list, and that is all that is known;
- **the drivers**, each with whether they are on shift;
- **how far away a delivery with a driver is** (`eta_ms`), where Shipday will say: its own call for that is
  for accounts on a premium plan and may be asked three times a minute for one order. Each such order is
  asked once a minute, a few of them a round, the one asked longest ago first. An account that is refused
  the call is not asked again for an hour (`eta` is then `plan`), and the order's own `etaTime` is what
  there is.

Shipday is never hurried: a round that is told it asks too often (429) holds the next ones back, twice as
long each time, up to ten minutes; a key it refuses is tried once a minute and no oftener.

Which order on the POS each delivery is (`pos.shipday.match`) is worked out when a screen asks, from the
POS's deliveries as they stand at that moment (`pos`, which the API sets): a check rung up a second ago is
matched at once.

**Changes.** Four things are changed in Shipday when a person at a terminal asked for exactly that: a
delivery is given to a driver (`give`), taken back from one (`take_back`), marked as it goes (`mark`:
started, picked up, at the customer's, delivered, failed, incomplete), and said to be ready for pickup
(`ready`). The first three are never done by the hub itself; the last one is, for a delivery whose check on
the POS is marked Ready (below). Before a person's change is sent the hub asks Shipday for its list again
and sends nothing where the delivery no longer stands as the person's screen showed it (it left the list,
somebody else gave it to a driver, the driver picked it up or marked it in Shipday's app); after it the list
is asked for once more, so the screens show what Shipday now says and the answer can tell whether the change
shows there (`shown`). A change whose answer did not come is not taken for made or for not made: the list
read after it says which.

**Ready for pickup** is the one change Shipday's list never shows: nothing Shipday answers about an order
says whether it was marked ready. So the hub keeps what it told itself (`ready_ms` on a delivery in the
picture: when Shipday was told): in memory for the day of service, and on the delivery's check on the POS
where it has one (`pos.shipday.ready`, which the API writes and the matching reads back), so a hub that
restarted still knows of those. It is told of a delivery that has not been picked up, with a driver or
without one (`can_ready`), and it is made when Shipday answers that it is: an answer that did not come
leaves it unknown, and the person is told so.

It is also the one change the hub makes **by itself** (`ready_by_itself`): after a round Shipday answered,
the API looks for deliveries whose check on the POS is marked Ready and has the board tell Shipday of each,
on the list that round just read. Shipday not answering is tried again a minute later, `READY_TRIES` times
in all; a telling Shipday refused is not repeated until the delivery stands elsewhere there (another
driver, another step), since asking the same again gets the same answer.

What a delivery can be marked as depends on where it stands (`steps_of`), and the picture says it of each
delivery (`steps`), so a screen offers what this hub would send and nothing else. Only forward: a mark made
by mistake is put right in Shipday's own app.

**What Shipday says moves a check.** After every round Shipday answered, the board calls `on_round`, where
the API moves the POS's checks by what Shipday now says of their deliveries (`pos.shipday.follow`,
`pos.api.shipday`): picked up there is Out here, delivered there is Delivered here. The board itself writes
nothing on the POS.

Nothing here names a customer in a log: an order is told of by Shipday's own id.
"""

from __future__ import annotations

import json
import logging
import threading
import time
import traceback
from collections.abc import Callable, Mapping, Sequence
from datetime import date
from typing import Any

from .. import localtime
from .client import LIMIT, NOT_FOUND, REFUSED, REJECTED, Shipday, ShipdayFailed
from .match import OnPos, matched
from .read import (
    ACTIVE,
    ALREADY_DELIVERED,
    FAILED_DELIVERY,
    FINISHED,
    GONE,
    INCOMPLETE,
    NOT_ACCEPTED,
    NOT_ASSIGNED,
    NOT_STARTED_YET,
    PICKED_UP,
    READY_TO_DELIVER,
    STARTED,
    driver_of,
    minutes_of,
    order_of,
)
from .read import tracking_id as tracking_id_of

log = logging.getLogger("pos.shipday")

FAST_SECONDS = 20.0
"""How often Shipday is asked while a screen shows its deliveries."""
SLOW_SECONDS = 60.0
"""How often while some screen reads the picture without showing it: enough for the few words on the home
screen's button, and for a key that is refused."""
IDLE_SECONDS = 300.0
"""How often once no screen has asked the hub about Shipday for `IDLE_AFTER_MS`: Shipday is not asked two
thousand times over a night in which nobody reads the answer."""
IDLE_AFTER_MS = 10 * 60_000
WATCHED_MS = 120_000
"""A screen that asked the hub within this long is looking."""
ASK_GAP_MS = 10_000
"""A person who asks out of turn (the button on the screen) is not passed on to Shipday sooner than this
after it was last asked."""
DRIVERS_EVERY_MS = 60_000
ETA_EVERY_MS = 60_000
"""One delivery is asked after once a minute: Shipday allows three times."""
ETA_MOST = 6
"""How many deliveries are asked after in one round."""
ETA_PLAN_MS = 60 * 60_000
"""An account that was refused the call is asked again after this long: the plan may have changed."""
ETA_MISS_MS = 10 * 60_000
"""A delivery Shipday gave no answer for is asked after again after this long."""
ETA_STATES = (STARTED, PICKED_UP, READY_TO_DELIVER)
"""Where a delivery has to stand for it to be on its way to anybody."""
HOLD_FIRST_MS, HOLD_MOST_MS = 60_000, 10 * 60_000
LEAVING_TRIES = 3
"""How many rounds an order that left the list is asked for before it is kept as `GONE`."""
LEAVING_MOST = 5
"""How many of them are asked for in one round."""
DONE_MOST = 200
"""How many finished deliveries of a day are kept."""
DONE_SAID = 60
"""How many of them a screen is told, the last to finish first."""

ETA_OFF, ETA_ON, ETA_PLAN = "off", "on", "plan"
"""Whether Shipday says how far away a delivery is: not asked yet; it answers; the account's plan has no
such call."""

CAN = ("driver", "status", "ready")
"""What this hub changes in Shipday when a person asks: a delivery's driver, how far along it is, and that
it is ready for pickup. A screen offers no more than is listed here, so one that knows of more offers
nothing this hub would not do."""
HELD = (NOT_ACCEPTED, NOT_STARTED_YET, STARTED)
"""Where a delivery stands while a driver has it and has not picked it up: it can still be taken back."""
WAITING = (NOT_ASSIGNED, *HELD)
"""Where a delivery stands before it is picked up: it can be said to be ready for that."""
READY_MOST = 400
"""How many deliveries the hub remembers having said ready, the last ones told."""
READY_TRIES = 3
"""How often the hub tries by itself to say one delivery ready while Shipday gives no answer to it."""
READY_AGAIN_MS = 60_000
"""How long after a try that got no answer the next one comes."""
NO_KEY, NOT_LISTED, HAS_DRIVER, NO_DRIVER, OTHER_DRIVER, ON_ITS_WAY, UNSURE, UNKNOWN_DRIVER, MOVED, NOT_A_STEP = (
    "no_key",
    "not_listed",
    "has_driver",
    "no_driver",
    "other_driver",
    "on_its_way",
    "unsure",
    "unknown_driver",
    "moved",
    "not_a_step",
)
"""Why the hub sent Shipday no change: it has no key; the delivery is no longer on Shipday's list; it has a
driver already; it has none to take it back from; another driver has it than the screen showed; it was
picked up; Shipday says of it something this hub does not know what to make of; Shipday lists no such
driver, or one it does not let take orders; it stands elsewhere than the screen showed; it cannot be marked
as that from where it stands."""


def steps_of(order: Mapping[str, Any]) -> tuple[str, ...]:
    """What a delivery can be marked as from where it stands, in Shipday's own words and in the order a
    delivery goes: only forward, and never a step it is already at or past.

    What a driver does (started, picked up, at the customer's, delivered) is said only of a delivery a driver
    has. One nobody has can only be ended as not delivered. Shipday's pages do not say what Shipday itself
    lets through: this is what the hub is willing to ask for."""
    state = order["state"]
    if state not in ACTIVE:
        return ()
    if state == NOT_ASSIGNED or order["driver"] is None:
        # with a driver and "not assigned", or without one and further along: nothing is guessed
        return (FAILED_DELIVERY, INCOMPLETE) if state == NOT_ASSIGNED and order["driver"] is None else ()
    steps: list[str] = []
    if state in (NOT_ACCEPTED, NOT_STARTED_YET):
        steps.append(STARTED)
    if state in HELD:
        steps.append(PICKED_UP)
    if state == PICKED_UP:
        steps.append(READY_TO_DELIVER)
    return (*steps, ALREADY_DELIVERED, FAILED_DELIVERY, INCOMPLETE)


class ShipdayBoard:
    def __init__(
        self,
        source: Shipday | None = None,
        *,
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.source = source
        # Set by the API: `pos` gives the POS's own deliveries of the running day, for the matching;
        # `on_change` tells the screens that the picture is another one; `on_round` is called after every
        # round Shipday answered, for what the hub does on the POS with what Shipday says (`pos.shipday.follow`).
        self.pos: Callable[[], Sequence[OnPos]] | None = None
        self.on_change: Callable[[], None] | None = None
        self.on_round: Callable[[], None] | None = None
        self._now = now
        self._asking = threading.Lock()  # one round at a time: the loop's own and one a person asked for
        self._lock = threading.Lock()  # the picture, which a round swaps and a screen's call reads
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._watched_ms = 0
        self._seen_ms = 0
        self._forget()

    def _forget(self) -> None:
        """Everything Shipday ever said: for another key, which may be another restaurant's."""
        self._orders: dict[int, dict[str, Any]] = {}
        self._done: dict[int, dict[str, Any]] = {}
        self._done_day: date | None = None
        self._leaving: dict[int, tuple[dict[str, Any], int]] = {}  # left the list: last heard, and tries
        self._drivers: list[dict[str, Any]] = []
        self._drivers_ms: int | None = None
        self._asked_ms: int | None = None
        self._answered_ms: int | None = None
        self._failure: dict[str, Any] | None = None  # since_ms, at_ms, reason, said
        self._hold_until_ms = 0
        self._held_ms = 0
        self._eta: dict[int, tuple[int, int | None]] = {}  # by order: when it may be asked again, the moment
        self._eta_state = ETA_OFF
        self._eta_hold_ms = 0
        self._ready: dict[int, int] = {}  # by order: when this hub told Shipday it is ready for pickup
        # by order, of the telling the hub does by itself: tries so far, when the next may come, and where
        # the delivery stood in Shipday (its step and driver) when they were made
        self._ready_missed: dict[int, tuple[int, int, tuple[str, int]]] = {}
        self._ready_itself: set[int] = set()  # told by the hub itself since a person last asked for it
        self._picture = ""

    # --- the key -----------------------------------------------------------------------------------------

    @property
    def configured(self) -> bool:
        """Whether the hub has a key to ask Shipday with."""
        return self.source is not None

    @property
    def running(self) -> bool:
        return self._thread is not None and self.source is not None

    def use(self, source: Shipday | None) -> None:
        """This key from now on, or none: one was typed, replaced or removed while the hub runs. Never in the
        middle of a round. What another key was answered is forgotten: it may be another account's."""
        with self._asking:
            old = self.source
            if source is not None and old is not None and source.same_as(old):
                return
            self.source = source
            with self._lock:
                self._forget()
        self._wake.set()  # the loop asks with the new key now

    # --- a round -----------------------------------------------------------------------------------------

    def round(self, *, forced: bool = False) -> dict[str, Any]:
        """Asks Shipday once and keeps what it says. `forced`: a person asked, so the drivers are asked for
        too and a holding back is not waited out. Answers what came of it: `asked`, `answered`, and why not
        (`reason`, `said`)."""
        with self._asking:
            return self._round(forced=forced)

    def _round(self, *, forced: bool, drivers: bool | None = None) -> dict[str, Any]:
        """A round, for whoever holds `_asking`. `drivers`: whether the drivers are asked for too; unless
        said, when a person asked or it is their turn."""
        source = self.source
        if source is None:
            return {"asked": False, "answered": False, "reason": NO_KEY, "said": "no key for Shipday"}
        now = self._now()
        if not forced and now < self._hold_until_ms:
            return {"asked": False, "answered": False, "reason": LIMIT, "said": "Shipday is given a rest"}
        self._asked_ms = now
        if drivers is None:
            drivers = forced or self._drivers_ms is None or now - self._drivers_ms >= DRIVERS_EVERY_MS
        try:
            raw_orders = source.active_orders()
            raw_drivers = source.carriers() if drivers else None
        except ShipdayFailed as err:
            self._failed(now, err)
            self._told()
            return {"asked": True, "answered": False, "reason": err.reason, "said": err.said}
        if self._failure is not None:
            log.warning("shipday: it answers again")
        self._failure, self._held_ms, self._hold_until_ms = None, 0, 0
        self._answered_ms = now
        orders = {order["id"]: order for raw in raw_orders if (order := order_of(raw)) is not None}
        self._left(source, orders, now)
        self._etas(source, orders, now)
        with self._lock:
            self._orders = orders
            self._ready_missed = {ident: tried for ident, tried in self._ready_missed.items() if ident in orders}
            self._ready_itself &= orders.keys()
            if raw_drivers is not None:
                self._drivers = [driver for raw in raw_drivers if (driver := driver_of(raw)) is not None]
                self._drivers_ms = now
        self._told()
        self._heard()
        return {"asked": True, "answered": True, "reason": None, "said": ""}

    def _heard(self) -> None:
        """Shipday answered: whoever acts on what it says does so now (`on_round`). What goes wrong there is
        logged and never stops the reading."""
        if self.on_round is None:
            return
        try:
            self.on_round()
        except Exception:  # noqa: BLE001 - the picture is read and shown whatever becomes of the checks
            log.error("shipday: following it on the POS went wrong\n%s", traceback.format_exc(limit=3, chain=False))
        self._told()  # a delivery the hub said ready by itself reads differently now

    def hurry(self) -> None:
        """Something on the POS changed that Shipday is told of by itself (a delivery's check was marked
        Ready): the next round comes now and not after the usual pause. Nothing without a key."""
        if self.source is not None:
            self._wake.set()

    # --- what a person changes ------------------------------------------------------------------------------

    def give(self, order_id: int, driver_id: int, *, by: str) -> dict[str, Any]:
        """Gives a delivery nobody has to a driver, because `by` asked at a terminal. Shipday tells the
        driver. Nothing is sent for a delivery that is not on Shipday's list as it reads this moment, for
        one that has a driver already, or to a driver Shipday does not list or does not let take orders."""

        def check(order: dict[str, Any] | None) -> str | None:
            if order is None:
                return NOT_LISTED
            if order["driver"] is not None:
                return HAS_DRIVER
            if order["state"] != NOT_ASSIGNED:
                return UNSURE  # no driver, and not what Shipday calls waiting for one: nothing is guessed
            with self._lock:
                known = any(driver["id"] == driver_id and driver["active"] for driver in self._drivers)
            return None if known else UNKNOWN_DRIVER

        def shown(order: dict[str, Any] | None) -> bool:
            return order is not None and order["driver"] is not None and order["driver"]["id"] == driver_id

        return self._changed(
            order_id,
            check,
            lambda source: source.assign(order_id, driver_id),
            shown,
            by,
            f"given to driver {driver_id}",
        )

    def take_back(self, order_id: int, driver_id: int, *, by: str) -> dict[str, Any]:
        """Takes a delivery back from the driver the person's screen showed it with (`driver_id`), so that
        nobody has it. Nothing is sent where another driver has it by now, where nobody has, or once it
        was picked up: what is on its way is not taken from the driver who carries it."""

        def check(order: dict[str, Any] | None) -> str | None:
            if order is None:
                return NOT_LISTED
            if order["driver"] is None:
                return NO_DRIVER
            if order["driver"]["id"] != driver_id:
                return OTHER_DRIVER
            if order["state"] in HELD:
                return None
            return ON_ITS_WAY if order["state"] in (PICKED_UP, READY_TO_DELIVER) else UNSURE

        def shown(order: dict[str, Any] | None) -> bool:
            return order is not None and order["driver"] is None

        return self._changed(
            order_id, check, lambda source: source.unassign(order_id), shown, by, f"taken back from driver {driver_id}"
        )

    def mark(self, order_id: int, status: str, was: str, *, by: str) -> dict[str, Any]:
        """Marks a delivery as it goes (`status`: one of Shipday's own words), because `by` asked at a
        terminal whose screen showed it standing at `was`. Nothing is sent for a delivery that stands
        elsewhere by now (the driver marked it first, somebody took it back), or for a step that is not
        one from where it stands (`steps_of`)."""

        def check(order: dict[str, Any] | None) -> str | None:
            if order is None:
                return NOT_LISTED
            if order["state"] != was:
                return MOVED
            return None if status in steps_of(order) else NOT_A_STEP

        def shown(order: dict[str, Any] | None) -> bool:
            if status in FINISHED:
                # it ended: gone from the active ones, and not ended as something else
                return order is None or order["state"] in (status, GONE)
            return order is not None and order["state"] == status

        return self._changed(
            order_id, check, lambda source: source.mark(order_id, status), shown, by, f"marked {status}"
        )

    def ready(self, order_id: int, *, by: str) -> dict[str, Any]:
        """Tells Shipday that a delivery is made and waits for its driver, because `by` asked at a terminal.
        Nothing is sent for one that is no longer on Shipday's list, or that was picked up: it left already.
        One nobody has yet can be said ready as well as one a driver has.

        Shipday's list says nothing of it afterwards (`shown` is never true), so it is `done` when Shipday
        answered that it is, and the hub writes down that it told (`ready_ms` in the picture). Where the
        answer did not come, nothing is written down and the person is told that it is not known."""

        def check(order: dict[str, Any] | None) -> str | None:
            if order is None:
                return NOT_LISTED
            if order["state"] in (PICKED_UP, READY_TO_DELIVER):
                return ON_ITS_WAY
            return None if order["state"] in WAITING else UNSURE

        with self._lock:
            self._ready_itself.discard(order_id)

        def send(source: Shipday) -> None:
            with self._lock:
                told = order_id in self._ready_itself
            if told:
                return  # the hub told Shipday by itself in the reading just made: it is not told twice
            source.ready(order_id)
            with self._lock:  # Shipday answered that it is: the list read after this tells the screens
                self._said_ready(order_id, self._now())

        return self._changed(order_id, check, send, None, by, "said ready for pickup")

    def _said_ready(self, order_id: int, now: int) -> None:
        """Shipday answered that a delivery is ready for pickup: remembered, for whoever holds `_lock`."""
        self._ready_missed.pop(order_id, None)
        self._ready.pop(order_id, None)
        self._ready[order_id] = now
        for ident in list(self._ready)[: max(0, len(self._ready) - READY_MOST)]:
            del self._ready[ident]

    def ready_by_itself(self, order_id: int) -> int | None:
        """Tells Shipday that a delivery is ready for pickup because its check on the POS is marked Ready.
        Only for `on_round`: it runs inside a round, on the list that round just read, so whoever calls
        holds `_asking` already and Shipday is not asked for its list again. Answers when Shipday said that
        it is; None where nothing was sent or Shipday did not say so.

        Nothing is sent for a delivery that is not on the list as it was just read, one that was picked up,
        one this hub has told already, or one whose tries are used up (`READY_TRIES`, and at once where
        Shipday refused) while it still stands where it stood."""
        source = self.source
        if source is None:
            return None
        now = self._now()
        with self._lock:
            order = self._orders.get(order_id)
            if order is None or order["state"] not in WAITING or order_id in self._ready:
                return None
            stands = (str(order["state"]), int(order["driver"]["id"]) if order["driver"] is not None else 0)
            tries, again, stood = self._ready_missed.get(order_id, (0, 0, stands))
        if stood != stands:
            tries, again = 0, 0  # it stands elsewhere in Shipday than when it was tried: asked afresh
        if tries >= READY_TRIES or now < again:
            return None
        try:
            source.ready(order_id)
        except ShipdayFailed as err:
            # an answer that says no is the answer; one that did not come is asked for again, a few times
            tries = READY_TRIES if err.reason in (REJECTED, NOT_FOUND) else tries + 1
            with self._lock:
                self._ready_missed[order_id] = (tries, now + READY_AGAIN_MS, stands)
            log.warning(
                "shipday: order %s not said ready for pickup (%s), by the hub itself as its check is ready%s",
                order_id,
                err.reason,
                "" if tries < READY_TRIES else "; not tried again while it stands as it does",
            )
            return None
        with self._lock:
            self._said_ready(order_id, now)
            self._ready_itself.add(order_id)
        log.warning("shipday: order %s said ready for pickup by the hub itself, as its check is ready", order_id)
        return now

    def _changed(
        self,
        order_id: int,
        check: Callable[[dict[str, Any] | None], str | None],
        send: Callable[[Shipday], None],
        shown: Callable[[dict[str, Any] | None], bool] | None,
        by: str,
        what: str,
    ) -> dict[str, Any]:
        """One change a person asked for: the list is read, the change is sent where the delivery stands as
        `check` wants it, and the list is read again. Answers `done` (Shipday made it, as far as it said or
        its list shows), `sent` (it was asked to), `shown` (its list shows it; never of a change the list
        has no place for, where `shown` is None), and why not (`reason`, `said`, and `told`: Shipday's own
        words for refusing, for the person and for no log)."""
        answer: dict[str, Any] = {"done": False, "sent": False, "shown": False, "reason": None, "said": "", "told": ""}
        with self._asking:
            source = self.source
            if source is None:
                return {**answer, "reason": NO_KEY, "said": "no key for Shipday"}
            # as it stands now, not as it stood when the hub last asked: a change is never sent on old news.
            # The drivers are asked for only by a hub that has not read them yet (one just started)
            before = self._round(forced=True, drivers=self._drivers_ms is None)
            if not before["answered"]:
                return {**answer, "reason": before["reason"], "said": before["said"]}
            with self._lock:
                order = self._orders.get(order_id)
            refusal = check(order)
            if refusal is not None:
                return {**answer, "reason": refusal}
            failed: ShipdayFailed | None = None
            try:
                send(source)
            except ShipdayFailed as err:
                failed = err
            after = self._round(forced=True, drivers=False)
            with self._lock:
                # as it is listed now: among the active ones, or among the ones that ended today
                order = self._orders.get(order_id) or self._done.get(order_id)
            answer["sent"] = True
            answer["shown"] = shown is not None and after["answered"] and shown(order)
            answer["done"] = failed is None or answer["shown"]
            if not answer["done"] and failed is not None:
                answer.update(reason=failed.reason, said=failed.said, told=failed.told)
            # who did what, by Shipday's own ids: no customer and nothing Shipday said
            if answer["done"]:
                log.warning("shipday: order %s %s by %s", order_id, what, by)
            else:
                log.warning("shipday: order %s not %s (%s), asked by %s", order_id, what, answer["reason"], by)
            return answer

    def _failed(self, now: int, err: ShipdayFailed) -> None:
        since = self._failure["since_ms"] if self._failure is not None else now
        if self._failure is None or self._failure["reason"] != err.reason:
            log.warning("shipday: %s", err.said)
        self._failure = {"since_ms": since, "at_ms": now, "reason": err.reason, "said": err.said}
        if err.reason == LIMIT:
            self._held_ms = min(HOLD_MOST_MS, max(HOLD_FIRST_MS, self._held_ms * 2))
            self._hold_until_ms = now + self._held_ms

    def _left(self, source: Shipday, orders: dict[int, dict[str, Any]], now: int) -> None:
        """What became of the orders that are no longer active. Each is asked for by its number; what
        Shipday says of it is kept for the day, and one it says nothing of is kept as gone."""
        day = localtime.service_day_of(now)
        with self._lock:
            before = dict(self._orders)
            if self._done_day != day:
                self._done, self._done_day = {}, day
                self._ready, self._ready_missed, self._ready_itself = {}, {}, set()
        for ident, order in before.items():
            if ident not in orders and ident not in self._done:
                self._leaving.setdefault(ident, (order, 0))
        finished: dict[int, dict[str, Any]] = {}
        for ident in list(self._leaving)[:LEAVING_MOST]:
            last, tries = self._leaving[ident]
            if ident in orders:  # it is active again: nothing left
                del self._leaving[ident]
                continue
            became: dict[str, Any] | None = None
            try:
                raw = source.order(last["number"]) if last["number"] else None
                read = order_of(raw) if raw is not None else None
                # the same order, and finished: one that Shipday still calls active has only left the list
                if read is not None and read["id"] == ident and read["state"] in FINISHED:
                    became = read
                elif raw is None or read is None or read["id"] != ident or tries + 1 >= LEAVING_TRIES:
                    became = {**last, "state": GONE}
            except ShipdayFailed:
                if tries + 1 >= LEAVING_TRIES:
                    became = {**last, "state": GONE}
            if became is None:
                self._leaving[ident] = (last, tries + 1)
                continue
            del self._leaving[ident]
            finished[ident] = {**became, "ended_ms": became.get("delivered_ms") or now}
        if finished:
            with self._lock:
                self._done.update(finished)
                for ident in list(self._done)[: max(0, len(self._done) - DONE_MOST)]:
                    del self._done[ident]

    def _etas(self, source: Shipday, orders: dict[int, dict[str, Any]], now: int) -> None:
        """How far away the deliveries with a driver are, as far as Shipday says: a few of them asked this
        round, the rest keeping what they were last told. The moment is written onto the order (`eta_ms`),
        over the one the order itself carried."""
        self._eta = {ident: told for ident, told in self._eta.items() if ident in orders}
        due: list[tuple[int, int, str]] = []
        for ident, order in orders.items():
            again, at = self._eta.get(ident, (0, None))
            if at is not None:
                order["eta_ms"], order["eta_said"] = at, ""
            tracked = tracking_id_of(order["tracking"]) if order["tracking"] else None
            if order["driver"] is not None and order["state"] in ETA_STATES and tracked and now >= again:
                due.append((again, ident, tracked))
        if now < self._eta_hold_ms:
            return
        for _, ident, tracked in sorted(due)[:ETA_MOST]:
            try:
                minutes = minutes_of(source.progress(tracked))
            except ShipdayFailed as err:
                if err.reason == REFUSED:
                    # the key works (the orders came with it): this call is not the account's to make
                    self._eta_state, self._eta_hold_ms = ETA_PLAN, now + ETA_PLAN_MS
                    log.warning("shipday: it will not say how far away a delivery is (the account's plan)")
                    return
                if err.reason == LIMIT:
                    self._eta_hold_ms = now + ETA_MISS_MS
                    return
                self._eta[ident] = (now + ETA_MISS_MS, self._eta.get(ident, (0, None))[1])
                continue
            self._eta_state = ETA_ON
            at = None if minutes is None else (now + minutes * 60_000) // 60_000 * 60_000
            self._eta[ident] = (now + ETA_EVERY_MS, at)
            if at is not None:
                orders[ident]["eta_ms"], orders[ident]["eta_said"] = at, ""

    def _told(self) -> None:
        """Tells the screens when the picture is another one than the last they were told of."""
        with self._lock:
            picture = json.dumps(
                [
                    list(self._orders.values()),
                    list(self._done.values()),
                    self._drivers,
                    self._trouble(),
                    self._eta_state,
                    sorted(self._ready.items()),
                ],
                sort_keys=True,
            )
            changed, self._picture = picture != self._picture, picture
        if changed and self.on_change is not None:
            self.on_change()

    # --- what a screen is told -----------------------------------------------------------------------------

    def watched(self) -> None:
        """A screen is looking: Shipday is asked oftener for a while, and at once if nobody was looking."""
        now = self._now()
        was = now - self._watched_ms < WATCHED_MS
        self._watched_ms = self._seen_ms = now
        if not was:
            self._wake.set()

    def seen(self) -> None:
        """A screen read the picture without showing it (the home screen, for its button): somebody is at a
        terminal, so Shipday is asked every minute, and at once if nobody had asked for a long while."""
        now = self._now()
        idle = now - self._seen_ms >= IDLE_AFTER_MS
        self._seen_ms = now
        if idle:
            self._wake.set()

    def _trouble(self) -> dict[str, Any] | None:
        failure = self._failure
        if failure is None:
            return None
        return {"since_ms": failure["since_ms"], "reason": failure["reason"], "said": failure["said"]}

    def said(self) -> dict[str, Any]:
        """The picture as `GET /shipday` answers it (`pos.api.shipday`). It carries no time of asking: an
        answer that has not changed reads the same, so a screen that has it is told so and draws nothing."""
        with self._lock:
            orders = [dict(order) for order in self._orders.values()]
            done = [dict(order) for order in reversed(self._done.values())][:DONE_SAID]
            drivers = [dict(driver) for driver in self._drivers]
            trouble = self._trouble()
            read = self._answered_ms is not None
            eta = self._eta_state
            ready = dict(self._ready)
        names = {driver["id"]: driver for driver in drivers}
        found = matched([*orders, *done], list(self.pos()) if self.pos is not None else [])
        loads: dict[int, int] = {}
        for order in [*orders, *done]:
            driver = order["driver"]
            if driver is not None and not driver["name"] and driver["id"] in names:
                order["driver"] = {**driver, "name": names[driver["id"]]["name"], "phone": names[driver["id"]]["phone"]}
            match = found.get(order["id"])
            order["pos"] = match[0].about(match[1]) if match is not None else None
            order["steps"] = list(steps_of(order))
            told = ready.get(order["id"])
            if told is None and match is not None and match[0].told_id == order["id"]:
                told = match[0].told_ms  # its check says so: told before this hub started, or by the other hub
            order["ready_ms"] = told
            order["can_ready"] = False
        for order in orders:
            order["can_ready"] = order["state"] in WAITING and order["ready_ms"] is None
            if order["driver"] is not None and order["state"] in ACTIVE:
                loads[order["driver"]["id"]] = loads.get(order["driver"]["id"], 0) + 1
        for driver in drivers:
            driver["orders"] = loads.get(driver["id"], 0)
        return {
            "on": self.configured,
            "read": read,
            "trouble": trouble,
            "eta": eta,
            "can": list(CAN),
            "orders": orders,
            "done": done,
            "drivers": drivers,
        }

    def about(self) -> dict[str, Any]:
        """How the asking goes, for the page of the hub's keys: no order and no customer in it."""
        with self._lock:
            return {
                "on": self.configured,
                "running": self.running,
                "asked_ms": self._asked_ms,
                "answered_ms": self._answered_ms,
                "trouble": self._trouble(),
                "eta": self._eta_state,
                "orders": len(self._orders),
                "drivers": len(self._drivers),
                "on_shift": sum(1 for driver in self._drivers if driver["on_shift"]),
            }

    def ask_now(self) -> dict[str, Any]:
        """A person asked: Shipday is asked now, unless it was within `ASK_GAP_MS` (then `soon` is true and
        nothing is done)."""
        asked = self._asked_ms
        if self.source is not None and asked is not None and self._now() - asked < ASK_GAP_MS:
            return {"asked": False, "answered": False, "soon": True, "reason": None, "said": ""}
        return {**self.round(forced=True), "soon": False}

    # --- for as long as the hub runs -----------------------------------------------------------------------

    def pause(self) -> float:
        """How long the loop waits before the next round."""
        now = self._now()
        if now - self._watched_ms < WATCHED_MS and self._failure is None:
            return FAST_SECONDS
        return SLOW_SECONDS if now - self._seen_ms < IDLE_AFTER_MS else IDLE_SECONDS

    def start(self) -> None:
        """A daemon that does a round now and then one after every `pause`. Nothing without a key, and
        nothing where it already runs: a key typed later starts it (`pos.api.keys.use_keys`)."""
        if self.source is None or self._thread is not None:
            return

        def loop() -> None:
            while True:
                self._wake.clear()
                try:
                    self.round()
                except Exception:  # noqa: BLE001 - a round that goes wrong must never be the last one
                    log.error("shipday: a round went wrong\n%s", traceback.format_exc(limit=3, chain=False))
                self._wake.wait(self.pause())

        self._thread = threading.Thread(target=loop, name="shipday", daemon=True)
        self._thread.start()


__all__ = [
    "CAN",
    "ETA_OFF",
    "ETA_ON",
    "ETA_PLAN",
    "HAS_DRIVER",
    "MOVED",
    "NOT_A_STEP",
    "NOT_LISTED",
    "NO_DRIVER",
    "NO_KEY",
    "ON_ITS_WAY",
    "OTHER_DRIVER",
    "UNKNOWN_DRIVER",
    "UNSURE",
    "WAITING",
    "ShipdayBoard",
    "steps_of",
]
