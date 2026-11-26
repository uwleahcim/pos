"""Texts that really go out (`pos.twilio`, docs/texts.md): the POS's texts to its customers sent through the
restaurant's own Twilio account, which a manager types in the app. Twilio is stood in for by a transport that
answers as its Messages API does; nothing here reaches the internet. The numbers and the account are made up."""

from __future__ import annotations

import asyncio
import json
import logging
import threading
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.api.keys import use_keys
from pos.identity.staff import Directory, Staff
from pos.keys import TEXTS, HubKeys, KeyStore, vault_from_env
from pos.maps import Lookups
from pos.menu.service import MenuService, load_definitions
from pos.messaging import LogMessenger, Message, about_of
from pos.online.service import OnlineOrders
from pos.orders.numbers import OrderNumbers
from pos.printing.service import PrintService
from pos.push.devices import PushDevices
from pos.push.relay import PushRelay
from pos.settings import SettingStore
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts
from pos.twilio import (
    MOST_AN_HOUR,
    TwilioConfig,
    TwilioMessenger,
    clean,
    config_of,
    e164,
    said_of,
)

ACCOUNT = "AC" + "0123456789abcdef" * 2
TOKEN = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
API_KEY = "SK" + "fedcba9876543210" * 2
SERVICE = "MG" + "00112233445566778899aabbccddeeff"
FROM = "+17815550100"
PAT = "+17815550142"
"""Nobody's account, nobody's token and nobody's numbers (555-01xx is kept for made-up ones)."""
T0 = 1_800_000_000  # the clock of these tests, in seconds
WORDS = "Hi Pat, order #12 is ready for pickup at China Sky."


class FakeTwilio:
    """Twilio's Messages API as the hub meets it. `script` is what it answers to each text handed to it, in
    turn, and the last of them from then on: `"ok"` (taken), a pair (the web's status, Twilio's error
    number), or an exception to raise in place of an answer. `became` says what a taken text came to when
    it is asked after: Twilio's word, and its error number."""

    def __init__(self, *script: Any, became: tuple[str, int | None] = ("delivered", None)) -> None:
        self.script = list(script) or ["ok"]
        self.became = became
        self.posts: list[dict[str, str]] = []
        self.who: list[str] = []
        self.asked: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.who.append(request.headers.get("authorization", ""))
        if request.method == "GET":
            sid = request.url.path.rsplit("/", 1)[-1].removesuffix(".json")
            self.asked.append(sid)
            status, code = self.became
            return httpx.Response(200, json={"sid": sid, "status": status, "error_code": code})
        assert request.url.path == f"/2010-04-01/Accounts/{ACCOUNT}/Messages.json", request.url.path
        self.posts.append({name: values[0] for name, values in parse_qs(request.content.decode()).items()})
        answer = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        if isinstance(answer, Exception):
            raise answer
        if answer == "ok":
            return httpx.Response(201, json={"sid": f"SM{len(self.posts):032x}", "status": "queued"})
        status, code = answer
        told = {"code": code, "message": "Twilio's own words", "status": status} if code else {}
        return httpx.Response(status, json=told)

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self)


class Bench:
    """A Twilio messenger on a clock that is moved by hand: nothing runs until `turn` is called."""

    def __init__(self, twilio: FakeTwilio | None = None, *, sender: str = FROM, key_sid: str = "") -> None:
        self.twilio = twilio if twilio is not None else FakeTwilio()
        self.now = float(T0)
        self.messenger = TwilioMessenger(
            TwilioConfig(ACCOUNT, TOKEN, sender, key_sid),
            transport=self.twilio.transport,
            now=lambda: self.now,
            background=False,
            sleep=self.wait,
        )

    def wait(self, seconds: float) -> None:
        self.now += seconds

    def turn(self, seconds: float = 0.0) -> int:
        """Time passes, and the messenger works what is due."""
        self.now += seconds
        return self.messenger.run_due()

    def send(self, to: str = "+1 781 555 0142", body: str = WORDS, order_id: str = "o12", kind: str = "ready") -> None:
        self.messenger.send(Message(to, body, "en", order_id, kind))

    def last(self) -> dict[str, Any]:
        return self.messenger._outcomes[-1].about()  # noqa: SLF001 - what became of the last text


