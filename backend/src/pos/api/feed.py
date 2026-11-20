"""The change feed: the hub tells every connected screen what changed, the moment it does.

The screens used to ask. Each one read the open orders, the floor and the open check every two seconds and
the menu's revision every five, so twenty screens were some twenty requests a second to say "nothing new",
and a change still took up to two seconds to show on the screen beside the one that made it. A screen now
holds one request open (`GET /live`, a stream of server-sent events) and the hub writes on it when an order
changes, the menu is saved, a dish is 86'd or a location setting is written:

    event: hello
    data: {"cursor": 1234, "menu": 57, "heartbeat": 1.0}

    event: changed
    data: {"orders": ["o-17"], "topics": [], "cursor": 1236}

    event: changed
    data: {"orders": [], "topics": ["menu"]}

    :                                 (a comment line every `heartbeat` seconds: the hub is there)

The stream says *that* something changed, never what it is now: the screen then reads it with the calls it
always used (`/orders`, `/orders/{id}`, `/floor`, `/menu`), which answer 304 when it already has it. So there
is still one way to read an order, an older app that only polls keeps working beside a newer one, and an
event that is lost costs no more than the wait for the screen's slow safety poll.

The news about orders comes from the log itself, not from the request that wrote it: a watcher reads what
arrived after the last arrival it told (`arrivals`), the API pokes it after every append so the news leaves
within milliseconds, and it looks by itself once a second as well. That second look is what tells the changes
this process did not write: another API worker's, a standby hub's (its database receives the primary's log,
and PostgreSQL has no LISTEN on a standby), a menu imported with `hubctl`. The watcher runs only while a
screen is connected, so a hub nobody listens to does nothing.

Nothing is queued per screen. A screen that reads slowly has the orders it has not been told yet kept as a
set, and past `MANY` of them it is told to read everything again, so a stuck connection cannot grow the hub.

A stream never ends by itself, and a server that is asked to stop waits for its open answers: `end_on_stop`
ends the streams when the stop signal comes, so the hub restarts as fast as it did (`hubctl update`).
"""

from __future__ import annotations

import asyncio
import json
import logging
import signal
import threading
from collections.abc import AsyncIterator, Callable, Iterable, Mapping
from typing import Any, Protocol

log = logging.getLogger(__name__)

MANY = 200  # more orders than this waiting for one screen: it is told to read everything again instead


class Log(Protocol):
    """The part of an operation store the feed reads (`OpStore` and `PgOpStore` both have it)."""

    def arrivals(self, cursor: int, limit: int = ...) -> list[tuple[int, str]]: ...


def frame(event: str, data: Mapping[str, Any]) -> bytes:
    """One server-sent event: a name, one line of JSON, a blank line."""
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()


BEAT = b":\n\n"  # a comment: every client ignores it, and its arrival says the hub is alive


