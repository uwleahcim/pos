"""The engine's output: an immutable tree with price, kitchen lines, usage, allergens and a snapshot."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal


@dataclass(frozen=True)
class Problem:
    code: str
    message: str
    group_id: str | None = None
    option_id: str | None = None
    component_id: str | None = None


@dataclass(frozen=True)
class EffectResult:
    op: str
    target: str
    outcome: str  # applied | no_op | error
    detail: str = ""


@dataclass(frozen=True)
class ResolvedModifier:
    group_id: str
    option_id: str
    qty: int
    kitchen_label: str
    price_delta: Decimal
    effects_applied: tuple[EffectResult, ...] = ()
    children: tuple[ResolvedModifier, ...] = ()
    defaulted: bool = False
    station: str | None = None
    prefix: str | None = None  # no | extra | side | light, already written into kitchen_label


@dataclass(frozen=True)
class KitchenLine:
    station: str
    qty: int
    text: str
    labels: tuple[str, ...] = ()
    header: str | None = None  # the combo's number and name for child lines
    origin: str = "line"  # line | slot | component | modifier
    allergy_note: str | None = None


@dataclass(frozen=True)
class IngredientUsage:
    ingredient: str
    qty: Decimal  # used, in the ingredient's base unit
    purchased: Decimal  # with yield applied
    unit: str
    cost: Decimal  # exact; round with money() for display


@dataclass(frozen=True)
class AllergenProfile:
    contains: frozenset[str] = frozenset()
    may_contain: frozenset[str] = frozenset()
    free: frozenset[str] = frozenset()
    unknown: frozenset[str] = frozenset()
    sources: Mapping[str, tuple[str, ...]] = field(default_factory=dict)

    def state(self, allergen: str) -> str:
        for name in ("contains", "may_contain", "free", "unknown"):
            if allergen in getattr(self, name):
                return name
        return "unknown"


@dataclass(frozen=True)
class Snapshot:
    recipe_version: str | None
    resolved_at: datetime
    engine_version: str


@dataclass(frozen=True)
class ResolvedLine:
    variant_id: str
    menu_entry_id: str | None
    qty: int
    names: Mapping[str, str]
    variant_names: Mapping[str, str]
    unit_price: Decimal
    price_source: str  # entry_override | variant_base | slot | included
    modifiers: tuple[ResolvedModifier, ...]
    children: tuple[ResolvedLine, ...]
    line_total: Decimal
    tax_class: str
    kitchen_lines: tuple[KitchenLine, ...]
    usage: tuple[IngredientUsage, ...]
    allergens: AllergenProfile
    cost: Decimal
    snapshot: Snapshot
    problems: tuple[Problem, ...] = ()
    origin: str = "line"
    component_id: str | None = None
    option_id: str | None = None
    locked: bool = False
    notes: str | None = None

    @property
    def ok(self) -> bool:
        return not self.problems and all(child.ok for child in self.children)

    @property
    def modifier_total(self) -> Decimal:
        return sum((m.price_delta for m in self.modifiers), Decimal(0))

    @property
    def children_total(self) -> Decimal:
        return sum((c.line_total for c in self.children), Decimal(0))

    @property
    def food_cost_pct(self) -> Decimal | None:
        if not self.line_total:
            return None
        return (self.cost / self.line_total * 100).quantize(Decimal("0.1"))


@dataclass(frozen=True)
class CostBreakdown:
    variant_id: str
    price: Decimal
    cost: Decimal
    margin: Decimal
    food_cost_pct: Decimal | None
    usage: tuple[IngredientUsage, ...]
