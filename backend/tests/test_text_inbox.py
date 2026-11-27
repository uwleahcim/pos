"""Conversations by text (`pos.texts`, docs/text-inbox.md): what customers text the restaurant is written
down by their number, the staff read it, answer and start a conversation, and the POS's own texts to an
order are in the same conversation. Twilio is stood in for by a transport that answers as its pages say it
does; nothing here reaches the internet. The numbers and the account are made up."""

from __future__ import annotations

import os
from datetime import UTC, datetime
from email.utils import format_datetime
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.staff import Directory, Staff
from pos.keys import HubKeys, vault_from_env
from pos.maps import Lookups
from pos.menu.service import MenuService, load_definitions
from pos.messaging import Message
from pos.online.service import OnlineOrders
from pos.orders.numbers import OrderNumbers
from pos.printing.service import PrintService
from pos.push.devices import PushDevices
from pos.push.relay import PushRelay
from pos.settings import SettingStore
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts
from pos.texts import (
    BODY_MAX,
    HISTORY_MS,
    WINDOW_MS,
    Listener,
    Refused,
    Texts,
    TextStore,
    channel_of,
    number_of,
)
from pos.twilio import TwilioConfig, TwilioMessenger

DSN = os.environ.get("POS_TEST_DATABASE_URL")

ACCOUNT = "AC" + "0123456789abcdef" * 2
TOKEN = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
SERVICE = "MG" + "00112233445566778899aabbccddeeff"
FROM = "+17815550100"
OTHER = "+17815550111"  # another number of the same Twilio account: the fax line, say
PAT = "+17815550142"
LEE = "+17815550177"
"""Nobody's account, nobody's token and nobody's numbers (555-01xx is kept for made-up ones)."""
T0 = 1_800_000_000  # the clock of these tests, in seconds
NOW_MS = T0 * 1000


def sid(n: int, kind: str = "SM") -> str:
    """A name as Twilio gives a text (`SM`, with a picture `MM`) or a picture (`ME`), made up."""
    return kind + f"{n:032x}"


def row(
    n: int,
    body: str = "Can I order for pickup?",
    *,
    inbound: bool = True,
    who: str = PAT,
    ours: str = FROM,
    ago: float = 0.0,
    status: str | None = None,
    pictures: int = 0,
    service: str | None = None,
    code: int | None = None,
) -> dict[str, Any]:
    """A message as Twilio's list describes one: `ago` seconds before the tests' clock."""
    at = datetime.fromtimestamp(T0 - ago, UTC)
    return {
        "sid": sid(n, "MM" if pictures else "SM"),
        "direction": "inbound" if inbound else "outbound-api",
        "from": who if inbound else ours,
        "to": ours if inbound else who,
        "body": body,
        "status": status or ("received" if inbound else "delivered"),
        "num_media": str(pictures),
        "date_sent": format_datetime(at),
        "messaging_service_sid": service,
        "error_code": code,
    }


