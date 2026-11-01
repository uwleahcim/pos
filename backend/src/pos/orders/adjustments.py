"""Discounts, comps and service charges: everything that moves a price after the menu engine has set it
(architecture page, section 9). The rules are data per location (`POS_PRICING` names a JSON file; without
one, this restaurant's defaults), the order module applies them, and the check records each one with who
did it, who approved it and why. The engine's own combo, schedule and channel pricing stays in the engine:
this layer never edits a resolved line.

Phase 1 carries discounts (a percentage, an amount or a comp, on a line or the whole check, from a fixed
list of reasons, each saying who may apply it and its cap) and service charges (a percentage or an amount
by order type or party size, taxed by its own class, flagged when it is a gratuity for staff). Promotions
and promo codes are phase 2.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

DISCOUNT_KINDS = ("percent", "amount", "comp")
SCOPES = ("line", "check")
APPROVERS = frozenset({"manager", "owner"})
APPROVAL_TTL = 10 * 60
"""Seconds a manager's approval stays good for: long enough to finish the discount, not a whole shift."""


def _money(value: Any) -> Decimal | None:
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return None


@dataclass(frozen=True)
class DiscountRule:
    """A reason a price may come down, and the limits on it."""

    code: str
    name: str
    kinds: tuple[str, ...] = ("percent", "amount")
    scopes: tuple[str, ...] = ("line", "check")
    max_percent: Decimal | None = None
    max_amount: Decimal | None = None
    fixed_percent: Decimal | None = None  # a staff meal is always its percentage
    approval: str = "manager"  # none | manager: who must be there when it is applied
    stacks: bool = False  # may sit on a check with other discounts

    def as_json(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "name": self.name,
            "kinds": list(self.kinds),
            "scopes": list(self.scopes),
            "max_percent": None if self.max_percent is None else str(self.max_percent),
            "max_amount": None if self.max_amount is None else str(self.max_amount),
            "fixed_percent": None if self.fixed_percent is None else str(self.fixed_percent),
            "approval": self.approval,
            "stacks": self.stacks,
        }

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> DiscountRule:
        return cls(
            code=data["code"],
            name=data.get("name", data["code"]),
            kinds=tuple(data.get("kinds", ("percent", "amount"))),
            scopes=tuple(data.get("scopes", ("line", "check"))),
            max_percent=_money(data["max_percent"]) if data.get("max_percent") is not None else None,
            max_amount=_money(data["max_amount"]) if data.get("max_amount") is not None else None,
            fixed_percent=_money(data["fixed_percent"]) if data.get("fixed_percent") is not None else None,
            approval=data.get("approval", "manager"),
            stacks=bool(data.get("stacks", False)),
        )


@dataclass(frozen=True)
class ChargeRule:
    """A service charge: automatic when its conditions hold, or added by staff."""

    code: str
    name: str
    kind: str  # percent | amount
    value: Decimal
    tax_class: str = "service_charge"
    gratuity: bool = False  # paid over to staff: not revenue, and usually not taxed
    order_types: tuple[str, ...] = ()  # () = any
    min_party: int | None = None
    automatic: bool = False  # applied by the backend when its conditions hold
    removal: str = "manager"  # none | manager: who may take an automatic one off

    def applies(self, order_type: str, guests: int | None) -> bool:
        """Whether this charge goes on a check of this order type and party size by itself."""
        if not self.automatic:
            return False
        if self.order_types and order_type not in self.order_types:
            return False
        return self.min_party is None or (guests or 0) >= self.min_party

    def as_json(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "name": self.name,
            "kind": self.kind,
            "value": str(self.value),
            "tax_class": self.tax_class,
            "gratuity": self.gratuity,
            "order_types": list(self.order_types),
            "min_party": self.min_party,
            "automatic": self.automatic,
            "removal": self.removal,
        }

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> ChargeRule:
        return cls(
            code=data["code"],
            name=data.get("name", data["code"]),
            kind=data.get("kind", "percent"),
            value=Decimal(str(data.get("value", "0"))),
            tax_class=data.get("tax_class", "service_charge"),
            gratuity=bool(data.get("gratuity", False)),
            order_types=tuple(data.get("order_types", ())),
            min_party=data.get("min_party"),
            automatic=bool(data.get("automatic", False)),
            removal=data.get("removal", "manager"),
        )


