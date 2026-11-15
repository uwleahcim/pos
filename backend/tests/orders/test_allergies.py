"""An allergy told at the table: kept on the order for a seat or the whole table, the latest word on each
standing, and held against what the menu says each dish contains."""

from __future__ import annotations

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import PrintService
from pos.sync.oplog import ALLERGY_NOTE_MAX, OpStore, replay

from ..conftest import T0, make_op
from .test_menu_orders import DINNER, GTC_QUART, payload


def told(at: int, seat: int | None = None, *allergens: str, note: str = "", **more):
    return make_op("allergy", at=at, seat=seat, allergens=list(allergens), note=note, **more)


def test_an_allergy_is_kept_for_a_seat_or_the_whole_table():
    state = replay(
        [
            make_op("create", at=0, table="12", guests=3),
            told(1, 2, "peanut", "sesame", by="Amy", by_id="s1"),
            told(2, None, "crustacean", note="  no  oyster sauce "),
        ]
    )
    assert state.allergy_list() == [
        {"seat": None, "allergens": ["crustacean"], "note": "no oyster sauce", "by": "", "by_id": None},
        {"seat": 2, "allergens": ["peanut", "sesame"], "note": "", "by": "Amy", "by_id": "s1"},
    ]
    assert state.snapshot()["allergies"] == state.allergy_list()
    assert state.allergens_for(2) == ["crustacean", "peanut", "sesame"]  # the table's and the seat's own
    assert state.allergens_for(1) == state.allergens_for(None) == ["crustacean"]


def test_the_latest_word_on_a_seat_stands_and_seats_do_not_overwrite_each_other():
    ops = [
        make_op("create", at=0, table="12"),
        told(5, 1, "peanut", node="a"),
        told(6, 2, "sesame", node="b"),  # another screen, another seat: both count
        told(7, 1, "wheat", "peanut", "wheat", node="b"),  # seat 1 again: this is what stands, each once
    ]
    for order in (ops, ops[::-1], [ops[3], ops[0], ops[2], ops[1]]):
        state = replay(order)
        assert [(a["seat"], a["allergens"]) for a in state.allergy_list()] == [
            (1, ["wheat", "peanut"]),
            (2, ["sesame"]),
        ]


def test_an_allergy_with_nothing_in_it_takes_the_allergy_off():
    state = replay([make_op("create", at=0), told(1, 2, "peanut"), told(2, None, note="celery"), told(3, 2)])
    assert [(a["seat"], a["note"]) for a in state.allergy_list()] == [(None, "celery")]
    # an older word that arrives late does not bring it back
    assert replay([told(3, 2), told(1, 2, "peanut")]).allergy_list() == []


def test_whatever_a_screen_sends_is_read_safely():
    state = replay(
        [
            told(1, 0, "peanut"),  # seat 0 is no seat: the table
            make_op("allergy", at=2, seat="2", allergens="peanut", note=None),  # not a seat, not a list: nothing
            make_op("allergy", at=3, seat=True, allergens=[" sesame ", 7, ""], note="x" * 200),
        ]
    )
    (table,) = state.allergy_list()
    assert table["seat"] is None and table["allergens"] == ["sesame"] and len(table["note"]) == ALLERGY_NOTE_MAX


def client() -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=MenuService(load_definitions("restaurant"), now=lambda: DINNER),
            printing=PrintService([], direct=False),
        )
    )


def test_the_menu_lists_its_allergens_for_the_screen_to_offer():
    listed = client().get("/menu/allergens").json()["allergens"]
    assert listed[0] == {"code": "milk", "name": "Milk"} and {"code": "peanut", "name": "Peanuts"} in listed
    assert [a["code"] for a in listed][-1] == "msg"  # in the menu's order: the nine majors, then its own


def test_a_dish_the_menu_says_contains_the_allergen_is_marked_for_its_seat():
    c = client()
    ops = [
        payload("a", "create", 0, table="12", guests=2),
        payload("b", "add_line", 1, line_id="L1", item="?", seat=1, request=GTC_QUART),  # soy and wheat
        payload("c", "add_line", 2, line_id="L2", item="?", seat=2, request=GTC_QUART),
        payload("d", "add_line", 3, line_id="L3", item="?", seat=2, request={"variant_id": "CALROLL:roll"}),
        payload("e", "allergy", 4, seat=2, allergens=["wheat", "peanut"], by="Amy"),
    ]
    assert c.post("/orders/o1/ops", json=ops).json()["refused"] == []
    order = c.get("/orders/o1").json()
    assert order["allergies"] == [{"seat": 2, "allergens": ["wheat", "peanut"], "note": "", "by": "Amy", "by_id": None}]
    assert {line: order["lines"][line]["allergy"] for line in ("L1", "L2", "L3")} == {
        "L1": [],  # another seat's dish
        "L2": ["wheat"],
        "L3": [],  # the menu names nothing in it: no mark, and no promise either
    }
    # told for the whole table, it is held against every dish
    c.post("/orders/o1/ops", json=[payload("f", "allergy", 5, allergens=["soy"])])
    order = c.get("/orders/o1").json()
    assert order["lines"]["L1"]["allergy"] == ["soy"] and order["lines"]["L2"]["allergy"] == ["soy", "wheat"]
    # taken off again, nothing is marked
    c.post("/orders/o1/ops", json=[payload("g", "allergy", 6), payload("h", "allergy", 7, seat=2)])
    order = c.get("/orders/o1").json()
    assert order["allergies"] == [] and order["lines"]["L2"]["allergy"] == []
