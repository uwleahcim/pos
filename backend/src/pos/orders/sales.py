"""Sales over a span of days, to hold beside the days before.

The day's report (`pos.orders.day`) is one day read closely: what is still open, the money, what came off.
This is the longer look: any days from one to a quarter of a year, added up the same way, with each day of
the span on a line of its own. `comparison` names the days to hold it against: as many days, whole weeks
earlier, so that a Friday stands beside a Friday.

A day is a day of service (4 AM to 4 AM), and a check counts on the day it was opened, or on the day it is
promised for when that is later, exactly as in the day's report: a span of one day reads the same sales
there and here. A check voided whole is no sale. A payment counts on the day it was taken. Everything is
reckoned from the operation log; nothing is written down, and nothing here changes a sale.

A quarter of a year is tens of thousands of checks, and replaying each from its log takes about a
thousandth of a second, so what one check comes to (`Sale`, from `sale_of`) is remembered in the hub's
memory under the exact state of its log (`SaleMemo`): a check nobody touched since is not replayed again,
and one that changed in any way is. Nothing remembered outlives the hub's process.

The figures add up:

- `sales.gross` is every dish on the span's checks at the price it was sold at; `days`, `hours`, `menus`,
  `categories` and `kinds` each split that one figure.
- `sales.net` = gross - discounts; `sales.total` = net + charges + gratuity + tax.
- `per_check` = net / checks. `per_guest` = the net of the checks that say how many guests they were,
  over those guests: a to-go order has no guests and is left out of it rather than counted as nobody.
- `turn` is how long a table's check stood, from opened to closed: how many closed table checks there were
  and the middle one of their times (the median: one table forgotten open overnight does not move it).
- `money.taken` is every payment recorded in the span, by how it was paid, whatever check it was for.
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from statistics import median
from sys import intern
from typing import Any, NamedTuple

from .. import localtime
from ..menu.defs import Definitions
from ..sync.oplog import OrderEntry, OrderState
from ..tax import TaxProfile
from .adjustments import PricingRules
from .check import _money, check_for
from .day import METHODS, ZERO, _guests, _Menu, _most_first, _Tally, order_day

MAX_DAYS = 92
"""The longest span one reading adds up: a quarter of a year."""
CENT = Decimal("0.01")


def comparison(first: date, last: date) -> tuple[date, date]:
    """The days to hold beside `first`..`last`: as many days, the fewest whole weeks earlier that do not
    overlap them. One day stands beside the same weekday a week before, a week beside the week before, ten
    days beside the ten days two weeks before."""
    days = (last - first).days + 1
    back = timedelta(weeks=-(-days // 7))
    return first - back, last - back


def span_ms(first: date, last: date) -> tuple[int, int]:
    """The wall-clock stamps the service of `first`..`last` runs between."""
    return localtime.service_day(first)[0], localtime.service_day(last)[1]


def _each(total: Decimal, over: int) -> str | None:
    return str((total / over).quantize(CENT, ROUND_HALF_UP)) if over > 0 else None


class Picked(NamedTuple):
    """One choice on a sold dish, as its line kept it."""

    group: str
    option: str
    word: str  # the one-tap instruction in front of it (no, extra, side, light), or ""
    qty: int  # how many of it on one of the dish
    label: str  # what the check called it, without the count: the name to fall back on
    price: Decimal  # what it added to one of the dish
    depth: int  # 1 for a choice of a choice (the sauce on a roll of a combination)


class Sold(NamedTuple):
    """The same dish sold the same way in the same hour of one check, added up."""

    item: str | None
    entry: str
    hour: int | None
    amount: Decimal
    qty: int
    variant: str = ""
    name: str = ""  # what the menu called the dish when it was sold, without its size
    size: str = ""  # what its size was called
    typed: str = ""  # the name typed for an off-menu dish
    picked: tuple[Picked, ...] = ()  # its choices, in the order of the check


def _same(thing: Any) -> Any:
    return thing


def _text(names: Any, fallback: Any = "") -> str:
    said = names.get("en") if isinstance(names, Mapping) else None
    return intern(str(said or fallback or ""))


def _picked(rows: Any, one: Callable[[Any], Any]) -> tuple[Picked, ...]:
    """The choices a line's snapshot lists, without the kitchen notes written under a dish inside it."""
    out: list[Picked] = []
    for row in rows or ():
        if not isinstance(row, Mapping) or row.get("note"):
            continue
        qty = row.get("qty")
        qty = qty if isinstance(qty, int) and not isinstance(qty, bool) and qty > 0 else 1
        label = str(row.get("label") or "")
        if qty > 1:
            label = label.removeprefix(f"{qty}x ")
        out.append(
            one(
                Picked(
                    intern(str(row.get("group_id") or "")),
                    intern(str(row.get("option_id") or "")),
                    intern(str(row.get("prefix") or "")),
                    qty,
                    intern(label),
                    _money(row.get("price")),
                    int(row.get("depth") or 0),
                )
            )
        )
    return one(tuple(out))


