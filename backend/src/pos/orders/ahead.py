"""The orders ahead: what the kitchen has promised for a time that is still to come, by the day it is for.

An order the customer named a time for (a phone order for tonight at seven, Saturday's catering) is taken
days before it is cooked. The list of open checks holds it among tonight's tables; this is the same orders
read the other way: by the day and the hour they are for, each with what it comes to, what was paid on it
(a deposit) and what is still to collect, and whether it was sent, since an order nobody sent prints no
ticket when its time comes.

Nothing is kept for it. Every figure is the check as the hub reckons it at this moment, and an order is on
the list by what its own log says: it names a time, it is not a table's, it was not voided, and it has not
been handed over. A closed check stays on it until its time has passed: an order paid in full on Tuesday
and closed is still Saturday's food.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import date
from decimal import Decimal
from typing import Any

from .. import localtime
from ..sync.oplog import OrderState, promised_ms
from ..tax import TaxProfile
from .adjustments import PricingRules
from .check import check_for

ZERO = Decimal("0.00")
HANDOVERS = ("pickup", "delivery")
"""How an order leaves: the customer comes for it, or it is brought to an address."""


def is_ahead(state: OrderState, now_ms: int) -> bool:
    """Whether the order is still to come at `now_ms`: a to-go order with a time the customer named, not
    voided, not handed over. An open one stays on the list however late it is, until somebody closes it;
    a closed one only while its time is still ahead."""
    fields = state.fields
    promised = promised_ms(fields.get("promised_at"))
    if promised is None or state.status == "void" or fields.get("for_later") is not True:
        return False
    if str(fields.get("order_type") or "dine_in") == "dine_in" or fields.get("stage") == "picked_up":
        return False
    return state.status == "open" or promised > now_ms


def _text(value: Any) -> str:
    return " ".join(str(value or "").split())


def ahead_row(state: OrderState, taxes: TaxProfile, rules: PricingRules | None) -> dict[str, Any]:
    """One order as the list names it: who and when, how it leaves, what is on it, and the money."""
    fields = state.fields
    check = check_for(state, taxes, rules)
    guests = fields.get("event_guests")
    lines = [line for line in state.ordered_lines() if line.active]
    items: dict[str, int] = {}
    for line in lines:
        name = str((line.priced or {}).get("name") or line.item or "")
        items[name] = items.get(name, 0) + line.qty
    quoted = fields.get("quoted_minutes")
    return {
        "order_id": state.order_id,
        "order_no": fields.get("order_no") if isinstance(fields.get("order_no"), int) else None,
        "customer_name": _text(fields.get("customer_name")),
        "phone": _text(fields.get("phone")),
        "channel": _text(fields.get("channel")),
        "promised_ms": promised_ms(fields.get("promised_at")),
        "quoted_minutes": quoted if isinstance(quoted, int) and not isinstance(quoted, bool) else 0,
        "guests": guests if isinstance(guests, int) and not isinstance(guests, bool) and guests > 0 else None,
        "handover": fields.get("handover") if fields.get("handover") in HANDOVERS else None,
        "address": _text(fields.get("address")),
        "event_note": _text(fields.get("event_note")),
        "status": state.status,
        "stage": str(fields.get("stage") or "new"),
        "dishes": sum(line.qty for line in lines),
        # dishes nobody sent: no ticket prints for them when the order's time comes
        "unsent": sum(line.qty for line in lines if line.fired_at is None and not line.arrived_sent),
        "items": [{"name": name, "qty": qty} for name, qty in items.items()],
        "total": check["total"],
        "paid": check["paid"],
        "due": check["due"],
        "opened_ms": state.first.wall_ms if state.first is not None else None,
    }


def orders_ahead(
    states: Iterable[OrderState], *, now_ms: int, taxes: TaxProfile, rules: PricingRules | None
) -> dict[str, Any]:
    """The orders still to come among `states`, by the day of service each is for, the earliest first. An
    order that is late and still open stands under the day it was for. Each day adds its orders up."""
    days: dict[date, list[dict[str, Any]]] = {}
    for state in states:
        if not is_ahead(state, now_ms):
            continue
        row = ahead_row(state, taxes, rules)
        days.setdefault(localtime.service_day_of(row["promised_ms"]), []).append(row)
    out = []
    for day in sorted(days):
        rows = sorted(days[day], key=lambda row: (row["promised_ms"], row["order_no"] or 0, row["order_id"]))
        out.append(
            {
                "day": day.isoformat(),
                "orders": rows,
                "count": len(rows),
                "guests": sum(row["guests"] or 0 for row in rows),
                "unsent": sum(1 for row in rows if row["unsent"]),
                **{name: str(sum((Decimal(row[name]) for row in rows), ZERO)) for name in ("total", "paid", "due")},
            }
        )
    # (not the moment it was read at: an answer that reads the same is not sent to a screen a second time)
    return {"today": localtime.service_day_of(now_ms).isoformat(), "days": out}
