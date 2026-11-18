"""A driver's runs: what each driver took out over a day of service (docs/delivery.md).

A delivery handed to a driver is out with them until it is marked delivered or comes back
(`stage` out, `driver`, `driver_id`, `out_at`). Each time an order leaves is a **leg**: who took it, when
it left, and what became of it. A **run** is the bags a driver left with in one go: legs of one driver that
left within `RUN_GAP_MS` of the one before while none of them was delivered yet. Bags picked together on the
Deliveries screen leave at the same moment; bags tapped out one after the other at the counter, a few
seconds apart, are the same trip all the same.

Nothing is kept for it. Every leg is read off the order's own log, so the report says what the log says: an
order that came back and left again with somebody else has two legs, one with each driver. A leg counts on
the day of service it left in. The times are when somebody tapped the screen: "delivered" is when it was
marked delivered, which may be at the door or when the driver walked back in.

A check closed while its bag was still out counts as delivered when it was closed: nobody closes a check
for food that is still on the road.

It is about who carried what and when. No money is in it: what a delivery came to, and what was paid on it,
is the check's and the reports' (`pos.orders.sales`).
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date
from typing import Any

from .. import localtime
from ..sync.oplog import Op, OrderState, apply, is_delivery

RUN_GAP_MS = 5 * 60 * 1000
"""Bags that leave with one driver within this long of each other are one run."""

DELIVERED, BACK, HANDED, VOIDED = "delivered", "back", "handed", "void"
"""How a leg ended: at the customer's door, back at the restaurant, in another driver's hands, or with the
order voided. One that has not ended is still out."""


@dataclass
class Leg:
    """One time an order left with a driver."""

    order_id: str
    driver_id: str
    driver: str
    left_ms: int
    end: str | None = None
    end_ms: int | None = None
    to: str = ""  # who took it over, for one that changed hands on the way


def _text(value: Any) -> str:
    return " ".join(str(value or "").split())


def _ms(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def legs_of(ops: Iterable[Op], order_id: str) -> tuple[OrderState, list[Leg], int | None]:
    """The order as its log leaves it, every time it left with a driver (oldest first), and the moment it
    was marked delivered with nobody having taken it out (a hub's own way from ready to delivered), None for
    one that never was. `ops` are the order's operations in any order, duplicates and all."""
    unique: dict[str, Op] = {}
    for op in ops:
        if op.order_id == order_id:
            unique.setdefault(op.op_id, op)
    state = OrderState(order_id=order_id)
    legs: list[Leg] = []
    alone: int | None = None
    out: Leg | None = None
    for op in sorted(unique.values(), key=lambda o: o.sort_key):
        was_stage = state.fields.get("stage")
        try:
            apply(state, op)
        except (KeyError, TypeError, ValueError):
            continue  # an operation the replay cannot read moves nothing; the hub refuses them at the door
        fields = state.fields
        stage = fields.get("stage")
        at = op.hlc.wall_ms
        brought = state.status != "void" and is_delivery(fields)
        going = brought and stage == "out"
        who = (_text(fields.get("driver_id")), _text(fields.get("driver")))
        if out is not None and (not going or who != (out.driver_id, out.driver)):
            # it is no longer out with whoever had it: say what became of it
            if going:
                out.end, out.to = HANDED, who[1]
            elif state.status == "void":
                out.end = VOIDED
            elif brought and stage == "picked_up":
                out.end = DELIVERED
            else:
                out.end = BACK
            out.end_ms = max(at, out.left_ms)
            out = None
        if going and out is None:
            # the moment the screen said it left; one handed on along the way left its new driver's hands now
            said = _ms(fields.get("out_at"))
            fresh = was_stage != "out" or not legs or said != legs[-1].left_ms
            out = Leg(order_id, who[0], who[1], said if said is not None and fresh else at)
            legs.append(out)
        if not brought or stage != "picked_up":
            alone = None  # not delivered, or no longer
        elif was_stage not in ("out", "picked_up"):
            alone = at
    closed = state.closed_at.wall_ms if state.status == "closed" and state.closed_at is not None else None
    if closed is not None and is_delivery(state.fields):
        if out is not None:
            out.end, out.end_ms = DELIVERED, max(closed, out.left_ms)
        elif state.fields.get("stage") not in ("out", "picked_up"):
            alone = closed  # closed from the counter, with no driver named and nobody marking it delivered
    return state, legs, alone


def _bag(state: OrderState, leg: Leg) -> dict[str, Any]:
    fields = state.fields
    took = None if leg.end_ms is None else max(0, (leg.end_ms - leg.left_ms) // 60000)
    return {
        "order_id": leg.order_id,
        "order_no": fields.get("order_no"),
        "customer_name": _text(fields.get("customer_name")),
        "address": _text(fields.get("address")),
        "left_ms": leg.left_ms,
        "outcome": leg.end or "out",
        "at_ms": leg.end_ms,
        "minutes": took,
        **({"to": leg.to} if leg.end == HANDED else {}),
    }


def _runs(legs: list[tuple[OrderState, Leg]]) -> list[dict[str, Any]]:
    """One driver's legs as runs, the first run of the day first."""
    runs: list[list[tuple[OrderState, Leg]]] = []
    for state, leg in sorted(legs, key=lambda each: (each[1].left_ms, _ms(each[0].fields.get("order_no")) or 0)):
        last = runs[-1] if runs else None
        together = (
            last is not None
            and leg.left_ms - last[-1][1].left_ms <= RUN_GAP_MS
            # none of them was at a door yet: the driver had not gone and come
            and not any(o.end == DELIVERED and o.end_ms is not None and o.end_ms <= leg.left_ms for _, o in last)
        )
        if together and last is not None:
            last.append((state, leg))
        else:
            runs.append([(state, leg)])
    listed = []
    for run in runs:
        left = run[0][1].left_ms
        ends = [leg.end_ms for _, leg in run]
        ended = None if any(end is None for end in ends) else max(end for end in ends if end is not None)
        listed.append(
            {
                "left_ms": left,
                "ended_ms": ended,
                "minutes": None if ended is None else max(0, (ended - left) // 60000),
                "bags": [_bag(state, leg) for state, leg in run],
            }
        )
    return listed


def _count(runs: list[dict[str, Any]], outcome: str) -> int:
    return sum(1 for run in runs for bag in run["bags"] if bag["outcome"] == outcome)


def runs_report(logs: Iterable[tuple[str, Iterable[Op]]], day: date) -> dict[str, Any]:
    """The runs of a day of service. `logs` are the orders that may have left in it, each with its
    operations; an order that never left with anybody adds nothing.

    `drivers` is each driver who took something out, the one whose first run left earliest first, with their
    `runs` in the order they left and how many bags were `delivered`, came `back` or are still `out`. A run
    says when it `left_ms`, when its last bag was marked (`ended_ms`, null while one is out) and its `bags`:
    the order's number, name and address, when it left, its `outcome` (`delivered`, `back`, `out`, `handed`
    with `to`, `void`), when that was marked (`at_ms`) and the `minutes` between. The totals count every
    driver. `no_driver` counts the deliveries marked delivered that day with nobody having taken them out."""
    since, until = localtime.service_day(day)
    by_driver: dict[tuple[str, str], list[tuple[OrderState, Leg]]] = {}
    no_driver = 0
    for order_id, ops in logs:
        state, legs, alone = legs_of(ops, order_id)
        if alone is not None and since <= alone < until:
            no_driver += 1
        for leg in legs:
            if since <= leg.left_ms < until:
                # by the id the hub knows them by; by the name for one a screen named without an id
                key = (leg.driver_id, "" if leg.driver_id else leg.driver)
                by_driver.setdefault(key, []).append((state, leg))
    drivers = []
    for (driver_id, _), legs_ in by_driver.items():
        runs = _runs(legs_)
        drivers.append(
            {
                "driver_id": driver_id,
                "driver": max(legs_, key=lambda each: each[1].left_ms)[1].driver,  # as last named
                "runs": len(runs),
                "delivered": _count(runs, DELIVERED),
                "back": _count(runs, BACK),
                "out": _count(runs, "out"),
                "list": runs,
            }
        )
    drivers.sort(key=lambda d: (d["list"][0]["left_ms"], d["driver"]))
    return {
        "day": day.isoformat(),
        "since_ms": since,
        "until_ms": until,
        "runs": sum(d["runs"] for d in drivers),
        "delivered": sum(d["delivered"] for d in drivers),
        "back": sum(d["back"] for d in drivers),
        "out": sum(d["out"] for d in drivers),
        "no_driver": no_driver,
        "drivers": drivers,
    }
