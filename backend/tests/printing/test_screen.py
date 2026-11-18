"""A station's screen: the dishes it has to make, as its tickets say them, each send of an order a ticket, the
longest in the kitchen first. A cook marks a dish made and it leaves; the mark is the kitchen's own word on
the order and changes nothing of the check. What is on a screen follows the paper: a dish stands where it is
cooked, a to-go order whole where it is packed, an order sent ahead only once its time has come."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.screen import KEEP_MS, PASS, RECENT, kitchen_screen
from pos.printing.service import SOON_MS, Printer, PrintService
from pos.settings import DEFAULTS, SettingStore
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore, replay

from ..conftest import T0, make_op, servers_void
from .test_held import CATERING, SATURDAY, START, hub, post, release
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen
from .test_stations import manager, menu_with_takeout
from .test_ticket_skips import BAR_SCREEN, op, skipping
from .test_ticket_skips import send as send_from

DSN = os.environ.get("POS_TEST_DATABASE_URL")
MINUTE = 60_000
TABLE = {"table": "12", "order_type": "dine_in", "server": "Amy", "guests": 4}
PHONE = {"order_type": "takeout", "channel": "phone", "customer_name": "Linda"}


def send(c: TestClient, order_id: str, *dishes: dict, at: int = 0, device: str = "t1", **how) -> None:
    """Opens the order (once) with these dishes and sends them; the dishes are `L{at}-1`, `L{at}-2`, ..."""
    send_from(c, device, order_id, *dishes, at=at, **(how or TABLE))


def mark(
    c: TestClient, order_id: str, station: str, *lines: str, at: int, done: bool = True, device: str = "k1"
) -> None:
    """A station's screen says these dishes are made (or takes it back)."""
    said = op(device, f"{order_id}-{station}-{at}", "done", at, station=station, line_ids=list(lines), done=done)
    answer = c.post(f"/orders/{order_id}/ops", json=[{**said, "order_id": order_id}])
    assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text


def screen(c: TestClient, *stations: str) -> dict:
    answer = c.get("/kitchen/screen", params={"stations": ",".join(stations)})
    assert answer.status_code == 200, answer.text
    return answer.json()


def on(c: TestClient, *stations: str, recent: bool = False) -> list[tuple[str, list[str]]]:
    """What the screen lists: each ticket's order and its dishes, a made one in brackets, a void struck."""

    def words(line: dict) -> str:
        said = f"{line['qty']} {line['label']}"
        said = f"~{said}~" if line["void"] else said
        return f"({said})" if line["done"] else said

    listed = screen(c, *stations)["recent" if recent else "tickets"]
    return [(ticket["order_id"], [words(line) for line in ticket["lines"]]) for ticket in listed]


def clocked(clock: list[int], *printers: str, settings: SettingStore | None = None) -> TestClient:
    """A hub whose clock the test holds, with a printer at each of these stations (none: a location that
    prints nothing)."""
    made = [Printer(p, f"10.0.0.{n}", id=p) for n, p in enumerate(printers, 1)]
    return TestClient(
        create_app(
            OpStore(physical=lambda: clock[0]),
            menu=menu_with_takeout(),
            printing=PrintService(made, direct=False, now=lambda: clock[0]),
            settings=settings or SettingStore(),
        )
    )


# --- what a screen lists ------------------------------------------------------------------------------------


def test_a_station_s_screen_lists_its_dishes_of_each_send_the_oldest_first():
    c = kitchen("wok", "sushi", "bar")
    send(c, "o1", CHICKEN, ROLL, BEER)
    send(c, "o2", CHICKEN, CHICKEN, table="7", order_type="dine_in")
    send(c, "o1", CHICKEN, at=60)  # more for table 12, later: a ticket of its own, like on paper
    assert on(c, "wok") == [
        ("o1", ["1 左宗鸡 (Qt)"]),
        ("o2", ["1 左宗鸡 (Qt)", "1 左宗鸡 (Qt)"]),
        ("o1", ["1 左宗鸡 (Qt)"]),
    ]
    assert on(c, "sushi") == [("o1", ["1 加州卷"])]
    assert on(c, "bar") == [("o1", ["1 Tsingtao"])]

    first = screen(c, "wok")["tickets"][0]
    assert first["id"] == f"o1:{T0 + 50}"
    assert (first["table"], first["server"], first["guests"], first["to_go"]) == ("12", "Amy", 4, False)
    assert first["since_ms"] == T0 + 50  # when it was sent: what the screen counts its minutes from
    assert first["also_at"] == ["Sushi bar", "Bar"]  # who else cooks for this send, as the paper says
    line = first["lines"][0]
    assert (line["line_id"], line["stations"], line["done"], line["void"]) == ("L0-1", ["wok"], False, False)
    assert screen(c, "wok")["tickets"][2]["also_at"] == []
    assert screen(c, "wok")["stations"] == [{"code": "wok", "name": "Wok"}]


