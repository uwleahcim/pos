"""A list of addresses while one is being typed (docs/delivery.md, "A list of addresses while typing").

Wherever a screen asks for a street address, the hub says what the letters typed so far could become. The
restaurant's own earlier deliveries come first and ask nobody. A map service is asked only where a manager
turned it on: it is sent the letters typed and nothing else, what it answers is not kept, and a service that
gives no list never fails a form.

There are three map services, Google, Mapbox and Azure Maps, asked in that order: the next one only when
the one before it gave no answer, because its free amount for the month is used up or because it is down.
The hub counts how often each was asked this month, and a screen is told who answered and how much is left."""

from __future__ import annotations

import json
import logging
import os
import time

import httpx
import pytest

from pos.addresses import (
    KINDS,
    MONTHLY_MOST,
    NEAR_METERS,
    REST,
    US_BOX,
    AddressBook,
    Asked,
    Azure,
    Mapbox,
    PgAsked,
    Places,
    Suggester,
    Suggestion,
    azure_from_env,
    fits,
    known,
    mapbox_from_env,
    month_of,
    own_addresses,
    places_from_env,
    said,
    services_from_env,
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
        "service": None,
        "title": None,
        "left": None,
        "monthly_most": None,
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
    told = h.c.get("/settings/address_list").json()
    assert {name: told[name] for name in ("google", "mapbox", "azure", "service", "asks", "credit")} == {
        "google": False,
        "mapbox": False,
        "azure": False,
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
    told = h.c.get("/settings/address_list").json()
    assert (told["google"], told["service"], told["asks"], told["credit"]) == (False, False, False, "Google Maps")
    assert [(one["name"], one["key"], one["on"], one["left"]) for one in told["services"]] == [
        ("google", False, False, None),
        ("mapbox", False, False, None),
        ("azure", False, False, None),
    ]
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
    # the restaurant's own first, then Google's, with its name to show under the list and what it has left
    assert (told["credit"], told["service"], told["title"]) == ("Google Maps", "google", "Google Maps")
    assert told["left"] == MONTHLY_MOST["google"] - 3  # this list, and where the restaurant stands: two requests
    assert told["monthly_most"] == 9500  # of so many: a screen draws what is left as a ring
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
    assert told["credit"] is None and told["service"] is None and told["left"] is None  # nothing of Google's
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
        "service": "google",
        "left": MONTHLY_MOST["google"] - 1,
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


def test_the_hub_asks_no_more_often_in_a_month_than_the_service_gives_away():
    clock = [86400.0 * 20000]  # the fourth of October
    h = delivered()
    world = World(*WINCHESTER)
    suggester = asking(h, world, origin="", monthly=3, clock=lambda: clock[0])
    for letters in ("12 E", "12 El", "12 Elm"):
        assert len(listed(h, letters)) == 3
    assert typed(h, "12 Elm")["left"] is None, "the address the restaurant knows whole asks nobody"
    assert listed(h, "12 Elm S") == [(ELM, "orders")] and len(world.seen) == 3  # the fourth is not asked
    told = suggester.status()
    assert (told["asked_month"], told["monthly_most"], told["left"], told["last_failure"]) == (3, 3, 0, "limit")
    tried = h.c.post("/settings/address_list/try", headers=h.manager()).json()
    assert (tried["reason"], tried["left"]) == ("limit", 0)
    assert tried["message"] == "Google has been asked as often as it may be this month."
    clock[0] += 86400  # the next day changes nothing: the month is the same
    assert listed(h, "12 Elm S") == [(ELM, "orders")] and suggester.status()["asked_today"] == 0
    clock[0] += 86400 * 28  # the next month it is asked again
    assert len(listed(h, "12 Elm S")) == 3
    told = suggester.status()
    assert (told["asked_month"], told["left"]) == (1, 2)
    # where the restaurant stands is two requests, and is not asked for with one left
    h2 = delivered()
    world2 = World(*WINCHESTER)
    second = asking(h2, world2, monthly=1)
    listed(h2, "12 Elm")
    second.placed()
    assert len(world2.seen) == 1 and second.status()["asked_month"] == 1


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
    told = suggester_from_env({"POS_MAPS_GOOGLE_KEY": "AIza-key-456", "POS_MAPS_SUGGEST_MONTHLY": "40"}).status()
    assert told == {
        "service": "google",
        "asked_month": 0,
        "monthly_most": 40,
        "left": 40,
        "asked_today": 0,
        "failed_today": 0,
        "last_failure": None,
        "placed": False,
        "resting": False,
    }
    unread = suggester_from_env({"POS_MAPS_GOOGLE_KEY": "k" * 20, "POS_MAPS_SUGGEST_MONTHLY": "many"}).status()
    assert unread["monthly_most"] == 9500  # Google gave 10,000 away each month: the hub stops a twentieth short
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
    assert suggester.ready and suggester.names == ["google"]
    suggester.use(None)
    assert not suggester.ready and suggester.left("google") is None
    with pytest.raises(LookupFailed):
        suggester.suggest("12 Elm")


def test_the_status_says_how_often_the_list_asked_and_whether_it_is_on():
    h = delivered()
    assert h.c.get("/maps/status").json()["suggest"] is None
    world = World(*WINCHESTER)
    asking(h, world, on=False, origin="")
    google = {
        "service": "google",
        "asked_month": 0,
        "monthly_most": 9500,
        "left": 9500,
        "asked_today": 0,
        "failed_today": 0,
        "last_failure": None,
        "placed": False,
        "resting": False,
        "enabled": False,
    }
    assert h.c.get("/maps/status").json()["suggest"] == google
    assert h.c.get("/maps/status").json()["suggests"] == [google]
    h.c.put("/settings/address_list", json={"google": True}, headers=h.manager())
    listed(h, "12 Elm")
    told = h.c.get("/maps/status").json()["suggest"]
    assert (told["enabled"], told["asked_today"], told["asked_month"], told["left"]) == (True, 1, 1, 9499)
    assert "Elm" not in json.dumps(h.c.get("/maps/status").json())  # no address is in it


def test_a_bad_setting_is_refused():
    h = Hub(now=at(16))
    refused = h.c.put("/settings/address_list", json={"google": "yes please"}, headers=h.manager())
    assert refused.status_code == 422
    assert h.c.put("/settings/address_list", json={"azure": 7}, headers=h.manager()).status_code == 422
    assert h.c.get("/settings/address_list").json()["google"] is False


# Mapbox and Azure Maps ---------------------------------------------------------------------------------------

TOKEN = "pk.made-up-token-789"
AZURE_KEY = "made-up-azure-key-000"
WINCHESTER_MA = "Winchester, Massachusetts 01890"


def feature(name: str, place: str = WINCHESTER_MA, state: str = "Massachusetts", code: str = "MA") -> dict:
    """One address as Mapbox tells it: the street, and the town with the state spelled out."""
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [-71.137, 42.4523]},
        "properties": {
            "feature_type": "address",
            "name": name,
            "place_formatted": f"{place}, United States",
            "full_address": f"{name}, {place}, United States",
            "context": {"region": {"name": state, "region_code": code, "region_code_full": f"US-{code}"}},
        },
    }


