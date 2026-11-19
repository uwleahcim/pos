"""A customer per phone number: who is calling, what they ordered before, and one line to remember them by.

Nothing about a customer is typed in for its own sake. The orders already carry the number and the name
(`phone`, `customer_name`), and the log's index finds a number's orders however old they are (`index(phone=)`),
so a customer's name, how often they ordered, since when and what they had are read from the order log, the
same on every hub and in the cloud. The one thing kept here is the note ("no MSG", "side door"): a line a
person typed about the customer, by the number's digits.

`customer_card` is what a screen shows when the phone rings or a number is typed; `same_again` is a past
order's dishes as the menu sells them now, for a new order to start from. This is the first slice of the
customer records the architecture plans for later: no points, no messages to customers. An address is not
kept either: where a customer's latest delivery went is read off that order, like their name. So is how far
that address is: what the map said when the fee was picked is on the order, and `saved_trip` hands it to
the customer's next delivery, so the map service is asked once per customer and address.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Callable, Sequence
from typing import Any, Protocol

from .maps import same_address
from .orders.delivery_fee import fee_of
from .sync.oplog import OrderEntry, OrderState, is_delivery, phone_digits

NOTE_MAX = 120
"""How long the note about a customer may be: one line on a phone."""
RECENT = 5
"""How many past orders a card lists, newest first."""
SHORTEST = 7
"""A number with fewer digits is no customer: an extension, a blocked caller ID, a typo."""
_LOOK_AT = 40  # how many of the newest orders are opened to find RECENT with dishes on them


def clean_note(note: object) -> str:
    """The note on one line, no longer than `NOTE_MAX`."""
    return " ".join(str(note or "").split())[:NOTE_MAX].rstrip()


class CustomerNotes:
    """The notes people typed about customers, by the number's digits. In memory: tests and a laptop. Every
    hub and the cloud use `PgCustomerNotes`."""

    def __init__(self) -> None:
        self._notes: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def get(self, phone: str) -> dict[str, Any] | None:
        with self._lock:
            kept = self._notes.get(phone)
            return dict(kept) if kept else None

    def put(self, phone: str, note: str, *, by: str, at_ms: int) -> dict[str, Any]:
        """Keeps `note` for the number (an empty one too: the note was taken off) with who wrote it and when."""
        kept = {"note": note, "by": by, "at_ms": at_ms}
        with self._lock:
            self._notes[phone] = kept
        return dict(kept)

    def all(self) -> dict[str, str]:
        """Every note there is, by the number's digits: what a list of the customers shows beside each."""
        with self._lock:
            return {phone: kept["note"] for phone, kept in self._notes.items() if kept["note"]}


SCHEMA = """
CREATE TABLE IF NOT EXISTS customer_note (
    phone      TEXT PRIMARY KEY,
    note       TEXT NOT NULL DEFAULT '',
    updated_by TEXT NOT NULL DEFAULT '',
    updated_ms BIGINT NOT NULL DEFAULT 0
);
"""


class ReadOnlyError(RuntimeError):
    """This database is a standby: the note is saved on the primary."""


