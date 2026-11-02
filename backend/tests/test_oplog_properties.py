"""Property tests: whatever the operations, the replay obeys the rules."""

from __future__ import annotations

from hypothesis import given, settings
from hypothesis import strategies as st

from pos.sync.hlc import HLC
from pos.sync.oplog import Op, replay
from pos.sync.simulate import run, run_outage

from .conftest import T0

nodes = st.sampled_from(["a", "b", "hub"])
line_ids = st.sampled_from(["L1", "L2", "L3", "L4"])
courses = st.sampled_from(["apps", "entrees", "*"])


@st.composite
def ops(draw):
    """A set of operations on one order, with the clock stamps a few devices might really produce."""
    count = draw(st.integers(1, 40))
    result = []
    for i in range(count):
        node = draw(nodes)
        stamp = HLC(T0 + draw(st.integers(0, 50)), draw(st.integers(0, 3)), node)
        kind = draw(
            st.sampled_from(
                [
                    "create",
                    "set_field",
                    "add_line",
                    "add_line",
                    "set_line",
                    "set_line",
                    "void_line",
                    "fire",
                    "close",
                    "reopen",
                    "void_order",
                ]
            )
        )
        data: dict = {}
        if kind in ("create", "set_field"):
            data = {"table": draw(st.integers(1, 9)), "note": draw(st.sampled_from(["", "rush", "vip"]))}
        elif kind == "add_line":
            data = {
                "line_id": draw(line_ids),
                "item": "x",
                "qty": draw(st.integers(1, 3)),
                "course": draw(st.sampled_from(["apps", "entrees"])),
            }
        elif kind == "set_line":
            data = {"line_id": draw(line_ids), "qty": draw(st.integers(1, 5))}
            if draw(st.booleans()):  # a drag on the check: another place, another course
                data["rank"] = draw(st.sampled_from([0.5, 1.5, 2.0, 7.0]))
                data["course"] = draw(st.sampled_from(["apps", "entrees"]))
        elif kind == "void_line":
            data = {"line_id": draw(line_ids)}
        elif kind == "fire":
            data = {"course": draw(courses)}
        result.append(Op(f"op{i}", "o1", stamp, node, kind, data))
    return result


@given(ops(), st.randoms())
@settings(max_examples=200)
def test_the_result_depends_only_on_the_set_of_operations(ops, rnd):
    want = replay(ops).snapshot()
    shuffled = ops[:]
    rnd.shuffle(shuffled)
    assert replay(shuffled).snapshot() == want
    assert replay(shuffled + ops[: len(ops) // 2]).snapshot() == want  # duplicates
    half = len(ops) // 2
    assert replay(ops[:half] + ops[half:]).snapshot() == want  # a merge of two copies


@given(ops())
@settings(max_examples=200)
def test_a_void_always_wins_and_last_writer_wins_per_field(ops):
    state = replay(ops)
    voided = {op.data["line_id"] for op in ops if op.kind == "void_line"}
    for line_id in voided:
        assert not state.lines[line_id].active
    if any(op.kind == "void_order" for op in ops):
        assert state.status == "void"
    setters = [op for op in ops if op.kind in ("create", "set_field")]
    if setters:
        latest = max(setters, key=lambda op: op.sort_key)
        assert state.fields["table"] == latest.data["table"]
    for course in {op.data["course"] for op in ops if op.kind == "fire"}:
        first = min((op for op in ops if op.kind == "fire" and op.data["course"] == course), key=lambda op: op.sort_key)
        assert state.fired[course] == first.hlc


@given(
    seed=st.integers(0, 2**31),
    replicas=st.integers(2, 4),
    rounds=st.integers(10, 80),
    drop=st.floats(0, 0.7),
    dup=st.floats(0, 0.4),
    lose_ack=st.floats(0, 0.5),
)
@settings(max_examples=40, deadline=None)
def test_terminals_converge_once_the_cables_are_back(seed, replicas, rounds, drop, dup, lose_ack):
    report = run(seed=seed, replicas=replicas, rounds=rounds, drop=drop, dup=dup, lose_ack=lose_ack)
    assert report.converged, report


@given(seed=st.integers(0, 2**31), replicas=st.integers(2, 4), outage_rounds=st.integers(5, 60))
@settings(max_examples=25, deadline=None)
def test_orders_captured_with_every_backend_dead_replay_on_the_hub_as_the_terminal_saw_them(
    seed, replicas, outage_rounds
):
    """ADR 6: a terminal keeps ringing its own tables while nothing answers; when the hub is back, each of
    those orders must come out of the hub's replay exactly as the terminal showed it, flagged for printing."""
    report = run_outage(seed=seed, replicas=replicas, rounds=40, outage_rounds=outage_rounds)
    assert report.ok, report
    assert report.flagged == report.captured_ops
