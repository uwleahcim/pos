"""A dish going from one check to another (the Toast comparison's row 3: move, merge, hand over): it goes
over as it is, sold once, with its price, its comp and whether the kitchen has it; it never leaves a check
without arriving on another; and it is neither a void nor a dish taken off."""

from __future__ import annotations

from fastapi.testclient import TestClient

from pos.sync.hlc import HLC
from pos.sync.oplog import replay

from ..conftest import T0, make_op
from . import test_counts as counts
from .test_adjustments import DUCK, TEA, client, payload
from .test_voids import approval, codes, lines, send, table

FROM_TEA = {"order_id": "o1", "line_id": "L1"}
FROM_DUCK = {"order_id": "o1", "line_id": "L2"}


def other_table(c: TestClient, order_id: str = "o2", table: str = "14") -> None:
    assert (
        send(c, payload(f"{order_id}-a", "create", 5, order_id, table=table, guests=2), order_id=order_id)["refused"]
        == []
    )


def take(c: TestClient, op_id: str, at: int, line_id: str, came: dict, order_id: str = "o2", **more) -> dict:
    """The check `order_id` takes a dish from where `came` says."""
    op = payload(op_id, "add_line", at, order_id, line_id=line_id, item="?", **{"from": came}, **more)
    return send(c, op, order_id=order_id)


def let_go(c: TestClient, op_id: str, at: int, line_id: str, to: dict, order_id: str = "o1") -> dict:
    return send(
        c, payload(op_id, "move_line", at, order_id, line_id=line_id, to=to, by="Amy", by_id="s1"), order_id=order_id
    )


def total(c: TestClient, order_id: str) -> str:
    return c.get(f"/orders/{order_id}/check").json()["total"]


# --- the log ----------------------------------------------------------------------------------------------


def test_a_dish_that_came_already_sent_is_not_sent_again_and_keeps_the_time_it_went():
    went = str(HLC(T0 + 3, 0, "a"))
    state = replay(
        [
            make_op("create", "o2", 0, table="14"),
            make_op(
                "add_line", "o2", 10, line_id="M1", item="Duck", **{"from": FROM_DUCK | {"table": "12"}}, sent=went
            ),
            make_op("add_line", "o2", 11, line_id="M2", item="Tea"),
            make_op("fire", "o2", 12, course="*"),
        ],
        "o2",
    )
    carried, own = state.lines["M1"], state.lines["M2"]
    assert carried.arrived_sent and str(carried.fired_at) == went and not carried.modified_after_fire
    assert carried.moved_from == {"order_id": "o1", "line_id": "L2", "table": "12"}
    assert not own.arrived_sent and own.fired_at.wall_ms == T0 + 12  # the fire sent what was the check's own
    assert state.snapshot()["lines"]["M1"]["moved_from"]["table"] == "12"
    # and the check it is on now says when the kitchen got it: at its old table, not when it came over
    assert [state.snapshot()["lines"][line]["sent_ms"] for line in ("M1", "M2")] == [T0 + 3, T0 + 12]


def test_sent_means_nothing_on_a_dish_that_names_no_check_it_came_from():
    state = replay([make_op("add_line", at=1, line_id="L1", item="Tea", sent=str(HLC(T0, 0, "a")))])
    assert state.lines["L1"].fired_at is None and not state.lines["L1"].arrived_sent


