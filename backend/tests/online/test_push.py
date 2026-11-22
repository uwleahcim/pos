"""Online orders GloriaFood sends by itself (pos.online.service, pos.api.online): a push is put on the POS at
once, the minute's asking stays on as the net under it, and an order that came both ways is one order."""

from __future__ import annotations

import json
import logging
import threading

from pos.online.gloriafood import PUSH_MOST
from pos.online.inbox import Arrival, Inbox
from pos.online.service import REFUSAL_LOG_MS, WRONG_KEY, OnlineOrders

from .hub import MINUTE, NOW, PUSH_KEY, FakeFood, Hub
from .orders import order, row

DAY = 24 * 60 * MINUTE
CHICKEN = ("Sweet & Sour Chicken", 2)
COMBO = ("Maki Combination",)
ROUND = {"asked": True, "came": 0, "known": 0, "placed": 0, "booked": 0, "kept": 0, "failed": 0}
TODAY = {"came": 0, "by_push": 0, "by_poll": 0, "placed": 0, "booked": 0, "kept": 0, "failed": 0, "unread": 0}
CUSTOMER = ("Pat", "Example", "555", "Restaurant Row", "3B", "Ring the bell")


def lunch(number: int = 301, **more) -> dict:
    return order(number, [row(*CHICKEN), row(*COMBO)], instructions="Ring the bell twice", **more)


def on_the_pos(hub: Hub, number: int) -> bool:
    return hub.client.get(f"/orders/gf-{number}").status_code == 200


def orders_on_the_pos(hub: Hub) -> int:
    return len(hub.client.get("/orders").json()["orders"])


def tickets(hub: Hub) -> list[str]:
    return sorted(job_id for job_id in hub.papers() if ":notice:" not in job_id)


def as_it_stands(hub: Hub, number: int = 301) -> tuple:
    """Everything a second arrival of the same order must leave alone."""
    return (len(hub.store.for_order(f"gf-{number}")), tickets(hub), orders_on_the_pos(hub), hub.slips())


# A push ------------------------------------------------------------------------------------------------------


def test_a_pushed_order_is_on_the_pos_at_once_numbered_and_printed_and_nobody_was_asked():
    hub = Hub(push=True)
    answer = hub.push(lunch())
    assert (answer.status_code, answer.json()) == (200, {"received": 1})
    assert hub.food.asked == 0  # it did not wait for the minute
    got = hub.order(301)
    assert (got["status"], got["fields"]["order_no"], got["fields"]["channel"]) == ("open", 1, "online")
    assert got["fired"] and got["fields"]["customer_name"] == "Pat Example"
    assert tickets(hub) == ["gf-301:fire:front", "gf-301:fire:sushi", "gf-301:fire:wok"]
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.order_id, arrival.via, arrival.fetched_ms) == ("placed", "gf-301", "push", NOW)
    status = hub.status()
    assert status["push"] == {"configured": True, "pushed_ms": NOW, "refused": None}
    assert status["today"] == {**TODAY, "came": 1, "by_push": 1, "placed": 1}


def test_a_pushed_order_is_the_same_order_as_one_the_hub_asked_for():
    asked, told = Hub(push=True), Hub(push=True)
    asked.accept(lunch(payment="ONLINE"))
    told.push(lunch(payment="ONLINE"))
    assert asked.order(301)["fields"] == told.order(301)["fields"]
    assert asked.check(301) == told.check(301)
    assert asked.papers() == told.papers()


# Both ways at once: one order ---------------------------------------------------------------------------------


def test_an_order_that_was_pushed_is_not_put_on_again_when_the_asking_brings_it():
    hub = Hub(push=True)
    hub.push(lunch())
    before = as_it_stands(hub)
    hub.clock += MINUTE
    assert hub.accept(lunch()) == {**ROUND, "came": 1, "known": 1}
    assert as_it_stands(hub) == before
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.via, arrival.fetched_ms) == ("push", NOW)  # how and when it came first
    assert hub.status()["today"] == {**TODAY, "came": 1, "by_push": 1, "placed": 1}


def test_an_order_the_asking_brought_first_is_not_put_on_again_by_its_push():
    hub = Hub(push=True)
    hub.accept(lunch())
    before = as_it_stands(hub)
    hub.clock += 5_000
    answer = hub.push(lunch())
    assert (answer.status_code, answer.json()) == (200, {"received": 1})  # GloriaFood is told it arrived
    assert as_it_stands(hub) == before
    assert hub.inbox.get("gloriafood", "301").via == "poll"
    assert hub.status()["today"] == {**TODAY, "came": 1, "by_poll": 1, "placed": 1}


