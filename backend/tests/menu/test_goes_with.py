"""A dish says which dishes go with it, and the menu the screens read says it on that dish.

It is menu data (`Item.attrs.goes_with`: item codes, set on the dish in the menu editor), and only ever a
suggestion: the hub rings nothing by itself. A dish taken off sale is left out until it is back, a deleted
dish is forgotten by every dish that named it, and a save refuses what is no list of dishes."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.staff import Directory, Staff
from pos.identity.tokens import Tokens
from pos.menu import admin
from pos.menu.defs import GOES_WITH_MOST, Definitions, Item
from pos.menu.service import MenuService, load_definitions
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore

from ..conftest import T0

DINNER = datetime(2026, 11, 18, 19, 0, tzinfo=UTC)


def put(defs: Definitions, code: str, **changed) -> dict:
    """The dish as the menu editor saves it, with [changed] set."""
    return {"kind": "item", "op": "put", "data": {**admin.encode(defs.items[code]), **changed}}


def going_with(defs: Definitions, code: str, *named: str) -> Definitions:
    attrs = {**admin.encode(defs.items[code])["attrs"], "goes_with": list(named)}
    return admin.apply(defs, [put(defs, code, attrs=attrs)])


def entries(menu: MenuService) -> dict[str, dict]:
    """Every dish on the menus open at dinner, by its place on the menu."""
    out: dict[str, dict] = {}

    def walk(sections: list[dict]) -> None:
        for section in sections:
            out.update({e["entry_id"]: e for e in section["entries"]})
            walk(section["sections"])

    for m in menu.menus(at=DINNER):
        walk(m["sections"])
    return out


def suggested(defs: Definitions, entry_id: str = "dinner:87") -> list[str] | None:
    return entries(MenuService(defs, now=lambda: DINNER))[entry_id].get("goes_with")


# The dish -----------------------------------------------------------------------------------------------------


def test_a_dish_reads_the_dishes_it_goes_with_and_nothing_else():
    def read(named) -> tuple[str, ...]:
        return Item("DUCK", "entrees", {"en": "Duck"}, attrs={"goes_with": named}).goes_with

    assert Item("DUCK", "entrees", {"en": "Duck"}).goes_with == ()
    assert read(["PANCAKE", "WINE"]) == ("PANCAKE", "WINE")  # in the order the manager put them
    assert read(["PANCAKE", "DUCK", "PANCAKE", "", 7, None, "WINE"]) == ("PANCAKE", "WINE")  # not itself, none twice
    assert read([f"D{n}" for n in range(9)]) == tuple(f"D{n}" for n in range(GOES_WITH_MOST))
    for nothing in ("PANCAKE", {"PANCAKE": True}, 3, True, None):
        assert read(nothing) == ()


# The menu the screens read ------------------------------------------------------------------------------------


def test_the_menu_says_it_on_that_dish_wherever_it_is_listed_and_on_no_other():
    defs = going_with(load_definitions("restaurant"), "GTC", "TSINGTAO", "EGGROLL")
    assert admin.problems(defs) == admin.problems(load_definitions("restaurant"))  # nothing the check minds
    lunch = datetime(2026, 11, 18, 12, 30, tzinfo=UTC)
    menu = MenuService(defs, now=lambda: lunch)
    on_menu: dict[str, dict] = {}
    for m in menu.menus(at=lunch):
        for section in m["sections"]:
            on_menu.update({e["entry_id"]: e for e in section["entries"]})
    assert on_menu["dinner:87"]["goes_with"] == ["TSINGTAO", "EGGROLL"]
    if "lunch:L12" in on_menu:  # the same dish as a lunch special suggests the same
        assert on_menu["lunch:L12"]["goes_with"] == ["TSINGTAO", "EGGROLL"]
    assert [e for e in on_menu.values() if e["item"] != "GTC" and "goes_with" in e] == []
    # and a menu on which no dish names any reads as it always did
    plain = entries(MenuService(load_definitions("restaurant"), now=lambda: DINNER))
    assert not any("goes_with" in e for e in plain.values())


def test_a_dish_off_sale_is_not_suggested_until_it_is_back():
    defs = going_with(load_definitions("restaurant"), "GTC", "TSINGTAO", "TEA")
    off = admin.apply(defs, [put(defs, "TSINGTAO", active=False)])
    assert suggested(off) == ["TEA"]
    assert off.items["GTC"].goes_with == ("TSINGTAO", "TEA")  # the dish still names it
    none = admin.apply(off, [put(off, "TEA", active=False)])
    assert suggested(none) is None
    back = admin.apply(none, [put(none, "TSINGTAO", active=True), put(none, "TEA", active=True)])
    assert suggested(back) == ["TSINGTAO", "TEA"]


def test_a_name_no_dish_has_is_never_handed_to_a_screen():
    defs = load_definitions("restaurant")
    # written straight into the menu, past the editor: the screens are still told only of real dishes
    defs.items["GTC"] = Item(**{**vars(defs.items["GTC"]), "attrs": {"goes_with": ["NOPE", "TEA", "GTC"]}})
    assert suggested(defs) == ["TEA"]


# The menu editor ----------------------------------------------------------------------------------------------


def test_a_save_refuses_what_is_no_list_of_dishes():
    defs = load_definitions("restaurant")
    cases = [
        ("TEA", "bad_goes_with"),
        ({"TEA": True}, "bad_goes_with"),
        (["TEA", 7], "bad_goes_with"),
        (["TEA", "GTC"], "bad_goes_with"),  # itself
        (["TEA", "TEA"], "bad_goes_with"),  # twice
        (["TEA", "SODA", "EGGROLL", "WINGS", "PUPU"], "too_many_goes_with"),
    ]
    for named, code in cases:
        errors, _ = admin.problems(admin.apply(defs, [put(defs, "GTC", attrs={"goes_with": named})]))
        assert [p.code for p in errors] == [code], named
        assert "GTC" in errors[0].message
    most = ["TEA", "SODA", "EGGROLL", "WINGS"]
    assert len(most) == GOES_WITH_MOST
    assert admin.problems(admin.apply(defs, [put(defs, "GTC", attrs={"goes_with": most})]))[0] == []
    assert admin.problems(admin.apply(defs, [put(defs, "GTC", attrs={"goes_with": []})]))[0] == []
    # a name no dish has is not kept: the save goes through without it
    saved = admin.apply(defs, [put(defs, "GTC", attrs={"goes_with": ["TEA", "NOPE", ""]})])
    assert admin.problems(saved)[0] == [] and dict(saved.items["GTC"].attrs) == {"goes_with": ["TEA"]}


def the_editor_deletes(defs: Definitions, code: str) -> list[dict]:
    """A dish deleted as the app's menu editor sends it: its places on the menus and its sizes, then itself."""
    return [
        *({"kind": "entry", "op": "delete", "key": e.id} for e in defs.entries if e.item == code),
        *({"kind": "variant", "op": "delete", "key": v.id} for v in defs.variants_of(code)),
        {"kind": "item", "op": "delete", "key": code},
    ]


