"""What a delivery costs the customer: a fee by how far it goes, or by how long the drive is (docs/delivery.md).

The location lists its own prices (the `delivery_fee` setting, `pos.settings.clean_delivery_fee`): whether it
charges at all (off to start, so nothing is added to anybody's check until the owner says what it is),
whether it goes by miles or by the minutes of the drive, and its bands in order, each "up to so far, this
much". The band a delivery falls in is picked when the order is taken.

What was picked is an order field, `delivery_fee`, set like any field (`set_field`), so a hub that does not
know it simply keeps nothing. A screen says only which band: `{"up_to": "2.5"}`, or `{"up_to": null}` for
no fee on purpose (a regular, a mistake of the restaurant's), or nothing at all to take the answer back. The
hub fills in the rest before it is stored (`fee_ops`), as it prices a dish: what that band costs now, what it
goes by and whether the fee is taxed. So an order keeps the fee it was given when the prices change later,
and no screen can make up an amount. A band the location does not list is left out and reported, like a
refused discount.

With a map service on the hub (`pos.maps`) the form asks how far the address is and picks the band for it
(`band_for`); whoever takes the order can still tap another. What the map said then travels with the pick,
`{"up_to": "4.5", "measured": {"miles": "3.2", "minutes": 9}}`, and is kept beside the fee, so the history of
a check shows a fee that was picked against the map. It is what the screen was told, kept as a note: it
never changes what the band costs.

The check charges it only while the order is a delivery (`pos.orders.check`): one changed to pickup keeps
what was picked and is charged nothing. It is a charge of its own on the check and on the bill, "Delivery
fee", and it is in the sales with the other charges; it is never a gratuity, and nothing here says who the
money goes to.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import replace
from decimal import Decimal, InvalidOperation
from typing import Any

from ..sync.oplog import ORDER_FIELDS, Op, is_delivery

FIELD = "delivery_fee"
CHARGE_ID = "fee:delivery"
"""The fee's row among a check's charges. Not `delivery_fee`: that is a charge rule's code in the pricing
rules, and a rule's code on a row means the rule put it there."""
CHARGE_NAME = "Delivery fee"
TAX_CLASS = "delivery_fee"
"""What a taxed fee is taxed as: by the profile's own rule for it, else by its default rule."""
MEASURES = ("miles", "minutes")
MILES_MAX = Decimal(100)
MINUTES_MAX = Decimal(240)
FEE_MAX = Decimal("999.99")
BANDS_MAX = 8
"""One screenful of buttons on a phone, beside "No fee"."""
ZERO = Decimal(0)
CENT = Decimal("0.01")
TENTH = Decimal("0.1")
MEASURED_MILES_MAX = Decimal(1000)
MEASURED_MINUTES_MAX = 24 * 60
"""What the map may have said and still be kept: further is no delivery."""


def measure(value: Any, by: str) -> Decimal | None:
    """How far a band reaches, read: miles to a tenth, whole minutes, above nothing and within reason. None
    when it is no such number."""
    if isinstance(value, bool) or not isinstance(value, int | float | str | Decimal):
        return None
    try:
        number = Decimal(str(value).strip())
    except InvalidOperation:
        return None
    if not number.is_finite() or number <= ZERO:
        return None
    step, most = (TENTH, MILES_MAX) if by == "miles" else (Decimal(1), MINUTES_MAX)
    if number > most or number != number.quantize(step):
        return None
    return number


def measure_text(number: Decimal) -> str:
    """A band's reach as it is stored and compared: "2", "2.5", "10"."""
    return format(number.normalize(), "f")


def money(value: Any) -> Decimal | None:
    """A fee, read: dollars and cents, nothing below zero. None when it is no such amount."""
    if isinstance(value, bool) or not isinstance(value, int | float | str | Decimal):
        return None
    try:
        amount = Decimal(str(value).strip())
    except InvalidOperation:
        return None
    if not amount.is_finite() or amount < ZERO or amount > FEE_MAX or amount != amount.quantize(CENT):
        return None
    return amount.quantize(CENT)


def band_of(setting: Mapping[str, Any], up_to: Any) -> dict[str, str] | None:
    """The band of the location's list that reaches `up_to`, or None: no such band, or no fee is charged."""
    by = setting.get("by")
    reach = measure(up_to, by) if by in MEASURES else None
    if reach is None or setting.get("enabled") is not True:
        return None
    for band in setting.get("bands") or ():
        if measure(band.get("up_to"), by) == reach:
            return {"up_to": measure_text(reach), "fee": str(band["fee"])}
    return None


def band_for(setting: Mapping[str, Any], miles: Decimal, minutes: int) -> dict[str, str] | None:
    """The band a delivery this far falls in: the nearest one of the location's list that reaches it. None
    when it is further than the last band reaches, or no fee is charged."""
    by = setting.get("by")
    if setting.get("enabled") is not True or by not in MEASURES:
        return None
    far = miles if by == "miles" else Decimal(minutes)
    reaches = [(measure(band.get("up_to"), by), band) for band in setting.get("bands") or ()]
    for reach, band in sorted(((r, b) for r, b in reaches if r is not None), key=lambda entry: entry[0]):
        if far <= reach:
            return {"up_to": measure_text(reach), "fee": str(band["fee"])}
    return None


