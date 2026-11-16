"""A bill for each check of a split table: the check's own dishes and its part of every discount, charge
and the tax, to the cent as the hub reckons it; and for a table that splits evenly, the whole bill with
the part under the total."""

from __future__ import annotations

from datetime import datetime

from fastapi.testclient import TestClient

from pos.orders.adjustments import default_rules
from pos.orders.check import check_for
from pos.printing.bill import Bill, bill_for, render_bill
from pos.sync.oplog import replay
from pos.tax import massachusetts

from ..conftest import make_op
from ..orders.test_adjustments import DUCK, TEA, adj
from ..orders.test_menu_orders import payload
from ..orders.test_split import LOBSTER, SEAT
from .fake_printer import decode
from .test_other_stations import kitchen

AT = datetime(2026, 11, 15, 19, 42)
WIDE = 48


def paper(bill: Bill, dialect: str = "escpos") -> list[str]:
    return [line.rstrip() for line in decode(render_bill(bill, dialect=dialect)).text]


def row(left: str, right: str, wide: int = WIDE) -> str:
    """A line of the bill with its amount at the right edge."""
    return left + right.rjust(wide - len(left))


def three_seats(*more, **fields):
    """Tea for seat 1, duck for seat 2, two teas for seat 3 and a lobster for the table."""
    ops = [
        make_op("create", at=0, table="5", guests=3, server="Amy", order_type="dine_in", **fields),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, seat=2, priced=DUCK),
        make_op("add_line", at=3, line_id="L3", item="Tea", qty=2, seat=3, priced=TEA),
        make_op("add_line", at=4, line_id="L4", item="Lobster", qty=1, priced=LOBSTER),
        *more,
    ]
    state = replay(ops, "o1")
    return check_for(state, massachusetts(), default_rules()), state.fields