def test_an_order_whose_push_never_came_is_brought_by_the_asking_within_the_minute():
    hub = Hub(push=True)
    hub.push(lunch(301))
    hub.clock += MINUTE
    # GloriaFood hands over both: the one it pushed, and one whose push was lost on the way
    assert hub.accept(lunch(301), lunch(302)) == {**ROUND, "came": 2, "known": 1, "placed": 1}
    assert (hub.order(301)["fields"]["order_no"], hub.order(302)["fields"]["order_no"]) == (1, 2)
    assert orders_on_the_pos(hub) == 2
    assert (hub.inbox.get("gloriafood", "301").via, hub.inbox.get("gloriafood", "302").via) == ("push", "poll")
    assert hub.status()["today"] == {**TODAY, "came": 2, "by_push": 1, "by_poll": 1, "placed": 2}


def test_the_same_order_pushed_twice_is_one_order():
    hub = Hub(push=True)
    assert hub.push(lunch(), lunch()).json() == {"received": 2}  # twice in one push
    before = as_it_stands(hub)
    assert before[2] == 1
    hub.clock += 2_000
    assert hub.push(lunch()).status_code == 200  # and once more, as GloriaFood's pages say it may
    assert as_it_stands(hub) == before


class Waiting(FakeFood):
    """A GloriaFood that takes its time to answer: `pop` waits until it is let go."""

    def __init__(self) -> None:
        super().__init__()
        self.asking = threading.Event()
        self.go = threading.Event()

    def pop(self) -> list[dict]:
        self.asking.set()
        assert self.go.wait(10)
        return super().pop()


def test_a_push_does_not_wait_for_gloriafood_s_answer_and_the_two_place_the_order_once():
    food = Waiting()
    hub = Hub(source=food, push=True)
    food.queue.append(lunch())
    done: list[dict] = []
    minute = threading.Thread(target=lambda: done.append(hub.online.round()))
    minute.start()
    assert food.asking.wait(10)  # the hub is waiting for GloriaFood's answer...
    assert hub.push(lunch()).status_code == 200  # ...and the push of the same order goes on meanwhile
    before = as_it_stands(hub)
    assert before[2] == 1 and hub.order(301)["fields"]["order_no"] == 1
    food.go.set()
    minute.join(10)
    assert done == [{**ROUND, "came": 1, "known": 1}]
    assert as_it_stands(hub) == before


def test_many_pushes_at_once_place_each_order_once_and_number_them_apart():
    hub = Hub(push=True)
    answers: list[int] = []

    def send(number: int) -> None:
        answers.append(hub.push(lunch(number)).status_code)

    senders = [threading.Thread(target=send, args=(301 + n % 4,)) for n in range(12)]  # four orders, each thrice
    for sender in senders:
        sender.start()
    for sender in senders:
        sender.join(20)
    assert answers == [200] * 12
    assert orders_on_the_pos(hub) == 4
    assert sorted(hub.order(n)["fields"]["order_no"] for n in range(301, 305)) == [1, 2, 3, 4]
    assert len(tickets(hub)) == 12  # three papers an order, once


# Who may push ------------------------------------------------------------------------------------------------


def test_a_push_without_the_key_is_turned_away_unread_and_nothing_of_it_is_kept(caplog):
    hub = Hub(push=True)
    with caplog.at_level(logging.DEBUG):
        nothing = hub.push(lunch(), key=None)
        wrong = hub.push(lunch(), key="somebody-else's-key")
        nearly = hub.push(lunch(), key=PUSH_KEY[:-1])
        longer = hub.push(lunch(), key=PUSH_KEY + "0")
        bearer = hub.push(lunch(), key=f"Bearer {PUSH_KEY}")
        unread = hub.push(key="wrong", body="this is not even JSON")  # it is turned away before it is read
    for answer in (nothing, wrong, nearly, longer, bearer, unread):
        assert (answer.status_code, answer.json()) == (401, {"error": "refused"})
    assert orders_on_the_pos(hub) == 0 and not hub.papers()
    assert hub.inbox.since(0) == [] and hub.status()["waiting"] == 0
    status = hub.status()
    assert status["push"] == {
        "configured": True,
        "pushed_ms": None,
        "refused": {"at_ms": NOW, "reason": WRONG_KEY, "count": 6},
    }
    # the log says it happened, once, and nothing of what was sent
    said = [record.getMessage() for record in caplog.records if record.name == "pos.online"]
    assert said == ["online orders: a push was turned away: it carried no key (1 so far)"]
    for text in (caplog.text, json.dumps(status)):
        assert "somebody" not in text and PUSH_KEY not in text and PUSH_KEY[:-1] not in text
        assert not [piece for piece in CUSTOMER if piece in text]
    # whoever keeps knocking is logged once a minute
    hub.clock += REFUSAL_LOG_MS
    with caplog.at_level(logging.WARNING):
        hub.push(lunch(), key="wrong")
    assert caplog.records[-1].getMessage() == f"online orders: a push was turned away: {WRONG_KEY} (7 so far)"
    # and the right key still gets in
    assert hub.push(lunch()).status_code == 200 and on_the_pos(hub, 301)


