"""The way in for GloriaFood's pushes, set in the app (pos.online.wayin, pos.api.keys; docs/online-orders.md,
"Push"): the key for pushes and the Cloudflare Tunnel's token are a manager's to type, the push door and
the tunnel are told of them without a restart, and the hub can try its own way in without sending a key
anywhere."""

from __future__ import annotations

import base64
import json
import logging
import stat

import httpx
import pytest
from starlette.testclient import TestClient

from pos.api.keys import knocked_at_door, knocked_outside
from pos.keys import ONLINE_PUSH, ONLINE_TUNNEL, HubKeys, tunnel_of, tunnel_token
from pos.online.door import KEY_FILE, PATH, Door
from pos.online.tunnel import STATUS_FILE, TOKEN_FILE, digest_of, mark_of
from pos.online.wayin import WayIn, clean_address, wayin_from_env

from .hub import MINUTE, NOW, PUSH_KEY, Hub
from .orders import order, row

TYPED_KEY = "typed-in-the-app-key-for-pushes-0001"
OTHER_KEY = "another-key-for-pushes-typed-later-2"
"""Nobody's keys."""
TUNNEL = "6ff42ae2-765d-4adf-8112-31c55c1551ef"
ADDRESS = "orders.example.com"


def token_of(tunnel: str = TUNNEL, secret: bytes = b"made up for a test, nobody's secret") -> str:
    """A tunnel's token as Cloudflare makes one: its account, the tunnel's id and its secret, as one word."""
    held = {"a": "0" * 32, "t": tunnel, "s": base64.b64encode(secret).decode()}
    return base64.b64encode(json.dumps(held).encode()).decode()


TOKEN = token_of()


def lunch(number: int = 301) -> dict:
    return order(number, [row("Sweet & Sour Chicken", 2)])


# --- the two keys --------------------------------------------------------------------------------------------------


def test_the_token_is_found_in_the_command_cloudflare_shows_and_put_together_when_a_paste_broke_it():
    assert tunnel_token(TOKEN) == TOKEN
    assert tunnel_token(f"  sudo cloudflared service install {TOKEN}\n") == TOKEN
    assert tunnel_token(f"docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token {TOKEN}") == TOKEN
    assert tunnel_token(f"{TOKEN[:60]}\n{TOKEN[60:]}\n") == TOKEN, "a token alone that picked up a line end"
    for pasted in ("", "   ", "sudo cloudflared service install", "too-short", f"{TOKEN} {TOKEN}x", f"{TOKEN}!"):
        with pytest.raises(ValueError) as said:
            tunnel_token(pasted)
        assert TOKEN not in str(said.value), "what was pasted is never said back"
    with pytest.raises(ValueError, match="no token was typed"):
        tunnel_token(" \n ")


def test_the_tunnel_s_id_is_read_out_of_its_token_and_a_token_that_reads_otherwise_is_kept_all_the_same():
    assert tunnel_of(TOKEN) == "6ff42ae2"
    assert tunnel_of(TOKEN.rstrip("=")) == "6ff42ae2", "copied without its last characters of padding"
    odd = "A" * 60  # it is one long word, and nothing is in it
    assert tunnel_of(odd) == "" and tunnel_of("not base64 at all !!") == ""
    assert tunnel_of(base64.b64encode(b'{"t": "../../etc"}').decode()) == "", "only an id is shown"
    keys = HubKeys()
    view = keys.set(ONLINE_TUNNEL, {"key": odd}, by="Mike")
    assert view["set"] is True and view["shown"] == {"tunnel": ""} and keys.data(ONLINE_TUNNEL)["key"] == odd


