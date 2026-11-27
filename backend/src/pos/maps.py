"""How far a delivery goes, asked of a map service (docs/delivery.md, "Looking the distance up").

The delivery fee goes by miles or by the minutes of the drive (`pos.orders.delivery_fee`), and whoever takes
the order picks the band. With a map service's key on the hub (`POS_MAPS_KEY` in /opt/pos/.env, put there by
`hubctl maps key`) and the restaurant's own address in the fee's setting (`origin`), the hub asks the
service how far a delivery's address is, and the form picks the band for it. Without either, nothing is
asked and the band is tapped by hand, as before. A lookup that fails is said on the form, and the band is
tapped by hand.

What leaves the building: the two addresses, the restaurant's and the delivery's, and nothing else. No
name, no phone number, nothing of the order. An answer is kept in memory for a day so the same address is
not asked twice, and is never written down; the log names no address. The key goes in a header, never in an
address a log could show.

The hub asks at most `POS_MAPS_DAILY` times a day (500 unless set), so a screen gone wrong cannot run up a
bill: past that the form says so and the band is tapped by hand.

A customer who orders again to the same address is not asked about at all: what the map said the last time
is on their own order, beside the fee, and the hub reads it there (`pos.customers.saved_trip`). Those
figures say which service measured them and carry a mark of the restaurant's address they were measured
from (`origin_mark`), so a restaurant whose address is corrected does not go on charging by the old one.

There may be a second service, asked only when the first gives no distance ("A second map service" in the
guide): Google Maps, with a key of its own (`POS_MAPS_GOOGLE_KEY`, put there by `hubctl maps google`) and
a day's most of its own (`POS_MAPS_GOOGLE_DAILY`, 100 unless set). Google's terms do not let its distances
and drive times be kept, so what it says picks the price and is then gone: it is not remembered for the
day, it does not go onto the order, and a customer measured by it is asked about again the next time
(`may_keep`). Its terms also want its name beside its figures wherever they are shown (`credit_of`).

Google also knows the roads as they are right now ("Live traffic" in the guide). Where a manager turned
that on, a delivery that is for now is promised its cooking and the drive as it is at this minute
(`Lookups.drive_soon`): one more request to Google, of its dearer kind, at most `POS_MAPS_TRAFFIC_DAILY` a
day (150 unless set). That figure is used for the promise and kept nowhere, and it never touches the fee,
which goes by the usual drive.

Mapbox and Azure Maps can be asked both things as well (`pos.roads`), with the keys the list of addresses
uses, each where a manager turned it on for that ("Which service is asked first" in the guide). The order
the services are asked in, for the distance and for the drive right now, is the location's own
(`drive_lookups` in pos.settings, `turned_on` here): the first that is turned on and has a key, and the
next one only when the one before it gives nothing. Each has a day's most of its own, and a form is told
who answered and how many of its day's lookups are left, for the little badge beside the figures.
"""

from __future__ import annotations

import hashlib
import logging
import os
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any, Protocol

import httpx

log = logging.getLogger("pos.maps")

ADDRESS_MAX = 200
"""As long as an order's own address may be."""
TIMEOUT_SECONDS = 4.0
"""How long one service is waited for, in all (`_within`). Two of them, one after the other, still answer
inside the nine seconds a form waits for the hub, and somebody is on the phone with a customer meanwhile."""
CHAIN_WAITS = 2
"""How many such waits all the services asked how far one address is get between them, however many a
location turned on: the form has stopped waiting past that, so nobody else is asked."""
KEEP_SECONDS = 24 * 3600
KEEP_MOST = 500
DAILY_MOST = 500
FALLBACK_DAILY_MOST = 100
"""The most the second service is asked in a day unless set: about 3,000 a month, inside what Google's
price list gave away each month when this was written (10,000 plain routes)."""
TRAFFIC_DAILY_MOST = 150
"""The most the drive right now is asked in a day unless set: about 4,650 a month, inside what Google's
price list gave away each month when this was written (5,000 routes with traffic)."""
OTHER_DAILY_MOST = {"mapbox": 500, "azure": 15}
"""The most Mapbox and Azure Maps are asked how far a delivery goes in a day unless set. Mapbox gave away
100,000 directions a month when this was written, and Azure Maps 1,000 routes (their price lists, read
2026-11-25); the drive right now is counted by itself (`OTHER_TRAFFIC_DAILY_MOST`), and the two together
stay inside those."""
OTHER_TRAFFIC_DAILY_MOST = {"mapbox": 500, "azure": 15}
"""The most each of them is asked the drive right now in a day unless set."""
START_SECONDS = 25 * 86400.0
"""How long where the restaurant stands is remembered, for a service that is asked the drive between two
places and not between two addresses. Geocodio says it, whose answers may be kept."""
START_AGAIN = 3600.0
"""How long after Geocodio did not say where the restaurant stands it is asked again."""
METERS_A_MILE = Decimal("1609.344")
TENTH = Decimal("0.1")
HUNDREDTH = Decimal("0.01")
MILES_MOST = Decimal(1000)
"""An answer further than this is no delivery: the address was read as one somewhere else."""

GEOCODIO = "https://api.geocod.io/v2.1"
GOOGLE = "https://routes.googleapis.com"

