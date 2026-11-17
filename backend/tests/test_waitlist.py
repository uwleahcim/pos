"""The waitlist: a party is put on the list with a name, a size and the wait it was told; it waits in the
order it came; it goes off the list by sitting down or by leaving, and can be put back; the list is
tonight's, and the names and numbers of the nights before are not kept."""

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
from pos.sync.oplog import OpStore
from pos.waitlist import MOST_GUESTS, MOST_QUOTE, MOST_WAITING, NAME_MAX, NOTE_MAX, Refused, Waitlist, WaitStore

DSN = os.environ.get("POS_TEST_DATABASE_URL")

MINUTE = 60_000


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """A time on the restaurant's own clock in November 2026, in wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


class Wall:
    """The hub's clock, set by the test."""

    def __init__(self, now: int) -> None:
        self.now = now

    def __call__(self) -> int:
        return self.now


def list_at(now: int = at(18), store: WaitStore | None = None) -> tuple[Waitlist, Wall]:
    wall = Wall(now)
    return Waitlist(store, now_ms=wall), wall


def hub(now: int = at(18)) -> tuple[TestClient, Wall]:
    waitlist, wall = list_at(now)
    app = create_app(OpStore(), menu=MenuService(build_example()), printing=PrintService([]), waitlist=waitlist)
    return TestClient(app), wall


def add(c: TestClient, name: str = "Chen", size: int = 4, staff_id: str = "s4", **more) -> dict:
    r = c.post("/waitlist", json={"staff_id": staff_id, "name": name, "size": size, **more})
    assert r.status_code == 200, r.text
    return r.json()["party"]


def tonight(c: TestClient) -> dict:
    r = c.get("/waitlist")
    assert r.status_code == 200, r.text
    return r.json()


def names(told: dict, part: str = "waiting") -> list[str]:
    return [p["name"] for p in told[part]]


def refused(r) -> tuple[int, str]:
    return r.status_code, r.json()["detail"]["error"]


def test_a_party_waits_in_the_order_it_came():
    c, wall = hub()
    assert tonight(c)["waiting"] == [] and tonight(c)["counts"]["waiting"] == 0
    chen = add(c, "  Chen ", 4, phone="781 555 0101", quoted_minutes=20, note="high  chair")
    assert chen["name"] == "Chen" and chen["size"] == 4 and chen["phone"] == "781 555 0101"
    assert chen["note"] == "high chair" and chen["by"] == "Holly" and chen["status"] == "waiting"
    # the hub's clock says when they came, and when their wait turns amber and red
    assert chen["at_ms"] == at(18) and chen["due_ms"] == at(18, 20) and chen["amber_ms"] == at(18, 15)
    wall.now = at(18, 5)
    garcia = add(c, "Garcia", 2, staff_id="s1")
    assert garcia["quoted_minutes"] is None and garcia["due_ms"] is None and garcia["amber_ms"] is None
    wall.now = at(18, 7)
    add(c, "Okafor", 6, quoted_minutes=3)

    told = tonight(c)
    assert names(told) == ["Chen", "Garcia", "Okafor"]
    assert told["counts"] == {"waiting": 3, "guests": 12, "seated": 0, "left": 0, "average_wait_minutes": None}
    assert told["quotes"] == [5, 10, 15, 20, 30, 45, 60, 90]
    # nothing in the answer moves with the clock: a list nobody changed reads as unchanged
    wall.now = at(18, 9)
    assert tonight(c) == told
    # a wait shorter than the amber warning is amber from the start
    assert told["waiting"][2]["amber_ms"] == at(18, 7) and told["waiting"][2]["due_ms"] == at(18, 10)