class MapboxWorld:
    """Mapbox's Geocoding API as far as the hub uses it, and everything it was asked."""

    def __init__(self, *features: object, status: int = 200) -> None:
        self.features = list(features)
        self.status = status
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"message": "Not Authorized - Invalid Token"})
        return httpx.Response(200, json={"type": "FeatureCollection", "features": self.features})

    def mapbox(self, **more) -> Mapbox:
        return Mapbox(TOKEN, client=httpx.Client(transport=httpx.MockTransport(self)), **more)


def found(line: str, rest: str = "Winchester, MA 01890") -> dict:
    """One address as Azure Maps tells it."""
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [-71.137, 42.4523]},
        "properties": {
            "typeGroup": "Address",
            "address": {
                "addressLine": line,
                "formattedAddress": f"{line}, {rest}, United States",
                "countryRegion": {"ISO": "US", "name": "United States"},
            },
        },
    }


class AzureWorld:
    """Azure Maps' Search as far as the hub uses it, and everything it was asked."""

    def __init__(self, *features: object, status: int = 200, stands: list | None = None) -> None:
        self.features = list(features)
        self.status = status
        self.stands = [-71.137, 42.4523] if stands is None else stands  # longitude first, as it says it
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"error": {"code": "Unauthorized"}})
        if request.url.path == "/geocode":  # where the restaurant stands
            place = [{"type": "Feature", "geometry": {"type": "Point", "coordinates": self.stands}}]
            return httpx.Response(200, json={"type": "FeatureCollection", "features": place if self.stands else []})
        return httpx.Response(200, json={"type": "FeatureCollection", "features": self.features})

    def azure(self) -> Azure:
        return Azure(AZURE_KEY, client=httpx.Client(transport=httpx.MockTransport(self)))

    @property
    def lists(self) -> list[dict]:
        """What each asking for a list said, in order."""
        return [dict(request.url.params) for request in self.seen if request.url.path == "/geocode:autocomplete"]


def chain(h: Hub, *services, on: tuple[str, ...] = ("google", "mapbox", "azure"), origin: str = "", **more):
    """The hub with these map services, and the list's use of the ones named turned on."""
    suggester = Suggester(*services, **more)
    h.c.app.state.suggester = suggester
    if origin:
        fee = {"enabled": False, "by": "miles", "bands": [], "taxed": False, "origin": origin}
        assert h.c.put("/settings/delivery_fee", json=fee, headers=h.manager()).status_code == 200
    setting = {name: name in on for name in ("google", "mapbox", "azure")}
    assert h.c.put("/settings/address_list", json=setting, headers=h.manager()).status_code == 200
    return suggester


