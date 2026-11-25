"""The drive as Mapbox and Azure Maps say it (docs/delivery.md, "Which service is asked first").

The hub asks how far a delivery goes and how long the drive is right now (`pos.maps`). Geocodio and Google
are asked that of two addresses. Mapbox and Azure Maps are asked it of two places on the map, so each first
finds where the delivery's address stands with its own search, and where the restaurant stands too when
the hub does not tell it (`Lookups.start_of`: Geocodio's answer, which may be kept and given to anybody).
Nothing either of them says is kept here: not the places, and not the figures (`pos.maps.NOT_KEPT`).

They are asked with the keys the list of addresses uses (`POS_MAPS_MAPBOX_KEY`, `POS_MAPS_AZURE_KEY`), and
only where a manager turned them on for it (`drive_lookups` in pos.settings). Their searches are counted
against the same month's free amount as the list's (`Lookups.count_with`), so asking them here cannot run
up a bill there.

Mapbox: the Directions API (https://docs.mapbox.com/api/navigation/directions/, read 2026-11-25),
`GET /directions/v5/{profile}/{longitude},{latitude};{longitude},{latitude}` with the token in the address
of the request. `mapbox/driving` for the usual drive; `mapbox/driving-traffic` for the drive right now,
whose `duration` "is a prediction for travel time based on historical travel data and live traffic". The
places come from its Geocoding API, version 6 (forward, no autocomplete, one answer).

Azure Maps: Route Directions (https://learn.microsoft.com/rest/api/maps/route/post-route-directions,
version 2025-01-01, read 2026-11-25), `POST /route/directions` with the two places as GeoJSON points,
longitude first, and the key in a header. `optimizeRoute` is `fastestWithoutTraffic` for the usual drive
and `fastestWithTraffic` for the drive right now; the totals stand in the feature whose `type` is
`RoutePath`: `distanceInMeters`, `durationInSeconds`, and `durationTrafficInSeconds`, the time "with
current traffic conditions". The places come from its Get Geocoding.

Neither was ever called for real from here: both are written from their own pages and tried against
stand-ins. `hubctl maps test mapbox "<address>"` (or `azure`), or the first delivery after one is turned
on, is its first real asking.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from decimal import Decimal
from typing import Any

import httpx

from .addresses import AZURE, AZURE_VERSION, MAPBOX, _answered, _features, _point, _quiet
from .maps import METERS_A_MILE, TIMEOUT_SECONDS, LookupFailed, Maps, Trip, trip_of

ROUTE_VERSION = "2025-01-01"
"""The version of Azure Maps' Route Directions this was written from."""
ASKED = "the map service asked the drive"
"""What the log calls an asking from here."""
STEP_SECONDS = TIMEOUT_SECONDS / 2
"""How long one request of a lookup is waited for: a lookup is two or three of them, one after the other,
and the form waits only so long for all of it."""

Place = tuple[float, float]
"""Latitude, then longitude."""


def _minutes(seconds: Any) -> int | None:
    """A drive's seconds in whole minutes and never less than one; None for what is no such number."""
    trip = trip_of(0, seconds)
    return trip.minutes if trip is not None else None


def _trip(meters: Any, seconds: Any) -> Trip | None:
    """A route's length in meters and its time in seconds, read; None when either is no such number."""
    if isinstance(meters, bool) or not isinstance(meters, int | float):
        return None
    return trip_of(Decimal(str(meters)) / METERS_A_MILE, seconds)


def _spot(feature: Mapping[str, Any]) -> Place | None:
    """Where a GeoJSON feature's point stands; it says longitude first."""
    held = feature.get("geometry")
    pair = held.get("coordinates") if isinstance(held, Mapping) else None
    return _point(pair[1], pair[0]) if isinstance(pair, list) and len(pair) >= 2 else None


class MapboxRoads:
    """Mapbox, asked the drive: where the delivery's address stands (one search, or two with the
    restaurant's), then the route between the two places. The token and the places go in the address of each
    request, so httpx's own line about them is kept out of the log."""

    name = "mapbox"

    def __init__(self, token: str, *, base: str = MAPBOX, client: httpx.Client | None = None) -> None:
        self._token = token
        self._base = base.rstrip("/")
        self._client = client if client is not None else httpx.Client(timeout=STEP_SECONDS)
        _quiet(self._base)

    @staticmethod
    def searches(told: bool) -> int:
        """How many searches one lookup makes, as the list's month counts them: one for the delivery's
        address, and one more for the restaurant's where the hub does not say where it stands."""
        return 1 if told else 2

    def _stands(self, address: str, near: Place | None = None) -> Place:
        """Where an address stands, as its first answer says; what is near `near` first. Raises LookupFailed,
        `not_found` for an address it reads as no place."""
        asked = {
            "q": address.replace(";", " "),  # a semicolon would make two askings of one
            "autocomplete": "false",
            "country": "us",
            "language": "en",
            "limit": "1",
            "access_token": self._token,
        }
        if near is not None:
            asked["proximity"] = f"{near[1]},{near[0]}"
        data = _answered(
            lambda: self._client.get(f"{self._base}/search/geocode/v6/forward", params=asked),
            who=self.name,
            what=ASKED,
            nothing=(404, 422),
        )
        for feature in _features(data):
            spot = _spot(feature)
            if spot is not None:
                return spot
            break
        raise LookupFailed("not_found")

    def _route(self, profile: str, origin: str, destination: str, start: Place | None) -> Mapping[str, Any]:
        """The first route by car between the two addresses, with its `distance` in meters and its
        `duration` in seconds. Raises LookupFailed."""
        here = start if start is not None else self._stands(origin)
        there = self._stands(destination, near=here)
        way = f"{here[1]:.6f},{here[0]:.6f};{there[1]:.6f},{there[0]:.6f}"
        data = _answered(
            lambda: self._client.get(
                f"{self._base}/directions/v5/mapbox/{profile}/{way}",
                params={"alternatives": "false", "overview": "false", "steps": "false", "access_token": self._token},
            ),
            who=self.name,
            what=ASKED,
            nothing=(404, 422),
        )
        routes = data.get("routes")
        first = routes[0] if isinstance(routes, list) and routes and isinstance(routes[0], Mapping) else None
        if data.get("code") not in (None, "Ok") or first is None:  # no road between the two, or none near one
            raise LookupFailed("not_found")
        return first

    def trip(self, origin: str, destination: str, start: Place | None = None) -> Trip:
        """The usual drive from the restaurant to a delivery's address. Raises LookupFailed."""
        route = self._route("driving", origin, destination, start)
        trip = _trip(route.get("distance"), route.get("duration"))
        if trip is None:
            raise LookupFailed("not_found")
        return trip

    def drive_now(self, origin: str, destination: str, start: Place | None = None) -> int:
        """The minutes of the drive as the roads are at this minute. Raises LookupFailed."""
        minutes = _minutes(self._route("driving-traffic", origin, destination, start).get("duration"))
        if minutes is None:
            raise LookupFailed("not_found")
        return minutes