def test_anyone_signed_in_keeps_the_list_and_a_stranger_does_not():
    c, _ = hub()
    for staff_id in ("s1", "s2", "s3", "s4"):
        add(c, f"Party {staff_id}", 2, staff_id=staff_id)
    assert [p["by"] for p in tonight(c)["waiting"]] == ["Amy", "Ben", "Mike", "Holly"]
    r = c.post("/waitlist", json={"staff_id": "s99", "name": "Chen", "size": 2})
    assert refused(r) == (404, "unknown_staff")
    party = tonight(c)["waiting"][0]["id"]
    for path in ("called", "seat", "left", "back"):
        body = {"staff_id": "s99", "table": "A7"}
        assert refused(c.post(f"/waitlist/{party}/{path}", json=body)) == (404, "unknown_staff")
    assert len(tonight(c)["waiting"]) == 4


def test_what_the_list_refuses():
    c, _ = hub()
    who = {"staff_id": "s4"}

    def tried(**body) -> tuple[int, str]:
        return refused(c.post("/waitlist", json={**who, "name": "Chen", "size": 2, **body}))

    assert tried(name="   ") == (422, "no_name")
    assert tried(name="x" * (NAME_MAX + 1)) == (422, "long_text")
    assert tried(size=0) == (422, "bad_size")
    assert tried(size=MOST_GUESTS + 1) == (422, "bad_size")
    assert tried(quoted_minutes=0) == (422, "bad_quote")
    assert tried(quoted_minutes=MOST_QUOTE + 1) == (422, "bad_quote")
    assert tried(phone="555") == (422, "bad_phone")
    assert tried(phone="call my cell") == (422, "bad_phone")
    assert tried(note="x" * (NOTE_MAX + 1)) == (422, "long_text")
    assert tonight(c)["waiting"] == []
    # the largest party, the longest wait and a number with its signs are taken
    big = add(c, "x" * NAME_MAX, MOST_GUESTS, quoted_minutes=MOST_QUOTE, phone="+1 (781) 555-0101")
    assert big["size"] == MOST_GUESTS and big["phone"] == "+1 (781) 555-0101"
    assert refused(c.post("/waitlist/no-such-party/left", json=who)) == (404, "unknown_party")
    assert refused(c.post(f"/waitlist/{big['id']}/left", json={**who, "why": "bored"})) == (422, "bad_why")
    assert refused(c.post(f"/waitlist/{big['id']}/seat", json={**who, "table": "ZZ9"})) == (404, "unknown_table")


def test_sixty_parties_wait_at_most():
    waitlist, _ = list_at()
    for n in range(MOST_WAITING):
        waitlist.add(f"Party {n}", 2, by_id="s4", by="Holly")
    with pytest.raises(Refused) as err:
        waitlist.add("One more", 2, by_id="s4", by="Holly")
    assert err.value.code == "too_many"
    # a party that sat down makes room
    first = waitlist.tonight()["waiting"][0]["id"]
    waitlist.seat(first, "A7", by="Holly")
    waitlist.add("One more", 2, by_id="s4", by="Holly")
    with pytest.raises(Refused) as err:
        waitlist.back(first)
    assert err.value.code == "too_many"


def test_a_waiting_party_is_put_right_and_keeps_its_place():
    c, wall = hub()
    chen = add(c, "Chen", 4, quoted_minutes=20)
    wall.now = at(18, 5)
    add(c, "Garcia", 2)
    wall.now = at(18, 12)
    body = {"staff_id": "s1", "name": "Chen W", "size": 5, "phone": "7815550101", "quoted_minutes": 30, "note": "booth"}
    r = c.put(f"/waitlist/{chen['id']}", json=body)
    assert r.status_code == 200, r.text
    changed = r.json()["party"]
    assert (changed["name"], changed["size"], changed["phone"], changed["note"]) == ("Chen W", 5, "7815550101", "booth")
    # the wait told is still counted from when they came, and who put them on the list stays
    assert changed["at_ms"] == at(18) and changed["due_ms"] == at(18, 30) and changed["by"] == "Holly"
    assert names(r.json()) == ["Chen W", "Garcia"]
    assert refused(c.put(f"/waitlist/{chen['id']}", json={**body, "size": 0})) == (422, "bad_size")
    # one that is off the list is not changed
    c.post(f"/waitlist/{chen['id']}/left", json={"staff_id": "s4"})
    assert refused(c.put(f"/waitlist/{chen['id']}", json=body)) == (409, "not_waiting")


