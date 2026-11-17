"""The waste log: the kitchen writes down food that was not sold (a dish of the menu or something typed, how
many, and a reason from the location's list), a mistaken entry is struck out and never deleted, a manager
reads the totals by day, by reason and by dish, and none of it is part of the sales."""

from __future__ import annotations

import os
from dataclasses import replace
from datetime import UTC, date, datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.defs import Entry, Item, Variant, money
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import PrintService
from pos.settings import STANDARD_WASTE_REASONS, WASTE_REASONS_MAX, clean_waste
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts
from pos.waste import MAX_DAYS, MOST_A_DAY, NAME_MAX, NOTE_MAX, QTY_MAX, Refused, WasteLog, WasteStore

DSN = os.environ.get("POS_TEST_DATABASE_URL")
DINNER = datetime(2026, 11, 16, 23, 0, tzinfo=UTC)  # the menu's own clock: dinner is on

WINGS = "WINGS:6pc"  # 8.95
EGGROLL = "EGGROLL:regular"  # 3.50
QUART = "GTC:quart"  # 24.95
PINT = "GTC:pint"  # 13.95


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """That time of that day of November 2026 on the restaurant's own clock, as wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


def menu():
    """The sample menu with a dish whose price is typed when it is rung, and a lunch price of its own."""
    defs = load_definitions("restaurant")
    defs.add(
        Item("LOBSTER", "entrees", {"en": "Twin Lobsters"}, attrs={"asks_price": True}),
        Variant("LOBSTER:regular", "LOBSTER", "regular", {"en": "Regular"}, money(0)),
        Entry("dinner:LOBSTER", "dinner", "dinner/chefs", "LOBSTER", "L1"),
    )
    lunch = next(i for i, e in enumerate(defs.entries) if e.id == "lunch:L12")
    defs.entries[lunch] = replace(defs.entries[lunch], price_overrides={"GTC:lunch": Decimal("9.95")})
    return defs


class Hub:
    """A hub whose clock the test sets, and the screens' calls to it."""

    def __init__(self, now: int = at(18), store: WasteStore | None = None) -> None:
        self.now = now
        self.ops = OpStore(physical=lambda: self.now)
        self.waste = WasteLog(store, now_ms=lambda: self.now)
        self.c = TestClient(
            create_app(
                self.ops,
                menu=MenuService(menu(), now=lambda: DINNER),
                taxes=massachusetts(),
                printing=PrintService([]),
                waste=self.waste,
            )
        )
        self._manager: dict[str, str] | None = None

    def manager(self) -> dict[str, str]:
        if self._manager is None:
            token = self.c.post("/admin/session", json={"device": "office", "pin": "9999"}).json()["token"]
            self._manager = {"authorization": f"Bearer {token}"}
        return self._manager

    def log(self, when: int | None = None, *, staff: str = "s1", ok: bool = True, **fields):
        """Somebody writes an entry at a screen. Without `ok`, the hub's answer as it came."""
        if when is not None:
            self.now = when
        body = {"staff_id": staff, "qty": 1, "reason": "Dropped", **fields}
        answer = self.c.post("/waste", json=body)
        if not ok:
            return answer
        assert answer.status_code == 200, answer.text
        return answer.json()

    def day(self, day: str | None = None) -> dict:
        answer = self.c.get("/waste", params={"day": day} if day else {})
        assert answer.status_code == 200, answer.text
        return answer.json()

    def strike(self, entry_id: str, *, staff: str = "s1", manager: bool = False):
        headers = self.manager() if manager else {}
        return self.c.post(f"/waste/{entry_id}/strike", json={"staff_id": "" if manager else staff}, headers=headers)

    def report(self, first: str | None = None, last: str | None = None) -> dict:
        params = {name: day for name, day in (("from", first), ("to", last)) if day}
        answer = self.c.get("/reports/waste", params=params, headers=self.manager())
        assert answer.status_code == 200, answer.text
        return answer.json()


def refused(answer) -> tuple[int, str]:
    return answer.status_code, answer.json()["detail"]["error"]


# Writing an entry ------------------------------------------------------------------------------------------


