"""Twilio's way in (`pos.online.twilio_way`, docs/text-inbox.md, "Instant delivery and pictures"): Twilio calls
the hub the moment a text comes or changes, and fetches from it the pictures the staff send. Its calls come
through the push door under a word the hub makes itself, and nothing of a call is believed but which text it
is about. Twilio, the door's street and the internet are stood in for; nothing here reaches the internet,
and the account and the numbers are made up."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.api.keys import twilio_at_door, twilio_outside, use_keys
from pos.keys import SLOTS, TEXTS_WAY, HubKeys
from pos.maps import Lookups
from pos.menu.service import MenuService, load_definitions
from pos.online.door import KEY_FILE, TWILIO_FILE, Door, door_from_env
from pos.online.service import OnlineOrders
from pos.online.tunnel import digest_of
from pos.online.twilio_way import CALL_MOST, PATHS, PICTURE_FOR_SECONDS, TWIML, Knocks, TwilioWay, clean, hush, make
from pos.online.wayin import WayIn
from pos.orders.numbers import OrderNumbers
from pos.printing.service import PrintService
from pos.push.devices import PushDevices
from pos.push.relay import PushRelay
from pos.settings import SettingStore
from pos.sync.oplog import OpStore
from pos.tax import massachusetts
from pos.texts import HEARD_A_MINUTE, OWN, SEND_BYTES, SEND_MOST, Refused, Texts, picture_kind
from pos.twilio import said_of

from .test_text_inbox import ACCOUNT, FROM, LEE, NOW_MS, OTHER, PAT, T0, TOKEN, FakeTwilio, hub_keys, row, sid, staff

DSN = os.environ.get("POS_TEST_DATABASE_URL")

ADDRESS = "pos.example.com"
JPEG = b"\xff\xd8\xff\xe0" + b"a picture of the lunch menu " * 8
PNG = b"\x89PNG\r\n\x1a\n" + b"a map of where to park " * 8
GIF = b"GIF89a" + b"the dragon dances " * 8
AMY = {"staff_id": "s1"}
XML = "text/xml; charset=utf-8"


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


class Calling(FakeTwilio):
    """Twilio as it answers when it is asked for one text by its name, and as it takes a text with
    pictures: every address it was given for one is kept."""

    def __init__(self, *messages: dict[str, Any]) -> None:
        super().__init__(*messages)
        self.ones: list[str] = []
        self.forms: list[dict[str, list[str]]] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        base = f"/2010-04-01/Accounts/{ACCOUNT}/Messages"
        path = request.url.path
        if not self.down and request.method == "POST" and path == f"{base}.json":
            self.forms.append(parse_qs(request.content.decode()))
        found = re.fullmatch(re.escape(base) + r"/((?:SM|MM)[0-9a-f]{32})\.json", path)
        if not self.down and request.method == "GET" and found is not None:
            self.ones.append(found[1])
            for message in self.messages:
                if message["sid"] == found[1]:
                    return httpx.Response(200, json=message)
            if found[1] not in {sid(900 + n) for n in range(1, len(self.posts) + 1)}:
                return httpx.Response(404, json={"code": 20404})
        return super().__call__(request)


class World(httpx.AsyncBaseTransport):
    """Everything the hub can reach when it tries its own way in: its door, and the internet. `leads` says
    what each name on the internet leads to: the hub's door (`door`), or somebody else's answer."""

    def __init__(self) -> None:
        self.door: httpx.ASGITransport | None = None
        self.leads: dict[str, object] = {}
        self.calls: list[httpx.Request] = []

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        to: object = None
        if (request.url.scheme, request.url.host, request.url.port) == ("http", "door", 8090):
            to = "door"
        elif request.url.scheme == "https" and request.url.port is None:
            to = self.leads.get(request.url.host)
        if to == "door" and self.door is not None:
            return await self.door.handle_async_request(request)
        if isinstance(to, httpx.Response):
            return to
        if isinstance(to, Exception):
            raise to
        raise httpx.ConnectError("nothing answers there")


class Rig:
    """A hub with a Twilio account typed in the app, a push door in front of it and a street outside the
    door: `street` is where Twilio and everybody else on the internet come from. The clock is moved by
    hand, and the hub's texts go out when the test works the line."""

    def __init__(self, tmp_path, twilio: Calling | None = None, *, door: bool = True, account: bool = True) -> None:
        self.twilio = twilio if twilio is not None else Calling()
        self.now = float(T0)
        self.door_dir = tmp_path / "door"
        self.door_dir.mkdir()
        self.world = World()
        self.wayin = WayIn(self.door_dir, None, client=httpx.AsyncClient(transport=self.world))
        store = OpStore(physical=lambda: int(self.now * 1000))
        self.keys = hub_keys()
        self.app = create_app(
            store,
            staff=staff(),
            menu=MenuService(load_definitions("restaurant")),
            taxes=massachusetts(),
            printing=PrintService([]),
            settings=SettingStore(),
            numbers=OrderNumbers(store),
            keys=self.keys,
            wayin=self.wayin,
            lookups=Lookups(),
            online=OnlineOrders(None),
            relay=PushRelay(PushDevices(), None),
            location="China Sky",
        )
        self.app.state.texts_made_with = {
            "transport": self.twilio.transport,
            "background": False,
            "sleep": lambda seconds: None,
            "now": lambda: self.now,
        }
        self.api = TestClient(self.app)
        token = self.api.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
        self.auth = {"authorization": f"Bearer {token}"}
        inside = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app))
        self.inside_calls: list[str] = []
        self.the_door = Door(
            to="http://api:8000",
            told=self.door_dir / KEY_FILE,
            twilio=self.door_dir / TWILIO_FILE,
            client=inside,
        )
        if door:
            self.world.door = httpx.ASGITransport(app=self.the_door)
        self.world.leads = {ADDRESS: "door"}
        self.street = TestClient(self.the_door)
        if account:
            typed = {"account": ACCOUNT, "key": TOKEN, "sender": "781 555 0100"}
            assert self.api.put("/hub/keys/texts", json=typed, headers=self.auth).status_code == 200

    # -- what a manager does

    def address(self, name: str = ADDRESS) -> None:
        assert self.api.put("/hub/online/push/address", json={"address": name}, headers=self.auth).status_code == 200

    def on(self, **body: Any) -> dict[str, Any]:
        answer = self.api.post("/hub/texts/way", json=body or None, headers=self.auth)
        assert answer.status_code == 200, answer.text
        return answer.json()

    def ready(self) -> str:
        """The address is typed and the way in turned on: gives the hub's word for Twilio."""
        self.address()
        url = self.on()["texts_way"]["url"]
        return url.split("/")[4]

    def way(self) -> dict[str, Any]:
        return self.api.get("/hub/keys", headers=self.auth).json()["texts_way"]

    # -- what Twilio does

    def calls(self, word: str, what: str = "text", **form: str) -> httpx.Response:
        return self.street.post(f"/twilio/{word}/{what}", data=form)

    # -- what the staff do and see

    def say(self, body: str = "", to: str = PAT, **more: Any) -> httpx.Response:
        return self.api.post(f"/texts/with/{to}", json={**AMY, "body": body, **more})

    def work(self, seconds: float = 0.0) -> int:
        self.now += seconds
        return self.app.state.messenger.run_due()

    def texts(self, phone: str = PAT) -> list[dict[str, Any]]:
        return self.api.get(f"/texts/with/{phone}", params=AMY).json()["texts"]

    def can_send_pictures(self) -> bool:
        return self.api.get("/texts", params=AMY).json()["send"]["pictures"]