def test_a_party_is_called_once():
    c, wall = hub()
    chen = add(c)
    wall.now = at(18, 10)
    called = c.post(f"/waitlist/{chen['id']}/called", json={"staff_id": "s4"}).json()["party"]
    assert called["called_ms"] == at(18, 10) and called["status"] == "waiting"
    wall.now = at(18, 14)
    again = c.post(f"/waitlist/{chen['id']}/called", json={"staff_id": "s4", "on": True}).json()["party"]
    assert again["called_ms"] == at(18, 10)  # the first call counts
    off = c.post(f"/waitlist/{chen['id']}/called", json={"staff_id": "s4", "on": False}).json()["party"]
    assert off["called_ms"] is None


def test_a_party_sits_down_at_a_table():
    c, wall = hub()
    chen = add(c, "Chen", 4, quoted_minutes=20)
    wall.now = at(18, 5)
    garcia = add(c, "Garcia", 2)
    wall.now = at(18, 17)
    r = c.post(f"/waitlist/{chen['id']}/seat", json={"staff_id": "s4", "table": "A7", "order_id": "o-1"})
    assert r.status_code == 200, r.text
    sat = r.json()["party"]
    assert sat["status"] == "seated" and sat["seated_ms"] == at(18, 17) and sat["waited_minutes"] == 17
    assert (sat["table"], sat["table_label"], sat["order_id"], sat["ended_by"]) == ("A7", "A7", "o-1", "Holly")
    told = r.json()
    assert names(told) == ["Garcia"] and names(told, "earlier") == ["Chen"]
    assert told["counts"] == {"waiting": 1, "guests": 2, "seated": 1, "left": 0, "average_wait_minutes": 17}

    # sat a second time (two screens at once): the first table counts
    again = c.post(f"/waitlist/{chen['id']}/seat", json={"staff_id": "s1", "table": "B5", "order_id": "o-2"})
    assert again.status_code == 200 and again.json()["party"]["table"] == "A7"
    assert again.json()["party"]["order_id"] == "o-1"
    # a seated party is not called and does not leave
    assert refused(c.post(f"/waitlist/{chen['id']}/called", json={"staff_id": "s4"})) == (409, "not_waiting")
    assert refused(c.post(f"/waitlist/{chen['id']}/left", json={"staff_id": "s4"})) == (409, "not_waiting")

    wall.now = at(18, 30)
    c.post(f"/waitlist/{garcia['id']}/seat", json={"staff_id": "s4", "table": "B5"})
    told = tonight(c)
    assert names(told, "earlier") == ["Garcia", "Chen"]  # the last to go first
    assert told["counts"]["average_wait_minutes"] == 21  # 17 and 25 minutes


def test_a_party_leaves_or_does_not_show():
    c, wall = hub()
    chen = add(c, "Chen", 4)
    garcia = add(c, "Garcia", 2)
    wall.now = at(18, 25)
    left = c.post(f"/waitlist/{chen['id']}/left", json={"staff_id": "s1"}).json()["party"]
    assert (left["status"], left["left_why"], left["left_ms"], left["ended_by"]) == ("left", "left", at(18, 25), "Amy")
    assert left["waited_minutes"] == 25
    wall.now = at(18, 40)
    gone = c.post(f"/waitlist/{garcia['id']}/left", json={"staff_id": "s4", "why": "no_show"}).json()
    assert gone["party"]["left_why"] == "no_show"
    assert gone["waiting"] == [] and names(gone, "earlier") == ["Garcia", "Chen"]
    assert gone["counts"] == {"waiting": 0, "guests": 0, "seated": 0, "left": 2, "average_wait_minutes": None}
    # taken off twice changes nothing, and a party that left is not sat down
    again = c.post(f"/waitlist/{chen['id']}/left", json={"staff_id": "s4", "why": "no_show"}).json()["party"]
    assert again["left_why"] == "left" and again["ended_by"] == "Amy"
    assert refused(c.post(f"/waitlist/{chen['id']}/seat", json={"staff_id": "s4", "table": "A7"})) == (
        409,
        "not_waiting",
    )