def text(to: str = "+1 781 555 0142", body: str = WORDS) -> Message:
    return Message(to, body, "en", "o12", "ready")


# --- one text ------------------------------------------------------------------------------------------------


def test_a_text_goes_to_twilio_from_the_restaurant_s_number_and_is_asked_after():
    bench = Bench()
    bench.send()
    assert bench.twilio.posts == [], "sending never waits for Twilio: the text is in the line"
    assert bench.turn() == 1
    assert bench.twilio.posts == [{"To": PAT, "From": FROM, "Body": WORDS}]
    assert bench.twilio.who == [httpx.BasicAuth(ACCOUNT, TOKEN)._auth_header]  # noqa: SLF001
    assert bench.last()["state"] == "sent"
    # Twilio took it; whether the phone company delivered it is asked a few seconds on
    assert bench.turn(5) == 0 and bench.twilio.asked == []
    assert bench.turn(5) == 1 and bench.twilio.asked == ["SM" + "0" * 31 + "1"]
    assert bench.last() == {
        "at_ms": T0 * 1000,
        "kind": "ready",
        "order_id": "o12",
        "state": "delivered",
        "code": None,
        "said": "",
    }
    assert bench.messenger.waiting == 0


def test_a_messaging_service_or_an_api_key_is_used_where_the_account_has_one():
    bench = Bench(sender=SERVICE, key_sid=API_KEY)
    bench.send()
    bench.turn()
    assert bench.twilio.posts == [{"To": PAT, "MessagingServiceSid": SERVICE, "Body": WORDS}]
    assert bench.twilio.who == [httpx.BasicAuth(API_KEY, TOKEN)._auth_header]  # noqa: SLF001


@pytest.mark.parametrize(
    ("typed", "number"),
    [
        ("+1 781 555 0142", "+17815550142"),
        ("(781) 555-0142", "+17815550142"),
        ("781.555.0142", "+17815550142"),
        ("1 781 555 0142", "+17815550142"),
        ("+86 138 0013 8000", "+8613800138000"),
        ("555 0142", None),  # no area code
        ("081 555 0142", None),  # no area code begins with 0
        ("", None),
        ("call the desk", None),
        ("+1", None),
    ],
)
def test_a_number_is_written_the_way_twilio_wants_it(typed, number):
    assert e164(typed) == number


def test_an_order_whose_number_is_none_is_not_handed_to_twilio():
    bench = Bench()
    bench.send(to="555 0142")
    assert bench.turn() == 0 and bench.twilio.posts == []
    assert (bench.last()["state"], bench.last()["said"]) == (
        "failed",
        "the number on the order is not one a text can be sent to",
    )


# --- when it does not go -------------------------------------------------------------------------------------


def test_a_text_twilio_could_not_be_reached_for_is_tried_twice_more():
    down = httpx.ConnectError("no route")
    bench = Bench(FakeTwilio(down, down, "ok"))
    bench.send()
    bench.turn()
    assert len(bench.twilio.posts) == 1 and bench.last()["state"] == "waiting"
    assert bench.turn(4) == 0
    assert bench.turn(1) == 1 and len(bench.twilio.posts) == 2
    assert bench.turn(20) == 1 and len(bench.twilio.posts) == 3
    assert bench.last()["state"] == "sent"
    # and no more than that: a hub without internet gives up in half a minute
    bench = Bench(FakeTwilio(down))
    bench.send()
    for _ in range(10):
        bench.turn(60)
    assert len(bench.twilio.posts) == 3
    assert (bench.last()["state"], bench.last()["said"]) == ("failed", "Twilio could not be reached")


