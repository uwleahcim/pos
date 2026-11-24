"""Every guest of a check is in the guest list, and the check's money is the one's who pays
(docs/guest-list.md, "Every guest of a check").

Until this, the guest list knew one guest of a check: the number typed on it. A party the host seats from
its reservation or the waitlist left a number too, and when two tables are put together both tables' guests
sit at one check. Each of them came in and ordered, so each has the visit. The money of a check counts for
one guest: the number typed on the check; on a check with no number, its only guest; with several guests
and no number, nobody until a number is typed. Who sat on which check is noted on the hub as it happens,
and nothing is written on any check."""

from __future__ import annotations

from decimal import Decimal

import pytest

from pos.api.guests import note_seated
from pos.check_guests import KEEP_DAYS, CheckGuest, CheckGuests, guest_of
from pos.orders.guests import Visit, payer_of, shared_out
from pos.reservations import Reservations
from pos.waitlist import Waitlist

from ..printing.fake_printer import decode
from .test_day import DSN, EGGROLL, WINGS, Hub
from .test_guest_tags import HOLLY, NOBODY, book_table, host_stand, kept, seat, seated_at, wait
from .test_guests import GTC, LINDA, OMAR, PRIYA, a_year, guests, one

NOVAK = NOBODY  # a number that never ordered
DAY_MS = 24 * 60 * 60 * 1000


def check(h: Hub, order_id: str, table: str, *dishes: dict) -> Decimal:
    """A table's check with these dishes on it; what it comes to before tax."""
    h.table(order_id, h.now - 60_000, table=table)
    for i, dish in enumerate(dishes, 1):
        h.ring(order_id, f"L{i}", dish, h.now - 50_000 + i)
    return Decimal(h.check(order_id)["subtotal"])


def tally(h: Hub, phone: str) -> tuple[int, int, Decimal] | None:
    """How many visits the list counts for this number, how many of them they paid, and what they spent."""
    row = next((row for row in guests(h)["guests"] if row["phone"] == phone), None)
    return None if row is None else (row["visits"], row["paid"], Decimal(row["spent"]))


def latest(h: Hub, phone: str) -> dict:
    """Their latest visit, as the list shows it when the guest is opened: the check, its money, who paid."""
    visit = one(h, phone)["latest"][0]
    return {"order_id": visit["order_id"], "net": Decimal(visit["net"]), "paid": visit["paid"]}


def type_number(h: Hub, order_id: str, phone: str, name: str = "") -> None:
    """Somebody types a customer's number on the check, as the screens do."""
    h.now += 1_000
    h.op(order_id, "set_field", h.now, phone=phone, customer_name=name)


def put_together(h: Hub, emptied: str, onto: str, lines: int) -> None:
    """Two tables made one check, as a screen does it: every dish of `emptied` goes over, and that check is
    closed saying where they went (docs/moves.md)."""
    for n in range(1, lines + 1):
        h.now += 1_000
        came = {"order_id": emptied, "line_id": f"L{n}"}
        h.op(onto, "add_line", h.now, line_id=f"M-{emptied}-{n}", item="?", **{"from": came})
        h.op(emptied, "move_line", h.now + 1, line_id=f"L{n}", to={"order_id": onto, "line_id": f"M-{emptied}-{n}"})
    h.now += 1_000
    h.op(emptied, "set_field", h.now, merged_into=onto, by="Holly", by_id="s4")
    h.op(emptied, "close", h.now + 1)


# --- a party the host seated ----------------------------------------------------------------------------------


