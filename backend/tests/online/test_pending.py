"""An order GloriaFood hands over before the restaurant answered it (pos.online.service, pos.online.inbox).

With "Pending" among the statuses of its integration, GloriaFood gives the hub an order the moment the
customer places it, and the same order again when the restaurant accepts it, turns it down or misses it. The
first is not put on the POS and alerts nobody; what comes after it is taken as it comes."""

from __future__ import annotations

from typing import Any

from pos.online.place import WAITS
from pos.online.service import UNANSWERED_MS

from .hub import MINUTE, NOW, Hub
from .orders import order, reservation, row

CHICKEN = ("Sweet & Sour Chicken", 2)
COMBO = ("Maki Combination",)
NONE = {"asked": True, "came": 0, "known": 0, "placed": 0, "booked": 0, "kept": 0, "failed": 0}
TODAY = {"came": 0, "by_push": 0, "by_poll": 0, "placed": 0, "booked": 0, "kept": 0, "failed": 0, "unread": 0}
TICKETS = ["gf-301:fire:front", "gf-301:fire:sushi", "gf-301:fire:wok"]
TOMORROW = "2027-01-16"
SEVEN_TOMORROW = "2027-01-17T00:00:00.000Z"  # 19:00 on Saturday, by the restaurant's clock


def lunch(number: int = 301, **more: Any) -> dict[str, Any]:
    return order(number, [row(*CHICKEN), row(*COMBO)], instructions="Ring the bell twice", **more)


def unanswered(told: dict[str, Any]) -> dict[str, Any]:
    """The same order as GloriaFood hands it over the moment the customer places it: nobody at the
    restaurant has answered it, so it was accepted at no time and, unless the customer named one, is for
    no time yet."""
    for_later = bool(told.get("for_later"))
    return {
        **told,
        "status": "pending",
        "accepted_at": None,
        "fulfill_at": told["fulfill_at"] if for_later else None,
        "updated_at": "2027-01-15T22:59:30.000Z",
    }


def on_the_pos(hub: Hub, number: int) -> bool:
    return hub.client.get(f"/orders/gf-{number}").status_code == 200


def tickets(hub: Hub) -> list[str]:
    return sorted(job_id for job_id in hub.papers() if ":notice:" not in job_id)


def test_an_order_handed_over_before_it_is_accepted_waits_and_alerts_nobody():
    hub = Hub()
    assert hub.accept(unanswered(lunch())) == {**NONE, "came": 1, "kept": 1}
    assert not on_the_pos(hub, 301) and tickets(hub) == [] and hub.slips() == []
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.said) == ("kept", WAITS) and "accepted" in WAITS
    status = hub.status()
    # it is listed, in words that say what it waits for, and is news to nobody
    (look,) = status["look"]
    assert (look["id"], look["state"], look["said"], look["new"]) == ("301", "kept", WAITS, False)
    assert status["news"] == 0 and status["today"] == {**TODAY, "came": 1, "by_poll": 1, "kept": 1}


def test_it_goes_on_the_pos_when_gloriafood_hands_it_over_again_accepted():
    hub = Hub()
    hub.accept(unanswered(lunch()))
    hub.clock += MINUTE
    told = lunch()
    assert hub.accept(told) == {**NONE, "came": 1, "placed": 1}
    got = hub.order(301)
    assert (got["status"], got["fields"]["order_no"], got["fields"]["channel"]) == ("open", 1, "online")
    assert got["fired"] and tickets(hub) == TICKETS
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.order_id, arrival.said) == ("placed", "gf-301", "")
    # the order as it was accepted is the one kept; when it first came, and that it was asked for, stay
    assert arrival.raw == told and (arrival.fetched_ms, arrival.settled_ms, arrival.via) == (NOW, hub.clock, "poll")
    status = hub.status()
    assert status["today"] == {**TODAY, "came": 1, "by_poll": 1, "placed": 1}
    assert (status["look"], status["news"], hub.slips()) == ([], 0, [])
    # handed over a third time it is the same order: one check, one set of tickets
    hub.clock += MINUTE
    assert hub.accept(lunch()) == {**NONE, "came": 1, "known": 1}
    assert len(hub.client.get("/orders").json()["orders"]) == 1 and tickets(hub) == TICKETS


def test_an_order_placed_and_accepted_between_two_askings_goes_on_once():
    hub = Hub()
    assert hub.accept(unanswered(lunch()), lunch()) == {**NONE, "came": 2, "placed": 1}
    assert on_the_pos(hub, 301) and tickets(hub) == TICKETS
    # and the other way round in one answer: the accepted one stands, the one still waiting says nothing new
    assert hub.accept(lunch(302), unanswered(lunch(302))) == {**NONE, "came": 2, "known": 1, "placed": 1}
    assert on_the_pos(hub, 302)
    assert len(hub.client.get("/orders").json()["orders"]) == 2


