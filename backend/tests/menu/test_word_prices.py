"""What a one-tap word on a choice charges (the Toast comparison, 2026-11-15, Mike's yes): Extra charges the
option again, On the side and Light charge it once, a free option stays free, and "no" costs nothing as before.
The location can set each word's factor (`Word`), and a group can charge otherwise (`Group.word_factors`)."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal as D

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu import admin
from pos.menu.defs import Group, Option, Word
from pos.menu.engine import MenuEngine, all_problems
from pos.menu.fixtures.example import build_example
from pos.menu.request import LineRequest, Selection
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.sync.oplog import OpStore
from tests.menu.conftest import DINNER_TIME

PINT = D("13.95")  # General Tso's Chicken, pint; the shrimp add-on is 4.00 on this dish, the sauce 0.50


def sell(engine: MenuEngine, *picks: tuple, variant: str = "GTC:pint", entry: str | None = "dinner:87"):
    selections = tuple(Selection(group, option, qty, prefix=word) for group, option, word, qty in picks)
    line = engine.resolve(LineRequest(variant, 1, entry, selections))
    assert list(all_problems(line)) == []
    return line


def delta(line, option_id: str) -> D:
    return next(m.price_delta for m in line.modifiers if m.option_id == option_id)


def test_extra_charges_the_option_again_and_the_other_words_charge_it_once(engine):
    plain = sell(engine, ("addons", "addons:shrimp", None, 1))
    extra = sell(engine, ("addons", "addons:shrimp", "extra", 1))
    assert (plain.line_total, extra.line_total) == (PINT + D("4.00"), PINT + D("8.00"))
    assert delta(extra, "addons:shrimp") == D("8.00")
    for word in ("side", "light"):
        assert sell(engine, ("addons", "addons:shrimp", word, 1)).line_total == PINT + D("4.00")
    assert sell(engine, ("addons", "addons:shrimp", "no", 1)).line_total == PINT


def test_a_free_option_stays_free_and_two_of_an_extra_are_each_charged_again(engine):
    hot = sell(engine, ("spice", "spice:mild", "extra", 1))
    assert hot.line_total == PINT and "EXTRA 少辣" in hot.kitchen_lines[0].labels
    two = sell(engine, ("addons", "addons:shrimp", "extra", 2))
    assert delta(two, "addons:shrimp") == D("16.00")  # two shrimp add-ons, each charged again
    assert "2x EXTRA 加虾" in two.kitchen_lines[0].labels


def test_a_pick_the_group_gives_free_is_free_with_extra_too(defs):
    defs.add(
        Group("toppings", {"en": "Toppings"}, 0, None, free_count=1),
        Option("toppings:scallion", "toppings", "scallion", {"en": "Scallion"}, "葱", price=D("0.75")),
        Option("toppings:peanut", "toppings", "peanut", {"en": "Peanuts"}, "花生", price=D("0.75")),
    )
    defs.attachments.append(replace(defs.attachments[0], owner_kind="item", owner="GTC", group="toppings", sort=9))
    engine = MenuEngine(defs, now=lambda: DINNER_TIME)
    line = sell(engine, ("toppings", "toppings:scallion", "extra", 1), ("toppings", "toppings:peanut", "extra", 1))
    # the first pick is the free one, whatever its word; the second costs its price twice
    assert (delta(line, "toppings:scallion"), delta(line, "toppings:peanut")) == (D(0), D("1.50"))


def test_the_location_sets_what_each_word_charges_and_a_cent_is_rounded_up(defs):
    defs.add(Word("extra", D("1.5")), Word("light", D("0.5")))
    engine = MenuEngine(defs, now=lambda: DINNER_TIME)
    assert delta(sell(engine, ("addons", "addons:shrimp", "extra", 1)), "addons:shrimp") == D("6.00")
    assert delta(sell(engine, ("addons", "addons:shrimp", "light", 1)), "addons:shrimp") == D("2.00")
    assert delta(sell(engine, ("addons", "addons:sauce", "extra", 1)), "addons:sauce") == D("0.75")
    assert delta(sell(engine, ("addons", "addons:sauce", "light", 1)), "addons:sauce") == D("0.25")
    defs.add(Word("light", D("0.75")))
    assert delta(sell(engine, ("addons", "addons:sauce", "light", 1)), "addons:sauce") == D("0.38")  # 0.375
    # a word the location says nothing of keeps the standing rule
    assert delta(sell(engine, ("addons", "addons:shrimp", "side", 1)), "addons:shrimp") == D("4.00")
    assert admin.problems(defs)[0] == []


def test_a_group_charges_otherwise_than_the_location_for_the_words_it_names(defs):
    defs.add(Word("light", D("0.5")))
    defs.groups["addons"] = replace(defs.groups["addons"], word_factors={"extra": D(1)})
    engine = MenuEngine(defs, now=lambda: DINNER_TIME)
    assert delta(sell(engine, ("addons", "addons:shrimp", "extra", 1)), "addons:shrimp") == D("4.00")
    assert delta(sell(engine, ("addons", "addons:shrimp", "light", 1)), "addons:shrimp") == D("2.00")
    # the brown rice is in another group: Extra charges its 1.00 again there
    assert delta(sell(engine, ("rice", "rice:brown", "extra", 1)), "rice:brown") == D("2.00")
    assert defs.word_factors(defs.groups["addons"]) == {"extra": D(1), "side": D(1), "light": D("0.5")}
    assert defs.word_factors() == {"extra": D(2), "side": D(1), "light": D("0.5")}


def test_a_choice_that_is_a_dish_is_not_charged_again(engine):
    plain = sell(engine, ("rice_slot", "rice_slot:brown", None, 1), variant="C5:regular", entry="dinner:C5")
    extra = sell(engine, ("rice_slot", "rice_slot:brown", "extra", 1), variant="C5:regular", entry="dinner:C5")
    assert extra.line_total == plain.line_total


def test_a_screen_is_told_what_each_word_charges_in_each_group(defs):
    defs.groups["addons"] = replace(defs.groups["addons"], word_factors={"extra": D("1.5")})
    api = TestClient(create_app(OpStore(), menu=MenuService(defs, now=lambda: DINNER_TIME), printing=PrintService([])))
    groups = {g["group_id"]: g for g in api.get("/menu/items/GTC", params={"entry_id": "dinner:87"}).json()["groups"]}
    assert {word: D(f) for word, f in groups["rice"]["words"].items()} == {"extra": 2, "side": 1, "light": 1}
    assert {word: D(f) for word, f in groups["addons"]["words"].items()} == {"extra": D("1.5"), "side": 1, "light": 1}
    priced = api.post(
        "/menu/price",
        json={
            "variant_id": "GTC:pint",
            "entry_id": "dinner:87",
            "selections": [
                {"group_id": "addons", "option_id": "addons:shrimp", "prefix": "extra"},
                {"group_id": "rice", "option_id": "rice:brown", "prefix": "extra"},
            ],
        },
    ).json()
    assert priced["unit_price"] == "21.95" and priced["problems"] == []  # 13.95 + 6.00 + 2.00
    rows = {m["option_id"]: (m["label"], m["price"]) for m in priced["modifiers"]}
    assert rows["addons:shrimp"] == ("EXTRA Add shrimp", "6.00")
    assert rows["rice:brown"] == ("EXTRA Brown rice", "2.00")


def test_the_editor_sets_the_rule_for_the_location_and_for_a_group_and_a_wrong_one_is_refused():
    defs = build_example()
    assert admin.catalog(defs)["word"] == []  # nobody has said: the standing rule
    row = next(g for g in admin.catalog(defs)["group"] if g["key"] == "addons")
    assert row["word_factors"] is None
    data = {k: v for k, v in row.items() if k != "key"}
    saved = admin.apply(
        defs,
        [
            {"kind": "word", "op": "put", "data": {"code": "extra", "factor": "1.5"}},
            {"kind": "group", "op": "put", "data": {**data, "word_factors": {"extra": "1", "light": "0.5"}}},
        ],
    )
    assert admin.problems(saved)[0] == []
    assert saved.words["extra"] == Word("extra", D("1.5"))
    assert saved.groups["addons"].word_factors == {"extra": D(1), "light": D("0.5")}
    assert admin.catalog(saved)["word"] == [{"key": "extra", "code": "extra", "factor": "1.5"}]
    assert next(g for g in admin.catalog(saved)["group"] if g["key"] == "addons")["word_factors"] == {
        "extra": "1",
        "light": "0.5",
    }
    # taking the location's row away brings the standing rule back
    back = admin.apply(saved, [{"kind": "word", "op": "delete", "key": "extra"}])
    assert back.word_factor(back.groups["rice"], "extra") == D(2)
    # a copy made for an edit or an import keeps the rule
    assert admin.copy_of(saved).words == saved.words

    wrong = admin.apply(
        defs,
        [
            {"kind": "word", "op": "put", "data": {"code": "no", "factor": "1"}},
            {"kind": "word", "op": "put", "data": {"code": "light", "factor": "-1"}},
            {"kind": "group", "op": "put", "data": {**data, "word_factors": {"double": "2", "extra": "11"}}},
        ],
    )
    assert [(p.code, p.message) for p in admin.problems(wrong)[0]] == [
        ("bad_word", "the location's rule: no price can be set for 'no'; one of extra, side, light"),
        ("bad_factor", "the location's rule: light must charge between 0 and 10 times the option"),
        ("bad_word", "addons: no price can be set for 'double'; one of extra, side, light"),
        ("bad_factor", "addons: extra must charge between 0 and 10 times the option"),
    ]
