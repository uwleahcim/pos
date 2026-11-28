"""Shipday on the hub's own wire (`pos.api.shipday`, and the key in `pos.api.keys`): off until a manager
types the key, in force the moment it is typed, tried from the page of keys, and each delivery told with
the check it is on the POS."""

from __future__ import annotations

import asyncio
import itertools
import json
import logging

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.api.keys import use_keys
from pos.identity.staff import Directory, Staff
from pos.keys import SHIPDAY, HubKeys, KeyStore, vault_from_env
from pos.online.service import OnlineOrders
from pos.settings import SettingStore
from pos.shipday.board import ShipdayBoard
from pos.sync.hlc import HLC
from pos.sync.oplog import Op, OpStore

from .fake import ELM, KEY, OAK, TOM, WEI, FakeShipday, at, carrier, order

_ids = itertools.count(1)


class Hub:
    """A hub with a manager and a server, a clock moved by hand, and a Shipday that is nobody's."""

    def __init__(self, *, key: bool = False) -> None:
        self.now = at(18)
        self.shipday = FakeShipday()
        self.store = OpStore(physical=lambda: self.now)
        vault = vault_from_env({"POS_SECRET": "the-location-s-own-secret", "POS_KEYS_FILE": "/nowhere/at/all"})
        self.keys = HubKeys(KeyStore(), vault, environ={}, now=lambda: self.now)
        if key:
            self.keys.set(SHIPDAY, {"key": KEY}, by="Mike")
        self.board = ShipdayBoard(self.shipday.source() if key else None, now=lambda: self.now)
        staff = Directory(
            [Staff.with_pin("s1", "Amy", "server", "1111"), Staff.with_pin("s3", "Mike", "manager", "9999")]
        )
        app = create_app(
            self.store,
            staff=staff,
            settings=SettingStore(),
            keys=self.keys,
            online=OnlineOrders(None),
            shipday=self.board,
        )
        # a key typed in the app is asked with through the same stand-in for the internet
        app.state.shipday_made_with = {"client": self.shipday.source()._client}  # noqa: SLF001
        self.c = TestClient(app)
        self._manager: dict[str, str] | None = None

    def manager(self) -> dict[str, str]:
        if self._manager is None:
            token = self.c.post("/admin/session", json={"device": "office", "pin": "9999"}).json()["token"]
            self._manager = {"authorization": f"Bearer {token}"}
        return self._manager

    def op(self, order_id: str, op_kind: str, /, **data) -> None:
        body = {
            "op_id": f"{order_id}-{op_kind}-{next(_ids)}",
            "order_id": order_id,
            "hlc": str(HLC(self.now, next(_ids), "t1")),
            "device": "t1",
            "kind": op_kind,
            "data": data,
        }
        answer = self.c.post(f"/orders/{order_id}/ops", json=[body])
        assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text

    def delivery(self, order_id: str, name: str, phone: str, address: str) -> int:
        """A delivery rung up at the POS, and the number the hub gave it."""
        self.op(
            order_id,
            "create",
            order_type="takeout",
            channel="phone",
            customer_name=name,
            phone=phone,
            handover="delivery",
            address=address,
        )
        return self.c.get(f"/orders/{order_id}").json()["fields"]["order_no"]

    def from_the_website(self, ext_id: str, name: str, phone: str) -> None:
        """A delivery GloriaFood handed over: only the hub itself writes where an order came from."""
        fields = {
            "order_type": "takeout",
            "channel": "online",
            "customer_name": name,
            "phone": phone,
            "handover": "delivery",
            "address": ELM,
            "order_no": 41,
            "stage": "new",
            "online": {"source": "gloriafood", "id": ext_id, "type": "delivery"},
        }
        self.store.append(
            [Op(f"gf-{ext_id}:create", f"gf-{ext_id}", HLC(self.now, 0, "online"), "online", "create", fields)]
        )

    def shown(self) -> dict:
        answer = self.c.get("/shipday")
        assert answer.status_code == 200, answer.text
        return answer.json()


def test_a_hub_without_the_key_reads_nothing_and_says_it_is_off():
    h = Hub()
    assert h.shown() == {
        "on": False,
        "read": False,
        "trouble": None,
        "eta": "off",
        "orders": [],
        "done": [],
        "drivers": [],
    }
    refused = h.c.post("/shipday/ask")
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_key"
    assert h.c.post("/hub/shipday/try", headers=h.manager()).status_code == 409
    about = h.c.get("/hub/keys", headers=h.manager()).json()["shipday"]
    assert (about["on"], about["running"], about["asked_ms"], about["orders"]) == (False, False, None, 0)
    assert h.shipday.calls == [], "nothing is asked of anybody"