# --- the hub's word and the addresses it makes --------------------------------------------------------------


def test_the_hub_makes_its_own_word_and_nothing_typed_is_taken_for_one():
    one, other = make(), make()
    assert one != other and clean(one) == one
    assert all(re.fullmatch(r"[A-Za-z0-9_-]{43}", part) for part in one.values())
    for typed in (
        {},
        {"key": one["key"]},
        {"key": "short", "seal": one["seal"]},
        {"key": "a b" * 20, "seal": "x"},
        "x",
    ):
        with pytest.raises(ValueError) as said:
            clean(typed)
        assert one["key"] not in str(said.value)


def test_every_address_for_twilio_carries_the_word_and_a_picture_s_is_good_for_an_hour_and_only_as_made():
    held = make()
    way = TwilioWay(ADDRESS, held["key"], held["seal"])
    assert way.text_url == f"https://{ADDRESS}/twilio/{held['key']}/text"
    assert way.status_url == f"https://{ADDRESS}/twilio/{held['key']}/status"
    url = way.picture_url("0123abcd4567", 2, T0)
    path = url.removeprefix(f"https://{ADDRESS}")
    found = PATHS.fullmatch(path)
    assert found is not None and found[1] == held["key"], "the door knows the path for one of Twilio's"
    _, _, _, _, text_id, n, until, mark = path.split("/")
    assert (text_id, n, int(until)) == ("0123abcd4567", "2", T0 + PICTURE_FOR_SECONDS)
    assert way.good(text_id, 2, int(until), mark, T0 + 3599)
    assert not way.good(text_id, 2, int(until), mark, T0 + 3601), "an hour on it is good no more"
    assert not way.good(text_id, 1, int(until), mark, T0), "another picture's"
    assert not way.good("0123abcd4568", 2, int(until), mark, T0), "another text's"
    assert not way.good(text_id, 2, int(until) + 86400, mark, T0), "made to last longer"
    other = TwilioWay(ADDRESS, held["key"], make()["seal"])
    assert not other.good(text_id, 2, int(until), mark, T0), "the word alone does not make a picture's address"
    assert held["key"] not in repr(way) and held["seal"] not in repr(way)


@pytest.mark.parametrize(
    "path",
    [
        "/twilio/text",
        "/twilio/short/text",
        "/twilio/{w}/texts",
        "/twilio/{w}/text/",
        "/twilio/{w}/media",
        "/twilio/{w}/media/0123abcd4567/0/1800003600",
        "/twilio/{w}/media/../../orders/0/1800003600/" + "m" * 43,
        "/twilio/{w}/../orders",
        "/orders",
    ],
)
def test_no_other_path_is_one_of_twilio_s(path):
    assert PATHS.fullmatch(path.replace("{w}", "w" * 43)) is None


def test_the_word_is_taken_out_of_a_server_s_line_about_a_call():
    word = make()["key"]
    name = "a-test-of-the-lines-about-calls"
    hush(name)
    hush(name)
    lines = logging.getLogger(name)
    assert len(lines.filters) == 1, "told twice, it is hushed once"
    record = logging.LogRecord(
        name,
        logging.INFO,
        __file__,
        1,
        '%s - "%s %s HTTP/%s" %d',
        ("1.2.3.4:5", "POST", f"/twilio/{word}/text", "1.1", 200),
        None,
    )
    assert lines.filter(record)
    assert word not in record.getMessage() and '"POST /twilio/-/text HTTP/1.1" 200' in record.getMessage()


# --- the door -----------------------------------------------------------------------------------------------


