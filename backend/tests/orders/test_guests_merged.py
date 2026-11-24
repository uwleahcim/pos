"""Two tables put together: the guests go with their check (docs/guest-list.md, "When two tables are put
together").

A party the host seated from its reservation or the waitlist is known by the check it sat down on. When that
check is merged into another table's (docs/moves.md), its dishes go over and it is closed with nothing on it,
saying where they went. From then on the party sits on the check that was kept: its strip, its table on the
floor map and its row in the list of checks say whose it is. The hub notes that in the book or on the
waitlist, where seating the party wrote which check it was; nothing goes onto any check."""

from __future__ import annotations

from pos.api.guests import follow_merges, kept_check
from pos.reservations import Reservations
from pos.waitlist import Waitlist

from ..printing.fake_printer import decode
from .test_day import Hub
from .test_guest_tags import (
    HOLLY,
    at_table,
    book_table,
    host_stand,
    in_the_list,
    kept,
    on_the_map,
    seat,
    seated_at,
    the_book,
    the_list,
    wait,
)
from .test_guests import GTC, LINDA, OMAR, guests


def merge(h: Hub, emptied: str, onto: str) -> None:
    """One check takes another's dishes, as a screen says it: the emptied one is closed, saying where they
    went. (The dishes themselves go over one by one before that; nothing here reads them.)"""
    h.now += 1_000
    h.op(emptied, "set_field", h.now, merged_into=onto, by="Holly", by_id="s4")
    h.op(emptied, "close", h.now + 1)


def names(h: Hub, order_id: str) -> list[str]:
    return [party["name"] for party in seated_at(h, order_id)["parties"]]


def two_tables(h: Hub) -> None:
    h.table("t-1", h.now - 60_000, table="A7")
    h.table("t-2", h.now - 60_000, table="B5")


def test_a_party_goes_with_its_check_when_two_tables_are_put_together():
    h = host_stand()
    kept(h, LINDA, tags=["VIP", "Catering client"])
    linda = book_table(h, "Linda P.", "+1 (781) 555-0101", note="Window table, birthday")["booking"]
    two_tables(h)  # hers, and a walk-in's
    seat(h, linda, "t-1")
    assert (names(h, "t-1"), names(h, "t-2")) == (["Linda P."], [])
    merge(h, "t-1", "t-2")
    # the check that was kept says whose it is, with her tags and the note of her reservation
    assert seated_at(h, "t-2") == {
        "order_id": "t-2",
        "parties": [
            {
                "from": "reservation",
                "name": "Linda P.",
                "size": 2,
                "note": "Window table, birthday",
                "tags": ["Catering client", "VIP"],
            }
        ],
        "tags": ["Catering client", "VIP"],
    }
    assert at_table(h, "t-2")["tags"] == ["Catering client", "VIP"]
    # so do its table on the floor map and its row in the list of checks
    assert on_the_map(h) == {"t-2": [{"name": "Linda P.", "tags": ["Catering client", "VIP"]}]}
    assert in_the_list(h)["t-2"]["seated"] == ["Linda P."]
    # and the emptied check, closed, says nobody
    assert seated_at(h, "t-1") == {"order_id": "t-1", "parties": [], "tags": []}
    assert "seated" not in in_the_list(h, status="closed", hours="24")["t-1"]


def test_the_check_that_is_kept_names_the_parties_of_both_tables_in_the_order_they_sat():
    h = host_stand()
    kept(h, OMAR, tags=["Regular"])
    two_tables(h)
    seat(h, wait(h, "Omar", OMAR)["party"], "t-2", table="B5", book="waitlist")
    h.now += 60_000
    seat(h, book_table(h, "Wu", "", note="High chair")["booking"], "t-1")
    h.now += 60_000
    seat(h, wait(h, "Tess")["party"], "t-1", book="waitlist")  # joined the Wus
    merge(h, "t-1", "t-2")
    assert names(h, "t-2") == ["Omar", "Wu", "Tess"]
    assert seated_at(h, "t-2")["parties"][1]["note"] == "High chair"
    assert on_the_map(h) == {
        "t-2": [{"name": "Omar", "tags": ["Regular"]}, {"name": "Wu", "tags": []}, {"name": "Tess", "tags": []}]
    }
    assert in_the_list(h)["t-2"]["seated"] == ["Omar", "Wu", "Tess"]


