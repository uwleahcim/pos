"""The Apple push sender: the token it signs, the headers it sends, and what it makes of Apple's answers."""

from __future__ import annotations

import asyncio
import base64
import json

import httpx
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from pos.push.apns import PRODUCTION, SANDBOX, ApnsConfig, ApnsSender, provider_token, sender_from_env

TOKEN = "ab" * 32
NOW = 1_730_000_000.0


def make_key() -> tuple[bytes, ec.EllipticCurvePublicKey]:
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return pem, key.public_key()


def _unb64(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


# --- the provider token ------------------------------------------------------------------------------------------


def test_the_provider_token_is_es256_over_the_key_id_and_the_team():
    pem, public = make_key()
    token = provider_token(pem, "ABC123DEFG", "TEAM456789", 1_730_000_000)
    header, claims, signature = token.split(".")
    assert json.loads(_unb64(header)) == {"alg": "ES256", "kid": "ABC123DEFG"}
    assert json.loads(_unb64(claims)) == {"iss": "TEAM456789", "iat": 1_730_000_000}
    raw = _unb64(signature)
    assert len(raw) == 64  # r and s, 32 bytes each, not DER
    r, s = int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")
    public.verify(encode_dss_signature(r, s), f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))


def test_a_key_that_is_not_apples_kind_is_refused():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    with pytest.raises(ValueError, match="EC"):
        provider_token(pem, "ABC123DEFG", "TEAM456789", 0)


# --- the key on the hub ---------------------------------------------------------------------------------------------


def test_the_key_comes_from_the_environment_or_there_is_none(tmp_path):
    assert ApnsConfig.from_env({}) is None
    key = tmp_path / "AuthKey_ABC123DEFG.p8"
    key.write_bytes(b"pem bytes")
    env = {"POS_APNS_KEY": str(key), "POS_APNS_KEY_ID": "ABC123DEFG", "POS_APNS_TEAM_ID": "TEAM456789"}
    assert ApnsConfig.from_env(env) == ApnsConfig(b"pem bytes", "ABC123DEFG", "TEAM456789", "org.chinasky.posApp")
    other = ApnsConfig.from_env({**env, "POS_APNS_BUNDLE_ID": "org.example.pos"})
    assert other is not None and other.bundle_id == "org.example.pos"
    assert ApnsConfig.from_env({"POS_APNS_KEY": str(key), "POS_APNS_KEY_ID": "ABC123DEFG"}) is None  # no team
    assert ApnsConfig.from_env({**env, "POS_APNS_KEY": str(tmp_path / "missing.p8")}) is None


def test_without_a_key_there_is_no_sender(monkeypatch):
    monkeypatch.delenv("POS_APNS_KEY", raising=False)
    assert sender_from_env() is None


# --- sending -------------------------------------------------------------------------------------------------------