def test_both_keys_are_kept_like_the_rest_sealed_never_told_back_and_the_app_s_word_over_the_hub_s_file():
    keys = HubKeys(environ={"POS_GLORIAFOOD_PUSH_KEY": PUSH_KEY, "POS_TUNNEL_TOKEN": TOKEN})
    push, tunnel = keys.view(ONLINE_PUSH), keys.view(ONLINE_TUNNEL)
    assert (push["set"], push["source"], push["ending"]) == (True, "hub", PUSH_KEY[-4:])
    assert (tunnel["set"], tunnel["source"], tunnel["ending"], tunnel["shown"]) == (
        True,
        "hub",
        "",
        {"tunnel": "6ff42ae2"},
    )
    other = token_of("0a1b2c3d-0000-4000-8000-000000000000", b"another made-up secret for a test!!")
    typed = keys.set(ONLINE_TUNNEL, {"key": f"cloudflared service install {other}"}, by="Mike")
    assert (typed["source"], typed["shown"], typed["by"]) == ("app", {"tunnel": "0a1b2c3d"}, "Mike")
    assert other not in str(typed) and other.encode() not in keys.store.all()[ONLINE_TUNNEL].sealed
    assert keys.data(ONLINE_TUNNEL)["key"] == other
    keys.set(ONLINE_PUSH, {"key": f" {TYPED_KEY}\n"}, by="Mike")
    env = keys.environ()
    assert (env["POS_GLORIAFOOD_PUSH_KEY"], env["POS_TUNNEL_TOKEN"]) == (TYPED_KEY, other)
    keys.remove(ONLINE_PUSH, by="Mike")
    assert keys.data(ONLINE_PUSH) is None and "POS_GLORIAFOOD_PUSH_KEY" not in keys.environ()
    assert keys.view(ONLINE_PUSH)["removed"] is True
    for short in ("", "fifteen-letters", "with-a-sign-that-no-key-has-in-it!"):
        with pytest.raises(ValueError):
            keys.set(ONLINE_PUSH, {"key": short}, by="Mike")


# --- handing over --------------------------------------------------------------------------------------------------


def folders(tmp_path):
    door, tunnel = tmp_path / "door", tmp_path / "tunnel"
    door.mkdir()
    tunnel.mkdir()
    return door, tunnel


def test_the_door_is_handed_the_key_s_sha_and_not_the_key_and_the_tunnel_its_token_for_the_hub_s_user_alone(tmp_path):
    door, tunnel = folders(tmp_path)
    wayin = WayIn(door, tunnel)
    assert wayin.about()["door"] is None, "nothing was handed yet"
    wayin.hand(TYPED_KEY, TOKEN)
    left = (door / KEY_FILE).read_text()
    assert json.loads(left) == {"sha256": digest_of(TYPED_KEY)} and TYPED_KEY not in left
    assert (tunnel / TOKEN_FILE).read_text() == TOKEN
    assert stat.S_IMODE((tunnel / TOKEN_FILE).stat().st_mode) == 0o600
    assert stat.S_IMODE((door / KEY_FILE).stat().st_mode) == 0o600
    assert sorted(p.name for p in door.iterdir()) == [KEY_FILE], "nothing is left lying beside it"
    assert (wayin.about()["door"], wayin.about()["tunnel_told"]) == (True, True)
    wayin.hand(None, None)
    assert json.loads((door / KEY_FILE).read_text()) == {"sha256": None}, "the door is told that there is none"
    assert not (tunnel / TOKEN_FILE).exists()
    wayin.hand(None, None)  # and again, with nothing to take away


def test_a_machine_without_the_folders_hands_nothing_and_one_that_cannot_write_says_so_without_the_key(
    tmp_path, caplog
):
    nowhere = wayin_from_env({"POS_DOOR_DIR": str(tmp_path / "none"), "POS_TUNNEL_DIR": str(tmp_path / "none2")})
    nowhere.hand(TYPED_KEY, TOKEN)
    assert nowhere.about() == {
        "door": None,
        "tunnel_told": None,
        "tunnel": {"there": False, "state": "off", "since_ms": None, "reason": None, "said": "", "version": ""},
    }
    assert not (tmp_path / "none").exists()
    door, tunnel = folders(tmp_path)
    (door / KEY_FILE).mkdir()  # something is in the way
    (tunnel / TOKEN_FILE).mkdir()
    (tunnel / TOKEN_FILE / "x").write_text("")
    wayin = WayIn(door, tunnel)
    with caplog.at_level(logging.DEBUG):
        wayin.hand(TYPED_KEY, TOKEN)
        wayin.hand(None, None)
    assert (wayin.about()["door"], wayin.about()["tunnel_told"]) == (False, False)
    assert "could not be told" in caplog.text
    assert TYPED_KEY not in caplog.text and TOKEN not in caplog.text


# --- the door ------------------------------------------------------------------------------------------------------


