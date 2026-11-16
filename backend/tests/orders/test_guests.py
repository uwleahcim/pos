"""The guest list: every customer who ordered with a phone number, read from a year of their orders.

How often each came, what they spent, when they were last here and what they order most, with the regulars,
the guests who stopped coming and the new ones picked out. These tests ring orders over the year before
Monday the 16th of November 2026 through the hub the way the screens do, and read what a manager gets."""

from __future__ import annotations

from dataclasses import replace
from datetime import date, datetime, timedelta
from decimal import Decimal

import pytest

from pos import localtime
from pos.orders.guests import (
    LAPSED_DAYS,
    LOOK_BACK_DAYS,
    NEW_DAYS,
    REGULAR_DAYS,
    REGULAR_VISITS,
    guest_report,
    guests_report,
    visit_of,
)

from .test_day import BEER, DRAGON, DSN, EGGROLL, PUPU, SODA, WINGS, Hub, at, money
from .test_dishes import GTC, OPEN, typed_menu

TODAY = date(2026, 11, 16)
LINDA, OMAR, PRIYA, SAM, TESS = "7815550101", "7815550102", "7815550103", "7815550104", "7815550105"


def ago(days: int, hour: int = 18, minute: int = 0) -> int:
    """That time of the day `days` before the 16th, on the restaurant's own clock, as wall-clock ms."""
    day = TODAY - timedelta(days=days)
    return int(datetime(day.year, day.month, day.day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


def order(h: Hub, order_id: str, when: int, phone: str, name: str, *dishes: dict | tuple[dict, int], **fields) -> None:
    """A to-go order from this number with these dishes (a dish, or a dish and how many)."""
    h.to_go(order_id, when, name=name, phone=phone, **fields)
    for i, rung in enumerate(dishes, 1):
        request, qty = rung if isinstance(rung, tuple) else (rung, 1)
        h.ring(order_id, f"L{i}", request, when + i * 60_000, qty=qty)


def guests(h: Hub) -> dict:
    answer = h.c.get("/reports/guests", headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def guest(report: dict, phone: str) -> dict:
    return next(row for row in report["guests"] if row["phone"] == phone)


def one(h: Hub, phone: str) -> dict:
    answer = h.c.get(f"/reports/guests/{phone}", headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def a_year(h: Hub | None = None) -> Hub:
    """Read on Monday the 16th at nine in the evening:

    - Linda: five orders, the last three within the month. General Tso's every time.
    - Omar: four orders last winter and spring, none since April.
    - Priya: three orders in early September, the last 61 days ago.
    - Sam: his first order ever ten days ago, and one more yesterday.
    - Tess: one order fourteen months ago and one last week.
    """
    h = h or Hub()
    order(h, "l1", ago(200), LINDA, "Linda Park", GTC, EGGROLL)
    order(h, "l2", ago(120), "+1 (781) 555-0101", "Linda Park", (GTC, 2))
    order(h, "l3", ago(30), "781 555 0101", "Linda", GTC, (EGGROLL, 2), BEER)
    order(h, "l4", ago(12), LINDA, "", GTC, WINGS)
    order(h, "l5", ago(2), LINDA, "Linda P.", GTC)
    for i, days in enumerate((330, 300, 260, 215), 1):
        order(h, f"m{i}", ago(days), OMAR, "Omar", PUPU, DRAGON)
    for i, days in enumerate((80, 70, 61), 1):
        order(h, f"p{i}", ago(days), PRIYA, "Priya", WINGS)
    order(h, "s1", ago(10), SAM, "Sam", DRAGON)
    order(h, "s2", ago(1), SAM, "Sam", DRAGON, SODA)
    order(h, "t1", ago(420), TESS, "Tess", PUPU)
    order(h, "t2", ago(7), TESS, "Tess", EGGROLL)
    return h


def test_the_guest_list_is_for_managers():
    h = a_year()
    for path in ("/reports/guests", f"/reports/guests/{LINDA}"):
        assert h.c.get(path).status_code == 401
        assert h.c.get(path, headers={"authorization": "Bearer nobody"}).status_code == 401


def test_the_list_reads_a_year_and_says_what_its_words_mean():
    report = guests(a_year())
    assert (report["first"], report["last"], report["days"]) == ("2025-11-17", "2026-11-16", LOOK_BACK_DAYS)
    assert (report["regular_visits"], report["regular_days"], report["lapsed_days"], report["new_days"]) == (
        REGULAR_VISITS,
        REGULAR_DAYS,
        LAPSED_DAYS,
        NEW_DAYS,
    )
    assert (REGULAR_VISITS, REGULAR_DAYS, LAPSED_DAYS, NEW_DAYS, LOOK_BACK_DAYS) == (3, 90, 60, 30, 365)


def test_a_guest_is_a_number_with_how_often_they_came_what_they_spent_and_when():
    h = a_year()
    linda = guest(guests(h), LINDA)
    # 13.95 + 3.50, 27.90, 13.95 + 7.00 + 6.50, 13.95 + 8.95, 13.95: however the number was written
    assert (linda["visits"], linda["spent"], linda["per_visit"]) == (5, "109.65", "21.93")
    assert (linda["last"], linda["first"]) == ("2026-11-14", "2026-04-30")
    assert (linda["orders_ever"], linda["since_ms"]) == (5, ago(200))
    assert linda["name"] == "Linda P."  # the name on their latest order that has one
    assert linda["lately"] == 3
    # what their checks came to before tax: the net of each
    nets = [money(h.check(o)["subtotal"]) - money(h.check(o)["discount_total"]) for o in ("l1", "l2", "l3", "l4", "l5")]
    assert money(linda["spent"]) == sum(nets)


def test_the_guests_are_listed_the_one_who_spent_most_first_and_the_list_adds_up():
    report = guests(a_year())
    rows = [(row["name"], row["visits"], row["spent"]) for row in report["guests"]]
    assert rows == [
        ("Omar", 4, "131.60"),
        ("Linda P.", 5, "109.65"),
        ("Sam", 2, "34.85"),
        ("Priya", 3, "26.85"),
        ("Tess", 1, "3.50"),
    ]
    totals = report["totals"]
    assert (totals["guests"], totals["visits"], totals["spent"]) == (5, 15, "306.45")
    assert money(totals["spent"]) == sum(money(row["spent"]) for row in report["guests"])
    assert totals["per_visit"] == "20.43"
    assert (totals["regulars"], totals["lapsed"], totals["new"]) == (1, 2, 1)


def test_their_favourite_dishes_are_the_ones_they_ordered_most():
    h = a_year()
    linda = guest(guests(h), LINDA)
    assert linda["favourites"] == [
        {"item": "GTC", "name": "General Tso's Chicken", "count": 6},
        {"item": "EGGROLL", "name": "Egg roll", "count": 3},
        {"item": "WINGS", "name": "Chicken wings", "count": 1},  # as many as the beer: by name then
    ]
    # the list carries three; the guest read alone carries them all
    assert [row["name"] for row in one(h, LINDA)["guest"]["favourites"]] == [
        "General Tso's Chicken",
        "Egg roll",
        "Chicken wings",
        "Tsingtao",
    ]


def test_regulars_guests_who_stopped_coming_and_new_ones_are_picked_out():
    report = guests(a_year())
    said = {row["name"]: (row["regular"], row["lapsed"], row["new"]) for row in report["guests"]}
    assert said == {
        "Linda P.": (True, False, False),  # three visits in the last 90 days
        "Omar": (False, True, False),  # four in the year, none for 60 days
        "Priya": (False, True, False),  # three in the last 90 days, but the last 61 days ago: stopped coming
        "Sam": (False, False, True),  # his first order ever was ten days ago
        "Tess": (False, False, False),  # one visit this year, and a guest since last year
    }
    assert guest(report, PRIYA)["lately"] == 3 and guest(report, OMAR)["lately"] == 0


def test_the_days_that_draw_the_lines():
    h = Hub()
    for i, days in enumerate((REGULAR_DAYS - 1, 59, 59), 1):
        order(h, f"a{i}", ago(days, minute=i), LINDA, "A", EGGROLL)  # the third 59 days ago: still coming
    for i, days in enumerate((REGULAR_DAYS, 60, 60), 1):
        order(h, f"b{i}", ago(days, minute=i), OMAR, "B", EGGROLL)  # one 90 days ago is not of the last 90
    order(h, "c1", ago(NEW_DAYS - 1), PRIYA, "C", EGGROLL)
    order(h, "d1", ago(NEW_DAYS), SAM, "D", EGGROLL)
    order(h, "e1", ago(LOOK_BACK_DAYS - 1), TESS, "E", EGGROLL)  # the first day the list reads
    order(h, "f1", ago(LOOK_BACK_DAYS), "7815550199", "F", EGGROLL)  # the day before it
    report = guests(h)
    a, b = guest(report, LINDA), guest(report, OMAR)
    assert (a["lately"], a["regular"], a["lapsed"]) == (3, True, False)
    assert (b["lately"], b["regular"], b["lapsed"]) == (2, False, True)
    assert (guest(report, PRIYA)["new"], guest(report, SAM)["new"]) == (True, False)
    assert guest(report, TESS)["last"] == "2025-11-17"
    assert "7815550199" not in [row["phone"] for row in report["guests"]]


def test_since_when_and_how_many_orders_ever_look_past_the_year():
    h = a_year()
    tess = guest(guests(h), TESS)
    assert (tess["visits"], tess["spent"], tess["first"], tess["last"]) == (1, "3.50", "2026-11-09", "2026-11-09")
    assert (tess["orders_ever"], tess["since_ms"], tess["new"]) == (2, ago(420), False)
    # what the to-go form says of the same caller
    card = h.c.get("/customers/lookup", params={"phone": TESS}).json()
    assert (card["orders"], card["first_ms"]) == (tess["orders_ever"], tess["since_ms"])


def test_what_is_no_visit():
    h = a_year()
    before = guests(h)
    h.to_go("x1", ago(3), name="Linda", phone=LINDA)  # opened and left empty
    order(h, "x2", ago(3), LINDA, "Linda", PUPU)
    h.op("x2", "void_order", ago(3, minute=30))  # voided whole
    order(h, "x3", ago(3), "5551", "Short", PUPU)  # an extension, not a customer's number
    order(h, "x4", ago(3), "", "Walk-in", PUPU)  # no number at all
    h.table("x5", ago(3), table="4")  # a table has no number
    h.ring("x5", "L1", PUPU, ago(3, minute=1))
    h.to_go("x6", ago(3), name="Nobody yet", phone="7815550177")  # a number with nothing but an empty order
    after = guests(h)
    assert after["totals"] == before["totals"]
    linda = guest(after, LINDA)
    assert (linda["visits"], linda["spent"]) == (5, "109.65")
    assert linda["orders_ever"] == 6  # the empty one is an order, as on the to-go form; the voided one is not
    assert "7815550177" not in [row["phone"] for row in after["guests"]]
    # a dish voided is not in what they spent, nor a favourite
    h.op("l5", "fire", ago(2, minute=5))
    h.ring("l5", "L7", DRAGON, ago(2, minute=6))
    h.op("l5", "fire", ago(2, minute=7))
    h.op("l5", "void_line", ago(2, minute=8), line_id="L7", reason="kitchen-error", by="Amy")
    linda = guest(guests(h), LINDA)
    assert linda["spent"] == "109.65"
    assert "Dragon roll" not in [row["name"] for row in one(h, LINDA)["guest"]["favourites"]]


def test_comps_and_discounts_come_off_what_a_guest_spent():
    h = a_year()
    h.op("s2", "discount", ago(1, minute=10), discount_id="D1", reason="loyalty", kind="amount", value="2.00")
    sam = guest(guests(h), SAM)
    assert sam["spent"] == "32.85" and money(sam["spent"]) == Decimal("15.95") * 2 + Decimal("2.95") - 2


def test_an_order_for_a_later_day_is_a_visit_once_that_day_has_come():
    h = a_year()
    # rung four days ago for Wednesday the 18th
    wednesday = int(datetime(2026, 11, 18, 18, tzinfo=localtime.zone()).timestamp() * 1000)
    order(h, "c1", ago(4), PRIYA, "Priya", (PUPU, 3), promised_at=wednesday)
    priya = guest(guests(h), PRIYA)
    assert (priya["visits"], priya["last"], priya["lapsed"]) == (3, "2026-09-16", True)
    assert priya["orders_ever"] == 4
    h.now = wednesday + 60_000
    priya = guest(guests(h), PRIYA)
    assert (priya["visits"], priya["last"], priya["spent"]) == (4, "2026-11-18", "77.70")
    assert (priya["lapsed"], priya["regular"]) == (False, True)
    # one rung before the year began for a day inside it counts on that day
    inside = ago(LOOK_BACK_DAYS - 5)
    order(h, "c2", ago(LOOK_BACK_DAYS + 20), OMAR, "Omar", PUPU, promised_at=inside)
    h.now = at(21)
    omar = guest(guests(h), OMAR)
    assert (omar["visits"], omar["first"]) == (5, "2025-11-21")


def test_the_note_about_a_customer_stands_beside_them():
    h = a_year()
    saved = h.c.put(f"/customers/{LINDA}", json={"note": "no MSG, side door", "by": "Amy"})
    assert saved.status_code == 200, saved.text
    h.c.put(f"/customers/{OMAR}", json={"note": "", "by": "Amy"})
    report = guests(h)
    assert guest(report, LINDA)["note"] == "no MSG, side door"
    assert guest(report, OMAR)["note"] == "" and guest(report, SAM)["note"] == ""
    close = one(h, LINDA)
    assert (close["guest"]["note"], close["note_by"], close["note_ms"]) == ("no MSG, side door", "Amy", h.now)
    assert (one(h, OMAR)["note_by"], one(h, OMAR)["note_ms"]) == ("Amy", None)


def test_one_guest_read_closely_lists_their_latest_visits_with_the_dishes():
    h = a_year()
    close = one(h, "+1 (781) 555-0101")  # however the number is written
    assert close["guest"] == {**guest(guests(h), LINDA), "favourites": close["guest"]["favourites"]}
    assert [(visit["order_id"], visit["day"], visit["kind"], visit["net"]) for visit in close["latest"]] == [
        ("l5", "2026-11-14", "takeout", "13.95"),
        ("l4", "2026-11-04", "takeout", "22.90"),
        ("l3", "2026-10-17", "takeout", "27.45"),
        ("l2", "2026-07-19", "takeout", "27.90"),
        ("l1", "2026-04-30", "takeout", "17.45"),
    ]
    assert close["latest"][2]["dishes"] == [
        {"item": "EGGROLL", "name": "Egg roll", "count": 2},
        {"item": "GTC", "name": "General Tso's Chicken", "count": 1},
        {"item": "TSINGTAO", "name": "Tsingtao", "count": 1},
    ]
    assert close["latest"][0]["opened_ms"] == ago(2)
    # nobody by that number, or nobody this year
    for nobody in ("7815550000", "12", "none"):
        answer = h.c.get(f"/reports/guests/{nobody}", headers=h.manager())
        assert answer.status_code == 404 and answer.json()["detail"]["error"] == "no_guest", nobody
    h2 = Hub()
    order(h2, "t1", ago(420), TESS, "Tess", PUPU)
    assert h2.c.get(f"/reports/guests/{TESS}", headers=h2.manager()).status_code == 404
    assert guests(h2)["guests"] == []


def test_a_guest_lists_only_their_ten_latest_visits():
    h = Hub()
    for i in range(12):
        order(h, f"v{i}", ago(i + 1), LINDA, "Linda", EGGROLL)
    close = one(h, LINDA)
    assert close["guest"]["visits"] == 12
    assert [visit["order_id"] for visit in close["latest"]] == [f"v{i}" for i in range(10)]


def test_dishes_are_called_what_the_menu_calls_them_today_and_a_typed_dish_what_was_typed():
    h = Hub(defs=typed_menu())
    order(h, "o1", ago(5), LINDA, "Linda", EGGROLL, WINGS)
    h.ring("o1", "L8", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, ago(5, minute=9), qty=2)
    order(h, "o2", ago(3), LINDA, "Linda", (WINGS, 2))
    state = h.c.app.state
    visits = [visit_of(h.store.view(o), state.taxes, state.pricing) for o in ("o1", "o2")]
    entries = h.store.with_phone()
    today = typed_menu()
    today.items["EGGROLL"] = replace(today.items["EGGROLL"], names={"en": "Crispy egg roll"})
    del today.items["WINGS"]
    report = guests_report(visits, entries, {}, defs=today, now_ms=h.now)
    assert report["guests"][0]["favourites"] == [
        {"item": None, "name": "Chicken wings", "count": 3},  # gone from the menu: the name it was sold under
        {"item": None, "name": "Lobster ginger scallion", "count": 2},  # typed in: the name that was typed
        {"item": "EGGROLL", "name": "Crispy egg roll", "count": 1},
    ]
    assert report["guests"][0]["spent"] == "67.35"  # 3.50 + 8.95 + 37.00 + 17.90


def straight(h: Hub) -> dict:
    """The list reckoned straight from every order in the log, nothing remembered."""
    state = h.c.app.state
    visits = [visit_of(h.store.view(o), state.taxes, state.pricing) for o in h.store.order_ids()]
    return guests_report(
        [visit for visit in visits if visit is not None],
        h.store.with_phone(),
        state.customers.all(),
        defs=state.menu.defs,
        now_ms=h.now,
    )


def test_what_the_hub_remembers_reads_the_same_as_reckoned_straight_from_the_orders():
    h = a_year()
    asked, again = guests(h), guests(h)  # the first reading replays every order, the second none
    assert asked == again == straight(h)
    memo = h.c.app.state.visit_memo
    assert len(memo) == 15  # every order of the year with a number; the one of fourteen months ago was not read
    # an order that changed is read again
    h.ring("l5", "L9", BEER, ago(2, minute=20), qty=2)
    linda = guest(guests(h), LINDA)
    assert (linda["spent"], linda["favourites"][-1]) == ("122.65", {"item": "TSINGTAO", "name": "Tsingtao", "count": 3})
    assert guests(h) == straight(h)
    state = h.c.app.state
    close = guest_report(
        LINDA,
        [visit_of(h.store.view(o), state.taxes, state.pricing) for o in ("l1", "l2", "l3", "l4", "l5")],
        h.store.index(phone=LINDA),
        None,
        defs=state.menu.defs,
        now_ms=h.now,
    )
    assert close == one(h, LINDA)


def test_every_order_with_a_number_is_found_however_old():
    h = a_year()
    found = h.store.with_phone()
    assert len(found) == 16 and [entry.order_id for entry in found] == sorted(entry.order_id for entry in found)
    h.table("x1", ago(1), table="4")
    assert len(h.store.with_phone()) == 16
    assert {entry.phone for entry in found} == {LINDA, OMAR, PRIYA, SAM, TESS}


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_guest_list_is_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(postgres=DSN)
    try:
        a_year(h)
        h.table("x1", ago(1), table="4")
        h.ring("x1", "L1", PUPU, ago(1, minute=1))
        memory = a_year()
        assert guests(h) == guests(memory)
        assert guests(h) == guests(memory)  # and again, from what is remembered
        assert one(h, LINDA) == one(memory, LINDA)
        assert [entry.order_id for entry in h.store.with_phone()] == [e.order_id for e in memory.store.with_phone()]
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
