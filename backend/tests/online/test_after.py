"""What GloriaFood says of an order after it is on the POS (pos.online.after, pos.online.service).

With "Send every time an order is updated" its integration hands an order over again whenever something of
it changes: it was marked ready in GloriaFood's app, or it was cancelled. An order that is on the POS takes
that: ready is ready on the POS, and a cancelled one is voided and the kitchen told. What GloriaFood says of
an order that never went on the POS is listed in plain words."""

from __future__ import annotations

from typing import Any

import pytest

from pos.online.after import CANCELLED, REASON
from pos.online.place import BY

from .hub import MINUTE, Hub
from .orders import order, reservation, row

CHICKEN = ("Sweet & Sour Chicken", 2)
COMBO = ("Maki Combination",)
NONE = {"asked": True, "came": 0, "known": 0, "placed": 0, "booked": 0, "kept": 0, "failed": 0}
AGAIN = {**NONE, "came": 1, "known": 1}
"""What a round says of one order that was here already, whatever it brings of it."""
TICKETS = ["gf-301:fire:front", "gf-301:fire:sushi", "gf-301:fire:wok"]
LATER = "2027-01-15T23:06:00.000Z"
TOMORROW = "2027-01-16"
SEVEN_TOMORROW = "2027-01-17T00:00:00.000Z"  # 19:00 on Saturday, by the restaurant's clock


def lunch(number: int = 301, **more: Any) -> dict[str, Any]:
    return order(number, [row(*CHICKEN), row(*COMBO)], **more)


def ready(told: dict[str, Any]) -> dict[str, Any]:
    """The same order as GloriaFood hands it over again once it was marked ready in its app."""
    return {**told, "ready": True, "updated_at": LATER}


def cancelled(told: dict[str, Any]) -> dict[str, Any]:
    """The same order as GloriaFood hands it over again once it was cancelled."""
    return {**told, "status": "canceled", "updated_at": LATER}


def tickets(hub: Hub) -> list[str]:
    return sorted(job_id for job_id in hub.papers() if ":notice:" not in job_id)


def ops(hub: Hub, number: int = 301) -> int:
    return len(hub.store.for_order(f"gf-{number}"))


def write(hub: Hub, number: int, *made: tuple[str, dict[str, Any]]) -> None:
    """A screen writes these operations on the order, as a person at the counter would."""
    order_id = f"gf-{number}"
    body = [
        {
            "op_id": f"{order_id}:screen-{hub.clock}-{n}",
            "order_id": order_id,
            "hlc": f"{hub.clock}-{n}-t1",
            "device": "t1",
            "kind": kind,
            "data": data,
        }
        for n, (kind, data) in enumerate(made)
    ]
    answer = hub.client.post(f"/orders/{order_id}/ops", json=body)
    assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text


# --- ready -------------------------------------------------------------------------------------


def test_an_order_marked_ready_in_gloriafoods_app_is_ready_on_the_pos():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    assert hub.order(301)["fields"]["stage"] == "new" and tickets(hub) == TICKETS
    hub.clock += 5 * MINUTE
    assert hub.accept(ready(told)) == AGAIN
    got = hub.order(301)
    assert (got["status"], got["fields"]["stage"]) == ("open", "ready")
    # nothing prints for it and nobody has to look at anything: the list of checks says Ready
    assert tickets(hub) == TICKETS and hub.slips() == []
    status = hub.status()
    assert (status["look"], status["news"]) == ([], 0)
    # GloriaFood tells its customer itself: the POS sends no text of its own on top
    assert hub.client.get("/messages").json()["messages"] == []
    # the order as it came last is the one kept, for whoever looks at what GloriaFood sent
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.raw, arrival.said) == ("placed", ready(told), "")
    # and it is said once
    before = ops(hub)
    assert hub.accept(ready(told)) == AGAIN
    assert ops(hub) == before


