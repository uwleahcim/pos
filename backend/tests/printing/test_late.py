"""ADR 6: an order taken while no backend answered prints when one returns, headed LATE with the time the
operator took it, so the kitchen knows it may already have cooked it from a handwritten note."""

from __future__ import annotations

from datetime import datetime

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.service import LATE_AFTER_MS, Printer, PrintService, taken_offline
from pos.sync.oplog import OpStore

from ..conftest import T0
from .fake_printer import decode
from .test_service import op, payload

NOW = T0 + 30 * 60_000  # the hub's clock: half an hour after T0


def setup():
    service = PrintService([Printer("kitchen", "10.0.0.1")], direct=False, now=lambda: NOW)
    client = TestClient(create_app(OpStore(physical=lambda: NOW), printing=service))
    return client, service


def test_a_batch_flagged_offline_prints_headed_late_with_the_time_it_was_taken():
    client, service = setup()
    taken = 12 * 60_000  # twelve minutes after T0, with the hub down
    batch = [
        op("a", "create", taken, table="A7", server="Amy", guests=2, offline=True),
        op("b", "add_line", taken + 1, line_id="L1", item="Spring Roll", course="1", offline=True),
        op("c", "fire", taken + 2, course="*", offline=True),
    ]
    assert client.post("/orders/o1/ops", json=[payload(o) for o in batch]).json()["print_jobs"] == ["c:kitchen"]
    ticket = decode(service.store.all()[0].data)
    assert ticket.text[0].strip() == "*** LATE ***" and ticket.text[1] == "KITCHEN"
    when = datetime.fromtimestamp((T0 + taken) / 1000).strftime("%H:%M")
    assert any(t.startswith(f"taken {when} offline, printed ") for t in ticket.text)
    assert "*** LATE ***" in ticket.inverted
    assert "1 x Spring Roll" in ticket.text


def test_an_old_unflagged_batch_is_late_too_and_a_fresh_one_is_not():
    client, service = setup()
    old = NOW - T0 - LATE_AFTER_MS - 60_000  # stamped a minute past the limit by an app that does not flag
    client.post("/orders/o1/ops", json=[payload(o) for o in [op("a", "create", old, table="B2")]])
    client.post("/orders/o1/ops", json=[payload(op("b", "add_line", old + 1, line_id="L1", item="Tea"))])
    client.post("/orders/o1/ops", json=[payload(op("c", "fire", old + 2, course="*"))])
    assert decode(service.store.all()[0].data).text[0].strip() == "*** LATE ***"

    fresh = NOW - T0 - 5_000  # five seconds ago: an ordinary fire
    client.post("/orders/o2/ops", json=[{**payload(op("d", "create", fresh, table="B3")), "order_id": "o2"}])
    client.post(
        "/orders/o2/ops", json=[{**payload(op("e", "add_line", fresh + 1, line_id="L1", item="Tea")), "order_id": "o2"}]
    )
    client.post("/orders/o2/ops", json=[{**payload(op("f", "fire", fresh + 2, course="*")), "order_id": "o2"}])
    jobs = service.store.all()
    assert len(jobs) == 2
    assert decode(jobs[1].data).text[0] == "KITCHEN"


def test_taken_offline_picks_the_earliest_late_stamp():
    assert taken_offline([op("a", "create", 0)], NOW, late_after_ms=LATE_AFTER_MS) is not None  # half an hour old
    assert taken_offline([op("a", "create", NOW - T0 - 1000)], NOW) is None
    flagged = taken_offline([op("a", "create", NOW - T0 - 1000, offline=True)], NOW)
    assert flagged == datetime.fromtimestamp((NOW - 1000) / 1000)
    both = taken_offline([op("b", "fire", 5000, offline=True), op("a", "create", 2000, offline=True)], NOW)
    assert both == datetime.fromtimestamp((T0 + 2000) / 1000)
