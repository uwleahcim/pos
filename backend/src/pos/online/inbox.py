"""Every online order the hub was given, written down before anything is done with it.

The website's service hands an accepted order over once (`pos.online.gloriafood`). If the hub lost it between
being given it and putting it on the POS, nobody would send it again. So an order is written here first, as
it came, and only then turned into a check; what became of it is written beside it:

- `new`: written down, not yet looked at;
- `placed`: it is on the POS, as the order `order_id`;
- `booked`: it was a table booked on the website and is in the reservation book (`pos.online.book`);
- `kept`: not something the POS takes as an order (an order placed from a table, one that was not accepted);
  `said` tells why. Nothing is lost: it is still in the website's own app;
- `failed`: it could not be put on the POS; `said` tells why, and it is tried again a few times.

The website's service can also be set to hand an order over before the restaurant answered it, and again
when it did (an integration of GloriaFood's with "Pending" among its statuses), or every time something of
it changes ("Send every time an order is updated"). So an order that is here, not on the POS, and comes
again saying something else of itself is taken as it comes now (`Inbox.again`): the one that waited to be
accepted goes on the POS when it is, and one that was cancelled meanwhile never does. What is said later of
an order that is on the POS is the POS's to take (`pos.online.after`); here only the order as it came last
is kept in place of the one before (`Inbox.heard`).

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

STATES = ("new", "placed", "booked", "kept", "failed")
POLL, PUSH = "poll", "push"
"""How an order reached the hub first: the hub asked for it, or the website's service sent it."""
MOST_TRIES = 5
"""How often an order that could not be put on the POS is tried again before it is left for a person."""
KEEP_DAYS = 30
"""How long an order is kept as it came, with the customer's details; after that only what became of it."""
SAID_MAX = 300
ACCEPTED, PENDING = "accepted", "pending"
"""What an order says became of it at the restaurant (`status_of`): `ACCEPTED`, and `PENDING` while nobody
there has answered it. The website's service has more words (rejected, timed_out, canceled); they are read
as they come."""
RETAKEN = ("kept", "new", "failed")
"""The states in which an order that comes again saying something else became of it is taken as it comes
now: it is not on the POS. One that is written down and not looked at yet (`new`) is also taken when it
only says it is ready now: nothing was done with it, so the newest word of it is the one to go by."""


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
    # Which of the restaurant's accounts brought it (`pos.online.accounts`); nothing for one that came before
    # there could be several, and for a push the hub could not put to an account.
    account: str = ""

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
            "settled_ms": self.settled_ms,
            "via": self.via,
            "account": self.account,
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
        order twice, and the first one stands. One that is here without an account learns it from the one
        that comes with one (a push that named none, then the asking for an account): nothing else of it
        changes, and `account_of` knows that restaurant from then on."""
        with self._lock:
            key = (arrival.source, arrival.ext_id)
            if key in self._rows:
                if arrival.account and not self._rows[key].account:
                    self._rows[key] = replace(self._rows[key], account=arrival.account)
                return False
            self._rows[key] = arrival
            return True

    def again(self, arrival: Arrival) -> bool:
        """An order that is here comes again, and says something else became of it than it said when it was
        written down: it was handed over while it waited to be accepted, and now it is accepted (or turned
        down, or missed, or cancelled). Then what came now is written in place of what came then, and the
        order waits to be looked at as a new one does. True when that was so.

        Only an order that is not on the POS: one that was kept, one that would not go on, or one that is
        written down and not looked at yet (that one also when it only says it is ready now). One that is
        on the POS or in the book stays as it is here whatever is sent after it. An order never goes back
        to waiting either: one that comes again unanswered says nothing new. Nor does an older copy take
        the place of a newer one (`updated_at`, where both say it): a cancelled order is not accepted again
        by a copy that was on its way. When it came first, how, and from which account stay as they were
        written down."""
        told = None if arrival.raw is None else status_of(arrival.raw)
        if arrival.raw is None or told is None or told == PENDING:
            return False
        with self._lock:
            key = (arrival.source, arrival.ext_id)
            here = self._rows.get(key)
            if here is None or here.raw is None or here.state not in RETAKEN:
                return False
            news = status_of(here.raw) != told or (here.state == "new" and _ready(here.raw) != _ready(arrival.raw))
            if not news or (_updated(arrival.raw) and _updated(here.raw) > _updated(arrival.raw)):
                return False
            self._rows[key] = replace(
                here, raw=arrival.raw, kind=arrival.kind, state="new", order_id=None, said="", tries=0, settled_ms=None
            )
            return True

    def heard(self, arrival: Arrival) -> None:
        """An order that is on the POS or in the book came again (`pos.online.after`): the order as it came
        now is kept in place of the one before, for whoever looks at what was sent. Nothing else of it
        changes. Not for one whose details were dropped already (they stay dropped), and never an older
        copy in place of a newer one (`updated_at`, where both say it)."""
        if arrival.raw is None:
            return
        with self._lock:
            key = (arrival.source, arrival.ext_id)
            here = self._rows.get(key)
            if here is None or here.raw is None or here.raw == arrival.raw:
                return
            if _updated(arrival.raw) and _updated(here.raw) > _updated(arrival.raw):
                return
            self._rows[key] = replace(here, raw=arrival.raw)

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

    def account_of(self, restaurant: str) -> str | None:
        """The account whose orders carry this number of GloriaFood's for the restaurant (`restaurant_id`
        on every order): the account of the newest order written down with it. None when no order with
        that number was ever put to an account."""
        with self._lock:
            for row in reversed(self._rows.values()):
                if row.account and row.raw is not None and _restaurant(row.raw) == restaurant:
                    return row.account
        return None

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


def _restaurant(raw: Mapping[str, Any]) -> str:
    return restaurant_of(raw) or ""


def status_of(order: Mapping[str, Any]) -> str:
    """What an order says became of it at the restaurant, in the website's service's own word. One that
    says nothing was accepted: only accepted orders were handed over when the API was first written."""
    return str(order.get("status") or ACCEPTED)


def _ready(order: Mapping[str, Any]) -> bool:
    """Whether an order says it was marked ready in the website's own app."""
    return order.get("ready") is True


