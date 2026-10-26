"""The operation log in PostgreSQL: the same store as `OpStore`, surviving restarts.

One table, `ops`, holds every operation in arrival order. `seq` is dense (1, 2, 3, ...) so the cursor a
peer keeps is simply the last `seq` it has seen, exactly as with the in-memory store. Appends take a
short advisory lock so two API workers cannot hand out the same `seq`.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Iterable
from typing import Any

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .hlc import HLC
from .oplog import KINDS, MAX_DRIFT_MS, ClockDriftError, Op, OrderState, replay

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
"""

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
        if self.role == "primary":
            with self._pool.connection() as conn:
                conn.execute(SCHEMA)

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

    def since(self, cursor: int, limit: int | None = None) -> list[Op]:
        sql = f"SELECT {_COLUMNS} FROM ops WHERE seq > %s ORDER BY seq"
        params: tuple[Any, ...] = (cursor,)
        if limit is not None:
            sql += " LIMIT %s"
            params += (limit,)
        with self._pool.connection() as conn:
            return [_row_to_op(row) for row in conn.execute(sql, params)]

    def for_order(self, order_id: str) -> list[Op]:
        with self._pool.connection() as conn:
            rows = conn.execute(f"SELECT {_COLUMNS} FROM ops WHERE order_id = %s ORDER BY seq", (order_id,))
            return [_row_to_op(row) for row in rows]

    def order_ids(self) -> list[str]:
        with self._pool.connection() as conn:
            return [row[0] for row in conn.execute("SELECT DISTINCT order_id FROM ops ORDER BY order_id")]

    def state(self, order_id: str) -> OrderState:
        return replay(self.for_order(order_id), order_id)

    def op_ids(self) -> frozenset[str]:
        with self._pool.connection() as conn:
            return frozenset(row[0] for row in conn.execute("SELECT op_id FROM ops"))
