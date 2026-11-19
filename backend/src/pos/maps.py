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
"""

from __future__ import annotations

import hashlib
import logging
import os
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Mapping
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
KEEP_SECONDS = 24 * 3600
KEEP_MOST = 500
DAILY_MOST = 500
FALLBACK_DAILY_MOST = 100
"""The most the second service is asked in a day unless set: about 3,000 a month, inside what Google's
price list gave away each month when this was written (10,000 plain routes)."""
TRAFFIC_DAILY_MOST = 150
"""The most the drive right now is asked in a day unless set: about 4,650 a month, inside what Google's
price list gave away each month when this was written (5,000 routes with traffic)."""
METERS_A_MILE = Decimal("1609.344")
TENTH = Decimal("0.1")
MILES_MOST = Decimal(1000)
"""An answer further than this is no delivery: the address was read as one somewhere else."""

GEOCODIO = "https://api.geocod.io/v2.1"
GOOGLE = "https://routes.googleapis.com"

NOT_KEPT = frozenset({"google"})
"""The services whose terms do not let a distance or a drive time be kept. Google's (the Routes API's
policies and the Google Maps Platform Service Specific Terms, read 2026-11-18) allow place IDs to be kept,
and coordinates for thirty days, and nothing else of an answer."""
CREDIT = {"google": "Google Maps"}
"""What a service's terms want shown beside its figures, in these exact words."""

SAID = {
    "not_found": "The map service could not find that address. Check it, or pick the fee by hand.",
    "unreachable": "The map service is not answering. Pick the fee by hand.",
    "refused": "The map service refused the hub's key. Pick the fee by hand, and tell the owner.",
    "limit": "The map service has been asked as often as it may be today. Pick the fee by hand.",
}


@dataclass(frozen=True)
class Trip:
    """A drive from the restaurant to a delivery's address."""

    miles: Decimal  # along the road, to a tenth
    minutes: int  # the usual drive, to the nearest minute and never less than one
    service: str = field(default="", compare=False)  # who measured it, once `Lookups` knows

    def as_json(self) -> dict[str, Any]:
        return {"miles": format(self.miles, "f"), "minutes": self.minutes}


def may_keep(service: object) -> bool:
    """Whether a distance this service measured may be kept: on the order, and in the hub's memory for the
    day. Figures that do not say who measured them may not: nobody can tell whose terms they fall under."""
    return isinstance(service, str) and bool(service) and service not in NOT_KEPT


def credit_of(service: object) -> str | None:
    """The words a service's terms want beside its figures on a screen, or None."""
    return CREDIT.get(service) if isinstance(service, str) else None


class LookupFailed(Exception):
    """A lookup that gave no distance. `reason` is one of `SAID`; the message is for whoever takes the order."""

    def __init__(self, reason: str) -> None:
        super().__init__(SAID[reason])
        self.reason = reason


class Maps(Protocol):
    name: str

    def trip(self, origin: str, destination: str) -> Trip:
        """The drive from one address to the other. Raises LookupFailed."""
        ...


def trip_of(miles: Any, seconds: Any) -> Trip | None:
    """A service's two numbers, read: road miles to a tenth and the drive in whole minutes. None when
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
    return Trip(miles=far.quantize(TENTH, rounding=ROUND_HALF_UP), minutes=max(1, minutes))


class _NoAddresses(logging.Filter):
    """httpx logs the address of every request it makes, and a lookup's holds two street addresses."""

    def __init__(self, host: str) -> None:
        super().__init__()
        self._host = host

    def filter(self, record: logging.LogRecord) -> bool:
        return not any(isinstance(arg, httpx.URL) and arg.host == self._host for arg in record.args or ())


class Geocodio:
    """Geocodio's distance call (https://www.geocod.io/docs/): one origin, one destination, by road."""

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


