"""The hub's keys for the services outside the building, as a manager types them in the app.

A hub asks a map service how far a delivery is and what the letters typed in an address box could become,
asks GloriaFood for the website's orders and wakes a locked iPhone through Apple. Each of those wants a key,
and until now each key was put on the hub from its terminal (`hubctl maps key`, `hubctl online key`,
`hubctl push apple`), into `/opt/pos/.env`. This module lets a manager type the same keys in the app
(Location, Keys and connections; docs/hub-keys.md). The Twilio account the texts to customers go out with
(`texts`, docs/texts.md) is kept here too, and is typed in the app only. So is the restaurant's key for
Shipday (`shipday`, docs/shipday.md), which the hub reads the deliveries and the drivers there with.

What is kept, and how:

- A key typed in the app is **sealed** before it is stored (`Vault`): what the database holds, and so what a
  backup of it holds, opens only with the hub's own secret. That is `POS_SECRET` where the hub has one (the
  same on every hub of a location, so a second hub opens what the first sealed), and a file of the hub's
  own otherwise (`/keys/vault.key`, a volume that is not in any backup of the database).
- Beside the seal, in the clear: the key's last four characters (none for a short key), who typed it and
  when, and for Apple's key the ids that are no secret. That is all a screen is ever told (`HubKeys.views`).
  The key itself goes one way: into the hub.
- **Removed in the app** is kept too (a row with no seal), because the hub's own file may still name a key:
  what the app said last stands.

Which key is in force (`HubKeys.data`, `HubKeys.environ`): the one typed in the app when there is a row for
it, else the one in the hub's own file. `hubctl` deletes the app's row when it is told a key from the
terminal, so of the two ways the one used last wins.

**GloriaFood's key comes in several**: a restaurant with more than one website there, or an account it
tests with, has a key for each (`pos.online.accounts`). The first is the slot `online`, as it always was;
every other account's is kept under `online:<id>`, typed in the app only, and gone with its account.

**Two of the keys are used by a program beside the API**: the key GloriaFood's own pushes carry
(`online_push`), which the push door checks, and the Cloudflare Tunnel's token (`online_tunnel`), which the
tunnel runs with. They are kept here like the rest, and the API hands each of the two programs what it
needs whenever one changes (`pos.online.wayin`), so neither is restarted and neither is started by the API.

Nothing here is written to a log but who set or removed which key. No message of this module carries what
was typed.
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import re
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from cryptography.fernet import Fernet, InvalidToken, MultiFernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from psycopg import errors
from psycopg.rows import tuple_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .online.accounts import MAIN, account_of_slot
from .sync.pgstore import ReadOnlyError
from .twilio import clean as _clean_twilio

log = logging.getLogger(__name__)

VAULT_FILE = "/keys/vault.key"
"""Where a hub keeps the secret its seals open with, when it has no `POS_SECRET` (`POS_KEYS_FILE` names
another place). The `pos-keys` volume in infra/hub/docker-compose.yml."""
ENDING = 4
"""How many of a key's last characters a screen is shown, to tell one key from another."""
ENDING_FROM = 16
"""A key shorter than this shows none of itself: four of a dozen characters would be a third of it."""
APPLE_BUNDLE = "org.chinasky.posApp"
"""The app Apple's key pushes to, unless another is typed (`pos.push.apns`)."""

