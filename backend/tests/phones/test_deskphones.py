"""Desk phones linked to screens: the hub watches the PBX for an extension answering an outside call, looks
the extension up in the `desk_phones` setting and keeps the answer for the linked device to collect, which
then opens the caller's order as if it had taken the call itself."""

from __future__ import annotations

import asyncio
import socket
import time

import pytest

from pos.phones.ami import Message
from pos.phones.deskphones import AmiWatcher, Answered, AnsweredCalls, CallTracker, _describe, extension_of
from pos.settings import DEFAULTS, SettingStore, clean_desk_phones
from tests.orders.test_menu_orders import client
from tests.phones.fake_ami import FakePBX

TRUNK = "PJSIP/Twilio-Oregon-00000123"
LINKED = "1730000000.123"
CALLER = {"CallerIDNum": "+16175551234", "CallerIDName": "LINDA CHEN"}


def newchannel(channel: str, context: str, exten: str, uniqueid: str, linkedid: str, **caller: str) -> Message:
    return {
        "Event": "Newchannel",
        "Channel": channel,
        "Context": context,
        "Exten": exten,
        "Uniqueid": uniqueid,
        "Linkedid": linkedid,
        **caller,
    }


def dial_end(channel: str, dest: str, status: str, linkedid: str = LINKED, **caller: str) -> Message:
    """The end of one dial: the dialed channel carries its endpoint's context, a trunk's for a trunk."""
    return {
        "Event": "DialEnd",
        "Channel": channel,
        "DestChannel": dest,
        "DestContext": "from-pstn-e164-us" if "Twilio" in dest else "from-internal",
        "DialStatus": status,
        "Linkedid": linkedid,
        "CallerIDNum": caller.get("CallerIDNum", "+16175551234"),
        "CallerIDName": caller.get("CallerIDName", "617-555-1234"),  # FreePBX's LookGood rewrite of the name
    }


def hangup(channel: str, uniqueid: str, linkedid: str) -> Message:
    return {"Event": "Hangup", "Channel": channel, "Uniqueid": uniqueid, "Linkedid": linkedid, "Cause": "16"}


def outside_call() -> Message:
    """The restaurant's number dialed from a cell: the trunk channel, before FreePBX touches the caller name."""
    return newchannel(TRUNK, "from-pstn-e164-us", "+17817296899", LINKED, LINKED, **CALLER)


def ring_group_answer(answering: str = "200", others: tuple[str, ...] = ("201", "220")) -> list[Message]:
    """What the manager interface shows when ring group 600 rings every desk phone through a Local channel
    each and one of them picks up: only the answering phone's dial ends with ANSWER."""
    events = [outside_call()]
    for n, ext in enumerate((answering, *others)):
        local = f"Local/{ext}@from-internal-0000004{n}"
        events.append(newchannel(f"{local};1", "from-internal", ext, f"1730000001.{n}1", LINKED, **CALLER))
        events.append(newchannel(f"{local};2", "from-internal", ext, f"1730000001.{n}2", LINKED, **CALLER))
        events.append({**dial_end(f"{local};2", f"PJSIP/{ext}-0000006{n}", "ANSWER"), "Event": "DialBegin"})
    events.append(dial_end("Local/200@from-internal-00000040;2", f"PJSIP/{answering}-00000060", "ANSWER"))
    events.append(dial_end(TRUNK, "Local/200@from-internal-00000040;1", "ANSWER"))
    for n, ext in enumerate(others, start=1):
        events.append(dial_end(f"Local/{ext}@from-internal-0000004{n};2", f"PJSIP/{ext}-0000006{n}", "CANCEL"))
    return events


# --- which extension a channel is ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("channel", "extension"),
    [
        ("PJSIP/200-00000067", "200"),
        ("SIP/201-0000abcd", "201"),
        ("PJSIP/Twilio-Oregon-00000123", "Twilio-Oregon"),  # a trunk: never on the list of desk phones
        ("Local/200@from-internal-00000045;2", None),
        ("DAHDI/1-1", None),
        ("", None),
    ],
)
def test_the_extension_is_read_off_the_channel_name(channel, extension):
    assert extension_of(channel) == extension


# --- following a call through the events ---------------------------------------------------------------------


def test_a_desk_phone_answering_the_ring_group_is_one_answer_with_the_callers_own_name():
    tracker = CallTracker(clock=lambda: 1_730_000_010.5)
    answers = [a for a in map(tracker.feed, ring_group_answer()) if a is not None]
    assert answers == [
        Answered(
            linkedid=LINKED,
            extension="200",
            number="+16175551234",
            name="LINDA CHEN",  # from the trunk, not FreePBX's 617-555-1234 rewrite
            dialed="+17817296899",
            at_ms=1_730_000_010_500,
        )
    ]


