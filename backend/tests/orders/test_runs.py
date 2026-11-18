"""A driver's runs for the shift (docs/delivery.md, "Runs").

Each time a delivery leaves with a driver is a leg; the bags a driver left with in one go are a run. The
report is read off the orders' own logs: who took what, when it left and what became of it. No money is in
it, and reading it changes nothing."""

from __future__ import annotations

import random
from datetime import date

from pos.orders.runs import RUN_GAP_MS, legs_of, runs_report

from .test_day import EGGROLL, Hub, at
from .test_delivery import ELM
from .test_drivers import TOM, WEI

OAK = "4 Oak Rd, Winchester"
SECOND = 1000
MINUTE = 60 * SECOND


def bag(h: Hub, order_id: str, when: int, name: str = "Linda", address: str = ELM, **more) -> None:
    """A phone order that is brought to the customer."""
    h.to_go(order_id, when, name=name, phone="781 555 0101", handover="delivery", address=address, **more)


def leaves(h: Hub, order_id: str, when: int, driver: dict, by: str = "Amy", by_id: str = "s1") -> None:
    h.op(order_id, "set_field", when, stage="out", out_at=when, by=by, by_id=by_id, **driver)


def delivered(h: Hub, order_id: str, when: int) -> None:
    h.op(order_id, "set_field", when, stage="picked_up", by="Tom", by_id="d1")


def came_back(h: Hub, order_id: str, when: int) -> None:
    h.op(order_id, "set_field", when, stage="ready", driver=None, driver_id=None, by="Mike", by_id="s3")


def runs(h: Hub, day: str | None = None) -> dict:
    answer = h.c.get("/deliveries/runs", params={"day": day} if day else {})
    assert answer.status_code == 200, answer.text
    return answer.json()


def told(report: dict) -> list[tuple]:
    """Every bag of a report in a line: the driver, which of their runs, the order, what became of it and
    after how many minutes."""
    return [
        (driver["driver"], number, each["order_id"], each["outcome"], each["minutes"])
        for driver in report["drivers"]
        for number, run in enumerate(driver["list"], 1)
        for each in run["bags"]
    ]


# A run --------------------------------------------------------------------------------------------------------


def test_bags_that_leave_together_are_one_run_and_each_says_what_became_of_it():
    h = Hub(now=at(18))
    bag(h, "o1", at(18), name="Linda")
    bag(h, "o2", at(18, 5), name="Raj", address=OAK)
    for order_id in ("o1", "o2"):  # picked together on the Deliveries screen: they left at the same moment
        leaves(h, order_id, at(18, 40), TOM)
    # on the road
    report = runs(h)
    assert (report["day"], report["runs"], report["delivered"], report["back"], report["out"]) == (
        "2026-11-16",
        1,
        0,
        0,
        2,
    )
    [tom] = report["drivers"]
    assert (tom["driver"], tom["driver_id"], tom["runs"], tom["out"]) == ("Tom", "d1", 1, 2)
    [run] = tom["list"]
    assert (run["left_ms"], run["ended_ms"], run["minutes"]) == (at(18, 40), None, None)
    assert [(b["order_no"], b["customer_name"], b["address"], b["outcome"], b["at_ms"]) for b in run["bags"]] == [
        (1, "Linda", ELM, "out", None),
        (2, "Raj", OAK, "out", None),
    ]
    # the first door, then the second
    delivered(h, "o1", at(18, 55))
    assert runs(h)["drivers"][0]["list"][0]["ended_ms"] is None  # one is still out
    delivered(h, "o2", at(19, 5))
    report = runs(h)
    assert (report["runs"], report["delivered"], report["out"]) == (1, 2, 0)
    [run] = report["drivers"][0]["list"]
    assert (run["left_ms"], run["ended_ms"], run["minutes"]) == (at(18, 40), at(19, 5), 25)
    assert [(b["order_id"], b["outcome"], b["left_ms"], b["at_ms"], b["minutes"]) for b in run["bags"]] == [
        ("o1", "delivered", at(18, 40), at(18, 55), 15),
        ("o2", "delivered", at(18, 40), at(19, 5), 25),
    ]


