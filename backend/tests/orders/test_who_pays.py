"""Who pays a check: a tap on the check says which of its guests the money counts for
(docs/guest-list.md, "Who pays").

Every guest of a check has the visit, and the check's money counts for one of them. A check with one guest
needs no word. Where several guests sit on a check and no number is typed on it, the money waited for a
number to be typed. Now whoever serves the table says it with a tap on the party's name: the hub keeps the
word beside who sat on the check (`pos.check_guests`), and the guest list counts the check's money for that
guest. One guest pays a check; the word is the last one said, and it wins over a number typed on the check.
Nothing is written on any check, no money is taken by it, and no screen is told a number."""

from __future__ import annotations

from decimal import Decimal

import pytest

from pos.api.guests import note_seated
from pos.check_guests import CheckGuests, PgCheckGuests, guest_of
from pos.orders.guests import payer_of
from pos.reservations import Reservations
from pos.waitlist import Waitlist

from .test_check_guests import NOVAK, check, latest, put_together, tally, type_number
from .test_day import DSN, EGGROLL, WINGS, Hub
from .test_guest_tags import HOLLY, book_table, host_stand, kept, seat, wait
from .test_guests import GTC, LINDA, OMAR, PRIYA, guests, one


def who_sits(h: Hub, order_id: str) -> dict:
    """The hub's whole answer about who sits on a check, as the screen with it open asks (no token)."""
    answer = h.c.get(f"/orders/{order_id}/seated")
    assert answer.status_code == 200, answer.text
    return answer.json()


def paying(h: Hub, order_id: str) -> list[str]:
    """The names of the parties on this check that somebody said pay it."""
    return [party["name"] for party in who_sits(h, order_id)["parties"] if party["pays"]]


def say(h: Hub, order_id: str, party: str, pays: bool = True, staff_id: str = "s1"):
    """Whoever serves the table says that this party pays (or takes it back): the hub's answer as it came."""
    return h.c.post(f"/orders/{order_id}/payer", json={"staff_id": staff_id, "party": party, "pays": pays})


def said(h: Hub, order_id: str, party: str, pays: bool = True) -> dict:
    answer = say(h, order_id, party, pays)
    assert answer.status_code == 200, answer.text
    return answer.json()


def two_at(h: Hub, order_id: str = "t-1", table: str = "A7") -> tuple[Decimal, str, str]:
    """Linda (from her reservation) and the Novaks (from the waitlist) on one check: what it comes to, and
    what the hub knows each party by."""
    net = check(h, order_id, table, GTC, EGGROLL)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], order_id, table=table)
    h.now += 60_000
    seat(h, wait(h, "Novak", NOVAK)["party"], order_id, table=table, book="waitlist")
    linda, novak = who_sits(h, order_id)["parties"]
    return net, linda["key"], novak["key"]


# --- the word ---------------------------------------------------------------------------------------------------


def test_a_tap_says_which_guest_pays_and_the_checks_money_counts_for_that_guest():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    was = guests(h)["totals"]
    net, linda, novak = two_at(h)
    # two guests and no word: both came in and ordered, and the money is nobody's yet
    assert tally(h, LINDA) == (visits + 1, paid, spent) and tally(h, NOVAK) == (1, 0, Decimal(0))
    assert paying(h, "t-1") == []
    # the Novaks pay
    told = said(h, "t-1", novak)
    assert [(party["name"], party["pays"]) for party in told["parties"]] == [("Linda P.", False), ("Novak", True)]
    assert told == who_sits(h, "t-1")  # the answer is the check's guests as they stand now
    assert tally(h, NOVAK) == (1, 1, net) and latest(h, NOVAK) == {"order_id": "t-1", "net": net, "paid": True}
    assert tally(h, LINDA) == (visits + 1, paid, spent)
    assert latest(h, LINDA) == {"order_id": "t-1", "net": Decimal(0), "paid": False}
    now = guests(h)["totals"]
    assert (now["visits"], now["paid"]) == (was["visits"] + 2, was["paid"] + 1)
    assert Decimal(now["spent"]) == Decimal(was["spent"]) + net  # the check once
    # no, Linda does: one guest pays a check, so the word moves
    said(h, "t-1", linda)
    assert paying(h, "t-1") == ["Linda P."]
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + net) and tally(h, NOVAK) == (1, 0, Decimal(0))
    assert Decimal(guests(h)["totals"]["spent"]) == Decimal(was["spent"]) + net
    # said again changes nothing
    said(h, "t-1", linda)
    assert paying(h, "t-1") == ["Linda P."] and tally(h, LINDA) == (visits + 1, paid + 1, spent + net)
    # taken back: nobody again
    said(h, "t-1", linda, pays=False)
    assert paying(h, "t-1") == []
    assert tally(h, LINDA) == (visits + 1, paid, spent) and tally(h, NOVAK) == (1, 0, Decimal(0))
    # taking back the word of a party that does not pay leaves the one that does
    said(h, "t-1", novak)
    said(h, "t-1", linda, pays=False)
    assert paying(h, "t-1") == ["Novak"]


