"""Online orders on the hub: asked for every minute, written down, put on the POS (docs/online-orders.md).

One round (`OnlineOrders.round`) does three things, in this order:

1. **Ask.** GloriaFood is asked for the orders accepted since the last time (`pos.online.gloriafood`), but
   only by a hub that can write them down (`Inbox.writable`): GloriaFood hands an order over once.
2. **Write down.** Every order it gave is written to the inbox as it came (`pos.online.inbox`), before
   anything else is done with it. One that cannot be written down this round is held in memory and written
   the next.
3. **Put on the POS.** Every order written down and not yet dealt with is turned into a to-go order
   (`pos.online.place`) and handed to `put`, which the API sets: it stores the operations, numbers the
   order and prints its tickets, as it does for a screen's. What became of the order is written beside it.

An order that cannot be put on the POS is tried again each round, a few times, and then left for a person:
`status` lists it and `notice`, when the API set one, prints a slip where the to-go orders print. So does
an order that reached the hub after its time and was not sent to the kitchen.

Nothing here names a customer in a log or in `status`: an order is told of by GloriaFood's number for it.
"""

from __future__ import annotations

import logging
import threading
import time
import traceback
from collections.abc import Callable, Mapping
from dataclasses import replace
from typing import Any, Protocol

from .. import localtime
from .gloriafood import NAME, FetchFailed
from .inbox import KEEP_DAYS, MOST_TRIES, Arrival, Inbox
from .place import ORDER_TYPES, CannotPlace, NotAnOrder, Placed, ext_id_of

log = logging.getLogger("pos.online")

UNREADABLE = "unreadable"
"""The kind of an arrival that is no order: an answer of GloriaFood's that could not be read."""
SEVERAL = "several"
"""The kind of the one slip that stands for many: orders from earlier days that all came in one round."""
MOST_OLD_SLIPS = 3
"""More orders from earlier days than this in one round get one slip between them: a key put on the hub
days after the integration was made brings them all at once."""
INTERVAL_SECONDS = 60.0
"""How often GloriaFood is asked: what its own pages say a POS should do."""
DAY_MS = 24 * 60 * 60_000
FORGET_EVERY_MS = 60 * 60_000
UNREAD_SLIP_MS = 15 * 60_000
"""An answer that cannot be read prints a slip, but not one a minute while GloriaFood sends nonsense."""
LISTED = 10
"""How many orders to look at `status` names."""


class Source(Protocol):
    """Where online orders come from: `pop` gives the ones accepted since it was last asked, once."""

    name: str

    def pop(self) -> list[dict[str, Any]]: ...


