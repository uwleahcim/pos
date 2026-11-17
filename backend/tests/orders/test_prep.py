"""The prep list: a day's orders ahead added up, dish by dish, for each station that cooks them. These tests
read it for the week of `test_ahead.py` (taken on Monday the 16th), ring a few more dishes, and print it."""

from __future__ import annotations

from datetime import date

import pytest

from pos.menu import admin
from pos.menu.service import load_definitions
from pos.printing.prep import prep_list

from ..printing.fake_printer import decode
from ..printing.test_stations import TAKE_OUT_CHOICE, TAKEOUT
from .test_ahead import later, week
from .test_day import BEER, DSN, PUPU, WINGS, Hub, at
from .test_menu_orders import GTC_QUART

SATURDAY = "2026-11-21"
PLAIN = {"variant_id": "GTC:quart", "entry_id": "dinner:87", "selections": []}


def prep(h: Hub, day: str | None = SATURDAY) -> dict:
    answer = h.c.get("/orders/ahead/prep", params={"day": day} if day else {})
    assert answer.status_code == 200, answer.text
    return answer.json()


def rows(h: Hub, station: str, day: str = SATURDAY) -> list[tuple[int, str, str]]:
    """What one station makes for the day: how many, of what, and the combination a part belongs to."""
    found = [s for s in prep(h, day)["stations"] if s["station"] == station]
    return [(row["qty"], row["label"], row["header"]) for s in found for row in s["rows"]]


def test_a_days_dishes_are_added_up_for_each_station():
    h = week()
    cursor = h.store.cursor
    saturday = prep(h)
    assert h.store.cursor == cursor  # reading changes nothing
    assert (saturday["day"], saturday["today"]) == (SATURDAY, "2026-11-16")
    assert saturday["orders"] == [
        {
            "order_id": "c1",
            "order_no": 1,
            "customer_name": "Chen",
            "channel": "catering",
            "promised_ms": at(12, day=21),
            "guests": 30,
            "handover": "delivery",
            "dishes": 5,
            "unsent": 0,
        },
        {
            "order_id": "c2",
            "order_no": 2,
            "customer_name": "Park",
            "channel": "catering",
            "promised_ms": at(18, day=21),
            "guests": 8,
            "handover": "pickup",
            "dishes": 1,
            "unsent": 0,
        },
    ]
    # six dishes rung in on two orders: Chen's two platters and three wings, Park's platter
    assert (saturday["count"], saturday["guests"], saturday["dishes"], saturday["unsent"]) == (2, 38, 6, 0)
    assert [(s["station"], s["name"]) for s in saturday["stations"]] == [("fryer", "Fryer")]
    # in the kitchen's own words, each platter with its parts: three platters, and the wings ordered alone
    assert rows(h, "fryer") == [(3, "宝宝盘", ""), (3, "蛋卷", "4 宝宝盘"), (3, "鸡翅", ""), (3, "鸡翅", "4 宝宝盘")]
    # by when the first of each: Chen's at noon, though Park's platter is for six
    assert {row["first_ms"] for row in saturday["stations"][0]["rows"]} == {at(12, day=21)}


def test_the_running_day_when_no_day_is_asked_and_what_nobody_sent():
    h = week()
    today = prep(h, None)
    assert today["day"] == "2026-11-16" and [o["order_id"] for o in today["orders"]] == ["p1"]
    # Lee's wings are on the order and nobody sent them: they count, and the list says so
    assert (today["dishes"], today["unsent"]) == (1, 1)
    assert rows(h, "fryer", "2026-11-16") == [(1, "鸡翅", "")]
    assert h.c.get("/orders/ahead/prep", params={"day": "Saturday"}).status_code == 422


def test_only_the_orders_ahead_count():
    h = week()
    # Sunday's order was voided whole, Friday's was handed over; a table and an order for now name no time
    for day in ("2026-11-22", "2026-11-20", "2026-11-17"):
        empty = prep(h, day)
        assert (empty["orders"], empty["stations"], empty["dishes"]) == ([], [], 0)
    # a dish taken off is not made; a closed order still is, until its time has passed
    h.op("c1", "void_line", at(18), line_id="L2", reason="guest-changed-mind")
    assert rows(h, "fryer") == [(3, "宝宝盘", ""), (3, "蛋卷", "4 宝宝盘"), (3, "鸡翅", "4 宝宝盘")]
    h.now = at(19, day=21)  # Saturday evening: Park's, paid and closed, was for six; Chen's is late and open
    assert [o["order_id"] for o in prep(h)["orders"]] == ["c1"]


