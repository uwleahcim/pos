"""Validation comes back as problems on the line, never as exceptions."""

from __future__ import annotations

from datetime import timedelta

from pos.menu import LineRequest, Selection
from tests.menu.conftest import DINNER_TIME


def codes(engine, request):
    return sorted(p.code for p in engine.validate(request))


def test_unknown_things(engine):
    assert codes(engine, LineRequest("GTC:gallon")) == ["unknown_variant"]
    assert codes(engine, LineRequest("GTC:pint", 1, "dinner:999")) == ["unknown_entry"]
    assert codes(engine, LineRequest("GTC:pint", 1, "dinner:88")) == ["entry_mismatch"]
    assert codes(engine, LineRequest("GTC:lunch", 1, "dinner:87")) == ["variant_not_offered"]
    assert codes(engine, LineRequest("GTC:pint", 1, None, (Selection("spice", "spice:nuclear"),))) == ["unknown_option"]
    assert codes(engine, LineRequest("GTC:pint", 1, None, (Selection("entree_slot", "entree_slot:gtc"),))) == [
        "group_not_attached"
    ]


def test_selection_rules(engine):
    assert codes(
        engine, LineRequest("GTC:pint", 1, None, (Selection("spice", "spice:mild"), Selection("spice", "spice:extra")))
    ) == ["too_many"]
    assert codes(engine, LineRequest("GTC:pint", 1, None, (Selection("spice", "spice:mild", 2),))) == ["qty"]
    assert codes(engine, LineRequest("GTC:pint", 1, None, (Selection("addons", "addons:shrimp", 5),))) == ["max_qty"]
    assert codes(
        engine,
        LineRequest("GTC:pint", 1, None, (Selection("addons", "addons:shrimp"), Selection("addons", "addons:shrimp"))),
    ) == ["duplicate"]
    assert codes(engine, LineRequest("GTC:pint", 0)) == ["qty"]


def test_required_slot_without_a_default_must_be_answered(engine, defs):
    defs.options["entree_slot:gtc"] = type(defs.options["entree_slot:gtc"])(
        **{**defs.options["entree_slot:gtc"].__dict__, "is_default": False}
    )
    assert codes(engine, LineRequest("C5:regular")) == ["too_few"]
    assert codes(engine, LineRequest("C5:regular", 1, None, (Selection("entree_slot", "entree_slot:bb"),))) == []


def test_sold_out_options_and_variants_come_back_as_problems_until_cleared(engine):
    engine.set_availability(
        "rice:brown", "sold_out", until=DINNER_TIME + timedelta(hours=2), reason="ran out", by="chef"
    )
    engine.set_availability("GTC:quart", "sold_out")
    assert codes(engine, LineRequest("GTC:quart", 1, None, (Selection("rice", "rice:brown"),))) == [
        "sold_out",
        "sold_out",
    ]
    assert codes(
        engine,
        LineRequest(
            "GTC:quart",
            1,
            None,
            (Selection("rice", "rice:brown"),),
        ),
    ) == ["sold_out", "sold_out"]
    later = DINNER_TIME + timedelta(hours=3)
    assert (
        sorted(
            p.code
            for p in engine.validate(LineRequest("GTC:pint", 1, None, (Selection("rice", "rice:brown"),)), at=later)
        )
        == []
    )
    engine.set_availability("GTC:quart", "available")
    assert codes(engine, LineRequest("GTC:quart")) == []


def test_a_substitution_with_no_matching_role_is_a_no_op_that_still_prints(engine):
    line = engine.resolve(LineRequest("EGGROLL:regular", 1, None, (Selection("rice", "rice:brown"),)))
    assert [p.code for p in line.problems] == ["group_not_attached"], "egg rolls have no rice question"
    wings = engine.resolve(LineRequest("WINGS:6pc", 1, None, (Selection("spice", "spice:extra"),)))
    assert wings.modifiers[0].effects_applied[0].outcome == "applied"
