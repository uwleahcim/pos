"""A table booked on the website, read for the reservation book (pos.online.book): what is copied, what is
tidied to fit the book, and what cannot be booked and why."""

from __future__ import annotations

import pytest

from pos.online.book import RESERVATION_TYPES, booking_id_for, wanted
from pos.online.place import CannotPlace, NotAnOrder
from pos.reservations import NOTE_MAX
from pos.waitlist import MOST_GUESTS, NAME_MAX

from .hub import MINUTE, NOW
from .orders import reservation, row

HALF_PAST_SEVEN = NOW + 89 * MINUTE  # 19:30 on the evening of `NOW`, which is 18:01
LUNCH = ("Sweet & Sour Chicken", 2)


def test_a_table_reservation_is_read_as_a_name_a_size_a_time_a_number_and_a_note():
    told = reservation(401, 4, instructions="  A high chair,\nplease ")
    want = wanted(told, now_ms=NOW)
    assert (want.booking_id, want.ext_id) == ("gf-401", "401") and want.booking_id == booking_id_for("401")
    assert (want.name, want.size, want.at_ms) == ("Pat Example", 4, HALF_PAST_SEVEN)
    assert (want.phone, want.note) == ("+1 781 555 0142", "A high chair, please")
    assert (want.said, want.late) == ("", False)


def test_only_what_the_book_needs_is_read():
    want = wanted(reservation(401), now_ms=NOW)
    kept = " ".join(str(value) for value in vars(want).values())
    for private in ("pat@example.com", "not-a-real-key", "not-a-real-token", "True"):
        assert private not in kept


def test_the_two_kinds_of_booked_table_are_reservations_and_nothing_else_is():
    assert RESERVATION_TYPES == ("table_reservation", "order_ahead")
    for kind in ("pickup", "delivery", "dine_in"):
        with pytest.raises(NotAnOrder):
            wanted(reservation(401, kind=kind), now_ms=NOW)


def test_a_table_booked_with_its_dishes_ordered_ahead_says_so_in_the_book_and_to_a_person():
    told = reservation(401, 6, kind="order_ahead", rows=[row(*LUNCH)], instructions="Window table")
    want = wanted(told, now_ms=NOW)
    assert want.note == "Ordered ahead: dishes in GloriaFood. Window table"
    assert want.said == (
        "its dishes were ordered ahead and are not on the POS: they are in GloriaFood's app, to ring in when "
        "the party sits"
    )
    assert (want.size, want.late) == (6, False)


@pytest.mark.parametrize(
    ("first", "last", "name"),
    [
        ("Pat", "Example", "Pat Example"),
        ("  Pat ", None, "Pat"),
        (None, "Example", "Example"),
        ("Christopher", "Montgomery-Smith", "Montgomery-Smith"),  # too long for a name a host calls out
        ("Maximiliana", "Featherstonehaugh-Cholmondeley", "Maximiliana"),
        ("Bartholomew-Maximilian-Augustus", "Featherstonehaugh-Cholmondeley", "Bartholomew-Maximilian-A"),
        (None, None, "Online guest"),
        ("", "\n", "Online guest"),
    ],
)
def test_the_name_is_made_to_fit_what_a_host_calls_out(first, last, name):
    want = wanted(reservation(401, client_first_name=first, client_last_name=last), now_ms=NOW)
    assert want.name == name and len(want.name) <= NAME_MAX


def test_a_note_longer_than_the_book_takes_is_cut_and_shows_it():
    long = "We are celebrating my mother's eightieth birthday and one of us uses a wheelchair, a quiet table"
    want = wanted(reservation(401, instructions=long), now_ms=NOW)
    assert len(want.note) == NOTE_MAX and want.note.endswith("…") and long.startswith(want.note[:-1])
    assert want.said == ""  # the whole of it is in GloriaFood's app: nothing for a person to do
    ahead = wanted(reservation(402, kind="order_ahead", instructions=long), now_ms=NOW)
    assert len(ahead.note) == NOTE_MAX and ahead.note.startswith("Ordered ahead: dishes in GloriaFood. We are")


