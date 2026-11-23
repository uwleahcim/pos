"""Tags on a guest, and the note written from the guest list (docs/guest-list.md, "Tags and the note").

A manager puts a few words on a guest ("VIP", "Friend of the house") and writes or corrects the one line the
restaurant keeps about them, both from the guest list. The list shows each guest's tags and every tag there
is to offer; the hub keeps who wrote what and when, and nothing else moves by it. Whoever takes that guest's
call or order is shown the tags beside the note (`GET /customers/lookup`); they go on no order and no print."""

from __future__ import annotations

import pytest

from pos.customers import NOTE_MAX
from pos.guest_tags import STANDARD, TAG_MAX, TAGS_MOST, GuestTags, clean_tags, offered

from ..printing.fake_printer import decode
from .test_day import DSN, Hub
from .test_guests import GTC, LINDA, OMAR, PRIYA, SAM, TESS, a_year, guest, guests, one, order

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
    assert all(row["phone"] != NOBODY for row in report["guests"])  # no visit in the year: not a guest of the list
    assert counts(report) == {"Friend of the house": 0, "Old friend": 0, "VIP": 0}
    assert h.c.get(f"/reports/guests/{NOBODY}", headers=h.manager()).status_code == 404
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