def test_a_dish_not_sent_is_on_no_screen():
    c = kitchen("wok")
    rung = op("t1", "o1-open", "create", 0, **TABLE)
    dish = op("t1", "o1-1", "add_line", 1, line_id="L1", item="?", request=CHICKEN)
    assert c.post("/orders/o1/ops", json=[rung, dish]).status_code == 202
    assert on(c, "wok") == []


def test_the_dishes_are_worded_as_the_ticket_words_them():
    c = kitchen("wok", "sushi")
    spicy = {**CHICKEN, "selections": [{"group_id": "spice", "option_id": "spice:extra"}]}
    opened = op("t1", "o1-open", "create", 0, **TABLE)
    dish = op("t1", "o1-1", "add_line", 1, line_id="L1", item="?", request=spicy, qty=2, seat=3, note="no onions")
    told = op("t1", "o1-al", "allergy", 2, seat=3, allergens=["peanut"], note="")
    fire = op("t1", "o1-fire", "fire", 50, course="*")
    answer = c.post("/orders/o1/ops", json=[opened, dish, told, fire])
    assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text
    ticket = screen(c, "wok")["tickets"][0]
    line = ticket["lines"][0]
    assert (line["qty"], line["label"], line["seat"], line["note"]) == (2, "左宗鸡 (Qt)", 3, "no onions")
    assert line["modifiers"] and len(line["modifiers"]) == len(line["depths"])
    assert line["allergy"] == "Peanuts" and ticket["allergies"] == ["Seat 3: Peanuts"]


# --- marking a dish made ------------------------------------------------------------------------------------


def test_a_dish_marked_made_leaves_and_a_finished_ticket_is_kept_at_hand():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, CHICKEN, ROLL)
    mark(c, "o1", "wok", "L0-1", at=60)
    assert on(c, "wok") == [("o1", ["(1 左宗鸡 (Qt))", "1 左宗鸡 (Qt)"])]  # one made, one to go: still a ticket
    assert on(c, "sushi") == [("o1", ["1 加州卷"])]  # the wok's word is the wok's alone
    mark(c, "o1", "wok", "L0-2", at=70)
    assert on(c, "wok") == []
    assert on(c, "wok", recent=True) == [("o1", ["(1 左宗鸡 (Qt))", "(1 左宗鸡 (Qt))"])]
    assert screen(c, "wok")["recent"][0]["done_ms"] == T0 + 70
    # brought back: the station takes its word back, and the ticket is where it was
    mark(c, "o1", "wok", "L0-1", "L0-2", at=80, done=False)
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)", "1 左宗鸡 (Qt)"])]
    assert on(c, "wok", recent=True) == []


def test_the_mark_is_the_kitchens_word_and_changes_nothing_of_the_check():
    c = kitchen("wok")
    send(c, "o1", CHICKEN, CHICKEN)
    before = c.get("/orders/o1/check").json()
    lines = c.get("/orders/o1").json()["lines"]
    paper = [job.job_id for job in c.app.state.printing.store.all()]
    boss = manager(c)
    told = c.get("/orders/o1/history", headers=boss).json()
    assert told["steps"]
    mark(c, "o1", "wok", "L0-1", "L0-2", "nothing-of-this-check", at=60)
    assert c.get("/orders/o1/check").json() == before  # not a cent
    assert c.get("/orders/o1/history", headers=boss).json() == told  # nor a step in the check's history
    assert [job.job_id for job in c.app.state.printing.store.all()] == paper  # and nothing prints for it
    after = c.get("/orders/o1").json()["lines"]
    assert set(after) == set(lines)  # a dish the check never had is not made up by a mark
    assert after["L0-1"]["done"] == {"wok": T0 + 60} and lines["L0-1"]["done"] == {}
    assert {**after["L0-1"], "done": {}} == lines["L0-1"]  # the dish is as it was, but for the mark


def test_the_latest_word_of_a_station_on_a_dish_stands_whatever_order_it_arrives_in():
    made = make_op("done", at=70, station="wok", line_ids=["L1"])
    back = make_op("done", at=80, station="wok", line_ids=["L1"], done=False)
    fryer = make_op("done", at=90, station="fryer", line_ids=["L1"])
    base = [
        make_op("create", at=0, table="12"),
        make_op("add_line", at=1, line_id="L1", item="Egg roll"),
        make_op("fire", at=2, course="*"),
    ]
    assert replay([*base, made, back, fryer]).lines["L1"].done == {"fryer": T0 + 90}
    assert replay([*base, fryer, back, made]).lines["L1"].done == {"fryer": T0 + 90}  # replayed in stamp order
    assert replay([*base, made]).lines["L1"].done == {"wok": T0 + 70}
    # a mark that says nothing usable marks nothing
    odd = [make_op("done", at=95, station="", line_ids=["L1"]), make_op("done", at=96)]
    assert replay([*base, *odd]).lines["L1"].done == {}


