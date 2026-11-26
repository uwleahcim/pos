"""An online order turned into what the POS writes for an order of its own (pos.online.place), against the
restaurant's own menu: the dishes are found by GloriaFood's ids, the prices are GloriaFood's, and the check
comes to what the customer was charged."""

from __future__ import annotations

import json
from decimal import Decimal
from functools import cache

import pytest

from pos.menu.gloriafood import load_restaurant_menu
from pos.menu.service import MenuService
from pos.online.place import (
    BY,
    DEVICE,
    DIFFERENCE,
    PROMOTION,
    ROUNDED,
    CannotPlace,
    NotAnOrder,
    Placed,
    hidden,
    ops_for,
    own_word,
)
from pos.orders.adjustments import ChargeRule, PricingRules
from pos.orders.check import UNTAXED, check_for
from pos.orders.delivery_fee import fee_charged, fee_of, fee_ops
from pos.sync.hlc import Clock
from pos.sync.oplog import Op, OrderState, replay
from pos.tax import massachusetts

from ..conftest import make_op
from .hub import MINUTE, NOW
from .orders import extra, order, row

TAXES = massachusetts()
MINUTES = {"online": 25, "delivery": 45}
CENT = Decimal("0.01")


@cache
def menu() -> MenuService:
    return MenuService(load_restaurant_menu()[0])


def place(told: dict, *, now: int = NOW, rules: PricingRules | None = None) -> Placed:
    clock = Clock(DEVICE, lambda: now)
    return ops_for(
        told,
        menu(),
        stamp=clock.now,
        check_of=lambda state: check_for(state, TAXES, rules),
        rules=rules,
        minutes=MINUTES,
        now_ms=now,
    )


def state_of(placed: Placed) -> OrderState:
    return replay(placed.ops, placed.order_id)


def check_of(placed: Placed, rules: PricingRules | None = None) -> dict:
    return check_for(state_of(placed), TAXES, rules)


def kinds(placed: Placed) -> list[str]:
    return [op.kind for op in placed.ops]


def lines(placed: Placed) -> list[dict]:
    return [op.data for op in placed.ops if op.kind == "add_line"]


LUNCH = ("Sweet & Sour Chicken", 2)


# An order for pickup -------------------------------------------------------------------------------------


def test_a_pickup_order_becomes_a_to_go_order_with_its_dishes_sent():
    told = order(101, [row(*LUNCH, choose=("Wonton Soup", "Brown Rice")), row("Maki Combination")])
    placed = place(told)
    assert placed.order_id == "gf-101"
    assert (placed.said, placed.as_written, placed.difference, placed.late) == ("", (), Decimal(0), False)
    assert kinds(placed) == ["create", "add_line", "add_line", "fire"]
    # one order however often it is placed: the same operations, by name
    assert [op.op_id for op in placed.ops] == ["gf-101:create", "gf-101:line-1", "gf-101:line-2", "gf-101:fire"]
    assert all(op.device == DEVICE and op.hlc.node == DEVICE for op in placed.ops)
    assert [op.hlc for op in placed.ops] == sorted(op.hlc for op in placed.ops)
    fields = state_of(placed).fields
    assert fields == {
        "order_type": "takeout",
        "channel": "online",
        "stage": "new",
        "customer_name": "Pat Example",
        "phone": "+1 781 555 0142",
        "promised_at": NOW + 24 * MINUTE,  # GloriaFood promised 18:25
        "quoted_minutes": 25,  # ...when it was accepted at 18:00: the kitchen gets it now
        "locale": "en",
        "online": {"source": "gloriafood", "id": "101", "type": "pickup", "payment": "CASH", "total": "58.69"},
    }
    state = state_of(placed)
    assert all(line.fired_at is not None and line.by == BY for line in state.lines.values())