def test_the_word_wins_over_a_number_typed_on_the_check_and_without_it_the_number_pays():
    h = host_stand()
    linda_was, priya_was = tally(h, LINDA), tally(h, PRIYA)
    net, linda, _ = two_at(h)
    type_number(h, "t-1", PRIYA, "Priya")  # somebody typed a third guest's number on the check
    assert tally(h, PRIYA) == (priya_was[0] + 1, priya_was[1] + 1, priya_was[2] + net)  # as before the tap
    said(h, "t-1", linda)
    assert tally(h, LINDA) == (linda_was[0] + 1, linda_was[1] + 1, linda_was[2] + net)
    assert tally(h, PRIYA) == (priya_was[0] + 1, priya_was[1], priya_was[2])  # she has the visit still
    said(h, "t-1", linda, pays=False)
    assert tally(h, PRIYA) == (priya_was[0] + 1, priya_was[1] + 1, priya_was[2] + net)
    assert payer_of("typed", ["typed", "a", "b"], "b") == "b"
    assert payer_of("typed", ["typed", "a", "b"]) == "typed"
    assert payer_of("", ["a", "b"], "a") == "a"
    assert payer_of("", ["a", "b"], "gone") == ""  # a word about somebody who is no guest of the check
    assert payer_of("", ["a"], "") == "a" and payer_of("", ["a", "b"]) == "" and payer_of("", []) == ""


def test_the_check_is_told_who_can_pay_and_who_does_and_never_a_number():
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    _, linda, novak = two_at(h)
    h.now += 60_000
    seat(h, book_table(h, "Wu", time="21:45")["booking"], "t-1")  # left no number
    said(h, "t-1", novak)
    told = who_sits(h, "t-1")
    assert told["payer"] is True  # this hub takes the word
    assert [(party["name"], party["listed"], party["pays"]) for party in told["parties"]] == [
        ("Linda P.", True, False),
        ("Novak", True, True),
        ("Wu", False, False),
    ]
    assert told["parties"][0] == {
        "from": "reservation",
        "name": "Linda P.",
        "size": 2,
        "note": "",
        "tags": ["VIP"],
        "key": linda,
        "listed": True,
        "pays": False,
    }
    assert len({party["key"] for party in told["parties"]}) == 3
    words = h.c.get("/orders/t-1/seated").text + say(h, "t-1", linda).text
    assert not any(phone in words for phone in (LINDA, NOVAK, "555"))
    # a check nobody was seated on says so as before, and that the hub takes the word
    assert who_sits(h, "t-9") == {"order_id": "t-9", "parties": [], "tags": [], "payer": True}


