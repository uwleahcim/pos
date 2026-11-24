"""The guest list: every customer who ordered with a phone number, and how good a guest each one is.

A guest is a phone number that has ordered (`pos.customers`): nothing is typed in for the list's sake, and
nothing new is kept. It is read from the same orders as the sales report, a year of them: for each guest
how many times they came, what they spent, when they were last here, and what they order most. Three lists
are picked out of it:

- regulars: `REGULAR_VISITS` visits or more in the last `REGULAR_DAYS` days;
- stopped coming: `REGULAR_VISITS` visits or more in the year, and none for `LAPSED_DAYS` days. A guest on
  this list is not on the regulars' list as well;
- new: their first order ever was in the last `NEW_DAYS` days.

How it is counted:

- A visit is an order with at least one dish on it that carries the number. It counts on the day the sales
  count it on (the day it was opened, or the day it is for when that is later), and only once that day has
  come. An order voided whole is no visit, and a dish voided or taken off is not in it.
- `spent` is the net sales of their visits: every dish at the price it was sold at, less comps and
  discounts, before tax, charges and gratuity. Added up over every guest it is the net sales of the checks
  that carry a number.
- Favourite dishes are counted by how many were sold, a dish by its code while the menu has it (called what
  the menu calls it today), an off-menu dish by the name typed for it.
- `since_ms` and `orders_ever` are of every order the number ever placed, not only the year's: what the
  to-go form says of a caller ("12 orders since Mar 2025").

Beside each guest stand the two things the restaurant keeps about a number: the note (`pos.customers`) and
the tags a manager put on it (`pos.guest_tags`), with every tag there is to offer and how many of the
list's guests carry it.

A number that carries a tag and has no visit in the year is listed too, apart from the guests who ordered
(`tagged`): somebody tagged from their reservation or their line of the waitlist before their first order,
or a guest of long ago. Its row has the shape of a guest's with no visit and nothing spent, under the name
it was tagged by. It is counted in no total and no tag's `guests`: those are of the guests who ordered.

What one order comes to as a visit (`Visit`, from `visit_of`) is remembered in the hub's memory while its
log stays as it was (`VisitMemo`), as the sales are: a year of orders with a number is read from the log
once after the hub starts and from memory after that.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from datetime import date, timedelta
from decimal import Decimal
from sys import intern
from typing import Any, NamedTuple

from .. import localtime
from ..customers import NOTE_MAX, SHORTEST
from ..guest_tags import TAG_MAX, TAGS_MOST, offered
from ..menu.defs import Definitions
from ..sync.oplog import OrderEntry, OrderState, phone_digits
from ..tax import TaxProfile
from .adjustments import PricingRules
from .day import ZERO
from .sales import CENT, OrderMemo, _each, _same, sale_of

LOOK_BACK_DAYS = 365
"""How many days of service the list reads, today the last of them."""
REGULAR_VISITS = 3
REGULAR_DAYS = 90
LAPSED_DAYS = 60
NEW_DAYS = 30
FAVOURITES = 3
"""How many favourite dishes each guest of the list carries; one guest read alone carries `MORE_FAVOURITES`."""
MORE_FAVOURITES = 10
LATEST = 10
"""How many of their latest visits one guest read alone lists."""


class Visit(NamedTuple):
    """One order of a customer, as the guest list counts it."""

    phone: str  # digits
    order_id: str
    order_no: Any
    day: date  # the day of service it counts on
    opened_ms: int
    net: Decimal
    name: str  # the customer's name on the order
    kind: str
    dishes: tuple[tuple[str | None, str, int], ...]  # code (None for a name that was typed), name, how many


def visit_of(state: OrderState, taxes: TaxProfile, rules: PricingRules | None, one: Any = _same) -> Visit | None:
    """This order as a visit, or None when it is none: no number on it, voided whole, or no dish on it."""
    phone = phone_digits(state.fields.get("phone"))
    if len(phone) < SHORTEST or state.first is None:
        return None
    sale = sale_of(state, taxes, rules)
    if sale is None or sale.void or not sale.lines:
        return None
    dishes: dict[tuple[str | None, str], int] = {}
    for line in sale.lines:
        key = (None, line.typed) if line.typed else (line.item, line.name)
        dishes[key] = dishes.get(key, 0) + line.qty
    return Visit(
        phone=phone,
        order_id=state.order_id,
        order_no=state.fields.get("order_no"),
        day=sale.day,
        opened_ms=state.first.wall_ms,
        net=sale.gross - sale.off,
        name=intern(" ".join(str(state.fields.get("customer_name") or "").split())),
        kind=sale.kind,
        dishes=one(tuple((item, name, qty) for (item, name), qty in dishes.items())),
    )


class VisitMemo(OrderMemo):
    """Each order's `Visit`, remembered (`OrderMemo`): 100,000 orders with a number, some years of them, a
    few hundred bytes each, so some 50 MB at the very most."""

    def __init__(self, keep: int = 100_000, at_once: int = 500) -> None:
        super().__init__(visit_of, keep, at_once)


def window(now_ms: int) -> tuple[date, date]:
    """The days the list reads: the `LOOK_BACK_DAYS` days of service that end with the one running."""
    today = localtime.service_day_of(now_ms)
    return today - timedelta(days=LOOK_BACK_DAYS - 1), today


def in_window(entries: Iterable[OrderEntry], first: date) -> list[OrderEntry]:
    """Of the orders that carry a number, the ones that can count on a day from `first` on: opened since
    then, or wanted for a time since then. Voided ones apart."""
    since = localtime.service_day(first)[0]
    return [
        entry
        for entry in entries
        if entry.status != "void"
        and len(entry.phone) >= SHORTEST
        and entry.first_ms is not None
        and (entry.first_ms >= since or (entry.promised_ms is not None and entry.promised_ms >= since))
    ]


class _Guest:
    def __init__(self) -> None:
        self.visits: list[Visit] = []
        self.spent = ZERO
        self.dishes: dict[tuple[str | None, str], int] = {}

    def add(self, visit: Visit) -> None:
        self.visits.append(visit)
        self.spent += visit.net
        for item, name, qty in visit.dishes:
            self.dishes[(item, name)] = self.dishes.get((item, name), 0) + qty


def _favourites(dishes: Mapping[tuple[str | None, str], int], defs: Definitions, most: int) -> list[dict[str, Any]]:
    """The dishes ordered most: by code while the menu has the dish, under today's name, else by the name
    it was sold under."""
    loc = defs.localizer
    counted: dict[tuple[str | None, str], int] = {}
    for (item, name), qty in dishes.items():
        known = defs.items.get(item) if item is not None else None
        key = (item, loc.text(known.names, "en") or name) if known is not None else (None, name)
        counted[key] = counted.get(key, 0) + qty
    ranked = sorted(counted.items(), key=lambda pair: (-pair[1], pair[0][1].lower(), pair[0][0] or ""))
    return [{"item": item, "name": name, "count": count} for (item, name), count in ranked[:most]]


def _ever(entries: Iterable[OrderEntry]) -> dict[str, tuple[int, int]]:
    """For each number, how many orders it ever placed (voided ones apart) and when the first was opened."""
    ever: dict[str, tuple[int, int]] = {}
    for entry in entries:
        if entry.status == "void" or entry.first_ms is None or len(entry.phone) < SHORTEST:
            continue
        count, first = ever.get(entry.phone, (0, entry.first_ms))
        ever[entry.phone] = (count + 1, min(first, entry.first_ms))
    return ever


def _row(
    phone: str,
    guest: _Guest,
    ever: tuple[int, int] | None,
    note: str,
    tags: Sequence[str],
    *,
    defs: Definitions,
    today: date,
    favourites: int,
) -> dict[str, Any]:
    visits = sorted(guest.visits, key=lambda visit: (visit.day, visit.opened_ms, visit.order_id), reverse=True)
    last = visits[0].day
    lately = sum(1 for visit in visits if (today - visit.day).days < REGULAR_DAYS)
    lapsed = len(visits) >= REGULAR_VISITS and (today - last).days >= LAPSED_DAYS
    since_ms = min(ever[1] if ever is not None else visits[-1].opened_ms, visits[-1].opened_ms)
    return {
        "phone": phone,
        "name": next((visit.name for visit in visits if visit.name), ""),
        "note": note,
        "tags": list(tags),
        "visits": len(visits),
        "spent": str(guest.spent),
        "per_visit": _each(guest.spent, len(visits)),
        "last": last.isoformat(),
        "first": visits[-1].day.isoformat(),
        "since_ms": since_ms,
        "orders_ever": max(ever[0] if ever is not None else 0, len(visits)),
        "lately": lately,
        "regular": lately >= REGULAR_VISITS and not lapsed,
        "lapsed": lapsed,
        "new": (today - localtime.service_day_of(since_ms)).days < NEW_DAYS,
        "favourites": _favourites(guest.dishes, defs, favourites),
    }


def _tagged_row(phone: str, name: str, ever: tuple[int, int] | None, note: str, tags: Sequence[str]) -> dict[str, Any]:
    """The row of a number that carries a tag and has no visit in the year: a guest's row with no visit.
    `since_ms` and `orders_ever` are of the orders it placed before the year, if it placed any."""
    return {
        "phone": phone,
        "name": name,
        "note": note,
        "tags": list(tags),
        "visits": 0,
        "spent": str(ZERO),
        "per_visit": None,
        "last": None,
        "first": None,
        "since_ms": ever[1] if ever is not None else None,
        "orders_ever": ever[0] if ever is not None else 0,
        "lately": 0,
        "regular": False,
        "lapsed": False,
        "new": False,
        "favourites": [],
    }


def _gather(visits: Iterable[Visit], first: date, today: date) -> dict[str, _Guest]:
    guests: dict[str, _Guest] = {}
    for visit in visits:
        if first <= visit.day <= today:
            guests.setdefault(visit.phone, _Guest()).add(visit)
    return guests


def _about(first: date, today: date, now_ms: int) -> dict[str, Any]:
    return {
        "first": first.isoformat(),
        "last": today.isoformat(),
        "days": LOOK_BACK_DAYS,
        "regular_visits": REGULAR_VISITS,
        "regular_days": REGULAR_DAYS,
        "lapsed_days": LAPSED_DAYS,
        "new_days": NEW_DAYS,
        "now_ms": now_ms,
        # what a screen that writes a guest's note and tags holds them to
        "note_max": NOTE_MAX,
        "tag_max": TAG_MAX,
        "tags_most": TAGS_MOST,
    }


def guests_report(
    visits: Iterable[Visit],
    entries: Sequence[OrderEntry],
    notes: Mapping[str, str],
    *,
    defs: Definitions,
    now_ms: int,
    tags: Mapping[str, Sequence[str]] | None = None,
    names: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """The guest list as it stands at `now_ms`: every number with a visit in the days of `window`, the one
    that spent most first. `visits` are at least the visits of those days, `entries` every order that
    carries a number (for since when and how many orders ever), `notes` the note kept about each number and
    `tags` the tags on each. `tags` in the answer is every tag there is to offer, with how many of the
    guests listed carry it. `tagged` is every number that carries a tag and has no visit in those days,
    under the name it was tagged by (`names`), by that name and the nameless by their number after them."""
    first, today = window(now_ms)
    ever = _ever(entries)
    carried = tags or {}
    called = names or {}
    rows = [
        _row(
            phone,
            guest,
            ever.get(phone),
            notes.get(phone, ""),
            carried.get(phone, ()),
            defs=defs,
            today=today,
            favourites=FAVOURITES,
        )
        for phone, guest in _gather(visits, first, today).items()
    ]
    rows.sort(key=lambda row: (-Decimal(row["spent"]), -row["visits"], row["name"].lower(), row["phone"]))
    spent = sum((Decimal(row["spent"]) for row in rows), ZERO)
    count = sum(row["visits"] for row in rows)
    listed = {row["phone"] for row in rows}
    others = [
        _tagged_row(phone, called.get(phone, ""), ever.get(phone), notes.get(phone, ""), words)
        for phone, words in carried.items()
        if words and phone not in listed
    ]
    others.sort(key=lambda row: (not row["name"], row["name"].casefold(), row["phone"]))
    return {
        **_about(first, today, now_ms),
        "guests": rows,
        "tagged": others,
        "tags": offered(carried, listed),
        "totals": {
            "guests": len(rows),
            "visits": count,
            "spent": str(spent.quantize(CENT)),
            "per_visit": _each(spent, count),
            "regulars": sum(1 for row in rows if row["regular"]),
            "lapsed": sum(1 for row in rows if row["lapsed"]),
            "new": sum(1 for row in rows if row["new"]),
        },
    }


def guest_report(
    phone: str,
    visits: Iterable[Visit],
    entries: Sequence[OrderEntry],
    note: Mapping[str, Any] | None,
    *,
    defs: Definitions,
    now_ms: int,
    tags: Mapping[str, Any] | None = None,
    name: str = "",
) -> dict[str, Any] | None:
    """One guest read closely: the row of the list with more favourite dishes, their latest visits (each
    with its dishes), who wrote the note about them and when, and who last put their tags on (`tags` is
    what is kept for the number: its `tags`, `by` and `at_ms`). A number with no visit in the days of
    `window` that carries a tag is read too: the row it has among the `tagged`, under the `name` it was
    tagged by, with no visit to show. None for a number with neither. `visits` and `entries` are this
    number's."""
    first, today = window(now_ms)
    guest = _gather((visit for visit in visits if visit.phone == phone), first, today).get(phone)
    words = list((tags or {}).get("tags") or ())
    about = str((note or {}).get("note") or "")
    if guest is None and not words:
        return None
    if guest is None:
        row = _tagged_row(phone, name, _ever(entries).get(phone), about, words)
        latest: list[Visit] = []
    else:
        row = _row(
            phone, guest, _ever(entries).get(phone), about, words, defs=defs, today=today, favourites=MORE_FAVOURITES
        )
        latest = sorted(guest.visits, key=lambda visit: (visit.day, visit.opened_ms, visit.order_id), reverse=True)
    return {
        **_about(first, today, now_ms),
        "guest": row,
        "note_by": str((note or {}).get("by") or ""),
        "note_ms": (note or {}).get("at_ms") if (note or {}).get("note") else None,
        "tags_by": str((tags or {}).get("by") or ""),
        "tags_ms": (tags or {}).get("at_ms") if (tags or {}).get("tags") else None,
        "latest": [
            {
                "order_id": visit.order_id,
                "order_no": visit.order_no,
                "day": visit.day.isoformat(),
                "opened_ms": visit.opened_ms,
                "kind": visit.kind,
                "net": str(visit.net),
                "dishes": _favourites({(item, name): qty for item, name, qty in visit.dishes}, defs, len(visit.dishes)),
            }
            for visit in latest[:LATEST]
        ],
    }
