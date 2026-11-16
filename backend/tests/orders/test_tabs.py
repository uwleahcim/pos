"""Bar tabs (the Toast comparison's row 13): a check opened with a name and no table. It is rung in and sent
like a table's check, its tickets and its bill are headed with the name, it is on no floor map, and when the
party sits down it is given a table and is that table's check from then on. Its sales are never left out: a
tab paid at the bar is a kind of its own beside the tables, and one that sat down counts with the tables."""

from __future__ import annotations

from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos.orders.check import check_for
from pos.printing.bill import bill_for
from pos.printing.service import MOVED_SLIP_MS, allergy_lines, tab_changes
from pos.sync.oplog import is_tab, replay
from pos.tax import massachusetts

from ..conftest import T0, make_op
from ..printing.fake_printer import decode
from ..printing.test_bill import paper
from ..printing.test_moved_slip import dishes, kitchen, post, seated, slip
from ..printing.test_other_stations import BEER as BAR_BEER
from ..printing.test_other_stations import CHICKEN
from ..printing.test_stations import manager
from .test_day import BEER, DSN, EGGROLL, WINGS, Hub, at, money
from .test_history import said, steps
from .test_menu_orders import payload
from .test_sales import sales


def tab(c: TestClient, order_id: str, name: str, *rung: dict, fire: bool = True) -> list[str]:
    """A tab in `name` with these dishes (L1, L2, ...), sent unless `fire` is false; the tickets it printed."""
    ops = [payload(f"{order_id}-open", "create", 0, tab=True, customer_name=name, order_type="dine_in", server="Ben")]
    ops += [
        payload(f"{order_id}-{n}", "add_line", n, line_id=f"L{n}", item="?", request=dish)
        for n, dish in enumerate(rung, 1)
    ]
    if fire:
        ops.append(payload(f"{order_id}-fire", "fire", 50, course="*"))
    return post(c, order_id, *ops)["print_jobs"]


def open_tab(h: Hub, order_id: str, when: int, name: str = "Linda") -> None:
    h.op(order_id, "create", when, tab=True, customer_name=name, order_type="dine_in", server="Ben", server_id="s2")


def test_a_tab_is_a_named_check_with_no_table_until_it_is_given_one():
    opened = make_op("create", at=0, tab=True, customer_name="  Linda   Wu ", order_type="dine_in")
    state = replay([opened], "o1")
    assert state.is_tab and state.tab_name == "Linda Wu"
    sat = replay([opened, make_op("set_field", at=1, table="12", guests=2)], "o1")
    assert not sat.is_tab and sat.tab_name == ""
    assert sat.fields["tab"] is True and sat.fields["customer_name"] == "  Linda   Wu "  # how it began stays
    # a table's check, a to-go order, and a word that is not "true" are no tabs
    assert is_tab({"tab": True}) and is_tab({"tab": True, "order_type": "dine_in", "table": ""})
    for fields in (
        {},
        {"customer_name": "Lee"},
        {"tab": True, "table": "5"},
        {"tab": True, "order_type": "takeout", "customer_name": "Lee"},
        {"tab": "yes", "customer_name": "Lee"},
        {"tab": 1},
    ):
        assert not is_tab(fields), fields
        assert not replay([make_op("create", at=0, **fields)], "o1").is_tab


def test_a_tabs_ticket_is_headed_with_its_name_and_goes_to_the_stations_like_a_tables():
    c = kitchen("wok", "bar", "takeout")
    assert tab(c, "o1", "Linda", BAR_BEER, CHICKEN) == ["o1-fire:wok", "o1-fire:bar"]  # nothing to bag
    for job in ("o1-fire:wok", "o1-fire:bar"):
        lines = slip(c, job)
        assert "TAB LINDA" in lines and "Server Ben" in lines
        assert "No table" not in lines and not any(line.startswith("Table") for line in lines)
    assert "1 x Tsingtao" in slip(c, "o1-fire:bar") and dishes(c, "o1-fire:wok") == 1  # each its own
    # a tab nobody named is still a tab, and a to-go order still leads with its number and name
    assert tab(c, "o2", "", BAR_BEER) == ["o2-fire:bar"]
    assert "TAB" in slip(c, "o2-fire:bar") and "No table" not in slip(c, "o2-fire:bar")
    to_go = [
        payload("o3-open", "create", 0, order_type="takeout", channel="phone", customer_name="Lee"),
        payload("o3-1", "add_line", 1, line_id="L1", item="?", request=BAR_BEER),
        payload("o3-fire", "fire", 50, course="*"),
    ]
    post(c, "o3", *to_go)
    bag = slip(c, "o3-fire:bar")
    assert any(line.endswith("LEE") and line.startswith("#") for line in bag) and "TAB LEE" not in bag


