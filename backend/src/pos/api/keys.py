"""The hub's keys on the wire. What is kept and how is `pos.keys`; these are the calls (docs/hub-keys.md).

Every call is a manager's (the token from `/admin/session`): no setting hands them out.

- `GET /hub/keys`: every key the hub can hold, as a screen may see it (`pos.keys.HubKeys.views`): `keys`, each
  with its `name` (`maps`, `maps_google`, `maps_mapbox`, `maps_azure`, `online`, `push_apple`, `texts`,
  `shipday`), whether one is in force (`set`), where
  from (`source`: `app`, `hub` for the hub's own file, or null), its last characters (`ending`), Apple's ids
  (`shown`), who touched it in the app last and when (`by`, `at_ms`), `removed` and `unreadable`. And
  `kept`: false on a hub that has nowhere to keep its sealing secret, where a key typed in the app lasts
  until the hub restarts. No answer of any call here has a key in it (the address for Twilio, below, is the
  one thing here that is to be kept to oneself).
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

**The way in for GloriaFood's pushes** (`pos.online.wayin`; docs/online-orders.md, "Push"). Its two secrets
are keys like the rest: `online_push`, the key a push must carry, and `online_tunnel`, the Cloudflare
Tunnel's token (pasted alone or inside the command Cloudflare shows; `shown.tunnel` is the start of the
tunnel's id, which is no secret). The push door and the tunnel are programs beside the API. It hands each
what it needs when a key changes, and neither is restarted.

- `GET /hub/keys` also gives `way_in`: `address` (the name GloriaFood sends to, as a manager typed it, or
  empty), `door` (whether the door could be told its key; null on a machine that runs none) and `tunnel`:
  `there` (the hub runs a tunnel program), `state` (`off`, `starting`, `connected`, `failing`), `since_ms`,
  and while it fails `reason` (`refused`, `unreachable`, `slow`, `missing`, `trouble`) and `said`
  (Cloudflare's program's own last word on it).
- `PUT /hub/online/push/address`: `{"address": "orders.example.com"}`, with or without `https://` and the
  path; empty forgets it. 422 `bad_value` for what is no name on the internet. Answers like the `GET`.
- `POST /hub/online/push/try`: the hub knocks at its own door, and with an address at
  `https://<address>/online/push`, with a word made for that knock where the key would be, and says
  whether each knock reached it: `tried.door` and `tried.outside` (null without an address, or when the
  door did not open), each with `ok`, `reason` and the answer's `code`. The key for pushes is sent
  nowhere, and a try counts as no push. 409 `no_key` on a hub without a key for pushes. Answers like the
  `GET` beside it.

**Texts to customers** (`pos.twilio`; docs/texts.md). The restaurant's Twilio account is the key `texts`:
`PUT /hub/keys/texts` with `{"account": "AC...", "key": "<the Auth Token>", "sender": "<a number of the
account's, or a Messaging Service's SID>"}` and, where the account is used with an API key, that key's SID
as `key_sid` and its secret as `key`. `shown` is the account, the sender and the API key's SID; the token
is never shown. From the moment it is typed the POS's texts go out through Twilio, and with it removed they
go nowhere again.

- `GET /hub/keys` also gives `texts`: `provider` (`log`: no service, the texts are only written to the
  hub's log; `twilio`), `sender`, `day` (of the last 24 hours: `texts`, `delivered`, `failed`) and
  `last_failed` (the order, the kind of text, when, and why in words, `said`). Never a customer's number
  and never the words of a text.
- `POST /hub/texts/try`: `{"to": "781 555 0142"}`: one text to that number now, to see that the account
  works, answered with `tried`: `ok`, `state` (`delivered`, `sent`: Twilio took it and the phone company
  has not said yet, `failed`), Twilio's error number (`code`) and why in words (`said`). The number is used
  for that one text and kept nowhere. 409 `no_service` on a hub without a Twilio account; 422 `bad_value`
  for what is no number. Answers like the `GET` beside it.

**Twilio's way in** (`pos.online.twilio_way`; docs/text-inbox.md, "Instant delivery and pictures"): Twilio
calls the hub the moment a text comes or changes, and fetches from it the pictures the staff send. It comes
by the push door and the tunnel, at the address above, under a word the hub makes itself.

- `GET /hub/keys` also gives `texts_way`: `on` (the hub has made its word), `address` (the hub's name on the
  internet, the same one GloriaFood sends to), `url` (what goes into Twilio's console as "A message comes
  in", once both are there; null until then), `door` (whether the door could be told; null on a machine
  that runs none) and `called_ms` (when Twilio last called). `url` holds the hub's word: it is the one thing
  on this page that is not to be shared, and it is told to a manager because a manager has to copy it into
  Twilio's console.
- `POST /hub/texts/way`: turns it on: the hub makes its word, unless it has one. `{"again": true}` makes a
  new one, after which the old address is dead and Twilio's console wants the new one. Answers like the
  `GET`. 409 `no_service` on a hub without a Twilio account.
- `DELETE /hub/texts/way`: turns it off: the word is forgotten and the door lets no call of Twilio's in.
- `POST /hub/texts/way/try`: the hub calls its own address for Twilio with a word made for that one try, at
  the door and, with an address, from outside, and says whether each call reached it: `way_tried.door` and
  `way_tried.outside`, each with `ok`, `reason` and the answer's `code`. 409 `off` while it is not turned on.

**Shipday** (`pos.shipday`; docs/shipday.md). The restaurant's key for Shipday is the key `shipday`:
`PUT /hub/keys/shipday` with `{"key": "..."}`. From the moment it is typed the hub asks Shipday for its
deliveries and drivers, and with it removed it asks nothing.

- `GET /hub/keys` also gives `shipday`: how the asking goes: `on` (a key is in force), `running`, when
  Shipday was last asked and last answered (`asked_ms`, `answered_ms`), `trouble` (null, or `since_ms`,
  `reason` and `said` for an asking that got no answer), whether Shipday says how far away a delivery is
  (`eta`: `off`, `on`, `plan`), and how many active `orders`, `drivers` and drivers `on_shift` it last
  listed. No order and no customer.
- `POST /hub/shipday/try`: Shipday is asked now, for its active orders and its drivers, and what came of
  it is answered as `shipday_tried`: `ok`, `reason` and `said` when not, and how many `orders`, `drivers`
  and drivers `on_shift` it listed. Nothing is changed in Shipday. 409 `no_key` on a hub without a key.
  Answers like the `GET` beside it.

A key changes the service that uses it in place (`use_keys`): the map lookups keep the day's counts, the
online orders start asking (or stop), Apple's sender is exchanged and so is the messenger the texts go out
with. A hub also looks once a minute whether
the keys changed under it (`watch_keys`): typed on the other hub of the location, or taken back by `hubctl`.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable, Iterable
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from ..addresses import services_from_env
from ..keys import (
    MAPS,
    MAPS_AZURE,
    MAPS_GOOGLE,
    MAPS_MAPBOX,
    ONLINE,
    ONLINE_PUSH,
    ONLINE_TUNNEL,
    PUSH_APPLE,
    SHIPDAY,
    SLOTS,
    TEXTS,
    TEXTS_WAY,
    HubKeys,
    UnknownKey,
    slot_for,
)
from ..maps import Lookups, fallback_from_env, maps_from_env, others_from_env
from ..messaging import Messenger, about_of, messenger_from_env
from ..online.accounts import MAIN, SETTING, Account, account_of_slot, accounts_of, clean_accounts, name_of, new_id
from ..online.gloriafood import GloriaFood
from ..online.service import OnlineOrders
from ..online.twilio_way import Knocks, TwilioWay
from ..online.twilio_way import make as make_way
from ..online.wayin import ADDRESS_SETTING, WayIn, clean_address
from ..push.apns import ApnsConfig, ApnsSender
from ..push.relay import PushRelay
from ..settings import SettingStore
from ..shipday.board import ShipdayBoard
from ..sync.pgstore import ReadOnlyError
from ..twilio import TwilioMessenger, config_of
from .auth import manager_from
from .shipday import use_shipday

log = logging.getLogger(__name__)

WATCH_SECONDS = 60.0
"""How often a hub looks whether the keys changed under it."""
TYPED_MOST = 16_000
"""The most a call may carry in one box: Apple's key file is a few hundred letters."""
NUMBER_MOST = 40
"""The most letters a phone number typed for a try may have, however it is spaced."""


