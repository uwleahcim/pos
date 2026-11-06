"""Apple's push service (APNs) over HTTP/2 with token-based authentication.

The hub signs a short-lived token with the team's APNs key (`AuthKey_<KEYID>.p8`, one per team, never
expires) and posts each notification to `api.push.apple.com`; a development build of the app, the kind Xcode
installs on Mike's iPhone, only takes pushes from the sandbox service, so a token Apple refuses on production
as `BadDeviceToken` is tried on the sandbox once and remembered there.

Two kinds go out: a VoIP push (`apns-push-type: voip`, topic `<bundle>.voip`), which iOS delivers to a locked
phone and the app must hand to CallKit at once, and an alert (`apns-push-type: alert`, the bundle id as the
topic), the notification for a desk-phone pick-up.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Literal

import httpx

log = logging.getLogger("pos.push")

PRODUCTION = "https://api.push.apple.com"
SANDBOX = "https://api.sandbox.push.apple.com"
Env = Literal["production", "sandbox"]
Kind = Literal["voip", "alert"]

#: Apple's reasons for which the token itself is at fault (the environment, or the app is gone).
BAD_TOKEN = frozenset({"BadDeviceToken", "DeviceTokenNotForTopic"})
GONE = frozenset({"Unregistered", "ExpiredToken"})


@dataclass(frozen=True)
class ApnsConfig:
    key_pem: bytes
    key_id: str
    team_id: str
    bundle_id: str

    @classmethod
    def from_env(cls, environ: dict[str, str] | None = None) -> ApnsConfig | None:
        """`POS_APNS_KEY` (the .p8 file), `POS_APNS_KEY_ID`, `POS_APNS_TEAM_ID` and `POS_APNS_BUNDLE_ID`;
        None when no key is configured, as on a laptop or a hub before `hubctl push apple`."""
        env = os.environ if environ is None else environ
        path = env.get("POS_APNS_KEY", "").strip()
        if not path:
            return None
        key_id, team_id = env.get("POS_APNS_KEY_ID", "").strip(), env.get("POS_APNS_TEAM_ID", "").strip()
        if not key_id or not team_id:
            log.warning("POS_APNS_KEY is set but POS_APNS_KEY_ID or POS_APNS_TEAM_ID is not: no pushes go out")
            return None
        try:
            with open(path, "rb") as f:
                pem = f.read()
        except OSError as err:
            log.warning("the APNs key %s cannot be read (%s): no pushes go out", path, err)
            return None
        return cls(pem, key_id, team_id, env.get("POS_APNS_BUNDLE_ID", "").strip() or "org.chinasky.posApp")


@dataclass(frozen=True)
class SendResult:
    ok: bool
    status: int
    reason: str | None = None
    env: Env | None = None  # the environment the token answered on; None when neither took it

    @property
    def gone(self) -> bool:
        """The token is no longer any device's: forget it."""
        return self.reason in GONE


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def provider_token(key_pem: bytes, key_id: str, team_id: str, issued_at: int) -> str:
    """The JWT Apple wants in the `authorization` header: ES256 over the key, the key id in the header, the
    team id as the issuer."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("the APNs key is not an EC (P-256) key")
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": team_id, "iat": issued_at}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{_b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


@dataclass
class _Counts:
    sent: int = 0
    failed: int = 0
    last_error: str | None = None
    last_sent_ms: int | None = None
    by_env: dict[str, int] = field(default_factory=dict)


class ApnsSender:
    """One HTTP/2 client to Apple for as long as the API runs. Apple asks that the provider token be renewed at
    least once an hour and not more than every twenty minutes; it is renewed after fifty."""

    def __init__(
        self,
        config: ApnsConfig,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], float] = time.time,
        token_life: float = 50 * 60,
        timeout: float = 10.0,
    ) -> None:
        self.config = config
        self._clock = clock
        self._token_life = token_life
        self._token: tuple[float, str] | None = None
        self._client = httpx.AsyncClient(http2=transport is None, transport=transport, timeout=timeout)
        self._counts = _Counts()

    async def close(self) -> None:
        await self._client.aclose()

    @property
    def bundle_id(self) -> str:
        return self.config.bundle_id

    def status(self) -> dict[str, Any]:
        c = self._counts
        return {
            "configured": True,
            "bundle": self.config.bundle_id,
            "key_id": self.config.key_id,
            "team_id": self.config.team_id,
            "sent": c.sent,
            "failed": c.failed,
            "last_error": c.last_error,
            "last_sent": c.last_sent_ms,
            "by_env": dict(c.by_env),
        }

    def _authorization(self) -> str:
        now = self._clock()
        if self._token is None or now - self._token[0] > self._token_life:
            self._token = (now, provider_token(self.config.key_pem, self.config.key_id, self.config.team_id, int(now)))
        return f"bearer {self._token[1]}"

    async def send(
        self,
        token: str,
        payload: dict[str, Any],
        *,
        kind: Kind,
        env: Env | None = None,
        collapse_id: str | None = None,
        expiration: int = 0,
    ) -> SendResult:
        """Posts one notification. `env` is where the token is known to live; None tries production first and
        then the sandbox, as a development build's token lives there. Nothing raises: the result says."""
        order: list[Env] = [env] if env else ["production", "sandbox"]
        if env:
            order.append("sandbox" if env == "production" else "production")  # reinstalled with the other kind of build
        last = SendResult(False, 0, "not sent")
        for attempt in order:
            last = await self._post(attempt, token, payload, kind, collapse_id, expiration)
            if last.ok or last.reason not in BAD_TOKEN:
                break
        if last.ok:
            self._counts.sent += 1
            self._counts.last_sent_ms = int(self._clock() * 1000)
            self._counts.by_env[last.env or "?"] = self._counts.by_env.get(last.env or "?", 0) + 1
        else:
            self._counts.failed += 1
            self._counts.last_error = f"{last.status} {last.reason}"
        return last

    async def _post(
        self, env: Env, token: str, payload: dict[str, Any], kind: Kind, collapse_id: str | None, expiration: int
    ) -> SendResult:
        topic = self.config.bundle_id + (".voip" if kind == "voip" else "")
        headers = {
            "authorization": self._authorization(),
            "apns-topic": topic,
            "apns-push-type": kind,
            "apns-priority": "10",
            "apns-expiration": str(expiration),
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        base = PRODUCTION if env == "production" else SANDBOX
        try:
            response = await self._client.post(f"{base}/3/device/{token}", json=payload, headers=headers)
        except httpx.HTTPError as err:
            log.warning("push to %s (%s) failed: %s", token[:8], env, err)
            return SendResult(False, 0, f"{type(err).__name__}: {err}"[:200])
        if response.status_code == 200:
            return SendResult(True, 200, None, env)
        reason: str | None = None
        try:
            reason = response.json().get("reason")
        except ValueError:
            reason = None
        reason = reason or response.text[:100] or "error"
        if reason == "ExpiredProviderToken":  # the clock moved: a fresh token next time
            self._token = None
        log.warning("push to %s (%s, %s) refused: %s %s", token[:8], env, kind, response.status_code, reason)
        return SendResult(False, response.status_code, reason, env)


def sender_from_env() -> ApnsSender | None:
    """The sender for the key `hubctl push apple` put on this hub; None until then."""
    config = ApnsConfig.from_env()
    return ApnsSender(config) if config is not None else None