def test_ready_never_takes_an_order_back_from_where_it_already_is():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    write(hub, 301, ("set_field", {"stage": "picked_up"}))
    hub.clock += MINUTE
    before = ops(hub)
    assert hub.accept(ready(told)) == AGAIN
    assert hub.order(301)["fields"]["stage"] == "picked_up" and ops(hub) == before
    # one that is ready stays ready when a later copy does not say so
    hub.accept(lunch(302))
    hub.accept(ready(lunch(302)))
    hub.clock += MINUTE
    hub.accept({**lunch(302), "ready": False, "updated_at": "2027-01-15T23:08:00.000Z"})
    assert hub.order(302)["fields"]["stage"] == "ready"


def test_an_order_that_comes_already_made_is_on_the_pos_ready_and_is_not_sent_to_the_kitchen():
    # the hub was off while the order was accepted and made from GloriaFood's own app
    hub = Hub()
    assert hub.accept(ready(lunch())) == {**NONE, "came": 1, "placed": 1}
    got = hub.order(301)
    assert (got["status"], got["fields"]["stage"], got["fired"]) == ("open", "ready", {})
    assert tickets(hub) == []
    (slip,) = hub.slips()
    assert "NOT SENT TO THE KITCHEN" in slip and "already marked ready in GloriaFood's app" in slip
    assert hub.client.get("/messages").json()["messages"] == []  # GloriaFood told its customer itself
    # accepted and marked ready between two askings: the same
    assert hub.accept(lunch(302), ready(lunch(302))) == {**NONE, "came": 2, "placed": 1}
    assert (hub.order(302)["fields"]["stage"], hub.order(302)["fired"]) == ("ready", {})


# --- cancelled ---------------------------------------------------------------------------------


def test_an_order_cancelled_in_gloriafood_is_voided_on_the_pos_and_the_kitchen_is_told():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    hub.clock += 5 * MINUTE
    assert hub.accept(cancelled(told)) == AGAIN
    got = hub.order(301)
    assert got["status"] == "void" and got["fields"]["online"]["status"] == "canceled"
    # every dish is a void with its reason, like one a manager voided: it is in the report of voids
    assert [line["status"] for line in got["lines"].values()] == ["void", "void"]
    for line in got["lines"].values():
        said = line["voided"]
        assert (said["reason"], said["reason_name"], said["by"]) == (REASON, CANCELLED, BY)
    # the stations that had its dishes get a VOID ticket each
    voids = [job_id for job_id in tickets(hub) if job_id not in TICKETS]
    assert len(voids) == 3 and all("VOID" in " ".join(hub.papers()[job_id]) for job_id in voids)
    # where the bags are packed a slip says so in words
    (slip,) = hub.slips()
    assert "ONLINE ORDER CANCELLED" in slip and "Online order #1 (301)" in slip and "voided" in slip
    assert "Pat" not in slip
    # and it is listed for a manager, as news
    status = hub.status()
    (look,) = status["look"]
    assert (look["id"], look["state"], look["order_id"], look["new"]) == ("301", "placed", "gf-301", True)
    assert look["said"] == "it was cancelled in GloriaFood: the POS voided it"
    assert status["news"] == 1 and status["today"]["placed"] == 1
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.raw, arrival.settled_ms) == (cancelled(told), hub.clock)
    # said again, it is nothing new: no second void, ticket or slip
    before = (ops(hub), tickets(hub), hub.slips())
    hub.clock += MINUTE
    assert hub.accept(cancelled(told)) == AGAIN
    assert (ops(hub), tickets(hub), hub.slips()) == before
    assert hub.inbox.get("gloriafood", "301").settled_ms == hub.clock - MINUTE


def test_a_cancelled_order_is_out_of_the_days_sales():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    hub.clock += MINUTE
    hub.accept(cancelled(told))
    day = hub.client.get("/reports/day", headers=hub.manager()).json()
    assert (day["checks"], day["sales"]["net"]) == (0, "0.00")
    assert (day["voided_checks"]["count"], day["voids"]["count"]) == (1, 2)


