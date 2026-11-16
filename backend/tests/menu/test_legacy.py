"""What the restaurant's original POS knew is on the menu: Chinese names and kitchen labels, the dishes the
online export never had, the dining room's prices, and the original POS's modifier groups."""

from __future__ import annotations

import json
from datetime import datetime
from decimal import Decimal as D
from zoneinfo import ZoneInfo

import pytest

from pos.menu import admin
from pos.menu.bar import add_bar
from pos.menu.defs import Definitions
from pos.menu.engine import MenuEngine
from pos.menu.gloriafood import BUNDLED, STATIONS, load_gloriafood, load_restaurant_menu, settings_from
from pos.menu.legacy import LEGACY, add_legacy, import_legacy, kitchen_label
from pos.menu.request import LineRequest, Selection
from pos.menu.service import MenuService


def legacy() -> dict:
    return json.loads(LEGACY.read_text(encoding="utf-8"))


def export_and_bar() -> Definitions:
    defs = load_gloriafood(BUNDLED, settings_from(STATIONS))[0]
    add_bar(defs)
    return defs


def sell(engine: MenuEngine, variant: str, *selections: tuple[str, str] | tuple[str, str, str], entry=None):
    chosen = tuple(Selection(s[0], s[1], prefix=s[2]) if len(s) == 3 else Selection(s[0], s[1]) for s in selections)
    line = engine.resolve(LineRequest(variant, 1, entry, chosen))
    assert line.ok, line.problems
    return line


def test_the_label_the_kitchen_reads_is_the_chinese_name_then_the_original_pos_s_label():
    assert kitchen_label("腰果蝦", "SHMP CASHEW r") == "腰果蝦 SHMP CASHEW r"
    assert kitchen_label("腰果蝦", None) == "腰果蝦"
    assert kitchen_label(None, "sr:KAPPA MAKI") == "sr:KAPPA MAKI"
    assert kitchen_label(None, None) is None


def test_the_whole_menu_loads_clean_with_everything_the_file_adds():
    defs, report = load_restaurant_menu()
    assert MenuEngine(defs).check() == []
    assert admin.problems(defs) == ([], [])
    note = report.notes[-1]
    assert note.startswith("original POS: 266 dishes named, 13 re-stationed, 93 dishes added, 10 prices set, 10 groups")
    data = legacy()
    # "Take out" under Preparation (and under the sauces) sends the dish to the takeout station as well
    take_out = [o for o in defs.options.values() if o.code == "take_out"]
    assert len(take_out) == 2 and {o.routes_to for o in take_out} == {"takeout"}
    for code, spec in data["items"].items():
        item = defs.items[code]
        assert item.names.get("zh") == spec.get("zh")
        assert item.names.get("kitchen") == kitchen_label(spec.get("zh"), spec.get("kitchen"))
        if "station" in spec:
            assert item.station == spec["station"]
    for spec in data["new"]:
        item = defs.items[spec["code"]]
        asks = {f"asks_{spec['asks']}": True} if "asks" in spec else {}  # an open dish: its name and price typed
        assert item.names["en"] == spec["name"] and item.attrs == {"legacy_pos": True, **asks}
        assert [v.base_price for v in defs.variants_of(item.code)] == [D(str(spec["price"]))]
        sections = {e.section for e in defs.entries if e.item == item.code}
        assert sections and all(s.endswith(f"/{item.category}") for s in sections)
        assert all(e.number == item.code for e in defs.entries if e.item == item.code)
    for change in data["prices"]:
        assert defs.variants[change["variant"]].base_price == D(str(change["price"]))
    for code, group in data["groups"].items():
        assert len(defs.options_of(code)) == len(group["options"])
        for opt in group["options"]:
            held = defs.options[f"{code}:{opt['code']}"]
            assert held.kitchen_label == opt.get("kitchen_label") and held.price == D(str(opt.get("price") or 0))


