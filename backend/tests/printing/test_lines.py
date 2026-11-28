"""A line for each printer (`pos.printing.jobs.Lines`): one paper at a time, oldest first, printers side by
side; a printer that fails one paper has failed the ones behind it; and the wire itself (`send_raw`): a job
may take as long as it takes while the printer keeps taking it."""

from __future__ import annotations

import socket
import threading
import time
from dataclasses import replace

import pytest

from pos.printing.jobs import FALLBACK_AFTER, JobStore, Lines, PrintJob, send_raw
from pos.printing.service import Printer, PrintService
from pos.printing.ticket import DEMO


def wait_for(predicate, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.01)


class Wires:
    """The printers' side: what each was handed, in the order it took it; how many of the hub's writes it
    had on its hands at once; which printers do not answer (`down`); and which take a while over a job
    (`slow`, seconds), or wait to be told (`hold`, until `go` is set)."""

    def __init__(self) -> None:
        self.got: list[tuple[str, bytes]] = []
        self.tried: list[str] = []
        self.down: set[str] = set()
        self.slow: dict[str, float] = {}
        self.hold: set[str] = set()
        self.go = threading.Event()
        self.at_once: dict[str, int] = {}
        self.most_at_once: dict[str, int] = {}
        self._lock = threading.Lock()

    def __call__(self, address: str, data: bytes) -> None:
        with self._lock:
            self.tried.append(address)
            self.at_once[address] = self.at_once.get(address, 0) + 1
            self.most_at_once[address] = max(self.most_at_once.get(address, 0), self.at_once[address])
        try:
            if address in self.down:
                raise OSError("timed out")
            if address in self.hold:
                assert self.go.wait(5)
            time.sleep(self.slow.get(address, 0))
            with self._lock:
                self.got.append((address, data))
        finally:
            with self._lock:
                self.at_once[address] -= 1


WOK, BAR = "10.0.0.1", "10.0.0.2"


def queued(store: JobStore, printer: str, *names: str, fallback: str | None = None) -> list[PrintJob]:
    """Jobs for one printer in the order named; each one's paper is its name, and its fallback's says so."""
    fallbacks = lambda name: [(fallback, f"{name} at the fallback".encode())] if fallback else None  # noqa: E731
    return [store.create(printer, name.encode(), job_id=name, fallbacks=fallbacks(name)) for name in names]


# One at a time, in order, side by side ----------------------------------------------------------------------


def test_a_printer_is_handed_one_paper_at_a_time_in_the_order_they_were_queued():
    """What the restaurant's one kitchen printer gets for an order: every station's ticket at the same
    instant. It used to get them on a connection each, all at once."""
    wires, store = Wires(), JobStore()
    wires.slow[WOK] = 0.03
    lines = Lines(store, wires)
    names = ["kitchen", "broiler", "sushi", "takeout", "soup", "bill"]
    for job in queued(store, WOK, *names):
        lines.wake(job.printer)  # as `PrintService.queue` does for each job it makes
    wait_for(lambda: all(store.get(name).status == "done" for name in names))
    assert [data.decode() for _, data in wires.got] == names
    assert wires.most_at_once == {WOK: 1}
    assert [store.get(name).attempts for name in names] == [1] * len(names)
    wait_for(lambda: lines.working() == [])  # the line is nobody's once it is empty


def test_a_paper_queued_while_the_line_is_worked_goes_behind_the_others():
    wires, store = Wires(), JobStore()
    wires.hold.add(WOK)
    lines = Lines(store, wires)
    for job in queued(store, WOK, "first"):
        lines.wake(job.printer)
    wait_for(lambda: wires.tried == [WOK])  # the printer is busy with the first
    for job in queued(store, WOK, "second", "third"):
        lines.wake(job.printer)
    assert lines.working() == [WOK] and wires.most_at_once == {WOK: 1}
    wires.go.set()
    wait_for(lambda: len(wires.got) == 3)
    assert [data.decode() for _, data in wires.got] == ["first", "second", "third"]