def test_a_dish_is_the_dish_a_server_rings_in():
    placed = place(order(102, [row(*LUNCH, choose=("Wonton Soup", "Brown Rice"), instructions=" sauce on  the side ")]))
    (line,) = lines(placed)
    assert (line["item"], line["qty"], line["note"], line["by"]) == ("Sweet & Sour Chicken", 2, "sauce on the side", BY)
    priced = line["priced"]
    assert (priced["item"], priced["variant_id"], priced["unit_price"]) == ("L01", "L01:regular", "14.95")
    assert priced["problems"] == [] and "online" not in priced  # the POS's price is the website's here
    # the kitchen reads its own labels, at the dish's own stations
    assert [k["station"] for k in priced["kitchen"]] == ["wok1", "soup"]
    assert "SWEET & SOUR" in priced["kitchen"][0]["label"]
    assert [m["label"] for m in priced["modifiers"]] == ["Brown Rice", "Wonton Soup"]
    # what a screen reopens the choices from
    assert line["request"] == {
        "variant_id": "L01:regular",
        "selections": [
            {"group_id": "soup_929530", "option_id": "soup_929530:4904289", "qty": 1},
            {"group_id": "lunch_rice_929539", "option_id": "lunch_rice_929539:4904330", "qty": 1},
        ],
    }
    assert menu().priced(line["request"])["problems"] == []


def test_a_size_is_found_by_its_id_and_a_paid_choice_costs_what_it_cost_online():
    rows = [row("Duck Sauce", size="Medium"), row("Chicken Soong", choose=("Lettuce Wrap",))]
    placed = place(order(103, rows))
    assert placed.as_written == ()
    sauce, soong = (line["priced"] for line in lines(placed))
    assert sauce["name"] == "Duck Sauce (Medium)" and sauce["variant_id"].startswith("Y21:")
    # the size's price online is the dish's and the size's together
    assert Decimal(sauce["unit_price"]) == Decimal("2.50")
    wrap = next(m for m in soong["modifiers"] if not m["defaulted"])
    assert (wrap["qty"], wrap["price"], wrap["option_id"] is not None) == (1, "0.75", True)
    assert Decimal(soong["unit_price"]) == Decimal(str(row("Chicken Soong")["price"])) + Decimal("0.75")
    assert Decimal(check_of(placed)["total"]) == Decimal(str(order(103, rows)["total_price"]))


def test_more_of_a_choice_than_the_menu_on_the_pos_takes_goes_on_as_written_at_what_it_cost():
    rows = [row("Chicken Soong", choose=(("Lettuce Wrap", 2),))]
    placed = place(order(104, rows))
    assert placed.as_written == ("Chicken Soong",)
    (soong,) = (line["priced"] for line in lines(placed))
    (wrap,) = soong["modifiers"]
    assert (wrap["label"], wrap["qty"], wrap["price"]) == ("2x Lettuce Wrap", 1, "1.50")
    assert Decimal(soong["unit_price"]) == Decimal(str(row("Chicken Soong")["price"])) + Decimal("1.50")
    assert soong["kitchen"][0]["station"] == "wok1"  # it still prints where the dish is cooked
    assert Decimal(check_of(placed)["total"]) == Decimal(str(order(104, rows)["total_price"]))


def test_the_rolls_of_a_combination_are_found_by_name_and_then_by_number():
    # the rolls are the POS's own dishes there: GloriaFood's ids for them are not on the menu
    placed = place(order(104, [row("Maki Combination", choose=("Kappa Maki", "Kaniyu", "Spicy Tuna"))]))
    (line,) = lines(placed)
    assert placed.as_written == ()
    chosen = {s["option_id"] for s in line["request"]["selections"]}
    assert {"roll_934419:K01", "roll_934419:K02", "roll_934419:K10"} <= chosen  # "Kaniyu" is "Kanikyu" on the POS
    assert [k["station"] for k in line["priced"]["kitchen"]][0] == "sushi"


