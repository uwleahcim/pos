"""The print log: every paper the hub made, where it went, how that ended, and the paper itself.

A printer says nothing about what it printed, and a ticket that never came out leaves no trace in the
kitchen. So the hub writes each print down as it queues it (`PrintService.queue`): what it was (a ticket for
table 12, a bill, the day's report), which printer it was for, and the paper step by step
(`pos.printing.script`). What happens to its job is written beside it as it happens: each try that failed
and why, the move to a fallback printer, that it printed and at which printer. A manager reads it in the
app (Location settings › Printers › Print log; docs/printing.md, "The print log"), looks at any paper on
the screen as it came out, and prints it again, headed REPRINT.

The log is kept in PostgreSQL on a hub (`PgPrintLog`), so it is there after a restart; the jobs themselves
are in memory (`pos.printing.jobs`), so a print still waiting when the hub stopped is one that was never
printed, and the log says so (`PrintService.status`). Prints older than `KEEP_DAYS` are dropped. In memory
for tests and a laptop.

Writing the log never holds up a print and never stops one: whoever calls it catches what it raises.
"""

from __future__ import annotations

import os
import re
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field, replace
from typing import Any

from .script import Script, clean

KEEP_DAYS = 14
"""How long a print stays in the log."""

EVENTS = 12
"""The most that is kept of what happened to one print: the first of them, and the latest."""

DAY_MS = 24 * 60 * 60 * 1000

TYPES = ("kitchen", "bar", "bill", "reprint", "other")
"""The types a manager reads the log by (`types_of`), in the order a screen offers them: the kitchen's
tickets, the bar's, the guests' bills, whatever was printed again, and the rest (the day's report, pack
sheets, prep lists, bag labels, notices, test prints)."""

PLACES = ("kitchen", "bar")
"""Where a ticket's dishes are made, as `PrintService` writes it on the ticket's print (`Print.places`)."""

SORTS = {"bill": "Bill", "day": "Day report", "pack": "Pack sheet", "prep": "Prep list", "labels": "Bag labels"}
KINDS = {
    "modify": "Change",
    "void": "Void",
    "allergy": "Allergy notice",
    "moved": "Moved slip",
    "bag": "Bag slip",
    "notice": "Notice",
}
"""What a print is called on the screen (the app's `PrintEntry.what`), so that a search for the words a
manager reads there finds it."""

FOUND_CHARS = 80
"""How much of a paper's line a search shows as the place it found its words."""


@dataclass(frozen=True)
class Event:
    """One thing that happened to a print: a try that `failed` (`text` says why; `times` when the same
    thing went wrong several times running), a `moved` to a fallback printer (`text` names it), `printed`
    (`text` says where and by whom, when that is worth saying), or `reprinted` (`text`: by whom, where)."""

    ms: int
    what: str
    text: str = ""
    times: int = 1

    def as_json(self) -> dict[str, Any]:
        return {"ms": self.ms, "what": self.what, "text": self.text, "times": self.times}

    @staticmethod
    def from_json(raw: Any) -> Event | None:
        if not isinstance(raw, Mapping) or not isinstance(raw.get("ms"), int) or not isinstance(raw.get("what"), str):
            return None
        times = raw.get("times")
        return Event(raw["ms"], raw["what"], str(raw.get("text") or ""), times if isinstance(times, int) else 1)


