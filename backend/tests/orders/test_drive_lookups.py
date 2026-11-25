"""Which map service is asked first (docs/delivery.md, "Which service is asked first").

A hub can have four map services for a delivery's drive: Geocodio, Google, Mapbox and Azure Maps. A manager
puts them in the order they are asked, once for how far a delivery goes and once for the drive right now,
and turns each on or off for each. The first that is turned on and has a key is asked, and the next one
only when the one before it gives nothing. A screen is told who answered and how many of its day's lookups
it has left by the hub's own count.

Geocodio and Google are asked wherever the hub has their key, as before a location could say. Mapbox and
Azure Maps are off until one is turned on. They are asked the drive between two places, so each first
finds where the delivery's address stands, and those searches come out of the same month's free amount as
the list of addresses (tests/orders/test_address_list.py)."""

from __future__ import annotations

import json
import logging
import threading
from decimal import Decimal

import httpx
import pytest

from pos.addresses import MONTHLY_MOST, Suggester, month_of
from pos.maps import (
    OTHER_DAILY_MOST,
    Geocodio,
    LookupFailed,
    Lookups,
    Trip,
    is_on,
    lookups_from_env,
    order_of,
    others_from_env,
    turned_on,
)
from pos.roads import ROUTE_VERSION, AzureRoads, MapboxRoads, roads_from_env
from pos.settings import DEFAULTS, clean_drive_lookups

from .test_address_list import place
from .test_counter import client, manager
from .test_delivery import ELM
from .test_delivery_distance import FROM_HOME, HOME, LINDA, far, live
from .test_delivery_fee import MILES, brought, priced

TOKEN = "pk.eyJ1IjoicG9zLXRlc3QifQ.abcdefghijklmnopqrst"
AZURE_KEY = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHklmn"
STANDS = (42.4523, -71.137)
"""Where the made-up restaurant stands: latitude, longitude."""
THERE = (42.46, -71.15)
"""Where Elm Street does."""
USUAL = {"distance": ["geocodio", "google", "mapbox", "azure"], "traffic": ["google", "mapbox", "azure"]}


class Service:
    """A map service under one of the hub's names, that remembers what it was asked."""

    def __init__(self, name: str, miles: str = "3.2", minutes: int = 9, *, fails: str | None = None) -> None:
        self.name = name
        self.said = Trip(Decimal(miles), minutes)
        self.fails = fails
        self.asked: list[tuple[str, str]] = []

    def trip(self, origin: str, destination: str) -> Trip:
        self.asked.append((origin, destination))
        if self.fails:
            raise LookupFailed(self.fails)
        return self.said


class Knows(Service):
    """One that knows the roads as they are right now as well."""

    def __init__(
        self,
        name: str,
        miles: str = "3.3",
        minutes: int = 10,
        *,
        now: int = 14,
        fails: str | None = None,
        jams: str | None = None,
        holds: threading.Event | None = None,
    ) -> None:
        super().__init__(name, miles, minutes, fails=fails)
        self.now, self.jams, self.holds = now, jams, holds
        self.asked_now: list[tuple[str, str]] = []

    def drive_now(self, origin: str, destination: str) -> int:
        self.asked_now.append((origin, destination))
        if self.holds is not None:
            self.holds.wait(5)
        if self.jams:
            raise LookupFailed(self.jams)
        return self.now


class Between(Knows):
    """One that is asked the drive between two places, as the hub sees Mapbox and Azure Maps: it says how
    many searches it makes first, and is told where the restaurant stands where the hub knows."""

    def __init__(self, name: str, miles: str = "3.4", minutes: int = 11, *, each: int = 1, **more) -> None:
        super().__init__(name, miles, minutes, **more)
        self.each = each
        self.starts: list[tuple[float, float] | None] = []

    def searches(self, told: bool) -> int:
        return self.each if told else 2 * self.each

    def trip(self, origin: str, destination: str, start: tuple[float, float] | None = None) -> Trip:
        self.starts.append(start)
        return super().trip(origin, destination)

    def drive_now(self, origin: str, destination: str, start: tuple[float, float] | None = None) -> int:
        self.starts.append(start)
        return super().drive_now(origin, destination)


def hub(*services, **more):
    """A hub with these map services, each under its own name, the restaurant's own address and its prices."""
    by = {service.name: service for service in services}
    c = client()
    c.app.state.lookups = Lookups(
        by.get("geocodio"),
        fallback=by.get("google"),
        others=[by[name] for name in ("mapbox", "azure") if name in by],
        **more,
    )
    priced(c, {**MILES, "origin": HOME})
    return c


def four(**more):
    """A hub with all four."""
    services = (Service("geocodio"), Knows("google"), Between("mapbox"), Between("azure", "3.5", 12, each=10, now=16))
    return hub(*services, **more), *services


def looked(c) -> dict:
    return c.get("/settings/drive_lookups").json()


def put(c, expect: int = 200, **purposes) -> dict:
    """A manager says who is asked."""
    saved = c.put("/settings/drive_lookups", json=purposes, headers=manager(c))
    assert saved.status_code == expect, saved.text
    return saved.json()


