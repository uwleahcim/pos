"""Combination Plate C5 and the Pu Pu Platter: slots, nested items, locks."""

from __future__ import annotations

from decimal import Decimal as D

from pos.menu import ComponentRequest, LineRequest, Selection


def test_c5_rings_in_with_defaults(engine):
    line = engine.resolve(LineRequest("C5:regular", 1, "dinner:C5"))
    assert line.ok, list(line.problems) + [p for c in line.children for p in c.problems]
    assert line.line_total == D("14.50")
    assert [c.variant_id for c in line.children] == ["GTC:lunch", "EGGROLL:regular", "PFR:side"]
    assert all(c.origin == "slot" and c.price_source == "slot" and c.unit_price == 0 for c in line.children)
    entree = line.children[0]
    assert entree.modifiers[0].option_id == "spice:medium" and entree.modifiers[0].defaulted
    assert [(k.station, k.text, k.header) for k in line.kitchen_lines] == [
        ("wok", "1 左宗鸡 (L)", "C5 套餐"),
        ("fryer", "1 蛋卷", "C5 套餐"),
        ("wok", "1 叉烧炒饭 (small)", "C5 套餐"),
    ]


def test_c5_allergens_are_the_union_of_its_children(engine):
    profile = engine.resolve(LineRequest("C5:regular", 1, "dinner:C5")).allergens
    assert {"wheat", "soy", "egg"} <= profile.contains
    assert {"sesame", "peanut", "fish", "crustacean"} <= profile.may_contain
    assert "tree_nut" in profile.unknown, "the entree's chili is unreviewed, so the combo cannot claim free"


def test_c5_explosion_is_the_children_plus_the_cookie_and_container(engine):
    line = engine.resolve(LineRequest("C5:regular", 1, "dinner:C5"))
    usage = {u.ingredient: u for u in engine.explode(line)}
    assert usage["fortune_cookie"].qty == 1 and usage["combo_container"].qty == 1
    assert "eggroll_wrapper" in usage and "chicken_thigh" in usage and "pork_bbq" in usage
    assert line.cost == sum((c.cost for c in line.children), D(0)) + D("0.35")


def test_slot_choices_and_nested_customization(engine):
    line = engine.resolve(
        LineRequest(
            "C5:regular",
            1,
            "dinner:C5",
            (
                Selection(
                    "entree_slot",
                    "entree_slot:gtc",
                    children=(Selection("spice", "spice:extra"), Selection("addons", "addons:shrimp")),
                ),
                Selection("rice_slot", "rice_slot:brown"),
            ),
        )
    )
    assert line.ok, [p for c in line.children for p in c.problems]
    assert line.line_total == D("14.50") + D("1.00") + D("4.00")
    entree = next(c for c in line.children if c.variant_id == "GTC:lunch")
    assert [m.option_id for m in entree.modifiers] == ["spice:extra", "rice:white", "addons:shrimp"]
    assert "crustacean" in line.allergens.contains
    assert entree.kitchen_lines[0].text == "1 左宗鸡 (L) · 加辣 · 加虾"


def test_a_locked_slot_refuses_customization(engine):
    line = engine.resolve(
        LineRequest(
            "C5:regular",
            1,
            "dinner:C5",
            (Selection("side_slot", "side_slot:eggroll", children=(Selection("spice", "spice:extra"),)),),
        )
    )
    side = next(c for c in line.children if c.variant_id == "EGGROLL:regular")
    assert side.locked and [p.code for p in side.problems] == ["group_not_attached"]


def test_pu_pu_platter_nests_dishes_and_explodes_the_half_portion_inline(engine):
    line = engine.resolve(LineRequest("PUPU:regular", 1, "dinner:4"))
    assert line.ok, line.problems
    assert line.line_total == D("16.95")
    assert [c.variant_id for c in line.children] == ["EGGROLL:regular", "WINGS:6pc"]
    assert all(c.price_source == "included" and c.origin == "component" for c in line.children)
    wings = line.children[1]
    assert wings.modifiers[0].option_id == "spice:mild" and wings.modifiers[0].defaulted
    inline = {u.ingredient for u in line.usage}
    assert "springroll_wrapper" in inline and "carrot" in inline, "half a spring roll is exploded in place"
    assert {k.station for k in line.kitchen_lines} == {"fryer"}


def test_pu_pu_platter_components_can_be_customized_unless_locked(engine):
    custom = engine.resolve(
        LineRequest(
            "PUPU:regular", 1, "dinner:4", components=(ComponentRequest("pp2", (Selection("spice", "spice:extra"),)),)
        )
    )
    assert custom.ok and custom.children[1].modifiers[0].option_id == "spice:extra"
    locked = engine.resolve(
        LineRequest(
            "PUPU:regular", 1, "dinner:4", components=(ComponentRequest("pp1", (Selection("spice", "spice:extra"),)),)
        )
    )
    assert [p.code for p in locked.problems] == ["locked"]
    fractional = engine.resolve(
        LineRequest(
            "PUPU:regular", 1, "dinner:4", components=(ComponentRequest("pp3", (Selection("spice", "spice:extra"),)),)
        )
    )
    assert [p.code for p in fractional.problems] == ["locked"]
