from __future__ import annotations

import base64
import re
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.photos import EventPhoto, PhotoStore
from pos.identity.staff import Directory, Locked, Staff, demo_directory

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 100 + b"\xff\xd9"


def directory(clock):
    return Directory(
        [
            Staff.with_pin("s1", "Amy", "server", "1111", tag_uid="04A1B2C3D4E5F6"),
            Staff.with_pin("s3", "Mike", "manager", "9999"),
        ],
        clock=clock,
    )


def test_pin_and_tag_sign_in():
    d = directory(lambda: 0.0)
    assert d.by_pin("1111", device="t1").name == "Amy"
    assert d.by_pin("9999", device="t1").role == "manager"
    assert d.by_pin("0000", device="t1") is None
    assert d.by_tag("04A1B2C3D4E5F6", device="t1").method == "tag"
    assert d.by_tag("nope", device="t1") is None


def test_five_misses_lock_that_device_for_a_minute():
    now = [0.0]
    d = directory(lambda: now[0])
    for _ in range(5):
        assert d.by_pin("0000", device="t1") is None
    with pytest.raises(Locked):
        d.by_pin("1111", device="t1")
    assert d.by_pin("1111", device="t2").name == "Amy"  # another device is not locked
    now[0] += 61
    assert d.by_pin("1111", device="t1").name == "Amy"


def test_pins_are_never_stored_in_clear():
    staff = Staff.with_pin("s1", "Amy", "server", "1111")
    # by their shape, and never for the digits: random hex holds any four digits by chance now and then
    assert re.fullmatch(r"[0-9a-f]{16}", staff.pin_salt) and re.fullmatch(r"[0-9a-f]{64}", staff.pin_hash)
    assert "1111" not in repr(replace(staff, pin_salt="", pin_hash=""))
    assert staff.pin_matches("1111") and not staff.pin_matches("1112")


def test_demo_directory_from_environment(monkeypatch):
    monkeypatch.setenv("POS_STAFF", "a:Ann:server:1234, b:Bo:manager:5678")
    d = demo_directory()
    assert len(d) == 2 and d.by_pin("5678", device="x").name == "Bo"
    monkeypatch.delenv("POS_STAFF")
    assert len(demo_directory()) == 4


def test_a_slip_in_the_staff_list_does_not_keep_the_hub_from_starting(monkeypatch, caplog):
    # an entry with a part missing, an empty one, an id taken twice: left out, and the rest sign in
    monkeypatch.setenv(
        "POS_STAFF", "s3:Mike:manager:9999,d1:Tom:driver,,d2::driver:5555, d3:Wei:driver:6666 ,s3:Max:host:7777"
    )
    with caplog.at_level("WARNING"):
        d = demo_directory()
    assert [(s.staff_id, s.name, s.role) for s in d.all()] == [("s3", "Mike", "manager"), ("d3", "Wei", "driver")]
    assert d.by_pin("6666", device="x").name == "Wei"
    assert [r.getMessage().split()[2] for r in caplog.records if "left out" in r.getMessage()] == ["2", "4", "6"]
    # what is said never repeats an entry: there is a PIN in each
    assert not any(pin in caplog.text for pin in ("9999", "5555", "6666", "7777"))

    # nothing in it reads: the demo staff, so somebody can still sign in, and the log says so
    caplog.clear()
    monkeypatch.setenv("POS_STAFF", "Tom the driver")
    with caplog.at_level("WARNING"):
        assert len(demo_directory()) == 4
    assert "the demo staff signs in" in caplog.text

    # an empty line is no list at all
    caplog.clear()
    monkeypatch.setenv("POS_STAFF", "")
    with caplog.at_level("WARNING"):
        assert len(demo_directory()) == 4
    assert caplog.text == ""


def test_a_staff_list_with_no_manager_or_an_unknown_role_is_said_in_the_log(monkeypatch, caplog):
    monkeypatch.setenv("POS_STAFF", "a:Ann:server:1234,d1:Tom:drivr:4444")
    with caplog.at_level("WARNING"):
        d = demo_directory()
    assert len(d) == 2  # kept as typed: it is the owner's list
    assert "Tom has the role 'drivr'" in caplog.text
    assert "no manager and no owner" in caplog.text
    assert not any(pin in caplog.text for pin in ("1234", "4444"))

    caplog.clear()
    monkeypatch.setenv("POS_STAFF", "o:Mei:owner:1234,d1:Tom:driver:4444")
    with caplog.at_level("WARNING"):
        assert len(demo_directory()) == 2
    assert caplog.text == ""


def test_photo_store_dedupes_caps_and_limits_size():
    store = PhotoStore(keep=2)
    for i in range(3):
        store.put(EventPhoto(f"p{i}", "t1", None, "fire", None, float(i), JPEG))
    assert len(store) == 2 and store.get("p0") is None and store.get("p2")
    assert store.put(EventPhoto("p2", "t1", None, "fire", None, 9.0, JPEG)).taken_at == 2.0
    with pytest.raises(ValueError):
        store.put(EventPhoto("big", "t1", None, "fire", None, 0.0, b"\xff\xd8" + b"\x00" * 300_000))


def test_api_sign_in_and_photos():
    client = TestClient(create_app(staff=directory(lambda: 0.0), photos=PhotoStore()))
    assert client.post("/signin", json={"device": "mac1", "pin": "1111"}).json()["name"] == "Amy"
    assert client.post("/signin", json={"device": "mac1", "pin": "0000"}).status_code == 401
    assert client.post("/signin", json={"device": "mac1"}).status_code == 422
    for _ in range(4):
        client.post("/signin", json={"device": "mac1", "pin": "0000"})
    locked = client.post("/signin", json={"device": "mac1", "pin": "1111"})
    assert locked.status_code == 423 and locked.json()["detail"]["seconds"] == 60

    body = {
        "photo_id": "ph1",
        "device": "mac1",
        "event": "fire",
        "op_id": "op9",
        "staff_id": "s1",
        "jpeg_b64": base64.b64encode(JPEG).decode(),
    }
    assert client.post("/events/photos", json=body).json() == {"photo_id": "ph1", "bytes": len(JPEG)}
    assert client.post("/events/photos", json=body).status_code == 202  # resend is harmless
    got = client.get("/events/photos/ph1")
    assert got.headers["content-type"] == "image/jpeg" and got.content == JPEG
    listed = client.get("/events/photos").json()["photos"]
    assert len(listed) == 1 and listed[0]["event"] == "fire" and listed[0]["op_id"] == "op9"
    assert client.post("/events/photos", json={**body, "jpeg_b64": "not base64!"}).status_code == 422
    assert (
        client.post("/events/photos", json={**body, "jpeg_b64": base64.b64encode(b"PNG...").decode()}).status_code
        == 422
    )
    assert client.get("/events/photos/nope").status_code == 404
