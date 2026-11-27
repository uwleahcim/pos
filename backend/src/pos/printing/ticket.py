"""Kitchen tickets and receipts as data, rendered to ESC/POS or StarPRNT by `render`.

The backend builds a `Ticket` from an order and its routing; the apps never see ESC/POS and never decide
what a ticket says. A modify ticket is a new ticket with `kind="modify"`, never a silent change.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime

from .escpos import Builder
from .script import ScriptBuilder
from .star import StarBuilder

DIALECTS: dict[str, type[Builder]] = {"escpos": Builder, "star": StarBuilder}
AUTO = "auto"
"""A printer's language setting that is no language: print in the one the printer was found to speak."""

SCRIPT = "script"
"""No printer's language either: the paper written down step by step (`pos.printing.script`), which is what
the print log keeps of it. Every renderer takes it where it takes a printer's language."""


def builder(dialect: str, *, dots: int = 576, font: str | None = None) -> Builder:
    """What a renderer writes a paper with: the builder of a printer's language, or the one that writes the
    steps down (`SCRIPT`)."""
    if dialect == SCRIPT:
        return ScriptBuilder(dots=dots)
    return DIALECTS[dialect](dots=dots, font=font)


ONE, EACH = "one", "each"
"""How a printer that prints for several stations prints one send (its `tickets` setting): every dish on `one`
ticket, headed with all its stations, or a ticket for `each` station, headed with that station alone. With
`each`, the stations a manager grouped (the printer's `groups`: wok 1 with wok 2) still share a ticket."""


@dataclass(frozen=True)
class TicketLine:
    qty: int
    label: str  # the kitchen label in the station's language, e.g. "左宗鸡 (Qt)"
    modifiers: tuple[str, ...] = ()  # e.g. ("加辣", "糙米", "加虾")
    depths: tuple[int, ...] = ()  # how far in each of `modifiers` prints: 1 is a choice on the choice above it
    note: str = ""
    seat: int | None = None
    void: bool = False
    changed: bool = False  # modified after the course was fired
    header: str | None = None  # the dish this one is part of, when it is a combo's or a lunch special's choice
    allergy: str = ""  # the allergy told for this dish's seat ("Peanuts - no MSG"), printed under the dish
    # where it is cooked, of the stations this ticket is for: for a screen (the pass); the paper does not print it
    stations: tuple[str, ...] = field(default=(), compare=False)


@dataclass(frozen=True)
class Money:
    """Where a to-go order stands with its money when its ticket is made, for whoever hands the bag over."""

    words: str  # "PAID", "NOT PAID  $45.20", "NOTHING TO PAY"
    owing: bool = False  # something is still to be collected: printed white on black
    detail: str = ""  # the smaller line under it: "$20.00 paid of $65.20"


@dataclass(frozen=True)
class Ticket:
    station: str  # "Wok"
    # new | modify | void | reprint | allergy (an allergy told or changed after its dishes were sent) | moved
    # (dishes already sent now go to another table than the one on their ticket: `was_at`) | bag (what goes in
    # the bag of a to-go order changed after it was sent: no dishes, the answer alone) | notice (no order at
    # all: something a person has to look at, in `words`)
    kind: str
    order_id: str
    ticket_no: int
    table: str
    lines: tuple[TicketLine, ...]
    server: str = ""
    order_type: str = "dine in"  # dine in | takeout | delivery | phone | catering
    guests: int | None = None
    course: str | None = None
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # "Wok 1" on the copy a fallback printer gets when Wok 1's is down
    late: datetime | None = None  # when the operator took it, if it reached the backend late (ADR 6)
    order_no: int | None = None  # counter mode: the number called at the shelf
    customer: str = ""  # the name on a takeout order
    channel: str = ""  # counter | phone | online | delivery | catering
    promised: datetime | None = None  # a takeout order's promised time
    part: tuple[int, int] | None = None  # (2, 3): the second of the three tickets this send has the cooks working on
    also_at: tuple[str, ...] = ()  # the other stations cooking for the same send, by name ("Wok 2", "Sushi Bar")
    allergies: tuple[str, ...] = ()  # the allergies told at the table, one a line ("Table: Peanuts", "Seat 2: Sesame")
    money: Money | None = None  # the takeout counter's copy of a to-go order: paid, or what is still owed
    was_at: str = ""  # on a `moved` slip: the table the dishes were sent for, which the cooks' tickets name
    tab: bool = False  # a bar tab: no table, called by the name on it (`customer`)
    was_tab: str | None = None  # on a `moved` slip for a tab that sat down: the name its tickets were headed with
    # The takeout counter's copy of a to-go order: what the customer wants in the bag besides the food, a line
    # each ("2 x Chopsticks", "Forks"); empty when nothing was wanted, None while nobody was asked.
    bag: tuple[str, ...] | None = None
    # What the customer wrote for the whole order (an online order's instructions): on every station's
    # ticket, since it may say an allergy or "no onions in anything".
    note: str = ""
    # A `notice`: its headline, printed white on black, and what there is to say under it, a line each.
    words: tuple[str, ...] = ()
    # An order from one of the restaurant's websites, where it has several: what the restaurant calls that
    # one ("Sushi site"), said beside the channel. And `test`: the order came from the account the restaurant
    # only tests with, so nobody is to make it (docs/online-orders.md, "Several accounts").
    store: str = ""
    test: bool = False


