"""The floor editor's side of the hub: a manager redraws the floor from the app (`PUT /settings/floor_plan`),
every floor map follows, and the plan the hub came with stays underneath for putting back."""

from __future__ import annotations

import copy

import pytest

from pos.floor import clean_floor_plan, load_floor
from pos.floor.plan import LABEL_MAX, MARGIN, SEATS_MAX, SIDE_MAX, SIDE_MIN

from .orders.test_menu_orders import client, payload
from .test_reservations import MON, add, at, hub

ROOMS = [{"id": "main", "name": "Main"}, {"id": "bar", "name": "Bar"}]


def table(ident: str, room: str = "main", x: float = 100, y: float = 100, **more) -> dict:
    return {"id": ident, "label": ident, "room": room, "x": x, "y": y, "w": 50, "h": 50, "seats": 2, **more}


def manager(c) -> dict[str, str]:
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    return {"authorization": f"Bearer {token}"}


def as_drawn() -> dict:
    """The plan the hub came with, as the editor would send it back unchanged."""
    plan = load_floor().as_json()
    return {"rooms": [{"id": r["id"], "name": r["name"]} for r in plan["rooms"]], "tables": plan["tables"]}


def test_a_plan_is_stored_as_its_tables_need_it():
    plan = clean_floor_plan(
        {
            "rooms": ROOMS,
            "tables": [
                table("T1", x=500, y=300),
                table("T2", x=700, y=300, w=40, h=100),
                table("B1", "bar", x=500, y=600, shape="round", w=30, h=44, rotation=30),
            ],
        }
    )
    by = {t["id"]: t for t in plan["tables"]}
    # moved together so that the leftmost and the topmost stand a margin from the plan's corner
    assert (by["T1"]["x"], by["T1"]["y"]) == (MARGIN + 25, MARGIN + 50)
    assert by["T2"]["x"] - by["T1"]["x"] == 200 and by["B1"]["y"] - by["T1"]["y"] == 300
    # as wide and as high as the tables need, with the margin on every side
    assert plan["width"] == (720 - 475) + 2 * MARGIN and plan["height"] == (615 - 250) + 2 * MARGIN
    # a round table is as wide as it is deep, and is not turned
    assert (by["B1"]["w"], by["B1"]["h"], by["B1"]["rotation"]) == (30, 30, 0)
    # each room's frame is the one round its own tables
    main, bar = plan["rooms"]
    assert main["x"] < by["T1"]["x"] - 25 and main["x"] + main["w"] > by["T2"]["x"] + 20
    assert bar["y"] < by["B1"]["y"] - 15 < by["B1"]["y"] + 15 < bar["y"] + bar["h"]
    # what is stored reads back as a plan, and saving it again changes nothing
    again = clean_floor_plan({"rooms": plan["rooms"], "tables": plan["tables"]})
    assert again == plan


def test_a_new_room_gets_its_id_from_its_name_and_tables_can_stand_in_it_at_once():
    plan = clean_floor_plan(
        {
            "rooms": [{"id": "main", "name": "Main"}, {"name": "Patio 2"}, {"name": "  Sushi   bar "}],
            "tables": [table("P1", "#1"), table("S1", "#2", x=300)],
        }
    )
    assert [(r["id"], r["name"]) for r in plan["rooms"]] == [
        ("main", "Main"),
        ("patio-2", "Patio 2"),
        ("sushi-bar", "Sushi bar"),
    ]
    assert [t["room"] for t in plan["tables"]] == ["patio-2", "sushi-bar"]
    # an id that is taken is not given twice
    plan = clean_floor_plan({"rooms": [{"id": "patio", "name": "Deck"}, {"name": "Patio"}], "tables": []})
    assert [r["id"] for r in plan["rooms"]] == ["patio", "patio-2"]
    # a room with no table yet still has a frame, under the tables
    assert all(r["w"] > 0 and r["h"] > 0 for r in plan["rooms"])


def test_a_turned_table_is_kept_inside_the_plan_and_its_turn_between_half_turns():
    plan = clean_floor_plan({"rooms": ROOMS, "tables": [table("T1", w=100, h=100, rotation=405)]})
    (t1,) = plan["tables"]
    assert t1["rotation"] == 45
    # a square on its corner reaches further than its sides: the margin is kept from its points
    assert t1["x"] == pytest.approx(MARGIN + 100 / 2**0.5, abs=0.01)
    assert clean_floor_plan({"rooms": ROOMS, "tables": [table("T1", rotation=-200)]})["tables"][0]["rotation"] == 160


