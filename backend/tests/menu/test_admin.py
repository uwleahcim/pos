"""The menu editor's backend: the catalog as JSON and back, checked changes, managers only."""

from __future__ import annotations

import io
import os
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from openpyxl import load_workbook

from pos.api.app import create_app
from pos.identity.staff import Directory, Staff
from pos.identity.tokens import Tokens
from pos.menu import admin
from pos.menu.service import MenuService, load_definitions
from pos.sync.oplog import OpStore


def everything(defs):
    """Every definition as a put, the way the editor would send a whole menu."""
    return [
        {"kind": kind, "op": "put", "data": {k: v for k, v in row.items() if k != "key"}}
        for kind, rows in admin.catalog(defs).items()
        for row in rows
    ]


@pytest.mark.parametrize("source", ["example", "restaurant", "gloriafood"])
def test_the_catalog_comes_back_from_json_exactly(source):
    defs = load_definitions(source)
    empty = admin.copy_of(defs)
    for kind in admin.KINDS.values():
        getattr(empty, kind.attr).clear()
    rebuilt = admin.apply(empty, everything(defs))
    for kind in admin.KINDS.values():
        a, b = getattr(defs, kind.attr), getattr(rebuilt, kind.attr)
        assert (a == b) if isinstance(a, dict) else sorted(map(repr, a)) == sorted(map(repr, b)), kind.name
    assert admin.problems(defs)[0] == []  # every shipped menu passes its own checks


def test_changes_make_a_new_menu_and_leave_the_old_one_alone():
    defs = load_definitions("example")
    price = defs.variants["GTC:quart"].base_price
    new = admin.apply(
        defs,
        [
            {
                "kind": "variant",
                "op": "put",
                "data": {**admin.encode(defs.variants["GTC:quart"]), "base_price": "25.95"},
            },
            {
                "kind": "variant",
                "op": "put",
                "data": {"item": "GTC", "code": "gallon", "names": {"en": "Gallon"}, "base_price": "60"},
            },
            {"kind": "entry", "op": "delete", "key": "dinner:2"},
        ],
    )
    assert new.variants["GTC:quart"].base_price == Decimal("25.95")
    assert new.variants["GTC:gallon"].id == "GTC:gallon"  # the id follows from item and code
    assert new.entry("dinner:2") is None and defs.entry("dinner:2") is not None
    assert defs.variants["GTC:quart"].base_price == price


def test_bad_changes_are_refused_with_the_reason():
    defs = load_definitions("example")
    cases = [
        ({"kind": "dish", "op": "put", "data": {}}, "unknown kind"),
        ({"kind": "item", "op": "rename"}, "op must be put or delete"),
        ({"kind": "entry", "op": "delete", "key": "nope"}, "no entry 'nope'"),
        (
            {"kind": "variant", "op": "put", "data": {"item": "GTC", "code": "x", "names": {}, "base_price": "abc"}},
            "not a number",
        ),
        ({"kind": "item", "op": "put", "data": {"code": "X", "names": {}}}, "category"),
        (
            {"kind": "item", "op": "put", "data": {"code": "X", "category": "c", "names": {}, "colour": "red"}},
            "unknown fields colour",
        ),
        (
            {"kind": "item", "op": "put", "data": {"code": "X", "category": "c", "names": {}, "active": "yes"}},
            "true or false",
        ),
    ]
    for change, message in cases:
        with pytest.raises(admin.ChangeError, match=message):
            admin.apply(defs, [change])


def test_a_change_that_breaks_the_menu_is_found_before_saving():
    defs = load_definitions("example")
    orphan = admin.apply(defs, [{"kind": "item", "op": "delete", "key": "GTC"}])
    errors, _ = admin.problems(orphan)
    assert any("GTC" in p.message for p in errors)
    # with cascade a dish takes its sizes, entries and recipes with it, and the menu stays whole
    gone = admin.apply(defs, [{"kind": "item", "op": "delete", "key": "PUPU", "cascade": True}])
    assert admin.problems(gone)[0] == []
    assert not any(v.item == "PUPU" for v in gone.variants.values())
    assert not any(e.item == "PUPU" for e in gone.entries)
    # but not out of a combo that offers it: the editor is told which option still points at it
    combo = admin.apply(defs, [{"kind": "item", "op": "delete", "key": "GTC", "cascade": True}])
    assert [p.message for p in admin.problems(combo)[0]] == ["entree_slot:gtc links unknown variant GTC:lunch"]


# --- the API -------------------------------------------------------------------------------------------------


@pytest.fixture
def client():
    staff = Directory([Staff.with_pin("s1", "Amy", "server", "1111"), Staff.with_pin("s3", "Mike", "manager", "9999")])
    menu = MenuService(load_definitions("example"))
    return TestClient(create_app(OpStore(), staff=staff, menu=menu, tokens=Tokens("test")))


def signed_in(client, pin="9999"):
    token = client.post("/admin/session", json={"device": "mac1", "pin": pin}).json()["token"]
    return {"Authorization": f"Bearer {token}"}


def test_only_a_manager_edits_the_menu(client):
    assert client.get("/admin/menu").status_code == 401
    assert client.post("/admin/session", json={"device": "mac1", "pin": "1111"}).status_code == 403
    assert client.post("/admin/session", json={"device": "mac1", "pin": "0000"}).status_code == 401
    assert client.get("/admin/menu", headers={"Authorization": "Bearer forged.token"}).status_code == 401
    server = Tokens("test").issue("s1", "Amy", "server")[0]
    assert client.get("/admin/menu", headers={"Authorization": f"Bearer {server}"}).status_code == 403
    assert client.get("/admin/menu", headers=signed_in(client)).status_code == 200