@dataclass
class PricingRules:
    discounts: dict[str, DiscountRule] = field(default_factory=dict)
    charges: dict[str, ChargeRule] = field(default_factory=dict)

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> PricingRules:
        rules = cls()
        for d in data.get("discounts", ()):
            rule = DiscountRule.from_json(d)
            rules.discounts[rule.code] = rule
        for c in data.get("charges", ()):
            charge = ChargeRule.from_json(c)
            rules.charges[charge.code] = charge
        return rules

    def as_json(self) -> dict[str, Any]:
        return {
            "discounts": [d.as_json() for d in self.discounts.values()],
            "charges": [c.as_json() for c in self.charges.values()],
        }

    def problems(
        self,
        kind: str,
        data: Mapping[str, Any],
        *,
        approved: bool,
        existing: Iterable[Mapping[str, Any]] = (),
    ) -> list[dict[str, str]]:
        """What is wrong with a `discount`, `charge` or `remove_charge` operation before it is stored: an
        unknown reason, a kind or scope the reason does not allow, a value over its cap, a discount that
        does not stack on one already taking from the same lines (`existing` holds the active discounts'
        `reason` and `line_id`), or a manager's approval missing. Empty when it may go on the check."""
        if kind == "discount":
            return self._discount_problems(data, approved=approved, existing=list(existing))
        if kind == "charge":
            rule = self.charges.get(str(data.get("code", "")))
            if rule is None:
                return [{"code": "unknown_charge", "message": f"no charge called {data.get('code')!r}"}]
            return []
        if kind == "remove_charge":
            rule = self.charges.get(str(data.get("charge_id", "")))
            if rule is not None and rule.automatic and rule.removal == "manager" and not approved:
                return [{"code": "needs_approval", "message": f"a manager must take off the {rule.name.lower()}"}]
            return []
        return []

    def _discount_problems(
        self, data: Mapping[str, Any], *, approved: bool, existing: list[Mapping[str, Any]]
    ) -> list[dict[str, str]]:
        rule = self.discounts.get(str(data.get("reason", "")))
        if rule is None:
            return [{"code": "unknown_reason", "message": f"no discount reason called {data.get('reason')!r}"}]
        out = []
        kind = str(data.get("kind", ""))
        if kind not in rule.kinds:
            out.append({"code": "bad_kind", "message": f"{rule.name} cannot be a {kind or 'blank'} discount"})
        scope = "line" if data.get("line_id") else "check"
        if scope not in rule.scopes:
            out.append({"code": "bad_scope", "message": f"{rule.name} does not apply to a {scope}"})
        value = _money(data.get("value"))
        if kind == "percent":
            if value is None or value <= 0 or value > 100:
                out.append({"code": "bad_value", "message": "a percentage between 0 and 100 is needed"})
            elif rule.fixed_percent is not None and value != rule.fixed_percent:
                out.append({"code": "bad_value", "message": f"{rule.name} is always {rule.fixed_percent}%"})
            elif rule.max_percent is not None and value > rule.max_percent:
                out.append({"code": "over_cap", "message": f"{rule.name} is at most {rule.max_percent}%"})
        elif kind == "amount":
            if value is None or value <= 0:
                out.append({"code": "bad_value", "message": "an amount above zero is needed"})
            elif rule.max_amount is not None and value > rule.max_amount:
                out.append({"code": "over_cap", "message": f"{rule.name} is at most {rule.max_amount}"})
        # Two comps on two different dishes are fine; two discounts taking from the same dish, or a check
        # discount over a line discount, only when both stack.
        line_id = data.get("line_id")
        overlapping = [e for e in existing if line_id is None or e.get("line_id") in (None, line_id)]
        others = [self.discounts.get(str(e.get("reason"))) for e in overlapping]
        if overlapping and (not rule.stacks or any(o is not None and not o.stacks for o in others)):
            out.append({"code": "no_stacking", "message": f"{rule.name} cannot go on top of another discount"})
        if rule.approval == "manager" and not approved:
            out.append({"code": "needs_approval", "message": f"{rule.name} needs a manager's PIN"})
        return out


def default_rules() -> PricingRules:
    """This restaurant's reasons and charges until the portal sets them: comps and staff meals with a
    manager on the spot, a small loyalty reward any server may give, an automatic gratuity for parties of
    six and a delivery fee."""
    return PricingRules.from_json(
        {
            "discounts": [
                {"code": "comp", "name": "Manager comp", "kinds": ["comp"], "approval": "manager"},
                {
                    "code": "staff_meal",
                    "name": "Staff meal",
                    "kinds": ["percent"],
                    "fixed_percent": "50",
                    "approval": "manager",
                },
                {
                    "code": "loyalty",
                    "name": "Loyalty reward",
                    "kinds": ["percent", "amount"],
                    "max_percent": "20",
                    "max_amount": "20",
                    "approval": "none",
                },
                {
                    "code": "promotion",
                    "name": "Promotion",
                    "kinds": ["percent", "amount"],
                    "max_percent": "50",
                    "max_amount": "50",
                    "approval": "manager",
                },
                {
                    "code": "service_recovery",
                    "name": "Service recovery",
                    "kinds": ["percent", "amount", "comp"],
                    "max_percent": "100",
                    "approval": "manager",
                },
            ],
            "charges": [
                {
                    "code": "auto_gratuity",
                    "name": "Gratuity 18% (party of 6 or more)",
                    "kind": "percent",
                    "value": "18",
                    "tax_class": "gratuity",
                    "gratuity": True,
                    "order_types": ["dine_in"],
                    "min_party": 6,
                    "automatic": True,
                    "removal": "manager",
                },
                {
                    "code": "delivery_fee",
                    "name": "Delivery fee",
                    "kind": "amount",
                    "value": "4.00",
                    "tax_class": "service_charge",
                    "order_types": ["delivery"],
                    "automatic": True,
                    "removal": "none",
                },
            ],
        }
    )


def load_rules(path: str | None = None) -> PricingRules:
    """`POS_PRICING` names a JSON file of rules; without one, this restaurant's defaults."""
    path = path if path is not None else os.environ.get("POS_PRICING")
    if path:
        return PricingRules.from_json(json.loads(Path(path).read_text()))
    return default_rules()
