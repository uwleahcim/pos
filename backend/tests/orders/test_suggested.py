"""Suggestions taken: which of the dishes the app suggested were added, and by whom (docs/goes-with.md).

A dish added from the tray "Goes with ..." says which dish it went with. The line is a sale like any other;
the mark only lets a manager read, over any days, how often each suggestion was taken and who took it. These
tests ring an evening through the hub the way the screens do and read the report the way a manager gets it."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal

import pytest

from pos.menu.defs import Definitions
from pos.menu.service import load_definitions
from pos.orders.sales import MAX_DAYS
from pos.sync.hlc import HLC

from .test_day import BEER, DRAGON, DSN, EGGROLL, PUPU, SODA, TEA, WINGS, Hub, at

MONDAY = "2026-11-16"


def ring(h: Hub, order_id: str, line_id: str, request: dict, when: int, *, by: str = "Amy", qty: int = 1, **more):
    """A dish as a screen rings it; `went_with` names the dish whose suggestion it was."""
    by_id = {"Amy": "s1", "Ben": "s2", "Mike": "s3"}[by]
    request = {**request, "qty": qty}
    h.op(order_id, "add_line", when, line_id=line_id, item="?", qty=qty, request=request, by=by, by_id=by_id, **more)


def change(h: Hub, order_id: str, when: int, *ops: tuple[str, dict]) -> None:
    """Several operations in one batch, as a screen sends a changed dish: the void and what takes its place."""
    h.now = max(h.now, when)
    batch = [
        {
            "op_id": f"{order_id}-change-{when}-{n}",
            "order_id": order_id,
            "hlc": str(HLC(when, n, "t1")),
            "device": "t1",
            "kind": kind,
            "data": {"by": "Amy", "by_id": "s1", **data},
        }
        for n, (kind, data) in enumerate(ops, start=1)
    ]
    answer = h.c.post(f"/orders/{order_id}/ops", json=batch)
    assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text


def night(h: Hub | None = None) -> Hub:
    """Monday the 16th:

    - o1, table 12: Amy rings a pu pu platter and takes two of its suggestions, a beer and then two more
      beers; Ben rings wings and takes a soda with them; Amy rings a beer nobody suggested.
    - o2, to go: Amy rings a pu pu platter and takes nothing with it.
    """
    h = h or Hub(now=at(17))
    h.table("o1", at(17))
    ring(h, "o1", "L1", PUPU, at(17, 1))
    ring(h, "o1", "L2", BEER, at(17, 2), went_with="PUPU")
    ring(h, "o1", "L3", BEER, at(17, 3), qty=2, went_with="PUPU")
    ring(h, "o1", "L4", WINGS, at(17, 4), by="Ben")
    ring(h, "o1", "L5", SODA, at(17, 5), by="Ben", went_with="WINGS")
    ring(h, "o1", "L6", BEER, at(17, 6))
    h.op("o1", "fire", at(17, 7))
    h.to_go("o2", at(18))
    ring(h, "o2", "L1", PUPU, at(18, 1))
    h.op("o2", "fire", at(18, 2))
    h.now = at(21)
    return h


def report(h: Hub, first: str = MONDAY, last: str = MONDAY) -> dict:
    answer = h.c.get("/reports/suggestions", params={"from": first, "to": last}, headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def test_the_report_is_for_whoever_reads_the_reports():
    h = night()
    assert h.c.get("/reports/suggestions").status_code == 401
    assert h.c.get("/reports/suggestions", headers={"authorization": "Bearer nobody"}).status_code == 401
    assert h.c.get("/reports/suggestions", headers=h.manager()).status_code == 200


def test_each_suggestion_taken_is_under_the_dish_it_went_with():
    said = report(night())
    assert (said["from"], said["to"], said["days"], said["max_days"]) == (MONDAY, MONDAY, 1, MAX_DAYS)
    assert said["running"] is True and said["now_ms"] == at(21)  # Monday is not over at nine
    assert (said["taken"], said["amount"]) == (4, "22.45")  # three beers and a soda
    assert said["dishes"] == [
        {
            "item": "PUPU",
            "name": "Pu Pu Platter",
            "sold": 2,  # two platters went out, with or without anything
            "taken": 3,
            "amount": "19.50",
            "added": [{"item": "TSINGTAO", "name": "Tsingtao", "taken": 3, "amount": "19.50"}],
        },
        {
            "item": "WINGS",
            "name": "Chicken wings",
            "sold": 1,
            "taken": 1,
            "amount": "2.95",
            "added": [{"item": "SODA", "name": "Soda", "taken": 1, "amount": "2.95"}],
        },
    ]


def test_who_took_them_the_most_first():
    said = report(night())
    assert said["staff"] == [
        {"staff_id": "s1", "name": "Amy", "taken": 3, "amount": "19.50"},
        {"staff_id": "s2", "name": "Ben", "taken": 1, "amount": "2.95"},
    ]


def test_nothing_taken_reads_as_nothing():
    h = Hub(now=at(17))
    h.table("o1", at(17))
    ring(h, "o1", "L1", PUPU, at(17, 1))
    said = report(h)
    assert (said["taken"], said["amount"], said["dishes"], said["staff"]) == (0, "0.00", [], [])


def suggesting(**named: tuple[str, ...]) -> Definitions:
    """The restaurant's menu with what goes with some dishes set, as a manager sets it in the menu editor."""
    defs = load_definitions("restaurant")
    for code, with_ in named.items():
        item = defs.items[code]
        defs.items[code] = replace(item, attrs={**item.attrs, "goes_with": list(with_)})
    return defs


