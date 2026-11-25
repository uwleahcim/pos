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

A map service comes second, and only where a manager turned it on (`address_list` in the settings, off
until then): Google's Places API (New), Autocomplete, with the key the hub has for Google Maps
(`POS_MAPS_GOOGLE_KEY`; the key has to be allowed to call Places API (New)). It is sent the letters typed,
and where the restaurant stands, so that streets nearby come first. No name, no phone number, nothing of an
order. The key goes in a header, the letters in the body, and the hub's log names neither. What it answers
is shown and then gone: nothing of it is remembered or written down (its terms keep predictions out of any
store), and its name stands under a list that holds one of its answers (`maps.credit_of`). An address
somebody tapped is the customer's own address, typed with fewer letters, and goes on the order like one
typed in full.

Where the restaurant stands is asked of the same service once (`Places.locate`): its own address as
Google reads it, and that place's coordinates, kept in the hub's memory for under thirty days and never
written down, as its terms allow. Until it is known the service goes by where the hub's own internet
connection is.

The hub asks the service at most `POS_MAPS_SUGGEST_DAILY` times a day (300 unless set: about 9,000 a month,
inside the 10,000 its price list gave away each month when this was written), so a screen gone wrong cannot
run up a bill. Past that, and whenever the service does not answer in two seconds, the list holds the
restaurant's own addresses alone. A list never fails a form.
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from .maps import ADDRESS_MAX, LookupFailed, _plain
from .orders.sales import OrderMemo
from .sync.oplog import OrderEntry, OrderState, is_delivery, phone_digits

log = logging.getLogger("pos.addresses")

PLACES = "https://places.googleapis.com"
SERVICE = "google"
"""The name of the one map service that lists addresses, as `pos.maps` names it."""
OWN_MOST = 3
"""How many of the restaurant's own addresses lead a list that the map service adds to."""
LIST_MOST = 6
"""How long a list is at most: a phone shows it under the box, over the keyboard."""
TYPED_FROM = 2
"""Letters typed before the restaurant's own addresses are listed."""
ASK_FROM = 4
"""Letters typed before the map service is asked: "12 E" says little, and every asking is counted."""
SUGGEST_SECONDS = 2.0
"""How long the service is waited for. Somebody is typing: a list that comes later than that is in the way."""
SUGGEST_DAILY_MOST = 300
LOOK_BACK_DAYS = 400
"""How far back deliveries are read for their addresses: the year the guest list reads, and a month."""
BOOK_MOST = 5000
"""The most addresses the book holds, the newest deliveries first."""
BOOK_SECONDS = 60.0
"""How long the book stands before the orders are read again: a delivery taken now is listed a minute on."""
BOOK_BUDGET = 0.25
"""The most seconds one asking spends reading old orders. A hub that just started reads a year of them a
part at a time, the newest first, and lists what it has read so far."""
NEAR_METERS = 20_000.0
"""How far around the restaurant addresses come first: further than any delivery goes, and inside the 50 km
the service allows."""
NEAR_SECONDS = 25 * 86400.0
"""How long the restaurant's coordinates stand in memory: under the thirty days the service's terms allow."""
NEAR_AGAIN = 3600.0
"""After the coordinates could not be had, how long until they are asked for again."""
KINDS = ("street_address", "premise", "subpremise", "route")
"""What the service is asked to list: addresses and streets, no shops and no towns."""
_LOOK_AT = 40  # how many of a customer's newest orders are opened for their addresses, as for their card
_PART = 200  # how many orders the book reads before it looks at the time

SAID = {
    "refused": "Google refused the hub's key. Is Places API (New) turned on for it?",
    "limit": "Google has been asked as often as it may be today.",
    "unreachable": "Google is not answering.",
    "not_found": "Google found no address like that.",
}
"""What a manager is told when the service is tried and gives no list. A form is told nothing: it lists the
restaurant's own addresses."""


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


def _text(held: Any) -> str:
    """The words of one of the service's texts (`{"text": "..."}`), on one line."""
    words = held.get("text") if isinstance(held, Mapping) else None
    return " ".join(words.split()) if isinstance(words, str) else ""


def _here(words: str) -> str:
    """An address without the country at its end: every address here is in it."""
    for end in (", USA", ", United States"):
        if words.endswith(end):
            return words[: -len(end)]
    return "" if words in ("USA", "United States") else words


