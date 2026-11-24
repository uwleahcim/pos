"""The staff list as a manager changes it in the app (`pos.api.staff`, docs/staff.md): the calls, who may
make them, what is in force the moment one is made, and that no answer and no log line carries a PIN."""

from __future__ import annotations

import asyncio
import json
import logging

import numpy as np
import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.api.staff import use_staff, watch_staff
from pos.identity.faces import FaceSignIn, FaceStore, Template
from pos.identity.staff import Directory, Staff
from pos.identity.staff_list import Actor, StaffList, StaffStore
from pos.identity.tags import TagStore
from pos.settings import SettingStore
from pos.sync.pgstore import ReadOnlyError

NOW = 1_800_000_000_000
PINS = ("1111", "2222", "9999", "3333", "4827", "5310", "6204", "8080")
"""Every PIN these tests type. None of them is in a time, an id or a name the hub answers with."""


def own() -> list[Staff]:
    return [
        Staff.with_pin("s1", "Amy", "server", "1111"),
        Staff.with_pin("s2", "Ben", "bartender", "2222"),
        Staff.with_pin("s3", "Mike", "manager", "9999"),
        Staff.with_pin("s4", "Holly", "host", "3333"),
    ]


def wired(
    people: list[Staff] | None = None, *, store: StaffStore | None = None, source: str = "hub"
) -> tuple[TestClient, StaffList]:
    staff = StaffList(store, own=own() if people is None else people, source=source, now=lambda: NOW)
    directory = Directory([])
    faces = FaceSignIn(FaceStore(), directory.get)
    app = create_app(staff=directory, staff_list=staff, settings=SettingStore(), tags=TagStore(), faces=faces)
    return TestClient(app), staff


def session(api: TestClient, pin: str = "9999") -> dict[str, str]:
    answer = api.post("/admin/session", json={"device": "t1", "pin": pin})
    assert answer.status_code == 200, answer.text
    return {"authorization": f"Bearer {answer.json()['token']}"}


def signs_in(api: TestClient, pin: str, device: str = "t2") -> str | None:
    answer = api.post("/signin", json={"device": device, "pin": pin})
    return answer.json()["name"] if answer.status_code == 200 else None


def by_id(answer: dict) -> dict[str, dict]:
    return {person["staff_id"]: person for person in answer["staff"]}


# --- who may ---------------------------------------------------------------------------------------------------


def test_the_staff_list_is_a_manager_s_and_nobody_else_s():
    api, staff = wired()
    kim = {"name": "Kim", "role": "server", "pin": "4827"}
    assert api.get("/hub/staff").status_code == 401
    assert api.post("/hub/staff", json=kim).status_code == 401
    assert api.put("/hub/staff/s1", json={"pin": "4827"}).status_code == 401
    assert api.delete("/hub/staff/s1").status_code == 401
    # a server's own session (servers take tables, so the hub gives them one for that) opens none of it
    opened = api.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"})
    assert opened.status_code == 200 and opened.json()["role"] == "server"
    server = {"authorization": f"Bearer {opened.json()['token']}"}
    assert api.get("/hub/staff", headers=server).status_code == 403
    assert api.post("/hub/staff", json=kim, headers=server).status_code == 403
    assert api.put("/hub/staff/s1", json={"pin": "4827"}, headers=server).status_code == 403
    assert api.delete("/hub/staff/s2", headers=server).status_code == 403
    assert staff.source() == "hub" and signs_in(api, "4827") is None


# --- reading ---------------------------------------------------------------------------------------------------


def test_the_list_says_who_is_on_it_and_what_the_one_asking_may_do():
    api, _ = wired()
    said = api.get("/hub/staff", headers=session(api)).json()
    assert said["source"] == "hub" and said["demo_pins"] == 0
    assert said["roles"] == ["server", "bartender", "host", "cashier", "kitchen", "driver", "manager", "owner"]
    assert [p["name"] for p in said["staff"]] == ["Amy", "Ben", "Mike", "Holly"]
    people = by_id(said)
    assert people["s1"] == {
        "staff_id": "s1",
        "name": "Amy",
        "role": "server",
        "you": False,
        "pin": {"from": "hub", "by": "", "at_ms": None},
        "can": {"change": True, "role": True, "remove": True, "why": None},
    }
    assert people["s3"]["you"] is True
    # nobody is an owner here yet, so Mike may make himself one; nothing else of his own role, and not off
    assert people["s3"]["can"] == {"change": True, "role": True, "remove": False, "why": "yourself"}


