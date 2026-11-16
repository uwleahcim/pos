"""The guest's bill: the check on paper. It says what the check on screen says, to the cent, under the
restaurant's own lines, and prints at the printer the screen asks for or where the location's bills print."""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.orders.adjustments import default_rules
from pos.orders.check import check_for
from pos.printing.bill import SAMPLE, Bill, BillLine, bill_for, render_bill
from pos.printing.escpos import Builder, fit
from pos.printing.service import Printer, PrintService
from pos.settings import BILL_LINE_MAX, BILL_LINES_MAX, SettingStore, clean_bill
from pos.sync.oplog import OpStore, replay
from pos.tax import massachusetts

from ..conftest import T0, make_op
from ..orders.test_adjustments import DUCK, TEA, adj
from ..orders.test_menu_orders import payload
from .fake_printer import decode
from .test_other_stations import CHICKEN, ROLL, kitchen, send
from .test_stations import manager, menu_with_takeout

AT = datetime(2026, 11, 15, 19, 42)
WIDE = 48


def paper(bill: Bill) -> list[str]:
    """The bill as an Epson prints it, line by line, without the padding at the end of each."""
    return [line.rstrip() for line in decode(render_bill(bill)).text]


def table_of_two(*more):
    ops = [
        make_op("create", at=0, table="5", guests=2, server="Amy", order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=2, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
        *more,
    ]
    state = replay(ops, "o1")
    return check_for(state, massachusetts(), default_rules()), state.fields


def printed(c: TestClient, answer: dict) -> list[str]:
    job = c.app.state.printing.store.get(answer["job_id"])
    return [line.rstrip() for line in decode(job.data).text]


def test_the_bill_says_what_the_check_says():
    check, fields = table_of_two()
    lines = paper(bill_for(check, fields, head=("China Sky", "1 Main Street"), foot=("Thank you!",), at=AT))
    assert lines[0] == "China Sky" and lines[1] == "1 Main Street"
    # the table and the time, the server and the day
    assert "Table 5  2 guests" + " " * 24 + "7:42 PM" in lines
    assert "Server Amy" + " " * 26 + "Nov 15, 2026" in lines
    # each dish with what it comes to for its quantity, the amount at the right edge
    assert "2  Tea" + " " * 37 + "20.00" in lines
    assert "1  Duck" + " " * 36 + "20.00" in lines
    assert "Subtotal" + " " * 35 + "40.00" in lines
    # one tax line, as the guest reads it on the check: 6.25% state and 0.75% local are 7%
    assert [line for line in lines if "tax" in line.lower()] == ["Sales tax 7%" + " " * 32 + "2.80"]
    # the total, twice the size, so half as many characters across
    assert "TOTAL" + " " * 13 + "$42.80" in lines
    assert check["total"] == "42.80"
    # nothing paid: nothing said about paying
    assert not any(line.startswith(("Paid", "DUE", "PAID")) for line in lines)
    assert lines[lines.index("Thank you!") - 1] == "-" * WIDE
    assert all(len(line) <= WIDE for line in lines)


def test_only_the_right_hand_column_adds_up():
    check, fields = table_of_two(
        adj("discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L2", applied_by="Amy"),
        adj("discount", 4, discount_id="D2", reason="promotion", kind="amount", value="1.00"),
    )
    lines = paper(bill_for(check, fields, at=AT))
    # the comp is said under its dish, in words, and taken off under the subtotal, where the screen takes it off
    duck = lines.index("1  Duck" + " " * 36 + "20.00")
    assert lines[duck + 1] == "   Manager comp -20.00"
    assert "Manager comp, Duck" + " " * 24 + "-20.00" in lines
    assert "Promotion" + " " * 34 + "-1.00" in lines
    column = [
        line.rsplit(" ", 1)[1]
        for line in lines[duck - 1 :]
        if line[-3:-2] == "." and "$" not in line and not line.startswith(" ")
    ]
    assert column == ["20.00", "20.00", "40.00", "-20.00", "-1.00", check["tax"]]
    assert "TOTAL" + " " * 13 + f"${check['total']}" in lines


def test_a_choice_stands_under_its_dish_with_what_it_adds():
    shrimp = {
        "unit_price": "24.95",
        "tax_class": "prepared_food",
        "name": "General Gao's Chicken (Qt)",
        "modifiers": [
            {"label": "Brown rice", "price": "1.00"},
            {"label": "Extra Add shrimp", "price": "8.00"},
            {"label": "Spicy mayo", "price": "0", "depth": 1},
        ],
    }
    state = replay(
        [
            make_op("create", at=0, table="5", order_type="dine_in"),
            make_op("add_line", at=1, line_id="L1", item="GTC", qty=2, priced=shrimp),
        ],
        "o1",
    )
    lines = paper(bill_for(check_for(state, massachusetts()), state.fields, at=AT))
    dish = lines.index("2  General Gao's Chicken (Qt)" + " " * 14 + "49.90")
    # two of the dish, so two of each choice: what the choices add for the line, as the screen says it
    assert lines[dish + 1 : dish + 4] == ["   Brown rice +2.00", "   Extra Add shrimp +16.00", "     Spicy mayo"]


def test_what_was_paid_and_what_is_still_due():
    part = adj("pay", 5, payment_id="P1", method="cash", amount="20.00", tendered="50.00")
    check, fields = table_of_two(part)
    lines = paper(bill_for(check, fields, at=AT))
    total = lines.index("TOTAL" + " " * 13 + "$42.80")
    assert lines[total + 1] == "Paid cash" + " " * 33 + "-20.00"
    assert lines[total + 2] == "   50.00 handed over, 30.00 change"
    assert lines[total + 3] == "DUE" + " " * 15 + "$22.80"

    rest = adj("pay", 6, payment_id="P2", method="elsewhere", amount="22.80")
    check, fields = table_of_two(part, rest)
    lines = paper(bill_for(check, fields, at=AT))
    assert "Paid" + " " * 38 + "-22.80" in lines  # taken outside the POS: just paid
    assert "PAID IN FULL" in lines and not any(line.startswith("DUE") for line in lines)


def test_a_to_go_order_is_headed_with_its_number_and_name():
    state = replay(
        [
            make_op(
                "create", at=0, order_type="takeout", channel="phone", order_no=7, customer_name="Linda", server="Ben"
            ),
            make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        ],
        "o1",
    )
    lines = paper(bill_for(check_for(state, massachusetts()), state.fields, at=AT.replace(hour=0, minute=5)))
    assert "Order #7  Linda" + " " * 25 + "12:05 AM" in lines
    assert "Phone  Server Ben" + " " * 19 + "Nov 15, 2026" in lines


def test_a_long_dish_goes_on_below_and_keeps_its_price_in_the_column():
    long = "Seafood Delight with Jumbo Shrimp, Scallops and Lobster in White Sauce"
    lines = paper(replace(SAMPLE, lines=(BillLine(1, long, "38.95"),), at=AT))
    first = next(i for i, line in enumerate(lines) if line.startswith("1  Seafood"))
    assert lines[first].endswith(" 38.95") and len(lines[first]) == WIDE
    assert lines[first + 1].startswith("   ") and lines[first + 1].strip() in long
    assert "".join(f"{lines[first][:-5].strip()} {lines[first + 1].strip()}".split()) == "".join(f"1{long}".split())


def test_a_name_in_chinese_keeps_its_price_at_the_edge():
    """Chinese is drawn, not typed: the whole line is one picture as wide as the paper, the price in it."""
    data = render_bill(replace(SAMPLE, lines=(BillLine(1, "左宗鸡", "16.95"),), at=AT))
    assert (576, 32) in decode(data).images


def test_a_star_printer_draws_the_bill_and_nothing_runs_off_the_paper():
    wide = replace(SAMPLE, head=("W" * 40, "M" * 60), lines=(BillLine(1, "W" * 70, "38.95"),), at=AT)
    short = replace(wide, head=("W", "M"), lines=(BillLine(1, "W", "38.95"),))
    tall, low = (render_bill(bill, dialect="star") for bill in (wide, short))
    assert len(tall) > len(low)  # the long lines went on below instead of being cut off at the edge


def test_an_indented_word_longer_than_the_line_still_ends():
    for builder in (Builder(), Builder(chars_per_line=10)):
        builder.line("   " + "W" * 120)
        text = decode(bytes(builder)).text
        assert "".join(line.strip() for line in text) == "W" * 120 and all(len(line) <= builder.chars for line in text)


def test_fit_cuts_at_words_and_always_moves_on():
    by_chars = len
    assert fit("one two three", by_chars, 20) == ("one two three", "")
    assert fit("one two three", by_chars, 9) == ("one two", "three")
    assert fit("  one two three", by_chars, 9) == ("  one two", "three")
    assert fit("abcdefghij", by_chars, 4) == ("abcd", "efghij")  # no space to cut at
    assert fit("abcdef", by_chars, 0) == ("a", "bcdef")  # no room at all: one character, so it ends


def test_a_drawn_line_too_wide_for_the_paper_goes_on_below():
    one, two = Builder(), Builder()
    one.image_line("左宗鸡")
    two.image_line("左宗鸡" * 20)
    assert len(decode(bytes(one)).images) == 1 and len(decode(bytes(two)).images) > 1


# --- where it prints, and the API -----------------------------------------------------------------------------


def test_a_bill_prints_at_the_takeout_printer_until_the_location_says_otherwise():
    c = kitchen("wok", "sushi", "takeout")
    send(c, "o1", CHICKEN, ROLL)
    answer = c.post("/orders/o1/bill")
    assert answer.status_code == 202
    assert answer.json()["printed_at"] == {"id": "takeout", "name": "Takeout"}
    assert answer.json()["printer"] == "10.0.0.3"
    lines = printed(c, answer.json())
    check = c.get("/orders/o1/check").json()
    assert "TOTAL" + f"${check['total']}".rjust(19) in lines
    assert any(line.startswith("Table 12") for line in lines)
    assert "Thank you!" in lines  # the foot a location starts with
    for row in check["lines"]:
        assert any(line.startswith(f"{row['qty']}  {row['name']}"[:30]) for line in lines)

    # the manager names the printer for bills
    saved = c.put("/settings/bill", json={"printer": "sushi"}, headers=manager(c))
    assert saved.status_code == 200 and saved.json()["prints_at"] == "sushi" and saved.json()["usual"] == "takeout"
    assert c.post("/orders/o1/bill").json()["printed_at"]["id"] == "sushi"


def test_a_screen_may_ask_for_its_own_printer():
    c = kitchen("wok", "bar", "takeout")
    send(c, "o1", CHICKEN)
    assert c.post("/orders/o1/bill", json={"printer": "bar"}).json()["printed_at"]["id"] == "bar"
    # a printer that is no longer there is passed over: the bill prints where the location's do
    assert c.post("/orders/o1/bill", json={"printer": "gone"}).json()["printed_at"]["id"] == "takeout"
    assert c.post("/orders/o1/bill", json={}).json()["printed_at"]["id"] == "takeout"


def test_with_no_takeout_printer_the_first_printer_takes_the_bill():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN)
    assert c.post("/orders/o1/bill").json()["printed_at"]["id"] == "wok"
    assert c.get("/settings/bill").json()["prints_at"] == "wok"