@pytest.mark.parametrize(
    "phone", ["call the office", "12", "+1 781 555 0142 extension 4 after six", "781-555-0142 x12"]
)
def test_a_number_the_book_does_not_take_is_left_out_and_said(phone):
    want = wanted(reservation(401, client_phone=phone), now_ms=NOW)
    assert want.phone == ""
    assert want.said == "its phone number is not one the book takes and was left out: it is in GloriaFood's app"


def test_a_reservation_without_a_number_is_booked_without_one():
    want = wanted(reservation(401, client_phone=None), now_ms=NOW)
    assert (want.phone, want.said) == ("", "")


@pytest.mark.parametrize(
    ("guests", "why"),
    [
        (0, "it does not say how many they are"),
        (None, "it does not say how many they are"),
        ("many", "it does not say how many they are"),
        (True, "it does not say how many they are"),
        (-2, "it does not say how many they are"),
        (MOST_GUESTS + 1, f"it is for {MOST_GUESTS + 1} guests, and the book takes {MOST_GUESTS} at most"),
    ],
)
def test_a_reservation_that_does_not_say_for_how_many_cannot_be_booked(guests, why):
    with pytest.raises(CannotPlace) as failed:
        wanted(reservation(401, guests), now_ms=NOW)
    assert failed.value.reason == why


def test_how_many_they_are_is_read_as_a_number_however_it_is_written():
    assert wanted(reservation(401, "5"), now_ms=NOW).size == 5
    assert wanted(reservation(401, 5.0), now_ms=NOW).size == 5
    assert wanted(reservation(401, MOST_GUESTS), now_ms=NOW).size == MOST_GUESTS


@pytest.mark.parametrize("at", [None, "", "tomorrow at seven", "2027-01-16T00:30:00"])
def test_a_reservation_that_names_no_time_cannot_be_booked(at):
    with pytest.raises(CannotPlace) as failed:
        wanted(reservation(401, at=at), now_ms=NOW)
    assert failed.value.reason == "it names no time"


def test_the_time_is_the_minute_the_table_is_for():
    want = wanted(reservation(401, at="2027-01-16T00:30:41.250Z"), now_ms=NOW)
    assert want.at_ms == HALF_PAST_SEVEN


def test_a_reservation_for_a_day_that_is_over_is_not_booked_and_is_no_failure():
    # for Thursday evening, and the hub hears of it on Friday
    with pytest.raises(NotAnOrder) as kept:
        wanted(reservation(401, at="2027-01-15T00:30:00.000Z"), now_ms=NOW)
    assert kept.value.reason == "it was for Jan 14, a day that is over: it was not put in the book"
    assert not kept.value.old  # no slip: there is nothing left to do about it


def test_the_small_hours_belong_to_the_evening_before():
    # half past midnight on Saturday is Friday's service: still today at one in the morning
    small_hours = reservation(401, at="2027-01-16T05:30:00.000Z")
    assert wanted(small_hours, now_ms=NOW).late is False
    assert wanted(small_hours, now_ms=NOW + 380 * MINUTE).late is False  # 00:21, before its time
    after = wanted(small_hours, now_ms=NOW + 7 * 60 * MINUTE)  # 01:01: past its time, and its day is not over
    assert after.late and after.said == "it reached the hub after its time (00:30)"


def test_a_reservation_of_today_that_reaches_the_hub_after_its_time_is_booked_and_said_to_be_late():
    told = reservation(401)  # for 19:30
    assert wanted(told, now_ms=HALF_PAST_SEVEN + 15 * MINUTE).late is False
    want = wanted(told, now_ms=HALF_PAST_SEVEN + 16 * MINUTE)
    assert want.late and want.said == "it reached the hub after its time (19:30)"


@pytest.mark.parametrize(
    ("change", "why"),
    [
        ({"status": "rejected"}, "it was rejected in GloriaFood's app"),
        ({"status": "canceled"}, "it was cancelled in GloriaFood"),
        ({"id": None}, "it has no number"),
    ],
)
def test_what_was_not_accepted_or_has_no_number_is_kept_with_why(change, why):
    with pytest.raises(NotAnOrder) as kept:
        wanted({**reservation(401), **change}, now_ms=NOW)
    assert kept.value.reason == why