def test_dishes_print_in_chinese_with_the_old_label_and_cook_where_the_original_pos_sent_them():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    chicken = sell(engine, "C01:regular")  # the original POS fried it at the appetizer station, not the wok
    assert chicken.kitchen_lines[0].station == "fryer"
    assert chicken.kitchen_lines[0].text.startswith("1 甜酸雞 SWT&SOUR CHKN r")
    assert defs.categories["soup"].names == {"en": "Soup", "zh": "湯"}
    lunch = sell(engine, "L01:regular", entry="lunch:L01")  # the lunch special and its soup, both in Chinese
    assert [(k.station, k.text) for k in lunch.kitchen_lines] == [
        ("wok1", "1 L甜酸雞 LUN:SWEET & SOUR CHKN"),
        ("soup", "1 日本湯 MISO SOUP"),
    ]
    assert sell(engine, "A15:regular").kitchen_lines[0].station == "wok1"  # the soongs left the fryer
    assert sell(engine, "L21:regular").kitchen_lines[0].station == "sushi"  # the sushi lunches left the wok
    assert sell(engine, "I42:regular").kitchen_lines[0].station == "broiler"  # the teriyaki stays with its category
    lunchtime = datetime(2026, 10, 28, 12, 15, tzinfo=ZoneInfo("America/New_York"))  # a Wednesday
    zh = {s.name for m in engine.menu_for("pos", lunchtime, locale="zh") for s in m.sections}
    assert {"午特", "頭抬", "湯", "大廚菜", "捲", "壽司", "飲料", "調酒", "點心"} <= zh


def test_the_screens_get_each_dish_s_kitchen_label_so_their_search_finds_it_by_the_old_abbreviation():
    def entries(sections):
        for section in sections:
            yield from section["entries"]
            yield from entries(section["sections"])

    menus = MenuService(load_restaurant_menu()[0]).menus("pos")
    dishes = {e["item"]: e for m in menus for e in entries(m["sections"])}
    assert dishes["S01"]["name"] == "Shrimp with Cashew Nuts"
    assert dishes["S01"]["kitchen_name"] == "腰果蝦 SHMP CASHEW r"
    assert dishes["beefeater"]["kitchen_name"] is None  # a bottle the original POS never labelled


def test_the_dishes_only_the_original_pos_sold_are_on_sale():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    calamari = sell(engine, "A18:regular")
    sold = (calamari.line_total, calamari.tax_class, calamari.kitchen_lines[0].station)
    assert sold == (D("17.95"), "prepared_food", "wok1")
    assert calamari.kitchen_lines[0].text == "1 椒鹽魷魚 CRISPY CALRMRI"
    assert sell(engine, "D01:regular").kitchen_lines[0].station == "takeout"  # the new Desserts category
    food = next(m for m in engine.menu_for("pos") if m.menu == "dinner")
    names = [s.name for s in food.sections]
    assert names.index("Desserts") == names.index("Extras") + 1
    appetizers = next(s for s in food.sections if s.name == "Appetizers")
    assert [e.number for e in appetizers.entries][-5:] == ["A18", "A23", "A24", "A25", "A27"]  # after the export's
    coke = sell(engine, "W011:regular")
    assert (coke.line_total, coke.tax_class, coke.kitchen_lines[0].station) == (D("2.00"), "prepared_food", "soda")
    assert {e.menu for e in defs.entries if e.item == "W011"} == {"dinner", "drinks"}  # Beverages is on both menus
    mocktail = sell(engine, "W04:regular")
    assert (mocktail.tax_class, mocktail.kitchen_lines[0].station) == ("prepared_food", "bar")
    cocktail = sell(engine, "W20:regular", ("drink_options", "drink_options:tall"))
    assert (cocktail.line_total, cocktail.tax_class) == (D("9.25"), "alcohol")
    assert cocktail.kitchen_lines[0].text == "1 KOKO MOKO · TALL"  # the button's "<" is not part of the label
    assert sell(engine, "G010:regular").tax_class == "gift_card"
    assert sell(engine, "X101:regular").kitchen_lines[0].station == "bar"
    assert [h.item for h in engine.search("calamari")] == ["S10", "A18"]


