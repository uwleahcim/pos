"""How far a delivery goes, looked up from its address (docs/delivery.md, "Looking the distance up").

With a map service's key on the hub and the restaurant's own address in the fee's setting, a form asks the
hub how far an address is and is told the band of the fee it falls in. Only the two addresses go to the
service. Without a service, or when it gives no distance, the band is tapped by hand as before.

A customer who orders again to the same address is not asked about again: what the map said is on their own
earlier order, and the hub reads it there ("Customers who order again")."""

from __future__ import annotations

import logging
from decimal import Decimal

import httpx
import pytest

from pos.customers import saved_trip
from pos.maps import Geocodio, LookupFailed, Lookups, Trip, lookups_from_env, maps_from_env, origin_mark, trip_of
from pos.orders.delivery_fee import band_for, fee_of, measured_of

from .test_counter import client, manager, payload, takeout
from .test_day import Hub, at
from .test_delivery import ELM
from .test_delivery_fee import MILES, MINUTES, brought, carried, check, pick, priced
from .test_history import steps

HOME = "1 Restaurant Row, Winchester, MA"
OAK = "4 Oak Rd, Woburn, MA"
LINDA = "(781) 555-0142"
FROM_HOME = origin_mark(HOME)
SAID = {"service": "atlas", "from": FROM_HOME, "saved": False}
"""What an answer says beside the distance when the service was asked."""


class Atlas:
    """A map service that knows a few addresses, and remembers what it was asked."""

    name = "atlas"

    def __init__(self, trips: dict[str, Trip] | None = None, *, fails: str | None = None) -> None:
        self.trips = {ELM: Trip(Decimal("3.2"), 9), OAK: Trip(Decimal("9.3"), 21)} if trips is None else trips
        self.fails = fails
        self.asked: list[tuple[str, str]] = []

    def trip(self, origin: str, destination: str) -> Trip:
        self.asked.append((origin, destination))
        if self.fails:
            raise LookupFailed(self.fails)
        if destination not in self.trips:
            raise LookupFailed("not_found")
        return self.trips[destination]


def mapped(fee: dict = MILES, *, atlas: Atlas | None = None, origin: str = HOME, **more):
    """A hub with a map service, the restaurant's own address and its prices."""
    c = client()
    atlas = atlas if atlas is not None else Atlas()
    c.app.state.lookups = Lookups(atlas, **more)
    priced(c, {**fee, "origin": origin})
    return c, atlas


def far(c, address: str = ELM, **more):
    return c.post("/delivery/distance", json={"address": address, **more})


def measured(told: dict) -> dict:
    """What a form sends back with its pick: the distance as the hub said it, and who measured it from where."""
    return {key: told[key] for key in ("miles", "minutes", "service", "from")}


# Whether anything is looked up ------------------------------------------------------------------------------


def test_nothing_is_looked_up_without_a_map_service_or_without_the_restaurants_own_address():
    c = client()
    assert {"maps": False, "lookup": False, "origin": ""}.items() <= c.get("/settings/delivery_fee").json().items()
    refused = far(c)
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_lookup"
    # a service, and still no address to start from
    atlas = Atlas()
    c.app.state.lookups = Lookups(atlas)
    told = priced(c, MILES)
    assert (told["maps"], told["lookup"]) == (True, False)
    refused = far(c)
    assert refused.status_code == 409 and "own address" in refused.json()["detail"]["message"]
    assert atlas.asked == []
    # the address alone, on a hub with no service
    c = client()
    told = priced(c, {**MILES, "origin": HOME})
    assert (told["origin"], told["maps"], told["lookup"]) == (HOME, False, False)
    assert far(c).status_code == 409


def test_a_manager_says_where_deliveries_start_and_an_older_app_leaves_it_alone():
    c, _ = mapped(origin="  1 Restaurant Row,   Winchester, MA ")
    assert c.get("/settings/delivery_fee").json()["origin"] == HOME  # as one line
    assert c.get("/settings/delivery_fee").json()["lookup"] is True
    # an app built before the lookup saves the prices and says nothing of the address
    older = {"enabled": True, "by": "miles", "bands": [{"up_to": 3, "fee": 4}], "taxed": False}
    assert priced(c, older)["origin"] == HOME
    # taken off on purpose, nothing is looked up
    assert priced(c, {**older, "origin": ""})["lookup"] is False
    for bad in ({"origin": "x" * 201}, {"origin": 5}):
        assert c.put("/settings/delivery_fee", json={**older, **bad}, headers=manager(c)).status_code == 422


