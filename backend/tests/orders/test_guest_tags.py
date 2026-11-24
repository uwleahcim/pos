"""Tags on a guest, and the note written from the guest list (docs/guest-list.md, "Tags and the note").

A manager puts a few words on a guest ("VIP", "Friend of the house") and writes or corrects the one line the
restaurant keeps about them, both from the guest list. The list shows each guest's tags and every tag there
is to offer; the hub keeps who wrote what and when, and nothing else moves by it. Whoever takes that guest's
call or order is shown the tags beside the note (`GET /customers/lookup`); they go on no order and no print.
The host stand sees them too: on the guest's reservation in the book, on their party on the waitlist, and
while their call still rings (`GET /customers/tags`). A manager tags a guest from there as well, one who
never ordered too: the box is handed what it needs by `GET /reports/guests/tags`. A number that carries a
tag and has no visit in the year stands in the list all the same, apart from the guests who ordered
(`tagged`), under the name it was tagged by."""

from __future__ import annotations

import pytest

from pos.customers import NOTE_MAX
from pos.guest_tags import (
    NAME_MAX,
    STANDARD,
    TAG_MAX,
    TAGS_MOST,
    GuestTags,
    clean_name,
    clean_tags,
    offered,
    with_tags,
)
from pos.reservations import Reservations
from pos.waitlist import Waitlist

from ..printing.fake_printer import decode
from .test_day import DSN, Hub
from .test_guests import GTC, LINDA, OMAR, PRIYA, SAM, TESS, a_year, ago, guest, guests, one, order

NOBODY = "7815550199"
"""A number that never ordered."""


def keep(h: Hub, phone: str, headers: dict[str, str] | None = None, **body):
    """What the guest list writes about a guest: the hub's answer as it came."""
    return h.c.put(f"/reports/guests/{phone}", json=body, headers=h.manager() if headers is None else headers)


def kept(h: Hub, phone: str, **body) -> dict:
    answer = keep(h, phone, **body)
    assert answer.status_code == 200, answer.text
    return answer.json()


def counts(report: dict) -> dict[str, int]:
    return {row["tag"]: row["guests"] for row in report["tags"]}


# --- the words themselves ---------------------------------------------------------------------------------


def test_a_guests_tags_are_tidied_each_once_in_the_order_of_the_alphabet():
    assert clean_tags(["  Regular  at\nthe bar ", "VIP", "", "   ", "vip", "Catering"]) == [
        "Catering",
        "Regular at the bar",
        "VIP",
    ]
    assert clean_tags(None) == [] and clean_tags([]) == []
    # a tag somebody carries already, and a standard one, is spelt the way it is known
    assert clean_tags(["vip", "catering CLIENT"], ["Catering client", "VIP"]) == ["Catering client", "VIP"]
    assert clean_tags(["vip"], ["Vip", "VIP"]) == ["Vip"]  # the first of two spellings stands
    assert clean_tags(["x" * TAG_MAX]) == ["x" * TAG_MAX]
    assert clean_tags([f"t{i}" for i in range(TAGS_MOST)]) == [f"t{i}" for i in range(TAGS_MOST)]
    assert (TAG_MAX, TAGS_MOST, STANDARD) == (24, 6, ("VIP", "Friend of the house"))


@pytest.mark.parametrize(
    ("tags", "problem"),
    [
        ("VIP", "list of words"),
        ([1, 2], "list of words"),
        ({"VIP": True}, "list of words"),
        (["x" * (TAG_MAX + 1)], f"{TAG_MAX} letters"),
        ([f"t{i}" for i in range(TAGS_MOST + 1)], f"{TAGS_MOST} tags"),
    ],
)
def test_tags_that_cannot_be_kept_are_refused_with_the_reason(tags, problem):
    with pytest.raises(ValueError, match=problem):
        clean_tags(tags)


def test_every_tag_there_is_to_offer_with_how_many_guests_carry_it():
    carried = {LINDA: ["Catering", "VIP"], OMAR: ["VIP"], PRIYA: ["Bar"], NOBODY: ["Catering", "Old friend"]}
    # the one most guests carry first, then by the alphabet; a standard one is offered before anybody carries it
    assert offered(carried) == [
        {"tag": "Catering", "guests": 2},
        {"tag": "VIP", "guests": 2},
        {"tag": "Bar", "guests": 1},
        {"tag": "Old friend", "guests": 1},
        {"tag": "Friend of the house", "guests": 0},
    ]
    # counted among the guests of a list: a tag only others carry is still one to offer
    assert offered(carried, [LINDA, OMAR, PRIYA]) == [
        {"tag": "VIP", "guests": 2},
        {"tag": "Bar", "guests": 1},
        {"tag": "Catering", "guests": 1},
        {"tag": "Friend of the house", "guests": 0},
        {"tag": "Old friend", "guests": 0},
    ]
    assert offered({}) == [{"tag": "Friend of the house", "guests": 0}, {"tag": "VIP", "guests": 0}]


def test_the_tags_of_a_number_are_kept_with_who_put_them_on_and_when():
    tags = GuestTags()
    assert tags.get(LINDA) is None and tags.all() == {}
    assert tags.put(LINDA, ["VIP"], by="Mike", at_ms=5) == {"tags": ["VIP"], "by": "Mike", "at_ms": 5}
    tags.put(OMAR, ["Bar", "VIP"], by="Mike", at_ms=6)
    tags.put(OMAR, [], by="Olive", at_ms=7)  # taken off: the latest word stands, and who said it
    assert tags.get(LINDA) == {"tags": ["VIP"], "by": "Mike", "at_ms": 5}
    assert tags.get(OMAR) == {"tags": [], "by": "Olive", "at_ms": 7}
    assert tags.all() == {LINDA: ["VIP"]}
    tags.get(LINDA)["tags"].append("x")  # what is handed out is a copy
    tags.all()[LINDA].append("y")
    assert tags.get(LINDA)["tags"] == ["VIP"]


# --- on the guest list ------------------------------------------------------------------------------------


