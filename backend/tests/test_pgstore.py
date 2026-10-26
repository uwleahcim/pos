"""The PostgreSQL store behaves exactly like the in-memory one. Needs a database: set POS_TEST_DATABASE_URL."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.sync.oplog import ClockDriftError, OpStore

from .conftest import T0, make_op

DSN = os.environ.get("POS_TEST_DATABASE_URL")
STANDBY = os.environ.get("POS_TEST_STANDBY_URL")  # a streaming standby of DSN, for the replica tests
pytestmark = pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")


@pytest.fixture
def pg():
    import psycopg

    from pos.sync.pgstore import PgOpStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops")
    store = PgOpStore(DSN, physical=lambda: T0 + 1_000)
    yield store
    store.close()


def test_matches_the_memory_store(pg):
    mem = OpStore(physical=lambda: T0 + 1_000)
    ops = [
        make_op("create", at=0, table=4),
        make_op("add_line", at=1, line_id="L1", item="Tsingtao", qty=2),
        make_op("add_line", order_id="o2", at=2, line_id="L1", item="Rolls"),
        make_op("void_line", at=3, line_id="L1", reason="spill"),
    ]
    for store in (mem, pg):
        assert [op.op_id for op in store.append(ops[:2])] == [ops[0].op_id, ops[1].op_id]
        assert store.append(ops[:2]) == []  # duplicates are ignored
        assert [op.op_id for op in store.append(ops)] == [ops[2].op_id, ops[3].op_id]
    assert pg.cursor == mem.cursor == 4
    assert len(pg) == 4 and ops[0].op_id in pg and "nope" not in pg
    assert pg.since(2) == mem.since(2) and pg.since(0, 1) == mem.since(0, 1)
    assert pg.for_order("o1") == mem.for_order("o1")
    assert pg.order_ids() == mem.order_ids() == ["o1", "o2"]
    assert pg.state("o1").snapshot() == mem.state("o1").snapshot()
    assert pg.op_ids() == mem.op_ids()
    assert pg.since(0)[0].data == {"table": 4}  # jsonb round-trips the data


def test_refuses_drift_and_unknown_kinds_before_writing(pg):
    with pytest.raises(ClockDriftError):
        pg.append([make_op("create", at=10 * 60_000)])
    with pytest.raises(ValueError):
        pg.append([make_op("bogus")])
    assert pg.cursor == 0


def test_survives_a_restart(pg):
    from pos.sync.pgstore import PgOpStore

    pg.append([make_op("create", table=1)])
    pg.close()
    again = PgOpStore(DSN)
    try:
        assert again.cursor == 1 and again.state("o1").fields == {"table": 1}
    finally:
        again.close()


def test_api_on_postgres(pg):
    client = TestClient(create_app(pg))
    op = {
        "op_id": "a",
        "order_id": "o1",
        "hlc": f"{T0:013d}-0000-t1",
        "device": "t1",
        "kind": "create",
        "data": {"table": 9},
    }
    assert client.post("/orders/o1/ops", json=[op]).json() == {"accepted": ["a"], "cursor": 1}
    assert client.get("/orders/o1").json()["fields"] == {"table": 9}
    assert client.get("/orders").json()["orders"][0]["order_id"] == "o1"
    assert client.get("/ops", params={"since": 0}).json()["cursor"] == 1
    health = client.get("/health").json()
    assert health["cursor"] == 1 and health["role"] == "primary"


@pytest.mark.skipif(not STANDBY, reason="set POS_TEST_STANDBY_URL to a streaming standby of the test database")
def test_standby_serves_reads_and_refuses_writes(pg):
    import time

    from pos.sync.pgstore import PgOpStore, ReadOnlyError

    pg.append([make_op("create", table=3)])
    standby = PgOpStore(STANDBY, physical=lambda: T0 + 1_000)
    try:
        for _ in range(50):  # streaming replication lands within milliseconds
            if standby.cursor == 1:
                break
            time.sleep(0.1)
        assert standby.role == "replica" and pg.role == "primary"
        assert standby.state("o1").fields == {"table": 3}
        with pytest.raises(ReadOnlyError):
            standby.append([make_op("add_line", at=1, line_id="L1", item="Tea")])
        client = TestClient(create_app(standby))
        assert client.get("/health").json()["role"] == "replica"
        op = {"op_id": "z", "order_id": "o1", "hlc": f"{T0:013d}-0000-t1", "device": "t1", "kind": "close"}
        refused = client.post("/orders/o1/ops", json=[op])
        assert refused.status_code == 503 and refused.json()["detail"]["error"] == "read_only"
        assert client.get("/orders/o1").json()["fields"] == {"table": 3}
    finally:
        standby.close()