def try_it(h: Hub, service: str | None = None) -> dict:
    body = {} if service is None else {"service": service}
    return h.c.post("/settings/address_list/try", json=body, headers=h.manager()).json()


def test_mapbox_is_sent_the_letters_typed_and_nothing_else(caplog):
    h = delivered()
    world = MapboxWorld(feature("12 Elm Street"), feature("12 Elmwood Road"))
    suggester = chain(h, world.mapbox(), origin=HOME)
    with caplog.at_level(logging.INFO):
        told = typed(h, "12 Elm", phone=LINDA)
        suggester.placed()
    # the restaurant's own first, then Mapbox's, with its name to show under the list and what it has left
    assert (told["credit"], told["service"], told["title"]) == ("© Mapbox © OpenStreetMap", "mapbox", "Mapbox")
    assert told["left"] == MONTHLY_MOST["mapbox"] - 1 == 94_999
    assert told["suggestions"] == [
        {"address": ELM, "main": ELM, "rest": "", "from": "customer"},
        {
            "address": "12 Elm Street, Winchester, MA 01890",  # the state by its two letters, the country left off
            "main": "12 Elm Street",
            "rest": "Winchester, MA 01890",
            "from": "mapbox",
        },
        {
            "address": "12 Elmwood Road, Winchester, MA 01890",
            "main": "12 Elmwood Road",
            "rest": "Winchester, MA 01890",
            "from": "mapbox",
        },
    ]
    # one request: it is never asked where the restaurant stands, because nothing it answers may be kept
    (asked,) = world.seen
    assert (asked.method, asked.url.host, asked.url.path) == ("GET", "api.mapbox.com", "/search/geocode/v6/forward")
    assert dict(asked.url.params) == {
        "q": "12 Elm",
        "autocomplete": "true",
        "country": "us",
        "language": "en",
        "limit": "5",
        "proximity": "ip",  # where the hub's own internet connection is
        "access_token": TOKEN,
        "types": "address,street",  # addresses and streets: no shops, no towns
    }
    assert asked.content == b""
    # no name, no number, nothing of an order; and the log names no address and no token
    sent = str(asked.url).encode()
    assert b"555" not in sent and b"Linda" not in sent and b"Oak" not in sent and b"Restaurant" not in sent
    assert "Elm" not in caplog.text and "pk." not in caplog.text and "access_token" not in caplog.text


def test_what_mapbox_answers_is_read_with_care():
    world = MapboxWorld(
        feature("  12   Elm Street "),
        feature("5 Broadway", "New York, New York 10004", state="New York", code="NY"),  # the state, not the town
        # nothing said of the state: it stays as it is spelled
        {"properties": {"name": "Elm Street", "place_formatted": "Winchester, Massachusetts, United States"}},
        {"properties": {"full_address": "9 Birch Lane, Stoneham, Massachusetts 02180, United States"}},
        {"properties": {"name": "x" * 201}},
        {"properties": {"name": 12}},
        {"type": "Feature"},
        "nonsense",
    )
    assert world.mapbox().suggest("12 Elm") == [
        Suggestion("12 Elm Street, Winchester, MA 01890", "12 Elm Street", "Winchester, MA 01890", "mapbox"),
        Suggestion("5 Broadway, New York, NY 10004", "5 Broadway", "New York, NY 10004", "mapbox"),
        Suggestion("Elm Street, Winchester, Massachusetts", "Elm Street", "Winchester, Massachusetts", "mapbox"),
        Suggestion("9 Birch Lane, Stoneham, Massachusetts 02180", "", "", "mapbox"),
    ]
    assert MapboxWorld().mapbox().suggest("12 Elm") == []  # an answer with nothing in it
    answer = httpx.Response(200, json=["no", "collection"])
    assert Mapbox(TOKEN, client=httpx.Client(transport=httpx.MockTransport(lambda _: answer))).suggest("12 Elm") == []
    # a semicolon would make two askings of one; and what is listed can be everything Mapbox knows
    plain = MapboxWorld()
    plain.mapbox(kinds=[]).suggest("12 Elm; 4 Oak")
    assert dict(plain.seen[0].url.params)["q"] == "12 Elm  4 Oak" and "types" not in dict(plain.seen[0].url.params)
    # what it says instead of a list
    for status, reason in (
        (401, "refused"),
        (403, "refused"),
        (429, "limit"),
        (422, "not_found"),
        (500, "unreachable"),
    ):
        with pytest.raises(LookupFailed) as failed:
            MapboxWorld(status=status).mapbox().suggest("12 Elm")
        assert (failed.value.reason, failed.value.code) == (reason, status)
    assert world.mapbox().locate(HOME) is None and len(world.seen) == 1  # never asked where anything stands


