"""Asking GloriaFood for the accepted orders, and reading what it sends by itself (pos.online.gloriafood),
against a GloriaFood that is a function."""

from __future__ import annotations

import json

import httpx
import pytest

from pos.online.gloriafood import (
    API_VERSION,
    POP_URL,
    FetchFailed,
    GloriaFood,
    allowed,
    push_key_from_env,
    pushed,
    source_from_env,
)

KEY = "made-up-key-0123456789"


def food(handler) -> GloriaFood:
    return GloriaFood(KEY, client=httpx.Client(transport=httpx.MockTransport(handler)))


def answering(status: int = 200, body: object = None, text: str | None = None):
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if text is not None:
            return httpx.Response(status, text=text)
        return httpx.Response(status, json=body)

    return handler, seen


def test_it_asks_with_the_key_in_a_header_and_sends_nothing_else():
    handler, seen = answering(body={"count": 0, "orders": []})
    assert food(handler).pop() == []
    (request,) = seen
    assert (request.method, str(request.url)) == ("POST", POP_URL)
    assert request.headers["Authorization"] == KEY
    assert request.headers["Glf-Api-Version"] == API_VERSION
    assert request.headers["Accept"] == "application/json"
    assert request.content == b""  # no order, no customer, nothing of the POS leaves the building
    assert KEY not in str(request.url)


def test_it_gives_the_orders_as_they_came_without_the_restaurant_s_own_keys():
    order = {"id": 7, "type": "pickup", "restaurant_key": "secret", "restaurant_token": "secret", "items": []}
    handler, _ = answering(body={"count": 1, "orders": [order]})
    assert food(handler).pop() == [{"id": 7, "type": "pickup", "items": []}]


@pytest.mark.parametrize("text", ["", "  \n", json.dumps({"count": 0}), json.dumps({"orders": []})])
def test_no_orders_is_an_empty_list(text):
    handler, _ = answering(text=text)
    assert food(handler).pop() == []


@pytest.mark.parametrize(
    ("status", "said"),
    [
        (401, "GloriaFood refused the key"),
        (403, "GloriaFood refused the key"),
        (429, "GloriaFood says it is asked too often"),
        (500, "GloriaFood answered with an error (500)"),
        (302, "GloriaFood answered with an error (302)"),
    ],
)
def test_an_answer_that_is_no_orders_says_why_in_words(status, said):
    handler, _ = answering(status, text="nope")
    with pytest.raises(FetchFailed) as failed:
        food(handler).pop()
    assert failed.value.reason == said
    assert failed.value.body is None  # nothing was handed over: nothing to keep
    assert KEY not in failed.value.reason


@pytest.mark.parametrize(
    "text",
    ["<html>maintenance</html>", json.dumps({"count": 2, "orders": "soon"}), json.dumps({"orders": [1, 2]}), "[]"],
)
def test_an_answer_that_cannot_be_read_is_handed_back_to_be_kept(text):
    # GloriaFood answered: whatever orders were in it will not be sent again
    handler, _ = answering(text=text)
    with pytest.raises(FetchFailed) as failed:
        food(handler).pop()
    assert failed.value.reason == "GloriaFood's answer could not be read"
    assert failed.value.body == text


def test_no_answer_says_so_and_never_the_key():
    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("too slow", request=request)

    def gone(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"no route with {KEY}", request=request)

    with pytest.raises(FetchFailed) as timed_out:
        food(slow).pop()
    assert timed_out.value.reason == "GloriaFood did not answer in time"
    with pytest.raises(FetchFailed) as unreachable:
        food(gone).pop()
    assert unreachable.value.reason == "GloriaFood could not be reached (ConnectError)"
    assert unreachable.value.__cause__ is None and unreachable.value.__suppress_context__  # no key in a traceback


def test_a_hub_with_no_key_asks_nobody():
    assert source_from_env({}) is None
    assert source_from_env({"POS_GLORIAFOOD_KEY": "  "}) is None
    assert isinstance(source_from_env({"POS_GLORIAFOOD_KEY": f" {KEY} "}), GloriaFood)


