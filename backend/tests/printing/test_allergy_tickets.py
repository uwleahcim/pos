"""An allergy told at the table reaches the kitchen: in a block of its own on every station's ticket, under
each dish of the seat it was told for, and on a ticket of its own when it is told after dishes were sent."""

from __future__ import annotations

from fastapi.testclient import TestClient

from ..conftest import servers_void
from ..orders.test_menu_orders import payload
from .fake_printer import Decoded, decode
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen


def post(c: TestClient, *ops: dict, order_id: str = "o1") -> None:
    sent = c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops])
    assert sent.status_code == 202 and sent.json()["refused"] == []


def dish(op_id: str, at: int, request: dict, seat: int | None = None) -> dict:
    return payload(op_id, "add_line", at, line_id=op_id, item="?", seat=seat, request=request)


def ticket(c: TestClient, key: str, printer: str) -> Decoded | None:
    job = c.app.state.printing.store.get(f"{key}:{printer}")
    return None if job is None else decode(job.data)


def below(text: list[str], line: str, count: int = 1) -> list[str]:
    at = text.index(line)
    return text[at + 1 : at + 1 + count]


def test_an_allergy_stands_in_a_block_on_every_station_s_ticket():
    c = kitchen("wok", "sushi")
    post(
        c,
        payload("open", "create", 0, table="12", guests=2, order_type="dine_in"),
        dish("L1", 1, CHICKEN, seat=1),
        dish("L2", 2, ROLL, seat=2),
        payload("a1", "allergy", 3, seat=2, allergens=["peanut", "crustacean"], note="no oyster sauce"),
        payload("a2", "allergy", 4, allergens=["sesame"]),
        payload("fire", "fire", 5, course="*"),
    )
    wok, sushi = ticket(c, "fire", "wok"), ticket(c, "fire", "sushi")
    for printed in (wok, sushi):  # the wok cooks nothing for seat 2 and reads its allergy all the same
        assert "ALLERGY" in printed.inverted
        assert below(printed.text, "ALLERGY".center(24), 3) == [
            "Table: Sesame",
            "Seat 2: Peanuts, Crustacean shellfish - no",  # a long one wraps under itself
            "  oyster sauce",
        ]
    assert wok.text[0] == "WOK"  # a new ticket like any other
    # under each dish of the seat it was told for, and under no other
    assert below(sushi.text, "    ** ALLERGY: Peanuts, Crustacean shellfish -") == ["  no oyster sauce **"]
    assert not [t for t in wok.text if t.startswith("    ** ALLERGY")]
    assert c.app.state.printing.store.get("a1:wok") is None  # nothing was at the kitchen yet: no notice


def test_an_allergy_told_after_sending_prints_at_every_station_that_has_dishes():
    c = kitchen("wok", "sushi", "bar")
    post(
        c,
        payload("open", "create", 0, table="12", guests=2, order_type="dine_in"),
        dish("L1", 1, CHICKEN, seat=1),
        dish("L2", 2, ROLL, seat=2),
        payload("fire", "fire", 3, course="*"),
        dish("L3", 4, BEER, seat=2),  # not sent yet: the bar has nothing to be told about
    )
    assert "ALLERGY" not in ticket(c, "fire", "wok").inverted
    post(c, payload("told", "allergy", 10, seat=2, allergens=["peanut"], by="Amy"))
    wok, sushi = ticket(c, "told", "wok"), ticket(c, "told", "sushi")
    assert ticket(c, "told", "bar") is None
    assert wok.text[0] == "*** ALLERGY *** WOK"
    assert below(wok.text, "ALLERGY".center(24), 2) == ["Seat 2: Peanuts", "For the dishes you already have:"]
    assert len(wok.images) == 1 and len(sushi.images) == 1  # each one's dish again, as on its first ticket
    assert "    ** ALLERGY: Peanuts **" in sushi.text and "    ** ALLERGY: Peanuts **" not in wok.text
    assert not [t for t in wok.text + sushi.text if t.startswith(("Ticket ", "Also at"))]  # nothing new is cooking
    # the beer goes later: its ticket carries the allergy like any ticket, and nobody is told twice
    post(c, payload("fire2", "fire", 20, course="*"))
    bar = ticket(c, "fire2", "bar")
    assert bar.text[0] == "BAR" and "Seat 2: Peanuts" in bar.text and ticket(c, "fire2", "wok") is None


