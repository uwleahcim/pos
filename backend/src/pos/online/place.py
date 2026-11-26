"""An online order, as GloriaFood gave it, turned into what the POS writes for an order of its own.

`ops_for` reads one accepted order (`pos.online.gloriafood`) and gives the operations that put it on the
POS as a to-go order: who it is for and when, its dishes, what the customer was charged, and the `fire`
that sends it to the kitchen. Nothing here stores or prints: the hub does that with what comes back
(`pos.api.online`), as it does with a screen's operations.

**What becomes an order.** An order GloriaFood says was accepted, for pickup or for delivery. A table
reservation, an order placed from a table, one that was not accepted: `NotAnOrder`, with why. They stay
where they are, in GloriaFood's own app. So does one that nobody at the restaurant has answered yet
(`WAITS`): GloriaFood hands it over again when it is accepted, and then it is an order
(`pos.online.inbox.Inbox.again`). What GloriaFood says of an order after it is on the POS (it was marked
ready, it was cancelled) is `pos.online.after`.

**The dishes.** The menu on the POS was imported from GloriaFood's and kept its ids (`pos.menu.gloriafood`):
a dish knows GloriaFood's number for it, a size and a choice are coded by theirs. So a dish sold online is
found by those, never by guessing at names first, and it goes on the check as the same dish a server rings
in: same name, same kitchen label, same station. A choice whose id the menu no longer has (the rolls of a
combination are the POS's own dishes) is found by its name among that dish's choices, and then by its
number, which GloriaFood and the POS count alike. A dish that cannot be found, or whose choices the menu
will not take, goes on **as written**: under the name and with the choices GloriaFood sent, at the station
of the dish when the dish is known. Nothing is ever left off an order.

A restaurant with a second website at GloriaFood (`pos.online.accounts`) has its dishes numbered a second
time there: the same dish has another number on each. So a dish whose number the menu does not have is
looked for by its name, and taken when exactly one dish on the POS is called that (its menu number, where it
has one, picks between two of a name). Its size and its choices are then found as above.

**Which account.** `origin` says which of the restaurant's accounts the order came from, in the hub's own
words: the account, the name the restaurant gave it, and that it is the one for testing. They are kept on
the order beside GloriaFood's number (`online.account`, `online.store`, `online.test`), for the screens and
the tickets to say.

**The prices are GloriaFood's.** The customer was shown a price and agreed to it, and the dining room's
prices can differ from the website's. So every dish carries what it cost online, whatever the POS's menu
says; the POS's own price is kept beside it when it differs (`priced.online.menu_price`).

**The money.** A promotion is a discount on the dish it was given on, or on the check; the delivery fee is
the order's delivery fee; the tip is a gratuity, never taxed; a service fee is a charge. What the POS's own
rules would add by themselves to a to-go order is left off: the customer was not charged it. Then the check
is reckoned as the POS reckons any check, and compared with GloriaFood's total. When they differ, a row of
its own makes the check come to what the customer was charged, in the open: "Rounding" for a few cents (the
POS rounds the state's and the town's tax each by itself, GloriaFood rounds 7% once: a cent apart on about
one order in four), "Online total difference" for more (a row this module does not know), and that one is
reported for a person to look at. An order paid on the website is recorded as paid, on the day, as money
taken outside the POS; one to be paid at the door is not.

**An order that reaches the hub late.** GloriaFood keeps an accepted order until the hub asks, so a hub
that was off, or had no internet, is given what it missed all at once. An order whose time has not come is
put on the POS and sent to the kitchen as ever. One whose time passed more than a quarter of an hour ago
goes on the POS, for the check and the day's sales, and is **not** sent to the kitchen: the food is cooked
or it was never wanted, and a ticket now would have it cooked twice. One whose time has passed and that
was accepted on an earlier day is not put on the POS at all (`NotAnOrder`, `old`): it would count in the
wrong day's sales. It is reported, never dropped quietly, and it is in GloriaFood's own records.

**An order that reaches the hub made.** One GloriaFood says was marked ready in its own app before the hub
ever had it (`ready`: the hub was off, and the restaurant worked from GloriaFood's app) goes on the POS for
the check, as ready, and is not sent to the kitchen either (`MADE`).

Nothing of the customer but the name, the number, the address of a delivery and what they wrote is put on
the order: no e-mail, no card, no consent to marketing.
"""

from __future__ import annotations

import math
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, replace
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any

from .. import localtime
from ..menu.defs import Definitions, Item, Variant
from ..menu.gloriafood import split_number
from ..menu.service import MenuService
from ..orders.adjustments import PricingRules
from ..orders.check import UNTAXED
from ..orders.day import PAID_ONLINE
from ..orders.delivery_fee import ONLINE
from ..sync.hlc import HLC
from ..sync.oplog import Op, OrderState, replay
from .gloriafood import NAME
from .inbox import ACCEPTED, PENDING, status_of

