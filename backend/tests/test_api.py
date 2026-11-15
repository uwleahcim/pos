from __future__ import annotations

from datetime import UTC, datetime
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu.service import MenuService, load_definitions
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore

from .conftest import T0


def payload(op_id: str, kind: str, at: int, **data):
    return {
        "op_id": op_id,
        "order_id": "o1",
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def test_append_read_and_pull():
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100)))
    ops = [payload("a", "create", 0, table=4), payload("b", "add_line", 1, line_id="L1", item="Tsingtao", qty=2)]
    first = client.post("/orders/o1/ops", json=ops).json()
    assert (first["accepted"], first["cursor"], first["print_jobs"]) == (["a", "b"], 2, [])
    second = client.post("/orders/o1/ops", json=ops).json()
    assert (second["accepted"], second["cursor"]) == ([], 2)

    order = client.get("/orders/o1").json()
    assert order["fields"] == {"table": 4}
    assert order["lines"]["L1"]["qty"] == 2

    pulled = client.get("/ops", params={"since": 1}).json()
    assert [op["op_id"] for op in pulled["ops"]] == ["b"] and pulled["cursor"] == 2
    assert client.get("/orders/nope").status_code == 404

    client.post("/orders/o2/ops", json=[{**payload("c", "create", 5, table=7), "order_id": "o2"}])
    client.post("/orders/o2/ops", json=[{**payload("d", "close", 6), "order_id": "o2"}])
    listed = client.get("/orders").json()
    assert [o["order_id"] for o in listed["orders"]] == ["o2", "o1"] and listed["cursor"] == 4
    assert [o["order_id"] for o in client.get("/orders", params={"status": "open"}).json()["orders"]] == ["o1"]
    assert client.get("/orders", params={"status": "weird"}).status_code == 422


def test_big_reads_come_compressed_for_a_client_that_accepts_it():
    """The app saves every dish's choices in one read (over ten megabytes for the restaurant's menu): a few
    hundred kilobytes over the wire when the client accepts gzip, and the same bytes as ever when it does not."""
    client = TestClient(create_app(OpStore(physical=lambda: T0)))
    compressed = client.get("/menu/items", headers={"accept-encoding": "gzip"})
    assert compressed.status_code == 200 and compressed.headers["content-encoding"] == "gzip"
    plain = client.get("/menu/items", headers={"accept-encoding": "identity"})
    assert plain.status_code == 200 and "content-encoding" not in plain.headers
    assert compressed.json() == plain.json()
    assert client.get("/health", headers={"accept-encoding": "gzip"}).headers.get("content-encoding") is None


def test_a_read_that_has_not_changed_is_answered_with_no_body():
    """The screens ask for the open orders, the floor and the open check every two seconds: an answer the
    screen already has comes back as 304 with nothing in it, and the full answer again once it changed."""
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100)))
    client.post("/orders/o1/ops", json=[payload("a", "create", 0, table=4)])
    for path in ("/orders?status=open", "/orders/o1", "/orders/o1/check", "/floor", "/menu", "/settings/coursing"):
        first = client.get(path)
        etag = first.headers["etag"]
        assert first.status_code == 200 and etag.startswith('W/"')
        again = client.get(path, headers={"if-none-match": etag})
        assert (again.status_code, again.content, again.headers["etag"]) == (304, b"", etag), path
        assert "content-type" not in again.headers
        assert client.get(path, headers={"if-none-match": 'W/"something-else"'}).json() == first.json()
        assert client.get(path, headers={"if-none-match": f'"other", {etag}'}).status_code == 304
    # compressed or not, the answer has the same name
    etag = client.get("/menu", headers={"accept-encoding": "identity"}).headers["etag"]
    zipped = client.get("/menu", headers={"accept-encoding": "gzip"})
    assert zipped.headers["content-encoding"] == "gzip" and zipped.headers["etag"] == etag
    assert client.get("/menu", headers={"accept-encoding": "gzip", "if-none-match": etag}).status_code == 304

    etag = client.get("/orders/o1").headers["etag"]
    client.post("/orders/o1/ops", json=[payload("b", "add_line", 1, line_id="L1", item="Tsingtao", qty=2)])
    changed = client.get("/orders/o1", headers={"if-none-match": etag})
    assert changed.status_code == 200 and changed.headers["etag"] != etag and changed.json()["lines"]["L1"]["qty"] == 2
    # refusals and writes are left alone
    missing = client.get("/orders/nope", headers={"if-none-match": etag})
    assert missing.status_code == 404 and "etag" not in missing.headers
    posted = client.post("/orders/o1/ops", json=[payload("b", "add_line", 1)], headers={"if-none-match": etag})
    assert posted.status_code == 202 and "etag" not in posted.headers


def test_a_screen_lists_the_open_orders_and_the_recent_ones():
    """`hours` keeps the list the size of a day: the orders still open, however old, and the ones that changed
    within those hours. Without it every order the store knows is listed, as before."""
    hour = 3_600_000
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100 * hour)))

    def order(order_id: str, at: int, *more: str) -> None:
        ops = [payload(f"{order_id}-create", "create", at, table=1)]
        ops += [payload(f"{order_id}-{kind}", kind, at + i + 1) for i, kind in enumerate(more)]
        client.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops])

    order("last-week", 0, "close")
    order("forgotten", 1 * hour)  # opened days ago and never closed: still a check someone owes
    order("lunch", 90 * hour, "close")
    order("voided", 95 * hour, "void_order")
    order("dinner", 99 * hour)

    def listed(**params) -> list[str]:
        return [o["order_id"] for o in client.get("/orders", params=params).json()["orders"]]

    assert listed() == ["dinner", "voided", "lunch", "forgotten", "last-week"]
    assert listed(hours=24) == ["dinner", "voided", "lunch", "forgotten"]
    assert listed(hours=2) == ["dinner", "forgotten"]
    assert listed(hours=24, status="closed") == ["lunch"]
    assert listed(hours=24, status="open") == listed(status="open") == ["dinner", "forgotten"]
    assert listed(hours=0.5, status="void") == []
    assert client.get("/orders", params={"hours": 0}).status_code == 422


