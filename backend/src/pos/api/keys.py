"""The hub's keys on the wire. What is kept and how is `pos.keys`; these are the calls (docs/hub-keys.md).

Every call is a manager's (the token from `/admin/session`): no setting hands them out.

- `GET /hub/keys`: every key the hub can hold, as a screen may see it (`pos.keys.HubKeys.views`): `keys`, each
  with its `name` (`maps`, `maps_google`, `online`, `push_apple`), whether one is in force (`set`), where
  from (`source`: `app`, `hub` for the hub's own file, or null), its last characters (`ending`), Apple's ids
  (`shown`), who touched it in the app last and when (`by`, `at_ms`), `removed` and `unreadable`. And
  `kept`: false on a hub that has nowhere to keep its sealing secret, where a key typed in the app lasts
  until the hub restarts. No answer of any call here has a key in it.
- `PUT /hub/keys/{name}`: a manager typed one: `{"key": "..."}`, and for Apple's `key` is the text of the
  .p8 file, with `key_id`, `team_id` and, if it is not the usual one, `bundle_id`. It is checked, sealed,
  stored, and in force at once: the hub is not restarted. Answers like the `GET`. 422 `bad_value` with words
  that say what is wrong and never what was typed; 404 `unknown_key`; 503 `read_only` on a standby.
- `DELETE /hub/keys/{name}`: removed: none is in force, also where the hub's own file still names one.
  Answers like the `GET`.

**GloriaFood's accounts** (`pos.online.accounts`: a restaurant with two websites there, and one it tests
with). The first is the key `online` above. The others are made, named and taken away here, a manager's
calls like the rest:

- `GET /hub/keys` also gives `online_accounts`: every account, the first account first, each with its `id`,
  its `name`, whether it is the one for testing (`test`) and its `key` as above (the first's is the key
  `online`; another's is named `online:<id>`).
- `POST /hub/online/accounts`: another account: `{"name": "Sushi site", "key": "...", "test": false}`. The key
  is checked before anything is made. Answers like the `GET`, with the new account's `id` as `added`. 422
  `bad_value` for a name that is missing, too long or taken, for a key that does not look like one, and for
  more accounts than a hub asks.
- `PUT /hub/online/accounts/{id}`: its name, or whether it is for testing: `{"name": "...", "test": true}`,
  either left out to keep it. The first account (`main`) is named here too. 404 `unknown_account`.
- `PUT /hub/keys/online:{id}` and `DELETE /hub/keys/online:{id}`: its key replaced, and its key removed
  while the account stays, as for any key.
- `DELETE /hub/online/accounts/{id}`: the account is gone, and its key with it: the hub stops asking it. The
  orders it brought stay as they are. 409 `first_account` for `main`: that one stays, with or without a key.

A key changes the service that uses it in place (`use_keys`): the map lookups keep the day's counts, the
online orders start asking (or stop) and Apple's sender is exchanged. A hub also looks once a minute whether
the keys changed under it (`watch_keys`): typed on the other hub of the location, or taken back by `hubctl`.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Iterable
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from ..keys import MAPS, MAPS_GOOGLE, ONLINE, PUSH_APPLE, SLOTS, HubKeys, UnknownKey, slot_for
from ..maps import Lookups, fallback_from_env, maps_from_env
from ..online.accounts import MAIN, SETTING, Account, account_of_slot, accounts_of, clean_accounts, name_of, new_id
from ..online.gloriafood import GloriaFood
from ..online.service import OnlineOrders
from ..push.apns import ApnsConfig, ApnsSender
from ..push.relay import PushRelay
from ..settings import SettingStore
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

log = logging.getLogger(__name__)

WATCH_SECONDS = 60.0
"""How often a hub looks whether the keys changed under it."""
TYPED_MOST = 16_000
"""The most a call may carry in one box: Apple's key file is a few hundred letters."""


class KeyIn(BaseModel):
    """What a manager typed for one key. No limits are set here: a refusal for a box that is too long would
    hand the box back in its words, and nothing typed here is ever handed back."""

    key: str = ""
    key_id: str = Field("", description="Apple's key: the ten letters and digits in the file's name")
    team_id: str = Field("", description="Apple's key: the team it belongs to")
    bundle_id: str = Field("", description="Apple's key: the app it pushes to, when not the usual one")


class AccountIn(BaseModel):
    """A further account with GloriaFood: what the restaurant calls it, its key for asking, and whether it
    is the one the restaurant only tests with. To change one, what is left out stays as it is."""

    name: str | None = None
    key: str = ""
    test: bool | None = None


