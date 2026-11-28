"""Shipday on the hub's own wire (`pos.api.shipday`, and the key in `pos.api.keys`): off until a manager
types the key, in force the moment it is typed, tried from the page of keys, each delivery told with the
check it is on the POS, a delivery given to a driver, taken back, marked or said ready for pickup when a
person asks for exactly that, a check moved by what Shipday says of its delivery, and Shipday told by the
hub itself that a delivery is ready for pickup when its check is marked Ready."""

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
        "can": ["driver", "status", "ready"],
        "orders": [],
        "done": [],
        "drivers": [],
        "moves_checks": True,
        "tells_ready": True,
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
        "can": ["driver", "status", "ready"],
        "orders": [],
        "done": [],
        "drivers": [],
        "moves_checks": True,
        "tells_ready": True,
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
    assert h.shown()["can"] == ["driver", "status", "ready"]
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


# --- a delivery is marked as it goes --------------------------------------------------------------------------


def held(h: Hub, state: str = "NOT_STARTED_YET") -> None:
    """One delivery Tom has (accepted, unless said otherwise), and the hub has read it."""
    h.shipday.orders = [order(7001, "A-1", state=state, driver=TOM, assigned=at(18, 5))]
    h.shipday.carriers = [carrier(TOM), carrier(WEI, on_shift=False)]
    h.board.round()
    h.now += 5_000


def mark(h: Hub, status: str, was: str, *, order_id: int = 7001, staff: str = "s1") -> dict:
    answer = h.c.post(f"/shipday/orders/{order_id}/status", json={"staff_id": staff, "status": status, "was": was})
    assert answer.status_code == 200, answer.text
    return answer.json()


ENDS = ["ALREADY_DELIVERED", "FAILED_DELIVERY", "INCOMPLETE"]


def test_the_picture_says_of_each_delivery_what_it_can_be_marked_as_from_where_it_stands():
    h = Hub(key=True)
    h.shipday.orders = [
        order(1, "A-1"),
        order(2, "A-2", state="NOT_ACCEPTED", driver=TOM),
        order(3, "A-3", state="NOT_STARTED_YET", driver=TOM),
        order(4, "A-4", state="STARTED", driver=TOM),
        order(5, "A-5", state="PICKED_UP", driver=TOM),
        order(6, "A-6", state="READY_TO_DELIVER", driver=TOM),
        order(7, "A-7", state="SOMETHING_NEW", driver=TOM),
        order(8, "A-8", state="PICKED_UP"),  # on its way, and nobody has it: nothing is guessed
        order(9, "A-9", state="NOT_ASSIGNED", driver=TOM),  # a driver, and "not assigned": the same
    ]
    h.board.round()
    assert {each["number"]: each["steps"] for each in h.shown()["orders"]} == {
        "A-1": ["FAILED_DELIVERY", "INCOMPLETE"],  # nobody has it: it can only be ended as not delivered
        "A-2": ["STARTED", "PICKED_UP", *ENDS],
        "A-3": ["STARTED", "PICKED_UP", *ENDS],
        "A-4": ["PICKED_UP", *ENDS],
        "A-5": ["READY_TO_DELIVER", *ENDS],
        "A-6": ENDS,
        "A-7": [],
        "A-8": [],
        "A-9": [],
    }


def test_a_delivery_is_marked_as_it_goes_with_the_list_read_before_and_after():
    h = Hub(key=True)
    held(h)
    h.shipday.now = h.now
    marked = mark(h, "PICKED_UP", "NOT_STARTED_YET")
    assert outcome(marked) == (True, True, True, None) and (marked["said"], marked["told"]) == ("", "")
    assert h.shipday.calls[-3:] == ["GET /orders", "PUT /orders/7001/status", "GET /orders"]
    put = next(sent for sent in h.shipday.sent if sent.method == "PUT")
    assert json.loads(put.content) == {"status": "PICKED_UP"}, "one word of Shipday's own, and nothing of the POS"
    assert put.headers["content-type"] == "application/json"
    assert (put.headers["authorization"], put.headers["x-api-key"]) == (f"Basic {KEY}", KEY)
    now = marked["shipday"]["orders"][0]
    assert (now["state"], now["picked_up_ms"], now["driver"]["name"]) == ("PICKED_UP", h.now, "Tom Reyes")
    assert now["steps"] == ["READY_TO_DELIVER", *ENDS], "and what it can be marked as next"
    assert h.shown() == marked["shipday"], "every screen reads what the one that asked was answered"
    # a step further, by somebody else
    assert outcome(mark(h, "READY_TO_DELIVER", "PICKED_UP", staff="s3")) == (True, True, True, None)
    assert h.shown()["orders"][0]["state"] == "READY_TO_DELIVER"
    assert h.shipday.changes() == ["PUT /orders/7001/status"] * 2
    assert h.shipday.asked("/carriers") == 1, "the drivers are not asked for again for a mark"


def test_a_delivery_marked_delivered_failed_or_incomplete_leaves_the_list_and_is_among_the_finished():
    for status in ENDS:
        h = Hub(key=True)
        held(h, "PICKED_UP")
        h.shipday.now = h.now
        ended = mark(h, status, "PICKED_UP")
        assert outcome(ended) == (True, True, True, None), status
        assert h.shipday.calls[-4:] == ["GET /orders", "PUT /orders/7001/status", "GET /orders", "GET /orders/A-1"]
        assert ended["shipday"]["orders"] == []
        done = ended["shipday"]["done"][0]
        assert (done["id"], done["state"], done["steps"]) == (7001, status, []), "nothing more can be said of it"
        assert [d["orders"] for d in ended["shipday"]["drivers"]] == [0, 0], "and Tom has nothing out"
    # one nobody has can be ended as not delivered, and as nothing else
    h = Hub(key=True)
    waiting(h)
    assert outcome(mark(h, "ALREADY_DELIVERED", "NOT_ASSIGNED")) == (False, False, False, "not_a_step")
    assert outcome(mark(h, "INCOMPLETE", "NOT_ASSIGNED")) == (True, True, True, None)
    assert h.shipday.changes() == ["PUT /orders/7001/status"]


def test_the_screens_are_told_when_a_delivery_was_marked():
    h = Hub(key=True)
    held(h)
    told: list[str] = []
    h.c.app.state.feed.changed = told.append
    mark(h, "STARTED", "NOT_STARTED_YET")
    assert told == ["shipday"]


