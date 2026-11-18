"""Tickets from orders: a `fire` or a void of a sent line turns into one job per kitchen printer, delivered
by the hub or a relay.

Printers are the location's setting (`settings/printers`, a manager's screen in the app): each one serves
one kitchen station or several (wok1, fryer, bar, takeout, ...), speaks ESC/POS or StarPRNT (set, or as the
printer was found to speak when the setting says `auto`) and names the printers that take its tickets when
it fails, in order. `POS_PRINTERS` (name=host[:port][/dialect], e.g.
`kitchen=172.19.1.162/escpos,bar=172.19.1.14/star`) seeds a hub whose setting is still empty.

Routing: a line prints at the printer serving its station; a printer serving several stations prints their
lines on one ticket, headed with every station's name; the first printer also takes every station that has
no printer, so nothing fired is ever left unprinted. A to-go order (counter, phone, online, delivery,
catering) prints whole at the takeout station's printer too, for the bag to be packed and checked. A
station's ticket leaves off the choices the menu hides from it (`Group.hidden_at`: the cooks do not read the
rice or the soup a dish comes with); the dish prints there all the same, and the bag's ticket reads what the
takeout station reads.

A screen can be told to print no ticket at some stations (`ticket_skips`, a manager's setting): what is sent
or voided from it prints nothing there, because the person ringing it in is the one who makes it (the bar's
own screen and the bar printer). The rest of the order prints where it always does.

A guest's bill (`pos.printing.bill`) is no kitchen ticket and is not routed by station: it prints where it
is asked for (`bill_printer`), on the same queue, with the same fallbacks.

An order sent ahead of its time (tonight at seven, Saturday's catering) prints nothing when it is sent:
the hub keeps which dishes wait (`pos.printing.held`, in the database, so a restart loses nothing) and
makes the ticket when the time comes, from the order as it stands then (`release_due`).

A hub writes jobs straight to the printers (`POS_PRINT_DIRECT=1`, the default); the cloud cannot reach a
LAN printer, so it runs with `POS_PRINT_DIRECT=0` and leaves jobs for a terminal relay to claim. Either way
the job store is the queue; the printing itself is retried in the background and never holds up the order
call.
"""

from __future__ import annotations

import itertools
import os
import threading
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, replace
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from .. import localtime
from ..orders.bag import FIELD as BAG
from ..orders.bag import bag_lines, bag_of
from ..sync.hlc import wall_clock_ms
from ..sync.oplog import Line, Op, OrderState, is_delivery, replay
from .bill import Bill, render_bill
from .day import DayPaper, render_day
from .escpos import find_font
from .held import Held, HeldTickets, Part
from .jobs import JobStore, PrintJob, send_raw
from .pack import PackSheet, render_pack
from .prep import PrepPaper, render_prep
from .ticket import AUTO, DIALECTS, Money, Ticket, TicketLine, render

LATE_AFTER_MS = 10 * 60 * 1000
"""An operation stamped this long before it arrives was queued through an outage, flagged or not."""

DEFAULT_LEAD_MINUTES = 15
"""How long before its promised time a future order's ticket prints when the order carries no quote."""

SOON_MS = 60_000
"""An order whose ticket is due within this is cooked now: nothing is held for under a minute."""


@dataclass(frozen=True)
class Printer:
    """One printer: `name` is the station it serves (its code, `wok1`), the first of `stations` when it
    serves several; `fallbacks` the ids of the printers that take its tickets when it does not answer, in
    order. `id` tells two printers on one station apart; it is the name unless the setting gave one.
    `dialect` is the language its tickets are rendered in; `language` is what the setting says, which may be
    `auto` (the dialect is then the one the printer was found to speak, `detected`)."""

    name: str
    address: str  # host or host:port
    dialect: str = "escpos"
    fallbacks: tuple[str, ...] = ()
    id: str = ""
    stations: tuple[str, ...] = ()
    language: str = ""
    detected: str | None = None

    def __post_init__(self) -> None:
        if not self.id:
            object.__setattr__(self, "id", self.name)
        if not self.stations:
            object.__setattr__(self, "stations", (self.name,))
        if not self.language:
            object.__setattr__(self, "language", self.dialect)

    @property
    def station(self) -> str:
        return self.name

    @classmethod
    def parse(cls, spec: str) -> Printer:
        name, _, rest = spec.strip().partition("=")
        address, _, dialect = rest.partition("/")
        if not name or not address:
            raise ValueError(f"printer spec {spec!r}: want name=host[:port][/dialect]")
        dialect = dialect or "escpos"
        if dialect not in DIALECTS:
            raise ValueError(f"printer {name}: unknown dialect {dialect!r}")
        return cls(name=name, address=address, dialect=dialect)

    def as_setting(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "station": self.name,
            "stations": list(self.stations),
            "address": self.address,
            "dialect": self.language,
            "detected": self.detected,
            "fallbacks": list(self.fallbacks),
        }


def printers_from_env(value: str | None = None) -> list[Printer]:
    raw = os.environ.get("POS_PRINTERS", "") if value is None else value
    return [Printer.parse(spec) for spec in raw.split(",") if spec.strip()]


def printers_from_setting(setting: Mapping[str, Any]) -> list[Printer]:
    """The printers as the `printers` setting holds them (checked by `pos.settings.clean_printers`). One set
    to `auto` prints in the language it was found to speak, and in ESC/POS, which most printers speak, until
    it has been told."""
    out = []
    for p in setting.get("printers", ()):
        stations = tuple(str(code) for code in p.get("stations") or (p["station"],))
        language = str(p.get("dialect") or "escpos")
        detected = p.get("detected") if p.get("detected") in DIALECTS else None
        out.append(
            Printer(
                name=stations[0],
                address=str(p["address"]),
                dialect=(detected or "escpos") if language == AUTO else language,
                fallbacks=tuple(str(f) for f in p.get("fallbacks", ())),
                id=str(p.get("id") or stations[0]),
                stations=stations,
                language=language,
                detected=detected,
            )
        )
    return out


def is_to_go(state: OrderState) -> bool:
    """A counter, phone, online, delivery or catering order: anything that leaves in a bag."""
    return str(state.fields.get("order_type") or "dine_in") != "dine_in"


