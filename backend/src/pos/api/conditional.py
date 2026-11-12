"""A read that has not changed is answered with `304 Not Modified` and no body.

The screens poll: the open orders, the floor and the open check every two seconds, the menu when an order
opens. Most of those answers are the same as the one before, and the same answer sent again is bytes on the
network, a decode and a redraw on every screen for nothing. Every JSON answer to a GET therefore carries an
`ETag` (a hash of its bytes), and a client that sends it back in `If-None-Match` gets 304 while the answer
is still the same. A client that sends nothing gets what it always got.

The answer is still worked out to be compared, so this saves the network and the screen, not the hub: the
reads the screens poll are made cheap in the order log's own index (`pos.sync`).
"""

from __future__ import annotations

from hashlib import blake2b
from typing import Any

Scope = dict[str, Any]
Message = dict[str, Any]


def etag_of(body: bytes) -> str:
    """Weak, because the same answer also travels compressed (the gzip middleware sits outside this one)."""
    return f'W/"{blake2b(body, digest_size=12).hexdigest()}"'


def _matches(wanted: str, etag: str) -> bool:
    bare = etag.removeprefix("W/")
    return any(tag.strip().removeprefix("W/") == bare for tag in wanted.split(","))


class ConditionalGet:
    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Any, send: Any) -> None:
        if scope["type"] != "http" or scope["method"] != "GET":
            await self.app(scope, receive, send)
            return
        wanted = next((v.decode("latin-1") for k, v in scope["headers"] if k == b"if-none-match"), "")
        start: Message | None = None  # held back until the whole body is here
        chunks: list[bytes] = []

        async def held(message: Message) -> None:
            nonlocal start
            if message["type"] == "http.response.start":
                headers = dict(message.get("headers", ()))
                json = headers.get(b"content-type", b"").startswith(b"application/json")
                if message["status"] == 200 and json and b"etag" not in headers:
                    start = message
                    return
            elif message["type"] == "http.response.body" and start is not None:
                chunks.append(message.get("body", b""))
                if message.get("more_body"):
                    return
                body = b"".join(chunks)
                etag = etag_of(body)
                first, start = start, None
                kept = [(k, v) for k, v in first.get("headers", ()) if k != b"content-length"]
                if wanted and _matches(wanted, etag):
                    unchanged = [(k, v) for k, v in kept if k != b"content-type"]
                    await send({**first, "status": 304, "headers": [*unchanged, (b"etag", etag.encode())]})
                    await send({"type": "http.response.body", "body": b""})
                    return
                length = (b"content-length", str(len(body)).encode())
                await send({**first, "headers": [*kept, length, (b"etag", etag.encode())]})
                await send({"type": "http.response.body", "body": body})
                return
            await send(message)

        await self.app(scope, receive, held)
