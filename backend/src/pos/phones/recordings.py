"""Call recordings on phone orders (docs/call-recordings.md).

The PBX records the calls; the hub only reads them. Nothing here records anything, and nothing on the PBX is
changed from here: the hub's recordings key runs one small program there (`infra/hub/pbx/pos-recordings`,
installed by `hubctl pbx recordings link`) that lists the recordings and hands one over as an MP3, and
refuses everything else.

Three things happen, all through that one program:

- **A look** (`Recordings.sweep`): "what changed since the last look?". Every recording's name says who was on
  the call and which call it was (FreePBX names them `<kind>-<called>-<from>-<date>-<time>-<call id>.<ext>`),
  so a look costs one short listing and no audio moves. What is found is kept in the database, a line a
  call: the call's id, the outside number, when it began, which file. The hub looks every ten minutes, a few
  seconds after a call ends (the PBX's manager interface says when), and when somebody opens an order's
  calls and the last look is not fresh.
- **An order's calls** (`Recordings.for_order`): the recorded calls with the order's phone number, from the
  day the order was opened to the day it is wanted for. A call from the customer and a call out to them
  both count. Reading that list moves no audio either.
- **Listening** (`Recordings.audio`): the one recording is fetched from the PBX as an MP3 when somebody
  presses play, and kept on the hub for a month so the second listen is at once.

A call recorded through the POS's stereo step on the PBX has a second file, `pos-<call id>.mp3`, with the
caller on the left and the restaurant on the right; where there is one, that is the one played.
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import tempfile
import threading
import time
import traceback
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .. import localtime
from ..sync.oplog import phone_digits

log = logging.getLogger("pos.phones.recordings")

BACKFILL_DAYS = 90
"""How far back the first look goes: the calls of the last three months are found for the orders of then."""
EVERY_SECONDS = 600.0
"""How often the hub looks when nothing tells it to."""
AFTER_A_CALL = (6.0, 45.0)
"""Seconds after a call ends at which the hub looks: once for the recording, once more for the stereo file
the PBX makes of a long call."""
FRESH_SECONDS = 15.0
"""A look this recent is not repeated when somebody opens an order's calls."""
HOLD_BACK_SECONDS = 60.0
"""After a look that failed, nobody opening an order's calls waits for another one this long."""
MOST_CALLS = 40
"""The most calls one order lists."""
KEEP_DAYS = 30
"""How long a recording somebody listened to stays on the hub."""
KEEP_BYTES = 1_000_000_000
"""The most the hub keeps of them; the ones not listened to the longest go first."""
LIST_TIMEOUT = 40.0
GET_TIMEOUT = 180.0


class PbxError(Exception):
    """The PBX did not answer what was asked: `code` says how (`unreachable`: no answer at all, the key
    refused, a host key that changed; `gone`: no such recording there any more; `tools`: the PBX has nothing
    to read a recording with; `refused` and `failed` for the rest), `message` in its own words."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReadOnlyError(RuntimeError):
    """The database is a standby: nothing can be written here until it is promoted."""


@dataclass(frozen=True)
class Listed:
    """One file of the PBX's recordings folder, as a listing gives it."""

    mtime: float
    size: int
    path: str


@dataclass(frozen=True)
class Recording:
    """What the hub keeps of one recorded call."""

    call_id: str  # the call's id on the PBX: every channel of the call shares it ("1795713495.19788")
    started_ms: int  # when the call began, on the PBX's clock
    number: str = ""  # the outside party, as digits (`phone_digits`); empty until FreePBX's own file is seen
    direction: str = "in"  # "in": the customer called; "out": the restaurant called them
    extension: str = ""  # who dialed, for a call out
    dialed: str = ""  # the restaurant's number that was called, for a call in
    path: str = ""  # FreePBX's own recording, both voices in one channel
    size: int = 0
    stereo_path: str = ""  # the POS's stereo file, where the PBX makes one
    stereo_size: int = 0
    seconds: int | None = None  # the length as measured on the MP3 the hub fetched
    measured: int = 0  # the size of the file that was measured: a recording that grew since is measured again

    @property
    def stereo(self) -> bool:
        return bool(self.stereo_path)

    @property
    def best(self) -> tuple[str, int]:
        """The file to play, and its size: the stereo one where there is one."""
        return (self.stereo_path, self.stereo_size) if self.stereo_path else (self.path, self.size)

    @property
    def length(self) -> int | None:
        """How long the call runs, in seconds: measured once the hub has fetched it, and until then worked
        out from the file's size. None for a kind of file the hub cannot tell it of."""
        path, size = self.best
        if self.seconds is not None and self.measured == size:
            return self.seconds
        return estimate_seconds(path, size)