def test_a_hub_that_still_signs_in_the_demo_staff_says_so():
    api, _ = wired(source="demo")
    mike = session(api)
    said = api.get("/hub/staff", headers=mike).json()
    assert said["source"] == "demo" and said["demo_pins"] == 4
    said = api.put("/hub/staff/s1", json={"pin": "4827"}, headers=mike).json()
    # the list is the app's now, and three people still have a PIN anybody can read in the guide
    assert said["source"] == "app" and said["demo_pins"] == 3
    assert by_id(said)["s1"]["pin"] == {"from": "app", "by": "Mike", "at_ms": NOW}
    assert by_id(said)["s2"]["pin"] == {"from": "demo", "by": "", "at_ms": None}


# --- changing --------------------------------------------------------------------------------------------------


def test_somebody_added_signs_in_at_once_and_is_on_every_list():
    api, staff = wired()
    mike = session(api)
    told: list[str] = []
    api.app.state.feed.changed = told.append  # what the screens are told changed
    answer = api.post("/hub/staff", json={"name": "Kim", "role": "server", "pin": "4827"}, headers=mike)
    assert answer.status_code == 200 and answer.json()["added"] == "s5" and answer.json()["source"] == "app"
    assert by_id(answer.json())["s5"]["pin"] == {"from": "app", "by": "Mike", "at_ms": NOW}
    assert signs_in(api, "4827") == "Kim"
    assert signs_in(api, "1111") == "Amy", "nobody else typed a PIN again"
    roster = {person["staff_id"]: person for person in api.get("/staff").json()["staff"]}
    assert roster["s5"]["name"] == "Kim" and roster["s5"]["takes_tables"] is True
    assert [p["name"] for p in api.get("/admin/staff", headers=mike).json()["staff"]][-1] == "Kim"
    assert staff.source() == "app"
    assert told == ["settings"], "the screens that list the staff read them again"


def test_a_pin_changed_is_the_only_one_that_works_from_that_moment():
    api, _ = wired()
    mike = session(api)
    assert api.put("/hub/staff/s1", json={"pin": "4827"}, headers=mike).status_code == 200
    assert signs_in(api, "1111") is None and signs_in(api, "4827") == "Amy"
    # a manager changes their own, and the session they are in goes on
    assert api.put("/hub/staff/s3", json={"pin": "5310"}, headers=mike).status_code == 200
    assert api.get("/hub/staff", headers=mike).status_code == 200
    assert signs_in(api, "9999") is None and signs_in(api, "5310") == "Mike"


def test_a_name_and_a_role_change_on_every_list():
    api, _ = wired()
    mike = session(api)
    said = api.put("/hub/staff/s1", json={"name": " Amy  W ", "role": "host"}, headers=mike).json()
    assert (by_id(said)["s1"]["name"], by_id(said)["s1"]["role"]) == ("Amy W", "host")
    assert by_id(said)["s1"]["pin"]["from"] == "hub", "the PIN was not touched"
    answer = api.post("/signin", json={"device": "t2", "pin": "1111"}).json()
    assert (answer["name"], answer["role"]) == ("Amy W", "host")
    roster = {person["staff_id"]: person for person in api.get("/staff").json()["staff"]}
    assert roster["s1"]["takes_tables"] is False and roster["s1"]["assigns_tables"] is True


