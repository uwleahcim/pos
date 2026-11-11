"""Slice 1: the app sends choices, the hub prices them, the check adds up with Massachusetts meals tax."""

from __future__ import annotations

from datetime import UTC, datetime

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import Printer, PrintService, ticket_for_fire
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts

from ..conftest import T0

DINNER = datetime(2026, 10, 30, 19, 0, tzinfo=UTC)  # a Friday evening: the lunch menu is closed


def payload(op_id: str, kind: str, at: int, **data):
    return {
        "op_id": op_id,
        "order_id": "o1",
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def client(printing: PrintService | None = None) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=MenuService(load_definitions("restaurant"), now=lambda: DINNER),
            taxes=massachusetts(),
            printing=printing or PrintService([]),
        )
    )


GTC_QUART = {
    "variant_id": "GTC:quart",
    "entry_id": "dinner:87",
    "selections": [{"group_id": "spice", "option_id": "spice:extra"}, {"group_id": "rice", "option_id": "rice:brown"}],
}


def test_menu_shows_every_station_with_two_languages():
    c = client()
    menus = c.get("/menu").json()["menus"]
    assert [m["menu"] for m in menus] == ["dinner"]
    sections = {s["section_id"]: s for s in menus[0]["sections"]}
    assert {"dinner/apps", "dinner/chefs", "dinner/sushi", "dinner/bar"} <= set(sections)
    gtc = next(e for e in sections["dinner/chefs"]["entries"] if e["item"] == "GTC")
    assert (
        gtc["second_name"]
        and gtc["has_options"]
        and [v["variant_id"] for v in gtc["variants"]]
        == [
            "GTC:pint",
            "GTC:quart",
        ]
    )
    zh = c.get("/menu", params={"locale": "zh"}).json()["menus"][0]
    assert zh["name"] == "晚餐"

    item = c.get("/menu/items/GTC", params={"entry": "dinner:87"}).json()
    assert [g["group_id"] for g in item["groups"]] == ["spice", "rice", "addons"]
    assert item["groups"][1]["min_select"] == 1
    assert c.get("/menu/items/NOPE").status_code == 404
    assert c.get("/menu/search", params={"q": "87"}).json()["hits"][0]["item"] == "GTC"


def test_price_preview():
    c = client()
    priced = c.post("/menu/price", json=GTC_QUART).json()
    assert priced["unit_price"] == "25.95"  # quart 24.95 + brown rice 1.00; extra spicy is free
    assert priced["tax_class"] == "prepared_food" and priced["name"] == "General Tso's Chicken (Quart)"
    assert priced["kitchen"][0]["station"] == "wok"
    assert c.post("/menu/price", json={"variant_id": "NOPE:x"}).json()["problems"][0]["code"] == "unknown_variant"


def test_lines_are_priced_by_the_hub_and_the_check_adds_up():
    c = client()
    forged = {"unit_price": "0.01", "name": "cheap"}
    ops = [
        payload("a", "create", 0, table="12", guests=2, order_type="dine_in"),
        payload("b", "add_line", 1, line_id="L1", item="?", qty=1, seat=1, request=GTC_QUART, priced=forged),
        payload("c", "add_line", 2, line_id="L2", item="?", qty=2, seat=2, request={"variant_id": "TSINGTAO:bottle"}),
        payload("d", "add_line", 3, line_id="L3", item="?", qty=1, seat=2, request={"variant_id": "CALROLL:roll"}),
    ]
    assert c.post("/orders/o1/ops", json=ops).status_code == 202
    order = c.get("/orders/o1").json()
    assert order["lines"]["L1"]["item"] == "General Tso's Chicken (Quart)"
    assert order["lines"]["L1"]["priced"]["unit_price"] == "25.95"  # the forged price was dropped

    check = c.get("/orders/o1/check").json()
    assert [(line["line_id"], line["total"]) for line in check["lines"]] == [
        ("L1", "25.95"),
        ("L2", "13.00"),
        ("L3", "8.50"),
    ]
    assert check["subtotal"] == "47.45"
    assert [(t["component"], t["amount"]) for t in check["tax_lines"]] == [
        ("ma_meals", "2.97"),  # 6.25% of 47.45 = 2.965625
        ("ma_local_meals", "0.36"),  # 0.75% = 0.355875
    ]
    assert (check["tax"], check["tax_rate_pct"], check["total"]) == ("3.33", "7.00", "50.78")

    c.post(
        "/orders/o1/ops",
        json=[payload("e", "void_line", 4, line_id="L2"), payload("f", "set_line", 5, line_id="L3", qty=2)],
    )
    check = c.get("/orders/o1/check").json()
    assert check["subtotal"] == "42.95" and [line["line_id"] for line in check["lines"]] == ["L1", "L3"]
    assert c.get("/orders/nope/check").status_code == 404


