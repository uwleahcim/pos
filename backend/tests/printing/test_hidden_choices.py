"""A station's ticket leaves off the choices the menu hides from it: the wok does not read the rice. The bag's
ticket reads what the takeout station reads, and a dish is never left off with its choices."""

from __future__ import annotations

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu import admin
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import Printer, PrintService, Takes, kitchen_changes, ticket_for
from pos.settings import SettingStore
from pos.sync.oplog import OpStore, replay

from ..conftest import T0
from ..orders.test_menu_orders import DINNER, GTC_QUART, payload
from .fake_printer import FakePrinter, decode
from .test_service import wait_for
from .test_stations import TAKE_OUT_CHOICE, TAKEOUT


def menu_hiding_rice(*stations: str) -> MenuService:
    """The sample menu with a takeout station, its rice choice left off the tickets of `stations`."""
    defs = load_definitions("restaurant")
    rice = admin.encode(defs.groups["rice"])
    defs = admin.apply(defs, [TAKEOUT, {"kind": "group", "op": "put", "data": {**rice, "hidden_at": list(stations)}}])
    assert admin.problems(defs)[0] == []
    return MenuService(defs, now=lambda: DINNER)


def app_with(printing: PrintService, menu: MenuService) -> TestClient:
    c = TestClient(
        create_app(OpStore(physical=lambda: T0 + 100), menu=menu, printing=printing, settings=SettingStore())
    )
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    headers = {"authorization": f"Bearer {token}"}
    c.put("/settings/printers", headers=headers, json={"printers": [], "takeout_station": "takeout"})
    return c


def order(c: TestClient, order_id: str, *, to_go: bool, void: bool = False) -> None:
    """General Tso's chicken, extra spicy, brown rice: fired, and then voided when asked."""
    how = {"order_type": "takeout", "channel": "phone"} if to_go else {"table": "12", "order_type": "dine_in"}
    ops = [
        payload("a", "create", 0, **how),
        payload("b", "add_line", 1, line_id="L1", item="?", request=GTC_QUART),
        payload("c", "fire", 2, course="*"),
    ]
    if void:
        ops.append(payload("d", "void_line", 3, line_id="L1", reason="changed their mind"))
    for n, op in enumerate(ops):
        c.post(f"/orders/{order_id}/ops", json=[{**op, "op_id": f"{order_id}-{n}", "order_id": order_id}])


def tickets(c: TestClient, order_id: str, *, upto: int | None = None) -> dict[str, list[tuple[str, tuple, bool]]]:
    """What each printer's ticket lists for the order's last change: printer id -> (dish, choices, void)."""
    printing: PrintService = c.app.state.printing
    ops = c.app.state.store.for_order(order_id)[:upto]
    before, after = replay(ops[:-1], order_id), replay(ops, order_id)
    sent, voided = kitchen_changes(before, after)
    to_go = str(after.fields.get("order_type")) != "dine_in"
    out = {}
    for printer, routes in printing.routing(printing.printers, to_go=to_go):
        ticket = ticket_for(after, sent, voided, station=printer.name, ticket_no=1, routes=routes)
        if ticket is not None:
            out[printer.id] = [(t.label, t.modifiers, t.void) for t in ticket.lines]
    return out


WOK, BAG = Printer("wok", "10.0.0.9", id="wok"), Printer("takeout", "10.0.0.10", id="bag")


def test_the_wok_does_not_read_the_rice_and_the_bag_does():
    c = app_with(PrintService([WOK, BAG], direct=False), menu_hiding_rice("wok"))
    order(c, "o1", to_go=False)
    assert tickets(c, "o1") == {"wok": [("左宗鸡 (Qt)", ("加辣",), False)]}  # a table's order: nothing to bag
    order(c, "o2", to_go=True)
    assert tickets(c, "o2") == {
        "wok": [("左宗鸡 (Qt)", ("加辣",), False)],
        "bag": [("左宗鸡 (Qt)", ("加辣", "糙米"), False)],  # whoever packs the bag scoops the rice
    }
    # the check lists the rice and charges for it as before
    check = c.get("/orders/o1/check").json()
    assert [m["label"] for m in check["lines"][0]["modifiers"]] == ["Extra spicy", "Brown rice"]


