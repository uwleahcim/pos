"""The change feed (`pos.api.feed`): what a screen holding `/live` open is told, and when."""

from __future__ import annotations

import asyncio
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from collections.abc import AsyncIterator, Iterator
from typing import Any

import httpx
import pytest
import uvicorn
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.api.feed import BEAT, MANY, ChangeFeed
from pos.identity.staff import demo_directory
from pos.menu.service import MenuService, load_definitions
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore

from .conftest import T0, make_op

DSN = os.environ.get("POS_TEST_DATABASE_URL")


def told(chunk: bytes) -> tuple[str, dict[str, Any]]:
    """One frame as (event, data); a heartbeat is ("beat", {})."""
    if chunk == BEAT:
        return "beat", {}
    event, data = chunk.decode().rstrip("\n").split("\n")
    return event.removeprefix("event: "), json.loads(data.removeprefix("data: "))


async def nxt(stream: AsyncIterator[bytes], within: float = 2.0) -> tuple[str, dict[str, Any]]:
    return told(await asyncio.wait_for(anext(stream), within))


# The feed by itself -----------------------------------------------------------------------------------------


def test_a_screen_is_greeted_then_told_each_change_once():
    async def scenario() -> None:
        feed = ChangeFeed(heartbeat=30)
        stream = feed.stream({"cursor": 7, "menu": 3})
        assert await nxt(stream) == ("hello", {"cursor": 7, "menu": 3, "heartbeat": 30})
        assert feed.screens == 1
        # three changes before the screen reads: one line, each order once, in the order they changed
        feed.orders_changed(["o2", "o1"], cursor=9)
        feed.changed("menu")
        feed.orders_changed(["o1", "o3"], cursor=11)
        assert await nxt(stream) == ("changed", {"orders": ["o2", "o1", "o3"], "topics": ["menu"], "cursor": 11})
        # and nothing is told twice
        feed.changed("settings")
        assert await nxt(stream) == ("changed", {"orders": [], "topics": ["settings"]})
        await stream.aclose()
        assert feed.screens == 0

    asyncio.run(scenario())


def test_a_quiet_stream_carries_a_heartbeat():
    async def scenario() -> None:
        feed = ChangeFeed(heartbeat=0.05)
        stream = feed.stream({"cursor": 0})
        assert (await nxt(stream))[0] == "hello"
        started = time.monotonic()
        assert [await nxt(stream), await nxt(stream)] == [("beat", {}), ("beat", {})]
        assert 0.08 <= time.monotonic() - started < 1.0
        feed.orders_changed(["o1"])
        assert await nxt(stream) == ("changed", {"orders": ["o1"], "topics": []})
        await stream.aclose()

    asyncio.run(scenario())


def test_every_screen_is_told_and_one_that_left_is_forgotten():
    async def scenario() -> None:
        feed = ChangeFeed(heartbeat=30)
        one, two = feed.stream({}), feed.stream({})
        await nxt(one), await nxt(two)
        assert feed.screens == 2
        feed.orders_changed(["o1"])
        assert (await nxt(one))[1]["orders"] == (await nxt(two))[1]["orders"] == ["o1"]
        await one.aclose()
        assert feed.screens == 1
        feed.orders_changed(["o2"])
        assert (await nxt(two))[1]["orders"] == ["o2"]
        await two.aclose()

    asyncio.run(scenario())


def test_a_screen_far_behind_is_told_to_read_everything():
    """A stream nobody reads does not grow the hub: past MANY orders it is one flag."""

    async def scenario() -> None:
        feed = ChangeFeed(heartbeat=30)
        stream = feed.stream({})
        await nxt(stream)
        feed.orders_changed([f"o{n}" for n in range(MANY + 1)], cursor=500)
        assert await nxt(stream) == ("changed", {"orders": [], "topics": [], "everything": True, "cursor": 500})
        feed.orders_changed(["o1"])
        assert await nxt(stream) == ("changed", {"orders": ["o1"], "topics": []})
        await stream.aclose()

    asyncio.run(scenario())