class FakeTwilio:
    """Twilio as the hub meets it for the conversations: it takes texts, lists the account's messages (the
    newest first, a page at a time), says which pictures a text carries, hands a picture over by way of
    another address, and names a Messaging Service's numbers."""

    def __init__(self, *messages: dict[str, Any], page: int = 100, by_day: bool = False) -> None:
        self.messages = list(messages)  # the newest first, as Twilio lists them
        self.page = page
        self.by_day = by_day  # goes by the day alone: hands back older messages than were asked for
        self.posts: list[dict[str, str]] = []
        self.lists: list[dict[str, str]] = []
        self.pictures: dict[str, list[tuple[str, str, bytes]]] = {}
        self.service_numbers: list[str] | None = None
        self.down = False
        self.refuse: tuple[int, int] | None = None
        self.asked: list[str] = []
        self.picture_keys: list[str] = []

    def add(self, message: dict[str, Any]) -> None:
        self.messages.insert(0, message)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if self.down:
            raise httpx.ConnectError("no route")
        path = request.url.path
        base = f"/2010-04-01/Accounts/{ACCOUNT}/Messages"
        if request.url.host == "media.example":
            # where Twilio keeps a picture: asked without the account's key
            self.picture_keys.append(request.headers.get("authorization", ""))
            for kept in self.pictures.values():
                for name, kind, data in kept:
                    if path == f"/{name}":
                        return httpx.Response(200, content=data, headers={"content-type": kind})
            return httpx.Response(404)
        if request.url.host == "messaging.twilio.com":
            if self.service_numbers is None:
                return httpx.Response(404, json={"code": 20404})
            return httpx.Response(200, json={"phone_numbers": [{"phone_number": n} for n in self.service_numbers]})
        if request.method == "POST":
            assert path == f"{base}.json", path
            self.posts.append({name: values[0] for name, values in parse_qs(request.content.decode()).items()})
            return httpx.Response(201, json={"sid": sid(900 + len(self.posts)), "status": "queued"})
        if path == f"{base}.json":
            if self.refuse is not None:
                return httpx.Response(self.refuse[0], json={"code": self.refuse[1]})
            asked = dict(request.url.params)
            self.lists.append(asked)
            since = datetime.strptime(asked["DateSent>"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
            if self.by_day:
                since -= since % 86400
            page = int(asked.get("Page", "0"))
            size = int(asked["PageSize"])
            found = [m for m in self.messages if _at(m) >= since]
            rows = found[page * size : (page + 1) * size][: self.page] if self.page >= size else None
            if rows is None:  # a smaller page than was asked for: the tests' way to make several
                rows = found[page * self.page : (page + 1) * self.page]
                more = len(found) > (page + 1) * self.page
            else:
                more = len(found) > (page + 1) * size
            following = (
                f"{base}.json?DateSent%3E={asked['DateSent>']}&PageSize={size}&Page={page + 1}" if more else None
            )
            return httpx.Response(200, json={"messages": rows, "next_page_uri": following})
        if path.endswith("/Media.json"):
            name = path.split("/")[-2]
            self.asked.append(name)
            kept = self.pictures.get(name)
            if kept is None:
                return httpx.Response(404, json={"code": 20404})
            return httpx.Response(200, json={"media_list": [{"sid": n, "content_type": kind} for n, kind, _ in kept]})
        if "/Media/" in path:
            name = path.split("/")[-1]
            return httpx.Response(307, headers={"location": f"https://media.example/{name}"})
        name = path.rsplit("/", 1)[-1].removesuffix(".json")
        return httpx.Response(200, json={"sid": name, "status": "delivered", "error_code": None})

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self)


def _at(message: dict[str, Any]) -> float:
    from email.utils import parsedate_to_datetime

    return parsedate_to_datetime(message["date_sent"]).timestamp()


class Bench:
    """The conversations, a Twilio messenger that writes into them and the listener that asks Twilio, on a
    clock moved by hand: nothing runs until `turn` or `ask` is called."""

    def __init__(self, twilio: FakeTwilio | None = None, *, sender: str = FROM, store: TextStore | None = None) -> None:
        self.twilio = twilio if twilio is not None else FakeTwilio()
        self.now = float(T0)
        self.told = 0
        self.names = {"7815550142": "Pat"}
        self.texts = Texts(
            store,
            now=lambda: self.now,
            name_of=lambda digits: self.names.get(digits, ""),
            on_change=self._tell,
            location="China Sky",
        )
        self.messenger = TwilioMessenger(
            TwilioConfig(ACCOUNT, TOKEN, sender),
            transport=self.twilio.transport,
            now=lambda: self.now,
            background=False,
            sleep=self.wait,
            keeper=self.texts,
        )
        self.listener = Listener(self.texts, lambda: self.messenger, now=lambda: self.now)

    def _tell(self) -> None:
        self.told += 1

    def wait(self, seconds: float) -> None:
        self.now += seconds

    def turn(self, seconds: float = 0.0) -> int:
        self.now += seconds
        return self.messenger.run_due()

    def ask(self, seconds: float = 0.0) -> int:
        self.now += seconds
        return self.listener.round()

    def thread(self, phone: str = PAT) -> dict[str, Any]:
        return self.texts.thread(phone)

    def bodies(self, phone: str = PAT) -> list[str]:
        return [text["body"] for text in self.thread(phone)["texts"]]

    def say(self, body: str, to: str = PAT, **more: Any) -> dict[str, Any]:
        text, new = self.texts.compose(to, body, by_id="s1", by_name="Amy", **more)
        if new:
            self.messenger.deliver(text.text_id, text.phone, text.body)
        return text.as_json()


# --- numbers -------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "number"),
    [
        ("+17815550142", PAT),
        ("781 555 0142", PAT),
        ("17815550142", PAT),
        ("rcs:+17815550142", PAT),
        ("+8613800138000", "+8613800138000"),
        ("rcs:china_sky_agent", None),  # the restaurant's own name on a chat channel
        ("55512", None),  # a short code
        ("whatsapp:+17815550142", None),  # not a channel the POS reads
        ("", None),
    ],
)
def test_a_conversation_is_kept_by_the_customer_s_number_however_it_is_written(raw, number):
    assert number_of(raw) == number


def test_how_a_text_travelled_is_read_from_twilio_s_addresses():
    assert channel_of("rcs:+17815550142", "rcs:china_sky_agent") == "rcs"
    assert channel_of(PAT, FROM) == "sms"
    assert channel_of(PAT, FROM, pictures=2) == "mms"


# --- what a customer texts -----------------------------------------------------------------------------------


def test_a_customer_s_text_is_written_down_once_under_the_name_the_orders_know():
    bench = Bench(FakeTwilio(row(1, "Can I order for pickup?")))
    assert bench.ask() == 1
    listed = bench.texts.threads()
    assert listed["unread"] == 1
    (thread,) = listed["threads"]
    assert (thread["phone"], thread["digits"], thread["name"], thread["unread"]) == (PAT, "7815550142", "Pat", 1)
    assert thread["last"] == {
        "body": "Can I order for pickup?",
        "at_ms": NOW_MS,
        "inbound": True,
        "state": "received",
        "pictures_n": 0,
        "kind": "",
    }
    assert bench.told == 1, "the screens are told that a text came"
    # asked again, Twilio lists the same text: it is not here twice, and nobody is told anything
    assert bench.ask(5) == 0 and bench.bodies() == ["Can I order for pickup?"] and bench.told == 1


def test_a_number_the_orders_do_not_know_has_no_name_and_is_a_conversation_all_the_same():
    bench = Bench(FakeTwilio(row(1, "Are you open on Thanksgiving?", who=LEE)))
    bench.ask()
    (thread,) = bench.texts.threads()["threads"]
    assert (thread["phone"], thread["name"]) == (LEE, "")


def test_texts_show_in_the_order_they_were_sent_and_the_newest_conversation_is_first():
    bench = Bench(
        FakeTwilio(
            row(3, "Lee here", who=LEE, ago=10),
            row(2, "Two egg rolls too", ago=60),
            row(1, "One General Tso", ago=120),
        )
    )
    assert bench.ask() == 3
    assert bench.bodies() == ["One General Tso", "Two egg rolls too"]
    assert [t["phone"] for t in bench.texts.threads()["threads"]] == [LEE, PAT]
    assert bench.texts.threads()["unread"] == 2


