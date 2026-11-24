"""The tunnel: the hub's line to Cloudflare, down which GloriaFood's pushes come (docs/online-orders.md,
"The way in"). `python -m pos.online.tunnel`, the `tunnel` service in infra/hub/docker-compose.yml.

Cloudflare's own program (`cloudflared`) holds the line. It wants the tunnel's token when it starts, and a
manager types that token in the app (Location, Keys and connections), long after the hub started. Nothing
on a hub may start or restart a program for the app: the API has no hold on the containers. So this small
keeper runs all the time, beside nothing but the push door, and does the starting itself:

- It watches one file, `/tunnel/token`, which the API writes (`pos.online.wayin`). No file: no tunnel, and
  it waits. A token: it starts `cloudflared` with it. Another token: it ends that one and starts anew. The
  file gone: it ends it.
- A `cloudflared` that ends by itself (a token Cloudflare does not take, a hub with no way out) is started
  again, after a little longer each time, five minutes at the most.
- It says how the tunnel stands in `/tunnel/status.json`, for the API to read: `off`, `starting`,
  `connected` (Cloudflare's program says it holds a line: its own `/ready`), or `failing`, with why.

The token is handed to `cloudflared` in its environment, never on its command line, and is taken out of
every line it prints before the line is printed or kept. This module uses nothing but Python itself: it is
the one program on the hub that talks to the outside all day, and is kept small.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Protocol

TUNNEL_DIR = "/tunnel"
"""Where the API leaves the tunnel its token, and the tunnel says how it stands (`POS_TUNNEL_DIR` names
another place). The volume `pos-tunnel`."""
TOKEN_FILE = "token"
STATUS_FILE = "status.json"
PROGRAM = "cloudflared"
METRICS = "127.0.0.1:20241"
"""Where `cloudflared` is told to say how it is doing: inside this container only."""

STATES = ("off", "starting", "connected", "failing")
"""How a tunnel stands: it has no token, it is on its way to Cloudflare, it is there, or it cannot get there."""
REASONS = ("refused", "unreachable", "slow", "missing", "trouble")
"""Why not: Cloudflare did not take the token, Cloudflare cannot be reached, it is taking long, the hub has
no tunnel program, and anything else."""

LOOK_SECONDS = 2.0
"""How often the token is looked at, and `cloudflared` asked whether it holds a line."""
BEAT_SECONDS = 10.0
"""How often it says how it stands when nothing changed: silence for long means it is not running."""
SLOW_SECONDS = 30.0
"""A `cloudflared` that runs this long without a line to Cloudflare is failing, though it goes on trying."""
STOP_SECONDS = 8.0
"""How long a `cloudflared` told to end is waited for before it is ended."""
WAITS = (5.0, 10.0, 20.0, 40.0, 80.0, 160.0, 300.0)
"""How long until a `cloudflared` that ended is started again: longer each time in a row."""
LINES_KEPT = 40
SAID_MOST = 200
TOKEN_MOST = 8_000
REGISTERED = "Registered tunnel connection"

_REFUSED = ("not valid", "invalid tunnel secret", "unauthorized", "unauthenticated", "tunnel not found")
_UNREACHABLE = ("dial", "no such host", "timeout", "timed out", "unreachable", "connection refused", "handshake")
_STAMP = re.compile(r"^\S*\d\S*Z?\s+(ERR|FTL|WRN|INF|DBG)\s+")


def digest_of(secret: str) -> str:
    """The SHA-256 of a secret: enough to know it when it comes, and not the secret."""
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def mark_of(token: str | None) -> str:
    """A few characters that change when the tunnel's token does, and say nothing of it: how the API knows
    which token a tunnel's word on how it stands is about."""
    return digest_of(token)[:12] if token else ""