class KeyIn(BaseModel):
    """What a manager typed for one key. No limits are set here: a refusal for a box that is too long would
    hand the box back in its words, and nothing typed here is ever handed back."""

    key: str = ""
    key_id: str = Field("", description="Apple's key: the ten letters and digits in the file's name")
    team_id: str = Field("", description="Apple's key: the team it belongs to")
    bundle_id: str = Field("", description="Apple's key: the app it pushes to, when not the usual one")
    account: str = Field("", description="Twilio: the Account SID")
    sender: str = Field("", description="Twilio: the number the texts are sent from, or a Messaging Service's SID")
    key_sid: str = Field("", description="Twilio: an API key's SID, when `key` is that key's secret")


class AccountIn(BaseModel):
    """A further account with GloriaFood: what the restaurant calls it, its key for asking, and whether it
    is the one the restaurant only tests with. To change one, what is left out stays as it is."""

    name: str | None = None
    key: str = ""
    test: bool | None = None


class TryTextIn(BaseModel):
    """The mobile number a manager wants the one text of a try sent to. It is kept nowhere."""

    to: str = ""


class WayOnIn(BaseModel):
    """Turning Twilio's way in on. `again`: a new word in place of the one the hub has."""

    again: bool = False


class AddressIn(BaseModel):
    """The name on the internet GloriaFood sends its pushes to. Empty: none is remembered."""

    address: str = ""