def test_opening_a_conversation_reads_it_for_everybody_and_a_new_text_is_unread_again():
    bench = Bench(FakeTwilio(row(1)))
    bench.ask()
    read = bench.texts.read(PAT, by="Amy")
    assert read is not None and (read.unread, read.read_by) == (0, "Amy")
    assert bench.texts.threads()["unread"] == 0 and bench.told == 2
    assert bench.texts.read(PAT, by="Ben").read_by == "Amy", "nothing new: it stays read by whoever read it"
    assert bench.told == 2
    bench.twilio.add(row(2, "Hello?"))
    bench.ask(5)
    assert bench.thread()["thread"]["unread"] == 1
    assert bench.texts.read("+17815550999", by="Amy") is None


def test_a_conversation_is_found_by_name_number_or_a_word_of_a_text():
    bench = Bench(FakeTwilio(row(2, "Table for six on Friday?", who=LEE), row(1, "One General Tso")))
    bench.ask()

    def found(q: str) -> list[str]:
        return [t["phone"] for t in bench.texts.threads(q=q)["threads"]]

    assert found("pat") == [PAT]
    assert found("0177") == [LEE]
    assert found("friday table") == [LEE]
    assert found("general") == [PAT]
    assert found("pat friday") == []
    assert found("") == [LEE, PAT]


def test_older_texts_are_read_a_page_at_a_time():
    bench = Bench(FakeTwilio(*[row(n, f"text {n}", ago=(10 - n) * 60) for n in range(10, 0, -1)]))
    bench.ask()
    newest = bench.texts.thread(PAT, limit=4)
    assert [t["body"] for t in newest["texts"]] == ["text 7", "text 8", "text 9", "text 10"] and newest["more"]
    before = bench.texts.thread(PAT, before_ms=newest["texts"][0]["at_ms"], limit=4)
    assert [t["body"] for t in before["texts"]] == ["text 3", "text 4", "text 5", "text 6"] and before["more"]
    first = bench.texts.thread(PAT, before_ms=before["texts"][0]["at_ms"], limit=4)
    assert [t["body"] for t in first["texts"]] == ["text 1", "text 2"] and not first["more"]


# --- STOP ----------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("word", ["STOP", "stop", " Stop ", "UNSUBSCRIBE", "cancel", "END", "quit", "StopAll"])
def test_a_customer_who_answers_stop_is_written_to_no_more(word):
    bench = Bench(FakeTwilio(row(1, word)))
    bench.ask()
    assert bench.thread()["thread"]["stopped_ms"] == NOW_MS
    with pytest.raises(Refused) as refusal:
        bench.say("Sorry to see you go")
    assert refusal.value.code == "stopped"
    assert bench.twilio.posts == [], "a text Twilio would throw away is not handed to it"


def test_start_lets_the_texts_go_again_and_a_stop_inside_a_sentence_is_no_stop():
    bench = Bench(FakeTwilio(row(1, "STOP", ago=120)))
    bench.ask()
    bench.twilio.add(row(2, "Start", ago=60))
    bench.ask(1)
    assert bench.thread()["thread"]["stopped_ms"] is None
    bench.twilio.add(row(3, "Please stop by the bar when it is ready"))
    bench.ask(1)
    assert bench.thread()["thread"]["stopped_ms"] is None
    assert bench.say("Will do")["state"] == "waiting"


def test_twilio_saying_they_opted_out_marks_the_conversation_too():
    bench = Bench(FakeTwilio(row(1, "Hi")))
    bench.ask()
    text = bench.say("Hello Pat")
    bench.texts.became(text["id"], state="failed", code=21610, said="the customer answered STOP")
    thread = bench.thread()
    assert thread["thread"]["stopped_ms"] == NOW_MS
    assert (thread["texts"][-1]["state"], thread["texts"][-1]["code"]) == ("failed", 21610)


# --- what the staff write ------------------------------------------------------------------------------------


def test_an_answer_goes_out_from_the_restaurant_s_number_and_says_what_became_of_it():
    bench = Bench(FakeTwilio(row(1, "Can I order for pickup?")))
    bench.ask()
    text = bench.say("Sure, what would you like?", device="ipad1")
    assert (text["state"], text["by"], text["inbound"], text["kind"]) == ("waiting", "Amy", False, "")
    assert bench.thread()["thread"]["unread"] == 0, "whoever answers has read what they answer"
    assert bench.turn() == 1
    assert bench.twilio.posts == [{"To": PAT, "From": FROM, "Body": "Sure, what would you like?"}]
    assert bench.thread()["texts"][-1]["state"] == "sent"
    bench.turn(8)  # Twilio is asked what became of it
    assert bench.thread()["texts"][-1]["state"] == "delivered"
    assert bench.bodies() == ["Can I order for pickup?", "Sure, what would you like?"]


def test_the_first_text_to_a_number_says_who_it_is_from_and_how_to_stop():
    bench = Bench()
    assert bench.thread(LEE)["wrap"] == {"before": "China Sky: ", "after": "\nReply STOP to opt out."}
    text = bench.say("Your table is ready whenever you are.", to="781 555 0177", name="Lee")
    assert text["body"] == "China Sky: Your table is ready whenever you are.\nReply STOP to opt out."
    bench.turn()
    assert bench.twilio.posts[0]["Body"] == text["body"]
    assert bench.thread(LEE)["thread"]["name"] == "Lee"
    # the conversation has begun: the next text is as it was typed
    assert bench.thread(LEE)["wrap"] == {"before": "", "after": ""}
    assert bench.say("See you soon", to=LEE)["body"] == "See you soon"


def test_a_customer_who_wrote_first_is_answered_with_the_words_alone():
    bench = Bench(FakeTwilio(row(1, "Hi")))
    bench.ask()
    assert bench.thread()["wrap"] == {"before": "", "after": ""}
    assert bench.say("Hello!")["body"] == "Hello!"


