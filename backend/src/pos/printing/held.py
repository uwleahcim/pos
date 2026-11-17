"""The tickets of orders sent ahead of their time: what waits, kept where a restart cannot lose it.

An order for later (tonight at seven, Saturday's catering) is sent when it is taken and cooked when its time
comes. Until then nothing of it is on paper and nothing of it is drawn: the hub keeps only which dishes wait
(`Held`), by order, and makes the ticket when the time comes, from the order as it stands at that moment
(`PrintService.release_due`). So a dish added on Wednesday is on Saturday's ticket, a dish taken off is
not, and the ticket says what is paid then.

What waits is kept in PostgreSQL on every hub (`PgHeldTickets`), so a hub that is updated or loses power
on Thursday still prints on Saturday, and the hub that takes over has the same list. A standby never prints:
`due` gives it nothing until it is promoted. In memory for tests and a laptop.
"""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass, replace
from typing import Any


@dataclass(frozen=True)
class Part:
    """The dishes one send put on hold: the op that sent them (`key`, which the ticket's job is named by), the
    lines by id, and the stations the screen that sent them prints no ticket at (`skip`)."""

    key: str
    lines: tuple[str, ...]
    skip: tuple[str, ...] = ()

    def as_json(self) -> dict[str, Any]:
        return {"key": self.key, "lines": list(self.lines), "skip": list(self.skip)}

    @staticmethod
    def from_json(raw: Any) -> Part | None:
        if not isinstance(raw, dict) or not isinstance(raw.get("key"), str):
            return None
        lines = tuple(str(line) for line in raw.get("lines") or ())
        return Part(raw["key"], lines, tuple(str(s) for s in raw.get("skip") or ())) if lines else None


@dataclass(frozen=True)
class Held:
    """What waits of one order, and when it prints: `start_ms` is its promised time less its lead, as the
    order stood when this was last written (wall-clock ms)."""

    order_id: str
    start_ms: int
    parts: tuple[Part, ...] = ()

    @property
    def lines(self) -> frozenset[str]:
        return frozenset(line for part in self.parts for line in part.lines)

    def without(self, lines: frozenset[str] | set[str]) -> Held:
        """The same with these dishes off it: a part left with none is gone."""
        parts = (replace(p, lines=tuple(i for i in p.lines if i not in lines)) for p in self.parts)
        return replace(self, parts=tuple(p for p in parts if p.lines))


class HeldTickets:
    """What waits, by order. In memory: tests and a laptop. Every hub and the cloud use `PgHeldTickets`."""

    def __init__(self) -> None:
        self._held: dict[str, Held] = {}
        self._lock = threading.Lock()
        self.fresh = True
        """Whether this list was only just begun, so that it cannot know of orders sent ahead before it: a
        hub that starts with a fresh one takes those on (`PrintService.adopt`). One in memory always is."""

    def get(self, order_id: str) -> Held | None:
        with self._lock:
            return self._held.get(order_id)

    def put(self, held: Held) -> None:
        """Keeps this for its order in place of what was kept; one with no dish left is dropped."""
        with self._lock:
            if held.parts:
                self._held[held.order_id] = held
            else:
                self._held.pop(held.order_id, None)

    def drop(self, order_id: str) -> None:
        with self._lock:
            self._held.pop(order_id, None)

    def due(self, by_ms: int) -> list[Held]:
        """The orders whose tickets print at `by_ms` or before, the earliest first."""
        with self._lock:
            return sorted((h for h in self._held.values() if h.start_ms <= by_ms), key=_soonest)

    def all(self) -> list[Held]:
        with self._lock:
            return sorted(self._held.values(), key=_soonest)


def _soonest(held: Held) -> tuple[int, str]:
    return held.start_ms, held.order_id


SCHEMA = """
CREATE TABLE IF NOT EXISTS held_ticket (
    order_id TEXT PRIMARY KEY,
    start_ms BIGINT NOT NULL,
    parts    JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS held_ticket_start_ms ON held_ticket (start_ms);
"""


class PgHeldTickets(HeldTickets):
    """The same calls, in PostgreSQL, so what waits is there after a restart and on the hub that takes over."""

    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        from psycopg.rows import tuple_row
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery(), to_regclass('held_ticket') IS NULL").fetchone()
            self.fresh = bool(row is not None and not row[0] and row[1])  # this start is the one that makes it
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    @staticmethod
    def _row(row: tuple[Any, ...]) -> Held:
        parts = (Part.from_json(raw) for raw in (row[2] if isinstance(row[2], list) else ()))
        return Held(str(row[0]), int(row[1]), tuple(p for p in parts if p is not None))

    def _read(self, where: str, args: tuple[Any, ...]) -> list[Held]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute(
                    f"SELECT order_id, start_ms, parts FROM held_ticket {where} ORDER BY start_ms, order_id", args
                ).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet
        return [self._row(row) for row in rows]

    def get(self, order_id: str) -> Held | None:
        found = self._read("WHERE order_id = %s", (order_id,))
        return found[0] if found else None

    def put(self, held: Held) -> None:
        from psycopg.types.json import Jsonb

        if not held.parts:
            self.drop(held.order_id)
            return
        with self._pool.connection() as conn:
            conn.execute(
                """
                INSERT INTO held_ticket (order_id, start_ms, parts) VALUES (%s, %s, %s)
                ON CONFLICT (order_id) DO UPDATE SET start_ms = EXCLUDED.start_ms, parts = EXCLUDED.parts
                """,
                (held.order_id, held.start_ms, Jsonb([part.as_json() for part in held.parts])),
            )

    def drop(self, order_id: str) -> None:
        with self._pool.connection() as conn:
            conn.execute("DELETE FROM held_ticket WHERE order_id = %s", (order_id,))

    def due(self, by_ms: int) -> list[Held]:
        # a standby has the list and prints nothing: the hub that takes orders does, and this one once it is
        # promoted
        return self._read("WHERE start_ms <= %s AND NOT pg_is_in_recovery()", (by_ms,))

    def all(self) -> list[Held]:
        return self._read("", ())


def default_held() -> HeldTickets:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgHeldTickets(dsn) if dsn else HeldTickets()