def test_a_screen_for_two_stations_wants_the_word_of_each():
    c = kitchen("wok", "sushi", "bar")
    send(c, "o1", CHICKEN, ROLL, BEER)
    both = screen(c, "wok", "sushi")
    assert [(line["label"], line["stations"]) for line in both["tickets"][0]["lines"]] == [
        ("左宗鸡 (Qt)", ["wok"]),
        ("加州卷", ["sushi"]),
    ]
    assert both["tickets"][0]["also_at"] == ["Bar"]
    assert [station["code"] for station in both["stations"]] == ["sushi", "wok"]
    mark(c, "o1", "wok", "L0-1", at=60)
    assert on(c, "wok", "sushi") == [("o1", ["(1 左宗鸡 (Qt))", "1 加州卷"])]
    assert [line["made"] for line in screen(c, "wok", "sushi")["tickets"][0]["lines"]] == [["wok"], []]
    mark(c, "o1", "sushi", "L0-2", at=70)
    assert on(c, "wok", "sushi") == [] and on(c, "bar") == [("o1", ["1 Tsingtao"])]


# --- to-go orders -------------------------------------------------------------------------------------------


def test_a_to_go_order_stands_whole_where_it_is_packed():
    c = kitchen("wok", "sushi", "takeout")
    send(c, "o1", CHICKEN, ROLL, **PHONE)
    send(c, "o2", CHICKEN)  # a table's: nothing for the packer
    assert on(c, "takeout") == [("o1", ["1 左宗鸡 (Qt)", "1 加州卷"])]
    packing = screen(c, "takeout")["tickets"][0]
    assert (packing["order_no"], packing["customer"], packing["channel"], packing["to_go"]) == (
        1,
        "Linda",
        "phone",
        True,
    )
    assert packing["also_at"] == ["Wok", "Sushi bar"]  # where the food is coming from
    assert [line["stations"] for line in packing["lines"]] == [["takeout"], ["takeout"]]
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"]), ("o2", ["1 左宗鸡 (Qt)"])]
    # the wok has made its part: the packer's list is its own, and still stands
    mark(c, "o1", "wok", "L0-1", at=60)
    assert on(c, "takeout") == [("o1", ["1 左宗鸡 (Qt)", "1 加州卷"])]
    mark(c, "o1", "takeout", "L0-1", "L0-2", at=70)
    assert on(c, "takeout") == []


def test_a_to_go_order_marked_ready_is_off_every_screen_and_a_closed_one_is_not():
    c = kitchen("wok", "takeout")
    send(c, "o1", CHICKEN, **PHONE)
    send(c, "o2", CHICKEN, order_type="takeout", channel="counter", customer_name="Sam")
    # paid at the counter and closed: the food is still to make
    assert c.post("/orders/o2/ops", json=[{**op("t1", "o2-close", "close", 60), "order_id": "o2"}]).status_code == 202
    assert [order for order, _ in on(c, "wok")] == ["o1", "o2"]
    mark(c, "o2", "wok", "L0-1", at=65)  # and a closed check still takes the kitchen's word
    assert [order for order, _ in on(c, "wok")] == ["o1"] and [order for order, _ in on(c, "takeout")] == ["o1", "o2"]
    mark(c, "o2", "wok", "L0-1", at=66, done=False)
    ready = {**op("t1", "o1-ready", "set_field", 70, stage="ready"), "order_id": "o1"}
    assert c.post("/orders/o1/ops", json=[ready]).status_code == 202
    assert [order for order, _ in on(c, "wok")] == ["o2"] and [order for order, _ in on(c, "takeout")] == ["o2"]
    gone = {**op("t1", "o2-gone", "set_field", 80, stage="picked_up"), "order_id": "o2"}
    assert c.post("/orders/o2/ops", json=[gone]).status_code == 202
    assert on(c, "wok") == []


def test_an_order_sent_ahead_is_on_no_screen_until_its_time():
    clock = [T0 + 100]
    c = hub(clock, log=OpStore(physical=lambda: clock[0]))
    post(
        c,
        op("t1", "o1-open", "create", 0, **CATERING),
        op("t1", "o1-1", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
        op("t1", "o1-fire", "fire", 50, course="*"),
        op("t1", "o1-close", "close", 60),  # paid for on the day it was taken, and the check closed
    )
    assert on(c, "wok") == [] and on(c, "takeout") == []  # sent on Tuesday for Saturday: nobody cooks it yet
    clock[0] = START
    assert on(c, "wok") == []  # until the hub has put its tickets on paper
    assert release(c)
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])] and on(c, "takeout") == [("o1", ["1 左宗鸡 (Qt)"])]
    ticket = screen(c, "wok")["tickets"][0]
    assert ticket["since_ms"] == START - SOON_MS  # in the kitchen since its tickets printed, not since Tuesday
    assert ticket["promised_ms"] == SATURDAY and ticket["channel"] == "catering"