def test_a_dish_gone_to_another_check_is_off_this_one_and_says_where_it_went():
    ops = [
        make_op("add_line", at=1, line_id="L1", item="Tea"),
        make_op("fire", at=2, course="*"),
        make_op("move_line", at=3, line_id="L1", to={"order_id": "o2", "line_id": "M1"}, by="Amy", by_id="s1"),
    ]
    line = replay(ops).lines["L1"]
    assert line.status == "removed" and line.moved and not line.active
    assert line.moved_to == {
        "order_id": "o2",
        "line_id": "M1",
        "by": "Amy",
        "by_id": "s1",
        "device": "a",
        "at_ms": T0 + 3,
    }
    assert line.voided is None and line.removed is None  # neither a void nor a dish taken off
    # whichever of a void and a move came first stands
    void = make_op("void_line", at=4, line_id="L1", reason="rung-in-wrong")
    assert replay([*ops, void]).lines["L1"].moved
    early = make_op("void_line", at=2, node="b", line_id="L1")
    assert replay([*ops, early]).lines["L1"].status == "void" and not replay([*ops, early]).lines["L1"].moved
    # a move that names no check moves nothing
    nowhere = make_op("move_line", at=3, line_id="L1", to=None)
    assert replay([*ops[:2], nowhere]).lines["L1"].active


def test_a_move_that_reaches_the_log_before_its_dish_still_takes_it_off():
    move = make_op("move_line", at=3, line_id="L1", to={"order_id": "o2", "line_id": "M1"})
    add = make_op("add_line", at=1, line_id="L1", item="Tea")
    assert replay([move]).lines["L1"].moved
    assert replay([move, add]).snapshot() == replay([add, move]).snapshot()


# --- through the hub ------------------------------------------------------------------------------------


def test_a_sent_dish_goes_over_as_it_is_whatever_the_terminal_says_of_it():
    c = client()
    table(c)  # o1 at table 12: tea (L1) and a duck (L2), both sent, rung in by Amy
    other_table(c)
    before = total(c, "o1")
    # the terminal says where it goes; what it says of the dish itself is not believed
    answer = take(c, "t1", 20, "M1", FROM_DUCK, qty=5, priced=TEA, seat=2, by="Ben", sent="0-0-x", course="x")
    assert answer["refused"] == [] and answer["print_jobs"] == []
    dish = lines(c, "o2")["M1"]
    assert (dish["item"], dish["qty"], dish["seat"], dish["by"], dish["fired"]) == ("Duck", 1, 2, "Amy", True)
    assert dish["moved_from"] == {"order_id": "o1", "line_id": "L2", "table": "12"}
    stored = [op for op in c.get("/ops").json()["ops"] if op["op_id"] == "t1"][0]["data"]
    assert stored["priced"] == DUCK and stored["sent"] == str(HLC(T0 + 3, 0, "t1"))
    # for a moment the dish is on both checks, never on neither
    assert total(c, "o1") == before
    answer = let_go(c, "m1", 21, "L2", {"order_id": "o2", "line_id": "M1"})
    assert answer["refused"] == [] and answer["print_jobs"] == []
    gone = lines(c, "o1")["L2"]
    assert gone["status"] == "removed" and gone["moved_to"]["order_id"] == "o2" and gone["moved_to"]["by"] == "Amy"
    assert (total(c, "o1"), total(c, "o2")) == ("10.71", "21.40")
    # it is in neither report: nothing was voided and nothing was taken off
    report = c.get("/reports/adjustments").json()
    assert report["voids"] == [] and report["taken_off"] == []


def test_a_dish_not_sent_yet_goes_over_unsent_and_is_sent_from_its_new_check():
    c = client()
    send(c, payload("a", "create", 0, table="12"), payload("b", "add_line", 1, line_id="L1", item="Tea", priced=TEA))
    other_table(c)
    assert take(c, "t1", 20, "M1", FROM_TEA)["refused"] == []
    assert let_go(c, "m1", 21, "L1", {"order_id": "o2", "line_id": "M1"})["refused"] == []
    assert lines(c, "o2")["M1"]["fired"] is False
    assert c.get("/reports/adjustments").json()["taken_off"] == []
    send(c, payload("f", "fire", 30, "o2", course="*"), order_id="o2")
    assert lines(c, "o2")["M1"]["fired"] is True


