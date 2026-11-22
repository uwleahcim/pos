"""Whose turn the next table is (pos.floor.turn): who is in tonight's turn, by a host's word or the time
clock, and the order they take their tables in."""

from __future__ import annotations

from datetime import date, datetime

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.floor.turn import NOBODY, Word, in_turn, last_sat, punched, said, say
from pos.identity.staff import Directory, Staff
from pos.menu.fixtures.example import build_example
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.settings import SettingStore, clean_time_clock
from pos.sync.hlc import HLC
from pos.sync.oplog import Op, OpStore, OrderState, replay
from pos.timeclock import Shift, TimeClock

MINUTE = 60_000
DAY = date(2026, 11, 16)


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """A time on the restaurant's own clock in November 2026, in wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


class Wall:
    """The hub's clock, set by the test."""

    def __init__(self, now: int) -> None:
        self.now = now

    def __call__(self) -> int:
        return self.now


STAFF = [
    Staff.with_pin("s1", "Amy", "server", "1111"),
    Staff.with_pin("s2", "Ben", "bartender", "2222"),
    Staff.with_pin("s3", "Mike", "manager", "9999"),
    Staff.with_pin("s4", "Holly", "host", "3333"),
    Staff.with_pin("s5", "Carl", "server", "5555"),
    Staff.with_pin("s6", "Dan", "server", "6666"),
]
TAKERS = [{"staff_id": s.staff_id, "name": s.name} for s in STAFF if s.role != "host"]


def hub(now: int = at(17), *, clock_on: bool = False) -> tuple[TestClient, Wall]:
    wall = Wall(now)
    settings = SettingStore()
    settings.put("time_clock", clean_time_clock({"enabled": clock_on}))
    app = create_app(
        OpStore(physical=wall),
        staff=Directory(STAFF),
        menu=MenuService(build_example()),
        printing=PrintService([]),
        settings=settings,
        clock=TimeClock(now_ms=wall),
    )
    return TestClient(app), wall


def turn(c: TestClient) -> list[str]:
    return c.get("/floor").json()["turn"]


def word(c: TestClient, server: str, on: bool = True, by: str = "s4") -> list[str]:
    r = c.post("/floor/turn", json={"staff_id": by, "server_id": server, "on": on})
    assert r.status_code == 200, r.text
    return r.json()["turn"]


def refused(c: TestClient, server: str, on: bool = True, by: str = "s4") -> tuple[int, str]:
    r = c.post("/floor/turn", json={"staff_id": by, "server_id": server, "on": on})
    return r.status_code, r.json()["detail"]["error"]


def seat(c: TestClient, wall: Wall, order: str, table: str, server: str, **more) -> None:
    """A party is sat at `table` for `server` now, as the terminal sends it."""
    name = next(s.name for s in STAFF if s.staff_id == server)
    op = {
        "op_id": f"{order}-create",
        "order_id": order,
        "hlc": str(HLC(wall.now, 0, "t1")),
        "device": "t1",
        "kind": "create",
        "data": {"table": table, "guests": 2, "server": name, "server_id": server, **more},
    }
    r = c.post(f"/orders/{order}/ops", json=[op])
    assert r.status_code == 202 and r.json()["accepted"] == [op["op_id"]], r.text


def punch(c: TestClient, pin: str, action: str) -> None:
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": action})
    assert r.status_code == 200, r.text


def order(order_id: str, opened: int, **fields) -> OrderState:
    """An order as the log replays it, opened at `opened`; `status` closes or voids it."""
    status = fields.pop("status", "open")
    ops = [Op(f"{order_id}-a", order_id, HLC(opened, 0, "t1"), "t1", "create", fields)]
    if status != "open":
        kind = "void_order" if status == "void" else "close"
        ops.append(Op(f"{order_id}-b", order_id, HLC(opened + 1, 0, "t1"), "t1", kind, {}))
    return replay(ops, order_id)


# The host's words --------------------------------------------------------------------------------------------


def test_nothing_was_said_until_a_host_says_it():
    assert said(NOBODY, DAY) == {}
    assert said({}, DAY) == {} and said({"day": DAY.isoformat(), "said": "everybody"}, DAY) == {}


def test_a_word_is_kept_for_the_day_it_was_said_on():
    stored = say(NOBODY, DAY, "s1", True, at_ms=at(17), by_id="s4", by="Holly")
    stored = say(stored, DAY, "s5", False, at_ms=at(17, 5), by_id="s4", by="Holly")
    assert stored["day"] == "2026-11-16"
    assert stored["said"]["s1"] == {"on": True, "at_ms": at(17), "by_id": "s4", "by": "Holly"}
    assert said(stored, DAY) == {"s1": Word(True, at(17)), "s5": Word(False, at(17, 5))}
    assert said(stored, date(2026, 11, 17)) == {}  # the next day nobody has been said to be on

    # the next day's first word leaves yesterday's behind
    monday = say(stored, date(2026, 11, 17), "s6", True, at_ms=at(11, day=17), by_id="s3", by="Mike")
    assert (monday["day"], list(monday["said"])) == ("2026-11-17", ["s6"])