def test_a_party_seated_with_a_number_is_a_guest_who_came_in_and_ordered():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)  # five to-go orders in the year
    assert tally(h, NOVAK) is None
    # Linda's table, booked; the Novaks came off the waitlist; the Wus left no number; and a walk-in
    a7 = check(h, "t-1", "A7", GTC, EGGROLL)
    b5 = check(h, "t-2", "B5", WINGS)
    check(h, "t-3", "C1", GTC)
    check(h, "t-4", "C2", GTC)
    seat(h, book_table(h, "Linda P.", "+1 (781) 555-0101")["booking"], "t-1")
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-2", table="B5", book="waitlist")
    seat(h, book_table(h, "Wu", time="21:45")["booking"], "t-3", table="C1")
    # each is a guest of the check they sat on: the visit, and the money, since they are its only guest
    assert tally(h, LINDA) == (visits + 1, paid + 1, spent + a7)
    assert latest(h, LINDA) == {"order_id": "t-1", "net": a7, "paid": True}
    assert tally(h, NOVAK) == (1, 1, b5)
    novak = next(row for row in guests(h)["guests"] if row["phone"] == NOVAK)
    assert (novak["name"], novak["new"], novak["orders_ever"], novak["last"]) == ("Novak", True, 1, "2026-11-16")
    assert novak["favourites"] == [{"item": "WINGS", "name": "Chicken wings", "count": 1}]
    # an order of hers and a table of hers are both hers: six orders ever, the name of her latest visit
    linda = next(row for row in guests(h)["guests"] if row["phone"] == LINDA)
    assert (linda["orders_ever"], linda["name"], linda["last"]) == (6, "Linda P.", "2026-11-16")
    # a party with no number is no guest of the list, and a walk-in's check is nobody's
    report = guests(h)
    assert report["totals"]["guests"] == 6 and not any(row["name"] == "Wu" for row in report["guests"])
    # a dish rung in after they sat down is theirs too: the check is read, not copied
    h.ring("t-2", "L9", EGGROLL, h.now + 5_000)
    assert tally(h, NOVAK) == (1, 1, Decimal(h.check("t-2")["subtotal"]))


def test_a_seated_party_is_a_guest_once_a_dish_is_rung_in_and_no_longer_when_put_back():
    h = host_stand()
    before = tally(h, LINDA)
    h.table("t-1", h.now - 60_000, table="A7")
    linda = book_table(h, "Linda P.", LINDA)["booking"]
    seat(h, linda, "t-1")
    assert tally(h, LINDA) == before  # a check with no dish is no visit, as an order with none is not
    h.ring("t-1", "L1", GTC, h.now + 1_000)
    assert tally(h, LINDA) == (before[0] + 1, before[1] + 1, before[2] + Decimal("13.95"))
    # put back in the book: she sits on no check, and the visit is not hers
    assert h.c.post(f"/reservations/{linda['id']}/back", json=HOLLY).status_code == 200
    assert tally(h, LINDA) == before
    # seated again, and the whole check voided: no visit, as for an order voided whole
    seat(h, linda, "t-1")
    assert tally(h, LINDA)[0] == before[0] + 1
    h.op("t-1", "void_order", h.now + 2_000)
    assert tally(h, LINDA) == before
    # the same for a party of the waitlist
    h.table("t-2", h.now, table="B5")
    h.ring("t-2", "L1", WINGS, h.now + 1_000)
    novak = wait(h, "Novak", NOVAK)["party"]
    seat(h, novak, "t-2", table="B5", book="waitlist")
    assert tally(h, NOVAK) == (1, 1, Decimal(h.check("t-2")["subtotal"]))
    assert h.c.post(f"/waitlist/{novak['id']}/back", json=HOLLY).status_code == 200
    assert tally(h, NOVAK) is None


# --- several guests at one check -------------------------------------------------------------------------------


def test_two_parties_at_one_table_both_have_the_visit_and_the_money_is_one_guests():
    h = host_stand()
    visits, paid, spent = tally(h, LINDA)
    was = guests(h)["totals"]
    a7 = check(h, "t-1", "A7", GTC, EGGROLL)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    h.now += 60_000
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-1", book="waitlist")  # joined her table
    # both came in and ordered; nobody said who pays, so the money is nobody's yet
    assert tally(h, LINDA) == (visits + 1, paid, spent) and tally(h, NOVAK) == (1, 0, Decimal(0))
    assert latest(h, LINDA) == {"order_id": "t-1", "net": Decimal(0), "paid": False}
    assert latest(h, NOVAK) == {"order_id": "t-1", "net": Decimal(0), "paid": False}
    novak = next(row for row in guests(h)["guests"] if row["phone"] == NOVAK)
    assert novak["per_visit"] is None  # no visit they paid to reckon it over
    assert {dish["item"] for dish in novak["favourites"]} == {"GTC", "EGGROLL"}  # what the table ordered
    now = guests(h)["totals"]
    assert (now["guests"], now["visits"], now["paid"], now["spent"]) == (
        was["guests"] + 1,
        was["visits"] + 2,
        was["paid"],
        was["spent"],
    )
    # the Novaks pay: their number is typed on the check, and the money is theirs and nobody else's
    type_number(h, "t-1", NOVAK, "Novak")
    assert tally(h, NOVAK) == (1, 1, a7) and latest(h, NOVAK) == {"order_id": "t-1", "net": a7, "paid": True}
    assert tally(h, LINDA) == (visits + 1, paid, spent)
    now = guests(h)["totals"]
    assert (now["visits"], now["paid"]) == (was["visits"] + 2, was["paid"] + 1)
    assert Decimal(now["spent"]) == Decimal(was["spent"]) + a7  # the check once, not once for each guest
    # somebody else pays, who was not seated by the host: a third guest of the check, with its money
    was_priya = tally(h, PRIYA)
    type_number(h, "t-1", PRIYA, "Priya")
    assert tally(h, PRIYA) == (was_priya[0] + 1, was_priya[1] + 1, was_priya[2] + a7)
    assert tally(h, NOVAK) == (1, 0, Decimal(0)) and tally(h, LINDA) == (visits + 1, paid, spent)