def test_a_party_follows_through_every_merge_whichever_way_round_the_hub_hears_of_them():
    h = host_stand()
    two_tables(h)
    h.table("t-3", h.now - 60_000, table="C1")
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    # one after the other: A7 onto B5, then B5 onto C1
    merge(h, "t-1", "t-2")
    assert names(h, "t-2") == ["Linda P."]
    merge(h, "t-2", "t-3")
    assert (names(h, "t-1"), names(h, "t-2"), names(h, "t-3")) == ([], [], ["Linda P."])

    # the later merge heard of first (a screen that was offline sends the earlier one afterwards)
    h = host_stand()
    two_tables(h)
    h.table("t-3", h.now - 60_000, table="C1")
    seat(h, wait(h, "Omar", OMAR)["party"], "t-1", book="waitlist")
    merge(h, "t-2", "t-3")
    assert names(h, "t-1") == ["Omar"]  # his check went nowhere yet
    merge(h, "t-1", "t-2")
    assert (names(h, "t-1"), names(h, "t-2"), names(h, "t-3")) == ([], [], ["Omar"])


def test_where_a_merged_check_went_is_read_from_the_log():
    h = host_stand()
    two_tables(h)
    store = h.c.app.state.store
    assert kept_check(store, "t-1") is None  # merged into nothing
    assert kept_check(store, "t-9") is None  # no such check
    h.op("t-1", "set_field", h.now, merged_into="t-2")
    assert kept_check(store, "t-1") == "t-2"
    h.op("t-2", "set_field", h.now + 1, merged_into="t-1")  # a ring cannot be followed to an end
    assert kept_check(store, "t-1") is None and kept_check(store, "t-2") is None


def test_a_party_stays_where_it_is_when_its_check_went_somewhere_the_hub_never_heard_of():
    h = host_stand()
    two_tables(h)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    said: list[str] = []
    h.c.app.state.feed.changed = said.append
    merge(h, "t-1", "t-9")
    assert names(h, "t-1") == ["Linda P."] and said == []
    # a check with nobody seated on it moves nobody, and neither does a field that is not a merge
    merge(h, "t-2", "t-1")
    h.op("t-1", "set_field", h.now + 5, guests=4)
    assert names(h, "t-1") == ["Linda P."] and said == []


def test_the_screens_are_told_to_read_again_when_a_party_went_over_and_only_then():
    h = host_stand()
    two_tables(h)
    h.table("t-3", h.now - 60_000, table="C1")
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    seat(h, wait(h, "Omar", OMAR)["party"], "t-1", book="waitlist")
    seat(h, wait(h, "Tess")["party"], "t-2", table="B5", book="waitlist")
    said: list[str] = []
    h.c.app.state.feed.changed = said.append
    merge(h, "t-1", "t-3")  # a reservation's party and one of the waitlist
    assert said == ["reservations", "waitlist"]
    merge(h, "t-2", "t-3")  # a party of the waitlist alone
    assert said == ["reservations", "waitlist", "waitlist"]
    assert names(h, "t-3") == ["Linda P.", "Omar", "Tess"]
    # the same merge told again changes nothing and tells nobody
    assert follow_merges(h.c.app.state, []) == []
    h.op("t-1", "set_field", h.now + 10, merged_into="t-3")
    assert said == ["reservations", "waitlist", "waitlist"]


def test_put_back_after_the_tables_were_put_together_takes_the_party_off_the_kept_check():
    h = host_stand()
    two_tables(h)
    linda = book_table(h, "Linda P.", LINDA)["booking"]
    omar = wait(h, "Omar", OMAR)["party"]
    seat(h, linda, "t-1")
    seat(h, omar, "t-1", book="waitlist")
    merge(h, "t-1", "t-2")
    assert names(h, "t-2") == ["Linda P.", "Omar"]
    assert h.c.post(f"/reservations/{linda['id']}/back", json=HOLLY).status_code == 200
    assert names(h, "t-2") == ["Omar"]
    assert h.c.post(f"/waitlist/{omar['id']}/back", json=HOLLY).status_code == 200
    assert names(h, "t-2") == [] and on_the_map(h) == {}