DEVICE = "online"
"""The device an online order's operations are written by, and the node of the clock that stamps them."""
BY = "Online order"
PROMOTION = "Online promotion"
DIFFERENCE = "Online total difference"
ROUNDED = "Rounding"
"""The row for a difference of a few cents: two ways of rounding the same tax."""
ORDER_TYPES = ("pickup", "delivery")
WAITS = "it waits to be accepted in GloriaFood's app"
"""What is said of an order that was handed over before anybody at the restaurant answered it."""
NOT_ACCEPTED = {
    PENDING: WAITS,
    "rejected": "it was rejected in GloriaFood's app",
    "canceled": "it was cancelled in GloriaFood",
    "cancelled": "it was cancelled in GloriaFood",
}
"""What is said of an order that is not for the POS, by GloriaFood's word for what became of it."""
MISSED = "it was missed: nobody answered it in GloriaFood's app in time"
MISSED_UNREACHED = "it was missed: GloriaFood could not reach its app at the restaurant"
"""The two ways GloriaFood says an order went unanswered (`timed_out`, with `missed_reason`)."""
MADE = "it was already marked ready in GloriaFood's app"
"""What is said of an order that reaches the hub made: it is not sent to the kitchen a second time."""
KEPT_WORDS = {
    "table_reservation": "a table reservation",
    "order_ahead": "a table booked with its dishes ordered ahead",
    "dine_in": "an order placed from a table",
}
SOLD_ANYWAY = frozenset({"none_left", "sold_out", "inactive", "option_hidden"})
"""What the menu says against a dish that does not stop an online order: it was sold, and somebody accepted it."""
PROMOTIONS = frozenset({"promo_cart", "promo_item", "promo_cart_item"})
SERVICE_FEES = frozenset({"service_fee_subtotal", "service_fee_total"})
HOW = {
    "no_contact": "No contact: leave it at the door",
    "meet_rider": "Meets the driver outside",
    "curbside_pickup": "Curbside pickup",
    "outside_venue": "Picks up outside",
}
"""How the customer wants it handed over, in words, where that is not the usual way."""
ADDRESS_PARTS = (("apartment", "Apt"), ("floor", "Floor"), ("bloc", "Building"), ("intercom", "Intercom"))
QUOTED_MAX = 24 * 60
NOTE_MAX = 300
NAME_MAX = 80
ZERO = Decimal(0)
CENT = Decimal("0.01")
ROUNDING = Decimal("0.05")
"""A difference up to this is two ways of rounding the same tax; more is something to look at."""
LATE_MS = 15 * 60_000
"""How long after its time an order can reach the hub and still be sent to the kitchen."""
UNTIMED_MS = 60 * 60_000
"""For an order that names no time: how long after it was accepted its time is taken to be."""


class NotAnOrder(Exception):
    """What came is nothing the POS takes as an order. `reason` says why, for a person. `old` for an order
    the POS would have taken had it come in time: somebody should know of it."""

    def __init__(self, reason: str, *, old: bool = False) -> None:
        super().__init__(reason)
        self.reason = reason
        self.old = old


def unaccepted(order: Mapping[str, Any]) -> NotAnOrder | None:
    """Why an order is nothing for the POS yet, or at all, by what GloriaFood says became of it: one that
    still waits to be accepted, one that was turned down, missed or cancelled. None for an accepted one."""
    status = status_of(order)
    if status == ACCEPTED:
        return None
    if status == "timed_out":
        # GloriaFood says why nobody answered: its app at the restaurant was not reached, or was and waited
        unreached = str(order.get("missed_reason") or "").upper() == "NO_CONNECTION"
        return NotAnOrder(MISSED_UNREACHED if unreached else MISSED)
    return NotAnOrder(NOT_ACCEPTED.get(status) or f"it was not accepted ({status})")


class CannotPlace(Exception):
    """An order that should go on the POS and cannot be read well enough to. `reason` says why."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class Placed:
    """An online order as the POS will write it."""

    order_id: str
    ops: tuple[Op, ...]
    as_written: tuple[str, ...] = ()  # the dishes that went on under GloriaFood's own name
    difference: Decimal = ZERO  # GloriaFood's total less what the POS reckoned, before the row that evens them
    notes: tuple[str, ...] = ()  # whatever else a person should know of it
    late: bool = False  # it reached the hub after its time, or made: on the POS, not sent to the kitchen

    @property
    def look(self) -> bool:
        """Whether a person should look at it: a dish as written, or a difference beyond rounding."""
        return bool(self.as_written) or abs(self.difference) > ROUNDING or bool(self.notes)

    @property
    def said(self) -> str:
        """What is told of it, in words; nothing when it went on exactly."""
        parts = []
        if self.as_written:
            dishes = ", ".join(self.as_written)
            parts.append(f"{_many(len(self.as_written), 'dish', 'dishes')} went on as written ({dishes})")
        if abs(self.difference) > ROUNDING:
            more = "more" if self.difference > 0 else "less"
            parts.append(f"GloriaFood's total is ${abs(self.difference)} {more} than the POS reckoned")
        return "; ".join([*parts, *self.notes])


def own_word(op: Op) -> Op:
    """An operation as a screen may send it: without `online`, which says where an order came from and is
    the hub's alone to write."""
    if op.kind in ("create", "set_field") and "online" in op.data:
        return replace(op, data={name: value for name, value in op.data.items() if name != "online"})
    return op


