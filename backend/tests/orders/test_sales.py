"""Sales over a span of days, beside the days before.

The same sales as the day's report, added up over any days from one to a quarter of a year, with the same
figures for as many days whole weeks earlier. These tests ring a few evenings through the hub the way the
screens do and read what a manager gets."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from pos.orders.sales import MAX_DAYS, SaleMemo, comparison, day_sheet, sale_of, sales_report, sales_reports
from pos.tax import massachusetts

from .test_day import BEER, DSN, EGGROLL, PUPU, WINGS, Hub, added, at, evening, money, prepaid, website


def sales(h: Hub, first: str | None = None, last: str | None = None) -> dict:
    params = {name: day for name, day in (("from", first), ("to", last)) if day}
    answer = h.c.get("/reports/sales", params=params, headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def week_before(h: Hub) -> Hub:
    """Monday the 9th, the Monday before `evening`'s: w1, table 2, three guests, two wings and a beer, paid
    by card and closed after fifty minutes; w2, to go, a platter, not paid."""
    h.table("w1", at(18, day=9), table="2", guests=3)
    h.ring("w1", "L1", WINGS, at(18, 1, day=9), qty=2)
    h.ring("w1", "L2", BEER, at(18, 2, day=9))
    h.op("w1", "fire", at(18, 3, day=9))
    h.pay("w1", at(18, 49, day=9), h.check("w1")["total"], "card")
    h.op("w1", "close", at(18, 50, day=9))
    h.to_go("w2", at(19, day=9))
    h.ring("w2", "L1", PUPU, at(19, 1, day=9))
    return h


def test_the_sales_are_for_managers_and_a_span_has_to_make_sense():
    h = Hub()
    assert h.c.get("/reports/sales").status_code == 401
    assert h.c.get("/reports/sales", headers={"authorization": "Bearer nobody"}).status_code == 401
    for params in ({"from": "yesterday"}, {"to": "2026-02-30"}, {"from": "2026-11-16", "to": "2026-11-15"}):
        assert h.c.get("/reports/sales", params=params, headers=h.manager()).status_code == 422, params
    long = h.c.get("/reports/sales", params={"from": "2026-08-16", "to": "2026-11-16"}, headers=h.manager())
    assert long.status_code == 422 and long.json()["detail"]["error"] == "too_long"
    assert long.json()["detail"]["max_days"] == MAX_DAYS == 92
    assert sales(h, "2026-08-17", "2026-11-16")["span"]["checks"] == 0  # 92 days exactly


def test_the_days_to_hold_beside_are_as_many_days_whole_weeks_earlier():
    def beside(first: tuple[int, int], last: tuple[int, int]) -> tuple[date, date]:
        return comparison(date(2026, *first), date(2026, *last))

    assert beside((11, 16), (11, 16)) == (date(2026, 11, 9), date(2026, 11, 9))  # a Monday beside a Monday
    assert beside((11, 9), (11, 15)) == (date(2026, 11, 2), date(2026, 11, 8))  # a week beside the week before
    assert beside((11, 9), (11, 16)) == (date(2026, 10, 26), date(2026, 11, 2))  # eight days: two weeks back
    assert beside((10, 19), (11, 15)) == (date(2026, 9, 21), date(2026, 10, 18))  # four weeks, four weeks back
    for first, last in ((date(2026, 1, 1), date(2026, 1, 1)), (date(2026, 3, 3), date(2026, 5, 20))):
        earlier = comparison(first, last)
        assert earlier[1] < first and earlier[1] - earlier[0] == last - first
        assert earlier[0].weekday() == first.weekday()


def test_nothing_asked_is_the_running_day_beside_the_same_day_a_week_before():
    h = week_before(evening())
    before = h.store.cursor
    answer = sales(h)
    span, earlier = answer["span"], answer["before"]
    assert (span["first"], span["last"], span["running"]) == ("2026-11-16", "2026-11-16", True)
    assert (span["since_ms"], span["until_ms"]) == (at(4), at(4, day=17))
    assert (earlier["first"], earlier["last"], earlier["running"]) == ("2026-11-09", "2026-11-09", False)
    assert (span["checks"], span["sales"]["gross"]) == (4, "58.60")
    assert (earlier["checks"], earlier["guests"], earlier["sales"]["gross"]) == (2, 3, "41.35")
    assert (answer["max_days"], answer["now_ms"]) == (92, at(21))
    assert h.store.cursor == before  # reading changes nothing
    assert sales(h, "2026-11-16") == sales(h, None, "2026-11-16") == answer  # one day named either way


def test_one_day_reads_the_same_sales_as_the_days_report():
    h = week_before(evening())
    for day in ("2026-11-09", "2026-11-15", "2026-11-16", "2026-11-17"):
        span, report = sales(h, day, day)["span"], h.report(day)
        for figure in ("checks", "guests", "sales", "menus", "categories", "kinds", "discounts"):
            assert span[figure] == report[figure], (day, figure)
        assert span["money"]["taken"] == report["money"]["taken"], day
        assert span["money"]["taken_total"] == report["money"]["taken_total"], day
        assert [(d["day"], d["checks"], d["gross"]) for d in span["days"]] == [
            (day, report["checks"], report["sales"]["gross"])
        ]


def test_a_span_is_its_days_added_up_and_every_split_adds_up_to_the_dishes_sold():
    h = week_before(evening())
    span = sales(h, "2026-11-09", "2026-11-17")["span"]
    days = {day: h.report(day) for day in ("2026-11-09", "2026-11-15", "2026-11-16", "2026-11-17")}
    assert [d["day"] for d in span["days"]] == [f"2026-11-{n:02d}" for n in range(9, 18)]  # every day, sold or not
    for row in span["days"]:
        report = days.get(row["day"])
        if report is None:
            assert (row["checks"], row["guests"], row["gross"], row["net"], row["total"]) == (
                0,
                0,
                "0.00",
                "0.00",
                "0.00",
            )
        else:
            assert (row["checks"], row["guests"]) == (report["checks"], report["guests"])
            assert (row["gross"], row["net"], row["total"]) == tuple(
                report["sales"][k] for k in ("gross", "net", "total")
            )
    assert span["checks"] == sum(r["checks"] for r in days.values()) == 2 + 2 + 4 + 1
    assert span["guests"] == sum(r["guests"] for r in days.values())
    for figure in ("gross", "discounts", "net", "charges", "gratuity", "tax", "total"):
        assert money(span["sales"][figure]) == sum(money(r["sales"][figure]) for r in days.values()), figure
    gross = money(span["sales"]["gross"])
    for split in ("menus", "categories", "kinds", "hours"):
        assert added(span[split]) == gross, split
    assert sum(money(d["gross"]) for d in span["days"]) == gross
    assert money(span["money"]["taken_total"]) == sum(money(r["money"]["taken_total"]) for r in days.values())
    assert added(span["money"]["taken"]) == money(span["money"]["taken_total"])
    assert [m["method"] for m in span["money"]["taken"]] == ["cash", "card", "elsewhere"]


def test_the_days_before_are_read_exactly_as_they_read_on_their_own():
    h = week_before(evening())
    a_day = sales(h, "2026-11-16", "2026-11-16")
    assert a_day["before"] == sales(h, "2026-11-09", "2026-11-09")["span"]
    a_week = sales(h, "2026-11-10", "2026-11-16")
    assert (a_week["before"]["first"], a_week["before"]["last"]) == ("2026-11-03", "2026-11-09")
    assert a_week["before"] == sales(h, "2026-11-03", "2026-11-09")["span"]
    assert (a_week["span"]["checks"], a_week["before"]["checks"]) == (6, 2)
    # no day is in both, so no sale is counted on both sides
    assert not {d["day"] for d in a_week["span"]["days"]} & {d["day"] for d in a_week["before"]["days"]}


def test_the_average_check_and_the_average_guest():
    h = evening()
    span = sales(h)["span"]
    assert (span["checks"], span["guests"], span["sales"]["net"]) == (4, 8, "56.60")
    assert span["per_check"] == "14.15"  # 56.60 over four checks
    # o2 is to go and says no guests: it is left out of the average guest, not counted as a party of nobody
    seated = sum(money(h.check(o)["subtotal"]) - money(h.check(o)["discount_total"]) for o in ("o1", "o3", "o4"))
    assert seated == Decimal("39.65") and span["per_guest"] == "4.96"
    assert {k["kind"]: k["guests"] for k in span["kinds"]} == {"dine_in": 8, "takeout": 0}
    nothing = sales(h, "2026-11-12", "2026-11-12")["span"]
    assert (nothing["per_check"], nothing["per_guest"], nothing["turn"]) == (None, None, {"tables": 0, "minutes": None})


def test_how_long_a_table_stood_is_the_middle_one_of_the_closed_tables():
    h = Hub(now=at(11))
    for order_id, opened, closed in (("a", at(11), at(11, 30)), ("b", at(12), at(13)), ("c", at(12), at(17))):
        h.table(order_id, opened)
        h.ring(order_id, "L1", EGGROLL, opened + 60_000)
        h.op(order_id, "close", closed)
    h.table("still-open", at(17, 30))
    h.ring("still-open", "L1", EGGROLL, at(17, 31))
    h.to_go("to-go", at(17, 40))
    h.ring("to-go", "L1", EGGROLL, at(17, 41))
    h.op("to-go", "close", at(17, 45))
    turn = sales(h)["span"]["turn"]
    assert turn == {"tables": 3, "minutes": 60}  # 30, 60 and 300 minutes: the one left open all afternoon moves nothing

    h.op("a", "close", at(18))  # closing a closed check again does not move its time
    assert sales(h)["span"]["turn"] == {"tables": 3, "minutes": 60}
    h.op("b", "reopen", at(18, 10))  # open again: not a table that has turned
    assert sales(h)["span"]["turn"] == {"tables": 2, "minutes": 165}
    h.op("b", "close", at(18, 30))  # and closed again: it stood until then
    assert sales(h)["span"]["turn"] == {"tables": 3, "minutes": 300}
    h.op("c", "void_order", at(18, 40))  # a check voided whole is no table served
    assert sales(h)["span"]["turn"] == {"tables": 2, "minutes": 210}


def test_the_hours_run_in_the_order_of_a_night_whatever_the_day():
    h = Hub(now=at(11, day=14))
    h.table("sat", at(23, day=14))
    h.ring("sat", "L1", BEER, at(23, 5, day=14))
    h.ring("sat", "L2", BEER, at(1, 10, day=15))  # one in the morning: still Saturday's night
    h.table("sun", at(11, day=15))
    h.ring("sun", "L1", EGGROLL, at(11, 5, day=15))
    h.ring("sun", "L2", WINGS, at(23, 30, day=15))
    span = sales(h, "2026-11-14", "2026-11-15")["span"]
    assert [(row["hour"], row["count"], row["amount"]) for row in span["hours"]] == [
        (11, 1, "3.50"),
        (23, 2, "15.45"),
        (1, 1, "6.50"),
    ]
    assert [(d["day"], d["gross"]) for d in span["days"]] == [("2026-11-14", "13.00"), ("2026-11-15", "12.45")]


def test_an_order_rung_for_a_later_day_is_that_days_sale_and_its_money_the_day_it_was_taken():
    h = prepaid()  # rung, paid and closed on Saturday the 14th for Monday the 16th
    total = h.check("c1")["total"]
    rung = sales(h, "2026-11-14", "2026-11-14")["span"]
    assert (rung["checks"], rung["sales"]["gross"], rung["money"]["taken_total"]) == (0, "0.00", total)
    for_it = sales(h, "2026-11-16", "2026-11-16")["span"]
    assert (for_it["checks"], for_it["sales"]["gross"], for_it["money"]["taken_total"]) == (1, "50.85", "0.00")
    both = sales(h, "2026-11-14", "2026-11-16")["span"]
    assert (both["checks"], both["sales"]["total"], both["money"]["taken_total"]) == (1, total, total)
    assert [(d["day"], d["checks"]) for d in both["days"]] == [("2026-11-14", 0), ("2026-11-15", 0), ("2026-11-16", 1)]
    # the Saturday a week later holds it beside itself: the money is in `before`, the sale in neither
    later = sales(h, "2026-11-21", "2026-11-21")
    assert (later["before"]["money"]["taken_total"], later["before"]["checks"], later["span"]["checks"]) == (
        total,
        0,
        0,
    )


def test_a_check_voided_whole_is_no_sale_and_money_taken_on_it_is_still_money_taken():
    h = Hub(now=at(18))
    h.table("o1", at(18))
    h.ring("o1", "L1", WINGS, at(18, 1))
    h.pay("o1", at(18, 5), "5.00", "cash")
    h.table("o2", at(18, 10))
    h.ring("o2", "L1", EGGROLL, at(18, 11))
    assert sales(h)["span"]["checks"] == 2
    h.op("o1", "void_order", at(18, 20))
    span = sales(h)["span"]
    assert (span["checks"], span["sales"]["gross"], span["money"]["taken_total"]) == (1, "3.50", "5.00")


def test_the_hours_worked_and_the_sales_for_each_of_them_where_the_time_clock_is_used():
    h = Hub(now=at(16), clock_on=True)
    for pin in ("1111", "2222"):
        assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": "in"}).status_code == 200
    h.table("o1", at(17))
    h.ring("o1", "L1", PUPU, at(17, 1), qty=4)  # 67.80
    h.now = at(20)
    for pin in ("1111", "2222"):
        assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": "out"}).status_code == 200
    answer = sales(h)
    assert answer["span"]["clock"] == {"worked_ms": 8 * 3_600_000, "people": 2, "unended": 0, "net_per_hour": "8.48"}
    assert answer["before"]["clock"] == {"worked_ms": 0, "people": 0, "unended": 0, "net_per_hour": None}
    assert sales(evening())["span"]["clock"] is None  # a location that does not use the time clock


def afresh(h: Hub, first: date, last: date) -> dict:
    """The sales of these days reckoned straight from every order in the log, nothing remembered."""
    state = h.c.app.state
    return sales_report(
        [h.store.view(o) for o in h.store.order_ids()],
        first,
        last,
        taxes=state.taxes,
        rules=state.pricing,
        defs=state.menu.defs,
        now_ms=h.now,
    )


def test_the_sales_can_be_reckoned_straight_from_the_orders():
    h = week_before(evening())
    week = (date(2026, 11, 10), date(2026, 11, 16))
    answer = sales(h, "2026-11-10", "2026-11-16")
    assert afresh(h, *week) == {k: v for k, v in answer["span"].items() if k != "clock"}
    assert afresh(h, *comparison(*week)) == {k: v for k, v in answer["before"].items() if k != "clock"}
    # and both at once from the orders' sales, as the hub does it
    state = h.c.app.state
    sold = [sale_of(h.store.view(o), state.taxes, state.pricing) for o in h.store.order_ids()]
    both = sales_reports(sold, [week, comparison(*week)], defs=state.menu.defs, now_ms=h.now)
    assert both == [afresh(h, *week), afresh(h, *comparison(*week))]


def test_a_check_is_replayed_again_only_when_it_changed_and_reads_the_same_either_way():
    h = week_before(evening())
    asked: list[list[str]] = []
    views = h.store.views

    def counted(entries):
        asked.append([e.order_id for e in entries])
        return views(entries)

    h.store.views = counted
    span = (date(2026, 11, 9), date(2026, 11, 17))

    def read() -> dict:
        asked.clear()
        answer = sales(h, span[0].isoformat(), span[1].isoformat())["span"]
        replayed = list(asked)
        assert {k: v for k, v in answer.items() if k != "clock"} == afresh(h, *span)
        asked[:] = replayed  # what the reading itself replayed, not this check of it
        return answer

    first = read()
    assert sorted(o for some in asked for o in some) == sorted(h.store.order_ids())  # every order, the first time
    assert read() == first and asked == []  # and none the second
    h.pay("o3", at(21, 5), "1.00", "cash")
    assert money(read()["money"]["taken_total"]) == money(first["money"]["taken_total"]) + 1
    assert asked == [["o3"]]  # only the check that changed
    # whatever happens to a check, the next reading has it: a void, a discount, a reopening, a whole check voided
    h.op("o4", "void_line", at(21, 10), line_id="L2", reason="kitchen-error", by="Amy")
    assert (first["sales"]["gross"], read()["sales"]["gross"], asked) == ("142.85", "126.90", [["o4"]])
    h.op(
        "o3", "discount", at(21, 12), discount_id="D9", reason="loyalty", kind="amount", value="1.00", applied_by="Amy"
    )
    assert (read()["sales"]["discounts"], asked) == ("3.00", [["o3"]])
    h.op("o1", "reopen", at(21, 15))
    assert (first["turn"]["tables"], read()["turn"]["tables"], asked) == (4, 3, [["o1"]])
    h.op("o2", "void_order", at(21, 20))
    assert (read()["checks"], asked) == (first["checks"] - 1, [["o2"]])
    h.table("o9", at(21, 30))
    h.ring("o9", "L1", WINGS, at(21, 31))
    assert (read()["checks"], asked) == (first["checks"], [["o9"]])
    # a dish is named by the menu when the report is read, not when its check was first added up
    assert [c["name"] for c in read()["categories"]] == [c["name"] for c in afresh(h, *span)["categories"]]


def test_what_is_remembered_is_bounded_read_in_pieces_and_dropped_under_other_rules():
    h = week_before(evening())
    state = h.c.app.state
    entries = h.store.index()
    about = {"taxes": state.taxes, "rules": state.pricing}
    straight = [sale_of(s, **about) for s in h.store.views(entries)]
    asked: list[int] = []

    def views(some):
        asked.append(len(some))
        return h.store.views(some)

    memo = SaleMemo(keep=4, at_once=3)
    assert list(memo.sales(entries, views, **about)) == straight
    assert asked == [3, 3, 3, 1] and len(memo) == 4  # ten orders three at a time, the last four kept
    asked.clear()
    again = list(memo.sales(entries, views, **about))
    assert sorted(again, key=repr) == sorted(straight, key=repr) and sum(asked) == 6
    roomy = SaleMemo()
    assert list(roomy.sales(entries, views, **about)) == straight and len(roomy) == 10
    asked.clear()
    assert list(roomy.sales(entries, views, **about)) == straight and asked == []
    # other taxes or other rules: nothing worked out under the old ones is handed out
    assert list(roomy.sales(entries, views, taxes=massachusetts(), rules=state.pricing)) == straight
    assert sum(asked) == 10


# The same days as a table for a spreadsheet: a line a day, for the accountant. ------------------------------

SHEET = [
    "Day",
    "Checks",
    "Guests",
    "Dinner",
    "Lunch",
    "Dishes sold",
    "Comps and discounts",
    "Net sales",
    "Charges",
    "Gratuity",
    "Sales tax",
    "Total",
    "Tax-exempt checks",
    "Tax-exempt sales",
    "Tax not charged",
    "Voids after sending",
    "Voids after sending, amount",
    "Checks voided whole",
    "Checks voided whole, amount",
    "Cash",
    "Card",
    "Paid online",
    "Paid elsewhere",
    "Money taken",
]
PAID = {"cash": "Cash", "card": "Card", "online": "Paid online", "elsewhere": "Paid elsewhere"}


def sheet(h: Hub, first: str | None = None, last: str | None = None) -> dict:
    params = {name: day for name, day in (("from", first), ("to", last)) if day}
    answer = h.c.get("/reports/sales/sheet", params=params, headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def lines(answer: dict) -> dict[str, dict[str, str]]:
    """Each line of a sheet under its day ("Total" for the last), each cell under its column's name."""
    assert all(len(row) == len(answer["columns"]) for row in [*answer["rows"], answer["total"]])
    return {row[0]: dict(zip(answer["columns"], row, strict=True)) for row in [*answer["rows"], answer["total"]]}


