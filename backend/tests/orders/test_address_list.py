"""A list of addresses while one is being typed (docs/delivery.md, "A list of addresses while typing").

Wherever a screen asks for a street address, the hub says what the letters typed so far could become. The
restaurant's own earlier deliveries come first and ask nobody. A map service is asked only where a manager
turned it on: it is sent the letters typed and nothing else, what it answers is not kept, and a service that
gives no list never fails a form."""

from __future__ import annotations

import json
import logging
import os

import httpx
import pytest

from pos.addresses import (
    KINDS,
    NEAR_METERS,
    AddressBook,
    Places,
    Suggester,
    Suggestion,
    fits,
    known,
    own_addresses,
    places_from_env,
    suggester_from_env,
    worth_asking,
)
from pos.maps import LookupFailed

from .test_day import Hub, at

DSN = os.environ.get("POS_TEST_DATABASE_URL")

HOME = "1 Restaurant Row, Winchester, MA"
ELM = "12 Elm St, Winchester"
ELMWOOD = "120 Elmwood Ave, Woburn"
OAK = "4 Oak Rd Apt 12, Woburn"
LINDA = "(781) 555-0142"
OMAR = "(781) 555-0177"
STANDS = {"latitude": 42.4523, "longitude": -71.137}
"""Where the made-up restaurant stands."""


def typed(h: Hub, letters: str, **more) -> dict:
    answer = h.c.post("/addresses/suggest", json={"typed": letters, **more})
    assert answer.status_code == 200, answer.text
    return answer.json()


def listed(h: Hub, letters: str, **more) -> list[tuple[str, str]]:
    """The list for these letters: each address and where it is from."""
    return [(one["address"], one["from"]) for one in typed(h, letters, **more)["suggestions"]]


def brought(h: Hub, order_id: str, when: int, address: str, phone: str = LINDA, **fields) -> None:
    """A phone order that is brought to that address."""
    h.to_go(order_id, when, phone=phone, handover="delivery", address=address, **fields)


def delivered(h: Hub | None = None) -> Hub:
    """Three deliveries of an afternoon: Linda's to Elm Street and to Oak Road, Omar's to Elmwood Avenue."""
    h = h or Hub(now=at(16))
    brought(h, "d1", at(16, 1), ELM)
    brought(h, "d2", at(16, 2), ELMWOOD, phone=OMAR, name="Omar")
    brought(h, "d3", at(16, 3), OAK)
    return h


def prediction(text: str, main: str = "", rest: str = "", place: str = "") -> dict:
    told: dict = {"text": {"text": text, "matches": [{"endOffset": 2}]}}
    if main:
        told["structuredFormat"] = {"mainText": {"text": main}, "secondaryText": {"text": rest}}
    if place:
        told["placeId"] = place
    return {"placePrediction": told}


class World:
    """Google's Places API as far as the hub uses it, and everything it was asked."""

    def __init__(self, *predictions: dict, status: int = 200, place: dict | None = STANDS) -> None:
        self.predictions = list(predictions)
        self.status = status
        self.place = place
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"error": {"status": "PERMISSION_DENIED"}})
        if request.method == "GET":
            return httpx.Response(200, json={"location": self.place} if self.place else {})
        asked = json.loads(request.content)
        if "includedPrimaryTypes" not in asked:  # where the restaurant stands: its own address, read
            return httpx.Response(200, json={"suggestions": [prediction(asked["input"], place="ChIJ-home_1")]})
        return httpx.Response(200, json={"suggestions": self.predictions} if self.predictions else {})

    def places(self, **more) -> Places:
        return Places("AIza-key-456", client=httpx.Client(transport=httpx.MockTransport(self)), **more)

    @property
    def lists(self) -> list[dict]:
        """The bodies of the askings for a list, in order."""
        bodies = [json.loads(request.content) for request in self.seen if request.method == "POST"]
        return [body for body in bodies if "includedPrimaryTypes" in body]


WINCHESTER = (
    prediction("12 Elm Street, Winchester, MA, USA", "12 Elm Street", "Winchester, MA, USA"),
    prediction("12 Elmwood Road, Winchester, MA, USA", "12 Elmwood Road", "Winchester, MA, USA"),
)