def test_a_fault_of_twilio_s_own_is_tried_again_and_a_refusal_is_not():
    bench = Bench(FakeTwilio((503, None), (429, 20429), "ok"))
    bench.send()
    bench.turn()
    bench.turn(5)
    bench.turn(20)
    assert len(bench.twilio.posts) == 3 and bench.last()["state"] == "sent"
    # a number Twilio says is none: asked once, and said in words with Twilio's own number for it
    bench = Bench(FakeTwilio((400, 21211)))
    bench.send()
    for _ in range(5):
        bench.turn(60)
    assert len(bench.twilio.posts) == 1
    assert bench.last()["code"] == 21211
    assert bench.last()["said"] == "the number on the order is not one a text can be sent to (Twilio's error 21211)"
    # a fault with nothing of Twilio's to name
    bench = Bench(FakeTwilio((500, None)))
    bench.send()
    for _ in range(5):
        bench.turn(60)
    assert len(bench.twilio.posts) == 3
    assert (bench.last()["code"], bench.last()["said"]) == (None, "Twilio answered with a fault of its own (500)")


@pytest.mark.parametrize("lost", [httpx.ReadTimeout("slow"), httpx.ReadError("dropped"), httpx.WriteError("cut")])
def test_a_text_twilio_may_have_taken_is_never_sent_twice(lost):
    bench = Bench(FakeTwilio(lost))
    bench.send()
    for _ in range(5):
        bench.turn(60)
    assert len(bench.twilio.posts) == 1
    assert bench.last()["said"] == "Twilio did not answer: the text may or may not have gone"
    # nor by pressing Ready again within the ten minutes: it may be on the customer's phone
    bench.send()
    assert bench.turn() == 0 and len(bench.twilio.posts) == 1


@pytest.mark.parametrize(
    ("status", "code", "words"),
    [
        (401, 20003, "Twilio does not know the key: type it again under Keys and connections"),
        (401, None, "Twilio does not know the key: type it again under Keys and connections"),
        (400, 21608, "this Twilio account is a trial: it texts only the numbers verified in its console"),
        (400, 21610, "the customer answered STOP to an earlier text: Twilio sends them no more"),
        (400, 21606, "the number to send from is not one of this Twilio account's that can text"),
        (400, 21408, "Twilio may not text that country (Geo permissions in Twilio's console)"),
        (400, 29999, "Twilio would not send it"),
    ],
)
def test_what_twilio_refuses_is_said_in_words_a_manager_can_act_on(status, code, words):
    bench = Bench(FakeTwilio((status, code)))
    bench.send()
    bench.turn()
    number = code or 20003
    assert bench.last() == {
        "at_ms": T0 * 1000,
        "kind": "ready",
        "order_id": "o12",
        "state": "failed",
        "code": number,
        "said": f"{words} (Twilio's error {number})",
    }
    assert said_of(number) == f"{words} (Twilio's error {number})"


def test_a_text_the_phone_company_throws_away_is_found_out_and_said():
    # the commonest fault of a new account: Twilio takes the text, and the carrier drops it because the
    # number it comes from is not registered for business texts
    bench = Bench(FakeTwilio(became=("undelivered", 30034)))
    bench.send()
    bench.turn()
    assert bench.last()["state"] == "sent"
    bench.turn(8)
    assert bench.last()["state"] == "failed" and bench.last()["code"] == 30034
    assert "not registered for business texts yet (A2P 10DLC" in bench.last()["said"]
    # one the phone company says nothing of stays sent: asked twice, and then left
    bench = Bench(FakeTwilio(became=("sent", None)))
    bench.send()
    bench.turn()
    bench.turn(8)
    bench.turn(37)
    for _ in range(5):
        bench.turn(600)
    assert len(bench.twilio.asked) == 2 and bench.last()["state"] == "sent"


# --- the two guards ------------------------------------------------------------------------------------------


