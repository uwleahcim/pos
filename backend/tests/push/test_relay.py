"""The push relay: a ring for a registered extension wakes its phone, a desk-phone pick-up lights its screen,
and the PBX's marks follow the registered extensions."""

from __future__ import annotations

import asyncio
import threading
import time
from typing import Any

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.phones.ami import AMIClient
from pos.phones.deskphones import AmiWatcher, AnsweredCalls, CallTracker
from pos.push.apns import SendResult
from pos.push.devices import PushDevice, PushDevices
from pos.push.relay import PushRelay, pretty_number, rung_extension
from pos.sync.oplog import OpStore
from tests.phones.fake_ami import FakePBX
from tests.phones.test_deskphones import CALLER, LINKED, TRUNK, newchannel, outside_call, ring_group_answer, until

NOW = 1_730_000_000.0
IPHONE_VOIP, IPHONE_ALERT, IPAD_ALERT = "aa" * 8, "bb" * 8, "cc" * 8


class FakeSender:
    """Takes every push and answers as told per token: (ok, status, reason, env)."""

    def __init__(self) -> None:
        self.sent: list[dict[str, Any]] = []
        self.answers: dict[str, tuple[bool, int, str | None, str | None]] = {}
        self.closed = False

    async def send(self, token, payload, *, kind, env=None, collapse_id=None, expiration=0) -> SendResult:
        self.sent.append(
            {
                "token": token,
                "payload": payload,
                "kind": kind,
                "env": env,
                "collapse_id": collapse_id,
                "expiration": expiration,
            }
        )
        ok, status, reason, answered = self.answers.get(token, (True, 200, None, env or "production"))
        return SendResult(ok, status, reason, answered)

    def status(self) -> dict[str, Any]:
        return {"configured": True, "bundle": "org.chinasky.posApp", "sent": len(self.sent)}

    async def close(self) -> None:
        self.closed = True


def registry() -> PushDevices:
    found = PushDevices(clock=lambda: NOW)
    found.put(PushDevice(IPHONE_VOIP, "iphone1", "ios", "voip", "302"))
    found.put(PushDevice(IPHONE_ALERT, "iphone1", "ios", "alert"))
    found.put(PushDevice(IPAD_ALERT, "ipad1", "ios", "alert"))
    return found


def dial_begin(channel: str, dest: str, linkedid: str = LINKED) -> dict[str, str]:
    return {"Event": "DialBegin", "Channel": channel, "DestChannel": dest, "Linkedid": linkedid, **CALLER}


def ring_group_pass(extensions: tuple[str, ...] = ("200", "302")) -> list[dict[str, str]]:
    """Ring group 600 dialing its members: a Local channel each, which then dials the phone itself."""
    events = []
    for n, ext in enumerate(extensions):
        local = f"Local/{ext}@from-internal-0000004{n}"
        events.append(dial_begin(TRUNK, f"{local};1"))
        events.append(dial_begin(f"{local};2", f"PJSIP/{ext}-0000006{n}"))
    return events


def run(test):
    return asyncio.run(test())


# --- which extension a dial rings -------------------------------------------------------------------------------


def test_the_extension_a_dial_is_for():
    assert rung_extension("Local/302@from-internal-00000040;1") == "302"
    assert rung_extension("Local/302@from-internal-00000040;2") == "302"
    assert rung_extension("Local/16175550000@from-internal-00000041;1") == "16175550000"  # follow-me to a cell
    assert rung_extension("PJSIP/302-00000067") == "302"
    assert rung_extension("DAHDI/1-1") is None and rung_extension("") is None


def test_a_number_as_a_notification_shows_it():
    assert pretty_number("+16175551234") == "(617) 555-1234"
    assert pretty_number("6175551234") == "(617) 555-1234"
    assert pretty_number("+442071234567") == "+442071234567"
    assert pretty_number("") == ""


# --- rings ---------------------------------------------------------------------------------------------------------


