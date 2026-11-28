"""Shipday's API as the hub asks it (https://docs.shipday.com/reference, read 2026-11-28).

Three questions, all of them reads:

- `GET /orders`: the active orders (every one that is not delivered, failed or marked incomplete), each
  with its customer, its driver when it has one, its times and where it stands.
- `GET /orders/{orderNumber}`: one order by the number it is known by, also when it is no longer active:
  what became of a delivery that left the list.
- `GET /carriers`: the drivers, each with whether they are on shift.
- `GET /order/progress/{trackingId}`: how many minutes away a delivery is. Shipday's pages say this one
  is "only available for customer having premium plans" and may be asked three times a minute for one
  order.

The key goes in the `Authorization` header as `Basic <key>`: the key itself after the word, which is how
Shipday's pages and its own client libraries send it (it is not a name and password). The same pages'
machine-readable part names a header `x-api-key` for it as well, so it is sent in both: the same key, to
the same place.

What leaves the building: the key, and for the second and fourth question a number Shipday itself gave.
Nothing of the POS.

Nothing here was ever tried against Shipday itself: it is written from its reference pages, which do not
agree with themselves everywhere, and tested against answers built from the examples on them.
"""

from __future__ import annotations

import hmac
import json
from typing import Any
from urllib.parse import quote

import httpx

NAME = "shipday"
BASE = "https://api.shipday.com"
TIMEOUT_SECONDS = 15.0
"""How long Shipday is waited for. Nobody stands waiting for this answer: the next round asks again."""

REFUSED, LIMIT, UNREACHABLE, SLOW, ERROR, UNREADABLE, NOT_FOUND = (
    "refused",
    "limit",
    "unreachable",
    "slow",
    "error",
    "unreadable",
    "not_found",
)
"""Why Shipday gave no answer: it refused the key; it is asked too often; it cannot be reached; it did not
answer in time; it answered with an error; its answer could not be read; it knows nothing by that number."""


class ShipdayFailed(Exception):
    """Shipday gave no answer this time: `reason` is one of the words above, `said` the same for a person.
    Never anything of the key, and never anything Shipday sent."""

    def __init__(self, reason: str, said: str) -> None:
        super().__init__(said)
        self.reason = reason
        self.said = said


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

    def _get(self, path: str, params: dict[str, str] | None = None) -> Any:
        try:
            response = self._client.get(
                f"{self._url}{path}",
                params=params,
                headers={"Authorization": f"Basic {self._key}", "x-api-key": self._key, "Accept": "application/json"},
            )
        except httpx.TimeoutException:
            raise ShipdayFailed(SLOW, "Shipday did not answer in time") from None
        except httpx.HTTPError as err:
            raise ShipdayFailed(UNREACHABLE, f"Shipday could not be reached ({type(err).__name__})") from None
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


__all__ = [
    "BASE",
    "ERROR",
    "LIMIT",
    "NAME",
    "NOT_FOUND",
    "REFUSED",
    "SLOW",
    "UNREACHABLE",
    "UNREADABLE",
    "Shipday",
    "ShipdayFailed",
]
