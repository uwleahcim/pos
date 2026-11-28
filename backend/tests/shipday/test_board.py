"""Shipday's deliveries and drivers as the hub keeps them (`pos.shipday.board`): what a round asks and
keeps, what becomes of an order that leaves the list, how far away a delivery is, and how the hub behaves
when Shipday does not answer, refuses the key or says it is asked too often."""

from __future__ import annotations

import logging

import httpx

from pos.shipday.board import (
    ASK_GAP_MS,
    DRIVERS_EVERY_MS,
    ETA_EVERY_MS,
    ETA_MISS_MS,
    ETA_MOST,
    ETA_PLAN_MS,
    FAST_SECONDS,
    IDLE_AFTER_MS,
    IDLE_SECONDS,
    SLOW_SECONDS,
    WATCHED_MS,
    ShipdayBoard,
)
from pos.shipday.match import OnPos

from .fake import ELM, KEY, OAK, TOM, WEI, FakeShipday, at, carrier, minutes_away, order

MINUTE = 60_000
SECOND = 1000


class Bench:
    """A board, the Shipday it asks, a clock moved by hand, and how often the screens were told."""

    def __init__(self) -> None:
        self.now = at(18)
        self.shipday = FakeShipday()
        self.board = ShipdayBoard(self.shipday.source(), now=lambda: self.now)
        self.told = 0
        self.board.on_change = self._tell

    def _tell(self) -> None:
        self.told += 1

    def round(self, after: int = 0, **how) -> dict:
        self.now += after
        return self.board.round(**how)

    def orders(self) -> dict[int, dict]:
        return {each["id"]: each for each in self.board.said()["orders"]}

    def done(self) -> dict[int, dict]:
        return {each["id"]: each for each in self.board.said()["done"]}


def test_a_round_keeps_the_active_orders_and_the_drivers_with_what_each_has():
    b = Bench()
    b.shipday.orders = [
        order(1, "A-1"),
        order(2, "A-2", state="PICKED_UP", driver=TOM, name="Raj Patel", address=OAK, phone="+17815550102"),
        order(3, "A-3", state="NOT_STARTED_YET", driver=TOM, phone="+17815550103"),
    ]
    b.shipday.carriers = [carrier(TOM), carrier(WEI, on_shift=False)]
    assert b.board.said() == {
        "on": True,
        "read": False,
        "trouble": None,
        "eta": "off",
        "can": ["driver", "status", "ready"],
        "orders": [],
        "done": [],
        "drivers": [],
    }
    assert b.round() == {"asked": True, "answered": True, "reason": None, "said": ""}
    said = b.board.said()
    assert said["read"] is True and said["trouble"] is None
    assert [(o["id"], o["state"], o["driver"] and o["driver"]["name"]) for o in said["orders"]] == [
        (1, "NOT_ASSIGNED", None),
        (2, "PICKED_UP", "Tom Reyes"),
        (3, "NOT_STARTED_YET", "Tom Reyes"),
    ]
    assert said["drivers"] == [
        {**TOM, "on_shift": True, "active": True, "orders": 2},
        {**WEI, "on_shift": False, "active": True, "orders": 0},
    ]
    assert all(o["pos"] is None for o in said["orders"]), "no POS to match against"
    assert b.told == 1


def test_the_screens_are_told_only_when_the_picture_is_another_one():
    b = Bench()
    b.shipday.orders = [order(1, "A-1")]
    b.round()
    b.round(20 * SECOND)
    b.round(20 * SECOND)
    assert b.told == 1, "the same answer three times is one piece of news"
    b.shipday.orders = [order(1, "A-1", state="NOT_ACCEPTED", driver=TOM, assigned=at(18, 1))]
    b.round(20 * SECOND)
    assert b.told == 2
    unchanged = b.board.said()
    b.round(20 * SECOND)
    assert b.board.said() == unchanged, "nothing in the answer moves with the clock"


