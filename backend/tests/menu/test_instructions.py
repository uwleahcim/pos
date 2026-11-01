"""One-tap instructions on a choice: NO, EXTRA, SIDE and LIGHT (`Selection.prefix`)."""

from __future__ import annotations

from decimal import Decimal as D

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu.engine import all_problems
from pos.menu.fixtures.example import build_example
from pos.menu.request import LineRequest, Selection
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.sync.oplog import OpStore
from tests.menu.conftest import DINNER_TIME


def test_no_makes_the_option_free_and_skips_its_effects(engine):
    plain = engine.resolve(LineRequest("GTC:pint", 1, "dinner:87"))
    line = engine.resolve(LineRequest("GTC:pint", 1, "dinner:87", (Selection("addons", "addons:shrimp", prefix="no"),)))
    assert line.line_total == plain.line_total == D("13.95")
    mod = next(m for m in line.modifiers if m.option_id == "addons:shrimp")
    assert (mod.kitchen_label, mod.prefix, mod.price_delta) == ("NO 加虾", "no", D(0))
    assert [e.outcome for e in mod.effects_applied] == ["no_op"]
    assert "NO 加虾" in line.kitchen_lines[0].labels
    assert list(all_problems(line)) == []


def test_side_and_extra_keep_the_price_and_print_in_front_of_the_label(engine):
    line = engine.resolve(
        LineRequest(
            "GTC:pint",
            1,
            "dinner:87",
            (Selection("rice", "rice:brown", prefix="side"), Selection("addons", "addons:sauce", prefix="extra")),
        )
    )
    assert line.line_total == D("15.45")  # 13.95 + 1.00 brown rice + 0.50 sauce
    labels = line.kitchen_lines[0].labels
    assert "SIDE 糙米" in labels and "EXTRA 多汁" in labels
    sauce = next(m for m in line.modifiers if m.option_id == "addons:sauce")
    assert [e.outcome for e in sauce.effects_applied] == ["applied"], "extra sauce still scales the sauce"


def test_an_option_without_a_kitchen_label_prints_under_its_name_when_instructed(engine):
    light = (Selection("spice", "spice:medium", prefix="light"),)
    line = engine.resolve(LineRequest("GTC:pint", 1, "dinner:87", light))
    assert "LIGHT Medium" in line.kitchen_lines[0].labels
    plain = engine.resolve(LineRequest("GTC:pint", 1, "dinner:87", (Selection("spice", "spice:medium"),)))
    assert plain.kitchen_lines[0].labels == (), "without an instruction a label-less option stays off the ticket"


def test_an_unknown_instruction_is_a_problem_and_the_option_is_charged_as_chosen(engine):
    line = engine.resolve(
        LineRequest("GTC:pint", 1, "dinner:87", (Selection("addons", "addons:shrimp", prefix="double"),))
    )
    assert [p.code for p in all_problems(line)] == ["bad_prefix"]
    assert line.line_total == D("17.95"), "13.95 plus the shrimp at this entry's 4.00"


def test_the_price_preview_shows_the_instruction_on_the_choice():
    api = TestClient(
        create_app(OpStore(), menu=MenuService(build_example(), now=lambda: DINNER_TIME), printing=PrintService([]))
    )
    r = api.post(
        "/menu/price",
        json={
            "variant_id": "GTC:pint",
            "entry_id": "dinner:87",
            "selections": [
                {"group_id": "addons", "option_id": "addons:shrimp", "prefix": "no"},
                {"group_id": "rice", "option_id": "rice:brown", "prefix": "side"},
            ],
        },
    )
    assert r.status_code == 200, r.text
    priced = r.json()
    assert priced["unit_price"] == "14.95" and priced["problems"] == []
    by_option = {m["option_id"]: m for m in priced["modifiers"]}
    assert (by_option["addons:shrimp"]["label"], by_option["addons:shrimp"]["prefix"]) == ("NO Add shrimp", "no")
    assert D(by_option["addons:shrimp"]["price"]) == 0
    assert (by_option["rice:brown"]["label"], by_option["rice:brown"]["price"]) == ("SIDE Brown rice", "1.00")
    assert "SIDE 糙米" in priced["kitchen"][0]["labels"] and "NO 加虾" in priced["kitchen"][0]["labels"]
