"""Online orders through the hub (pos.online.service, pos.api.online): asked for, written down, put on the
POS, numbered and printed as a screen's order is, and what is done with the ones that cannot be."""

from __future__ import annotations

import json
import logging
from decimal import Decimal

from pos.online.gloriafood import FetchFailed
from pos.online.inbox import KEEP_DAYS, MOST_TRIES, Arrival, Inbox
from pos.online.service import ASK_GAP_MS, UNREAD_SLIP_MS

from ..printing.fake_printer import decode
from .hub import MINUTE, NOW, Hub
from .orders import extra, order, row

HOUR = 60 * MINUTE
DAY = 24 * HOUR
CHICKEN = ("Sweet & Sour Chicken", 2)  # wok 1 and the soup station; its ticket is drawn in Chinese
COMBO = ("Maki Combination",)  # the sushi bar
NONE = {"asked": True, "came": 0, "known": 0, "placed": 0, "kept": 0, "failed": 0}
TODAY = {"came": 0, "by_push": 0, "by_poll": 0, "placed": 0, "kept": 0, "failed": 0, "unread": 0}
CUSTOMER = ("Pat", "Example", "555", "Restaurant Row", "3B", "Ring the bell")


def lunch(number: int = 301, **more) -> dict:
    return order(number, [row(*CHICKEN), row(*COMBO)], instructions="Ring the bell twice", **more)


def money(amount: float) -> str:
    return f"{Decimal(str(amount)):.2f}"


def on_the_pos(hub: Hub, number: int) -> bool:
    return hub.client.get(f"/orders/gf-{number}").status_code == 200


def tickets(hub: Hub) -> list[str]:
    return sorted(job_id for job_id in hub.papers() if ":notice:" not in job_id)


# A round ---------------------------------------------------------------------------------------------------


def test_an_accepted_order_is_written_down_put_on_the_pos_numbered_and_printed():
    hub = Hub()
    told = lunch()
    assert hub.accept(told) == {**NONE, "came": 1, "placed": 1}
    assert hub.food.asked == 1
    got = hub.order(301)
    assert (got["status"], got["fields"]["order_no"], got["fields"]["channel"]) == ("open", 1, "online")
    assert got["fields"]["order_type"] == "takeout" and got["fields"]["customer_name"] == "Pat Example"
    assert got["fired"]  # sent to the kitchen by itself
    check = hub.check(301)
    assert (check["total"], check["due"]) == (money(told["total_price"]), money(told["total_price"]))
    # a ticket where each dish is cooked and the whole order where it is packed
    assert tickets(hub) == ["gf-301:fire:front", "gf-301:fire:sushi", "gf-301:fire:wok"]
    assert "NOT PAID" in hub.paper("fire:front") and "PAT EXAMPLE" in hub.paper("fire:front")
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.order_id, arrival.said, arrival.tries) == ("placed", "gf-301", "", 0)
    assert arrival.raw == told and arrival.settled_ms == NOW
    status = hub.status()
    assert status["configured"] and status["source"] == "gloriafood" and status["writable"]
    assert (status["asked_ms"], status["answered_ms"], status["last_failure"]) == (NOW, NOW, None)
    assert status["today"] == {**TODAY, "came": 1, "by_poll": 1, "placed": 1}
    assert (status["waiting"], status["look"]) == (0, [])
    assert hub.slips() == []


def test_the_next_order_takes_the_next_number_and_a_minute_with_no_orders_does_nothing():
    hub = Hub()
    hub.accept(lunch(301))
    hub.clock += MINUTE
    assert hub.accept() == NONE
    hub.clock += MINUTE
    assert hub.accept(lunch(302), lunch(303)) == {**NONE, "came": 2, "placed": 2}
    assert [hub.order(n)["fields"]["order_no"] for n in (301, 302, 303)] == [1, 2, 3]
    assert hub.food.asked == 3


