"""The day's report: what was sold, what was taken for it, what came off and what is still open.

A day is a day of service, four in the morning to four the next. The figures are reckoned from the log each
time they are asked, they add up, and every payment is in them. These tests ring a small evening through the
hub the way the screens do and read the report a manager gets."""

from __future__ import annotations

import itertools
import os
from datetime import UTC, date, datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.service import MenuService, load_definitions
from pos.orders.day import day_report, order_day
from pos.printing.service import Printer, PrintService
from pos.settings import DEFAULTS, SettingStore, clean_time_clock
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts
from pos.timeclock import TimeClock

from ..printing.fake_printer import decode

DSN = os.environ.get("POS_TEST_DATABASE_URL")
DINNER = datetime(2026, 11, 16, 23, 0, tzinfo=UTC)  # the menu's own clock: dinner is on
WINGS = {"variant_id": "WINGS:6pc", "entry_id": "dinner:3"}  # 8.95, Appetizers
EGGROLL = {"variant_id": "EGGROLL:regular", "entry_id": "dinner:1"}  # 3.50, Appetizers
SPRING = {"variant_id": "SPRINGROLL:regular", "entry_id": "dinner:2"}  # 3.25, Appetizers
PUPU = {"variant_id": "PUPU:regular", "entry_id": "dinner:4"}  # 16.95, Appetizers
DRAGON = {"variant_id": "DRAGON:roll", "entry_id": "dinner:S4"}  # 15.95, Rolls
BEER = {"variant_id": "TSINGTAO:bottle", "entry_id": "dinner:B1"}  # 6.50, Beer
SODA = {"variant_id": "SODA:glass", "entry_id": "dinner:D2"}  # 2.95, Drinks
TEA = {"variant_id": "TEA:pot", "entry_id": "dinner:D1"}  # 2.50, Drinks

_ids = itertools.count()


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """That time of that day of November 2026 on the restaurant's own clock, as wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


class Hub:
    """A hub whose clock the test sets, and the screens' calls to it."""

    def __init__(
        self, now: int = at(21), *, clock_on: bool = False, printers: bool = True, postgres: str | None = None
    ) -> None:
        self.now = now
        settings = SettingStore()
        settings.put("time_clock", clean_time_clock({"enabled": clock_on}))
        settings.put("voids", {**DEFAULTS["voids"], "approval": "none"})
        if postgres:
            from pos.sync.pgstore import PgOpStore

            self.store = PgOpStore(postgres, physical=lambda: self.now)
        else:
            self.store = OpStore(physical=lambda: self.now)
        self.printing = PrintService([Printer("takeout", "10.0.0.9", id="front")] if printers else [], direct=False)
        self.clock = TimeClock(None, now_ms=lambda: self.now)
        self.c = TestClient(
            create_app(
                self.store,
                menu=MenuService(load_definitions("restaurant"), now=lambda: DINNER),
                taxes=massachusetts(),
                printing=self.printing,
                settings=settings,
                clock=self.clock,
            )
        )
        self._manager: dict[str, str] | None = None

    def op(self, order_id: str, op_kind: str, when: int, /, **data) -> None:
        """One operation stamped `when`, as a screen sends it; the hub's clock moves on to then."""
        self.now = max(self.now, when)
        body = {
            "op_id": f"{order_id}-{op_kind}-{next(_ids)}",
            "order_id": order_id,
            "hlc": str(HLC(when, next(_ids), "t1")),
            "device": "t1",
            "kind": op_kind,
            "data": data,
        }
        answer = self.c.post(f"/orders/{order_id}/ops", json=[body])
        assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text

    def table(self, order_id: str, when: int, table: str = "12", guests: int = 2) -> None:
        self.op(order_id, "create", when, table=table, guests=guests, order_type="dine_in")

    def to_go(self, order_id: str, when: int, name: str = "Lee", **fields) -> None:
        self.op(order_id, "create", when, order_type="takeout", customer_name=name, channel="phone", **fields)

    def ring(self, order_id: str, line_id: str, request: dict, when: int, *, by: str = "Amy", qty: int = 1) -> None:
        by_id = {"Amy": "s1", "Ben": "s2", "Mike": "s3"}[by]
        request = {**request, "qty": qty}
        self.op(order_id, "add_line", when, line_id=line_id, item="?", qty=qty, request=request, by=by, by_id=by_id)

    def pay(self, order_id: str, when: int, amount: str, method: str = "cash") -> None:
        self.op(order_id, "pay", when, payment_id=f"P{next(_ids)}", method=method, amount=amount, by="Amy")

    def check(self, order_id: str) -> dict:
        return self.c.get(f"/orders/{order_id}/check").json()

    def manager(self) -> dict[str, str]:
        if self._manager is None:
            token = self.c.post("/admin/session", json={"device": "office", "pin": "9999"}).json()["token"]
            self._manager = {"authorization": f"Bearer {token}"}
        return self._manager

    def report(self, day: str | None = None) -> dict:
        answer = self.c.get("/reports/day", params={"day": day} if day else {}, headers=self.manager())
        assert answer.status_code == 200, answer.text
        return answer.json()


