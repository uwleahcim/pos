"""What Shipday answers, read into what the hub tells a screen (`pos.shipday.read`): the names its pages
give, the odd values their own examples carry, and nothing guessed where a value is missing."""

from __future__ import annotations

import pytest

from pos.shipday.read import UNKNOWN, driver_of, minutes_of, moment, order_of, state_of, tracking_id

from .fake import ELM, TOM, at, carrier, minutes_away, order


def test_an_order_is_read_with_its_customer_its_driver_its_times_and_its_money():
    raw = order(
        7001,
        "1270166229",
        state="PICKED_UP",
        driver=TOM,
        placed=at(18),
        assigned=at(18, 5),
        started=at(18, 10),
        picked_up=at(18, 20),
        wanted=at(18, 45),
        tracked="dGNrPTcwMDE",
    )
    read = order_of(raw)
    assert read == {
        "id": 7001,
        "number": "1270166229",
        "state": "PICKED_UP",
        "name": "Linda Chen",
        "address": ELM,
        "phone": "+17815550101",
        "driver": TOM,
        "placed_ms": at(18),
        "due_ms": at(18, 45),
        "assigned_ms": at(18, 5),
        "started_ms": at(18, 10),
        "picked_up_ms": at(18, 20),
        "arrived_ms": None,
        "delivered_ms": None,
        "eta_ms": None,
        "eta_said": "",
        "total": "42.75",
        "fee": "4.00",
        "tip": "5.00",
        "payment": "CREDIT_CARD",
        "items": 3,
        "note": "Side door",
        "tracking": "https://dispatch.shipday.com/trackingPage/dGNrPTcwMDE&lang=en",
        "scheduled": False,
    }


def test_what_the_pages_own_examples_leave_empty_reads_as_nothing():
    # the example on Shipday's page: no driver, a null id for one, no dishes, an empty time of arrival
    raw = order(7002, "88", eta="")
    raw.update({"assignedCarrierId": None, "orderItems": None, "costing": None, "trackingLink": None})
    read = order_of(raw)
    assert read is not None
    assert (read["driver"], read["items"], read["total"], read["tracking"], read["eta_ms"]) == (None, 0, None, "", None)
    # the words beside that example say -1 for no driver
    raw["assignedCarrierId"] = -1
    assert order_of(raw)["driver"] is None


def test_a_driver_named_only_by_id_is_kept_for_the_list_of_drivers_to_name():
    raw = order(7003, "89", state="NOT_ACCEPTED")
    raw["assignedCarrierId"] = 501
    assert order_of(raw)["driver"] == {"id": 501, "name": "", "phone": ""}


def test_something_without_shipday_s_own_id_is_no_order():
    raw = order(7004, "90")
    del raw["orderId"]
    assert order_of(raw) is None
    assert order_of({}) is None


@pytest.mark.parametrize(
    ("status", "state"),
    [
        ({"orderState": "STARTED"}, "STARTED"),
        ({"orderState": "already_delivered"}, "ALREADY_DELIVERED"),
        ("PICKED_UP", "PICKED_UP"),  # the query's flat word, should an order ever carry it so
        ({"orderState": "ACTIVE"}, UNKNOWN),  # a word for asking with, never where one order stands
        ({"orderState": "SOMETHING_NEW"}, UNKNOWN),
        ({}, UNKNOWN),
        (None, UNKNOWN),
    ],
)
def test_where_an_order_stands_is_shipday_s_own_word_or_unknown(status, state):
    assert state_of({"orderStatus": status}) == state