def test_the_customer_s_note_is_on_every_station_s_ticket_the_pack_sheet_and_the_kitchen_s_screen():
    hub = Hub()
    hub.accept(lunch())
    for printer in ("wok", "sushi", "front"):
        paper = hub.paper(f"fire:{printer}")
        assert "CUSTOMER'S NOTE" in paper and "Ring the bell twice" in paper, printer
    screen = hub.client.get("/kitchen/screen", params={"stations": "sushi"}).json()
    assert [ticket["note"] for ticket in screen["tickets"]] == ["Ring the bell twice"]
    printed = hub.client.post("/orders/gf-301/pack-sheet")
    assert printed.status_code == 202, printed.text
    sheet = "\n".join(decode(hub.jobs.get(printed.json()["job_id"]).data).text)
    assert "PACK SHEET" in sheet and "CUSTOMER'S NOTE" in sheet and "Ring the bell twice" in sheet


def test_an_order_with_no_note_prints_no_bar_for_one():
    hub = Hub()
    hub.accept(order(301, [row(*COMBO)]))
    assert "CUSTOMER'S NOTE" not in hub.paper("fire:sushi")
    screen = hub.client.get("/kitchen/screen", params={"stations": "sushi"}).json()
    assert [ticket["note"] for ticket in screen["tickets"]] == [""]


def test_an_order_paid_online_is_a_payment_today_and_its_ticket_says_paid():
    hub = Hub()
    rows = [row(*CHICKEN), extra("delivery_fee", 4.0), extra("tip", 6.0)]
    told = order(301, rows, kind="delivery", payment="ONLINE")
    hub.accept(told)
    check = hub.check(301)
    assert (check["total"], check["paid"], check["due"]) == (money(told["total_price"]), check["total"], "0.00")
    (payment,) = check["payments"]
    assert (payment["method"], payment["note"], payment["by"]) == ("elsewhere", "Paid online", "Online order")
    assert {c["name"]: (c["amount"], c["gratuity"]) for c in check["charges"]} == {
        "Tip": ("6.00", True),
        "Delivery fee": ("4.00", False),
    }
    front = hub.paper("fire:front")
    assert "PAID" in front and "NOT PAID" not in front and "DELIVERY" in front
    assert "Restaurant Row" not in front  # an address is on the bill that goes with the bag, not on a ticket
    bill = hub.client.post("/orders/gf-301/bill")
    assert bill.status_code == 202, bill.text
    words = "\n".join(decode(hub.jobs.get(bill.json()["job_id"]).data).text)
    assert "1 Restaurant Row, Winchester" in words and "Delivery fee" in words and "PAID IN FULL" in words


# One order is one order ------------------------------------------------------------------------------------


def test_an_order_gloriafood_sends_twice_is_one_order():
    hub = Hub()
    hub.accept(lunch())
    before = (len(hub.store.for_order("gf-301")), tickets(hub))
    hub.clock += MINUTE
    assert hub.accept(lunch()) == {**NONE, "came": 1, "known": 1}
    assert (len(hub.store.for_order("gf-301")), tickets(hub)) == before
    assert len(hub.client.get("/orders").json()["orders"]) == 1
    assert hub.status()["today"]["came"] == 1


class Forgetful(Inbox):
    """An inbox that cannot write what became of an order, `fails` times."""

    fails = 1

    def settle(self, arrival: Arrival) -> None:
        if self.fails:
            self.fails -= 1
            raise RuntimeError("the database went away")
        super().settle(arrival)


def test_an_order_on_the_pos_whose_end_could_not_be_written_down_is_not_put_on_it_again():
    hub = Hub(inbox=Forgetful())
    assert hub.accept(lunch())["placed"] == 1
    assert hub.inbox.get("gloriafood", "301").state == "new"  # nothing was written of it
    before = (len(hub.store.for_order("gf-301")), tickets(hub))
    hub.clock += MINUTE
    assert hub.accept() == {**NONE, "placed": 1}  # it is looked at again, found on the POS, and written down
    assert (len(hub.store.for_order("gf-301")), tickets(hub)) == before
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.state, arrival.order_id) == ("placed", "gf-301")
    hub.clock += MINUTE
    assert hub.accept(lunch(302))["placed"] == 1 and hub.order(302)["fields"]["order_no"] == 2


