"""Dishes taken off a check before the kitchen saw them, for the manager's report.

A dish the kitchen has not seen simply comes off the check, with nothing asked: that is the rule of the
order screen and it stays. Nothing prints and nothing is voided, so until now no report showed it. The log
has always kept the removal; this reads it back: every dish taken off before it was sent, and every time
fewer of an unsent dish were kept, with what it was worth, who did it, on which screen, when, and how long
the dish had been on the check. A slip of the finger is on the check for seconds; a dish that was served
and then taken off was there a good while.

A dish changed before it was sent (taken off with as many put in its place) is not one. Fewer in its place
counts the difference, as with a void.
"""

from __future__ import annotations

from collections.abc import Mapping
from decimal import Decimal
from typing import Any

from ..sync.oplog import Line, OrderState

CENT = Decimal("0.01")


def taken_off_rows(state: OrderState, since: int = 0) -> list[dict[str, Any]]:
    """The dishes taken off one order before they were sent (at or after `since`), in the order of the check."""
    replaced_by: dict[str, Line] = {}
    for line in state.ordered_lines():
        if line.replaces:
            replaced_by.setdefault(line.replaces, line)
    rows: list[dict[str, Any]] = []
    for line in state.ordered_lines():
        if line.added_at is None:
            continue  # a removal that reached the log before its dish, or without one: nothing was rung in
        for cut in line.cuts:
            _row(rows, state, line, int(cut.get("qty") or 0), cut, since)
        if line.status == "removed" and not line.moved:  # gone to another check is not taken off
            again = replaced_by.get(line.line_id)
            _row(rows, state, line, line.qty - (again.qty if again is not None else 0), line.removed or {}, since)
    return rows


def _row(
    rows: list[dict[str, Any]], state: OrderState, line: Line, qty: int, took: Mapping[str, Any], since: int
) -> None:
    at_ms = int(took.get("at_ms") or 0)
    if qty <= 0 or at_ms < since:
        return
    priced = line.priced or {}
    unit = Decimal(str(priced.get("unit_price", "0")))
    added_ms = line.added_at.wall_ms if line.added_at is not None else at_ms
    rows.append(
        {
            "order_id": state.order_id,
            "table": state.fields.get("table"),
            "order_no": state.fields.get("order_no"),
            "customer_name": state.fields.get("customer_name"),
            "line_id": line.line_id,
            "item": priced.get("name") or line.item,
            "qty": qty,
            "amount": str((unit * qty).quantize(CENT)),
            "by": took.get("by") or "",
            "by_id": took.get("by_id"),
            "rung_by": line.by,
            "device": took.get("device") or "",
            "at_ms": at_ms,
            "on_check_ms": max(at_ms - added_ms, 0),
        }
    )


def by_check(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The rows added up for each check: what came off it and how many times, the most first."""
    totals: dict[str, dict[str, Any]] = {}
    for row in rows:
        total = totals.setdefault(
            row["order_id"],
            {
                "order_id": row["order_id"],
                "table": row["table"],
                "order_no": row["order_no"],
                "customer_name": row["customer_name"],
                "amount": Decimal(0),
                "count": 0,
            },
        )
        total["amount"] += Decimal(row["amount"])
        total["count"] += 1
    ranked = sorted(totals.values(), key=lambda total: (-total["amount"], -total["count"], total["order_id"]))
    return [{**total, "amount": str(total["amount"])} for total in ranked]
