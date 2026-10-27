"""Tickets from orders: a `fire` turns into one job per kitchen printer, delivered by the hub or a relay.

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

from ..sync.oplog import Op, OrderState
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


def ticket_for_fire(state: OrderState, op: Op, *, station: str, ticket_no: int) -> Ticket | None:
    """The lines a `fire` sends to the kitchen: active lines of the fired course (`*` = every course)."""
    course = op.data.get("course", "*")
    lines = []
    for line in state.lines.values():
        if line.status != "active" or not (course == "*" or line.course == course):
            continue
        kitchen = (line.priced or {}).get("kitchen")
        if not kitchen:  # a line typed on the phase 0 demo screen
            kitchen = [{"qty": 1, "label": line.item, "labels": []}]
        for k in kitchen:
            lines.append(
                TicketLine(
                    qty=line.qty * int(k.get("qty", 1)),
                    label=str(k.get("label") or line.item),
                    modifiers=tuple(k.get("labels", ())),
                    note=line.note,
                    seat=line.seat,
                    changed=line.modified_after_fire,
                )
            )
    if not lines:
        return None
    fields = state.fields
    return Ticket(
        station=station,
        kind="new",
        order_id=state.order_id,
        ticket_no=ticket_no,
        table=str(fields.get("table", "")),
        lines=tuple(lines),
        server=str(fields.get("server", "")),
        order_type=str(fields.get("order_type", "dine in")),
        guests=fields.get("guests"),
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

    def on_ops(self, state_of: Callable[[str], OrderState], ops: list[Op]) -> list[PrintJob]:
        """Called after operations are stored: every accepted `fire` becomes tickets."""
        jobs: list[PrintJob] = []
        for op in ops:
            if op.kind == "fire" and self.printers:
                jobs.extend(self.fire(state_of(op.order_id), op))
        return jobs

    def fire(self, state: OrderState, op: Op) -> list[PrintJob]:
        with self._lock:
            ticket_no = next(self._tickets)
        jobs = []
        for printer in self.printers:
            ticket = ticket_for_fire(state, op, station=printer.name, ticket_no=ticket_no)
            if ticket is None:
                continue
            jobs.append(self.queue(ticket, printer, job_id=f"{op.op_id}:{printer.name}"))
        return jobs

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
