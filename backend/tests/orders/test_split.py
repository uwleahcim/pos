"""Splitting a check: one table, several checks. The dishes stay on one order; each check gets its dishes,
its part of every discount, charge and the tax, and the checks add up to what the table owes as one."""

from __future__ import annotations

import random
from decimal import Decimal

from pos.orders.adjustments import default_rules
from pos.orders.check import check_for
from pos.orders.split import ONE, Split, parts, placed, prorate, split_of
from pos.sync.oplog import MAX_CHECKS, replay
from pos.tax import massachusetts

from ..conftest import make_op
from .test_adjustments import DUCK, TEA, adj

LOBSTER = {"unit_price": "25.00", "tax_class": "prepared_food", "name": "Lobster"}
SEAT = {"by": "seat"}
DISH = {"by": "dish"}


def D(text: str) -> Decimal:
    return Decimal(text)


def check_of(*ops):
    return check_for(replay(list(ops), "o1"), massachusetts(), default_rules())


def three_seats(*more, **fields):
    """Tea for seat 1, duck for seat 2, two teas for seat 3 and a lobster for the table."""
    return check_of(
        make_op("create", at=0, table="5", guests=3, order_type="dine_in", **fields),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, seat=2, priced=DUCK),
        make_op("add_line", at=3, line_id="L3", item="Tea", qty=2, seat=3, priced=TEA),
        make_op("add_line", at=4, line_id="L4", item="Lobster", qty=1, priced=LOBSTER),
        *more,
    )


def money(check, name):
    return [part[name] for part in check["checks"]]


def dishes(check):
    return {part["check"]: [(line["name"], line["total"]) for line in part["lines"]] for part in check["checks"]}


# --- the arithmetic -------------------------------------------------------------------------------------


def test_equal_parts_add_up_and_the_odd_cents_go_to_the_first():
    assert parts(D("25.00"), 3) == [D("8.34"), D("8.33"), D("8.33")]
    assert parts(D("0.02"), 3) == [D("0.01"), D("0.01"), D("0.00")]
    assert parts(D("10.00"), 1) == [D("10.00")]
    assert parts(D("0.00"), 4) == [D("0.00")] * 4


def test_in_proportion_adds_up_and_the_cents_left_go_where_most_was_lost():
    # 5.20 over 8.97 and 19.93: 1.613... and 3.586...; the cent left goes to the second, which lost more
    assert prorate(D("5.20"), [D("8.97"), D("19.93")]) == [D("1.61"), D("3.59")]
    assert prorate(D("1.00"), [D("1"), D("1"), D("1")]) == [D("0.34"), D("0.33"), D("0.33")]
    # nothing to weigh by (every dish comped): in equal parts
    assert prorate(D("3.00"), [D("0"), D("0")]) == [D("1.50"), D("1.50")]
    assert prorate(D("0.00"), [D("5"), D("7")]) == [D("0.00"), D("0.00")]


def test_what_the_order_says_of_its_split():
    assert split_of({}) == ONE and split_of({"split": None}) == ONE
    assert split_of({"split": SEAT}) == Split("seat")
    assert split_of({"split": DISH}) == Split("dish")
    assert split_of({"split": {"by": "even", "ways": 4}}) == Split("even", 4)
    # whatever cannot be read is one check
    for junk in ("seat", 3, {"by": "table"}, {"by": "even"}, {"by": "even", "ways": 1}, {"by": "even", "ways": "4"}):
        assert split_of({"split": junk}) == ONE
    assert split_of({"split": {"by": "even", "ways": MAX_CHECKS + 1}}) == ONE
    assert Split("seat").as_json() == {"by": "seat"} and ONE.as_json() is None
    assert Split("even", 4).as_json() == {"by": "even", "ways": 4}


# --- by seat --------------------------------------------------------------------------------------------


