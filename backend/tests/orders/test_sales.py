"""Sales over a span of days, beside the days before.

The same sales as the day's report, added up over any days from one to a quarter of a year, with the same
figures for as many days whole weeks earlier. These tests ring a few evenings through the hub the way the
screens do and read what a manager gets."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from pos.orders.sales import MAX_DAYS, SaleMemo, comparison, sale_of, sales_report, sales_reports
from pos.tax import massachusetts

from .test_day import BEER, DSN, EGGROLL, PUPU, WINGS, Hub, added, at, evening, money, prepaid


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
        assert sales(h)["span"]["turn"] == {"tables": 2, "minutes": 61}
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
