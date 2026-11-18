"""How long the kitchen takes (docs/kitchen-times.md): the marks of the kitchen screens, added up over a span
of days.

A cook marks a dish made at a station's screen, and the pass (or the server who carried it) marks it gone
out (`pos.printing.screen`, `pos.printing.made`). Every mark carries its time and every dish the moment it
was sent, so the orders' logs already say how long everything took. This reads them:

- a **ticket** is what a station's screen calls one: the dishes of one send of an order that the station
  makes. It took from the moment its dishes were in the kitchen (when they were sent, or for an order sent
  ahead, when its time came) until the station marked the last of them made. A to-go order is one more
  ticket at the station that packs it, as on that station's screen;
- a **send** went out when the last of its dishes was marked gone out;
- a **dish** was made when the last of the stations that cook it said so.

Only what was marked can be timed. A ticket with a dish nobody marked is counted beside the times (`open`)
and never in them, and a station that finished marking no ticket at all in the span (`silent`: it has no
screen, or nobody taps it) is named with how many it was sent and kept out of every figure. So a kitchen
that works off paper has a report that says it timed nothing, not one that says it was slow. The time is
the station's own word: a dish the pass sent out while its station said nothing is not timed for that
station.

The tickets are the ones of orders that stand: an order voided whole is left out, and so is a dish voided
or taken off. Nothing here changes an order or is written down.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from datetime import date, datetime, timedelta
from statistics import median
from typing import Any, NamedTuple

from .. import localtime
from ..sync.oplog import OrderState
from .screen import PASS, _due, _stations
from .service import is_to_go

SLOWEST = 10
"""How many of the longest tickets a report names."""
DISHES = 100
"""How many dishes a report lists at most, the slowest first."""
MINUTE = 60_000


class Cooked(NamedTuple):
    """One dish that was sent, as far as the kitchen's clock goes."""

    name: str
    sent_ms: int
    device: str  # the screen that sent it: what it prints no ticket at, no station cooks from
    stations: tuple[str, ...]  # where the menu has it cooked
    made: tuple[tuple[str, int], ...]  # each station's own word, and when it said it
    out_ms: int | None  # when it went out, if anybody said so


class Kitchen(NamedTuple):
    """One order's dishes for the kitchen's clock, with whose it is. It is read off the log alone, so it can
    be remembered for as long as the log stays as it was (`pos.orders.sales.OrderMemo`)."""

    order_id: str
    table: str
    tab: str
    order_no: int | None
    customer: str
    to_go: bool
    dishes: tuple[Cooked, ...]


def kitchen_of(state: OrderState) -> Kitchen | None:
    """The dishes of an order that were sent and still stand, each with when it was in the kitchen and what
    the kitchen said of it. None for an order voided whole and for one with nothing sent."""
    if state.status == "void":
        return None
    fields = state.fields
    to_go = is_to_go(state)
    due = _due(state)
    dishes: list[Cooked] = []
    for line in state.ordered_lines():
        if line.fired_at is None or not line.active:
            continue
        priced = line.priced or {}
        names = priced.get("names")
        typed = priced.get("typed")
        name = (typed.get("name") if isinstance(typed, Mapping) else None) or (
            names.get("en") if isinstance(names, Mapping) else None
        )
        sent = line.fired_at.wall_ms
        dishes.append(
            Cooked(
                name=str(name or line.item or ""),
                # an order sent ahead of its time is in the kitchen when that time comes, as on the screens
                sent_ms=due if due is not None and due > sent else sent,
                device=line.fired_at.node,
                stations=tuple(sorted({station for station in _stations(line) if station is not None})),
                made=tuple(sorted((station, at) for station, at in line.done.items() if station != PASS)),
                out_ms=line.done.get(PASS),
            )
        )
    if not dishes:
        return None
    order_no = fields.get("order_no")
    return Kitchen(
        order_id=state.order_id,
        table=str(fields.get("table") or ""),
        tab=state.tab_name,
        order_no=order_no if isinstance(order_no, int) and not isinstance(order_no, bool) else None,
        customer=str(fields.get("customer_name") or "") if to_go else "",
        to_go=to_go,
        dishes=tuple(dishes),
    )


