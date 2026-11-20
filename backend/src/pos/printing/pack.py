"""The pack sheet of a to-go order: the whole order as it stands, to pack the food by and check it off.

A kitchen ticket says what one send has a station cooking. A catering order is packed from many tickets, by
somebody who has to know more than the dishes: who it is for and when, how many it feeds, whether it is
picked up or driven to an address, what else was promised ("set up by 11:30, side door"), and whether the
money was collected. The pack sheet is that on one paper, with a box to tick beside every dish and a line
for whoever packed it and whoever checked it.

A `PackSheet` is data, like a `Ticket` or a `Bill`: the print service makes one from an order
(`PrintService.pack_sheet`) and `render_pack` turns it into the bytes for a printer in its own language. It
always says the order as the log has it when it prints: a dish added since the tickets went out is on it,
one taken off is not. The dishes nobody sent to the kitchen stand apart under a black bar, since no ticket
of them exists and nobody is cooking them.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from .escpos import Builder
from .ticket import DIALECTS, Money, TicketLine

HANDOVER_WORDS = {"pickup": "PICKUP", "delivery": "DELIVERY"}


@dataclass(frozen=True)
class PackSheet:
    order_id: str
    lines: tuple[TicketLine, ...]  # the dishes the kitchen has, as the takeout station reads them
    unsent: tuple[TicketLine, ...] = ()  # the dishes on the order nobody sent: no ticket, nobody cooking
    count: int = 0  # how many dishes were rung in, a platter once, the ones not sent with them
    order_no: int | None = None
    customer: str = ""
    phone: str = ""
    channel: str = ""  # counter | phone | catering | ...
    promised: datetime | None = None
    guests: int | None = None  # how many the event feeds
    handover: str = ""  # pickup | delivery, or nothing said
    address: str = ""
    note: str = ""  # the note for the event
    said: str = ""  # what the customer wrote for the whole order (an online order's instructions)
    allergies: tuple[str, ...] = ()
    money: Money | None = None
    bag: tuple[str, ...] | None = None  # as on the takeout station's ticket
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # the printer this was for, on the copy a fallback printer gets


def _many(count: int, one: str, many: str | None = None) -> str:
    return f"{count} {one if count == 1 else many or one + 's'}"


def _dish(b: Builder, line: TicketLine) -> None:
    seat = f" [s{line.seat}]" if line.seat else ""
    b.line(f"[ ] {line.qty} x {line.label}{seat}", big=True)
    if line.header:
        b.line(f"        with {line.header}")
    for i, mod in enumerate(line.modifiers):
        depth = line.depths[i] if i < len(line.depths) else 0
        b.line(f"{'    ' * (depth + 2)}+ {mod}")
    if line.note:
        b.line(f"        ** {line.note} **", bold=True)
    if line.allergy:
        b.line(f"        ** ALLERGY: {line.allergy} **", bold=True)


def render_pack(sheet: PackSheet, *, dots: int = 576, font: str | None = None, dialect: str = "escpos") -> bytes:
    """The print job for one pack sheet (`dialect` escpos or star). Deterministic for the same inputs."""
    b = DIALECTS[dialect](dots=dots, font=font)
    if sheet.reprinted_from:
        b.line(f"{sheet.reprinted_from} printer down, printed here".upper(), center=True, bold=True, invert=True)
    b.line("PACK SHEET", big=True, bold=True, center=True)
    number = f"#{sheet.order_no}  " if sheet.order_no is not None else ""
    if number or sheet.customer:
        b.line(f"{number}{sheet.customer}".strip().upper(), big=True, bold=True)
    if sheet.promised is not None:
        # always with its day: a sheet printed on Thursday to go over the order is for Saturday all the same
        b.line(f"FOR {sheet.promised:%H:%M}  {sheet.promised:%a %b} {sheet.promised.day}".upper(), bold=True)
    how = HANDOVER_WORDS.get(sheet.handover, "")
    if how:
        b.line(how, big=True, bold=True)
    if sheet.address:
        b.line(sheet.address, bold=True)
    said = [sheet.channel.replace("_", " ").capitalize()] if sheet.channel else []
    if sheet.guests:
        said.append(_many(sheet.guests, "guest"))
    if sheet.phone:
        said.append(sheet.phone)
    if said:
        b.line("  ".join(said), bold=True)
    if sheet.note:
        b.line(f"** {sheet.note} **", bold=True)
    if sheet.said:
        b.line("CUSTOMER'S NOTE", bold=True, center=True, invert=True)
        b.line(sheet.said, bold=True)
    if sheet.money is not None:
        b.line(sheet.money.words, big=True, bold=True, center=sheet.money.owing, invert=sheet.money.owing)
        if sheet.money.detail:
            b.line(sheet.money.detail, bold=True)
    b.rule()
    if sheet.allergies:
        b.line("ALLERGY", big=True, bold=True, center=True, invert=True)
        for told in sheet.allergies:
            b.line(told, bold=True)
        b.rule()
    for line in sheet.lines:
        _dish(b, line)
    if sheet.unsent:
        # No ticket of these is in the kitchen: whoever packs must not wait for them, and somebody must send
        # them or take them off.
        if sheet.lines:
            b.rule()
        b.line("NOT SENT TO THE KITCHEN", bold=True, center=True, invert=True)
        for line in sheet.unsent:
            _dish(b, line)
    b.rule()
    b.line(f"{_many(sheet.count, 'dish', 'dishes')} to pack", bold=True)
    if sheet.bag is not None:
        b.line("ALSO IN THE BAG", bold=True)
        for words in sheet.bag or ("NOTHING",):
            b.line(words, big=True)
    b.rule()
    b.feed(1)
    b.line("Packed by  ______________________________")
    b.feed(1)
    b.line("Checked by ______________________________")
    b.rule()
    b.line(f"{sheet.order_id[-8:]}  {sheet.at.strftime('%Y-%m-%d %H:%M:%S')}")
    b.feed(2).cut()
    return bytes(b)