def test_a_tap_sent_twice_is_one_text():
    bench = Bench(FakeTwilio(row(1, "Hi")))
    bench.ask()
    first = bench.say("On our way out with it", text_id="screen-abc-0001")
    again = bench.say("On our way out with it", text_id="screen-abc-0001")
    assert first["id"] == again["id"] == "screen-abc-0001"
    bench.turn()
    assert len(bench.twilio.posts) == 1 and len(bench.bodies()) == 2


def test_the_same_words_twice_are_a_person_s_to_send():
    bench = Bench(FakeTwilio(row(1, "Hi")))
    bench.ask()
    bench.say("ok")
    bench.say("ok")
    bench.turn()
    assert [post["Body"] for post in bench.twilio.posts] == ["ok", "ok"]


@pytest.mark.parametrize(
    ("to", "body", "code"),
    [
        ("555 0142", "Hello", "no_number"),
        (PAT, "   \n ", "no_text"),
        (PAT, "x" * (BODY_MAX + 1), "too_long"),
    ],
)
def test_a_text_that_cannot_go_is_refused_before_it_is_written_down(to, body, code):
    bench = Bench(FakeTwilio(row(1, "Hi")))
    bench.ask()
    with pytest.raises(Refused) as refusal:
        bench.say(body, to=to)
    assert refusal.value.code == code
    assert bench.bodies() == ["Hi"] and bench.twilio.posts == []


def test_a_text_that_did_not_go_says_why_in_the_conversation():
    twilio = FakeTwilio(row(1, "Hi"))
    bench = Bench(twilio)
    bench.ask()
    twilio.down = True
    bench.say("Hello Pat")
    bench.turn()
    bench.turn(5)
    bench.turn(20)
    last = bench.thread()["texts"][-1]
    assert (last["state"], last["said"]) == ("failed", "Twilio could not be reached")


# --- the POS's own texts in the same conversation -------------------------------------------------------------


def test_the_pos_s_own_text_to_an_order_is_in_the_customer_s_conversation():
    bench = Bench()
    ready = "Hi Pat, order #12 is ready for pickup at China Sky."
    bench.messenger.send(Message("781 555 0142", ready, "en", "o12", "ready", name="Patricia"))
    (text,) = bench.thread()["texts"]
    assert (text["body"], text["kind"], text["order_id"], text["state"], text["by"]) == (
        ready,
        "ready",
        "o12",
        "waiting",
        "",
    )
    assert bench.thread()["thread"]["name"] == "Patricia", "the order's own name for them"
    bench.turn()
    bench.turn(8)
    assert bench.thread()["texts"][0]["state"] == "delivered"
    assert bench.twilio.posts == [{"To": PAT, "From": FROM, "Body": ready}], "as it always went: nothing around it"
    # and the customer's answer is read under it
    bench.twilio.add(row(1, "Be there in 10"))
    bench.ask(1)
    assert bench.bodies() == [ready, "Be there in 10"]
    # an answer to them is not wrapped: the conversation began with the order's text
    assert bench.say("See you then")["body"] == "See you then"


def test_a_text_found_at_twilio_before_its_sending_was_answered_is_the_same_text():
    bench = Bench()
    text = bench.say("Running ten minutes late, sorry", to=PAT, name="Pat")
    # Twilio lists it (the hub asked for the newest texts) before the hub heard the answer to its sending
    listed = row(901, text["body"], inbound=False, status="sent")
    assert bench.texts.take(listed) is True
    assert len(bench.bodies()) == 1 and bench.thread()["texts"][0]["state"] == "sent"
    bench.turn()  # now the sending is answered, with the same name
    bench.turn(8)
    (only,) = bench.thread()["texts"]
    assert (only["id"], only["state"], only["by"]) == (text["id"], "delivered", "Amy")


def test_a_text_sent_from_the_restaurant_s_number_by_something_else_is_shown_as_such():
    bench = Bench(FakeTwilio(row(5, "We open at noon on Thanksgiving.", inbound=False, ago=30)))
    assert bench.ask() == 1
    (text,) = bench.thread()["texts"]
    assert (text["kind"], text["inbound"], text["state"], text["by"]) == ("elsewhere", False, "delivered", "")
    assert bench.thread()["thread"]["unread"] == 0


def test_what_twilio_says_of_a_text_later_never_puts_it_back():
    bench = Bench(FakeTwilio(row(5, "Hello", inbound=False, status="delivered")))
    bench.ask()
    assert bench.texts.take(row(5, "Hello", inbound=False, status="sent")) is False
    assert bench.thread()["texts"][0]["state"] == "delivered"
    assert bench.texts.take(row(5, "Hello", inbound=False, status="read")) is True
    assert bench.thread()["texts"][0]["state"] == "read"
    assert bench.texts.take(row(5, "Hello", inbound=False, status="undelivered", code=30003)) is False
    assert bench.thread()["texts"][0]["state"] == "read"


def test_a_text_the_phone_company_did_not_deliver_says_so():
    bench = Bench(FakeTwilio(row(5, "Hello", inbound=False, status="sent", ago=20)))
    bench.ask()
    bench.twilio.messages[0] = row(5, "Hello", inbound=False, status="undelivered", code=30005, ago=20)
    assert bench.ask(5) == 1
    text = bench.thread()["texts"][0]
    assert (text["state"], text["code"]) == ("failed", 30005)


# --- asking Twilio -------------------------------------------------------------------------------------------