def stands(told: dict, purpose: str) -> list[tuple]:
    """Each service of a purpose as a screen is told it: its name, whether it is on, has a key, and is asked."""
    return [(one["name"], one["on"], one["key"], one["asks"]) for one in told[purpose]["services"]]


# The setting --------------------------------------------------------------------------------------------------


def test_geocodio_and_google_are_asked_as_before_and_the_others_wait_to_be_turned_on():
    c, geocodio, google, mapbox, azure = four()
    told = looked(c)
    assert told["distance"]["order"] == USUAL["distance"] and told["traffic"]["order"] == USUAL["traffic"]
    assert stands(told, "distance") == [
        ("geocodio", True, True, True),
        ("google", True, True, True),
        ("mapbox", False, True, False),
        ("azure", False, True, False),
    ]
    assert stands(told, "traffic") == [
        ("google", True, True, True),
        ("mapbox", False, True, False),
        ("azure", False, True, False),
    ]
    # what a screen calls each, the words its terms want beside its figures, and how its day stands
    assert [(one["title"], one["credit"]) for one in told["distance"]["services"]] == [
        ("Geocodio", None),
        ("Google Maps", "Google Maps"),
        ("Mapbox", "© Mapbox © OpenStreetMap"),
        ("Azure Maps", "Azure Maps"),
    ]
    assert [(one["left"], one["daily_most"]) for one in told["distance"]["services"]] == [
        (500, 500),
        (100, 100),
        (500, 500),
        (15, 15),
    ]
    assert [(one["left"], one["daily_most"]) for one in told["traffic"]["services"]] == [
        (150, 150),
        (500, 500),
        (15, 15),
    ]
    # the form goes on as before: Geocodio first, Google when it gives nothing, and nobody else
    assert c.get("/settings/delivery_fee").json()["services"] == ["geocodio", "google"]
    assert far(c).json()["service"] == "geocodio"
    geocodio.fails, google.fails = "unreachable", "unreachable"
    assert far(c, "4 Oak Rd").json()["detail"]["reason"] == "unreachable"
    assert mapbox.asked == azure.asked == []


def test_a_hub_with_no_key_for_a_service_says_so_and_asks_the_ones_it_has():
    c = hub(Knows("google"))
    told = looked(c)
    assert stands(told, "distance") == [
        ("geocodio", True, False, False),
        ("google", True, True, True),
        ("mapbox", False, False, False),
        ("azure", False, False, False),
    ]
    geocodio = told["distance"]["services"][0]
    assert (geocodio["left"], geocodio["daily_most"], geocodio["asked_today"]) == (None, None, 0)
    assert c.get("/settings/delivery_fee").json()["services"] == ["google"]
    # turning on one that has no key asks nobody new
    put(c, distance={"mapbox": True})
    assert stands(looked(c), "distance")[2] == ("mapbox", True, False, False)
    assert far(c).json()["service"] == "google"


def test_a_manager_puts_the_services_in_another_order_and_the_first_in_it_is_asked_first():
    c, geocodio, google, mapbox, _ = four()
    assert c.put("/settings/drive_lookups", json={"distance": {"order": ["google"]}}).status_code in (401, 403)
    told = put(c, distance={"order": ["mapbox", "google", "geocodio", "azure"], "mapbox": True})
    assert told["distance"]["order"] == ["mapbox", "google", "geocodio", "azure"]
    assert stands(told, "distance")[0] == ("mapbox", True, True, True)
    assert told["traffic"]["order"] == USUAL["traffic"], "the other one is left as it was"
    assert c.get("/settings/delivery_fee").json()["services"] == ["mapbox", "google", "geocodio"]
    answer = far(c).json()
    assert (answer["service"], answer["miles"], answer["title"]) == ("mapbox", "3.4", "Mapbox")
    assert (answer["credit"], answer["keep"]) == ("© Mapbox © OpenStreetMap", False)
    assert geocodio.asked == google.asked == []
    # the next one in it when the first gives nothing, and the one after that
    mapbox.fails = google.fails = "unreachable"
    assert far(c, "4 Oak Rd").json()["service"] == "geocodio"
    assert (len(mapbox.asked), len(google.asked), len(geocodio.asked)) == (2, 1, 1)
    # a name alone leads, and the ones left out follow as they stood in the usual order
    assert put(c, distance={"order": ["azure"]})["distance"]["order"] == ["azure", "geocodio", "google", "mapbox"]
    # the setting holds the order and the switches, and nothing of the day
    assert c.app.state.settings.get("drive_lookups")["distance"] == {
        "order": ["azure", "geocodio", "google", "mapbox"],
        "geocodio": True,
        "google": True,
        "mapbox": True,
        "azure": False,
    }