def test_the_sheet_is_for_managers_and_its_days_are_asked_like_the_sales():
    h = Hub()
    assert h.c.get("/reports/sales/sheet").status_code == 401
    assert h.c.get("/reports/sales/sheet", headers={"authorization": "Bearer nobody"}).status_code == 401
    for params in ({"from": "yesterday"}, {"to": "2026-02-30"}, {"from": "2026-11-16", "to": "2026-11-15"}):
        assert h.c.get("/reports/sales/sheet", params=params, headers=h.manager()).status_code == 422, params
    long = h.c.get("/reports/sales/sheet", params={"from": "2026-08-16", "to": "2026-11-16"}, headers=h.manager())
    assert long.status_code == 422 and long.json()["detail"]["error"] == "too_long"
    quarter = sheet(h, "2026-08-17", "2026-11-16")  # 92 days exactly: a line for each, sold on or not
    assert len(quarter["rows"]) == 92 and quarter["max_days"] == 92
    assert set(quarter["total"][1:]) == {"0", "0.00"}
    today = sheet(h)  # nothing asked: the day that is running
    assert (today["first"], today["last"], today["running"]) == ("2026-11-16", "2026-11-16", True)
    assert [row[0] for row in today["rows"]] == ["2026-11-16"] and today["now_ms"] == at(21)
    assert sheet(h, "2026-11-15")["running"] is False