def test_the_dining_room_s_prices_win_where_the_sheet_disagreed():
    defs, _ = load_restaurant_menu()
    assert defs.variants["C13:regular"].base_price == D("19.95")  # online 18.95
    assert defs.variants["N25:regular"].base_price == D("16.95")  # online 17.95
    assert defs.variants["R03:regular"].base_price == D("2.00")  # online 2.50
    assert defs.variants["J29:regular"].base_price == D("8.95")  # kept online: the original POS's 6.95 is stale
    assert defs.variants["R01:regular"].base_price == D("1.95")  # kept online: the original POS also sells it so
    assert [v.base_price for v in defs.variants_of("Y21")][:2] == [D("0.00"), D("1.75")]  # the export's sizes stay


def test_the_original_pos_s_groups_are_offered_with_its_labels_and_take_the_instructions():
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    on_chicken = [g.code for g, _ in defs.attachments_for("C01")]
    assert on_chicken == ["rice_929524", "spice", "allergy", "preparation", "sauces", "ingredients"]
    line = sell(
        engine,
        "C01:regular",
        ("ingredients", "ingredients:broccoli", "no"),
        ("ingredients", "ingredients:cashew", "extra"),
        ("spice", "spice:extra_hot"),
        ("allergy", "allergy:nut"),
    )
    assert line.line_total == D("21.95")  # 17.95 + the 2.00 cashews twice, for EXTRA; NO is free
    # the white rice the dish comes with is not said; what was asked for is
    assert line.kitchen_lines[0].labels == ("XXXhot", "*NUT ALRGY", "NO BROCOL", "EXTRA CASHEW")
    spice = defs.groups["spice"]
    assert (spice.min_select, spice.max_select) == (0, 1)
    assert defs.groups["ingredients"].max_select is None and defs.groups["platter"].allow_quantity
    # the sushi bar, the bar, the wings, the platters, the moo shu pancakes and a charge for an extra
    avocado, inside_out = ("sushi_options", "sushi_options:avocado"), ("sushi_options", "sushi_options:inside_out")
    roll = sell(engine, "K01:regular", avocado, inside_out)
    assert (roll.line_total, roll.kitchen_lines[0].labels) == (D("8.20"), ("AVOCADO", "INSIDE OUT"))
    assert [g.code for g, _ in defs.attachments_for("K01")] == ["sushi_options", "allergy"]
    assert [g.code for g, _ in defs.attachments_for("makers_mark")] == ["served", "drink_options"]
    assert [g.code for g, _ in defs.attachments_for("W011")] == ["drink_options"]
    wings = sell(engine, "A04:regular", ("wings", "wings:salt_pepper"))
    assert (wings.line_total, wings.kitchen_lines[0].labels[-1]) == (D("11.95"), "SALT&PEPR")
    assert [g.code for g, _ in defs.attachments_for("A23")][0] == "platter"
    assert [g.code for g, _ in defs.attachments_for("A19")][0] == "platter"
    pancake = next(o for o in defs.options_of("extra_pancake_933359"))
    moo_shu = sell(engine, "M01:regular", ("extra_pancake_933359", pancake.id))
    assert moo_shu.line_total == D("17.45") and "Pancakes" in moo_shu.kitchen_lines[0].labels
    chips = sell(engine, "Y31:regular", ("charge", "charge:c050"))
    assert chips.line_total == D("2.00") and chips.kitchen_lines[0].labels == ()  # a charge is not for the kitchen
    assert "sauce_size" not in defs.groups  # the export already sells the sauces in sizes