def test_nothing_is_marked_that_no_longer_stands_as_the_screen_showed_it():
    h = Hub(key=True)
    held(h, "STARTED")
    # meanwhile the driver's app said picked up: the hub has not heard, and asks before it sends
    h.shipday.orders = [order(7001, "A-1", state="PICKED_UP", driver=TOM)]
    assert outcome(mark(h, "PICKED_UP", "STARTED")) == (False, False, False, "moved")
    assert h.shown()["orders"][0]["state"] == "PICKED_UP", "and the screens show where it stands"
    # never backwards, never a step it is at, never one that skips what comes first
    assert outcome(mark(h, "STARTED", "PICKED_UP")) == (False, False, False, "not_a_step")
    assert outcome(mark(h, "PICKED_UP", "PICKED_UP")) == (False, False, False, "not_a_step")
    h.shipday.orders = [order(7001, "A-1", state="STARTED", driver=TOM)]
    assert outcome(mark(h, "READY_TO_DELIVER", "STARTED")) == (False, False, False, "not_a_step")
    # somebody took it back: what a driver does is not said of a delivery nobody has
    h.shipday.orders = [order(7001, "A-1")]
    assert outcome(mark(h, "PICKED_UP", "STARTED")) == (False, False, False, "moved")
    assert outcome(mark(h, "PICKED_UP", "NOT_ASSIGNED")) == (False, False, False, "not_a_step")
    # a word for where it stands that this hub does not know: nothing is guessed
    h.shipday.orders = [order(7001, "A-1", state="SOMETHING_NEW", driver=TOM)]
    assert outcome(mark(h, "ALREADY_DELIVERED", "UNKNOWN")) == (False, False, False, "not_a_step")
    # it left the list (the driver delivered it, or it was deleted there)
    h.shipday.orders = []
    assert outcome(mark(h, "ALREADY_DELIVERED", "PICKED_UP")) == (False, False, False, "not_listed")
    assert outcome(mark(h, "INCOMPLETE", "STARTED", order_id=4242)) == (False, False, False, "not_listed")
    assert h.shipday.changes() == [], "not one change was asked of Shipday"


def test_a_mark_shipday_will_not_make_or_never_answers_is_said_as_it_is():
    h = Hub(key=True)
    held(h)
    h.shipday.refuses = (400, {})
    refused = mark(h, "PICKED_UP", "NOT_STARTED_YET")
    assert outcome(refused) == (False, True, False, "rejected")
    assert (refused["said"], refused["told"]) == ("Shipday would not do it (400)", "")
    assert refused["shipday"]["orders"][0]["state"] == "NOT_STARTED_YET"
    # it made the mark and its answer was lost on the way back: the list read after it settles it
    h.shipday.refuses, h.shipday.lost = False, True
    assert outcome(mark(h, "PICKED_UP", "NOT_STARTED_YET")) == (True, True, True, None)
    assert outcome(mark(h, "ALREADY_DELIVERED", "PICKED_UP")) == (True, True, True, None), "gone from the list"
    # it says the mark is made and its list does not show it (yet): done, as Shipday said, and not shown
    h = Hub(key=True)
    held(h)
    h.shipday.deaf = True
    assert outcome(mark(h, "ALREADY_DELIVERED", "NOT_STARTED_YET")) == (True, True, False, None)
    # it made none and never answered: not done, and said so
    h.shipday.lost = True
    lost = mark(h, "PICKED_UP", "NOT_STARTED_YET")
    assert outcome(lost) == (False, True, False, "slow") and lost["said"] == "Shipday did not answer in time"
    # and where it cannot be asked first, nothing is sent
    h = Hub(key=True)
    held(h)
    h.shipday.fail = 401
    assert outcome(mark(h, "PICKED_UP", "NOT_STARTED_YET")) == (False, False, False, "refused")
    assert h.shipday.changes() == []


def test_who_marks_is_somebody_the_hub_knows_and_the_mark_one_of_shipday_s_words(caplog):
    h = Hub(key=True)
    held(h)
    path = "/shipday/orders/7001/status"
    stranger = h.c.post(path, json={"staff_id": "nobody", "status": "PICKED_UP", "was": "NOT_STARTED_YET"})
    assert stranger.status_code == 404 and stranger.json()["detail"]["error"] == "unknown_staff"
    for body in (
        {"staff_id": "s1", "status": "PICKED_UP"},
        {"staff_id": "s1", "was": "NOT_STARTED_YET"},
        {"status": "PICKED_UP", "was": "NOT_STARTED_YET"},
        {"staff_id": "s1", "status": "NOT_ASSIGNED", "was": "NOT_STARTED_YET"},  # not a thing to mark it as
        {"staff_id": "s1", "status": "DELETED", "was": "NOT_STARTED_YET"},
        {"staff_id": "s1", "status": "picked_up", "was": "NOT_STARTED_YET"},
    ):
        assert h.c.post(path, json=body).status_code == 422, body
    assert h.shipday.changes() == []
    with caplog.at_level(logging.DEBUG):
        assert outcome(mark(h, "PICKED_UP", "NOT_STARTED_YET")) == (True, True, True, None), "a server may"
        h.shipday.refuses = (400, {"message": "Order is locked"})
        assert outcome(mark(h, "READY_TO_DELIVER", "PICKED_UP", staff="s3"))[3] == "rejected"
    assert "shipday: order 7001 marked PICKED_UP by Amy" in caplog.text
    assert "shipday: order 7001 not marked READY_TO_DELIVER (rejected), asked by Mike" in caplog.text
    assert "locked" not in caplog.text, "what Shipday said is for the person who asked, and for no log"
    for word in (KEY, "Linda", "Elm St", "5550101", "Tom", "A-1"):
        assert word not in caplog.text
    bare = Hub()
    answer = bare.c.post(path, json={"staff_id": "s1", "status": "PICKED_UP", "was": "NOT_STARTED_YET"})
    assert answer.status_code == 409 and answer.json()["detail"]["error"] == "no_key"
    assert bare.shipday.calls == []


# --- a delivery is said to be ready for pickup ----------------------------------------------------------------


def ready(h: Hub, *, order_id: int = 7001, staff: str = "s1") -> dict:
    answer = h.c.post(f"/shipday/orders/{order_id}/ready", json={"staff_id": staff})
    assert answer.status_code == 200, answer.text
    return answer.json()