def test_the_sheet_is_a_line_for_each_day_and_a_line_of_totals_every_cell_as_text():
    h = week_before(evening())
    before = h.store.cursor
    answer = sheet(h, "2026-11-09", "2026-11-17")
    assert h.store.cursor == before  # reading changes nothing
    assert answer["columns"] == SHEET
    assert [row[0] for row in answer["rows"]] == [f"2026-11-{n:02d}" for n in range(9, 18)]
    assert answer["total"][0] == "Total"
    for row in [*answer["rows"], answer["total"]]:
        assert all(isinstance(cell, str) and "\t" not in cell and "\n" not in cell for cell in row)
    monday = lines(answer)["2026-11-16"]
    assert monday == {
        "Day": "2026-11-16",
        "Checks": "4",
        "Guests": "8",
        "Dinner": "58.60",
        "Lunch": "0.00",
        "Dishes sold": "58.60",
        "Comps and discounts": "2.00",  # what came off is written as it is, with no minus sign
        "Net sales": "56.60",
        "Charges": "0.00",
        "Gratuity": "0.00",
        "Sales tax": "3.96",
        "Total": "60.56",
        "Tax-exempt checks": "0",
        "Tax-exempt sales": "0.00",
        "Tax not charged": "0.00",
        "Voids after sending": "1",
        "Voids after sending, amount": "3.50",
        "Checks voided whole": "1",
        "Checks voided whole, amount": "2.95",
        "Cash": "25.00",
        "Card": "8.84",
        "Paid online": "0.00",  # the column is there on every sheet, so a month's sheets line up
        "Paid elsewhere": "18.14",
        "Money taken": "51.98",
    }
    quiet = lines(answer)["2026-11-12"]  # a day nothing was sold on is a line of zeroes, not a gap
    assert set(quiet.values()) == {"2026-11-12", "0", "0.00"}


