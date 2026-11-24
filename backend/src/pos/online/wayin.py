"""The way in for GloriaFood's pushes, as the API tends it (docs/online-orders.md, "Push").

Two programs beside the API bring a push in: the push door (`pos.online.door`), which checks the key a push
carries, and the tunnel (`pos.online.tunnel`), which holds a line open to Cloudflare. Each needs one secret
of the hub's: the door the key for pushes, the tunnel its token. Both are a manager's to type in the app
(`pos.keys`), and the API cannot start or restart a program: it has no hold on the hub's containers, and is
not given one. So both programs run all the time, idle without their secret, and the API **hands** each
what it needs, in a folder it shares with that one program and no other:

- **The door** (`/door`, the volume `pos-door`, which the door may only read): `key.json`, which holds not
  the key but its SHA-256. The door can tell a push that carries the key from one that does not, and has
  nothing to give away.
- **The tunnel** (`/tunnel`, the volume `pos-tunnel`): `token`, the tunnel's token as it is, since the tunnel
  has to show it to Cloudflare; readable by the hub's own user alone, as `/opt/pos/.env` is root's alone.
  The tunnel writes `status.json` beside it: whether it has reached Cloudflare, and if not, why.

Both look at their file as they work, so a key typed in the app is in force within a second or two, and
nothing is restarted. What is handed is always the key in force (`pos.keys.HubKeys`: the app's over the
hub's own file), so a hub set up with `hubctl` goes on as it did.

**Trying it** (`WayIn.knock`): the API knocks at the door, and at the address GloriaFood sends to, with a
word made for that one knock in place of the key. The door hands a knock without the key on to the API as
it does for anybody, and the API knows its own word when it arrives (`OnlineOrders.expect`). So the whole
way in is proven, from the address at Cloudflare to this very hub, and the key for pushes never leaves it.

Nothing here is written to a log but that a hand-over failed. No message carries a key or a token.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

import httpx

from .door import DOOR_DIR, KEY_FILE
from .tunnel import REASONS, STATES, STATUS_FILE, TOKEN_FILE, TUNNEL_DIR, digest_of, mark_of, write_whole

log = logging.getLogger(__name__)

DOOR_URL = "http://door:8090"
"""The door, seen from the API's container (`POS_DOOR_URL`)."""
PATH = "/online/push"
STALE_MS = 45_000
"""A tunnel that has not said how it stands for this long is not running."""
STATUS_MOST = 4_000
SAID_MOST = 200
KNOCK_SECONDS = 15.0
"""How long a knock is waited for: GloriaFood itself waits fifteen seconds."""

HOST = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$")
"""A name on the internet: no number alone, no port, nothing after it."""
ADDRESS_SETTING = "online_push_address"


def clean_address(typed: str) -> str:
    """The name GloriaFood sends pushes to, as a manager typed it: `orders.example.com`, with or without
    `https://` before it and `/online/push` after. Nothing for nothing typed. ValueError for what is not a
    name on the internet: a number, a port, a name without a dot."""
    text = re.sub(r"^https?://", "", typed.strip().lower())
    text = text.split("/", 1)[0]
    if not text:
        return ""
    if not HOST.fullmatch(text):
        raise ValueError(
            "that does not look like an address on the internet (a name such as orders.example.com, with no port)"
        )
    return text


def _folder(named: str | None, usual: str) -> Path | None:
    """One of the two folders, where this machine has it: a hub does, a laptop and the cloud do not."""
    path = Path((named or "").strip() or usual)
    return path if path.is_dir() else None


def _words(value: Any, most: int) -> str:
    """What another program wrote, as a screen may show it: a line of plain text, not long."""
    if not isinstance(value, str):
        return ""
    return "".join(ch if ch.isprintable() else " " for ch in value).strip()[:most]


