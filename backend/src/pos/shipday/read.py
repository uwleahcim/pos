"""What Shipday answers, turned into what the hub tells a screen.

Shipday's order (its "Delivery Order Object") is read into a flat thing with the hub's own names, and its
driver ("Carrier") likewise. Whatever is missing, null or of another kind than its pages say is left out
rather than guessed: the pages' own examples carry an empty `etaTime`, a null `orderItems` and a null
`assignedCarrierId` where the words beside them say `-1`.

**Times.** Shipday's pages say every time of an order's `activityLog` is UTC, and their examples carry no
zone ("2019-11-29T11:43:59"): a time without one is read as UTC. The time a delivery is wanted for comes in
two parts, a day and a time of day (`expectedDeliveryDate`, `expectedDeliveryTime`), read as UTC too.

**Where an order stands** is Shipday's own word (`orderStatus.orderState`), kept as it is: `NOT_ASSIGNED`,
`NOT_ACCEPTED` (given to a driver who has not accepted it), `NOT_STARTED_YET` (accepted), `STARTED`,
`PICKED_UP`, `READY_TO_DELIVER`, `ALREADY_DELIVERED`, `FAILED_DELIVERY`, `INCOMPLETE`. A word that is none
of these is `UNKNOWN`: a screen says so and guesses nothing.

**When it arrives.** `etaTime` is a string Shipday's pages give no form for. One that reads as a moment is
`eta_ms`; anything else that is short enough is handed on as Shipday wrote it (`eta_said`).
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from datetime import UTC, date, datetime, time
from decimal import Decimal, InvalidOperation
from typing import Any
from urllib.parse import parse_qsl, urlsplit

NOT_ASSIGNED, NOT_ACCEPTED, NOT_STARTED_YET = "NOT_ASSIGNED", "NOT_ACCEPTED", "NOT_STARTED_YET"
STARTED, PICKED_UP, READY_TO_DELIVER = "STARTED", "PICKED_UP", "READY_TO_DELIVER"
ALREADY_DELIVERED, FAILED_DELIVERY, INCOMPLETE = "ALREADY_DELIVERED", "FAILED_DELIVERY", "INCOMPLETE"
UNKNOWN = "UNKNOWN"
GONE = "GONE"
"""Not Shipday's word: an order that left the list of active ones, of which Shipday did not say what became."""

ACTIVE = (NOT_ASSIGNED, NOT_ACCEPTED, NOT_STARTED_YET, STARTED, PICKED_UP, READY_TO_DELIVER)
FINISHED = (ALREADY_DELIVERED, FAILED_DELIVERY, INCOMPLETE)
STATES = (*ACTIVE, *FINISHED)

NAME_MAX, ADDRESS_MAX, PHONE_MAX, NOTE_MAX, NUMBER_MAX, SAID_MAX, LINK_MAX = 80, 200, 40, 200, 60, 30, 400
_CLOCK = re.compile(r"^(\d{1,2}):(\d{2})(?::(\d{2}))?$")
_PRINTABLE = re.compile(r"[^\x20-\x7e -￿]")


def _line(value: Any, most: int) -> str:
    """A word or a line of Shipday's as one line of text, no longer than `most`; nothing for what is none."""
    if not isinstance(value, str | int | float) or isinstance(value, bool):
        return ""
    return " ".join(_PRINTABLE.sub(" ", str(value)).split())[:most]


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str) and value.strip().lstrip("-").isdigit():
        return int(value.strip())
    return None


def _money(value: Any) -> str | None:
    """An amount as Shipday sends one (a number, or a number written out), to the cent; None for none."""
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        return None
    try:
        amount = Decimal(str(value).strip())
    except InvalidOperation:
        return None
    if not amount.is_finite():
        return None
    return str(amount.quantize(Decimal("0.01")))