def ext_id_of(order: Mapping[str, Any]) -> str | None:
    """GloriaFood's own number for an order, as text; None for something that has none."""
    value = order.get("id")
    if isinstance(value, bool) or not isinstance(value, int | str) or not str(value).strip():
        return None
    return str(value).strip()


def order_id_for(ext_id: str) -> str:
    """The POS order an online order becomes: always the same one, so an order given twice is one order."""
    return f"gf-{ext_id}"


def hidden(order: Mapping[str, Any]) -> dict[str, Any]:
    """An order as it came with everything of the customer taken out, for a person to look at its shape:
    the name, number, e-mail, address and where the customer is are gone, and so is whatever they wrote."""

    def scrub(value: Any, key: str = "") -> Any:
        private = key.startswith(("client_", "billing")) or key in _PRIVATE
        if isinstance(value, Mapping):
            return "(hidden)" if private else {str(k): scrub(v, str(k)) for k, v in value.items()}
        if isinstance(value, list):
            return "(hidden)" if private else [scrub(v, key) for v in value]
        if value in (None, ""):
            return value
        return "(hidden)" if private or key == "instructions" else value

    return {str(k): scrub(v, str(k)) for k, v in order.items()}


_PRIVATE = frozenset(
    {
        "latitude",
        "longitude",
        "card_type",
        "gateway_transaction_id",
        "reference",
        "coupons",
        "coupon",
        "restaurant_key",
        "restaurant_token",
        "unreadable",  # an answer that could not be read, kept whole: whatever is in it
    }
)