MAP_KEY = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
MAPBOX_TOKEN = re.compile(r"^[pst]k\.[A-Za-z0-9_-]{20,600}\.[A-Za-z0-9_-]{10,200}$")
"""A Mapbox access token: `pk.` (a public one, which will do), `sk.` or `tk.`, and two runs of letters and
digits with a dot between them."""
AZURE_KEY = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
"""The key of an Azure Maps account, its primary or its secondary: one run of letters and digits."""
ONLINE_KEY = re.compile(r"^[A-Za-z0-9._~+/=-]{8,200}$")
PUSH_KEY = re.compile(r"^[A-Za-z0-9._~+/=-]{16,200}$")
"""The key GloriaFood's pushes carry: what `hubctl online push key` takes."""
SHIPDAY_KEY = re.compile(r"^[A-Za-z0-9._~+/=-]{16,200}$")
"""Shipday's API key (My Account in its Dispatch Dashboard): letters and digits with a dot in the middle."""
TUNNEL_TOKEN = re.compile(r"^[A-Za-z0-9_=+/-]{40,4000}$")
"""A Cloudflare Tunnel's token: one long run of letters and digits. What `hubctl online tunnel token` takes."""
TUNNEL_ID = re.compile(r"^[0-9A-Fa-f][0-9A-Fa-f-]{7,63}$")
APPLE_ID = re.compile(r"^[A-Z0-9]{10}$")
BUNDLE_ID = re.compile(r"^[A-Za-z0-9.-]{1,155}$")
_PEM_BODY = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----(.*?)-----END [A-Z ]*PRIVATE KEY-----", re.DOTALL)


# --- what each key is ------------------------------------------------------------------------------------------


def _one_key(pattern: re.Pattern[str], looks_like: str) -> Callable[[Mapping[str, Any]], dict[str, str]]:
    def clean(typed: Mapping[str, Any]) -> dict[str, str]:
        key = "".join(str(typed.get("key") or "").split())  # a paste often brings a line end with it
        if not key:
            raise ValueError("no key was typed")
        if not pattern.fullmatch(key):
            raise ValueError(f"that does not look like a key ({looks_like})")
        return {"key": key}

    return clean


def _one_from_env(name: str) -> Callable[[Mapping[str, str]], dict[str, str] | None]:
    def read(env: Mapping[str, str]) -> dict[str, str] | None:
        key = (env.get(name) or "").strip()
        return {"key": key} if key else None

    return read


def apple_pem(text: str) -> str:
    """Apple's key file (`AuthKey_XXXXXXXXXX.p8`) as it was pasted, put back the way the file has it. A paste
    into a one-line box loses the line ends, and one copied out of a mail may have spaces in it: only the
    letters between the two dashed lines count. ValueError when what is left is not a key Apple signs pushes
    with (a P-256 private key). The words never say what was pasted."""
    found = _PEM_BODY.search(text)
    body = "".join((found.group(1) if found else text).split())
    try:
        raw = base64.b64decode(body, validate=True)
    except (binascii.Error, ValueError):
        raw = b""
    if not raw:
        raise ValueError("that is not Apple's key file: paste everything in the .p8 file, the dashed lines too")
    wrapped = "\n".join(body[i : i + 64] for i in range(0, len(body), 64))
    pem = f"-----BEGIN PRIVATE KEY-----\n{wrapped}\n-----END PRIVATE KEY-----\n"
    try:
        key = load_pem_private_key(pem.encode(), password=None)
    except (ValueError, TypeError):
        # `from None`: whatever the library says of the key goes no further
        raise ValueError(
            "that is not Apple's key file: paste everything in the .p8 file, the dashed lines too"
        ) from None
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("that is a private key, but not the kind Apple gives for pushes (a .p8 from Keys)")
    return pem


def _clean_apple(typed: Mapping[str, Any]) -> dict[str, str]:
    pem = apple_pem(str(typed.get("key") or ""))
    key_id = str(typed.get("key_id") or "").strip().upper()
    team_id = str(typed.get("team_id") or "").strip().upper()
    bundle_id = str(typed.get("bundle_id") or "").strip() or APPLE_BUNDLE
    if not APPLE_ID.fullmatch(key_id):
        raise ValueError("the key id is the ten letters and digits in the file's name, AuthKey_<key id>.p8")
    if not APPLE_ID.fullmatch(team_id):
        raise ValueError("the team id is ten letters and digits (Membership details in the Apple developer account)")
    if not BUNDLE_ID.fullmatch(bundle_id):
        raise ValueError("the bundle id is the app's own name at Apple, such as org.chinasky.posApp")
    return {"key": pem, "key_id": key_id, "team_id": team_id, "bundle_id": bundle_id}


def _apple_from_env(env: Mapping[str, str]) -> dict[str, str] | None:
    from .push.apns import ApnsConfig

    config = ApnsConfig.from_env(dict(env))
    if config is None:
        return None
    return {
        "key": config.key_pem.decode("ascii", "replace"),
        "key_id": config.key_id,
        "team_id": config.team_id,
        "bundle_id": config.bundle_id,
    }


