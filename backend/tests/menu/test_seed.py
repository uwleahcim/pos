"""`pos.menu.seed` adds to a hub's stored menu what the bundled files gained, moves no price the editor set,
and moves a category's section to the menu the files now put it on, with every dish the editor gave it."""

from __future__ import annotations

import json
import os
from dataclasses import replace
from decimal import Decimal as D

import pytest

from pos.menu import admin
from pos.menu.bar import BAR, import_bar
from pos.menu.defs import Entry, Item, Variant
from pos.menu.engine import MenuEngine
from pos.menu.gloriafood import BUNDLED, DEFAULT_MENUS, STATIONS, load_gloriafood, load_restaurant_menu, settings_from
from pos.menu.seed import fill, main, missing, reprice, restructure

DSN = os.environ.get("POS_TEST_DATABASE_URL")


def export_alone():
    return load_gloriafood(BUNDLED, settings_from(STATIONS))[0]


def before_the_bar():
    """A hub seeded before `bar.json` existed: the export alone, with a beer price the editor changed since."""
    defs = export_alone()
    beer = defs.variants["E09:regular"]
    defs.variants[beer.id] = replace(beer, base_price=D("5.50"))
    return defs


def before_the_drinks_menu():
    """A hub seeded before the drinks had their own menu: one menu ("Menu") plus lunch, the bar's shelves on
    it, and the editor's work since: Mixed Drinks renamed and coloured, a punch added to it, a soft drink
    added to Beverages, a beer repriced."""
    defs = load_gloriafood(BUNDLED, replace(settings_from(STATIONS), menus=DEFAULT_MENUS))[0]
    import_bar(defs, {**json.loads(BAR.read_text(encoding="utf-8")), "menu": "dinner"})
    assert "drinks" not in defs.menus and defs.menus["dinner"].names == {"en": "Menu", "zh": "菜单"}
    mixed = defs.sections["dinner/mixed_drinks"]
    defs.sections[mixed.id] = replace(mixed, names={"en": "Cocktails"}, display={"color": "#AA3355"})
    defs.add(
        Item("house_punch", "mixed_drinks", {"en": "House Punch"}, tax_class="alcohol", sort=90),
        Variant("house_punch:regular", "house_punch", "regular", {"en": "Regular"}, D("9.95")),
        Entry("dinner:house_punch", "dinner", "dinner/mixed_drinks", "house_punch", None, sort=24_900),
        Item("arnold_palmer", "beverages", {"en": "Arnold Palmer"}, sort=90),
        Variant("arnold_palmer:regular", "arnold_palmer", "regular", {"en": "Regular"}, D("3.50")),
        Entry("dinner:arnold_palmer", "dinner", "dinner/beverages", "arnold_palmer", "B99", sort=25_900),
    )
    beer = defs.variants["E09:regular"]
    defs.variants[beer.id] = replace(beer, base_price=D("7.25"))
    assert MenuEngine(defs).check() == []
    return defs


def test_missing_adds_the_bar_and_keeps_the_editor_s_changes():
    stored = before_the_bar()
    bundled, _ = load_restaurant_menu()
    merged, added = missing(stored, bundled)
    assert "item makers_mark" in added and "category whiskey" in added and "entry drinks:makers_mark" in added
    assert "group served" in added and "attachment category:whiskey/served" in added
    assert "item zombie" in added and "entry drinks:zombie" in added and "category mixed_drinks" not in added
    assert len(added) == len(set(added))
    assert merged.variants["E09:regular"].base_price == D("5.50")  # not the export's 4.50
    assert set(merged.items) == set(bundled.items)
    assert MenuEngine(merged).check() == []
    assert stored.items.keys().isdisjoint({"makers_mark"})  # the input was left alone
    again, added_again = missing(merged, bundled)
    assert added_again == [] and set(again.items) == set(merged.items)


def test_reprice_moves_only_the_prices_nobody_changed():
    stored = before_the_bar()
    bundled, _ = load_restaurant_menu()
    merged, _ = missing(stored, bundled)
    updated = reprice(merged, bundled, export_alone())
    assert "variant E01:regular price 4.00 -> 5.50" in updated  # the export's Budweiser, at the printed price now
    assert merged.variants["E01:regular"].base_price == D("5.50")
    assert merged.variants["E09:regular"].base_price == D("5.50") and not [u for u in updated if "E09" in u]
    assert stored.variants["E01:regular"].base_price == D("4.00")  # the input was left alone
    assert reprice(merged, bundled, export_alone()) == []