@dataclass(frozen=True, slots=True)
class Sale:
    """What one order comes to for the sales: worked out from its log, and good for as long as the log, the
    taxes and the location's rules stay as they were. The menu is not in it: a dish is kept by its code and
    named when a report is read, so a category renamed since reads by its new name."""

    day: date  # the day of service it counts on
    void: bool  # voided whole: no sale, and the rest below is empty
    payments: tuple[tuple[int, str, Decimal], ...]  # each payment taken: when, how, how much
    gross: Decimal = ZERO
    off: Decimal = ZERO
    tax: Decimal = ZERO
    total: Decimal = ZERO
    charges: Decimal = ZERO
    gratuity: Decimal = ZERO
    discounts: tuple[tuple[str, Decimal], ...] = ()  # by the name the location gives each
    guests: int = 0
    kind: str = ""
    stood_ms: int | None = None  # a table's check, closed: from opened to closed
    lines: tuple[Sold, ...] = ()
    """The dishes sold, added up by dish, menu entry, hour of the day and the way each was sold."""


def sale_of(
    state: OrderState,
    taxes: TaxProfile,
    rules: PricingRules | None,
    one: Callable[[Any], Any] = _same,
) -> Sale | None:
    """What this order comes to, or None for an order with nothing in its log. `one` gives back the one
    copy to keep of a choice or a list of choices: the same few on every check, so whoever remembers many
    sales passes its own and holds each once."""
    its_day = order_day(state)
    if its_day is None:
        return None
    payments = tuple(
        (payment.stamp.wall_ms, intern(str(payment.method or "cash")), Decimal(payment.amount or "0"))
        for payment in state.payments.values()
        if payment.stamp is not None
    )
    if state.status == "void":
        return Sale(its_day, True, payments)
    check = check_for(state, taxes, rules)
    kind = check["order_type"]
    charges = gratuity = ZERO
    for charge in check["charges"]:
        if charge["gratuity"]:
            gratuity += Decimal(charge["amount"])
        else:
            charges += Decimal(charge["amount"])
    zone = localtime.zone()
    lines: dict[tuple[Any, ...], list[Any]] = {}
    for row in check["lines"]:
        line = state.lines[row["line_id"]]
        priced = line.priced or {}
        item = priced.get("item")
        at = line.added_at
        hour = datetime.fromtimestamp(at.wall_ms / 1000, zone).hour if at is not None else None
        typed = priced.get("typed")
        typed = typed if isinstance(typed, Mapping) else {}
        # the same few codes and names on every check: one copy of each, however many checks are remembered
        key = (
            intern(item) if isinstance(item, str) else None,
            intern(str(priced.get("entry_id") or "")),
            hour,
            intern(str(priced.get("variant_id") or "")),
            # an off-menu dish is called what was typed for it: the menu's own name for it is kept beside
            intern(str(typed["menu_name"])) if typed.get("menu_name") else _text(priced.get("names"), row["name"]),
            _text(priced.get("variant_names")),
            intern(str(typed.get("name") or "")),
            _picked(priced.get("modifiers"), one),
        )
        sold = lines.setdefault(key, [ZERO, 0])
        sold[0] += Decimal(row["total"])
        sold[1] += row["qty"]
    stood = None
    if kind == "dine_in" and state.status == "closed" and state.closed_at is not None and state.first is not None:
        stood = state.closed_at.wall_ms - state.first.wall_ms
    return Sale(
        its_day,
        False,
        payments,
        gross=Decimal(check["subtotal"]),
        off=Decimal(check["discount_total"]),
        tax=Decimal(check["tax"]),
        total=Decimal(check["total"]),
        charges=charges,
        gratuity=gratuity,
        discounts=tuple((intern(str(row["name"])), Decimal(row["amount"])) for row in check["discounts"]),
        guests=_guests(state),
        kind=intern(str(kind)),
        stood_ms=stood,
        lines=tuple(Sold(*key[:3], amount, qty, *key[3:]) for key, (amount, qty) in lines.items()),
    )