def test_an_answer_that_cannot_be_read_is_kept_without_the_restaurant_s_keys():
    text = '{"count": 1, "orders": [{"id": 7, "restaurant_key": "secret-one", "restaurant_token" : "secret-two", '
    handler, _ = answering(text=text)
    with pytest.raises(FetchFailed) as failed:
        food(handler).pop()
    assert failed.value.reason == "GloriaFood's answer could not be read"
    assert "secret" not in failed.value.body and '"id": 7' in failed.value.body
    assert failed.value.body.count("(left out)") == 2


# A push ------------------------------------------------------------------------------------------------------


def test_a_push_is_let_in_only_with_the_key_the_hub_was_given():
    assert allowed(KEY, KEY) and allowed(f"  {KEY} ", KEY)
    for given in (None, "", " ", KEY[:-1], KEY + "0", KEY.upper(), f"Bearer {KEY}", "clé"):
        assert not allowed(given, KEY), given
    for no_key in (None, ""):  # a hub with no key for pushes lets nothing in, whatever is sent
        assert not allowed(KEY, no_key) and not allowed("", no_key) and not allowed(None, no_key)


def test_a_hub_with_no_key_for_pushes_has_none():
    assert push_key_from_env({}) is None
    assert push_key_from_env({"POS_GLORIAFOOD_PUSH_KEY": "  "}) is None
    assert push_key_from_env({"POS_GLORIAFOOD_PUSH_KEY": f" {KEY} "}) == KEY
    assert push_key_from_env({"POS_GLORIAFOOD_KEY": KEY}) is None  # the key for asking is another key


def test_a_push_is_read_as_an_answer_is_and_also_one_order_by_itself_or_a_bare_list():
    one = {"id": 7, "type": "pickup", "restaurant_key": "secret-one", "restaurant_token": "secret-two"}
    read = [{"id": 7, "type": "pickup"}]  # the restaurant's own keys are left out
    assert pushed(json.dumps({"count": 1, "orders": [one]}).encode()) == read
    assert pushed(json.dumps(one).encode()) == read
    assert pushed(json.dumps([one, one]).encode()) == read * 2
    for none in (b"", b"  \n", b"{}", b'{"count": 0}', b'{"count": 0, "orders": []}', b'{"orders": []}', b"[]"):
        assert pushed(none) == [], none


@pytest.mark.parametrize(
    ("body", "why"),
    [
        (b"<orders><order><id>7</id></order></orders>", "it came as XML, and the hub reads JSON"),
        (b"hello", "it is not JSON"),
        (b"\xff\xfe\x00", "it is not text"),
        (b'{"error": "nope", "client_first_name": "Pat"}', "it holds no orders, but: client_first_name, error"),
        (b'{"count": 2, "orders": "soon"}', "it holds no orders, but: count, orders"),
        (b'{"orders": [1, 2]}', "it holds no orders, but: orders"),
        (b"[1, 2]", "it is a list, not orders"),
        (b'"7"', "it is a str, not orders"),
    ],
)
def test_a_push_that_cannot_be_read_says_what_it_looked_like_and_nothing_of_a_customer(body, why):
    with pytest.raises(FetchFailed) as failed:
        pushed(body)
    assert failed.value.reason == f"GloriaFood's push could not be read ({why})"
    assert "Pat" not in failed.value.reason


def test_a_push_that_cannot_be_read_is_kept_without_the_restaurant_s_keys_in_either_language():
    xml = b"<order><id>7</id><restaurant_key>secret-one</restaurant_key><restaurant_token>secret-two</restaurant_token>"
    with pytest.raises(FetchFailed) as failed:
        pushed(xml)
    assert "secret" not in failed.value.body and "<id>7</id>" in failed.value.body
    assert failed.value.body.count("(left out)") == 2
    odd = b'{"event": "x", "restaurant_key": "secret-one", "RESTAURANT_TOKEN" : "secret-two"}'
    with pytest.raises(FetchFailed) as failed:
        pushed(odd)
    assert "secret" not in failed.value.body and failed.value.body.count("(left out)") == 2