def test_a_service_that_is_turned_off_is_not_asked_and_with_none_on_nothing_is_looked_up():
    c, geocodio, google, _, _ = four()
    put(c, distance={"geocodio": False})
    assert c.get("/settings/delivery_fee").json()["services"] == ["google"]
    assert far(c).json()["service"] == "google" and geocodio.asked == []
    told = put(c, distance={"google": False})
    assert [one["asks"] for one in told["distance"]["services"]] == [False, False, False, False]
    fee = c.get("/settings/delivery_fee").json()
    assert (fee["maps"], fee["lookup"], fee["services"]) == (False, False, [])
    refused = far(c)
    assert refused.status_code == 409 and "turned on" in refused.json()["detail"]["message"]
    assert len(google.asked) == 1
    # a key is tried out all the same (`hubctl maps test google "<address>"`)
    assert far(c, via="google").json()["service"] == "google"
    # and back on
    put(c, distance={"geocodio": True})
    assert far(c).json()["service"] == "geocodio"


def test_what_a_service_measured_is_not_read_from_memory_once_it_is_turned_off():
    c, geocodio, google, _, _ = four()
    assert far(c).json()["service"] == "geocodio"
    assert far(c).json()["service"] == "geocodio" and len(geocodio.asked) == 1  # from the day's memory
    put(c, distance={"geocodio": False})
    assert far(c).json()["service"] == "google"
    # a customer's own earlier order still says how far: it is hers, whoever measured it
    measured = {"miles": "3.2", "minutes": 9, "service": "geocodio", "from": FROM_HOME}
    brought(c, phone=LINDA, delivery_fee={"up_to": "4.5", "measured": measured})
    again = far(c, phone=LINDA).json()
    assert (again["service"], again["saved"], again["title"]) == ("geocodio", True, "Geocodio")
    assert len(geocodio.asked) == 1 and len(google.asked) == 1


@pytest.mark.parametrize(
    "bad",
    [
        {"distance": {"order": ["google", "here"]}},
        {"distance": {"order": ["google", "google"]}},
        {"traffic": {"order": ["geocodio"]}},  # it does not know the roads right now
        {"distance": {"order": "google"}},
        {"distance": {"mapbox": "maybe"}},
        {"traffic": ["google"]},
    ],
)
def test_a_bad_setting_is_refused_and_nothing_changes(bad):
    c, *_ = four()
    refused = c.put("/settings/drive_lookups", json=bad, headers=manager(c))
    assert refused.status_code == 422, refused.text
    assert looked(c)["distance"]["order"] == USUAL["distance"]
    assert c.app.state.settings.get("drive_lookups") == DEFAULTS["drive_lookups"]


def test_the_setting_is_read_with_care_whatever_was_stored():
    assert clean_drive_lookups({}) == DEFAULTS["drive_lookups"]
    told = clean_drive_lookups({"traffic": {"order": ["azure"], "azure": True}})
    assert told["traffic"] == {"order": ["azure", "google", "mapbox"], "google": True, "mapbox": False, "azure": True}
    assert told["distance"] == DEFAULTS["drive_lookups"]["distance"]
    for bad in ({"distance": 5}, {"distance": {"order": [5]}}, {"traffic": {"google": None, "mapbox": 1}}):
        with pytest.raises(ValueError):
            clean_drive_lookups(bad)
    # the order as the hub reads a setting, whatever stands in it
    assert order_of(None, "distance") == USUAL["distance"]
    assert order_of({"distance": {"order": ["azure", "here", "azure", 5]}}, "distance") == [
        "azure",
        "geocodio",
        "google",
        "mapbox",
    ]
    assert order_of({"traffic": "google"}, "traffic") == USUAL["traffic"]
    assert turned_on(None, "distance") == ["geocodio", "google"] and turned_on({}, "traffic") == ["google"]
    assert is_on({"traffic": {"mapbox": True, "google": "no"}}, "traffic", "mapbox") is True
    assert is_on({"traffic": {"mapbox": True, "google": "no"}}, "traffic", "google") is True  # as unless set


# The drive right now --------------------------------------------------------------------------------------------


def test_the_drive_right_now_is_asked_in_the_order_set_and_says_who_answered():
    c, _, google, mapbox, azure = four()
    live(c)
    told = far(c, now=True).json()["drive_now"]
    assert told == {
        "minutes": 14,
        "before": 25,
        "credit": "Google Maps",
        "service": "google",
        "title": "Google Maps",
        "left": 149,
        "daily_most": 150,
    }
    put(c, traffic={"order": ["azure", "mapbox", "google"], "azure": True, "mapbox": True})
    told = far(c, now=True).json()["drive_now"]
    assert (told["minutes"], told["service"], told["title"], told["credit"]) == (
        16,
        "azure",
        "Azure Maps",
        "Azure Maps",
    )
    assert (told["left"], told["daily_most"]) == (14, 15)
    assert (len(azure.asked_now), len(mapbox.asked_now), len(google.asked_now)) == (1, 0, 1)
    # the distance is asked as it was: the two orders are apart
    assert far(c).json()["service"] == "geocodio"