def test_a_dish_that_suggests_and_sold_with_nothing_taken_is_listed():
    """The dragon roll suggests a beer and a tea; two went out and nobody took either: the row to look at.
    The egg roll suggests a tea too, and none was sold in these days: nothing to say about it."""
    h = night(Hub(now=at(17), defs=suggesting(DRAGON=("TSINGTAO", "TEA"), EGGROLL=("TEA",))))
    ring(h, "o1", "L9", DRAGON, at(17, 9), qty=2)
    h.now = at(21)
    said = report(h)
    assert [dish["item"] for dish in said["dishes"]] == ["PUPU", "WINGS", "DRAGON"]  # nothing taken comes last
    assert said["dishes"][2] == {
        "item": "DRAGON",
        "name": "Dragon roll",
        "sold": 2,
        "taken": 0,
        "amount": "0.00",
        "added": [
            {"item": "TSINGTAO", "name": "Tsingtao", "taken": 0, "amount": "0.00"},
            {"item": "TEA", "name": "Hot tea", "taken": 0, "amount": "0.00"},
        ],
    }
    assert (said["taken"], said["amount"]) == (4, "22.45")  # the totals are the suggestions taken, as before


def test_a_suggestion_nobody_took_is_under_its_dish_after_the_ones_taken():
    h = night(Hub(now=at(17), defs=suggesting(PUPU=("MAITAI", "TSINGTAO", "TEA"))))
    pupu = report(h)["dishes"][0]
    assert [(row["item"], row["taken"]) for row in pupu["added"]] == [("TSINGTAO", 3), ("MAITAI", 0), ("TEA", 0)]


def test_a_dish_off_sale_is_not_listed_as_a_suggestion_nobody_took():
    defs = suggesting(PUPU=("MAITAI", "TSINGTAO"), DRAGON=("MAITAI",))
    defs.items["MAITAI"] = replace(defs.items["MAITAI"], active=False)
    h = night(Hub(now=at(17), defs=defs))
    ring(h, "o1", "L9", DRAGON, at(17, 9))
    h.now = at(21)
    said = report(h)
    assert [row["item"] for row in said["dishes"][0]["added"]] == ["TSINGTAO"]
    assert [dish["item"] for dish in said["dishes"]] == ["PUPU", "WINGS"]  # the roll has nothing to suggest now


def test_a_suggested_dish_is_a_sale_like_any_other():
    """The mark changes no figure: the day's report and the dishes sold read the same with it or without."""
    marked, plain = night(), Hub(now=at(17))
    plain.table("o1", at(17))
    ring(plain, "o1", "L1", PUPU, at(17, 1))
    ring(plain, "o1", "L2", BEER, at(17, 2))
    ring(plain, "o1", "L3", BEER, at(17, 3), qty=2)
    ring(plain, "o1", "L4", WINGS, at(17, 4), by="Ben")
    ring(plain, "o1", "L5", SODA, at(17, 5), by="Ben")
    ring(plain, "o1", "L6", BEER, at(17, 6))
    plain.op("o1", "fire", at(17, 7))
    plain.to_go("o2", at(18))
    ring(plain, "o2", "L1", PUPU, at(18, 1))
    plain.op("o2", "fire", at(18, 2))
    plain.now = at(21)
    for key in ("sales", "categories", "staff", "hours"):
        assert marked.report()[key] == plain.report()[key], key

    def dishes(h: Hub) -> list[tuple]:
        days = {"from": MONDAY, "to": MONDAY}
        rows = h.c.get("/reports/dishes", params=days, headers=h.manager()).json()["dishes"]
        return [(row["item"], row["count"], row["amount"]) for row in rows if row["count"]]

    assert dishes(marked) == dishes(plain)
    days = {"from": MONDAY, "to": MONDAY}
    sales = [h.c.get("/reports/sales", params=days, headers=h.manager()).json() for h in (marked, plain)]
    assert sales[0] == sales[1]
    assert ("TSINGTAO", 4, "26.00") in dishes(marked)
    assert marked.check("o1")["total"] == plain.check("o1")["total"]


