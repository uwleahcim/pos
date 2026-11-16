"""The time clock: a person clocks in and out and takes breaks with their own PIN, the hub's clock stamps every
punch, a shift nobody ended is closed when the night is over and marked, and a manager's corrections change
the hours only through a log that keeps what they were, who changed them and why."""

from __future__ import annotations

import os
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.fixtures.example import build_example
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.settings import DEFAULTS, SettingStore, clean_time_clock
from pos.sync.oplog import OpStore
from pos.timeclock import ClockStore, Refused, TimeClock, night_cutoff_ms

DSN = os.environ.get("POS_TEST_DATABASE_URL")

MINUTE = 60_000
HOUR = 60 * MINUTE


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """A time on the restaurant's own clock in November 2026, in wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


class Wall:
    """The hub's clock, set by the test."""

    def __init__(self, now: int) -> None:
        self.now = now

    def __call__(self) -> int:
        return self.now


def clock_at(now: int, store: ClockStore | None = None) -> tuple[TimeClock, Wall]:
    wall = Wall(now)
    return TimeClock(store, now_ms=wall), wall


def hub(now: int = at(16), *, on: bool = True, breaks_paid: bool = False) -> tuple[TestClient, Wall]:
    clock, wall = clock_at(now)
    settings = SettingStore()
    settings.put("time_clock", clean_time_clock({"enabled": on, "breaks_paid": breaks_paid}))
    app = create_app(
        OpStore(), menu=MenuService(build_example()), printing=PrintService([]), settings=settings, clock=clock
    )
    return TestClient(app), wall


def manager(c: TestClient) -> dict[str, str]:
    token = c.post("/admin/session", json={"device": "office", "pin": "9999"}).json()["token"]
    return {"authorization": f"Bearer {token}"}


def punch(c: TestClient, action: str = "state", pin: str = "1111", **more) -> dict:
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": action, **more})
    assert r.status_code == 200, r.text
    return r.json()


def refused(c: TestClient, action: str, pin: str = "1111") -> tuple[int, str]:
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": action})
    return r.status_code, r.json()["detail"]["error"]


def report(c: TestClient, since: int = at(4), until: int = at(4, day=17)) -> dict:
    r = c.get("/timeclock/report", params={"since": since, "until": until}, headers=manager(c))
    assert r.status_code == 200, r.text
    return r.json()


# The setting -----------------------------------------------------------------------------------------------


def test_the_clock_is_off_until_a_manager_turns_it_on():
    assert DEFAULTS["time_clock"] == {"enabled": False, "breaks_paid": False, "week_starts": "mon"}
    c, _ = hub(on=False)
    assert c.get("/settings/time_clock").json() == DEFAULTS["time_clock"]
    assert refused(c, "in") == (409, "off")
    assert refused(c, "state") == (409, "off")
    # only a manager turns it on, and a key left out keeps what it was
    assert c.put("/settings/time_clock", json={"enabled": True}).status_code == 401
    saved = c.put("/settings/time_clock", json={"enabled": True}, headers=manager(c))
    assert saved.json() == {"enabled": True, "breaks_paid": False, "week_starts": "mon"}
    saved = c.put("/settings/time_clock", json={"week_starts": "sun"}, headers=manager(c))
    assert saved.json() == {"enabled": True, "breaks_paid": False, "week_starts": "sun"}
    assert punch(c, "in")["state"] == "in"
    bad = c.put("/settings/time_clock", json={"week_starts": "wed"}, headers=manager(c))
    assert (bad.status_code, bad.json()["detail"]["error"]) == (422, "bad_value")
    with pytest.raises(ValueError):
        clean_time_clock({"enabled": "yes"})


# A person at the clock ---------------------------------------------------------------------------------------