def test_the_drivers_are_asked_for_once_a_minute_and_at_once_when_a_person_asks():
    b = Bench()
    b.round()
    b.round(20 * SECOND)
    b.round(20 * SECOND)
    assert (b.shipday.asked("/orders"), b.shipday.asked("/carriers")) == (3, 1)
    b.round(DRIVERS_EVERY_MS - 40 * SECOND)
    assert b.shipday.asked("/carriers") == 2
    b.round(SECOND, forced=True)
    assert b.shipday.asked("/carriers") == 3


def test_a_driver_an_order_names_only_by_id_is_named_from_the_list_of_drivers():
    b = Bench()
    raw = order(1, "A-1", state="NOT_ACCEPTED")
    raw["assignedCarrierId"] = WEI["id"]
    b.shipday.orders, b.shipday.carriers = [raw], [carrier(TOM), carrier(WEI)]
    b.round()
    assert b.orders()[1]["driver"] == WEI
    assert [d["orders"] for d in b.board.said()["drivers"]] == [0, 1]


def test_an_order_that_leaves_the_list_is_asked_for_once_and_kept_with_what_became_of_it():
    b = Bench()
    b.shipday.orders = [order(1, "A-1", state="PICKED_UP", driver=TOM), order(2, "A-2")]
    b.round()
    b.shipday.orders = [order(2, "A-2")]
    b.shipday.finished["A-1"] = order(1, "A-1", state="ALREADY_DELIVERED", driver=TOM, delivered=at(18, 31))
    b.round(20 * SECOND)
    assert list(b.orders()) == [2]
    done = b.done()[1]
    assert (done["state"], done["delivered_ms"], done["ended_ms"], done["driver"]) == (
        "ALREADY_DELIVERED",
        at(18, 31),
        at(18, 31),
        TOM,
    )
    assert b.shipday.asked("/orders/A-1") == 1
    b.round(20 * SECOND)
    b.round(20 * SECOND)
    assert b.shipday.asked("/orders/A-1") == 1, "what became of it is asked once"
    assert b.told == 2


def test_an_order_that_failed_or_was_deleted_says_so_as_far_as_shipday_does():
    b = Bench()
    b.shipday.orders = [order(1, "A-1", driver=TOM, state="PICKED_UP"), order(2, "A-2"), order(3, "", phone="")]
    b.round()
    b.shipday.orders = []
    b.shipday.finished["A-1"] = order(1, "A-1", state="FAILED_DELIVERY", driver=TOM)
    b.round(20 * SECOND)
    done = b.done()
    assert done[1]["state"] == "FAILED_DELIVERY" and done[1]["ended_ms"] == b.now
    assert done[2]["state"] == "GONE", "Shipday has nothing by that number any more: deleted there"
    assert done[3]["state"] == "GONE", "an order without a number cannot be asked for"
    assert b.shipday.asked("/orders/") == 0


def test_an_order_shipday_knows_nothing_of_is_gone_whichever_way_it_says_so():
    b = Bench()
    b.shipday.unknown = 404
    b.shipday.orders = [order(1, "A-1")]
    b.round()
    b.shipday.orders = []
    b.round(20 * SECOND)
    assert b.done()[1]["state"] == "GONE"
    # another order under the same number is not this one
    b.shipday.unknown = 200
    b.shipday.orders = [order(5, "A-5")]
    b.round(20 * SECOND)
    b.shipday.orders = []
    b.shipday.finished["A-5"] = order(6, "A-5", state="ALREADY_DELIVERED")
    b.round(20 * SECOND)
    assert b.done()[5]["state"] == "GONE"