def test_somebody_taken_off_signs_in_no_more_by_pin_tag_or_face():
    api, _ = wired()
    mike = session(api)
    assert api.put("/admin/staff/s2/tag", json={"tag_uid": "04A1B2C3D4E5F6"}, headers=mike).status_code == 200
    api.app.state.faces.store.add(Template("v1", "s2", "fake", np.zeros(4), "t1", 1.0))
    assert api.post("/signin", json={"device": "t2", "tag_uid": "04A1B2C3D4E5F6"}).json()["name"] == "Ben"
    said = api.delete("/hub/staff/s2", headers=mike)
    assert said.status_code == 200 and [p["name"] for p in said.json()["staff"]] == ["Amy", "Mike", "Holly"]
    assert signs_in(api, "2222") is None
    assert api.post("/signin", json={"device": "t2", "tag_uid": "04A1B2C3D4E5F6"}).status_code == 401
    assert api.app.state.tags.for_staff("s2") is None, "the tag is forgotten"
    assert api.app.state.faces.store.for_staff("s2") == [], "and the face"
    assert "s2" not in {person["staff_id"] for person in api.get("/staff").json()["staff"]}
    assert api.app.state.staff.name_of("s2") == "Ben", "what Ben did keeps his name"
    assert api.delete("/hub/staff/s2", headers=mike).status_code == 404
    assert api.put("/hub/staff/s2", json={"name": "Ben again"}, headers=mike).status_code == 404
    # the tag is free for the next person
    assert api.put("/admin/staff/s1/tag", json={"tag_uid": "04A1B2C3D4E5F6"}, headers=mike).status_code == 200


def test_a_session_ends_the_moment_its_holder_is_taken_off_or_given_another_role():
    api, _ = wired([*own(), Staff.with_pin("s5", "Olive", "owner", "8080")])
    mike, olive = session(api), session(api, "8080")
    approval = api.post("/approvals", json={"device": "t1", "pin": "9999", "purpose": "void", "order_id": "o1"})
    assert approval.status_code == 200
    assert api.put("/hub/staff/s3", json={"role": "server"}, headers=olive).status_code == 200
    assert api.get("/hub/staff", headers=mike).status_code == 401, "a manager's session, and Mike is none now"
    assert api.get("/hub/keys", headers=mike).status_code == 401
    assert api.app.state.tokens.verify(approval.json()["approval"]) is None
    assert api.post("/admin/session", json={"device": "t1", "pin": "9999"}).status_code == 403
    assert api.put("/hub/staff/s3", json={"role": "manager"}, headers=olive).status_code == 200
    again = session(api)
    assert api.delete("/hub/staff/s3", headers=olive).status_code == 200
    assert api.get("/hub/staff", headers=again).status_code == 401
    assert api.post("/admin/session", json={"device": "t1", "pin": "9999"}).status_code == 401


def test_a_manager_who_makes_themselves_the_first_owner_stays_signed_in():
    api, staff = wired()
    mike = session(api)
    approval = api.post("/approvals", json={"device": "t1", "pin": "9999", "purpose": "void", "order_id": "o1"})
    said = api.put("/hub/staff/s3", json={"role": "owner"}, headers=mike)
    assert said.status_code == 200 and by_id(said.json())["s3"]["role"] == "owner"
    assert by_id(said.json())["s3"]["can"] == {"change": True, "role": False, "remove": False, "why": "yourself"}
    # an owner may do what a manager may: the session opened as a manager goes on, and so does the approval
    after = api.get("/hub/staff", headers=mike)
    assert after.status_code == 200 and after.json()["roles"][-1] == "owner"
    assert api.get("/hub/keys", headers=mike).status_code == 200
    assert api.app.state.tokens.verify(approval.json()["approval"]) is not None
    assert api.put("/hub/staff/s3", json={"role": "manager"}, headers=mike).json()["detail"]["error"] == "yourself"
    assert api.put("/hub/staff/s1", json={"role": "owner"}, headers=mike).status_code == 200, "as an owner now"
    assert [m.role for m in staff.members()] == ["owner", "bartender", "owner", "host"]


# --- what is refused -------------------------------------------------------------------------------------------