def test_the_price_is_the_website_s_whatever_the_dining_room_charges():
    told = order(105, [row("Basil Chicken"), row("Shrimp Chow Fun", 2)])
    basil, fun = (line["priced"] for line in lines(place(told)))
    assert (basil["unit_price"], basil["online"]) == ("18.95", {"menu_price": "19.95"})
    assert (fun["unit_price"], fun["online"]) == ("17.95", {"menu_price": "16.95"})
    check = check_of(place(told))
    assert check["subtotal"] == "54.85" and Decimal(check["total"]) == Decimal(str(told["total_price"]))


# A dish the menu cannot make ---------------------------------------------------------------------------------


def test_a_dish_the_pos_does_not_have_goes_on_as_written():
    told = order(106, [row("Orange Juice", 2, instructions="no ice"), row(*LUNCH)])
    placed = place(told)
    assert placed.as_written == ("Orange Juice",)
    assert placed.said == "1 dish went on as written (Orange Juice)"
    juice = lines(placed)[0]
    assert (juice["item"], juice["qty"], juice["note"]) == ("Orange Juice", 2, "no ice")
    assert "request" not in juice
    priced = juice["priced"]
    assert (priced["item"], priced["variant_id"], priced["tax_class"]) == (None, None, "prepared_food")
    assert priced["online"] == {"as_written": True}
    assert priced["kitchen"] == [
        {
            "station": None,
            "qty": 1,
            "text": "1 Orange Juice",
            "label": "Orange Juice",
            "labels": [],
            "depths": [],
            "header": None,
            "note": None,
        }
    ]
    # nothing is left off, and the check still comes to what the customer was charged
    assert Decimal(check_of(placed)["total"]) == Decimal(str(told["total_price"]))
    assert check_of(placed)["unpriced"] == []
    assert state_of(placed).lines["gf-106-1"].fired_at is not None


def test_a_dish_whose_choices_the_menu_will_not_take_goes_on_as_written_at_its_own_station():
    dish = row("Maki Combination")
    dish["options"] = dish["options"][:2]  # one roll, where the menu asks for three
    dish["options"].append(
        {"id": 1, "name": "X9:  Dragon Sauce", "price": 1.5, "group_name": "Extras", "quantity": 2, "type": "option"}
    )
    dish["total_item_price"] = 27.95
    placed = place(order(107, [dish]))
    assert placed.as_written == ("Maki Combination",)
    (line,) = lines(placed)
    priced = line["priced"]
    assert (priced["item"], priced["unit_price"]) == ("J55", "27.95")
    assert priced["kitchen"][0]["station"] == "sushi"
    assert priced["kitchen"][0]["labels"] == ["Miso Soup", "Kappa Maki", "2x Dragon Sauce"]
    assert [(m["label"], m["price"]) for m in priced["modifiers"]][-1] == ("2x Dragon Sauce", "3.00")


def test_a_dish_that_ran_out_on_the_pos_was_sold_online_all_the_same():
    service = MenuService(load_restaurant_menu()[0])
    service.set_availability("L01:regular", "86")
    clock = Clock(DEVICE, lambda: NOW)
    placed = ops_for(
        order(108, [row(*LUNCH)]),
        service,
        stamp=clock.now,
        check_of=lambda state: check_for(state, TAXES),
        now_ms=NOW,
    )
    assert placed.as_written == () and lines(placed)[0]["priced"]["problems"] == []


# The money -------------------------------------------------------------------------------------------------