def test_what_became_of_an_order_is_asked_a_few_rounds_over_while_shipday_still_calls_it_active():
    b = Bench()
    b.shipday.orders = [order(1, "A-1", state="PICKED_UP", driver=TOM)]
    b.round()
    b.shipday.orders = []
    b.shipday.finished["A-1"] = order(1, "A-1", state="PICKED_UP", driver=TOM)  # the list was ahead of it
    b.round(20 * SECOND)
    assert b.done() == {} and b.orders() == {}
    b.shipday.finished["A-1"] = order(1, "A-1", state="ALREADY_DELIVERED", driver=TOM, delivered=at(18, 2))
    b.round(20 * SECOND)
    assert b.done()[1]["state"] == "ALREADY_DELIVERED"
    # one it never settles on is kept as gone after three tries
    b.shipday.orders = [order(2, "A-2")]
    b.round(20 * SECOND)
    b.shipday.orders = []
    b.shipday.finished["A-2"] = order(2, "A-2", state="STARTED")
    for _ in range(3):
        b.round(20 * SECOND)
    assert b.done()[2]["state"] == "GONE" and b.shipday.asked("/orders/A-2") == 3
    # and one that is back on the list was never gone
    b.shipday.orders = [order(3, "A-3")]
    b.round(20 * SECOND)
    b.shipday.orders = []
    b.shipday.finished["A-3"] = order(3, "A-3", state="NOT_ASSIGNED")
    b.round(20 * SECOND)
    b.shipday.orders = [order(3, "A-3")]
    b.round(20 * SECOND)
    assert 3 in b.orders() and 3 not in b.done()


def test_the_finished_ones_are_the_day_s_and_the_last_to_finish_is_first():
    b = Bench()
    b.shipday.orders = [order(1, "A-1"), order(2, "A-2")]
    b.round()
    b.shipday.orders = [order(2, "A-2")]
    b.round(MINUTE)
    b.shipday.orders = []
    b.round(MINUTE)
    assert list(b.done()) == [2, 1]
    b.now = at(4, 1, day=17)  # the night is over
    b.round()
    assert b.done() == {}


def test_when_shipday_does_not_answer_the_picture_stays_and_says_since_when():
    b = Bench()
    b.shipday.orders = [order(1, "A-1")]
    b.round()
    b.shipday.fail = httpx.ConnectError("no route")
    assert b.round(20 * SECOND) == {
        "asked": True,
        "answered": False,
        "reason": "unreachable",
        "said": "Shipday could not be reached (ConnectError)",
    }
    first = b.now
    b.shipday.fail = httpx.ReadTimeout("slow")
    b.round(MINUTE)
    said = b.board.said()
    assert list(b.orders()) == [1], "what was last heard stays up"
    assert said["trouble"] == {"since_ms": first, "reason": "slow", "said": "Shipday did not answer in time"}
    b.board.watched()
    assert b.board.pause() == SLOW_SECONDS, "a Shipday that does not answer is not asked oftener for being watched"
    b.shipday.fail = 500
    assert b.round(MINUTE)["reason"] == "error"
    b.shipday.fail = None
    b.round(MINUTE)
    assert b.board.said()["trouble"] is None
    assert b.told == 5, "each change of what is wrong is news, and so is its end"
    assert b.done() == {}, "an order is not gone because Shipday was"


def test_a_key_shipday_refuses_is_said_so_and_never_shown(caplog):
    b = Bench()
    b.shipday.fail = 401
    with caplog.at_level(logging.DEBUG):
        told = b.round()
        b.round(MINUTE)
    assert (told["reason"], told["said"]) == ("refused", "Shipday refused the key")
    assert b.board.said()["trouble"]["reason"] == "refused" and b.board.said()["read"] is False
    assert KEY not in caplog.text and KEY not in str(b.board.said()) and KEY not in str(b.board.about())
    assert caplog.text.count("Shipday refused the key") == 1, "said once, not every round"


def test_an_answer_that_is_not_what_shipday_s_pages_show_is_unreadable_or_read_as_far_as_it_goes():
    b = Bench()
    b.shipday.orders = "not a list"  # type: ignore[assignment]
    assert b.round()["reason"] == "unreadable"
    b.shipday.orders = [order(1, "A-1"), "junk", {"no": "id"}, None]  # type: ignore[list-item]
    b.round(MINUTE)
    assert list(b.orders()) == [1]
    b.shipday.orders = order(2, "A-2")  # type: ignore[assignment]  # one order by itself
    b.round(MINUTE)
    assert list(b.orders()) == [2]