def test_the_file_refuses_what_it_cannot_place():
    defs = export_and_bar()
    with pytest.raises(ValueError, match="no category 'Pastry'"):
        import_legacy(defs, {"new": [{"code": "Z9", "category": "Pastry", "name": "Cake", "price": 1}]})
    with pytest.raises(ValueError, match="already exists"):
        import_legacy(defs, {"new": [{"code": "C01", "category": "Chicken", "name": "Twice", "price": 1}]})
    with pytest.raises(ValueError, match="unknown station"):
        import_legacy(defs, {"items": {"C01": {"station": "grill"}}})
    with pytest.raises(ValueError, match="unknown group"):
        import_legacy(defs, {"attachments": [{"category": "Chicken", "group": "nothing"}]})
    with pytest.raises(ValueError, match="unknown variant"):
        import_legacy(defs, {"prices": [{"variant": "C01:large", "price": 1}]})
    assert "legacy_pos" not in {k for i in defs.items.values() for k in i.attrs}  # nothing half-added that matters
    report = add_legacy(defs)
    assert report.items == 93 and MenuEngine(defs).check() == []  # 89 dishes and the four open ones
    with pytest.raises(ValueError, match="already exists"):
        add_legacy(defs)


def test_an_appetizer_platter_comes_with_its_six_and_swaps_one_for_another():
    """The platter for two comes with six things, all chosen before anyone touches it. No crab rangoon, two
    chicken fingers and spare ribs for the boneless: six again, the ticket and the check read only the changes
    (the count in front, what was left off as NO), and the spare ribs are charged."""
    defs, _ = load_restaurant_menu()
    service = MenuService(defs)
    platter = next(g for g in service.item("A19")["groups"] if g["group_id"] == "platter")
    assert platter["allow_quantity"] is True and platter["options"][0]["max_qty"] is None
    assert (platter["min_select"], platter["max_select"]) == (6, 6)
    six = [o["option_id"].split(":")[1] for o in platter["options"] if o["is_default"]]
    assert six == ["spring_roll", "chicken_wings", "chicken_fingers", "boneless_ribs", "beef_teriyaki", "crab_rangoon"]

    def pick(*codes, **more):
        return [{"group_id": "platter", "option_id": f"platter:{c}", **more} for c in codes]

    plain = service.priced({"variant_id": "A19:regular"})
    assert plain["problems"] == [] and " · " not in plain["kitchen"][0]["text"]
    sent = service.priced({"variant_id": "A19:regular", "selections": pick(*six)})  # as a screen sends it
    assert sent["problems"] == [] and sent["kitchen"][0]["text"] == plain["kitchen"][0]["text"]

    # the word No on the rangoon leaves its place free for a second chicken finger; spare ribs for boneless
    priced = service.priced(
        {
            "variant_id": "A19:regular",
            "selections": pick("spring_roll", "chicken_wings", "beef_teriyaki", "spare_ribs")
            + pick("chicken_fingers", qty=2)
            + pick("crab_rangoon", prefix="no"),
        }
    )
    assert priced["problems"] == []
    assert D(priced["unit_price"]) - D(plain["unit_price"]) == D("2.00")
    changed = [(m["label"], m["kitchen_label"], m["price"]) for m in priced["modifiers"] if not m["defaulted"]]
    assert changed == [
        ("Spare ribs", "SPARE RIBS", "2.00"),
        ("2x Chicken fingers", "2x CHKN FINGR", "0.00"),
        ("NO Crab rangoon", "NO RANGOON", "0.00"),
        ("NO Boneless ribs", "NO BONLES RIB", "0.00"),
    ]
    assert priced["kitchen"][0]["text"].endswith("· SPARE RIBS · 2x CHKN FINGR · NO RANGOON · NO BONLES RIB")

    # six it is: five is one short, seven one too many
    short = service.priced({"variant_id": "A19:regular", "selections": pick(*six[:5])})
    assert [p["code"] for p in short["problems"]] == ["too_few"]
    over = service.priced({"variant_id": "A19:regular", "selections": pick(*six, "veg_spring_roll")})
    assert [p["code"] for p in over["problems"]] == ["too_many"]
