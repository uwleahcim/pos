"""Definitions: what the restaurant sells, how it is configured, what it is made of.

Everything here is frozen data. Codes are the identifiers in this in-memory form (the database adds
UUIDs): a variant is "ITEM:variant", an option "group:option", a menu entry "menu:number" and a
section "menu/section".
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import date, datetime, time
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

CENT = Decimal("0.01")
ONE = Decimal(1)


def money(value: Any) -> Decimal:
    return dec(value).quantize(CENT, rounding=ROUND_HALF_UP)


def dec(value: Any) -> Decimal:
    return value if isinstance(value, Decimal) else Decimal(str(value))


class UnitError(ValueError):
    """A recipe uses a unit the ingredient cannot convert."""


class StaleMenu(Exception):
    """Someone else saved the menu since the editor read it."""

    def __init__(self, expected: int, current: int) -> None:
        super().__init__(f"the menu is at revision {current}, not {expected}")
        self.expected, self.current = expected, current


@dataclass(frozen=True)
class Unit:
    code: str
    dimension: str  # mass | volume | count
    to_base: Decimal  # factor to g, ml or each


@dataclass(frozen=True)
class Allergen:
    code: str
    names: Mapping[str, str]
    is_major: bool = False
    sort: int = 0


@dataclass(frozen=True)
class Station:
    code: str
    names: Mapping[str, str]
    printers: tuple[str, ...] = ()
    cross_contact: frozenset[str] = frozenset()


@dataclass(frozen=True)
class Category:
    code: str
    names: Mapping[str, str]
    parent: str | None = None
    tax_class: str | None = None
    station: str | None = None
    prep_minutes: int | None = None
    sort: int = 0
    active: bool = True


@dataclass(frozen=True)
class Item:
    code: str
    category: str
    names: Mapping[str, str]  # locales plus "kitchen"
    kind: str = "standard"  # standard | combo
    aliases: tuple[str, ...] = ()
    description: Mapping[str, Any] = field(default_factory=dict)
    tax_class: str | None = None
    station: str | None = None
    prep_minutes: int | None = None
    tags: tuple[str, ...] = ()
    attrs: Mapping[str, Any] = field(default_factory=dict)
    active: bool = True
    sort: int = 0


@dataclass(frozen=True)
class ComponentOverride:
    role: str
    ingredient: str
    qty: Decimal
    unit: str


@dataclass(frozen=True)
class Variant:
    id: str  # "GTC:quart"
    item: str
    code: str
    names: Mapping[str, str]
    base_price: Decimal
    recipe_scale: Decimal = ONE
    component_overrides: tuple[ComponentOverride, ...] = ()
    plu: str | None = None
    sort: int = 0
    active: bool = True


@dataclass(frozen=True)
class Effect:
    op: str  # add | remove | substitute | scale | note
    ingredient: str | None = None
    role: str | None = None
    qty: Decimal | None = None
    unit: str | None = None
    factor: Decimal | None = None


@dataclass(frozen=True)
class Option:
    id: str  # "rice:brown"
    group: str
    code: str
    names: Mapping[str, str]
    kitchen_label: str | None = None
    price_mode: str = "delta"  # delta | absolute | free | linked
    price: Decimal = Decimal(0)
    is_default: bool = False
    max_qty: int | None = None
    effects: tuple[Effect, ...] = ()
    linked_variant: str | None = None
    child_groups: tuple[str, ...] = ()
    station: str | None = None
    routes_to: str | None = None  # a station the whole dish prints at as well when this is chosen ("take out")
    sort: int = 0
    active: bool = True


@dataclass(frozen=True)
class Group:
    code: str
    names: Mapping[str, str]
    min_select: int = 0
    max_select: int | None = None
    free_count: int = 0
    allow_quantity: bool = False
    allow_duplicates: bool = False
    display: str = "inline"
    sort: int = 0
    source_category: str | None = None
    """The options come from this category: every dish on sale in it (and in the categories under it) is an
    option linked to the dish, one per size when it has several, kept in step on every save (`linked.sync`).
    Options added by hand stay beside them."""


@dataclass(frozen=True)
class Attachment:
    owner_kind: str  # item | category
    owner: str
    group: str
    overrides: Mapping[str, Any] = field(default_factory=dict)
    # min, max, default, hidden, prices, expose_linked_groups, child_defaults
    excluded: bool = False
    sort: int = 0


@dataclass(frozen=True)
class Menu:
    code: str
    names: Mapping[str, str]
    channels: tuple[str, ...]
    schedule: Mapping[str, Any] = field(default_factory=dict)
    priority: int = 0
    active: bool = True


@dataclass(frozen=True)
class Section:
    id: str  # "dinner/chefs"
    menu: str
    names: Mapping[str, str]
    parent: str | None = None
    display: Mapping[str, Any] = field(default_factory=dict)
    sort: int = 0


@dataclass(frozen=True)
class Entry:
    id: str  # "dinner:87"
    menu: str
    section: str
    item: str
    number: str | None
    variants: tuple[str, ...] | None = None  # None = every active variant
    price_overrides: Mapping[str, Decimal] = field(default_factory=dict)
    availability: Mapping[str, Any] = field(default_factory=dict)
    visible: bool = True
    featured: bool = False
    display: Mapping[str, Any] = field(default_factory=dict)
    sort: int = 0


@dataclass(frozen=True)
class AllergenDecl:
    allergen: str
    level: str  # contains | may_contain
    verified: bool = False
    source: str | None = None


@dataclass(frozen=True)
class Ingredient:
    code: str
    names: Mapping[str, str]
    kind: str  # stock | prep
    base_unit: str
    category: str | None = None
    each_grams: Decimal | None = None
    grams_per_ml: Decimal | None = None
    yield_pct: Decimal = Decimal(100)
    cost_per_base_unit: Decimal = Decimal(0)
    dietary_tags: tuple[str, ...] = ()
    allergens: tuple[AllergenDecl, ...] = ()
    allergens_reviewed_at: datetime | None = None
    track_stock: bool = True
    critical: bool = False
    active: bool = True


@dataclass(frozen=True)
class AllergenOverride:
    owner_kind: str  # item | variant
    owner: str
    allergen: str
    level: str  # contains | may_contain | free
    reason: str
    set_by: str | None = None


@dataclass(frozen=True)
class Component:
    id: str
    kind: str  # ingredient | variant
    ref: str  # ingredient code or variant id
    qty: Decimal
    unit: str
    role: str | None = None
    optional: bool = False
    scales: bool = True
    sort: int = 0
    defaults: Mapping[str, str] = field(default_factory=dict)  # group -> option, for a nested item
    locked: bool = False


@dataclass(frozen=True)
class Recipe:
    id: str  # "GTC@1"
    owner_kind: str  # item | variant | ingredient
    owner: str
    version: int
    components: tuple[Component, ...]
    yield_qty: Decimal = ONE
    yield_unit: str | None = None
    notes: str | None = None
    is_current: bool = True


@dataclass(frozen=True)
class Availability:
    target: str  # variant id or option id
    status: str  # available | sold_out | hidden
    until: datetime | None = None
    reason: str | None = None
    set_by: str | None = None
    set_at: datetime | None = None


class Localizer:
    """Names per language with fallback chains; no language is special unless a chain says so."""

    def __init__(self, chains: Mapping[str, tuple[str, ...]] | None = None, default: str = "en") -> None:
        self.chains = dict(chains or {})
        self.default = default

    def chain(self, locale: str) -> tuple[str, ...]:
        chain = self.chains.get(locale)
        if chain:
            return (locale, *chain) if chain[0] != locale else chain
        return (locale, self.default)

    def text(self, names: Mapping[str, str], locale: str) -> str:
        for code in self.chain(locale):
            if names.get(code):
                return names[code]
        for code, value in names.items():
            if code != "kitchen" and value:
                return value
        return ""

    def kitchen(self, names: Mapping[str, str]) -> str:
        return names.get("kitchen") or self.text(names, self.default)


SYSTEM_DEFAULTS = {"tax_class": "prepared_food", "station": None, "prep_minutes": 0}


class Definitions:
    """Every definition the engine resolves against, as of one moment."""

    def __init__(self, localizer: Localizer | None = None) -> None:
        self.units: dict[str, Unit] = {}
        self.allergens: dict[str, Allergen] = {}
        self.stations: dict[str, Station] = {}
        self.categories: dict[str, Category] = {}
        self.items: dict[str, Item] = {}
        self.variants: dict[str, Variant] = {}
        self.groups: dict[str, Group] = {}
        self.options: dict[str, Option] = {}
        self.attachments: list[Attachment] = []
        self.menus: dict[str, Menu] = {}
        self.sections: dict[str, Section] = {}
        self.entries: list[Entry] = []
        self.ingredients: dict[str, Ingredient] = {}
        self.overrides: list[AllergenOverride] = []
        self.recipes: list[Recipe] = []
        self.localizer = localizer or Localizer()

    def add(self, *objects: Any) -> Definitions:
        for obj in objects:
            match obj:
                case Unit():
                    self.units[obj.code] = obj
                case Allergen():
                    self.allergens[obj.code] = obj
                case Station():
                    self.stations[obj.code] = obj
                case Category():
                    self.categories[obj.code] = obj
                case Item():
                    self.items[obj.code] = obj
                case Variant():
                    self.variants[obj.id] = obj
                case Group():
                    self.groups[obj.code] = obj
                case Option():
                    self.options[obj.id] = obj
                case Attachment():
                    self.attachments.append(obj)
                case Menu():
                    self.menus[obj.code] = obj
                case Section():
                    self.sections[obj.id] = obj
                case Entry():
                    self.entries.append(obj)
                case Ingredient():
                    self.ingredients[obj.code] = obj
                case AllergenOverride():
                    self.overrides.append(obj)
                case Recipe():
                    self.recipes.append(obj)
                case _:
                    raise TypeError(f"cannot add {type(obj).__name__}")
        return self

    # --- lookups -------------------------------------------------------------------------------

    def entry(self, entry_id: str) -> Entry | None:
        return next((e for e in self.entries if e.id == entry_id), None)

    def entries_of(self, menu_code: str) -> list[Entry]:
        return sorted((e for e in self.entries if e.menu == menu_code), key=lambda e: e.sort)

    def category_chain(self, code: str | None) -> list[Category]:
        chain: list[Category] = []
        seen: set[str] = set()
        while code and code in self.categories and code not in seen:
            seen.add(code)
            chain.append(self.categories[code])
            code = self.categories[code].parent
        return chain

    def inherited(self, item: Item, attr: str) -> Any:
        """Item, then nearest ancestor category, then the system default."""
        value = getattr(item, attr)
        if value is not None:
            return value
        for cat in self.category_chain(item.category):
            value = getattr(cat, attr)
            if value is not None:
                return value
        return SYSTEM_DEFAULTS.get(attr)

    def attachments_for(self, item_code: str) -> list[tuple[Group, Mapping[str, Any]]]:
        """The item's modifier groups: its own attachments first, then inherited ones, overrides merged."""
        item = self.items[item_code]
        merged: dict[str, dict[str, Any]] = {}
        excluded: set[str] = set()
        order: list[tuple[int, int, str]] = []
        layers: list[list[Attachment]] = [
            [a for a in self.attachments if a.owner_kind == "item" and a.owner == item_code]
        ]
        for cat in self.category_chain(item.category):
            layers.append([a for a in self.attachments if a.owner_kind == "category" and a.owner == cat.code])
        for depth, layer in enumerate(layers):
            for att in sorted(layer, key=lambda a: a.sort):
                if att.excluded:
                    excluded.add(att.group)
                    continue
                if att.group in excluded:
                    continue
                if att.group not in merged:
                    merged[att.group] = {}
                    order.append((depth, att.sort, att.group))
                # the more specific layer came first; a less specific layer fills only what is unset
                for key, value in att.overrides.items():
                    merged[att.group].setdefault(key, value)
        order.sort(key=lambda t: (t[1], self.groups[t[2]].sort, t[2]))
        return [(self.groups[code], merged[code]) for _, _, code in order if code in self.groups]

    def options_of(self, group_code: str) -> list[Option]:
        return sorted((o for o in self.options.values() if o.group == group_code), key=lambda o: (o.sort, o.code))

    def linked_item(self, option: Option) -> Item | None:
        """The dish an option stands for, when it is one (`linked_variant`)."""
        variant = self.variants.get(option.linked_variant or "")
        return self.items.get(variant.item) if variant is not None else None

    def option_names(self, option: Option) -> Mapping[str, str]:
        """What an option is called: its own names, or, when it has none, the dish it is linked to (with the
        size when the dish has several), so a linked option follows the dish through a rename."""
        if any(v for k, v in option.names.items() if k != "kitchen"):
            return option.names
        item = self.linked_item(option)
        if item is None:
            return option.names
        variant = self.variants[option.linked_variant or ""]
        if len(self.variants_of(item.code)) <= 1:
            return item.names
        names = dict(item.names)
        for locale, text in list(names.items()):
            size = (
                self.localizer.text(variant.names, locale)
                if locale != "kitchen"
                else self.localizer.kitchen(variant.names)
            )
            names[locale] = f"{text} ({size})" if size else text
        return names

    def option_kitchen_label(self, option: Option) -> str | None:
        """What the kitchen reads for an option: its own label, else the linked dish's kitchen name."""
        if option.kitchen_label:
            return option.kitchen_label
        item = self.linked_item(option)
        if item is None:
            return None
        label = self.localizer.kitchen(item.names)
        variant = self.variants[option.linked_variant or ""]
        if len(self.variants_of(item.code)) > 1:
            label = f"{label} ({self.localizer.kitchen(variant.names)})"
        return label or None

    def items_in(self, category_code: str) -> list[Item]:
        """The dishes of a category and of the categories under it, in menu order."""
        found = [
            i for i in self.items.values() if any(c.code == category_code for c in self.category_chain(i.category))
        ]
        return sorted(found, key=lambda i: (i.sort, i.code))

    def variants_of(self, item_code: str) -> list[Variant]:
        return sorted((v for v in self.variants.values() if v.item == item_code), key=lambda v: (v.sort, v.code))

    def current_recipe(self, owner_kind: str, owner: str) -> Recipe | None:
        return next((r for r in self.recipes if r.owner_kind == owner_kind and r.owner == owner and r.is_current), None)

    def recipe_for_variant(self, variant: Variant) -> tuple[Recipe | None, bool]:
        """The variant's own recipe, else the item's (scaled by recipe_scale). Second value: scaled."""
        own = self.current_recipe("variant", variant.id)
        if own:
            return own, False
        return self.current_recipe("item", variant.item), True

    # --- units ---------------------------------------------------------------------------------

    def convert(self, qty: Decimal, unit_code: str, ingredient: Ingredient) -> Decimal:
        """A quantity in the ingredient's base unit, through grams when the dimensions differ."""
        unit = self.units.get(unit_code)
        base = self.units.get(ingredient.base_unit)
        if unit is None or base is None:
            raise UnitError(f"unknown unit {unit_code!r} or base unit {ingredient.base_unit!r}")
        if unit.dimension == base.dimension:
            return qty * unit.to_base / base.to_base
        grams: Decimal | None = None
        if unit.dimension == "mass":
            grams = qty * unit.to_base
        elif unit.dimension == "volume" and ingredient.grams_per_ml:
            grams = qty * unit.to_base * ingredient.grams_per_ml
        elif unit.dimension == "count" and ingredient.each_grams:
            grams = qty * unit.to_base * ingredient.each_grams
        if grams is not None:
            if base.dimension == "mass":
                return grams / base.to_base
            if base.dimension == "volume" and ingredient.grams_per_ml:
                return grams / ingredient.grams_per_ml / base.to_base
            if base.dimension == "count" and ingredient.each_grams:
                return grams / ingredient.each_grams / base.to_base
        raise UnitError(
            f"{ingredient.code}: cannot convert {unit_code} ({unit.dimension}) "
            f"to {ingredient.base_unit} ({base.dimension})"
        )

    def same_dimension(self, unit_a: str, unit_b: str) -> bool:
        a, b = self.units.get(unit_a), self.units.get(unit_b)
        return a is not None and b is not None and a.dimension == b.dimension


def menu_open(menu: Menu, at: datetime) -> bool:
    """Whether a menu's schedule covers a moment. Days are 1 (Monday) to 7 (Sunday)."""
    schedule = menu.schedule or {}
    if schedule.get("from") and at.date() < date.fromisoformat(schedule["from"]):
        return False
    if schedule.get("to") and at.date() > date.fromisoformat(schedule["to"]):
        return False
    weekly: Iterable[Mapping[str, Any]] = schedule.get("weekly") or ()
    if not weekly:
        return True
    day, now = at.isoweekday(), at.time()
    for window in weekly:
        if day not in window.get("days", (1, 2, 3, 4, 5, 6, 7)):
            continue
        start, end = time.fromisoformat(window["from"]), time.fromisoformat(window["to"])
        if (start <= now < end) if start <= end else (now >= start or now < end):
            return True
    return False
