"""Conversations by text: what customers text the restaurant, and what it texts them (docs/text-inbox.md).

Until now the POS only sent texts (`pos.messaging`: ready, on its way, a new time) and kept nothing of them.
A customer who answered one answered Twilio, and nobody read it. This module is the other half: every text
to and from the restaurant's Twilio number is kept here, by the customer's number, so the staff can read
what a customer wrote, answer, and start a conversation, and take an order or a booking that way.

- **A text** (`Text`) is one message, in or out, with what became of it. The POS's own texts to an order are
  kept too, so an answer to "order #42 is ready" is read under the text it answers.
- **A conversation** (`Thread`) is everything with one number: the name the orders know that number by,
  how many of the customer's texts nobody has opened yet, and whether they answered STOP.

Where the texts come from: `pos.twilio` sends them and asks Twilio for the new ones (`Listener`); what
Twilio says of a text is handed to `Texts.take`, however it was heard, so a text is never here twice. Where
Twilio can reach the hub (`pos.online.twilio_way`) it also calls the moment a text comes or changes, and the
hub asks for that one text at once (`Listener.hear`) instead of finding it at its next asking.

**Pictures the staff send** are kept on the hub with the text (`compose`), and Twilio fetches them from the
hub when the text goes out. They are kept as long as the pictures somebody looked at; Twilio has them after
that, like a customer's.

**STOP.** A customer who answers STOP (or one of the phone companies' other words for it) is sent nothing
more by Twilio until they text START. The conversation says so, and `compose` refuses to write to them: a
text Twilio would throw away is not shown as sent.

**The first text to a number** that never texted the restaurant, and was never texted by it, says who it
is from and how to make it stop (`wrap`): the phone companies ask that of a business, and filter the texts
that leave it out.

Kept in memory or in PostgreSQL, like the notes: a second hub has the conversations, the cloud does not.
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
import traceback
import uuid
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any, Protocol

from .sync.oplog import phone_digits

log = logging.getLogger(__name__)

BODY_MAX = 1600
"""The most letters of one text: Twilio takes no more, and cuts it into several for the phone company."""
PAGE = 100
"""The texts of a conversation one reading answers, the newest; the next reading asks for the ones before."""
THREADS = 100
"""The conversations a list answers, the ones with the newest texts."""
NAME_MAX = 80
MEDIA_MOST = 10
"""The most pictures of one text that are listed: a phone sends no more."""
PICTURE_MAX = 10 * 1024 * 1024
"""The biggest picture the hub fetches and hands a screen, in bytes."""
PICTURES_KEPT_MS = 30 * 24 * 3600 * 1000
"""How long a picture somebody looked at is kept on the hub. Twilio has them all: an older one is fetched
again when somebody looks."""

SEND_MOST = 5
"""The most pictures one text of the staff's carries."""
SEND_BYTES = 4_500_000
"""The most the pictures of one text may weigh together, in bytes: Twilio takes five million of a whole text."""
OWN = "out:"
"""What the pictures the staff sent are kept under, before the text's id: a customer's are kept under
Twilio's name for their text."""
HEARD_A_MINUTE = 120
"""The most calls of Twilio's in a minute that the hub asks Twilio about at once. More than that wait for
the next asking, a few seconds on: nobody gets the hub to ask without end."""

RECEIVED, WAITING, SENT, DELIVERED, READ, FAILED = "received", "waiting", "sent", "delivered", "read", "failed"
_RANK = {WAITING: 0, SENT: 1, DELIVERED: 2, READ: 3}
ELSEWHERE = "elsewhere"
"""The kind of a text the restaurant's number sent that the POS did not: from Twilio's console, another
program, or Twilio's own answer to STOP and HELP."""
STAFF = ""
"""The kind of a text a person typed at a terminal. The POS's own texts carry theirs (`ready`, `out`,
`delayed`: `pos.messaging`)."""

STOP_WORDS = frozenset({"stop", "stopall", "unsubscribe", "cancel", "end", "quit", "revoke", "optout"})
START_WORDS = frozenset({"start", "yes", "unstop"})
"""What the phone companies take as "send me no more" and "send me texts again", whatever the case. Twilio
acts on them by itself; the hub reads them to say so on the conversation."""
OPTED_OUT = 21610
"""Twilio's error number for a text to somebody who answered STOP."""

_TWILIO_STATE = {
    "accepted": SENT,
    "scheduled": SENT,
    "queued": SENT,
    "sending": SENT,
    "sent": SENT,
    "delivered": DELIVERED,
    "partially_delivered": DELIVERED,
    "read": READ,
    "undelivered": FAILED,
    "failed": FAILED,
    "canceled": FAILED,
    "receiving": RECEIVED,
    "received": RECEIVED,
}
"""Twilio's words for where a text stands, as the POS says them."""
_CHANNELS = ("rcs",)
"""The ways besides a plain text that an address of Twilio's can name (`rcs:+17815550142`) and the POS reads."""
_TEXT_ID = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


class Refused(Exception):
    """Something asked of the conversations that they do not do, with a word for the code and a sentence for
    the person."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReadOnlyError(RuntimeError):
    """The database is a standby: nothing can be written here until it is promoted."""


def number_of(raw: object) -> str | None:
    """A customer's number the way the conversations are kept by (+17815550142), from what a screen typed, an
    order carries or Twilio names (`rcs:+17815550142`). None for what is no number a text can go to: ten
    digits are a number of this country's, eleven that begin with 1 the same, and one written with a + is
    taken as it is."""
    text = str(raw or "").strip()
    for channel in _CHANNELS:
        text = text.removeprefix(f"{channel}:")
    if ":" in text:
        return None  # another channel's address (`whatsapp:`, `messenger:`): not one the POS reads
    digits = re.sub(r"\D", "", text)
    if text.startswith("+"):
        return f"+{digits}" if 8 <= len(digits) <= 15 else None
    if len(digits) == 10 and digits[0] not in "01":
        return f"+1{digits}"
    if len(digits) == 11 and digits[0] == "1" and digits[1] not in "01":
        return f"+{digits}"
    return None


def channel_of(*addresses: object, pictures: int = 0) -> str:
    """How a text travelled: `rcs` where Twilio's addresses say so, `mms` with a picture, else `sms`."""
    for address in addresses:
        for channel in _CHANNELS:
            if str(address or "").startswith(f"{channel}:"):
                return channel
    return "mms" if pictures else "sms"


