"""What the restaurant's original POS knew and the online export did not: `data/legacy_pos.json`.

The GloriaFood export (`gloriafood.py`) is the online menu: English names, online prices, the few option
groups the website asks. The restaurant's original POS carried the rest of what a dining room needs, and
Mike's merged sheet of 2026-11-10 put the two side by side. This module adds that rest to definitions that
already hold the export and the bar (`bar.py`):

- the **Chinese name** of a dish (`names.zh`) and the **kitchen label** it printed (`names.kitchen`): the
  ticket shows the Chinese name first and the original POS's label after it, so the wok reads 腰果蝦 and the
  rest of the line reads SHMP CASHEW r, as both did before;
- the **station** a dish printed at when the original POS sent it somewhere else than its category goes
  (sweet and sour chicken to the fryer, the soongs to the wok, the sushi lunches to the sushi bar);
- the **dishes and drinks only the original POS sold**, numbered as it numbered them, in the export's
  categories (or a new one, Desserts);
- the **dining room's price** where it differs from the online one;
- the original POS's **modifier groups**: spice, allergies, preparation words, sauces and ingredients on
  every kitchen dish (with the sheet's NO / EXTRA / SIDE / LIGHT in front of any of them), the sushi bar's
  options, the bar's, the appetizer platter's choices, the wings', a charge for an extra, every option
  carrying the label the kitchen already knows;
- Chinese names for the categories.

A hub seeds all of it with the rest of the menu. A running hub takes what it lacks with `hubctl menu
import --apply` (`seed.py`): the additions, the names and stations it has none of, and the prices still at
the export's; nothing the menu editor changed moves.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .defs import Attachment, Category, Definitions, Entry, Group, Item, Option, Section, Variant, money

LEGACY = Path(__file__).with_name("data") / "legacy_pos.json"
AFTER_THE_EXPORT = 500
"""Dishes added to an export category sort after its own, like the bar's additions (`bar.py`)."""


@dataclass
class LegacyReport:
    named: int = 0  # dishes given a Chinese name or a kitchen label
    stations: int = 0  # dishes sent to another station than their category's
    categories: int = 0  # categories named in Chinese
    new_categories: int = 0
    items: int = 0  # dishes added
    prices: int = 0
    groups: int = 0
    options: int = 0
    attachments: int = 0

    def summary(self) -> str:
        return (
            f"original POS: {self.named} dishes named, {self.stations} re-stationed, {self.items} dishes added, "
            f"{self.prices} prices set, {self.groups} groups with {self.options} options on {self.attachments} "
            f"dishes and categories"
        )


def kitchen_label(zh: str | None, kitchen: str | None) -> str | None:
    """What prints on the ticket for a dish the original POS knew: its Chinese name, then the label the
    original POS printed, when it had both; whichever it had otherwise."""
    parts = [p for p in (zh, kitchen) if p]
    return " ".join(parts) or None


def _names(value: Any) -> dict[str, str]:
    return dict(value) if isinstance(value, Mapping) else {"en": str(value)}


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_") or "x"


def add_legacy(defs: Definitions, path: Path | str = LEGACY) -> LegacyReport:
    return import_legacy(defs, json.loads(Path(path).read_text(encoding="utf-8")))