def test_a_tab_that_sat_down_is_called_by_its_table():
    c = kitchen("bar")
    tab(c, "o1", "Linda", BAR_BEER)
    post(c, "o1", payload("sit", "set_field", 100, table="12", guests=2))
    more = [
        payload("r2", "add_line", 200, line_id="L9", item="?", request=BAR_BEER),
        payload("f2", "fire", 201, course="*"),
    ]
    assert post(c, "o1", *more)["print_jobs"] == ["f2:bar"]
    lines = slip(c, "f2:bar")
    assert "Table 12  2 guests" in lines
    assert "TAB LINDA" not in lines and "LINDA" not in lines  # a name in big letters is a bag's


def test_a_tab_that_sits_down_with_drinks_on_their_way_prints_a_slip_where_they_are_made():
    c = kitchen("wok", "bar")
    tab(c, "o1", "Linda", BAR_BEER, BAR_BEER)
    answer = post(c, "o1", payload("sit", "set_field", 100, table="12", guests=2))
    assert answer["print_jobs"] == ["sit:moved:tab:Linda:bar"]  # the wok has nothing of it
    bar = slip(c, "sit:moved:tab:Linda:bar")
    assert bar[0].startswith("*** MOVED ***")
    assert bar.index("Table 12  2 guests") < bar.index("WAS TAB LINDA") < bar.index("NOW TABLE 12")
    assert bar[bar.index("NOW TABLE 12") + 1] == "These dishes go to the new table:"
    assert bar.count("1 x Tsingtao") == 2
    assert "NOW TABLE 12" in decode(c.app.state.printing.store.get("sit:moved:tab:Linda:bar").data).inverted
    # moved on to another table afterwards, it is a table that moves
    assert post(c, "o1", payload("mv", "set_field", 200, table="14"))["print_jobs"] == ["mv:moved:12:bar"]


def test_nothing_prints_for_a_tab_that_sits_down_with_nothing_on_its_way():
    c = kitchen("bar")
    tab(c, "o1", "Linda", BAR_BEER, fire=False)  # nothing sent yet: its ticket will name the table
    assert post(c, "o1", payload("sit", "set_field", 100, table="12"))["print_jobs"] == []
    # sent long ago: the drinks are in their hands
    late = kitchen("bar", now=T0 + 50 + MOVED_SLIP_MS + 1)
    tab(late, "o1", "Linda", BAR_BEER)
    assert post(late, "o1", payload("sit", "set_field", 100, table="12"))["print_jobs"] == []
    # a manager turned the slip off
    off = kitchen("bar")
    off.put("/settings/tickets", json={"moved": False}, headers=manager(off))
    tab(off, "o1", "Linda", BAR_BEER)
    assert post(off, "o1", payload("sit", "set_field", 100, table="12"))["print_jobs"] == []
    # renamed, handed over, still at the bar: no slip
    same = kitchen("bar")
    tab(same, "o1", "Linda", BAR_BEER)
    assert post(same, "o1", payload("n", "set_field", 100, customer_name="Linda W", server="Amy"))["print_jobs"] == []
    state = same.app.state.store.view("o1")
    assert tab_changes(state, state, T0 + 1000) == []