class Api(httpx.AsyncBaseTransport):
    """An API behind a door, which answers what the test tells it to and keeps what reached it."""

    def __init__(self) -> None:
        self.calls: list[httpx.Request] = []
        self.answer = httpx.Response(200, content=TWIML, headers={"content-type": "text/xml"})

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        await request.aread()
        self.calls.append(request)
        return self.answer


def a_door(tmp_path, word: str | None) -> tuple[TestClient, Api]:
    api = Api()
    told = tmp_path / TWILIO_FILE
    if word is not None:
        told.write_text(json.dumps({"sha256": digest_of(word)}))
    door = Door(to="http://api:8000", told=tmp_path / KEY_FILE, twilio=told, client=httpx.AsyncClient(transport=api))
    return TestClient(door), api


def test_the_door_lets_a_call_of_twilio_s_in_under_the_hub_s_word_and_hands_back_only_nothing_to_send(tmp_path):
    word = make()["key"]
    street, api = a_door(tmp_path, word)
    api.answer = httpx.Response(200, content=b"<Response><Message>whatever the API said</Message></Response>")
    for what in ("text", "status"):
        answer = street.post(f"/twilio/{word}/{what}", data={"MessageSid": sid(1), "Body": "hello"})
        assert (answer.status_code, answer.content, answer.headers["content-type"]) == (200, TWIML, XML)
    assert [(c.method, str(c.url)) for c in api.calls] == [
        ("POST", f"http://api:8000/twilio/{word}/text"),
        ("POST", f"http://api:8000/twilio/{word}/status"),
    ]
    assert parse_qs(api.calls[0].content.decode()) == {"MessageSid": [sid(1)], "Body": ["hello"]}
    assert "authorization" not in api.calls[0].headers and "cookie" not in api.calls[0].headers


def test_the_door_is_shut_to_every_other_word_method_and_path_and_never_holds_the_word(tmp_path):
    word = make()["key"]
    street, api = a_door(tmp_path, word)
    other = make()["key"]
    mark = "m" * 43
    tried = [
        ("POST", f"/twilio/{other}/text"),
        ("POST", f"/twilio/{word[:-1]}/text"),
        ("GET", f"/twilio/{word}/text"),
        ("PUT", f"/twilio/{word}/status"),
        ("DELETE", f"/twilio/{word}/status"),
        ("POST", f"/twilio/{word}/media/0123abcd4567/0/{T0}/{mark}"),
        ("GET", f"/twilio/{other}/media/0123abcd4567/0/{T0}/{mark}"),
        ("POST", f"/twilio/{word}/text/more"),
        ("POST", f"/twilio/{word}/orders"),
        ("GET", "/twilio"),
        ("GET", f"/texts/with/{PAT}"),
        ("GET", "/hub/keys"),
    ]
    for method, path in tried:
        answer = street.request(method, path, data={"MessageSid": sid(1)} if method == "POST" else None)
        assert (answer.status_code, answer.content) == (404, b""), (method, path)
    assert api.calls == [], "none of them reached the API"
    assert word not in (tmp_path / TWILIO_FILE).read_text(), "the door is told the word's SHA-256, not the word"


def test_a_door_that_was_told_no_word_lets_no_call_of_twilio_s_in(tmp_path):
    word = make()["key"]
    for told in (None, "", "{", json.dumps({"sha256": None}), json.dumps({"sha256": word})):
        street, api = a_door(tmp_path, None)
        if told is not None:
            (tmp_path / TWILIO_FILE).write_text(told)
        assert street.post(f"/twilio/{word}/text", data={"MessageSid": sid(1)}).status_code == 404, told
        assert api.calls == []
    # and a door that is not told where to look for one at all (an older set-up)
    door = Door(to="http://api:8000", key="a-key-for-pushes-000001", client=httpx.AsyncClient(transport=Api()))
    assert TestClient(door).post(f"/twilio/{word}/text", data={}).status_code == 404


def test_the_door_takes_no_more_of_a_call_than_twilio_s_weigh_and_says_only_a_number_when_the_api_does_not_answer(
    tmp_path,
):
    word = make()["key"]
    street, api = a_door(tmp_path, word)
    big = street.post(f"/twilio/{word}/text", data={"Body": "x" * (CALL_MOST + 1)})
    assert (big.status_code, big.content) == (413, b"") and api.calls == []
    for inside, outside in ((404, 404), (403, 403), (500, 502), (301, 502), (401, 502)):
        api.answer = httpx.Response(inside, content=b"what went wrong inside, in words")
        answer = street.post(f"/twilio/{word}/text", data={"MessageSid": sid(1)})
        assert (answer.status_code, answer.content) == (outside, b""), inside


def test_the_door_hands_out_a_picture_and_nothing_that_is_not_one(tmp_path):
    word = make()["key"]
    street, api = a_door(tmp_path, word)
    path = f"/twilio/{word}/media/0123abcd4567/0/{T0}/{'m' * 43}"
    api.answer = httpx.Response(200, content=JPEG, headers={"content-type": "image/jpeg"})
    got = street.get(path)
    assert (got.status_code, got.content, got.headers["content-type"]) == (200, JPEG, "image/jpeg")
    assert got.headers["x-content-type-options"] == "nosniff" and "no-store" in got.headers["cache-control"]
    head = street.head(path)  # Twilio looks at what a picture is before it fetches it
    assert (head.status_code, head.headers["content-type"], head.headers["content-length"]) == (
        200,
        "image/jpeg",
        str(len(JPEG)),
    )
    assert [c.method for c in api.calls] == ["GET", "GET"]
    for kind in ("application/json", "text/html", "image/svg+xml", ""):
        api.answer = httpx.Response(200, content=b'{"orders": []}', headers={"content-type": kind} if kind else {})
        assert (street.get(path).status_code, street.get(path).content) == (502, b""), kind


