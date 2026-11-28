"""The push door: the one thing on a hub that a way in from outside the building may reach.

GloriaFood sends an accepted order to an address on the internet (docs/online-orders.md, "Push"). Whatever
brings that address to the hub, a tunnel or the restaurant's own router, must never be pointed at the hub's
API: that is the whole POS. It is pointed here instead. The door is a second, tiny server (`uvicorn --factory
pos.online.door:door_from_env`, the `door` service in infra/hub/docker-compose.yml) that does one thing:

- `POST /online/push` that carries this restaurant's key for pushes is handed on to the API's own
  `/online/push` on the hub's inside network, and the API's answer is handed back.

- A call of Twilio's whose path carries the hub's word for Twilio (`pos.online.twilio_way`: a text came,
  something became of one, or a picture of a text the restaurant is sending is fetched) is handed on to
  the API under the same path, and the API's answer is handed back: a few fixed letters for the first
  two, the picture for the third and nothing else of any answer.

Everything else is answered 404 with nothing in it: every other path, every other method, and so is every
call while the hub has no key for pushes, and every call of Twilio's kind while it has no word for Twilio.
There is no page that says what this is.

The door runs all the time, shut until the hub has a key for pushes, and it is told of that key by the API
(`pos.online.wayin`): a small file in a folder the door may only read (`/door/key.json`), which holds the
key's SHA-256 and not the key. The door looks at the file with every call, so a key a manager types in the
app (Location, Keys and connections) opens the door at once, and one that is removed shuts it; the door is
never restarted for it. A door that was told nothing yet goes by `POS_GLORIAFOOD_PUSH_KEY`, as it always
did. A file that cannot be read keeps the door shut. The word for Twilio is told the same way, in a second
file beside the first (`/door/twilio.json`), and without that file no call of Twilio's kind gets in.

A push without the key is not read. Only its header is handed on, with an empty body, so that the API can
count it and say so in its status (`pos.online.service`), and the API's 401 is handed back. A push that
says it is bigger than a push may be, or turns out to be, is answered 413 and is not handed on.

Nothing is kept here and nothing is written to a log but the line a server writes for each call (the time,
the path, the answer's number): no header, no body, no key. The hub's word for Twilio is in a path, so it is
taken out of that line before the line is written (`pos.online.twilio_way.hush`).
"""

from __future__ import annotations

import hmac
import json
import os
import re
from collections.abc import Awaitable, Callable, MutableMapping
from pathlib import Path
from typing import Any

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from .gloriafood import PUSH_MOST, allowed, push_key_from_env
from .tunnel import digest_of
from .twilio_way import CALL_MOST, PATHS, SENT_KINDS, TWIML, hush

PATH = "/online/push"
INSIDE = "http://api:8000"
"""Where the API is, seen from the door's container."""
WAIT_SECONDS = 12.0
"""How long the API is waited for: GloriaFood itself waits fifteen seconds for the door."""
ANSWER_MOST = 2_000
"""The most of an answer of the API's that is handed back. Its answers to a push are a few words."""

DOOR_DIR = "/door"
"""Where the API leaves the door its word (`POS_DOOR_DIR` names another place). The volume `pos-door`."""
KEY_FILE = "key.json"
TWILIO_FILE = "twilio.json"
"""Where the API leaves the SHA-256 of the hub's word for Twilio."""
PICTURE_MOST = 6_000_000
"""The most of a picture that is handed out, in bytes: Twilio takes five million of a whole text."""
_DIGEST = re.compile(r"^[0-9a-f]{64}$")

Scope = MutableMapping[str, Any]
Receive = Callable[[], Awaitable[MutableMapping[str, Any]]]
Send = Callable[[MutableMapping[str, Any]], Awaitable[None]]


