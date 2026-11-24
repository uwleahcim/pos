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

from ..keys import MAPS, MAPS_GOOGLE, ONLINE, PUSH_APPLE, SLOTS, HubKeys, UnknownKey
from ..maps import Lookups, fallback_from_env, maps_from_env
from ..online.gloriafood import source_from_env
from ..online.service import OnlineOrders
from ..push.apns import ApnsConfig, ApnsSender
from ..push.relay import PushRelay
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
    wanted = set(SLOTS if names is None else names)
    env = await run_in_threadpool(keys.environ)
    if wanted & {MAPS, MAPS_GOOGLE}:
        lookups: Lookups = app.state.lookups
        lookups.use(maps_from_env(env), fallback_from_env(env))
        app.state.feed.changed("settings")  # the delivery fee and live traffic say what the hub can look up
    if ONLINE in wanted:
        online: OnlineOrders = app.state.online
        # not in the middle of a round, which may be waiting for GloriaFood: off the loop
        await run_in_threadpool(online.use, source_from_env(env))
        if app.state.asks_online:
            online.start()  # nothing where the round already runs, and nothing without a key
        app.state.feed.changed("online")  # the screens say whether the hub asks
    if PUSH_APPLE in wanted:
        relay: PushRelay = app.state.relay
        fresh = await run_in_threadpool(sender_for, keys)
        old, relay.sender = relay.sender, fresh
        if old is not None:
            await old.close()
    app.state.keys_mark = await run_in_threadpool(keys.mark)


async def watch_keys(app: FastAPI, every: float = WATCH_SECONDS) -> None:
    """For as long as the API runs: when the stored keys are not the ones this hub last put to work, they are
    put to work. A hub that cannot read its database for a while tries again at the next turn."""
    while True:
        await asyncio.sleep(every)
        try:
            keys: HubKeys = app.state.keys
            if await run_in_threadpool(keys.mark) != app.state.keys_mark:
                await use_keys(app)
                log.warning("hub keys: they changed under this hub; the ones in force now are in use")
        except asyncio.CancelledError:
            raise
        except Exception as err:  # noqa: BLE001 - never the last look
            log.warning("hub keys: could not look whether they changed (%s)", type(err).__name__)


def add_hub_keys(app: FastAPI) -> None:
    def said() -> dict[str, Any]:
        keys: HubKeys = app.state.keys
        return {"keys": keys.views(), "kept": keys.vault.kept}

    def slot_of(name: str) -> str:
        if name not in SLOTS:
            raise HTTPException(404, {"error": "unknown_key", "message": "this hub holds no key of that name"})
        return name

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
