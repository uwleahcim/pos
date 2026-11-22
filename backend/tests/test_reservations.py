"""The reservation book: a table is booked for a day and a time with a name and a size; a day's book reads
in the order of the times; a reservation ends by sitting down, by being cancelled or by not showing, and can
be put back; a day is a day of service; a day that is over is only read, and its names are not kept for
ever."""

from __future__ import annotations

import os
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos import localtime, reservations
from pos.api.app import create_app
from pos.menu.fixtures.example import build_example
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.reservations import (
    HOLD_MIN,
    KEEP_DAYS,
    MOST_AHEAD_DAYS,
    NOTE_MAX,
    BookStore,
    Refused,
    Reservations,
)
from pos.sync.oplog import OpStore
from pos.waitlist import MOST_GUESTS, NAME_MAX

DSN = os.environ.get("POS_TEST_DATABASE_URL")

MINUTE = 60_000
MON, TUE, SAT = "2026-11-16", "2026-11-17", "2026-11-21"


def at(hour: int, minute: int = 0, *, day: int = 16, month: int = 11) -> int:
    """A time on the restaurant's own clock in late 2026, in wall-clock milliseconds."""
    return int(datetime(2026, month, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


class Wall:
    """The hub's clock, set by the test."""

    def __init__(self, now: int) -> None:
        self.now = now

    def __call__(self) -> int:
        return self.now


def book_at(now: int = at(15), store: BookStore | None = None) -> tuple[Reservations, Wall]:
    """The book on Monday 16 November 2026, at three in the afternoon unless told otherwise."""
    wall = Wall(now)
    return Reservations(store, now_ms=wall), wall


def hub(now: int = at(15)) -> tuple[TestClient, Wall]:
    book, wall = book_at(now)
    app = create_app(OpStore(), menu=MenuService(build_example()), printing=PrintService([]), reservations=book)
    return TestClient(app), wall


def add(
    c: TestClient, name: str = "Chen", size: int = 4, time: str = "18:30", day: str = MON, staff_id: str = "s4", **more
) -> dict:
    r = c.post(
        "/reservations", json={"staff_id": staff_id, "name": name, "size": size, "day": day, "time": time, **more}
    )
    assert r.status_code == 200, r.text
    return r.json()["booking"]


def read(c: TestClient, day: str | None = None) -> dict:
    r = c.get("/reservations", params=None if day is None else {"day": day})
    assert r.status_code == 200, r.text
    return r.json()


def names(told: dict, part: str = "booked") -> list[str]:
    return [b["name"] for b in told[part]]


def refused(r) -> tuple[int, str]:
    return r.status_code, r.json()["detail"]["error"]


WHO = {"staff_id": "s4"}


def test_a_table_is_booked_and_the_day_reads_in_the_order_of_the_times():
    c, wall = hub()
    told = read(c)
    assert (told["day"], told["today"], told["booked"], told["ahead"]) == (MON, MON, [], [])
    garcia = add(c, "Garcia", 2, "19:15", staff_id="s1")
    chen = add(c, "  Chen ", 4, "18:30", phone="781 555 0101", note="birthday,  cake in the fridge", table="A7")
    assert (chen["name"], chen["size"], chen["phone"]) == ("Chen", 4, "781 555 0101")
    assert (chen["note"], chen["by"], chen["status"]) == ("birthday, cake in the fridge", "Holly", "booked")
    assert (chen["day"], chen["time"], chen["at_ms"]) == (MON, "18:30", at(18, 30))
    assert (chen["table"], chen["table_label"], chen["made_ms"]) == ("A7", "A7", at(15))
    # the hub's clock says when its time is near, and when it is past with nobody seated
    assert (chen["soon_ms"], chen["late_ms"]) == (at(18, 15), at(18, 45))
    assert (garcia["table"], garcia["by"], garcia["arrived_ms"], garcia["clash"]) == ("", "Amy", None, None)
    add(c, "Okafor", 6, "9:05")  # an hour without its nought reads too

    told = read(c)
    assert names(told) == ["Okafor", "Chen", "Garcia"]
    assert told["booked"][0]["time"] == "09:05"
    assert told["counts"] == {"booked": 3, "guests": 12, "seated": 0, "cancelled": 0, "no_show": 0}
    assert told["ahead"] == [{"day": MON, "parties": 3, "guests": 12}]
    assert (told["hold_minutes"], told["name_max"], told["note_max"]) == (HOLD_MIN, NAME_MAX, NOTE_MAX)
    # nothing in the answer moves with the clock: a book nobody changed reads as unchanged
    wall.now = at(18, 40)
    assert read(c) == told


def test_two_for_the_same_time_stay_in_the_order_they_were_written():
    c, _ = hub()
    for name in ("Chen", "Garcia", "Okafor"):
        add(c, name, 2, "18:00")
    add(c, "Silva", 2, "17:45")
    assert names(read(c)) == ["Silva", "Chen", "Garcia", "Okafor"]


def test_another_days_book_and_the_days_ahead():
    c, _ = hub()
    add(c, "Chen", 4, "18:30")
    add(c, "Garcia", 2, "12:00", day=SAT)
    add(c, "Okafor", 8, "19:00", day=SAT)
    add(c, "Silva", 2, "19:00", day=TUE)
    today = read(c)
    assert names(today) == ["Chen"]
    assert today["ahead"] == [
        {"day": MON, "parties": 1, "guests": 4},
        {"day": TUE, "parties": 1, "guests": 2},
        {"day": SAT, "parties": 2, "guests": 10},
    ]
    saturday = read(c, SAT)
    assert (saturday["day"], saturday["today"], names(saturday)) == (SAT, MON, ["Garcia", "Okafor"])
    assert saturday["ahead"] == today["ahead"]
    assert read(c, "2026-11-19")["booked"] == []
    assert refused(c.get("/reservations", params={"day": "Saturday"})) == (422, "bad_day")


def test_a_day_is_a_day_of_service():
    c, wall = hub()
    # half past midnight on Monday's book is after Monday's midnight
    late = add(c, "Night owls", 2, "00:30")
    assert (late["day"], late["time"], late["at_ms"]) == (MON, "00:30", at(0, 30, day=17))
    add(c, "Chen", 4, "23:45")
    assert names(read(c)) == ["Chen", "Night owls"]
    # at one in the morning it is still Monday's service: its book is today's, and tables are booked in it
    wall.now = at(1, day=17)
    told = read(c)
    assert (told["day"], told["today"]) == (MON, MON)
    add(c, "Garcia", 2, "01:30")
    assert names(read(c)) == ["Chen", "Night owls", "Garcia"]
    # the morning after, Tuesday's book starts empty and Monday's is yesterday's
    wall.now = at(11, day=17)
    told = read(c)
    assert (told["day"], told["today"], told["booked"]) == (TUE, TUE, [])
    assert names(read(c, MON)) == ["Chen", "Night owls", "Garcia"]


def test_anyone_signed_in_keeps_the_book_and_a_stranger_does_not():
    c, _ = hub()
    for staff_id in ("s1", "s2", "s3", "s4"):
        add(c, f"Party {staff_id}", 2, staff_id=staff_id)
    assert [b["by"] for b in read(c)["booked"]] == ["Amy", "Ben", "Mike", "Holly"]
    body = {"staff_id": "s99", "name": "Chen", "size": 2, "day": MON, "time": "18:00"}
    assert refused(c.post("/reservations", json=body)) == (404, "unknown_staff")
    booking = read(c)["booked"][0]["id"]
    assert refused(c.put(f"/reservations/{booking}", json=body)) == (404, "unknown_staff")
    for path in ("arrived", "seat", "cancel", "back"):
        r = c.post(f"/reservations/{booking}/{path}", json={"staff_id": "s99", "table": "A7"})
        assert refused(r) == (404, "unknown_staff")
    assert len(read(c)["booked"]) == 4


def test_what_the_book_refuses():
    c, _ = hub()
    good = {"staff_id": "s4", "name": "Chen", "size": 4, "day": MON, "time": "18:30"}
    far = localtime.day_of(at(15)).toordinal() + MOST_AHEAD_DAYS + 1
    for change, code in (
        ({"name": "   "}, "no_name"),
        ({"name": "x" * (NAME_MAX + 1)}, "long_text"),
        ({"note": "x" * (NOTE_MAX + 1)}, "long_text"),
        ({"size": 0}, "bad_size"),
        ({"size": MOST_GUESTS + 1}, "bad_size"),
        ({"phone": "555"}, "bad_phone"),
        ({"phone": "call me maybe"}, "bad_phone"),
        ({"day": "11/21/2026"}, "bad_day"),
        ({"day": ""}, "bad_day"),
        ({"time": "6:30 PM"}, "bad_time"),
        ({"time": "24:00"}, "bad_time"),
        ({"time": "18:60"}, "bad_time"),
        ({"day": "2026-11-15"}, "past_day"),
        ({"day": type(localtime.day_of(0)).fromordinal(far).isoformat()}, "too_far"),
    ):
        assert refused(c.post("/reservations", json={**good, **change})) == (422, code), change
    assert refused(c.post("/reservations", json={**good, "table": "Z99"})) == (404, "unknown_table")
    assert read(c)["booked"] == []
    # the last day that can be booked is a year and a day ahead
    last = type(localtime.day_of(0)).fromordinal(far - 1).isoformat()
    assert c.post("/reservations", json={**good, "day": last}).status_code == 200
    # a time of today that has passed is taken: a party that called from the car is written down as it is
    assert add(c, "Late entry", 2, "14:00")["at_ms"] == at(14)
    assert refused(c.post("/reservations/nobody/seat", json={**WHO, "table": "A7"})) == (404, "unknown_booking")


def test_a_day_takes_so_many_reservations(monkeypatch):
    monkeypatch.setattr(reservations, "MOST_A_DAY", 2)
    c, _ = hub()
    chen = add(c, "Chen")
    add(c, "Garcia")
    body = {"staff_id": "s4", "name": "Okafor", "size": 2, "day": MON, "time": "20:00"}
    assert refused(c.post("/reservations", json=body)) == (409, "too_many")
    okafor = add(c, "Okafor", 2, "20:00", day=TUE)  # another day has room
    # and it cannot be moved into the full day
    assert refused(c.put(f"/reservations/{okafor['id']}", json=body)) == (409, "too_many")
    # one that ended makes room, and then cannot come back into a day that filled up again
    c.post(f"/reservations/{chen['id']}/cancel", json=WHO)
    assert c.post("/reservations", json=body).status_code == 200
    assert refused(c.post(f"/reservations/{chen['id']}/back", json=WHO)) == (409, "too_many")


def test_a_standing_reservation_is_put_right():
    c, wall = hub()
    chen = add(c, "Chen", 4, "18:30", phone="781 555 0101", note="booth")
    add(c, "Garcia", 2, "19:00")
    wall.now = at(16)
    body = {**WHO, "name": "Chen", "size": 6, "day": MON, "time": "19:30", "phone": "", "note": "", "table": "A8"}
    r = c.put(f"/reservations/{chen['id']}", json=body)
    assert r.status_code == 200, r.text
    after = r.json()["booking"]
    assert (after["size"], after["time"], after["phone"], after["note"], after["table"]) == (6, "19:30", "", "", "A8")
    assert (after["made_ms"], after["by"]) == (at(15), "Holly")  # who booked it and when stays
    assert names(r.json()) == ["Garcia", "Chen"]
    # moved to another day, the answer is that day's book
    r = c.put(f"/reservations/{chen['id']}", json={**body, "day": SAT})
    assert (r.json()["day"], names(r.json())) == (SAT, ["Chen"])
    assert names(read(c)) == ["Garcia"]
    # what it does not take changes nothing
    assert refused(c.put(f"/reservations/{chen['id']}", json={**body, "size": 0})) == (422, "bad_size")
    assert refused(c.put(f"/reservations/{chen['id']}", json={**body, "day": "2026-11-15"})) == (422, "past_day")
    assert refused(c.put(f"/reservations/{chen['id']}", json={**body, "table": "Z99"})) == (404, "unknown_table")
    assert read(c, SAT)["booked"][0]["size"] == 6
    # one that was cancelled is put back before it is changed
    c.post(f"/reservations/{chen['id']}/cancel", json=WHO)
    assert refused(c.put(f"/reservations/{chen['id']}", json=body)) == (409, "not_booked")


def test_a_party_that_is_here_is_marked_once():
    c, wall = hub()
    chen = add(c, "Chen", 4, "18:30")
    wall.now = at(18, 20)
    here = c.post(f"/reservations/{chen['id']}/arrived", json=WHO).json()["booking"]
    assert (here["arrived_ms"], here["status"]) == (at(18, 20), "booked")
    wall.now = at(18, 25)
    again = c.post(f"/reservations/{chen['id']}/arrived", json=WHO).json()["booking"]
    assert again["arrived_ms"] == at(18, 20)  # the first time counts
    off = c.post(f"/reservations/{chen['id']}/arrived", json={**WHO, "on": False}).json()["booking"]
    assert off["arrived_ms"] is None
    # nobody is here for another day's table
    garcia = add(c, "Garcia", 2, "18:00", day=SAT)
    assert refused(c.post(f"/reservations/{garcia['id']}/arrived", json=WHO)) == (409, "not_today")
    # a party that is here and moves to another day is not here any more; a later time today keeps the mark
    c.post(f"/reservations/{chen['id']}/arrived", json=WHO)
    body = {**WHO, "name": "Chen", "size": 4, "day": MON, "time": "19:00"}
    assert c.put(f"/reservations/{chen['id']}", json=body).json()["booking"]["arrived_ms"] == at(18, 25)
    assert c.put(f"/reservations/{chen['id']}", json={**body, "day": SAT}).json()["booking"]["arrived_ms"] is None


def test_a_party_sits_down_at_a_table():
    c, wall = hub()
    chen = add(c, "Chen", 4, "18:30", table="A7")
    garcia = add(c, "Garcia", 2, "19:00")
    wall.now = at(18, 34)
    # they sit where there is room, which need not be the table that was held
    r = c.post(f"/reservations/{chen['id']}/seat", json={**WHO, "table": "A8", "order_id": "o-1"})
    assert r.status_code == 200, r.text
    sat = r.json()["booking"]
    assert (sat["status"], sat["seated_ms"], sat["seated_table"], sat["seated_label"]) == (
        "seated",
        at(18, 34),
        "A8",
        "A8",
    )
    assert (sat["table"], sat["order_id"], sat["ended_by"]) == ("A7", "o-1", "Holly")
    told = r.json()
    assert names(told) == ["Garcia"] and names(told, "earlier") == ["Chen"]
    assert told["counts"] == {"booked": 1, "guests": 2, "seated": 1, "cancelled": 0, "no_show": 0}
    assert told["ahead"] == [{"day": MON, "parties": 1, "guests": 2}]
    # a second screen seating the same party: the first table counts
    wall.now = at(18, 36)
    r = c.post(f"/reservations/{chen['id']}/seat", json={"staff_id": "s1", "table": "A1", "order_id": "o-2"})
    again = r.json()["booking"]
    assert (again["seated_table"], again["order_id"], again["seated_ms"], again["ended_by"]) == (
        "A8",
        "o-1",
        at(18, 34),
        "Holly",
    )
    # a table the floor plan does not have, no table, and a reservation that is not today's
    assert refused(c.post(f"/reservations/{garcia['id']}/seat", json={**WHO, "table": "Z99"})) == (404, "unknown_table")
    assert refused(c.post(f"/reservations/{garcia['id']}/seat", json={**WHO, "table": ""})) == (422, "no_table")
    okafor = add(c, "Okafor", 6, "18:00", day=SAT)
    r = c.post(f"/reservations/{okafor['id']}/seat", json={**WHO, "table": "A7"})
    assert refused(r) == (409, "not_today")
    assert "Sat 21 Nov" in r.json()["detail"]["message"]
    # one that was cancelled is put back first
    c.post(f"/reservations/{garcia['id']}/cancel", json=WHO)
    assert refused(c.post(f"/reservations/{garcia['id']}/seat", json={**WHO, "table": "A7"})) == (409, "not_booked")


def test_a_reservation_is_cancelled_or_the_party_does_not_show():
    c, wall = hub()
    chen = add(c, "Chen", 4, "18:30")
    garcia = add(c, "Garcia", 2, "19:00")
    okafor = add(c, "Okafor", 6, "19:30")
    wall.now = at(17)
    gone = c.post(f"/reservations/{chen['id']}/cancel", json={"staff_id": "s1"}).json()["booking"]
    assert (gone["status"], gone["ended_ms"], gone["ended_by"]) == ("cancelled", at(17), "Amy")
    wall.now = at(19, 20)
    r = c.post(f"/reservations/{garcia['id']}/cancel", json={**WHO, "why": "no_show"})
    assert r.json()["booking"]["status"] == "no_show"
    told = r.json()
    assert names(told) == ["Okafor"] and names(told, "earlier") == ["Garcia", "Chen"]  # the last to end first
    assert told["counts"] == {"booked": 1, "guests": 6, "seated": 0, "cancelled": 1, "no_show": 1}
    # said twice it stays as it was; the other word changes how it ended
    wall.now = at(19, 25)
    same = c.post(f"/reservations/{garcia['id']}/cancel", json={**WHO, "why": "no_show"}).json()["booking"]
    assert same["ended_ms"] == at(19, 20)
    other = c.post(f"/reservations/{garcia['id']}/cancel", json=WHO).json()["booking"]
    assert (other["status"], other["ended_ms"]) == ("cancelled", at(19, 25))
    assert refused(c.post(f"/reservations/{okafor['id']}/cancel", json={**WHO, "why": "bored"})) == (422, "bad_why")
    # a party that has a table is not cancelled
    c.post(f"/reservations/{okafor['id']}/seat", json={**WHO, "table": "A7"})
    assert refused(c.post(f"/reservations/{okafor['id']}/cancel", json=WHO)) == (409, "not_booked")
    # a later day's table is cancelled, but nobody can have missed it yet
    silva = add(c, "Silva", 2, "18:00", day=SAT)
    assert refused(c.post(f"/reservations/{silva['id']}/cancel", json={**WHO, "why": "no_show"})) == (409, "not_today")
    assert c.post(f"/reservations/{silva['id']}/cancel", json=WHO).json()["booking"]["status"] == "cancelled"
    assert read(c)["ahead"] == []


def test_a_reservation_that_ended_by_mistake_is_put_back():
    c, wall = hub()
    chen = add(c, "Chen", 4, "18:30", table="A7", note="booth")
    wall.now = at(18, 20)
    c.post(f"/reservations/{chen['id']}/arrived", json=WHO)
    c.post(f"/reservations/{chen['id']}/seat", json={**WHO, "table": "A8", "order_id": "o-1"})
    back = c.post(f"/reservations/{chen['id']}/back", json=WHO).json()["booking"]
    assert (back["status"], back["seated_ms"], back["seated_table"], back["order_id"], back["ended_by"]) == (
        "booked",
        None,
        "",
        "",
        "",
    )
    # it stands as it stood: its time, its table, its note, and that the party is here
    assert (back["time"], back["table"], back["note"], back["arrived_ms"]) == ("18:30", "A7", "booth", at(18, 20))
    c.post(f"/reservations/{chen['id']}/cancel", json={**WHO, "why": "no_show"})
    again = c.post(f"/reservations/{chen['id']}/back", json=WHO).json()
    assert again["booking"]["status"] == "booked" and again["booking"]["ended_ms"] is None
    assert names(again) == ["Chen"] and again["earlier"] == []
    # putting back one that stands changes nothing
    assert c.post(f"/reservations/{chen['id']}/back", json=WHO).json()["booking"] == again["booking"]


def test_two_reservations_of_one_table_close_together_are_told_about_each_other():
    c, _ = hub()
    chen = add(c, "Chen", 4, "18:00", table="A7")
    garcia = add(c, "Garcia", 2, "19:15", table="A7")
    assert garcia["clash"] == {"id": chen["id"], "name": "Chen", "at_ms": at(18)}
    okafor = add(c, "Okafor", 6, "19:30", table="A7")  # an hour and a half after Chen: that table is free again
    told = {b["name"]: b["clash"] and b["clash"]["name"] for b in read(c)["booked"]}
    assert told == {"Chen": "Garcia", "Garcia": "Okafor", "Okafor": "Garcia"}  # the nearest one is named
    assert okafor["clash"]["name"] == "Garcia"
    # another table, no table, and another day are nobody's business
    add(c, "Silva", 2, "18:00", table="A8")
    add(c, "Nguyen", 2, "18:00")
    add(c, "Weekend", 2, "18:00", day=SAT, table="A7")
    told = {b["name"]: b["clash"] for b in read(c)["booked"]}
    assert told["Silva"] is None and told["Nguyen"] is None
    assert read(c, SAT)["booked"][0]["clash"] is None
    # a reservation that ended holds no table
    c.post(f"/reservations/{garcia['id']}/cancel", json=WHO)
    assert all(b["clash"] is None for b in read(c)["booked"])


def held(c: TestClient) -> dict[str, list[str]]:
    """The tables the floor map is told are held, each with whose they are."""
    return {table: [hold["name"] for hold in holds] for table, holds in c.get("/floor").json()["holds"].items()}


def test_the_floor_map_is_told_which_tables_are_held_today():
    c, wall = hub()
    assert c.get("/floor").json()["holds"] == {}
    chen = add(c, "Chen", 4, "18:30", table="A7", phone="781 555 0101", note="booth by the window")
    hold = c.get("/floor").json()["holds"]["A7"][0]
    # whose it is and for when, and the moments the map counts against: an hour and a half before (somebody
    # sat there then would still be eating), a quarter before, a quarter after, an hour and a half after
    assert hold == {
        "id": chen["id"],
        "name": "Chen",
        "size": 4,
        "at_ms": at(18, 30),
        "time": "18:30",
        "arrived_ms": None,
        "held_ms": at(17),
        "soon_ms": at(18, 15),
        "late_ms": at(18, 45),
        "until_ms": at(20),
    }
    assert at(18, 30) - hold["held_ms"] == hold["until_ms"] - at(18, 30) == HOLD_MIN * MINUTE
    # the guest's number and the note stay in the book
    assert "781" not in str(hold) and "booth" not in str(hold)
    # two of one table stand in the order of their times; no table held, and another day, are not on the map
    okafor = add(c, "Okafor", 6, "17:00", table="A7")
    add(c, "Garcia", 2, "19:00")
    add(c, "Silva", 2, "18:00", table="B5")
    add(c, "Weekend", 2, "18:00", day=SAT, table="A8")
    assert held(c) == {"A7": ["Okafor", "Chen"], "B5": ["Silva"]}
    # a party that is here says so
    wall.now = at(18, 20)
    c.post(f"/reservations/{chen['id']}/arrived", json=WHO)
    assert c.get("/floor").json()["holds"]["A7"][1]["arrived_ms"] == at(18, 20)
    # one that sat down (wherever), was called off or did not show holds nothing; put back, it holds again
    c.post(f"/reservations/{chen['id']}/seat", json={**WHO, "table": "A8", "order_id": "o-1"})
    assert held(c) == {"A7": ["Okafor"], "B5": ["Silva"]}
    c.post(f"/reservations/{okafor['id']}/cancel", json={**WHO, "why": "no_show"})
    assert held(c) == {"B5": ["Silva"]}
    c.post(f"/reservations/{okafor['id']}/back", json=WHO)
    assert held(c) == {"A7": ["Okafor"], "B5": ["Silva"]}
    # moved to another table, the hold moves with it
    c.put(
        f"/reservations/{okafor['id']}",
        json={**WHO, "name": "Okafor", "size": 6, "day": MON, "time": "17:00", "table": "A1"},
    )
    assert held(c) == {"A1": ["Okafor"], "B5": ["Silva"]}


def test_the_floor_reads_the_same_until_the_book_changes_or_the_day_does():
    c, wall = hub()
    add(c, "Chen", 4, "18:30", table="A7")
    add(c, "Weekend", 2, "18:00", day=TUE, table="A8")
    first = c.get("/floor")
    etag = first.headers["etag"]
    # the afternoon goes by, the table's time comes and passes: nothing the hub says changes, so a screen
    # that asks again is told it has it
    for now in (at(17), at(18, 20), at(18, 50), at(23, 30)):
        wall.now = now
        assert c.get("/floor", headers={"If-None-Match": etag}).status_code == 304
    # a change to the book is a change to the floor
    add(c, "Garcia", 2, "19:00", table="B5")
    again = c.get("/floor", headers={"If-None-Match": etag})
    assert again.status_code == 200 and set(again.json()["holds"]) == {"A7", "B5"}
    # half past midnight is still Monday's service; after four it is Tuesday, and Tuesday's tables are held
    wall.now = at(0, 30, day=17)
    assert set(c.get("/floor").json()["holds"]) == {"A7", "B5"}
    wall.now = at(5, day=17)
    assert held(c) == {"A8": ["Weekend"]}


def test_a_day_that_is_over_is_only_read_and_its_names_are_not_kept_for_ever():
    store = BookStore()
    book, wall = book_at(at(15), store)
    chen = book.add("Chen", 4, MON, "18:30", phone="781 555 0101", note="booth", table="A7", by_id="s4", by="Holly")
    garcia = book.add("Garcia", 2, MON, "19:00", phone="781 555 0102", by_id="s4", by="Holly")
    weekend = book.add("Okafor", 6, SAT, "19:00", phone="781 555 0103", by_id="s4", by="Holly")
    wall.now = at(18, 40)
    book.seat(chen.booking_id, "A7", order_id="o-1", by="Holly")

    # the next day Monday's book is read as it ended, names and all, and nothing in it changes
    wall.now = at(11, day=17)
    monday = book.book(localtime.day_of(at(12)))
    assert [(b["name"], b["status"]) for b in monday["booked"]] == [("Garcia", "booked")]  # nobody marked it
    assert [(b["name"], b["phone"], b["seated_table"]) for b in monday["earlier"]] == [("Chen", "781 555 0101", "A7")]
    for change in (
        lambda: book.change(garcia.booking_id, "Garcia", 2, TUE, "19:00"),
        lambda: book.seat(garcia.booking_id, "A7"),
        lambda: book.arrive(garcia.booking_id),
        lambda: book.cancel(garcia.booking_id, "no_show"),
        lambda: book.back(chen.booking_id),
    ):
        with pytest.raises(Refused) as err:
            change()
        assert err.value.code == "day_over"
    assert store.get(garcia.booking_id) == garcia

    # the names, numbers and notes stay a month after the day, and the first table booked after that takes
    # them off; how many they were, when, and how it ended is kept
    wall.now = at(12, day=16, month=12)  # thirty days on: still kept
    assert KEEP_DAYS == 30
    book.add("Silva", 2, "2026-12-16", "18:00", by_id="s4", by="Holly")
    assert store.get(chen.booking_id).phone == "781 555 0101"
    wall.now = at(12, day=17, month=12)
    book.add("Nguyen", 2, "2026-12-17", "18:00", by_id="s4", by="Holly")
    for old in (chen, garcia):
        kept = store.get(old.booking_id)
        assert (kept.name, kept.phone, kept.note) == ("", "", "")
        assert (kept.size, kept.at_ms, kept.table) == (old.size, old.at_ms, old.table)
    assert store.get(chen.booking_id).status == "seated"
    assert store.get(weekend.booking_id).phone == "781 555 0103"  # 21 November is not a month gone yet


def test_the_screens_are_told_when_the_book_changes():
    c, _ = hub()
    said: list[str] = []
    c.app.state.feed.changed = said.append
    chen = add(c)
    c.put(f"/reservations/{chen['id']}", json={**WHO, "name": "Chen", "size": 5, "day": MON, "time": "18:30"})
    c.post(f"/reservations/{chen['id']}/arrived", json=WHO)
    c.post(f"/reservations/{chen['id']}/seat", json={**WHO, "table": "A7"})
    c.post(f"/reservations/{chen['id']}/back", json=WHO)
    c.post(f"/reservations/{chen['id']}/cancel", json=WHO)
    assert said == ["reservations"] * 6
    # what is refused, and reading, tells nobody
    c.post("/reservations", json={**WHO, "name": "", "size": 2, "day": MON, "time": "18:30"})
    c.post(f"/reservations/{chen['id']}/arrived", json=WHO)
    read(c)
    assert said == ["reservations"] * 6


def test_a_reservation_is_no_check_and_no_sale():
    c, _ = hub()
    chen = add(c, "Chen", 4, "18:30", table="A7")
    # a table that is held is not a table that is busy, and the book opens no check by itself: the screen
    # that seats the party does, as for a party walking in
    assert c.get("/floor").json()["status"] == {}
    c.post(f"/reservations/{chen['id']}/seat", json={**WHO, "table": "A7", "order_id": "o-none"})
    assert c.get("/orders").json()["orders"] == []
    assert c.get("/floor").json()["status"] == {}


def calling(c: TestClient, phone: str) -> list[tuple[str, str, str]]:
    r = c.get("/reservations/caller", params={"phone": phone})
    assert r.status_code == 200, r.text
    return [(b["name"], b["day"], b["time"]) for b in r.json()["booked"]]


def test_somebody_calling_is_told_the_tables_their_number_has_booked():
    c, wall = hub()
    tonight = add(c, "Chen", 4, "18:30", phone="781 555 0101", table="A8")
    add(c, "Chen", 6, "12:00", day=SAT, phone="(781) 555-0101")
    add(c, "Garcia", 2, "19:00", phone="617 555 0199")
    gone = add(c, "Chen", 2, "20:00", day=TUE, phone="781 555 0101")
    add(c, "Okafor", 5, "17:00")  # booked without a number: nobody's call finds it

    # by the digits, however the number was typed and however the caller ID writes it; the soonest first
    assert calling(c, "+17815550101") == [("Chen", MON, "18:30"), ("Chen", TUE, "20:00"), ("Chen", SAT, "12:00")]
    told = c.get("/reservations/caller", params={"phone": "781-555-0101"}).json()
    assert (told["phone"], told["today"]) == ("7815550101", MON)
    first = told["booked"][0]
    assert (first["id"], first["size"], first["table"], first["table_label"], first["status"]) == (
        tonight["id"],
        4,
        "A8",
        "A8",
        "booked",
    )

    # another number, a number nobody booked with, one too short to be a number, and none at all
    assert calling(c, "617 555 0199") == [("Garcia", MON, "19:00")]
    assert calling(c, "781 555 0102") == []
    assert calling(c, "550101") == []
    assert calling(c, "") == []
    assert c.get("/reservations/caller").json()["booked"] == []

    # only what still stands: not one that was cancelled, nor one that sat down
    assert c.post(f"/reservations/{gone['id']}/cancel", json=WHO).status_code == 200
    assert calling(c, "781 555 0101") == [("Chen", MON, "18:30"), ("Chen", SAT, "12:00")]
    wall.now = at(18, 35)
    sat = c.post(f"/reservations/{tonight['id']}/seat", json={**WHO, "table": "A8", "order_id": "o1"})
    assert sat.status_code == 200
    assert calling(c, "781 555 0101") == [("Chen", SAT, "12:00")]

    # and nothing of a day that is over
    wall.now = at(12, day=22)
    assert calling(c, "781 555 0101") == []


def test_asking_who_calls_changes_nothing_in_the_book():
    book, _ = book_at()
    book.add("Chen", 4, MON, "18:30", phone="781 555 0101", by_id="s4", by="Holly")
    before = book.book()
    assert [b.name for b in book.of_phone("1 781 555 0101")] == ["Chen"]
    assert book.of_phone(None) == [] and book.of_phone(7815550101) != []
    assert book.book() == before
    for n in range(reservations.MOST_OF_A_CALLER + 2):
        book.add(f"Chen {n}", 2, TUE, "18:00", phone="7815550101", by_id="s4", by="Holly")
    assert len(book.of_phone("781 555 0101")) == reservations.MOST_OF_A_CALLER


# A table booked somewhere else (the website) ---------------------------------------------------------------


def taken(book: Reservations, number: str = "gf-401", when: int = at(18, 30), **more) -> tuple:
    told = {"phone": "+1 781 555 0142", "note": "high chair", "by_id": "online", "by": "the website", **more}
    return book.take(number, told.pop("name", "Pat Example"), told.pop("size", 4), when, **told)


def test_a_table_booked_on_the_website_is_in_the_book_under_the_website_s_own_number():
    book, wall = book_at()
    pat, new = taken(book, when=at(19, 30, day=17))
    assert new and (pat.booking_id, pat.name, pat.size, pat.at_ms) == ("gf-401", "Pat Example", 4, at(19, 30, day=17))
    assert (pat.phone, pat.note, pat.table, pat.by, pat.made_ms) == (
        "+1 781 555 0142",
        "high chair",
        "",
        "the website",
        at(15),
    )
    told = book.book(pat.day)
    (row,) = told["booked"]
    assert (row["id"], row["online"], row["day"], row["time"], row["status"]) == (
        "gf-401",
        "401",
        TUE,
        "19:30",
        "booked",
    )
    assert told["ahead"] == [{"day": TUE, "parties": 1, "guests": 4}]
    # one written on a screen came from no website
    chen = book.add("Chen", 2, MON, "18:30", by_id="s4", by="Holly")
    assert chen.online == "" and book.book()["booked"][0]["online"] == ""
    # somebody who calls about it is found by the number they gave the website
    assert [b.booking_id for b in book.of_phone("781-555-0142")] == ["gf-401"]


def test_the_same_one_given_again_changes_nothing_whatever_was_done_with_it_since():
    book, wall = book_at()
    pat, _ = taken(book)
    again, new = taken(book, name="Somebody Else", size=9, when=at(21))
    assert not new and again == pat and len(book.book()["booked"]) == 1
    # a host put it right, and then took it out of the book: it is not booked again behind their back
    book.change("gf-401", "Pat Example", 6, MON, "19:00", phone="+1 781 555 0142", table="A7", table_label="A7")
    assert taken(book)[0].size == 6
    book.cancel("gf-401", by="Holly")
    gone, new = taken(book)
    assert not new and gone.status == "cancelled" and book.book()["booked"] == []


def test_the_book_s_own_rules_hold_for_a_table_booked_elsewhere(monkeypatch):
    book, wall = book_at()
    for change, code in (
        ({"when": at(18, 30, day=15)}, "past_day"),
        ({"when": at(18, 30) + (MOST_AHEAD_DAYS + 1) * 24 * 60 * MINUTE}, "too_far"),
        ({"size": 0}, "bad_size"),
        ({"size": MOST_GUESTS + 1}, "bad_size"),
        ({"name": ""}, "no_name"),
        ({"name": "x" * (NAME_MAX + 1)}, "long_text"),
        ({"note": "x" * (NOTE_MAX + 1)}, "long_text"),
        ({"phone": "call me maybe"}, "bad_phone"),
    ):
        with pytest.raises(Refused) as no:
            taken(book, **change)
        assert no.value.code == code, change
    assert book.book()["booked"] == []
    # a time of today that has passed is taken, as it is from a screen
    assert taken(book, when=at(14))[1]
    # and a day that is full takes no more
    monkeypatch.setattr(reservations, "MOST_A_DAY", 1)
    with pytest.raises(Refused) as full:
        taken(book, "gf-402")
    assert full.value.code == "too_many"
    assert taken(book, "gf-402", when=at(18, 30, day=17))[1]  # another day has room


def test_a_screen_cannot_write_a_reservation_as_the_website_s():
    c, _ = hub()
    made = c.post(
        "/reservations",
        json={**WHO, "id": "gf-401", "online": "401", "name": "Chen", "size": 4, "day": MON, "time": "18:30"},
    ).json()["booking"]
    assert made["online"] == "" and not made["id"].startswith("gf-") and made["by"] == "Holly"


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_book_is_kept_in_postgres():
    import psycopg

    from pos.reservations import PgBookStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS reservation")
    store = PgBookStore(DSN)
    try:
        book, wall = book_at(at(15), store)
        chen = book.add("Chen", 4, MON, "18:30", phone="781 555 0101", note="booth", table="A7", by_id="s4", by="Holly")
        garcia = book.add("Garcia", 2, MON, "18:30", by_id="s1", by="Amy")
        okafor = book.add("Okafor", 6, MON, "17:00", table="A7", table_label="A7", by_id="s4", by="Holly")
        weekend = book.add("Silva", 8, SAT, "00:30", by_id="s4", by="Holly")
        wall.now = at(18, 20)
        book.arrive(chen.booking_id)
        wall.now = at(18, 33)
        book.seat(chen.booking_id, "A8", table_label="A8", order_id="o-1", by="Holly")
        wall.now = at(19)
        book.cancel(garcia.booking_id, "no_show", by="Amy")
        book.change(okafor.booking_id, "Okafor", 7, MON, "20:00", table="A7", table_label="A7")

        again = PgBookStore(DSN)  # another process: the hub after a restart
        try:
            later, wall2 = book_at(at(19, 5), again)
            assert {table: [h["name"] for h in holds] for table, holds in later.holds().items()} == {"A7": ["Okafor"]}
            assert later.of_phone("781 555 0101") == []  # Chen sat down
            told = later.book()
            assert [(b["name"], b["size"], b["time"], b["table"]) for b in told["booked"]] == [
                ("Okafor", 7, "20:00", "A7")
            ]
            assert [(b["name"], b["status"]) for b in told["earlier"]] == [("Garcia", "no_show"), ("Chen", "seated")]
            sat = told["earlier"][1]
            assert (sat["table"], sat["seated_table"], sat["order_id"], sat["arrived_ms"], sat["ended_by"]) == (
                "A7",
                "A8",
                "o-1",
                at(18, 20),
                "Holly",
            )
            assert (sat["phone"], sat["note"], sat["by"], sat["made_ms"]) == ("781 555 0101", "booth", "Holly", at(15))
            assert told["counts"] == {"booked": 1, "guests": 7, "seated": 1, "cancelled": 0, "no_show": 1}
            assert told["ahead"] == [
                {"day": MON, "parties": 1, "guests": 7},
                {"day": SAT, "parties": 1, "guests": 8},
            ]
            assert later.book(localtime.day_of(at(12, day=21)))["booked"][0]["at_ms"] == at(0, 30, day=22)
            back = later.back(garcia.booking_id)
            assert back.status == "booked" and back.ended_ms is None
            assert [b["name"] for b in later.book()["booked"]] == ["Garcia", "Okafor"]

            # a table booked on the website is kept under the website's number, once
            pat, new = taken(later, when=at(21))
            assert new and again.get("gf-401") == pat and not taken(later, size=9)[1]
            assert [(b["name"], b["online"]) for b in later.book()["booked"]][-1] == ("Pat Example", "401")
            later.cancel("gf-401", by="Holly")

            # two for the same time stay in the order they were written, whatever was changed since
            later.change(okafor.booking_id, "Okafor", 7, MON, "18:30")
            assert [b["name"] for b in later.book()["booked"]] == ["Garcia", "Okafor"]

            # a month and a day on, the first table booked takes the old names and numbers off
            wall2.now = at(12, day=22, month=12)
            later.add("Nguyen", 2, "2026-12-22", "18:00", by_id="s4", by="Holly")
            kept = again.get(chen.booking_id)
            assert (kept.name, kept.phone, kept.note, kept.size, kept.seated_table) == ("", "", "", 4, "A8")
            assert again.get(weekend.booking_id).name == ""  # 21 November is a month gone by then
            assert [b["name"] for b in later.book()["booked"]] == ["Nguyen"]
        finally:
            again.close()
    finally:
        store.close()
        with psycopg.connect(DSN) as conn:
            conn.execute("DROP TABLE IF EXISTS reservation")
