"""Shipday's API as the hub asks it (https://docs.shipday.com/reference, read 2026-11-28).

Four questions, which change nothing:

- `GET /orders`: the active orders (every one that is not delivered, failed or marked incomplete), each
  with its customer, its driver when it has one, its times and where it stands.
- `GET /orders/{orderNumber}`: one order by the number it is known by, also when it is no longer active:
  what became of a delivery that left the list.
- `GET /carriers`: the drivers, each with whether they are on shift.
- `GET /order/progress/{trackingId}`: how many minutes away a delivery is. Shipday's pages say this one
  is "only available for customer having premium plans" and may be asked three times a minute for one
  order.

And two changes, each made only when a person at a terminal asked for exactly that (`pos.api.shipday`):

- `PUT /orders/assign/{orderId}/{carrierId}`: gives an order to a driver. Shipday tells the driver.
- `PUT /orders/unassign/{orderId}`: takes it back from whoever has it.

Both go by Shipday's own id of the order (`orderId`), never by the number it is known by, and carry nothing
else: no body, nothing of the POS.

The key goes in the `Authorization` header as `Basic <key>`: the key itself after the word, which is how
Shipday's pages and its own client libraries send it (it is not a name and password). The same pages'
machine-readable part names a header `x-api-key` for it as well, so it is sent in both: the same key, to
the same place.

What leaves the building: the key, and ids and numbers Shipday itself gave. Nothing of the POS.

Nothing here was ever tried against Shipday itself: it is written from its reference pages, which do not
agree with themselves everywhere, and tested against answers built from the examples on them.
"""

from __future__ import annotations

import hmac
import json
import re
from collections.abc import Mapping
from typing import Any
from urllib.parse import quote

import httpx

NAME = "shipday"
BASE = "https://api.shipday.com"
TIMEOUT_SECONDS = 15.0
"""How long Shipday is waited for. Nobody stands waiting for this answer: the next round asks again."""

REFUSED, LIMIT, UNREACHABLE, SLOW, ERROR, UNREADABLE, NOT_FOUND, REJECTED = (
    "refused",
    "limit",
    "unreachable",
    "slow",
    "error",
    "unreadable",
    "not_found",
    "rejected",
)
"""Why Shipday gave no answer: it refused the key; it is asked too often; it cannot be reached; it did not
answer in time; it answered with an error; its answer could not be read; it knows nothing by that number.
And of a change: it answered, and did not make it."""

TOLD_MAX = 160
_UNPRINTABLE = re.compile(r"[^\x20-\x7e\u00a0-\uffff]")
_TOLD_BY = ("response", "message", "errorMessage", "error", "detail")
"""Where an answer of Shipday's that refuses a change may say why. Its pages show none: these are the names
its answers to an order that was added carry, and the usual ones."""


class ShipdayFailed(Exception):
    """Shipday gave no answer this time, or would not make a change: `reason` is one of the words above,
    `said` the same for a person. Never anything of the key. `told` is what Shipday itself said of a change
    it would not make, as one short line, for the person who asked for the change and for nobody else: it is
    never written to a log."""

    def __init__(self, reason: str, said: str, *, told: str = "") -> None:
        super().__init__(said)
        self.reason = reason
        self.said = said
        self.told = told


def _told(data: Any) -> str:
    """What an answer of Shipday's says in words, where it says anything: one line, not long."""
    if not isinstance(data, Mapping):
        return ""
    for name in _TOLD_BY:
        value = data.get(name)
        if isinstance(value, str) and value.strip():
            return " ".join(_UNPRINTABLE.sub(" ", value).split())[:TOLD_MAX]
    return ""


