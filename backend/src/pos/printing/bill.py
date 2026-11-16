"""The guest's bill on paper: the check as the hub reckons it (`pos.orders.check.check_for`), so the paper
says what the screen says, to the cent.

A `Bill` is data, like a kitchen `Ticket`: `bill_for` makes one from an order's check and its fields, and
`render_bill` turns it into the bytes for a printer in its own language. From the top: the restaurant's own
lines (the location's `bill` setting; the first one big), the table or the order's number with the time, each
dish with what it costs and its choices under it, the subtotal, every discount and charge by name, sales tax
as ONE line (the split by jurisdiction is for the back office), the total, what was paid and what is still
due, and the location's closing lines.

Only the right-hand column adds up: a choice's own price ("+1.00") and a comp on a dish ("-48.00") stand in
the words under the dish, since the dish's amount already holds its choices and the comp is taken off below
the subtotal, where the screen takes it off too.

A table that pays on several checks (`pos.orders.split`) gets a bill for each: the check's own dishes (a
shared dish with this check's part of it, "1/3 of 18.00"), its part of every discount, charge and the tax,
and its own total. A table that splits evenly gets the whole bill once for each part, with the part under
the total.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from ..sync.oplog import is_tab
from .ticket import DIALECTS

ZERO = Decimal(0)
PAID_AS = {"cash": "Paid cash", "card": "Paid card"}
"""How a payment reads on the bill by its method; one taken outside the POS (`elsewhere`) is just "Paid"."""


@dataclass(frozen=True)
class BillLine:
    qty: int
    name: str
    amount: str  # what the dish comes to with its choices, for its quantity: "33.90"
    notes: tuple[tuple[str, int], ...] = ()  # under the dish, (words, how far in): its choices, then a comp


@dataclass(frozen=True)
class Bill:
    order_id: str
    where: str  # "Table 12", "Order #7", "Bar tab"
    lines: tuple[BillLine, ...]
    total: str
    detail: str = ""  # beside `where`: "4 guests", the name on a to-go order or on a tab
    who: str = ""  # under it: "Server Amy", "Phone"
    note: str = ""  # under that, on one of a split table's bills: "One of 3 checks at this table"
    head: tuple[str, ...] = ()  # the restaurant's own lines; the first prints big
    sums: tuple[tuple[str, str], ...] = ()  # between the dishes and the total: subtotal, discounts, charges, tax
    paid: tuple[tuple[str, str], ...] = ()  # under the total: each payment; a row with no amount is words only
    # One part of a check split evenly: ("Part 2 of 4", "23.46"). It prints big under the total, and what
    # was paid and is due is then this part's.
    share: tuple[str, str] | None = None
    due: str | None = None  # what is still owed once something was paid; None while nothing was
    foot: tuple[str, ...] = ()
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # the printer this bill was for, on the copy a fallback printer gets


def _money(value: Any) -> Decimal:
    try:
        return Decimal(str(value))
    except InvalidOperation:
        return ZERO


def _amount(value: Any) -> str:
    return f"{_money(value):,.2f}"


def _rate(pct: Any) -> str:
    """7.00 -> 7, 6.25 -> 6.25: the rate as the check on screen says it."""
    value = _money(pct)
    return str(value.quantize(Decimal(1))) if value == value.to_integral_value() else str(value.normalize())


def _clock(at: datetime) -> str:
    return f"{at.hour % 12 or 12}:{at:%M} {'AM' if at.hour < 12 else 'PM'}"


def _day(at: datetime) -> str:
    return f"{at:%b} {at.day}, {at.year}"


def bill_for(
    check: Mapping[str, Any],
    fields: Mapping[str, Any],
    *,
    head: tuple[str, ...] = (),
    foot: tuple[str, ...] = (),
    at: datetime | None = None,
    number: int | None = None,
) -> Bill:
    """The bill for an order: `check` is its check as the hub reckons it, `fields` what the order says of
    itself (table, guests, server, the number and name of a to-go order). `number` asks for one of a split
    table's checks (`check["checks"]`) instead of the whole table's; a number the table has no check for
    gives the whole."""
    parts = list(check.get("checks") or ())
    part = next((p for p in parts if p.get("check") == number), None) if number is not None else None
    even = (check.get("split") or {}).get("by") == "even"
    own = check if part is None or even else part  # whose dishes and sums the paper lists
    owed = check if part is None else part  # whose payments and what is due

    discounts = [d for d in own.get("discounts") or () if _money(d.get("amount")) > ZERO]
    names = {row["line_id"]: str(row["name"]) for row in check.get("lines") or ()}
    lines = []
    for row in own.get("lines") or ():
        notes = []
        shared = len(row.get("shared") or ())
        if shared:  # this check's part of a dish: the choices' own prices are the whole dish's, so not said
            notes.append((f"1/{shared + 1} of {_amount(row.get('of'))}", 0))
        for m in row.get("modifiers") or ():
            price = ZERO if shared else _money(m.get("amount"))
            change = f" {'+' if price > ZERO else '-'}{_amount(abs(price))}" if price != ZERO else ""
            notes.append((f"{m['label']}{change}", int(m.get("depth") or 0)))
        # a comp or a discount on this dish: said here so the guest sees which dish, taken off below
        for d in discounts:
            if d.get("line_id") == row["line_id"]:
                notes.append((f"{d['name']} -{_amount(d['amount'])}", 0))
        lines.append(BillLine(int(row.get("qty") or 1), str(row["name"]), _amount(row.get("total")), tuple(notes)))

    sums = [("Subtotal", _amount(own.get("subtotal")))]
    for d in discounts:
        on = names.get(d.get("line_id"))
        sums.append((f"{d['name']}, {on}" if on else str(d["name"]), f"-{_amount(d['amount'])}"))
    for c in own.get("charges") or ():
        sums.append((str(c["name"]), _amount(c.get("amount"))))
    sums.append((f"Sales tax {_rate(check.get('tax_rate_pct'))}%", _amount(own.get("tax"))))

    total, paid_so_far = _money(owed.get("total")), _money(owed.get("paid"))
    paid = []
    for p in owed.get("payments") or ():
        paid.append((PAID_AS.get(str(p.get("method")), "Paid"), f"-{_amount(p.get('amount'))}"))
        handed, took = _money(p.get("tendered")), _money(p.get("amount"))
        if p.get("tendered") not in (None, "") and handed > took:
            paid.append((f"   {_amount(handed)} handed over, {_amount(handed - took)} change", ""))
    if paid_so_far > total:  # a dish taken off after the check was paid
        paid.append((f"Paid {_amount(paid_so_far - total)} more than the total", ""))

    table = str(fields.get("table") or "")
    guests, number_of_day = fields.get("guests"), fields.get("order_no")
    channel = str(fields.get("channel") or "").replace("_", " ").capitalize()
    server = f"Server {fields['server']}" if fields.get("server") else ""
    if table:
        where = f"Table {table}"
        detail = f"{guests} guest{'' if guests == 1 else 's'}" if isinstance(guests, int) and guests > 0 else ""
        who = server
    elif is_tab(fields):  # a bar tab that has not sat down: called by the name on it
        where = "Bar tab"
        detail = str(fields.get("customer_name") or "")
        who = server
    else:
        where = (
            f"Order #{number_of_day}"
            if isinstance(number_of_day, int)
            else (f"{channel} order" if channel else "Order")
        )
        detail = str(fields.get("customer_name") or "")
        who = "  ".join(part for part in (channel if isinstance(number_of_day, int) else "", server) if part)
    note, share = "", None
    if part is not None and even:
        share = (f"Part {part['check']} of {len(parts)}", _amount(part.get("total")))
    elif part is not None:
        detail = f"Check {part['check']}"
        on = "at this table" if table else "on this tab" if is_tab(fields) else "on this order"
        note = f"One of {len(parts)} checks {on}"
    return Bill(
        order_id=str(check.get("order_id") or ""),
        where=where,
        detail=detail,
        who=who,
        note=note,
        lines=tuple(lines),
        total=_amount(check.get("total") if even else total),
        head=tuple(head),
        sums=tuple(sums),
        paid=tuple(paid),
        share=share,
        due=_amount(owed.get("due")) if paid else None,
        foot=tuple(foot),
        at=at or datetime.now(),
    )


def render_bill(bill: Bill, *, dots: int = 576, font: str | None = None, dialect: str = "escpos") -> bytes:
    """The print job for one bill (`dialect` escpos or star). Deterministic for the same inputs. No buzzer:
    a bill comes out where a person is standing waiting for it."""
    b = DIALECTS[dialect](dots=dots, font=font)
    if bill.reprinted_from:
        # A fallback printer's copy: whoever stands there carries it out front, and tears this strip off.
        b.line(f"{bill.reprinted_from} printer down, printed here".upper(), center=True, bold=True, invert=True)
        b.feed(1)
    for i, text in enumerate(bill.head):
        b.line(text, big=i == 0, bold=i == 0, center=True)
    if bill.head:
        b.rule()
    b.columns("  ".join(part for part in (bill.where, bill.detail) if part), _clock(bill.at), bold=True)
    b.columns(bill.who, _day(bill.at))
    if bill.note:
        b.line(bill.note)
    b.rule()
    for line in bill.lines:
        b.columns(f"{line.qty} ".ljust(3) + line.name, line.amount, hang="   ")
        for words, depth in line.notes:
            b.line(f"{'   ' + '  ' * depth}{words}")
    b.rule()
    for label, amount in bill.sums:
        b.columns(label, amount)
    b.rule()
    if bill.share is None:
        b.columns("TOTAL", f"${bill.total}", bold=True, big=True)
    else:  # the table's total, then this guest's part of it, which is the figure to pay
        b.columns("TOTAL", f"${bill.total}", bold=True)
        b.columns(bill.share[0].upper(), f"${bill.share[1]}", bold=True, big=True)
    for label, amount in bill.paid:
        b.columns(label, amount) if amount else b.line(label)
    if bill.due is not None:
        if Decimal(bill.due.replace(",", "")) > ZERO:
            b.columns("DUE", f"${bill.due}", bold=True, big=True)
        else:
            b.line("PAID IN FULL", bold=True, center=True)
    if bill.foot:
        b.rule()
    for text in bill.foot:
        b.line(text, center=True)
    b.feed(1)
    b.line(f"{bill.order_id[-8:]}  {bill.at:%Y-%m-%d %H:%M:%S}".strip(), center=True)
    b.feed(2).cut()
    return bytes(b)


SAMPLE = Bill(
    order_id="0193f2a7-sample-bill",
    where="Table 12",
    detail="4 guests",
    who="Server Amy",
    lines=(
        BillLine(1, "General Gao's Chicken (Qt)", "25.95", (("Brown rice +1.00", 0), ("Extra Add shrimp +8.00", 0))),
        BillLine(2, "Hot & Sour Soup", "7.90"),
        BillLine(1, "Peking Duck", "48.00", (("Manager comp -48.00", 0),)),
    ),
    sums=(
        ("Subtotal", "81.85"),
        ("Manager comp, Peking Duck", "-48.00"),
        ("Sales tax 7%", "2.37"),
    ),
    total="36.22",
    paid=(("Paid cash", "-20.00"),),
    due="16.22",
)
"""What the bill settings' sample prints, under the texts being tried: every kind of row a real bill can have."""