def hand_way_in(app: FastAPI) -> None:
    """The key for pushes and the tunnel's token in force now: the API's own check of a push goes by the
    one, and the push door and the tunnel are handed what each needs (`pos.online.wayin`)."""
    keys: HubKeys = app.state.keys
    push, tunnel = keys.data(ONLINE_PUSH), keys.data(ONLINE_TUNNEL)
    push_key = push["key"] if push is not None else None
    online: OnlineOrders = app.state.online
    online.use_push_key(push_key)
    wayin: WayIn = app.state.wayin
    wayin.hand(push_key, tunnel["key"] if tunnel is not None else None)


def hand_texts_way(app: FastAPI, *, tell: bool = True) -> None:
    """The hub's word for Twilio's calls in force now, or none: the API goes by it, and with `tell` the push
    door is told (`pos.online.wayin`), so that a call whose path carries the word gets in."""
    keys: HubKeys = app.state.keys
    held = keys.data(TEXTS_WAY)
    good = held is not None and bool(held.get("key")) and bool(held.get("seal"))
    app.state.way_secret = dict(held) if held is not None and good else None
    if tell:
        wayin: WayIn = app.state.wayin
        wayin.hand_twilio(held["key"] if held is not None and good else None)


def texts_way(app: FastAPI) -> TwilioWay | None:
    """Twilio's way in as it stands: None while it is not turned on, and while the hub has no name on the
    internet. With it a text can carry pictures, and Twilio is told where to call."""
    held = app.state.way_secret
    if not held:
        return None
    address = app.state.settings.get(ADDRESS_SETTING).get("address")
    if not isinstance(address, str) or not address:
        return None
    return TwilioWay(address, held["key"], held["seal"])


def callback_for(app: FastAPI) -> Callable[[], str]:
    """What a messenger asks with every text: where Twilio is to say what became of it, or nothing."""

    def where() -> str:
        way = texts_way(app)
        return way.status_url if way is not None else ""

    return where