def online_setup(keys: HubKeys, settings: SettingStore) -> tuple[list[GloriaFood], list[Account]]:
    """What the hub asks GloriaFood with: a source for every account that has a key in force, and the
    accounts as the restaurant named them."""
    accounts = accounts_of(settings.get(SETTING))
    sources = []
    for account in accounts:
        data = keys.data(account.slot)
        if data is not None:
            sources.append(GloriaFood(data["key"], account=account.id))
    return sources, accounts


def keys_mark(keys: HubKeys, settings: SettingStore) -> str:
    """Changes whenever a key does, or an account of GloriaFood's: what a hub holds against what it last
    put to work."""
    named = ";".join(f"{a.id}:{a.name}:{a.test}" for a in accounts_of(settings.get(SETTING)))
    return f"{keys.mark()}|{named}"


def sender_for(keys: HubKeys) -> ApnsSender | None:
    """Apple's sender for the key in force, or None where the hub has none."""
    data = keys.data(PUSH_APPLE)
    if data is None:
        return None
    return ApnsSender(ApnsConfig(data["key"].encode(), data["key_id"], data["team_id"], data["bundle_id"]))


async def use_keys(app: FastAPI, names: Iterable[str] | None = None) -> None:
    """Puts the keys in force to work, all of them or the ones named: after one was typed or removed, and
    when the keys were found changed. The services are changed where they stand, since the calls that use
    them hold on to them."""
    keys: HubKeys = app.state.keys
    # a further account's key (`online:<id>`) is GloriaFood's like the first
    wanted = {ONLINE if account_of_slot(name) else name for name in (SLOTS if names is None else names)}
    env = await run_in_threadpool(keys.environ)
    if wanted & {MAPS, MAPS_GOOGLE}:
        lookups: Lookups = app.state.lookups
        lookups.use(maps_from_env(env), fallback_from_env(env))
        app.state.feed.changed("settings")  # the delivery fee and live traffic say what the hub can look up
    if ONLINE in wanted:
        online: OnlineOrders = app.state.online
        # not in the middle of a round, which may be waiting for GloriaFood: off the loop
        sources, accounts = await run_in_threadpool(online_setup, keys, app.state.settings)
        await run_in_threadpool(online.use, sources, accounts)
        if app.state.asks_online:
            online.start()  # nothing where the round already runs, and nothing without a key
        app.state.feed.changed("online")  # the screens say whether the hub asks
    if PUSH_APPLE in wanted:
        relay: PushRelay = app.state.relay
        fresh = await run_in_threadpool(sender_for, keys)
        old, relay.sender = relay.sender, fresh
        if old is not None:
            await old.close()
    app.state.keys_mark = await run_in_threadpool(keys_mark, keys, app.state.settings)


async def watch_keys(app: FastAPI, every: float = WATCH_SECONDS) -> None:
    """For as long as the API runs: when the stored keys are not the ones this hub last put to work, they are
    put to work. A hub that cannot read its database for a while tries again at the next turn."""
    while True:
        await asyncio.sleep(every)
        try:
            keys: HubKeys = app.state.keys
            if await run_in_threadpool(keys_mark, keys, app.state.settings) != app.state.keys_mark:
                await use_keys(app)
                log.warning("hub keys: they changed under this hub; the ones in force now are in use")
        except asyncio.CancelledError:
            raise
        except Exception as err:  # noqa: BLE001 - never the last look
            log.warning("hub keys: could not look whether they changed (%s)", type(err).__name__)