def test_a_delivery_paid_online_carries_its_fee_its_tip_and_its_payment():
    rows = [row(*LUNCH), row("Maki Combination"), extra("delivery_fee", 4.0), extra("tip", 6.0)]
    told = order(201, rows, kind="delivery", payment="ONLINE", fulfillment_option="no_contact")
    placed = place(told)
    assert kinds(placed) == ["create", "add_line", "add_line", "charge", "pay", "fire"]
    fields = state_of(placed).fields
    assert (fields["handover"], fields["address"]) == ("delivery", "1 Restaurant Row, Winchester")
    assert fields["event_note"] == "Apt 3B, No contact: leave it at the door"
    assert fields["delivery_fee"] == {"by": "online", "up_to": None, "amount": "4.00", "taxed": False}
    assert fields["online"]["payment"] == "ONLINE"
    check = check_of(placed)
    assert [(c["name"], c["amount"], c["taxed"], c["gratuity"]) for c in check["charges"]] == [
        ("Tip", "6.00", False, True),
        ("Delivery fee", "4.00", False, False),
    ]
    assert (check["subtotal"], check["tax"], check["total"]) == ("54.85", "3.84", "68.69")
    assert Decimal(check["total"]) == Decimal(str(told["total_price"]))
    # paid on the website: money taken outside the POS, on the day, for what the customer was charged
    assert check["payments"] == [
        {
            "payment_id": "gf-201:paid",
            "method": "elsewhere",
            "amount": "68.69",
            "tendered": None,
            "note": "Paid online",
            "by": BY,
        }
    ]
    assert (check["paid"], check["due"]) == ("68.69", "0.00")


def test_an_order_to_be_paid_at_the_door_records_no_payment():
    for payment in ("CASH", "CARD", "CARD_PHONE"):
        check = check_of(place(order(202, [row(*LUNCH)], payment=payment)))
        assert (check["payments"], check["paid"], check["due"]) == ([], "0.00", "31.99")


def test_an_order_paid_in_two_ways_is_not_guessed_at():
    placed = place(order(203, [row(*LUNCH)], payment="ONLINE", used_payment_methods=2))
    assert check_of(placed)["payments"] == []
    assert "paid in more than one way" in placed.said


def test_a_taxed_delivery_fee_is_taxed_as_the_website_taxed_it():
    told = order(204, [row(*LUNCH), extra("delivery_fee", 5.0)], kind="delivery", taxed_fee=True)
    placed = place(told)
    assert state_of(placed).fields["delivery_fee"] == {"by": "online", "up_to": None, "amount": "5.00", "taxed": True}
    check = check_of(placed)
    assert check["charges"][0]["taxed"] is True
    assert (check["tax"], check["total"]) == ("2.44", "37.34")
    assert Decimal(check["total"]) == Decimal(str(told["total_price"])) and placed.difference == 0


def test_a_delivery_with_no_fee_says_no_fee():
    placed = place(order(205, [row(*LUNCH)], kind="delivery"))
    fields = state_of(placed).fields
    assert fields["delivery_fee"] == {"by": None, "up_to": None, "amount": "0.00", "taxed": False}
    assert fee_of(fields) == {"by": None, "up_to": None, "amount": "0.00", "taxed": False}  # no fee, on purpose
    assert fee_charged(fields) is None


def test_a_promotion_on_a_dish_and_one_on_the_cart_are_discounts_by_name():
    free = row("Duck Sauce", parent_id=900, item_discount=row("Duck Sauce")["total_item_price"])
    lunch = row(*LUNCH, cart_discount=2.99, cart_discount_rate=0.1)
    rows = [
        extra("promo_item", 0, "Free sauce with lunch", id=900),
        free,
        lunch,
        extra("promo_cart", 0, "10% off your first order", cart_discount=-2.99, cart_discount_rate=-0.1),
    ]
    told = order(206, rows, coupons=["WELCOME10"])
    placed = place(told)
    assert kinds(placed) == ["create", "add_line", "discount", "add_line", "discount", "fire"]
    on_dish, on_cart = (op.data for op in placed.ops if op.kind == "discount")
    assert on_dish == {
        "discount_id": "gf-206:off-1",
        "reason": PROMOTION,
        "kind": "amount",
        "value": str(Decimal(str(free["total_item_price"])).quantize(Decimal("0.01"))),
        "line_id": "gf-206-1",
        "note": "Free sauce with lunch",
        "applied_by": BY,
    }
    assert (on_cart["value"], on_cart.get("line_id")) == ("2.99", None)
    assert on_cart["note"] == "Free sauce with lunch, 10% off your first order, coupon WELCOME10"
    check = check_of(placed)
    assert [d["name"] for d in check["discounts"]] == [PROMOTION, PROMOTION]
    assert Decimal(check["discount_total"]) == Decimal(str(free["total_item_price"])) + Decimal("2.99")
    assert Decimal(check["total"]) == Decimal(str(told["total_price"])) and placed.difference == 0