def as_the_day_reads(h: Hub, day: str, line: dict[str, str]) -> None:
    """This line of a sheet says what the day's report says of the day."""
    report = h.report(day)
    assert (line["Checks"], line["Guests"]) == (str(report["checks"]), str(report["guests"])), day
    for column, figure in (
        ("Dishes sold", "gross"),
        ("Comps and discounts", "discounts"),
        ("Net sales", "net"),
        ("Charges", "charges"),
        ("Gratuity", "gratuity"),
        ("Sales tax", "tax"),
        ("Total", "total"),
    ):
        assert line[column] == report["sales"][figure], (day, column)
    exempted = report["tax_exempt"]
    assert (line["Tax-exempt checks"], line["Tax-exempt sales"], line["Tax not charged"]) == (
        str(exempted["count"]),
        exempted["sales"],
        exempted["tax"],
    ), day
    for column, figure in (("Voids after sending", "voids"), ("Checks voided whole", "voided_checks")):
        assert (line[column], line[f"{column}, amount"]) == (str(report[figure]["count"]), report[figure]["amount"]), (
            day,
            column,
        )
    taken = {PAID[row["method"]]: row["amount"] for row in report["money"]["taken"]}
    assert {name: line[name] for name in PAID.values()} == {name: taken.get(name, "0.00") for name in PAID.values()}
    assert line["Money taken"] == report["money"]["taken_total"], day
    by_menu = {row["name"]: row["amount"] for row in report["menus"]}
    assert {name: line[name] for name in ("Dinner", "Lunch")} == {
        name: by_menu.get(name, "0.00") for name in ("Dinner", "Lunch")
    }, day


