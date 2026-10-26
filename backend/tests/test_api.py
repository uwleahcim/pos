from __future__ import annotations

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore

from .conftest import T0


def payload(op_id: str, kind: str, at: int, **data):
    return {
        "op_id": op_id,
        "order_id": "o1",
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def test_append_read_and_pull():
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100)))
    ops = [payload("a", "create", 0, table=4), payload("b", "add_line", 1, line_id="L1", item="Tsingtao", qty=2)]
    assert client.post("/orders/o1/ops", json=ops).json() == {"accepted": ["a", "b"], "cursor": 2}
    assert client.post("/orders/o1/ops", json=ops).json() == {"accepted": [], "cursor": 2}

    order = client.get("/orders/o1").json()
    assert order["fields"] == {"table": 4}
    assert order["lines"]["L1"]["qty"] == 2

    pulled = client.get("/ops", params={"since": 1}).json()
    assert [op["op_id"] for op in pulled["ops"]] == ["b"] and pulled["cursor"] == 2
    assert client.get("/orders/nope").status_code == 404

    client.post("/orders/o2/ops", json=[{**payload("c", "create", 5, table=7), "order_id": "o2"}])
    client.post("/orders/o2/ops", json=[{**payload("d", "close", 6), "order_id": "o2"}])
    listed = client.get("/orders").json()
    assert [o["order_id"] for o in listed["orders"]] == ["o2", "o1"] and listed["cursor"] == 4
    assert [o["order_id"] for o in client.get("/orders", params={"status": "open"}).json()["orders"]] == ["o1"]
    assert client.get("/orders", params={"status": "weird"}).status_code == 422


def test_bad_ops_are_refused():
    client = TestClient(create_app(OpStore(physical=lambda: T0)))
    nameless = {**payload("n", "create", 0), "device": "", "hlc": str(HLC(T0, 0, ""))}
    assert client.post("/orders/o1/ops", json=[nameless]).json()["detail"]["error"] == "bad_stamp"
    other = {**payload("m", "create", 0), "device": "t2"}
    assert client.post("/orders/o1/ops", json=[other]).json()["detail"]["error"] == "bad_stamp"
    drift = client.post("/orders/o1/ops", json=[payload("z", "create", 10 * 60_000)])
    assert drift.status_code == 422 and drift.json()["detail"]["error"] == "clock_drift"
    assert client.post("/orders/o1/ops", json=[payload("y", "explode", 0)]).status_code == 422
    wrong_order = dict(payload("w", "create", 0), order_id="o2")
    assert client.post("/orders/o1/ops", json=[wrong_order]).status_code == 400