def tunnel_token(text: str) -> str:
    """The tunnel's token out of what was pasted. Cloudflare shows it inside a command (`cloudflared service
    install eyJ...`), and the whole command is what gets copied: the one word of it that is long enough to
    be a token is the token. A token that picked up line ends on its way is put together again, from the
    word that starts the way a token does (`eyJ`) to the end. ValueError when no token is in it; the words
    never say what was pasted."""
    words = text.split()
    if not words:
        raise ValueError("no token was typed")
    long = [word for word in words if TUNNEL_TOKEN.fullmatch(word)]
    if len(long) == 1:
        return long[0]
    starts = [n for n, word in enumerate(words) if word.startswith("eyJ")]
    if len(starts) == 1:
        joined = "".join(words[starts[0] :])
        if TUNNEL_TOKEN.fullmatch(joined):
            return joined
    raise ValueError(
        "that does not look like a tunnel's token (one long run of letters and digits, usually starting with eyJ)"
    )


def tunnel_of(token: str) -> str:
    """The start of the tunnel's own id at Cloudflare, which its token carries in the clear and which is no
    secret (it is in the tunnel's address): what a screen shows to tell one tunnel from another. Nothing
    for a token that does not read that way; such a token is kept all the same."""
    for decode in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            held = json.loads(decode(token + "=" * (-len(token) % 4)))
        except (binascii.Error, ValueError):
            continue
        ident = held.get("t") if isinstance(held, dict) else None
        if isinstance(ident, str) and TUNNEL_ID.fullmatch(ident):
            return ident[:8]
    return ""


def _clean_tunnel(typed: Mapping[str, Any]) -> dict[str, str]:
    token = tunnel_token(str(typed.get("key") or ""))
    return {"key": token, "tunnel": tunnel_of(token)}


def _tunnel_from_env(env: Mapping[str, str]) -> dict[str, str] | None:
    token = (env.get("POS_TUNNEL_TOKEN") or "").strip()
    return {"key": token, "tunnel": tunnel_of(token)} if token else None


@dataclass(frozen=True)
class Slot:
    """One key the hub can hold. `env` are the names the hub's own file has it under (what `hubctl` writes);
    `clean` checks what a manager typed and gives what is kept (ValueError otherwise); `from_env` reads the
    same out of the hub's file; `to_env` says it the way that file would, for the code that reads its key
    from there; `shown` are the parts that are no secret."""

    name: str
    env: tuple[str, ...]
    clean: Callable[[Mapping[str, Any]], dict[str, str]]
    from_env: Callable[[Mapping[str, str]], dict[str, str] | None]
    to_env: Callable[[Mapping[str, str]], dict[str, str]] = field(default=lambda data: {})
    shown: tuple[str, ...] = ()


MAPS, MAPS_GOOGLE, ONLINE, PUSH_APPLE = "maps", "maps_google", "online", "push_apple"
MAPS_MAPBOX, MAPS_AZURE = "maps_mapbox", "maps_azure"
ONLINE_PUSH, ONLINE_TUNNEL = "online_push", "online_tunnel"
TEXTS = "texts"
SHIPDAY = "shipday"