def test_the_number_typed_on_a_check_pays_and_the_same_number_seated_is_one_guest():
    h = host_stand()
    linda, omar = tally(h, LINDA), tally(h, OMAR)
    a7 = check(h, "t-1", "A7", GTC)
    type_number(h, "t-1", LINDA, "Linda")
    assert tally(h, LINDA) == (linda[0] + 1, linda[1] + 1, linda[2] + a7)  # as it always was
    # the host seats her reservation on that check: still one visit, and still hers
    seat(h, book_table(h, "Linda P.", "781-555-0101")["booking"], "t-1")
    assert tally(h, LINDA) == (linda[0] + 1, linda[1] + 1, linda[2] + a7)
    assert next(row for row in guests(h)["guests"] if row["phone"] == LINDA)["name"] == "Linda"  # the check's own
    # Omar's party joins: he has the visit, and the number on the check still pays
    seat(h, wait(h, "Omar", OMAR)["party"], "t-1", book="waitlist")
    assert tally(h, OMAR) == (omar[0] + 1, omar[1], omar[2])
    assert tally(h, LINDA) == (linda[0] + 1, linda[1] + 1, linda[2] + a7)
    assert latest(h, OMAR) == {"order_id": "t-1", "net": Decimal(0), "paid": False}


# --- two tables put together -----------------------------------------------------------------------------------


def test_both_tables_guests_are_guests_of_the_joined_check():
    h = host_stand()
    linda = tally(h, LINDA)
    a7 = check(h, "t-1", "A7", GTC, EGGROLL)
    b5 = check(h, "t-2", "B5", WINGS)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-2", table="B5", book="waitlist")
    assert tally(h, LINDA) == (linda[0] + 1, linda[1] + 1, linda[2] + a7) and tally(h, NOVAK) == (1, 1, b5)
    sales = h.report()["sales"]
    put_together(h, "t-1", "t-2", lines=2)
    assert Decimal(h.check("t-2")["subtotal"]) == a7 + b5 and h.check("t-1")["subtotal"] == "0.00"
    # both came in and ordered: one visit each, on the check that was kept; nobody said who pays
    assert tally(h, LINDA) == (linda[0] + 1, linda[1], linda[2]) and tally(h, NOVAK) == (1, 0, Decimal(0))
    assert latest(h, LINDA)["order_id"] == "t-2" and latest(h, NOVAK)["order_id"] == "t-2"
    # Linda pays for the table: the whole joined check is hers
    type_number(h, "t-2", LINDA, "Linda P.")
    assert tally(h, LINDA) == (linda[0] + 1, linda[1] + 1, linda[2] + a7 + b5)
    assert tally(h, NOVAK) == (1, 0, Decimal(0))
    assert h.report()["sales"] == sales  # the day's sales never heard of any of it