def test_what_cannot_print_is_refused_in_words():
    c = kitchen("wok")
    assert c.post("/orders/nope/bill").status_code == 404
    opened = [payload("open", "create", 0, table="3", order_type="dine_in")]
    assert c.post("/orders/o1/ops", json=opened).status_code == 202
    empty = c.post("/orders/o1/bill")
    assert empty.status_code == 409 and empty.json()["detail"]["error"] == "nothing_on_check"

    none = kitchen()
    opened.append(payload("add", "add_line", 1, line_id="L1", item="?", request=CHICKEN))
    assert none.post("/orders/o1/ops", json=opened).status_code == 202
    refused = none.post("/orders/o1/bill")
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_printer"
    assert none.get("/settings/bill").json()["prints_at"] is None


def test_a_paid_order_still_prints_and_says_so():
    c = kitchen("takeout")
    send(c, "o1", CHICKEN, order_type="takeout", channel="counter", customer_name="Sam")
    due = c.get("/orders/o1/check").json()["due"]
    pay = payload("pay", "pay", 500, payment_id="P1", method="cash", amount=due)
    assert c.post("/orders/o1/ops", json=[pay, payload("close", "close", 501)]).json()["refused"] == []
    lines = printed(c, c.post("/orders/o1/bill").json())
    assert "Paid cash" + f"-{due}".rjust(39) in lines and "PAID IN FULL" in lines
    assert any(line.startswith("Order #1  Sam") for line in lines)