def test_when_the_first_gives_no_word_about_the_roads_the_next_one_is_asked():
    c, _, google, mapbox, azure = four()
    live(c)
    put(c, traffic={"order": ["mapbox", "azure", "google"], "azure": True, "mapbox": True})
    mapbox.jams = "refused"
    told = far(c, now=True).json()["drive_now"]
    assert (told["minutes"], told["service"]) == (16, "azure")
    azure.jams = "unreachable"
    assert far(c, now=True).json()["drive_now"]["service"] == "google"
    roads = {one["name"]: one for one in looked(c)["traffic"]["services"]}
    assert (roads["mapbox"]["asked_today"], roads["mapbox"]["failed_today"], roads["mapbox"]["last_failure"]) == (
        2,
        2,
        "refused",
    )
    assert (roads["azure"]["asked_today"], roads["azure"]["failed_today"], roads["azure"]["left"]) == (2, 1, 13)
    # nobody knows: no failure, the delivery is promised its usual minutes
    google.jams = "unreachable"
    answer = far(c, now=True)
    assert answer.status_code == 200 and answer.json()["drive_now"] is None


def test_a_screen_is_told_while_a_service_gives_nothing_and_no_longer_once_it_answers_again():
    c, geocodio, google, _, _ = four()
    live(c)

    def failing(purpose: str, name: str) -> str | None:
        return {one["name"]: one for one in looked(c)[purpose]["services"]}[name]["failing"]

    assert failing("distance", "geocodio") is None and failing("traffic", "google") is None
    geocodio.fails, google.jams = "refused", "unreachable"
    assert far(c, now=True).json()["service"] == "google"
    assert (failing("distance", "geocodio"), failing("traffic", "google")) == ("refused", "unreachable")
    assert failing("distance", "google") is None  # it measured the distance all the same
    # the key is put right: the next asking answers, and nothing is said of the last one any more
    geocodio.fails = google.jams = None
    assert far(c, "4 Oak Rd", now=True).json()["service"] == "geocodio"
    assert failing("distance", "geocodio") is None and failing("traffic", "google") is None
    status = c.get("/maps/status").json()
    assert status["last_failure"] == "refused"  # `hubctl maps status` still says what it last failed by


def test_one_that_was_asked_as_often_as_it_may_be_today_is_passed_over():
    c, _, google, mapbox, _ = four(other_traffic_daily={"mapbox": 1})
    live(c)
    put(c, traffic={"order": ["mapbox", "google", "azure"], "mapbox": True})
    assert [far(c, now=True).json()["drive_now"]["service"] for _ in range(3)] == ["mapbox", "google", "google"]
    roads = {one["name"]: one for one in looked(c)["traffic"]["services"]}
    assert (roads["mapbox"]["left"], roads["mapbox"]["last_failure"], len(mapbox.asked_now)) == (0, "limit", 1)


def test_a_slow_service_leaves_the_next_one_its_turn_inside_the_time_a_form_waits():
    holds = threading.Event()
    mapbox = Between("mapbox", holds=holds)
    google = Knows("google")
    c = hub(Service("geocodio"), google, mapbox, wait=0.6)
    live(c)
    put(c, traffic={"order": ["mapbox", "google", "azure"], "mapbox": True})
    try:
        told = far(c, now=True).json()["drive_now"]
    finally:
        holds.set()
    assert (told["minutes"], told["service"]) == (14, "google")
    roads = {one["name"]: one for one in looked(c)["traffic"]["services"]}
    assert (roads["mapbox"]["failed_today"], roads["mapbox"]["last_failure"]) == (1, "unreachable")


class Held(Service):
    """One that does not answer how far it is until it is let go."""

    def __init__(self, name: str, holds: threading.Event) -> None:
        super().__init__(name)
        self.holds = holds

    def trip(self, origin: str, destination: str) -> Trip:
        self.asked.append((origin, destination))
        self.holds.wait(5)
        return self.said


def test_nobody_else_is_asked_how_far_once_the_form_has_stopped_waiting():
    """Each service is waited for so long, and a form for two such waits. With more services turned on than
    that, two that do not answer are the end of it: the third is not asked for a form that went away, and
    nothing is counted against its day."""
    holds = threading.Event()
    mapbox = Between("mapbox")
    c = hub(Held("geocodio", holds), Held("google", holds), mapbox, wait=0.05)
    put(c, distance={"mapbox": True})
    try:
        told = far(c)
    finally:
        holds.set()
    assert (told.status_code, told.json()["detail"]["reason"]) == (424, "unreachable")
    assert mapbox.asked == []
    stands = {one["name"]: one for one in looked(c)["distance"]["services"]}
    assert (stands["mapbox"]["asked_today"], stands["mapbox"]["failing"]) == (0, None)
    assert [stands[name]["failing"] for name in ("geocodio", "google")] == ["unreachable", "unreachable"]


def test_services_that_say_no_at_once_leave_every_one_after_them_its_turn():
    c = hub(
        Service("geocodio", fails="refused"),
        Knows("google", fails="limit"),
        Between("mapbox", fails="unreachable"),
        Between("azure", "3.5", 12, each=10),
    )
    put(c, distance={"mapbox": True, "azure": True})
    assert far(c).json()["service"] == "azure"


