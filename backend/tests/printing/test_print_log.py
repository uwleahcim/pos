"""Every paper the hub prints is written in the print log with what became of it, can be looked at on a
screen as it came out, and can be printed again, headed REPRINT (docs/printing.md, "The print log")."""

from __future__ import annotations

import copy
import os
import uuid
from dataclasses import replace
from datetime import datetime

import pytest
from fastapi.testclient import TestClient
from psycopg.types.json import Jsonb

from pos.api.app import create_app
from pos.api.prints import bar_stations
from pos.printing.bill import SAMPLE, render_bill
from pos.printing.jobs import FALLBACK_AFTER
from pos.printing.labels import BagLabels, render_labels
from pos.printing.log import (
    DAY_MS,
    EVENTS,
    KEEP_DAYS,
    TYPES,
    Event,
    PgPrintLog,
    Print,
    PrintLog,
    found_in,
    pattern_of,
    search_for,
    types_of,
    words_of,
)
from pos.printing.script import REPRINT, carried, clean, original, pages, play, reprinted
from pos.printing.service import NoPrinter, NoSuchPrint, Printer, PrintService
from pos.printing.ticket import DEMO, DIALECTS, SCRIPT, render
from pos.sync.oplog import OpStore

from ..conftest import T0
from .fake_printer import decode
from .test_other_stations import BEER, CHICKEN, send
from .test_stations import manager, menu_with_takeout

DSN = os.environ.get("POS_TEST_DATABASE_URL")
MINUTE = 60_000
LABELS = BagLabels(order_id="0193f2a7-two-bags", bags=2, order_no=45, customer="Wu", at=datetime(2026, 11, 26, 18, 42))


def jobs_of(prints: list[Print]) -> list[str]:
    return [entry.job_id for entry in prints]


def texts(script: list[list[dict]]) -> list[str]:
    """What a script's lines say, the two sides of a pair of columns together."""
    said = []
    for page in script:
        for step in page:
            if step["k"] == "line":
                said.append(step["text"])
            elif step["k"] == "cols":
                said.append(f"{step['left']} | {step['right']}")
    return said


class Wires:
    """The printers' side of the wire: what each address was sent, and which of them do not answer."""

    def __init__(self) -> None:
        self.down: set[str] = set()
        self.got: list[tuple[str, bytes]] = []

    def __call__(self, address: str, data: bytes) -> None:
        if address in self.down:
            raise OSError("timed out")
        self.got.append((address, data))


def service(*, log: PrintLog | None = None, clock: list[int] | None = None, wires: Wires | None = None) -> PrintService:
    """A hub's printing with a wok printer (the bar is its fallback) and a bar printer that speaks Star. Its
    jobs are kept and printed when the test says (`retry_pending`), over wires the test holds."""
    printers = [
        Printer("wok", "10.0.0.1", id="wok", fallbacks=("bar",)),
        Printer("bar", "10.0.0.2", id="bar", dialect="star"),
    ]
    clock = clock if clock is not None else [T0]
    made = PrintService(printers, now=lambda: clock[0], log=log, send=wires or Wires())
    made._start = lambda job: None  # nothing is written to a printer as it is queued: `retry_pending` does it
    made.station_names = lambda: {"wok": "Wok", "bar": "Bar"}  # as the menu names them
    return made


def hub(printing: PrintService) -> TestClient:
    return TestClient(create_app(OpStore(physical=lambda: T0 + 100), menu=menu_with_takeout(), printing=printing))


# The paper written down ------------------------------------------------------------------------------------


@pytest.mark.parametrize("dialect", sorted(DIALECTS))
def test_a_paper_written_down_plays_back_as_the_very_bytes_its_printer_got(dialect: str):
    def make():
        return DIALECTS[dialect]()

    assert play(pages(render(DEMO, dialect=SCRIPT)), make) == render(DEMO, dialect=dialect)
    assert play(pages(render_bill(SAMPLE, dialect=SCRIPT)), make) == render_bill(SAMPLE, dialect=dialect)
    # an order's labels are a paper each inside the one job: a page each in the script
    script = pages(render_labels(LABELS, dialect=SCRIPT))
    assert len(script) == 2 and play(script, make) == render_labels(LABELS, dialect=dialect)


def test_the_script_says_the_paper_line_by_line():
    (page,) = pages(render(replace(DEMO, kind="void"), dialect=SCRIPT))
    assert page[0] == {"k": "beep", "n": 3}
    assert page[1] == {"k": "line", "text": "*** VOID *** WOK", "bold": True, "big": True, "center": True}
    assert page[2]["k"] == "cols" and page[2]["left"] == "#3412  dine in"
    assert {"k": "rule"} in page and page[-1] == {"k": "cut"}
    assert "1 x 左宗鸡 (Qt) [s2]" in texts([page])  # Chinese is kept as it is written, not as a picture of it


