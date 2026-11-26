"""The inbox every online order is written to before anything is done with it (pos.online.inbox), in
memory and, where `POS_TEST_DATABASE_URL` names one, in PostgreSQL."""

from __future__ import annotations

import os
from dataclasses import replace

import pytest

from pos.online.inbox import MOST_TRIES, SAID_MAX, Arrival, Inbox

DSN = os.environ.get("POS_TEST_DATABASE_URL")
RAW = {"id": 7, "client_first_name": "Pat", "items": [{"name": "Tea", "price": 2.5}]}


@pytest.fixture(params=["memory", "postgres"])
def inbox(request):
    if request.param == "memory":
        yield Inbox()
        return
    if not DSN:
        pytest.skip("set POS_TEST_DATABASE_URL to run against PostgreSQL")
    import psycopg

    from pos.online.inbox import PgInbox

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS online_order")
    box = PgInbox(DSN)
    try:
        yield box
    finally:
        box.close()


def came(ext_id: str, at: int = 1000, **more) -> Arrival:
    return Arrival(**{"source": "gloriafood", "ext_id": ext_id, "fetched_ms": at, "raw": RAW, "kind": "pickup", **more})


def test_an_order_is_written_down_once_however_often_it_comes(inbox):
    assert inbox.writable()
    assert inbox.add(came("7")) is True
    assert inbox.add(came("7", at=2000, kind="delivery")) is False  # the same order again: the first stands
    kept = inbox.get("gloriafood", "7")
    assert kept == came("7")
    assert kept.raw == RAW and kept.waiting
    assert inbox.get("gloriafood", "8") is None
    assert inbox.get("elsewhere", "7") is None  # another service's number 7 is another order


PLACED = {**RAW, "status": "pending", "accepted_at": None}
"""An order as GloriaFood hands it over the moment the customer places it: nobody has answered it yet."""
ACCEPTED = {**RAW, "status": "accepted", "accepted_at": "2027-01-15T23:00:00.000Z"}


def test_an_order_kept_before_it_was_answered_is_taken_as_it_comes_again(inbox):
    inbox.add(came("7", raw=PLACED))
    inbox.settle(replace(came("7"), state="kept", said="it waits to be accepted", settled_ms=1500))
    assert inbox.again(came("7", at=2000, raw=PLACED)) is False  # it says of itself what it said: nothing new
    assert inbox.get("gloriafood", "7").state == "kept"
    # accepted now: what came now stands in place of what came then, and it waits as a new one does
    assert inbox.again(came("7", at=3000, raw=ACCEPTED, kind="delivery", via="push", account="main")) is True
    taken = inbox.get("gloriafood", "7")
    assert (taken.raw, taken.kind, taken.state, taken.said, taken.settled_ms) == (ACCEPTED, "delivery", "new", "", None)
    assert (taken.fetched_ms, taken.via, taken.account) == (1000, "poll", "")  # when and how it came first
    assert [row.ext_id for row in inbox.waiting()] == ["7"]
    assert inbox.again(came("7", at=4000, raw=ACCEPTED)) is False  # and once


def test_one_that_is_written_down_and_not_looked_at_yet_is_taken_as_it_comes_again_too(inbox):
    # placed and accepted between two askings: GloriaFood hands both over in one answer
    inbox.add(came("7", raw=PLACED))
    assert inbox.again(came("7", raw=ACCEPTED)) is True
    assert inbox.get("gloriafood", "7").raw == ACCEPTED
    # the other way round, the order that says it is still waiting says nothing new: it never goes back
    inbox.add(came("8", raw=ACCEPTED))
    assert inbox.again(came("8", raw=PLACED)) is False
    inbox.settle(replace(came("8"), state="kept", said="it reached the hub a day late", settled_ms=1500))
    assert inbox.again(came("8", raw=PLACED)) is False
    assert inbox.get("gloriafood", "8").raw == ACCEPTED