def test_each_line_of_the_sheet_reads_what_the_days_report_reads_for_that_day():
    h = week_before(evening())
    answer = lines(sheet(h, "2026-11-09", "2026-11-17"))
    for day in (f"2026-11-{n:02d}" for n in range(9, 18)):
        as_the_day_reads(h, day, answer[day])
    for day in ("2026-11-09", "2026-11-15", "2026-11-16", "2026-11-17"):  # and a day asked alone is that line
        alone = sheet(h, day, day)
        assert lines(alone)[day] == answer[day]
        assert alone["total"][1:] == alone["rows"][0][1:]


def test_the_totals_are_the_lines_added_up_and_read_what_the_sales_read():
    h = week_before(evening())
    answer = sheet(h, "2026-11-09", "2026-11-17")
    for i, column in enumerate(answer["columns"][1:], start=1):
        assert money(answer["total"][i]) == sum(money(row[i]) for row in answer["rows"]), column
    total, span = lines(answer)["Total"], sales(h, "2026-11-09", "2026-11-17")["span"]
    assert (total["Checks"], total["Guests"]) == (str(span["checks"]), str(span["guests"])) == ("9", "15")
    for column, figure in (
        ("Dishes sold", "gross"),
        ("Comps and discounts", "discounts"),
        ("Net sales", "net"),
        ("Charges", "charges"),
        ("Gratuity", "gratuity"),
        ("Sales tax", "tax"),
        ("Total", "total"),
    ):
        assert total[column] == span["sales"][figure], column
    assert total["Money taken"] == span["money"]["taken_total"] == "78.09"
    taken = {PAID[row["method"]]: row["amount"] for row in span["money"]["taken"]}
    # a way nobody paid in these days is no row of the sales and a column of zeroes on the sheet
    assert {name: total[name] for name in PAID.values()} == {name: taken.get(name, "0.00") for name in PAID.values()}
    assert money(total["Dinner"]) + money(total["Lunch"]) == money(total["Dishes sold"])  # the menus split it
    for line in lines(answer).values():  # and every line adds up the way the sales do
        assert money(line["Net sales"]) == money(line["Dishes sold"]) - money(line["Comps and discounts"])
        assert money(line["Total"]) == sum(money(line[c]) for c in ("Net sales", "Charges", "Gratuity", "Sales tax"))
        assert money(line["Money taken"]) == sum(money(line[name]) for name in PAID.values())