def ops_for(
    order: Mapping[str, Any],
    menu: MenuService,
    *,
    stamp: Callable[[], HLC],
    check_of: Callable[[OrderState], Mapping[str, Any]],
    rules: PricingRules | None = None,
    minutes: Mapping[str, Any] | None = None,
    now_ms: int,
    origin: Mapping[str, Any] | None = None,
) -> Placed:
    """The operations that put this order on the POS. `stamp` stamps each one, `check_of` reckons a check
    as the hub does, `rules` are the location's own charges, `minutes` its quoted minutes by channel (for an
    order the customer wants later: how long before its time the kitchen gets it), `origin` which of the
    restaurant's accounts it came from (`account`, `store`: its name, `test`)."""
    ext_id = ext_id_of(order)
    if ext_id is None:
        raise NotAnOrder("it has no number")
    kind = str(order.get("type") or "")
    refused = unaccepted(order)
    if refused is not None:
        raise refused
    if kind not in ORDER_TYPES:
        raise NotAnOrder(f"it is {KEPT_WORDS.get(kind, f'of a kind the POS does not take ({kind})')}")
    if str(order.get("tax_type") or "NET").upper() == "GROSS":
        raise NotAnOrder("its prices have the tax in them, which this POS does not take")
    rows = [row for row in order.get("items") or () if isinstance(row, Mapping)]
    dishes = [row for row in rows if _kind(row) == "item"]
    if not dishes:
        raise CannotPlace("it has no dishes")
    late = _late(order, now_ms)
    made_already = order.get("ready") is True  # in GloriaFood's app, before the hub ever had it

    order_id = order_id_for(ext_id)
    delivery = kind == "delivery"
    notes: list[str] = []
    made: list[Op] = []

    def write(name: str, op_kind: str, data: dict[str, Any]) -> None:
        made.append(Op(f"{order_id}:{name}", order_id, stamp(), DEVICE, op_kind, data))

    total = _money(order.get("total_price"))
    fee = sum((_charged(row) for row in rows if _kind(row) == "delivery_fee"), ZERO)
    fields: dict[str, Any] = {
        "order_type": "takeout",
        "channel": "online",
        "stage": "ready" if made_already else "new",
        "customer_name": _name_of(order),
        "phone": _line(order.get("client_phone"), 40),
        **_times(order, minutes or {}, delivery=delivery, now_ms=now_ms),
        **(_delivery(order, fee) if delivery else {}),
        "note": _note(order, delivery=delivery),
        "online": {**_about(order, ext_id, kind, total), **_origin(origin or {})},
    }
    locale = str(order.get("client_language") or "")[:2].lower()
    if locale.isalpha() and len(locale) == 2:
        fields["locale"] = locale
    write("create", "create", {name: value for name, value in fields.items() if value not in ("", None)})

    # the dishes, each with what came off it by a promotion
    matcher = _Matcher(menu)
    promotions = {str(row.get("id")): _line(row.get("name"), NAME_MAX) for row in rows if _kind(row) in PROMOTIONS}
    as_written: list[str] = []
    cart_off = ZERO
    for n, row in enumerate(dishes, start=1):
        qty = _qty(row.get("quantity"))
        unit = _unit(row, qty)
        if unit is None:
            unit = ZERO
            notes.append(f"{_dish_name(row)} came with no price")
        line_id = f"{order_id}-{n}"
        priced, request = matcher.priced(row, unit)
        if priced is None:
            priced = matcher.as_written(row, unit)
            as_written.append(priced["name"])
        data: dict[str, Any] = {"line_id": line_id, "item": priced["name"], "qty": qty, "priced": priced, "by": BY}
        if request is not None:
            data["request"] = request
        if said := _line(row.get("instructions"), NOTE_MAX):
            data["note"] = said
        write(f"line-{n}", "add_line", data)
        off = min(abs(_money(row.get("item_discount")) or ZERO), unit * qty)
        if off > ZERO:
            write(
                f"off-{n}",
                "discount",
                {
                    "discount_id": f"{order_id}:off-{n}",
                    "reason": PROMOTION,
                    "kind": "amount",
                    "value": str(off),
                    "line_id": line_id,
                    "note": promotions.get(str(row.get("parent_id")), ""),
                    "applied_by": BY,
                },
            )
        cart_off += abs(_money(row.get("cart_discount")) or ZERO)
    if cart_off == ZERO:  # said once, on the promotion's own row, and not shared out over the dishes
        cart_off = sum((abs(_money(r.get("cart_discount")) or ZERO) for r in rows if _kind(r) in PROMOTIONS), ZERO)
    cart_off += sum((abs(_money(r.get("total_item_price")) or ZERO) for r in rows if _kind(r) == "cash_discount"), ZERO)
    if cart_off > ZERO:
        named = [name for name in dict.fromkeys(promotions.values()) if name]
        named += [f"coupon {_line(code, 40)}" for code in order.get("coupons") or () if isinstance(code, str | int)]
        write(
            "off",
            "discount",
            {
                "discount_id": f"{order_id}:off",
                "reason": PROMOTION,
                "kind": "amount",
                "value": str(cart_off),
                "note": ", ".join(named)[:NOTE_MAX],
                "applied_by": BY,
            },
        )

    # what the customer was charged beside the dishes
    if fee > ZERO and not delivery:
        write(
            "fee", "charge", _charge(order_id, "fee", "online_fee", "Delivery fee", fee, _taxed(order, "delivery_fee"))
        )
    tip = sum((_charged(row) for row in rows if _kind(row) == "tip"), ZERO)
    if tip > ZERO:
        tipped = _charge(order_id, "tip", "online_tip", "Tip", tip, taxed=False)
        write("tip", "charge", {**tipped, "tax_class": "gratuity", "gratuity": True})
    for n, row in enumerate((row for row in rows if _kind(row) in SERVICE_FEES), start=1):
        amount = _charged(row)
        if amount > ZERO:
            listed = "service_fee_total" if _kind(row) == "service_fee_total" else "fees_discounts_subtotal"
            name = _line(row.get("name"), NAME_MAX).replace("_", " ").capitalize() or "Service fee"
            taxed = _taxed(order, listed, default=True)
            write(
                f"service-{n}", "charge", _charge(order_id, f"service-{n}", "online_service_fee", name, amount, taxed)
            )
    unknown = sorted({_kind(row) for row in rows} - KNOWN)
    if unknown:
        notes.append(f"it has rows of a kind this POS does not know ({', '.join(unknown)})")
    # what the POS's own rules would add to a to-go order by themselves: the customer was not charged it
    for rule in (rules or PricingRules()).charges.values():
        if rule.applies("takeout", None):
            write(f"no-{rule.code}", "remove_charge", {"charge_id": rule.code, "code": rule.code})

    # the POS's check against GloriaFood's total: a difference is a row of its own, never a quiet change
    difference = ZERO
    if total is None:
        notes.append("GloriaFood gave no total for it")
    else:
        reckoned = _money(check_of(replay(made, order_id)).get("total")) or ZERO
        difference = total - reckoned
        if difference:
            small = abs(difference) <= ROUNDING
            code, name = ("online_rounding", ROUNDED) if small else ("online_difference", DIFFERENCE)
            write("difference", "charge", _charge(order_id, "difference", code, name, difference, False))

    ways = _ways_paid(order)
    if "ONLINE" in ways and total is not None and total > ZERO:
        if ways == {"ONLINE"}:
            write(
                "paid",
                "pay",
                {
                    "payment_id": f"{order_id}:paid",
                    "method": "elsewhere",
                    "amount": str(total),
                    "note": PAID_ONLINE,  # the words the reports know the website's money by
                    "by": BY,
                },
            )
        elif ways <= WAYS_TO_PAY:
            notes.append("it was paid in more than one way on the website: GloriaFood says what is still to collect")
        else:
            notes.append("how it was paid on the website cannot be read: GloriaFood says what is still to collect")
    unsent = late or (MADE if made_already else "")
    if unsent:
        notes.append(f"{unsent}: it is on the POS for the check and was not sent to the kitchen")
    else:
        write("fire", "fire", {"course": "*", "by": BY})
    return Placed(order_id, tuple(made), tuple(as_written), difference, tuple(notes), late=bool(unsent))