def test_a_ring_group_ringing_a_registered_extension_wakes_its_phone_once_per_pass():
    clock = [NOW]
    sender = FakeSender()
    relay = PushRelay(registry(), sender, clock=lambda: clock[0])  # type: ignore[arg-type]
    tracker = CallTracker(clock=lambda: clock[0])

    async def go():
        tracker.feed(outside_call())
        for event in ring_group_pass():  # 200 is a desk phone nobody registered, 302 the iPhone
            relay.feed(event, tracker)
        await relay.drain()
        assert len(sender.sent) == 1  # the Local channel and the phone itself: one ring
        push = sender.sent[0]
        assert push["token"] == IPHONE_VOIP and push["kind"] == "voip" and push["expiration"] == 0
        assert push["collapse_id"] is None
        assert push["payload"] == {
            "kind": "ring",
            "call": LINKED,
            "extension": "302",
            "number": "+16175551234",
            "name": "LINDA CHEN",
            "dialed": "+17817296899",
            "at": int(NOW * 1000),
        }
        relay.feed(dial_begin(TRUNK, "Local/16175550000@from-internal-00000042;1"), tracker)  # follow-me to a cell
        clock[0] += 30  # the ring group's next pass
        for event in ring_group_pass():
            relay.feed(event, tracker)
        await relay.drain()
        assert len(sender.sent) == 1
        clock[0] += 20  # beyond the 45 seconds: the phone is rung again for this call
        for event in ring_group_pass():
            relay.feed(event, tracker)
        await relay.drain()
        assert len(sender.sent) == 2
        for event in ring_group_pass(("302",)):
            relay.feed({**event, "Linkedid": "1730000000.999"}, tracker)  # another call: pushed at once
        await relay.drain()
        assert len(sender.sent) == 3 and sender.sent[2]["payload"]["number"] == ""  # a call the hub never saw start
        assert relay.status()["pushes"] == {"ring": 3, "pop": 0, "test": 0}

    run(go)


def test_the_hooks_user_event_is_a_ring_too_and_is_remembered():
    sender = FakeSender()
    relay = PushRelay(registry(), sender, clock=lambda: NOW)  # type: ignore[arg-type]
    tracker = CallTracker(clock=lambda: NOW)

    async def go():
        tracker.feed(outside_call())
        relay.feed({"Event": "UserEvent", "UserEvent": "Other", "Extension": "302", "Linkedid": LINKED}, tracker)
        assert relay.status()["hook_seen"] is None
        relay.feed({"Event": "UserEvent", "UserEvent": "PosPush", "Extension": "302", "Linkedid": LINKED}, tracker)
        await relay.drain()
        assert [p["payload"]["extension"] for p in sender.sent] == ["302"]
        assert relay.status()["hook_seen"] == int(NOW * 1000)
        for event in ring_group_pass(("302",)):  # the dial that follows the hook: the same ring
            relay.feed(event, tracker)
        await relay.drain()
        assert len(sender.sent) == 1

    run(go)


def test_a_ring_for_an_extension_nobody_registered_is_nothing():
    sender = FakeSender()
    relay = PushRelay(registry(), sender, clock=lambda: NOW)  # type: ignore[arg-type]
    tracker = CallTracker(clock=lambda: NOW)

    async def go():
        relay.feed(dial_begin(TRUNK, "PJSIP/200-00000067"), tracker)
        relay.feed(newchannel(TRUNK, "from-pstn-e164-us", "+17817296899", LINKED, LINKED), tracker)
        relay.feed({"Event": "DialBegin", "DestChannel": "PJSIP/302-00000067"}, tracker)  # no call id: not a ring
        await relay.drain()
        assert sender.sent == []

    run(go)


# --- pick-ups -----------------------------------------------------------------------------------------------------


def pop(**over: Any) -> dict[str, Any]:
    return {
        "id": f"{LINKED}:200",
        "device": "ipad1",
        "extension": "200",
        "number": "+16175551234",
        "name": "LINDA CHEN",
        "dialed": "+17817296899",
        "at": int(NOW * 1000),
        "seq": 1,
        **over,
    }