def test_azure_maps_is_sent_the_letters_typed_and_where_the_restaurant_stands(caplog):
    h = delivered()
    world = AzureWorld(found("12 Elm St"), found("12 Elmwood Rd"))
    suggester = chain(h, world.azure(), origin=HOME)
    with caplog.at_level(logging.INFO):
        told = typed(h, "12 Elm", phone=LINDA)
        suggester.placed()
    assert (told["credit"], told["service"], told["title"]) == ("Azure Maps", "azure", "Azure Maps")
    assert told["suggestions"] == [
        {"address": ELM, "main": ELM, "rest": "", "from": "customer"},
        {
            "address": "12 Elm St, Winchester, MA 01890",
            "main": "12 Elm St",
            "rest": "Winchester, MA 01890",
            "from": "azure",
        },
        {
            "address": "12 Elmwood Rd, Winchester, MA 01890",
            "main": "12 Elmwood Rd",
            "rest": "Winchester, MA 01890",
            "from": "azure",
        },
    ]
    (first,) = [request for request in world.seen if request.url.path == "/geocode:autocomplete"]
    assert (first.method, first.url.host) == ("GET", "atlas.microsoft.com")
    assert dict(first.url.params) == {
        "api-version": "2026-01-01",
        "query": "12 Elm",
        "countryRegion": "US",
        "resultTypeGroups": "Address",  # addresses and streets: no shops, no towns
        "top": "5",
        "bbox": US_BOX,  # the whole country: nobody typing waited to hear where the restaurant stands
    }
    assert first.headers["subscription-key"] == AZURE_KEY
    # where the restaurant stands is asked once, behind the list: its own address, and no customer's
    (place,) = [request for request in world.seen if request.url.path == "/geocode"]
    assert dict(place.url.params) == {"api-version": "2026-01-01", "query": HOME, "top": "1"}
    assert place.headers["subscription-key"] == AZURE_KEY
    # that one is a whole transaction of Azure's, which ten askings for a list come to
    assert suggester.left("azure") == MONTHLY_MOST["azure"] - 11 == 47_489
    # from then on the streets around the restaurant come first, and it is not asked for again
    assert typed(h, "12 Elm S")["left"] == 47_488
    suggester.placed()
    assert world.lists[-1]["coordinates"] == "-71.137,42.4523" and "bbox" not in world.lists[-1]
    assert len(world.seen) == 3 and suggester.statuses()[0]["placed"] is True
    # the key is in no address of a request; no name, no number; and the log names no address and no key
    sent = b" ".join(str(request.url).encode() for request in world.seen)
    assert AZURE_KEY.encode() not in sent and b"555" not in sent and b"Linda" not in sent and b"Oak" not in sent
    assert "Elm" not in caplog.text and "Restaurant" not in caplog.text and AZURE_KEY not in caplog.text


def test_what_azure_maps_answers_is_read_with_care():
    world = AzureWorld(
        {
            "properties": {
                "address": {
                    "addressLine": "  12   Elm St ",
                    "formattedAddress": " 12   Elm St, Winchester,  MA 01890, United States ",
                }
            }
        },
        {"properties": {"address": {"formattedAddress": "Elm St, Winchester, MA 01890, United States"}}},  # no line
        {"properties": {"address": {"addressLine": "9 Birch Ln"}}},  # the street alone
        {"properties": {"address": {"addressLine": "4 Oak Rd", "formattedAddress": "Oak Road 4, Woburn, MA"}}},
        {"properties": {"address": {"addressLine": "x" * 201}}},
        {"properties": {"address": "12 Elm St"}},
        {"properties": {"address": {"addressLine": 12}}},
        {"type": "Feature"},
        "nonsense",
    )
    assert world.azure().suggest("12 Elm") == [
        Suggestion("12 Elm St, Winchester, MA 01890", "12 Elm St", "Winchester, MA 01890", "azure"),
        Suggestion("Elm St, Winchester, MA 01890", "", "", "azure"),
        Suggestion("9 Birch Ln", "", "", "azure"),
        Suggestion("Oak Road 4, Woburn, MA", "", "", "azure"),  # it does not begin with the street: one part
    ]
    assert AzureWorld().azure().suggest("12 Elm") == []  # an answer with nothing in it
    for status, reason in (
        (401, "refused"),
        (403, "refused"),
        (429, "limit"),
        (404, "not_found"),
        (500, "unreachable"),
    ):
        with pytest.raises(LookupFailed) as failed:
            AzureWorld(status=status).azure().suggest("12 Elm")
        assert (failed.value.reason, failed.value.code) == (reason, status)
    # where a place stands, read: longitude first, a number that is no latitude, and no place at all
    assert AzureWorld().azure().locate(HOME) == (42.4523, -71.137)
    assert AzureWorld(stands=[-71.137, 142.45]).azure().locate(HOME) is None
    assert AzureWorld(stands=[-71.137]).azure().locate(HOME) is None
    assert AzureWorld(stands=[]).azure().locate(HOME) is None


# One after the other ------------------------------------------------------------------------------------------


