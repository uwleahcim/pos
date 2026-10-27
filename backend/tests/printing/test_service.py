from __future__ import annotations

import base64
import time

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.service import Printer, PrintService, printers_from_env, ticket_for_fire
from pos.sync.hlc import HLC
from pos.sync.oplog import Op, OpStore, replay

from ..conftest import T0
from .fake_printer import FakePrinter, decode


def op(op_id: str, kind: str, at: int, **data) -> Op:
    return Op(op_id=op_id, order_id="o1", hlc=HLC(T0 + at, 0, "t1"), device="t1", kind=kind, data=data)


def payload(o: Op) -> dict:
    return {
        "op_id": o.op_id,
        "order_id": o.order_id,
        "hlc": str(o.hlc),
        "device": o.device,
        "kind": o.kind,
        "data": o.data,
    }


ORDER = [
    op("a", "create", 0, table=12, server="Amy", guests=4),
    op("b", "add_line", 1, line_id="L1", item="左宗鸡 (Qt)", qty=1, seat=2),
    op("c", "add_line", 2, line_id="L2", item="Kung Pao Chicken (Pt)", qty=2, note="allergy: peanut"),
    op("d", "add_line", 3, line_id="L3", item="Tsingtao", qty=2, course="drinks"),
    op("e", "void_line", 4, line_id="L3", reason="changed mind"),
]


def test_printer_specs():
    assert printers_from_env("kitchen=172.19.1.162/escpos, bar=172.19.1.14:9100/star") == [
        Printer("kitchen", "172.19.1.162", "escpos"),
        Printer("bar", "172.19.1.14:9100", "star"),
    ]
    assert printers_from_env("") == []
    with pytest.raises(ValueError):
        Printer.parse("kitchen=172.19.1.162/dotmatrix")
    with pytest.raises(ValueError):
        Printer.parse("172.19.1.162")


def test_fire_makes_a_ticket_of_the_active_lines():
    state = replay(ORDER)
    ticket = ticket_for_fire(state, op("f", "fire", 5, course="*"), station="Wok", ticket_no=7)
    assert ticket is not None
    assert ticket.table == "12" and ticket.server == "Amy" and ticket.guests == 4 and ticket.ticket_no == 7
    assert [(line.qty, line.label) for line in ticket.lines] == [(1, "左宗鸡 (Qt)"), (2, "Kung Pao Chicken (Pt)")]
    assert ticket.lines[1].note == "allergy: peanut" and ticket.lines[0].seat == 2
    assert ticket_for_fire(state, op("g", "fire", 6, course="drinks"), station="Bar", ticket_no=8) is None


def wait_for(predicate, seconds: float = 3.0) -> None:
    deadline = time.monotonic() + seconds
    while not predicate():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.02)


def test_hub_prints_on_fire_and_unrouted_lines_go_to_the_first_printer():
    epson, star = FakePrinter(), FakePrinter()
    try:
        service = PrintService([Printer("kitchen", epson.address), Printer("bar", star.address, "star")])
        client = TestClient(create_app(OpStore(physical=lambda: T0 + 100), printing=service))
        assert client.post("/orders/o1/ops", json=[payload(o) for o in ORDER]).json()["print_jobs"] == []
        fired = client.post("/orders/o1/ops", json=[payload(op("f", "fire", 5, course="*"))]).json()
        assert fired["print_jobs"] == ["f:kitchen"]  # typed lines carry no station: the first printer
        wait_for(lambda: len(epson.jobs) == 1)
        out = decode(epson.jobs[0])
        assert out.text[0] == "KITCHEN" and any("Table 12  4 guests" in t for t in out.text)
        assert "2 x Kung Pao Chicken" in out.text and out.cuts == 1
        assert star.jobs == []
        wait_for(lambda: all(j["status"] == "done" for j in client.get("/print/jobs").json()["jobs"]))
        jobs = client.get("/print/jobs").json()["jobs"]
        assert {j["done_by"] for j in jobs} == {"hub"}
        # the same fire sent again (a retry from the terminal) is one job, not two
        again = client.post("/orders/o1/ops", json=[payload(op("f", "fire", 5, course="*"))]).json()
        assert again["accepted"] == [] and again["print_jobs"] == []
        assert len(client.get("/print/jobs").json()["jobs"]) == 1
    finally:
        epson.close()
        star.close()


def test_cloud_leaves_jobs_for_a_relay():
    printer = FakePrinter()
    try:
        service = PrintService([Printer("kitchen", printer.address)], direct=False)
        client = TestClient(create_app(OpStore(physical=lambda: T0 + 100), printing=service))
        client.post("/orders/o1/ops", json=[payload(o) for o in ORDER])
        client.post("/orders/o1/ops", json=[payload(op("f", "fire", 5, course="*"))])
        listed = client.get("/print/printers").json()
        assert listed["direct"] is False and listed["printers"][0]["address"] == printer.address
        assert client.get("/print/jobs", params={"status": "queued"}).json()["jobs"][0]["job_id"] == "f:kitchen"

        claim = client.post("/print/jobs/claim", json={"relay": "ipad1", "printers": [printer.address]}).json()
        job = claim["job"]
        assert job["job_id"] == "f:kitchen" and job["leased_to"] == "ipad1"
        data = base64.b64decode(job["data_b64"])
        assert decode(data).cuts == 1
        # nobody else gets it while the lease runs
        assert (
            client.post("/print/jobs/claim", json={"relay": "mac1", "printers": [printer.address]}).json()["job"]
            is None
        )
        assert client.post("/print/jobs/claim", json={"relay": "mac1", "printers": ["10.0.0.9"]}).json()["job"] is None

        failed = client.post("/print/jobs/f:kitchen/failed", json={"by": "ipad1", "error": "no route"}).json()
        assert failed["status"] == "queued" and failed["last_error"] == "no route"
        job = client.post("/print/jobs/claim", json={"relay": "mac1", "printers": [printer.address]}).json()["job"]
        assert job["job_id"] == "f:kitchen"
        done = client.post("/print/jobs/f:kitchen/done", json={"by": "mac1"}).json()
        assert done["status"] == "done" and done["done_by"] == "mac1"
        assert client.post("/print/jobs/f:kitchen/done", json={"by": "ipad1"}).json()["done_by"] == "mac1"
        assert client.post("/print/jobs/nope/done", json={"by": "mac1"}).status_code == 404
        assert client.get("/print/jobs", params={"status": "queued"}).json()["jobs"] == []
        assert printer.jobs == []  # the cloud never touched the printer itself
    finally:
        printer.close()


def test_test_print_by_name():
    printer = FakePrinter()
    try:
        service = PrintService([Printer("kitchen", printer.address)])
        client = TestClient(create_app(OpStore(physical=lambda: T0), printing=service))
        assert client.post("/print/test", json={"printer": "bar"}).status_code == 404
        job = client.post("/print/test", json={"printer": "kitchen"}).json()
        assert job["printer"] == printer.address and job["bytes"] > 1000
        wait_for(lambda: len(printer.jobs) == 1)
        assert decode(printer.jobs[0]).text[0] == "KITCHEN"
    finally:
        printer.close()