def test_the_number_typed_on_a_merged_check_is_a_guest_of_the_joined_one():
    h = host_stand()
    omar, priya = tally(h, OMAR), tally(h, PRIYA)
    a7 = check(h, "t-1", "A7", GTC)
    b5 = check(h, "t-2", "B5", WINGS)
    type_number(h, "t-1", OMAR, "Omar")
    type_number(h, "t-2", PRIYA, "Priya")
    assert tally(h, OMAR) == (omar[0] + 1, omar[1] + 1, omar[2] + a7)
    put_together(h, "t-1", "t-2", lines=1)
    # Priya's number is on the check that was kept: she pays. Omar came in and ordered.
    assert tally(h, PRIYA) == (priya[0] + 1, priya[1] + 1, priya[2] + a7 + b5)
    assert tally(h, OMAR) == (omar[0] + 1, omar[1], omar[2])
    assert latest(h, OMAR) == {"order_id": "t-2", "net": Decimal(0), "paid": False}
    assert next(row for row in guests(h)["guests"] if row["phone"] == OMAR)["name"] == "Omar"
    # the emptied check still carries his number, and nothing was written on the one that was kept
    assert h.c.get("/orders/t-1").json()["fields"]["phone"] == OMAR
    assert OMAR not in h.c.get("/orders/t-2").text and "Omar" not in h.c.get("/orders/t-2").text
    # put together again with a third table that has nobody: both go on, and nobody's number is on it
    c1 = check(h, "t-3", "C1", EGGROLL)
    put_together(h, "t-2", "t-3", lines=1)  # its own dish; the one that came from A7 stays in this test
    assert latest(h, OMAR)["order_id"] == "t-3" and latest(h, PRIYA)["order_id"] == "t-3"
    assert tally(h, OMAR) == (omar[0] + 1, omar[1], omar[2])
    assert tally(h, PRIYA) == (priya[0] + 2, priya[1] + 1, priya[2] + a7)  # what is left on B5's check is hers
    assert Decimal(h.check("t-3")["subtotal"]) == c1 + b5


# --- what is kept, and where -----------------------------------------------------------------------------------


def test_the_visit_stays_when_the_book_and_the_waitlist_have_forgotten_the_party():
    h = host_stand()
    check(h, "t-1", "A7", GTC)
    check(h, "t-2", "B5", WINGS)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1")
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-2", table="B5", book="waitlist")
    counted = (tally(h, LINDA), tally(h, NOVAK))
    # thirty days on for the book, the next night for the waitlist: neither knows them any more
    state = h.c.app.state
    state.reservations = Reservations(now_ms=lambda: h.now)
    state.waitlist = Waitlist(now_ms=lambda: h.now)
    assert seated_at(h, "t-1")["parties"] == []
    assert (tally(h, LINDA), tally(h, NOVAK)) == counted
    # a hub that starts with nobody seated takes nothing away either
    note_seated(state)
    assert (tally(h, LINDA), tally(h, NOVAK)) == counted


def test_a_hub_that_starts_notes_the_parties_already_seated_and_a_note_that_fails_stops_no_seating():
    h = host_stand()
    state = h.c.app.state
    before = tally(h, LINDA)
    a7 = check(h, "t-1", "A7", GTC)
    working = state.check_guests

    class Away(CheckGuests):
        def put(self, guest: CheckGuest) -> None:
            raise RuntimeError("the database is away")

        def drop(self, source: str, source_id: str) -> bool:
            raise RuntimeError("the database is away")

    state.check_guests = Away()
    linda = book_table(h, "Linda P.", LINDA)["booking"]  # the booking itself is noted nowhere, and goes through
    assert seat(h, linda, "t-1")["booking"]["order_id"] == "t-1"  # so does seating her
    assert tally(h, LINDA) == before
    # the hub is started again (an update): whoever sits on a check is noted, so tonight's tables count
    state.check_guests = working
    note_seated(state)
    assert tally(h, LINDA) == (before[0] + 1, before[1] + 1, before[2] + a7)
    note_seated(state)  # and again changes nothing
    assert tally(h, LINDA) == (before[0] + 1, before[1] + 1, before[2] + a7)


