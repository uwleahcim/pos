"""Dish names in two languages on the screens (docs/dish-names.md): the menu says a category's other name as
it says a dish's, and a dish rung by a screen that shows Chinese is recorded as every other dish is."""

from __future__ import annotations

from dataclasses import replace
from datetime import UTC, datetime

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu.gloriafood import load_restaurant_menu
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import PrintService
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts

from ..conftest import T0

DINNER = datetime(2026, 10, 30, 19, 0, tzinfo=UTC)  # a Friday evening: the lunch menu is closed


def client(defs=None) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=MenuService(defs or load_definitions("restaurant"), now=lambda: DINNER),
            taxes=massachusetts(),
            printing=PrintService([]),
        )
    )


def sections(c: TestClient, **params) -> dict:
    return {s["section_id"]: s for s in c.get("/menu", params=params).json()["menus"][0]["sections"]}


def test_a_category_says_its_other_name_as_a_dish_does():
    c = client()
    chefs = sections(c)["dinner/chefs"]
    assert (chefs["name"], chefs["second_name"]) == ("Chef's Specials", "招牌菜")
    gtc = next(e for e in chefs["entries"] if e["item"] == "GTC")
    assert (gtc["name"], gtc["second_name"]) == ("General Tso's Chicken", "左宗棠鸡")

    # asked in Chinese, the two change places
    chefs = sections(c, locale="zh")["dinner/chefs"]
    assert (chefs["name"], chefs["second_name"]) == ("招牌菜", "Chef's Specials")


def test_a_category_with_no_chinese_name_says_none():
    defs = load_definitions("restaurant")
    defs.sections["dinner/apps"] = replace(defs.sections["dinner/apps"], names={"en": "Appetizers"})
    c = client(defs)
    apps = sections(c)["dinner/apps"]
    assert (apps["name"], apps["second_name"]) == ("Appetizers", None)


def test_the_restaurants_menu_names_its_categories_in_chinese():
    defs, _ = load_restaurant_menu()
    menu = MenuService(defs, now=lambda: DINNER)
    named = {}

    def walk(rows):
        for row in rows:
            named[row["name"]] = row["second_name"]
            walk(row["sections"])

    for m in menu.menus():
        walk(m["sections"])
    assert named["Chicken"] == "雞" and named["Soup"] == "湯"
    assert sum(1 for other in named.values() if other) >= 30  # most of them; the rest stay English


def test_a_dish_is_recorded_in_english_whatever_the_screen_called_it():
    """A screen showing Chinese names sends the dish as every screen does. Were it to send the Chinese name,
    the hub's menu names the line all the same: the bill, the reports and the next screen read one name."""
    c = client()
    ops = [
        {
            "op_id": op_id,
            "order_id": "o1",
            "hlc": str(HLC(T0 + at, 0, "t1")),
            "device": "t1",
            "kind": kind,
            "data": data,
        }
        for op_id, kind, at, data in [
            ("a", "create", 0, {"table": "12", "guests": 2, "order_type": "dine_in"}),
            (
                "b",
                "add_line",
                1,
                {
                    "line_id": "L1",
                    "item": "左宗棠鸡",
                    "qty": 1,
                    "request": {"variant_id": "GTC:quart", "entry_id": "dinner:87"},
                },
            ),
        ]
    ]
    assert c.post("/orders/o1/ops", json=ops).status_code == 202
    line = c.get("/orders/o1").json()["lines"]["L1"]
    assert line["item"] == "General Tso's Chicken (Quart)"
    # and the line carries both names, so a screen can show either without asking the menu again
    assert line["priced"]["names"]["en"] == "General Tso's Chicken"
    assert line["priced"]["names"]["zh"] == "左宗棠鸡"
    assert c.get("/orders/o1/check").json()["lines"][0]["name"] == "General Tso's Chicken (Quart)"