def test_a_dish_is_written_with_the_menus_own_name_and_price():
    h = Hub()
    entry = h.log(at(18, 5), variant_id=QUART, qty=2, reason="Burnt", note="left on the wok", name="whatever")
    # the hub names and prices the dish from its menu: what a screen calls it does not count
    assert (entry["name"], entry["item"], entry["variant_id"]) == ("General Tso's Chicken (Quart)", "GTC", QUART)
    assert (entry["qty"], entry["each"], entry["value"]) == (2, "24.95", "49.90")
    assert (entry["reason"], entry["note"], entry["by"], entry["by_id"]) == ("Burnt", "left on the wok", "Amy", "s1")
    assert (entry["at_ms"], entry["day"], entry["struck_ms"]) == (at(18, 5), "2026-11-16", None)

    # a dish with one size is called by its name alone
    assert h.log(variant_id=WINGS)["name"] == "Chicken wings"
    # a menu that prices the size differently says that price (the lunch special)
    lunch = h.log(variant_id="GTC:lunch", entry_id="lunch:L12")
    assert (lunch["name"], lunch["each"]) == ("General Tso's Chicken (Lunch)", "9.95")
    assert h.log(variant_id="GTC:lunch")["each"] == "10.95"
    # a dish whose price is typed when it is rung has none of its own
    lobster = h.log(variant_id="LOBSTER:regular", qty=2)
    assert (lobster["name"], lobster["each"], lobster["value"]) == ("Twin Lobsters", None, None)


def test_something_that_is_not_a_dish_is_typed_and_has_no_price():
    h = Hub()
    entry = h.log(name="  Tray of   white rice ", qty=1, reason="expired")
    assert (entry["name"], entry["item"], entry["variant_id"]) == ("Tray of white rice", None, None)
    assert (entry["each"], entry["value"]) == (None, None)
    assert entry["reason"] == "Expired"  # the words as the location lists them


def test_an_entry_says_what_how_many_and_why():
    h = Hub()
    for bad, error in [
        ({"name": ""}, "no_text"),
        ({"name": "   "}, "no_text"),
        ({"name": "x" * (NAME_MAX + 1)}, "long_text"),
        ({"variant_id": WINGS, "qty": 0}, "bad_qty"),
        ({"variant_id": WINGS, "qty": -1}, "bad_qty"),
        ({"variant_id": WINGS, "qty": QTY_MAX + 1}, "bad_qty"),
        ({"variant_id": WINGS, "reason": ""}, "bad_reason"),
        ({"variant_id": WINGS, "reason": "Given to a friend"}, "bad_reason"),
        ({"variant_id": WINGS, "note": "x" * (NOTE_MAX + 1)}, "long_text"),
        ({"variant_id": "NOPE:regular"}, "unknown_dish"),
    ]:
        assert refused(h.log(ok=False, **bad)) == (422, error), bad
    assert refused(h.log(ok=False, staff="s99", variant_id=WINGS)) == (404, "unknown_staff")
    assert h.day()["entries"] == []  # nothing was written
    assert h.log(variant_id=WINGS, qty=QTY_MAX, name="x" * NAME_MAX, note="y" * NOTE_MAX)["qty"] == QTY_MAX


def test_the_day_is_read_newest_first_with_what_stands_added_up():
    h = Hub()
    h.log(at(17), variant_id=WINGS, qty=2)
    h.log(at(18), name="Tray of rice", qty=3, reason="Expired", staff="s2")
    h.log(at(19), variant_id=EGGROLL, qty=4, reason="Made wrong")
    told = h.day()
    assert [(e["name"], e["qty"], e["value"], e["by"]) for e in told["entries"]] == [
        ("Egg roll", 4, "14.00", "Amy"),
        ("Tray of rice", 3, None, "Ben"),
        ("Chicken wings", 2, "17.90", "Amy"),
    ]
    assert told["total"] == {"entries": 3, "count": 9, "value": "31.90", "unpriced": 3}
    assert (told["day"], told["today"]) == ("2026-11-16", True)
    # and what a screen needs to write the next one
    assert told["reasons"] == STANDARD_WASTE_REASONS
    assert told["limits"] == {"name": NAME_MAX, "note": NOTE_MAX, "qty": QTY_MAX}


def test_a_day_of_service_runs_past_midnight():
    h = Hub()
    h.log(at(23, 30), variant_id=WINGS)
    h.log(at(1, 30, day=17), variant_id=EGGROLL, reason="Expired")  # closing up: still Monday's service
    h.log(at(11, day=17), variant_id=QUART)
    assert [e["name"] for e in h.day("2026-11-16")["entries"]] == ["Egg roll", "Chicken wings"]
    today = h.day()
    assert (today["day"], [e["name"] for e in today["entries"]]) == ("2026-11-17", ["General Tso's Chicken (Quart)"])
    assert h.day("2026-11-16")["today"] is False
    assert h.c.get("/waste", params={"day": "2026-13-40"}).status_code == 422


# Striking out ----------------------------------------------------------------------------------------------


