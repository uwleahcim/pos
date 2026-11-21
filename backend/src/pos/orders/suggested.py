"""Suggestions taken: how often the dishes a dish suggests were added, and by whom (docs/goes-with.md).

A manager says on each dish which dishes go with it; once it is rung the order screen shows them, one tap
each. A dish added that way says on its line which dish it went with (`Line.went_with`). It is a sale like
any other and no figure changes for it: this report only reads the mark, over the same remembered sales as
the sales report.

`suggestions_report` answers, for a span of days of service:

- `taken` and `amount`: how many suggested dishes were sold and what they came to at their price;
- `dishes`: each dish something was taken with, and each dish that suggests something today and was sold
  in those days with nothing taken; the one that brought the most first. Each says how many of it were
  `sold` in those days (with or without anything), how many suggestions were `taken` with it and for how
  much, and each dish `added`: the ones taken, the most first, then what it suggests today that nobody took;
- `staff`: who rang the suggested dishes in, the most first;
- `running`: one of those days is still running, so the figures will still move.

What came off a check is not in it: a voided dish, one taken off before it was sent, a voided check. A dish
counts at its price, as in the day's report by person: a comp or a discount takes nothing from it.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import date
from decimal import Decimal
from typing import Any

from .. import localtime
from ..menu.defs import Definitions
from .sales import Sale

ZERO = Decimal(0)


class _Taken:
    """How many and for how much."""

    __slots__ = ("amount", "taken")

    def __init__(self) -> None:
        self.taken = 0
        self.amount = ZERO

    def add(self, qty: int, amount: Decimal) -> None:
        self.taken += qty
        self.amount += amount

    def row(self) -> dict[str, Any]:
        return {"taken": self.taken, "amount": str(self.amount.quantize(Decimal("0.01")))}


def _most_first(named: tuple[str, _Taken]) -> Any:
    return (-named[1].taken, -named[1].amount, named[0].casefold())


def suggestions_report(
    sales: Iterable[Sale],
    span: tuple[date, date],
    *,
    defs: Definitions,
    now_ms: int,
) -> dict[str, Any]:
    """The suggestions taken in `span` (first day, last day), from the sales of the orders given: at least
    every order that counts on one of those days."""
    first, last = span
    loc = defs.localizer
    sold: dict[str, int] = {}  # how many of each dish went out, by its code
    names: dict[str, str] = {}  # what each dish was called when it was sold
    with_: dict[str, dict[str, _Taken]] = {}  # the dish it went with, then the dish added
    people: dict[str, tuple[str | None, str, _Taken]] = {}
    total = _Taken()

    for sale in sales:
        if sale.void or not first <= sale.day <= last:
            continue
        for line in sale.lines:
            if line.item is not None:
                sold[line.item] = sold.get(line.item, 0) + line.qty
                names.setdefault(line.item, line.typed or line.name)
            if not line.went_with:
                continue
            code = line.item or line.name
            added = with_.setdefault(line.went_with, {})
            taken = added.get(code)
            if taken is None:
                taken = added[code] = _Taken()
                names.setdefault(code, line.typed or line.name)
            taken.add(line.qty, line.amount)
            who = people.get(line.by_id or line.by)
            if who is None:
                who = people[line.by_id or line.by] = (line.by_id or None, line.by, _Taken())
            who[2].add(line.qty, line.amount)
            total.add(line.qty, line.amount)

    def name_of(code: str) -> str:
        item = defs.items.get(code)
        return (loc.text(item.names, "en") if item is not None else "") or names.get(code) or code

    def suggests(code: str) -> list[str]:
        """What the dish suggests on the menu as it stands: the dishes still on sale, as the screens show."""
        item = defs.items.get(code)
        if item is None or not item.active:
            return []
        return [c for c in item.goes_with if c in defs.items and defs.items[c].active]

    # a dish that suggests something and went out with nothing taken is a row too: the one to look at
    for code, count in sold.items():
        if count > 0 and code not in with_ and suggests(code):
            with_[code] = {}

    dishes: list[tuple[Any, dict[str, Any]]] = []
    for code, added in with_.items():
        whole = _Taken()
        for taken in added.values():
            whole.add(taken.taken, taken.amount)
        rows = sorted(((name_of(item), taken, item) for item, taken in added.items()), key=lambda r: _most_first(r[:2]))
        rows += [(name_of(item), _Taken(), item) for item in suggests(code) if item not in added]
        name, count = name_of(code), sold.get(code, 0)
        dishes.append(
            (
                # the most taken first; with nothing taken, the one that went out the most
                (-whole.taken, -whole.amount, -count, name.casefold()),
                {
                    "item": code,
                    "name": name,
                    "sold": count,
                    **whole.row(),
                    "added": [{"item": item, "name": said, **taken.row()} for said, taken, item in rows],
                },
            )
        )
    dishes.sort(key=lambda entry: entry[0])
    staff = sorted(people.values(), key=lambda who: _most_first((who[1], who[2])))
    return {
        "from": first.isoformat(),
        "to": last.isoformat(),
        "days": (last - first).days + 1,
        "running": first <= localtime.service_day_of(now_ms) <= last,  # the last day is not over yet
        **total.row(),
        "dishes": [row for _, row in dishes],
        "staff": [{"staff_id": staff_id, "name": name, **taken.row()} for staff_id, name, taken in staff],
        "now_ms": now_ms,
    }