def test_restructure_moves_the_drinks_to_their_menu_with_everything_the_editor_gave_them():
    stored = before_the_drinks_menu()
    bundled, _ = load_restaurant_menu()
    merged, changed = restructure(stored, bundled)
    merged, added = missing(merged, bundled)
    assert "menu dinner renamed Menu -> Food" in changed
    assert "section drinks/mixed_drinks moved from dinner/mixed_drinks with 27 entries" in changed  # 26 + the punch
    assert "section drinks/beverages added beside dinner/beverages with 7 entries" in changed  # 6 + the Arnold Palmer
    assert "section drinks/whiskey moved from dinner/whiskey with 25 entries" in changed
    assert "menu drinks" in added and not [a for a in added if a.startswith("section drinks/")]
    # no dish the hub already sold is added to the drinks again; the original POS's new drinks are new
    assert not [a for a in added if a.startswith("entry drinks:") and a.removeprefix("entry drinks:") in stored.items]
    assert merged.menus["dinner"].names == {"en": "Food", "zh": "菜品"} and merged.menus["drinks"].priority == -10
    # the moved section keeps the editor's name and colour, and every dish, the editor's punch included
    assert "dinner/mixed_drinks" not in merged.sections
    cocktails = merged.sections["drinks/mixed_drinks"]
    assert (cocktails.menu, cocktails.names, cocktails.display) == ("drinks", {"en": "Cocktails"}, {"color": "#AA3355"})
    by_id = {e.id: e for e in merged.entries}
    assert "dinner:house_punch" not in by_id and "dinner:zombie" not in by_id and "dinner:makers_mark" not in by_id
    assert (by_id["drinks:house_punch"].section, by_id["drinks:house_punch"].sort) == ("drinks/mixed_drinks", 24_900)
    assert by_id["drinks:zombie"].section == "drinks/mixed_drinks" and by_id["drinks:makers_mark"].menu == "drinks"
    assert not [e for e in merged.entries if e.menu == "dinner" and e.section.endswith(("/mixed_drinks", "/whiskey"))]
    # the soft drinks stay with the food and are at the bar too, the editor's Arnold Palmer included, same number
    assert "dinner/beverages" in merged.sections and "drinks/beverages" in merged.sections
    assert (by_id["dinner:arnold_palmer"].number, by_id["drinks:arnold_palmer"].number) == ("B99", "B99")
    assert by_id["drinks:arnold_palmer"].section == "drinks/beverages"
    # the editor's price stays; lunch is untouched; the result is a clean menu that sells the same things
    assert merged.variants["E09:regular"].base_price == D("7.25")
    assert "lunch/lunch_specials" in merged.sections and merged.menus["lunch"] == stored.menus["lunch"]
    assert admin.problems(merged) == ([], [])
    engine = MenuEngine(merged)
    food = next(m for m in engine.menu_for("pos") if m.menu == "dinner")
    drinks = next(m for m in engine.menu_for("pos") if m.menu == "drinks")
    assert [s.name for s in drinks.sections][:2] == ["Cocktails", "Beverages"] and "Cocktails" not in [
        s.name for s in food.sections
    ]
    sold = {e.item for s in food.sections + drinks.sections for e in s.entries}
    assert {i for i in sold if not merged.items[i].attrs.get("legacy_pos")} == {
        e.item for e in stored.entries if e.menu != "lunch"
    }
    assert stored.sections["dinner/mixed_drinks"].names == {"en": "Cocktails"}  # the input was left alone
    # done once: a second run finds nothing to move or add
    again, changed_again = restructure(merged, bundled)
    assert changed_again == [] and missing(again, bundled)[1] == []


def test_fill_gives_a_stored_menu_the_names_and_stations_it_lacks_and_keeps_the_editor_s():
    """A hub seeded from the export alone has English names only; the original POS's Chinese names and
    kitchen labels arrive, and a name or station the editor set is left as it is."""
    stored = before_the_bar()
    chicken = stored.items["C01"]
    stored.items["C01"] = replace(chicken, names={**chicken.names, "zh": "糖醋雞"}, station="wok2")  # the editor's
    soup = stored.categories["soup"]
    stored.categories["soup"] = replace(soup, names={"en": "Soups"})
    bundled, _ = load_restaurant_menu()
    merged, added = missing(stored, bundled)
    filled = fill(merged, bundled)
    assert "item C02 named kitchen, zh" in filled and "item H29 cooks at fryer" in filled
    assert "category soup named zh" in filled and "section dinner/soup named zh" in filled
    cashew = merged.items["C02"].names
    assert cashew == {"en": "Diced Chicken with Cashew Nuts", "zh": "腰果雞", "kitchen": "腰果雞 DIC CHKN CSHW r"}
    assert merged.items["H29"].station == "fryer"
    assert merged.items["C01"].names["zh"] == "糖醋雞" and merged.items["C01"].station == "wok2"  # the editor's
    assert merged.items["C01"].names["kitchen"] == "甜酸雞 SWT&SOUR CHKN r"  # it had no label, so it takes one
    assert merged.categories["soup"].names == {"en": "Soups", "zh": "湯"}
    assert "item A18" in added and "group spice" in added and "attachment category:chicken/spice" in added
    assert stored.items["C02"].names == {"en": "Diced Chicken with Cashew Nuts"}  # the input was left alone
    assert admin.problems(merged) == ([], [])
    assert fill(merged, bundled) == []