def kitchen_changes(before: OrderState | None, after: OrderState) -> tuple[list[Line], list[Line]]:
    """What the kitchen must hear about between two replays of an order: lines sent for the first time,
    and lines it already had that are now off the order (a void, or the old half of a change). A dish that
    changes checks (`pos.orders.moves`) is neither: the check it leaves voids nothing, and on the check it
    comes onto a dish the kitchen already has is not sent again."""
    sent, voided = [], []
    for line in after.ordered_lines():
        was = before.lines.get(line.line_id) if before is not None else None
        if line.active and line.fired_at is not None and (was is None or was.fired_at is None):
            if not line.arrived_sent:
                sent.append(line)
        elif not line.active and was is not None and was.active and was.fired_at is not None and not line.moved:
            voided.append(line)
    return sent, voided


MOVED_SLIP_MS = 45 * 60 * 1000
"""How long after a dish was sent a change of table is still worth a slip to its station: later than this the
food has reached the table it was sent for."""


def table_changes(before: OrderState, after: OrderState, now_ms: int) -> list[tuple[str, list[Line]]]:
    """The dishes the kitchen is still likely to be cooking that now go to another table than the one on their
    ticket, by the table they were sent for: the check moved to another table, or dishes came onto it from a
    check at another table. Only dishes sent in the last `MOVED_SLIP_MS`; nothing for a check that is not open
    or has no table."""
    table = after.fields.get("table")
    if after.status != "open" or table in (None, ""):
        return []
    out: dict[str, list[Line]] = {}
    was = before.fields.get("table")
    for line in _still_cooking(after, now_ms):
        if line.line_id in before.lines:
            sent_for = was  # on the check before: its ticket names the table the check stood at
        else:
            sent_for = (line.moved_from or {}).get("table") if line.arrived_sent else None
        if sent_for not in (None, "") and str(sent_for) != str(table):
            out.setdefault(str(sent_for), []).append(line)
    return list(out.items())


def tab_changes(before: OrderState, after: OrderState, now_ms: int) -> list[tuple[str, list[Line]]]:
    """The same for a bar tab that sat down: the drinks and dishes sent in the last `MOVED_SLIP_MS` whose
    tickets are headed with the name on a tab and that now go to a table, by that name. The tab was given a
    table, or its dishes went onto a table's check. Nothing for a check that is not open or has no table."""
    if after.status != "open" or after.fields.get("table") in (None, ""):
        return []
    out: dict[str, list[Line]] = {}
    for line in _still_cooking(after, now_ms):
        if line.line_id in before.lines:
            name = before.tab_name if before.is_tab else None  # the check itself was the tab
        else:
            name = (line.moved_from or {}).get("tab") if line.arrived_sent else None
        if name is not None:
            out.setdefault(str(name), []).append(line)
    return list(out.items())


def _still_cooking(state: OrderState, now_ms: int) -> list[Line]:
    """The dishes on the check sent so lately that a station is likely still making them."""
    return [
        line
        for line in state.ordered_lines()
        if line.active and line.fired_at is not None and now_ms - line.fired_at.wall_ms <= MOVED_SLIP_MS
    ]


def taken_offline(ops: Iterable[Op], now_ms: int, late_after_ms: int = LATE_AFTER_MS) -> datetime | None:
    """When the operator took a batch that reaches the backend late: a terminal with no backend flagged the
    operations `offline` (ADR 6), or their stamps are older than `late_after_ms` (an app that did not say
    so). None for a batch that arrived in good time. The kitchen ticket is headed "late" with that time."""
    late = [op for op in ops if op.data.get("offline") or now_ms - op.hlc.wall_ms > late_after_ms]
    if not late:
        return None
    return datetime.fromtimestamp(min(op.hlc.wall_ms for op in late) / 1000)


def starts_ms(state: OrderState, *, default_lead_minutes: int = DEFAULT_LEAD_MINUTES) -> int | None:
    """When this order's ticket prints (wall-clock ms): its promised time less the minutes quoted for it.
    None for an order that names no time."""
    promised = state.fields.get("promised_at")
    if isinstance(promised, bool) or not isinstance(promised, int):
        return None
    quoted = state.fields.get("quoted_minutes")
    lead = quoted if isinstance(quoted, int) and not isinstance(quoted, bool) and quoted > 0 else default_lead_minutes
    return promised - lead * 60_000


def lead_delay(state: OrderState, now_ms: int, *, default_lead_minutes: int = DEFAULT_LEAD_MINUTES) -> float:
    """Seconds a ticket for this order waits before printing: a future order (architecture section 12,
    "Future orders") fires on its own ahead of its promised time by the minutes quoted for it, so the kitchen
    sees it when it is time to cook, not when it was taken. 0 for an order due now or soon."""
    start = starts_ms(state, default_lead_minutes=default_lead_minutes)
    if start is None or start - now_ms <= SOON_MS:
        return 0.0
    return (start - now_ms) / 1000


def _dollars(amount: Decimal) -> str:
    return f"${amount:,.2f}"


def money_words(check: Mapping[str, Any]) -> Money | None:
    """What the takeout counter's ticket says about the money, from the order's check (`total`, `paid`, `due`
    as the hub reckons them, tax and charges in): PAID, or NOT PAID with what is still to collect, white on
    black. Part paid says both sums. Paid more than the check now comes to (a dish voided after paying) says
    by how much. None when the check cannot be trusted to the cent (a line with no price)."""
    if check.get("unpriced"):
        return None
    try:
        total, paid, due = (Decimal(str(check[key])) for key in ("total", "paid", "due"))
    except (KeyError, InvalidOperation):
        return None
    if due > 0:
        so_far = f"{_dollars(paid)} paid of {_dollars(total)}" if paid > 0 else ""
        return Money(f"NOT PAID  {_dollars(due)}", owing=True, detail=so_far)
    if paid > total:
        return Money("PAID", detail=f"{_dollars(paid - total)} more than the check, now {_dollars(total)}")
    return Money("PAID" if paid > 0 else "NOTHING TO PAY")


def _told(state: OrderState) -> list[tuple[Any, ...]]:
    """The allergies on the order as the kitchen reads them: who typed one in is not its business."""
    return [(told["seat"], tuple(told["allergens"]), told["note"]) for told in state.allergy_list()]


def _when(ms: Any) -> datetime | None:
    return datetime.fromtimestamp(ms / 1000) if isinstance(ms, int) else None


def _local(ms: Any) -> datetime | None:
    """A wall-clock stamp on the restaurant's own clock, as its reports read one."""
    if isinstance(ms, bool) or not isinstance(ms, int):
        return None
    return datetime.fromtimestamp(ms / 1000, localtime.zone())


