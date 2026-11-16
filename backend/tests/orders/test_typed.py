"""A dish whose price is typed when it is rung, and an off-menu dish whose name is typed too.

The menu says which dishes ask (`Item.attrs`: `asks_price`, `asks_name`); the engine takes what was typed for
those and refuses it for every other dish, so a price still never comes from a screen for a dish that has
one. What was typed stands on the check, the bill and the kitchen ticket, and the manager's report lists it."""

from __future__ import annotations

from dataclasses import replace
from datetime import UTC, datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu import admin
from pos.menu.defs import Definitions, Entry, Item, Variant, money
from pos.menu.gloriafood import load_restaurant_menu
from pos.menu.seed import missing
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import Printer, PrintService
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts

from ..conftest import T0, servers_void
from ..printing.fake_printer import decode

DINNER = datetime(2026, 11, 16, 19, 0, tzinfo=UTC)

OPEN = {"variant_id": "OPEN:regular", "entry_id": "dinner:OPEN"}
LOBSTER = {"variant_id": "LOBSTER:regular", "entry_id": "dinner:LOBSTER"}
WINGS = {"variant_id": "WINGS:6pc"}


def typed_menu() -> Definitions:
    """The sample menu with an off-menu dish (Open Food, cooked at the wok) and a market-price one (Lobster)."""
    defs = load_definitions("restaurant")
    defs.add(
        Item("OPEN", "entrees", {"en": "Open Food"}, attrs={"asks_name": True}),
        Variant("OPEN:regular", "OPEN", "regular", {"en": "Regular"}, money(0)),
        Entry("dinner:OPEN", "dinner", "dinner/chefs", "OPEN", "OPEN"),
        Item("LOBSTER", "entrees", {"en": "Twin Lobsters"}, attrs={"asks_price": True}),
        Variant("LOBSTER:regular", "LOBSTER", "regular", {"en": "Regular"}, money(0)),
        Entry("dinner:LOBSTER", "dinner", "dinner/chefs", "LOBSTER", "L1"),
    )
    return defs


def client(*, voids: bool = False) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=MenuService(typed_menu(), now=lambda: DINNER),
            taxes=massachusetts(),
            printing=PrintService([Printer("wok", "10.0.0.1", id="wok")], direct=False),
            settings=servers_void() if voids else None,
        )
    )