TEST_WORDS = ("TEST ORDER", "DO NOT MAKE")
"""What heads every paper of an order that came from the account the restaurant tests with."""


NOTED = frozenset({"new", "modify", "reprint", "allergy"})
"""The kinds of ticket that carry the customer's note: the ones a cook works from."""


def render(
    ticket: Ticket, *, dots: int = 576, font: str | None = None, beep: bool = True, dialect: str = "escpos"
) -> bytes:
    """The print job for one ticket (`dialect` escpos or star). Deterministic for the same inputs."""
    b = builder(dialect, dots=dots, font=font)
    if beep:
        b.beep(3 if ticket.kind in ("modify", "void", "allergy", "moved", "bag", "notice") or ticket.late else 1)
    header = {
        "new": ticket.station,
        "modify": f"*** MODIFY *** {ticket.station}",
        "void": f"*** VOID *** {ticket.station}",
        "reprint": f"REPRINT {ticket.station}",
        "allergy": f"*** ALLERGY *** {ticket.station}",
        "moved": f"*** MOVED *** {ticket.station}",
        "bag": f"*** BAG *** {ticket.station}",
        "notice": f"*** LOOK *** {ticket.station}",
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
        # A fallback printer's copy: whoever stands here carries it to the station it is for.
        b.line(f"{ticket.reprinted_from} printer down, printed here".upper(), center=True, bold=True, invert=True)
    if ticket.kind == "notice":
        # No order at all: something whoever stands here has to look at, said as plainly as a dish.
        # It has no number of its own on it: a "#1" here would be read as an order's.
        b.line(ticket.at.strftime("%H:%M"), center=True)
        b.rule()
        for i, said in enumerate(ticket.words):
            b.line(said, big=i == 0, bold=True, center=i == 0, invert=i == 0)
        b.rule()
        b.line(f"{ticket.order_id.rsplit(':', 1)[-1][-20:]}  {ticket.at.strftime('%Y-%m-%d %H:%M:%S')}")
        b.feed(2).cut()
        return bytes(b)
    b.columns(f"#{ticket.ticket_no}  {ticket.order_type}", ticket.at.strftime("%H:%M"))
    if ticket.test:
        # Before anything a cook reads of it: this is nobody's food.
        for said in TEST_WORDS:
            b.line(said, big=True, bold=True, center=True, invert=True)
    if ticket.tab:
        # A bar tab has no table: the name on it is where its drinks go, so it is the biggest thing on it.
        b.line(f"TAB {ticket.customer}".strip().upper(), big=True, bold=True)
    elif ticket.order_no is not None or (ticket.customer and not ticket.table):
        # A takeout order is called by number and name at the shelf, so they are the biggest thing on it.
        # (A table's check that began as a tab keeps its name, and is called by its table.)
        number = f"#{ticket.order_no}  " if ticket.order_no is not None else ""
        b.line(f"{number}{ticket.customer}".strip().upper(), big=True, bold=True)
    if ticket.promised is not None:
        # The day too when it is not the day the ticket prints: a ticket that comes out early, or late, must
        # not be cooked for the wrong day.
        day = "" if ticket.promised.date() == ticket.at.date() else f"  {ticket.promised:%a %b} {ticket.promised.day}"
        b.line(f"READY BY {ticket.promised:%H:%M}{day.upper()}", bold=True)
    if ticket.money is not None:
        # Under the number and the name: the third thing asked at the shelf. Money still to collect is a
        # black bar across the paper, so a bag is not handed over on the strength of a quiet line.
        b.line(ticket.money.words, big=True, bold=True, center=ticket.money.owing, invert=ticket.money.owing)
        if ticket.money.detail:
            b.line(ticket.money.detail, bold=True)
    if ticket.table:
        guests = f"  {ticket.guests} guests" if ticket.guests else ""
        b.line(f"Table {ticket.table}{guests}", bold=True)
    elif ticket.channel:
        how = "  DELIVERY" if ticket.order_type == "delivery" else ""
        store = f": {ticket.store}" if ticket.store else ""
        b.line(f"{ticket.channel.replace('_', ' ').capitalize()}{store}{how}", bold=True)
    elif not ticket.tab:
        b.line("No table", bold=True)
    if ticket.server:
        b.line(f"Server {ticket.server}")
    if ticket.course:
        b.line(f"Course: {ticket.course}")
    # What else this send has cooking, last before the dishes: a cook times a dish against the other stations.
    if ticket.part is not None:
        b.line(f"Ticket {ticket.part[0]} of {ticket.part[1]}")
    if ticket.also_at:
        b.line(f"Also at: {', '.join(ticket.also_at)}", bold=True)
    b.rule()
    # The allergies told at the table stand in a block of their own, white on black, on every station's ticket
    # (the menu engine design: "in bold on every station's copy"): a wok or a fryer is shared by every dish.
    if ticket.allergies:
        b.line("ALLERGY", big=True, bold=True, center=True, invert=True)
        for told in ticket.allergies:
            b.line(told, bold=True)
    elif ticket.kind == "allergy":
        b.line("NO ALLERGY NOW", big=True, bold=True, center=True, invert=True)
        b.line("The allergy told before was taken off.", bold=True)
    if ticket.kind == "allergy":
        b.line("For the dishes you already have:")
    if ticket.allergies or ticket.kind == "allergy":
        b.rule()
    if ticket.note and ticket.kind in NOTED:
        # What the customer wrote for the whole order, on every station's ticket under a bar of its own: it
        # is read before the dishes, and it is not the kitchen's own allergy block, which a person filled in.
        b.line("CUSTOMER'S NOTE", bold=True, center=True, invert=True)
        b.line(ticket.note, bold=True)
        b.rule()
    if ticket.kind == "moved":
        # The cooks' tickets name the table the food was sent for: this one says where it goes now, as big as
        # a dish, so whoever runs the plate reads it from the pass.
        was = f"TAB {ticket.was_tab}".strip() if ticket.was_tab is not None else f"TABLE {ticket.was_at}"
        b.line(f"WAS {was}".upper(), big=True, bold=True, center=True)
        b.line(f"NOW TABLE {ticket.table}".upper(), big=True, bold=True, center=True, invert=True)
        b.line("These dishes go to the new table:")
        b.rule()
    for line in ticket.lines:
        # A void is printed white on black, the dish and its choices, so nobody cooks it by mistake.
        prefix = "VOID " if line.void else ("CHG  " if line.changed else "")
        seat = f" [s{line.seat}]" if line.seat else ""
        inv = line.void
        b.line(f"{prefix}{line.qty} x {line.label}{seat}", big=True, bold=line.void or line.changed, invert=inv)
        if line.header:
            b.line(f"    with {line.header}", invert=inv)
        for i, mod in enumerate(line.modifiers):
            # a choice on a choice (the sauce on a roll of a combination) stands under it, one step further in
            depth = line.depths[i] if i < len(line.depths) else 0
            b.line(f"{'    ' * (depth + 1)}+ {mod}", invert=inv)
        if line.note:
            b.line(f"    ** {line.note} **", bold=True, invert=inv)
        if line.allergy:
            b.line(f"    ** ALLERGY: {line.allergy} **", bold=True, invert=inv)
    if ticket.bag is not None:
        # Under the dishes, as big as a dish: whoever packs the bag reads it last, with the bag open. "Nothing"
        # is said too, so nobody drops chopsticks in out of habit.
        if ticket.lines:
            b.rule()
        b.line("NOW IN THE BAG" if ticket.kind == "bag" else "ALSO IN THE BAG", bold=True)
        for words in ticket.bag or ("NOTHING",):
            b.line(words, big=True)
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