class Full(Inbox):
    """An inbox that cannot take a new order, `fails` times."""

    fails = 1

    def add(self, arrival: Arrival) -> bool:
        if self.fails:
            self.fails -= 1
            raise RuntimeError("the database went away")
        return super().add(arrival)


def test_an_order_that_cannot_be_written_down_is_held_and_written_the_next_minute():
    hub = Hub(inbox=Full())
    assert hub.accept(lunch()) == {**NONE, "came": 1}  # GloriaFood will not send it again: it is not lost
    assert not on_the_pos(hub, 301) and hub.status()["waiting"] == 1
    hub.clock += MINUTE
    assert hub.accept() == {**NONE, "placed": 1}
    assert on_the_pos(hub, 301) and hub.status()["waiting"] == 0


# When GloriaFood is not asked, or does not answer -----------------------------------------------------------


def test_a_hub_with_no_key_asks_nobody():
    hub = Hub(key=False)
    assert hub.online.round() == {**NONE, "asked": False}
    status = hub.status()
    assert (status["configured"], status["source"], status["running"], status["asked_ms"]) == (False, None, False, None)
    refused = hub.client.post("/online/fetch")
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_key"
    hub.online.start()  # and no minute's round is started
    assert not hub.status()["running"]


class Standby(Inbox):
    def writable(self) -> bool:
        return False


def test_a_hub_that_cannot_write_orders_down_does_not_ask_for_them():
    hub = Hub(inbox=Standby())
    assert hub.accept(lunch()) == {**NONE, "asked": False}
    assert hub.food.asked == 0 and len(hub.food.queue) == 1  # GloriaFood still has it, for the hub that can
    assert not hub.status()["writable"]


def test_when_gloriafood_does_not_answer_the_hub_says_why_and_asks_again_the_next_minute():
    hub = Hub()
    hub.food.fail = FetchFailed("GloriaFood did not answer in time")
    assert hub.accept(lunch()) == NONE
    status = hub.status()
    assert status["last_failure"] == {"at_ms": NOW, "reason": "GloriaFood did not answer in time"}
    assert (status["asked_ms"], status["answered_ms"], status["look"]) == (NOW, None, [])
    assert hub.slips() == []
    hub.food.fail = None
    hub.clock += MINUTE
    assert hub.accept() == {**NONE, "came": 1, "placed": 1}
    status = hub.status()
    assert (status["last_failure"], status["answered_ms"]) == (None, NOW + MINUTE)


def test_an_answer_that_cannot_be_read_is_kept_and_a_slip_says_to_look_at_gloriafood_s_app():
    hub = Hub()
    hub.food.fail = FetchFailed("GloriaFood's answer could not be read", '{"orders": "Pat Example, 3B"')
    assert hub.online.round() == NONE
    status = hub.status()
    assert status["last_failure"]["reason"] == "GloriaFood's answer could not be read"
    (look,) = status["look"]
    assert (look["id"], look["kind"], look["state"], look["order_id"]) == (
        f"unread-{NOW}",
        "unreadable",
        "failed",
        None,
    )
    # it is not counted as an order, which it may not be: it is counted as what it is
    assert status["today"] == {**TODAY, "unread": 1} and status["waiting"] == 0
    (slip,) = hub.slips()
    assert "ONLINE ORDERS: LOOK" in slip and "GloriaFood's own app" in slip and "Pat" not in slip
    # what came is kept on the hub, and is not shown to whoever asks
    assert hub.inbox.get("gloriafood", f"unread-{NOW}").raw == {"unreadable": '{"orders": "Pat Example, 3B"'}
    shown = hub.client.get(f"/online/orders/unread-{NOW}")
    assert shown.status_code == 200 and shown.json()["order"] == {"unreadable": "(hidden)"}
    # nonsense every minute is one slip a quarter of an hour, and every answer is kept
    hub.clock += MINUTE
    hub.online.round()
    assert len(hub.slips()) == 1 and hub.status()["today"]["unread"] == 2
    hub.clock += UNREAD_SLIP_MS
    hub.online.round()
    assert len(hub.slips()) == 2


