"""What Shipday says of a delivery, turned into what the POS writes on its check (`pos.shipday.follow`):
picked up there is Out here, delivered there is Delivered here unless money is due, only forward, only
once, and never for a check a person could not have moved either."""

from __future__ import annotations

import itertools
from dataclasses import replace
from typing import Any

from pos.shipday.follow import (
    BY,
    DELIVERED,
    DEVICE,
    DUE,
    NOTED,
    OUT,
    RECENT_MS,
    ops_following,
    own_word,
)
from pos.sync.hlc import HLC
from pos.sync.oplog import Op, OrderState, replay

from .fake import TOM, WEI, at

NOW = at(18, 40)
_n = itertools.count(1)


def op(kind: str, /, **data: Any) -> Op:
    n = next(_n)
    return Op(f"o-7:{n}", "o-7", HLC(NOW - 600_000 + n, 0, "t1"), "t1", kind, data)


def check(*more: Op, sent: bool = True, handover: str = "delivery") -> tuple[list[Op], OrderState]:
    """A delivery on the POS with one dish, sent to the kitchen unless said, and whatever came after."""
    ops = [
        op("create", order_type="takeout", channel="online", handover=handover, order_no=12, stage="new"),
        op("add_line", line_id="L1", item="Tea", qty=1),
        *([op("fire", course="*")] if sent else []),
        # what came after is stamped after, though the test wrote it down first
        *(replace(late, hlc=HLC(NOW - 600_000 + next(_n), 0, "t1")) for late in more),
    ]
    return ops, replay(ops, "o-7")


def said(state: str, **more: Any) -> dict[str, Any]:
    """One of Shipday's deliveries as the board has it: picked up five minutes ago where it was."""
    return {
        "id": 7001,
        "number": "1270166229",
        "state": state,
        "driver": {**TOM},
        "picked_up_ms": NOW - 5 * 60_000,
        "delivered_ms": None,
        **more,
    }


def follow(delivery: dict[str, Any], state: OrderState, *, due: bool = False) -> tuple[tuple[Op, ...], str]:
    stamps = itertools.count(1)
    return ops_following(delivery, state, due=lambda: due, stamp=lambda: HLC(NOW, next(stamps), DEVICE), now_ms=NOW)


def after(ops: list[Op], made: tuple[Op, ...]) -> OrderState:
    return replay([*ops, *made], "o-7")


def test_picked_up_in_shipday_is_out_on_the_pos_with_shipday_s_driver_and_its_time():
    ops, state = check()
    made, what = follow(said("PICKED_UP"), state)
    assert what == OUT and [(o.op_id, o.kind, o.device) for o in made] == [
        ("o-7:shipday-out-7001-501", "set_field", DEVICE)
    ]
    assert made[0].data == {
        "stage": "out",
        "driver": "Tom Reyes",
        "driver_id": "shipday:501",
        "out_at": NOW - 5 * 60_000,
        "by": BY,
        "shipday": {"id": 7001, "number": "1270166229", "state": "PICKED_UP", "at_ms": NOW - 5 * 60_000},
    }
    now = after(ops, made)
    assert (now.status, now.fields["stage"], now.fields["driver"]) == ("open", "out", "Tom Reyes")
    # further along the same road is out just the same, and a packed one leaves like one still cooking
    assert follow(said("READY_TO_DELIVER"), state)[1] == OUT
    assert follow(said("PICKED_UP"), check(op("set_field", stage="ready"))[1])[1] == OUT


def test_a_moment_shipday_names_is_taken_only_where_it_can_be_right():
    _, state = check()
    for named in (NOW - RECENT_MS - 1, NOW - 5 * 3_600_000, NOW + 60_000, None, "18:35", True):
        made, _ = follow(said("PICKED_UP", picked_up_ms=named), state)
        assert made[0].data["out_at"] == NOW, f"{named!r}: when the hub heard of it"
    assert follow(said("PICKED_UP", picked_up_ms=NOW - RECENT_MS), state)[0][0].data["out_at"] == NOW - RECENT_MS