def test_noting_a_guest_writes_nothing_on_a_check_and_changes_no_sale():
    h = host_stand()
    kept(h, LINDA, tags=["VIP"])
    check(h, "t-1", "A7", GTC)
    figures = (h.report()["sales"], h.check("t-1"), h.c.get("/orders/t-1").json())
    seat(h, book_table(h, "Linda P.", LINDA, note="Window table")["booking"], "t-1")
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-1", book="waitlist")
    assert (h.report()["sales"], h.check("t-1"), h.c.get("/orders/t-1").json()) == figures
    # the check, its bill and what the server's screen is told carry no number
    told = (h.c.get("/orders/t-1").text, str(h.check("t-1")), str(seated_at(h, "t-1")), h.c.get("/floor").text)
    assert not any(phone in words for words in told for phone in (LINDA, NOVAK))
    printed = h.c.post("/orders/t-1/bill", json={})
    assert printed.status_code == 202, printed.text
    lines = [line for line in decode(h.printing.store.get(printed.json()["job_id"]).data).text if line.strip()]
    assert lines and not any("Linda" in line or "Novak" in line or "555" in line for line in lines)
    # and the guest list is still for whoever may read it
    assert h.c.get("/reports/guests").status_code == 401


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_seated_guests_count_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h, memory = Hub(postgres=DSN), Hub()
    try:
        for hub in (h, memory):
            a_year(hub)
            state = hub.c.app.state
            state.reservations = Reservations(now_ms=lambda hub=hub: hub.now)
            state.waitlist = Waitlist(now_ms=lambda hub=hub: hub.now)
            check(hub, "t-1", "A7", GTC, EGGROLL)
            check(hub, "t-2", "B5", WINGS)
            check(hub, "t-3", "C1", GTC)  # a walk-in
            seat(hub, book_table(hub, "Linda P.", LINDA)["booking"], "t-1")
            seat(hub, wait(hub, "Novak", NOVAK)["party"], "t-2", table="B5", book="waitlist")
            seat(hub, wait(hub, "Omar", OMAR)["party"], "t-2", table="B5", book="waitlist")
        assert tally(h, NOVAK) == (1, 0, Decimal(0)) and tally(h, LINDA)[0] == 6
        assert guests(h) == guests(memory)
        assert guests(h) == guests(memory)  # and again, from what is remembered
        for phone in (LINDA, NOVAK, OMAR):
            assert one(h, phone) == one(memory, phone)
        for store in (h.store, memory.store):
            assert [entry.order_id for entry in store.entries(["t-2", "t-1", "no-such", "t-1"])] == ["t-1", "t-2"]
            assert store.entries([]) == []
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")


# --- the reckoning by itself -----------------------------------------------------------------------------------


def a_visit(order_id: str, phone: str, name: str = "", net: str = "10.00") -> Visit:
    from datetime import date

    return Visit(phone, order_id, None, date(2026, 11, 16), 1, Decimal(net), name, "dine_in", ())


def sat(order_id: str, phone: str, name: str, at_ms: int, source: str = "reservation") -> CheckGuest:
    return guest_of(source, f"{source}-{name}", order_id, phone, name, at_ms)


def test_who_pays_a_check():
    assert payer_of(LINDA, [LINDA, OMAR]) == LINDA  # the number typed on it, whoever else sat there
    assert payer_of("", [OMAR]) == OMAR  # no number: its only guest
    assert payer_of("", [OMAR, LINDA]) == ""  # several guests and no number: nobody yet
    assert payer_of("", []) == ""


def test_a_list_with_nobody_seated_is_the_list_it_always_was():
    typed = [a_visit("o1", LINDA, "Linda"), a_visit("o2", OMAR, "Omar")]
    out = list(shared_out(typed, [], []))
    assert out == typed and all(a is b for a, b in zip(out, typed, strict=True))
    # a guest seated on some other check changes nothing about these
    assert list(shared_out(typed, [], [sat("o9", PRIYA, "Priya", 5)])) == typed