def test_a_void_leaves_it_off_the_same_way():
    c = app_with(PrintService([WOK, BAG], direct=False), menu_hiding_rice("wok"))
    order(c, "o1", to_go=True, void=True)
    assert tickets(c, "o1") == {
        "wok": [("左宗鸡 (Qt)", ("加辣",), True)],
        "bag": [("左宗鸡 (Qt)", ("加辣", "糙米"), True)],
    }


def test_a_printer_standing_in_for_the_wok_reads_what_the_wok_reads():
    """One printer for the whole kitchen: it prints the wok's ticket, so it leaves the rice off like the wok;
    a to-go order, bagged at the same printer, lists the rice once."""
    only = Printer("kitchen", "10.0.0.9", id="k")
    c = app_with(PrintService([only], direct=False), menu_hiding_rice("wok"))
    order(c, "o1", to_go=False)
    assert tickets(c, "o1") == {"k": [("左宗鸡 (Qt)", ("加辣",), False)]}
    both = Printer("wok", "10.0.0.9", id="k", stations=("wok", "takeout"))
    c = app_with(PrintService([both], direct=False), menu_hiding_rice("wok"))
    order(c, "o1", to_go=False)
    order(c, "o2", to_go=True)
    assert tickets(c, "o1") == {"k": [("左宗鸡 (Qt)", ("加辣",), False)]}
    assert tickets(c, "o2") == {"k": [("左宗鸡 (Qt)", ("加辣", "糙米"), False)]}


def test_a_dish_sent_to_the_takeout_counter_by_a_choice_reads_there_as_the_counter_reads_it():
    """The old POS's "Take out" under Preparation (Extra spicy stands in for it here) sends the dish to the
    takeout counter as well. The counter's copy lists the rice; with no printer at the counter the first
    printer stands in for it and says the dish once, with what either station reads."""
    defs = admin.apply(menu_hiding_rice("wok").defs, [TAKE_OUT_CHOICE])
    menu = MenuService(defs, now=lambda: DINNER)
    c = app_with(PrintService([WOK, BAG], direct=False), menu)
    order(c, "o1", to_go=False)
    assert tickets(c, "o1") == {
        "wok": [("左宗鸡 (Qt)", ("加辣",), False)],
        "bag": [("左宗鸡 (Qt)", ("加辣", "糙米"), False)],
    }
    c = app_with(PrintService([WOK], direct=False), menu)
    order(c, "o1", to_go=False)
    assert tickets(c, "o1") == {"wok": [("左宗鸡 (Qt)", ("加辣", "糙米"), False)]}


def test_a_choice_hidden_everywhere_it_prints_leaves_the_dish_alone_on_the_ticket():
    c = app_with(PrintService([WOK, BAG], direct=False), menu_hiding_rice("wok", "takeout"))
    order(c, "o2", to_go=True)
    assert tickets(c, "o2") == {
        "wok": [("左宗鸡 (Qt)", ("加辣",), False)],
        "bag": [("左宗鸡 (Qt)", ("加辣",), False)],
    }


def test_who_reads_a_line_on_each_printer():
    wok = Takes(frozenset({"wok"}), served=frozenset({"wok", "takeout"}))
    assert wok("wok") and not wok("fryer") and wok.readers("wok") == {"wok"}
    first = Takes(frozenset({"wok"}), first=True, served=frozenset({"wok", "takeout"}))
    assert first("fryer") and first.readers("fryer") == {"fryer"} and not first("takeout")
    bag = Takes(frozenset({"takeout"}), served=frozenset({"wok", "takeout"}), whole="takeout")
    assert bag("wok") and bag.readers("wok") == {"takeout"} and bag.readers("takeout") == {"takeout"}
    both = Takes(frozenset({"wok", "takeout"}), served=frozenset({"wok", "takeout"}), whole="takeout")
    assert both.readers("wok") == {"wok", "takeout"}


def test_the_paper_at_the_wok_is_a_line_shorter_than_the_bag_s():
    wok, bag = FakePrinter("epson"), FakePrinter("epson")
    try:
        printing = PrintService([Printer("wok", wok.address, id="p1"), Printer("takeout", bag.address, id="p2")])
        c = app_with(printing, menu_hiding_rice("wok"))
        order(c, "o1", to_go=True)
        wait_for(lambda: len(wok.jobs) == 1 and len(bag.jobs) == 1)
        # every Chinese line is one image: the dish and each choice the station reads
        assert len(decode(wok.jobs[0]).images) == 2 and len(decode(bag.jobs[0]).images) == 3
    finally:
        wok.close()
        bag.close()