def test_the_hub_s_door_looks_for_the_word_beside_the_key_for_pushes(tmp_path):
    word = make()["key"]
    (tmp_path / TWILIO_FILE).write_text(json.dumps({"sha256": digest_of(word)}))
    door = door_from_env({"POS_DOOR_DIR": str(tmp_path), "POS_DOOR_TO": "http://127.0.0.1:9"})
    street = TestClient(door)
    assert street.post(f"/twilio/{make()['key']}/text", data={}).status_code == 404
    assert street.post(f"/twilio/{word}/text", data={}).status_code == 502, "let in, and no API answers there"


# --- turned on by a manager ---------------------------------------------------------------------------------


def test_twilio_s_way_in_is_a_manager_s_to_turn_on_and_needs_a_twilio_account(tmp_path):
    rig = Rig(tmp_path, account=False)
    for call in (
        rig.api.post("/hub/texts/way"),
        rig.api.delete("/hub/texts/way"),
        rig.api.post("/hub/texts/way/try"),
        rig.api.post("/hub/texts/way", headers={"authorization": "Bearer made-up"}),
    ):
        assert call.status_code == 401
    refused = rig.api.post("/hub/texts/way", headers=rig.auth)
    assert (refused.status_code, refused.json()["detail"]["error"]) == (409, "no_service")
    assert rig.way() == {"on": False, "address": "", "url": None, "door": None, "called_ms": None}


def test_turned_on_the_hub_makes_its_word_tells_the_door_and_shows_the_manager_the_address_for_twilio(tmp_path):
    rig = Rig(tmp_path)
    assert rig.can_send_pictures() is False
    on = rig.on()["texts_way"]
    assert on == {"on": True, "address": "", "url": None, "door": True, "called_ms": None}, "no name yet: no address"
    assert rig.can_send_pictures() is False, "without a name on the internet Twilio has nowhere to fetch from"
    rig.address()
    way = rig.way()
    found = re.fullmatch(rf"https://{re.escape(ADDRESS)}/twilio/([A-Za-z0-9_-]{{43}})/text", way["url"])
    assert found is not None and way["address"] == ADDRESS
    word = found[1]
    assert rig.can_send_pictures() is True
    # the door has the word's SHA-256 and the database its seal: neither holds the word
    assert json.loads((rig.door_dir / TWILIO_FILE).read_text()) == {"sha256": digest_of(word)}
    kept = rig.keys.store.all()[TEXTS_WAY]
    assert word.encode() not in kept.sealed and kept.ending == "" and kept.shown == {} and kept.by == "Mike"
    # it is on no list of keys, and no key's call sets or removes it
    listed = rig.api.get("/hub/keys", headers=rig.auth).json()
    assert TEXTS_WAY not in [key["name"] for key in listed["keys"]] and TEXTS_WAY not in SLOTS
    assert word not in json.dumps({**listed, "texts_way": None})
    typed = {"key": make()["key"], "seal": make()["seal"]}
    assert rig.api.put(f"/hub/keys/{TEXTS_WAY}", json=typed, headers=rig.auth).status_code == 404
    assert rig.api.delete(f"/hub/keys/{TEXTS_WAY}", headers=rig.auth).status_code == 404
    # turned on a second time it is the same address; asked for a new one, the old one is dead at the door
    assert rig.on()["texts_way"]["url"] == way["url"]
    assert rig.calls(word, MessageSid=sid(1)).status_code == 200
    fresh = rig.on(again=True)["texts_way"]["url"]
    assert fresh != way["url"]
    assert rig.calls(word, MessageSid=sid(1)).status_code == 404
    assert rig.calls(fresh.split("/")[4], MessageSid=sid(1)).status_code == 200


def test_turned_off_the_word_is_forgotten_the_door_is_shut_and_a_text_carries_no_picture(tmp_path):
    rig = Rig(tmp_path)
    word = rig.ready()
    off = rig.api.delete("/hub/texts/way", headers=rig.auth).json()["texts_way"]
    assert off == {"on": False, "address": ADDRESS, "url": None, "door": True, "called_ms": None}
    assert json.loads((rig.door_dir / TWILIO_FILE).read_text()) == {"sha256": None}
    assert TEXTS_WAY not in rig.keys.store.all()
    assert rig.calls(word, MessageSid=sid(1)).status_code == 404
    assert rig.api.post(f"/twilio/{word}/text", data={"MessageSid": sid(1)}).status_code == 404, "nor at the API"
    assert rig.can_send_pictures() is False
    refused = rig.say("The menu", pictures=[b64(JPEG)])
    assert (refused.status_code, refused.json()["detail"]["error"]) == (409, "no_way")
    assert rig.texts() == [] and rig.twilio.posts == []


def test_a_word_made_on_the_location_s_other_hub_is_found_and_handed_to_this_hub_s_door(tmp_path):
    rig = Rig(tmp_path)
    rig.address()
    other = HubKeys(rig.keys.store, rig.keys.vault, environ={}, now=lambda: NOW_MS + 5)
    held = make()
    other.set(TEXTS_WAY, held, by="Mike")
    assert rig.way()["on"] is False, "this hub has not looked yet"
    asyncio.run(use_keys(rig.app))  # what a hub does within the minute when the keys changed under it
    assert rig.way()["url"] == f"https://{ADDRESS}/twilio/{held['key']}/text"
    assert rig.calls(held["key"], MessageSid=sid(1)).status_code == 200