def three() -> tuple[World, MapboxWorld, AzureWorld]:
    """All three services, each with an answer of its own."""
    return World(*WINCHESTER), MapboxWorld(feature("12 Elm Street")), AzureWorld(found("12 Elm St"))


def test_once_googles_month_is_used_up_the_next_service_is_asked():
    h = delivered()
    google, mapbox, azure = three()
    monthly = {"google": 2, "mapbox": 1, "azure": 100}
    chain(h, google.places(), mapbox.mapbox(), azure.azure(), monthly=monthly)
    assert [typed(h, letters)["service"] for letters in ("12 E", "12 El")] == ["google", "google"]
    told = typed(h, "12 Elm")
    assert (told["service"], told["title"], told["credit"], told["left"]) == (
        "mapbox",
        "Mapbox",
        "© Mapbox © OpenStreetMap",
        0,
    )
    assert [one["from"] for one in told["suggestions"]] == ["orders", "mapbox"]  # one service's answers, never two
    told = typed(h, "12 Elm S")
    assert (told["service"], told["left"], told["monthly_most"]) == ("azure", 99, 100)
    assert (len(google.seen), len(mapbox.seen), len(azure.seen)) == (2, 1, 1)
    # the setting says how each stands
    services = h.c.get("/settings/address_list").json()["services"]
    assert [(one["name"], one["left"], one["monthly_most"], one["used_up"]) for one in services] == [
        ("google", 0, 2, True),
        ("mapbox", 0, 1, True),
        ("azure", 99, 100, False),
    ]


def test_while_google_is_down_the_next_service_is_asked_and_google_is_left_alone_for_a_minute():
    clock = [86400.0 * 20000]
    h = delivered()
    google, mapbox, azure = three()
    google.status = 500
    suggester = chain(h, google.places(), mapbox.mapbox(), azure.azure(), clock=lambda: clock[0])
    assert typed(h, "12 E")["service"] == "mapbox"
    assert (len(google.seen), len(mapbox.seen), len(azure.seen)) == (1, 1, 0)
    # nobody typing waits for Google again at every letter
    assert [typed(h, letters)["service"] for letters in ("12 El", "12 Elm")] == ["mapbox", "mapbox"]
    assert (len(google.seen), len(mapbox.seen)) == (1, 3)
    told = {one["service"]: one for one in suggester.statuses()}
    assert (told["google"]["resting"], told["google"]["last_failure"], told["google"]["failed_today"]) == (
        True,
        "unreachable",
        1,
    )
    assert told["mapbox"]["resting"] is False and told["mapbox"]["asked_today"] == 3
    assert [one["resting"] for one in h.c.get("/settings/address_list").json()["services"]] == [True, False, False]
    # a minute on it is asked again, and is back
    clock[0] += REST["unreachable"] + 1
    google.status = 200
    assert typed(h, "12 Elm S")["service"] == "google" and len(mapbox.seen) == 3
    assert suggester.statuses()[0]["resting"] is False


def test_a_key_that_is_refused_rests_five_minutes_and_trying_it_out_ends_the_rest():
    clock = [86400.0 * 20000]
    h = delivered()
    google, mapbox, _ = three()
    google.status = 403
    chain(h, google.places(), mapbox.mapbox(), clock=lambda: clock[0])
    assert typed(h, "12 E")["service"] == "mapbox"
    clock[0] += 61
    assert typed(h, "12 El")["service"] == "mapbox" and len(google.seen) == 1  # a refused key is not better yet
    # a manager who tries it asks it all the same, and is told what is wrong
    assert (try_it(h, "google")["reason"], len(google.seen)) == ("refused", 2)
    # the key is put right: trying it out asks it, it answers, and it is asked first again
    google.status = 200
    tried = try_it(h, "google")
    assert (tried["ok"], tried["service"], tried["found"]) == (True, "google", 2)
    assert typed(h, "12 Elm")["service"] == "google" and len(mapbox.seen) == 2
    # and one that the service itself says is asked too often rests as long
    google.status = 429
    assert typed(h, "12 Elm S")["service"] == "mapbox"
    clock[0] += REST["limit"] - 1
    assert typed(h, "12 Elm St")["service"] == "mapbox"
    clock[0] += 2
    google.status = 200
    assert typed(h, "12 Elm St,")["service"] == "google"


def test_a_service_that_answers_with_nothing_has_answered_and_nobody_else_is_asked():
    h = delivered()
    google, mapbox, azure = three()
    google.predictions = []
    suggester = chain(h, google.places(), mapbox.mapbox(), azure.azure())
    told = typed(h, "9 Birch")
    assert told["suggestions"] == [] and told["service"] is None and told["left"] is None
    # the same when it says there is no address like that
    google.status = 404
    assert listed(h, "9 Birch L") == []
    assert (len(google.seen), len(mapbox.seen), len(azure.seen)) == (2, 0, 0)
    assert suggester.statuses()[0]["resting"] is False  # it answered: it is asked again at the next letter