def test_a_change_made_on_another_thread_reaches_the_stream():
    """The API's own handlers run on worker threads; the streams live on the server's loop."""

    async def scenario() -> None:
        feed = ChangeFeed(heartbeat=30)
        stream = feed.stream({})
        await nxt(stream)
        threading.Thread(target=lambda: feed.changed("menu")).start()
        assert await nxt(stream) == ("changed", {"orders": [], "topics": ["menu"]})
        await stream.aclose()

    asyncio.run(scenario())


def test_the_log_is_watched_while_a_screen_listens():
    """What arrives in the log is told whoever wrote it: at once after a poke, within `every` without one."""

    async def scenario() -> None:
        store = OpStore(physical=lambda: T0 + 1_000)
        store.append([make_op("create", "o0")])
        checks = []
        feed = ChangeFeed(heartbeat=30, every=0.05)
        feed.follow(store, also=lambda: checks.append(1))
        feed.poke()  # nobody listens: nothing happens, nothing is kept
        stream = feed.stream({"cursor": store.cursor})
        assert (await nxt(stream))[0] == "hello"
        # written behind the feed's back, as another worker or the primary of this standby would
        store.append([make_op("create", "o1"), make_op("add_line", "o1", line_id="L1", item="x")])
        assert await nxt(stream) == ("changed", {"orders": ["o1"], "topics": [], "cursor": 3})
        store.append([make_op("create", "o2")])
        assert await nxt(stream) == ("changed", {"orders": ["o2"], "topics": [], "cursor": 4})
        assert checks  # the menu's own check ran with the looks
        await stream.aclose()
        assert feed._watcher is not None
        await asyncio.wait_for(feed._watcher, 2.0)  # nobody listens: nothing runs
        # the next screen starts it again, from its own cursor: what it missed it reads itself on hello
        store.append([make_op("create", "o3")])
        again = feed.stream({"cursor": store.cursor})
        assert (await nxt(again))[0] == "hello"
        store.append([make_op("create", "o4")])
        assert await nxt(again) == ("changed", {"orders": ["o4"], "topics": [], "cursor": 6})
        await again.aclose()

    asyncio.run(scenario())


def test_a_poke_tells_without_waiting_for_the_next_look():
    async def scenario() -> None:
        store = OpStore(physical=lambda: T0 + 1_000)
        feed = ChangeFeed(heartbeat=30, every=30)
        feed.follow(store)
        stream = feed.stream({"cursor": 0})
        await nxt(stream)
        await asyncio.sleep(0.05)  # the watcher has had its first look and waits out its thirty seconds
        store.append([make_op("create", "o1")])
        feed.poke()
        started = time.monotonic()
        assert await nxt(stream, within=1.0) == ("changed", {"orders": ["o1"], "topics": [], "cursor": 1})
        assert time.monotonic() - started < 0.5
        await stream.aclose()

    asyncio.run(scenario())


def test_a_log_that_cannot_be_read_is_tried_again():
    """The database away for a moment: the stream stays up, and the news comes when it is back."""

    class Flaky(OpStore):
        broken = True

        def arrivals(self, cursor: int, limit: int = 2000) -> list[tuple[int, str]]:
            if self.broken:
                raise RuntimeError("database away")
            return super().arrivals(cursor, limit)

    async def scenario() -> None:
        store = Flaky(physical=lambda: T0 + 1_000)
        feed = ChangeFeed(heartbeat=30, every=0.02)
        feed.follow(store)
        stream = feed.stream({"cursor": 0})
        await nxt(stream)
        store.append([make_op("create", "o1")])
        await asyncio.sleep(0.1)
        store.broken = False
        assert await nxt(stream) == ("changed", {"orders": ["o1"], "topics": [], "cursor": 1})
        await stream.aclose()

    asyncio.run(scenario())


# What the API tells -----------------------------------------------------------------------------------------


class Heard(ChangeFeed):
    """A feed that writes down what it was asked to tell."""

    def __init__(self) -> None:
        super().__init__()
        self.pokes = 0
        self.topics: list[str] = []

    def poke(self) -> None:
        self.pokes += 1

    def changed(self, topic: str) -> None:
        self.topics.append(topic)


def payload(op_id: str, kind: str, at: int, order_id: str = "o1", **data):
    stamp = str(HLC(T0 + at, 0, "t1"))
    return {"op_id": op_id, "order_id": order_id, "hlc": stamp, "device": "t1", "kind": kind, "data": data}