def test_the_same_words_to_the_same_number_go_once_in_ten_minutes():
    bench = Bench()
    bench.send()
    bench.send()  # Ready pressed, taken back and pressed again
    bench.turn()
    assert len(bench.twilio.posts) == 1
    assert bench.last()["said"] == "the same text went to this number a few minutes ago: it was not sent twice"
    bench.send(body="Hi Pat, order #12 at China Sky will be ready at 18:40. Sorry for the wait.", kind="delayed")
    bench.send(to="+1 781 555 0177")  # another customer's order made ready in the same minute
    bench.turn()
    assert len(bench.twilio.posts) == 3
    bench.turn(601)
    bench.send()
    bench.turn()
    assert len(bench.twilio.posts) == 4


def test_a_text_that_did_not_go_can_be_tried_again_at_once():
    bench = Bench(FakeTwilio((400, 21608), "ok"))
    bench.send()
    bench.turn()
    assert bench.last()["state"] == "failed"
    bench.send()  # the manager verified the number in Twilio's console, and Ready is pressed again
    bench.turn()
    assert len(bench.twilio.posts) == 2 and bench.last()["state"] == "sent"


def test_no_more_than_so_many_texts_go_out_in_an_hour_whatever_asks_for_them():
    bench = Bench()
    for n in range(MOST_AN_HOUR + 5):
        bench.send(body=f"Hi Pat, order #{n} is ready for pickup at China Sky.")
    bench.turn()
    assert len(bench.twilio.posts) == MOST_AN_HOUR
    assert bench.last()["said"] == f"more than {MOST_AN_HOUR} texts in an hour: this one was held back"
    bench.turn(3601)
    bench.send(body="Hi Pat, order #999 is ready for pickup at China Sky.")
    bench.turn()
    assert len(bench.twilio.posts) == MOST_AN_HOUR + 1


# --- what is kept, and what is not ---------------------------------------------------------------------------


def test_what_a_screen_is_told_of_the_texts_has_no_number_and_no_words_in_it():
    bench = Bench(FakeTwilio("ok", (400, 21610), "ok"))
    bench.send()
    bench.send(to="+1 781 555 0177", order_id="o13")
    bench.send(to="+1 781 555 0188", order_id="o14", kind="out")
    bench.turn()
    bench.turn(8)
    about = bench.messenger.about()
    assert about == {
        "provider": "twilio",
        "sender": FROM,
        "day": {"texts": 3, "delivered": 2, "failed": 1},
        "last_failed": {
            "at_ms": T0 * 1000,
            "kind": "ready",
            "order_id": "o13",
            "state": "failed",
            "code": 21610,
            "said": "the customer answered STOP to an earlier text: Twilio sends them no more (Twilio's error 21610)",
        },
    }
    told = json.dumps(about)
    for secret in ("0142", "0177", "0188", "Pat", TOKEN, "ready for pickup"):
        assert secret not in told
    # a day on, the count starts over
    bench.turn(24 * 3600 + 1)
    assert bench.messenger.about()["day"] == {"texts": 0, "delivered": 0, "failed": 0}
    assert bench.messenger.about()["last_failed"] is None
    assert about_of(bench.messenger)["provider"] == "twilio"
    assert about_of(LogMessenger()) == {"provider": "log", "sender": "", "day": None, "last_failed": None}


def test_the_log_names_the_order_and_the_outcome_and_nothing_of_the_customer(caplog):
    bench = Bench(FakeTwilio("ok", (400, 21211), httpx.ConnectError("no route to 54.0.0.1")))
    with caplog.at_level(logging.DEBUG):
        bench.send()
        bench.send(to="+1 781 555 0177", order_id="o13")
        bench.send(to="+1 781 555 0188", order_id="o14")
        for _ in range(4):
            bench.turn(30)
    logged = "\n".join(record.getMessage() for record in caplog.records if record.name.startswith("pos"))
    assert "o12" in logged and "o13" in logged and "o14" in logged
    for secret in ("555", "Pat", TOKEN, "ready for pickup at"):
        assert secret not in logged, secret
    assert TOKEN not in repr(bench.messenger.config)


def test_one_text_that_goes_wrong_does_not_stop_the_ones_after_it():
    bench = Bench(FakeTwilio(ValueError("something nobody thought of"), "ok"))
    bench.send()
    bench.send(to="+1 781 555 0177")
    assert bench.turn() == 2
    assert len(bench.twilio.posts) == 2 and bench.last()["state"] == "sent"


