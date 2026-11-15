"""The number left of a dish, kept in step with the checks before a batch of operations is stored.

Whoever 86s a dish may type a number left instead (`POST /menu/86` with `remaining`). From then on the
number follows the checks: a dish going on one takes it down by the line's quantity, a dish coming off
(removed before it was sent, voided after, its whole order voided) gives it back, never above the number
that was typed, and at zero the menu shows the dish sold out. The count is gone when the night is over
(`localtime.night_end`). This adds a count to the 86 rules of the Menu Engine Design, with the owner's yes
(2026-11-15); the 86 itself, set by hand and staying until it is cleared, is as it was.

What one of a line takes is on its priced snapshot (`uses`: the dish itself and the dishes inside it, the
soup with a lunch special, each roll of a maki combination); a line with no `uses` takes one of its own
dish, which is also how a line from before there were counts is read.

The hub counts by the difference an operation makes to what its order holds, so every way a dish can come
off a check gives it back without a rule of its own. A sent dish that is changed is a void and a new line
in one batch (`replaces`); the two are weighed together, so changing the last one of a dish after it sold
out takes nothing, and when the change asks for more than is left neither is stored and the check stays as
it was. An operation that asks for more than is left (a new line, a larger quantity) is left out and
reported like a line the menu refuses; the rest of the batch goes through.

A void gives the dish back even when the kitchen had already made it: if that one went in the bin, the
number is typed again. And a count is one number on one hub: two screens cannot both sell the last one
(`MenuService.counting`), while a terminal taking orders with no hub to ask sells from the number it last
saw and hears about it when its orders arrive.
"""

from __future__ import annotations

from collections.abc import Collection
from copy import deepcopy
from typing import TYPE_CHECKING, Any

from ..sync.oplog import Line, Op, OpStore, OrderState, apply

if TYPE_CHECKING:
    from ..menu.service import MenuService
    from ..sync.pgstore import PgOpStore

RAISES = frozenset({"add_line", "set_line"})
"""The operations that can put more of a dish on a check; every other kind only keeps or gives back."""


def uses(line: Line) -> dict[str, int]:
    """How many of each dish one of this line takes, by variant id."""
    priced = line.priced or {}
    listed = priced.get("uses")
    if isinstance(listed, dict):
        return {str(t): n for t, n in listed.items() if isinstance(n, int) and not isinstance(n, bool) and n > 0}
    variant = priced.get("variant_id")
    return {variant: 1} if isinstance(variant, str) else {}


def holds(state: OrderState, targets: Collection[str]) -> dict[str, int]:
    """How many of each of `targets` the order holds: on its live lines, and none once the order is voided."""
    held = dict.fromkeys(targets, 0)
    if state.status == "void":
        return held
    for line in state.lines.values():
        if not line.active:
            continue
        qty = _qty(line.qty)
        for target, n in uses(line).items():
            if target in held:
                held[target] += n * qty
    return held


def count_ops(
    menu: MenuService, store: OpStore | PgOpStore, ops: list[Op]
) -> tuple[list[Op], list[dict[str, Any]], dict[str, int]]:
    """Weigh a batch against the numbers left before it is stored: the operations to store, the ones left
    out (each with why, in words for a screen), and what the stored ones take of each counted dish
    (negative: what they give back) for `MenuService.take` once they are in the log. With no dish counted
    the batch comes back untouched and nothing is read."""
    counts = menu.counts()
    if not counts or not ops:
        return ops, [], {}
    left = {target: state.remaining or 0 for target, state in counts.items()}
    taken = dict.fromkeys(counts, 0)
    partner = _partners(ops)
    settled: dict[str, dict[str, Any] | None] = {}  # weighed ahead with its partner: None stored, else why not
    kept: list[Op] = []
    refused: list[dict[str, Any]] = []
    states: dict[str, OrderState] = {}
    held: dict[str, dict[str, int]] = {}
    for op in ops:
        if op.op_id in settled:
            why = settled[op.op_id]
            if why is None:
                kept.append(op)
            else:
                refused.append({**why, "op_id": op.op_id})
            continue
        state = states.get(op.order_id)
        if state is None:
            state = states[op.order_id] = store.state(op.order_id)
            held[op.order_id] = holds(state, counts)
        together = [op, partner[op.op_id]] if op.op_id in partner else [op]
        was = held[op.order_id]
        after = deepcopy(state) if any(o.kind in RAISES for o in together) else state
        for each in together:
            apply(after, each)
        now = holds(after, counts)
        short = [t for t in counts if now[t] > was[t] and taken[t] + now[t] - was[t] > left[t]]
        if short:
            why = {
                "error": "none_left",
                "problems": [
                    {"code": "none_left", "message": _none_left(menu.target_name(t), left[t] - taken[t])} for t in short
                ],
            }
            refused.append({**why, "op_id": op.op_id})
            for each in together[1:]:
                settled[each.op_id] = why
            continue
        states[op.order_id], held[op.order_id] = after, now
        for target in counts:
            taken[target] += now[target] - was[target]
        kept.append(op)
        for each in together[1:]:
            settled[each.op_id] = None
    return kept, refused, {target: n for target, n in taken.items() if n}


def _partners(ops: list[Op]) -> dict[str, Op]:
    """A changed dish is a void and the line that takes its place (`replaces`): each one's other half, by
    operation id, for the pairs this batch holds whole."""
    voids = {(op.order_id, op.data.get("line_id")): op for op in ops if op.kind == "void_line"}
    out: dict[str, Op] = {}
    for op in ops:
        if op.kind != "add_line" or not isinstance(op.data.get("replaces"), str):
            continue
        void = voids.get((op.order_id, op.data["replaces"]))
        if void is not None and void.op_id not in out:
            out[op.op_id], out[void.op_id] = void, op
    return out


def _none_left(name: str, left: int) -> str:
    return f"No {name} left." if left <= 0 else f"Only {left} {name} left."


def _qty(value: Any) -> int:
    try:
        return max(int(value), 0)
    except (TypeError, ValueError):
        return 0