def test_shipday_asked_too_often_is_given_a_rest_twice_as_long_each_time():
    b = Bench()
    b.shipday.fail = 429
    assert b.round()["reason"] == "limit"
    asked = b.shipday.asked("/orders")
    assert b.round(30 * SECOND)["asked"] is False, "held back for the first minute"
    assert b.shipday.asked("/orders") == asked
    assert b.round(31 * SECOND)["asked"] is True  # and refused again: two minutes now
    assert b.round(90 * SECOND)["asked"] is False
    assert b.round(31 * SECOND)["asked"] is True  # four minutes
    for _ in range(6):
        b.round(11 * MINUTE)
    b.round(9 * MINUTE)
    assert b.round(30 * SECOND)["asked"] is False, "ten minutes at the most"
    b.shipday.fail = None
    assert b.round(31 * SECOND)["answered"] is True
    b.shipday.fail = 429
    b.round(20 * SECOND)
    assert b.round(61 * SECOND)["asked"] is True, "and it starts over at a minute"
    # a person who asks is not held back
    assert b.round(SECOND, forced=True)["asked"] is True


def test_how_far_away_a_delivery_is_comes_from_shipday_once_a_minute_for_those_on_their_way():
    b = Bench()
    b.shipday.orders = [
        order(1, "A-1", state="PICKED_UP", driver=TOM, tracked="track-one"),
        order(2, "A-2", tracked="track-two"),  # nobody has it
        order(3, "A-3", state="NOT_ACCEPTED", driver=WEI, tracked="track-three"),  # not on its way yet
        order(4, "A-4", state="STARTED", driver=WEI),  # no tracking page
    ]
    b.shipday.progress["track-one"] = minutes_away(12)
    b.round()
    assert b.board.said()["eta"] == "on"
    assert b.orders()[1]["eta_ms"] == at(18, 12)
    assert [b.orders()[n]["eta_ms"] for n in (2, 3, 4)] == [None, None, None]
    assert [call for call in b.shipday.calls if "progress" in call] == ["GET /order/progress/track-one"]
    b.round(20 * SECOND)
    b.round(20 * SECOND)
    assert b.shipday.asked("/order/progress/track-one") == 1, "once a minute for one delivery"
    assert b.orders()[1]["eta_ms"] == at(18, 12), "and what it said stays meanwhile"
    b.shipday.progress["track-one"] = minutes_away(9.4)
    b.round(ETA_EVERY_MS - 40 * SECOND)
    assert b.shipday.asked("/order/progress/track-one") == 2
    assert b.orders()[1]["eta_ms"] == at(18, 11)
    assert b.shipday.sent[-1].url.params["isStaticDataRequired"] == "false"


def test_shipday_s_figure_stands_over_the_order_s_own_and_no_figure_leaves_that_one():
    b = Bench()
    b.shipday.orders = [
        order(1, "A-1", state="PICKED_UP", driver=TOM, tracked="track-one", eta="2026-11-16T23:40:00"),
        order(2, "A-2", state="PICKED_UP", driver=WEI, tracked="track-two", eta="18:45"),
    ]
    b.shipday.progress = {"track-one": minutes_away("INF"), "track-two": minutes_away(7)}
    b.round()
    assert (b.orders()[1]["eta_ms"], b.orders()[1]["eta_said"]) == (at(18, 40), "")
    assert (b.orders()[2]["eta_ms"], b.orders()[2]["eta_said"]) == (at(18, 7), "")