def money(value: str) -> Decimal:
    return Decimal(value)


def added(rows: list[dict]) -> Decimal:
    return sum((money(row["amount"]) for row in rows), Decimal(0))


def evening(h: Hub | None = None) -> Hub:
    """Monday the 16th, read at nine in the evening:

    - o1, table 12, two guests: Amy rings wings and two egg rolls, Ben a beer; $2 off as a loyalty reward; paid
      $20 cash and the rest by card; closed.
    - o2, to go for Lee: a pu pu platter, paid elsewhere, closed.
    - o3, table 5, four guests: a spring roll nobody sent. Still open.
    - o4, table 7: an egg roll sent and voided, a dragon roll; closed with nothing paid.
    - o5: a soda, and the whole check voided.
    - o6: rung today for tomorrow evening, with $5 cash down.
    - y1: yesterday's table, still open. y2: yesterday's tab, paid tonight by card.
    """
    h = h or Hub(now=at(19, day=15))
    h.table("y1", at(19, day=15), table="3")
    h.ring("y1", "L1", TEA, at(19, 1, day=15))
    h.table("y2", at(22, day=15), table="4")
    h.ring("y2", "L1", BEER, at(22, 1, day=15))
    h.op("y2", "fire", at(22, 2, day=15))

    h.table("o1", at(17))
    h.ring("o1", "L1", WINGS, at(17, 5))
    h.ring("o1", "L2", EGGROLL, at(17, 6), qty=2)
    h.op("o1", "fire", at(17, 7))
    h.pay("y2", at(17, 10), h.check("y2")["total"], "card")
    h.op("y2", "close", at(17, 11))
    h.to_go("o5", at(17, 30), name="Kim")
    h.ring("o5", "L1", SODA, at(17, 31))
    h.op("o5", "void_order", at(17, 40))
    h.ring("o1", "L3", BEER, at(18, 10), by="Ben")
    h.op("o1", "fire", at(18, 11))
    h.op(
        "o1", "discount", at(18, 20), discount_id="D1", reason="loyalty", kind="amount", value="2.00", applied_by="Amy"
    )
    h.pay("o1", at(18, 30), "20.00", "cash")
    h.pay("o1", at(18, 31), str(money(h.check("o1")["total"]) - 20), "card")
    h.op("o1", "close", at(18, 32))
    h.to_go("o2", at(19))
    h.ring("o2", "L1", PUPU, at(19, 1))
    h.op("o2", "fire", at(19, 2))
    h.pay("o2", at(19, 20), h.check("o2")["total"], "elsewhere")
    h.op("o2", "close", at(19, 21))
    h.to_go("o6", at(19, 30), name="Cho", promised_at=at(18, day=17))
    h.ring("o6", "L1", PUPU, at(19, 31), qty=2)
    h.pay("o6", at(19, 32), "5.00", "cash")
    h.table("o4", at(20), table="7")
    h.ring("o4", "L1", EGGROLL, at(20, 1))
    h.ring("o4", "L2", DRAGON, at(20, 1))
    h.op("o4", "fire", at(20, 2))
    h.op("o4", "void_line", at(20, 10), line_id="L1", reason="kitchen-error", by="Amy")
    h.op("o4", "close", at(20, 30))
    h.table("o3", at(20, 40), table="5", guests=4)
    h.ring("o3", "L1", SPRING, at(20, 41))
    h.now = at(21)
    return h


def test_the_report_is_for_managers():
    h = Hub()
    assert h.c.get("/reports/day").status_code == 401
    assert h.c.get("/reports/day", headers={"authorization": "Bearer nobody"}).status_code == 401
    assert h.c.post("/reports/day/print").status_code == 401
    assert h.c.get("/reports/day", params={"day": "yesterday"}, headers=h.manager()).status_code == 422
    assert h.c.get("/reports/day", params={"day": "2026-02-30"}, headers=h.manager()).status_code == 422


