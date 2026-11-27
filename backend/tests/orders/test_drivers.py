"""A delivery handed to a driver (docs/delivery.md).

Who a delivery can be handed to is a power (`deliver`): to start the drivers hold it, a role that came with
it, and nobody who was on the staff before holds anything new. An order that leaves says who took it and
when (`stage` out, `driver`, `driver_id`, `out_at`); the customer is told it is on its way, once; the
check's history says who took it. Nothing of the sale changes by any of it."""

from __future__ import annotations

from pos.identity.powers import HANDED, STANDARD, clean_powers, held, holds
from pos.identity.staff import Directory, Staff, demo_directory, roster
from pos.messaging import LogMessenger

from ..printing.test_other_stations import CHICKEN, kitchen
from ..printing.test_screen import on, send
from ..printing.test_ticket_skips import op as screen_op
from .test_counter import HOUR, NOW, client, payload, takeout
from .test_day import Hub, at
from .test_delivery import BELL, ELM
from .test_history import steps as history_steps

TOM = {"driver": "Tom", "driver_id": "d1"}
WEI = {"driver": "Wei", "driver_id": "d2"}


# Who delivers -------------------------------------------------------------------------------------------------


def test_a_driver_delivers_to_start_and_nobody_else_holds_anything_new():
    assert "driver" in HANDED
    assert STANDARD["deliver"] == ["driver"]
    assert held(None, "driver") == ["deliver"]  # and nothing else: no voids, no reports, no tables
    for role in ("server", "bartender", "host", "cashier", "kitchen"):
        assert not holds(None, role, "deliver")
    # the powers there were are whose they were (texts with customers came later, to roles of its own:
    # docs/text-inbox.md)
    assert {power: roles for power, roles in STANDARD.items() if power not in ("deliver", "texts") and roles} == {
        "take_tables": ["server", "bartender"],
        "assign_tables": ["host"],
    }
    # a manager and an owner take a delivery out themselves, as they do everything
    assert holds(None, "manager", "deliver") and holds(None, "owner", "deliver")
    assert holds({"roles": {"deliver": []}}, "manager", "deliver")  # and no table takes it from them


def test_the_location_hands_deliveries_to_whoever_takes_them_out():
    servers_too = clean_powers({"roles": {"deliver": ["server", "driver"]}})
    assert servers_too["roles"]["deliver"] == ["server", "driver"]
    assert holds(servers_too, "server", "deliver") and holds(servers_too, "driver", "deliver")
    assert not holds(servers_too, "host", "deliver")
    # a driver can be handed any other power, like any role, and holds none until then
    approves = clean_powers({"roles": {"void": ["driver"]}})
    assert holds(approves, "driver", "void") and not holds(None, "driver", "void")


def test_the_staff_list_says_who_a_delivery_can_be_handed_to():
    staff = [
        Staff.with_pin("s1", "Amy", "server", "1111"),
        Staff.with_pin("s3", "Mike", "manager", "9999"),
        Staff.with_pin("d1", "Tom", "driver", "4444"),
    ]
    listed = {s["name"]: s for s in roster(Directory(staff))}
    assert {name: s["delivers"] for name, s in listed.items()} == {"Amy": False, "Mike": True, "Tom": True}
    assert (listed["Tom"]["role"], listed["Tom"]["takes_tables"], listed["Tom"]["assigns_tables"]) == (
        "driver",
        False,
        False,
    )
    # the servers take deliveries out here too
    powers = clean_powers({"roles": {"deliver": ["server", "driver"]}})
    assert [s["name"] for s in roster(Directory(staff), powers) if s["delivers"]] == ["Amy", "Mike", "Tom"]
    # the staff a hub starts with has no driver: the manager is who it offers, until the location says more
    assert [s["name"] for s in roster(demo_directory()) if s["delivers"]] == ["Mike"]
    c = client()
    assert [s["name"] for s in c.get("/staff").json()["staff"] if s["delivers"]] == ["Mike"]


