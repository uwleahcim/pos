"""The hub's keys for the services outside the building, typed by a manager in the app (`pos.keys`,
docs/hub-keys.md): sealed where they are stored, never told back to a screen, in force without a restart,
and the app's word over the hub's own file."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import stat

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.api.keys import use_keys, watch_keys
from pos.identity.staff import Directory, Staff
from pos.keys import (
    MAPS,
    MAPS_AZURE,
    MAPS_GOOGLE,
    MAPS_MAPBOX,
    ONLINE,
    PUSH_APPLE,
    HubKeys,
    Kept,
    KeyStore,
    PgKeyStore,
    Vault,
    apple_pem,
    ending_of,
    vault_from_env,
)
from pos.maps import LookupFailed, Lookups, Trip
from pos.online.gloriafood import GloriaFood
from pos.online.service import OnlineOrders
from pos.push.devices import PushDevices
from pos.push.relay import PushRelay
from pos.settings import SettingStore

DSN = os.environ.get("POS_TEST_DATABASE_URL")

GEOCODIO_KEY = "made-up-geocodio-key-0123456789abcd"
GOOGLE_KEY = "AIzaMadeUpGoogleKey0123456789wxyz"
FOOD_KEY = "made-up-gloriafood-key-9876"
MAPBOX_KEY = "pk.madeUpMapboxTokenPart0123456789.madeUpEnding_qrst"
AZURE_KEY = "MadeUpAzureMapsKey0123456789abcdefghijklmn"
"""Nobody's keys."""


def p8(curve: ec.EllipticCurve | None = None) -> str:
    """A key file as Apple hands one out: a P-256 private key, PKCS#8, in PEM."""
    key = ec.generate_private_key(curve or ec.SECP256R1())
    return key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()


def vault() -> Vault:
    return vault_from_env({"POS_SECRET": "the-location-s-own-secret", "POS_KEYS_FILE": "/nowhere/at/all"})


def hub(
    environ: dict[str, str] | None = None, store: KeyStore | None = None, clock: list[int] | None = None
) -> HubKeys:
    ticks = clock if clock is not None else [1_800_000_000_000]
    return HubKeys(store, vault(), environ=environ or {}, now=lambda: ticks[0])


# --- the seal ------------------------------------------------------------------------------------------------


def test_what_is_sealed_opens_only_with_the_hub_s_own_secret():
    mine, theirs = vault(), vault_from_env({"POS_SECRET": "another location", "POS_KEYS_FILE": "/nowhere/at/all"})
    sealed = mine.seal({"key": GEOCODIO_KEY})
    assert GEOCODIO_KEY.encode() not in sealed, "what is stored is not the key"
    assert mine.open(sealed) == {"key": GEOCODIO_KEY}
    assert theirs.open(sealed) is None
    assert mine.open(b"not a seal at all") is None


def test_two_hubs_with_the_same_secret_open_each_other_s_seals():
    env = {"POS_SECRET": "shared by both hubs", "POS_KEYS_FILE": "/nowhere/at/all"}
    hub1, hub2 = vault_from_env(env), vault_from_env(env)
    assert hub2.open(hub1.seal({"key": FOOD_KEY})) == {"key": FOOD_KEY}
    assert hub1.kept and hub2.kept


def test_a_hub_without_a_shared_secret_keeps_one_of_its_own_in_a_file_only_it_reads(tmp_path):
    place = tmp_path / "vault.key"
    first = vault_from_env({"POS_KEYS_FILE": str(place)})
    sealed = first.seal({"key": GEOCODIO_KEY})
    assert first.kept and stat.S_IMODE(place.stat().st_mode) == 0o600
    again = vault_from_env({"POS_KEYS_FILE": str(place)})  # the hub restarted
    assert again.open(sealed) == {"key": GEOCODIO_KEY}
    # the hub is given a shared secret later: what it sealed before still opens, and new seals use the shared one
    later = vault_from_env({"POS_KEYS_FILE": str(place), "POS_SECRET": "given later"})
    assert later.open(sealed) == {"key": GEOCODIO_KEY}
    other_hub = vault_from_env({"POS_SECRET": "given later", "POS_KEYS_FILE": "/nowhere/at/all"})
    assert other_hub.open(later.seal({"key": FOOD_KEY})) == {"key": FOOD_KEY}


def test_with_nowhere_to_keep_a_secret_the_vault_says_its_seals_do_not_outlast_the_process(tmp_path):
    nowhere = vault_from_env({"POS_KEYS_FILE": str(tmp_path / "no-such-folder" / "vault.key")})
    assert nowhere.kept is False
    assert not (tmp_path / "no-such-folder").exists(), "nothing is made where the hub's volume is missing"
    assert nowhere.open(nowhere.seal({"key": FOOD_KEY})) == {"key": FOOD_KEY}
    (tmp_path / "vault.key").write_text("not a secret")
    assert vault_from_env({"POS_KEYS_FILE": str(tmp_path / "vault.key")}).kept is False


# --- which key is in force -------------------------------------------------------------------------------------


