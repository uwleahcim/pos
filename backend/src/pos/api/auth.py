"""Who is calling a back-office endpoint: the session token from `/admin/session`, and what its holder may do."""

from __future__ import annotations

from typing import Any

from fastapi import HTTPException

from ..identity.powers import SETTINGS, holds
from ..identity.tokens import Grant, Tokens

MANAGERS = frozenset({"manager", "owner"})


def manager_from(tokens: Tokens, authorization: str | None) -> Grant:
    """The manager behind a `Bearer` token, or 401 (no valid token) / 403 (not a manager). This is the check
    of everything no setting hands out: the location's settings, the printers, the staff's tags and faces."""
    grant = _grant(tokens, authorization)
    if grant.role not in MANAGERS:
        raise HTTPException(403, {"error": "not_allowed", "role": grant.role, "power": SETTINGS})
    return grant


def powers_of(state: Any) -> dict[str, Any] | None:
    """The location's table of who may do what, as it stands now (None on an app built without settings:
    the standard table)."""
    settings = getattr(state, "settings", None)
    return settings.get("powers") if settings is not None else None


def holder_from(state: Any, authorization: str | None, power: str) -> Grant:
    """The person behind a `Bearer` token when their role holds `power` at this location now, or 401 (no
    valid token) / 403 (the role does not hold it). `state` is the app's (`app.state`): its tokens and its
    settings. The table is read on every call, so a power taken from a role is gone from the sessions
    already open."""
    grant = _grant(state.tokens, authorization)
    if not holds(powers_of(state), grant.role, power):
        raise HTTPException(403, {"error": "not_allowed", "role": grant.role, "power": power})
    return grant


def _grant(tokens: Tokens, authorization: str | None) -> Grant:
    token = (authorization or "").removeprefix("Bearer ").strip()
    grant = tokens.verify(token) if token else None
    if grant is None:
        raise HTTPException(401, {"error": "sign_in", "message": "sign in with a manager PIN"})
    return grant