class _NoPlaces(logging.Filter):
    """httpx logs the address of every request it makes, and the one for where the restaurant stands names
    a place: nothing of this service's requests is logged by it."""

    def __init__(self, host: str) -> None:
        super().__init__()
        self._host = host

    def filter(self, record: logging.LogRecord) -> bool:
        return not any(isinstance(arg, httpx.URL) and arg.host == self._host for arg in record.args or ())


class Places:
    """Google's Places API (New): Autocomplete for the list, and one Place Details for where the restaurant
    stands (https://developers.google.com/maps/documentation/places/web-service/place-autocomplete). The
    letters go in the body and the key in a header, so neither is in the address of a request, which a log
    could show; httpx's own line about the one request that names a place id is kept out of the log."""

    name = SERVICE

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
        logging.getLogger("httpx").addFilter(_NoPlaces(httpx.URL(self._base).host))

    def suggest(self, typed: str, near: tuple[float, float] | None = None) -> list[Suggestion]:
        """What the letters typed could become, the likeliest first. Raises LookupFailed."""
        out: list[Suggestion] = []
        for told in self._predictions(
            typed, near, "suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat"
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
        data = self._asked(
            lambda: self._client.get(f"{self._base}/v1/places/{place}", headers=self._headers("location"))
        )
        stands = data.get("location")
        lat = stands.get("latitude") if isinstance(stands, Mapping) else None
        lng = stands.get("longitude") if isinstance(stands, Mapping) else None
        if (
            isinstance(lat, bool)
            or isinstance(lng, bool)
            or not isinstance(lat, int | float)
            or not isinstance(lng, int | float)
        ):
            return None
        return (float(lat), float(lng)) if -90 <= lat <= 90 and -180 <= lng <= 180 else None

    def _headers(self, mask: str) -> dict[str, str]:
        return {"X-Goog-Api-Key": self._key, "X-Goog-FieldMask": mask}

    def _predictions(
        self, typed: str, near: tuple[float, float] | None, mask: str, *, kinds: Sequence[str] | None = None
    ) -> list[Mapping[str, Any]]:
        body: dict[str, Any] = {"input": typed, "includedRegionCodes": ["us"], "languageCode": "en"}
        wanted = self._kinds if kinds is None else list(kinds)
        if wanted:
            body["includedPrimaryTypes"] = wanted
        if near is not None:
            body["locationBias"] = {
                "circle": {"center": {"latitude": near[0], "longitude": near[1]}, "radius": NEAR_METERS}
            }
        data = self._asked(
            lambda: self._client.post(f"{self._base}/v1/places:autocomplete", json=body, headers=self._headers(mask))
        )
        listed = data.get("suggestions")
        told = (
            [one.get("placePrediction") for one in listed if isinstance(one, Mapping)]
            if isinstance(listed, list)
            else []
        )
        return [one for one in told if isinstance(one, Mapping)]

    def _asked(self, ask: Callable[[], httpx.Response]) -> Mapping[str, Any]:
        """What the service answered, read. Raises LookupFailed for anything but an answer."""
        try:
            answer = ask()
        except httpx.HTTPError as err:
            log.warning("the address list's map service did not answer (%s)", type(err).__name__)
            raise LookupFailed("unreachable") from None
        status = answer.status_code
        if status in (401, 403):  # a wrong key, Places API (New) not turned on for it, or billing not set up
            log.warning("the address list's map service refused the key (%d)", status)
            raise LookupFailed("refused")
        if status == 429:
            log.warning("the address list's map service says the account is at its limit (%d)", status)
            raise LookupFailed("limit")
        if status == 404:
            raise LookupFailed("not_found")
        if status >= 400:
            log.warning("the address list's map service answered %d", status)
            raise LookupFailed("unreachable")
        try:
            data = answer.json()
        except ValueError:
            log.warning("the address list's map service's answer could not be read")
            raise LookupFailed("unreachable") from None
        return data if isinstance(data, Mapping) else {}


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
        log.warning("the address list's map service was not heard from in %.0f s", seconds)
        raise LookupFailed("unreachable")
    if isinstance(box[0], Exception):
        raise box[0]
    return box[0]


class Suggester:
    """The hub's asking of the map service for a list: the service when there is one, never more often in
    a day than the owner would expect to pay for, and where the restaurant stands, found once."""

    def __init__(
        self,
        places: Places | None = None,
        *,
        daily: int = SUGGEST_DAILY_MOST,
        wait: float = SUGGEST_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._places = places
        self._daily, self._wait, self._clock = daily, wait, clock
        self._lock = threading.Lock()
        self._day = 0
        self._asked = 0
        self._failed = 0
        self._last_failure: str | None = None
        self._near: tuple[str, float, tuple[float, float] | None] | None = None  # of which address, when, where
        self._finding: threading.Thread | None = None

    def use(self, places: Places | None) -> None:
        """This service from now on: a key was typed, replaced or removed while the hub runs (`pos.keys`).
        What the day already counted stays counted."""
        with self._lock:
            self._places = places
            self._near = None

    @property
    def ready(self) -> bool:
        """Whether there is a service to ask."""
        return self._places is not None

    def _today(self) -> None:
        """Starts the day's counts over when the day has turned. Called with the lock held."""
        day = int(self._clock() // 86400)
        if day != self._day:
            self._day, self._asked, self._failed = day, 0, 0

    def _ask(self, ask: Callable[[Places], Any], *, requests: int = 1) -> Any:
        """One asking of the service, of so many requests, counted against the day and waited for. Raises
        LookupFailed."""
        with self._lock:
            places = self._places
            if places is None:
                raise LookupFailed("unreachable")
            self._today()
            if self._asked + requests > self._daily:
                self._last_failure = "limit"
                raise LookupFailed("limit")
            self._asked += requests
        try:
            return _within(self._wait * requests, lambda: ask(places))
        except LookupFailed as err:
            with self._lock:
                self._failed += 1
                self._last_failure = err.reason
            raise

    def _stands(self, origin: str) -> tuple[float, float] | None:
        """Where the restaurant stands, from memory. When it is not known, the address changed or the memory
        is nearly a month old, the service is asked behind this call (two requests: the address as it reads
        it, then that place), and after a failure not again for an hour. Nobody typing waits for it: until
        it is known the service goes by where the hub's internet connection is."""
        if not origin:
            return None
        now = self._clock()
        with self._lock:
            held = self._near
            same = held is not None and held[0] == origin
            if held is not None and same and now - held[1] < (NEAR_SECONDS if held[2] is not None else NEAR_AGAIN):
                return held[2]
            if self._places is None:
                return None
            self._near = (origin, now, None)  # asked for: nobody else asks meanwhile

            def find() -> None:
                try:
                    found = self._ask(lambda places: places.locate(origin), requests=2)
                except LookupFailed:
                    found = None
                with self._lock:
                    if self._near is not None and self._near[0] == origin:
                        self._near = (origin, now, found)

            self._finding = threading.Thread(target=find, name="addresses-near", daemon=True)
            self._finding.start()
        return None

    def placed(self, seconds: float = 5.0) -> None:
        """Waits until the asking for where the restaurant stands is over, if one runs: for a test, and for
        trying the service out."""
        finding = self._finding
        if finding is not None:
            finding.join(seconds)

    def suggest(self, typed: str, origin: str = "") -> list[Suggestion]:
        """What the letters typed could become, as the service says, with the streets near the restaurant's
        own address (`origin`) first. Raises LookupFailed."""
        near = self._stands(" ".join(origin.split()))
        return list(self._ask(lambda places: places.suggest(typed, near)))

    def status(self) -> dict[str, Any] | None:
        """For `hubctl maps status`: how often the list's service was asked today and how often it gave
        none, and whether it knows where the restaurant stands; None where there is no service. No address
        is in it."""
        with self._lock:
            if self._places is None:
                return None
            self._today()
            return {
                "service": self._places.name,
                "asked_today": self._asked,
                "failed_today": self._failed,
                "daily_most": self._daily,
                "last_failure": self._last_failure,
                "placed": self._near is not None and self._near[2] is not None,
            }


def worth_asking(typed: str) -> bool:
    """Whether the letters typed are enough to ask the map service about: four of them, a letter among
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


def suggester_from_env(environ: Mapping[str, str] | None = None) -> Suggester:
    env = os.environ if environ is None else environ
    try:
        daily = max(0, int(env.get("POS_MAPS_SUGGEST_DAILY", "") or SUGGEST_DAILY_MOST))
    except ValueError:
        daily = SUGGEST_DAILY_MOST
    return Suggester(places_from_env(env), daily=daily)


__all__ = [
    "ASK_FROM",
    "LIST_MOST",
    "OWN_MOST",
    "SAID",
    "SERVICE",
    "AddressBook",
    "Places",
    "Suggester",
    "Suggestion",
    "fits",
    "known",
    "own_addresses",
    "places_from_env",
    "suggester_from_env",
    "worth_asking",
]