def test_a_day_nothing_happened_on_reads_all_zeroes_and_reading_changes_nothing():
    h = Hub()
    before = h.store.cursor
    report = h.report()
    assert (report["day"], report["today"], report["checks"], report["guests"]) == ("2026-11-16", True, 0, 0)
    assert set(report["sales"].values()) == {"0.00"}
    assert report["money"]["taken"] == [] and report["money"]["taken_total"] == "0.00"
    assert [report[k] for k in ("menus", "categories", "kinds", "staff", "hours", "discounts")] == [[]] * 6
    assert [report[k] for k in ("open", "unpaid", "earlier")] == [[], [], []] and report["unsent"] == 0
    assert report["clock"] is None  # the location does not use the time clock
    assert h.store.cursor == before


def test_the_days_checks_and_what_they_come_to():
    h = evening()
    report = h.report()
    assert (report["day"], report["today"]) == ("2026-11-16", True)
    assert (report["since_ms"], report["until_ms"]) == (at(4), at(4, day=17))
    # o1, o2, o3 and o4: not the voided check, not tomorrow's order, not yesterday's tables
    assert (report["checks"], report["guests"]) == (4, 2 + 4 + 2)
    checks = [h.check(o) for o in ("o1", "o2", "o3", "o4")]
    sales = report["sales"]
    assert sales["gross"] == "58.60" == str(sum(money(c["subtotal"]) for c in checks))
    assert sales["discounts"] == "2.00"
    assert sales["net"] == "56.60"
    assert sales["tax"] == str(sum(money(c["tax"]) for c in checks)) and money(sales["tax"]) > 0
    assert sales["total"] == str(sum(money(c["total"]) for c in checks))
    assert (sales["charges"], sales["gratuity"]) == ("0.00", "0.00")
    assert money(sales["total"]) == money(sales["net"]) + money(sales["tax"])


def test_every_split_of_the_sales_adds_up_to_the_dishes_sold():
    report = evening().report()
    gross = money(report["sales"]["gross"])
    for split in ("menus", "categories", "kinds", "staff", "hours"):
        assert added(report[split]) == gross, split
    assert [(m["name"], m["amount"]) for m in report["menus"]] == [("Dinner", "58.60")]
    assert [(c["name"], c["count"], c["amount"]) for c in report["categories"]] == [
        ("Appetizers", 5, "36.15"),  # wings, two egg rolls, a pu pu platter, a spring roll
        ("Rolls", 1, "15.95"),
        ("Beer", 1, "6.50"),
    ]
    assert [(k["kind"], k["count"], k["guests"], k["amount"]) for k in report["kinds"]] == [
        ("dine_in", 3, 8, "41.65"),
        ("takeout", 1, 0, "16.95"),
    ]
    assert [(s["name"], s["staff_id"], s["amount"]) for s in report["staff"]] == [
        ("Amy", "s1", "52.10"),
        ("Ben", "s2", "6.50"),
    ]
    assert [(row["hour"], row["amount"]) for row in report["hours"]] == [
        (17, "15.95"),
        (18, "6.50"),
        (19, "16.95"),
        (20, "19.20"),
    ]
    assert report["discounts"] == [{"name": "Loyalty reward", "count": 1, "amount": "2.00"}]


def test_the_money_taken_is_every_payment_of_the_day_by_how_it_was_paid():
    h = evening()
    report = h.report()
    taken = {t["method"]: (t["count"], t["amount"]) for t in report["money"]["taken"]}
    o1, o2, y2 = (money(h.check(o)["total"]) for o in ("o1", "o2", "y2"))
    assert [t["method"] for t in report["money"]["taken"]] == ["cash", "card", "elsewhere"]
    assert taken["cash"] == (2, "25.00")  # $20 at table 12 and the $5 down on tomorrow's order
    assert taken["card"] == (2, str(o1 - 20 + y2))
    assert taken["elsewhere"] == (1, str(o2))
    assert money(report["money"]["taken_total"]) == added(report["money"]["taken"]) == o1 + o2 + y2 + 5
    assert report["money"]["for_other_days"] == str(y2 + 5)  # yesterday's tab and tomorrow's order
    assert report["money"]["on_voided"] == "0.00"