def test_the_list_says_what_a_note_and_the_tags_are_held_to_and_offers_the_standard_tags():
    report = guests(a_year())
    assert (report["note_max"], report["tag_max"], report["tags_most"]) == (NOTE_MAX, TAG_MAX, TAGS_MOST)
    assert report["tags"] == [{"tag": "Friend of the house", "guests": 0}, {"tag": "VIP", "guests": 0}]
    assert all(row["tags"] == [] for row in report["guests"])


def test_a_tag_put_on_a_guest_stands_beside_them_and_is_counted():
    h = a_year()
    assert kept(h, LINDA, tags=["VIP", "Catering client"]) == {
        "phone": LINDA,
        "note": "",
        "note_by": "",
        "note_ms": None,
        "tags": ["Catering client", "VIP"],
        "tags_by": "Mike",
        "tags_ms": h.now,
    }
    kept(h, "+1 (781) 555-0102", tags=["vip"])  # however the number is written; spelt as it is known
    report = guests(h)
    assert guest(report, LINDA)["tags"] == ["Catering client", "VIP"]
    assert guest(report, OMAR)["tags"] == ["VIP"] and guest(report, SAM)["tags"] == []
    assert report["tags"] == [
        {"tag": "VIP", "guests": 2},
        {"tag": "Catering client", "guests": 1},
        {"tag": "Friend of the house", "guests": 0},
    ]
    close = one(h, LINDA)
    assert close["guest"] == {**guest(report, LINDA), "favourites": close["guest"]["favourites"]}
    assert (close["tags_by"], close["tags_ms"]) == ("Mike", h.now)
    assert (one(h, SAM)["tags_by"], one(h, SAM)["tags_ms"]) == ("", None)


def test_a_tag_is_spelt_the_way_the_guests_who_carry_it_spell_it():
    h = a_year()
    kept(h, LINDA, tags=["Catering client"])
    assert kept(h, OMAR, tags=["CATERING CLIENT", "friend of the house"])["tags"] == [
        "Catering client",
        "Friend of the house",
    ]
    assert counts(guests(h)) == {"Catering client": 2, "Friend of the house": 1, "VIP": 0}


def test_a_tag_taken_off_is_gone_and_one_nobody_carries_is_no_longer_offered():
    h = a_year()
    kept(h, LINDA, tags=["Bar", "VIP"])
    h.now += 60_000
    assert kept(h, LINDA, tags=["VIP"])["tags"] == ["VIP"]
    assert counts(guests(h)) == {"VIP": 1, "Friend of the house": 0}
    h.now += 60_000
    off = kept(h, LINDA, tags=[])
    assert (off["tags"], off["tags_by"], off["tags_ms"]) == ([], "Mike", None)
    report = guests(h)
    assert guest(report, LINDA)["tags"] == [] and counts(report) == {"Friend of the house": 0, "VIP": 0}
    assert (one(h, LINDA)["tags_by"], one(h, LINDA)["tags_ms"]) == ("Mike", None)


def test_the_note_is_written_from_the_list_under_the_name_behind_the_pin():
    h = a_year()
    # whatever name the call claims, the note is by whoever opened the list
    answer = keep(h, LINDA, note="  no MSG,\n side  door ", by="Amy")
    assert answer.status_code == 200, answer.text
    assert answer.json() == {
        "phone": LINDA,
        "note": "no MSG, side door",
        "note_by": "Mike",
        "note_ms": h.now,
        "tags": [],
        "tags_by": "",
        "tags_ms": None,
    }
    assert guest(guests(h), LINDA)["note"] == "no MSG, side door"
    close = one(h, LINDA)
    assert (close["guest"]["note"], close["note_by"], close["note_ms"]) == ("no MSG, side door", "Mike", h.now)
    # and the form that takes their call reads the same line
    assert h.c.get("/customers/lookup", params={"phone": LINDA}).json()["note"] == "no MSG, side door"
    assert kept(h, LINDA, note="x" * 300)["note"] == "x" * NOTE_MAX
    assert kept(h, LINDA, note=" ")["note"] == "" and guest(guests(h), LINDA)["note"] == ""


def test_what_is_left_out_stays_and_what_is_as_it_was_keeps_who_wrote_it():
    h = a_year()
    h.c.put(f"/customers/{LINDA}", json={"note": "side door", "by": "Amy"})  # written on the to-go form
    wrote = h.now
    h.now += 60_000
    both = kept(h, LINDA, tags=["VIP"])
    assert (both["note"], both["note_by"], both["note_ms"]) == ("side door", "Amy", wrote)
    tagged = h.now
    h.now += 60_000
    # the screen sends both when one of them changed: the other keeps its writer and its time
    again = kept(h, LINDA, tags=["vip"], note="side door, rings twice")
    assert (again["tags"], again["tags_by"], again["tags_ms"]) == (["VIP"], "Mike", tagged)
    assert (again["note"], again["note_by"], again["note_ms"]) == ("side door, rings twice", "Mike", h.now)
    h.now += 60_000
    same = kept(h, LINDA, tags=["VIP"], note=" side door,  rings twice ")
    assert (same["tags_ms"], same["note_ms"]) == (tagged, h.now - 60_000)
    assert kept(h, LINDA) == same  # nothing sent, nothing changed
    # a note written on the to-go form leaves the tags as they are
    h.c.put(f"/customers/{LINDA}", json={"note": "back door", "by": "Ben"})
    close = one(h, LINDA)
    assert (close["guest"]["note"], close["note_by"]) == ("back door", "Ben")
    assert (close["guest"]["tags"], close["tags_by"], close["tags_ms"]) == (["VIP"], "Mike", tagged)


