"""Desk phones linked to screens.

A call taken on a desk phone opens the caller's order on the screen linked to that phone, as if the screen had
taken the call itself: the caller's last order of the day, or a new phone order with the number. The hub
watches the PBX's manager interface (`AmiWatcher`) for the moment an extension answers an outside call
(`CallTracker`), looks the extension up in the `desk_phones` setting a manager keeps under Location settings
(extension to device name) and holds the answer for that device (`AnsweredCalls`); the app collects it with
`GET /phones/answered?device=` and does what it does when it picks up a call itself.

What counts as an answer: a `DialEnd` with `DialStatus: ANSWER` whose dialed channel is an extension's
(`PJSIP/200-...`, not a trunk's), on a call that came in on a trunk; the caller is read off the call's first
channel, before FreePBX rewrites the caller name. A ring group rings the desk phones through a Local channel
each, so the dial that ends in ANSWER on the phone itself is the one that counts, once per call and phone. A
call transferred to another linked phone is an answer there too. Calls between extensions, calls out and
follow-me to a cell are not answers. A call that rang before the watcher connected still counts when the
caller's number is an outside one.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import socket
import ssl
import sys
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, field
from typing import TYPE_CHECKING, Any, TextIO

from .ami import TRUNK_CONTEXTS, AMIClient, AMIError, Message, digits

if TYPE_CHECKING:
    from ..push.relay import PushRelay

log = logging.getLogger("pos.phones")

_ENDPOINT = re.compile(r"^(?:PJSIP|SIP)/(.+)-[0-9A-Fa-f]{8}$")


def extension_of(channel: str) -> str | None:
    """The endpoint a channel belongs to: `PJSIP/200-00000067` is extension 200. A Local channel or anything
    else is nobody's phone."""
    found = _ENDPOINT.match(channel or "")
    return found.group(1) if found else None


@dataclass(frozen=True)
class Answered:
    """An outside call picked up on an extension: who called, what they dialed, and when."""

    linkedid: str
    extension: str
    number: str
    name: str
    dialed: str
    at_ms: int


#: A trunk's words for no caller name: Asterisk's `<unknown>` (Twilio sends none) and the carriers' own.
NO_NAME = frozenset({"unknown", "anonymous", "unavailable", "restricted", "private", "withheld"})


def caller_name(raw: str) -> str:
    """The caller's name as the trunk gave it, or "" when the trunk only said it had none."""
    name = raw.strip()
    return "" if name.strip("<>").strip().lower() in NO_NAME else name


@dataclass
class _Call:
    number: str
    name: str
    dialed: str
    seen: float
    answered: set[str] = field(default_factory=set)