def test_a_reprint_is_headed_once_however_often_it_is_printed_again():
    script = pages(render(DEMO, dialect=SCRIPT))
    again = reprinted(script, "FIRST PRINTED FRI JAN 15 03:00")
    head = [step for step in again[0] if step.get("re")]
    assert [step["text"] for step in head] == [REPRINT, "FIRST PRINTED FRI JAN 15 03:00"]
    assert head[0]["invert"] and head[0]["big"]  # white on black, as big as a dish
    assert again[0][0]["k"] == "beep"  # the heading is the first thing on the paper, under the beep
    assert original(again) == script
    assert reprinted(again, "FIRST PRINTED FRI JAN 15 03:00") == again
    # a fallback printer's copy says whose printer is down, under the heading
    down = reprinted(script, "FIRST PRINTED FRI JAN 15 03:00", whose="Wok")
    assert [s["text"] for s in down[0] if s.get("re")][-1] == "WOK PRINTER DOWN, PRINTED HERE"
    # and on the screen, a paper that came out at a fallback says so on top
    assert texts(carried(script, "Wok"))[0] == "WOK PRINTER DOWN, PRINTED HERE"
    assert texts(carried(again, "Wok"))[:3] == [
        REPRINT,
        "FIRST PRINTED FRI JAN 15 03:00",
        "WOK PRINTER DOWN, PRINTED HERE",
    ]


def test_a_script_read_back_keeps_only_what_can_be_played():
    kept = clean([[{"k": "line", "text": "A"}, {"k": "picture"}, "junk"], "junk", [], [{"k": "cut"}]])
    assert kept == [[{"k": "line", "text": "A"}], [{"k": "cut"}]]
    assert clean(None) == [] and clean({"k": "line"}) == []


# What the log keeps ------------------------------------------------------------------------------------------


def test_a_send_is_written_down_ticket_by_ticket_and_marked_when_it_prints():
    wires, clock = Wires(), [T0]
    printing = service(clock=clock, wires=wires)
    c = hub(printing)
    key = send(c, "o1", CHICKEN, BEER)
    by_printer = {entry.printer: entry for entry in printing.log.list()}
    wok, bar = by_printer["wok"], by_printer["bar"]
    assert (wok.job_id, wok.printer, wok.name, wok.address) == (f"{key}:wok", "wok", "Wok", "10.0.0.1")
    assert (wok.sort, wok.kind, wok.title, wok.head, wok.order_id) == ("ticket", "new", "Table 12", "Wok", "o1")
    assert (bar.printer, bar.title) == ("bar", "Table 12")
    assert not wok.printed and wok.trouble and printing.status(wok) == "waiting"
    # the paper is kept as it was made: what the wok read, and nothing of the bar's
    _, script = printing.log.get(wok.job_id)
    assert "1 x 左宗鸡 (Qt)" in texts(script) and "1 x Tsingtao" not in texts(script)
    clock[0] += 2000
    assert printing.retry_pending() == 2
    wok = printing.log.get(wok.job_id)[0]
    assert wok.printed and not wok.trouble and printing.status(wok) == "printed"
    assert (wok.printed_ms, wok.printed_by, wok.printed_on, wok.tries) == (T0 + 2000, "hub", "10.0.0.1", 0)
    assert [(e.what, e.ms) for e in wok.events] == [("printed", T0 + 2000)]
    assert printing.seen(wok)["status"] == "printed"


def test_the_same_job_asked_for_twice_is_one_print():
    printing = service()
    printing.queue(DEMO, printing.printers[0], job_id="j1")
    printing.queue(DEMO, printing.printers[0], job_id="j1")
    assert [entry.job_id for entry in printing.log.list()] == ["j1"]


def test_a_printer_that_does_not_answer_is_written_down_once_and_counted():
    wires, clock = Wires(), [T0]
    wires.down = {"10.0.0.2"}
    printing = service(clock=clock, wires=wires)
    told: list[int] = []
    printing.on_log = lambda: told.append(clock[0])
    printing.queue(SAMPLE, printing.printers[1], job_id="bill")  # the bar has no fallback
    assert told == [T0]
    for second in range(1, 6):  # tried every few seconds, the same answer each time
        clock[0] = T0 + second * 3000
        assert printing.retry_pending() == 0
    entry = printing.log.get("bill")[0]
    assert (entry.tries, entry.error, entry.error_ms) == (1, "timed out", T0 + 3000)
    assert [(e.what, e.text, e.times) for e in entry.events] == [("failed", "timed out", 1)]
    assert told == [T0, T0 + 3000]  # the screens heard of the failure once, not of every try
    clock[0] = T0 + 70_000  # a minute on, the count is brought up to date, quietly
    printing.retry_pending()
    entry = printing.log.get("bill")[0]
    assert (entry.tries, entry.events[-1].times) == (6, 6)
    assert told == [T0, T0 + 3000]
    wires.down = set()
    clock[0] = T0 + 80_000
    assert printing.retry_pending() == 1
    entry = printing.log.get("bill")[0]
    assert entry.printed and entry.trouble  # it printed, late: still one to look at
    assert (entry.tries, entry.printed_ms, entry.error) == (6, T0 + 80_000, "timed out")
    assert [(e.what, e.times) for e in entry.events] == [("failed", 6), ("printed", 1)]
    assert told[-1] == T0 + 80_000


def test_a_ticket_that_went_to_the_fallback_says_where_it_printed():
    wires, clock = Wires(), [T0]
    wires.down = {"10.0.0.1"}
    printing = service(clock=clock, wires=wires)
    printing.queue(DEMO, printing.printers[0], job_id="t1")
    for n in range(FALLBACK_AFTER):
        clock[0] = T0 + (n + 1) * 3000
        printing.retry_pending()
    entry = printing.log.get("t1")[0]
    assert [(e.what, e.text) for e in entry.events] == [("failed", "timed out"), ("moved", "Bar")]
    assert not entry.printed
    clock[0] = T0 + 9000
    assert printing.retry_pending() == 1
    entry = printing.log.get("t1")[0]
    assert entry.printed and entry.elsewhere and entry.trouble
    assert (entry.printed_on, entry.printed_name, entry.tries) == ("10.0.0.2", "Bar", 2)
    assert entry.events[-1] == Event(T0 + 9000, "printed", "Bar")
    # on the screen the paper reads as the bar's printer printed it
    shown, script = printing.paper("t1")
    assert shown == entry and texts(script)[0] == "WOK PRINTER DOWN, PRINTED HERE"
    assert texts(printing.log.get("t1")[1])[0] == "WOK"  # the log keeps it as it was made for the wok


