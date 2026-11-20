"""What the hub says to the screens of the online orders that need a person (pos.online.service `status`,
pos.api.online): which of the ones to look at came up after somebody last looked, what is wrong right now,
and the word that somebody looked."""

from __future__ import annotations

import json

from pos.online.gloriafood import FetchFailed
from pos.online.inbox import MOST_TRIES
from pos.online.service import STALE_MS
from pos.sync.pgstore import ReadOnlyError

from .hub import MINUTE, NOW, PUSH_KEY, Hub
from .orders import order, row
from .test_service import CHICKEN, Standby, lunch


def late(hub: Hub, number: int) -> None:
    """An order that reaches the hub long after its time: on the POS, not sent, and one to look at."""
    assert hub.accept(lunch(number))["placed"] == 1


def topics(hub: Hub) -> list[str]:
    """What the change feed is told from now on, in order."""
    told: list[str] = []
    feed = hub.client.app.state.feed
    said = feed.changed
    feed.changed = lambda topic: (told.append(topic), said(topic))[1]
    return told


# The ones to look at ------------------------------------------------------------------------------------------


def test_an_order_to_look_at_is_new_until_somebody_looked_and_stays_listed():
    hub = Hub()
    hub.clock = NOW + 45 * MINUTE
    late(hub, 301)
    status = hub.status()
    (look,) = status["look"]
    assert (look["id"], look["at_ms"], look["new"]) == ("301", hub.clock, True)
    assert (status["seen_ms"], status["news"]) == (0, 1)

    hub.clock += MINUTE
    after = hub.client.post("/online/seen", json={"by": "  Mike \n"})
    assert after.status_code == 200
    status = after.json()
    assert status == hub.status()  # it answers with the status as it now is
    (look,) = status["look"]
    assert (look["id"], look["new"]) == ("301", False)  # still listed: looking takes nothing away
    assert (status["seen_ms"], status["news"]) == (hub.clock, 0)
    assert hub.client.app.state.settings.get("online_seen") == {"at_ms": hub.clock, "by": "Mike"}

    # the next one is new, and the one before it is not
    hub.clock += MINUTE
    late(hub, 302)
    status = hub.status()
    assert [(look["id"], look["new"]) for look in status["look"]] == [("302", True), ("301", False)]
    assert status["news"] == 1


def test_an_order_that_is_still_being_tried_is_not_news_until_it_is_given_up_on():
    hub = Hub()

    def broken(told):
        raise RuntimeError("no")

    hub.online.put = broken
    for tries in range(1, MOST_TRIES):
        hub.accept(*([lunch()] if tries == 1 else []))
        status = hub.status()
        assert [look["new"] for look in status["look"]] == [False] and status["news"] == 0  # it may go on yet
        assert hub.slips() == []
        hub.clock += MINUTE
    hub.accept()
    status = hub.status()
    (look,) = status["look"]
    assert (look["state"], look["tries"], look["new"], look["at_ms"]) == ("failed", MOST_TRIES, True, hub.clock)
    assert status["news"] == 1 and len(hub.slips()) == 1  # news at the moment its slip prints


def test_something_that_cannot_be_read_is_news_and_an_order_that_went_on_cleanly_is_not():
    hub = Hub()
    assert hub.accept(lunch())["placed"] == 1
    assert (hub.status()["look"], hub.status()["news"]) == ([], 0)
    hub.clock += MINUTE
    hub.food.fail = FetchFailed("GloriaFood's answer could not be read", "<html>")
    hub.accept()
    status = hub.status()
    assert [(look["kind"], look["new"]) for look in status["look"]] == [("unreadable", True)]
    assert status["news"] == 1


def test_who_looked_is_kept_short_and_nothing_else_is_taken_from_the_call():
    hub = Hub()
    assert hub.client.post("/online/seen", json={}).status_code == 200  # nobody named: it still counts
    assert hub.client.app.state.settings.get("online_seen") == {"at_ms": NOW, "by": ""}
    assert hub.client.post("/online/seen", json={"by": "x" * 81}).status_code == 422
    assert hub.client.post("/online/seen", json={"by": "Amy", "at_ms": 1}).json()["seen_ms"] == NOW  # the hub's clock


def test_the_screens_hear_of_something_to_look_at_and_of_somebody_looking():
    hub = Hub()
    told = topics(hub)
    hub.accept(lunch())
    assert "online" not in told  # an order that went on as it should is nothing to look at
    hub.clock = NOW + 45 * MINUTE
    late(hub, 302)
    assert told.count("online") == 1
    hub.client.post("/online/seen", json={"by": "Mike"})
    assert told.count("online") == 2


def test_the_screens_hear_of_one_to_look_at_that_prints_no_slip():
    hub = Hub(push=True)
    told = topics(hub)
    # on the POS and sent to the kitchen, with a dish the menu on the POS does not have: no slip, and one to look at
    assert hub.accept(order(303, [row("Orange Juice", 2), row(*CHICKEN)]))["placed"] == 1
    status = hub.status()
    assert [(look["id"], look["state"], look["new"]) for look in status["look"]] == [("303", "placed", True)]
    assert status["look"][0]["said"] == "1 dish went on as written (Orange Juice)"
    assert (hub.slips(), told.count("online")) == ([], 1)