def test_a_service_that_is_turned_off_or_has_no_key_is_passed_over():
    h = delivered()
    google, mapbox, azure = three()
    chain(h, google.places(), mapbox.mapbox(), azure.azure(), on=("mapbox", "azure"))
    assert typed(h, "12 Elm")["service"] == "mapbox" and google.seen == [] and azure.seen == []
    # Google turned on with no key for it on this hub, Mapbox turned off: Azure Maps is the one to ask
    chain(h, mapbox.mapbox(), azure.azure(), on=("google", "azure"))
    assert typed(h, "12 Elm")["service"] == "azure" and len(mapbox.seen) == 1
    told = h.c.get("/settings/address_list").json()
    assert [(one["name"], one["on"], one["key"], one["asks"]) for one in told["services"]] == [
        ("google", True, False, False),
        ("mapbox", False, True, False),
        ("azure", True, True, True),
    ]
    assert (told["service"], told["asks"]) == (False, False)  # what an app from before is told of Google
    # none turned on: nothing leaves the building
    chain(h, google.places(), mapbox.mapbox(), azure.azure(), on=())
    assert listed(h, "12 Elm") == [(ELM, "orders")] and (len(google.seen), len(mapbox.seen), len(azure.seen)) == (
        0,
        1,
        1,
    )
    # whatever order they are handed in, they are asked in their own
    assert Suggester(azure.azure(), google.places(), mapbox.mapbox()).names == ["google", "mapbox", "azure"]


def test_when_no_service_answers_the_list_holds_the_restaurants_own_alone():
    h = delivered()
    google, mapbox, azure = three()
    google.status, mapbox.status, azure.status = 500, 401, 429
    suggester = chain(h, google.places(), mapbox.mapbox(), azure.azure())
    told = typed(h, "12 Elm")
    assert told["suggestions"] == [{"address": ELM, "main": ELM, "rest": "", "from": "orders"}]
    assert (told["credit"], told["service"], told["title"], told["left"], told["monthly_most"]) == (None,) * 5
    assert [(one["service"], one["last_failure"], one["resting"]) for one in suggester.statuses()] == [
        ("google", "unreachable", True),
        ("mapbox", "refused", True),
        ("azure", "limit", True),
    ]
    # while they rest nobody is asked, and nobody typing waits
    assert listed(h, "12 Elm S") == [(ELM, "orders")]
    assert (len(google.seen), len(mapbox.seen), len(azure.seen)) == (1, 1, 1)
    with pytest.raises(LookupFailed) as failed:
        suggester.suggest("12 Elm St")
    assert failed.value.reason == "unreachable"  # what the first of them said


def test_all_of_them_together_are_waited_for_no_longer_than_a_form_waits():
    def slow(request: httpx.Request) -> httpx.Response:
        time.sleep(0.6)
        return httpx.Response(200, json={})

    h = delivered()
    late = Places("AIza-key-456", client=httpx.Client(transport=httpx.MockTransport(slow)))
    mapbox = MapboxWorld(feature("12 Elm Street"))
    # Google is waited for, and then too little time is left for anybody else
    chain(h, late, mapbox.mapbox(), wait=0.3, within=0.5)
    began = time.monotonic()
    assert listed(h, "12 Elm") == [(ELM, "orders")]
    assert time.monotonic() - began < 0.6 and mapbox.seen == []
    # with time left, the next one is asked once Google was not heard from
    chain(h, late, mapbox.mapbox(), wait=0.1, within=3.0)
    assert typed(h, "12 Elm S")["service"] == "mapbox"


# Turning them on, and trying them out --------------------------------------------------------------------------


def test_the_setting_says_how_each_service_stands_in_the_order_they_are_asked():
    h = delivered()
    google, mapbox, _ = three()
    chain(h, google.places(), mapbox.mapbox(), on=("google",))
    assert h.c.get("/settings/address_list").json() == {
        "google": True,
        "mapbox": False,
        "azure": False,
        "service": True,
        "asks": True,
        "credit": "Google Maps",
        "services": [
            {
                "name": "google",
                "title": "Google Maps",
                "credit": "Google Maps",
                "on": True,
                "key": True,
                "asks": True,
                "left": 9500,
                "monthly_most": 9500,
                "used_up": False,
                "resting": False,
            },
            {
                "name": "mapbox",
                "title": "Mapbox",
                "credit": "© Mapbox © OpenStreetMap",
                "on": False,
                "key": True,
                "asks": False,
                "left": 95_000,
                "monthly_most": 95_000,
                "used_up": False,
                "resting": False,
            },
            {
                "name": "azure",
                "title": "Azure Maps",
                "credit": "Azure Maps",
                "on": False,
                "key": False,
                "asks": False,
                "left": None,
                "monthly_most": 47_500,
                "used_up": False,
                "resting": False,
            },
        ],
    }