@pytest.mark.parametrize(
    ("phone", "body", "problem"),
    [
        ("12", {"tags": ["VIP"]}, "not a phone number"),
        ("none", {"note": "x"}, "not a phone number"),
        (LINDA, {"tags": ["x" * (TAG_MAX + 1)], "note": "kept?"}, f"{TAG_MAX} letters"),
        (LINDA, {"tags": [f"t{i}" for i in range(TAGS_MOST + 1)], "note": "kept?"}, f"{TAGS_MOST} tags"),
    ],
)
def test_what_cannot_be_kept_is_refused_whole_with_the_reason(phone, body, problem):
    h = a_year()
    kept(h, LINDA, tags=["VIP"], note="side door")
    answer = keep(h, phone, **body)
    assert answer.status_code == 422, answer.text
    assert answer.json()["detail"]["error"] == "bad_value" and problem in answer.json()["detail"]["message"]
    close = one(h, LINDA)  # the note that came with bad tags is not written either
    assert (close["guest"]["tags"], close["guest"]["note"]) == (["VIP"], "side door")
    assert keep(h, LINDA, tags="VIP").status_code == 422 and keep(h, LINDA, note="x" * 401).status_code == 422


def test_only_who_may_read_the_guest_list_writes_on_it():
    h = a_year()
    assert h.c.put(f"/reports/guests/{LINDA}", json={"tags": ["VIP"]}).status_code == 401
    assert keep(h, LINDA, {"authorization": "Bearer nobody"}, tags=["VIP"]).status_code == 401

    def session(pin: str) -> dict[str, str]:
        answer = h.c.post("/admin/session", json={"device": "t1", "pin": pin})
        assert answer.status_code == 200, answer.text
        return {"authorization": f"Bearer {answer.json()['token']}"}

    # a server handed the reports has a session, and no hand on the guests
    assert h.c.put("/settings/powers", json={"roles": {"reports": ["server"]}}, headers=h.manager()).status_code == 200
    amy = session("1111")
    refused = keep(h, LINDA, amy, tags=["VIP"], note="side door")
    assert refused.status_code == 403 and refused.json()["detail"]["power"] == "guests"
    assert (guest(guests(h), LINDA)["tags"], guest(guests(h), LINDA)["note"]) == ([], "")
    # handed the guest list, they write on it under their own name
    h.c.put("/settings/powers", json={"roles": {"guests": ["server"]}}, headers=h.manager())
    assert keep(h, LINDA, amy, tags=["VIP"]).json()["tags_by"] == "Amy"
    # and it is weighed on every call: taken back, the same session writes no more
    h.c.put("/settings/powers", json={"roles": {"guests": []}}, headers=h.manager())
    assert keep(h, LINDA, amy, tags=[]).status_code == 403
    assert guest(guests(h), LINDA)["tags"] == ["VIP"]


def test_a_number_outside_the_list_can_be_tagged_and_its_tag_is_one_to_offer():
    h = a_year()
    assert kept(h, NOBODY, tags=["Old friend"], note="moved away")["tags"] == ["Old friend"]
    report = guests(h)
    # no visit in the year: not among the guests who ordered, and counted with none of them
    assert all(row["phone"] != NOBODY for row in report["guests"])
    assert counts(report) == {"Friend of the house": 0, "Old friend": 0, "VIP": 0}
    assert [row["phone"] for row in report["tagged"]] == [NOBODY]  # it stands apart, for the tag it carries
    # the next guest given the tag gets it as it is spelt
    assert kept(h, TESS, tags=["old FRIEND"])["tags"] == ["Old friend"]


def test_writing_about_a_guest_moves_no_figure_of_the_list_and_no_sale():
    h = a_year()

    def figures() -> tuple:
        report = guests(h)
        rows = [{k: v for k, v in row.items() if k not in ("tags", "note")} for row in report["guests"]]
        sales = h.c.get("/reports/sales", params={"from": "2026-11-01", "to": "2026-11-16"}, headers=h.manager())
        return report["totals"], rows, sales.json()["span"], h.report()["sales"]

    before = figures()
    kept(h, LINDA, tags=["VIP", "Catering client"], note="no MSG")
    kept(h, OMAR, tags=["VIP"])
    kept(h, OMAR, tags=[])
    assert figures() == before
    assert h.check("l5") == h.check("l5") and "tags" not in h.c.get("/orders/l5").text


# --- where the order is taken ------------------------------------------------------------------------------


def card(h: Hub, phone: str) -> dict:
    """Who the hub says is at this number, as the to-go form and the order screen ask (no token)."""
    answer = h.c.get("/customers/lookup", params={"phone": phone})
    assert answer.status_code == 200, answer.text
    return answer.json()


def test_whoever_takes_the_call_or_the_order_sees_the_guests_tags():
    h = a_year()
    assert card(h, LINDA)["tags"] == [] and card(h, NOBODY)["tags"] == []
    kept(h, LINDA, tags=["VIP", "Catering client"], note="no MSG")
    linda = card(h, "+1 (781) 555-0101")  # a number matches by its digits, however it is typed
    assert linda["tags"] == ["Catering client", "VIP"] and linda["note"] == "no MSG"
    assert linda["known"] and linda["orders"] == 5 and linda["name"] == "Linda P."
    assert card(h, OMAR)["tags"] == []  # a tag is on the number it was put on
    # the card says the words and no more: who put them on is the guest list's to say
    assert "tags_by" not in linda and "tags_ms" not in linda
    # taken off in the guest list, they are gone from the card the next time it is asked
    kept(h, LINDA, tags=[])
    assert card(h, LINDA)["tags"] == [] and card(h, LINDA)["note"] == "no MSG"


def test_a_tag_alone_makes_a_number_known_before_its_first_order():
    h = a_year()
    assert card(h, NOBODY)["known"] is False
    kept(h, NOBODY, tags=["Friend of the house"])
    friend = card(h, NOBODY)
    assert friend["known"] and friend["orders"] == 0 and friend["tags"] == ["Friend of the house"]
    kept(h, NOBODY, tags=[])
    assert card(h, NOBODY)["known"] is False
    assert card(h, "12")["tags"] == []  # a number too short is nobody's


def test_the_note_written_where_the_order_is_taken_leaves_the_tags():
    h = a_year()
    kept(h, LINDA, tags=["VIP"])
    # anyone at a terminal still writes the note on the to-go form; the tags are the guest list's
    assert h.c.put(f"/customers/{LINDA}", json={"note": "side door", "by": "Amy", "tags": []}).status_code == 200
    assert (card(h, LINDA)["tags"], card(h, LINDA)["note"]) == (["VIP"], "side door")
    closely = one(h, LINDA)
    assert (closely["tags_by"], closely["note_by"]) == ("Mike", "Amy")