def moment(value: Any) -> int | None:
    """A moment as Shipday writes one, in wall-clock ms: a time of day with its day ("2019-11-29T11:43:59",
    with or without a zone; without one it is UTC), or a count of milliseconds or seconds since 1970."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        if not math.isfinite(value) or value <= 0:
            return None
        # ten digits are seconds, thirteen are milliseconds
        return int(value) if value >= 100_000_000_000 else int(value * 1000) if value >= 1_000_000_000 else None
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.isdigit():
        return moment(int(text))
    try:
        at = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=UTC)
    return int(at.timestamp() * 1000)


def _wanted(log: Mapping[str, Any]) -> int | None:
    """When a delivery is wanted for: Shipday's day and time of day for it, both UTC."""
    day, clock = log.get("expectedDeliveryDate"), log.get("expectedDeliveryTime")
    if not isinstance(day, str) or not isinstance(clock, str):
        return None
    found = _CLOCK.match(clock.strip())
    if found is None:
        return moment(clock)  # a whole moment where the pages say a time of day
    try:
        on = date.fromisoformat(day.strip()[:10])
        at = time(int(found.group(1)), int(found.group(2)), int(found.group(3) or 0))
    except ValueError:
        return None
    return int(datetime.combine(on, at, UTC).timestamp() * 1000)


def _driver(raw: Any) -> dict[str, Any] | None:
    """The driver an order names (`assignedCarrier`): who it is, and the number to call."""
    if not isinstance(raw, Mapping):
        return None
    ident = _int(raw.get("id"))
    if ident is None or ident < 0:
        return None
    return {"id": ident, "name": _line(raw.get("name"), NAME_MAX), "phone": _line(raw.get("phoneNumber"), PHONE_MAX)}


def state_of(raw: Mapping[str, Any]) -> str:
    """Where an order stands, in Shipday's own word, or `UNKNOWN` for one it does not say or says otherwise."""
    status = raw.get("orderStatus")
    word = status.get("orderState") if isinstance(status, Mapping) else status
    word = word.strip().upper() if isinstance(word, str) else ""
    return word if word in STATES else UNKNOWN


def order_of(raw: Mapping[str, Any]) -> dict[str, Any] | None:
    """One order of Shipday's as a screen is told it; None for something without Shipday's own id.

    `id` is what Shipday changes an order by and `number` what it finds one by; `state` is where it stands;
    `name`, `address`, `phone` are the customer's; `driver` is who has it (`id`, `name`, `phone`) or null;
    the times are wall-clock ms or null: `placed_ms`, `due_ms` (when it is wanted for), `assigned_ms`,
    `started_ms`, `picked_up_ms`, `arrived_ms`, `delivered_ms`; `eta_ms` or `eta_said` is when Shipday
    expects it there; `total`, `fee`, `tip` are amounts as text, `payment` Shipday's word for how it is
    paid; `items` how many dishes it lists; `note` what the driver is told; `tracking` the customer's
    tracking page; `scheduled` whether it was placed for later."""
    ident = _int(raw.get("orderId"))
    if ident is None:
        return None
    customer = raw.get("customer") if isinstance(raw.get("customer"), Mapping) else {}
    log = raw.get("activityLog") if isinstance(raw.get("activityLog"), Mapping) else {}
    costing = raw.get("costing") if isinstance(raw.get("costing"), Mapping) else {}
    driver = _driver(raw.get("assignedCarrier"))
    if driver is None:
        carrier = _int(raw.get("assignedCarrierId"))
        if carrier is not None and carrier > 0:
            driver = {"id": carrier, "name": "", "phone": ""}  # named by the list of drivers (`ShipdayBoard`)
    items = raw.get("orderItems")
    dishes = 0
    if isinstance(items, list):
        for item in items:
            qty = _int(item.get("quantity")) if isinstance(item, Mapping) else None
            dishes += qty if qty is not None and 0 < qty < 1000 else 1
    eta_text = raw.get("etaTime")
    # a time of day by itself says no day and no zone: it is handed on as written, never reckoned with
    eta_ms = None if isinstance(eta_text, str) and _CLOCK.match(eta_text.strip()) else moment(eta_text)
    link = raw.get("trackingLink")
    tracking = link.strip() if isinstance(link, str) and link.strip().lower().startswith("https://") else ""
    return {
        "id": ident,
        "number": _line(raw.get("orderNumber"), NUMBER_MAX),
        "state": state_of(raw),
        "name": _line(customer.get("name"), NAME_MAX),
        "address": _line(customer.get("address"), ADDRESS_MAX),
        "phone": _line(customer.get("phoneNumber"), PHONE_MAX),
        "driver": driver,
        "placed_ms": moment(log.get("placementTime")),
        "due_ms": _wanted(log),
        "assigned_ms": moment(log.get("assignedTime")),
        "started_ms": moment(log.get("startTime")),
        "picked_up_ms": moment(log.get("pickedUpTime")),
        "arrived_ms": moment(log.get("arrivedTime")),
        "delivered_ms": moment(log.get("deliveryTime")),
        "eta_ms": eta_ms,
        "eta_said": "" if eta_ms is not None else _line(eta_text, SAID_MAX),
        "total": _money(costing.get("totalCost")),
        "fee": _money(costing.get("deliveryFee")),
        "tip": _money(costing.get("tip")),
        "payment": _line(raw.get("paymentMethod"), 24).upper(),
        "items": dishes,
        "note": _line(raw.get("deliveryInstruction"), NOTE_MAX),
        "tracking": tracking[:LINK_MAX],
        "scheduled": raw.get("schedule") is True,
    }


