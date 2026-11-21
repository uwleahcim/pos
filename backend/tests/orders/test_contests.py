"""Contests for the staff: who rang in the most of a dish, of a category, or the most sales.

A manager sets a contest up; who is ahead is added up from the same checks as the reports, each time it is
asked. These tests ring a small evening through the hub the way the screens do, and read the board the way
a manager and each of the staff get it. The staff are the demo four: Amy a server, Ben a bartender, Mike a
manager and Holly a host."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from pos.menu.service import load_definitions
from pos.orders.contest import CONTESTS_MAX, Contest, clean_contests, contests_of
from pos.orders.sales import MAX_DAYS

from .test_day import BEER, DSN, EGGROLL, PUPU, SODA, WINGS, Hub, at, evening, money

MONDAY = "2026-11-16"  # the day `evening` rings


def contest(**said) -> dict:
    """A contest as the manager's screen sends it: on sales, for that Monday, unless said otherwise."""
    return {"name": "Monday night", "counts": "sales", "first": MONDAY, "last": MONDAY, **said}


def save(h: Hub, *contests: dict, headers: dict | None = None):
    headers = h.manager() if headers is None else headers
    return h.c.put("/settings/contests", json={"contests": list(contests)}, headers=headers)


def saved(h: Hub, *contests: dict) -> list[dict]:
    answer = save(h, *contests)
    assert answer.status_code == 200, answer.text
    return answer.json()["contests"]


def board(h: Hub, contest_id: str) -> dict:
    answer = h.c.get(f"/reports/contests/{contest_id}", headers=h.manager())
    assert answer.status_code == 200, answer.text
    return answer.json()


def mine(h: Hub, staff_id: str) -> list[dict]:
    answer = h.c.get("/contests", params={"staff_id": staff_id})
    assert answer.status_code == 200, answer.text
    return answer.json()["contests"]


def rows(standings: list[dict]) -> list[tuple]:
    return [(row["name"], row["place"], row["count"], row["amount"]) for row in standings]


def test_there_is_no_contest_until_a_manager_sets_one_up():
    h = evening()
    listed = h.c.get("/settings/contests").json()
    assert listed["contests"] == [] and listed["today"] == MONDAY
    assert listed["roles"] == ["server", "bartender", "host", "cashier", "kitchen", "driver", "manager", "owner"]
    assert listed["standard_roles"] == ["server", "bartender"]
    # the categories one can count: each with a dish on sale, as the reports name them, in the menu's order
    # (by name where the menu gives them none)
    assert listed["categories"][:3] == [
        {"code": "sides", "name": "Appetizers", "menu": "Dinner"},
        {"code": "beer", "name": "Beer", "menu": "Dinner"},
        {"code": "chefs", "name": "Chef's Specials", "menu": "Dinner"},
    ]
    assert len({c["code"] for c in listed["categories"]}) == len(listed["categories"]) == 11
    assert listed["limits"] == {"contests": CONTESTS_MAX, "name": 40, "note": 80, "days": MAX_DAYS, "shown_days": 7}
    assert mine(h, "s1") == []


def test_only_a_manager_sets_a_contest_and_only_the_reports_power_reads_a_whole_board():
    h = evening()
    assert save(h, contest(), headers={}).status_code == 401
    assert save(h, contest(), headers={"authorization": "Bearer nobody"}).status_code == 401
    [made] = saved(h, contest())
    assert h.c.get(f"/reports/contests/{made['id']}").status_code == 401
    # a host handed the reports reads the board, and still sets nothing
    powers = h.c.put("/settings/powers", json={"roles": {"reports": ["host"]}}, headers=h.manager())
    assert powers.status_code == 200
    token = h.c.post("/admin/session", json={"device": "t1", "pin": "3333"}).json()["token"]
    holly = {"authorization": f"Bearer {token}"}
    assert h.c.get(f"/reports/contests/{made['id']}", headers=holly).status_code == 200
    refused = save(h, headers=holly)
    assert refused.status_code == 403 and refused.json()["detail"]["power"] == "settings"
    assert len(h.c.get("/settings/contests").json()["contests"]) == 1
    assert h.c.get("/reports/contests/nothing", headers=h.manager()).status_code == 404


