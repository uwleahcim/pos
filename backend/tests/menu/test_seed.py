"""`pos.menu.seed` adds to a hub's stored menu what the bundled files gained, moves no price the editor set."""

from __future__ import annotations

import os
from dataclasses import replace
from decimal import Decimal as D

import pytest

from pos.menu.engine import MenuEngine
from pos.menu.gloriafood import BUNDLED, STATIONS, load_gloriafood, load_restaurant_menu, settings_from
from pos.menu.seed import main, missing, reprice

DSN = os.environ.get("POS_TEST_DATABASE_URL")


def export_alone():
    return load_gloriafood(BUNDLED, settings_from(STATIONS))[0]


def before_the_bar():
    """A hub seeded before `bar.json` existed: the export alone, with a beer price the editor changed since."""
    defs = export_alone()
    beer = defs.variants["E09:regular"]
    defs.variants[beer.id] = replace(beer, base_price=D("5.50"))
    return defs


def test_missing_adds_the_bar_and_keeps_the_editor_s_changes():
    stored = before_the_bar()
    bundled, _ = load_restaurant_menu()
    merged, added = missing(stored, bundled)
    assert "item makers_mark" in added and "category whiskey" in added and "entry dinner:makers_mark" in added
    assert "group served" in added and "attachment category:whiskey/served" in added
    assert "item zombie" in added and "entry dinner:zombie" in added and "category mixed_drinks" not in added
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
