"""The push door: the one thing on a hub that a way in from outside the building may reach.

GloriaFood sends an accepted order to an address on the internet (docs/online-orders.md, "Push"). Whatever
brings that address to the hub, a tunnel or the restaurant's own router, must never be pointed at the hub's
API: that is the whole POS. It is pointed here instead. The door is a second, tiny server (`uvicorn --factory
pos.online.door:door_from_env`, the `door` service in infra/hub/docker-compose.yml) that does one thing:

- `POST /online/push` that carries this restaurant's key for pushes is handed on to the API's own
  `/online/push` on the hub's inside network, and the API's answer is handed back.

Everything else is answered 404 with nothing in it: every other path, every other method, and so is every
call while the hub has no key for pushes. There is no page that says what this is.

A push without the key is not read. Only its header is handed on, with an empty body, so that the API can
count it and say so in its status (`pos.online.service`), and the API's 401 is handed back. A push that
says it is bigger than a push may be, or turns out to be, is answered 413 and is not handed on.

Nothing is kept here and nothing is written to a log but the line a server writes for each call (the time,
the path, the answer's number): no header, no body, no key.
"""

from __future__ import annotations

import os
from collections.abc import Awaitable, Callable, MutableMapping
from typing import Any

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from .gloriafood import PUSH_MOST, allowed, push_key_from_env

PATH = "/online/push"
INSIDE = "http://api:8000"
"""Where the API is, seen from the door's container."""
WAIT_SECONDS = 12.0
"""How long the API is waited for: GloriaFood itself waits fifteen seconds for the door."""
ANSWER_MOST = 2_000
"""The most of an answer of the API's that is handed back. Its answers to a push are a few words."""

Scope = MutableMapping[str, Any]
Receive = Callable[[], Awaitable[MutableMapping[str, Any]]]
Send = Callable[[MutableMapping[str, Any]], Awaitable[None]]


class Door:
    """The door as a server (ASGI). `to` is the API's address on the inside, `key` what a push must carry
    (None: the door is shut). `client` is for the tests, which stand an API behind it."""

    def __init__(self, *, to: str = INSIDE, key: str | None = None, client: httpx.AsyncClient | None = None) -> None:
        self._to = to.rstrip("/") + PATH
        self._key = key or None
        self._client = client

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
        if request.method != "POST" or request.url.path != PATH or self._key is None:
            return Response(status_code=404)
        authorization = request.headers.get("authorization")
        body: bytes | None = b""
        if allowed(authorization, self._key):
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


async def body_of(request: Request) -> bytes | None:
    """What a push holds, or None for one that is bigger than a push may be: by what it says of itself,
    or by what actually comes."""
    said = request.headers.get("content-length", "")
    if said.isdigit() and int(said) > PUSH_MOST:
        return None
    parts: list[bytes] = []
    size = 0
    async for part in request.stream():
        size += len(part)
        if size > PUSH_MOST:
            return None
        parts.append(part)
    return b"".join(parts)


def door_from_env(environ: MutableMapping[str, str] | None = None) -> Door:
    """The hub's door: the API at `POS_DOOR_TO` (the `api` service unless set), open for the key in
    `POS_GLORIAFOOD_PUSH_KEY` and shut without one."""
    env = os.environ if environ is None else environ
    return Door(to=(env.get("POS_DOOR_TO") or INSIDE).strip(), key=push_key_from_env(env))