def payload(op_id: str, kind: str, at: int, order_id: str = "o1", **data) -> dict:
    return {
        "op_id": op_id,
        "order_id": order_id,
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def send(c: TestClient, *ops: dict, order_id: str = "o1") -> dict:
    return c.post(f"/orders/{order_id}/ops", json=list(ops)).json()


def table(c: TestClient, order_id: str = "o1") -> None:
    assert (
        send(c, payload(f"{order_id}-open", "create", 0, order_id, table="12", guests=2, order_type="dine_in"))[
            "refused"
        ]
        == []
    )


def ring(c: TestClient, line_id: str, request: dict, at: int, order_id: str = "o1", **more) -> dict:
    more = {"by": "Amy", "by_id": "s1", **more}
    return send(
        c,
        payload(f"{order_id}-{line_id}", "add_line", at, order_id, line_id=line_id, item="?", request=request, **more),
        order_id=order_id,
    )


def entries(c: TestClient) -> dict[str, dict]:
    out: dict[str, dict] = {}

    def walk(sections: list[dict]) -> None:
        for section in sections:
            out.update({e["item"]: e for e in section["entries"]})
            walk(section["sections"])

    for menu in c.get("/menu").json()["menus"]:
        walk(menu["sections"])
    return out


# The menu ---------------------------------------------------------------------------------------------------


def test_the_menu_says_which_dishes_ask_and_no_other_dish_does():
    c = client()
    on_menu = entries(c)
    assert (on_menu["OPEN"]["asks_price"], on_menu["OPEN"]["asks_name"]) == (True, True)
    assert on_menu["LOBSTER"]["asks_price"] is True and "asks_name" not in on_menu["LOBSTER"]
    assert on_menu["OPEN"]["needs_choice"] and on_menu["LOBSTER"]["needs_choice"]  # a tap has to ask
    assert "asks_price" not in on_menu["WINGS"] and "asks_name" not in on_menu["WINGS"]
    detail = c.get("/menu/items/OPEN", params={"entry": "dinner:OPEN"}).json()
    assert (detail["asks_price"], detail["asks_name"]) == (True, True)
    assert "asks_price" not in c.get("/menu/items/WINGS").json()


def test_a_dish_that_asks_its_name_asks_its_price_as_well():
    item = Item("X", "entrees", {"en": "X"}, attrs={"asks_name": True})
    assert item.asks_name and item.asks_price
    assert not Item("Y", "entrees", {"en": "Y"}).asks_price


def test_the_preview_takes_what_was_typed():
    c = client()
    priced = c.post("/menu/price", json={**OPEN, "price": "18.5", "name": "  Lobster   ginger scallion "}).json()
    assert (priced["name"], priced["unit_price"], priced["problems"]) == ("Lobster ginger scallion", "18.50", [])
    assert priced["typed"] == {"price": "18.50", "menu_name": "Open Food", "name": "Lobster ginger scallion"}
    assert priced["tax_class"] == "prepared_food"
    assert [(k["station"], k["text"]) for k in priced["kitchen"]] == [("wok", "1 Lobster ginger scallion")]
    market = c.post("/menu/price", json={**LOBSTER, "price": "42"}).json()
    assert (market["name"], market["unit_price"], market["problems"]) == ("Twin Lobsters", "42.00", [])
    assert market["typed"] == {"price": "42.00", "menu_name": "Twin Lobsters"}


@pytest.mark.parametrize(
    ("request_", "codes"),
    [
        (OPEN, ["price_needed", "name_needed"]),
        ({**OPEN, "price": "12"}, ["name_needed"]),
        ({**OPEN, "price": "12", "name": "   "}, ["name_needed"]),
        ({**OPEN, "name": "Special"}, ["price_needed"]),
        ({**OPEN, "price": "", "name": "Special"}, ["price_needed"]),
        ({**OPEN, "price": "0", "name": "Special"}, ["bad_price"]),  # a free dish is a comp
        ({**OPEN, "price": "-5", "name": "Special"}, ["bad_price"]),
        ({**OPEN, "price": "12.345", "name": "Special"}, ["bad_price"]),
        ({**OPEN, "price": "twelve", "name": "Special"}, ["bad_price"]),
        ({**OPEN, "price": "NaN", "name": "Special"}, ["bad_price"]),
        ({**OPEN, "price": "1e999999", "name": "Special"}, ["bad_price"]),
        ({**OPEN, "price": "10000", "name": "Special"}, ["bad_price"]),  # 1895 for 18.95 is the likelier slip
        ({**OPEN, "price": "12", "name": "x" * 41}, ["bad_name"]),
        ({**OPEN, "price": "12", "name": "Special\x1b@"}, ["bad_name"]),  # nothing a printer could take as a command
        (LOBSTER, ["price_needed"]),
        ({**LOBSTER, "price": "42", "name": "Crab"}, ["name_fixed"]),  # it asks its price, not its name
        ({**WINGS, "price": "1.00"}, ["price_fixed"]),  # a dish with a price of its own
        ({**WINGS, "name": "Free wings"}, ["name_fixed"]),
    ],
)
def test_what_was_typed_is_checked(request_: dict, codes: list[str]):
    c = client()
    assert [p["code"] for p in c.post("/menu/price", json=request_).json()["problems"]] == codes
    table(c)
    answer = ring(c, "L1", request_, 1000)
    assert [r["error"] for r in answer["refused"]] == ["invalid_line"]
    assert [p["code"] for p in answer["refused"][0]["problems"]] == codes
    assert c.get("/orders/o1").json()["lines"] == {}  # nothing half-rung on the check


def test_the_most_a_typed_price_can_be_is_still_a_price():
    c = client()
    assert c.post("/menu/price", json={**LOBSTER, "price": "9999.99"}).json()["problems"] == []


# The check --------------------------------------------------------------------------------------------------


def test_a_typed_dish_stands_on_the_check_like_any_other():
    c = client()
    table(c)
    assert ring(c, "L1", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, 1000, qty=2)["refused"] == []
    assert ring(c, "L2", {**LOBSTER, "price": 42}, 2000)["refused"] == []  # a number does as well as its digits
    assert ring(c, "L3", WINGS, 3000)["refused"] == []
    order = c.get("/orders/o1").json()
    assert order["lines"]["L1"]["item"] == "Lobster ginger scallion"
    assert order["lines"]["L1"]["priced"]["typed"]["menu_name"] == "Open Food"
    assert order["lines"]["L1"]["request"]["price"] == "18.50"  # kept, so a screen can reopen the line
    check = c.get("/orders/o1/check").json()
    assert [(line["name"], line["qty"], line["unit_price"], line["total"]) for line in check["lines"]] == [
        ("Lobster ginger scallion", 2, "18.50", "37.00"),
        ("Twin Lobsters", 1, "42.00", "42.00"),
        ("Chicken wings", 1, "8.95", "8.95"),
    ]
    subtotal = Decimal("37.00") + Decimal("42.00") + Decimal("8.95")
    assert Decimal(check["subtotal"]) == subtotal
    # taxed like the dishes around it: nothing about a typed price sets it apart from a sale
    assert [line["tax_class"] for line in check["lines"]] == ["prepared_food"] * 3
    assert check["tax_rate_pct"] == "7.00" and [Decimal(t["base"]) for t in check["tax_lines"]] == [subtotal] * 2
    assert Decimal(check["total"]) == subtotal + Decimal(check["tax"])
    assert check["unpriced"] == []


def test_a_screen_cannot_price_a_dish_by_saying_it_did():
    c = client()
    table(c)
    # the terminal's own `priced` is dropped, as ever: the wings cost what the menu says
    assert ring(c, "L1", WINGS, 1000, priced={"name": "Wings", "unit_price": "0.01"})["refused"] == []
    # and a typed dish costs what was typed, whatever `priced` came along with it
    typed = {**OPEN, "price": "30", "name": "Whole fish"}
    assert ring(c, "L2", typed, 2000, priced={"name": "Whole fish", "unit_price": "3.00"})["refused"] == []
    check = c.get("/orders/o1/check").json()
    assert [(line["name"], line["unit_price"]) for line in check["lines"]] == [
        ("Chicken wings", "8.95"),
        ("Whole fish", "30.00"),
    ]


def test_same_again_rings_a_typed_dish_as_it_was():
    c = client()
    table(c)
    ring(c, "L1", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, 1000)
    again = c.get("/orders/o1/again").json()
    assert again["missing"] == []
    (line,) = again["lines"]
    assert (line["item"], line["unit_price"], line["was"]) == ("Lobster ginger scallion", "18.50", "18.50")
    assert (line["request"]["price"], line["request"]["name"]) == ("18.50", "Lobster ginger scallion")


# The kitchen and the bill -----------------------------------------------------------------------------------


def test_the_kitchen_reads_what_was_typed_and_the_bill_prints_it():
    c = client()
    table(c)
    ring(c, "L1", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, 1000)
    ring(c, "L2", {**LOBSTER, "price": "42"}, 2000)
    send(c, payload("fire", "fire", 3000, course="*"))
    ticket = " ".join(" ".join(decode(c.app.state.printing.store.get("fire:wok").data).text).split())
    assert "Lobster ginger scallion" in ticket and "Twin Lobsters" in ticket
    assert "Open Food" not in ticket  # what the cook has to read is what was typed
    answer = c.post("/orders/o1/bill", json={"device": "t1"}).json()
    bill = [line.rstrip() for line in decode(c.app.state.printing.store.get(answer["job_id"]).data).text]
    assert any(line.startswith("1  Lobster ginger scallion") and line.endswith("18.50") for line in bill)
    assert any(line.startswith("1  Twin Lobsters") and line.endswith("42.00") for line in bill)


# The report -------------------------------------------------------------------------------------------------


def report(c: TestClient, **params: int) -> dict:
    return c.get("/reports/adjustments", params=params).json()


def test_the_report_lists_every_dish_sold_at_a_typed_price():
    c = client()
    table(c)
    ring(c, "L1", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, 1000, qty=2)
    ring(c, "L2", {**LOBSTER, "price": "42"}, 2000, by="Ben", by_id="s2")
    ring(c, "L3", WINGS, 3000)  # a dish with its own price is not one
    answer = report(c)
    assert [
        (t["order_id"], t["table"], t["line_id"], t["item"], t["menu_name"], t["named"], t["qty"], t["unit_price"])
        for t in answer["typed"]
    ] == [
        ("o1", "12", "L1", "Lobster ginger scallion", "Open Food", True, 2, "18.50"),
        ("o1", "12", "L2", "Twin Lobsters", "Twin Lobsters", False, 1, "42.00"),
    ]
    assert [(t["amount"], t["by"], t["by_id"], t["at_ms"], t["voided"], t["status"]) for t in answer["typed"]] == [
        ("37.00", "Amy", "s1", T0 + 1000, False, "open"),
        ("42.00", "Ben", "s2", T0 + 2000, False, "open"),
    ]
    assert (answer["typed_total"], answer["typed_count"]) == ("79.00", 2)
    assert answer["typed_by_staff"] == [
        {"key": "Ben", "amount": "42.00", "count": 1},
        {"key": "Amy", "amount": "37.00", "count": 1},
    ]
    assert [t["line_id"] for t in report(c, since=T0 + 1500)["typed"]] == ["L2"]  # by when it was rung in


def test_a_typed_dish_taken_off_or_voided_does_not_count_as_sold():
    c = client(voids=True)
    table(c)
    ring(c, "L1", {**OPEN, "price": "18.50", "name": "Lobster ginger scallion"}, 1000)
    ring(c, "L2", {**OPEN, "price": "9", "name": "Side of greens"}, 2000)
    ring(c, "L3", {**LOBSTER, "price": "42"}, 3000)
    send(c, payload("off", "void_line", 4000, line_id="L1", by="Amy"))  # before it was sent: simply off
    send(c, payload("fire", "fire", 5000, course="*"))
    send(c, payload("void", "void_line", 6000, line_id="L2", reason="kitchen-error", by="Amy"))  # after: a void
    answer = report(c)
    assert [(t["line_id"], t["voided"], t["amount"]) for t in answer["typed"]] == [
        ("L2", True, "0.00"),
        ("L3", False, "42.00"),
    ]
    assert (answer["typed_total"], answer["typed_count"]) == ("42.00", 1)
    assert answer["typed_by_staff"] == [{"key": "Amy", "amount": "42.00", "count": 1}]
    # each is where it belongs: the one taken off with the dishes taken off, the void with the voids
    assert [t["line_id"] for t in answer["taken_off"]] == ["L1"]
    assert [(v["line_id"], v["item"], v["amount"]) for v in answer["voids"]] == [("L2", "Side of greens", "9.00")]


# The menu editor and the restaurant's own menu --------------------------------------------------------------


def test_the_menu_editor_turns_asking_on_and_off():
    defs = load_definitions("restaurant")
    wings = admin.encode(defs.items["WINGS"])
    asking = admin.apply(defs, [{"kind": "item", "op": "put", "data": {**wings, "attrs": {"asks_price": True}}}])
    assert admin.problems(asking) == admin.problems(defs)  # nothing the menu check minds
    menu = MenuService(asking, now=lambda: DINNER)
    assert menu.priced({**WINGS, "price": "11.5"})["unit_price"] == "11.50"
    assert [p["code"] for p in menu.priced(WINGS)["problems"]] == ["price_needed"]
    back = admin.apply(asking, [{"kind": "item", "op": "put", "data": {**wings, "attrs": {}}}])
    assert MenuService(back, now=lambda: DINNER).priced(WINGS)["unit_price"] == "8.95"


def test_the_old_pos_s_open_dishes_are_on_the_menu():
    defs, _ = load_restaurant_menu()
    menu = MenuService(defs, now=lambda: DINNER)
    stations = {}
    for code, name in (("FF", "Open Food"), ("89", "Open Soup"), ("SS", "Open Sushi"), ("DD", "Open Drink")):
        item = defs.items[code]
        assert item.names == {"en": name} and item.asks_name and item.asks_price
        (variant,) = defs.variants_of(code)
        (entry,) = [e for e in defs.entries if e.item == code]
        priced = menu.priced({"variant_id": variant.id, "entry_id": entry.id, "price": "12", "name": "Chef's own"})
        assert (priced["name"], priced["unit_price"], priced["problems"]) == ("Chef's own", "12.00", [])
        stations[code] = [k["station"] for k in priced["kitchen"]]
    assert stations == {"FF": ["wok1"], "89": ["soup"], "SS": ["sushi"], "DD": ["bar"]}
    assert not defs.items["A18"].asks_price  # and no other dish of the old POS asks anything


def test_a_running_hub_takes_the_open_dishes_with_a_menu_import():
    bundled, _ = load_restaurant_menu()
    stored = admin.copy_of(bundled)
    for code in ("FF", "89", "SS", "DD"):
        del stored.items[code]
        del stored.variants[f"{code}:regular"]
    stored.entries = [e for e in stored.entries if e.item not in ("FF", "89", "SS", "DD")]
    stored.variants["A18:regular"] = replace(stored.variants["A18:regular"], base_price=money("19.95"))  # the editor's
    merged, added = missing(stored, bundled)
    assert {"item FF", "variant FF:regular", "entry dinner:FF", "item DD", "entry drinks:DD"} <= set(added)
    assert merged.items["FF"].asks_name and merged.variants["A18:regular"].base_price == money("19.95")
    assert admin.problems(merged) == ([], [])
