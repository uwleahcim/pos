"""The orders customers placed on the restaurant's GloriaFood site, once they are accepted.

GloriaFood hands accepted orders to a POS in two ways (its "Accepted orders" API, version 2), and the hub
takes both (docs/online-orders.md):

- **It asks.** A hub sits behind the restaurant's router, so every minute it sends one request, with the key
  of this restaurant in a header and nothing else, and GloriaFood answers with the orders that were accepted
  since it was last asked (`{"count": 1, "orders": [...]}`). GloriaFood keeps an order for as long as nobody
  asks; once it has answered with it, it does not send it again.
- **It is told.** GloriaFood sends each order the moment it is accepted, to an address the restaurant gave
  it, with a key of the restaurant's in the `Authorization` header (`pushed`, `allowed`). That is the faster
  way, and the one that needs a way in from outside (`pos.online.door`).

Either way the hub writes down every order it is given before it does anything else with it
(`pos.online.inbox`), and an order that came both ways is one order.

**Not only accepted orders.** Every order says what became of it (`status`: `accepted`, `pending`,
`rejected`, `timed_out`, `canceled`), and which of them an integration sends is set in GloriaFood's admin.
One that sends pending orders too hands an order over the moment the customer places it (`accepted_at` and
`fulfill_at` empty) and again when it is accepted. Nothing is filtered here: what is done with each is
`pos.online.place.unaccepted` and `pos.online.inbox.Inbox.again`.

What leaves the building: the key the hub asks with, in the `Authorization` header. No order, no customer,
nothing of the POS. Both keys are this restaurant's own integrations in GloriaFood's admin ("Poll Accepted
Order v2" and "Push Accepted Order"); they live in `/opt/pos/.env` (`POS_GLORIAFOOD_KEY`, put there by
`hubctl online key`, and `POS_GLORIAFOOD_PUSH_KEY`, by `hubctl online push key`) or, typed in the app, sealed
in the hub's database (`pos.keys`), and are never written to a log.

**A restaurant with several accounts** (`pos.online.accounts`) has a key for asking each, and the hub asks
each with its own (`GloriaFood.account`). A push does not say in so many words which account it is from,
but every order carries the key of the restaurant it was placed with (`restaurant_key`): before that key is
dropped it is held against the keys the hub asks with (`GloriaFood.owns`, `pushed_by`).
"""

from __future__ import annotations

import hmac
import json
import os
import re
from collections.abc import Callable, Mapping
from typing import Any

import httpx

from .accounts import MAIN

NAME = "gloriafood"
POP_URL = "https://pos.globalfoodsoft.com/pos/order/pop"
API_VERSION = "2"
TIMEOUT_SECONDS = 20.0
"""How long GloriaFood is waited for. Nobody stands waiting for this answer: the next minute asks again."""
BODY_KEPT = 200_000
"""How much of an answer that cannot be read is written down for a person to look at."""
SECRETS = frozenset({"restaurant_key", "restaurant_token"})
"""What every order carries of the restaurant's own account with GloriaFood. Dropped as the answer is read:
an order is written down for thirty days, and a key has no business in that."""
_SECRET_TEXT = re.compile(
    r'("restaurant_(?:key|token)"\s*:\s*)"[^"]*"|(<restaurant_(key|token)>)[^<]*(</restaurant_\3>)', re.IGNORECASE
)
PUSH_MOST = 2_000_000
"""The most a push may weigh, in bytes. An order is a few thousand; this is room for a busy minute's worth."""


class FetchFailed(Exception):
    """GloriaFood gave no orders this time, in words for a person. `body` is what it did send, when it sent
    something that could not be read: it may hold orders GloriaFood will not send again."""

    def __init__(self, reason: str, body: str | None = None) -> None:
        super().__init__(reason)
        self.reason = reason
        self.body = body


class GloriaFood:
    """The accepted orders of one restaurant on GloriaFood, asked for with that restaurant's key. `account`
    says which of the restaurant's accounts it is, where it has several."""

    name = NAME

    def __init__(
        self, key: str, *, account: str = MAIN, url: str = POP_URL, client: httpx.Client | None = None
    ) -> None:
        self._key = key
        self.account = account
        self._url = url
        self._client = client if client is not None else httpx.Client(timeout=TIMEOUT_SECONDS)

    def owns(self, order: Mapping[str, Any]) -> bool:
        """Whether an order as GloriaFood sent it is this account's: it carries the key this account is
        asked with. Compared in the same time whatever it carries."""
        told = order.get("restaurant_key")
        return isinstance(told, str) and bool(told) and _same(told, self._key)

    def same_as(self, other: object) -> bool:
        """Whether another source asks the same account with the same key: then what is known of how the
        asking goes still holds."""
        return isinstance(other, GloriaFood) and other.account == self.account and _same(other._key, self._key)

    def pop(self) -> list[dict[str, Any]]:
        """The orders accepted since the last time this was asked, as GloriaFood sends them. They are not
        sent a second time, so whoever calls this keeps them. The restaurant's own keys, which GloriaFood
        puts on every order, are left out (`SECRETS`)."""
        try:
            response = self._client.post(
                self._url,
                headers={"Authorization": self._key, "Accept": "application/json", "Glf-Api-Version": API_VERSION},
            )
        except httpx.TimeoutException:
            raise FetchFailed("GloriaFood did not answer in time") from None
        except httpx.HTTPError as err:
            raise FetchFailed(f"GloriaFood could not be reached ({type(err).__name__})") from None
        if response.status_code in (401, 403):
            raise FetchFailed("GloriaFood refused the key")
        if response.status_code == 429:
            raise FetchFailed("GloriaFood says it is asked too often")
        if response.status_code != 200:
            raise FetchFailed(f"GloriaFood answered with an error ({response.status_code})")
        return read(response.text)