class PgCustomerNotes(CustomerNotes):
    """The same calls, in PostgreSQL, so a note is there after a restart and on the hub that takes over."""

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

    def get(self, phone: str) -> dict[str, Any] | None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                row = conn.execute(
                    "SELECT note, updated_by, updated_ms FROM customer_note WHERE phone = %s", (phone,)
                ).fetchone()
        except errors.UndefinedTable:
            return None  # a standby whose primary has not been updated yet
        return None if row is None else {"note": row[0], "by": row[1], "at_ms": int(row[2])}

    def put(self, phone: str, note: str, *, by: str, at_ms: int) -> dict[str, Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                conn.execute(
                    """
                    INSERT INTO customer_note (phone, note, updated_by, updated_ms) VALUES (%s, %s, %s, %s)
                    ON CONFLICT (phone) DO UPDATE
                        SET note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_ms = EXCLUDED.updated_ms
                    """,
                    (phone, note, by, at_ms),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return {"note": note, "by": by, "at_ms": at_ms}

    def all(self) -> dict[str, str]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute("SELECT phone, note FROM customer_note WHERE note <> ''").fetchall()
        except errors.UndefinedTable:
            return {}  # a standby whose primary has not been updated yet
        return {str(phone): str(note) for phone, note in rows}


def default_notes() -> CustomerNotes:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgCustomerNotes(dsn) if dsn else CustomerNotes()


class _Store(Protocol):
    def index(self, *, phone: str | None = None) -> list[OrderEntry]: ...
    def views(self, entries: Sequence[OrderEntry]) -> list[OrderState]: ...


def _dishes(state: OrderState) -> list[dict[str, Any]]:
    return [{"qty": line.qty, "item": line.item} for line in state.ordered_lines() if line.active]


def customer_card(
    store: _Store, notes: CustomerNotes, phone: object, *, total: Callable[[OrderState], str]
) -> dict[str, Any]:
    """What is known of the customer at this number: the name on their latest order that has one, how many
    orders they placed (voided ones do not count), when the first and the latest were opened, the note, where
    their latest delivery went (`address`, with `address_note`, what was said for the driver that time; a
    catering order's note is about its event and is not handed back), and
    their latest `RECENT` orders that have dishes on them, each with what it came to (`total` works that out)
    and its dishes. `known` is false for a number with no order and no note, and for one too short to be a
    customer's. Read from the log's index: only the orders listed are replayed, and the store keeps those."""
    digits = phone_digits(phone)
    card: dict[str, Any] = {
        "phone": digits,
        "known": False,
        "name": "",
        "note": "",
        "orders": 0,
        "first_ms": None,
        "last_ms": None,
        "recent": [],
        # where their latest delivery went, and what was said for the driver then: what the form offers
        # the next time they want one brought
        "address": "",
        "address_note": "",
    }
    if len(digits) < SHORTEST:
        return card
    kept = notes.get(digits)
    if kept:
        card["note"] = kept["note"]
    entries = [e for e in store.index(phone=digits) if e.status != "void" and e.first_ms is not None]
    entries.sort(key=lambda e: (e.first_ms, e.order_id), reverse=True)
    if entries:
        card.update(orders=len(entries), first_ms=entries[-1].first_ms, last_ms=entries[0].first_ms)
    recent: list[dict[str, Any]] = []
    for state in store.views(entries[:_LOOK_AT]):
        if not card["name"]:
            card["name"] = str(state.fields.get("customer_name") or "").strip()
        if not card["address"] and is_delivery(state.fields):
            card["address"] = " ".join(str(state.fields.get("address") or "").split())
            # a catering order's note is about its event ("set up by 11:30"), not about the door
            if card["address"] and state.fields.get("channel") != "catering":
                card["address_note"] = " ".join(str(state.fields.get("event_note") or "").split())
        dishes = _dishes(state)
        if not dishes or len(recent) >= RECENT:
            continue
        recent.append(
            {
                "order_id": state.order_id,
                "opened_ms": state.first.wall_ms if state.first is not None else None,
                "order_no": state.fields.get("order_no"),
                "status": state.status,
                "channel": str(state.fields.get("channel") or ""),
                "total": total(state),
                "items": dishes,
            }
        )
    card["recent"] = recent
    card["known"] = bool(entries) or bool(card["note"])
    return card


def saved_trip(store: _Store, phone: object, address: str, mark: str) -> dict[str, Any] | None:
    """How far this customer's address is, as the map said it the last time a delivery of theirs went
    there: `{"miles", "minutes", "service", "from"}`, read off their newest delivery to that address that
    has the figures. None when there is none: another number, another address (the case and the spaces
    aside), figures measured from another address of the restaurant's (`mark` is today's,
    `pos.maps.origin_mark`), or an order that was voided. Like the card, it opens only the customer's own
    newest orders."""
    digits = phone_digits(phone)
    if len(digits) < SHORTEST or not address.strip():
        return None
    entries = [e for e in store.index(phone=digits) if e.status != "void" and e.first_ms is not None]
    entries.sort(key=lambda e: (e.first_ms, e.order_id), reverse=True)
    for state in store.views(entries[:_LOOK_AT]):
        if not is_delivery(state.fields) or not same_address(state.fields.get("address"), address):
            continue
        measured = (fee_of(state.fields) or {}).get("measured")
        if measured is not None and measured.get("from") == mark:
            return dict(measured)
    return None


_GONE = frozenset({"unknown_variant", "unknown_entry", "variant_not_offered", "inactive", "entry_mismatch"})
_CHOICE_GONE = frozenset({"option_hidden", "group_not_attached", "unknown_group", "unknown_component", "locked"})


def _why(problems: Sequence[dict[str, Any]]) -> str:
    """Why the menu will not sell a past dish today, in the words an operator tells the customer. The
    menu's own problems name ids (`CALROLL:roll is sold_out`): fine for a log, not for a screen."""
    first = problems[0] if problems else {}
    code = str(first.get("code") or "")
    if code in ("sold_out", "none_left"):
        if first.get("option_id"):
            return "One of its choices is sold out today."
        hidden = str(first.get("message") or "").endswith("hidden")
        return "It is off the menu today." if hidden else "It is sold out today."
    if code in _GONE:
        return "It is no longer on the menu."
    if code in _CHOICE_GONE:
        return "One of its choices is no longer offered."
    if code in ("too_few", "too_many", "max_qty"):
        return "Its choices have changed since."
    return "The menu does not sell it this way now."


def same_again(
    state: OrderState, price: Callable[[dict[str, Any]], tuple[dict[str, Any] | None, list[dict[str, Any]]]]
) -> dict[str, Any]:
    """A past order's dishes for a new order to start from: each with its choices as they were (`request`),
    priced by the menu as it sells today (`price` hands back the priced line, or the problems that stop the
    sale). `was` is what one cost then, so a screen can say a price moved. A dish the menu no longer sells that
    way (taken off, a choice gone, sold out now), and one that was typed in and never came from the menu, is
    under `missing` with why, and is not added: the operator rings it in by hand or tells the customer."""
    lines: list[dict[str, Any]] = []
    missing: list[dict[str, Any]] = []
    for line in state.ordered_lines():
        if not line.active:
            continue
        if not isinstance(line.request, dict):
            missing.append({"item": line.item, "qty": line.qty, "why": "It was typed in, not picked from the menu."})
            continue
        priced, problems = price(line.request)
        if priced is None:
            missing.append({"item": line.item, "qty": line.qty, "why": _why(problems)})
            continue
        lines.append(
            {
                "item": priced["name"],
                "qty": line.qty,
                "note": line.note,
                "request": line.request,
                "unit_price": priced["unit_price"],
                "was": (line.priced or {}).get("unit_price"),
            }
        )
    return {"order_id": state.order_id, "lines": lines, "missing": missing}
