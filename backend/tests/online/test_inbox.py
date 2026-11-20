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
