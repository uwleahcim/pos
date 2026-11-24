"""The labels of a to-go order's bags: a short slip for each bag, to stick on it.

An order that leaves in three bags is three things on the shelf, and the ticket that says whose they are
is stapled to one of them. A label says it on each: the number and the name the order is called by, which
bag of how many it is, that it is a delivery when it is one, and when it is due. So whoever hands the order
over, or drives it, counts the bags against the label and leaves none behind.

A label says no more of the customer than the name: not the phone number, not the address and not the
money. The shelf is where other customers stand, and those are on the bill and the ticket that go with the
bag. It lists no dish either: what is in which bag is the packer's business, and nobody tells the hub.

`BagLabels` is data, like a `Ticket` or a `PackSheet`: the print service makes one from an order and how
many bags somebody counted (`PrintService.bag_labels`), and `render_labels` turns it into the bytes for a
printer in its own language: every label of the order in one job, each cut off the next, so that they come
out together or not at all. Nothing prints by itself: somebody asks for them (`POST
/orders/{order_id}/bag-labels`).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from .ticket import DIALECTS

BAGS_MOST = 24
"""The most bags one asking prints labels for: a slip of the thumb must not empty the roll."""


@dataclass(frozen=True)
class BagLabels:
    order_id: str
    bags: int  # how many bags the order went into: a label for each
    order_no: int | None = None  # the number called at the shelf
    customer: str = ""  # the name on the order, as its ticket heads it
    delivery: bool = False  # brought to the customer: a driver's bag, not the shelf's
    promised: datetime | None = None  # when the order is due
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # the printer this was for, on the copy a fallback printer gets


def render_labels(labels: BagLabels, *, dots: int = 576, font: str | None = None, dialect: str = "escpos") -> bytes:
    """The print job for an order's labels (`dialect` escpos or star): one after the other, each cut off the
    next. Deterministic for the same inputs.

    Each label is a paper of its own inside the one job. A Star printer cuts where a drawn page ends and
    nowhere else (`pos.printing.star`), so labels drawn as one page would come out as one long strip."""
    number = f"#{labels.order_no}" if labels.order_no is not None else ""
    whose = f"{number}  {labels.customer}".strip().upper()

    def label(bag: int) -> bytes:
        b = DIALECTS[dialect](dots=dots, font=font)
        if labels.reprinted_from:
            b.line(f"{labels.reprinted_from} printer down, printed here".upper(), center=True, bold=True, invert=True)
        if whose:
            b.line(whose, big=True, bold=True)
        # what tells one label from the next, so the one thing on it that is white on black
        b.line(f"BAG {bag} OF {labels.bags}", big=True, bold=True, center=True, invert=True)
        if labels.delivery:
            b.line("DELIVERY", big=True, bold=True)
        if labels.promised is not None:
            # as the ticket says it: the day too when it is not the day the label prints
            p = labels.promised
            day = "" if p.date() == labels.at.date() else f"  {p:%a %b} {p.day}".upper()
            b.line(f"READY BY {p:%H:%M}{day}", bold=True)
        b.line(f"{labels.order_id[-8:]}  {labels.at.strftime('%Y-%m-%d %H:%M:%S')}")
        b.feed(1).cut()
        return bytes(b)

    return b"".join(label(bag) for bag in range(1, labels.bags + 1))