class CallTracker:
    """Turns the stream of manager events into answers. Calls are followed by their `Linkedid`, which every
    channel of a call shares; the first channel of an outside call arrives on a trunk context and carries the
    caller as the trunk sent them."""

    def __init__(
        self,
        *,
        contexts: frozenset[str] = TRUNK_CONTEXTS,
        clock: Callable[[], float] = time.time,
        keep: float = 4 * 3600,
    ) -> None:
        self._contexts, self._clock, self._keep = contexts, clock, keep
        self._calls: dict[str, _Call] = {}
        self._ended: dict[str, float] = {}  # linkedid: when the call's first channel hung up
        self._pruned = clock()

    @property
    def open(self) -> int:
        """Calls being followed."""
        return len(self._calls)

    def feed(self, packet: Message) -> Answered | None:
        now = self._clock()
        self._prune(now)
        event = packet.get("Event", "")
        linkedid = packet.get("Linkedid") or packet.get("Uniqueid", "")
        if event == "Newchannel":
            if packet.get("Context", "") in self._contexts and linkedid not in self._calls:
                self._calls[linkedid] = _Call(
                    packet.get("CallerIDNum", ""),
                    caller_name(packet.get("CallerIDName", "")),
                    packet.get("Exten", ""),
                    now,
                )
            return None
        if event == "Hangup":
            if packet.get("Uniqueid", "") == linkedid:  # the call's first channel: the trunk's
                self._calls.pop(linkedid, None)
                self._ended[linkedid] = now
            return None
        if event != "DialEnd" or packet.get("DialStatus") != "ANSWER":
            return None
        if packet.get("DestContext", "") in self._contexts:
            return None  # a trunk answered: a call out, or follow-me ringing a cell
        extension = extension_of(packet.get("DestChannel", ""))
        if extension is None:
            return None
        call = self._calls.get(linkedid)
        if call is None:
            # the call started before the watcher listened: an outside number still counts, an extension's does not
            number = packet.get("CallerIDNum", "")
            if len(digits(number)) < 7:
                return None
            call = self._calls[linkedid] = _Call(number, caller_name(packet.get("CallerIDName", "")), "", now)
        if extension in call.answered:
            return None
        call.answered.add(extension)
        return Answered(linkedid, extension, call.number, call.name, call.dialed, int(now * 1000))

    def state(self, linkedid: str) -> dict[str, Any]:
        """Where a call stands, for a screen woken for it: `ringing` (up, no extension has answered),
        `answered` (with the extensions that did; a transfer adds one), `ended` (the caller's channel hung
        up in the last ten minutes) or `unknown` (never seen, or long gone)."""
        call = self._calls.get(linkedid)
        if call is None:
            state = "ended" if linkedid in self._ended else "unknown"
            return {"call": linkedid, "state": state, "answered": [], "number": "", "name": "", "dialed": ""}
        return {
            "call": linkedid,
            "state": "answered" if call.answered else "ringing",
            "answered": sorted(call.answered),
            "number": call.number,
            "name": call.name,
            "dialed": call.dialed,
        }

    def _prune(self, now: float) -> None:
        if now - self._pruned < 60 and now >= self._pruned:
            return
        self._pruned = now
        for linkedid, call in list(self._calls.items()):
            if now - call.seen > self._keep:
                del self._calls[linkedid]
        for linkedid, at in list(self._ended.items()):
            if now - at > 600:
                del self._ended[linkedid]


