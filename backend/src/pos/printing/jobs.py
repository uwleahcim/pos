"""Print jobs: kept until a printer accepts them, delivered directly by a hub or through a terminal relay.

Every job has an id and lives until it is done. A hub sends it straight to the printer's port 9100. When
the hubs are down, a terminal on the LAN asks the cloud for jobs it can reach (`claim`), writes the bytes to
the printer, and reports `done`. A claim is a short lease: a relay that goes quiet loses the job to the next
one; a relay that reports twice changes nothing. So a job prints once, by whichever path works.

A job may carry fallbacks: the same ticket rendered for other printers, in the order the manager listed
them. After `FALLBACK_AFTER` failed attempts at the printer it is on, the job moves to the next one (and
round again when every one has failed), so a dead printer costs seconds, not the ticket.

What happens to a job is told to whoever watches (`JobStore.watch`: the print log, `pos.printing.log`): that
a try failed, that the job moved on to a fallback, that it printed.
"""

from __future__ import annotations

import socket
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field

LEASE_SECONDS = 8.0
PRINTER_PORT = 9100
FALLBACK_AFTER = 2
"""Failed attempts at one printer before the job moves to its next fallback."""


@dataclass
class PrintJob:
    job_id: str
    printer: str  # host or host:port of the printer
    data: bytes
    created: float
    status: str = "queued"  # queued | leased | done | failed
    attempts: int = 0
    leased_to: str | None = None
    lease_until: float = 0.0
    done_by: str | None = None
    done_at: float | None = None
    last_error: str | None = None
    not_before: float = 0.0  # a future order's ticket: nobody prints it before this (the store's clock)
    fallbacks: list[tuple[str, bytes]] = field(default_factory=list)
    """Where the job goes when its printer keeps failing: (printer address, the ticket rendered for it), in
    order; the printer it leaves joins the end, so the job rounds them all until one prints."""
    failures: int = 0  # failed attempts at the printer it is on now
    moved: int = 0  # how many times it moved to a fallback


def send_raw(printer: str, data: bytes, *, timeout: float = 4.0, linger: float = 2.0) -> None:
    """Write the job to the printer's raw port. Raises OSError when the printer cannot be reached.

    Printers answer on this port with status bytes (Star sends them unasked). Closing a socket that still
    holds unread input makes the kernel send a reset instead of an orderly close, and a printer that sees
    the reset may drop what it has not printed yet, stuck mid-command. So: send, say we are done writing,
    then read and discard whatever comes back until the printer hangs up or goes quiet.
    """
    host, _, port = printer.partition(":")
    with socket.create_connection((host, int(port or PRINTER_PORT)), timeout=timeout) as sock:
        sock.sendall(data)
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            return
        sock.settimeout(linger)
        try:
            while sock.recv(4096):
                pass
        except OSError:
            pass  # quiet for `linger` seconds, or the printer closed first: either way the job is delivered


