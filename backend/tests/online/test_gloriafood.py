"""Asking GloriaFood for the accepted orders (pos.online.gloriafood), against a GloriaFood that is a function."""

from __future__ import annotations

import json

import httpx
import pytest

from pos.online.gloriafood import API_VERSION, POP_URL, FetchFailed, GloriaFood, source_from_env

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