def test_a_cart_promotion_said_only_on_its_own_row_is_taken_off_once():
    rows = [row(*LUNCH), extra("promo_cart", 0, "Five off", cart_discount=-5.0)]
    told = order(207, rows)
    told["total_price"] = float(((Decimal("29.90") - 5) * Decimal("1.07")).quantize(Decimal("0.01")))
    placed = place(told)
    check = check_of(placed)
    # the POS rounds the state's and the town's tax each by itself, so a cent can part it from GloriaFood's
    assert (check["discount_total"], check["total"]) == ("5.00", "26.64") and abs(placed.difference) <= CENT


def test_a_service_fee_is_a_charge_and_the_pos_s_own_to_go_charge_is_left_off():
    packaging = ChargeRule(code="packaging", name="Packaging", kind="amount", value=Decimal("1.00"), automatic=True)
    rules = PricingRules(charges={"packaging": packaging})
    assert packaging.applies("takeout", None)
    rows = [row(*LUNCH), extra("service_fee_subtotal", 1.5, "SERVICE_FEE_SUBTOTAL")]
    told = order(208, rows)
    told["tax_list"].append({"type": "fees_discounts_subtotal", "value": 0.11, "rate": 0.07})
    told["total_price"] = 33.6  # 29.90 + 1.50, and 7% on both
    placed = place(told, rules=rules)
    assert kinds(placed) == ["create", "add_line", "charge", "remove_charge", "fire"]
    check = check_of(placed, rules)
    assert [(c["name"], c["amount"], c["taxed"]) for c in check["charges"]] == [("Service fee subtotal", "1.50", True)]
    assert check["total"] == "33.60" and placed.difference == 0


def test_a_cent_of_rounding_is_evened_by_a_row_of_its_own_and_is_nothing_to_look_at():
    # GloriaFood rounds the tax once, at 7%; the POS rounds Massachusetts' and Winchester's parts apart
    cent = next(
        n
        for n in range(1, 400)
        if Decimal(check_for(_one_dish(n), TAXES)["total"]) != (_price(n) * Decimal("1.07")).quantize(Decimal("0.01"))
    )
    dish = row("Sweet & Sour Chicken", total_item_price=float(_price(cent)), price=float(_price(cent)))
    told = order(209, [dish], payment="ONLINE")
    placed = place(told)
    assert abs(placed.difference) == Decimal("0.01") and not placed.as_written
    assert (placed.said, placed.look) == ("", False)  # about one order in four: nobody is sent to look
    difference = next(op.data for op in placed.ops if op.kind == "charge")
    assert (difference["name"], difference["code"], difference["tax_class"]) == (ROUNDED, "online_rounding", UNTAXED)
    check = check_of(placed)
    assert Decimal(check["total"]) == Decimal(str(told["total_price"]))
    assert (check["paid"], check["due"]) == (check["total"], "0.00")
    row_ = next(c for c in check["charges"] if c["name"] == ROUNDED)
    assert row_["taxed"] is False and abs(Decimal(row_["amount"])) == Decimal("0.01")


def _price(cents: int) -> Decimal:
    return Decimal(10) + Decimal(cents) / 100


def _one_dish(cents: int) -> OrderState:
    priced = {"unit_price": str(_price(cents)), "tax_class": "prepared_food", "name": "Dish"}
    return replay([make_op("add_line", line_id="L1", item="Dish", qty=1, priced=priced)], "o1")