@pytest.mark.parametrize("cascade", [False, True])
def test_a_deleted_dish_is_forgotten_by_every_dish_that_named_it(cascade):
    defs = going_with(load_definitions("restaurant"), "GTC", "TSINGTAO", "TEA")
    defs = going_with(defs, "BB", "TEA")
    defs = admin.apply(defs, [put(defs, "WINGS", attrs={"asks_price": True, "goes_with": ["TEA"]})])

    def delete(menu: Definitions, code: str) -> Definitions:
        if cascade:
            return admin.apply(menu, [{"kind": "item", "op": "delete", "key": code, "cascade": True}])
        return admin.apply(menu, the_editor_deletes(menu, code))

    gone = delete(defs, "TEA")
    assert admin.problems(gone)[0] == []
    assert dict(gone.items["GTC"].attrs) == {"goes_with": ["TSINGTAO"]}
    assert "goes_with" not in gone.items["BB"].attrs  # it named nothing else: the dish is as it was before
    assert dict(gone.items["WINGS"].attrs) == {"asks_price": True}  # and whatever else a dish holds stays
    assert suggested(gone) == ["TSINGTAO"]
    assert defs.items["GTC"].goes_with == ("TSINGTAO", "TEA")  # the menu being sold from is not touched
    both = delete(gone, "TSINGTAO")
    assert "goes_with" not in both.items["GTC"].attrs and suggested(both) is None


@pytest.fixture
def client():
    staff = Directory([Staff.with_pin("s1", "Amy", "server", "1111"), Staff.with_pin("s3", "Mike", "manager", "9999")])
    menu = MenuService(load_definitions("restaurant"), now=lambda: DINNER)
    return TestClient(
        create_app(OpStore(physical=lambda: T0 + 100), staff=staff, menu=menu, tokens=Tokens("test")),
    )


