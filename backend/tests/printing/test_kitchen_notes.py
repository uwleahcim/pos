"""One-tap notes to the kitchen: a short list of words a location sets ("Rush", "Split for 2"), which the
dish's sheet shows as buttons. A tap puts the words in the dish's note, so the order carries the words
themselves and the ticket prints them under the dish as it prints a typed note."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pos.settings import STANDARD_KITCHEN_NOTES, clean_kitchen_notes

from ..orders.test_menu_orders import payload
from .fake_printer import decode
from .test_other_stations import kitchen
from .test_stations import manager


def test_a_location_starts_with_a_short_list():
    c = kitchen("wok")
    assert c.get("/settings/kitchen_notes").json() == {"notes": STANDARD_KITCHEN_NOTES}
    assert STANDARD_KITCHEN_NOTES[:2] == ["Rush", "Split for 2"]


def test_a_manager_lists_the_notes_and_nobody_else_does():
    c = kitchen("wok")
    listed = {"notes": ["  Rush ", "Split   for 2", "Cut in half"]}
    assert c.put("/settings/kitchen_notes", json=listed).status_code == 401
    server, _ = c.app.state.tokens.issue("s1", "Amy", "server")
    refused = c.put("/settings/kitchen_notes", json=listed, headers={"authorization": f"Bearer {server}"})
    assert refused.status_code == 403
    saved = c.put("/settings/kitchen_notes", json=listed, headers=manager(c))
    # tidied, in the order given: the order the buttons show
    assert saved.status_code == 200 and saved.json() == {"notes": ["Rush", "Split for 2", "Cut in half"]}
    assert c.get("/settings/kitchen_notes").json() == saved.json()
    # an empty list offers none: the note is typed as before
    none = c.put("/settings/kitchen_notes", json={"notes": []}, headers=manager(c))
    assert none.status_code == 200 and c.get("/settings/kitchen_notes").json() == {"notes": []}


def test_what_the_setting_refuses():
    assert clean_kitchen_notes({}) == {"notes": STANDARD_KITCHEN_NOTES}  # left out: the standard ones
    assert clean_kitchen_notes({"notes": []}) == {"notes": []}
    for bad, why in [
        ({"notes": "Rush"}, "a list of words"),
        ({"notes": [{"name": "Rush"}]}, "a list of words"),
        ({"notes": [f"Note {n}" for n in range(13)]}, "at most 12 notes"),
        ({"notes": [" "]}, "needs its words"),
        ({"notes": ["x" * 25]}, "at most 24 characters"),
        # several notes on a dish are joined with commas, so one note holds none
        ({"notes": ["Rush, please"]}, "no comma"),
        ({"notes": ["Rush", "rush"]}, "listed twice"),
    ]:
        with pytest.raises(ValueError, match=why):
            clean_kitchen_notes(bad)
    c = kitchen("wok")
    told = c.put("/settings/kitchen_notes", json={"notes": ["Rush", "RUSH"]}, headers=manager(c))
    assert told.status_code == 422 and told.json()["detail"]["error"] == "bad_value"
    assert "listed twice" in told.json()["detail"]["message"]
    assert c.get("/settings/kitchen_notes").json() == {"notes": STANDARD_KITCHEN_NOTES}  # nothing was saved


def post(c: TestClient, *ops: dict, order_id: str = "o1") -> None:
    told = c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops])
    assert told.status_code == 202, told.text


def test_the_words_tapped_print_under_the_dish_like_a_typed_note():
    c = kitchen("wok")
    post(
        c,
        payload("open", "create", 0, table="T1"),
        payload("a1", "add_line", 1, line_id="L1", item="Kung Pao Chicken (Pt)", note="Rush, Split for 2"),
        payload("send", "fire", 2),
    )
    paper = decode(c.app.state.printing.store.get("send:wok").data)
    assert "** Rush, Split for 2 **" in [line.strip() for line in paper.text]


def test_a_note_dropped_from_the_list_stays_on_the_dishes_that_carry_it():
    c = kitchen("wok")
    post(
        c,
        payload("open", "create", 0, table="T1"),
        payload("a1", "add_line", 1, line_id="L1", item="Kung Pao Chicken (Pt)", note="Rush"),
    )
    assert c.put("/settings/kitchen_notes", json={"notes": ["Hurry"]}, headers=manager(c)).status_code == 200
    assert c.get("/orders/o1").json()["lines"]["L1"]["note"] == "Rush"
