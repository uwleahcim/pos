"""Shipday on the hub's own wire (`pos.api.shipday`, and the key in `pos.api.keys`): off until a manager
types the key, in force the moment it is typed, tried from the page of keys, each delivery told with the
check it is on the POS, and a delivery given to a driver or taken back when a person asks for exactly that."""

from __future__ import annotations

import asyncio
import itertools
import json
import logging

import httpx
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
        "can": ["driver"],
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
        "can": ["driver"],
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


# --- a delivery is given to a driver, and taken back -------------------------------------------------------


def waiting(h: Hub) -> None:
    """One delivery nobody has, Tom on shift and Wei off, and the hub has read both."""
    h.shipday.orders = [order(7001, "A-1")]
    h.shipday.carriers = [carrier(TOM), carrier(WEI, on_shift=False)]
    h.board.round()
    h.now += 5_000


def give(h: Hub, driver: int = TOM["id"], *, order_id: int = 7001, staff: str = "s1") -> dict:
    answer = h.c.post(f"/shipday/orders/{order_id}/driver", json={"staff_id": staff, "driver_id": driver})
    assert answer.status_code == 200, answer.text
    return answer.json()


def take_back(h: Hub, driver: int = TOM["id"], *, order_id: int = 7001, staff: str = "s1") -> dict:
    answer = h.c.post(f"/shipday/orders/{order_id}/driver/back", json={"staff_id": staff, "driver_id": driver})
    assert answer.status_code == 200, answer.text
    return answer.json()


def outcome(answer: dict) -> tuple:
    return (answer["done"], answer["sent"], answer["shown"], answer["reason"])


def test_a_delivery_is_given_to_a_driver_and_taken_back_with_the_list_read_before_and_after():
    h = Hub(key=True)
    waiting(h)
    assert h.shown()["can"] == ["driver"]
    h.shipday.now = h.now
    given = give(h)
    assert outcome(given) == (True, True, True, None) and (given["said"], given["told"]) == ("", "")
    assert h.shipday.calls[-3:] == ["GET /orders", "PUT /orders/assign/7001/501", "GET /orders"]
    put = next(sent for sent in h.shipday.sent if sent.method == "PUT")
    assert put.content == b"", "nothing of the POS goes with it"
    assert (put.headers["authorization"], put.headers["x-api-key"]) == (f"Basic {KEY}", KEY)
    now = given["shipday"]["orders"][0]
    assert (now["driver"], now["state"]) == ({"id": 501, "name": "Tom Reyes", "phone": "+17815550150"}, "NOT_ACCEPTED")
    assert now["assigned_ms"] == h.now
    assert [(d["name"], d["orders"]) for d in given["shipday"]["drivers"]] == [("Tom Reyes", 1), ("Wei Zhang", 0)]
    assert h.shown() == given["shipday"], "every screen reads what the one that asked was answered"
    # and back: nobody has it again
    back = take_back(h, staff="s3")
    assert outcome(back) == (True, True, True, None)
    assert h.shipday.changes() == ["PUT /orders/assign/7001/501", "PUT /orders/unassign/7001"]
    assert (back["shipday"]["orders"][0]["driver"], back["shipday"]["orders"][0]["state"]) == (None, "NOT_ASSIGNED")
    assert h.shipday.asked("/carriers") == 1, "the drivers are not asked for again for a change"


def test_a_hub_that_just_started_reads_the_drivers_before_it_says_who_can_be_given_one():
    h = Hub(key=True)
    h.shipday.orders = [order(7001, "A-1")]
    h.shipday.carriers = [carrier(TOM)]
    assert h.shipday.calls == [], "this hub has asked Shipday for nothing yet: the screen is from before it restarted"
    assert outcome(give(h)) == (True, True, True, None)
    assert h.shipday.calls == ["GET /orders", "GET /carriers", "PUT /orders/assign/7001/501", "GET /orders"]
    # and a driver Shipday does not list is still given nothing
    h.shipday.orders = [order(7002, "A-2")]
    assert outcome(give(h, 999, order_id=7002)) == (False, False, False, "unknown_driver")
    assert h.shipday.changes() == ["PUT /orders/assign/7001/501"]