def test_an_order_on_the_pos_or_in_the_book_is_never_taken_again(inbox):
    canceled = {**RAW, "status": "canceled"}
    for n, state in (("1", "placed"), ("2", "booked")):
        inbox.add(came(n, raw=ACCEPTED))
        inbox.settle(replace(came(n), state=state, order_id=f"gf-{n}", settled_ms=1500))
        assert inbox.again(came(n, at=2000, raw=canceled)) is False
        here = inbox.get("gloriafood", n)
        assert (here.raw, here.state, here.order_id, here.settled_ms) == (ACCEPTED, state, f"gf-{n}", 1500)
    assert inbox.again(came("9", raw=ACCEPTED)) is False  # one that is not here
    assert inbox.get("gloriafood", "9") is None
    # one whose details were dropped long ago: what it said of itself then is not known any more
    inbox.add(came("4", raw=PLACED))
    inbox.settle(replace(came("4"), state="kept", said="it waits to be accepted", settled_ms=1500))
    assert inbox.forget_before(5000) == 3
    assert inbox.again(came("4", at=9000, raw=ACCEPTED)) is False


def test_one_that_would_not_go_on_the_pos_and_was_cancelled_since_is_taken_as_it_comes_now(inbox):
    # given up on, for a person to ring in by hand: that it was cancelled since is what that person must know
    inbox.add(came("3", raw=ACCEPTED))
    given_up = replace(came("3"), state="failed", said="a dish is not on the menu", tries=MOST_TRIES, settled_ms=1500)
    inbox.settle(given_up)
    assert inbox.again(came("3", at=2000, raw=ACCEPTED)) is False  # the same again: it stays given up on
    assert inbox.again(came("3", at=3000, raw={**RAW, "status": "canceled"})) is True
    here = inbox.get("gloriafood", "3")
    assert (here.state, here.said, here.tries, here.raw["status"]) == ("new", "", 0, "canceled")


READY = {**ACCEPTED, "ready": True}
"""An order as it comes once it was marked ready in the website's own app."""


def test_one_not_looked_at_yet_is_taken_as_it_comes_when_it_only_says_it_is_ready_now(inbox):
    # accepted and marked ready between two askings: both copies come in one answer
    inbox.add(came("7", raw=ACCEPTED))
    assert inbox.again(came("7", raw=READY)) is True
    assert inbox.get("gloriafood", "7").raw == READY
    assert inbox.again(came("7", raw=READY)) is False  # and once
    # one something was done with already is not taken again for that: it is the POS's to say it is ready
    inbox.add(came("8", raw=ACCEPTED))
    inbox.settle(replace(came("8"), state="kept", said="it reached the hub a day late", settled_ms=1500))
    assert inbox.again(came("8", raw=READY)) is False
    assert inbox.get("gloriafood", "8").raw == ACCEPTED
    # an order that says nothing of being ready is one that is not
    inbox.add(came("9", raw={**ACCEPTED, "ready": None}))
    assert inbox.again(came("9", raw={**ACCEPTED, "ready": False})) is False


def test_an_older_copy_never_takes_the_place_of_a_newer_one(inbox):
    accepted = {**ACCEPTED, "updated_at": "2027-01-15T23:01:00.000Z"}
    canceled = {**RAW, "status": "canceled", "updated_at": "2027-01-15T23:06:00.000Z"}
    inbox.add(came("7", raw=canceled))
    inbox.settle(replace(came("7"), state="kept", said="it was cancelled", settled_ms=1500))
    assert inbox.again(came("7", at=2000, raw=accepted)) is False  # it was on its way while the order was cancelled
    assert inbox.get("gloriafood", "7").state == "kept"
    # a copy that does not say when it was changed is taken at its word, as before
    assert inbox.again(came("7", at=3000, raw=ACCEPTED)) is True
    # and the newer one is taken
    inbox.add(came("8", raw=accepted))
    inbox.settle(replace(came("8"), state="kept", said="it reached the hub a day late", settled_ms=1500))
    assert inbox.again(came("8", at=2000, raw=canceled)) is True