def test_a_tag_goes_on_no_order_and_on_no_bill():
    h = a_year()
    kept(h, LINDA, tags=["VIP"], note="no MSG")
    order(h, "l6", h.now - 60_000, LINDA, "Linda P.", GTC)
    assert "VIP" not in h.c.get("/orders/l6").text and "VIP" not in str(h.check("l6"))
    printed = h.c.post("/orders/l6/bill", json={})
    assert printed.status_code == 202, printed.text
    words = [line for line in decode(h.printing.store.get(printed.json()["job_id"]).data).text if line.strip()]
    assert any("Linda P." in line for line in words)  # her bill, by her name
    assert not any("VIP" in line or "no MSG" in line for line in words)


# --- at the host stand: the book, the waitlist, the call that rings ------------------------------------------

HOLLY = {"staff_id": "s4"}
"""The host, who keeps the book and the list: no token, as for every change to them."""
MONDAY, SATURDAY = "2026-11-16", "2026-11-21"


def host_stand() -> Hub:
    """The year's guests, on a hub whose book and waitlist go by the test's clock (Monday the 16th, nine in
    the evening)."""
    h = a_year()
    state = h.c.app.state
    state.reservations = Reservations(now_ms=lambda: h.now)
    state.waitlist = Waitlist(now_ms=lambda: h.now)
    return h


def book_table(h: Hub, name: str, phone: str = "", day: str = MONDAY, time: str = "21:30", **more) -> dict:
    """A table booked by the host; the hub's whole answer."""
    body = {**HOLLY, "name": name, "size": 2, "day": day, "time": time, "phone": phone, **more}
    answer = h.c.post("/reservations", json=body)
    assert answer.status_code == 200, answer.text
    return answer.json()


def the_book(h: Hub, day: str | None = None) -> dict:
    answer = h.c.get("/reservations", params={"day": day} if day else None)
    assert answer.status_code == 200, answer.text
    return answer.json()


def wait(h: Hub, name: str, phone: str = "", **more) -> dict:
    """A party put on the waitlist by the host; the hub's whole answer."""
    answer = h.c.post("/waitlist", json={**HOLLY, "name": name, "size": 2, "phone": phone, **more})
    assert answer.status_code == 200, answer.text
    return answer.json()


def the_list(h: Hub) -> dict:
    answer = h.c.get("/waitlist")
    assert answer.status_code == 200, answer.text
    return answer.json()


def tags_of(rows: list[dict]) -> dict[str, list[str]]:
    return {row["name"]: row["tags"] for row in rows}


def ringing(h: Hub, phone: str) -> dict:
    """What a screen asks while this number's call rings (no token)."""
    answer = h.c.get("/customers/tags", params={"phone": phone})
    assert answer.status_code == 200, answer.text
    return answer.json()


def test_rows_are_answered_with_the_tags_their_number_carries():
    carried = {LINDA: ["Catering client", "VIP"], OMAR: ["VIP"]}
    rows = [
        {"name": "Linda", "phone": "+1 (781) 555-0101"},  # by its digits, however it was typed
        {"name": "Omar", "phone": OMAR},
        {"name": "Priya", "phone": PRIYA},  # nobody tagged this number
        {"name": "Walk-in", "phone": ""},
        {"name": "No number kept"},
        {"name": "Short", "phone": "0101"},
    ]
    told = with_tags(rows, carried)
    assert tags_of(told) == {
        "Linda": ["Catering client", "VIP"],
        "Omar": ["VIP"],
        "Priya": [],
        "Walk-in": [],
        "No number kept": [],
        "Short": [],
    }
    assert all("tags" not in row for row in rows)  # the rows handed in are left as they were
    told[0]["tags"].append("mine")
    assert carried[LINDA] == ["Catering client", "VIP"]  # and so is what the numbers carry
    assert with_tags([], carried) == [] and with_tags(rows[:1], {}) == [{**rows[0], "tags": []}]


def test_a_reservation_shows_the_tags_of_its_number_in_the_book():
    h = host_stand()
    kept(h, LINDA, tags=["VIP", "Catering client"])
    made = book_table(h, "Linda P.", "781 555 0101", note="window")
    assert made["booking"]["tags"] == ["Catering client", "VIP"]  # the answer to the booking itself says so
    book_table(h, "Omar", OMAR, time="21:45")
    book_table(h, "Walk-in Wu")  # no number: nothing to look up
    assert tags_of(the_book(h)["booked"]) == {"Linda P.": ["Catering client", "VIP"], "Omar": [], "Walk-in Wu": []}
    # the tags are the number's, not the booking's: put on later, they are there the next time the book is read
    kept(h, OMAR, tags=["Friend of the house"])
    assert tags_of(the_book(h)["booked"])["Omar"] == ["Friend of the house"]
    # a later day's book says them too, and so does a reservation once it ended
    ahead = book_table(h, "Linda P.", LINDA, day=SATURDAY, time="18:00")["booking"]
    assert tags_of(the_book(h, SATURDAY)["booked"]) == {"Linda P.": ["Catering client", "VIP"]}
    off = h.c.post(f"/reservations/{ahead['id']}/cancel", json={**HOLLY, "why": "cancelled"})
    assert off.status_code == 200 and off.json()["booking"]["tags"] == ["Catering client", "VIP"]
    assert tags_of(the_book(h, SATURDAY)["earlier"]) == {"Linda P.": ["Catering client", "VIP"]}
    # taken off in the guest list, they are gone from the book
    kept(h, LINDA, tags=[])
    assert tags_of(the_book(h)["booked"])["Linda P."] == []
    # nothing was kept with the reservation itself, and the floor map's holds are told no tag
    assert all("tags" not in vars(b) for b in h.c.app.state.reservations.store.between(0))
    assert "Friend of the house" not in h.c.get("/floor").text