def test_what_came_off_is_not_counted():
    h = night()
    # a tea suggested with an egg roll, sent and then voided; one taken off before it was sent; and a check
    # voided whole with a suggestion on it
    h.table("o3", at(19), table="5")
    ring(h, "o3", "L1", EGGROLL, at(19, 1))
    ring(h, "o3", "L2", TEA, at(19, 2), went_with="EGGROLL")
    ring(h, "o3", "L3", TEA, at(19, 3), went_with="EGGROLL")
    h.op("o3", "fire", at(19, 4))
    h.op("o3", "void_line", at(19, 10), line_id="L2", reason="kitchen-error", by="Amy")
    ring(h, "o3", "L4", SODA, at(19, 11), went_with="EGGROLL")
    h.op("o3", "void_line", at(19, 12), line_id="L4", by="Amy")
    h.to_go("o4", at(19, 30), name="Kim")
    ring(h, "o4", "L1", WINGS, at(19, 31))
    ring(h, "o4", "L2", SODA, at(19, 32), went_with="WINGS")
    h.op("o4", "void_order", at(19, 40))
    h.now = at(21)
    said = report(h)
    egg = next(dish for dish in said["dishes"] if dish["item"] == "EGGROLL")
    assert (egg["taken"], egg["amount"], [row["item"] for row in egg["added"]]) == (1, "2.50", ["TEA"])
    wings = next(dish for dish in said["dishes"] if dish["item"] == "WINGS")
    assert (wings["sold"], wings["taken"]) == (1, 1)  # the voided check's wings and soda are in neither
    assert said["taken"] == 5


def test_a_changed_dish_keeps_what_it_went_with():
    h = night()
    # two more of the beer the kitchen already has: the screen voids the line and rings the changed one in
    # its place, both at once, and says nothing of where the first one came from
    change(
        h,
        "o1",
        at(19),
        ("void_line", {"line_id": "L2"}),
        ("add_line", {"line_id": "L7", "item": "?", "qty": 3, "request": {**BEER, "qty": 3}, "replaces": "L2"}),
    )
    h.op("o1", "fire", at(19, 1))
    h.now = at(21)
    said = report(h)
    assert said["dishes"][0]["added"] == [{"item": "TSINGTAO", "name": "Tsingtao", "taken": 5, "amount": "32.50"}]
    assert h.c.get("/orders/o1").json()["lines"]["L7"]["went_with"] == "PUPU"


def test_a_dish_that_changes_checks_keeps_what_it_went_with():
    h = night()
    h.table("o5", at(19), table="8")
    # the soda goes to table 8: the hub reads what it is from the check it comes from, the mark with it
    h.op("o5", "add_line", at(19, 1), line_id="M1", item="?", qty=1, **{"from": {"order_id": "o1", "line_id": "L5"}})
    h.op("o1", "move_line", at(19, 1), line_id="L5", to={"order_id": "o5", "line_id": "M1"})
    h.now = at(21)
    assert h.c.get("/orders/o5").json()["lines"]["M1"]["went_with"] == "WINGS"
    said = report(h)
    wings = next(dish for dish in said["dishes"] if dish["item"] == "WINGS")
    assert (wings["taken"], wings["amount"]) == (1, "2.95")  # once, on the check it is on now
    assert said["taken"] == 4


@pytest.mark.parametrize("said", [7, ["PUPU"], {"item": "PUPU"}, "", "x" * 121])
def test_a_mark_that_is_no_dish_code_is_not_kept(said):
    h = Hub(now=at(17))
    h.table("o1", at(17))
    ring(h, "o1", "L1", BEER, at(17, 1), went_with=said)
    assert h.c.get("/orders/o1").json()["lines"]["L1"]["went_with"] is None
    assert report(h)["taken"] == 0
    assert h.check("o1")["subtotal"] == "6.50"  # and the beer is on the check all the same


def test_a_dish_off_the_menu_since_is_named_as_it_was_sold():
    h = night()
    ring(h, "o1", "L8", SODA, at(17, 8), went_with="GONE")
    h.now = at(21)
    gone = next(dish for dish in report(h)["dishes"] if dish["item"] == "GONE")
    assert (gone["name"], gone["sold"], gone["taken"]) == ("GONE", 0, 1)


def test_the_days_asked_for_are_the_days_counted():
    h = night(Hub(now=at(17, day=15)))
    h.table("y1", at(19, day=15), table="3")
    ring(h, "y1", "L1", EGGROLL, at(19, 1, day=15))
    ring(h, "y1", "L2", TEA, at(19, 2, day=15), went_with="EGGROLL")
    h.now = at(21)
    assert report(h)["taken"] == 4
    both = report(h, "2026-11-15", MONDAY)
    assert (both["days"], both["taken"], both["amount"]) == (2, 5, str(Decimal("22.45") + Decimal("2.50")))
    sunday = report(h, "2026-11-15", "2026-11-15")
    assert (sunday["taken"], sunday["running"]) == (1, False)
    assert both["running"] is True
    assert h.c.get("/reports/suggestions", params={"from": "Monday"}, headers=h.manager()).status_code == 422


def test_reading_writes_nothing():
    h = night()
    before, day = h.store.cursor, h.report()
    report(h)
    report(h)
    assert h.store.cursor == before and h.report() == day


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_report_is_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(17), postgres=DSN)
    try:
        night(h)
        memory = report(night())
        assert report(h) == memory
        assert report(h) == memory  # and again, from what is remembered
        assert memory["taken"] == 4
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