def test_tickets_waiting_behind_one_their_printer_failed_say_the_same_in_the_log():
    """A printer that is down is tried once a round, with the oldest ticket (`pos.printing.jobs.Lines`).
    The tickets behind it count the try too, and the log says of each what it says of the first."""
    wires, clock = Wires(), [T0]
    wires.down = {"10.0.0.1"}
    printing = service(clock=clock, wires=wires)
    for name in ("t1", "t2", "t3"):
        printing.queue(DEMO, printing.printers[0], job_id=name)
    for n in range(FALLBACK_AFTER):
        clock[0] = T0 + (n + 1) * 3000
        assert printing.retry_pending() == 0
    for name in ("t1", "t2", "t3"):
        entry = printing.log.get(name)[0]
        assert [(e.what, e.text) for e in entry.events] == [("failed", "timed out"), ("moved", "Bar")]
        # the second failure, the same within the minute, is counted when the ticket prints
        assert (entry.tries, entry.error, printing.status(entry)) == (1, "timed out", "waiting")
    clock[0] = T0 + 9000
    assert printing.retry_pending() == 3
    assert [address for address, _ in wires.got] == ["10.0.0.2"] * 3
    for name in ("t1", "t2", "t3"):
        entry = printing.log.get(name)[0]
        assert entry.printed and entry.elsewhere and (entry.printed_name, entry.tries) == ("Bar", 2)


def test_a_print_still_waiting_when_the_hub_stopped_reads_as_lost():
    log, wires = PrintLog(), Wires()
    wires.down = {"10.0.0.1", "10.0.0.2"}
    before = service(log=log, wires=wires)
    before.queue(DEMO, before.printers[0], job_id="t1")
    before.retry_pending()
    after = service(log=log)  # the hub started again: the log is there, the job is not
    entry = after.log.get("t1")[0]
    assert after.status(entry) == "lost" and after.seen(entry)["status"] == "lost"
    assert before.status(entry) == "waiting"


def test_what_happened_to_a_print_is_kept_short():
    entry = Print("j", T0, printer="wok", name="Wok", address="10.0.0.1")
    for n in range(40):
        entry = entry.then(Event(T0 + n, "failed", f"error {n}"))
    assert len(entry.events) == EVENTS
    assert entry.events[0].text == "error 0" and entry.events[-1].text == "error 39"
    assert Print.from_json(entry.as_json()) == entry
    assert Print.from_json({"job_id": "j"}) == Print("j", 0, printer="", name="", address="")
    assert Print.from_json({"at_ms": 1}) is None and Print.from_json("junk") is None


def test_prints_older_than_the_log_keeps_are_dropped():
    clock = [T0]
    printing = service(clock=clock)
    printing.queue(DEMO, printing.printers[0], job_id="old")
    clock[0] = T0 + KEEP_DAYS * DAY_MS - MINUTE
    printing.queue(DEMO, printing.printers[0], job_id="kept")
    assert {entry.job_id for entry in printing.log.list()} == {"old", "kept"}
    clock[0] = T0 + KEEP_DAYS * DAY_MS + 2 * 60 * MINUTE
    printing.queue(DEMO, printing.printers[0], job_id="new")
    assert [entry.job_id for entry in printing.log.list()] == ["new", "kept"]


def test_a_log_that_cannot_be_written_stops_no_print():
    class Broken(PrintLog):
        def add(self, entry, script):
            raise RuntimeError("the database is away")

        def change(self, job_id, how):
            raise RuntimeError("the database is away")

    wires = Wires()
    printing = service(log=Broken(), wires=wires)
    printing.queue(DEMO, printing.printers[0], job_id="t1")
    assert printing.retry_pending() == 1
    assert [address for address, _ in wires.got] == ["10.0.0.1"]


# Printing it again ---------------------------------------------------------------------------------------------


def test_a_reprint_is_the_same_paper_headed_reprint():
    wires, clock = Wires(), [T0]
    printing = service(clock=clock, wires=wires)
    printing.queue(replace(DEMO, kind="modify"), printing.printers[0], job_id="t1")
    printing.retry_pending()
    first_bytes = wires.got[0][1]
    clock[0] = T0 + 5 * MINUTE
    job, made = printing.reprint("t1", by="Mike")
    assert job.job_id == made.job_id and made.job_id.startswith("reprint:")
    assert (made.reprint_of, made.first_ms, made.by) == ("t1", T0, "Mike")
    assert (made.printer, made.sort, made.kind, made.title, made.head) == ("wok", "ticket", "modify", "Table 12", "Wok")
    assert printing.retry_pending() == 1
    address, data = wires.got[-1]
    paper = decode(data)
    assert address == "10.0.0.1"
    # white on black across the top, with when the first came out; then the ticket as it was, word for word
    assert paper.inverted[0] == REPRINT
    said = [line.strip() for line in paper.text if line.strip()]
    assert said[:3] == [REPRINT, "FIRST PRINTED FRI JAN 15 03:00", "*** MODIFY *** WOK"]
    assert said[2:] == [line.strip() for line in decode(first_bytes).text if line.strip()]
    assert paper.beeps == decode(first_bytes).beeps and paper.cuts == 1
    # the first counts it and says who asked
    first = printing.log.get("t1")[0]
    assert first.reprints == 1 and first.events[-1] == Event(T0 + 5 * MINUTE, "reprinted", "by Mike at Wok")
    # the reprint's own paper in the log is the one headed REPRINT
    assert texts(printing.paper(made.job_id)[1])[0] == REPRINT