def test_the_days_checks_settle_paid_owed_and_over():
    h = evening()
    report = h.report()
    cash = report["money"]
    o3, o4 = (money(h.check(o)["total"]) for o in ("o3", "o4"))
    assert money(cash["paid_this_day"]) == money(h.check("o1")["total"]) + money(h.check("o2")["total"])
    assert (cash["paid_other_days"], cash["over"]) == ("0.00", "0.00")
    assert money(cash["due"]) == o3 + o4
    assert money(report["sales"]["total"]) == money(cash["paid_this_day"]) + money(cash["due"])
    # paid more than the check comes to (a dish voided after it was paid for): the difference is said
    h.pay("o3", at(21, 5), str(o3 + 10), "cash")
    cash = h.report()["money"]
    assert cash["over"] == "10.00" and money(cash["due"]) == o4
    assert money(h.report()["sales"]["total"]) == (
        money(cash["paid_this_day"]) + money(cash["paid_other_days"]) + money(cash["due"]) - money(cash["over"])
    )


def test_what_came_off_and_what_is_still_open():
    h = evening()
    report = h.report()
    assert report["voids"] == {"count": 1, "amount": "3.50"}  # the egg roll at table 7
    assert report["voided_checks"] == {"count": 1, "amount": "2.95"}  # the soda's check
    assert report["taken_off"] == {"count": 0, "amount": "0.00"}
    assert report["typed"] == {"count": 0, "amount": "0.00"}
    assert report["later"]["count"] == 1 and report["later"]["amount"] == h.check("o6")["total"]
    assert [(r["order_id"], r["table"], r["due"], r["unsent"]) for r in report["open"]] == [
        ("o3", "5", h.check("o3")["total"], 1)
    ]
    assert [(r["order_id"], r["status"], r["due"]) for r in report["unpaid"]] == [
        ("o4", "closed", h.check("o4")["total"])
    ]
    assert [(r["order_id"], r["day"], r["table"]) for r in report["earlier"]] == [("y1", "2026-11-15", "3")]
    assert report["unsent"] == 2  # the spring roll at table 5 and the tea at yesterday's table 3


def test_a_dish_taken_off_before_it_was_sent_is_counted_as_that():
    h = evening()
    h.op("o3", "void_line", at(21, 1), line_id="L1", by="Amy", by_id="s1")
    report = h.report()
    assert report["taken_off"] == {"count": 1, "amount": "3.25"}
    assert report["voids"]["count"] == 1 and report["sales"]["gross"] == "55.35"


def test_yesterday_reads_as_yesterday_whenever_it_is_asked():
    h = evening()
    report = h.report("2026-11-15")
    assert (report["today"], report["checks"]) == (False, 2)
    assert report["sales"]["gross"] == "9.00"  # the tea and the beer
    assert report["money"]["taken"] == []  # nothing was paid that night
    y2 = h.check("y2")["total"]
    assert (report["money"]["paid_this_day"], report["money"]["paid_other_days"]) == ("0.00", y2)
    assert report["money"]["due"] == h.check("y1")["total"]
    assert [r["order_id"] for r in report["open"]] == ["y1"]
    assert report["earlier"] == []  # the list of older open checks is for the running day
    assert report["voids"]["count"] == 0  # tonight's void is tonight's


def test_an_order_rung_for_a_later_day_is_that_days_sale():
    h = evening()
    tomorrow = h.report("2026-11-17")
    assert (tomorrow["today"], tomorrow["checks"]) == (False, 1)
    assert tomorrow["sales"]["gross"] == "33.90"
    assert (tomorrow["money"]["paid_other_days"], tomorrow["money"]["taken"]) == ("5.00", [])
    assert order_day(h.store.view("o6")) == date(2026, 11, 17)
    assert order_day(h.store.view("o1")) == date(2026, 11, 16)
    # a promised time that is no time at all leaves the order on the day it was opened, and the report reads
    h.to_go("o7", at(20, 50), name="Odd", promised_at=10**30)
    assert order_day(h.store.view("o7")) == date(2026, 11, 16)
    assert h.report()["checks"] == 5


def prepaid(h: Hub | None = None) -> Hub:
    """Saturday the 14th: three platters rung for Monday the 16th, paid in full by card and closed on the
    spot. Nobody touches the order again. Read on Monday at nine in the evening."""
    h = h or Hub(now=at(15, day=14))
    h.to_go("c1", at(15, day=14), name="Park", promised_at=at(18))
    h.ring("c1", "L1", PUPU, at(15, 1, day=14), qty=3)
    h.pay("c1", at(15, 2, day=14), h.check("c1")["total"], "card")
    h.op("c1", "close", at(15, 3, day=14))
    h.now = at(21)
    return h


