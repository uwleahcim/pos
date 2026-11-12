"""The index of the log: which orders there are, where each stands and whether it changed, without replaying
anything. The screens ask for the open orders every two seconds, so those reads must cost the same however
long the history is. Both stores keep one; the PostgreSQL tests need POS_TEST_DATABASE_URL."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.orders.callers import last_order
from pos.orders.numbers import OrderNumbers
from pos.sync import oplog
from pos.sync.oplog import OpStore, OrderEntry

from .conftest import T0, make_op

DSN = os.environ.get("POS_TEST_DATABASE_URL")
NOW = T0 + 100 * 3_600_000  # the stores' clock: a hundred hours after the first stamp


def _postgres():
    import psycopg

    from pos.sync.pgstore import PgOpStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    return PgOpStore(DSN, physical=lambda: NOW)


@pytest.fixture(params=["memory", "postgres"])
def store(request):
    if request.param == "memory":
        yield OpStore(physical=lambda: NOW)
        return
    if not DSN:
        pytest.skip("set POS_TEST_DATABASE_URL to run against PostgreSQL")
    pg = _postgres()
    yield pg
    pg.close()


@pytest.fixture
def pg():
    if not DSN:
        pytest.skip("set POS_TEST_DATABASE_URL to run against PostgreSQL")
    store = _postgres()
    yield store
    store.close()


@pytest.fixture
def replays(monkeypatch):
    """How many orders were replayed from their operations, in either store."""
    from pos.sync import pgstore

    count = [0]
    real = oplog.replay

    def counted(ops, order_id=None):
        count[0] += 1
        return real(ops, order_id)

    monkeypatch.setattr(oplog, "replay", counted)
    monkeypatch.setattr(pgstore, "replay", counted)
    return count


def day(store, orders: int, *, closed: bool = True, at: int = 0, prefix: str = "o") -> None:
    """`orders` checks of two dishes each, opened one second apart from `at` ms after T0."""
    for i in range(orders):
        order_id, t = f"{prefix}{i}", at + i * 1_000
        ops = [
            make_op("create", order_id, at=t, table=i + 1),
            make_op("add_line", order_id, at=t + 1, line_id="L1", item="Tsingtao", qty=2),
            make_op("add_line", order_id, at=t + 2, line_id="L2", item="Rolls"),
        ]
        if closed:
            ops.append(make_op("close", order_id, at=t + 3))
        store.append(ops)


def test_the_index_knows_where_each_order_stands(store):
    assert store.index() == [] and store.entry("o1") is None and store.view("o1") is None
    store.append([make_op("create", "o1", at=0, table=4), make_op("add_line", "o1", at=1, line_id="L1", item="Tea")])
    store.append([make_op("create", "o2", at=5_000, table=7), make_op("close", "o2", at=6_000)])
    store.append([make_op("create", "o3", at=7_000, table=9), make_op("void_order", "o3", at=8_000)])

    assert [(e.order_id, e.status) for e in store.index()] == [("o1", "open"), ("o2", "closed"), ("o3", "void")]
    one = store.entry("o1")
    assert isinstance(one, OrderEntry) and (one.first_ms, one.last_ms, one.version) == (T0, T0 + 1, 2)
    assert [e.order_id for e in store.index(status="open")] == ["o1"]
    assert [e.order_id for e in store.index(status="closed")] == ["o2"]
    assert [e.order_id for e in store.index(opened_since=T0 + 5_000)] == ["o2", "o3"]
    assert [e.order_id for e in store.index(active_since=T0 + 6_001)] == ["o3"]
    assert [e.order_id for e in store.index(status="closed", active_since=T0 + 2)] == ["o2"]
    assert store.index(status="open", opened_since=T0 + 1) == []

    # an order's row moves when the order does, and only then
    two = store.entry("o2")
    store.append([make_op("reopen", "o2", at=9_000)])
    assert store.entry("o1") == one and store.entry("o2") != two
    assert (store.entry("o2").status, store.entry("o2").last_ms, store.entry("o2").version) == ("open", T0 + 9_000, 7)
    assert [e.order_id for e in store.index(status="open")] == ["o1", "o2"]
    # an operation stamped before the ones already there (a terminal back from an outage) counts all the same
    store.append([make_op("add_line", "o1", at=-5, line_id="L0", item="Soup")])
    assert (store.entry("o1").first_ms, store.entry("o1").last_ms, store.entry("o1").version) == (T0 - 5, T0 + 1, 8)


def test_an_order_is_replayed_once_per_change(store, replays):
    day(store, 3, closed=False)
    entries = store.index(status="open")
    replays[0] = 0
    first = store.views(entries)
    assert [s.order_id for s in first] == ["o0", "o1", "o2"] and len(first[0].lines) == 2
    again = store.views(store.index(status="open"))
    assert all(a is b for a, b in zip(first, again, strict=True))  # the very same replays: nothing was read again
    assert store.view("o1") is first[1]
    assert replays[0] <= 3  # the memory store had them from working out the index

    store.append([make_op("add_line", "o1", at=50_000, line_id="L3", item="Tea")])
    replays[0] = 0
    after = store.views(store.index(status="open"))
    assert after[0] is first[0] and after[2] is first[2]
    assert after[1] is not first[1] and len(after[1].lines) == 3 and len(first[1].lines) == 2
    assert replays[0] <= 2  # the changed order (and its index row), nothing else

    # `state` stays the caller's own copy: changing it changes nothing anyone else reads
    own = store.state("o1")
    assert own is not after[1] and own.snapshot() == after[1].snapshot()
    oplog.apply(own, make_op("close", "o1", at=60_000))
    assert store.view("o1").status == "open"
    # rows read before a change still get the order as it stands now
    assert len(store.views(entries)[1].lines) == 3


def test_reading_the_open_orders_does_not_grow_with_the_history(pg, replays):
    """A month of closed checks behind tonight's open ones: the polls replay the open ones once, then nothing."""
    from pos.sync.pgstore import PgOpStore

    day(pg, 60, at=0)
    day(pg, 4, closed=False, at=90 * 3_600_000, prefix="open")
    pg.close()
    again = PgOpStore(DSN, physical=lambda: NOW)  # the hub restarts: nothing is kept in memory
    try:
        client = TestClient(create_app(again))
        replays[0] = 0
        listed = client.get("/orders", params={"status": "open"}).json()["orders"]
        assert sorted(o["order_id"] for o in listed) == ["open0", "open1", "open2", "open3"]
        assert replays[0] == 4
        floor = client.get("/floor").json()
        assert sorted(check["order_id"] for checks in floor["status"].values() for check in checks) == [
            "open0",
            "open1",
            "open2",
            "open3",
        ]
        assert client.get("/orders/open2").json()["fields"] == {"table": 3}
        assert client.get("/orders/open2/check").json()["lines"][0]["name"] == "Tsingtao"
        assert client.get("/orders", params={"status": "open"}).json()["orders"] == listed
        assert replays[0] == 4  # the floor, one order, its check and the list again: all from the same replays
    finally:
        again.close()


