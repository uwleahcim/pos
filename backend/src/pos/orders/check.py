"""A check: the order's priced lines, its discounts and charges, subtotal, tax lines and total.

Computed from the operation log on every read and never stored, so a late void or a merged offline edit
is always reflected. Lines carry the price they were sold at (`priced`, set by the hub when the line was
added); a line without one (the phase 0 demo screen) counts as zero and is flagged.

Order of operations (architecture section 9): line discounts, then check discounts spread over the lines
in proportion, then charges on the discounted subtotal (and a delivery's fee, pos.orders.delivery_fee), then
tax on whatever each class taxes. A check a
manager marked tax exempt (pos.orders.exempt) is charged no tax: `tax_exempt` says for whom, and how much
tax that was.

A table that pays on several checks is still one order and one check here: `checks` then says what each
of them comes to (pos.orders.split), and they add up to this check to the cent.
"""

from __future__ import annotations

from dataclasses import replace
from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from ..sync.oplog import Discount, OrderState
from ..tax import TaxableLine, TaxProfile
from .adjustments import ChargeRule, PricingRules
from .delivery_fee import CHARGE_ID as FEE_ID
from .delivery_fee import CHARGE_NAME as FEE_NAME
from .delivery_fee import TAX_CLASS as FEE_TAX_CLASS
from .delivery_fee import fee_charged
from .exempt import exemption_of
from .split import split_checks, split_of

ZERO = Decimal(0)
CENT = Decimal("0.01")
UNTAXED = "untaxed"
"""The tax class of a charge that is never taxed, whatever the location's tax profile says of the classes it
knows: a row that only evens a check with what a customer was charged somewhere else (pos.online.place)."""