def clean_body(value: object) -> str:
    """What somebody typed as a text: its lines kept, the blank ends and what cannot be printed taken off."""
    if not isinstance(value, str):
        return ""
    lines = value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    tidy = "\n".join("".join(ch if ch.isprintable() else " " for ch in line).rstrip() for line in lines)
    return re.sub(r"\n{3,}", "\n\n", tidy).strip()


def picture_kind(data: bytes) -> str | None:
    """What a picture is, by how it begins: one of the three kinds a text carries to any phone (JPEG, PNG,
    GIF). None for anything else, whatever it is called."""
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    return None


def clean_name(value: object) -> str:
    return " ".join(str(value or "").split())[:NAME_MAX]


@dataclass(frozen=True)
class Picture:
    """One picture (or sound, or card) a text carries: Twilio's name for it and what it says it is."""

    sid: str
    """Twilio's name for it; empty for a picture the staff sent, which the hub keeps itself (`OWN`)."""
    type: str = ""

    def as_json(self, n: int) -> dict[str, Any]:
        return {"n": n, "type": self.type, "image": self.type.startswith("image/")}


@dataclass(frozen=True)
class Text:
    """One text, in or out. `phone` is the customer's number whichever way it went. `at_ms` is when it was
    sent or came, on the wall clock; `seq` the order the hub wrote them down in (what "unread" counts by)."""

    text_id: str
    phone: str
    inbound: bool
    body: str
    at_ms: int
    state: str
    sid: str = ""
    channel: str = "sms"
    pictures: tuple[Picture, ...] = ()
    pictures_n: int = 0
    """How many pictures Twilio says it carries; `pictures` lists the ones the hub has learned of."""
    code: int | None = None
    said: str = ""
    kind: str = STAFF
    order_id: str = ""
    by_id: str = ""
    by_name: str = ""
    device: str = ""
    seq: int = 0

    def as_json(self) -> dict[str, Any]:
        return {
            "id": self.text_id,
            "phone": self.phone,
            "inbound": self.inbound,
            "body": self.body,
            "at_ms": self.at_ms,
            "state": self.state,
            "channel": self.channel,
            "pictures": [picture.as_json(n) for n, picture in enumerate(self.pictures)],
            "pictures_n": self.pictures_n,
            "code": self.code,
            "said": self.said,
            "kind": self.kind,
            "order_id": self.order_id,
            "by": self.by_name,
        }


@dataclass(frozen=True)
class Thread:
    """Everything with one number, as a list shows it: its newest text, how many of the customer's nobody
    has opened (`unread`), and since when they want no more (`stopped_ms`)."""

    phone: str
    name: str = ""
    read_seq: int = 0
    read_by: str = ""
    stopped_ms: int | None = None
    last: Text | None = None
    unread: int = 0

    def as_json(self) -> dict[str, Any]:
        last = self.last
        return {
            "phone": self.phone,
            "digits": phone_digits(self.phone),
            "name": self.name,
            "unread": self.unread,
            "read_by": self.read_by,
            "stopped_ms": self.stopped_ms,
            "last": None
            if last is None
            else {
                "body": last.body,
                "at_ms": last.at_ms,
                "inbound": last.inbound,
                "state": last.state,
                "pictures_n": last.pictures_n,
                "kind": last.kind,
            },
        }


def _matches(thread: Thread, texts: Sequence[Text], words: Sequence[str]) -> bool:
    """Whether a conversation holds every word that is looked for: in its name, its number or its texts."""
    if not words:
        return True
    digits = phone_digits(thread.phone)
    for word in words:
        number = re.sub(r"\D", "", word)
        if word in thread.name.lower():
            continue
        if number and len(number) >= 3 and number in digits:
            continue
        if any(word in text.body.lower() for text in texts):
            continue
        return False
    return True


def _search_words(q: str) -> list[str]:
    return [word for word in q.lower().split() if word][:6]