KNOWN = frozenset({"item", "delivery_fee", "tip", "cash_discount"}) | PROMOTIONS | SERVICE_FEES


# --- the order's own fields ---------------------------------------------------------------------


WAYS_TO_PAY = frozenset({"ONLINE", "CASH", "CARD", "CARD_PHONE"})
"""How an order is paid, in GloriaFood's words: on the website, or at the door in cash, by card, or by a card
read out over the phone."""


def _ways_paid(order: Mapping[str, Any]) -> set[str]:
    """Every way an order was paid, in GloriaFood's words, upper case: its one `payment`, and those it lists
    in `used_payment_methods`. That is a list of the same words: one as a rule (`["ONLINE"]` for a card, a
    wallet or PayPal on the website, whichever it was), two for a payment that was split. What is listed in
    a shape this does not know stays in as it came, so it is never taken for money the website took."""
    listed = order.get("used_payment_methods")
    if not isinstance(listed, list | tuple):
        listed = [listed]
    return {str(way).strip().upper() for way in (order.get("payment"), *listed) if way not in (None, "")}


def _name_of(order: Mapping[str, Any]) -> str:
    first, last = _line(order.get("client_first_name"), 40), _line(order.get("client_last_name"), 40)
    return f"{first} {last}".strip() or "Online order"


def _about(order: Mapping[str, Any], ext_id: str, kind: str, total: Decimal | None) -> dict[str, Any]:
    """What the order keeps of where it came from: GloriaFood's number for it, how the customer chose to pay
    and what they were charged. With these a check can be set beside GloriaFood's own list."""
    about: dict[str, Any] = {"source": NAME, "id": ext_id, "type": kind}
    payment = _line(order.get("payment"), 24).upper()
    if payment:
        about["payment"] = payment
    if total is not None:
        about["total"] = str(total)
    return about


def _origin(origin: Mapping[str, Any]) -> dict[str, Any]:
    """Which of the restaurant's accounts an order came from, as the order keeps it: nothing that was not
    said, so an order of a restaurant with one unnamed account reads as it always did."""
    about: dict[str, Any] = {}
    if account := _line(origin.get("account"), 12):
        about["account"] = account
    if store := _line(origin.get("store"), NAME_MAX):
        about["store"] = store
    if origin.get("test") is True:
        about["test"] = True
    return about


def _ms(value: Any) -> int | None:
    """A time as GloriaFood writes one ("2026-11-20T23:41:49.000Z"), in wall-clock ms."""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        at = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if at.tzinfo is None:
        return None
    return int(at.timestamp() * 1000)


def _clock(ms: int) -> str:
    """A moment on the restaurant's own clock, for a person: "18:25", with the day when it is not today."""
    at = datetime.fromtimestamp(ms / 1000, localtime.zone())
    return f"{at:%H:%M}" if at.date() == localtime.now().date() else f"{at:%H:%M} on {at:%b} {at.day}"


def _late(order: Mapping[str, Any], now_ms: int) -> str:
    """Why this order is not sent to the kitchen, in words, when it reached the hub after its time; nothing
    for one that came in time. Raises `NotAnOrder` for one from an earlier day."""
    promised, accepted = _ms(order.get("fulfill_at")), _ms(order.get("accepted_at"))
    due = promised if promised is not None else None if accepted is None else accepted + UNTIMED_MS
    if due is None or now_ms <= due + LATE_MS:
        return ""
    if accepted is not None and localtime.service_day_of(accepted) != localtime.service_day_of(now_ms):
        day = localtime.service_day_of(accepted)
        raise NotAnOrder(
            f"it was accepted on {day:%b} {day.day} and reached the hub after its time: it is in GloriaFood's "
            "own records and was not put on today's sales",
            old=True,
        )
    return f"it reached the hub after its time ({_clock(due)})"


