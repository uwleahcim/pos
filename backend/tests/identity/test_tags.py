"""Staff tags: the ids as a reader types them, whose they are, the manager's calls, and the hands-free
switching settings."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.staff import Directory, Staff
from pos.identity.tags import NO_TAG, PgTagStore, TagStore, TagTaken, clean_tag_uid, sign_in_by_tag
from pos.settings import SettingStore, clean_presence

DSN = os.environ.get("POS_TEST_DATABASE_URL")


def staff() -> Directory:
    return Directory(
        [
            Staff.with_pin("s1", "Amy", "server", "1111"),
            Staff.with_pin("s2", "Ben", "bartender", "2222", tag_uid="AABBCCDD"),  # listed with the staff (POS_STAFF)
            Staff.with_pin("s3", "Mike", "manager", "9999"),
        ]
    )


def test_a_tag_id_is_kept_as_typed_without_separators():
    assert clean_tag_uid("04:a2-b3 c4\n") == "04A2B3C4"
    assert clean_tag_uid("0001234567") == "0001234567", "a 125 kHz card's decimal id"
    for bad in ("", "04A", "04A2!B3", "x" * 65, None):
        with pytest.raises(ValueError):
            clean_tag_uid(bad)


def test_a_tag_is_one_persons_at_a_time():
    store = TagStore()
    tag = store.assign("s1", "04A2B3C4D5E6F7", device="mac1")
    assert (tag.staff_id, tag.uid, tag.device) == ("s1", "04A2B3C4D5E6F7", "mac1")
    assert tag.summary()["ends"] == "E6F7" and tag.summary()["enrolled"] is True
    assert store.staff_for("04A2B3C4D5E6F7") == "s1" and store.for_staff("s1") == tag
    with pytest.raises(TagTaken) as taken:
        store.assign("s2", "04A2B3C4D5E6F7")
    assert taken.value.staff_id == "s1"
    store.assign("s1", "11112222")  # a new badge replaces the old one
    assert store.staff_for("04A2B3C4D5E6F7") is None and store.staff_for("11112222") == "s1"
    assert store.forget("s1") == 1 and store.forget("s1") == 0 and store.all() == {}


def test_sign_in_by_tag_knows_enrolled_and_listed_tags():
    store = TagStore()
    directory = staff()
    store.assign("s1", "04A2B3C4D5E6F7")
    store.assign("s9", "99999999")  # no longer on the staff
    amy = sign_in_by_tag(store, directory, "04:a2:b3:c4:d5:e6:f7", device="t1")
    assert amy is not None and (amy.name, amy.method, amy.device) == ("Amy", "tag", "t1")
    ben = sign_in_by_tag(store, directory, "aa bb cc dd", device="t1")
    assert ben is not None and ben.name == "Ben", "a tag listed with the staff member works too"
    assert sign_in_by_tag(store, directory, "00000000", device="t1") is None
    assert sign_in_by_tag(store, directory, "99999999", device="t1") is None
    assert sign_in_by_tag(store, directory, "!!", device="t1") is None


def client() -> TestClient:
    return TestClient(create_app(staff=staff(), settings=SettingStore(), tags=TagStore()))


def token(api: TestClient) -> dict[str, str]:
    answer = api.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()
    return {"authorization": f"Bearer {answer['token']}"}


def test_api_tags_are_a_managers_job_and_sign_people_in():
    api = client()
    assert api.put("/admin/staff/s1/tag", json={"tag_uid": "04A2B3C4"}).status_code == 401
    assert api.delete("/admin/staff/s1/tag").status_code == 401
    auth = token(api)
    assert api.put("/admin/staff/s9/tag", json={"tag_uid": "04A2B3C4"}, headers=auth).status_code == 404
    bad = api.put("/admin/staff/s1/tag", json={"tag_uid": "x!"}, headers=auth)
    assert bad.status_code == 422 and bad.json()["detail"]["error"] == "bad_tag"
    given = api.put("/admin/staff/s1/tag", json={"tag_uid": "04:a2:b3:c4:d5:e6:f7", "device": "mac1"}, headers=auth)
    assert given.status_code == 200
    assert given.json()["staff_id"] == "s1" and given.json()["tag"]["ends"] == "E6F7"
    listed = api.get("/admin/staff", headers=auth).json()["staff"]
    assert listed[0]["tag"]["enrolled"] is True and listed[0]["tag"]["ends"] == "E6F7"
    assert listed[1]["tag"] == NO_TAG
    taken = api.put("/admin/staff/s2/tag", json={"tag_uid": "04A2B3C4D5E6F7"}, headers=auth)
    assert taken.status_code == 409 and taken.json()["detail"]["name"] == "Amy"
    api.put("/staff/s1/preferences", json={"text_scale": 1.3})
    signed = api.post("/signin", json={"device": "t1", "tag_uid": "04a2b3c4d5e6f7"}).json()
    assert (signed["name"], signed["method"], signed["preferences"]["text_scale"]) == ("Amy", "tag", 1.3)
    assert api.post("/signin", json={"device": "t1", "tag_uid": "aa:bb:cc:dd"}).json()["name"] == "Ben"
    assert api.post("/signin", json={"device": "t1", "tag_uid": "00000000"}).status_code == 401
    assert api.delete("/admin/staff/s1/tag", headers=auth).json() == {"staff_id": "s1", "removed": 1}
    assert api.post("/signin", json={"device": "t1", "tag_uid": "04A2B3C4D5E6F7"}).status_code == 401
    assert api.get("/admin/staff", headers=auth).json()["staff"][0]["tag"] == NO_TAG


def test_presence_settings():
    assert clean_presence({}) == {"switch": True, "away_seconds": 60}
    assert clean_presence({"switch": False, "away_seconds": 0}) == {"switch": False, "away_seconds": 0}
    assert clean_presence({"away_seconds": 120.0}) == {"switch": True, "away_seconds": 120}
    bads = [{"switch": "yes"}, {"away_seconds": True}, {"away_seconds": -1}, {"away_seconds": 3601}]
    for bad in [*bads, {"away_seconds": 1.5}]:
        with pytest.raises(ValueError):
            clean_presence(bad)
    api = client()
    assert api.get("/settings/presence").json() == {"switch": True, "away_seconds": 60}
    assert api.put("/settings/presence", json={"switch": False}).status_code == 401, "a manager's setting"
    auth = token(api)
    saved = api.put("/settings/presence", json={"switch": False, "away_seconds": 0}, headers=auth)
    assert saved.status_code == 200 and saved.json() == {"switch": False, "away_seconds": 0}
    assert api.get("/settings/presence").json() == {"switch": False, "away_seconds": 0}
    bad = api.put("/settings/presence", json={"switch": True, "away_seconds": 5000}, headers=auth)
    assert bad.status_code == 422 and "3600" in bad.json()["detail"]["message"]


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_tags_survive_in_postgres():
    store = PgTagStore(DSN)
    try:
        with store._pool.connection() as conn:  # noqa: SLF001 - a clean table for the test
            conn.execute("DELETE FROM staff_tag")
        store.assign("s1", "04A2B3C4D5E6F7", device="mac1")
        again = PgTagStore(DSN)
        try:
            assert again.staff_for("04A2B3C4D5E6F7") == "s1"
            with pytest.raises(TagTaken):
                again.assign("s2", "04A2B3C4D5E6F7")
            again.assign("s1", "11112222")
            assert again.staff_for("04A2B3C4D5E6F7") is None and again.for_staff("s1").uid == "11112222"
            assert again.forget("s1") == 1 and again.all() == {}
        finally:
            again.close()
    finally:
        store.close()
