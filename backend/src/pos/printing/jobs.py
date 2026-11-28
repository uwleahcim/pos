"""Print jobs: kept until a printer accepts them, delivered directly by a hub or through a terminal relay.

Every job has an id and lives until it is done. A hub sends it straight to the printer's port 9100. When
the hubs are down, a terminal on the LAN asks the cloud for jobs it can reach (`claim`), writes the bytes to
the printer, and reports `done`. A claim is a short lease: a relay that goes quiet loses the job to the next
one; a relay that reports twice changes nothing. So a job prints once, by whichever path works.

Whoever writes a job has it to itself for as long as that takes. The hub's own write is such a lease too
(`write`), one no clock ends: handing a ticket over takes as long as the printer takes, and a job that is on
its way is not one that still has to go. The hub's second chance (`pending`) and a relay's `claim` both
pass it over until the write has ended, one way or the other.

The hub keeps a line for each printer (`Lines`): a printer prints one paper at a time, so it is handed one
at a time, the oldest first, the next when it has taken the one before. Printers are worked side by side,
each by a thread of its own, so one that is off or out of paper holds up nobody else's tickets. A printer
that fails a paper has failed every paper waiting behind it too: they would have met the same, so each
counts the try without being sent, and a printer that is down costs two tries in all before everything in
its line moves on to the fallbacks.

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
from collections.abc import Callable, Iterable, Sequence
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


DRAIN_LONGEST = 30.0
"""How long a printer that keeps talking is listened to after a job, in all: a paper is long out by then."""


def send_raw(
    printer: str, data: bytes, *, timeout: float = 4.0, linger: float = 2.0, longest: float = DRAIN_LONGEST
) -> None:
    """Write the job to the printer's raw port. Raises OSError when the printer cannot be reached, or stops
    taking the job.

    `timeout` is how long the printer may stand still, not how long the job may take: to answer the
    connection, and then to take some more of the job. A printer prints as it reads, so a long ticket (a
    catering order's) is handed over at the speed of the paper and can take longer than any fixed time; as
    long as it keeps going in, it is going well. Given up halfway, it would be sent again whole and come
    out twice.

    Printers answer on this port with status bytes (Star sends them unasked). Closing a socket that still
    holds unread input makes the kernel send a reset instead of an orderly close, and a printer that sees
    the reset may drop what it has not printed yet, stuck mid-command. So: send, say we are done writing,
    then read and discard whatever comes back until the printer hangs up or goes quiet for `linger`
    seconds; and for `longest` seconds at most, so a printer that never stops talking does not keep the
    ones behind this job waiting for good.
    """
    host, _, port = printer.partition(":")
    with socket.create_connection((host, int(port or PRINTER_PORT)), timeout=timeout) as sock:
        left = memoryview(data)
        while left:
            left = left[sock.send(left) :]  # waits `timeout` for room, then hands over what fits
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            return
        sock.settimeout(linger)
        until = time.monotonic() + longest
        try:
            while sock.recv(4096) and time.monotonic() < until:
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
            self._back_unlocked(job, by)
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

    def write(self, job: PrintJob, *, send: Callable[[str, bytes], None] = send_raw, by: str = "hub") -> str:
        """The hub path: write to the printer now. The job is leased to the hub for as long as the write
        takes, so nobody writes it a second time meanwhile. Says what became of it: `printed`; `failed`,
        and the job is back in the queue for another try, a relay, or on its way to a fallback; or `taken`
        for a job somebody is writing already (this hub on another thread, or a relay whose lease still
        runs), which is left to them.

        Whatever goes wrong with the write is a failed try, an address that cannot be read as much as a
        printer that does not answer: the job is never left as the hub's for good, and one that cannot be
        written where it is still moves on to its fallbacks."""
        with self._lock:
            if job.status == "done":
                return "printed"
            if job.status == "leased" and job.lease_until > self._clock():
                return "taken"
            job.status = "leased"
            job.leased_to = by
            job.lease_until = float("inf")  # the write ends it, not the clock: see `_back_unlocked`
            job.attempts += 1
            printer, data = job.printer, job.data
        try:
            send(printer, data)
        except Exception as err:  # noqa: BLE001 - see above
            with self._lock:
                self._back_unlocked(job, by)
                happened = self._failed_unlocked(job, str(err) or type(err).__name__)
            self._tell(job, happened)
            return "failed"
        except BaseException:
            with self._lock:
                self._back_unlocked(job, by)  # the hub is stopping: a job left leased would never print
            raise
        self.done(job.job_id, by)
        return "printed"

    def deliver_direct(self, job: PrintJob, *, send: Callable[[str, bytes], None] = send_raw, by: str = "hub") -> bool:
        """`write`, for whoever only asks whether it printed here and now."""
        return self.write(job, send=send, by=by) == "printed"

    def missed(self, jobs: Iterable[PrintJob], printer: str, error: str) -> None:
        """The printer at `printer` failed the paper ahead of these, with `error`: a failed try for each of
        them too, as it would have been had the hub gone on and written them. A job that no longer waits
        there (printed, taken by a relay, moved on) is passed over."""
        told = []
        with self._lock:
            for job in jobs:
                if job.status == "queued" and job.printer == printer:
                    job.attempts += 1
                    told.append((job, self._failed_unlocked(job, error)))
        for job, happened in told:
            self._tell(job, happened)

    @staticmethod
    def _back_unlocked(job: PrintJob, by: str) -> None:
        """The job goes back to the queue from whoever had it, unless it was done or taken on meanwhile."""
        if job.status == "leased" and job.leased_to == by:
            job.status = "queued"
            job.leased_to = None
            job.lease_until = 0.0


class Lines:
    """The hub's side of delivery: a line for each printer, by its address.

    A printer prints one paper at a time. Handed several at once, on a connection each, it takes them in
    whatever order it likes, lets the ones it has no room for wait or turns them away, and a wait looks to
    the hub like a printer that does not answer. So the hub hands a printer one job, waits until it has
    taken it, and hands it the next: the oldest first, which for the tickets of one order is the order the
    stations stand in on the printer.

    Each line is worked by a thread of its own, started when there is something in it (`wake`) and gone
    when it is empty, so printers print side by side and a slow one keeps only its own papers waiting. A
    line stops at the first paper its printer fails: the try counts for every paper behind it
    (`JobStore.missed`), the ones that have had enough of this printer move to their fallbacks, whose lines
    are woken, and the rest wait for the next `wake`. The hub's loop wakes every line with work every few
    seconds (`wake_all`); that is the pace a printer that is down is tried at.

    `sweep` is the same hand-over without the threads, each printer's line in turn on the caller's own: one
    go at everything that waits, for a test, or a hub that wants it done before it goes on."""

    def __init__(self, store: JobStore, send: Callable[[str, bytes], None] = send_raw, *, by: str = "hub") -> None:
        self.store = store
        self._send = send
        self._by = by
        self._lock = threading.Lock()
        self._working: dict[str, threading.Thread] = {}

    def wake(self, printer: str) -> None:
        """Somebody works the line of the printer at this address from now until it is empty or the printer
        fails a paper. Nothing to do when somebody already does: they look again before they leave."""
        with self._lock:
            if printer in self._working:
                return
            worker = threading.Thread(target=self._work, args=(printer,), name=f"print-line {printer}", daemon=True)
            self._working[printer] = worker
            worker.start()

    def wake_all(self) -> None:
        """Every line with a paper that may print now is worked: the ones a failed printer left waiting,
        and whatever a relay took and did not print."""
        for printer in dict.fromkeys(job.printer for job in self.store.pending()):
            self.wake(printer)

    def working(self) -> list[str]:
        """The printers whose lines are being worked right now."""
        with self._lock:
            return list(self._working)

    def _work(self, printer: str) -> None:
        me = threading.current_thread()
        try:
            while True:
                _, took_all = self.hand_over(printer, wake=True)
                with self._lock:
                    # looked at under the lock `wake` takes: a job queued a moment ago is either seen here,
                    # or finds the line unworked and starts it again
                    if not took_all or not self.store.pending([printer]):
                        del self._working[printer]
                        return
        finally:
            with self._lock:
                if self._working.get(printer) is me:  # stopped by something else than the end of the line
                    del self._working[printer]

    def hand_over(
        self, printer: str, jobs: Sequence[PrintJob] | None = None, *, wake: bool = False
    ) -> tuple[int, bool]:
        """Hands the printer at this address its papers one after another, oldest first: `jobs`, or
        everything that waits for it now. Stops at the first one it fails, which is a failed try for every
        one behind it as well. Gives how many printed, and whether the printer took all it was handed.
        `wake` works the lines of the printers that papers moved on to."""
        waiting = list(self.store.pending([printer]) if jobs is None else jobs)
        printed = 0
        for nth, job in enumerate(waiting):
            if job.printer != printer:
                continue  # it moved on meanwhile (a relay reported a failure): it is another line's
            went = self.store.write(job, send=self._send, by=self._by)
            if went == "printed":
                printed += 1
            elif went == "failed":
                behind = waiting[nth + 1 :]
                self.store.missed(behind, printer, job.last_error or "")
                if wake:
                    for moved_to in dict.fromkeys(j.printer for j in (job, *behind) if j.printer != printer):
                        self.wake(moved_to)
                return printed, False
        return printed, True

    def sweep(self) -> int:
        """One go at every paper that may print now, on the caller's thread: each printer's line in turn,
        in the order their oldest papers were queued. A paper that moves on to a fallback in this sweep is
        that printer's in the next. Gives how many printed."""
        lines: dict[str, list[PrintJob]] = {}
        for job in self.store.pending():
            lines.setdefault(job.printer, []).append(job)
        return sum(self.hand_over(printer, jobs)[0] for printer, jobs in lines.items())