def test_an_app_from_before_there_were_several_turns_google_on_and_leaves_the_others():
    h = Hub(now=at(16))

    def put(**named) -> tuple[bool, bool, bool]:
        answer = h.c.put("/settings/address_list", json=named, headers=h.manager())
        assert answer.status_code == 200, answer.text
        return tuple(answer.json()[name] for name in ("google", "mapbox", "azure"))

    assert put(mapbox=True, azure=True) == (False, True, True)
    assert put(google=True) == (True, True, True)  # the old app names Google alone
    assert put(google=False) == (False, True, True)
    assert put(azure=False) == (False, True, False) and put() == (False, True, False)
    assert h.c.put("/settings/address_list", json={"mapbox": "perhaps"}, headers=h.manager()).status_code == 422
    assert h.c.put("/settings/address_list", json={"mapbox": False}).status_code == 401


def test_each_service_is_tried_by_itself_whatever_the_others_do():
    h = delivered()
    google, mapbox, azure = three()
    mapbox.status = 401
    chain(h, google.places(), mapbox.mapbox(), on=(), origin=HOME)  # tried before any is turned on
    assert try_it(h, "mapbox") == {
        "ok": False,
        "found": 0,
        "reason": "refused",
        "message": "Mapbox refused the hub's token. Copy it again from your Mapbox account; "
        "it must have no URL restriction.",
        "service": "mapbox",
        "left": 94_999,
    }
    assert google.seen == []  # nobody else was asked in its place
    # asked about the restaurant's own address, never a customer's
    assert dict(mapbox.seen[0].url.params)["q"] == HOME
    mapbox.status = 200
    assert try_it(h, "mapbox") == {
        "ok": True,
        "found": 1,
        "reason": None,
        "message": "",
        "service": "mapbox",
        "left": 94_998,
    }
    mapbox.status = 500
    assert try_it(h, "mapbox")["message"] == "Mapbox answered 500, which is no list. Tell whoever looks after the hub."
    # a service this hub has no key for, and a name that is no service's
    none = h.c.post("/settings/address_list/try", json={"service": "azure"}, headers=h.manager())
    assert none.status_code == 409 and none.json()["detail"] == {
        "error": "no_service",
        "message": "this hub has no key for Azure Maps",
    }
    unknown = h.c.post("/settings/address_list/try", json={"service": "bing"}, headers=h.manager())
    assert unknown.status_code == 422 and unknown.json()["detail"]["error"] == "bad_value"
    assert h.c.post("/settings/address_list/try", json={"service": "mapbox"}).status_code == 401
    # Google unless one is named: an app from before there were several sends nothing
    assert try_it(h)["service"] == "google" and len(google.lists) == 1
    assert h.c.post("/settings/address_list/try", headers=h.manager()).json()["service"] == "google"
    # Azure Maps, once it has a key
    azure.status = 403
    chain(h, google.places(), mapbox.mapbox(), azure.azure(), on=())
    tried = try_it(h, "azure")
    assert (tried["ok"], tried["reason"]) == (False, "refused")
    assert tried["message"] == (
        "Azure Maps refused the hub's key. Copy the primary key again from your Maps account in the Azure portal."
    )


def test_what_a_manager_is_told_when_a_service_gives_no_list():
    assert said("google", "refused") == "Google refused the hub's key. Is Places API (New) turned on for it?"
    assert said("google", "unreachable") == "Google is not answering."
    assert said("mapbox", "unreachable") == "Mapbox is not answering."
    assert said("mapbox", "not_found") == "Mapbox found no address like that."
    assert said("azure", "limit") == "Azure Maps has been asked as often as it may be this month."
    assert (
        said("azure", "unreachable", 503)
        == "Azure Maps answered 503, which is no list. Tell whoever looks after the hub."
    )
    assert said("azure", "refused", 401).startswith("Azure Maps refused the hub's key.")  # the status says no more


# The month's count ---------------------------------------------------------------------------------------------


def test_the_month_turns_by_the_latest_of_the_services_own_clocks():
    from datetime import UTC, datetime

    assert month_of(datetime(2026, 12, 1, 7, 59, tzinfo=UTC).timestamp()) == "2026-11"  # still November in California
    assert month_of(datetime(2026, 12, 1, 8, 0, tzinfo=UTC).timestamp()) == "2026-12"
    assert month_of(86400.0 * 20000) == "2024-10"


