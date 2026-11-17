"""PAID or NOT PAID on the takeout counter's ticket: orders paid first and orders paid at pickup sit on the
same shelf, and whoever hands a bag over reads on it whether there is money to collect. Only the copy that
goes in the bag says it; the cooks' tickets and a table's tickets never do."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.service import Printer, PrintService, money_words
from pos.printing.ticket import DEMO, Money, render
from pos.settings import clean_tickets
from pos.sync.oplog import OpStore

from ..conftest import T0, servers_void
from ..orders.test_menu_orders import payload
from .fake_printer import Decoded, decode
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen, send
from .test_stations import manager, menu_with_takeout

PHONE = {"order_type": "takeout", "channel": "phone", "customer_name": "Linda"}
HOUR = 60 * 60_000


def ticket(c: TestClient, key: str, printer: str = "takeout") -> Decoded:
    job = c.app.state.printing.store.get(f"{key}:{printer}")
    assert job is not None, f"no ticket at {printer}"
    return decode(job.data)


def money(c: TestClient, key: str, printer: str = "takeout") -> list[str]:
    """What the printer's ticket for that send says about the money, each line without its padding."""
    words = ("PAID", "NOT PAID", "NOTHING TO PAY", "$")
    return [line.strip() for line in ticket(c, key, printer).text if line.strip().startswith(words)]


def due(c: TestClient, order_id: str = "o1") -> Decimal:
    return Decimal(c.get(f"/orders/{order_id}/check").json()["due"])


def pay(c: TestClient, op_id: str, amount: Decimal | str, *, at: int = 500, order_id: str = "o1") -> None:
    op = payload(op_id, "pay", at, payment_id=op_id, method="cash", amount=str(amount))
    assert c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id}]).json()["refused"] == []


def test_an_order_paid_at_pickup_says_not_paid_and_what_to_collect_on_the_bag_only():
    c = kitchen("wok", "sushi", "takeout")
    key = send(c, "o1", CHICKEN, ROLL, **PHONE)
    owed = due(c)
    assert owed > 0
    assert money(c, key) == [f"NOT PAID  ${owed}"]
    bag = ticket(c, key)
    assert f"NOT PAID  ${owed}" in bag.inverted  # white on black: there is money to collect
    # under the name, above the dishes
    lines = [line.strip() for line in bag.text]
    assert lines.index("#1  LINDA") < lines.index(f"NOT PAID  ${owed}") < lines.index("-" * 48)
    # the cooks do not read about money
    assert money(c, key, "wok") == [] and money(c, key, "sushi") == []