# What a form is told ----------------------------------------------------------------------------------------


def test_an_address_is_told_how_far_it_is_and_the_band_it_falls_in():
    c, atlas = mapped()
    told = far(c).json()
    assert told == {
        "miles": "3.2",
        "minutes": 9,
        "by": "miles",
        "band": {"up_to": "4.5", "fee": "5.00"},
        "beyond": False,
        **SAID,
    }
    # only the two addresses went out: where it starts and where it goes
    assert atlas.asked == [(HOME, ELM)]


def test_the_band_is_the_nearest_one_that_reaches():
    two, mid, eight = (band["up_to"] for band in MILES["bands"])
    for miles, band in (("0.3", two), ("2.0", two), ("2.1", mid), ("4.5", mid), ("4.6", eight), ("8.0", eight)):
        assert band_for(MILES, Decimal(miles), 5)["up_to"] == band, miles
    assert band_for(MILES, Decimal("8.1"), 5) is None  # further than the list reaches
    # by the minutes of the drive it is the minutes that count, however far
    assert band_for(MINUTES, Decimal("30"), 10)["up_to"] == "10"
    assert band_for(MINUTES, Decimal("1"), 11)["up_to"] == "20"
    assert band_for(MINUTES, Decimal("1"), 21) is None
    # the bands in any order, and no band while no fee is charged
    shuffled = {**MILES, "bands": list(reversed(MILES["bands"]))}
    assert band_for(shuffled, Decimal("1"), 5)["up_to"] == "2"
    assert band_for({**MILES, "enabled": False}, Decimal("1"), 5) is None


def test_further_than_the_prices_reach_is_said_and_no_band_is_picked():
    c, _ = mapped()
    told = far(c, OAK).json()
    assert (told["miles"], told["minutes"], told["band"], told["beyond"]) == ("9.3", 21, None, True)
    # by minutes the same address is 21 minutes, past "up to 20"
    c, _ = mapped(MINUTES)
    told = far(c, OAK).json()
    assert (told["by"], told["band"], told["beyond"]) == ("minutes", None, True)
    assert far(c).json()["band"] == {"up_to": "10", "fee": "3.00"}


def test_with_the_fee_turned_off_the_distance_is_still_told():
    c, _ = mapped({**MILES, "enabled": False})
    told = far(c).json()
    assert (told["miles"], told["band"], told["beyond"]) == ("3.2", None, False)


def test_an_address_is_one_line_of_reasonable_length():
    c, atlas = mapped()
    assert far(c, "   ").status_code == 422
    assert far(c, "9 " + "long " * 50).status_code == 422
    assert c.post("/delivery/distance", json={}).status_code == 422
    assert atlas.asked == []
    assert far(c, "  12 Elm St,\n Winchester ").status_code == 200
    assert atlas.asked == [(HOME, ELM)]  # asked as one line


# When the service gives no distance -------------------------------------------------------------------------


@pytest.mark.parametrize("reason", ["not_found", "unreachable", "refused", "limit"])
def test_a_lookup_that_fails_says_so_in_words_for_the_form(reason):
    c, _ = mapped(atlas=Atlas(fails=reason))
    failed = far(c)
    assert failed.status_code == 424
    detail = failed.json()["detail"]
    assert (detail["error"], detail["reason"]) == ("lookup_failed", reason)
    assert "by hand" in detail["message"] and ELM not in detail["message"]
    # and the fee can be picked by hand all the same
    brought(c)
    assert pick(c, {"up_to": "4.5"})["refused"] == []
    assert check(c)["total"] == "15.71"


def test_the_same_address_is_asked_once_a_day_and_a_failure_is_asked_again():
    now = [1_000_000.0]
    c, atlas = mapped(clock=lambda: now[0])
    assert far(c).json()["miles"] == "3.2"
    assert far(c, "12 elm st,  WINCHESTER").json()["miles"] == "3.2"  # the same address, typed another way
    assert len(atlas.asked) == 1
    now[0] += 25 * 3600
    assert far(c).json()["miles"] == "3.2"
    assert len(atlas.asked) == 2
    # an address the service did not find is asked again: it may have been a slip of the finger
    assert far(c, "1 Nowhere").status_code == 424
    assert far(c, "1 Nowhere").status_code == 424
    assert len(atlas.asked) == 4