# --- a text shows the moment it comes ------------------------------------------------------------------------


def test_twilio_calls_and_the_text_is_there_at_once_as_twilio_itself_describes_it(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "Can I order for pickup?")))
    word = rig.ready()
    told: list[str] = []
    rig.app.state.feed.changed = told.append
    # the call says other words and another sender: nothing of it is believed but which text it is about
    answer = rig.calls(word, MessageSid=sid(1), From=LEE, To=FROM, Body="FREE EGG ROLLS FOR LEE", NumMedia="0")
    assert (answer.status_code, answer.content, answer.headers["content-type"]) == (200, TWIML, XML)
    assert rig.twilio.ones == [sid(1)], "the hub asked Twilio for that one text"
    assert rig.twilio.lists == [], "and did not wait for its next asking"
    (text,) = rig.texts()
    assert (text["body"], text["inbound"], text["state"]) == ("Can I order for pickup?", True, "received")
    assert rig.api.get(f"/texts/with/{LEE}", params=AMY).json()["texts"] == []
    assert told == ["texts"], "the screens are told"
    assert rig.way()["called_ms"] == NOW_MS
    # Twilio calls twice about the same text, and the hub's own asking finds it too: it is here once
    rig.calls(word, MessageSid=sid(1))
    assert rig.app.state.text_listener.round() == 0
    assert len(rig.texts()) == 1 and told == ["texts"]


def test_a_call_about_a_text_twilio_does_not_know_or_that_is_another_number_s_puts_nothing_on_the_pos(tmp_path):
    fax = row(2, "A fax, really", ours=OTHER)
    rig = Rig(tmp_path, Calling(fax))
    word = rig.ready()
    assert rig.calls(word, MessageSid=sid(77), From=PAT, Body="I am not a text").status_code == 200
    assert rig.calls(word, MessageSid=sid(2), From=PAT, Body="A fax, really").status_code == 200
    assert rig.calls(word, MessageSid="not-a-name-of-twilio-s", From=PAT, Body="x").status_code == 200
    assert rig.calls(word, Body="no name at all").status_code == 200
    assert rig.twilio.ones == [sid(77), sid(2)], "only what could be a text's name is asked about"
    assert rig.api.get("/texts", params=AMY).json()["threads"] == []


def test_a_text_with_a_picture_that_twilio_calls_about_lists_its_pictures(tmp_path):
    twilio = Calling(row(3, "Is this the dish?", pictures=1))
    twilio.pictures[sid(3, "MM")] = [(sid(9, "ME"), "image/jpeg", JPEG)]
    rig = Rig(tmp_path, twilio)
    word = rig.ready()
    rig.calls(word, MessageSid=sid(3, "MM"), NumMedia="1", MediaUrl0="https://elsewhere.example/x.jpg")
    (text,) = rig.texts()
    assert (text["channel"], text["pictures"]) == ("mms", [{"n": 0, "type": "image/jpeg", "image": True}])
    shown = rig.api.get(f"/texts/picture/{text['id']}/0", params=AMY)
    assert (shown.status_code, shown.content) == (200, JPEG), "from Twilio, never from the address in the call"


def test_nobody_gets_the_hub_to_ask_twilio_without_end(tmp_path):
    rig = Rig(tmp_path)
    word = rig.ready()
    for n in range(HEARD_A_MINUTE + 30):
        assert rig.calls(word, MessageSid=sid(1000 + n)).status_code == 200
    assert len(rig.twilio.ones) == HEARD_A_MINUTE
    rig.now += 61
    rig.twilio.add(row(5, "Still open?"))
    rig.calls(word, MessageSid=sid(5))
    assert [t["body"] for t in rig.texts()] == ["Still open?"], "a minute on it asks again"


def test_a_call_is_answered_whatever_twilio_does_and_the_asking_stays_as_the_net(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "Hello?")))
    word = rig.ready()
    rig.twilio.down = True
    assert rig.calls(word, MessageSid=sid(1)).status_code == 200, "Twilio is answered all the same"
    assert rig.texts() == []
    rig.twilio.down = False
    assert rig.app.state.text_listener.round() == 1, "the next asking has it"
    assert [t["body"] for t in rig.texts()] == ["Hello?"]


def test_the_api_itself_takes_a_call_only_under_the_word_and_no_bigger_than_twilio_s(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "Hello?")))
    word = rig.ready()
    other = make()["key"]
    for path in (f"/twilio/{other}/text", f"/twilio/{other}/status", f"/twilio/{word}x/text"):
        answer = rig.api.post(path, data={"MessageSid": sid(1)})
        assert (answer.status_code, answer.content) == (404, b""), path
    assert rig.api.post(f"/twilio/{word}/text", data={"Body": "x" * (CALL_MOST + 1)}).status_code == 413
    assert rig.twilio.ones == [] and rig.texts() == []
    assert "/twilio" not in json.dumps(rig.api.get("/openapi.json").json()), "they are on no list of the API's calls"


# --- what became of a text is told, not asked ----------------------------------------------------------------


