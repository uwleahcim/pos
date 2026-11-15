"""The menu in PostgreSQL: a save and a load give back the same definitions, and a second save writes only
what changed, to the audit log. Needs a database: set POS_TEST_DATABASE_URL."""

from __future__ import annotations

import os
from dataclasses import replace
from datetime import UTC, datetime
from decimal import Decimal

import pytest

from pos.menu.defs import Availability, Definitions
from pos.menu.engine import MenuEngine
from pos.menu.request import LineRequest, Selection
from pos.menu.service import load_definitions

DSN = os.environ.get("POS_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")

TABLES = (
    "audit_log recipe_component recipe item_allergen_override ingredient_allergen ingredient availability_state "
    "menu_entry menu_section menu modifier_attachment modifier_option modifier_group item_variant item category "
    "station allergen unit"
).split()


@pytest.fixture
def store():
    import psycopg

    from pos.menu.store import MenuStore

    with psycopg.connect(DSN) as conn:
        for table in TABLES:
            conn.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
    s = MenuStore(DSN)
    yield s
    s.close()


def same(a: Definitions, b: Definitions) -> None:
    for name in ("units", "allergens", "stations", "categories", "items", "variants", "groups", "options", "menus"):
        assert getattr(a, name) == getattr(b, name), name
    assert a.sections == b.sections
    for name in ("attachments", "entries", "overrides"):
        assert sorted(getattr(a, name), key=repr) == sorted(getattr(b, name), key=repr), name
    assert {r.id: r for r in a.recipes} == {r.id: r for r in b.recipes}
    # an ingredient's allergen declarations are a set: the table has no order for them
    unordered = lambda d: {k: replace(i, allergens=frozenset(i.allergens)) for k, i in d.ingredients.items()}  # noqa: E731
    assert unordered(a) == unordered(b)


@pytest.mark.parametrize("source", ["example", "gloriafood"])
def test_a_menu_comes_back_exactly_as_saved(store, source):
    defs = load_definitions(source)
    assert store.is_empty() and store.revision() == 0
    first = store.save(defs, actor="import")
    assert first.inserted > 0 and first.updated == first.deleted == 0
    loaded = store.load(defs.localizer)
    same(defs, loaded)
    # saving the same menu again changes nothing
    again = store.save(loaded, actor="mike")
    assert again.changed == 0 and again.revision == first.revision


def test_the_engine_prices_the_stored_menu_the_same(store):
    defs = load_definitions("example")
    store.save(defs)
    at = datetime(2026, 10, 27, 19, 0)
    request = LineRequest("GTC:quart", menu_entry_id="dinner:87", selections=(Selection("rice", "rice:brown"),))
    a = MenuEngine(defs, now=lambda: at).resolve(request, at)
    b = MenuEngine(store.load(defs.localizer), now=lambda: at).resolve(request, at)
    assert (a.line_total, a.names, [k.text for k in a.kitchen_lines]) == (
        b.line_total,
        b.names,
        [k.text for k in b.kitchen_lines],
    )


def test_a_change_writes_only_its_rows_and_keeps_ids(store):
    defs = load_definitions("example")
    store.save(defs)
    before = store.revision()
    variant = defs.variants["GTC:quart"]
    defs.variants["GTC:quart"] = replace(variant, base_price=Decimal("25.95"))
    gone = next(e for e in defs.entries if e.id == "dinner:2")
    defs.entries.remove(gone)
    result = store.save(defs, actor="mike")
    assert (result.inserted, result.updated, result.deleted) == (0, 1, 1)
    log = store.audit(2)
    assert {(r["table_name"], r["action"], r["actor"]) for r in log} == {
        ("item_variant", "update", "mike"),
        ("menu_entry", "delete", "mike"),
    }
    update = next(r for r in log if r["action"] == "update")
    assert (update["before"]["base_price"], update["after"]["base_price"]) == ("24.95", "25.95")
    assert update["before"]["id"] == update["after"]["id"]  # the row keeps its id
    assert result.revision == before + 2
    loaded = store.load()
    assert loaded.variants["GTC:quart"].base_price == Decimal("25.95") and loaded.entry("dinner:2") is None


def test_a_save_that_breaks_a_reference_is_refused_whole(store):
    defs = load_definitions("example")
    store.save(defs)
    rev = store.revision()
    defs.items["GTC"] = replace(defs.items["GTC"], category="nope")
    with pytest.raises(ValueError, match="category 'nope' does not exist"):
        store.save(defs)
    assert store.revision() == rev and store.load().items["GTC"].category != "nope"


