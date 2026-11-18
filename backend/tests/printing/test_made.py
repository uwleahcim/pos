"""What the floor hears of the kitchen: a dish every one of its stations marked made is ready, on its check
and on the floor map, until the pass (or the server who carried it) says it went out. A kitchen that marks
nothing changes nothing on the floor's screens, and a mark changes nothing of the check."""

from __future__ import annotations

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.made import kitchen_word, kitchen_words, ready_of, with_kitchen
from pos.printing.screen import PASS
from pos.printing.service import Printer, PrintService
from pos.sync.oplog import OpStore, replay

from ..conftest import T0, make_op, servers_void
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen
from .test_screen import mark, out, send
from .test_stations import manager, menu_with_takeout
from .test_ticket_skips import BAR_SCREEN, op, skipping

WOK = {"code": "wok", "name": "Wok"}
SUSHI = {"code": "sushi", "name": "Sushi bar"}


def words(c: TestClient, order_id: str = "o1") -> dict[str, dict]:
    """The kitchen's word on each dish of an order that has one, as the order is read."""
    lines = c.get(f"/orders/{order_id}").json()["lines"]
    return {line_id: line["kitchen"] for line_id, line in lines.items() if "kitchen" in line}


def floor(c: TestClient, table: str = "12") -> list[dict]:
    """What the floor map is told of a table's checks: how many dishes are ready and since when."""
    checks = c.get("/floor").json()["status"].get(table, [])
    return [{k: check[k] for k in ("ready", "ready_ms") if k in check} for check in checks]


# --- on the check -------------------------------------------------------------------------------------------


def test_a_kitchen_that_marks_nothing_changes_nothing_on_the_floors_screens():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, ROLL)
    assert words(c) == {}
    assert all("kitchen" not in line for line in c.get("/orders/o1").json()["lines"].values())
    assert floor(c) == [{}]  # the check is there, with nothing of the kitchen on it


def test_a_dish_its_station_made_is_ready_on_its_check():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, CHICKEN, ROLL)
    mark(c, "o1", "wok", "L0-1", at=60)
    assert words(c) == {"L0-1": {"cooks": [{**WOK, "made": True}], "ready_ms": T0 + 60}}
    mark(c, "o1", "sushi", "L0-3", at=75)
    assert words(c)["L0-3"] == {"cooks": [{**SUSHI, "made": True}], "ready_ms": T0 + 75}
    assert "L0-2" not in words(c)  # the wok still has the other one
    # not made after all: the dish says nothing again
    mark(c, "o1", "wok", "L0-1", at=80, done=False)
    assert set(words(c)) == {"L0-3"}


def test_a_dish_that_went_out_says_when():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, ROLL)
    mark(c, "o1", "wok", "L0-1", at=60)
    out(c, "o1", "L0-1", at=70)
    assert words(c)["L0-1"] == {"cooks": [{**WOK, "made": True}], "ready_ms": T0 + 60, "out_ms": T0 + 70}
    # one the pass sent out with its station silent: it went out, so it was made
    out(c, "o1", "L0-2", at=72)
    assert words(c)["L0-2"] == {"cooks": [{**SUSHI, "made": True}], "ready_ms": T0 + 72, "out_ms": T0 + 72}
    # brought back at the pass: the wok's own word is as it was
    out(c, "o1", "L0-1", "L0-2", at=80, done=False)
    assert words(c) == {"L0-1": {"cooks": [{**WOK, "made": True}], "ready_ms": T0 + 60}}