def twilio_at_door(came: dict[str, Any], arrived: bool) -> dict[str, Any]:
    """What a knock the way Twilio comes, at the hub's own door, came to: `ok`, or why not. `shut`: the
    door does not know the hub's word (an older door, or it could not be told); `no_answer`: no door runs;
    `api`: the door is up and the API behind it did not answer it; `other`."""
    code = came["code"]
    if code == 200 and arrived:
        reason = None
    elif code is None:
        reason = "no_answer"
    elif code == 404:
        reason = "shut"
    elif code in (502, 504):
        reason = "api"
    else:
        reason = "other"
    return {"ok": reason is None, "reason": reason, "code": code}


def twilio_outside(came: dict[str, Any], arrived: bool) -> dict[str, Any]:
    """What the same knock from outside came to: `ok` when it reached this very hub, or why not, in the
    words of `knocked_outside`. `elsewhere`: something answers, and it is not this hub. `not_routed`: the
    name is known and leads nowhere for this path (404): at Cloudflare the public hostname lets only
    GloriaFood's path through."""
    code = came["code"]
    if code == 200 and arrived:
        reason = None
    elif code is None:
        reason = "late" if came["late"] else "no_answer"
    elif code in (200, 401):
        reason = "elsewhere"
    elif code == 404:
        reason = "not_routed"
    elif code == 403:
        reason = "blocked"
    elif code in (502, 503, 504) or 520 <= code <= 530:
        reason = "tunnel_down"
    elif 300 <= code < 400:
        reason = "redirect"
    else:
        reason = "other"
    return {"ok": reason is None, "reason": reason, "code": code}


def knocked_at_door(came: dict[str, Any], arrived: bool) -> dict[str, Any]:
    """What a knock at the hub's own door came to: `ok`, or why not. `shut`: the door has no key yet;
    `no_answer`: no door runs; `api`: the door is up and the API behind it did not answer it; `other`."""
    code = came["code"]
    if code == 401 and came["refused"] and arrived:
        reason = None
    elif code is None:
        reason = "no_answer"
    elif code == 404:
        reason = "shut"
    elif code in (502, 504):
        reason = "api"
    else:
        reason = "other"
    return {"ok": reason is None, "reason": reason, "code": code}


def knocked_outside(came: dict[str, Any], arrived: bool) -> dict[str, Any]:
    """What a knock from outside came to: `ok` when it reached this very hub, or why not. `no_answer`:
    nothing answers at that name (`late`: not in time); `elsewhere`: something answers, and it is not this
    hub; `not_routed`: the name is known and leads nowhere for this path (404); `blocked`: whoever keeps the
    name turns the call away (403); `tunnel_down`: the name's keeper cannot get to the door (502, 503, 504,
    Cloudflare's 52x and 530); `redirect`; `other`."""
    code = came["code"]
    if code == 401 and came["refused"] and arrived:
        reason = None
    elif code is None:
        reason = "late" if came["late"] else "no_answer"
    elif code == 401:
        reason = "elsewhere"
    elif code == 404:
        reason = "not_routed"
    elif code == 403:
        reason = "blocked"
    elif code in (502, 503, 504) or 520 <= code <= 530:
        reason = "tunnel_down"
    elif 300 <= code < 400:
        reason = "redirect"
    else:
        reason = "other"
    return {"ok": reason is None, "reason": reason, "code": code, "url": came["url"]}


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


def texts_for(keys: HubKeys, **made_with: Any) -> Messenger:
    """What the POS's texts go out with: Twilio where the hub holds an account for it, and otherwise the
    messenger that only writes them to the log. `made_with` is handed to the Twilio messenger (the tests
    give it a stand-in for the internet)."""
    config = config_of(keys.data(TEXTS))
    return TwilioMessenger(config, **made_with) if config is not None else messenger_from_env()