NOT_KEPT = frozenset({"google", "mapbox", "azure"})
"""The services whose terms do not let a distance or a drive time be kept. Google's (the Routes API's
policies and the Google Maps Platform Service Specific Terms, read 2026-11-18) allow place IDs to be kept,
and coordinates for thirty days, and nothing else of an answer. Mapbox's and Azure Maps' pages on their
routes say nothing that lets a figure be kept (read 2026-11-25), so theirs are not kept either."""
CREDIT = {"google": "Google Maps", "mapbox": "\u00a9 Mapbox \u00a9 OpenStreetMap", "azure": "Azure Maps"}
"""What a service's terms want shown beside its figures, in these exact words."""
TITLE = {"geocodio": "Geocodio", "google": "Google Maps", "mapbox": "Mapbox", "azure": "Azure Maps"}
"""What a screen calls each service."""
ORDER = ("geocodio", "google", "mapbox", "azure")
"""The services a hub can ask how far a delivery goes, in the order they are asked unless the location
sets another."""
TRAFFIC_ORDER = ("google", "mapbox", "azure")
"""The ones that know the roads as they are right now, in the order they are asked unless set."""
PURPOSES = {"distance": ORDER, "traffic": TRAFFIC_ORDER}
ON_UNLESS_SET = {"distance": frozenset({"geocodio", "google"}), "traffic": frozenset({"google"})}
"""The services that are asked wherever the hub has their key, until a manager turns one off: the ones
that were asked before a location could say. Mapbox and Azure Maps are off until one is turned on, since
that sends a delivery's address to a service nobody chose for it."""

SAID = {
    "not_found": "The map service could not find that address. Check it, or pick the fee by hand.",
    "unreachable": "The map service is not answering. Pick the fee by hand.",
    "refused": "The map service refused the hub's key. Pick the fee by hand, and tell the owner.",
    "limit": "The map service has been asked as often as it may be today. Pick the fee by hand.",
}


@dataclass(frozen=True)
class Trip:
    """A drive from the restaurant to a delivery's address."""

    miles: Decimal  # along the road, to a hundredth: as fine as a band of the fee may be listed
    minutes: int  # the usual drive, to the nearest minute and never less than one
    service: str = field(default="", compare=False)  # who measured it, once `Lookups` knows

    def as_json(self) -> dict[str, Any]:
        return {"miles": miles_text(self.miles), "minutes": self.minutes}


@dataclass(frozen=True)
class Driven:
    """The drive as the roads are at this minute, and who said so."""

    minutes: int
    service: str


def may_keep(service: object) -> bool:
    """Whether a distance this service measured may be kept: on the order, and in the hub's memory for the
    day. Figures that do not say who measured them may not: nobody can tell whose terms they fall under."""
    return isinstance(service, str) and bool(service) and service not in NOT_KEPT


def credit_of(service: object) -> str | None:
    """The words a service's terms want beside its figures on a screen, or None."""
    return CREDIT.get(service) if isinstance(service, str) else None


def order_of(setting: Mapping[str, Any] | None, purpose: str) -> list[str]:
    """The order a location asks the services in for one purpose (`distance`, how far a delivery goes, or
    `traffic`, the drive right now), as its setting has it (`drive_lookups`): the names it gives that are
    services for that, each once, and after them any it leaves out, in the usual order."""
    usual = PURPOSES[purpose]
    told = setting.get(purpose) if setting is not None else None
    given = told.get("order") if isinstance(told, Mapping) else None
    named: list[str] = []
    if isinstance(given, list | tuple):
        for name in given:
            if name in usual and name not in named:
                named.append(name)
    return [*named, *(name for name in usual if name not in named)]


def is_on(setting: Mapping[str, Any] | None, purpose: str, name: str) -> bool:
    """Whether a location has that service turned on for that purpose: what its setting says, and where it
    says nothing, whether the service was asked before a location could say (`ON_UNLESS_SET`)."""
    told = setting.get(purpose) if setting is not None else None
    said = told.get(name) if isinstance(told, Mapping) else None
    return said if isinstance(said, bool) else name in ON_UNLESS_SET[purpose]


def turned_on(setting: Mapping[str, Any] | None, purpose: str) -> list[str]:
    """The services a location asks for one purpose, in the order it asks them."""
    return [name for name in order_of(setting, purpose) if is_on(setting, purpose, name)]


class LookupFailed(Exception):
    """A lookup that gave no distance. `reason` is one of `SAID`; the message is for whoever takes the order.
    `code` is the status the service answered with, where it answered something that was no answer."""

    def __init__(self, reason: str, code: int | None = None) -> None:
        super().__init__(SAID[reason])
        self.reason = reason
        self.code = code


class Maps(Protocol):
    name: str

    def trip(self, origin: str, destination: str) -> Trip:
        """The drive from one address to the other. Raises LookupFailed."""
        ...


def miles_text(miles: Decimal) -> str:
    """Road miles as they are said and kept: to a hundredth, "3.24", and with one figure after the point
    where the hundredths are nothing, "3.2", "3.0", as every distance read before a band could be listed
    finer than a tenth."""
    far = miles.quantize(HUNDREDTH, rounding=ROUND_HALF_UP)
    return format(far.quantize(TENTH) if far == far.quantize(TENTH) else far, "f")