def test_the_hub_asks_no_more_in_a_day_than_it_was_told_to():
    now = [1_000_000.0]
    atlas = Atlas({f"{n} Elm St": Trip(Decimal("1.0"), 4) for n in range(1, 9)})
    c, _ = mapped(atlas=atlas, daily=3, clock=lambda: now[0])
    assert [far(c, f"{n} Elm St").status_code for n in range(1, 6)] == [200, 200, 200, 424, 424]
    assert far(c, "5 Elm St").json()["detail"]["reason"] == "limit"
    assert far(c, "2 Elm St").status_code == 200  # one it already knows costs nothing
    assert len(atlas.asked) == 3
    status = c.get("/maps/status").json()
    assert status == {
        "configured": True,
        "service": "atlas",
        "asked_today": 3,
        "failed_today": 0,
        "saved_today": 0,
        "daily_most": 3,
        "last_failure": "limit",
        "origin_set": True,
    }
    assert "Elm" not in str(status)  # no address is in it
    now[0] += 24 * 3600
    assert far(c, "5 Elm St").status_code == 200


def test_a_hub_with_no_service_says_so_in_its_status():
    status = client().get("/maps/status").json()
    assert (status["configured"], status["service"], status["origin_set"]) == (False, None, False)


# What the map said travels with the pick --------------------------------------------------------------------


def test_a_pick_carries_what_the_map_said_and_the_band_still_decides_the_amount():
    c, _ = mapped()
    brought(c)
    told = {"miles": "3.2", "minutes": 9}
    assert pick(c, {"up_to": "4.5", "measured": told})["refused"] == []
    assert carried(c) == {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False, "measured": told}
    assert check(c)["total"] == "15.71"
    # picked against the map: the nearer band, and what the map said is kept beside it
    assert pick(c, {"up_to": "2", "measured": {"miles": 3.2, "minutes": 9}, "amount": "0.01"}, when=60)["refused"] == []
    assert carried(c) == {"by": "miles", "up_to": "2", "amount": "3.00", "taxed": False, "measured": told}
    # no fee on purpose keeps it too
    pick(c, {"up_to": None, "measured": told}, when=70)
    assert carried(c) == {"up_to": None, "amount": "0.00", "measured": told}
    assert fee_of({"delivery_fee": carried(c)})["measured"] == told
    # tapped by hand, there is none
    pick(c, {"up_to": "8"}, when=80)
    assert "measured" not in carried(c)


def test_what_the_map_said_is_read_with_care():
    assert measured_of({"measured": {"miles": 3.25, "minutes": 9}}) is None  # miles to a tenth
    for bad in (
        None,
        "3.2",
        {"miles": "3.2"},
        {"minutes": 9},
        {"miles": "far", "minutes": 9},
        {"miles": "3.2", "minutes": 0},
        {"miles": "3.2", "minutes": 9.5},
        {"miles": "-1", "minutes": 9},
        {"miles": "5000", "minutes": 9},
        {"miles": True, "minutes": 9},
        {"miles": "3.2", "minutes": True},
        {"miles": "NaN", "minutes": 9},
    ):
        assert measured_of({"measured": bad}) is None, bad
    assert measured_of({"measured": {"miles": 3, "minutes": 9}}) == {"miles": "3.0", "minutes": 9}
    # a pick whose note cannot be read is kept without it: the band is what counts
    c, _ = mapped()
    brought(c)
    assert pick(c, {"up_to": "4.5", "measured": {"miles": "far", "minutes": 9}})["refused"] == []
    assert carried(c) == {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False}


def test_the_history_shows_a_fee_picked_against_the_map():
    h = Hub(now=at(17))
    h.c.put("/settings/delivery_fee", json=MILES, headers=h.manager())
    told = {"miles": "3.2", "minutes": 9}
    picked = {"up_to": "4.5", "measured": told}
    h.to_go("o1", at(17), handover="delivery", address=ELM, delivery_fee=picked, by="Amy", by_id="s1")
    h.op("o1", "set_field", at(17, 5), delivery_fee={"up_to": "2", "measured": told}, by="Ben", by_id="s2")
    fees = [(s["by"], s["now"]) for s in steps(h) if s["what"] == "delivery_fee"]
    assert [now["measured"] for _, now in fees] == [told, told]
    assert [(by, now["up_to"], now["amount"]) for by, now in fees] == [("Amy", "4.5", "5.00"), ("Ben", "2", "3.00")]


