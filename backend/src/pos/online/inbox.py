"""Every online order the hub was given, written down before anything is done with it.

The website's service hands an accepted order over once (`pos.online.gloriafood`). If the hub lost it between
being given it and putting it on the POS, nobody would send it again. So an order is written here first, as
it came, and only then turned into a check; what became of it is written beside it:

- `new`: written down, not yet looked at;
- `placed`: it is on the POS, as the order `order_id`;
- `kept`: not something the POS takes as an order (a table reservation, an order that was not accepted);
  `said` tells why. Nothing is lost: it is still in the website's own app;
- `failed`: it could not be put on the POS; `said` tells why, and it is tried again a few times.

An order as it came holds the customer's name, number, address and e-mail. It is kept `KEEP_DAYS` days, so
that an order that went wrong can be looked at and put right, and then only what became of it stays: the
website's number for it, the day, and the POS order it turned into. Nothing here is sent anywhere.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from typing import Any

STATES = ("new", "placed", "kept", "failed")
POLL, PUSH = "poll", "push"
"""How an order reached the hub first: the hub asked for it, or the website's service sent it."""
MOST_TRIES = 5
"""How often an order that could not be put on the POS is tried again before it is left for a person."""
KEEP_DAYS = 30
"""How long an order is kept as it came, with the customer's details; after that only what became of it."""
SAID_MAX = 300


class ReadOnlyError(RuntimeError):
    """The database is a standby: nothing can be written here until it is promoted."""


@dataclass(frozen=True)
class Arrival:
    """One order as the website's service gave it, and what became of it here."""

    source: str  # "gloriafood"
    ext_id: str  # the service's own number for the order
    fetched_ms: int
    raw: dict[str, Any] | None  # as it came; None once it is older than `KEEP_DAYS`
    kind: str = ""  # pickup | delivery | table_reservation | ..., as the service called it
    state: str = "new"
    order_id: str | None = None  # the POS order it became
    said: str = ""  # why it was kept or failed, or what a person should know of one that was placed
    tries: int = 0
    settled_ms: int | None = None
    via: str = POLL  # how it reached the hub first: asked for (`POLL`) or sent to it (`PUSH`)

    @property
    def waiting(self) -> bool:
        """Still to be put on the POS: new, or failed fewer times than a person is asked for."""
        return self.state == "new" or (self.state == "failed" and self.tries < MOST_TRIES)

    def about(self) -> dict[str, Any]:
        """What the hub says of it to whoever asks how the online orders are doing: nothing of the customer."""
        return {
            "source": self.source,
            "id": self.ext_id,
            "kind": self.kind,
            "state": self.state,
            "order_id": self.order_id,
            "said": self.said,
            "tries": self.tries,
            "fetched_ms": self.fetched_ms,
            "via": self.via,
        }