def asking(h: Hub, world: World, *, on: bool = True, origin: str = HOME, **more) -> Suggester:
    """The hub with Google's key, the restaurant's own address, and the list's use of Google turned on."""
    suggester = Suggester(world.places(), **more)
    h.c.app.state.suggester = suggester
    if origin:
        fee = {"enabled": False, "by": "miles", "bands": [], "taxed": False, "origin": origin}
        assert h.c.put("/settings/delivery_fee", json=fee, headers=h.manager()).status_code == 200
    if on:
        assert h.c.put("/settings/address_list", json={"google": True}, headers=h.manager()).status_code == 200
    return suggester


# What the letters typed could become ------------------------------------------------------------------------


def test_a_word_typed_whole_is_a_word_of_the_address_and_the_one_being_typed_starts_one():
    assert fits("12 el", ELM) and fits("elm 12", ELM) and fits("ELM  st", ELM) and fits("12 Elm St, Winch", ELM)
    assert not fits("12 oak", ELM) and not fits("2 elm", ELM) and not fits("lm", ELM)
    # the 12 is typed whole once a space follows it: it is not the start of 120 any more
    assert fits("12", ELMWOOD) and not fits("12 ", ELMWOOD) and not fits("12 el", ELMWOOD) and fits("12 ", ELM)
    assert fits("120 elmw", ELMWOOD) and not fits("12 elm str", ELM)
    # an address typed whole is not offered to itself, the case and the spaces aside
    assert not fits("12 elm st,  winchester", ELM) and not fits("", ELM) and not fits(" , ", ELM)


def test_the_customers_own_come_first_and_the_ones_that_begin_the_same_way_lead():
    told = known("12", [OAK, ELM], [ELMWOOD, "12 Main St, Woburn", ELM], most=6)
    # Linda's own two: Elm Street begins with what was typed, Oak Road holds it further on; then the others',
    # the one with that very number before the one whose number begins that way; Elm Street is not listed twice
    assert [(one.address, one.source) for one in told] == [
        (ELM, "customer"),
        (OAK, "customer"),
        ("12 Main St, Woburn", "orders"),
        (ELMWOOD, "orders"),
    ]
    assert told[0].as_json() == {"address": ELM, "main": ELM, "rest": "", "from": "customer"}
    assert len(known("12", [OAK, ELM], [ELMWOOD, "12 Main St, Woburn"], most=3)) == 3
    assert known("1", [ELM], [ELMWOOD], most=6) == []  # one letter says nothing yet
    assert [one.address for one in known("el", [], [ELMWOOD, ELM], most=6)] == [ELMWOOD, ELM]  # the newest first


def test_the_map_service_is_asked_from_the_fourth_letter_and_never_about_a_number_alone():
    assert worth_asking("12 E") and worth_asking("elm s") and worth_asking(" 12   Elm ")
    assert not worth_asking("12") and not worth_asking("elm") and not worth_asking("1234 56") and not worth_asking("")


# The restaurant's own deliveries ----------------------------------------------------------------------------


def test_an_earlier_delivery_is_listed_while_its_address_is_typed():
    h = delivered()
    assert listed(h, "12 el") == [(ELM, "orders")]
    assert listed(h, "elm") == [(ELMWOOD, "orders"), (ELM, "orders")]  # the newest delivery first
    # the one that begins with that number, the one whose number begins that way, the one that holds it
    assert listed(h, "12") == [(ELM, "orders"), (ELMWOOD, "orders"), (OAK, "orders")]
    assert listed(h, "12 ") == [(ELM, "orders"), (OAK, "orders")]  # a space: the number is typed whole
    told = typed(h, "woburn")
    assert told == {
        "typed": "woburn",
        "suggestions": [
            {"address": OAK, "main": OAK, "rest": "", "from": "orders"},
            {"address": ELMWOOD, "main": ELMWOOD, "rest": "", "from": "orders"},
        ],
        "credit": None,
    }
    # nothing fits, one letter, nothing typed: an empty list and no error
    assert listed(h, "9 birch") == [] and listed(h, "1") == [] and listed(h, "   ") == []
    # an address that is typed whole has nothing more to become
    assert listed(h, "12 elm st, winchester") == []
    assert h.c.post("/addresses/suggest", json={"typed": "x" * 401}).status_code == 422
    assert listed(h, "12 elm " + "x" * 200) == []  # longer than an address may be