def estimate_seconds(path: str, size: int) -> int | None:
    """A recording's length from its size alone. The POS's stereo file is an MP3 at 64 kbit/s; FreePBX's
    `.WAV` is GSM (1,625 bytes a second after 60 of header), its `.wav` plain 8 kHz, 16 bits."""
    if path.endswith(".mp3"):
        return max(0, round(size / 8000))
    if path.endswith(".WAV"):
        return max(0, round((size - 60) / 1625))
    if path.endswith(".wav"):
        return max(0, round((size - 44) / 16000))
    return None


# FreePBX: <kind>-<called>-<from>-YYYYMMDD-HHMMSS-<call id>.<ext>; the POS's stereo file: pos-<call id>.mp3
_OWN = re.compile(r"^([a-z]+)-(.*)-([^-]*)-(\d{8})-(\d{6})-(\d+\.\d+)\.([A-Za-z0-9]+)$")
_STEREO = re.compile(r"^pos-(\d+\.\d+)\.mp3$")
_FETCHABLE = re.compile(r"^[A-Za-z0-9+_.@/-]+$")  # what `pos-recordings get` takes
_CALL_ID = re.compile(r"^\d+\.\d+$")


def started_ms_of(call_id: str) -> int:
    """When a call began: Asterisk names a call by the second its first channel was made."""
    return int(call_id.split(".", 1)[0]) * 1000


def read_name(path: str) -> dict[str, Any] | None:
    """What a recording's file name says, as the fields of a `Recording`: None for a file that is not a
    call with an outside number (a call between two extensions, a leg the stereo step has not put together
    yet, anything else in the folder)."""
    name = path.rsplit("/", 1)[-1]
    if not _FETCHABLE.match(path) or ".." in path:
        return None
    stereo = _STEREO.match(name)
    if stereo:
        return {"call_id": stereo.group(1), "stereo_path": path}
    own = _OWN.match(name)
    if not own:
        return None
    kind, called, by, _, _, call_id, _ = own.groups()
    if kind == "out":  # out-<dialed>-<extension>
        number, extension, dialed, direction = phone_digits(called), by, "", "out"
    else:  # generic-<the restaurant's number>-<caller>, rg-<ring group>-<caller>, exten-<extension>-<caller>
        number, extension, dialed, direction = phone_digits(by), "", called, "in"
    if len(number) < 7:
        return None
    return {
        "call_id": call_id,
        "number": number,
        "direction": direction,
        "extension": extension,
        "dialed": dialed,
        "path": path,
    }