class Told:
    """What the API told the door of the key for pushes, read again whenever the file changed."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._stamp: tuple[int, int, int] | None = None
        self._digest: str | None = None

    def now(self) -> tuple[bool, str | None]:
        """Whether the door was told anything, and the key's SHA-256: None when the hub has no key for
        pushes, and when what was left cannot be read."""
        try:
            found = os.stat(self._path)
        except FileNotFoundError:
            self._stamp = None
            return False, None
        except OSError:
            return True, None
        stamp = (found.st_mtime_ns, found.st_size, found.st_ino)
        if stamp != self._stamp:
            digest = None
            try:
                told = json.loads(self._path.read_bytes()[:1000])
                given = told.get("sha256") if isinstance(told, dict) else None
                if isinstance(given, str) and _DIGEST.fullmatch(given):
                    digest = given
            except (OSError, ValueError):
                digest = None
            self._stamp, self._digest = stamp, digest
        return True, self._digest


class Door:
    """The door as a server (ASGI). `to` is the API's address on the inside. What a push must carry is what
    the API left in `told` (the key's SHA-256), and until it left anything, `key` (None: the door is shut).
    What a call of Twilio's must carry in its path is what the API left in `twilio` (the word's SHA-256);
    without it there is no such call. `client` is for the tests, which stand an API behind it."""

    def __init__(
        self,
        *,
        to: str = INSIDE,
        key: str | None = None,
        told: Path | None = None,
        twilio: Path | None = None,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._inside_at = to.rstrip("/")
        self._to = self._inside_at + PATH
        self._key = key or None
        self._told = Told(told) if told is not None else None
        self._twilio = Told(twilio) if twilio is not None else None
        self._client = client

    def _judge(self, authorization: str | None) -> tuple[bool, bool]:
        """Whether the door is open at all, and whether this call carries the key. The comparison takes the
        same time whatever was sent."""
        said, digest = self._told.now() if self._told is not None else (False, None)
        if not said:
            return self._key is not None, allowed(authorization, self._key)
        if digest is None:
            return False, False
        given = (authorization or "").strip()
        return True, bool(given) and hmac.compare_digest(digest_of(given), digest)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "lifespan":
            await self._lifespan(receive, send)
            return
        if scope["type"] != "http":
            return  # no sockets, nothing else: whoever asks is left without an answer
        request = Request(scope, receive)
        response = await self._answer(request)
        await response(scope, receive, send)

    async def _answer(self, request: Request) -> Response:
        if request.url.path != PATH:
            return await self._from_twilio(request)
        if request.method != "POST":
            return Response(status_code=404)
        authorization = request.headers.get("authorization")
        is_open, with_key = self._judge(authorization)
        if not is_open:
            return Response(status_code=404)
        body: bytes | None = b""
        if with_key:
            body = await body_of(request)
            if body is None:
                return JSONResponse({"error": "too_big"}, 413)
        headers = {"Content-Type": request.headers.get("content-type") or "application/json"}
        if authorization is not None:
            headers["Authorization"] = authorization
        try:
            inside = await self._inside().post(self._to, content=body, headers=headers)
        except httpx.TimeoutException:
            return JSONResponse({"error": "late"}, 504)
        except httpx.HTTPError:
            return JSONResponse({"error": "down"}, 502)
        if len(inside.content) > ANSWER_MOST or not inside.headers.get("content-type", "").startswith(
            "application/json"
        ):
            return JSONResponse({"error": "trouble"}, 502)
        return Response(inside.content, inside.status_code, media_type="application/json")

    async def _from_twilio(self, request: Request) -> Response:
        """A call of Twilio's kind: handed on when its path carries the hub's word for Twilio, and
        otherwise not found, like every path there is nothing behind. What comes back is the API's number
        and, of its answer, only what Twilio is to have: the fixed "nothing to send back" for a call about
        a text, and a picture for a picture."""
        found = PATHS.fullmatch(request.url.path)
        if found is None or self._twilio is None:
            return Response(status_code=404)
        _, digest = self._twilio.now()
        if digest is None or not hmac.compare_digest(digest_of(found[1]), digest):
            return Response(status_code=404)
        to = self._inside_at + request.url.path
        about_text = found[2] in ("text", "status")
        if request.method not in (("POST",) if about_text else ("GET", "HEAD")):
            return Response(status_code=404)
        try:
            if about_text:
                body = await body_of(request, CALL_MOST)
                if body is None:
                    return Response(status_code=413)
                kind = request.headers.get("content-type") or "application/x-www-form-urlencoded"
                inside = await self._inside().post(to, content=body, headers={"Content-Type": kind})
            else:
                inside = await self._inside().get(to)  # Twilio asks with HEAD first: the same answer, less its body
        except httpx.TimeoutException:
            return Response(status_code=504)
        except httpx.HTTPError:
            return Response(status_code=502)
        if inside.status_code != 200:
            return Response(status_code=inside.status_code if inside.status_code in (403, 404, 410) else 502)
        if about_text:
            return Response(TWIML, 200, media_type="text/xml")
        kind = inside.headers.get("content-type", "").split(";")[0].strip().lower()
        if kind not in SENT_KINDS or len(inside.content) > PICTURE_MOST:
            return Response(status_code=502)
        headers = {"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"}
        return Response(inside.content, 200, media_type=kind, headers=headers)

    def _inside(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=WAIT_SECONDS)
        return self._client

    async def _lifespan(self, receive: Receive, send: Send) -> None:
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                if self._client is not None:
                    await self._client.aclose()
                await send({"type": "lifespan.shutdown.complete"})
                return


async def body_of(request: Request, most: int = PUSH_MOST) -> bytes | None:
    """What a push holds, or None for one that is bigger than a push may be (`most`, in bytes): by what
    it says of itself, or by what actually comes."""
    said = request.headers.get("content-length", "")
    if said.isdigit() and int(said) > most:
        return None
    parts: list[bytes] = []
    size = 0
    async for part in request.stream():
        size += len(part)
        if size > most:
            return None
        parts.append(part)
    return b"".join(parts)


def door_from_env(environ: MutableMapping[str, str] | None = None) -> Door:
    """The hub's door: the API at `POS_DOOR_TO` (the `api` service unless set), open for the key the API
    tells it of in `POS_DOOR_DIR` (`/door` unless set), and until it is told anything, for the key in
    `POS_GLORIAFOOD_PUSH_KEY`. Shut without one. Twilio's calls get in once the API left its word for them
    in the same folder."""
    env = os.environ if environ is None else environ
    folder = Path((env.get("POS_DOOR_DIR") or "").strip() or DOOR_DIR)
    hush()
    return Door(
        to=(env.get("POS_DOOR_TO") or INSIDE).strip(),
        key=push_key_from_env(env),
        told=folder / KEY_FILE,
        twilio=folder / TWILIO_FILE,
    )