def test_a_party_taken_off_by_mistake_is_put_back_where_it_stood():
    c, wall = hub()
    chen = add(c, "Chen", 4, quoted_minutes=20)
    wall.now = at(18, 5)
    garcia = add(c, "Garcia", 2)
    wall.now = at(18, 10)
    c.post(f"/waitlist/{chen['id']}/called", json={"staff_id": "s4"})
    c.post(f"/waitlist/{chen['id']}/seat", json={"staff_id": "s4", "table": "A7", "order_id": "o-1"})
    c.post(f"/waitlist/{garcia['id']}/left", json={"staff_id": "s4"})
    wall.now = at(18, 12)
    back = c.post(f"/waitlist/{chen['id']}/back", json={"staff_id": "s4"}).json()
    party = back["party"]
    assert party["status"] == "waiting" and party["at_ms"] == at(18) and party["due_ms"] == at(18, 20)
    assert (party["table"], party["order_id"], party["seated_ms"], party["ended_by"]) == ("", "", None, "")
    assert party["called_ms"] == at(18, 10)  # that they were called is still true
    assert names(back) == ["Chen"] and names(back, "earlier") == ["Garcia"]
    back = c.post(f"/waitlist/{garcia['id']}/back", json={"staff_id": "s4"}).json()
    assert names(back) == ["Chen", "Garcia"] and back["earlier"] == []  # each where it stood
    assert c.post(f"/waitlist/{garcia['id']}/back", json={"staff_id": "s4"}).json()["party"]["status"] == "waiting"


def test_the_list_is_tonights_and_the_names_of_the_nights_before_are_not_kept():
    store = WaitStore()
    waitlist, wall = list_at(at(21), store)
    chen = waitlist.add("Chen", 4, phone="781 555 0101", note="booth", by_id="s4", by="Holly")
    garcia = waitlist.add("Garcia", 2, phone="781 555 0102", by_id="s4", by="Holly")
    waitlist.seat(chen.party_id, "A7", by="Holly")
    # half past midnight is still the same night
    wall.now = at(0, 30, day=17)
    late = waitlist.add("Okafor", 3, by_id="s4", by="Holly")
    assert [p["name"] for p in waitlist.tonight()["waiting"]] == ["Garcia", "Okafor"]
    assert store.get(chen.party_id).phone == "781 555 0101"

    # the next day the list starts empty; a party of last night is not found on it
    wall.now = at(11, day=17)
    told = waitlist.tonight()
    assert told["waiting"] == [] and told["earlier"] == [] and told["counts"]["seated"] == 0
    with pytest.raises(Refused) as err:
        waitlist.seat(garcia.party_id, "A7")
    assert err.value.code == "unknown_party"
    # reading keeps what is there; the first party of the new night takes the names and numbers off
    assert store.get(garcia.party_id).name == "Garcia"
    waitlist.add("Silva", 2, phone="781 555 0199", by_id="s4", by="Holly")
    for old in (chen, garcia, late):
        kept = store.get(old.party_id)
        assert (kept.name, kept.phone, kept.note) == ("", "", "")
        assert (kept.size, kept.at_ms) == (old.size, old.at_ms)  # how many and when they came stays
    assert store.get(chen.party_id).status == "seated" and store.get(chen.party_id).table == "A7"
    assert [(p["name"], p["phone"]) for p in waitlist.tonight()["waiting"]] == [("Silva", "781 555 0199")]


