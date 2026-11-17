"""An order sent ahead of its time (tonight at seven, Saturday's catering) prints nothing when it is sent. The
hub keeps which dishes wait, where a restart cannot lose it, and makes the ticket when the time comes, from
the order as it stands then: what was added is on it, what was taken off is not, and nothing about a dish
that never reached paper is printed in between."""

from __future__ import annotations

import os
from dataclasses import replace
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.held import Held, HeldTickets, Part
from pos.printing.jobs import PrintJob
from pos.printing.service import Printer, PrintService
from pos.printing.ticket import DEMO, render
from pos.settings import SettingStore, clean_ticket_skips
from pos.sync.hlc import HLC
from pos.sync.oplog import Op, OpStore

from ..conftest import T0, servers_void
from ..orders.test_menu_orders import payload
from .fake_printer import Decoded, decode
from .test_other_stations import BEER, CHICKEN, ROLL, send
from .test_stations import menu_with_takeout

DSN = os.environ.get("POS_TEST_DATABASE_URL")
MINUTE = 60_000
HOUR = 60 * MINUTE
DAY = 24 * HOUR
SATURDAY = T0 + 4 * DAY  # when the order is for, four days after it is taken
START = SATURDAY - HOUR  # quoted an hour: its tickets print an hour ahead
CATERING = {
    "order_type": "takeout",
    "channel": "catering",
    "customer_name": "Linda",
    "promised_at": SATURDAY,
    "quoted_minutes": 60,
    "for_later": True,
}
STATIONS = ("wok", "sushi", "bar", "takeout")


def hub(
    clock: list[int],
    *,
    log: OpStore | None = None,
    held: HeldTickets | None = None,
    settings: SettingStore | None = None,
) -> TestClient:
    """A hub with a printer at each station whose clock the test holds. Given the log and what waits of
    another, it is that hub started again: a new process with nothing of the old one's memory."""
    printers = [Printer(p, f"10.0.0.{n}", id=p) for n, p in enumerate(STATIONS, 1)]
    service = PrintService(printers, direct=False, now=lambda: clock[0], held=held)
    return TestClient(
        create_app(
            log if log is not None else OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=service,
            settings=settings or SettingStore(),
        )
    )


def post(c: TestClient, *ops: dict, order_id: str = "o1") -> dict:
    sent = c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops])
    assert sent.status_code == 202 and sent.json()["refused"] == []
    return sent.json()


def release(c: TestClient) -> list[str]:
    """The hub's look at what is due, as its loop takes it every few seconds: the jobs it made."""
    made: list[PrintJob] = c.app.state.printing.release_due()
    return [job.job_id for job in made]


def printed(c: TestClient) -> list[str]:
    return [job.job_id for job in c.app.state.printing.store.all()]


def waiting(c: TestClient) -> list[tuple[str, int, int]]:
    return [(h["order_id"], h["starts_ms"], h["lines"]) for h in c.get("/print/jobs").json()["held"]]


def ticket(c: TestClient, key: str, printer: str) -> Decoded | None:
    job = c.app.state.printing.store.get(f"{key}:{printer}")
    return None if job is None else decode(job.data)


def dishes(c: TestClient, key: str, printer: str) -> int | None:
    """How many dishes the printer's ticket lists: the ones drawn as a picture (the chicken, the roll, which
    the kitchen reads in Chinese) and the ones in letters (the beer). None when it got no ticket."""
    paper = ticket(c, key, printer)
    return None if paper is None else len(paper.images) + sum(" x " in line for line in paper.text)


def test_an_order_sent_ahead_is_not_on_paper_until_its_time():
    clock = [T0 + 100]
    c = hub(clock)
    sent = c.post("/orders/o1/ops", json=[payload("open", "create", 0, **CATERING)])
    assert sent.status_code == 202
    key = send(c, "o1", CHICKEN, ROLL, at=10)
    assert printed(c) == [] and waiting(c) == [("o1", START, 2)]
    for early in (T0 + DAY, START - 2 * MINUTE):
        clock[0] = early
        assert release(c) == []
    clock[0] = START - MINUTE + 1  # within a minute of its time: cook it
    assert release(c) == [f"{key}:wok", f"{key}:sushi", f"{key}:takeout"]
    assert (dishes(c, key, "wok"), dishes(c, key, "sushi"), dishes(c, key, "takeout")) == (1, 1, 2)
    assert waiting(c) == [] and release(c) == []  # once


