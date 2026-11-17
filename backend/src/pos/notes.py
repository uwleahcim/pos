"""Notes for the shift, and the manager's log.

**A note for the shift** is what a manager wants everybody to know before they start: the specials, what is
out, the party of twelve at seven. Each person sees a note once, the next time they are at the floor or the
list of checks after signing in, and the hub keeps who has seen which. A note comes down by itself when the
night is over (`localtime.NIGHT_ENDS`), or stays until a manager takes it down. Changing a note's words
shows it to everybody again.

**The manager's log** is the managers' own book: what happened in a shift that the next manager should
know, each entry under one subject (`SUBJECTS`). An entry is never changed and never deleted. A mistaken one
is struck out: it stays readable, with who struck it and when.

Neither touches a check or a sale: they are words beside the orders, kept in memory or in PostgreSQL.
"""

from __future__ import annotations

import os
import re
import threading
import time
import uuid
from collections.abc import Callable, Collection, Sequence
from dataclasses import dataclass, replace
from datetime import datetime
from typing import Any

from . import localtime

TEXT_MAX = 500
"""The most letters of a note for the shift: a few lines, read standing up."""
MOST_NOTES = 12
"""The most notes up at once: more than a person reads before starting."""
EARLIER_DAYS = 14
"""How far back a manager's list of notes goes for the ones that have come down."""
LOG_TEXT_MAX = 2000
"""The most letters of one entry of the manager's log."""
PAGE = 50
"""The entries of the log one reading answers; the next reading asks for the ones before."""
LASTS = ("tonight", "stays")
"""How long a note is up: until the night is over, or until a manager takes it down."""
SUBJECTS: tuple[tuple[str, str], ...] = (
    ("guests", "Guests"),
    ("staff", "Staff"),
    ("kitchen", "Kitchen"),
    ("bar", "Bar"),
    ("repairs", "Repairs"),
    ("deliveries", "Deliveries"),
    ("money", "Money"),
    ("other", "Other"),
)
"""What an entry of the manager's log is about, in the order the screens offer them."""
SUBJECT_NAMES = dict(SUBJECTS)

DAY_MS = 86_400_000


class Refused(Exception):
    """Something asked of the notes or the log that they do not do, with a word for the code and a sentence
    for the person."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReadOnlyError(RuntimeError):
    """The database is a standby: nothing can be written here until it is promoted."""


@dataclass(frozen=True)
class Note:
    """A note for the shift."""

    note_id: str
    text: str
    by_id: str
    by: str
    at_ms: int
    until_ms: int | None = None  # when it comes down by itself; None stays until it is taken down
    edited_ms: int | None = None  # when its words were last changed
    edited_by: str = ""
    removed_ms: int | None = None  # when a manager took it down
    removed_by: str = ""

    def runs(self, now_ms: int) -> bool:
        """Whether it is up: not taken down, and its night not over."""
        return self.removed_ms is None and (self.until_ms is None or now_ms < self.until_ms)

    @property
    def lasts(self) -> str:
        return "stays" if self.until_ms is None else "tonight"

    def ended_ms(self, now_ms: int) -> int | None:
        """When it came down, by a manager or by itself; None while it is up."""
        if self.removed_ms is not None:
            return self.removed_ms
        return self.until_ms if self.until_ms is not None and now_ms >= self.until_ms else None

    def as_json(self) -> dict[str, Any]:
        return {
            "id": self.note_id,
            "text": self.text,
            "by": self.by,
            "at_ms": self.at_ms,
            "until_ms": self.until_ms,
            "lasts": self.lasts,
            "edited_ms": self.edited_ms,
        }


@dataclass(frozen=True)
class LogEntry:
    """One entry of the manager's log."""

    entry_id: str
    subject: str
    text: str
    by_id: str
    by: str
    at_ms: int
    device: str = ""
    struck_ms: int | None = None  # when it was struck out; it stays readable
    struck_by: str = ""

    def as_json(self) -> dict[str, Any]:
        return {
            "id": self.entry_id,
            "subject": self.subject,
            "subject_name": SUBJECT_NAMES.get(self.subject, self.subject),
            "text": self.text,
            "by": self.by,
            "at_ms": self.at_ms,
            "day": localtime.service_day_of(self.at_ms).isoformat(),
            "struck_ms": self.struck_ms,
            "struck_by": self.struck_by,
        }


