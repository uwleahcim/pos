"""Dishes taken off a check before the kitchen saw them: nothing is asked and nothing prints, and the
manager's report lists every one of them with who took it off, when, and how long it had been on the check."""

from __future__ import annotations

import random

from fastapi.testclient import TestClient

from pos.orders.taken_off import taken_off_rows
from pos.sync.oplog import replay

from ..conftest import T0, make_op, servers_void
from .test_adjustments import DUCK, TEA, client, payload

MINUTE = 60_000


def send(c: TestClient, *ops: dict, order_id: str = "o1") -> dict:
    return c.post(f"/orders/{order_id}/ops", json=list(ops)).json()


def rung(c: TestClient, order_id: str = "o1", *, table: str = "12", tea: int = 1) -> None:
    """A table with tea (L1) and a duck (L2) rung in by Amy, nothing sent yet."""
    answer = send(
        c,
        payload(f"{order_id}-a", "create", 0, order_id, table=table, guests=2, order_type="dine_in"),
        payload(f"{order_id}-b", "add_line", 1000, order_id, line_id="L1", item="Tea", qty=tea, priced=TEA, by="Amy"),
        payload(f"{order_id}-c", "add_line", 2000, order_id, line_id="L2", item="Duck", qty=1, priced=DUCK, by="Amy"),
        order_id=order_id,
    )
    assert answer["refused"] == []


def taken(c: TestClient, **params: int) -> dict:
    return c.get("/reports/adjustments", params=params).json()


def test_a_dish_taken_off_before_it_was_sent_is_in_the_report_with_who_when_and_how_long():
    c = client()
    rung(c)
    # nothing is asked: no reason, no manager, and the dish is off the check
    answer = send(c, payload("d", "void_line", 2000 + 3 * MINUTE, line_id="L2", by="Ben", by_id="s2"))
    assert answer["refused"] == []
    assert c.get("/orders/o1").json()["lines"]["L2"]["status"] == "removed"

    report = taken(c)
    (row,) = report["taken_off"]
    assert (row["order_id"], row["table"], row["line_id"], row["item"], row["qty"], row["amount"]) == (
        "o1",
        "12",
        "L2",
        "Duck",
        1,
        "20.00",
    )
    assert (row["by"], row["by_id"], row["rung_by"], row["device"]) == ("Ben", "s2", "Amy", "t1")
    assert (row["at_ms"], row["on_check_ms"], row["status"]) == (T0 + 2000 + 3 * MINUTE, 3 * MINUTE, "open")
    assert (report["taken_off_total"], report["taken_off_count"]) == ("20.00", 1)
    assert report["taken_off_by_staff"] == [{"key": "Ben", "amount": "20.00", "count": 1}]
    assert report["taken_off_by_check"] == [
        {"order_id": "o1", "table": "12", "order_no": None, "customer_name": None, "amount": "20.00", "count": 1}
    ]
    # it is no void: the kitchen never had it
    assert report["voids"] == [] and report["void_total"] == "0.00"


def test_fewer_of_an_unsent_dish_counts_what_came_off_and_more_of_it_does_not():
    c = client()
    rung(c, tea=3)
    send(c, payload("d", "set_line", 60_000, line_id="L1", qty=1, by="Amy", by_id="s1"))  # three teas, then one
    send(c, payload("e", "set_line", 70_000, line_id="L1", qty=4, by="Amy", by_id="s1"))  # then four
    send(c, payload("f", "set_line", 80_000, line_id="L1", rank=5.0))  # moved on the check: nothing came off
    report = taken(c)
    assert [(t["line_id"], t["item"], t["qty"], t["amount"], t["by"]) for t in report["taken_off"]] == [
        ("L1", "Tea", 2, "20.00", "Amy")
    ]
    assert report["taken_off"][0]["on_check_ms"] == 59_000