def test_the_months_count_outlives_the_hub_and_two_hubs_count_as_one():
    clock = [86400.0 * 20000]
    asked = Asked()
    world = World(*WINCHESTER)
    first = Suggester(world.places(), monthly=5, asked=asked, clock=lambda: clock[0])
    first.suggest("12 Elm")
    first.suggest("12 Elm S")
    assert first.left("google") == 3
    # a hub that restarts goes on counting where it stopped
    again = Suggester(world.places(), monthly=5, asked=asked, clock=lambda: clock[0])
    assert again.left("google") == 3 and again.status()["asked_month"] == 2
    # and what the other hub asked is counted against the same month
    again.suggest("12 Elm St")
    first.suggest("12 E")
    assert first.left("google") == 1 and asked.of("2024-10") == {"google": 4}
    again.suggest("12 El")
    with pytest.raises(LookupFailed) as failed:
        first.suggest("12 Elm")
    assert failed.value.reason == "limit" and len(world.seen) == 5
    # a key replaced while the hub runs is the same account still: the count stands
    first.use(world.places())
    assert first.left("google") == 0
    # the next month each starts over
    clock[0] += 86400 * 31
    assert first.left("google") == 5 and again.left("google") == 5 and asked.of("2024-11") == {}


def test_the_hubs_own_file_names_a_key_and_a_month_for_each_service():
    assert mapbox_from_env({}) is None and mapbox_from_env({"POS_MAPS_MAPBOX_KEY": " "}) is None
    assert azure_from_env({}) is None and azure_from_env({"POS_MAPS_AZURE_KEY": ""}) is None
    assert mapbox_from_env({"POS_MAPS_MAPBOX_KEY": TOKEN}).name == "mapbox"
    assert azure_from_env({"POS_MAPS_AZURE_KEY": AZURE_KEY}).name == "azure"
    env = {"POS_MAPS_AZURE_KEY": AZURE_KEY, "POS_MAPS_MAPBOX_KEY": TOKEN}
    assert [service.name for service in services_from_env(env)] == ["mapbox", "azure"]
    env = {
        **env,
        "POS_MAPS_GOOGLE_KEY": "AIza-key-456",
        "POS_MAPS_MAPBOX_MONTHLY": "500",
        "POS_MAPS_AZURE_MONTHLY": "x",
    }
    suggester = suggester_from_env(env)
    assert [(one["service"], one["monthly_most"], one["left"]) for one in suggester.statuses()] == [
        ("google", 9500, 9500),
        ("mapbox", 500, 500),
        ("azure", 47_500, 47_500),  # what could not be read is what the service gives away, a twentieth short
    ]
    # a key typed or removed while the hub runs: the ones that stay keep what the day counted
    suggester.use(*services_from_env({"POS_MAPS_MAPBOX_KEY": TOKEN}))
    assert suggester.names == ["mapbox"] and suggester.most("mapbox") == 500 and suggester.most("google") == 9500
    assert suggester.has("mapbox") and not suggester.has("google") and suggester.left("azure") is None


def test_the_status_names_every_service_the_list_can_ask():
    h = delivered()
    google, mapbox, azure = three()
    chain(h, google.places(), mapbox.mapbox(), azure.azure(), on=("google", "azure"), monthly={"google": 1})
    listed(h, "12 Elm")
    listed(h, "12 Elm S")
    told = h.c.get("/maps/status").json()
    assert [(one["service"], one["enabled"], one["asked_month"], one["left"]) for one in told["suggests"]] == [
        ("google", True, 1, 0),
        ("mapbox", False, 0, 95_000),
        ("azure", True, 1, 47_499),
    ]
    assert told["suggest"] == told["suggests"][0]
    assert "Elm" not in json.dumps(told) and "pk." not in json.dumps(told)  # no address and no key is in it


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_months_count_is_kept_in_the_database():
    import psycopg

    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS map_asked")
    asked = PgAsked(DSN)
    try:
        assert asked.of("2026-11") == {}
        assert asked.add("google", "2026-11", 1) == 1 and asked.add("google", "2026-11", 2) == 3
        assert asked.add("azure", "2026-11", 10) == 10 and asked.add("google", "2026-12", 1) == 1
        other = PgAsked(DSN)  # the other hub, or this one after it restarted
        try:
            assert other.of("2026-11") == {"google": 3, "azure": 10}
            assert other.add("google", "2026-11", 1) == 4
        finally:
            other.close()
        assert asked.of("2026-11") == {"google": 4, "azure": 10}
        # a count and nothing else is written down
        with psycopg.connect(DSN) as conn:
            rows = conn.execute("SELECT service, month, asked FROM map_asked ORDER BY month, service").fetchall()
        assert rows == [("azure", "2026-11", 10), ("google", "2026-11", 4), ("google", "2026-12", 1)]
        # the hub's asking counts in it
        world = World(*WINCHESTER)
        suggester = Suggester(world.places(), monthly=10, asked=asked, clock=lambda: 1_795_000_000.0)  # 2026-11
        assert suggester.left("google") == 6
        suggester.suggest("12 Elm")
        assert suggester.left("google") == 5 and asked.of("2026-11")["google"] == 5
        # a database that does not answer: the count goes on in the hub's memory, and so does the list
        asked.close()
        assert asked.add("google", "2026-11", 1) == 6
        assert asked.of("2026-11") == {"google": 6, "azure": 10}
        suggester.suggest("12 Elm S")
        assert suggester.left("google") == 3
    finally:
        asked.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS map_asked")


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