def test_every_text_goes_out_with_where_twilio_is_to_say_what_became_of_it_and_delivered_shows_at_once(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "Can I order for pickup?")))
    word = rig.ready()
    rig.calls(word, MessageSid=sid(1))
    assert rig.say("Sure, what would you like?").status_code == 200
    assert rig.work() == 1
    (form,) = rig.twilio.forms
    assert form["StatusCallback"] == [f"https://{ADDRESS}/twilio/{word}/status"]
    assert rig.texts()[-1]["state"] == "sent"
    # the phone company says it arrived: Twilio calls, the hub asks for that text, and it is delivered
    rig.twilio.add(row(901, "Sure, what would you like?", inbound=False, status="delivered"))
    answer = rig.calls(word, "status", MessageSid=sid(901), MessageStatus="delivered")
    assert (answer.status_code, answer.content) == (200, TWIML)
    assert rig.texts()[-1]["state"] == "delivered"
    assert rig.twilio.ones == [sid(1), sid(901)]
    # a call that says more than Twilio does is not believed
    rig.calls(word, "status", MessageSid=sid(901), MessageStatus="read")
    assert rig.texts()[-1]["state"] == "delivered"


def test_a_text_that_was_not_delivered_says_why_as_soon_as_twilio_calls(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "Hi")))
    word = rig.ready()
    rig.calls(word, MessageSid=sid(1))
    rig.say("Hello Pat")
    rig.work()
    rig.twilio.add(row(901, "Hello Pat", inbound=False, status="undelivered", code=30003))
    rig.calls(word, "status", MessageSid=sid(901), MessageStatus="undelivered", ErrorCode="30003")
    last = rig.texts()[-1]
    assert (last["state"], last["code"]) == ("failed", 30003)


def test_without_the_way_in_no_address_goes_to_twilio_and_the_hub_asks_as_before(tmp_path):
    rig = Rig(tmp_path)
    rig.say("Hello Pat")
    rig.work()
    assert "StatusCallback" not in rig.twilio.forms[0] and "MediaUrl" not in rig.twilio.forms[0]
    rig.on()  # turned on, and still no name on the internet
    rig.say("Are you there?")
    rig.work()
    assert "StatusCallback" not in rig.twilio.forms[1]
    assert rig.work(8) >= 1 and rig.texts()[0]["state"] == "delivered", "asked a few seconds on, as always"


# --- pictures the staff send ---------------------------------------------------------------------------------


def test_a_picture_is_known_by_how_it_begins():
    assert [picture_kind(data) for data in (JPEG, PNG, GIF)] == ["image/jpeg", "image/png", "image/gif"]
    for data in (b"", b"<svg xmlns='http://www.w3.org/2000/svg'/>", b"%PDF-1.7", b"RIFF0000WEBPVP8 ", b"GIF90a"):
        assert picture_kind(data) is None


def test_a_text_goes_out_with_its_pictures_and_twilio_fetches_each_from_the_hub_through_the_door(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "What is on the lunch menu?")))
    word = rig.ready()
    rig.calls(word, MessageSid=sid(1))
    sent = rig.say("Here it is, and where to park", pictures=[b64(JPEG), b64(PNG)])
    assert sent.status_code == 200, sent.text
    text = sent.json()
    assert (text["state"], text["channel"], text["pictures_n"]) == ("waiting", "mms", 2)
    assert text["pictures"] == [
        {"n": 0, "type": "image/jpeg", "image": True},
        {"n": 1, "type": "image/png", "image": True},
    ]
    assert rig.work() == 1
    (form,) = rig.twilio.forms
    assert form["Body"] == ["Here it is, and where to park"] and form["From"] == [FROM]
    urls = form["MediaUrl"]
    assert len(urls) == 2 and all(
        url.startswith(f"https://{ADDRESS}/twilio/{word}/media/{text['id']}/") for url in urls
    )
    # Twilio comes for them the way it was told, from the internet, to the door
    for url, data, kind in zip(urls, (JPEG, PNG), ("image/jpeg", "image/png"), strict=True):
        path = url.removeprefix(f"https://{ADDRESS}")
        head = rig.street.head(path)
        assert (head.status_code, head.headers["content-type"]) == (200, kind)
        got = rig.street.get(path)
        assert (got.status_code, got.content, got.headers["content-type"]) == (200, data, kind)
    # and a screen shows the same pictures in the conversation
    last = rig.texts()[-1]
    assert (last["id"], last["state"], last["pictures_n"]) == (text["id"], "sent", 2)
    for n, data in enumerate((JPEG, PNG)):
        shown = rig.api.get(f"/texts/picture/{text['id']}/{n}", params=AMY)
        assert (shown.status_code, shown.content) == (200, data)
    # what Twilio says of the text later changes nothing of its pictures
    delivered = row(901, "Here it is, and where to park", inbound=False, status="delivered", pictures=2)
    rig.twilio.add({**delivered, "sid": sid(901)})  # under the name Twilio gave the text when it took it
    rig.calls(word, "status", MessageSid=sid(901))
    last = rig.texts()[-1]
    assert (last["state"], last["channel"], len(last["pictures"])) == ("delivered", "mms", 2)
    assert rig.twilio.asked == [], "Twilio was not asked which pictures the hub itself sent"


def test_a_picture_s_address_is_good_for_an_hour_and_only_exactly_as_the_hub_made_it(tmp_path):
    rig = Rig(tmp_path)
    word = rig.ready()
    text = rig.say("The menu", pictures=[b64(JPEG), b64(GIF)]).json()
    rig.work()
    first = rig.twilio.forms[0]["MediaUrl"][0].removeprefix(f"https://{ADDRESS}")
    _, _, _, _, text_id, n, until, mark = first.split("/")
    assert (text_id, n, int(until)) == (text["id"], "0", T0 + PICTURE_FOR_SECONDS)

    def fetch(text_id: str = text_id, n: str = n, until: str = until, mark: str = mark, word: str = word) -> int:
        return rig.street.get(f"/twilio/{word}/media/{text_id}/{n}/{until}/{mark}").status_code

    assert fetch() == 200
    assert fetch(n="1") == 404, "the other picture has its own mark"
    assert fetch(until=str(int(until) + 3600)) == 404
    assert fetch(mark=mark[:-1] + ("A" if mark[-1] != "A" else "B")) == 404
    assert fetch(text_id="0" * 32) == 404
    assert fetch(word=make()["key"]) == 404
    rig.now += PICTURE_FOR_SECONDS + 1
    assert fetch() == 404, "an hour on, the address is dead"
    # and behind the door the API says the same to whoever is in the building
    assert rig.api.get(first).status_code == 404
    rig.now -= PICTURE_FOR_SECONDS + 1
    assert rig.api.get(first).status_code == 200
    assert rig.api.get(first.replace(word, make()["key"])).status_code == 404


