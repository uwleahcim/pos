"""The timer on each table of the floor map: what an open check is waiting on and since when, read from the
order log (`pos.floor.check_timer`), and the location's warning times (`table_timers` in `pos.settings`)."""

from __future__ import annotations

import pytest

from pos.floor import STAGES, check_timer
from pos.settings import DEFAULTS, SettingStore, clean_table_timers
from pos.sync.oplog import replay

from ..conftest import T0, make_op
from .test_menu_orders import GTC_QUART, client, payload

MIN = 60_000
COURSES = ["drinks", "1", "2", "3"]


def timer(*ops, courses=COURSES):
    """The timer of the check these ops make, as (stage, minutes after T0)."""
    found = check_timer(replay(ops, "o1"), courses)
    return found and (found["stage"], (found["since_ms"] - T0) / MIN)


def add(at: float, line_id: str, course: str | None = "1"):
    return make_op("add_line", at=int(at * MIN), line_id=line_id, item="x", course=course)


def fire(at: float, course: str = "*"):
    return make_op("fire", at=int(at * MIN), course=course)


def test_a_table_with_nothing_on_its_check_has_been_sat_since_it_was_opened():
    opened = make_op("create", at=0, table="A7", guests=4)
    assert timer(opened) == ("sat", 0)
    # a dish put on and taken off again before the kitchen saw it: still nothing ordered
    assert timer(opened, add(3, "L1"), make_op("void_line", at=4 * MIN, line_id="L1")) == ("sat", 0)
    assert check_timer(replay([], "o1")) is None  # no check at all


def test_dishes_nobody_sent_are_timed_from_the_first_of_them():
    opened = make_op("create", at=0, table="A7")
    assert timer(opened, add(2, "L1"), add(6, "L2", "2")) == ("unsent", 2)
    # moving a dish about on the check does not start its wait over
    moved = make_op("set_line", at=7 * MIN, line_id="L1", course="1", rank=9.0)
    assert timer(opened, add(2, "L1"), add(6, "L2", "2"), moved) == ("unsent", 2)


def test_a_held_course_is_timed_from_when_the_course_before_it_went():
    opened = make_op("create", at=0, table="A7")
    both = [opened, add(1, "app"), add(1, "main", "2"), add(1, "cake", "3")]
    assert timer(*both, fire(2, "1")) == ("held", 2)  # the mains wait since the appetizers went
    # a first drink sent in the middle of it does not start the mains' wait over
    drink = [add(9, "beer", "drinks"), fire(9, "drinks")]
    assert timer(*both, fire(2, "1"), *drink) == ("held", 2)
    # once the mains go, dessert has waited since then, not since it was put on the check
    assert timer(*both, fire(2, "1"), fire(20, "2")) == ("held", 20)
    # a main ordered after the starters were eaten has only waited since it was ordered
    late = [opened, add(1, "app"), fire(2, "1"), add(40, "main", "2")]
    assert timer(*late) == ("held", 40)


def test_a_held_course_the_kitchen_order_does_not_place_is_timed_from_the_last_course_to_go():
    ops = [make_op("create", at=0, table="A7"), add(1, "app"), add(1, "odd", "chef"), fire(3, "1")]
    assert timer(*ops) == ("held", 3)
    assert timer(*ops, courses=[]) == ("held", 3)  # coursing switched off since


def test_a_late_addition_to_a_course_that_has_gone_is_unsent_and_goes_before_a_held_course():
    opened = make_op("create", at=0, table="A7")
    going = [opened, add(1, "app"), add(1, "main", "2"), fire(2, "1")]
    assert timer(*going, add(12, "app2")) == ("unsent", 12)  # another appetizer nobody fired
    assert timer(*going, add(12, "app2"), fire(13, "1")) == ("held", 2)  # sent: the mains' wait shows again
    # after "fire everything", whatever comes onto the check is a late addition
    assert timer(opened, add(1, "a", None), fire(2), add(30, "b", None)) == ("unsent", 30)


def test_a_table_with_everything_sent_is_timed_from_the_last_dish_to_go():
    opened = make_op("create", at=0, table="A7")
    assert timer(opened, add(1, "app"), fire(2)) == ("fired", 2)
    assert timer(opened, add(1, "app"), fire(2), add(30, "beer"), fire(31)) == ("fired", 31)
    # the beer sent and then voided: what is left went at 2
    voided = make_op("void_line", at=33 * MIN, line_id="beer")
    assert timer(opened, add(1, "app"), fire(2), add(30, "beer"), fire(31), voided) == ("fired", 2)
    # everything sent and voided: the table sits with nothing since the last dish went
    gone = make_op("void_line", at=5 * MIN, line_id="app")
    assert timer(opened, add(1, "app"), fire(2), gone) == ("sat", 2)


