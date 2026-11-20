"""The orders customers placed on the restaurant's GloriaFood site, fetched once they are accepted.

GloriaFood hands accepted orders to a POS in two ways (its "Accepted orders" API, version 2). A hub sits
behind the restaurant's router, so it uses the one made for that: it asks. Every minute the hub sends one
request, with the key of this restaurant in a header and nothing else, and GloriaFood answers with the orders
that were accepted since it was last asked (`{"count": 1, "orders": [...]}`). GloriaFood keeps an order for
as long as nobody asks; once it has answered with it, it does not send it again. So the hub writes down
every order it is given before it does anything else with it (`pos.online.inbox`).

What leaves the building: the key, in the `Authorization` header. No order, no customer, nothing of the
POS. The key is this integration's own ("Poll Accepted Order v2" among the restaurant's integrations in
GloriaFood's admin); it lives in `/opt/pos/.env` (`POS_GLORIAFOOD_KEY`, put there by `hubctl online key`)
and is never written to a log.
"""

from __future__ import annotations

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
_SECRET_TEXT = re.compile(r'("restaurant_(?:key|token)"\s*:\s*)"[^"]*"')


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
        text = response.text
        if not text.strip():
            return []
        try:
            data = response.json()
        except ValueError:
            raise FetchFailed("GloriaFood's answer could not be read", _kept(text)) from None
        orders = data.get("orders") if isinstance(data, Mapping) else None
        if orders is None and isinstance(data, Mapping) and data.get("count") in (0, None):
            return []
        if not isinstance(orders, list) or not all(isinstance(order, Mapping) for order in orders):
            raise FetchFailed("GloriaFood's answer could not be read", _kept(text))
        return [{name: value for name, value in order.items() if name not in SECRETS} for order in orders]


def _kept(text: str) -> str:
    """An answer that could not be read, as it is written down: its start, without the restaurant's keys."""
    return _SECRET_TEXT.sub(r'\1"(left out)"', text[:BODY_KEPT])


def source_from_env(environ: Mapping[str, str] | None = None) -> GloriaFood | None:
    """The restaurant's GloriaFood orders, when its key is on the hub (`POS_GLORIAFOOD_KEY`); None without
    one, and then nothing is asked of anybody."""
    env = os.environ if environ is None else environ
    key = (env.get("POS_GLORIAFOOD_KEY") or "").strip()
    return GloriaFood(key) if key else None