def test_a_day_s_checks_are_the_ones_opened_during_its_service(monkeypatch):
    """`day` lists what was opened between four that morning and four the next, the location's time, open or
    not: a check opened after midnight is found under the evening it belongs to."""
    monkeypatch.setenv("POS_TIMEZONE", "America/New_York")
    zone = ZoneInfo("America/New_York")

    def at(day: int, hour: int, minute: int = 0) -> int:
        return int(datetime(2026, 11, day, hour, minute, tzinfo=zone).timestamp() * 1000)

    client = TestClient(create_app(OpStore(physical=lambda: at(20, 12))))

    def order(order_id: str, opened: int, *more: str) -> None:
        hlc = [str(HLC(opened + i, 0, "t1")) for i in range(len(more) + 1)]
        ops = [{**payload(f"{order_id}-create", "create", 0, table=1), "hlc": hlc[0]}]
        ops += [{**payload(f"{order_id}-{kind}", kind, 0), "hlc": hlc[i + 1]} for i, kind in enumerate(more)]
        assert (
            client.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops]).status_code == 202
        )

    order("early-bird", at(14, 3, 30), "close")  # half past three: still the night of the 13th
    order("lunch", at(14, 12), "close")
    order("dinner", at(14, 19), "void_order")
    order("nightcap", at(15, 0, 30), "close")  # after midnight, the same evening
    order("still-open", at(14, 21))
    order("next-day", at(15, 11), "close")

    def listed(**params) -> list[str]:
        return sorted(o["order_id"] for o in client.get("/orders", params={"brief": True, **params}).json()["orders"])

    assert listed(day="2026-11-14") == ["dinner", "lunch", "nightcap", "still-open"]
    assert listed(day="2026-11-13") == ["early-bird"]
    assert listed(day="2026-11-15") == ["next-day"]
    assert listed(day="2026-11-14", status="closed") == ["lunch", "nightcap"]
    assert listed(day="2026-11-14", hours=1) == listed(day="2026-11-14")  # the day says it all
    assert listed(day="2026-11-01") == []
    assert client.get("/orders", params={"day": "yesterday"}).status_code == 422
    assert client.get("/orders", params={"day": "2026-02-30"}).status_code == 422
    rows = client.get("/orders", params={"day": "2026-11-14", "brief": True}).json()["orders"]
    assert {row["order_id"]: row["opened_ms"] for row in rows}["nightcap"] == at(15, 0, 30)


def test_a_list_can_leave_out_what_only_the_order_s_own_screen_reads():
    """`brief` drops each line's `request` and `priced` (most of an order's bytes); everything a list shows
    stays: the fields, each line's quantity and status, what was fired, what was paid."""
    menu = MenuService(load_definitions("restaurant"), now=lambda: datetime(2026, 10, 30, 19, 0, tzinfo=UTC))
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100), menu=menu))
    request = {
        "variant_id": "GTC:quart",
        "entry_id": "dinner:87",
        "selections": [
            {"group_id": "spice", "option_id": "spice:extra"},
            {"group_id": "rice", "option_id": "rice:brown"},
        ],
    }
    ops = [
        payload("a", "create", 0, table=4, guests=2),
        payload("b", "add_line", 1, line_id="L1", item="?", qty=2, request=request),
        payload("c", "fire", 2, course="*"),
    ]
    assert client.post("/orders/o1/ops", json=ops).json()["refused"] == []
    full = client.get("/orders", params={"status": "open"}).json()["orders"][0]
    brief = client.get("/orders", params={"status": "open", "brief": True}).json()["orders"][0]
    assert full["lines"]["L1"]["priced"]["unit_price"] and full["lines"]["L1"]["request"] == request
    assert full == client.get("/orders/o1").json()
    line = brief["lines"]["L1"]
    assert "priced" not in line and "request" not in line
    assert (line["item"], line["qty"], line["status"], line["fired"]) == (
        full["lines"]["L1"]["item"],
        2,
        "active",
        True,
    )
    assert brief.pop("opened_ms") == T0  # when it was opened: what a list of older checks is read by
    assert {k: v for k, v in brief.items() if k != "lines"} == {k: v for k, v in full.items() if k != "lines"}


def test_bad_ops_are_refused():
    client = TestClient(create_app(OpStore(physical=lambda: T0)))
    nameless = {**payload("n", "create", 0), "device": "", "hlc": str(HLC(T0, 0, ""))}
    assert client.post("/orders/o1/ops", json=[nameless]).json()["detail"]["error"] == "bad_stamp"
    other = {**payload("m", "create", 0), "device": "t2"}
    assert client.post("/orders/o1/ops", json=[other]).json()["detail"]["error"] == "bad_stamp"
    drift = client.post("/orders/o1/ops", json=[payload("z", "create", 10 * 60_000)])
    assert drift.status_code == 422 and drift.json()["detail"]["error"] == "clock_drift"
    assert client.post("/orders/o1/ops", json=[payload("y", "explode", 0)]).status_code == 422
    wrong_order = dict(payload("w", "create", 0), order_id="o2")
    assert client.post("/orders/o1/ops", json=[wrong_order]).status_code == 400