def test_the_api_pokes_the_feed_for_new_operations_only():
    feed = Heard()
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100), feed=feed))
    ops = [payload("a", "create", 0, table=4)]
    client.post("/orders/o1/ops", json=ops)
    assert feed.pokes == 1
    client.post("/orders/o1/ops", json=ops)  # the outbox sending it again: nothing new, nothing told
    assert feed.pokes == 1
    assert client.get("/health").json()["screens"] == 0


def test_the_menu_and_the_settings_tell_their_changes():
    feed = Heard()
    menu = MenuService(load_definitions("example"))
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100), staff=demo_directory(), menu=menu, feed=feed))
    assert client.post("/menu/86", json={"target_id": "GTC:quart", "status": "sold_out"}).status_code == 200
    assert feed.topics == ["menu"]
    token = client.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    auth = {"authorization": f"Bearer {token}"}
    saved = client.put("/settings/coursing", json={"enabled": False, "courses": []}, headers=auth)
    assert saved.status_code == 200, saved.text
    assert feed.topics == ["menu", "settings"]
    # a write that is refused tells nothing
    assert client.put("/settings/coursing", json={"enabled": False, "courses": []}).status_code in (401, 403)
    assert feed.topics == ["menu", "settings"]


# Over a real connection -------------------------------------------------------------------------------------


class Hub:
    """The API served by uvicorn on a free local port, as the hub serves it: a stream that never ends cannot
    be read through the in-process test client, which waits for the whole answer."""

    def __init__(self, app: Any) -> None:
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.url = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        config = uvicorn.Config(app, log_level="warning", lifespan="off", timeout_graceful_shutdown=1)
        self.server = uvicorn.Server(config)
        self.thread = threading.Thread(target=self.server.run, kwargs={"sockets": [self.sock]}, daemon=True)

    def __enter__(self) -> Hub:
        self.thread.start()
        deadline = time.monotonic() + 10
        while not self.server.started:
            assert time.monotonic() < deadline, "the test hub did not start"
            time.sleep(0.01)
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.should_exit = True
        self.thread.join(10)
        assert not self.thread.is_alive(), "the test hub did not stop"


def frames(response: httpx.Response) -> Iterator[tuple[str, dict[str, Any]]]:
    """The stream as (event, data) pairs; a heartbeat is ("beat", {}). Reading waits at most the client's
    read timeout, so a line that never comes fails the test instead of hanging it."""
    event, data = "", ""
    for line in response.iter_lines():
        if line.startswith("event:"):
            event = line.removeprefix("event:").strip()
        elif line.startswith("data:"):
            data = line.removeprefix("data:").strip()
        elif line.startswith(":"):
            event, data = "beat", "{}"
        elif not line and event:
            yield event, json.loads(data)
            event, data = "", ""


def news(stream: Iterator[tuple[str, dict[str, Any]]]) -> tuple[str, dict[str, Any]]:
    """The next line that is not a heartbeat."""
    return next(frame for frame in stream if frame[0] != "beat")


def waited(condition, seconds: float = 3.0) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    return False


def test_a_screen_hears_of_an_order_the_moment_another_screen_sends_it():
    store = OpStore(physical=lambda: T0 + 100)
    # `every` far longer than the test: what arrives here was pushed by the append, not found by the watcher
    menu = MenuService(load_definitions("example"))
    app = create_app(store, menu=menu, feed=ChangeFeed(heartbeat=0.2, every=30))
    with Hub(app) as hub, httpx.Client(base_url=hub.url, timeout=5) as client:
        client.post("/orders/o0/ops", json=[payload("z", "create", 0, order_id="o0")])
        headers = {"accept": "text/event-stream", "accept-encoding": "gzip"}
        with client.stream("GET", "/live", params={"device": "mac1"}, headers=headers) as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            assert "content-encoding" not in response.headers  # compressed, a line would wait for the next
            assert response.headers["cache-control"] == "no-store"
            stream = frames(response)
            event, hello = next(stream)
            assert event == "hello" and hello["cursor"] == 1 and hello["heartbeat"] == 0.2
            assert hello["menu"] == client.get("/menu/revision").json()["revision"]
            assert client.get("/health").json()["screens"] == 1
            assert "mac1" in [d["device"] for d in client.get("/devices").json()["devices"]]

            started = time.monotonic()
            sent = client.post("/orders/o1/ops", json=[payload("a", "create", 1, table=4)])
            assert sent.status_code == 202
            assert news(stream) == ("changed", {"orders": ["o1"], "topics": [], "cursor": 2})
            assert time.monotonic() - started < 1.0

            # a quiet hub still writes: that is how the screen knows it is alive
            assert next(stream) == ("beat", {})

            client.post("/menu/86", json={"target_id": "GTC:quart", "status": "sold_out"})
            assert news(stream) == ("changed", {"orders": [], "topics": ["menu"]})
        # the screen went away: the hub forgets it
        assert waited(lambda: client.get("/health").json()["screens"] == 0)