def add_hub_keys(app: FastAPI) -> None:
    def accounts() -> list[Account]:
        return accounts_of(app.state.settings.get(SETTING))

    def said() -> dict[str, Any]:
        keys: HubKeys = app.state.keys
        return {
            "keys": keys.views(),
            "kept": keys.vault.kept,
            "online_accounts": [{**account.about(), "key": keys.view(account.slot)} for account in accounts()],
        }

    def slot_of(name: str) -> str:
        """A key this hub holds: one of its own, or the key of an account of GloriaFood's that there is."""
        account = account_of_slot(name)
        known = name in SLOTS or (slot_for(name) is not None and any(a.id == account for a in accounts()))
        if not known:
            raise HTTPException(404, {"error": "unknown_key", "message": "this hub holds no key of that name"})
        return name

    def account_of(account: str) -> Account:
        found = next((a for a in accounts() if a.id == account), None)
        if found is None:
            raise HTTPException(404, {"error": "unknown_account", "message": "there is no such account"})
        return found

    def keep(listed: list[Account]) -> None:
        """Stores the accounts, checked: 422 in words for what is wrong with them."""
        try:
            cleaned = clean_accounts({"accounts": [account.about() for account in listed]})
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from None
        try:
            app.state.settings.put(SETTING, cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err

    @app.get("/hub/keys")
    def read_hub_keys(authorization: str | None = Header(None)) -> dict[str, Any]:
        """The keys this hub can hold and how each stands. Never a key."""
        manager_from(app.state.tokens, authorization)
        return said()

    @app.put("/hub/keys/{name}")
    async def write_hub_key(name: str, body: KeyIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager typed a key: checked, sealed, stored and in force at once."""
        grant = manager_from(app.state.tokens, authorization)
        slot_of(name)
        typed = body.model_dump()
        if any(len(part) > TYPED_MOST for part in typed.values()):
            raise HTTPException(422, {"error": "bad_value", "message": "that is far too long to be a key"})
        keys: HubKeys = app.state.keys
        try:
            await run_in_threadpool(lambda: keys.set(name, typed, by=grant.name))
        except UnknownKey as err:
            raise HTTPException(404, {"error": "unknown_key"}) from err
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from None
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        await use_keys(app, [name])
        return await run_in_threadpool(said)

    @app.delete("/hub/keys/{name}")
    async def remove_hub_key(name: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager removed a key: none is in force from now on."""
        grant = manager_from(app.state.tokens, authorization)
        slot_of(name)
        keys: HubKeys = app.state.keys
        try:
            await run_in_threadpool(lambda: keys.remove(name, by=grant.name))
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        await use_keys(app, [name])
        return await run_in_threadpool(said)

    @app.post("/hub/online/accounts")
    async def add_online_account(body: AccountIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Another account with GloriaFood: named, its key checked, sealed and asked with at once."""
        grant = manager_from(app.state.tokens, authorization)
        if len(body.key) > TYPED_MOST:
            raise HTTPException(422, {"error": "bad_value", "message": "that is far too long to be a key"})
        keys: HubKeys = app.state.keys

        def add() -> str:
            listed = accounts()
            try:
                name = name_of(body.name or "")
                # the key before the account: an account is not made for a key that is none
                SLOTS[ONLINE].clean({"key": body.key})
            except ValueError as err:
                raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from None
            made = Account(new_id([account.id for account in listed]), name, body.test is True)
            keep([*listed, made])
            try:
                keys.set(made.slot, {"key": body.key}, by=grant.name)
            except ReadOnlyError as err:
                raise HTTPException(503, {"error": "read_only"}) from err
            return made.id

        added = await run_in_threadpool(add)
        await use_keys(app, [ONLINE])
        return {**await run_in_threadpool(said), "added": added}

    @app.put("/hub/online/accounts/{account}")
    async def change_online_account(
        account: str, body: AccountIn, authorization: str | None = Header(None)
    ) -> dict[str, Any]:
        """What an account is called, or whether it is the one for testing. Its key is not touched."""
        manager_from(app.state.tokens, authorization)

        def change() -> None:
            was = account_of(account)
            try:
                name = was.name if body.name is None else name_of(body.name)
            except ValueError as err:
                raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from None
            now = Account(was.id, name, was.test if body.test is None else body.test)
            keep([now if a.id == was.id else a for a in accounts()])

        await run_in_threadpool(change)
        await use_keys(app, [ONLINE])
        return await run_in_threadpool(said)

    @app.delete("/hub/online/accounts/{account}")
    async def remove_online_account(account: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """An account is gone, and its key with it: the hub stops asking it. Its orders stay."""
        grant = manager_from(app.state.tokens, authorization)
        keys: HubKeys = app.state.keys

        def remove() -> None:
            gone = account_of(account)
            if gone.id == MAIN:
                message = "the first account stays: remove its key instead"
                raise HTTPException(409, {"error": "first_account", "message": message})
            keep([a for a in accounts() if a.id != gone.id])
            try:
                keys.forget(gone.slot, by=grant.name)
            except ReadOnlyError as err:
                raise HTTPException(503, {"error": "read_only"}) from err

        await run_in_threadpool(remove)
        await use_keys(app, [ONLINE])
        return await run_in_threadpool(said)
