"""Dishes sold at a typed price, for the manager's report.

A dish the menu says asks its price (market price), or its name and price (an off-menu dish: the old POS's
Open Food), is rung with what the server typed. The menu engine checks it and the line keeps it
(`priced.typed`), so the check, the bill and every total carry the sale like any other. What the menu cannot
do is say whether the price was the right one, so the report lists every one of them: what was typed, for
how much, by whom, on which check and when.

A dish taken off before it was sent is not listed here (the taken-off report has it), nor one changed before
it was sent or gone to another check, which is listed where it stands now. One voided after the kitchen had
it is listed and marked, and counts for nothing in the totals: the voids report values it.
"""

from __future__ import annotations

from collections.abc import Mapping
from decimal import Decimal
from typing import Any

from ..sync.oplog import OrderState

CENT = Decimal("0.01")


def typed_rows(state: OrderState, since: int = 0) -> list[dict[str, Any]]:
    """The dishes on one order sold at a typed price (rung in at or after `since`), in the order of the check."""
    rows: list[dict[str, Any]] = []
    for line in state.ordered_lines():
        priced = line.priced or {}
        typed = priced.get("typed")
        if not isinstance(typed, Mapping) or line.added_at is None or line.status == "removed":
            continue
        at_ms = line.added_at.wall_ms
        if at_ms < since:
            continue
        unit = Decimal(str(priced.get("unit_price", "0")))
        voided = line.status == "void"
        rows.append(
            {
                "order_id": state.order_id,
                "table": state.fields.get("table"),
                "order_no": state.fields.get("order_no"),
                "customer_name": state.fields.get("customer_name"),
                "line_id": line.line_id,
                "item": priced.get("name") or line.item,
                "menu_name": str(typed.get("menu_name") or ""),
                "named": "name" in typed,  # an off-menu dish: its name was typed too
                "qty": line.qty,
                "unit_price": str(unit.quantize(CENT)),
                "amount": str((Decimal(0) if voided else unit * line.qty).quantize(CENT)),
                "voided": voided,
                "by": line.by,
                "by_id": line.by_id,
                "at_ms": at_ms,
            }
        )
    return rows
