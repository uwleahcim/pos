"""A walk-in's number at the table (docs/guest-list.md, "A walk-in's number").

A guest with no reservation leaves a phone number at the table: whoever serves them types it on the table's
check, as a number is typed on a to-go order. The check is then that guest's visit in the guest list, its
money counts for them, and where the owner set a rate they earn points on it. It is the check's own number
(`set_field {phone, customer_name}`), so every hub and the cloud have it and a terminal with no hub keeps
it; the hub was counting a number on a check all along, and what is new here is what it must NOT do with
one at a table: open the check for a caller, or send it a text. Nothing else moves by it: no sale, no
bill, no kitchen ticket."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

import pytest

from pos.messaging import LogMessenger
from pos.orders.callers import last_order
from pos.orders.check import check_for
from pos.printing.bill import bill_for
from pos.printing.service import ticket_for
from pos.printing.ticket import render
from pos.reservations import Reservations
from pos.tax import massachusetts
from pos.waitlist import Waitlist

from ..printing.fake_printer import decode
from ..printing.test_bill import paper
from .test_check_guests import NOVAK, check, latest, tally, type_number
from .test_counter import HOUR, client, payload, takeout
from .test_day import DSN, EGGROLL, WINGS, Hub, at
from .test_guest_tags import book_table, host_stand, seat
from .test_guests import GTC, LINDA, guests, one
from .test_history import steps
from .test_points import close, has, looked_up, save
from .test_who_pays import said, who_sits

WALKER = "7815550142"
"""A number that never ordered: a guest who walked in."""


def take_off(h: Hub, order_id: str) -> None:
    """The number is taken off the check again, as the screen does it."""
    h.now += 1_000
    h.op(order_id, "set_field", h.now, phone=None, customer_name=None)


# --- the guest list ---------------------------------------------------------------------------------------------


def test_a_number_typed_on_a_tables_check_makes_the_walk_in_a_guest_who_pays_it():
    h = host_stand()
    was = guests(h)["totals"]
    net = check(h, "w-1", "B4", GTC, EGGROLL)
    assert tally(h, WALKER) is None  # a walk-in with no number is no guest of the list
    type_number(h, "w-1", "781 555 0142", "Dana")
    assert tally(h, WALKER) == (1, 1, net)
    row = one(h, WALKER)
    assert row["guest"]["name"] == "Dana" and row["latest"][0]["table"] == "B4"
    assert latest(h, WALKER) == {"order_id": "w-1", "net": net, "paid": True}
    now = guests(h)["totals"]
    assert now["guests"] == was["guests"] + 1 and Decimal(now["spent"]) == Decimal(was["spent"]) + net


def test_the_number_can_be_changed_and_taken_off_again():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    net = check(h, "w-1", "B4", GTC)
    type_number(h, "w-1", WALKER, "Dana")
    assert tally(h, WALKER) == (1, 1, net)
    # the wrong number: it was Linda's table
    type_number(h, "w-1", LINDA, "Linda")
    assert tally(h, WALKER) is None and tally(h, LINDA) == (visits + 1, paid + 1, spent + net)
    take_off(h, "w-1")
    assert tally(h, WALKER) is None and tally(h, LINDA) == (visits, paid, spent)
    assert h.c.get("/orders/w-1").json()["fields"].get("phone") is None


def test_a_number_too_short_to_be_one_is_no_guest():
    h = host_stand()
    was = guests(h)["totals"]
    check(h, "w-1", "B4", GTC)
    type_number(h, "w-1", "55501", "Dana")
    assert guests(h)["totals"] == was


def test_at_a_table_with_a_seated_party_the_number_typed_pays_unless_a_tap_says_otherwise():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    net = check(h, "w-1", "A7", GTC, EGGROLL)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "w-1", table="A7")
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + net)  # her table, and nobody else's
    # a friend who walked in with her pays, and leaves a number
    type_number(h, "w-1", WALKER, "Dana")
    assert tally(h, WALKER) == (1, 1, net) and tally(h, LINDA) == (visits + 1, paid, spent)
    # no number is told to the screen, and Linda is not said to pay
    sits = who_sits(h, "w-1")
    assert [(party["name"], party["pays"]) for party in sits["parties"]] == [("Linda P.", False)]
    assert WALKER not in str(sits) and LINDA not in str(sits)
    # a tap on her name says she pays after all: the word wins over the number
    said(h, "w-1", sits["parties"][0]["key"])
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + net) and tally(h, WALKER) == (1, 0, Decimal(0))


# --- points -----------------------------------------------------------------------------------------------------


def test_the_walk_in_earns_points_once_the_check_is_closed():
    h = host_stand()
    save(h, per_dollar="1")
    net = check(h, "w-1", "B4", GTC, EGGROLL)
    type_number(h, "w-1", WALKER, "Dana")
    assert has(h, WALKER) == 0 and looked_up(h, WALKER)["points"] == 0  # still being rung
    close(h, "w-1")
    assert has(h, WALKER) == int(net) and looked_up(h, WALKER)["points"] == int(net)
    # what the next table's server is told when the number is typed there: who it is, and what they have
    card = looked_up(h, "(781) 555-0142")
    assert (card["known"], card["name"], card["orders"]) == (True, "Dana", 1)


def test_a_number_typed_after_the_check_was_closed_earns_too_and_taken_off_earns_nothing():
    h = host_stand()
    save(h, per_dollar="2")
    net = check(h, "w-1", "B4", WINGS)
    close(h, "w-1")
    type_number(h, "w-1", WALKER, "Dana")
    assert has(h, WALKER) == int(net * 2)
    take_off(h, "w-1")
    assert tally(h, WALKER) is None and looked_up(h, WALKER)["points"] == 0


def test_a_bar_tab_takes_a_number_and_keeps_its_name():
    h = host_stand()
    save(h, per_dollar="1")
    h.op("tab-1", "create", h.now - 60_000, order_type="dine_in", tab=True, customer_name="Dana")
    h.ring("tab-1", "L1", WINGS, h.now - 50_000)
    net = Decimal(h.check("tab-1")["subtotal"])
    h.now += 1_000
    h.op("tab-1", "set_field", h.now, phone=WALKER)  # the number alone: the tab has its name
    close(h, "tab-1")
    assert tally(h, WALKER) == (1, 1, net) and has(h, WALKER) == int(net)
    assert one(h, WALKER)["guest"]["name"] == "Dana"


def test_a_tabs_name_names_a_guest_only_for_want_of_another():
    h = host_stand()
    h.op("tab-1", "create", h.now - 60_000, order_type="dine_in", tab=True, customer_name="Blue jacket", phone=WALKER)
    h.ring("tab-1", "L1", WINGS, h.now - 50_000)
    # all the hub knows them by is what the bar called the tab
    assert one(h, WALKER)["guest"]["name"] == "Blue jacket" and looked_up(h, WALKER)["name"] == "Blue jacket"
    # an order under their own name, older than the tab: the tab does not rename them
    h.op(
        "o-1", "create", h.now - 3 * HOUR, order_type="takeout", channel="phone", phone=WALKER, customer_name="Dana R."
    )
    h.ring("o-1", "L1", EGGROLL, h.now - 3 * HOUR + 1_000)
    assert one(h, WALKER)["guest"]["name"] == "Dana R." and looked_up(h, WALKER)["name"] == "Dana R."
    assert looked_up(h, WALKER)["orders"] == 2


# --- what a number at a table must not do --------------------------------------------------------------------


def test_a_call_from_a_number_left_at_a_table_opens_no_check():
    c = client()

    def last(phone: str) -> str | None:
        order = c.get("/orders/last", params={"phone": phone}).json()["order"]
        return None if order is None else order["order_id"]

    table = [
        payload("t1-a", "create", -2 * HOUR, "t1", table="B4", guests=2, order_type="dine_in"),
        payload("t1-b", "set_field", -2 * HOUR + 5, "t1", phone="781 555 0142", customer_name="Dana"),
    ]
    assert c.post("/orders/t1/ops", json=table).json()["refused"] == []
    tab = [payload("b1-a", "create", -HOUR, "b1", order_type="dine_in", tab=True, customer_name="Dana", phone=WALKER)]
    assert c.post("/orders/b1/ops", json=tab).json()["refused"] == []
    # they ate in at noon and ring in the evening: a new order, not their table's check or their tab
    assert last("+17815550142") is None
    assert last_order(c.app.state.store, WALKER, day=c.app.state.today()) is None
    # an order they phone in is theirs as before, whatever was opened at a table since
    takeout(c, "o1", -30 * 60_000, channel="phone", phone="781-555-0142")
    more = [
        payload("t2-a", "create", -10 * 60_000, "t2", table="B5", guests=2, order_type="dine_in", phone=WALKER),
    ]
    assert c.post("/orders/t2/ops", json=more).json()["refused"] == []
    assert last("7815550142") == "o1"


def test_a_number_left_at_a_table_is_never_sent_a_text():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    table = [
        payload("t1-a", "create", 0, "t1", table="B4", guests=2, order_type="dine_in"),
        payload("t1-b", "set_field", 1, "t1", phone="+17815550142", customer_name="Dana"),
        payload("t1-c", "add_line", 2, "t1", line_id="L1", item="Tea", qty=1),
        payload("t1-d", "fire", 3, "t1"),
    ]
    assert c.post("/orders/t1/ops", json=table).json()["refused"] == []
    # whatever a screen sets on it afterwards: a stage, a time that moves later
    for n, fields in enumerate(
        ({"stage": "ready"}, {"promised_at": 1_900_000_000_000}, {"promised_at": 1_900_000_600_000}, {"stage": "out"})
    ):
        told = c.post("/orders/t1/ops", json=[payload(f"t1-s{n}", "set_field", 10 + n, "t1", **fields)]).json()
        assert told["refused"] == [] and told["texts"] == []
    assert messenger.sent == []
    # a to-go order is told it is ready, as before
    takeout(c, "o1", 20, channel="phone", phone="+17815550142")
    told = c.post("/orders/o1/ops", json=[payload("o1-r", "set_field", 30, "o1", stage="ready")]).json()
    assert [text["to"] for text in told["texts"]] == ["+17815550142"] and len(messenger.sent) == 1


# --- nothing else moves ------------------------------------------------------------------------------------------


def test_typing_the_number_moves_no_sale_and_prints_on_no_bill_or_ticket():
    h = host_stand()
    check(h, "w-1", "B4", GTC, EGGROLL)
    h.op("w-1", "fire", h.now + 1, course="*")

    def figures() -> dict:
        """The day's report but for when it was read and what the open check is called."""
        read = h.report()
        still_open = [{**row, "customer_name": None} for row in read["open"]]
        return {**read, "now_ms": None, "open": still_open}

    report, money = figures(), h.check("w-1")
    type_number(h, "w-1", "781 555 0142", "Dana Whitfield")
    assert figures() == report and h.check("w-1") == money
    assert h.report()["open"][0]["customer_name"] == "Dana Whitfield"  # the list of open checks names it
    state = h.store.view("w-1")
    bill = paper(bill_for(check_for(state, massachusetts()), state.fields, at=datetime(2026, 11, 16, 21, 5)))
    assert any(line.startswith("Table B4") for line in bill)
    ticket = ticket_for(state, list(state.lines.values()), station="kitchen", ticket_no=3)
    assert ticket is not None and ticket.order_no is None
    for said_on_it in (" ".join(bill), " ".join(decode(render(ticket)).text)):
        assert "DANA" not in said_on_it.upper() and "WHITFIELD" not in said_on_it.upper()
        assert "0142" not in said_on_it