def test_the_customer_on_the_phone_has_their_own_addresses_first():
    h = delivered()
    assert listed(h, "12", phone=LINDA) == [(ELM, "customer"), (OAK, "customer"), (ELMWOOD, "orders")]
    assert listed(h, "el", phone=OMAR) == [(ELMWOOD, "customer"), (ELM, "orders")]
    # a number that is no customer's, and one that never had a delivery
    assert listed(h, "el", phone="12") == [(ELMWOOD, "orders"), (ELM, "orders")]
    assert listed(h, "el", phone="(617) 555-0100") == [(ELMWOOD, "orders"), (ELM, "orders")]
    assert own_addresses(h.store, LINDA) == [OAK, ELM] and own_addresses(h.store, "12") == []


def test_an_address_is_listed_once_as_its_newest_delivery_spelled_it():
    h = delivered()
    brought(h, "d4", at(16, 4), "12 ELM ST,   winchester", phone=OMAR, name="Omar")
    assert listed(h, "12 el") == [("12 ELM ST, winchester", "orders")]
    assert listed(h, "12 el", phone=LINDA) == [(ELM, "customer")]  # as Linda's own order has it


def test_only_a_delivery_that_stands_is_listed():
    h = Hub(now=at(16))
    h.to_go("p1", at(16, 1), phone=LINDA, handover="pickup", address=ELM)  # picked up, whatever it carries
    h.to_go("p2", at(16, 2), phone=LINDA)
    h.table("t1", at(16, 3))
    brought(h, "v1", at(16, 4), ELMWOOD)
    h.op("v1", "void_order", at(16, 5))
    brought(h, "n1", at(16, 6), OAK, phone="")  # no number on it: it is not read
    assert listed(h, "el") == [] and listed(h, "oak") == [] and listed(h, "el", phone=LINDA) == []
    brought(h, "d1", at(16, 7), ELM)
    assert listed(h, "el", phone=LINDA) == [(ELM, "customer")]


def test_the_book_reads_the_orders_again_after_a_minute_and_goes_back_a_year():
    clock = [1000.0]
    h = Hub(now=at(16))
    book = AddressBook(clock=lambda: clock[0])  # a book with a clock of the test's own
    assert book.listed(h.store, now_ms=h.now) == []
    brought(h, "d1", at(16, 1), ELM)
    assert book.listed(h.store, now_ms=h.now) == []  # the book stands for a minute
    clock[0] += 61
    assert book.listed(h.store, now_ms=h.now) == [ELM]
    brought(h, "d2", at(16, 2), ELMWOOD, phone=OMAR)
    h.op("d1", "void_order", at(16, 3))
    clock[0] += 61
    assert book.listed(h.store, now_ms=h.now) == [ELMWOOD]  # the voided one is gone, the new one is in
    # 401 days on, the delivery is too old to be read
    clock[0] += 61
    assert book.listed(h.store, now_ms=h.now + 401 * 86_400_000) == []


def test_a_hub_that_just_started_reads_old_orders_a_part_at_a_time_the_newest_first():
    h = Hub(now=at(10))
    for n in range(450):
        brought(h, f"d{n}", at(10) + n * 1000, f"{n + 1} Birch Ln, Stoneham", phone=f"781555{n:04d}")
    book = AddressBook(budget=0.0, every=0.0)  # no time at all: one part of the orders at each asking
    first = book.listed(h.store, now_ms=h.now)
    assert len(first) == 200 and first[0] == "450 Birch Ln, Stoneham"  # the newest two hundred
    assert len(book.listed(h.store, now_ms=h.now)) == 400
    assert len(book.listed(h.store, now_ms=h.now)) == 450 and len(book.listed(h.store, now_ms=h.now)) == 450


def test_the_restaurants_own_address_is_offered_no_delivery():
    h = delivered()
    assert listed(h, "12 el", own=False) == []


def test_asking_for_a_list_writes_nothing_and_opens_no_order():
    h = delivered()
    before = h.c.get("/orders").json()
    listed(h, "12 el", phone=LINDA)
    assert h.c.get("/orders").json() == before
    assert h.c.get("/customers/lookup", params={"phone": LINDA}).json()["orders"] == 2


# The map service ---------------------------------------------------------------------------------------------


