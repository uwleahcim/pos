"""Online orders on the hub: sent to it or asked for, written down, put on the POS (docs/online-orders.md).

An order reaches the hub in two ways, and both are on at once:

- **A push** (`OnlineOrders.push`): GloriaFood sends the order the moment it is accepted. It is written down
  and put on the POS before GloriaFood is answered.
- **A round** (`OnlineOrders.round`), every minute: GloriaFood is asked for the orders accepted since the
  last time (`pos.online.gloriafood`), but only by a hub that can write them down (`Inbox.writable`):
  GloriaFood hands an order over once when asked. This is the net under the push: an order whose push never
  arrived is here within the minute.

Either way the same three things happen, in this order:

1. **Write down.** Every order given is written to the inbox as it came (`pos.online.inbox`), with how it
   came, before anything else is done with it. One that is already there is the same order come the other
   way, or sent twice: the first stands and the second is nothing. One that cannot be written down now is
   held in memory and written at the next round.
2. **Put on the POS.** Every order written down and not yet dealt with is turned into a to-go order
   (`pos.online.place`) and handed to `put`, which the API sets: it stores the operations, numbers the
   order and prints its tickets, as it does for a screen's. What became of the order is written beside it.
3. **Tell.** An order that cannot be put on the POS is tried again each round, a few times, and then left
   for a person: `status` lists it and `notice`, when the API set one, prints a slip where the to-go orders
   print. So does an order that reached the hub after its time and was not sent to the kitchen.

One order at a time is written down and put on the POS (`_lock`), whichever way it came, so the two ways
cannot both place the same order. Asking GloriaFood is done outside that lock: a push never waits for it.

Nothing here names a customer in a log or in `status`: an order is told of by GloriaFood's number for it.
A push that is turned away is counted and told of by why, never by what it carried.
"""

from __future__ import annotations

import logging
import threading
import time
import traceback
from collections.abc import Callable, Mapping, Sequence
from dataclasses import replace
from typing import Any, Protocol

from .. import localtime
from .gloriafood import NAME, FetchFailed, allowed
from .inbox import KEEP_DAYS, MOST_TRIES, POLL, PUSH, Arrival, Inbox
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
REFUSAL_LOG_MS = 60_000
"""A push that is turned away is counted every time and logged at most this often: the way in is open to
the internet, and whoever knocks must not fill the hub's log."""
NO_KEY_SENT = "it carried no key"
WRONG_KEY = "it carried the wrong key"