def test_what_the_website_took_is_a_row_of_the_sales_and_a_column_of_the_sheet():
    h = week_before(evening())
    before = sales(h, "2026-11-09", "2026-11-17")["span"]
    monday, sunday = website(h, "g1", at(19, 40)), website(h, "g0", at(18, day=15), PUPU)
    h.now = at(21)
    span = sales(h, "2026-11-09", "2026-11-17")["span"]
    assert [m["method"] for m in span["money"]["taken"]] == ["cash", "card", "online", "elsewhere"]
    taken = {m["method"]: (m["count"], m["amount"]) for m in span["money"]["taken"]}
    assert taken.pop("online") == (2, str(money(monday) + money(sunday)))
    assert taken == {m["method"]: (m["count"], m["amount"]) for m in before["money"]["taken"]}  # the others as before
    assert money(span["money"]["taken_total"]) == money(before["money"]["taken_total"]) + money(monday) + money(sunday)
    # a day asked alone says what the day's report says, row for row
    for day in ("2026-11-15", "2026-11-16"):
        assert sales(h, day, day)["span"]["money"]["taken"] == h.report(day)["money"]["taken"], day
    # the sheet: each day's own, in its column, and the money taken still every column added up
    answer = lines(sheet(h, "2026-11-09", "2026-11-17"))
    assert (answer["2026-11-15"]["Paid online"], answer["2026-11-16"]["Paid online"]) == (sunday, monday)
    assert answer["2026-11-16"]["Paid elsewhere"] == "18.14"  # Lee's order, paid outside the POS another way
    assert answer["Total"]["Paid online"] == str(money(monday) + money(sunday))
    for day, line in answer.items():
        assert money(line["Money taken"]) == sum(money(line[name]) for name in PAID.values()), day
        if day != "Total":
            as_the_day_reads(h, day, line)
    # reckoned afresh from the orders, with nothing remembered, it is the same
    assert afresh(h, date(2026, 11, 9), date(2026, 11, 17))["money"] == span["money"]