class SaleMemo:
    """Each order's `Sale`, remembered under the exact state of its log (the index's `version` and `tip`),
    so that a second reading replays only the checks that changed. All of it is dropped when the taxes or
    the rules are other objects than it was worked out under; the least recently read go first past `keep`
    orders (40,000: a quarter beside the quarter before at 200 checks a day, under 3 KB each with every dish
    and how it was sold, so some 110 MB at the very most). The choices on the dishes are the same few on
    every check, so one copy of each is kept for all of them (`_one`). Nothing here can make a reading
    differ from one reckoned afresh: only save it the work."""

    def __init__(self, keep: int = 40_000, at_once: int = 500) -> None:
        self._keep, self._at_once = keep, at_once
        self._kept: OrderedDict[str, tuple[int, str, Sale | None]] = OrderedDict()
        self._under: tuple[Any, Any] = (None, None)
        self._ones: dict[Any, Any] = {}  # the one copy of each choice, and of each list of choices
        self._lock = threading.Lock()

    def __len__(self) -> int:
        return len(self._kept)

    def _one(self, thing: Any) -> Any:
        """The one copy kept of this choice or list of choices. A menu has a few thousand of them at most;
        past very many (a menu rewritten again and again) they are let go and gathered afresh."""
        if len(self._ones) > 200_000:
            self._ones = {}
        return self._ones.setdefault(thing, thing)

    def sales(
        self,
        entries: Sequence[OrderEntry],
        views: Callable[[Sequence[OrderEntry]], Sequence[OrderState]],
        *,
        taxes: TaxProfile,
        rules: PricingRules | None,
    ) -> Iterator[Sale]:
        """The sale of each of these orders: the remembered ones first, then the rest, replayed through
        `views` a few hundred at a time (a quarter of a year is too many to hold replayed all at once)."""
        missing: list[OrderEntry] = []
        found: list[Sale] = []
        with self._lock:
            if self._under[0] is not taxes or self._under[1] is not rules:
                self._kept.clear()
                self._ones = {}
                self._under = (taxes, rules)
            for entry in entries:
                kept = self._kept.get(entry.order_id)
                if kept is None or (kept[0], kept[1]) != (entry.version, entry.tip):
                    missing.append(entry)
                    continue
                self._kept.move_to_end(entry.order_id)
                if kept[2] is not None:
                    found.append(kept[2])
        yield from found
        for start in range(0, len(missing), self._at_once):
            some = missing[start : start + self._at_once]
            fresh = [
                (entry, sale_of(state, taxes, rules, self._one)) for entry, state in zip(some, views(some), strict=True)
            ]
            with self._lock:
                if self._under[0] is taxes and self._under[1] is rules:
                    for entry, sale in fresh:
                        self._kept[entry.order_id] = (entry.version, entry.tip, sale)
                        self._kept.move_to_end(entry.order_id)
                    while len(self._kept) > self._keep:
                        self._kept.popitem(last=False)
            yield from (sale for _, sale in fresh if sale is not None)


