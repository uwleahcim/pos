"""Print jobs: kept until a printer accepts them, delivered directly by a hub or through a terminal relay.

Every job has an id and lives until it is done. A hub sends it straight to the printer's port 9100. When
the hubs are down, a terminal on the LAN asks the cloud for jobs it can reach (`claim`), writes the bytes to
the printer, and reports `done`. A claim is a short lease: a relay that goes quiet loses the job to the next
one; a relay that reports twice changes nothing. So a job prints once, by whichever path works.
"""

from __future__ import annotations

import socket
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass

LEASE_SECONDS = 8.0
PRINTER_PORT = 9100


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


def send_raw(printer: str, data: bytes, *, timeout: float = 4.0) -> None:
    """Write the job to the printer's raw port. Raises OSError when the printer cannot be reached."""
    host, _, port = printer.partition(":")
    with socket.create_connection((host, int(port or PRINTER_PORT)), timeout=timeout) as sock:
        sock.sendall(data)


class JobStore:
    """In memory for phase 0; the calls are what a PostgreSQL table will offer in phase 1."""

    def __init__(self, *, clock: Callable[[], float] = time.monotonic, lease: float = LEASE_SECONDS) -> None:
        self._jobs: dict[str, PrintJob] = {}
        self._clock = clock
        self._lease = lease
        self._lock = threading.Lock()

    def create(self, printer: str, data: bytes, *, job_id: str | None = None) -> PrintJob:
        with self._lock:
            job_id = job_id or uuid.uuid4().hex
            if job_id in self._jobs:
                return self._jobs[job_id]  # the same job asked for twice is one job
            job = PrintJob(job_id=job_id, printer=printer, data=data, created=self._clock())
            self._jobs[job_id] = job
            return job

    def get(self, job_id: str) -> PrintJob | None:
        return self._jobs.get(job_id)

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
            and (printers is None or j.printer in printers)
        ]
        return sorted(jobs, key=lambda j: j.created)

    def done(self, job_id: str, by: str) -> PrintJob:
        """Idempotent: the first report wins, later ones are acknowledged and ignored."""
        with self._lock:
            job = self._jobs[job_id]
            if job.status != "done":
                job.status = "done"
                job.done_by = by
                job.done_at = self._clock()
            return job

    def failed(self, job_id: str, by: str, error: str) -> PrintJob:
        """The relay could not reach the printer; the job goes back to the queue at once."""
        with self._lock:
            job = self._jobs[job_id]
            if job.status == "leased" and job.leased_to == by:
                job.status = "queued"
                job.leased_to = None
                job.lease_until = 0.0
            job.last_error = error
            return job

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
                job.last_error = str(err)
            return False
        self.done(job.job_id, by)
        return True