def test_a_reprint_of_a_reprint_repeats_the_first_paper():
    wires, clock = Wires(), [T0]
    printing = service(clock=clock, wires=wires)
    printing.queue(DEMO, printing.printers[0], job_id="t1")
    printing.retry_pending()
    _, once = printing.reprint("t1", by="Mike")
    clock[0] = T0 + MINUTE
    _, twice = printing.reprint(once.job_id, by="Amy")
    assert (twice.reprint_of, twice.first_ms) == ("t1", T0)
    said = texts(printing.log.get(twice.job_id)[1])
    assert said.count(REPRINT) == 1 and said[1] == "FIRST PRINTED FRI JAN 15 03:00"
    assert printing.log.get("t1")[0].reprints == 2 and printing.log.get(once.job_id)[0].reprints == 0


def test_a_reprint_of_a_ticket_that_never_came_out_says_so():
    wires = Wires()
    wires.down = {"10.0.0.1", "10.0.0.2"}
    log = PrintLog()
    before = service(log=log, wires=wires)
    before.queue(DEMO, before.printers[0], job_id="t1")
    after = service(log=log)  # started again with the ticket never printed
    _, made = after.reprint("t1")
    assert texts(log.get(made.job_id)[1])[:2] == [REPRINT, "FIRST SENT FRI JAN 15 03:00, DID NOT PRINT"]


def test_a_reprint_can_go_to_another_printer_in_that_printers_language():
    wires = Wires()
    printing = service(wires=wires)
    printing.queue(DEMO, printing.printers[0], job_id="t1")
    printing.retry_pending()
    _, made = printing.reprint("t1", printer="bar")
    assert (made.printer, made.name, made.address) == ("bar", "Bar", "10.0.0.2")
    printing.retry_pending()
    address, data = wires.got[-1]
    script = printing.log.get(made.job_id)[1]
    assert address == "10.0.0.2" and data == play(script, DIALECTS["star"])
    assert decode(wires.got[0][1]).text  # the wok's was text; the Star's is one image of the same lines
    assert printing.log.get("t1")[0].events[-1].text == "at Bar"


def test_a_reprint_whose_printer_is_down_goes_to_its_fallback_and_says_both():
    wires = Wires()
    printing = service(wires=wires)
    printing.queue(DEMO, printing.printers[0], job_id="t1")
    printing.retry_pending()
    wires.down = {"10.0.0.1"}
    job, made = printing.reprint("t1")
    address, data = job.fallbacks[0]
    wanted = reprinted(printing.log.get("t1")[1], "FIRST PRINTED FRI JAN 15 03:00", whose="Wok")
    assert address == "10.0.0.2" and data == play(wanted, DIALECTS["star"])
    for _ in range(FALLBACK_AFTER + 1):
        printing.retry_pending()
    made = printing.log.get(made.job_id)[0]
    assert made.printed and made.elsewhere and made.printed_name == "Bar"
    assert texts(printing.paper(made.job_id)[1])[:3] == [
        REPRINT,
        "FIRST PRINTED FRI JAN 15 03:00",
        "WOK PRINTER DOWN, PRINTED HERE",
    ]


def test_nothing_is_reprinted_without_a_print_or_a_printer():
    printing = service()
    with pytest.raises(NoSuchPrint):
        printing.reprint("nothing")
    printing.queue(DEMO, printing.printers[0], job_id="t1")
    with pytest.raises(NoPrinter):
        printing.reprint("t1", printer="office")
    # the printer it was made for was taken off the list: at whichever printer has its address now, else none
    printing.printers = [Printer("grill", "10.0.0.1", id="grill")]
    assert printing.reprint("t1")[1].printer == "grill"
    printing.printers = [Printer("grill", "10.0.0.9", id="grill")]
    with pytest.raises(NoPrinter):
        printing.reprint("t1")
    assert printing.reprint("t1", printer="grill")[1].address == "10.0.0.9"


# On the wire -------------------------------------------------------------------------------------------------


def test_the_log_is_a_managers_to_read_and_to_print_from():
    c = hub(service())
    amy, _ = c.app.state.tokens.issue("s1", "Amy", "server")
    server = {"authorization": f"Bearer {amy}"}
    for call in (
        lambda headers: c.get("/print/log", headers=headers),
        lambda headers: c.get("/print/log/paper", params={"job": "x"}, headers=headers),
        lambda headers: c.post("/print/log/reprint", json={"job": "x"}, headers=headers),
    ):
        assert call({}).status_code == 401
        assert call(server).status_code == 403