def test_a_dish_of_two_stations_is_ready_when_both_have_made_it():
    base = [
        make_op("create", at=0, table="12"),
        make_op(
            "add_line",
            at=1,
            line_id="L1",
            item="Surf and turf",
            priced={
                "kitchen": [
                    {"qty": 1, "label": "Steak", "labels": [], "station": "wok"},
                    {"qty": 1, "label": "Sashimi", "labels": [], "station": "sushi"},
                ]
            },
        ),
        make_op("fire", at=3, course="*"),
    ]
    names = {"wok": "Wok", "sushi": "Sushi bar"}

    def word(*ops, **how) -> dict | None:
        return kitchen_word(replay([*base, *ops]).lines["L1"], station_names=names, **how)

    wok = make_op("done", at=60, station="wok", line_ids=["L1"])
    sushi = make_op("done", at=90, station="sushi", line_ids=["L1"])
    assert word() is None
    # the wok's part is made and the sushi bar still works on its own: not ready, and it says who it waits on
    assert word(wok) == {"cooks": [{**SUSHI, "made": False}, {**WOK, "made": True}]}
    assert word(wok, sushi) == {"cooks": [{**SUSHI, "made": True}, {**WOK, "made": True}], "ready_ms": T0 + 90}
    assert word(sushi, wok)["ready_ms"] == T0 + 90  # when the last of them did, whatever order they arrive in
    # a station the sending screen prints nothing at never hears of the dish: nobody waits for its word
    assert word(wok, skip={"sushi"}) == {"cooks": [{**WOK, "made": True}], "ready_ms": T0 + 60}
    # a station that does not cook the dish can say what it likes
    fryer = make_op("done", at=70, station="fryer", line_ids=["L1"])
    assert word(fryer) is None
    # the wok took its word back after the dish went out: its later word stands
    gone = make_op("done", at=95, station=PASS, line_ids=["L1"])
    back = make_op("done", at=99, station="wok", line_ids=["L1"], done=False)
    assert word(wok, sushi, gone, back) == {
        "cooks": [{**SUSHI, "made": True}, {**WOK, "made": False}],
        "out_ms": T0 + 95,
    }


def test_a_dish_with_no_station_is_never_ready_and_can_still_go_out():
    typed = [
        make_op("create", at=0, table="12"),
        make_op("add_line", at=1, line_id="L1", item="Egg roll"),
        make_op("fire", at=3, course="*"),
    ]
    assert kitchen_word(replay(typed).lines["L1"]) is None
    gone = make_op("done", at=70, station=PASS, line_ids=["L1"])
    assert kitchen_word(replay([*typed, gone]).lines["L1"]) == {"cooks": [], "out_ms": T0 + 70}
    assert ready_of(replay([*typed, gone])) == {}


def test_only_a_sent_dish_that_is_still_on_the_check_has_a_word():
    c = TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService([Printer("wok", "10.0.0.1", id="wok")], direct=False),
            settings=servers_void(),
        )
    )
    send(c, "o1", CHICKEN, CHICKEN)
    mark(c, "o1", "wok", "L0-1", "L0-2", at=60)
    assert set(words(c)) == {"L0-1", "L0-2"} and floor(c) == [{"ready": 2, "ready_ms": T0 + 60}]
    gone = op("t1", "o1-void", "void_line", 70, line_id="L0-1", reason="kitchen-error", by="Amy", by_id="s1")
    assert c.post("/orders/o1/ops", json=[gone]).json()["refused"] == []
    assert set(words(c)) == {"L0-2"}  # a void says it is a void, and nothing is carried out for it
    assert floor(c) == [{"ready": 1, "ready_ms": T0 + 60}]
    # a mark that names a dish nobody sent marks nothing a server would carry
    rung = op("t1", "o1-late", "add_line", 80, line_id="L9", item="?", request=CHICKEN)
    assert c.post("/orders/o1/ops", json=[rung]).status_code == 202
    mark(c, "o1", "wok", "L9", at=85)
    assert set(words(c)) == {"L0-2"} and floor(c) == [{"ready": 1, "ready_ms": T0 + 60}]


def test_the_word_changes_nothing_of_the_check_and_the_server_can_say_it_went_out():
    c = kitchen("wok")
    send(c, "o1", CHICKEN, CHICKEN)
    before = c.get("/orders/o1/check").json()
    lines = c.get("/orders/o1").json()["lines"]
    paper = [job.job_id for job in c.app.state.printing.store.all()]
    boss = manager(c)
    told = c.get("/orders/o1/history", headers=boss).json()
    mark(c, "o1", "wok", "L0-1", at=60)
    # the server who carried it says so from the check, with the pass's own word: any screen may
    carried = op("t1", "o1-carried", "done", 70, station=PASS, line_ids=["L0-1"], by="Amy", by_id="s1")
    assert c.post("/orders/o1/ops", json=[carried]).json()["refused"] == []
    assert words(c)["L0-1"]["out_ms"] == T0 + 70
    assert c.get("/orders/o1/check").json() == before  # not a cent
    assert c.get("/orders/o1/history", headers=boss).json() == told  # nor a step in the check's history
    assert [job.job_id for job in c.app.state.printing.store.all()] == paper  # and nothing prints for it
    after = c.get("/orders/o1").json()["lines"]
    assert after["L0-2"] == lines["L0-2"]  # a dish nobody marked reads as it always did
    plain = {k: v for k, v in after["L0-1"].items() if k != "kitchen"}
    assert {**plain, "done": {}} == lines["L0-1"]  # and a marked one is as it was, but for the marks