def test_what_waits_outlives_the_hub():
    clock = [T0 + 100]
    log, held = OpStore(physical=lambda: T0 + 100), HeldTickets()
    c = hub(clock, log=log, held=held)
    key = send(c, "o1", CHICKEN, ROLL, **CATERING)
    assert printed(c) == []
    # the hub is updated on Thursday: what waits is in its database, and nothing else was ever made
    again = hub(clock, log=log, held=held)
    assert waiting(again) == [("o1", START, 2)] and printed(again) == []
    clock[0] = START
    assert release(again) == [f"{key}:wok", f"{key}:sushi", f"{key}:takeout"]


def test_a_hub_that_was_off_at_the_time_prints_as_soon_as_it_is_back():
    clock = [T0 + 100]
    log, held = OpStore(physical=lambda: T0 + 100), HeldTickets()
    key = send(hub(clock, log=log, held=held), "o1", CHICKEN, **CATERING)
    clock[0] = START + 25 * MINUTE  # the power was out from the morning until now
    back = hub(clock, log=log, held=held)
    assert release(back) == [f"{key}:wok", f"{key}:takeout"]
    assert f"READY BY {_clock(SATURDAY)}" in ticket(back, key, "wok").text


def _clock(ms: int) -> str:
    return f"{datetime.fromtimestamp(ms / 1000):%H:%M}"


def test_the_ticket_is_the_order_as_it_stands_when_its_time_comes():
    clock = [T0 + 100]
    c = hub(clock, settings=servers_void())
    first = send(c, "o1", CHICKEN, ROLL, **CATERING)
    # on Wednesday the customer adds beer and drops the chicken
    clock[0] = T0 + DAY
    send(c, "o1", BEER, at=100)
    took_off = post(c, payload("v1", "void_line", 300, line_id="L0-1", reason="guest-changed-mind"))
    # nothing of the order is on paper, so no ticket and no void slip prints
    assert took_off["print_jobs"] == [] and printed(c) == []
    assert waiting(c) == [("o1", START, 2)]
    clock[0] = START
    # one ticket a station, under the first send: the roll, the beer, and both for the bag
    assert release(c) == [f"{first}:sushi", f"{first}:bar", f"{first}:takeout"]
    assert (dishes(c, first, "sushi"), dishes(c, first, "bar"), dishes(c, first, "takeout")) == (1, 1, 2)
    # the beer is no change to a ticket the bar has: this is the first it sees of the order
    assert "1 x Tsingtao" in ticket(c, first, "takeout").text and "1 x Tsingtao" in ticket(c, first, "bar").text
    assert not any("VOID" in line for job in printed(c) for line in decode(_data(c, job)).text)


def _data(c: TestClient, job_id: str) -> bytes:
    return c.app.state.printing.store.get(job_id).data


def test_an_order_with_every_dish_taken_off_prints_nothing():
    clock = [T0 + 100]
    c = hub(clock, settings=servers_void())
    send(c, "o1", CHICKEN, **CATERING)
    post(c, payload("v1", "void_line", 300, line_id="L0-1", reason="guest-changed-mind"))
    assert waiting(c) == [] and printed(c) == []
    clock[0] = START
    assert release(c) == []


def test_an_order_moved_to_another_time_waits_for_the_new_one():
    clock = [T0 + 100]
    c = hub(clock)
    key = send(c, "o1", CHICKEN, **CATERING)
    post(c, payload("later", "set_field", 200, promised_at=SATURDAY + DAY))  # now it is for Sunday
    assert waiting(c) == [("o1", START + DAY, 1)]
    clock[0] = START
    assert release(c) == []
    clock[0] = START + DAY
    assert release(c) == [f"{key}:wok", f"{key}:takeout"]
    assert f"READY BY {_clock(SATURDAY + DAY)}" in ticket(c, key, "wok").text