def test_a_manager_types_the_key_and_the_hub_reads_shipday_with_it_at_once():
    h = Hub()
    h.shipday.orders = [order(1, "A-1"), order(2, "A-2", state="PICKED_UP", driver=TOM, phone="+17815550102")]
    h.shipday.carriers = [carrier(TOM), carrier(WEI, on_shift=False)]
    saved = h.c.put("/hub/keys/shipday", json={"key": f"  {KEY}\n"}, headers=h.manager())
    assert saved.status_code == 200 and KEY not in saved.text
    slot = next(key for key in saved.json()["keys"] if key["name"] == "shipday")
    assert (slot["set"], slot["source"], slot["ending"], slot["by"]) == (True, "app", KEY[-4:], "Mike")
    assert h.shown()["on"] is True and h.shown()["read"] is False, "no restart, and nothing asked behind a test's back"
    tried = h.c.post("/hub/shipday/try", headers=h.manager())
    assert tried.status_code == 200 and KEY not in tried.text
    assert tried.json()["shipday_tried"] == {
        "ok": True,
        "reason": None,
        "said": "",
        "orders": 2,
        "drivers": 2,
        "on_shift": 1,
    }
    about = tried.json()["shipday"]
    assert (about["on"], about["asked_ms"], about["answered_ms"], about["trouble"]) == (True, h.now, h.now, None)
    assert h.shipday.sent[0].headers["authorization"] == f"Basic {KEY}"
    assert [o["number"] for o in h.shown()["orders"]] == ["A-1", "A-2"]
    assert KEY not in json.dumps(h.shown())
    # removed: nothing is asked any more, and what the key brought is gone from every screen
    gone = h.c.delete("/hub/keys/shipday", headers=h.manager()).json()
    assert next(key for key in gone["keys"] if key["name"] == "shipday")["removed"] is True
    assert h.shown() == {
        "on": False,
        "read": False,
        "trouble": None,
        "eta": "off",
        "orders": [],
        "done": [],
        "drivers": [],
    }


def test_a_key_shipday_refuses_is_said_so_by_the_try():
    h = Hub()
    h.c.put("/hub/keys/shipday", json={"key": KEY}, headers=h.manager())
    h.shipday.fail = 401
    tried = h.c.post("/hub/shipday/try", headers=h.manager()).json()
    assert tried["shipday_tried"] == {
        "ok": False,
        "reason": "refused",
        "said": "Shipday refused the key",
        "orders": None,
        "drivers": None,
        "on_shift": None,
    }
    assert tried["shipday"]["trouble"]["reason"] == "refused"
    assert h.shown()["trouble"]["said"] == "Shipday refused the key"


def test_what_is_wrong_with_a_typed_key_is_said_without_the_key():
    h = Hub()
    for typed in ("", "short", "has spaces in it, which no key has", "x" * 300):
        refused = h.c.put("/hub/keys/shipday", json={"key": typed}, headers=h.manager())
        assert refused.status_code == 422 and refused.json()["detail"]["error"] == "bad_value"
        assert not typed or typed not in refused.text
    assert h.shown()["on"] is False


def test_the_key_and_its_try_are_a_manager_s_and_the_deliveries_any_terminal_s():
    h = Hub(key=True)
    assert h.c.put("/hub/keys/shipday", json={"key": KEY}).status_code == 401
    assert h.c.delete("/hub/keys/shipday").status_code == 401
    assert h.c.post("/hub/shipday/try").status_code == 401
    session = h.c.post("/admin/session", json={"device": "t1", "pin": "1111", "power": "take_tables"}).json()
    server = {"authorization": f"Bearer {session['token']}"}
    assert h.c.put("/hub/keys/shipday", json={"key": KEY}, headers=server).status_code == 403
    assert h.c.post("/hub/shipday/try", headers=server).status_code == 403
    assert h.c.get("/shipday").status_code == 200, "like the list of orders"
    assert h.c.post("/shipday/ask").status_code == 200


