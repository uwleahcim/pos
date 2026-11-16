"""Splitting a check: one table, several checks.

A split never makes a second order. The dishes stay on the one order the kitchen cooked from, and the order
says how the table pays (its `split` field):

- `{by: seat}`: a check for each seat. A dish is on its seat's check; a dish for the table (no seat) is
  shared by every check.
- `{by: dish}`: the dishes were put on checks by hand. A dish nobody placed is on check 1.
- `{by: even, ways: n}`: the dishes stay together and the total is cut in `n` equal parts.

Under the first two a dish can be put on other checks than the rule gives it: the line's `checks`, one
number to move it, several to share it between them in equal parts. That is the check's business alone:
the dish keeps its seat, and the kitchen hears nothing.

A check is known by its number and keeps it while it holds a dish: under `seat` the number is the seat's.
Checks that hold nothing are not there, so the numbers can have gaps.

`split_checks` is the money, for `pos.orders.check.check_for`: what each check comes to, with every discount
and charge carried over in proportion and the tax divided the same way, so the checks add up to the cent to
what the table owes as one. Splitting never changes what the table owes.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date
from decimal import ROUND_DOWN, Decimal
from typing import Any

from ..sync.oplog import MAX_CHECKS, OrderState
from ..tax import TaxableLine, TaxLine, TaxProfile

ZERO = Decimal(0)
CENT = Decimal("0.01")


@dataclass(frozen=True)
class Split:
    """How an order's table pays: `by` is seat, dish or even; empty for one check. `ways` counts an even
    split's parts."""

    by: str = ""
    ways: int = 0

    def as_json(self) -> dict[str, Any] | None:
        if not self.by:
            return None
        return {"by": self.by, "ways": self.ways} if self.by == "even" else {"by": self.by}


ONE = Split()


def split_of(fields: Mapping[str, Any]) -> Split:
    """The order's split as its `split` field says it. Whatever cannot be read is one check, and so is an
    even split in fewer than two parts."""
    said = fields.get("split")
    if not isinstance(said, Mapping):
        return ONE
    by = said.get("by")
    if by in ("seat", "dish"):
        return Split(by)
    ways = said.get("ways")
    if by == "even" and isinstance(ways, int) and not isinstance(ways, bool) and 2 <= ways <= MAX_CHECKS:
        return Split("even", ways)
    return ONE


def placed(state: OrderState, split: Split) -> tuple[list[int], dict[str, list[int]]]:
    """Which checks there are, by number, and which of them each live dish is on (several: shared between
    them). Empty when the table is not split by its dishes."""
    if split.by not in ("seat", "dish"):
        return [], {}
    own: dict[str, list[int] | None] = {}  # None: the table's, shared by every check
    for line in state.ordered_lines():
        if not line.active:
            continue
        if line.checks:
            own[line.line_id] = line.checks
        elif split.by == "dish":
            own[line.line_id] = [1]
        else:
            seat = line.seat
            seated = isinstance(seat, int) and not isinstance(seat, bool) and 1 <= seat <= MAX_CHECKS
            own[line.line_id] = [seat] if seated else None
    numbers = sorted({n for on in own.values() if on for n in on})
    if not numbers:
        return [], {}  # every dish is the table's: there is nothing to tell the checks apart by
    return numbers, {line_id: on or numbers for line_id, on in own.items()}


def parts(amount: Decimal, n: int) -> list[Decimal]:
    """`amount` in `n` equal parts that add up to it; the odd cents go to the first parts, one each."""
    each = (amount / n).quantize(CENT, rounding=ROUND_DOWN)
    odd = int((amount - each * n) / CENT)
    return [each + CENT if i < odd else each for i in range(n)]


def prorate(amount: Decimal, weights: Sequence[Decimal]) -> list[Decimal]:
    """`amount` divided in proportion to `weights`, to the cent and adding up to it: each part is rounded
    down and the cents left over go to the parts that lost most by it. In equal parts when nothing weighs."""
    total = sum(weights, ZERO)
    if total <= ZERO:
        return parts(amount, len(weights))
    exact = [amount * w / total for w in weights]
    shares = [e.quantize(CENT, rounding=ROUND_DOWN) for e in exact]
    left = int((amount - sum(shares, ZERO)) / CENT)
    by_loss = sorted(range(len(weights)), key=lambda i: (shares[i] - exact[i], i))
    for i in by_loss[:left]:
        shares[i] += CENT
    return shares


