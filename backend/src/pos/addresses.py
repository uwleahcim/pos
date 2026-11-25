"""A list of addresses while one is being typed (docs/delivery.md, "A list of addresses while typing").

Wherever a screen asks for a street address, the hub is asked what the letters typed so far could become,
and the screen lists the answers under the box. A tap puts one in. Nothing is put in a box by itself: a
list is a help, and what was typed stands until somebody taps.

The answers come from two places.

The restaurant's own deliveries come first. The customer on the phone had deliveries brought somewhere
before (`own_addresses`, read off their own newest orders, like their card), and other deliveries of the
past year went to addresses that start the same way (`AddressBook`, read off the orders that carry a
number, each remembered while its log stands). Those cost nothing and ask nobody outside the building. An
address from another customer's order is listed as an address and nothing else: no name, no number.

Map services come second, and only where a manager turned one on (`address_list` in the settings, each
off until then). There are three, and they are asked in this order (`ORDER`):

- Google's Places API (New), Autocomplete, with the key the hub has for Google Maps (`POS_MAPS_GOOGLE_KEY`;
  the key has to be allowed to call Places API (New)).
- Mapbox's Geocoding API, version 6, with a token of its own (`POS_MAPS_MAPBOX_KEY`). Mapbox's Address
  Autofill is a kit for web pages and has no call a hub could make; this is the call of Mapbox's that lists
  addresses as they are typed and that a server may make.
- Azure Maps' Geocode Autocomplete, with a key of its own (`POS_MAPS_AZURE_KEY`).

One of them answers a list, never two. The first that is turned on and has a key is asked, and the next one
only when the one before it gave no answer: its free amount for the month is used up (below), it did not
answer in time, or it refused the key. That is what the others are for: they take over once the first one's
free amount is used up, and while it is down (the owner's words, 2026-11-25). A service that answers with an
empty list has answered, and nobody else is asked about the same letters. A service that just gave no
answer is left alone for a while (`REST`), so that somebody typing does not wait for it again at every
letter; all of them together are waited for no longer than a form waits for the hub (`CHAIN_SECONDS`).

Whichever is asked is sent the letters typed, and nothing else of the order: no name, no phone number. The
key goes in a header and the letters in the body where the service takes them there (Google, and Azure
Maps' key); Mapbox takes both in the address of the request alone, so nothing of any of these requests is
logged, and the hub's log names no address and no key. What a service answers is shown and then gone:
nothing of it is remembered or written down (their terms keep answers out of any store), and its name
stands under a list that holds one of its answers (`credit_of`). An address somebody tapped is the
customer's own address, typed with fewer letters, and goes on the order like one typed in full.

Where the restaurant stands is asked of Google and of Azure Maps once, each of its own (`locate`): the
restaurant's own address as that service reads it, as coordinates, kept in the hub's memory for under thirty
days and never written down, as their terms allow. Until it is known Google goes by where the hub's own
internet connection is, and Azure Maps by the whole country. Mapbox's terms do not let an answer be kept at
all, so it is never asked where the restaurant stands. It is told what Geocodio says, the service the hub
measures a delivery's distance with, whose terms let an answer be kept and used with anybody's map
(`Suggester.place_with`, `pos.maps.Lookups.locate`); on a hub with no key for Geocodio it goes by the hub's
internet connection.

What is near comes first (the owner's words, 2026-11-25: deliveries go four miles as a rule, further for a
big order): `near_miles` of the setting, four unless a manager sets it. Google is told that distance as a
circle around the restaurant, a preference and no wall; Mapbox and Azure Maps take the place alone and put
what is nearest to it first.

Each service gives so many askings away each month, and the hub asks it no more often than that
(`MONTHLY_MOST`), so the list never costs anything and a screen gone wrong cannot run up a bill: of Google
9,500 (its price list gave 10,000 away each month when this was written), of Mapbox 95,000 (of 100,000)
and of Azure Maps 47,500 (of the 50,000 that its 5,000 free transactions come to at ten askings each). The
twentieth part is left over because the hub's month and a service's own do not turn at the same hour, and
because the hub counts only what it asked itself. How often each was asked this month is counted in the
database (`Asked`), so a hub that restarts goes on counting where it stopped and two hubs count as one. A
screen is told who answered its list and how many askings that service has left for the month
(`Suggester.left`), and shows it small, under the list. Past a service's month the next one is asked, and
past the last one, and whenever none answers in time, the list holds the restaurant's own addresses alone.
A list never fails a form.
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from collections.abc import Callable, Collection, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Protocol
from zoneinfo import ZoneInfo

import httpx
from psycopg.rows import tuple_row
from psycopg_pool import ConnectionPool

from .maps import ADDRESS_MAX, LookupFailed, _plain
from .orders.sales import OrderMemo
from .sync.oplog import OrderEntry, OrderState, is_delivery, phone_digits

log = logging.getLogger("pos.addresses")

PLACES = "https://places.googleapis.com"
MAPBOX = "https://api.mapbox.com"
AZURE = "https://atlas.microsoft.com"
AZURE_VERSION = "2026-01-01"
"""The version of Azure Maps' Search calls the hub speaks: the one Geocode Autocomplete became general in."""
SERVICE = "google"
"""The name of the map service that is asked first, as `pos.maps` names it."""
ORDER = ("google", "mapbox", "azure")
"""The map services that list addresses, in the order they are asked: each one after the first only when the
one before it gave no answer."""
TITLE = {"google": "Google Maps", "mapbox": "Mapbox", "azure": "Azure Maps"}
"""What a screen calls each service."""
WHO = {"google": "Google", "mapbox": "Mapbox", "azure": "Azure Maps"}
"""Each service in a sentence."""
CREDIT = {"google": "Google Maps", "mapbox": "\u00a9 Mapbox \u00a9 OpenStreetMap", "azure": "Azure Maps"}
"""What stands under a list that holds one of a service's answers: Google's terms want these exact words,
and Mapbox's attribution names it and the map its data is drawn from."""
OWN_MOST = 3
"""How many of the restaurant's own addresses lead a list that the map service adds to."""
LIST_MOST = 6
"""How long a list is at most: a phone shows it under the box, over the keyboard."""
TYPED_FROM = 2
"""Letters typed before the restaurant's own addresses are listed."""
ASK_FROM = 4
"""Letters typed before the map service is asked: "12 E" says little, and every asking is counted."""
SUGGEST_SECONDS = 2.0
"""How long one service is waited for. Somebody is typing: a list that comes later than that is in the way."""
CHAIN_SECONDS = 3.5
"""How long the services are waited for one after the other, in all: a form waits four seconds for the hub."""
FREE = {"google": 10_000, "mapbox": 100_000, "azure": 50_000}
"""The askings each service gave away each month when this was written (2026-11-25): Google's Places API
(New), Autocomplete Requests, 10,000; Mapbox's temporary Geocoding API, 100,000 requests; Azure Maps'
Search, 5,000 transactions, of which ten askings of Geocode Autocomplete make one."""
MONTHLY_MOST = {name: free * 95 // 100 for name, free in FREE.items()}
"""The most each service is asked in a month unless the hub's file says otherwise (`MONTHLY_ENV`): its free
amount but for a twentieth, which is what the hub's count and the service's own may differ by."""
MONTHLY_ENV = {
    "google": "POS_MAPS_SUGGEST_MONTHLY",
    "mapbox": "POS_MAPS_MAPBOX_MONTHLY",
    "azure": "POS_MAPS_AZURE_MONTHLY",
}
MONTH_BY = ZoneInfo("America/Los_Angeles")
"""Whose midnight turns the hub's month: Google's bills go by Pacific time, the latest of the three."""
REST = {"unreachable": 60.0, "refused": 300.0, "limit": 300.0}
"""After a service gave no answer, the seconds it is left alone and the next one is asked in its place: a
minute when it did not answer, five when it refused the key or said itself that it is asked too often.
Trying it out (Location, Address list) asks it all the same, and an answer ends the rest."""
MAP_MOST = 5
"""How many addresses a service is asked for: a list holds six at most, the restaurant's own among them."""
LOOK_BACK_DAYS = 400
"""How far back deliveries are read for their addresses: the year the guest list reads, and a month."""
BOOK_MOST = 5000
"""The most addresses the book holds, the newest deliveries first."""
BOOK_SECONDS = 60.0
"""How long the book stands before the orders are read again: a delivery taken now is listed a minute on."""
BOOK_BUDGET = 0.25
"""The most seconds one asking spends reading old orders. A hub that just started reads a year of them a
part at a time, the newest first, and lists what it has read so far."""
METERS_A_MILE = 1609.344
CIRCLE_MOST_METERS = 50_000.0
"""The widest circle Google takes."""
NEAR_METERS = 4 * METERS_A_MILE
"""How far around the restaurant addresses come first where nobody says (`reach`): four miles, as far as
the restaurant this was built for usually delivers (the owner's words, 2026-11-25). A manager sets it under
Location, Address list (`near_miles` of the setting). It is a preference and no wall: an address further
out is still listed when the letters fit it. Google is told the distance as a circle (50 km is the widest
it takes); Mapbox and Azure Maps take the place alone and put what is nearest to it first."""
NEAR_SECONDS = 25 * 86400.0
"""How long the restaurant's coordinates stand in memory: under the thirty days the service's terms allow."""
NEAR_AGAIN = 3600.0
"""After the coordinates could not be had, how long until they are asked for again."""
KINDS = ("street_address", "premise", "subpremise", "route")
"""What Google is asked to list: addresses and streets, no shops and no towns."""
MAPBOX_KINDS = ("address", "street")
"""The same of Mapbox, in its words."""
US_BOX = "-179.9,18.9,-66.9,71.4"
"""The whole country, as Azure Maps is told it (west, south, east, north) until it is known where the
restaurant stands: that service wants to be told a place or a box with every asking."""
_LOOK_AT = 40  # how many of a customer's newest orders are opened for their addresses, as for their card
_PART = 200  # how many orders the book reads before it looks at the time

SAID = {
    "refused": "Google refused the hub's key. Is Places API (New) turned on for it?",
    "limit": "Google has been asked as often as it may be this month.",
    "unreachable": "Google is not answering.",
    "not_found": "Google found no address like that.",
}
"""What a manager is told when Google is tried and gives no list. A form is told nothing: it lists the
restaurant's own addresses. The same of the other services: `said`."""
_REFUSED = {
    "mapbox": (
        "Mapbox refused the hub's token. Copy it again from your Mapbox account; it must have no URL restriction."
    ),
    "azure": "Azure Maps refused the hub's key. Copy the primary key again from your Maps account in the Azure portal.",
}


def said(service: str, reason: str, code: int | None = None) -> str:
    """What a manager is told when a service is tried and gives no list. `code` is the status the service
    answered with when that was no answer the hub knows: said as it is, for whoever looks after the hub."""
    who = WHO.get(service, service)
    if reason == "unreachable" and code is not None:
        return f"{who} answered {code}, which is no list. Tell whoever looks after the hub."
    if service == SERVICE:
        return SAID[reason]
    if reason == "refused" and service in _REFUSED:
        return _REFUSED[service]
    return SAID[reason].replace("Google", who)


def credit_of(source: object) -> str | None:
    """The words that stand under a list with one of this service's answers, or None for a line that is the
    restaurant's own."""
    return CREDIT.get(source) if isinstance(source, str) else None


@dataclass(frozen=True)
class Suggestion:
    """One line of a list: `address` is what goes into the box, `main` and `rest` the same in two parts where
    the service told them apart ("12 Elm St" and "Winchester, MA"), and `source` where it is from: `customer`
    (this customer's own earlier delivery), `orders` (another delivery of the restaurant's) or the name of
    the map service."""

    address: str
    main: str = ""
    rest: str = ""
    source: str = "orders"

    def as_json(self) -> dict[str, Any]:
        return {"address": self.address, "main": self.main or self.address, "rest": self.rest, "from": self.source}


_BREAKS = " \t\n,.;#"


def _words(text: str) -> list[str]:
    return [word for word in re.split(r"[\s,.;#]+", text.casefold()) if word]


def _typed(typed: str) -> tuple[list[str], str]:
    """The words that are typed whole, and the one that is still being typed (empty when the typing ends
    on a space or a comma: every word is whole then)."""
    words = _words(typed)
    if not words or typed[-1:] in _BREAKS:
        return words, ""
    return words[:-1], words[-1]


def fits(typed: str, address: str) -> bool:
    """Whether the letters typed could become this address: every word typed whole is a word of the address,
    the one still being typed starts one, the case and the commas aside, and the address is more than what
    was typed. "12 el" is 12 Elm St and not 120 Elmwood Ave: the 12 is typed whole."""
    whole, begun = _typed(typed)
    held = _words(address)
    if not (whole or begun) or _plain(typed) == _plain(address):
        return False
    return all(word in held for word in whole) and (not begun or any(word.startswith(begun) for word in held))


def _place(typed: str, address: str) -> int:
    """Where in a list an address that fits belongs: 0 when it begins with the first word typed ("12" and
    "12 Elm St"), 1 when it begins the way that word does ("12" and "120 Elmwood Ave"), 2 when it holds the
    letters further on ("12" and "4 Oak Rd Apt 12")."""
    whole, begun = _typed(typed)
    held = _words(address)
    first = whole[0] if whole else begun
    if not held or not first:
        return 2
    if held[0] == first:
        return 0
    return 1 if not whole and held[0].startswith(first) else 2


def _went_to(state: OrderState, _taxes: Any = None, _rules: Any = None, _one: Any = None) -> tuple[str, int] | None:
    """Where an order was brought and when it was opened; None for one that was not brought anywhere."""
    if state.status == "void" or not is_delivery(state.fields):
        return None
    address = " ".join(str(state.fields.get("address") or "").split())
    if not address or len(address) > ADDRESS_MAX:
        return None
    return address, state.first.wall_ms if state.first is not None else 0


class _Store(Protocol):
    def index(self, *, phone: str | None = None) -> list[OrderEntry]: ...
    def with_phone(self) -> list[OrderEntry]: ...
    def views(self, entries: Sequence[OrderEntry]) -> list[OrderState]: ...


def own_addresses(store: _Store, phone: object) -> list[str]:
    """Where this customer's deliveries went, the newest first and each once (the case and the spaces
    aside), read off their own newest orders. None for a number too short to be a customer's."""
    digits = phone_digits(phone)
    if len(digits) < 7:
        return []
    entries = [e for e in store.index(phone=digits) if e.status != "void" and e.first_ms is not None]
    entries.sort(key=lambda e: (e.first_ms, e.order_id), reverse=True)
    seen: dict[str, str] = {}
    for state in store.views(entries[:_LOOK_AT]):
        went = _went_to(state)
        if went is not None:
            seen.setdefault(_plain(went[0]), went[0])
    return list(seen.values())


class AddressBook:
    """Where the restaurant's deliveries of the past year went: each address once, as its newest delivery
    spelled it, the newest first. Read off the orders that carry a customer's number, each remembered while
    its log stands (`OrderMemo`), and read again once a minute. It is the hub's memory of its own orders and
    nothing more: it is in no database, and it holds no name and no number."""

    def __init__(
        self,
        *,
        days: int = LOOK_BACK_DAYS,
        most: int = BOOK_MOST,
        every: float = BOOK_SECONDS,
        budget: float = BOOK_BUDGET,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._days, self._most, self._every, self._budget, self._clock = days, most, every, budget, clock
        self._memo = OrderMemo(_went_to, keep=120_000, at_once=_PART)
        self._lock = threading.Lock()
        self._listed: list[str] = []
        self._read_at: float | None = None  # None until the orders were read through once
        self._reading = False

    def listed(self, store: _Store, *, now_ms: int) -> list[str]:
        """The addresses, the newest first. Reads the orders again when the book is a minute old, for at most
        `budget` seconds: what is left is read at the next asking, and what was read so far is listed."""
        now = self._clock()
        with self._lock:
            if self._reading or (self._read_at is not None and now - self._read_at < self._every):
                return self._listed
            self._reading = True
        try:
            since = now_ms - self._days * 86_400_000
            entries = [
                e for e in store.with_phone() if e.status != "void" and e.first_ms is not None and e.first_ms >= since
            ]
            entries.sort(key=lambda e: (e.first_ms, e.order_id), reverse=True)
            newest: dict[str, tuple[int, str]] = {}
            whole = True
            replayed = 0

            def views(some: Sequence[OrderEntry]) -> list[OrderState]:
                nonlocal replayed
                replayed += len(some)  # the memo asks only for the orders it does not remember
                return store.views(some)

            until = time.monotonic() + self._budget
            for start in range(0, len(entries), _PART):
                before = replayed
                # the taxes and the rules have no say in where an order went: the memo is never dropped
                went = self._memo.each(entries[start : start + _PART], views, taxes=None, rules=None)  # type: ignore[arg-type]
                for address, at_ms in went:
                    key = _plain(address)
                    if key not in newest or newest[key][0] < at_ms:
                        newest[key] = (at_ms, address)
                if replayed > before and start + _PART < len(entries) and time.monotonic() > until:
                    whole = False  # the older ones at the next asking: what was read stays read
                    break
            listed = [address for _, address in sorted(newest.values(), reverse=True)[: self._most]]
            with self._lock:
                self._listed = listed
                self._read_at = now if whole else None
            return listed
        finally:
            with self._lock:
                self._reading = False


def known(typed: str, own: Sequence[str], others: Sequence[str], *, most: int) -> list[Suggestion]:
    """The restaurant's own addresses the typing could become: the customer's own first, then the others',
    each kind with the ones that begin the way the typing does at the head (`_place`) and the newest
    delivery first among those, at most `most` in all."""
    if len(_plain(typed).replace(" ", "")) < TYPED_FROM:
        return []
    out: list[Suggestion] = []
    seen: set[str] = set()
    for source, addresses in (("customer", own), ("orders", others)):
        fitting = [address for address in addresses if fits(typed, address)]
        for address in sorted(fitting, key=lambda address: _place(typed, address)):  # stable: newest first
            if _plain(address) not in seen:
                seen.add(_plain(address))
                out.append(Suggestion(address, source=source))
    return out[:most]


def _line(words: Any) -> str:
    """A service's words on one line; nothing for what is no words."""
    return " ".join(words.split()) if isinstance(words, str) else ""


def _text(held: Any) -> str:
    """The words of one of Google's texts (`{"text": "..."}`), on one line."""
    return _line(held.get("text")) if isinstance(held, Mapping) else ""


def _here(words: str) -> str:
    """An address without the country at its end: every address here is in it."""
    for end in (", USA", ", United States"):
        if words.endswith(end):
            return words[: -len(end)]
    return "" if words in ("USA", "United States") else words


def _point(lat: Any, lng: Any) -> tuple[float, float] | None:
    """A place as latitude and longitude, or None for two numbers that are no place."""
    if isinstance(lat, bool) or isinstance(lng, bool) or not isinstance(lat, int | float):
        return None
    if not isinstance(lng, int | float):
        return None
    return (float(lat), float(lng)) if -90 <= lat <= 90 and -180 <= lng <= 180 else None


class _Unlogged(logging.Filter):
    """httpx logs the address of every request it makes, and these hold what was typed, a place, or (Mapbox's)
    the token itself: nothing of a list's requests is logged by it."""

    hosts: set[str] = set()

    def filter(self, record: logging.LogRecord) -> bool:
        return not any(isinstance(arg, httpx.URL) and arg.host in self.hosts for arg in record.args or ())


_unlogged = _Unlogged()


def _quiet(base: str) -> None:
    """Keeps httpx's own line about every request to this service out of the log."""
    _Unlogged.hosts.add(httpx.URL(base).host)
    logger = logging.getLogger("httpx")
    if _unlogged not in logger.filters:
        logger.addFilter(_unlogged)


def _answered(ask: Callable[[], httpx.Response], *, who: str, nothing: Collection[int] = (404,)) -> Mapping[str, Any]:
    """What a service answered, read. Raises LookupFailed for anything but an answer; `nothing` are the
    statuses this service says "no such address" with. The log says which service and how it went, and
    never what it was asked."""
    try:
        answer = ask()
    except httpx.HTTPError as err:
        log.warning("the address list's map service (%s) did not answer (%s)", who, type(err).__name__)
        raise LookupFailed("unreachable") from None
    status = answer.status_code
    if status in (401, 403):  # a wrong key, the service not turned on for it, or billing not set up
        log.warning("the address list's map service (%s) refused the key (%d)", who, status)
        raise LookupFailed("refused", status)
    if status == 429:
        log.warning("the address list's map service (%s) says the account is at its limit (%d)", who, status)
        raise LookupFailed("limit", status)
    if status in nothing:
        raise LookupFailed("not_found", status)
    if status >= 400:
        log.warning("the address list's map service (%s) answered %d", who, status)
        raise LookupFailed("unreachable", status)
    try:
        data = answer.json()
    except ValueError:
        log.warning("the address list's map service's (%s) answer could not be read", who)
        raise LookupFailed("unreachable") from None
    return data if isinstance(data, Mapping) else {}


class Lists(Protocol):
    """A map service that lists what the letters typed could become."""

    name: str
    locates: int
    """How many requests finding where the restaurant stands is; 0 for a service that is not asked that."""
    locate_counts: int
    """How many askings of the month's free amount that finding is counted as."""

    def suggest(
        self, typed: str, near: tuple[float, float] | None = None, reach: float = NEAR_METERS
    ) -> list[Suggestion]:
        """What the letters typed could become, the likeliest first, with the streets around `near`
        (latitude, longitude) first: within `reach` meters of it, for a service that takes a distance.
        Raises LookupFailed."""
        ...

    def locate(self, address: str) -> tuple[float, float] | None:
        """Where an address stands, or None when the service reads it as no place. Raises LookupFailed."""
        ...


class Places:
    """Google's Places API (New): Autocomplete for the list, and one Place Details for where the restaurant
    stands (https://developers.google.com/maps/documentation/places/web-service/place-autocomplete). The
    letters go in the body and the key in a header, so neither is in the address of a request, which a log
    could show; httpx's own line about the one request that names a place id is kept out of the log."""

    name = SERVICE
    locates = 2
    locate_counts = 2

    def __init__(
        self,
        key: str,
        *,
        base: str = PLACES,
        kinds: Sequence[str] = KINDS,
        client: httpx.Client | None = None,
    ) -> None:
        self._key = key
        self._base = base.rstrip("/")
        self._kinds = [kind for kind in kinds if kind][:5]  # the service takes five at most
        self._client = client if client is not None else httpx.Client(timeout=SUGGEST_SECONDS)
        _quiet(self._base)

    def suggest(
        self, typed: str, near: tuple[float, float] | None = None, reach: float = NEAR_METERS
    ) -> list[Suggestion]:
        """What the letters typed could become, the likeliest first, those within `reach` meters of `near`
        before the others. Raises LookupFailed."""
        out: list[Suggestion] = []
        for told in self._predictions(
            typed,
            near,
            "suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat",
            reach=reach,
        ):
            address = _here(_text(told.get("text")))
            parts = told.get("structuredFormat")
            parts = parts if isinstance(parts, Mapping) else {}
            if address and len(address) <= ADDRESS_MAX:
                main = _text(parts.get("mainText"))
                out.append(Suggestion(address, main, _here(_text(parts.get("secondaryText"))) if main else "", SERVICE))
        return out

    def locate(self, address: str) -> tuple[float, float] | None:
        """Where an address stands, as latitude and longitude: the first place the service reads it as. None
        when it reads it as none. Raises LookupFailed."""
        found = self._predictions(address, None, "suggestions.placePrediction.placeId", kinds=())
        place = next((told.get("placeId") for told in found if isinstance(told.get("placeId"), str)), None)
        if not place or not re.fullmatch(r"[A-Za-z0-9_-]{1,300}", place):
            return None
        data = _answered(
            lambda: self._client.get(f"{self._base}/v1/places/{place}", headers=self._headers("location")),
            who=self.name,
        )
        stands = data.get("location")
        return _point(stands.get("latitude"), stands.get("longitude")) if isinstance(stands, Mapping) else None

    def _headers(self, mask: str) -> dict[str, str]:
        return {"X-Goog-Api-Key": self._key, "X-Goog-FieldMask": mask}

    def _predictions(
        self,
        typed: str,
        near: tuple[float, float] | None,
        mask: str,
        *,
        kinds: Sequence[str] | None = None,
        reach: float = NEAR_METERS,
    ) -> list[Mapping[str, Any]]:
        body: dict[str, Any] = {"input": typed, "includedRegionCodes": ["us"], "languageCode": "en"}
        wanted = self._kinds if kinds is None else list(kinds)
        if wanted:
            body["includedPrimaryTypes"] = wanted
        if near is not None:
            # a preference and no wall: what is in the circle comes first, and the rest is still listed
            body["locationBias"] = {
                "circle": {
                    "center": {"latitude": near[0], "longitude": near[1]},
                    "radius": round(min(max(reach, 1.0), CIRCLE_MOST_METERS), 1),
                }
            }
        data = _answered(
            lambda: self._client.post(f"{self._base}/v1/places:autocomplete", json=body, headers=self._headers(mask)),
            who=self.name,
        )
        listed = data.get("suggestions")
        told = (
            [one.get("placePrediction") for one in listed if isinstance(one, Mapping)]
            if isinstance(listed, list)
            else []
        )
        return [one for one in told if isinstance(one, Mapping)]


def _features(data: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """The places of an answer that is a GeoJSON collection (Mapbox's, Azure Maps'), each with what is
    said of it; nothing for an answer that is none."""
    listed = data.get("features")
    return [one for one in listed if isinstance(one, Mapping)] if isinstance(listed, list) else []


def _state_short(place: str, context: Any) -> str:
    """A town, state and ZIP with the state by its two letters, as an address is written here: Mapbox spells
    the state out ("Winchester, Massachusetts 01890") and says its letters beside it."""
    region = context.get("region") if isinstance(context, Mapping) else None
    name = _line(region.get("name")) if isinstance(region, Mapping) else ""
    code = _line(region.get("region_code")) if isinstance(region, Mapping) else ""
    at = place.rfind(name) if name else -1  # the last one: New York, New York
    if at < 0 or not re.fullmatch(r"[A-Z]{2}", code):
        return place
    return f"{place[:at]}{code}{place[at + len(name) :]}"


class Mapbox:
    """Mapbox's Geocoding API, version 6: forward, with autocomplete, which reads what it is sent as the
    start of an address (https://docs.mapbox.com/api/search/geocoding/). It takes the letters and the token
    in the address of the request and nowhere else, so httpx's own line about each request is kept out of
    the log. Its answers are of its temporary kind, which its terms do not let anybody keep: nothing of one
    is remembered, and it is never asked where the restaurant stands. It is told that (`proximity`) where the
    hub knows it from Geocodio, and goes by where the hub's own internet connection is where not
    (`proximity=ip`)."""

    name = "mapbox"
    locates = 0
    locate_counts = 0

    def __init__(
        self,
        token: str,
        *,
        base: str = MAPBOX,
        kinds: Sequence[str] = MAPBOX_KINDS,
        client: httpx.Client | None = None,
    ) -> None:
        self._token = token
        self._base = base.rstrip("/")
        self._kinds = [kind for kind in kinds if kind]
        self._client = client if client is not None else httpx.Client(timeout=SUGGEST_SECONDS)
        _quiet(self._base)

    def suggest(
        self, typed: str, near: tuple[float, float] | None = None, reach: float = NEAR_METERS
    ) -> list[Suggestion]:
        """What the letters typed could become, the likeliest first, the nearest to `near` before the others
        (it takes a place and no distance, so `reach` is not sent). Raises LookupFailed."""
        asked = {
            "q": typed.replace(";", " "),  # a semicolon would make two askings of one
            "autocomplete": "true",
            "country": "us",
            "language": "en",
            "limit": str(MAP_MOST),
            "proximity": f"{near[1]},{near[0]}" if near is not None else "ip",
            "access_token": self._token,
        }
        if self._kinds:
            asked["types"] = ",".join(self._kinds)
        data = _answered(
            lambda: self._client.get(f"{self._base}/search/geocode/v6/forward", params=asked),
            who=self.name,
            nothing=(404, 422),  # 422: letters it cannot read as the start of anything
        )
        out: list[Suggestion] = []
        for feature in _features(data):
            told = feature.get("properties")
            told = told if isinstance(told, Mapping) else {}
            main = _line(told.get("name"))
            rest = _state_short(_here(_line(told.get("place_formatted"))), told.get("context"))
            whole = f"{main}, {rest}" if main and rest else main or _here(_line(told.get("full_address")))
            if whole and len(whole) <= ADDRESS_MAX:
                out.append(Suggestion(whole, main if rest else "", rest if main else "", self.name))
        return out

    def locate(self, address: str) -> tuple[float, float] | None:
        """Never asked: its terms do not let where the restaurant stands be kept."""
        return None


class Azure:
    """Azure Maps' Search: Geocode Autocomplete for the list, and one Get Geocoding for where the restaurant
    stands (https://learn.microsoft.com/rest/api/maps/search/get-geocode-autocomplete). The key goes in a
    header; the letters go in the address of the request, so httpx's own line about each is kept out of
    the log. It wants a place or a box with every asking: the restaurant's own once that is known, and the
    whole country until then."""

    name = "azure"
    locates = 1
    locate_counts = 10  # one transaction of its Search, which ten askings for a list come to

    def __init__(self, key: str, *, base: str = AZURE, client: httpx.Client | None = None) -> None:
        self._key = key
        self._base = base.rstrip("/")
        self._client = client if client is not None else httpx.Client(timeout=SUGGEST_SECONDS)
        _quiet(self._base)

    def _headers(self) -> dict[str, str]:
        return {"subscription-key": self._key, "Accept-Language": "en-US"}

    def suggest(
        self, typed: str, near: tuple[float, float] | None = None, reach: float = NEAR_METERS
    ) -> list[Suggestion]:
        """What the letters typed could become, the likeliest first, the nearest to `near` before the others
        (it takes a place and no distance, so `reach` is not sent). Raises LookupFailed."""
        asked = {
            "api-version": AZURE_VERSION,
            "query": typed,
            "countryRegion": "US",
            "resultTypeGroups": "Address",  # addresses and streets, no shops and no towns
            "top": str(MAP_MOST),
        }
        if near is not None:
            asked["coordinates"] = f"{near[1]},{near[0]}"
        else:
            asked["bbox"] = US_BOX
        data = _answered(
            lambda: self._client.get(f"{self._base}/geocode:autocomplete", params=asked, headers=self._headers()),
            who=self.name,
        )
        out: list[Suggestion] = []
        for feature in _features(data):
            told = feature.get("properties")
            where = told.get("address") if isinstance(told, Mapping) else None
            where = where if isinstance(where, Mapping) else {}
            main = _line(where.get("addressLine"))
            whole = _here(_line(where.get("formattedAddress"))) or main
            # the street and the rest of it, where the whole begins with the street
            rest = whole[len(main) :].lstrip(" ,") if main and whole.casefold().startswith(main.casefold()) else ""
            if whole and len(whole) <= ADDRESS_MAX:
                out.append(Suggestion(whole, main if rest else "", rest, self.name))
        return out

    def locate(self, address: str) -> tuple[float, float] | None:
        """Where an address stands, as latitude and longitude: the first place the service reads it as. None
        when it reads it as none. Raises LookupFailed."""
        data = _answered(
            lambda: self._client.get(
                f"{self._base}/geocode",
                params={"api-version": AZURE_VERSION, "query": address, "top": "1"},
                headers=self._headers(),
            ),
            who=self.name,
        )
        for feature in _features(data):
            spot = feature.get("geometry")
            pair = spot.get("coordinates") if isinstance(spot, Mapping) else None
            if isinstance(pair, list) and len(pair) >= 2:
                return _point(pair[1], pair[0])  # it says longitude first
            return None
        return None


def _within(seconds: float, ask: Callable[[], Any]) -> Any:
    """What `ask` answers, or LookupFailed("unreachable") when it has not answered in `seconds`: a request's
    own timeout bounds each of its steps and not their sum. The asking goes on behind, and what it answers
    then is dropped."""
    box: list[Any] = []

    def run() -> None:
        try:
            box.append(ask())
        except Exception as err:  # noqa: BLE001  handed to the one who waits, below
            box.append(err)

    thread = threading.Thread(target=run, name="addresses-ask", daemon=True)
    thread.start()
    thread.join(seconds)
    if not box:
        log.warning("the address list's map service was not heard from in %.1f s", seconds)
        raise LookupFailed("unreachable")
    if isinstance(box[0], Exception):
        raise box[0]
    return box[0]


def month_of(now: float) -> str:
    """The month a moment falls in, as the hub counts its askings: "2026-11"."""
    return datetime.fromtimestamp(now, MONTH_BY).strftime("%Y-%m")


class Asked:
    """How often each service was asked in each month. In memory: tests and a laptop. Every hub and the
    cloud use `PgAsked`, so that a hub that restarts goes on counting where it stopped."""

    def __init__(self) -> None:
        self._counts: dict[tuple[str, str], int] = {}
        self._lock = threading.Lock()

    def add(self, service: str, month: str, askings: int) -> int:
        """Counts so many askings more, and says how many that makes this month."""
        with self._lock:
            self._counts[(service, month)] = self._counts.get((service, month), 0) + askings
            return self._counts[(service, month)]

    def of(self, month: str) -> dict[str, int]:
        """How often each service was asked in that month; a service that was not is not in it."""
        with self._lock:
            return {service: count for (service, at), count in self._counts.items() if at == month}


ASKED_SCHEMA = """
CREATE TABLE IF NOT EXISTS map_asked (
    service    TEXT NOT NULL,
    month      TEXT NOT NULL,
    asked      BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (service, month)
);
"""


class PgAsked(Asked):
    """The same in the hub's database: one row for a service and a month, and nothing of what was asked. A
    count that cannot be written (a standby, a database that does not answer in two seconds) is kept in
    memory beside it for as long as the hub runs, so a list never waits for the count and never fails over
    it."""

    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        self._stored: dict[tuple[str, str], int] = {}  # as the database last said, for when it does not answer
        self._pool = ConnectionPool(
            dsn, min_size=1, max_size=pool_size, open=True, timeout=2.0, kwargs={"row_factory": tuple_row}
        )
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(ASKED_SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def add(self, service: str, month: str, askings: int) -> int:
        try:
            with self._pool.connection() as conn:
                row = conn.execute(
                    """
                    INSERT INTO map_asked (service, month, asked) VALUES (%s, %s, %s)
                    ON CONFLICT (service, month) DO UPDATE SET asked = map_asked.asked + EXCLUDED.asked
                    RETURNING asked
                    """,
                    (service, month, askings),
                ).fetchone()
        except Exception as err:  # noqa: BLE001  a count is never worth a list
            log.warning("the address list's count of %s could not be written (%s)", service, type(err).__name__)
            return self._stored.get((service, month), 0) + super().add(service, month, askings)
        self._stored[(service, month)] = int(row[0]) if row else askings
        return self._stored[(service, month)] + super().add(service, month, 0)

    def of(self, month: str) -> dict[str, int]:
        try:
            with self._pool.connection() as conn:
                rows = conn.execute("SELECT service, asked FROM map_asked WHERE month = %s", (month,)).fetchall()
        except Exception as err:  # noqa: BLE001  a hub in charge that is older has no such table; a database away
            log.warning("the address list's counts could not be read (%s)", type(err).__name__)
            rows = [(service, count) for (service, at), count in self._stored.items() if at == month]
        counts = {str(service): int(count) for service, count in rows}
        for service, count in counts.items():
            self._stored[(service, month)] = count
        for service, count in super().of(month).items():  # what this hub could not write
            counts[service] = counts.get(service, 0) + count
        return counts


def default_asked() -> Asked:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    return PgAsked(dsn) if dsn else Asked()


class _Listing:
    """One service, and how this month and today went with it."""

    def __init__(self, service: Lists, monthly: int) -> None:
        self.service = service
        self.monthly = monthly
        self.month = 0  # askings this month, as the count says (`Asked`)
        self.asked = 0  # today, for the status
        self.failed = 0
        self.last_failure: str | None = None
        self.rests_until = 0.0  # left alone until then, after it gave no answer
        self.near: tuple[str, float, tuple[float, float] | None] | None = None  # of which address, when, where
        self.finding: threading.Thread | None = None


def _place_in_order(listing: _Listing) -> int:
    name = listing.service.name
    return ORDER.index(name) if name in ORDER else len(ORDER)


class Suggester:
    """The hub's asking of the map services for a list: the first that has a key, and the next one when it
    gives no answer; none of them more often in a month than it gives away; and where the restaurant
    stands, found once for each that is asked that."""

    def __init__(
        self,
        *services: Lists | None,
        monthly: int | Mapping[str, int] | None = None,
        asked: Asked | None = None,
        wait: float = SUGGEST_SECONDS,
        within: float = CHAIN_SECONDS,
        clock: Callable[[], float] = time.time,
        placer: Callable[[str], tuple[float, float] | None] | None = None,
    ) -> None:
        self._monthly = monthly
        self._counts = asked if asked is not None else Asked()
        self._wait, self._all, self._clock = wait, within, clock
        self._placer = placer
        self._lock = threading.Lock()
        self._day = 0
        self._month = ""
        self._listings: list[_Listing] = []
        self.use(*services)

    def most(self, name: str) -> int:
        """The most this service is asked in a month, whether the hub has a key for it or not."""
        if isinstance(self._monthly, Mapping):
            return self._monthly.get(name, MONTHLY_MOST.get(name, MONTHLY_MOST[SERVICE]))
        return MONTHLY_MOST.get(name, MONTHLY_MOST[SERVICE]) if self._monthly is None else self._monthly

    def use(self, *services: Lists | None) -> None:
        """These services from now on, in the order they are asked (`ORDER`): a key was typed, replaced or
        removed while the hub runs (`pos.keys`). What the month and the day already counted against a
        service stays counted against it; its rest is over, and where the restaurant stands is asked
        again."""
        with self._lock:
            was = {listing.service.name: listing for listing in self._listings}
            fresh = []
            for service in services:
                if service is None:
                    continue
                listing = _Listing(service, self.most(service.name))
                before = was.get(service.name)
                if before is not None:
                    listing.asked, listing.failed, listing.last_failure = (
                        before.asked,
                        before.failed,
                        before.last_failure,
                    )
                fresh.append(listing)
            self._listings = sorted(fresh, key=_place_in_order)
            self._month = ""  # the month's counts are read again, for the ones that are new

    @property
    def ready(self) -> bool:
        """Whether there is a service to ask."""
        return bool(self._listings)

    @property
    def names(self) -> list[str]:
        """The services this hub has a key for, in the order they are asked."""
        with self._lock:
            return [listing.service.name for listing in self._listings]

    def has(self, name: str) -> bool:
        """Whether this hub has a key for that service."""
        return name in self.names

    def _turned(self) -> None:
        """Starts the day's counts over when the day has turned, and reads the month's when the month has
        (or the services changed). Called with the lock held."""
        now = self._clock()
        day = int(now // 86400)
        if day != self._day:
            self._day = day
            for listing in self._listings:
                listing.asked, listing.failed = 0, 0
        month = month_of(now)
        if month != self._month:
            self._month = month
            counted = self._counts.of(month)
            for listing in self._listings:
                listing.month = counted.get(listing.service.name, 0)

    def _ask(
        self,
        listing: _Listing,
        ask: Callable[[Lists], Any],
        *,
        requests: int = 1,
        counts: int | None = None,
        wait: float | None = None,
        rests: bool = True,
    ) -> Any:
        """One asking of a service, of so many requests, counted against its month (as `counts` askings
        where that is not the number of requests) and waited for. A service that gives no answer rests
        from then (`REST`), unless `rests` says this asking decides nothing about it; one that answers
        rests no longer. Raises LookupFailed."""
        askings = requests if counts is None else counts
        with self._lock:
            self._turned()
            if listing.month + askings > listing.monthly:
                listing.last_failure = "limit"
                raise LookupFailed("limit")
            # counted before it is asked: an asking that is on its way is one the service will count
            counted = self._counts.add(listing.service.name, self._month, askings)
            if counted > listing.monthly:  # the other hub asked meanwhile: this asking is not made after all
                self._counts.add(listing.service.name, self._month, -askings)
                listing.month = max(listing.month, counted - askings)
                listing.last_failure = "limit"
                raise LookupFailed("limit")
            listing.asked += requests
            listing.month = max(listing.month + askings, counted)
        try:
            told = _within((self._wait if wait is None else wait) * requests, lambda: ask(listing.service))
        except LookupFailed as err:
            with self._lock:
                listing.failed += 1
                listing.last_failure = err.reason
                if rests and err.reason in REST:
                    listing.rests_until = self._clock() + REST[err.reason]
            raise
        if rests:
            with self._lock:
                listing.rests_until = 0.0
        return told

    def place_with(self, placer: Callable[[str], tuple[float, float] | None] | None) -> None:
        """Who says where the restaurant stands for a service that is never asked that itself (Mapbox):
        somebody whose answer may be kept and given to anybody (`Lookups.locate`: Geocodio). It raises
        LookupFailed when it cannot say; None for nobody, and such a service goes by what it has."""
        self._placer = placer

    def _stands(self, listing: _Listing, origin: str) -> tuple[float, float] | None:
        """Where the restaurant stands as this service reads it, from memory. When it is not known, the
        address changed or the memory is nearly a month old, the service is asked behind this call, and
        after a failure not again for an hour. Nobody typing waits for it: until it is known the service
        goes by what it has (`Lists.suggest`). A service that is not asked that itself (`locates` 0) is told
        what the hub's own placer says (`place_with`), and never knows where there is none."""
        service = listing.service
        own = service.locates > 0
        placer = self._placer
        if not origin or (not own and placer is None):
            return None
        now = self._clock()
        with self._lock:
            held = listing.near
            same = held is not None and held[0] == origin
            if held is not None and same and now - held[1] < (NEAR_SECONDS if held[2] is not None else NEAR_AGAIN):
                return held[2]
            listing.near = (origin, now, None)  # asked for: nobody else asks meanwhile

            def find() -> None:
                try:
                    if own:
                        found = self._ask(
                            listing,
                            lambda service: service.locate(origin),
                            requests=service.locates,
                            counts=service.locate_counts,
                            rests=False,
                        )
                    else:  # not this service's asking: nothing of its month, and nothing about how it stands
                        found = placer(origin) if placer is not None else None
                except LookupFailed:
                    found = None
                except Exception:  # noqa: BLE001  a list is a help: it goes by what it has
                    log.warning("where the restaurant stands could not be asked")
                    found = None
                with self._lock:
                    if listing.near is not None and listing.near[0] == origin:
                        listing.near = (origin, now, found)

            listing.finding = threading.Thread(target=find, name="addresses-near", daemon=True)
            listing.finding.start()
        return None

    def placed(self, seconds: float = 5.0) -> None:
        """Waits until the asking for where the restaurant stands is over, where one runs: for a test, and
        for trying a service out."""
        with self._lock:
            finding = [listing.finding for listing in self._listings if listing.finding is not None]
        for thread in finding:
            thread.join(seconds)

    def suggest(
        self,
        typed: str,
        origin: str = "",
        *,
        among: Collection[str] | None = None,
        via: str | None = None,
        reach: float = NEAR_METERS,
    ) -> list[Suggestion]:
        """What the letters typed could become, as the first service says that gives an answer, with the
        streets near the restaurant's own address (`origin`) first: within `reach` meters of it, for a
        service that takes a distance. `among` names the services a manager
        turned on (all of them unless given); they are asked in their order, each after the first only
        when the one before it gave no answer: its month is used up, it rests after it did not answer, it
        does not answer now, or it refuses the key. An empty list is an answer. `via` names the one
        service to ask whatever the others do and whether it rests or not: for trying it out.

        Raises LookupFailed when none of them answered: with what the first one's reason was, or that
        there is no address like that when one of them said so."""
        origin = " ".join(origin.split())
        with self._lock:
            listings = [
                listing
                for listing in self._listings
                if (listing.service.name == via if via is not None else among is None or listing.service.name in among)
            ]
        reasons: list[tuple[str, int | None]] = []
        until = time.monotonic() + self._all
        for listing in listings:
            if via is None:
                with self._lock:
                    resting = self._clock() < listing.rests_until
                if resting:
                    reasons.append((listing.last_failure or "unreachable", None))
                    continue
            left = until - time.monotonic()
            if left < 0.25:  # no time is left that anybody typing would wait
                break
            near = self._stands(listing, origin)
            try:
                found = self._ask(
                    listing,
                    lambda service, near=near: service.suggest(typed, near, reach),
                    wait=min(self._wait, left),
                )
            except LookupFailed as err:
                if err.reason == "not_found":
                    raise  # it answered: there is no such address, and nobody else is asked
                reasons.append((err.reason, err.code))
                continue
            return list(found)
        if not reasons:
            raise LookupFailed("unreachable")
        raise LookupFailed(*reasons[0])

    def left(self, name: str) -> int | None:
        """How many askings this service has left for the month, by the hub's own count; None for a service
        this hub has no key for."""
        with self._lock:
            self._turned()
            for listing in self._listings:
                if listing.service.name == name:
                    return max(0, listing.monthly - listing.month)
        return None

    def statuses(self) -> list[dict[str, Any]]:
        """For the Address list's setting and `hubctl maps status`: of each service this hub has a key for,
        in the order they are asked, how often it was asked this month, the most it is asked in one and
        what is left of that, how often it was asked today and how often it gave no list, whether it rests
        after giving no answer, and whether it knows where the restaurant stands. No address is in it."""
        with self._lock:
            self._turned()
            now = self._clock()
            return [
                {
                    "service": listing.service.name,
                    "asked_month": listing.month,
                    "monthly_most": listing.monthly,
                    "left": max(0, listing.monthly - listing.month),
                    "asked_today": listing.asked,
                    "failed_today": listing.failed,
                    "last_failure": listing.last_failure,
                    "placed": listing.near is not None and listing.near[2] is not None,
                    "resting": now < listing.rests_until,
                }
                for listing in self._listings
            ]

    def status(self) -> dict[str, Any] | None:
        """The same of the service that is asked first; None where there is no service."""
        told = self.statuses()
        return told[0] if told else None


def worth_asking(typed: str) -> bool:
    """Whether the letters typed are enough to ask a map service about: four of them, a letter among
    them. A house number alone could be anywhere."""
    plain = _plain(typed)
    return len(plain) >= ASK_FROM and any(letter.isalpha() for letter in plain)


def places_from_env(environ: Mapping[str, str] | None = None) -> Places | None:
    """`POS_MAPS_GOOGLE_KEY` is the hub's Google Maps Platform key; for the list it has to be allowed to call
    Places API (New). None with no key. `POS_MAPS_SUGGEST_TYPES` names what is listed, with commas (unless
    set: addresses and streets, `KINDS`; `all`: everything the service knows, shops and towns too)."""
    env = os.environ if environ is None else environ
    key = env.get("POS_MAPS_GOOGLE_KEY", "").strip()
    if not key:
        return None
    named = env.get("POS_MAPS_SUGGEST_TYPES", "").strip().lower()
    kinds = KINDS if not named else [] if named == "all" else [kind.strip() for kind in named.split(",")]
    return Places(key, base=env.get("POS_MAPS_PLACES_URL", "").strip() or PLACES, kinds=kinds)


def mapbox_from_env(environ: Mapping[str, str] | None = None) -> Mapbox | None:
    """`POS_MAPS_MAPBOX_KEY` is a Mapbox access token (a public one, `pk.`, will do; it must not be
    restricted to web addresses). None with no token."""
    env = os.environ if environ is None else environ
    token = env.get("POS_MAPS_MAPBOX_KEY", "").strip()
    return Mapbox(token, base=env.get("POS_MAPS_MAPBOX_URL", "").strip() or MAPBOX) if token else None


def azure_from_env(environ: Mapping[str, str] | None = None) -> Azure | None:
    """`POS_MAPS_AZURE_KEY` is the key of an Azure Maps account (its primary or its secondary key). None with
    no key."""
    env = os.environ if environ is None else environ
    key = env.get("POS_MAPS_AZURE_KEY", "").strip()
    return Azure(key, base=env.get("POS_MAPS_AZURE_URL", "").strip() or AZURE) if key else None


def services_from_env(environ: Mapping[str, str] | None = None) -> list[Lists]:
    """The services this hub has a key for, in the order they are asked."""
    env = os.environ if environ is None else environ
    made = (places_from_env(env), mapbox_from_env(env), azure_from_env(env))
    return [service for service in made if service is not None]


def suggester_from_env(environ: Mapping[str, str] | None = None, *, asked: Asked | None = None) -> Suggester:
    """The hub's asking as its own file has it: the services it names a key for, and the most each is asked
    in a month (`MONTHLY_ENV`; `MONTHLY_MOST` unless set). `asked` is where the month's askings are counted."""
    env = os.environ if environ is None else environ
    monthly: dict[str, int] = {}
    for name, named in MONTHLY_ENV.items():
        try:
            monthly[name] = max(0, int(env.get(named, "") or MONTHLY_MOST[name]))
        except ValueError:
            monthly[name] = MONTHLY_MOST[name]
    return Suggester(*services_from_env(env), monthly=monthly, asked=asked)


__all__ = [
    "ASK_FROM",
    "CREDIT",
    "FREE",
    "LIST_MOST",
    "MONTHLY_MOST",
    "ORDER",
    "OWN_MOST",
    "REST",
    "SAID",
    "SERVICE",
    "TITLE",
    "AddressBook",
    "Asked",
    "Azure",
    "Lists",
    "Mapbox",
    "PgAsked",
    "Places",
    "Suggester",
    "Suggestion",
    "azure_from_env",
    "credit_of",
    "default_asked",
    "fits",
    "known",
    "mapbox_from_env",
    "month_of",
    "own_addresses",
    "places_from_env",
    "said",
    "services_from_env",
    "suggester_from_env",
    "worth_asking",
]
