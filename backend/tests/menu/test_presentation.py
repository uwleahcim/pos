"""Menus by channel and time, search, item detail, dependents."""

from __future__ import annotations

from decimal import Decimal as D

from tests.menu.conftest import LUNCH_TIME, WEEKEND_LUNCH


def test_menus_follow_channel_schedule_and_priority(engine):
    at_lunch = engine.menu_for("pos", LUNCH_TIME)
    assert [m.menu for m in at_lunch] == ["lunch", "dinner"], "lunch outranks dinner while both are open"
    assert [m.menu for m in engine.menu_for("pos", WEEKEND_LUNCH)] == ["dinner"]
    assert [m.menu for m in engine.menu_for("online", LUNCH_TIME)] == ["dinner"]
    lunch = at_lunch[0]
    entry = lunch.sections[0].entries[0]
    assert (entry.number, entry.item, entry.name) == ("L12", "GTC", "General Tso's Chicken")
    assert [(v.variant_id, v.price, v.price_source) for v in entry.variants] == [
        ("GTC:lunch", D("10.95"), "entry_override")
    ]
    assert entry.contains == ("soy", "wheat") and "peanut" in entry.may_contain


def test_menu_in_another_language_with_fallback(engine):
    dinner = engine.menu_for("pos", locale="zh")[0]
    assert dinner.name == "晚餐"
    chefs = next(s for s in dinner.sections if s.section_id == "dinner/chefs")
    assert chefs.entries[0].name == "左宗棠鸡"
    traditional = engine.menu_for("pos", locale="zh-Hant")[0]
    assert next(s for s in traditional.sections if s.section_id == "dinner/chefs").entries[0].name == "左宗棠鸡", (
        "zh-Hant falls back to zh"
    )


def test_sold_out_shows_on_the_menu(engine):
    engine.set_availability("GTC:quart", "sold_out", reason="no chicken")
    chefs = next(s for s in engine.menu_for("pos")[0].sections if s.section_id == "dinner/chefs")
    assert [(v.variant_id, v.status) for v in chefs.entries[0].variants] == [
        ("GTC:pint", "available"),
        ("GTC:quart", "sold_out"),
    ]


def test_search_by_number_name_alias_and_pinyin(engine):
    assert engine.search("87", "pos")[0].item == "GTC"
    assert engine.search("L12", "pos", LUNCH_TIME)[0].number == "L12"
    assert engine.search("L12", "pos") == [], "lunch numbers do not match outside lunch hours"
    assert engine.search("zzt")[0].item == "GTC"
    assert engine.search("general")[0].item == "GTC"
    assert engine.search("左宗")[0].item == "GTC"
    assert engine.search("c5", "pos")[0].item == "C5"
    assert [h.item for h in engine.search("rice")][:2] == ["PFR", "BRICE"] or "PFR" in [
        h.item for h in engine.search("rice")
    ]
    assert engine.search("   ") == []


def test_item_detail_shows_effective_prices_and_defaults(engine):
    detail = engine.item_detail("GTC", "dinner:87")
    assert [v.variant_id for v in detail.variants] == ["GTC:pint", "GTC:quart"]
    assert [g.group_id for g in detail.groups] == ["spice", "rice", "addons"]
    addons = detail.groups[2]
    assert addons.allow_quantity and addons.options[0].price == D("4.00"), (
        "the item attachment overrides the shrimp price"
    )
    assert next(o for o in detail.groups[0].options if o.is_default).option_id == "spice:medium"
    assert (detail.tax_class, detail.station) == ("prepared_food", "wok")
    combo = engine.item_detail("C5")
    assert [o.linked_variant for o in combo.groups[0].options] == ["GTC:lunch", "BB:lunch"]


def test_dependents_walk_preps_nested_dishes_and_combo_slots(engine):
    # GTC through the sauce prep, C5 through its entree slot, PFR directly; BB uses oyster sauce, not soy
    assert engine.dependents("soy_sauce") == [
        "C5:regular",
        "GTC:lunch",
        "GTC:pint",
        "GTC:quart",
        "PFR:regular",
        "PFR:side",
    ]
    assert engine.dependents("qt_container") == ["GTC:quart"]
    assert "PUPU:regular" in engine.dependents("eggroll_wrapper") and "C5:regular" in engine.dependents(
        "eggroll_wrapper"
    )


def test_cost_breakdown(engine):
    breakdown = engine.cost("GTC:quart", entry_id="dinner:87")
    assert (breakdown.price, breakdown.cost) == (D("24.95"), D("4.68"))
    assert breakdown.margin == D("20.27") and breakdown.food_cost_pct == D("18.8")