class Inbox:
    """The orders in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._rows: dict[tuple[str, str], Arrival] = {}  # in the order they came
        self._lock = threading.Lock()

    def writable(self) -> bool:
        """Whether an order can be written down here now. Asked before GloriaFood is: an order it hands over
        and that cannot be written down would be nowhere."""
        return True

    def add(self, arrival: Arrival) -> bool:
        """Writes down an order that just came. False when it is already here: the service may send the same
        order twice, and the first one stands."""
        with self._lock:
            key = (arrival.source, arrival.ext_id)
            if key in self._rows:
                return False
            self._rows[key] = arrival
            return True

    def settle(self, arrival: Arrival) -> None:
        """Writes what became of an order that is here: its state, the POS order, what is said of it and
        how often it was tried. The order as it came, and when, stay as they were written down."""
        with self._lock:
            key = (arrival.source, arrival.ext_id)
            if key in self._rows:
                self._rows[key] = replace(
                    self._rows[key],
                    state=arrival.state,
                    order_id=arrival.order_id,
                    said=arrival.said[:SAID_MAX],
                    tries=arrival.tries,
                    settled_ms=arrival.settled_ms,
                )

    def get(self, source: str, ext_id: str) -> Arrival | None:
        with self._lock:
            return self._rows.get((source, ext_id))

    def waiting(self, limit: int = 50) -> list[Arrival]:
        """The orders still to be put on the POS, the oldest first."""
        with self._lock:
            return [row for row in self._rows.values() if row.waiting][:limit]

    def since(self, since_ms: int) -> list[Arrival]:
        """Every order that came at or after `since_ms`, in the order they came."""
        with self._lock:
            return [row for row in self._rows.values() if row.fetched_ms >= since_ms]

    def troubled(self, limit: int = 10) -> list[Arrival]:
        """The orders that could not be put on the POS, the newest first."""
        with self._lock:
            failed = [row for row in self._rows.values() if row.state == "failed"]
        return sorted(failed, key=lambda row: row.fetched_ms, reverse=True)[:limit]

    def forget_before(self, before_ms: int) -> int:
        """Drops the customer's details from every order that came before `before_ms` and is not still to be
        put on the POS. Gives how many were dropped."""
        dropped = 0
        with self._lock:
            for key, row in self._rows.items():
                if row.raw is not None and row.fetched_ms < before_ms and not row.waiting:
                    self._rows[key] = replace(row, raw=None)
                    dropped += 1
        return dropped


SCHEMA = """
CREATE TABLE IF NOT EXISTS online_order (
    seq        BIGSERIAL PRIMARY KEY,
    source     TEXT NOT NULL,
    ext_id     TEXT NOT NULL,
    fetched_ms BIGINT NOT NULL,
    raw        JSONB,
    kind       TEXT NOT NULL DEFAULT '',
    state      TEXT NOT NULL DEFAULT 'new',
    order_id   TEXT,
    said       TEXT NOT NULL DEFAULT '',
    tries      INTEGER NOT NULL DEFAULT 0,
    settled_ms BIGINT,
    via        TEXT NOT NULL DEFAULT 'poll',
    UNIQUE (source, ext_id)
);
CREATE INDEX IF NOT EXISTS online_order_fetched ON online_order (fetched_ms);
"""
# A hub that wrote orders down before they could also be pushed has the table without `via`. Looked for
# first, and added only where it is missing: adding a column locks the table, and that is not for every minute.
HAS_VIA = (
    "SELECT 1 FROM information_schema.columns "
    "WHERE table_schema = current_schema() AND table_name = 'online_order' AND column_name = 'via'"
)
ADD_VIA = "ALTER TABLE online_order ADD COLUMN IF NOT EXISTS via TEXT NOT NULL DEFAULT 'poll'"

_COLUMNS = "source, ext_id, fetched_ms, raw, kind, state, order_id, said, tries, settled_ms, via"


def _prepare(conn: Any) -> None:
    """The table as this version writes it, on a database that can be written."""
    conn.execute(SCHEMA)
    if conn.execute(HAS_VIA).fetchone() is None:
        conn.execute(ADD_VIA)


def _arrival_of(row: Sequence[Any]) -> Arrival:
    return Arrival(
        source=row[0],
        ext_id=row[1],
        fetched_ms=int(row[2]),
        raw=dict(row[3]) if isinstance(row[3], Mapping) else None,
        kind=row[4],
        state=row[5],
        order_id=row[6],
        said=row[7],
        tries=int(row[8]),
        settled_ms=None if row[9] is None else int(row[9]),
        via=row[10],
    )


class PgInbox(Inbox):
    """The same calls, in PostgreSQL: an order written down is there after a restart and on the hub that
    takes over."""

    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        from psycopg.rows import tuple_row
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                _prepare(conn)

    def close(self) -> None:
        self._pool.close()

    def writable(self) -> bool:
        try:
            with self._pool.connection() as conn:
                row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
                if row is None or row[0]:
                    return False  # a standby: the hub that takes the orders asks
                _prepare(conn)  # a standby that was promoted since this one started
                return True
        except Exception:  # noqa: BLE001 - whatever is wrong with the database, nothing can be written
            return False

    def _read(self, sql: str, args: Sequence[Any]) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                return conn.execute(sql, args).fetchall()
        except (errors.UndefinedTable, errors.UndefinedColumn):
            return []  # a standby whose primary has not been updated yet

    def add(self, arrival: Arrival) -> bool:
        from psycopg import errors
        from psycopg.types.json import Jsonb

        try:
            with self._pool.connection() as conn:
                done = conn.execute(
                    f"INSERT INTO online_order ({_COLUMNS}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    "ON CONFLICT (source, ext_id) DO NOTHING",
                    (
                        arrival.source,
                        arrival.ext_id,
                        arrival.fetched_ms,
                        None if arrival.raw is None else Jsonb(arrival.raw),
                        arrival.kind,
                        arrival.state,
                        arrival.order_id,
                        arrival.said[:SAID_MAX],
                        arrival.tries,
                        arrival.settled_ms,
                        arrival.via,
                    ),
                )
                return done.rowcount == 1
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def settle(self, arrival: Arrival) -> None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                conn.execute(
                    "UPDATE online_order SET state = %s, order_id = %s, said = %s, tries = %s, settled_ms = %s "
                    "WHERE source = %s AND ext_id = %s",
                    (
                        arrival.state,
                        arrival.order_id,
                        arrival.said[:SAID_MAX],
                        arrival.tries,
                        arrival.settled_ms,
                        arrival.source,
                        arrival.ext_id,
                    ),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def get(self, source: str, ext_id: str) -> Arrival | None:
        rows = self._read(f"SELECT {_COLUMNS} FROM online_order WHERE source = %s AND ext_id = %s", (source, ext_id))
        return _arrival_of(rows[0]) if rows else None

    def waiting(self, limit: int = 50) -> list[Arrival]:
        rows = self._read(
            f"SELECT {_COLUMNS} FROM online_order "
            "WHERE state = 'new' OR (state = 'failed' AND tries < %s) ORDER BY seq LIMIT %s",
            (MOST_TRIES, limit),
        )
        return [_arrival_of(row) for row in rows]

    def since(self, since_ms: int) -> list[Arrival]:
        rows = self._read(f"SELECT {_COLUMNS} FROM online_order WHERE fetched_ms >= %s ORDER BY seq", (since_ms,))
        return [_arrival_of(row) for row in rows]

    def troubled(self, limit: int = 10) -> list[Arrival]:
        rows = self._read(
            f"SELECT {_COLUMNS} FROM online_order WHERE state = 'failed' ORDER BY fetched_ms DESC, seq DESC LIMIT %s",
            (limit,),
        )
        return [_arrival_of(row) for row in rows]

    def forget_before(self, before_ms: int) -> int:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                done = conn.execute(
                    "UPDATE online_order SET raw = NULL WHERE raw IS NOT NULL AND fetched_ms < %s "
                    "AND NOT (state = 'new' OR (state = 'failed' AND tries < %s))",
                    (before_ms, MOST_TRIES),
                )
                return done.rowcount
        except (errors.ReadOnlySqlTransaction, errors.UndefinedTable):
            return 0


def default_inbox() -> Inbox:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgInbox(dsn) if dsn else Inbox()