def test_one_check_until_the_table_is_split():
    check = three_seats()
    assert check["split"] is None and check["checks"] == []
    assert (check["subtotal"], check["tax"], check["total"]) == ("75.00", "5.25", "80.25")


def test_by_seat_is_a_check_for_each_seat_with_the_tables_dishes_shared():
    check = three_seats(make_op("set_field", at=9, split=SEAT))
    assert check["split"] == {"by": "seat"}
    assert dishes(check) == {
        1: [("Tea", "10.00"), ("Lobster", "8.34")],
        2: [("Duck", "20.00"), ("Lobster", "8.33")],
        3: [("Tea", "20.00"), ("Lobster", "8.33")],
    }
    # the lobster is on every check, and each says who else has it and what the whole dish comes to
    lobster = [part["lines"][-1] for part in check["checks"]]
    assert [(line["shared"], line["of"]) for line in lobster] == [
        ([2, 3], "25.00"),
        ([1, 3], "25.00"),
        ([1, 2], "25.00"),
    ]
    assert check["checks"][0]["lines"][0]["shared"] == []
    assert money(check, "subtotal") == ["18.34", "28.33", "28.33"]
    # the table's tax (4.69 state and 0.56 local on 75.00), divided by what each check holds
    assert money(check, "tax") == ["1.29", "1.98", "1.98"]
    assert money(check, "total") == ["19.63", "30.31", "30.31"]
    # splitting never changes what the table owes
    assert (check["subtotal"], check["tax"], check["total"]) == ("75.00", "5.25", "80.25")
    assert sum(map(D, money(check, "total"))) == D(check["total"])


def test_a_dish_added_after_the_split_goes_to_its_seat():
    check = three_seats(
        make_op("set_field", at=9, split=SEAT),
        make_op("add_line", at=10, line_id="L5", item="Tea", qty=1, seat=2, priced=TEA),
    )
    assert dishes(check)[2] == [("Duck", "20.00"), ("Lobster", "8.33"), ("Tea", "10.00")]


def test_by_seat_with_every_dish_on_one_seat_is_still_one_check():
    check = check_of(
        make_op("create", at=0, table="5", guests=2, order_type="dine_in", split=SEAT),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
    )
    assert check["checks"] == [] and check["split"] is None
    # and with no dish on a seat at all there is nothing to tell checks apart by
    none = check_of(
        make_op("create", at=0, table="5", guests=4, order_type="dine_in", split=SEAT),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
    )
    assert none["checks"] == []


def test_a_seat_with_nothing_of_its_own_has_no_check():
    check = check_of(
        make_op("create", at=0, table="5", guests=4, order_type="dine_in", split=SEAT),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, seat=4, priced=DUCK),
        make_op("add_line", at=3, line_id="L3", item="Lobster", qty=1, priced=LOBSTER),
    )
    # a check keeps its seat's number, so the numbers can have gaps; the lobster is halved, not quartered
    assert dishes(check) == {1: [("Tea", "10.00"), ("Lobster", "12.50")], 4: [("Duck", "20.00"), ("Lobster", "12.50")]}


# --- by hand --------------------------------------------------------------------------------------------


def test_a_dish_moved_to_another_check_keeps_its_seat_and_tells_the_kitchen_nothing():
    ops = [
        make_op("create", at=0, table="5", guests=3, order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, seat=2, priced=DUCK),
        make_op("fire", at=3, course="*"),
        make_op("set_field", at=4, split=SEAT),
        make_op("set_line", at=5, line_id="L2", checks=[1]),
    ]
    state = replay(ops, "o1")
    line = state.lines["L2"]
    assert (line.checks, line.seat, line.modified_after_fire) == ([1], 2, False)
    assert state.snapshot()["lines"]["L2"]["checks"] == [1]
    assert state.snapshot()["lines"]["L1"]["checks"] is None
    # seat 2's duck is on check 1 now, so the table is one check again
    assert check_for(state, massachusetts(), default_rules())["checks"] == []