# Customers who order again -----------------------------------------------------------------------------------


def again(fee: dict = MILES, **more):
    """A hub where Linda had a delivery brought to Elm Street: the map was asked then, and the fee picked
    with what it said. The hub has since started again, so nothing is left in its memory."""
    c, atlas = mapped(fee, **more)
    told = far(c, phone=LINDA).json()
    assert told["saved"] is False
    brought(c, phone=LINDA, delivery_fee={"up_to": told["band"]["up_to"], "measured": measured(told)})
    atlas = Atlas()
    c.app.state.lookups = Lookups(atlas, **more)
    return c, atlas


def test_a_pick_carries_who_measured_it_and_from_where():
    c, _ = again()
    kept = carried(c)["measured"]
    assert kept == {"miles": "3.2", "minutes": 9, "service": "atlas", "from": FROM_HOME}
    # the mark is of the restaurant's address however it was typed, and says nothing of it
    assert origin_mark("  1 restaurant row,  WINCHESTER, ma ") == FROM_HOME != origin_mark(OAK)
    assert len(FROM_HOME) == 8 and "Restaurant" not in FROM_HOME
    # the two go together or not at all, and only as the hub writes them
    plain = {"miles": "3.2", "minutes": 9}
    for bad in (
        {"service": "atlas"},
        {"from": FROM_HOME},
        {"service": "Atlas Maps!", "from": FROM_HOME},
        {"service": "atlas", "from": "1 Restaurant Row"},
        {"service": 5, "from": FROM_HOME},
        {"service": "atlas", "from": 12345678},
    ):
        assert measured_of({"measured": {**plain, **bad}}) == plain, bad


def test_a_customer_who_orders_again_to_the_same_address_is_not_looked_up():
    c, atlas = again()
    told = far(c, phone=LINDA).json()
    assert told == {
        "miles": "3.2",
        "minutes": 9,
        "by": "miles",
        "band": {"up_to": "4.5", "fee": "5.00"},
        "beyond": False,
        "service": "atlas",
        "from": FROM_HOME,
        "saved": True,
    }
    assert atlas.asked == []
    # the number and the address as anybody types them
    assert far(c, "12 elm st,   WINCHESTER", phone="781.555.0142").json()["saved"] is True
    assert far(c, phone="+1 781 555 0142").json()["saved"] is True
    assert atlas.asked == []
    status = c.get("/maps/status").json()
    assert (status["asked_today"], status["saved_today"]) == (0, 3)


def test_the_saved_distance_is_priced_as_the_prices_are_now():
    c, atlas = again()
    priced(c, {**MILES, "bands": [{"up_to": "3", "fee": "4.00"}, {"up_to": "6", "fee": "7.00"}], "origin": HOME})
    told = far(c, phone=LINDA).json()
    assert (told["saved"], told["band"]) == (True, {"up_to": "6", "fee": "7.00"})
    # by the minutes of the drive it is the saved minutes that count
    priced(c, {**MINUTES, "origin": HOME})
    told = far(c, phone=LINDA).json()
    assert (told["saved"], told["by"], told["band"]) == (True, "minutes", {"up_to": "10", "fee": "3.00"})
    # and past the last price it says so, as a looked-up one does
    priced(c, {**MILES, "bands": [{"up_to": "2", "fee": "3.00"}], "origin": HOME})
    told = far(c, phone=LINDA).json()
    assert (told["saved"], told["band"], told["beyond"]) == (True, None, True)
    assert atlas.asked == []