class Street:
    """The door as the tests reach it, with a hub behind it and the folder the API leaves its word in."""

    def __init__(self, hub: Hub, folder, *, key: str | None = None) -> None:
        self.hub = hub
        inside = httpx.AsyncClient(transport=httpx.ASGITransport(app=hub.client.app))
        self.door = Door(to="http://api:8000", key=key, told=folder / KEY_FILE, client=inside)
        self.client = TestClient(self.door)

    def push(self, *orders: dict, key: str | None) -> httpx.Response:
        body = json.dumps({"count": len(orders), "orders": list(orders)})
        headers = {"Content-Type": "application/json"} | ({} if key is None else {"Authorization": key})
        return self.client.post(PATH, content=body, headers=headers)


def test_a_key_typed_in_the_app_opens_the_door_at_once_and_one_removed_shuts_it_with_no_restart(tmp_path):
    door, tunnel = folders(tmp_path)
    hub = Hub(keys=HubKeys(), wayin=WayIn(door, tunnel))
    street = Street(hub, door)
    assert street.push(lunch(), key=TYPED_KEY).status_code == 404, "shut: the hub has no key for pushes"
    auth = hub.manager()
    typed = hub.client.put("/hub/keys/online_push", json={"key": TYPED_KEY}, headers=auth)
    assert typed.status_code == 200 and TYPED_KEY not in typed.text
    assert typed.json()["way_in"]["door"] is True
    assert hub.status()["push"]["configured"] is True
    answer = street.push(lunch(), key=TYPED_KEY)
    assert (answer.status_code, answer.json()) == (200, {"received": 1})
    assert hub.order(301)["fields"]["order_no"] == 1 and hub.inbox.get("gloriafood", "301").via == "push"
    assert (
        street.push(lunch(302), key=OTHER_KEY).status_code == 401
        and street.push(lunch(302), key=None).status_code == 401
    )
    # replaced: the old key opens nothing from that moment
    hub.clock += MINUTE
    assert hub.client.put("/hub/keys/online_push", json={"key": OTHER_KEY}, headers=auth).status_code == 200
    assert street.push(lunch(302), key=TYPED_KEY).status_code == 401
    assert street.push(lunch(302), key=OTHER_KEY).status_code == 200
    assert hub.status()["push"]["refused"]["reason"] == "it carried the wrong key"
    # removed: shut again, for the right key too
    assert hub.client.delete("/hub/keys/online_push", headers=auth).status_code == 200
    assert street.push(lunch(303), key=OTHER_KEY).status_code == 404
    assert hub.status()["push"]["configured"] is False and hub.client.get("/orders/gf-303").status_code == 404


def test_a_door_that_was_told_nothing_goes_by_the_hub_s_own_file_and_what_the_api_says_stands_over_it(tmp_path):
    door, _ = folders(tmp_path)
    street = Street(Hub(push=True), door, key=PUSH_KEY)  # set up with hubctl, before the API said a word
    assert street.push(lunch(), key=PUSH_KEY).status_code == 200
    (door / KEY_FILE).write_text(json.dumps({"sha256": None}))  # removed in the app
    assert street.push(lunch(302), key=PUSH_KEY).status_code == 404
    (door / KEY_FILE).unlink()
    assert street.push(lunch(302), key=PUSH_KEY).status_code == 200, "nothing said again: the hub's own file"


def test_a_door_that_cannot_read_what_it_was_told_stays_shut(tmp_path):
    door, _ = folders(tmp_path)
    street = Street(Hub(push=True), door, key=PUSH_KEY)
    for nonsense in ("", "not json", "[]", '{"sha256": "abc"}', '{"sha256": 7}', json.dumps({"sha256": "G" * 64})):
        (door / KEY_FILE).write_text(nonsense)
        assert street.push(lunch(), key=PUSH_KEY).status_code == 404, nonsense
    assert street.hub.inbox.since(0) == []


def test_the_door_reads_the_body_of_a_push_only_when_it_carries_the_key_it_was_told_of(tmp_path):
    door, _ = folders(tmp_path)
    hub = Hub(push=True)
    calls: list[httpx.Request] = []

    class Inside(httpx.AsyncBaseTransport):
        def __init__(self) -> None:
            self._api = httpx.ASGITransport(app=hub.client.app)

        async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
            calls.append(request)
            return await self._api.handle_async_request(request)

    (door / KEY_FILE).write_text(json.dumps({"sha256": digest_of(PUSH_KEY)}))
    client = TestClient(Door(told=door / KEY_FILE, client=httpx.AsyncClient(transport=Inside())))
    body = json.dumps({"count": 1, "orders": [lunch()]})
    assert client.post(PATH, content=body, headers={"Authorization": "a stranger"}).status_code == 401
    assert client.post(PATH, content=body, headers={"Authorization": f" {PUSH_KEY} "}).status_code == 200
    assert [len(call.content) for call in calls] == [0, len(body)]