def test_a_delivery_is_said_ready_for_pickup_and_the_hub_remembers_that_it_told():
    h = Hub(key=True)
    held(h)
    before = h.shown()["orders"][0]
    assert (before["can_ready"], before["ready_ms"]) == (True, None)
    as_listed = json.dumps(h.shipday.orders)
    said = ready(h)
    # Shipday's list has no place for it: done is Shipday's own answer, and shown is never true
    assert outcome(said) == (True, True, False, None) and (said["said"], said["told"]) == ("", "")
    assert h.shipday.calls[-3:] == ["GET /orders", "PUT /orders/7001/meta", "GET /orders"]
    put = next(sent for sent in h.shipday.sent if sent.method == "PUT")
    assert json.loads(put.content) == {"readyToPickup": True}, "one word of Shipday's own, and nothing of the POS"
    assert put.headers["content-type"] == "application/json"
    assert (put.headers["authorization"], put.headers["x-api-key"]) == (f"Basic {KEY}", KEY)
    assert h.shipday.ready == {7001: True}
    assert json.dumps(h.shipday.orders) == as_listed, "nothing Shipday lists of the order says so afterwards"
    now = said["shipday"]["orders"][0]
    assert (now["ready_ms"], now["can_ready"]) == (h.now, False), "so the hub says that it told, and when"
    assert (now["state"], now["steps"]) == (before["state"], before["steps"]), "and it stands where it stood"
    assert h.shown() == said["shipday"], "every screen reads what the one that asked was answered"
    assert h.shipday.asked("/carriers") == 1, "the drivers are not asked for again for it"
    # one nobody has yet is said ready as well: the food can be made before a driver is found
    h = Hub(key=True)
    waiting(h)
    assert outcome(ready(h, staff="s3")) == (True, True, False, None)
    assert h.shown()["orders"][0]["ready_ms"] == h.now
    # and where Shipday answers 202 with nothing, as its page also lists
    h = Hub(key=True)
    held(h, "STARTED")
    h.shipday.ready_answers = 202
    assert outcome(ready(h)) == (True, True, False, None)
    assert h.shown()["orders"][0]["ready_ms"] == h.now


def test_the_picture_says_which_deliveries_can_be_said_ready_for_pickup():
    h = Hub(key=True)
    h.shipday.orders = [
        order(1, "A-1"),
        order(2, "A-2", state="NOT_ACCEPTED", driver=TOM),
        order(3, "A-3", state="NOT_STARTED_YET", driver=TOM),
        order(4, "A-4", state="STARTED", driver=TOM),
        order(5, "A-5", state="PICKED_UP", driver=TOM),
        order(6, "A-6", state="READY_TO_DELIVER", driver=TOM),
        order(7, "A-7", state="SOMETHING_NEW", driver=TOM),
    ]
    h.board.round()
    assert {each["number"]: each["can_ready"] for each in h.shown()["orders"]} == {
        "A-1": True,  # nobody has it yet
        "A-2": True,
        "A-3": True,
        "A-4": True,
        "A-5": False,  # it left already
        "A-6": False,
        "A-7": False,  # a word this hub does not know: nothing is guessed
    }
    assert all(each["ready_ms"] is None for each in h.shown()["orders"])
    # one that finished cannot be, and still says when it was
    h = Hub(key=True)
    held(h)
    told_at = h.now
    ready(h)
    h.now += 60_000
    h.shipday.now = h.now
    mark(h, "ALREADY_DELIVERED", "NOT_STARTED_YET")
    done = h.shown()["done"][0]
    assert (done["id"], done["can_ready"], done["ready_ms"]) == (7001, False, told_at)


def test_nothing_is_said_ready_that_was_picked_up_or_left_the_list():
    h = Hub(key=True)
    held(h, "STARTED")
    # meanwhile the driver's app said picked up: the hub has not heard, and asks before it sends
    h.shipday.orders = [order(7001, "A-1", state="PICKED_UP", driver=TOM)]
    assert outcome(ready(h)) == (False, False, False, "on_its_way")
    assert h.shown()["orders"][0]["state"] == "PICKED_UP", "and the screens show where it stands"
    h.shipday.orders = [order(7001, "A-1", state="READY_TO_DELIVER", driver=TOM)]
    assert outcome(ready(h)) == (False, False, False, "on_its_way")
    # a word for where it stands that this hub does not know: nothing is guessed
    h.shipday.orders = [order(7001, "A-1", state="SOMETHING_NEW", driver=TOM)]
    assert outcome(ready(h)) == (False, False, False, "unsure")
    # it left the list (delivered, or deleted there), or was never on it
    h.shipday.orders = []
    assert outcome(ready(h)) == (False, False, False, "not_listed")
    assert outcome(ready(h, order_id=4242)) == (False, False, False, "not_listed")
    assert h.shipday.changes() == [] and h.shipday.ready == {}, "not one change was asked of Shipday"
    assert h.shown()["done"][0]["ready_ms"] is None


def test_ready_for_pickup_shipday_will_not_take_or_never_answers_is_said_as_it_is_and_not_remembered():
    h = Hub(key=True)
    held(h)
    h.shipday.refuses = (400, {"message": "Order is locked"})
    refused = ready(h)
    assert outcome(refused) == (False, True, False, "rejected")
    assert (refused["said"], refused["told"]) == ("Shipday would not do it (400)", "Order is locked")
    now = refused["shipday"]["orders"][0]
    assert (now["ready_ms"], now["can_ready"]) == (None, True), "it can be tried again"
    # the answer was lost on the way back: Shipday may have taken it, and its list cannot say. Not done,
    # not remembered, and said so
    h.shipday.refuses, h.shipday.lost = False, True
    lost = ready(h)
    assert outcome(lost) == (False, True, False, "slow") and lost["said"] == "Shipday did not answer in time"
    assert h.shipday.ready == {7001: True}, "Shipday did take it, as it happens"
    assert h.shown()["orders"][0]["ready_ms"] is None
    # telling it again does no harm, and is remembered once Shipday answers
    h.shipday.lost = False
    assert outcome(ready(h)) == (True, True, False, None)
    assert h.shown()["orders"][0]["ready_ms"] == h.now
    first = h.now
    h.now += 30_000
    assert outcome(ready(h)) == (True, True, False, None), "the hub itself does not refuse a second telling"
    assert h.shown()["orders"][0]["ready_ms"] == first + 30_000
    assert h.shipday.changes() == ["PUT /orders/7001/meta"] * 4
    # and where it cannot be asked first, nothing is sent
    h = Hub(key=True)
    held(h)
    h.shipday.fail = 401
    assert outcome(ready(h)) == (False, False, False, "refused")
    h.shipday.fail = httpx.ConnectError("no way out")
    assert outcome(ready(h)) == (False, False, False, "unreachable")
    assert h.shipday.changes() == []


def test_what_was_said_ready_is_kept_for_the_day_and_forgotten_with_another_key():
    h = Hub(key=True)
    held(h)
    ready(h)
    told_at = h.now
    h.now += 3 * 60 * 60_000
    h.board.round()
    assert h.shown()["orders"][0]["ready_ms"] == told_at, "still told, hours later the same evening"
    h.now += 24 * 60 * 60_000
    h.board.round()
    tomorrow = h.shown()["orders"][0]
    assert (tomorrow["ready_ms"], tomorrow["can_ready"]) == (None, True), "another day of service"
    ready(h)
    h.board.use(h.shipday.source("AnotherKey0.SomebodyElsesAccount99"))
    h.board.round()
    assert h.shown()["orders"][0]["ready_ms"] is None, "another account's orders are not this one's"