def test_printers_print_side_by_side_and_a_slow_one_keeps_only_its_own_waiting():
    wires, store = Wires(), JobStore()
    wires.hold.add(WOK)  # the wok's printer has stopped taking anything
    lines = Lines(store, wires)
    for job in [*queued(store, WOK, "wok 1", "wok 2"), *queued(store, BAR, "bar 1", "bar 2")]:
        lines.wake(job.printer)
    wait_for(lambda: [data.decode() for _, data in wires.got] == ["bar 1", "bar 2"])
    assert store.get("wok 1").status == "leased" and store.get("wok 2").status == "queued"
    wires.go.set()
    wait_for(lambda: len(wires.got) == 4)
    assert [data.decode() for address, data in wires.got if address == WOK] == ["wok 1", "wok 2"]


# A printer that fails ---------------------------------------------------------------------------------------


def test_a_printer_that_fails_a_paper_has_failed_the_ones_behind_it():
    """Down, it is tried once a round, not once for every paper that waits: they would all meet the same.
    So two tries in all, and everything in its line is on its way to the fallback together."""
    wires, store = Wires(), JobStore()
    wires.down.add(WOK)
    lines = Lines(store, wires)
    jobs = queued(store, WOK, "a", "b", "c", fallback=BAR)
    told: list[tuple[str, str, str]] = []
    store.watch = lambda job, what, detail: told.append((job.job_id, what, detail))

    assert lines.sweep() == 0
    assert wires.tried == [WOK]  # one try at the printer
    assert [(j.attempts, j.failures, j.last_error, j.printer) for j in jobs] == [(1, 1, "timed out", WOK)] * 3
    assert told == [("a", "failed", "timed out"), ("b", "failed", "timed out"), ("c", "failed", "timed out")]

    for _ in range(FALLBACK_AFTER - 1):
        assert lines.sweep() == 0
    assert wires.tried == [WOK] * FALLBACK_AFTER
    assert [(j.printer, j.moved, j.status) for j in jobs] == [(BAR, 1, "queued")] * 3  # all three, together
    assert lines.sweep() == 3
    assert wires.got == [(BAR, f"{name} at the fallback".encode()) for name in "abc"]


def test_a_line_stops_at_a_failure_and_goes_on_from_there_when_woken():
    wires, store = Wires(), JobStore()
    lines = Lines(store, wires)
    jobs = queued(store, WOK, "a", "b", "c")  # no fallback: they wait for their own printer
    wires.down.add(WOK)
    lines.wake(WOK)
    wait_for(lambda: lines.working() == [] and wires.tried == [WOK])
    assert [(j.status, j.attempts) for j in jobs] == [("queued", 1)] * 3
    time.sleep(0.05)
    assert wires.tried == [WOK]  # a line does not go round by itself: the hub's loop wakes it
    wires.down.clear()
    lines.wake_all()
    wait_for(lambda: all(j.status == "done" for j in jobs))
    assert [data.decode() for _, data in wires.got] == ["a", "b", "c"]
    assert [j.attempts for j in jobs] == [2, 2, 2]


def test_papers_that_move_to_a_fallback_wake_its_line():
    wires, store = Wires(), JobStore()
    wires.down.add(WOK)
    lines = Lines(store, wires)
    jobs = queued(store, WOK, "a", "b", fallback=BAR)
    for _ in range(FALLBACK_AFTER):
        lines.wake_all()  # the hub's loop, every few seconds
        wait_for(lambda: WOK not in lines.working())
    wait_for(lambda: all(j.status == "done" for j in jobs))  # nobody woke the bar's line but the move itself
    assert wires.got == [(BAR, b"a at the fallback"), (BAR, b"b at the fallback")]
    assert wires.tried == [WOK] * FALLBACK_AFTER + [BAR, BAR]


def test_a_line_passes_over_what_a_relay_is_printing():
    now = [100.0]
    wires, store = Wires(), JobStore(clock=lambda: now[0])
    lines = Lines(store, wires)
    a, b = queued(store, WOK, "a", "b")
    assert store.claim([WOK], relay="ipad1") is a
    assert lines.sweep() == 1 and wires.got == [(WOK, b"b")]
    assert a.status == "leased" and a.leased_to == "ipad1" and a.attempts == 1
    now[0] += 9  # the relay went quiet: the hub's line has it after all
    assert lines.sweep() == 1 and wires.got[-1] == (WOK, b"a")