def test_another_address_another_number_or_no_number_is_looked_up():
    c, atlas = again()
    assert far(c, OAK, phone=LINDA).json()["saved"] is False  # somewhere else this time
    assert far(c, "12 Elm Street, Winchester", phone=LINDA).status_code == 424  # another spelling is another address
    assert atlas.asked == [(HOME, OAK), (HOME, "12 Elm Street, Winchester")]
    for n, phone in enumerate(("781 555 0199", "", "0142", "no number")):
        c.app.state.lookups = Lookups(atlas)  # nothing in memory
        assert far(c, phone=phone).json()["saved"] is False, phone
        assert len(atlas.asked) == 3 + n
    # only the two addresses went out, whoever was asking
    assert all(set(asked) <= {HOME, ELM, OAK, "12 Elm Street, Winchester"} for asked in atlas.asked)
    assert "555" not in str(atlas.asked)


def test_a_distance_measured_from_another_address_of_the_restaurants_is_not_used():
    c, atlas = again()
    priced(c, {**MILES, "origin": "2 Restaurant Row, Winchester, MA"})  # the address was typed wrong at first
    told = far(c, phone=LINDA).json()
    assert (told["saved"], told["from"]) == (False, origin_mark("2 Restaurant Row, Winchester, MA"))
    assert atlas.asked == [("2 Restaurant Row, Winchester, MA", ELM)]
    # put back, the saved one counts again
    priced(c, {**MILES, "origin": HOME})
    assert far(c, phone=LINDA).json()["saved"] is True