def test_the_top_of_the_bill_is_the_managers_to_write():
    named = TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService([Printer("takeout", "10.0.0.1")], direct=False),
            settings=SettingStore(),
            location="China Sky",
        )
    )
    send(named, "o1", CHICKEN)
    # until a manager types a heading, the location's name heads the bill
    assert printed(named, named.post("/orders/o1/bill").json())[0].strip() == "China Sky"

    lines = {"header": ["China Sky", "1 Main Street, Winchester", "", "(781) 555-0100"], "footer": []}
    assert named.put("/settings/bill", json=lines).status_code in (401, 403)  # a manager's to set
    saved = named.put("/settings/bill", json=lines, headers=manager(named))
    assert saved.status_code == 200 and saved.json()["header"] == lines["header"] and saved.json()["footer"] == []
    assert saved.json()["printer"] is None  # left out of the call: as it was
    top = printed(named, named.post("/orders/o1/bill").json())
    # (the empty line is a gap on the paper; the test printer keeps no empty lines)
    assert top[:4] == ["China Sky", "1 Main Street, Winchester", "(781) 555-0100", "-" * WIDE]

    # a hub that was never told its name prints no heading rather than a made-up one
    plain = kitchen("takeout")
    send(plain, "o1", CHICKEN)
    assert printed(plain, plain.post("/orders/o1/bill").json())[0].startswith("Table 12")