def write_whole(path: Path, text: str) -> None:
    """Writes a small file so that whoever reads it finds the old one or the new one, never a part: beside
    it first, the hub's own user's alone, then in its place."""
    beside = path.with_name(f".{path.name}.new")
    fd = os.open(beside, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(beside, path)


def why(lines: Sequence[str]) -> tuple[str, str]:
    """Why a `cloudflared` is not connected, from its last lines: one of `REASONS`, and the line of its own
    that says it best, without its time."""
    recent = list(lines)[-12:]

    def last(words: Sequence[str]) -> str | None:
        return next((line for line in reversed(recent) if any(word in line.lower() for word in words)), None)

    refused, unreachable = last(_REFUSED), last(_UNREACHABLE)
    if refused is not None:
        reason, line = "refused", refused
    elif unreachable is not None:
        reason, line = "unreachable", unreachable
    else:
        errors = [line for line in recent if " ERR " in line or " FTL " in line]
        reason, line = "trouble", (errors or recent or [""])[-1]
    return reason, _STAMP.sub("", line).strip()[:SAID_MOST]


class Running(Protocol):
    """A `cloudflared` that was started: its last `lines`, whether it said it `registered` a line with
    Cloudflare, whether it ended (`poll`: None while it runs), and the way to end it."""

    lines: Sequence[str]
    registered: bool

    def poll(self) -> int | None: ...

    def stop(self) -> None: ...


class Child:
    """`cloudflared` as this keeper runs it. What it prints is printed here, a line at a time, with the
    token taken out, and the last lines are kept for saying why it is not connected."""

    def __init__(self, argv: Sequence[str], token: str, *, out: Callable[[str], None] = print) -> None:
        self.lines: deque[str] = deque(maxlen=LINES_KEPT)
        self.registered = False
        self._token = token
        self._out = out
        # the hub's own program, by its name, with no words of anybody's on its command line
        self._proc = subprocess.Popen(
            list(argv),
            env={**os.environ, "TUNNEL_TOKEN": token},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            bufsize=1,
        )
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        assert self._proc.stdout is not None
        for raw in self._proc.stdout:
            line = raw.rstrip("\r\n").replace(self._token, "(the token)")
            if REGISTERED in line:
                self.registered = True
            self.lines.append(line)
            self._out(line)

    def poll(self) -> int | None:
        code = self._proc.poll()
        if code is not None:
            self._reader.join(timeout=2)  # its last words, before anybody asks why it ended
        return code

    def stop(self) -> None:
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=STOP_SECONDS)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait(timeout=STOP_SECONDS)
        self._reader.join(timeout=2)


def start(token: str) -> Running:
    """Starts Cloudflare's program with this token, told not to replace itself and where to say how it is
    doing. `FileNotFoundError` on a machine that has no such program."""
    return Child([PROGRAM, "tunnel", "--no-autoupdate", "--metrics", METRICS, "run"], token, out=say)


def ready() -> bool | None:
    """Whether `cloudflared` holds a line to Cloudflare, by its own account (`/ready`: 200 with one, 503
    with none). None when it does not answer at all: just started, or of a kind that does not say."""
    try:
        with urllib.request.urlopen(f"http://{METRICS}/ready", timeout=2) as answer:
            return bool(answer.status == 200)
    except urllib.error.HTTPError:
        return False
    except (OSError, ValueError):
        return None


def say(line: str) -> None:
    print(line, flush=True)