def test_a_sweep_gives_each_paper_one_go_and_what_moves_waits_for_the_next():
    wires, store = Wires(), JobStore()
    wires.down.add(WOK)
    lines = Lines(store, wires)
    wok = queued(store, WOK, "w1", "w2", fallback=BAR)
    bar = queued(store, BAR, "b1")
    assert lines.sweep() == 1 and wires.got == [(BAR, b"b1")]  # the bar's own, while the wok is down
    assert lines.sweep() == 0 and [j.printer for j in wok] == [BAR, BAR]
    assert [address for address, _ in wires.got] == [BAR]  # moved in this sweep: printed in the next
    assert lines.sweep() == 2 and bar[0].attempts == 1


def test_many_hands_queue_at_once_and_every_paper_still_comes_out_once_and_in_order():
    """Screens, the online orders and the hub's own loop all queue and wake at the same time, and the
    printers fail now and then. Whatever the timing: every paper once, each printer's in the order they
    were queued, and never two at a printer at once."""
    printers = [WOK, BAR, "10.0.0.3"]
    store, lock = JobStore(), threading.Lock()
    got: dict[str, list[str]] = {printer: [] for printer in printers}
    at_once, most, tries = dict.fromkeys(printers, 0), dict.fromkeys(printers, 0), [0]

    def send(printer: str, data: bytes) -> None:
        with lock:
            at_once[printer] += 1
            most[printer] = max(most[printer], at_once[printer])
            tries[0] += 1
            fails = tries[0] % 7 == 0  # every seventh try, whichever printer it is at
        time.sleep(0.0005)
        with lock:
            at_once[printer] -= 1
            if not fails:
                got[printer].append(data.decode())
        if fails:
            raise OSError("timed out")

    lines = Lines(store, send)
    queued_at: dict[str, list[str]] = {printer: [] for printer in printers}
    queueing = threading.Lock()

    def screen(n: int) -> None:
        for i in range(60):
            printer = printers[(n + i) % len(printers)]
            with queueing:  # the order they were queued in is the order they are written down in here
                name = f"{n}-{i}"
                store.create(printer, name.encode(), job_id=name)
                queued_at[printer].append(name)
            lines.wake(printer)

    screens = [threading.Thread(target=screen, args=(n,)) for n in range(6)]
    for hand in screens:
        hand.start()
    deadline = time.monotonic() + 20
    while any(hand.is_alive() for hand in screens) or any(job.status != "done" for job in store.all()):
        assert time.monotonic() < deadline, "timed out"
        lines.wake_all()  # the hub's loop: what a failed printer left waiting goes on
        time.sleep(0.002)
    assert got == queued_at
    assert most == dict.fromkeys(printers, 1)
    wait_for(lambda: lines.working() == [])


# The service ------------------------------------------------------------------------------------------------


def test_the_tickets_of_one_send_come_out_one_at_a_time_in_the_order_of_the_stations():
    wires = Wires()
    wires.slow[WOK] = 0.02
    stations = ("kitchen", "broiler", "sushi", "takeout")
    printer = Printer("kitchen", WOK, stations=stations, tickets="each")
    service = PrintService([printer], send=wires)
    jobs = [
        service.queue(replace(DEMO, station=station.upper()), printer, job_id=f"fire:kitchen:{station}")
        for station in stations
    ]
    wait_for(lambda: all(job.status == "done" for job in jobs))
    assert len({job.data for job in jobs}) == len(jobs)  # each headed with its own station
    assert [data for _, data in wires.got] == [job.data for job in jobs]
    assert wires.most_at_once == {WOK: 1}