def test_an_order_handed_over_twice_before_it_is_accepted_is_one_order_waiting():
    hub = Hub()
    hub.accept(unanswered(lunch()))
    hub.clock += MINUTE
    assert hub.accept(unanswered(lunch())) == {**NONE, "came": 1, "known": 1}
    assert hub.inbox.get("gloriafood", "301").settled_ms == NOW and not on_the_pos(hub, 301)


def test_one_that_was_turned_down_or_missed_says_so_and_is_news():
    hub = Hub()
    hub.accept(unanswered(lunch(301)), unanswered(lunch(302)))
    hub.clock += MINUTE
    turned_down = unanswered(lunch(301)) | {"status": "rejected"}
    missed = unanswered(lunch(302)) | {"status": "timed_out", "missed_reason": "TIMED_OUT"}
    assert hub.accept(turned_down, missed) == {**NONE, "came": 2, "kept": 2}
    assert not on_the_pos(hub, 301) and not on_the_pos(hub, 302) and tickets(hub) == [] and hub.slips() == []
    status = hub.status()
    assert {look["id"]: (look["said"], look["new"]) for look in status["look"]} == {
        "301": ("it was rejected in GloriaFood's app", True),
        "302": ("it was missed: nobody answered it in GloriaFood's app in time", True),
    }
    assert status["news"] == 2


def test_an_order_nobody_answered_for_a_quarter_of_an_hour_is_news_once():
    hub = Hub()
    hub.accept(unanswered(lunch()))
    hub.clock += 5 * MINUTE
    hub.client.post("/online/seen", json={"by": "Mike"})  # somebody looked while it was waiting
    hub.clock = NOW + UNANSWERED_MS - 1
    assert hub.status()["news"] == 0
    # an order for now is answered or missed long before this: most likely nothing told the hub
    hub.clock = NOW + UNANSWERED_MS
    status = hub.status()
    (look,) = status["look"]
    assert (look["id"], look["said"], look["new"], status["news"]) == ("301", WAITS, True, 1)
    hub.clock += MINUTE
    hub.client.post("/online/seen", json={"by": "Mike"})
    hub.clock += 30 * MINUTE
    assert hub.status()["news"] == 0  # looked at: it stays listed and is news no longer
    # accepted after all, however late it is said: on the POS (and not sent to the kitchen so long after)
    late = lunch(accepted="2027-01-15T23:00:00.000Z", fulfill="2027-01-15T23:25:00.000Z")
    assert hub.accept(late) == {**NONE, "came": 1, "placed": 1}
    assert on_the_pos(hub, 301) and not hub.order(301)["fired"]


def test_an_order_on_the_pos_is_not_taken_off_by_a_copy_that_says_it_still_waits():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    before = (len(hub.store.for_order("gf-301")), tickets(hub))
    hub.clock += MINUTE
    # the copy from before it was accepted, come late, and the accepted one once more: neither says
    # anything the POS does not say already (what a cancelled one does is in test_after)
    assert hub.accept(unanswered(lunch()), told) == {**NONE, "came": 2, "known": 2}
    assert (len(hub.store.for_order("gf-301")), tickets(hub)) == before and hub.slips() == []
    assert hub.order(301)["status"] == "open" and hub.status()["look"] == []
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.raw) == ("placed", told)


def test_a_push_brings_the_accepted_order_after_the_asking_brought_it_unanswered():
    hub = Hub(push=True)
    hub.accept(unanswered(lunch()))
    answer = hub.push(lunch())
    assert (answer.status_code, answer.json()) == (200, {"received": 1})
    assert on_the_pos(hub, 301) and tickets(hub) == TICKETS
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.via) == ("placed", "poll")  # how it came first
    # and both by push
    assert hub.push(unanswered(lunch(302))).json() == {"received": 1}
    assert not on_the_pos(hub, 302)
    assert hub.push(lunch(302)).json() == {"received": 1}
    assert on_the_pos(hub, 302)


def test_a_table_booked_on_the_website_goes_into_the_book_when_it_is_accepted():
    hub = Hub()
    told = reservation(401, 4, at=SEVEN_TOMORROW)
    assert hub.accept(unanswered(told)) == {**NONE, "came": 1, "kept": 1}
    assert hub.booked(TOMORROW) == []
    status = hub.status()
    assert [(look["id"], look["said"], look["new"]) for look in status["look"]] == [("401", WAITS, False)]
    hub.clock += MINUTE
    assert hub.accept(told) == {**NONE, "came": 1, "booked": 1}
    (booking,) = hub.booked(TOMORROW)
    assert (booking["id"], booking["size"], booking["time"]) == ("gf-401", 4, "19:00")
    assert hub.status()["look"] == []
