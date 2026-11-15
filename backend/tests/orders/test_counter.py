"""Counter mode and takeout (architecture section 12, phase 1): order numbers from the hub, pay before the
kitchen sees the order, quote times a manager sets per channel, future orders that print at their lead
time, and the ready text behind a messenger that only logs."""

from __future__ import annotations

from collections.abc import Callable
from datetime import date, datetime

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.service import MenuService, load_definitions
from pos.messaging import LogMessenger, text_for
from pos.orders.numbers import OrderNumbers
from pos.printing.jobs import JobStore
from pos.printing.service import Printer, PrintService, lead_delay, ticket_for
from pos.printing.ticket import render
from pos.settings import SettingStore, clean_quotes
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore, replay
from pos.tax import massachusetts

from ..conftest import T0, make_op, servers_void
from ..printing.fake_printer import decode

TEA = {"unit_price": "10.00", "tax_class": "prepared_food", "name": "Tea"}
NOW = T0 + 100  # the backend's clock in these tests
DAY = localtime.day_of(T0)  # the location's day at that moment
HOUR = 60 * 60_000


def payload(op_id: str, op_kind: str, at: int, order_id: str = "o1", **data):
    return {
        "op_id": op_id,
        "order_id": order_id,
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": op_kind,
        "data": data,
    }


def client(
    *,
    store: OpStore | None = None,
    printing: PrintService | None = None,
    messenger: LogMessenger | None = None,
    numbers: OrderNumbers | None = None,
    today: Callable[[], date] = lambda: DAY,
) -> TestClient:
    store = store if store is not None else OpStore(physical=lambda: NOW)  # an empty store is falsy
    return TestClient(
        create_app(
            store,
            menu=MenuService(load_definitions("restaurant")),
            taxes=massachusetts(),
            printing=printing or PrintService([]),
            messenger=messenger,
            location="China Sky",
            numbers=numbers or OrderNumbers(store, today=today),
            today=today,
        )
    )


def takeout(c: TestClient, order_id: str, at: int, **fields) -> dict:
    fields = {"order_type": "takeout", "channel": "counter", "customer_name": "Linda", **fields}
    ops = [
        payload(f"{order_id}-a", "create", at, order_id, **fields),
        payload(f"{order_id}-b", "add_line", at + 1, order_id, line_id="L1", item="Tea", qty=1, priced=TEA),
    ]
    r = c.post(f"/orders/{order_id}/ops", json=ops).json()
    assert r["refused"] == []
    return r


def test_takeout_orders_are_numbered_by_the_hub_through_the_day():
    store = OpStore(physical=lambda: NOW)
    c = client(store=store)
    takeout(c, "o1", 0, order_no=99)  # a terminal's own number is dropped
    c.post("/orders/o2/ops", json=[payload("o2-a", "create", 2, "o2", table="5", guests=2, order_type="dine_in")])
    takeout(c, "o3", 4, channel="phone", phone="+16175551234")
    orders = {o["order_id"]: o["fields"] for o in c.get("/orders").json()["orders"]}
    assert (orders["o1"]["order_no"], orders["o1"]["stage"]) == (1, "new")
    assert "order_no" not in orders["o2"]  # a table order is known by its table
    assert orders["o3"]["order_no"] == 2
    # A restart (or the standby hub taking over) picks the day up where it was; a new day starts again at 1.
    assert OrderNumbers(store, today=lambda: DAY).next() == 3
    assert OrderNumbers(store, today=lambda: date(2030, 1, 1)).next() == 1