@pytest.mark.parametrize(
    ("change", "problem"),
    [
        ({"rooms": []}, "at least one room"),
        ({"rooms": [{"name": " "}]}, "every room has a name"),
        ({"rooms": [{"name": "Main"}, {"name": "main"}]}, "two rooms are called"),
        ({"rooms": [{"id": "a b", "name": "Main"}]}, "a room's id"),
        ({"rooms": [{"id": "m", "name": "Main"}, {"id": "m", "name": "Bar"}]}, "two rooms have the id"),
        ({"rooms": [{"name": "x" * 33}]}, "letters at most"),
        ({"tables": [table("T 1")]}, "a table's id"),
        ({"tables": [table("T1"), table("T1", x=300)]}, "two tables have the id"),
        ({"tables": [table("T1"), table("T2", label="t1", x=300)]}, "two tables are called"),
        ({"tables": [table("T1", label="x" * (LABEL_MAX + 1))]}, "letters at most"),
        ({"tables": [table("T1", "patio")]}, "a room the plan does not have"),
        ({"tables": [table("T1", shape="star")]}, "its shape"),
        ({"tables": [table("T1", kind="sofa")]}, "its kind"),
        ({"tables": [table("T1", seats=0)]}, "seats"),
        ({"tables": [table("T1", seats=SEATS_MAX + 1)]}, "seats"),
        ({"tables": [table("T1", seats=2.5)]}, "whole number"),
        ({"tables": [table("T1", w=SIDE_MIN - 1)]}, "each side"),
        ({"tables": [table("T1", h=SIDE_MAX + 1)]}, "each side"),
        ({"tables": [table("T1", x="left")]}, "must be a number"),
        ({"tables": [table("T1", x=float("inf"))]}, "must be a number"),
        ({"tables": [table("T1"), table("T2", x=50_000)]}, "too far apart"),
    ],
)
def test_a_plan_that_cannot_be_is_refused_with_the_reason(change, problem):
    with pytest.raises(ValueError, match=problem):
        clean_floor_plan({"rooms": ROOMS, "tables": [table("T1")], **change})


def test_a_manager_redraws_the_floor_and_every_map_follows():
    c = client()
    start = c.get("/settings/floor_plan").json()
    assert (start["edited"], start["by"], start["busy"], start["booked"]) == (False, "", [], [])
    assert len(start["tables"]) == 42 and [r["id"] for r in start["rooms"]] == ["D", "AB", "JK"]

    drawn = as_drawn()
    a7 = next(t for t in drawn["tables"] if t["id"] == "A7")
    a7.update(label="A7w", seats=6, w=60, h=110, rotation=0)  # the corner table becomes a six-top by the window
    drawn["tables"].append(table("P1", "#3", x=1500, y=300, shape="round", seats=5))
    drawn["rooms"].append({"name": "Patio"})
    drawn["tables"] = [t for t in drawn["tables"] if t["id"] != "K9"]

    assert c.put("/settings/floor_plan", json=drawn).status_code == 401
    server = c.post("/admin/session", json={"device": "t1", "pin": "1111"})
    assert server.status_code in (401, 403)  # a server has no key to the settings
    auth = manager(c)
    saved = c.put("/settings/floor_plan", json=drawn, headers=auth)
    assert saved.status_code == 200, saved.text
    saved = saved.json()
    assert (saved["edited"], saved["by"]) == (True, "Mike") and saved["saved_ms"] > 0
    assert [r["name"] for r in saved["rooms"]] == ["Dining room C & D", "Main dining", "Bar and lounge", "Patio"]

    floor = c.get("/floor").json()
    by = {t["id"]: t for t in floor["tables"]}
    assert len(by) == 42 and "K9" not in by
    assert (by["A7"]["label"], by["A7"]["seats"], by["A7"]["rotation"]) == ("A7w", 6, 0)
    assert (by["P1"]["room"], by["P1"]["shape"], by["P1"]["seats"]) == ("patio", "round", 5)
    assert c.get("/settings/floor_plan").json() == saved

    # a plan that cannot be is refused and nothing changes
    bad = copy.deepcopy(drawn)
    bad["tables"][0]["seats"] = 0
    r = c.put("/settings/floor_plan", json=bad, headers=auth)
    assert (
        r.status_code == 422 and r.json()["detail"]["error"] == "bad_value" and "seats" in r.json()["detail"]["message"]
    )
    assert c.get("/settings/floor_plan").json() == saved

    # put back: the plan the hub came with
    assert c.delete("/settings/floor_plan").status_code == 401
    back = c.delete("/settings/floor_plan", headers=auth).json()
    assert (back["edited"], len(back["tables"])) == (False, 42)
    assert {t["id"]: t["label"] for t in c.get("/floor").json()["tables"]}["A7"] == "A7"


