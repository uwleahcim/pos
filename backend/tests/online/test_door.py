"""The push door (pos.online.door): the one thing a way in from outside the building may reach. It hands a
push that carries the key on to the API and answers everything else with nothing."""

from __future__ import annotations

import json

import httpx
import pytest
from starlette.testclient import TestClient

from pos.online.door import PATH, Door, door_from_env
from pos.online.gloriafood import PUSH_MOST
from pos.online.service import NO_KEY_SENT, WRONG_KEY

from .hub import NOW, PUSH_KEY, Hub
from .orders import order, row


def lunch(number: int = 301) -> dict:
    return order(number, [row("Sweet & Sour Chicken", 2)])


class Inside(httpx.AsyncBaseTransport):
    """What reaches the API from the door: every call, as it was handed on."""

    def __init__(self, hub: Hub) -> None:
        self.calls: list[httpx.Request] = []
        self._api = httpx.ASGITransport(app=hub.client.app)

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        return await self._api.handle_async_request(request)


class Outside:
    """The door with a hub behind it, as GloriaFood and everybody else on the internet see it."""

    def __init__(self, hub: Hub | None = None, *, key: str | None = PUSH_KEY) -> None:
        self.hub = hub if hub is not None else Hub(push=True)
        self.inside = Inside(self.hub)
        inside = httpx.AsyncClient(transport=self.inside)
        self.client = TestClient(Door(to="http://api:8000", key=key, client=inside))

    def push(self, *orders: dict, key: str | None = PUSH_KEY, body: str | bytes | None = None) -> httpx.Response:
        if body is None:
            body = json.dumps({"count": len(orders), "orders": list(orders)})
        headers = {"Content-Type": "application/json"} | ({} if key is None else {"Authorization": key})
        return self.client.post(PATH, content=body, headers=headers)


def test_a_push_with_the_key_goes_through_the_door_onto_the_pos():
    outside = Outside()
    answer = outside.push(lunch())
    assert (answer.status_code, answer.json()) == (200, {"received": 1})
    assert outside.hub.order(301)["fields"]["order_no"] == 1
    assert outside.hub.inbox.get("gloriafood", "301").via == "push"
    (call,) = outside.inside.calls
    assert (call.method, str(call.url)) == ("POST", "http://api:8000/online/push")


def test_a_push_without_the_key_is_not_read_and_the_hub_still_hears_of_it():
    outside = Outside()
    nothing = outside.push(lunch(), key=None)
    wrong = outside.push(lunch(), key="somebody-else's-key")
    for answer in (nothing, wrong):
        assert (answer.status_code, answer.json()) == (401, {"error": "refused"})
    # only the header went inside, with nothing of the order
    assert [call.content for call in outside.inside.calls] == [b"", b""]
    assert outside.hub.inbox.since(0) == []
    refused = outside.hub.status()["push"]["refused"]
    assert refused == {"at_ms": NOW, "reason": WRONG_KEY, "count": 2}
    assert NO_KEY_SENT != WRONG_KEY


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", PATH),
        ("PUT", PATH),
        ("DELETE", PATH),
        ("POST", "/online/push/"),
        ("POST", "/online/fetch"),
        ("GET", "/online/status"),
        ("GET", "/online/orders/301"),
        ("GET", "/orders"),
        ("POST", "/admin/session"),
        ("GET", "/health"),
        ("GET", "/docs"),
        ("GET", "/openapi.json"),
        ("GET", "/"),
    ],
)
def test_nothing_else_of_the_hub_is_behind_the_door(method: str, path: str):
    outside = Outside()
    outside.hub.accept(lunch())
    answer = outside.client.request(
        method, path, headers={"Authorization": PUSH_KEY}, json={"device": "x", "pin": "9999"}
    )
    assert (answer.status_code, answer.content) == (404, b"")
    assert outside.inside.calls == []  # it never reached the API


def test_a_door_without_a_key_is_shut():
    outside = Outside(key=None)
    for key in (None, PUSH_KEY, ""):
        answer = outside.push(lunch(), key=key)
        assert (answer.status_code, answer.content) == (404, b"")
    assert outside.inside.calls == []


def test_a_push_that_is_too_big_is_not_handed_on():
    outside = Outside()
    answer = outside.push(body=b'{"orders": [' + b" " * PUSH_MOST + b"]}")
    assert (answer.status_code, answer.json()) == (413, {"error": "too_big"})
    assert outside.inside.calls == []


def test_what_the_hub_answers_is_handed_back_and_nothing_more():
    outside = Outside()
    unreadable = outside.push(body="not JSON")
    assert (unreadable.status_code, unreadable.json()) == (422, {"error": "unreadable"})
    assert outside.push(lunch()).json() == {"received": 1}
    assert outside.push(lunch()).json() == {"received": 1}  # the same order again: taken, and one order
    assert len(outside.hub.client.get("/orders").json()["orders"]) == 1


def test_an_api_that_is_down_or_slow_is_an_error_gloriafood_can_see():
    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route", request=request)

    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("too slow", request=request)

    def odd(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text="<html>the POS, by mistake</html>")

    for handler, status, error in ((down, 502, "down"), (slow, 504, "late"), (odd, 502, "trouble")):
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        door = TestClient(Door(to="http://api:8000", key=PUSH_KEY, client=client))
        answer = door.post(PATH, content="{}", headers={"Authorization": PUSH_KEY})
        assert (answer.status_code, answer.json()) == (status, {"error": error})


def test_the_hub_s_door_reads_its_key_and_where_the_api_is():
    shut = door_from_env({})
    assert TestClient(shut).post(PATH, content="{}", headers={"Authorization": PUSH_KEY}).status_code == 404
    seen: list[str] = []

    def api(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, json={"received": 0})

    door = door_from_env({"POS_GLORIAFOOD_PUSH_KEY": f" {PUSH_KEY} ", "POS_DOOR_TO": "http://elsewhere:9000/"})
    door._client = httpx.AsyncClient(transport=httpx.MockTransport(api))
    assert TestClient(door).post(PATH, content="{}", headers={"Authorization": PUSH_KEY}).json() == {"received": 0}
    assert seen == ["http://elsewhere:9000/online/push"]