class _Screen:
    """One open stream and what it has not been told yet."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.wake = asyncio.Event()
        self.orders: dict[str, None] = {}  # in the order they changed, each once
        self.topics: dict[str, None] = {}
        self.cursor: int | None = None


class ChangeFeed:
    """Who is listening, and the telling. `orders_changed` and `changed` may be called from any thread."""

    def __init__(self, *, heartbeat: float = 1.0, every: float = 1.0) -> None:
        self.heartbeat = heartbeat  # seconds between two lines on a stream with no news
        self.every = every  # seconds between two looks at the log when nobody poked
        self.closing = False  # the hub is stopping: every stream ends, a new one ends after its hello
        self._lock = threading.Lock()
        self._screens: set[_Screen] = set()
        self._log: Log | None = None
        self._also: Callable[[], object] | None = None
        self._watcher: asyncio.Task[None] | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._poked: asyncio.Event | None = None

    def follow(self, source: Log, *, also: Callable[[], object] | None = None) -> None:
        """The log whose arrivals are told. `also` runs with every look, on a thread: the menu's check for a
        save made elsewhere."""
        self._log = source
        self._also = also

    @property
    def screens(self) -> int:
        """How many streams are open now."""
        with self._lock:
            return len(self._screens)

    # Telling ----------------------------------------------------------------------------------------------

    def orders_changed(self, order_ids: Iterable[str], cursor: int | None = None) -> None:
        """These orders changed; `cursor` is the log's cursor they are told up to."""
        ids = list(order_ids)
        if ids:
            self._tell(ids, (), cursor)

    def changed(self, topic: str) -> None:
        """Something that is not an order changed: `menu` (a save, the 86 board), `settings`, `notes` (a note
        for the shift was put up, changed or taken down), `waitlist` (a party was put on the list, changed,
        sat down or taken off), `reservations` (a table was booked, or a booking changed or ended) or
        `online` (there is an online order to look at, or somebody looked). A screen that does not know a
        topic ignores it."""
        self._tell((), (topic,), None)

    def _tell(self, order_ids: Iterable[str], topics: Iterable[str], cursor: int | None) -> None:
        with self._lock:
            for screen in self._screens:
                screen.orders.update(dict.fromkeys(order_ids))
                screen.topics.update(dict.fromkeys(topics))
                if cursor is not None:
                    screen.cursor = cursor
                try:
                    screen.loop.call_soon_threadsafe(screen.wake.set)
                except RuntimeError:  # its loop closed under it (the server is stopping)
                    pass

    def poke(self) -> None:
        """The log just grew: look now rather than at the next second. Does nothing when nobody listens."""
        loop, poked = self._loop, self._poked
        if loop is None or poked is None:
            return
        try:
            loop.call_soon_threadsafe(poked.set)
        except RuntimeError:
            pass

    # Listening --------------------------------------------------------------------------------------------

    async def stream(self, hello: Mapping[str, Any]) -> AsyncIterator[bytes]:
        """One screen's stream: `hello` first (the screen reads everything once when it gets it), then a
        `changed` for whatever changed since the line before, or a heartbeat when nothing did. Ends when the
        screen goes away."""
        screen = _Screen(asyncio.get_running_loop())
        with self._lock:
            self._screens.add(screen)
        try:
            # From the cursor in `hello`, taken before this screen was listening: an arrival in between is told
            # (once too often at worst), never missed.
            self._watch(int(hello.get("cursor") or 0))
            yield frame("hello", {**hello, "heartbeat": self.heartbeat})
            while not self.closing:
                try:
                    await asyncio.wait_for(screen.wake.wait(), self.heartbeat)
                except TimeoutError:
                    yield BEAT
                    continue
                if not self.closing:
                    yield frame("changed", self._take(screen))
        finally:
            with self._lock:
                self._screens.discard(screen)

    def close(self) -> None:
        """The hub is stopping: ends every stream (the screens come back to whichever hub answers)."""
        self.closing = True
        with self._lock:
            for screen in self._screens:
                try:
                    screen.loop.call_soon_threadsafe(screen.wake.set)
                except RuntimeError:
                    pass
        self.poke()  # the watcher sees there is nobody left

    def _take(self, screen: _Screen) -> dict[str, Any]:
        with self._lock:
            orders, topics, cursor = list(screen.orders), list(screen.topics), screen.cursor
            screen.orders.clear()
            screen.topics.clear()
            screen.cursor = None
            screen.wake.clear()
        news: dict[str, Any] = {"orders": orders, "topics": topics}
        if len(orders) > MANY:
            news = {"orders": [], "topics": topics, "everything": True}
        if cursor is not None:
            news["cursor"] = cursor
        return news

    # Watching the log -------------------------------------------------------------------------------------

    def _watch(self, since: int) -> None:
        """Starts the watcher if it is not running (called on the server's loop, by the first screen)."""
        if self._log is None or (self._watcher is not None and not self._watcher.done()):
            return
        self._loop = asyncio.get_running_loop()
        self._poked = asyncio.Event()
        self._watcher = self._loop.create_task(self._watching(since, self._poked))

    async def _watching(self, seen: int, poked: asyncio.Event) -> None:
        try:
            while self.screens:
                poked.clear()  # before the look: a poke that lands during it makes the next look immediate
                try:
                    seen = await asyncio.to_thread(self._look, seen)
                except Exception:  # the database is away: the streams' heartbeat goes on, the next look retries
                    log.exception("change feed: could not read the log")
                try:
                    await asyncio.wait_for(poked.wait(), self.every)
                except TimeoutError:
                    pass
        finally:
            if self._poked is poked:
                self._loop = self._poked = None

    def _look(self, seen: int) -> int:
        """Tells what arrived after `seen` and returns how far it got. Runs on a thread: it asks the database."""
        source = self._log
        if source is None:
            return seen
        if self._also is not None:
            try:
                self._also()
            except Exception:
                log.exception("change feed: the menu check failed")
        while True:
            rows = source.arrivals(seen, 2000)
            if not rows:
                return seen
            seen = rows[-1][0]
            self.orders_changed(dict.fromkeys(order_id for _, order_id in rows), seen)
            if len(rows) < 2000:
                return seen


def end_on_stop(feed: ChangeFeed) -> Callable[[], None]:
    """Ends the feed's streams when the server is told to stop. Call it on the server's loop once the server
    has its own signal handlers (the API's lifespan does); what it returns undoes it.

    uvicorn, asked to stop, closes idle connections and then waits for the requests in flight. A stream is
    always in flight, so without this the hub would stand there until it is killed (docker waits ten seconds),
    with every screen still attached to a hub that takes no more requests. The handler only passes the word
    to the loop (the one thing a signal handler may do to it) and then calls the server's own. A server that
    set no handler of its own is left alone: there, the signal's default already ends the process."""
    loop = asyncio.get_running_loop()
    hooked: list[tuple[int, Any, Any]] = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        previous = signal.getsignal(sig)
        if not callable(previous):
            continue

        def stop(signum: int, frame: Any, previous: Any = previous) -> None:
            try:
                loop.call_soon_threadsafe(feed.close)
            except RuntimeError:  # the loop is gone already
                pass
            previous(signum, frame)

        try:
            signal.signal(sig, stop)
        except ValueError:  # not the main thread (a test client's): no signals arrive here
            continue
        hooked.append((sig, stop, previous))

    def undo() -> None:
        for sig, mine, previous in hooked:
            if signal.getsignal(sig) is mine:
                signal.signal(sig, previous)

    return undo