def test_an_order_moved_up_to_now_prints_with_the_change():
    clock = [T0 + 100]
    c = hub(clock)
    key = send(c, "o1", CHICKEN, **CATERING)
    # they are at the door: it is for half an hour from now, and it takes an hour
    moved = post(c, payload("now", "set_field", 200, promised_at=T0 + 30 * MINUTE))
    assert moved["print_jobs"] == [f"{key}:wok", f"{key}:takeout"]
    assert waiting(c) == [] and release(c) == []


def test_an_order_voided_whole_prints_nothing():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", CHICKEN, **CATERING)
    post(c, payload("gone", "void_order", 200))
    assert waiting(c) == []
    clock[0] = START
    assert release(c) == [] and printed(c) == []


def test_a_voided_order_found_at_its_time_prints_nothing():
    # one voided on another hub: this one hears of it from the log, not from a batch of its own
    clock = [T0 + 100]
    log, held = OpStore(physical=lambda: T0 + 100), HeldTickets()
    c = hub(clock, log=log, held=held)
    send(c, "o1", CHICKEN, **CATERING)
    op = payload("gone", "void_order", 200)
    log.append([Op(op["op_id"], "o1", HLC.parse(op["hlc"]), op["device"], "void_order", {})])
    assert waiting(c) == [("o1", START, 1)]
    clock[0] = START
    assert release(c) == [] and waiting(c) == []


def test_closing_the_check_does_not_cancel_the_food():
    clock = [T0 + 100]
    c = hub(clock)
    key = send(c, "o1", CHICKEN, **CATERING)
    post(c, payload("shut", "close", 200))  # paid in full on Tuesday, and the check closed
    clock[0] = START
    assert release(c) == [f"{key}:wok", f"{key}:takeout"]


def test_an_allergy_told_while_it_waits_is_on_its_ticket_and_no_notice_prints():
    clock = [T0 + 100]
    c = hub(clock)
    key = send(c, "o1", CHICKEN, **CATERING)
    told = post(c, payload("a1", "allergy", 200, allergens=["peanut"]))
    assert told["print_jobs"] == [] and printed(c) == []
    clock[0] = START
    release(c)
    assert "ALLERGY" in ticket(c, key, "wok").inverted
    assert any("Peanuts" in line for line in ticket(c, key, "wok").text)
    # once it is on paper, another allergy is a notice of its own
    after = post(c, payload("a2", "allergy", 300, allergens=["sesame"]))
    assert after["print_jobs"] == ["a2:wok", "a2:takeout"]


def test_dishes_sent_once_its_time_has_come_print_at_once():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", CHICKEN, **CATERING)
    clock[0] = START
    release(c)
    more = send(c, "o1", BEER, at=100)
    assert ticket(c, more, "bar") is not None and waiting(c) == []


def test_dishes_added_at_the_last_minute_go_out_with_the_ones_that_waited():
    # the hub's loop has not looked yet when the dish is sent: everything prints together, as one ticket
    clock = [T0 + 100]
    c = hub(clock)
    first = send(c, "o1", CHICKEN, **CATERING)
    clock[0] = START
    send(c, "o1", BEER, at=100)
    assert printed(c) == [f"{first}:wok", f"{first}:bar", f"{first}:takeout"]
    assert dishes(c, first, "takeout") == 2 and waiting(c) == [] and release(c) == []


def test_a_void_of_a_dish_on_paper_prints_while_the_rest_waits():
    clock = [T0 + 100]
    c = hub(clock, settings=servers_void())
    first = send(c, "o1", CHICKEN, **{**CATERING, "promised_at": T0 + 2 * HOUR})
    clock[0] = T0 + HOUR
    assert release(c) == [f"{first}:wok", f"{first}:takeout"]
    # then it is put off to Saturday, and a roll is added: the roll waits, the chicken is on paper
    post(c, payload("later", "set_field", 200, promised_at=SATURDAY))
    second = send(c, "o1", ROLL, at=300)
    assert waiting(c) == [("o1", START, 1)] and ticket(c, second, "sushi") is None
    gone = post(c, payload("v1", "void_line", 400, line_id="L0-1", reason="guest-changed-mind"))
    assert gone["print_jobs"] == ["v1:wok", "v1:takeout"]
    quiet = post(c, payload("v2", "void_line", 500, line_id="L300-1", reason="guest-changed-mind"))
    assert quiet["print_jobs"] == [] and waiting(c) == []


