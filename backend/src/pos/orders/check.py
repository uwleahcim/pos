"""A check: the order's priced lines, subtotal, tax lines and total.

Computed from the operation log on every read and never stored, so a late void or a merged offline edit
is always reflected. Lines carry the price they were sold at (`priced`, set by the hub when the line was
added); a line without one (the phase 0 demo screen) counts as zero and is flagged.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from typing import Any

from ..sync.oplog import OrderState
from ..tax import TaxableLine, TaxProfile

ZERO = Decimal(0)
CENT = Decimal("0.01")


def check_for(state: OrderState, taxes: TaxProfile, on: date | None = None) -> dict[str, Any]:
    order_type = str(state.fields.get("order_type") or "dine_in")
    lines: list[dict[str, Any]] = []
    taxable: list[TaxableLine] = []
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
        taxable.append(TaxableLine(line.line_id, priced.get("tax_class", "prepared_food"), total))
        lines.append(
            {
                "line_id": line.line_id,
                "name": priced.get("name") or line.item,
                "qty": line.qty,
                "seat": line.seat,
                "course": line.course,
                "unit_price": str(unit),
                "total": str(total),
                "modifiers": [m["label"] for m in priced.get("modifiers", ()) if not m.get("defaulted")],
                "tax_class": priced.get("tax_class"),
            }
        )
    tax_lines = taxes.compute(taxable, order_type, on)
    tax = sum((t.amount for t in tax_lines), ZERO)
    return {
        "order_id": state.order_id,
        "status": state.status,
        "order_type": order_type,
        "lines": lines,
        "subtotal": str(subtotal),
        "tax_lines": [t.as_json() for t in tax_lines],
        "tax": str(tax),
        "total": str(subtotal + tax),
        "unpriced": unpriced,
    }