def use_texts(app: FastAPI) -> None:
    """The Twilio account in force now is the one the texts go out with: a new messenger where the account
    changed, was typed for the first time or was removed, and the same one where it did not (it keeps what
    it knows of the day's texts, and the ones still in its line). A messenger the hub was handed at its
    start (the tests) is never exchanged."""
    if app.state.texts_given:
        return
    keys: HubKeys = app.state.keys
    config = config_of(keys.data(TEXTS))
    old: Messenger = app.state.messenger
    if isinstance(old, TwilioMessenger):
        if old.config == config:
            return
    elif config is None:
        return
    fresh: Messenger = (
        TwilioMessenger(config, **app.state.texts_made_with) if config is not None else messenger_from_env()
    )
    if isinstance(fresh, TwilioMessenger) and fresh.keeper is None:
        fresh.keeper = app.state.texts  # what goes out is written down in the customer's conversation
    if isinstance(fresh, TwilioMessenger):
        fresh.callback = callback_for(app)  # and Twilio is told where to say what became of it
    app.state.messenger = fresh
    app.state.notifier.messenger = fresh
    if isinstance(old, TwilioMessenger):
        old.close()
    if isinstance(fresh, TwilioMessenger) and app.state.listens_texts:
        app.state.text_listener.start()  # and Twilio is asked for the texts that come; nothing where it already is
    app.state.feed.changed("texts")  # the screens say whether the hub can text
    log.warning("texts to customers: %s", "they go out through Twilio" if config is not None else "no service now")