def test_a_row_of_a_kind_nobody_knows_is_evened_and_said():
    told = order(210, [row(*LUNCH), extra("bottle_deposit", 0.5)])
    told["total_price"] = 32.49
    placed = place(told)
    assert placed.difference == Decimal("0.50")
    assert "rows of a kind this POS does not know (bottle_deposit)" in placed.said
    assert "GloriaFood's total is $0.50 more than the POS reckoned" in placed.said
    check = check_of(placed)
    assert check["total"] == "32.49" and placed.look
    assert [(c["name"], c["amount"], c["taxed"]) for c in check["charges"]] == [(DIFFERENCE, "0.50", False)]


# When it is for --------------------------------------------------------------------------------------------


def test_an_order_for_later_waits_for_the_location_s_own_minutes():
    told = order(301, [row(*LUNCH)], fulfill="2027-01-16T00:30:00.000Z", for_later=True)
    fields = state_of(place(told)).fields
    assert (fields["promised_at"], fields["for_later"], fields["quoted_minutes"]) == (NOW + 89 * MINUTE, True, 25)
    delivery = order(302, [row(*LUNCH)], kind="delivery", fulfill="2027-01-16T00:30:00.000Z", for_later=True)
    assert state_of(place(delivery)).fields["quoted_minutes"] == 45
    assert place(told).late is False and "fire" in kinds(place(told))


def test_an_order_that_names_no_time_is_cooked_now():
    told = order(303, [row(*LUNCH)], fulfill=None)
    fields = state_of(place(told)).fields
    assert "promised_at" not in fields and "quoted_minutes" not in fields
    assert "fire" in kinds(place(told))


def test_an_order_that_reaches_the_hub_after_its_time_is_on_the_pos_and_not_sent_to_the_kitchen():
    told = order(304, [row(*LUNCH)], payment="ONLINE")  # wanted for 18:25
    in_time = place(told, now=NOW + 39 * MINUTE)  # 18:40: a quarter of an hour's grace
    assert in_time.late is False and "fire" in kinds(in_time)
    late = place(told, now=NOW + 60 * MINUTE)  # the hub had no internet until 19:01
    assert late.late is True and late.look
    assert kinds(late) == ["create", "add_line", "pay"]  # the sale and its payment, and no ticket
    assert "it reached the hub after its time (18:25" in late.said
    assert "not sent to the kitchen" in late.said
    assert all(line.fired_at is None for line in state_of(late).lines.values())


def test_an_order_from_an_earlier_day_is_not_put_on_today_s_sales():
    told = order(305, [row(*LUNCH)])
    with pytest.raises(NotAnOrder) as kept:
        place(told, now=NOW + 20 * 60 * MINUTE)  # the next afternoon
    assert kept.value.old is True
    assert "accepted on Jan 15" in kept.value.reason and "GloriaFood's own records" in kept.value.reason
    # one still to come is an order however long ago it was accepted
    ahead = order(306, [row(*LUNCH)], fulfill="2027-01-17T23:00:00.000Z", for_later=True)
    assert "fire" in kinds(place(ahead, now=NOW + 20 * 60 * MINUTE))


# What is no order ------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("change", "why"),
    [
        ({"type": "table_reservation"}, "it is a table reservation"),
        ({"type": "order_ahead"}, "it is a table booked with its dishes ordered ahead"),
        ({"type": "dine_in"}, "it is an order placed from a table"),
        ({"type": "drone"}, "it is of a kind the POS does not take (drone)"),
        ({"status": "rejected"}, "it was not accepted (rejected)"),
        ({"status": "canceled"}, "it was not accepted (canceled)"),
        ({"status": "pending"}, "it waits to be accepted in GloriaFood's app"),  # it may be yet
        ({"tax_type": "GROSS"}, "its prices have the tax in them, which this POS does not take"),
        ({"id": None}, "it has no number"),
    ],
)
def test_what_is_no_order_for_the_pos_is_kept_with_why(change, why):
    with pytest.raises(NotAnOrder) as kept:
        place({**order(401, [row(*LUNCH)]), **change})
    assert kept.value.reason == why and kept.value.old is False


def test_an_order_with_no_dishes_cannot_be_placed():
    with pytest.raises(CannotPlace) as failed:
        place(order(402, [extra("tip", 2.0)]))
    assert failed.value.reason == "it has no dishes"