def test_a_token_expires():
    now = [1000.0]
    tokens = Tokens("k", clock=lambda: now[0])
    token, _ = tokens.issue("s3", "Mike", "manager", ttl=60)
    assert tokens.verify(token).name == "Mike"
    assert Tokens("other").verify(token) is None
    now[0] += 61
    assert tokens.verify(token) is None


def test_the_editor_reads_changes_and_the_terminals_see_it(client):
    auth = signed_in(client)
    read = client.get("/admin/menu", headers=auth).json()
    rev = read["revision"]
    quart = next(v for v in read["catalog"]["variant"] if v["key"] == "GTC:quart")
    assert quart["base_price"] == "24.95" and read["errors"] == []

    data = {k: v for k, v in quart.items() if k != "key"} | {"base_price": "25.95"}
    change = [{"kind": "variant", "op": "put", "data": data}]
    dry = client.post("/admin/menu/changes", json={"changes": change, "revision": rev, "dry_run": True}, headers=auth)
    assert dry.json()["dry_run"] is True
    assert client.post("/menu/price", json={"variant_id": "GTC:quart"}).json()["unit_price"] == "24.95"

    saved = client.post("/admin/menu/changes", json={"changes": change, "revision": rev}, headers=auth).json()
    assert saved["revision"] == rev + 1
    assert client.get("/menu").json()["revision"] == rev + 1
    assert client.post("/menu/price", json={"variant_id": "GTC:quart"}).json()["unit_price"] == "25.95"

    # a second editor still holding the old revision is told to reload, not allowed to overwrite
    stale = client.post("/admin/menu/changes", json={"changes": change, "revision": rev}, headers=auth)
    assert stale.status_code == 409 and stale.json()["detail"]["revision"] == rev + 1


def test_a_save_that_breaks_the_menu_is_refused_whole(client):
    auth = signed_in(client)
    rev = client.get("/admin/menu", headers=auth).json()["revision"]
    broken = [
        {"kind": "entry", "op": "delete", "key": "dinner:2"},
        {"kind": "item", "op": "delete", "key": "GTC"},
    ]
    r = client.post("/admin/menu/changes", json={"changes": broken, "revision": rev}, headers=auth)
    assert r.status_code == 422 and r.json()["detail"]["error"] == "menu_problems"
    assert any("GTC" in p["message"] for p in r.json()["detail"]["errors"])
    assert client.get("/menu").json()["revision"] == rev
    bad = client.post("/admin/menu/changes", json={"changes": [{"kind": "dish", "op": "put"}]}, headers=auth)
    assert bad.status_code == 422 and bad.json()["detail"]["error"] == "bad_change"


def test_the_spreadsheet_round_trip(client):
    auth = signed_in(client)
    rev = client.get("/admin/menu", headers=auth).json()["revision"]
    sheet = client.get("/admin/menu/workbook", headers=auth)
    assert sheet.headers["x-menu-revision"] == str(rev)
    wb = load_workbook(io.BytesIO(sheet.content))
    for row in wb["Variants"].iter_rows(min_row=2):
        if row[0].value == "GTC:quart":
            row[5].value = "26.50"
    edited = io.BytesIO()
    wb.save(edited)

    dry = client.post("/admin/menu/workbook", content=edited.getvalue(), headers=auth).json()
    assert dry["dry_run"] is True and "price GTC:quart: 24.95 -> 26.50" in dry["changes"]
    assert client.post("/menu/price", json={"variant_id": "GTC:quart"}).json()["unit_price"] == "24.95"

    params = {"dry_run": "false", "revision": rev}
    saved = client.post("/admin/menu/workbook", params=params, content=edited.getvalue(), headers=auth).json()
    assert saved["revision"] == rev + 1
    assert client.post("/menu/price", json={"variant_id": "GTC:quart"}).json()["unit_price"] == "26.50"
    junk = client.post("/admin/menu/workbook", content=b"not a workbook", headers=auth)
    assert junk.status_code == 422 and junk.json()["detail"]["error"] == "bad_workbook"


DSN = os.environ.get("POS_TEST_DATABASE_URL")


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_a_stored_save_names_the_manager_in_the_audit_log():
    import psycopg

    from pos.menu.store import MenuStore

    from .test_store import TABLES

    with psycopg.connect(DSN) as conn:
        for table in TABLES:
            conn.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
    store = MenuStore(DSN)
    try:
        staff = Directory([Staff.with_pin("s3", "Mike", "manager", "9999")])
        menu = MenuService(load_definitions("example"), store=store)
        client = TestClient(create_app(OpStore(), staff=staff, menu=menu, tokens=Tokens("test")))
        auth = signed_in(client)
        read = client.get("/admin/menu", headers=auth).json()
        quart = next(v for v in read["catalog"]["variant"] if v["key"] == "GTC:quart")
        data = {k: v for k, v in quart.items() if k != "key"} | {"base_price": "25.95"}
        change = {"changes": [{"kind": "variant", "op": "put", "data": data}], "revision": read["revision"]}
        saved = client.post("/admin/menu/changes", json=change, headers=auth).json()
        assert (saved["updated"], saved["revision"]) == (1, read["revision"] + 1)
        log = client.get("/admin/menu/audit", params={"limit": 1}, headers=auth).json()["changes"]
        assert (log[0]["actor"], log[0]["table_name"], log[0]["after"]["base_price"]) == (
            "Mike (s3)",
            "item_variant",
            "25.95",
        )
        # the database refuses a save from a stale revision too, not only the API
        assert client.post("/admin/menu/changes", json=change, headers=auth).status_code == 409
    finally:
        store.close()