def test_the_screens_are_told_when_the_list_changes():
    c, _ = hub()
    said: list[str] = []
    c.app.state.feed.changed = said.append
    chen = add(c)
    who = {"staff_id": "s4"}
    c.put(f"/waitlist/{chen['id']}", json={**who, "name": "Chen", "size": 5})
    c.post(f"/waitlist/{chen['id']}/called", json=who)
    c.post(f"/waitlist/{chen['id']}/seat", json={**who, "table": "A7"})
    c.post(f"/waitlist/{chen['id']}/back", json=who)
    c.post(f"/waitlist/{chen['id']}/left", json=who)
    assert said == ["waitlist"] * 6
    # what is refused, and reading, tells nobody
    c.post("/waitlist", json={**who, "name": "", "size": 2})
    c.post(f"/waitlist/{chen['id']}/called", json=who)
    tonight(c)
    assert said == ["waitlist"] * 6


def test_a_party_is_no_check_and_no_sale():
    c, _ = hub()
    chen = add(c, "Chen", 4)
    c.post(f"/waitlist/{chen['id']}/seat", json={"staff_id": "s4", "table": "A7", "order_id": "o-none"})
    # the list opens no check by itself: the screen that seats the party does, as for a party walking in
    assert c.get("/orders").json()["orders"] == []
    assert c.get("/floor").json()["status"] == {}


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_list_is_kept_in_postgres():
    import psycopg

    from pos.waitlist import PgWaitStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS waitlist_party")
    store = PgWaitStore(DSN)
    try:
        waitlist, wall = list_at(at(18), store)
        chen = waitlist.add("Chen", 4, phone="781 555 0101", quoted_minutes=20, note="booth", by_id="s4", by="Holly")
        wall.now = at(18, 5)
        garcia = waitlist.add("Garcia", 2, by_id="s1", by="Amy")
        wall.now = at(18, 6)
        okafor = waitlist.add("Okafor", 6, quoted_minutes=45, by_id="s4", by="Holly")
        wall.now = at(18, 10)
        waitlist.call(chen.party_id)
        wall.now = at(18, 17)
        waitlist.seat(chen.party_id, "A7", table_label="A7", order_id="o-1", by="Holly")
        wall.now = at(18, 18)
        waitlist.leave(garcia.party_id, "no_show", by="Amy")
        waitlist.change(okafor.party_id, "Okafor", 7, quoted_minutes=45)

        again = PgWaitStore(DSN)  # another process: the hub after a restart
        try:
            later, wall2 = list_at(at(18, 20), again)
            told = later.tonight()
            assert [(p["name"], p["size"], p["due_ms"]) for p in told["waiting"]] == [("Okafor", 7, at(18, 51))]
            assert [(p["name"], p["status"], p["waited_minutes"]) for p in told["earlier"]] == [
                ("Garcia", "left", 13),
                ("Chen", "seated", 17),
            ]
            sat = told["earlier"][1]
            assert (sat["table"], sat["order_id"], sat["called_ms"], sat["ended_by"]) == (
                "A7",
                "o-1",
                at(18, 10),
                "Holly",
            )
            assert (sat["phone"], sat["note"], sat["by"]) == ("781 555 0101", "booth", "Holly")
            assert told["earlier"][0]["left_why"] == "no_show"
            assert told["counts"] == {"waiting": 1, "guests": 7, "seated": 1, "left": 1, "average_wait_minutes": 17}
            back = later.back(garcia.party_id)
            assert back.status == "waiting" and back.left_ms is None
            assert [p["name"] for p in later.tonight()["waiting"]] == ["Garcia", "Okafor"]

            # the next night: an empty list, and the first party takes yesterday's names and numbers off
            wall2.now = at(17, day=17)
            assert later.tonight()["waiting"] == []
            later.add("Silva", 2, by_id="s4", by="Holly")
            kept = again.get(chen.party_id)
            assert (kept.name, kept.phone, kept.note, kept.size, kept.table) == ("", "", "", 4, "A7")
            assert [p["name"] for p in later.tonight()["waiting"]] == ["Silva"]
        finally:
            again.close()
    finally:
        store.close()
        with psycopg.connect(DSN) as conn:
            conn.execute("DROP TABLE IF EXISTS waitlist_party")