async def use_keys(app: FastAPI, names: Iterable[str] | None = None) -> None:
    """Puts the keys in force to work, all of them or the ones named: after one was typed or removed, and
    when the keys were found changed. The services are changed where they stand, since the calls that use
    them hold on to them."""
    keys: HubKeys = app.state.keys
    # a further account's key (`online:<id>`) is GloriaFood's like the first
    wanted = {ONLINE if account_of_slot(name) else name for name in (SLOTS if names is None else names)}
    env = await run_in_threadpool(keys.environ)
    if wanted & {MAPS, MAPS_GOOGLE, MAPS_MAPBOX, MAPS_AZURE}:
        # Mapbox and Azure Maps can be asked the drive too, with the keys the list of addresses uses
        lookups: Lookups = app.state.lookups
        lookups.use(maps_from_env(env), fallback_from_env(env), *others_from_env(env))
    if wanted & {MAPS, MAPS_GOOGLE, MAPS_MAPBOX, MAPS_AZURE}:
        # the list of addresses asks with Google's key too, and with Mapbox's and Azure Maps' after it
        app.state.suggester.use(*services_from_env(env))
        # the delivery fee, live traffic and the list of addresses say what the hub can look up
        app.state.feed.changed("settings")
    if ONLINE in wanted:
        online: OnlineOrders = app.state.online
        # not in the middle of a round, which may be waiting for GloriaFood: off the loop
        sources, accounts = await run_in_threadpool(online_setup, keys, app.state.settings)
        await run_in_threadpool(online.use, sources, accounts)
        if app.state.asks_online:
            online.start()  # nothing where the round already runs, and nothing without a key
        app.state.feed.changed("online")  # the screens say whether the hub asks
    if wanted & {ONLINE_PUSH, ONLINE_TUNNEL}:
        await run_in_threadpool(hand_way_in, app)
        app.state.feed.changed("online")  # the screens say whether the hub takes pushes
    if PUSH_APPLE in wanted:
        relay: PushRelay = app.state.relay
        fresh = await run_in_threadpool(sender_for, keys)
        old, relay.sender = relay.sender, fresh
        if old is not None:
            await old.close()
    if TEXTS in wanted:
        await run_in_threadpool(use_texts, app)
    if names is None or TEXTS_WAY in wanted:
        await run_in_threadpool(hand_texts_way, app)
        app.state.feed.changed("texts")  # the screens say whether a text can carry a picture
    if SHIPDAY in wanted:
        # never in the middle of a round, which may be waiting for Shipday: off the loop
        await run_in_threadpool(use_shipday, app)
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

    def address() -> str:
        held = app.state.settings.get(ADDRESS_SETTING).get("address")
        return held if isinstance(held, str) else ""

    def texts() -> dict[str, Any]:
        """How the texts to customers are doing. The last one that failed is named by its order's number,
        as the lists of orders show it: never by anything of the customer."""
        about = about_of(app.state.messenger)
        failed = about.get("last_failed")
        if isinstance(failed, dict):
            state = app.state.store.state(str(failed.get("order_id") or ""))
            about["last_failed"] = {**failed, "order_no": state.fields.get("order_no")}
        return about

    def twilio_way() -> dict[str, Any]:
        """Twilio's way in, for the manager who sets it up: the address is theirs to copy into Twilio's
        console, and nobody else's to see."""
        wayin: WayIn = app.state.wayin
        way = texts_way(app)
        return {
            "on": app.state.way_secret is not None,
            "address": address(),
            "url": way.text_url if way is not None else None,
            "door": wayin.twilio_told,
            "called_ms": app.state.text_listener.called_ms,
        }

    def said() -> dict[str, Any]:
        keys: HubKeys = app.state.keys
        wayin: WayIn = app.state.wayin
        return {
            "keys": keys.views(),
            "kept": keys.vault.kept,
            "online_accounts": [{**account.about(), "key": keys.view(account.slot)} for account in accounts()],
            "way_in": {"address": address(), **wayin.about()},
            "texts": texts(),
            "texts_way": twilio_way(),
            "shipday": app.state.shipday.about(),
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

    @app.put("/hub/online/push/address")
    def write_push_address(body: AddressIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """The name GloriaFood sends its pushes to, remembered for trying the way in. It is no secret."""
        manager_from(app.state.tokens, authorization)
        if len(body.address) > 300:
            raise HTTPException(422, {"error": "bad_value", "message": "that is far too long to be an address"})
        try:
            cleaned = clean_address(body.address)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from None
        try:
            app.state.settings.put(ADDRESS_SETTING, {"address": cleaned})
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("texts")  # Twilio fetches a text's pictures at this name too
        return said()

    @app.post("/hub/online/push/try")
    async def try_way_in(authorization: str | None = Header(None)) -> dict[str, Any]:
        """The hub knocks at its own door, and from outside at the address GloriaFood sends to, and says
        whether each knock reached it. No key is sent anywhere, and a try counts as no push."""
        manager_from(app.state.tokens, authorization)
        online: OnlineOrders = app.state.online
        wayin: WayIn = app.state.wayin
        if not online.pushable:
            message = "this hub has no key for pushes yet"
            raise HTTPException(409, {"error": "no_key", "message": message})
        word = online.expect()
        door = knocked_at_door(await wayin.knock(word), online.arrived(word))
        outside = None
        host = await run_in_threadpool(address)
        if host and door["ok"]:
            word = online.expect()
            outside = {"address": host, **knocked_outside(await wayin.knock(word, host), online.arrived(word))}
        return {**await run_in_threadpool(said), "tried": {"door": door, "outside": outside}}

    @app.post("/hub/texts/way")
    async def turn_on_texts_way(
        body: WayOnIn | None = None, authorization: str | None = Header(None)
    ) -> dict[str, Any]:
        """Twilio's way in is turned on: the hub makes its word for Twilio's calls, unless it has one, and
        the door is told. With `again` a new word is made, and the address Twilio has is dead."""
        grant = manager_from(app.state.tokens, authorization)
        if not isinstance(app.state.messenger, TwilioMessenger):
            message = "this hub has no Twilio account yet"
            raise HTTPException(409, {"error": "no_service", "message": message})
        keys: HubKeys = app.state.keys
        again = body is not None and body.again

        def make() -> None:
            if not again and keys.data(TEXTS_WAY) is not None:
                return
            try:
                keys.set(TEXTS_WAY, make_way(), by=grant.name)
            except ReadOnlyError as err:
                raise HTTPException(503, {"error": "read_only"}) from err

        await run_in_threadpool(make)
        await use_keys(app, [TEXTS_WAY])
        return await run_in_threadpool(said)

    @app.delete("/hub/texts/way")
    async def turn_off_texts_way(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Twilio's way in is turned off: the word is forgotten, and the door lets no call of Twilio's in.
        The texts are asked for every few seconds again, and a text carries no picture."""
        grant = manager_from(app.state.tokens, authorization)
        keys: HubKeys = app.state.keys

        def forget() -> None:
            try:
                keys.forget(TEXTS_WAY, by=grant.name)
            except ReadOnlyError as err:
                raise HTTPException(503, {"error": "read_only"}) from err

        await run_in_threadpool(forget)
        await use_keys(app, [TEXTS_WAY])
        return await run_in_threadpool(said)

    @app.post("/hub/texts/way/try")
    async def try_texts_way(authorization: str | None = Header(None)) -> dict[str, Any]:
        """The hub calls its own address for Twilio, at the door and from outside, with a word made for
        that one try, and says whether each call reached it. Nothing is asked of Twilio and no text is
        written down."""
        manager_from(app.state.tokens, authorization)
        held = app.state.way_secret
        if not held:
            message = "Twilio's way in is not turned on yet"
            raise HTTPException(409, {"error": "off", "message": message})
        wayin: WayIn = app.state.wayin
        knocks: Knocks = app.state.way_knocks
        path = f"/twilio/{held['key']}/text"
        knock = knocks.expect()
        door = twilio_at_door(await wayin.knock_twilio(path, knock), knocks.arrived(knock))
        outside = None
        host = await run_in_threadpool(address)
        if host and door["ok"]:
            knock = knocks.expect()
            came = await wayin.knock_twilio(path, knock, host)
            outside = {"address": host, **twilio_outside(came, knocks.arrived(knock))}
        return {**await run_in_threadpool(said), "way_tried": {"door": door, "outside": outside}}

    @app.post("/hub/texts/try")
    async def try_texts(body: TryTextIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """One text to the number a manager typed, now, through the Twilio account in force: whether it
        went, and why not. The number is used for this and kept nowhere."""
        manager_from(app.state.tokens, authorization)
        messenger = app.state.messenger
        if not isinstance(messenger, TwilioMessenger):
            message = "this hub has no Twilio account yet"
            raise HTTPException(409, {"error": "no_service", "message": message})
        if not body.to.strip() or len(body.to) > NUMBER_MOST:
            raise HTTPException(422, {"error": "bad_value", "message": "type the mobile number to send the text to"})
        words = f"A test from the POS at {app.state.location}: texts to customers are working."
        tried = await run_in_threadpool(messenger.try_now, body.to, words)
        return {**await run_in_threadpool(said), "tried": tried}

    @app.post("/hub/shipday/try")
    async def try_shipday(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Shipday is asked now, with the key in force, for its active orders and its drivers: whether it
        answered, and how many of each it listed. Nothing is changed in Shipday."""
        manager_from(app.state.tokens, authorization)
        board: ShipdayBoard = app.state.shipday
        if not board.configured:
            message = "this hub has no key for Shipday yet"
            raise HTTPException(409, {"error": "no_key", "message": message})
        came = await run_in_threadpool(lambda: board.round(forced=True))
        now = await run_in_threadpool(said)
        about = now["shipday"]
        tried = {
            "ok": came["answered"],
            "reason": came["reason"],
            "said": came["said"],
            "orders": about["orders"] if came["answered"] else None,
            "drivers": about["drivers"] if came["answered"] else None,
            "on_shift": about["on_shift"] if came["answered"] else None,
        }
        return {**now, "shipday_tried": tried}