def test_a_caller_with_a_table_booked_is_answered_with_their_tags_too():
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    book_table(h, "Linda P.", LINDA)
    told = h.c.get("/reservations/caller", params={"phone": "(781) 555-0101"}).json()
    assert [(b["name"], b["tags"]) for b in told["booked"]] == [("Linda P.", ["VIP"])]
    assert h.c.get("/reservations/caller", params={"phone": OMAR}).json()["booked"] == []


def test_a_party_on_the_waitlist_shows_the_tags_of_its_number():
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    put = wait(h, "Linda P.", "781-555-0101", quoted_minutes=20)
    assert put["party"]["tags"] == ["VIP"] and tags_of(put["waiting"]) == {"Linda P.": ["VIP"]}
    wait(h, "Omar", OMAR)
    wait(h, "Family Wu")  # most parties leave no number
    assert tags_of(the_list(h)["waiting"]) == {"Linda P.": ["VIP"], "Omar": [], "Family Wu": []}
    kept(h, OMAR, tags=["Regular at the bar"])
    assert tags_of(the_list(h)["waiting"])["Omar"] == ["Regular at the bar"]
    # a party that went off the list keeps showing them among the earlier ones
    gone = h.c.post(f"/waitlist/{put['party']['id']}/left", json={**HOLLY, "why": "left"})
    assert gone.status_code == 200 and gone.json()["party"]["tags"] == ["VIP"]
    told = the_list(h)
    assert tags_of(told["earlier"]) == {"Linda P.": ["VIP"]} and "Linda P." not in tags_of(told["waiting"])
    # the wait to suggest names nobody, tagged or not
    assert "VIP" not in h.c.get("/waitlist/suggest").text


def test_a_call_that_rings_is_told_the_tags_of_its_number_and_nothing_else():
    h = host_stand()
    kept(h, LINDA, tags=["VIP", "Catering client"], note="no MSG")
    told = ringing(h, "+1 (781) 555-0101")
    assert told == {"phone": LINDA, "tags": ["Catering client", "VIP"]}  # no name, no note, no order
    assert ringing(h, OMAR) == {"phone": OMAR, "tags": []}  # a customer nobody tagged
    assert ringing(h, NOBODY) == {"phone": NOBODY, "tags": []}  # a number that never ordered
    assert ringing(h, "anonymous") == {"phone": "", "tags": []}  # a call with no number
    assert ringing(h, "0101")["tags"] == []  # an extension
    assert h.c.get("/customers/tags").status_code == 422 and h.c.get("/customers/tags?phone=").status_code == 422
    kept(h, LINDA, tags=[])
    assert ringing(h, LINDA)["tags"] == []
    # asking wrote nothing, and the note is still written the way it was
    assert h.c.put(f"/customers/{LINDA}", json={"note": "side door", "by": "Amy"}).status_code == 200
    assert card(h, LINDA)["note"] == "side door"


def test_the_book_and_the_waitlist_are_told_to_read_again_when_a_guests_tags_change():
    h = host_stand()
    said: list[str] = []
    h.c.app.state.feed.changed = said.append
    kept(h, LINDA, tags=["VIP"])
    assert said == ["reservations", "waitlist"]
    # the same tags again, a note alone, and what is refused tell nobody
    kept(h, LINDA, tags=["vip"])
    kept(h, LINDA, note="no MSG")
    assert keep(h, LINDA, tags=["x" * (TAG_MAX + 1)]).status_code == 422
    the_book(h)
    the_list(h)
    ringing(h, LINDA)
    assert said == ["reservations", "waitlist"]
    kept(h, LINDA, tags=[])
    assert said == ["reservations", "waitlist"] * 2


def test_showing_a_guests_tags_at_the_host_stand_changes_no_reservation_no_party_and_no_sale():
    h = host_stand()
    made = book_table(h, "Linda P.", LINDA)["booking"]
    put = wait(h, "Omar", OMAR)["party"]
    before = (guests(h)["totals"], h.report()["sales"])

    def bare(row: dict) -> dict:
        return {key: value for key, value in row.items() if key != "tags"}

    kept(h, LINDA, tags=["VIP"])
    kept(h, OMAR, tags=["VIP"])
    assert bare(the_book(h)["booked"][0]) == bare(made) and bare(the_list(h)["waiting"][0]) == bare(put)
    assert (guests(h)["totals"], h.report()["sales"]) == before


# --- tagging a guest from their reservation or the waitlist -----------------------------------------------


def tag_box(h: Hub, phone: str | None = None, headers: dict[str, str] | None = None):
    """What the box that tags a guest is handed where the guest list was not read: the hub's answer as it
    came."""
    asked = {"phone": phone} if phone is not None else None
    return h.c.get("/reports/guests/tags", params=asked, headers=h.manager() if headers is None else headers)


def test_the_tag_box_is_handed_the_tags_on_offer_and_the_ones_the_number_carries():
    h = host_stand()
    kept(h, LINDA, tags=["VIP", "Catering client"])
    kept(h, OMAR, tags=["VIP"])
    h.now += 60_000
    # with no number: the tags there are, each with how many numbers carry it, and what they are held to
    answer = tag_box(h)
    assert answer.status_code == 200, answer.text
    assert answer.json() == {
        "tags": [
            {"tag": "VIP", "guests": 2},
            {"tag": "Catering client", "guests": 1},
            {"tag": "Friend of the house", "guests": 0},
        ],
        "tag_max": TAG_MAX,
        "tags_most": TAGS_MOST,
        "phone": "",
        "carried": [],
        "tags_by": "",
        "tags_ms": None,
    }
    # with a number, however it is written: what it carries now, who put it on and when
    hers = tag_box(h, "+1 (781) 555-0101").json()
    assert (hers["phone"], hers["carried"], hers["tags_by"]) == (LINDA, ["Catering client", "VIP"], "Mike")
    assert hers["tags_ms"] == h.now - 60_000 and hers["tags"] == answer.json()["tags"]
    # a number nobody tagged, and one that never ordered, carry none and are no error
    assert tag_box(h, SAM).json()["carried"] == [] and tag_box(h, NOBODY).json()["tags_ms"] is None
    # it is no guest of the list called "tags": the list's own calls answer as they did
    assert h.c.get(f"/reports/guests/{LINDA}", headers=h.manager()).json()["guest"]["tags"] == [
        "Catering client",
        "VIP",
    ]
    assert h.c.get(f"/reports/guests/{NOBODY}", headers=h.manager()).status_code == 404


