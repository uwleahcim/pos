"""The menu as the apps see it: JSON views of the engine, and the priced snapshot an order line keeps.

The apps never price anything. They send the customer's choices (`LineRequest`); the hub resolves them and
stores the result in the line's `add_line` operation, so the order keeps the name, price, tax class and
kitchen text it was sold at, whatever the menu says later.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import asdict
from datetime import datetime
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo

from .defs import Definitions
from .engine import MenuEngine, ResolvedSection, all_problems, flatten_modifiers
from .request import ComponentRequest, LineRequest, Selection
from .resolved import ResolvedLine


def _plain(value: Any) -> Any:
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [_plain(v) for v in value]
    if isinstance(value, frozenset | set):
        return sorted(value)
    return value


def selection_from(data: Mapping[str, Any]) -> Selection:
    return Selection(
        group_id=str(data["group_id"]),
        option_id=str(data["option_id"]),
        qty=int(data.get("qty", 1)),
        children=tuple(selection_from(c) for c in data.get("children", ())),
        components=tuple(component_from(c) for c in data.get("components", ())),
    )


def component_from(data: Mapping[str, Any]) -> ComponentRequest:
    return ComponentRequest(
        component_id=str(data["component_id"]),
        selections=tuple(selection_from(s) for s in data.get("selections", ())),
        components=tuple(component_from(c) for c in data.get("components", ())),
        notes=data.get("notes"),
    )


def request_from(data: Mapping[str, Any]) -> LineRequest:
    """A line request from JSON: {variant_id, entry_id?, selections?, components?, notes?}. Quantity is the
    line's own field, so the request is always priced for one."""
    return LineRequest(
        variant_id=str(data["variant_id"]),
        qty=1,
        menu_entry_id=data.get("entry_id"),
        selections=tuple(selection_from(s) for s in data.get("selections", ())),
        components=tuple(component_from(c) for c in data.get("components", ())),
        notes=data.get("notes"),
    )


def load_definitions(source: str | None = None) -> Definitions:
    """`POS_MENU`: `gloriafood` (the restaurant's own menu from its online-ordering export, the default),
    `restaurant` (the sample full-service menu), `example` (the spec's worked example), a GloriaFood JSON
    export path, or a workbook path imported over the sample's categories, stations and modifier groups."""
    source = source if source is not None else os.environ.get("POS_MENU", "gloriafood")
    from .fixtures.example import build_example
    from .fixtures.restaurant import build_restaurant
    from .gloriafood import load_gloriafood, load_restaurant_menu, settings_from

    if source in ("", "gloriafood"):
        return load_restaurant_menu()[0]
    if source == "example":
        return build_example()
    if source == "restaurant":
        return build_restaurant()
    if source.endswith(".json"):
        return load_gloriafood(source, settings_from())[0]
    from .sheet import import_workbook

    report, defs = import_workbook(build_restaurant(), source, dry_run=False)
    if not report.ok:
        raise ValueError(f"menu workbook {source}: " + "; ".join(report.errors[:10]))
    return defs


def local_now() -> datetime:
    """The restaurant's wall clock: lunch hours and menu schedules are local times (`POS_TIMEZONE`)."""
    return datetime.now(ZoneInfo(os.environ.get("POS_TIMEZONE", "America/New_York")))


class MenuService:
    def __init__(self, defs: Definitions | None = None, now=None) -> None:
        self.engine = MenuEngine(defs if defs is not None else load_definitions(), now=now or local_now)

    @property
    def defs(self) -> Definitions:
        return self.engine.defs

    # --- views ---------------------------------------------------------------------------------

    def menus(self, channel: str = "pos", locale: str = "en", at: datetime | None = None) -> list[dict[str, Any]]:
        return [
            {
                "menu": m.menu,
                "name": m.name,
                "priority": m.priority,
                "sections": [self._section(s, locale) for s in m.sections],
            }
            for m in self.engine.menu_for(channel, at, locale)
        ]

    def _section(self, section: ResolvedSection, locale: str) -> dict[str, Any]:
        return {
            "section_id": section.section_id,
            "name": section.name,
            "entries": [
                {
                    "entry_id": e.entry_id,
                    "number": e.number,
                    "item": e.item,
                    "name": e.name,
                    "second_name": self._second_name(e.item, locale),
                    "variants": [_plain(asdict(v)) for v in e.variants],
                    "contains": list(e.contains),
                    "tags": list(e.tags),
                    "has_options": bool(self.defs.attachments_for(e.item)),
                }
                for e in section.entries
            ],
            "sections": [self._section(s, locale) for s in section.sections],
        }

    def _second_name(self, item_code: str, locale: str) -> str | None:
        """The other language on the button: Chinese under an English name, English under a Chinese one."""
        names = self.defs.items[item_code].names
        other = "en" if locale.startswith("zh") else "zh"
        return names.get(other)

    def item(self, item_id: str, entry_id: str | None = None, locale: str = "en") -> dict[str, Any]:
        detail = self.engine.item_detail(item_id, entry_id, locale=locale)
        out = _plain(asdict(detail))
        out["second_name"] = self._second_name(item_id, locale)
        return out

    def search(self, query: str, channel: str = "pos", locale: str = "en") -> list[dict[str, Any]]:
        return [asdict(h) for h in self.engine.search(query, channel, locale=locale)]

    # --- pricing -------------------------------------------------------------------------------

    def resolve(self, request: Mapping[str, Any], at: datetime | None = None) -> ResolvedLine:
        return self.engine.resolve(request_from(request), at)

    def priced(self, request: Mapping[str, Any], at: datetime | None = None) -> dict[str, Any]:
        """The snapshot an order line keeps: names, the price of one, tax class, kitchen lines, problems."""
        line = self.resolve(request, at)
        loc = self.defs.localizer
        problems = [asdict(p) for p in all_problems(line)]
        name = loc.text(line.names, "en")
        variant = self.defs.variants.get(line.variant_id)
        if variant is not None and len(self.defs.variants_of(variant.item)) > 1:
            name = f"{name} ({loc.text(line.variant_names, 'en')})"
        return {
            "variant_id": line.variant_id,
            "entry_id": line.menu_entry_id,
            "names": dict(line.names),
            "variant_names": dict(line.variant_names),
            "name": name,
            "unit_price": str(line.line_total),
            "tax_class": line.tax_class,
            "modifiers": [
                {
                    "group_id": m.group_id,
                    "option_id": m.option_id,
                    "qty": m.qty,
                    "label": loc.text(self.defs.options[m.option_id].names, "en")
                    if m.option_id in self.defs.options
                    else m.kitchen_label,
                    "kitchen_label": m.kitchen_label,
                    "price": str(m.price_delta),
                    "defaulted": m.defaulted,
                }
                for m in flatten_modifiers(line.modifiers)
            ],
            "kitchen": [
                {
                    "station": k.station,
                    "qty": k.qty,
                    "text": k.text,
                    "label": k.text.split(" ", 1)[-1].split(" · ")[0],  # without the count and modifiers
                    "labels": list(k.labels),
                    "header": k.header,
                }
                for k in line.kitchen_lines
            ],
            "contains": sorted(line.allergens.contains),
            "problems": problems,
            "snapshot": {
                "recipe_version": line.snapshot.recipe_version,
                "resolved_at": line.snapshot.resolved_at.isoformat(),
                "engine_version": line.snapshot.engine_version,
            },
        }