def test_charges_a_gratuity_and_a_check_charged_no_tax_are_on_the_line_of_their_day():
    from .test_exempt import exempt  # it reads the sales with this module's own helpers

    h = Hub(now=at(17))
    h.table("o1", at(17), table="9", guests=6)  # a party of six: the gratuity adds itself
    h.ring("o1", "L1", PUPU, at(17, 1), qty=3)
    h.op("o2", "create", at(17, 30), order_type="delivery", customer_name="Lee", channel="phone")  # with its fee
    h.ring("o2", "L1", WINGS, at(17, 31))
    h.table("o3", at(18), table="4")
    h.ring("o3", "L1", EGGROLL, at(18, 1), qty=2)
    assert exempt(h, "o3", at(18, 5))["refused"] == []
    h.now = at(21)
    line = lines(sheet(h))["2026-11-16"]
    assert (line["Charges"], line["Gratuity"]) == ("4.00", "9.15")
    assert (line["Tax-exempt checks"], line["Tax-exempt sales"], line["Tax not charged"]) == ("1", "7.00", "0.49")
    assert money(line["Total"]) == sum(money(line[c]) for c in ("Net sales", "Charges", "Gratuity", "Sales tax"))
    as_the_day_reads(h, "2026-11-16", line)


def test_what_came_off_and_the_money_are_on_the_line_of_the_day_they_happened():
    h = evening()
    h.op("y2", "reopen", at(21, 2))
    h.op("y2", "void_line", at(21, 3), line_id="L1", reason="kitchen-error", by="Amy")  # yesterday's tab, tonight
    answer = lines(sheet(h, "2026-11-15", "2026-11-16"))
    sunday, monday = answer["2026-11-15"], answer["2026-11-16"]
    assert (sunday["Voids after sending"], sunday["Voids after sending, amount"]) == ("0", "0.00")
    assert (monday["Voids after sending"], monday["Voids after sending, amount"]) == ("2", "10.00")
    # the tab was paid by card on Monday (6.96 of the 8.84): Monday's money, whatever is left of Sunday's sale
    assert (sunday["Dishes sold"], sunday["Card"], monday["Card"]) == ("2.50", "0.00", "8.84")
    for day in ("2026-11-15", "2026-11-16"):
        as_the_day_reads(h, day, answer[day])
    # an order rung and paid on Saturday for Monday: Saturday's money, Monday's sale
    h = prepaid()
    total = h.check("c1")["total"]
    answer = lines(sheet(h, "2026-11-14", "2026-11-16"))
    assert (answer["2026-11-14"]["Checks"], answer["2026-11-14"]["Money taken"]) == ("0", total)
    assert (answer["2026-11-16"]["Checks"], answer["2026-11-16"]["Total"]) == ("1", total)
    assert (answer["2026-11-16"]["Money taken"], answer["Total"]["Money taken"]) == ("0.00", total)
    # a check voided whole after money was taken on it: no sale, the check said as voided, the money still there
    h = Hub(now=at(18))
    h.to_go("o1", at(18))
    h.ring("o1", "L1", WINGS, at(18, 1))
    h.pay("o1", at(18, 2), "5.00", "cash")
    h.op("o1", "void_order", at(18, 5))
    line = lines(sheet(h))["2026-11-16"]
    assert (line["Checks"], line["Dishes sold"], line["Total"]) == ("0", "0.00", "0.00")
    assert (line["Checks voided whole"], line["Checks voided whole, amount"], line["Cash"]) == ("1", "8.95", "5.00")
    as_the_day_reads(h, "2026-11-16", line)


