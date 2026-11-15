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
from typing import Any

from ..sync.hlc import wall_clock_ms
from ..sync.oplog import Line, Op, OrderState, replay
from .escpos import find_font
from .jobs import JobStore, PrintJob, send_raw
from .ticket import AUTO, DIALECTS, Ticket, TicketLine, render

LATE_AFTER_MS = 10 * 60 * 1000
"""An operation stamped this long before it arrives was queued through an outage, flagged or not."""

DEFAULT_LEAD_MINUTES = 15
"""How long before its promised time a future order's ticket prints when the order carries no quote."""


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
    and lines it already had that are now off the order (a void, or the old half of a change)."""
    sent, voided = [], []
    for line in after.ordered_lines():
        was = before.lines.get(line.line_id) if before is not None else None
        if line.active and line.fired_at is not None and (was is None or was.fired_at is None):
            sent.append(line)
        elif not line.active and was is not None and was.active and was.fired_at is not None:
            voided.append(line)
    return sent, voided


def taken_offline(ops: Iterable[Op], now_ms: int, late_after_ms: int = LATE_AFTER_MS) -> datetime | None:
    """When the operator took a batch that reaches the backend late: a terminal with no backend flagged the
    operations `offline` (ADR 6), or their stamps are older than `late_after_ms` (an app that did not say
    so). None for a batch that arrived in good time. The kitchen ticket is headed "late" with that time."""
    late = [op for op in ops if op.data.get("offline") or now_ms - op.hlc.wall_ms > late_after_ms]
    if not late:
        return None
    return datetime.fromtimestamp(min(op.hlc.wall_ms for op in late) / 1000)


def lead_delay(state: OrderState, now_ms: int, *, default_lead_minutes: int = DEFAULT_LEAD_MINUTES) -> float:
    """Seconds a ticket for this order waits before printing: a future order (architecture section 12,
    "Future orders") fires on its own ahead of its promised time by the minutes quoted for it, so the kitchen
    sees it when it is time to cook, not when it was taken. 0 for an order due now or soon."""
    promised = state.fields.get("promised_at")
    if not isinstance(promised, int):
        return 0.0
    quoted = state.fields.get("quoted_minutes")
    lead_ms = (quoted if isinstance(quoted, int) and quoted > 0 else default_lead_minutes) * 60_000
    delay = (promised - lead_ms - now_ms) / 1000
    return delay if delay > 60 else 0.0


def _told(state: OrderState) -> list[tuple[Any, ...]]:
    """The allergies on the order as the kitchen reads them: who typed one in is not its business."""
    return [(told["seat"], tuple(told["allergens"]), told["note"]) for told in state.allergy_list()]


def _when(ms: Any) -> datetime | None:
    return datetime.fromtimestamp(ms / 1000) if isinstance(ms, int) else None


def allergy_words(told: Mapping[str, Any], names: Mapping[str, str]) -> str:
    """One allergy in words: its allergens by name, then whatever else was said ("Peanuts, Sesame - no MSG").
    Plain letters, so a printer writes it as text."""
    listed = ", ".join(names.get(code) or code for code in told.get("allergens") or ())
    return " - ".join(part for part in (listed, str(told.get("note") or "")) if part)


def allergy_lines(state: OrderState, names: Mapping[str, str]) -> tuple[str, ...]:
    """The allergies told on the order, one a line, the whole table's first ("Table: Peanuts", "Seat 2:
    Sesame"; "Order:" on an order with no table)."""
    whole = "Table" if state.fields.get("table") else "Order"
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
) -> Ticket | None:
    """One station's ticket: voided lines first, printed in reverse, then the lines being sent.
    `routes(station)` says whether a kitchen line cooked at that station belongs on this ticket; without it,
    every line does. `late` is when the operator took it, for a batch that reached the backend late.
    `allergens` names the menu's allergens by code, for the allergies told on the order: they head every
    station's ticket, and a seat's own stands under each of its dishes. `kind` says what the ticket is when it
    is not for dishes sent or voided (`allergy`: an allergy told after `sent` had gone to the kitchen)."""
    names = allergens or {}
    by_seat = {told["seat"]: allergy_words(told, names) for told in state.allergy_list() if told.get("seat")}
    lines = [
        *_ticket_lines(voided or [], routes, void=True, allergies=by_seat),
        *_ticket_lines(sent, routes, void=False, allergies=by_seat),
    ]
    if not lines:
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
        order_type=str(fields.get("order_type", "dine in")),
        guests=fields.get("guests"),
        course=course,
        late=late,
        order_no=fields.get("order_no") if isinstance(fields.get("order_no"), int) else None,
        customer=str(fields.get("customer_name", "")),
        channel=str(fields.get("channel", "")),
        promised=_when(fields.get("promised_at")),
        allergies=allergy_lines(state, names),
    )