def test_a_cancelled_order_the_website_took_money_for_says_the_pos_gives_none_back():
    hub = Hub()
    told = lunch(payment="ONLINE")
    hub.accept(told)
    total = hub.check(301)["total"]
    hub.clock += MINUTE
    hub.accept(cancelled(told))
    assert hub.order(301)["status"] == "void"
    (look,) = hub.status()["look"]
    assert look["said"] == (
        f"it was cancelled in GloriaFood: the POS voided it; the website took ${total} for it, "
        "which the POS does not give back"
    )
    # the payment stays where it was written: the day's report has it under money taken on voided checks
    money = hub.client.get("/reports/day", headers=hub.manager()).json()["money"]
    assert (money["taken_total"], money["on_voided"]) == (total, total)


def test_a_cancelled_order_the_kitchen_never_had_is_voided_with_no_ticket_for_the_kitchen():
    hub = Hub()
    # for half past eight: its tickets wait for their time
    later = lunch(for_later=True, fulfill="2027-01-16T01:30:00.000Z")
    hub.accept(later)
    (held,) = hub.client.get("/print/jobs").json()["held"]
    hub.clock += MINUTE
    hub.accept(cancelled(later))
    assert hub.order(301)["status"] == "void" and hub.client.get("/print/jobs").json()["held"] == []
    hub.clock = held["starts_ms"] + MINUTE
    hub.printing.release_due()
    assert tickets(hub) == [] and len(hub.slips()) == 1
    # one that came after its time was never sent: its dishes stay on the voided check, as on any check
    # voided whole, and what it was worth is with the voided checks
    hub = Hub()
    hub.clock += 45 * MINUTE
    told = lunch(302)
    hub.accept(told)
    assert hub.order(302)["fired"] == {} and len(hub.slips()) == 1
    hub.clock += MINUTE
    hub.accept(cancelled(told))
    got = hub.order(302)
    assert got["status"] == "void" and [line["status"] for line in got["lines"].values()] == ["active", "active"]
    assert tickets(hub) == [] and len(hub.slips()) == 2
    day = hub.client.get("/reports/day", headers=hub.manager()).json()
    assert (day["voided_checks"]["count"], day["voids"]["count"]) == (1, 0)
    assert day["voided_checks"]["amount"] == hub.check(302)["subtotal"] != "0.00"


def test_a_dish_with_a_number_left_goes_back_on_its_number_when_the_order_is_cancelled():
    hub = Hub()
    left = hub.client.post("/menu/86", json={"target_id": "L01:regular", "status": "available", "remaining": 3})
    assert left.status_code == 200, left.text
    told = lunch()
    hub.accept(told)
    (dish,) = hub.client.get("/menu/86").json()["items"]
    assert dish["left"] == 1
    hub.clock += MINUTE
    hub.accept(cancelled(told))
    (dish,) = hub.client.get("/menu/86").json()["items"]
    assert (dish["left"], dish["status"]) == (3, "available")


def test_a_cancelled_order_somebody_voided_already_is_marked_and_nothing_more_is_said():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    write(hub, 301, ("void_order", {"reason": "The customer rang"}))
    hub.clock += MINUTE
    before = (tickets(hub), hub.slips())
    assert hub.accept(cancelled(told)) == AGAIN
    got = hub.order(301)
    assert got["status"] == "void" and got["fields"]["online"]["status"] == "canceled"
    assert (tickets(hub), hub.slips()) == before
    status = hub.status()
    assert (status["look"], status["news"]) == ([], 0)


@pytest.mark.parametrize(
    ("done", "why"),
    [
        ((("pay", {"payment_id": "p1", "method": "cash", "amount": "5.00"}),), "money was taken for it at the POS"),
        ((("set_field", {"stage": "picked_up"}), ("close", {})), "it was picked up"),
        ((("set_field", {"stage": "out"}),), "it has left with a driver"),
    ],
)
def test_a_cancelled_order_that_was_paid_at_the_pos_or_handed_over_is_flagged_and_not_voided(done, why):
    hub = Hub()
    told = lunch()
    hub.accept(told)
    write(hub, 301, *done)
    was = hub.order(301)["status"]
    hub.clock += MINUTE
    assert hub.accept(cancelled(told)) == AGAIN
    got = hub.order(301)
    assert got["status"] == was and got["fields"]["online"]["status"] == "canceled"
    assert [line["status"] for line in got["lines"].values()] == ["active", "active"]
    assert tickets(hub) == TICKETS
    (look,) = hub.status()["look"]
    assert look["said"] == f"it was cancelled in GloriaFood, and {why}: it is still on the POS" and look["new"]
    (slip,) = hub.slips()
    assert "ONLINE ORDER CANCELLED" in slip and "still on the POS" in slip and "manager" in slip