def test_a_screen_that_skips_a_station_skips_it_for_what_it_sent_ahead():
    clock = [T0 + 100]
    settings = SettingStore()
    settings.put("ticket_skips", clean_ticket_skips({"screens": [{"device": "bar1", "stations": ["bar"]}]}))
    c = hub(clock, settings=settings)

    def op(device: str, op_id: str, kind: str, at: int, **data) -> dict:
        stamp = str(HLC(T0 + at, 0, device))
        return {"op_id": op_id, "order_id": "o1", "hlc": stamp, "device": device, "kind": kind, "data": data}

    post(
        c,
        op("bar1", "open", "create", 0, **CATERING),
        op("bar1", "a1", "add_line", 1, line_id="L1", item="?", request=BEER),
        op("bar1", "a2", "add_line", 2, line_id="L2", item="?", request=CHICKEN),
        op("bar1", "bar-fire", "fire", 3, course="*"),
    )
    # another beer from a screen that prints everywhere
    post(
        c,
        op("t1", "a3", "add_line", 10, line_id="L3", item="?", request=BEER),
        op("t1", "floor-fire", "fire", 11, course="*"),
    )
    clock[0] = START
    assert release(c) == ["bar-fire:wok", "bar-fire:takeout", "floor-fire:bar", "floor-fire:takeout"]
    assert dishes(c, "floor-fire", "bar") == 1


def test_an_order_for_now_and_a_table_are_never_held():
    clock = [T0 + 100]
    c = hub(clock)
    now = send(c, "o1", CHICKEN, order_type="takeout", channel="counter", customer_name="Linda")
    table = send(c, "o2", CHICKEN)
    assert printed(c) == [f"{now}:wok", f"{now}:takeout", f"{table}:wok"] and waiting(c) == []


def test_a_starting_hub_takes_on_the_orders_sent_ahead_that_nothing_holds(monkeypatch: pytest.MonkeyPatch):
    # sent ahead on a hub from before it wrote down what waits: the tickets were in its memory, and are gone
    clock = [T0 + 100]
    log = OpStore(physical=lambda: T0 + 100)
    old = hub(clock, log=log)
    send(old, "o1", CHICKEN, ROLL, **CATERING)
    send(old, "o2", CHICKEN, **{**CATERING, "promised_at": T0 + 2 * HOUR})
    send(old, "o3", BEER, order_type="takeout", channel="counter", customer_name="Ann")  # for now: on paper
    send(old, "o4", CHICKEN, **CATERING)
    post(old, payload("gone", "void_order", 900), order_id="o4")
    clock[0] = T0 + 90 * MINUTE  # o2's time came and went on the old hub: it is on paper too

    new = hub(clock, log=log)  # nothing of what waited came with it
    assert waiting(new) == []
    ahead = log.views(log.index(promised=(clock[0], 10**14)))
    assert new.app.state.printing.adopt(ahead) == ["o1"]
    assert waiting(new) == [("o1", START, 2)]
    assert new.app.state.printing.adopt(ahead) == []  # what is on hold is left as it is
    clock[0] = START
    assert release(new) == ["held:o1:wok", "held:o1:sushi", "held:o1:takeout"]

    # and a hub does it by itself as it starts (by its own clock, on which neither order's time has come)
    monkeypatch.setenv("POS_PRINT_DIRECT", "0")
    monkeypatch.delenv("DATABASE_URL", raising=False)
    settings = SettingStore()
    settings.put(
        "printers", {"printers": [{"id": "wok", "station": "wok", "address": "10.0.0.1"}], "takeout_station": ""}
    )
    started = TestClient(create_app(log, menu=menu_with_takeout(), settings=settings))
    assert [(h["order_id"], h["lines"]) for h in started.get("/print/jobs").json()["held"]] == [("o2", 1), ("o1", 2)]