def test_a_table_keeps_its_check_when_it_is_moved_or_renamed_and_cannot_be_taken_off_while_it_is_open():
    c = client()
    auth = manager(c)
    c.post("/orders/o1/ops", json=[payload("a", "create", 0, table="A7", guests=4, server="Amy")])
    assert c.get("/settings/floor_plan").json()["busy"] == ["A7"]

    drawn = as_drawn()
    without = {**drawn, "tables": [t for t in drawn["tables"] if t["id"] != "A7"]}
    r = c.put("/settings/floor_plan", json=without, headers=auth)
    assert r.status_code == 409
    detail = r.json()["detail"]
    assert (detail["error"], detail["tables"]) == ("table_busy", ["A7"]) and "open check" in detail["message"]
    assert c.get("/settings/floor_plan").json()["edited"] is False

    # moved across the room and renamed, it is the same table: its check is still on it
    next(t for t in drawn["tables"] if t["id"] == "A7").update(x=1400, y=200, label="W1")
    assert c.put("/settings/floor_plan", json=drawn, headers=auth).status_code == 200
    floor = c.get("/floor").json()
    assert floor["status"]["A7"][0]["order_id"] == "o1"
    assert next(t for t in floor["tables"] if t["id"] == "A7")["label"] == "W1"

    # once the check is closed the table can go
    c.post("/orders/o1/ops", json=[payload("b", "close", 5)])
    assert c.put("/settings/floor_plan", json=without, headers=auth).status_code == 200
    assert "A7" not in {t["id"] for t in c.get("/floor").json()["tables"]}

    # and the hub's own plan cannot come back over a table that is in use and not on it
    with_new = {**drawn, "tables": [*drawn["tables"], table("P1", "AB", x=1500, y=300)]}
    assert c.put("/settings/floor_plan", json=with_new, headers=auth).status_code == 200
    c.post("/orders/o2/ops", json=[{**payload("c", "create", 6, table="P1"), "order_id": "o2"}])
    r = c.delete("/settings/floor_plan", headers=auth)
    assert r.status_code == 409 and r.json()["detail"]["tables"] == ["P1"]


def test_a_table_a_reservation_holds_cannot_be_taken_off_and_a_new_table_can_be_booked():
    c, _wall = hub(at(15))
    auth = manager(c)
    add(c, "Chen", 4, "18:30", MON, table="A8")
    assert c.get("/settings/floor_plan").json()["booked"] == ["A8"]
    drawn = as_drawn()
    without = {**drawn, "tables": [t for t in drawn["tables"] if t["id"] != "A8"]}
    r = c.put("/settings/floor_plan", json=without, headers=auth)
    assert r.status_code == 409 and r.json()["detail"]["error"] == "table_booked"

    # a table drawn in the editor is a table of the floor: the book and the waitlist know it
    drawn["tables"].append(table("P1", "AB", x=1500, y=300, seats=6))
    assert c.put("/settings/floor_plan", json=drawn, headers=auth).status_code == 200
    booked = add(c, "Kim", 6, "19:00", MON, table="P1")
    assert booked["table"] == "P1"
    r = c.post(
        "/reservations", json={"staff_id": "s4", "name": "Wu", "size": 2, "day": MON, "time": "19:30", "table": "ZZ"}
    )
    assert r.status_code == 404 and r.json()["detail"]["error"] == "unknown_table"


def test_the_change_feed_tells_the_maps_the_floor_changed():
    c = client()
    auth = manager(c)
    feed = c.app.state.feed
    told: list[str] = []
    original = feed.changed
    feed.changed = lambda *topics, **more: (told.extend(topics), original(*topics, **more))[1]
    assert c.put("/settings/floor_plan", json=as_drawn(), headers=auth).status_code == 200
    assert "floor" in told