def test_the_screens_are_told_when_a_delivery_was_given_to_a_driver():
    h = Hub(key=True)
    waiting(h)
    told: list[str] = []
    h.c.app.state.feed.changed = told.append
    give(h)
    assert told == ["shipday"]


def test_nothing_is_sent_for_a_delivery_that_no_longer_stands_as_the_screen_showed_it():
    h = Hub(key=True)
    waiting(h)
    h.shipday.carriers.append(carrier({"id": 503, "name": "Old Account", "phone": ""}, active=False))
    h.c.post("/shipday/ask")
    h.now += 20_000
    assert outcome(give(h, 999)) == (False, False, False, "unknown_driver")
    assert outcome(give(h, 503)) == (False, False, False, "unknown_driver"), "one Shipday does not let take orders"
    assert outcome(take_back(h)) == (False, False, False, "no_driver")
    # meanwhile somebody gave it to Wei in Shipday's own app: the hub has not heard, and asks before it sends
    h.shipday.orders = [order(7001, "A-1", state="NOT_ACCEPTED", driver=WEI)]
    assert outcome(give(h)) == (False, False, False, "has_driver")
    assert h.shown()["orders"][0]["driver"]["name"] == "Wei Zhang", "and the screens show who has it"
    assert outcome(take_back(h)) == (False, False, False, "other_driver"), "the screen said Tom had it"
    # Wei picked it up: what is on its way is not taken from the driver who carries it
    h.shipday.orders = [order(7001, "A-1", state="PICKED_UP", driver=WEI)]
    assert outcome(take_back(h, WEI["id"])) == (False, False, False, "on_its_way")
    # a word for where it stands that this hub does not know: nothing is guessed
    h.shipday.orders = [order(7001, "A-1", state="SOMETHING_NEW")]
    assert outcome(give(h)) == (False, False, False, "unsure")
    h.shipday.orders = [order(7001, "A-1", state="SOMETHING_NEW", driver=TOM)]
    assert outcome(take_back(h)) == (False, False, False, "unsure")
    # it left the list (delivered, or deleted there)
    h.shipday.orders = []
    assert outcome(give(h)) == (False, False, False, "not_listed")
    assert outcome(take_back(h)) == (False, False, False, "not_listed")
    assert outcome(give(h, order_id=4242)) == (False, False, False, "not_listed"), "an id Shipday never listed"
    assert h.shipday.changes() == [], "not one change was asked of Shipday"


def test_a_delivery_a_driver_accepted_or_started_can_still_be_taken_back():
    h = Hub(key=True)
    waiting(h)
    for state in ("NOT_ACCEPTED", "NOT_STARTED_YET", "STARTED"):
        h.shipday.orders = [order(7001, "A-1", state=state, driver=TOM)]
        assert outcome(take_back(h)) == (True, True, True, None), state
    assert h.shipday.changes() == ["PUT /orders/unassign/7001"] * 3


def test_what_shipday_will_not_do_is_said_with_its_own_words_which_no_log_keeps(caplog):
    h = Hub(key=True)
    waiting(h)
    h.shipday.refuses = (400, {"message": "Carrier is\noff shift. " + "x" * 300})
    with caplog.at_level(logging.DEBUG):
        refused = give(h)
    assert outcome(refused) == (False, True, False, "rejected")
    assert refused["said"] == "Shipday would not do it (400)"
    assert refused["told"].startswith("Carrier is off shift. xxx") and len(refused["told"]) == 160
    assert refused["shipday"]["orders"][0]["driver"] is None
    assert "order 7001 not given to driver 501 (rejected), asked by Amy" in caplog.text
    assert "off shift" not in caplog.text
    # an answer that says in itself that it was not done
    h.shipday.refuses = True
    said_no = give(h)
    assert outcome(said_no) == (False, True, False, "rejected")
    assert (said_no["said"], said_no["told"]) == ("Shipday would not do it", "Carrier is not available.")
    # an order or a driver Shipday knows nothing of
    h.shipday.refuses = (404, {})
    assert outcome(give(h)) == (False, True, False, "not_found")
    h.shipday.refuses = (500, {})
    assert outcome(give(h)) == (False, True, False, "error")


