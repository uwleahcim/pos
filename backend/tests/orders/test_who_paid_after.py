"""Who paid a check, said afterwards from the guest list (docs/guest-list.md, "Who paid, said afterwards").

A tap on the check says which of its guests pays it. On a busy night nobody taps, and the check of two
parties waits: its money counts for nobody, and once the party is put off the book or the waitlist forgot
it the check cannot be told any more. So the guest list says how many checks wait, lists them with their
guests, and whoever may read the list says who paid: of the guests the hub noted on the check
(`pos.check_guests`), so it can be said for as long as the list reads the visit. The number typed on a
check is one of its guests there too, and so is the number of a check that was merged in. Nothing is
written on any check, no money is taken by it, and it stays behind the manager's PIN."""

from __future__ import annotations

import logging
from dataclasses import replace
from decimal import Decimal

import pytest

from pos.check_guests import PgCheckGuests, guest_of
from pos.orders.guests import TYPED, Visit, paid_by
from pos.reservations import Reservations
from pos.waitlist import Waitlist

from .test_check_guests import NOVAK, a_visit, check, put_together, sat, tally, type_number
from .test_day import DSN, WINGS, Hub
from .test_guest_tags import book_table, host_stand, seat, wait
from .test_guests import GTC, LINDA, OMAR, PRIYA, guests, one
from .test_who_pays import paying, said, say, two_at