def test_pay_before_fire_records_the_payment_and_what_is_due():
    c = client()
    takeout(c, "o1", 0)
    check = c.get("/orders/o1/check").json()
    assert (check["total"], check["paid"], check["due"]) == ("10.71", "0.00", "10.71")

    bad = [
        payload("p0", "pay", 2, payment_id="P0", method="cash", amount="0"),
        payload("p1", "pay", 3, payment_id="P1", method="bitcoin", amount="10.71"),
        payload("p2", "pay", 4, payment_id="P2", method="cash", amount="10.71", tendered="5.00"),
        payload("p3", "pay", 5, method="cash", amount="10.71"),
    ]
    r = c.post("/orders/o1/ops", json=bad).json()
    assert r["accepted"] == []
    assert [(x["op_id"], x["problems"][0]["code"]) for x in r["refused"]] == [
        ("p0", "bad_value"),
        ("p1", "bad_method"),
        ("p2", "bad_value"),
        ("p3", "bad_request"),
    ]
    paid = [
        payload("p4", "pay", 6, payment_id="P4", method="cash", amount="10.71", tendered="20.00", by="Amy"),
        payload("f", "fire", 7, course="*"),
    ]
    assert c.post("/orders/o1/ops", json=paid).json()["accepted"] == ["p4", "f"]
    # the same payment sent twice (a terminal retry under a new op id) is one payment
    again = payload("p5", "pay", 8, payment_id="P4", method="cash", amount="10.71")
    assert c.post("/orders/o1/ops", json=[again]).json()["accepted"] == ["p5"]
    check = c.get("/orders/o1/check").json()
    assert (check["paid"], check["due"]) == ("10.71", "0.00")
    assert check["payments"] == [
        {"payment_id": "P4", "method": "cash", "amount": "10.71", "tendered": "20.00", "note": "", "by": "Amy"}
    ]
    assert c.get("/orders/o1").json()["payments"]["P4"]["method"] == "cash"
    # paid elsewhere (a phone order settled through another system) leaves nothing due either
    takeout(c, "o2", 10, channel="phone")
    c.post("/orders/o2/ops", json=[payload("p6", "pay", 12, "o2", payment_id="P6", method="elsewhere", amount="10.71")])
    assert c.get("/orders/o2/check").json()["due"] == "0.00"


def test_quote_times_are_set_by_a_manager_and_read_by_every_terminal():
    c = client()
    quotes = c.get("/settings/quotes").json()
    assert quotes["minutes"] == {"counter": 15, "phone": 20, "online": 25, "delivery": 45}
    assert quotes["pay_at_pickup"] == ["phone"]

    body = {"minutes": {"counter": 10, "phone": 25}, "pay_at_pickup": ["online", "phone"]}
    assert c.put("/settings/quotes", json=body).status_code == 401
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    auth = {"authorization": f"Bearer {token}"}
    saved = c.put("/settings/quotes", json=body, headers=auth).json()
    assert saved["minutes"] == {"counter": 10, "phone": 25, "online": 25, "delivery": 45}
    assert saved["pay_at_pickup"] == ["online", "phone"]
    assert c.get("/settings/quotes").json() == saved
    r = c.put("/settings/quotes", json={"minutes": {"drone": 5}}, headers=auth)
    assert r.status_code == 422 and "drone" in r.json()["detail"]["message"]

    with pytest.raises(ValueError):
        clean_quotes({"minutes": {"counter": -1}})
    with pytest.raises(ValueError):
        clean_quotes({"pay_at_pickup": ["kiosk"]})
    store = SettingStore()
    assert store.put("quotes", {"minutes": {"phone": 30}})["minutes"]["counter"] == 15


def test_a_future_order_prints_at_its_lead_time_and_a_void_at_once():
    promised = NOW + HOUR  # an hour from now, quoted 20 minutes: the ticket prints in 40
    state = replay([make_op("create", at=0, order_type="takeout", promised_at=promised, quoted_minutes=20)], "o1")
    assert lead_delay(state, NOW) == 40 * 60
    soon = replay([make_op("create", at=0, order_type="takeout", promised_at=NOW + 10 * 60_000)], "o1")
    assert lead_delay(soon, NOW) == 0  # due in ten minutes with the default lead: cook it now
    assert lead_delay(replay([make_op("create", at=0, order_type="takeout")], "o1"), NOW) == 0

    mono = [1000.0]
    store = JobStore(clock=lambda: mono[0])
    service = PrintService([Printer("kitchen", "k:9100")], store=store, direct=False, now=lambda: NOW)
    c = client(printing=service)
    takeout(c, "o1", 0, promised_at=promised, quoted_minutes=20)
    fired = c.post("/orders/o1/ops", json=[payload("f", "fire", 2, course="*")]).json()
    assert fired["print_jobs"] == ["f:kitchen"]
    job = c.get("/print/jobs").json()["jobs"][0]
    assert (job["status"], job["due_in"]) == ("queued", 2400)
    assert c.post("/print/jobs/claim", json={"relay": "r1", "printers": ["k:9100"]}).json()["job"] is None
    mono[0] += 2401
    claimed = c.post("/print/jobs/claim", json={"relay": "r1", "printers": ["k:9100"]}).json()["job"]
    assert claimed["job_id"] == "f:kitchen" and claimed["due_in"] == 0
    # The ticket carries the number, the name and the promised time, big, for the shelf.
    text = decode(store.get("f:kitchen").data).text
    assert "#1  LINDA" in text and f"READY BY {datetime.fromtimestamp(promised / 1000):%H:%M}" in text
    assert "Counter" in text and not any("No table" in t for t in text)
    # A void on a future order does not wait: the kitchen may have started early.
    c.app.state.settings = servers_void()  # no manager at hand: this is about when the void prints
    c.post("/orders/o1/ops", json=[payload("v", "void_line", 3, line_id="L1", reason="kitchen-error")])
    assert [j.job_id for j in store.pending()] == ["v:kitchen"]


