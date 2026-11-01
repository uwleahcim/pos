"""Who is calling a back-office endpoint: a manager's session token from `/admin/session`."""

from __future__ import annotations

from fastapi import HTTPException

from ..identity.tokens import Grant, Tokens

MANAGERS = frozenset({"manager", "owner"})


def manager_from(tokens: Tokens, authorization: str | None) -> Grant:
    """The manager behind a `Bearer` token, or 401 (no valid token) / 403 (not a manager)."""
    token = (authorization or "").removeprefix("Bearer ").strip()
    grant = tokens.verify(token) if token else None
    if grant is None:
        raise HTTPException(401, {"error": "sign_in", "message": "sign in with a manager PIN"})
    if grant.role not in MANAGERS:
        raise HTTPException(403, {"error": "not_allowed", "role": grant.role})
    return grant