def test_a_dish_cannot_leave_a_check_without_arriving_on_another():
    c = client()
    table(c)
    other_table(c)
    # nothing took it over there
    answer = let_go(c, "m1", 20, "L2", {"order_id": "o2", "line_id": "M1"})
    assert codes(answer) == [["not_arrived"]] and answer["refused"][0]["error"] == "invalid_move"
    assert lines(c, "o1")["L2"]["status"] == "active"
    # the tea went over, which lets the duck go nowhere
    assert take(c, "t1", 21, "M1", FROM_TEA)["refused"] == []
    assert codes(let_go(c, "m2", 22, "L2", {"order_id": "o2", "line_id": "M1"})) == [["not_arrived"]]
    assert codes(let_go(c, "m3", 23, "L2", {"order_id": "o9", "line_id": "M1"})) == [["not_arrived"]]
    assert codes(let_go(c, "m4", 24, "L2", None)) == [["not_arrived"]]
    assert lines(c, "o1")["L2"]["status"] == "active"
    assert let_go(c, "m5", 25, "L1", {"order_id": "o2", "line_id": "M1"})["refused"] == []


def test_a_dish_that_is_not_there_to_take_is_not_taken():
    c = client()
    table(c)
    other_table(c)
    assert codes(take(c, "t1", 20, "M1", {"order_id": "o9", "line_id": "L1"})) == [["unknown_source"]]
    assert codes(take(c, "t2", 21, "M1", {"order_id": "o1", "line_id": "L9"})) == [["unknown_source"]]
    assert codes(take(c, "t3", 22, "M1", "o1")) == [["unknown_source"]]
    assert codes(take(c, "t4", 23, "L9", FROM_TEA, order_id="o1")) == [["unknown_source"]]  # from itself
    # voided meanwhile on its own check: it is not brought back to life on another
    void = payload("v", "void_line", 24, line_id="L1", reason="rung-in-wrong", approval=approval(c))
    assert send(c, void)["refused"] == []
    assert codes(take(c, "t5", 25, "M1", FROM_TEA)) == [["gone"]]
    assert lines(c, "o2") == {}


def test_a_sent_dish_that_came_over_is_voided_like_any_sent_dish():
    c = client()
    table(c)
    other_table(c)
    take(c, "t1", 20, "M1", FROM_DUCK)
    let_go(c, "m1", 21, "L2", {"order_id": "o2", "line_id": "M1"})
    bare = send(c, payload("v1", "void_line", 30, "o2", line_id="M1"), order_id="o2")
    assert codes(bare) == [["unknown_reason", "needs_approval"]]
    word = {"reason": "rung-in-wrong", "approval": approval(c, "o2")}
    assert send(c, payload("v2", "void_line", 31, "o2", line_id="M1", **word), order_id="o2")["refused"] == []
    assert [v["line_id"] for v in c.get("/reports/adjustments").json()["voids"]] == ["M1"]


def test_the_comp_on_a_dish_comes_along_with_who_approved_it():
    c = client()
    table(c)
    other_table(c)
    comp = {"reason": "comp", "kind": "comp", "applied_by": "Amy", "approval": approval(c, purpose="adjust")}
    assert send(c, payload("d", "discount", 10, discount_id="D1", line_id="L2", **comp))["refused"] == []
    came = {"order_id": "o1", "discount_id": "D1"}
    answer = send(
        c,
        payload("t1", "add_line", 20, "o2", line_id="M1", item="?", **{"from": FROM_DUCK}),
        # no approval is asked again, and what the terminal says of the discount is not believed
        payload(
            "t2", "discount", 21, "o2", discount_id="E1", line_id="M1", kind="percent", value="1", **{"from": came}
        ),
        order_id="o2",
    )
    assert answer["refused"] == []
    let_go(c, "m1", 22, "L2", {"order_id": "o2", "line_id": "M1"})
    check = c.get("/orders/o2/check").json()
    assert [(d["discount_id"], d["line_id"], d["kind"], d["approved_by"]["name"]) for d in check["discounts"]] == [
        ("E1", "M1", "comp", "Mike")
    ]
    assert check["total"] == "0.00" and total(c, "o1") == "10.71"
    kept = c.get("/orders/o2").json()["discounts"]["E1"]
    assert kept["from"] == came and kept["applied_by"] == "Amy"
    # once only, and only onto the dish it was on
    again = send(
        c, payload("t3", "discount", 30, "o2", discount_id="E2", line_id="M1", **{"from": came}), order_id="o2"
    )
    assert codes(again) == [["unknown_source"]]