def test_the_map_service_is_off_until_a_manager_turns_it_on():
    h = delivered()
    world = World(*WINCHESTER)
    asking(h, world, on=False)
    assert h.c.get("/settings/address_list").json() == {
        "google": False,
        "service": True,
        "asks": False,
        "credit": "Google Maps",
    }
    assert listed(h, "12 elm") == [(ELM, "orders")] and world.seen == []  # nothing left the building
    # only a manager turns it on
    assert h.c.put("/settings/address_list", json={"google": True}).status_code == 401
    server = h.c.post("/admin/session", json={"device": "t1", "pin": "1111"})
    assert server.status_code == 403
    told = h.c.put("/settings/address_list", json={"google": True}, headers=h.manager()).json()
    assert (told["google"], told["asks"]) == (True, True)
    assert listed(h, "12 elm")[1:] == [
        ("12 Elm Street, Winchester, MA", "google"),
        ("12 Elmwood Road, Winchester, MA", "google"),
    ]
    # and off again
    h.c.put("/settings/address_list", json={"google": False}, headers=h.manager())
    asked = len(world.seen)
    assert listed(h, "12 elm") == [(ELM, "orders")] and len(world.seen) == asked


def test_a_hub_with_no_google_key_lists_its_own_deliveries_alone():
    h = delivered()
    assert h.c.get("/settings/address_list").json() == {
        "google": False,
        "service": False,
        "asks": False,
        "credit": "Google Maps",
    }
    told = h.c.put("/settings/address_list", json={"google": True}, headers=h.manager()).json()
    assert (told["google"], told["service"], told["asks"]) == (True, False, False)  # turned on, and nobody to ask
    assert listed(h, "12 elm") == [(ELM, "orders")]
    tried = h.c.post("/settings/address_list/try", headers=h.manager())
    assert tried.status_code == 409 and tried.json()["detail"]["error"] == "no_service"


def test_google_is_sent_the_letters_typed_and_nothing_else(caplog):
    h = delivered()
    world = World(*WINCHESTER)
    suggester = asking(h, world)
    with caplog.at_level(logging.INFO):
        told = typed(h, "12 Elm", phone=LINDA)
        suggester.placed()
    # the restaurant's own first, then Google's, with its name to show under the list
    assert told["credit"] == "Google Maps"
    assert told["suggestions"] == [
        {"address": ELM, "main": ELM, "rest": "", "from": "customer"},
        {
            "address": "12 Elm Street, Winchester, MA",
            "main": "12 Elm Street",
            "rest": "Winchester, MA",
            "from": "google",
        },
        {
            "address": "12 Elmwood Road, Winchester, MA",
            "main": "12 Elmwood Road",
            "rest": "Winchester, MA",
            "from": "google",
        },
    ]
    (asked,) = [request for request in world.seen if b"includedPrimaryTypes" in request.content]
    assert (asked.method, str(asked.url)) == ("POST", "https://places.googleapis.com/v1/places:autocomplete")
    assert json.loads(asked.content) == {
        "input": "12 Elm",
        "includedRegionCodes": ["us"],
        "languageCode": "en",
        "includedPrimaryTypes": list(KINDS),  # addresses and streets: no shops, no towns
    }
    assert asked.headers["x-goog-api-key"] == "AIza-key-456"
    assert asked.headers["x-goog-fieldmask"] == (
        "suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat"
    )
    # no name, no number, nothing of an order: not in any request, and the log names no address and no key
    sent = b" ".join(request.content + str(request.url).encode() for request in world.seen)
    assert b"555" not in sent and b"Linda" not in sent and b"Oak" not in sent
    assert "Elm" not in caplog.text and "Restaurant Row" not in caplog.text and "AIza" not in caplog.text
    assert "ChIJ" not in caplog.text


def test_where_the_restaurant_stands_is_asked_once_and_streets_nearby_come_first():
    h = delivered()
    world = World(*WINCHESTER)
    suggester = asking(h, world)
    listed(h, "9 Birch")
    suggester.placed()
    # the restaurant's own address as Google reads it, then that place: only where it stands is asked for
    (first,) = [r for r in world.seen if r.method == "POST" and b"includedPrimaryTypes" not in r.content]
    (place,) = [r for r in world.seen if r.method == "GET"]
    assert json.loads(first.content) == {"input": HOME, "includedRegionCodes": ["us"], "languageCode": "en"}
    assert first.headers["x-goog-fieldmask"] == "suggestions.placePrediction.placeId"
    assert (place.method, str(place.url)) == ("GET", "https://places.googleapis.com/v1/places/ChIJ-home_1")
    assert place.headers["x-goog-fieldmask"] == "location" and place.headers["x-goog-api-key"] == "AIza-key-456"
    assert "locationBias" not in world.lists[0]  # nobody typing waited for it
    # from then on the streets around the restaurant come first, and it is not asked for again
    listed(h, "9 Birch L")
    listed(h, "9 Birch Ln")
    suggester.placed()
    circle = {"center": STANDS, "radius": NEAR_METERS}
    assert [body.get("locationBias") for body in world.lists] == [None, {"circle": circle}, {"circle": circle}]
    assert len(world.seen) == 5 and suggester.status()["asked_today"] == 5 and suggester.status()["placed"] is True
    # the restaurant's own address typed over: no delivery is listed, and nothing is said of where it stood
    listed(h, "1 Restaurant R", own=False)
    assert "locationBias" not in world.lists[-1]


