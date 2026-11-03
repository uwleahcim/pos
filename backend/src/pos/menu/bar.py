"""The bar's menu from `data/bar.json`: the bottles by the pour, the wine list, the cocktails, the beer prices.

Every bottle on the back shelf and the speed rails is an item in a category per shelf (whiskey, vodka,
gin, ...), cooked at the bar station and taxed as alcohol, with one size, the pour, unless the file lists
its sizes (a glass and a bottle of wine, a 1 oz pour of a rare whisky). The file holds the price of each
size, the retail price a pour was derived from (see its `_about`), and the optional choices a category
offers (rocks, neat, up, shot; hot or cold). A category marked `existing` is one the GloriaFood export
already has: its items join it after the export's own (the cocktails go into Mixed Drinks). `prices`
are the printed menu's prices for the export's own items (the beers). `add_bar` puts it all into
definitions that already hold the rest of the menu, so a hub seeds the kitchen and the bar at once and
the menu editor edits both alike. An item with `"visible": false` stays in the catalog but off the order
screen.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .defs import Attachment, Category, Definitions, Entry, Group, Item, Option, Section, Variant, money

BAR = Path(__file__).with_name("data") / "bar.json"
FIRST_SORT = 40
"""The export's categories sort 0 to 30; the bar's come after them, so the order screen shows them last."""
AFTER_THE_EXPORT = 500
"""Entries added to an export category sort after its own, which number far fewer than this per category."""


@dataclass
class BarReport:
    categories: int = 0
    items: int = 0
    prices: int = 0

    def summary(self) -> str:
        return f"bar: {self.categories} categories and {self.items} items added, {self.prices} prices set"


def add_bar(defs: Definitions, path: Path | str = BAR) -> BarReport:
    return import_bar(defs, json.loads(Path(path).read_text(encoding="utf-8")))


def _names(value: Any) -> dict[str, str]:
    return dict(value) if isinstance(value, Mapping) else {"en": str(value)}


def import_bar(defs: Definitions, data: Mapping[str, Any]) -> BarReport:
    """Add the file's categories, items, sizes, menu entries and prices to `defs`; refuse a code already taken."""
    report = BarReport()
    menu = data.get("menu", "dinner")
    station = data.get("station")
    tax_class = data.get("tax_class", "alcohol")
    if menu not in defs.menus:
        raise ValueError(f"bar: unknown menu {menu!r}")
    if station is not None and station not in defs.stations:
        raise ValueError(f"bar: unknown station {station!r}")
    pour = data.get("pour") or {"code": "pour", "name": {"en": "Pour"}}
    groups: Mapping[str, Mapping[str, Any]] = data.get("groups") or {}
    for code, group in groups.items():
        if code in defs.groups:
            raise ValueError(f"bar: modifier group {code!r} already exists")
        defs.add(Group(code, _names(group["name"]), min_select=0, max_select=1, sort=1))
        for sort, opt in enumerate(group.get("options", ())):
            defs.add(
                Option(
                    f"{code}:{opt['code']}",
                    code,
                    opt["code"],
                    _names(opt["name"]),
                    kitchen_label=opt.get("kitchen_label"),
                    sort=sort,
                )
            )
    for cat in data.get("categories", ()):
        code = cat["code"]
        section_id = f"{menu}/{code}"
        existing = bool(cat.get("existing"))
        if existing:
            if code not in defs.categories or section_id not in defs.sections:
                raise ValueError(f"bar: category {code!r} is marked existing but the menu has no such category")
            first = defs.categories[code].sort * 1000 + AFTER_THE_EXPORT
        else:
            if code in defs.categories:
                raise ValueError(f"bar: category {code!r} already exists")
            sort = FIRST_SORT + report.categories
            names = _names(cat["name"])
            defs.add(
                Category(code, names, tax_class=tax_class, station=station, sort=sort),
                Section(section_id, menu, names, sort=sort),
            )
            report.categories += 1
            first = sort * 1000
        for group_sort, group in enumerate(cat.get("groups", ())):
            if group not in groups:
                raise ValueError(f"bar: category {code!r} offers unknown group {group!r}")
            defs.add(Attachment("category", code, group, sort=group_sort))
        size = cat.get("pour") or pour  # how an item that lists no sizes is sold
        for item_sort, item in enumerate(cat.get("items", ())):
            item_code = item["code"]
            if item_code in defs.items:
                raise ValueError(f"bar: item {item_code!r} already exists")
            sizes = item.get("sizes") or [{**size, "price": item["price"]}]
            attrs: dict[str, Any] = {"bar": True}
            if "sizes" not in item and size.get("oz") is not None:
                attrs["pour_oz"] = size["oz"]
            if item.get("retail_750") is not None:
                attrs["retail_750"] = item["retail_750"]
            if item.get("well"):
                attrs["well"] = True
            defs.add(
                Item(
                    item_code,
                    code,
                    {"en": item["name"]},
                    description={"en": item["description"]} if item.get("description") else {},
                    tax_class=item.get("tax_class", tax_class if existing else None),
                    attrs=attrs,
                    active=bool(item.get("active", True)),
                    sort=first % 1000 + item_sort,
                ),
                Entry(
                    f"{menu}:{item_code}",
                    menu,
                    section_id,
                    item_code,
                    None,
                    visible=bool(item.get("visible", True)),
                    sort=first + item_sort,
                ),
            )
            for size_sort, one in enumerate(sizes):
                defs.add(
                    Variant(
                        f"{item_code}:{one['code']}",
                        item_code,
                        one["code"],
                        _names(one["name"]),
                        money(one["price"]),
                        sort=size_sort,
                    )
                )
            report.items += 1
    for change in data.get("prices", ()):
        variant_id = change["variant"]
        if variant_id not in defs.variants:
            raise ValueError(f"bar: price for unknown variant {variant_id!r}")
        defs.variants[variant_id] = replace(defs.variants[variant_id], base_price=money(change["price"]))
        report.prices += 1
    return report