class Tunnel:
    """The keeper. `folder` is where the token is left and the status written. `spawn`, `is_ready` and
    `clock` are for the tests, which stand a program in for Cloudflare's."""

    def __init__(
        self,
        folder: Path,
        *,
        spawn: Callable[[str], Running] = start,
        is_ready: Callable[[], bool | None] = ready,
        clock: Callable[[], float] = time.time,
        version: str = "",
        out: Callable[[str], None] = say,
    ) -> None:
        self._folder = folder
        self._spawn = spawn
        self._is_ready = is_ready
        self._clock = clock
        self._version = version
        self._out = out
        self._token: str | None = None
        self._child: Running | None = None
        self._waiting = 0.0  # since when it has been without a line: its start, or the moment it lost one
        self._again_at = 0.0
        self._ended = 0  # times in a row
        self._failed: tuple[str, str] | None = None  # why, and its own word on it
        self._state = "off"
        self._since = clock()
        self._written: tuple[str, str | None, str, str] | None = None
        self._beat = 0.0
        self._told_unwritable = False

    @property
    def state(self) -> str:
        return self._state

    def _wanted(self) -> str | None:
        """The token the API left, or None: no file, an empty one, or one that cannot be read now."""
        try:
            with open(self._folder / TOKEN_FILE, encoding="utf-8", errors="replace") as f:
                token = "".join(f.read(TOKEN_MOST).split())
        except OSError:
            return None
        return token or None

    def turn(self) -> None:
        """One look: at the token, at `cloudflared`, and then it says how the tunnel stands."""
        now = self._clock()
        token = self._wanted()
        if token != self._token:
            had = self._token is not None
            self._end()
            self._token = token
            self._failed, self._ended, self._again_at = None, 0, 0.0
            if token is None:
                self._out("tunnel: the token is gone; the tunnel is stopped")
            elif had:
                self._out("tunnel: another token; starting anew")
        if token is None:
            self._stand("off", now)
            return
        child = self._child
        if child is not None and (code := child.poll()) is not None:
            self._child = None
            self._failed = why(child.lines)
            wait = WAITS[min(self._ended, len(WAITS) - 1)]
            self._ended += 1
            self._again_at = now + wait
            self._out(f"tunnel: cloudflared ended ({code}): {self._failed[0]}; again in {wait:.0f} s")
        if self._child is None and now >= self._again_at:
            try:
                self._child = self._spawn(token)
                self._waiting = now
                self._out("tunnel: cloudflared started")
            except OSError as err:
                self._failed = ("missing", "")
                self._again_at = now + WAITS[-1]
                self._out(f"tunnel: cloudflared could not be started ({type(err).__name__})")
        up = False
        if self._child is not None:
            told = self._is_ready()
            up = self._child.registered if told is None else told
            if up:
                if self._state != "connected":
                    self._out("tunnel: connected to Cloudflare")
                self._failed, self._ended = None, 0
            else:
                if self._state == "connected":
                    self._waiting = now
                    self._out("tunnel: the line to Cloudflare is lost; cloudflared goes on trying")
                if self._failed is None and now - self._waiting >= SLOW_SECONDS:
                    reason, said = why(self._child.lines)
                    self._failed = ("slow" if reason == "trouble" else reason, said)
        self._stand("connected" if up else "failing" if self._failed is not None else "starting", now)

    def _stand(self, state: str, now: float) -> None:
        if state != self._state:
            self._state, self._since = state, now
        reason, said = self._failed if state == "failing" and self._failed is not None else (None, "")
        mark = mark_of(self._token)
        stands = (state, reason, said, mark)
        if stands == self._written and now - self._beat < BEAT_SECONDS:
            return
        told = {
            "state": state,
            "since_ms": int(self._since * 1000),
            "reason": reason,
            "said": said,
            "mark": mark,
            "version": self._version,
            "beat_ms": int(now * 1000),
        }
        try:
            write_whole(self._folder / STATUS_FILE, json.dumps(told))
        except OSError as err:
            if not self._told_unwritable:
                self._told_unwritable = True
                self._out(f"tunnel: cannot say how it stands in {self._folder} ({type(err).__name__})")
            return
        self._written, self._beat = stands, now

    def _end(self) -> None:
        if self._child is not None:
            self._child.stop()
            self._child = None

    def close(self) -> None:
        """The keeper is told to end: `cloudflared` ends with it."""
        self._end()


def version_of(program: str = PROGRAM) -> str:
    """Which `cloudflared` this hub has, in its own words; nothing where it has none."""
    try:
        done = subprocess.run([program, "--version"], capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    found = re.search(r"\d{4}\.\d+\.\d+", done.stdout or "")
    return found.group(0) if found else (done.stdout or "").strip()[:40]


def main() -> int:
    folder = Path((os.environ.get("POS_TUNNEL_DIR") or "").strip() or TUNNEL_DIR)
    version = version_of()
    say(f"tunnel: cloudflared {version or 'is not on this hub'}; the token is looked for in {folder}")
    tunnel = Tunnel(folder, version=version)
    stopping = threading.Event()
    for name in (signal.SIGTERM, signal.SIGINT):
        signal.signal(name, lambda *_: stopping.set())
    if tunnel._wanted() is None:
        say("tunnel: no token yet. A manager types it in the app: Location, Keys and connections")
    while not stopping.is_set():
        tunnel.turn()
        stopping.wait(LOOK_SECONDS)
    tunnel.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