def allergy_words(told: Mapping[str, Any], names: Mapping[str, str]) -> str:
    """One allergy in words: its allergens by name, then whatever else was said ("Peanuts, Sesame - no MSG").
    Plain letters, so a printer writes it as text."""
    listed = ", ".join(names.get(code) or code for code in told.get("allergens") or ())
    return " - ".join(part for part in (listed, str(told.get("note") or "")) if part)


def allergy_lines(state: OrderState, names: Mapping[str, str]) -> tuple[str, ...]:
    """The allergies told on the order, one a line, the whole table's first ("Table: Peanuts", "Seat 2:
    Sesame"; "Tab:" on a bar tab, "Order:" on any other order with no table)."""
    whole = "Table" if state.fields.get("table") else "Tab" if state.is_tab else "Order"
    return tuple(
        f"{f'Seat {told["seat"]}' if told.get('seat') else whole}: {allergy_words(told, names)}"
        for told in state.allergy_list()
    )


def ticket_for(
    state: OrderState,
    sent: list[Line],
    voided: list[Line] | None = None,
    *,
    station: str,
    ticket_no: int,
    routes: Callable[[str | None], bool] | None = None,
    course: str | None = None,
    late: datetime | None = None,
    allergens: Mapping[str, str] | None = None,
    kind: str | None = None,
    was_at: str = "",
    was_tab: str | None = None,
) -> Ticket | None:
    """One station's ticket: voided lines first, printed in reverse, then the lines being sent.
    `routes(station)` says whether a kitchen line cooked at that station belongs on this ticket; without it,
    every line does. `late` is when the operator took it, for a batch that reached the backend late.
    `allergens` names the menu's allergens by code, for the allergies told on the order: they head every
    station's ticket, and a seat's own stands under each of its dishes. `kind` says what the ticket is when it
    is not for dishes sent or voided (`allergy`: an allergy told after `sent` had gone to the kitchen;
    `moved`: `sent` went to the kitchen for table `was_at`, or for the bar tab called `was_tab`, and now goes
    to this order's table; `bag`: what goes in the bag changed after the order was sent, a slip with no
    dishes on it)."""
    names = allergens or {}
    by_seat = {told["seat"]: allergy_words(told, names) for told in state.allergy_list() if told.get("seat")}
    lines = [
        *_ticket_lines(voided or [], routes, void=True, allergies=by_seat),
        *_ticket_lines(sent, routes, void=False, allergies=by_seat),
    ]
    if not lines and kind != "bag":
        return None
    voids = sum(line.void for line in lines)
    kind = kind or ("new" if not voids else "void" if voids == len(lines) else "modify")
    if course is None:
        courses = {line.course for line in sent}
        course = courses.pop() if len(courses) == 1 else None
    fields = state.fields
    return Ticket(
        station=station,
        kind=kind,
        order_id=state.order_id,
        ticket_no=ticket_no,
        table=str(fields.get("table", "")),
        lines=tuple(lines),
        server=str(fields.get("server", "")),
        # an order that is brought to the customer says so on every station's ticket: it is packed to travel
        order_type="delivery" if is_delivery(fields) else str(fields.get("order_type", "dine in")),
        guests=fields.get("guests"),
        course=course,
        late=late,
        order_no=fields.get("order_no") if isinstance(fields.get("order_no"), int) else None,
        customer=str(fields.get("customer_name", "")),
        channel=str(fields.get("channel", "")),
        promised=_when(fields.get("promised_at")),
        allergies=allergy_lines(state, names),
        was_at=was_at,
        tab=state.is_tab,
        was_tab=was_tab,
    )


Paper = Ticket | Bill | DayPaper | PackSheet | PrepPaper
"""What a printer can be handed: a kitchen ticket, a guest's bill, the day's report, an order's pack sheet
or a day's prep list."""


@dataclass(frozen=True)
class Takes:
    """What one printer prints: called with the station a kitchen line is cooked at, it says whether the line
    belongs on this printer's ticket. `own` is the stations it serves, `first` whether it also stands in for
    every station with no printer (`served` is the stations that have one), and `whole` the takeout station
    when it takes this order whole for the bag. `skip` is the stations the screen that sent this prints no
    ticket at: a line cooked there is on no printer's ticket of its own (the bag's still lists it)."""

    own: frozenset[str] = frozenset()
    first: bool = False
    served: frozenset[str] = frozenset()
    whole: str | None = None
    skip: frozenset[str] = frozenset()

    def cooks(self, station: str | None) -> bool:
        if station in self.skip:
            return False
        return station in self.own or (self.first and station not in self.served)

    def __call__(self, station: str | None) -> bool:
        return self.whole is not None or self.cooks(station)

    def readers(self, station: str | None) -> frozenset[str | None]:
        """The stations a line cooked at `station` is printed for here: its own, when this printer prints
        that station's tickets, and the takeout station when the order prints whole for the bag. A choice
        hidden from all of them is left off; one any of them reads prints."""
        cook = {station} if self.cooks(station) else set()
        return frozenset(cook | ({self.whole} if self.whole is not None else set()))


def _read_here(k: Mapping[str, Any], routes: Callable[[str | None], bool] | None) -> set[int]:
    """Which of a kitchen line's choices this ticket lists, by their place in `labels`: all of them, less the
    ones every station the ticket is printed for leaves off (`Group.hidden_at`, kept on the line as `hidden`)."""
    count = len(k.get("labels") or ())
    hidden = k.get("hidden") or ()
    if not hidden:
        return set(range(count))
    station = k.get("station")
    readers = routes.readers(station) if isinstance(routes, Takes) else frozenset({station})
    return {i for i in range(count) if i >= len(hidden) or not readers <= set(hidden[i])}


