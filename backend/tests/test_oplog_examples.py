"""Worked examples: the conflict rules from the architecture, one scenario each."""

from __future__ import annotations

import random

import pytest

from pos.sync.hlc import HLC
from pos.sync.oplog import ClockDriftError, Op, OpStore, replay

from .conftest import T0


def test_two_terminals_add_lines_while_disconnected_and_both_lines_survive(op):
    ops = [
        op("create", at=0, node="a", table=12),
        op("add_line", at=10, node="a", line_id="L1", item="Spicy Tuna Roll"),
        op("add_line", at=11, node="b", line_id="L2", item="Tsingtao"),
    ]
    state = replay(ops)
    assert set(state.lines) == {"L1", "L2"}
    assert state.fields["table"] == 12


def test_arrival_order_and_duplicates_never_change_the_result(op):
    ops = [op("create", at=0, table=1)] + [
        op("add_line", at=i, node=random.choice("ab"), line_id=f"L{i}", item="x") for i in range(1, 8)
    ]
    ops += [op("set_line", at=20, line_id="L3", qty=4), op("void_line", at=21, line_id="L5")]
    want = replay(ops).snapshot()
    for _ in range(5):
        shuffled = ops[:]
        random.shuffle(shuffled)
        assert replay(shuffled + ops[:3]).snapshot() == want


def test_a_void_wins_over_a_concurrent_edit_whichever_came_first(op):
    base = [op("create", at=0), op("add_line", at=1, line_id="L1", item="Sake", qty=1)]
    edit_then_void = base + [
        op("set_line", at=5, node="a", line_id="L1", qty=3),
        op("void_line", at=4, node="b", line_id="L1"),
    ]
    void_then_edit = base + [
        op("void_line", at=4, node="b", line_id="L1"),
        op("set_line", at=9, node="a", line_id="L1", qty=3),
    ]
    for ops in (edit_then_void, void_then_edit):
        line = replay(ops).lines["L1"]
        assert line.status == "removed"  # never fired: it just comes off


def test_order_fields_are_last_writer_wins_by_clock(op):
    ops = [
        op("create", at=0, table=5),
        op("set_field", at=4, node="b", table=7),
        op("set_field", at=3, node="a", table=6),
    ]
    assert replay(ops).fields["table"] == 7


def test_a_change_after_firing_is_flagged_for_a_modify_ticket(op):
    ops = [
        op("create", at=0),
        op("add_line", at=1, line_id="L1", item="General Tso's Chicken", course="entrees"),
        op("fire", at=2, course="entrees"),
        op("set_line", at=3, line_id="L1", qty=2),
        op("add_line", at=4, line_id="L2", item="Rice", course="entrees"),
    ]
    state = replay(ops)
    assert state.lines["L1"].modified_after_fire
    assert state.lines["L2"].modified_after_fire
    assert str(state.fired["entrees"]).startswith(str(T0 + 2))


def test_firing_twice_keeps_the_first_time(op):
    ops = [op("create", at=0), op("fire", at=5, node="b", course="apps"), op("fire", at=3, node="a", course="apps")]
    assert replay(ops).fired["apps"] == HLC(T0 + 3, 0, "a")


def test_a_voided_order_stays_void_and_a_closed_one_can_reopen(op):
    closed = [op("create", at=0), op("close", at=1)]
    assert replay(closed).status == "closed"
    assert replay(closed + [op("reopen", at=2)]).status == "open"
    assert replay(closed + [op("void_order", at=2), op("close", at=3), op("reopen", at=4)]).status == "void"


def test_a_stamp_far_in_the_future_is_refused_until_the_clock_is_fixed():
    store = OpStore(physical=lambda: T0)
    fine = Op("x1", "o1", HLC(T0 + 60_000, 0, "a"), "a", "create", {"table": 1})
    wrong = Op("x2", "o1", HLC(T0 + 10 * 60_000, 0, "a"), "a", "create", {"table": 1})
    assert store.append([fine]) == [fine]
    with pytest.raises(ClockDriftError):
        store.append([wrong])
    assert store.append([fine]) == []  # a duplicate is simply ignored
    assert store.cursor == 1
