"""The prep list: a day's orders ahead added up, dish by dish, for each station that cooks them.

Saturday has three catering orders and two phone orders named for a time. Each prints its own tickets when
its time comes; what the kitchen needs the day before is the sum: eight quarts of General Tso's, forty egg
rolls, and by when the first of them. `prep_list` reckons that from the orders as the log has them, in the
words the stations' own tickets use (the kitchen label, the choices a station reads), and `prep_paper` and
`render_prep` put it on paper.

The orders are the ones the list of orders ahead has for that day (`pos.orders.ahead.is_ahead`): a to-go
order the customer named a time for, not voided, not handed over. Every dish on them counts, sent or not: an
order on the books is food to make, and what nobody sent yet is said at the top so somebody sends it. The
takeout station packs and does not cook, so a dish stands under the station that makes it, and under the
takeout station only when nothing else does.

Nothing is kept: the list is reckoned again each time it is asked.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any

from .. import localtime
from ..orders.ahead import HANDOVERS, is_ahead
from ..sync.oplog import Line, OrderState, promised_ms
from .day import long_day
from .escpos import Builder
from .ticket import DIALECTS

NO_STATION = "No station"


def _text(value: Any) -> str:
    return " ".join(str(value or "").split())


def _cooked(line: Line, takeout: str | None) -> list[Mapping[str, Any]]:
    """The line as the stations cook it: its kitchen lines, less the takeout station's copies of a dish some
    other station makes."""
    kitchen = (line.priced or {}).get("kitchen")
    if not kitchen:  # a line typed on the phase 0 demo screen
        return [{"qty": 1, "label": line.item, "labels": []}]
    made = [k for k in kitchen if k.get("station") != takeout]
    return made or list(kitchen)


def _choices(k: Mapping[str, Any]) -> tuple[tuple[str, ...], tuple[int, ...]]:
    """The choices the dish's own station reads, and how far in each stands (`Group.hidden_at`: a station's
    ticket leaves off what the menu hides from it, and so does its part of this list)."""
    labels = [str(text) for text in k.get("labels") or ()]
    depths = [int(d) for d in k.get("depths") or ()]
    hidden = k.get("hidden") or ()
    station = k.get("station")
    read = [i for i in range(len(labels)) if i >= len(hidden) or station not in hidden[i]]
    return tuple(labels[i] for i in read), tuple(depths[i] if i < len(depths) else 0 for i in read)


def prep_list(
    states: Iterable[OrderState],
    day: date,
    *,
    now_ms: int,
    takeout: str | None = None,
    station_names: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """What the orders ahead for `day` (a day of service) need made, among `states`.

    `orders` are the day's orders, the earliest first, each with its dishes and how many of them nobody sent.
    `stations` are the stations that cook for them, in the order the menu lists its stations: each has `rows`,
    a dish a row (`label`, `header` for a part of a combination, `qty` over all the orders, `first_ms` the
    earliest time an order with it is for), and under a row its `ways`: how many of them are wanted some
    other way than plain (`choices`, `depths`, `note`). `dishes` counts what was rung in, a platter once;
    `unsent` how many of those nobody sent to the kitchen."""
    names = station_names or {}
    picked = []
    for state in states:
        promised = promised_ms(state.fields.get("promised_at"))
        if promised is None or not is_ahead(state, now_ms) or localtime.service_day_of(promised) != day:
            continue
        picked.append((promised, state))
    picked.sort(key=lambda pair: (pair[0], pair[1].fields.get("order_no") or 0, pair[1].order_id))

    orders = []
    by_station: dict[str | None, dict[tuple[str, str], dict[str, Any]]] = {}
    for promised, state in picked:
        fields = state.fields
        lines = [line for line in state.ordered_lines() if line.active]
        guests = fields.get("event_guests")
        orders.append(
            {
                "order_id": state.order_id,
                "order_no": fields.get("order_no") if isinstance(fields.get("order_no"), int) else None,
                "customer_name": _text(fields.get("customer_name")),
                "channel": _text(fields.get("channel")),
                "promised_ms": promised,
                "guests": guests if isinstance(guests, int) and not isinstance(guests, bool) and guests > 0 else None,
                "handover": fields.get("handover") if fields.get("handover") in HANDOVERS else None,
                "dishes": sum(line.qty for line in lines),
                "unsent": sum(line.qty for line in lines if line.fired_at is None and not line.arrived_sent),
            }
        )
        for line in lines:
            for k in _cooked(line, takeout):
                station = k.get("station") or None
                label = str(k.get("label") or line.item)
                rows = by_station.setdefault(station, {})
                row = rows.setdefault(
                    (label, str(k.get("header") or "")),
                    {"label": label, "header": str(k.get("header") or ""), "qty": 0, "first_ms": promised, "ways": {}},
                )
                qty = line.qty * int(k.get("qty", 1))
                row["qty"] += qty
                row["first_ms"] = min(row["first_ms"], promised)
                choices, depths = _choices(k)
                note = " · ".join(str(n) for n in (k.get("note"), line.note) if n)
                if choices or note:
                    way = row["ways"].setdefault(
                        (choices, depths, note),
                        {"qty": 0, "choices": list(choices), "depths": list(depths), "note": note},
                    )
                    way["qty"] += qty

    order = {code: at for at, code in enumerate(names)}
    stations = []
    for station in sorted(by_station, key=lambda code: (code is None, order.get(code, len(order)), code or "")):
        rows = sorted(by_station[station].values(), key=lambda row: (row["label"].casefold(), row["header"]))
        stations.append(
            {
                "station": station,
                "name": NO_STATION if station is None else names.get(station) or station,
                "rows": [{**row, "ways": list(row["ways"].values())} for row in rows],
            }
        )
    return {
        "day": day.isoformat(),
        "today": localtime.service_day_of(now_ms).isoformat(),
        "orders": orders,
        "count": len(orders),
        "guests": sum(row["guests"] or 0 for row in orders),
        "dishes": sum(row["dishes"] for row in orders),
        "unsent": sum(row["unsent"] for row in orders),
        "stations": stations,
    }


@dataclass(frozen=True)
class PrepPaper:
    """A day's prep list as it prints. `prep` is `prep_list`'s answer."""

    prep: Mapping[str, Any]
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # the printer this was for, on the copy a fallback printer gets


def prep_paper(prep: Mapping[str, Any], *, at: datetime | None = None) -> PrepPaper:
    return PrepPaper(prep=prep, at=at or datetime.now())


def _many(count: int, one: str, many: str | None = None) -> str:
    return f"{count} {one if count == 1 else many or one + 's'}"


def _clock(ms: int) -> str:
    return f"{datetime.fromtimestamp(ms / 1000, localtime.zone()):%H:%M}"


def summed(prep: Mapping[str, Any]) -> str:
    """The day in a line: "3 orders, 38 guests, 42 dishes"."""
    said = [_many(prep["count"], "order")]
    if prep["guests"]:
        said.append(_many(prep["guests"], "guest"))
    said.append(_many(prep["dishes"], "dish", "dishes"))
    return ", ".join(said)


def _way(b: Builder, way: Mapping[str, Any]) -> None:
    """How some of a dish are wanted, under its row: the count on the first choice, the rest under it."""
    first = f"    {way['qty']} x "
    choices, depths = way["choices"], way["depths"]
    for i, choice in enumerate(choices):
        depth = depths[i] if i < len(depths) else 0
        b.line(f"{first if i == 0 else ' ' * len(first)}{'    ' * depth}+ {choice}")
    if way["note"]:
        b.line(f"{first if not choices else ' ' * len(first)}** {way['note']} **", bold=True)


def render_prep(paper: PrepPaper, *, dots: int = 576, font: str | None = None, dialect: str = "escpos") -> bytes:
    """The print job for one day's prep list (`dialect` escpos or star). Deterministic for the same inputs."""
    prep = paper.prep
    b = DIALECTS[dialect](dots=dots, font=font)
    if paper.reprinted_from:
        b.line(f"{paper.reprinted_from} printer down, printed here".upper(), center=True, bold=True, invert=True)
        b.feed(1)
    b.line("PREP LIST", big=True, bold=True, center=True)
    b.line(long_day(date.fromisoformat(prep["day"])), bold=True, center=True)
    b.line(summed(prep), center=True)
    if prep["unsent"]:
        # counted below all the same: an order on the books is food to make
        b.line(
            f"{_many(prep['unsent'], 'DISH', 'DISHES')} NOT SENT TO THE KITCHEN", bold=True, center=True, invert=True
        )
    b.rule()
    b.line("THE ORDERS", bold=True)
    for order in prep["orders"]:
        number = f"#{order['order_no']} " if order["order_no"] is not None else ""
        said = [f"{_clock(order['promised_ms'])}  {number}{order['customer_name']}".rstrip()]
        if order["guests"]:
            said.append(_many(order["guests"], "guest"))
        if order["handover"]:
            said.append(order["handover"])
        b.columns(", ".join(said), _many(order["dishes"], "dish", "dishes"))
    # a time beside each dish only when the day has more than one: with one, the head of the list says it
    times = {order["promised_ms"] for order in prep["orders"]}
    for station in prep["stations"]:
        b.rule()
        b.line(str(station["name"]).upper(), bold=True)
        for row in station["rows"]:
            by = f"by {_clock(row['first_ms'])}" if len(times) > 1 else ""
            words = f"{row['qty']} x {row['label']}"
            if by:
                b.columns(words, by, bold=True)
            else:
                b.line(words, bold=True)
            if row["header"]:
                b.line(f"    with {row['header']}")
            for way in row["ways"]:
                _way(b, way)
    b.rule()
    b.line(f"{paper.at:%Y-%m-%d %H:%M:%S}", center=True)
    b.feed(2).cut()
    return bytes(b)