def test_a_driver_shipday_does_not_name_or_none_at_all_is_still_somebody_s():
    _, state = check()
    made, _ = follow(said("PICKED_UP", driver={"id": 502, "name": "", "phone": ""}), state)
    assert (made[0].data["driver"], made[0].data["driver_id"]) == ("Shipday driver", "shipday:502")
    made, _ = follow(said("PICKED_UP", driver=None), state)
    assert (made[0].op_id, made[0].data["driver"], made[0].data["driver_id"]) == (
        "o-7:shipday-out-7001-0",
        "Shipday driver",
        "shipday",
    )


def test_delivered_with_nothing_to_pay_is_delivered_and_closed():
    out = op("set_field", stage="out", driver="Sam", driver_id="s7", out_at=NOW - 900_000)
    ops, state = check(out)  # somebody sent it out on the POS, with one of the POS's own drivers
    made, what = follow(said("ALREADY_DELIVERED", delivered_ms=NOW - 60_000), state)
    assert what == DELIVERED and [(o.op_id, o.kind) for o in made] == [
        ("o-7:shipday-delivered-7001", "set_field"),
        ("o-7:shipday-closed-7001", "close"),
    ]
    assert made[0].data == {
        "stage": "picked_up",
        "by": BY,
        "shipday": {"id": 7001, "number": "1270166229", "state": "ALREADY_DELIVERED", "at_ms": NOW - 60_000},
    }
    assert made[1].data == {"by": BY}
    now = after(ops, made)
    assert (now.status, now.fields["stage"], now.fields["driver"]) == ("closed", "picked_up", "Sam")


def test_delivered_before_the_hub_saw_it_leave_goes_out_first_so_its_history_says_who_took_it():
    ops, state = check()
    delivered = said("ALREADY_DELIVERED", picked_up_ms=NOW - 20 * 60_000, delivered_ms=NOW - 60_000)
    made, what = follow(delivered, state)
    assert what == DELIVERED and [o.op_id.split(":")[1] for o in made] == [
        "shipday-out-7001-501",
        "shipday-delivered-7001",
        "shipday-closed-7001",
    ]
    assert made[0].data["out_at"] == NOW - 20 * 60_000
    assert [o.hlc for o in made] == sorted(o.hlc for o in made), "in the order they are stamped"
    # a pickup Shipday puts after the delivery (a clock, a zone) never leaves later than it arrived
    late = said("ALREADY_DELIVERED", picked_up_ms=NOW - 30_000, delivered_ms=NOW - 60_000)
    assert follow(late, state)[0][0].data["out_at"] == NOW - 60_000
    now = after(ops, made)
    assert (now.status, now.fields["stage"], now.fields["driver_id"]) == ("closed", "picked_up", "shipday:501")


def test_delivered_with_money_due_stays_open_out_with_its_driver_and_says_what_shipday_said():
    ops, state = check()
    made, what = follow(said("ALREADY_DELIVERED", delivered_ms=NOW - 60_000), state, due=True)
    assert what == DUE and [o.op_id.split(":")[1] for o in made] == [
        "shipday-out-7001-501",
        "shipday-said-7001-ALREADY_DELIVERED",
    ]
    assert made[1].data == {
        "shipday": {"id": 7001, "number": "1270166229", "state": "ALREADY_DELIVERED", "at_ms": NOW - 60_000},
        "by": BY,
    }
    now = after(ops, made)
    assert (now.status, now.fields["stage"], now.fields["shipday"]["state"]) == ("open", "out", "ALREADY_DELIVERED")
    # one that was out already only gets the word
    made, what = follow(said("ALREADY_DELIVERED"), after(ops, made), due=True)
    assert what == DUE and [o.op_id.split(":")[1] for o in made] == ["shipday-said-7001-ALREADY_DELIVERED"]


def test_whether_money_is_due_is_asked_only_of_a_delivery_that_was_made():
    _, state = check()

    def never() -> bool:
        raise AssertionError("nobody asked what is due")

    for word in ("PICKED_UP", "READY_TO_DELIVER", "FAILED_DELIVERY", "INCOMPLETE", "STARTED"):
        ops_following(said(word), state, due=never, stamp=lambda: HLC(NOW, 1, DEVICE), now_ms=NOW)


