"""A check: the order's priced lines, its discounts and charges, subtotal, tax lines and total.

Computed from the operation log on every read and never stored, so a late void or a merged offline edit
is always reflected. Lines carry the price they were sold at (`priced`, set by the hub when the line was
added); a line without one (the phase 0 demo screen) counts as zero and is flagged.

Order of operations (architecture section 9): line discounts, then check discounts spread over the lines
in proportion, then charges on the discounted subtotal, then tax on whatever each class taxes.
"""

from __future__ import annotations

from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from ..sync.oplog import Discount, OrderState
from ..tax import TaxableLine, TaxProfile
from .adjustments import ChargeRule, PricingRules

ZERO = Decimal(0)
CENT = Decimal("0.01")


def cents(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def check_for(
    state: OrderState, taxes: TaxProfile, rules: PricingRules | None = None, on: date | None = None
) -> dict[str, Any]:
    order_type = str(state.fields.get("order_type") or "dine_in")
    rules = rules or PricingRules()
    lines: list[dict[str, Any]] = []
    net: dict[str, Decimal] = {}  # what each line is worth after discounts
    tax_classes: dict[str, str] = {}
    subtotal = ZERO
    unpriced = []
    for line in sorted(state.lines.values(), key=lambda line: (line.seat or 0, line.line_id)):
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
                "modifiers": [m["label"] for m in priced.get("modifiers", ()) if not m.get("defaulted")],
                "tax_class": priced.get("tax_class"),
            }
        )

    # Discounts: on a line first, then on the check, each capped at what is left to take off.
    discount_rows: list[dict[str, Any]] = []
    discount_total = ZERO
    active = sorted((d for d in state.discounts.values() if d.active), key=lambda d: (d.line_id is None, d.stamp or ""))
    for discount in active:
        amount = _discount_amount(discount, net)
        if discount.line_id is not None:
            if amount > ZERO:
                net[discount.line_id] -= amount
                for row in lines:
                    if row["line_id"] == discount.line_id:
                        row["discount"] = str(Decimal(row["discount"]) + amount)
        else:
            _spread(amount, net)
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
                "line_id": discount.line_id,
                "note": discount.note,
                "amount": str(amount),
                "applied_by": discount.applied_by,
                "approved_by": discount.approved_by,
            }
        )
    discounted = sum(net.values(), ZERO)

    # Charges on the discounted subtotal: the rules' automatic ones unless taken off, plus the ones staff put on.
    charge_rows: list[dict[str, Any]] = []
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
        row["taxed"] = _taxed(taxes, rule.tax_class, order_type, on)
        charge_rows.append(row)
    for charge in state.charges.values():
        if not charge.active or charge.charge_id in rules.charges:
            continue
        amount = _charge_amount(charge.kind, Decimal(charge.value or "0"), discounted)
        charge_total += amount
        taxable.append(TaxableLine(f"charge:{charge.charge_id}", charge.tax_class, amount))
        row = _charge_row(charge.charge_id, charge.name, charge.kind, charge.value, amount, charge.gratuity, False)
        row["taxed"] = _taxed(taxes, charge.tax_class, order_type, on)
        row["applied_by"] = charge.applied_by
        charge_rows.append(row)

    # An empty check still names its tax lines (at 0.00), so a terminal knows the rates for its own estimate.
    tax_lines = taxes.compute(taxable or [TaxableLine("", "default", ZERO)], order_type, on)
    tax = sum((t.amount for t in tax_lines), ZERO)
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
        # customers see one tax line; the split by jurisdiction is for the back office
        "tax_rate_pct": str(sum((t.rate_pct for t in tax_lines), ZERO)),
        "total": str(cents(discounted + charge_total + tax)),
        "unpriced": unpriced,
    }


def _discount_amount(discount: Discount, net: dict[str, Decimal]) -> Decimal:
    """What this discount takes off, given what is left on its line or on the whole check."""
    if discount.line_id is not None:
        base = net.get(discount.line_id, ZERO)
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


def _spread(amount: Decimal, net: dict[str, Decimal]) -> None:
    """Takes a check discount off every line in proportion to what it is worth, so each line's tax base is
    right; the odd cent lands on the largest line."""
    base = sum(net.values(), ZERO)
    if amount <= ZERO or base <= ZERO:
        return
    shares = {line_id: cents(amount * worth / base) for line_id, worth in net.items()}
    off_by = amount - sum(shares.values(), ZERO)
    if off_by:
        largest = max(net, key=lambda line_id: (net[line_id], line_id))
        shares[largest] += off_by
    for line_id, share in shares.items():
        net[line_id] -= share


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


__all__ = ["charge_snapshot", "check_for"]