def test_a_change_and_a_removal_are_told_and_the_same_word_again_is_not():
    c = kitchen("wok")
    post(
        c,
        payload("open", "create", 0, table="12", order_type="dine_in"),
        dish("L1", 1, CHICKEN),
        payload("told", "allergy", 2, allergens=["peanut"]),
        payload("fire", "fire", 3, course="*"),
    )
    assert "Table: Peanuts" in ticket(c, "fire", "wok").text
    post(c, payload("again", "allergy", 10, allergens=["peanut"], by="Ben"))  # the same, typed by someone else
    assert ticket(c, "again", "wok") is None
    post(c, payload("more", "allergy", 11, allergens=["peanut", "celery-x"]))
    assert "Table: Peanuts, celery-x" in ticket(c, "more", "wok").text  # a code the menu does not name, as it is
    post(c, payload("off", "allergy", 12))
    cleared = ticket(c, "off", "wok")
    assert cleared.text[0] == "*** ALLERGY *** WOK" and "NO ALLERGY NOW" in cleared.inverted
    assert "The allergy told before was taken off." in cleared.text and "ALLERGY" not in cleared.inverted


def test_an_allergy_and_a_fire_together_tell_the_old_dishes_and_head_the_new_ticket():
    c = kitchen("wok", "sushi")
    post(
        c,
        payload("open", "create", 0, table="12", order_type="dine_in"),
        dish("L1", 1, CHICKEN),
        payload("fire", "fire", 2, course="*"),
    )
    post(c, dish("L2", 10, ROLL), payload("told", "allergy", 11, allergens=["sesame"]), payload("fire2", "fire", 12))
    new = ticket(c, "fire2", "sushi")
    assert new.text[0] == "SUSHI BAR" and "Table: Sesame" in new.text
    assert ticket(c, "told", "sushi") is None  # its ticket says it already
    assert ticket(c, "told", "wok").text[0] == "*** ALLERGY *** WOK" and ticket(c, "fire2", "wok") is None


def test_a_to_go_order_s_allergy_reaches_the_counter_that_packs_it():
    c = kitchen("wok", "takeout")
    post(
        c,
        payload("open", "create", 0, order_type="takeout", channel="phone", customer_name="Linda"),
        dish("L1", 1, CHICKEN),
        payload("fire", "fire", 2, course="*"),
    )
    post(c, payload("told", "allergy", 3, allergens=["peanut"], note="severe"))
    for printer in ("wok", "takeout"):
        assert "Order: Peanuts - severe" in ticket(c, "told", printer).text
    # told with the send itself, the tickets say it and no second one follows
    post(
        c,
        payload("open2", "create", 10, order_type="takeout", channel="phone", customer_name="Sam"),
        dish("M1", 11, CHICKEN),
        payload("fire2", "fire", 12, course="*"),
        payload("told2", "allergy", 13, allergens=["sesame"]),
        order_id="o2",
    )
    assert "Order: Sesame" in ticket(c, "fire2", "takeout").text and ticket(c, "told2", "takeout") is None


def test_a_dish_voided_since_is_not_listed_and_with_none_left_nobody_is_told():
    c = kitchen("wok", "sushi", settings=servers_void())
    post(
        c,
        payload("open", "create", 0, table="12", order_type="dine_in"),
        dish("L1", 1, CHICKEN),
        dish("L2", 2, ROLL),
        payload("fire", "fire", 3, course="*"),
    )
    post(c, payload("void", "void_line", 4, line_id="L2", reason="kitchen-error"))
    post(c, payload("told", "allergy", 5, allergens=["peanut"]))
    assert ticket(c, "told", "wok") is not None and ticket(c, "told", "sushi") is None
    assert "ALLERGY" not in ticket(c, "void", "sushi").inverted  # it was told after the void went out
    post(c, payload("void2", "void_line", 6, line_id="L1", reason="kitchen-error"))
    assert "Table: Peanuts" in ticket(c, "void2", "wok").text  # a void ticket carries it like any other
    post(c, payload("told2", "allergy", 7, allergens=["sesame"]))
    assert ticket(c, "told2", "wok") is None  # nothing of this table is at the kitchen any more
