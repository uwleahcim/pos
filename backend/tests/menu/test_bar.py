"""Everything in bar.json is on the menu: bottles by the pour, wine by the glass and bottle, cocktails, beer prices."""

from __future__ import annotations

import json
from decimal import Decimal as D

import pytest

from pos.menu.bar import BAR, FIRST_SORT, import_bar
from pos.menu.defs import Category, Definitions, Entry, Item, Menu, Section, Station, Variant, money
from pos.menu.engine import MenuEngine
from pos.menu.gloriafood import BUNDLED, STATIONS, load_gloriafood, load_restaurant_menu, settings_from
from pos.menu.request import LineRequest, Selection


def listed() -> list[dict]:
    """The file's items, each with its category and the size code it sells in when it lists no sizes."""
    data = json.loads(BAR.read_text(encoding="utf-8"))
    return [
        {**item, "category": cat["code"], "size": (cat.get("pour") or data["pour"])["code"]}
        for cat in data["categories"]
        for item in cat["items"]
    ]


def bottles() -> list[dict]:
    return [item for item in listed() if "retail_750" in item]


def prices_of(item: dict) -> dict[str, float]:
    return {s["code"]: s["price"] for s in item["sizes"]} if "sizes" in item else {item["size"]: item["price"]}


def test_everything_in_the_file_sells_at_the_bar_at_its_price():
    defs, report = load_restaurant_menu()
    engine = MenuEngine(defs)
    assert engine.check() == []
    assert any(note.startswith("bar: 12 categories") for note in report.notes)
    items = listed()
    assert len(bottles()) >= 95 and len(items) >= len(bottles()) + 45  # the wine, sake, cocktails and a beer
    for listed_item in items:
        code = listed_item["code"]
        item = defs.items[code]
        assert item.category == listed_item["category"] and defs.categories[item.category].station == "bar"
        variants = defs.variants_of(code)
        assert {v.code: v.base_price for v in variants} == {c: D(str(p)) for c, p in prices_of(listed_item).items()}
        for variant in variants:
            line = engine.resolve(LineRequest(variant.id))
            assert line.ok, line.problems
            sold = (line.line_total, line.tax_class, line.kitchen_lines[0].station)
            assert sold == (variant.base_price, listed_item.get("tax_class", "alcohol"), "bar"), code
        assert item.attrs["bar"] is True
        if "retail_750" in listed_item:
            assert item.attrs["retail_750"] == listed_item["retail_750"]


def test_pours_end_in_45_or_95_and_well_brands_are_the_cheapest():
    well = [p for b in bottles() if b.get("well") for p in prices_of(b).values()]
    called = [p for b in bottles() if not b.get("well") for p in prices_of(b).values()]
    assert well and called
    for price in well + called:
        assert round(price * 100) % 100 in (45, 95), price
    assert max(well) < min(called)


def test_the_bar_sections_come_last_on_the_drinks_menu_and_offer_how_a_pour_is_served():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    drinks = next(m for m in engine.menu_for("pos") if m.menu == "drinks")
    names = [s.name for s in drinks.sections]
    assert names[-12:] == [
        "White Wine", "Red Wine", "Sparkling Wine", "Sake & Plum Wine", "Whiskey", "Vodka", "Gin", "Rum",
        "Tequila", "Cognac & Brandy", "Liqueurs & Cordials", "Aperitifs & Vermouth",
    ]  # fmt: skip
    food = next(m for m in engine.menu_for("pos") if m.menu == "dinner")
    assert not {s.name for s in food.sections} & set(names[-12:])  # the Food menu sells none of it
    whiskey = next(s for s in drinks.sections if s.name == "Whiskey")
    entry = next(e for e in whiskey.entries if e.name == "Maker's Mark")
    assert entry.number is None and [(v.name, v.price) for v in entry.variants] == [("1.5 oz", D("8.95"))]
    served = defs.groups["served"]
    assert (served.min_select, served.max_select) == (0, 1)
    rocks = engine.resolve(LineRequest("makers_mark:pour", 1, None, (Selection("served", "served:rocks"),)))
    assert rocks.ok and rocks.line_total == D("8.95") and "ROCKS" in rocks.kitchen_lines[0].text
    neat = engine.resolve(LineRequest("makers_mark:pour"))
    assert neat.ok and "ROCKS" not in neat.kitchen_lines[0].text
    assert [g.code for g, _ in defs.attachments_for("hibiki_21")] == ["served", "drink_options"]  # + the original POS's
    assert [v.names["en"] for v in defs.variants_of("hibiki_21")] == ["1 oz"]
    # wine by the glass and the bottle, or the bottle alone, as the printed list has it
    white = next(s for s in drinks.sections if s.name == "White Wine")
    riesling = next(e for e in white.entries if e.name == "Riesling, Schlink Haus")
    assert [(v.name, v.price) for v in riesling.variants] == [("Glass", D("9")), ("Bottle", D("32"))]
    assert [v.code for v in defs.variants_of("merlot_wente")] == ["bottle"]
    halves = [(v.code, v.base_price) for v in defs.variants_of("pinot_grigio_santa_margherita")]
    assert halves == [("half", D("25")), ("bottle", D("50"))]
    assert [g.code for g, _ in defs.attachments_for("riesling_schlink_haus")] == ["drink_options"]  # the original POS's
    # sake comes hot or cold, and does not ask rocks or neat
    assert [g.code for g, _ in defs.attachments_for("sake_gekkeikan")] == ["temperature", "drink_options"]
    hot = engine.resolve(LineRequest("sake_gekkeikan:regular", 1, None, (Selection("temperature", "temperature:hot"),)))
    assert hot.ok and hot.line_total == D("8") and "HOT" in hot.kitchen_lines[0].text


