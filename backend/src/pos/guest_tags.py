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

A number can be tagged before it ever ordered, from its reservation or its line of the waitlist. The guest
list shows such a number too, and has no order to read a name from, so the name it was tagged by is kept
with its tags (`put(..., name=)`, `rename`, `names`): one line of `NAME_MAX` letters at most, for as long as
the number carries a tag. Taking every tag off drops the name with them. It is shown in the guest list and
nowhere else; a number that ordered is called what its order calls it.
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
NAME_MAX = 40
"""How long the name kept with a number's tags may be: a line of the guest list."""


def clean_name(name: object) -> str:
    """The name a number was tagged by, as it may be kept: on one line, what cannot be printed taken out,
    cut to `NAME_MAX`. Nothing that is no words is no name."""
    if not isinstance(name, str):
        return ""
    return " ".join("".join(ch if ch.isprintable() else " " for ch in name).split())[:NAME_MAX].rstrip()


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


def tags_together(phones: Iterable[object], carried: Mapping[str, Sequence[str]]) -> list[str]:
    """The tags these numbers carry between them, each once whatever its capitals, in the order of the
    alphabet: what the check of a table says of the guests who were seated at it. The numbers are compared
    by their digits; one that is no number, or that nobody tagged, adds none. `carried` is every tagged
    number (`GuestTags.all`)."""
    kept: dict[str, str] = {}
    for phone in phones:
        for tag in carried.get(phone_digits(phone), ()):
            kept.setdefault(tag.casefold(), tag)
    return sorted(kept.values(), key=lambda tag: (tag.casefold(), tag))


class GuestTags:
    """The tags on each number, by its digits. In memory: tests and a laptop. Every hub and the cloud use
    `PgGuestTags`."""

    def __init__(self) -> None:
        self._tags: dict[str, dict[str, Any]] = {}
        self._names: dict[str, str] = {}
        self._lock = threading.Lock()

    def get(self, phone: str) -> dict[str, Any] | None:
        with self._lock:
            kept = self._tags.get(phone)
            return {**kept, "tags": list(kept["tags"])} if kept else None

    def put(self, phone: str, tags: Sequence[str], *, by: str, at_ms: int, name: str | None = None) -> dict[str, Any]:
        """Keeps these tags for the number (none too: they were taken off) with who said so and when.
        `name` is what the number was called where it was tagged (its reservation, its party): it is kept
        with the tags, and with no name said the one it had stays. A number left with no tag keeps no name."""
        kept = {"tags": list(tags), "by": by, "at_ms": at_ms}
        said = clean_name(name)
        with self._lock:
            self._tags[phone] = kept
            if not kept["tags"]:
                self._names.pop(phone, None)
            elif said:
                self._names[phone] = said
        return {**kept, "tags": list(tags)}

    def rename(self, phone: str, name: str | None) -> None:
        """Keeps the name alone, for a number that carries a tag: who put its tags on, and when, stay. An
        empty name is no name said, and a number with no tag keeps none."""
        said = clean_name(name)
        with self._lock:
            if said and (self._tags.get(phone) or {}).get("tags"):
                self._names[phone] = said

    def all(self) -> dict[str, list[str]]:
        """The tags of every number that carries one."""
        with self._lock:
            return {phone: list(kept["tags"]) for phone, kept in self._tags.items() if kept["tags"]}

    def names(self) -> dict[str, str]:
        """The name kept with the tags of each number that carries one and was tagged by a name."""
        with self._lock:
            return dict(self._names)


SCHEMA = """
CREATE TABLE IF NOT EXISTS guest_tag (
    phone      TEXT PRIMARY KEY,
    tags       JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_by TEXT NOT NULL DEFAULT '',
    updated_ms BIGINT NOT NULL DEFAULT 0
);
ALTER TABLE guest_tag ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '';
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

    def _write(self, sql: str, args: Sequence[Any]) -> None:
        """One write. A table that has no `name` yet (this hub took over from one that ran before the name
        was kept, and has not been restarted since) is given the column, and the write is made again."""
        from psycopg import errors

        try:
            try:
                with self._pool.connection() as conn:
                    conn.execute(sql, args)
            except errors.UndefinedColumn:
                with self._pool.connection() as conn:
                    conn.execute(SCHEMA)
                    conn.execute(sql, args)
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def put(self, phone: str, tags: Sequence[str], *, by: str, at_ms: int, name: str | None = None) -> dict[str, Any]:
        from psycopg.types.json import Jsonb

        said = clean_name(name) if tags else ""
        self._write(
            """
            INSERT INTO guest_tag (phone, tags, updated_by, updated_ms, name) VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (phone) DO UPDATE
                SET tags = EXCLUDED.tags, updated_by = EXCLUDED.updated_by, updated_ms = EXCLUDED.updated_ms,
                    name = CASE WHEN %s THEN guest_tag.name ELSE EXCLUDED.name END
            """,
            # with tags and no name said, the name the number had stays
            (phone, Jsonb(list(tags)), by, at_ms, said, bool(tags) and not said),
        )
        return {"tags": list(tags), "by": by, "at_ms": at_ms}

    def rename(self, phone: str, name: str | None) -> None:
        said = clean_name(name)
        if said:
            self._write("UPDATE guest_tag SET name = %s WHERE phone = %s AND tags <> '[]'::jsonb", (said, phone))

    def all(self) -> dict[str, list[str]]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute("SELECT phone, tags FROM guest_tag WHERE tags <> '[]'::jsonb").fetchall()
        except errors.UndefinedTable:
            return {}  # a standby whose primary has not been updated yet
        return {str(phone): _listed(tags) for phone, tags in rows}

    def names(self) -> dict[str, str]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                rows = conn.execute(
                    "SELECT phone, name FROM guest_tag WHERE tags <> '[]'::jsonb AND name <> ''"
                ).fetchall()
        except (errors.UndefinedTable, errors.UndefinedColumn):
            return {}  # a standby whose primary has not been updated yet
        return {str(phone): str(name) for phone, name in rows}


def default_guest_tags() -> GuestTags:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgGuestTags(dsn) if dsn else GuestTags()