def test_a_tabs_drinks_that_join_a_tables_check_say_whose_tab_they_were():
    c = kitchen("wok", "bar")
    tab(c, "o1", "Linda", BAR_BEER)
    seated(c, "o2", "14", CHICKEN)
    # the terminal says only where the drink comes from: the hub says it was a tab, and whose
    came = {"order_id": "o1", "line_id": "L1", "tab": "Somebody else", "table": "99"}
    took = post(c, "o2", payload("t1", "add_line", 100, line_id="M1", item="?", **{"from": came}))
    assert took["print_jobs"] == ["t1:moved:tab:Linda:bar"]
    bar = slip(c, "t1:moved:tab:Linda:bar")
    assert "WAS TAB LINDA" in bar and "NOW TABLE 14" in bar and bar.count("1 x Tsingtao") == 1
    line = c.app.state.store.view("o2").lines["M1"]
    assert line.moved_from == {"order_id": "o1", "line_id": "L1", "tab": "Linda"}
    gave = post(
        c,
        "o1",
        payload("m1", "move_line", 101, line_id="L1", to={"order_id": "o2", "line_id": "M1"}),
        payload("m2", "set_field", 102, merged_into="o2"),
        payload("m3", "close", 103),
    )
    assert gave["print_jobs"] == []  # no void, and nothing sent a second time
    # the drink is on one check only, and was sold once
    assert [row["line_id"] for row in c.get("/orders/o1/check").json()["lines"]] == []
    assert [row["line_id"] for row in c.get("/orders/o2/check").json()["lines"]] == ["L1", "M1"]
    # a dish that comes from a table's check says its table, and no tab
    seated(c, "o3", "20", CHICKEN)
    post(
        c, "o2", payload("t2", "add_line", 200, line_id="M2", item="?", **{"from": {"order_id": "o3", "line_id": "L1"}})
    )
    assert c.app.state.store.view("o2").lines["M2"].moved_from == {"order_id": "o3", "line_id": "L1", "table": "20"}


def test_the_bill_of_a_tab_is_headed_with_its_name():
    beer = {"name": "Beer", "unit_price": "6.50"}
    state = replay(
        [
            make_op("create", at=0, tab=True, customer_name="Linda", server="Ben", order_type="dine_in"),
            make_op("add_line", at=1, line_id="L1", item="Beer", qty=2, priced=beer),
        ],
        "o1",
    )
    check = check_for(state, massachusetts())
    lines = paper(bill_for(check, state.fields, at=datetime(2026, 11, 16, 19, 42)))
    assert any(line.startswith("Bar tab  Linda") and line.endswith("7:42 PM") for line in lines)
    assert any(line.startswith("Server Ben") for line in lines)
    assert not any(line.startswith(("Order", "Table")) for line in lines)
    # a tab is eaten in: taxed as a table's check is
    table = replay(
        [
            make_op("create", "o2", at=0, table="5", order_type="dine_in"),
            make_op("add_line", "o2", at=1, line_id="L1", item="Beer", qty=2, priced=beer),
        ],
        "o2",
    )
    assert (check["order_type"], check["tax"], check["total"]) == (
        "dine_in",
        *(check_for(table, massachusetts())[k] for k in ("tax", "total")),
    )
    # sat down, the bill is the table's
    sat = replay([*[make_op("create", at=0, tab=True, customer_name="Linda")], make_op("set_field", at=2, table="12")])
    sat_lines = paper(bill_for(check_for(sat, massachusetts()), sat.fields, at=datetime(2026, 11, 16, 19, 42)))
    assert any(line.startswith("Table 12") for line in sat_lines) and not any("Bar tab" in line for line in sat_lines)


def test_an_allergy_told_on_a_tab_is_the_tabs():
    told = make_op("allergy", at=1, seat=None, allergens=["peanut"], note="")
    a_tab = replay([make_op("create", at=0, tab=True, customer_name="Linda"), told], "o1")
    assert allergy_lines(a_tab, {"peanut": "Peanuts"}) == ("Tab: Peanuts",)
    a_table = replay([make_op("create", at=0, table="5"), told], "o1")
    assert allergy_lines(a_table, {"peanut": "Peanuts"}) == ("Table: Peanuts",)
    to_go = replay([make_op("create", at=0, order_type="takeout"), told], "o1")
    assert allergy_lines(to_go, {"peanut": "Peanuts"}) == ("Order: Peanuts",)