def test_bags_tapped_out_one_after_the_other_are_the_same_trip():
    h = Hub(now=at(18))
    for n in range(1, 5):
        bag(h, f"o{n}", at(18, n))
    # at the counter, one tap after another on the list of checks; the third was still being packed
    leaves(h, "o1", at(18, 40), TOM)
    leaves(h, "o2", at(18, 40) + 20 * SECOND, TOM)
    leaves(h, "o3", at(18, 44), TOM)
    # Tom was long gone when this one left: it went with his next trip
    leaves(h, "o4", at(18, 44) + RUN_GAP_MS + SECOND, TOM)
    report = runs(h)
    assert told(report) == [
        ("Tom", 1, "o1", "out", None),
        ("Tom", 1, "o2", "out", None),
        ("Tom", 1, "o3", "out", None),
        ("Tom", 2, "o4", "out", None),
    ]
    assert (report["runs"], report["out"]) == (2, 4)
    assert [run["left_ms"] for run in report["drivers"][0]["list"]] == [at(18, 40), at(18, 44) + RUN_GAP_MS + SECOND]


def test_a_bag_that_leaves_after_one_was_delivered_is_the_next_run():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    bag(h, "o2", at(18, 1))
    leaves(h, "o1", at(18, 40), TOM)
    delivered(h, "o1", at(18, 42))  # across the street
    leaves(h, "o2", at(18, 43), TOM)  # he was back before five minutes were up, and left again
    assert told(runs(h)) == [("Tom", 1, "o1", "delivered", 2), ("Tom", 2, "o2", "out", None)]
    # one that only came back to the counter (the wrong bag) and left again broke nothing: he had not gone
    bag(h, "o3", at(19))
    bag(h, "o4", at(19, 1))
    leaves(h, "o3", at(19, 30), WEI)
    leaves(h, "o4", at(19, 30), WEI)
    came_back(h, "o4", at(19, 31))
    leaves(h, "o4", at(19, 32), WEI)
    wei = runs(h)["drivers"][1]
    assert (wei["driver"], wei["runs"], wei["back"], wei["out"]) == ("Wei", 1, 1, 2)
    assert [(b["order_id"], b["outcome"]) for b in wei["list"][0]["bags"]] == [
        ("o3", "out"),
        ("o4", "back"),
        ("o4", "out"),
    ]


# What became of a bag -----------------------------------------------------------------------------------------


def test_a_bag_that_came_back_and_left_with_another_driver_counts_with_each():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    leaves(h, "o1", at(18, 40), TOM)
    came_back(h, "o1", at(18, 50))  # nobody home
    leaves(h, "o1", at(19), WEI)
    delivered(h, "o1", at(19, 20))
    report = runs(h)
    assert told(report) == [("Tom", 1, "o1", "back", 10), ("Wei", 1, "o1", "delivered", 20)]
    assert [(d["driver"], d["runs"], d["delivered"], d["back"], d["out"]) for d in report["drivers"]] == [
        ("Tom", 1, 0, 1, 0),  # whoever left first is first
        ("Wei", 1, 1, 0, 0),
    ]
    assert (report["runs"], report["delivered"], report["back"], report["out"]) == (2, 1, 1, 0)


def test_a_bag_handed_on_along_the_way_says_who_took_it_over():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    leaves(h, "o1", at(18, 40), TOM)
    h.op("o1", "set_field", at(18, 50), by="Mike", by_id="s3", **WEI)  # Tom's car would not start
    delivered(h, "o1", at(19, 10))
    report = runs(h)
    assert told(report) == [("Tom", 1, "o1", "handed", 10), ("Wei", 1, "o1", "delivered", 20)]
    [toms] = report["drivers"][0]["list"][0]["bags"]
    assert (toms["to"], toms["at_ms"]) == ("Wei", at(18, 50))
    [weis] = report["drivers"][1]["list"][0]["bags"]
    assert weis["left_ms"] == at(18, 50) and "to" not in weis  # it left Wei's hands from then
    # neither delivered nor back for Tom: it is Wei's delivery
    assert (report["drivers"][0]["delivered"], report["drivers"][0]["back"], report["delivered"]) == (0, 0, 1)


def test_a_voided_order_and_a_check_closed_while_out_end_the_trip():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    bag(h, "o2", at(18, 1))
    leaves(h, "o1", at(18, 40), TOM)
    leaves(h, "o2", at(18, 40), TOM)
    h.op("o1", "void_order", at(18, 45))  # the customer called it off
    h.op("o2", "close", at(19, 5))  # paid at the door, closed at the counter, and nobody tapped Delivered
    report = runs(h)
    assert told(report) == [("Tom", 1, "o1", "void", 5), ("Tom", 1, "o2", "delivered", 25)]
    assert (report["delivered"], report["back"], report["out"]) == (1, 0, 0)
    assert report["drivers"][0]["list"][0]["ended_ms"] == at(19, 5)
    # reopened to fix something on it: it is as it was before it closed, out with Tom since then
    h.op("o2", "reopen", at(19, 30))
    assert told(runs(h)) == [("Tom", 1, "o1", "void", 5), ("Tom", 1, "o2", "out", None)]