def test_the_same_dish_wanted_another_way_stands_under_its_row():
    h = Hub(now=at(17))
    later(h, "c1", at(17), "Chen", at(12, day=21))
    h.ring("c1", "L1", PLAIN, at(17, 1), qty=6)
    h.ring("c1", "L2", GTC_QUART, at(17, 2), qty=2)  # extra spicy, brown rice
    later(h, "c2", at(17, 3), "Park", at(18, day=21))
    h.ring("c2", "L1", GTC_QUART, at(17, 4))
    h.op("c2", "add_line", at(17, 5), line_id="L2", item="?", qty=1, request={**PLAIN, "qty": 1}, note="no onions")
    h.ring("c2", "L3", BEER, at(17, 6), qty=4)
    wok, bar = prep(h)["stations"]
    assert (wok["station"], bar["station"]) == ("wok", "bar")  # in the order the menu lists its stations
    (chicken,) = wok["rows"]
    assert chicken["qty"] == 10 and chicken["first_ms"] == at(12, day=21)
    # six are plain and say nothing; three are wanted one way and one another
    assert [(way["qty"], way["note"], len(way["choices"])) for way in chicken["ways"]] == [
        (3, "", 2),
        (1, "no onions", 0),
    ]
    assert [(row["qty"], row["label"], row["ways"]) for row in bar["rows"]] == [(4, "Tsingtao", [])]


def test_the_takeout_station_packs_and_does_not_cook():
    # a menu where the Extra spicy choice also sends the dish to the takeout station
    h = Hub(now=at(17), defs=admin.apply(load_definitions("restaurant"), [TAKEOUT, TAKE_OUT_CHOICE]))
    later(h, "c1", at(17), "Chen", at(12, day=21))
    h.ring("c1", "L1", GTC_QUART, at(17, 1), qty=2)
    state = h.store.view("c1")
    assert {k["station"] for k in state.lines["L1"].priced["kitchen"]} == {"wok", "takeout"}
    # the wok makes it; the takeout station's copy of it is not a second dish to make
    assert [(s["station"], [row["qty"] for row in s["rows"]]) for s in prep(h)["stations"]] == [("wok", [2])]
    # a dish nothing but the takeout station has stays under it: it has to stand somewhere
    alone = prep_list([state], date(2026, 11, 21), now_ms=h.now, takeout="wok")
    assert [(s["station"], s["name"]) for s in alone["stations"]] == [("takeout", "takeout")]


def test_the_list_on_paper():
    h = week()
    later(h, "p9", at(17, 40), "Ann", at(12, day=21), channel="phone")
    h.ring("p9", "L1", BEER, at(17, 41), qty=2)  # not sent
    answer = h.c.post("/orders/ahead/prep/print", json={"day": SATURDAY})
    assert answer.status_code == 202, answer.text
    assert answer.json()["day"] == SATURDAY and answer.json()["printed_at"] == {"id": "front", "name": "takeout"}
    paper = decode(h.printing.store.get(answer.json()["job_id"]).data)
    text = [line.strip() for line in paper.text]
    assert text[:3] == ["PREP LIST", "Saturday, November 21, 2026", "3 orders, 38 guests, 8 dishes"]
    assert paper.inverted == ["2 DISHES NOT SENT TO THE KITCHEN"]
    orders = text[text.index("THE ORDERS") + 1 :][:3]
    assert [" ".join(line.split()) for line in orders] == [
        "12:00 #1 Chen, 30 guests, delivery 5 dishes",
        "12:00 #7 Ann 2 dishes",  # the seventh to-go order of the week
        "18:00 #2 Park, 8 guests, pickup 1 dish",
    ]
    # the bar in letters, with by when; the fryer's dishes as the kitchen reads them, drawn
    assert " ".join(text[text.index("BAR") + 1].split()) == "2 x Tsingtao by 12:00"
    assert "FRYER" in text and len(paper.images) >= 4 and paper.cuts == 1


def test_printing_needs_a_dish_and_a_printer():
    h = week()
    nothing = h.c.post("/orders/ahead/prep/print", json={"day": "2026-11-22"})
    assert nothing.status_code == 409 and nothing.json()["detail"]["error"] == "nothing_to_prep"
    bare = week(Hub(now=at(17), printers=False))
    refused = bare.c.post("/orders/ahead/prep/print", json={"day": SATURDAY})
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_printer"
    # with one time for the whole day, no dish says by when: the head of the list does
    h.op("c2", "set_field", at(18), promised_at=at(12, day=21))
    again = h.c.post("/orders/ahead/prep/print", json={"day": SATURDAY, "printer": "front"})
    paper = decode(h.printing.store.get(again.json()["job_id"]).data)
    assert not any("by 12:00" in line for line in paper.text)


def test_a_platter_counts_once_among_the_dishes_and_wings_add_up_across_orders():
    h = week()
    later(h, "c5", at(17, 40), "Wu", at(13, day=21))
    h.ring("c5", "L1", WINGS, at(17, 41), qty=4)
    h.ring("c5", "L2", PUPU, at(17, 42))
    saturday = prep(h)
    assert saturday["dishes"] == 11 and saturday["count"] == 3
    assert rows(h, "fryer") == [(4, "宝宝盘", ""), (4, "蛋卷", "4 宝宝盘"), (7, "鸡翅", ""), (4, "鸡翅", "4 宝宝盘")]


@pytest.mark.skipif(not DSN, reason="POS_TEST_DATABASE_URL not set")
def test_the_prep_list_on_postgres():
    h = week(Hub(now=at(17), postgres=DSN))
    saturday = prep(h)
    assert (saturday["count"], saturday["dishes"]) == (2, 6)
    assert rows(h, "fryer") == [(3, "宝宝盘", ""), (3, "蛋卷", "4 宝宝盘"), (3, "鸡翅", ""), (3, "鸡翅", "4 宝宝盘")]
