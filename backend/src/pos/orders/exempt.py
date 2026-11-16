"""A check a manager marked exempt from sales tax: who it is for, under which certificate, and who said so.

Some buyers pay no meals tax (a school, a church, a town office with a certificate of exemption). The tax
rules decide what a class of dish is taxed as; this is the other half the architecture names (section 9,
"Exemption"): a manager's override on one order, logged and reported.

The mark is an order field, `tax_exempt`, set like any field (`set_field`), so a hub that does not know it
simply leaves the tax on. Before it is stored the hub checks it, as it checks a void or a comp:

- it names the organisation and the number of its certificate, both in words that were typed;
- a manager approves it on the spot: the terminal asks `POST /approvals` (purpose `exempt`) with the
  manager's PIN and sends the token it gets as `approval`. The hub swaps the token for who it was; nothing
  a terminal says about approval itself is kept;
- the check is open and no money has been taken on it: what was paid was paid with the tax in it.

Taking the mark off (`tax_exempt: null`) puts the tax back, and anyone who has the check open may do it.

Nothing about a sale changes: an exempt check is in Sales and The day with every dish on it. Only the tax
is not charged, and the reports say on how many checks, on how much, and how much tax that was.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import replace
from decimal import Decimal
from typing import TYPE_CHECKING, Any

from ..identity.tokens import Tokens
from ..sync.oplog import ORDER_FIELDS, Op, OpStore, OrderState, apply
from .adjustments import APPROVERS

if TYPE_CHECKING:
    from ..sync.pgstore import PgOpStore

FIELD = "tax_exempt"
ORGANISATION_MAX = 60
"""How long the organisation's name may be: a line of the bill and a little more."""
CERTIFICATE_MAX = 40
HUB_ONLY = ("approval", "approved_by")
"""What a terminal's operation never brings into the log itself: the token, and what the hub writes."""
ZERO = Decimal(0)


def exemption_of(fields: Mapping[str, Any]) -> dict[str, Any] | None:
    """The exemption an order carries, or None: the organisation, its certificate's number, the manager who
    approved it (`approved_by`, `approved_by_id`), who marked it (`by`) and when (`at_ms`). A mark with no
    manager behind it is no exemption: only the hub writes one, after the PIN."""
    value = fields.get(FIELD)
    if not isinstance(value, Mapping):
        return None
    organisation, certificate = _words(value.get("organisation")), _words(value.get("certificate"))
    approved = value.get("approved_by")
    if not organisation or not certificate or not isinstance(approved, Mapping) or not approved.get("staff_id"):
        return None
    at_ms = value.get("at_ms")
    return {
        "organisation": organisation,
        "certificate": certificate,
        "approved_by": str(approved.get("name") or ""),
        "approved_by_id": str(approved.get("staff_id")),
        "by": str(value.get("by") or ""),
        "at_ms": at_ms if isinstance(at_ms, int) and not isinstance(at_ms, bool) else None,
    }


def exempt_ops(tokens: Tokens, store: OpStore | PgOpStore, ops: list[Op]) -> tuple[list[Op], list[dict[str, Any]]]:
    """Check every new mark of a check as tax exempt before it is stored. A mark the rules refuse is left
    out and reported with its problems, like a refused discount; whatever else its operation says of the
    order (a `create` with its table and guests) goes through without it. The operations earlier in the
    same batch count: a payment and a mark sent together are a mark on a paid check."""
    if not any(_marks(op) for op in ops):
        return ops, []
    kept: list[Op] = []
    refused: list[dict[str, Any]] = []
    states: dict[str, OrderState] = {}
    for op in ops:
        state = states.get(op.order_id)
        if state is None:
            state = states[op.order_id] = store.state(op.order_id)
        if _marks(op):
            data = {k: v for k, v in op.data.items() if k not in HUB_ONLY}
            problems = _problems(tokens, state, op, data)
            if problems:
                refused.append({"op_id": op.op_id, "error": "invalid_exemption", "problems": problems})
                del data[FIELD]
                if op.kind != "create" and not any(name in ORDER_FIELDS for name in data):
                    continue  # it said nothing else of the order
            op = replace(op, data=data)
        try:
            apply(state, op)
        except (KeyError, TypeError, ValueError):
            pass  # an operation the replay cannot read changes nothing here; the store refuses or keeps it
        kept.append(op)
    return kept, refused


def _marks(op: Op) -> bool:
    return op.kind in ("create", "set_field") and FIELD in op.data


def _problems(tokens: Tokens, state: OrderState, op: Op, data: dict[str, Any]) -> list[dict[str, str]]:
    """What stops this mark; when nothing does, `data` holds the mark as the hub writes it: the two things
    typed, who marked it and when, and the manager who approved."""
    wanted = data[FIELD]
    if state.status != "open":
        return [{"code": "closed", "message": "This check is closed. Reopen it to change its tax."}]
    if wanted is None or wanted is False:
        data[FIELD] = None
        return []
    if not isinstance(wanted, Mapping):
        return [{"code": "bad_request", "message": "an exemption names the organisation and its certificate"}]
    problems = []
    organisation, certificate = _words(wanted.get("organisation")), _words(wanted.get("certificate"))
    if not organisation:
        problems.append({"code": "no_organisation", "message": "Say who the check is for."})
    elif len(organisation) > ORGANISATION_MAX:
        problems.append({"code": "bad_value", "message": f"The name takes {ORGANISATION_MAX} letters."})
    if not certificate:
        problems.append({"code": "no_certificate", "message": "The number of the certificate is needed."})
    elif len(certificate) > CERTIFICATE_MAX:
        problems.append({"code": "bad_value", "message": f"The number takes {CERTIFICATE_MAX} letters."})
    if any(_amount(p.amount) > ZERO for p in state.payments.values()):
        message = "Money has been taken on this check. A check is marked exempt before it is paid."
        problems.append({"code": "paid", "message": message})
    token = op.data.get("approval")
    grant = tokens.verify(token) if isinstance(token, str) else None
    if grant is None or grant.role not in APPROVERS or grant.scope != f"exempt:{op.order_id}":
        problems.append({"code": "needs_approval", "message": "Marking a check tax exempt needs a manager's PIN."})
    if problems or grant is None:
        return problems
    approved = {"staff_id": grant.staff_id, "name": grant.name}
    data[FIELD] = {
        "organisation": organisation,
        "certificate": certificate,
        "by": str(data.get("by") or ""),
        "by_id": data.get("by_id") if isinstance(data.get("by_id"), str) else None,
        "at_ms": op.hlc.wall_ms,
        "approved_by": approved,
    }
    data["approved_by"] = approved  # beside the mark too, where a check's history looks for the manager
    return []


def _amount(value: Any) -> Decimal:
    try:
        return Decimal(str(value or "0"))
    except ArithmeticError:
        return ZERO


def _words(value: Any) -> str:
    return " ".join(value.split()) if isinstance(value, str) else ""


__all__ = ["CERTIFICATE_MAX", "FIELD", "ORGANISATION_MAX", "exempt_ops", "exemption_of"]