def test_the_screens_are_told_when_a_delivery_was_said_ready():
    h = Hub(key=True)
    held(h)
    told: list[str] = []
    h.c.app.state.feed.changed = told.append
    ready(h)
    assert told == ["shipday"], "Shipday's list reads as before: what the hub told is part of the picture"


def test_who_says_ready_is_somebody_the_hub_knows_and_it_is_written_down_without_the_customer(caplog):
    h = Hub(key=True)
    held(h)
    path = "/shipday/orders/7001/ready"
    stranger = h.c.post(path, json={"staff_id": "nobody"})
    assert stranger.status_code == 404 and stranger.json()["detail"]["error"] == "unknown_staff"
    assert h.c.post(path, json={}).status_code == 422
    assert h.c.post("/shipday/orders/a-1/ready", json={"staff_id": "s1"}).status_code == 422
    assert h.shipday.changes() == []
    with caplog.at_level(logging.DEBUG):
        assert outcome(ready(h)) == (True, True, False, None), "a server may, as anybody bags an order"
        h.shipday.refuses = (400, {"message": "Order is locked"})
        assert outcome(ready(h, staff="s3"))[3] == "rejected"
    assert "shipday: order 7001 said ready for pickup by Amy" in caplog.text
    assert "shipday: order 7001 not said ready for pickup (rejected), asked by Mike" in caplog.text
    assert "locked" not in caplog.text, "what Shipday said is for the person who asked, and for no log"
    for word in (KEY, "Linda", "Elm St", "5550101", "Tom", "A-1"):
        assert word not in caplog.text
    bare = Hub()
    answer = bare.c.post(path, json={"staff_id": "s1"})
    assert answer.status_code == 409 and answer.json()["detail"]["error"] == "no_key"
    assert bare.shipday.calls == []


# --- Shipday moves the check ----------------------------------------------------------------------------------

TEA = {"unit_price": "10.00", "tax_class": "prepared_food", "name": "Tea"}


def cooking(h: Hub, order_id: str = "o-7", *, paid: bool = False) -> int:
    """Raj Patel's delivery on the POS, one dish of it with the kitchen, and the number the hub gave it.
    Paid in full where said, as an order paid on the website is."""
    number = h.delivery(order_id, "Raj Patel", "781 555 0102", OAK)
    h.op(order_id, "add_line", line_id="L1", item="Tea", qty=1, priced=TEA)
    h.op(order_id, "fire", course="*")
    if paid:
        h.op(order_id, "pay", payment_id=f"{order_id}-P1", method="cash", amount=due_on(h, order_id))
    return number


def due_on(h: Hub, order_id: str = "o-7") -> str:
    return h.c.get(f"/orders/{order_id}/check").json()["due"]


def raj(state: str, driver: dict = TOM, **more) -> dict:
    """The same delivery as Shipday has it: matched to the check by the phone number."""
    return order(
        7001, "S-77", name="Raj P.", address="4 Oak Road", phone="+17815550102", state=state, driver=driver, **more
    )


def heard(h: Hub, *active: dict, ended: dict | None = None) -> None:
    """Half a minute later Shipday lists these (and says this of the one that ended), and the hub reads it."""
    h.shipday.orders = list(active)
    if ended is not None:
        h.shipday.finished[ended["orderNumber"]] = ended
    h.shipday.carriers = [carrier(TOM), carrier(WEI)]
    h.now += 30_000
    h.board.round()


def check_of(h: Hub, order_id: str = "o-7") -> dict:
    return h.c.get(f"/orders/{order_id}").json()


def stands(h: Hub, order_id: str = "o-7") -> tuple:
    found = check_of(h, order_id)
    return (found["status"], found["fields"].get("stage"), found["fields"].get("driver"))


def texts(h: Hub) -> list[str]:
    return [text["kind"] for text in h.c.get("/messages").json()["messages"]]


def test_picked_up_in_shipday_takes_the_check_out_with_shipday_s_driver_and_texts_nobody():
    h = Hub(key=True)
    cooking(h)
    heard(h, raj("STARTED"))
    assert stands(h) == ("open", "new", None), "a driver on the way to the restaurant moves nothing"
    left = h.now + 10_000
    heard(h, raj("PICKED_UP", picked_up=left))
    fields = check_of(h)["fields"]
    assert (fields["stage"], fields["driver"], fields["driver_id"], fields["out_at"]) == (
        "out",
        "Tom Reyes",
        "shipday:501",
        left,
    )
    assert fields["shipday"] == {"id": 7001, "number": "S-77", "state": "PICKED_UP", "at_ms": left}
    assert texts(h) == [], "Shipday tells the customer itself: the POS sends no second text"
    assert h.shown()["orders"][0]["pos"]["stage"] == "out"
    assert h.shipday.changes() == [], "one way: nothing is told to Shipday"
    # the check's history says who did it, and the day's runs who took it
    steps = h.c.get("/orders/o-7/history", headers=h.manager()).json()["steps"]
    assert [(step["now"], step["by"], step.get("driver")) for step in steps if step["what"] == "stage"] == [
        ("out", "Shipday", "Tom Reyes")
    ]
    runs = h.c.get("/deliveries/runs").json()
    assert [(d["driver"], d["driver_id"], d["out"]) for d in runs["drivers"]] == [("Tom Reyes", "shipday:501", 1)]


def test_a_check_somebody_sends_out_on_the_pos_still_texts_its_customer():
    """The other way round, so that the test above would notice a text."""
    h = Hub(key=True)
    cooking(h)
    h.op("o-7", "set_field", stage="out", driver="Amy", driver_id="s1", out_at=h.now, by="Amy", by_id="s1")
    assert texts(h) == ["out"]
    heard(h, raj("PICKED_UP", picked_up=h.now))
    assert stands(h) == ("open", "out", "Amy"), "out already, with whoever: not sent out again"
    assert "shipday" not in check_of(h)["fields"] and texts(h) == ["out"]


def test_delivered_in_shipday_closes_a_check_with_nothing_left_to_pay():
    h = Hub(key=True)
    cooking(h, paid=True)
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert stands(h) == ("open", "out", "Tom Reyes")
    arrived = h.now + 600_000
    h.now += 600_000
    heard(h, ended=raj("ALREADY_DELIVERED", picked_up=arrived - 620_000, delivered=arrived))
    assert stands(h) == ("closed", "picked_up", "Tom Reyes")
    assert check_of(h)["fields"]["shipday"] == {
        "id": 7001,
        "number": "S-77",
        "state": "ALREADY_DELIVERED",
        "at_ms": arrived,
    }
    assert texts(h) == []
    done = h.shown()["done"][0]
    assert (done["state"], done["pos"]["status"], done["pos"]["stage"]) == ("ALREADY_DELIVERED", "closed", "picked_up")
    steps = h.c.get("/orders/o-7/history", headers=h.manager()).json()["steps"]
    assert [(step["what"], step["by"]) for step in steps if step["what"] in ("stage", "closed")] == [
        ("stage", "Shipday"),
        ("stage", "Shipday"),
        ("closed", "Shipday"),
    ]
    runs = h.c.get("/deliveries/runs").json()
    assert [(d["driver"], d["delivered"], d["out"]) for d in runs["drivers"]] == [("Tom Reyes", 1, 0)]