class AnsweredCalls:
    """The answers on linked desk phones, kept for two minutes for their screens to collect. `links` reads the
    manager's extension-to-device links when a phone answers, so a change takes the next call. A screen asks
    with `wait` and is answered the moment one of its phones picks up: each answer kept has a `seq`, the
    hub's `cursor` is the last one given out, and a request waits for an answer newer than the cursor it
    brings back."""

    def __init__(
        self, links: Callable[[], Mapping[str, str]], *, keep: float = 120.0, clock: Callable[[], float] = time.time
    ) -> None:
        self._links, self._keep, self._clock = links, keep, clock
        self._calls: deque[dict[str, Any]] = deque()
        self._lock = threading.Lock()
        self._answers = 0
        self._pops = 0
        self._links_version = 0
        self._waiters: set[asyncio.Future[None]] = set()

    @property
    def counts(self) -> dict[str, int]:
        """Answers seen on any extension, how many reached a linked screen, and how many screens are waiting
        for the next one right now."""
        with self._lock:
            return {"answers": self._answers, "pops": self._pops, "waiting": len(self._waiters)}

    @property
    def cursor(self) -> int:
        """The `seq` of the last answer kept for a screen; a screen brings it back as `after`."""
        return self._pops

    def linked(self, device: str) -> bool:
        """Whether any desk phone is linked to this device (names compared regardless of case)."""
        wanted = device.casefold()
        return any(name.casefold() == wanted for name in self._links().values())

    def record(self, answered: Answered) -> dict[str, Any] | None:
        """Keeps the answer for the linked device; None when no device is linked to that extension."""
        device = self._links().get(answered.extension)
        with self._lock:
            self._answers += 1
            if device is None:
                return None
            self._pops += 1
            pop = {
                "id": f"{answered.linkedid}:{answered.extension}",
                "device": device,
                "extension": answered.extension,
                "number": answered.number,
                "name": answered.name,
                "dialed": answered.dialed,
                "at": answered.at_ms,
                "seq": self._pops,
            }
            self._calls.append(pop)
            self._prune(self._clock())
        self._wake()
        return pop

    def links_changed(self) -> None:
        """A manager changed the links: every waiting screen is answered now, with `linked` as it stands."""
        self._links_version += 1
        self._wake()

    async def wait(self, device: str, *, after: int, timeout: float) -> list[dict[str, Any]]:
        """`for_device`, the moment it holds a call newer than `after` (the `cursor` the screen was last given,
        0 at first) or the links change; otherwise when `timeout` seconds are up, with what there is. A cursor
        beyond this hub's (from its other hub, or from before a restart) is answered at once, so the screen
        learns the right one."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        version = self._links_version
        while True:
            woken = loop.create_future()  # registered before looking, so a pick-up in between still wakes it
            with self._lock:
                self._waiters.add(woken)
            try:
                calls = self.for_device(device)
                if after > self._pops or version != self._links_version or any(c["seq"] > after for c in calls):
                    return calls
                left = deadline - loop.time()
                if left <= 0:
                    return calls
                await asyncio.wait_for(woken, left)
            except TimeoutError:
                return self.for_device(device)
            finally:
                with self._lock:
                    self._waiters.discard(woken)

    def _wake(self) -> None:
        with self._lock:
            waiters, self._waiters = self._waiters, set()
        for woken in waiters:  # each on its own loop, maybe; the watcher records on the API's, a tool on none
            woken.get_loop().call_soon_threadsafe(_resolve, woken)

    def for_device(self, device: str) -> list[dict[str, Any]]:
        """The calls answered for this device in the last two minutes, oldest first, each with its age on
        the hub's clock (so a screen whose clock drifts still judges it right)."""
        now = self._clock()
        wanted = device.casefold()
        with self._lock:
            self._prune(now)
            return [
                {**{k: v for k, v in pop.items() if k != "device"}, "age_ms": max(0, int(now * 1000) - pop["at"])}
                for pop in self._calls
                if pop["device"].casefold() == wanted
            ]

    def _prune(self, now: float) -> None:
        cutoff = int((now - self._keep) * 1000)
        while self._calls and self._calls[0]["at"] < cutoff:
            self._calls.popleft()


#: An endpoint's device state (`PJSIPShowEndpoints`) or a peer's status (`SIPpeers`) when no phone is on it.
_OFFLINE = frozenset({"unavailable", "invalid", "unknown", "unreachable"})


async def extensions(client: AMIClient) -> list[dict[str, Any]]:
    """The PBX's extensions, lowest first: its PJSIP (or SIP) endpoints with a number for a name (a trunk's name
    is a word), each with whether a phone is registered on it right now."""
    try:
        _, rows = await client.send("PJSIPShowEndpoints")
        found = [(r.get("ObjectName", ""), r.get("DeviceState", "")) for r in rows if r.get("Event") == "EndpointList"]
    except AMIError:  # a chan_sip system
        _, rows = await client.send("SIPpeers")
        found = [(r.get("ObjectName", ""), r.get("Status", "")) for r in rows if r.get("Event") == "PeerEntry"]
    numbered = sorted(((name, state) for name, state in found if name.isdigit()), key=lambda item: int(item[0]))
    return [{"extension": name, "online": state.split(" ")[0].lower() not in _OFFLINE} for name, state in numbered]


def _resolve(future: asyncio.Future[None]) -> None:
    if not future.done():
        future.set_result(None)


def _describe(err: BaseException, host: str) -> str:
    """The error as the status shows it. The hub reaches the PBX through the tunnel service, by name, so a name
    that does not resolve is that service being down, as a rule, which is worth saying in those words."""
    if isinstance(err, socket.gaierror):
        return f"{host} does not resolve ({err.strerror or err}): the tunnel service is probably down"
    return str(err) or type(err).__name__