# An order that cannot be put on the POS ----------------------------------------------------------------------


def test_an_order_that_will_not_go_on_is_tried_a_few_times_and_then_a_slip_says_so(caplog):
    hub = Hub()

    def broken(told):
        raise RuntimeError(f"cannot read what {told['client_first_name']} wrote")

    put, hub.online.put = hub.online.put, broken
    with caplog.at_level(logging.ERROR, logger="pos.online"):
        for tries in range(1, MOST_TRIES):
            assert hub.accept(*([lunch()] if tries == 1 else []))["failed"] == 1
            assert hub.inbox.get("gloriafood", "301").tries == tries and hub.slips() == []
            assert hub.status()["waiting"] == 1
            hub.clock += MINUTE
        assert hub.accept() == {**NONE, "failed": 1}
    (slip,) = hub.slips()
    assert "NOT ON THE POS" in slip and "Online order 301" in slip and "Ring it in by hand" in slip
    status = hub.status()
    (look,) = status["look"]
    assert (look["id"], look["state"], look["tries"]) == ("301", "failed", MOST_TRIES)
    assert look["said"] == "it could not be put on the POS (RuntimeError)"
    assert status["waiting"] == 0
    # neither the log nor the slip repeats what the error said: it can quote a customer
    assert "Pat" not in caplog.text and "Pat" not in slip and "301" in caplog.text
    hub.online.put = put
    hub.clock += MINUTE
    assert hub.accept() == NONE and not on_the_pos(hub, 301)  # it is left for a person


def test_an_order_that_goes_on_at_the_second_try_is_one_order_with_one_set_of_tickets():
    hub = Hub()
    put = hub.online.put
    hub.online.put = lambda told: (_ for _ in ()).throw(RuntimeError("the database went away"))
    assert hub.accept(lunch())["failed"] == 1 and not on_the_pos(hub, 301)
    hub.online.put = put
    hub.clock += MINUTE
    assert hub.accept() == {**NONE, "placed": 1}
    assert tickets(hub) == ["gf-301:fire:front", "gf-301:fire:sushi", "gf-301:fire:wok"] and hub.slips() == []
    assert hub.status()["look"] == []


def test_an_order_with_no_dishes_fails_for_good_at_once():
    hub = Hub()
    assert hub.accept(order(301, [extra("tip", 3.0)])) == {**NONE, "came": 1, "failed": 1}
    (slip,) = hub.slips()
    assert "NOT ON THE POS" in slip and "it has no dishes" in slip
    hub.clock += MINUTE
    assert hub.accept() == NONE


def test_what_is_no_order_for_the_pos_is_kept_without_a_slip():
    hub = Hub()
    booked = order(301, [], kind="table_reservation")
    turned_down = lunch(302, status="rejected")
    assert hub.accept(booked, turned_down) == {**NONE, "came": 2, "kept": 2}
    assert not on_the_pos(hub, 301) and not on_the_pos(hub, 302)
    assert hub.inbox.get("gloriafood", "301").said == "it is a table reservation"
    assert hub.inbox.get("gloriafood", "302").said == "it was not accepted (rejected)"
    status = hub.status()
    # a reservation is nothing to look at; an order the POS would take and did not is
    assert [look["id"] for look in status["look"]] == ["302"] and hub.slips() == [] and tickets(hub) == []


# Late, old, and for later ----------------------------------------------------------------------------------


def test_an_order_that_reaches_the_hub_after_its_time_is_on_the_pos_unsent_and_a_slip_says_so():
    hub = Hub()
    hub.clock = NOW + 45 * MINUTE  # the hub was off: it was for 18:25 and it is 18:46
    assert hub.accept(lunch()) == {**NONE, "came": 1, "placed": 1}
    got = hub.order(301)
    assert got["fields"]["order_no"] == 1 and not got["fired"] and tickets(hub) == []
    assert hub.check(301)["total"] == money(lunch()["total_price"])  # the sale is on the POS all the same
    (slip,) = hub.slips()
    assert "NOT SENT TO THE KITCHEN" in slip and "Online order #1 (301)" in slip and "Send it from the order" in slip
    assert "void one of the two" in slip  # somebody may have rung it in by hand while the hub was off
    (look,) = hub.status()["look"]
    assert (look["id"], look["state"], look["order_id"]) == ("301", "placed", "gf-301")
    assert "was not sent to the kitchen" in look["said"]