def test_failed_and_incomplete_move_nothing_and_are_written_on_the_check():
    for word in ("FAILED_DELIVERY", "INCOMPLETE"):
        for ops, state in (check(), check(op("set_field", stage="out", driver="Sam", driver_id="s7"))):
            made, what = follow(said(word, ended_ms=NOW - 120_000), state)
            assert what == NOTED and [(o.op_id, o.kind) for o in made] == [
                (f"o-7:shipday-said-7001-{word}", "set_field")
            ]
            assert made[0].data == {
                "shipday": {"id": 7001, "number": "1270166229", "state": word, "at_ms": NOW - 120_000},
                "by": BY,
            }
            now = after(ops, made)
            assert (now.status, now.fields["stage"]) == ("open", state.fields["stage"]), "where it stood"


def test_a_check_the_kitchen_never_had_is_not_moved_only_told():
    ops, state = check(sent=False)
    for word, at_ms in (("PICKED_UP", NOW - 5 * 60_000), ("ALREADY_DELIVERED", NOW - 60_000)):
        made, what = follow(said(word, delivered_ms=NOW - 60_000), state)
        assert what == NOTED and [o.op_id.split(":")[1] for o in made] == [f"shipday-said-7001-{word}"]
        assert made[0].data["shipday"] == {"id": 7001, "number": "1270166229", "state": word, "at_ms": at_ms}
        now = after(ops, made)
        assert (now.status, now.fields["stage"]) == ("open", "new")


def test_a_check_that_is_out_already_is_not_sent_out_again():
    _, state = check(op("set_field", stage="out", driver="Sam", driver_id="s7", out_at=NOW - 900_000))
    assert follow(said("PICKED_UP"), state) == ((), "")
    assert follow(said("READY_TO_DELIVER"), state) == ((), "")


def test_nothing_is_written_for_a_check_that_is_closed_voided_delivered_or_no_delivery():
    words = ("PICKED_UP", "READY_TO_DELIVER", "ALREADY_DELIVERED", "FAILED_DELIVERY", "INCOMPLETE")
    stands = {
        "closed": check(op("close"))[1],
        "voided": check(op("void_order", reason="rung twice"))[1],
        "marked delivered": check(op("set_field", stage="picked_up"))[1],
        "the customer comes for it": check(handover="pickup")[1],
        "not on the POS": OrderState(order_id="o-7"),
    }
    for why, state in stands.items():
        for word in words:
            assert follow(said(word), state) == ((), ""), f"{why}, {word}"


def test_what_a_driver_has_not_picked_up_moves_nothing():
    _, state = check()
    for word in ("NOT_ASSIGNED", "NOT_ACCEPTED", "NOT_STARTED_YET", "STARTED", "GONE", "", None, "SOMETHING_NEW"):
        assert follow(said(word), state) == ((), ""), word


def test_every_step_has_a_fixed_id_and_another_driver_is_another_step():
    _, state = check()
    first, _ = follow(said("PICKED_UP"), state)
    again, _ = follow(said("READY_TO_DELIVER", picked_up_ms=NOW - 60_000), state)
    assert [o.op_id for o in first] == [o.op_id for o in again], "read twice, written once"
    other, _ = follow(said("PICKED_UP", driver={**WEI}), state)
    assert other[0].op_id == "o-7:shipday-out-7001-502"
    different, _ = follow(said("PICKED_UP", id=7002), state)
    assert different[0].op_id == "o-7:shipday-out-7002-501"


def test_a_screen_s_word_for_what_shipday_said_is_dropped():
    told = {"id": 1, "number": "x", "state": "ALREADY_DELIVERED", "at_ms": NOW}
    sent = op("set_field", stage="ready", shipday=told)
    assert own_word(sent).data == {"stage": "ready"} and own_word(sent).op_id == sent.op_id
    assert own_word(op("create", order_type="takeout", shipday=told)).data == {"order_type": "takeout"}
    plain = op("set_field", stage="ready")
    assert own_word(plain) is plain
    line = op("add_line", line_id="L1", item="Tea", shipday=told)
    assert own_word(line) is line, "only where an order's own fields are written"
