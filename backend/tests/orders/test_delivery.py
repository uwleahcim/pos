"""An order that is brought to the customer (docs/delivery.md).

It is a to-go order like any other, with how it leaves (`handover` delivery), where it goes (`address`) and
what was said for the driver (`event_note`). Every ticket says DELIVERY, the bill that travels with the bag
says where to and which number to call, nobody is texted to come and get it, and the next time the number
orders the hub hands the address back. The sale and its payments are counted as any to-go order's are."""

from __future__ import annotations

from datetime import datetime

from pos.messaging import LogMessenger
from pos.orders.check import check_for
from pos.printing.bill import bill_for
from pos.printing.service import ticket_for
from pos.printing.ticket import render
from pos.sync.oplog import is_delivery, replay
from pos.tax import massachusetts

from ..conftest import make_op
from ..printing.fake_printer import decode
from ..printing.test_bill import AT, paper
from . import test_customers as customers
from .test_counter import HOUR, NOW, TEA, client, payload, takeout
from .test_day import Hub, at
from .test_history import steps as history_steps

ELM = "12 Elm St, Winchester"
BELL = "Ring twice, side door"


def to_go(*more, **fields):
    """A phone order with a pot of tea on it, replayed."""
    said = {"order_type": "takeout", "channel": "phone", "order_no": 7, "customer_name": "Linda", **fields}
    ops = [
        make_op("create", at=0, **said),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        make_op("fire", at=2, course="*"),
        *more,
    ]
    return replay(ops, "o1")


# What a delivery is ---------------------------------------------------------------------------------------------


def test_an_order_is_a_delivery_by_how_it_leaves_and_a_table_never_is():
    assert is_delivery({"order_type": "takeout", "handover": "delivery", "address": ELM})
    assert is_delivery({"order_type": "takeout", "handover": "delivery"})  # the address may still be to come
    assert not is_delivery({"order_type": "takeout", "handover": "pickup", "address": ELM})
    assert not is_delivery({"order_type": "takeout", "address": ELM})  # nothing said: it is picked up
    assert not is_delivery({"order_type": "dine_in", "table": "12", "handover": "delivery"})
    assert not is_delivery({"table": "12", "handover": "delivery"})
    assert not is_delivery({})


# The papers -----------------------------------------------------------------------------------------------------


def test_the_bill_says_where_it_goes_and_which_number_to_call():
    state = to_go(handover="delivery", address=f"  {ELM}  ", phone="781 555 0101", event_note=BELL)
    lines = paper(bill_for(check_for(state, massachusetts()), state.fields, at=AT))
    top = lines[: lines.index(next(line for line in lines if line.startswith("1  Tea")))]
    at = top.index("DELIVERY")
    assert top[at + 1 : at + 4] == [ELM, "Phone 781 555 0101", BELL]
    assert any(line.startswith("Order #7  Linda") for line in top[:at])  # under whose order it is
    # and the money is as on any bill
    assert any(line.startswith("TOTAL") and line.endswith("$10.71") for line in lines)


def test_the_bill_of_a_delivery_says_only_what_it_was_told():
    bare = to_go(handover="delivery", address=ELM)
    lines = paper(bill_for(check_for(bare, massachusetts()), bare.fields, at=AT))
    at = lines.index("DELIVERY")
    assert lines[at + 1] == ELM
    assert set(lines[at + 2]) == {"-"}  # the rule: no line for a number or a note nobody gave
    nowhere = to_go(handover="delivery")
    lines = paper(bill_for(check_for(nowhere, massachusetts()), nowhere.fields, at=AT))
    assert lines[lines.index("DELIVERY") + 1] == "No address was given"  # said, so the driver asks


def test_an_order_that_is_picked_up_and_a_table_print_as_they_did():
    for fields in (
        {},
        {"handover": "pickup", "address": ELM, "phone": "781 555 0101"},
        {"order_type": "dine_in", "table": "12", "handover": "delivery", "address": ELM},
    ):
        state = to_go(**fields)
        lines = paper(bill_for(check_for(state, massachusetts()), state.fields, at=AT))
        assert "DELIVERY" not in lines and ELM not in lines, fields
        ticket = ticket_for(state, list(state.lines.values()), station="kitchen", ticket_no=3)
        text = [line.strip() for line in decode(render(ticket)).text]
        assert not any("DELIVERY" in line.upper() for line in text), fields


