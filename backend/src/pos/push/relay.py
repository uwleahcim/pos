"""What turns the PBX's events into pushes, and the marks on the PBX that make its dial wait.

A locked iPhone has no SIP registration: its app is suspended, so the PBX's dial to that extension fails at
once and the call passes it by. The relay wakes it the moment the PBX starts ringing the extension (a
`DialBegin` to the phone, or to the Local channel a ring group rings it through) with a VoIP push, which iOS
delivers to a locked phone and the app hands to CallKit; the phone registers in a few seconds and the next
dial reaches it. For that next dial to come soon, the PBX's pre-dial hook (docs/push-relay.md) holds a dial to
an extension marked `POSPUSH/<ext>` in the PBX's database for up to eight seconds while the phone registers,
and says so with a `UserEvent: PosPush`, which the relay takes as a ring too. The hub keeps those marks: one
per extension some screen has registered a VoIP token for, rewritten on every connection and every change.

A desk-phone pick-up for a linked screen goes out as a notification (an alert push) to that screen's tokens,
so a locked iPad lights up with the caller and opens the order when tapped.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections.abc import Callable, Coroutine
from typing import Any

from ..phones.ami import AMIClient, AMIError, Message
from ..phones.deskphones import CallTracker, extension_of
from .apns import ApnsSender, SendResult
from .devices import PushDevice, PushDevices

log = logging.getLogger("pos.push")

_LOCAL = re.compile(r"^Local/([^@/]+)@")
FAMILY = "POSPUSH"


def rung_extension(channel: str) -> str | None:
    """The extension a dial is for: the phone itself (`PJSIP/200-00000067`) or the Local channel a ring group,
    a queue or follow-me rings it through (`Local/200@from-internal-00000040;1`)."""
    found = _LOCAL.match(channel or "")
    return found.group(1) if found else extension_of(channel)


def pretty_number(number: str) -> str:
    """`+16175551234` as a notification shows it: `(617) 555-1234`; anything else as it came."""
    digits = re.sub(r"\D", "", number or "")
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    if len(digits) == 10:
        return f"({digits[:3]}) {digits[3:6]}-{digits[6:]}"
    return number or ""


def _explain(err: BaseException) -> str:
    text = str(err) or type(err).__name__
    if "permission" in text.lower():
        return f"{text}: the AMI user needs the write right `system` to mark extensions on the PBX"
    return text


def _numeric(extension: str) -> tuple[int, str]:
    return (int(extension), "") if extension.isdigit() else (1 << 31, extension)


class PushRelay:
    """Fed every manager event by the watcher; pushes go out on the watcher's loop, never in its way."""

    def __init__(
        self,
        devices: PushDevices,
        sender: ApnsSender | None,
        *,
        clock: Callable[[], float] = time.time,
        again: float = 45.0,
    ) -> None:
        self.devices, self.sender, self._clock, self._again = devices, sender, clock, again
        self._recent: dict[tuple[str, str], float] = {}  # (linkedid, extension): when it was last pushed for
        self._client: AMIClient | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._marks: list[str] = []
        self._marks_error: str | None = None
        self._marked_ms: int | None = None
        self._hook_seen_ms: int | None = None
        self._pushes = {"ring": 0, "pop": 0, "test": 0}
        self._tasks: set[asyncio.Task[Any]] = set()

    @property
    def configured(self) -> bool:
        """Whether the hub has an Apple key to push with (`hubctl push apple`)."""
        return self.sender is not None

    @property
    def marks(self) -> list[str]:
        """The extensions marked on the PBX at the last sync."""
        return list(self._marks)

    def status(self) -> dict[str, Any]:
        apple = self.sender.status() if self.sender is not None else {"configured": False}
        return {
            **apple,
            "devices": self.devices.counts(),
            "pushes": dict(self._pushes),
            "pbx": self._client is not None,
            "marks": list(self._marks),
            "marks_error": self._marks_error,
            "marked_at": self._marked_ms,
            "hook_seen": self._hook_seen_ms,
        }

    async def close(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        if self.sender is not None:
            await self.sender.close()

    async def drain(self) -> None:
        """Waits for every push on its way (tests)."""
        while self._tasks:
            await asyncio.gather(*list(self._tasks), return_exceptions=True)

    # --- the PBX side: the marks that make its dial wait ----------------------------------------------------------

    async def connected(self, client: AMIClient) -> None:
        """The watcher logged in: the marks are rewritten from the tokens registered now."""
        self._client, self._loop = client, asyncio.get_running_loop()
        await self.sync_marks()

    def disconnected(self) -> None:
        self._client = None

    async def sync_marks(self) -> None:
        """Rewrites `POSPUSH/<ext>` on the PBX: one entry per extension some screen can be woken for. Nothing
        raises; the status says what went wrong (an AMI user without the write right `system`, as a rule)."""
        client = self._client
        if client is None:
            return
        wanted = sorted(self.devices.extensions("voip"), key=_numeric)
        try:
            try:
                await client.send("DBDelTree", Family=FAMILY)
            except AMIError as err:
                if "not found" not in str(err).lower():  # an empty family is not an error worth a word
                    raise
            for extension in wanted:
                await client.send("DBPut", Family=FAMILY, Key=extension, Val="1")
        except (AMIError, ConnectionError, OSError, TimeoutError) as err:
            self._marks_error = _explain(err)
            log.warning("could not mark the push extensions on the PBX: %s", self._marks_error)
            return
        if wanted != self._marks or self._marks_error:
            log.info("marked on the PBX for push: %s", ", ".join(wanted) or "nothing")
        self._marks, self._marks_error, self._marked_ms = wanted, None, int(self._clock() * 1000)

    def marks_changed(self) -> None:
        """A token came or went: the PBX's marks follow, on the watcher's loop (callable from any thread)."""
        loop = self._loop
        if loop is None or loop.is_closed() or self._client is None:
            return
        loop.call_soon_threadsafe(self._spawn, self.sync_marks())

    # --- the events: a ring for an extension some screen registered, a pick-up for a linked screen -------------

    def feed(self, packet: Message, tracker: CallTracker) -> None:
        """A `DialBegin` to an extension (or to the Local channel it is rung through) and the hook's
        `UserEvent: PosPush` are rings; each (call, extension) is pushed for once per `again` seconds, since a
        ring group rings every member again every pass."""
        event = packet.get("Event", "")
        if event == "UserEvent":
            if packet.get("UserEvent") != "PosPush":
                return
            self._hook_seen_ms = int(self._clock() * 1000)
            extension = packet.get("Extension", "").strip() or None
        elif event == "DialBegin":
            extension = rung_extension(packet.get("DestChannel", ""))
        else:
            return
        linkedid = packet.get("Linkedid") or packet.get("Uniqueid", "")
        if extension and linkedid:
            self._ring(linkedid, extension, tracker)

    def _ring(self, linkedid: str, extension: str, tracker: CallTracker) -> None:
        now = self._clock()
        self._forget(now)
        if (linkedid, extension) in self._recent:
            return
        targets = self.devices.for_extension(extension, "voip")
        if not targets:
            return
        self._recent[(linkedid, extension)] = now
        call = tracker.state(linkedid)
        payload = {
            "kind": "ring",
            "call": linkedid,
            "extension": extension,
            "number": call.get("number", ""),
            "name": call.get("name", ""),
            "dialed": call.get("dialed", ""),
            "at": int(now * 1000),
        }
        self._pushes["ring"] += 1
        self._spawn(self._send_all(targets, payload, kind="voip", expiration=0, what=f"ring {extension} ({linkedid})"))

    def pop(self, pop: dict[str, Any]) -> None:
        """A desk phone linked to a screen picked up: that screen's notification, with the caller; the app
        opens the order from the hub when the notification is tapped, as it does when it is awake."""
        targets = self.devices.for_device(pop["device"], "alert")
        if not targets:
            return
        number, name = pop.get("number") or "", pop.get("name") or ""
        who = " · ".join(part for part in (pretty_number(number), name) if part) or "a call"
        payload = {
            "aps": {
                "alert": {"title": f"Phone {pop['extension']} picked up", "body": who},
                "sound": "default",
                "interruption-level": "time-sensitive",
                "thread-id": "desk-phone",
            },
            "kind": "pop",
            "call": pop["id"],
            "device": pop["device"],
            "extension": pop["extension"],
            "number": number,
            "name": name,
        }
        self._pushes["pop"] += 1
        self._spawn(
            self._send_all(
                targets,
                payload,
                kind="alert",
                expiration=int(self._clock()) + 60,
                collapse_id=pop["id"],
                what=f"pop for {pop['device']} ({pop['id']})",
            )
        )

    async def test(self, device: str, kind: str = "alert") -> dict[str, Any]:
        """A push to a screen by hand (`hubctl push test`, the app's Test button): a notification, or with
        `voip` a test call the phone shows and ends by itself."""
        targets = self.devices.for_device(device, kind)
        now_ms = int(self._clock() * 1000)
        if kind == "voip":
            payload: dict[str, Any] = {
                "kind": "test",
                "call": f"test-{now_ms}",
                "extension": targets[0].extension if targets else "",
                "number": "",
                "name": "POS test call",
                "at": now_ms,
            }
        else:
            payload = {
                "aps": {"alert": {"title": "POS push works", "body": f"The hub reaches {device}."}, "sound": "default"},
                "kind": "test",
                "device": device,
            }
        results = await self._send_all(
            targets,
            payload,
            kind=kind,
            expiration=int(self._clock()) + 60,
            collapse_id="test",
            what=f"test to {device}",
        )
        self._pushes["test"] += 1
        return {
            "device": device,
            "kind": kind,
            "configured": self.configured,
            "tokens": len(targets),
            "sent": sum(1 for r in results if r["ok"]),
            "results": results,
        }

    # --- sending ----------------------------------------------------------------------------------------------------

    async def _send_all(
        self,
        targets: list[PushDevice],
        payload: dict[str, Any],
        *,
        kind: str,
        expiration: int,
        collapse_id: str | None = None,
        what: str,
    ) -> list[dict[str, Any]]:
        sender = self.sender
        if sender is None:
            log.info("no Apple key on this hub: not pushing %s", what)
            return []
        results: list[dict[str, Any]] = []
        for target in targets:
            result = await sender.send(
                target.token, payload, kind=kind, env=target.env, collapse_id=collapse_id, expiration=expiration
            )
            self._settle(target, result)
            results.append(
                {
                    "device": target.device,
                    "platform": target.platform,
                    "kind": target.kind,
                    "ok": result.ok,
                    "env": result.env,
                    "reason": result.reason,
                }
            )
            if result.ok:
                log.info("pushed %s to %s (%s, %s)", what, target.device, target.platform, result.env)
            else:
                log.warning("push %s to %s failed: %s %s", what, target.device, result.status, result.reason)
        return results

    def _settle(self, target: PushDevice, result: SendResult) -> None:
        if result.ok and result.env and result.env != target.env:
            self.devices.set_env(target.token, result.env)
        elif result.gone:
            self.devices.remove(target.token)
            log.info("forgot %s's %s token: Apple says %s", target.device, target.kind, result.reason)
            self.marks_changed()

    def _spawn(self, coro: Coroutine[Any, Any, Any]) -> None:
        loop = asyncio.get_running_loop()
        task = loop.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _forget(self, now: float) -> None:
        for key, at in list(self._recent.items()):
            if now - at >= self._again or now < at:
                del self._recent[key]