class Apple:
    """Apple's push service as a mock transport: answers by environment and token, BadDeviceToken otherwise."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.answers: dict[tuple[str, str], tuple[int, dict[str, str]]] = {}
        self.failing = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.failing:
            raise httpx.ConnectError("no route to apple")
        env = "production" if request.url.host == "api.push.apple.com" else "sandbox"
        token = request.url.path.rsplit("/", 1)[1]
        status, body = self.answers.get((env, token), (400, {"reason": "BadDeviceToken"}))
        return httpx.Response(status, json=body)


def sender(apple: Apple, clock=None) -> ApnsSender:
    pem, _ = make_key()
    config = ApnsConfig(pem, "ABC123DEFG", "TEAM456789", "org.chinasky.posApp")
    return ApnsSender(config, transport=httpx.MockTransport(apple), clock=clock or (lambda: NOW))


def send(apple: Apple, *sends, clock=None):
    """Runs the sends on one sender; each is (token, payload, kwargs)."""

    async def go():
        s = sender(apple, clock)
        try:
            return [await s.send(token, payload, **kwargs) for token, payload, kwargs in sends]
        finally:
            await s.close()

    return asyncio.run(go())


def test_a_voip_push_goes_to_production_with_apples_headers():
    apple = Apple()
    apple.answers[("production", TOKEN)] = (200, {})
    [result] = send(apple, (TOKEN, {"kind": "ring"}, {"kind": "voip"}))
    assert (result.ok, result.status, result.env, result.reason) == (True, 200, "production", None)
    [request] = apple.requests
    assert str(request.url) == f"{PRODUCTION}/3/device/{TOKEN}"
    assert request.headers["apns-topic"] == "org.chinasky.posApp.voip"
    assert request.headers["apns-push-type"] == "voip"
    assert request.headers["apns-priority"] == "10"
    assert request.headers["apns-expiration"] == "0"
    assert request.headers["authorization"].startswith("bearer ey")
    assert "apns-collapse-id" not in request.headers
    assert json.loads(request.content) == {"kind": "ring"}


def test_an_alert_carries_the_bundle_topic_a_collapse_id_and_an_expiration():
    apple = Apple()
    apple.answers[("production", TOKEN)] = (200, {})
    payload = {"aps": {"alert": "Phone 200 picked up"}}
    kwargs = {"kind": "alert", "collapse_id": "1730000000.123:200", "expiration": 1_730_000_060}
    [result] = send(apple, (TOKEN, payload, kwargs))
    assert result.ok
    [request] = apple.requests
    assert request.headers["apns-topic"] == "org.chinasky.posApp"
    assert request.headers["apns-push-type"] == "alert"
    assert request.headers["apns-collapse-id"] == "1730000000.123:200"
    assert request.headers["apns-expiration"] == "1730000060"


def test_a_development_builds_token_is_found_on_the_sandbox_and_remembered():
    apple = Apple()
    apple.answers[("sandbox", TOKEN)] = (200, {})
    first, second = send(apple, (TOKEN, {}, {"kind": "voip"}), (TOKEN, {}, {"kind": "voip", "env": "sandbox"}))
    assert (first.ok, first.env) == (True, "sandbox")
    assert [r.url.host for r in apple.requests[:2]] == ["api.push.apple.com", "api.sandbox.push.apple.com"]
    assert (second.ok, second.env) == (True, "sandbox")
    assert len(apple.requests) == 3 and str(apple.requests[2].url).startswith(SANDBOX)


def test_a_token_that_moved_to_the_other_environment_is_found_there():
    apple = Apple()
    apple.answers[("production", TOKEN)] = (200, {})
    [result] = send(apple, (TOKEN, {}, {"kind": "alert", "env": "sandbox"}))  # the app was reinstalled from the store
    assert (result.ok, result.env) == (True, "production")
    assert [r.url.host for r in apple.requests] == ["api.sandbox.push.apple.com", "api.push.apple.com"]


def test_a_token_apple_no_longer_knows_is_gone_and_not_tried_elsewhere():
    apple = Apple()
    apple.answers[("production", TOKEN)] = (410, {"reason": "Unregistered"})
    [result] = send(apple, (TOKEN, {}, {"kind": "voip"}))
    assert (result.ok, result.status, result.reason, result.gone) == (False, 410, "Unregistered", True)
    assert len(apple.requests) == 1


def test_a_refusal_that_is_not_about_the_token_is_not_retried_on_the_sandbox():
    apple = Apple()
    apple.answers[("production", TOKEN)] = (403, {"reason": "InvalidProviderToken"})
    [result] = send(apple, (TOKEN, {}, {"kind": "voip"}))
    assert (result.ok, result.status, result.reason, result.gone) == (False, 403, "InvalidProviderToken", False)
    assert len(apple.requests) == 1


def test_a_network_failure_is_a_failed_send_not_an_exception():
    apple = Apple()
    apple.failing = True
    [result] = send(apple, (TOKEN, {}, {"kind": "voip"}))
    assert not result.ok and result.status == 0 and result.env is None
    assert result.reason is not None and result.reason.startswith("ConnectError")


def test_the_provider_token_lives_fifty_minutes_and_is_dropped_when_apple_says_it_expired():
    apple = Apple()
    apple.answers[("production", TOKEN)] = (200, {})
    clock = [NOW]

    async def go():
        s = sender(apple, lambda: clock[0])
        try:
            await s.send(TOKEN, {}, kind="voip")
            await s.send(TOKEN, {}, kind="voip")
            clock[0] += 51 * 60
            await s.send(TOKEN, {}, kind="voip")
            apple.answers[("production", TOKEN)] = (403, {"reason": "ExpiredProviderToken"})
            assert not (await s.send(TOKEN, {}, kind="voip")).ok
            apple.answers[("production", TOKEN)] = (200, {})
            await s.send(TOKEN, {}, kind="voip")
            return s.status()
        finally:
            await s.close()

    status = asyncio.run(go())
    auths = [r.headers["authorization"] for r in apple.requests]
    assert auths[0] == auths[1] != auths[2]  # reused, then renewed after fifty minutes
    assert auths[2] == auths[3] != auths[4]  # signed again after Apple refused it
    assert (status["sent"], status["failed"], status["last_error"]) == (4, 1, "403 ExpiredProviderToken")
    assert status["by_env"] == {"production": 4} and status["last_sent"] == int(clock[0] * 1000)
    assert (status["configured"], status["bundle"], status["key_id"]) == (True, "org.chinasky.posApp", "ABC123DEFG")