def test_the_latest_word_on_a_person_is_the_one_that_stands():
    stored = say(NOBODY, DAY, "s1", True, at_ms=at(17), by_id="s4", by="Holly")
    stored = say(stored, DAY, "s1", False, at_ms=at(20, 30), by_id="s3", by="Mike")
    assert said(stored, DAY) == {"s1": Word(False, at(20, 30))}


def test_a_word_that_cannot_be_read_was_never_said():
    stored = {
        "day": "2026-11-16",
        "said": {"s1": {"on": "yes", "at_ms": 5}, "s5": {"on": True}, "s6": "in", "s2": {"on": True, "at_ms": True}},
    }
    assert said(stored, DAY) == {}


# The time clock ---------------------------------------------------------------------------------------------


def shift(staff_id: str, role: str, in_ms: int, out_ms: int | None = None, **more) -> Shift:
    return Shift(f"{staff_id}-{in_ms}", staff_id, staff_id, role, in_ms, out_ms, **more)


def test_a_server_on_the_clock_is_in_and_whoever_clocked_out_is_out():
    punches = punched(
        [
            shift("s1", "server", at(16)),
            shift("s5", "server", at(11), at(15)),
            shift("s2", "bartender", at(16)),  # tends the bar: a host says so when he is to take tables
            shift("s3", "manager", at(10), at(22)),
        ]
    )
    assert punches == {"s1": Word(True, at(16)), "s5": Word(False, at(15)), "s3": Word(False, at(22))}


def test_a_persons_latest_shift_counts_and_one_taken_off_counts_for_nothing():
    lunch, dinner = shift("s1", "server", at(11), at(15)), shift("s1", "server", at(17))
    assert punched([lunch, dinner]) == punched([dinner, lunch]) == {"s1": Word(True, at(17))}
    assert punched([lunch, shift("s1", "server", at(17), removed=True)]) == {"s1": Word(False, at(15))}
    assert punched([shift("s5", "server", at(17), removed=True)]) == {}


# When each one was last sat ---------------------------------------------------------------------------------


def test_a_table_counts_for_whoever_it_is_with_from_the_moment_it_was_opened():
    since = at(4)
    orders = [
        order("o1", at(17, 5), table="A1", server_id="s1"),
        order("o2", at(18, 20), table="A2", server_id="s1", status="closed"),  # paid and gone: she was sat it
        order("o3", at(17, 40), table="B1", server_id="s5"),
        order("o4", at(19), table="B2", server_id="s5", status="void"),  # opened by mistake: no table
        order("o5", at(19, 30), server_id="s6"),  # an order to go: nobody's turn
        order("o6", at(19, 45), table="", server_id="s6"),
        order("o7", at(3, 30), table="C1", server_id="s6"),  # last night's
        order("o8", at(20), table="C2"),  # nobody's yet
    ]
    assert last_sat(orders, since) == {"s1": at(18, 20), "s5": at(17, 40)}


# The turn ---------------------------------------------------------------------------------------------------


def test_nobody_is_in_the_turn_that_nothing_said_was_on():
    assert in_turn(TAKERS, {}, {}, {"s1": at(18)}) == []


def test_those_with_no_table_yet_go_first_in_the_order_they_came_then_the_one_sat_longest_ago():
    words = {"s1": Word(True, at(16, 50)), "s5": Word(True, at(16, 55)), "s6": Word(True, at(18))}
    assert in_turn(TAKERS, words, {}, {}) == ["s1", "s5", "s6"]
    assert in_turn(TAKERS, words, {}, {"s1": at(17, 5)}) == ["s5", "s6", "s1"]
    assert in_turn(TAKERS, words, {}, {"s1": at(17, 5), "s5": at(17, 1)}) == ["s6", "s5", "s1"]
    sat = {"s1": at(17, 5), "s5": at(17, 1), "s6": at(18, 30)}
    assert in_turn(TAKERS, words, {}, sat) == ["s5", "s1", "s6"]


