"""What a customer wrote for the whole order (an online order's instructions) prints on every ticket a cook
works from, under a bar of its own, and on the pack sheet; and a `notice` is a slip that is no order."""

from __future__ import annotations

from datetime import datetime

import pytest

from pos.printing.pack import PackSheet, render_pack
from pos.printing.ticket import NOTED, Ticket, TicketLine, render

from .fake_printer import decode

AT = datetime(2027, 1, 15, 18, 1)
BEER = TicketLine(qty=1, label="Tsingtao")
NOTE = "No onions in anything, please"


def paper(ticket: Ticket) -> list[str]:
    return decode(render(ticket)).text


def ticket(kind: str, **more) -> Ticket:
    return Ticket(station="Bar", kind=kind, order_id="gf-301", ticket_no=4, table="", lines=(BEER,), at=AT, **more)


@pytest.mark.parametrize("kind", sorted(NOTED))
def test_the_customer_s_note_is_on_every_ticket_a_cook_works_from_before_the_dishes(kind):
    lines = paper(ticket(kind, note=NOTE))
    bar = next(n for n, line in enumerate(lines) if line.strip() == "CUSTOMER'S NOTE")
    assert lines[bar + 1] == NOTE
    assert bar < next(n for n, line in enumerate(lines) if "Tsingtao" in line)


@pytest.mark.parametrize("kind", ["void", "moved", "bag"])
def test_a_slip_no_dish_is_cooked_from_does_not_repeat_it(kind):
    assert "CUSTOMER'S NOTE" not in " ".join(paper(ticket(kind, note=NOTE)))


def test_an_order_with_no_note_has_no_bar_for_one():
    assert "CUSTOMER'S NOTE" not in " ".join(paper(ticket("new")))


def test_a_notice_is_its_headline_and_what_there_is_to_say():
    slip = Ticket(
        station="Takeout",
        kind="notice",
        order_id="online:gloriafood:301",
        ticket_no=9,
        table="",
        lines=(),
        at=AT,
        words=("NOT ON THE POS", "Online order 301: it has no dishes.", "Look at it in GloriaFood's own app."),
    )
    lines = paper(slip)
    assert lines[0] == "*** LOOK *** TAKEOUT" and lines[1].strip() == "18:01"
    assert [line.strip() for line in lines if "POS" in line or "301" in line or "app" in line] == [
        "NOT ON THE POS",
        "Online order 301: it has no dishes.",
        "Look at it in GloriaFood's own app.",
        "301  2027-01-15 18:01:00",
    ]
    assert not [line for line in lines if line.startswith("#")]  # no number that could be taken for an order's
    assert decode(render(slip)).cuts == 1
    assert render(slip, dialect="star")  # a Star printer draws it as it draws a ticket


def test_the_pack_sheet_says_what_the_customer_wrote():
    sheet = PackSheet(order_id="gf-301", lines=(BEER,), count=1, customer="Pat", said=NOTE, at=AT)
    lines = decode(render_pack(sheet)).text
    bar = next(n for n, line in enumerate(lines) if line.strip() == "CUSTOMER'S NOTE")
    assert lines[bar + 1] == NOTE
    assert "CUSTOMER'S NOTE" not in " ".join(decode(render_pack(PackSheet("gf-301", (BEER,), count=1, at=AT))).text)