def test_what_an_order_on_the_pos_says_later_is_kept_in_place_of_what_it_said(inbox):
    inbox.add(came("1", raw=ACCEPTED))
    inbox.settle(replace(came("1"), state="placed", order_id="gf-1", settled_ms=1500))
    inbox.heard(came("1", at=2000, raw=READY, kind="delivery", via="push"))
    here = inbox.get("gloriafood", "1")
    assert here.raw == READY
    # nothing else of it changes
    assert (here.state, here.order_id, here.settled_ms, here.fetched_ms, here.kind, here.via) == (
        "placed",
        "gf-1",
        1500,
        1000,
        "pickup",
        "poll",
    )
    inbox.heard(came("9", raw=READY))  # one that is not here: nothing happens
    assert inbox.get("gloriafood", "9") is None
    # an older copy never takes the place of a newer one, where both say when they were changed
    newer = {**READY, "updated_at": "2027-01-15T23:06:00.000Z"}
    inbox.heard(came("1", raw=newer))
    inbox.heard(came("1", raw={**ACCEPTED, "updated_at": "2027-01-15T23:01:00.000Z"}))
    assert inbox.get("gloriafood", "1").raw == newer
    inbox.heard(came("1", raw=READY))  # one that does not say is taken at its word
    assert inbox.get("gloriafood", "1").raw == READY
    # one whose details were dropped stays without them
    assert inbox.forget_before(5000) == 1
    inbox.heard(came("1", at=9000, raw=READY))
    assert inbox.get("gloriafood", "1").raw is None


def test_an_order_that_says_nothing_of_itself_counts_as_accepted(inbox):
    inbox.add(came("7"))  # no status at all: an accepted order, as the API was first written
    inbox.settle(replace(came("7"), state="kept", said="an order placed from a table", settled_ms=1500))
    assert inbox.again(came("7", raw=ACCEPTED)) is False
    assert inbox.again(came("7", raw={**RAW, "status": "canceled"})) is True


def test_what_became_of_it_is_written_beside_it(inbox):
    for n in ("1", "2", "3", "4"):
        inbox.add(came(n, at=1000 + int(n)))
    inbox.settle(replace(came("1"), state="placed", order_id="gf-1", settled_ms=5000))
    inbox.settle(replace(came("2"), state="kept", said="a table reservation", settled_ms=5000))
    inbox.settle(replace(came("3"), state="failed", said="x" * 400, tries=1, settled_ms=5000))
    inbox.settle(replace(came("9"), state="placed"))  # one that is not here: nothing happens
    placed = inbox.get("gloriafood", "1")
    assert (placed.state, placed.order_id, placed.settled_ms, placed.waiting) == ("placed", "gf-1", 5000, False)
    assert placed.raw == RAW and placed.fetched_ms == 1001  # as it came, and when
    assert inbox.get("gloriafood", "2").said == "a table reservation"
    assert len(inbox.get("gloriafood", "3").said) == SAID_MAX
    # still to be put on the POS: the new one, and the failed one while it has tries left; the oldest first
    assert [row.ext_id for row in inbox.waiting()] == ["3", "4"]
    assert [row.ext_id for row in inbox.waiting(limit=1)] == ["3"]
    inbox.settle(replace(came("3"), state="failed", said="still no", tries=MOST_TRIES))
    assert [row.ext_id for row in inbox.waiting()] == ["4"]  # left for a person
    assert [row.ext_id for row in inbox.troubled()] == ["3"]
    assert [row.ext_id for row in inbox.since(1003)] == ["3", "4"]
    assert inbox.get("gloriafood", "9") is None


def test_the_ones_that_failed_come_newest_first(inbox):
    for n, at in (("1", 1000), ("2", 3000), ("3", 2000)):
        inbox.add(came(n, at=at, state="failed", tries=MOST_TRIES))
    assert [row.ext_id for row in inbox.troubled()] == ["2", "3", "1"]
    assert [row.ext_id for row in inbox.troubled(limit=2)] == ["2", "3"]