def test_a_place_that_cannot_be_found_is_not_asked_for_again_within_the_hour():
    clock = [86400.0 * 20000]
    h = delivered()
    world = World(*WINCHESTER, place=None)
    suggester = asking(h, world, clock=lambda: clock[0])
    listed(h, "9 Birch")
    suggester.placed()
    listed(h, "9 Birch L")
    suggester.placed()
    assert len(world.seen) == 4 and suggester.status()["placed"] is False  # found once: two requests, no place
    assert all("locationBias" not in body for body in world.lists)
    clock[0] += 3601
    world.place = STANDS
    listed(h, "9 Birch Ln")
    suggester.placed()
    listed(h, "9 Birch Lane")
    assert world.lists[-1]["locationBias"]["circle"]["center"] == STANDS
    # a manager corrects the restaurant's address: where the new one stands is asked
    fee = {"enabled": False, "by": "miles", "bands": [], "taxed": False, "origin": "2 Restaurant Row, Winchester, MA"}
    h.c.put("/settings/delivery_fee", json=fee, headers=h.manager())
    seen = len(world.seen)
    listed(h, "9 Birch Lane W")
    suggester.placed()
    assert len(world.seen) == seen + 3 and "locationBias" not in world.lists[-1]


def test_three_of_the_restaurants_own_lead_a_list_of_six_at_most():
    h = Hub(now=at(16))
    for n in range(5):
        brought(h, f"d{n}", at(16, n), f"12 Elm Ct Unit {n + 1}, Woburn")
    world = World(*[prediction(f"12 Elm {word}, Medford, MA, USA") for word in ("Ave", "Rd", "Ln", "Way", "Pl")])
    asking(h, world, origin="")
    told = typed(h, "12 Elm")
    assert [one["from"] for one in told["suggestions"]] == ["orders"] * 3 + ["google"] * 3
    assert told["suggestions"][0]["address"] == "12 Elm Ct Unit 5, Woburn"
    # a prediction with no two parts reads as one, and the country is left off
    assert told["suggestions"][3] == {
        "address": "12 Elm Ave, Medford, MA",
        "main": "12 Elm Ave, Medford, MA",
        "rest": "",
        "from": "google",
    }
    # without Google's, five of the restaurant's own fit
    assert len(listed(h, "12")) == 5


def test_google_is_not_asked_about_too_few_letters_or_an_address_the_restaurant_knows_whole():
    h = delivered()
    world = World(*WINCHESTER)
    asking(h, world, origin="")
    assert listed(h, "12") == [(ELM, "orders"), (ELMWOOD, "orders"), (OAK, "orders")]
    assert listed(h, "12 ") == [(ELM, "orders"), (OAK, "orders")] and listed(h, "elm") != []
    assert listed(h, ELM.upper()) == [] and listed(h, ELM, phone=LINDA) == []  # picked, or filled in for her
    assert world.seen == []
    # an address Google lists that is the one typed, or one of the restaurant's own, is not listed twice
    world.predictions = [prediction("12 Elm St, Winchester, USA"), prediction("12 elm st, Winchester, MA, USA")]
    assert listed(h, "12 Elm St, Winchester, MA") == [(ELM, "google")] and len(world.seen) == 1
    assert listed(h, "12 Elm S") == [(ELM, "orders"), ("12 elm st, Winchester, MA", "google")]