def _within(seconds: float, ask: Callable[[], Trip]) -> Trip:
    """What `ask` answers, or LookupFailed("unreachable") when it has not answered in `seconds`. A request's
    own timeout bounds each of its steps, not their sum, and not the looking up of the service's name; the
    form waits only so long. The asking goes on behind, and what it answers then is dropped."""
    box: list[Trip | Exception] = []

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

    def status(self) -> dict[str, Any]:
        return {
            "service": self.maps.name,
            "asked_today": self.asked,
            "failed_today": self.failed,
            "daily_most": self.daily,
            "last_failure": self.last_failure,
        }


class Lookups:
    """The hub's lookups: the service when there is one, a second one for when the first gives nothing,
    each answer that may be kept remembered for a day, and neither asked more in a day than the owner
    would expect to pay for."""

    def __init__(
        self,
        maps: Maps | None = None,
        *,
        fallback: Maps | None = None,
        daily: int = DAILY_MOST,
        fallback_daily: int = FALLBACK_DAILY_MOST,
        traffic_daily: int = TRAFFIC_DAILY_MOST,
        wait: float = TIMEOUT_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        asked = [(maps, daily), (fallback, fallback_daily)]
        self._services = [_Asked(service, most) for service, most in asked if service is not None]
        # the one that knows the roads as they are right now, when there is one, counted by itself
        knows = [service.maps for service in self._services if callable(getattr(service.maps, "drive_now", None))]
        self._traffic = _Asked(knows[0], traffic_daily) if knows else None
        self._daily = daily
        self._wait = wait
        self._clock = clock
        self._lock = threading.Lock()
        self._kept: OrderedDict[tuple[str, str], tuple[float, Trip]] = OrderedDict()
        self._day = 0
        self._spared = 0

    @property
    def ready(self) -> bool:
        """Whether there is a service to ask."""
        return bool(self._services)

    @property
    def names(self) -> list[str]:
        """The services in the order they are asked: the first, then the one for when it gives nothing."""
        return [service.maps.name for service in self._services]

    def _today(self, now: float) -> None:
        """Starts the day's counts over when the day has turned. Called with the lock held."""
        day = int(now // 86400)
        if day != self._day:
            self._day, self._spared = day, 0
            for service in (*self._services, self._traffic):
                if service is not None:
                    service.asked, service.failed = 0, 0

    def spared(self) -> None:
        """A distance was read off a customer's own earlier order, and nobody was asked: counted, so
        `hubctl maps status` can say how often."""
        with self._lock:
            self._today(self._clock())
            self._spared += 1

    def trip(self, origin: str, destination: str, *, via: str | None = None) -> Trip:
        """The drive from the restaurant to a delivery's address, and who measured it (`Trip.service`). The
        first service is asked, and the second only when the first gives no distance, whatever its reason.
        `via` names the one service to ask, for trying a key out: nothing remembered answers for it.
        Raises LookupFailed: that the address was not found when any of them said so (it is what somebody at
        the form can do something about), else what the first one said."""
        services = [service for service in self._services if via is None or service.maps.name == via]
        if not services:
            raise LookupFailed("unreachable")
        key = (_plain(origin), _plain(destination))
        now = self._clock()
        if via is None:
            with self._lock:
                kept = self._kept.get(key)
                if kept is not None and now - kept[0] < KEEP_SECONDS:
                    self._kept.move_to_end(key)
                    return kept[1]
        reasons: list[str] = []
        for service in services:
            with self._lock:
                self._today(now)
                if service.asked >= service.daily:
                    service.last_failure = "limit"
                    reasons.append("limit")
                    continue
                service.asked += 1
            try:
                told = _within(self._wait, lambda maps=service.maps: maps.trip(origin, destination))
                trip = replace(told, service=service.maps.name)
            except LookupFailed as err:
                with self._lock:
                    service.failed += 1
                    service.last_failure = err.reason
                reasons.append(err.reason)
                continue
            if may_keep(trip.service):  # the others' answers are used once and are gone
                with self._lock:
                    self._kept[key] = (now, trip)
                    self._kept.move_to_end(key)
                    while len(self._kept) > KEEP_MOST:
                        self._kept.popitem(last=False)
            return trip
        raise LookupFailed("not_found" if "not_found" in reasons else reasons[0])

    @property
    def traffic(self) -> str | None:
        """The name of the service that knows the roads as they are right now, or None where none does."""
        return self._traffic.maps.name if self._traffic is not None else None

    def drive_soon(self, origin: str, destination: str) -> Callable[[], int | None]:
        """Starts asking how long the drive to a delivery's address is at this minute, and hands back the
        waiting for it. The asking runs beside the looking up of the distance, so a form hears of both
        inside the time it waits. What the waiting gives is the minutes, or None: nobody here knows the
        roads right now, it was asked as often as it may be today, or no answer came in time. None is no
        failure to a form: the delivery is promised its usual minutes.

        The figure is never remembered and never written down: it is right for this minute alone, and the
        service's terms do not let it be kept."""
        asked = self._traffic
        if asked is None:
            return lambda: None
        with self._lock:
            self._today(self._clock())
            if asked.asked >= asked.daily:
                asked.last_failure = "limit"
                return lambda: None
            asked.asked += 1
        box: list[int | Exception] = []

        def run() -> None:
            try:
                box.append(asked.maps.drive_now(origin, destination))  # type: ignore[attr-defined]
            except Exception as err:  # noqa: BLE001  handed to the one who waits, below
                box.append(err)

        thread = threading.Thread(target=run, name="maps-traffic", daemon=True)
        thread.start()
        until = time.monotonic() + self._wait

        def wait() -> int | None:
            thread.join(max(0.0, until - time.monotonic()))
            told = box[0] if box else LookupFailed("unreachable")
            if isinstance(told, LookupFailed):
                with self._lock:
                    asked.failed += 1
                    asked.last_failure = told.reason
                return None
            if isinstance(told, Exception):
                raise told
            return told

        return wait

    def status(self) -> dict[str, Any]:
        """For `hubctl maps status`: whether there is a service, and how today went: how often it was asked,
        how often it gave no distance, and how often a customer's own earlier order spared the asking;
        under `fallback` the same of the second service, or None where there is none, and under `traffic` how
        often the drive right now was asked, or None where nobody here knows it. No address is in it."""
        with self._lock:
            self._today(self._clock())
            first = self._services[0].status() if self._services else None
            return {
                "configured": first is not None,
                "service": first["service"] if first else None,
                "asked_today": first["asked_today"] if first else 0,
                "failed_today": first["failed_today"] if first else 0,
                "saved_today": self._spared,
                "daily_most": first["daily_most"] if first else self._daily,
                "last_failure": first["last_failure"] if first else None,
                "fallback": self._services[1].status() if len(self._services) > 1 else None,
                "traffic": self._traffic.status() if self._traffic is not None else None,
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


def lookups_from_env(environ: Mapping[str, str] | None = None) -> Lookups:
    """The hub's services as its own file names them. With Google's key alone, Google is the one service."""
    env = os.environ if environ is None else environ
    return Lookups(
        maps_from_env(env),
        fallback=fallback_from_env(env),
        daily=_most(env, "POS_MAPS_DAILY", DAILY_MOST),
        fallback_daily=_most(env, "POS_MAPS_GOOGLE_DAILY", FALLBACK_DAILY_MOST),
        traffic_daily=_most(env, "POS_MAPS_TRAFFIC_DAILY", TRAFFIC_DAILY_MOST),
    )


__all__ = [
    "ADDRESS_MAX",
    "Geocodio",
    "Google",
    "LookupFailed",
    "Lookups",
    "Maps",
    "Trip",
    "credit_of",
    "fallback_from_env",
    "lookups_from_env",
    "maps_from_env",
    "may_keep",
    "origin_mark",
    "same_address",
    "trip_of",
]
