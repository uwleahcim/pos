"""How far a delivery goes, looked up from its address (docs/delivery.md, "Looking the distance up").

With a map service's key on the hub and the restaurant's own address in the fee's setting, a form asks the
hub how far an address is and is told the band of the fee it falls in. Only the two addresses go to the
service. Without a service, or when it gives no distance, the band is tapped by hand as before.

A customer who orders again to the same address is not asked about again: what the map said is on their own
earlier order, and the hub reads it there ("Customers who order again").

A hub may have a second service, Google Maps, for when the first gives no distance ("A second map service").
What it says picks the price and is not kept anywhere."""

from __future__ import annotations

import json
import logging
import threading
from decimal import Decimal

import httpx
import pytest

from pos.customers import saved_trip
from pos.maps import (
    Geocodio,
    Google,
    LookupFailed,
    Lookups,
    Trip,
    credit_of,
    fallback_from_env,
    lookups_from_env,
    maps_from_env,
    may_keep,
    origin_mark,
    trip_of,
)
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
SAID = {"service": "atlas", "credit": None, "keep": True, "from": FROM_HOME, "saved": False, "drive_now": None}
"""What an answer says beside the distance when the service was asked."""
MARKS = {"service": "atlas", "from": FROM_HOME}
"""Who measured a distance and from where, as a form sends it back with its pick."""


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
        "fallback": None,
        "traffic": None,
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
    told = {"miles": "3.2", "minutes": 9, **MARKS}
    assert pick(c, {"up_to": "4.5", "measured": told})["refused"] == []
    assert carried(c) == {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False, "measured": told}
    assert check(c)["total"] == "15.71"
    # picked against the map: the nearer band, and what the map said is kept beside it
    again = {"up_to": "2", "measured": {"miles": 3.2, "minutes": 9, **MARKS}, "amount": "0.01"}
    assert pick(c, again, when=60)["refused"] == []
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
    told = {"miles": "3.2", "minutes": 9, **MARKS}
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
        "credit": None,
        "keep": True,
        "from": FROM_HOME,
        "saved": True,
        "drive_now": None,
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
    # an app built before distances were saved sends the two numbers alone, and they are not kept: nobody
    # can tell who measured them
    brought(c, "o1", 0, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": {"miles": "3.2", "minutes": 9}})
    assert carried(c) == {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False}
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


# A second map service -----------------------------------------------------------------------------------------


class Globe(Atlas):
    """The second service: it knows the same addresses, and one street the first does not."""

    name = "google"

    def __init__(self, *, fails: str | None = None) -> None:
        super().__init__(
            {ELM: Trip(Decimal("3.3"), 10), OAK: Trip(Decimal("9.4"), 22), NEW: Trip(Decimal("1.6"), 5)}, fails=fails
        )


NEW = "3 Newbuild Way, Winchester, MA"
GOOGLE_MARKS = {"service": "google", "from": FROM_HOME}


def two(fee: dict = MILES, *, first: Atlas | None = None, second: Globe | None = None, **more):
    """A hub with both services."""
    first = first if first is not None else Atlas()
    second = second if second is not None else Globe()
    c, _ = mapped(fee, atlas=first)
    c.app.state.lookups = Lookups(first, fallback=second, **more)
    return c, first, second


def test_the_second_service_is_asked_only_when_the_first_gives_no_distance():
    c, first, second = two()
    assert c.get("/settings/delivery_fee").json()["services"] == ["atlas", "google"]
    told = far(c).json()
    assert (told["miles"], told["service"], told["credit"]) == ("3.2", "atlas", None)
    assert second.asked == []
    # a street the first does not know
    told = far(c, NEW).json()
    assert told == {
        "miles": "1.6",
        "minutes": 5,
        "by": "miles",
        "band": {"up_to": "2", "fee": "3.00"},
        "beyond": False,
        "service": "google",
        "credit": "Google Maps",
        "keep": False,
        "from": FROM_HOME,
        "saved": False,
        "drive_now": None,
    }
    # it is sent the two addresses too, and nothing else
    assert first.asked == [(HOME, ELM), (HOME, NEW)] and second.asked == [(HOME, NEW)]
    assert c.get("/settings/delivery_fee").json()["lookup"] is True


@pytest.mark.parametrize("reason", ["not_found", "unreachable", "refused", "limit"])
def test_whatever_the_first_says_the_second_is_tried(reason):
    c, first, second = two(first=Atlas(fails=reason))
    told = far(c).json()
    assert (told["miles"], told["minutes"], told["service"], told["credit"]) == ("3.3", 10, "google", "Google Maps")
    assert len(first.asked) == len(second.asked) == 1
    status = c.get("/maps/status").json()
    assert (status["failed_today"], status["last_failure"]) == (1, reason)
    assert status["fallback"] == {
        "service": "google",
        "asked_today": 1,
        "failed_today": 0,
        "daily_most": 100,
        "last_failure": None,
    }


def test_when_neither_gives_a_distance_the_form_is_told_what_it_can_do_about():
    # an address neither knows
    c, _, _ = two()
    assert far(c, "1 Nowhere").json()["detail"]["reason"] == "not_found"
    # the first cannot be reached and the second does not know the street: the street is what to check
    c, _, _ = two(first=Atlas(fails="unreachable"))
    assert far(c, "1 Nowhere").json()["detail"]["reason"] == "not_found"
    # the first does not know it and the second's key is refused: still the street
    c, _, second = two(second=Globe(fails="refused"))
    refused = far(c, "1 Nowhere")
    assert (refused.status_code, refused.json()["detail"]["reason"]) == (424, "not_found")
    assert c.get("/maps/status").json()["fallback"]["last_failure"] == "refused"
    # no internet: neither answers, and the form says so
    c, _, _ = two(first=Atlas(fails="unreachable"), second=Globe(fails="unreachable"))
    detail = far(c).json()["detail"]
    assert detail["reason"] == "unreachable" and "by hand" in detail["message"]


def test_what_the_second_service_says_is_not_remembered_and_is_asked_no_more_than_it_may_be():
    now = [1_000_000.0]
    c, first, second = two(fallback_daily=3, clock=lambda: now[0])
    assert [far(c, NEW).status_code for _ in range(5)] == [200, 200, 200, 424, 424]
    # each time it was asked afresh, until its own day's most; the first was asked every time
    assert (len(first.asked), len(second.asked)) == (5, 3)
    assert far(c, NEW).json()["detail"]["reason"] == "not_found"
    status = c.get("/maps/status").json()
    assert (status["asked_today"], status["failed_today"], status["daily_most"]) == (6, 6, 500)
    assert status["fallback"] == {
        "service": "google",
        "asked_today": 3,
        "failed_today": 0,
        "daily_most": 3,
        "last_failure": "limit",
    }
    # what the first says is remembered for the day, as before
    assert far(c).status_code == far(c).status_code == 200
    assert len(first.asked) == 7
    now[0] += 24 * 3600
    assert far(c, NEW).json()["service"] == "google"
    # the first at its own most for the day: the second answers
    c, first, second = two(daily=1)
    assert [far(c, address).json()["service"] for address in (ELM, OAK, OAK)] == ["atlas", "google", "google"]
    assert (len(first.asked), len(second.asked)) == (1, 2)


def test_what_the_second_service_says_picks_the_price_and_is_not_kept_on_the_order():
    c, _, second = two()
    told = far(c, NEW, phone=LINDA).json()
    new = {"channel": "phone", "handover": "delivery", "address": NEW, "phone": LINDA}
    takeout(c, "o1", 0, **new, delivery_fee={"up_to": told["band"]["up_to"], "measured": measured(told)})
    assert carried(c) == {"by": "miles", "up_to": "2", "amount": "3.00", "taxed": False}
    assert check(c)["total"] == "13.71"
    # no fee on purpose, the same
    pick(c, {"up_to": None, "measured": measured(told)}, when=70)
    assert carried(c) == {"up_to": None, "amount": "0.00"}
    # so the customer is asked about again the next time, and the history has nothing of it
    assert saved_trip(c.app.state.store, LINDA, NEW, FROM_HOME) is None
    assert far(c, NEW, phone=LINDA).json()["saved"] is False
    assert len(second.asked) == 2
    assert "1.6" not in c.get("/orders/o1").text
    # and nothing a screen says makes it kept: the service's name decides
    assert may_keep("atlas") and may_keep("geocodio")
    assert not may_keep("google") and not may_keep("") and not may_keep(None)
    assert (credit_of("google"), credit_of("geocodio"), credit_of(None)) == ("Google Maps", None, None)


def test_a_distance_once_kept_from_the_second_service_is_never_handed_on():
    # an order that carries such figures all the same (written by something older, or by hand)
    c, _, second = two()
    takeout(c, "o1", 0, channel="phone", handover="delivery", address=NEW, phone=LINDA)
    state = c.app.state.store.view("o1")
    state.fields["delivery_fee"] = {
        "by": "miles",
        "up_to": "2",
        "amount": "3.00",
        "taxed": False,
        "measured": {"miles": "1.6", "minutes": 5, **GOOGLE_MARKS},
    }

    class Shelf:
        def index(self, *, phone=None):
            return c.app.state.store.index(phone=phone)

        def views(self, entries):
            return [state]

    assert saved_trip(Shelf(), LINDA, NEW, FROM_HOME) is None
    state.fields["delivery_fee"]["measured"]["service"] = "atlas"
    assert saved_trip(Shelf(), LINDA, NEW, FROM_HOME) == {"miles": "1.6", "minutes": 5, **MARKS}


def test_one_service_can_be_asked_by_name_to_try_its_key():
    c, first, second = two()
    brought(c, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": {"miles": "3.2", "minutes": 9, **MARKS}})
    told = far(c, phone=LINDA, via="Google").json()
    assert (told["miles"], told["service"], told["saved"]) == ("3.3", "google", False)  # not her saved one
    assert (first.asked, second.asked) == ([], [(HOME, ELM)])
    assert far(c, via="atlas").json()["service"] == "atlas"
    assert far(c, via="atlas").json()["service"] == "atlas"
    assert len(first.asked) == 2  # asked each time: nothing remembered answers a try
    refused = far(c, via="mapquest")
    assert refused.status_code == 422 and "no map service" in refused.json()["detail"]["message"]
    # a hub with the one service has no second to try
    c, _ = mapped()
    assert far(c, via="google").status_code == 422
    assert c.get("/settings/delivery_fee").json()["services"] == ["atlas"]


def test_the_second_service_alone_is_the_one_service():
    c, _ = mapped()
    second = Globe()
    c.app.state.lookups = Lookups(fallback=second, fallback_daily=7)
    told = far(c).json()
    assert (told["service"], told["credit"]) == ("google", "Google Maps")
    status = c.get("/maps/status").json()
    assert (status["configured"], status["service"], status["daily_most"], status["fallback"]) == (
        True,
        "google",
        7,
        None,
    )


class Slow(Atlas):
    """A service that does not come back in time."""

    def __init__(self) -> None:
        super().__init__()
        self.let_go = threading.Event()

    def trip(self, origin: str, destination: str) -> Trip:
        self.asked.append((origin, destination))
        self.let_go.wait(5)
        return self.trips[destination]


def test_a_service_is_waited_for_only_so_long_and_then_the_second_is_asked():
    slow = Slow()
    c, _, second = two(first=slow, wait=0.05)
    told = far(c).json()
    assert (told["miles"], told["service"]) == ("3.3", "google")
    status = c.get("/maps/status").json()
    assert (status["failed_today"], status["last_failure"]) == (1, "unreachable")
    # alone, the form is told the service cannot be reached; what it says later is dropped
    lookups = Lookups(slow, wait=0.05)
    with pytest.raises(LookupFailed) as failed:
        lookups.trip(HOME, OAK)
    assert failed.value.reason == "unreachable"
    slow.let_go.set()

    # and whatever else a service's own code raises still comes out of the asking
    class Broken(Atlas):
        def trip(self, origin: str, destination: str) -> Trip:
            raise ZeroDivisionError

    with pytest.raises(ZeroDivisionError):
        Lookups(Broken()).trip(HOME, ELM)


def google(handler) -> Google:
    return Google("AIza-key-456", client=httpx.Client(transport=httpx.MockTransport(handler)))


def test_google_is_sent_the_two_addresses_in_the_body_and_the_key_in_a_header(caplog):
    seen: list[httpx.Request] = []

    def answer(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"routes": [{"distanceMeters": 5214, "duration": "545s"}]})

    with caplog.at_level(logging.INFO, logger="httpx"):
        trip = google(answer).trip(HOME, ELM)
    assert trip == Trip(Decimal("3.2"), 9)  # 5,214 meters, 545 seconds
    (request,) = seen
    assert (request.method, str(request.url)) == ("POST", "https://routes.googleapis.com/directions/v2:computeRoutes")
    assert json.loads(request.content) == {
        "origin": {"address": HOME},
        "destination": {"address": ELM},
        "travelMode": "DRIVE",
        "routingPreference": "TRAFFIC_UNAWARE",  # the usual drive: no traffic is asked for
        "regionCode": "us",
    }
    assert request.headers["x-goog-api-key"] == "AIza-key-456"
    # only the length and the time are asked for
    assert request.headers["x-goog-fieldmask"] == "routes.distanceMeters,routes.duration"
    # the log names no address, and no key
    assert "Elm" not in caplog.text and "Restaurant Row" not in caplog.text and "AIza" not in caplog.text


@pytest.mark.parametrize(
    ("answer", "reason"),
    [
        (httpx.Response(200, json={}), "not_found"),  # no route: every empty thing is left out of an answer
        (httpx.Response(200, json={"routes": []}), "not_found"),
        (httpx.Response(200, json={"routes": [{"distanceMeters": 5214}]}), "not_found"),
        (httpx.Response(200, json={"routes": [{"distanceMeters": "far", "duration": "545s"}]}), "not_found"),
        (httpx.Response(200, json={"routes": [{"distanceMeters": 5214, "duration": "soon"}]}), "not_found"),
        (httpx.Response(200, json={"routes": [{"distanceMeters": 9_000_000, "duration": "545s"}]}), "not_found"),
        (httpx.Response(200, json=["what"]), "not_found"),
        (httpx.Response(200, text="<html>"), "unreachable"),
        (httpx.Response(400, json={"error": {"status": "INVALID_ARGUMENT"}}), "not_found"),
        (httpx.Response(404, json={"error": {"status": "NOT_FOUND"}}), "not_found"),
        (httpx.Response(401, json={"error": {"status": "UNAUTHENTICATED"}}), "refused"),
        (httpx.Response(403, json={"error": {"status": "PERMISSION_DENIED"}}), "refused"),
        (httpx.Response(429, json={"error": {"status": "RESOURCE_EXHAUSTED"}}), "limit"),
        (httpx.Response(503, text="later"), "unreachable"),
    ],
)
def test_what_google_may_answer_instead(answer, reason, caplog):
    with pytest.raises(LookupFailed) as failed:
        google(lambda _: answer).trip(HOME, ELM)
    assert failed.value.reason == reason
    assert "Elm" not in caplog.text and "AIza" not in caplog.text


def test_a_google_route_of_no_length_and_one_that_does_not_answer(caplog):
    # the same address twice: the length is nothing and is left out of the answer
    here = google(lambda _: httpx.Response(200, json={"routes": [{"duration": "0s"}]})).trip(HOME, HOME)
    assert here == Trip(Decimal("0.0"), 1)

    def silent(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout(f"timed out asking about {ELM}", request=request)

    with pytest.raises(LookupFailed) as failed:
        google(silent).trip(HOME, ELM)
    assert failed.value.reason == "unreachable" and failed.value.__cause__ is None
    assert "ReadTimeout" in caplog.text and "Elm" not in caplog.text and "AIza" not in caplog.text


def test_the_second_key_comes_from_the_hubs_own_file_too():
    assert fallback_from_env({}) is None
    assert fallback_from_env({"POS_MAPS_GOOGLE_KEY": "  "}) is None
    assert isinstance(fallback_from_env({"POS_MAPS_GOOGLE_KEY": "AIza"}), Google)
    both = lookups_from_env({"POS_MAPS_KEY": "abc", "POS_MAPS_GOOGLE_KEY": "AIza", "POS_MAPS_GOOGLE_DAILY": "25"})
    assert both.names == ["geocodio", "google"]
    assert (both.status()["daily_most"], both.status()["fallback"]["daily_most"]) == (500, 25)
    alone = lookups_from_env({"POS_MAPS_GOOGLE_KEY": "AIza", "POS_MAPS_GOOGLE_DAILY": "lots"})
    assert alone.names == ["google"] and alone.status()["daily_most"] == 100
    assert lookups_from_env({"POS_MAPS_KEY": "abc"}).names == ["geocodio"]


# Live traffic -------------------------------------------------------------------------------------------------


class Roads(Globe):
    """The second service as the hub asks it about the roads right now: tonight Elm Street takes 14 minutes,
    not the usual 9."""

    def __init__(self, *, fails: str | None = None, jams: str | None = None, holds: threading.Event | None = None):
        super().__init__(fails=fails)
        self.now = {ELM: 14, OAK: 30, NEW: 6}
        self.jams = jams
        self.holds = holds
        self.asked_now: list[tuple[str, str]] = []

    def drive_now(self, origin: str, destination: str) -> int:
        self.asked_now.append((origin, destination))
        if self.holds is not None:
            self.holds.wait(5)
        if self.jams:
            raise LookupFailed(self.jams)
        if destination not in self.now:
            raise LookupFailed("not_found")
        return self.now[destination]


def live(c, expect: int = 200, **setting) -> dict:
    """A manager turns live traffic on."""
    put = c.put("/settings/live_drive", json={"enabled": True, "before": 25, **setting}, headers=manager(c))
    assert put.status_code == expect, put.text
    return put.json()


def jammed(**more):
    """A hub with both services, the second one knowing the roads, and live traffic turned on."""
    roads = more.pop("roads", None) or Roads()
    c, first, _ = two(second=roads, **more)
    live(c)
    return c, first, roads


def test_live_traffic_is_off_until_a_manager_turns_it_on():
    # a hub with nothing set up
    assert client().get("/settings/live_drive").json() == {
        "enabled": False,
        "before": 25,
        "traffic": False,
        "origin": False,
        "live": False,
    }
    # one with everything it takes: still off, and nobody is asked about the roads
    roads = Roads()
    c, _, _ = two(second=roads)
    told = c.get("/settings/live_drive").json()
    assert (told["enabled"], told["traffic"], told["origin"], told["live"]) == (False, True, True, False)
    assert c.get("/settings/delivery_fee").json()["live"] is False
    assert far(c, now=True).json()["drive_now"] is None
    assert roads.asked_now == []
    # turned on
    assert live(c, before=30) == {"enabled": True, "before": 30, "traffic": True, "origin": True, "live": True}
    assert c.get("/settings/delivery_fee").json()["live"] is True
    # and off again
    c.put("/settings/live_drive", json={"enabled": False, "before": 30}, headers=manager(c))
    assert c.get("/settings/delivery_fee").json()["live"] is False
    assert far(c, now=True).json()["drive_now"] is None


def test_only_a_manager_sets_it_and_the_minutes_are_whole_and_sane():
    c, _, _ = two(second=Roads())
    assert c.put("/settings/live_drive", json={"enabled": True, "before": 25}).status_code in (401, 403)
    for before in (-1, 241):
        assert live(c, 422, before=before)["detail"]["error"] == "bad_value"
    assert c.get("/settings/live_drive").json()["enabled"] is False
    assert live(c, before=0)["before"] == 0
    # saving the prices leaves it alone, and saving it leaves the prices and the address alone
    priced(c, {**MILES, "origin": HOME})
    assert c.get("/settings/live_drive").json()["live"] is True
    assert c.get("/settings/delivery_fee").json()["origin"] == HOME


def test_a_delivery_for_now_is_told_the_drive_as_it_is_and_the_fee_does_not_go_by_it():
    c, first, roads = jammed()
    told = far(c, now=True).json()
    assert told["drive_now"] == {"minutes": 14, "before": 25, "credit": "Google Maps"}
    # the fee goes by the usual drive, as the first service measured it
    assert (told["miles"], told["minutes"], told["service"], told["keep"]) == ("3.2", 9, "atlas", True)
    assert told["band"] == {"up_to": "4.5", "fee": "5.00"}
    assert (first.asked, roads.asked, roads.asked_now) == ([(HOME, ELM)], [], [(HOME, ELM)])
    # by minutes too: the 9 of the usual drive pick the price, not tonight's 14
    c, _, roads = jammed(fee=MINUTES)
    told = far(c, now=True).json()
    assert (told["minutes"], told["drive_now"]["minutes"]) == (9, 14)
    usual, tonight = far(c).json()["band"], band_for(c.get("/settings/delivery_fee").json(), Decimal("3.2"), 14)
    assert told["band"] == usual and usual is not None and usual != tonight


def test_an_order_for_later_and_a_try_of_a_key_ask_nothing_about_the_roads():
    c, _, roads = jammed()
    assert far(c).json()["drive_now"] is None  # the form did not say it is for now
    assert far(c, now=True, via="atlas").json()["drive_now"] is None
    assert roads.asked_now == []


def test_a_returning_customers_fee_is_her_saved_one_and_the_roads_are_asked_all_the_same():
    c, first, roads = jammed()
    brought(c, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": {"miles": "3.2", "minutes": 9, **MARKS}})
    told = far(c, phone=LINDA, now=True).json()
    assert (told["saved"], told["miles"], told["drive_now"]["minutes"]) == (True, "3.2", 14)
    assert (first.asked, roads.asked_now) == ([], [(HOME, ELM)])


def test_the_drive_right_now_is_never_put_on_the_order():
    c, _, _ = jammed()
    told = far(c, now=True).json()
    brought(c, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": measured(told), "drive_now": told["drive_now"]})
    fee = fee_of(c.app.state.store.view("o1").fields)
    assert fee["measured"] == {"miles": "3.2", "minutes": 9, **MARKS}
    assert "drive_now" not in fee and "14" not in json.dumps(fee)


def test_no_word_about_the_roads_is_no_failure_and_the_fee_is_still_picked():
    for jams in ("unreachable", "refused", "not_found"):
        c, _, roads = jammed(roads=Roads(jams=jams))
        told = far(c, now=True)
        assert told.status_code == 200
        assert (told.json()["drive_now"], told.json()["band"]) == (None, {"up_to": "4.5", "fee": "5.00"})
        traffic = c.get("/maps/status").json()["traffic"]
        assert (traffic["asked_today"], traffic["failed_today"], traffic["last_failure"]) == (1, 1, jams)


def test_the_roads_are_asked_about_each_time_and_no_more_in_a_day_than_set():
    now = [1_000_000.0]
    c, first, roads = jammed(traffic_daily=2, clock=lambda: now[0])
    assert [far(c, now=True).json()["drive_now"]["minutes"] for _ in range(2)] == [14, 14]
    assert len(roads.asked_now) == 2  # nothing is remembered: the roads change
    assert len(first.asked) == 1  # the distance is
    assert far(c, now=True).json()["drive_now"] is None
    assert len(roads.asked_now) == 2
    assert c.get("/maps/status").json()["traffic"] == {
        "service": "google",
        "asked_today": 2,
        "failed_today": 0,
        "daily_most": 2,
        "last_failure": "limit",
        "enabled": True,
    }
    now[0] += 86400
    assert far(c, now=True).json()["drive_now"]["minutes"] == 14


def test_a_slow_word_about_the_roads_does_not_hold_the_form():
    holds = threading.Event()
    c, _, roads = jammed(roads=Roads(holds=holds), wait=0.05)
    told = far(c, now=True).json()
    assert (told["drive_now"], told["miles"]) == (None, "3.2")
    assert c.get("/maps/status").json()["traffic"]["last_failure"] == "unreachable"
    holds.set()


def test_a_hub_where_nobody_knows_the_roads_promises_as_it_did():
    c, atlas = mapped()
    told = live(c)
    assert (told["enabled"], told["traffic"], told["live"]) == (True, False, False)
    assert c.get("/settings/delivery_fee").json()["live"] is False
    assert far(c, now=True).json()["drive_now"] is None
    assert c.get("/maps/status").json()["traffic"] is None
    # and one whose only service is the one that knows them
    c, _ = mapped()
    roads = Roads()
    c.app.state.lookups = Lookups(fallback=roads)
    live(c)
    told = far(c, now=True).json()
    assert (told["service"], told["drive_now"]["minutes"]) == ("google", 14)
    assert (roads.asked, roads.asked_now) == ([(HOME, ELM)], [(HOME, ELM)])


def test_google_is_asked_for_the_time_alone_with_the_traffic_there_is(caplog):
    seen: list[httpx.Request] = []

    def answer(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"routes": [{"duration": "845s"}]})

    with caplog.at_level(logging.INFO, logger="httpx"):
        assert google(answer).drive_now(HOME, ELM) == 14
    (request,) = seen
    assert json.loads(request.content) == {
        "origin": {"address": HOME},
        "destination": {"address": ELM},
        "travelMode": "DRIVE",
        "routingPreference": "TRAFFIC_AWARE",
        "regionCode": "us",
    }
    assert request.headers["x-goog-fieldmask"] == "routes.duration"
    assert request.headers["x-goog-api-key"] == "AIza-key-456"
    assert "Elm" not in caplog.text and "Restaurant Row" not in caplog.text and "AIza" not in caplog.text


@pytest.mark.parametrize(
    ("answer", "reason"),
    [
        (httpx.Response(200, json={}), "not_found"),
        (httpx.Response(200, json={"routes": [{"distanceMeters": 5214}]}), "not_found"),
        (httpx.Response(200, json={"routes": [{"duration": 845}]}), "not_found"),
        (httpx.Response(403, json={"error": {"status": "PERMISSION_DENIED"}}), "refused"),
        (httpx.Response(429, json={"error": {"status": "RESOURCE_EXHAUSTED"}}), "limit"),
    ],
)
def test_what_google_may_say_of_the_roads_instead(answer, reason):
    with pytest.raises(LookupFailed) as failed:
        google(lambda request: answer).drive_now(HOME, ELM)
    assert failed.value.reason == reason


def test_a_short_drive_is_a_minute_and_the_days_most_comes_from_the_hubs_own_file():
    assert google(lambda request: httpx.Response(200, json={"routes": [{"duration": "12s"}]})).drive_now(HOME, ELM) == 1
    both = lookups_from_env({"POS_MAPS_KEY": "abc", "POS_MAPS_GOOGLE_KEY": "AIza", "POS_MAPS_TRAFFIC_DAILY": "40"})
    assert (both.traffic, both.status()["traffic"]["daily_most"]) == ("google", 40)
    assert lookups_from_env({"POS_MAPS_GOOGLE_KEY": "AIza"}).status()["traffic"]["daily_most"] == 150
    alone = lookups_from_env({"POS_MAPS_KEY": "abc"})
    assert (alone.traffic, alone.status()["traffic"]) == (None, None)


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
