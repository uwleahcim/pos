"""Short-lived staff tokens for back-office calls such as the menu editor.

A manager signs in once with a PIN and gets a token; each later call carries it instead of the PIN, so a
PIN is checked once rather than on every save. A token is signed, not stored: every hub and the cloud
accept it when they share `POS_SECRET`; without one, each process makes its own secret and a restart
asks for the PIN again.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass

TTL_SECONDS = 60 * 60


@dataclass(frozen=True)
class Grant:
    staff_id: str
    name: str
    role: str
    expires: float
    scope: str | None = None  # what the token is good for, e.g. "adjust:o1" for a discount on one order


class Tokens:
    def __init__(self, secret: str | None = None, *, clock: Callable[[], float] = time.time) -> None:
        secret = secret or os.environ.get("POS_SECRET") or secrets.token_hex(32)
        self._key = secret.encode()
        self._clock = clock

    def issue(
        self, staff_id: str, name: str, role: str, ttl: float = TTL_SECONDS, *, scope: str | None = None
    ) -> tuple[str, Grant]:
        grant = Grant(staff_id, name, role, self._clock() + ttl, scope)
        body = _b64(json.dumps(grant.__dict__, separators=(",", ":")).encode())
        return f"{body}.{self._sign(body)}", grant

    def verify(self, token: str) -> Grant | None:
        """The grant a token carries, or None if it is forged, malformed or expired."""
        body, _, signature = token.partition(".")
        if not signature or not hmac.compare_digest(signature, self._sign(body)):
            return None
        try:
            grant = Grant(**json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))))
        except (ValueError, TypeError):
            return None
        return grant if grant.expires > self._clock() else None

    def _sign(self, body: str) -> str:
        return _b64(hmac.new(self._key, body.encode(), hashlib.sha256).digest())


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")