class _Times:
    """How long some tickets took, and how many beside them nobody finished marking."""

    __slots__ = ("open", "took")

    def __init__(self) -> None:
        self.took: list[int] = []
        self.open = 0

    def add(self, took_ms: int | None) -> None:
        if took_ms is None:
            self.open += 1
        else:
            self.took.append(max(0, took_ms))

    def row(self, late_ms: int, counted: str = "tickets") -> dict[str, Any]:
        """How many were timed (under `counted`), their average (`avg_ms`), the middle one (`median_ms`) and
        the longest; how many took the location's red minutes or more (`late`); and `open`, the ones sent
        and not marked through."""
        took = self.took
        return {
            counted: len(took),
            "avg_ms": round(sum(took) / len(took)) if took else None,
            "median_ms": round(median(took)) if took else None,
            "longest_ms": max(took) if took else None,
            "late": sum(1 for one in took if one >= late_ms) if late_ms > 0 else 0,
            "open": self.open,
        }


class _Ticket(NamedTuple):
    """One station's dishes of one send, and how long they took it; None while a dish of them is unmarked."""

    kitchen: Kitchen
    station: str
    sent_ms: int
    took_ms: int | None


class _Span:
    """The kitchen's times of one span of days, gathered one send at a time and added up at the end: which
    stations marked anything at all is known only then."""

    def __init__(self, first: date, last: date, now_ms: int) -> None:
        self.first, self.last = first, last
        self.since, self.until = localtime.service_day(first)[0], localtime.service_day(last)[1]
        self.now_ms = now_ms
        self.tickets: list[_Ticket] = []
        self.out = _Times()
        self.dishes: dict[str, _Times] = {}

    def holds(self, sent_ms: int) -> bool:
        return self.since <= sent_ms < self.until and sent_ms <= self.now_ms

    def _stations(self) -> tuple[dict[str, _Times], dict[str, _Times]]:
        """Each station's tickets: the stations that finished marking one, and the `silent` ones that never
        did. A silent station has no screen, or nobody taps it: its tickets are no measure of anything, so
        they are named beside the times and kept out of every figure."""
        every: dict[str, _Times] = {}
        for ticket in self.tickets:
            every.setdefault(ticket.station, _Times()).add(ticket.took_ms)
        timed = {code: times for code, times in every.items() if times.took}
        return timed, {code: times for code, times in every.items() if not times.took}

    def totals(self, late_ms: int) -> dict[str, Any]:
        timed, _ = self._stations()
        made = _Times()
        for times in timed.values():
            made.took.extend(times.took)
            made.open += times.open
        return {
            "first": self.first.isoformat(),
            "last": self.last.isoformat(),
            "since_ms": self.since,
            "until_ms": self.until,
            "running": self.since <= self.now_ms < self.until,
            "made": made.row(late_ms),
            "out": self.out.row(late_ms),
        }

    def report(self, late_ms: int, names: Mapping[str, str]) -> dict[str, Any]:
        timed, silent = self._stations()
        zone, night = localtime.zone(), localtime.NIGHT_ENDS.hour
        hours: dict[int, _Times] = {}
        days: dict[date, _Times] = {}
        slow: list[dict[str, Any]] = []
        for ticket in self.tickets:
            if ticket.station not in timed:
                continue
            hour = datetime.fromtimestamp(ticket.sent_ms / 1000, zone).hour
            hours.setdefault(hour, _Times()).add(ticket.took_ms)
            days.setdefault(localtime.service_day_of(ticket.sent_ms), _Times()).add(ticket.took_ms)
            if ticket.took_ms is not None:
                whose = ticket.kitchen
                slow.append(
                    {
                        "order_id": whose.order_id,
                        "table": whose.table,
                        "tab": whose.tab,
                        "order_no": whose.order_no,
                        "customer": whose.customer,
                        "to_go": whose.to_go,
                        "station": ticket.station,
                        "station_name": names.get(ticket.station) or ticket.station,
                        "sent_ms": ticket.sent_ms,
                        "took_ms": max(0, ticket.took_ms),
                    }
                )
        slow.sort(key=lambda row: (-row["took_ms"], row["sent_ms"], row["order_id"], row["station"]))
        every_day = [self.first + timedelta(days=n) for n in range((self.last - self.first).days + 1)]
        return {
            **self.totals(late_ms),
            "stations": sorted(
                (
                    {"code": code, "name": names.get(code) or code, **times.row(late_ms)}
                    for code, times in timed.items()
                ),
                key=lambda row: (-row["tickets"], row["name"]),
            ),
            "silent": sorted(
                ({"code": code, "name": names.get(code) or code, "open": times.open} for code, times in silent.items()),
                key=lambda row: (-row["open"], row["name"]),
            ),
            # in the order of a night: the hours after midnight come last
            "hours": [
                {"hour": hour, **hours[hour].row(late_ms)}
                for hour in sorted(hours, key=lambda hour: (hour - night) % 24)
            ],
            "days": [{"day": day.isoformat(), **days.get(day, _Times()).row(late_ms)} for day in every_day],
            "dishes": sorted(
                ({"name": name, **times.row(late_ms, "count")} for name, times in self.dishes.items() if times.took),
                key=lambda row: (-row["avg_ms"], -row["count"], row["name"]),
            )[:DISHES],
            "slowest": slow[:SLOWEST],
        }