def test_where_nothing_prints_the_clock_alone_says_when_an_order_sent_ahead_is_due():
    clock = [T0 + 100]
    c = clocked(clock)
    post(
        c,
        op("t1", "o1-open", "create", 0, **CATERING),
        op("t1", "o1-1", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
        op("t1", "o1-fire", "fire", 50, course="*"),
    )
    assert on(c, "wok") == []
    clock[0] = START - SOON_MS - 1
    assert on(c, "wok") == []
    clock[0] = START - SOON_MS  # when its ticket would print, if there were a printer
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]
    assert screen(c, "wok")["tickets"][0]["since_ms"] == START - SOON_MS
    clock[0] = START + 30 * MINUTE
    assert screen(c, "wok")["tickets"][0]["id"] == f"o1:{START - SOON_MS}"  # the same ticket, half an hour on


def test_an_order_moved_to_a_later_time_leaves_the_screen_until_then():
    clock = [T0 + 100]
    c = clocked(clock)
    soon = {**PHONE, "promised_at": T0 + 30 * MINUTE, "quoted_minutes": 30}
    post(
        c,
        op("t1", "o1-open", "create", 0, **soon),
        op("t1", "o1-1", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
        op("t1", "o1-fire", "fire", 50, course="*"),
    )
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]
    assert screen(c, "wok")["tickets"][0]["since_ms"] == T0 + 50  # due as soon as it can be: since it was sent
    post(c, op("t1", "o1-later", "set_field", 90, promised_at=T0 + 180 * MINUTE))
    assert on(c, "wok") == []  # she will come at eight instead: not the wok's yet
    clock[0] = T0 + 150 * MINUTE
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]


# --- what takes a dish off a screen ---------------------------------------------------------------------------


def test_a_dish_voided_while_it_is_on_the_screen_stays_struck_until_the_cook_has_seen_it():
    c = TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService([Printer("wok", "10.0.0.1", id="wok")], direct=False),
            settings=servers_void(),
        )
    )
    send(c, "o1", CHICKEN, CHICKEN, CHICKEN)
    mark(c, "o1", "wok", "L0-1", at=60)  # the first was made before anything was voided
    for line, at in (("L0-1", 70), ("L0-2", 71)):
        void = op("t1", f"o1-void-{at}", "void_line", at, line_id=line, reason="kitchen-error", by="Amy", by_id="s1")
        answer = c.post("/orders/o1/ops", json=[{**void, "order_id": "o1"}])
        assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text
    # the made one does not come back; the one still cooking is struck, for the cook to stop
    assert on(c, "wok") == [("o1", ["~1 左宗鸡 (Qt)~", "1 左宗鸡 (Qt)"])]
    mark(c, "o1", "wok", "L0-2", at=80)  # seen
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]
    mark(c, "o1", "wok", "L0-3", at=90)
    assert on(c, "wok") == [] and on(c, "wok", recent=True) == [("o1", ["(1 左宗鸡 (Qt))"])]


def test_a_closed_table_and_a_voided_order_are_off_the_screen():
    c = kitchen("wok")
    send(c, "o1", CHICKEN)
    send(c, "o2", CHICKEN, table="7", order_type="dine_in")
    send(c, "o3", CHICKEN, table="8", order_type="dine_in")
    assert [order for order, _ in on(c, "wok")] == ["o1", "o2", "o3"]
    assert c.post("/orders/o1/ops", json=[{**op("t1", "o1-close", "close", 60), "order_id": "o1"}]).status_code == 202
    assert (
        c.post("/orders/o2/ops", json=[{**op("t1", "o2-void", "void_order", 61), "order_id": "o2"}]).status_code == 202
    )
    assert [order for order, _ in on(c, "wok")] == ["o3"]
    # reopened, a table's dishes nobody marked are the kitchen's again
    assert c.post("/orders/o1/ops", json=[{**op("t1", "o1-again", "reopen", 62), "order_id": "o1"}]).status_code == 202
    assert [order for order, _ in on(c, "wok")] == ["o1", "o3"]


def test_a_ticket_nobody_marks_leaves_by_itself_after_four_hours():
    clock = [T0 + 100]
    c = clocked(clock, "wok")
    send(c, "o1", CHICKEN)
    clock[0] = T0 + KEEP_MS
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]
    clock[0] = T0 + KEEP_MS + MINUTE
    assert on(c, "wok") == []
    # and what it finished is kept only so long too
    assert KEEP_MS == 4 * 60 * MINUTE


def test_only_the_last_few_finished_tickets_are_kept_at_hand_the_latest_first():
    c = kitchen("wok")
    for n in range(1, RECENT + 3):
        send(c, f"o{n}", CHICKEN, table=str(n), order_type="dine_in")
        mark(c, f"o{n}", "wok", "L0-1", at=60 + n)
    recent = [order for order, _ in on(c, "wok", recent=True)]
    assert recent == [f"o{n}" for n in range(RECENT + 2, 2, -1)] and len(recent) == RECENT


