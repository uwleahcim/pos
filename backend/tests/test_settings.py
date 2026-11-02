"""Location settings a manager changes from the app and every terminal reads: coursing (on or off, the
courses by name in kitchen order, which one a new dish goes to) beside the quote times. Stored on the hub
like the quote times, under one key each."""

from __future__ import annotations

import pytest

from pos.printing.service import Printer, PrintService
from pos.settings import DEFAULTS, SettingStore, clean_coursing

from .orders.test_menu_orders import GTC_QUART, client, payload
from .printing.fake_printer import FakePrinter, decode
from .printing.test_service import wait_for

STANDARD = [("drinks", "Drinks"), ("1", "Appetizers"), ("2", "Entrees"), ("3", "Dessert")]


def pairs(data: dict) -> list[tuple[str, str]]:
    return [(c["id"], c["name"]) for c in data["courses"]]


def test_the_standard_courses_are_the_default_and_a_new_dish_goes_to_the_appetizers():
    coursing = SettingStore().get("coursing")
    assert coursing["enabled"] is True and coursing["default"] == "1"
    assert pairs(coursing) == STANDARD
    assert clean_coursing(DEFAULTS["coursing"]) == DEFAULTS["coursing"]


def test_a_manager_names_orders_and_adds_courses_without_limit():
    cleaned = clean_coursing(
        {
            "enabled": True,
            "default": "2",
            "courses": [
                {"id": "drinks", "name": "  Drinks "},
                {"name": "Soup"},  # new from the screen: it gets its id from its name
                {"id": "2", "name": "Mains"},
                {"name": "Soup & Salad"},
            ],
        }
    )
    assert pairs(cleaned) == [("drinks", "Drinks"), ("soup", "Soup"), ("2", "Mains"), ("soup-salad", "Soup & Salad")]
    assert cleaned["default"] == "2" and cleaned["enabled"] is True


def test_new_course_ids_come_from_the_name_and_never_collide():
    many = {"enabled": True, "courses": [{"name": f"Course {i}"} for i in range(1, 101)]}
    cleaned = clean_coursing(many)
    assert len(cleaned["courses"]) == 100 and cleaned["default"] == "course-1"  # the first, when none is named
    assert len({c["id"] for c in cleaned["courses"]}) == 100
    courses = [{"name": "汤"}, {"name": "主菜"}, {"id": "course", "name": "x"}]
    chinese = clean_coursing({"enabled": True, "courses": courses})
    assert [c["id"] for c in chinese["courses"]] == ["course-2", "course-3", "course"]


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ({"enabled": True, "courses": []}, "at least one course"),
        ({"enabled": "yes", "courses": [{"id": "1", "name": "A"}]}, "enabled"),
        ({"enabled": True, "courses": {"id": "1"}}, "list"),
        ({"enabled": True, "courses": [{"id": "1", "name": "A"}, {"id": "1", "name": "B"}]}, "twice"),
        ({"enabled": True, "courses": [{"id": "1", "name": "Soup"}, {"id": "2", "name": "soup"}]}, "twice"),
        ({"enabled": True, "courses": [{"id": "1", "name": "  "}]}, "name"),
        ({"enabled": True, "courses": [{"id": "1", "name": "x" * 41}]}, "40"),
        ({"enabled": True, "courses": [{"id": "*", "name": "All"}]}, "id"),
        ({"enabled": True, "courses": [{"id": "no spaces", "name": "A"}]}, "id"),
        ({"enabled": True, "default": "9", "courses": [{"id": "1", "name": "A"}]}, "default"),
    ],
)
def test_bad_coursing_is_refused_with_the_reason(body, problem):
    with pytest.raises(ValueError, match=problem):
        clean_coursing(body)


def test_coursing_off_keeps_the_courses_for_when_it_comes_back():
    store = SettingStore()
    saved = store.put("coursing", clean_coursing({**DEFAULTS["coursing"], "enabled": False}))
    assert saved["enabled"] is False and pairs(saved) == STANDARD and saved["default"] == "1"
    # an older row that only said "off" still shows the standard courses once it is on again
    assert pairs(store.put("coursing", {"enabled": False})) == STANDARD


def test_coursing_is_set_by_a_manager_and_read_by_every_terminal():
    c = client()
    assert c.get("/settings/coursing").json() == DEFAULTS["coursing"]
    assert [x["id"] for x in c.get("/floor").json()["courses"]] == ["drinks", "1", "2", "3"]

    body = {
        "enabled": True,
        "default": "soup",
        "courses": [{"id": "drinks", "name": "Drinks"}, {"name": "Soup"}, {"id": "2", "name": "Mains"}],
    }
    assert c.put("/settings/coursing", json=body).status_code == 401
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    auth = {"authorization": f"Bearer {token}"}
    saved = c.put("/settings/coursing", json=body, headers=auth).json()
    assert pairs(saved) == [("drinks", "Drinks"), ("soup", "Soup"), ("2", "Mains")] and saved["default"] == "soup"
    assert c.get("/settings/coursing").json() == saved
    assert pairs(c.get("/floor").json()) == pairs(saved)  # the floor map and the order screen follow

    r = c.put("/settings/coursing", json={"enabled": True, "courses": []}, headers=auth)
    assert r.status_code == 422 and "at least one course" in r.json()["detail"]["message"]

    off = c.put("/settings/coursing", json={**body, "enabled": False}, headers=auth).json()
    assert off["enabled"] is False and pairs(off) == pairs(saved)
    assert c.get("/floor").json()["courses"] == []  # nothing to course by while it is off


def test_the_kitchen_ticket_names_the_course_as_the_manager_did():
    printer = FakePrinter()
    try:
        c = client(PrintService([Printer("kitchen", printer.address)]))
        token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
        body = {"enabled": True, "courses": [{"id": "1", "name": "Starters"}, {"id": "2", "name": "Mains"}]}
        assert c.put("/settings/coursing", json=body, headers={"authorization": f"Bearer {token}"}).status_code == 200
        c.post(
            "/orders/o1/ops",
            json=[
                payload("a", "create", 0, table="A7", guests=2),
                payload("b", "add_line", 1, line_id="L1", item="?", seat=1, course="1", request=GTC_QUART),
                payload("c", "add_line", 2, line_id="L2", item="?", seat=1, course="old", request=GTC_QUART),
                payload("d", "fire", 3, course="1"),
            ],
        )
        c.post("/orders/o1/ops", json=[payload("e", "fire", 4, course="old")])
        wait_for(lambda: len(printer.jobs) == 2)
        printed = [line for job in printer.jobs for line in decode(job).text]
        assert "Course: Starters" in printed
        assert "Course: old" in printed  # a course no longer on the list keeps its id on the ticket
    finally:
        printer.close()