def test_the_setting_lists_the_printers_by_the_names_on_their_tickets():
    c = kitchen(Printer("wok1", "10.0.0.1", id="p1", stations=("wok1", "wok2")), "takeout")
    read = c.get("/settings/bill").json()
    assert read["printer"] is None and read["header"] == [] and read["footer"] == ["Thank you!"]
    assert [p["id"] for p in read["printers"]] == ["p1", "takeout"]
    assert read["printers"][1]["name"] == "Takeout" and " + " in read["printers"][0]["name"]
    assert read["prints_at"] == "takeout"


def test_the_sample_prints_what_is_being_tried_before_it_is_saved():
    c = kitchen("wok", "takeout")
    tried = {"printer": "wok", "header": ["Trial Name"], "footer": ["See you soon"]}
    assert c.post("/print/bill-sample", json=tried).status_code in (401, 403)
    answer = c.post("/print/bill-sample", json=tried, headers=manager(c))
    assert answer.status_code == 202 and answer.json()["printed_at"]["id"] == "wok"
    lines = printed(c, answer.json())
    assert lines[0].strip() == "Trial Name" and "See you soon" in lines
    assert "TOTAL" + "$36.22".rjust(19) in lines
    assert c.get("/settings/bill").json()["header"] == []  # nothing was saved
    # "the usual printer" being tried is the takeout printer, whatever is saved
    assert c.put("/settings/bill", json={"printer": "wok"}, headers=manager(c)).status_code == 200
    usual = c.post("/print/bill-sample", json={"printer": None}, headers=manager(c)).json()
    assert usual["printed_at"]["id"] == "takeout"
    too_long = c.post("/print/bill-sample", json={"header": ["x" * (BILL_LINE_MAX + 1)]}, headers=manager(c))
    assert too_long.status_code == 422


def test_a_fallback_printers_copy_says_whose_bill_it_is():
    front = Printer("takeout", "10.0.0.1", id="front", fallbacks=("wok",))
    c = kitchen(front, "wok")
    send(c, "o1", CHICKEN)
    job = c.app.state.printing.store.get(c.post("/orders/o1/bill").json()["job_id"])
    [(address, data)] = job.fallbacks
    assert address == "10.0.0.2"
    assert "TAKEOUT PRINTER DOWN, PRINTED HERE" in decode(data).inverted
    assert "PRINTER DOWN" not in " ".join(decode(job.data).text)


def test_the_bill_setting_is_checked():
    assert clean_bill({}) == {"printer": None, "header": [], "footer": []}
    cleaned = clean_bill({"printer": "", "header": ["", "  China   Sky ", "", "Winchester", ""], "footer": ["Bye\n"]})
    assert cleaned == {"printer": None, "header": ["China Sky", "", "Winchester"], "footer": ["Bye"]}
    assert clean_bill({"printer": "p2"})["printer"] == "p2"
    for bad in (
        {"printer": "two words"},
        {"printer": 3},
        {"header": "China Sky"},
        {"header": [1]},
        {"footer": ["x"] * (BILL_LINES_MAX + 1)},
        {"header": ["x" * (BILL_LINE_MAX + 1)]},
    ):
        with pytest.raises(ValueError):
            clean_bill(bad)