def test_live_traffic_needs_a_service_for_the_roads_that_is_turned_on():
    c, _, google, _, _ = four()
    assert live(c)["live"] is True
    put(c, traffic={"google": False})
    told = c.get("/settings/live_drive").json()
    assert (told["traffic"], told["live"]) == (False, False)
    assert far(c, now=True).json()["drive_now"] is None and google.asked_now == []
    put(c, traffic={"mapbox": True})
    assert c.get("/settings/live_drive").json()["live"] is True
    assert far(c, now=True).json()["drive_now"]["service"] == "mapbox"


# Where the two places stand, and whose month the searches come out of -------------------------------------------


def test_the_searches_before_a_drive_come_out_of_the_same_month_as_the_list_of_addresses():
    now = [1_000_000.0]
    c, geocodio, google, mapbox, azure = four(clock=lambda: now[0])
    suggester = Suggester(monthly={"mapbox": 5, "azure": 25}, clock=lambda: now[0])
    c.app.state.lookups.count_with(suggester.spend)
    put(c, distance={"order": ["mapbox", "azure", "geocodio", "google"], "mapbox": True, "azure": True})
    month = month_of(now[0])
    # nobody told it where the restaurant stands (this Geocodio cannot say), so it searches for both places
    assert far(c).json()["service"] == "mapbox" and mapbox.starts == [None]
    assert suggester._counts.of(month) == {"mapbox": 2}
    assert far(c, "4 Oak Rd").json()["service"] == "mapbox"
    # the month has room for one search more and it needs two: it is not asked, and the next one is
    told = far(c, "9 Pine St").json()
    assert (told["service"], len(mapbox.asked)) == ("azure", 2)
    # ten askings of Azure Maps' search make one of what it bills, and it makes two
    assert suggester._counts.of(month) == {"mapbox": 4, "azure": 20}
    assert far(c, "2 Ash Ln").json()["service"] == "geocodio" and len(azure.asked) == 1
    services = {one["name"]: one for one in looked(c)["distance"]["services"]}
    # what its month refused is none of its day's askings
    assert (services["mapbox"]["asked_today"], services["mapbox"]["last_failure"]) == (2, "limit")
    assert (services["azure"]["asked_today"], services["azure"]["failed_today"]) == (1, 0)
    # the list of addresses has that much less left of the same month
    assert Suggester(monthly={"mapbox": 5}, asked=suggester._counts, clock=lambda: now[0]).spend("mapbox", 1) is True
    assert suggester.spend("mapbox", 1) is False and suggester.spend("mapbox", 0) is True
    assert suggester.spend("google", MONTHLY_MOST["google"] + 1) is False


def test_the_restaurants_place_is_geocodios_asked_once_and_given_to_whoever_needs_it():
    asked: list[httpx.Request] = []

    def geocodio(request: httpx.Request) -> httpx.Response:
        asked.append(request)
        if request.url.path.endswith("/geocode"):
            return httpx.Response(200, json=place())
        return httpx.Response(200, json={"destinations": [{"distance_miles": 3.24, "duration_seconds": 545}]})

    mapbox = Between("mapbox")
    spent: list[tuple[str, int]] = []
    lookups = Lookups(
        Geocodio("geo-key-1", client=httpx.Client(transport=httpx.MockTransport(geocodio))), others=[mapbox]
    )
    lookups.count_with(lambda name, askings: spent.append((name, askings)) or True)
    # nobody at a form waits for it: the first asking goes without, and searches for both places
    assert lookups.trip(HOME, ELM, among=["mapbox"]).service == "mapbox"
    lookups.started()
    assert lookups.trip(HOME, "4 Oak Rd", among=["mapbox"]).service == "mapbox"
    assert lookups.drive_ahead(HOME, ELM, among=["mapbox"])() is not None
    assert mapbox.starts == [None, STANDS, STANDS]
    assert spent == [("mapbox", 2), ("mapbox", 1), ("mapbox", 1)]
    # Geocodio was asked where the restaurant's own address stands, once
    (one,) = asked
    assert (one.url.path, dict(one.url.params)) == ("/v2.1/geocode", {"q": HOME, "limit": "1"})
    # another address of the restaurant's is another place
    assert lookups.start_of("5 Other Rd, Woburn, MA") is None
    lookups.started()
    assert lookups.start_of("5 Other Rd, Woburn, MA") == STANDS and len(asked) == 2