def test_a_guest_who_only_booked_a_table_is_tagged_from_their_reservation():
    h = host_stand()
    book_table(h, "Novak", "781 555 0199")
    wait(h, "Novak", "781-555-0199")
    assert tags_of(the_book(h)["booked"]) == {"Novak": []} and tag_box(h, NOBODY).json()["carried"] == []
    # the box saves with the guest list's own call: the number need not have ordered
    assert kept(h, NOBODY, tags=["vip", "Wine club"])["tags"] == ["VIP", "Wine club"]
    assert tags_of(the_book(h)["booked"]) == {"Novak": ["VIP", "Wine club"]}
    assert tags_of(the_list(h)["waiting"]) == {"Novak": ["VIP", "Wine club"]}
    assert ringing(h, NOBODY)["tags"] == ["VIP", "Wine club"]
    # the next box offers the new tag, counted by the numbers that carry it
    box = tag_box(h, NOBODY).json()
    assert box["carried"] == ["VIP", "Wine club"] and {"tag": "Wine club", "guests": 1} in box["tags"]
    # they are no guest of the list for it (no visit), and the note was not touched
    assert all(row["phone"] != NOBODY for row in guests(h)["guests"])
    assert card(h, NOBODY)["note"] == ""
    # taken off again from the same box
    assert kept(h, NOBODY, tags=[])["tags"] == []
    assert tags_of(the_book(h)["booked"]) == {"Novak": []} and tag_box(h, NOBODY).json()["carried"] == []


def test_only_who_may_read_the_guest_list_is_handed_the_tag_box():
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    assert h.c.get("/reports/guests/tags").status_code == 401
    assert tag_box(h, LINDA, {"authorization": "Bearer nobody"}).status_code == 401
    # a server handed the reports has a session, and no hand on the guests
    assert h.c.put("/settings/powers", json={"roles": {"reports": ["server"]}}, headers=h.manager()).status_code == 200
    opened = h.c.post("/admin/session", json={"device": "t1", "pin": "1111"})
    amy = {"authorization": f"Bearer {opened.json()['token']}"}
    refused = tag_box(h, LINDA, amy)
    assert refused.status_code == 403 and refused.json()["detail"]["power"] == "guests"
    # the host's own PIN opens no session for it either: tagging stays with whoever may read the guest list
    assert h.c.post("/admin/session", json={"device": "t1", "pin": "3333", "power": "guests"}).status_code == 403
    # something that is no phone number is refused, as the write refuses it
    short = tag_box(h, "555")
    assert short.status_code == 422 and short.json()["detail"]["error"] == "bad_value"


def test_handing_out_the_tag_box_reads_no_order_and_changes_nothing(monkeypatch):
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    made = book_table(h, "Linda Chen", LINDA)["booking"]
    before = (guests(h)["totals"], h.report()["sales"], the_book(h), ringing(h, LINDA))

    def no_orders(*_args, **_kwargs):
        raise AssertionError("the tag box read the orders")

    with monkeypatch.context() as patched:
        store = h.c.app.state.store
        for reading in ("with_phone", "index", "views"):
            patched.setattr(store, reading, no_orders)
        for phone in (None, LINDA, NOBODY):
            assert tag_box(h, phone).status_code == 200
    assert (guests(h)["totals"], h.report()["sales"], the_book(h), ringing(h, LINDA)) == before
    assert the_book(h)["booked"][0] == made


# --- a tagged guest with no order, in the guest list ---------------------------------------------------------

ZED = "7815550188"
"""A number whose one order is older than the year the list reads."""


def no_visit(phone: str, name: str, tags: list[str], **more) -> dict:
    """The row of a number that carries a tag and has no visit in the year."""
    return {
        "phone": phone,
        "name": name,
        "note": "",
        "tags": tags,
        "visits": 0,
        "spent": "0.00",
        "per_visit": None,
        "last": None,
        "first": None,
        "since_ms": None,
        "orders_ever": 0,
        "lately": 0,
        "regular": False,
        "lapsed": False,
        "new": False,
        "favourites": [],
        **more,
    }


def test_the_name_a_number_was_tagged_by_is_kept_while_it_carries_a_tag():
    tags = GuestTags()
    assert tags.names() == {}
    # the name comes with the tags, and what is handed back about the tags is as it was
    assert tags.put(NOBODY, ["VIP"], by="Mike", at_ms=5, name="Novak") == {"tags": ["VIP"], "by": "Mike", "at_ms": 5}
    assert tags.get(NOBODY) == {"tags": ["VIP"], "by": "Mike", "at_ms": 5}
    assert tags.names() == {NOBODY: "Novak"}
    tags.put(NOBODY, ["Bar", "VIP"], by="Olive", at_ms=6)  # tags changed with no name said: the name stays
    tags.put(LINDA, ["VIP"], by="Mike", at_ms=6)  # tagged from the guest list: no name comes with it
    assert tags.names() == {NOBODY: "Novak"}
    tags.put(NOBODY, ["VIP"], by="Olive", at_ms=7, name="Novak family")  # called something else the next time
    assert tags.names() == {NOBODY: "Novak family"}
    tags.put(NOBODY, ["VIP"], by="Olive", at_ms=8, name="")  # an empty name is no name said
    assert tags.names() == {NOBODY: "Novak family"}
    # the name alone: who put the tags on, and when, stays
    tags.rename(NOBODY, "Ana Novak")
    tags.rename(LINDA, "Linda")
    tags.rename(OMAR, "Omar")  # carries no tag: nothing is kept about the number
    assert tags.names() == {NOBODY: "Ana Novak", LINDA: "Linda"}
    assert tags.get(NOBODY) == {"tags": ["VIP"], "by": "Olive", "at_ms": 8} and tags.get(OMAR) is None
    # every tag taken off takes the name with it, and a tag put on later does not bring it back
    tags.put(NOBODY, [], by="Mike", at_ms=9)
    assert tags.names() == {LINDA: "Linda"}
    tags.put(NOBODY, ["VIP"], by="Mike", at_ms=10)
    assert tags.names() == {LINDA: "Linda"}
    tags.put(OMAR, [], by="Mike", at_ms=11, name="Omar")  # no tag, so no name
    assert tags.names() == {LINDA: "Linda"}