def import_legacy(defs: Definitions, data: Mapping[str, Any]) -> LegacyReport:
    """Add the file's names, stations, dishes, prices, groups and attachments to `defs`, in place."""
    report = LegacyReport()
    by_name = {defs.localizer.text(c.names, "en"): c.code for c in defs.categories.values()}

    def category(name: str, where: str) -> str:
        code = by_name.get(name)
        if code is None:
            raise ValueError(f"original POS: {where}: no category {name!r}")
        return code

    def sections_of(code: str) -> list[Section]:
        return [s for s in defs.sections.values() if s.id == f"{s.menu}/{code}"]

    # --- categories: Chinese names, and the new ones
    for name, spec in (data.get("categories") or {}).items():
        if spec.get("new"):
            code = _slug(name)
            if code in defs.categories:
                raise ValueError(f"original POS: category {code!r} already exists")
            menu = spec.get("menu", "dinner")
            if menu not in defs.menus:
                raise ValueError(f"original POS: category {name!r}: unknown menu {menu!r}")
            station = spec.get("station")
            if station is not None and station not in defs.stations:
                raise ValueError(f"original POS: category {name!r}: unknown station {station!r}")
            names = {"en": name, **({"zh": spec["zh"]} if spec.get("zh") else {})}
            sort = int(spec.get("sort") or 0)
            defs.add(
                Category(code, names, tax_class=spec.get("tax_class"), station=station, sort=sort),
                Section(f"{menu}/{code}", menu, names, sort=sort),
            )
            by_name[name] = code
            report.new_categories += 1
            continue
        code = category(name, f"category {name!r}")
        if spec.get("zh"):
            held = defs.categories[code]
            defs.categories[code] = replace(held, names={**held.names, "zh": spec["zh"]})
            for section in sections_of(code):
                defs.sections[section.id] = replace(section, names={**section.names, "zh": spec["zh"]})
            report.categories += 1

    # --- dishes the export has: Chinese names, kitchen labels, stations
    for code, spec in (data.get("items") or {}).items():
        item = defs.items.get(code)
        if item is None:
            raise ValueError(f"original POS: names for unknown dish {code!r}")
        names = dict(item.names)
        if spec.get("zh"):
            names["zh"] = spec["zh"]
        label = kitchen_label(spec.get("zh"), spec.get("kitchen"))
        if label:
            names["kitchen"] = label
        station = spec.get("station")
        if station is not None and station not in defs.stations:
            raise ValueError(f"original POS: dish {code!r}: unknown station {station!r}")
        if names != dict(item.names):
            report.named += 1
        if station is not None and station != item.station:
            report.stations += 1
        defs.items[code] = replace(item, names=names, station=station if station is not None else item.station)

    # --- the original POS's modifier groups
    groups: Mapping[str, Mapping[str, Any]] = data.get("groups") or {}
    for code, group in groups.items():
        if code in defs.groups:
            raise ValueError(f"original POS: modifier group {code!r} already exists")
        defs.add(
            Group(
                code,
                _names(group["name"]),
                min_select=int(group.get("min") or 0),
                max_select=group.get("max"),
                allow_quantity=bool(group.get("allow_quantity", False)),
                sort=int(group.get("sort") or 0),
            )
        )
        report.groups += 1
        for sort, opt in enumerate(group.get("options", ())):
            routes_to = opt.get("routes_to")
            if routes_to is not None and routes_to not in defs.stations:
                raise ValueError(f"original POS: option {opt['code']!r} of {code!r}: unknown station {routes_to!r}")
            defs.add(
                Option(
                    f"{code}:{opt['code']}",
                    code,
                    opt["code"],
                    _names(opt["name"]),
                    kitchen_label=opt.get("kitchen_label"),
                    price_mode="delta",
                    price=money(opt.get("price") or 0),
                    is_default=bool(opt.get("default", False)),
                    routes_to=routes_to,
                    sort=sort,
                )
            )
            report.options += 1

    # --- dishes only the original POS sold
    for item_sort, spec in enumerate(data.get("new") or ()):
        code = spec["code"]
        if code in defs.items:
            raise ValueError(f"original POS: dish {code!r} already exists")
        cat_code = category(spec["category"], f"dish {code!r}")
        sections = sections_of(cat_code)
        if not sections:
            raise ValueError(f"original POS: dish {code!r}: category {spec['category']!r} is on no menu")
        station = spec.get("station")
        if station is not None and station not in defs.stations:
            raise ValueError(f"original POS: dish {code!r}: unknown station {station!r}")
        names = {"en": spec["name"]}
        if spec.get("zh"):
            names["zh"] = spec["zh"]
        label = kitchen_label(spec.get("zh"), spec.get("kitchen"))
        if label:
            names["kitchen"] = label
        first = defs.categories[cat_code].sort * 1000 + AFTER_THE_EXPORT + item_sort
        asks = spec.get("asks")
        if asks not in (None, "price", "name"):
            raise ValueError(f"original POS: dish {code!r} asks {asks!r}; it can ask its price or its name")
        defs.add(
            Item(
                code,
                cat_code,
                names,
                aliases=(code,),
                description={"en": spec["description"]} if spec.get("description") else {},
                tax_class=spec.get("tax_class"),
                station=station,
                # typed when the dish is rung: its price (a market price), or what it is and its price (an
                # off-menu dish, the original POS's OPEN FOOD)
                attrs={"legacy_pos": True, **({f"asks_{asks}": True} if asks else {})},
                sort=AFTER_THE_EXPORT + item_sort,
            ),
            Variant(f"{code}:regular", code, "regular", {"en": "Regular"}, money(spec["price"])),
            *(Entry(f"{s.menu}:{code}", s.menu, s.id, code, code, sort=first) for s in sections),
        )
        for sort, group in enumerate(spec.get("groups") or ()):
            if group not in defs.groups:
                raise ValueError(f"original POS: dish {code!r} offers unknown group {group!r}")
            defs.add(Attachment("item", code, group, sort=sort))
            report.attachments += 1
        report.items += 1

    # --- which categories and dishes offer the groups
    for spec in data.get("attachments") or ():
        group = spec["group"]
        if group not in defs.groups:
            raise ValueError(f"original POS: attachment of unknown group {group!r}")
        if "category" in spec:
            owner_kind, owner = "category", category(spec["category"], f"group {group!r}")
        else:
            owner_kind, owner = "item", spec["item"]
            if owner not in defs.items:
                raise ValueError(f"original POS: group {group!r} on unknown dish {owner!r}")
        if any(a.owner_kind == owner_kind and a.owner == owner and a.group == group for a in defs.attachments):
            continue
        sort = 1 + sum(1 for a in defs.attachments if a.owner_kind == owner_kind and a.owner == owner)
        defs.add(Attachment(owner_kind, owner, group, sort=sort))
        report.attachments += 1

    # --- the dining room's prices
    for change in data.get("prices") or ():
        variant_id = change["variant"]
        if variant_id not in defs.variants:
            raise ValueError(f"original POS: price for unknown variant {variant_id!r}")
        defs.variants[variant_id] = replace(defs.variants[variant_id], base_price=money(change["price"]))
        report.prices += 1
    return report