class AmiWatcher:
    """One connection to the PBX's manager interface for as long as the API runs: logs in for call events,
    feeds them to the tracker, records the answers, and reconnects with a growing pause after any drop. With a
    push `relay`, the hook's user events are asked for too, every event reaches the relay, and so does every
    pick-up kept for a screen (docs/push-relay.md)."""

    def __init__(
        self,
        host: str,
        port: int,
        user: str,
        secret: str,
        calls: AnsweredCalls,
        *,
        tls: bool = False,
        tracker: CallTracker | None = None,
        relay: PushRelay | None = None,
        backoff: tuple[float, float] = (1.0, 10.0),
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.host, self.port, self.user, self.tls = host, port, user, tls
        self._secret, self._calls, self._backoff, self._clock = secret, calls, backoff, clock
        self._tracker = tracker if tracker is not None else CallTracker(clock=clock)
        self.relay = relay
        self.on_call_end: Callable[[str], None] | None = None
        """Told the id of every call whose first channel hung up: the call is over (its recording is on the
        PBX in a moment; `pos.phones.recordings`)."""
        self._task: asyncio.Task[None] | None = None
        self._client: AMIClient | None = None
        self._since: float | None = None
        self._last_error: str | None = None
        self._attempts = 0
        self._connections = 0
        self._events = 0

    def start(self) -> None:
        """Runs the watcher on the current event loop until `stop`."""
        if self._task is None:
            self._task = asyncio.get_running_loop().create_task(self.run(), name="pbx-watcher")

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is None:
            return
        task.cancel()
        try:
            await asyncio.wait_for(task, 15)
        except (asyncio.CancelledError, TimeoutError):
            pass
        self._client = None
        self._since = None

    def _ended(self, packet: Message) -> None:
        """Tells `on_call_end` of a call whose first channel hung up; what it does with that never stops the
        watching."""
        if self.on_call_end is None or packet.get("Event", "") != "Hangup":
            return
        call = packet.get("Uniqueid", "")
        if not call or call != (packet.get("Linkedid") or call):
            return
        try:
            self.on_call_end(call)
        except Exception as err:  # noqa: BLE001
            log.warning("a call's end could not be passed on (%s)", type(err).__name__)

    @property
    def tracker(self) -> CallTracker:
        """The calls followed on this connection (`state` answers a woken screen's question)."""
        return self._tracker

    def status(self) -> dict[str, Any]:
        return {
            "configured": True,
            "host": self.host,
            "port": self.port,
            "tls": self.tls,
            "connected": self._since is not None,
            "since": None if self._since is None else int(self._since * 1000),
            "attempts": self._attempts,
            "connections": self._connections,
            "events": self._events,
            "last_error": self._last_error,
        }

    async def extensions(self) -> list[dict[str, Any]]:
        """The PBX's extensions (see `extensions`) while connected; none when not, or when the PBX does not
        answer in time."""
        client = self._client
        if client is None:
            return []
        try:
            return await extensions(client)
        except (AMIError, ConnectionError, OSError, TimeoutError) as err:
            log.warning("PBX %s:%s did not list its extensions: %s", self.host, self.port, err)
            return []

    async def run(self) -> None:
        delay = self._backoff[0]
        while True:
            self._attempts += 1
            try:
                async with AMIClient(self.host, self.port, tls=self.tls, timeout=5.0) as client:
                    await client.login(self.user, self._secret, events="call,user" if self.relay else "call")
                    self._client = client
                    self._connections += 1
                    self._since = self._clock()
                    delay = self._backoff[0]
                    log.info("PBX link up: %s:%s as %s", self.host, self.port, self.user)
                    if self.relay is not None:
                        await self.relay.connected(client)
                    async for packet in client.events():
                        self._events += 1
                        if self.relay is not None:
                            self.relay.feed(packet, self._tracker)
                        answered = self._tracker.feed(packet)
                        self._ended(packet)
                        if answered is not None:
                            pop = self._calls.record(answered)
                            log.info(
                                "%s answered %s%s",
                                answered.extension,
                                answered.number,
                                f" for {pop['device']}" if pop else "",
                            )
                            if pop is not None and self.relay is not None:
                                self.relay.pop(pop)
                    raise ConnectionError("AMI connection closed")
            except asyncio.CancelledError:
                self._client = None
                self._since = None
                if self.relay is not None:
                    self.relay.disconnected()
                raise
            except (AMIError, ConnectionError, OSError, TimeoutError, ssl.SSLError) as err:
                self._client = None
                self._since = None
                if self.relay is not None:
                    self.relay.disconnected()
                self._last_error = _describe(err, self.host)
                log.warning("PBX link %s:%s: %s; trying again in %.0f s", self.host, self.port, self._last_error, delay)
                await asyncio.sleep(delay)
                delay = min(delay * 2, self._backoff[1])


def watcher_from_env(calls: AnsweredCalls, relay: PushRelay | None = None) -> AmiWatcher | None:
    """The watcher for the PBX named by `POS_AMI_HOST` (with `POS_AMI_PORT`, `POS_AMI_USER`, `POS_AMI_SECRET`
    and `POS_AMI_TLS`); None when no PBX is configured, as on a laptop."""
    host = os.environ.get("POS_AMI_HOST", "").strip()
    if not host:
        return None
    tls = os.environ.get("POS_AMI_TLS", "").strip().lower() in ("1", "true", "yes")
    port = int(os.environ.get("POS_AMI_PORT") or (5039 if tls else 5038))
    return AmiWatcher(
        host,
        port,
        os.environ.get("POS_AMI_USER") or "pos",
        os.environ.get("POS_AMI_SECRET", ""),
        calls,
        tls=tls,
        relay=relay,
    )


# --- command line: watch the answers on a live PBX -------------------------------------------------------------


async def watch(
    client: AMIClient, *, count: int | None = None, seconds: float | None = None, out: TextIO = sys.stdout
) -> int:
    """Print each outside call as an extension answers it, one JSON line each, as the hub would see it."""
    tracker = CallTracker()
    seen = 0

    async def run() -> None:
        nonlocal seen
        async for packet in client.events():
            answered = tracker.feed(packet)
            if answered is None:
                continue
            seen += 1
            print(json.dumps(asdict(answered)), file=out, flush=True)
            if count is not None and seen >= count:
                return

    try:
        await asyncio.wait_for(run(), seconds)
    except TimeoutError:
        pass
    return seen


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m pos.phones.deskphones",
        description="Print each outside call as an extension answers it, as the hub sees it (Ctrl-C to stop).",
    )
    parser.add_argument("--host", required=True, help="the PBX, or `pbx` for the hub's tunnel")
    parser.add_argument("--port", type=int, default=5038)
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--user", default="pos")
    parser.add_argument("--secret-env", default="AMI_SECRET", help="environment variable holding the secret")
    parser.add_argument("--count", type=int, help="stop after this many answers")
    parser.add_argument("--seconds", type=float, help="stop after this many seconds")
    args = parser.parse_args(argv)
    secret = os.environ.get(args.secret_env, "")
    if not secret:
        print(f"set {args.secret_env} to the AMI user's secret", file=sys.stderr)
        return 2

    async def run() -> int:
        async with AMIClient(args.host, args.port, tls=args.tls) as client:
            await client.login(args.user, secret, events="call")
            print(f"watching {args.host}:{args.port} as {args.user}", file=sys.stderr)
            return await watch(client, count=args.count, seconds=args.seconds)

    try:
        asyncio.run(run())
    except (AMIError, ConnectionError, OSError, TimeoutError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