def test_a_delivery_marked_delivered_with_no_driver_is_counted_apart():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    h.op("o1", "set_field", at(18, 30), stage="ready")
    h.op("o1", "set_field", at(18, 50), stage="picked_up")  # the owner ran it over, and named nobody
    bag(h, "o2", at(18, 5))
    h.op("o2", "close", at(19))  # closed from the counter, no stage tapped at all
    h.to_go("o3", at(18, 10), name="Kim")  # the customer came for this one
    h.op("o3", "set_field", at(18, 40), stage="picked_up")
    bag(h, "o4", at(18, 15))  # still in the kitchen
    report = runs(h)
    assert (report["drivers"], report["runs"], report["no_driver"]) == ([], 0, 2)
    # one a driver did take is not among them, and one whose "delivered" was taken back is not either
    leaves(h, "o4", at(19, 10), TOM)
    delivered(h, "o4", at(19, 30))
    h.op("o1", "set_field", at(19, 35), stage="ready")
    report = runs(h)
    assert (report["delivered"], report["no_driver"]) == (1, 1)


# Whose, and which day -----------------------------------------------------------------------------------------


def test_a_run_counts_on_the_day_of_service_it_left_in():
    h = Hub(now=at(19, day=15))
    bag(h, "y1", at(19, day=15))
    bag(h, "y2", at(23, 30, day=15))
    leaves(h, "y1", at(19, 30, day=15), TOM)
    delivered(h, "y1", at(19, 50, day=15))
    leaves(h, "y2", at(23, 50, day=15), TOM)
    delivered(h, "y2", at(0, 20))  # past midnight is still Sunday's service
    bag(h, "o1", at(17))
    leaves(h, "o1", at(17, 30), WEI)
    assert told(runs(h)) == [("Wei", 1, "o1", "out", None)]  # Monday, the day that is running
    sunday = runs(h, "2026-11-15")
    assert told(sunday) == [("Tom", 1, "y1", "delivered", 20), ("Tom", 2, "y2", "delivered", 30)]
    assert (sunday["day"], sunday["runs"], sunday["delivered"], sunday["out"]) == ("2026-11-15", 2, 2, 0)
    assert (sunday["since_ms"], sunday["until_ms"]) == (at(4, day=15), at(4))
    # a day nobody delivered on, and a day that is not one
    empty = runs(h, "2026-11-10")
    assert (empty["drivers"], empty["runs"], empty["no_driver"]) == ([], 0, 0)
    assert h.c.get("/deliveries/runs", params={"day": "2026-13-45"}).status_code == 422
    assert h.c.get("/deliveries/runs", params={"day": "yesterday"}).status_code == 422


def test_a_driver_is_told_apart_by_who_they_are_not_by_how_they_were_spelled():
    h = Hub(now=at(18))
    for n in range(1, 4):
        bag(h, f"o{n}", at(18, n))
    leaves(h, "o1", at(18, 40), TOM)
    leaves(h, "o2", at(19, 40), {"driver": "Thomas", "driver_id": "d1"})  # renamed on the staff list since
    # a screen that named somebody the hub does not know: by the name, and apart from everybody with an id
    h.op("o3", "set_field", at(19, 50), stage="out", out_at=at(19, 50), driver="Tom")
    report = runs(h)
    assert [(d["driver_id"], d["driver"], d["runs"]) for d in report["drivers"]] == [
        ("d1", "Thomas", 2),
        ("", "Tom", 1),
    ]