def waiting(h: Hub) -> list[dict]:
    """The checks that wait for who paid, as the guest list lists them."""
    answer = h.c.get("/reports/guests/payers", headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()["checks"]


def the_check(h: Hub, order_id: str) -> dict:
    """One check with its guests, as whoever says who paid it is shown it."""
    answer = h.c.get(f"/reports/guests/payers/{order_id}", headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def say_after(h: Hub, order_id: str, guest: str, pays: bool = True, headers: dict | None = None):
    """A manager says from the guest list that this guest paid (or takes it back): the answer as it came."""
    headers = h.manager() if headers is None else headers
    return h.c.post(f"/reports/guests/payers/{order_id}", json={"guest": guest, "pays": pays}, headers=headers)


def said_after(h: Hub, order_id: str, guest: str, pays: bool = True) -> dict:
    answer = say_after(h, order_id, guest, pays)
    assert answer.status_code == 200, answer.text
    return answer.json()


def who(row: dict) -> list[tuple[str, bool]]:
    return [(guest["name"], guest["pays"]) for guest in row["guests"]]


def forget(h: Hub) -> None:
    """Thirty days on for the book, the next night for the waitlist: neither knows the parties any more."""
    state = h.c.app.state
    state.reservations = Reservations(now_ms=lambda: h.now)
    state.waitlist = Waitlist(now_ms=lambda: h.now)


# --- the checks that wait -------------------------------------------------------------------------------------


def test_the_guest_list_says_how_many_checks_wait_and_lists_them_with_their_guests():
    h = host_stand()
    assert guests(h)["waiting"] == {"checks": 0, "net": "0.00"} and waiting(h) == []
    opened = h.now - 60_000
    net, linda, novak = two_at(h)
    # a table of one party, a table with a number typed on it and a walk-in's: none of them waits
    check(h, "t-2", "B5", WINGS)
    seat(h, wait(h, "Omar", OMAR)["party"], "t-2", table="B5", book="waitlist")
    check(h, "t-3", "C1", GTC)
    seat(h, book_table(h, "Sam", "7815550144", time="21:45")["booking"], "t-3", table="C1")
    seat(h, wait(h, "Priya", PRIYA)["party"], "t-3", table="C1", book="waitlist")
    type_number(h, "t-3", PRIYA, "Priya")
    check(h, "t-4", "C2", GTC)
    assert guests(h)["waiting"] == {"checks": 1, "net": str(net)}
    assert waiting(h) == [
        {
            "order_id": "t-1",
            "order_no": None,
            "table": "A7",
            "day": "2026-11-16",
            "opened_ms": opened,
            "kind": "dine_in",
            "net": str(net),
            "guests": [
                {"key": linda, "name": "Linda P.", "phone": LINDA, "typed": False, "pays": False},
                {"key": novak, "name": "Novak", "phone": NOVAK, "typed": False, "pays": False},
            ],
            "waits": True,
            "said_by": "",
        }
    ]
    # a second table that waits stands before it: the newest first
    h.now += 5 * 60_000
    two_at(h, "t-5", "D1")
    assert [row["order_id"] for row in waiting(h)] == ["t-5", "t-1"]
    assert guests(h)["waiting"]["checks"] == 2


def test_a_manager_says_who_paid_from_the_list_and_the_money_counts_for_that_guest():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    net, linda, novak = two_at(h)
    told = said_after(h, "t-1", novak)
    assert who(told) == [("Linda P.", False), ("Novak", True)]
    assert (told["waits"], told["said_by"]) == (False, "Mike")  # the name behind the PIN
    assert told == the_check(h, "t-1")
    assert tally(h, NOVAK) == (1, 1, net) and tally(h, LINDA) == (visits + 1, paid, spent)
    assert guests(h)["waiting"] == {"checks": 0, "net": "0.00"} and waiting(h) == []
    # it is the same word a tap on the check says: the check with the table open shows it
    assert paying(h, "t-1") == ["Novak"]
    # one guest pays a check: said of Linda, the word moves
    assert who(said_after(h, "t-1", linda)) == [("Linda P.", True), ("Novak", False)]
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + net) and tally(h, NOVAK) == (1, 0, Decimal(0))
    # taken back: it waits again, and taking back somebody who does not pay moves nothing
    assert said_after(h, "t-1", linda, pays=False)["waits"] is True
    assert [row["order_id"] for row in waiting(h)] == ["t-1"] and paying(h, "t-1") == []
    said_after(h, "t-1", novak)
    assert who(said_after(h, "t-1", linda, pays=False)) == [("Linda P.", False), ("Novak", True)]


def test_a_tap_on_the_check_takes_the_check_off_the_list_and_says_who_said_it():
    h = host_stand()
    _, linda, _ = two_at(h)
    said(h, "t-1", linda)  # Amy taps the name on the check
    assert waiting(h) == [] and guests(h)["waiting"]["checks"] == 0
    told = the_check(h, "t-1")
    assert who(told) == [("Linda P.", True), ("Novak", False)] and told["said_by"] == "Amy"


def test_it_can_be_said_when_the_book_and_the_waitlist_have_forgotten_the_party():
    h = host_stand()
    net, linda, novak = two_at(h)
    forget(h)
    # the check cannot be told any more: nobody sits on it as far as the book and the list know
    gone = say(h, "t-1", linda)
    assert gone.status_code == 404 and gone.json()["detail"]["error"] == "unknown_party"
    # the guest list still can: it says it of the guests the hub noted on the check
    assert [row["order_id"] for row in waiting(h)] == ["t-1"]
    assert who(said_after(h, "t-1", novak)) == [("Linda P.", False), ("Novak", True)]
    assert tally(h, NOVAK) == (1, 1, net) and waiting(h) == []


# --- every guest of the check ---------------------------------------------------------------------------------


def test_the_number_typed_on_the_check_is_one_of_its_guests_and_pays_until_another_is_said():
    h = host_stand()
    priya_was = tally(h, PRIYA)
    net, linda, novak = two_at(h)
    type_number(h, "t-1", PRIYA, "Priya")
    told = the_check(h, "t-1")
    assert [(guest["key"], guest["name"], guest["typed"], guest["pays"]) for guest in told["guests"]] == [
        (TYPED, "Priya", True, True),
        (linda, "Linda P.", False, False),
        (novak, "Novak", False, False),
    ]
    assert (told["waits"], told["said_by"]) == (False, "") and waiting(h) == []  # the number pays: no wait
    # Linda paid after all
    assert who(said_after(h, "t-1", linda)) == [("Priya", False), ("Linda P.", True), ("Novak", False)]
    assert tally(h, PRIYA) == (priya_was[0] + 1, priya_was[1], priya_was[2])
    # no: the number on the check did. That takes the word from whoever had it
    again = said_after(h, "t-1", TYPED)
    assert who(again) == [("Priya", True), ("Linda P.", False), ("Novak", False)] and again["said_by"] == ""
    assert tally(h, PRIYA) == (priya_was[0] + 1, priya_was[1] + 1, priya_was[2] + net)
    assert paying(h, "t-1") == []
    # the number pays for want of a word, so there is no word of it to take back
    back = say_after(h, "t-1", TYPED, pays=False)
    assert back.status_code == 422 and back.json()["detail"]["error"] == "bad_value"
    # and a check with no number has no such guest
    two_at(h, "t-2", "B5")
    none = say_after(h, "t-2", TYPED)
    assert none.status_code == 404 and none.json()["detail"]["error"] == "unknown_guest"


def test_the_same_number_typed_and_seated_is_one_guest_to_say():
    h = host_stand()
    check(h, "t-1", "A7", GTC)
    seat(h, book_table(h, "Linda Papas", LINDA)["booking"], "t-1")
    h.now += 60_000
    novak = seat(h, wait(h, "Novak", NOVAK)["party"], "t-1", book="waitlist")["party"]
    type_number(h, "t-1", LINDA, "Linda P.")
    told = the_check(h, "t-1")
    assert [(guest["key"], guest["name"]) for guest in told["guests"]] == [
        (TYPED, "Linda P."),
        (f"waitlist:{novak['id']}", "Novak"),
    ]
    assert who(told) == [("Linda P.", True), ("Novak", False)]


def test_a_guest_of_a_check_that_was_merged_in_can_be_said_to_have_paid():
    h = host_stand()
    omar_was = tally(h, OMAR)
    a7 = check(h, "t-1", "A7", GTC)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    b5 = check(h, "t-2", "B5", WINGS)
    type_number(h, "t-2", OMAR, "Omar K.")
    put_together(h, "t-2", "t-1", 1)
    # Omar is a guest of the joined check and is on no screen with the table open: here he is
    (row,) = waiting(h)
    assert {guest["name"]: guest["key"].split(":")[0] for guest in row["guests"]} == {
        "Linda P.": "reservation",
        "Omar K.": "check",
    }
    assert Decimal(row["net"]) == a7 + b5
    assert sorted(who(said_after(h, "t-1", "check:t-2"))) == [("Linda P.", False), ("Omar K.", True)]
    assert tally(h, OMAR) == (omar_was[0] + 1, omar_was[1] + 1, omar_was[2] + a7 + b5)


# --- who may say it, and what cannot be said ------------------------------------------------------------------


def test_it_is_said_by_whoever_may_read_the_guest_list_and_by_nobody_else():
    h = host_stand()
    _, linda, novak = two_at(h)
    assert h.c.get("/reports/guests/payers").status_code == 401
    assert h.c.get("/reports/guests/payers/t-1").status_code == 401
    assert say_after(h, "t-1", linda, headers={}).status_code == 401
    session = h.c.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"})
    server = {"authorization": f"Bearer {session.json()['token']}"}
    assert h.c.get("/reports/guests/payers", headers=server).status_code == 403
    assert h.c.get("/reports/guests/payers/t-1", headers=server).status_code == 403
    assert say_after(h, "t-1", linda, headers=server).status_code == 403
    assert the_check(h, "t-1")["waits"] is True  # none of it said anything


def test_what_cannot_be_said():
    h = host_stand()
    _, linda, _ = two_at(h)
    other = seat(h, wait(h, "Omar", OMAR)["party"], "t-2", table="B5", book="waitlist")["party"]
    check(h, "t-2", "B5", WINGS)
    check(h, "t-4", "C2", GTC)  # a walk-in's
    h.table("t-6", h.now, table="D4")
    seat(h, wait(h, "Priya", PRIYA)["party"], "t-6", table="D4", book="waitlist")  # seated, nothing rung in
    for order_id in ("t-4", "t-6", "no-such"):
        gone = h.c.get(f"/reports/guests/payers/{order_id}", headers=h.manager())
        assert gone.status_code == 404 and gone.json()["detail"]["error"] == "no_check", order_id
        assert say_after(h, order_id, linda).json()["detail"]["error"] == "no_check"
    for guest in (f"waitlist:{other['id']}", "waitlist:no-such", "check:t-1", "nonsense", ""):
        nobody = say_after(h, "t-1", guest)
        assert nobody.status_code == 404 and nobody.json()["detail"]["error"] == "unknown_guest", guest
    assert the_check(h, "t-1")["waits"] is True
    # a table of one party is read, and has nothing to say: its only guest pays
    alone = the_check(h, "t-2")
    assert who(alone) == [("Omar", True)] and (alone["waits"], alone["said_by"]) == (False, "")


# --- what it does not touch -----------------------------------------------------------------------------------


def test_saying_it_afterwards_writes_nothing_on_a_check_and_changes_no_sale():
    h = host_stand()
    _, linda, novak = two_at(h)
    figures = (h.report()["sales"], h.check("t-1"), h.c.get("/orders/t-1").json(), len(h.store))
    waiting(h)
    said_after(h, "t-1", linda)
    said_after(h, "t-1", novak)
    said_after(h, "t-1", novak, pays=False)
    assert (h.report()["sales"], h.check("t-1"), h.c.get("/orders/t-1").json(), len(h.store)) == figures


def test_the_log_names_the_check_and_who_said_it_and_no_guest(caplog):
    h = host_stand()
    _, linda, _ = two_at(h)
    with caplog.at_level(logging.DEBUG):
        said_after(h, "t-1", linda)
        say_after(h, "t-1", "nonsense")
    assert "t-1" in caplog.text and "s3" in caplog.text
    assert not any(word in caplog.text for word in (LINDA, NOVAK, "Linda", "Novak"))


def test_a_guests_visit_says_how_many_guests_its_check_had_and_at_which_table():
    h = host_stand()
    two_at(h)
    visit, older = one(h, LINDA)["latest"][:2]
    assert (visit["order_id"], visit["guests"], visit["table"]) == ("t-1", 2, "A7")
    assert (older["guests"], older["table"]) == (1, "")  # an order of her own, to go


# --- the sum itself -------------------------------------------------------------------------------------------


def test_a_check_with_its_guests_and_who_pays_it():
    a7 = a_visit("t-1", "")
    linda, novak = sat("t-1", LINDA, "Linda P.", 1_000), sat("t-1", NOVAK, "Novak", 2_000, "waitlist")
    row = paid_by(a7, [linda, novak])
    assert (row["waits"], row["said_by"], who(row)) == (True, "", [("Linda P.", False), ("Novak", False)])
    assert [guest["key"] for guest in row["guests"]] == ["reservation:reservation-Linda P.", "waitlist:waitlist-Novak"]
    row = paid_by(a7, [linda, replace(novak, pays=True, pays_by="Amy")])
    assert (row["waits"], row["said_by"], who(row)) == (False, "Amy", [("Linda P.", False), ("Novak", True)])
    # one guest alone pays without a word, and so does the number on the check
    assert who(paid_by(a7, [linda])) == [("Linda P.", True)]
    typed = paid_by(a_visit("t-1", PRIYA, "Priya"), [linda])
    assert (who(typed), typed["said_by"]) == ([("Priya", True), ("Linda P.", False)], "")
    # it is the sum the guest list does: the one who pays here is the one whose visit is paid there
    assert isinstance(a7, Visit) and row["net"] == str(a7.net)


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_it_is_said_the_same_from_postgres():
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
        net, linda, novak = two_at(h)
        # the same number noted twice on the check, the second of them tapped: one guest, who pays
        kept_guests.put(guest_of("waitlist", "twice", "t-1", LINDA, "Linda P.", h.now))
        kept_guests.pay("waitlist", "twice", True, by="Amy")
        told = the_check(h, "t-1")
        assert who(told) == [("Linda P.", True), ("Novak", False)] and told["said_by"] == "Amy"
        # taken back of her: of every note of her number on the check
        assert said_after(h, "t-1", linda, pays=False)["waits"] is True
        assert [row["order_id"] for row in waiting(h)] == ["t-1"]
        assert who(said_after(h, "t-1", novak)) == [("Linda P.", False), ("Novak", True)]
        assert tally(h, NOVAK) == (1, 1, net) and waiting(h) == []
    finally:
        kept_guests.close()
        h.store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS ops, orders, check_guest")
