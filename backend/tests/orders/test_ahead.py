"""The orders ahead: what was promised for a time still to come, by the day it is for, with what was paid on
each. These tests take catering and phone orders through the hub the way the screens do, on Monday the 16th,
and read the list as the week goes on."""

from __future__ import annotations

from decimal import Decimal

import pytest

from .test_day import BEER, DSN, PUPU, WINGS, Hub, at

SATURDAY_NOON = at(12, day=21)


def ahead(h: Hub) -> dict:
    answer = h.c.get("/orders/ahead")
    assert answer.status_code == 200, answer.text
    return answer.json()


def days(h: Hub) -> list[tuple[str, list[str]]]:
    """Each day on the list with its orders, in the order the list has them."""
    return [(day["day"], [row["order_id"] for row in day["orders"]]) for day in ahead(h)["days"]]


def later(h: Hub, order_id: str, when: int, name: str, promised: int, *, channel: str = "catering", **more) -> None:
    """An order the customer named a time for, as the form opens it."""
    lead = 60 if channel == "catering" else 20
    h.op(
        order_id,
        "create",
        when,
        order_type="takeout",
        customer_name=name,
        channel=channel,
        promised_at=promised,
        quoted_minutes=lead,
        for_later=True,
        **more,
    )


def week(h: Hub | None = None) -> Hub:
    """Monday the 16th at five in the afternoon:

    - c1, Chen's catering for Saturday noon: 30 guests, delivered, two platters and three wings (65.01 with
      tax), sent, 20.00 paid as a deposit.
    - c2, Park's catering for Saturday at six, picked up: one platter (18.14), paid in full and closed.
    - p1, Lee's phone order for tonight at seven: wings, not sent yet.
    - p2, a phone order for now; t1, a table. Neither names a time.
    - c3 for Sunday, voided whole; c4 for Friday, handed over already."""
    h = h or Hub(now=at(17))
    later(
        h,
        "c1",
        at(17),
        "Chen",
        SATURDAY_NOON,
        phone="781 555 0101",
        event_guests=30,
        handover="delivery",
        address="12 Main St,  Winchester",
        event_note="Set up by 11:30, side door",
    )
    h.ring("c1", "L1", PUPU, at(17, 1), qty=2)
    h.ring("c1", "L2", WINGS, at(17, 2), qty=3)
    h.op("c1", "fire", at(17, 3), course="*")
    h.pay("c1", at(17, 4), "20.00")
    later(h, "c2", at(17, 5), "Park", at(18, day=21), handover="pickup", event_guests=8)
    h.ring("c2", "L1", PUPU, at(17, 6))
    h.op("c2", "fire", at(17, 7), course="*")
    h.pay("c2", at(17, 8), "18.14", "elsewhere")
    h.op("c2", "close", at(17, 9))
    later(h, "p1", at(17, 10), "Lee", at(19), channel="phone")
    h.ring("p1", "L1", WINGS, at(17, 11))
    h.to_go("p2", at(17, 12), "Ann")
    h.ring("p2", "L1", BEER, at(17, 13))
    h.table("t1", at(17, 14))
    h.ring("t1", "L1", BEER, at(17, 15))
    later(h, "c3", at(17, 16), "Gone", at(12, day=22))
    h.ring("c3", "L1", PUPU, at(17, 17))
    h.op("c3", "void_order", at(17, 18))
    later(h, "c4", at(17, 19), "Early", at(12, day=20))
    h.ring("c4", "L1", PUPU, at(17, 20))
    h.op("c4", "fire", at(17, 21), course="*")
    h.op("c4", "set_field", at(17, 22), stage="picked_up")
    h.op("c4", "close", at(17, 23))
    h.now = at(17, 30)
    return h