def test_a_key_from_the_hub_s_own_file_is_in_force_and_shown_by_its_ending_only():
    keys = hub({"POS_MAPS": "geocodio", "POS_MAPS_KEY": GEOCODIO_KEY})
    view = keys.view(MAPS)
    assert view == {
        "name": "maps",
        "set": True,
        "source": "hub",
        "ending": "abcd",
        "shown": {},
        "by": "",
        "at_ms": None,
        "removed": False,
        "unreadable": False,
    }
    assert keys.data(MAPS) == {"key": GEOCODIO_KEY}
    assert keys.view(ONLINE)["set"] is False and keys.view(ONLINE)["source"] is None
    assert [v["name"] for v in keys.views()] == [
        "maps",
        "maps_google",
        "maps_mapbox",
        "maps_azure",
        "online",
        "online_push",
        "online_tunnel",
        "push_apple",
    ]


def test_a_key_typed_in_the_app_is_sealed_and_wins_over_the_hub_s_file():
    store = KeyStore()
    keys = hub({"POS_MAPS_KEY": "the-old-key-from-the-terminal-1111"}, store)
    view = keys.set(MAPS, {"key": f"  {GEOCODIO_KEY}\n"}, by="Mike")
    assert (view["set"], view["source"], view["ending"], view["by"]) == (True, "app", "abcd", "Mike")
    assert view["at_ms"] == 1_800_000_000_000
    row = store.all()[MAPS]
    assert row.sealed is not None and GEOCODIO_KEY.encode() not in row.sealed
    assert keys.data(MAPS) == {"key": GEOCODIO_KEY}
    env = keys.environ()
    assert (env["POS_MAPS"], env["POS_MAPS_KEY"]) == ("geocodio", GEOCODIO_KEY)


def test_removed_in_the_app_means_none_is_in_force_whatever_the_hub_s_file_says():
    keys = hub({"POS_GLORIAFOOD_KEY": FOOD_KEY, "POS_NODE": "pos-hub1"})
    assert keys.environ()["POS_GLORIAFOOD_KEY"] == FOOD_KEY
    view = keys.remove(ONLINE, by="Mike")
    assert (view["set"], view["source"], view["removed"], view["by"], view["ending"]) == (False, None, True, "Mike", "")
    env = keys.environ()
    assert "POS_GLORIAFOOD_KEY" not in env and env["POS_NODE"] == "pos-hub1", "only the key's own names are touched"
    assert keys.data(ONLINE) is None


def test_what_a_screen_is_told_never_has_a_key_in_it():
    keys = hub({"POS_MAPS_GOOGLE_KEY": GOOGLE_KEY})
    pem = p8()
    keys.set(MAPS, {"key": GEOCODIO_KEY}, by="Mike")
    keys.set(ONLINE, {"key": FOOD_KEY}, by="Mike")
    keys.set(PUSH_APPLE, {"key": pem, "key_id": "abc123defg", "team_id": "N46M58VZD4"}, by="Mike")
    told = json.dumps(keys.views())
    body = "".join(pem.splitlines()[1:-1])
    for secret in (GEOCODIO_KEY, GOOGLE_KEY, FOOD_KEY, body, body[:40]):
        assert secret not in told
    apple = keys.view(PUSH_APPLE)
    assert apple["shown"] == {"key_id": "ABC123DEFG", "team_id": "N46M58VZD4", "bundle_id": "org.chinasky.posApp"}
    assert apple["ending"] == "", "Apple's key is told apart by its key id"
    assert keys.view(MAPS_GOOGLE)["ending"] == "wxyz"


def test_a_short_key_shows_nothing_of_itself():
    assert ending_of("0123456789abcdef") == "cdef"
    assert ending_of("0123456789abcde") == ""
    keys = hub()
    assert keys.set(ONLINE, {"key": "shortkey"}, by="Mike")["ending"] == ""


@pytest.mark.parametrize(
    ("name", "typed", "problem"),
    [
        (MAPS, {"key": ""}, "no key was typed"),
        (MAPS, {"key": "   \n"}, "no key was typed"),
        (MAPS, {"key": "too-short"}, "does not look like a key"),
        (MAPS, {"key": "has spaces inside it which a key never has!"}, "does not look like a key"),
        (ONLINE, {"key": "x" * 201}, "does not look like a key"),
        (MAPS_MAPBOX, {"key": "MadeUpAzureMapsKey0123456789abcdefghijklmn"}, "a Mapbox token starts with pk."),
        (MAPS_MAPBOX, {"key": "pk.only-one-part-of-a-token-0123456789"}, "a Mapbox token starts with pk."),
        (MAPS_AZURE, {"key": "too-short-for-azure-maps"}, "letters and digits, 32 or more"),
        (MAPS_AZURE, {"key": "pk.madeUpMapboxTokenPart0123456789.madeUpEnding_qrst"}, "32 or more"),
        (PUSH_APPLE, {"key": "hello", "key_id": "ABC123DEFG", "team_id": "N46M58VZD4"}, "not Apple's key file"),
    ],
)
def test_a_key_that_cannot_be_one_is_refused_in_words_that_do_not_repeat_it(name, typed, problem):
    keys = hub()
    with pytest.raises(ValueError, match=problem) as refused:
        keys.set(name, typed, by="Mike")
    typed_key = typed["key"].strip()
    assert not typed_key or typed_key not in str(refused.value)
    assert keys.store.all() == {}


