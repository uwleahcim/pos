"""Dishes sold over a span of days, best to worst, with their sizes and their options.

The same checks as the sales report, read dish by dish: how many of each and for how much, beside the same
days whole weeks earlier, the sizes a dish went out in and every choice made on it. These tests ring a few
evenings through the hub the way the screens do and read what a manager gets."""

from __future__ import annotations

from dataclasses import replace
from datetime import date
from decimal import Decimal

import pytest

from pos.menu.defs import Entry, Item, Variant
from pos.menu.defs import money as price
from pos.menu.service import load_definitions
from pos.orders.dishes import dishes_report
from pos.orders.sales import MAX_DAYS, sale_of

from .test_day import BEER, DSN, EGGROLL, PUPU, SODA, WINGS, Hub, at, evening, money
from .test_sales import sales, week_before

GTC = {"variant_id": "GTC:pint", "entry_id": "dinner:87"}  # 13.95, Chef's Specials; a quart is 24.95
COMBO = {"variant_id": "C5:regular", "entry_id": "dinner:C5"}  # 14.50: an entree, a side and a rice
OPEN = {"variant_id": "OPEN:regular", "entry_id": "dinner:OPEN"}


def picks(*chosen: tuple[str, ...], **more) -> list[dict]:
    """Selections as a screen sends them: (group, option) or (group, option, word)."""
    return [
        {"group_id": c[0], "option_id": f"{c[0]}:{c[1]}", **({"prefix": c[2]} if len(c) > 2 else {}), **more}
        for c in chosen
    ]