def test_each_delivery_says_the_check_it_is_on_the_pos():
    h = Hub(key=True)
    number = h.delivery("o-7", "Raj Patel", "781 555 0102", OAK)
    h.from_the_website("1270166229", "Linda Chen", "+1 781 555 0101")
    h.op("o-8", "create", order_type="takeout", customer_name="Sam", phone="781 555 0103")  # comes to the counter
    h.shipday.orders = [
        order(1, "1270166229", phone="+16175550000"),  # the number alone tells
        order(2, "S-77", name="Raj P.", address="4 Oak Road", phone="+17815550102", state="STARTED", driver=TOM),
        order(3, "S-78", name="Sam", phone="+17815550103"),  # a pickup on the POS is no delivery
        order(4, "S-79", name="Zoe", phone="+17815550104"),  # taken in Shipday by hand
    ]
    asked = h.c.post("/shipday/ask").json()
    assert (asked["asked"], asked["answered"], asked["soon"]) == (True, True, False)
    assert [o["pos"] for o in asked["shipday"]["orders"]] == [
        {"order_id": "gf-1270166229", "order_no": 41, "status": "open", "stage": "new", "by": "number"},
        {"order_id": "o-7", "order_no": number, "status": "open", "stage": "new", "by": "phone"},
        None,
        None,
    ]
    assert h.c.post("/shipday/ask").json()["soon"] is True, "not passed on twice in ten seconds"
    # the check is voided on the POS while the delivery is still out in Shipday: a screen can say so
    h.op("o-7", "void_order", by="Mike", by_id="s3", reason="rung twice")
    assert h.shown()["orders"][1]["pos"]["status"] == "void"
    # and a check rung up now is matched without Shipday being asked again
    h.delivery("o-9", "Zoe Lin", "(781) 555-0104", ELM)
    assert h.shown()["orders"][3]["pos"]["order_id"] == "o-9"
    assert h.shipday.asked("/orders") == 1


def test_an_answer_that_has_not_changed_is_the_one_a_screen_already_has():
    h = Hub(key=True)
    h.shipday.orders = [order(1, "A-1", state="PICKED_UP", driver=TOM)]
    h.board.round()
    first = h.c.get("/shipday")
    h.now += 20_000
    h.board.round()
    again = h.c.get("/shipday", headers={"if-none-match": first.headers["etag"]})
    assert again.status_code == 304, "nothing in it moves with the clock"
    h.shipday.orders = []
    h.shipday.finished["A-1"] = order(1, "A-1", state="ALREADY_DELIVERED", driver=TOM, delivered=h.now)
    h.now += 20_000
    h.board.round()
    assert h.c.get("/shipday", headers={"if-none-match": first.headers["etag"]}).status_code == 200


def test_a_terminal_that_reads_the_picture_keeps_the_hub_asking_and_a_screen_that_shows_it_hurries_it():
    h = Hub(key=True)
    assert h.board.pause() == 300.0, "nobody has asked this hub about Shipday: it asks every five minutes"
    assert h.c.get("/shipday").status_code == 200  # the home screen, for the words on its button
    assert h.board.pause() == 60.0
    h.c.get("/shipday", params={"looking": "true"})  # the Shipday screen
    assert h.board.pause() == 20.0
    h.now += 2 * 60_000
    assert h.board.pause() == 60.0
    h.now += 8 * 60_000
    assert h.board.pause() == 300.0, "ten minutes with no terminal asking"


def test_the_screens_are_told_on_the_change_feed_when_the_picture_or_the_key_changes():
    h = Hub()
    told: list[str] = []
    h.c.app.state.feed.changed = told.append  # what a screen's stream would be sent
    h.c.put("/hub/keys/shipday", json={"key": KEY}, headers=h.manager())
    assert told == ["shipday"], "the key is in force: the home screen shows the button"
    h.shipday.orders = [order(1, "A-1")]
    h.board.round()
    h.now += 20_000
    h.board.round()
    assert told == ["shipday", "shipday"], "once for the order, and not again for the same answer"
    h.c.get("/shipday", params={"looking": "true"})
    assert h.board.pause() == 20.0
    h.c.delete("/hub/keys/shipday", headers=h.manager())
    assert told[-1] == "shipday" and len(told) == 3


def test_a_key_typed_on_the_other_hub_is_asked_with_once_this_hub_notices():
    h = Hub()
    other_hub = HubKeys(h.keys.store, h.keys.vault, environ={}, now=lambda: h.now + 60_000)
    other_hub.set(SHIPDAY, {"key": KEY}, by="Mike")
    assert h.board.configured is False
    asyncio.run(use_keys(h.c.app))  # what the minute's look does when the keys changed under the hub
    assert h.board.configured is True
    other_hub.remove(SHIPDAY, by="Mike")
    asyncio.run(use_keys(h.c.app))
    assert h.board.configured is False


def test_nothing_of_the_key_or_a_customer_is_written_to_the_log(caplog):
    h = Hub()
    h.shipday.orders = [order(1, "A-1", state="PICKED_UP", driver=TOM)]
    with caplog.at_level(logging.DEBUG):
        h.c.put("/hub/keys/shipday", json={"key": KEY}, headers=h.manager())
        h.c.post("/hub/shipday/try", headers=h.manager())
        h.shipday.fail = 401
        h.now += 60_000
        h.c.post("/shipday/ask")
        h.c.delete("/hub/keys/shipday", headers=h.manager())
    assert "shipday" in caplog.text
    for word in (KEY, KEY[-8:], "Linda", "Elm St", "5550101"):
        assert word not in caplog.text