class TextStore:
    """The texts and the conversations, in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._texts: dict[str, Text] = {}
        self._by_sid: dict[str, str] = {}
        self._threads: dict[str, Thread] = {}
        self._pictures: dict[tuple[str, int], tuple[str, bytes, int]] = {}
        self._seq = 0
        self._lock = threading.RLock()

    def writable(self) -> bool:
        return True

    # -- texts

    def add(self, text: Text, *, name: str = "") -> Text | None:
        """Writes a text down, and its conversation where it is the number's first. None where a text with
        its id, or with Twilio's name for it, is here already."""
        with self._lock:
            if text.text_id in self._texts or (text.sid and text.sid in self._by_sid):
                return None
            self._seq += 1
            kept = replace(text, seq=self._seq)
            self._texts[kept.text_id] = kept
            if kept.sid:
                self._by_sid[kept.sid] = kept.text_id
            thread = self._threads.get(kept.phone)
            if thread is None:
                self._threads[kept.phone] = Thread(kept.phone, name=name)
            elif name and name != thread.name:
                self._threads[kept.phone] = replace(thread, name=name)
            return kept

    def get(self, text_id: str) -> Text | None:
        with self._lock:
            return self._texts.get(text_id)

    def by_sid(self, sid: str) -> Text | None:
        with self._lock:
            text_id = self._by_sid.get(sid)
            return self._texts.get(text_id) if text_id else None

    def unsent(self, phone: str, body: str, since_ms: int) -> Text | None:
        """The oldest text to this number with these words that Twilio has not named yet (they are sent in
        the order they were written): the one a text found at Twilio is, when the hub sent it and has not
        heard Twilio's answer."""
        with self._lock:
            found = [
                t
                for t in self._texts.values()
                if not t.inbound
                and not t.sid
                and t.state != FAILED
                and t.phone == phone
                and t.body == body
                and t.at_ms >= since_ms
            ]
        return min(found, key=lambda t: t.seq) if found else None

    def change(self, text_id: str, **fields: Any) -> Text | None:
        """Writes what changed of a text. Twilio's name for it is given once."""
        with self._lock:
            old = self._texts.get(text_id)
            if old is None:
                return None
            new = replace(old, **fields)
            self._texts[text_id] = new
            if old.sid and old.sid != new.sid and self._by_sid.get(old.sid) == text_id:
                del self._by_sid[old.sid]
            if new.sid:
                self._by_sid[new.sid] = text_id
            return new

    def drop(self, text_id: str) -> None:
        """Takes a text out: one that turned out to be another that is here already."""
        with self._lock:
            old = self._texts.pop(text_id, None)
            if old is not None and old.sid and self._by_sid.get(old.sid) == text_id:
                del self._by_sid[old.sid]

    def texts(self, phone: str, *, before_ms: int | None = None, limit: int = PAGE) -> list[Text]:
        """A conversation's texts, the oldest first: the newest `limit` of them, or of those before
        `before_ms`."""
        with self._lock:
            found = [t for t in self._texts.values() if t.phone == phone and (before_ms is None or t.at_ms < before_ms)]
        found.sort(key=lambda t: (t.at_ms, t.seq))
        return found[-limit:]

    def newest_ms(self) -> int | None:
        """When the newest text the hub knows of was sent: from where Twilio is asked after a restart."""
        with self._lock:
            return max((t.at_ms for t in self._texts.values()), default=None)

    # -- conversations

    def _thread(self, thread: Thread) -> Thread:
        texts = [t for t in self._texts.values() if t.phone == thread.phone]
        last = max(texts, key=lambda t: (t.at_ms, t.seq), default=None)
        unread = sum(1 for t in texts if t.inbound and t.seq > thread.read_seq)
        return replace(thread, last=last, unread=unread)

    def thread(self, phone: str) -> Thread | None:
        with self._lock:
            thread = self._threads.get(phone)
            return None if thread is None else self._thread(thread)

    def threads(self, *, q: str = "", limit: int = THREADS) -> list[Thread]:
        """The conversations, the one with the newest text first; with `q`, those that hold every word of it
        in the name, the number or a text."""
        words = _search_words(q)
        with self._lock:
            found = [self._thread(thread) for thread in self._threads.values()]
            if words:
                found = [
                    t for t in found if _matches(t, [x for x in self._texts.values() if x.phone == t.phone], words)
                ]
        found = [t for t in found if t.last is not None]
        found.sort(key=lambda t: (t.last.at_ms, t.last.seq) if t.last else (0, 0), reverse=True)
        return found[:limit]

    def unread(self) -> int:
        """How many conversations hold a text of the customer's that nobody has opened."""
        with self._lock:
            return sum(1 for thread in self._threads.values() if self._thread(thread).unread)

    def set_thread(self, phone: str, **fields: Any) -> Thread | None:
        """Writes what changed of a conversation: its name, how far it was read and by whom, STOP."""
        with self._lock:
            thread = self._threads.get(phone)
            if thread is None:
                return None
            self._threads[phone] = replace(thread, **fields)
            return self._thread(self._threads[phone])

    def top_seq(self, phone: str) -> int:
        with self._lock:
            return max((t.seq for t in self._texts.values() if t.phone == phone), default=0)

    # -- pictures somebody looked at

    def picture(self, sid: str, n: int) -> tuple[str, bytes] | None:
        with self._lock:
            kept = self._pictures.get((sid, n))
            return None if kept is None else (kept[0], kept[1])

    def keep_picture(self, sid: str, n: int, kind: str, data: bytes, at_ms: int) -> None:
        with self._lock:
            self._pictures[(sid, n)] = (kind, data, at_ms)

    def drop_pictures(self, before_ms: int) -> None:
        with self._lock:
            for key in [key for key, kept in self._pictures.items() if kept[2] < before_ms]:
                del self._pictures[key]


SCHEMA = """
CREATE TABLE IF NOT EXISTS text_message (
    seq        BIGSERIAL PRIMARY KEY,
    text_id    TEXT NOT NULL UNIQUE,
    sid        TEXT UNIQUE,
    phone      TEXT NOT NULL,
    inbound    BOOLEAN NOT NULL,
    body       TEXT NOT NULL DEFAULT '',
    at_ms      BIGINT NOT NULL,
    state      TEXT NOT NULL,
    channel    TEXT NOT NULL DEFAULT 'sms',
    pictures   JSONB NOT NULL DEFAULT '[]',
    pictures_n INT NOT NULL DEFAULT 0,
    code       INT,
    said       TEXT NOT NULL DEFAULT '',
    kind       TEXT NOT NULL DEFAULT '',
    order_id   TEXT NOT NULL DEFAULT '',
    by_id      TEXT NOT NULL DEFAULT '',
    by_name    TEXT NOT NULL DEFAULT '',
    device     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS text_message_phone ON text_message (phone, at_ms);
CREATE TABLE IF NOT EXISTS text_thread (
    phone      TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT '',
    read_seq   BIGINT NOT NULL DEFAULT 0,
    read_by    TEXT NOT NULL DEFAULT '',
    stopped_ms BIGINT
);
CREATE TABLE IF NOT EXISTS text_picture (
    sid   TEXT NOT NULL,
    n     INT NOT NULL,
    kind  TEXT NOT NULL DEFAULT '',
    data  BYTEA NOT NULL,
    at_ms BIGINT NOT NULL,
    PRIMARY KEY (sid, n)
);
"""

_TEXT = (
    "text_id, phone, inbound, body, at_ms, state, sid, channel, pictures, pictures_n, code, said, kind, "
    "order_id, by_id, by_name, device, seq"
)
_CHANGED = frozenset({"state", "sid", "channel", "pictures", "pictures_n", "code", "said", "at_ms"})
_THREAD_CHANGED = frozenset({"name", "read_seq", "read_by", "stopped_ms"})