def test_a_bag_leaves_when_the_screen_said_so_and_when_the_log_says_so_without():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    # tapped at 18:40 on a phone that got through to the hub two minutes later: it left at 18:40
    h.op("o1", "set_field", at(18, 42), stage="out", out_at=at(18, 40), **TOM)
    came_back(h, "o1", at(18, 50))
    # sent out again by a screen that says no time: the log's own time, not the one it left at before
    h.op("o1", "set_field", at(19), stage="out", **TOM)
    delivered(h, "o1", at(19, 20))
    # a time that cannot be right is not believed
    bag(h, "o2", at(18, 5))
    h.op("o2", "set_field", at(19, 30), stage="out", out_at=at(19, 30) // 1000, **WEI)
    report = runs(h)
    assert told(report) == [
        ("Tom", 1, "o1", "back", 10),
        ("Tom", 2, "o1", "delivered", 20),
        ("Wei", 1, "o2", "out", None),
    ]
    assert [run["left_ms"] for d in report["drivers"] for run in d["list"]] == [at(18, 40), at(19), at(19, 30)]
    # named again while out, spelled another way: the same driver, and no hand-over
    h.op("o2", "set_field", at(19, 35), driver="Wei L.", driver_id="d2")
    assert told(runs(h))[-1] == ("Wei L.", 1, "o2", "out", None)


def test_an_order_the_customer_comes_for_and_a_table_are_no_part_of_it():
    h = Hub(now=at(18))
    h.to_go("o1", at(18), name="Kim")
    h.op("o1", "set_field", at(18, 40), stage="out", out_at=at(18, 40), **TOM)  # a slip no screen makes
    h.table("o2", at(18, 5))
    h.op("o2", "set_field", at(18, 41), stage="out", out_at=at(18, 41), **TOM)
    report = runs(h)
    assert (report["drivers"], report["no_driver"]) == ([], 0)
    # one that was a delivery when it left and is picked up after all: it came back
    bag(h, "o3", at(18, 10))
    leaves(h, "o3", at(18, 45), TOM)
    h.op("o3", "set_field", at(18, 55), handover="pickup")
    assert told(runs(h)) == [("Tom", 1, "o3", "back", 10)]


# Nothing but who carried what ---------------------------------------------------------------------------------


def keys_of(value: object) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {key for each in value.values() for key in keys_of(each)}
    if isinstance(value, list):
        return {key for each in value for key in keys_of(each)}
    return set()


def test_no_money_is_in_the_runs_and_reading_them_changes_nothing():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    h.ring("o1", "L1", EGGROLL, at(18, 1))
    h.op("o1", "fire", at(18, 2))
    leaves(h, "o1", at(18, 40), TOM)
    due = h.check("o1")["due"]
    h.pay("o1", at(19), due)  # paid at the door
    delivered(h, "o1", at(19))
    h.op("o1", "close", at(19, 1))
    cursor = h.store.cursor
    report = runs(h)
    assert keys_of(report) == {
        *("day", "since_ms", "until_ms", "runs", "delivered", "back", "out", "no_driver", "drivers"),
        *("driver_id", "driver", "list", "left_ms", "ended_ms", "minutes", "bags"),
        *("order_id", "order_no", "customer_name", "address", "outcome", "at_ms"),
    }
    assert due != "0.00" and due not in str(report)
    assert told(report) == [("Tom", 1, "o1", "delivered", 20)]
    assert h.store.cursor == cursor and h.check("o1")["due"] == "0.00"  # the sale is where it was
    # asked again later with nothing changed, the screen is told so and sent nothing
    first = h.c.get("/deliveries/runs")
    h.now += 5 * MINUTE
    again = h.c.get("/deliveries/runs", headers={"if-none-match": first.headers["etag"]})
    assert again.status_code == 304


def test_the_legs_are_the_same_however_the_log_arrived():
    h = Hub(now=at(18))
    bag(h, "o1", at(18))
    leaves(h, "o1", at(18, 40), TOM)
    came_back(h, "o1", at(18, 50))
    leaves(h, "o1", at(19), WEI)
    delivered(h, "o1", at(19, 20))
    ops = h.store.for_order("o1")
    _, straight, _ = legs_of(ops, "o1")
    assert [(leg.driver, leg.left_ms, leg.end, leg.end_ms) for leg in straight] == [
        ("Tom", at(18, 40), "back", at(18, 50)),
        ("Wei", at(19), "delivered", at(19, 20)),
    ]
    shuffled = [*ops, *ops[:3]]  # twice over in part, and in no order
    random.Random(7).shuffle(shuffled)
    assert legs_of(shuffled, "o1")[1] == straight
    # the report takes the logs as they are, with another order's operations among them
    bag(h, "o2", at(19, 30))
    mixed = [*ops, *h.store.for_order("o2")]
    report = runs_report([("o1", mixed), ("o2", mixed), ("nothing", [])], date(2026, 11, 16))
    assert told(report) == [("Tom", 1, "o1", "back", 10), ("Wei", 1, "o1", "delivered", 20)]