def test_what_is_kept_of_an_order():
    held = Held("o1", 5, (Part("f1", ("L1", "L2"), ("bar",)), Part("f2", ("L3",))))
    assert held.lines == {"L1", "L2", "L3"}
    assert held.without({"L1", "L3"}) == Held("o1", 5, (Part("f1", ("L2",), ("bar",)),))
    assert Part.from_json(held.parts[0].as_json()) == held.parts[0]
    assert Part.from_json({"key": "f"}) is None and Part.from_json("f") is None
    store = HeldTickets()
    store.put(held)
    store.put(Held("o2", 3, (Part("g", ("L9",)),)))
    assert [h.order_id for h in store.all()] == ["o2", "o1"]
    assert [h.order_id for h in store.due(4)] == ["o2"] and store.get("o1") == held
    store.put(held.without(held.lines))  # nothing left of it: it is dropped
    store.drop("o2")
    assert store.all() == [] and store.get("o1") is None


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_what_waits_is_kept_in_postgres():
    import psycopg

    from pos.printing.held import PgHeldTickets

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS held_ticket")
    store = PgHeldTickets(DSN)
    try:
        held = Held("o1", SATURDAY, (Part("f1", ("L1", "L2"), ("bar",)), Part("f2", ("L3",))))
        store.put(held)
        store.put(Held("o2", START, (Part("g", ("L9",)),)))
        again = PgHeldTickets(DSN)  # another process: the hub after a restart
        try:
            assert store.fresh and not again.fresh  # only the start that made the list takes old orders on
            assert again.get("o1") == held and again.get("nobody") is None
            assert [h.order_id for h in again.all()] == ["o2", "o1"]
            assert [h.order_id for h in again.due(START)] == ["o2"] and again.due(START - 1) == []
            again.put(held.without({"L1", "L3"}))
            assert store.get("o1") == Held("o1", SATURDAY, (Part("f1", ("L2",), ("bar",)),))
            again.put(held.without(held.lines))
            again.drop("o2")
            assert store.all() == []
        finally:
            again.close()

        # the whole way: a hub on PostgreSQL holds an order, is started again, and prints it at its time
        clock = [T0 + 100]
        log = OpStore(physical=lambda: T0 + 100)
        key = send(hub(clock, log=log, held=store), "o1", CHICKEN, **CATERING)
        back = PgHeldTickets(DSN)
        try:
            restarted = hub(clock, log=log, held=back)
            assert waiting(restarted) == [("o1", START, 1)]
            clock[0] = START
            assert release(restarted) == [f"{key}:wok", f"{key}:takeout"] and back.all() == []
        finally:
            back.close()
    finally:
        store.close()


def test_a_ticket_that_cannot_be_written_down_prints_now_with_its_day_on_it():
    class Broken(HeldTickets):
        def put(self, held: Held) -> None:
            raise OSError("the database is not answering")

    clock = [T0 + 100]
    c = hub(clock, held=Broken())
    key = send(c, "o1", CHICKEN, **CATERING)
    # on paper days early rather than lost, and it says which day it is for
    assert printed(c) == [f"{key}:wok", f"{key}:takeout"]
    paper = ticket(c, key, "wok")
    assert [line for line in paper.text if line.startswith("READY BY")] == [
        f"READY BY {_clock(SATURDAY)}  {_day(SATURDAY)}"
    ]
    clock[0] = START
    assert release(c) == []


def _day(ms: int) -> str:
    at = datetime.fromtimestamp(ms / 1000)
    return f"{at:%a %b} {at.day}".upper()


def test_a_ticket_printed_on_its_day_says_the_time_alone():
    clock = [T0 + 100]
    c = hub(clock)
    key = send(c, "o1", CHICKEN, **{**CATERING, "promised_at": T0 + 2 * HOUR})
    clock[0] = T0 + HOUR
    release(c)
    assert f"READY BY {_clock(T0 + 2 * HOUR)}" in ticket(c, key, "wok").text
    at = datetime(2026, 11, 17, 9, 0)
    assert "READY BY 12:00" in decode(render(replace(DEMO, at=at, promised=datetime(2026, 11, 17, 12, 0)))).text
    other = decode(render(replace(DEMO, at=at, promised=datetime(2026, 11, 21, 12, 0))))
    assert "READY BY 12:00  SAT NOV 21" in other.text