def _updated(order: Mapping[str, Any]) -> str:
    """When an order says it was last changed, as the website's service writes it
    ("2027-01-15T23:06:00.000Z": always UTC and of one shape, so the later one is the greater text); nothing
    for one that does not say."""
    value = order.get("updated_at")
    return value.strip() if isinstance(value, str) else ""


def restaurant_of(order: Mapping[str, Any]) -> str | None:
    """GloriaFood's own number for the restaurant an order was placed with, as text; None when the order
    has none."""
    value = order.get("restaurant_id")
    if isinstance(value, bool) or not isinstance(value, int | str) or not str(value).strip():
        return None
    return str(value).strip()


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
    account    TEXT NOT NULL DEFAULT '',
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
# The same for `account`, on a hub that wrote orders down before a restaurant could have several.
HAS_ACCOUNT = HAS_VIA.replace("'via'", "'account'")
ADD_ACCOUNT = "ALTER TABLE online_order ADD COLUMN IF NOT EXISTS account TEXT NOT NULL DEFAULT ''"

_COLUMNS = "source, ext_id, fetched_ms, raw, kind, state, order_id, said, tries, settled_ms, via, account"


def _prepare(conn: Any) -> None:
    """The table as this version writes it, on a database that can be written."""
    conn.execute(SCHEMA)
    if conn.execute(HAS_VIA).fetchone() is None:
        conn.execute(ADD_VIA)
    if conn.execute(HAS_ACCOUNT).fetchone() is None:
        conn.execute(ADD_ACCOUNT)


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
        account=row[11],
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
                    f"INSERT INTO online_order ({_COLUMNS}) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    # one that is here without an account learns it; whether the row is new is its xmax
                    "ON CONFLICT (source, ext_id) DO UPDATE SET account = EXCLUDED.account "
                    "WHERE online_order.account = '' AND EXCLUDED.account <> '' "
                    "RETURNING (xmax = 0)",
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
                        arrival.account,
                    ),
                )
                row = done.fetchone()
                return row is not None and bool(row[0])
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def again(self, arrival: Arrival) -> bool:
        from psycopg import errors
        from psycopg.types.json import Jsonb

        told = None if arrival.raw is None else status_of(arrival.raw)
        if arrival.raw is None or told is None or told == PENDING:
            return False
        updated = _updated(arrival.raw)
        try:
            with self._pool.connection() as conn:
                done = conn.execute(
                    "UPDATE online_order SET raw = %s, kind = %s, state = 'new', order_id = NULL, said = '', "
                    "tries = 0, settled_ms = NULL "
                    "WHERE source = %s AND ext_id = %s AND state = ANY(%s) AND raw IS NOT NULL "
                    # what it said of itself when it was written down, read as `status_of` and `_ready` read it
                    "AND (COALESCE(NULLIF(raw ->> 'status', ''), %s) <> %s "
                    "OR (state = 'new' AND COALESCE(raw -> 'ready' = 'true'::jsonb, false) <> %s)) "
                    # and never an older copy in place of a newer one, where both say when they were changed
                    "AND NOT (%s <> '' AND COALESCE(btrim(raw ->> 'updated_at'), '') > %s)",
                    (
                        Jsonb(arrival.raw),
                        arrival.kind,
                        arrival.source,
                        arrival.ext_id,
                        list(RETAKEN),
                        ACCEPTED,
                        told,
                        _ready(arrival.raw),
                        updated,
                        updated,
                    ),
                )
                return done.rowcount == 1
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def heard(self, arrival: Arrival) -> None:
        from psycopg import errors
        from psycopg.types.json import Jsonb

        if arrival.raw is None:
            return
        raw, updated = Jsonb(arrival.raw), _updated(arrival.raw)
        try:
            with self._pool.connection() as conn:
                conn.execute(
                    "UPDATE online_order SET raw = %s WHERE source = %s AND ext_id = %s AND raw IS NOT NULL "
                    "AND raw <> %s AND NOT (%s <> '' AND COALESCE(btrim(raw ->> 'updated_at'), '') > %s)",
                    (raw, arrival.source, arrival.ext_id, raw, updated, updated),
                )
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

    def account_of(self, restaurant: str) -> str | None:
        rows = self._read(
            "SELECT account FROM online_order WHERE account <> '' AND raw ->> 'restaurant_id' = %s "
            "ORDER BY seq DESC LIMIT 1",
            (restaurant,),
        )
        return rows[0][0] if rows else None

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