def test_every_station_s_ticket_says_delivery_and_none_says_where_to():
    state = to_go(handover="delivery", address=ELM, phone="781 555 0101", event_note=BELL)
    ticket = ticket_for(state, list(state.lines.values()), station="kitchen", ticket_no=3)
    assert ticket is not None and ticket.order_type == "delivery"
    text = [line.strip() for line in decode(render(ticket)).text]
    assert any(line.startswith("#3  delivery") for line in text)
    assert "Phone  DELIVERY" in text
    assert "#7  LINDA" in text  # still called by its number and name at the shelf
    # a cook has no use for the address or the number: they are on the bill, which goes with the bag
    assert not any(ELM in line or "781" in line or BELL in line for line in text)


# The customer -------------------------------------------------------------------------------------------------


def test_nobody_is_texted_to_come_for_an_order_that_is_brought_to_them():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    takeout(c, "o1", 0, channel="phone", phone="+16175551234", handover="delivery", address=ELM)
    answer = c.post("/orders/o1/ops", json=[payload("r1", "set_field", 2, stage="ready")]).json()
    assert answer["refused"] == [] and answer.get("texts", []) == [] and messenger.sent == []
    assert c.get("/orders/o1").json()["fields"]["stage"] == "ready"  # it is ready all the same
    # the same customer coming for the next one is told, as before
    takeout(c, "o2", 10, channel="phone", phone="+16175551234", handover="pickup")
    c.post("/orders/o2/ops", json=[payload("r2", "set_field", 12, "o2", stage="ready")])
    assert [m.order_id for m in messenger.sent] == ["o2"] and "ready for pickup" in messenger.sent[0].body
    # an order changed to a delivery before it is ready gets none either
    takeout(c, "o3", 20, channel="phone", phone="+16175551234")
    c.post("/orders/o3/ops", json=[payload("h3", "set_field", 21, "o3", handover="delivery", address=ELM)])
    c.post("/orders/o3/ops", json=[payload("r3", "set_field", 22, "o3", stage="ready")])
    assert [m.order_id for m in messenger.sent] == ["o2"]


def test_a_delivery_pushed_back_is_told_when_it_comes_and_one_just_made_a_delivery_is_told_nothing():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    soon, later = NOW + HOUR, NOW + 2 * HOUR
    takeout(c, "o1", 0, channel="phone", phone="+16175551234", handover="delivery", address=ELM, promised_at=soon)
    answer = c.post("/orders/o1/ops", json=[payload("d1", "set_field", 2, promised_at=later)]).json()
    assert [m["kind"] for m in answer["texts"]] == ["delayed"]
    at = f"{datetime.fromtimestamp(later / 1000):%H:%M}"
    assert (
        messenger.sent[-1].body
        == f"Hi Linda, order #1 from China Sky will be with you around {at}. Sorry for the wait."
    )
    # in their language
    takeout(c, "o2", 10, channel="phone", phone="+16175551234", locale="zh", handover="delivery", promised_at=soon)
    c.post("/orders/o2/ops", json=[payload("d2", "set_field", 12, "o2", promised_at=later)])
    assert messenger.sent[-1].body == f"Linda您好，China Sky的订单 #2 预计{at}送到，请见谅。"
    # an order for the counter that is now to be brought: it takes longer because they asked, so no "sorry"
    takeout(c, "o3", 20, channel="phone", phone="+16175551234", promised_at=soon)
    change = payload("h3", "set_field", 21, "o3", handover="delivery", address=ELM, promised_at=later)
    assert c.post("/orders/o3/ops", json=[change]).json().get("texts", []) == []
    assert len(messenger.sent) == 2


def test_the_address_of_their_latest_delivery_comes_back_with_the_customer():
    c = customers.client()
    day = customers.DAY
    customers.order(c, "o1", 0, customers.ROLL, handover="delivery", address="4 Oak Rd, Woburn", event_note="Blue door")
    customers.order(c, "o2", 10 * day, customers.ROLL, handover="delivery", address=f" {ELM} ", event_note=BELL)
    customers.order(c, "o3", 20 * day, customers.ROLL)  # picked up since: the address is still theirs
    customers.order(c, "o4", 30 * day, customers.ROLL, handover="pickup", address="1 Wrong Way")
    customers.order(c, "x1", 25 * day, customers.ROLL, phone="781 555 0199", name="Sam")
    linda = customers.card(c, customers.LINDA)
    assert (linda["address"], linda["address_note"]) == (ELM, BELL)
    assert linda["orders"] == 4 and [past["order_id"] for past in linda["recent"]] == ["o4", "o3", "o2", "o1"]
    sam = customers.card(c, "781 555 0199")
    assert (sam["address"], sam["address_note"]) == ("", "")  # nothing was ever brought to them
    nobody = customers.card(c, "781 555 0123")
    assert nobody["known"] is False and (nobody["address"], nobody["address_note"]) == ("", "")