def _pictures_of(value: Any) -> tuple[Picture, ...]:
    if not isinstance(value, list):
        return ()
    return tuple(
        Picture(str(row.get("sid") or ""), str(row.get("type") or "")) for row in value if isinstance(row, Mapping)
    )


def _text_of(row: Sequence[Any]) -> Text:
    return Text(
        text_id=row[0],
        phone=row[1],
        inbound=bool(row[2]),
        body=row[3],
        at_ms=int(row[4]),
        state=row[5],
        sid=row[6] or "",
        channel=row[7],
        pictures=_pictures_of(row[8]),
        pictures_n=int(row[9]),
        code=None if row[10] is None else int(row[10]),
        said=row[11],
        kind=row[12],
        order_id=row[13],
        by_id=row[14],
        by_name=row[15],
        device=row[16],
        seq=int(row[17]),
    )


def _like(word: str) -> str:
    """A word as a pattern that finds it anywhere, its own `%` and `_` meaning themselves."""
    return "%" + word.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


class PgTextStore(TextStore):
    """The same calls, in PostgreSQL, so the conversations are there after a restart and on the hub that
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

    def writable(self) -> bool:
        try:
            with self._pool.connection() as conn:
                row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
                if row is None or row[0]:
                    return False  # a standby: the hub that has the database asks Twilio
                conn.execute(SCHEMA)  # a standby that was promoted since this one started
                return True
        except Exception:  # noqa: BLE001 - whatever is wrong with the database, nothing can be written
            return False

    def _write(self, sql: str, args: Sequence[Any]) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                done = conn.execute(sql, args)
                return done.fetchall() if done.description is not None else []
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def _read(self, sql: str, args: Sequence[Any] = ()) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                return conn.execute(sql, args).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet

    # -- texts

    def add(self, text: Text, *, name: str = "") -> Text | None:
        from psycopg import errors
        from psycopg.types.json import Jsonb

        pictures = Jsonb([{"sid": p.sid, "type": p.type} for p in text.pictures])
        try:
            with self._pool.connection() as conn:
                row = conn.execute(
                    "INSERT INTO text_message (text_id, phone, inbound, body, at_ms, state, sid, channel, pictures, "
                    "pictures_n, code, said, kind, order_id, by_id, by_name, device) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    "ON CONFLICT DO NOTHING RETURNING seq",
                    (
                        text.text_id,
                        text.phone,
                        text.inbound,
                        text.body,
                        text.at_ms,
                        text.state,
                        text.sid or None,
                        text.channel,
                        pictures,
                        text.pictures_n,
                        text.code,
                        text.said,
                        text.kind,
                        text.order_id,
                        text.by_id,
                        text.by_name,
                        text.device,
                    ),
                ).fetchone()
                if row is None:
                    return None
                conn.execute(
                    "INSERT INTO text_thread (phone, name) VALUES (%s, %s) ON CONFLICT (phone) DO UPDATE "
                    "SET name = EXCLUDED.name WHERE EXCLUDED.name <> ''",
                    (text.phone, name),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return replace(text, seq=int(row[0]))

    def get(self, text_id: str) -> Text | None:
        rows = self._read(f"SELECT {_TEXT} FROM text_message WHERE text_id = %s", (text_id,))
        return _text_of(rows[0]) if rows else None

    def by_sid(self, sid: str) -> Text | None:
        rows = self._read(f"SELECT {_TEXT} FROM text_message WHERE sid = %s", (sid,))
        return _text_of(rows[0]) if rows else None

    def unsent(self, phone: str, body: str, since_ms: int) -> Text | None:
        rows = self._read(
            f"SELECT {_TEXT} FROM text_message WHERE phone = %s AND NOT inbound AND sid IS NULL AND body = %s "
            "AND state <> %s AND at_ms >= %s ORDER BY seq LIMIT 1",
            (phone, body, FAILED, since_ms),
        )
        return _text_of(rows[0]) if rows else None

    def change(self, text_id: str, **fields: Any) -> Text | None:
        from psycopg.types.json import Jsonb

        unknown = set(fields) - _CHANGED
        if unknown:
            raise ValueError(f"not something of a text that changes: {sorted(unknown)}")
        if not fields:
            return self.get(text_id)
        values: list[Any] = []
        for name, value in fields.items():
            if name == "pictures":
                value = Jsonb([{"sid": p.sid, "type": p.type} for p in value])
            elif name == "sid":
                value = value or None
            values.append(value)
        sets = ", ".join(f"{name} = %s" for name in fields)  # the names are this module's own (`_CHANGED`)
        rows = self._write(f"UPDATE text_message SET {sets} WHERE text_id = %s RETURNING {_TEXT}", (*values, text_id))
        return _text_of(rows[0]) if rows else None

    def drop(self, text_id: str) -> None:
        self._write("DELETE FROM text_message WHERE text_id = %s", (text_id,))

    def texts(self, phone: str, *, before_ms: int | None = None, limit: int = PAGE) -> list[Text]:
        rows = self._read(
            f"SELECT {_TEXT} FROM text_message WHERE phone = %s AND (%s::bigint IS NULL OR at_ms < %s) "
            "ORDER BY at_ms DESC, seq DESC LIMIT %s",
            (phone, before_ms, before_ms, limit),
        )
        return [_text_of(row) for row in reversed(rows)]

    def newest_ms(self) -> int | None:
        rows = self._read("SELECT max(at_ms) FROM text_message")
        return int(rows[0][0]) if rows and rows[0][0] is not None else None

    # -- conversations

    _THREADS = (
        "SELECT t.phone, t.name, t.read_seq, t.read_by, t.stopped_ms, "
        "(SELECT count(*) FROM text_message u WHERE u.phone = t.phone AND u.inbound AND u.seq > t.read_seq), "
        + ", ".join(f"l.{name.strip()}" for name in _TEXT.split(","))
        + " FROM text_thread t JOIN LATERAL (SELECT * FROM text_message m WHERE m.phone = t.phone "
        "ORDER BY m.at_ms DESC, m.seq DESC LIMIT 1) l ON TRUE"
    )

    @staticmethod
    def _thread_of(row: Sequence[Any]) -> Thread:
        return Thread(
            phone=row[0],
            name=row[1],
            read_seq=int(row[2]),
            read_by=row[3],
            stopped_ms=None if row[4] is None else int(row[4]),
            unread=int(row[5]),
            last=_text_of(row[6:]),
        )

    def thread(self, phone: str) -> Thread | None:
        rows = self._read(f"{self._THREADS} WHERE t.phone = %s", (phone,))
        if rows:
            return self._thread_of(rows[0])
        bare = self._read(
            "SELECT phone, name, read_seq, read_by, stopped_ms FROM text_thread WHERE phone = %s", (phone,)
        )
        if not bare:
            return None
        row = bare[0]
        return Thread(row[0], row[1], int(row[2]), row[3], None if row[4] is None else int(row[4]))

    def threads(self, *, q: str = "", limit: int = THREADS) -> list[Thread]:
        where: list[str] = []
        args: list[Any] = []
        for word in _search_words(q):
            number = re.sub(r"\D", "", word)
            parts = [
                "t.name ILIKE %s",
                "EXISTS (SELECT 1 FROM text_message b WHERE b.phone = t.phone AND b.body ILIKE %s)",
            ]
            args += [_like(word), _like(word)]
            if len(number) >= 3:
                parts.append("t.phone LIKE %s")
                args.append(_like(number))
            where.append("(" + " OR ".join(parts) + ")")
        sql = self._THREADS + (" WHERE " + " AND ".join(where) if where else "")
        rows = self._read(f"{sql} ORDER BY l.at_ms DESC, l.seq DESC LIMIT %s", (*args, limit))
        return [self._thread_of(row) for row in rows]

    def unread(self) -> int:
        rows = self._read(
            "SELECT count(*) FROM text_thread t WHERE EXISTS "
            "(SELECT 1 FROM text_message u WHERE u.phone = t.phone AND u.inbound AND u.seq > t.read_seq)"
        )
        return int(rows[0][0]) if rows else 0

    def set_thread(self, phone: str, **fields: Any) -> Thread | None:
        unknown = set(fields) - _THREAD_CHANGED
        if unknown:
            raise ValueError(f"not something of a conversation that changes: {sorted(unknown)}")
        if fields:
            sets = ", ".join(f"{name} = %s" for name in fields)  # this module's own names (`_THREAD_CHANGED`)
            self._write(f"UPDATE text_thread SET {sets} WHERE phone = %s", (*fields.values(), phone))
        return self.thread(phone)

    def top_seq(self, phone: str) -> int:
        rows = self._read("SELECT max(seq) FROM text_message WHERE phone = %s", (phone,))
        return int(rows[0][0]) if rows and rows[0][0] is not None else 0

    # -- pictures somebody looked at

    def picture(self, sid: str, n: int) -> tuple[str, bytes] | None:
        rows = self._read("SELECT kind, data FROM text_picture WHERE sid = %s AND n = %s", (sid, n))
        return (rows[0][0], bytes(rows[0][1])) if rows else None

    def keep_picture(self, sid: str, n: int, kind: str, data: bytes, at_ms: int) -> None:
        self._write(
            "INSERT INTO text_picture (sid, n, kind, data, at_ms) VALUES (%s, %s, %s, %s, %s) "
            "ON CONFLICT (sid, n) DO NOTHING",
            (sid, n, kind, data, at_ms),
        )

    def drop_pictures(self, before_ms: int) -> None:
        self._write("DELETE FROM text_picture WHERE at_ms < %s", (before_ms,))


def default_text_store() -> TextStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgTextStore(dsn) if dsn else TextStore()


def _when(told: Mapping[str, Any], now_ms: int) -> int:
    """When Twilio says a text was sent or came, as wall-clock ms; now where it does not say."""
    for name in ("date_sent", "date_created"):
        raw = told.get(name)
        if isinstance(raw, str) and raw:
            try:
                at = parsedate_to_datetime(raw)
            except (TypeError, ValueError):
                try:
                    at = datetime.fromisoformat(raw.replace("Z", "+00:00"))
                except ValueError:
                    continue
            if at.tzinfo is None:
                at = at.replace(tzinfo=UTC)
            return int(at.timestamp() * 1000)
    return now_ms


def _whole(value: Any) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


class Texts:
    """The conversations and their rules. `name_of` says what the orders call a number (its digits), for a
    conversation that begins with a text nobody at the POS wrote; `on_change` is called whenever a screen
    that shows conversations has something to read; `location` is the restaurant's name, for the first text
    to a number (`wrap`)."""

    def __init__(
        self,
        store: TextStore | None = None,
        *,
        now: Callable[[], float] = time.time,
        name_of: Callable[[str], str] | None = None,
        on_change: Callable[[], None] | None = None,
        location: str = "",
    ) -> None:
        self.store = store if store is not None else TextStore()
        self._now = now
        self.name_of = name_of
        self.on_change = on_change
        self.location = location
        self._lock = threading.RLock()  # one text at a time is written down, however it was heard of

    def _now_ms(self) -> int:
        return int(self._now() * 1000)

    def tell(self) -> None:
        """A screen that shows conversations has something to read."""
        if self.on_change is not None:
            try:
                self.on_change()
            except Exception:  # noqa: BLE001 - a screen that is not told reads at its next look
                log.warning("texts: the screens could not be told")

    def _name(self, phone: str) -> str:
        """What the orders call this number, for a conversation that is new."""
        if self.name_of is None or self.store.thread(phone) is not None:
            return ""
        try:
            return clean_name(self.name_of(phone_digits(phone)))
        except Exception:  # noqa: BLE001 - a conversation without a name is still a conversation
            return ""

    # -- what the POS sends (`pos.twilio.TwilioMessenger` calls these two)

    def wrote(self, *, to: str, body: str, kind: str, order_id: str = "", name: str = "") -> str | None:
        """One of the POS's own texts to an order is on its way to Twilio: it is written down, so the
        customer's answer is read under it. Gives the text's id, or None where it could not be kept (a hub
        whose database is a standby: the text goes all the same)."""
        phone = number_of(to)
        if phone is None:
            return None
        text = Text(uuid.uuid4().hex, phone, False, body, self._now_ms(), WAITING, kind=kind, order_id=order_id)
        try:
            with self._lock:
                kept = self.store.add(text, name=clean_name(name) or self._name(phone))
        except ReadOnlyError:
            return None
        except Exception:  # noqa: BLE001 - an order's text is never held back for the want of a note of it
            log.warning("texts: one of the POS's own could not be written down")
            return None
        self.tell()
        return kept.text_id if kept is not None else None

    def became(self, text_id: str, *, state: str, sid: str = "", code: int | None = None, said: str = "") -> None:
        """What became of a text the hub handed to Twilio: taken (with Twilio's name for it), delivered,
        read, or not gone and why."""
        try:
            with self._lock:
                old = self.store.get(text_id)
                if old is None:
                    return
                if sid and sid != old.sid:
                    twin = self.store.by_sid(sid)
                    if twin is not None and twin.text_id != text_id:
                        if twin.kind == ELSEWHERE:
                            # Twilio was asked for its newest texts before it had answered this one's sending
                            self.store.drop(twin.text_id)
                            state = _further(state, twin.state)
                        else:
                            # another text with the same words took this one's name by mistake: it gives it back
                            self.store.change(twin.text_id, sid="")
                new = self._settle(old, state, sid=sid, code=code, said=said)
        except ReadOnlyError:
            return
        if new is not None:
            self.tell()

    def _settle(self, old: Text, state: str, *, sid: str = "", code: int | None = None, said: str = "") -> Text | None:
        """Writes where a text stands now, never back from where it stood: a text that was delivered is not
        made "sent" by an answer that comes late. Gives the text where anything changed."""
        fields: dict[str, Any] = {}
        if sid and not old.sid:
            fields["sid"] = sid
        further = _further(old.state, state)
        if further != old.state:
            fields["state"] = further
            fields["code"] = code if further == FAILED else None
            fields["said"] = said if further == FAILED else ""
        if not fields:
            return None
        new = self.store.change(old.text_id, **fields)
        if new is not None and new.state == FAILED and new.code == OPTED_OUT:
            thread = self.store.thread(new.phone)
            if thread is not None and thread.stopped_ms is None:
                self.store.set_thread(new.phone, stopped_ms=self._now_ms())
        return new

    # -- what Twilio says of a text (asked for, or pushed)

    def take(
        self, told: Mapping[str, Any], *, pictures: Callable[[str], Sequence[Picture] | None] | None = None
    ) -> bool:
        """One text as Twilio describes it (a row of its list of messages): a customer's is written down
        once, one of the restaurant's the POS did not send too, and one the hub knows learns where it stands
        now. `pictures` asks Twilio which pictures a text carries. Whether anything changed."""
        sid = str(told.get("sid") or "")
        if not sid:
            return False
        inbound = str(told.get("direction") or "").startswith("inbound")
        phone = number_of(told.get("from") if inbound else told.get("to"))
        if phone is None:
            return False  # a short code, a chat address: not a number the POS keeps conversations by
        now_ms = self._now_ms()
        state = _TWILIO_STATE.get(str(told.get("status") or ""), RECEIVED if inbound else SENT)
        if inbound:
            state = RECEIVED
        code = told.get("error_code")
        code = code if isinstance(code, int) and not isinstance(code, bool) else None
        said = str(told.get("error_message") or "")[:200]
        n = min(_whole(told.get("num_media")), MEDIA_MOST)
        changed = False
        with self._lock:
            known = self.store.by_sid(sid)
            if known is None and not inbound:
                body = str(told.get("body") or "")
                mine = self.store.unsent(phone, body, _when(told, now_ms) - 5 * 60 * 1000)
                if mine is not None:
                    # the hub sent it and never heard Twilio's answer: this is it
                    known = self.store.change(mine.text_id, sid=sid)
                    changed = True
            if known is None:
                text = Text(
                    text_id=uuid.uuid4().hex,
                    phone=phone,
                    inbound=inbound,
                    body=str(told.get("body") or "")[: BODY_MAX * 2],
                    at_ms=_when(told, now_ms),
                    state=state,
                    sid=sid,
                    channel=channel_of(told.get("from"), told.get("to"), pictures=n),
                    pictures_n=n,
                    code=code if state == FAILED else None,
                    said=said if state == FAILED else "",
                    kind=STAFF if inbound else ELSEWHERE,
                )
                known = self.store.add(text, name=self._name(phone))
                if known is None:
                    return False
                changed = True
                if inbound:
                    self._heard_stop(known)
            elif not inbound:
                channel = channel_of(told.get("from"), told.get("to"), pictures=known.pictures_n or n)
                if channel != known.channel and channel == "rcs":
                    known = self.store.change(known.text_id, channel=channel) or known
                    changed = True
                if self._settle(known, state, code=code, said=said) is not None:
                    changed = True
        if known is not None and n > len(known.pictures) and pictures is not None:
            found = pictures(sid)  # Twilio is asked outside the lock: nobody's text waits for it
            if found:
                listed = tuple(found)[:MEDIA_MOST]
                self.store.change(known.text_id, pictures=listed, pictures_n=max(n, len(listed)))
                changed = True
        return changed

    def _heard_stop(self, text: Text) -> None:
        """A customer's text that is one of the phone companies' words: STOP ends the texts to them, START
        lets them go again. Twilio acts on the word by itself; this is the conversation saying so."""
        word = text.body.strip().lower()
        if word in STOP_WORDS:
            self.store.set_thread(text.phone, stopped_ms=text.at_ms)
        elif word in START_WORDS:
            thread = self.store.thread(text.phone)
            if thread is not None and thread.stopped_ms is not None and thread.stopped_ms <= text.at_ms:
                self.store.set_thread(text.phone, stopped_ms=None)

    # -- what the staff do

    def wrap(self, phone: str) -> tuple[str, str]:
        """What stands before and after the first text to a number that never texted the restaurant and was
        never texted by it: who it is from, and how to make it stop. Nothing for a conversation that has
        begun."""
        thread = self.store.thread(phone)
        if thread is not None and thread.last is not None:
            return "", ""
        return (f"{self.location}: " if self.location else ""), "\nReply STOP to opt out."

    def compose(
        self,
        to: object,
        body: object,
        *,
        by_id: str,
        by_name: str,
        device: str = "",
        text_id: str = "",
        name: str = "",
        pictures: Sequence[bytes] = (),
    ) -> tuple[Text, bool]:
        """A text a person typed, written down as waiting to go: the text, and whether it is new (False for
        one a screen sent twice under the same id: it is not sent again). `pictures` go with it and are kept
        on the hub, for Twilio to fetch and for the screens to show. Refused for no number, neither words
        nor a picture, too many of either, a picture that is none a text carries, and a customer who
        answered STOP."""
        phone = number_of(to)
        if phone is None:
            raise Refused("no_number", "That is not a number a text can go to.")
        words = clean_body(body)
        if not words and not pictures:
            raise Refused("no_text", "A text needs some words.")
        if text_id and not _TEXT_ID.fullmatch(text_id):
            raise Refused("bad_id", "That is no id for a text.")
        if len(pictures) > SEND_MOST:
            raise Refused("too_many", f"A text carries {SEND_MOST} pictures at the most.")
        kinds = [picture_kind(data) for data in pictures]
        if not all(kinds):
            raise Refused("bad_picture", "A text carries a JPEG, a PNG or a GIF. That picture is none of them.")
        if sum(len(data) for data in pictures) > SEND_BYTES:
            raise Refused("too_big", "Those pictures are too big together for one text.")
        with self._lock:
            if text_id:
                again = self.store.get(text_id)
                if again is not None:
                    return again, False
            thread = self.store.thread(phone)
            if thread is not None and thread.stopped_ms is not None:
                raise Refused("stopped", "They answered STOP: no text goes to them until they text START.")
            before, after = self.wrap(phone)
            # a picture alone still says who it is from the first time: the name without its colon
            head = f"{before}{words}" if words else before.rstrip().removesuffix(":")
            whole = f"{head}{after}".strip()
            if len(whole) > BODY_MAX:
                raise Refused("too_long", f"A text holds {BODY_MAX} letters at the most.")
            now_ms = self._now_ms()
            text = Text(
                text_id or uuid.uuid4().hex,
                phone,
                False,
                whole,
                now_ms,
                WAITING,
                channel="mms" if pictures else "sms",
                pictures=tuple(Picture("", kind or "") for kind in kinds),
                pictures_n=len(pictures),
                by_id=by_id,
                by_name=by_name,
                device=device[:80],
            )
            kept = self.store.add(text, name=clean_name(name) or self._name(phone))
            if kept is None:
                raise Refused("bad_id", "That id is another text's.")
            try:
                for n, data in enumerate(pictures):
                    self.store.keep_picture(f"{OWN}{kept.text_id}", n, kinds[n] or "", data, now_ms)
            except Exception:
                self.store.drop(kept.text_id)  # a text whose pictures the hub does not hold cannot go
                raise
            # whoever answers has read what they answer
            self.store.set_thread(phone, read_seq=self.store.top_seq(phone), read_by=by_name)
        self.tell()
        return kept, True

    def sent_picture(self, text_id: str, n: int) -> tuple[str, bytes] | None:
        """A picture the staff sent with a text, as the hub keeps it: what it is, and the picture. None
        where the hub holds none (it was never there, or it is older than the hub keeps them)."""
        return self.store.picture(f"{OWN}{text_id}", n)

    def read(self, phone: str, *, by: str) -> Thread | None:
        """Somebody opened the conversation: the customer's texts in it are read, for everybody."""
        with self._lock:
            thread = self.store.thread(phone)
            if thread is None:
                return None
            top = self.store.top_seq(phone)
            if top <= thread.read_seq:
                return thread
            thread = self.store.set_thread(phone, read_seq=top, read_by=by)
        self.tell()
        return thread

    def name(self, phone: str, name: str) -> None:
        """What the orders call this number now: kept on its conversation for the list."""
        name = clean_name(name)
        thread = self.store.thread(phone)
        if thread is not None and name and name != thread.name:
            try:
                self.store.set_thread(phone, name=name)
            except ReadOnlyError:
                return
            self.tell()

    def threads(self, *, q: str = "", limit: int = THREADS) -> dict[str, Any]:
        """The conversations for a list, the newest first, and how many hold something nobody has opened."""
        return {
            "unread": self.store.unread(),
            "threads": [thread.as_json() for thread in self.store.threads(q=q, limit=max(1, min(limit, THREADS)))],
        }

    def thread(self, phone: str, *, before_ms: int | None = None, limit: int = PAGE) -> dict[str, Any]:
        """One conversation: its texts, the oldest first (the newest `limit`, or those before `before_ms`),
        whether there are older ones (`more`), and what the first text to this number would be wrapped in."""
        limit = max(1, min(limit, PAGE))
        thread = self.store.thread(phone) or Thread(phone)
        texts = self.store.texts(phone, before_ms=before_ms, limit=limit + 1)
        more = len(texts) > limit
        before, after = self.wrap(phone)
        return {
            "thread": thread.as_json(),
            "texts": [text.as_json() for text in texts[-limit:]],
            "more": more,
            "wrap": {"before": before, "after": after},
        }


def _further(old: str, new: str) -> str:
    """Where a text stands after it was told `new` while it stood at `old`: never back. A text that failed
    stays failed unless the phone company says it arrived after all."""
    if old == new or new == RECEIVED or old == RECEIVED:
        return old
    if new == FAILED:
        return old if old in (DELIVERED, READ) else FAILED
    if old == FAILED:
        return new if new in (DELIVERED, READ) else FAILED
    return new if _RANK.get(new, -1) > _RANK.get(old, -1) else old


class Hears(Protocol):
    """What the hub asks Twilio with (`pos.twilio.TwilioMessenger`)."""

    def heard(self, since_ms: int) -> list[dict[str, Any]] | None: ...

    def one(self, sid: str) -> dict[str, Any] | None: ...

    def pictures_of(self, sid: str) -> list[Picture] | None: ...


HISTORY_MS = 3 * 24 * 3600 * 1000
"""How far back Twilio is asked the first time, and after the hub was off for long: three days."""
WINDOW_MS = 15 * 60 * 1000
"""How far before the last asking each asking reaches: what Twilio said of a text can change for a while
after it was sent (delivered, read, not delivered), and a text can show up late."""
QUICK_SECONDS = 5.0
"""How often Twilio is asked while a screen is on."""
SLOW_SECONDS = 30.0
"""How often while none is: the texts are still written down, for whoever turns a screen on next."""


class Listener:
    """Asks Twilio for the texts that came, now and then, and hands each to `Texts.take`.

    Twilio would rather tell: it calls an address on the internet the moment a text comes. A hub has none
    (docs/text-inbox.md, "How a text reaches the hub"), so it asks instead: the list of the account's
    messages since a little before it last asked. A text therefore shows a few seconds after it came, and
    nothing outside the building has to be set up.

    Where Twilio can reach the hub after all (`pos.online.twilio_way`) it calls the moment a text comes or
    changes, and `hear` asks for that one text at once. The asking goes on beside it: it is the net under
    a call that did not arrive.

    `source` gives what Twilio is asked with now, None while the hub has no Twilio account. `screens` says
    how many screens are on: with none the asking slows down."""

    def __init__(
        self,
        texts: Texts,
        source: Callable[[], Hears | None],
        *,
        now: Callable[[], float] = time.time,
        screens: Callable[[], int] | None = None,
    ) -> None:
        self.texts = texts
        self._source = source
        self._now = now
        self._screens = screens
        self._asked_ms: int | None = None
        self._last_round = 0.0
        self._tidied_ms = 0
        self._thread: threading.Thread | None = None
        self.ok: bool | None = None
        """Whether the last asking was answered; None before the first."""
        self.at_ms: int | None = None
        """When Twilio last answered."""
        self.called_ms: int | None = None
        """When Twilio last called the hub about a text; None where it never has."""
        self._called: list[float] = []  # when the calls of the last minute came
        self._lock = threading.Lock()

    def about(self) -> dict[str, Any]:
        """How the asking stands, for a screen: whether Twilio answered the last time, and when it last did."""
        return {"ok": self.ok, "at_ms": self.at_ms}

    def round(self) -> int:
        """Asks Twilio once. Gives how many texts were new or changed; nothing on a hub without an account,
        and on one whose database is a standby (the hub that has the database asks)."""
        source = self._source()
        if source is None:
            self.ok = None
            return 0
        if not self.texts.store.writable():
            return 0
        now_ms = int(self._now() * 1000)
        last = self._asked_ms if self._asked_ms is not None else self.texts.store.newest_ms()
        since = max(now_ms - HISTORY_MS, (last or 0) - WINDOW_MS)
        heard = source.heard(since)
        if heard is None:
            self.ok = False
            return 0
        self.ok, self.at_ms, self._asked_ms = True, now_ms, now_ms
        changed = 0
        for told in reversed(heard):  # Twilio lists the newest first: they are written down as they came
            try:
                if self.texts.take(told, pictures=source.pictures_of):
                    changed += 1
            except ReadOnlyError:
                break
        if changed:
            self.texts.tell()  # the screens read what came
        if now_ms - self._tidied_ms > 3600 * 1000:
            self._tidied_ms = now_ms
            try:
                self.texts.store.drop_pictures(now_ms - PICTURES_KEPT_MS)
            except ReadOnlyError:
                pass
        return changed

    def hear(self, sid: str) -> bool:
        """Twilio called the hub about this text (its own name for it): it came, or something became of it.
        Nothing of the call is believed but the name: Twilio itself is asked for that text, and what it
        answers is written down like a row of its list. Whether anything changed. Nothing on a hub without
        an account, on a standby, and past `HEARD_A_MINUTE` calls in a minute: the next asking has it."""
        source = self._source()
        if source is None:
            return False
        now = self._now()
        with self._lock:
            self._called = [at for at in self._called if at > now - 60]
            if len(self._called) >= HEARD_A_MINUTE:
                return False
            self._called.append(now)
            self.called_ms = int(now * 1000)
        if not self.texts.store.writable():
            return False
        told = source.one(sid)
        if told is None:
            return False
        try:
            changed = self.texts.take(told, pictures=source.pictures_of)
        except ReadOnlyError:
            return False
        if changed:
            self.texts.tell()
        return changed

    def due(self) -> bool:
        """Whether it is time to ask: every few seconds with a screen on, less often with none."""
        quiet = self._now() - self._last_round
        watched = self._screens is None or self._screens() > 0
        return quiet >= (QUICK_SECONDS if watched else SLOW_SECONDS)

    def start(self, tick: float = 1.0) -> None:
        """A daemon that asks whenever it is due, for as long as the hub runs."""
        if self._thread is not None:
            return

        def loop() -> None:
            while True:
                try:
                    if self.due():
                        self._last_round = self._now()
                        self.round()
                except Exception:  # noqa: BLE001 - an asking that goes wrong must never be the last one
                    self.ok = False
                    log.error("texts: asking Twilio went wrong\n%s", traceback.format_exc(limit=3, chain=False))
                time.sleep(tick)

        self._thread = threading.Thread(target=loop, name="texts-in", daemon=True)
        self._thread.start()


__all__ = [
    "BODY_MAX",
    "OWN",
    "SEND_BYTES",
    "SEND_MOST",
    "DELIVERED",
    "ELSEWHERE",
    "FAILED",
    "READ",
    "RECEIVED",
    "SENT",
    "WAITING",
    "Hears",
    "Listener",
    "PgTextStore",
    "Picture",
    "ReadOnlyError",
    "Refused",
    "Text",
    "TextStore",
    "Texts",
    "Thread",
    "channel_of",
    "default_text_store",
    "number_of",
    "picture_kind",
]