def test_what_the_list_does_not_take_is_refused_in_words_and_nothing_changes():
    api, staff = wired([*own(), Staff.with_pin("s5", "Olive", "owner", "8080")])
    mike = session(api)

    def refused(answer, status: int, error: str) -> str:  # noqa: ANN001
        assert answer.status_code == status and answer.json()["detail"]["error"] == error, answer.text
        return answer.json()["detail"]["message"]

    kim = {"name": "Kim", "role": "server", "pin": "4827"}
    for bad in ({"pin": "48270"}, {"pin": "48a7"}, {"pin": ""}, {"pin": 4827}, {"pin": ["4827"]}, {"pin": "4" * 500}):
        words = refused(api.post("/hub/staff", json={**kim, **bad}, headers=mike), 422, "bad_value")
        assert words == "A PIN is four digits."
    refused(api.post("/hub/staff", json={**kim, "name": ""}, headers=mike), 422, "bad_value")
    refused(api.post("/hub/staff", json={**kim, "name": {"a": 1}}, headers=mike), 422, "bad_value")
    refused(api.post("/hub/staff", json={**kim, "role": "waiter"}, headers=mike), 422, "bad_value")
    refused(api.post("/hub/staff", json={"name": "Kim"}, headers=mike), 422, "bad_value")
    words = refused(api.post("/hub/staff", json={**kim, "pin": "2222"}, headers=mike), 409, "pin_taken")
    assert "2222" not in words and "Ben" not in words
    refused(api.put("/hub/staff/s1", json={"pin": "9999"}, headers=mike), 409, "pin_taken")
    refused(api.post("/hub/staff", json={**kim, "name": "ben"}, headers=mike), 409, "name_taken")
    refused(api.delete("/hub/staff/s3", headers=mike), 409, "yourself")
    refused(api.put("/hub/staff/s3", json={"role": "server"}, headers=mike), 409, "yourself")
    refused(api.delete("/hub/staff/s5", headers=mike), 403, "owner_only")
    refused(api.put("/hub/staff/s5", json={"pin": "4827"}, headers=mike), 403, "owner_only")
    refused(api.put("/hub/staff/s1", json={"role": "owner"}, headers=mike), 403, "owner_only")
    refused(api.put("/hub/staff/s9", json={"name": "Zed"}, headers=mike), 404, "unknown_staff")
    refused(api.delete("/hub/staff/s9", headers=mike), 404, "unknown_staff")
    assert staff.source() == "hub", "not one of them took the list over"
    assert signs_in(api, "8080") == "Olive" and signs_in(api, "4827") is None
    said = api.get("/hub/staff", headers=mike).json()
    assert said["roles"][-1] == "manager", "a manager is offered no owner to make while there is one"
    assert by_id(said)["s5"]["can"] == {"change": False, "role": False, "remove": False, "why": "owner_only"}
    assert by_id(said)["s3"]["can"] == {"change": True, "role": False, "remove": False, "why": "yourself"}


def test_the_last_manager_stays_whoever_asks():
    api, staff = wired()
    assert api.delete("/hub/staff/s3", headers=session(api)).json()["detail"]["error"] == "yourself"
    assert staff.source() == "hub"
    # and from the hub's terminal, where nobody is signed in
    from pos.identity.staff_list import Refused

    with pytest.raises(Refused) as caught:
        staff.remove("s3", by=None)
    assert caught.value.code == "last_manager"


def test_a_standby_changes_nothing_and_says_so():
    class Standby(StaffStore):
        def put(self, member, *, taking_over=()):  # noqa: ANN001, ANN201, ARG002
            raise ReadOnlyError("this database is a standby")

    api, _ = wired(store=Standby())
    mike = session(api)
    answer = api.post("/hub/staff", json={"name": "Kim", "role": "server", "pin": "4827"}, headers=mike)
    assert answer.status_code == 503 and answer.json()["detail"]["error"] == "read_only"
    assert signs_in(api, "4827") is None and signs_in(api, "1111") == "Amy"


# --- a PIN goes one way ------------------------------------------------------------------------------------------


def test_no_answer_and_no_log_line_has_a_pin_in_it(caplog):
    api, staff = wired()
    mike = session(api)
    said: list[str] = []
    with caplog.at_level(logging.DEBUG):
        for answer in (
            api.post("/hub/staff", json={"name": "Kim", "role": "server", "pin": "4827"}, headers=mike),
            api.put("/hub/staff/s5", json={"pin": "5310"}, headers=mike),
            api.put("/hub/staff/s1", json={"pin": "5310"}, headers=mike),  # taken
            api.post("/hub/staff", json={"name": "Lee", "role": "driver", "pin": "62040"}, headers=mike),  # no PIN
            api.put("/hub/staff/s2", json={"name": "Benny", "role": "host"}, headers=mike),
            api.delete("/hub/staff/s4", headers=mike),
            api.get("/hub/staff", headers=mike),
            api.get("/admin/staff", headers=mike),
            api.get("/staff"),
        ):
            said.append(answer.text)
    logged = "\n".join(record.getMessage() for record in caplog.records)
    for text in (*said, logged):
        for pin in ("4827", "5310", "62040"):
            assert pin not in text
    kept = {m.staff_id: m for m in staff.store.all()}
    for text in said:
        for member in kept.values():
            assert not member.pin_hash or member.pin_hash not in text
            assert not member.pin_salt or member.pin_salt not in text
        assert "pin_hash" not in text and "pin_salt" not in text
    # the log says who changed whom, by name
    for line in (
        "staff: Kim (s5) was added as server by Mike",
        "staff: the PIN of Kim (s5) was changed by Mike",
        "staff: Ben (s2) is now called Benny, changed by Mike",
        "staff: Benny (s2) is now a host, was a bartender, changed by Mike",
        "staff: Holly (s4, host) was taken off the staff by Mike",
    ):
        assert line in logged


