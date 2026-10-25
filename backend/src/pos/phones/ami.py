"""Minimal Asterisk Manager Interface (AMI) client and probe for the FreePBX connector.

The architecture needs three things from the PBX: call events carrying the caller and the dialed number
(the caller pop-up and the location detection), queue pause and unpause for the shared call pool, and
Originate for click-to-call. This is the smallest client that does those, plus a probe that proves an AMI
user and a network path work before any connector code is written.

    AMI_SECRET=... python -m pos.phones.ami --host freepbx.example.org --user pos probe
    AMI_SECRET=... python -m pos.phones.ami --host freepbx.example.org --user pos tail --location 5551230001=Downtown

The secret comes from an environment variable so it never lands in a shell history or a process list.
This file stands alone (standard library only, Python 3.11 or newer) so it can be copied to the PBX host and run there.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import itertools
import json
import os
import re
import ssl
import sys
from collections.abc import AsyncIterator, Mapping
from dataclasses import asdict, dataclass, field
from typing import TextIO

Message = dict[str, str]

# Contexts FreePBX gives to calls arriving on a trunk; Exten on those channels is the dialed number (DID).
TRUNK_CONTEXTS = frozenset({"from-trunk", "from-pstn", "from-did-direct", "from-trunk-sip", "from-sip-external"})
_NOT_DIGITS = re.compile(r"\D+")


class AMIError(Exception):
    """The PBX answered an action with Response: Error."""


async def read_packet(reader: asyncio.StreamReader) -> Message:
    """One AMI packet: `Key: Value` lines up to a blank line. Raises ConnectionError at end of stream."""
    packet: Message = {}
    while True:
        raw = await reader.readline()
        if not raw:
            raise ConnectionError("AMI connection closed")
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            if packet:
                return packet
            continue
        key, sep, value = line.partition(":")
        if sep and " " not in key:
            packet[key] = value.strip()
        else:  # free text, as in the output of the Command action
            packet["Output"] = packet.get("Output", "") + line + "\n"


def encode_packet(fields: Mapping[str, str]) -> bytes:
    return ("".join(f"{key}: {value}\r\n" for key, value in fields.items()) + "\r\n").encode()


@dataclass
class _Pending:
    future: asyncio.Future
    response: Message | None = None
    events: list[Message] = field(default_factory=list)


class AMIClient:
    """One AMI connection: actions with their responses (list actions included) and a stream of events."""

    def __init__(
        self, host: str, port: int = 5038, *, tls: bool = False, verify: bool = True, timeout: float = 10.0
    ) -> None:
        self.host, self.port, self.tls, self.verify, self.timeout = host, port, tls, verify, timeout
        self.banner = ""
        self._ids = itertools.count(1)
        self._pending: dict[str, _Pending] = {}
        self._events: asyncio.Queue[Message | None] = asyncio.Queue()
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._pump_task: asyncio.Task | None = None

    async def __aenter__(self) -> AMIClient:
        await self.connect()
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    async def connect(self) -> str:
        context = None
        if self.tls:
            context = ssl.create_default_context()
            if not self.verify:
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
        self._reader, self._writer = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port, ssl=context), self.timeout
        )
        raw = await asyncio.wait_for(self._reader.readline(), self.timeout)
        self.banner = raw.decode("utf-8", errors="replace").strip()
        self._pump_task = asyncio.create_task(self._pump())
        return self.banner

    async def close(self) -> None:
        if self._writer is None:
            return
        try:
            await self.send("Logoff")
        except (AMIError, ConnectionError, TimeoutError):
            pass
        if self._pump_task is not None:
            self._pump_task.cancel()
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (OSError, ssl.SSLError):
            pass
        self._writer = None

    async def login(self, username: str, secret: str, events: str = "off") -> Message:
        """Challenge-response login so the secret never crosses the wire in clear; TLS is still the real lock."""
        try:
            challenge, _ = await self.send("Challenge", AuthType="MD5")
        except AMIError:  # a PBX that refuses Challenge gets a plain login
            response, _ = await self.send("Login", Username=username, Secret=secret, Events=events)
            return response
        key = hashlib.md5((challenge["Challenge"] + secret).encode(), usedforsecurity=False).hexdigest()
        response, _ = await self.send("Login", AuthType="MD5", Username=username, Key=key, Events=events)
        return response

    async def send(self, action: str, **fields: str) -> tuple[Message, list[Message]]:
        """Send an action and wait for its response; a list action also returns its events."""
        if self._writer is None:
            raise ConnectionError("not connected")
        action_id = str(next(self._ids))
        pending = _Pending(asyncio.get_running_loop().create_future())
        self._pending[action_id] = pending
        self._writer.write(encode_packet({"Action": action, "ActionID": action_id, **fields}))
        await self._writer.drain()
        try:
            return await asyncio.wait_for(pending.future, self.timeout)
        finally:
            self._pending.pop(action_id, None)

    async def events(self) -> AsyncIterator[Message]:
        """Unsolicited events, until the connection closes."""
        while (packet := await self._events.get()) is not None:
            yield packet

    async def _pump(self) -> None:
        assert self._reader is not None
        try:
            while True:
                packet = await read_packet(self._reader)
                pending = self._pending.get(packet.get("ActionID", ""))
                if pending is None:
                    if "Event" in packet:
                        await self._events.put(packet)
                    continue
                self._settle(pending, packet)
        except (ConnectionError, OSError, asyncio.CancelledError) as err:
            for pending in self._pending.values():
                if not pending.future.done():
                    pending.future.set_exception(ConnectionError(str(err) or "connection closed"))
            await self._events.put(None)
            if isinstance(err, asyncio.CancelledError):
                raise

    @staticmethod
    def _settle(pending: _Pending, packet: Message) -> None:
        if pending.future.done():
            return
        if pending.response is None:
            pending.response = packet
            if packet.get("Response") == "Error":
                pending.future.set_exception(AMIError(packet.get("Message", "AMI error")))
            elif packet.get("EventList", "").lower() != "start":
                pending.future.set_result((packet, []))
            return
        pending.events.append(packet)
        if packet.get("EventList", "").lower() == "complete":
            pending.future.set_result((pending.response, pending.events))


# --- what the POS makes of the events ---------------------------------------------------------------


def digits(number: str) -> str:
    return _NOT_DIGITS.sub("", number or "")


def location_for(dialed: str, locations: Mapping[str, str]) -> str | None:
    """The location whose number was dialed, matched on the last ten digits so 1-555... and 555... agree."""
    wanted = digits(dialed)[-10:]
    if not wanted:
        return None
    return next((name for number, name in locations.items() if digits(number)[-10:] == wanted), None)


@dataclass(frozen=True)
class CallSeen:
    event: str
    uniqueid: str
    channel: str
    caller: str
    caller_name: str
    dialed: str
    context: str
    queue: str
    location: str | None


def call_from_event(packet: Message, locations: Mapping[str, str] | None = None) -> CallSeen | None:
    """An incoming call as the POS sees it: Newchannel on a trunk context carries the caller and the dialed
    number; QueueCallerJoin says which queue it landed in. Anything else is not a call for us."""
    event = packet.get("Event", "")
    context = packet.get("Context", "")
    if event == "Newchannel" and context not in TRUNK_CONTEXTS:
        return None
    if event not in ("Newchannel", "QueueCallerJoin"):
        return None
    dialed = packet.get("Exten", "") if event == "Newchannel" else ""
    return CallSeen(
        event,
        packet.get("Uniqueid", ""),
        packet.get("Channel", ""),
        packet.get("CallerIDNum", ""),
        packet.get("CallerIDName", ""),
        dialed,
        context,
        packet.get("Queue", ""),
        location_for(dialed, locations or {}),
    )


# --- the three primitives and the probe -----------------------------------------------------------


async def probe(client: AMIClient) -> dict:
    """Inventory of a logged-in PBX: version, queues, endpoints and live channels."""
    out: dict = {"banner": client.banner}
    settings, _ = await client.send("CoreSettings")
    out["asterisk"] = settings.get("AsteriskVersion", "")
    out["system"] = settings.get("SystemName", "")
    _, queues = await client.send("QueueSummary")
    out["queues"] = [
        {key.lower(): row.get(key, "") for key in ("Queue", "LoggedIn", "Available", "Callers", "HoldTime")}
        for row in queues
        if row.get("Event") == "QueueSummary"
    ]
    try:
        _, items = await client.send("PJSIPShowEndpoints")
        endpoints = [
            {"name": e.get("ObjectName", ""), "state": e.get("DeviceState", "")}
            for e in items
            if e.get("Event") == "EndpointList"
        ]
    except AMIError:  # a chan_sip system
        _, items = await client.send("SIPpeers")
        endpoints = [
            {"name": e.get("ObjectName", ""), "state": e.get("Status", "")}
            for e in items
            if e.get("Event") == "PeerEntry"
        ]
    out["endpoints"] = endpoints
    _, channels = await client.send("CoreShowChannels")
    out["channels"] = sum(1 for c in channels if c.get("Event") == "CoreShowChannel")
    return out


async def set_paused(client: AMIClient, interface: str, paused: bool, queue: str = "", reason: str = "POS") -> Message:
    """Pause or unpause an agent (FreePBX dynamic agents look like Local/201@from-queue/n)."""
    fields = {"Interface": interface, "Paused": "true" if paused else "false", "Reason": reason}
    if queue:
        fields["Queue"] = queue
    response, _ = await client.send("QueuePause", **fields)
    return response


async def originate(
    client: AMIClient,
    channel: str,
    number: str,
    context: str = "from-internal",
    callerid: str = "",
    timeout_ms: int = 30000,
) -> Message:
    """Click-to-call: ring the agent's channel, then dial the number through the PBX's own routes."""
    fields = {
        "Channel": channel,
        "Exten": number,
        "Context": context,
        "Priority": "1",
        "Timeout": str(timeout_ms),
        "Async": "true",
    }
    if callerid:
        fields["CallerID"] = callerid
    response, _ = await client.send("Originate", **fields)
    return response


async def tail(
    client: AMIClient,
    locations: Mapping[str, str],
    *,
    count: int | None = None,
    seconds: float | None = None,
    out: TextIO = sys.stdout,
) -> int:
    """Print incoming calls as they arrive, one JSON line each with the detected location."""
    seen = 0

    async def run() -> None:
        nonlocal seen
        async for packet in client.events():
            call = call_from_event(packet, locations)
            if call is None:
                continue
            seen += 1
            print(json.dumps(asdict(call)), file=out, flush=True)
            if count is not None and seen >= count:
                return

    try:
        await asyncio.wait_for(run(), seconds)
    except TimeoutError:
        pass
    return seen


# --- command line ---------------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m pos.phones.ami", description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=5038, help="5038 plain, 5039 with --tls")
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--insecure", action="store_true", help="skip certificate verification (lab only)")
    parser.add_argument("--user", required=True, help="the AMI user from FreePBX > Settings > Asterisk Manager Users")
    parser.add_argument("--secret-env", default="AMI_SECRET", help="environment variable holding the secret")
    parser.add_argument("--timeout", type=float, default=10.0)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe", help="log in and list version, queues, endpoints and live channels")
    tail_cmd = sub.add_parser("tail", help="print incoming calls with the location detected from the dialed number")
    tail_cmd.add_argument("--location", action="append", default=[], metavar="NUMBER=NAME")
    tail_cmd.add_argument("--count", type=int, help="stop after this many calls")
    tail_cmd.add_argument("--seconds", type=float, help="stop after this many seconds")
    for name in ("pause", "unpause"):
        cmd = sub.add_parser(name, help=f"{name} an agent in the queues")
        cmd.add_argument("--interface", required=True, help="e.g. Local/201@from-queue/n or PJSIP/201")
        cmd.add_argument("--queue", default="", help="one queue only; default all")
        cmd.add_argument("--reason", default="POS")
    orig = sub.add_parser("originate", help="click-to-call from an extension")
    orig.add_argument("--channel", required=True, help="e.g. PJSIP/201")
    orig.add_argument("--number", required=True)
    orig.add_argument("--context", default="from-internal")
    orig.add_argument("--callerid", default="")
    return parser


async def run(args: argparse.Namespace) -> int:
    secret = os.environ.get(args.secret_env, "")
    if not secret:
        print(f"set {args.secret_env} to the AMI user's secret", file=sys.stderr)
        return 2
    client = AMIClient(args.host, args.port, tls=args.tls, verify=not args.insecure, timeout=args.timeout)
    async with client:
        await client.login(args.user, secret, events="call,agent" if args.command == "tail" else "off")
        if args.command == "probe":
            print(json.dumps(await probe(client), indent=2))
        elif args.command == "tail":
            locations = dict(item.split("=", 1) for item in args.location)
            await tail(client, locations, count=args.count, seconds=args.seconds)
        elif args.command in ("pause", "unpause"):
            response = await set_paused(client, args.interface, args.command == "pause", args.queue, args.reason)
            print(response.get("Message", response.get("Response", "")))
        elif args.command == "originate":
            response = await originate(client, args.channel, args.number, args.context, args.callerid)
            print(response.get("Message", response.get("Response", "")))
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return asyncio.run(run(args))
    except (AMIError, ConnectionError, OSError, TimeoutError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