class JobStore:
    """In memory for phase 0; the calls are what a PostgreSQL table will offer in phase 1."""

    def __init__(self, *, clock: Callable[[], float] = time.monotonic, lease: float = LEASE_SECONDS) -> None:
        self._jobs: dict[str, PrintJob] = {}
        self._clock = clock
        self._lease = lease
        self._lock = threading.Lock()
        self.watch: Callable[[PrintJob, str, str], None] | None = None
        """Told what happens to a job, after it happened: `failed` with what went wrong and `moved` with the
        address the job left (it is at its next printer by then), `printed` with who printed it. Called
        outside the store's lock, from whichever thread it happened on; what it raises is dropped, since a
        job prints whether or not anybody is writing it down."""

    def _tell(self, job: PrintJob, happened: list[tuple[str, str]]) -> None:
        for what, detail in happened if self.watch is not None else ():
            try:
                self.watch(job, what, detail)
            except Exception:  # noqa: BLE001 - see `watch`
                pass

    def create(
        self,
        printer: str,
        data: bytes,
        *,
        job_id: str | None = None,
        delay: float = 0.0,
        fallbacks: list[tuple[str, bytes]] | None = None,
    ) -> PrintJob:
        """Queues a job; `delay` seconds keeps it from every printer and relay until then (a future order);
        `fallbacks` are the printers it moves to, with the ticket rendered for each, when this one fails."""
        with self._lock:
            job_id = job_id or uuid.uuid4().hex
            if job_id in self._jobs:
                return self._jobs[job_id]  # the same job asked for twice is one job
            now = self._clock()
            job = PrintJob(
                job_id=job_id,
                printer=printer,
                data=data,
                created=now,
                not_before=now + delay if delay > 0 else 0.0,
                fallbacks=list(fallbacks or ()),
            )
            self._jobs[job_id] = job
            return job

    def get(self, job_id: str) -> PrintJob | None:
        return self._jobs.get(job_id)

    def due_in(self, job: PrintJob) -> float:
        """Seconds until a scheduled job may print; 0 for one that may print now."""
        return max(0.0, job.not_before - self._clock())

    def all(self) -> list[PrintJob]:
        with self._lock:
            return list(self._jobs.values())

    def pending(self, printers: list[str] | None = None) -> list[PrintJob]:
        """Jobs nobody is printing right now: queued, or leased to a relay that went quiet."""
        with self._lock:
            return self._pending_unlocked(printers)

    def claim(self, printers: list[str], relay: str) -> PrintJob | None:
        """Hand the oldest job for one of `printers` to `relay` for a few seconds."""
        with self._lock:
            for job in self._pending_unlocked(printers):
                job.status = "leased"
                job.leased_to = relay
                job.lease_until = self._clock() + self._lease
                job.attempts += 1
                return job
        return None

    def _pending_unlocked(self, printers: list[str] | None) -> list[PrintJob]:
        now = self._clock()
        jobs = [
            j
            for j in self._jobs.values()
            if j.status in ("queued", "leased")
            and (j.status == "queued" or j.lease_until <= now)
            and j.not_before <= now
            and (printers is None or j.printer in printers)
        ]
        return sorted(jobs, key=lambda j: j.created)

    def done(self, job_id: str, by: str) -> PrintJob:
        """Idempotent: the first report wins, later ones are acknowledged and ignored."""
        with self._lock:
            job = self._jobs[job_id]
            first = job.status != "done"
            if first:
                job.status = "done"
                job.done_by = by
                job.done_at = self._clock()
        if first:
            self._tell(job, [("printed", by)])
        return job

    def failed(self, job_id: str, by: str, error: str) -> PrintJob:
        """The relay could not reach the printer; the job goes back to the queue at once, or on to its next
        fallback when this printer has failed it enough."""
        with self._lock:
            job = self._jobs[job_id]
            if job.status == "leased" and job.leased_to == by:
                job.status = "queued"
                job.leased_to = None
                job.lease_until = 0.0
            happened = self._failed_unlocked(job, error)
        self._tell(job, happened)
        return job

    def _failed_unlocked(self, job: PrintJob, error: str) -> list[tuple[str, str]]:
        """Gives what happened, for whoever watches: the failure, and the move to a fallback it brought."""
        happened = [("failed", error)]
        job.last_error = error
        job.failures += 1
        if job.fallbacks and job.failures >= FALLBACK_AFTER:
            left = job.printer
            job.fallbacks.append((job.printer, job.data))
            job.printer, job.data = job.fallbacks.pop(0)
            job.failures = 0
            job.moved += 1
            happened.append(("moved", left))
        return happened

    def deliver_direct(self, job: PrintJob, *, send: Callable[[str, bytes], None] = send_raw, by: str = "hub") -> bool:
        """The hub path: write to the printer now. On failure the job stays queued for a retry or a relay."""
        with self._lock:
            if job.status == "done":
                return True
            job.attempts += 1
        try:
            send(job.printer, job.data)
        except OSError as err:
            with self._lock:
                happened = self._failed_unlocked(job, str(err))
            self._tell(job, happened)
            return False
        self.done(job.job_id, by)
        return True
