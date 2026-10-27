"""Import a GloriaFood "Fetch Menu" export (API version 2) into menu definitions.

The restaurant's current online menu is the starting point for the POS menu: categories become categories
and dinner-menu sections, items become items with one variant per size, option groups become modifier
groups attached to the item or the whole category. The format is documented at
https://github.com/GlobalFood/integration_docs/tree/master/fetch_menu.

What the export does not carry is filled from `ImportSettings`: which kitchen station cooks each category,
the tax class behind each GloriaFood tax category, and the lunch hours. Chinese names and kitchen labels
are not in the export; they are added later through the spreadsheet round trip.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .defs import (
    Allergen,
    Attachment,
    Category,
    Definitions,
    Entry,
    Group,
    Item,
    Localizer,
    Menu,
    Option,
    Section,
    Station,
    Variant,
    money,
)

NUMBERED = re.compile(r"^\s*([A-Z]{0,2}\d{1,3}[A-Z]?)\s*:?\s+(.+?)\s*$")
"""'L01:   Sweet & Sour Chicken', '02   Kaniyu', '801: Miso Soup': the menu number, then the name."""

TAGS = {
    "HOT": "spicy",
    "VEGETARIAN": "vegetarian",
    "VEGAN": "vegan",
    "GLUTEN_FREE": "gluten_free",
    "HALAL": "halal",
    "NUT_FREE": "nut_free",
    "DAIRY_FREE": "dairy_free",
    "RAW": "raw",
}

ALLERGENS = {  # GloriaFood allergen name -> allergen code, the nine US majors
    "milk": "milk",
    "eggs": "egg",
    "fish": "fish",
    "crustaceans": "crustacean",
    "shellfish": "crustacean",
    "tree nuts": "tree_nut",
    "nuts": "tree_nut",
    "peanuts": "peanut",
    "wheat": "wheat",
    "gluten": "wheat",
    "soybeans": "soy",
    "soy": "soy",
    "sesame": "sesame",
}


@dataclass
class ImportSettings:
    tax_classes: Mapping[int, str] = field(default_factory=dict)  # GloriaFood tax_category_id -> tax class
    stations: Mapping[str, Mapping[str, str]] = field(default_factory=dict)  # code -> names
    category_stations: Mapping[str, str | None] = field(default_factory=dict)  # category name -> station
    default_station: str | None = None
    lunch_category: str = "Lunch Specials"
    lunch_hours: Mapping[str, Any] = field(
        default_factory=lambda: {"days": [1, 2, 3, 4, 5, 6], "from": "11:00", "to": "15:00"}
    )
    include_inactive_categories: bool = True
    """Online-only switches: the export marks beer and wine inactive because they are not sold online, but
    the bar sells them at the table. Items marked inactive stay out either way."""


@dataclass
class ImportReport:
    categories: int = 0
    items: int = 0
    variants: int = 0
    groups: int = 0
    notes: list[str] = field(default_factory=list)

    def summary(self) -> str:
        return (
            f"{self.categories} categories, {self.items} items, {self.variants} variants, "
            f"{self.groups} modifier groups; {len(self.notes)} notes"
        )


def guess_tax_classes(data: Mapping[str, Any]) -> dict[int, str]:
    """GloriaFood tax categories are ids without names: the one under alcohol categories is alcohol, the one
    under gift certificates is a gift card, and everything else is prepared food."""
    seen: dict[int, set[str]] = {}
    for cat in data.get("categories", ()):
        for item in cat.get("items", ()):
            if item.get("tax_category_id") is not None:
                seen.setdefault(item["tax_category_id"], set()).add(cat["name"].lower())
    out = {}
    for tax_id, names in seen.items():
        if all("gift" in n for n in names):
            out[tax_id] = "gift_card"
        elif all(any(w in n for w in ("beer", "wine", "mixed drink", "cocktail", "liquor")) for n in names):
            out[tax_id] = "alcohol"
        else:
            out[tax_id] = "prepared_food"
    return out


def split_number(name: str) -> tuple[str | None, str]:
    match = NUMBERED.match(name or "")
    if match:
        return match.group(1), match.group(2)
    return None, (name or "").strip()


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_") or "x"


def import_gloriafood(
    data: Mapping[str, Any], settings: ImportSettings | None = None
) -> tuple[Definitions, ImportReport]:
    settings = settings or ImportSettings()
    report = ImportReport()
    taxes = {**guess_tax_classes(data), **settings.tax_classes}
    defs = Definitions(Localizer({"kitchen": ("kitchen", "zh", "en")}))
    for code, names in settings.stations.items():
        defs.add(Station(code, dict(names), (code,)))
    for sort, (code, en) in enumerate(
        [
            ("milk", "Milk"),
            ("egg", "Eggs"),
            ("fish", "Fish"),
            ("crustacean", "Crustacean shellfish"),
            ("tree_nut", "Tree nuts"),
            ("peanut", "Peanuts"),
            ("wheat", "Wheat"),
            ("soy", "Soybeans"),
            ("sesame", "Sesame"),
        ]
    ):
        defs.add(Allergen(code, {"en": en}, True, sort))
    defs.add(Menu("dinner", {"en": "Menu", "zh": "菜单"}, ("pos", "phone"), {}, 0))
    defs.add(
        Menu(
            "lunch",
            {"en": "Lunch", "zh": "午餐"},
            ("pos", "phone"),
            {"weekly": [dict(settings.lunch_hours)]},
            10,
        )
    )

    groups: dict[int, str] = {}

    def group_code(g: Mapping[str, Any]) -> str:
        if g["id"] in groups:
            return groups[g["id"]]
        code = f"{_slug(g['name'])}_{g['id']}"
        groups[g["id"]] = code
        required = bool(g.get("required"))
        max_select = g.get("force_max") or None
        defs.add(
            Group(
                code,
                {"en": g["name"]},
                min_select=max(int(g.get("force_min") or 0), 1) if required else 0,
                max_select=max_select,
                allow_quantity=bool(g.get("allow_quantity")),
                sort=int(g.get("sort") or 0),
            )
        )
        for o in g.get("options", ()):
            number, name = split_number(o["name"])
            kitchen = (o.get("extras") or {}).get("menu_option_kitchen_internal_name") or name
            defs.add(
                Option(
                    f"{code}:{o['id']}",
                    code,
                    str(o["id"]),
                    {"en": name},
                    kitchen_label=kitchen,
                    price_mode="delta",
                    price=money(o.get("price") or 0),
                    is_default=bool(o.get("default")),
                    sort=int(o.get("sort") or 0),
                    active=not o.get("is_out_of_stock", False),
                )
            )
        report.groups += 1
        return code

    for cat in sorted(data.get("categories", ()), key=lambda c: c.get("sort", 0)):
        if not cat.get("active", True) and not settings.include_inactive_categories:
            continue
        if not cat.get("items"):
            report.notes.append(f"category {cat['name']!r} is empty and was skipped")
            continue
        cat_code = _slug(cat["name"])
        if cat["name"] in settings.category_stations:
            station = settings.category_stations[cat["name"]]
        else:
            station = settings.default_station
            report.notes.append(f"category {cat['name']!r} has no station set; it goes to {station}")
        if station is not None and station not in settings.stations:
            report.notes.append(f"category {cat['name']!r}: unknown station {station!r}")
        lunch = cat["name"] == settings.lunch_category
        menu = "lunch" if lunch else "dinner"
        section_id = f"{menu}/{cat_code}"
        defs.add(
            Category(cat_code, {"en": cat["name"]}, station=station, sort=int(cat.get("sort") or 0)),
            Section(
                section_id,
                menu,
                {"en": cat["name"]},
                display={"description": cat.get("description")} if cat.get("description") else {},
                sort=int(cat.get("sort") or 0),
            ),
        )
        report.categories += 1
        if not cat.get("active", True):
            report.notes.append(f"category {cat['name']!r} is off online; kept for the POS")
        for g in cat.get("groups") or ():
            defs.add(Attachment("category", cat_code, group_code(g), sort=int(g.get("sort") or 0)))

        for item in sorted(cat["items"], key=lambda i: i.get("sort", 0)):
            if not item.get("active", True):
                report.notes.append(f"item {item['name'].strip()!r} is inactive and was skipped")
                continue
            number, name = split_number(item["name"])
            code = number or f"GF{item['id']}"
            if code in defs.items:
                code = f"{code}_{item['id']}"
            if name == "Gift Certificate":
                name = f"Gift Certificate ${money(item.get('price') or 0):.0f}"
            extras = item.get("extras") or {}
            allergens = sorted(
                {
                    ALLERGENS[a["name"].lower()]
                    for a in extras.get("menu_item_allergens_values") or ()
                    if a.get("name", "").lower() in ALLERGENS
                }
            )
            names = {"en": name}
            if extras.get("menu_item_kitchen_internal_name"):
                names["kitchen"] = extras["menu_item_kitchen_internal_name"]
            defs.add(
                Item(
                    code,
                    cat_code,
                    names,
                    aliases=(number,) if number else (),
                    description={"en": item["description"]} if item.get("description") else {},
                    tax_class=taxes.get(item.get("tax_category_id"), "prepared_food"),
                    tags=tuple(TAGS.get(t, t.lower()) for t in item.get("tags") or ()),
                    attrs={"gloriafood_id": item["id"], "allergens": allergens},
                    sort=int(item.get("sort") or 0),
                )
            )
            report.items += 1
            sizes = item.get("sizes") or []
            if sizes:
                for s_sort, size in enumerate(sorted(sizes, key=lambda s: (not s.get("default"), s.get("sort", 0)))):
                    defs.add(
                        Variant(
                            f"{code}:{size['id']}",
                            code,
                            str(size["id"]),
                            {"en": size["name"]},
                            money(size.get("price") or 0),
                            sort=s_sort,
                        )
                    )
                    for g in size.get("groups") or ():
                        report.notes.append(f"{code}: group {g['name']!r} on size {size['name']!r} is on every size")
                        defs.add(Attachment("item", code, group_code(g)))
                    report.variants += 1
            else:
                defs.add(Variant(f"{code}:regular", code, "regular", {"en": "Regular"}, money(item.get("price") or 0)))
                report.variants += 1
            for g in item.get("groups") or ():
                defs.add(Attachment("item", code, group_code(g), sort=int(g.get("sort") or 0)))
            defs.add(
                Entry(
                    f"{menu}:{code}",
                    menu,
                    section_id,
                    code,
                    number,
                    sort=int(cat.get("sort") or 0) * 1000 + int(item.get("sort") or 0),
                )
            )
            if re.search(r"\d+\.\d\d?$", name):
                report.notes.append(f"{code}: name {name!r} ends in what looks like a price")
    if data.get("currency", "USD") != "USD":
        report.notes.append(f"currency {data.get('currency')} is not USD")
    return defs, report


def load_gloriafood(path: Path | str, settings: ImportSettings | None = None) -> tuple[Definitions, ImportReport]:
    return import_gloriafood(json.loads(Path(path).read_text(encoding="utf-8")), settings)


DATA = Path(__file__).with_name("data")
BUNDLED = DATA / "gloriafood_menu.json"
"""The restaurant's online menu as exported on 2026-10-27; the POS menu until the real one is curated."""
STATIONS = DATA / "stations.json"


def settings_from(path: Path | str = STATIONS) -> ImportSettings:
    """Stations and the category-to-station map from a JSON file like `data/stations.json`."""
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    return ImportSettings(
        stations=config.get("stations", {}),
        category_stations=config.get("categories", {}),
        default_station=config.get("default_station"),
        lunch_hours=config.get("lunch_hours") or {"days": [1, 2, 3, 4, 5, 6], "from": "11:00", "to": "15:00"},
    )


def load_restaurant_menu() -> tuple[Definitions, ImportReport]:
    """The bundled export with the bundled stations: what a hub serves by default."""
    return load_gloriafood(BUNDLED, settings_from(STATIONS))