@pytest.mark.parametrize(
    "said",
    [
        {"name": "  "},
        {"name": "x" * 41},
        {"note": "x" * 81},
        {"counts": "tips"},
        {"counts": "dish"},
        {"counts": "category", "category": ""},
        {"first": "Monday"},
        {"last": "2026-02-30"},
        {"first": "2026-11-17"},  # after its last day
        {"first": "2026-08-16"},  # 93 days
        {"roles": []},
        {"roles": ["server", "chef"]},
        {"board": "nobody"},
        {"id": "two words"},
    ],
)
def test_a_contest_that_makes_no_sense_is_refused(said):
    h = Hub()
    answer = save(h, contest(**said))
    assert answer.status_code == 422 and answer.json()["detail"]["error"] == "bad_value", answer.text
    assert h.c.get("/settings/contests").json()["contests"] == []


def test_the_dish_or_the_category_of_a_new_contest_is_on_the_menu():
    h = Hub()
    for said, error in (
        ({"counts": "dish", "item": "UNICORN"}, "unknown_dish"),
        ({"counts": "category", "category": "unicorns"}, "unknown_category"),
        ({"counts": "dish", "item": "sides"}, "unknown_dish"),  # a category is no dish
    ):
        answer = save(h, contest(**said))
        assert answer.status_code == 422 and answer.json()["detail"]["error"] == error, said
    [dish, category] = saved(
        h,
        contest(name="Wings week", counts="dish", item="WINGS"),
        contest(name="Starters", counts="category", category="sides"),
    )
    # called what the menu calls it, whatever the screen sent
    assert (dish["what"], dish["item"], dish["category"]) == ("Chicken wings", "WINGS", None)
    assert (category["what"], category["item"], category["category"]) == ("Appetizers", None, "sides")


def test_a_list_holds_twelve_contests_and_each_id_once():
    h = Hub()
    many = [contest(name=f"Night {n}") for n in range(CONTESTS_MAX + 1)]
    assert save(h, *many).status_code == 422
    listed = saved(h, *many[:CONTESTS_MAX])
    assert len({c["id"] for c in listed}) == CONTESTS_MAX
    twice = save(h, {**listed[0]}, {**listed[1], "id": listed[0]["id"]})
    assert twice.status_code == 422


def test_a_new_contest_is_given_an_id_and_says_who_set_it_and_when():
    h = evening()
    [made] = saved(h, contest(name="  Monday   night ", note=" Winner picks the staff meal "))
    assert (made["id"], made["name"], made["note"]) == ("monday-night", "Monday night", "Winner picks the staff meal")
    assert (made["roles"], made["board"], made["what"]) == (["server", "bartender"], "own", "")
    assert (made["state"], made["shown"], made["days"]) == ("running", True, 1)
    assert (made["set_by"], made["set_ms"]) == ("Mike", at(21))
    # the same name again is another contest; saved as it was, the first keeps who set it and when
    h.now = at(21, 30)
    first, second = saved(h, made, contest())
    assert (first["id"], second["id"]) == ("monday-night", "monday-night-2")
    assert (first["set_ms"], second["set_ms"]) == (at(21), at(21, 30))
    # changed, it says when; and what a screen sends as `set_by` counts for nothing
    h.now = at(21, 45)
    first, second = saved(h, {**first, "last": "2026-11-22", "set_by": "Amy", "set_ms": 1}, second)
    assert (first["set_by"], first["set_ms"], first["days"]) == ("Mike", at(21, 45), 7)
    assert second["set_ms"] == at(21, 30)
    # taken out of the list, it is gone
    assert [c["id"] for c in saved(h, second)] == ["monday-night-2"]


def test_a_contest_on_sales_is_the_days_sales_by_who_rang_them():
    h = evening()
    [made] = saved(h, contest())
    read = board(h, made["id"])
    assert rows(read["standings"]) == [("Amy", 1, 6, "52.10"), ("Ben", 2, 1, "6.50")]
    assert read["front"] == ["Amy"] and read["of"] == 2
    assert read["total"] == {"count": 7, "amount": "58.60"} and read["others"] == {"count": 0, "amount": "0.00"}
    # the very figures the day's report gives for each of them, and together the day's dishes
    report = h.report()
    assert [(s["name"], s["amount"]) for s in report["staff"]] == [(r["name"], r["amount"]) for r in read["standings"]]
    assert read["total"]["amount"] == report["sales"]["gross"]