def test_an_order_from_another_day_is_not_put_on_the_pos_and_a_slip_says_so():
    hub = Hub()
    hub.clock = NOW + 2 * DAY  # the key was put on the hub two days after it was accepted
    assert hub.accept(lunch()) == {**NONE, "came": 1, "kept": 1}
    assert not on_the_pos(hub, 301) and tickets(hub) == []
    (slip,) = hub.slips()
    assert "NOT ON THE POS" in slip and "Online order 301" in slip
    (look,) = hub.status()["look"]
    assert (look["id"], look["kind"], look["state"]) == ("301", "pickup", "kept")


def test_many_orders_from_earlier_days_in_one_round_share_one_slip():
    hub = Hub()
    hub.clock = NOW + 2 * DAY  # the integration was made days before its key was put on the hub
    assert hub.accept(*(lunch(n) for n in range(301, 306))) == {**NONE, "came": 5, "kept": 5}
    (slip,) = hub.slips()
    assert "NOT ON THE POS" in slip and "5 online orders from earlier days" in slip and "hubctl online status" in slip
    assert len(hub.status()["look"]) == 5  # each is named where a person looks them up
    hub.clock += MINUTE
    hub.accept(*(lunch(n, accepted="2027-01-17T23:00:00.000Z", fulfill="2027-01-17T23:25:00.000Z") for n in (306, 307)))
    assert len(tickets(hub)) == 6 and len(hub.slips()) == 1  # and today's orders go to the kitchen as ever


def test_an_order_for_later_prints_when_its_time_comes():
    hub = Hub()
    later = lunch(for_later=True, fulfill="2027-01-16T01:30:00.000Z")  # accepted at 18:00 for 20:30
    assert hub.accept(later)["placed"] == 1
    got = hub.order(301)
    assert got["fired"] and got["fields"]["for_later"] is True and got["fields"]["quoted_minutes"] == 25
    assert tickets(hub) == []
    (held,) = hub.client.get("/print/jobs").json()["held"]
    assert held["order_id"] == "gf-301" and held["starts_ms"] == got["fields"]["promised_at"] - 25 * MINUTE
    hub.clock = held["starts_ms"] - 5 * MINUTE
    assert hub.printing.release_due() == []
    hub.clock = held["starts_ms"]
    hub.printing.release_due()
    assert len(tickets(hub)) == 3 and "Ring the bell twice" in "\n".join(sum(hub.papers().values(), []))


# The numbers left ------------------------------------------------------------------------------------------


def test_a_dish_with_a_number_left_is_counted_down_and_an_order_is_never_refused_for_it():
    hub = Hub()
    left = hub.client.post("/menu/86", json={"target_id": "L01:regular", "status": "available", "remaining": 3})
    assert left.status_code == 200, left.text
    hub.accept(order(301, [row(*CHICKEN)]))
    (dish,) = hub.client.get("/menu/86").json()["items"]
    assert (dish["left"], dish["status"]) == (1, "available")
    hub.clock += MINUTE
    assert hub.accept(order(302, [row(*CHICKEN)]))["placed"] == 1  # two sold online with one left: it was sold
    (dish,) = hub.client.get("/menu/86").json()["items"]
    assert (dish["left"], dish["status"]) == (0, "sold_out")
    assert hub.inbox.get("gloriafood", "302").said == "" and len(hub.order(302)["lines"]) == 1


# What a person is shown ------------------------------------------------------------------------------------