def test_two_screens_and_the_reads_they_make_afterwards():
    """The stream only says which order changed; the screen reads it as it always did, and the read it
    already has is still answered 304."""
    app = create_app(OpStore(physical=lambda: T0 + 100), feed=ChangeFeed(heartbeat=5, every=30))
    with Hub(app) as hub, httpx.Client(base_url=hub.url, timeout=5) as client:
        with client.stream("GET", "/live") as one, client.stream("GET", "/live") as two:
            first, second = frames(one), frames(two)
            assert next(first)[0] == next(second)[0] == "hello"
            client.post("/orders/o1/ops", json=[payload("a", "create", 1, table=4)])
            assert news(first)[1]["orders"] == news(second)[1]["orders"] == ["o1"]
            listed = client.get("/orders", params={"hours": 18, "brief": True})
            assert [o["order_id"] for o in listed.json()["orders"]] == ["o1"]
            again = client.get(
                "/orders", params={"hours": 18, "brief": True}, headers={"if-none-match": listed.headers["etag"]}
            )
            assert again.status_code == 304
            assert client.get("/health").json()["screens"] == 2
        assert waited(lambda: client.get("/health").json()["screens"] == 0)


def test_closing_the_feed_ends_every_stream():
    """What the stop signal does (`end_on_stop`): the streams end, so the server has nothing left to wait for."""

    async def scenario() -> None:
        store = OpStore(physical=lambda: T0 + 1_000)
        feed = ChangeFeed(heartbeat=30, every=30)
        feed.follow(store)
        stream = feed.stream({"cursor": 0})
        await nxt(stream)
        watcher = feed._watcher
        feed.close()
        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(anext(stream), 1.0)
        assert feed.screens == 0
        await asyncio.wait_for(watcher, 1.0)  # and the watcher with them
        late = feed.stream({"cursor": 0})  # a screen that connects while the hub stops: greeted, then let go
        assert (await nxt(late))[0] == "hello"
        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(anext(late), 1.0)

    asyncio.run(scenario())