def test_a_name_is_kept_on_one_line_and_no_longer_than_a_line_of_the_list():
    assert clean_name("  Novak\n  family\t") == "Novak family"
    assert clean_name(None) == "" and clean_name("") == "" and clean_name("   ") == ""
    assert clean_name("x" * (NAME_MAX + 5)) == "x" * NAME_MAX
    assert clean_name("Ana" + " " * NAME_MAX + "Novak") == "Ana Novak"
    assert NAME_MAX == 40


def test_a_tagged_guest_who_never_ordered_stands_in_the_list_apart_from_those_who_did():
    h = a_year()
    before = guests(h)
    assert before["tagged"] == []
    kept(h, NOBODY, tags=["vip", "Wine club"], name="Novak")
    kept(h, LINDA, tags=["VIP"], name="Linda at the door")  # a guest who ordered is where she was
    report = guests(h)
    assert report["tagged"] == [no_visit(NOBODY, "Novak", ["VIP", "Wine club"])]
    assert guest(report, LINDA)["name"] == "Linda P." and guest(report, LINDA)["tags"] == ["VIP"]
    # the guests who ordered, what they came to and how many of them carry each tag are as they were
    assert [row["phone"] for row in report["guests"]] == [row["phone"] for row in before["guests"]]
    assert report["totals"] == before["totals"]
    assert counts(report) == {"VIP": 1, "Friend of the house": 0, "Wine club": 0}
    # the note the restaurant keeps about the number stands beside it, as beside any guest
    kept(h, NOBODY, note="likes the window")
    assert guests(h)["tagged"] == [no_visit(NOBODY, "Novak", ["VIP", "Wine club"], note="likes the window")]


def test_tagged_guests_with_no_order_stand_by_name_and_the_nameless_by_number_after_them():
    h = a_year()
    for phone, name in (("7815550193", "zoe"), ("7815550192", ""), ("7815550191", "Ana"), ("7815550194", "Bo")):
        kept(h, phone, tags=["VIP"], **({"name": name} if name else {}))
    kept(h, "7815550190", tags=["VIP"])
    assert [(row["name"], row["phone"]) for row in guests(h)["tagged"]] == [
        ("Ana", "7815550191"),
        ("Bo", "7815550194"),
        ("zoe", "7815550193"),
        ("", "7815550190"),
        ("", "7815550192"),
    ]


def test_a_guest_of_long_ago_who_carries_a_tag_says_since_when():
    h = a_year()
    order(h, "z1", ago(400), ZED, "Zed", GTC)
    assert all(row["phone"] != ZED for row in guests(h)["guests"]) and guests(h)["tagged"] == []
    kept(h, ZED, tags=["Old friend"], name="Zed")
    assert guests(h)["tagged"] == [no_visit(ZED, "Zed", ["Old friend"], since_ms=ago(400), orders_ever=1)]


def test_a_tagged_guest_with_no_order_is_read_closely_and_their_tags_are_changed_like_any_guests():
    h = a_year()
    assert h.c.get(f"/reports/guests/{NOBODY}", headers=h.manager()).status_code == 404
    kept(h, NOBODY, tags=["VIP"], name="Novak", note="likes the window")
    close = one(h, NOBODY)
    assert close["guest"] == no_visit(NOBODY, "Novak", ["VIP"], note="likes the window")
    assert close["latest"] == []
    assert (close["tags_by"], close["tags_ms"], close["note_by"], close["note_ms"]) == ("Mike", h.now, "Mike", h.now)
    assert (close["first"], close["last"], close["tag_max"]) == ("2025-11-17", "2026-11-16", TAG_MAX)
    # changed from the list, where no name is said: the name they were tagged by stays
    assert kept(h, NOBODY, tags=["VIP", "Wine club"])["tags"] == ["VIP", "Wine club"]
    assert one(h, NOBODY)["guest"]["name"] == "Novak"
    # the last tag taken off: no guest of the list any more, and the name is not kept
    kept(h, NOBODY, tags=[])
    assert guests(h)["tagged"] == [] and h.c.app.state.guest_tags.names() == {}
    answer = h.c.get(f"/reports/guests/{NOBODY}", headers=h.manager())
    assert (answer.status_code, answer.json()["detail"]["error"]) == (404, "no_guest")
    assert card(h, NOBODY)["note"] == "likes the window"  # the note is the number's, tag or none


def test_the_name_comes_with_the_tags_tidied_and_alone_it_leaves_who_tagged():
    h = a_year()
    names = h.c.app.state.guest_tags.names
    kept(h, NOBODY, tags=["VIP"], name="  Novak\n family  ")
    assert names() == {NOBODY: "Novak family"}
    h.now += 60_000
    # the same tags saved under another name: the name is kept, and who put the tags on is as it was
    again = kept(h, NOBODY, tags=["VIP"], name="Ana Novak")
    assert names() == {NOBODY: "Ana Novak"}
    assert (again["tags_by"], again["tags_ms"]) == ("Mike", h.now - 60_000)
    kept(h, NOBODY, name="A. Novak")  # the name alone
    assert names() == {NOBODY: "A. Novak"}
    kept(h, NOBODY, tags=["VIP"], name="x" * 200)
    assert names() == {NOBODY: "x" * NAME_MAX}
    # a name for a number that carries no tag is not kept, and too long a one is refused whole
    kept(h, SAM, name="Sam at the door")
    kept(h, OMAR, tags=[], name="Omar")
    assert names() == {NOBODY: "x" * NAME_MAX}
    assert keep(h, NOBODY, tags=["Bar"], name="x" * 201).status_code == 422
    assert h.c.app.state.guest_tags.get(NOBODY)["tags"] == ["VIP"]
    assert keep(h, NOBODY, tags=["VIP"], name=7).status_code == 422


