"""The list of addresses while one is being typed, on the wire. What is listed is worked out in
`pos.addresses`; these are the calls (docs/delivery.md, "A list of addresses while typing").

- `POST /addresses/suggest` `{typed, phone, own}`: what the letters typed so far could become. Anyone at a
  terminal may ask it, like how far an address is. The letters go in the body, never in the address of the
  request, which a log could show.
- `GET /settings/address_list`, `PUT /settings/address_list` (manager token): whether a map service is asked
  as well as the restaurant's own deliveries (`google`, off until a manager turns it on).
- `POST /settings/address_list/try` (manager token): asks the map service once, about the restaurant's own
  address, and says whether it answered: how a manager finds out that the hub's Google key may call Places
  API (New) before turning the list's use of it on.
"""

from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from ..addresses import (
    LIST_MOST,
    OWN_MOST,
    SAID,
    SERVICE,
    AddressBook,
    Suggester,
    Suggestion,
    known,
    own_addresses,
    worth_asking,
)
from ..maps import ADDRESS_MAX, LookupFailed, credit_of, same_address
from ..settings import SettingStore, clean_address_list
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

log = logging.getLogger("pos.addresses")

TRY_WITH = "1 Main St"
"""What the service is tried with where the restaurant's own address is not set yet: no customer's address."""


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
    """Whether the list of addresses asks a map service as well."""

    google: bool = False


def add_address_list(app: FastAPI, book: AddressBook | None = None) -> None:
    book = book if book is not None else AddressBook()
    app.state.address_book = book

    def now(setting: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """The list's setting as a screen is told it: with `service`, whether this hub has a map service
        that lists addresses, `asks`, whether it is asked (a service, and turned on), and `credit`, the
        name that stands under a list with one of its answers."""
        settings: SettingStore = app.state.settings
        suggester: Suggester = app.state.suggester
        told = dict(setting if setting is not None else settings.get("address_list"))
        return {
            **told,
            "service": suggester.ready,
            "asks": told.get("google") is True and suggester.ready,
            "credit": credit_of(SERVICE),
        }

    @app.get("/settings/address_list")
    def read_address_list() -> dict[str, Any]:
        """The list of addresses under a box that is being typed in: `google`, whether a manager turned the
        map service on for it; `service`, whether this hub has one (a Google Maps key); `asks`, whether both
        hold. The restaurant's own earlier deliveries are listed either way."""
        return now()

    @app.put("/settings/address_list")
    def write_address_list(body: AddressListIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns the map service on or off for the list. From then on what is typed in an address
        box is sent to it, or is not."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        try:
            cleaned = clean_address_list(body.model_dump())
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = settings.put("address_list", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return now(saved)

    @app.post("/settings/address_list/try")
    def try_address_list(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Asks the map service once, whether the list uses it or not, and says how it went: `ok`, `found`
        (how many addresses it listed), and for a failure its `reason` and words for the manager. It is
        asked about the restaurant's own address (Location, Delivery fee), and about "1 Main St" where
        that is not set: never about a customer's. 409 `no_service` on a hub with no Google Maps key."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        suggester: Suggester = app.state.suggester
        if not suggester.ready:
            raise HTTPException(409, {"error": "no_service", "message": "this hub has no Google Maps key"})
        origin = str(settings.get("delivery_fee").get("origin") or "")
        try:
            found = suggester.suggest(origin or TRY_WITH)
        except LookupFailed as err:
            return {"ok": False, "found": 0, "reason": err.reason, "message": SAID[err.reason]}
        return {"ok": True, "found": len(found), "reason": None, "message": ""}

    @app.post("/addresses/suggest")
    def suggest_addresses(body: TypedIn) -> dict[str, Any]:
        """What the letters typed in an address box could become: `suggestions`, each `{address, main, rest,
        from}`, at most six, in the order a screen lists them. `address` is what a tap puts in the box;
        `main` and `rest` are the same in two parts where they are told apart; `from` says where it is
        from: `customer` (an earlier delivery of the customer at `phone`), `orders` (another delivery of the
        restaurant's in the past year) or `google`. `credit` is the name to show under a list that holds
        one of the map service's answers ("Google Maps"), or null.

        The restaurant's own deliveries come first and ask nobody. The map service is asked only where a
        manager turned it on, from the fourth letter, and not about an address the restaurant already knows
        in full. It is sent the letters typed and nothing else: no name, no phone number, nothing of an
        order. The number is used on the hub alone. What the service answers is not kept.

        A list is a help: a service that does not answer, refuses the key or was asked as often as it may
        be today gives a shorter list and no error. With `own` false (the restaurant's own address) no
        delivery is listed and the service alone is asked."""
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
            if settings.get("address_list").get("google") is True and suggester.ready and not whole:
                if worth_asking(typed):
                    origin = str(settings.get("delivery_fee").get("origin") or "") if body.own else ""
                    try:
                        outside = suggester.suggest(typed, origin)
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
        return {
            "typed": typed,
            "suggestions": [one.as_json() for one in listed],
            "credit": credit_of(SERVICE) if any(one.source == SERVICE for one in listed) else None,
        }
