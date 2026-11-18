"""A dish going from one check to another: checked by the hub before it is stored.

Tables merge, a guest joins another party, a drink was rung in on the wrong table. The dish is not voided
and rung in again: it goes over as it is, and the log of both checks says so.

A move is two operations, one on each check, and the terminal sends them in this order:

1. the check that takes the dish: an `add_line` that names where the dish comes from
   (`from: {order_id, line_id}`). The hub fills in the dish itself from the check it comes from: what it is,
   how many, its choices, its note, its course, the price it was sold at and who rang it in. A terminal
   says only where it goes (seat, place on the check). A dish the kitchen already has arrives as sent
   (`sent`, the stamp it went at), so no fire sends it a second time and nothing prints for it;
2. the check that lets it go: a `move_line` that names where the dish went (`to: {order_id, line_id}`).
   The hub stores it only when the dish is on the other check, come from this very line. So a dish never
   leaves a check without arriving on another: it cannot be made to vanish by moving it.

Between the two the dish is on both checks for a moment, never on neither. A dish that is no longer on the
check it was to come from (someone voided it meanwhile) is not taken over.

A discount on the dish comes along: a `discount` on the new line that names the one it continues
(`from: {order_id, discount_id}`), see `pos.api.app.adjust_ops`. The number left of a counted dish
(`pos.orders.counts`) does not move: the dish was sold once.

The kitchen is told nothing by these two operations. What it does hear, when food on its way changes table,
is the MOVED slip (`pos.printing.service`).
"""

from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING, Any

from ..sync.oplog import Op, OpStore, OrderState

if TYPE_CHECKING:
    from ..sync.pgstore import PgOpStore

CARRIED = ("item", "qty", "note", "course", "request", "priced", "by", "by_id")
"""What a dish keeps when it changes checks, read from the check it comes from, never from the terminal."""


def carried(op: Op) -> bool:
    """Whether this operation only passes a dish (or its discount) from one check to another: an `add_line`
    or a `discount` the hub has checked against where it comes from, or a `move_line`."""
    return op.kind == "move_line" or (op.kind in ("add_line", "discount") and isinstance(op.data.get("from"), dict))


def carry_ops(store: OpStore | PgOpStore, ops: list[Op]) -> tuple[list[Op], list[dict[str, Any]]]:
    """Check every dish changing checks in a batch. An `add_line` that names where it comes from is filled
    in from there; one that names a check or dish this hub does not know, or a dish no longer on its check,
    is left out and reported, like a line the menu refuses. A `move_line` is left out and reported unless
    its dish is on the other check. The rest of the batch goes through."""
    if not any(op.kind == "move_line" or "from" in op.data for op in ops):
        return ops, []
    out: list[Op] = []
    refused: list[dict[str, Any]] = []
    seen: dict[str, OrderState | None] = {}
    arriving: set[tuple[str, str, str, str]] = set()  # (to order, to line, from order, from line) in this batch

    def order(order_id: str) -> OrderState | None:
        if order_id not in seen:
            seen[order_id] = store.view(order_id)  # shared: read, never changed
        return seen[order_id]

    def refuse(op: Op, error: str, code: str, message: str) -> None:
        refused.append({"op_id": op.op_id, "error": error, "problems": [{"code": code, "message": message}]})

    for op in ops:
        if op.kind == "add_line" and "from" in op.data:
            came = _where(op.data.get("from"))
            source = order(came[0]) if came is not None and came[0] != op.order_id else None
            line = source.lines.get(came[1]) if source is not None and came is not None else None
            if came is None or source is None or line is None or line.added_at is None:
                refuse(op, "invalid_line", "unknown_source", "The check that dish was to come from is not known here.")
                continue
            if not line.active:
                refuse(op, "invalid_line", "gone", "That dish is no longer on the check it was to come from.")
                continue
            data = {k: v for k, v in op.data.items() if k not in CARRIED and k not in ("sent", "done")}
            data.update({name: getattr(line, name) for name in CARRIED})
            table = source.fields.get("table")
            data["from"] = {
                "order_id": came[0],
                "line_id": came[1],
                **({"table": str(table)} if table else {}),
                # a bar tab has no table: its dishes say whose tab they were rung in on
                **({"tab": source.tab_name} if source.is_tab else {}),
            }
            if line.fired_at is not None:
                data["sent"] = str(line.fired_at)
                if line.done:
                    data["done"] = dict(line.done)  # what its stations had made stays made
            arriving.add((op.order_id, str(op.data.get("line_id")), *came))
            op = replace(op, data=data)
        elif op.kind == "move_line":
            to = _where(op.data.get("to"))
            line_id = op.data.get("line_id")
            there = None
            if to is not None and isinstance(line_id, str):
                other = order(to[0])
                there = other.lines.get(to[1]) if other is not None else None
                came = there.moved_from if there is not None else None
                arrived = came is not None and (came["order_id"], came["line_id"]) == (op.order_id, line_id)
                if not arrived and (*to, op.order_id, line_id) not in arriving:
                    to = None
            if to is None or not isinstance(line_id, str):
                refuse(
                    op,
                    "invalid_move",
                    "not_arrived",
                    "The dish did not reach the other check, so it stays on this one.",
                )
                continue
        out.append(op)
    return out, refused


def _where(value: Any) -> tuple[str, str] | None:
    """The check and the dish on it an operation names (`order_id`, `line_id`), or None when it names none."""
    if not isinstance(value, dict):
        return None
    order_id, line_id = value.get("order_id"), value.get("line_id")
    if not isinstance(order_id, str) or not order_id or not isinstance(line_id, str) or not line_id:
        return None
    return order_id, line_id


__all__ = ["CARRIED", "carried", "carry_ops"]