def test_a_key_sealed_by_another_hub_is_said_to_be_unreadable_and_the_hub_s_file_is_used():
    store = KeyStore()
    there = HubKeys(store, vault_from_env({"POS_SECRET": "hub one alone", "POS_KEYS_FILE": "/nowhere/at/all"}))
    there.set(MAPS, {"key": GEOCODIO_KEY}, by="Mike")
    there.set(ONLINE, {"key": FOOD_KEY}, by="Mike")
    here = hub({"POS_MAPS_KEY": "this-hub-s-own-key-from-hubctl-2222"}, store)
    maps, online = here.view(MAPS), here.view(ONLINE)
    assert (maps["set"], maps["source"], maps["unreadable"], maps["ending"]) == (True, "hub", True, "2222")
    assert (online["set"], online["source"], online["unreadable"]) == (False, None, True)
    env = here.environ()
    assert env["POS_MAPS_KEY"] == "this-hub-s-own-key-from-hubctl-2222" and "POS_GLORIAFOOD_KEY" not in env


def test_nothing_of_a_key_is_written_to_the_log(caplog):
    keys = hub()
    with caplog.at_level(logging.DEBUG):
        keys.set(MAPS, {"key": GEOCODIO_KEY}, by="Mike")
        keys.remove(MAPS, by="Mike")
        with pytest.raises(ValueError):
            keys.set(MAPS, {"key": "nearly-a-key!"}, by="Mike")
    assert "maps was set in the app by Mike" in caplog.text and "removed in the app by Mike" in caplog.text
    assert GEOCODIO_KEY not in caplog.text and "nearly-a-key" not in caplog.text


# --- Apple's key file --------------------------------------------------------------------------------------------


def test_apple_s_key_file_is_read_however_it_was_pasted():
    pem = p8()
    lines = pem.strip().splitlines()
    one_line = " ".join(lines)  # a one-line box takes the line ends away
    bare = "".join(lines[1:-1])  # only the letters between the dashed lines
    for pasted in (pem, one_line, bare, pem.replace("\n", "\r\n"), f"\n\n  {pem}  \n"):
        assert apple_pem(pasted) == pem


def test_another_kind_of_private_key_is_not_apple_s():
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    with pytest.raises(ValueError, match="not the kind Apple gives"):
        apple_pem(other.decode())
    with pytest.raises(ValueError, match="not the kind Apple gives"):
        apple_pem(p8(ec.SECP384R1()))


@pytest.mark.parametrize(
    ("ids", "problem"),
    [
        ({"key_id": "", "team_id": "N46M58VZD4"}, "key id"),
        ({"key_id": "AuthKey_AB", "team_id": "N46M58VZD4"}, "key id"),
        ({"key_id": "ABC123DEFG", "team_id": "short"}, "team id"),
        ({"key_id": "ABC123DEFG", "team_id": "N46M58VZD4", "bundle_id": "not a bundle"}, "bundle id"),
    ],
)
def test_apple_s_ids_are_checked_as_hubctl_checks_them(ids, problem):
    with pytest.raises(ValueError, match=problem):
        hub().set(PUSH_APPLE, {"key": p8(), **ids}, by="Mike")


def test_apple_s_key_from_the_hub_s_own_file_is_read_where_hubctl_put_it(tmp_path):
    pem = p8()
    (tmp_path / "AuthKey_ABC123DEFG.p8").write_text(pem)
    env = {
        "POS_APNS_KEY": str(tmp_path / "AuthKey_ABC123DEFG.p8"),
        "POS_APNS_KEY_ID": "ABC123DEFG",
        "POS_APNS_TEAM_ID": "N46M58VZD4",
    }
    keys = hub(env)
    view = keys.view(PUSH_APPLE)
    assert (view["set"], view["source"], view["shown"]["key_id"]) == (True, "hub", "ABC123DEFG")
    assert keys.data(PUSH_APPLE)["key"] == pem


# --- the services follow, without a restart ----------------------------------------------------------------------


class FakeMaps:
    def __init__(self, name: str, answer: Trip | LookupFailed) -> None:
        self.name, self.answer = name, answer

    def trip(self, origin: str, destination: str) -> Trip:
        if isinstance(self.answer, LookupFailed):
            raise self.answer
        return self.answer