def test_with_no_geocodio_or_none_that_answers_each_finds_the_restaurant_itself():
    mapbox = Between("mapbox")
    lookups = Lookups(None, fallback=Knows("google"), others=[mapbox])
    assert lookups.start_of(HOME) is None and lookups._finding is None  # nobody to ask
    now = [1_000_000.0]
    calls: list[str] = []

    def down(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        return httpx.Response(503, text="later")

    lookups = Lookups(
        Geocodio("geo-key-1", client=httpx.Client(transport=httpx.MockTransport(down))),
        others=[mapbox],
        clock=lambda: now[0],
    )
    assert lookups.start_of(HOME) is None
    lookups.started()
    assert lookups.start_of(HOME) is None and len(calls) == 1  # not asked again at once
    now[0] += 3601
    assert lookups.start_of(HOME) is None
    lookups.started()
    assert len(calls) == 2
    assert lookups.trip(HOME, ELM, among=["mapbox"]).service == "mapbox" and mapbox.starts == [None]


# Mapbox itself ------------------------------------------------------------------------------------------------


class MapboxSays:
    """Mapbox's Geocoding and Directions as far as the hub uses them, and everything it was asked."""

    def __init__(self, *, routes: object = None, code: str = "Ok", status: int = 200, features: object = None) -> None:
        self.routes = routes
        self.code, self.status = code, status
        self.features = features
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"message": "Not Authorized - Invalid Token"})
        if "/search/geocode/" in request.url.path:
            lat, lng = STANDS if "Restaurant" in request.url.params["q"] else THERE
            features = [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [lng, lat]}}]
            features = features if self.features is None else self.features
            return httpx.Response(200, json={"type": "FeatureCollection", "features": features})
        routes = self.routes
        if routes is None:  # tonight the drive takes 14 minutes, not the usual 9
            jammed = "driving-traffic" in request.url.path
            routes = [{"distance": 5214.3, "duration": 840.0 if jammed else 545.2, "duration_typical": 560.0}]
        return httpx.Response(200, json={"code": self.code, "routes": routes})

    def roads(self) -> MapboxRoads:
        return MapboxRoads(TOKEN, client=httpx.Client(transport=httpx.MockTransport(self)))


def test_mapbox_is_asked_where_the_two_addresses_stand_and_then_the_drive_between_them(caplog):
    world = MapboxSays()
    with caplog.at_level(logging.INFO):
        trip = world.roads().trip(HOME, ELM)
    assert trip == Trip(Decimal("3.2"), 9)  # 5,214 meters, 545 seconds
    home, there, route = world.seen
    assert all(request.method == "GET" and request.url.host == "api.mapbox.com" for request in world.seen)
    assert home.url.path == there.url.path == "/search/geocode/v6/forward"
    assert dict(home.url.params) == {
        "q": HOME,
        "autocomplete": "false",
        "country": "us",
        "language": "en",
        "limit": "1",
        "access_token": TOKEN,
    }
    # the delivery's address is looked for around the restaurant first, longitude first as Mapbox wants it
    assert (there.url.params["q"], there.url.params["proximity"]) == (ELM, "-71.137,42.4523")
    # the usual drive, between the two places, longitude first, and nothing drawn or spelled out
    assert route.url.path == "/directions/v5/mapbox/driving/-71.137000,42.452300;-71.150000,42.460000"
    assert dict(route.url.params) == {
        "alternatives": "false",
        "overview": "false",
        "steps": "false",
        "access_token": TOKEN,
    }
    # the token and the addresses are in the address of each request, so none is written to the log
    assert TOKEN not in caplog.text and "Elm" not in caplog.text and "api.mapbox.com" not in caplog.text


def test_mapbox_that_is_told_where_the_restaurant_stands_searches_once_and_says_the_roads_right_now():
    world = MapboxSays()
    roads = world.roads()
    assert (roads.searches(True), roads.searches(False)) == (1, 2)
    assert roads.drive_now(HOME, ELM, start=STANDS) == 14  # 840 seconds as the roads are
    there, route = world.seen
    assert there.url.params["q"] == ELM
    assert route.url.path == "/directions/v5/mapbox/driving-traffic/-71.137000,42.452300;-71.150000,42.460000"
    assert roads.trip(HOME, ELM, start=STANDS) == Trip(Decimal("3.2"), 9)
    assert "/mapbox/driving/" in world.seen[-1].url.path
    # a semicolon in an address would make two askings of one
    roads.trip(HOME, "12 Elm St; Apt 2", start=STANDS)
    assert world.seen[-2].url.params["q"] == "12 Elm St  Apt 2"


@pytest.mark.parametrize(
    ("world", "reason"),
    [
        (MapboxSays(status=401), "refused"),
        (MapboxSays(status=403), "refused"),
        (MapboxSays(status=429), "limit"),
        (MapboxSays(status=422), "not_found"),
        (MapboxSays(status=503), "unreachable"),
        (MapboxSays(features=[]), "not_found"),  # an address it reads as no place
        (MapboxSays(features=[{"geometry": {"coordinates": ["east", "north"]}}]), "not_found"),
        (MapboxSays(code="NoRoute", routes=[]), "not_found"),  # no road between the two
        (MapboxSays(routes="none"), "not_found"),
        (MapboxSays(routes=[{"distance": 5214, "duration": None}]), "not_found"),
        (MapboxSays(routes=[{"distance": True, "duration": "soon"}]), "not_found"),
    ],
)
def test_what_mapbox_may_answer_instead(world, reason, caplog):
    roads = world.roads()
    for ask in (roads.trip, roads.drive_now):
        with pytest.raises(LookupFailed) as failed:
            ask(HOME, ELM)
        assert failed.value.reason == reason
    assert TOKEN not in caplog.text and "Elm" not in caplog.text