def test_an_account_whose_plan_has_no_such_call_is_not_asked_again_for_an_hour():
    b = Bench()
    b.shipday.orders = [
        order(1, "A-1", state="PICKED_UP", driver=TOM, tracked="track-one", eta="18:45"),
        order(2, "A-2", state="STARTED", driver=WEI, tracked="track-two"),
    ]
    b.shipday.progress = {"track-one": 401, "track-two": 401}
    b.round()
    said = b.board.said()
    assert said["eta"] == "plan" and said["trouble"] is None, "the key works: only this call is not the account's"
    assert b.orders()[1]["eta_said"] == "18:45", "the order's own word is what there is"
    asked = len([call for call in b.shipday.calls if "progress" in call])
    assert asked == 1, "the second is not tried after the first was refused"
    for _ in range(5):
        b.round(MINUTE)
    assert len([call for call in b.shipday.calls if "progress" in call]) == 1
    b.shipday.progress = {"track-one": minutes_away(5), "track-two": minutes_away(6)}
    b.round(ETA_PLAN_MS)
    assert b.board.said()["eta"] == "on" and b.orders()[1]["eta_ms"] is not None


def test_a_delivery_shipday_gives_no_answer_for_is_left_alone_for_ten_minutes():
    b = Bench()
    b.shipday.orders = [order(1, "A-1", state="PICKED_UP", driver=TOM, tracked="track-one")]
    b.round()  # 400: the id read off the link is not one Shipday knows
    assert b.board.said()["eta"] == "off" and b.board.said()["trouble"] is None
    for _ in range(5):
        b.round(MINUTE)
    assert b.shipday.asked("/order/progress/track-one") == 1
    b.round(ETA_MISS_MS - 5 * MINUTE)
    assert b.shipday.asked("/order/progress/track-one") == 2


def test_only_a_few_deliveries_are_asked_after_in_a_round_the_one_asked_longest_ago_first():
    b = Bench()
    b.shipday.orders = [
        order(n, f"A-{n}", state="PICKED_UP", driver=TOM, tracked=f"track-{n}", phone=f"+1781555{n:04d}")
        for n in range(1, ETA_MOST + 4)
    ]
    b.shipday.progress = {f"track-{n}": minutes_away(n) for n in range(1, ETA_MOST + 4)}
    b.round()
    assert len([o for o in b.orders().values() if o["eta_ms"] is not None]) == ETA_MOST
    b.round(20 * SECOND)
    assert all(o["eta_ms"] is not None for o in b.orders().values()), "the rest in the next round"
    assert len([call for call in b.shipday.calls if "progress" in call]) == ETA_MOST + 3
    # asked too often about deliveries: none is asked after for a while, and the orders still come
    b.shipday.progress = dict.fromkeys(b.shipday.progress, 429)
    b.round(ETA_EVERY_MS)
    before = len(b.shipday.calls)
    b.round(ETA_EVERY_MS)
    assert b.shipday.calls[before:] == ["GET /orders", "GET /carriers"] and b.board.said()["trouble"] is None


def test_a_person_s_asking_is_not_passed_on_within_ten_seconds_of_the_last():
    b = Bench()
    b.round()
    b.now += ASK_GAP_MS - 1
    assert b.board.ask_now() == {"asked": False, "answered": False, "soon": True, "reason": None, "said": ""}
    b.now += 1
    assert b.board.ask_now()["answered"] is True and b.shipday.asked("/orders") == 2


def test_shipday_is_asked_oftener_while_a_screen_looks_and_seldom_while_nobody_asks_the_hub():
    b = Bench()
    assert b.board.pause() == IDLE_SECONDS, "a hub nobody has asked yet"
    b.board.seen()  # the home screen read the picture for its button
    assert b.board.pause() == SLOW_SECONDS
    b.board.watched()  # the Shipday screen is open
    assert b.board.pause() == FAST_SECONDS
    b.now += WATCHED_MS
    assert b.board.pause() == SLOW_SECONDS, "closed again: once a minute, for the button"
    b.now += IDLE_AFTER_MS - WATCHED_MS - 1
    assert b.board.pause() == SLOW_SECONDS
    b.now += 1
    assert b.board.pause() == IDLE_SECONDS, "the last terminal went dark ten minutes ago"


