"""Tax profile for one location and the arithmetic that turns taxable lines into tax lines."""

from __future__ import annotations

import json
import os
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import Any

CENT = Decimal("0.01")
ZERO = Decimal(0)


def cents(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


@dataclass(frozen=True)
class Component:
    """One rate from one jurisdiction, e.g. Massachusetts meals tax 6.25%."""

    code: str
    name: str
    jurisdiction: str
    rate_pct: Decimal
    starts: date | None = None
    ends: date | None = None  # exclusive

    def live(self, on: date) -> bool:
        return (self.starts is None or on >= self.starts) and (self.ends is None or on < self.ends)


@dataclass(frozen=True)
class Group:
    code: str
    components: tuple[str, ...]


@dataclass(frozen=True)
class Rule:
    """For a tax class (and optionally an order type), which group applies; group None means exempt."""

    tax_class: str
    group: str | None
    order_type: str | None = None
    reason: str | None = None  # why it is exempt, for the report

    @property
    def specificity(self) -> int:
        return 1 if self.order_type else 0


@dataclass(frozen=True)
class TaxableLine:
    key: str  # line id, or "service_charge"
    tax_class: str
    amount: Decimal  # after the discounts that reduce the base


@dataclass(frozen=True)
class TaxLine:
    component: str
    name: str
    jurisdiction: str
    rate_pct: Decimal
    base: Decimal
    amount: Decimal

    def as_json(self) -> dict[str, Any]:
        return {
            "component": self.component,
            "name": self.name,
            "jurisdiction": self.jurisdiction,
            "rate_pct": str(self.rate_pct),
            "base": str(self.base),
            "amount": str(self.amount),
        }


@dataclass
class TaxProfile:
    location: str
    components: dict[str, Component] = field(default_factory=dict)
    groups: dict[str, Group] = field(default_factory=dict)
    rules: list[Rule] = field(default_factory=list)
    rounding: str = "check"  # check | line

    def rule_for(self, tax_class: str, order_type: str | None) -> Rule | None:
        matches = [
            r for r in self.rules if r.tax_class == tax_class and (r.order_type is None or r.order_type == order_type)
        ]
        return max(matches, key=lambda r: r.specificity, default=None)

    def compute(
        self, lines: Iterable[TaxableLine], order_type: str | None = None, on: date | None = None
    ) -> list[TaxLine]:
        """Tax lines per component. A class with no rule is taxed by the rule for `default`, if any."""
        on = on or date.today()
        bases: dict[str, Decimal] = {}
        exact: dict[str, Decimal] = {}
        for line in lines:
            rule = self.rule_for(line.tax_class, order_type) or self.rule_for("default", order_type)
            if rule is None or rule.group is None:
                continue
            for code in self.groups[rule.group].components:
                component = self.components[code]
                if not component.live(on):
                    continue
                bases[code] = bases.get(code, ZERO) + line.amount
                share = line.amount * component.rate_pct / 100
                exact[code] = exact.get(code, ZERO) + (cents(share) if self.rounding == "line" else share)
        out = []
        for code in sorted(bases, key=lambda c: list(self.components).index(c)):
            component = self.components[code]
            out.append(
                TaxLine(
                    code,
                    component.name,
                    component.jurisdiction,
                    component.rate_pct,
                    cents(bases[code]),
                    cents(exact[code]),
                )
            )
        return out

    # --- loading -------------------------------------------------------------------------------

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> TaxProfile:
        profile = cls(location=data.get("location", ""), rounding=data.get("rounding", "check"))
        for c in data.get("components", ()):
            profile.components[c["code"]] = Component(
                c["code"],
                c["name"],
                c["jurisdiction"],
                Decimal(str(c["rate_pct"])),
                date.fromisoformat(c["starts"]) if c.get("starts") else None,
                date.fromisoformat(c["ends"]) if c.get("ends") else None,
            )
        for g in data.get("groups", ()):
            profile.groups[g["code"]] = Group(g["code"], tuple(g["components"]))
        for r in data.get("rules", ()):
            profile.rules.append(Rule(r["tax_class"], r.get("group"), r.get("order_type"), r.get("reason")))
        problems = profile.check()
        if problems:
            raise ValueError("; ".join(problems))
        return profile

    def check(self) -> list[str]:
        problems = []
        for g in self.groups.values():
            problems += [f"group {g.code}: unknown component {c}" for c in g.components if c not in self.components]
        problems += [
            f"rule {r.tax_class}: unknown group {r.group}" for r in self.rules if r.group and r.group not in self.groups
        ]
        if self.rounding not in ("check", "line"):
            problems.append(f"rounding {self.rounding!r}: want check or line")
        return problems


def massachusetts(local_option: bool = True, location: str = "MA") -> TaxProfile:
    """Massachusetts meals tax: 6.25% state on prepared food and drink, plus the 0.75% local option in towns
    that adopted it. Alcohol at the table is a meal. Not legal advice: confirm the town before going live."""
    components = [{"code": "ma_meals", "name": "MA meals tax", "jurisdiction": "Massachusetts", "rate_pct": "6.25"}]
    if local_option:
        components.append(
            {"code": "ma_local_meals", "name": "Local meals tax", "jurisdiction": location, "rate_pct": "0.75"}
        )
    return TaxProfile.from_json(
        {
            "location": location,
            "rounding": "check",
            "components": components,
            "groups": [{"code": "meals", "components": [c["code"] for c in components]}],
            "rules": [
                {"tax_class": "default", "group": "meals"},
                {"tax_class": "prepared_food", "group": "meals"},
                {"tax_class": "alcohol", "group": "meals"},
                {"tax_class": "beverage", "group": "meals"},
                {"tax_class": "service_charge", "group": "meals"},
                {"tax_class": "gratuity", "group": None, "reason": "a gratuity paid over to staff"},
                {"tax_class": "gift_card", "group": None, "reason": "not a sale of a meal"},
                {"tax_class": "deposit", "group": None, "reason": "a deposit is not a sale"},
            ],
        }
    )


def load_profile(path: str | None = None) -> TaxProfile:
    """`POS_TAX_PROFILE` names a JSON profile; without one, Massachusetts with the local option."""
    path = path if path is not None else os.environ.get("POS_TAX_PROFILE")
    if path:
        return TaxProfile.from_json(json.loads(Path(path).read_text()))
    return massachusetts()
