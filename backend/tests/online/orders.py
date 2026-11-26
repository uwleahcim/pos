"""Online orders for the tests, shaped as GloriaFood's "Accepted orders" API (version 2) sends them and
made from the menu export the hub's own menu was imported from, so their ids are the real ones. The
customers are made up."""

from __future__ import annotations

import json
from decimal import Decimal
from functools import cache
from typing import Any

from pos.menu.gloriafood import BUNDLED

CENT = Decimal("0.01")


@cache
def export() -> dict[str, Any]:
    return json.loads(BUNDLED.read_text())


def dish(name: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """A dish of the online menu and its category, by a piece of its name."""
    for category in export()["categories"]:
        for item in category["items"]:
            if name.lower() in item["name"].lower():
                return item, category
    raise KeyError(name)


def groups_of(item: dict[str, Any], category: dict[str, Any], size: dict[str, Any] | None) -> list[dict[str, Any]]:
    return [*(category.get("groups") or ()), *(item.get("groups") or ()), *((size or {}).get("groups") or ())]


_ids = iter(range(240_000_000, 250_000_000))


def row(
    name: str,
    qty: int = 1,
    *,
    size: str | None = None,
    choose: tuple[str | tuple[str, int], ...] = (),
    instructions: str = "",
    **more: Any,
) -> dict[str, Any]:
    """One dish of an order: `size` by name, `choose` the choices by a piece of their names (with how many,
    as a pair); every required choice not named takes its first option, as the website's form starts."""
    item, category = dish(name)
    sizes = item.get("sizes") or []
    picked = next((s for s in sizes if s["name"].lower() == (size or "").lower()), None) if size else None
    if picked is None and sizes:
        picked = next((s for s in sizes if s.get("default")), sizes[0])
    options: list[dict[str, Any]] = []
    if picked is not None:
        options.append(
            {
                "id": next(_ids),
                "name": picked["name"],
                "price": picked["price"],
                "group_name": "Size",
                "quantity": 1,
                "type": "size",
                "type_id": picked["id"],
            }
        )
    wanted = [(c, 1) if isinstance(c, str) else c for c in choose]
    for group in groups_of(item, category, picked):
        taken = [(o, n) for o in group["options"] for piece, n in wanted if piece.lower() in o["name"].lower()]
        if not taken and group.get("required"):
            taken = [(option, 1) for option in group["options"][: max(1, group.get("force_min") or 1)]]
        for option, n in taken:
            options.append(
                {
                    "id": next(_ids),
                    "name": option["name"],
                    "price": option["price"],
                    "group_name": group["name"],
                    "quantity": n,
                    "type": "option",
                    "type_id": option["id"],
                }
            )
    unit = Decimal(str(item["price"])) + sum((Decimal(str(o["price"])) * o["quantity"] for o in options), Decimal(0))
    return {
        "id": next(_ids),
        "name": item["name"],
        "total_item_price": float((unit * qty).quantize(CENT)),
        "price": item["price"],
        "quantity": qty,
        "instructions": instructions,
        "type": "item",
        "type_id": item["id"],
        "tax_rate": 0.07,
        "tax_value": 0,
        "parent_id": None,
        "item_discount": 0,
        "cart_discount_rate": 0,
        "cart_discount": 0,
        "tax_type": "NET",
        "options": options,
        **more,
    }


def extra(kind: str, amount: float, name: str | None = None, **more: Any) -> dict[str, Any]:
    """A row that is no dish: `delivery_fee`, `tip`, `promo_cart`, `service_fee_subtotal`, ..."""
    return {
        "id": next(_ids),
        "name": name or kind.upper(),
        "total_item_price": amount,
        "price": amount,
        "quantity": 1,
        "instructions": None,
        "type": kind,
        "type_id": None,
        "parent_id": None,
        "item_discount": 0,
        "cart_discount_rate": 0,
        "cart_discount": 0,
        "tax_type": "NET",
        "options": [],
        **more,
    }


def money(rows: list[dict[str, Any]], *, taxed_fee: bool = False) -> dict[str, Any]:
    """The totals GloriaFood sends with these rows, at the 7% it charges on the dishes: tax rounded once."""
    dishes = [r for r in rows if r["type"] == "item"]
    food = sum((Decimal(str(r["total_item_price"])) for r in dishes), Decimal(0))
    off = sum(
        (abs(Decimal(str(r["item_discount"]))) + abs(Decimal(str(r["cart_discount"]))) for r in dishes), Decimal(0)
    )
    fee = sum((Decimal(str(r["total_item_price"])) for r in rows if r["type"] == "delivery_fee"), Decimal(0))
    tip = sum((Decimal(str(r["total_item_price"])) for r in rows if r["type"] == "tip"), Decimal(0))
    base = food - off + (fee if taxed_fee else Decimal(0))
    tax = (base * Decimal("0.07")).quantize(CENT)
    taxes = [{"type": "item", "value": float(((food - off) * Decimal("0.07")).quantize(CENT)), "rate": 0.07}]
    if taxed_fee:
        taxes.append({"type": "delivery_fee", "value": float((fee * Decimal("0.07")).quantize(CENT)), "rate": 0.07})
    return {
        "sub_total_price": float(food - off),
        "tax_value": float(tax),
        "tax_type": "NET",
        "tax_name": "Sales Tax",
        "tax_list": taxes,
        "total_price": float(food - off + fee + tip + tax),
    }


def order(
    number: int,
    rows: list[dict[str, Any]],
    *,
    kind: str = "pickup",
    payment: str = "CASH",
    accepted: str = "2027-01-15T23:00:00.000Z",
    fulfill: str = "2027-01-15T23:25:00.000Z",
    taxed_fee: bool = False,
    **more: Any,
) -> dict[str, Any]:
    """An accepted order as the API hands it over. The customer is nobody: the address is not a real one."""
    delivery = kind == "delivery"
    return {
        "id": number,
        "api_version": 2,
        "type": kind,
        "status": "accepted",
        "source": "website",
        "payment": payment,
        "accepted_at": accepted,
        "fulfill_at": fulfill,
        "updated_at": accepted,
        "for_later": False,
        "persons": 0,  # how many sit down, for a table that is booked: nothing for a pickup or a delivery
        "instructions": None,
        "restaurant_id": 1,
        "restaurant_name": "The Restaurant",
        "restaurant_timezone": "America/New_York",
        "restaurant_key": "not-a-real-key",
        "restaurant_token": "not-a-real-token",
        "currency": "USD",
        "client_id": 7,
        "client_first_name": "Pat",
        "client_last_name": "Example",
        "client_email": "pat@example.com",
        "client_phone": "+1 781 555 0142",
        "client_address": "1 Restaurant Row, Winchester" if delivery else None,
        "client_address_parts": {"street": "1 Restaurant Row", "city": "Winchester", "apartment": "3B"}
        if delivery
        else None,
        "client_marketing_consent": True,
        "client_language": "en",
        "fulfillment_option": None,
        # every way it was paid, as GloriaFood names them: one, or two for a payment that was split
        "used_payment_methods": [payment],
        "latitude": "42.45" if delivery else None,
        "longitude": "-71.13" if delivery else None,
        "coupons": [],
        "items": rows,
        **money(rows, taxed_fee=taxed_fee),
        **more,
    }


def reservation(
    number: int,
    guests: int = 4,
    *,
    at: str = "2027-01-16T00:30:00.000Z",
    kind: str = "table_reservation",
    rows: list[dict[str, Any]] | None = None,
    **more: Any,
) -> dict[str, Any]:
    """A table booked on the website, as the API hands it over: an order with no dishes (or, as an
    `order_ahead`, with the dishes ordered ahead), how many they are in `persons`, and the time the table is
    for in `fulfill_at` (half past seven on the evening of `tests.online.hub.NOW` unless told otherwise)."""
    return order(number, rows or [], kind=kind, fulfill=at, for_later=True, persons=guests, **more)