def test_the_customer_s_details_go_after_a_while_and_what_became_of_the_order_stays(inbox):
    inbox.add(came("1", at=1000, state="placed", order_id="gf-1"))
    inbox.add(came("2", at=1000))  # still to be put on the POS: it is kept whole however old
    inbox.add(came("3", at=9000, state="placed", order_id="gf-3"))
    assert inbox.forget_before(5000) == 1
    old = inbox.get("gloriafood", "1")
    assert old.raw is None and (old.state, old.order_id, old.kind, old.fetched_ms) == ("placed", "gf-1", "pickup", 1000)
    assert inbox.get("gloriafood", "2").raw == RAW
    assert inbox.get("gloriafood", "3").raw == RAW
    assert inbox.forget_before(5000) == 0  # once


def test_what_is_said_of_an_order_names_no_customer(inbox):
    inbox.add(came("7", state="failed", said="it has no dishes", tries=MOST_TRIES))
    about = inbox.get("gloriafood", "7").about()
    assert about == {
        "source": "gloriafood",
        "id": "7",
        "kind": "pickup",
        "state": "failed",
        "order_id": None,
        "said": "it has no dishes",
        "tries": MOST_TRIES,
        "fetched_ms": 1000,
        "settled_ms": None,
        "via": "poll",
        "account": "",
    }
    assert "Pat" not in str(about)


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_an_order_written_down_is_there_after_a_restart():
    import psycopg

    from pos.online.inbox import PgInbox

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS online_order")
    first = PgInbox(DSN)
    try:
        first.add(came("1"))
        first.add(came("2", at=2000))
        first.settle(replace(came("1"), state="placed", order_id="gf-1", settled_ms=3000))
    finally:
        first.close()
    again = PgInbox(DSN)  # the hub after a restart, or the one that took over
    try:
        assert again.writable()
        assert [row.ext_id for row in again.waiting()] == ["2"]
        assert again.get("gloriafood", "1").order_id == "gf-1"
        assert again.add(came("2")) is False
    finally:
        again.close()


def test_how_an_order_came_first_is_written_beside_it(inbox):
    inbox.add(came("1"))
    inbox.add(came("2", via="push"))
    assert inbox.add(came("2", at=2000)) is False  # it came the other way too: how it came first stands
    assert (inbox.get("gloriafood", "1").via, inbox.get("gloriafood", "2").via) == ("poll", "push")
    inbox.settle(replace(came("2"), state="placed", order_id="gf-2", settled_ms=3000))
    assert inbox.get("gloriafood", "2").via == "push"
    assert [row.via for row in inbox.since(0)] == ["poll", "push"]
    assert inbox.get("gloriafood", "2").about()["via"] == "push"


OLD_TABLE = """
CREATE TABLE online_order (
    seq        BIGSERIAL PRIMARY KEY,
    source     TEXT NOT NULL,
    ext_id     TEXT NOT NULL,
    fetched_ms BIGINT NOT NULL,
    raw        JSONB,
    kind       TEXT NOT NULL DEFAULT '',
    state      TEXT NOT NULL DEFAULT 'new',
    order_id   TEXT,
    said       TEXT NOT NULL DEFAULT '',
    tries      INTEGER NOT NULL DEFAULT 0,
    settled_ms BIGINT,
    UNIQUE (source, ext_id)
)
"""