def test_the_orders_ahead_stand_by_the_day_they_are_for():
    h = week()
    cursor = h.store.cursor
    answer = ahead(h)
    assert answer["today"] == "2026-11-16"
    assert days(h) == [("2026-11-16", ["p1"]), ("2026-11-21", ["c1", "c2"])]
    assert h.store.cursor == cursor  # reading changes nothing
    saturday = answer["days"][1]
    chen, park = saturday["orders"]
    assert chen == {
        "order_id": "c1",
        "order_no": 1,
        "customer_name": "Chen",
        "phone": "781 555 0101",
        "channel": "catering",
        "promised_ms": SATURDAY_NOON,
        "quoted_minutes": 60,
        "guests": 30,
        "handover": "delivery",
        "address": "12 Main St, Winchester",  # on one line, however it was typed
        "event_note": "Set up by 11:30, side door",
        "status": "open",
        "stage": "new",
        "dishes": 5,
        "unsent": 0,
        "items": [{"name": "Pu Pu Platter", "qty": 2}, {"name": "Chicken wings", "qty": 3}],
        "total": "65.01",
        "paid": "20.00",
        "due": "45.01",
        "opened_ms": at(17),
    }
    # the money is the check's own, to the cent
    assert (chen["total"], chen["paid"], chen["due"]) == tuple(h.check("c1")[k] for k in ("total", "paid", "due"))
    # paid in full on Monday and closed: still Saturday's food
    assert (park["status"], park["handover"], park["guests"]) == ("closed", "pickup", 8)
    assert (park["total"], park["paid"], park["due"]) == ("18.14", "18.14", "0.00")
    # the day adds its orders up
    day = {k: v for k, v in saturday.items() if k != "orders"}
    assert day == {
        "day": "2026-11-21",
        "count": 2,
        "guests": 38,
        "unsent": 0,
        "total": "83.15",
        "paid": "38.14",
        "due": "45.01",
    }
    # tonight's phone order: nobody sent it, so no ticket will print for it
    tonight = answer["days"][0]
    assert (tonight["unsent"], tonight["orders"][0]["unsent"], tonight["orders"][0]["dishes"]) == (1, 1, 1)
    assert (tonight["orders"][0]["guests"], tonight["orders"][0]["handover"], tonight["guests"]) == (None, None, 0)


def test_anyone_at_a_terminal_reads_it_and_an_empty_week_is_an_empty_list():
    h = Hub(now=at(17))
    assert h.c.get("/orders/ahead").json() == {"today": "2026-11-16", "days": []}


def test_an_order_stays_until_it_is_handed_over_or_its_time_is_past():
    h = week()
    h.now = at(20)  # tonight's order is an hour late and still open: it stays, under its day
    assert days(h)[0] == ("2026-11-16", ["p1"])
    h.op("p1", "fire", at(20, 1), course="*")
    h.op("p1", "set_field", at(20, 2), stage="ready")
    assert days(h)[0] == ("2026-11-16", ["p1"])  # on the shelf is not handed over
    h.op("p1", "set_field", at(20, 3), stage="picked_up")
    h.op("p1", "close", at(20, 3))
    assert days(h) == [("2026-11-21", ["c1", "c2"])]
    # Saturday evening, after both times: the open one stays until somebody closes it, the closed one is gone
    h.now = at(19, day=21)
    assert days(h) == [("2026-11-21", ["c1"])]
    assert ahead(h)["today"] == "2026-11-21"
    # and on Sunday it still stands under Saturday, the day it was for
    h.now = at(12, day=22)
    assert days(h) == [("2026-11-21", ["c1"])]
    h.op("c1", "close", at(12, 1, day=22))
    assert days(h) == []


def test_an_order_moved_to_another_day_moves_on_the_list():
    h = week()
    h.op("c1", "set_field", at(18), promised_at=at(12, day=22))
    assert days(h) == [("2026-11-16", ["p1"]), ("2026-11-21", ["c2"]), ("2026-11-22", ["c1"])]


def test_the_small_hours_belong_to_the_evening_before():
    h = Hub(now=at(17))
    later(h, "n1", at(17), "Night", at(0, 30, day=22))  # half past midnight after Saturday's service
    later(h, "n2", at(17, 1), "Dawn", at(4, day=22))  # four in the morning opens Sunday
    assert days(h) == [("2026-11-21", ["n1"]), ("2026-11-22", ["n2"])]


