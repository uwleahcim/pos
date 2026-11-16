"""The operation log in PostgreSQL: the same store as `OpStore`, surviving restarts.

One table, `ops`, holds every operation in arrival order. `seq` is dense (1, 2, 3, ...) so the cursor a
peer keeps is simply the last `seq` it has seen, exactly as with the in-memory store. Appends take a
short advisory lock so two API workers cannot hand out the same `seq`.

A second table, `orders`, is the index of the log: one row per order with where it stands, when it was
opened and last changed, and how far its history goes. It is written in the same transaction as the
operations, so it is never behind them, and a standby gets it with the rest of the database. The screens ask
for the open orders every two seconds: with the index that is one small query and no replay while nothing
changed, where reading the log itself meant replaying every order ever taken (0.2 s after one day of
service, 8 s after a month, measured 2026-11-12). A database written before the index existed is indexed
when the hub starts.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable, Iterable, Sequence
from typing import Any

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .hlc import HLC
from .oplog import KINDS, MAX_DRIFT_MS, ClockDriftError, Op, OrderEntry, OrderState, Views, replay

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS ops (
    seq         BIGINT PRIMARY KEY,
    op_id       TEXT NOT NULL UNIQUE,
    order_id    TEXT NOT NULL,
    hlc_wall    BIGINT NOT NULL,
    hlc_counter INTEGER NOT NULL,
    hlc_node    TEXT NOT NULL,
    device      TEXT NOT NULL,
    kind        TEXT NOT NULL,
    data        JSONB NOT NULL DEFAULT '{}'::jsonb,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ops_order_id ON ops (order_id, seq);
CREATE TABLE IF NOT EXISTS orders (
    order_id TEXT PRIMARY KEY,
    status   TEXT NOT NULL,
    first_ms BIGINT,
    last_ms  BIGINT,
    version  BIGINT NOT NULL,
    tip      TEXT NOT NULL,
    phone    TEXT NOT NULL DEFAULT '',
    promised_ms BIGINT
);
CREATE INDEX IF NOT EXISTS orders_open ON orders (order_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS orders_first_ms ON orders (first_ms);
CREATE INDEX IF NOT EXISTS orders_last_ms ON orders (last_ms);
"""

# What the index came to keep after it was first made: the customer's number on each order, as digits (added
# 2026-11-15, to find a caller's earlier orders) and the time an order is promised for (added 2026-11-16, to
# find the orders rung earlier for a day). An index made before either gets the columns and every row is
# worked out again, once (`_ensure_index`).
_ADDED = ("phone", "promised_ms")
_HAS_ADDED = """
SELECT count(*) FROM information_schema.columns
WHERE table_schema = current_schema() AND table_name = 'orders' AND column_name = ANY(%s)
"""
_ADD = """
ALTER TABLE orders ADD COLUMN IF NOT EXISTS phone TEXT NOT NULL DEFAULT '';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS promised_ms BIGINT;
CREATE INDEX IF NOT EXISTS orders_phone ON orders (phone, first_ms) WHERE phone <> '';
CREATE INDEX IF NOT EXISTS orders_promised_ms ON orders (promised_ms) WHERE promised_ms IS NOT NULL;
"""

_UNINDEXED = """
SELECT o.order_id
FROM (SELECT order_id, MAX(seq) AS seq FROM ops GROUP BY order_id) o
LEFT JOIN orders r ON r.order_id = o.order_id
WHERE r.order_id IS NULL OR r.version <> o.seq
ORDER BY o.order_id
"""

_INDEX = """
INSERT INTO orders (order_id, status, first_ms, last_ms, version, tip, phone, promised_ms)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (order_id) DO UPDATE SET status = EXCLUDED.status, first_ms = EXCLUDED.first_ms,
    last_ms = EXCLUDED.last_ms, version = EXCLUDED.version, tip = EXCLUDED.tip, phone = EXCLUDED.phone,
    promised_ms = EXCLUDED.promised_ms
"""