def test_the_log_page_by_page_by_printer_and_by_trouble():
    wires, clock = Wires(), [T0]
    printing = service(clock=clock, wires=wires)
    c = hub(printing)
    boss = manager(c)
    for n in range(5):
        clock[0] = T0 + n * MINUTE
        printing.queue(DEMO, printing.printers[n % 2], job_id=f"t{n}")
    printing.retry_pending()
    wires.down = {"10.0.0.2"}
    clock[0] = T0 + 5 * MINUTE
    printing.queue(SAMPLE, printing.printers[1], job_id="bill", title="Sample bill")
    printing.retry_pending()
    first = c.get("/print/log", params={"limit": 4}, headers=boss).json()
    assert [p["job_id"] for p in first["prints"]] == ["bill", "t4", "t3", "t2"]
    assert first["keeps_days"] == KEEP_DAYS
    assert first["printers"] == [
        {"id": "wok", "name": "Wok", "address": "10.0.0.1"},
        {"id": "bar", "name": "Bar", "address": "10.0.0.2"},
    ]
    bill = first["prints"][0]
    assert (bill["status"], bill["sort"], bill["title"], bill["error"], bill["tries"]) == (
        "waiting",
        "bill",
        "Sample bill",
        "timed out",
        1,
    )
    assert first["prints"][1]["status"] == "printed" and first["prints"][1]["printed_by"] == "hub"
    rest = c.get("/print/log", params={"limit": 4, "before": first["next"]}, headers=boss).json()
    assert [p["job_id"] for p in rest["prints"]] == ["t1", "t0"] and rest["next"] is None
    bar = c.get("/print/log", params={"printer": "bar"}, headers=boss).json()
    assert [p["job_id"] for p in bar["prints"]] == ["bill", "t3", "t1"]
    trouble = c.get("/print/log", params={"only": "trouble"}, headers=boss).json()
    assert [p["job_id"] for p in trouble["prints"]] == ["bill"]
    assert c.get("/print/log", params={"before": "soon"}, headers=boss).status_code == 422


def test_the_paper_and_the_reprint_on_the_wire():
    wires = Wires()
    printing = service(wires=wires)
    c = hub(printing)
    boss = manager(c)
    told: list[str] = []
    c.app.state.feed.changed = told.append
    key = send(c, "o1", CHICKEN)
    assert told == ["prints"]  # the screens with the log open read it again
    printing.retry_pending()
    paper = c.get("/print/log/paper", params={"job": f"{key}:wok"}, headers=boss).json()
    assert paper["status"] == "printed" and paper["title"] == "Table 12"
    assert paper["pages"][0][1] == {"k": "line", "text": "WOK", "bold": True, "big": True, "center": True}
    assert c.get("/print/log/paper", params={"job": "gone"}, headers=boss).status_code == 404
    answer = c.post("/print/log/reprint", json={"job": f"{key}:wok"}, headers=boss)
    assert answer.status_code == 202
    made = answer.json()
    assert made["printed_at"] == {"id": "wok", "name": "Wok"}
    assert (made["print"]["reprint_of"], made["print"]["by"], made["print"]["status"]) == (
        f"{key}:wok",
        "Mike",
        "waiting",
    )
    printing.retry_pending()
    assert decode(wires.got[-1][1]).inverted[0] == REPRINT
    elsewhere = c.post("/print/log/reprint", json={"job": f"{key}:wok", "printer": "bar"}, headers=boss)
    assert elsewhere.json()["printed_at"] == {"id": "bar", "name": "Bar"}
    listed = c.get("/print/log", headers=boss).json()["prints"]
    assert [p["reprints"] for p in listed if p["job_id"] == f"{key}:wok"] == [2]
    gone = c.post("/print/log/reprint", json={"job": "gone"}, headers=boss)
    assert gone.status_code == 404 and gone.json()["detail"]["error"] == "no_such_print"
    nowhere = c.post("/print/log/reprint", json={"job": f"{key}:wok", "printer": "office"}, headers=boss)
    assert nowhere.status_code == 409 and nowhere.json()["detail"]["error"] == "no_printer"
    assert [p["id"] for p in nowhere.json()["detail"]["printers"]] == ["wok", "bar"]


def test_a_test_print_is_called_one_in_the_log():
    printing = service()
    c = hub(printing)
    assert c.post("/print/test", json={"printer": "wok"}).status_code == 202
    (entry,) = printing.log.list()
    assert (entry.sort, entry.title, entry.printer) == ("ticket", "Test print", "wok")


# Read by type, and searched ---------------------------------------------------------------------------------


def test_the_bar_is_where_the_menu_makes_its_drinks():
    # the liquor, the beer and the cocktails print at `bar` (with a pot of tea); the sushi bar is a kitchen
    assert bar_stations(menu_with_takeout().defs) == {"bar"}


def test_a_print_is_of_the_types_a_manager_reads_the_log_by():
    def made(**what) -> Print:
        return Print("j", T0, printer="p", name="P", address="10.0.0.1", **what)

    assert types_of(made(places=("kitchen",))) == ("kitchen",)
    assert types_of(made(places=("bar",))) == ("bar",)
    assert types_of(made(places=("kitchen", "bar"))) == ("kitchen", "bar")  # one ticket with dishes of both
    assert types_of(made(sort="bill")) == ("bill",)
    assert types_of(made(sort="day")) == types_of(made(sort="labels")) == ("other",)
    assert types_of(made()) == ("other",)  # a ticket that is nobody's order: a test print, a notice
    # whatever is printed again is a reprint, and still what it was
    assert types_of(made(places=("bar",), reprint_of="first")) == ("bar", "reprint")
    assert types_of(made(sort="bill", reprint_of="first")) == ("bill", "reprint")
    assert set(TYPES) == {"kitchen", "bar", "bill", "reprint", "other"}
    # what is kept of a print says where it is made, and a print from before that says nothing
    assert Print.from_json(made(places=("bar",)).as_json()).places == ("bar",)
    old = {k: v for k, v in made().as_json().items() if k != "places"}
    assert Print.from_json(old).places == ()