def test_the_first_asking_reaches_three_days_back_and_the_next_a_quarter_of_an_hour():
    bench = Bench(FakeTwilio(row(1, "Hi", ago=3600)))
    bench.ask()
    first = datetime.fromtimestamp(T0 - HISTORY_MS / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert bench.twilio.lists[0] == {"DateSent>": first, "PageSize": "100"}
    bench.ask(5)
    again = datetime.fromtimestamp(T0 - WINDOW_MS / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert bench.twilio.lists[1]["DateSent>"] == again


def test_a_hub_that_was_restarted_asks_from_a_little_before_its_newest_text():
    store = TextStore()
    before = Bench(FakeTwilio(row(1, "Hi", ago=3600)), store=store)
    before.ask()
    after = Bench(FakeTwilio(row(2, "Anybody there?", ago=600), row(1, "Hi", ago=3600)), store=store)
    assert after.ask() == 1
    since = datetime.fromtimestamp(T0 - 3600 - WINDOW_MS / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert after.twilio.lists[0]["DateSent>"] == since
    assert after.bodies() == ["Hi", "Anybody there?"]


def test_a_long_list_is_read_page_after_page():
    twilio = FakeTwilio(*[row(n, f"text {n}", ago=(8 - n) * 60) for n in range(8, 0, -1)], page=3)
    bench = Bench(twilio)
    assert bench.ask() == 8
    assert [asked.get("Page", "0") for asked in twilio.lists] == ["0", "1", "2"]
    assert bench.bodies() == [f"text {n}" for n in range(1, 9)]


def test_a_twilio_that_goes_by_the_day_alone_is_not_read_to_the_end_every_time():
    old = [row(n, f"old {n}", ago=3600 * 5 + n) for n in range(100, 400)]
    twilio = FakeTwilio(row(1, "new"), *old, by_day=True)
    bench = Bench(twilio)
    bench.texts.store.add(_known())  # a hub that has been running: it asks a quarter of an hour back
    assert bench.ask() == 1
    assert len(twilio.lists) == 1, "the first page already reaches further back than was asked for"
    assert bench.bodies() == ["new"]


def _known() -> Any:
    from pos.texts import Text

    return Text("known-text-0001", LEE, True, "earlier", NOW_MS - 60_000, "received", sid=sid(7777))


def test_texts_of_the_account_s_other_numbers_are_left_out():
    bench = Bench(
        FakeTwilio(
            row(3, "For the fax line", ours=OTHER),
            row(2, "From the other number", inbound=False, ours=OTHER),
            row(1, "For the restaurant"),
        )
    )
    assert bench.ask() == 1
    assert [t["phone"] for t in bench.texts.threads()["threads"]] == [PAT] and bench.bodies() == ["For the restaurant"]


def test_with_a_messaging_service_its_texts_are_known_by_its_name_its_numbers_or_the_chat_channel():
    twilio = FakeTwilio(
        row(4, "Not ours", ours=OTHER),
        row(3, "By chat", who="rcs:+17815550142", ours="rcs:china_sky_agent"),
        row(2, "To a number of the service", who=LEE, ours=FROM),
        row(1, "Named by the service", service=SERVICE, ours="+17815550123"),
    )
    twilio.service_numbers = [FROM]
    bench = Bench(twilio, sender=SERVICE)
    assert bench.ask() == 3
    assert bench.bodies() == ["Named by the service", "By chat"]
    assert bench.thread()["texts"][1]["channel"] == "rcs"
    assert bench.bodies(LEE) == ["To a number of the service"]
    # an answer goes out through the service, which picks the way (chat where the phone takes it)
    bench.say("Hello")
    bench.turn()
    assert bench.twilio.posts == [{"To": PAT, "MessagingServiceSid": SERVICE, "Body": "Hello"}]


def test_a_twilio_that_cannot_be_asked_is_said_and_asked_again():
    twilio = FakeTwilio(row(1, "Hi"))
    bench = Bench(twilio)
    twilio.down = True
    assert bench.ask() == 0
    assert bench.listener.about() == {"ok": False, "at_ms": None}
    assert bench.messenger.heard_fault == "Twilio could not be reached"
    twilio.down = False
    twilio.refuse = (401, 20003)
    bench.ask(5)
    assert "Twilio does not know the key" in bench.messenger.heard_fault
    twilio.refuse = None
    assert bench.ask(5) == 1
    assert bench.listener.about() == {"ok": True, "at_ms": NOW_MS + 10_000} and bench.messenger.heard_fault == ""


def test_a_hub_without_twilio_asks_nobody():
    texts = Texts(TextStore())
    listener = Listener(texts, lambda: None)
    assert listener.round() == 0 and listener.about() == {"ok": None, "at_ms": None}


def test_asking_is_quick_with_a_screen_on_and_slow_with_none():
    bench = Bench()
    screens = 1
    listener = Listener(bench.texts, lambda: bench.messenger, now=lambda: bench.now, screens=lambda: screens)
    listener._last_round = bench.now  # noqa: SLF001 - it has just asked
    bench.now += 4
    assert not listener.due()
    bench.now += 1
    assert listener.due()
    screens = 0
    assert not listener.due()
    bench.now += 25
    assert listener.due()


# --- pictures ------------------------------------------------------------------------------------------------

JPEG = b"\xff\xd8\xff\xe0 a picture of a menu"


def test_a_text_with_pictures_lists_them_and_a_picture_is_fetched_without_the_key_going_on():
    twilio = FakeTwilio(row(1, "Is this the dish?", pictures=2))
    twilio.pictures[sid(1, "MM")] = [(sid(1, "ME"), "image/jpeg", JPEG), (sid(2, "ME"), "audio/amr", b"...")]
    bench = Bench(twilio)
    bench.ask()
    (text,) = bench.thread()["texts"]
    assert text["channel"] == "mms" and text["pictures_n"] == 2
    assert text["pictures"] == [
        {"n": 0, "type": "image/jpeg", "image": True},
        {"n": 1, "type": "audio/amr", "image": False},
    ]
    assert bench.messenger.picture(sid(1, "MM"), sid(1, "ME")) == ("image/jpeg", JPEG)
    assert twilio.picture_keys == [""], "the account's key stays with Twilio's own address"
    assert bench.messenger.picture(sid(1, "MM"), "../../etc/passwd") is None
    assert bench.messenger.picture("not-a-text", sid(1, "ME")) is None


def test_pictures_twilio_could_not_list_yet_are_asked_for_again():
    twilio = FakeTwilio(row(1, "", pictures=1))
    bench = Bench(twilio)
    bench.ask()
    assert bench.thread()["texts"][0]["pictures"] == [] and bench.thread()["texts"][0]["pictures_n"] == 1
    twilio.pictures[sid(1, "MM")] = [(sid(1, "ME"), "image/png", b"png")]
    assert bench.ask(5) == 1
    assert bench.thread()["texts"][0]["pictures"] == [{"n": 0, "type": "image/png", "image": True}]
    asked = len(twilio.asked)
    bench.ask(5)
    assert len(twilio.asked) == asked, "once they are known Twilio is not asked again"


# --- on the wire ---------------------------------------------------------------------------------------------


def staff() -> Directory:
    return Directory(
        [
            Staff.with_pin("s1", "Amy", "server", "1111"),
            Staff.with_pin("s3", "Mike", "manager", "9999"),
            Staff.with_pin("s5", "Ken", "kitchen", "5555"),
        ]
    )


def wired(twilio: FakeTwilio | None = None) -> tuple[TestClient, FakeTwilio, Listener, TwilioMessenger]:
    """A hub whose Twilio is `twilio`: its texts go out when the test works the line, and Twilio is asked
    when the test says so."""
    twilio = twilio if twilio is not None else FakeTwilio()
    store = OpStore(physical=lambda: NOW_MS)
    messenger = TwilioMessenger(
        TwilioConfig(ACCOUNT, TOKEN, FROM), transport=twilio.transport, now=lambda: float(T0), background=False
    )
    app = create_app(
        store,
        staff=staff(),
        menu=MenuService(load_definitions("restaurant")),
        taxes=massachusetts(),
        printing=PrintService([]),
        settings=SettingStore(),
        numbers=OrderNumbers(store),
        lookups=Lookups(),
        online=OnlineOrders(None),
        relay=PushRelay(PushDevices(), None),
        location="China Sky",
        messenger=messenger,
    )
    return TestClient(app), twilio, app.state.text_listener, messenger


AMY = {"staff_id": "s1"}


def test_only_who_holds_the_power_reads_the_texts():
    api, _, _, _ = wired()
    assert api.get("/texts", params=AMY).status_code == 200
    assert api.get("/texts", params={"staff_id": "s3"}).status_code == 200
    refused = api.get("/texts", params={"staff_id": "s5"})
    assert (refused.status_code, refused.json()["detail"]) == (
        403,
        {"error": "not_allowed", "role": "kitchen", "power": "texts"},
    )
    assert api.get("/texts", params={"staff_id": "nobody"}).status_code == 404
    assert api.get("/texts").status_code == 422
    for path in ("/texts/unread", f"/texts/with/{PAT}", "/texts/picture/x/0"):
        assert api.get(path, params={"staff_id": "s5"}).status_code == 403, path
    assert api.post(f"/texts/with/{PAT}", json={"staff_id": "s5", "body": "Hi"}).status_code == 403
    assert api.post(f"/texts/with/{PAT}/read", json={"staff_id": "s5"}).status_code == 403
    # the table is the location's own: a manager takes the texts from the servers
    token = api.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    put = api.put("/settings/powers", json={"roles": {"texts": ["host"]}}, headers={"authorization": f"Bearer {token}"})
    assert put.status_code == 200
    assert api.get("/texts", params=AMY).status_code == 403


def test_a_conversation_from_the_customer_s_text_to_the_answer():
    api, twilio, listener, messenger = wired(FakeTwilio(row(1, "Can I get two egg rolls for pickup?")))
    assert api.get("/texts/unread", params=AMY).json() == {"on": True, "unread": 0}
    assert listener.round() == 1
    assert api.get("/texts/unread", params=AMY).json() == {"on": True, "unread": 1}
    listed = api.get("/texts", params=AMY).json()
    assert (listed["on"], listed["number"], listed["unread"]) == (True, FROM, 1)
    assert listed["listening"] == {"ok": True, "at_ms": NOW_MS, "said": ""}
    assert [t["phone"] for t in listed["threads"]] == [PAT]
    opened = api.get("/texts/with/7815550142", params=AMY).json()
    assert [t["body"] for t in opened["texts"]] == ["Can I get two egg rolls for pickup?"]
    assert api.post(f"/texts/with/{PAT}/read", json=AMY).json()["unread"] == 0
    sent = api.post(
        "/texts/with/781 555 0142",
        json={**AMY, "body": "Sure! Ready in 15 minutes.", "device": "ipad1", "id": "ipad1-0000-0001"},
    )
    assert sent.status_code == 200
    assert (sent.json()["id"], sent.json()["state"], sent.json()["by"]) == ("ipad1-0000-0001", "waiting", "Amy")
    messenger.run_due()
    assert twilio.posts == [{"To": PAT, "From": FROM, "Body": "Sure! Ready in 15 minutes."}]
    texts = api.get(f"/texts/with/{PAT}", params=AMY).json()["texts"]
    assert [(t["body"], t["state"]) for t in texts] == [
        ("Can I get two egg rolls for pickup?", "received"),
        ("Sure! Ready in 15 minutes.", "sent"),
    ]
    # the same tap again is the same text
    again = api.post(f"/texts/with/{PAT}", json={**AMY, "body": "Sure! Ready in 15 minutes.", "id": "ipad1-0000-0001"})
    messenger.run_due()
    assert again.json()["id"] == "ipad1-0000-0001" and len(twilio.posts) == 1


def test_what_is_refused_on_the_wire():
    api, twilio, listener, _ = wired(FakeTwilio(row(1, "STOP")))
    listener.round()
    stopped = api.post(f"/texts/with/{PAT}", json={**AMY, "body": "Hello"})
    assert (stopped.status_code, stopped.json()["detail"]["error"]) == (409, "stopped")
    assert api.post("/texts/with/5550142", json={**AMY, "body": "Hello"}).status_code == 422
    assert api.post(f"/texts/with/{LEE}", json={**AMY, "body": "  "}).json()["detail"]["error"] == "no_text"
    assert api.get("/texts/with/5550142", params=AMY).status_code == 422
    assert api.post(f"/texts/with/{LEE}/read", json=AMY).status_code == 404
    assert twilio.posts == []


def test_a_hub_without_twilio_says_so_and_sends_nothing():
    app = create_app(
        OpStore(), staff=staff(), menu=MenuService(load_definitions("restaurant")), printing=PrintService([])
    )
    api = TestClient(app)
    listed = api.get("/texts", params=AMY).json()
    assert (listed["on"], listed["threads"], listed["listening"]["ok"]) == (False, [], None)
    refused = api.post(f"/texts/with/{PAT}", json={**AMY, "body": "Hello"})
    assert (refused.status_code, refused.json()["detail"]["error"]) == (409, "no_service")
    assert api.get(f"/texts/with/{PAT}", params=AMY).json()["texts"] == []


def test_a_picture_is_fetched_once_and_handed_to_the_screen():
    twilio = FakeTwilio(row(1, "Is this the dish?", pictures=2))
    twilio.pictures[sid(1, "MM")] = [(sid(1, "ME"), "image/jpeg", JPEG), (sid(2, "ME"), "text/x-vcard", b"BEGIN:VCARD")]
    api, _, listener, _ = wired(twilio)
    listener.round()
    text = api.get(f"/texts/with/{PAT}", params=AMY).json()["texts"][0]
    shown = api.get(f"/texts/picture/{text['id']}/0", params=AMY)
    assert (shown.status_code, shown.headers["content-type"], shown.content) == (200, "image/jpeg", JPEG)
    assert shown.headers["x-content-type-options"] == "nosniff"
    twilio.down = True  # the second look needs no Twilio: the hub kept it
    assert api.get(f"/texts/picture/{text['id']}/0", params=AMY).content == JPEG
    twilio.down = False
    card = api.get(f"/texts/picture/{text['id']}/1", params=AMY)
    assert card.headers["content-type"] == "application/octet-stream", "what is no picture is never shown as one"
    assert api.get(f"/texts/picture/{text['id']}/2", params=AMY).status_code == 404
    assert api.get("/texts/picture/nothing/0", params=AMY).status_code == 404
    twilio.pictures[sid(1, "MM")][1] = (sid(2, "ME"), "text/x-vcard", b"")
    twilio.down = True
    api2, _, listener2, _ = wired(twilio)
    assert listener2.round() == 0


def test_a_picture_twilio_does_not_hand_over_is_said():
    twilio = FakeTwilio(row(1, "", pictures=1))
    twilio.pictures[sid(1, "MM")] = [(sid(1, "ME"), "image/jpeg", JPEG)]
    api, _, listener, _ = wired(twilio)
    listener.round()
    text = api.get(f"/texts/with/{PAT}", params=AMY).json()["texts"][0]
    twilio.down = True
    refused = api.get(f"/texts/picture/{text['id']}/0", params=AMY)
    assert (refused.status_code, refused.json()["detail"]["error"]) == (502, "not_fetched")


def op(op_id: str, kind: str, at: int, order_id: str = "o1", **data: Any) -> dict[str, Any]:
    return {
        "op_id": op_id,
        "order_id": order_id,
        "hlc": str(HLC(NOW_MS - 1000 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def test_an_order_s_ready_text_and_the_customer_s_answer_are_one_conversation():
    api, twilio, listener, messenger = wired()
    tea = {"unit_price": "10.00", "tax_class": "prepared_food", "name": "Tea"}
    made = [
        op("a", "create", 0, order_type="takeout", customer_name="Pat", phone="(781) 555-0142"),
        op("b", "add_line", 1, line_id="L1", item="Tea", qty=1, priced=tea),
        op("c", "set_field", 2, stage="ready"),
    ]
    answer = api.post("/orders/o1/ops", json=made)
    assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text
    messenger.run_due()
    assert len(twilio.posts) == 1 and "is ready for pickup at China Sky" in twilio.posts[0]["Body"]
    twilio.add(row(1, "Thanks, 5 minutes away"))
    listener.round()
    opened = api.get(f"/texts/with/{PAT}", params=AMY).json()
    assert opened["thread"]["name"] == "Pat" and opened["thread"]["unread"] == 1
    assert [(t["kind"], t["order_id"], t["inbound"]) for t in opened["texts"]] == [
        ("ready", "o1", False),
        ("", "", True),
    ]
    assert opened["wrap"] == {"before": "", "after": ""}


def test_the_screens_are_told_on_the_change_feed():
    api, twilio, listener, messenger = wired(FakeTwilio(row(1, "Hi")))
    told: list[str] = []
    api.app.state.feed.changed = told.append
    listener.round()
    assert told == ["texts"]
    api.post(f"/texts/with/{PAT}/read", json=AMY)
    api.post(f"/texts/with/{PAT}", json={**AMY, "body": "Hello"})
    messenger.run_due()
    assert told == ["texts"] * 4, "it came, it was read, an answer was written, Twilio took the answer"


def hub_keys() -> HubKeys:
    vault = vault_from_env({"POS_SECRET": "the-location-s-own-secret", "POS_KEYS_FILE": "/nowhere/at/all"})
    return HubKeys(None, vault, environ={}, now=lambda: NOW_MS)


def test_an_account_typed_in_the_app_writes_into_the_conversations_at_once():
    twilio = FakeTwilio()
    store = OpStore(physical=lambda: NOW_MS)
    app = create_app(
        store,
        staff=staff(),
        menu=MenuService(load_definitions("restaurant")),
        taxes=massachusetts(),
        printing=PrintService([]),
        settings=SettingStore(),
        numbers=OrderNumbers(store),
        keys=hub_keys(),
        lookups=Lookups(),
        online=OnlineOrders(None),
        relay=PushRelay(PushDevices(), None),
        location="China Sky",
    )
    app.state.texts_made_with = {"transport": twilio.transport, "background": False, "sleep": lambda seconds: None}
    api = TestClient(app)
    assert api.get("/texts", params=AMY).json()["on"] is False
    session = api.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    typed = {"account": ACCOUNT, "key": TOKEN, "sender": "781 555 0100"}
    assert api.put("/hub/keys/texts", json=typed, headers={"authorization": f"Bearer {session}"}).status_code == 200
    listed = api.get("/texts", params=AMY).json()
    assert (listed["on"], listed["number"]) == (True, FROM)
    assert api.post(f"/texts/with/{PAT}", json={**AMY, "body": "Hello Pat", "name": "Pat"}).status_code == 200
    app.state.messenger.run_due()
    assert twilio.posts[0]["Body"] == "China Sky: Hello Pat\nReply STOP to opt out."
    assert api.get(f"/texts/with/{PAT}", params=AMY).json()["texts"][0]["state"] == "sent"
    # and what the customer answers is read with the same account
    twilio.add(row(1, "Hi!"))
    assert app.state.text_listener.round() >= 1
    bodies = [t["body"] for t in api.get(f"/texts/with/{PAT}", params=AMY).json()["texts"]]
    assert bodies == ["China Sky: Hello Pat\nReply STOP to opt out.", "Hi!"]


# --- PostgreSQL ----------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_conversations_are_the_same_in_postgresql_and_are_there_after_a_restart():
    import psycopg

    from pos.texts import PgTextStore

    with psycopg.connect(DSN, autocommit=True) as conn:
        for table in ("text_message", "text_thread", "text_picture"):
            conn.execute(f"DROP TABLE IF EXISTS {table}")
    store = PgTextStore(DSN)
    try:
        twilio = FakeTwilio(
            row(3, "Lee here, table for 6 on Friday?", who=LEE, ago=10),
            row(2, "Two egg rolls too", ago=60, pictures=1),
            row(1, "One General Tso", ago=120),
        )
        twilio.pictures[sid(2, "MM")] = [(sid(9, "ME"), "image/jpeg", JPEG)]
        bench = Bench(twilio, store=store)
        assert store.writable()
        assert bench.ask() == 3 and bench.ask(5) == 0
        assert bench.bodies() == ["One General Tso", "Two egg rolls too"]
        assert bench.thread()["texts"][1]["pictures"] == [{"n": 0, "type": "image/jpeg", "image": True}]
        listed = bench.texts.threads()
        assert listed["unread"] == 2 and [t["phone"] for t in listed["threads"]] == [LEE, PAT]
        assert [t["name"] for t in listed["threads"]] == ["", "Pat"]
        assert [t["phone"] for t in bench.texts.threads(q="friday")["threads"]] == [LEE]
        assert [t["phone"] for t in bench.texts.threads(q="0142")["threads"]] == [PAT]
        assert [t["phone"] for t in bench.texts.threads(q="pat egg")["threads"]] == [PAT]
        assert bench.texts.threads(q="100%")["threads"] == []
        # an answer: written down, sent, delivered, and the conversation is read
        text = bench.say("Got it, 20 minutes", text_id="screen-abc-0001")
        assert bench.say("Got it, 20 minutes", text_id="screen-abc-0001")["id"] == text["id"]
        bench.turn()
        bench.turn(8)
        assert bench.thread()["texts"][-1]["state"] == "delivered"
        assert bench.thread()["thread"]["unread"] == 0 and bench.texts.threads()["unread"] == 1
        assert len(twilio.posts) == 1
        # found at Twilio before its sending was answered, it is the same text
        late = bench.say("One more thing")
        assert bench.texts.take(row(902, "One more thing", inbound=False, status="sent")) is True
        bench.turn()
        assert [t["body"] for t in bench.thread()["texts"]].count("One more thing") == 1
        assert bench.thread()["texts"][-1]["id"] == late["id"]
        # STOP, and a picture kept
        twilio.add(row(4, "STOP", who=LEE))
        bench.ask(5)
        assert bench.thread(LEE)["thread"]["stopped_ms"] is not None
        store.keep_picture(sid(2, "MM"), 0, "image/jpeg", JPEG, NOW_MS)
        store.keep_picture(sid(2, "MM"), 0, "image/jpeg", b"another", NOW_MS)
        assert store.picture(sid(2, "MM"), 0) == ("image/jpeg", JPEG)
        store.drop_pictures(NOW_MS + 1)
        assert store.picture(sid(2, "MM"), 0) is None
        older = bench.texts.thread(PAT, limit=2)
        assert older["more"] and len(older["texts"]) == 2
        again = PgTextStore(DSN)  # another process: the hub after a restart
        try:
            after = Texts(again)
            assert [t["body"] for t in after.thread(PAT)["texts"]][:2] == ["One General Tso", "Two egg rolls too"]
            assert after.thread(LEE)["thread"]["stopped_ms"] is not None
            assert again.newest_ms() == store.newest_ms()
        finally:
            again.close()
    finally:
        store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            for table in ("text_message", "text_thread", "text_picture"):
                conn.execute(f"DROP TABLE IF EXISTS {table}")
