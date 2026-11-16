"""The kitchen and a dish that changes checks or tables (the Toast comparison's row 3): nothing is voided and
nothing is sent twice, and a station that is still cooking for a table that moved gets a MOVED slip with the
table on its ticket and the table the food goes to now."""

from __future__ import annotations

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.service import MOVED_SLIP_MS, Printer, PrintService, kitchen_changes, table_changes
from pos.printing.ticket import DEMO, render
from pos.settings import SettingStore
from pos.sync.oplog import OpStore, replay

from ..conftest import T0, make_op
from ..orders.test_menu_orders import payload
from .fake_printer import decode
from .test_other_stations import CHICKEN, ROLL
from .test_stations import manager, menu_with_takeout


def kitchen(*stations: str, now: int = T0 + 1000, settings: SettingStore | None = None) -> TestClient:
    """A hub with a printer for each of these stations, whose print service reads the clock at `now`."""
    printers = [Printer(code, f"10.0.0.{n}", id=code) for n, code in enumerate(stations, 1)]
    service = PrintService(printers, direct=False, now=lambda: now)
    hub = create_app(
        OpStore(physical=lambda: now), menu=menu_with_takeout(), printing=service, settings=settings or SettingStore()
    )
    return TestClient(hub)


def post(c: TestClient, order_id: str, *ops: dict) -> dict:
    answer = c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops])
    assert answer.status_code == 202, answer.text
    assert answer.json()["refused"] == []
    return answer.json()


def seated(c: TestClient, order_id: str, table: str, *dishes: dict, fire: bool = True) -> None:
    """A check at `table` with these dishes (L1, L2, ...), sent unless `fire` is false."""
    ops = [payload(f"{order_id}-open", "create", 0, table=table, order_type="dine_in", guests=2)]
    ops += [
        payload(f"{order_id}-{n}", "add_line", n, line_id=f"L{n}", item="?", request=dish)
        for n, dish in enumerate(dishes, 1)
    ]
    if fire:
        ops.append(payload(f"{order_id}-fire", "fire", 50, course="*"))
    post(c, order_id, *ops)


def slip(c: TestClient, job_id: str) -> list[str]:
    job = c.app.state.printing.store.get(job_id)
    assert job is not None, f"no slip {job_id}"
    return [line.strip() for line in decode(job.data).text if line.strip()]


def dishes(c: TestClient, job_id: str) -> int:
    """How many dishes a ticket lists: each is drawn, since its name may be in Chinese."""
    return len(decode(c.app.state.printing.store.get(job_id).data).images)


def test_a_table_that_moves_with_food_on_its_way_prints_a_slip_at_each_station_cooking_for_it():
    c = kitchen("wok", "sushi", "bar")
    seated(c, "o1", "12", CHICKEN, ROLL)
    answer = post(c, "o1", payload("mv", "set_field", 100, table="14"))
    assert answer["print_jobs"] == ["mv:moved:12:wok", "mv:moved:12:sushi"]  # the bar has nothing of it
    wok = slip(c, "mv:moved:12:wok")
    assert wok[0] == "*** MOVED *** WOK"
    assert wok.index("Table 14  2 guests") < wok.index("WAS TABLE 12") < wok.index("NOW TABLE 14")
    assert wok[wok.index("NOW TABLE 14") + 1] == "These dishes go to the new table:"
    assert dishes(c, "mv:moved:12:wok") == 1  # its own dish, not the sushi bar's
    assert "NOW TABLE 14" in decode(c.app.state.printing.store.get("mv:moved:12:wok").data).inverted
    assert dishes(c, "mv:moved:12:sushi") == 1


def test_nothing_prints_for_a_table_that_moves_with_nothing_on_its_way():
    c = kitchen("wok")
    seated(c, "o1", "12", CHICKEN, fire=False)  # nothing sent yet: its ticket will name the new table
    assert post(c, "o1", payload("mv", "set_field", 100, table="14"))["print_jobs"] == []
    # sent long ago: the food is on the table it was sent for
    late = kitchen("wok", now=T0 + 50 + MOVED_SLIP_MS + 1)
    seated(late, "o1", "12", CHICKEN)
    assert post(late, "o1", payload("mv", "set_field", 100, table="14"))["print_jobs"] == []
    # the same table again, another server, more guests: no slip
    same = kitchen("wok")
    seated(same, "o1", "12", CHICKEN)
    assert post(same, "o1", payload("s", "set_field", 100, table="12", server="Ben", guests=4))["print_jobs"] == []