def test_a_person_clocks_in_takes_a_break_and_clocks_out():
    c, wall = hub(at(16))
    seen = punch(c)
    assert (seen["state"], seen["since_ms"], seen["shift"], seen["punched"]) == ("out", None, None, None)
    assert seen["staff"] == {
        "staff_id": "s1",
        "name": "Amy",
        "role": "server",
        "method": "pin",
        "preferences": c.get("/staff/s1/preferences").json()["preferences"],
    }

    on = punch(c, "in")
    assert (on["state"], on["since_ms"], on["punched"], on["now_ms"]) == ("in", at(16), "in", at(16))
    assert (on["shift"]["in_ms"], on["shift"]["out_ms"], on["shift"]["role"]) == (at(16), None, "server")

    wall.now = at(19)
    away = punch(c, "break_start")
    assert (away["state"], away["since_ms"]) == ("break", at(19))
    wall.now = at(19, 30)
    back = punch(c, "break_end")
    assert (back["state"], back["since_ms"]) == ("in", at(16))
    assert back["shift"]["breaks"] == [{"start_ms": at(19), "end_ms": at(19, 30)}]

    wall.now = at(22, 15)
    done = punch(c, "out")
    assert (done["state"], done["since_ms"], done["punched"]) == ("out", None, "out")
    shift = done["shift"]  # the answer to a clock-out says what the shift came to
    assert (shift["in_ms"], shift["out_ms"], shift["closed_by"], shift["edited"]) == (at(16), at(22, 15), "self", False)
    assert (shift["span_ms"], shift["break_ms"], shift["worked_ms"]) == (
        6 * HOUR + 15 * MINUTE,
        30 * MINUTE,
        5 * HOUR + 45 * MINUTE,
    )
    assert punch(c)["shift"] is None  # nothing running


def test_a_punch_has_to_fit_where_the_person_stands():
    c, wall = hub()
    assert refused(c, "out") == (409, "not_in")
    assert refused(c, "break_start") == (409, "not_in")
    assert refused(c, "break_end") == (409, "not_in")
    punch(c, "in")
    assert refused(c, "in") == (409, "already_in")
    assert refused(c, "break_end") == (409, "not_on_break")
    punch(c, "break_start")
    assert refused(c, "break_start") == (409, "on_break")
    assert refused(c, "lunch") == (422, "bad_action")
    # clocking out from a break ends the break with the shift
    wall.now += HOUR
    shift = punch(c, "out")["shift"]
    assert shift["breaks"][-1]["end_ms"] == shift["out_ms"] == wall.now
    # somebody else's clock is their own
    assert punch(c, pin="2222")["state"] == "out"


def test_the_clock_knows_people_as_sign_in_does():
    c, _ = hub()
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": "0000", "action": "in"})
    assert (r.status_code, r.json()["detail"]["error"]) == (401, "unknown_credential")
    r = c.post("/timeclock/punch", json={"device": "t1", "action": "in"})
    assert (r.status_code, r.json()["detail"]["error"]) == (422, "no_credential")
    for _ in range(4):
        c.post("/timeclock/punch", json={"device": "t1", "pin": "0000", "action": "in"})
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": "1111", "action": "in"})
    assert (r.status_code, r.json()["detail"]["error"]) == (423, "locked")  # five wrong PINs lock the pad
    assert report(c)["shifts"] == []


def test_the_time_is_the_hubs_and_a_punch_sent_twice_counts_once():
    c, wall = hub(at(16))
    # a screen cannot say when: whatever else it sends, the punch is stamped as it arrives
    first = punch(c, "in", punch_id="p-1", at_ms=at(9), in_ms=at(9))
    assert first["shift"]["in_ms"] == at(16)
    wall.now = at(16, 5)
    again = punch(c, "in", punch_id="p-1")  # the answer was lost on the way; the screen asks again
    assert (again["state"], again["punched"], again["shift"]["in_ms"]) == ("in", "in", at(16))
    assert len(report(c)["shifts"]) == 1
    # the same name on another person's punch, or on another kind of punch, is not that punch
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": "2222", "action": "in", "punch_id": "p-1"})
    assert (r.status_code, r.json()["detail"]["error"]) == (422, "bad_punch")
    r = c.post("/timeclock/punch", json={"device": "t1", "pin": "1111", "action": "out", "punch_id": "p-1"})
    assert (r.status_code, r.json()["detail"]["error"]) == (422, "bad_punch")
    assert punch(c)["state"] == "in"