def bar_night(h: Hub | None = None) -> Hub:
    """Monday the 16th, read at nine: b1, Linda's tab, two beers, paid cash at the bar and closed. b2, Wu's
    tab, a beer at the bar, then sat at table 12 with two guests, wings, paid by card and closed an hour
    after it was opened. b3, Kim's tab, a beer, still open. o1, table 5, an egg roll, still open."""
    h = h or Hub(now=at(17))
    open_tab(h, "b1", at(17))
    h.ring("b1", "L1", BEER, at(17, 1), by="Ben", qty=2)
    h.op("b1", "fire", at(17, 2))
    h.pay("b1", at(17, 40), h.check("b1")["total"], "cash")
    h.op("b1", "close", at(17, 41))
    open_tab(h, "b2", at(18), name="Wu")
    h.ring("b2", "L1", BEER, at(18, 1), by="Ben")
    h.op("b2", "fire", at(18, 2))
    h.op("b2", "set_field", at(18, 10), table="12", guests=2, server="Amy", server_id="s1", by="Amy", by_id="s1")
    h.ring("b2", "L2", WINGS, at(18, 12))
    h.op("b2", "fire", at(18, 13))
    h.pay("b2", at(18, 59), h.check("b2")["total"], "card")
    h.op("b2", "close", at(19))
    open_tab(h, "b3", at(19, 30), name="Kim")
    h.ring("b3", "L1", BEER, at(19, 31), by="Ben")
    h.table("o1", at(20), table="5")
    h.ring("o1", "L1", EGGROLL, at(20, 1))
    h.now = at(21)
    return h


def test_a_tab_paid_at_the_bar_is_a_sale_of_its_own_kind_and_every_sale_is_counted():
    h = bar_night()
    report = h.report()
    kinds = {k["kind"]: (k["count"], k["guests"], k["amount"]) for k in report["kinds"]}
    # two tabs that never sat down (one still open); Wu's sat down, so it counts with the tables
    assert kinds == {"tab": (2, 0, "19.50"), "dine_in": (2, 4, "18.95")}
    assert (report["checks"], report["sales"]["gross"]) == (4, "38.45")
    assert sum(money(k["amount"]) for k in report["kinds"]) == money(report["sales"]["gross"])
    span = sales(h)["span"]
    assert {k["kind"]: (k["count"], k["amount"]) for k in span["kinds"]} == {
        "tab": (2, "19.50"),
        "dine_in": (2, "18.95"),
    }
    assert span["sales"]["gross"] == "38.45"
    # a tab paid at the bar is no table's turn; the one that sat down stood an hour
    assert span["turn"] == {"tables": 1, "minutes": 60}
    # and the money of both is in the till's count: Linda paid cash at the bar, Wu by card at the table
    taken = {t["method"]: t["amount"] for t in span["money"]["taken"]}
    assert taken == {"cash": h.check("b1")["total"], "card": h.check("b2")["total"]}


def test_an_open_tab_is_listed_as_one_and_the_day_prints_the_bars_tabs():
    h = bar_night()
    report = h.report()
    listed = [(r["order_id"], r.get("tab", False), r["table"], r["customer_name"]) for r in report["open"]]
    assert listed == [("b3", True, None, "Kim"), ("o1", False, "5", None)]
    answer = h.c.post("/reports/day/print", json={}, headers=h.manager())
    assert answer.status_code == 202, answer.text
    text = [line.strip() for line in decode(h.printing.store.get(answer.json()["job_id"]).data).text if line.strip()]
    assert any(line.startswith("Bar tabs (2 checks)") and line.endswith("19.50") for line in text)
    assert any(line.startswith("Tables (2 checks)") and line.endswith("18.95") for line in text)