def test_dishes_put_on_checks_by_hand_and_the_rest_stay_on_the_first():
    check = three_seats(
        make_op("set_field", at=9, split=DISH),
        make_op("set_line", at=10, line_id="L2", checks=[2]),
        make_op("set_line", at=11, line_id="L4", checks=[2, 1]),  # shared by the two
    )
    assert dishes(check) == {
        1: [("Tea", "10.00"), ("Tea", "20.00"), ("Lobster", "12.50")],
        2: [("Duck", "20.00"), ("Lobster", "12.50")],
    }
    assert sum(map(D, money(check, "total"))) == D(check["total"])


def test_checks_put_on_dishes_count_for_nothing_until_the_order_is_split():
    check = three_seats(make_op("set_line", at=10, line_id="L2", checks=[2]))
    assert check["checks"] == []


def test_what_is_not_a_check_number_puts_the_dish_back():
    ops = [
        make_op("create", at=0, table="5", order_type="dine_in", split=DISH),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK, checks=[3, 3, 2]),
    ]
    assert replay(ops, "o1").lines["L2"].checks == [2, 3]
    for junk, kept in (
        (None, None),
        ([], None),
        ("2", None),
        ([0, -1, MAX_CHECKS + 1], None),
        (4, [4]),
        ([True], None),
    ):
        state = replay([*ops, make_op("set_line", at=5, line_id="L2", checks=junk)], "o1")
        assert state.lines["L2"].checks == kept, junk


def test_an_edited_dish_stays_on_the_checks_it_was_put_on():
    ops = [
        make_op("create", at=0, table="5", order_type="dine_in", split=DISH),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
        make_op("set_line", at=3, line_id="L2", checks=[2]),
        # an edit: the dish is voided and added again with other choices
        make_op("void_line", at=4, line_id="L2"),
        make_op("add_line", at=5, line_id="L2b", item="Duck", qty=1, priced=DUCK, replaces="L2"),
    ]
    state = replay(ops, "o1")
    assert state.lines["L2b"].checks == [2]
    assert placed(state, Split("dish")) == ([1, 2], {"L1": [1], "L2b": [2]})


# --- discounts and charges are carried ------------------------------------------------------------------


def test_discounts_and_charges_go_with_the_dishes_they_were_on():
    check = check_of(
        make_op("create", at=0, table="5", guests=6, order_type="dine_in", split=SEAT),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Tea", qty=1, seat=2, priced=TEA),
        make_op("add_line", at=3, line_id="L3", item="Tea", qty=1, seat=2, priced=TEA),
        adj("discount", 4, discount_id="D1", reason="loyalty", kind="percent", value="10", line_id="L1"),
        adj("discount", 5, discount_id="D2", reason="promotion", kind="amount", value="0.10"),
    )
    # the table as one check, as before the split: see test_adjustments
    assert (check["discount_total"], check["charge_total"], check["tax"], check["total"]) == (
        "1.10",
        "5.20",
        "2.03",
        "36.13",
    )
    one, two = check["checks"]
    # the 10% on seat 1's tea is seat 1's alone; the 0.10 off the check is 0.03 on each of the first two
    # teas and 0.04 on the last, so 0.03 and 0.07
    assert [(d["discount_id"], d["name"], d["amount"]) for d in one["discounts"]] == [
        ("D1", "Loyalty reward", "1.00"),
        ("D2", "Promotion", "0.03"),
    ]
    assert [(d["discount_id"], d["amount"]) for d in two["discounts"]] == [("D2", "0.07")]
    assert money(check, "subtotal") == ["10.00", "20.00"]
    assert money(check, "discount_total") == ["1.03", "0.07"]
    # the party's gratuity (18% of the 28.90 left) in proportion to the 8.97 and the 19.93
    assert [[(c["charge_id"], c["amount"]) for c in part["charges"]] for part in (one, two)] == [
        [("auto_gratuity", "1.61")],
        [("auto_gratuity", "3.59")],
    ]
    assert money(check, "charge_total") == ["1.61", "3.59"]
    assert money(check, "tax") == ["0.63", "1.40"]
    assert money(check, "total") == ["11.21", "24.92"]