# Nobody clocked out ------------------------------------------------------------------------------------------


def test_a_shift_nobody_ended_is_closed_when_the_night_is_over_and_marked():
    c, wall = hub(at(16))
    punch(c, "in")
    wall.now = at(21)
    punch(c, "break_start")  # and went home without a word
    wall.now = at(3, 59, day=17)
    assert punch(c)["state"] == "break"  # the night is not over yet

    wall.now = at(11, day=17)
    seen = punch(c)
    assert (seen["state"], seen["shift"]) == ("out", None)
    left = seen["unended"]  # the clock tells the person, so the manager hears of it before payday
    assert (left["in_ms"], left["out_ms"], left["closed_by"], left["unended"]) == (
        at(16),
        at(4, day=17),
        "system",
        True,
    )
    assert left["breaks"] == [{"start_ms": at(21), "end_ms": at(4, day=17)}]

    told = report(c)
    (shift,) = told["shifts"]
    assert [e["action"] for e in shift["log"]] == ["in", "break_start", "auto_out"]
    assert shift["log"][-1]["by"] == ""  # the hub's doing, nobody's
    assert (told["unended"], told["people"][0]["unended"]) == (1, 1)

    # the next day starts clean, and the reminder stays until a manager has put the real time on it
    assert punch(c, "in")["unended"]["shift_id"] == left["shift_id"]
    fixed = c.put(
        f"/timeclock/shifts/{left['shift_id']}",
        json={"in_ms": at(16), "out_ms": at(21), "reason": "Went home at nine, forgot the clock"},
        headers=manager(c),
    ).json()
    assert (fixed["closed_by"], fixed["unended"], fixed["edited"], fixed["breaks"]) == ("manager", False, True, [])
    assert punch(c)["unended"] is None


def test_the_night_ends_at_four_and_an_early_start_belongs_to_the_next_day():
    assert night_cutoff_ms(at(16)) == at(4, day=17)
    assert night_cutoff_ms(at(0, 30, day=17)) == at(4, day=17)  # the bar's closer, in for the last hours
    assert night_cutoff_ms(at(1, 1, day=17)) == at(4, day=18)  # under three hours to go: that is tomorrow's start
    assert night_cutoff_ms(at(3, 30, day=17)) == at(4, day=18)  # the prep cook is starting the day
    assert night_cutoff_ms(at(4, day=17)) == at(4, day=18)

    clock, wall = clock_at(at(3, 30, day=17))
    clock.punch("s9", "Chen", "kitchen", "in")
    wall.now = at(13, day=17)
    assert clock.sweep() == []  # still at the wok at one in the afternoon
    wall.now = at(4, day=18)
    (closed,) = clock.sweep()
    assert (closed.out_ms, closed.closed_by) == (at(4, day=18), "system")
    assert clock.sweep() == []  # once


def test_a_manager_can_say_that_the_hubs_guess_was_right():
    clock, wall = clock_at(at(22))
    shift_id = clock.punch("s2", "Ben", "bartender", "in")["shift"]["shift_id"]
    wall.now = at(9, day=17)
    with pytest.raises(Refused) as err:
        clock.edit(shift_id, in_ms=at(22), out_ms=at(4, day=17), reason="", by_id="s3", by="Mike")
    assert err.value.code == "reason_needed"
    kept = clock.edit(
        shift_id, in_ms=at(22), out_ms=at(4, day=17), reason="Closed the bar, inventory", by_id="s3", by="Mike"
    )
    assert (kept.closed_by, kept.unended, kept.edited) == ("manager", False, True)
    with pytest.raises(Refused) as err:  # and now nothing is left to say
        clock.edit(shift_id, in_ms=at(22), out_ms=at(4, day=17), reason="Again", by_id="s3", by="Mike")
    assert err.value.code == "no_change"


# A manager's corrections -------------------------------------------------------------------------------------