@pytest.mark.parametrize(
    ("status", "reason"),
    [(403, "refused"), (401, "refused"), (429, "limit"), (500, "unreachable"), (400, "unreachable")],
)
def test_a_service_that_gives_no_list_never_fails_a_form(status, reason):
    h = delivered()
    world = World(*WINCHESTER, status=status)
    suggester = asking(h, world, origin="")
    told = typed(h, "12 Elm")
    assert told["suggestions"] == [{"address": ELM, "main": ELM, "rest": "", "from": "orders"}]
    assert told["credit"] is None  # nothing of Google's is in the list
    status_now = suggester.status()
    assert (status_now["asked_today"], status_now["failed_today"], status_now["last_failure"]) == (1, 1, reason)
    # a manager who tries it is told what is wrong
    tried = h.c.post("/settings/address_list/try", headers=h.manager()).json()
    assert (tried["ok"], tried["reason"]) == (False, reason)
    if reason == "refused":
        assert tried["message"] == "Google refused the hub's key. Is Places API (New) turned on for it?"
    assert h.c.post("/settings/address_list/try").status_code == 401


def test_a_service_that_does_not_answer_in_time_is_not_waited_for():
    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("too slow", request=request)

    h = delivered()
    places = Places("AIza-key-456", client=httpx.Client(transport=httpx.MockTransport(slow)))
    suggester = Suggester(places)
    h.c.app.state.suggester = suggester
    h.c.put("/settings/address_list", json={"google": True}, headers=h.manager())
    assert listed(h, "12 Elm") == [(ELM, "orders")]
    assert suggester.status()["last_failure"] == "unreachable"
    with pytest.raises(LookupFailed) as failed:
        places.suggest("12 Elm")
    assert failed.value.reason == "unreachable"


def test_trying_it_asks_about_the_restaurants_own_address_and_never_a_customers():
    h = delivered()
    world = World(prediction("1 Restaurant Row, Winchester, MA, USA"))
    suggester = asking(h, world, on=False)  # it can be tried before it is turned on
    assert h.c.post("/settings/address_list/try", headers=h.manager()).json() == {
        "ok": True,
        "found": 1,
        "reason": None,
        "message": "",
    }
    suggester.placed()
    assert world.lists == [
        {"input": HOME, "includedRegionCodes": ["us"], "languageCode": "en", "includedPrimaryTypes": list(KINDS)}
    ]
    # with no address of its own yet, a made-up one
    h2 = delivered()
    world2 = World()
    asking(h2, world2, on=False, origin="")
    assert h2.c.post("/settings/address_list/try", headers=h2.manager()).json()["found"] == 0
    assert [body["input"] for body in world2.lists] == ["1 Main St"]


def test_the_hub_asks_no_more_often_in_a_day_than_it_may():
    clock = [86400.0 * 20000]
    h = delivered()
    world = World(*WINCHESTER)
    suggester = asking(h, world, origin="", daily=3, clock=lambda: clock[0])
    for letters in ("12 E", "12 El", "12 Elm"):
        assert len(listed(h, letters)) == 3
    assert listed(h, "12 Elm S") == [(ELM, "orders")] and len(world.seen) == 3  # the fourth is not asked
    told = suggester.status()
    assert (told["asked_today"], told["daily_most"], told["last_failure"]) == (3, 3, "limit")
    assert h.c.post("/settings/address_list/try", headers=h.manager()).json()["reason"] == "limit"
    clock[0] += 86400  # the next day it is asked again
    assert len(listed(h, "12 Elm S")) == 3 and suggester.status()["asked_today"] == 1
    # where the restaurant stands is two requests, and is not asked for with one left
    h2 = delivered()
    world2 = World(*WINCHESTER)
    second = asking(h2, world2, daily=1)
    listed(h2, "12 Elm")
    second.placed()
    assert len(world2.seen) == 1 and second.status()["asked_today"] == 1


def test_what_google_answers_is_read_with_care():
    world = World(
        prediction("  12   Elm Street, Winchester, MA, USA ", "12 Elm Street", "Winchester, MA, USA"),
        {"queryPrediction": {"text": {"text": "elm street pizza"}}},  # no place: not an address
        {"placePrediction": {"text": {"text": 12}}},
        {"placePrediction": {"text": {"text": "x" * 201}}},
        "nonsense",
        prediction("USA", "USA", ""),
        prediction("Elm Street, Winchester, MA, United States", "Elm Street", "United States"),
    )
    assert world.places().suggest("12 Elm") == [
        Suggestion("12 Elm Street, Winchester, MA", "12 Elm Street", "Winchester, MA", "google"),
        Suggestion("Elm Street, Winchester, MA", "Elm Street", "", "google"),
    ]
    assert World().places().suggest("12 Elm") == []  # an answer with nothing in it
    # what is listed can be set on the hub: nothing named lists everything Google knows
    plain = World(*WINCHESTER)
    plain.places(kinds=[]).suggest("12 Elm")
    assert "includedPrimaryTypes" not in json.loads(plain.seen[0].content)
    # where a place stands, read: a number that is no latitude, and no place at all
    assert World(place={"latitude": 42.45, "longitude": -71.13}).places().locate(HOME) == (42.45, -71.13)
    assert World(place={"latitude": 142.45, "longitude": -71.13}).places().locate(HOME) is None
    assert World(place={"latitude": True, "longitude": -71.13}).places().locate(HOME) is None
    assert World(place=None).places().locate(HOME) is None