def test_delivered_before_the_hub_saw_it_leave_is_out_and_delivered_in_one_go():
    h = Hub(key=True)
    cooking(h, paid=True)
    heard(h, raj("STARTED"))
    h.now += 900_000
    left = h.now - 600_000
    heard(h, ended=raj("ALREADY_DELIVERED", picked_up=left, delivered=h.now - 30_000))
    assert stands(h) == ("closed", "picked_up", "Tom Reyes")
    assert check_of(h)["fields"]["out_at"] == left, "when Shipday says it was picked up"
    runs = h.c.get("/deliveries/runs").json()
    assert [(d["driver"], d["delivered"]) for d in runs["drivers"]] == [("Tom Reyes", 1)] and runs["no_driver"] == 0


def test_a_delivered_check_with_money_due_stays_open_until_somebody_takes_the_money():
    h = Hub(key=True)
    cooking(h)  # cash at the door
    assert due_on(h) == "10.71"
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    arrived = h.now + 300_000
    h.now += 300_000
    heard(h, ended=raj("ALREADY_DELIVERED", delivered=arrived))
    assert stands(h) == ("open", "out", "Tom Reyes"), "open, out with its driver, who has the money"
    assert check_of(h)["fields"]["shipday"]["state"] == "ALREADY_DELIVERED"
    assert check_of(h)["fields"]["shipday"]["at_ms"] == arrived
    heard(h)
    heard(h)
    assert stands(h) == ("open", "out", "Tom Reyes") and due_on(h) == "10.71", "however often Shipday is read"
    # its history says it left with Shipday's driver, and what Shipday said after: once each
    steps = h.c.get("/orders/o-7/history", headers=h.manager()).json()["steps"]
    assert [
        (step["what"], step.get("now") or step.get("state"), step.get("said_ms"), step["by"])
        for step in steps
        if step["what"] in ("stage", "shipday")
    ] == [("stage", "out", None, "Shipday"), ("shipday", "ALREADY_DELIVERED", arrived, "Shipday")]
    # the driver is back with the cash: Delivered on the POS, as ever
    h.op("o-7", "pay", payment_id="P9", method="cash", amount="10.71", by="Amy")
    h.op("o-7", "set_field", stage="picked_up")
    h.op("o-7", "close")
    assert stands(h) == ("closed", "picked_up", "Tom Reyes")
    heard(h)
    assert stands(h) == ("closed", "picked_up", "Tom Reyes")


def test_a_delivered_check_whose_money_was_taken_without_closing_it_is_closed_at_the_next_reading():
    h = Hub(key=True)
    cooking(h)
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    heard(h, ended=raj("ALREADY_DELIVERED", delivered=h.now + 20_000))
    assert stands(h) == ("open", "out", "Tom Reyes")
    h.op("o-7", "pay", payment_id="P9", method="cash", amount="10.71", by="Amy")
    heard(h)
    assert stands(h) == ("closed", "picked_up", "Tom Reyes")


def test_failed_or_incomplete_in_shipday_moves_nothing_and_is_written_on_the_check():
    for word in ("FAILED_DELIVERY", "INCOMPLETE"):
        h = Hub(key=True)
        cooking(h, paid=True)
        heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
        heard(h, ended=raj(word))
        assert stands(h) == ("open", "out", "Tom Reyes"), "a person decides what becomes of the bag"
        assert check_of(h)["fields"]["shipday"]["state"] == word
        assert h.shown()["done"][0]["pos"]["stage"] == "out"


def test_each_step_is_written_once_and_what_a_person_does_afterwards_stands():
    h = Hub(key=True)
    cooking(h, paid=True)
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    wrote = len(h.store.for_order("o-7"))
    heard(h, raj("PICKED_UP", picked_up=h.now - 10_000))
    heard(h, raj("READY_TO_DELIVER", picked_up=h.now - 40_000))
    assert len(h.store.for_order("o-7")) == wrote, "read three times, written once"
    # the bag came back: Shipday still says picked up, and the check stays where the person put it
    h.op("o-7", "set_field", stage="ready", driver=None, driver_id=None, by="Amy", by_id="s1")
    heard(h, raj("PICKED_UP", picked_up=h.now - 70_000))
    assert stands(h) == ("open", "ready", None)
    # another driver picks it up: that is another step
    left = h.now + 20_000
    heard(h, raj("PICKED_UP", WEI, picked_up=left))
    assert stands(h) == ("open", "out", "Wei Zhang") and check_of(h)["fields"]["out_at"] == left
    assert texts(h) == []
    # closed by Shipday, opened again by a manager: it is not closed behind their back a second time
    heard(h, ended=raj("ALREADY_DELIVERED", WEI, delivered=h.now + 20_000))
    assert stands(h)[0] == "closed"
    h.op("o-7", "reopen", by="Mike", by_id="s3")
    heard(h)
    heard(h)
    assert stands(h)[0] == "open"


def test_a_check_the_kitchen_never_had_or_that_is_voided_is_not_moved():
    h = Hub(key=True)
    h.delivery("o-7", "Raj Patel", "781 555 0102", OAK)  # rung up, and never sent
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert stands(h) == ("open", "new", None)
    assert check_of(h)["fields"]["shipday"]["state"] == "PICKED_UP", "what Shipday said is on it all the same"
    h.op("o-7", "void_order", by="Mike", by_id="s3", reason="rung twice")
    heard(h, ended=raj("ALREADY_DELIVERED", delivered=h.now + 20_000))
    assert stands(h)[0] == "void" and check_of(h)["fields"]["shipday"]["state"] == "PICKED_UP"


def test_a_delivery_that_is_on_no_check_moves_none():
    h = Hub(key=True)
    cooking(h, paid=True)
    heard(h, order(7002, "S-90", name="Zoe", phone="+17815550104", state="PICKED_UP", driver=TOM, picked_up=at(18)))
    assert stands(h) == ("open", "new", None)
    assert len(h.store.for_order("o-7")) == 4