def test_a_comp_on_a_shared_dish_is_shared_the_same_way():
    check = three_seats(
        make_op("set_field", at=9, split=SEAT),
        adj("discount", 10, discount_id="D1", reason="comp", kind="comp", line_id="L4"),
    )
    lobster = [part["lines"][-1] for part in check["checks"]]
    assert [(line["total"], line["discount"]) for line in lobster] == [
        ("8.34", "8.34"),
        ("8.33", "8.33"),
        ("8.33", "8.33"),
    ]
    assert [part["discounts"][0]["amount"] for part in check["checks"]] == ["8.34", "8.33", "8.33"]
    # each check is left with its own dishes: 10.00, 20.00 and 20.00 and their tax
    # (the table's tax on the 50.00 left is 3.13 state and 0.38 local, and both odd cents fall on check 1)
    assert money(check, "total") == ["10.71", "21.40", "21.40"]
    assert check["total"] == "53.51"


def test_two_discounts_on_a_shared_cent_never_take_a_check_below_nothing():
    penny = {"unit_price": "0.02", "tax_class": "prepared_food", "name": "Mint"}
    check = check_of(
        make_op("create", at=0, table="5", order_type="dine_in", split=DISH),
        make_op("add_line", at=1, line_id="L1", item="Mint", qty=1, priced=penny, checks=[1, 2]),
        adj("discount", 2, discount_id="D1", reason="promotion", kind="amount", value="0.01", line_id="L1"),
        adj("discount", 3, discount_id="D2", reason="promotion", kind="amount", value="0.01", line_id="L1"),
    )
    assert [(part["subtotal"], part["discount_total"], part["total"]) for part in check["checks"]] == [
        ("0.01", "0.01", "0.00"),
        ("0.01", "0.01", "0.00"),
    ]


# --- evenly ---------------------------------------------------------------------------------------------


def test_an_even_split_cuts_the_total_in_equal_parts():
    check = three_seats(make_op("set_field", at=9, split={"by": "even", "ways": 4}))
    assert check["split"] == {"by": "even", "ways": 4}
    # 80.25 in four: the odd cent on the first part; the dishes stay together on the table's check
    assert [(part["check"], part["total"], part["lines"]) for part in check["checks"]] == [
        (1, "20.07", []),
        (2, "20.06", []),
        (3, "20.06", []),
        (4, "20.06", []),
    ]
    assert len(check["lines"]) == 4 and check["total"] == "80.25"


def test_an_even_split_leaves_dishes_where_they_were_put_for_later():
    check = three_seats(
        make_op("set_line", at=8, line_id="L2", checks=[2]),
        make_op("set_field", at=9, split={"by": "even", "ways": 2}),
    )
    assert money(check, "total") == ["40.13", "40.12"]


# --- paying ---------------------------------------------------------------------------------------------


def test_a_payment_that_names_a_check_is_that_checks():
    check = three_seats(
        make_op("set_field", at=9, split=SEAT),
        make_op("pay", at=10, payment_id="P1", method="cash", amount="30.31", tendered="40.00", check=2),
    )
    assert money(check, "paid") == ["0.00", "30.31", "0.00"]
    assert money(check, "due") == ["19.63", "0.00", "30.31"]
    assert check["checks"][1]["payments"] == [
        {"payment_id": "P1", "method": "cash", "amount": "30.31", "tendered": "40.00", "note": "", "by": "", "check": 2}
    ]
    assert (check["paid"], check["due"]) == ("30.31", "49.94")
    assert check["payments"][0]["check"] == 2