def test_another_key_keeps_what_the_day_already_counted_against_a_service():
    from decimal import Decimal

    far = Trip(Decimal("3.2"), 9)
    lookups = Lookups(FakeMaps("geocodio", LookupFailed("refused")), daily=5, fallback_daily=3)
    with pytest.raises(LookupFailed):
        lookups.trip("1 Main St", "12 Elm St")
    assert lookups.status()["asked_today"] == 1 and lookups.status()["failed_today"] == 1
    lookups.use(FakeMaps("geocodio", far), FakeMaps("google", far))  # the right key typed, and a second service
    status = lookups.status()
    assert (status["asked_today"], status["failed_today"], status["daily_most"]) == (1, 1, 5)
    assert status["fallback"]["service"] == "google" and status["fallback"]["daily_most"] == 3
    assert lookups.trip("1 Main St", "12 Elm St").miles == Decimal("3.2")
    assert lookups.status()["asked_today"] == 2
    lookups.use(None, None)
    assert lookups.ready is False and lookups.status()["configured"] is False


def test_another_key_for_asking_starts_the_online_status_over():
    class Refuses:
        name = "gloriafood"

        def pop(self):
            from pos.online.gloriafood import FetchFailed

            raise FetchFailed("refused the key")

    online = OnlineOrders(Refuses())
    online.round()
    assert online.status()["last_failure"]["reason"] == "refused the key"
    online.use(None)
    status = online.status()
    assert status["configured"] is False and status["last_failure"] is None and status["asked_ms"] is None


# --- on the wire ---------------------------------------------------------------------------------------------------


def staff() -> Directory:
    return Directory([Staff.with_pin("s1", "Amy", "server", "1111"), Staff.with_pin("s3", "Mike", "manager", "9999")])


def wired(keys: HubKeys | None = None) -> tuple[TestClient, HubKeys]:
    keys = keys if keys is not None else hub()
    relay = PushRelay(PushDevices(), None)
    app = create_app(
        staff=staff(), settings=SettingStore(), keys=keys, lookups=Lookups(), online=OnlineOrders(None), relay=relay
    )
    return TestClient(app), keys


def token(api: TestClient, pin: str = "9999") -> dict[str, str]:
    answer = api.post("/admin/session", json={"device": "t1", "pin": pin}).json()
    return {"authorization": f"Bearer {answer['token']}"}


def test_the_keys_are_a_manager_s_and_nobody_else_s():
    api, _ = wired()
    assert api.get("/hub/keys").status_code == 401
    assert api.put("/hub/keys/maps", json={"key": GEOCODIO_KEY}).status_code == 401
    assert api.delete("/hub/keys/maps").status_code == 401
    # a server's own session (servers take tables, so the hub gives them one for that) opens none of it
    session = api.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"})
    assert session.status_code == 200 and session.json()["role"] == "server"
    server = {"authorization": f"Bearer {session.json()['token']}"}
    assert api.get("/hub/keys", headers=server).status_code == 403
    assert api.put("/hub/keys/maps", json={"key": GEOCODIO_KEY}, headers=server).status_code == 403
    assert api.delete("/hub/keys/maps", headers=server).status_code == 403
    assert api.app.state.lookups.ready is False


def test_a_manager_types_the_map_keys_and_the_hub_asks_with_them_at_once():
    api, _ = wired()
    auth = token(api)
    before = api.get("/hub/keys", headers=auth).json()
    assert [key["set"] for key in before["keys"]] == [False] * 8 and before["kept"] is True
    assert api.get("/maps/status").json()["configured"] is False
    saved = api.put("/hub/keys/maps", json={"key": GEOCODIO_KEY}, headers=auth)
    assert saved.status_code == 200 and GEOCODIO_KEY not in saved.text
    first = saved.json()["keys"][0]
    assert (first["name"], first["set"], first["source"], first["ending"], first["by"]) == (
        "maps",
        True,
        "app",
        "abcd",
        "Mike",
    )
    assert api.get("/maps/status").json()["service"] == "geocodio", "no restart"
    api.put("/hub/keys/maps_google", json={"key": GOOGLE_KEY}, headers=auth)
    status = api.get("/maps/status").json()
    assert status["fallback"]["service"] == "google" and status["traffic"]["service"] == "google"
    gone = api.delete("/hub/keys/maps", headers=auth).json()["keys"][0]
    assert (gone["set"], gone["removed"], gone["by"]) == (False, True, "Mike")
    status = api.get("/maps/status").json()
    assert status["service"] == "google" and status["fallback"] is None, "Google's key alone: the one service"