def test_the_floor_says_what_each_table_waits_on_and_carries_the_warning_times():
    c = client()
    c.post(
        "/orders/o1/ops",
        json=[
            payload("a", "create", 0, table="A7", guests=4, server="Amy"),
            payload("b", "add_line", 10, line_id="L1", item="?", course="1", request={"variant_id": "CALROLL:roll"}),
            payload("c", "add_line", 20, line_id="L2", item="?", course="2", request=GTC_QUART),
        ],
    )
    floor = c.get("/floor").json()
    assert floor["status"]["A7"][0]["timer"] == {"stage": "unsent", "since_ms": T0 + 10}
    assert floor["timers"] == DEFAULTS["table_timers"]
    c.post("/orders/o1/ops", json=[payload("d", "fire", 30, course="1")])
    assert c.get("/floor").json()["status"]["A7"][0]["timer"] == {"stage": "held", "since_ms": T0 + 30}
    c.post("/orders/o1/ops", json=[payload("e", "fire", 40, course="2")])
    assert c.get("/floor").json()["status"]["A7"][0]["timer"] == {"stage": "fired", "since_ms": T0 + 40}

    # the answer does not move with the clock: a screen that has it is told so until something changes
    first = c.get("/floor")
    again = c.get("/floor", headers={"if-none-match": first.headers["etag"]})
    assert again.status_code == 304


def test_the_default_times_cover_every_stage():
    timers = SettingStore().get("table_timers")
    assert timers["enabled"] is True and set(timers["stages"]) == set(STAGES)
    assert timers["stages"]["sat"] == {"warn": 5, "late": 10}
    assert timers["stages"]["fired"] == {"warn": 25, "late": 0}  # a nudge, never overdue
    assert clean_table_timers(DEFAULTS["table_timers"]) == DEFAULTS["table_timers"]
    # a stage left out keeps its default, on the way in and in what an older row holds
    held = {"stages": {"held": {"warn": 10, "late": 20}}}
    assert clean_table_timers(held)["stages"]["sat"] == {"warn": 5, "late": 10}
    assert SettingStore().put("table_timers", held)["stages"]["unsent"]["late"] == 10


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ({"enabled": "yes"}, "enabled"),
        ({"stages": [1, 2]}, "stages"),
        ({"stages": {"eating": {"warn": 5, "late": 10}}}, "unknown stage"),
        ({"stages": {"sat": 5}}, "warn and late"),
        ({"stages": {"sat": {"warn": 2.5, "late": 10}}}, "whole number"),
        ({"stages": {"sat": {"warn": True, "late": 10}}}, "whole number"),
        ({"stages": {"sat": {"warn": -1, "late": 10}}}, "0 \\(never\\)"),
        ({"stages": {"sat": {"warn": 5, "late": 100_000}}}, "0 \\(never\\)"),
        ({"stages": {"sat": {"warn": 10, "late": 10}}}, "after its warning"),
        ({"stages": {"held": {"warn": 30, "late": 20}}}, "after its warning"),
    ],
)
def test_bad_table_timers_are_refused_with_the_reason(body, problem):
    with pytest.raises(ValueError, match=problem):
        clean_table_timers(body)


def test_either_time_of_a_stage_can_be_switched_off():
    cleaned = clean_table_timers({"stages": {"sat": {"warn": 0, "late": 8}, "fired": {"warn": 0, "late": 0}}})
    assert cleaned["stages"]["sat"] == {"warn": 0, "late": 8}
    assert cleaned["stages"]["fired"] == {"warn": 0, "late": 0}  # this stage is not timed at all


def test_the_timers_are_set_by_a_manager_and_every_floor_map_follows():
    c = client()
    assert c.get("/settings/table_timers").json() == DEFAULTS["table_timers"]
    body = {"enabled": True, "stages": {"held": {"warn": 12, "late": 18}}}
    assert c.put("/settings/table_timers", json=body).status_code == 401
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    auth = {"authorization": f"Bearer {token}"}
    saved = c.put("/settings/table_timers", json=body, headers=auth).json()
    assert saved["stages"]["held"] == {"warn": 12, "late": 18} and saved["stages"]["sat"] == {"warn": 5, "late": 10}
    assert c.get("/floor").json()["timers"] == saved

    r = c.put("/settings/table_timers", json={"stages": {"held": {"warn": 30, "late": 20}}}, headers=auth)
    assert r.status_code == 422 and "after its warning" in r.json()["detail"]["message"]

    off = c.put("/settings/table_timers", json={**saved, "enabled": False}, headers=auth).json()
    assert off["enabled"] is False and off["stages"] == saved["stages"]  # the times stay for when it is back on