def test_the_status_and_the_copy_of_an_order_name_no_customer():
    hub = Hub()
    hub.clock = NOW + 45 * MINUTE
    told = order(
        301, [row(*CHICKEN, instructions="Ring the bell at 3B")], kind="delivery", instructions="Ring the bell twice"
    )
    hub.accept(told, order(302, [extra("tip", 1.0)]))
    status = hub.status()
    assert len(status["look"]) == 2
    shown = hub.client.get("/online/orders/301").json()
    assert shown["id"] == "301" and shown["order"]["items"][0]["type_id"] == told["items"][0]["type_id"]
    assert shown["order"]["total_price"] == told["total_price"]
    for text in (json.dumps(status), json.dumps(shown), *hub.slips()):
        assert not [piece for piece in CUSTOMER if piece in text], text
    unknown = hub.client.get("/online/orders/999")
    assert unknown.status_code == 404 and unknown.json()["detail"]["error"] == "unknown_order"


def test_an_order_as_it_came_is_dropped_after_a_month_and_what_became_of_it_stays():
    hub = Hub()
    hub.accept(lunch())
    hub.clock += KEEP_DAYS * DAY - HOUR
    hub.online.round()
    assert hub.client.get("/online/orders/301").status_code == 200
    hub.clock += 2 * HOUR
    hub.online.round()
    gone = hub.client.get("/online/orders/301")
    assert gone.status_code == 410 and gone.json()["detail"]["error"] == "forgotten"
    arrival = hub.inbox.get("gloriafood", "301")
    assert (arrival.raw, arrival.state, arrival.order_id) == (None, "placed", "gf-301")
    assert on_the_pos(hub, 301)  # the order on the POS is the POS's own and stays


def test_asking_now_does_a_round_and_says_what_it_did():
    hub = Hub()
    hub.food.queue.append(lunch())
    answer = hub.client.post("/online/fetch")
    assert answer.status_code == 200, answer.text
    done = answer.json()
    assert {name: done[name] for name in NONE} == {**NONE, "came": 1, "placed": 1}
    assert done["status"]["today"]["placed"] == 1 and on_the_pos(hub, 301)


def ask_now(hub: Hub) -> dict:
    """Somebody pressed "Ask now" on a screen (or ran `hubctl online fetch`)."""
    answer = hub.client.post("/online/fetch")
    assert answer.status_code == 200, answer.text
    return answer.json()


def test_asking_now_says_whether_gloriafood_answered_and_why_it_did_not():
    hub = Hub()
    done = ask_now(hub)
    assert (done["asked"], done["answered"], done["soon"], done["reason"]) == (True, True, False, None)
    hub.clock += MINUTE
    hub.food.fail = FetchFailed("GloriaFood did not answer in time")
    hub.food.queue.append(lunch())
    done = ask_now(hub)
    assert {name: done[name] for name in NONE} == NONE
    assert (done["answered"], done["soon"], done["reason"]) == (False, False, "GloriaFood did not answer in time")
    assert done["status"]["last_failure"]["reason"] == done["reason"]
    hub.food.fail = None
    hub.clock += MINUTE
    done = ask_now(hub)
    assert (done["answered"], done["reason"], done["came"], done["placed"]) == (True, None, 1, 1)


def test_somebody_leaning_on_the_button_does_not_ask_gloriafood_again_and_again():
    hub = Hub()
    assert ask_now(hub)["asked"] and hub.food.asked == 1
    hub.food.queue.append(lunch())
    hub.clock += ASK_GAP_MS - 1
    again = ask_now(hub)  # too soon after the last asking: GloriaFood is left alone, and the answer says so
    assert {name: again[name] for name in NONE} == {**NONE, "asked": False}
    assert (again["soon"], again["answered"], again["reason"]) == (True, False, None)
    assert hub.food.asked == 1 and not on_the_pos(hub, 301)
    assert again["status"]["asked_ms"] == NOW  # when it was asked is not moved by a press that asked nobody
    hub.clock += 1
    then = ask_now(hub)
    assert (then["asked"], then["soon"], then["came"], then["placed"]) == (True, False, 1, 1)
    assert hub.food.asked == 2 and on_the_pos(hub, 301)
    # the minute's own round is never held back: it asks whenever its minute comes
    hub.clock += 1_000
    assert hub.online.round() == NONE and hub.food.asked == 3
    # and a press soon after the minute's round waits its turn like any other
    hub.clock += 1_000
    assert ask_now(hub)["soon"] and hub.food.asked == 3


