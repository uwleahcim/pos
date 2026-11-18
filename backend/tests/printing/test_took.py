"""How long the kitchen takes: the marks of the kitchen screens added up over a span of days. A ticket took
from when its dishes were in the kitchen until its station marked the last of them; a send went out when its
last dish did. Only what was marked is timed, and reading the report changes nothing."""

from __future__ import annotations

from datetime import date

import pytest

from pos.orders.sales import MAX_DAYS, comparison
from pos.printing.took import Cooked, Kitchen, kitchen_of, kitchen_times
from pos.settings import clean_ticket_skips

from ..orders.test_day import BEER, DRAGON, DSN, EGGROLL, PUPU, WINGS, Hub, at
from ..orders.test_dishes import GTC

MIN = 60_000
PASS = "*pass"


def times(h: Hub, first: str | None = None, last: str | None = None) -> dict:
    params = {name: day for name, day in (("from", first), ("to", last)) if day}
    answer = h.c.get("/reports/kitchen", params=params, headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def table(h: Hub, order_id: str, when: int, *dishes: dict, table_no: str = "12") -> None:
    """A table that orders these dishes (`L1`, `L2`, ...) and has them sent, all at `when`."""
    h.table(order_id, when, table=table_no)
    for n, dish in enumerate(dishes, 1):
        h.ring(order_id, f"L{n}", dish, when)
    h.op(order_id, "fire", when)


def made(h: Hub, order_id: str, station: str, when: int, *lines: str, done: bool = True) -> None:
    """A station's screen says these dishes are made (or takes it back); the pass says they went out."""
    h.op(order_id, "done", when, station=station, line_ids=list(lines), done=done)


def figures(row: dict) -> tuple:
    """How many were timed, the average, the middle one and the longest in minutes, the late and the open."""
    mins = tuple(None if row[key] is None else row[key] / MIN for key in ("avg_ms", "median_ms", "longest_ms"))
    return (row.get("tickets", row.get("count")), *mins, row["late"], row["open"])


def stations(report: dict) -> dict[str, tuple]:
    return {row["name"]: figures(row) for row in report["span"]["stations"]}


def evening() -> Hub:
    """Monday the 16th, read at nine. Table 12 at 18:00: wings and an egg roll (the fryer, done at 18:09),
    General Tso's (the wok, 18:14) and a beer (the bar, which has no screen). Table 7 at 18:30: wings
    (18:36) and General Tso's (18:52)."""
    h = Hub(now=at(17))
    table(h, "o1", at(18), WINGS, EGGROLL, GTC, BEER)
    made(h, "o1", "fryer", at(18, 7), "L1")
    made(h, "o1", "fryer", at(18, 9), "L2")
    made(h, "o1", "wok", at(18, 14), "L3")
    table(h, "o2", at(18, 30), WINGS, GTC, table_no="7")
    made(h, "o2", "fryer", at(18, 36), "L1")
    made(h, "o2", "wok", at(18, 52), "L2")
    h.now = at(21)
    return h


# --- the call ------------------------------------------------------------------------------------------------


def test_the_times_are_for_those_who_read_reports_and_a_span_has_to_make_sense():
    h = Hub()
    assert h.c.get("/reports/kitchen").status_code == 401
    assert h.c.get("/reports/kitchen", headers={"authorization": "Bearer nobody"}).status_code == 401
    for params in ({"from": "yesterday"}, {"to": "2026-02-30"}, {"from": "2026-11-16", "to": "2026-11-15"}):
        assert h.c.get("/reports/kitchen", params=params, headers=h.manager()).status_code == 422, params
    long = h.c.get("/reports/kitchen", params={"from": "2026-08-16", "to": "2026-11-16"}, headers=h.manager())
    assert long.status_code == 422 and long.json()["detail"]["error"] == "too_long"
    report = times(h, "2026-08-17", "2026-11-16")  # 92 days exactly
    assert report["max_days"] == MAX_DAYS and report["span"]["made"]["tickets"] == 0


def test_nothing_asked_is_the_running_day_beside_the_same_day_a_week_before():
    report = times(evening())
    span, before = report["span"], report["before"]
    assert (span["first"], span["last"], span["running"]) == ("2026-11-16", "2026-11-16", True)
    assert (before["first"], before["last"], before["running"]) == ("2026-11-09", "2026-11-09", False)
    assert report["late_min"] == 20 and report["now_ms"] == at(21)


# --- what a ticket took --------------------------------------------------------------------------------------


def test_a_ticket_took_from_when_it_was_sent_until_its_station_marked_its_last_dish():
    report = times(evening())
    # the fryer: 9 and 6 minutes; the wok: 14 and 22
    assert stations(report) == {"Fryer": (2, 7.5, 7.5, 9, 0, 0), "Wok": (2, 18, 18, 22, 1, 0)}
    # and all of them together: 6, 9, 14, 22
    assert figures(report["span"]["made"]) == (4, 12.75, 11.5, 22, 1, 0)


def test_a_ticket_with_a_dish_nobody_marked_is_counted_beside_the_times_and_never_in_them():
    h = evening()
    table(h, "o3", at(19), WINGS, EGGROLL, GTC, table_no="3")
    made(h, "o3", "fryer", at(19, 5), "L1")  # the egg roll and the wok's dish: nobody tapped them
    h.now = at(21)
    report = times(h)
    assert stations(report) == {"Fryer": (2, 7.5, 7.5, 9, 0, 1), "Wok": (2, 18, 18, 22, 1, 1)}
    assert figures(report["span"]["made"]) == (4, 12.75, 11.5, 22, 1, 2)


def test_a_kitchen_that_marks_nothing_has_timed_nothing():
    h = Hub(now=at(17))
    table(h, "o1", at(18), WINGS, GTC, BEER)
    table(h, "o2", at(18, 30), WINGS, table_no="7")
    h.now = at(21)
    span = times(h)["span"]
    assert figures(span["made"]) == (0, None, None, None, 0, 0)
    assert span["stations"] == [] and span["dishes"] == [] and span["slowest"] == [] and span["hours"] == []
    # the stations it was sent tickets at are named, with how many
    assert [(row["name"], row["open"]) for row in span["silent"]] == [("Fryer", 2), ("Bar", 1), ("Wok", 1)]


def test_a_station_that_never_marks_is_named_and_kept_out_of_every_figure():
    span = times(evening())["span"]
    assert span["silent"] == [{"code": "bar", "name": "Bar", "open": 1}]
    assert span["made"]["open"] == 0  # the beer nobody marked is not the kitchen running behind
    assert [row["hour"] for row in span["hours"]] == [18]
    assert figures(span["hours"][0]) == (4, 12.75, 11.5, 22, 1, 0)


def test_each_send_of_an_order_is_a_ticket_of_its_own():
    h = evening()
    h.ring("o1", "L5", WINGS, at(19))
    h.op("o1", "fire", at(19))
    made(h, "o1", "fryer", at(19, 4), "L5")
    h.now = at(21)
    assert stations(times(h))["Fryer"] == (3, 19 / 3, 6, 9, 0, 0)


def test_a_mark_taken_back_is_no_time_and_the_latest_word_stands():
    h = evening()
    made(h, "o2", "wok", at(18, 53), "L2", done=False)  # not made after all
    h.now = at(21)
    assert stations(times(h))["Wok"] == (1, 14, 14, 14, 0, 1)
    made(h, "o2", "wok", at(18, 58), "L2")
    h.now = at(21)
    assert stations(times(h))["Wok"] == (2, 21, 21, 28, 1, 0)


def test_late_is_the_locations_red_minutes_and_none_when_it_has_none():
    h = evening()
    assert figures(times(h)["span"]["made"])[4] == 1  # 20 minutes to start: the wok's 22
    assert h.c.put("/settings/kitchen_screens", json={"warn": 5, "late": 9}, headers=h.manager()).status_code == 200
    report = times(h)
    assert report["late_min"] == 9
    assert figures(report["span"]["made"])[4] == 3  # 9, 14 and 22: nine minutes is late
    assert h.c.put("/settings/kitchen_screens", json={"warn": 0, "late": 0}, headers=h.manager()).status_code == 200
    report = times(h)
    assert report["late_min"] == 0 and figures(report["span"]["made"])[4] == 0


def test_a_dish_voided_and_an_order_voided_whole_are_left_out():
    h = evening()
    h.op("o1", "void_line", at(18, 20), line_id="L3", reason="kitchen-error", by="Amy", by_id="s1")
    h.op("o2", "void_order", at(19))
    h.now = at(21)
    report = times(h)
    assert stations(report) == {"Fryer": (1, 9, 9, 9, 0, 0)}
    assert [row["name"] for row in report["span"]["dishes"]] == ["Egg roll", "Chicken wings"]


# --- to go, the pass, and the screens that skip a station ---------------------------------------------------


def test_a_to_go_order_is_one_more_ticket_where_it_is_packed():
    h = Hub(now=at(17))
    h.to_go("o1", at(18))
    h.ring("o1", "L1", PUPU, at(18))
    h.ring("o1", "L2", GTC, at(18))
    h.op("o1", "fire", at(18))
    made(h, "o1", "fryer", at(18, 8), "L1")
    made(h, "o1", "wok", at(18, 12), "L2")
    made(h, "o1", "takeout", at(18, 15), "L1", "L2")  # the packer has the bag
    h.now = at(21)
    report = times(h)
    assert stations(report) == {
        "Fryer": (1, 8, 8, 8, 0, 0),
        "takeout": (1, 15, 15, 15, 0, 0),  # (this menu gives the station no name)
        "Wok": (1, 12, 12, 12, 0, 0),
    }
    # a dish is timed until it is cooked, not until it is in the bag
    assert {row["name"]: figures(row)[1] for row in report["span"]["dishes"]} == {
        "General Tso's Chicken": 12,
        "Pu Pu Platter": 8,
    }
    slowest = report["span"]["slowest"][0]
    assert (slowest["to_go"], slowest["customer"], slowest["station_name"], slowest["took_ms"]) == (
        True,
        "Lee",
        "takeout",
        15 * MIN,
    )


def test_a_send_went_out_when_its_last_dish_did():
    h = evening()
    made(h, "o1", PASS, at(18, 16), "L1", "L2", "L3")
    made(h, "o1", PASS, at(18, 18), "L4")  # the beer was carried last
    made(h, "o2", PASS, at(18, 40), "L1")  # the wings went; the chicken was never marked
    h.now = at(21)
    span = times(h)["span"]
    assert figures(span["out"]) == (1, 18, 18, 18, 0, 1)
    # the pass's word is not a station's: nothing of the stations' own times moved
    assert stations({"span": span}) == {"Fryer": (2, 7.5, 7.5, 9, 0, 0), "Wok": (2, 18, 18, 22, 1, 0)}


def test_a_dish_the_pass_sent_out_with_its_station_silent_is_not_timed_for_the_station():
    h = Hub(now=at(17))
    table(h, "o1", at(18), WINGS, GTC)
    made(h, "o1", "fryer", at(18, 6), "L1")
    made(h, "o1", PASS, at(18, 15), "L1", "L2")
    h.now = at(21)
    span = times(h)["span"]
    assert stations({"span": span}) == {"Fryer": (1, 6, 6, 6, 0, 0)}
    assert span["silent"] == [{"code": "wok", "name": "Wok", "open": 1}]
    assert figures(span["out"]) == (1, 15, 15, 15, 0, 0)


def test_a_screen_that_prints_no_ticket_at_a_station_sends_it_nothing_to_time():
    h = Hub(now=at(17))
    skips = clean_ticket_skips({"screens": [{"device": "t1", "stations": ["bar"]}]})
    h.c.app.state.settings.put("ticket_skips", skips)
    table(h, "o1", at(18), BEER)  # poured where it was rung: no ticket anywhere
    table(h, "o2", at(18, 10), BEER, WINGS, table_no="7")
    made(h, "o2", "fryer", at(18, 15), "L2")
    h.now = at(21)
    span = times(h)["span"]
    assert stations({"span": span}) == {"Fryer": (1, 5, 5, 5, 0, 0)}
    assert span["silent"] == []
    assert figures(span["out"]) == (0, None, None, None, 0, 1)  # o2 has food to carry; o1 waits for nobody


def test_an_order_sent_ahead_is_timed_from_when_its_time_came():
    h = Hub(now=at(10))
    h.to_go("o1", at(10), promised_at=at(18, 30), quoted_minutes=30)
    h.ring("o1", "L1", PUPU, at(10, 1))
    h.op("o1", "fire", at(10, 2))
    made(h, "o1", "fryer", at(18, 9), "L1")
    h.now = at(21)
    span = times(h)["span"]
    # its ticket is the kitchen's a minute before six, eight hours after it was rung
    assert stations({"span": span})["Fryer"] == (1, 10, 10, 10, 0, 0)
    assert [row["hour"] for row in span["hours"]] == [17]
    # and before its time has come it is no ticket at all
    early = Hub(now=at(10))
    early.to_go("o1", at(10), promised_at=at(18, 30), quoted_minutes=30)
    early.ring("o1", "L1", PUPU, at(10, 1))
    early.op("o1", "fire", at(10, 2))
    early.now = at(12)
    assert times(early)["span"]["silent"] == []


# --- the dishes and the longest tickets ---------------------------------------------------------------------


def test_the_dishes_are_listed_the_slowest_first_each_timed_until_it_was_made():
    report = times(evening())
    assert [(row["name"], *figures(row)[:4]) for row in report["span"]["dishes"]] == [
        ("General Tso's Chicken", 2, 18, 18, 22),
        ("Egg roll", 1, 9, 9, 9),
        ("Chicken wings", 2, 6.5, 6.5, 7),
    ]


def test_a_dish_of_two_stations_is_made_when_the_last_of_them_made_it():
    sent = at(18)
    duck = Cooked(
        "Peking duck", sent, "t1", ("oven", "wok"), (("oven", sent + 30 * MIN), ("wok", sent + 12 * MIN)), None
    )
    half = Cooked("Half duck", sent, "t1", ("oven", "wok"), (("wok", sent + 10 * MIN),), None)
    whose = Kitchen("o1", "12", "", None, "", False, (duck, half))
    day = (date(2026, 11, 16), date(2026, 11, 16))
    span = kitchen_times([whose], day, comparison(*day), now_ms=at(21), late_min=20)["span"]
    assert [(row["name"], row["count"], row["avg_ms"] / MIN, row["open"]) for row in span["dishes"]] == [
        ("Peking duck", 1, 30, 0)
    ]
    # the wok made both of its dishes; the oven still owes one
    assert stations({"span": span}) == {"wok": (1, 12, 12, 12, 0, 0)}
    assert span["silent"] == [{"code": "oven", "name": "oven", "open": 1}]


def test_the_longest_tickets_are_named_the_longest_first():
    h = evening()
    slowest = times(h)["span"]["slowest"]
    assert [(row["order_id"], row["table"], row["station_name"], row["took_ms"] / MIN) for row in slowest] == [
        ("o2", "7", "Wok", 22),
        ("o1", "12", "Wok", 14),
        ("o1", "12", "Fryer", 9),
        ("o2", "7", "Fryer", 6),
    ]
    assert slowest[0]["sent_ms"] == at(18, 30)
    for n in range(12):
        table(h, f"x{n}", at(19, n), WINGS, table_no=str(20 + n))
        made(h, f"x{n}", "fryer", at(19, n + 30), "L1")
    h.now = at(21)
    slowest = times(h)["span"]["slowest"]
    assert len(slowest) == 10 and [row["order_id"] for row in slowest[:3]] == ["x0", "x1", "x2"]


# --- hours, days and the days before -------------------------------------------------------------------------


def test_the_hours_run_in_the_order_of_a_night_and_every_day_of_a_span_is_listed():
    h = evening()
    table(h, "n1", at(23, 30), WINGS, table_no="3")
    made(h, "n1", "fryer", at(23, 40), "L1")
    table(h, "n2", at(1, 10, day=17), WINGS, table_no="4")  # past midnight: still Monday's service
    made(h, "n2", "fryer", at(1, 14, day=17), "L1")
    table(h, "t1", at(17, day=17), WINGS, table_no="5")
    made(h, "t1", "fryer", at(17, 3, day=17), "L1")
    h.now = at(21, day=18)
    span = times(h, "2026-11-15", "2026-11-18")["span"]
    assert [(row["hour"], row["tickets"]) for row in span["hours"]] == [(17, 1), (18, 4), (23, 1), (1, 1)]
    assert [(row["day"], row["tickets"], row["avg_ms"]) for row in span["days"]] == [
        ("2026-11-15", 0, None),
        ("2026-11-16", 6, 65 * MIN / 6),
        ("2026-11-17", 1, 3 * MIN),
        ("2026-11-18", 0, None),
    ]
    assert span["running"] is True


def test_the_same_days_whole_weeks_earlier_are_held_beside():
    h = Hub(now=at(17, day=9))
    table(h, "w1", at(18, day=9), WINGS, GTC)
    made(h, "w1", "fryer", at(18, 10, day=9), "L1")
    made(h, "w1", "wok", at(18, 20, day=9), "L2")
    made(h, "w1", PASS, at(18, 25, day=9), "L1", "L2")
    table(h, "o1", at(18), WINGS)
    made(h, "o1", "fryer", at(18, 4), "L1")
    h.now = at(21)
    report = times(h)
    assert figures(report["span"]["made"]) == (1, 4, 4, 4, 0, 0)
    assert figures(report["before"]["made"]) == (2, 15, 15, 20, 1, 0)
    assert figures(report["before"]["out"]) == (1, 25, 25, 25, 1, 0)
    assert set(report["before"]) == {"first", "last", "since_ms", "until_ms", "running", "made", "out"}


# --- reckoned from the log, and changing nothing -------------------------------------------------------------


def afresh(h: Hub, first: date, last: date) -> dict:
    """The times of these days reckoned straight from every order in the log, nothing remembered."""
    state = h.c.app.state
    kitchens = [kitchen_of(h.store.view(o)) for o in h.store.order_ids()]
    return kitchen_times(
        [k for k in kitchens if k is not None],
        (first, last),
        comparison(first, last),
        now_ms=h.now,
        takeout=state.printing.takeout_station(),
        skips=state.printing.skips,
        station_names=state.printing.station_names(),
        late_min=20,
    )


def test_an_order_is_replayed_again_only_when_it_changed_and_reads_the_same_either_way():
    h = evening()
    asked: list[list[str]] = []
    views = h.store.views

    def counted(entries):
        asked.append([e.order_id for e in entries])
        return views(entries)

    h.store.views = counted
    day = date(2026, 11, 16)

    def read() -> dict:
        asked.clear()
        answer = times(h)
        replayed = list(asked)
        fresh = afresh(h, day, day)
        assert {key: answer[key] for key in fresh} == fresh
        asked[:] = replayed  # what the reading itself replayed, not this check of it
        return answer

    first = read()
    assert sorted(o for some in asked for o in some) == ["o1", "o2"]  # every order, the first time
    assert read() == first and asked == []  # and none the second
    made(h, "o1", "bar", at(18, 3), "L4")
    h.now = at(21)
    assert stations(read())["Bar"] == (1, 3, 3, 3, 0, 0) and asked == [["o1"]]  # only the order that changed


def test_reading_the_times_changes_nothing():
    h = evening()
    before = [h.c.get(f"/orders/{o}").json() for o in ("o1", "o2")]
    index = [(entry.order_id, entry.version, entry.tip) for entry in h.store.index()]
    times(h)
    times(h, "2026-11-09", "2026-11-16")
    assert [h.c.get(f"/orders/{o}").json() for o in ("o1", "o2")] == before
    assert [(entry.order_id, entry.version, entry.tip) for entry in h.store.index()] == index


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_times_are_the_same_from_postgres():
    import psycopg

    def rung(h: Hub) -> Hub:
        table(h, "o1", at(18), WINGS, EGGROLL, GTC, DRAGON)
        made(h, "o1", "fryer", at(18, 9), "L1", "L2")
        made(h, "o1", "wok", at(18, 14), "L3")
        made(h, "o1", PASS, at(18, 20), "L1", "L2", "L3", "L4")
        h.now = at(21)
        return h

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(17), postgres=DSN)
    try:
        rung(h)
        memory = rung(Hub(now=at(17)))
        for first, last in ((None, None), ("2026-11-09", "2026-11-17")):
            assert times(h, first, last) == times(memory, first, last)
        assert stations(times(h)) == {"Fryer": (1, 9, 9, 9, 0, 0), "Wok": (1, 14, 14, 14, 0, 0)}
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
