"""Tickets from orders: a `fire` or a void of a sent line turns into one job per kitchen printer, delivered
by the hub or a relay.

Printers come from `POS_PRINTERS`, e.g. `kitchen=172.19.1.162/escpos,bar=172.19.1.14/star`
(name=host[:port][/dialect]). A hub writes jobs straight to the printers (`POS_PRINT_DIRECT=1`, the
default); the cloud cannot reach a LAN printer, so it runs with `POS_PRINT_DIRECT=0` and leaves jobs for
a terminal relay to claim. Either way the job store is the queue; the printing itself is retried in the
background and never holds up the order call.
"""

from __future__ import annotations

import itertools
import os
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from ..sync.oplog import Line, Op, OrderState, replay
from .escpos import find_font
from .jobs import JobStore, PrintJob, send_raw
from .ticket import DIALECTS, Ticket, TicketLine, render


@dataclass(frozen=True)
class Printer:
    name: str
    address: str  # host or host:port
    dialect: str = "escpos"

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


def printers_from_env(value: str | None = None) -> list[Printer]:
    raw = os.environ.get("POS_PRINTERS", "") if value is None else value
    return [Printer.parse(spec) for spec in raw.split(",") if spec.strip()]


def kitchen_changes(before: OrderState | None, after: OrderState) -> tuple[list[Line], list[Line]]:
    """What the kitchen must hear about between two replays of an order: lines sent for the first time,
    and lines it already had that are now off the order (a void, or the old half of a change)."""
    sent, voided = [], []
    for line_id, line in after.lines.items():
        was = before.lines.get(line_id) if before is not None else None
        if line.active and line.fired_at is not None and (was is None or was.fired_at is None):
            sent.append(line)
        elif not line.active and was is not None and was.active and was.fired_at is not None:
            voided.append(line)
    return sent, voided


def ticket_for(
    state: OrderState,
    sent: list[Line],
    voided: list[Line] | None = None,
    *,
    station: str,
    ticket_no: int,
    routes: Callable[[str | None], bool] | None = None,
    course: str | None = None,
) -> Ticket | None:
    """One station's ticket: voided lines first, printed in reverse, then the lines being sent.
    `routes(station)` says whether a kitchen line cooked at that station belongs on this ticket; without it,
    every line does."""
    lines = [*_ticket_lines(voided or [], routes, void=True), *_ticket_lines(sent, routes, void=False)]
    if not lines:
        return None
    voids = sum(line.void for line in lines)
    kind = "new" if not voids else "void" if voids == len(lines) else "modify"
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
    )


def _ticket_lines(lines: list[Line], routes: Callable[[str | None], bool] | None, *, void: bool) -> list[TicketLine]:
    out = []
    for line in lines:
        kitchen = (line.priced or {}).get("kitchen")
        if not kitchen:  # a line typed on the phase 0 demo screen
            kitchen = [{"qty": 1, "label": line.item, "labels": []}]
        for k in kitchen:
            if routes is not None and not routes(k.get("station")):
                continue
            out.append(
                TicketLine(
                    qty=line.qty * int(k.get("qty", 1)),
                    label=str(k.get("label") or line.item),
                    modifiers=tuple(k.get("labels", ())),
                    note=line.note,
                    seat=line.seat,
                    void=void,
                    changed=not void and line.modified_after_fire,
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
        for line in state.lines.values()
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
        printers: list[Printer],
        *,
        store: JobStore | None = None,
        direct: bool = True,
        send: Callable[[str, bytes], None] = send_raw,
        font: str | None = None,
        dots: int = 576,
    ) -> None:
        self.printers = printers
        self.store = store or JobStore()
        self.direct = direct
        self._send = send
        self._font = font or find_font()
        self._dots = dots
        self._tickets = itertools.count(1)
        self._lock = threading.Lock()

    @classmethod
    def from_env(cls) -> PrintService:
        return cls(printers_from_env(), direct=os.environ.get("POS_PRINT_DIRECT", "1") != "0")

    def printer(self, name: str) -> Printer | None:
        return next((p for p in self.printers if p.name == name), None)

    def on_ops(self, ops_of: Callable[[str], list[Op]], ops: list[Op]) -> list[PrintJob]:
        """Called after operations are stored. Each order's tickets come from comparing the order before and
        after this batch, so a fire prints only lines not sent yet, a void of a sent line prints at once,
        and a change (void plus a new line plus a fire, sent together) prints as one ticket."""
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
                jobs.extend(self.send(after, sent, voided, key=key.op_id))
        return jobs

    def send(self, state: OrderState, sent: list[Line], voided: list[Line], *, key: str) -> list[PrintJob]:
        with self._lock:
            ticket_no = next(self._tickets)
        jobs = []
        named = {p.name for p in self.printers}
        for i, printer in enumerate(self.printers):
            ticket = ticket_for(
                state,
                sent,
                voided,
                station=printer.name,
                ticket_no=ticket_no,
                routes=self._routes(printer, i == 0, named),
            )
            if ticket is None:
                continue
            jobs.append(self.queue(ticket, printer, job_id=f"{key}:{printer.name}"))
        return jobs

    @staticmethod
    def _routes(printer: Printer, first: bool, named: set[str]) -> Callable[[str | None], bool]:
        """A printer named after a station takes that station's lines; the first printer also takes every
        station without a printer of its own, so nothing fired is ever left unprinted."""

        def takes(station: str | None) -> bool:
            return station == printer.name or (first and station not in named)

        return takes

    def queue(self, ticket: Ticket, printer: Printer, *, job_id: str | None = None) -> PrintJob:
        data = render(ticket, dots=self._dots, font=self._font, dialect=printer.dialect)
        job = self.store.create(printer.address, data, job_id=job_id)
        if self.direct:
            threading.Thread(target=self._deliver, args=(job,), daemon=True).start()
        return job

    def _deliver(self, job: PrintJob) -> None:
        self.store.deliver_direct(job, send=self._send)

    def start_retrying(self, interval: float = 3.0) -> None:
        """A daemon that gives undelivered jobs another go every `interval` seconds (hubs only)."""
        if not self.direct or not self.printers:
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
