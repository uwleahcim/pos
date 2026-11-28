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

Nothing here names a customer in a log: an order is told of by Shipday's own id.
"""

from __future__ import annotations

import json
import logging
import threading
import time
import traceback
from collections.abc import Callable, Sequence
from datetime import date
from typing import Any

from .. import localtime
from .client import LIMIT, REFUSED, Shipday, ShipdayFailed
from .match import OnPos, matched
from .read import ACTIVE, FINISHED, GONE, PICKED_UP, READY_TO_DELIVER, STARTED, driver_of, minutes_of, order_of
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


class ShipdayBoard:
    def __init__(
        self,
        source: Shipday | None = None,
        *,
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.source = source
        # Set by the API: `pos` gives the POS's own deliveries of the running day, for the matching;
        # `on_change` tells the screens that the picture is another one.
        self.pos: Callable[[], Sequence[OnPos]] | None = None
        self.on_change: Callable[[], None] | None = None
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
            source = self.source
            if source is None:
                return {"asked": False, "answered": False, "reason": "no_key", "said": "no key for Shipday"}
            now = self._now()
            if not forced and now < self._hold_until_ms:
                return {"asked": False, "answered": False, "reason": LIMIT, "said": "Shipday is given a rest"}
            self._asked_ms = now
            try:
                raw_orders = source.active_orders()
                raw_drivers = None
                if forced or self._drivers_ms is None or now - self._drivers_ms >= DRIVERS_EVERY_MS:
                    raw_drivers = source.carriers()
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
                if raw_drivers is not None:
                    self._drivers = [driver for raw in raw_drivers if (driver := driver_of(raw)) is not None]
                    self._drivers_ms = now
            self._told()
            return {"asked": True, "answered": True, "reason": None, "said": ""}

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
        names = {driver["id"]: driver for driver in drivers}
        found = matched([*orders, *done], list(self.pos()) if self.pos is not None else [])
        loads: dict[int, int] = {}
        for order in [*orders, *done]:
            driver = order["driver"]
            if driver is not None and not driver["name"] and driver["id"] in names:
                order["driver"] = {**driver, "name": names[driver["id"]]["name"], "phone": names[driver["id"]]["phone"]}
            match = found.get(order["id"])
            order["pos"] = match[0].about(match[1]) if match is not None else None
        for order in orders:
            if order["driver"] is not None and order["state"] in ACTIVE:
                loads[order["driver"]["id"]] = loads.get(order["driver"]["id"], 0) + 1
        for driver in drivers:
            driver["orders"] = loads.get(driver["id"], 0)
        return {
            "on": self.configured,
            "read": read,
            "trouble": trouble,
            "eta": eta,
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


__all__ = ["ETA_OFF", "ETA_ON", "ETA_PLAN", "ShipdayBoard"]