def test_who_says_it_and_what_cannot_be_said():
    h = host_stand()
    _, linda, novak = two_at(h)
    wu = seat(h, book_table(h, "Wu", time="21:45")["booking"], "t-1")["booking"]
    other = wait(h, "Omar", OMAR)["party"]
    check(h, "t-2", "B5", WINGS)
    seat(h, other, "t-2", table="B5", book="waitlist")
    # somebody the hub knows says it: a server, the host, a manager alike
    assert say(h, "t-1", linda, staff_id="s1").status_code == 200
    assert say(h, "t-1", linda, staff_id=HOLLY["staff_id"]).status_code == 200
    nobody = say(h, "t-1", novak, staff_id="s99")
    assert nobody.status_code == 404 and nobody.json()["detail"]["error"] == "unknown_staff"
    # a party that left no number cannot be the one: it is no guest of the list
    none = say(h, "t-1", f"reservation:{wu['id']}")
    assert none.status_code == 409 and none.json()["detail"]["error"] == "no_number"
    assert "Wu" in none.json()["detail"]["message"]
    # a party of another check, a party nobody knows, and nonsense
    for party in (f"waitlist:{other['id']}", "waitlist:no-such", "check:t-1", "nonsense", ""):
        gone = say(h, "t-1", party)
        assert gone.status_code == 404 and gone.json()["detail"]["error"] == "unknown_party", party
    assert paying(h, "t-1") == ["Linda P."]  # none of it moved the word
    assert paying(h, "t-2") == []


# --- what the word follows --------------------------------------------------------------------------------------


def test_the_word_stays_through_the_host_stands_changes_and_a_hub_that_starts_again():
    h = host_stand()
    net, linda, _ = two_at(h)
    said(h, "t-1", linda)
    counted = tally(h, LINDA)
    booking = next(row for row in h.c.get("/reservations").json()["earlier"] if row["name"] == "Linda P.")
    # the host tags her from the book, another party joins, the hub is updated: she pays still
    kept(h, LINDA, tags=["VIP"])
    seat(h, wait(h, "Omar", OMAR)["party"], "t-1", book="waitlist")
    seat(h, booking, "t-1")  # seated again on the check she sits on
    note_seated(h.c.app.state)
    assert paying(h, "t-1") == ["Linda P."] and tally(h, LINDA) == counted
    assert latest(h, LINDA) == {"order_id": "t-1", "net": net, "paid": True}


def test_a_party_put_back_takes_its_word_along_and_seated_elsewhere_has_none():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    net, linda, novak = two_at(h)
    said(h, "t-1", linda)
    booking = next(row for row in h.c.get("/reservations").json()["earlier"] if row["name"] == "Linda P.")
    assert h.c.post(f"/reservations/{booking['id']}/back", json=HOLLY).status_code == 200
    # she sits on no check: the Novaks are its only guest, and pay it without a word
    assert tally(h, LINDA) == (visits, paid, spent) and tally(h, NOVAK) == (1, 1, net)
    assert say(h, "t-1", linda).status_code == 404
    # seated at another table: a guest of that check, and nobody said that she pays the first one
    b5 = check(h, "t-2", "B5", WINGS)
    seat(h, booking, "t-2", table="B5")
    assert paying(h, "t-1") == [] and paying(h, "t-2") == []
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + b5)  # its only guest
    # put back once more and seated at the first table again: the word is not remembered from before
    assert h.c.post(f"/reservations/{booking['id']}/back", json=HOLLY).status_code == 200
    seat(h, booking, "t-1")
    assert paying(h, "t-1") == [] and tally(h, LINDA) == (visits + 1, paid, spent)
    assert novak in {party["key"] for party in who_sits(h, "t-1")["parties"]}


