"""The caller's order (the thread "Open the caller's order when answering a call"): when a terminal picks up
a call it asks the hub for the last order the number opened today and opens it; with none it starts a new
phone order."""

from __future__ import annotations

from datetime import timedelta

from fastapi.testclient import TestClient

from pos import localtime
from pos.orders.callers import phone_digits

from ..conftest import T0
from .test_counter import DAY, HOUR, client, payload, takeout

MINUTE = 60_000  # the store refuses a stamp more than five minutes ahead of its clock, so orders sit in the past


def test_numbers_match_by_their_digits_without_the_country_code():
    assert phone_digits("+1 (781) 555-1234") == "7815551234"
    assert phone_digits("781 555 1234") == "7815551234"
    assert phone_digits("17815551234") == "7815551234"
    assert phone_digits("+44 20 7946 0958") == "442079460958"  # not a North American number: kept whole
    assert phone_digits(None) == ""
    assert phone_digits("Unknown") == ""


def test_the_day_is_the_locations_not_the_hubs(monkeypatch):
    monkeypatch.setenv("POS_TIMEZONE", "America/New_York")
    assert str(localtime.day_of(T0)) == "2027-01-15"  # 08:00 UTC, 03:00 in Massachusetts
    assert str(localtime.day_of(T0 - 4 * HOUR)) == "2027-01-14"  # 04:00 UTC the same day, 23:00 the day before
    monkeypatch.setenv("POS_TIMEZONE", "UTC")
    assert str(localtime.day_of(T0 - 4 * HOUR)) == "2027-01-15"


def last(c: TestClient, phone: str) -> str | None:
    answer = c.get("/orders/last", params={"phone": phone}).json()
    assert answer["day"] == DAY.isoformat()
    return None if answer["order"] is None else answer["order"]["order_id"]


def test_the_last_order_the_number_opened_today_is_the_one_opened_last():
    c = client()
    takeout(c, "o1", -2 * HOUR, channel="phone", phone="781 555 1234")
    takeout(c, "o2", -HOUR, channel="phone", phone="(781) 555-1234")
    # o1 is touched after o2 was opened (marked ready): o2 is still the last order placed
    c.post("/orders/o1/ops", json=[payload("o1-r", "set_field", -30 * MINUTE, "o1", stage="ready")])
    assert last(c, "+17815551234") == "o2"
    assert last(c, "17815551234") == "o2"
    assert last(c, "781-555-1234") == "o2"
    assert last(c, "781 555 9999") is None


def test_only_today_counts_and_a_voided_order_does_not():
    c = client()
    takeout(c, "old", -24 * HOUR, channel="phone", phone="781 555 1234")  # yesterday's order
    assert last(c, "7815551234") is None
    takeout(c, "o1", -2 * HOUR, channel="phone", phone="781 555 1234")
    takeout(c, "o2", -HOUR, channel="phone", phone="781 555 1234")
    c.post("/orders/o2/ops", json=[payload("o2-v", "void_order", -20 * MINUTE, "o2")])
    assert last(c, "7815551234") == "o1"
    # a closed order still counts: the customer may be calling about the order they picked up
    c.post("/orders/o1/ops", json=[payload("o1-c", "close", -10 * MINUTE, "o1")])
    assert last(c, "7815551234") == "o1"


def test_a_number_the_hub_cannot_read_opens_nothing():
    c = client()
    c.post("/orders/t1/ops", json=[payload("t1-a", "create", 0, "t1", table="5", guests=2, order_type="dine_in")])
    assert last(c, "Anonymous") is None
    assert c.get("/orders/last").status_code == 422
    assert c.get("/orders/last", params={"phone": ""}).status_code == 422


def test_the_day_rolls_over_with_the_location(monkeypatch):
    monkeypatch.setenv("POS_TIMEZONE", "America/New_York")
    late = T0 + 14 * HOUR  # 22:00 UTC: 17:00 in Massachusetts, still the 15th
    c = client(today=lambda: localtime.day_of(late))
    takeout(c, "o1", 0, channel="phone", phone="781 555 1234")  # opened 03:00 local, the same local day
    answer = c.get("/orders/last", params={"phone": "7815551234"}).json()
    assert (answer["day"], answer["order"]["order_id"]) == ("2027-01-15", "o1")
    assert localtime.day_of(late) + timedelta(days=1) == localtime.day_of(late + 7 * HOUR)  # 00:00 local next day