class PushRefused(Exception):
    """A push the hub does not take, in words for a person. `status` is what the sender is answered."""

    def __init__(self, reason: str, status: int) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status = status


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
        push_key: str | None = None,
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.source = source
        self.inbox = inbox if inbox is not None else Inbox()
        self._push_key = push_key or None  # what a push must carry; None: every push is turned away
        # Set by the API: `put` stores an order's operations and prints its tickets; `notice` prints a slip
        # for an order somebody has to look at (the arrival, and the words for it).
        self.put: Callable[[Mapping[str, Any]], Placed] | None = None
        self.notice: Callable[[Arrival, str], None] | None = None
        self._now = now
        self._asking = threading.Lock()  # one round at a time: the minute's own and one a person asked for
        self._lock = threading.Lock()  # one order at a time is written down and placed, however it came
        self._unwritten: list[Arrival] = []  # given by GloriaFood and not written down yet
        self._asked_ms: int | None = None
        self._answered_ms: int | None = None
        self._failure: tuple[int, str] | None = None  # the last time asking failed, and why
        self._forgot_ms = 0
        self._unread_slip_ms: int | None = None
        self._pushed_ms: int | None = None  # the last push the hub took
        self._refused: tuple[int, str] | None = None  # the last push it turned away, and why
        self._refusals = 0
        self._refusal_logged_ms: int | None = None
        self._thread: threading.Thread | None = None

    @property
    def configured(self) -> bool:
        """Whether this hub asks GloriaFood: it has the key for that."""
        return self.source is not None

    @property
    def pushable(self) -> bool:
        """Whether this hub takes pushes: it has the key they must carry."""
        return self._push_key is not None

    @property
    def name(self) -> str:
        return self.source.name if self.source is not None else NAME

    # --- a round ---------------------------------------------------------------------------------

    def round(self) -> dict[str, Any]:
        """Asks, writes down and puts on the POS, once. Gives what happened: how many orders `came`, how
        many of them were here already (`known`: a push brought them first), how many were `placed`, `kept`
        (nothing the POS takes) and `failed`, and `asked`: whether GloriaFood was asked at all (not without
        a key, and not by a hub that cannot write)."""
        with self._asking:
            done = {"asked": False, "came": 0, "known": 0, "placed": 0, "kept": 0, "failed": 0}
            if not self.inbox.writable():
                return done
            answer: list[dict[str, Any]] | FetchFailed | None = None
            now = self._now()
            if self.source is not None:
                done["asked"] = True
                self._asked_ms = now
                try:
                    answer = self.source.pop()  # outside `_lock`: a push is not kept waiting for GloriaFood
                except FetchFailed as err:
                    answer = err
            with self._lock:
                if isinstance(answer, FetchFailed):
                    self._failed(now, answer)
                elif answer is not None:
                    self._answered_ms, self._failure = now, None
                    done["came"] = len(answer)
                    done["known"], _ = self._take(answer, now, POLL)
                else:
                    self._write_down()
                self._settle(done)
                self._forget()
            return done

    def admit(self, authorization: str | None) -> None:
        """Whether a push is let in, by the `Authorization` header it came with, before anything of it is
        read. `PushRefused` for one that is not: on a hub with no key for pushes (404), and for one that
        does not carry the key (401)."""
        if self._push_key is None:
            raise PushRefused("this hub takes no pushes", 404)
        if not allowed(authorization, self._push_key):
            raise self._turned_away(WRONG_KEY if (authorization or "").strip() else NO_KEY_SENT)

    def push(self, read: Callable[[], Sequence[Mapping[str, Any]]]) -> dict[str, Any]:
        """Orders GloriaFood sent by itself, in a push that was let in (`admit`). `read` gives them, and
        raises `FetchFailed` for a push that cannot be read. They are written down and put on the POS now,
        before GloriaFood is answered. Gives how many were `received`, how many of them were here already
        (`known`), how many orders were `placed`, `kept` and `failed` just now, and how many could not be
        written down (`unwritten`: held in memory until the next round).

        `PushRefused` for one this hub cannot take: a hub that cannot write orders down (503: the other hub
        takes them, and the asking brings whatever is missed), and a push that cannot be read (422: it is
        kept as it came, for a person)."""
        if not self.inbox.writable():
            raise PushRefused("this hub cannot write orders down now", 503)
        now = self._now()
        try:
            orders = read()
        except FetchFailed as err:
            with self._lock:
                self._pushed_ms = now
                self._unread(now, err, PUSH)
            raise PushRefused(err.reason, 422) from None
        with self._lock:
            self._pushed_ms = now
            done = {"received": len(orders), "known": 0, "placed": 0, "kept": 0, "failed": 0, "unwritten": 0}
            done["known"], done["unwritten"] = self._take(orders, now, PUSH)
            self._settle(done, new_only=True)
            return done

    def _turned_away(self, reason: str) -> PushRefused:
        """Counts a push that did not carry the key, and says so in the log now and then. What it carried
        is not looked at, not kept and not logged."""
        now = self._now()
        self._refused = (now, reason)
        self._refusals += 1
        if self._refusal_logged_ms is None or now - self._refusal_logged_ms >= REFUSAL_LOG_MS:
            self._refusal_logged_ms = now
            log.warning("online orders: a push was turned away: %s (%d so far)", reason, self._refusals)
        return PushRefused(reason, 401)

    def _take(self, orders: Sequence[Mapping[str, Any]], now: int, via: str) -> tuple[int, int]:
        """Writes down the orders that just came, this way. Gives how many of them were here already, and
        how many could not be written down now."""
        mine = []
        for n, order in enumerate(orders):
            ext_id = ext_id_of(order) or f"unnumbered-{now}-{n}"
            mine.append(
                Arrival(source=self.name, ext_id=ext_id, fetched_ms=now, raw=dict(order), kind=_kind(order), via=via)
            )
        self._unwritten.extend(mine)
        known = {id(arrival) for arrival in self._write_down()}
        left = {id(arrival) for arrival in self._unwritten}
        return sum(id(arrival) in known for arrival in mine), sum(id(arrival) in left for arrival in mine)

    def _settle(self, done: dict[str, Any], *, new_only: bool = False) -> None:
        """Puts every order that is written down and waiting on the POS, and prints the slips for the ones
        somebody has to look at. `new_only` leaves the ones that would not go on before to the minute's
        round: a busy minute of pushes must not use up an order's tries in a few seconds."""
        slips: list[tuple[Arrival, str]] = []
        for arrival in self._waiting():
            if new_only and arrival.state != "new":
                continue
            settled, tell = self._place(arrival)
            done[settled.state] += 1
            if tell:
                slips.append((settled, tell))
        self._slips(slips)

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

    def _failed(self, now: int, err: FetchFailed) -> None:
        """GloriaFood was asked and gave no orders: why is kept for `status`, and what it did send, when it
        sent something, for a person."""
        self._failure = (now, err.reason)
        log.warning("online orders: %s", err.reason)
        if err.body is not None:
            self._unread(now, err, POLL)

    def _unread(self, now: int, err: FetchFailed, via: str) -> None:
        """Something of GloriaFood's that cannot be read is kept as it came, for a person: there may be
        orders in it.

        An answer to the hub's asking is not sent again, so a slip says to look at GloriaFood's app (at most
        one a quarter of an hour). A push that cannot be read prints one only on a hub that does not also
        ask: where it asks, the same orders come that way within the minute, and a slip would have somebody
        ring them in a second time."""
        if via == PUSH:
            log.warning("online orders: %s", err.reason)
            where = "the hub's asking brings its orders" if self.configured else "its orders are in GloriaFood's app"
            said = f"{err.reason}: {where}"
        else:
            said = f"{err.reason}: it may hold orders, which are in its own app"
        unread = Arrival(
            source=self.name,
            ext_id=f"unread-{now}",
            fetched_ms=now,
            raw={"unreadable": err.body or ""},
            kind=UNREADABLE,
            state="failed",
            said=said,
            tries=MOST_TRIES,
            settled_ms=now,
            via=via,
        )
        self._unwritten.append(unread)
        self._write_down()
        if via == PUSH and self.configured:
            return
        if self._unread_slip_ms is None or now - self._unread_slip_ms >= UNREAD_SLIP_MS:
            self._unread_slip_ms = now
            self._tell(unread, unread.said)

    def _write_down(self) -> list[Arrival]:
        """Writes down what is held in memory. Gives the ones that were here already: the same order sent
        twice, or come the other way first. One that cannot be written now stays in memory."""
        left: list[Arrival] = []
        known: list[Arrival] = []
        for arrival in self._unwritten:
            try:
                if not self.inbox.add(arrival):
                    known.append(arrival)
            except Exception:  # noqa: BLE001 - whatever the database says, the order is kept for the next round
                log.error("online order %s could not be written down; it is kept in memory", arrival.ext_id)
                left.append(arrival)
        self._unwritten = left
        return known

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
        """How the online orders are doing, for `hubctl online status` and the screens: whether the hub
        asks GloriaFood (`configured`) and when it last answered and why it did not; whether it takes pushes
        (`push`), when the last one came, and the last one it turned away and why; today's orders by what
        became of them and by how they came; and the ones to look at, each by GloriaFood's number. Nothing
        of a customer, and no key."""
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
        orders = [row for row in today if row.kind != UNREADABLE]
        pushed = [row.fetched_ms for row in today if row.via == PUSH]
        pushed_ms = max([*pushed, *([] if self._pushed_ms is None else [self._pushed_ms])], default=None)
        refused = None
        if self._refused is not None:
            refused = {"at_ms": self._refused[0], "reason": self._refused[1], "count": self._refusals}
        return {
            "configured": self.configured,
            "source": self.source.name if self.source is not None else None,
            "running": self._thread is not None and self._thread.is_alive(),
            "writable": self.inbox.writable(),
            "asked_ms": self._asked_ms,
            "answered_ms": self._answered_ms,
            "last_failure": None if self._failure is None else {"at_ms": self._failure[0], "reason": self._failure[1]},
            "push": {"configured": self.pushable, "pushed_ms": pushed_ms, "refused": refused},
            "today": {
                "came": len(orders),
                "by_push": sum(row.via == PUSH for row in orders),
                "by_poll": sum(row.via == POLL for row in orders),
                "placed": sum(row.state == "placed" for row in orders),
                "kept": sum(row.state == "kept" for row in orders),
                "failed": sum(row.state == "failed" for row in orders),
                "unread": len(today) - len(orders),
            },
            "waiting": len(waiting) + len(self._unwritten),
            "look": [row.about() for row in listed],
        }

    # --- every minute ----------------------------------------------------------------------------

    def start(self, interval: float = INTERVAL_SECONDS) -> None:
        """A daemon that does a round now and then one every `interval` seconds. Nothing without a key:
        with the one for asking it asks; with only the one for pushes it still tries again the orders that
        would not go on, and drops the old ones."""
        if not (self.configured or self.pushable) or self._thread is not None:
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


__all__ = ["INTERVAL_SECONDS", "NAME", "SEVERAL", "UNREADABLE", "OnlineOrders", "PushRefused", "Source"]
