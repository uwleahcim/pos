"""Kitchen tickets and receipts as data, rendered to ESC/POS or StarPRNT by `render`.

The backend builds a `Ticket` from an order and its routing; the apps never see ESC/POS and never decide
what a ticket says. A modify ticket is a new ticket with `kind="modify"`, never a silent change.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime

from .escpos import Builder
from .star import StarBuilder

DIALECTS: dict[str, type[Builder]] = {"escpos": Builder, "star": StarBuilder}


@dataclass(frozen=True)
class TicketLine:
    qty: int
    label: str  # the kitchen label in the station's language, e.g. "左宗鸡 (Qt)"
    modifiers: tuple[str, ...] = ()  # e.g. ("加辣", "糙米", "加虾")
    note: str = ""
    seat: int | None = None
    void: bool = False
    changed: bool = False  # modified after the course was fired
    header: str | None = None  # the dish this one is part of, when it is a combo's or a lunch special's choice


@dataclass(frozen=True)
class Ticket:
    station: str  # "Wok"
    kind: str  # new | modify | void | reprint
    order_id: str
    ticket_no: int
    table: str
    lines: tuple[TicketLine, ...]
    server: str = ""
    order_type: str = "dine in"  # dine in | takeout | delivery | phone | catering
    guests: int | None = None
    course: str | None = None
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # "Wok" on a backup printer's copy
    late: datetime | None = None  # when the operator took it, if it reached the backend late (ADR 6)
    order_no: int | None = None  # counter mode: the number called at the shelf
    customer: str = ""  # the name on a takeout order
    channel: str = ""  # counter | phone | online | delivery | catering
    promised: datetime | None = None  # a takeout order's promised time


def render(
    ticket: Ticket, *, dots: int = 576, font: str | None = None, beep: bool = True, dialect: str = "escpos"
) -> bytes:
    """The print job for one ticket (`dialect` escpos or star). Deterministic for the same inputs."""
    b = DIALECTS[dialect](dots=dots, font=font)
    if beep:
        b.beep(3 if ticket.kind in ("modify", "void") or ticket.late else 1)
    header = {
        "new": ticket.station,
        "modify": f"*** MODIFY *** {ticket.station}",
        "void": f"*** VOID *** {ticket.station}",
        "reprint": f"REPRINT {ticket.station}",
    }
    if ticket.late:
        # Taken while no backend answered (a terminal capturing only) and printed when one returned: the
        # kitchen may have cooked it from a handwritten note already, so the ticket says so first.
        b.line("*** LATE ***", big=True, bold=True, center=True, invert=True)
    b.line(header.get(ticket.kind, ticket.station).upper(), big=True, bold=True, center=True)
    if ticket.late:
        b.line(
            f"taken {ticket.late.strftime('%H:%M')} offline, printed {ticket.at.strftime('%H:%M')}",
            center=True,
            bold=True,
        )
    if ticket.reprinted_from:
        b.line(f"reprinted from {ticket.reprinted_from}", center=True, bold=True)
    b.columns(f"#{ticket.ticket_no}  {ticket.order_type}", ticket.at.strftime("%H:%M"))
    if ticket.order_no is not None or ticket.customer:
        # A takeout order is called by number and name at the shelf, so they are the biggest thing on it.
        number = f"#{ticket.order_no}  " if ticket.order_no is not None else ""
        b.line(f"{number}{ticket.customer}".strip().upper(), big=True, bold=True)
    if ticket.promised is not None:
        b.line(f"READY BY {ticket.promised:%H:%M}", bold=True)
    if ticket.table:
        guests = f"  {ticket.guests} guests" if ticket.guests else ""
        b.line(f"Table {ticket.table}{guests}", bold=True)
    elif ticket.channel:
        b.line(ticket.channel.replace("_", " ").capitalize(), bold=True)
    else:
        b.line("No table", bold=True)
    if ticket.server:
        b.line(f"Server {ticket.server}")
    if ticket.course:
        b.line(f"Course: {ticket.course}")
    b.rule()
    for line in ticket.lines:
        # A void is printed white on black, the dish and its choices, so nobody cooks it by mistake.
        prefix = "VOID " if line.void else ("CHG  " if line.changed else "")
        seat = f" [s{line.seat}]" if line.seat else ""
        inv = line.void
        b.line(f"{prefix}{line.qty} x {line.label}{seat}", big=True, bold=line.void or line.changed, invert=inv)
        if line.header:
            b.line(f"    with {line.header}", invert=inv)
        for mod in line.modifiers:
            b.line(f"    + {mod}", invert=inv)
        if line.note:
            b.line(f"    ** {line.note} **", bold=True, invert=inv)
    b.rule()
    b.line(f"{ticket.order_id[-8:]}  {ticket.at.strftime('%Y-%m-%d %H:%M:%S')}")
    b.feed(2).cut()
    return bytes(b)


def drawer_kick(*, pin: int = 0, dialect: str = "escpos") -> bytes:
    """A job that only opens the drawer (a cash sale, a no-sale with manager approval)."""
    return bytes(DIALECTS[dialect]().drawer_kick(pin))


def ascii_only(ticket: Ticket) -> Ticket:
    """The same ticket with every non-ASCII label replaced, to test a printer without graphics."""

    def plain(text: str) -> str:
        return text if all(32 <= ord(ch) < 127 for ch in text) else "[CJK]"

    lines = tuple(
        replace(line, label=plain(line.label), modifiers=tuple(plain(m) for m in line.modifiers), note=plain(line.note))
        for line in ticket.lines
    )
    return replace(ticket, lines=lines)


DEMO = Ticket(
    station="Wok",
    kind="new",
    order_id="0193f2a7-demo-ticket",
    ticket_no=3412,
    table="12",
    server="Amy",
    guests=4,
    course="entrees",
    lines=(
        TicketLine(1, "左宗鸡 (Qt)", ("加辣", "糙米", "加虾"), seat=2),
        TicketLine(2, "Kung Pao Chicken (Pt)", ("no peanuts",), note="allergy: peanut", seat=1),
        TicketLine(1, "麻婆豆腐", ("lunch special", "酸辣汤", "炒饭")),
    ),
)