def test_two_tables_put_together_keep_the_word_of_the_check_that_is_kept():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    a7 = check(h, "t-1", "A7", GTC, EGGROLL)
    b5 = check(h, "t-2", "B5", WINGS)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    for name, phone, order_id, table in (("Novak", NOVAK, "t-1", "A7"), ("Omar", OMAR, "t-2", "B5")):
        h.now += 60_000
        seat(h, wait(h, name, phone)["party"], order_id, table=table, book="waitlist")
    h.now += 60_000
    seat(h, wait(h, "Priya", PRIYA)["party"], "t-2", table="B5", book="waitlist")
    linda = who_sits(h, "t-1")["parties"][0]["key"]
    omar = who_sits(h, "t-2")["parties"][0]["key"]
    said(h, "t-1", linda)
    said(h, "t-2", omar)
    omar_was = tally(h, OMAR)
    assert omar_was[1:] == (tally(h, OMAR)[1], tally(h, OMAR)[2])
    # A7 is put onto B5: B5's check is kept, and its word stands. One guest pays a check.
    put_together(h, "t-1", "t-2", lines=2)
    assert paying(h, "t-2") == ["Omar"] and paying(h, "t-1") == []
    assert [party["name"] for party in who_sits(h, "t-2")["parties"]] == ["Linda P.", "Novak", "Omar", "Priya"]
    assert tally(h, OMAR) == (omar_was[0], omar_was[1], omar_was[2] + a7)  # the whole joined check
    assert tally(h, LINDA) == (visits + 1, paid, spent)
    # and it can be said anew on the joined check
    said(h, "t-2", linda)
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + a7 + b5)


def test_a_table_put_onto_one_where_nobody_was_said_to_pay_waits_for_the_word():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    a7 = check(h, "t-1", "A7", GTC, EGGROLL)
    b5 = check(h, "t-2", "B5", WINGS)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    h.now += 60_000
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-1", book="waitlist")
    h.now += 60_000
    seat(h, wait(h, "Omar", OMAR)["party"], "t-2", table="B5", book="waitlist")
    said(h, "t-1", who_sits(h, "t-1")["parties"][0]["key"])
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + a7)
    put_together(h, "t-1", "t-2", lines=2)
    # who pays A7 was said of A7's check; the joined check is another question
    assert paying(h, "t-2") == []
    assert tally(h, LINDA) == (visits + 1, paid, spent)
    one_visit = one(h, LINDA)["latest"][0]
    assert (one_visit["order_id"], one_visit["paid"], one_visit["waits"]) == ("t-2", False, True)
    said(h, "t-2", who_sits(h, "t-2")["parties"][0]["key"])
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + a7 + b5)


# --- what it does not touch --------------------------------------------------------------------------------------


def test_saying_who_pays_writes_nothing_on_a_check_and_changes_no_sale():
    h = host_stand()
    _, linda, novak = two_at(h)
    figures = (h.report()["sales"], h.check("t-1"), h.c.get("/orders/t-1").json(), len(h.store))
    said(h, "t-1", linda)
    said(h, "t-1", novak)
    said(h, "t-1", novak, pays=False)
    assert (h.report()["sales"], h.check("t-1"), h.c.get("/orders/t-1").json(), len(h.store)) == figures
    assert h.c.get("/floor").json()["seated"]["t-1"] == [
        {"name": "Linda P.", "tags": []},
        {"name": "Novak", "tags": []},
    ]  # the floor map is told what it was told


def test_a_visit_says_whether_its_money_waits_for_the_word_or_another_guest_paid():
    h = host_stand()
    net, linda, _ = two_at(h)

    def last(phone: str) -> tuple[str, bool, bool]:
        visit = one(h, phone)["latest"][0]
        return visit["net"], visit["paid"], visit["waits"]

    assert last(LINDA) == ("0.00", False, True) and last(NOVAK) == ("0.00", False, True)
    said(h, "t-1", linda)
    assert last(LINDA) == (str(net), True, False) and last(NOVAK) == ("0.00", False, False)
    # an order of her own never waited
    older = one(h, LINDA)["latest"][1]
    assert (older["paid"], older["waits"]) == (True, False)


# --- the store ---------------------------------------------------------------------------------------------------