def test_a_screen_that_prints_nothing_at_a_station_sends_its_screen_nothing_either():
    c = TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService(
                [Printer(p, f"10.0.0.{n}", id=p) for n, p in enumerate(("wok", "bar"), 1)], direct=False
            ),
            settings=skipping(BAR_SCREEN),
        )
    )
    send(c, "o1", CHICKEN, BEER, device="bar1")  # rung in at the bar's own screen: the bartender makes it
    send(c, "o2", BEER, device="t1", table="7", order_type="dine_in")  # from the floor
    assert on(c, "bar") == [("o2", ["1 Tsingtao"])]
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]
    assert screen(c, "wok")["tickets"][0]["also_at"] == []  # the bar's screen has nothing of it to name


def test_a_dish_that_changes_checks_keeps_what_its_stations_made_of_it():
    c = kitchen("wok")
    send(c, "o1", CHICKEN, CHICKEN)
    mark(c, "o1", "wok", "L0-1", at=60)
    opened = {**op("t1", "o2-open", "create", 61, table="14", order_type="dine_in"), "order_id": "o2"}
    assert c.post("/orders/o2/ops", json=[opened]).status_code == 202
    for n, line in enumerate(("L0-1", "L0-2"), 1):
        came = {"order_id": "o1", "line_id": line}
        # (a terminal cannot say a dish is made by moving it: the hub reads that from the check it leaves)
        take = op(
            "t1", f"o2-take-{n}", "add_line", 70 + n, line_id=f"M{n}", item="?", done={"sushi": 5}, **{"from": came}
        )
        go = op("t1", f"o1-go-{n}", "move_line", 80 + n, line_id=line, to={"order_id": "o2", "line_id": f"M{n}"})
        assert c.post("/orders/o2/ops", json=[{**take, "order_id": "o2"}]).json()["refused"] == []
        assert c.post("/orders/o1/ops", json=[{**go, "order_id": "o1"}]).json()["refused"] == []
    assert c.get("/orders/o2").json()["lines"]["M1"]["done"] == {"wok": T0 + 60}
    assert c.get("/orders/o2").json()["lines"]["M2"]["done"] == {}
    # one ticket, at the table the dishes are at now, with the made one made
    assert on(c, "wok") == [("o2", ["(1 左宗鸡 (Qt))", "1 左宗鸡 (Qt)"])]
    assert screen(c, "wok")["tickets"][0]["table"] == "14"


# --- the pass -----------------------------------------------------------------------------------------------


def passed(c: TestClient, *stations: str) -> dict:
    answer = c.get("/kitchen/pass", params={"stations": ",".join(stations)} if stations else None)
    assert answer.status_code == 200, answer.text
    return answer.json()


def at_pass(c: TestClient, *stations: str, recent: bool = False) -> list[tuple[str, list[str]]]:
    """What the pass lists: each ticket's order and its dishes, each with where it is cooked (a station that
    has made it ticked); a dish that went out in brackets, a void struck."""

    def words(line: dict) -> str:
        cooks = " ".join(cook["name"] + ("✓" if cook["made"] else "") for cook in line["cooks"])
        said = f"{line['qty']} {line['label']} [{cooks}]"
        said = f"~{said}~" if line["void"] else said
        return f"({said})" if line["done"] else said

    listed = passed(c, *stations)["recent" if recent else "tickets"]
    return [(ticket["order_id"], [words(line) for line in ticket["lines"]]) for ticket in listed]


def out(c: TestClient, order_id: str, *lines: str, at: int, done: bool = True) -> None:
    """The pass says these dishes went out (or takes it back)."""
    mark(c, order_id, PASS, *lines, at=at, done=done, device="p1")


def test_the_pass_lists_a_send_whole_with_where_each_dish_is_cooked():
    c = kitchen("wok", "sushi", "bar")
    send(c, "o1", CHICKEN, ROLL, BEER)
    send(c, "o2", CHICKEN, table="7", order_type="dine_in")
    assert at_pass(c) == [
        ("o1", ["1 左宗鸡 (Qt) [Wok]", "1 加州卷 [Sushi bar]", "1 Tsingtao [Bar]"]),
        ("o2", ["1 左宗鸡 (Qt) [Wok]"]),
    ]
    answer = passed(c)
    assert answer["pass"] is True and answer["stations"] == []  # none named: every station
    assert (answer["warn"], answer["late"]) == (10, 20)
    first = answer["tickets"][0]
    assert (first["table"], first["since_ms"], first["also_at"]) == ("12", T0 + 50, [])
    line = first["lines"][0]
    assert (line["line_id"], line["stations"], line["made"], line["done"]) == ("L0-1", [PASS], [], False)
    assert line["cooks"] == [{"code": "wok", "name": "Wok", "made": False}]
    assert "pass" not in screen(c, "wok") and "cooks" not in screen(c, "wok")["tickets"][0]["lines"][0]