def test_the_hubs_loop_wakes_the_lines_and_waits_for_no_printer():
    wires = Wires()
    wires.hold.add(WOK)
    service = PrintService([Printer("wok", WOK), Printer("bar", BAR)], send=wires)
    service._start = lambda job: None  # queued, and nobody at the lines yet
    service.queue(DEMO, service.printers[0], job_id="wok")
    service.queue(DEMO, service.printers[1], job_id="bar")
    began = time.monotonic()
    service.wake_lines()  # what the loop does every few seconds
    assert time.monotonic() - began < 1  # it is back at once, with the wok's printer still on the first paper
    wait_for(lambda: service.store.get("bar").status == "done")
    assert service.store.get("wok").status == "leased"
    wires.go.set()
    wait_for(lambda: service.store.get("wok").status == "done")
    assert not PrintService([Printer("wok", WOK)], direct=False, send=wires).lines.working()


# The wire ---------------------------------------------------------------------------------------------------


class Reader:
    """A printer that reads at its own pace: `chunk` bytes, then `pause` seconds, until `stop_after` bytes
    when it stops reading altogether (it is out of paper); `chatter` has it send a status byte every few
    hundredths of a second for as long as the connection lasts."""

    def __init__(self, *, chunk: int = 65536, pause: float = 0.0, stop_after: int | None = None, chatter: bool = False):
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)  # a printer's small buffer
        self._server.bind(("127.0.0.1", 0))
        self._server.listen()
        self.address = f"127.0.0.1:{self._server.getsockname()[1]}"
        self.chunk, self.pause, self.stop_after, self.chatter = chunk, pause, stop_after, chatter
        self.read = 0
        self.done = threading.Event()
        self._stop = threading.Event()
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        try:
            conn, _ = self._server.accept()
        except OSError:
            return
        with conn:
            conn.settimeout(0.05)
            while not self._stop.is_set():
                if self.chatter:
                    try:
                        conn.sendall(b"\x14")
                    except OSError:
                        break
                if self.stop_after is not None and self.read >= self.stop_after:
                    time.sleep(0.02)
                    continue
                try:
                    got = conn.recv(self.chunk)
                except TimeoutError:
                    continue
                except OSError:
                    break
                if not got:
                    if not self.chatter:
                        break
                    time.sleep(0.02)
                    continue
                self.read += len(got)
                time.sleep(self.pause)
        self.done.set()

    def close(self) -> None:
        self._stop.set()
        self._server.close()


LONG = bytes(4_000_000)  # far more than the wire holds by itself: the hub waits for the printer to read it


@pytest.fixture
def lan(monkeypatch):
    """The hub's end of the wire as it is towards a printer on the LAN: it holds some tens of kilobytes of
    a job that the printer has not taken yet. Towards a pretend printer on the same machine it would hold
    megabytes, and take a whole job off the hub's hands whether or not anybody reads it."""

    def short(address, timeout=None):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
        sock.settimeout(timeout)
        sock.connect(address)
        return sock

    monkeypatch.setattr(socket, "create_connection", short)


def test_a_long_job_takes_as_long_as_it_takes_while_the_printer_keeps_taking_it(lan):
    """The time limit is on standing still. A long ticket goes in at the speed of the paper; counted as
    failed for being slow, it would be sent again whole and come out twice."""
    printer = Reader(chunk=8192, pause=0.001)  # a little at a time without a stop: half a second at the least
    try:
        began = time.monotonic()
        send_raw(printer.address, LONG, timeout=0.25, linger=0.2)
        assert time.monotonic() - began > 0.25  # longer than the limit, and no failure
        assert printer.done.wait(5) and printer.read == len(LONG)
    finally:
        printer.close()


def test_a_printer_that_stops_taking_the_job_is_a_failure(lan):
    printer = Reader(stop_after=100_000)
    try:
        began = time.monotonic()
        with pytest.raises(OSError, match="timed out"):
            send_raw(printer.address, LONG, timeout=0.3, linger=0.2)
        assert time.monotonic() - began < 3
    finally:
        printer.close()


def test_a_printer_that_never_stops_talking_is_not_listened_to_for_good():
    printer = Reader(chatter=True)
    try:
        began = time.monotonic()
        send_raw(printer.address, b"ticket", timeout=1, linger=0.3, longest=0.6)
        assert 0.5 < time.monotonic() - began < 3
        assert printer.read == len(b"ticket")
    finally:
        printer.close()