class _Span:
    """What one span of days comes to, added up one order at a time."""

    def __init__(self, first: date, last: date) -> None:
        self.first, self.last = first, last
        self.since, self.until = span_ms(first, last)
        self.days = {
            first + timedelta(days=i): {"checks": 0, "guests": 0, "gross": ZERO, "discounts": ZERO, "total": ZERO}
            for i in range((last - first).days + 1)
        }
        self.checks = self.guests = 0
        self.guest_net = ZERO
        self.sums = dict.fromkeys(("gross", "discounts", "charges", "gratuity", "tax", "total"), ZERO)
        self.lines: dict[tuple[str | None, str, int | None], list[Any]] = {}  # dish, entry, hour -> amount, qty
        self.kinds, self.discounts, self.taken = _Tally(), _Tally(), _Tally()
        self.taken_total = ZERO
        self.turns: list[int] = []

    def paid(self, sale: Sale) -> None:
        """The money taken on this order during the span, whatever day the order counts on."""
        for at_ms, method, amount in sale.payments:
            if self.since <= at_ms < self.until:
                self.taken.add(method, amount, method=method)
                self.taken_total += amount

    def sold(self, sale: Sale) -> None:
        """One check of the span, not voided whole."""
        self.checks += 1
        self.guests += sale.guests
        if sale.guests:
            self.guest_net += sale.gross - sale.off
        sums = self.sums
        sums["gross"] += sale.gross
        sums["discounts"] += sale.off
        sums["tax"] += sale.tax
        sums["total"] += sale.total
        sums["charges"] += sale.charges
        sums["gratuity"] += sale.gratuity
        for name, amount in sale.discounts:
            self.discounts.add(name, amount, name=name)
        day = self.days[sale.day]
        day["checks"] += 1
        day["guests"] += sale.guests
        day["gross"] += sale.gross
        day["discounts"] += sale.off
        day["total"] += sale.total
        self.kinds.add(sale.kind, ZERO, kind=sale.kind, guests=0)
        kind = self.kinds.rows[sale.kind]
        kind["guests"] += sale.guests
        if sale.stood_ms is not None:
            self.turns.append(sale.stood_ms)
        for line in sale.lines:
            kind["amount"] += line.amount
            sold = self.lines.setdefault((line.item, line.entry, line.hour), [ZERO, 0])
            sold[0] += line.amount
            sold[1] += line.qty

    def report(self, menu: _Menu, now_ms: int) -> dict[str, Any]:
        menus, categories, hours = _Tally(), _Tally(), _Tally()
        named: dict[tuple[str | None, str], tuple[str, str, str, str]] = {}
        for (item, entry, hour), (amount, qty) in self.lines.items():
            names = named.get((item, entry))
            if names is None:
                names = named[(item, entry)] = menu.of({"item": item, "entry_id": entry})
            menu_code, menu_name, category_code, category_name = names
            menus.add(menu_code, amount, qty, menu=menu_code, name=menu_name)
            categories.add(
                (menu_code, category_code), amount, qty, menu=menu_code, code=category_code, name=category_name
            )
            # in the order a night runs: from the hour it begins, round to the hour before it
            place = 24 if hour is None else (hour - localtime.NIGHT_ENDS.hour) % 24
            hours.add(hour, amount, qty, hour=hour, place=place)
        methods = {name: i for i, name in enumerate(METHODS)}
        sums = self.sums
        net = sums["gross"] - sums["discounts"]
        return {
            "first": self.first.isoformat(),
            "last": self.last.isoformat(),
            "since_ms": self.since,
            "until_ms": self.until,
            "running": self.since <= now_ms < self.until,
            "checks": self.checks,
            "guests": self.guests,
            "sales": {
                "gross": str(sums["gross"]),
                "discounts": str(sums["discounts"]),
                "net": str(net),
                "charges": str(sums["charges"]),
                "gratuity": str(sums["gratuity"]),
                "tax": str(sums["tax"]),
                "total": str(sums["total"]),
            },
            "per_check": _each(net, self.checks),
            "per_guest": _each(self.guest_net, self.guests),
            "turn": {
                "tables": len(self.turns),
                "minutes": round(median(self.turns) / 60000) if self.turns else None,
            },
            "days": [
                {
                    "day": day.isoformat(),
                    "checks": row["checks"],
                    "guests": row["guests"],
                    "gross": str(row["gross"]),
                    "net": str(row["gross"] - row["discounts"]),
                    "total": str(row["total"]),
                }
                for day, row in self.days.items()
            ],
            "hours": [{k: v for k, v in row.items() if k != "place"} for row in hours.listed(lambda row: row["place"])],
            "menus": menus.listed(_most_first),
            "categories": categories.listed(lambda row: (row["menu"], -row["amount"], row["name"])),
            "kinds": self.kinds.listed(lambda row: (-row["amount"], row["kind"])),
            "discounts": self.discounts.listed(_most_first),
            "money": {
                "taken": self.taken.listed(lambda row: (methods.get(row["method"], len(methods)), row["method"])),
                "taken_total": str(self.taken_total),
            },
        }


def sales_reports(
    sales: Iterable[Sale],
    spans: Sequence[tuple[date, date]],
    *,
    defs: Definitions,
    now_ms: int,
) -> list[dict[str, Any]]:
    """The sales of each of `spans` (first day, last day; no day in two of them), in one pass over the
    orders' sales given: every order opened before the latest span's service ended and changed since the
    earliest began, and every order promised for a day in between. An order that belongs to no day of any
    span costs a look and counts only for the money taken on it."""
    sums = [_Span(first, last) for first, last in spans]
    for sale in sales:
        for span in sums:
            span.paid(sale)
        if sale.void:
            continue
        for span in sums:
            if sale.day in span.days:
                span.sold(sale)
                break
    menu = _Menu(defs)
    return [span.report(menu, now_ms) for span in sums]


def sales_report(
    states: Iterable[OrderState],
    first: date,
    last: date,
    *,
    taxes: TaxProfile,
    rules: PricingRules | None,
    defs: Definitions,
    now_ms: int,
) -> dict[str, Any]:
    """The sales of `first`..`last` reckoned straight from these orders, nothing remembered."""
    sales = (sale for sale in (sale_of(state, taxes, rules) for state in states) if sale is not None)
    return sales_reports(sales, [(first, last)], defs=defs, now_ms=now_ms)[0]