def test_a_log_written_before_the_index_is_indexed_when_the_hub_starts(pg):
    import psycopg

    from pos.sync.pgstore import PgOpStore

    day(pg, 3)
    pg.append([make_op("create", "late", at=9_000, table=2)])
    want = pg.index()
    pg.close()
    with psycopg.connect(DSN) as conn:  # as a build without the index left it
        conn.execute("DROP TABLE orders")
    again = PgOpStore(DSN, physical=lambda: NOW)
    try:
        assert again.index() == want and [e.order_id for e in again.index(status="open")] == ["late"]
    finally:
        again.close()
    with psycopg.connect(DSN) as conn:  # an older build ran for a while after the index was made
        conn.execute("DELETE FROM orders WHERE order_id = 'o1'")
        conn.execute("UPDATE orders SET status = 'open', version = 1 WHERE order_id = 'o2'")
    healed = PgOpStore(DSN, physical=lambda: NOW)
    try:
        assert healed.index() == want
    finally:
        healed.close()


def test_the_day_s_lookups_read_the_day_only(pg, replays):
    """The order number picks up where the day was and a caller's last order is today's: neither replays the
    days before."""
    from datetime import date

    from pos import localtime

    day(pg, 30, at=0)  # an earlier day
    start = 72 * 3_600_000
    today: date = localtime.day_of(T0 + start)
    for i, phone in enumerate(["781 555 0101", "781 555 0102"]):
        pg.append([make_op("create", f"t{i}", at=start + i, order_no=i + 1, phone=phone, order_type="takeout")])
    pg._views = oplog.Views()  # as after a restart
    replays[0] = 0
    assert OrderNumbers(pg, today=lambda: today).next() == 3
    assert replays[0] == 2
    assert last_order(pg, "(781) 555-0102", day=today).order_id == "t1"
    assert last_order(pg, "781 555 0199", day=today) is None
    assert replays[0] == 2