def cents(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def check_for(
    state: OrderState, taxes: TaxProfile, rules: PricingRules | None = None, on: date | None = None
) -> dict[str, Any]:
    order_type = str(state.fields.get("order_type") or "dine_in")
    rules = rules or PricingRules()
    exempt = exemption_of(state.fields)
    lines: list[dict[str, Any]] = []
    net: dict[str, Decimal] = {}  # what each line is worth after discounts
    tax_classes: dict[str, str] = {}
    subtotal = ZERO
    unpriced = []
    for line in state.ordered_lines():  # as the check shows them, so the receipt reads the same
        if line.status != "active":
            continue
        priced = line.priced or {}
        unit = Decimal(priced.get("unit_price", "0"))
        total = (unit * line.qty).quantize(CENT)
        if not priced:
            unpriced.append(line.line_id)
        subtotal += total
        net[line.line_id] = total
        tax_classes[line.line_id] = priced.get("tax_class", "prepared_food")
        lines.append(
            {
                "line_id": line.line_id,
                "name": priced.get("name") or line.item,
                "qty": line.qty,
                "seat": line.seat,
                "course": line.course,
                "unit_price": str(unit),
                "total": str(total),
                "discount": "0.00",  # what came off this line itself, filled in below
                # each choice that is not the dish's default, with what it adds to the line for its quantity;
                # `depth` 1 is a choice of a choice (the sauce on a roll of the maki combination)
                "modifiers": [
                    {
                        "label": m["label"],
                        "price": str(_money(m.get("price"))),
                        "amount": str(cents(_money(m.get("price")) * line.qty)),
                        "depth": int(m.get("depth") or 0),
                    }
                    for m in shown_modifiers(priced.get("modifiers", ()))
                ],
                "tax_class": priced.get("tax_class"),
            }
        )

    # Discounts: on a line first, then on the check, each capped at what is left to take off. A discount on
    # a dish follows the dish through its edits (each one voids the line and adds the changed one), and comes
    # off the check with the dish when it is removed or voided with nothing in its place: no row, nothing
    # off the total. The log keeps the discount as it was approved either way.
    discount_rows: list[dict[str, Any]] = []
    taken: list[dict[str, Decimal]] = []  # beside each row: what it took off each line
    discount_total = ZERO
    active = sorted((d for d in state.discounts.values() if d.active), key=lambda d: (d.line_id is None, d.stamp or ""))
    for discount in active:
        line_id = None if discount.line_id is None else state.current_line(discount.line_id)
        if line_id is not None and line_id not in net:
            continue  # its dish is off the check
        amount = _discount_amount(discount, net, line_id)
        if line_id is not None:
            if amount > ZERO:
                net[line_id] -= amount
                for row in lines:
                    if row["line_id"] == line_id:
                        row["discount"] = str(Decimal(row["discount"]) + amount)
            taken.append({line_id: amount})
        else:
            taken.append(_spread(amount, net))
        discount_total += amount
        discount_rows.append(
            {
                "discount_id": discount.discount_id,
                "reason": discount.reason,
                "name": rules.discounts[discount.reason].name
                if discount.reason in rules.discounts
                else discount.reason,
                "kind": discount.kind,
                "value": discount.value,
                "line_id": line_id,
                "note": discount.note,
                "amount": str(amount),
                "applied_by": discount.applied_by,
                "approved_by": discount.approved_by,
            }
        )
    discounted = sum(net.values(), ZERO)

    # Charges on the discounted subtotal: the rules' automatic ones unless taken off, plus the ones staff put on.
    charge_rows: list[dict[str, Any]] = []
    charge_classes: list[str | None] = []  # beside each row: the class it is taxed as (None: it is not taxed)
    charge_total = ZERO
    taxable = [TaxableLine(line_id, tax_classes[line_id], amount) for line_id, amount in net.items()]
    guests = state.fields.get("guests")
    for rule in rules.charges.values():
        if not rule.applies(order_type, guests if isinstance(guests, int) else None):
            continue
        placeholder = state.charges.get(rule.code)
        if placeholder is not None and not placeholder.active:
            continue  # taken off, with whatever approval the rule asked for
        amount = _charge_amount(rule.kind, rule.value, discounted)
        charge_total += amount
        taxable.append(TaxableLine(f"charge:{rule.code}", rule.tax_class, amount))
        row = _charge_row(rule.code, rule.name, rule.kind, str(rule.value), amount, rule.gratuity, True)
        row["taxed"] = exempt is None and _taxed(taxes, rule.tax_class, order_type, on)
        charge_rows.append(row)
        charge_classes.append(rule.tax_class)
    for charge in state.charges.values():
        if not charge.active or charge.charge_id in rules.charges:
            continue
        amount = _charge_amount(charge.kind, Decimal(charge.value or "0"), discounted)
        charge_total += amount
        charge_class = None if charge.tax_class == UNTAXED else charge.tax_class
        if charge_class is not None:
            taxable.append(TaxableLine(f"charge:{charge.charge_id}", charge_class, amount))
        row = _charge_row(charge.charge_id, charge.name, charge.kind, charge.value, amount, charge.gratuity, False)
        row["taxed"] = exempt is None and charge_class is not None and _taxed(taxes, charge_class, order_type, on)
        row["applied_by"] = charge.applied_by
        charge_rows.append(row)
        charge_classes.append(charge_class)
    # What a delivery costs, as it was picked when the order was taken (pos.orders.delivery_fee): a charge of
    # its own, last, taxed only when the location says its fee is. `delivery` says which band it was.
    fee = fee_charged(state.fields)
    if fee is not None:
        amount = cents(Decimal(fee["amount"]))
        fee_class = FEE_TAX_CLASS if fee["taxed"] and _taxed(taxes, FEE_TAX_CLASS, order_type, on) else None
        charge_total += amount
        if fee_class is not None:
            taxable.append(TaxableLine(f"charge:{FEE_ID}", fee_class, amount))
        row = _charge_row(FEE_ID, FEE_NAME, "amount", fee["amount"], amount, False, False)
        row["taxed"] = exempt is None and fee_class is not None
        row["delivery"] = {"by": fee["by"], "up_to": fee["up_to"]}
        charge_rows.append(row)
        charge_classes.append(fee_class)

    # An empty check still names its tax lines (at 0.00), so a terminal knows the rates for its own estimate.
    tax_lines = taxes.compute(taxable or [TaxableLine("", "default", ZERO)], order_type, on)
    if exempt is not None:
        # The lines stay, at nothing, so a terminal still knows the rates; what the tax would have been is
        # kept beside who the check is for, for the reports.
        exempt["tax"] = str(cents(sum((t.amount for t in tax_lines), ZERO)))
        tax_lines = [replace(t, base=cents(ZERO), amount=cents(ZERO)) for t in tax_lines]
    tax = sum((t.amount for t in tax_lines), ZERO)
    total = cents(discounted + charge_total + tax)
    paid = sum((Decimal(p.amount or "0") for p in state.payments.values()), ZERO)
    split = split_of(state.fields)
    checks = split_checks(
        state,
        split,
        lines=lines,
        taken=list(zip(discount_rows, taken, strict=True)),
        charges=list(zip(charge_rows, charge_classes, strict=True)),
        tax_classes=tax_classes,
        tax_lines=tax_lines,
        taxes=taxes,
        order_type=order_type,
        on=on,
        total=total,
    )
    return {
        "order_id": state.order_id,
        "status": state.status,
        "order_type": order_type,
        "lines": lines,
        "subtotal": str(cents(subtotal)),
        "discounts": discount_rows,
        "discount_total": str(cents(discount_total)),
        "charges": charge_rows,
        "charge_total": str(cents(charge_total)),
        "tax_lines": [t.as_json() for t in tax_lines],
        "tax": str(cents(tax)),
        # only on a check a manager marked exempt: organisation, certificate, approved_by, by, at_ms, and
        # `tax`, what was not charged
        **({"tax_exempt": exempt} if exempt is not None else {}),
        # customers see one tax line; the split by jurisdiction is for the back office
        "tax_rate_pct": str(sum((t.rate_pct for t in tax_lines), ZERO)),
        "total": str(total),
        # Counter mode pays before the kitchen sees the order; `due` is what is still owed at pickup.
        "payments": [
            {"payment_id": pid, **p.as_json()}
            for pid, p in sorted(state.payments.items(), key=lambda kv: kv[1].stamp or "")
        ],
        "paid": str(cents(paid)),
        "due": str(cents(max(total - paid, ZERO))),
        "unpriced": unpriced,
        # A table that pays on several checks: how it is split, and what each check comes to. They add up
        # to the totals above. `checks` is empty while the table is one check, whatever `split` asks for
        # (by seat with every dish on one seat is still one check).
        "split": split.as_json() if checks else None,
        "checks": checks,
    }


def shown_modifiers(rows: Any) -> list[dict[str, Any]]:
    """The choices a check lists under a dish: those that are not the dish's defaults, and a default whose
    own choices (one level deeper) differ, so a changed sauce reads under the roll it is on, not on its own."""
    rows = [dict(m) for m in rows]
    shown: list[dict[str, Any]] = []
    for i, m in enumerate(rows):
        if not m.get("defaulted"):
            shown.append(m)
            continue
        depth = int(m.get("depth") or 0)
        for later in rows[i + 1 :]:
            if int(later.get("depth") or 0) <= depth:
                break
            if not later.get("defaulted"):
                shown.append(m)
                break
    return shown


def _money(value: Any) -> Decimal:
    try:
        return Decimal(str(value if value is not None else 0))
    except ArithmeticError:
        return ZERO


def _discount_amount(discount: Discount, net: dict[str, Decimal], line_id: str | None) -> Decimal:
    """What this discount takes off, given what is left on its line (`line_id`, the one standing for the
    line it was put on) or on the whole check."""
    if line_id is not None:
        base = net.get(line_id, ZERO)
    else:
        base = sum(net.values(), ZERO)
    if base <= ZERO:
        return ZERO
    if discount.kind == "comp":
        return base
    try:
        value = Decimal(discount.value)
    except ArithmeticError:
        return ZERO
    amount = cents(base * value / 100) if discount.kind == "percent" else cents(value)
    return min(max(amount, ZERO), base)


def _spread(amount: Decimal, net: dict[str, Decimal]) -> dict[str, Decimal]:
    """Takes a check discount off every line in proportion to what it is worth, so each line's tax base is
    right; the odd cent lands on the largest line. Returns what came off each line."""
    base = sum(net.values(), ZERO)
    if amount <= ZERO or base <= ZERO:
        return {}
    shares = {line_id: cents(amount * worth / base) for line_id, worth in net.items()}
    off_by = amount - sum(shares.values(), ZERO)
    if off_by:
        largest = max(net, key=lambda line_id: (net[line_id], line_id))
        shares[largest] += off_by
    for line_id, share in shares.items():
        net[line_id] -= share
    return shares


def _charge_amount(kind: str, value: Decimal, discounted: Decimal) -> Decimal:
    return cents(discounted * value / 100) if kind == "percent" else cents(value)


def _taxed(taxes: TaxProfile, tax_class: str, order_type: str, on: date | None) -> bool:
    """Whether this class is taxed here at all, so a terminal's own estimate taxes the charge or not."""
    return bool(taxes.compute([TaxableLine("probe", tax_class, Decimal(100))], order_type, on))


def _charge_row(
    charge_id: str, name: str, kind: str, value: str, amount: Decimal, gratuity: bool, automatic: bool
) -> dict[str, Any]:
    return {
        "charge_id": charge_id,
        "name": name,
        "kind": kind,
        "value": value,
        "amount": str(amount),
        "gratuity": gratuity,
        "automatic": automatic,
    }


def charge_snapshot(rule: ChargeRule) -> dict[str, Any]:
    """What the hub writes into a `charge` operation so the check keeps the charge as it was when added."""
    return {
        "name": rule.name,
        "kind": rule.kind,
        "value": str(rule.value),
        "tax_class": rule.tax_class,
        "gratuity": rule.gratuity,
    }


__all__ = ["UNTAXED", "charge_snapshot", "check_for"]