# Leaving ------------------------------------------------------------------------------------------------------


def delivery(c, order_id: str, when: int, **more) -> None:
    """A phone order that is brought to Elm Street, sent to the kitchen and marked ready."""
    takeout(c, order_id, when, channel="phone", phone="+16175551234", handover="delivery", address=ELM, **more)
    answer = c.post(
        f"/orders/{order_id}/ops",
        json=[
            payload(f"{order_id}-f", "fire", when + 2, order_id, course="*"),
            payload(f"{order_id}-r", "set_field", when + 3, order_id, stage="ready"),
        ],
    ).json()
    assert answer["refused"] == [] and answer.get("texts", []) == []  # nobody is told to come for it


def test_an_order_handed_to_a_driver_says_who_took_it_and_when():
    c = client()
    delivery(c, "o1", 0)
    out = payload("o1-out", "set_field", 10, stage="out", out_at=NOW + 10, by="Amy", by_id="s1", **TOM)
    assert c.post("/orders/o1/ops", json=[out]).json()["refused"] == []
    fields = c.get("/orders/o1").json()["fields"]
    assert (fields["stage"], fields["driver"], fields["driver_id"], fields["out_at"]) == ("out", "Tom", "d1", NOW + 10)
    assert c.get("/orders/o1").json()["status"] == "open"  # it is on its way, not delivered
    # it is still listed with the open orders, where a screen reads what each driver has out
    assert [o["order_id"] for o in c.get("/orders", params={"status": "open"}).json()["orders"]] == ["o1"]


def test_the_customer_is_told_it_is_on_its_way_once():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    delivery(c, "o1", 0)
    out = payload("o1-out", "set_field", 10, stage="out", out_at=NOW + 10, **TOM)
    assert [m["kind"] for m in c.post("/orders/o1/ops", json=[out]).json()["texts"]] == ["out"]
    assert messenger.sent[-1].body == "Hi Linda, order #1 from China Sky is on its way."
    assert ELM not in messenger.sent[-1].body and "Tom" not in messenger.sent[-1].body
    # taken back (it was the wrong bag) and handed to another driver: they were told already
    back = payload("o1-back", "set_field", 20, stage="ready", driver=None, driver_id=None)
    again = payload("o1-again", "set_field", 30, stage="out", out_at=NOW + 30, **WEI)
    assert c.post("/orders/o1/ops", json=[back]).json().get("texts", []) == []
    assert c.post("/orders/o1/ops", json=[again]).json().get("texts", []) == []
    fields = c.get("/orders/o1").json()["fields"]
    assert (fields["stage"], fields["driver"], fields["out_at"]) == ("out", "Wei", NOW + 30)
    assert len(messenger.sent) == 1
    # in their language
    delivery(c, "o2", 100, locale="zh")
    c.post("/orders/o2/ops", json=[payload("o2-out", "set_field", 110, "o2", stage="out", out_at=NOW + 110, **TOM)])
    assert messenger.sent[-1].body == "Linda您好，China Sky的订单 #2 已出发，正在配送途中。"
    # an order with no number to text is told nothing
    takeout(c, "o3", 200, channel="phone", handover="delivery", address=ELM)
    silent = payload("o3-out", "set_field", 210, "o3", stage="out", out_at=NOW + 210, **TOM)
    assert c.post("/orders/o3/ops", json=[silent]).json().get("texts", []) == []


def test_an_order_the_customer_comes_for_is_never_on_its_way():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    takeout(c, "o1", 0, channel="phone", phone="+16175551234")
    wrong = payload("o1-out", "set_field", 10, stage="out", out_at=NOW + 10, **TOM)
    assert c.post("/orders/o1/ops", json=[wrong]).json().get("texts", []) == []
    assert messenger.sent == []