def test_an_order_paid_and_closed_the_day_it_was_rung_is_still_a_sale_of_the_day_it_is_for():
    """No sale falls between two days: the order is closed and nothing happens to it on the day it is for,
    and it is that day's sale all the same, with its money said to have come in on another day."""
    h = prepaid()
    total = h.check("c1")["total"]
    rung = h.report("2026-11-14")
    assert (rung["checks"], rung["sales"]["gross"], rung["sales"]["total"]) == (0, "0.00", "0.00")
    assert (rung["later"]["count"], rung["later"]["amount"]) == (1, total)
    assert (rung["money"]["taken_total"], rung["money"]["for_other_days"]) == (total, total)
    between = h.report("2026-11-15")
    assert (between["checks"], between["later"]["count"], between["money"]["taken_total"]) == (0, 0, "0.00")
    today = h.report()
    assert (today["checks"], today["sales"]["gross"], today["sales"]["total"]) == (1, "50.85", total)
    assert today["money"]["taken"] == []
    paid = today["money"]
    assert (paid["paid_this_day"], paid["paid_other_days"], paid["due"]) == ("0.00", total, "0.00")
    assert [today[k] for k in ("open", "unpaid", "earlier")] == [[], [], []]
    # every sale is in one day and one only
    days = [h.report(f"2026-11-{d}") for d in (13, 14, 15, 16, 17)]
    assert [d["sales"]["gross"] for d in days] == ["0.00", "0.00", "0.00", "50.85", "0.00"]


def test_the_night_ends_at_four_so_one_in_the_morning_is_still_the_evening_before():
    h = Hub(now=at(23, 30))
    h.table("late", at(0, 45, day=17), table="9")
    h.ring("late", "L1", BEER, at(0, 46, day=17), by="Ben")
    h.pay("late", at(1, 15, day=17), h.check("late")["total"], "cash")
    h.now = at(1, 30, day=17)
    report = h.report()  # no day asked: the one that is running
    assert (report["day"], report["today"], report["checks"]) == ("2026-11-16", True, 1)
    assert report["money"]["taken"][0]["count"] == 1
    assert [row["hour"] for row in report["hours"]] == [0]
    h.now = at(4, 1, day=17)
    assert (h.report()["day"], h.report()["checks"]) == ("2026-11-17", 0)
    assert h.report("2026-11-16")["checks"] == 1


def test_a_void_tonight_on_yesterdays_tab_is_tonights_void():
    h = evening()
    h.op("y2", "reopen", at(21, 2))
    h.op("y2", "void_line", at(21, 3), line_id="L1", reason="kitchen-error", by="Amy")
    assert h.report()["voids"] == {"count": 2, "amount": "10.00"}
    assert h.report("2026-11-15")["voids"]["count"] == 0
    assert h.report("2026-11-15")["sales"]["gross"] == "2.50"  # the beer is off yesterday's sales


def test_money_on_a_check_voided_since_is_said():
    h = Hub(now=at(18))
    h.to_go("o1", at(18))
    h.ring("o1", "L1", SODA, at(18, 1))
    h.pay("o1", at(18, 2), "3.00", "cash")
    h.op("o1", "void_order", at(18, 5))
    report = h.report()
    assert (report["checks"], report["sales"]["gross"]) == (0, "0.00")
    assert report["money"]["taken_total"] == "3.00" and report["money"]["on_voided"] == "3.00"
    assert report["voided_checks"]["count"] == 1


def test_a_dish_that_left_the_menu_is_still_a_sale():
    h = Hub(now=at(18))
    h.table("o1", at(18))
    gone = {"unit_price": "11.00", "tax_class": "prepared_food", "name": "Last year's special", "item": "GONE"}
    h.op("o1", "add_line", at(18, 1), line_id="L1", item="Special", qty=1, priced=gone, by="Amy", by_id="s1")
    report = h.report()
    assert report["sales"]["gross"] == "11.00"
    assert [(c["name"], c["amount"]) for c in report["categories"]] == [("Off the menu now", "11.00")]


def test_the_report_can_be_reckoned_straight_from_the_orders():
    h = evening()
    states = [h.store.view(o) for o in ("o1", "o2", "o3", "o4", "o5", "o6", "y1", "y2")]
    report = day_report(
        states,
        date(2026, 11, 16),
        taxes=massachusetts(),
        rules=None,
        defs=load_definitions("restaurant"),
        now_ms=at(21),
    )
    assert report["sales"] == h.report()["sales"] and report["money"] == h.report()["money"]