def test_an_entry_is_struck_out_never_deleted():
    h = Hub()
    wrong = h.log(at(18), variant_id=QUART, qty=10)
    h.log(at(18, 1), variant_id=QUART, qty=1)
    h.now = at(18, 5)
    struck = h.strike(wrong["id"])
    assert struck.status_code == 200
    assert (struck.json()["struck_ms"], struck.json()["struck_by"]) == (at(18, 5), "Amy")
    told = h.day()
    # it is still read, marked, and counts in no total
    assert [(e["qty"], e["struck_by"]) for e in told["entries"]] == [(1, ""), (10, "Amy")]
    assert told["total"] == {"entries": 1, "count": 1, "value": "24.95", "unpriced": 0}
    # striking it again changes nothing
    h.now = at(18, 9)
    assert h.strike(wrong["id"]).json()["struck_ms"] == at(18, 5)
    assert refused(h.strike("no-such-entry")) == (404, "unknown_entry")


def test_who_may_strike_an_entry_out():
    h = Hub()
    amys = h.log(at(18), variant_id=WINGS)
    # somebody else does not; nobody without a name does
    assert refused(h.strike(amys["id"], staff="s2")) == (409, "not_yours")
    assert refused(h.strike(amys["id"], staff="s99")) == (404, "unknown_staff")
    assert refused(h.strike(amys["id"], staff="")) == (404, "unknown_staff")
    # the next day the one who wrote it does not either: the day has been read by then
    h.now = at(11, day=17)
    assert refused(h.strike(amys["id"])) == (409, "past")
    assert h.day("2026-11-16")["total"]["count"] == 1
    # a manager does, any day, and the log says it was them
    struck = h.strike(amys["id"], manager=True)
    assert (struck.status_code, struck.json()["struck_by"]) == (200, "Mike")
    # a token that is no manager's is nobody special
    token, _ = h.c.app.state.tokens.issue("s2", "Ben", "bartender")
    bens = h.log(variant_id=EGGROLL, staff="s1")
    as_ben = h.c.post(
        f"/waste/{bens['id']}/strike", json={"staff_id": "s2"}, headers={"authorization": f"Bearer {token}"}
    )
    assert refused(as_ben) == (409, "not_yours")


# The report ------------------------------------------------------------------------------------------------


def week(h: Hub) -> Hub:
    """Three days of a kitchen's waste: Saturday the 14th, Sunday the 15th and Monday the 16th."""
    h.log(at(19, day=14), variant_id=QUART, qty=2, reason="Burnt")
    h.log(at(20, day=14), variant_id=WINGS, qty=1, reason="Dropped")
    h.log(at(22, day=14), name="Tray of white rice", qty=2, reason="Expired")
    h.log(at(18, day=15), variant_id=QUART, qty=1, reason="Made wrong")
    h.log(at(19, day=15), variant_id=PINT, qty=1, reason="Burnt")
    h.log(at(23, day=15), name="tray of white rice", qty=1, reason="Expired", staff="s2")
    mistake = h.log(at(12, day=16), variant_id=WINGS, qty=50, reason="Dropped")
    h.strike(mistake["id"])
    h.log(at(18, day=16), variant_id=WINGS, qty=3, reason="Dropped")
    h.now = at(21)
    return h


def test_the_report_adds_the_days_up_by_day_by_reason_and_by_dish():
    told = week(Hub()).report("2026-11-13", "2026-11-16")
    assert (told["from"], told["to"]) == ("2026-11-13", "2026-11-16")
    # 2 + 1 quarts, 1 pint, 1 + 3 wings; 3 trays of rice with no price
    assert told["total"] == {"entries": 7, "count": 11, "value": "124.60", "unpriced": 3}
    assert told["struck"] == 1  # the fifty wings count nowhere
    assert [(d["day"], d["count"], d["value"]) for d in told["days"]] == [
        ("2026-11-13", 0, "0.00"),  # a day with nothing is still a line
        ("2026-11-14", 5, "58.85"),
        ("2026-11-15", 3, "38.90"),
        ("2026-11-16", 3, "26.85"),
    ]
    # what cost the most first; what has no price, last
    assert [(r["name"], r["count"], r["value"]) for r in told["reasons"]] == [
        ("Burnt", 3, "63.85"),
        ("Dropped", 4, "35.80"),
        ("Made wrong", 1, "24.95"),
        ("Expired", 3, "0.00"),
    ]
    # two sizes of a dish are two lines; the same words typed twice are one
    assert [(d["name"], d["count"], d["value"], d["typed"]) for d in told["dishes"]] == [
        ("General Tso's Chicken (Quart)", 3, "74.85", False),
        ("Chicken wings", 4, "35.80", False),
        ("General Tso's Chicken (Pint)", 1, "13.95", False),
        ("tray of white rice", 3, "0.00", True),
    ]
    for rows in (told["days"], told["reasons"], told["dishes"]):
        assert sum(r["count"] for r in rows) == told["total"]["count"]
        assert sum(Decimal(r["value"]) for r in rows) == Decimal(told["total"]["value"])