def test_somebody_taken_out_is_not_in_it_and_keeps_their_place_for_when_they_are_back():
    sat = {"s1": at(17, 5), "s5": at(17, 1), "s6": at(18, 30)}
    words = {"s1": Word(True, at(16, 50)), "s5": Word(False, at(20)), "s6": Word(True, at(18))}
    assert in_turn(TAKERS, words, {}, sat) == ["s1", "s6"]
    assert in_turn(TAKERS, {**words, "s5": Word(True, at(20, 30))}, {}, sat) == ["s5", "s1", "s6"]


def test_the_later_of_a_hosts_word_and_the_time_clock_stands():
    clocked_in, clocked_out = {"s1": Word(True, at(16))}, {"s1": Word(False, at(21))}
    assert in_turn(TAKERS, {}, clocked_in, {}) == ["s1"]
    assert in_turn(TAKERS, {"s1": Word(False, at(20))}, clocked_in, {}) == []  # cut for the night
    assert in_turn(TAKERS, {"s1": Word(True, at(16, 30))}, clocked_out, {}) == []  # went home after
    assert in_turn(TAKERS, {"s1": Word(True, at(21, 30))}, clocked_out, {}) == ["s1"]  # stayed for one more
    # said in the same instant, the host's word is the one that stands
    assert in_turn(TAKERS, {"s1": Word(False, at(16))}, clocked_in, {}) == []


def test_only_somebody_a_table_can_be_given_to_is_in_the_turn():
    words = {"s4": Word(True, at(17)), "gone": Word(True, at(17)), "s2": Word(True, at(17, 1))}
    assert in_turn(TAKERS, words, {}, {}) == ["s2"]  # the host takes none; the bartender does when a host says so


def test_two_who_came_in_together_go_by_name():
    words = {"s6": Word(True, at(17)), "s1": Word(True, at(17)), "s5": Word(True, at(17))}
    assert in_turn(TAKERS, words, {}, {}) == ["s1", "s5", "s6"]  # Amy, Carl, Dan


# Through the hub --------------------------------------------------------------------------------------------


def test_the_floor_has_no_turn_until_a_host_says_who_is_on():
    c, wall = hub()
    assert turn(c) == []
    seat(c, wall, "o1", "A1", "s1")
    assert turn(c) == []  # a table alone puts nobody in: the hub does not guess who is working


def test_a_host_says_who_is_on_and_the_turn_goes_round():
    c, wall = hub(at(16, 50))
    assert word(c, "s1") == ["s1"]
    wall.now = at(16, 51)
    assert word(c, "s5") == ["s1", "s5"]
    wall.now = at(16, 52)
    assert word(c, "s6", by="s3") == ["s1", "s5", "s6"]  # a manager gives tables out too
    assert turn(c) == ["s1", "s5", "s6"]

    wall.now = at(17, 5)
    seat(c, wall, "o1", "A1", "s1", by="Holly", by_id="s4")
    assert turn(c) == ["s5", "s6", "s1"]
    wall.now = at(17, 10)
    seat(c, wall, "o2", "A2", "s1", by="Holly", by_id="s4")  # Carl is passed over: he is still next
    assert turn(c) == ["s5", "s6", "s1"]
    wall.now = at(17, 20)
    seat(c, wall, "o3", "A3", "s6")  # Dan opens a table himself: that was his turn
    assert turn(c) == ["s5", "s1", "s6"]
    wall.now = at(17, 30)
    seat(c, wall, "o4", "A4", "s5")
    assert turn(c) == ["s1", "s6", "s5"]


def test_a_table_handed_over_counts_for_the_one_who_took_it():
    c, wall = hub(at(16, 50))
    word(c, "s1")
    wall.now = at(16, 51)
    word(c, "s5")
    wall.now = at(17, 5)
    seat(c, wall, "o1", "A1", "s1")
    assert turn(c) == ["s5", "s1"]
    give = {
        "op_id": "o1-give",
        "order_id": "o1",
        "hlc": str(HLC(at(17, 6), 0, "t1")),
        "device": "t1",
        "kind": "set_field",
        "data": {"server": "Carl", "server_id": "s5", "by": "Holly", "by_id": "s4"},
    }
    wall.now = at(17, 6)
    assert c.post("/orders/o1/ops", json=[give]).json()["accepted"] == ["o1-give"]
    assert turn(c) == ["s1", "s5"]  # Amy has no table again; Carl has had his


def test_somebody_cut_for_the_night_is_out_and_comes_back_where_they_stood():
    c, wall = hub(at(16, 50))
    for minute, server in enumerate(("s1", "s5", "s6")):
        wall.now = at(16, 50 + minute)
        word(c, server)
    wall.now = at(17, 5)
    seat(c, wall, "o1", "A1", "s1")
    wall.now = at(20)
    assert word(c, "s5", on=False) == ["s6", "s1"]
    assert c.app.state.settings.get("turn")["said"]["s5"] == {
        "on": False,
        "at_ms": at(20),
        "by_id": "s4",
        "by": "Holly",
    }
    wall.now = at(20, 30)
    assert word(c, "s5") == ["s6", "s5", "s1"]  # no table yet tonight, and in after Dan