def test_a_discount_comes_along_only_with_its_own_dish():
    c = client()
    table(c)
    other_table(c)
    comp = {"reason": "comp", "kind": "comp", "applied_by": "Amy", "approval": approval(c, purpose="adjust")}
    send(c, payload("d", "discount", 10, discount_id="D1", line_id="L2", **comp))
    came = {"order_id": "o1", "discount_id": "D1"}
    # the tea came over, the comp was on the duck
    tea = [
        payload("t1", "add_line", 20, "o2", line_id="M1", item="?", **{"from": FROM_TEA}),
        payload("t2", "discount", 21, "o2", discount_id="E1", line_id="M1", **{"from": came}),
    ]
    assert codes(send(c, *tea, order_id="o2")) == [["unknown_source"]]
    # a dish rung in here has nothing to bring
    own = [
        payload("t3", "add_line", 22, "o2", line_id="N1", item="Tea", priced=TEA),
        payload("t4", "discount", 23, "o2", discount_id="E2", line_id="N1", **{"from": came}),
    ]
    assert codes(send(c, *own, order_id="o2")) == [["unknown_source"]]
    for bad in ({"order_id": "o1", "discount_id": "D9"}, {"order_id": "o9", "discount_id": "D1"}, "D1"):
        op = payload(f"x{bad}", "discount", 24, "o2", discount_id="E3", line_id="M1", **{"from": bad})
        assert codes(send(c, op, order_id="o2")) == [["unknown_source"]]
    assert c.get("/orders/o2/check").json()["discounts"] == []


def test_the_last_one_of_a_counted_dish_can_still_change_tables():
    c = counts.client()
    counts.count(c, remaining=1)
    counts.send(c, "o1", counts.payload("o1", "open", "create", 0, table="12"))
    counts.send(c, "o2", counts.payload("o2", "open", "create", 0, table="14"))
    assert counts.add(c, "o1", "L1", 1)["refused"] == []
    assert counts.left(c) == 0
    over = counts.payload("o2", "t1", "add_line", 10, line_id="M1", item="?", **{"from": FROM_TEA})
    assert counts.send(c, "o2", over)["refused"] == []  # none left, and it goes over all the same
    assert counts.left(c) == 0
    away = counts.payload("o1", "m1", "move_line", 11, line_id="L1", to={"order_id": "o2", "line_id": "M1"})
    assert counts.send(c, "o1", away)["refused"] == []
    assert counts.left(c) == 0  # sold once: nothing came back when it left its first check
    # taken off where it is now, it comes back
    counts.send(c, "o2", counts.payload("o2", "v", "void_line", 12, line_id="M1"))
    assert counts.left(c) == 1


def test_a_hub_that_moves_dishes_says_so_to_the_screens():
    c = client()
    table(c)
    assert c.get("/orders/o1/check").json()["moves"] is True
    assert c.get("/floor").json()["moves"] is True


def test_a_check_emptied_into_another_says_where_its_dishes_went():
    c = client()
    table(c)
    other_table(c)
    for n, (line_id, came) in enumerate((("M1", FROM_TEA), ("M2", FROM_DUCK))):
        take(c, f"t{n}", 20 + n, line_id, came)
        let_go(c, f"m{n}", 30 + n, came["line_id"], {"order_id": "o2", "line_id": line_id})
    send(c, payload("s", "set_field", 40, merged_into="o2"), payload("z", "close", 41))
    old = c.get("/orders/o1").json()
    assert old["status"] == "closed" and old["fields"]["merged_into"] == "o2"
    assert total(c, "o1") == "0.00" and total(c, "o2") == "32.11"
    assert "12" not in c.get("/floor").json()["status"]