def kitchen_times(
    kitchens: Iterable[Kitchen],
    span: tuple[date, date],
    before: tuple[date, date],
    *,
    now_ms: int,
    takeout: str | None = None,
    skips: Callable[[str], frozenset[str]] = lambda device: frozenset(),
    station_names: Mapping[str, str] | None = None,
    late_min: int = 0,
) -> dict[str, Any]:
    """The kitchen's times of `span`, with the same days' totals `before` to hold beside them.

    `made` is the tickets of every station that marks, together, and `out` the sends that went out: each
    says how many were timed (`tickets`), their `avg_ms`, `median_ms` and `longest_ms`, how many took
    `late_min` minutes or more (`late`; none are counted when it is 0), and how many were sent and not marked
    through (`open`). The same for each of the `stations` (the most tickets first), each of the `hours` a
    ticket was sent in (in the order of a night) and each of the `days`. `silent` is the stations that
    finished marking no ticket at all in the span, each with how many it was sent (`open`): they are in
    none of the figures. `dishes` is the dishes, the slowest first, each timed until the last station that
    cooks it made it (`count` times), and `slowest` names the longest tickets.

    `takeout` is the station that packs to-go orders, which has a ticket of every one of them; `skips(device)`
    the stations the screen that sent a dish prints no ticket at, and so no station cooks from."""
    names = station_names or {}
    late_ms = max(0, late_min) * MINUTE
    spans = [_Span(*span, now_ms), _Span(*before, now_ms)]
    for kitchen in kitchens:
        sends: dict[int, list[Cooked]] = {}
        for dish in kitchen.dishes:
            sends.setdefault(dish.sent_ms, []).append(dish)
        for sent, dishes in sends.items():
            into = next((one for one in spans if one.holds(sent)), None)
            if into is None:
                continue
            at: dict[str, list[int | None]] = {}  # each station's word on each of its dishes of this send
            for dish in dishes:
                skip = skips(dish.device)
                said = dict(dish.made)
                cooks = [station for station in dish.stations if station not in skip]
                for station in cooks:
                    at.setdefault(station, []).append(said.get(station))
                # the packer has every dish of a to-go order, whoever cooks it
                if kitchen.to_go and takeout and takeout not in skip and takeout not in cooks:
                    at.setdefault(takeout, []).append(said.get(takeout))
                if cooks:
                    into.dishes.setdefault(dish.name, _Times()).add(_last(sent, [said.get(s) for s in cooks]))
            for station, words in at.items():
                into.tickets.append(_Ticket(kitchen, station, sent, _last(sent, words)))
            if at:  # (a send no station cooks waits for nobody: a beer rung at the bar's own screen)
                into.out.add(_last(sent, [dish.out_ms for dish in dishes]))
    return {
        "span": spans[0].report(late_ms, names),
        "before": spans[1].totals(late_ms),
        "late_min": max(0, late_min),
    }


def _last(sent_ms: int, words: list[int | None]) -> int | None:
    """How long after `sent_ms` the last of these words was said; None while one of them is missing."""
    said = [word for word in words if word is not None]
    return max(said) - sent_ms if said and len(said) == len(words) else None