def _ticket_lines(
    lines: list[Line],
    routes: Callable[[str | None], bool] | None,
    *,
    void: bool,
    allergies: Mapping[int, str] | None = None,
) -> list[TicketLine]:
    """`allergies` is what was told for each seat, in words: it prints under that seat's dishes."""
    out = []
    for line in lines:
        kitchen = (line.priced or {}).get("kitchen")
        if not kitchen:  # a line typed on the phase 0 demo screen
            kitchen = [{"qty": 1, "label": line.item, "labels": []}]
        # A dish sent to a second station (a "take out" choice, a to-go order) is the same words again
        # there; a printer that takes both stations says it once, with every choice either of them reads.
        # The cooks do not read every choice (the rice, the soup): a station's ticket leaves off what the
        # menu hides from it.
        said: dict[tuple[Any, ...], tuple[Mapping[str, Any], set[int], list[str]]] = {}
        for k in kitchen:
            station = k.get("station")
            if routes is not None and not routes(station):
                continue
            labels, depths = tuple(k.get("labels", ())), tuple(int(d) for d in k.get("depths") or ())
            words = (k.get("qty", 1), k.get("label"), labels, depths, k.get("header"), k.get("note"))
            read = _read_here(k, routes)
            if words in said:
                said[words][1].update(read)
            else:
                said[words] = (k, read, [])
            if isinstance(station, str) and station not in said[words][2]:
                said[words][2].append(station)
        for (_, _, labels, depths, _, _), (k, read, cooked) in said.items():
            out.append(
                TicketLine(
                    qty=line.qty * int(k.get("qty", 1)),
                    label=str(k.get("label") or line.item),
                    modifiers=tuple(text for i, text in enumerate(labels) if i in read),
                    depths=tuple(depth for i, depth in enumerate(depths) if i in read),
                    # the dish's own note (a slot dish's, from its choice) and the order line's, under every line
                    note=" · ".join(n for n in (k.get("note"), line.note) if n),
                    seat=line.seat,
                    void=void,
                    changed=not void and line.modified_after_fire,
                    header=k.get("header") or None,
                    allergy=(allergies or {}).get(line.seat, "") if line.seat else "",
                    stations=tuple(cooked),
                )
            )
    return out


def ticket_for_fire(
    state: OrderState,
    op: Op,
    *,
    station: str,
    ticket_no: int,
    routes: Callable[[str | None], bool] | None = None,
) -> Ticket | None:
    """The lines one `fire` sends: active lines of the fired course (`*` = every course) that no earlier
    fire sent. `state` may be replayed with or without the fire itself."""
    course = op.data.get("course", "*")
    lines = [
        line
        for line in state.ordered_lines()
        if line.active and (course == "*" or line.course == course) and line.fired_at in (None, op.hlc)
    ]
    return ticket_for(
        state,
        lines,
        station=station,
        ticket_no=ticket_no,
        routes=routes,
        course=None if course == "*" else course,
    )