def worked_shift(c: TestClient, wall: Wall) -> str:
    """Amy, four to ten, with half an hour off at seven."""
    wall.now = at(16)
    shift_id = punch(c, "in")["shift"]["shift_id"]
    wall.now = at(19)
    punch(c, "break_start")
    wall.now = at(19, 30)
    punch(c, "break_end")
    wall.now = at(22)
    punch(c, "out")
    return shift_id


def test_a_correction_changes_the_hours_and_the_log_keeps_what_they_were():
    c, wall = hub()
    shift_id = worked_shift(c, wall)
    wall.now = at(23)
    body = {
        "in_ms": at(15, 30),
        "out_ms": at(22),
        "breaks": [{"start_ms": at(19), "end_ms": at(19, 30)}],
        "reason": "  Came in at 3:30 to set up,   clocked in late ",
        "device": "mac1",
    }
    assert c.put(f"/timeclock/shifts/{shift_id}", json=body).status_code == 401
    assert (
        c.put(f"/timeclock/shifts/{shift_id}", json=body, headers={"authorization": "Bearer nope"}).status_code == 401
    )
    fixed = c.put(f"/timeclock/shifts/{shift_id}", json=body, headers=manager(c))
    assert fixed.status_code == 200, fixed.text
    assert (fixed.json()["in_ms"], fixed.json()["closed_by"], fixed.json()["edited"]) == (at(15, 30), "self", True)
    assert fixed.json()["worked_ms"] == 6 * HOUR

    (shift,) = report(c)["shifts"]
    entry = shift["log"][-1]
    assert [e["action"] for e in shift["log"]] == ["in", "break_start", "break_end", "out", "edit"]
    assert (entry["by"], entry["by_id"], entry["device"], entry["at_ms"]) == ("Mike", "s3", "mac1", at(23))
    assert entry["reason"] == "Came in at 3:30 to set up, clocked in late"
    assert entry["before"] == {
        "in_ms": at(16),
        "out_ms": at(22),
        "breaks": [{"start_ms": at(19), "end_ms": at(19, 30)}],
    }
    assert entry["after"] == {
        "in_ms": at(15, 30),
        "out_ms": at(22),
        "breaks": [{"start_ms": at(19), "end_ms": at(19, 30)}],
    }
    # the punches themselves are still there, as they were made
    assert [(e["action"], e["at_ms"], e["by"]) for e in shift["log"][:4]] == [
        ("in", at(16), "Amy"),
        ("break_start", at(19), "Amy"),
        ("break_end", at(19, 30), "Amy"),
        ("out", at(22), "Amy"),
    ]


@pytest.mark.parametrize(
    ("change", "code"),
    [
        ({"reason": ""}, "reason_needed"),
        ({"reason": "   "}, "reason_needed"),
        ({"reason": "x" * 201}, "bad_reason"),
        ({"out_ms": at(15)}, "out_before_in"),
        ({"out_ms": at(16)}, "out_before_in"),
        ({"out_ms": at(23, 30)}, "in_the_future"),
        ({"in_ms": at(21, day=14)}, "too_long"),
        ({"in_ms": 0}, "bad_time"),
        ({"breaks": [{"start_ms": at(15), "end_ms": at(15, 30)}]}, "bad_breaks"),  # before the shift
        ({"breaks": [{"start_ms": at(21, 45), "end_ms": at(22, 15)}]}, "bad_breaks"),  # past its end
        ({"breaks": [{"start_ms": at(19), "end_ms": at(18)}]}, "bad_breaks"),
        ({"breaks": [{"start_ms": at(19)}]}, "bad_breaks"),  # a break with no end on a shift that has ended
        (
            {"breaks": [{"start_ms": at(19), "end_ms": at(20)}, {"start_ms": at(19, 30), "end_ms": at(21)}]},
            "bad_breaks",
        ),
        ({"breaks": [{"start_ms": at(17) + n, "end_ms": at(17) + n} for n in range(21)]}, "too_many_breaks"),
        ({}, "no_change"),
    ],
)
def test_a_correction_that_makes_no_sense_is_refused_and_changes_nothing(change: dict, code: str):
    c, wall = hub()
    shift_id = worked_shift(c, wall)
    wall.now = at(23)
    body = {
        "in_ms": at(16),
        "out_ms": at(22),
        "breaks": [{"start_ms": at(19), "end_ms": at(19, 30)}],
        "reason": "Fixing the time",
        **change,
    }
    r = c.put(f"/timeclock/shifts/{shift_id}", json=body, headers=manager(c))
    assert r.status_code in (409, 422), r.text
    assert r.json()["detail"]["error"] == code
    (shift,) = report(c)["shifts"]
    assert (shift["in_ms"], shift["out_ms"], shift["edited"], len(shift["log"])) == (at(16), at(22), False, 4)