def _times(order: Mapping[str, Any], minutes: Mapping[str, Any], *, delivery: bool, now_ms: int) -> dict[str, Any]:
    """When it is wanted, and how long before that the kitchen gets it. An order for as soon as possible
    was promised its time when it was accepted: the kitchen gets it now. One the customer wants later waits
    on the hub until the location's own minutes before its time, like an order taken ahead by phone."""
    promised = _ms(order.get("fulfill_at"))
    if promised is None:
        return {}
    if order.get("for_later") is True:
        lead = minutes.get("delivery" if delivery else "online")
        quoted = lead if isinstance(lead, int) and not isinstance(lead, bool) and lead > 0 else None
        told: dict[str, Any] = {"promised_at": promised, "for_later": True}
        return told if quoted is None else {**told, "quoted_minutes": quoted}
    accepted = _ms(order.get("accepted_at")) or now_ms
    quoted = max(1, min(QUOTED_MAX, math.ceil((promised - min(accepted, now_ms)) / 60_000)))
    return {"promised_at": promised, "quoted_minutes": quoted}


def _delivery(order: Mapping[str, Any], fee: Decimal) -> dict[str, Any]:
    """Where it goes, what the driver should know, and what the delivery cost the customer."""
    parts = order.get("client_address_parts")
    parts = parts if isinstance(parts, Mapping) else {}
    address = _line(order.get("client_address"), 200) or _line(parts.get("full_address"), 200)
    if not address:
        street, city = _line(parts.get("street"), 120), _line(parts.get("city"), 60)
        address = ", ".join(part for part in (street, city, _line(parts.get("zipcode"), 12)) if part)
    lowered = address.lower()
    more = [
        f"{word} {text}"
        for key, word in ADDRESS_PARTS
        if (text := _line(parts.get(key), 40)) and text.lower() not in lowered
    ]
    if (text := _line(parts.get("more_address"), 120)) and text.lower() not in lowered:
        more.append(text)
    how = HOW.get(str(order.get("fulfillment_option") or ""))
    told: dict[str, Any] = {"handover": "delivery", "address": address}
    if note := ", ".join([*more, *([how] if how else [])])[:NOTE_MAX]:
        told["event_note"] = note
    # the fee as GloriaFood charged it: the order's own delivery fee, so it is charged while it is a
    # delivery and nobody is asked to pick one on top (pos.orders.delivery_fee)
    if fee > ZERO:
        taxed = _taxed(order, "delivery_fee")
        told["delivery_fee"] = {"by": ONLINE, "up_to": None, "amount": str(fee.quantize(CENT)), "taxed": taxed}
    else:  # delivered for nothing: "no fee" as a screen says it, so nobody is asked to pick one
        told["delivery_fee"] = {"by": None, "up_to": None, "amount": "0.00", "taxed": False}
    return told


def _note(order: Mapping[str, Any], *, delivery: bool) -> str:
    """What the customer wrote for the whole order, and how a pickup is handed over when that is not at
    the counter. It prints on every station's ticket: it may say an allergy."""
    said = _line(order.get("instructions"), NOTE_MAX)
    how = "" if delivery else HOW.get(str(order.get("fulfillment_option") or ""), "")
    return " · ".join(part for part in (said, how) if part)[:NOTE_MAX]


# --- the money -----------------------------------------------------------------------------------


def _kind(row: Mapping[str, Any]) -> str:
    return str(row.get("type") or "item")


def _money(value: Any) -> Decimal | None:
    """An amount as GloriaFood sends one (a number, sometimes text), to the cent. None for no amount."""
    if value is None or isinstance(value, bool) or not isinstance(value, int | float | str | Decimal):
        return None
    try:
        amount = Decimal(str(value).strip())
    except InvalidOperation:
        return None
    return amount.quantize(CENT, rounding=ROUND_HALF_UP) if amount.is_finite() else None


