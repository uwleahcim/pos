"""Tags on a guest: a few words a manager puts on a phone number, to pick guests out by (docs/guest-list.md).

"VIP", "Friend of the house", "Catering client": a tag is a short word or two, the same word on every guest
who carries it, so the guest list can show everybody who does. It is put on from the guest list by whoever
may read it (`guests` in the table of powers, `pos/identity/powers.py`), on a guest that is a phone number
(`pos.customers`), and kept by the number's digits with who put it on and when.

- There is no list of tags to keep up. The tags on offer are the ones some guest carries, and the few in
  `STANDARD`, which are offered before anybody carries them. A tag nobody carries any more is gone.
- A tag is spelt one way: "vip" typed where "VIP" is in use becomes "VIP" (`clean_tags`).
- A guest carries at most `TAGS_MOST`, each `TAG_MAX` letters at most, in the order of the alphabet.

A tag says something about a customer, as the note does, and the screens that take an order show both to
whoever takes it. So do the screens of the host stand: a reservation and a party on the waitlist are answered
with the tags their number carries (`with_tags`), and a call that rings asks for its number's
(`GET /customers/tags`). It stays on the hub: it is on no kitchen ticket and no bill, and nothing sends it
out.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

from .sync.oplog import phone_digits

TAG_MAX = 24
"""How long a tag may be: a button on a phone."""
TAGS_MOST = 6
"""How many tags one guest carries at most: more than a line of them says nothing at a glance."""
STANDARD = ("VIP", "Friend of the house")
"""The tags offered before any guest carries them."""


def clean_tags(tags: object, known: Iterable[str] = ()) -> list[str]:
    """A guest's tags as they may be kept: each on one line, the empty ones dropped, each once whatever its
    capitals, in the order of the alphabet. One that is `known` (in use, or standard) is spelt as it is
    known. Raises ValueError for something that is no list of words, a tag over `TAG_MAX` and more than
    `TAGS_MOST` of them."""
    if tags is None:
        return []
    if not isinstance(tags, list | tuple) or not all(isinstance(tag, str) for tag in tags):
        raise ValueError("the tags must be a list of words")
    spelt = {tag.casefold(): tag for tag in reversed([*known])}  # the first of two spellings stands
    kept: dict[str, str] = {}
    for tag in tags:
        words = " ".join(tag.split())
        if not words:
            continue
        if len(words) > TAG_MAX:
            raise ValueError(f"a tag is {TAG_MAX} letters at most")
        kept.setdefault(words.casefold(), spelt.get(words.casefold(), words))
    if len(kept) > TAGS_MOST:
        raise ValueError(f"a guest carries {TAGS_MOST} tags at most")
    return sorted(kept.values(), key=lambda tag: (tag.casefold(), tag))


def offered(carried: Mapping[str, Sequence[str]], listed: Iterable[str] | None = None) -> list[dict[str, Any]]:
    """Every tag there is to offer: the ones some number carries and the standard ones, each with how many
    `guests` of the `listed` numbers carry it (of every number, with none given). The one most guests carry
    first, then by the alphabet."""
    among = None if listed is None else set(listed)
    counts: dict[str, int] = {tag: 0 for tag in STANDARD}
    for phone, tags in carried.items():
        for tag in tags:
            counts[tag] = counts.get(tag, 0) + (1 if among is None or phone in among else 0)
    return [
        {"tag": tag, "guests": count}
        for tag, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0].casefold(), pair[0]))
    ]


def with_tags(rows: Iterable[Mapping[str, Any]], carried: Mapping[str, Sequence[str]]) -> list[dict[str, Any]]:
    """Each row with the `tags` its number carries: what a reservation or a party on the waitlist is
    answered with. The number is the row's `phone`, compared by its digits as a caller's is; a row with no
    number, or with one nobody tagged, carries none. `carried` is every tagged number (`GuestTags.all`),
    read once for the whole answer. Nothing is kept with the row: the tags are the number's, wherever it
    turns up."""
    return [{**row, "tags": list(carried.get(phone_digits(row.get("phone")), ()))} for row in rows]


class GuestTags:
    """The tags on each number, by its digits. In memory: tests and a laptop. Every hub and the cloud use
    `PgGuestTags`."""

    def __init__(self) -> None:
        self._tags: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def get(self, phone: str) -> dict[str, Any] | None:
        with self._lock:
            kept = self._tags.get(phone)
            return {**kept, "tags": list(kept["tags"])} if kept else None

    def put(self, phone: str, tags: Sequence[str], *, by: str, at_ms: int) -> dict[str, Any]:
        """Keeps these tags for the number (none too: they were taken off) with who said so and when."""
        kept = {"tags": list(tags), "by": by, "at_ms": at_ms}
        with self._lock:
            self._tags[phone] = kept
        return {**kept, "tags": list(tags)}

    def all(self) -> dict[str, list[str]]:
        """The tags of every number that carries one."""
        with self._lock:
            return {phone: list(kept["tags"]) for phone, kept in self._tags.items() if kept["tags"]}


SCHEMA = """
CREATE TABLE IF NOT EXISTS guest_tag (
    phone      TEXT PRIMARY KEY,
    tags       JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_by TEXT NOT NULL DEFAULT '',
    updated_ms BIGINT NOT NULL DEFAULT 0
);
"""


class ReadOnlyError(RuntimeError):
    """This database is a standby: the tags are saved on the primary."""


def _listed(value: object) -> list[str]:
    return [str(tag) for tag in value] if isinstance(value, list) else []


class PgGuestTags(GuestTags):
    """The same calls, in PostgreSQL, so the tags are there after a restart and on the hub that takes over."""

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
                    "SELECT tags, updated_by, updated_ms FROM guest_tag WHERE phone = %s", (phone,)
                ).fetchone()
        except errors.UndefinedTable:
            return None  # a standby whose primary has not been updated yet
        return None if row is None else {"tags": _listed(row[0]), "by": row[1], "at_ms": int(row[2])}

    def put(self, phone: str, tags: Sequence[str], *, by: str, at_ms: int) -> dict[str, Any]:
        from psycopg import errors
        from psycopg.types.json import Jsonb

        try:
            with self._pool.connection() as conn:
                conn.execute(
                    """
                    INSERT INTO guest_tag (phone, tags, updated_by, updated_ms) VALUES (%s, %s, %s, %s)
                    ON CONFLICT (phone) DO UPDATE
                        SET tags = EXCLUDED.tags, updated_by = EXCLUDED.updated_by, updated_ms = EXCLUDED.updated_ms
                    """,
                    (phone, Jsonb(list(tags)), by, at_ms),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return {"tags": list(tags), "by": by, "at_ms": at_ms}

    def all(self) -> dict[str, list[str]]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute("SELECT phone, tags FROM guest_tag WHERE tags <> '[]'::jsonb").fetchall()
        except errors.UndefinedTable:
            return {}  # a standby whose primary has not been updated yet
        return {str(phone): _listed(tags) for phone, tags in rows}


def default_guest_tags() -> GuestTags:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgGuestTags(dsn) if dsn else GuestTags()