def test_a_checks_bill_lists_its_own_dishes_and_its_part_of_a_shared_one():
    check, fields = three_seats(make_op("set_field", at=9, split=SEAT))
    lines = paper(bill_for(check, fields, foot=("Thank you!",), at=AT, number=2))
    # headed with the table and the check's number, and how many checks the table has
    assert row("Table 5  Check 2", "7:42 PM") in lines
    assert lines[lines.index(row("Server Amy", "Nov 15, 2026")) + 1] == "One of 3 checks at this table"
    assert row("1  Duck", "20.00") in lines
    # the table's lobster: this check's third, and what the whole dish comes to
    assert lines[lines.index(row("1  Lobster", "8.33")) + 1] == "   1/3 of 25.00"
    assert not any("Tea" in line for line in lines)  # the other seats' dishes are on their own bills
    assert row("Subtotal", "28.33") in lines
    assert row("Sales tax 7%", "1.98") in lines
    assert row("TOTAL", "$30.31", WIDE // 2) in lines
    assert check["checks"][1]["total"] == "30.31"
    assert all(len(line) <= WIDE for line in lines)


def test_the_bills_of_a_table_add_up_to_the_table():
    check, fields = three_seats(make_op("set_field", at=9, split=SEAT))
    totals = []
    for part in check["checks"]:
        lines = paper(bill_for(check, fields, at=AT, number=part["check"]))
        (total,) = [line for line in lines if line.startswith("TOTAL")]
        totals.append(total.split("$")[1])
    assert totals == ["19.63", "30.31", "30.31"] and check["total"] == "80.25"
    # with no check asked for, and for a number the table has no check for, the paper is the whole table's
    for whole in (None, 9):
        lines = paper(bill_for(check, fields, at=AT, number=whole))
        assert row("Table 5  3 guests", "7:42 PM") in lines and row("TOTAL", "$80.25", WIDE // 2) in lines


def test_a_checks_bill_carries_its_part_of_each_discount_and_charge():
    ops = [
        make_op("create", at=0, table="5", guests=6, order_type="dine_in", split=SEAT),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Tea", qty=1, seat=2, priced=TEA),
        make_op("add_line", at=3, line_id="L3", item="Tea", qty=1, seat=2, priced=TEA),
        adj("discount", 4, discount_id="D1", reason="loyalty", kind="percent", value="10", line_id="L1"),
        adj("discount", 5, discount_id="D2", reason="promotion", kind="amount", value="0.10"),
    ]
    state = replay(ops, "o1")
    check = check_for(state, massachusetts(), default_rules())
    one = paper(bill_for(check, state.fields, at=AT, number=1))
    assert one[one.index(row("1  Tea", "10.00")) + 1] == "   Loyalty reward -1.00"
    at = one.index(row("Subtotal", "10.00"))
    assert one[at + 1 : at + 5] == [
        row("Loyalty reward, Tea", "-1.00"),
        row("Promotion", "-0.03"),
        row(check["charges"][0]["name"], "1.61"),
        row("Sales tax 7%", "0.63"),
    ]
    assert row("TOTAL", "$11.21", WIDE // 2) in one
    two = paper(bill_for(check, state.fields, at=AT, number=2))
    at = two.index(row("Subtotal", "20.00"))
    # the loyalty reward was on seat 1's tea: nothing of it here
    assert two[at + 1 : at + 4] == [
        row("Promotion", "-0.07"),
        row(check["charges"][0]["name"], "3.59"),
        row("Sales tax 7%", "1.40"),
    ]
    assert row("TOTAL", "$24.92", WIDE // 2) in two


def test_a_choice_on_a_shared_dish_is_named_without_its_price():
    rice = {
        "unit_price": "18.00",
        "tax_class": "prepared_food",
        "name": "Fried Rice",
        "modifiers": [{"label": "Add shrimp", "price": "4.00"}],
    }
    ops = [
        make_op("create", at=0, table="5", order_type="dine_in", split={"by": "dish"}),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Fried Rice", qty=1, priced=rice, checks=[1, 2]),
    ]
    state = replay(ops, "o1")
    check = check_for(state, massachusetts(), default_rules())
    two = paper(bill_for(check, state.fields, at=AT, number=2))
    at = two.index(row("1  Fried Rice", "9.00"))
    # the 4.00 is in the whole dish's 18.00: beside half of it, it would read as an extra
    assert two[at + 1 : at + 3] == ["   1/2 of 18.00", "   Add shrimp"]
    whole = paper(bill_for(check, state.fields, at=AT))
    assert whole[whole.index(row("1  Fried Rice", "18.00")) + 1] == "   Add shrimp +4.00"


def test_what_was_paid_on_a_check_is_on_its_bill_alone():
    check, fields = three_seats(
        make_op("set_field", at=9, split=SEAT),
        make_op("pay", at=10, payment_id="P1", method="cash", amount="30.31", tendered="40.00", check=2),
    )
    two = paper(bill_for(check, fields, at=AT, number=2))
    assert row("Paid cash", "-30.31") in two and "PAID IN FULL" in two
    assert "   40.00 handed over, 9.69 change" in two
    three = paper(bill_for(check, fields, at=AT, number=3))
    assert not any(line.startswith(("Paid", "DUE", "PAID")) for line in three)


def test_an_even_split_prints_the_whole_bill_with_the_part_under_the_total():
    check, fields = three_seats(make_op("set_field", at=9, split={"by": "even", "ways": 4}))
    first = paper(bill_for(check, fields, at=AT, number=1))
    # every dish, as on the table's one bill
    for dish in (row("1  Tea", "10.00"), row("1  Duck", "20.00"), row("2  Tea", "20.00"), row("1  Lobster", "25.00")):
        assert dish in first
    assert row("Table 5  3 guests", "7:42 PM") in first
    # the table's total at the size of the rest, then this guest's part, big: the figure to pay
    at = first.index(row("TOTAL", "$80.25"))
    assert first[at + 1] == row("PART 1 OF 4", "$20.07", WIDE // 2)
    last = paper(bill_for(check, fields, at=AT, number=4))
    assert row("PART 4 OF 4", "$20.06", WIDE // 2) in last


def test_a_part_of_an_even_split_says_what_was_paid_on_it():
    check, fields = three_seats(
        make_op("set_field", at=9, split={"by": "even", "ways": 4}),
        make_op("pay", at=10, payment_id="P1", method="card", amount="10.00", check=3),
    )
    third = paper(bill_for(check, fields, at=AT, number=3))
    assert row("Paid card", "-10.00") in third
    assert row("DUE", "$10.06", WIDE // 2) in third


def test_a_star_draws_a_checks_bill_too():
    check, fields = three_seats(make_op("set_field", at=9, split=SEAT))
    assert len(render_bill(bill_for(check, fields, at=AT, number=1), dialect="star")) > 1000


# --- the API --------------------------------------------------------------------------------------------


def split_table(c: TestClient, split: dict) -> None:
    ops = [
        payload("open", "create", 0, table="5", guests=3, order_type="dine_in"),
        payload("a", "add_line", 1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        payload("b", "add_line", 2, line_id="L2", item="Duck", qty=1, seat=2, priced=DUCK),
        payload("c", "add_line", 3, line_id="L3", item="Lobster", qty=1, priced=LOBSTER),
        payload("s", "set_field", 4, split=split),
    ]
    assert c.post("/orders/o1/ops", json=ops).json()["refused"] == []


def printed(c: TestClient, job: dict) -> list[str]:
    return [line.rstrip() for line in decode(c.app.state.printing.store.get(job["job_id"]).data).text]


def test_the_check_says_how_the_table_is_split():
    c = kitchen("takeout")
    split_table(c, SEAT)
    check = c.get("/orders/o1/check").json()
    assert check["split"] == {"by": "seat"}
    assert [(part["check"], part["total"]) for part in check["checks"]] == [(1, "24.08"), (2, "34.77")]
    assert check["total"] == "58.85"
    # the order itself says which checks a dish was put on by hand: none here, the seats place them
    assert [line["checks"] for line in c.get("/orders/o1").json()["lines"].values()] == [None, None, None]
    moved = [payload("m", "set_line", 5, line_id="L3", checks=[2])]
    assert c.post("/orders/o1/ops", json=moved).json()["print_jobs"] == []  # nothing for the kitchen
    assert c.get("/orders/o1").json()["lines"]["L3"]["checks"] == [2]
    assert [part["total"] for part in c.get("/orders/o1/check").json()["checks"]] == ["10.70", "48.15"]


def test_a_split_table_gets_a_bill_for_each_check():
    c = kitchen("takeout")
    split_table(c, SEAT)
    answer = c.post("/orders/o1/bill")
    assert answer.status_code == 202
    body = answer.json()
    assert body["bills"] == 2 and len(body["jobs"]) == 2 and body["printed_at"]["id"] == "takeout"
    assert body["job_id"] == body["jobs"][0]["job_id"]  # as an app that knows of one bill reads it
    first, second = (printed(c, job) for job in body["jobs"])
    assert any(line.startswith("Table 5  Check 1") for line in first) and row("TOTAL", "$24.08", 24) in first
    assert any(line.startswith("Table 5  Check 2") for line in second) and row("TOTAL", "$34.77", 24) in second

    # one check's bill alone
    one = c.post("/orders/o1/bill", json={"check": 2}).json()
    assert one["bills"] == 1 and row("TOTAL", "$34.77", 24) in printed(c, one)
    # a check the table does not have
    none = c.post("/orders/o1/bill", json={"check": 7})
    assert none.status_code == 409 and none.json()["detail"]["error"] == "no_such_check"


def test_an_even_split_prints_a_bill_for_each_part():
    c = kitchen("takeout")
    split_table(c, {"by": "even", "ways": 3})
    body = c.post("/orders/o1/bill").json()
    assert body["bills"] == 3
    assert [next(line for line in printed(c, job) if line.startswith("PART")) for job in body["jobs"]] == [
        row("PART 1 OF 3", "$19.62", 24),
        row("PART 2 OF 3", "$19.62", 24),
        row("PART 3 OF 3", "$19.61", 24),
    ]


def test_a_table_on_one_check_prints_one_bill_as_before():
    c = kitchen("takeout")
    split_table(c, None)
    body = c.post("/orders/o1/bill").json()
    assert body["bills"] == 1 and row("TOTAL", "$58.85", 24) in printed(c, body)
    refused = c.post("/orders/o1/bill", json={"check": 1})
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_such_check"