def test_the_history_of_a_tab_says_it_began_as_one_and_where_it_sat_down():
    h = bar_night()
    answer = h.c.get("/orders/b3/history", headers=h.manager()).json()
    assert (answer["order"].get("tab"), answer["order"]["table"], answer["order"]["customer_name"]) == (
        True,
        None,
        "Kim",
    )
    assert answer["steps"][0]["what"] == "opened"
    assert answer["steps"][0]["fields"] == {
        "order_type": "dine_in",
        "tab": True,
        "customer_name": "Kim",
        "server": "Ben",
    }
    # sat down: the table's check now, which began as a tab and says who sat it and whose it became
    sat = h.c.get("/orders/b2/history", headers=h.manager()).json()
    assert "tab" not in sat["order"] and sat["order"]["table"] == "12"
    assert sat["steps"][0]["fields"]["tab"] is True
    moved = {s["what"]: s for s in sat["steps"] if s["what"] in ("table", "server", "guests")}
    assert said(moved["table"], "was", "now", "by") == (None, "12", "Amy")
    assert said(moved["server"], "was", "now") == ("Ben", "Amy")
    assert said(moved["guests"], "was", "now") == (None, 2)
    # renamed: a step like any other name's
    h.op("b3", "set_field", at(21, 5), customer_name="Kim Lee", by="Ben", by_id="s2")
    assert said(steps(h, "b3")[-1], "what", "field", "was", "now") == ("field", "customer_name", "Kim", "Kim Lee")


def test_a_drink_that_came_from_a_tab_says_so_in_the_tables_history():
    h = bar_night()
    h.op("o1", "add_line", at(21, 1), line_id="M1", item="?", qty=1, **{"from": {"order_id": "b3", "line_id": "L1"}})
    h.op("b3", "move_line", at(21, 1), line_id="L1", to={"order_id": "o1", "line_id": "M1"})
    came = steps(h, "o1")[-1]
    assert said(came, "what", "other", "other_table", "other_tab", "rung_by") == ("moved_in", "b3", None, "Kim", "Ben")
    left = steps(h, "b3")[-1]
    assert said(left, "what", "other", "other_table") == ("moved_out", "o1", "5")
    # between two tables there is no tab to name
    h.table("o2", at(21, 2), table="7")
    h.op("o2", "add_line", at(21, 3), line_id="M2", item="?", qty=1, **{"from": {"order_id": "o1", "line_id": "L1"}})
    assert "other_tab" not in steps(h, "o2")[-1]


def test_a_tab_emptied_onto_a_tables_check_is_no_bar_tab_of_its_own_and_no_tables_turn():
    h = Hub(now=at(17))
    open_tab(h, "b1", at(17))
    h.ring("b1", "L1", BEER, at(17, 1), by="Ben")
    h.op("b1", "fire", at(17, 2))
    h.table("o1", at(17, 30), table="5")
    h.op("o1", "add_line", at(17, 31), line_id="M1", item="?", qty=1, **{"from": {"order_id": "b1", "line_id": "L1"}})
    h.op("b1", "move_line", at(17, 31), line_id="L1", to={"order_id": "o1", "line_id": "M1"})
    h.op("b1", "set_field", at(17, 31), merged_into="o1")
    h.op("b1", "close", at(17, 31))
    h.pay("o1", at(18, 29), h.check("o1")["total"], "card")
    h.op("o1", "close", at(18, 30))
    h.now = at(21)
    span = sales(h)["span"]
    # the beer was sold once, at the table; the emptied tab is a check that came to nothing, with the tables
    assert {k["kind"]: (k["count"], k["amount"]) for k in span["kinds"]} == {"dine_in": (2, "6.50")}
    assert span["sales"]["gross"] == "6.50" and span["turn"] == {"tables": 1, "minutes": 60}
    assert {k["kind"]: k["amount"] for k in h.report()["kinds"]} == {"dine_in": "6.50"}


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_tabs_read_the_same_from_postgres():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(17), postgres=DSN)
    try:
        bar_night(h)
        memory = bar_night()
        for figure in ("kinds", "checks", "sales", "open"):
            assert h.report()[figure] == memory.report()[figure], figure
        assert sales(h)["span"]["kinds"] == sales(memory)["span"]["kinds"]
        assert h.store.view("b3").is_tab and not h.store.view("b2").is_tab
    finally:
        h.store.close()