@dataclass(frozen=True)
class Takes:
    """What one printer prints: called with the station a kitchen line is cooked at, it says whether the line
    belongs on this printer's ticket. `own` is the stations it serves, `first` whether it also stands in for
    every station with no printer (`served` is the stations that have one), and `whole` the takeout station
    when it takes this order whole for the bag."""

    own: frozenset[str] = frozenset()
    first: bool = False
    served: frozenset[str] = frozenset()
    whole: str | None = None

    def cooks(self, station: str | None) -> bool:
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
        said: dict[tuple[Any, ...], tuple[Mapping[str, Any], set[int]]] = {}
        for k in kitchen:
            if routes is not None and not routes(k.get("station")):
                continue
            labels, depths = tuple(k.get("labels", ())), tuple(int(d) for d in k.get("depths") or ())
            words = (k.get("qty", 1), k.get("label"), labels, depths, k.get("header"), k.get("note"))
            read = _read_here(k, routes)
            if words in said:
                said[words][1].update(read)
            else:
                said[words] = (k, read)
        for (_, _, labels, depths, _, _), (k, read) in said.items():
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
    ) -> None:
        self._printers = printers
        self.store = store or JobStore()
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
        "Ticket 2 of 3", `also_at` for "Also at: Wok 2, Sushi Bar". Neither until the API wires the setting in."""

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
        printers = self.printers
        by_id = next((p for p in printers if p.id == name), None)
        return by_id or next((p for p in printers if name in p.stations), None)

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
        are working from were printed without it."""
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
            if sent or voided:
                key = next((op for op in batch if op.kind in ("fire", "void_line")), batch[0])
                now = self._now()
                late = taken_offline(batch, now, self._late_after_ms)
                delay = lead_delay(after, now) if not voided else 0.0  # a void prints at once
                jobs.extend(self.send(after, sent, voided, key=key.op_id, late=late, delay=delay))
            if _told(before) != _told(after):
                gone = {line.line_id for line in sent}
                had = [
                    line
                    for line in after.ordered_lines()
                    if line.active and line.fired_at is not None and line.line_id not in gone
                ]
                if had:
                    key = next(op for op in batch if op.kind == "allergy")
                    now = self._now()
                    late = taken_offline(batch, now, self._late_after_ms)
                    # with a future order's own tickets, when those are still waiting for their time
                    delay = lead_delay(after, now)
                    jobs.extend(self.send(after, had, [], key=key.op_id, late=late, delay=delay, kind="allergy"))
        return jobs

    def send(
        self,
        state: OrderState,
        sent: list[Line],
        voided: list[Line],
        *,
        key: str,
        late: datetime | None = None,
        delay: float = 0.0,
        kind: str | None = None,
    ) -> list[PrintJob]:
        """One ticket per printer that has lines in this change. `delay` seconds holds the tickets back (a
        future order's lead time); the hub's retry loop and the relays pick them up when they are due.
        `kind` is `allergy` for the notice that follows dishes already sent, which lists them again.

        When the change has more than one station cooking, each ticket can say so (the `tickets` setting):
        "Ticket 2 of 3" numbers the tickets that have something to cook, in the order the printers stand, and
        "Also at: Wok 2, Sushi Bar" names the stations cooking the rest. The takeout counter packs and does not
        cook: its ticket is not numbered and it is not named on the cooks', but it reads where the food is
        coming from like any other."""
        with self._lock:
            ticket_no = next(self._tickets)
        printers = self.printers
        courses = self.course_names() if self.course_names is not None else {}
        allergens = self.allergen_names()
        made: list[tuple[Printer, Ticket, tuple[str, ...]]] = []
        for printer, routes in self.routing(printers, to_go=is_to_go(state)):
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
            )
            if ticket is None:
                continue
            if ticket.course in courses:
                ticket = replace(ticket, course=courses[ticket.course])
            made.append((printer, ticket, self.cooking(printer, routes, [*voided, *sent])))
        words = self.ticket_words() if kind is None else {}  # a notice is no send: nothing new is cooking
        cooks = sum(1 for _, _, cooked in made if cooked)
        jobs, nth = [], 0
        for printer, ticket, cooked in made:
            nth += bool(cooked)
            if words.get("numbered") and cooked and cooks > 1:
                ticket = replace(ticket, part=(nth, cooks))
            if words.get("also_at"):
                others = dict.fromkeys(name for _, _, there in made for name in there if name not in cooked)
                ticket = replace(ticket, also_at=tuple(others))
            jobs.append(self.queue(ticket, printer, job_id=f"{key}:{printer.id}", delay=delay, printers=printers))
        return jobs

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

    def routing(self, printers: list[Printer], *, to_go: bool) -> list[tuple[Printer, Takes]]:
        """Which lines each printer takes, by station: a printer takes its own stations (the first printer on
        a station, when two list one); the first printer in the list also takes every station without a
        printer and lines with none, so nothing fired is left unprinted; and the takeout station's printer
        takes every line of a to-go order, whole, for the bag. Each `Takes` also says for which stations a
        line prints there, which decides the choices it lists (`Group.hidden_at`)."""
        served: dict[str, Printer] = {}
        for printer in printers:
            for station in printer.stations:
                served.setdefault(station, printer)
        takeout = self.takeout_station() if to_go else None
        out = []
        for i, printer in enumerate(printers):
            own = frozenset(station for station in printer.stations if served[station] is printer)
            whole = takeout if takeout is not None and printer is served.get(takeout) else None
            out.append((printer, Takes(own, first=i == 0, served=frozenset(served), whole=whole)))
        return out

    def queue(
        self,
        ticket: Ticket,
        printer: Printer,
        *,
        job_id: str | None = None,
        delay: float = 0.0,
        printers: list[Printer] | None = None,
    ) -> PrintJob:
        """Renders the ticket for the printer and for each of its fallbacks (headed with whose ticket it is),
        and queues it; a hub starts writing it at once."""
        data = render(ticket, dots=self._dots, font=self._font, dialect=printer.dialect)
        fallbacks = []
        by_id = {p.id: p for p in (printers if printers is not None else self.printers)}
        for fallback_id in printer.fallbacks:
            fallback = by_id.get(fallback_id)
            if fallback is None or fallback.address == printer.address:
                continue
            copy = replace(ticket, reprinted_from=ticket.station)
            rendered = render(copy, dots=self._dots, font=self._font, dialect=fallback.dialect)
            fallbacks.append((fallback.address, rendered))
        job = self.store.create(printer.address, data, job_id=job_id, delay=delay, fallbacks=fallbacks)
        if self.direct and delay <= 0:
            threading.Thread(target=self._deliver, args=(job,), daemon=True).start()
        return job

    def _deliver(self, job: PrintJob) -> None:
        self.store.deliver_direct(job, send=self._send)

    def start_retrying(self, interval: float = 3.0) -> None:
        """A daemon that gives undelivered jobs another go every `interval` seconds, and prints a future
        order's tickets when their time comes (hubs only)."""
        if not self.direct:
            return

        def loop() -> None:
            while True:
                time.sleep(interval)
                try:
                    self.retry_pending()
                except Exception:  # noqa: BLE001 - a printing hiccup must never stop the retry loop
                    pass

        threading.Thread(target=loop, name="print-retry", daemon=True).start()

    def retry_pending(self) -> int:
        """The hub's second chance for jobs its first write could not deliver. Returns how many printed."""
        if not self.direct:
            return 0
        return sum(1 for job in self.store.pending() if self.store.deliver_direct(job, send=self._send))