def test_an_order_paid_as_it_is_sent_says_paid():
    c = kitchen("wok", "takeout")
    opened = [
        payload("open", "create", 0, **PHONE),
        payload("add", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
    ]
    assert c.post("/orders/o1/ops", json=opened).status_code == 202
    pay_and_send = [
        payload("pay", "pay", 10, payment_id="P1", method="cash", amount=str(due(c)), tendered="100.00"),
        payload("fire", "fire", 11, course="*"),
    ]
    assert c.post("/orders/o1/ops", json=pay_and_send).json()["refused"] == []
    assert money(c, "fire") == ["PAID"]
    assert "PAID" not in ticket(c, "fire").inverted
    assert money(c, "fire", "wok") == []


def test_part_paid_says_both_sums():
    c = kitchen("wok", "takeout")
    opened = [
        payload("open", "create", 0, **PHONE),
        payload("add", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
        payload("pay", "pay", 2, payment_id="P1", method="cash", amount="5.00"),
    ]
    assert c.post("/orders/o1/ops", json=opened).json()["refused"] == []
    total = Decimal(c.get("/orders/o1/check").json()["total"])
    assert c.post("/orders/o1/ops", json=[payload("fire", "fire", 11, course="*")]).status_code == 202
    assert money(c, "fire") == [f"NOT PAID  ${total - 5}", f"$5.00 paid of ${total}"]


def test_a_dish_added_after_paying_prints_what_is_owed_for_it():
    c = kitchen("wok", "bar", "takeout")
    first = send(c, "o1", CHICKEN, **PHONE)
    paid = due(c)
    pay(c, "p1", paid)
    assert due(c) == 0
    later = send(c, "o1", BEER, at=1000)
    owed = due(c)
    assert owed > 0
    assert money(c, first) == [f"NOT PAID  ${paid}"]  # a ticket on paper stays as it printed
    assert money(c, later) == [f"NOT PAID  ${owed}", f"${paid} paid of ${paid + owed}"]


def test_a_dish_voided_after_paying_says_how_much_was_paid_too_much():
    c = kitchen("wok", "bar", "takeout", settings=servers_void())
    send(c, "o1", CHICKEN, BEER, **PHONE)
    paid = due(c)
    pay(c, "p1", paid)
    void = [payload("v1", "void_line", 2000, line_id="L0-2", reason="out-of-stock")]
    assert c.post("/orders/o1/ops", json=void).json()["refused"] == []
    total = Decimal(c.get("/orders/o1/check").json()["total"])
    assert money(c, "v1") == ["PAID", f"${paid - total} more than the check, now ${total}"]


def test_a_tables_order_says_nothing_about_money_even_at_the_counter():
    c = kitchen("wok", "takeout")
    key = send(c, "o1", CHICKEN)  # table 12
    assert c.app.state.printing.store.get(f"{key}:takeout") is None
    assert money(c, key, "wok") == []
    # one printer for the cooks and the bag: the to-go order's whole ticket is the bag's, and says it
    one = kitchen(Printer("wok", "10.0.0.1", id="k", stations=("wok", "takeout")))
    assert money(one, send(one, "o1", CHICKEN, **PHONE), "k") == [f"NOT PAID  ${due(one)}"]
    assert money(one, send(one, "o2", CHICKEN), "k") == []


def test_with_no_printer_at_the_counter_no_ticket_says_it():
    c = kitchen("wok")
    assert money(c, send(c, "o1", CHICKEN, **PHONE), "wok") == []


def test_an_allergy_notice_says_nothing_about_money():
    c = kitchen("wok", "takeout")
    send(c, "o1", CHICKEN, **PHONE)
    told = [payload("told", "allergy", 900, allergy_id="A1", allergens=["peanut"], note="")]
    assert c.post("/orders/o1/ops", json=told).status_code == 202
    assert "*** ALLERGY *** TAKEOUT" in ticket(c, "told").text and money(c, "told") == []


def test_the_copy_on_a_fallback_printer_says_the_same():
    c = kitchen("wok", Printer("takeout", "10.0.0.2", id="takeout", fallbacks=("wok",)))
    key = send(c, "o1", CHICKEN, **PHONE)
    address, copy = c.app.state.printing.store.get(f"{key}:takeout").fallbacks[0]
    assert address == "10.0.0.1" and f"NOT PAID  ${due(c)}" in decode(copy).inverted


def test_a_manager_turns_it_off():
    c = kitchen("wok", "takeout")
    assert c.get("/settings/tickets").json()["paid"] is True
    headers = manager(c)
    saved = c.put("/settings/tickets", json={"paid": False, "moved": True, "pack": True}, headers=headers).json()
    assert saved == {"numbered": True, "also_at": True, "paid": False, "moved": True, "pack": True}
    key = send(c, "o1", CHICKEN, **PHONE)
    assert money(c, key) == [] and "#1  LINDA" in ticket(c, key).text
    # an app from before the switch saves the other two and leaves this one as it is
    saved = c.put("/settings/tickets", json={"numbered": False, "also_at": True}, headers=headers).json()
    assert saved == {"numbered": False, "also_at": True, "paid": False, "moved": True, "pack": True}
    assert clean_tickets({}) == {"numbered": True, "also_at": True, "paid": True, "moved": True, "pack": True}
    with pytest.raises(ValueError, match="paid must be true or false"):
        clean_tickets({"paid": 1})


def future(clock: list[int]) -> TestClient:
    """A hub with a wok and a takeout counter whose clock the test holds."""
    service = PrintService(
        [Printer("wok", "10.0.0.1", id="wok"), Printer("takeout", "10.0.0.2", id="takeout", fallbacks=("wok",))],
        direct=False,
        now=lambda: clock[0],
    )
    return TestClient(create_app(OpStore(physical=lambda: T0 + 100), menu=menu_with_takeout(), printing=service))


def test_an_order_sent_ahead_prints_at_its_time_with_the_money_as_it_stands_then():
    clock = [T0 + 100]
    c = future(clock)
    printing = c.app.state.printing
    # sent ahead in the morning for tonight: nothing is made until its time, three hours on
    paid = send(c, "o1", CHICKEN, **PHONE, promised_at=T0 + 4 * HOUR, quoted_minutes=60)
    part = send(c, "o2", CHICKEN, **PHONE, promised_at=T0 + 4 * HOUR, quoted_minutes=60)
    owed = due(c)
    pay(c, "p1", "5.00")  # a deposit at noon
    pay(c, "p2", owed - 5, at=600)  # and the rest
    pay(c, "p3", "5.00", order_id="o2")  # a deposit alone on the other
    assert printing.store.all() == [] and printing.release_due() == []

    clock[0] = T0 + 3 * HOUR
    made = {job.job_id for job in printing.release_due()}
    assert made == {f"{paid}:wok", f"{paid}:takeout", f"{part}:wok", f"{part}:takeout"}
    assert money(c, paid) == ["PAID"]
    assert money(c, part) == [f"NOT PAID  ${owed - 5}", f"$5.00 paid of ${owed}"]
    # the copy a fallback printer would get says the same, and the cooks' ticket never speaks of money
    address, copy = printing.store.get(f"{paid}:takeout").fallbacks[0]
    assert address == "10.0.0.1" and "PAID" in [line.strip() for line in decode(copy).text]
    assert not any("PAID" in line for line in ticket(c, paid, "wok").text)
    # each prints once
    assert printing.release_due() == [] and len(printing.store.all()) == 4


def test_a_ticket_whose_time_has_come_is_left_as_it_printed():
    clock = [T0 + 100]
    c = future(clock)
    printing = c.app.state.printing
    key = send(c, "o1", CHICKEN, **PHONE, promised_at=T0 + 4 * HOUR, quoted_minutes=60)
    owed = due(c)
    clock[0] = T0 + 3 * HOUR  # its time has come: it is on paper
    printing.release_due()
    pay(c, "p1", owed)
    assert money(c, key) == [f"NOT PAID  ${owed}"]
    assert len(printing.store.all()) == 2 and printing.held.all() == []


def test_the_words_for_every_way_a_check_can_stand():
    def check(total: str, paid: str, **more) -> dict:
        due = max(Decimal(total) - Decimal(paid), Decimal(0))
        return {"total": total, "paid": paid, "due": str(due), "unpriced": [], **more}

    assert money_words(check("45.20", "0.00")) == Money("NOT PAID  $45.20", owing=True)
    assert money_words(check("1245.20", "200.00")) == Money(
        "NOT PAID  $1,045.20", owing=True, detail="$200.00 paid of $1,245.20"
    )
    assert money_words(check("45.20", "45.20")) == Money("PAID")
    assert money_words(check("35.20", "45.20")) == Money("PAID", detail="$10.00 more than the check, now $35.20")
    assert money_words(check("0.00", "0.00")) == Money("NOTHING TO PAY")  # all of it comped
    # a line with no price: the sum cannot be trusted, so the ticket says nothing rather than something wrong
    assert money_words(check("45.20", "0.00", unpriced=["L1"])) is None
    assert money_words({"total": "?"}) is None


def test_it_prints_big_on_both_kinds_of_printer_and_a_service_nobody_told_prints_as_before():
    owing = replace(DEMO, table="", order_no=42, customer="Linda", money=Money("NOT PAID  $45.20", owing=True))
    for dialect in ("escpos", "star"):
        assert render(owing, dialect=dialect) != render(replace(owing, money=None), dialect=dialect)
    decoded = decode(render(owing))
    assert "NOT PAID  $45.20" in decoded.inverted
    assert PrintService([Printer("takeout", "10.0.0.1")], direct=False).check_of is None
    assert not [line for line in decode(render(DEMO)).text if "PAID" in line]