def dishes(h: Hub, first: str | None = None, last: str | None = None) -> dict:
    params = {name: day for name, day in (("from", first), ("to", last)) if day}
    answer = h.c.get("/reports/dishes", params=params, headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def dish(report: dict, name: str) -> dict:
    return next(row for row in report["dishes"] if row["name"] == name)


def sold(rows: list[dict]) -> list[tuple]:
    return [(row.get("group", ""), row["name"], row["count"], row["amount"]) for row in rows]


def chicken_night(h: Hub | None = None) -> Hub:
    """Monday the 16th: c1, table 3, two quarts of General Tso's extra spicy with brown rice and a pint as
    it comes; c2, to go, a pint with extra shrimp, the sauce on the side and no rice."""
    h = h or Hub()
    h.table("c1", at(18), table="3")
    quart = {"variant_id": "GTC:quart", "entry_id": "dinner:87"}
    h.ring("c1", "L1", {**quart, "selections": picks(("spice", "extra"), ("rice", "brown"))}, at(18, 1), qty=2)
    h.ring("c1", "L2", GTC, at(18, 2))
    h.to_go("c2", at(19))
    chosen = picks(("addons", "shrimp", "extra"), ("addons", "sauce", "side"), ("rice", "none"))
    h.ring("c2", "L1", {**GTC, "selections": chosen}, at(19, 1))
    return h


def test_the_dishes_are_for_managers_and_a_span_has_to_make_sense():
    h = Hub()
    assert h.c.get("/reports/dishes").status_code == 401
    assert h.c.get("/reports/dishes", headers={"authorization": "Bearer nobody"}).status_code == 401
    for params in ({"from": "yesterday"}, {"to": "2026-02-30"}, {"from": "2026-11-16", "to": "2026-11-15"}):
        assert h.c.get("/reports/dishes", params=params, headers=h.manager()).status_code == 422, params
    long = h.c.get("/reports/dishes", params={"from": "2026-08-16", "to": "2026-11-16"}, headers=h.manager())
    assert long.status_code == 422 and long.json()["detail"]["error"] == "too_long"
    report = dishes(h, "2026-08-17", "2026-11-16")  # 92 days exactly
    assert report["max_days"] == MAX_DAYS and report["span"]["count"] == 0


def test_nothing_asked_is_the_running_day_beside_the_same_day_a_week_before():
    report = dishes(evening())
    assert (report["span"]["first"], report["span"]["last"], report["span"]["running"]) == (
        "2026-11-16",
        "2026-11-16",
        True,
    )
    assert (report["before"]["first"], report["before"]["last"]) == ("2026-11-09", "2026-11-09")
    assert dishes(evening(), "2026-11-15")["span"]["first"] == "2026-11-15"


def test_every_dish_sold_is_listed_most_sold_first_with_how_many_and_for_how_much():
    report = dishes(evening())
    rung = [(row["name"], row["count"], row["amount"]) for row in report["dishes"] if row["count"]]
    # the egg roll sent and voided is no sale, nor the soda on the check voided whole; the spring roll
    # nobody sent is on its check all the same
    assert rung == [
        ("Egg roll", 2, "7.00"),
        ("Pu Pu Platter", 1, "16.95"),
        ("Dragon roll", 1, "15.95"),
        ("Chicken wings", 1, "8.95"),
        ("Tsingtao", 1, "6.50"),
        ("Spring roll", 1, "3.25"),
    ]
    wings = dish(report, "Chicken wings")
    assert (wings["item"], wings["menu_name"], wings["category_name"], wings["on_menu"]) == (
        "WINGS",
        "Dinner",
        "Appetizers",
        True,
    )


def test_the_dishes_add_up_to_the_dishes_sold_of_the_sales_and_each_category_to_its_own():
    h = week_before(chicken_night(evening()))
    for first, last in ((None, None), ("2026-11-09", "2026-11-17"), ("2026-11-15", "2026-11-15")):
        report, the_sales = dishes(h, first, last), sales(h, first, last)
        for part in ("span", "before"):
            assert report[part]["amount"] == the_sales[part]["sales"]["gross"], (first, part)
            assert {key: report[part][key] for key in ("first", "last", "since_ms", "until_ms", "running")} == {
                key: the_sales[part][key] for key in ("first", "last", "since_ms", "until_ms", "running")
            }
        rows = report["dishes"]
        assert sum(row["count"] for row in rows) == report["span"]["count"]
        assert sum(money(row["amount"]) for row in rows) == money(report["span"]["amount"])
        assert sum(money(row["before_amount"]) for row in rows) == money(report["before"]["amount"])
        by_category = {(row["menu"], row["code"]): row for row in report["categories"]}
        for category in the_sales["span"]["categories"]:
            ours = by_category[(category["menu"], category["code"])]
            assert (ours["count"], ours["amount"]) == (category["count"], category["amount"]), category
        for category in report["categories"]:
            its = [row for row in rows if (row["menu"], row["category"]) == (category["menu"], category["code"])]
            assert category["dishes"] == len(its) and category["count"] == sum(row["count"] for row in its)
            assert money(category["amount"]) == sum(money(row["amount"]) for row in its)
            assert category["before_count"] == sum(row["before_count"] for row in its)


def test_a_dish_on_the_menu_that_sold_none_is_listed_too_so_worst_first_begins_with_it():
    report = dishes(evening())
    none = [row for row in report["dishes"] if row["count"] == 0]
    assert {"Soda", "Mai Tai", "General Tso's Chicken", "Combination Plate"} <= {row["name"] for row in none}
    assert all(row["on_menu"] and row["amount"] == "0.00" and row["options"] == [] for row in none)
    assert [row["count"] for row in report["dishes"]] == sorted(
        (row["count"] for row in report["dishes"]), reverse=True
    )
    assert [row["name"] for row in none] == sorted(row["name"] for row in none)  # by name where nothing tells
    # every dish the menu shows is there once, whatever menus it is on
    names = [row["name"] for row in report["dishes"]]
    assert len(names) == len(set(names)) == 19  # 21 lines on the two menus, two dishes on both
    drinks = next(row for row in report["categories"] if row["name"] == "Drinks")
    assert (drinks["dishes"], drinks["count"], drinks["amount"]) == (2, 0, "0.00")


def test_a_dish_lists_the_sizes_it_went_out_in_and_they_add_up_to_it():
    report = dishes(chicken_night())
    chicken = dish(report, "General Tso's Chicken")
    assert (chicken["count"], chicken["amount"]) == (4, "88.30")  # 2 x 25.95 (a dollar of rice), 13.95, 22.45
    assert sold(chicken["sizes"]) == [("", "Pint", 2, "36.40"), ("", "Quart", 2, "51.90")]
    assert sum(money(size["amount"]) for size in chicken["sizes"]) == money(chicken["amount"])
    h = evening()
    assert dish(dishes(h), "Chicken wings")["sizes"] == []  # a dish of one size has none to tell apart


def test_the_options_of_a_dish_say_how_it_went_out_how_many_times_and_what_they_added():
    chicken = dish(dishes(chicken_night()), "General Tso's Chicken")
    assert sold(chicken["options"]) == [
        # under each group in the order the dish asks them, the most picked first; what the dish comes
        # with (medium, white rice) counts like what was picked
        ("Spice level", "Extra spicy", 2, "0.00"),
        ("Spice level", "Medium", 2, "0.00"),
        ("Choice of rice", "Brown rice", 2, "2.00"),  # a dollar on each of two quarts
        ("Choice of rice", "No rice", 1, "0.00"),
        ("Choice of rice", "White rice", 1, "0.00"),
        ("Add-ons", "EXTRA Add shrimp", 1, "8.00"),  # the word in front is part of what it is
        ("Add-ons", "SIDE Extra sauce", 1, "0.50"),
    ]
    # what the options added is in the dish's money already: 4 dishes at their menu prices and 10.50 more
    assert money(chicken["amount"]) == 2 * money("24.95") + 2 * money("13.95") + money("10.50")


def test_a_choice_of_a_choice_stands_under_the_choice_it_belongs_to():
    h = Hub()
    h.table("p1", at(18), table="4")
    h.ring("p1", "L1", COMBO, at(18, 1), qty=3)  # as it comes: General Tso's, an egg roll, pork fried rice
    entree = picks(("entree_slot", "bb"))[0]
    spicy = picks(("entree_slot", "gtc"), children=picks(("spice", "extra"), ("addons", "shrimp")))[0]
    h.ring("p1", "L2", {**COMBO, "selections": [entree, *picks(("side_slot", "springroll"))]}, at(18, 2))
    h.ring("p1", "L3", {**COMBO, "selections": [spicy, *picks(("rice_slot", "brown"))]}, at(18, 3), qty=2)
    plate = dish(dishes(h), "Combination Plate")
    assert (plate["count"], plate["amount"]) == (6, "97.00")  # 6 x 14.50, and 2 x (4.00 shrimp + 1.00 rice)
    listed = sold(plate["options"])
    assert listed[:2] == [("Entree", "General Tso's Chicken", 5, "0.00"), ("Entree", "Beef with Broccoli", 1, "0.00")]
    assert ("General Tso's Chicken · Spice level", "Medium", 3, "0.00") in listed
    assert ("General Tso's Chicken · Spice level", "Extra spicy", 2, "0.00") in listed
    assert ("General Tso's Chicken · Add-ons", "Add shrimp", 2, "8.00") in listed
    assert ("Side", "Egg roll", 5, "0.00") in listed and ("Side", "Spring roll", 1, "0.00") in listed
    assert ("Rice", "Pork fried rice", 4, "0.00") in listed and ("Rice", "Brown rice", 2, "2.00") in listed
    groups = list(dict.fromkeys(group for group, *_ in listed))
    # the entree, then what was chosen on each entree, then the side and the rice
    assert groups[0] == "Entree" and groups[-2:] == ["Side", "Rice"]
    assert all(group.startswith(("General Tso's Chicken · ", "Beef with Broccoli · ")) for group in groups[1:-2])
    # the General Tso's inside a plate is the plate's option: no General Tso's was sold by itself
    assert dish(dishes(h), "General Tso's Chicken")["count"] == 0


def test_two_of_a_choice_on_each_dish_count_twice_each():
    h = Hub()
    h.table("q1", at(18), table="4")
    h.ring("q1", "L1", {**GTC, "selections": picks(("addons", "shrimp"), qty=2)}, at(18, 1), qty=3)
    line = h.c.get("/orders/q1").json()["lines"]["L1"]["priced"]
    assert [m["label"] for m in line["modifiers"] if m["option_id"] == "addons:shrimp"] == ["2x Add shrimp"]
    shrimp = next(row for row in dish(dishes(h), "General Tso's Chicken")["options"] if row["group"] == "Add-ons")
    # two on each of three dishes are six, by its name without the count, and 4.00 each
    assert (shrimp["name"], shrimp["count"], shrimp["amount"]) == ("Add shrimp", 6, "24.00")
    gone = load_definitions("restaurant")
    del gone.options["addons:shrimp"]  # no longer an option of the menu: by the name on its check
    monday = date(2026, 11, 16)
    report = straight(h, monday, monday, (date(2026, 11, 9), date(2026, 11, 9)), gone)
    assert ("Add-ons", "Add shrimp", 6, "24.00") in sold(dish(report, "General Tso's Chicken")["options"])


def test_the_days_before_stand_beside_each_dish_its_sizes_and_its_options():
    h = week_before(chicken_night(evening()))
    h.table("w3", at(20, day=9), table="6")
    h.ring("w3", "L1", {**GTC, "selections": picks(("rice", "brown"))}, at(20, 1, day=9), qty=3)
    report = dishes(h, "2026-11-16")
    wings, beer = dish(report, "Chicken wings"), dish(report, "Tsingtao")
    assert (wings["count"], wings["before_count"], wings["before_amount"]) == (1, 2, "17.90")
    assert (beer["count"], beer["before_count"]) == (1, 1)
    chicken = dish(report, "General Tso's Chicken")
    assert (chicken["count"], chicken["before_count"], chicken["before_amount"]) == (4, 3, "44.85")
    assert [(s["name"], s["count"], s["before_count"]) for s in chicken["sizes"]] == [("Pint", 2, 3), ("Quart", 2, 0)]
    rice = {row["name"]: (row["count"], row["before_count"]) for row in chicken["options"] if "rice" in row["group"]}
    assert rice == {"Brown rice": (2, 3), "No rice": (1, 0), "White rice": (1, 0)}
    assert (report["span"]["count"], report["before"]["count"]) == (11, 7)
    # the week before read on its own: the wings stand first, and nothing was sold the week before that
    earlier = dishes(h, "2026-11-09")
    assert [(row["name"], row["count"], row["before_count"]) for row in earlier["dishes"][:2]] == [
        ("General Tso's Chicken", 3, 0),
        ("Chicken wings", 2, 0),
    ]
    # a dish sold before and not now is in the list with nothing against it now
    h.table("w4", at(21, day=9), table="7")
    h.ring("w4", "L1", SODA, at(21, 1, day=9), qty=4)
    soda = dish(dishes(h, "2026-11-16"), "Soda")
    assert (soda["count"], soda["amount"], soda["before_count"], soda["before_amount"]) == (0, "0.00", 4, "11.80")


def test_a_span_of_days_adds_the_dishes_of_its_days_up():
    h = chicken_night(evening())
    h.table("t1", at(18, day=17), table="2")
    h.ring("t1", "L1", EGGROLL, at(18, 1, day=17), qty=3)
    h.ring("t1", "L2", PUPU, at(18, 2, day=17))
    two = dishes(h, "2026-11-16", "2026-11-17")
    # o6 was rung on the 16th for the 17th: its dishes are the 17th's
    monday, tuesday = dishes(h, "2026-11-16"), dishes(h, "2026-11-17")
    for name in ("Egg roll", "Pu Pu Platter", "General Tso's Chicken", "Tsingtao"):
        whole, parts = dish(two, name), (dish(monday, name), dish(tuesday, name))
        assert whole["count"] == sum(part["count"] for part in parts), name
        assert money(whole["amount"]) == sum(money(part["amount"]) for part in parts), name
    assert dish(two, "Egg roll")["count"] == 5 and two["before"]["first"] == "2026-11-09"


def typed_menu():
    defs = load_definitions("restaurant")
    defs.add(
        Item("OPEN", "entrees", {"en": "Open Food"}, attrs={"asks_name": True}),
        Variant("OPEN:regular", "OPEN", "regular", {"en": "Regular"}, price(0)),
        Entry("dinner:OPEN", "dinner", "dinner/chefs", "OPEN", "OPEN"),
    )
    return defs


def test_an_off_menu_dish_is_one_line_with_the_names_typed_for_it():
    h = Hub(defs=typed_menu())
    h.table("f1", at(18), table="4")
    h.ring("f1", "L1", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, at(18, 1), qty=2)
    h.ring("f1", "L2", {**OPEN, "price": "22", "name": "Lobster ginger scallion"}, at(18, 2))
    h.ring("f1", "L3", {**OPEN, "price": "9", "name": "Fried bananas"}, at(18, 3))
    open_food = dish(dishes(h), "Open Food")
    assert (open_food["count"], open_food["amount"], open_food["category_name"]) == (4, "68.00", "Entrees")
    assert open_food["typed"] == [
        {"name": "Lobster ginger scallion", "count": 3, "amount": "59.00"},
        {"name": "Fried bananas", "count": 1, "amount": "9.00"},
    ]
    assert open_food["sizes"] == [] and dish(dishes(h), "Egg roll")["typed"] == []


def straight(h: Hub, first: date, last: date, before: tuple[date, date], defs=None) -> dict:
    """The dishes of these days reckoned straight from every order in the log, nothing remembered."""
    state = h.c.app.state
    states = [h.store.view(o) for o in h.store.order_ids()]
    the_sales = [sale for sale in (sale_of(s, state.taxes, state.pricing) for s in states) if sale is not None]
    return dishes_report(the_sales, (first, last), before, defs=defs or state.menu.defs, now_ms=h.now)


def test_a_dish_is_called_what_the_menu_calls_it_today_and_one_gone_keeps_the_name_it_was_sold_under():
    h = chicken_night(evening())
    monday, before = date(2026, 11, 16), (date(2026, 11, 9), date(2026, 11, 9))
    today = load_definitions("restaurant")
    today.items["EGGROLL"] = replace(today.items["EGGROLL"], names={"en": "Crispy egg roll"})
    today.options["rice:brown"] = replace(today.options["rice:brown"], names={"en": "Whole-grain rice"})
    today.variants["GTC:quart"] = replace(today.variants["GTC:quart"], names={"en": "Large"})
    del today.items["WINGS"]
    del today.options["spice:extra"]
    del today.variants["GTC:pint"]
    today.entries[:] = [entry for entry in today.entries if entry.item not in ("WINGS", "TSINGTAO")]
    report = straight(h, monday, monday, before, today)
    assert dish(report, "Crispy egg roll")["count"] == 2
    wings = dish(report, "Chicken wings")  # no longer a dish of the menu: by the name on its check
    assert (wings["item"], wings["count"], wings["category_name"], wings["on_menu"]) == (
        None,
        1,
        "Off the menu now",
        False,
    )
    beer = dish(report, "Tsingtao")  # still a dish, on no menu: its sale is a sale all the same
    assert (beer["item"], beer["count"], beer["on_menu"]) == ("TSINGTAO", 1, False)
    chicken = dish(report, "General Tso's Chicken")
    assert [(size["name"], size["count"]) for size in chicken["sizes"]] == [("Large", 2), ("Pint", 2)]
    names = {(row["group"], row["name"]) for row in chicken["options"]}
    assert ("Choice of rice", "Whole-grain rice") in names and ("Spice level", "Extra spicy") in names
    assert sum(money(row["amount"]) for row in report["dishes"]) == money(report["span"]["amount"])
    # and off the menu, nothing sold: not listed
    gone = straight(Hub(), monday, monday, before, today)
    assert "Tsingtao" not in [row["name"] for row in gone["dishes"]]
    assert "Chicken wings" not in [row["name"] for row in gone["dishes"]]


def test_what_the_hub_remembers_reads_the_same_as_reckoned_straight_from_the_orders():
    h = week_before(chicken_night(evening()))
    for first, last in ((date(2026, 11, 16), date(2026, 11, 16)), (date(2026, 11, 9), date(2026, 11, 17))):
        asked = dishes(h, first.isoformat(), last.isoformat())  # the first reading replays every check
        again = dishes(h, first.isoformat(), last.isoformat())  # the second none of them
        before = (date.fromisoformat(asked["before"]["first"]), date.fromisoformat(asked["before"]["last"]))
        afresh = straight(h, first, last, before)
        for read in (asked, again):
            assert {key: read[key] for key in afresh} == afresh
    memo = h.c.app.state.sale_memo
    # every check keeps the one copy of a choice it shares with the others
    lines = [line for _, _, sale in memo._kept.values() if sale is not None for line in sale.lines]
    medium = [p for line in lines for p in line.picked if p.option == "spice:medium"]
    assert len(medium) > 1 and all(p is medium[0] for p in medium)
    # a dish changed on its check is read again
    h.ring("c1", "L9", BEER, at(21, 30), qty=2)
    assert dish(dishes(h, "2026-11-16"), "Tsingtao")["count"] == 3
    h.op("c1", "void_line", at(21, 31), line_id="L1", by="Mike", by_id="s3", reason="mistake")
    chicken = dish(dishes(h, "2026-11-16"), "General Tso's Chicken")
    assert chicken["count"] == 2 and [size["name"] for size in chicken["sizes"]] == ["Pint"]


def test_comps_and_discounts_do_not_change_what_a_dish_sold_for():
    h = evening()
    report = dishes(h)
    the_sales = sales(h)
    assert money(the_sales["span"]["sales"]["discounts"]) > 0  # the loyalty reward on o1
    assert money(report["span"]["amount"]) == money(the_sales["span"]["sales"]["gross"])
    assert dish(report, "Egg roll")["amount"] == str(2 * Decimal("3.50"))
    assert dish(report, "Chicken wings")["amount"] == "8.95" and WINGS["variant_id"] == "WINGS:6pc"


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_dishes_are_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(19, day=15), postgres=DSN)
    try:
        week_before(chicken_night(evening(h)))
        memory = week_before(chicken_night(evening()))
        for first, last in ((None, None), ("2026-11-09", "2026-11-17"), ("2026-11-15", "2026-11-15")):
            assert dishes(h, first, last) == dishes(memory, first, last)
            assert dishes(h, first, last) == dishes(memory, first, last)  # and again, from what is remembered
        assert dish(dishes(h), "General Tso's Chicken")["count"] == 4
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