def test_a_manager_types_mapbox_s_and_azure_maps_keys_and_the_list_of_addresses_has_them_to_ask():
    api, keys = wired()
    auth = token(api)
    suggester = api.app.state.suggester
    assert suggester.names == []
    saved = api.put("/hub/keys/maps_azure", json={"key": f" {AZURE_KEY}\n"}, headers=auth)
    assert saved.status_code == 200 and AZURE_KEY not in saved.text
    assert suggester.names == ["azure"], "no restart"
    saved = api.put("/hub/keys/maps_mapbox", json={"key": MAPBOX_KEY}, headers=auth)
    assert saved.status_code == 200 and MAPBOX_KEY not in saved.text and "pk." not in saved.text
    told = {key["name"]: key for key in saved.json()["keys"]}
    assert (told["maps_mapbox"]["set"], told["maps_mapbox"]["source"], told["maps_mapbox"]["ending"]) == (
        True,
        "app",
        "qrst",
    )
    assert (told["maps_azure"]["set"], told["maps_azure"]["ending"], told["maps_azure"]["by"]) == (True, "klmn", "Mike")
    assert suggester.names == ["mapbox", "azure"], "in the order they are asked"
    api.put("/hub/keys/maps_google", json={"key": GOOGLE_KEY}, headers=auth)
    assert suggester.names == ["google", "mapbox", "azure"]
    env = keys.environ()
    assert (env["POS_MAPS_MAPBOX_KEY"], env["POS_MAPS_AZURE_KEY"]) == (MAPBOX_KEY, AZURE_KEY)
    # the setting of the list says which of them the hub has a key for; each is off until a manager turns it on
    listed = api.get("/settings/address_list").json()["services"]
    assert [(one["name"], one["key"], one["on"]) for one in listed] == [
        ("google", True, False),
        ("mapbox", True, False),
        ("azure", True, False),
    ]
    # a token that is none is refused in words that do not repeat it, and nothing changes
    refused = api.put("/hub/keys/maps_mapbox", json={"key": "sk-not-a-mapbox-token-at-all-0000"}, headers=auth)
    assert refused.status_code == 422 and "sk-not" not in refused.text and "starts with pk." in refused.text
    assert suggester.names == ["google", "mapbox", "azure"]
    # removed: nobody is asked with it any more, and the others stay
    gone = {key["name"]: key for key in api.delete("/hub/keys/maps_mapbox", headers=auth).json()["keys"]}
    assert (gone["maps_mapbox"]["set"], gone["maps_mapbox"]["removed"]) == (False, True)
    assert suggester.names == ["google", "azure"]
    # the delivery's distance is asked of neither: they are for the list of addresses alone
    status = api.get("/maps/status").json()
    assert status["service"] == "google" and status["fallback"] is None


def test_mapbox_s_and_azure_maps_keys_can_stand_in_the_hub_s_own_file():
    keys = hub({"POS_MAPS_MAPBOX_KEY": MAPBOX_KEY, "POS_MAPS_AZURE_KEY": AZURE_KEY})
    mapbox, azure = keys.view(MAPS_MAPBOX), keys.view(MAPS_AZURE)
    assert (mapbox["set"], mapbox["source"], mapbox["ending"]) == (True, "hub", "qrst")
    assert (azure["set"], azure["source"], azure["ending"]) == (True, "hub", "klmn")
    assert MAPBOX_KEY not in json.dumps(keys.views()) and AZURE_KEY not in json.dumps(keys.views())
    keys.remove(MAPS_AZURE, by="Mike")
    env = keys.environ()
    assert env["POS_MAPS_MAPBOX_KEY"] == MAPBOX_KEY and "POS_MAPS_AZURE_KEY" not in env


def test_a_manager_types_gloriafood_s_key_and_the_hub_has_someone_to_ask():
    api, _ = wired()
    auth = token(api)
    assert api.get("/online/status").json()["configured"] is False
    saved = api.put("/hub/keys/online", json={"key": FOOD_KEY}, headers=auth)
    assert saved.status_code == 200 and FOOD_KEY not in saved.text
    online: OnlineOrders = api.app.state.online
    assert isinstance(online.source, GloriaFood) and api.get("/online/status").json()["configured"] is True
    assert online.status()["running"] is False, "nothing is asked where the API is not serving (a test)"
    api.delete("/hub/keys/online", headers=auth)
    assert online.source is None and api.get("/online/status").json()["configured"] is False


def test_a_manager_pastes_apple_s_key_and_the_hub_can_push():
    api, _ = wired()
    auth = token(api)
    assert api.get("/push/status").json()["configured"] is False
    pem = p8()
    body = {"key": " ".join(pem.splitlines()), "key_id": "abc123defg", "team_id": "N46M58VZD4"}
    saved = api.put("/hub/keys/push_apple", json=body, headers=auth)
    assert saved.status_code == 200 and pem.splitlines()[1] not in saved.text
    status = api.get("/push/status").json()
    assert (status["configured"], status["key_id"], status["team_id"], status["bundle"]) == (
        True,
        "ABC123DEFG",
        "N46M58VZD4",
        "org.chinasky.posApp",
    )
    assert api.app.state.relay.sender.config.key_pem.decode() == pem
    api.delete("/hub/keys/push_apple", headers=auth)
    assert api.get("/push/status").json()["configured"] is False


def test_what_is_wrong_with_a_key_is_said_without_the_key_and_nothing_changes():
    api, keys = wired()
    auth = token(api)
    bad = api.put("/hub/keys/maps", json={"key": "nearly a key"}, headers=auth)
    assert bad.status_code == 422 and bad.json()["detail"]["error"] == "bad_value"
    assert "does not look like a key" in bad.json()["detail"]["message"] and "nearly" not in bad.text
    long = api.put("/hub/keys/maps", json={"key": "k" * 20_000}, headers=auth)
    assert long.status_code == 422 and "kkkk" not in long.text
    assert api.put("/hub/keys/nothing", json={"key": GEOCODIO_KEY}, headers=auth).status_code == 404
    assert api.delete("/hub/keys/nothing", headers=auth).status_code == 404
    assert keys.store.all() == {} and api.app.state.lookups.ready is False