def test_a_hub_with_no_key_for_pushes_takes_none_and_says_nothing():
    hub = Hub()
    for key in (None, PUSH_KEY, ""):
        answer = hub.push(lunch(), key=key)
        assert (answer.status_code, answer.json()) == (404, {"error": "not_found"})
    assert orders_on_the_pos(hub) == 0 and hub.inbox.since(0) == []
    assert hub.status()["push"] == {"configured": False, "pushed_ms": None, "refused": None}


class Standby(Inbox):
    def writable(self) -> bool:
        return False


def test_a_push_to_a_hub_that_cannot_write_orders_down_is_not_taken():
    hub = Hub(inbox=Standby(), push=True)
    answer = hub.push(lunch())
    assert (answer.status_code, answer.json()) == (503, {"error": "standby"})  # GloriaFood knows it did not arrive
    assert orders_on_the_pos(hub) == 0


def test_a_push_that_is_too_big_is_turned_away():
    hub = Hub(push=True)
    answer = hub.push(body=b'{"orders": [' + b" " * PUSH_MOST + b"]}")
    assert (answer.status_code, answer.json()) == (413, {"error": "too_big"})
    assert hub.inbox.since(0) == []


# What a push may look like ------------------------------------------------------------------------------------


def test_a_push_may_hold_one_order_by_itself_a_bare_list_or_none():
    hub = Hub(push=True)
    assert hub.push(body=json.dumps(lunch(301))).json() == {"received": 1}
    assert hub.push(body=json.dumps([lunch(302), lunch(303)])).json() == {"received": 2}
    for none in ('{"count": 0, "orders": []}', '{"count": 0}', "{}", "", "  "):
        answer = hub.push(body=none)
        assert (answer.status_code, answer.json()) == (200, {"received": 0}), none
    assert orders_on_the_pos(hub) == 3 and hub.status()["today"]["unread"] == 0


def test_the_restaurant_s_own_keys_on_a_pushed_order_are_not_written_down():
    hub = Hub(push=True)
    told = lunch()
    assert told["restaurant_key"] and told["restaurant_token"]
    hub.push(told)
    raw = hub.inbox.get("gloriafood", "301").raw
    assert "restaurant_key" not in raw and "restaurant_token" not in raw and raw["id"] == 301


def test_a_push_that_cannot_be_read_is_kept_for_a_person_and_the_asking_brings_its_orders(caplog):
    hub = Hub(push=True)
    xml = (
        "<orders><order><id>301</id><restaurant_key>not-a-real-key</restaurant_key>"
        "<name>Pat Example</name></order></orders>"
    )
    with caplog.at_level(logging.WARNING):
        answer = hub.push(body=xml)
    assert (answer.status_code, answer.json()) == (422, {"error": "unreadable"})
    status = hub.status()
    assert status["today"] == {**TODAY, "unread": 1} and status["push"]["pushed_ms"] == NOW
    (look,) = status["look"]
    assert (look["id"], look["kind"], look["state"], look["via"]) == (f"unread-{NOW}", "unreadable", "failed", "push")
    assert look["said"] == (
        "GloriaFood's push could not be read (it came as XML, and the hub reads JSON): "
        "the hub's asking brings its orders"
    )
    # no slip: a slip would have somebody ring in an order that is on its way by the other road
    assert hub.slips() == []
    # what came is kept for a person, without the restaurant's key, and is shown to nobody who asks
    kept = hub.inbox.get("gloriafood", f"unread-{NOW}").raw["unreadable"]
    assert "not-a-real-key" not in kept and "<id>301</id>" in kept
    assert hub.client.get(f"/online/orders/unread-{NOW}").json()["order"] == {"unreadable": "(hidden)"}
    assert "Pat" not in caplog.text and "Pat" not in json.dumps(status)
    # the order itself comes within the minute
    hub.clock += MINUTE
    assert hub.accept(lunch()) == {**ROUND, "came": 1, "placed": 1}


def test_a_push_of_something_else_than_orders_is_told_of_by_its_shape():
    hub = Hub(push=True)
    answer = hub.push(body=json.dumps({"event": "ping", "client_first_name": "Pat", "payload": {"a": 1}}))
    assert answer.status_code == 422
    (look,) = hub.status()["look"]
    assert look["said"].startswith(
        "GloriaFood's push could not be read (it holds no orders, but: client_first_name, event, payload)"
    )
    assert "Pat" not in look["said"]