def test_a_tickets_dishes_say_whether_it_is_the_kitchens_or_the_bars():
    printing = service()
    c = hub(printing)
    key = send(c, "o1", CHICKEN, BEER)
    by_job = {entry.job_id: entry for entry in printing.log.list()}
    assert by_job[f"{key}:wok"].places == ("kitchen",)
    assert by_job[f"{key}:bar"].places == ("bar",)
    assert [e.job_id for e in printing.log.list(type="bar")] == [f"{key}:bar"]
    assert [e.job_id for e in printing.log.list(type="kitchen")] == [f"{key}:wok"]
    # a test print and a bill are neither
    assert c.post("/print/test", json={"printer": "bar"}).status_code == 202
    printing.queue(SAMPLE, printing.printers[1], job_id="bill")
    assert {e.job_id for e in printing.log.list(type="bar")} == {f"{key}:bar"}
    assert [e.job_id for e in printing.log.list(type="bill")] == ["bill"]
    assert [e.title for e in printing.log.list(type="other")] == ["Test print"]


def test_one_printer_for_the_wok_and_the_bar_files_each_ticket_by_what_is_on_it():
    both = Printer("wok", "10.0.0.1", id="line", stations=("wok", "bar"))
    printing = PrintService([both], now=lambda: T0, send=Wires())
    printing._start = lambda job: None
    c = hub(printing)
    drinks = send(c, "o1", BEER)
    food = send(c, "o2", CHICKEN)
    mixed = send(c, "o3", CHICKEN, BEER)
    by_job = {entry.job_id: entry.places for entry in printing.log.list()}
    assert by_job == {
        f"{drinks}:line": ("bar",),
        f"{food}:line": ("kitchen",),
        f"{mixed}:line": ("kitchen", "bar"),  # under both
    }
    assert {e.job_id for e in printing.log.list(type="bar")} == {f"{drinks}:line", f"{mixed}:line"}
    assert {e.job_id for e in printing.log.list(type="kitchen")} == {f"{food}:line", f"{mixed}:line"}


def test_a_hub_that_was_not_told_its_bar_files_every_ticket_under_the_kitchen():
    printing = service()  # no API, so nobody said which stations are the bar's
    printing.queue(DEMO, printing.printers[1], job_id="t")
    assert printing.log.get("t")[0].places == ("kitchen",)
    printing.bar_stations = lambda: 1 / 0  # and a menu that cannot be read holds up no ticket
    printing.queue(DEMO, printing.printers[1], job_id="u")
    assert printing.log.get("u")[0].places == ("kitchen",)


def test_a_reprint_is_listed_under_the_reprints_and_under_what_it_repeats():
    printing = service()
    c = hub(printing)
    key = send(c, "o1", BEER)
    _, again = printing.reprint(f"{key}:bar", by="Mike")
    assert again.places == ("bar",)
    assert [e.job_id for e in printing.log.list(type="reprint")] == [again.job_id]
    assert {e.job_id for e in printing.log.list(type="bar")} == {again.job_id, f"{key}:bar"}
    assert printing.log.list(type="kitchen") == []


def test_the_prints_of_an_older_hub_are_filed_by_what_their_printer_prints_for_now():
    printing = service()
    printing.bar_stations = lambda: {"bar"}
    asked = []
    printing.log.restamp = lambda how: asked.append(how) or 3
    assert printing.catch_up_log() == 3
    (placed,) = asked

    def old(printer: str = "wok", **what) -> Print:
        return Print("j", T0, printer=printer, name="P", address="10.0.0.1", **what)

    assert placed(old()).places == ("kitchen",) and placed(old("bar")).places == ("bar",)
    assert placed(old("taken away since")).places == ("kitchen",)
    assert placed(old("bar", reprint_of="first")).places == ("bar",)
    # what is nobody's order stays with the rest, and a print that says where it is made is left as it is
    for other in (old(sort="bill"), old(sort="day"), old(title="Test print"), old(kind="notice")):
        assert placed(other) == other
    assert placed(old("bar", places=("kitchen",))).places == ("kitchen",)
    # a log that cannot be brought up to date stops no hub from starting
    printing.log.restamp = lambda how: 1 / 0
    assert printing.catch_up_log() == 0


def test_the_words_a_search_looks_through_are_the_logs_line_and_the_paper():
    script = pages(render(replace(DEMO, kind="void"), dialect=SCRIPT))
    entry = Print("j", T0, printer="wok", name="Wok", address="10.0.0.1", kind="void", title="Table 12", head="Wok")
    about, *paper = words_of(entry, script).split("\n")
    assert about == "Void Table 12 Wok Wok"
    assert paper[0] == "*** VOID *** WOK" and "2 x Kung Pao Chicken (Pt) [s1]" in paper
    assert "#3412 dine in " in paper[1]  # the two sides of a pair of columns, one line
    again = replace(entry, reprint_of="first", by="Mike", sort="bill", kind="")
    assert words_of(again, []) == "Reprint Bill Table 12 Wok Wok Mike"
    words = words_of(entry, script)
    # found on the paper: the line is shown; found in the log's own line: there is nothing more to show
    assert found_in(words, "kung pao") == "2 x Kung Pao Chicken (Pt) [s1]"
    assert found_in(words, "table 12") == "" and found_in(words, "VOID") == ""
    assert found_in(words, "no peanuts") == "+ no peanuts"
    assert found_in(words, "pao kung") is None and found_in(words, "table peanuts") is None  # as typed, on one line
    assert found_in("About\n" + "x" * 200, "xxx").endswith("…") and len(found_in("A\n" + "x" * 200, "x")) == 80