async def one_look(app, within: float = 10.0) -> None:
    """The watcher's next look, whole. `use_keys` moves the hub's mark as the last thing it does, so the mark
    having moved is the look having finished: waited for as such, and not for a length of time, which a busy
    machine does not keep to (the watcher's first look starts a thread)."""
    was = app.state.keys_mark
    looking = asyncio.create_task(watch_keys(app, every=0.01))
    try:
        async with asyncio.timeout(within):
            while app.state.keys_mark == was:
                await asyncio.sleep(0.01)
    finally:
        looking.cancel()
        await asyncio.gather(looking, return_exceptions=True)


def test_a_hub_notices_keys_that_changed_under_it():
    """Typed on the location's other hub, or taken back with hubctl: found at the next look."""
    store = KeyStore()
    api, keys = wired(hub({"POS_MAPS_KEY": "this-hub-s-own-key-from-hubctl-2222"}, store))
    app = api.app

    asyncio.run(use_keys(app))  # as the hub starts: its own file's key
    assert app.state.lookups.names == ["geocodio"]
    other_hub = HubKeys(store, vault(), now=lambda: 1_800_000_060_000)
    other_hub.remove(MAPS, by="Mike")
    other_hub.set(MAPS_GOOGLE, {"key": GOOGLE_KEY}, by="Mike")
    assert app.state.lookups.names == ["geocodio"]
    asyncio.run(one_look(app))
    assert app.state.lookups.names == ["google"]
    store._rows.pop(MAPS)  # noqa: SLF001 - what `hubctl maps key` does: the app's row goes, the file's key is back
    asyncio.run(one_look(app))
    assert app.state.lookups.names == ["geocodio", "google"]


# --- GloriaFood's accounts -----------------------------------------------------------------------------------------

SUSHI_KEY = "made-up-key-of-the-sushi-site-5555"
TEST_KEY = "made-up-key-to-test-with-7777"


def account(answer: dict, name: str) -> dict:
    return next(a for a in answer["online_accounts"] if a["name"] == name)


def test_a_manager_adds_a_second_gloriafood_account_and_the_hub_asks_both():
    api, keys = wired(hub({"POS_GLORIAFOOD_KEY": FOOD_KEY}))
    asyncio.run(use_keys(api.app))  # as the hub starts
    auth = token(api)
    before = api.get("/hub/keys", headers=auth).json()
    assert [(a["id"], a["name"], a["test"], a["key"]["source"]) for a in before["online_accounts"]] == [
        ("main", "", False, "hub")
    ]
    added = api.post("/hub/online/accounts", json={"name": " Sushi  site ", "key": SUSHI_KEY}, headers=auth)
    assert added.status_code == 200 and SUSHI_KEY not in added.text
    sushi = account(added.json(), "Sushi site")
    assert sushi["id"] == added.json()["added"] and sushi["id"] != "main" and sushi["test"] is False
    assert (sushi["key"]["name"], sushi["key"]["set"], sushi["key"]["source"], sushi["key"]["ending"]) == (
        f"online:{sushi['id']}",
        True,
        "app",
        "5555",
    )
    assert sushi["key"]["by"] == "Mike"
    assert [key["name"] for key in added.json()["keys"]] == [
        MAPS,
        MAPS_GOOGLE,
        MAPS_MAPBOX,
        MAPS_AZURE,
        ONLINE,
        "online_push",
        "online_tunnel",
        PUSH_APPLE,
    ], "as an older app reads it"
    online: OnlineOrders = api.app.state.online
    assert [(source.account, type(source)) for source in online.sources] == [
        ("main", GloriaFood),
        (sushi["id"], GloriaFood),
    ]
    status = api.get("/online/status").json()
    assert [(a["id"], a["name"], a["configured"]) for a in status["accounts"]] == [
        ("main", "", True),
        (sushi["id"], "Sushi site", True),
    ]
    # a third, to test with
    test = account(
        api.post("/hub/online/accounts", json={"name": "Testing", "key": TEST_KEY, "test": True}, headers=auth).json(),
        "Testing",
    )
    assert test["test"] is True and len(online.sources) == 3 and online.accounts[test["id"]].test is True
    assert keys.data(f"online:{test['id']}") == {"key": TEST_KEY} and keys.data(ONLINE) == {"key": FOOD_KEY}