def test_what_somebody_who_does_not_take_part_rang_is_added_up_apart():
    h = evening()
    [made] = saved(h, contest())
    h.table("m1", at(21, 5), table="9")
    h.ring("m1", "L1", SODA, at(21, 6), by="Mike")  # the manager helps out
    h.op("m1", "add_line", at(21, 7), line_id="L2", item="?", qty=1, request={**BEER, "qty": 1}, by="Zed")
    h.op("m1", "add_line", at(21, 8), line_id="L3", item="?", qty=2, request={**BEER, "qty": 2}, by="Ben")  # no id
    read = board(h, made["id"])
    assert rows(read["standings"]) == [("Amy", 1, 6, "52.10"), ("Ben", 2, 3, "19.50")]
    assert read["others"] == {"count": 2, "amount": "9.45"}  # Mike's soda, and a beer by somebody not on the staff
    gross = money(h.report()["sales"]["gross"])
    assert money(read["total"]["amount"]) + money(read["others"]["amount"]) == gross
    # with the managers in the contest, Mike is on the board
    [made] = saved(h, {**made, "roles": ["server", "bartender", "manager"]})
    read = board(h, made["id"])
    assert rows(read["standings"])[-1] == ("Mike", 3, 1, "2.95") and read["others"]["amount"] == "6.50"


def test_a_contest_on_a_dish_or_a_category_goes_by_how_many():
    h = evening()
    rolls, starters, beers = saved(
        h,
        contest(name="Egg rolls", counts="dish", item="EGGROLL"),
        contest(name="Starters", counts="category", category="sides"),
        contest(name="Beers", counts="category", category="beer"),
    )
    # two on table 12; the one on table 7 was voided and counts for nobody
    assert rows(board(h, rolls["id"])["standings"]) == [("Amy", 1, 2, "7.00"), ("Ben", None, 0, "0.00")]
    # wings, two egg rolls, a platter to go and a spring roll nobody sent yet: the day's report says five too
    assert rows(board(h, starters["id"])["standings"]) == [("Amy", 1, 5, "36.15"), ("Ben", None, 0, "0.00")]
    assert rows(board(h, beers["id"])["standings"]) == [("Ben", 1, 1, "6.50"), ("Amy", None, 0, "0.00")]
    assert board(h, rolls["id"])["front"] == ["Amy"]


def test_a_check_counts_on_its_own_day_and_a_voided_one_never():
    h = evening()
    week, tuesday, sunday = saved(
        h,
        contest(name="The week", first="2026-11-15", last="2026-11-21"),
        contest(name="Tuesday", first="2026-11-17", last="2026-11-17"),
        contest(name="Sunday", first="2026-11-15", last="2026-11-15"),
    )
    # rung on Monday for Tuesday evening: Tuesday's, as in the reports
    assert rows(board(h, tuesday["id"])["standings"]) == [("Amy", 1, 2, "33.90"), ("Ben", None, 0, "0.00")]
    # Sunday's table with its tea, and Sunday's tab with its beer, paid on Monday
    assert rows(board(h, sunday["id"])["standings"]) == [("Amy", 1, 2, "9.00"), ("Ben", None, 0, "0.00")]
    whole = board(h, week["id"])
    assert rows(whole["standings"]) == [("Amy", 1, 10, "95.00"), ("Ben", 2, 1, "6.50")]
    # the soda on the check voided whole is in none of them
    assert money(whole["total"]["amount"]) == Decimal("52.10") + Decimal("33.90") + Decimal("9.00") + Decimal("6.50")
    # a late void is in the next reading
    h.op("o1", "void_line", at(21, 10), line_id="L1", reason="kitchen-error", by="Mike", by_id="s3")
    assert rows(board(h, week["id"])["standings"])[0] == ("Amy", 1, 9, "86.05")


def test_a_dish_given_away_was_still_sold_and_counts_at_its_price():
    h = Hub()
    [made] = saved(h, contest())
    h.table("c1", at(18))
    h.ring("c1", "L1", WINGS, at(18, 1))
    h.op("c1", "discount", at(18, 5), discount_id="D1", reason="loyalty", kind="amount", value="8.95", applied_by="Amy")
    assert h.check("c1")["total"] == "0.00"
    assert rows(board(h, made["id"])["standings"])[0] == ("Amy", 1, 1, "8.95")
    assert h.report()["staff"][0]["amount"] == "8.95"  # as the day's report counts it


