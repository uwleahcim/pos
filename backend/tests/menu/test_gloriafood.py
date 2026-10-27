"""The restaurant's online-ordering export imports into a menu the engine can sell from."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal as D
from zoneinfo import ZoneInfo

from pos.menu.engine import MenuEngine
from pos.menu.gloriafood import ImportSettings, import_gloriafood, load_restaurant_menu, split_number
from pos.menu.request import LineRequest, Selection

BOSTON = ZoneInfo("America/New_York")


def test_numbers_come_off_the_names():
    assert split_number("L01:   Sweet & Sour Chicken") == ("L01", "Sweet & Sour Chicken")
    assert split_number("02   Kaniyu") == ("02", "Kaniyu")
    assert split_number("801:   Miso Soup") == ("801", "Miso Soup")
    assert split_number("Gift Certificate") == (None, "Gift Certificate")


def test_the_bundled_menu_loads_clean():
    defs, report = load_restaurant_menu()
    engine = MenuEngine(defs)
    assert engine.check() == []
    assert report.items > 290 and report.groups == 12
    assert not [n for n in report.notes if "no station" in n or "unknown station" in n]
    assert {s for s in defs.stations} == {
        "wok1", "wok2", "wok3", "broiler", "range", "fryer", "sushi", "bar", "takeout", "soup", "soda",
    }  # fmt: skip
    # beer is off online but sold at the bar; the inactive orange juice stays out
    assert defs.items["E09"].names["en"] == "Tsing Tao" and defs.inherited(defs.items["E09"], "tax_class") == "alcohol"
    assert not any(item.names["en"] == "Orange Juice" for item in defs.items.values())
    assert (
        sorted(i.names["en"] for i in defs.items.values() if i.tax_class == "gift_card")[0] == "Gift Certificate $100"
    )


def test_dishes_price_and_route_to_their_stations():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)

    def sell(variant, *selections):
        line = engine.resolve(LineRequest(variant, 1, None, tuple(Selection(g, o) for g, o in selections)))
        assert line.ok, line.problems
        return line

    chicken = sell("C01:regular")  # the category's rice group defaults to white rice
    assert (chicken.line_total, chicken.kitchen_lines[0].station) == (D("17.95"), "wok1")
    assert "White Rice" in chicken.kitchen_lines[0].text
    assert sell("K01:regular").kitchen_lines[0].station == "sushi"
    assert sell("I42:regular").kitchen_lines[0].station == "broiler"
    assert sell("E09:regular").kitchen_lines[0].station == "bar"
    sauce = [v for v in defs.variants_of("Y21")]
    assert [(v.names["en"], v.base_price) for v in sauce][:2] == [("Small", D("0.00")), ("Medium", D("1.75"))]

    rice = next(g for g in defs.groups.values() if g.names["en"] == "Rice")
    brown = next(o for o in defs.options_of(rice.code) if o.names["en"] == "Brown Rice")
    assert "Brown Rice" in sell("C01:regular", (rice.code, brown.id)).kitchen_lines[0].text

    roll_group = next(g for g in defs.groups.values() if g.names["en"] == "Roll")
    assert (roll_group.min_select, roll_group.max_select) == (3, 3)


def test_lunch_is_its_own_menu_on_weekday_lunch_hours():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    tuesday_noon = datetime(2026, 10, 27, 12, 0, tzinfo=BOSTON)
    tuesday_night = datetime(2026, 10, 27, 19, 0, tzinfo=BOSTON)
    sunday_noon = datetime(2026, 11, 1, 12, 0, tzinfo=BOSTON)
    assert [m.menu for m in engine.menu_for("pos", tuesday_noon)] == ["lunch", "dinner"]
    assert [m.menu for m in engine.menu_for("pos", tuesday_night)] == ["dinner"]
    assert [m.menu for m in engine.menu_for("pos", sunday_noon)] == ["dinner"]


def test_unmapped_categories_go_to_the_default_and_are_reported():
    data = {
        "currency": "USD",
        "categories": [
            {
                "id": 1,
                "name": "Noodles",
                "sort": 0,
                "active": True,
                "groups": [],
                "items": [{"id": 9, "name": "N1: Lo Mein", "price": 9.5, "active": True, "sizes": [], "groups": []}],
            }
        ],
    }
    settings = ImportSettings(stations={"wok1": {"en": "Wok 1"}}, default_station="wok1")
    defs, report = import_gloriafood(data, settings)
    assert defs.inherited(defs.items["N1"], "station") == "wok1"
    assert any("no station set" in n for n in report.notes)