def test_the_report_of_no_days_asked_is_the_running_day_and_one_day_is_that_day():
    h = week(Hub())
    today = h.report()
    assert (today["from"], today["to"], today["total"]["count"]) == ("2026-11-16", "2026-11-16", 3)
    sunday = h.report("2026-11-15")
    assert (sunday["from"], sunday["to"], sunday["total"]["count"]) == ("2026-11-15", "2026-11-15", 3)
    assert h.report(last="2026-11-14")["total"]["count"] == 5


def test_the_report_is_a_managers_and_a_span_has_to_make_sense():
    h = week(Hub())
    assert h.c.get("/reports/waste").status_code == 401
    server, _ = h.c.app.state.tokens.issue("s1", "Amy", "server")
    assert h.c.get("/reports/waste", headers={"authorization": f"Bearer {server}"}).status_code == 403
    backwards = h.c.get("/reports/waste", params={"from": "2026-11-16", "to": "2026-11-14"}, headers=h.manager())
    assert refused(backwards) == (422, "bad_value")
    long = h.c.get("/reports/waste", params={"from": "2026-08-16", "to": "2026-11-16"}, headers=h.manager())
    assert refused(long) == (422, "too_long") and long.json()["detail"]["max_days"] == MAX_DAYS
    assert h.c.get("/reports/waste", params={"from": "yesterday"}, headers=h.manager()).status_code == 422


# Beside the sales, never part of them ----------------------------------------------------------------------


def test_the_waste_log_changes_nothing_in_the_sales():
    """A dish is rung, sent and paid; the same dish is then written into the waste log, and struck out. The
    check, the day's report, the sales and the dishes sold read exactly as they did: the log takes nothing
    out of the sales and puts nothing in."""
    h = Hub(at(18))

    def op(kind: str, when: int, **data) -> None:
        h.now = when
        body = {
            "op_id": f"o1-{kind}-{when}",
            "order_id": "o1",
            "hlc": str(HLC(when, 0, "t1")),
            "device": "t1",
            "kind": kind,
            "data": data,
        }
        answer = h.c.post("/orders/o1/ops", json=[body])
        assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text

    op("create", at(18), table="12", guests=2, order_type="dine_in")
    wings = {"variant_id": WINGS, "entry_id": "dinner:3", "qty": 2}
    op("add_line", at(18, 1), line_id="L1", item="?", qty=2, request=wings, by="Amy", by_id="s1")
    op("fire", at(18, 2))
    total = h.c.get("/orders/o1/check").json()["total"]
    op("pay", at(18, 40), payment_id="P1", method="cash", amount=total, by="Amy")

    def books() -> list:
        h.now = at(21)
        return [
            h.c.get("/orders/o1").json(),
            h.c.get("/orders/o1/check").json(),
            h.c.get("/reports/day", headers=h.manager()).json(),
            h.c.get("/reports/sales", headers=h.manager()).json(),
            h.c.get("/reports/dishes", headers=h.manager()).json(),
        ]

    before = books()
    assert Decimal(before[3]["span"]["sales"]["net"]) == Decimal("17.90")
    written = h.log(at(20), variant_id=WINGS, qty=2)
    h.log(at(20, 1), name="Tray of rice", reason="Expired")
    assert books() == before
    h.now = at(20, 5)
    assert h.strike(written["id"]).status_code == 200
    assert books() == before
    # and the log wrote no operation on any order
    assert len(h.ops) == 4 and h.ops.order_ids() == ["o1"]


# The location's own reasons --------------------------------------------------------------------------------


def test_the_reasons_are_the_locations_own():
    h = Hub()
    told = h.c.get("/settings/waste").json()
    assert told["reasons"] == STANDARD_WASTE_REASONS
    assert "Given away" not in told["reasons"]  # a dish given to a guest is a comp, on the check
    listed = {"reasons": ["Dropped", "  Burnt ", "Fell   off the pass"]}
    assert h.c.put("/settings/waste", json=listed).status_code == 401
    server, _ = h.c.app.state.tokens.issue("s1", "Amy", "server")
    assert h.c.put("/settings/waste", json=listed, headers={"authorization": f"Bearer {server}"}).status_code == 403
    saved = h.c.put("/settings/waste", json=listed, headers=h.manager())
    assert saved.status_code == 200 and saved.json()["reasons"] == ["Dropped", "Burnt", "Fell off the pass"]
    assert h.day()["reasons"] == ["Dropped", "Burnt", "Fell off the pass"]
    # an entry is written with a reason of the list as it is now
    assert refused(h.log(ok=False, variant_id=WINGS, reason="Expired")) == (422, "bad_reason")
    kept = h.log(variant_id=WINGS, reason="Fell off the pass")
    # and keeps its words when the list changes afterwards
    h.c.put("/settings/waste", json={"reasons": ["Dropped"]}, headers=h.manager())
    assert [e["reason"] for e in h.day()["entries"]] == ["Fell off the pass"]
    assert h.report()["reasons"][0]["name"] == kept["reason"]