def test_people_level_share_a_place_and_nothing_yet_is_no_place():
    h = Hub()
    [made] = saved(h, contest(name="Beers", counts="dish", item="TSINGTAO", roles=["server", "bartender", "host"]))
    assert rows(board(h, made["id"])["standings"]) == [
        ("Amy", None, 0, "0.00"),
        ("Ben", None, 0, "0.00"),
        ("Holly", None, 0, "0.00"),
    ]
    assert board(h, made["id"])["front"] == []
    h.table("t1", at(18))
    h.ring("t1", "L1", BEER, at(18, 1), qty=2)
    h.ring("t1", "L2", BEER, at(18, 2), by="Ben")
    h.ring("t1", "L3", BEER, at(18, 3), by="Ben")
    read = board(h, made["id"])
    assert rows(read["standings"]) == [("Amy", 1, 2, "13.00"), ("Ben", 1, 2, "13.00"), ("Holly", None, 0, "0.00")]
    assert read["front"] == ["Amy", "Ben"] and read["of"] == 3


def test_each_person_sees_their_own_number_and_who_is_in_front():
    h = evening()
    saved(h, contest(note="Winner picks the staff meal"))
    [amy], [ben], [holly], [mike] = (mine(h, who) for who in ("s1", "s2", "s4", "s3"))
    assert (amy["name"], amy["note"], amy["state"], amy["board"]) == (
        "Monday night",
        "Winner picks the staff meal",
        "running",
        "own",
    )
    assert amy["takes_part"] is True and amy["standings"] is None
    assert (amy["me"]["place"], amy["me"]["count"], amy["me"]["amount"], amy["of"]) == (1, 6, "52.10", 2)
    assert (ben["me"]["place"], ben["me"]["amount"], ben["front"], ben["standings"]) == (2, "6.50", ["Amy"], None)
    # a host and a manager do not take part: they see who is in front, and no number at all
    for other in (holly, mike):
        assert (other["takes_part"], other["me"], other["front"], other["standings"]) == (False, None, ["Amy"], None)
        assert "total" not in other and "others" not in other
    assert h.c.get("/contests", params={"staff_id": "s99"}).status_code == 404
    assert h.c.get("/contests").status_code == 422


def test_the_whole_board_is_for_everybody_only_where_the_manager_said_so():
    h = evening()
    [made] = saved(h, contest(board="all"))
    for who in ("s1", "s2", "s4"):
        [seen] = mine(h, who)
        assert rows(seen["standings"]) == [("Amy", 1, 6, "52.10"), ("Ben", 2, 1, "6.50")]
        assert "others" not in seen  # what the others rang stays in the manager's report
    saved(h, {**made, "board": "own"})
    assert mine(h, "s4")[0]["standings"] is None


def test_a_contest_is_on_the_staffs_screens_from_when_it_is_set_until_a_week_after_it_ends():
    h = evening()
    coming, last_week, long_ago = saved(
        h,
        contest(name="Next weekend", first="2026-11-20", last="2026-11-22"),
        contest(name="Last week", first="2026-11-03", last="2026-11-09"),
        contest(name="October", first="2026-10-01", last="2026-10-31"),
    )
    assert [(c["state"], c["shown"]) for c in (coming, last_week, long_ago)] == [
        ("coming", True),
        ("over", True),  # its last day was a week ago today
        ("over", False),
    ]
    seen = mine(h, "s1")
    assert [c["name"] for c in seen] == ["Next weekend", "Last week"]
    # not begun: Amy will take part, and nothing counts yet
    assert (seen[0]["takes_part"], seen[0]["me"]["place"], seen[0]["me"]["count"], seen[0]["front"]) == (
        True,
        None,
        0,
        [],
    )
    assert mine(h, "s4")[0]["takes_part"] is False
    # the manager's list keeps the old one, and its board still reads
    assert len(h.c.get("/settings/contests").json()["contests"]) == 3
    assert board(h, long_ago["id"])["state"] == "over"
    # the next morning last week's is off the screens too
    h.now = at(9, day=17)
    assert [c["name"] for c in mine(h, "s1")] == ["Next weekend"]