def test_a_time_without_a_zone_is_utc_and_counts_of_seconds_and_milliseconds_are_read_too():
    assert moment("2026-11-16T23:00:00") == at(18)
    assert moment("2026-11-16T23:00:00Z") == at(18)
    assert moment("2026-11-16T18:00:00-05:00") == at(18)
    assert moment(at(18)) == at(18)
    assert moment(at(18) // 1000) == at(18)
    assert moment(str(at(18))) == at(18)
    for nothing in ("", "   ", None, "soon", 0, -5, 12, True, float("nan")):
        assert moment(nothing) is None


def test_when_it_arrives_is_a_moment_where_it_reads_as_one_and_shipday_s_words_otherwise():
    assert order_of(order(1, "a", eta="2026-11-16T23:25:00"))["eta_ms"] == at(18, 25)
    assert order_of(order(1, "a", eta=at(18, 25)))["eta_ms"] == at(18, 25)
    # a time of day says no day and no zone: handed on as written
    told = order_of(order(1, "a", eta="18:25"))
    assert (told["eta_ms"], told["eta_said"]) == (None, "18:25")
    told = order_of(order(1, "a", eta="12 min"))
    assert (told["eta_ms"], told["eta_said"]) == (None, "12 min")
    assert len(order_of(order(1, "a", eta="x" * 500))["eta_said"]) == 30


def test_the_time_it_is_wanted_for_needs_both_its_day_and_its_time():
    raw = order(1, "a", wanted=at(19, 30))
    assert order_of(raw)["due_ms"] == at(19, 30)
    raw["activityLog"]["expectedDeliveryTime"] = "00:30"  # hh:mm, as one page says
    raw["activityLog"]["expectedDeliveryDate"] = "2026-11-17"
    assert order_of(raw)["due_ms"] == at(19, 30)
    raw["activityLog"]["expectedDeliveryDate"] = None
    assert order_of(raw)["due_ms"] is None
    raw["activityLog"] = None
    assert order_of(raw)["due_ms"] is None and order_of(raw)["placed_ms"] is None


def test_what_a_customer_wrote_is_one_line_of_a_bounded_length():
    raw = order(1, "a", name="Linda\n\x07Chen " + "x" * 300)
    raw["deliveryInstruction"] = "ring\ttwice\r\nthen wait " + "y" * 500
    read = order_of(raw)
    assert read["name"].startswith("Linda Chen xxx") and len(read["name"]) == 80
    assert read["note"].startswith("ring twice then wait") and len(read["note"]) == 200


def test_a_tracking_link_that_is_no_https_address_is_not_handed_on():
    raw = order(1, "a")
    for link in ("javascript:alert(1)", "http://dispatch.shipday.com/t/abc", 17, ""):
        raw["trackingLink"] = link
        assert order_of(raw)["tracking"] == ""


def test_a_driver_is_read_with_whether_they_are_on_shift_and_never_with_where_they_are():
    read = driver_of(carrier(TOM, on_shift=True))
    assert read == {**TOM, "on_shift": True, "active": True}
    assert driver_of(carrier(TOM, on_shift=False, active=False)) == {**TOM, "on_shift": False, "active": False}
    assert driver_of({"name": "nobody"}) is None
    # a driver without a name goes by their code name
    assert driver_of({**carrier(TOM), "name": "", "codeName": "T-7"})["name"] == "T-7"


def test_minutes_away_are_read_where_shipday_has_a_figure_and_are_none_where_it_has_not():
    assert minutes_of(minutes_away(12)) == 12
    assert minutes_of(minutes_away(11.2)) == 12, "rounded up: better early than late"
    assert minutes_of(minutes_away("INF")) is None
    only_text = minutes_away(9)
    only_text["dynamicData"]["detailEta"] = None
    assert minutes_of(only_text) == 9
    for nothing in ({}, {"dynamicData": None}, {"dynamicData": {"estimatedTimeInMinutes": "soon"}}):
        assert minutes_of(nothing) is None
    assert minutes_of(minutes_away(100_000)) is None, "no drive takes ten weeks"


def test_the_tracking_page_s_id_is_read_off_the_customer_s_link():
    assert tracking_id("https://dispatch.shipday.com/trackingPage/dGNrPTcwMDE&lang=en") == "dGNrPTcwMDE"
    assert tracking_id("https://dispatch.shipday.com/trackingPage/dGNrPTcwMDE") == "dGNrPTcwMDE"
    assert tracking_id("https://example.com/track?lang=en&trackingId=abc123XYZ") == "abc123XYZ"
    assert tracking_id("https://dispatch.shipday.com/") is None
    assert tracking_id("") is None
