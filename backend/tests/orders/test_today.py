"""Today so far, beside the same weekday a week ago at the same time of day.

One reading for a phone: the day's report as it stands, the whole of the same weekday a week earlier, and
how far each had come by this time of day, so that an owner can tell whether tonight is ahead or behind.
These tests ring two Mondays through the hub the way the screens do and read it as the evening goes on."""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal

import pytest

from pos import localtime
from pos.orders.today import RungMemo, rung_by, rung_of, same_time
from pos.tax import massachusetts

from .test_day import BEER, DRAGON, DSN, EGGROLL, PUPU, SODA, WINGS, Hub, at, evening
from .test_sales import sales, week_before


def today(h: Hub, headers: dict[str, str] | None = None) -> dict:
    answer = h.c.get("/reports/today", headers=headers or h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def answer_per_check(day: dict) -> str:
    """The day's net sales over its checks, to the cent."""
    return str((Decimal(day["sales"]["net"]) / day["checks"]).quantize(Decimal("0.01")))


def two_mondays(h: Hub | None = None) -> Hub:
    """Monday the 9th, the whole of it: a table at six (two wings, a beer: 24.40) and a platter to go at
    seven (16.95). Then Monday the 16th up to half past five: a table with wings (8.95)."""
    h = week_before(h or Hub(now=at(17, day=9)))
    h.table("o1", at(17))
    h.ring("o1", "L1", WINGS, at(17, 5))
    h.op("o1", "fire", at(17, 6))
    h.now = at(17, 30)
    return h


def test_it_is_for_whoever_may_see_the_reports():
    h = Hub()
    assert h.c.get("/reports/today").status_code == 401
    assert h.c.get("/reports/today", headers={"authorization": "Bearer nobody"}).status_code == 401
    assert today(h)["day"]["today"] is True
    # A host is refused a session for the reports, until the location hands the hosts the reports.
    asked = {"device": "t1", "pin": "3333", "power": "reports"}
    assert h.c.post("/admin/session", json=asked).status_code == 403
    assert h.c.put("/settings/powers", json={"roles": {"reports": ["host"]}}, headers=h.manager()).status_code == 200
    host = {"authorization": f"Bearer {h.c.post('/admin/session', json=asked).json()['token']}"}
    assert today(h, host)["day"]["today"] is True
    # Taken back, the session that is already open reads nothing more.
    assert h.c.put("/settings/powers", json={"roles": {"reports": []}}, headers=h.manager()).status_code == 200
    refused = h.c.get("/reports/today", headers=host)
    assert refused.status_code == 403
    assert refused.json()["detail"] == {"error": "not_allowed", "role": "host", "power": "reports"}


def test_the_day_is_the_days_report_and_before_is_the_sales_of_the_same_weekday_a_week_ago():
    h = week_before(evening())
    cursor = h.store.cursor
    answer = today(h)
    assert answer["now_ms"] == at(21)
    assert answer["day"] == h.report()  # no clock at this location, so nothing is added to it
    assert answer["before"] == sales(h, "2026-11-09")["span"]
    assert (answer["before"]["first"], answer["before"]["running"]) == ("2026-11-09", False)
    assert h.store.cursor == cursor  # reading changes nothing
    assert today(h) == answer
    # The sums a phone shows without adding anything up itself: the average check, and what is open now.
    assert answer["per_check"] == answer_per_check(answer["day"]) == "14.15"  # 56.60 net over four checks
    still_open = [*answer["day"]["open"], *answer["day"]["earlier"]]
    assert [(row["order_id"], row["total"]) for row in still_open] == [("o3", "3.47"), ("w2", "18.14"), ("y1", "2.68")]
    assert answer["open"] == {"count": 3, "total": "24.29", "due": "24.29"}
    assert today(Hub(now=at(11)))["per_check"] is None
    # Each hour of the night on both days, in the order a night runs; each side adds up to its dishes sold.
    assert answer["hours"] == [
        {"hour": 17, "now": "15.95", "before": "0.00"},
        {"hour": 18, "now": "6.50", "before": "24.40"},
        {"hour": 19, "now": "16.95", "before": "16.95"},
        {"hour": 20, "now": "19.20", "before": "0.00"},
    ]
    assert sum(Decimal(row["now"]) for row in answer["hours"]) == Decimal(answer["day"]["sales"]["gross"])
    assert sum(Decimal(row["before"]) for row in answer["hours"]) == Decimal(answer["before"]["sales"]["gross"])


def test_a_day_with_nothing_before_it_reads_zero_on_both_sides():
    h = Hub(now=at(11))
    answer = today(h)
    assert (answer["day"]["checks"], answer["before"]["checks"]) == (0, 0)
    assert answer["pace"] == {"now": "0.00", "before": "0.00", "before_ms": at(11, day=9)}


def test_the_pace_is_what_had_been_rung_in_by_this_time_of_day_on_both_days():
    h = two_mondays()
    # Half past five: the wings today; a week ago the first dish went on at a minute past six.
    assert today(h)["pace"] == {"now": "8.95", "before": "0.00", "before_ms": at(17, 30, day=9)}
    # A minute past six, to the second: the dish rung at that very moment a week ago counts.
    h.now = at(18, 1)
    assert today(h)["pace"]["before"] == "17.90"  # the two wings
    h.now = at(18, 30)
    h.ring("o1", "L2", BEER, at(18, 30))
    assert today(h)["pace"] == {"now": "15.45", "before": "24.40", "before_ms": at(18, 30, day=9)}
    # Nine o'clock: all of last Monday is behind us, and the whole of it is also what `before` says.
    h.to_go("o2", at(20, 55))
    h.ring("o2", "L1", PUPU, at(20, 56), qty=2)
    h.now = at(21)
    answer = today(h)
    assert answer["pace"] == {"now": "49.35", "before": "41.35", "before_ms": at(21, day=9)}
    assert answer["pace"]["now"] == answer["day"]["sales"]["gross"]
    assert answer["pace"]["before"] == answer["before"]["sales"]["gross"]


def test_the_pace_is_the_dishes_before_comps_and_only_of_checks_that_are_sales():
    h = two_mondays()
    h.now = at(18, 30)
    # A discount belongs to the whole check, so it moves the net sales and not the dishes rung in.
    h.op(
        "o1", "discount", at(18, 31), discount_id="D1", reason="loyalty", kind="amount", value="2.00", applied_by="Amy"
    )
    answer = today(h)
    assert (answer["pace"]["now"], answer["day"]["sales"]["net"]) == ("8.95", "6.95")
    # A dish voided after it was sent is off the check, and off the pace.
    h.ring("o1", "L2", EGGROLL, at(18, 32))
    h.op("o1", "fire", at(18, 33))
    assert today(h)["pace"]["now"] == "12.45"
    h.op("o1", "void_line", at(18, 40), line_id="L2", reason="kitchen-error", by="Amy")
    assert today(h)["pace"]["now"] == "8.95"
    # A check voided whole is no sale.
    h.to_go("o5", at(18, 41), name="Kim")
    h.ring("o5", "L1", SODA, at(18, 42))
    assert today(h)["pace"]["now"] == "11.90"
    h.op("o5", "void_order", at(18, 45))
    assert today(h)["pace"]["now"] == "8.95"
    # Last Monday's check voided whole tonight is no longer in what last Monday had come to.
    h.op("w2", "void_order", at(18, 50))
    h.now = at(21)
    answer = today(h)
    assert (answer["pace"]["before"], answer["before"]["sales"]["gross"]) == ("24.40", "24.40")


def test_an_order_rung_days_ago_for_today_counts_from_the_morning():
    h = two_mondays()
    # Rung on Saturday for tonight at seven: it is tonight's sale, and was rung in long before this hour.
    h.now = at(15, day=14)
    h.to_go("c1", at(15, day=14), name="Park", promised_at=at(19))
    h.ring("c1", "L1", PUPU, at(15, 1, day=14), qty=3)
    h.now = at(17, 30)
    answer = today(h)
    assert answer["pace"]["now"] == "59.80"  # the wings and three platters
    assert answer["day"]["sales"]["gross"] == "59.80"
    # The same a week ago: an order rung on the 7th for the 9th is in what the 9th had come to by any hour.
    h2 = Hub(now=at(12, day=7))
    h2.to_go("c0", at(12, day=7), name="Park", promised_at=at(19, day=9))
    h2.ring("c0", "L1", DRAGON, at(12, 1, day=7))
    h2.now = at(11)
    assert today(h2)["pace"] == {"now": "0.00", "before": "15.95", "before_ms": at(11, day=9)}


def test_one_in_the_morning_is_still_the_evening_before_on_both_days():
    late = Hub(now=at(23, day=9))
    late.table("w1", at(23, day=9))
    late.ring("w1", "L1", BEER, at(23, 30, day=9))
    late.ring("w1", "L2", BEER, at(0, 30, day=10))  # half past midnight: still Monday the 9th's service
    late.table("o1", at(23, 45))
    late.ring("o1", "L1", WINGS, at(23, 50))
    late.now = at(0, 15, day=17)
    answer = today(late)
    assert answer["day"]["day"] == "2026-11-16" and answer["before"]["first"] == "2026-11-09"
    assert answer["pace"] == {"now": "8.95", "before": "6.50", "before_ms": at(0, 15, day=10)}
    late.now = at(0, 45, day=17)
    answer = today(late)
    assert answer["pace"]["before"] == "13.00"
    # Eleven at night comes before half past midnight: the night runs from four to four.
    assert answer["hours"] == [
        {"hour": 23, "now": "8.95", "before": "6.50"},
        {"hour": 0, "now": "0.00", "before": "6.50"},
    ]


def test_the_same_time_of_day_holds_across_a_week_the_clocks_changed_in():
    zone = localtime.zone()
    # The clocks went back on Sunday 1 November 2026: Monday the 2nd is held beside Monday 26 October.
    now = int(datetime(2026, 11, 2, 18, 30, tzinfo=zone).timestamp() * 1000)
    then = same_time(now, date(2026, 11, 2), date(2026, 10, 26))
    assert datetime.fromtimestamp(then / 1000, zone) == datetime(2026, 10, 26, 18, 30, tzinfo=zone)
    assert now - then == 7 * 24 * 3_600_000 + 3_600_000  # a week and the hour that was lived twice
    # Any ordinary week: exactly seven days.
    assert at(18, 30) - same_time(at(18, 30), date(2026, 11, 16), date(2026, 11, 9)) == 7 * 24 * 3_600_000


def test_the_time_clock_adds_the_net_sales_for_each_hour_worked_on_both_days():
    h = Hub(now=at(16, day=9), clock_on=True)
    assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": "1111", "action": "in"}).status_code == 200
    week_before(h)
    h.now = at(20, day=9)
    assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": "1111", "action": "out"}).status_code == 200
    h.now = at(16)
    for pin in ("1111", "2222"):
        assert h.c.post("/timeclock/punch", json={"device": "t1", "pin": pin, "action": "in"}).status_code == 200
    h.table("o1", at(17))
    h.ring("o1", "L1", WINGS, at(17, 5), qty=4)
    h.now = at(18)
    answer = today(h)
    clock = answer["day"]["clock"]
    assert (clock["people"], clock["worked_ms"], clock["net_per_hour"]) == (2, 4 * 3_600_000, "8.95")
    assert sorted(p["name"] for p in clock["on_now"]) == ["Amy", "Ben"]
    before = answer["before"]["clock"]
    assert (before["people"], before["worked_ms"], before["net_per_hour"]) == (1, 4 * 3_600_000, "10.34")
    # Before anybody has worked an hour there is no figure to give, and none is made up.
    quiet = Hub(now=at(11), clock_on=True)
    assert today(quiet)["day"]["clock"]["net_per_hour"] is None


def test_what_a_check_comes_to_is_remembered_until_the_check_changes():
    h = two_mondays()
    memo = RungMemo()
    taxes = massachusetts()

    def read() -> Decimal:
        entries = h.store.index()
        return rung_by(memo.each(entries, h.store.views, taxes=taxes, rules=None), date(2026, 11, 16), at(23))

    assert read() == Decimal("8.95")
    assert len(memo) == 3  # the two checks of last Monday and tonight's
    kept = rung_of(h.store.view("o1"), taxes, None)
    assert kept is not None and kept.lines == ((at(17, 5), Decimal("8.95")),)
    h.ring("o1", "L2", BEER, at(17, 40))
    assert read() == Decimal("15.45")  # the check that changed is read again, the others are not
    h.op("o1", "void_order", at(17, 45))
    assert read() == Decimal("0.00") and rung_of(h.store.view("o1"), taxes, None) is None


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_it_reads_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(17, day=9), postgres=DSN)
    try:
        two_mondays(h)
        memory = two_mondays()
        for clock in (at(17, 30), at(18, 1), at(21)):
            h.now = memory.now = clock
            assert today(h) == today(memory)
        assert today(h)["pace"] == {"now": "8.95", "before": "41.35", "before_ms": at(21, day=9)}
    finally:
        h.store.close()