def test_the_hubs_own_file_says_whether_there_is_a_service_and_how_often_it_is_asked():
    assert places_from_env({}) is None and places_from_env({"POS_MAPS_GOOGLE_KEY": "  "}) is None
    assert places_from_env({"POS_MAPS_GOOGLE_KEY": "AIza-key-456"}).name == "google"
    assert suggester_from_env({}).ready is False and suggester_from_env({}).status() is None
    told = suggester_from_env({"POS_MAPS_GOOGLE_KEY": "AIza-key-456", "POS_MAPS_SUGGEST_DAILY": "40"}).status()
    assert told == {
        "service": "google",
        "asked_today": 0,
        "failed_today": 0,
        "daily_most": 40,
        "last_failure": None,
        "placed": False,
    }
    assert (
        suggester_from_env({"POS_MAPS_GOOGLE_KEY": "k" * 20, "POS_MAPS_SUGGEST_DAILY": "many"}).status()["daily_most"]
        == 300
    )
    # what Google lists: addresses and streets unless the hub's file names something else
    said: list[httpx.Request] = []

    def answer(request: httpx.Request) -> httpx.Response:
        said.append(request)
        return httpx.Response(200, json={})

    for named, kinds in (("", list(KINDS)), ("premise, route", ["premise", "route"]), ("ALL", None)):
        places = places_from_env({"POS_MAPS_GOOGLE_KEY": "AIza-key-456", "POS_MAPS_SUGGEST_TYPES": named})
        places._client = httpx.Client(transport=httpx.MockTransport(answer))
        places.suggest("12 Elm")
        assert json.loads(said[-1].content).get("includedPrimaryTypes") == kinds
    # a key typed or removed while the hub runs
    suggester = suggester_from_env({})
    suggester.use(places_from_env({"POS_MAPS_GOOGLE_KEY": "AIza-key-456"}))
    assert suggester.ready
    suggester.use(None)
    assert not suggester.ready
    with pytest.raises(LookupFailed):
        suggester.suggest("12 Elm")


def test_the_status_says_how_often_the_list_asked_and_whether_it_is_on():
    h = delivered()
    assert h.c.get("/maps/status").json()["suggest"] is None
    world = World(*WINCHESTER)
    asking(h, world, on=False, origin="")
    assert h.c.get("/maps/status").json()["suggest"] == {
        "service": "google",
        "asked_today": 0,
        "failed_today": 0,
        "daily_most": 300,
        "last_failure": None,
        "placed": False,
        "enabled": False,
    }
    h.c.put("/settings/address_list", json={"google": True}, headers=h.manager())
    listed(h, "12 Elm")
    told = h.c.get("/maps/status").json()["suggest"]
    assert (told["enabled"], told["asked_today"]) == (True, 1)
    assert "Elm" not in json.dumps(h.c.get("/maps/status").json())  # no address is in it


def test_a_bad_setting_is_refused():
    h = Hub(now=at(16))
    refused = h.c.put("/settings/address_list", json={"google": "yes please"}, headers=h.manager())
    assert refused.status_code == 422
    assert h.c.get("/settings/address_list").json()["google"] is False


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_same_list_from_postgres():
    import psycopg

    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(16), postgres=DSN)
    try:
        delivered(h)
        h.op("d2", "void_order", at(16, 5))
        assert listed(h, "12") == [(ELM, "orders"), (OAK, "orders")] and listed(h, "elmw") == []
        assert listed(h, "12", phone=LINDA) == [(ELM, "customer"), (OAK, "customer")]
        assert own_addresses(h.store, LINDA) == [OAK, ELM]
    finally:
        h.store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS ops, orders")