# --- how the tunnel stands -----------------------------------------------------------------------------------------


def says(tunnel, **told) -> None:
    told = {"state": "connected", "since_ms": NOW - 5_000, "mark": mark_of(TOKEN), "beat_ms": NOW, **told}
    (tunnel / STATUS_FILE).write_text(json.dumps(told))


def test_the_api_reads_how_the_tunnel_stands_and_takes_nothing_of_it_but_what_it_knows(tmp_path):
    door, tunnel = folders(tmp_path)
    clock = [NOW]
    wayin = WayIn(door, tunnel, now=lambda: clock[0])
    gone = {"there": False, "state": "off", "since_ms": None, "reason": None, "said": "", "version": ""}
    assert wayin.tunnel() == gone, "no tunnel program has said anything"
    wayin.hand(PUSH_KEY, TOKEN)
    says(tunnel, version="2026.3.0", reason="refused", said="left over from before", extra={"anything": "else"})
    assert wayin.tunnel() == {
        "there": True,
        "state": "connected",
        "since_ms": NOW - 5_000,
        "reason": None,
        "said": "",
        "version": "2026.3.0",
    }
    says(tunnel, state="failing", reason="refused", said="Unauthorized: Invalid tunnel secret\x07\n" + "x" * 500)
    failing = wayin.tunnel()
    assert (failing["state"], failing["reason"]) == ("failing", "refused")
    assert failing["said"].startswith("Unauthorized: Invalid tunnel secret") and len(failing["said"]) == 200
    assert "\x07" not in failing["said"] and "\n" not in failing["said"]
    says(tunnel, state="failing", reason="something new", said=7)
    assert (wayin.tunnel()["reason"], wayin.tunnel()["said"]) == (None, "")
    says(tunnel, state="dancing")
    assert wayin.tunnel()["state"] == "starting", "a word the API does not know is not passed on"
    # its word is about the token before this one: it has not looked at the new one yet
    says(tunnel, mark=mark_of(token_of("0a1b2c3d-0000-4000-8000-000000000000")))
    assert (wayin.tunnel()["state"], wayin.tunnel()["since_ms"]) == ("starting", None)
    wayin.hand(PUSH_KEY, None)
    assert wayin.tunnel()["state"] == "off"
    says(tunnel, state="off", mark="")
    assert wayin.tunnel() == {**gone, "there": True, "since_ms": NOW - 5_000}
    # silence: the tunnel's program is not running
    clock[0] += 46_000
    assert wayin.tunnel() == gone
    for nonsense in ("", "{", "[1, 2]", '"connected"', json.dumps({"state": "connected", "beat_ms": "now"})):
        (tunnel / STATUS_FILE).write_text(nonsense)
        assert wayin.tunnel() == gone, nonsense


# --- on the wire ---------------------------------------------------------------------------------------------------


class World(httpx.AsyncBaseTransport):
    """Everything the hub can reach when it knocks: its own door, and the internet. `leads` says what each
    name on the internet leads to: the hub's door (`door`), or an answer of somebody else's."""

    def __init__(self, door: Door | None, leads: dict[str, object] | None = None) -> None:
        self._door = httpx.ASGITransport(app=door) if door is not None else None
        self.leads = leads or {}
        self.calls: list[httpx.Request] = []

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        host, to = request.url.host, None
        if (request.url.scheme, host, request.url.port) == ("http", "door", 8090):
            to = "door"
        elif request.url.scheme == "https" and request.url.port is None:
            to = self.leads.get(host)
        if to == "door" and self._door is not None:
            return await self._door.handle_async_request(request)
        if isinstance(to, httpx.Response):
            return to
        if isinstance(to, Exception):
            raise to
        raise httpx.ConnectError("nothing answers there")