class OnlineOrders:
    def __init__(
        self,
        source: Source | None,
        inbox: Inbox | None = None,
        *,
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.source = source
        self.inbox = inbox if inbox is not None else Inbox()
        # Set by the API: `put` stores an order's operations and prints its tickets; `notice` prints a slip
        # for an order somebody has to look at (the arrival, and the words for it).
        self.put: Callable[[Mapping[str, Any]], Placed] | None = None
        self.notice: Callable[[Arrival, str], None] | None = None
        self._now = now
        self._lock = threading.Lock()  # one round at a time: the minute's own and one a person asked for
        self._unwritten: list[Arrival] = []  # given by GloriaFood and not written down yet
        self._asked_ms: int | None = None
        self._answered_ms: int | None = None
        self._failure: tuple[int, str] | None = None  # the last time asking failed, and why
        self._forgot_ms = 0
        self._unread_slip_ms: int | None = None
        self._thread: threading.Thread | None = None

    @property
    def configured(self) -> bool:
        return self.source is not None

    # --- a round ---------------------------------------------------------------------------------

    def round(self) -> dict[str, Any]:
        """Asks, writes down and puts on the POS, once. Gives what happened: how many orders `came`, how
        many were `placed`, `kept` (nothing the POS takes) and `failed`, and `asked`: whether GloriaFood
        was asked at all (not without a key, and not by a hub that cannot write)."""
        with self._lock:
            done = {"asked": False, "came": 0, "placed": 0, "kept": 0, "failed": 0}
            if self.inbox.writable():
                self._write_down()
                if self.source is not None:
                    done["asked"] = True
                    done["came"] = self._ask()
                slips: list[tuple[Arrival, str]] = []
                for arrival in self._waiting():
                    settled, tell = self._place(arrival)
                    done[settled.state] += 1
                    if tell:
                        slips.append((settled, tell))
                self._slips(slips)
                self._forget()
            return done

    def _slips(self, slips: list[tuple[Arrival, str]]) -> None:
        """A slip for each order somebody has to look at; the ones from earlier days share one when there
        are many of them."""
        old = [arrival for arrival, _ in slips if arrival.state == "kept"]
        if len(old) > MOST_OLD_SLIPS:
            slips = [(arrival, said) for arrival, said in slips if arrival.state != "kept"]
            now = self._now()
            said = (
                f"{len(old)} online orders from earlier days reached the hub only now: they are in GloriaFood's "
                "own records and were not put on today's sales"
            )
            several = Arrival(old[0].source, f"old-{now}", now, None, kind=SEVERAL, state="kept", said=said)
            slips.append((several, said))
        for arrival, said in slips:
            self._tell(arrival, said)

    def _ask(self) -> int:
        assert self.source is not None
        now = self._asked_ms = self._now()
        try:
            orders = self.source.pop()
        except FetchFailed as err:
            self._failure = (now, err.reason)
            log.warning("online orders: %s", err.reason)
            if err.body is not None:
                # It answered, with something that cannot be read: there may be orders in it, and it will
                # not send them again. Kept as it came, for a person.
                unread = Arrival(
                    source=self.source.name,
                    ext_id=f"unread-{now}",
                    fetched_ms=now,
                    raw={"unreadable": err.body},
                    kind=UNREADABLE,
                    state="failed",
                    said="GloriaFood's answer could not be read: it may hold orders, which are in its own app",
                    tries=MOST_TRIES,
                    settled_ms=now,
                )
                self._unwritten.append(unread)
                self._write_down()
                if self._unread_slip_ms is None or now - self._unread_slip_ms >= UNREAD_SLIP_MS:
                    self._unread_slip_ms = now
                    self._tell(unread, unread.said)
            return 0
        self._answered_ms, self._failure = now, None
        for n, order in enumerate(orders):
            ext_id = ext_id_of(order) or f"unnumbered-{now}-{n}"
            self._unwritten.append(
                Arrival(source=self.source.name, ext_id=ext_id, fetched_ms=now, raw=order, kind=_kind(order))
            )
        self._write_down()
        return len(orders)

    def _write_down(self) -> None:
        left: list[Arrival] = []
        for arrival in self._unwritten:
            try:
                self.inbox.add(arrival)  # False for one already here: GloriaFood sent it twice
            except Exception:  # noqa: BLE001 - whatever the database says, the order is kept for the next round
                log.error("online order %s could not be written down; it is kept in memory", arrival.ext_id)
                left.append(arrival)
        self._unwritten = left

    def _waiting(self) -> list[Arrival]:
        try:
            return self.inbox.waiting()
        except Exception:  # noqa: BLE001 - the database again: the next round reads them
            return []

    def _place(self, arrival: Arrival) -> tuple[Arrival, str]:
        """Puts one order on the POS and writes what became of it. Gives the order as it is now (`placed`,
        `kept` or `failed`) and what a slip should say of it, when somebody has to look at it."""
        now = self._now()
        settled = replace(arrival, settled_ms=now)
        tell = ""
        try:
            if self.put is None or arrival.raw is None:
                raise CannotPlace("this hub is not set up to put it on the POS")
            placed = self.put(arrival.raw)
        except NotAnOrder as err:
            settled = replace(settled, state="kept", said=err.reason)
            tell = err.reason if err.old else ""
        except CannotPlace as err:
            settled = replace(settled, state="failed", said=err.reason, tries=MOST_TRIES)
            tell = err.reason
        except Exception as err:  # noqa: BLE001 - one order that will not go on must not stop the others
            # the place in the code, without the words: an error's words can quote what a customer wrote
            where = "".join(traceback.format_tb(err.__traceback__)[-3:])
            log.error("online order %s could not be put on the POS (%s)\n%s", arrival.ext_id, type(err).__name__, where)
            said = f"it could not be put on the POS ({type(err).__name__})"
            settled = replace(settled, state="failed", said=said, tries=arrival.tries + 1)
            tell = said if settled.tries >= MOST_TRIES else ""
        else:
            settled = replace(settled, state="placed", order_id=placed.order_id, said=placed.said)
            tell = placed.said if placed.late else ""
        try:
            self.inbox.settle(settled)
        except Exception:  # noqa: BLE001 - it stays as it was and is looked at again: an order placed twice is one order
            log.error("what became of online order %s could not be written down", arrival.ext_id)
        return settled, tell

    def _tell(self, arrival: Arrival, said: str) -> None:
        if self.notice is None:
            return
        try:
            self.notice(arrival, said)
        except Exception:  # noqa: BLE001 - a slip that does not print changes nothing of the order
            log.error("the slip for online order %s could not be printed", arrival.ext_id)

    def _forget(self) -> None:
        """Once an hour: the customer's details are dropped from the orders older than `KEEP_DAYS`."""
        now = self._now()
        if now - self._forgot_ms < FORGET_EVERY_MS:
            return
        self._forgot_ms = now
        try:
            self.inbox.forget_before(now - KEEP_DAYS * DAY_MS)
        except Exception:  # noqa: BLE001 - it is tried again in an hour
            pass

    # --- what a person is told -------------------------------------------------------------------

    def status(self) -> dict[str, Any]:
        """How the online orders are doing, for `hubctl online status` and the screens: whether the hub has
        a key, when GloriaFood last answered and why it did not, today's orders by what became of them, and
        the ones to look at, each by GloriaFood's number. Nothing of a customer."""
        now = self._now()
        start, _ = localtime.service_day(localtime.service_day_of(now))
        try:
            today = self.inbox.since(start)
            waiting = self.inbox.waiting()
            troubled = self.inbox.troubled(LISTED)
        except Exception:  # noqa: BLE001 - the database cannot be read: say what is known without it
            today, waiting, troubled = [], [], []
        look = {(row.source, row.ext_id): row for row in troubled}
        for row in today:
            if _to_look_at(row):
                look.setdefault((row.source, row.ext_id), row)
        listed = sorted(look.values(), key=lambda row: row.fetched_ms, reverse=True)[:LISTED]
        return {
            "configured": self.configured,
            "source": self.source.name if self.source is not None else None,
            "running": self._thread is not None and self._thread.is_alive(),
            "writable": self.inbox.writable(),
            "asked_ms": self._asked_ms,
            "answered_ms": self._answered_ms,
            "last_failure": None if self._failure is None else {"at_ms": self._failure[0], "reason": self._failure[1]},
            "today": {
                "came": len(today),
                "placed": sum(row.state == "placed" for row in today),
                "kept": sum(row.state == "kept" for row in today),
                "failed": sum(row.state == "failed" for row in today),
            },
            "waiting": len(waiting) + len(self._unwritten),
            "look": [row.about() for row in listed],
        }

    # --- every minute ----------------------------------------------------------------------------

    def start(self, interval: float = INTERVAL_SECONDS) -> None:
        """A daemon that does a round now and then one every `interval` seconds. Nothing without a key."""
        if self.source is None or self._thread is not None:
            return

        def loop() -> None:
            while True:
                try:
                    self.round()
                except Exception:  # noqa: BLE001 - a round that goes wrong must never be the last one
                    log.error("online orders: a round went wrong\n%s", traceback.format_exc(limit=3, chain=False))
                time.sleep(interval)

        self._thread = threading.Thread(target=loop, name="online-orders", daemon=True)
        self._thread.start()


def _kind(order: Mapping[str, Any]) -> str:
    return str(order.get("type") or "")[:40]


def _to_look_at(row: Arrival) -> bool:
    """Whether a person should look at an order: one that failed, one that went on the POS with something
    to say of it, and one the POS would take as an order that was kept all the same (it came a day late)."""
    if row.state == "failed":
        return True
    if row.state == "placed":
        return bool(row.said)
    return row.state == "kept" and row.kind in ORDER_TYPES


__all__ = ["INTERVAL_SECONDS", "NAME", "SEVERAL", "UNREADABLE", "OnlineOrders", "Source"]
