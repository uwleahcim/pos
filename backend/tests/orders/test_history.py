"""A check's history: every step the log keeps of one order, oldest first, with who did it, at which screen
and when. It is for managers, it reads the log and changes nothing, and what changed nothing is no step.

These tests ring a table through the hub the way the screens do and read the history a manager gets."""

from __future__ import annotations

import os

import pytest

from pos.identity.photos import EventPhoto, PhotoStore
from pos.orders.history import history
from pos.sync.hlc import HLC

from ..conftest import T0, make_op
from .test_day import BEER, EGGROLL, WINGS, Hub, at

DSN = os.environ.get("POS_TEST_DATABASE_URL")
JPEG = b"\xff\xd8\xff\xe0 a face \xff\xd9"


def steps(h: Hub, order_id: str = "o1") -> list[dict]:
    answer = h.c.get(f"/orders/{order_id}/history", headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()["steps"]


def said(step: dict, *names: str) -> tuple:
    return tuple(step[name] for name in names)


def dinner(h: Hub | None = None) -> Hub:
    """Table 12 on Monday the 16th: Amy opens it and rings wings and two egg rolls, sends them, Ben adds a
    beer and sends it; an egg roll line is voided, $2 comes off, the party moves to table 14 and is handed
    to Ben; they pay cash and card and the check is closed."""
    h = h or Hub(now=at(17))
    h.op("o1", "create", at(17), table="12", guests=2, order_type="dine_in", server="Amy", server_id="s1", by="Amy")
    h.ring("o1", "L1", WINGS, at(17, 5))
    h.ring("o1", "L2", EGGROLL, at(17, 6), qty=2)
    h.op("o1", "fire", at(17, 7), course="*", by="Amy", by_id="s1")
    h.ring("o1", "L3", BEER, at(18, 10), by="Ben")
    h.op("o1", "set_line", at(18, 11), line_id="L3", qty=2, seat=2, by="Ben", by_id="s2")
    h.op("o1", "fire", at(18, 12), course="*", by="Ben", by_id="s2")
    h.op("o1", "void_line", at(18, 20), line_id="L2", reason="kitchen-error", by="Amy", by_id="s1")
    h.op(
        "o1", "discount", at(18, 25), discount_id="D1", reason="loyalty", kind="amount", value="2.00", applied_by="Amy"
    )
    h.op("o1", "set_field", at(18, 30), table="14", by="Mike", by_id="s3")
    h.op("o1", "set_field", at(18, 31), server="Ben", server_id="s2", by="Mike", by_id="s3")
    h.pay("o1", at(19), "20.00", "cash")
    h.pay("o1", at(19, 1), "5.00", "card")
    h.op("o1", "close", at(19, 2), by="Ben", by_id="s2")
    h.now = at(21)
    return h


def test_the_history_is_for_managers_and_an_unknown_check_is_not_found():
    h = dinner()
    assert h.c.get("/orders/o1/history").status_code == 401
    assert h.c.get("/orders/o1/history", headers={"authorization": "Bearer nobody"}).status_code == 401
    answer = h.c.get("/orders/nothing/history", headers=h.manager())
    assert answer.status_code == 404 and answer.json()["detail"]["error"] == "unknown_id"


def test_every_step_of_a_table_oldest_first_with_who_where_and_when():
    h = dinner()
    before = h.store.cursor
    answer = h.c.get("/orders/o1/history", headers=h.manager()).json()
    assert h.store.cursor == before  # reading changes nothing
    assert answer["order"] == {
        "order_id": "o1",
        "status": "closed",
        "table": "14",
        "order_no": None,
        "customer_name": "",
        "order_type": "dine_in",
        "server": "Ben",
        "guests": 2,
        "opened_ms": at(17),
        "merged_into": None,
    }
    told = answer["steps"]
    assert [s["what"] for s in told] == [
        "opened",
        "added",
        "added",
        "sent",
        "added",
        "changed",
        "sent",
        "voided",
        "discount",
        "table",
        "server",
        "paid",
        "paid",
        "closed",
    ]
    assert [s["at_ms"] for s in told] == sorted(s["at_ms"] for s in told)
    assert {s["device"] for s in told} == {"t1"}
    assert [s["by"] for s in told] == [
        "Amy",
        "Amy",
        "Amy",
        "Amy",
        "Ben",
        "Ben",
        "Ben",
        "Amy",
        "Amy",
        "Mike",
        "Mike",
        "Amy",
        "Amy",
        "Ben",
    ]
    opened, wings, rolls, first_send, beer, more_beer, second_send, void, off, moved, handed, cash, card, _ = told
    assert opened["fields"] == {"table": "12", "guests": 2, "order_type": "dine_in", "server": "Amy"}
    assert opened["at_ms"] == at(17)
    assert said(wings, "dish", "qty", "unit_price", "changed") == ("Chicken wings", 1, "8.95", False)
    assert said(rolls, "dish", "qty", "line_id") == ("Egg roll", 2, "L2")
    assert first_send["course"] is None
    assert first_send["dishes"] == [{"dish": "Chicken wings", "qty": 1}, {"dish": "Egg roll", "qty": 2}]
    assert more_beer["dish"] == beer["dish"]
    assert more_beer["changes"] == [{"field": "qty", "was": 1, "now": 2}, {"field": "seat", "was": None, "now": 2}]
    assert second_send["dishes"] == [{"dish": beer["dish"], "qty": 2}]  # only what had not gone yet
    assert said(void, "dish", "qty", "reason", "by_id") == ("Egg roll", 2, "Kitchen error", "s1")
    assert said(off, "name", "kind", "value", "dish") == ("Loyalty reward", "amount", "2.00", None)
    assert said(moved, "was", "now") == ("12", "14")
    assert said(handed, "was", "now") == ("Amy", "Ben")
    assert said(cash, "method", "amount") == ("cash", "20.00")
    assert said(card, "method", "amount") == ("card", "5.00")


def test_what_changed_nothing_is_no_step():
    h = dinner()
    count = len(steps(h))
    h.op("o1", "add_line", at(19, 10), line_id="L1", item="?", qty=1, request=WINGS)  # the same dish, sent again
    h.op("o1", "set_line", at(19, 11), line_id="L1", rank=0.5)  # moved up the check: nobody's business
    h.op("o1", "set_field", at(19, 12), table="14", guests=2)  # what it already was
    h.op("o1", "close", at(19, 13))  # closed already
    h.op("o1", "void_line", at(19, 14), line_id="L2", reason="kitchen-error")  # voided already
    h.op("o1", "void_line", at(19, 15), line_id="nothing")  # never on the check
    h.op("o1", "fire", at(19, 16), course="*")  # nothing left to send
    h.op("o1", "remove_discount", at(19, 17), discount_id="never")
    h.op("o1", "set_field", at(19, 18), locale="zh", ticket_no=7)  # the hub's own bookkeeping
    assert len(steps(h)) == count


def test_a_dish_taken_off_before_sending_a_change_of_a_dish_and_a_check_reopened_and_voided():
    h = Hub(now=at(17))
    h.table("o1", at(17))
    h.ring("o1", "L1", WINGS, at(17, 1))
    h.ring("o1", "L2", EGGROLL, at(17, 2))
    h.op("o1", "void_line", at(17, 3), line_id="L2", by="Amy", by_id="s1")  # the kitchen never saw it
    # an edit takes the dish off and adds the changed one in its place
    h.op("o1", "void_line", at(17, 4), line_id="L1", by="Amy", by_id="s1")
    h.op("o1", "add_line", at(17, 4), line_id="L3", item="?", qty=2, request={**WINGS, "qty": 2}, replaces="L1")
    h.op("o1", "close", at(17, 10))
    h.op("o1", "reopen", at(17, 11))
    h.op("o1", "void_order", at(17, 12), reason="Rung on the wrong table")
    told = steps(h)
    assert [s["what"] for s in told] == [
        "opened",
        "added",
        "added",
        "taken_off",
        "taken_off",
        "added",
        "closed",
        "reopened",
        "voided_check",
    ]
    assert said(told[3], "dish", "qty", "by") == ("Egg roll", 1, "Amy")
    assert said(told[5], "dish", "qty", "changed") == ("Chicken wings", 2, True)
    assert told[8]["reason"] == "Rung on the wrong table"


def test_a_dish_that_went_to_another_check_says_where_on_both():
    h = dinner(Hub(now=at(17)))
    h.table("o2", at(18, 40), table="20")
    went = str(HLC(at(17, 7), 0, "t1"))
    h.op("o1", "reopen", at(19, 5))
    # the other check takes the dish, then this one lets it go: a dish never leaves without arriving
    h.op(
        "o2",
        "add_line",
        at(19, 6),
        line_id="M1",
        item="?",
        qty=1,
        request=WINGS,
        sent=went,
        moved_by="Ben",
        moved_by_id="s2",
        **{"from": {"order_id": "o1", "line_id": "L1"}},
    )
    h.op("o1", "move_line", at(19, 6), line_id="L1", to={"order_id": "o2", "line_id": "M1"}, by="Ben", by_id="s2")
    left = steps(h)[-1]
    assert said(left, "what", "dish", "qty", "other", "other_table", "by") == (
        "moved_out",
        "Chicken wings",
        1,
        "o2",
        "20",
        "Ben",
    )
    came = steps(h, "o2")[-1]
    assert said(came, "what", "dish", "other", "other_table", "sent") == ("moved_in", "Chicken wings", "o1", "14", True)
    # who brought it over did this step; who rang the dish in stays who rang it, and is said beside
    assert said(came, "by", "by_id", "rung_by") == ("Ben", "s2", "Amy")


def test_a_dish_brought_over_by_an_older_build_names_nobody_rather_than_who_rang_it():
    h = dinner(Hub(now=at(17)))
    h.table("o2", at(18, 40), table="20")
    h.op("o1", "reopen", at(19, 5))
    h.op("o2", "add_line", at(19, 6), line_id="M1", item="?", **{"from": {"order_id": "o1", "line_id": "L1"}})
    came = steps(h, "o2")[-1]
    assert said(came, "what", "by", "by_id", "rung_by") == ("moved_in", "", None, "Amy")


def test_a_discount_that_came_over_with_its_dish_says_so():
    h = Hub(now=at(17))
    h.table("o1", at(17), table="12")
    h.ring("o1", "L1", WINGS, at(17, 5))
    h.op(
        "o1",
        "discount",
        at(17, 6),
        discount_id="D1",
        line_id="L1",
        reason="loyalty",
        kind="amount",
        value="2.00",
        applied_by="Amy",
    )
    h.table("o2", at(17, 7), table="20")
    h.op("o2", "add_line", at(17, 8), line_id="M1", item="?", **{"from": {"order_id": "o1", "line_id": "L1"}})
    h.op(
        "o2",
        "discount",
        at(17, 8),
        discount_id="D2",
        line_id="M1",
        by="Ben",
        by_id="s2",
        **{"from": {"order_id": "o1", "discount_id": "D1"}},
    )
    own, came = steps(h)[-1], steps(h, "o2")[-1]
    assert said(own, "what", "dish", "carried", "by") == ("discount", "Chicken wings", False, "Amy")
    assert said(came, "what", "dish", "kind", "value", "carried", "by") == (
        "discount",
        "Chicken wings",
        "amount",
        "2.00",
        True,
        "Ben",
    )


def test_two_tables_made_one_say_where_the_dishes_went():
    h = Hub(now=at(17))
    h.table("o1", at(17), table="12")
    h.table("o2", at(17, 1), table="14")
    h.op("o2", "set_field", at(17, 5), merged_into="o1", by="Mike", by_id="s3")
    h.op("o2", "close", at(17, 5), by="Mike", by_id="s3")
    told = steps(h, "o2")
    assert [s["what"] for s in told] == ["opened", "merged", "closed"]
    assert said(told[1], "other", "other_table", "by") == ("o1", "12", "Mike")


def test_a_to_go_order_says_its_stages_its_promise_and_who_it_is_for():
    h = Hub(now=at(17))
    h.to_go("o1", at(17), name="Lee", phone="781 555 0101", promised_at=at(17, 30), quoted_minutes=30)
    h.op("o1", "set_field", at(17, 2), promised_at=at(17, 45), quoted_minutes=45, by="Amy", by_id="s1")
    h.op("o1", "set_field", at(17, 3), customer_name="Lee Wong")
    h.op("o1", "set_field", at(17, 40), stage="ready")
    h.op("o1", "set_field", at(17, 50), stage="picked_up")
    told = steps(h)
    assert told[0]["fields"] == {
        "order_type": "takeout",
        "customer_name": "Lee",
        "phone": "781 555 0101",
        "channel": "phone",
        "order_no": 1,
        "promised_at": at(17, 30),
        "quoted_minutes": 30,
    }
    assert [(s["what"], s.get("field"), s.get("was"), s.get("now")) for s in told[1:]] == [
        ("promised", None, at(17, 30), at(17, 45)),
        ("quoted", None, 30, 45),
        ("field", "customer_name", "Lee", "Lee Wong"),
        ("stage", None, "new", "ready"),  # the hub starts a to-go order at "new"
        ("stage", None, "ready", "picked_up"),
    ]


def test_an_allergy_a_split_a_charge_and_a_discount_taken_off_again():
    h = dinner()
    h.op("o1", "reopen", at(19, 5))
    h.op("o1", "allergy", at(19, 6), seat=1, allergens=["peanut"], note="carries an EpiPen", by="Ben", by_id="s2")
    h.op("o1", "allergy", at(19, 7), seat=1, allergens=[], note="")
    h.op("o1", "set_field", at(19, 8), split={"by": "seat"})
    h.op("o1", "remove_discount", at(19, 9), discount_id="D1")
    h.op("o1", "remove_discount", at(19, 10), discount_id="D1")  # taken off already
    told = steps(h)[-5:]
    assert [s["what"] for s in told] == ["reopened", "allergy", "allergy_cleared", "split", "discount_removed"]
    assert said(told[1], "seat", "note", "by") == (1, "carries an EpiPen", "Ben")
    assert len(told[1]["allergens"]) == 1  # by the menu's own name for it, or its code where the menu has none
    assert told[2]["seat"] == 1
    assert said(told[3], "was", "now") == (None, {"by": "seat"})
    assert said(told[4], "name", "dish") == ("Loyalty reward", None)


def test_a_step_that_names_nobody_is_whoever_its_photo_shows_and_carries_the_photo():
    h = Hub(now=at(17))
    h.table("o1", at(17))
    h.ring("o1", "L1", WINGS, at(17, 1))
    h.op("o1", "fire", at(17, 2), course="*")  # an older app: a send named nobody
    h.op("o1", "close", at(17, 3))
    sent, closed = steps(h)[-2:]
    assert said(sent, "by", "by_id", "photo") == ("", None, None)
    photos: PhotoStore = h.c.app.state.photos
    photos.put(EventPhoto("p1", "t1", sent["op_id"], "fire", "s2", 0.0, JPEG))
    photos.put(EventPhoto("p2", "t1", closed["op_id"], "close", None, 0.0, JPEG))  # a camera, nobody signed in
    sent, closed = steps(h)[-2:]
    assert said(sent, "by", "by_id", "photo") == ("Ben", "s2", "p1")
    assert said(closed, "by", "by_id", "photo") == ("", None, "p2")
    assert h.c.get("/events/photos/p1").content == JPEG


def test_the_photo_store_finds_a_photo_by_its_operation_until_it_lets_the_photo_go():
    photos = PhotoStore(keep=2)
    photos.put(EventPhoto("p1", "t1", "op-1", "fire", "s1", 0.0, JPEG))
    photos.put(EventPhoto("p2", "t1", None, "sign_in", "s1", 0.0, JPEG))
    assert photos.for_op("op-1").photo_id == "p1" and photos.for_op("op-2") is None
    photos.put(EventPhoto("p3", "t1", "op-3", "close", "s1", 0.0, JPEG))  # the oldest goes
    assert photos.for_op("op-1") is None and photos.for_op("op-3").photo_id == "p3"


def test_a_course_is_said_by_its_name():
    h = Hub(now=at(17))
    h.table("o1", at(17))
    h.op("o1", "add_line", at(17, 1), line_id="L1", item="?", qty=1, request=WINGS, course="1", seat=2)
    h.op("o1", "add_line", at(17, 2), line_id="L2", item="?", qty=1, request=EGGROLL, course="2")
    h.op("o1", "set_line", at(17, 3), line_id="L2", course="3")
    h.op("o1", "fire", at(17, 4), course="1")
    h.op("o1", "fire", at(17, 5), course="gone")  # a course nobody has a dish under: nothing went
    told = steps(h)[1:]
    assert [s["what"] for s in told] == ["added", "added", "changed", "sent"]
    assert said(told[0], "course", "seat") == ("Appetizers", 2)
    assert told[2]["changes"] == [{"field": "course", "was": "Entrees", "now": "Dessert"}]
    assert said(told[3], "course", "dishes") == ("Appetizers", [{"dish": "Chicken wings", "qty": 1}])


def test_a_step_stamped_while_no_hub_answered_says_so():
    h = Hub(now=at(17))
    h.table("o1", at(17))
    h.op("o1", "add_line", at(17, 1), line_id="L1", item="?", qty=1, request=WINGS, offline=True)
    assert [s["offline"] for s in steps(h)] == [False, True]


def test_the_steps_come_in_the_order_of_their_stamps_however_the_operations_arrived():
    ops = [
        make_op("fire", "o1", 30, course="*"),
        make_op("add_line", "o1", 20, line_id="L1", item="Tea", qty=1, by="Amy"),
        make_op("create", "o1", 10, table="12"),
        make_op("add_line", "o1", 20, line_id="L1", item="Tea", qty=1, by="Amy"),  # the same dish from a retry
        make_op("pay", "o2", 40, payment_id="P1", amount="5.00"),  # another check's: not this history
    ]
    told = history(ops, "o1")
    assert [(s["what"], s["at_ms"] - T0) for s in told] == [("opened", 10), ("added", 20), ("sent", 30)]
    assert told[1]["dish"] == "Tea" and told[2]["dishes"] == [{"dish": "Tea", "qty": 1}]
    assert history([], "o1") == []


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_history_is_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(17), postgres=DSN)
    try:
        dinner(h)
        memory = dinner()

        def plain(told: list[dict]) -> list[dict]:
            return [{k: v for k, v in s.items() if k != "op_id"} for s in told]

        assert plain(steps(h)) == plain(steps(memory))
    finally:
        h.store.close()