def test_a_pick_up_on_a_linked_desk_phone_notifies_the_screen():
    sender = FakeSender()
    relay = PushRelay(registry(), sender, clock=lambda: NOW)  # type: ignore[arg-type]

    async def go():
        relay.pop(pop())
        relay.pop(pop(device="mac1"))  # a screen without a token: nothing
        relay.pop(pop(name="", id=f"{LINKED}:201", extension="201"))
        relay.pop(pop(name="", number="", id=f"{LINKED}:202", extension="202"))
        await relay.drain()
        assert [p["token"] for p in sender.sent] == [IPAD_ALERT] * 3
        first = sender.sent[0]
        assert first["kind"] == "alert" and first["collapse_id"] == f"{LINKED}:200"
        assert first["expiration"] == int(NOW) + 60
        assert first["payload"] == {
            "aps": {
                "alert": {"title": "Phone 200 picked up", "body": "(617) 555-1234 · LINDA CHEN"},
                "sound": "default",
                "interruption-level": "time-sensitive",
                "thread-id": "desk-phone",
            },
            "kind": "pop",
            "call": f"{LINKED}:200",
            "device": "ipad1",
            "extension": "200",
            "number": "+16175551234",
            "name": "LINDA CHEN",
        }
        assert sender.sent[1]["payload"]["aps"]["alert"]["body"] == "(617) 555-1234"
        assert sender.sent[2]["payload"]["aps"]["alert"]["body"] == "a call"
        assert relay.status()["pushes"]["pop"] == 3

    run(go)


# --- what Apple answers ----------------------------------------------------------------------------------------------


def test_where_apple_took_a_token_is_remembered_and_a_gone_token_is_forgotten():
    sender = FakeSender()
    devices = registry()
    devices.put(PushDevice("dd" * 8, "iphone2", "ios", "voip", "302"))
    sender.answers[IPHONE_VOIP] = (True, 200, None, "sandbox")
    sender.answers["dd" * 8] = (False, 410, "Unregistered", "production")
    relay = PushRelay(devices, sender, clock=lambda: NOW)  # type: ignore[arg-type]
    tracker = CallTracker(clock=lambda: NOW)

    async def go():
        relay.feed(dial_begin(TRUNK, "PJSIP/302-00000067"), tracker)
        await relay.drain()
        assert len(sender.sent) == 2
        assert next(d for d in devices.all() if d.token == IPHONE_VOIP).env == "sandbox"
        assert devices.counts() == {"voip": 1, "alert": 2}  # iphone2's token is gone

    run(go)


def test_without_an_apple_key_nothing_goes_out_but_the_status_says_so():
    relay = PushRelay(registry(), None, clock=lambda: NOW)
    tracker = CallTracker(clock=lambda: NOW)

    async def go():
        relay.feed(dial_begin(TRUNK, "PJSIP/302-00000067"), tracker)
        relay.pop(pop())
        await relay.drain()
        status = relay.status()
        assert status["configured"] is False and status["devices"] == {"voip": 1, "alert": 2}
        assert status["pushes"] == {"ring": 1, "pop": 1, "test": 0} and status["pbx"] is False
        result = await relay.test("ipad1")
        assert result == {
            "device": "ipad1",
            "kind": "alert",
            "configured": False,
            "tokens": 1,
            "sent": 0,
            "results": [],
        }
        await relay.close()

    run(go)


def test_a_test_push_goes_to_the_screens_tokens_of_that_kind():
    sender = FakeSender()
    relay = PushRelay(registry(), sender, clock=lambda: NOW)  # type: ignore[arg-type]

    async def go():
        result = await relay.test("IPHONE1")
        assert (result["tokens"], result["sent"]) == (1, 1)
        assert result["results"] == [
            {"device": "iphone1", "platform": "ios", "kind": "alert", "ok": True, "env": "production", "reason": None}
        ]
        assert sender.sent[-1]["payload"]["aps"]["alert"]["title"] == "POS push works"
        assert sender.sent[-1]["collapse_id"] == "test"
        call = await relay.test("iphone1", "voip")
        assert call["sent"] == 1 and sender.sent[-1]["kind"] == "voip"
        assert sender.sent[-1]["payload"]["kind"] == "test" and sender.sent[-1]["payload"]["extension"] == "302"
        assert sender.sent[-1]["payload"]["call"].startswith("test-")
        assert (await relay.test("mac1"))["tokens"] == 0
        assert relay.status()["pushes"]["test"] == 3
        await relay.close()
        assert sender.closed

    run(go)


