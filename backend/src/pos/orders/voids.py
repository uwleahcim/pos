"""Voids of dishes the kitchen already has: checked by the hub before they are stored, and reported.

A dish the kitchen has not seen simply comes off the check (the log keeps it as `removed`); nothing here
touches that. Once a dish has been sent, taking it off is money leaving the register after the food was
made, so the location's void rules (`settings.voids`) apply, like the pricing rules apply to a comp:

- the void names a reason from the location's list;
- unless the location lets servers void, a manager approves it on the spot: the terminal asks
  `POST /approvals` (purpose `void`) with the manager's PIN and sends the token it gets as `approval`. The
  hub swaps the token for `approved_by`, who it was; nothing a terminal says about approval itself is kept.

Changing a sent dish is not a void: the terminal voids the line and adds the changed dish in its place
(`replaces`) in one batch, and as long as what takes its place holds as many, nothing is asked. Fewer of a
sent dish goes the same way with a smaller quantity, and that is a void of the difference.

A void the rules refuse is left out and reported with its problems, like a refused discount; the line that
would have taken the dish's place is left out with it, so the check stays as it was.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import replace
from decimal import Decimal
from typing import TYPE_CHECKING, Any

from ..identity.powers import May, standard
from ..identity.tokens import Tokens
from ..sync.oplog import Op, OpStore, OrderState, apply

if TYPE_CHECKING:
    from ..sync.pgstore import PgOpStore

CENT = Decimal("0.01")
HUB_ONLY = ("approval", "approved_by", "reason_name")
"""What a terminal's `void_line` never brings into the log itself: the token, and what the hub writes."""


def void_ops(
    rules: Callable[[], Mapping[str, Any]],
    tokens: Tokens,
    store: OpStore | PgOpStore,
    ops: list[Op],
    may: May = standard,
) -> tuple[list[Op], list[dict[str, Any]]]:
    """Check every new void of a sent dish against the location's void rules before it is stored. `rules`
    reads them, and is asked only when a batch holds such a void. `may` says whether a role holds the power
    to approve one (`void`) at this location. The operations earlier in the same batch count: a dish added,
    sent and voided in one batch (a terminal back from an outage) is a sent dish."""
    if not any(op.kind == "void_line" for op in ops):
        return ops, []
    in_place: dict[tuple[str, str], int] = {}  # (order, line) -> how many the line this batch puts in its place holds
    for op in ops:
        if op.kind == "add_line" and isinstance(op.data.get("replaces"), str):
            in_place[(op.order_id, op.data["replaces"])] = _qty(op.data.get("qty", 1))
    kept: list[Op] = []
    refused: list[dict[str, Any]] = []
    stays: set[tuple[str, str]] = set()  # (order, line) whose void was refused: nothing takes its place
    states: dict[str, OrderState] = {}
    current: Mapping[str, Any] | None = None
    for op in ops:
        state = states.get(op.order_id)
        if state is None:
            state = states[op.order_id] = store.state(op.order_id)
        if op.kind == "void_line":
            data = {k: v for k, v in op.data.items() if k not in HUB_ONLY}
            line_id = data.get("line_id")
            line = state.lines.get(line_id) if isinstance(line_id, str) else None
            sent = line is not None and line.active and line.fired_at is not None
            if sent and in_place.get((op.order_id, line_id), 0) < line.qty:
                if current is None:
                    current = rules()
                problems = _problems(current, tokens, op, data, may)
                if problems:
                    refused.append({"op_id": op.op_id, "error": "invalid_void", "problems": problems})
                    stays.add((op.order_id, line_id))
                    continue
            op = replace(op, data=data)
        elif op.kind == "add_line" and (op.order_id, op.data.get("replaces")) in stays:
            problems = [{"code": "void_refused", "message": "the dish this one replaces could not be voided"}]
            refused.append({"op_id": op.op_id, "error": "invalid_line", "problems": problems})
            continue
        apply(state, op)
        kept.append(op)
    for op in [op for op in kept if op.kind == "add_line" and (op.order_id, op.data.get("replaces")) in stays]:
        # sent ahead of the void it goes with (no terminal of ours does): it comes out all the same
        kept.remove(op)
        problems = [{"code": "void_refused", "message": "the dish this one replaces could not be voided"}]
        refused.append({"op_id": op.op_id, "error": "invalid_line", "problems": problems})
    return kept, refused


def _problems(rules: Mapping[str, Any], tokens: Tokens, op: Op, data: dict[str, Any], may: May) -> list[dict[str, str]]:
    """What stops this void of a sent dish; when nothing does, `data` gains what the hub adds to it: the
    reason's name as the location has it now and, when a manager approved, who."""
    problems = []
    reason = next((r for r in rules.get("reasons", ()) if r.get("id") == data.get("reason")), None)
    if reason is None:
        problems.append({"code": "unknown_reason", "message": "a void of a sent dish needs a reason from the list"})
    token = op.data.get("approval")
    grant = tokens.verify(token) if isinstance(token, str) else None
    approved = grant is not None and grant.scope == f"void:{op.order_id}" and may(grant.role, "void")
    if rules.get("approval", "manager") != "none" and not approved:
        problems.append({"code": "needs_approval", "message": "a void of a sent dish needs a manager's PIN"})
    if problems:
        return problems
    if reason is not None:
        data["reason_name"] = str(reason.get("name") or "")
    if grant is not None and approved:
        data["approved_by"] = {"staff_id": grant.staff_id, "name": grant.name}
    return []


def _qty(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def void_rows(state: OrderState, since: int = 0) -> list[dict[str, Any]]:
    """The voids of sent dishes on one order, for the report: the dish, how many of it and what they were
    worth, why, who voided and who approved, and when (`at_ms`; only those at or after `since`). Fewer of a
    dish counts the difference; a changed dish (as many sent again in its place) is not a void. A void made
    before reasons were asked has neither a reason nor an approver."""
    replaced_by = {}
    for line in state.ordered_lines():
        if line.replaces:
            replaced_by.setdefault(line.replaces, line)
    rows = []
    for line in state.ordered_lines():
        if line.status != "void":
            continue
        again = replaced_by.get(line.line_id)
        qty = line.qty - (again.qty if again is not None else 0)
        voided = line.voided or {}
        at_ms = int(voided.get("at_ms") or 0)
        if qty <= 0 or at_ms < since:
            continue
        priced = line.priced or {}
        unit = Decimal(str(priced.get("unit_price", "0")))
        rows.append(
            {
                "order_id": state.order_id,
                "table": state.fields.get("table"),
                "order_no": state.fields.get("order_no"),
                "line_id": line.line_id,
                "item": priced.get("name") or line.item,
                "qty": qty,
                "amount": str((unit * qty).quantize(CENT)),
                "reason": voided.get("reason"),
                "reason_name": voided.get("reason_name") or "",
                "by": voided.get("by") or "",
                "by_id": voided.get("by_id"),
                "approved_by": voided.get("approved_by"),
                "at_ms": at_ms,
            }
        )
    return rows