def test_the_bartender_is_in_when_a_host_says_so():
    c, _ = hub()
    assert word(c, "s2") == ["s2"]
    assert word(c, "s3") == ["s2", "s3"]  # and a manager working the floor


def test_only_whoever_gives_tables_out_says_who_is_in_the_turn():
    c, _ = hub()
    assert refused(c, "s5", by="s1") == (403, "not_allowed")  # a server
    assert refused(c, "s5", by="s2") == (403, "not_allowed")  # the bartender
    assert refused(c, "s5", by="nobody") == (404, "unknown_staff")
    assert refused(c, "nobody") == (404, "unknown_staff")
    assert refused(c, "s4") == (422, "no_tables")  # the host takes no tables
    assert turn(c) == [] and c.app.state.settings.get("turn") == NOBODY
    assert word(c, "s4", on=False) == []  # taking somebody out is never refused


def test_the_words_are_for_tonight():
    c, wall = hub(at(17))
    word(c, "s1")
    wall.now = at(3, 30, day=17)  # half past three in the morning is still tonight
    assert turn(c) == ["s1"]
    wall.now = at(11, day=17)
    assert turn(c) == []
    assert word(c, "s5") == ["s5"]
    assert list(c.app.state.settings.get("turn")["said"]) == ["s5"]  # yesterday's are gone


def test_with_the_time_clock_on_the_servers_come_in_as_they_clock_in():
    c, wall = hub(at(16), clock_on=True)
    assert turn(c) == []
    punch(c, "1111", "in")  # Amy
    wall.now = at(16, 10)
    punch(c, "2222", "in")  # Ben tends the bar
    punch(c, "9999", "in")  # Mike runs the floor
    wall.now = at(16, 20)
    punch(c, "5555", "in")  # Carl
    assert turn(c) == ["s1", "s5"]

    wall.now = at(17)
    seat(c, wall, "o1", "A1", "s1")
    assert turn(c) == ["s5", "s1"]
    wall.now = at(17, 30)
    punch(c, "5555", "break_start")  # on a break he is still on the clock: the host passes him over
    assert turn(c) == ["s5", "s1"]
    wall.now = at(21)
    punch(c, "5555", "break_end")
    punch(c, "5555", "out")
    assert turn(c) == ["s1"]


def test_a_hosts_word_and_the_time_clock_take_turns_at_being_the_later():
    c, wall = hub(at(16), clock_on=True)
    punch(c, "1111", "in")
    wall.now = at(20)
    assert word(c, "s1", on=False) == []  # cut, and finishing her tables on the clock
    wall.now = at(20, 15)
    assert word(c, "s2") == ["s2"]  # the bartender takes the late tables
    wall.now = at(22)
    punch(c, "2222", "in")
    punch(c, "2222", "out")  # a punch made and taken back at ten: he has gone home
    assert turn(c) == []


def test_a_location_that_does_not_use_the_clock_is_not_asked_what_it_says():
    c, wall = hub(at(16), clock_on=True)
    punch(c, "1111", "in")
    assert turn(c) == ["s1"]
    c.app.state.settings.put("time_clock", clean_time_clock({"enabled": False}))
    assert turn(c) == []


def test_the_screens_are_told_when_the_turn_changes():
    c, wall = hub(at(16), clock_on=True)
    told: list[str] = []
    c.app.state.feed.changed = told.append
    word(c, "s1")
    assert told == ["floor"]
    refused(c, "s5", by="s1")
    assert told == ["floor"]  # a word that was refused changed nothing
    punch(c, "5555", "state")
    assert told == ["floor"]  # looking at the clock is no punch
    punch(c, "5555", "in")
    assert told == ["floor", "floor"]


def test_the_floor_reads_as_unchanged_until_the_turn_moves():
    c, wall = hub()
    first = c.get("/floor")
    assert c.get("/floor", headers={"if-none-match": first.headers["etag"]}).status_code == 304
    word(c, "s1")
    assert c.get("/floor", headers={"if-none-match": first.headers["etag"]}).status_code == 200


@pytest.mark.parametrize("body", [{"staff_id": "s4"}, {"staff_id": "s4", "server_id": "s1", "on": "maybe"}, {}])
def test_a_word_that_is_not_one_is_refused(body):
    c, _ = hub()
    assert c.post("/floor/turn", json=body).status_code == 422
    assert turn(c) == []