# --- the marks on the PBX --------------------------------------------------------------------------------------------


def test_the_marks_on_the_pbx_follow_the_registered_extensions():
    devices = registry()
    devices.put(PushDevice("dd" * 8, "iphone2", "ios", "voip", "1000"))
    devices.put(PushDevice("ee" * 8, "iphone3", "ios", "voip", "303"))
    relay = PushRelay(devices, FakeSender(), clock=lambda: NOW)  # type: ignore[arg-type]

    async def go():
        async with FakePBX() as pbx:
            async with AMIClient("127.0.0.1", pbx.port) as client:
                await client.login("pos", "s3cret", events="call,user")
                await relay.connected(client)  # the family was empty: DBDelTree's "not found" is no error
                assert pbx.db == {"POSPUSH": {"302": "1", "303": "1", "1000": "1"}}
                status = relay.status()
                assert status["marks"] == ["302", "303", "1000"] and status["marks_error"] is None
                assert status["marked_at"] == int(NOW * 1000) and status["pbx"] is True
                devices.put(PushDevice("ff" * 8, "iphone4", "ios", "voip", "304"))
                threading.Thread(target=relay.marks_changed).start()  # as a request on the wire does it
                await until(lambda: "304" in pbx.db.get("POSPUSH", {}))
                for token in (IPHONE_VOIP, "dd" * 8, "ee" * 8, "ff" * 8):
                    devices.remove(token)
                relay.marks_changed()
                await until(lambda: "POSPUSH" not in pbx.db)
                await relay.drain()
                assert relay.marks == []
                pbx.denied.add("DBPut")  # an AMI user without the write right
                devices.put(PushDevice(IPHONE_VOIP, "iphone1", "ios", "voip", "302"))
                await relay.sync_marks()
                assert "write right `system`" in relay.status()["marks_error"]
                relay.disconnected()
                relay.marks_changed()  # no connection: nothing to do, no error
                assert relay.status()["pbx"] is False

    run(go)


def test_the_watcher_asks_for_user_events_syncs_the_marks_and_feeds_the_relay():
    sender = FakeSender()
    devices = registry()
    relay = PushRelay(devices, sender)  # type: ignore[arg-type]
    calls = AnsweredCalls(lambda: {"200": "ipad1"})

    async def go():
        async with FakePBX() as pbx:
            watcher = AmiWatcher("127.0.0.1", pbx.port, "pos", "s3cret", calls, relay=relay, backoff=(0.05, 0.1))
            watcher.start()
            try:
                await until(lambda: watcher.status()["connected"] and relay.status()["pbx"])
                login = next(p for p in pbx.received if p.get("Action") == "Login")
                assert login["Events"] == "call,user"
                await until(lambda: pbx.db.get("POSPUSH") == {"302": "1"})
                for event in ring_group_answer(answering="200", others=("302", "201")):
                    await pbx.emit(**event)
                await until(lambda: len(sender.sent) == 2)
                kinds = [(p["kind"], p["token"]) for p in sender.sent]
                assert kinds == [("voip", IPHONE_VOIP), ("alert", IPAD_ALERT)]  # 302 rung, then 200 picked up
                assert sender.sent[1]["payload"]["call"] == f"{LINKED}:200"
                assert watcher.tracker.state(LINKED)["state"] == "answered"
                await pbx.drop()
                await until(lambda: not relay.status()["pbx"])
                await until(lambda: watcher.status()["connections"] == 2 and relay.status()["pbx"])
            finally:
                await watcher.stop()
            assert relay.status()["pbx"] is False

    run(go)


# --- on the wire ---------------------------------------------------------------------------------------------------