def split_checks(
    state: OrderState,
    split: Split,
    *,
    lines: Sequence[Mapping[str, Any]],
    taken: Sequence[tuple[Mapping[str, Any], Mapping[str, Decimal]]],
    charges: Sequence[tuple[Mapping[str, Any], str]],
    tax_classes: Mapping[str, str],
    tax_lines: Sequence[TaxLine],
    taxes: TaxProfile,
    order_type: str,
    on: date | None,
    total: Decimal,
) -> list[dict[str, Any]]:
    """The table's checks, each with its dishes and what it comes to; empty for a table on one check.

    `lines` are the check's rows, `taken` each discount's row with what it took off each line, `charges`
    each charge's row with its tax class, `tax_lines` and `total` the table's tax and total as one check.
    """
    if split.by == "even":
        totals = parts(total, split.ways)
        paid = _paid(state, list(range(1, split.ways + 1)), totals)
        return [
            {"check": n, "lines": [], "total": _s(totals[i]), **paid[i]} for i, n in enumerate(range(1, split.ways + 1))
        ]
    numbers, placed_on = placed(state, split)
    if len(numbers) < 2:
        return []
    at = {n: i for i, n in enumerate(numbers)}
    rows: list[list[dict[str, Any]]] = [[] for _ in numbers]
    subtotal = [ZERO] * len(numbers)
    net = [ZERO] * len(numbers)
    off: list[dict[str, Decimal]] = [{} for _ in numbers]  # discount id -> what it took off this check
    taxable: list[list[TaxableLine]] = [[] for _ in numbers]
    for row in lines:
        line_id = row["line_id"]
        on_checks = placed_on.get(line_id) or [numbers[0]]
        n = len(on_checks)
        worth = parts(Decimal(row["total"]), n)
        # Each discount on the dish, in the order it was taken: a check's part of it is what the dish's
        # discounts so far come to there, less what the earlier ones did, so no part goes below nothing.
        gone, before = ZERO, [ZERO] * n
        for discount, by_line in taken:
            amount = by_line.get(line_id, ZERO)
            if amount <= ZERO:
                continue
            gone += amount
            now = parts(gone, n)
            for j, number in enumerate(on_checks):
                share = now[j] - before[j]
                if share:
                    took = off[at[number]]
                    took[discount["discount_id"]] = took.get(discount["discount_id"], ZERO) + share
            before = now
        for j, number in enumerate(on_checks):
            i = at[number]
            left = worth[j] - before[j]
            subtotal[i] += worth[j]
            net[i] += left
            taxable[i].append(TaxableLine(line_id, tax_classes[line_id], left))
            rows[i].append(
                {
                    "line_id": line_id,
                    "name": row["name"],
                    "qty": row["qty"],
                    "seat": row["seat"],
                    "shared": [m for m in on_checks if m != number],  # the other checks it is shared with
                    "of": row["total"],  # what the whole dish comes to
                    "total": _s(worth[j]),
                    "discount": _s(before[j]),
                    "modifiers": row["modifiers"],
                }
            )

    charged: list[list[dict[str, Any]]] = [[] for _ in numbers]
    charge_total = [ZERO] * len(numbers)
    for charge, tax_class in charges:
        for i, share in enumerate(prorate(Decimal(charge["amount"]), net)):
            charge_total[i] += share
            taxable[i].append(TaxableLine(f"charge:{charge['charge_id']}", tax_class, share))
            if share:
                charged[i].append({"charge_id": charge["charge_id"], "name": charge["name"], "amount": _s(share)})

    # The table's tax, each jurisdiction's line divided by what every check holds that it taxes.
    tax = [ZERO] * len(numbers)
    bases = [{t.component: t.base for t in taxes.compute(mine, order_type, on)} for mine in taxable]
    for line in tax_lines:
        for i, share in enumerate(prorate(line.amount, [base.get(line.component, ZERO) for base in bases])):
            tax[i] += share

    totals = [net[i] + charge_total[i] + tax[i] for i in range(len(numbers))]
    paid = _paid(state, numbers, totals)
    out = []
    for i, number in enumerate(numbers):
        discounts = [
            {
                "discount_id": discount["discount_id"],
                "name": discount["name"],
                "line_id": discount["line_id"],
                "amount": _s(off[i][discount["discount_id"]]),
            }
            for discount, _ in taken
            if off[i].get(discount["discount_id"], ZERO) > ZERO
        ]
        out.append(
            {
                "check": number,
                "lines": rows[i],
                "subtotal": _s(subtotal[i]),
                "discounts": discounts,
                "discount_total": _s(subtotal[i] - net[i]),
                "charges": charged[i],
                "charge_total": _s(charge_total[i]),
                "tax": _s(tax[i]),
                "total": _s(totals[i]),
                **paid[i],
            }
        )
    return out


def _s(amount: Decimal) -> str:
    """An amount as the check says it: to the cent, "0.00" for nothing."""
    return str(amount.quantize(CENT))


def _paid(state: OrderState, numbers: Sequence[int], totals: Sequence[Decimal]) -> list[dict[str, Any]]:
    """What was paid on each check and what it still owes. A payment that names a check is that check's. One
    that names none (or a check no longer there) was for the table: it goes to the checks in order, each
    up to what it still owes, and whatever is over stays with the first."""
    at = {n: i for i, n in enumerate(numbers)}
    paid = [ZERO] * len(numbers)
    rows: list[list[dict[str, Any]]] = [[] for _ in numbers]
    payments = sorted(state.payments.items(), key=lambda kv: kv[1].stamp or "")
    for pid, p in payments:
        if p.check in at:
            paid[at[p.check]] += Decimal(p.amount or "0")
            rows[at[p.check]].append({"payment_id": pid, **p.as_json()})
    for pid, p in payments:
        if p.check in at:
            continue
        left = Decimal(p.amount or "0")
        poured = [ZERO] * len(numbers)
        for i, owed in enumerate(totals):
            take = min(left, max(owed - paid[i], ZERO))
            poured[i] += take
            left -= take
        poured[0] += left
        for i, amount in enumerate(poured):
            if amount > ZERO:
                paid[i] += amount
                whole = amount == Decimal(p.amount or "0")
                row = {"payment_id": pid, **p.as_json(), "amount": _s(amount)}
                rows[i].append(row if whole else {**row, "tendered": None})
    return [
        {"payments": rows[i], "paid": _s(paid[i]), "due": _s(max(totals[i] - paid[i], ZERO))}
        for i in range(len(numbers))
    ]


__all__ = ["ONE", "Split", "parts", "placed", "prorate", "split_checks", "split_of"]