def test_a_dish_that_left_the_menu_has_its_column_so_the_menus_still_add_up():
    h = Hub(now=at(18))
    h.table("o1", at(18))
    h.ring("o1", "L1", WINGS, at(18, 1))
    gone = {"unit_price": "11.00", "tax_class": "prepared_food", "name": "Last year's special", "item": "GONE"}
    h.op("o1", "add_line", at(18, 2), line_id="L2", item="Special", qty=1, priced=gone, by="Amy", by_id="s1")
    answer = sheet(h)
    assert answer["columns"][3:7] == ["Dinner", "Lunch", "Off the menu now", "Dishes sold"]
    line = lines(answer)["2026-11-16"]
    assert (line["Dinner"], line["Lunch"], line["Off the menu now"], line["Dishes sold"]) == (
        "8.95",
        "0.00",
        "11.00",
        "19.95",
    )


def test_the_sheet_can_be_reckoned_straight_from_the_orders():
    h = week_before(evening())
    state = h.c.app.state
    sold = [sale_of(h.store.view(o), state.taxes, state.pricing) for o in h.store.order_ids()]
    straight = day_sheet(sold, date(2026, 11, 9), date(2026, 11, 17), defs=state.menu.defs, now_ms=h.now)
    first = sheet(h, "2026-11-09", "2026-11-17")
    assert {k: v for k, v in first.items() if k not in ("max_days", "now_ms")} == straight
    assert sheet(h, "2026-11-09", "2026-11-17") == first  # and the same from what the hub remembers
    h.op("o4", "void_line", at(21, 10), line_id="L2", reason="kitchen-error", by="Amy")  # a check that changed
    again = lines(sheet(h, "2026-11-09", "2026-11-17"))["2026-11-16"]
    assert (again["Voids after sending"], again["Voids after sending, amount"], again["Dishes sold"]) == (
        "2",
        "19.45",
        "42.65",
    )


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_sales_are_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(19, day=15), postgres=DSN)
    try:
        week_before(evening(h))
        memory = week_before(evening())
        for first, last in ((None, None), ("2026-11-09", "2026-11-17"), ("2026-11-15", "2026-11-15")):
            assert sales(h, first, last) == sales(memory, first, last)
            assert sheet(h, first, last) == sheet(memory, first, last)
        assert sales(h)["span"]["turn"] == {"tables": 2, "minutes": 61}
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