def test_a_manager_writes_in_a_shift_nobody_punched_and_no_time_counts_twice():
    c, wall = hub(at(23))
    body = {"staff_id": "s2", "in_ms": at(17), "out_ms": at(22, 30), "reason": "Forgot to clock in all night"}
    assert c.post("/timeclock/shifts", json=body).status_code == 401
    made = c.post("/timeclock/shifts", json=body, headers=manager(c))
    assert made.status_code == 200, made.text
    shift = made.json()
    assert (shift["name"], shift["role"], shift["closed_by"], shift["edited"]) == ("Ben", "bartender", "manager", True)
    (listed,) = report(c)["shifts"]
    (entry,) = listed["log"]
    assert (entry["action"], entry["by"], entry["before"], entry["reason"]) == ("add", "Mike", None, body["reason"])
    assert entry["after"] == {"in_ms": at(17), "out_ms": at(22, 30), "breaks": []}

    # the same hours cannot be written in twice, nor a shift that runs into them
    for again in ({}, {"in_ms": at(22), "out_ms": at(22, 45)}, {"in_ms": at(16), "out_ms": at(17, 1)}):
        r = c.post("/timeclock/shifts", json={**body, **again}, headers=manager(c))
        assert (r.status_code, r.json()["detail"]["error"]) == (409, "overlaps")
    # right up against it is fine
    edge = c.post("/timeclock/shifts", json={**body, "in_ms": at(11), "out_ms": at(17)}, headers=manager(c))
    assert edge.status_code == 200
    nobody = c.post("/timeclock/shifts", json={**body, "staff_id": "s99"}, headers=manager(c))
    assert (nobody.status_code, nobody.json()["detail"]["error"]) == (404, "unknown_staff")
    no_reason = c.post("/timeclock/shifts", json={**body, "staff_id": "s1", "reason": ""}, headers=manager(c))
    assert (no_reason.status_code, no_reason.json()["detail"]["error"]) == (409, "reason_needed")


def test_a_shift_written_in_with_no_end_puts_the_person_on_the_clock():
    c, wall = hub(at(19))
    body = {"staff_id": "s1", "in_ms": at(16), "reason": "Has been here since four"}
    made = c.post("/timeclock/shifts", json=body, headers=manager(c)).json()
    assert (made["state"], made["out_ms"], made["closed_by"]) == ("in", None, "")
    assert punch(c)["state"] == "in" and punch(c)["since_ms"] == at(16)
    assert refused(c, "in") == (409, "already_in")
    twice = c.post("/timeclock/shifts", json=body | {"in_ms": at(18)}, headers=manager(c))
    assert (twice.status_code, twice.json()["detail"]["error"]) == (409, "already_in")
    wall.now = at(22)
    assert punch(c, "out")["shift"]["worked_ms"] == 6 * HOUR
    # a night that is over cannot be left running
    old = c.post("/timeclock/shifts", json=body | {"in_ms": at(16, day=14)}, headers=manager(c))
    assert (old.status_code, old.json()["detail"]["error"]) == (409, "too_long")


