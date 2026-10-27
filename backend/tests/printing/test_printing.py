from __future__ import annotations

import socket
import time

import pytest

from pos.printing.escpos import Builder, find_font, is_plain
from pos.printing.jobs import JobStore, send_raw
from pos.printing.ticket import DEMO, Ticket, TicketLine, drawer_kick, render

from .fake_printer import FakePrinter, decode


@pytest.fixture
def printer():
    fake = FakePrinter()
    yield fake
    fake.close()


def test_plain_text_goes_as_text_and_chinese_as_image():
    job = bytes(Builder().line("Table 12", bold=True).line("左宗鸡 (Qt)", big=True).cut())
    out = decode(job)
    assert out.text == ["Table 12"]
    assert len(out.images) == 1 and out.images[0][0] == 576 and out.images[0][1] > 20
    assert "左宗鸡".encode() not in job  # never raw UTF-8 on the wire
    assert out.cuts == 1 and not out.unknown


def test_narrow_paper_and_columns():
    b = Builder(dots=384)
    b.columns("#3412  dine in", "16:42")
    line = decode(bytes(b)).text[0]
    assert len(line) == 32 and line.startswith("#3412") and line.endswith("16:42")


def test_demo_ticket_renders_once_and_the_same_every_time():
    first = render(DEMO, beep=False)
    assert first == render(DEMO, beep=False)
    out = decode(first)
    assert out.cuts == 1 and not out.unknown
    assert any("Table 12  4 guests" in t for t in out.text)
    assert "2 x Kung Pao Chicken" in out.text and "  (Pt) [s1]" in out.text  # wrapped double-width line
    assert any("allergy: peanut" in t for t in out.text)
    assert len(out.images) >= 4  # the Chinese label lines and modifiers


def test_modify_and_void_tickets_say_so():
    base = Ticket(
        station="Wok",
        kind="modify",
        order_id="o1",
        ticket_no=7,
        table="3",
        lines=(TicketLine(1, "Soup", changed=True),),
    )
    out = decode(render(base))
    assert out.text[0] == "*** MODIFY *** WOK" and any(t.startswith("CHG  1 x Soup") for t in out.text)
    assert out.beeps == 1  # a modify ticket beeps so the cook looks
    void = Ticket(
        station="Wok", kind="void", order_id="o1", ticket_no=7, table="3", lines=(TicketLine(1, "Soup", void=True),)
    )
    assert any(t.startswith("VOID 1 x Soup") for t in decode(render(void, beep=False)).text)


def test_long_big_lines_wrap_at_a_word():
    out = decode(bytes(Builder().line("2 x Kung Pao Chicken (Pt) [s1]", big=True)))
    assert out.text == ["2 x Kung Pao Chicken", "  (Pt) [s1]"]


def test_drawer_kick_bytes():
    out = decode(drawer_kick())
    assert out.drawer_pulses == 1 and not out.text and not out.images


def test_hub_path_prints_directly_and_marks_the_job_done(printer):
    store = JobStore()
    job = store.create(printer.address, render(DEMO))
    assert store.deliver_direct(job) is True
    time.sleep(0.05)
    assert printer.jobs == [job.data] and job.status == "done" and job.done_by == "hub"
    assert store.claim([printer.address], relay="ipad1") is None  # nothing left for a relay


def test_relay_path_prints_once_even_when_the_relay_retries(printer):
    now = [100.0]
    store = JobStore(clock=lambda: now[0], lease=8.0)
    job = store.create(printer.address, render(DEMO))

    claimed = store.claim([printer.address], relay="ipad1")
    assert claimed is job and job.status == "leased" and job.leased_to == "ipad1"
    assert store.claim([printer.address], relay="mac1") is None  # leased to ipad1 for 8 s
    send_raw(claimed.printer, claimed.data)
    store.done(job.job_id, by="ipad1")
    store.done(job.job_id, by="ipad1")  # a retried report changes nothing
    time.sleep(0.05)
    assert len(printer.jobs) == 1 and job.status == "done"


def test_a_quiet_relay_loses_the_job_and_a_failed_relay_returns_it(printer):
    now = [100.0]
    store = JobStore(clock=lambda: now[0], lease=8.0)
    job = store.create(printer.address, b"x")
    assert store.claim([printer.address], relay="ipad1") is job
    now[0] += 9  # the lease ran out with no report
    assert store.claim([printer.address], relay="mac1") is job and job.leased_to == "mac1" and job.attempts == 2
    store.failed(job.job_id, by="mac1", error="connection refused")
    assert job.status == "queued" and store.claim([printer.address], relay="ipad1") is job


def test_hub_path_falls_back_when_the_printer_is_unreachable():
    store = JobStore()
    dead = socket.create_server(("127.0.0.1", 0)).getsockname()[1]  # a port nothing listens on after close
    job = store.create(f"127.0.0.1:{dead}", b"x")
    assert store.deliver_direct(job) is False
    assert job.status == "queued" and job.last_error
    assert store.pending() == [job]


def test_same_job_id_twice_is_one_job():
    store = JobStore()
    a = store.create("p", b"x", job_id="order1-wok-3412")
    b = store.create("p", b"x", job_id="order1-wok-3412")
    assert a is b and len(store.pending()) == 1


def test_font_and_plain_detection():
    assert is_plain("Table 12") and not is_plain("左宗鸡") and not is_plain("café")
    assert find_font() is None or find_font().endswith((".ttc", ".ttf"))


def test_star_dialect_uses_star_bytes():
    from pos.printing.star import RASTER_IN, RASTER_OUT, StarBuilder

    job = render(DEMO, dialect="star")
    assert job.startswith(b"\x1b@")
    assert b"\x1b\x1da\x01" in job  # Star centre
    assert b"\x1bi\x01\x01" in job  # Star double size
    assert job.count(RASTER_IN) == job.count(RASTER_OUT) >= 4  # one raster block per Chinese line
    assert b"\x1dv0" not in job and b"\x1dV" not in job  # no Epson raster or cut
    assert job.endswith(b"\x1bd\x03")  # partial cut
    assert "左宗鸡".encode() not in job
    assert render(DEMO, dialect="star") == job
    assert drawer_kick(dialect="star").endswith(b"\x07")
    assert bytes(StarBuilder().line("x").beep()) == bytes(StarBuilder().line("x"))  # no buzzer bytes yet


def test_star_raster_rows_are_whole():
    from pos.printing.star import RASTER_IN, RASTER_OUT, StarBuilder

    job = bytes(StarBuilder(dots=384).line("麻婆豆腐"))
    body = job.split(RASTER_IN, 1)[1].split(RASTER_OUT, 1)[0]
    rows = 0
    while body:
        assert body[0:1] == b"b" and body[1] == 48 and body[2] == 0  # 384 dots = 48 bytes a row
        body = body[51:]
        rows += 1
    assert rows > 20


def test_ascii_demo_has_no_graphics():
    from pos.printing.ticket import ascii_only

    plain = ascii_only(DEMO)
    assert plain.lines[0].label == "[CJK]" and plain.lines[1].label == "Kung Pao Chicken (Pt)"
    out = decode(render(plain, beep=False))
    assert not out.images and out.cuts == 1 and not out.unknown


def test_star_raster_blocks_disable_the_end_of_page_cut():
    from pos.printing.star import RASTER_IN

    assert b"\x1b*rE0\x00" in RASTER_IN and b"\x1b*rF0\x00" in RASTER_IN
    job = render(DEMO, dialect="star", beep=False)
    assert job.count(b"\x1bd\x03") == 1  # one cut, at the end