def test_the_checks_history_says_who_typed_the_number():
    h = host_stand()
    check(h, "w-1", "B4", GTC)
    h.now += 1_000
    h.op("w-1", "set_field", h.now, phone="781 555 0142", customer_name="Dana", by="Amy", by_id="s1")
    typed = [(step["field"], step["now"], step["by"]) for step in steps(h, "w-1") if step["what"] == "field"]
    assert sorted(typed) == [("customer_name", "Dana", "Amy"), ("phone", "781 555 0142", "Amy")]


# --- in PostgreSQL ----------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_walk_in_is_a_guest_from_postgres_too():
    import psycopg

    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(21), postgres=DSN)
    try:
        state = h.c.app.state
        state.reservations, state.waitlist = Reservations(now_ms=lambda: h.now), Waitlist(now_ms=lambda: h.now)
        net = check(h, "w-1", "B4", GTC, EGGROLL)
        assert tally(h, WALKER) is None
        type_number(h, "w-1", "781 555 0142", "Dana")
        assert tally(h, WALKER) == (1, 1, net) and tally(h, NOVAK) is None
        # the index knows the number as soon as it is typed, and forgets it when it is taken off
        assert [entry.order_id for entry in h.store.index(phone=WALKER)] == ["w-1"]
        assert h.c.get("/orders/last", params={"phone": WALKER}).json()["order"] is None
        take_off(h, "w-1")
        assert tally(h, WALKER) is None and h.store.index(phone=WALKER) == []
    finally:
        h.store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS ops, orders")