def test_a_picture_alone_is_a_text_and_the_first_one_still_says_who_it_is_from(tmp_path):
    rig = Rig(tmp_path, Calling(row(1, "Menu?", who=LEE)))
    word = rig.ready()
    first = rig.say("", pictures=[b64(JPEG)])
    assert first.status_code == 200 and first.json()["body"] == "China Sky\nReply STOP to opt out."
    rig.calls(word, MessageSid=sid(1))
    answer = rig.say("", to=LEE, pictures=[b64(JPEG)])
    assert answer.status_code == 200 and answer.json()["body"] == ""
    rig.work()
    assert rig.twilio.forms[0]["Body"] == ["China Sky\nReply STOP to opt out."]
    assert "Body" not in rig.twilio.forms[1] and len(rig.twilio.forms[1]["MediaUrl"]) == 1
    nothing = rig.say("  ")
    assert (nothing.status_code, nothing.json()["detail"]["error"]) == (422, "no_text")


def test_what_a_text_cannot_carry_is_refused_before_anything_is_written_down(tmp_path):
    rig = Rig(tmp_path)
    rig.ready()
    refused = {
        "bad_picture": rig.say("x", pictures=[b64(b"<svg xmlns='http://www.w3.org/2000/svg'/>")]),
        "too_big": rig.say("x", pictures=[b64(JPEG + b"\0" * (SEND_BYTES // 2))] * 2),
    }
    for code, answer in refused.items():
        assert (answer.status_code, answer.json()["detail"]["error"]) == (422, code), answer.text
    assert rig.say("x", pictures=[b64(JPEG + b"\0" * SEND_BYTES)]).status_code == 422, "one that alone is too big"
    assert rig.say("x", pictures=["not base64 at all!"]).json()["detail"]["error"] == "bad_picture"
    assert rig.say("x", pictures=[b64(JPEG)] * (SEND_MOST + 1)).status_code == 422
    assert rig.texts() == [] and rig.twilio.posts == []
    assert rig.app.state.texts.store.picture(f"{OWN}anything", 0) is None
    # the rules are the conversations' own, whoever asks
    texts = Texts(location="China Sky")
    with pytest.raises(Refused) as too_many:
        texts.compose(PAT, "x", by_id="s1", by_name="Amy", pictures=[JPEG] * (SEND_MOST + 1))
    assert too_many.value.code == "too_many"


def test_a_tap_sent_twice_is_one_text_with_its_pictures_once(tmp_path):
    rig = Rig(tmp_path)
    rig.ready()
    one = rig.say("The menu", id="screen-abc-0001", pictures=[b64(JPEG)]).json()
    two = rig.say("The menu", id="screen-abc-0001", pictures=[b64(JPEG)]).json()
    assert one["id"] == two["id"] == "screen-abc-0001"
    rig.work()
    assert len(rig.twilio.forms) == 1 and len(rig.texts()) == 1


def test_a_picture_the_hub_keeps_no_longer_is_fetched_from_twilio_which_has_it(tmp_path):
    rig = Rig(tmp_path)
    rig.ready()
    text = rig.say("The menu", pictures=[b64(JPEG)]).json()
    rig.work()
    store = rig.app.state.texts.store
    store.drop_pictures(int(rig.now * 1000) + 1)  # a month on: the hub tidied it away
    rig.twilio.pictures[sid(901)] = [(sid(8, "ME"), "image/jpeg", JPEG)]
    shown = rig.api.get(f"/texts/picture/{text['id']}/0", params=AMY)
    assert (shown.status_code, shown.content) == (200, JPEG)
    assert rig.twilio.asked == [sid(901)]
    assert store.picture(f"{OWN}{text['id']}", 0) == ("image/jpeg", JPEG), "and it is kept again"
    assert rig.api.get(f"/texts/picture/{text['id']}/0", params=AMY).status_code == 200
    assert rig.twilio.asked == [sid(901)], "Twilio is not asked a second time"
    assert rig.api.get(f"/texts/picture/{text['id']}/1", params=AMY).status_code == 404


def test_twilio_s_words_for_a_picture_it_could_not_fetch_send_the_manager_to_the_way_in():
    for code in (11200, 63019):
        assert "the way in under Keys and connections" in said_of(code)
    assert "too big" in said_of(11751) and "not a kind a text carries" in said_of(12300)


# --- trying it ------------------------------------------------------------------------------------------------


def test_a_knock_is_the_hub_s_own_for_a_minute_and_is_used_up_by_asking():
    now = [float(T0)]
    knocks = Knocks(lambda: now[0])
    word = knocks.expect()
    assert knocks.came("somebody-else's") is False and knocks.arrived("somebody-else's") is False
    assert knocks.came(word) is True and knocks.arrived(word) is True and knocks.arrived(word) is False
    late = knocks.expect()
    now[0] += 61
    assert knocks.came(late) is False and knocks.arrived(late) is False


def test_the_hub_tries_twilio_s_way_in_at_its_door_and_from_outside_and_asks_twilio_nothing(tmp_path):
    rig = Rig(tmp_path)
    off = rig.api.post("/hub/texts/way/try", headers=rig.auth)
    assert (off.status_code, off.json()["detail"]["error"]) == (409, "off")
    rig.on()
    only_door = rig.api.post("/hub/texts/way/try", headers=rig.auth).json()["way_tried"]
    assert only_door == {"door": {"ok": True, "reason": None, "code": 200}, "outside": None}
    word = rig.ready()
    rig.world.calls.clear()
    answer = rig.api.post("/hub/texts/way/try", headers=rig.auth)
    assert answer.status_code == 200
    tried = answer.json()["way_tried"]
    assert tried["door"] == {"ok": True, "reason": None, "code": 200}
    assert tried["outside"] == {"address": ADDRESS, "ok": True, "reason": None, "code": 200}
    assert [str(call.url) for call in rig.world.calls] == [
        f"http://door:8090/twilio/{word}/text",
        f"https://{ADDRESS}/twilio/{word}/text",
    ]
    assert word not in json.dumps(tried), "what a try came to does not say the word"
    assert rig.twilio.ones == [] and rig.twilio.lists == [] and rig.way()["called_ms"] is None
    assert rig.api.get("/texts", params=AMY).json()["threads"] == []


def test_what_a_try_says_when_the_way_in_does_not_lead_to_this_hub(tmp_path):
    rig = Rig(tmp_path)
    rig.ready()

    def outside(leads: object) -> dict[str, Any]:
        rig.world.leads = {ADDRESS: leads} if leads is not None else {}
        return rig.api.post("/hub/texts/way/try", headers=rig.auth).json()["way_tried"]["outside"]

    assert outside(None)["reason"] == "no_answer"
    assert outside(httpx.ReadTimeout("slow"))["reason"] == "late"
    assert outside(httpx.Response(200, content=TWIML))["reason"] == "elsewhere", "it answers, and is not this hub"
    assert outside(httpx.Response(404))["reason"] == "not_routed"
    assert outside(httpx.Response(403))["reason"] == "blocked"
    assert outside(httpx.Response(502))["reason"] == "tunnel_down"
    assert outside(httpx.Response(530))["reason"] == "tunnel_down"
    assert outside(httpx.Response(301, headers={"location": "https://elsewhere.example/"}))["reason"] == "redirect"
    assert outside(httpx.Response(418))["reason"] == "other"
    assert outside("door") == {"address": ADDRESS, "ok": True, "reason": None, "code": 200}


def test_a_try_says_when_the_door_is_not_running_or_does_not_know_the_word_and_then_knocks_nowhere_else(tmp_path):
    none = Rig(tmp_path / "a", door=False) if (tmp_path / "a").mkdir() is None else None
    assert none is not None
    none.ready()
    tried = none.api.post("/hub/texts/way/try", headers=none.auth).json()["way_tried"]
    assert tried == {"door": {"ok": False, "reason": "no_answer", "code": None}, "outside": None}
    (tmp_path / "b").mkdir()
    old = Rig(tmp_path / "b")
    old.ready()
    (old.door_dir / TWILIO_FILE).unlink()  # a door from before it could be told of Twilio's word
    tried = old.api.post("/hub/texts/way/try", headers=old.auth).json()["way_tried"]
    assert tried == {"door": {"ok": False, "reason": "shut", "code": 404}, "outside": None}
    assert len(old.world.calls) == 1


def test_how_a_knock_s_answer_is_read():
    assert twilio_at_door({"code": 200, "late": False}, True)["ok"] is True
    assert twilio_at_door({"code": 200, "late": False}, False)["reason"] == "other"
    assert twilio_at_door({"code": 504, "late": False}, False)["reason"] == "api"
    assert twilio_outside({"code": 401, "late": False}, False)["reason"] == "elsewhere"
    assert twilio_outside({"code": 522, "late": False}, False)["reason"] == "tunnel_down"


# --- PostgreSQL -----------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_a_sent_picture_is_kept_in_postgresql_with_its_text():
    import psycopg

    from pos.texts import PgTextStore

    tables = ("text_message", "text_thread", "text_picture")
    with psycopg.connect(DSN, autocommit=True) as conn:
        for table in tables:
            conn.execute(f"DROP TABLE IF EXISTS {table}")
    store = PgTextStore(DSN)
    try:
        texts = Texts(store, now=lambda: float(T0), location="China Sky")
        text, new = texts.compose(PAT, "The menu", by_id="s1", by_name="Amy", pictures=[JPEG, PNG])
        assert new and (text.channel, text.pictures_n) == ("mms", 2)
        again = PgTextStore(DSN)  # the hub after a restart
        try:
            after = Texts(again)
            kept = again.get(text.text_id)
            assert kept is not None and [p.type for p in kept.pictures] == ["image/jpeg", "image/png"]
            assert [p.sid for p in kept.pictures] == ["", ""]
            assert after.sent_picture(text.text_id, 0) == ("image/jpeg", JPEG)
            assert after.sent_picture(text.text_id, 1) == ("image/png", PNG)
            assert after.sent_picture(text.text_id, 2) is None
        finally:
            again.close()
        store.drop_pictures(T0 * 1000 + 1)
        assert texts.sent_picture(text.text_id, 0) is None
    finally:
        store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            for table in tables:
                conn.execute(f"DROP TABLE IF EXISTS {table}")