def test_every_guest_of_a_check_has_the_visit_once_and_one_of_them_its_money():
    def told(visits) -> list[tuple[str, str, str, bool, bool]]:
        return [(v.order_id, v.phone, v.name, v.paid, v.seated) for v in visits]

    seated = [
        sat("t1", OMAR, "Omar", 20, "waitlist"),
        sat("t1", LINDA, "Linda P.", 10),
        sat("t1", OMAR, "Omar again", 30),  # the same number twice at one table is one guest
        sat("t2", PRIYA, "Priya", 5),
        sat("t3", LINDA, "Linda P.", 40),
    ]
    # t1: nobody's number on it, two guests. t2: one guest. t3: a number on it, which is the guest's own.
    checks = [a_visit("t1", ""), a_visit("t2", ""), a_visit("t3", LINDA, "Linda")]
    typed = [a_visit("t3", LINDA, "Linda"), a_visit("o1", OMAR, "Omar")]
    assert told(shared_out(typed, checks, seated)) == [
        ("t3", LINDA, "Linda", True, False),
        ("o1", OMAR, "Omar", True, False),
        ("t1", LINDA, "Linda P.", False, True),  # the first to sit first
        ("t1", OMAR, "Omar", False, True),
        ("t2", PRIYA, "Priya", True, True),
    ]
    # a check with a number and another guest: the number pays, the guest has the visit
    assert told(shared_out([a_visit("t4", OMAR, "Omar")], [], [sat("t4", LINDA, "Linda P.", 1)])) == [
        ("t4", OMAR, "Omar", True, False),
        ("t4", LINDA, "Linda P.", False, True),
    ]
    # a check nobody is noted on is nobody's, even when it is handed in
    assert list(shared_out([], [a_visit("t5", "")], [])) == []


# --- the note itself -------------------------------------------------------------------------------------------


def the_same_way(guests_kept: CheckGuests) -> None:
    linda = guest_of("reservation", "b1", "t-1", LINDA, "  Linda \n P. ", 100)
    assert linda.name == "Linda P."  # on one line
    guests_kept.put(linda)
    guests_kept.put(guest_of("waitlist", "p1", "t-1", OMAR, "Omar", 200))
    guests_kept.put(guest_of("waitlist", "p2", "t-2", PRIYA, "Priya", 300))
    assert [g.name for g in guests_kept.on(["t-1"])] == ["Linda P.", "Omar"]  # the first to sit first
    assert [g.order_id for g in guests_kept.of_phone(OMAR)] == ["t-1"] and guests_kept.of_phone(NOVAK) == []
    assert [g.name for g in guests_kept.since(200)] == ["Omar", "Priya"] and guests_kept.on([]) == []
    # a party sits on one check: noted again, it is on the other one
    guests_kept.put(guest_of("waitlist", "p1", "t-2", OMAR, "Omar", 250))
    assert [g.name for g in guests_kept.on(["t-1"])] == ["Linda P."]
    assert [g.name for g in guests_kept.on(["t-2"])] == ["Omar", "Priya"]
    # two tables put together, and the same told again; a merge into itself or into nothing moves nobody
    assert guests_kept.follow("t-1", "t-2") == 1 and guests_kept.follow("t-1", "t-2") == 0
    assert guests_kept.follow("t-2", "t-2") == 0 and guests_kept.follow("t-2", "") == 0
    assert [g.name for g in guests_kept.on(["t-2"])] == ["Linda P.", "Omar", "Priya"]
    # put back; and what is older than the guest list reads is let go when somebody is noted
    assert guests_kept.drop("waitlist", "p2") is True and guests_kept.drop("waitlist", "p2") is False
    late = KEEP_DAYS * DAY_MS + 150
    guests_kept.put(guest_of("check", "t-9", "t-8", NOVAK, "Novak", late))
    assert [g.name for g in guests_kept.since(0)] == ["Omar", "Novak"]  # Linda sat down too long ago


def test_who_sat_on_which_check_is_noted_and_let_go():
    the_same_way(CheckGuests())


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_it_is_kept_in_postgresql_the_same_way():
    import psycopg

    from pos.check_guests import PgCheckGuests

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS check_guest")
    kept_here = PgCheckGuests(DSN)
    try:
        assert kept_here.since(0) == [] and kept_here.on(["t-1"]) == []
        the_same_way(kept_here)
    finally:
        kept_here.close()
    again = PgCheckGuests(DSN)  # after a restart
    try:
        assert [(g.source, g.source_id, g.order_id, g.phone, g.name) for g in again.since(0)] == [
            ("waitlist", "p1", "t-2", OMAR, "Omar"),
            ("check", "t-9", "t-8", NOVAK, "Novak"),
        ]
        # a hub that took over from one that ran before the guests were kept makes the table at the first note
        with psycopg.connect(DSN) as conn:
            conn.execute("DROP TABLE check_guest")
        assert again.since(0) == [] and again.of_phone(OMAR) == []
        again.put(guest_of("reservation", "b2", "t-3", LINDA, "Linda P.", late := 5))
        assert [g.at_ms for g in again.on(["t-3"])] == [late]
    finally:
        again.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS check_guest")