SLOTS: dict[str, Slot] = {
    slot.name: slot
    for slot in (
        # the map service a delivery's distance is asked of (docs/delivery.md): `hubctl maps key`
        Slot(
            MAPS,
            ("POS_MAPS", "POS_MAPS_KEY"),
            _one_key(MAP_KEY, "letters and digits, 16 or more, no spaces"),
            _one_from_env("POS_MAPS_KEY"),
            lambda data: {"POS_MAPS": "geocodio", "POS_MAPS_KEY": data["key"]},
        ),
        # Google Maps, asked when the first gives no distance, and about the roads right now: `hubctl maps google`
        Slot(
            MAPS_GOOGLE,
            ("POS_MAPS_GOOGLE_KEY",),
            _one_key(MAP_KEY, "letters and digits, 16 or more, no spaces"),
            _one_from_env("POS_MAPS_GOOGLE_KEY"),
            lambda data: {"POS_MAPS_GOOGLE_KEY": data["key"]},
        ),
        # Mapbox and Azure Maps, asked for the list of addresses while one is typed when Google gives no answer
        # (docs/delivery.md, "A list of addresses while typing"). Typed in the app; no hubctl command sets them.
        Slot(
            MAPS_MAPBOX,
            ("POS_MAPS_MAPBOX_KEY",),
            _one_key(MAPBOX_TOKEN, "a Mapbox token starts with pk. and has no spaces"),
            _one_from_env("POS_MAPS_MAPBOX_KEY"),
            lambda data: {"POS_MAPS_MAPBOX_KEY": data["key"]},
        ),
        Slot(
            MAPS_AZURE,
            ("POS_MAPS_AZURE_KEY",),
            _one_key(AZURE_KEY, "letters and digits, 32 or more, no spaces"),
            _one_from_env("POS_MAPS_AZURE_KEY"),
            lambda data: {"POS_MAPS_AZURE_KEY": data["key"]},
        ),
        # GloriaFood's key for this restaurant, for asking after the website's orders: `hubctl online key`
        Slot(
            ONLINE,
            ("POS_GLORIAFOOD_KEY",),
            _one_key(ONLINE_KEY, "letters and digits, 8 or more, no spaces"),
            _one_from_env("POS_GLORIAFOOD_KEY"),
            lambda data: {"POS_GLORIAFOOD_KEY": data["key"]},
        ),
        # the key GloriaFood's own pushes of an order carry (docs/online-orders.md, "Push"), checked by the
        # push door and by the API behind it: `hubctl online push key`
        Slot(
            ONLINE_PUSH,
            ("POS_GLORIAFOOD_PUSH_KEY",),
            _one_key(PUSH_KEY, "letters and digits, 16 or more, no spaces"),
            _one_from_env("POS_GLORIAFOOD_PUSH_KEY"),
            lambda data: {"POS_GLORIAFOOD_PUSH_KEY": data["key"]},
        ),
        # the token of the Cloudflare Tunnel that brings those pushes in ("The way in" in the same guide):
        # `hubctl online tunnel token`
        Slot(
            ONLINE_TUNNEL,
            ("POS_TUNNEL_TOKEN",),
            _clean_tunnel,
            _tunnel_from_env,
            lambda data: {"POS_TUNNEL_TOKEN": data["key"]},
            shown=("tunnel",),
        ),
        # Apple's key for waking a locked iPhone or iPad (docs/push-relay.md): `hubctl push apple`
        Slot(
            PUSH_APPLE,
            ("POS_APNS_KEY", "POS_APNS_KEY_ID", "POS_APNS_TEAM_ID", "POS_APNS_BUNDLE_ID"),
            _clean_apple,
            _apple_from_env,
            shown=("key_id", "team_id", "bundle_id"),
        ),
        # The restaurant's Twilio account, which the texts to customers go out with (docs/texts.md): the Auth
        # Token is the key, and the account's own name and what the texts are sent from are no secret. Typed
        # in the app only: no hubctl command sets it, and the hub's own file never names it.
        Slot(
            TEXTS,
            (),
            _clean_twilio,
            lambda env: None,
            shown=("account", "sender", "key_sid"),
        ),
        # The restaurant's key for Shipday, which its deliveries and drivers are read with (docs/shipday.md).
        # Typed in the app only: no hubctl command sets it, and the hub's own file never names it.
        Slot(
            SHIPDAY,
            (),
            _one_key(SHIPDAY_KEY, "letters and digits, 16 or more, no spaces"),
            lambda env: None,
        ),
    )
}


def slot_for(name: str) -> Slot | None:
    """The key of that name: one of `SLOTS`, or the key of a further GloriaFood account (`online:<id>`), which
    is GloriaFood's key like the first and is in nobody's file. None for a name that is no key's."""
    slot = SLOTS.get(name)
    if slot is not None:
        return slot
    if account_of_slot(name) in (None, MAIN):
        return None
    first = SLOTS[ONLINE]
    return Slot(name, (), first.clean, lambda env: None)