def the_same_way(store: CheckGuests) -> None:
    linda = guest_of("reservation", "b1", "t-1", LINDA, "Linda P.", 1_000)
    novak = guest_of("waitlist", "p1", "t-1", NOVAK, "Novak", 2_000)
    omar = guest_of("waitlist", "p2", "t-2", OMAR, "Omar", 3_000)
    for guest in (linda, novak, omar):
        store.put(guest)
    assert [guest.pays for guest in store.on(["t-1", "t-2"])] == [False, False, False]
    # the word, and who said it
    marked = store.pay("waitlist", "p1", True, by="Amy")
    assert marked is not None and (marked.pays, marked.pays_by, marked.order_id) == (True, "Amy", "t-1")
    assert [(guest.name, guest.pays) for guest in store.on(["t-1"])] == [("Linda P.", False), ("Novak", True)]
    # one guest pays a check: the word moves, and only on that check
    store.pay("waitlist", "p2", True, by="Amy")
    store.pay("reservation", "b1", True, by="Ben")
    assert [(guest.name, guest.pays, guest.pays_by) for guest in store.on(["t-1", "t-2"])] == [
        ("Linda P.", True, "Ben"),
        ("Novak", False, ""),
        ("Omar", True, "Amy"),
    ]
    assert store.pay("reservation", "no-such", True, by="Amy") is None
    # noted afresh on the same check (the host changed the party): the word stays
    store.put(guest_of("reservation", "b1", "t-1", LINDA, "Linda Papas", 1_000))
    assert [(guest.name, guest.pays, guest.pays_by) for guest in store.on(["t-1"])][0] == ("Linda Papas", True, "Ben")
    # noted on another check: it does not
    store.put(guest_of("reservation", "b1", "t-3", LINDA, "Linda Papas", 4_000))
    assert [(guest.order_id, guest.pays) for guest in store.of_phone(LINDA)] == [("t-3", False)]
    # taken back
    store.pay("waitlist", "p2", False, by="Ben")
    assert [guest.pays for guest in store.on(["t-2"])] == [False]
    # a check merged into another: its guests go over without their word, and the kept check's stands
    store.pay("waitlist", "p2", True, by="Amy")
    store.pay("waitlist", "p1", True, by="Amy")
    assert store.follow("t-1", "t-2") == 1
    assert [(guest.name, guest.pays) for guest in store.on(["t-2"])] == [("Novak", False), ("Omar", True)]


def test_the_store_keeps_the_word_in_memory():
    the_same_way(CheckGuests())


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_store_keeps_the_word_in_postgres_and_a_table_from_before_it_learns_to():
    import psycopg

    # the table as the hub made it before a word about who pays was kept, with a guest in it
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS check_guest")
        conn.execute(
            """
            CREATE TABLE check_guest (
                source TEXT NOT NULL, source_id TEXT NOT NULL, order_id TEXT NOT NULL, phone TEXT NOT NULL,
                name TEXT NOT NULL DEFAULT '', at_ms BIGINT NOT NULL, PRIMARY KEY (source, source_id)
            )
            """
        )
        conn.execute("INSERT INTO check_guest VALUES ('waitlist', 'old', 't-0', %s, 'Priya', 500)", (PRIYA,))
    store = PgCheckGuests(DSN)
    try:
        before = store.of_phone(PRIYA)
        assert [(guest.order_id, guest.pays, guest.pays_by) for guest in before] == [("t-0", False, "")]
        the_same_way(store)
        again = PgCheckGuests(DSN)  # the hub starts again: the word is there
        try:
            assert [(guest.name, guest.pays) for guest in again.on(["t-2"])] == [("Novak", False), ("Omar", True)]
        finally:
            again.close()
    finally:
        store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS check_guest")


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_word_counts_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders, check_guest")
    h = Hub(postgres=DSN)
    kept_guests = PgCheckGuests(DSN)
    try:
        from .test_guests import a_year

        a_year(h)
        state = h.c.app.state
        state.reservations = Reservations(now_ms=lambda: h.now)
        state.waitlist = Waitlist(now_ms=lambda: h.now)
        state.check_guests = kept_guests
        visits, paid, spent = tally(h, LINDA)
        net, linda, _ = two_at(h)
        assert tally(h, LINDA) == (visits + 1, paid, spent)
        said(h, "t-1", linda)
        assert tally(h, LINDA) == (visits + 1, paid + 1, spent + net) and tally(h, NOVAK) == (1, 0, Decimal(0))
        assert paying(h, "t-1") == ["Linda P."]
    finally:
        kept_guests.close()
        h.store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS ops, orders, check_guest")