def test_a_line_the_menu_refuses_is_left_out_and_the_rest_kept():
    c = client()
    two_rices = {
        "variant_id": "GTC:quart",
        "entry_id": "dinner:87",
        "selections": [
            {"group_id": "rice", "option_id": "rice:white"},
            {"group_id": "rice", "option_id": "rice:brown"},
        ],
    }
    ops = [
        payload("a", "create", 0, table="5"),
        payload("b", "add_line", 1, line_id="L1", item="?", request=two_rices),
        payload("c", "add_line", 2, line_id="L2", item="?", request={"variant_id": "NOPE:x"}),
        payload("d", "add_line", 3, line_id="L3", item="?", request={"selections": []}),
        payload("e", "add_line", 4, line_id="L4", item="?", request={"variant_id": "TEA:pot"}),
    ]
    body = c.post("/orders/o1/ops", json=ops).json()
    assert body["accepted"] == ["a", "e"]
    assert [(r["op_id"], r["error"]) for r in body["refused"]] == [
        ("b", "invalid_line"),
        ("c", "invalid_line"),
        ("d", "invalid_line"),
    ]
    assert body["refused"][1]["problems"][0]["code"] == "unknown_variant"
    assert list(c.get("/orders/o1").json()["lines"]) == ["L4"]


def test_fire_prints_kitchen_labels_with_modifiers():
    printing = PrintService([Printer("kitchen", "10.0.0.9")], direct=False)
    c = client(printing)
    c.post(
        "/orders/o1/ops",
        json=[
            payload("a", "create", 0, table="12"),
            payload("b", "add_line", 1, line_id="L1", item="?", request=GTC_QUART),
            payload("c", "fire", 2, course="*"),
        ],
    )
    assert len(printing.store.all()) == 1
    store = c.app.state.store
    ticket = ticket_for_fire(store.state("o1"), store.for_order("o1")[-1], station="kitchen", ticket_no=1)
    assert [(t.qty, t.label, t.modifiers) for t in ticket.lines] == [(1, "左宗鸡 (Qt)", ("加辣", "糙米"))]


def test_fired_lines_go_to_their_station_printer_and_the_rest_to_the_first():
    printing = PrintService([Printer("kitchen", "10.0.0.9"), Printer("bar", "10.0.0.10")], direct=False)
    c = client(printing)
    c.post(
        "/orders/o1/ops",
        json=[
            payload("a", "create", 0, table="12"),
            payload("b", "add_line", 1, line_id="L1", item="?", request=GTC_QUART),
            payload("c", "add_line", 2, line_id="L2", item="?", qty=2, request={"variant_id": "TSINGTAO:bottle"}),
            payload("d", "add_line", 3, line_id="L3", item="?", request={"variant_id": "CALROLL:roll"}),
            payload("e", "fire", 4, course="*"),
        ],
    )
    store = c.app.state.store
    fire = store.for_order("o1")[-1]
    kitchen, bar = (
        ticket_for_fire(store.state("o1"), fire, station=p.name, ticket_no=1, routes=routes)
        for p, routes in printing.routing(printing.printers, to_go=False)
    )
    assert [t.label for t in kitchen.lines] == ["左宗鸡 (Qt)", "加州卷"]  # wok and sushi: no printer of their own
    assert [(t.qty, t.label) for t in bar.lines] == [(2, "Tsingtao")]
    assert sorted(j.job_id for j in printing.store.all()) == ["e:bar", "e:kitchen"]


def test_an_empty_check_still_names_its_tax_rates():
    c = client()
    c.post("/orders/o1/ops", json=[payload("a", "create", 0, table="12", order_type="dine_in")])
    check = c.get("/orders/o1/check").json()
    assert (check["subtotal"], check["tax"], check["tax_rate_pct"]) == ("0.00", "0.00", "7.00")
    assert [t["rate_pct"] for t in check["tax_lines"]] == ["6.25", "0.75"]


def test_every_dish_on_the_open_menus_comes_with_its_choices_in_one_read():
    """ADR 6: a terminal saves these with the menu so it can still configure a dish with no backend."""
    c = client()
    menus = c.get("/menu").json()["menus"]
    entries = set()

    def walk(sections):
        for s in sections:
            entries.update((e["item"], e["entry_id"]) for e in s["entries"])
            walk(s["sections"])

    for m in menus:
        walk(m["sections"])
    bulk = c.get("/menu/items").json()
    assert bulk["revision"] == c.get("/menu/revision").json()["revision"]
    details = {(d["item"], d["entry_id"]): d for d in bulk["items"]}
    assert set(details) == entries and len(bulk["items"]) == len(entries)
    gtc = details[("GTC", "dinner:87")]
    one = c.get("/menu/items/GTC", params={"entry": "dinner:87"}).json()
    assert gtc["name"] == one["name"] and gtc["variants"] == one["variants"] and gtc["groups"] == one["groups"]
    assert {g["group_id"] for g in gtc["groups"]} >= {"spice", "rice"}