class Wired:
    """A hub with a door and a tunnel's folder, a manager signed in, and a world to knock in."""

    def __init__(self, tmp_path, *, door: bool = True, leads: dict[str, object] | None = None, **hub) -> None:
        self.door_dir, self.tunnel_dir = folders(tmp_path)
        self.world = World(None)
        self.wayin = WayIn(self.door_dir, self.tunnel_dir, client=httpx.AsyncClient(transport=self.world))
        self.hub = Hub(keys=HubKeys(), wayin=self.wayin, **hub)
        if door:
            inside = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.hub.client.app))
            self.world._door = httpx.ASGITransport(
                app=Door(to="http://api:8000", told=self.door_dir / KEY_FILE, client=inside)
            )
        self.world.leads = leads if leads is not None else {ADDRESS: "door"}
        self.auth = self.hub.manager()

    def put(self, path: str, body: dict) -> httpx.Response:
        return self.hub.client.put(path, json=body, headers=self.auth)

    def tried(self) -> dict:
        answer = self.hub.client.post("/hub/online/push/try", headers=self.auth)
        assert answer.status_code == 200, answer.text
        return answer.json()["tried"]


def test_the_way_in_is_a_manager_s_and_nobody_else_s(tmp_path):
    wired = Wired(tmp_path)
    api = wired.hub.client
    session = api.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"})
    server = {"authorization": f"Bearer {session.json()['token']}"}
    for headers, refused in (({}, 401), (server, 403)):
        assert api.put("/hub/keys/online_push", json={"key": TYPED_KEY}, headers=headers).status_code == refused
        assert api.put("/hub/keys/online_tunnel", json={"key": TOKEN}, headers=headers).status_code == refused
        assert api.delete("/hub/keys/online_tunnel", headers=headers).status_code == refused
        assert api.put("/hub/online/push/address", json={"address": ADDRESS}, headers=headers).status_code == refused
        assert api.post("/hub/online/push/try", headers=headers).status_code == refused
    assert not (wired.door_dir / KEY_FILE).exists() and not (wired.tunnel_dir / TOKEN_FILE).exists()
    assert wired.world.calls == []


def test_a_manager_types_the_tunnel_s_token_and_the_tunnel_is_handed_it_and_no_answer_has_it(tmp_path):
    wired = Wired(tmp_path)
    typed = wired.put("/hub/keys/online_tunnel", {"key": f"sudo cloudflared service install {TOKEN}"})
    assert typed.status_code == 200 and TOKEN not in typed.text
    mine = next(key for key in typed.json()["keys"] if key["name"] == "online_tunnel")
    assert (mine["set"], mine["source"], mine["shown"], mine["ending"], mine["by"]) == (
        True,
        "app",
        {"tunnel": "6ff42ae2"},
        "",
        "Mike",
    )
    assert (wired.tunnel_dir / TOKEN_FILE).read_text() == TOKEN
    way = typed.json()["way_in"]
    assert way["tunnel_told"] is True and way["tunnel"]["state"] == "off", "no tunnel program has spoken"
    says(wired.tunnel_dir, beat_ms=wired.hub.clock)  # the tunnel's program found it and reached Cloudflare
    wired.wayin._now = lambda: wired.hub.clock
    seen = wired.hub.client.get("/hub/keys", headers=wired.auth).json()["way_in"]["tunnel"]
    assert (seen["there"], seen["state"], seen["since_ms"]) == (True, "connected", NOW - 5_000)
    assert wired.hub.status()["push"]["tunnel"] == {
        "there": True,
        "state": "connected",
        "since_ms": NOW - 5_000,
        "reason": None,
    }
    refused = wired.put("/hub/keys/online_tunnel", {"key": "sudo cloudflared service install"})
    assert refused.status_code == 422 and "tunnel's token" in refused.json()["detail"]["message"]
    assert (wired.tunnel_dir / TOKEN_FILE).read_text() == TOKEN, "a refusal changes nothing"
    removed = wired.hub.client.delete("/hub/keys/online_tunnel", headers=wired.auth)
    assert removed.status_code == 200 and not (wired.tunnel_dir / TOKEN_FILE).exists()
    assert removed.json()["way_in"]["tunnel"]["state"] == "off"