def measured_of(value: Any) -> dict[str, Any] | None:
    """What the map said of a delivery, as a pick carries it: `{"miles": "3.2", "minutes": 9}`. None when
    the pick carries none, or it cannot be read."""
    told = value.get("measured") if isinstance(value, Mapping) else None
    if not isinstance(told, Mapping):
        return None
    miles, minutes = told.get("miles"), told.get("minutes")
    if isinstance(miles, bool) or not isinstance(miles, int | float | str | Decimal):
        return None
    if isinstance(minutes, bool) or not isinstance(minutes, int) or not 0 < minutes <= MEASURED_MINUTES_MAX:
        return None
    try:
        far = Decimal(str(miles).strip())
    except InvalidOperation:
        return None
    if not far.is_finite() or far < ZERO or far > MEASURED_MILES_MAX or far != far.quantize(TENTH):
        return None
    return {"miles": format(far.quantize(TENTH), "f"), "minutes": minutes}


def fee_of(fields: Mapping[str, Any]) -> dict[str, Any] | None:
    """What an order carries of its delivery fee, or None while nobody said: `amount` (dollars, "0.00" for
    no fee on purpose), `by` and `up_to` (the band it was picked by; None with no fee), `taxed`, and, only
    when the map was asked, `measured`: what it said of the address when the fee was picked."""
    value = fields.get(FIELD)
    if not isinstance(value, Mapping):
        return None
    amount = money(value.get("amount"))
    if amount is None:
        return None
    by = value.get("by")
    reach = measure(value.get("up_to"), by) if by in MEASURES else None
    measured = measured_of(value)
    told = {} if measured is None else {"measured": measured}
    if reach is None:
        return {"by": None, "up_to": None, "amount": "0.00", "taxed": False, **told} if amount == ZERO else None
    return {"by": by, "up_to": measure_text(reach), "amount": str(amount), "taxed": value.get("taxed") is True, **told}


def fee_charged(fields: Mapping[str, Any]) -> dict[str, Any] | None:
    """The fee to put on this order's check, or None: it is charged only while the order is a delivery, and
    only when there is something to charge."""
    fee = fee_of(fields)
    if fee is None or not is_delivery(fields) or Decimal(fee["amount"]) <= ZERO:
        return None
    return fee


def fee_ops(setting: Callable[[], Mapping[str, Any]], ops: list[Op]) -> tuple[list[Op], list[dict[str, Any]]]:
    """Fill in every newly picked fee before it is stored: the band's price as the location lists it now,
    what it goes by and whether it is taxed. A band the location does not list is left out and reported;
    whatever else its operation says of the order goes through without it. `setting` reads the location's
    `delivery_fee` setting, and is asked only when an operation picks a band."""
    if not any(_picks(op) for op in ops):
        return ops, []
    listed: Mapping[str, Any] | None = None
    kept: list[Op] = []
    refused: list[dict[str, Any]] = []
    for op in ops:
        if _picks(op):
            data = dict(op.data)
            wanted = data[FIELD]
            problem = None
            if wanted is None or wanted is False:
                data[FIELD] = None  # the answer taken back: nobody said what the delivery costs
            elif not isinstance(wanted, Mapping):
                problem = "a delivery fee names the band it was picked by"
            elif wanted.get("up_to") is None:
                data[FIELD] = {"up_to": None, "amount": "0.00"}  # no fee, on purpose
                if (told := measured_of(wanted)) is not None:
                    data[FIELD]["measured"] = told
            else:
                listed = setting() if listed is None else listed
                band = band_of(listed, wanted["up_to"])
                if band is None:
                    problem = (
                        "no delivery fee is charged here"
                        if listed.get("enabled") is not True
                        else f"no delivery fee is listed for up to {wanted['up_to']} {listed.get('by')}"
                    )
                else:
                    data[FIELD] = {
                        "by": listed["by"],
                        "up_to": band["up_to"],
                        "amount": band["fee"],
                        "taxed": listed.get("taxed") is True,
                    }
                    if (told := measured_of(wanted)) is not None:
                        data[FIELD]["measured"] = told
            if problem:
                refused.append({"op_id": op.op_id, "error": "invalid_delivery_fee", "message": problem})
                del data[FIELD]
                if op.kind != "create" and not any(name in ORDER_FIELDS for name in data):
                    continue  # it said nothing else of the order
            op = replace(op, data=data)
        kept.append(op)
    return kept, refused


def _picks(op: Op) -> bool:
    return op.kind in ("create", "set_field") and FIELD in op.data


__all__ = [
    "BANDS_MAX",
    "CHARGE_ID",
    "CHARGE_NAME",
    "FEE_MAX",
    "FIELD",
    "MEASURES",
    "MILES_MAX",
    "MINUTES_MAX",
    "TAX_CLASS",
    "band_for",
    "band_of",
    "fee_charged",
    "fee_of",
    "fee_ops",
    "measure",
    "measure_text",
    "measured_of",
    "money",
]