def test_following_a_merge_writes_which_check_the_party_sits_on_and_nothing_else():
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    made = book_table(h, "Linda P.", LINDA, note="Window table")["booking"]
    omar = wait(h, "Omar", OMAR)["party"]
    two_tables(h)
    h.ring("t-2", "L1", GTC, h.now - 30_000)
    sat = seat(h, made, "t-1")["booking"]
    waited = seat(h, omar, "t-1", book="waitlist")["party"]
    figures = (guests(h)["totals"], h.report()["sales"], h.check("t-2"))
    merge(h, "t-1", "t-2")
    # in the book and on the list: the check, and not the table they first sat down at
    now = the_book(h)["earlier"][0]
    assert now == {**sat, "tags": ["VIP"], "order_id": "t-2"} and now["seated_table"] == "A7"
    listed = next(party for party in the_list(h)["earlier"] if party["id"] == waited["id"])
    assert listed["order_id"] == "t-2" and {**listed, "order_id": "t-1"} == {**waited, "tags": listed["tags"]}
    # no figure moved, and the kept check carries nothing of either guest; its bill prints none of it
    assert (guests(h)["totals"], h.report()["sales"], h.check("t-2")) == figures
    for words in (h.c.get("/orders/t-2").text, h.c.get("/orders/t-1").text, str(h.check("t-2"))):
        assert not any(word in words for word in ("Linda", "Omar", "VIP", "Window", LINDA, OMAR))
    printed = h.c.post("/orders/t-2/bill", json={})
    assert printed.status_code == 202, printed.text
    lines = [line for line in decode(h.printing.store.get(printed.json()["job_id"]).data).text if line.strip()]
    assert lines and not any("Linda" in line or "Omar" in line or "VIP" in line for line in lines)


def test_a_book_that_cannot_be_written_does_not_stop_the_merge():
    h = host_stand()
    two_tables(h)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")

    def broken(*_args, **_kwargs):
        raise RuntimeError("the book is away")

    h.c.app.state.reservations.follow = broken
    merge(h, "t-1", "t-2")  # the hub took both operations (`Hub.op` asserts it)
    old = h.c.get("/orders/t-1").json()
    assert old["status"] == "closed" and old["fields"]["merged_into"] == "t-2"
    assert names(h, "t-1") == ["Linda P."]  # she is where she was, on a check that is closed


def test_only_the_parties_of_that_check_go_over_and_one_put_back_stays_in_the_book():
    now = 1_700_000_000_000
    book = Reservations(now_ms=lambda: now)
    day = book.today().isoformat()
    chen = book.add("Chen", 2, day, "23:00", by_id="s4", by="Holly")
    wu = book.add("Wu", 4, day, "23:15", by_id="s4", by="Holly")
    lee = book.add("Lee", 2, day, "23:30", by_id="s4", by="Holly")
    book.seat(chen.booking_id, "A7", order_id="t-1")
    book.seat(wu.booking_id, "B5", order_id="t-2")
    book.seat(lee.booking_id, "A7", order_id="t-1")
    book.back(lee.booking_id)
    assert [b.name for b in book.follow("t-1", "t-3")] == ["Chen"]
    assert [(b.name, b.order_id) for b in book.seated()] == [("Chen", "t-3"), ("Wu", "t-2")]
    assert book.follow("t-1", "t-3") == [] and book.follow("", "t-3") == [] and book.follow("t-2", "t-2") == []

    line = Waitlist(now_ms=lambda: now)
    omar = line.add("Omar", 2, by_id="s4", by="Holly")
    tess = line.add("Tess", 3, by_id="s4", by="Holly")
    line.seat(omar.party_id, "A7", order_id="t-1")
    line.seat(tess.party_id, "B5", order_id="t-2")
    assert [p.name for p in line.follow("t-1", "t-3")] == ["Omar"]
    assert sorted((p.name, p.order_id) for p in line.seated()) == [("Omar", "t-3"), ("Tess", "t-2")]
    assert line.follow("t-1", "t-3") == [] and line.follow("t-2", "") == []