def test_the_hub_stops_at_once_with_screens_attached():
    """The real server, as the image starts it: a stop signal ends the open streams, and the process is gone
    well inside the time docker gives it, where it used to wait on them until it was killed."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    env = {k: v for k, v in os.environ.items() if k not in ("DATABASE_URL", "MENU_DATABASE_URL")}
    # the image's own command (backend/Dockerfile), on a free port
    command = [sys.executable, "-m", "uvicorn", "pos.api.app:app", "--port", str(port), "--workers", "1"]
    command += ["--timeout-graceful-shutdown", "3", "--log-level", "warning"]
    hub = subprocess.Popen(command, env=env, stderr=subprocess.PIPE, text=True)
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=10) as client:

            def up() -> bool:
                try:
                    return client.get("/health").status_code == 200
                except httpx.TransportError:
                    return False

            assert waited(up, 30), "the hub did not start"
            with client.stream("GET", "/live") as one, client.stream("GET", "/live") as two:
                first, second = one.iter_lines(), two.iter_lines()
                assert next(first) == next(second) == "event: hello"
                assert client.get("/health").json()["screens"] == 2
                started = time.monotonic()
                hub.send_signal(signal.SIGTERM)
                list(first), list(second)  # both streams end, cleanly
        hub.wait(5)
        assert time.monotonic() - started < 2.0
    finally:
        if hub.poll() is None:
            hub.kill()
        errors = hub.stderr.read() if hub.stderr else ""
        hub.wait()
    assert "Traceback" not in errors and "Exception" not in errors, errors


def test_an_older_client_that_only_polls_is_served_as_before():
    app = create_app(OpStore(physical=lambda: T0 + 100))
    client = TestClient(app)
    client.post("/orders/o1/ops", json=[payload("a", "create", 1, table=4)])
    assert client.get("/orders/o1").status_code == 200
    assert client.get("/health").json() == {"status": "ok", "cursor": 1, "role": "memory", "node": "", "screens": 0}


@pytest.mark.skipif(not DSN, reason="POS_TEST_DATABASE_URL not set")
def test_what_another_process_writes_to_the_database_is_told():
    """Two API workers, or a standby whose database follows the primary: the operation was never appended
    here, and the screens on this process still hear of it within the watcher's interval."""
    import psycopg

    from pos.sync.pgstore import PgOpStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops")
        conn.execute("DROP TABLE IF EXISTS orders")
    here, there = PgOpStore(DSN, physical=lambda: T0 + 1_000), PgOpStore(DSN, physical=lambda: T0 + 1_000)
    try:
        there.append([make_op("create", "o0")])
        assert here.arrivals(0) == [(1, "o0")] and here.arrivals(1) == []
        app = create_app(here, feed=ChangeFeed(heartbeat=5, every=0.1))
        with Hub(app) as hub, httpx.Client(base_url=hub.url, timeout=5) as client:
            with client.stream("GET", "/live") as response:
                stream = frames(response)
                assert next(stream) == (
                    "hello",
                    {"cursor": 1, "menu": app.state.menu.revision, "role": "primary", "node": "", "heartbeat": 5},
                )
                there.append([make_op("create", "o7"), make_op("add_line", "o7", line_id="L1", item="x")])
                assert news(stream) == ("changed", {"orders": ["o7"], "topics": [], "cursor": 3})
                there.append([make_op("create", "o8"), make_op("create", "o9"), make_op("close", "o8")])
                assert news(stream) == ("changed", {"orders": ["o8", "o9"], "topics": [], "cursor": 6})
                assert here.arrivals(3, 2) == [(4, "o8"), (5, "o9")]
    finally:
        here.close()
        there.close()


# The menu's answer, when every screen asks for it at once -------------------------------------------------


def test_the_menu_answer_is_worked_out_once_for_screens_that_ask_together():
    """Told that the menu changed, every screen reads it in the same instant: they share one answer, and a
    change (an 86, a save, the clock moving on) is never served from the answer before it."""
    from datetime import datetime, timedelta

    now = datetime(2026, 11, 13, 18, 0, 0)
    menu = MenuService(load_definitions("example"), now=lambda: now)
    told: list[int] = []
    menu.on_change = lambda: told.append(1)
    first = menu.menus()
    assert menu.menus() is first  # the same second: the same answer, not worked out again
    assert menu.menus(locale="zh") is not first and menu.menus(at=now) is not first

    def quart() -> str:
        sizes = [v for m in menu.menus() for s in m["sections"] for e in s["entries"] for v in e["variants"]]
        return next(v["status"] for v in sizes if v["variant_id"] == "GTC:quart")

    assert quart() == "available"
    menu.set_availability("GTC:quart", "sold_out")
    assert told == [1] and quart() == "sold_out"  # in the same second, and not the answer from before the 86
    after = menu.menus()
    now += timedelta(seconds=1)
    assert menu.menus() is not after  # the clock moved: lunch may have ended
    menu.save(menu.defs, actor="test")
    assert told == [1, 1]


def test_screens_asking_for_the_menu_together_wait_for_one_answer():
    menu = MenuService(load_definitions("example"))
    worked = []
    plain = menu._menus

    def slow(channel: str, locale: str, at: Any) -> Any:
        worked.append(1)
        time.sleep(0.05)
        return plain(channel, locale, at)

    menu._menus = slow  # type: ignore[method-assign]
    # the wall clock may tick over during the test, so two workings at most, never one per screen
    answers: list[Any] = []
    screens = [threading.Thread(target=lambda: answers.append(menu.menus())) for _ in range(12)]
    for screen in screens:
        screen.start()
    for screen in screens:
        screen.join()
    assert len(answers) == 12 and 1 <= len(worked) <= 3
