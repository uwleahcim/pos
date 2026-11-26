"""A table booked on the website, as GloriaFood gave it, read for the reservation book.

GloriaFood hands a booked table over the way it hands over an order (`pos.online.gloriafood`), in the same
shape: `type` is `table_reservation`, or `order_ahead` for a table booked with its dishes ordered ahead;
`persons` is how many sit down, and `fulfill_at` the time the table is for. `wanted` reads one and gives
what the book is to hold. Nothing here writes: the hub does that with what comes back (`pos.api.online`,
`pos.reservations.Reservations.take`).

**What is copied.** The name, how many they are, the time, the phone number and what the customer wrote.
Nothing else: no e-mail, no consent to marketing, nothing of how they would pay.

**Made to fit the book.** The book's own limits hold for a reservation from the website as for one a host
types. A name longer than a host calls out is shortened to the family name, or the first name, or cut. A
note longer than the book takes is cut and ends in "…": the whole of it is in GloriaFood's app. A phone
number the book would not take is left out, and that is said.

**What cannot be booked.** One that does not say for how many, or for when: `CannotPlace`, with why, for a
person to write into the book by hand. One for a day that is over (the hub was off, or got its key later):
`NotAnOrder`; there is nothing left to do about it but know.

**After its time.** A reservation of today that reaches the hub more than a quarter of an hour after its
time is booked all the same, and `late`: the party may be at the door.

**Dishes ordered ahead** are not put on the POS here. The table goes into the book, its note says the
dishes were ordered ahead, and a person is told to ring them in from GloriaFood's app when the party sits.

A reservation is no check and no sale, and takes no money.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .. import localtime
from ..reservations import NOTE_MAX, WEBSITE, Refused
from ..waitlist import MOST_GUESTS, NAME_MAX, _phone
from .place import CannotPlace, NotAnOrder, _line, _ms, ext_id_of, unaccepted

RESERVATION_TYPES = ("table_reservation", "order_ahead")
"""What GloriaFood calls a booked table: one by itself, and one with its dishes ordered ahead."""
BY = "the website"
"""Who the book says wrote a reservation that came from the website."""
NOBODY = "Online guest"
"""The name of a reservation that came without one."""
AHEAD = "Ordered ahead: dishes in GloriaFood."
"""What the note of a table booked with its dishes begins with: whoever seats the party reads it."""
AHEAD_SAID = (
    "its dishes were ordered ahead and are not on the POS: they are in GloriaFood's app, to ring in when the party sits"
)
NO_PHONE_SAID = "its phone number is not one the book takes and was left out: it is in GloriaFood's app"
LATE_MS = 15 * 60_000
"""How long after its time a reservation of today can reach the hub before somebody is told it came late."""
MINUTE_MS = 60_000


@dataclass(frozen=True)
class Wanted:
    """A table booked on the website, as the book is to hold it."""

    booking_id: str
    ext_id: str  # GloriaFood's own number for it
    name: str
    size: int
    at_ms: int  # the minute the table is for
    phone: str = ""
    note: str = ""
    notes: tuple[str, ...] = ()  # what a person should know of it
    late: bool = False  # it is for today and its time has passed

    @property
    def said(self) -> str:
        """What is told of it, in words; nothing when it went into the book as it came."""
        return "; ".join(self.notes)


@dataclass(frozen=True)
class Booked:
    """What became of a table booked on the website: the reservation it is in the book, and what a person
    should know of it (`said`; nothing when there is nothing). `late` for one that came after its time."""

    booking_id: str
    said: str = ""
    late: bool = False


def booking_id_for(ext_id: str) -> str:
    """The reservation a table booked on the website becomes: always the same one, so one given twice is
    one reservation."""
    return f"{WEBSITE}{ext_id}"


def wanted(order: Mapping[str, Any], *, now_ms: int) -> Wanted:
    """What the book is to hold of this booked table. `NotAnOrder` for what is no reservation the book
    takes, `CannotPlace` for one it should take and cannot read well enough to; both say why."""
    ext_id = ext_id_of(order)
    if ext_id is None:
        raise NotAnOrder("it has no number")
    kind = str(order.get("type") or "")
    if kind not in RESERVATION_TYPES:
        raise NotAnOrder("it is not a table that was booked")
    refused = unaccepted(order)
    if refused is not None:
        raise refused

    size = _guests(order.get("persons"))
    if size is None:
        raise CannotPlace("it does not say how many they are")
    if size > MOST_GUESTS:
        raise CannotPlace(f"it is for {size} guests, and the book takes {MOST_GUESTS} at most")
    at_ms = _ms(order.get("fulfill_at"))
    if at_ms is None:
        raise CannotPlace("it names no time")
    at_ms -= at_ms % MINUTE_MS
    day, today = localtime.service_day_of(at_ms), localtime.service_day_of(now_ms)
    if day < today:
        raise NotAnOrder(f"it was for {day:%b} {day.day}, a day that is over: it was not put in the book")

    notes: list[str] = []
    late = day == today and now_ms > at_ms + LATE_MS
    if late:
        notes.append(f"it reached the hub after its time ({_clock(at_ms)})")
    ahead = kind == "order_ahead"
    if ahead:
        notes.append(AHEAD_SAID)
    phone = _line(order.get("client_phone"), 80)
    try:
        phone = _phone(phone)
    except Refused:
        phone = ""
        notes.append(NO_PHONE_SAID)
    return Wanted(
        booking_id_for(ext_id),
        ext_id,
        _name(order),
        size,
        at_ms,
        phone,
        _note(order, ahead=ahead),
        tuple(notes),
        late,
    )


def _guests(value: Any) -> int | None:
    """How many sit down, as a whole number of one or more; None for anything else."""
    if isinstance(value, bool):
        return None
    if isinstance(value, str) and value.strip().isdigit():
        value = int(value.strip())
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return value if isinstance(value, int) and value >= 1 else None


def _words(value: Any, most: int) -> str:
    """Text on one line with what cannot be printed taken out: what the book takes as a name or a note."""
    text = _line(value, most)
    return " ".join("".join(ch if ch.isprintable() else " " for ch in text).split())


def _name(order: Mapping[str, Any]) -> str:
    """The name a host calls out: the whole name when it fits, otherwise the family name, otherwise the
    first name, otherwise as much of the whole as fits."""
    first, last = _words(order.get("client_first_name"), 80), _words(order.get("client_last_name"), 80)
    whole = f"{first} {last}".strip()
    for name in (whole, last, first):
        if name and len(name) <= NAME_MAX:
            return name
    return whole[:NAME_MAX].strip() or NOBODY


def _note(order: Mapping[str, Any], *, ahead: bool) -> str:
    """What the customer wrote, after the word that its dishes were ordered ahead when they were; cut to
    what the book takes, with "…" for what is missing."""
    said = _words(order.get("instructions"), 1000)
    note = " ".join(part for part in (AHEAD if ahead else "", said) if part)
    return note if len(note) <= NOTE_MAX else f"{note[: NOTE_MAX - 1]}…"


def _clock(ms: int) -> str:
    """A moment of today on the restaurant's own clock: "19:30"."""
    return datetime.fromtimestamp(ms / 1000, localtime.zone()).strftime("%H:%M")


__all__ = ["BY", "RESERVATION_TYPES", "Booked", "Wanted", "booking_id_for", "wanted"]