def test_the_address_gloriafood_sends_to_is_remembered_as_a_name_and_nothing_else(tmp_path):
    wired = Wired(tmp_path)
    assert wired.hub.client.get("/hub/keys", headers=wired.auth).json()["way_in"]["address"] == ""
    for typed in (ADDRESS, f"https://{ADDRESS}/online/push", "  HTTPS://Orders.Example.com/ ", f"http://{ADDRESS}"):
        saved = wired.put("/hub/online/push/address", {"address": typed})
        assert saved.status_code == 200 and saved.json()["way_in"]["address"] == ADDRESS, typed
    for typed in ("localhost", "10.27.1.5", "orders.example.com:8443", "door", "a b.example.com", "x" * 400, "-a.com"):
        refused = wired.put("/hub/online/push/address", {"address": typed})
        assert refused.status_code == 422 and refused.json()["detail"]["error"] == "bad_value", typed
        assert typed not in refused.text or typed == "door"
    assert wired.hub.client.get("/hub/keys", headers=wired.auth).json()["way_in"]["address"] == ADDRESS
    assert wired.put("/hub/online/push/address", {"address": " "}).json()["way_in"]["address"] == ""
    assert clean_address("pos.restaurant.co.uk/online/push") == "pos.restaurant.co.uk"


def test_the_hub_knocks_at_its_door_and_from_outside_and_no_key_goes_anywhere_and_nothing_is_counted(tmp_path, caplog):
    wired = Wired(tmp_path)
    assert wired.hub.client.post("/hub/online/push/try", headers=wired.auth).json()["detail"]["error"] == "no_key"
    wired.put("/hub/keys/online_push", {"key": TYPED_KEY})
    assert wired.tried() == {"door": {"ok": True, "reason": None, "code": 401}, "outside": None}
    wired.put("/hub/online/push/address", {"address": ADDRESS})
    with caplog.at_level(logging.DEBUG):
        tried = wired.tried()
    assert tried == {
        "door": {"ok": True, "reason": None, "code": 401},
        "outside": {
            "address": ADDRESS,
            "ok": True,
            "reason": None,
            "code": 401,
            "url": f"https://{ADDRESS}/online/push",
        },
    }
    sent = [(str(call.url), call.headers["authorization"]) for call in wired.world.calls]
    assert [url for url, _ in sent] == ["http://door:8090/online/push"] * 2 + [f"https://{ADDRESS}/online/push"]
    words = [word for _, word in sent]
    assert len(set(words)) == 3 and all(word.startswith("try-") and TYPED_KEY not in word for word in words)
    assert all(TYPED_KEY.encode() not in call.content for call in wired.world.calls)
    assert all(word not in caplog.text for word in words), "a try is not written in the log"
    status = wired.hub.status()
    assert status["push"]["refused"] is None and status["push"]["pushed_ms"] is None, "a try counts as no push"
    assert status["trouble"] == [] and wired.hub.inbox.since(0) == []
    # the word of a try is good once, and is no key: somebody who saw one gets nowhere with it
    again = wired.hub.push(lunch(), key=words[-1])
    assert again.status_code == 401 and wired.hub.status()["push"]["refused"]["count"] == 1
    assert wired.hub.push(lunch(), key=TYPED_KEY).status_code == 200


def test_what_a_try_says_when_the_door_or_the_way_in_from_outside_does_not_lead_to_this_hub(tmp_path):
    elsewhere = httpx.Response(401, json={"error": "refused"})  # another hub's door, by the look of it
    wired = Wired(
        tmp_path,
        leads={
            ADDRESS: "door",
            "other.example.com": elsewhere,
            "login.example.com": httpx.Response(401, text="Sign in"),
            "down.example.com": httpx.Response(530, text="error code: 1033"),
            "bad.example.com": httpx.Response(502, text="Bad gateway"),
            "lost.example.com": httpx.Response(404),
            "wall.example.com": httpx.Response(403, text="Forbidden"),
            "moved.example.com": httpx.Response(301, headers={"location": "https://evil.example.org/online/push"}),
            "odd.example.com": httpx.Response(200, json={"received": 0}),
            "slow.example.com": httpx.ReadTimeout("too late"),
        },
    )
    wired.put("/hub/keys/online_push", {"key": TYPED_KEY})

    def outside(host: str) -> tuple:
        assert wired.put("/hub/online/push/address", {"address": host}).status_code == 200
        tried = wired.tried()
        assert tried["door"]["ok"] is True
        return tried["outside"]["ok"], tried["outside"]["reason"], tried["outside"]["code"]

    assert outside(ADDRESS) == (True, None, 401)
    assert outside("other.example.com") == (False, "elsewhere", 401)
    assert outside("login.example.com") == (False, "elsewhere", 401)
    assert outside("down.example.com") == (False, "tunnel_down", 530)
    assert outside("bad.example.com") == (False, "tunnel_down", 502)
    assert outside("lost.example.com") == (False, "not_routed", 404)
    assert outside("wall.example.com") == (False, "blocked", 403)
    assert outside("moved.example.com") == (False, "redirect", 301)
    assert outside("odd.example.com") == (False, "other", 200)
    assert outside("slow.example.com") == (False, "late", None)
    assert outside("nobody.example.com") == (False, "no_answer", None)
    assert not any(call.url.host == "evil.example.org" for call in wired.world.calls), "a redirect is not followed"
    assert wired.hub.status()["push"]["refused"] is None