def test_a_tagged_guests_first_order_puts_them_among_the_guests_who_ordered():
    h = a_year()
    kept(h, NOBODY, tags=["VIP"], name="Novak")
    assert [row["phone"] for row in guests(h)["tagged"]] == [NOBODY]
    order(h, "n1", ago(0, 20), NOBODY, "Ana Novak", GTC)
    report = guests(h)
    assert report["tagged"] == []
    row = guest(report, NOBODY)
    assert (row["name"], row["tags"], row["visits"], row["new"]) == ("Ana Novak", ["VIP"], 1, True)
    assert counts(report)["VIP"] == 1


def test_listing_tagged_guests_changes_no_order_and_no_figure():
    h = a_year()

    def figures() -> tuple:
        report = guests(h)
        sales = h.c.get("/reports/sales", params={"from": "2026-11-01", "to": "2026-11-16"}, headers=h.manager())
        return report["totals"], report["guests"], sales.json()["span"], h.report()["sales"]

    before = figures()
    kept(h, NOBODY, tags=["VIP"], name="Novak")
    one(h, NOBODY)
    assert figures() == before


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_tags_are_kept_in_postgresql_the_same_way():
    import psycopg

    from pos.guest_tags import PgGuestTags

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS guest_tag")
    tags = PgGuestTags(DSN)
    try:
        assert tags.get(LINDA) is None and tags.all() == {}
        assert tags.put(LINDA, ["VIP"], by="Mike", at_ms=5) == {"tags": ["VIP"], "by": "Mike", "at_ms": 5}
        tags.put(LINDA, ["Bar", "VIP"], by="Olive", at_ms=6)  # the latest word stands
        tags.put(OMAR, ["VIP"], by="Mike", at_ms=7)
        tags.put(OMAR, [], by="Mike", at_ms=8)  # taken off
        assert tags.get(LINDA) == {"tags": ["Bar", "VIP"], "by": "Olive", "at_ms": 6}
        assert tags.get(OMAR) == {"tags": [], "by": "Mike", "at_ms": 8}
        assert tags.all() == {LINDA: ["Bar", "VIP"]}
    finally:
        tags.close()
    again = PgGuestTags(DSN)  # after a restart
    try:
        assert again.get(LINDA)["tags"] == ["Bar", "VIP"] and again.all() == {LINDA: ["Bar", "VIP"]}
    finally:
        again.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS guest_tag")


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_name_is_kept_in_postgresql_the_same_way_and_a_table_of_before_gets_its_column():
    import psycopg

    from pos.guest_tags import PgGuestTags

    with psycopg.connect(DSN) as conn:
        # the table as the hubs before this had it, with a guest tagged then
        conn.execute("DROP TABLE IF EXISTS guest_tag")
        conn.execute(
            "CREATE TABLE guest_tag (phone TEXT PRIMARY KEY, tags JSONB NOT NULL DEFAULT '[]'::jsonb, "
            "updated_by TEXT NOT NULL DEFAULT '', updated_ms BIGINT NOT NULL DEFAULT 0)"
        )
        conn.execute(
            "INSERT INTO guest_tag (phone, tags, updated_by, updated_ms) VALUES (%s, '[\"VIP\"]', 'Mike', 3)", (LINDA,)
        )
    tags = PgGuestTags(DSN)
    try:
        assert tags.names() == {} and tags.all() == {LINDA: ["VIP"]}
        assert tags.put(NOBODY, ["VIP"], by="Mike", at_ms=5, name="Novak") == {
            "tags": ["VIP"],
            "by": "Mike",
            "at_ms": 5,
        }
        tags.put(NOBODY, ["Bar", "VIP"], by="Olive", at_ms=6)  # no name said: the name stays
        tags.put(NOBODY, ["Bar", "VIP"], by="Olive", at_ms=6, name="")
        assert tags.names() == {NOBODY: "Novak"}
        tags.put(NOBODY, ["VIP"], by="Olive", at_ms=7, name="  Novak\n family ")
        assert tags.names() == {NOBODY: "Novak family"}
        tags.rename(NOBODY, "Ana Novak")
        tags.rename(LINDA, "Linda")
        tags.rename(OMAR, "Omar")  # carries no tag: nothing is kept about the number
        assert tags.names() == {NOBODY: "Ana Novak", LINDA: "Linda"}
        assert tags.get(NOBODY) == {"tags": ["VIP"], "by": "Olive", "at_ms": 7} and tags.get(OMAR) is None
        assert tags.get(LINDA) == {"tags": ["VIP"], "by": "Mike", "at_ms": 3}
        tags.put(LINDA, [], by="Mike", at_ms=8)  # every tag taken off takes the name with it
        tags.put(LINDA, ["VIP"], by="Mike", at_ms=9)
        tags.put(OMAR, [], by="Mike", at_ms=9, name="Omar")  # no tag, so no name
        assert tags.names() == {NOBODY: "Ana Novak"}
    finally:
        tags.close()
    again = PgGuestTags(DSN)  # after a restart
    try:
        assert again.names() == {NOBODY: "Ana Novak"}
        # a database that lost the column under a running hub (one that took over from an older one): what
        # is read is no name, and the next write puts the column back
        with psycopg.connect(DSN) as conn:
            conn.execute("ALTER TABLE guest_tag DROP COLUMN name")
        assert again.names() == {} and again.all() == {LINDA: ["VIP"], NOBODY: ["VIP"]}
        again.rename(NOBODY, "Novak")
        assert again.names() == {NOBODY: "Novak"}
        with psycopg.connect(DSN) as conn:
            conn.execute("ALTER TABLE guest_tag DROP COLUMN name")
        again.put(LINDA, ["VIP"], by="Mike", at_ms=10, name="Linda")
        assert again.names() == {LINDA: "Linda"}
    finally:
        again.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS guest_tag")