def test_what_a_station_made_shows_at_the_pass_and_the_ticket_stays_until_it_goes_out():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, ROLL)
    mark(c, "o1", "wok", "L0-1", at=60)
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok✓]", "1 加州卷 [Sushi bar]"])]
    mark(c, "o1", "sushi", "L0-2", at=61)
    # every station has made its part: it is for the pass to send out
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok✓]", "1 加州卷 [Sushi bar✓]"])]
    assert on(c, "wok") == [] and on(c, "sushi") == []
    out(c, "o1", "L0-1", at=70)
    assert at_pass(c) == [("o1", ["(1 左宗鸡 (Qt) [Wok✓])", "1 加州卷 [Sushi bar✓]"])]
    out(c, "o1", "L0-2", at=75)
    assert at_pass(c) == []
    assert at_pass(c, recent=True) == [("o1", ["(1 左宗鸡 (Qt) [Wok✓])", "(1 加州卷 [Sushi bar✓])"])]
    assert passed(c)["recent"][0]["done_ms"] == T0 + 75
    # brought back at the pass: it did not go out after all
    out(c, "o1", "L0-1", "L0-2", at=80, done=False)
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok✓]", "1 加州卷 [Sushi bar✓]"])] and at_pass(c, recent=True) == []
    assert on(c, "wok") == []  # the wok's own word is as it was


def test_the_word_of_the_pass_changes_nothing_of_the_check():
    c = kitchen("wok")
    send(c, "o1", CHICKEN)
    before = c.get("/orders/o1/check").json()
    line = c.get("/orders/o1").json()["lines"]["L0-1"]
    paper = [job.job_id for job in c.app.state.printing.store.all()]
    boss = manager(c)
    told = c.get("/orders/o1/history", headers=boss).json()
    out(c, "o1", "L0-1", at=60)
    assert c.get("/orders/o1/check").json() == before
    assert c.get("/orders/o1/history", headers=boss).json() == told
    assert [job.job_id for job in c.app.state.printing.store.all()] == paper
    after = c.get("/orders/o1").json()["lines"]["L0-1"]
    assert after["done"] == {PASS: T0 + 60} and {**after, "done": {}} == line


def test_a_dish_that_went_out_is_made_at_its_station_too_unless_the_station_says_otherwise_after():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, CHICKEN, ROLL)
    out(c, "o1", "L0-1", at=60)  # the cook never tapped it, and the plate is gone
    assert on(c, "wok") == [("o1", ["(1 左宗鸡 (Qt))", "1 左宗鸡 (Qt)"])]
    assert screen(c, "wok")["tickets"][0]["lines"][0]["made"] == ["wok"]
    out(c, "o1", "L0-2", "L0-3", at=65)
    assert on(c, "wok") == [] and on(c, "sushi") == []
    finished = screen(c, "wok")["recent"][0]
    assert finished["done_ms"] == T0 + 65
    # the wok brings its ticket back after that: its later word stands
    mark(c, "o1", "wok", "L0-1", "L0-2", at=70, done=False)
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)", "1 左宗鸡 (Qt)"])]
    assert on(c, "sushi") == []
    # the pass takes its own word back: nothing new at the wok, and the roll is still gone
    out(c, "o1", "L0-1", "L0-2", at=71, done=False)
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok]", "1 左宗鸡 (Qt) [Wok]", "(1 加州卷 [Sushi bar])"])]
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)", "1 左宗鸡 (Qt)"])] and on(c, "sushi") == []
    # sent out again, after the wok's word: off the wok's screen again
    out(c, "o1", "L0-1", "L0-2", at=80)
    assert on(c, "wok") == [] and at_pass(c) == []


def test_the_word_of_the_pass_against_a_station_s_whatever_order_they_arrive_in():
    base = [
        make_op("create", at=0, table="12"),
        make_op(
            "add_line",
            at=1,
            line_id="L1",
            item="Wings",
            priced={"kitchen": [{"qty": 1, "label": "Wings", "labels": [], "station": "wok"}]},
        ),
        make_op("fire", at=3, course="*"),
    ]
    gone = make_op("done", at=70, station=PASS, line_ids=["L1"])
    back = make_op("done", at=80, station="wok", line_ids=["L1"], done=False)

    def wok(*ops) -> list[str]:
        listed = kitchen_screen([replay(list(ops))], ["wok"], now_ms=T0 + 100)
        return [ticket["order_id"] for ticket in listed["tickets"]]

    assert wok(*base, gone) == [] and wok(*base) == ["o1"]
    assert wok(*base, gone, back) == ["o1"] and wok(*base, back, gone) == ["o1"]  # replayed in stamp order
    early = make_op("done", at=60, station="wok", line_ids=["L1"], done=False)
    assert wok(*base, early, gone) == []  # the wok took its word back before the dish went out
    # a dish typed with no station is on the pass of every station, with nobody to wait for
    typed = make_op("add_line", at=2, line_id="L2", item="Egg roll")
    whole = kitchen_screen([replay([*base, typed])], [], now_ms=T0 + 100, passing=True)
    assert [(line["label"], line["cooks"]) for line in whole["tickets"][0]["lines"]] == [
        ("Wings", [{"code": "wok", "name": "wok", "made": False}]),
        ("Egg roll", []),
    ]
    assert kitchen_screen([replay([*base, typed])], ["fryer"], now_ms=T0 + 100, passing=True)["tickets"] == []