def test_a_clock_out_made_by_mistake_is_taken_back():
    c, wall = hub()
    shift_id = worked_shift(c, wall)
    wall.now = at(22, 10)
    body = {"in_ms": at(16), "breaks": [{"start_ms": at(19), "end_ms": at(19, 30)}], "reason": "Still on the floor"}
    running = c.put(f"/timeclock/shifts/{shift_id}", json=body, headers=manager(c)).json()
    assert (running["state"], running["out_ms"], running["closed_by"]) == ("in", None, "")
    wall.now = at(23)
    done = punch(c, "out")["shift"]
    assert (done["shift_id"], done["out_ms"], done["closed_by"], done["edited"]) == (shift_id, at(23), "self", True)


def test_a_shift_taken_off_is_kept_and_counts_for_nothing():
    c, wall = hub()
    shift_id = worked_shift(c, wall)
    wall.now = at(23)
    assert c.delete(f"/timeclock/shifts/{shift_id}", params={"reason": "x"}).status_code == 401
    r = c.delete(f"/timeclock/shifts/{shift_id}", headers=manager(c))
    assert (r.status_code, r.json()["detail"]["error"]) == (409, "reason_needed")
    gone = c.delete(f"/timeclock/shifts/{shift_id}", params={"reason": "Punched in on her day off"}, headers=manager(c))
    assert gone.status_code == 200 and gone.json()["state"] == "removed"

    told = report(c)
    (shift,) = told["shifts"]  # still listed, with why
    assert (shift["removed"], shift["log"][-1]["action"], shift["log"][-1]["reason"]) == (
        True,
        "remove",
        "Punched in on her day off",
    )
    assert shift["log"][-1]["before"]["in_ms"] == at(16)
    assert (told["people"], told["worked_ms"]) == ([], 0)
    # it cannot be changed any more, and the time is free again
    r = c.put(
        f"/timeclock/shifts/{shift_id}", json={"in_ms": at(16), "out_ms": at(21), "reason": "x"}, headers=manager(c)
    )
    assert (r.status_code, r.json()["detail"]["error"]) == (404, "unknown_shift")
    r = c.delete(f"/timeclock/shifts/{shift_id}", params={"reason": "again"}, headers=manager(c))
    assert r.status_code == 404
    again = {"staff_id": "s1", "in_ms": at(17), "out_ms": at(21), "reason": "The right hours"}
    assert c.post("/timeclock/shifts", json=again, headers=manager(c)).status_code == 200

    # one taken off while it runs ends there, and the person is off the clock
    wall.now = at(9, day=17)
    running = punch(c, "in")["shift"]["shift_id"]
    wall.now = at(9, 5, day=17)
    c.delete(f"/timeclock/shifts/{running}", params={"reason": "Wrong PIN"}, headers=manager(c))
    assert punch(c)["state"] == "out"


# The hours ---------------------------------------------------------------------------------------------------


def test_the_report_adds_up_each_persons_hours_and_says_who_is_on_now():
    c, wall = hub()
    worked_shift(c, wall)  # Amy: 5 h 30 worked, 30 min break
    wall.now = at(17)
    punch(c, "in", pin="2222")  # Ben, still on at eleven
    wall.now = at(23)
    assert c.get("/timeclock/report", params={"since": at(4), "until": at(4, day=17)}).status_code == 401
    server = c.post("/signin", json={"device": "t1", "pin": "1111"})
    assert server.status_code == 200  # a server has no token at all for the report
    told = report(c)
    assert (told["now_ms"], told["breaks_paid"], told["enabled"], told["week_starts"]) == (at(23), False, True, "mon")
    assert [(p["name"], p["role"], p["worked_ms"], p["break_ms"], p["shifts"], p["open"]) for p in told["people"]] == [
        ("Amy", "server", 5 * HOUR + 30 * MINUTE, 30 * MINUTE, 1, 0),
        ("Ben", "bartender", 6 * HOUR, 0, 1, 1),  # counted up to now while it runs
    ]
    assert (told["worked_ms"], told["break_ms"], told["unended"]) == (11 * HOUR + 30 * MINUTE, 30 * MINUTE, 0)
    assert [(s["name"], s["state"], s["in_ms"]) for s in told["on_now"]] == [("Ben", "in", at(17))]
    assert [s["name"] for s in told["shifts"]] == ["Amy", "Ben"]  # the oldest first

    # a shift counts on the day it began; who is on now is listed whatever the days asked for
    earlier = report(c, at(4, day=15), at(4, day=16))
    assert (earlier["shifts"], earlier["people"]) == ([], [])
    assert [s["name"] for s in earlier["on_now"]] == ["Ben"]
    bad = c.get("/timeclock/report", params={"since": at(4), "until": at(4)}, headers=manager(c))
    assert (bad.status_code, bad.json()["detail"]["error"]) == (422, "bad_window")