def test_the_line_is_worked_by_a_thread_of_its_own_and_closing_ends_it():
    took = threading.Event()

    def twilio(request: httpx.Request) -> httpx.Response:
        took.set()
        return httpx.Response(201, json={"sid": "SM" + "a" * 32, "status": "queued"})

    messenger = TwilioMessenger(TwilioConfig(ACCOUNT, TOKEN, FROM), transport=httpx.MockTransport(twilio))
    messenger.send(text())
    assert took.wait(10), "the text went without anybody working the line by hand"
    worker = messenger._thread  # noqa: SLF001
    assert worker is not None and worker.daemon
    messenger.close()
    worker.join(10)
    assert not worker.is_alive()
    messenger.send(text(body="after the account was exchanged"))  # dropped, and nothing breaks
    assert messenger.waiting == 0
    # nor does a try that was on its way while the account was exchanged
    tried = messenger.try_now(PAT, "a test")
    assert (tried["ok"], tried["said"]) == (False, "Twilio could not be reached")


# --- what a manager types ------------------------------------------------------------------------------------


def test_what_a_manager_types_for_twilio_is_tidied_and_kept():
    typed = {"account": f" {ACCOUNT}\n", "key": f"{TOKEN} ", "sender": "(781) 555-0100", "key_sid": ""}
    kept = clean(typed)
    assert kept == {"key": TOKEN, "account": ACCOUNT, "sender": FROM, "key_sid": ""}
    assert config_of(kept) == TwilioConfig(ACCOUNT, TOKEN, FROM)
    with_service = clean({**typed, "sender": f" {SERVICE} ", "key_sid": API_KEY})
    assert (with_service["sender"], with_service["key_sid"]) == (SERVICE, API_KEY)
    assert config_of(with_service).by_service and config_of(with_service).user == API_KEY
    assert config_of(None) is None and config_of({"key": TOKEN}) is None


@pytest.mark.parametrize(
    ("change", "problem"),
    [
        ({"account": "my twilio login"}, "the Account SID begins with AC"),
        ({"account": API_KEY}, "the Account SID begins with AC"),
        ({"key": ""}, "no Auth Token was typed"),
        ({"key": "hunter2"}, "does not look like an Auth Token"),
        ({"key": "caf\u00e9" * 8}, "does not look like an Auth Token"),
        ({"key": ACCOUNT}, "that is an SID, not the Auth Token"),
        ({"sender": ""}, "send from a phone number of the Twilio account's"),
        ({"sender": "555 0199"}, "send from a phone number of the Twilio account's"),
        ({"sender": "CHINASKY"}, "send from a phone number of the Twilio account's"),
        ({"key_sid": "my api key"}, "an API key's SID begins with SK"),
    ],
)
def test_what_is_wrong_with_it_is_said_in_words_that_do_not_repeat_it(change, problem):
    typed = {"account": ACCOUNT, "key": TOKEN, "sender": FROM, "key_sid": "", **change}
    with pytest.raises(ValueError) as refusal:
        clean(typed)
    words = str(refusal.value)
    assert problem in words
    for value in change.values():
        assert not value or value not in words


# --- on the wire ---------------------------------------------------------------------------------------------

TYPED = {"account": ACCOUNT, "key": TOKEN, "sender": "781 555 0100"}
NOW_MS = T0 * 1000
TEA = {"unit_price": "10.00", "tax_class": "prepared_food", "name": "Tea"}


def staff() -> Directory:
    return Directory([Staff.with_pin("s1", "Amy", "server", "1111"), Staff.with_pin("s3", "Mike", "manager", "9999")])


def hub_keys(store: KeyStore | None = None) -> HubKeys:
    vault = vault_from_env({"POS_SECRET": "the-location-s-own-secret", "POS_KEYS_FILE": "/nowhere/at/all"})
    return HubKeys(store, vault, environ={}, now=lambda: NOW_MS)


