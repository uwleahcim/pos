from __future__ import annotations

from datetime import date
from decimal import Decimal as D

import pytest

from pos.tax import TaxableLine, TaxProfile, massachusetts


def test_massachusetts_meals_tax_on_a_check():
    ma = massachusetts()
    lines = [TaxableLine("L1", "prepared_food", D("24.95")), TaxableLine("L2", "alcohol", D("13.00"))]
    tax = ma.compute(lines, "dine_in")
    assert [(t.component, t.base, t.amount) for t in tax] == [
        ("ma_meals", D("37.95"), D("2.37")),  # 6.25% of 37.95 = 2.371875
        ("ma_local_meals", D("37.95"), D("0.28")),  # 0.75% = 0.284625
    ]


def test_without_local_option_and_exempt_classes():
    ma = massachusetts(local_option=False)
    lines = [
        TaxableLine("L1", "prepared_food", D("10.00")),
        TaxableLine("dep", "deposit", D("100.00")),
        TaxableLine("tip", "gratuity", D("18.00")),
        TaxableLine("L2", "something_new", D("2.00")),  # no rule of its own: the default rule taxes it
    ]
    assert [(t.component, t.base, t.amount) for t in ma.compute(lines)] == [("ma_meals", D("12.00"), D("0.75"))]


def test_rounding_per_check_or_per_line():
    lines = [TaxableLine(f"L{i}", "prepared_food", D("1.10")) for i in range(3)]  # 6.25% of 1.10 = 0.06875
    per_check = massachusetts(local_option=False)
    assert per_check.compute(lines)[0].amount == D("0.21")  # 0.20625
    per_line = massachusetts(local_option=False)
    per_line.rounding = "line"
    assert per_line.compute(lines)[0].amount == D("0.21")  # 0.07 x 3


def test_rules_by_order_type_and_effective_dates():
    profile = TaxProfile.from_json(
        {
            "location": "CA test",
            "components": [
                {"code": "old", "name": "Old", "jurisdiction": "X", "rate_pct": "5", "ends": "2027-01-01"},
                {"code": "new", "name": "New", "jurisdiction": "X", "rate_pct": "6", "starts": "2027-01-01"},
            ],
            "groups": [{"code": "g", "components": ["old", "new"]}],
            "rules": [
                {"tax_class": "cold_food", "group": "g"},
                {"tax_class": "cold_food", "order_type": "takeout", "group": None, "reason": "cold to go"},
            ],
        }
    )
    line = [TaxableLine("L1", "cold_food", D("10.00"))]
    assert [(t.component, t.amount) for t in profile.compute(line, "dine_in", date(2026, 12, 31))] == [
        ("old", D("0.50"))
    ]
    assert [(t.component, t.amount) for t in profile.compute(line, "dine_in", date(2027, 1, 1))] == [("new", D("0.60"))]
    assert profile.compute(line, "takeout", date(2027, 1, 1)) == []


def test_a_broken_profile_is_refused():
    with pytest.raises(ValueError, match="unknown component"):
        TaxProfile.from_json({"groups": [{"code": "g", "components": ["nope"]}]})