def _matches(entry: LogEntry, words: Sequence[str]) -> bool:
    hay = f"{entry.text} {entry.by}".lower()
    return all(word in hay for word in words)


def _search_words(q: object) -> list[str]:
    return [word for word in str(q or "").lower().split() if word][:8]


class NoteStore:
    """The notes, who has seen them, and the log, in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._notes: dict[str, Note] = {}
        self._seen: dict[str, dict[str, int]] = {}
        self._log: list[LogEntry] = []  # in the order they were written
        self._lock = threading.Lock()

    # -- notes for the shift

    def put_note(self, note: Note, *, again: bool = False) -> None:
        """Writes a note, new or changed. `again` forgets who has seen it, so everybody sees it once more."""
        with self._lock:
            self._notes[note.note_id] = note
            if again:
                self._seen.pop(note.note_id, None)

    def note(self, note_id: str) -> Note | None:
        with self._lock:
            return self._notes.get(note_id)

    def notes(self, now_ms: int, *, since_ms: int | None = None) -> list[Note]:
        """The notes that are up at `now_ms`, the newest first; with `since_ms`, also the ones written or
        come down at or after it."""
        with self._lock:
            found = [n for n in self._notes.values() if _wanted(n, now_ms, since_ms)]
        return sorted(found, key=lambda n: (n.at_ms, n.note_id), reverse=True)

    def saw(self, staff_id: str, note_ids: Collection[str], at_ms: int) -> None:
        """This person has seen these notes. The first time counts: seeing one again changes nothing."""
        with self._lock:
            for note_id in note_ids:
                if note_id in self._notes:
                    self._seen.setdefault(note_id, {}).setdefault(staff_id, at_ms)

    def seen(self, note_ids: Collection[str]) -> dict[str, dict[str, int]]:
        """Who has seen each of these notes, and when: note id -> staff id -> wall-clock ms."""
        with self._lock:
            return {note_id: dict(self._seen.get(note_id, {})) for note_id in note_ids}

    # -- the manager's log

    def put_entry(self, entry: LogEntry) -> None:
        """Writes an entry: a new one goes last, one already there (struck out now) keeps its place."""
        with self._lock:
            for at, old in enumerate(self._log):
                if old.entry_id == entry.entry_id:
                    self._log[at] = entry
                    return
            self._log.append(entry)

    def entry(self, entry_id: str) -> LogEntry | None:
        with self._lock:
            return next((e for e in self._log if e.entry_id == entry_id), None)

    def counts(self, *, q: str = "") -> dict[str, int]:
        """How many entries each subject has, the struck ones left out; with `q`, of those that match it."""
        words = _search_words(q)
        counted: dict[str, int] = {}
        with self._lock:
            for entry in self._log:
                if entry.struck_ms is None and _matches(entry, words):
                    counted[entry.subject] = counted.get(entry.subject, 0) + 1
        return counted

    def entries(
        self, *, subject: str | None = None, q: str = "", before: str | None = None, limit: int = PAGE
    ) -> list[LogEntry]:
        """The entries, the newest first: of one subject, matching every word of `q`, written before the
        entry named `before`. `limit` of them at most."""
        words = _search_words(q)
        with self._lock:
            log = list(self._log)
        if before is not None:
            at = next((i for i, e in enumerate(log) if e.entry_id == before), 0)  # nothing is before a stranger
            log = log[:at]
        found = [e for e in reversed(log) if (subject is None or e.subject == subject) and _matches(e, words)]
        return found[:limit]


def _wanted(note: Note, now_ms: int, since_ms: int | None) -> bool:
    if note.runs(now_ms):
        return True
    if since_ms is None:
        return False
    return note.at_ms >= since_ms or (note.ended_ms(now_ms) or 0) >= since_ms


SCHEMA = """
CREATE TABLE IF NOT EXISTS shift_note (
    note_id    TEXT PRIMARY KEY,
    text       TEXT NOT NULL,
    by_id      TEXT NOT NULL DEFAULT '',
    by_name    TEXT NOT NULL DEFAULT '',
    at_ms      BIGINT NOT NULL,
    until_ms   BIGINT,
    edited_ms  BIGINT,
    edited_by  TEXT NOT NULL DEFAULT '',
    removed_ms BIGINT,
    removed_by TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS shift_note_written ON shift_note (at_ms);
CREATE TABLE IF NOT EXISTS shift_note_seen (
    note_id  TEXT NOT NULL,
    staff_id TEXT NOT NULL,
    at_ms    BIGINT NOT NULL,
    PRIMARY KEY (note_id, staff_id)
);
CREATE TABLE IF NOT EXISTS manager_log (
    seq       BIGSERIAL PRIMARY KEY,
    entry_id  TEXT NOT NULL UNIQUE,
    subject   TEXT NOT NULL,
    text      TEXT NOT NULL,
    by_id     TEXT NOT NULL DEFAULT '',
    by_name   TEXT NOT NULL DEFAULT '',
    at_ms     BIGINT NOT NULL,
    device    TEXT NOT NULL DEFAULT '',
    struck_ms BIGINT,
    struck_by TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS manager_log_subject ON manager_log (subject);
"""

_NOTE = "note_id, text, by_id, by_name, at_ms, until_ms, edited_ms, edited_by, removed_ms, removed_by"
_ENTRY = "entry_id, subject, text, by_id, by_name, at_ms, device, struck_ms, struck_by"


def _int(value: Any) -> int | None:
    return None if value is None else int(value)


def _note_of(row: Sequence[Any]) -> Note:
    return Note(row[0], row[1], row[2], row[3], int(row[4]), _int(row[5]), _int(row[6]), row[7], _int(row[8]), row[9])


def _entry_of(row: Sequence[Any]) -> LogEntry:
    return LogEntry(row[0], row[1], row[2], row[3], row[4], int(row[5]), row[6], _int(row[7]), row[8])


def _like(word: str) -> str:
    """A word as a pattern that finds it anywhere, its own `%` and `_` meaning themselves."""
    return "%" + word.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


class PgNoteStore(NoteStore):
    """The same calls, in PostgreSQL, so the notes and the log are there after a restart and on the hub that
    takes over."""

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

    def _write(self, statements: Sequence[tuple[str, Sequence[Any]]]) -> None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                for sql, args in statements:
                    conn.execute(sql, args)
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def _read(self, sql: str, args: Sequence[Any]) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                return conn.execute(sql, args).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet

    # -- notes for the shift

    def put_note(self, note: Note, *, again: bool = False) -> None:
        statements: list[tuple[str, Sequence[Any]]] = [
            (
                f"INSERT INTO shift_note ({_NOTE}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                "ON CONFLICT (note_id) DO UPDATE SET text = EXCLUDED.text, until_ms = EXCLUDED.until_ms, "
                "edited_ms = EXCLUDED.edited_ms, edited_by = EXCLUDED.edited_by, "
                "removed_ms = EXCLUDED.removed_ms, removed_by = EXCLUDED.removed_by",
                (
                    note.note_id,
                    note.text,
                    note.by_id,
                    note.by,
                    note.at_ms,
                    note.until_ms,
                    note.edited_ms,
                    note.edited_by,
                    note.removed_ms,
                    note.removed_by,
                ),
            )
        ]
        if again:
            statements.append(("DELETE FROM shift_note_seen WHERE note_id = %s", (note.note_id,)))
        self._write(statements)

    def note(self, note_id: str) -> Note | None:
        rows = self._read(f"SELECT {_NOTE} FROM shift_note WHERE note_id = %s", (note_id,))
        return _note_of(rows[0]) if rows else None

    def notes(self, now_ms: int, *, since_ms: int | None = None) -> list[Note]:
        up = "(removed_ms IS NULL AND (until_ms IS NULL OR until_ms > %s))"
        if since_ms is None:
            where, args = up, (now_ms,)
        else:
            # come down at or after `since_ms`: taken down then, or its night ended between then and now
            where = (
                f"{up} OR at_ms >= %s OR removed_ms >= %s OR (removed_ms IS NULL AND until_ms >= %s AND until_ms <= %s)"
            )
            args = (now_ms, since_ms, since_ms, since_ms, now_ms)
        rows = self._read(f"SELECT {_NOTE} FROM shift_note WHERE {where} ORDER BY at_ms DESC, note_id DESC", args)
        return [_note_of(row) for row in rows]

    def saw(self, staff_id: str, note_ids: Collection[str], at_ms: int) -> None:
        if not note_ids:
            return
        self._write(
            [
                (
                    "INSERT INTO shift_note_seen (note_id, staff_id, at_ms) "
                    "SELECT note_id, %s, %s FROM shift_note WHERE note_id = ANY(%s) "
                    "ON CONFLICT (note_id, staff_id) DO NOTHING",
                    (staff_id, at_ms, list(note_ids)),
                )
            ]
        )

    def seen(self, note_ids: Collection[str]) -> dict[str, dict[str, int]]:
        found: dict[str, dict[str, int]] = {note_id: {} for note_id in note_ids}
        if not note_ids:
            return found
        rows = self._read(
            "SELECT note_id, staff_id, at_ms FROM shift_note_seen WHERE note_id = ANY(%s)", (list(note_ids),)
        )
        for note_id, staff_id, at_ms in rows:
            found[note_id][staff_id] = int(at_ms)
        return found

    # -- the manager's log

    def put_entry(self, entry: LogEntry) -> None:
        self._write(
            [
                (
                    f"INSERT INTO manager_log ({_ENTRY}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    "ON CONFLICT (entry_id) DO UPDATE "
                    "SET struck_ms = EXCLUDED.struck_ms, struck_by = EXCLUDED.struck_by",
                    (
                        entry.entry_id,
                        entry.subject,
                        entry.text,
                        entry.by_id,
                        entry.by,
                        entry.at_ms,
                        entry.device,
                        entry.struck_ms,
                        entry.struck_by,
                    ),
                )
            ]
        )

    def entry(self, entry_id: str) -> LogEntry | None:
        rows = self._read(f"SELECT {_ENTRY} FROM manager_log WHERE entry_id = %s", (entry_id,))
        return _entry_of(rows[0]) if rows else None

    @staticmethod
    def _matching(q: str) -> tuple[list[str], list[Any]]:
        where: list[str] = []
        args: list[Any] = []
        for word in _search_words(q):
            where.append("(text ILIKE %s OR by_name ILIKE %s)")
            args += [_like(word), _like(word)]
        return where, args

    def counts(self, *, q: str = "") -> dict[str, int]:
        where, args = self._matching(q)
        where.append("struck_ms IS NULL")
        rows = self._read(
            f"SELECT subject, count(*) FROM manager_log WHERE {' AND '.join(where)} GROUP BY subject", args
        )
        return {subject: int(count) for subject, count in rows}

    def entries(
        self, *, subject: str | None = None, q: str = "", before: str | None = None, limit: int = PAGE
    ) -> list[LogEntry]:
        where, args = self._matching(q)
        if subject is not None:
            where.append("subject = %s")
            args.append(subject)
        if before is not None:
            where.append("seq < COALESCE((SELECT seq FROM manager_log WHERE entry_id = %s), 0)")
            args.append(before)
        rows = self._read(
            f"SELECT {_ENTRY} FROM manager_log {'WHERE ' + ' AND '.join(where) if where else ''} "
            "ORDER BY seq DESC LIMIT %s",
            [*args, limit],
        )
        return [_entry_of(row) for row in rows]


def default_note_store() -> NoteStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgNoteStore(dsn) if dsn else NoteStore()


def _words(value: object, most: int, what: str) -> str:
    """What somebody typed, tidied: its lines kept, the blank ends and the runs of blank lines taken off."""
    if not isinstance(value, str):
        raise Refused("no_text", f"{what} needs some words.")
    lines = value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    tidy = "\n".join("".join(ch if ch.isprintable() else " " for ch in line).rstrip() for line in lines)
    text = re.sub(r"\n{3,}", "\n\n", tidy).strip()
    if not text:
        raise Refused("no_text", f"{what} needs some words.")
    if len(text) > most:
        raise Refused("long_text", f"{what} is {len(text)} letters long. It can have {most} at most.")
    return text


class ShiftNotes:
    """The rules of the notes for the shift and of the manager's log, over a store."""

    def __init__(self, store: NoteStore | None = None, *, now_ms: Callable[[], int] | None = None) -> None:
        self.store = store if store is not None else NoteStore()
        self._now_ms = now_ms if now_ms is not None else lambda: int(time.time() * 1000)

    def now_ms(self) -> int:
        return self._now_ms()

    # -- notes for the shift

    def _until(self, lasts: object, now_ms: int) -> int | None:
        if lasts not in LASTS:
            raise Refused("bad_lasts", "A note is up for tonight, or stays until it is taken down.")
        if lasts == "stays":
            return None
        end = localtime.night_end(datetime.fromtimestamp(now_ms / 1000, localtime.zone()))
        return int(end.timestamp() * 1000)

    def _up(self, note_id: str, now_ms: int) -> Note:
        note = self.store.note(note_id)
        if note is None:
            raise Refused("unknown_note", "There is no such note.")
        if not note.runs(now_ms):
            raise Refused("ended", "This note has come down. Write it again as a new note.")
        return note

    def write(self, text: object, lasts: object = "tonight", *, by_id: str, by: str) -> Note:
        """A manager puts a note up. They have seen it themselves."""
        now = self.now_ms()
        words = _words(text, TEXT_MAX, "A note")
        until = self._until(lasts, now)
        if len(self.store.notes(now)) >= MOST_NOTES:
            raise Refused("too_many", f"{MOST_NOTES} notes are up already. Take one down first.")
        note = Note(uuid.uuid4().hex, words, by_id, by, now, until)
        self.store.put_note(note)
        self.store.saw(by_id, [note.note_id], now)
        return note

    def change(self, note_id: str, text: object, lasts: object, *, by_id: str, by: str) -> Note:
        """A manager changes a note that is up. New words show it to everybody again (but not to the manager
        who wrote them); only how long it is up changes nothing about who has seen it."""
        now = self.now_ms()
        note = self._up(note_id, now)
        words = _words(text, TEXT_MAX, "A note")
        until = self._until(lasts, now)
        again = words != note.text
        if not again and note.lasts == lasts:
            return note
        changed = replace(note, text=words, until_ms=until)
        if again:
            changed = replace(changed, edited_ms=now, edited_by=by)
        self.store.put_note(changed, again=again)
        if again:
            self.store.saw(by_id, [note_id], now)
        return changed

    def take_down(self, note_id: str, *, by: str) -> Note:
        """A manager takes a note down. It is kept, and nobody is shown it any more."""
        now = self.now_ms()
        note = self.store.note(note_id)
        if note is None:
            raise Refused("unknown_note", "There is no such note.")
        if not note.runs(now):
            return note
        down = replace(note, removed_ms=now, removed_by=by)
        self.store.put_note(down)
        return down

    def for_staff(self, staff_id: str) -> dict[str, Any]:
        """The notes that are up, the newest first, each with whether this person has seen it."""
        now = self.now_ms()
        notes = self.store.notes(now)
        seen = self.store.seen([n.note_id for n in notes])
        rows = [{**n.as_json(), "seen": staff_id in seen[n.note_id]} for n in notes]
        return {"notes": rows, "unseen": sum(1 for row in rows if not row["seen"]), "now_ms": now}

    def saw(self, staff_id: str, note_ids: Collection[str]) -> dict[str, Any]:
        """This person has seen these notes: they are not shown them again."""
        self.store.saw(staff_id, [str(i) for i in note_ids][:100], self.now_ms())
        return self.for_staff(staff_id)

    def board(self, staff: Sequence[tuple[str, str]]) -> dict[str, Any]:
        """A manager's list: the notes that are up, each with who has seen it and who has not yet (of
        `staff`, pairs of id and name), and the ones that came down in the last `EARLIER_DAYS` days."""
        now = self.now_ms()
        notes = self.store.notes(now, since_ms=now - EARLIER_DAYS * DAY_MS)
        seen = self.store.seen([n.note_id for n in notes])
        names = dict(staff)
        up: list[dict[str, Any]] = []
        earlier: list[dict[str, Any]] = []
        for note in notes:
            saw = seen[note.note_id]
            if note.runs(now):
                up.append(
                    {
                        **note.as_json(),
                        "seen": [
                            {"staff_id": staff_id, "name": names[staff_id], "at_ms": at_ms}
                            for staff_id, at_ms in sorted(saw.items(), key=lambda pair: pair[1])
                            if staff_id in names
                        ],
                        "waiting": [name for staff_id, name in staff if staff_id not in saw],
                    }
                )
            else:
                earlier.append(
                    {
                        **note.as_json(),
                        "ended_ms": note.ended_ms(now),
                        "removed_by": note.removed_by,
                        "seen_count": sum(1 for staff_id in saw if staff_id in names),
                    }
                )
        earlier.sort(key=lambda row: row["ended_ms"] or 0, reverse=True)
        return {
            "notes": up,
            "earlier": earlier,
            "staff": len(staff),
            "most": MOST_NOTES,
            "text_max": TEXT_MAX,
            "earlier_days": EARLIER_DAYS,
            "now_ms": now,
        }

    # -- the manager's log

    def log_write(self, subject: object, text: object, *, by_id: str, by: str, device: str = "") -> LogEntry:
        """A manager writes an entry. The hub's clock stamps it."""
        if subject not in SUBJECT_NAMES:
            raise Refused("bad_subject", "Pick what the entry is about.")
        words = _words(text, LOG_TEXT_MAX, "An entry")
        entry = LogEntry(uuid.uuid4().hex, str(subject), words, by_id, by, self.now_ms(), device[:120])
        self.store.put_entry(entry)
        return entry

    def log_strike(self, entry_id: str, *, by: str) -> LogEntry:
        """A manager strikes an entry out. It stays in the log, readable, with who struck it and when."""
        entry = self.store.entry(entry_id)
        if entry is None:
            raise Refused("unknown_entry", "There is no such entry.")
        if entry.struck_ms is not None:
            return entry
        struck = replace(entry, struck_ms=self.now_ms(), struck_by=by)
        self.store.put_entry(struck)
        return struck

    def log_read(
        self, *, subject: str | None = None, q: str = "", before: str | None = None, limit: int = PAGE
    ) -> dict[str, Any]:
        """The log, the newest entry first: of one subject or of all, matching every word of `q` (in the
        entry or in who wrote it), from before the entry named `before`. `subjects` counts the entries under
        each subject (those matching `q`, the struck ones left out), whatever subject is being read."""
        if subject is not None and subject not in SUBJECT_NAMES:
            raise Refused("bad_subject", "There is no such subject.")
        limit = max(1, min(int(limit), 200))
        found = self.store.entries(subject=subject, q=q, before=before, limit=limit + 1)
        counts = self.store.counts(q=q)
        return {
            "subjects": [{"id": key, "name": name, "count": counts.get(key, 0)} for key, name in SUBJECTS],
            "count": sum(counts.get(key, 0) for key, _ in SUBJECTS),
            "entries": [entry.as_json() for entry in found[:limit]],
            "more": len(found) > limit,
            "text_max": LOG_TEXT_MAX,
        }
