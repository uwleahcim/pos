"""`menu check`: the catalog validations that explain themselves."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal as D

from pos.menu import MenuEngine
from pos.menu.defs import AllergenOverride, Component, Entry, Group, Option, Recipe
from pos.menu.fixtures.example import build_example


def test_the_example_catalog_is_clean(engine):
    assert [p.code for p in engine.check() if not p.code.startswith("warn_")] == []


def test_every_validation_fires_on_a_broken_catalog():
    defs = build_example()
    defs.add(
        Entry("dinner:dup", "dinner", "dinner/chefs", "BB", "87"),
        Entry("dinner:ghost", "dinner", "dinner/nowhere", "NOPE", "999", ("NOPE:x",)),
        Group("empty", {"en": "Pick one"}, 1, 1),
        Option(
            "spice:bad",
            "spice",
            "bad",
            {"en": "Bad"},
            effects=(
                __import__("pos.menu.defs", fromlist=["Effect"]).Effect("add", ingredient="unobtainium", qty=D(1)),
            ),
        ),
        Recipe("GTC@2", "item", "GTC", 2, (Component("x1", "ingredient", "soy_sauce", D(1), "each"),)),
        AllergenOverride("item", "WINGS", "milk", "free", "chef guarantees"),  # wings use unreviewed dried chili
    )
    defs.recipes = [r if r.id != "GTC@1" else replace(r, is_current=False) for r in defs.recipes]
    codes = {p.code for p in MenuEngine(defs).check()}
    assert {
        "duplicate_number",
        "unknown_item",
        "unknown_section",
        "unknown_variant",
        "empty_required_group",
        "unknown_ingredient",
        "unit",
        "free_claim_unreviewed",
    } <= codes


def test_a_recipe_cycle_is_refused():
    defs = build_example()
    defs.add(Recipe("EGGROLL@2", "item", "EGGROLL", 2, (Component("loop", "variant", "PUPU:regular", D(1), "each"),)))
    defs.recipes = [r if r.id != "EGGROLL@1" else replace(r, is_current=False) for r in defs.recipes]
    assert any(p.code == "cycle" for p in MenuEngine(defs).check())


def test_a_modifier_targeting_a_missing_role_is_a_warning(engine, defs):
    from pos.menu.defs import Attachment

    defs.add(Attachment("item", "EGGROLL", "rice"))
    warnings = [p for p in engine.check() if p.code == "warn_missing_role"]
    assert any("EGGROLL" in w.message and "starch" in w.message for w in warnings)