_ENTRY = "order_id, status, first_ms, last_ms, version, tip, phone, promised_ms"

_EVERY_ORDER = "SELECT DISTINCT order_id FROM ops ORDER BY order_id"

_APPEND_LOCK = 7_031  # advisory lock key: one appender at a time on this database

_COLUMNS = "op_id, order_id, hlc_wall, hlc_counter, hlc_node, device, kind, data"


def _row_to_op(row: tuple[Any, ...]) -> Op:
    op_id, order_id, wall, counter, node, device, kind, data = row
    return Op(op_id=op_id, order_id=order_id, hlc=HLC(wall, counter, node), device=device, kind=kind, data=data)


class ReadOnlyError(RuntimeError):
    """This database is a standby: it serves reads, and writes go to the primary (or wait for a promotion)."""


class PgOpStore:
    """Same calls as `OpStore`; the API does not know which one it holds."""

    def __init__(self, dsn: str, physical: Callable[[], int] | None = None, *, pool_size: int = 4) -> None:
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        self._physical = physical or (lambda: int(time.time() * 1000))
        self._views = Views()
        self._indexed = False  # the orders table is there and level with the log
        if self.role == "primary":
            self._ensure_index()

    @property
    def role(self) -> str:
        """'primary' when this database accepts writes, 'replica' while it streams from another."""
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
        return "replica" if row and row[0] else "primary"

    def close(self) -> None:
        self._pool.close()

    @property
    def cursor(self) -> int:
        with self._pool.connection() as conn:
            row = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM ops").fetchone()
        return int(row[0]) if row else 0

    def now_ms(self) -> int:
        """The store's wall clock, the one operations are checked against."""
        return self._physical()

    def __contains__(self, op_id: str) -> bool:
        with self._pool.connection() as conn:
            return conn.execute("SELECT 1 FROM ops WHERE op_id = %s", (op_id,)).fetchone() is not None

    def __len__(self) -> int:
        return self.cursor

    def append(self, ops: Iterable[Op]) -> list[Op]:
        """Store new operations; duplicates are ignored. Returns the ones that were new."""
        now = self._physical()
        batch = list(ops)
        for op in batch:
            if op.hlc.wall_ms > now + MAX_DRIFT_MS:
                raise ClockDriftError(op, now)
            if op.kind not in KINDS:
                raise ValueError(f"unknown op kind {op.kind!r}")
        accepted: list[Op] = []
        try:
            if not self._indexed:
                self._ensure_index()  # a standby promoted since this hub started: the index is its to keep now
            with self._pool.connection() as conn, conn.transaction():
                self._insert(conn, batch, accepted)
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("standby database") from err
        return accepted

    def _insert(self, conn: Any, batch: list[Op], accepted: list[Op]) -> None:
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (_APPEND_LOCK,))
        row = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM ops").fetchone()
        seq = int(row[0]) if row else 0
        for op in batch:
            seq += 1
            inserted = conn.execute(
                f"INSERT INTO ops (seq, {_COLUMNS}) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) "
                "ON CONFLICT (op_id) DO NOTHING RETURNING seq",
                (
                    seq,
                    op.op_id,
                    op.order_id,
                    op.hlc.wall_ms,
                    op.hlc.counter,
                    op.hlc.node,
                    op.device,
                    op.kind,
                    Jsonb(op.data),
                ),
            ).fetchone()
            if inserted is None:
                seq -= 1  # a duplicate: keep `seq` dense
                continue
            accepted.append(op)
        self._index_orders(conn, sorted({op.order_id for op in accepted}))

    def since(self, cursor: int, limit: int | None = None) -> list[Op]:
        sql = f"SELECT {_COLUMNS} FROM ops WHERE seq > %s ORDER BY seq"
        params: tuple[Any, ...] = (cursor,)
        if limit is not None:
            sql += " LIMIT %s"
            params += (limit,)
        with self._pool.connection() as conn:
            return [_row_to_op(row) for row in conn.execute(sql, params)]

    def arrivals(self, cursor: int, limit: int = 2000) -> list[tuple[int, str]]:
        """Where each operation after `cursor` landed and whose it is, oldest first: `(cursor, order id)`.
        What the change feed tells the screens: one read of the primary key's tail, whoever wrote it (this
        process, another worker, or the primary this standby follows)."""
        sql = "SELECT seq, order_id FROM ops WHERE seq > %s ORDER BY seq LIMIT %s"
        with self._pool.connection() as conn:
            return [(int(seq), order_id) for seq, order_id in conn.execute(sql, (cursor, limit))]

    def for_order(self, order_id: str) -> list[Op]:
        with self._pool.connection() as conn:
            rows = conn.execute(f"SELECT {_COLUMNS} FROM ops WHERE order_id = %s ORDER BY seq", (order_id,))
            return [_row_to_op(row) for row in rows]

    def order_ids(self) -> list[str]:
        with self._pool.connection() as conn:
            return [row[0] for row in conn.execute("SELECT DISTINCT order_id FROM ops ORDER BY order_id")]

    def state(self, order_id: str) -> OrderState:
        """The order, replayed now: the caller's own copy, to change as it likes (`view` for a shared one)."""
        return replay(self.for_order(order_id), order_id)

    def op_ids(self) -> frozenset[str]:
        with self._pool.connection() as conn:
            return frozenset(row[0] for row in conn.execute("SELECT op_id FROM ops"))

    # The index of the log -----------------------------------------------------------------------------------

    def entry(self, order_id: str) -> OrderEntry | None:
        """The index's row for one order, or None for an order the log has never heard of."""
        try:
            with self._pool.connection() as conn:
                row = conn.execute(f"SELECT {_ENTRY} FROM orders WHERE order_id = %s", (order_id,)).fetchone()
        except (errors.UndefinedTable, errors.UndefinedColumn):
            if self._ensure_index():
                return self.entry(order_id)
            return next(iter(self._scan([order_id])), None)
        return None if row is None else OrderEntry(*row)

    def index(
        self,
        *,
        status: str | None = None,
        opened_since: int | None = None,
        active_since: int | None = None,
        phone: str | None = None,
        promised: tuple[int, int] | None = None,
    ) -> list[OrderEntry]:
        """The orders that stand at `status`, were opened at or after `opened_since`, last changed at or
        after `active_since` (wall-clock ms), carry the number `phone` (digits, see `phone_digits`) and are
        promised for a time from `promised[0]` up to, not at, `promised[1]`, whichever of the five are
        given, by order id."""
        where: list[str] = []
        params: list[Any] = []
        for clause, value in (
            ("status = %s", status),
            ("first_ms >= %s", opened_since),
            ("last_ms >= %s", active_since),
            ("phone = %s", phone),
            ("promised_ms >= %s", None if promised is None else promised[0]),
            ("promised_ms < %s", None if promised is None else promised[1]),
        ):
            if value is not None:
                where.append(clause)
                params.append(value)
        sql = f"SELECT {_ENTRY} FROM orders" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY order_id"
        try:
            with self._pool.connection() as conn:
                return [OrderEntry(*row) for row in conn.execute(sql, params)]
        except (errors.UndefinedTable, errors.UndefinedColumn):
            if self._ensure_index():
                return self.index(
                    status=status,
                    opened_since=opened_since,
                    active_since=active_since,
                    phone=phone,
                    promised=promised,
                )
            return [e for e in self._scan() if e.picked(status, opened_since, active_since, phone, promised)]

    def views(self, entries: Sequence[OrderEntry]) -> list[OrderState]:
        """The orders of these index rows, in the same order, each replayed only if it changed since it was
        last read (the changed ones in one query). Shared: read them, never change them."""
        found = {entry.order_id: self._views.get(entry) for entry in entries}
        missing = [order_id for order_id, state in found.items() if state is None]
        if missing:
            with self._pool.connection() as conn:
                for state, version, tip in self._replayed(conn, missing):
                    self._views.put(state.order_id, version, tip, state)
                    found[state.order_id] = state
        return [found[entry.order_id] or OrderState(order_id=entry.order_id) for entry in entries]

    def view(self, order_id: str) -> OrderState | None:
        """One order as it stands, replayed only if it changed since it was last read; None for an order the
        log has never heard of. Shared: read it, never change it."""
        entry = self.entry(order_id)
        return None if entry is None else self.views([entry])[0]

    @staticmethod
    def _replayed(conn: Any, order_ids: Sequence[str]) -> list[tuple[OrderState, int, str]]:
        """These orders replayed from the log as this connection sees it, each with the cursor and the id of
        its newest arrival."""
        ops: dict[str, list[Op]] = {}
        newest: dict[str, tuple[int, str]] = {}
        rows = conn.execute(
            f"SELECT seq, {_COLUMNS} FROM ops WHERE order_id = ANY(%s) ORDER BY seq", (list(order_ids),)
        )
        for seq, *row in rows:
            op = _row_to_op(tuple(row))
            ops.setdefault(op.order_id, []).append(op)
            newest[op.order_id] = (int(seq), op.op_id)
        return [(replay(order_ops, order_id), *newest[order_id]) for order_id, order_ops in ops.items()]

    def _index_orders(self, conn: Any, order_ids: Sequence[str]) -> None:
        """Rewrites the index rows of these orders from the log, inside the caller's transaction."""
        if not order_ids:
            return
        rows = [
            (*_entry_row(OrderEntry.of(state, version, tip)),)
            for state, version, tip in self._replayed(conn, order_ids)
        ]
        with conn.cursor() as cur:
            cur.executemany(_INDEX, rows)

    def _ensure_index(self) -> bool:
        """Makes the tables and brings the index level with the log, when this database takes writes: a hub
        updated from a build without the index, a database restored from a backup of one, or a standby that
        was promoted. False on a standby whose primary has no index yet: reads there fall back to the log.

        An index from a build that did not keep each order's phone number, or the time it is promised for,
        gets the columns, and every order is indexed again, once: both are in the log, not in the old rows."""
        if self.role != "primary":
            return False
        with self._pool.connection() as conn:
            conn.execute(SCHEMA)
            with conn.transaction():
                conn.execute("SELECT pg_advisory_xact_lock(%s)", (_APPEND_LOCK,))
                had = conn.execute(_HAS_ADDED, (list(_ADDED),)).fetchone()
                complete = had is not None and had[0] == len(_ADDED)
                conn.execute(_ADD)
                if complete:
                    behind = [row[0] for row in conn.execute(_UNINDEXED)]
                else:
                    behind = [row[0] for row in conn.execute(_EVERY_ORDER)]
                for at in range(0, len(behind), 200):
                    self._index_orders(conn, behind[at : at + 200])
        if behind:
            log.info("orders index: %d orders indexed from the log", len(behind))
        self._indexed = True
        return True

    def _scan(self, order_ids: Sequence[str] | None = None) -> list[OrderEntry]:
        """The index worked out from the log itself, as before there was one: only for a standby whose primary
        has not been updated yet."""
        with self._pool.connection() as conn:
            if order_ids is None:
                order_ids = [row[0] for row in conn.execute("SELECT DISTINCT order_id FROM ops ORDER BY order_id")]
            out: list[OrderEntry] = []
            for at in range(0, len(order_ids), 200):
                for state, version, tip in self._replayed(conn, order_ids[at : at + 200]):
                    self._views.put(state.order_id, version, tip, state)
                    out.append(OrderEntry.of(state, version, tip))
        return sorted(out, key=lambda e: e.order_id)


def _entry_row(entry: OrderEntry) -> tuple[Any, ...]:
    return (
        entry.order_id,
        entry.status,
        entry.first_ms,
        entry.last_ms,
        entry.version,
        entry.tip,
        entry.phone,
        entry.promised_ms,
    )