def wired(twilio: FakeTwilio | None = None, keys: HubKeys | None = None, **more: Any) -> tuple[TestClient, FakeTwilio]:
    """A hub whose Twilio is `twilio`, and whose texts go out as each is sent (no thread: the test works
    the line itself, or the try does)."""
    twilio = twilio if twilio is not None else FakeTwilio()
    store = OpStore(physical=lambda: NOW_MS)
    app = create_app(
        store,
        staff=staff(),
        menu=MenuService(load_definitions("restaurant")),
        taxes=massachusetts(),
        printing=PrintService([]),
        settings=SettingStore(),
        numbers=OrderNumbers(store),
        keys=keys if keys is not None else hub_keys(),
        lookups=Lookups(),
        online=OnlineOrders(None),
        relay=PushRelay(PushDevices(), None),
        location="China Sky",
        **more,
    )
    app.state.texts_made_with = {"transport": twilio.transport, "background": False, "sleep": lambda seconds: None}
    return TestClient(app), twilio


def token(api: TestClient, pin: str = "9999") -> dict[str, str]:
    answer = api.post("/admin/session", json={"device": "t1", "pin": pin}).json()
    return {"authorization": f"Bearer {answer['token']}"}


def op(op_id: str, kind: str, at: int, order_id: str = "o1", **data: Any) -> dict[str, Any]:
    return {
        "op_id": op_id,
        "order_id": order_id,
        "hlc": str(HLC(NOW_MS - 1000 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def pickup_made_ready(api: TestClient, order_id: str = "o1", phone: str = "(781) 555-0142") -> None:
    """A phone order for pickup is rung in at a terminal and marked ready."""
    made = [
        op(f"{order_id}-a", "create", 0, order_id, order_type="takeout", customer_name="Pat", phone=phone),
        op(f"{order_id}-b", "add_line", 1, order_id, line_id="L1", item="Tea", qty=1, priced=TEA),
        op(f"{order_id}-c", "set_field", 2, order_id, stage="ready"),
    ]
    answer = api.post(f"/orders/{order_id}/ops", json=made)
    assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text


def texts_of(answer: Any) -> dict[str, Any]:
    assert answer.status_code == 200, answer.text
    return answer.json()["texts"]


def test_until_an_account_is_typed_the_texts_go_nowhere_but_the_log():
    api, twilio = wired()
    auth = token(api)
    listed = api.get("/hub/keys", headers=auth).json()
    assert listed["texts"] == {"provider": "log", "sender": "", "day": None, "last_failed": None}
    key = next(k for k in listed["keys"] if k["name"] == TEXTS)
    assert (key["set"], key["source"], key["shown"]) == (False, None, {})
    pickup_made_ready(api)
    assert twilio.posts == []
    assert [m["kind"] for m in api.get("/messages").json()["messages"]] == ["ready"]


def test_a_manager_types_the_twilio_account_and_the_ready_text_really_goes():
    api, twilio = wired()
    auth = token(api)
    saved = api.put("/hub/keys/texts", json=TYPED, headers=auth)
    assert texts_of(saved) == {
        "provider": "twilio",
        "sender": FROM,
        "day": {"texts": 0, "delivered": 0, "failed": 0},
        "last_failed": None,
    }
    key = next(k for k in saved.json()["keys"] if k["name"] == TEXTS)
    assert (key["set"], key["source"], key["by"]) == (True, "app", "Mike")
    assert key["shown"] == {"account": ACCOUNT, "sender": FROM, "key_sid": ""} and key["ending"] == ""
    assert TOKEN not in saved.text, "the token is never told back"
    assert TOKEN.encode() not in api.app.state.keys.store.all()[TEXTS].sealed, "and is sealed where it is kept"
    # no restart: the next order made ready is texted through Twilio
    pickup_made_ready(api)
    messenger = api.app.state.messenger
    assert isinstance(messenger, TwilioMessenger) and api.app.state.notifier.messenger is messenger
    assert messenger.run_due() == 1
    assert twilio.posts == [
        {"To": PAT, "From": FROM, "Body": "Hi Pat, order #1 is ready for pickup at China Sky. Please pay at pickup."}
    ]
    assert texts_of(api.get("/hub/keys", headers=auth))["day"] == {"texts": 1, "delivered": 0, "failed": 0}
    # and what a hub with a texting service lists of its texts is nothing: no number is kept to show
    assert api.get("/messages").json() == {"messages": [], "provider": "TwilioMessenger"}


def test_the_same_account_typed_again_keeps_the_messenger_and_another_exchanges_it():
    api, twilio = wired()
    auth = token(api)
    api.put("/hub/keys/texts", json=TYPED, headers=auth)
    first = api.app.state.messenger
    api.put("/hub/keys/texts", json={**TYPED, "sender": "+1 (781) 555-0100"}, headers=auth)
    assert api.app.state.messenger is first, "what it knows of the day's texts is kept"
    api.put("/hub/keys/maps", json={"key": "made-up-geocodio-key-0123456789abcd"}, headers=auth)
    assert api.app.state.messenger is first, "another key's change does not touch it"
    api.put("/hub/keys/texts", json={**TYPED, "sender": SERVICE}, headers=auth)
    second = api.app.state.messenger
    assert second is not first and second.config.sender == SERVICE
    assert api.app.state.notifier.messenger is second
    first.send(text())  # the old one takes nothing more
    assert first.waiting == 0


def test_with_the_account_removed_the_texts_go_nowhere_again():
    api, twilio = wired()
    auth = token(api)
    api.put("/hub/keys/texts", json=TYPED, headers=auth)
    gone = api.delete("/hub/keys/texts", headers=auth)
    assert texts_of(gone)["provider"] == "log"
    key = next(k for k in gone.json()["keys"] if k["name"] == TEXTS)
    assert (key["set"], key["removed"]) == (False, True)
    pickup_made_ready(api)
    assert twilio.posts == [] and isinstance(api.app.state.messenger, LogMessenger)


def test_what_is_wrong_with_the_account_is_said_without_it_and_nothing_changes():
    api, _ = wired()
    auth = token(api)
    for bad in ({**TYPED, "account": "ACnot-an-account"}, {**TYPED, "key": "not a token at all"}, {"key": TOKEN}):
        refused = api.put("/hub/keys/texts", json=bad, headers=auth)
        assert refused.status_code == 422 and refused.json()["detail"]["error"] == "bad_value"
        assert TOKEN not in refused.text and "not a token" not in refused.text and "not-an-account" not in refused.text
    assert isinstance(api.app.state.messenger, LogMessenger)
    assert TEXTS not in api.app.state.keys.store.all()


def test_the_account_and_the_try_are_a_manager_s_and_nobody_else_s():
    api, twilio = wired()
    # a server's own session (servers take tables, so the hub gives them one for that) opens none of it
    session = api.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"})
    assert session.status_code == 200 and session.json()["role"] == "server"
    server = {"authorization": f"Bearer {session.json()['token']}"}
    for auth, refused in (({}, 401), (server, 403)):
        assert api.put("/hub/keys/texts", json=TYPED, headers=auth).status_code == refused
        assert api.delete("/hub/keys/texts", headers=auth).status_code == refused
        assert api.post("/hub/texts/try", json={"to": PAT}, headers=auth).status_code == refused
    assert twilio.posts == [] and isinstance(api.app.state.messenger, LogMessenger)


def test_a_manager_tries_the_account_with_one_text_to_a_number_of_their_own():
    api, twilio = wired()
    auth = token(api)
    none = api.post("/hub/texts/try", json={"to": "781 555 0142"}, headers=auth)
    assert none.status_code == 409 and none.json()["detail"]["error"] == "no_service"
    api.put("/hub/keys/texts", json=TYPED, headers=auth)
    tried = api.post("/hub/texts/try", json={"to": "781 555 0142"}, headers=auth)
    assert tried.status_code == 200 and tried.json()["tried"] == {
        "ok": True,
        "state": "delivered",
        "code": None,
        "said": "",
    }
    assert twilio.posts == [
        {"To": PAT, "From": FROM, "Body": "A test from the POS at China Sky: texts to customers are working."}
    ]
    assert "0142" not in tried.text, "the number is used for the one text and told back nowhere"
    assert tried.json()["texts"]["day"]["texts"] == 0, "a try is none of the day's texts to customers"
    # what is no number is said so, and Twilio is not asked
    for bad in ("", "   ", "555 0142", "9" * 60):
        refused = api.post("/hub/texts/try", json={"to": bad}, headers=auth)
        if refused.status_code == 200:
            assert refused.json()["tried"]["said"] == "that is not a phone number a text can go to"
        else:
            assert refused.status_code == 422 and refused.json()["detail"]["error"] == "bad_value"
    assert len(twilio.posts) == 1


@pytest.mark.parametrize(
    ("twilio", "state", "code", "words"),
    [
        (FakeTwilio((401, 20003)), "failed", 20003, "Twilio does not know the key"),
        (FakeTwilio((400, 21608)), "failed", 21608, "this Twilio account is a trial"),
        (FakeTwilio(became=("undelivered", 30034)), "failed", 30034, "not registered for business texts yet"),
        (FakeTwilio(httpx.ConnectError("down")), "failed", None, "Twilio could not be reached"),
        (FakeTwilio(became=("sent", None)), "sent", None, ""),
    ],
)
def test_a_try_says_why_the_text_did_not_go(twilio, state, code, words):
    api, _ = wired(twilio)
    auth = token(api)
    api.put("/hub/keys/texts", json=TYPED, headers=auth)
    tried = api.post("/hub/texts/try", json={"to": PAT}, headers=auth).json()["tried"]
    assert (tried["ok"], tried["state"], tried["code"]) == (state != "failed", state, code)
    assert words in tried["said"]


def test_the_last_text_that_failed_is_named_by_its_order_s_number():
    api, _ = wired(FakeTwilio((400, 21610)))
    auth = token(api)
    api.put("/hub/keys/texts", json=TYPED, headers=auth)
    pickup_made_ready(api, "o7")
    api.app.state.messenger.run_due()
    listed = api.get("/hub/keys", headers=auth)
    failed = texts_of(listed)["last_failed"]
    assert (failed["order_id"], failed["order_no"], failed["kind"], failed["code"]) == ("o7", 1, "ready", 21610)
    assert failed["said"].startswith("the customer answered STOP to an earlier text")
    assert "0142" not in listed.text and "Pat" not in listed.text


def test_a_hub_notices_an_account_typed_on_the_other_hub():
    store = KeyStore()
    api, twilio = wired(keys=hub_keys(store))
    assert isinstance(api.app.state.messenger, LogMessenger)
    hub_keys(store).set(TEXTS, TYPED, by="Mike")  # typed on the location's other hub
    asyncio.run(use_keys(api.app))  # what the hub's look once a minute does when the keys changed
    assert isinstance(api.app.state.messenger, TwilioMessenger)
    pickup_made_ready(api)
    api.app.state.messenger.run_due()
    assert [post["To"] for post in twilio.posts] == [PAT]


def test_a_hub_that_starts_with_an_account_texts_through_it_from_the_first_order():
    keys = hub_keys()
    keys.set(TEXTS, TYPED, by="Mike")
    api, _ = wired(keys=keys)
    messenger = api.app.state.messenger
    assert isinstance(messenger, TwilioMessenger) and messenger.config == TwilioConfig(ACCOUNT, TOKEN, FROM)
    assert api.app.state.notifier.messenger is messenger
    messenger.close()


def test_a_messenger_the_hub_was_handed_is_never_exchanged():
    mine = LogMessenger()
    api, twilio = wired(messenger=mine)
    api.put("/hub/keys/texts", json=TYPED, headers=token(api))
    assert api.app.state.messenger is mine
    pickup_made_ready(api)
    assert twilio.posts == [] and [m.kind for m in mine.sent] == ["ready"]