def test_what_the_list_of_reasons_refuses():
    assert clean_waste({}) == {"reasons": STANDARD_WASTE_REASONS}  # left out: the standard ones
    for bad in [
        {"reasons": []},  # every entry says why
        {"reasons": [""]},
        {"reasons": ["Dropped", "dropped"]},
        {"reasons": ["x" * 25]},
        {"reasons": [f"Reason {n}" for n in range(WASTE_REASONS_MAX + 1)]},
        {"reasons": "Dropped"},
        {"reasons": [1, 2]},
        {"reasons": ["Burnt\x07"]},
    ]:
        with pytest.raises(ValueError):
            clean_waste(bad)
    h = Hub()
    told = h.c.put("/settings/waste", json={"reasons": []}, headers=h.manager())
    assert refused(told) == (422, "bad_value")
    assert h.c.get("/settings/waste").json()["reasons"] == STANDARD_WASTE_REASONS  # nothing was saved


# Without the wire ------------------------------------------------------------------------------------------


def test_the_rules_hold_without_the_wire():
    now = [at(18)]
    log = WasteLog(now_ms=lambda: now[0])
    reasons = ["Dropped", "Burnt"]
    with pytest.raises(Refused) as told:
        log.log(name="Wings", qty=True, reason="Dropped", reasons=reasons, by_id="s1", by="Amy")
    assert told.value.code == "bad_qty"
    with pytest.raises(Refused) as told:
        log.log(name="Wings", qty=1, reason=None, reasons=reasons, by_id="s1", by="Amy")
    assert told.value.code == "bad_reason"
    free = log.log(name="Wings", qty=2, reason="burnt", reasons=reasons, each=Decimal("0"), by_id="s1", by="Amy")
    assert (free.reason, free.each, free.value) == ("Burnt", None, None)  # a price of nothing is no price
    with pytest.raises(Refused) as told:
        log.report(date(2026, 11, 16), date(2026, 11, 15))
    assert told.value.code == "bad_span"
    # a day takes only so many entries
    for _ in range(MOST_A_DAY - 1):
        log.log(name="Rice", qty=1, reason="Dropped", reasons=reasons, by_id="s1", by="Amy")
    with pytest.raises(Refused) as told:
        log.log(name="Rice", qty=1, reason="Dropped", reasons=reasons, by_id="s1", by="Amy")
    assert told.value.code == "too_many"
    now[0] = at(11, day=17)  # the next day takes its own
    assert log.log(name="Rice", qty=1, reason="Dropped", reasons=reasons, by_id="s1", by="Amy").qty == 1


# PostgreSQL ------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_log_is_kept_in_postgres():
    import psycopg

    from pos.waste import PgWasteStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS waste_entry")
    store = PgWasteStore(DSN)
    try:
        h = week(Hub(store=store))
        same = h.log(at(21), variant_id=WINGS)
        h.log(at(21), name="Rice")  # the same instant: they keep the order they were written in
        mem = week(Hub())
        mem.log(at(21), variant_id=WINGS)
        mem.log(at(21), name="Rice")

        again = PgWasteStore(DSN)  # another process: the hub after a restart
        try:
            later = Hub(at(21, 30), store=again)
            assert [e["name"] for e in later.day()["entries"]][:2] == ["Rice", "Chicken wings"]
            assert later.day()["total"] == mem.day()["total"]
            kept, held = later.report("2026-11-13", "2026-11-16"), mem.report("2026-11-13", "2026-11-16")
            for part in ("total", "struck", "days", "reasons", "dishes"):
                assert kept[part] == held[part], part
            # an entry reads back as it was written, and a strike is kept
            read = again.entry(same["id"])
            assert read is not None and read.as_json() == same
            later.now = at(21, 40)
            assert later.strike(same["id"]).status_code == 200
            assert store.entry(same["id"]).struck_by == "Amy"
            assert again.entry("no-such-entry") is None
        finally:
            again.close()
    finally:
        store.close()