def ending_of(key: str) -> str:
    """The last characters of a key, for a screen to tell one key from another by; none of a short one."""
    return key[-ENDING:] if len(key) >= ENDING_FROM else ""


def _ending(slot: Slot, data: Mapping[str, str]) -> str:
    # of Apple's key the key id is what tells one from another, and it is shown whole
    return "" if slot.shown else ending_of(data.get("key", ""))


# --- the seal ------------------------------------------------------------------------------------------------


class Vault:
    """Seals what a manager typed and opens it again. `secrets` are what it opens with, the first of them
    what it seals with; `kept` says whether a restart of the hub still opens today's seals."""

    def __init__(self, secrets: Sequence[bytes], *, kept: bool = True) -> None:
        self._fernet = MultiFernet([Fernet(secret) for secret in secrets])
        self.kept = kept

    def seal(self, data: Mapping[str, str]) -> bytes:
        return self._fernet.encrypt(json.dumps(dict(data), separators=(",", ":")).encode())

    def open(self, sealed: bytes) -> dict[str, str] | None:
        """What was sealed, or None for a seal another hub's secret made (or one that is damaged)."""
        try:
            data = json.loads(self._fernet.decrypt(bytes(sealed)))
        except (InvalidToken, ValueError, TypeError):
            return None
        return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else None


def _from_secret(secret: str) -> bytes:
    """The sealing secret a hub's `POS_SECRET` gives: the same on every hub that shares it."""
    derived = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"pos-hub-keys", info=b"vault v1").derive(secret.encode())
    return base64.urlsafe_b64encode(derived)


def _from_file(path: Path) -> bytes | None:
    """The hub's own sealing secret, made on first use and readable by the API's user alone. None where
    the place cannot be written (a laptop, a hub whose volume is missing)."""
    try:
        return _checked(path.read_bytes())
    except FileNotFoundError:
        pass
    except OSError:
        return None
    made = Fernet.generate_key()
    try:
        # the folder is the hub's volume: where there is none, nothing is made in its place
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:  # another worker made it in the same moment
        try:
            return _checked(path.read_bytes())
        except OSError:
            return None
    except OSError:
        return None
    with os.fdopen(fd, "wb") as f:
        f.write(made)
    return made


def _checked(raw: bytes) -> bytes | None:
    secret = raw.strip()
    try:
        Fernet(secret)
    except (ValueError, TypeError):
        return None
    return secret


def vault_from_env(environ: Mapping[str, str] | None = None) -> Vault:
    """The hub's vault: `POS_SECRET` first when the hub has one, then its own file. With neither (a laptop,
    the tests) a secret that lasts as long as the process: what is typed works until the restart, and
    `kept` says so."""
    env = os.environ if environ is None else environ
    secrets: list[bytes] = []
    shared = (env.get("POS_SECRET") or "").strip()
    if shared:
        secrets.append(_from_secret(shared))
    own = _from_file(Path((env.get("POS_KEYS_FILE") or "").strip() or VAULT_FILE))
    if own is not None:
        secrets.append(own)
    if secrets:
        return Vault(secrets)
    return Vault([Fernet.generate_key()], kept=False)


# --- what is stored --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Kept:
    """One key as the app left it: `sealed` is None when a manager removed it there."""

    name: str
    sealed: bytes | None
    ending: str = ""
    shown: Mapping[str, str] = field(default_factory=dict)
    by: str = ""
    at_ms: int = 0


class KeyStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgKeyStore`."""

    def __init__(self) -> None:
        self._rows: dict[str, Kept] = {}

    def all(self) -> dict[str, Kept]:
        return dict(self._rows)

    def put(self, kept: Kept) -> None:
        self._rows[kept.name] = kept

    def drop(self, name: str) -> None:
        """Forgets a key altogether, as if the app had never been told one: for a key whose account is gone."""
        self._rows.pop(name, None)

    def mark(self) -> str:
        """Changes whenever a row does: how a hub notices what was typed on another one."""
        rows = sorted(self.all().values(), key=_name)
        return ";".join(f"{row.name}:{row.at_ms}:{row.sealed is None}" for row in rows)


def _name(row: Kept) -> str:
    return row.name


SCHEMA = """
CREATE TABLE IF NOT EXISTS hub_key (
    name       TEXT PRIMARY KEY,
    sealed     BYTEA,
    ending     TEXT NOT NULL DEFAULT '',
    shown      JSONB NOT NULL DEFAULT '{}'::jsonb,
    by_name    TEXT NOT NULL DEFAULT '',
    at_ms      BIGINT NOT NULL DEFAULT 0
);
"""


class PgKeyStore(KeyStore):
    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def all(self) -> dict[str, Kept]:
        try:
            with self._pool.connection() as conn:
                rows = conn.execute("SELECT name, sealed, ending, shown, by_name, at_ms FROM hub_key").fetchall()
        except errors.UndefinedTable:  # a standby whose hub in charge is older than the keys
            return {}
        return {
            r[0]: Kept(r[0], bytes(r[1]) if r[1] is not None else None, r[2], dict(r[3] or {}), r[4], int(r[5]))
            for r in rows
        }

    def put(self, kept: Kept) -> None:
        try:
            with self._pool.connection() as conn:
                conn.execute(
                    """
                    INSERT INTO hub_key (name, sealed, ending, shown, by_name, at_ms) VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (name) DO UPDATE SET sealed = EXCLUDED.sealed, ending = EXCLUDED.ending,
                        shown = EXCLUDED.shown, by_name = EXCLUDED.by_name, at_ms = EXCLUDED.at_ms
                    """,
                    (kept.name, kept.sealed, kept.ending, Jsonb(dict(kept.shown)), kept.by, kept.at_ms),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err

    def drop(self, name: str) -> None:
        try:
            with self._pool.connection() as conn:
                conn.execute("DELETE FROM hub_key WHERE name = %s", (name,))
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err


def default_key_store() -> KeyStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    return PgKeyStore(dsn) if dsn else KeyStore()


# --- the keys as the hub uses them -----------------------------------------------------------------------------


class UnknownKey(KeyError):
    """No key of that name is one the hub holds."""


class HubKeys:
    """The keys in force on this hub, the app's over the hub's own file, and what a screen may be told of
    them. `environ` is the hub's own file as the process got it (its environment)."""

    def __init__(
        self,
        store: KeyStore | None = None,
        vault: Vault | None = None,
        *,
        environ: Mapping[str, str] | None = None,
        now: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.store = store if store is not None else KeyStore()
        self.vault = vault if vault is not None else Vault([Fernet.generate_key()], kept=False)
        self._environ = os.environ if environ is None else environ
        self._now = now

    def _slot(self, name: str) -> Slot:
        slot = slot_for(name)
        if slot is None:
            raise UnknownKey(name)
        return slot

    def _resolve(self, slot: Slot, row: Kept | None) -> tuple[str | None, dict[str, str] | None, bool]:
        """Where the key in force comes from (`app`, `hub` or nowhere), the key, and whether the app's own
        could not be opened here."""
        unreadable = False
        if row is not None:
            if row.sealed is None:
                return None, None, False  # removed in the app: the hub's own file is not asked
            opened = self.vault.open(row.sealed)
            if opened is not None and opened.keys() >= {"key", *slot.shown}:
                return "app", opened, False
            unreadable = True  # sealed by another hub: this one falls back on its own file
        own = slot.from_env(self._environ)
        return ("hub" if own is not None else None), own, unreadable

    def data(self, name: str) -> dict[str, str] | None:
        """The key in force, with what belongs to it (for Apple's: `key`, `key_id`, `team_id`,
        `bundle_id`), or None when the hub has none."""
        slot = self._slot(name)
        return self._resolve(slot, self.store.all().get(name))[1]

    def environ(self) -> dict[str, str]:
        """The hub's environment as it would read if the keys in force were all in its own file: what
        `pos.maps.lookups_from_env` and `pos.online.gloriafood.source_from_env` are handed, so a key typed
        in the app is read by the code that always read it from there."""
        env = dict(self._environ)
        rows = self.store.all()
        for slot in SLOTS.values():
            row = rows.get(slot.name)
            if row is None:
                continue
            source, data, _ = self._resolve(slot, row)
            if source == "hub":
                continue  # the app's could not be opened: the file's stays as it is
            for name in slot.env:
                env.pop(name, None)
            if data is not None:
                env.update(slot.to_env(data))
        return env

    def views(self) -> list[dict[str, Any]]:
        """Every key the hub can hold, as a screen may see it. For each: `set` (one is in force), `source`
        (`app`: typed in the app; `hub`: in the hub's own file, put there with hubctl; null: none),
        `ending` (its last characters, or nothing for a short one), `shown` (Apple's ids), who touched it
        in the app last and when (`by`, `at_ms`), whether that was to remove it (`removed`), and
        `unreadable`: it was typed in the app, but sealed by another hub, so this one cannot use it. Never
        the key."""
        rows = self.store.all()
        return [self._view(slot, rows.get(slot.name)) for slot in SLOTS.values()]

    def view(self, name: str) -> dict[str, Any]:
        slot = self._slot(name)
        return self._view(slot, self.store.all().get(name))

    def _view(self, slot: Slot, row: Kept | None) -> dict[str, Any]:
        source, data, unreadable = self._resolve(slot, row)
        mine = source == "app" and row is not None
        return {
            "name": slot.name,
            "set": data is not None,
            "source": source,
            "ending": row.ending if mine else (_ending(slot, data) if data is not None else ""),
            "shown": {part: data.get(part, "") for part in slot.shown} if data is not None else {},
            "by": row.by if row is not None else "",
            "at_ms": row.at_ms if row is not None else None,
            "removed": row is not None and row.sealed is None,
            "unreadable": unreadable,
        }

    def set(self, name: str, typed: Mapping[str, Any], *, by: str) -> dict[str, Any]:
        """A manager typed a key: checked (ValueError, in words that do not repeat it), sealed and stored.
        From now on it is the one in force, whatever the hub's own file says."""
        slot = self._slot(name)
        data = slot.clean(typed)
        row = Kept(
            name,
            self.vault.seal(data),
            _ending(slot, data),
            {part: data[part] for part in slot.shown},
            by,
            self._now(),
        )
        self.store.put(row)
        log.warning("hub keys: %s was set in the app by %s", name, by or "a manager")  # shown by hubctl logs
        return self._view(slot, row)

    def remove(self, name: str, *, by: str) -> dict[str, Any]:
        """A manager removed a key: none is in force, also where the hub's own file still names one."""
        slot = self._slot(name)
        row = Kept(name, None, "", {}, by, self._now())
        self.store.put(row)
        log.warning("hub keys: %s was removed in the app by %s", name, by or "a manager")
        return self._view(slot, row)

    def forget(self, name: str, *, by: str) -> None:
        """A further GloriaFood account is gone, and its key with it: nothing of it stays. Not for a key of
        `SLOTS`: the hub's own file may name one of those, so the app's word on it is kept (`remove`)."""
        if name in SLOTS or slot_for(name) is None:
            raise UnknownKey(name)
        self.store.drop(name)
        log.warning("hub keys: %s was removed with its account by %s", name, by or "a manager")

    def mark(self) -> str:
        return self.store.mark()


def keys_from_env() -> HubKeys:
    """The hub's keys: its database, its vault and its own file."""
    return HubKeys(default_key_store(), vault_from_env())


__all__ = [
    "APPLE_BUNDLE",
    "MAPS",
    "MAPS_AZURE",
    "MAPS_GOOGLE",
    "MAPS_MAPBOX",
    "ONLINE",
    "ONLINE_PUSH",
    "ONLINE_TUNNEL",
    "PUSH_APPLE",
    "SHIPDAY",
    "SLOTS",
    "TEXTS",
    "HubKeys",
    "Kept",
    "KeyStore",
    "PgKeyStore",
    "Slot",
    "UnknownKey",
    "Vault",
    "apple_pem",
    "default_key_store",
    "ending_of",
    "keys_from_env",
    "slot_for",
    "tunnel_of",
    "tunnel_token",
    "vault_from_env",
]
