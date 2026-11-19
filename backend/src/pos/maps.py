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
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any, Protocol

import httpx

log = logging.getLogger("pos.maps")

ADDRESS_MAX = 200
"""As long as an order's own address may be."""
TIMEOUT_SECONDS = 6.0
"""How long somebody on the phone with a customer is kept waiting, at most."""
KEEP_SECONDS = 24 * 3600
KEEP_MOST = 500
DAILY_MOST = 500
TENTH = Decimal("0.1")
MILES_MOST = Decimal(1000)
"""An answer further than this is no delivery: the address was read as one somewhere else."""

GEOCODIO = "https://api.geocod.io/v2.1"

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

    def as_json(self) -> dict[str, Any]:
        return {"miles": format(self.miles, "f"), "minutes": self.minutes}


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


class Lookups:
    """The hub's lookups: the service when there is one, each answer remembered for a day, and no more
    asked in a day than the owner would expect to pay for."""

    def __init__(
        self,
        maps: Maps | None = None,
        *,
        daily: int = DAILY_MOST,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._maps = maps
        self._daily = daily
        self._clock = clock
        self._lock = threading.Lock()
        self._kept: OrderedDict[tuple[str, str], tuple[float, Trip]] = OrderedDict()
        self._day = 0
        self._asked = 0
        self._failed = 0
        self._last_failure: str | None = None

    @property
    def ready(self) -> bool:
        """Whether there is a service to ask."""
        return self._maps is not None

    def trip(self, origin: str, destination: str) -> Trip:
        """The drive from the restaurant to a delivery's address. Raises LookupFailed."""
        maps = self._maps
        if maps is None:
            raise LookupFailed("unreachable")
        key = (_plain(origin), _plain(destination))
        now = self._clock()
        with self._lock:
            kept = self._kept.get(key)
            if kept is not None and now - kept[0] < KEEP_SECONDS:
                self._kept.move_to_end(key)
                return kept[1]
            day = int(now // 86400)
            if day != self._day:
                self._day, self._asked, self._failed = day, 0, 0
            if self._asked >= self._daily:
                self._last_failure = "limit"
                raise LookupFailed("limit")
            self._asked += 1
        try:
            trip = maps.trip(origin, destination)
        except LookupFailed as err:
            with self._lock:
                self._failed += 1
                self._last_failure = err.reason
            raise
        with self._lock:
            self._kept[key] = (now, trip)
            self._kept.move_to_end(key)
            while len(self._kept) > KEEP_MOST:
                self._kept.popitem(last=False)
        return trip

    def status(self) -> dict[str, Any]:
        """For `hubctl maps status`: whether there is a service, and how today went. No address is in it."""
        with self._lock:
            return {
                "configured": self._maps is not None,
                "service": self._maps.name if self._maps is not None else None,
                "asked_today": self._asked,
                "failed_today": self._failed,
                "daily_most": self._daily,
                "last_failure": self._last_failure,
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


def lookups_from_env(environ: Mapping[str, str] | None = None) -> Lookups:
    env = os.environ if environ is None else environ
    try:
        daily = int(env.get("POS_MAPS_DAILY", "") or DAILY_MOST)
    except ValueError:
        daily = DAILY_MOST
    return Lookups(maps_from_env(env), daily=max(0, daily))


__all__ = [
    "ADDRESS_MAX",
    "Geocodio",
    "LookupFailed",
    "Lookups",
    "Maps",
    "Trip",
    "lookups_from_env",
    "maps_from_env",
    "trip_of",
]