def test_the_first_screen_to_ask_after_a_quiet_spell_has_shipday_asked_at_once():
    b = Bench()
    woken = b.board._wake  # noqa: SLF001 - what cuts the loop's wait short
    b.board.seen()
    assert woken.is_set(), "nobody had asked: the loop does not sit out its five minutes"
    woken.clear()
    b.now += 30_000
    b.board.seen()
    assert not woken.is_set(), "somebody asked half a minute ago: the round comes in its turn"
    b.now += IDLE_AFTER_MS
    b.board.watched()
    assert woken.is_set()


def test_another_key_forgets_what_the_last_one_was_told_and_the_same_key_keeps_it():
    b = Bench()
    b.shipday.orders, b.shipday.carriers = [order(1, "A-1")], [carrier(TOM)]
    b.round()
    b.board.use(b.shipday.source())  # the same key, typed again
    assert list(b.orders()) == [1]
    b.board.use(b.shipday.source("AnotherKey0.SomebodyElsesAccount99"))
    said = b.board.said()
    assert (said["on"], said["read"], said["orders"], said["drivers"]) == (True, False, [], [])
    b.board.use(None)
    assert b.board.said()["on"] is False
    assert b.round() == {"asked": False, "answered": False, "reason": "no_key", "said": "no key for Shipday"}


def test_what_leaves_the_building_is_the_key_and_a_number_shipday_gave():
    b = Bench()
    b.shipday.orders = [order(1, "A 1/2", state="PICKED_UP", driver=TOM, tracked="track-one")]
    b.board.pos = lambda: [OnPos("o-1", 12, "Linda Chen", "7815550101", ELM)]
    b.round()
    b.shipday.orders = []
    b.round(MINUTE)
    assert b.shipday.calls == [
        "GET /orders",
        "GET /carriers",
        "GET /order/progress/track-one",
        "GET /orders",
        "GET /carriers",
        "GET /orders/A%201%2F2",
    ]
    for request in b.shipday.sent:
        assert request.headers["authorization"] == f"Basic {KEY}" and request.headers["x-api-key"] == KEY
        assert request.content == b""
        assert all(word not in str(request.url) for word in ("Linda", "Elm", "5550101", "o-1"))


def test_nothing_of_a_customer_is_written_to_the_log(caplog):
    b = Bench()
    b.shipday.orders = [order(1, "A-1", state="PICKED_UP", driver=TOM, tracked="track-one")]
    b.shipday.progress["track-one"] = 401
    with caplog.at_level(logging.DEBUG):
        b.round()
        b.shipday.orders = []
        b.shipday.fail = 500
        b.round(MINUTE)
        b.shipday.fail = None
        b.round(MINUTE)
    assert caplog.text
    for word in ("Linda", "Chen", "Elm", "5550101", "Tom", KEY):
        assert word not in caplog.text


def test_each_delivery_says_the_check_it_is_on_the_pos_as_the_pos_stands_when_asked():
    b = Bench()
    b.shipday.orders = [order(1, "1270166229"), order(2, "A-2", phone="+17815550102")]
    on_pos: list[OnPos] = []
    b.board.pos = lambda: on_pos
    b.round()
    assert [o["pos"] for o in b.board.said()["orders"]] == [None, None]
    on_pos.append(OnPos("gf-1270166229", 12, "Linda Chen", "7815559999", ELM, "1270166229", "open", "new"))
    on_pos.append(OnPos("o-7", 13, "Raj", "7815550102", OAK, "", "open", "ready"))
    assert [o["pos"] for o in b.board.said()["orders"]] == [
        {"order_id": "gf-1270166229", "order_no": 12, "status": "open", "stage": "new", "by": "number"},
        {"order_id": "o-7", "order_no": 13, "status": "open", "stage": "ready", "by": "phone"},
    ], "matched without another round"
    b.shipday.orders = [order(2, "A-2", phone="+17815550102")]
    b.round(MINUTE)
    assert b.done()[1]["pos"]["order_id"] == "gf-1270166229", "a finished one still says its check"