def test_a_mapbox_route_with_no_length_gives_no_distance_and_still_the_minutes_right_now():
    roads = MapboxSays(routes=[{"distance": "far", "duration": 840}]).roads()
    with pytest.raises(LookupFailed) as failed:
        roads.trip(HOME, ELM, start=STANDS)
    assert failed.value.reason == "not_found"
    assert roads.drive_now(HOME, ELM, start=STANDS) == 14


def test_mapbox_that_does_not_answer_is_unreachable_and_the_log_names_no_address(caplog):
    def silent(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout(f"timed out asking {request.url}", request=request)

    roads = MapboxRoads(TOKEN, client=httpx.Client(transport=httpx.MockTransport(silent)))
    with pytest.raises(LookupFailed) as failed:
        roads.trip(HOME, ELM)
    assert failed.value.reason == "unreachable" and failed.value.__cause__ is None
    assert "the map service asked the drive (mapbox) did not answer (ReadTimeout)" in caplog.text
    assert TOKEN not in caplog.text and "Elm" not in caplog.text


# Azure Maps itself ----------------------------------------------------------------------------------------------


def path_of(meters: object = 5214, seconds: object = 545, traffic: object = 840) -> dict:
    """The feature of Azure Maps' answer that holds a route's totals."""
    return {
        "type": "Feature",
        "geometry": {"type": "MultiLineString", "coordinates": []},
        "properties": {
            "type": "RoutePath",
            "distanceInMeters": meters,
            "durationInSeconds": seconds,
            "durationTrafficInSeconds": traffic,
        },
    }


class AzureSays:
    """Azure Maps' Get Geocoding and Route Directions as far as the hub uses them, and everything it was asked."""

    def __init__(self, *features: dict, status: int = 200, route_status: int = 200, found: object = None) -> None:
        self.features = [path_of()] if not features else list(features)
        self.status, self.route_status = status, route_status
        self.found = found
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"error": {"code": str(self.status)}})
        if request.method == "GET":
            lat, lng = STANDS if "Restaurant" in request.url.params["query"] else THERE
            found = [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [lng, lat]}, "properties": {}}]
            found = found if self.found is None else self.found
            return httpx.Response(200, json={"type": "FeatureCollection", "features": found})
        if self.route_status != 200:
            return httpx.Response(self.route_status, json={"error": {"code": "BadRequest"}})
        waypoint = {"type": "Feature", "geometry": {"type": "Point"}, "properties": {"type": "Waypoint"}}
        return httpx.Response(200, json={"type": "FeatureCollection", "features": [waypoint, *self.features]})

    def roads(self) -> AzureRoads:
        return AzureRoads(AZURE_KEY, client=httpx.Client(transport=httpx.MockTransport(self)))


def test_azure_maps_is_asked_where_the_two_addresses_stand_and_then_the_drive_between_them(caplog):
    world = AzureSays()
    with caplog.at_level(logging.INFO):
        trip = world.roads().trip(HOME, ELM)
    assert trip == Trip(Decimal("3.2"), 9)
    home, there, route = world.seen
    assert all(request.url.host == "atlas.microsoft.com" for request in world.seen)
    assert all(request.headers["subscription-key"] == AZURE_KEY for request in world.seen)  # never in an address
    assert (home.method, home.url.path) == (there.method, there.url.path) == ("GET", "/geocode")
    assert dict(home.url.params) == {"api-version": "2026-01-01", "query": HOME, "top": "1"}
    assert there.url.params["query"] == ELM
    assert (route.method, route.url.path) == ("POST", "/route/directions")
    assert dict(route.url.params) == {"api-version": ROUTE_VERSION} and ROUTE_VERSION == "2025-01-01"
    assert route.headers["content-type"] == "application/geo+json"
    assert json.loads(route.content) == {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [-71.137, 42.4523]},  # longitude first
                "properties": {"pointIndex": 0, "pointType": "waypoint"},
            },
            {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [-71.15, 42.46]},
                "properties": {"pointIndex": 1, "pointType": "waypoint"},
            },
        ],
        "travelMode": "driving",
        "optimizeRoute": "fastestWithoutTraffic",  # the usual drive
        "routeOutputOptions": ["routePath"],
        "maxRouteCount": 1,
    }
    assert AZURE_KEY not in caplog.text and "Elm" not in caplog.text and "atlas.microsoft.com" not in caplog.text


def test_azure_maps_that_is_told_where_the_restaurant_stands_searches_once_and_says_the_roads_right_now():
    world = AzureSays()
    roads = world.roads()
    # ten askings of its search make one of what it bills, as the list's month counts them
    assert (roads.searches(True), roads.searches(False)) == (10, 20)
    assert roads.drive_now(HOME, ELM, start=STANDS) == 14  # 840 seconds with the traffic there is
    there, route = world.seen
    assert there.url.params["query"] == ELM
    asked = json.loads(route.content)
    assert asked["optimizeRoute"] == "fastestWithTraffic"
    assert [feature["geometry"]["coordinates"] for feature in asked["features"]] == [
        [-71.137, 42.4523],
        [-71.15, 42.46],
    ]