class PrintService:
    def __init__(
        self,
        printers: list[Printer] | Callable[[], list[Printer]],
        *,
        store: JobStore | None = None,
        direct: bool = True,
        send: Callable[[str, bytes], None] = send_raw,
        font: str | None = None,
        dots: int = 576,
        now: Callable[[], int] = wall_clock_ms,
        late_after_ms: int = LATE_AFTER_MS,
        held: HeldTickets | None = None,
    ) -> None:
        self._printers = printers
        self.store = store or JobStore()
        self.held = held if held is not None else HeldTickets()
        """What waits of the orders sent ahead of their time (`pos.printing.held`): kept in the database on a
        hub, so their tickets print when the time comes whatever happened to the hub in between."""
        self._holding = threading.Lock()  # one at a time decides what waits and what prints of an order
        self.direct = direct
        self._send = send
        self._font = font or find_font()
        self._dots = dots
        self._now = now
        self._late_after_ms = late_after_ms
        self._tickets = itertools.count(1)
        self._lock = threading.Lock()
        self.course_names: Callable[[], Mapping[str, str]] | None = None
        """Course id -> name as the manager set it (the API wires the coursing setting in); a ticket prints
        the name, or the id of a course that is no longer on the list."""
        self.station_names: Callable[[], Mapping[str, str]] | None = None
        """Station code -> name as the menu has it (`wok1` -> `Wok 1`), for the head of the ticket."""
        self.takeout_station: Callable[[], str | None] = lambda: None
        """The station a to-go order prints whole at, besides its lines' own stations; None for none."""
        self.allergen_names: Callable[[], Mapping[str, str]] = dict
        """Allergen code -> name as the menu has it (`peanut` -> `Peanuts`), for the allergies on a ticket; a
        code the menu does not name prints as it is."""
        self.ticket_words: Callable[[], Mapping[str, Any]] = dict
        """What a ticket says about the other tickets of the same send (the `tickets` setting): `numbered` for
        "Ticket 2 of 3", `also_at` for "Also at: Wok 2, Sushi Bar"; and `paid`, for PAID or NOT PAID on the
        takeout counter's copy of a to-go order. None of them until the API wires the setting in."""
        self.check_of: Callable[[OrderState], Mapping[str, Any]] | None = None
        """An order's check as the hub reckons it (`total`, `paid`, `due`, `unpriced`), for the takeout
        counter's PAID or NOT PAID. The API wires it in; without it no ticket speaks of money."""
        self.skips: Callable[[str], frozenset[str]] = lambda device: frozenset()
        """The stations a screen prints no ticket at, by its device name (the `ticket_skips` setting): what is
        sent or voided from it prints nothing there. None for any screen until the API wires the setting in."""
        self.bill_place: Callable[[], str | None] = lambda: None
        """The printer the location's bills print at, by id (the `bill` setting); None when the location has
        not said, and for a printer that is no longer there."""
        self.state_of: Callable[[str], OrderState | None] | None = None
        """An order as the log has it now, by id (the API wires the store in): what a ticket that waited for
        its time is made from. Without it nothing that waits is released."""

    @classmethod
    def from_env(cls) -> PrintService:
        return cls(printers_from_env(), direct=os.environ.get("POS_PRINT_DIRECT", "1") != "0")

    @property
    def printers(self) -> list[Printer]:
        """The printers as they stand now: the setting is read each time, so a save takes effect at once."""
        return list(self._printers() if callable(self._printers) else self._printers)

    @printers.setter
    def printers(self, printers: list[Printer] | Callable[[], list[Printer]]) -> None:
        self._printers = printers

    def printer(self, name: str) -> Printer | None:
        """By id, else the first printer on the station of that name."""
        return self._named(self.printers, name)

    @staticmethod
    def _named(printers: list[Printer], name: str) -> Printer | None:
        by_id = next((p for p in printers if p.id == name), None)
        return by_id or next((p for p in printers if name in p.stations), None)

    def bill_printer(self, asked: str | None = None, *, location: bool = True) -> Printer | None:
        """Where a guest's bill prints: the printer asked for (a screen that keeps its own, the one beside
        it), else the location's, else the takeout station's (the counter, where people pay), else the first
        printer. A printer that is no longer there is passed over, so a bill is never refused for a stale
        choice; None only when the location has no printer at all. `location=False` leaves the location's own
        choice out (a manager trying another before saving it)."""
        printers = self.printers
        for name in (asked, self.bill_place() if location else None, self.takeout_station()):
            found = self._named(printers, name) if name else None
            if found is not None:
                return found
        return printers[0] if printers else None

    def pack_printer(self, asked: str | None = None) -> Printer | None:
        """Where an order's pack sheet prints: the printer asked for, else the takeout station's (where the
        bag is packed), else where the location's bills print. None only when the location has no printer."""
        printers = self.printers
        for name in (asked, self.takeout_station()):
            found = self._named(printers, name) if name else None
            if found is not None:
                return found
        return self.bill_printer()

    def station_name(self, code: str) -> str:
        names = self.station_names() if self.station_names is not None else {}
        return names.get(code) or code

    def head(self, printer: Printer) -> str:
        """What heads the printer's tickets: its station's name, or every one's when it serves several
        ("Wok 1 + Wok 2"; past three, "Wok 1 + 3 more")."""
        names = [self.station_name(code) for code in printer.stations]
        return " + ".join(names) if len(names) <= 3 else f"{names[0]} + {len(names) - 1} more"

    def on_ops(self, ops_of: Callable[[str], list[Op]], ops: list[Op]) -> list[PrintJob]:
        """Called after operations are stored. Each order's tickets come from comparing the order before and
        after this batch, so a fire prints only lines not sent yet, a void of a sent line prints at once,
        and a change (void plus a new line plus a fire, sent together) prints as one ticket. A batch taken
        while no backend answered prints headed "late", with the time the operator took it.

        An allergy told, changed or taken off after dishes went to the kitchen prints a ticket of its own at
        every station that has some of them, headed ALLERGY and listing those dishes: the tickets the cooks
        are working from were printed without it.

        A screen told to print no ticket at some stations (`skips`) sends and voids without one there. The
        ALLERGY notice and the MOVED slip print at every station all the same, whoever's screen they come from.

        Food on its way that changes table (the check moved, or its dishes went onto a check at another
        table) prints a slip headed MOVED at every station that has some of it, with the table on the cooks'
        tickets and the table it goes to now (`table_changes`; the location's `tickets.moved` turns it off).
        A bar tab that sits down is the same: the slip says whose tab the drinks were made for and the table
        they go to now (`tab_changes`).

        What goes in the bag of a to-go order (`pos.orders.bag`) is on the takeout station's ticket. When the
        answer changes after the order went to the kitchen, that station gets a slip headed BAG with the
        answer as it stands (`bag_slip`).

        An order sent ahead of its time prints nothing here: its dishes are put on hold (`_hold`) and print
        as one ticket a station when the time comes (`release_due`), with the allergies, the money and the bag
        as they stand then. A dish taken off while it waits was never on paper, so no void prints for it."""
        if not self.printers:
            return []
        jobs: list[PrintJob] = []
        by_order: dict[str, list[Op]] = {}
        for op in ops:
            by_order.setdefault(op.order_id, []).append(op)
        for order_id, batch in by_order.items():
            new = {op.op_id for op in batch}
            everything = ops_of(order_id)
            before = replay([op for op in everything if op.op_id not in new], order_id)
            after = replay(everything, order_id)
            sent, voided = kitchen_changes(before, after)
            now = self._now()
            waiting: frozenset[str] = frozenset()  # the dishes still on hold after this batch
            out: frozenset[str] = frozenset()  # the dishes that were on hold and print with this batch
            if is_to_go(after):
                key = next((op for op in batch if op.kind == "fire"), batch[0])
                released, waiting, out, sent, voided = self._hold(after, sent, voided, key=key, now=now)
                jobs.extend(released)
            printed = bool(sent) or bool(out)  # a ticket of this batch says the order as it stands now
            if sent or voided:
                key = next((op for op in batch if op.kind in ("fire", "void_line")), batch[0])
                late = taken_offline(batch, now, self._late_after_ms)
                skip = self.skips(key.device)
                jobs.extend(self.send(after, sent, voided, key=key.op_id, late=late, skip=skip))
            if printed:
                carried = {line.line_id for line in sent} | out
                skips = self.skips(next((op for op in batch if op.kind == "fire"), batch[0]).device)
                jobs.extend(self._pack_with(after, carried, key=f"{batch[0].op_id}:pack", skip=skips))
            if _told(before) != _told(after):
                gone = {line.line_id for line in sent} | out
                had = [
                    line
                    for line in after.ordered_lines()
                    if line.active
                    and line.fired_at is not None
                    and line.line_id not in gone
                    and line.line_id not in waiting  # not on paper yet: its ticket will say it
                ]
                if had:
                    key = next(op for op in batch if op.kind == "allergy")
                    late = taken_offline(batch, self._now(), self._late_after_ms)
                    jobs.extend(self.send(after, had, [], key=key.op_id, late=late, kind="allergy"))
            bag = self.bag(after)
            if bag is not None and bag != self.bag(before) and not printed:
                # The answer changed and no ticket of this batch carries it. With dishes already at the
                # kitchen, the bag is being packed from a ticket that says otherwise.
                on_paper = (
                    line.active and line.fired_at is not None and line.line_id not in waiting
                    for line in after.lines.values()
                )
                if any(on_paper):
                    key = next(op for op in batch if op.kind in ("create", "set_field") and BAG in op.data)
                    jobs.extend(self.bag_slip(after, key=f"{key.op_id}:bag"))
            if self.ticket_words().get("moved"):
                for was_at, lines in table_changes(before, after, self._now()):
                    slip = f"{batch[0].op_id}:moved:{was_at}"
                    jobs.extend(self.send(after, lines, [], key=slip, kind="moved", was_at=was_at))
                for name, lines in tab_changes(before, after, self._now()):
                    slip = f"{batch[0].op_id}:moved:tab:{name}"
                    jobs.extend(self.send(after, lines, [], key=slip, kind="moved", was_tab=name))
        return jobs

    def _hold(
        self, after: OrderState, sent: list[Line], voided: list[Line], *, key: Op, now: int
    ) -> tuple[list[PrintJob], frozenset[str], frozenset[str], list[Line], list[Line]]:
        """What a batch on a to-go order means for the dishes that wait for its time. While the order's time
        is still ahead, the dishes it sends are put on hold and print nothing; a dish on hold that was taken
        off is dropped quietly, since no ticket of it is on paper. Once the time has come (the clock passed
        it, or the order was moved up), everything on hold prints with this batch, as one ticket.

        Gives the jobs it queued, the dishes still on hold, the dishes those jobs carry, and what is left of
        `sent` and `voided` to print the usual way: nothing of `sent` while the order waits or when it went
        out with the held ones, and only the voids of dishes that were on paper."""
        with self._holding:
            try:
                held = self.held.get(after.order_id)
            except Exception:  # noqa: BLE001 - what waits cannot be read: the order call goes through all the same
                held = None
            waits = after.status != "void" and lead_delay(after, now) > 0
            if held is None and not (waits and sent):
                return [], frozenset(), frozenset(), sent, voided
            was = held.lines if held is not None else frozenset()
            off = {line.line_id for line in voided if line.line_id in was}
            parts = list(held.without(off).parts) if held is not None else []
            if sent:
                skip = tuple(sorted(self.skips(key.device)))
                parts.append(Part(key.op_id, tuple(line.line_id for line in sent), skip))
            now_held = Held(after.order_id, starts_ms(after) or now, tuple(parts))
            voided = [line for line in voided if line.line_id not in was]
            if waits:
                try:
                    if now_held != held:
                        self.held.put(now_held)
                    return [], now_held.lines, frozenset(), [], voided
                except Exception:  # noqa: BLE001 - what waits could not be written down
                    # A ticket that prints early is on paper, with its day on it; one that was never written
                    # down would be lost. So it prints now, and from here on it is an order the kitchen has.
                    pass
            jobs = self._print_held(now_held, after) if after.status != "void" else []
            try:
                self.held.drop(after.order_id)
            except Exception:  # noqa: BLE001 - still written down: it prints again at its time, never not at all
                pass
            return jobs, frozenset(), now_held.lines, [], voided

    def _print_held(self, held: Held, state: OrderState) -> list[PrintJob]:
        """The tickets of dishes that waited for their time, from the order as it stands: the dishes still on
        it, one ticket a station. Dishes sent from a screen that prints no ticket at some station go on a
        ticket of their own, which leaves that station out as theirs would have."""
        by_skip: dict[tuple[str, ...], tuple[str, set[str]]] = {}
        for part in held.parts:
            by_skip.setdefault(part.skip, (part.key, set()))[1].update(part.lines)
        jobs: list[PrintJob] = []
        for skip, (key, ids) in by_skip.items():
            # the kitchen sees every one of them for the first time: none is a change to a ticket it has
            lines = [
                replace(line, modified_after_fire=False)
                for line in state.ordered_lines()
                if line.line_id in ids and line.active and line.fired_at
            ]
            if lines:
                jobs.extend(self.send(state, lines, [], key=key, skip=frozenset(skip)))
        return jobs

    def adopt(self, orders: Iterable[OrderState]) -> list[str]:
        """Puts on hold the sent dishes of orders whose time is still ahead and of which nothing is written
        down: what a hub does as it starts with a list of what waits that was only just begun
        (`HeldTickets.fresh`). Before hubs kept that list in the database, such an order's tickets waited in
        the hub's memory, and the restart that brought this in lost them. An order that has something on hold
        is left as it is. Gives the orders it took on."""
        now = self._now()
        taken = []
        for state in orders:
            if not is_to_go(state) or state.status == "void" or lead_delay(state, now) <= 0:
                continue
            with self._holding:
                if self.held.get(state.order_id) is not None:
                    continue
                lines = tuple(
                    line.line_id
                    for line in state.ordered_lines()
                    if line.active and line.fired_at is not None and not line.arrived_sent
                )
                if lines:
                    part = Part(f"held:{state.order_id}", lines)
                    self.held.put(Held(state.order_id, starts_ms(state) or now, (part,)))
                    taken.append(state.order_id)
        return taken

    def release_due(self) -> list[PrintJob]:
        """Prints the tickets of the orders sent ahead whose time has come: each from the order as the log has
        it now. The hub's loop calls it every few seconds (`start_retrying`), and so does a relay asking for
        work, so a ticket that was due while the hub was off prints as soon as it is back. An order voided
        whole prints nothing; one that was closed prints all the same, since closing a check does not cancel
        the food. An order whose time was moved since it was put on hold waits for the new one."""
        if self.state_of is None or not self.printers:
            return []
        jobs: list[PrintJob] = []
        now = self._now()
        for due in self.held.due(now + SOON_MS):
            with self._holding:
                held = self.held.get(due.order_id)  # as it stands now: a batch may have changed it meanwhile
                state = self.state_of(due.order_id) if held is not None else None
                if held is None or state is None:
                    continue
                if state.status == "void":
                    self.held.drop(held.order_id)
                elif lead_delay(state, now) > 0:
                    self.held.put(replace(held, start_ms=starts_ms(state) or now))
                else:
                    tickets = self._print_held(held, state)
                    jobs.extend(tickets)
                    if tickets:
                        # a sheet for the packer too, unless every screen that sent it prints nothing there
                        skips = frozenset.intersection(*(frozenset(part.skip) for part in held.parts))
                        key = f"{held.parts[0].key}:pack"
                        jobs.extend(self._pack_with(state, held.lines, key=key, skip=skips))
                    self.held.drop(held.order_id)
        return jobs

    def not_yet(self) -> Callable[[OrderState], frozenset[str]]:
        """For a station's screen (`pos.printing.screen`): given an order, its sent dishes that are not in the
        kitchen yet, because the order was sent ahead of its time and its tickets still wait. That is what is
        on hold, read once for all the orders. A location with no printer puts nothing on hold, so there the
        clock alone says: every sent dish of an order whose time is still ahead."""
        if self.printers:
            try:
                held = {waits.order_id: waits.lines for waits in self.held.all()}
            except Exception:  # noqa: BLE001 - what waits cannot be read: the screen shows the dish early
                held = {}
            return lambda state: held.get(state.order_id, frozenset())
        now = self._now()

        def by_the_clock(state: OrderState) -> frozenset[str]:
            if not is_to_go(state) or lead_delay(state, now) <= 0:
                return frozenset()
            return frozenset(line.line_id for line in state.lines.values() if line.fired_at is not None)

        return by_the_clock

    def pack_sheet(self, state: OrderState) -> PackSheet | None:
        """The pack sheet of a to-go order as the log has it now (`pos.printing.pack`): every dish on it, in
        the words the takeout station's ticket uses, the ones nobody sent apart; who it is for and when, what
        its event needs, the allergies, the money and what else goes in the bag. None for a table's order and
        for an order with no dish on it."""
        lines = [line for line in state.ordered_lines() if line.active]
        if not is_to_go(state) or not lines:
            return None
        names = self.allergen_names()
        by_seat = {told["seat"]: allergy_words(told, names) for told in state.allergy_list() if told.get("seat")}
        reads = Takes(whole=self.takeout_station() or "")  # every dish, with the choices the packer reads
        sent = [line for line in lines if line.fired_at is not None or line.arrived_sent]
        unsent = [line for line in lines if line.fired_at is None and not line.arrived_sent]
        fields = state.fields
        guests = fields.get("event_guests")
        return PackSheet(
            order_id=state.order_id,
            lines=tuple(_ticket_lines(sent, reads, void=False, allergies=by_seat)),
            unsent=tuple(_ticket_lines(unsent, reads, void=False, allergies=by_seat)),
            count=sum(line.qty for line in lines),
            order_no=fields.get("order_no") if isinstance(fields.get("order_no"), int) else None,
            customer=str(fields.get("customer_name", "")),
            phone=" ".join(str(fields.get("phone") or "").split()),
            channel=str(fields.get("channel", "")),
            promised=_local(fields.get("promised_at")),
            guests=guests if isinstance(guests, int) and not isinstance(guests, bool) and guests > 0 else None,
            handover=str(fields.get("handover") or ""),
            address=" ".join(str(fields.get("address") or "").split()),
            note=" ".join(str(fields.get("event_note") or "").split()),
            allergies=allergy_lines(state, names),
            money=self.money(state),
            bag=self.bag(state),
            at=_local(self._now()) or datetime.now(),
        )

    def print_pack(
        self, state: OrderState, *, asked: str | None = None, job_id: str | None = None
    ) -> tuple[PrintJob, Printer] | None:
        """Prints the order's pack sheet where pack sheets print (`pack_printer`), and says where. None when
        there is nothing to print it from, or nothing to print it on."""
        sheet = self.pack_sheet(state)
        printer = self.pack_printer(asked) if sheet is not None else None
        if sheet is None or printer is None:
            return None
        return self.queue(sheet, printer, job_id=job_id), printer

    def _pack_with(
        self, state: OrderState, carried: Iterable[str], *, key: str, skip: frozenset[str] = frozenset()
    ) -> list[PrintJob]:
        """The pack sheet that comes with a catering order's tickets, the first time dishes of it reach paper
        (`carried`: the dishes going out now): none when some dish was on paper before, so dishes added later
        print their tickets and no second sheet (anyone can print one again, with the order as it stands).
        The location's `tickets.pack` turns it off; a screen that prints no ticket at the takeout station
        (`skip`) gets no sheet there either."""
        if str(state.fields.get("channel") or "") != "catering" or state.status == "void":
            return []
        if not self.ticket_words().get("pack"):
            return []
        takeout = self.takeout_station()
        if takeout is not None and takeout in skip:
            return []
        now = set(carried)
        if any(line.active and line.fired_at is not None and line.line_id not in now for line in state.lines.values()):
            return []
        made = self.print_pack(state, job_id=key)
        return [made[0]] if made is not None else []

    def send(
        self,
        state: OrderState,
        sent: list[Line],
        voided: list[Line],
        *,
        key: str,
        late: datetime | None = None,
        kind: str | None = None,
        was_at: str = "",
        was_tab: str | None = None,
        skip: frozenset[str] = frozenset(),
    ) -> list[PrintJob]:
        """One ticket per printer that has lines in this change. `skip` is the stations the screen that sent
        it prints no ticket at: their lines are on nobody's ticket but the bag's, and such a station is neither
        counted nor named on the other tickets, since no ticket of it is on its way. The takeout station's
        copy of a to-go order also says where the money stands (`money`) and what else goes in the bag
        (`bag`).
        `kind` is `allergy` for the notice that follows dishes already sent, which lists them again, and
        `moved` for the slip that says they now go to another table than `was_at`, the one they were sent for
        (or than the bar, when they were sent for the tab called `was_tab`).

        When the change has more than one station cooking, each ticket can say so (the `tickets` setting):
        "Ticket 2 of 3" numbers the tickets that have something to cook, in the order the printers stand, and
        "Also at: Wok 2, Sushi Bar" names the stations cooking the rest. The takeout counter packs and does not
        cook: its ticket is not numbered and it is not named on the cooks', but it reads where the food is
        coming from like any other."""
        with self._lock:
            ticket_no = next(self._tickets)
        printers = self.printers
        printed_at = datetime.fromtimestamp(self._now() / 1000)  # by the hub's clock, like the times it reckons by
        courses = self.course_names() if self.course_names is not None else {}
        allergens = self.allergen_names()
        words = self.ticket_words() if kind is None else {}  # a notice is no send: nothing new is cooking
        money = self.money(state) if kind is None else None
        bag = self.bag(state) if kind is None else None
        made: list[tuple[Printer, Ticket, tuple[str, ...]]] = []
        for printer, routes in self.routing(printers, to_go=is_to_go(state), skip=skip):
            ticket = ticket_for(
                state,
                sent,
                voided,
                station=self.head(printer),
                ticket_no=ticket_no,
                routes=routes,
                late=late,
                allergens=allergens,
                kind=kind,
                was_at=was_at,
                was_tab=was_tab,
            )
            if ticket is None:
                continue
            ticket = replace(ticket, at=printed_at)
            if ticket.course in courses:
                ticket = replace(ticket, course=courses[ticket.course])
            if routes.whole is not None and kind is None:
                # the copy that goes in the bag: where the money stands, and what else the customer wants in it
                ticket = replace(ticket, money=money, bag=bag)
            made.append((printer, ticket, self.cooking(printer, routes, [*voided, *sent])))
        cooks = sum(1 for _, _, cooked in made if cooked)
        jobs, nth = [], 0
        for printer, ticket, cooked in made:
            nth += bool(cooked)
            if words.get("numbered") and cooked and cooks > 1:
                ticket = replace(ticket, part=(nth, cooks))
            if words.get("also_at"):
                others = dict.fromkeys(name for _, _, there in made for name in there if name not in cooked)
                ticket = replace(ticket, also_at=tuple(others))
            jobs.append(self.queue(ticket, printer, job_id=f"{key}:{printer.id}", printers=printers))
        return jobs

    def bag(self, state: OrderState) -> tuple[str, ...] | None:
        """What the takeout counter's ticket for this order says goes in the bag besides the food, a line a
        choice; empty when the customer wanted nothing; None for a table's order and while nobody was asked."""
        answer = bag_of(state.fields) if is_to_go(state) else None
        return None if answer is None else bag_lines(answer)

    def bag_slip(self, state: OrderState, *, key: str) -> list[PrintJob]:
        """The slip the takeout station gets when what goes in the bag changes after the order was sent: the
        order as its ticket was headed, no dishes, and the answer as it stands now. The ticket the bag is
        packed from was printed with the old one."""
        printers = self.printers
        jobs = []
        for printer, routes in self.routing(printers, to_go=True):
            if routes.whole is None:
                continue
            with self._lock:
                ticket_no = next(self._tickets)
            ticket = ticket_for(state, [], station=self.head(printer), ticket_no=ticket_no, kind="bag")
            if ticket is None:
                continue
            ticket = replace(ticket, bag=self.bag(state), allergies=())  # the dishes' business, not the bag's
            jobs.append(self.queue(ticket, printer, job_id=f"{key}:{printer.id}", printers=printers))
        return jobs

    def money(self, state: OrderState) -> Money | None:
        """What the takeout counter's ticket for this order says about the money, as the order stands: None
        for a table's order, with the location's switch off (`tickets.paid`), or before the API wired the
        check in."""
        if self.check_of is None or not is_to_go(state) or not self.ticket_words().get("paid"):
            return None
        return money_words(self.check_of(state))

    def cooking(self, printer: Printer, takes: Takes, lines: Iterable[Line]) -> tuple[str, ...]:
        """The stations these lines are cooked at on this printer's ticket, by name, in the order they stand on
        it: the stations the printer prints for itself, not what it only lists for the bag, and never the
        takeout counter, which packs. A line with no station is cooked where its ticket comes out."""
        takeout = self.takeout_station()
        names: dict[str, None] = {}
        for line in lines:
            for k in (line.priced or {}).get("kitchen") or [{}]:
                station = k.get("station")
                if takes.cooks(station) and (station is None or station != takeout):
                    names.setdefault(self.station_name(station) if station else self.head(printer))
        return tuple(names)

    def routing(
        self, printers: list[Printer], *, to_go: bool, skip: frozenset[str] = frozenset()
    ) -> list[tuple[Printer, Takes]]:
        """Which lines each printer takes, by station: a printer takes its own stations (the first printer on
        a station, when two list one); the first printer in the list also takes every station without a
        printer and lines with none, so nothing fired is left unprinted; and the takeout station's printer
        takes every line of a to-go order, whole, for the bag. Each `Takes` also says for which stations a
        line prints there, which decides the choices it lists (`Group.hidden_at`). `skip` is the stations the
        sending screen prints no ticket at: nobody takes their lines, the first printer included, and the bag's
        copy is left out too when the takeout station itself is skipped."""
        served: dict[str, Printer] = {}
        for printer in printers:
            for station in printer.stations:
                served.setdefault(station, printer)
        takeout = self.takeout_station() if to_go else None
        if takeout in skip:
            takeout = None
        out = []
        for i, printer in enumerate(printers):
            own = frozenset(station for station in printer.stations if served[station] is printer)
            whole = takeout if takeout is not None and printer is served.get(takeout) else None
            out.append((printer, Takes(own, first=i == 0, served=frozenset(served), whole=whole, skip=skip)))
        return out

    def queue(
        self,
        ticket: Paper,
        printer: Printer,
        *,
        job_id: str | None = None,
        delay: float = 0.0,
        printers: list[Printer] | None = None,
    ) -> PrintJob:
        """Renders the ticket (or a guest's bill, the day's report, a pack sheet, a prep list) for the printer
        and for each of its fallbacks (headed with whose it is), and queues it; a hub starts writing it at
        once."""
        data, fallbacks = self._rendered(ticket, printer, printers)
        job = self.store.create(printer.address, data, job_id=job_id, delay=delay, fallbacks=fallbacks)
        if self.direct and delay <= 0:
            threading.Thread(target=self._deliver, args=(job,), daemon=True).start()
        return job

    def _rendered(
        self, ticket: Paper, printer: Printer, printers: list[Printer] | None = None
    ) -> tuple[bytes, list[tuple[str, bytes]]]:
        """The ticket as the printer prints it, and as each of its fallbacks does (address, bytes), in order.
        A fallback's copy says whose it is: the ticket's station, or for a bill or a day's report the printer
        it was for."""

        def drawn(paper: Paper, on: Printer) -> bytes:
            if isinstance(paper, Bill):
                return render_bill(paper, dots=self._dots, font=self._font, dialect=on.dialect)
            if isinstance(paper, DayPaper):
                return render_day(paper, dots=self._dots, font=self._font, dialect=on.dialect)
            if isinstance(paper, PackSheet):
                return render_pack(paper, dots=self._dots, font=self._font, dialect=on.dialect)
            if isinstance(paper, PrepPaper):
                return render_prep(paper, dots=self._dots, font=self._font, dialect=on.dialect)
            return render(paper, dots=self._dots, font=self._font, dialect=on.dialect)

        data = drawn(ticket, printer)
        fallbacks = []
        by_id = {p.id: p for p in (printers if printers is not None else self.printers)}
        whose = ticket.station if isinstance(ticket, Ticket) else self.head(printer)
        for fallback_id in printer.fallbacks:
            fallback = by_id.get(fallback_id)
            if fallback is None or fallback.address == printer.address:
                continue
            fallbacks.append((fallback.address, drawn(replace(ticket, reprinted_from=whose), fallback)))
        return data, fallbacks

    def _deliver(self, job: PrintJob) -> None:
        self.store.deliver_direct(job, send=self._send)

    def start_retrying(self, interval: float = 3.0) -> None:
        """A daemon that every `interval` seconds makes the tickets of the orders sent ahead whose time has
        come (`release_due`), and on a hub gives undelivered jobs another go."""

        def loop() -> None:
            while True:
                time.sleep(interval)
                for step in (self.release_due, self.retry_pending):
                    try:
                        step()
                    except Exception:  # noqa: BLE001 - a printing hiccup must never stop the loop
                        pass

        threading.Thread(target=loop, name="print-retry", daemon=True).start()

    def retry_pending(self) -> int:
        """The hub's second chance for jobs its first write could not deliver. Returns how many printed."""
        if not self.direct:
            return 0
        return sum(1 for job in self.store.pending() if self.store.deliver_direct(job, send=self._send))