def test_a_manager_can_turn_the_slip_off():
    c = kitchen("wok")
    saved = c.put("/settings/tickets", json={"moved": False}, headers=manager(c)).json()
    assert saved == {"numbered": True, "also_at": True, "paid": True, "moved": False}
    seated(c, "o1", "12", CHICKEN)
    assert post(c, "o1", payload("mv", "set_field", 100, table="14"))["print_jobs"] == []


def test_dishes_that_join_a_check_at_another_table_print_no_void_no_second_send_and_one_slip():
    c = kitchen("wok", "sushi")
    seated(c, "o1", "12", CHICKEN, ROLL)
    seated(c, "o2", "14", CHICKEN)
    # the roll goes over to table 14's check
    took = post(
        c, "o2", payload("t1", "add_line", 100, line_id="M1", item="?", **{"from": {"order_id": "o1", "line_id": "L2"}})
    )
    assert took["print_jobs"] == ["t1:moved:12:sushi"]
    paper = slip(c, "t1:moved:12:sushi")
    assert paper[0] == "*** MOVED *** SUSHI BAR" and "WAS TABLE 12" in paper and "NOW TABLE 14" in paper
    assert dishes(c, "t1:moved:12:sushi") == 1
    gave = post(c, "o1", payload("m1", "move_line", 101, line_id="L2", to={"order_id": "o2", "line_id": "M1"}))
    assert gave["print_jobs"] == []  # no VOID ticket for a dish that is still to be cooked and paid for
    # a later fire on the new check sends only what was not sent
    post(
        c,
        "o2",
        payload("n", "add_line", 110, line_id="N1", item="?", request=CHICKEN),
        payload("f", "fire", 111, course="*"),
    )
    assert not c.app.state.printing.store.get("f:sushi")
    assert slip(c, "f:wok")[0] == "WOK" and dishes(c, "f:wok") == 1


def test_dishes_that_change_checks_at_the_same_table_or_unsent_print_nothing():
    c = kitchen("wok", "sushi")
    seated(c, "o1", "12", CHICKEN, ROLL)
    seated(c, "o2", "12", CHICKEN)  # a second check at the same table
    took = post(
        c, "o2", payload("t1", "add_line", 100, line_id="M1", item="?", **{"from": {"order_id": "o1", "line_id": "L2"}})
    )
    assert took["print_jobs"] == []
    unsent = kitchen("wok")
    seated(unsent, "o1", "12", CHICKEN, fire=False)
    seated(unsent, "o2", "14", CHICKEN)
    took = post(
        unsent,
        "o2",
        payload("t1", "add_line", 100, line_id="M1", item="?", **{"from": {"order_id": "o1", "line_id": "L1"}}),
    )
    assert took["print_jobs"] == []


def test_what_the_kitchen_hears_between_two_replays_leaves_moves_out():
    went = [make_op("add_line", at=1, line_id="L1", item="Tea"), make_op("fire", at=2, course="*")]
    move = make_op("move_line", at=3, line_id="L1", to={"order_id": "o2", "line_id": "M1"})
    assert kitchen_changes(replay(went), replay([*went, move])) == ([], [])
    came = make_op(
        "add_line", "o2", 4, line_id="M1", item="Tea", **{"from": {"order_id": "o1", "line_id": "L1"}}, sent="1-0-a"
    )
    before = replay([make_op("create", "o2", 0, table="14")], "o2")
    assert kitchen_changes(before, replay([make_op("create", "o2", 0, table="14"), came], "o2")) == ([], [])


def test_which_dishes_changed_table_and_from_where():
    opened = [make_op("create", at=0, table="12"), make_op("add_line", at=1, line_id="L1", item="Tea")]
    sent = [*opened, make_op("fire", at=2, course="*")]
    moved = make_op("set_field", at=3, table="14")
    changes = table_changes(replay(sent), replay([*sent, moved]), T0 + 10)
    assert [(was, [line.line_id for line in lines]) for was, lines in changes] == [("12", ["L1"])]
    assert table_changes(replay(opened), replay([*opened, moved]), T0 + 10) == []  # not sent
    assert table_changes(replay(sent), replay([*sent, moved]), T0 + 2 + MOVED_SLIP_MS + 1) == []  # long ago
    closed = make_op("close", at=4)
    assert table_changes(replay(sent), replay([*sent, moved, closed]), T0 + 10) == []
    assert table_changes(replay([]), replay(sent), T0 + 10) == []  # a new check has changed nothing


def test_the_slip_reads_the_same_on_both_kinds_of_printer():
    from dataclasses import replace

    ticket = replace(DEMO, kind="moved", was_at="12", table="B4")
    words = [line.strip() for line in decode(render(ticket)).text]
    assert words[0] == "*** MOVED *** WOK" and "WAS TABLE 12" in words and "NOW TABLE B4" in words
    assert render(ticket, dialect="star")  # drawn without complaint
