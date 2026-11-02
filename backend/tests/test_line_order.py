"""Arranging the check: every line has a place on it (its rank), a drag moves a line to another place or
another course, and the kitchen ticket, the check and the order a terminal reads all follow that order."""

from __future__ import annotations

import math

from pos.printing.service import Printer, PrintService, ticket_for_fire
from pos.sync.oplog import replay

from .orders.test_menu_orders import GTC_QUART, client, payload

EGGROLL = {"variant_id": "EGGROLL:regular"}


def test_lines_rank_in_the_order_they_were_added_and_a_move_puts_one_between_two_others(op):
    ops = [
        op("create", at=0, table=1),
        op("add_line", at=1, line_id="L1", item="Egg roll"),
        op("add_line", at=2, line_id="L2", item="Duck"),
        op("add_line", at=3, line_id="L3", item="Tea"),
    ]
    state = replay(ops)
    assert [line.line_id for line in state.ordered_lines()] == ["L1", "L2", "L3"]
    assert [line.rank for line in state.ordered_lines()] == [1.0, 2.0, 3.0]

    moved = replay(ops + [op("set_line", at=4, line_id="L3", rank=1.5)])
    assert [line.line_id for line in moved.ordered_lines()] == ["L1", "L3", "L2"]
    snapshot = moved.snapshot()
    assert list(snapshot["lines"]) == ["L1", "L3", "L2"]  # the order a terminal reads them in
    assert snapshot["lines"]["L3"]["rank"] == 1.5

    # a dish added later goes after everything, including a line moved past the end
    later = replay(ops + [op("set_line", at=4, line_id="L2", rank=9), op("add_line", at=5, line_id="L4", item="x")])
    assert [line.line_id for line in later.ordered_lines()] == ["L1", "L3", "L2", "L4"]
    assert later.lines["L4"].rank == 10.0


def test_a_terminal_may_place_a_line_as_it_adds_it_and_a_rank_that_is_not_a_number_is_ignored(op):
    ops = [
        op("create", at=0),
        op("add_line", at=1, line_id="L1", item="x"),
        op("add_line", at=2, line_id="L2", item="x", rank=0.5),  # the terminal put it first
        op("set_line", at=3, line_id="L1", rank="first"),
        op("set_line", at=4, line_id="L1", rank=math.nan),
        op("set_line", at=5, line_id="L1", rank=True),
        op("set_line", at=6, line_id="L1", qty=2),  # the rest of the change still applies
    ]
    state = replay(ops)
    assert [line.line_id for line in state.ordered_lines()] == ["L2", "L1"]
    assert (state.lines["L1"].rank, state.lines["L1"].qty) == (1.0, 2)


def test_a_sent_line_moved_on_the_check_is_not_a_change_the_kitchen_hears_about(op):
    """Within its course or into another one: the dish keeps its place on the ticket it went out on
    (Mike, 2026-11-02). No void, no modify, and it is not on the ticket of the course it joins."""
    ops = [
        op("create", at=0),
        op("add_line", at=1, line_id="L1", item="x", course="1"),
        op("add_line", at=2, line_id="L2", item="y", course="1"),
        op("fire", at=3, course="1"),
    ]
    arranged = replay(ops + [op("set_line", at=4, line_id="L2", rank=0.5)])
    assert [line.line_id for line in arranged.ordered_lines()] == ["L2", "L1"]
    assert arranged.lines["L2"].modified_after_fire is False

    fire_entrees = op("fire", at=5, course="2")
    recoursed = replay(ops + [op("set_line", at=4, line_id="L2", course="2", rank=0.5), fire_entrees])
    line = recoursed.lines["L2"]
    assert (line.course, line.modified_after_fire) == ("2", False)
    assert line.fired_at == replay(ops).lines["L2"].fired_at  # sent when the appetizers went, still
    assert ticket_for_fire(recoursed, fire_entrees, station="kitchen", ticket_no=1) is None  # nothing new


def test_a_line_not_yet_sent_is_a_late_addition_only_while_it_sits_under_a_course_that_has_fired(op):
    ops = [
        op("create", at=0),
        op("add_line", at=1, line_id="L1", item="x", course="1"),
        op("fire", at=2, course="1"),
        op("add_line", at=3, line_id="L2", item="y", course="1"),  # after the appetizers went: flagged
    ]
    assert replay(ops).lines["L2"].modified_after_fire is True
    to_entrees = op("set_line", at=4, line_id="L2", course="2", rank=0.5)
    assert replay(ops + [to_entrees]).lines["L2"].modified_after_fire is False  # it goes when the entrees do
    more = replay(ops + [to_entrees, op("set_line", at=5, line_id="L2", qty=2)])
    assert more.lines["L2"].modified_after_fire is False  # the entrees have not gone: nothing is late
    back = replay(ops + [to_entrees, op("set_line", at=5, line_id="L2", course="1")])
    assert back.lines["L2"].modified_after_fire is True


def test_the_ticket_the_check_and_the_order_follow_the_arranged_order():
    printing = PrintService([Printer("kitchen", "10.0.0.9")], direct=False)
    c = client(printing)
    c.post(
        "/orders/o1/ops",
        json=[
            payload("a", "create", 0, table="A7", guests=2),
            payload("b", "add_line", 1, line_id="L1", item="?", seat=1, course="1", request=GTC_QUART),
            payload("c", "add_line", 2, line_id="L2", item="?", seat=2, course="1", request=EGGROLL),
            payload("d", "set_line", 3, line_id="L2", rank=0.5),  # the egg roll first, though seat 2 ordered it
            payload("e", "fire", 4, course="1"),
        ],
    )
    store = c.app.state.store
    ticket = ticket_for_fire(store.state("o1"), store.for_order("o1")[-1], station="kitchen", ticket_no=1)
    assert [t.label for t in ticket.lines] == ["蛋卷", "左宗鸡 (Qt)"]
    order = c.get("/orders/o1").json()
    assert list(order["lines"]) == ["L2", "L1"]
    assert (order["lines"]["L2"]["rank"], order["lines"]["L1"]["rank"]) == (0.5, 1.0)
    check = c.get("/orders/o1/check").json()
    assert [line["line_id"] for line in check["lines"]] == ["L2", "L1"]
