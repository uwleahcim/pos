"""Slice 2: the floor plan, open checks per table, seats and courses, the 86 board."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.floor import FloorPlan, load_floor
from pos.printing.service import Printer, PrintService, ticket_for_fire
from pos.sync.oplog import OpStore

from .test_menu_orders import GTC_QUART, client, payload


def test_the_restaurant_floor_loads():
    plan = load_floor()
    ids = [t.id for t in plan.tables]
    assert len(ids) == len(set(ids)) == 42
    assert {r["id"] for r in plan.rooms} == {"D", "AB", "JK"}
    assert plan.table("B5").seats == 6 and plan.table("D4").shape == "round"
    assert [t.id for t in plan.tables if t.kind == "counter"] == ["K1", "K2", "K3", "K4", "K5", "K6", "J3", "J4", "J5"]
    assert all(0 < t.x < plan.width and 0 < t.y < plan.height for t in plan.tables)


def test_a_broken_plan_is_refused():
    base = {"width": 10, "height": 10, "rooms": [{"id": "R"}]}
    table = {"id": "T1", "label": "T1", "room": "R", "x": 1, "y": 1, "w": 1, "h": 1, "seats": 2}
    with pytest.raises(ValueError, match="duplicate"):
        FloorPlan.from_json({**base, "tables": [table, table]})
    with pytest.raises(ValueError, match="unknown rooms"):
        FloorPlan.from_json({**base, "tables": [{**table, "room": "X"}]})


def test_the_floor_shows_open_checks_with_held_courses():
    c = client()
    c.post(
        "/orders/o1/ops",
        json=[
            payload("a", "create", 0, table="A7", guests=4, server="Amy"),
            payload(
                "b", "add_line", 1, line_id="L1", item="?", seat=1, course="1", request={"variant_id": "CALROLL:roll"}
            ),
            payload("c", "add_line", 2, line_id="L2", item="?", seat=2, course="2", request=GTC_QUART),
            payload("d", "fire", 3, course="1"),
        ],
    )
    c.post("/orders/o2/ops", json=[{**payload("e", "create", 4, table="K1", guests=1), "order_id": "o2"}])
    c.post("/orders/o2/ops", json=[{**payload("f", "close", 5), "order_id": "o2"}])
    floor = c.get("/floor").json()
    assert len(floor["tables"]) == 42 and [x["id"] for x in floor["courses"]] == ["drinks", "1", "2", "3"]
    (a7,) = floor["status"]["A7"]
    assert (a7["order_id"], a7["guests"], a7["server"], a7["items"]) == ("o1", 4, "Amy", 2)
    assert (a7["fired"], a7["held"]) == (["1"], ["2"])
    assert a7["total"] == "36.86"  # 8.50 + 25.95 = 34.45, 7% tax 2.41
    assert "K1" not in floor["status"]  # closed checks free the table

    # moving the party to another table is one field
    c.post("/orders/o1/ops", json=[payload("g", "set_field", 6, table="B5")])
    assert set(c.get("/floor").json()["status"]) == {"B5"}


def test_firing_a_course_prints_only_that_course_with_seats():
    printing = PrintService([Printer("kitchen", "10.0.0.9")], direct=False)
    c = client(printing)
    c.post(
        "/orders/o1/ops",
        json=[
            payload("a", "create", 0, table="A7"),
            payload(
                "b", "add_line", 1, line_id="L1", item="?", seat=1, course="1", request={"variant_id": "CALROLL:roll"}
            ),
            payload("c", "add_line", 2, line_id="L2", item="?", seat=2, course="2", request=GTC_QUART),
            payload("d", "fire", 3, course="1"),
        ],
    )
    store = c.app.state.store
    ticket = ticket_for_fire(store.state("o1"), store.for_order("o1")[-1], station="kitchen", ticket_no=1)
    assert [(t.seat, t.label) for t in ticket.lines] == [(1, "加州卷")] and ticket.course == "1"


def test_the_86_board():
    c = client()
    assert c.get("/menu/86").json()["items"] == []
    board = c.post("/menu/86", json={"target_id": "DRAFT:pitcher", "status": "sold_out", "by": "Amy"}).json()
    assert board["items"] == [
        {"target_id": "DRAFT:pitcher", "name": "House draft (Pitcher)", "status": "sold_out", "by": "Amy"}
    ]
    entry = next(e for s in c.get("/menu").json()["menus"][0]["sections"] for e in s["entries"] if e["item"] == "DRAFT")
    assert [v["status"] for v in entry["variants"]] == ["available", "sold_out"]
    refused = c.post(
        "/orders/o1/ops",
        json=[payload("a", "add_line", 0, line_id="L1", item="?", request={"variant_id": "DRAFT:pitcher"})],
    ).json()
    assert refused["refused"][0]["problems"][0]["code"] == "sold_out"
    assert c.post("/menu/86", json={"target_id": "DRAFT:pitcher", "status": "available"}).json()["items"] == []
    assert c.post("/menu/86", json={"target_id": "NOPE", "status": "sold_out"}).status_code == 404
    assert c.post("/menu/86", json={"target_id": "DRAFT:pitcher", "status": "gone"}).status_code == 422


def test_the_default_app_serves_the_real_floor():
    app = create_app(OpStore(), printing=PrintService([]))
    assert TestClient(app).get("/floor").json()["tables"][0]["id"] == "D8"