def test_a_cancellation_gloriafood_sends_by_itself_voids_the_order_too():
    hub = Hub(push=True)
    told = lunch()
    assert hub.push(told).json() == {"received": 1}
    hub.clock += MINUTE
    assert hub.push(cancelled(told)).json() == {"received": 1}
    assert hub.order(301)["status"] == "void"
    assert hub.status()["news"] == 1


def test_an_order_cancelled_before_it_went_on_the_pos_never_goes_on():
    hub = Hub()
    told = lunch()
    # accepted and cancelled between two askings
    assert hub.accept(told, cancelled(told)) == {**NONE, "came": 2, "kept": 1}
    assert hub.client.get("/orders/gf-301").status_code == 404 and tickets(hub) == [] and hub.slips() == []
    (look,) = hub.status()["look"]
    assert (look["state"], look["said"], look["new"]) == ("kept", "it was cancelled in GloriaFood", True)
    # an older copy that comes after says nothing against a newer one: it stays off
    hub.clock += MINUTE
    assert hub.accept(told) == AGAIN
    assert hub.client.get("/orders/gf-301").status_code == 404


def test_what_gloriafood_says_of_an_order_it_never_gave_to_be_made_is_in_plain_words():
    hub = Hub()
    waiting = {"status": "pending", "accepted_at": None, "fulfill_at": None}
    hub.accept(*(lunch(number) | waiting for number in (301, 302, 303)))
    hub.clock += MINUTE
    hub.accept(
        lunch(301) | waiting | {"status": "rejected"},
        lunch(302) | waiting | {"status": "timed_out", "missed_reason": "TIMED_OUT"},
        lunch(303) | waiting | {"status": "timed_out", "missed_reason": "NO_CONNECTION"},
    )
    assert {look["id"]: look["said"] for look in hub.status()["look"]} == {
        "301": "it was rejected in GloriaFood's app",
        "302": "it was missed: nobody answered it in GloriaFood's app in time",
        "303": "it was missed: GloriaFood could not reach its app at the restaurant",
    }
    assert hub.status()["news"] == 3 and hub.client.get("/orders").json()["orders"] == []


def test_a_word_of_gloriafoods_the_pos_does_not_know_changes_nothing_on_an_order_that_is_on_it(caplog):
    hub = Hub()
    told = lunch()
    hub.accept(told)
    hub.clock += MINUTE
    before = (ops(hub), tickets(hub))
    # whatever it means: no order is voided, and none made ready, on a word nobody here has read
    odd = {**told, "status": "Completed!", "ready": True, "updated_at": LATER}
    with caplog.at_level("WARNING", logger="pos.online"):
        assert hub.accept(odd) == AGAIN
    got = hub.order(301)
    assert (got["status"], got["fields"]["stage"], "status" in got["fields"]["online"]) == ("open", "new", False)
    assert (ops(hub), tickets(hub)) == before and hub.slips() == []
    status = hub.status()
    assert (status["look"], status["news"]) == ([], 0)
    # the word is named in the hub's log, with nothing of the customer, and the copy is kept to be read
    (said,) = [record.getMessage() for record in caplog.records if "does not know" in record.getMessage()]
    assert "301" in said and "'completed'" in said and "Pat" not in said
    assert hub.inbox.get("gloriafood", "301").raw == odd
    # a table in the book stays in it too
    table = reservation(401, 4, at=SEVEN_TOMORROW)
    hub.accept(table)
    hub.accept({**table, "status": "no_show", "updated_at": LATER})
    assert [booking["id"] for booking in hub.booked(TOMORROW)] == ["gf-401"] and hub.status()["look"] == []