def test_a_location_that_pays_breaks_counts_them_as_worked():
    c, wall = hub(breaks_paid=True)
    worked_shift(c, wall)
    wall.now = at(23)
    told = report(c)
    assert told["breaks_paid"] is True
    assert (told["people"][0]["worked_ms"], told["people"][0]["break_ms"]) == (6 * HOUR, 30 * MINUTE)
    # the hours on the clock are the same either way: the setting only changes how they are added up
    c.put("/settings/time_clock", json={"breaks_paid": False}, headers=manager(c))
    assert report(c)["people"][0]["worked_ms"] == 5 * HOUR + 30 * MINUTE


# PostgreSQL ----------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_clock_is_kept_in_postgres():
    import psycopg

    from pos.timeclock import PgClockStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS clock_shift")
        conn.execute("DROP TABLE IF EXISTS clock_log")
    store = PgClockStore(DSN)
    try:
        clock, wall = clock_at(at(16), store)
        shift_id = clock.punch("s1", "Amy", "server", "in", device="t1", punch_id="p-in")["shift"]["shift_id"]
        assert clock.punch("s1", "Amy", "server", "in", punch_id="p-in")["punched"] == "in"  # sent twice
        with pytest.raises(Refused) as err:
            clock.punch("s1", "Amy", "server", "in")
        assert err.value.code == "already_in"
        wall.now = at(19)
        clock.punch("s1", "Amy", "server", "break_start")
        wall.now = at(19, 30)
        clock.punch("s1", "Amy", "server", "break_end")
        clock.punch("s2", "Ben", "bartender", "in")
        wall.now = at(22)
        assert clock.punch("s1", "Amy", "server", "out")["shift"]["worked_ms"] == 5 * HOUR + 30 * MINUTE
        clock.edit(shift_id, in_ms=at(15, 30), out_ms=at(22), reason="Set up early", by_id="s3", by="Mike")

        again = PgClockStore(DSN)  # another process: the hub after a restart
        try:
            later, wall2 = clock_at(at(23), again)
            told = later.report(at(4), at(4, day=17))
            assert [(p["name"], p["worked_ms"]) for p in told["people"]] == [
                ("Amy", 6 * HOUR + 30 * MINUTE),
                ("Ben", 3 * HOUR + 30 * MINUTE),
            ]
            amy = told["shifts"][0]
            assert (amy["shift_id"], amy["in_ms"], amy["breaks"], amy["edited"]) == (shift_id, at(15, 30), [], True)
            assert [e["action"] for e in amy["log"]] == ["in", "break_start", "break_end", "out", "edit"]
            assert amy["log"][-1]["before"]["breaks"] == [{"start_ms": at(19), "end_ms": at(19, 30)}]
            assert [s["name"] for s in told["on_now"]] == ["Ben"]
            # two screens at the same moment cannot put one person on the clock twice
            from pos.timeclock import Entry, Shift

            with pytest.raises(Refused) as err:
                again.write(Shift("dup", "s2", "Ben", "bartender", at(23)), Entry("e-dup", "dup", "s2", "in", at(23)))
            assert err.value.code == "already_in"
            assert again.entry("e-dup") is None  # and nothing of it is kept
            # Ben never clocks out: the night ends for him at four
            wall2.now = at(9, day=17)
            (closed,) = later.sweep()
            assert (closed.name, closed.out_ms, closed.closed_by) == ("Ben", at(4, day=17), "system")
            assert again.open_shifts() == []
        finally:
            again.close()
    finally:
        store.close()