def test_a_try_says_when_the_door_is_not_running_or_is_shut_and_then_knocks_nowhere_else(tmp_path):
    wired = Wired(tmp_path, door=False)
    wired.put("/hub/keys/online_push", {"key": TYPED_KEY})
    wired.put("/hub/online/push/address", {"address": ADDRESS})
    assert wired.tried() == {"door": {"ok": False, "reason": "no_answer", "code": None}, "outside": None}
    assert [call.url.host for call in wired.world.calls] == ["door"]
    # a door that was not told the key (its folder could not be written) is shut, and the try says so
    shut = Wired(tmp_path / "second") if (tmp_path / "second").mkdir() is None else None
    shut.put("/hub/keys/online_push", {"key": TYPED_KEY})
    (shut.door_dir / KEY_FILE).write_text(json.dumps({"sha256": None}))
    assert shut.tried()["door"] == {"ok": False, "reason": "shut", "code": 404}
    assert knocked_at_door({"code": 502, "refused": False}, False) == {"ok": False, "reason": "api", "code": 502}
    assert knocked_at_door({"code": 401, "refused": True}, False)["reason"] == "other", "refused, but not by this hub"
    assert knocked_outside({"code": 401, "refused": True, "late": False, "url": "u"}, False)["reason"] == "elsewhere"


def test_a_hub_set_up_in_its_terminal_goes_on_as_it_did_and_the_app_can_take_over(tmp_path):
    door, tunnel = folders(tmp_path)
    keys = HubKeys(environ={"POS_GLORIAFOOD_PUSH_KEY": PUSH_KEY, "POS_TUNNEL_TOKEN": TOKEN})
    wayin = WayIn(door, tunnel)
    hub = Hub(push=True, keys=keys, wayin=wayin)
    from pos.api.keys import hand_way_in

    hand_way_in(hub.client.app)  # as the hub starts
    assert json.loads((door / KEY_FILE).read_text()) == {"sha256": digest_of(PUSH_KEY)}
    assert (tunnel / TOKEN_FILE).read_text() == TOKEN
    street = Street(hub, door, key=PUSH_KEY)
    assert street.push(lunch(), key=PUSH_KEY).status_code == 200
    seen = hub.client.get("/hub/keys", headers=hub.manager()).json()
    by_name = {key["name"]: key for key in seen["keys"]}
    assert (by_name["online_push"]["source"], by_name["online_tunnel"]["source"]) == ("hub", "hub")
    assert by_name["online_tunnel"]["shown"] == {"tunnel": "6ff42ae2"}
    # removed in the app: none is in force, though the hub's file still names both
    hub.client.delete("/hub/keys/online_tunnel", headers=hub.manager())
    hub.client.delete("/hub/keys/online_push", headers=hub.manager())
    assert not (tunnel / TOKEN_FILE).exists() and street.push(lunch(302), key=PUSH_KEY).status_code == 404
    # and told again in the terminal: hubctl takes the app's word off, and the hub's file is in force again
    keys.store.drop(ONLINE_PUSH)
    keys.store.drop(ONLINE_TUNNEL)
    hand_way_in(hub.client.app)  # what the hub does within the minute (`watch_keys`)
    assert (tunnel / TOKEN_FILE).read_text() == TOKEN and street.push(lunch(302), key=PUSH_KEY).status_code == 200