def _qty(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        return 1
    try:
        return max(1, min(999, int(Decimal(str(value)))))
    except (InvalidOperation, ValueError):
        return 1


def _options(row: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [option for option in row.get("options") or () if isinstance(option, Mapping)]


def _unit(row: Mapping[str, Any], qty: int) -> Decimal | None:
    """What one of a dish cost online, its size and choices in: the row's total over how many, when that
    comes out to the cent; else the dish's own price and each choice's."""
    total = _money(row.get("total_item_price"))
    if total is not None and (total / qty) == (total / qty).quantize(CENT):
        return (total / qty).quantize(CENT)
    base = _money(row.get("price"))
    if base is None:
        return None if total is None else (total / qty).quantize(CENT, rounding=ROUND_HALF_UP)
    extras = sum(((_money(o.get("price")) or ZERO) * _qty(o.get("quantity")) for o in _options(row)), ZERO)
    return base + extras


def _charged(row: Mapping[str, Any]) -> Decimal:
    """What a fee or a tip came to, less whatever a promotion took off it (free delivery)."""
    amount = _money(row.get("total_item_price"))
    if amount is None:
        amount = (_money(row.get("price")) or ZERO) * _qty(row.get("quantity"))
    off = abs(_money(row.get("item_discount")) or ZERO) + abs(_money(row.get("cart_discount")) or ZERO)
    return max(ZERO, amount - off)


def _taxed(order: Mapping[str, Any], listed: str, *, default: bool = False) -> bool:
    """Whether GloriaFood charged tax on a kind of row (`tax_list`); `default` when it does not say."""
    taxes = order.get("tax_list")
    if not isinstance(taxes, list):
        return default
    return any(
        isinstance(tax, Mapping) and tax.get("type") == listed and (_money(tax.get("value")) or ZERO) > ZERO
        for tax in taxes
    )


def _charge(order_id: str, name: str, code: str, words: str, amount: Decimal, taxed: bool) -> dict[str, Any]:
    return {
        "charge_id": f"{order_id}:{name}",
        "code": code,
        "name": words,
        "kind": "amount",
        "value": str(amount),
        "tax_class": "service_charge" if taxed else UNTAXED,
        "gratuity": False,
        "applied_by": BY,
    }


# --- the dishes ----------------------------------------------------------------------------------


def _line(value: Any, most: int) -> str:
    """Text on one line, no longer than `most`; nothing for anything that is not text or a number."""
    if isinstance(value, bool) or not isinstance(value, str | int | float):
        return ""
    return " ".join(str(value).split())[:most].strip()


def _plain(text: Any) -> str:
    """A name as it is compared: its menu number off, small letters, letters and digits only."""
    return re.sub(r"[^a-z0-9]+", " ", split_number(_line(text, 200))[1].lower()).strip()


def _number(code: Any) -> int | None:
    """The number in a menu number ("02", "K02", "L15A"): 2, 2, 15. None when it has none."""
    found = re.search(r"\d+", code) if isinstance(code, str) else None
    return int(found.group()) if found else None


def _dish_name(row: Mapping[str, Any]) -> str:
    return split_number(_line(row.get("name"), 200))[1][:NAME_MAX] or "Dish"


def _many(count: int, one: str, many: str) -> str:
    return f"{count} {one if count == 1 else many}"


class _Matcher:
    """Finds the POS's dish for what GloriaFood sold, by GloriaFood's own ids, and by its name when the id
    is one the menu does not have."""

    def __init__(self, menu: MenuService) -> None:
        self._menu = menu
        self._defs: Definitions = menu.defs
        self._items: dict[str, Item] = {}
        self._named: dict[str, list[Item]] = {}
        for item in self._defs.items.values():
            number = item.attrs.get("gloriafood_id")
            if number is not None:
                self._items.setdefault(str(number), item)
            if not item.asks_name and (name := _plain(self._defs.localizer.text(item.names, "en"))):
                self._named.setdefault(name, []).append(item)

    def item(self, row: Mapping[str, Any]) -> Item | None:
        number = row.get("type_id")
        found = None if number is None or isinstance(number, bool) else self._items.get(str(number))
        return found if found is not None else self._by_name(row)

    def _by_name(self, row: Mapping[str, Any]) -> Item | None:
        """The one dish on the POS that is called what GloriaFood calls this one: for a dish sold on another
        website of the restaurant, which numbers the same dish by itself. Two dishes of a name are told
        apart by the menu number in front of GloriaFood's name, then by which of them is still sold; when
        that leaves more than one, none is taken."""
        told = _line(row.get("name"), 200)
        named = self._named.get(_plain(told), [])
        menu_no = split_number(told)[0]
        if len(named) > 1 and menu_no:
            named = [item for item in named if menu_no.lower() in (alias.lower() for alias in item.aliases)] or named
        if len(named) > 1:
            named = [item for item in named if item.active] or named
        return named[0] if len(named) == 1 else None

    def priced(self, row: Mapping[str, Any], unit: Decimal) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        """The dish as the menu on the POS makes it, at the price it was sold for online, and the request a
        screen can reopen its choices from. `(None, None)` when the menu has no such dish, size or choice,
        or will not put them together."""
        item = self.item(row)
        if item is None:
            return None, None
        options = _options(row)
        variant = self._variant(item, [o for o in options if o.get("type") == "size"])
        chosen = self._chosen(item, [o for o in options if o.get("type") != "size"])
        if variant is None or chosen is None:
            return None, None
        request: dict[str, Any] = {
            "variant_id": variant.id,
            "selections": [
                {"group_id": group, "option_id": option, "qty": qty} for (group, option), (qty, _) in chosen.items()
            ],
        }
        if item.asks_price and not item.asks_name:
            request["price"] = str(unit)  # a dish priced when it is rung: what it cost online
        try:
            priced = self._menu.priced(request)
        except (KeyError, ValueError, TypeError):
            return None, None
        if any(problem["code"] not in SOLD_ANYWAY for problem in priced["problems"]):
            return None, None
        priced["problems"] = []
        menu_price = priced["unit_price"]
        priced["unit_price"] = str(unit)
        if Decimal(menu_price) != unit:
            priced["online"] = {"menu_price": menu_price}
        for shown in priced.get("modifiers") or ():
            # each choice at what it cost online, for as many as were taken; what the menu adds by itself
            # (a default, a choice of a choice) cost nothing there
            paid = chosen.get((shown.get("group_id"), shown.get("option_id"))) if not shown.get("depth") else None
            cost = paid[1] if paid is not None and not shown.get("note") else ZERO
            shown["price"] = str(cost.quantize(CENT))
        return priced, request

    def _variant(self, item: Item, sizes: list[Mapping[str, Any]]) -> Variant | None:
        variants = self._defs.variants_of(item.code)
        if len(sizes) > 1:
            return None
        if sizes:
            code, name = str(sizes[0].get("type_id")), _plain(sizes[0].get("name"))
            found = next((v for v in variants if v.code == code), None)
            if found is None and name:
                named = [v for v in variants if _plain(self._defs.localizer.text(v.names, "en")) == name]
                found = named[0] if len(named) == 1 else None
            return found
        if len(variants) == 1:
            return variants[0]
        return next((v for v in variants if v.code == "regular"), None)

    def _chosen(
        self, item: Item, options: list[Mapping[str, Any]]
    ) -> dict[tuple[str, str], tuple[int, Decimal]] | None:
        """Each choice as the menu on the POS knows it, `(group, option)`, with how many and what they cost
        together online. None when one of them is no choice of this dish's."""
        groups = [group for group, _ in self._defs.attachments_for(item.code)]
        offered = [(group, option) for group in groups for option in self._defs.options_of(group.code)]
        chosen: dict[tuple[str, str], tuple[int, Decimal]] = {}
        for told in options:
            code = None if told.get("type_id") is None else str(told.get("type_id"))
            found = [(group, option) for group, option in offered if code is not None and option.code == code]
            if not found:
                name, heading = _plain(told.get("name")), _plain(told.get("group_name"))
                named = [
                    (group, option)
                    for group, option in offered
                    if name and _plain(self._defs.localizer.text(self._defs.option_names(option), "en")) == name
                ]
                under = [pair for pair in named if _plain(self._defs.localizer.text(pair[0].names, "en")) == heading]
                found = under or named
            if not found and (number := _number(split_number(_line(told.get("name"), 200))[0])) is not None:
                # a choice that is a dish of the POS's own (a roll of a combination) and is named another
                # way there: GloriaFood numbers its choices as the POS numbers those dishes
                found = [
                    (group, option)
                    for group, option in offered
                    if group.source_category is not None and _number(option.code) == number
                ]
            if len(found) != 1:
                return None
            option = found[0][1]
            qty = _qty(told.get("quantity"))
            cost = (_money(told.get("price")) or ZERO) * qty
            had = chosen.get((option.group, option.id), (0, ZERO))
            chosen[(option.group, option.id)] = (had[0] + qty, had[1] + cost)
        return chosen

    def as_written(self, row: Mapping[str, Any], unit: Decimal) -> dict[str, Any]:
        """A dish the menu on the POS could not make, as GloriaFood named it: its name, its size and choices
        as words. It prints where the dish is cooked when the dish is known, else where tickets with no
        station print; it is taxed as that dish, else as prepared food."""
        item = self.item(row)
        name = _dish_name(row)
        chosen = []
        for told in _options(row):
            qty, words = _qty(told.get("quantity")), split_number(_line(told.get("name"), NAME_MAX))[1]
            if not words:
                continue
            label = f"{qty}x {words}" if qty > 1 else words
            cost = ZERO if told.get("type") == "size" else (_money(told.get("price")) or ZERO) * qty
            chosen.append((label, cost))
        station = self._defs.inherited(item, "station") if item is not None else None
        tax_class = self._defs.inherited(item, "tax_class") if item is not None else None
        labels = [label for label, _ in chosen]
        return {
            "item": item.code if item is not None else None,
            "variant_id": None,
            "entry_id": None,
            "names": {"en": name},
            "variant_names": {},
            "name": name,
            "unit_price": str(unit),
            "tax_class": tax_class or "prepared_food",
            "modifiers": [
                {
                    "group_id": None,
                    "option_id": None,
                    "qty": 1,
                    "label": label,
                    "kitchen_label": label,
                    "prefix": None,
                    "price": str(cost.quantize(CENT)),
                    "defaulted": False,
                    "depth": 0,
                }
                for label, cost in chosen
            ],
            "kitchen": [
                {
                    "station": station,
                    "qty": 1,
                    "text": " · ".join([f"1 {name}", *labels]),
                    "label": name,
                    "labels": labels,
                    "depths": [0] * len(labels),
                    "header": None,
                    "note": None,
                }
            ],
            "contains": [],
            "problems": [],
            "online": {"as_written": True},
        }


__all__ = [
    "BY",
    "DEVICE",
    "DIFFERENCE",
    "PROMOTION",
    "CannotPlace",
    "NotAnOrder",
    "Placed",
    "ext_id_of",
    "hidden",
    "ops_for",
    "order_id_for",
    "own_word",
]