def test_when_shipday_cannot_be_asked_first_nothing_is_sent():
    h = Hub(key=True)
    waiting(h)
    h.shipday.fail = 401
    refused = give(h)
    assert outcome(refused) == (False, False, False, "refused") and refused["said"] == "Shipday refused the key"
    h.shipday.fail = httpx.ConnectError("no way out")
    assert outcome(give(h)) == (False, False, False, "unreachable")
    h.shipday.fail = 429
    assert outcome(take_back(h)) == (False, False, False, "limit")
    assert h.shipday.changes() == []
    assert h.shown()["trouble"]["reason"] == "limit", "and the screens say that Shipday is not answering"


def test_an_answer_that_never_came_is_settled_by_what_the_list_shows():
    h = Hub(key=True)
    waiting(h)
    # Shipday made the change and its answer was lost on the way back: the list read after it shows the driver
    h.shipday.lost = True
    assert outcome(give(h)) == (True, True, True, None)
    # it made none and the answer was lost: not done, and said so
    h.shipday.orders = [order(7001, "A-1")]
    h.shipday.deaf = True
    lost = give(h)
    assert outcome(lost) == (False, True, False, "slow") and lost["said"] == "Shipday did not answer in time"
    # it says it is done and its list does not show it (yet): done, as Shipday said, and not shown
    h.shipday.lost = False
    assert outcome(give(h)) == (True, True, False, None)


def test_who_asks_is_somebody_the_hub_knows_and_a_hub_without_the_key_changes_nothing():
    h = Hub(key=True)
    waiting(h)
    stranger = h.c.post("/shipday/orders/7001/driver", json={"staff_id": "nobody", "driver_id": 501})
    assert stranger.status_code == 404 and stranger.json()["detail"]["error"] == "unknown_staff"
    assert h.c.post("/shipday/orders/7001/driver", json={"staff_id": "s1"}).status_code == 422
    assert h.c.post("/shipday/orders/7001/driver", json={"driver_id": 501}).status_code == 422
    assert h.c.post("/shipday/orders/7001/driver/back", json={"staff_id": "s1", "driver_id": -1}).status_code == 422
    assert h.c.post("/shipday/orders/a-1/driver", json={"staff_id": "s1", "driver_id": 501}).status_code == 422
    assert h.shipday.changes() == []
    assert outcome(give(h, staff="s1")) == (True, True, True, None), "a server may, as anybody hands a bag out"
    bare = Hub()
    for path in ("/shipday/orders/7001/driver", "/shipday/orders/7001/driver/back"):
        answer = bare.c.post(path, json={"staff_id": "s1", "driver_id": 501})
        assert answer.status_code == 409 and answer.json()["detail"]["error"] == "no_key"
    assert bare.shipday.calls == []


def test_a_change_is_written_down_with_who_asked_and_nothing_of_the_customer(caplog):
    h = Hub(key=True)
    waiting(h)
    with caplog.at_level(logging.DEBUG):
        give(h)
        take_back(h, staff="s3")
    assert "shipday: order 7001 given to driver 501 by Amy" in caplog.text
    assert "shipday: order 7001 taken back from driver 501 by Mike" in caplog.text
    for word in (KEY, "Linda", "Elm St", "5550101", "Tom", "A-1"):
        assert word not in caplog.text


def test_a_change_looks_at_shipday_as_a_screen_does_and_does_not_wait_out_a_rest():
    h = Hub(key=True)
    waiting(h)
    h.shipday.fail = 429
    h.now += 60_000
    h.board.round()  # told it asks too often: the hub's own rounds rest for a minute
    h.shipday.fail = None
    h.now += 5_000
    assert h.board.round()["asked"] is False
    assert outcome(give(h)) == (True, True, True, None), "a person's change is not held back by the rest"
    assert h.board.pause() == 20.0, "and the hub asks often for a while after it"
