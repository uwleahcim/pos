"""The design's worked example, as the engine's first golden test."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal as D

from pos.menu import LineRequest, Selection, money
from pos.menu.fixtures.example import REVIEWED

QUART = LineRequest(
    "GTC:quart",
    1,
    "dinner:87",
    (Selection("spice", "spice:extra"), Selection("rice", "rice:brown"), Selection("addons", "addons:shrimp")),
)


def usage_of(line, code):
    return next(u for u in line.usage if u.ingredient == code)


def test_price_is_variant_base_plus_deltas(engine):
    line = engine.resolve(QUART)
    assert line.ok, line.problems
    assert (line.unit_price, line.price_source) == (D("24.95"), "variant_base")
    assert [m.price_delta for m in line.modifiers] == [D("0"), D("1.00"), D("4.00")]
    assert line.line_total == D("29.95")
    assert line.tax_class == "prepared_food"


def test_explosion_matches_the_design_table(engine):
    line = engine.resolve(QUART)
    chicken = usage_of(line, "chicken_thigh")
    assert round(chicken.qty) == 340 and round(chicken.purchased) == 400
    assert round(usage_of(line, "shrimp_3140").qty) == 85
    assert round(usage_of(line, "broccoli").purchased) == 126
    assert round(usage_of(line, "brown_rice_raw").qty) == 151
    assert usage_of(line, "dried_chili").qty == 12
    assert usage_of(line, "qt_container").qty == 1
    assert {u.ingredient for u in line.usage} == {
        "chicken_thigh",
        "shrimp_3140",
        "broccoli",
        "soy_sauce",
        "sugar",
        "rice_vinegar",
        "cornstarch",
        "garlic",
        "ginger",
        "brown_rice_raw",
        "dried_chili",
        "qt_container",
    }, "white rice is gone: the substitution removed it before explosion"
    assert line.cost == D("7.05")
    assert line.food_cost_pct == D("23.5")
    sauce_cost = sum(
        usage_of(line, c).cost for c in ("soy_sauce", "sugar", "rice_vinegar", "cornstarch", "garlic", "ginger")
    )
    assert money(sauce_cost) == D("0.54"), "ingredient costs stay exact; rounding happens at the line"


def test_allergens_refuse_to_call_anything_free_until_the_chili_is_reviewed(engine, defs):
    before = engine.resolve(QUART).allergens
    assert before.contains == {"wheat", "soy", "crustacean"}
    assert before.may_contain == {"sesame", "peanut"}
    assert before.free == frozenset()
    assert before.unknown == {"milk", "egg", "fish", "tree_nut", "msg"}
    assert "shrimp_3140:contains" in before.sources["crustacean"]
    assert "station:wok" in before.sources["sesame"]

    defs.ingredients["dried_chili"] = replace(defs.ingredients["dried_chili"], allergens_reviewed_at=REVIEWED)
    after = engine.resolve(QUART).allergens
    assert after.free == {"milk", "egg", "fish", "tree_nut", "msg"}
    assert after.unknown == frozenset()


def test_the_kitchen_gets_one_line_at_the_wok(engine):
    line = engine.resolve(QUART)
    assert [(k.station, k.text) for k in line.kitchen_lines] == [("wok", "1 左宗鸡 (Qt) · 加辣 · 糙米 · 加虾")]
    assert line.snapshot.recipe_version == "GTC@1"


def test_effects_report_what_they_did(engine):
    line = engine.resolve(QUART)
    by_option = {m.option_id: m for m in line.modifiers}
    assert by_option["spice:extra"].effects_applied[0].outcome == "applied"
    sub = by_option["rice:brown"].effects_applied[0]
    assert sub.op == "substitute" and sub.outcome == "applied" and "white_rice_cooked" in sub.detail
    assert by_option["addons:shrimp"].effects_applied[0].detail == "+3 oz"


def test_lunch_entry_overrides_the_price_and_scales_the_recipe(engine):
    line = engine.resolve(LineRequest("GTC:lunch", 1, "lunch:L12"))
    assert (line.unit_price, line.price_source, line.line_total) == (D("10.95"), "entry_override", D("10.95"))
    assert round(usage_of(line, "chicken_thigh").qty) == round(D("6") * D("28.35") * D("0.75"))
    assert line.modifiers[0].option_id == "spice:medium" and line.modifiers[0].defaulted
    assert line.kitchen_lines[0].text == "1 左宗鸡 (L)"


def test_quantity_scales_price_and_usage_linearly(engine):
    one = engine.resolve(QUART)
    three = engine.resolve(replace(QUART, qty=3))
    assert three.line_total == one.line_total * 3
    assert usage_of(three, "chicken_thigh").purchased == usage_of(one, "chicken_thigh").purchased * 3
    assert three.kitchen_lines[0].text.startswith("3 左宗鸡")


def test_add_on_quantities_multiply_price_and_effects(engine):
    line = engine.resolve(LineRequest("GTC:pint", 1, "dinner:87", (Selection("addons", "addons:shrimp", 2),)))
    assert line.modifiers[-1].price_delta == D("8.00")
    assert round(usage_of(line, "shrimp_3140").qty) == 170
    assert line.line_total == D("21.95")
