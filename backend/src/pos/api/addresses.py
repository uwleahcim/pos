"""The list of addresses while one is being typed, on the wire. What is listed is worked out in
`pos.addresses`; these are the calls (docs/delivery.md, "A list of addresses while typing").

- `POST /addresses/suggest` `{typed, phone, own}`: what the letters typed so far could become. Anyone at a
  terminal may ask it, like how far an address is. The letters go in the body, never in the address of the
  request, which a log could show.
- `GET /settings/address_list`, `PUT /settings/address_list` (manager token): which map services are asked as
  well as the restaurant's own deliveries (`google`, `mapbox`, `azure`, each off until a manager turns it
  on), and under `services` how each stands: whether the hub has a key for it, and how many askings it has
  left for the month.
- `POST /settings/address_list/try` `{service}` (manager token): asks one map service once, about the
  restaurant's own address, and says whether it answered: how a manager finds out that a key works before
  turning the list's use of it on.
"""

from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from ..addresses import (
    CREDIT,
    LIST_MOST,
    ORDER,
    OWN_MOST,
    SERVICE,
    TITLE,
    AddressBook,
    Suggester,
    Suggestion,
    credit_of,
    known,
    own_addresses,
    said,
    worth_asking,
)
from ..maps import ADDRESS_MAX, LookupFailed, same_address
from ..settings import SettingStore, clean_address_list
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

log = logging.getLogger("pos.addresses")

TRY_WITH = "1 Main St"
"""What a service is tried with where the restaurant's own address is not set yet: no customer's address."""


class TypedIn(BaseModel):
    """The letters typed in an address box so far."""

    typed: str = Field(max_length=400)
    phone: str = Field(
        "", max_length=40, description="the customer's number, for their own earlier deliveries; used on the hub alone"
    )
    own: bool = Field(
        True,
        description="false for the restaurant's own address: no customer's delivery is listed for it",
    )


class AddressListIn(BaseModel):
    """Which map services the list of addresses asks as well. One that is left out stays as it is: an app
    from before there were several names Google alone."""

    google: bool | None = None
    mapbox: bool | None = None
    azure: bool | None = None


class TryIn(BaseModel):
    """Which map service is tried: Google unless named."""

    service: str = Field(SERVICE, max_length=20)