def test_changing_a_dish_is_not_taking_it_off_but_fewer_in_its_place_is_the_difference():
    c = client()
    rung(c, tea=3)
    # the same three teas with another choice: taken off and put back in one go
    send(
        c,
        payload("d", "void_line", 10_000, line_id="L1", reason="changed", by="Amy"),
        payload("e", "add_line", 10_001, line_id="L3", item="Tea", qty=3, priced=TEA, replaces="L1", by="Amy"),
    )
    assert taken(c)["taken_off"] == []
    # changed again, and only two of them this time
    send(
        c,
        payload("f", "void_line", 20_000, line_id="L3", reason="changed", by="Amy"),
        payload("g", "add_line", 20_001, line_id="L4", item="Tea", qty=2, priced=TEA, replaces="L3", by="Amy"),
    )
    assert [(t["line_id"], t["qty"], t["amount"]) for t in taken(c)["taken_off"]] == [("L3", 1, "10.00")]


def test_a_sent_dish_is_a_void_not_a_dish_taken_off_and_a_removal_with_no_dish_is_nothing():
    c = client()
    c.app.state.settings = servers_void()  # a server voids a sent dish with a reason alone here
    rung(c)
    send(c, payload("d", "fire", 5000, course="*"))
    send(c, payload("e", "void_line", 6000, line_id="L2", reason="kitchen-error", by="Amy"))
    send(c, payload("f", "void_line", 7000, line_id="L9", by="Amy"))  # a line nobody rang in
    report = taken(c)
    assert report["taken_off"] == [] and report["taken_off_count"] == 0
    assert [v["line_id"] for v in report["voids"]] == ["L2"]


def test_the_report_adds_up_by_who_took_it_off_and_by_check_and_reads_back_only_since_a_time():
    c = client()
    rung(c, "o1", table="12", tea=2)
    rung(c, "o2", table="7")
    send(c, payload("d", "void_line", 30_000, "o1", line_id="L2", by="Amy", by_id="s1"))
    send(c, payload("e", "void_line", 40_000, "o2", line_id="L1", by="Ben", by_id="s2"), order_id="o2")
    send(c, payload("f", "void_line", 50_000, "o2", line_id="L2"), order_id="o2")  # an app that says no name
    send(c, payload("g", "set_line", 60_000, "o1", line_id="L1", qty=1, by="Amy", by_id="s1"))

    report = taken(c)
    assert [(t["order_id"], t["line_id"], t["qty"], t["by"]) for t in report["taken_off"]] == [
        ("o1", "L2", 1, "Amy"),
        ("o2", "L1", 1, "Ben"),
        ("o2", "L2", 1, ""),
        ("o1", "L1", 1, "Amy"),
    ]
    assert report["taken_off"][2]["rung_by"] == "Amy"  # who rang it in is known all the same
    assert (report["taken_off_total"], report["taken_off_count"]) == ("60.00", 4)
    assert report["taken_off_by_staff"] == [
        {"key": "Amy", "amount": "30.00", "count": 2},
        {"key": "", "amount": "20.00", "count": 1},
        {"key": "Ben", "amount": "10.00", "count": 1},
    ]
    assert [(t["order_id"], t["table"], t["amount"], t["count"]) for t in report["taken_off_by_check"]] == [
        ("o1", "12", "30.00", 2),
        ("o2", "7", "30.00", 2),
    ]
    later = taken(c, since=T0 + 45_000)
    assert [(t["order_id"], t["line_id"]) for t in later["taken_off"]] == [("o2", "L2"), ("o1", "L1")]
    assert later["taken_off_total"] == "30.00"


def test_what_came_off_is_the_same_however_the_operations_arrived():
    ops = [
        make_op("create", at=0, table="12"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=5, priced=TEA, by="Amy"),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK, by="Amy"),
        make_op("set_line", at=10, node="b", line_id="L1", qty=3, by="Ben"),
        make_op("set_line", at=20, line_id="L1", qty=4, by="Amy"),
        make_op("set_line", at=30, node="b", line_id="L1", qty=1, by="Ben"),
        make_op("void_line", at=40, line_id="L2", by="Amy"),
        make_op("void_line", at=41, node="b", line_id="L2", by="Ben"),  # the second one changes nothing
    ]
    want = taken_off_rows(replay(ops))
    assert [(r["line_id"], r["qty"], r["by"], r["device"]) for r in want] == [
        ("L1", 2, "Ben", "b"),
        ("L1", 3, "Ben", "b"),
        ("L2", 1, "Amy", "a"),
    ]
    for _ in range(5):
        shuffled = ops[:]
        random.shuffle(shuffled)
        assert taken_off_rows(replay(shuffled + ops[:3])) == want
