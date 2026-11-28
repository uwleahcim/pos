"""Which order on the POS a delivery in Shipday is (`pos.shipday.match`): by GloriaFood's number where
Shipday carries it, by the customer's phone number otherwise, and by nothing rather than by a guess."""

from __future__ import annotations

from pos.shipday.match import BY_NUMBER, BY_PHONE, OnPos, matched, on_pos
from pos.shipday.read import order_of
from pos.sync.oplog import OrderState

from .fake import ELM, OAK, order


def shipday(ident: int, number: str, **more) -> dict:
    read = order_of(order(ident, number, **more))
    assert read is not None
    return read


def delivery(order_id: str, phone: str = "7815550101", address: str = ELM, **more) -> OnPos:
    return OnPos(order_id, phone=phone, address=address, **more)


def told(found: dict) -> dict[int, tuple[str, str]]:
    return {ident: (pos.order_id, how) for ident, (pos, how) in found.items()}


def test_an_order_gloriafood_gave_both_is_matched_by_its_number():
    website = delivery("gf-1270166229", online_id="1270166229", phone="7815559999")
    for number in ("1270166229", "#1270166229", " 1270166229 ", "GF-1270166229", "Order 1270166229 (web)"):
        assert told(matched([shipday(1, number)], [website])) == {1: ("gf-1270166229", BY_NUMBER)}, number
    # a longer number that only has it inside is another number
    assert matched([shipday(1, "91270166229", phone="+1 617 555 0000")], [website]) == {}


def test_a_short_number_is_only_matched_when_it_is_the_whole_number():
    short = delivery("gf-12", online_id="12", phone="7815559999")
    assert told(matched([shipday(1, "12", phone="")], [short])) == {1: ("gf-12", BY_NUMBER)}
    assert matched([shipday(1, "Order 12", phone="")], [short]) == {}


def test_without_the_number_the_customer_s_phone_matches_however_it_is_written():
    phoned = delivery("o-7")
    for phone in ("+17815550101", "(781) 555-0101", "781.555.0101", "1 781 555 0101"):
        assert told(matched([shipday(1, "A-55", phone=phone)], [phoned])) == {1: ("o-7", BY_PHONE)}, phone
    assert matched([shipday(1, "A-55", phone="+17815550199")], [phoned]) == {}
    assert matched([shipday(1, "A-55", phone="")], [delivery("o-8", phone="")]) == {}, "no number matches nobody"


def test_a_customer_with_two_deliveries_is_told_apart_by_the_house_number_or_not_at_all():
    home, work = delivery("o-1", address=ELM), delivery("o-2", address=OAK)
    assert told(matched([shipday(1, "A", address="4 Oak Road, Winchester")], [home, work])) == {1: ("o-2", BY_PHONE)}
    assert told(matched([shipday(1, "A", address="12 ELM STREET")], [home, work])) == {1: ("o-1", BY_PHONE)}
    # both to the same door: nothing says which, so neither
    twice = [delivery("o-1"), delivery("o-3")]
    assert matched([shipday(1, "A")], twice) == {}
    assert matched([shipday(1, "A", address="somewhere else")], [home, work]) == {}


def test_each_order_on_the_pos_is_one_delivery_and_the_number_is_looked_at_first():
    website = delivery("gf-1270166229", online_id="1270166229")
    phoned = delivery("o-9")  # the same customer rang up a second order
    found = matched([shipday(2, "A-56"), shipday(1, "1270166229")], [website, phoned])
    assert told(found) == {1: ("gf-1270166229", BY_NUMBER), 2: ("o-9", BY_PHONE)}
    # two of Shipday's for one check: the first has it
    assert told(matched([shipday(1, "A"), shipday(2, "B")], [phoned])) == {1: ("o-9", BY_PHONE)}


def test_a_voided_check_is_the_order_only_when_none_that_stands_has_the_number():
    voided, rung_again = delivery("o-1", status="void"), delivery("o-2")
    assert told(matched([shipday(1, "A")], [voided, rung_again])) == {1: ("o-2", BY_PHONE)}
    found = matched([shipday(1, "A")], [voided])
    assert told(found) == {1: ("o-1", BY_PHONE)}
    assert found[1][0].about(BY_PHONE)["status"] == "void"


def test_only_a_delivery_on_the_pos_is_looked_at():
    fields = {
        "order_type": "takeout",
        "handover": "delivery",
        "customer_name": "Linda Chen",
        "phone": "+1 (781) 555-0101",
        "address": ELM,
        "order_no": 12,
        "stage": "new",
        "online": {"source": "gloriafood", "id": "1270166229", "type": "delivery"},
    }
    read = on_pos(OrderState("gf-1270166229", fields=fields))
    assert read == OnPos("gf-1270166229", 12, "Linda Chen", "7815550101", ELM, "1270166229", "open", "new")
    assert read.about(BY_NUMBER) == {
        "order_id": "gf-1270166229",
        "order_no": 12,
        "status": "open",
        "stage": "new",
        "by": "number",
    }
    assert on_pos(OrderState("o-1", fields={**fields, "handover": "pickup"})) is None
    assert on_pos(OrderState("o-2", fields={**fields, "order_type": "dine_in"})) is None
    phoned = on_pos(OrderState("o-3", fields={"order_type": "takeout", "handover": "delivery"}))
    assert phoned == OnPos("o-3"), "an order with nothing on it yet is still one"