def test_a_phone_dialed_straight_is_an_answer_too():
    tracker = CallTracker()
    assert tracker.feed(outside_call()) is None
    answer = tracker.feed(dial_end(TRUNK, "PJSIP/201-00000070", "ANSWER"))
    assert answer is not None and (answer.extension, answer.number) == ("201", "+16175551234")


def test_a_call_answered_once_is_reported_once():
    tracker = CallTracker()
    events = ring_group_answer()
    first = [a for a in map(tracker.feed, events) if a is not None]
    again = tracker.feed(dial_end("Local/200@from-internal-00000040;2", "PJSIP/200-00000060", "ANSWER"))
    assert len(first) == 1 and again is None


def test_a_transfer_to_another_desk_phone_is_a_second_answer_on_that_phone():
    tracker = CallTracker()
    [a for a in map(tracker.feed, ring_group_answer()) if a is not None]
    moved = tracker.feed(dial_end(TRUNK, "PJSIP/201-00000080", "ANSWER"))
    assert moved is not None and (moved.extension, moved.number, moved.name) == ("201", "+16175551234", "LINDA CHEN")


def test_calls_between_extensions_and_calls_out_are_not_answers():
    tracker = CallTracker()
    internal = [
        newchannel("PJSIP/201-00000090", "from-internal", "200", "1730000020.1", "1730000020.1", CallerIDNum="201"),
        dial_end("PJSIP/201-00000090", "PJSIP/200-00000091", "ANSWER", linkedid="1730000020.1", CallerIDNum="201"),
    ]
    assert [tracker.feed(e) for e in internal] == [None, None]
    # a call out: the extension's channel carries the restaurant's number by the time the trunk answers
    outbound = [
        newchannel("PJSIP/200-00000092", "from-internal", "16175551234", "1730000030.1", "1730000030.1"),
        newchannel("PJSIP/Twilio-Oregon-00000093", "from-pstn-e164-us", "s", "1730000030.2", "1730000030.1"),
        dial_end(
            "PJSIP/200-00000092", "PJSIP/Twilio-Oregon-00000093", "ANSWER", "1730000030.1", CallerIDNum="7817296899"
        ),
    ]
    assert [tracker.feed(e) for e in outbound] == [None, None, None]
    # follow-me ringing a cell: the dial that answers is a trunk's, not a desk phone's
    tracker.feed(outside_call())
    assert (
        tracker.feed(dial_end("Local/6175550000@from-internal-00000050;2", "PJSIP/Twilio-Oregon-00000094", "ANSWER"))
        is None
    )


def test_a_call_that_rang_before_the_hub_was_watching_still_counts_when_the_number_is_an_outside_one():
    tracker = CallTracker()  # no Newchannel seen: the watcher connected mid-call
    answer = tracker.feed(dial_end("Local/200@from-internal-00000040;2", "PJSIP/200-00000060", "ANSWER"))
    assert answer is not None and (answer.number, answer.name, answer.dialed) == ("+16175551234", "617-555-1234", "")
    assert tracker.feed(dial_end("PJSIP/201-1", "PJSIP/200-2", "ANSWER", linkedid="x", CallerIDNum="201")) is None


def test_a_dial_that_was_not_answered_is_nothing():
    tracker = CallTracker()
    tracker.feed(outside_call())
    for status in ("BUSY", "NOANSWER", "CANCEL", "CONGESTION", "CHANUNAVAIL"):
        assert tracker.feed(dial_end(TRUNK, "PJSIP/200-00000060", status)) is None


def test_the_call_is_forgotten_when_the_caller_hangs_up_or_after_hours():
    now = [1_730_000_000.0]
    tracker = CallTracker(clock=lambda: now[0])
    tracker.feed(outside_call())
    tracker.feed(hangup(TRUNK, LINKED, LINKED))
    assert tracker.open == 0
    tracker.feed(outside_call())
    assert tracker.open == 1
    now[0] += 5 * 3600
    tracker.feed(newchannel("PJSIP/201-1", "from-internal", "200", "y", "y", CallerIDNum="201"))  # any event prunes
    assert tracker.open == 0


# --- what the screens collect -----------------------------------------------------------------------------------


def answered(ext: str = "200", linkedid: str = LINKED, at_ms: int = 1_730_000_010_500) -> Answered:
    return Answered(linkedid, ext, "+16175551234", "LINDA CHEN", "+17817296899", at_ms)


