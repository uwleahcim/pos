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

What leaves the building: the key the hub asks with, in the `Authorization` header. No order, no customer,
nothing of the POS. Both keys are this restaurant's own integrations in GloriaFood's admin ("Poll Accepted
Order v2" and "Push Accepted Order"); they live in `/opt/pos/.env` (`POS_GLORIAFOOD_KEY`, put there by
`hubctl online key`, and `POS_GLORIAFOOD_PUSH_KEY`, by `hubctl online push key`) and are never written to a
log.
"""

from __future__ import annotations

import hmac
import json
import os
import re
from collections.abc import Mapping
from typing import Any

import httpx

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
    """The accepted orders of one restaurant on GloriaFood, asked for with that restaurant's key."""

    name = NAME

    def __init__(self, key: str, *, url: str = POP_URL, client: httpx.Client | None = None) -> None:
        self._key = key
        self._url = url
        self._client = client if client is not None else httpx.Client(timeout=TIMEOUT_SECONDS)

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


def read(text: str, *, alone: bool = False) -> list[dict[str, Any]]:
    """The orders in what GloriaFood sent: `{"count": 1, "orders": [...]}`. Nothing at all, or a count of
    none, is no orders. `alone` is for a push, whose wrapping GloriaFood's pages do not spell out: one order
    by itself and a bare list of orders are read too, and what cannot be read is told of with its shape.
    `FetchFailed` for anything else, with what came."""
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
    return [{name: value for name, value in order.items() if name not in SECRETS} for order in orders]


def _shape(data: Any) -> str:
    """What came instead of orders, for whoever has to work out why: its kind and the names at its top,
    which are GloriaFood's own words and nothing of a customer."""
    if isinstance(data, Mapping):
        names = ", ".join(sorted(str(name)[:30] for name in data)[:12])
        return f"it holds no orders, but: {names}" if names else "it is empty"
    return f"it is a {type(data).__name__}, not orders"


def pushed(body: bytes) -> list[dict[str, Any]]:
    """The orders in a push, the restaurant's own keys left out. `FetchFailed` for one that cannot be read."""
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        raise FetchFailed("GloriaFood's push could not be read (it is not text)") from None
    return read(text, alone=True)


def allowed(given: str | None, key: str | None) -> bool:
    """Whether a push carries this restaurant's key: what came in the `Authorization` header is the key the
    hub was given, nothing more and nothing less. Never without a key on the hub. The comparison takes the
    same time whatever was sent, so the key cannot be felt out a letter at a time."""
    if not key or not given:
        return False
    return hmac.compare_digest(given.strip().encode("utf-8"), key.encode("utf-8"))


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
