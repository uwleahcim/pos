"""The menu as the apps see it: JSON views of the engine, and the priced snapshot an order line keeps.

The apps never price anything. They send the customer's choices (`LineRequest`); the hub resolves them and
stores the result in the line's `add_line` operation, so the order keeps the name, price, tax class and
kitchen text it was sold at, whatever the menu says later.
"""

from __future__ import annotations

import os
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import asdict
from datetime import datetime
from decimal import Decimal
from typing import TYPE_CHECKING, Any

from .. import localtime
from .defs import Definitions, StaleMenu, money
from .engine import PREFIXES, MenuEngine, ResolvedEntry, ResolvedSection, all_problems, flatten_modifiers
from .request import ComponentRequest, LineRequest, Selection
from .resolved import ResolvedLine, ResolvedModifier

if TYPE_CHECKING:
    from .store import MenuStore


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
        prefix=str(data["prefix"]) if data.get("prefix") else None,
        notes=str(data["notes"]).strip() or None if data.get("notes") else None,
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
    return localtime.now()


class MenuService:
    """The menu the hub sells from. With a `store` (every hub and the cloud) the menu lives in PostgreSQL:
    an empty database is seeded once from `POS_MENU` (the GloriaFood export by default), and from then on
    the database is the menu. `refresh` picks up a change saved by the editor or another hub."""

    REFRESH_SECONDS = 2.0

    def __init__(self, defs: Definitions | None = None, now=None, store: MenuStore | None = None) -> None:
        self.store = store
        self._now = now or local_now
        self.revision = 0
        self._checked = 0.0
        # Called when what the menu sells changed here: a save, a save picked up from elsewhere, the 86
        # board. The API tells the screens through it (`pos.api.feed`).
        self.on_change: Callable[[], object] | None = None
        self._changes = 0  # counts them: an answer kept from before a change is not given again
        self._kept: dict[tuple[str, str], tuple[MenuEngine, int, datetime, list[dict[str, Any]]]] = {}
        self._keeping = threading.Lock()
        if store is not None:
            if store.role == "primary" and store.is_empty():
                store.save(defs if defs is not None else load_definitions(), actor="import")
            defs = store.load()
            self.revision = store.revision()
        self.engine = MenuEngine(defs if defs is not None else load_definitions(), now=self._now)
        if store is not None:
            self.engine.availability = store.availability()

    def refresh(self, *, force: bool = False) -> bool:
        """Reload from the store when its revision moved; checked at most every REFRESH_SECONDS."""
        if self.store is None:
            return False
        now = time.monotonic()
        if not force and now - self._checked < self.REFRESH_SECONDS:
            return False
        self._checked = now
        revision = self.store.revision()
        if revision == self.revision:
            return False
        engine = MenuEngine(self.store.load(self.defs.localizer), now=self._now)
        engine.availability = self.store.availability()
        self.engine, self.revision = engine, revision
        self._changed()
        return True

    def _changed(self) -> None:
        self._changes += 1
        if self.on_change is not None:
            self.on_change()

    def set_availability(
        self, target_id: str, status: str, *, reason: str | None = None, by: str | None = None
    ) -> None:
        """86 a size or an option, or bring it back; stored, so a restart keeps the board."""
        self.engine.set_availability(target_id, status, reason=reason, by=by)
        if self.store is not None:
            self.store.set_availability(self.engine.availability.get(target_id), target_id)
        self._changed()

    def save(self, defs: Definitions, *, actor: str, expect: int | None = None) -> dict[str, int]:
        """Sell from `defs` from now on: stored (with the audit log) when there is a store, so every hub
        picks it up. `expect` refuses the save (StaleMenu) if someone else saved since that revision."""
        if self.store is None:
            if expect is not None and expect != self.revision:
                raise StaleMenu(expect, self.revision)
            engine = MenuEngine(defs, now=self._now)
            engine.availability = {
                k: v for k, v in self.engine.availability.items() if k in defs.variants or k in defs.options
            }
            self.engine, self.revision = engine, self.revision + 1
            self._changed()
            return {"revision": self.revision}
        result = self.store.save(defs, actor=actor, expect=expect)
        self.refresh(force=True)
        return {
            "revision": result.revision,
            "inserted": result.inserted,
            "updated": result.updated,
            "deleted": result.deleted,
        }

    @property
    def defs(self) -> Definitions:
        return self.engine.defs

    # --- views ---------------------------------------------------------------------------------

    def menus(self, channel: str = "pos", locale: str = "en", at: datetime | None = None) -> list[dict[str, Any]]:
        """The menus open on a channel, as the apps show them. Asked for the present (no `at`), the answer is
        kept for the rest of the clock's second: told that the menu changed, every screen reads it in the
        same instant, and working it out takes a tenth of a second for this restaurant's menu, so twenty
        screens get the one answer worked out once (and the callers that come while it is being worked out
        wait for it rather than each starting their own). Shared: read it, never change it."""
        if at is not None:
            return self._menus(channel, locale, at)
        with self._keeping:
            now = self._now().replace(microsecond=0)
            kept = self._kept.get((channel, locale))
            if kept is not None and kept[0] is self.engine and kept[1] == self._changes and kept[2] == now:
                return kept[3]
            engine, changes = self.engine, self._changes
            answer = self._menus(channel, locale, None)
            self._kept[(channel, locale)] = (engine, changes, now, answer)
            return answer

    def _menus(self, channel: str, locale: str, at: datetime | None) -> list[dict[str, Any]]:
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
            "color": self._section_color(section.section_id),
            "entries": [
                {
                    "entry_id": e.entry_id,
                    "number": e.number,
                    "item": e.item,
                    "name": e.name,
                    "second_name": self._second_name(e.item, locale),
                    "kitchen_name": self._kitchen_name(e.item),
                    "variants": [_plain(asdict(v)) for v in e.variants],
                    "contains": list(e.contains),
                    "tags": list(e.tags),
                    "has_options": bool(self.defs.attachments_for(e.item)),
                    "needs_choice": self._needs_choice(e),
                }
                for e in section.entries
            ],
            "sections": [self._section(s, locale) for s in section.sections],
        }

    def _section_color(self, section_id: str) -> str | None:
        """The POS tile colour set on the section (`display.color`, #RRGGBB), or None for the app's palette."""
        section = self.defs.sections.get(section_id)
        color = section.display.get("color") if section is not None else None
        return str(color) if color else None

    def _needs_choice(self, entry: ResolvedEntry) -> bool:
        """Whether a tap on this dish has to ask something before it can go on the check: a size, or a
        required group with no default. The tile shows its customize mark only then."""
        if len([v for v in entry.variants if v.status == "available"]) > 1:
            return True
        for group, overrides in self.defs.attachments_for(entry.item):
            min_select = overrides.get("min", group.min_select)
            if min_select <= 0:
                continue
            hidden = set(overrides.get("hidden", ()))
            options = [o for o in self.defs.options_of(group.code) if o.active and o.code not in hidden]
            default = overrides.get("default")
            # the engine fills in one default per group (`_apply_group`), so one default answers a group of one
            has_default = any(o.code == default for o in options) if default else any(o.is_default for o in options)
            if min_select > (1 if has_default else 0):
                return True
        return False

    def _second_name(self, item_code: str, locale: str) -> str | None:
        """The other language on the button: Chinese under an English name, English under a Chinese one."""
        names = self.defs.items[item_code].names
        other = "en" if locale.startswith("zh") else "zh"
        return names.get(other)

    def _kitchen_name(self, item_code: str) -> str | None:
        """What the dish's ticket calls it when that is not its name (`腰果蝦 SHMP CASHEW r`): the screens'
        search finds a dish by it too."""
        return self.defs.items[item_code].names.get("kitchen") or None

    def item(self, item_id: str, entry_id: str | None = None, locale: str = "en") -> dict[str, Any]:
        detail = self.engine.item_detail(item_id, entry_id, locale=locale)
        out = _plain(asdict(detail))
        out["second_name"] = self._second_name(item_id, locale)
        return out

    def details(self, channel: str = "pos", locale: str = "en", at: datetime | None = None) -> list[dict[str, Any]]:
        """`item` for every entry on the menus open now, each with its `entry_id`: what a terminal keeps on
        disk so a dish with choices can still be configured when no backend answers (ADR 6)."""
        out: list[dict[str, Any]] = []
        seen: set[tuple[str, str]] = set()

        def walk(sections: list[dict[str, Any]]) -> None:
            for section in sections:
                for entry in section["entries"]:
                    key = (entry["item"], entry["entry_id"])
                    if key in seen:
                        continue
                    seen.add(key)
                    out.append({**self.item(entry["item"], entry["entry_id"], locale), "entry_id": entry["entry_id"]})
                walk(section["sections"])

        for menu in self.menus(channel, locale, at):
            walk(menu["sections"])
        return out

    def search(self, query: str, channel: str = "pos", locale: str = "en") -> list[dict[str, Any]]:
        return [asdict(h) for h in self.engine.search(query, channel, locale=locale)]

    def eighty_sixed(self) -> list[dict[str, Any]]:
        out = []
        loc = self.defs.localizer
        for target, state in sorted(self.engine.availability.items()):
            if self.engine.status_of(target) == "available":
                continue
            variant = self.defs.variants.get(target)
            option = self.defs.options.get(target)
            if variant is not None:
                name = loc.text(self.defs.items[variant.item].names, "en")
                if len(self.defs.variants_of(variant.item)) > 1:
                    name += f" ({loc.text(variant.names, 'en')})"
            else:
                name = loc.text(self.defs.option_names(option), "en") if option else target
            out.append({"target_id": target, "name": name, "status": state.status, "by": state.set_by})
        return out

    # --- pricing -------------------------------------------------------------------------------

    def resolve(self, request: Mapping[str, Any], at: datetime | None = None) -> ResolvedLine:
        return self.engine.resolve(request_from(request), at)

    def _modifier_label(self, m: ResolvedModifier) -> str:
        """What the check shows for a choice: the option's name, with its instruction in front (NO Add shrimp)."""
        option = self.defs.options.get(m.option_id)
        if option is None:
            return m.kitchen_label
        name = self.defs.localizer.text(self.defs.option_names(option), "en")
        name = f"{PREFIXES[m.prefix]} {name}" if m.prefix else name
        return f"{m.qty}x {name}" if m.qty > 1 else name  # two of the same choice: "2x Chicken fingers"

    def _check_rows(self, line: ResolvedLine, depth: int = 0) -> list[dict[str, Any]]:
        """The choices on a line as the check lists them, each with what it adds for one of the dish. A choice
        that is a dish (a slot: the soup with a lunch special, each roll of a maki combination) is a row at
        this depth with the slot's price, and that dish's own choices follow one level deeper, so the check
        reads dish, choice, the choice's choices, each on its own line."""
        rows: list[dict[str, Any]] = []
        slots = {c.option_id: c for c in line.children if c.origin == "slot" and c.option_id}
        for m in flatten_modifiers(line.modifiers):
            child = slots.get(m.option_id)
            rows.append(
                {
                    "group_id": m.group_id,
                    "option_id": m.option_id,
                    "qty": m.qty,
                    "label": self._modifier_label(m),
                    "kitchen_label": m.kitchen_label,
                    "prefix": m.prefix,
                    # a slot's price is on its dish (the child line); a plain choice carries its own delta
                    "price": str(money(child.unit_price * child.qty if child is not None else m.price_delta)),
                    "defaulted": m.defaulted,
                    "depth": depth,
                }
            )
            if child is not None:
                rows.extend(self._check_rows(child, depth + 1))
                if child.notes:
                    # the kitchen note on that dish, read under it like one of its choices
                    rows.append(
                        {
                            "group_id": m.group_id,
                            "option_id": m.option_id,
                            "qty": 1,
                            "label": child.notes,
                            "kitchen_label": child.notes,
                            "prefix": None,
                            "price": "0.00",
                            "defaulted": False,
                            "depth": depth + 1,
                            "note": True,
                        }
                    )
        return rows

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
            "item": variant.item if variant is not None else None,
            "variant_id": line.variant_id,
            "entry_id": line.menu_entry_id,
            "names": dict(line.names),
            "variant_names": dict(line.variant_names),
            "name": name,
            "unit_price": str(line.line_total),
            "tax_class": line.tax_class,
            "modifiers": self._check_rows(line),
            "kitchen": [
                {
                    "station": k.station,
                    "qty": k.qty,
                    "text": k.text,
                    "label": k.text.split(" ", 1)[-1].split(" · ")[0],  # without the count and modifiers
                    "labels": list(k.labels),
                    "depths": list(k.depths),
                    "header": k.header,
                    "note": k.note,
                    # where each of `labels` is left off the ticket; not there when nothing is hidden anywhere
                    **({"hidden": [list(off) for off in k.hidden]} if k.hidden else {}),
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