def test_a_search_is_the_words_as_typed_and_a_number_in_it_is_a_whole_number():
    assert search_for("  Kung   PAO chicken ") == "Kung PAO chicken"
    assert search_for(None) == search_for("   ") == ""  # nothing typed is no search

    def finds(wanted: str, line: str) -> bool:
        return found_in(f"About\n{line}", wanted) is not None

    assert finds("table 1", "Table 1") and not finds("table 1", "Table 12") and not finds("table 1", "Table 21")
    assert finds("#45", "#45 dine in") and not finds("#45", "#451 dine in") and not finds("45", "#3451")
    assert finds("8.00", "Add shrimp +8.00") and not finds("8.00", "Peking Duck 48.00")
    assert finds("12", "Table 12") and finds("chick", "Kung Pao Chicken")  # a word may be only begun
    # what is typed is letters, never a pattern
    assert finds("7%", "Sales tax 7% 2.37") and not finds("100%", "Sales tax 7% 2.37")
    assert not finds("t.ble", "Table 12") and not finds("_", "Table 12") and not finds(".*", "Table 12")
    assert finds("(qt)", "1 x 左宗鸡 (Qt)") and finds("左宗", "1 x 左宗鸡 (Qt)") and finds("[s1]", "Chicken [s1]")
    assert finds("a\\b", "a\\b") and not finds("a\\b", "ab")
    assert pattern_of("table 1") == "table\\ 1(?![0-9])"


def test_the_log_is_searched_by_what_is_on_the_paper():
    printing = service()
    c = hub(printing)
    boss = manager(c)
    food = send(c, "o1", CHICKEN)
    drinks = send(c, "o2", BEER, table="7", order_type="dine_in")
    printing.queue(SAMPLE, printing.printers[1], job_id="bill")

    def jobs(**asked) -> list[str]:
        answer = c.get("/print/log", params=asked, headers=boss)
        assert answer.status_code == 200
        return [p["job_id"] for p in answer.json()["prints"]]

    assert jobs(q="左宗") == [f"{food}:wok"]  # a dish, in the kitchen's own letters
    assert jobs(q="TSINGTAO") == jobs(q="tsingtao") == [f"{drinks}:bar"]
    assert jobs(q="table 7") == [f"{drinks}:bar"]
    assert jobs(q="table 12") == jobs(q=" Table   12 ") == ["bill", f"{food}:wok"]
    assert jobs(q="table 1") == [] and jobs(q="12 table") == []  # a whole number, and the words as typed
    assert jobs(q="peking duck") == ["bill"] and jobs(q="7%") == ["bill"]
    assert jobs(q="bill") == ["bill"] and jobs(q="ticket table 7") == [f"{drinks}:bar"]  # the log's own line
    assert jobs(q="table", type="kitchen") == [f"{food}:wok"]
    assert jobs(q="table", printer="bar") == ["bill", f"{drinks}:bar"]
    assert jobs(q="nobody ordered this") == [] and jobs(q="100%") == [] and jobs(q="t.ble") == []
    assert jobs(q="   ") == jobs()  # nothing typed is no search
    # where on the paper it was found, when the line of the log does not show it
    found = c.get("/print/log", params={"q": "duck"}, headers=boss).json()["prints"][0]
    assert found["found"] == "1 Peking Duck 48.00"
    assert "found" not in c.get("/print/log", params={"q": "table 12"}, headers=boss).json()["prints"][0]
    assert "found" not in c.get("/print/log", headers=boss).json()["prints"][0]


def test_the_types_on_the_wire():
    printing = service()
    c = hub(printing)
    boss = manager(c)
    key = send(c, "o1", CHICKEN, BEER)
    printing.queue(SAMPLE, printing.printers[1], job_id="bill")
    c.post("/print/log/reprint", json={"job": "bill"}, headers=boss)

    def read(**asked) -> dict:
        return c.get("/print/log", params=asked, headers=boss).json()

    assert read()["types"] == ["kitchen", "bar", "bill", "reprint", "other"]
    assert [p["job_id"] for p in read(type="kitchen")["prints"]] == [f"{key}:wok"]
    assert [p["job_id"] for p in read(type="bar")["prints"]] == [f"{key}:bar"]
    assert [p["sort"] for p in read(type="bill")["prints"]] == ["bill", "bill"]
    (again,) = read(type="reprint")["prints"]
    assert again["reprint_of"] == "bill" and again["places"] == []
    assert read(type="other")["prints"] == []
    assert [p["places"] for p in read(type="bar")["prints"]] == [["bar"]]
    # by type page by page, like the rest
    first = read(type="bill", limit=1)
    assert first["next"] is not None and len(read(type="bill", limit=1, before=first["next"])["prints"]) == 1
    assert c.get("/print/log", params={"type": "pizza"}, headers=boss).status_code == 422
    assert c.get("/print/log", params={"q": "x" * 101}, headers=boss).status_code == 422


def test_a_restaurant_with_no_bar_is_not_offered_its_tickets():
    printing = service()
    c = hub(printing)
    boss = manager(c)
    assert "bar" in c.get("/print/log", headers=boss).json()["types"]
    # the manager moves the drinks to the wok's station: no station is the bar's any more
    defs = copy.deepcopy(c.app.state.menu.defs)
    for kept in (defs.categories, defs.items):
        for code, thing in list(kept.items()):
            if thing.station == "bar":
                kept[code] = replace(thing, station="wok")
    c.app.state.menu.save(defs, actor="test")
    assert c.get("/print/log", headers=boss).json()["types"] == ["kitchen", "bill", "reprint", "other"]
    key = send(c, "o1", BEER)
    assert [e.places for e in printing.log.list() if e.job_id.startswith(key)] == [("kitchen",)]