@dataclass(frozen=True)
class Print:
    """One print as the log keeps it. `job_id` is its job's; `at_ms` when the hub queued it. `printer`,
    `name` and `address` are the printer it was made for, as it stood then (its id, what heads its tickets,
    where it is). `sort` says what kind of paper it is (ticket, bill, day, pack, prep, labels), `kind` what
    kind of ticket (new, modify, void, allergy, moved, bag, notice), `title` what it is for ("Table 12",
    "#45 WU") and `head` the stations a ticket is headed with. Printed: `printed_ms`, by whom (`hub`, or
    the screen that carried it to the printer), and at which printer when it was not its own
    (`printed_on`, `printed_name`). `tries` and `error` are the tries that failed and the last thing that
    went wrong. A reprint names the print it repeats (`reprint_of`, the first one, never another reprint),
    when that one came out (`first_ms`) and who asked (`by`); the first one counts its `reprints`.
    `places` says where an order's ticket is made: `kitchen`, `bar`, or both for a ticket with dishes of
    each; nothing for every other paper, and for a slip that is nobody's order."""

    job_id: str
    at_ms: int
    printer: str
    name: str
    address: str
    sort: str = "ticket"
    kind: str = ""
    title: str = ""
    head: str = ""
    order_id: str = ""
    printed_ms: int | None = None
    printed_by: str = ""
    printed_on: str = ""
    printed_name: str = ""
    tries: int = 0
    error: str = ""
    error_ms: int | None = None
    reprint_of: str = ""
    first_ms: int | None = None
    by: str = ""
    reprints: int = 0
    events: tuple[Event, ...] = field(default=())
    places: tuple[str, ...] = ()

    @property
    def printed(self) -> bool:
        return self.printed_ms is not None

    @property
    def elsewhere(self) -> bool:
        """It printed, at another printer than the one it was made for."""
        return self.printed and bool(self.printed_on) and self.printed_on != self.address

    @property
    def trouble(self) -> bool:
        """Something a manager would want to look at: it has not printed, a try failed, or it came out at
        another printer."""
        return not self.printed or self.tries > 0 or self.elsewhere

    def then(self, event: Event) -> Print:
        """The same with one more thing that happened to it. The same failure again counts on the last one
        instead of filling the list; past `EVENTS` the middle ones go, the first and the latest stay."""
        events = list(self.events)
        last = events[-1] if events else None
        if last is not None and event.what == "failed" and (last.what, last.text) == (event.what, event.text):
            events[-1] = replace(last, ms=event.ms, times=last.times + event.times)
        else:
            events.append(event)
        if len(events) > EVENTS:
            events = [*events[: EVENTS // 2], *events[-(EVENTS - EVENTS // 2) :]]
        return replace(self, events=tuple(events))

    def as_json(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "at_ms": self.at_ms,
            "printer": self.printer,
            "name": self.name,
            "address": self.address,
            "sort": self.sort,
            "kind": self.kind,
            "title": self.title,
            "head": self.head,
            "order_id": self.order_id,
            "printed_ms": self.printed_ms,
            "printed_by": self.printed_by,
            "printed_on": self.printed_on,
            "printed_name": self.printed_name,
            "tries": self.tries,
            "error": self.error,
            "error_ms": self.error_ms,
            "reprint_of": self.reprint_of,
            "first_ms": self.first_ms,
            "by": self.by,
            "reprints": self.reprints,
            "events": [event.as_json() for event in self.events],
            "places": list(self.places),
        }

    @staticmethod
    def from_json(raw: Any) -> Print | None:
        """A print as it was kept; None for a row that is not one. What a newer hub wrote and this one does
        not know is left out, what an older one did not write reads as nothing."""
        if not isinstance(raw, Mapping) or not isinstance(raw.get("job_id"), str):
            return None

        def number(key: str) -> int | None:
            value = raw.get(key)
            return value if isinstance(value, int) and not isinstance(value, bool) else None

        def words(key: str) -> str:
            value = raw.get(key)
            return value if isinstance(value, str) else ""

        events = (Event.from_json(e) for e in raw.get("events") or ())
        places = raw.get("places")
        return Print(
            job_id=raw["job_id"],
            at_ms=number("at_ms") or 0,
            printer=words("printer"),
            name=words("name"),
            address=words("address"),
            sort=words("sort") or "ticket",
            kind=words("kind"),
            title=words("title"),
            head=words("head"),
            order_id=words("order_id"),
            printed_ms=number("printed_ms"),
            printed_by=words("printed_by"),
            printed_on=words("printed_on"),
            printed_name=words("printed_name"),
            tries=number("tries") or 0,
            error=words("error"),
            error_ms=number("error_ms"),
            reprint_of=words("reprint_of"),
            first_ms=number("first_ms"),
            by=words("by"),
            reprints=number("reprints") or 0,
            events=tuple(e for e in events if e is not None),
            places=tuple(p for p in PLACES if p in places) if isinstance(places, list) else (),
        )


def types_of(entry: Print) -> tuple[str, ...]:
    """The types a print is listed under (`TYPES`): a ticket under where it is made (the kitchen, the bar,
    or both), a bill under the bills, every other paper under the rest; and a reprint, whatever it repeats,
    under the reprints as well."""
    if entry.sort == "ticket" and entry.places:
        found = [place for place in PLACES if place in entry.places]
    else:
        found = ["bill" if entry.sort == "bill" else "other"]
    return (*found, "reprint") if entry.reprint_of else tuple(found)


def called(entry: Print) -> str:
    """What the screen calls a print, in a word or two: "Ticket", "Void", "Bill", "Day report"."""
    return SORTS.get(entry.sort) or KINDS.get(entry.kind) or "Ticket"


def words_of(entry: Print, script: Script) -> str:
    """What a search looks through, a line each: first what the log's own line says of the print (that it is
    a reprint, what it is called, what it is for, its stations, its printer, who asked for it), then every
    line of the paper itself as it was written down, the two sides of a pair of columns together."""
    about = (
        "Reprint" if entry.reprint_of else "",
        called(entry),
        entry.title,
        entry.head,
        entry.name,
        entry.by,
    )
    lines = [" ".join(part for part in about if part)]
    for page in script:
        for step in page:
            if step.get("k") == "line":
                said = str(step.get("text") or "")
            elif step.get("k") == "cols":
                said = f"{step.get('left') or ''}  {step.get('right') or ''}"
            else:
                continue
            if said.strip():
                lines.append(" ".join(said.split()))
    return "\n".join(lines)


def search_for(q: str | None) -> str:
    """What was typed, as a search: the words with one space between them. Nothing typed is no search."""
    return " ".join((q or "").split())


def pattern_of(wanted: str) -> str:
    """A search as the pattern its words are found by (the same here and in PostgreSQL, either case): the
    words as they were typed, letter for letter, anywhere on a line. A number at either end is a whole
    number there, so "table 1" is not table 12, and "#45" is not order 451."""
    literal = "".join(c if c.isalnum() else "\\" + c for c in wanted)
    before = "(?<![0-9])" if wanted[:1].isascii() and wanted[:1].isdigit() else ""
    after = "(?![0-9])" if wanted[-1:].isascii() and wanted[-1:].isdigit() else ""
    return f"{before}{literal}{after}"


def found_in(words: str, wanted: str) -> str | None:
    """Where a search finds its words in what is kept of a print (`words_of`): None when it does not; the
    line of the paper they are on, for a screen to put under the print so it is plain why it is listed; and
    nothing to show when the log's own line of the print already has them."""
    found = re.compile(pattern_of(wanted), re.IGNORECASE)
    about, _, paper = words.partition("\n")
    if found.search(about):
        return ""
    for line in paper.split("\n"):
        if found.search(line):
            return line if len(line) <= FOUND_CHARS else line[: FOUND_CHARS - 1].rstrip() + "…"
    return None


Before = tuple[int, str]
"""Where a page of the log ends: the time and the job of its last print. The next page starts after it."""


def _newest_first(entry: Print) -> tuple[int, str]:
    return (-entry.at_ms, entry.job_id)


class PrintLog:
    """The log, newest first. In memory: tests and a laptop. Every hub and the cloud use `PgPrintLog`."""

    def __init__(self) -> None:
        self._prints: dict[str, tuple[Print, Script]] = {}
        self._words: dict[str, str] = {}
        self._lock = threading.Lock()

    def add(self, entry: Print, script: Script) -> bool:
        """Writes a print down with its paper. A job asked for twice is one job and one print: the second
        is not written, and the answer says so."""
        with self._lock:
            if entry.job_id in self._prints:
                return False
            self._prints[entry.job_id] = (entry, script)
            self._words[entry.job_id] = words_of(entry, script)
            return True

    def get(self, job_id: str) -> tuple[Print, Script] | None:
        with self._lock:
            return self._prints.get(job_id)

    def change(self, job_id: str, how: Callable[[Print], Print]) -> Print | None:
        """What happened to a print, written to it: `how` gives the print as it stands after. None when the
        log has no such print (one made before the log was kept, or dropped since)."""
        with self._lock:
            found = self._prints.get(job_id)
            if found is None:
                return None
            after = how(found[0])
            self._prints[job_id] = (after, found[1])
            return after

    def list(
        self,
        *,
        printer: str | None = None,
        trouble: bool = False,
        type: str | None = None,  # noqa: A002 - what the log itself calls it
        q: str | None = None,
        before: Before | None = None,
        limit: int = 50,
    ) -> list[Print]:
        """A page of the log, newest first: the prints made for `printer` (by its id; all of them without),
        only the ones with `trouble` when asked, only the ones of one `type` (`TYPES`), only the ones that
        have the words of `q` (in their line of the log or on a line of their paper: `pattern_of`), starting
        after `before`."""
        found = self.page(printer=printer, trouble=trouble, type=type, q=q, before=before, limit=limit)
        return [entry for entry, _ in found]

    def page(
        self,
        *,
        printer: str | None = None,
        trouble: bool = False,
        type: str | None = None,  # noqa: A002
        q: str | None = None,
        before: Before | None = None,
        limit: int = 50,
    ) -> list[tuple[Print, str]]:
        """`list`, and beside each print the line of its paper a search found its words on (`found_in`)."""
        wanted = search_for(q)
        with self._lock:
            prints = [(entry, self._words.get(job_id, "")) for job_id, (entry, _) in self._prints.items()]
        listed = [
            (entry, found_in(words, wanted) if wanted else "")
            for entry, words in prints
            if (printer is None or entry.printer == printer)
            and (not trouble or entry.trouble)
            and (type is None or type in types_of(entry))
            and (before is None or _newest_first(entry) > (-before[0], before[1]))
        ]
        found = sorted(
            ((entry, where) for entry, where in listed if where is not None), key=lambda f: _newest_first(f[0])
        )
        return found[: max(0, limit)]

    def restamp(self, how: Callable[[Print], Print]) -> int:
        """Brings the prints an older hub wrote up to what this one keeps of a print (its types, the words
        a search looks through): `how` gives each as it should stand. Gives how many there were; none here,
        where every print is written whole."""
        return 0

    def prune(self, before_ms: int) -> int:
        """Drops the prints queued before `before_ms`; gives how many went."""
        with self._lock:
            old = [job_id for job_id, (entry, _) in self._prints.items() if entry.at_ms < before_ms]
            for job_id in old:
                del self._prints[job_id]
                self._words.pop(job_id, None)
            return len(old)


SCHEMA = """
CREATE TABLE IF NOT EXISTS print_log (
    job_id  TEXT PRIMARY KEY,
    at_ms   BIGINT NOT NULL,
    printer TEXT NOT NULL,
    trouble BOOLEAN NOT NULL,
    entry   JSONB NOT NULL,
    script  JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS print_log_newest ON print_log (at_ms DESC, job_id);
CREATE INDEX IF NOT EXISTS print_log_printer ON print_log (printer, at_ms DESC, job_id);
ALTER TABLE print_log ADD COLUMN IF NOT EXISTS types TEXT;
ALTER TABLE print_log ADD COLUMN IF NOT EXISTS words TEXT;
"""
"""`types` is the print's types between spaces (" kitchen reprint "), `words` what a search looks through
(`words_of`). Both are null on a print written by a hub from before them, until `restamp` fills them."""


def _typed(entry: Print) -> str:
    return f" {' '.join(types_of(entry))} "


class PgPrintLog(PrintLog):
    """The same calls, in PostgreSQL, so the log is there after a restart. A standby has the log its primary
    writes and writes nothing itself."""

    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        from psycopg.rows import tuple_row
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def add(self, entry: Print, script: Script) -> bool:
        from psycopg.types.json import Jsonb

        with self._pool.connection() as conn:
            done = conn.execute(
                """
                INSERT INTO print_log (job_id, at_ms, printer, trouble, entry, script, types, words)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (job_id) DO NOTHING
                """,
                (
                    entry.job_id,
                    entry.at_ms,
                    entry.printer,
                    entry.trouble,
                    Jsonb(entry.as_json()),
                    Jsonb(script),
                    _typed(entry),
                    words_of(entry, script),
                ),
            )
            return done.rowcount > 0

    def get(self, job_id: str) -> tuple[Print, Script] | None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                row = conn.execute("SELECT entry, script FROM print_log WHERE job_id = %s", (job_id,)).fetchone()
        except errors.UndefinedTable:
            return None  # a standby whose primary has not been updated yet
        entry = Print.from_json(row[0]) if row is not None else None
        return (entry, clean(row[1])) if entry is not None and row is not None else None

    def change(self, job_id: str, how: Callable[[Print], Print]) -> Print | None:
        from psycopg.types.json import Jsonb

        with self._pool.connection() as conn, conn.transaction():
            row = conn.execute("SELECT entry FROM print_log WHERE job_id = %s FOR UPDATE", (job_id,)).fetchone()
            before = Print.from_json(row[0]) if row is not None else None
            if before is None:
                return None
            after = how(before)
            conn.execute(
                "UPDATE print_log SET trouble = %s, entry = %s WHERE job_id = %s",
                (after.trouble, Jsonb(after.as_json()), job_id),
            )
            return after

    def page(
        self,
        *,
        printer: str | None = None,
        trouble: bool = False,
        type: str | None = None,  # noqa: A002
        q: str | None = None,
        before: Before | None = None,
        limit: int = 50,
    ) -> list[tuple[Print, str]]:
        from psycopg import errors

        wanted = search_for(q)
        where: list[str] = ["TRUE"]
        args: list[Any] = []
        if printer is not None:
            where.append("printer = %s")
            args.append(printer)
        if trouble:
            where.append("trouble")
        if type is not None:
            where.append("types LIKE %s")
            args.append(f"% {type} %")
        if wanted:
            where.append("words ~* %s")
            args.append(pattern_of(wanted))
        if before is not None:
            where.append("(at_ms < %s OR (at_ms = %s AND job_id > %s))")
            args.extend([before[0], before[0], before[1]])
        found = "words" if wanted else "''"
        try:
            with self._pool.connection() as conn:
                rows = conn.execute(
                    f"SELECT entry, {found} FROM print_log WHERE {' AND '.join(where)} "  # noqa: S608 - fixed parts
                    "ORDER BY at_ms DESC, job_id LIMIT %s",
                    (*args, max(0, limit)),
                ).fetchall()
        except (errors.UndefinedTable, errors.UndefinedColumn):
            return []  # a standby whose primary has not been updated yet
        prints = ((Print.from_json(row[0]), row[1] or "") for row in rows)
        return [
            (entry, (found_in(words, wanted) or "") if wanted else "") for entry, words in prints if entry is not None
        ]

    def restamp(self, how: Callable[[Print], Print]) -> int:
        from psycopg.types.json import Jsonb

        with self._pool.connection() as conn:
            standby = conn.execute("SELECT pg_is_in_recovery()").fetchone()
        if standby is not None and standby[0]:
            return 0  # its primary does it, and the standby has what the primary wrote
        done = 0
        while True:
            with self._pool.connection() as conn, conn.transaction():
                rows = conn.execute(
                    "SELECT job_id, entry, script FROM print_log WHERE words IS NULL LIMIT 200 FOR UPDATE"
                ).fetchall()
                for job_id, raw, script in rows:
                    before = Print.from_json(raw)
                    after = how(before) if before is not None else None
                    if after is None:  # not a print anybody can read: marked, so it is not looked at again
                        conn.execute("UPDATE print_log SET types = '', words = '' WHERE job_id = %s", (job_id,))
                        continue
                    conn.execute(
                        "UPDATE print_log SET entry = %s, types = %s, words = %s WHERE job_id = %s",
                        (Jsonb(after.as_json()), _typed(after), words_of(after, clean(script)), job_id),
                    )
            done += len(rows)
            if len(rows) < 200:
                return done

    def prune(self, before_ms: int) -> int:
        with self._pool.connection() as conn:
            return conn.execute("DELETE FROM print_log WHERE at_ms < %s", (before_ms,)).rowcount


def default_log() -> PrintLog:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgPrintLog(dsn) if dsn else PrintLog()