# The customer ----------------------------------------------------------------------------------------------


def test_what_the_customer_wrote_is_the_order_s_note_and_nothing_else_of_them_is_kept():
    told = order(
        501, [row(*LUNCH)], instructions="Peanut allergy!\nPlease  ring the bell", fulfillment_option="curbside_pickup"
    )
    placed = place(told)
    assert state_of(placed).fields["note"] == "Peanut allergy! Please ring the bell · Curbside pickup"
    everything = json.dumps([op.data for op in placed.ops])
    for private in ("pat@example.com", "client_email", "marketing", "42.45", "not-a-real-key", "client_id"):
        assert private not in everything


def test_an_order_looked_at_for_its_shape_shows_nothing_of_the_customer():
    told = order(502, [row(*LUNCH, instructions="for Pat")], kind="delivery", instructions="gate code 1234")
    shown = json.dumps(hidden(told))
    for private in ("Pat", "Example", "781", "Restaurant Row", "3B", "1234", "42.45", "not-a-real", "@example.com"):
        assert private not in shown, private
    assert hidden(told)["items"][0]["type_id"] == told["items"][0]["type_id"]  # what the order is stays
    assert hidden(told)["total_price"] == told["total_price"]
    assert hidden(told)["client_first_name"] == "(hidden)" and hidden(told)["instructions"] == "(hidden)"


# The hub's own word ----------------------------------------------------------------------------------------


def test_a_screen_cannot_say_an_order_came_from_the_website():
    forged = make_op("create", order_type="takeout", online={"source": "gloriafood", "id": "1"}, customer_name="X")
    assert own_word(forged).data == {"order_type": "takeout", "customer_name": "X"}
    plain = make_op("add_line", line_id="L1", item="Tea")
    assert own_word(plain) is plain


def test_a_screen_cannot_make_up_a_fee_charged_online():
    forged = make_op("set_field", delivery_fee={"by": "online", "up_to": None, "amount": "0.01", "taxed": False})
    (kept,), refused = fee_ops(lambda: {"enabled": True, "by": "miles", "bands": []}, [forged])
    assert kept.data == {"delivery_fee": {"up_to": None, "amount": "0.00"}} and refused == []  # no fee, as ever


def test_a_fee_charged_online_is_charged_while_the_order_is_a_delivery():
    online = {"by": "online", "up_to": None, "amount": "4.00", "taxed": False}
    delivery = {"order_type": "takeout", "handover": "delivery", "delivery_fee": online}
    assert fee_charged(delivery) == online
    assert fee_charged({**delivery, "handover": "pickup"}) is None  # changed to pickup: charged nothing
    state = replay([make_op("create", **delivery)], "o1")
    (charge,) = check_for(state, TAXES)["charges"]
    assert (charge["name"], charge["amount"], charge["delivery"]) == (
        "Delivery fee",
        "4.00",
        {"by": "online", "up_to": None},
    )


def charge(at: int, **data) -> Op:
    op = make_op("charge", at=at)
    return Op(op.op_id, op.order_id, op.hlc, op.device, op.kind, data)


def test_a_charge_marked_untaxed_is_never_taxed():
    tea = {"unit_price": "10.00", "tax_class": "prepared_food", "name": "Tea"}
    ops = [
        make_op("add_line", at=0, line_id="L1", item="Tea", qty=1, priced=tea),
        charge(1, charge_id="c1", name="Evened", kind="amount", value="-0.03", tax_class=UNTAXED),
        charge(2, charge_id="c2", name="Service", kind="amount", value="1.00"),
    ]
    check = check_for(replay(ops, "o1"), TAXES)
    assert [(c["name"], c["amount"], c["taxed"]) for c in check["charges"]] == [
        ("Evened", "-0.03", False),
        ("Service", "1.00", True),
    ]
    assert (check["tax"], check["total"]) == ("0.77", "11.74")  # 7% on the tea and the service charge alone