def test_a_screen_registers_its_tokens_on_the_wire_and_the_hub_says_how_it_stands():
    devices = PushDevices(clock=lambda: NOW)
    sender = FakeSender()
    relay = PushRelay(devices, sender, clock=lambda: NOW)  # type: ignore[arg-type]
    with TestClient(create_app(OpStore(), push_devices=devices, relay=relay)) as c:
        body = {
            "device": "iphone1",
            "platform": "ios",
            "kind": "voip",
            "token": IPHONE_VOIP.upper(),
            "extension": "302",
        }
        assert c.put("/push/devices", json=body).json() == {
            "ok": True,
            "configured": True,
            "kind": "voip",
            "extension": "302",
            "env": None,
        }
        assert c.put("/push/devices", json={**body, "kind": "alert", "token": IPHONE_ALERT}).json()["extension"] == ""
        refused = c.put("/push/devices", json={**body, "extension": ""})
        assert refused.status_code == 422 and "extension" in refused.json()["detail"]["message"]
        assert c.put("/push/devices", json={**body, "token": "zz"}).status_code == 422
        assert [d["device"] for d in c.get("/devices").json()["devices"]] == ["iphone1"]  # heard from
        status = c.get("/push/status").json()
        assert status["configured"] is True and status["devices"] == {"voip": 1, "alert": 1}
        assert status["marks"] == [] and status["pbx"] is False and status["hook_seen"] is None
        assert [d["token"] for d in status["list"]] == ["bbbbbbbb…", "aaaaaaaa…"]
        assert devices.extensions() == {"302"}
        test = c.post("/push/test", json={"device": "iphone1"}).json()
        assert (test["tokens"], test["sent"]) == (1, 1) and sender.sent[-1]["token"] == IPHONE_ALERT
        assert c.post("/push/test", json={"device": "iphone1", "kind": "sms"}).status_code == 422
        assert c.delete(f"/push/devices/{IPHONE_VOIP}").json() == {"ok": True, "removed": True}
        assert c.delete(f"/push/devices/{IPHONE_VOIP}").json() == {"ok": True, "removed": False}
        assert c.get("/push/status").json()["devices"] == {"voip": 0, "alert": 1}
    assert sender.closed  # the API closed the relay with it


def test_a_woken_phone_asks_where_the_call_stands():
    class Idle(AmiWatcher):
        def start(self) -> None:
            pass

        async def stop(self) -> None:
            pass

    tracker = CallTracker(clock=lambda: NOW)
    watcher = Idle("pbx", 5038, "pos", "x", AnsweredCalls(lambda: {}), tracker=tracker)
    with TestClient(create_app(OpStore(), watcher=watcher)) as c:
        unknown = c.get(f"/phones/calls/{LINKED}").json()
        assert unknown == {"call": LINKED, "state": "unknown", "answered": [], "number": "", "name": "", "dialed": ""}
        tracker.feed(outside_call())
        ringing = c.get(f"/phones/calls/{LINKED}").json()
        assert (ringing["state"], ringing["number"], ringing["name"]) == ("ringing", "+16175551234", "LINDA CHEN")
        for event in ring_group_answer(answering="200", others=("302",)):
            tracker.feed(event)
        assert c.get(f"/phones/calls/{LINKED}").json()["answered"] == ["200"]
    with TestClient(create_app(OpStore())) as c:  # no PBX configured
        assert c.get(f"/phones/calls/{LINKED}").json()["state"] == "unknown"


def test_a_hub_without_a_pbx_or_a_key_still_takes_registrations():
    with TestClient(create_app(OpStore())) as c:
        body = {"device": "ipad1", "platform": "ios", "kind": "alert", "token": IPAD_ALERT}
        assert c.put("/push/devices", json=body).json()["configured"] is False
        assert c.post("/push/test", json={"device": "ipad1"}).json()["sent"] == 0
        assert c.get("/push/status").json()["configured"] is False


def test_time_passes_for_the_relays_memory_of_rings():
    relay = PushRelay(registry(), FakeSender(), clock=time.time, again=0.05)  # type: ignore[arg-type]
    tracker = CallTracker()

    async def go():
        relay.feed(dial_begin(TRUNK, "PJSIP/302-00000067"), tracker)
        await asyncio.sleep(0.06)
        relay.feed(dial_begin(TRUNK, "PJSIP/302-00000067"), tracker)
        await relay.drain()
        assert relay.status()["pushes"]["ring"] == 2

    run(go)