# In the database -----------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_log_is_kept_in_postgresql():
    log = PgPrintLog(DSN)
    run = uuid.uuid4().hex  # this run's own printer, so what other runs left in the table is not in the way
    script = pages(render(DEMO, dialect=SCRIPT))
    try:
        for n in range(3):
            entry = Print(
                f"{run}:{n}", T0 + n * MINUTE, printer=run, name="Wok", address="10.0.0.1", title=f"Table {n}"
            )
            assert log.add(entry, script)
        assert not log.add(
            Print(f"{run}:0", T0, printer=run, name="Other", address="10.0.0.9"), []
        )  # one job, one print
        found, kept = log.get(f"{run}:1")
        assert (found.title, found.name, kept) == ("Table 1", "Wok", script)
        assert log.get(f"{run}:nothing") is None and log.change(f"{run}:nothing", lambda entry: entry) is None
        after = log.change(f"{run}:1", lambda entry: replace(entry, printed_ms=T0 + 5, printed_on="10.0.0.1"))
        assert after.printed and log.get(f"{run}:1")[0] == after
        assert [e.job_id for e in log.list(printer=run)] == [f"{run}:2", f"{run}:1", f"{run}:0"]
        assert [e.job_id for e in log.list(printer=run, trouble=True)] == [f"{run}:2", f"{run}:0"]
        page = log.list(printer=run, limit=2)
        assert [e.job_id for e in log.list(printer=run, before=(page[-1].at_ms, page[-1].job_id))] == [f"{run}:0"]
        again = PgPrintLog(DSN)  # the hub started again: it is all there
        try:
            assert again.get(f"{run}:1")[0] == after
        finally:
            again.close()
        # by type: none of these says where it is made, so they are not the kitchen's
        assert len(log.list(printer=run, type="other")) == 3 and log.list(printer=run, type="kitchen") == []
        bar = Print(f"{run}:bar", T0 + 9 * MINUTE, printer=run, name="Bar", address="10.0.0.2", places=("bar",))
        twice = replace(bar, job_id=f"{run}:twice", at_ms=T0 + 10 * MINUTE, reprint_of=bar.job_id, by="Mike")
        assert log.add(bar, script) and log.add(twice, script)
        assert [e.job_id for e in log.list(printer=run, type="bar")] == [twice.job_id, bar.job_id]
        assert [e.job_id for e in log.list(printer=run, type="reprint")] == [twice.job_id]
        assert log.list(printer=run, type="bill") == []
        # searched, the same as in memory: the words as typed, a number whole, what is typed never a pattern
        assert [e.job_id for e in log.list(printer=run, q="table 1")] == [f"{run}:1"]
        assert [e.job_id for e in log.list(printer=run, q="TABLE  2")] == [f"{run}:2"]
        assert [e.job_id for e in log.list(printer=run, q="mike")] == [twice.job_id]
        assert len(log.list(printer=run, q="kung pao")) == 5 and log.list(printer=run, q="pao kung") == []
        assert len(log.list(printer=run, q="(pt)")) == 5 and len(log.list(printer=run, q="#3412")) == 5
        assert log.list(printer=run, q="#341") == [] and log.list(printer=run, q="k.ng") == []
        assert log.list(printer=run, q="%") == [] and log.list(printer=run, q="_") == []
        assert [e.job_id for e in log.list(printer=run, q="kung pao", type="reprint")] == [twice.job_id]
        assert log.page(printer=run, q="kung pao", limit=1) == [(twice, "2 x Kung Pao Chicken (Pt) [s1]")]
        assert log.page(printer=run, q="table 1") == [(log.get(f"{run}:1")[0], "")]  # the log's own line has it
        assert log.page(printer=run, limit=1) == [(twice, "")]
        # a print an older hub wrote has neither its types nor its words: it is in no type and no search,
        # until the hub brings it up to date at its start
        old = Print(f"{run}:old", T0 + 20 * MINUTE, printer=run, name="Wok", address="10.0.0.1", title="Table 44")
        with log._pool.connection() as conn:
            conn.execute(
                "INSERT INTO print_log (job_id, at_ms, printer, trouble, entry, script) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (
                    old.job_id,
                    old.at_ms,
                    run,
                    True,
                    Jsonb({k: v for k, v in old.as_json().items() if k != "places"}),
                    Jsonb(script),
                ),
            )
        assert [e.job_id for e in log.list(printer=run, limit=1)] == [old.job_id]
        assert log.list(printer=run, q="table 44") == [] and old.job_id not in jobs_of(
            log.list(printer=run, type="other")
        )
        assert (
            log.restamp(lambda entry: replace(entry, places=("kitchen",)) if entry.job_id == old.job_id else entry) >= 1
        )
        assert log.restamp(lambda entry: entry) == 0  # once
        assert [e.places for e in log.list(printer=run, q="table 44")] == [("kitchen",)]
        assert [e.job_id for e in log.list(printer=run, type="kitchen")] == [old.job_id]
        assert log.get(f"{run}:1")[0] == after  # and what was up to date is as it was
    finally:
        with log._pool.connection() as conn:
            conn.execute("DELETE FROM print_log WHERE printer = %s", (run,))
        log.close()