def test_an_account_is_named_and_marked_for_testing_without_its_key_being_touched():
    api, keys = wired()
    auth = token(api)
    sushi = api.post("/hub/online/accounts", json={"name": "Sushi site", "key": SUSHI_KEY}, headers=auth).json()[
        "added"
    ]
    sealed = keys.store.all()[f"online:{sushi}"]
    changed = api.put(f"/hub/online/accounts/{sushi}", json={"name": "Sushi bar", "test": True}, headers=auth)
    assert changed.status_code == 200
    assert (account(changed.json(), "Sushi bar")["test"], account(changed.json(), "Sushi bar")["key"]["set"]) == (
        True,
        True,
    )
    assert keys.store.all()[f"online:{sushi}"] == sealed, "the key is as it was typed"
    online: OnlineOrders = api.app.state.online
    assert (online.accounts[sushi].name, online.accounts[sushi].test) == ("Sushi bar", True)
    # one of the two left out keeps it
    again = api.put(f"/hub/online/accounts/{sushi}", json={"test": False}, headers=auth).json()
    assert account(again, "Sushi bar")["test"] is False
    # the first account is named here too, whether it has a key or not
    first = api.put("/hub/online/accounts/main", json={"name": "Main site"}, headers=auth).json()
    assert [a["name"] for a in first["online_accounts"]] == ["Main site", "Sushi bar"]
    assert api.put("/hub/online/accounts/nobody", json={"name": "x"}, headers=auth).status_code == 404


def test_an_account_s_key_is_replaced_and_removed_like_any_key():
    api, keys = wired()
    auth = token(api)
    sushi = api.post("/hub/online/accounts", json={"name": "Sushi site", "key": SUSHI_KEY}, headers=auth).json()[
        "added"
    ]
    replaced = api.put(f"/hub/keys/online:{sushi}", json={"key": TEST_KEY}, headers=auth)
    assert replaced.status_code == 200 and account(replaced.json(), "Sushi site")["key"]["ending"] == "7777"
    assert keys.data(f"online:{sushi}") == {"key": TEST_KEY}
    removed = api.delete(f"/hub/keys/online:{sushi}", headers=auth).json()
    assert account(removed, "Sushi site")["key"]["set"] is False, "the account stays, with no key"
    assert api.app.state.online.sources == []
    assert api.get("/online/status").json()["accounts"][1]["configured"] is False
    # a key for an account that there is not is nobody's
    assert api.put("/hub/keys/online:zzzz", json={"key": TEST_KEY}, headers=auth).status_code == 404
    assert api.put("/hub/keys/online:main", json={"key": TEST_KEY}, headers=auth).status_code == 404
    assert "online:zzzz" not in keys.store.all()


def test_an_account_that_is_removed_takes_its_key_with_it_and_the_first_stays():
    api, keys = wired(hub({"POS_GLORIAFOOD_KEY": FOOD_KEY}))
    auth = token(api)
    sushi = api.post("/hub/online/accounts", json={"name": "Sushi site", "key": SUSHI_KEY}, headers=auth).json()[
        "added"
    ]
    assert len(api.app.state.online.sources) == 2
    gone = api.delete(f"/hub/online/accounts/{sushi}", headers=auth)
    assert gone.status_code == 200 and [a["id"] for a in gone.json()["online_accounts"]] == ["main"]
    assert f"online:{sushi}" not in keys.store.all()
    assert [source.account for source in api.app.state.online.sources] == ["main"]
    first = api.delete("/hub/online/accounts/main", headers=auth)
    assert first.status_code == 409 and first.json()["detail"]["error"] == "first_account"
    assert api.delete(f"/hub/online/accounts/{sushi}", headers=auth).status_code == 404
    assert keys.data(ONLINE) == {"key": FOOD_KEY}


def test_what_is_wrong_with_an_account_is_said_without_its_key_and_nothing_is_made():
    api, keys = wired()
    auth = token(api)

    def refused(body: dict, words: str) -> None:
        bad = api.post("/hub/online/accounts", json=body, headers=auth)
        assert bad.status_code == 422 and bad.json()["detail"]["error"] == "bad_value", bad.text
        assert words in bad.json()["detail"]["message"] and str(body.get("key") or "~")[:6] not in bad.text

    refused({"name": "Sushi site", "key": "no key"}, "does not look like a key")
    refused({"name": "Sushi site"}, "no key was typed")
    refused({"name": "", "key": SUSHI_KEY}, "give the account a name")
    refused({"name": "x" * 31, "key": SUSHI_KEY}, "too long")
    refused({"name": "Sushi site", "key": "k" * 20_000}, "far too long")
    assert keys.store.all() == {} and [
        a["id"] for a in api.get("/hub/keys", headers=auth).json()["online_accounts"]
    ] == ["main"]
    api.post("/hub/online/accounts", json={"name": "Sushi site", "key": SUSHI_KEY}, headers=auth)
    refused({"name": "sushi SITE", "key": TEST_KEY}, "two accounts are named")
    assert len(keys.store.all()) == 1


def test_gloriafood_s_accounts_are_a_manager_s_and_nobody_else_s():
    api, keys = wired()
    body = {"name": "Sushi site", "key": SUSHI_KEY}
    assert api.post("/hub/online/accounts", json=body).status_code == 401
    assert api.put("/hub/online/accounts/main", json={"name": "x"}).status_code == 401
    assert api.delete("/hub/online/accounts/main").status_code == 401
    session = api.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"})
    server = {"authorization": f"Bearer {session.json()['token']}"}
    assert api.post("/hub/online/accounts", json=body, headers=server).status_code == 403
    assert api.put("/hub/online/accounts/main", json={"name": "x"}, headers=server).status_code == 403
    assert api.delete("/hub/online/accounts/main", headers=server).status_code == 403
    assert keys.store.all() == {} and api.app.state.settings.get("online_accounts") == {"accounts": []}