def test_the_ticket_names_a_table_order_as_before():
    state = replay(
        [
            make_op("create", at=0, table="12", guests=4, order_type="dine_in"),
            make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
            make_op("fire", at=2, course="*"),
        ],
        "o1",
    )
    ticket = ticket_for(state, list(state.lines.values()), station="kitchen", ticket_no=3)
    assert ticket is not None and ticket.order_no is None and ticket.customer == ""
    text = decode(render(ticket)).text
    assert any("Table 12  4 guests" in t for t in text) and not any("READY BY" in t for t in text)


def test_the_ready_text_goes_once_in_the_customers_language_and_a_delay_sends_the_new_time():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    takeout(c, "o1", 0, channel="phone", phone="+16175551234", locale="zh")
    r = c.post("/orders/o1/ops", json=[payload("r1", "set_field", 2, stage="ready")]).json()
    assert [m["to"] for m in r["texts"]] == ["+16175551234"]
    assert messenger.sent[-1].body == "Linda您好，订单 #1 已准备好，请到China Sky取餐。请在取餐时付款。"
    assert messenger.sent[-1].kind == "ready" and messenger.sent[-1].locale == "zh"
    # marked ready again, or picked up: no second text
    c.post("/orders/o1/ops", json=[payload("r2", "set_field", 3, stage="ready")])
    c.post("/orders/o1/ops", json=[payload("r3", "set_field", 4, stage="picked_up")])
    assert len(messenger.sent) == 1

    # Paid first, in English, no name: nothing about paying.
    takeout(c, "o2", 10, channel="phone", phone="+16175550000", customer_name="")
    c.post("/orders/o2/ops", json=[payload("p", "pay", 11, "o2", payment_id="P1", method="elsewhere", amount="10.71")])
    c.post("/orders/o2/ops", json=[payload("r4", "set_field", 12, "o2", stage="ready")])
    assert messenger.sent[-1].body == "Hi there, order #2 is ready for pickup at China Sky."

    # A future order pushed back an hour: the new time, once; moved earlier or without a phone: nothing.
    later = NOW + 2 * HOUR
    takeout(c, "o3", 20, channel="phone", phone="+16175559999", promised_at=NOW + HOUR, quoted_minutes=20)
    r = c.post("/orders/o3/ops", json=[payload("d1", "set_field", 22, "o3", promised_at=later)]).json()
    assert [m["kind"] for m in r["texts"]] == ["delayed"]
    at = f"{datetime.fromtimestamp(later / 1000):%H:%M}"
    assert messenger.sent[-1].body == f"Hi Linda, order #3 at China Sky will be ready at {at}. Sorry for the wait."
    c.post("/orders/o3/ops", json=[payload("d2", "set_field", 23, "o3", promised_at=NOW + HOUR)])
    takeout(c, "o4", 30, promised_at=NOW + HOUR)
    c.post("/orders/o4/ops", json=[payload("d3", "set_field", 32, "o4", promised_at=later)])
    c.post("/orders/o4/ops", json=[payload("r5", "set_field", 33, "o4", stage="ready")])
    assert len(messenger.sent) == 3

    listed = c.get("/messages").json()
    assert listed["provider"] == "LogMessenger" and [m["order_id"] for m in listed["messages"]] == ["o3", "o2", "o1"]

    assert text_for("ready", replay([make_op("create", order_id="o9", at=0)], "o9"), location="x") is None  # no phone