class AzureRoads:
    """Azure Maps, asked the drive: where the delivery's address stands (one search, or two with the
    restaurant's), then the route between the two places. The key goes in a header and the places in the
    body; the address searched for goes in the address of its request, so httpx's own line about it is
    kept out of the log."""

    name = "azure"

    def __init__(self, key: str, *, base: str = AZURE, client: httpx.Client | None = None) -> None:
        self._key = key
        self._base = base.rstrip("/")
        self._client = client if client is not None else httpx.Client(timeout=STEP_SECONDS)
        _quiet(self._base)

    @staticmethod
    def searches(told: bool) -> int:
        """How many searches one lookup makes, as the list's month counts them: each is one transaction of
        its Search, which ten askings for a list come to."""
        return 10 if told else 20

    def _stands(self, address: str) -> Place:
        """Where an address stands, as its first answer says. Raises LookupFailed, `not_found` for an address
        it reads as no place."""
        data = _answered(
            lambda: self._client.get(
                f"{self._base}/geocode",
                params={"api-version": AZURE_VERSION, "query": address, "top": "1"},
                headers={"subscription-key": self._key, "Accept-Language": "en-US"},
            ),
            who=self.name,
            what=ASKED,
        )
        for feature in _features(data):
            spot = _spot(feature)
            if spot is not None:
                return spot
            break
        raise LookupFailed("not_found")

    def _route(self, how: str, origin: str, destination: str, start: Place | None) -> Mapping[str, Any]:
        """What is said of the first route by car between the two addresses: its `distanceInMeters`, its
        `durationInSeconds` and, asked with traffic, its `durationTrafficInSeconds`. Raises LookupFailed."""
        here = start if start is not None else self._stands(origin)
        there = self._stands(destination)
        asked = {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [place[1], place[0]]},
                    "properties": {"pointIndex": index, "pointType": "waypoint"},
                }
                for index, place in enumerate((here, there))
            ],
            "travelMode": "driving",
            "optimizeRoute": how,
            "routeOutputOptions": ["routePath"],
            "maxRouteCount": 1,
        }
        data = _answered(
            lambda: self._client.post(
                f"{self._base}/route/directions",
                params={"api-version": ROUTE_VERSION},
                content=json.dumps(asked),
                headers={"subscription-key": self._key, "Content-Type": "application/geo+json"},
            ),
            who=self.name,
            what=ASKED,
            nothing=(400, 404),  # two places it finds no road between
        )
        for feature in _features(data):
            told = feature.get("properties")
            if isinstance(told, Mapping) and told.get("type") == "RoutePath":
                return told
        raise LookupFailed("not_found")

    def trip(self, origin: str, destination: str, start: Place | None = None) -> Trip:
        """The usual drive from the restaurant to a delivery's address. Raises LookupFailed."""
        route = self._route("fastestWithoutTraffic", origin, destination, start)
        trip = _trip(route.get("distanceInMeters"), route.get("durationInSeconds"))
        if trip is None:
            raise LookupFailed("not_found")
        return trip

    def drive_now(self, origin: str, destination: str, start: Place | None = None) -> int:
        """The minutes of the drive as the roads are at this minute. Raises LookupFailed."""
        route = self._route("fastestWithTraffic", origin, destination, start)
        minutes = _minutes(route.get("durationTrafficInSeconds"))
        if minutes is None:
            raise LookupFailed("not_found")
        return minutes


def roads_from_env(environ: Mapping[str, str] | None = None) -> list[Maps]:
    """Mapbox and Azure Maps for the drive, each where the hub has its key: the keys the list of addresses
    asks them with (`POS_MAPS_MAPBOX_KEY`, `POS_MAPS_AZURE_KEY`)."""
    env = os.environ if environ is None else environ
    made: list[Maps] = []
    token = env.get("POS_MAPS_MAPBOX_KEY", "").strip()
    if token:
        made.append(MapboxRoads(token, base=env.get("POS_MAPS_MAPBOX_URL", "").strip() or MAPBOX))
    key = env.get("POS_MAPS_AZURE_KEY", "").strip()
    if key:
        made.append(AzureRoads(key, base=env.get("POS_MAPS_AZURE_URL", "").strip() or AZURE))
    return made


__all__ = ["AzureRoads", "MapboxRoads", "roads_from_env"]