def test_the_order_as_it_is_kept_does_not_carry_the_word():
    state = replay(
        [
            make_op("create", at=0, table="12"),
            make_op(
                "add_line",
                at=1,
                line_id="L1",
                item="Wings",
                priced={"kitchen": [{"qty": 1, "label": "Wings", "labels": [], "station": "wok"}]},
            ),
            make_op("add_line", at=2, line_id="L2", item="Egg roll"),
            make_op("fire", at=3, course="*"),
            make_op("done", at=60, station="wok", line_ids=["L1"]),
        ]
    )
    kept = state.snapshot()
    read = with_kitchen(kept, kitchen_words(state))
    assert "kitchen" not in kept["lines"]["L1"]  # what the hubs compare between them is the log's own
    assert read["lines"]["L1"]["kitchen"] == {
        "cooks": [{"code": "wok", "name": "wok", "made": True}],
        "ready_ms": T0 + 60,
    }
    assert read["lines"]["L2"] is kept["lines"]["L2"]
    assert with_kitchen(kept, {}) is kept


# --- on the floor map ---------------------------------------------------------------------------------------


def test_the_floor_counts_the_dishes_ready_at_each_check_until_they_go_out():
    c = kitchen("wok", "sushi")
    send(c, "o1", CHICKEN, CHICKEN, ROLL)
    send(c, "o2", CHICKEN, table="7", order_type="dine_in")
    mark(c, "o1", "wok", "L0-1", at=60)
    assert floor(c) == [{"ready": 1, "ready_ms": T0 + 60}] and floor(c, "7") == [{}]
    mark(c, "o1", "sushi", "L0-3", at=75)
    assert floor(c) == [{"ready": 2, "ready_ms": T0 + 75}]  # since the last of them was made
    out(c, "o1", "L0-3", at=80)
    assert floor(c) == [{"ready": 1, "ready_ms": T0 + 60}]
    out(c, "o1", "L0-1", at=85)
    assert floor(c) == [{}]
    # it did not go out after all: back on the map
    out(c, "o1", "L0-1", at=90, done=False)
    assert floor(c) == [{"ready": 1, "ready_ms": T0 + 60}]


def test_two_of_a_dish_count_as_two():
    c = kitchen("wok")
    send(c, "o1", CHICKEN)
    more = op("t1", "o1-more", "set_line", 55, line_id="L0-1", qty=2)
    assert c.post("/orders/o1/ops", json=[more]).json()["refused"] == []
    mark(c, "o1", "wok", "L0-1", at=60)
    assert floor(c) == [{"ready": 2, "ready_ms": T0 + 60}]


def test_a_drink_rung_at_the_bars_own_screen_waits_for_nobody():
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
    send(c, "o1", CHICKEN, BEER, device="bar1")  # rung in at the bar's own screen: the bartender pours it
    send(c, "o2", BEER, device="t1", table="7", order_type="dine_in")  # from the floor
    mark(c, "o1", "bar", "L0-2", at=60)  # (a screen of the bar would not list it: a stray word)
    mark(c, "o2", "bar", "L0-1", at=61)
    assert words(c) == {} and floor(c) == [{}]  # the bar's screen never had it: nothing to be ready
    assert words(c, "o2") == {"L0-1": {"cooks": [{"code": "bar", "name": "Bar", "made": True}], "ready_ms": T0 + 61}}
    assert floor(c, "7") == [{"ready": 1, "ready_ms": T0 + 61}]


def test_the_floor_answers_the_same_until_the_kitchen_says_something():
    c = kitchen("wok")
    send(c, "o1", CHICKEN)
    first = c.get("/floor")
    assert c.get("/floor", headers={"if-none-match": first.headers["etag"]}).status_code == 304
    mark(c, "o1", "wok", "L0-1", at=60)
    again = c.get("/floor", headers={"if-none-match": first.headers["etag"]})
    assert again.status_code == 200 and again.json()["status"]["12"][0]["ready"] == 1
    # the clock going by changes nothing in it: how long the map shows the mark is the map's to say
    assert c.get("/floor", headers={"if-none-match": again.headers["etag"]}).status_code == 304
    order = c.get("/orders/o1")
    assert c.get("/orders/o1", headers={"if-none-match": order.headers["etag"]}).status_code == 304