def test_a_catering_delivery_hands_its_address_back_and_not_the_note_about_its_event():
    c = customers.client()
    customers.order(c, "o1", 0, customers.ROLL, handover="delivery", address=ELM, event_note=BELL)
    customers.order(
        c,
        "o2",
        5 * customers.DAY,
        customers.ROLL,
        channel="catering",
        handover="delivery",
        address="1 Town Hall Sq",
        event_note="Set up by 11:30",
        event_guests=30,
    )
    linda = customers.card(c, customers.LINDA)
    assert (linda["address"], linda["address_note"]) == ("1 Town Hall Sq", "")


def test_a_delivery_with_no_address_hands_none_back_and_a_voided_one_is_not_read():
    c = customers.client()
    day = customers.DAY
    customers.order(c, "o1", 0, customers.ROLL, handover="delivery", address=ELM, event_note=BELL)
    customers.order(c, "o2", 5 * day, customers.ROLL, handover="delivery", event_note="No address typed")
    customers.order(c, "o3", 9 * day, customers.ROLL, handover="delivery", address="9 Void Ln")
    c.post("/orders/o3/ops", json=[customers.payload("o3", "void", "void_order", 9 * day + 10)])
    linda = customers.card(c, customers.LINDA)
    assert (linda["address"], linda["address_note"]) == (ELM, BELL)


# The history ----------------------------------------------------------------------------------------------------


def test_the_history_says_it_was_delivered_and_whose_the_note_is():
    h = Hub(now=at(17))
    h.to_go("o1", at(17), name="Linda", phone="781 555 0101", handover="delivery", address=ELM, event_note=BELL)
    h.op("o1", "set_field", at(17, 5), event_note="Back door", by="Amy", by_id="s1")
    h.op("o1", "set_field", at(17, 40), stage="ready")
    h.op("o1", "set_field", at(17, 55), stage="picked_up")
    h.to_go("o2", at(18), name="Sam", phone="781 555 0199")
    h.op("o2", "set_field", at(18, 20), stage="ready")
    told = history_steps(h)
    assert (told[0]["fields"]["handover"], told[0]["fields"]["address"], told[0]["fields"]["event_note"]) == (
        "delivery",
        ELM,
        BELL,
    )
    assert [(s["what"], s.get("now"), s.get("delivery"), s.get("catering")) for s in told[1:]] == [
        ("field", "Back door", None, False),  # the driver's note, not an event's
        ("stage", "ready", True, None),
        ("stage", "picked_up", True, None),  # which a screen reads as delivered
    ]
    # an order the customer comes for says nothing of a delivery
    assert [s.get("delivery") for s in history_steps(h, "o2") if s["what"] == "stage"] == [None]


# The money ------------------------------------------------------------------------------------------------------


def test_a_delivery_is_a_sale_like_any_to_go_order():
    c = client()
    takeout(c, "o1", 0, channel="phone", handover="delivery", address=ELM)
    takeout(c, "o2", 10, channel="phone")
    one, two = (c.get(f"/orders/{order}/check").json() for order in ("o1", "o2"))
    assert (one["subtotal"], one["tax"], one["total"]) == (two["subtotal"], two["tax"], two["total"])
    # Nothing is added for the trip. The hub's own rules (these tests run under them) know a delivery fee
    # for orders of the type `delivery`; an order brought by the restaurant's driver stays a to-go order, so
    # no fee goes on a customer's check until the owner says what it is.
    assert c.get("/pricing/rules").json()["charges"][1]["code"] == "delivery_fee"
    assert one["charges"] == []
    paid = payload("p1", "pay", 20, payment_id="P1", method="cash", amount=one["total"], tendered="20.00")
    assert c.post("/orders/o1/ops", json=[paid]).json()["refused"] == []
    after = c.get("/orders/o1/check").json()
    assert (after["paid"], after["due"]) == (one["total"], "0.00")
