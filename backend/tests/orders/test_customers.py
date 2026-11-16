"""A customer per phone number (the Toast comparison, 2026-11-15): who is calling is read from the orders the
number placed, however old; one note line is kept about them; and a past order can be had again, at today's
menu."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.customers import NOTE_MAX, CustomerNotes, _why, clean_note
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import PrintService
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts

from ..conftest import T0
from .test_menu_orders import DINNER, GTC_QUART

DAY = 24 * 60 * 60_000
NOW = T0 + 60 * DAY  # the hub's clock: two months after the first stamp, so orders can be weeks apart
ROLL = {"variant_id": "CALROLL:roll"}
LINDA = "781 555 0101"


def payload(order_id: str, op_id: str, kind: str, at: int, **data):
    return {
        "op_id": f"{order_id}-{op_id}",
        "order_id": order_id,
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def client(notes: CustomerNotes | None = None) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: NOW),
            menu=MenuService(load_definitions("restaurant"), now=lambda: DINNER),
            taxes=massachusetts(),
            printing=PrintService([]),
            customers=notes,
        )
    )


def order(c: TestClient, order_id: str, at: int, *dishes: dict, phone: str = LINDA, name: str = "Linda", **fields):
    """A to-go order opened `at` ms after T0 with these dishes (each a menu request), one of each."""
    ops = [
        payload(order_id, "open", "create", at, order_type="takeout", channel="phone", phone=phone, customer_name=name)
    ]
    ops[0]["data"].update(fields)
    for i, request in enumerate(dishes, start=1):
        ops.append(payload(order_id, f"L{i}", "add_line", at + i, line_id=f"L{i}", item="?", request=request))
    sent = c.post(f"/orders/{order_id}/ops", json=ops)
    assert sent.status_code == 202 and sent.json()["refused"] == []


def card(c: TestClient, phone: str) -> dict:
    answer = c.get("/customers/lookup", params={"phone": phone})
    assert answer.status_code == 200
    return answer.json()


def test_a_customer_is_read_from_the_orders_their_number_placed():
    c = client()
    order(c, "o1", 0, GTC_QUART, name="Linda")
    order(c, "o2", 20 * DAY, ROLL, ROLL, phone="+1 (781) 555-0101", name="Linda Chen")
    order(c, "o3", 40 * DAY, phone="7815550101", name="")  # opened and left: nothing on it
    order(c, "o4", 41 * DAY, GTC_QUART, phone="781-555-0101", name="Wrong")
    c.post("/orders/o4/ops", json=[payload("o4", "void", "void_order", 41 * DAY + 10)])
    order(c, "x1", 30 * DAY, ROLL, phone="781 555 0199", name="Sam")  # somebody else

    linda = card(c, "(781) 555-0101")
    assert linda["known"] and linda["phone"] == "7815550101"
    assert linda["name"] == "Linda Chen"  # the name on the latest order that has one
    assert linda["orders"] == 3  # the voided one does not count
    assert (linda["first_ms"], linda["last_ms"]) == (T0, T0 + 40 * DAY)
    assert [past["order_id"] for past in linda["recent"]] == ["o2", "o1"]  # newest first, only ones with dishes
    latest, first = linda["recent"]
    assert latest["opened_ms"] == T0 + 20 * DAY and latest["channel"] == "phone"
    assert latest["order_no"] == c.get("/orders/o2").json()["fields"]["order_no"]  # the number the hub gave it
    assert [(i["qty"], i["item"]) for i in latest["items"]] == [(1, "California roll"), (1, "California roll")]
    check = c.get("/orders/o1/check").json()
    assert first["total"] == check["total"] and float(first["total"]) > 0  # what it came to, tax and all
    assert first["items"] == [{"qty": 1, "item": check["lines"][0]["name"]}]

    assert card(c, "781 555 0199")["name"] == "Sam"


def test_a_number_that_never_ordered_is_not_a_customer_and_neither_is_a_short_one():
    c = client()
    order(c, "o1", 0, ROLL, phone="12")  # an extension typed as the number
    for phone in ("781 555 0123", "12", "Unknown"):
        nobody = card(c, phone)
        assert nobody["known"] is False and nobody["orders"] == 0 and nobody["recent"] == [] and nobody["name"] == ""
    assert c.get("/customers/lookup").status_code == 422  # a number is asked for


def test_only_the_latest_five_orders_are_listed_and_all_of_them_counted():
    c = client()
    for n in range(8):
        order(c, f"o{n}", n * DAY, ROLL)
    regular = card(c, LINDA)
    assert regular["orders"] == 8
    assert [past["order_id"] for past in regular["recent"]] == ["o7", "o6", "o5", "o4", "o3"]


def test_one_line_is_kept_about_a_customer():
    c = client()
    order(c, "o1", 0, ROLL)
    assert card(c, LINDA)["note"] == ""
    saved = c.put("/customers/+1 781 555 0101", json={"note": "  no MSG,\n side  door ", "by": "Amy"})
    assert saved.status_code == 200 and saved.json() == {"phone": "7815550101", "note": "no MSG, side door", "max": 120}
    assert card(c, "781.555.0101")["note"] == "no MSG, side door"
    # a note alone makes the number known: it can be written before the first order
    c.put("/customers/7815550155", json={"note": "calls ahead for 12"})
    ahead = card(c, "781 555 0155")
    assert ahead["known"] and ahead["orders"] == 0 and ahead["note"] == "calls ahead for 12"
    # an empty one takes it off
    c.put("/customers/7815550155", json={"note": " "})
    assert card(c, "781 555 0155")["known"] is False
    assert c.put("/customers/12", json={"note": "x"}).status_code == 422
    assert clean_note("x" * 300) == "x" * NOTE_MAX and clean_note(None) == ""


def test_the_note_records_who_wrote_it_and_when():
    notes = CustomerNotes()
    c = client(notes)
    c.put("/customers/7815550101", json={"note": "side door", "by": "Amy"})
    assert notes.get("7815550101") == {"note": "side door", "by": "Amy", "at_ms": NOW}
    assert notes.get("7815550102") is None
    # every note at once, for a list of the customers: a note taken off is none
    c.put("/customers/7815550102", json={"note": "allergic to peanuts", "by": "Ben"})
    c.put("/customers/7815550103", json={"note": "", "by": "Ben"})
    assert notes.all() == {"7815550101": "side door", "7815550102": "allergic to peanuts"}


def test_same_again_is_the_order_s_dishes_as_the_menu_sells_them_now():
    c = client()
    order(c, "o1", 0, GTC_QUART, ROLL, ROLL)
    c.post(
        "/orders/o1/ops",
        json=[
            payload("o1", "more", "set_line", 10, line_id="L1", qty=2, note="extra crispy"),
            payload("o1", "typed", "add_line", 11, line_id="T1", item="Birthday candle", qty=1),
            payload("o1", "off", "void_line", 12, line_id="L3", reason="changed"),
        ],
    )
    again = c.get("/orders/o1/again").json()
    assert again["order_id"] == "o1"
    chicken, roll = again["lines"]
    assert chicken["request"] == GTC_QUART and chicken["qty"] == 2 and chicken["note"] == "extra crispy"
    assert chicken["item"].startswith("General Tso") and chicken["unit_price"] == chicken["was"]
    assert roll["request"] == ROLL and roll["qty"] == 1  # the one taken off is not had again
    assert [(m["item"], m["qty"]) for m in again["missing"]] == [("Birthday candle", 1)]
    assert again["missing"][0]["why"] == "It was typed in, not picked from the menu."

    # every line goes onto a new order as it stands
    ops = [payload("o2", "open", "create", DAY, order_type="takeout", channel="phone", phone=LINDA)]
    for n, line in enumerate(again["lines"]):
        ops.append(payload("o2", f"A{n}", "add_line", DAY + 1 + n, line_id=f"A{n}", item=line["item"], qty=line["qty"]))
        ops[-1]["data"].update(request=line["request"], note=line["note"])
    assert c.post("/orders/o2/ops", json=ops).json()["refused"] == []
    old, new = c.get("/orders/o1/check").json(), c.get("/orders/o2/check").json()
    assert new["subtotal"] == old["subtotal"]


def test_a_dish_the_kitchen_is_out_of_today_is_named_and_not_added():
    c = client()
    order(c, "o1", 0, GTC_QUART, ROLL)
    assert c.post("/menu/86", json={"target_id": "CALROLL:roll", "status": "sold_out", "by": "Mike"}).status_code == 200
    again = c.get("/orders/o1/again").json()
    assert [line["request"] for line in again["lines"]] == [GTC_QUART]
    (gone,) = again["missing"]
    assert gone == {"item": "California roll", "qty": 1, "why": "It is sold out today."}  # words, not ids
    assert c.get("/orders/nope/again").status_code == 404


def test_why_a_past_dish_is_not_sold_is_said_in_plain_words():
    assert _why([{"code": "sold_out", "message": "GTC:qt-WHITE is sold out", "option_id": "GTC:qt-WHITE"}]) == (
        "One of its choices is sold out today."
    )
    assert _why([{"code": "sold_out", "message": "CALROLL:roll is hidden"}]) == "It is off the menu today."
    assert _why([{"code": "unknown_variant", "message": "no variant OLD:1"}]) == "It is no longer on the menu."
    assert _why([{"code": "option_hidden", "message": "x"}]) == "One of its choices is no longer offered."
    assert _why([{"code": "too_few", "message": "RICE needs a choice"}]) == "Its choices have changed since."
    assert _why([]) == "The menu does not sell it this way now."


DSN = os.environ.get("POS_TEST_DATABASE_URL")


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_notes_are_kept_in_postgresql_the_same_way():
    import psycopg

    from pos.customers import PgCustomerNotes

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS customer_note")
    notes = PgCustomerNotes(DSN)
    try:
        assert notes.get("7815550101") is None
        notes.put("7815550101", "side door", by="Amy", at_ms=NOW)
        notes.put("7815550101", "no MSG", by="Ben", at_ms=NOW + 5)  # the latest word stands
        assert notes.get("7815550101") == {"note": "no MSG", "by": "Ben", "at_ms": NOW + 5}
        notes.put("7815550102", "", by="Ben", at_ms=NOW + 6)  # a note taken off
        assert notes.all() == {"7815550101": "no MSG"}
    finally:
        notes.close()
    again = PgCustomerNotes(DSN)  # after a restart
    try:
        assert again.get("7815550101")["note"] == "no MSG"
    finally:
        again.close()