def test_an_answer_on_a_linked_phone_waits_for_its_screen_and_an_unlinked_one_is_dropped():
    now = [1_730_000_012.0]
    calls = AnsweredCalls(lambda: {"200": "tab1", "201": "Mac1"}, clock=lambda: now[0])
    assert calls.record(answered("210")) is None  # a phone nobody linked
    pop = calls.record(answered("200"))
    assert pop is not None and pop["device"] == "tab1" and pop["id"] == f"{LINKED}:200"
    assert calls.for_device("tab1") == [
        {
            "id": f"{LINKED}:200",
            "extension": "200",
            "number": "+16175551234",
            "name": "LINDA CHEN",
            "dialed": "+17817296899",
            "at": 1_730_000_010_500,
            "age_ms": 1500,
        }
    ]
    assert calls.for_device("ipad1") == []
    assert calls.for_device("mac1") == [] and calls.linked("mac1") and calls.linked("TAB1") and not calls.linked("x")
    assert calls.counts == {"answers": 2, "pops": 1}


def test_the_screen_sees_a_call_for_two_minutes_then_not():
    now = [1_730_000_012.0]
    calls = AnsweredCalls(lambda: {"200": "tab1"}, clock=lambda: now[0])
    calls.record(answered("200"))
    now[0] += 100
    assert len(calls.for_device("tab1")) == 1
    now[0] += 30
    assert calls.for_device("tab1") == []


def test_the_links_are_read_when_the_phone_answers_so_a_managers_change_takes_the_next_call():
    links = {"200": "tab1"}
    calls = AnsweredCalls(lambda: links)
    links["200"] = "ipad1"
    assert calls.record(answered("200"))["device"] == "ipad1"


# --- the setting -----------------------------------------------------------------------------------------------


def test_no_desk_phone_is_linked_until_a_manager_links_one():
    assert SettingStore().get("desk_phones") == {"links": []}
    assert clean_desk_phones(DEFAULTS["desk_phones"]) == {"links": []}


def test_links_are_tidied():
    cleaned = clean_desk_phones(
        {"links": [{"extension": " 200 ", "device": " tab1"}, {"extension": "201", "device": "mac1"}]}
    )
    assert cleaned == {"links": [{"extension": "200", "device": "tab1"}, {"extension": "201", "device": "mac1"}]}


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ({"links": {"200": "tab1"}}, "list"),
        ({"links": [{"device": "tab1"}]}, "extension"),
        ({"links": [{"extension": "200"}]}, "device"),
        ({"links": [{"extension": "2 00", "device": "tab1"}]}, "extension"),
        ({"links": [{"extension": "200", "device": "tab 1"}]}, "device"),
        ({"links": [{"extension": "200", "device": "tab1"}, {"extension": "200", "device": "mac1"}]}, "twice"),
    ],
)
def test_bad_links_are_refused_with_the_reason(body, problem):
    with pytest.raises(ValueError, match=problem):
        clean_desk_phones(body)


# --- on the wire --------------------------------------------------------------------------------------------------


def test_a_manager_links_the_phones_and_the_linked_screen_collects_the_answer():
    c = client()
    assert c.get("/settings/desk_phones").json() == {"links": []}
    assert c.get("/phones/answered", params={"device": "tab1"}).json() == {
        "device": "tab1",
        "linked": False,
        "calls": [],
    }
    body = {"links": [{"extension": "200", "device": "tab1"}]}
    assert c.put("/settings/desk_phones", json=body).status_code == 401
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    auth = {"authorization": f"Bearer {token}"}
    assert c.put("/settings/desk_phones", json=body, headers=auth).json() == body
    assert c.get("/settings/desk_phones").json() == body
    r = c.put("/settings/desk_phones", json={"links": [{"extension": "", "device": "tab1"}]}, headers=auth)
    assert r.status_code == 422 and "extension" in r.json()["detail"]["message"]

    c.app.state.answered.record(answered("200", at_ms=int(time.time() * 1000)))  # what the watcher does on a pick-up
    seen = c.get("/phones/answered", params={"device": "tab1"}).json()
    assert seen["linked"] is True and [x["id"] for x in seen["calls"]] == [f"{LINKED}:200"]
    assert seen["calls"][0]["number"] == "+16175551234" and seen["calls"][0]["age_ms"] >= 0
    assert c.get("/phones/answered", params={"device": "mac1"}).json()["calls"] == []
    status = c.get("/phones/status").json()
    assert (status["configured"], status["connected"], status["links"]) == (False, False, 1)
    assert status["answers"] == 1 and status["pops"] == 1


# --- the watcher on a live manager interface ---------------------------------------------------------------------


async def until(check, *, seconds: float = 5.0) -> None:
    for _ in range(int(seconds / 0.02)):
        if check():
            return
        await asyncio.sleep(0.02)
    raise AssertionError("gave up waiting")