class Shipday:
    """One restaurant's account with Shipday, asked with that restaurant's key."""

    name = NAME

    def __init__(self, key: str, *, url: str = BASE, client: httpx.Client | None = None) -> None:
        self._key = key
        self._url = url.rstrip("/")
        self._client = client if client is not None else httpx.Client(timeout=TIMEOUT_SECONDS)

    def same_as(self, other: object) -> bool:
        """Whether another one asks with the same key: then what is known of how the asking goes still holds."""
        return isinstance(other, Shipday) and hmac.compare_digest(other._key.encode(), self._key.encode())

    def _sent(self, method: str, path: str, params: dict[str, str] | None = None) -> httpx.Response:
        """One call, and Shipday's answer whatever it is; `ShipdayFailed` where there is none."""
        try:
            return self._client.request(
                method,
                f"{self._url}{path}",
                params=params,
                headers={"Authorization": f"Basic {self._key}", "x-api-key": self._key, "Accept": "application/json"},
            )
        except httpx.TimeoutException:
            raise ShipdayFailed(SLOW, "Shipday did not answer in time") from None
        except httpx.HTTPError as err:
            raise ShipdayFailed(UNREACHABLE, f"Shipday could not be reached ({type(err).__name__})") from None

    def _get(self, path: str, params: dict[str, str] | None = None) -> Any:
        response = self._sent("GET", path, params)
        code = response.status_code
        if code in (401, 403):
            raise ShipdayFailed(REFUSED, "Shipday refused the key")
        if code == 429:
            raise ShipdayFailed(LIMIT, "Shipday says it is asked too often")
        if code == 404:
            raise ShipdayFailed(NOT_FOUND, "Shipday knows nothing by that number")
        if code != 200:
            raise ShipdayFailed(ERROR, f"Shipday answered with an error ({code})")
        try:
            return json.loads(response.text) if response.text.strip() else None
        except ValueError:
            raise ShipdayFailed(UNREADABLE, "Shipday's answer could not be read") from None

    def _change(self, path: str) -> None:
        """One change, asked for with `PUT` and nothing in it. It is made when Shipday answers that it is
        (any 2xx that does not say `success` false); anything else is `ShipdayFailed`, with what Shipday
        said of it where it said anything (`told`). An answer that did not come in time says nothing of
        whether the change was made: whoever asked looks at the list again."""
        response = self._sent("PUT", path)
        code = response.status_code
        try:
            data = json.loads(response.text) if response.text.strip() else None
        except ValueError:
            data = None
        if code in (401, 403):
            raise ShipdayFailed(REFUSED, "Shipday refused the key", told=_told(data))
        if code == 429:
            raise ShipdayFailed(LIMIT, "Shipday says it is asked too often")
        if code == 404:
            raise ShipdayFailed(NOT_FOUND, "Shipday knows nothing by that number", told=_told(data))
        if 400 <= code < 500:
            raise ShipdayFailed(REJECTED, f"Shipday would not do it ({code})", told=_told(data))
        if not 200 <= code < 300:
            raise ShipdayFailed(ERROR, f"Shipday answered with an error ({code})")
        if isinstance(data, Mapping) and data.get("success") is False:
            raise ShipdayFailed(REJECTED, "Shipday would not do it", told=_told(data))

    def _listed(self, path: str) -> list[dict[str, Any]]:
        """An answer that is a list of things: Shipday's pages show a bare list. One thing by itself is read
        as a list of one, and nothing at all as none. Whatever in it is not a thing is left out."""
        data = self._get(path)
        if data is None:
            return []
        if isinstance(data, dict):
            data = [data]
        if not isinstance(data, list):
            raise ShipdayFailed(UNREADABLE, "Shipday's answer could not be read")
        return [row for row in data if isinstance(row, dict)]

    def active_orders(self) -> list[dict[str, Any]]:
        """The orders that are not finished yet, as Shipday sends them."""
        return self._listed("/orders")

    def order(self, number: str) -> dict[str, Any] | None:
        """One order by the number it is known by (Shipday's `orderNumber`), finished or not; None when
        Shipday has none by it. Where it has several by one number, the one it lists last."""
        try:
            found = self._listed(f"/orders/{quote(number, safe='')}")
        except ShipdayFailed as err:
            if err.reason == NOT_FOUND:
                return None
            raise
        return found[-1] if found else None

    def carriers(self) -> list[dict[str, Any]]:
        """The drivers, as Shipday sends them."""
        return self._listed("/carriers")

    def progress(self, tracking_id: str) -> dict[str, Any]:
        """How one delivery is coming along, by the id its tracking page has: how many minutes away it is.
        `ShipdayFailed` with `refused` from an account whose plan does not have this."""
        data = self._get(f"/order/progress/{quote(tracking_id, safe='')}", {"isStaticDataRequired": "false"})
        if not isinstance(data, dict):
            raise ShipdayFailed(UNREADABLE, "Shipday's answer could not be read")
        return data

    def assign(self, order_id: int, carrier_id: int) -> None:
        """Gives an order to a driver, by Shipday's own ids of both. Shipday tells the driver."""
        self._change(f"/orders/assign/{int(order_id)}/{int(carrier_id)}")

    def unassign(self, order_id: int) -> None:
        """Takes an order back from whoever has it, by Shipday's own id of it."""
        self._change(f"/orders/unassign/{int(order_id)}")


__all__ = [
    "BASE",
    "ERROR",
    "LIMIT",
    "NAME",
    "NOT_FOUND",
    "REFUSED",
    "REJECTED",
    "SLOW",
    "UNREACHABLE",
    "UNREADABLE",
    "Shipday",
    "ShipdayFailed",
]