def test_what_the_database_holds_is_no_pin():
    api, staff = wired()
    mike = session(api)
    api.post("/hub/staff", json={"name": "Kim", "role": "server", "pin": "4827"}, headers=mike)
    dumped = json.dumps([vars(member) for member in staff.store.all()])
    for pin in PINS:
        assert pin not in dumped


# --- a change made somewhere else ----------------------------------------------------------------------------------


async def one_look(app, within: float = 10.0) -> None:  # noqa: ANN001
    was = app.state.staff_mark
    looking = asyncio.create_task(watch_staff(app, every=0.01))
    try:
        async with asyncio.timeout(within):
            while app.state.staff_mark == was:
                await asyncio.sleep(0.01)
    finally:
        looking.cancel()
        await asyncio.gather(looking, return_exceptions=True)


def test_a_hub_notices_a_change_made_on_the_other_hub_or_in_the_terminal():
    store = StaffStore()
    api, _ = wired(store=store)
    mike = session(api)
    assert api.put("/admin/staff/s2/tag", json={"tag_uid": "04A1B2C3D4E5F6"}, headers=mike).status_code == 200
    # the location's other hub, on the same database
    other = StaffList(store, own=own(), now=lambda: NOW + 5)
    other.add("Kim", "server", "4827", by=Actor("s3", "Mike"))
    other.remove("s2", by=Actor("s3", "Mike"))
    other.change("s1", pin="5310", by=None)  # and `hubctl staff pin`
    assert signs_in(api, "4827") is None and signs_in(api, "2222") == "Ben", "not yet"
    asyncio.run(one_look(api.app))
    assert signs_in(api, "4827") == "Kim" and signs_in(api, "2222") is None
    assert signs_in(api, "5310") == "Amy" and signs_in(api, "1111") is None
    assert api.app.state.tags.for_staff("s2") is None
    said = api.get("/hub/staff", headers=mike).json()
    assert said["source"] == "app" and by_id(said)["s1"]["pin"]["from"] == "terminal"
    assert by_id(said)["s1"]["pin"]["by"] == "the hub's terminal"


def test_a_hub_that_cannot_read_its_staff_at_the_start_goes_on_with_its_own_and_looks_again():
    class Flaky(StaffStore):
        down = True

        def all(self):  # noqa: ANN201
            if self.down:
                raise OSError("the database is not up yet")
            return super().all()

    store = Flaky()
    store.down = False
    StaffList(store, own=own()).add("Kim", "server", "4827", by=Actor("s3", "Mike"))
    store.down = True
    staff = StaffList(store, own=own(), now=lambda: NOW)
    directory = Directory(own())
    app = create_app(staff=directory, staff_list=staff, settings=SettingStore(), tags=TagStore())
    api = TestClient(app)
    assert signs_in(api, "1111") == "Amy" and signs_in(api, "4827") is None
    store.down = False
    asyncio.run(one_look(app))
    assert signs_in(api, "4827") == "Kim"


def test_use_staff_keeps_the_one_directory_everything_holds():
    api, staff = wired()
    directory = api.app.state.staff
    staff.add("Kim", "server", "4827", by=Actor("s3", "Mike"))
    use_staff(api.app)
    assert api.app.state.staff is directory and directory.get("s5").name == "Kim"
    assert api.app.state.faces.staff("s5").name == "Kim", "the face sign-in asks the same directory"