def driver_of(raw: Mapping[str, Any]) -> dict[str, Any] | None:
    """One driver of Shipday's as a screen is told them: `id`, `name`, `phone`, whether they are on shift
    now (`on_shift`) and whether the account lets them take orders at all (`active`). None for something
    without an id. Where they were last seen is not handed on: no screen shows a map."""
    ident = _int(raw.get("id"))
    if ident is None or ident < 0:
        return None
    return {
        "id": ident,
        "name": _line(raw.get("name"), NAME_MAX) or _line(raw.get("codeName"), NAME_MAX),
        "phone": _line(raw.get("phoneNumber"), PHONE_MAX),
        "on_shift": raw.get("isOnShift") is True,
        "active": raw.get("isActive") is not False,
    }


def minutes_of(progress: Mapping[str, Any]) -> int | None:
    """How many minutes away a delivery is, by Shipday's own reckoning (`GET /order/progress`): its
    `detailEta.estimatedTimeInMinutes`, where `-1` means it has none, else the figure beside it, which it
    writes as text and as "INF" when it has none. None for none, and for a figure no drive takes."""
    live = progress.get("dynamicData")
    if not isinstance(live, Mapping):
        return None
    detail = live.get("detailEta")
    figures = [detail.get("estimatedTimeInMinutes") if isinstance(detail, Mapping) else None]
    figures.append(live.get("estimatedTimeInMinutes"))
    for figure in figures:
        if isinstance(figure, str):
            try:
                figure = float(figure.strip())
            except ValueError:
                continue
        if isinstance(figure, bool) or not isinstance(figure, int | float) or not math.isfinite(figure):
            continue
        if 0 <= figure <= 24 * 60:
            return math.ceil(figure)
    return None


def tracking_id(link: str) -> str | None:
    """The id of a delivery's tracking page, which `GET /order/progress` is asked by. Shipday's pages do not
    say where it is found. This reads it off the customer's tracking link: a part of the link's question
    whose name has "track" in it, else the last piece of its path, up to any "&". A guess, said so in
    docs/shipday.md; None for a link it finds nothing in."""
    try:
        parts = urlsplit(link.strip())
    except ValueError:
        return None
    for name, value in parse_qsl(parts.query):
        if "track" in name.lower() and value.strip():
            return value.strip()[:300]
    piece = parts.path.rstrip("/").rsplit("/", 1)[-1].split("&", 1)[0].strip()
    return piece[:300] if len(piece) >= 6 else None


__all__ = [
    "ACTIVE",
    "ALREADY_DELIVERED",
    "FAILED_DELIVERY",
    "FINISHED",
    "GONE",
    "INCOMPLETE",
    "NOT_ACCEPTED",
    "NOT_ASSIGNED",
    "NOT_STARTED_YET",
    "PICKED_UP",
    "READY_TO_DELIVER",
    "STARTED",
    "STATES",
    "UNKNOWN",
    "driver_of",
    "minutes_of",
    "moment",
    "order_of",
    "state_of",
    "tracking_id",
]
