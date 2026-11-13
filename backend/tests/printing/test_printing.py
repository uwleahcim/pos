from __future__ import annotations

import socket
import time
from dataclasses import replace

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


def test_star_ticket_is_one_raster_block_with_one_cut():
    from PIL import Image

    from pos.printing.star import RASTER_IN, RASTER_OUT, StarBuilder

    job = render(DEMO, dialect="star")
    assert job.startswith(b"\x1b@" + RASTER_IN) and job.endswith(RASTER_OUT)
    assert job.count(RASTER_IN) == 1 and job.count(RASTER_OUT) == 1  # enter raster mode once: one cut
    assert "左宗鸡".encode() not in job and b"Kung Pao" not in job  # everything is drawn
    assert render(DEMO, dialect="star") == job
    body = job[len(b"\x1b@" + RASTER_IN) : -len(RASTER_OUT)]
    rows = 0
    while body:
        assert body[0:1] == b"b" and body[1] == 72 and body[2] == 0  # 576 dots = 72 bytes a row
        body = body[75:]
        rows += 1
    assert 400 < rows < 2000
    # the drawer is line-mode bytes after the image; a drawer-only job has no raster block at all
    assert drawer_kick(dialect="star") == b"\x1b@\x1b\x07\x14\x14\x07"
    assert RASTER_IN not in drawer_kick(dialect="star")
    assert bytes(StarBuilder().line("x").beep()) == bytes(StarBuilder().line("x"))
    # columns: something drawn at both edges of the strip
    strip = bytes(StarBuilder(dots=384).columns("#3412  dine in", "16:42"))
    rowdata = strip[len(b"\x1b@" + RASTER_IN) : -len(RASTER_OUT)]
    img = Image.frombytes(
        "1",
        (384, len(rowdata) // 51),
        bytes(255 - b for i in range(0, len(rowdata), 51) for b in rowdata[i + 3 : i + 51]),
    )
    cols = [x for x in range(384) if any(img.getpixel((x, y)) == 0 for y in range(img.height))]
    assert cols[0] < 10 and cols[-1] > 370


def test_ascii_demo_has_no_graphics():
    from pos.printing.ticket import ascii_only

    plain = ascii_only(DEMO)
    assert plain.lines[0].label == "[CJK]" and plain.lines[1].label == "Kung Pao Chicken (Pt)"
    out = decode(render(plain, beep=False))
    assert not out.images and out.cuts == 1 and not out.unknown


def test_a_choice_that_is_a_dish_prints_under_the_dish_it_came_with():
    """The soup of a lunch special at the soup station says which special it belongs to."""
    ticket = replace(
        DEMO,
        lines=(TicketLine(1, "Miso Soup", header="L01 Sweet & Sour Chicken"), TicketLine(2, "Wonton Soup")),
    )
    text = decode(render(ticket, beep=False)).text
    assert "    with L01 Sweet & Sour Chicken" in text
    assert text.index("1 x Miso Soup") < text.index("    with L01 Sweet & Sour Chicken") < text.index("2 x Wonton Soup")


def test_a_choice_s_own_choices_print_on_the_lines_under_it_one_step_further_in():
    """The spicy mayo on a roll of a combination stands under that roll, not in brackets after it."""
    line = TicketLine(
        1,
        "Maki Combo",
        modifiers=("Kappa Maki", "Tekka Maki", "Spicy mayo", "No wasabi", "Miso Soup"),
        depths=(0, 0, 1, 1, 0),
    )
    old = TicketLine(1, "Lo Mein", modifiers=("Add shrimp", "Wings (Extra spicy)"))  # a line sold before this
    text = decode(render(replace(DEMO, lines=(line, old)), beep=False)).text
    rows = [row for row in text if "+ " in row]
    assert rows == [
        "    + Kappa Maki",
        "    + Tekka Maki",
        "        + Spicy mayo",
        "        + No wasabi",
        "    + Miso Soup",
        "    + Add shrimp",
        "    + Wings (Extra spicy)",
    ]