def test_a_pass_told_its_stations_watches_those_alone():
    c = kitchen("wok", "sushi", "bar")
    send(c, "o1", CHICKEN, ROLL, BEER)
    send(c, "o2", BEER, table="7", order_type="dine_in")  # drinks alone: nothing for the kitchen's pass
    assert at_pass(c, "wok", "sushi") == [("o1", ["1 左宗鸡 (Qt) [Wok]", "1 加州卷 [Sushi bar]"])]
    answer = passed(c, "wok", "sushi")
    assert answer["stations"] == [{"code": "sushi", "name": "Sushi bar"}, {"code": "wok", "name": "Wok"}]
    assert answer["tickets"][0]["also_at"] == ["Bar"]
    assert [order for order, _ in at_pass(c)] == ["o1", "o2"]


def test_a_to_go_order_is_on_the_pass_once_and_the_packer_s_list_is_the_packer_s():
    c = kitchen("wok", "sushi", "takeout")
    send(c, "o1", CHICKEN, ROLL, **PHONE)
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok]", "1 加州卷 [Sushi bar]"])]
    ticket = passed(c)["tickets"][0]
    assert (ticket["order_no"], ticket["customer"], ticket["to_go"]) == (1, "Linda", True)
    mark(c, "o1", "takeout", "L0-1", "L0-2", at=60)  # bagged: not the cooks' word
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok]", "1 加州卷 [Sushi bar]"])]
    out(c, "o1", "L0-1", "L0-2", at=70)
    assert at_pass(c) == [] and on(c, "wok") == []
    # marked Ready: off the last ones too, like every screen
    ready = {**op("t1", "o1-ready", "set_field", 80, stage="ready"), "order_id": "o1"}
    assert c.post("/orders/o1/ops", json=[ready]).status_code == 202
    assert at_pass(c, recent=True) == []


def test_the_pass_follows_the_paper_like_a_station_s_screen():
    c = TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService(
                [Printer(p, f"10.0.0.{n}", id=p) for n, p in enumerate(("wok", "bar"), 1)], direct=False
            ),
            settings=skipping(BAR_SCREEN),
        )
    )
    send(c, "o1", CHICKEN, BEER, device="bar1")  # the bartender makes the beer and prints no ticket for it
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok]"])]
    # a closed table is off the pass, like every screen
    assert c.post("/orders/o1/ops", json=[{**op("t1", "o1-close", "close", 80), "order_id": "o1"}]).status_code == 202
    assert at_pass(c) == []


def test_a_voided_dish_stays_struck_at_the_pass_until_the_pass_has_seen_it():
    c = TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService([Printer("wok", "10.0.0.1", id="wok")], direct=False),
            settings=servers_void(),
        )
    )
    send(c, "o1", CHICKEN, CHICKEN)
    void = op("t1", "o1-void", "void_line", 60, line_id="L0-1", reason="kitchen-error", by="Amy", by_id="s1")
    assert c.post("/orders/o1/ops", json=[{**void, "order_id": "o1"}]).json()["refused"] == []
    assert at_pass(c) == [("o1", ["~1 左宗鸡 (Qt) [Wok]~", "1 左宗鸡 (Qt) [Wok]"])]
    mark(c, "o1", "wok", "L0-1", at=65)  # the cook has seen it: off the wok's screen, and still for the pass to see
    assert on(c, "wok") == [("o1", ["1 左宗鸡 (Qt)"])]
    assert at_pass(c) == [("o1", ["~1 左宗鸡 (Qt) [Wok✓]~", "1 左宗鸡 (Qt) [Wok]"])]
    out(c, "o1", "L0-1", at=70)
    assert at_pass(c) == [("o1", ["1 左宗鸡 (Qt) [Wok]"])]


def test_the_pass_is_asked_for_like_a_screen():
    c = kitchen("wok")
    send(c, "o1", CHICKEN)
    for bad in ("wok,not a code", ",".join(f"s{n}" for n in range(33))):
        assert c.get("/kitchen/pass", params={"stations": bad}).status_code == 422, bad
    assert [order for order, _ in at_pass(c, *(f"s{n}" for n in range(31)), "wok")] == ["o1"]  # more than a screen's
    first = c.get("/kitchen/pass")
    again = c.get("/kitchen/pass", headers={"If-None-Match": first.headers["etag"]})
    assert again.status_code == 304
    mark(c, "o1", "wok", "L0-1", at=60)  # what a station made is news at the pass
    assert c.get("/kitchen/pass", headers={"If-None-Match": first.headers["etag"]}).status_code == 200


# --- the calls ----------------------------------------------------------------------------------------------