def _same(one: str, other: str) -> bool:
    return hmac.compare_digest(one.strip().encode("utf-8"), other.encode("utf-8"))


def read(text: str, *, alone: bool = False) -> list[dict[str, Any]]:
    """The orders in what GloriaFood sent: `{"count": 1, "orders": [...]}`. Nothing at all, or a count of
    none, is no orders. `alone` is for a push, whose wrapping GloriaFood's pages do not spell out: one order
    by itself and a bare list of orders are read too, and what cannot be read is told of with its shape.
    `FetchFailed` for anything else, with what came."""
    return [_without_keys(order) for order in _orders(text, alone=alone)]


def _without_keys(order: Mapping[str, Any]) -> dict[str, Any]:
    return {name: value for name, value in order.items() if name not in SECRETS}


def _orders(text: str, *, alone: bool = False) -> list[Mapping[str, Any]]:
    """The orders in what GloriaFood sent, still as it sent them: the restaurant's own keys are on them.
    Nothing outside this module is handed these."""
    if not text.strip():
        return []

    def unread(shape: str) -> FetchFailed:
        reason = f"GloriaFood's push could not be read ({shape})" if alone else "GloriaFood's answer could not be read"
        return FetchFailed(reason, _kept(text))

    try:
        data = json.loads(text)
    except ValueError:
        xml = text.lstrip().startswith("<")
        raise unread("it came as XML, and the hub reads JSON" if xml else "it is not JSON") from None
    orders: Any = None
    if isinstance(data, Mapping):
        orders = data.get("orders")
        if orders is None and alone and "id" in data:
            orders = [data]  # one order by itself
        elif orders is None and data.get("count") in (0, None) and (not alone or not data or "count" in data):
            return []
    elif alone and isinstance(data, list):
        orders = data
    if not isinstance(orders, list) or not all(isinstance(order, Mapping) for order in orders):
        raise unread(_shape(data))
    return orders


def _shape(data: Any) -> str:
    """What came instead of orders, for whoever has to work out why: its kind and the names at its top,
    which are GloriaFood's own words and nothing of a customer."""
    if isinstance(data, Mapping):
        names = ", ".join(sorted(str(name)[:30] for name in data)[:12])
        return f"it holds no orders, but: {names}" if names else "it is empty"
    return f"it is a {type(data).__name__}, not orders"


def pushed(body: bytes) -> list[dict[str, Any]]:
    """The orders in a push, the restaurant's own keys left out. `FetchFailed` for one that cannot be read."""
    return [order for _, order in pushed_by(body, lambda order: "")]


def pushed_by(body: bytes, whose: Callable[[Mapping[str, Any]], str]) -> list[tuple[str, dict[str, Any]]]:
    """The orders in a push, each with the account it is from. `whose` is shown every order as GloriaFood
    sent it, the restaurant's own key still on it, and says the account (nothing when it cannot tell); the
    order is handed on without its keys, as always. `FetchFailed` for a push that cannot be read."""
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        raise FetchFailed("GloriaFood's push could not be read (it is not text)") from None
    return [(whose(order), _without_keys(order)) for order in _orders(text, alone=True)]


def allowed(given: str | None, key: str | None) -> bool:
    """Whether a push carries this restaurant's key: what came in the `Authorization` header is the key the
    hub was given, nothing more and nothing less. Never without a key on the hub. The comparison takes the
    same time whatever was sent, so the key cannot be felt out a letter at a time."""
    if not key or not given:
        return False
    return _same(given, key)


def _kept(text: str) -> str:
    """An answer that could not be read, as it is written down: its start, without the restaurant's keys."""

    def left_out(found: re.Match[str]) -> str:
        if found.group(1):
            return f'{found.group(1)}"(left out)"'
        return f"{found.group(2)}(left out){found.group(4)}"

    return _SECRET_TEXT.sub(left_out, text[:BODY_KEPT])


def source_from_env(environ: Mapping[str, str] | None = None) -> GloriaFood | None:
    """The restaurant's GloriaFood orders, when its key is on the hub (`POS_GLORIAFOOD_KEY`); None without
    one, and then nothing is asked of anybody."""
    env = os.environ if environ is None else environ
    key = (env.get("POS_GLORIAFOOD_KEY") or "").strip()
    return GloriaFood(key) if key else None


def push_key_from_env(environ: Mapping[str, str] | None = None) -> str | None:
    """The key GloriaFood's pushes must carry, when one is on the hub (`POS_GLORIAFOOD_PUSH_KEY`); None
    without one, and then every push is turned away."""
    env = os.environ if environ is None else environ
    return (env.get("POS_GLORIAFOOD_PUSH_KEY") or "").strip() or None