def mp3_info(data: bytes) -> tuple[float, int] | None:
    """How long an MP3 runs, in seconds, and its channels (1 or 2), read off its frames one by one. None for
    something that is no MP3."""
    at = 0
    if data[:3] == b"ID3" and len(data) > 10:
        at = 10 + ((data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 | (data[8] & 0x7F) << 7 | (data[9] & 0x7F))
    rates = {3: (44100, 48000, 32000), 2: (22050, 24000, 16000), 0: (11025, 12000, 8000)}
    kbps_1 = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
    kbps_2 = (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)
    seconds, channels, frames, lost, end = 0.0, 0, 0, 0, len(data) - 4
    while at <= end:
        head = int.from_bytes(data[at : at + 4], "big")
        version, layer = (head >> 19) & 3, (head >> 17) & 3
        bitrate, rate = (head >> 12) & 15, (head >> 10) & 3
        if head >> 21 != 0x7FF or version == 1 or layer != 1 or bitrate in (0, 15) or rate == 3:
            at += 1  # not a frame's start: look on, a little
            lost += 1
            if lost > 65536:
                break
            continue
        hz = rates[version][rate]
        kbps = (kbps_1 if version == 3 else kbps_2)[bitrate]
        samples = 1152 if version == 3 else 576
        at += samples // 8 * kbps * 1000 // hz + ((head >> 9) & 1)
        seconds += samples / hz
        channels = 1 if (head >> 6) & 3 == 3 else 2
        frames += 1
    return (seconds, channels) if frames else None


# --- the PBX ---------------------------------------------------------------------------------------------


class Pbx:
    """The PBX's recordings as `pos-recordings` answers for them. `ask` is how a request gets there."""

    def ask(self, request: str, *, timeout: float) -> bytes:
        raise NotImplementedError

    def about(self) -> dict[str, str]:
        """What the program on the PBX says of itself: its version, the folder, the tools it found, and
        whether the stereo step is in place."""
        said: dict[str, str] = {}
        for line in self.ask("about", timeout=LIST_TIMEOUT).decode("utf-8", "replace").splitlines():
            key, _, value = line.strip().partition(" ")
            if key:
                said[key] = value
        return said

    def list(self, since: int) -> list[Listed]:
        """The files changed after `since` (seconds since 1970, on the PBX's clock)."""
        found = []
        for line in self.ask(f"list {int(since)}", timeout=LIST_TIMEOUT).decode("utf-8", "replace").splitlines():
            parts = line.split(" ", 2)
            if len(parts) != 3:
                continue
            try:
                found.append(Listed(float(parts[0]), int(parts[1]), parts[2]))
            except ValueError:
                continue
        return found

    def get(self, path: str) -> bytes:
        """One recording as an MP3."""
        if not _FETCHABLE.match(path) or ".." in path or path.startswith(("/", "-")):
            raise PbxError("refused", "that is not a recording's path")
        return self.ask(f"get {path}", timeout=GET_TIMEOUT)


class CommandPbx(Pbx):
    """A PBX asked by running a command: `command(request)` is what to run, and with what around it. The
    program's ways out are read here, so the real PBX and the one in the tests are read alike."""

    def command(self, request: str) -> tuple[list[str], Mapping[str, str] | None]:
        raise NotImplementedError

    def ask(self, request: str, *, timeout: float) -> bytes:
        argv, env = self.command(request)
        try:
            done = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as err:
            raise PbxError("unreachable", f"the PBX did not answer within {timeout:.0f} s") from err
        except OSError as err:
            raise PbxError("unreachable", f"could not ask the PBX: {err}") from err
        if done.returncode == 0:
            return done.stdout
        said = done.stderr.decode("utf-8", "replace").strip().splitlines()
        words = said[-1].strip() if said else f"exit {done.returncode}"
        code = {255: "unreachable", 2: "refused", 4: "gone", 5: "tools"}.get(done.returncode, "failed")
        raise PbxError(code, words[:300])


_TARGET = re.compile(r"^(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9._:-]*$")


class SshPbx(CommandPbx):
    """The PBX over SSH, with the hub's recordings key. On the PBX that key runs `pos-recordings` whatever
    is asked (its line in authorized_keys says so), so what is sent here is only ever a request to it."""

    def __init__(self, target: str, *, key: str, known_hosts: str, connect_timeout: int = 8) -> None:
        if not _TARGET.match(target):
            raise ValueError("the PBX is named user@host")
        self.target, self._key, self._known, self._connect = target, key, known_hosts, connect_timeout

    def command(self, request: str) -> tuple[list[str], Mapping[str, str] | None]:
        options = (
            "BatchMode=yes",
            "IdentitiesOnly=yes",
            "StrictHostKeyChecking=yes",
            f"UserKnownHostsFile={self._known}",
            f"ConnectTimeout={self._connect}",
            "ServerAliveInterval=15",
            "ServerAliveCountMax=2",
        )
        argv = ["ssh", "-T", "-i", self._key]
        for option in options:
            argv += ["-o", option]
        return [*argv, "--", self.target, request], None


def pbx_from_env(environ: Mapping[str, str] | None = None) -> SshPbx | None:
    """The PBX named by `POS_PBX_RECORDINGS` (user@host, written by `hubctl pbx recordings link`), asked with
    the key in `POS_PBX_RECORDINGS_DIR` (/pbx-recordings on a hub); None where there is none, as on a laptop
    and in the cloud."""
    environ = os.environ if environ is None else environ
    target = (environ.get("POS_PBX_RECORDINGS") or "").strip()
    if not target:
        return None
    folder = (environ.get("POS_PBX_RECORDINGS_DIR") or "/pbx-recordings").rstrip("/")
    try:
        return SshPbx(target, key=f"{folder}/id_ed25519", known_hosts=f"{folder}/known_hosts")
    except ValueError:
        log.warning("call recordings: POS_PBX_RECORDINGS is not user@host; the recordings stay off")
        return None


# --- what the hub keeps ----------------------------------------------------------------------------------


class RecordingStore:
    """The calls in memory: tests, and a laptop with no database."""

    def __init__(self) -> None:
        self._rows: dict[str, Recording] = {}
        self._cursor: int | None = None
        self._lock = threading.Lock()

    def put(self, rows: Sequence[Recording]) -> None:
        with self._lock:
            for row in rows:
                self._rows[row.call_id] = row

    def get_many(self, call_ids: Iterable[str]) -> dict[str, Recording]:
        with self._lock:
            return {call_id: self._rows[call_id] for call_id in call_ids if call_id in self._rows}

    def get(self, call_id: str) -> Recording | None:
        return self.get_many([call_id]).get(call_id)

    def for_number(self, number: str, since_ms: int, until_ms: int, most: int) -> list[Recording]:
        """The calls with `number` that began from `since_ms` up to, not at, `until_ms`, oldest first."""
        with self._lock:
            found = [
                row
                for row in self._rows.values()
                if row.number == number and since_ms <= row.started_ms < until_ms and (row.path or row.stereo_path)
            ]
        return sorted(found, key=lambda row: (row.started_ms, row.call_id))[:most]

    def delete(self, call_id: str) -> None:
        with self._lock:
            self._rows.pop(call_id, None)

    def count(self) -> int:
        with self._lock:
            return sum(1 for row in self._rows.values() if row.number)

    def cursor(self) -> int | None:
        """How far the looks have come: the newest change seen on the PBX, in its seconds. None before the
        first look."""
        return self._cursor

    def set_cursor(self, since: int) -> None:
        self._cursor = since


SCHEMA = """
CREATE TABLE IF NOT EXISTS call_recording (
    call_id     TEXT PRIMARY KEY,
    started_ms  BIGINT NOT NULL,
    number      TEXT NOT NULL DEFAULT '',
    direction   TEXT NOT NULL DEFAULT 'in',
    extension   TEXT NOT NULL DEFAULT '',
    dialed      TEXT NOT NULL DEFAULT '',
    path        TEXT NOT NULL DEFAULT '',
    size        BIGINT NOT NULL DEFAULT 0,
    stereo_path TEXT NOT NULL DEFAULT '',
    stereo_size BIGINT NOT NULL DEFAULT 0,
    seconds     INTEGER,
    measured    BIGINT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS call_recording_number ON call_recording (number, started_ms);
CREATE TABLE IF NOT EXISTS call_recording_cursor (
    one   BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (one),
    since BIGINT NOT NULL
);
"""

_COLUMNS = (
    "call_id, started_ms, number, direction, extension, dialed, path, size, stereo_path, stereo_size, seconds, measured"
)


def _row_of(row: Sequence[Any]) -> Recording:
    return Recording(
        row[0],
        int(row[1]),
        row[2],
        row[3],
        row[4],
        row[5],
        row[6],
        int(row[7]),
        row[8],
        int(row[9]),
        None if row[10] is None else int(row[10]),
        int(row[11]),
    )


class PgRecordingStore(RecordingStore):
    """The same calls, in PostgreSQL, so they are there after a restart and on the hub that takes over."""

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

    def _read(self, sql: str, args: Sequence[Any]) -> list[Any]:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                return conn.execute(sql, args).fetchall()
        except errors.UndefinedTable:
            return []  # a standby whose primary has not been updated yet

    def _write(self, sql: str, args: Sequence[Any] | Sequence[Sequence[Any]], *, many: bool = False) -> None:
        from psycopg import errors

        try:
            with self._pool.connection() as conn:
                if many:
                    conn.cursor().executemany(sql, args)  # type: ignore[arg-type]
                else:
                    conn.execute(sql, args)
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def put(self, rows: Sequence[Recording]) -> None:
        if not rows:
            return
        names = _COLUMNS.split(", ")
        self._write(
            f"INSERT INTO call_recording ({_COLUMNS}) VALUES ({', '.join(['%s'] * len(names))}) "
            "ON CONFLICT (call_id) DO UPDATE SET "
            + ", ".join(f"{name} = EXCLUDED.{name}" for name in names if name != "call_id"),
            [
                (
                    row.call_id,
                    row.started_ms,
                    row.number,
                    row.direction,
                    row.extension,
                    row.dialed,
                    row.path,
                    row.size,
                    row.stereo_path,
                    row.stereo_size,
                    row.seconds,
                    row.measured,
                )
                for row in rows
            ],
            many=True,
        )

    def get_many(self, call_ids: Iterable[str]) -> dict[str, Recording]:
        wanted = list(call_ids)
        if not wanted:
            return {}
        rows = self._read(f"SELECT {_COLUMNS} FROM call_recording WHERE call_id = ANY(%s)", (wanted,))
        return {row[0]: _row_of(row) for row in rows}

    def for_number(self, number: str, since_ms: int, until_ms: int, most: int) -> list[Recording]:
        rows = self._read(
            f"SELECT {_COLUMNS} FROM call_recording WHERE number = %s AND started_ms >= %s AND started_ms < %s "
            "AND (path <> '' OR stereo_path <> '') ORDER BY started_ms, call_id LIMIT %s",
            (number, since_ms, until_ms, most),
        )
        return [_row_of(row) for row in rows]

    def delete(self, call_id: str) -> None:
        self._write("DELETE FROM call_recording WHERE call_id = %s", (call_id,))

    def count(self) -> int:
        rows = self._read("SELECT count(*) FROM call_recording WHERE number <> ''", ())
        return int(rows[0][0]) if rows else 0

    def cursor(self) -> int | None:
        rows = self._read("SELECT since FROM call_recording_cursor", ())
        return int(rows[0][0]) if rows else None

    def set_cursor(self, since: int) -> None:
        self._write(
            "INSERT INTO call_recording_cursor (one, since) VALUES (TRUE, %s) "
            "ON CONFLICT (one) DO UPDATE SET since = EXCLUDED.since",
            (since,),
        )


def default_recording_store() -> RecordingStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    return PgRecordingStore(dsn) if dsn else RecordingStore()


def default_cache() -> Path:
    """Where the recordings somebody listened to are kept: `POS_RECORDINGS_CACHE` (/recordings on a hub, a
    volume of its own), and the machine's folder for passing things otherwise."""
    named = (os.environ.get("POS_RECORDINGS_CACHE") or "").strip()
    return Path(named) if named else Path(tempfile.gettempdir()) / "pos-recordings"


# --- the service -----------------------------------------------------------------------------------------


class Recordings:
    """The hub's side of the call recordings: looks at what the PBX has, says which calls go with an order,
    and fetches one to listen to. With no PBX (`pbx` None) it knows nothing and says so."""

    def __init__(
        self,
        store: RecordingStore | None = None,
        pbx: Pbx | None = None,
        *,
        cache: Path | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._store = store if store is not None else RecordingStore()
        self._pbx = pbx
        self._cache = cache if cache is not None else default_cache()
        self._clock = clock
        self._looking = threading.Lock()  # one look at a time
        self._fetching = threading.Lock()  # one recording at a time
        self._wake = threading.Condition()
        self._due: list[float] = []  # when to look, besides every ten minutes
        self._thread: threading.Thread | None = None
        self._tried: float | None = None  # when the last look began
        self._looked: float | None = None  # when the last look that worked began
        self._problem: PbxError | None = None  # what the last look failed with
        self.on_change: Callable[[], None] | None = None
        """Told whenever a look found a call that is new or changed: the screens that show an order's calls read
        them again (the hub's change feed, topic `calls`)."""
        self._about: dict[str, str] = {}
        self._about_at: float | None = None
        self._pruned: float | None = None

    @property
    def configured(self) -> bool:
        """Whether this hub is linked to a PBX's recordings at all."""
        return self._pbx is not None

    # --- looking ---------------------------------------------------------------------------------

    def sweep(self) -> int:
        """One look: the recordings changed on the PBX since the last one are written down. Answers how many
        calls were new or changed. Raises `PbxError` when the PBX does not answer, and `ReadOnlyError` on a
        standby (the hub that serves does the looking)."""
        if self._pbx is None:
            return 0
        with self._looking:
            began = self._clock()
            self._tried = began
            try:
                since = self._store.cursor()
                first = since is None
                if since is None:
                    since = int(began) - BACKFILL_DAYS * 86400
                # a second again: a file changed within the second of the last look is not missed
                listed = self._pbx.list(max(0, since - 1))
                changed = self._take(listed)
                newest = max((int(item.mtime) for item in listed), default=since)
                if first or newest > since:
                    self._store.set_cursor(max(newest, since))
            except PbxError as err:
                self._problem = err
                raise
            self._problem = None
            self._looked = began
            if changed:
                log.info("call recordings: %d call(s) new or changed on the PBX", changed)
                if self.on_change is not None:
                    self.on_change()
            return changed

    def _take(self, listed: Sequence[Listed]) -> int:
        said: dict[str, dict[str, Any]] = {}
        for item in listed:
            fields = read_name(item.path)
            if fields is None:
                continue
            fields["stereo_size" if "stereo_path" in fields else "size"] = item.size
            said.setdefault(fields.pop("call_id"), {}).update(fields)
        if not said:
            return 0
        known = self._store.get_many(said)
        changed = []
        for call_id, fields in said.items():
            before = known.get(call_id)
            after = replace(before or Recording(call_id, started_ms_of(call_id)), **fields)
            if after != before:
                changed.append(after)
        self._store.put(changed)
        return len(changed)

    def refresh(self) -> None:
        """A look now, unless one was just had (or just failed): what an order's calls are read behind, so
        the call that ended a minute ago is on the list. Never raises: a PBX that is away leaves the list as
        the last look found it."""
        if self._pbx is None:
            return
        now = self._clock()
        if self._tried is not None:
            wait = HOLD_BACK_SECONDS if self._problem is not None else FRESH_SECONDS
            if 0 <= now - self._tried < wait:
                return
        try:
            self.sweep()
        except (PbxError, ReadOnlyError):
            pass

    def call_ended(self, call_id: str = "") -> None:
        """A call just ended on the PBX (its manager interface said so): its recording is there in a moment,
        and the stereo file a little after. The hub looks then, on its own thread."""
        if self._pbx is None or self._thread is None:
            return
        now = self._clock()
        with self._wake:
            self._due.extend(now + after for after in AFTER_A_CALL)
            self._wake.notify()

    def start(self, interval: float = EVERY_SECONDS) -> None:
        """A daemon that looks now, then every `interval` seconds and after each call. Nothing without a PBX."""
        if self._pbx is None or self._thread is not None:
            return

        def loop() -> None:
            next_round = self._clock()
            while True:
                with self._wake:
                    now = self._clock()
                    at = min([next_round, *self._due])
                    if at > now:
                        self._wake.wait(min(at - now, interval))
                        continue
                    self._due = [due for due in self._due if due > now]
                    next_round = now + interval
                try:
                    self.sweep()
                except PbxError as err:
                    log.warning("call recordings: the PBX did not answer a look (%s: %s)", err.code, err.message)
                except ReadOnlyError:
                    pass  # a standby: the hub that serves writes them down
                except Exception:  # noqa: BLE001 - a look that goes wrong must never be the last one
                    log.error("call recordings: a look went wrong\n%s", traceback.format_exc(limit=3, chain=False))

        self._thread = threading.Thread(target=loop, name="call-recordings", daemon=True)
        self._thread.start()

    # --- an order's calls ------------------------------------------------------------------------

    def for_order(self, phone: str, first_ms: int | None, promised_ms: int | None = None) -> list[dict[str, Any]]:
        """The recorded calls that go with an order: the ones with its phone number, from the start of the
        day's service it was opened in to the end of the one it is wanted for, oldest first. `opened` marks
        the call the order was opened during."""
        number = phone_digits(phone)
        if len(number) < 7 or first_ms is None:
            return []
        since, _ = localtime.service_day(localtime.service_day_of(first_ms))
        _, until = localtime.service_day(localtime.service_day_of(max(first_ms, promised_ms or 0)))
        return [
            {
                "id": row.call_id,
                "direction": row.direction,
                "started_ms": row.started_ms,
                "seconds": row.length,
                "stereo": row.stereo,
                "extension": row.extension,
                "opened": row.started_ms - 30_000 <= first_ms <= row.started_ms + (row.length or 0) * 1000 + 120_000,
            }
            for row in self._store.for_number(number, since, until, MOST_CALLS)
        ]

    def belongs(self, call_id: str, phone: str, first_ms: int | None, promised_ms: int | None = None) -> bool:
        """Whether a call is one of an order's: nobody listens to a call through an order it is not on."""
        return any(call["id"] == call_id for call in self.for_order(phone, first_ms, promised_ms))

    # --- listening -------------------------------------------------------------------------------

    def audio(self, call_id: str) -> bytes:
        """One call's recording as an MP3: from the hub's own shelf when somebody listened before, from the
        PBX otherwise. Raises `PbxError`: `gone` for a call the hub does not know or the PBX no longer has,
        `unreachable` when the PBX is away or the hub is not linked to one."""
        if not _CALL_ID.match(call_id):
            raise PbxError("gone", "there is no such call")
        row = self._store.get(call_id)
        path, size = row.best if row is not None else ("", 0)
        if row is None or not path:
            raise PbxError("gone", "there is no such call")
        # kept by what it is: the stereo file that turned up later is never mistaken for the one before it
        kept = self._cache / f"{call_id}-{'stereo' if row.stereo else 'one'}-{size}.mp3"
        try:
            data = kept.read_bytes()
            os.utime(kept)  # listened to now: it stays a month from here
            return data
        except OSError:
            pass
        if self._pbx is None:
            raise PbxError("unreachable", "this hub is not linked to the PBX's recordings")
        with self._fetching:
            try:
                return kept.read_bytes()  # somebody else fetched it meanwhile
            except OSError:
                pass
            try:
                data = self._pbx.get(path)
            except PbxError as err:
                if err.code == "gone":
                    self._forget(call_id)
                raise
            if not data:
                raise PbxError("failed", "the PBX sent nothing for that recording")
            self._keep(kept, data)
        told = mp3_info(data)
        if told is not None:
            try:
                self._store.put([replace(row, seconds=round(told[0]), measured=size)])
            except ReadOnlyError:
                pass
        return data

    def _forget(self, call_id: str) -> None:
        try:
            self._store.delete(call_id)
        except ReadOnlyError:
            pass

    def _keep(self, kept: Path, data: bytes) -> None:
        """Puts a fetched recording on the hub's shelf; a hub that cannot (no room, no folder) plays it all
        the same."""
        try:
            self._cache.mkdir(parents=True, exist_ok=True)
            part = kept.with_suffix(".part")
            part.write_bytes(data)
            part.replace(kept)
            self._prune()
        except OSError as err:
            log.warning("call recordings: could not keep a recording on the hub (%s)", type(err).__name__)

    def _prune(self) -> None:
        """Takes the recordings nobody listened to for a month off the shelf, and the oldest ones while the
        shelf is over its size. At most once an hour."""
        now = self._clock()
        if self._pruned is not None and 0 <= now - self._pruned < 3600:
            return
        self._pruned = now
        files = []
        for file in self._cache.glob("*.mp3"):
            try:
                stat = file.stat()
            except OSError:
                continue
            files.append((stat.st_mtime, stat.st_size, file))
        total = sum(size for _, size, _ in files)
        for mtime, size, file in sorted(files):
            if now - mtime <= KEEP_DAYS * 86400 and total <= KEEP_BYTES:
                break
            try:
                file.unlink()
                total -= size
            except OSError:
                pass

    # --- how it stands ---------------------------------------------------------------------------

    def status(self, *, ask: bool = False) -> dict[str, Any]:
        """How the hub stands with the PBX's recordings. With `ask`, the program on the PBX is asked about
        itself now (its version, its tools, whether the stereo step is in place) when that was not done in
        the last minute; what it said last is told otherwise."""
        if self._pbx is None:
            return {"configured": False}
        now = self._clock()
        if ask and (self._about_at is None or not 0 <= now - self._about_at < 60):
            self._about_at = now
            try:
                self._about = self._pbx.about()
                if self._problem is not None and self._problem.code == "unreachable":
                    self._problem = None
            except PbxError as err:
                self._about = {}
                self._problem = err
        about = self._about
        problem = self._problem
        return {
            "configured": True,
            "pbx": getattr(self._pbx, "target", ""),
            "calls": self._store.count(),
            "looked_ms": None if self._looked is None else int(self._looked * 1000),
            "problem": None if problem is None else {"code": problem.code, "message": problem.message},
            "program": about.get("pos-recordings"),
            "tools": {tool: about.get(tool) == "yes" for tool in ("sox", "lame", "ffmpeg")} if about else None,
            # the stereo step is in place: the program that puts the two sides together, and its lines in the dialplan
            "stereo": all(about.get(part) == "yes" for part in ("stereo-script", "stereo-dialplan")) if about else None,
        }