def add_address_list(app: FastAPI, book: AddressBook | None = None) -> None:
    book = book if book is not None else AddressBook()
    app.state.address_book = book

    def now(setting: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """The list's setting as a screen is told it. Under `services`, every map service in the order they
        are asked: `name`, `title` (what a screen calls it), `credit` (the words under a list with one of
        its answers), `on` (a manager turned it on), `key` (this hub has a key for it), `asks` (both),
        `left` and `monthly_most` (how many askings it has left for the month, of how many), `used_up`,
        and `resting` (it gave no answer a moment ago, and the next one is asked meanwhile).

        For an app from before there were several: `service`, whether this hub has a key for Google;
        `asks`, whether Google is asked; and `credit`, Google's name."""
        settings: SettingStore = app.state.settings
        suggester: Suggester = app.state.suggester
        told = dict(setting if setting is not None else settings.get("address_list"))
        stands = {status["service"]: status for status in suggester.statuses()}
        services = []
        for name in ORDER:
            status = stands.get(name)
            on = told.get(name) is True
            most = status["monthly_most"] if status else suggester.most(name)
            services.append(
                {
                    "name": name,
                    "title": TITLE[name],
                    "credit": CREDIT[name],
                    "on": on,
                    "key": status is not None,
                    "asks": on and status is not None,
                    "left": status["left"] if status else None,
                    "monthly_most": most,
                    "used_up": status is not None and status["left"] < 1,
                    "resting": status is not None and status["resting"],
                }
            )
        return {
            **{name: told.get(name) is True for name in ORDER},
            "service": SERVICE in stands,
            "asks": told.get(SERVICE) is True and SERVICE in stands,
            "credit": CREDIT[SERVICE],
            "services": services,
        }

    @app.get("/settings/address_list")
    def read_address_list() -> dict[str, Any]:
        """The list of addresses under a box that is being typed in: which map services a manager turned on
        for it (`google`, `mapbox`, `azure`), and under `services` how each stands, in the order they are
        asked. The restaurant's own earlier deliveries are listed either way."""
        return now()

    @app.put("/settings/address_list")
    def write_address_list(body: AddressListIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns a map service on or off for the list. From then on what is typed in an address
        box is sent to it when its turn comes, or is not. A service that is not named stays as it is."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        wanted = {**settings.get("address_list"), **body.model_dump(exclude_none=True)}
        try:
            cleaned = clean_address_list(wanted)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = settings.put("address_list", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return now(saved)

    @app.post("/settings/address_list/try")
    def try_address_list(body: TryIn | None = None, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Asks one map service once (`service`; Google unless named), whether the list uses it or not and
        whatever the others do, and says how it went: `ok`, `found` (how many addresses it listed), `left`
        (the askings it has left for the month) and for a failure its `reason` and words for the manager.
        It is asked about the restaurant's own address (Location, Delivery fee), and about "1 Main St"
        where that is not set: never about a customer's. 422 `bad_value` for a name that is no service's;
        409 `no_service` on a hub with no key for it."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        suggester: Suggester = app.state.suggester
        name = body.service if body is not None else SERVICE
        if name not in ORDER:
            raise HTTPException(422, {"error": "bad_value", "message": "there is no such map service"})
        if not suggester.has(name):
            message = "this hub has no Google Maps key" if name == SERVICE else f"this hub has no key for {TITLE[name]}"
            raise HTTPException(409, {"error": "no_service", "message": message})
        origin = str(settings.get("delivery_fee").get("origin") or "")
        try:
            found = suggester.suggest(origin or TRY_WITH, via=name)
        except LookupFailed as err:
            return {
                "ok": False,
                "found": 0,
                "reason": err.reason,
                "message": said(name, err.reason, err.code),
                "service": name,
                "left": suggester.left(name),
            }
        return {
            "ok": True,
            "found": len(found),
            "reason": None,
            "message": "",
            "service": name,
            "left": suggester.left(name),
        }

    @app.post("/addresses/suggest")
    def suggest_addresses(body: TypedIn) -> dict[str, Any]:
        """What the letters typed in an address box could become: `suggestions`, each `{address, main, rest,
        from}`, at most six, in the order a screen lists them. `address` is what a tap puts in the box;
        `main` and `rest` are the same in two parts where they are told apart; `from` says where it is
        from: `customer` (an earlier delivery of the customer at `phone`), `orders` (another delivery of the
        restaurant's in the past year) or the map service that answered (`google`, `mapbox`, `azure`).

        Of a list that holds a map service's answers: `credit`, the words to show with it ("Google Maps");
        `service`, its name; `title`, what a screen calls it; and `left` of `monthly_most`, how many askings
        it has left for the month by the hub's own count of the most it is asked in one, so a screen can show
        who answered and how much of its free amount is left. All five are null for a list of the
        restaurant's own addresses.

        The restaurant's own deliveries come first and ask nobody. The map services are asked only where a
        manager turned them on, from the fourth letter, and not about an address the restaurant already
        knows in full: the first one, and the next only when the one before it gave no answer (its month is
        used up, or it is down). Whichever is asked is sent the letters typed and nothing else: no name, no
        phone number, nothing of an order. The number is used on the hub alone. What a service answers is
        not kept.

        A list is a help: when no service answers, the list is shorter and there is no error. With `own`
        false (the restaurant's own address) no delivery is listed and the services alone are asked."""
        settings: SettingStore = app.state.settings
        suggester: Suggester = app.state.suggester
        store = app.state.store
        typed = " ".join(body.typed.split())
        listed: list[Suggestion] = []
        if typed and len(typed) <= ADDRESS_MAX:
            theirs = own_addresses(store, body.phone) if body.own and body.phone else []
            others = book.listed(store, now_ms=store.now_ms()) if body.own else []
            listed = known(body.typed, theirs, others, most=LIST_MOST)  # as typed: a space ends a word
            whole = any(same_address(typed, address) for address in (*theirs, *others))
            outside: list[Suggestion] = []
            setting = settings.get("address_list")
            on = [name for name in suggester.names if setting.get(name) is True]
            if on and not whole and worth_asking(typed):
                origin = str(settings.get("delivery_fee").get("origin") or "") if body.own else ""
                try:
                    outside = suggester.suggest(typed, origin, among=on)
                except LookupFailed:
                    outside = []  # counted by the suggester; a form is told nothing
            if outside:
                listed = listed[:OWN_MOST]
                for one in outside:
                    if not same_address(one.address, typed) and not any(
                        same_address(one.address, had.address) for had in listed
                    ):
                        listed.append(one)
            listed = listed[:LIST_MOST]
        answered = next((one.source for one in listed if one.source in ORDER), None)
        return {
            "typed": typed,
            "suggestions": [one.as_json() for one in listed],
            "credit": credit_of(answered),
            "service": answered,
            "title": TITLE.get(answered) if answered else None,
            "left": suggester.left(answered) if answered else None,
            "monthly_most": suggester.most(answered) if answered else None,
        }