def test_fill_sends_the_take_out_choice_to_the_takeout_station_unless_the_editor_chose_a_station():
    """A hub that had the preparation group before "Take out" learned to route the dish gets the routing;
    one whose editor already set where a choice goes keeps that."""
    bundled, _ = load_restaurant_menu()
    stored = before_the_bar()
    merged, _added = missing(stored, bundled)
    merged.options["preparation:take_out"] = replace(merged.options["preparation:take_out"], routes_to=None)
    merged.options["wings:take_out"] = replace(merged.options["wings:take_out"], routes_to="wok2")
    filled = fill(merged, bundled)
    assert "option preparation:take_out also prints the dish at takeout" in filled
    assert merged.options["preparation:take_out"].routes_to == "takeout"
    assert merged.options["wings:take_out"].routes_to == "wok2" and "option wings:take_out" not in " ".join(filled)
    assert fill(merged, bundled) == []


def test_fill_gives_the_platter_its_six_unless_the_editor_set_the_group():
    """A hub whose Platter group was any number of anything takes "six, and these six" from the files; a
    group the editor already gave a number of picks keeps what it has."""
    bundled, _ = load_restaurant_menu()
    six = sorted(o.id for o in bundled.options_of("platter") if o.is_default)
    merged, _added = missing(before_the_bar(), bundled)
    merged.groups["platter"] = replace(merged.groups["platter"], min_select=0, max_select=None)
    for option in merged.options_of("platter"):
        merged.options[option.id] = replace(option, is_default=False)
    filled = fill(merged, bundled)
    assert any(line.startswith("group platter takes 6, comes with spring_roll") for line in filled)
    assert (merged.groups["platter"].min_select, merged.groups["platter"].max_select) == (6, 6)
    assert sorted(o.id for o in merged.options_of("platter") if o.is_default) == six and len(six) == 6
    assert fill(merged, bundled) == []
    merged.groups["platter"] = replace(merged.groups["platter"], min_select=0, max_select=4)
    assert fill(merged, bundled) == [] and merged.groups["platter"].max_select == 4


def test_restructure_leaves_a_menu_the_editor_renamed_alone():
    stored = before_the_drinks_menu()
    stored.menus["dinner"] = replace(stored.menus["dinner"], names={"en": "Dinner", "zh": "晚餐"})
    merged, changed = restructure(stored, load_restaurant_menu()[0])
    assert merged.menus["dinner"].names == {"en": "Dinner", "zh": "晚餐"}
    assert not [c for c in changed if c.startswith("menu")]


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_command_lists_then_saves_the_additions(capsys):
    import psycopg

    from pos.menu.store import MenuStore
    from tests.menu.test_store import TABLES

    with psycopg.connect(DSN) as conn:
        for table in TABLES:
            conn.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
    store = MenuStore(DSN)
    store.save(before_the_bar(), actor="import")
    store.close()

    assert main(["--dsn", DSN]) == 0
    out = capsys.readouterr().out
    assert "item makers_mark" in out and "variant E01:regular price 4.00 -> 5.50" in out and "dry run" in out
    store = MenuStore(DSN)
    stored = store.load()
    assert "makers_mark" not in stored.items and stored.variants["E01:regular"].base_price == D("4.00")
    store.close()

    assert main(["--dsn", DSN, "--apply"]) == 0
    assert "saved: revision" in capsys.readouterr().out
    store = MenuStore(DSN)
    stored = store.load()
    assert "makers_mark" in stored.items and stored.variants["E09:regular"].base_price == D("5.50")
    assert stored.variants["E01:regular"].base_price == D("5.50")
    assert store.audit(1)[0]["actor"] == "import (pos.menu.seed)"
    store.close()

    assert main(["--dsn", DSN, "--apply"]) == 0
    assert "nothing to add" in capsys.readouterr().out


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_command_moves_a_hub_s_drinks_to_their_menu(capsys):
    import psycopg

    from pos.menu.store import MenuStore
    from tests.menu.test_store import TABLES

    with psycopg.connect(DSN) as conn:
        for table in TABLES:
            conn.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
    store = MenuStore(DSN)
    store.save(before_the_drinks_menu(), actor="import")
    store.close()

    assert main(["--dsn", DSN]) == 0
    out = capsys.readouterr().out
    assert "section drinks/mixed_drinks moved from dinner/mixed_drinks with 27 entries" in out and "dry run" in out
    assert main(["--dsn", DSN, "--apply"]) == 0
    assert "saved: revision" in capsys.readouterr().out
    store = MenuStore(DSN)
    stored = store.load()
    store.close()
    assert stored.menus["dinner"].names["en"] == "Food" and stored.menus["drinks"].names["en"] == "Drinks"
    assert "dinner/mixed_drinks" not in stored.sections
    assert stored.sections["drinks/mixed_drinks"].names == {"en": "Cocktails", "zh": "調酒"}  # the editor's, + the fill
    by_id = {e.id: e for e in stored.entries}
    assert "dinner:house_punch" not in by_id and by_id["drinks:house_punch"].section == "drinks/mixed_drinks"
    assert by_id["drinks:arnold_palmer"].number == "B99" and by_id["dinner:arnold_palmer"].number == "B99"
    assert stored.variants["E09:regular"].base_price == D("7.25")
    assert MenuEngine(stored).check() == []
    assert main(["--dsn", DSN, "--apply"]) == 0
    assert "nothing to add" in capsys.readouterr().out