def test_the_account_that_brought_an_order_is_written_beside_it(inbox):
    inbox.add(came("1"))
    inbox.add(came("2", account="s1", raw={**RAW, "restaurant_id": 2}))
    inbox.add(came("3", account="t1", raw={**RAW, "restaurant_id": "3"}))
    assert [row.account for row in inbox.since(0)] == ["", "s1", "t1"]
    assert inbox.get("gloriafood", "2").about()["account"] == "s1"
    inbox.settle(replace(inbox.get("gloriafood", "2"), state="placed", order_id="gf-2", settled_ms=2000))
    assert inbox.get("gloriafood", "2").account == "s1"
    # GloriaFood's number for a restaurant says whose a later order is
    assert (inbox.account_of("2"), inbox.account_of("3"), inbox.account_of("9")) == ("s1", "t1", None)
    inbox.add(came("4", account="s2", raw={**RAW, "restaurant_id": 2}))  # the newest word on a number stands
    assert inbox.account_of("2") == "s2"
    inbox.add(came("5", raw={**RAW, "restaurant_id": 2}))  # one that was put to no account says nothing
    assert inbox.account_of("2") == "s2"


def test_an_order_that_is_here_without_an_account_learns_it_and_nothing_else_of_it_changes(inbox):
    assert inbox.add(came("1", raw={**RAW, "restaurant_id": 7})) is True  # pushed, and no account could be told
    inbox.settle(replace(inbox.get("gloriafood", "1"), state="placed", order_id="gf-1", settled_ms=2000))
    assert inbox.account_of("7") is None
    # the asking brings it for an account: it is the same order, and it learns whose it is
    assert inbox.add(replace(came("1", account="t1", raw={**RAW, "restaurant_id": 7}), fetched_ms=9000)) is False
    row = inbox.get("gloriafood", "1")
    assert (row.account, row.state, row.order_id, row.fetched_ms) == ("t1", "placed", "gf-1", came("1").fetched_ms)
    assert inbox.account_of("7") == "t1"
    # one that has its account keeps it, whoever brings it again
    assert inbox.add(came("1", account="s1")) is False and inbox.add(came("1")) is False
    assert inbox.get("gloriafood", "1").account == "t1"
    assert len(inbox.since(0)) == 1


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_a_hub_that_wrote_orders_down_before_there_were_accounts_keeps_them_and_learns_the_account():
    import psycopg

    from pos.online.inbox import PgInbox

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS online_order")
        conn.execute(OLD_TABLE)
        conn.execute("ALTER TABLE online_order ADD COLUMN via TEXT NOT NULL DEFAULT 'poll'")  # as #134 left it
        conn.execute(
            "INSERT INTO online_order (source, ext_id, fetched_ms, kind, state, order_id, via) "
            "VALUES ('gloriafood', '1', 1000, 'pickup', 'placed', 'gf-1', 'push')"
        )
    box = PgInbox(DSN)  # the hub after `hubctl update`
    try:
        assert box.writable() and box.writable()
        old = box.get("gloriafood", "1")
        assert (old.state, old.via, old.account) == ("placed", "push", "")
        assert box.add(came("2", account="s1", raw={**RAW, "restaurant_id": 2})) is True
        assert [row.account for row in box.since(0)] == ["", "s1"] and box.account_of("2") == "s1"
    finally:
        box.close()


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_a_hub_that_wrote_orders_down_before_pushes_keeps_them_and_learns_how_orders_come():
    import psycopg

    from pos.online.inbox import PgInbox

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS online_order")
        conn.execute(OLD_TABLE)  # as the hub made it before an order could be pushed
        conn.execute(
            "INSERT INTO online_order (source, ext_id, fetched_ms, kind, state, order_id) "
            "VALUES ('gloriafood', '1', 1000, 'pickup', 'placed', 'gf-1')"
        )
    box = PgInbox(DSN)  # the hub after `hubctl update`
    try:
        assert box.writable() and box.writable()  # and the column is added once
        old = box.get("gloriafood", "1")
        assert (old.state, old.order_id, old.via) == (
            "placed",
            "gf-1",
            "poll",
        )  # it was asked for: there was no other way
        assert box.add(came("1", via="push")) is False
        assert box.add(came("2", via="push")) is True
        assert [row.via for row in box.since(0)] == ["poll", "push"]
    finally:
        box.close()