def test_a_push_that_cannot_be_read_is_news_only_where_nothing_else_brings_its_orders():
    # on a hub that also asks, the asking brings its orders: listed, and nobody is sent to ring them in again
    hub = Hub(push=True)
    told = topics(hub)
    assert hub.push(body="<xml/>").status_code == 422
    status = hub.status()
    assert [(look["kind"], look["new"]) for look in status["look"]] == [("unreadable", False)]
    assert (hub.slips(), told, status["news"]) == ([], [], 0)

    # on a hub that only takes pushes, somebody has to look at GloriaFood's app
    alone = Hub(push=True, key=False)
    told = topics(alone)
    assert alone.push(body="<xml/>").status_code == 422
    status = alone.status()
    assert [(look["kind"], look["new"]) for look in status["look"]] == [("unreadable", True)]
    assert (len(alone.slips()), told, status["news"]) == (1, ["online"], 1)


def test_an_order_that_will_be_tried_again_tells_the_screens_nothing_yet():
    hub = Hub()
    told = topics(hub)

    def broken(told):
        raise RuntimeError("no")

    hub.online.put = broken
    hub.accept(lunch())
    assert "online" not in told
    for _ in range(1, MOST_TRIES):
        hub.clock += MINUTE
        hub.accept()
    assert told.count("online") == 1  # given up on: now it is one to look at


def test_the_status_and_the_word_that_somebody_looked_name_no_customer_and_no_key():
    hub = Hub(push=True)
    hub.clock = NOW + 45 * MINUTE
    late(hub, 301)
    hub.push(lunch(302), key="wrong")
    said = json.dumps([hub.status(), hub.client.post("/online/seen", json={"by": "Mike"}).json()])
    for word in ("Pat", "Example", "555", "Restaurant Row", "Ring the bell", PUSH_KEY, 'wrong"'):
        assert word not in said


# What is wrong right now ----------------------------------------------------------------------------------


def test_asking_that_fails_for_five_minutes_is_trouble_and_one_answer_ends_it():
    hub = Hub()
    assert hub.status()["trouble"] == []
    hub.food.fail = FetchFailed("GloriaFood refused the key")
    began = hub.clock
    hub.accept()
    assert hub.status()["trouble"] == []  # one answer that did not come is not trouble yet
    while hub.clock - began < STALE_MS - MINUTE:
        hub.clock += MINUTE
        hub.accept()
    assert hub.status()["trouble"] == []
    hub.clock += MINUTE
    hub.accept()
    assert hub.status()["trouble"] == [
        {"code": "not_answering", "since_ms": began, "reason": "GloriaFood refused the key", "urgent": True}
    ]
    # looking does not take it away: it holds until it is mended
    assert hub.client.post("/online/seen", json={"by": "Mike"}).json()["trouble"][0]["code"] == "not_answering"
    hub.food.fail = None
    hub.clock += MINUTE
    hub.accept()
    assert hub.status()["trouble"] == []
    # and it counts afresh the next time
    hub.food.fail = FetchFailed("GloriaFood did not answer in time")
    hub.clock += MINUTE
    hub.accept()
    assert hub.status()["trouble"] == []


def test_asking_that_fails_while_pushes_get_in_is_trouble_but_not_urgent():
    hub = Hub(push=True)
    assert hub.push(lunch(301)).status_code == 200
    hub.food.fail = FetchFailed("GloriaFood did not answer in time")
    began = hub.clock
    hub.accept()
    hub.clock += STALE_MS
    hub.accept()
    (trouble,) = hub.status()["trouble"]
    assert (trouble["code"], trouble["since_ms"], trouble["urgent"]) == ("not_answering", began, False)
    # a push turned away after the last one that got in: nothing is known to reach the POS any more
    hub.clock += MINUTE
    assert hub.push(lunch(302), key="wrong").status_code == 401
    (trouble,) = hub.status()["trouble"]
    assert (trouble["code"], trouble["urgent"]) == ("not_answering", True)


def test_orders_that_come_only_by_asking_while_pushes_are_turned_away_are_trouble_that_is_not_urgent():
    hub = Hub(push=True)
    assert hub.push(lunch(301), key="wrong").status_code == 401
    assert hub.status()["trouble"] == []  # nothing came by asking either: nothing says pushes should have
    hub.clock += MINUTE
    assert hub.accept(lunch(301))["placed"] == 1
    assert hub.status()["trouble"] == [
        {
            "code": "pushes_refused",
            "since_ms": NOW,
            "reason": "it carried the wrong key",
            "urgent": False,
            "count": 1,
        }
    ]
    # a push that gets in after it ends it: the test of the way in knocks once without the key, then with it
    hub.clock += MINUTE
    assert hub.push().status_code == 200
    assert hub.status()["trouble"] == []


def test_a_hub_that_cannot_write_says_so_instead_of_keeping_who_looked():
    hub = Hub(inbox=Standby())

    def standby(key, data):
        raise ReadOnlyError("this database is a standby")

    hub.client.app.state.settings.put = standby
    answer = hub.client.post("/online/seen", json={"by": "Mike"})
    assert (answer.status_code, answer.json()["detail"]) == (503, {"error": "read_only"})