def test_looking_it_up_again_asks_the_service_and_the_newest_order_is_the_one_read():
    c, atlas = again()
    atlas.trips[ELM] = Trip(Decimal("2.9"), 8)  # a new road
    told = far(c, phone=LINDA, fresh=True).json()
    assert (told["miles"], told["minutes"], told["saved"]) == ("2.9", 8, False)
    assert atlas.asked == [(HOME, ELM)]
    assert far(c, phone=LINDA).json()["miles"] == "3.2"  # nothing was picked with it yet
    brought(c, "o2", 3600, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": measured(told)})
    told = far(c, phone=LINDA).json()
    assert (told["miles"], told["minutes"], told["saved"]) == ("2.9", 8, True)
    assert len(atlas.asked) == 1


def test_figures_with_no_mark_a_pickup_and_a_voided_order_are_not_read():
    c, atlas = mapped()
    # an app built before distances were saved sends the two numbers alone: a note, and no more
    brought(c, "o1", 0, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": {"miles": "3.2", "minutes": 9}})
    kept = {"miles": "3.2", "minutes": 9, "service": "atlas", "from": FROM_HOME}
    # picked up after all, and one that was voided
    picked_up = {"channel": "phone", "handover": "pickup", "address": ELM, "phone": LINDA}
    takeout(c, "o2", 100, **picked_up, delivery_fee={"up_to": "4.5", "measured": kept})
    brought(c, "o3", 200, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": kept})
    c.post("/orders/o3/ops", json=[payload("o3-void", "void_order", 210, "o3")])
    # a price tapped by hand with no map in it
    brought(c, "o4", 300, phone=LINDA, delivery_fee={"up_to": "2"})
    store = c.app.state.store
    assert saved_trip(store, LINDA, ELM, FROM_HOME) is None
    assert far(c, phone=LINDA).json()["saved"] is False
    assert atlas.asked == [(HOME, ELM)]
    # an older delivery that has the figures is found behind the newer ones that do not
    brought(c, "o0", -500, phone=LINDA, delivery_fee={"up_to": None, "measured": {**kept, "miles": "3.4"}})
    assert saved_trip(store, LINDA, ELM, FROM_HOME) == {**kept, "miles": "3.4"}
    assert saved_trip(store, LINDA, "", FROM_HOME) is None
    assert saved_trip(store, LINDA, ELM, origin_mark(OAK)) is None


def test_a_customers_saved_distance_still_answers_when_the_service_does_not():
    c, _ = again()
    c.app.state.lookups = Lookups(Atlas(fails="unreachable"))
    assert far(c, phone=LINDA).json()["saved"] is True
    assert far(c, phone=LINDA, fresh=True).status_code == 424
    # with no service at all nothing is asked of anybody, as before
    c.app.state.lookups = Lookups()
    assert far(c, phone=LINDA).status_code == 409


# The service itself -----------------------------------------------------------------------------------------


def geocodio(handler) -> Geocodio:
    return Geocodio("key-123", client=httpx.Client(transport=httpx.MockTransport(handler)))


def test_the_service_is_sent_the_two_addresses_and_the_key_in_a_header(caplog):
    seen: list[httpx.Request] = []

    def answer(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"destinations": [{"distance_miles": 3.24, "duration_seconds": 545}]})

    with caplog.at_level(logging.INFO, logger="httpx"):
        trip = geocodio(answer).trip(HOME, ELM)
    assert trip == Trip(Decimal("3.2"), 9)
    (request,) = seen
    assert (request.method, request.url.path) == ("GET", "/v2.1/distance")
    assert dict(request.url.params) == {"origin": HOME, "destinations[]": ELM, "mode": "driving"}
    assert request.headers["authorization"] == "Bearer key-123"
    assert "key-123" not in str(request.url)
    # the log names no address, and no key
    assert "Elm" not in caplog.text and "Restaurant Row" not in caplog.text and "key-123" not in caplog.text


def test_an_answer_with_the_numbers_at_the_top_is_read_too():
    trip = geocodio(lambda _: httpx.Response(200, json={"distance_miles": "28.4", "duration_seconds": 3060})).trip(
        HOME, ELM
    )
    assert trip == Trip(Decimal("28.4"), 51)


@pytest.mark.parametrize(
    ("answer", "reason"),
    [
        (httpx.Response(401, json={"error": "Invalid API key"}), "refused"),
        (httpx.Response(403, json={"error": "This API key does not have permission"}), "refused"),
        (httpx.Response(402, json={"error": "Payment required"}), "limit"),
        (httpx.Response(429, json={"error": "Too many requests"}), "limit"),
        (httpx.Response(422, json={"error": "Could not geocode address"}), "not_found"),
        (httpx.Response(500, text="oops"), "unreachable"),
        (httpx.Response(200, text="not json"), "unreachable"),
        (httpx.Response(200, json={"destinations": []}), "not_found"),
        (httpx.Response(200, json={"destinations": [{"query": ELM, "distance_miles": None}]}), "not_found"),
        (httpx.Response(200, json=["what"]), "not_found"),
        (httpx.Response(200, json={"destinations": [{"distance_miles": 4000, "duration_seconds": 9}]}), "not_found"),
    ],
)
def test_what_the_service_may_answer_instead(answer, reason, caplog):
    with pytest.raises(LookupFailed) as failed:
        geocodio(lambda _: answer).trip(HOME, ELM)
    assert failed.value.reason == reason
    assert "Elm" not in caplog.text and "key-123" not in caplog.text


def test_a_service_that_does_not_answer_is_unreachable_and_the_log_names_no_address(caplog):
    def silent(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout(f"timed out asking {request.url}", request=request)

    with pytest.raises(LookupFailed) as failed:
        geocodio(silent).trip(HOME, ELM)
    assert failed.value.reason == "unreachable" and failed.value.__cause__ is None
    assert "ConnectTimeout" in caplog.text
    assert "Elm" not in caplog.text and "Restaurant Row" not in caplog.text and "key-123" not in caplog.text


def test_miles_to_a_tenth_and_the_drive_to_the_nearest_minute():
    assert trip_of(2.04, 0) == Trip(Decimal("2.0"), 1)  # never less than a minute
    assert trip_of("2.05", 89) == Trip(Decimal("2.1"), 1)
    assert trip_of(2.05, 90) == Trip(Decimal("2.1"), 2)
    assert trip_of(0, 600) == Trip(Decimal("0.0"), 10)
    for bad in ((None, 60), (3.2, None), ("far", 60), (-1, 60), (3.2, -5), (True, 60), (float("inf"), 60), (1001, 60)):
        assert trip_of(*bad) is None, bad


def test_the_key_comes_from_the_hubs_own_file():
    assert maps_from_env({}) is None
    assert maps_from_env({"POS_MAPS_KEY": "  "}) is None
    assert isinstance(maps_from_env({"POS_MAPS_KEY": "abc"}), Geocodio)
    assert maps_from_env({"POS_MAPS_KEY": "abc", "POS_MAPS": "somebody-else"}) is None
    assert lookups_from_env({}).ready is False
    lookups = lookups_from_env({"POS_MAPS_KEY": "abc", "POS_MAPS_DAILY": "40"})
    assert lookups.ready and lookups.status()["daily_most"] == 40
    assert lookups_from_env({"POS_MAPS_KEY": "abc", "POS_MAPS_DAILY": "lots"}).status()["daily_most"] == 500
