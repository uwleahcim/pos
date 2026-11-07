"""The restaurant's online-ordering export imports into a menu the engine can sell from."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal as D
from zoneinfo import ZoneInfo

import pytest

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
    assert [m.menu for m in engine.menu_for("pos", tuesday_noon)] == ["lunch", "dinner", "drinks"]
    assert [m.menu for m in engine.menu_for("pos", tuesday_night)] == ["dinner", "drinks"]
    assert [m.menu for m in engine.menu_for("pos", sunday_noon)] == ["dinner", "drinks"]


def test_the_drinks_are_their_own_menu_and_the_soft_drinks_are_on_both():
    """menus.json: the drink categories leave the Food menu for Drinks; Beverages (tea, soda) stays on Food too.
    Where a drink prints is the category's station, not the menu: everything on Drinks goes to the bar or the
    soda station, never to a wok."""
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    tuesday_night = datetime(2026, 10, 27, 19, 0, tzinfo=BOSTON)  # Lunch closed; the clock would open it at lunch
    menus = {m.menu: m for m in engine.menu_for("pos", tuesday_night)}
    assert [(m.name, m.priority) for m in menus.values()] == [("Food", 0), ("Drinks", -10)]
    food = [s.name for s in menus["dinner"].sections]
    drinks = [s.name for s in menus["drinks"].sections]
    assert drinks[:6] == ["Mixed Drinks", "Beverages", "Domestic Beer", "Foreign Beer", "White Wine", "Red Wine"]
    assert food[:2] == ["Appetizers", "Soup"] and "Beverages" in food and "Gift Certificates" in food
    assert not {"Mixed Drinks", "Domestic Beer", "Foreign Beer", "White Wine", "Red Wine", "Whiskey"} & set(food)
    assert "Lunch Specials" not in food and "Lunch Specials" not in drinks
    soda = next(s for s in menus["drinks"].sections if s.name == "Beverages")
    also = next(s for s in menus["dinner"].sections if s.name == "Beverages")
    assert [e.item for e in soda.entries] == [e.item for e in also.entries] and soda.entries
    assert {e.entry_id.split(":")[0] for e in soda.entries + also.entries} == {"drinks", "dinner"}
    assert {e.number for e in soda.entries} == {e.number for e in also.entries}  # the same numbers on both
    stations = {defs.inherited(defs.items[e.item], "station") for s in menus["drinks"].sections for e in s.entries}
    assert stations == {"bar", "soda"}
    assert defs.menus["drinks"].schedule == {} and defs.menus["drinks"].channels == ("pos", "phone")


def test_menus_json_names_exactly_one_default_menu(tmp_path):
    from pos.menu.gloriafood import MenuSpec, menus_from

    path = tmp_path / "menus.json"
    path.write_text('{"menus": [{"code": "a", "names": {"en": "A"}}, {"code": "b", "names": {"en": "B"}}]}')
    with pytest.raises(ValueError, match="exactly one"):
        menus_from(path)
    path.write_text('{"menus": [{"code": "a", "names": {"en": "A"}, "default": true, "categories": ["Soup"]}]}')
    assert menus_from(path) == (MenuSpec("a", {"en": "A"}, default=True, categories=("Soup",)),)
    settings = ImportSettings(menus=menus_from(path))
    assert [m.code for m in settings.menus_for("Soup")] == ["a"] and [m.code for m in settings.menus_for("x")] == ["a"]


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


def test_the_soup_choice_is_the_soup_and_the_maki_combination_offers_the_rolls():
    """groups.json: the lunch specials' soup group links to the dishes of the Soup category ("No Soup" stays a
    word), and the maki combination's Roll group offers the Roll category itself instead of the export's copies."""
    defs, report = load_restaurant_menu()
    assert report.linked == 28  # 4 soups in each of two soup groups, 20 rolls
    soup = defs.groups["soup_929530"]
    assert [(defs.option_names(o).get("en"), o.linked_variant) for o in defs.options_of(soup.code)] == [
        ("Miso Soup", "801:regular"),
        ("Wonton Soup", "802:regular"),
        ("Hot & Sour Soup", "803:regular"),
        ("Egg Drop Soup", "804:regular"),
        ("No Soup", None),
    ]
    engine = MenuEngine(defs)
    line = engine.resolve(LineRequest("L01:regular", 1, "lunch:L01", (Selection(soup.code, "soup_929530:4904287"),)))
    assert line.ok and line.line_total == D("14.95")
    assert [(k.station, k.text, k.header) for k in line.kitchen_lines] == [
        ("wok1", "1 Sweet & Sour Chicken · White Rice · Miso Soup", None),
        ("soup", "1 Miso Soup", "L01 Sweet & Sour Chicken"),
    ]
    roll = defs.groups["roll_934419"]
    assert roll.source_category == "roll_maki" and (roll.min_select, roll.max_select) == (3, 3)
    assert [o.linked_variant for o in defs.options_of(roll.code)] == [f"K{n:02d}:regular" for n in range(1, 21)]
    assert all(o.names == {} for o in defs.options_of(roll.code))  # called what the rolls are called
    assert [n for n in report.notes if "kept as a word" in n] == [
        "group 'Soup': option 'No Soup' is not a dish of soup; kept as a word",
        "group 'Sushi Soup': option 'No Soup' is not a dish of soup; kept as a word",
    ]