def _whole(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


class WayIn:
    """What the API hands the door and the tunnel, what it hears back, and its knocks at both ends.

    `door` and `tunnel` are the two folders (None: this machine has none, and nothing is handed). `client`
    is for the tests, which stand a door and an internet behind it."""

    def __init__(
        self,
        door: Path | None = None,
        tunnel: Path | None = None,
        *,
        door_url: str = DOOR_URL,
        client: httpx.AsyncClient | None = None,
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self._door = door
        self._tunnel = tunnel
        self._door_url = door_url.rstrip("/") + PATH
        self._client = client
        self._now = now
        self._door_told: bool | None = None
        self._tunnel_told: bool | None = None
        self._mark = ""  # of the token the tunnel was last handed

    # --- handing over ------------------------------------------------------------------------------------

    def hand(self, push_key: str | None, token: str | None) -> None:
        """The key for pushes and the tunnel's token in force now, or none of either: each program is told.
        A folder that cannot be written is said in the log, once for each time it happens, and in
        `about`; the hub goes on."""
        self._mark = mark_of(token)
        if self._door is not None:
            said = json.dumps({"sha256": digest_of(push_key) if push_key else None})
            self._door_told = self._write(self._door / KEY_FILE, said, "the door")
        if self._tunnel is not None:
            self._tunnel_told = self._hand_token(self._tunnel / TOKEN_FILE, token)

    def _write(self, path: Path, text: str, whom: str) -> bool:
        try:
            write_whole(path, text)
        except OSError as err:
            log.warning("the way in: %s could not be told (%s)", whom, type(err).__name__)
            return False
        return True

    def _hand_token(self, path: Path, token: str | None) -> bool:
        if token:
            return self._write(path, token, "the tunnel")
        try:
            path.unlink(missing_ok=True)
        except OSError as err:
            log.warning("the way in: the tunnel's token could not be taken away (%s)", type(err).__name__)
            return False
        return True

    # --- hearing back ------------------------------------------------------------------------------------

    def tunnel(self) -> dict[str, Any]:
        """How the tunnel stands, as it says itself: `there` (the hub runs a tunnel program that speaks),
        `state` (one of `STATES`), since when (`since_ms`), and while it is failing why (`reason`, one of
        `REASONS`, and `said`: the tunnel program's own last word on it). A tunnel that is still on the
        token before the one it was handed is `starting`. What it wrote is another program's, so nothing of
        it is taken but what is named here."""
        gone = {"there": False, "state": "off", "since_ms": None, "reason": None, "said": "", "version": ""}
        if self._tunnel is None:
            return gone
        try:
            with open(self._tunnel / STATUS_FILE, "rb") as f:
                told = json.loads(f.read(STATUS_MOST))
        except (OSError, ValueError):
            return gone
        if not isinstance(told, dict):
            return gone
        beat = _whole(told.get("beat_ms"))
        if beat is None or self._now() - beat > STALE_MS:
            return gone
        state = told.get("state") if told.get("state") in STATES else "starting"
        reason = told.get("reason") if told.get("reason") in REASONS else None
        out = {
            "there": True,
            "state": state,
            "since_ms": _whole(told.get("since_ms")),
            "reason": reason if state == "failing" else None,
            "said": _words(told.get("said"), SAID_MOST) if state == "failing" else "",
            "version": _words(told.get("version"), 40),
        }
        if told.get("mark") != self._mark:
            # its word is about another token than the one in force: it has not looked yet
            fresh = "starting" if self._mark else "off"
            out.update(state=fresh, since_ms=None, reason=None, said="")
        return out

    def about(self) -> dict[str, Any]:
        """The way in as a manager's screen is told of it: whether the door could be told its key (`door`:
        null on a machine that runs none), and the tunnel as it stands."""
        return {"door": self._door_told, "tunnel_told": self._tunnel_told, "tunnel": self.tunnel()}

    # --- knocking ----------------------------------------------------------------------------------------

    def _knocker(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=KNOCK_SECONDS, follow_redirects=False)
        return self._client

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()

    async def knock(self, word: str, host: str | None = None) -> dict[str, Any]:
        """One knock with `word` where the key would be: at the door from inside the hub, or with `host` at
        `https://<host>/online/push` from outside. Gives what came back: `code` (the answer's number, or
        None when nothing answered) and `refused` (it was the answer this hub gives a push without the
        key). Whether the knock reached this hub is for the caller to say: only it knows its word."""
        url = self._door_url if host is None else f"https://{host}{PATH}"
        try:
            answer = await self._knocker().post(
                url,
                content=b'{"count": 0, "orders": []}',
                headers={"Authorization": word, "Content-Type": "application/json"},
            )
        except httpx.TimeoutException:
            return {"url": url, "code": None, "refused": False, "late": True}
        except (httpx.HTTPError, OSError):
            return {"url": url, "code": None, "refused": False, "late": False}
        refused = False
        if answer.status_code == 401:
            try:
                refused = answer.json() == {"error": "refused"}
            except ValueError:
                refused = False
        return {"url": url, "code": answer.status_code, "refused": refused, "late": False}


def wayin_from_env(environ: Mapping[str, str] | None = None) -> WayIn:
    """The hub's way in: the folders `/door` and `/tunnel` where the machine has them (`POS_DOOR_DIR`,
    `POS_TUNNEL_DIR`), and the door at `POS_DOOR_URL`."""
    env = os.environ if environ is None else environ
    return WayIn(
        _folder(env.get("POS_DOOR_DIR"), DOOR_DIR),
        _folder(env.get("POS_TUNNEL_DIR"), TUNNEL_DIR),
        door_url=(env.get("POS_DOOR_URL") or "").strip() or DOOR_URL,
    )


__all__ = [
    "ADDRESS_SETTING",
    "DOOR_DIR",
    "KEY_FILE",
    "REASONS",
    "STATES",
    "STATUS_FILE",
    "TOKEN_FILE",
    "TUNNEL_DIR",
    "WayIn",
    "clean_address",
    "digest_of",
    "mark_of",
    "wayin_from_env",
    "write_whole",
]