def test_two_orders_for_the_same_minute_keep_the_order_of_their_numbers():
    h = Hub(now=at(17))
    for order_id in ("b", "a", "c"):
        later(h, order_id, at(17), order_id.upper(), SATURDAY_NOON)
    assert days(h) == [("2026-11-21", ["b", "a", "c"])]


def listed(h: Hub) -> dict[str, str | None]:
    orders = h.c.get("/orders", params={"brief": "true", "status": "open"}).json()["orders"]
    return {order["order_id"]: order.get("due") for order in orders}


def test_the_list_of_orders_says_what_is_still_to_pay_on_a_to_go_order_that_took_money():
    h = week()
    h.pay("t1", at(17, 31), "5.00")  # a table that took money says nothing here: tables are not paid first
    # a deposit is not the whole of it; an order nothing was paid on says nothing, all of it is due
    assert listed(h) == {"c1": "45.01", "p1": None, "p2": None, "t1": None}
    assert listed(h) == {"c1": "45.01", "p1": None, "p2": None, "t1": None}  # read again, the same
    h.ring("c1", "L3", BEER, at(17, 32))  # a dish more is more to pay
    assert listed(h)["c1"] == str(Decimal("45.01") + Decimal(h.check("c1")["total"]) - Decimal("65.01"))
    h.pay("c1", at(17, 33), h.check("c1")["due"])
    assert listed(h)["c1"] == "0.00"
    # the whole order, as its own screen reads it, carries no such figure: the check is where it reads it
    assert "due" not in h.c.get("/orders/c1").json()
    assert "due" not in h.c.get("/orders", params={"status": "open"}).json()["orders"][0]


def test_what_an_event_needs_is_kept_on_the_order_and_in_its_history():
    h = week()
    fields = h.c.get("/orders/c1").json()["fields"]
    assert (fields["handover"], fields["event_guests"], fields["event_note"]) == (
        "delivery",
        30,
        "Set up by 11:30, side door",
    )
    # the head count of an event is no table's covers: the reports and the automatic charges do not see it
    assert "guests" not in fields
    h.op("c1", "set_field", at(18), address="14 Main St, Winchester", handover="pickup", by="Amy")
    steps = h.c.get("/orders/c1/history", headers=h.manager()).json()["steps"]
    opened = next(step for step in steps if step["what"] == "opened")["fields"]
    assert (opened["handover"], opened["address"]) == ("delivery", "12 Main St,  Winchester")
    changed = {step["field"]: (step["was"], step["now"]) for step in steps if step["what"] == "field"}
    assert changed == {
        "address": ("12 Main St,  Winchester", "14 Main St, Winchester"),
        "handover": ("delivery", "pickup"),
    }
    assert ahead(h)["days"][1]["orders"][0]["handover"] == "pickup"


def test_catering_has_a_lead_of_its_own_among_the_quote_times():
    h = Hub(now=at(17))
    assert h.c.get("/settings/quotes").json()["minutes"]["catering"] == 60
    # a location that saved its quote times before there was one keeps the hour
    saved = {"minutes": {"counter": 10, "phone": 20, "online": 25, "delivery": 45}, "pay_at_pickup": ["phone"]}
    assert h.c.put("/settings/quotes", json=saved, headers=h.manager()).status_code == 200
    assert h.c.get("/settings/quotes").json()["minutes"] == {**saved["minutes"], "catering": 60}
    saved["minutes"]["catering"] = 120
    assert h.c.put("/settings/quotes", json=saved, headers=h.manager()).status_code == 200
    assert h.c.get("/settings/quotes").json()["minutes"]["catering"] == 120


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_orders_ahead_on_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders CASCADE")
    h = week(Hub(now=at(17), postgres=DSN))
    try:
        assert days(h) == [("2026-11-16", ["p1"]), ("2026-11-21", ["c1", "c2"])]
        assert listed(h)["c1"] == "45.01"
    finally:
        h.store.close()