def test_a_payment_for_the_table_fills_the_checks_in_order():
    check = three_seats(
        make_op("set_field", at=9, split=SEAT),
        make_op("pay", at=10, payment_id="P1", method="cash", amount="25.00", tendered="30.00"),
    )
    # 19.63 pays check 1 off, the other 5.37 goes toward check 2
    assert money(check, "paid") == ["19.63", "5.37", "0.00"]
    assert money(check, "due") == ["0.00", "24.94", "30.31"]
    # a part of a payment says nothing of what was handed over: that was said of the whole
    assert [(p["amount"], p["tendered"]) for p in check["checks"][0]["payments"]] == [("19.63", None)]
    assert "check" not in check["payments"][0]
    # more than the table owes stays with the first check
    over = three_seats(
        make_op("set_field", at=9, split=SEAT),
        make_op("pay", at=10, payment_id="P1", method="cash", amount="100.00"),
    )
    assert money(over, "paid") == ["39.38", "30.31", "30.31"] and money(over, "due") == ["0.00", "0.00", "0.00"]


def test_each_part_of_an_even_split_can_be_paid():
    check = three_seats(
        make_op("set_field", at=9, split={"by": "even", "ways": 4}),
        make_op("pay", at=10, payment_id="P1", method="card", amount="20.06", check=3),
    )
    assert money(check, "due") == ["20.07", "20.06", "0.00", "20.06"]


# --- whatever the split, it adds up ----------------------------------------------------------------------


def test_however_a_table_is_split_its_checks_add_up_to_the_table():
    rng = random.Random(7)
    for round_no in range(150):
        ops = [make_op("create", at=0, table="5", guests=rng.choice([2, 4, 6, 8]), order_type="dine_in")]
        count = rng.randint(1, 9)
        for n in range(count):
            priced = {"unit_price": f"{rng.randint(1, 4000) / 100:.2f}", "tax_class": "prepared_food", "name": f"D{n}"}
            data = {"seat": rng.choice([None, 1, 2, 3, 4])}
            if rng.random() < 0.4:
                data["checks"] = rng.sample(range(1, 6), rng.randint(1, 4))
            ops.append(
                make_op(
                    "add_line", at=n + 1, line_id=f"L{n}", item=f"D{n}", qty=rng.randint(1, 3), priced=priced, **data
                )
            )
        for n in range(rng.randint(0, 3)):
            on = rng.choice([None, f"L{rng.randrange(count)}"])
            how = rng.choice([("percent", str(rng.randint(1, 15))), ("amount", f"{rng.randint(1, 900) / 100:.2f}")])
            ops.append(
                adj("discount", 20 + n, discount_id=f"X{n}", reason="promotion", kind=how[0], value=how[1], line_id=on)
            )
        if rng.random() < 0.5:
            ops.append(make_op("pay", at=30, payment_id="P", method="cash", amount=f"{rng.randint(1, 9000) / 100:.2f}"))
        ops.append(
            make_op("set_field", at=40, split=rng.choice([SEAT, DISH, {"by": "even", "ways": rng.randint(2, 7)}]))
        )
        check = check_of(*ops)
        if not check["checks"]:
            continue
        for name in ("total", "paid"):
            assert sum(map(D, money(check, name))) == D(check[name]), (round_no, name)
        if check["split"]["by"] == "even":
            continue
        for name in ("subtotal", "discount_total", "charge_total", "tax"):
            assert sum(map(D, money(check, name))) == D(check[name]), (round_no, name)
        for part in check["checks"]:
            # every check adds up on its own, as its bill must
            made = D(part["subtotal"]) - D(part["discount_total"]) + D(part["charge_total"]) + D(part["tax"])
            assert made == D(part["total"]), round_no
            assert D(part["total"]) >= 0 and all(D(line["total"]) >= D(line["discount"]) for line in part["lines"])
            assert sum((D(d["amount"]) for d in part["discounts"]), D("0")) == D(part["discount_total"]), round_no
            assert sum((D(c["amount"]) for c in part["charges"]), D("0")) == D(part["charge_total"]), round_no