def test_a_manager_turns_it_off_and_on_again_under_location():
    h = Hub(key=True)
    both = {"moves_checks": True, "tells_ready": True}
    assert h.c.get("/settings/shipday").json() == both, "on to start: the restaurant chose it"
    assert h.shown()["moves_checks"] is True
    assert h.c.put("/settings/shipday", json={"moves_checks": False}).status_code == 401
    assert h.c.put("/settings/shipday", json={"moves_checks": "no"}, headers=h.manager()).status_code == 422
    told: list = []
    h.c.app.state.feed.changed = told.append
    off = h.c.put("/settings/shipday", json={"moves_checks": False}, headers=h.manager())
    assert off.status_code == 200 and off.json() == {"moves_checks": False, "tells_ready": True}
    assert told == ["settings", "shipday"], "the screens that say so read it again"
    cooking(h, paid=True)
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert h.shown()["moves_checks"] is False and h.shown()["orders"][0]["pos"]["stage"] == "new"
    assert stands(h) == ("open", "new", None) and "shipday" not in check_of(h)["fields"]
    # on again: the hub acts at its next reading on what Shipday says by then
    h.c.put("/settings/shipday", json={"moves_checks": True}, headers=h.manager())
    assert stands(h) == ("open", "new", None), "not before Shipday was read again"
    heard(h, raj("PICKED_UP", picked_up=h.now - 10_000))
    assert stands(h) == ("open", "out", "Tom Reyes")


def test_marking_a_delivery_delivered_from_the_pos_closes_its_check_once_shipday_says_so():
    h = Hub(key=True)
    cooking(h, paid=True)
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    h.now += 5_000
    h.shipday.now = h.now
    answer = mark(h, "ALREADY_DELIVERED", "PICKED_UP")
    assert outcome(answer) == (True, True, True, None)
    assert stands(h) == ("closed", "picked_up", "Tom Reyes"), "the check follows Shipday, whoever marked it there"
    assert answer["shipday"]["done"][0]["pos"]["status"] == "closed"
    assert answer["shipday"]["moves_checks"] is True


def test_only_the_hub_writes_what_shipday_said_onto_a_check():
    h = Hub(key=True)
    cooking(h)
    h.op("o-7", "set_field", note="ring twice", shipday={"id": 1, "number": "x", "state": "ALREADY_DELIVERED"})
    fields = check_of(h)["fields"]
    assert fields["note"] == "ring twice" and "shipday" not in fields


def test_the_screens_are_told_when_shipday_moved_a_check():
    h = Hub(key=True)
    cooking(h, paid=True)
    poked: list = []
    h.c.app.state.feed.poke = lambda: poked.append(1)
    heard(h, raj("STARTED"))
    assert poked == []
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert poked == [1]
    heard(h, raj("PICKED_UP", picked_up=h.now - 10_000))
    assert poked == [1], "and not when nothing was written"


def test_a_moved_check_is_logged_by_its_number_and_shipday_s_id_and_no_customer(caplog):
    h = Hub(key=True)
    number = cooking(h, paid=True)
    with caplog.at_level(logging.DEBUG):
        heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
        heard(h, ended=raj("ALREADY_DELIVERED", delivered=h.now + 20_000))
    assert f"shipday: check #{number} is out, as Shipday says it was picked up (its order 7001)" in caplog.text
    assert f"shipday: check #{number} is delivered and closed, as Shipday says it was delivered" in caplog.text
    ours = "\n".join(r.getMessage() for r in caplog.records if r.name.startswith("pos"))
    assert "is delivered and closed" in ours
    for word in (KEY, "Raj", "Oak R", "5550102", "Tom", "S-77"):
        assert word not in ours, word


def test_a_hub_whose_following_goes_wrong_still_reads_and_shows_shipday(caplog):
    h = Hub(key=True)
    cooking(h, paid=True)

    def broken() -> None:
        raise RuntimeError("the books are shut")

    h.board.on_round = broken
    with caplog.at_level(logging.ERROR):
        heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert "following it on the POS went wrong" in caplog.text
    assert h.shown()["orders"][0]["state"] == "PICKED_UP" and h.shown()["trouble"] is None
    assert stands(h) == ("open", "new", None)


# --- a check marked Ready tells Shipday ----------------------------------------------------------------------


def bagged(h: Hub, order_id: str = "o-7", *, by: str = "Amy") -> None:
    """Somebody at a screen marks the check Ready."""
    h.op(order_id, "set_field", stage="ready", by=by, by_id="s1")


def told_on(h: Hub, order_id: str = "o-7") -> dict | None:
    return check_of(h, order_id)["fields"].get("shipday_ready")