@pytest.mark.parametrize(
    ("world", "reason"),
    [
        (AzureSays(status=401), "refused"),
        (AzureSays(status=403), "refused"),
        (AzureSays(status=429), "limit"),
        (AzureSays(status=500), "unreachable"),
        (AzureSays(found=[]), "not_found"),  # an address it reads as no place
        (AzureSays(found=[{"geometry": None}]), "not_found"),
        (AzureSays(route_status=400), "not_found"),  # two places it finds no road between
        (AzureSays({"type": "Feature", "properties": {"type": "ManeuverPoint"}}), "not_found"),
        (AzureSays(path_of(seconds="soon", traffic="soon")), "not_found"),
        (AzureSays(path_of(meters=True, seconds=None, traffic=None)), "not_found"),
    ],
)
def test_what_azure_maps_may_answer_instead(world, reason, caplog):
    roads = world.roads()
    for ask in (roads.trip, roads.drive_now):
        with pytest.raises(LookupFailed) as failed:
            ask(HOME, ELM)
        assert failed.value.reason == reason
    assert AZURE_KEY not in caplog.text and "Elm" not in caplog.text


def test_an_azure_route_is_read_for_what_was_asked_of_it_alone():
    # nothing of the traffic: the usual drive, and no drive right now
    roads = AzureSays(path_of(traffic=None)).roads()
    assert roads.trip(HOME, ELM, start=STANDS) == Trip(Decimal("3.2"), 9)
    with pytest.raises(LookupFailed):
        roads.drive_now(HOME, ELM, start=STANDS)
    # no length: no distance, and still the minutes right now
    roads = AzureSays(path_of(meters=None)).roads()
    with pytest.raises(LookupFailed):
        roads.trip(HOME, ELM, start=STANDS)
    assert roads.drive_now(HOME, ELM, start=STANDS) == 14


# How the hub is put together ----------------------------------------------------------------------------------


def test_the_keys_are_the_ones_the_list_of_addresses_asks_with():
    assert roads_from_env({}) == [] and others_from_env({"POS_MAPS_MAPBOX_KEY": "  "}) == []
    both = roads_from_env({"POS_MAPS_MAPBOX_KEY": TOKEN, "POS_MAPS_AZURE_KEY": f" {AZURE_KEY}\n"})
    assert [type(one) for one in both] == [MapboxRoads, AzureRoads] and [one.name for one in both] == [
        "mapbox",
        "azure",
    ]
    lookups = lookups_from_env(
        {
            "POS_MAPS_KEY": "abc",
            "POS_MAPS_GOOGLE_KEY": "AIza",
            "POS_MAPS_MAPBOX_KEY": TOKEN,
            "POS_MAPS_AZURE_KEY": AZURE_KEY,
            "POS_MAPS_AZURE_ROUTES_DAILY": "40",
            "POS_MAPS_MAPBOX_TRAFFIC_DAILY": "lots",
        }
    )
    assert lookups.names == ["geocodio", "google", "mapbox", "azure"]
    assert lookups.traffics == ["google", "mapbox", "azure"]
    status = lookups.status()
    # the first two as `hubctl maps status` always said them, and the others after
    assert (status["service"], status["fallback"]["service"]) == ("geocodio", "google")
    assert [(one["service"], one["daily_most"]) for one in status["others"]] == [("mapbox", 500), ("azure", 40)]
    assert [(one["service"], one["daily_most"]) for one in status["traffics"]] == [
        ("google", 150),
        ("mapbox", OTHER_DAILY_MOST["mapbox"]),
        ("azure", 15),
    ]
    # with their keys alone they are the hub's services, and still off until turned on
    alone = lookups_from_env({"POS_MAPS_MAPBOX_KEY": TOKEN})
    assert alone.names == ["mapbox"] and alone.status()["service"] == "mapbox" and alone.status()["others"] == []


def test_the_hub_counts_the_searches_with_the_list_of_addresses_as_it_is_put_together():
    c = client()
    assert c.app.state.lookups._spend == c.app.state.suggester.spend


def test_the_status_lists_every_service_in_the_order_it_is_asked():
    c, *_ = four()
    live(c)
    put(c, distance={"order": ["google", "geocodio"]}, traffic={"order": ["mapbox"], "mapbox": True})
    far(c, now=True)
    status = c.get("/maps/status").json()
    assert [(one["name"], one["asks"], one["asked_today"]) for one in status["distance"]] == [
        ("google", True, 1),
        ("geocodio", True, 0),
        ("mapbox", False, 0),
        ("azure", False, 0),
    ]
    assert [(one["name"], one["asks"], one["asked_today"]) for one in status["drive_now"]] == [
        ("mapbox", True, 1),
        ("google", True, 0),
        ("azure", False, 0),
    ]
    assert status["live"] is True and all(roads["enabled"] is True for roads in status["traffics"])
    assert "Elm" not in json.dumps(status)  # no address is in it
