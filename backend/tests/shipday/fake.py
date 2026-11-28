"""A Shipday for the tests: it answers the hub's four questions from what a test put into it, in the shapes
Shipday's reference pages show (https://docs.shipday.com/reference, read 2026-11-28), and writes down every
call it was made. Nobody's account, nobody's key, and no customer who exists."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from urllib.parse import unquote

import httpx

from pos import localtime
from pos.shipday.client import Shipday

KEY = "MadeUpKey0.NobodysShipdayKey123456"
"""Shaped like the one on Shipday's pages: letters and digits with a dot in the middle."""
ELM = "12 Elm St, Winchester, MA 01890"
OAK = "4 Oak Rd, Winchester, MA 01890"
TRACK = "https://dispatch.shipday.com/trackingPage/"

TOM = {"id": 501, "name": "Tom Reyes", "phone": "+17815550150"}
WEI = {"id": 502, "name": "Wei Zhang", "phone": "+17815550151"}


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """That time of that day of November 2026 on the restaurant's own clock, as wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


def utc(ms: int | None) -> str | None:
    """A moment as Shipday's examples write one: UTC, and no zone said."""
    return None if ms is None else datetime.fromtimestamp(ms / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%S")


def carrier(who: dict[str, Any], *, on_shift: bool = True, active: bool = True) -> dict[str, Any]:
    """A driver as `GET /carriers` lists one, the misspelt names of where they are included."""
    return {
        "id": who["id"],
        "personalId": None,
        "name": who["name"],
        "codeName": "",
        "phoneNumber": who["phone"],
        "companyId": 9001,
        "areaId": 1,
        "isOnShift": on_shift,
        "email": "driver@example.com",
        "carrierPhoto": "https://example.com/photo.png",
        "isActive": active,
        "carrrierLocationLat": 42.4523,
        "carrrierLocationLng": -71.137,
    }


def order(
    ident: int,
    number: str,
    *,
    state: str = "NOT_ASSIGNED",
    name: str = "Linda Chen",
    address: str = ELM,
    phone: str = "+17815550101",
    driver: dict[str, Any] | None = None,
    placed: int | None = None,
    assigned: int | None = None,
    started: int | None = None,
    picked_up: int | None = None,
    arrived: int | None = None,
    delivered: int | None = None,
    wanted: int | None = None,
    eta: Any = "",
    total: float = 42.75,
    tracked: str | None = None,
    **more: Any,
) -> dict[str, Any]:
    """An order as `GET /orders` lists one (the "Delivery Order Object")."""
    due = None if wanted is None else datetime.fromtimestamp(wanted / 1000, UTC)
    return {
        "orderId": ident,
        "orderNumber": number,
        "companyId": 9001,
        "areaId": 1,
        "customer": {
            "name": name,
            "address": address,
            "phoneNumber": phone,
            "emailAddress": "customer@example.com",
            "latitude": 42.45,
            "longitude": -71.14,
        },
        "restaurant": {
            "id": 77,
            "name": "The restaurant",
            "address": "1 Main St, Winchester, MA 01890",
            "phoneNumber": "+17815550100",
            "latitude": 42.452,
            "longitude": -71.137,
        },
        "assignedCarrier": None
        if driver is None
        else {**carrier(driver), "carrrierLocationLat": None, "carrrierLocationLng": None},
        "distance": 2.4,
        "activityLog": {
            "placementTime": utc(placed if placed is not None else at(18)),
            "expectedPickupTime": None,
            "expectedDeliveryDate": None if due is None else f"{due:%Y-%m-%d}",
            "expectedDeliveryTime": None if due is None else f"{due:%H:%M:%S}",
            "assignedTime": utc(assigned),
            "startTime": utc(started),
            "pickedUpTime": utc(picked_up),
            "arrivedTime": utc(arrived),
            "deliveryTime": utc(delivered),
        },
        "costing": {
            "totalCost": total,
            "deliveryFee": 4.0,
            "tip": 5,
            "discountAmount": 0.0,
            "tax": 2.61,
            "cashTip": 0.0,
        },
        "paymentMethod": "credit_card",
        "orderItems": [{"name": "Egg Roll", "quantity": 2, "unitPrice": 3.5}, {"name": "Lo Mein", "quantity": 1}],
        "assignedCarrierId": None if driver is None else driver["id"],
        "orderStatus": {"incomplete": state == "INCOMPLETE", "accepted": driver is not None, "orderState": state},
        "trackingLink": None if tracked is None else f"{TRACK}{tracked}&lang=en",
        "feedback": None,
        "schedule": False,
        "parentId": 0,
        "etaTime": eta,
        "deliveryInstruction": "Side door",
        **more,
    }


class FakeShipday:
    """`orders` is the list of active ones; `finished` what it says of an order asked for by number once
    it is active no longer; `carriers` its drivers; `progress` what it says of a delivery by its tracking
    id (an answer, or the status it refuses with). `fail` makes every call fail: a status, or an error of
    the network. Every call is written down in `calls`, and what each carried in `sent`."""

    def __init__(self) -> None:
        self.orders: list[dict[str, Any]] = []
        self.finished: dict[str, dict[str, Any]] = {}
        self.carriers: list[dict[str, Any]] = []
        self.progress: dict[str, dict[str, Any] | int] = {}
        self.fail: int | Exception | None = None
        self.unknown = 200  # what it answers for a number it has nothing by: an empty list, or this status
        self.calls: list[str] = []
        self.sent: list[httpx.Request] = []

    def _answer(self, request: httpx.Request) -> httpx.Response:
        # as it went over the wire: a number with a slash in it must not read as two pieces of a path
        self.calls.append(f"{request.method} {request.url.raw_path.decode('ascii').split('?')[0]}")
        self.sent.append(request)
        if isinstance(self.fail, Exception):
            raise self.fail
        if self.fail is not None:
            return httpx.Response(self.fail, json={})
        path = unquote(request.url.path)
        if request.method != "GET":
            return httpx.Response(405, json={})
        if path == "/orders":
            return httpx.Response(200, json=self.orders)
        if path == "/carriers":
            return httpx.Response(200, json=self.carriers)
        if path.startswith("/orders/"):
            number = path.removeprefix("/orders/")
            listed = self.orders if isinstance(self.orders, list) else [self.orders]
            found = [each for each in listed if isinstance(each, dict) and each.get("orderNumber") == number]
            if number in self.finished:
                found.append(self.finished[number])
            if not found and self.unknown != 200:
                return httpx.Response(self.unknown, json={})
            return httpx.Response(200, json=found)
        if path.startswith("/order/progress/"):
            told = self.progress.get(path.removeprefix("/order/progress/"), 400)
            return httpx.Response(told, json={}) if isinstance(told, int) else httpx.Response(200, json=told)
        return httpx.Response(404, json={})

    def source(self, key: str = KEY) -> Shipday:
        return Shipday(key, client=httpx.Client(transport=httpx.MockTransport(self._answer)))

    def asked(self, path: str) -> int:
        """How often that was asked."""
        return self.calls.count(f"GET {path}")


def minutes_away(minutes: float | str) -> dict[str, Any]:
    """What `GET /order/progress/{trackingId}` answers for a delivery that many minutes away."""
    return {
        "fixedData": None,
        "dynamicData": {
            "orderStatus": {"startTime": None, "pickedTime": None, "status": "PICKED_UP"},
            "carrierLocation": {"latitude": 42.46, "longitude": -71.13},
            "estimatedTimeInMinutes": str(minutes),
            "detailEta": {
                "estimatedTimeInMinutes": float(minutes) if minutes != "INF" else -1.0,
                "pickUpTime": 0.0,
                "travelDistance": 2.4,
                "travelDistanceTime": 9.0,
                "deliveryTime": 9.0,
                "orderPosition": -1,
                "startedOrder": -1,
                "calprog": "",
            },
        },
    }