def test_a_check_marked_ready_tells_shipday_it_is_ready_for_pickup_by_itself_and_once():
    h = Hub(key=True)
    cooking(h)
    heard(h, raj("NOT_STARTED_YET"))
    assert h.shipday.changes() == [], "a check that is cooking tells Shipday nothing"
    waiting_one = h.shown()["orders"][0]
    assert (waiting_one["can_ready"], waiting_one["ready_ms"]) == (True, None)
    bagged(h)
    assert h.shipday.changes() == [], "nothing is sent from the tap itself: the hub's next reading does it"
    as_listed = json.dumps([raj("NOT_STARTED_YET")])
    heard(h, raj("NOT_STARTED_YET"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"] and h.shipday.ready == {7001: True}
    put = next(sent for sent in h.shipday.sent if sent.method == "PUT")
    assert json.loads(put.content) == {"readyToPickup": True}, "one word of Shipday's own, and nothing of the POS"
    assert h.shipday.calls[-2:] == ["GET /orders", "PUT /orders/7001/meta"], "on the list just read: not asked twice"
    assert json.dumps(h.shipday.orders) == as_listed
    # the check says so, the picture says so, and nothing else moved
    assert told_on(h) == {"id": 7001, "at_ms": h.now, "auto": True}
    now = h.shown()["orders"][0]
    assert (now["ready_ms"], now["can_ready"], now["pos"]["stage"]) == (h.now, False, "ready")
    assert stands(h) == ("open", "ready", None) and texts(h) == [], "no text: a delivery is brought"
    steps = h.c.get("/orders/o-7/history", headers=h.manager()).json()["steps"]
    said = [step for step in steps if step["what"] == "shipday_ready"]
    assert [(step["auto"], step["told_ms"], step["by"], step["device"]) for step in said] == [
        (True, h.now, "Shipday", "shipday")
    ]
    # once: not at the next readings, not after the check went back and was marked Ready again
    told_at = h.now
    heard(h, raj("NOT_STARTED_YET"))
    h.op("o-7", "set_field", stage="new", by="Amy", by_id="s1")
    heard(h, raj("STARTED"))
    bagged(h)
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"]
    assert told_on(h) == {"id": 7001, "at_ms": told_at, "auto": True}
    # and what Shipday says afterwards moves the check as before
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert stands(h) == ("open", "out", "Tom Reyes")
    assert h.shipday.changes() == ["PUT /orders/7001/meta"]


def test_a_delivery_nobody_has_yet_and_one_the_website_marked_ready_are_told_too():
    h = Hub(key=True)
    cooking(h)
    bagged(h)
    heard(h, raj("NOT_ASSIGNED", driver=None))
    assert h.shipday.ready == {7001: True}, "the food can be made before a driver is found"
    assert told_on(h) == {"id": 7001, "at_ms": h.now, "auto": True}
    # GloriaFood's own word that an order is ready is written on the check by the hub: who marked it Ready
    # makes no difference
    h = Hub(key=True)
    h.from_the_website("1270166229", "Linda Chen", "781 555 0101")
    h.store.append(
        [
            Op(
                "gf-1270166229:ready",
                "gf-1270166229",
                HLC(h.now, 1, "online"),
                "online",
                "set_field",
                {"stage": "ready", "by": "Online order"},
            )
        ]
    )
    heard(h, order(7002, "1270166229", state="STARTED", driver=TOM))
    assert h.shipday.ready == {7002: True}
    assert told_on(h, "gf-1270166229") == {"id": 7002, "at_ms": h.now, "auto": True}


def test_nothing_is_told_by_itself_of_a_delivery_that_left_or_has_no_ready_check_here():
    h = Hub(key=True)
    cooking(h)
    # picked up in Shipday before anybody marked the check: the check goes Out, and nothing is ready any more
    bagged(h)
    heard(h, raj("PICKED_UP", picked_up=h.now + 20_000))
    assert stands(h) == ("open", "out", "Tom Reyes") and h.shipday.changes() == []
    # a delivery Shipday lists that is on no check here: the button on the Shipday screen is for that one
    h = Hub(key=True)
    heard(h, order(7003, "S-90", state="STARTED", driver=TOM))
    assert h.shipday.changes() == [] and h.shown()["orders"][0]["can_ready"] is True
    # a check that was closed or voided while it stood at Ready
    for end in ("close", "void_order"):
        h = Hub(key=True)
        cooking(h, paid=True)
        bagged(h)
        h.op("o-7", end, **({"reason": "customer cancelled", "by": "Mike"} if end == "void_order" else {"by": "Amy"}))
        heard(h, raj("STARTED"))
        assert h.shipday.changes() == [] and told_on(h) is None, end
    # an order that comes to the counter is no delivery, whatever Shipday lists under its phone number
    h = Hub(key=True)
    h.op("o-8", "create", order_type="takeout", customer_name="Sam", phone="781 555 0103")
    h.op("o-8", "set_field", stage="ready", by="Amy", by_id="s1")
    heard(h, order(7004, "S-91", name="Sam", phone="+17815550103", state="STARTED", driver=TOM))
    assert h.shipday.changes() == [] and h.shown()["orders"][0]["pos"] is None


def test_a_hub_that_restarted_reads_on_the_check_that_shipday_was_told():
    h = Hub(key=True)
    cooking(h)
    bagged(h)
    heard(h, raj("STARTED"))
    told_at = h.now
    assert h.shipday.changes() == ["PUT /orders/7001/meta"]
    # everything the hub kept in memory is gone, as after `hubctl update`: the check still says it
    h.board.use(None)
    h.board.use(h.shipday.source())
    heard(h, raj("STARTED"))
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"], "not told a second time"
    now = h.shown()["orders"][0]
    assert (now["ready_ms"], now["can_ready"]) == (told_at, False), "and the screens still say when"
    # what the check says of another delivery is not this one's: Shipday made the order anew under another id
    h.board.use(None)
    h.board.use(h.shipday.source())
    again = {**raj("STARTED"), "orderId": 7009}
    heard(h, again)
    assert h.shipday.changes() == ["PUT /orders/7001/meta", "PUT /orders/7009/meta"]
    assert told_on(h) == {"id": 7009, "at_ms": h.now, "auto": True}


def test_shipday_not_answering_is_tried_again_a_few_times_and_a_refusal_is_not_repeated(caplog):
    h = Hub(key=True)
    cooking(h)
    bagged(h)
    h.shipday.lost = True  # it takes the word and its answer never arrives
    with caplog.at_level(logging.DEBUG):
        heard(h, raj("STARTED"))
        assert h.shipday.changes() == ["PUT /orders/7001/meta"]
        assert told_on(h) is None and h.shown()["orders"][0]["ready_ms"] is None, "not known: nothing is written"
        heard(h, raj("STARTED"))
        assert len(h.shipday.changes()) == 1, "half a minute later is too soon"
        heard(h, raj("STARTED"))
        assert len(h.shipday.changes()) == 2, "a minute later it is tried again"
        heard(h, raj("STARTED"))
        heard(h, raj("STARTED"))
        assert len(h.shipday.changes()) == 3
        for _ in range(6):
            heard(h, raj("STARTED"))
        assert len(h.shipday.changes()) == 3, "three tries, and no more while it stands as it does"
        assert h.shown()["orders"][0]["can_ready"] is True, "the button on the Shipday screen is still there"
    assert (
        "shipday: order 7001 not said ready for pickup (slow), by the hub itself as its check is ready" in caplog.text
    )
    assert "not tried again while it stands as it does" in caplog.text
    # it stands elsewhere in Shipday (another driver has it): asked afresh, and Shipday answers now
    h.shipday.lost = False
    heard(h, raj("NOT_STARTED_YET", driver=WEI))
    assert len(h.shipday.changes()) == 4 and told_on(h) == {"id": 7001, "at_ms": h.now, "auto": True}
    # a refusal is Shipday's answer: the same is not asked again
    h = Hub(key=True)
    cooking(h)
    bagged(h)
    h.shipday.refuses = (400, {"message": "Order is locked"})
    with caplog.at_level(logging.DEBUG):
        for _ in range(6):
            heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"] and told_on(h) is None
    assert "locked" not in caplog.text, "what Shipday said is in no log"
    h.shipday.refuses = False
    heard(h, raj("STARTED"))
    assert len(h.shipday.changes()) == 1, "still where it stood"
    heard(h, raj("STARTED", driver=WEI))
    assert len(h.shipday.changes()) == 2 and told_on(h) is not None
    # and a person's tap is never held back by the hub's own tries
    h = Hub(key=True)
    cooking(h)
    bagged(h)
    h.shipday.refuses = (400, {"message": "Order is locked"})
    heard(h, raj("STARTED"))
    h.shipday.refuses = False
    assert outcome(ready(h)) == (True, True, False, None)
    assert told_on(h) == {"id": 7001, "at_ms": h.now, "auto": False}


def test_the_button_writes_on_the_check_who_told_shipday_and_the_hub_does_not_tell_it_again():
    h = Hub(key=True)
    cooking(h)
    heard(h, raj("STARTED"))
    assert outcome(ready(h)) == (True, True, False, None), "tapped while the check is still cooking"
    assert told_on(h) == {"id": 7001, "at_ms": h.now, "auto": False}
    steps = h.c.get("/orders/o-7/history", headers=h.manager()).json()["steps"]
    assert [(step["auto"], step["by"]) for step in steps if step["what"] == "shipday_ready"] == [(False, "Amy")]
    assert stands(h) == ("open", "new", None), "the tap tells Shipday: it marks nothing on the POS"
    bagged(h)
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"], "told once, by Amy"
    # a delivery that is on no check: told, remembered by the hub, written nowhere
    h = Hub(key=True)
    held(h)
    assert outcome(ready(h)) == (True, True, False, None)
    assert h.shown()["orders"][0]["ready_ms"] == h.now


def test_a_tap_on_the_button_before_the_hub_s_own_turn_tells_shipday_once():
    h = Hub(key=True)
    cooking(h)
    heard(h, raj("STARTED"))
    bagged(h)
    # the hub has not read Shipday since: the person's tap reads it first, where the hub tells by itself
    said = ready(h)
    assert outcome(said) == (True, True, False, None)
    assert h.shipday.changes() == ["PUT /orders/7001/meta"], "one telling, not the hub's and the person's"
    assert told_on(h) == {"id": 7001, "at_ms": h.now, "auto": True}
    assert said["shipday"]["orders"][0]["ready_ms"] == h.now


def test_marking_a_delivery_ready_brings_the_hub_s_next_reading_forward():
    h = Hub(key=True)
    hurried: list[int] = []
    h.board.hurry = lambda: hurried.append(1)
    cooking(h)
    assert hurried == []
    bagged(h)
    assert hurried == [1], "Shipday is asked and told now, not at the next turn"
    h.op("o-7", "set_field", stage="new", by="Amy", by_id="s1")
    h.op("o-7", "set_field", note="ring twice")
    assert hurried == [1]
    h.op("o-8", "create", order_type="takeout", customer_name="Sam", phone="781 555 0103")
    h.op("o-8", "set_field", stage="ready", by="Amy", by_id="s1")
    assert hurried == [1], "an order that comes to the counter is nothing of Shipday's"
    h.c.put("/settings/shipday", json={"tells_ready": False}, headers=h.manager())
    bagged(h)
    assert hurried == [1], "and nothing while the hub does not tell Shipday by itself"
    bare = Hub()
    bare.board.hurry = lambda: hurried.append(2)
    cooking(bare)
    bagged(bare)
    assert hurried == [1], "nor on a hub without the key"


def test_a_manager_turns_the_telling_off_and_on_again_under_location():
    h = Hub(key=True)
    assert h.shown()["tells_ready"] is True, "on to start: the restaurant chose it"
    assert h.c.put("/settings/shipday", json={"tells_ready": False}).status_code == 401
    assert h.c.put("/settings/shipday", json={"tells_ready": "no"}, headers=h.manager()).status_code == 422
    off = h.c.put("/settings/shipday", json={"tells_ready": False}, headers=h.manager())
    assert off.status_code == 200 and off.json() == {"moves_checks": True, "tells_ready": False}
    # each switch is saved without the other: an app from before the second one sends the first alone
    kept = h.c.put("/settings/shipday", json={"moves_checks": False}, headers=h.manager())
    assert kept.json() == {"moves_checks": False, "tells_ready": False}
    kept = h.c.put("/settings/shipday", json={"moves_checks": True}, headers=h.manager())
    assert kept.json() == {"moves_checks": True, "tells_ready": False}
    assert h.c.put("/settings/shipday", json={}, headers=h.manager()).json() == kept.json(), "nothing named"
    cooking(h)
    bagged(h)
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == [] and told_on(h) is None
    picture = h.shown()
    assert picture["tells_ready"] is False and picture["orders"][0]["can_ready"] is True
    # the button still tells Shipday, as a person asked for exactly that
    h2 = Hub(key=True)
    h2.c.put("/settings/shipday", json={"tells_ready": False}, headers=h2.manager())
    cooking(h2)
    bagged(h2)
    heard(h2, raj("STARTED"))
    assert outcome(ready(h2)) == (True, True, False, None) and told_on(h2)["auto"] is False
    # on again: the hub tells at its next reading, also of the check marked meanwhile
    both = h.c.put("/settings/shipday", json={"tells_ready": True}, headers=h.manager())
    assert both.json() == {"moves_checks": True, "tells_ready": True}
    assert h.shipday.changes() == [], "not before Shipday was read again"
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"] and told_on(h)["auto"] is True


def test_a_hub_that_stands_by_tells_shipday_nothing():
    h = Hub(key=True)
    cooking(h)
    bagged(h)
    h.store.role = "replica"  # the location's other hub: it reads, and the one that serves tells
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == [] and told_on(h) is None
    h.store.role = "primary"
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"]


def test_only_the_hub_writes_on_a_check_that_shipday_was_told():
    h = Hub(key=True)
    cooking(h)
    h.op("o-7", "set_field", note="ring twice", shipday_ready={"id": 7001, "at_ms": 1, "auto": True})
    fields = check_of(h)["fields"]
    assert fields["note"] == "ring twice" and "shipday_ready" not in fields
    bagged(h)
    heard(h, raj("STARTED"))
    assert h.shipday.changes() == ["PUT /orders/7001/meta"], "a screen's word for it holds nothing back"


def test_the_screens_are_told_when_the_hub_told_shipday_by_itself():
    h = Hub(key=True)
    cooking(h)
    heard(h, raj("STARTED"))
    bagged(h)
    told: list[str] = []
    poked: list[int] = []
    h.c.app.state.feed.changed = told.append
    h.c.app.state.feed.poke = lambda: poked.append(1)
    heard(h, raj("STARTED"))
    assert told == ["shipday"], "the Shipday screens read the picture again"
    assert poked == [1], "and the check's own screens hear that it was written on"
    heard(h, raj("STARTED"))
    assert (told, poked) == (["shipday"], [1]), "and not when nothing was told"


def test_the_hub_s_own_telling_is_logged_by_number_and_shipday_s_id_and_no_customer(caplog):
    h = Hub(key=True)
    number = cooking(h)
    bagged(h)
    with caplog.at_level(logging.DEBUG):
        heard(h, raj("STARTED"))
    ours = "\n".join(r.getMessage() for r in caplog.records if r.name.startswith("pos"))
    assert "shipday: order 7001 said ready for pickup by the hub itself, as its check is ready" in ours
    assert f"shipday: check #{number} says that Shipday was told it is ready (its order 7001)" in ours
    for word in (KEY, "Raj", "Oak R", "5550102", "Tom", "S-77"):
        assert word not in ours, word
