"""The design's property tests: whatever the choices, the rules hold."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal as D

from hypothesis import given, settings
from hypothesis import strategies as st

from pos.menu import LineRequest, MenuEngine, Selection
from pos.menu.fixtures.example import build_example
from tests.menu.conftest import DINNER_TIME

DEFS = build_example()
ENGINE = MenuEngine(DEFS, now=lambda: DINNER_TIME)

spice = st.sampled_from(["spice:mild", "spice:medium", "spice:extra"]).map(lambda o: Selection("spice", o))
rice = st.sampled_from(["rice:white", "rice:brown", "rice:none"]).map(lambda o: Selection("rice", o))
addon = st.tuples(
    st.sampled_from(["addons:shrimp", "addons:sauce", "addons:nomsg", "addons:sauceside"]), st.integers(1, 3)
).map(lambda t: Selection("addons", t[0], t[1] if t[0] == "addons:shrimp" else 1))
gtc_selections = st.tuples(
    st.lists(spice, max_size=1),
    st.lists(rice, max_size=1),
    st.lists(addon, max_size=4, unique_by=lambda s: s.option_id),
).map(lambda t: tuple(t[0] + t[1] + t[2]))
gtc_requests = st.builds(
    LineRequest,
    variant_id=st.sampled_from(["GTC:pint", "GTC:quart", "GTC:lunch"]),
    qty=st.integers(1, 5),
    menu_entry_id=st.none(),
    selections=gtc_selections,
)


@given(gtc_requests)
@settings(max_examples=150)
def test_price_is_never_negative_and_totals_add_up(request):
    line = ENGINE.resolve(request)
    assert line.unit_price >= 0 and all(m.price_delta >= 0 for m in line.modifiers)
    assert line.line_total == ((line.unit_price + line.modifier_total + line.children_total) * line.qty).quantize(
        D("0.01")
    )
    assert line.cost >= 0
    assert all(u.purchased >= u.qty >= 0 for u in line.usage)


@given(gtc_requests)
@settings(max_examples=100)
def test_resolution_is_a_pure_function_of_the_request(request):
    first, second = ENGINE.resolve(request), ENGINE.resolve(request)
    assert replace(first, snapshot=None) == replace(second, snapshot=None)


@given(gtc_requests)
@settings(max_examples=100)
def test_usage_is_linear_in_quantity(request):
    one = ENGINE.resolve(replace(request, qty=1))
    many = ENGINE.resolve(request)
    for a, b in zip(one.usage, many.usage, strict=True):
        assert a.ingredient == b.ingredient and b.purchased == a.purchased * request.qty
    assert many.line_total == one.line_total * request.qty


@given(gtc_requests)
@settings(max_examples=100)
def test_a_same_amount_substitution_conserves_quantity(request):
    chosen_rice = next((s for s in request.selections if s.group_id == "rice"), None)
    white = ENGINE.resolve(replace(request, selections=tuple(s for s in request.selections if s.group_id != "rice")))
    brown = ENGINE.resolve(
        replace(
            request,
            selections=(*[s for s in request.selections if s.group_id != "rice"], Selection("rice", "rice:brown")),
        )
    )
    cooked_white = next(u.qty for u in white.usage if u.ingredient == "white_rice_raw") * 3
    cooked_brown = next(u.qty for u in brown.usage if u.ingredient == "brown_rice_raw") * 3
    assert cooked_white == cooked_brown, chosen_rice


@given(gtc_requests)
@settings(max_examples=100)
def test_adding_never_removes_an_allergen(request):
    base = ENGINE.resolve(
        replace(request, selections=tuple(s for s in request.selections if s.option_id != "addons:shrimp"))
    )
    plus = ENGINE.resolve(
        replace(
            request,
            selections=(
                *[s for s in request.selections if s.option_id != "addons:shrimp"],
                Selection("addons", "addons:shrimp"),
            ),
        )
    )
    assert base.allergens.contains <= plus.allergens.contains
    assert base.allergens.may_contain <= plus.allergens.may_contain | plus.allergens.contains
    assert "crustacean" in plus.allergens.contains