def test_the_86_board_survives_a_restart(store):
    from pos.menu.store import MenuStore

    store.save(load_definitions("example"))
    at = datetime(2026, 10, 27, 19, 0, tzinfo=UTC)
    store.set_availability(Availability("GTC:quart", "sold_out", None, "out of chicken", "amy", at), "GTC:quart")
    store.set_availability(Availability("rice:brown", "sold_out", None, None, "amy", at), "rice:brown")
    store.set_availability(None, "rice:brown")
    again = MenuStore(DSN)
    try:
        board = again.availability()
    finally:
        again.close()
    assert list(board) == ["GTC:quart"]
    assert (board["GTC:quart"].status, board["GTC:quart"].reason, board["GTC:quart"].set_by) == (
        "sold_out",
        "out of chicken",
        "amy",
    )
    with pytest.raises(ValueError):
        store.set_availability(None, "NOPE:x")


def test_a_hub_seeds_an_empty_database_once_and_picks_up_edits(store):
    from fastapi.testclient import TestClient

    from pos.api.app import create_app
    from pos.menu.service import MenuService
    from pos.sync.oplog import OpStore

    hub = MenuService(load_definitions("example"), store=store)
    assert store.revision() > 0 and "GTC" in hub.defs.items
    rev = hub.revision
    # a second start does not import again: the database is the menu now
    assert MenuService(load_definitions("restaurant"), store=store).revision == rev

    client = TestClient(create_app(OpStore(), menu=hub))
    assert client.get("/menu").json()["revision"] == rev
    client.post("/menu/86", json={"target_id": "GTC:quart", "status": "sold_out", "by": "amy"})
    assert MenuService(store=store).engine.status_of("GTC:quart") == "sold_out"  # survives a restart

    edited = store.load()
    edited.variants["GTC:pint"] = replace(edited.variants["GTC:pint"], base_price=Decimal("14.50"))
    store.save(edited, actor="mike")
    assert hub.refresh(force=True)
    price = client.post("/menu/price", json={"variant_id": "GTC:pint", "entry_id": "dinner:87"}).json()
    assert price["unit_price"] == "14.50"
    assert client.get("/menu").json()["revision"] == rev + 1
    assert hub.engine.status_of("GTC:quart") == "sold_out"  # the board comes along on a reload


def test_ids_must_follow_their_codes(store):
    defs = load_definitions("example")
    v = defs.variants.pop("GTC:quart")
    defs.variants["GTC:big"] = replace(v, id="GTC:big")
    with pytest.raises(ValueError, match="GTC:big"):
        store.save(defs)


def test_the_stations_a_group_is_hidden_at_are_kept_and_a_hub_from_before_gains_the_column(store):
    """Nobody has said (None), a manager's list, and a manager's "every station" (empty) each come back as
    saved; a database made before the column existed reads as nobody having said."""
    import psycopg

    from pos.menu.store import MenuStore

    defs = load_definitions("example")
    defs.groups["rice"] = replace(defs.groups["rice"], hidden_at=("wok", "fryer"))
    defs.groups["spice"] = replace(defs.groups["spice"], hidden_at=())
    store.save(defs, actor="mike")
    loaded = store.load(defs.localizer)
    assert loaded.groups["rice"].hidden_at == ("wok", "fryer") and loaded.groups["spice"].hidden_at == ()
    assert loaded.groups["addons"].hidden_at is None
    assert store.save(loaded).changed == 0
    # only the group's row is written when the list changes
    loaded.groups["rice"] = replace(loaded.groups["rice"], hidden_at=("wok",))
    result = store.save(loaded, actor="mike")
    assert (result.inserted, result.updated, result.deleted) == (0, 1, 0)
    assert store.audit(1)[0]["table_name"] == "modifier_group"
    with psycopg.connect(DSN) as conn:
        conn.execute("ALTER TABLE modifier_group DROP COLUMN hidden_station_ids")
    upgraded = MenuStore(DSN)  # a hub adds the column on start
    try:
        again = upgraded.load(defs.localizer)
        assert all(g.hidden_at is None for g in again.groups.values())
        assert upgraded.save(again).changed == 0
    finally:
        upgraded.close()