def test_the_order_as_it_came_last_is_the_one_kept_and_an_older_copy_never_replaces_it():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    hub.clock += MINUTE
    # something else of it changed in GloriaFood: nothing the POS takes, and it is kept to be read
    later = {**told, "instructions": "No onions", "updated_at": LATER}
    assert hub.accept(later) == AGAIN
    assert hub.inbox.get("gloriafood", "301").raw == later and hub.order(301)["status"] == "open"
    # the copy from before that, come late
    assert hub.accept(told) == AGAIN
    assert hub.inbox.get("gloriafood", "301").raw == later
    # a copy that says it was accepted, on its way while the order was cancelled, undoes nothing
    hub.accept({**cancelled(told), "updated_at": "2027-01-15T23:09:00.000Z"})
    assert hub.order(301)["status"] == "void"
    before = ops(hub)
    hub.accept(ready(told))
    assert hub.order(301)["status"] == "void" and ops(hub) == before
    assert hub.inbox.get("gloriafood", "301").raw["status"] == "canceled"


# --- a table booked on the website -----------------------------------------------------------------


def test_a_table_cancelled_on_the_website_is_cancelled_in_the_book():
    hub = Hub()
    told = reservation(401, 4, at=SEVEN_TOMORROW)
    assert hub.accept(told) == {**NONE, "came": 1, "booked": 1}
    assert [booking["id"] for booking in hub.booked(TOMORROW)] == ["gf-401"]
    hub.clock += MINUTE
    assert hub.accept(cancelled(told)) == AGAIN
    assert hub.booked(TOMORROW) == []
    booking = hub.book.store.get("gf-401")
    assert (booking.status, booking.ended_by) == ("cancelled", "the website")
    (look,) = hub.status()["look"]
    assert (look["state"], look["said"], look["new"]) == (
        "booked",
        "it was cancelled in GloriaFood: it is out of the book",
        True,
    )
    assert hub.slips() == []
    # said again, it is nothing new
    hub.clock += MINUTE
    assert hub.accept(cancelled(told)) == AGAIN
    assert hub.inbox.get("gloriafood", "401").settled_ms == hub.clock - MINUTE


def test_a_table_cancelled_on_the_website_after_the_party_sat_down_is_only_flagged():
    hub = Hub()
    told = reservation(401, 4)  # for this evening
    hub.accept(told)
    hub.book.seat("gf-401", "t1", by="Holly")
    hub.clock += MINUTE
    assert hub.accept(cancelled(told)) == AGAIN
    assert hub.book.store.get("gf-401").status == "seated"
    (look,) = hub.status()["look"]
    assert look["said"] == "it was cancelled in GloriaFood, and the party has a table already: it stays in the book"


# --- when it cannot be done now ----------------------------------------------------------------------


def test_what_cannot_be_told_to_the_pos_while_the_hub_cannot_write_is_kept_and_told_later():
    hub = Hub()
    told = lunch()
    hub.accept(told)
    tell, writable = hub.online.change, hub.inbox.writable
    tries: list[int] = []

    def refuse(*given: Any) -> Any:
        # between being asked and writing, the database turned read-only
        tries.append(1)
        hub.inbox.writable = lambda: False
        raise RuntimeError("read-only")

    hub.online.change = refuse
    hub.clock += MINUTE
    hub.accept(cancelled(told))
    assert tries == [1] and hub.order(301)["status"] == "open"
    hub.online.change, hub.inbox.writable = tell, writable
    hub.clock += MINUTE
    assert hub.accept() == NONE
    assert hub.order(301)["status"] == "void"


def test_one_that_goes_wrong_for_another_reason_is_dropped_and_stops_nothing():
    hub = Hub()
    told = lunch()
    hub.accept(told)

    def broken(*given: Any) -> Any:
        raise ValueError("a customer's words must never reach the log")

    hub.online.change = broken
    hub.clock += MINUTE
    assert hub.accept(cancelled(told), lunch(302)) == {**NONE, "came": 2, "known": 1, "placed": 1}
    assert hub.order(301)["status"] == "open" and hub.status()["waiting"] == 0