def trip_of(miles: Any, seconds: Any) -> Trip | None:
    """A service's two numbers, read: road miles to a hundredth and the drive in whole minutes. None when
    either is no such number."""
    try:
        far = Decimal(str(miles))
        took = Decimal(str(seconds))
    except InvalidOperation:
        return None
    if isinstance(miles, bool) or isinstance(seconds, bool) or not far.is_finite() or not took.is_finite():
        return None
    if far < 0 or took < 0 or far > MILES_MOST:
        return None
    minutes = int((took / 60).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    return Trip(miles=far.quantize(HUNDREDTH, rounding=ROUND_HALF_UP), minutes=max(1, minutes))


class _NoAddresses(logging.Filter):
    """httpx logs the address of every request it makes, and a lookup's holds two street addresses."""

    def __init__(self, host: str) -> None:
        super().__init__()
        self._host = host

    def filter(self, record: logging.LogRecord) -> bool:
        return not any(isinstance(arg, httpx.URL) and arg.host == self._host for arg in record.args or ())


class Geocodio:
    """Geocodio's distance call (https://www.geocod.io/docs/): one origin, one destination, by road. And its
    plain geocoding of one address (`locate`), for where the restaurant itself stands: its terms let an
    answer be kept and shown or used with anybody's map, which Google's and Mapbox's do not."""

    name = "geocodio"

    def __init__(self, key: str, *, base: str = GEOCODIO, client: httpx.Client | None = None) -> None:
        self._key = key
        self._base = base.rstrip("/")
        self._client = client if client is not None else httpx.Client(timeout=TIMEOUT_SECONDS)
        logging.getLogger("httpx").addFilter(_NoAddresses(httpx.URL(self._base).host))

    def trip(self, origin: str, destination: str) -> Trip:
        try:
            answer = self._client.get(
                f"{self._base}/distance",
                params={"origin": origin, "destinations[]": destination, "mode": "driving"},
                headers={"Authorization": f"Bearer {self._key}"},
            )
        except httpx.HTTPError as err:
            log.warning("the map service did not answer (%s)", type(err).__name__)  # its text holds the addresses
            raise LookupFailed("unreachable") from None
        status = answer.status_code
        if status in (401, 403):
            log.warning("the map service refused the key (%d)", status)
            raise LookupFailed("refused")
        if status in (402, 429):
            log.warning("the map service says the account is at its limit (%d)", status)
            raise LookupFailed("limit")
        if status == 422:
            raise LookupFailed("not_found")
        if status >= 400:
            log.warning("the map service answered %d", status)
            raise LookupFailed("unreachable")
        try:
            data = answer.json()
        except ValueError:
            log.warning("the map service's answer could not be read")
            raise LookupFailed("unreachable") from None
        found = _destination(data)
        trip = trip_of(found.get("distance_miles"), found.get("duration_seconds")) if found is not None else None
        if trip is None:
            raise LookupFailed("not_found")
        return trip

    def locate(self, address: str) -> tuple[float, float] | None:
        """Where an address stands, as latitude and longitude: the first place the service reads it as. None
        when it reads it as none. Raises LookupFailed."""
        try:
            answer = self._client.get(
                f"{self._base}/geocode",
                params={"q": address, "limit": "1"},
                headers={"Authorization": f"Bearer {self._key}"},
            )
        except httpx.HTTPError as err:
            log.warning("the map service did not answer (%s)", type(err).__name__)  # its text holds the address
            raise LookupFailed("unreachable") from None
        status = answer.status_code
        if status in (401, 403):
            log.warning("the map service refused the key (%d)", status)
            raise LookupFailed("refused")
        if status in (402, 429):
            log.warning("the map service says the account is at its limit (%d)", status)
            raise LookupFailed("limit")
        if status == 422:
            return None
        if status >= 400:
            log.warning("the map service answered %d", status)
            raise LookupFailed("unreachable")
        try:
            data = answer.json()
        except ValueError:
            log.warning("the map service's answer could not be read")
            raise LookupFailed("unreachable") from None
        results = data.get("results") if isinstance(data, Mapping) else None
        first = results[0] if isinstance(results, list) and results and isinstance(results[0], Mapping) else {}
        stands = first.get("location")
        if not isinstance(stands, Mapping):
            return None
        return _point(stands.get("lat"), stands.get("lng"))


def _point(latitude: Any, longitude: Any) -> tuple[float, float] | None:
    """A place on the map as two numbers, or None for anything else."""
    numbers = (latitude, longitude)
    if any(isinstance(one, bool) or not isinstance(one, int | float) for one in numbers):
        return None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    return float(latitude), float(longitude)


class Google:
    """Google's Routes API (https://developers.google.com/maps/documentation/routes): one route by car from
    one address to the other, with no traffic in it (`TRAFFIC_UNAWARE`, the plain kind of request). The two
    addresses go in the body and the key in a header, so neither is in the address of the request, which a
    log could show. Only the length and the time of the route are asked for (the field mask)."""

    name = "google"

    def __init__(self, key: str, *, base: str = GOOGLE, client: httpx.Client | None = None) -> None:
        self._key = key
        self._base = base.rstrip("/")
        self._client = client if client is not None else httpx.Client(timeout=TIMEOUT_SECONDS)

    def trip(self, origin: str, destination: str) -> Trip:
        route = self._route(origin, destination, "TRAFFIC_UNAWARE", "routes.distanceMeters,routes.duration")
        trip = _google_trip(route) if route is not None else None
        if trip is None:  # no route between the two: an address read as one overseas, or not read at all
            raise LookupFailed("not_found")
        return trip

    def drive_now(self, origin: str, destination: str) -> int:
        """The minutes of the drive as the roads are at this minute (`TRAFFIC_AWARE`: Google's dearer kind
        of request, and the only thing asked for is the time). Raises LookupFailed."""
        route = self._route(origin, destination, "TRAFFIC_AWARE", "routes.duration")
        minutes = _google_minutes(route.get("duration")) if route is not None else None
        if minutes is None:
            raise LookupFailed("not_found")
        return minutes

    def _route(self, origin: str, destination: str, preference: str, mask: str) -> Mapping[str, Any] | None:
        """The first route Google gives from one address to the other, with the fields the mask names; None
        when it gives none. Raises LookupFailed."""
        try:
            answer = self._client.post(
                f"{self._base}/directions/v2:computeRoutes",
                json={
                    "origin": {"address": origin},
                    "destination": {"address": destination},
                    "travelMode": "DRIVE",
                    "routingPreference": preference,
                    "regionCode": "us",
                },
                headers={"X-Goog-Api-Key": self._key, "X-Goog-FieldMask": mask},
            )
        except httpx.HTTPError as err:
            log.warning("the second map service did not answer (%s)", type(err).__name__)
            raise LookupFailed("unreachable") from None
        status = answer.status_code
        if status in (401, 403):  # a wrong key, the Routes API not turned on, or billing not set up
            log.warning("the second map service refused the key (%d)", status)
            raise LookupFailed("refused")
        if status == 429:
            log.warning("the second map service says the account is at its limit (%d)", status)
            raise LookupFailed("limit")
        if status in (400, 404):  # an address it cannot read
            raise LookupFailed("not_found")
        if status >= 400:
            log.warning("the second map service answered %d", status)
            raise LookupFailed("unreachable")
        try:
            data = answer.json()
        except ValueError:
            log.warning("the second map service's answer could not be read")
            raise LookupFailed("unreachable") from None
        routes = data.get("routes") if isinstance(data, Mapping) else None
        return routes[0] if isinstance(routes, list) and routes and isinstance(routes[0], Mapping) else None


def _google_trip(route: Mapping[str, Any]) -> Trip | None:
    """A route's length in meters and its time as "545s", read. A length of nothing is left out of the
    answer altogether, as every zero is."""
    took = route.get("duration")
    if not isinstance(took, str) or not took.endswith("s"):
        return None
    meters = route.get("distanceMeters", 0)
    if isinstance(meters, bool) or not isinstance(meters, int | float):
        return None
    return trip_of(Decimal(str(meters)) / METERS_A_MILE, took[:-1])


def _destination(data: Any) -> Mapping[str, Any] | None:
    """The one destination of an answer: the first of its `destinations`, or the answer itself where the
    numbers stand at the top."""
    if not isinstance(data, Mapping):
        return None
    listed = data.get("destinations")
    if isinstance(listed, list) and listed and isinstance(listed[0], Mapping):
        return listed[0]
    return data if "distance_miles" in data else None


def _plain(address: str) -> str:
    """An address as two spellings of it compare: the case and the spaces aside."""
    return " ".join(address.split()).casefold()


def origin_mark(origin: str) -> str:
    """A short mark of the address deliveries start from, kept beside a distance measured from it. A
    distance measured from another address has another mark, and is not used again. It says nothing of the
    address itself."""
    return hashlib.sha256(_plain(origin).encode()).hexdigest()[:8]


def same_address(one: object, other: object) -> bool:
    """Whether two spellings are one address: the case and the spaces aside, and nothing else. "12 Elm St"
    and "12 Elm Street" are two, and the second is looked up."""
    first = _plain(str(one or ""))
    return bool(first) and first == _plain(str(other or ""))


def _google_minutes(took: Any) -> int | None:
    """A route's time as Google writes it, "545s", in whole minutes and never less than one."""
    if not isinstance(took, str) or not took.endswith("s"):
        return None
    trip = trip_of(0, took[:-1])
    return trip.minutes if trip is not None else None


def _within(seconds: float, ask: Callable[[], Any]) -> Any:
    """What `ask` answers, or LookupFailed("unreachable") when it has not answered in `seconds`. A request's
    own timeout bounds each of its steps, not their sum, and not the looking up of the service's name; the
    form waits only so long. The asking goes on behind, and what it answers then is dropped."""
    box: list[Any] = []

    def run() -> None:
        try:
            box.append(ask())
        except Exception as err:  # noqa: BLE001  handed to the one who waits, below
            box.append(err)

    thread = threading.Thread(target=run, name="maps-ask", daemon=True)
    thread.start()
    thread.join(seconds)
    if not box:
        log.warning("a map service was not heard from in %.0f s", seconds)
        raise LookupFailed("unreachable")
    if isinstance(box[0], Exception):
        raise box[0]
    return box[0]


@dataclass
class _Asked:
    """One service, and how today went with it."""

    maps: Maps
    daily: int
    asked: int = 0
    failed: int = 0
    last_failure: str | None = None
    failing: str | None = None  # why the last asking of it gave nothing; None once it answered again
    other: bool = False  # one after the first two (Mapbox, Azure Maps): off until a manager turns it on

    def status(self) -> dict[str, Any]:
        return {
            "service": self.maps.name,
            "asked_today": self.asked,
            "failed_today": self.failed,
            "daily_most": self.daily,
            "left": max(0, self.daily - self.asked),
            "last_failure": self.last_failure,
        }


def _carried(asked: _Asked, was: Mapping[str, _Asked]) -> _Asked:
    """`asked` with the day's counts of the same service as it stood before."""
    before = was.get(asked.maps.name)
    if before is not None:
        asked.asked, asked.failed, asked.last_failure = before.asked, before.failed, before.last_failure
        asked.failing = before.failing
    return asked


def _in_turn(asked: list[_Asked], among: Sequence[str] | None) -> list[_Asked]:
    """These services as a location asks them: the ones `among` names, in its order. All of them as they
    stand where it names none."""
    if among is None:
        return list(asked)
    by = {one.maps.name: one for one in asked}
    return [by[name] for name in among if name in by]


class Lookups:
    """The hub's lookups: the services it has a key for, asked in the order the location sets and the next
    one only when the one before it gives nothing; each answer that may be kept remembered for a day; and
    none of them asked more in a day than the owner would expect to pay for."""

    def __init__(
        self,
        maps: Maps | None = None,
        *,
        fallback: Maps | None = None,
        others: Sequence[Maps | None] = (),
        daily: int = DAILY_MOST,
        fallback_daily: int = FALLBACK_DAILY_MOST,
        traffic_daily: int = TRAFFIC_DAILY_MOST,
        other_daily: Mapping[str, int] | None = None,
        other_traffic_daily: Mapping[str, int] | None = None,
        wait: float = TIMEOUT_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._daily = daily
        self._fallback_daily = fallback_daily
        self._traffic_daily = traffic_daily
        self._other_daily = {**OTHER_DAILY_MOST, **(other_daily or {})}
        self._other_traffic_daily = {**OTHER_TRAFFIC_DAILY_MOST, **(other_traffic_daily or {})}
        self._wait = wait
        self._clock = clock
        self._lock = threading.Lock()
        self._kept: OrderedDict[tuple[str, str], tuple[float, Trip]] = OrderedDict()
        self._day = 0
        self._spared = 0
        self._services: list[_Asked] = []
        self._traffics: list[_Asked] = []
        self._stands: tuple[str, float, tuple[float, float] | None] | None = None  # which address, when, where
        self._finding: threading.Thread | None = None
        self._spend: Callable[[str, int], bool] | None = None
        self.use(maps, fallback, *others)

    def use(self, maps: Maps | None, fallback: Maps | None = None, *others: Maps | None) -> None:
        """These services from now on: a key was typed, replaced or removed while the hub runs
        (`pos.keys`). What the day already counted against a service stays counted against it, so typing a
        key again does not start the day's most over. `others` are the ones after the first two (Mapbox,
        Azure Maps), each with a day's most by its name."""
        with self._lock:
            was = {asked.maps.name: asked for asked in self._services}
            roads = {asked.maps.name: asked for asked in self._traffics}
            self._services = [
                _carried(_Asked(service, most), was)
                for service, most in ((maps, self._daily), (fallback, self._fallback_daily))
                if service is not None
            ]
            self._services += [
                _carried(_Asked(other, self._other_daily.get(other.name, self._fallback_daily), other=True), was)
                for other in others
                if other is not None
            ]
            # the ones that know the roads as they are right now, each counted by itself
            self._traffics = [
                _carried(
                    _Asked(
                        asked.maps,
                        self._other_traffic_daily.get(asked.maps.name, self._traffic_daily),
                        other=asked.other,
                    ),
                    roads,
                )
                for asked in self._services
                if callable(getattr(asked.maps, "drive_now", None))
            ]

    def count_with(self, spend: Callable[[str, int], bool] | None) -> None:
        """Who counts the searches a service makes before it can say a drive (Mapbox and Azure Maps are asked
        where an address stands first): the list of addresses, against the same month's free amount as its
        own (`Suggester.spend`). It says False where the month has no room, and the service is then not
        asked. None for nobody, and they are not counted."""
        self._spend = spend

    @property
    def ready(self) -> bool:
        """Whether there is a service to ask."""
        return bool(self._services)

    @property
    def names(self) -> list[str]:
        """The services the hub has a key for, as they stand: the first, the one for when it gives nothing,
        and the others."""
        return [service.maps.name for service in self._services]

    def _today(self, now: float) -> None:
        """Starts the day's counts over when the day has turned. Called with the lock held."""
        day = int(now // 86400)
        if day != self._day:
            self._day, self._spared = day, 0
            for service in (*self._services, *self._traffics):
                service.asked, service.failed, service.failing = 0, 0, None

    def spared(self) -> None:
        """A distance was read off a customer's own earlier order, and nobody was asked: counted, so
        `hubctl maps status` can say how often."""
        with self._lock:
            self._today(self._clock())
            self._spared += 1

    def start_of(self, origin: str) -> tuple[float, float] | None:
        """Where the restaurant stands (latitude, longitude), from memory, for a service that is asked the
        drive between two places and not between two addresses. Geocodio says it, whose answers may be kept
        and given to anybody (`locate`), and it is remembered for 25 days. When it is not known, the address
        changed or the memory is old, Geocodio is asked behind this call, and after it did not say not again
        for an hour. Nobody at a form waits for it: until it is known, such a service finds the restaurant
        itself, each time, and keeps nothing. None also where the hub has no Geocodio."""
        now = self._clock()
        mark = _plain(origin)
        with self._lock:
            held = self._stands
            if held is not None and held[0] == mark:
                if now - held[1] < (START_SECONDS if held[2] is not None else START_AGAIN):
                    return held[2]
            if not any(
                may_keep(one.maps.name) and callable(getattr(one.maps, "locate", None)) for one in self._services
            ):
                return None
            self._stands = (mark, now, None)  # asked for: nobody else asks meanwhile

            def find() -> None:
                try:
                    found = self.locate(origin)
                except LookupFailed:
                    found = None
                except Exception:  # noqa: BLE001  a help: the service finds the restaurant itself
                    log.warning("where the restaurant stands could not be asked")
                    found = None
                with self._lock:
                    if self._stands is not None and self._stands[0] == mark:
                        self._stands = (mark, now, found)

            self._finding = threading.Thread(target=find, name="maps-start", daemon=True)
            self._finding.start()
        return None

    def started(self, seconds: float = 5.0) -> None:
        """Waits until the asking for where the restaurant stands is over, where one runs: for a test."""
        finding = self._finding
        if finding is not None:
            finding.join(seconds)

    def _ask_of(self, service: _Asked, what: str, origin: str, destination: str) -> Callable[[], Any]:
        """The asking of one service for the drive (`trip`) or for the drive right now (`drive_now`). A
        service that is asked the drive between two places says how many searches it makes first
        (`searches`): it is told where the restaurant stands where the hub knows (`start_of`), and its
        searches are counted against its month before they are made (`count_with`). Raises
        LookupFailed("limit") where the month has no room for them."""
        maps = service.maps
        call = getattr(maps, what)
        searches = getattr(maps, "searches", None)
        if not callable(searches):
            return lambda: call(origin, destination)
        start = self.start_of(origin)
        spend = self._spend
        if spend is not None and not spend(maps.name, searches(start is not None)):
            raise LookupFailed("limit")
        return lambda: call(origin, destination, start=start)

    def trip(
        self, origin: str, destination: str, *, via: str | None = None, among: Sequence[str] | None = None
    ) -> Trip:
        """The drive from the restaurant to a delivery's address, and who measured it (`Trip.service`). The
        services `among` names are asked in its order (the ones the location turned on, as it ordered them;
        all of them as they stand where it names none), the next one only when the one before it gives no
        distance, whatever its reason, and only while the form still waits (`CHAIN_WAITS`): a service that
        refuses or finds nothing says so at once, and one that does not answer uses its whole wait up. `via`
        names the one service to ask, for trying a key out: nothing remembered answers for it.
        Raises LookupFailed: that the address was not found when any of them said so (it is what somebody at
        the form can do something about), else what the first one said."""
        services = (
            [service for service in self._services if service.maps.name == via]
            if via is not None
            else _in_turn(self._services, among)
        )
        if not services:
            raise LookupFailed("unreachable")
        key = (_plain(origin), _plain(destination))
        now = self._clock()
        if via is None:
            with self._lock:
                kept = self._kept.get(key)
                if (
                    kept is not None
                    and now - kept[0] < KEEP_SECONDS
                    and kept[1].service in {service.maps.name for service in services}
                ):
                    self._kept.move_to_end(key)
                    return kept[1]
        reasons: list[str] = []
        until = time.monotonic() + CHAIN_WAITS * self._wait
        for service in services:
            left = until - time.monotonic()
            if left <= 0:  # the form has stopped waiting: nobody else is asked, and nothing is counted
                break
            with self._lock:
                self._today(now)
                if service.asked >= service.daily:
                    service.last_failure = service.failing = "limit"
                    reasons.append("limit")
                    continue
                service.asked += 1
            try:
                ask = self._ask_of(service, "trip", origin, destination)
            except LookupFailed as err:  # its month has no room for the searches: it is not asked
                with self._lock:
                    service.asked = max(0, service.asked - 1)
                    service.last_failure = service.failing = err.reason
                reasons.append(err.reason)
                continue
            try:
                trip = replace(_within(min(self._wait, left), ask), service=service.maps.name)
            except LookupFailed as err:
                with self._lock:
                    service.failed += 1
                    service.last_failure = service.failing = err.reason
                reasons.append(err.reason)
                continue
            with self._lock:
                service.failing = None
            if may_keep(trip.service):  # the others' answers are used once and are gone
                with self._lock:
                    self._kept[key] = (now, trip)
                    self._kept.move_to_end(key)
                    while len(self._kept) > KEEP_MOST:
                        self._kept.popitem(last=False)
            return trip
        raise LookupFailed("not_found" if "not_found" in reasons else reasons[0] if reasons else "unreachable")

    def locate(self, address: str) -> tuple[float, float] | None:
        """Where an address stands (latitude, longitude), as the first service says that can be asked that
        and whose answers may be kept and given to anybody: Geocodio. For the restaurant's own address,
        which the list of addresses puts what is near first by (`pos.addresses`). Counted as one of the
        day's askings. None when the service reads the address as no place. Raises LookupFailed, also
        where there is no such service."""
        with self._lock:
            service = next(
                (
                    one
                    for one in self._services
                    if may_keep(one.maps.name) and callable(getattr(one.maps, "locate", None))
                ),
                None,
            )
            if service is None:
                raise LookupFailed("unreachable")
            self._today(self._clock())
            if service.asked >= service.daily:
                service.last_failure = service.failing = "limit"
                raise LookupFailed("limit")
            service.asked += 1
        try:
            found = _within(self._wait, lambda: service.maps.locate(address))
            with self._lock:
                service.failing = None
            return found
        except LookupFailed as err:
            with self._lock:
                service.failed += 1
                service.last_failure = service.failing = err.reason
            raise

    @property
    def traffic(self) -> str | None:
        """The name of the first service that knows the roads as they are right now, as they stand, or None
        where none does."""
        return self._traffics[0].maps.name if self._traffics else None

    @property
    def traffics(self) -> list[str]:
        """The services the hub has a key for that know the roads as they are right now, as they stand."""
        return [asked.maps.name for asked in self._traffics]

    def drive_ahead(
        self, origin: str, destination: str, *, among: Sequence[str] | None = None
    ) -> Callable[[], Driven | None]:
        """Starts asking how long the drive to a delivery's address is at this minute, and hands back the
        waiting for it. The asking runs beside the looking up of the distance, so a form hears of both
        inside the time it waits. The services `among` names are asked in its order, the next one only when
        the one before it gives nothing; each but the last is given half the wait at most, so the next one
        still has its turn. What the waiting gives is the minutes and who said them, or None: nobody here
        knows the roads right now, each was asked as often as it may be today, or no answer came in time.
        None is no failure to a form: the delivery is promised its usual minutes.

        The figure is never remembered and never written down: it is right for this minute alone, and the
        services' terms do not let it be kept."""
        turn = _in_turn(self._traffics, among)
        if not turn:
            return lambda: None
        box: list[Driven | Exception] = []
        asking: list[_Asked] = []  # the one that is being asked right now
        over: list[bool] = []  # the one who waited went away
        until = time.monotonic() + self._wait

        def run() -> None:
            for place, asked in enumerate(turn):
                left = until - time.monotonic()
                if left <= 0:
                    return
                with self._lock:
                    self._today(self._clock())
                    if asked.asked >= asked.daily:
                        asked.last_failure = asked.failing = "limit"
                        continue
                    asked.asked += 1
                try:
                    ask = self._ask_of(asked, "drive_now", origin, destination)
                except LookupFailed as err:  # its month has no room for the searches: it is not asked
                    with self._lock:
                        asked.asked = max(0, asked.asked - 1)
                        asked.last_failure = asked.failing = err.reason
                    continue
                asking[:] = [asked]
                try:
                    minutes = _within(left if place == len(turn) - 1 else min(left, self._wait / 2), ask)
                except LookupFailed as err:
                    with self._lock:
                        if not over:
                            asked.failed += 1
                            asked.last_failure = asked.failing = err.reason
                    continue
                except Exception as err:  # noqa: BLE001  handed to the one who waits, below
                    box.append(err)
                    return
                with self._lock:
                    asked.failing = None
                box.append(Driven(minutes, asked.maps.name))
                return
            asking.clear()

        thread = threading.Thread(target=run, name="maps-traffic", daemon=True)
        thread.start()

        def wait() -> Driven | None:
            thread.join(max(0.0, until - time.monotonic()))
            if not box:
                with self._lock:
                    if thread.is_alive() and not over:  # still asking: no answer came in time
                        over.append(True)
                        for asked in asking:
                            asked.failed += 1
                            asked.last_failure = asked.failing = "unreachable"
                return None
            told = box[0]
            if isinstance(told, Exception):
                raise told
            return told

        return wait

    def drive_soon(self, origin: str, destination: str) -> Callable[[], int | None]:
        """`drive_ahead` of every service that knows the roads, as they stand, and the minutes alone."""
        wait = self.drive_ahead(origin, destination)

        def minutes() -> int | None:
            driven = wait()
            return driven.minutes if driven is not None else None

        return minutes

    def standing(self, purpose: str, setting: Mapping[str, Any] | None = None) -> list[dict[str, Any]]:
        """Every service there is for a purpose (`distance` or `traffic`), in the order the location asks
        them, as a screen is told it: `name`, `title`, `credit` (the words its terms want beside its
        figures, or None), `on` (a manager has it turned on for that), `key` (the hub has a key for it),
        `asks` (both), and how today went with it: `asked_today`, `failed_today`, `daily_most`, `left`,
        `last_failure` and `failing` (why its last asking gave nothing, None once it answered again), the
        last four None where the hub has no key."""
        with self._lock:
            self._today(self._clock())
            have = {asked.maps.name: asked for asked in (self._traffics if purpose == "traffic" else self._services)}
            out = []
            for name in order_of(setting, purpose):
                asked = have.get(name)
                on = is_on(setting, purpose, name)
                out.append(
                    {
                        "name": name,
                        "title": TITLE.get(name, name),
                        "credit": CREDIT.get(name),
                        "on": on,
                        "key": asked is not None,
                        "asks": on and asked is not None,
                        "asked_today": asked.asked if asked is not None else 0,
                        "failed_today": asked.failed if asked is not None else 0,
                        "daily_most": asked.daily if asked is not None else None,
                        "left": max(0, asked.daily - asked.asked) if asked is not None else None,
                        "last_failure": asked.last_failure if asked is not None else None,
                        "failing": asked.failing if asked is not None else None,
                    }
                )
            return out

    def left(self, purpose: str, name: object) -> dict[str, Any]:
        """What a form shows beside a figure of that service: `title`, and how many of its day's lookups for
        that purpose are `left` of `daily_most`, both None where the hub has no key for it now."""
        with self._lock:
            self._today(self._clock())
            asked = next(
                (one for one in (self._traffics if purpose == "traffic" else self._services) if one.maps.name == name),
                None,
            )
            return {
                "title": TITLE.get(name, name) if isinstance(name, str) and name else None,
                "left": max(0, asked.daily - asked.asked) if asked is not None else None,
                "daily_most": asked.daily if asked is not None else None,
            }

    def status(self) -> dict[str, Any]:
        """For `hubctl maps status`: whether there is a service, and how today went: how often it was asked,
        how often it gave no distance, and how often a customer's own earlier order spared the asking;
        under `fallback` the same of the second service, or None where there is none, under `others` of the
        ones after those two (Mapbox, Azure Maps), and under `traffics` how often the drive right now was
        asked of each that knows it (`traffic` is the first of them, or None). No address is in it."""
        with self._lock:
            self._today(self._clock())
            usual = [asked for asked in self._services if not asked.other]
            head = usual[0] if usual else self._services[0] if self._services else None
            first = head.status() if head is not None else None
            roads = [asked.status() for asked in self._traffics]
            return {
                "configured": first is not None,
                "service": first["service"] if first else None,
                "asked_today": first["asked_today"] if first else 0,
                "failed_today": first["failed_today"] if first else 0,
                "saved_today": self._spared,
                "daily_most": first["daily_most"] if first else self._daily,
                "last_failure": first["last_failure"] if first else None,
                "fallback": usual[1].status() if len(usual) > 1 else None,
                "others": [asked.status() for asked in self._services if asked.other and asked is not head],
                "traffic": roads[0] if roads else None,
                "traffics": roads,
            }


def maps_from_env(environ: Mapping[str, str] | None = None) -> Maps | None:
    """`POS_MAPS_KEY` is the service's key and `POS_MAPS` names the service (`geocodio` unless set); None
    with no key, as on a laptop or a hub before `hubctl maps key`."""
    env = os.environ if environ is None else environ
    key = env.get("POS_MAPS_KEY", "").strip()
    if not key:
        return None
    service = (env.get("POS_MAPS", "") or "geocodio").strip().lower()
    if service != "geocodio":
        log.warning("map service %r is not built: no distance is looked up", service)
        return None
    return Geocodio(key, base=env.get("POS_MAPS_URL", "").strip() or GEOCODIO)


def fallback_from_env(environ: Mapping[str, str] | None = None) -> Maps | None:
    """`POS_MAPS_GOOGLE_KEY` is a Google Maps Platform key that may call the Routes API; None with no key,
    as on every hub before `hubctl maps google`."""
    env = os.environ if environ is None else environ
    key = env.get("POS_MAPS_GOOGLE_KEY", "").strip()
    return Google(key, base=env.get("POS_MAPS_GOOGLE_URL", "").strip() or GOOGLE) if key else None


def _most(env: Mapping[str, str], name: str, unless_set: int) -> int:
    try:
        return max(0, int(env.get(name, "") or unless_set))
    except ValueError:
        return unless_set


def others_from_env(environ: Mapping[str, str] | None = None) -> list[Maps]:
    """Mapbox and Azure Maps, each where the hub has its key (`pos.roads`): the keys the list of addresses
    asks them with."""
    from .roads import roads_from_env  # it reads this module

    return roads_from_env(environ)


def lookups_from_env(environ: Mapping[str, str] | None = None) -> Lookups:
    """The hub's services as its own file names them. With Google's key alone, Google is the one service."""
    env = os.environ if environ is None else environ
    return Lookups(
        maps_from_env(env),
        fallback=fallback_from_env(env),
        others=others_from_env(env),
        daily=_most(env, "POS_MAPS_DAILY", DAILY_MOST),
        fallback_daily=_most(env, "POS_MAPS_GOOGLE_DAILY", FALLBACK_DAILY_MOST),
        traffic_daily=_most(env, "POS_MAPS_TRAFFIC_DAILY", TRAFFIC_DAILY_MOST),
        other_daily={
            name: _most(env, f"POS_MAPS_{name.upper()}_ROUTES_DAILY", most) for name, most in OTHER_DAILY_MOST.items()
        },
        other_traffic_daily={
            name: _most(env, f"POS_MAPS_{name.upper()}_TRAFFIC_DAILY", most)
            for name, most in OTHER_TRAFFIC_DAILY_MOST.items()
        },
    )


__all__ = [
    "ADDRESS_MAX",
    "ORDER",
    "PURPOSES",
    "TITLE",
    "TRAFFIC_ORDER",
    "Driven",
    "Geocodio",
    "Google",
    "LookupFailed",
    "Lookups",
    "Maps",
    "Trip",
    "credit_of",
    "fallback_from_env",
    "is_on",
    "lookups_from_env",
    "maps_from_env",
    "may_keep",
    "order_of",
    "origin_mark",
    "others_from_env",
    "same_address",
    "miles_text",
    "trip_of",
    "turned_on",
]