def test_reading_a_board_writes_nothing_and_changes_no_sale():
    h = evening()
    [made] = saved(h, contest(board="all"))
    before, report = h.store.cursor, h.report()
    for _ in range(2):
        board(h, made["id"])
        mine(h, "s1")
        h.c.get("/settings/contests")
    assert h.store.cursor == before and h.report() == report
    # setting a contest, changing it and taking it away touch no order either
    saved(h, {**made, "counts": "dish", "item": "WINGS"})
    saved(h)
    assert h.store.cursor == before and h.report() == report


def test_a_dish_taken_off_the_menu_leaves_its_contest_as_it_was():
    h = evening()
    gone = contest(id="old", name="Old special", counts="dish", item="GONE", what="Lobster special")
    h.c.app.state.settings.put("contests", clean_contests({"contests": [gone]}))
    [listed] = h.c.get("/settings/contests").json()["contests"]
    assert (listed["what"], listed["item"]) == ("Lobster special", "GONE")
    # saved again as it is, or with other days, it stays; pointed at another dish the menu lacks, it does not
    assert saved(h, {**listed, "last": "2026-11-18"})[0]["what"] == "Lobster special"
    assert save(h, {**listed, "item": "GONE2"}).status_code == 422
    assert rows(board(h, "old")["standings"]) == [("Amy", None, 0, "0.00"), ("Ben", None, 0, "0.00")]


def test_the_checked_setting_reads_back_and_a_stored_one_that_does_not_read_is_left_out():
    for wrong in ({"contests": "all"}, {"contests": [contest(roles="server")]}, {"contests": [contest(name=7)]}):
        with pytest.raises(ValueError):
            clean_contests(wrong)
    cleaned = clean_contests({"contests": [contest(roles=["manager", "bartender", "bartender"], board=None)]})
    [entry] = cleaned["contests"]
    assert entry["roles"] == ["bartender", "manager"] and entry["board"] == "own"  # the screen's order, each once
    assert clean_contests(cleaned) == cleaned and clean_contests({}) == {"contests": []}
    [read] = contests_of(cleaned)
    assert (read.first, read.last, read.by_money) == (date(2026, 11, 16), date(2026, 11, 16), True)
    assert read.state(date(2026, 11, 15)) == "coming" and read.state(date(2026, 11, 17)) == "over"
    assert read.shown(date(2026, 11, 23)) and not read.shown(date(2026, 11, 24))
    broken = [{"id": "x", "counts": "sales", "first": "soon", "last": "later"}, "words", {"id": "y"}]
    assert contests_of({"contests": [*broken, entry]}) == [read]
    assert contests_of(None) == [] and Contest.of({}) is None
    defs = load_definitions("restaurant")
    wings = Contest("w", "Wings", "dish", read.first, read.last, item="WINGS", what="Wings (old name)")
    assert wings.what_now(defs) == "Chicken wings" and wings.what_now(None) == "Wings (old name)"


def test_a_platter_counts_as_a_platter():
    h = Hub()
    [made] = saved(h, contest(name="Platters", counts="dish", item="PUPU"))
    h.to_go("p1", at(18))
    h.ring("p1", "L1", PUPU, at(18, 1), qty=3)
    h.ring("p1", "L2", EGGROLL, at(18, 2))
    assert rows(board(h, made["id"])["standings"])[0] == ("Amy", 1, 3, "50.85")


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_board_is_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(19, day=15), postgres=DSN)
    try:
        evening(h)
        memory = evening()
        week = contest(name="The week", first="2026-11-15", last="2026-11-21", board="all")
        starters = contest(name="Starters", counts="category", category="sides")
        for hub in (h, memory):
            saved(hub, week, starters)
        for contest_id in ("the-week", "starters"):
            assert board(h, contest_id) == board(memory, contest_id)
            assert board(h, contest_id) == board(memory, contest_id)  # and again, from what is remembered
        assert mine(h, "s2") == mine(memory, "s2")
        assert rows(board(h, "the-week")["standings"]) == [("Amy", 1, 10, "95.00"), ("Ben", 2, 1, "6.50")]
    finally:
        h.store.close()
    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