def test_asking_now_on_a_hub_that_cannot_write_asks_nobody_and_is_not_too_soon():
    hub = Hub(inbox=Standby())
    done = ask_now(hub)
    assert (done["asked"], done["soon"], done["answered"], done["reason"]) == (False, False, False, None)
    assert hub.food.asked == 0


# Only the hub says where an order came from ----------------------------------------------------------------


def op(hub: Hub, order_id: str, kind: str, n: int, **data) -> None:
    body = {
        "op_id": f"{order_id}-{n}",
        "order_id": order_id,
        "hlc": f"{hub.clock + n:015d}-0000-t1",
        "device": "t1",
        "kind": kind,
        "data": data,
    }
    sent = hub.client.post(f"/orders/{order_id}/ops", json=[body])
    assert sent.status_code == 202 and sent.json()["refused"] == [], sent.text


def test_a_screen_cannot_say_an_order_came_from_the_website():
    hub = Hub()
    forged = {"source": "gloriafood", "id": "1", "type": "pickup", "payment": "ONLINE", "total": "0.00"}
    op(hub, "w1", "create", 1, order_type="takeout", customer_name="Lee", channel="phone", online=forged)
    op(hub, "w1", "set_field", 2, online=forged, note="extra napkins")
    fields = hub.client.get("/orders/w1").json()["fields"]
    assert "online" not in fields and fields["note"] == "extra napkins" and fields["customer_name"] == "Lee"
    hub.accept(lunch())
    op(hub, "gf-301", "set_field", 3, online=None, note="knock")
    fields = hub.order(301)["fields"]
    assert fields["online"]["id"] == "301" and fields["note"] == "knock"  # nor take the mark off one that did


# The reports ----------------------------------------------------------------------------------------------


def test_the_reports_count_an_online_order_as_the_sale_it_is():
    hub = Hub()
    rows = [row(*CHICKEN), row(*COMBO), row("Orange Juice"), extra("delivery_fee", 4.0), extra("tip", 6.0)]
    told = order(301, rows, kind="delivery", payment="ONLINE")
    hub.accept(told)
    # a dish the POS's menu does not have goes on as GloriaFood named it, and is counted like the others
    assert hub.inbox.get("gloriafood", "301").said == "1 dish went on as written (Orange Juice)"
    food = sum(Decimal(str(r["total_item_price"])) for r in rows[:3])
    manager = hub.manager()
    sales = hub.client.get("/reports/sales", headers=manager).json()["span"]
    assert (sales["checks"], sales["sales"]["gross"], sales["sales"]["total"]) == (
        1,
        f"{food:.2f}",
        money(told["total_price"]),
    )
    assert (sales["sales"]["charges"], sales["sales"]["gratuity"]) == ("4.00", "6.00")
    day = hub.client.get("/reports/day", headers=manager).json()
    assert day["sales"] == sales["sales"]
    # what the website took has its own row in the day's money, and the Sales say the same
    assert day["money"]["taken"] == [{"method": "online", "count": 1, "amount": money(told["total_price"])}]
    assert sales["money"]["taken"] == day["money"]["taken"]
    assert (day["money"]["due"], [who["name"] for who in day["staff"]]) == ("0.00", ["Online order"])
    dishes = hub.client.get("/reports/dishes", headers=manager).json()
    assert {(d["item"], d["name"], d["count"]) for d in dishes["dishes"] if d["count"]} == {
        ("L01", "Sweet & Sour Chicken", 2),
        ("J55", "Maki Combination", 1),
        (None, "Orange Juice", 1),
    }
    for path in ("/reports/today", "/reports/guests", "/orders/gf-301/history", "/deliveries/runs"):
        assert hub.client.get(path, headers=manager).status_code == 200, path
    assert hub.client.get("/orders", params={"brief": True}).json()["orders"][0]["order_id"] == "gf-301"
    steps = hub.client.get("/orders/gf-301/history", headers=manager).json()["steps"]
    assert steps[0]["what"] == "opened" and steps[0]["device"] == "online"