def test_the_time_clocks_part_where_the_location_uses_it():
    h = Hub(now=at(16), clock_on=True)
    for pin in ("1111", "2222"):
        assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": "in"}).status_code == 200
    h.now = at(20)
    assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": "2222", "action": "out"}).status_code == 200
    h.now = at(21)
    clock = h.report()["clock"]
    assert (clock["people"], clock["unended"]) == (2, 0)
    assert clock["worked_ms"] == (5 + 4) * 3_600_000
    assert [(p["name"], p["state"], p["in_ms"]) for p in clock["on_now"]] == [("Amy", "in", at(16))]
    h.now = at(9, day=17)  # the night ended: the hub closed Amy's shift at four, and says so
    yesterday = h.report("2026-11-16")["clock"]
    assert (yesterday["unended"], yesterday["on_now"]) == (1, [])


def test_the_day_prints_where_the_bills_print():
    h = evening()
    answer = h.c.post("/reports/day/print", json={}, headers=h.manager())
    assert answer.status_code == 202, answer.text
    assert answer.json()["printed_at"] == {"id": "front", "name": "takeout"}
    assert answer.json()["day"] == "2026-11-16"
    job = h.printing.store.get(answer.json()["job_id"])
    text = [line.strip() for line in decode(job.data).text if line.strip()]
    report = h.report()
    assert text[:2] == ["THE DAY", "Monday, November 16, 2026"]
    assert any(line.startswith("Printed ") and line.endswith(" by Mike") for line in text)
    assert "The day is still running" in text

    def row(words: str) -> str:
        return next(line for line in text if line.startswith(words)).removeprefix(words).strip()

    assert row("Dishes sold") == "58.60"
    assert row("Comps and discounts") == "-2.00"
    assert row("Net sales") == "56.60"
    assert row("TOTAL") == report["sales"]["total"]
    assert row("4 checks, 8 guests") == ""
    assert row("Cash (2)") == "25.00"
    assert row("TAKEN THIS DAY") == report["money"]["taken_total"]
    assert row("STILL OWED") == report["money"]["due"]
    assert row("Appetizers (5)") == "36.15"
    assert row("Tables (3 checks)") == "41.65" and row("To go (1 check)") == "16.95"
    assert row("Amy") == "52.10"
    assert row("5 PM") == "15.95"
    assert row("Loyalty reward (1)") == "-2.00"
    assert row("Voided after sending (1)") == "3.50"
    assert row("1 check still open") == h.check("o3")["total"]
    assert row("1 closed check not paid in full") == h.check("o4")["total"]
    assert row("1 open check from earlier days") == h.check("y1")["total"]
    assert "2 dishes not sent to the kitchen" in text
    # another day by name; a quiet one still prints, with its zeroes
    quiet = h.c.post("/reports/day/print", json={"day": "2026-11-10"}, headers=h.manager())
    text = [line.strip() for line in decode(h.printing.store.get(quiet.json()["job_id"]).data).text if line.strip()]
    assert text[1] == "Tuesday, November 10, 2026" and "The day is still running" not in text
    assert "Nothing: every check is closed and paid" in text


def test_the_paper_says_who_is_still_on_the_clock_and_the_hours_worked():
    h = Hub(now=at(16), clock_on=True)
    assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": "1111", "action": "in"}).status_code == 200
    h.now = at(21, 30)
    answer = h.c.post("/reports/day/print", json={"day": "2026-11-16"}, headers=h.manager())
    text = [line.strip() for line in decode(h.printing.store.get(answer.json()["job_id"]).data).text if line.strip()]
    assert "Still on the clock: Amy" in text
    assert next(line for line in text if line.startswith("Hours worked (1 person)")).endswith("5 h 30 min")


def test_no_printer_no_paper():
    h = Hub(printers=False)
    answer = h.c.post("/reports/day/print", json={}, headers=h.manager())
    assert answer.status_code == 409 and answer.json()["detail"]["error"] == "no_printer"


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_report_is_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(19, day=15), postgres=DSN)
    try:
        evening(h)
        memory = evening()
        for day in (None, "2026-11-15", "2026-11-17"):
            assert h.report(day) == memory.report(day)
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(15, day=14), postgres=DSN)
    try:
        prepaid(h)
        memory = prepaid()
        for day in (None, "2026-11-14", "2026-11-15"):
            assert h.report(day) == memory.report(day)
        assert h.report()["sales"]["gross"] == "50.85"
    finally:
        h.store.close()