def on_the_menu(client: TestClient, item: str) -> dict:
    found: list[dict] = []

    def walk(sections: list[dict]) -> None:
        for section in sections:
            found.extend(e for e in section["entries"] if e["item"] == item)
            walk(section["sections"])

    for m in client.get("/menu").json()["menus"]:
        walk(m["sections"])
    return found[0]


def test_a_manager_sets_it_in_the_editor_and_every_screen_reads_it(client):
    token = client.post("/admin/session", json={"device": "mac1", "pin": "9999"}).json()["token"]
    auth = {"Authorization": f"Bearer {token}"}
    read = client.get("/admin/menu", headers=auth).json()
    gtc = next(i for i in read["catalog"]["item"] if i["key"] == "GTC")
    assert "goes_with" not in on_the_menu(client, "GTC")

    data = {k: v for k, v in gtc.items() if k != "key"} | {"attrs": {**gtc["attrs"], "goes_with": ["TSINGTAO", "TEA"]}}
    change = {"changes": [{"kind": "item", "op": "put", "data": data}], "revision": read["revision"]}
    saved = client.post("/admin/menu/changes", json=change, headers=auth)
    assert saved.status_code == 200 and saved.json()["revision"] == read["revision"] + 1
    assert on_the_menu(client, "GTC")["goes_with"] == ["TSINGTAO", "TEA"]
    again = client.get("/admin/menu", headers=auth).json()
    assert next(i for i in again["catalog"]["item"] if i["key"] == "GTC")["attrs"] == {"goes_with": ["TSINGTAO", "TEA"]}

    # a list that is none is refused whole, and says which dish
    bad = {"changes": [{"kind": "item", "op": "put", "data": data | {"attrs": {"goes_with": "TEA"}}}]}
    refused = client.post("/admin/menu/changes", json=bad | {"revision": again["revision"]}, headers=auth)
    assert refused.status_code == 422
    assert [p["code"] for p in refused.json()["detail"]["errors"]] == ["bad_goes_with"]
    assert on_the_menu(client, "GTC")["goes_with"] == ["TSINGTAO", "TEA"]

    # a server cannot set it: the editor is the manager's
    server = Tokens("test").issue("s1", "Amy", "server")[0]
    change["revision"] = again["revision"]
    assert (
        client.post("/admin/menu/changes", json=change, headers={"Authorization": f"Bearer {server}"}).status_code
        == 403
    )


# The check ----------------------------------------------------------------------------------------------------


def test_the_hub_rings_nothing_by_itself(client):
    """A suggestion is a tile on a screen. The dish that was rung is on the check, and nothing else is until
    someone rings it: the suggested dish then goes on as any dish does, at its own price."""
    token = client.post("/admin/session", json={"device": "mac1", "pin": "9999"}).json()["token"]
    auth = {"Authorization": f"Bearer {token}"}
    read = client.get("/admin/menu", headers=auth).json()
    gtc = next(i for i in read["catalog"]["item"] if i["key"] == "GTC")
    data = {k: v for k, v in gtc.items() if k != "key"} | {"attrs": {"goes_with": ["TEA"]}}
    change = {"changes": [{"kind": "item", "op": "put", "data": data}], "revision": read["revision"]}
    assert client.post("/admin/menu/changes", json=change, headers=auth).status_code == 200

    def op(op_id: str, kind: str, at: int, **data) -> dict:
        return {
            "op_id": op_id,
            "order_id": "o1",
            "hlc": str(HLC(T0 + at, 0, "t1")),
            "device": "t1",
            "kind": kind,
            "data": data,
        }

    def send(*ops: dict) -> dict:
        return client.post("/orders/o1/ops", json=list(ops)).json()

    assert send(op("open", "create", 0, table="12", guests=2, order_type="dine_in"))["refused"] == []
    rung = op("l1", "add_line", 1, line_id="L1", item="?", request={"variant_id": "GTC:quart"}, by="Amy", by_id="s1")
    assert send(rung)["refused"] == []
    lines = client.get("/orders/o1").json()["lines"]
    assert list(lines) == ["L1"]
    before = client.get("/orders/o1/check").json()["subtotal"]

    tea = op("l2", "add_line", 2, line_id="L2", item="?", request={"variant_id": "TEA:pot"}, by="Amy", by_id="s1")
    assert send(tea)["refused"] == []
    after = client.get("/orders/o1/check").json()
    assert list(client.get("/orders/o1").json()["lines"]) == ["L1", "L2"]
    price = client.post("/menu/price", json={"variant_id": "TEA:pot"}).json()["unit_price"]
    assert float(after["subtotal"]) == pytest.approx(float(before) + float(price))