def test_the_watcher_logs_in_turns_the_events_into_answers_and_comes_back_after_a_drop():
    calls = AnsweredCalls(lambda: {"200": "tab1"})

    async def go():
        async with FakePBX() as pbx:
            watcher = AmiWatcher("127.0.0.1", pbx.port, "pos", "s3cret", calls, backoff=(0.05, 0.1))
            watcher.start()
            try:
                await until(lambda: watcher.status()["connected"])
                login = next(p for p in pbx.received if p.get("Action") == "Login")
                assert login["Events"] == "call"
                for event in ring_group_answer():
                    await pbx.emit(**event)
                await until(lambda: calls.for_device("tab1"))
                assert watcher.status()["events"] >= len(ring_group_answer())
                await pbx.drop()  # the tunnel or the PBX went away
                await until(lambda: not watcher.status()["connected"])
                await until(lambda: watcher.status()["connected"] and watcher.status()["connections"] == 2)
                assert watcher.status()["last_error"]
            finally:
                await watcher.stop()
            status = watcher.status()
            assert not status["connected"] and (status["host"], status["configured"]) == ("127.0.0.1", True)

    asyncio.run(go())
    assert calls.for_device("tab1")[0]["extension"] == "200"


def test_the_watcher_keeps_trying_while_the_pbx_is_unreachable():
    calls = AnsweredCalls(lambda: {})

    async def go():
        watcher = AmiWatcher("127.0.0.1", 1, "pos", "nope", calls, backoff=(0.05, 0.1))
        watcher.start()
        try:
            await until(lambda: watcher.status()["attempts"] >= 3)
            status = watcher.status()
            assert status["connected"] is False and status["last_error"] and status["configured"] is True
        finally:
            await watcher.stop()

    asyncio.run(go())


def test_the_api_runs_the_watcher_for_as_long_as_it_runs():
    from fastapi.testclient import TestClient

    from pos.api.app import create_app
    from pos.sync.oplog import OpStore

    class Spy(AmiWatcher):
        log: list[str] = []

        def start(self) -> None:
            self.log.append("start")

        async def stop(self) -> None:
            self.log.append("stop")

    spy = Spy("pbx", 5038, "pos", "x", AnsweredCalls(lambda: {}))
    with TestClient(create_app(OpStore(), watcher=spy)) as c:
        assert spy.log == ["start"]
        assert c.get("/phones/status").json()["host"] == "pbx"
    assert spy.log == ["start", "stop"]


def test_the_command_line_prints_each_answer_as_a_json_line():
    import io
    import json

    from pos.phones.deskphones import watch

    out = io.StringIO()

    async def go():
        async with FakePBX() as pbx:
            from pos.phones.ami import AMIClient

            async with AMIClient("127.0.0.1", pbx.port) as client:
                await client.login("pos", "s3cret", events="call")
                for event in ring_group_answer():
                    await pbx.emit(**event)
                await pbx.emit(**dial_end(TRUNK, "PJSIP/201-00000080", "ANSWER"))  # transferred on
                return await watch(client, count=2, seconds=5, out=out)

    assert asyncio.run(go()) == 2
    first, second = (json.loads(line) for line in out.getvalue().splitlines())
    assert (first["extension"], first["number"], first["name"]) == ("200", "+16175551234", "LINDA CHEN")
    assert second["extension"] == "201" and second["linkedid"] == LINKED


def test_a_name_that_does_not_resolve_points_at_the_tunnel():
    """The api reaches the PBX through the tunnel service, by name; with the tunnel down the name resolves to
    nothing, which the status should say in those words rather than as a resolver error."""
    err = socket.gaierror(-3, "Temporary failure in name resolution")
    expected = "pbx does not resolve (Temporary failure in name resolution): the tunnel service is probably down"
    assert _describe(err, "pbx") == expected
    assert _describe(ConnectionRefusedError(111, "Connection refused"), "pbx") == "[Errno 111] Connection refused"
    assert _describe(TimeoutError(), "pbx") == "TimeoutError"


def test_a_pbx_whose_name_does_not_resolve_is_said_so_in_the_status(monkeypatch):
    """On a hub the api names the tunnel service, `pbx`; while that service is down (the PBX refusing the hub's
    key, say) the name resolves to nothing, and the status says so in those words."""

    class NoSuchHost:
        def __init__(self, *args, **kwargs): ...

        async def __aenter__(self):
            raise socket.gaierror(-3, "Temporary failure in name resolution")

        async def __aexit__(self, *exc):
            return False

    monkeypatch.setattr("pos.phones.deskphones.AMIClient", NoSuchHost)

    async def go():
        watcher = AmiWatcher("pbx", 5038, "pos", "secret", AnsweredCalls(lambda: {}), backoff=(0.01, 0.02))
        watcher.start()
        await until(lambda: watcher.status()["attempts"] >= 2)
        status = watcher.status()
        await watcher.stop()
        return status

    status = asyncio.run(go())
    assert (status["connected"], status["connections"]) == (False, 0)
    expected = "pbx does not resolve (Temporary failure in name resolution): the tunnel service is probably down"
    assert status["last_error"] == expected