def test_the_printed_cocktails_and_beer_prices_join_the_export_s_own_categories():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    drinks = next(m for m in engine.menu_for("pos") if m.menu == "drinks")
    mixed = next(s for s in drinks.sections if s.name == "Mixed Drinks")
    names = [e.name for e in mixed.entries]
    assert names[:4] == ["Mai Tai (to go)", "White Mai Tai", "Scorpion Bowl for 1", "Zombie"]  # the export's first
    # 26 from the printed list, 26 from the original POS, and its Open Drink
    assert "China Sky Rita" in names and len(names) == 53
    zombie = next(e for e in mixed.entries if e.name == "Zombie")
    assert zombie.number is None and [(v.name, v.price) for v in zombie.variants] == [("Regular", D("9.25"))]
    assert defs.items["zombie"].description["en"].startswith("Dark and light rums")
    sold = engine.resolve(LineRequest("zombie:regular"))
    assert sold.ok and (sold.line_total, sold.tax_class, sold.kitchen_lines[0].station) == (D("9.25"), "alcohol", "bar")
    # the export's beers keep their codes, at the printed prices; the export alone still says 4.00
    export, _ = load_gloriafood(BUNDLED, settings_from(STATIONS))
    budweiser = (export.variants["E01:regular"].base_price, defs.variants["E01:regular"].base_price)
    assert budweiser == (D("4.00"), D("5.50"))
    assert defs.variants["E09:regular"].base_price == D("6.50")
    foreign = next(s for s in drinks.sections if s.name == "Foreign Beer")
    assert [e.name for e in foreign.entries][-2:] == ["Non-Alcoholic Beer", "Tsing Tao (can)"]  # the original POS last
    na = engine.resolve(LineRequest("na_beer:regular"))
    assert na.ok and na.line_total == D("6.50") and na.tax_class == "prepared_food"


def _bare() -> Definitions:
    return Definitions().add(Menu("dinner", {"en": "Menu"}, ("pos",)), Station("bar", {"en": "Bar"}, ("bar",)))


def test_a_hidden_bottle_stays_in_the_catalog_but_off_the_order_screen():
    defs = _bare()
    report = import_bar(
        defs,
        {
            "menu": "dinner",
            "station": "bar",
            "categories": [
                {
                    "code": "gin",
                    "name": "Gin",
                    "items": [
                        {"code": "old_tom", "name": "Old Tom", "price": 7.95, "visible": False},
                        {"code": "plymouth", "name": "Plymouth", "price": 8.45, "description": "Navy strength"},
                    ],
                }
            ],
        },
    )
    assert (report.categories, report.items, report.prices) == (1, 2, 0)
    assert defs.categories["gin"].sort == FIRST_SORT and defs.categories["gin"].tax_class == "alcohol"
    assert set(defs.items) == {"old_tom", "plymouth"} and defs.items["plymouth"].description == {"en": "Navy strength"}
    engine = MenuEngine(defs)
    assert engine.check() == []
    gin = engine.menu_for("pos")[0].sections[0]
    assert [e.name for e in gin.entries] == ["Plymouth"]
    assert engine.resolve(LineRequest("old_tom:pour")).ok  # still sellable by its code, like any hidden entry


def test_items_can_join_a_category_the_menu_already_has_and_prices_can_move():
    defs = _bare().add(
        Category("beer", {"en": "Beer"}, station="bar", sort=7),
        Section("dinner/beer", "dinner", {"en": "Beer"}, sort=7),
        Item("E1", "beer", {"en": "Lager"}, tax_class="alcohol"),
        Entry("dinner:E1", "dinner", "dinner/beer", "E1", "E1", sort=7000),
        Variant("E1:regular", "E1", "regular", {"en": "Regular"}, money(4)),
    )
    report = import_bar(
        defs,
        {
            "categories": [
                {
                    "code": "beer",
                    "existing": True,
                    "pour": {"code": "regular", "name": "Regular"},
                    "items": [{"code": "na", "name": "Near Beer", "price": 6.5, "tax_class": "prepared_food"}],
                }
            ],
            "prices": [{"variant": "E1:regular", "price": 5.5}],
        },
    )
    assert (report.categories, report.items, report.prices) == (0, 1, 1)
    assert defs.variants["E1:regular"].base_price == D("5.50") and defs.variants["na:regular"].base_price == D("6.50")
    assert defs.items["na"].category == "beer" and defs.items["na"].tax_class == "prepared_food"
    engine = MenuEngine(defs)
    assert engine.check() == []
    beer = engine.menu_for("pos")[0].sections[0]
    assert [e.name for e in beer.entries] == ["Lager", "Near Beer"]
    assert engine.resolve(LineRequest("na:regular")).tax_class == "prepared_food"


def test_a_code_already_on_the_menu_or_an_unknown_group_is_refused():
    defs = _bare()
    data = {"categories": [{"code": "gin", "name": "Gin", "items": [{"code": "x", "name": "X", "price": 7.95}]}]}
    import_bar(defs, data)
    with pytest.raises(ValueError, match="category 'gin' already exists"):
        import_bar(defs, data)
    with pytest.raises(ValueError, match="unknown station"):
        import_bar(_bare(), {"station": "patio", "categories": []})
    with pytest.raises(ValueError, match="unknown group 'served'"):
        import_bar(_bare(), {"categories": [{"code": "gin", "name": "Gin", "groups": ["served"], "items": []}]})
    with pytest.raises(ValueError, match="marked existing"):
        import_bar(_bare(), {"categories": [{"code": "beer", "existing": True, "items": []}]})
    with pytest.raises(ValueError, match="unknown variant"):
        import_bar(_bare(), {"categories": [], "prices": [{"variant": "E1:regular", "price": 5.5}]})
