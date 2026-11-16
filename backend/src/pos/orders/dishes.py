"""Dishes sold over a span of days, best to worst, with their sizes and their options.

The sales report (`pos.orders.sales`) says what the days came to. This says what was sold in them: every
dish, how many and for how much, beside the same days whole weeks earlier, and under each dish the sizes it
went out in and every choice made on it, with how many times. It is reckoned from the same `Sale` of each
check as the sales report, so the two can never disagree, and the same checks count: a check on the day it
was opened (or the day it is for, when that is later), a check voided whole not at all, a dish voided or
taken off not at all.

How it adds up:

- A dish's `amount` is what it was sold for, its options in the price, before comps and discounts: the
  amounts of all the dishes are the sales report's `sales.gross`, and each category's are its category's.
- A dish's sizes add up to the dish. So do the names typed for an off-menu dish.
- An option's `count` is how many of it went out (two egg rolls on each of three platters are six) and
  its `amount` what it added to its dishes. That money is in the dish's amount already, not on top of it.
  The option a dish comes with (white rice, medium) is counted like one that was picked: together the
  options of a group say how the dish went out.
- A dish chosen inside another (the soup of a lunch special, a roll of a combination) is an option of that
  dish, not a dish sold: its own line in the list counts only the ones rung by themselves.

A dish is one line however many menus it is on, under the first menu it stands on today. Every dish on the
menu is listed, sold or not, so that worst first begins with what nobody ordered. Dishes, sizes, options and
categories are called what the menu calls them today; one the menu no longer has keeps the name it was sold
under and stands under "Off the menu now".
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import date
from decimal import Decimal
from typing import Any

from ..menu.defs import Definitions
from ..menu.engine import PREFIXES
from .day import ZERO, _Menu
from .sales import Picked, Sale, span_ms

NOW, BEFORE = 0, 1
LAST = 1_000_000  # sorts after everything the menu still has


class _Sold:
    """How many and for how much, in the span and in the days before."""

    __slots__ = ("amount", "count")

    def __init__(self) -> None:
        self.count = [0, 0]
        self.amount = [ZERO, ZERO]

    def add(self, which: int, count: int, amount: Decimal) -> None:
        self.count[which] += count
        self.amount[which] += amount

    def row(self, **about: Any) -> dict[str, Any]:
        return {
            **about,
            "count": self.count[NOW],
            "amount": str(self.amount[NOW]),
            "before_count": self.count[BEFORE],
            "before_amount": str(self.amount[BEFORE]),
        }

    def most_first(self) -> tuple[Any, ...]:
        return (-self.count[NOW], -self.amount[NOW], -self.count[BEFORE])


class _Dish:
    def __init__(self) -> None:
        self.sold = _Sold()
        self.name = ""  # as it was sold: the name of a dish the menu no longer has
        self.sizes: dict[str, tuple[str, _Sold]] = {}  # variant -> what it was called, how many
        self.typed: dict[str, _Sold] = {}
        self.options: dict[tuple[tuple[str, str, str], ...], tuple[tuple[str, ...], _Sold]] = {}

    def add(self, which: int, line: Any) -> None:
        self.sold.add(which, line.qty, line.amount)
        self.name = line.name or self.name
        size = self.sizes.get(line.variant)
        if size is None:
            size = self.sizes[line.variant] = (line.size, _Sold())
        size[1].add(which, line.qty, line.amount)
        if line.typed and which == NOW:
            self.typed.setdefault(line.typed, _Sold()).add(which, line.qty, line.amount)
        # A choice of a choice follows the choice it belongs to, one level deeper: it is kept under that
        # one, and there are as many of it as of that one.
        above: list[tuple[tuple[tuple[str, str, str], ...], tuple[str, ...], int]] = []
        picked: Picked
        for picked in line.picked:
            del above[picked.depth :]
            path, labels, each = above[-1] if above else ((), (), 1)
            path = (*path, (picked.group, picked.option, picked.word))
            labels = (*labels, picked.label)
            option = self.options.get(path)
            if option is None:
                option = self.options[path] = (labels, _Sold())
            option[1].add(which, picked.qty * each * line.qty, picked.price * each * line.qty)
            above.append((path, labels, picked.qty * each))


def dishes_report(
    sales: Iterable[Sale],
    span: tuple[date, date],
    before: tuple[date, date],
    *,
    defs: Definitions,
    now_ms: int,
) -> dict[str, Any]:
    """The dishes sold in `span` (first day, last day) and in the days `before`, from the sales of the
    orders given: at least every order that counts on a day of either."""
    spans = (span, before)
    dishes: dict[Any, _Dish] = {}
    totals = _Sold()
    for sale in sales:
        if sale.void:
            continue
        which = next((i for i, (first, last) in enumerate(spans) if first <= sale.day <= last), None)
        if which is None:
            continue
        for line in sale.lines:
            # by its code while the menu has it; a dish gone since by its code too, else by its name
            key = line.item if line.item in defs.items else ("gone", line.item or line.name)
            dish = dishes.get(key)
            if dish is None:
                dish = dishes[key] = _Dish()
            dish.add(which, line)
            totals.add(which, line.qty, line.amount)

    menu = _Menu(defs)
    loc = defs.localizer
    shown = {entry.item for entry in defs.entries if entry.visible}
    for code, item in defs.items.items():
        if item.active and code in shown:
            dishes.setdefault(code, _Dish())  # on the menu and nobody ordered it: listed all the same

    def option_name(option: str, word: str, label: str) -> str:
        known = defs.options.get(option)
        if known is None:
            return label
        name = loc.text(defs.option_names(known), "en") or label
        return f"{PREFIXES[word]} {name}" if word in PREFIXES else name

    def group_name(group: str) -> str:
        known = defs.groups.get(group)
        return (loc.text(known.names, "en") if known is not None else "") or ""

    menu_place = {code: i for i, code in enumerate(defs.menus)}
    categories: dict[tuple[str, str], dict[str, Any]] = {}
    rows: list[tuple[Any, dict[str, Any]]] = []
    for key, dish in dishes.items():
        item = defs.items.get(key) if isinstance(key, str) else None
        menu_code, menu_name, category_code, category_name = menu.of({"item": key if item is not None else None})
        name = (
            (loc.text(item.names, "en") if item is not None else "")
            or dish.name
            or str(key[1] if item is None else key)
        )

        sizes: list[tuple[Any, dict[str, Any]]] = []
        known_sizes = len(defs.variants_of(item.code)) if item is not None else 0
        if len(dish.sizes) > 1 or (dish.sizes and known_sizes > 1):
            for variant_id, (said, sold) in dish.sizes.items():
                variant = defs.variants.get(variant_id)
                size_name = (loc.text(variant.names, "en") if variant is not None else "") or said or variant_id
                place = (variant.sort, variant.code) if variant is not None else (LAST, size_name)
                sizes.append((place, sold.row(name=size_name)))

        # the groups in the order the dish asks them, then any it no longer has
        asked = {group.code: i for i, (group, _) in enumerate(defs.attachments_for(item.code))} if item else {}

        def group_place(group: str, top: bool, asked: dict[str, int] = asked) -> tuple[Any, ...]:
            known = defs.groups.get(group)
            return (asked.get(group, LAST) if top else 0, known.sort if known is not None else LAST, group)

        options: list[tuple[Any, dict[str, Any]]] = []
        for path, (labels, sold) in dish.options.items():
            names = [option_name(option, word, label) for (_, option, word), label in zip(path, labels, strict=True)]
            # under its group; a choice of a choice under the choice it belongs to and then its own group
            heading = " · ".join(part for part in (*names[:-1], group_name(path[-1][0])) if part)
            place: list[Any] = []
            for depth, (group, _, _) in enumerate(path):
                place += [group_place(group, depth == 0), 0 if depth == len(path) - 1 else 1]
                if depth < len(path) - 1:
                    place.append(names[depth])
            options.append(((tuple(place), *sold.most_first(), names[-1]), sold.row(group=heading, name=names[-1])))

        on_menu = item is not None and item.active and item.code in shown
        row = dish.sold.row(
            item=item.code if item is not None else None,
            name=name,
            menu=menu_code,
            menu_name=menu_name,
            category=category_code,
            category_name=category_name,
            on_menu=on_menu,
        )
        row["sizes"] = [size for _, size in sorted(sizes, key=lambda pair: pair[0])]
        row["typed"] = [
            {"name": said, "count": sold.count[NOW], "amount": str(sold.amount[NOW])}
            for said, sold in sorted(dish.typed.items(), key=lambda pair: (*pair[1].most_first(), pair[0]))
        ]
        row["options"] = [option for _, option in sorted(options, key=lambda pair: pair[0])]
        rows.append(((*dish.sold.most_first(), name, str(key)), row))

        category = defs.categories.get(category_code)
        its = categories.get((menu_code, category_code))
        if its is None:
            its = categories[(menu_code, category_code)] = {
                "place": (
                    menu_place.get(menu_code, LAST),
                    category.sort if category is not None else LAST,
                    category_name,
                ),
                "sold": _Sold(),
                "dishes": 0,
                "about": {"menu": menu_code, "menu_name": menu_name, "code": category_code, "name": category_name},
            }
        its["dishes"] += 1
        for which in (NOW, BEFORE):
            its["sold"].add(which, dish.sold.count[which], dish.sold.amount[which])

    def about(which: int) -> dict[str, Any]:
        first, last = spans[which]
        since, until = span_ms(first, last)
        return {
            "first": first.isoformat(),
            "last": last.isoformat(),
            "since_ms": since,
            "until_ms": until,
            "running": since <= now_ms < until,
            "count": totals.count[which],
            "amount": str(totals.amount[which]),
        }

    return {
        "span": about(NOW),
        "before": about(BEFORE),
        "dishes": [row for _, row in sorted(rows, key=lambda pair: pair[0])],
        "categories": [
            its["sold"].row(**its["about"], dishes=its["dishes"])
            for its in sorted(categories.values(), key=lambda its: its["place"])
        ],
    }