def test_the_stations_are_named_by_their_codes():
    c = kitchen("wok")
    for bad in ("", " , ", "wok,not a code", ",".join(f"s{n}" for n in range(9))):
        assert c.get("/kitchen/screen", params={"stations": bad}).status_code == 422, bad
    assert c.get("/kitchen/screen").status_code == 422
    assert screen(c, " wok ", "wok")["stations"] == [{"code": "wok", "name": "Wok"}]
    # a station the menu does not know has an empty screen under its own code
    assert screen(c, "pizza") == {**screen(c, "pizza"), "stations": [{"code": "pizza", "name": "pizza"}], "tickets": []}


def test_a_screen_that_asks_again_gets_nothing_new_when_nothing_changed():
    c = kitchen("wok")
    send(c, "o1", CHICKEN)
    first = c.get("/kitchen/screen", params={"stations": "wok"})
    again = c.get("/kitchen/screen", params={"stations": "wok"}, headers={"If-None-Match": first.headers["etag"]})
    assert again.status_code == 304
    mark(c, "o1", "wok", "L0-1", at=60)
    assert (
        c.get(
            "/kitchen/screen", params={"stations": "wok"}, headers={"If-None-Match": first.headers["etag"]}
        ).status_code
        == 200
    )


def test_a_manager_sets_when_a_ticket_turns_amber_and_red():
    c = kitchen("wok")
    assert c.get("/settings/kitchen_screens").json() == {"warn": 10, "late": 20} == DEFAULTS["kitchen_screens"]
    assert (screen(c, "wok")["warn"], screen(c, "wok")["late"]) == (10, 20)
    assert c.put("/settings/kitchen_screens", json={"warn": 5}).status_code == 401
    boss = manager(c)
    assert c.put("/settings/kitchen_screens", json={"warn": 5}, headers=boss).json() == {"warn": 5, "late": 20}
    assert c.put("/settings/kitchen_screens", json={"late": 12}, headers=boss).json() == {"warn": 5, "late": 12}
    assert (screen(c, "wok")["warn"], screen(c, "wok")["late"]) == (5, 12)
    # red comes after amber; either can be turned off
    refused = c.put("/settings/kitchen_screens", json={"warn": 12}, headers=boss)
    assert refused.status_code == 422 and refused.json()["detail"]["message"] == "red must come after amber"
    assert c.put("/settings/kitchen_screens", json={"warn": 30, "late": 0}, headers=boss).json() == {
        "warn": 30,
        "late": 0,
    }
    assert c.put("/settings/kitchen_screens", json={"warn": -1}, headers=boss).status_code == 422
    assert c.get("/settings/kitchen_screens").json() == {"warn": 30, "late": 0}


def test_the_screen_is_worked_out_from_the_orders_alone():
    """`kitchen_screen` with nothing wired in: no names, no skips, nothing waiting."""
    ops = [
        make_op("create", at=0, table="3"),
        make_op("add_line", at=1, line_id="L1", item="Egg roll"),  # typed, with no station
        make_op(
            "add_line",
            at=2,
            line_id="L2",
            item="Wings",
            priced={"kitchen": [{"qty": 2, "label": "Wings", "labels": ["Hot"], "depths": [0], "station": "fryer"}]},
        ),
        make_op("fire", at=3, course="*"),
    ]
    made = kitchen_screen([replay(ops)], ["fryer"], now_ms=T0 + 100)
    assert [(line["qty"], line["label"], line["modifiers"]) for line in made["tickets"][0]["lines"]] == [
        (2, "Wings", ["Hot"])
    ]
    assert made["stations"] == [{"code": "fryer", "name": "fryer"}] and (made["warn"], made["late"]) == (10, 20)
    assert kitchen_screen([replay(ops)], ["wok"], now_ms=T0 + 100)["tickets"] == []
    assert HLC(T0 + 3, 0, "a") == replay(ops).lines["L2"].fired_at


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run")
def test_the_marks_are_kept_in_postgres():
    import psycopg

    from pos.sync.pgstore import PgOpStore

    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS op, order_index, order_number, held_ticket CASCADE")
    store = PgOpStore(DSN, physical=lambda: T0 + 100)
    try:
        c = TestClient(
            create_app(
                store,
                menu=menu_with_takeout(),
                printing=PrintService([Printer("wok", "10.0.0.1", id="wok")], direct=False),
                settings=SettingStore(),
            )
        )
        send(c, "o1", CHICKEN, CHICKEN)
        mark(c, "o1", "wok", "L0-1", at=60)
        assert on(c, "wok") == [("o1", ["(1 左宗鸡 (Qt))", "1 左宗鸡 (Qt)"])]
        mark(c, "o1", "wok", "L0-2", at=70)
        assert on(c, "wok") == [] and on(c, "wok", recent=True) == [("o1", ["(1 左宗鸡 (Qt))", "(1 左宗鸡 (Qt))"])]
    finally:
        store.close()