def test_nothing_of_an_account_s_key_is_written_to_the_log(caplog):
    api, _ = wired()
    auth = token(api)
    with caplog.at_level(logging.DEBUG):
        sushi = api.post("/hub/online/accounts", json={"name": "Sushi site", "key": SUSHI_KEY}, headers=auth).json()[
            "added"
        ]
        api.put(f"/hub/keys/online:{sushi}", json={"key": TEST_KEY}, headers=auth)
        api.post("/hub/online/accounts", json={"name": "Other", "key": "not a key at all"}, headers=auth)
        api.delete(f"/hub/online/accounts/{sushi}", headers=auth)
    assert SUSHI_KEY not in caplog.text and TEST_KEY not in caplog.text and "not a key at all" not in caplog.text
    assert f"online:{sushi} was set in the app by Mike" in caplog.text
    assert f"online:{sushi} was removed with its account by Mike" in caplog.text


def test_a_hub_notices_an_account_that_was_added_or_named_on_the_other_hub():
    store, settings = KeyStore(), SettingStore()
    relay = PushRelay(PushDevices(), None)
    keys = hub({"POS_GLORIAFOOD_KEY": FOOD_KEY}, store)
    app = create_app(
        staff=staff(), settings=settings, keys=keys, lookups=Lookups(), online=OnlineOrders(None), relay=relay
    )

    asyncio.run(use_keys(app))
    online: OnlineOrders = app.state.online
    assert [source.account for source in online.sources] == ["main"]
    # the other hub of the location: the same database, another process
    settings.put("online_accounts", {"accounts": [{"id": "s1", "name": "Sushi site", "test": False}]})
    HubKeys(store, vault(), now=lambda: 1_800_000_060_000).set("online:s1", {"key": SUSHI_KEY}, by="Mike")
    asyncio.run(one_look(app))
    assert [source.account for source in online.sources] == ["main", "s1"] and online.accounts[
        "s1"
    ].name == "Sushi site"
    settings.put("online_accounts", {"accounts": [{"id": "s1", "name": "Sushi bar", "test": True}]})
    asyncio.run(one_look(app))
    assert (online.accounts["s1"].name, online.accounts["s1"].test) == ("Sushi bar", True)


# --- in PostgreSQL -------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_keys_survive_in_postgres_sealed():
    store = PgKeyStore(DSN)
    try:
        with store._pool.connection() as conn:  # noqa: SLF001 - a clean table for the test
            conn.execute("DELETE FROM hub_key")
        keys = HubKeys(store, vault(), environ={})
        keys.set(MAPS, {"key": GEOCODIO_KEY}, by="Mike")
        keys.set(PUSH_APPLE, {"key": p8(), "key_id": "ABC123DEFG", "team_id": "N46M58VZD4"}, by="Mike")
        keys.remove(ONLINE, by="Mike")
        mark = keys.mark()
        with store._pool.connection() as conn:  # noqa: SLF001
            dumped = conn.execute("SELECT string_agg(hub_key::text, ' ') FROM hub_key").fetchone()[0]
        assert GEOCODIO_KEY not in dumped and "abcd" in dumped, "a backup of the database holds no key"
        again = PgKeyStore(DSN)
        try:
            restarted = HubKeys(again, vault(), environ={"POS_GLORIAFOOD_KEY": FOOD_KEY})
            assert restarted.data(MAPS) == {"key": GEOCODIO_KEY}
            assert restarted.view(PUSH_APPLE)["shown"]["key_id"] == "ABC123DEFG"
            assert restarted.view(ONLINE)["removed"] is True and restarted.data(ONLINE) is None
            assert restarted.mark() == mark
            restarted.set(MAPS, {"key": GOOGLE_KEY}, by="Amy")
            assert restarted.mark() != mark and isinstance(again.all()[MAPS], Kept)
            assert keys.view(MAPS)["by"] == "Amy" and keys.view(MAPS)["ending"] == "wxyz"
            # a further account of GloriaFood's: its key is a row like the others, and gone with the account
            keys.set("online:s1", {"key": SUSHI_KEY}, by="Mike")
            assert restarted.data("online:s1") == {"key": SUSHI_KEY}
            with store._pool.connection() as conn:  # noqa: SLF001
                dumped = conn.execute("SELECT string_agg(hub_key::text, ' ') FROM hub_key").fetchone()[0]
            assert SUSHI_KEY not in dumped and "online:s1" in dumped
            mark = restarted.mark()
            keys.forget("online:s1", by="Mike")
            assert restarted.data("online:s1") is None and "online:s1" not in again.all() and restarted.mark() != mark
        finally:
            again.close()
    finally:
        store.close()