def test_on_a_hub_that_only_takes_pushes_one_that_cannot_be_read_prints_a_slip():
    hub = Hub(key=False, push=True)
    assert hub.push(body="not JSON").status_code == 422
    (look,) = hub.status()["look"]
    assert look["said"] == "GloriaFood's push could not be read (it is not JSON): its orders are in GloriaFood's app"
    (slip,) = hub.slips()
    assert "ONLINE ORDERS: LOOK" in slip and "GloriaFood's own app" in slip
    hub.clock += MINUTE
    hub.push(body="not JSON")
    assert len(hub.slips()) == 1  # not one a push


# A push in trouble --------------------------------------------------------------------------------------------


class Full(Inbox):
    """An inbox that cannot take an order, `fails` times."""

    def __init__(self, fails: int) -> None:
        super().__init__()
        self.fails = fails

    def add(self, arrival: Arrival) -> bool:
        if self.fails:
            self.fails -= 1
            raise RuntimeError("the disk is full")
        return super().add(arrival)


def test_a_pushed_order_that_cannot_be_written_down_is_answered_as_not_taken_and_is_not_lost():
    hub = Hub(inbox=Full(1), push=True)
    answer = hub.push(lunch())
    assert (answer.status_code, answer.json()) == (503, {"error": "not_written"})
    assert orders_on_the_pos(hub) == 0 and hub.status()["waiting"] == 1  # held in memory
    again = hub.push(lunch())  # GloriaFood tries again, if it does
    assert (again.status_code, again.json()) == (200, {"received": 1})
    assert orders_on_the_pos(hub) == 1 and hub.status()["waiting"] == 0
    hub.clock += MINUTE
    assert hub.accept(lunch()) == {**ROUND, "came": 1, "known": 1}  # and the asking brings it once more
    assert orders_on_the_pos(hub) == 1 and len(tickets(hub)) == 3


def test_a_pushed_order_that_cannot_be_written_down_is_written_at_the_next_minute_without_another_push():
    hub = Hub(inbox=Full(1), push=True)
    assert hub.push(lunch()).status_code == 503
    hub.clock += MINUTE
    assert hub.online.round() == {**ROUND, "placed": 1}
    assert on_the_pos(hub, 301) and hub.inbox.get("gloriafood", "301").via == "push"


def test_a_pushed_order_that_will_not_go_on_is_tried_again_by_the_minute_s_round():
    hub = Hub(key=False, push=True)  # even on a hub that asks nobody
    put, calls = hub.online.put, []

    def broken(told):
        calls.append(told["id"])
        if len(calls) == 1:
            raise RuntimeError("Pat Example's order")
        return put(told)

    hub.online.put = broken
    assert hub.push(lunch()).json() == {"received": 1}  # it arrived, and is written down
    assert not on_the_pos(hub, 301) and hub.status()["waiting"] == 1
    hub.clock += MINUTE
    assert hub.online.round() == {**ROUND, "asked": False, "placed": 1}
    assert on_the_pos(hub, 301) and len(tickets(hub)) == 3


def test_an_order_that_will_not_go_on_is_tried_once_a_minute_however_many_pushes_come_meanwhile():
    hub = Hub(push=True)
    put = hub.online.put

    def broken(told):
        if told["id"] == 301:
            raise RuntimeError("Pat Example's order")
        return put(told)

    hub.online.put = broken
    hub.push(lunch(301))
    for number in range(302, 310):  # a busy minute
        assert hub.push(lunch(number)).json() == {"received": 1}
    assert hub.inbox.get("gloriafood", "301").tries == 1 and hub.slips() == []
    assert orders_on_the_pos(hub) == 8
    hub.clock += MINUTE
    hub.online.round()
    assert hub.inbox.get("gloriafood", "301").tries == 2


def test_a_pushed_order_from_an_earlier_day_or_long_after_its_time_is_treated_as_one_the_hub_asked_for():
    hub = Hub(push=True)
    hub.clock = NOW + 45 * MINUTE
    assert hub.push(lunch(301)).status_code == 200
    assert on_the_pos(hub, 301) and not hub.order(301)["fired"]
    hub.clock = NOW + 2 * DAY
    assert hub.push(lunch(302)).status_code == 200
    assert not on_the_pos(hub, 302)
    late, old = sorted(hub.slips())
    assert "NOT ON THE POS" in late + old and "NOT SENT TO THE KITCHEN" in late + old


# The minute's round with only the key for pushes --------------------------------------------------------------


def test_the_minute_s_round_runs_with_either_key_and_not_without_one():
    for source, key, runs in ((None, None, False), (None, PUSH_KEY, True), (FakeFood(), None, True)):
        online = OnlineOrders(source, push_key=key)
        online.start(3600)
        assert online.status()["running"] is runs, (source, key)