def test_once_it_is_out_a_later_time_is_no_delay_to_text():
    messenger = LogMessenger()
    c = client(messenger=messenger)
    delivery(c, "o1", 0, promised_at=NOW + HOUR)
    c.post("/orders/o1/ops", json=[payload("o1-out", "set_field", 10, stage="out", out_at=NOW + 10, **TOM)])
    assert [m.kind for m in messenger.sent] == ["out"]
    later = payload("o1-late", "set_field", 20, promised_at=NOW + 2 * HOUR)
    assert c.post("/orders/o1/ops", json=[later]).json().get("texts", []) == []


def test_an_order_that_left_is_off_every_kitchen_screen():
    c = kitchen("wok", "takeout")
    send(c, "o1", CHICKEN, order_type="takeout", channel="phone", customer_name="Linda", handover="delivery")
    assert [order for order, _ in on(c, "wok")] == ["o1"]
    # the bag went out of the door without anybody marking it ready
    out = {**screen_op("t1", "o1-out", "set_field", 70, stage="out", out_at=70, **TOM), "order_id": "o1"}
    assert c.post("/orders/o1/ops", json=[out]).status_code == 202
    assert on(c, "wok") == [] and on(c, "takeout") == []


# The history --------------------------------------------------------------------------------------------------


def test_the_history_says_who_took_it_who_took_it_over_and_that_it_came_back():
    h = Hub(now=at(17))
    h.to_go("o1", at(17), name="Linda", phone="781 555 0101", handover="delivery", address=ELM, event_note=BELL)
    h.op("o1", "set_field", at(17, 40), stage="ready")
    h.op("o1", "set_field", at(17, 45), stage="out", out_at=at(17, 45), by="Amy", by_id="s1", **TOM)
    h.op("o1", "set_field", at(17, 50), by="Mike", by_id="s3", **WEI)  # Tom's car would not start
    h.op("o1", "set_field", at(17, 55), stage="ready", driver=None, driver_id=None, by="Mike", by_id="s3")
    h.op("o1", "set_field", at(18), stage="out", out_at=at(18), by="Amy", by_id="s1", **TOM)
    h.op("o1", "set_field", at(18, 20), stage="picked_up", by="Tom", by_id="d1")
    told = [s for s in history_steps(h) if s["what"] in ("stage", "driver")]
    assert [(s["what"], s.get("was"), s.get("now"), s.get("driver"), s.get("delivery")) for s in told] == [
        ("stage", "new", "ready", None, True),
        ("stage", "ready", "out", "Tom", True),  # left with Tom
        ("driver", "Tom", "Wei", None, None),  # handed over on the way
        ("stage", "out", "ready", None, True),  # back from the driver
        ("stage", "ready", "out", "Tom", True),
        ("stage", "out", "picked_up", None, True),  # delivered
    ]
    assert [s["by"] for s in told] == ["", "Amy", "Mike", "Mike", "Amy", "Tom"]


# The money ----------------------------------------------------------------------------------------------------


def test_leaving_with_a_driver_changes_nothing_of_the_sale():
    h = Hub(now=at(17))
    h.to_go("o1", at(17), name="Linda", phone="781 555 0101", handover="delivery", address=ELM)
    h.op("o1", "add_line", at(17, 1), line_id="L1", item="Tea", qty=1, priced={"unit_price": "3.00", "name": "Tea"})
    h.op("o1", "fire", at(17, 2), course="*")
    before = h.check("o1")
    h.op("o1", "set_field", at(17, 45), stage="out", out_at=at(17, 45), **TOM)
    out = h.check("o1")
    assert (out["total"], out["due"], out["charges"]) == (before["total"], before["due"], [])  # no fee for the trip
    # paid at the door: the money is recorded as on any to-go order, on the day it is taken
    h.pay("o1", at(18, 20), out["due"])
    h.op("o1", "set_field", at(18, 20), stage="picked_up")
    h.op("o1", "close", at(18, 21))
    after = h.check("o1")
    assert (after["total"], after["due"]) == (before["total"], "0.00")
