"""A number left on a dish (the Toast comparison, 2026-11-15): whoever 86s a dish may type how many are
left; every one sold takes it down, one removed or voided gives it back, the dish is sold out at zero, and
the count is gone when the night is over."""

from __future__ import annotations

import threading
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app, sellable
from pos.customers import _why
from pos.menu.gloriafood import load_restaurant_menu
from pos.menu.service import MenuService, load_definitions
from pos.orders.counts import count_ops, holds, uses
from pos.printing.service import PrintService
from pos.sync.hlc import HLC
from pos.sync.oplog import Line, Op, OpStore
from pos.tax import massachusetts

from ..conftest import T0
from .test_menu_orders import DINNER, GTC_QUART

ROLL_ID = "CALROLL:roll"
ROLL = {"variant_id": ROLL_ID}


class Clock:
    """The hub's clock, which a test can move on."""

    def __init__(self, at: datetime = DINNER) -> None:
        self.at = at

    def __call__(self) -> datetime:
        return self.at


def client(menu: MenuService | None = None) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100_000),
            menu=menu if menu is not None else MenuService(load_definitions("restaurant"), now=Clock()),
            taxes=massachusetts(),
            printing=PrintService([]),
        )
    )


def payload(order_id: str, op_id: str, kind: str, at: int, **data):
    return {
        "op_id": f"{order_id}-{op_id}",
        "order_id": order_id,
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": kind,
        "data": data,
    }


def op(op_id: str, kind: str, at: int, **data) -> Op:
    """An operation on order o1 as the store holds it, for the checks made below the API."""
    return Op(op_id, "o1", HLC(T0 + at, 0, "t1"), "t1", kind, data)


def send(c: TestClient, order_id: str, *ops: dict) -> dict:
    answer = c.post(f"/orders/{order_id}/ops", json=list(ops))
    assert answer.status_code == 202, answer.text
    return answer.json()


def add(c: TestClient, order_id: str, line_id: str, at: int, request: dict = ROLL, qty: int = 1) -> dict:
    return send(
        c, order_id, payload(order_id, line_id, "add_line", at, line_id=line_id, item="?", qty=qty, request=request)
    )


def count(c: TestClient, target: str = ROLL_ID, remaining: int | None = None, status: str = "available") -> dict:
    body = {"target_id": target, "status": status, "by": "Amy"}
    if remaining is not None:
        body["remaining"] = remaining
    answer = c.post("/menu/86", json=body)
    assert answer.status_code == 200, answer.text
    return answer.json()


def offer(c: TestClient, target: str = ROLL_ID) -> dict:
    """The size as the menu shows it on a tile: its `status` and how many are `left`."""

    def walk(sections):
        for section in sections:
            for entry in section["entries"]:
                for variant in entry["variants"]:
                    if variant["variant_id"] == target:
                        return variant
            found = walk(section["sections"])
            if found is not None:
                return found
        return None

    for menu in c.get("/menu").json()["menus"]:
        found = walk(menu["sections"])
        if found is not None:
            return found
    raise AssertionError(f"{target} is not on the menu")


def left(c: TestClient, target: str = ROLL_ID) -> int | None:
    return offer(c, target)["left"]


def said(answer: dict) -> list[str]:
    return [p["message"] for r in answer["refused"] for p in r["problems"]]


def qtys(c: TestClient, order_id: str) -> dict[str, tuple[int, str]]:
    return {i: (line["qty"], line["status"]) for i, line in c.get(f"/orders/{order_id}").json()["lines"].items()}


# --- selling down ---------------------------------------------------------------------------------------


def test_a_number_left_goes_down_as_the_dish_sells_and_the_dish_sells_out_at_zero():
    c = client()
    assert offer(c) == {**offer(c), "status": "available", "left": None}  # no number: the tile says nothing
    board = count(c, remaining=3)["items"]
    assert [(r["target_id"], r["name"], r["status"], r["left"], r["total"], r["by"]) for r in board] == [
        (ROLL_ID, "California roll", "available", 3, 3, "Amy")
    ]
    assert left(c) == 3

    assert add(c, "o1", "L1", 1, qty=2)["refused"] == []
    assert left(c) == 1 and offer(c)["status"] == "available"
    assert add(c, "o2", "L1", 2)["refused"] == []  # another table takes the last one
    assert (offer(c)["status"], left(c)) == ("sold_out", 0)
    row = c.get("/menu/86").json()["items"][0]
    assert (row["status"], row["left"], row["total"]) == ("sold_out", 0, 3)

    answer = add(c, "o3", "L1", 3)
    assert [r["error"] for r in answer["refused"]] == ["none_left"] and said(answer) == ["No California roll left."]
    assert c.get("/orders/o3").status_code == 404 or qtys(c, "o3") == {}  # nothing went on that check
    assert left(c) == 0


def test_more_than_is_left_is_refused_with_the_number_and_the_rest_of_the_batch_goes_through():
    c = client()
    count(c, remaining=2)
    answer = send(
        c,
        "o1",
        payload("o1", "open", "create", 0, table="4"),
        payload("o1", "L1", "add_line", 1, line_id="L1", item="?", qty=3, request=ROLL),
        payload("o1", "L2", "add_line", 2, line_id="L2", item="?", request=GTC_QUART),
    )
    assert said(answer) == ["Only 2 California roll left."]
    assert answer["accepted"] == ["o1-open", "o1-L2"] and left(c) == 2
    assert add(c, "o1", "L3", 3, qty=2)["refused"] == [] and left(c) == 0


def test_a_larger_quantity_on_a_line_is_weighed_like_a_new_one():
    c = client()
    count(c, remaining=3)
    add(c, "o1", "L1", 1)
    more = send(c, "o1", payload("o1", "q4", "set_line", 2, line_id="L1", qty=4))
    assert said(more) == ["Only 2 California roll left."] and qtys(c, "o1")["L1"] == (1, "active")
    assert send(c, "o1", payload("o1", "q3", "set_line", 3, line_id="L1", qty=3))["refused"] == []
    assert left(c) == 0 and qtys(c, "o1")["L1"] == (3, "active")
    assert send(c, "o1", payload("o1", "q1", "set_line", 4, line_id="L1", qty=1))["refused"] == []
    assert left(c) == 2  # fewer of it gives the difference back
    # where the line sits on the check is nothing the count hears about
    assert send(c, "o1", payload("o1", "mv", "set_line", 5, line_id="L1", rank=9.5))["refused"] == []
    assert left(c) == 2


def test_two_screens_cannot_both_sell_the_last_one():
    c = client()
    count(c, remaining=3)
    answers: list[dict] = []

    def ring(n: int) -> None:
        answers.append(add(c, f"t{n}", "L1", n))

    screens = [threading.Thread(target=ring, args=(n,)) for n in range(8)]
    for screen in screens:
        screen.start()
    for screen in screens:
        screen.join()
    assert sorted(len(a["refused"]) for a in answers) == [0, 0, 0, 1, 1, 1, 1, 1]
    assert left(c) == 0


def test_the_same_operations_sent_again_take_nothing_more():
    c = client()
    count(c, remaining=5)
    op = payload("o1", "L1", "add_line", 1, line_id="L1", item="?", qty=2, request=ROLL)
    assert send(c, "o1", op)["accepted"] == ["o1-L1"]
    assert send(c, "o1", op)["accepted"] == [] and left(c) == 3  # a terminal that did not hear the answer


# --- giving back ----------------------------------------------------------------------------------------


def test_a_dish_taken_off_gives_its_one_back_but_never_above_the_number_typed():
    c = client()
    add(c, "o0", "L0", 1)  # rung in before anyone counted
    count(c, remaining=2)
    add(c, "o1", "L1", 2)
    assert left(c) == 1
    send(c, "o1", payload("o1", "x1", "void_line", 3, line_id="L1"))  # not sent yet: it just comes off
    assert left(c) == 2 and qtys(c, "o1")["L1"] == (1, "removed")
    send(c, "o0", payload("o0", "x0", "void_line", 4, line_id="L0"))
    assert left(c) == 2  # that one was never part of the two


def test_a_void_of_a_sent_dish_and_a_voided_order_give_back_too():
    c = client()
    count(c, remaining=3)
    send(
        c,
        "o1",
        payload("o1", "open", "create", 0, table="4"),
        payload("o1", "L1", "add_line", 1, line_id="L1", item="?", request=ROLL),
        payload("o1", "L2", "add_line", 2, line_id="L2", item="?", request=ROLL),
        payload("o1", "fire", "fire", 3, course="*"),
    )
    assert left(c) == 1
    token = c.post("/approvals", json={"device": "t1", "pin": "9999", "order_id": "o1", "purpose": "void"}).json()
    void = payload(
        "o1", "x1", "void_line", 4, line_id="L1", reason="rung-in-wrong", by="Amy", approval=token["approval"]
    )
    assert send(c, "o1", void)["refused"] == []
    assert left(c) == 2 and qtys(c, "o1")["L1"] == (1, "void")
    send(c, "o1", payload("o1", "gone", "void_order", 5, reason="walked out"))
    assert left(c) == 3


def test_the_last_one_can_still_be_changed_after_it_sold_out():
    """A sent dish that is changed is voided and added again in one batch. The dish is sold out by then, and
    the change takes nothing: its own one comes back with the void."""
    c = client()
    count(c, remaining=1)
    send(
        c,
        "o1",
        payload("o1", "L1", "add_line", 1, line_id="L1", item="?", request=ROLL),
        payload("o1", "fire", "fire", 2, course="*"),
    )
    assert (offer(c)["status"], left(c)) == ("sold_out", 0)
    # the sheet that changes it prices it first, and is not told its own dish is gone
    assert c.post("/menu/price", json=ROLL).json()["problems"] == []
    changed = send(
        c,
        "o1",
        payload("o1", "x1", "void_line", 3, line_id="L1", reason="changed"),
        payload("o1", "L1b", "add_line", 4, line_id="L1b", item="?", request=ROLL, replaces="L1", note="no sesame"),
        payload("o1", "fire2", "fire", 5, course="*"),
    )
    assert changed["refused"] == [] and left(c) == 0
    assert qtys(c, "o1") == {"L1": (1, "void"), "L1b": (1, "active")}

    # asking for two of it is asking for one more than there is: neither half is stored, the check stays
    more = send(
        c,
        "o1",
        payload("o1", "x2", "void_line", 6, line_id="L1b", reason="changed"),
        payload("o1", "L1c", "add_line", 7, line_id="L1c", item="?", qty=2, request=ROLL, replaces="L1b"),
        payload("o1", "fire3", "fire", 8, course="*"),
    )
    assert [r["op_id"] for r in more["refused"]] == ["o1-x2", "o1-L1c"]
    assert set(said(more)) == {"No California roll left."}
    assert qtys(c, "o1") == {"L1": (1, "void"), "L1b": (1, "active")} and left(c) == 0


def test_the_line_that_replaces_one_is_weighed_with_its_void_even_when_it_comes_first():
    c = client()
    count(c, remaining=1)
    add(c, "o1", "L1", 1)
    swapped = send(
        c,
        "o1",
        payload("o1", "L1b", "add_line", 2, line_id="L1b", item="?", request=ROLL, replaces="L1"),
        payload("o1", "x1", "void_line", 3, line_id="L1"),
    )
    assert swapped["refused"] == [] and swapped["accepted"] == ["o1-L1b", "o1-x1"] and left(c) == 0


# --- dishes inside dishes -------------------------------------------------------------------------------


def test_a_dish_chosen_inside_another_counts_too():
    """The maki combination is three rolls and a soup, each a dish of the menu: a number left on a roll goes
    down when a combination takes it, and the combination cannot take a roll that has none left."""
    defs, _ = load_restaurant_menu()
    c = client(MenuService(defs, now=Clock()))
    rolls = [o.id for o in defs.options_of("roll_934419")[:4]]
    soup = {"group_id": "sushi_soup_2334003", "option_id": "sushi_soup_2334003:14653486"}

    def combo(*picked: str) -> dict:
        chosen = [{"group_id": "roll_934419", "option_id": option} for option in picked]
        return {"variant_id": "J55:regular", "entry_id": "dinner:J55", "selections": [*chosen, soup]}

    count(c, "K02:regular", remaining=2)
    assert add(c, "o1", "L1", 1, combo(*rolls[:3]), qty=2)["refused"] == []
    line = c.get("/orders/o1").json()["lines"]["L1"]
    assert line["priced"]["uses"]["K02:regular"] == 1 and line["priced"]["uses"]["J55:regular"] == 1
    assert (offer(c, "K02:regular")["status"], left(c, "K02:regular")) == ("sold_out", 0)  # two combinations, two rolls
    detail = c.get("/menu/items/J55", params={"entry": "dinner:J55"}).json()
    offered = {o["option_id"]: o["status"] for g in detail["groups"] for o in g["options"]}
    assert offered[rolls[1]] == "sold_out" and offered[rolls[0]] == "available"

    again = add(c, "o2", "L1", 2, combo(*rolls[:3]))
    assert [r["error"] for r in again["refused"]] == ["none_left"] and said(again) == ["No Kanikyu left."]
    assert add(c, "o2", "L2", 3, combo(rolls[0], rolls[2], rolls[3]))["refused"] == []  # without that roll

    send(c, "o1", payload("o1", "q1", "set_line", 4, line_id="L1", qty=1))
    assert left(c, "K02:regular") == 1  # one combination fewer gives its roll back


def test_what_a_line_takes_is_read_from_its_snapshot():
    assert uses(
        Line("L1", "Combo", priced={"variant_id": "J55:regular", "uses": {"J55:regular": 1, "K02:regular": 2}})
    ) == {
        "J55:regular": 1,
        "K02:regular": 2,
    }
    assert uses(Line("L1", "Roll", priced={"variant_id": ROLL_ID})) == {ROLL_ID: 1}  # a line from before counts
    assert uses(Line("L1", "Typed in")) == {}  # never came from the menu: nothing to count
    c = client()
    add(c, "o1", "L1", 1)
    assert "uses" not in c.get("/orders/o1").json()["lines"]["L1"]["priced"]  # a plain dish says nothing extra


# --- by hand, and the night's end -----------------------------------------------------------------------


def test_sold_out_by_hand_drops_the_number_and_a_number_brings_the_dish_back():
    c = client()
    count(c, remaining=5)
    board = count(c, status="sold_out")["items"]
    assert [(r["status"], "left" in r) for r in board] == [("sold_out", False)]
    answer = add(c, "o1", "L1", 1)
    assert [r["error"] for r in answer["refused"]] == ["invalid_line"]  # the 86 by hand is as it always was
    assert [p["code"] for r in answer["refused"] for p in r["problems"]] == ["sold_out"]

    count(c, remaining=2)
    assert (offer(c)["status"], left(c)) == ("available", 2)
    assert count(c)["items"] == []  # available with no number: the count is off
    assert left(c) is None and add(c, "o1", "L2", 2, qty=40)["refused"] == []


def test_a_new_number_starts_the_count_again():
    c = client()
    count(c, remaining=2)
    add(c, "o1", "L1", 1, qty=2)
    assert offer(c)["status"] == "sold_out"
    count(c, remaining=6)  # the kitchen made more
    assert (offer(c)["status"], left(c)) == ("available", 6)
    send(c, "o1", payload("o1", "x1", "void_line", 2, line_id="L1"))
    assert left(c) == 6  # what comes back never takes it above the six


@pytest.mark.parametrize(
    ("body", "status"),
    [
        ({"target_id": "rice:brown", "status": "available", "remaining": 4}, 422),  # a choice that is only a word
        ({"target_id": ROLL_ID, "status": "sold_out", "remaining": 4}, 422),
        ({"target_id": ROLL_ID, "status": "available", "remaining": 0}, 422),
        ({"target_id": ROLL_ID, "status": "available", "remaining": 1000}, 422),
        ({"target_id": "NOPE:x", "status": "available", "remaining": 4}, 404),
    ],
)
def test_a_number_left_is_for_a_dish_that_is_on_sale(body, status):
    c = client()
    assert c.post("/menu/86", json=body).status_code == status
    assert c.get("/menu/86").json()["items"] == []


def test_the_count_is_gone_when_the_night_is_over():
    clock = Clock(datetime(2026, 10, 30, 23, 30, tzinfo=localtime.zone()))  # a Friday, half past eleven at night
    c = client(MenuService(load_definitions("restaurant"), now=clock))
    row = count(c, remaining=1)["items"][0]
    assert row["until"] == "2026-10-31T04:00:00-04:00"
    add(c, "o1", "L1", 1)
    assert offer(c)["status"] == "sold_out"

    clock.at = datetime(2026, 10, 31, 3, 59, tzinfo=localtime.zone())  # the bar is still open after midnight
    assert offer(c)["status"] == "sold_out" and said(add(c, "o2", "L1", 2)) == ["No California roll left."]

    clock.at = datetime(2026, 10, 31, 4, 0, tzinfo=localtime.zone())
    assert (offer(c)["status"], left(c)) == ("available", None)
    assert c.get("/menu/86").json()["items"] == []
    assert add(c, "o2", "L2", 3, qty=7)["refused"] == []  # Saturday sells as many as it likes


def test_a_night_ends_at_four_in_the_morning_local_time():
    zone = localtime.zone()
    four = datetime(2026, 10, 31, 4, 0, tzinfo=zone)
    assert localtime.night_end(datetime(2026, 10, 30, 17, 0, tzinfo=zone)) == four
    assert localtime.night_end(datetime(2026, 10, 31, 0, 30, tzinfo=zone)) == four
    assert localtime.night_end(four) == four + timedelta(days=1)
    assert localtime.night_end(datetime(2026, 10, 30, 23, 0, tzinfo=UTC)) == four  # seven in the evening there


# --- around it ------------------------------------------------------------------------------------------


def test_every_screen_is_told_when_a_number_moves():
    menu = MenuService(load_definitions("restaurant"), now=Clock())
    c = client(menu)
    told: list[int] = []
    tell = menu.on_change
    menu.on_change = lambda: (told.append(1), tell())
    count(c, remaining=4)
    assert len(told) == 1
    add(c, "o1", "L1", 1)
    assert len(told) == 2  # the tile reads 3 left on every screen
    add(c, "o1", "L2", 2, GTC_QUART)
    assert len(told) == 2  # a dish nobody counts moves nothing


def test_with_no_dish_counted_a_batch_is_not_looked_at():
    menu = MenuService(load_definitions("restaurant"), now=Clock())

    class Unread(OpStore):
        def state(self, order_id):
            raise AssertionError("nothing is counted: the order is not read")

    ops = [op("a", "add_line", 0, line_id="L1", item="?", priced={"variant_id": ROLL_ID})]
    assert count_ops(menu, Unread(), ops) == (ops, [], {})
    assert menu.counting().__class__.__name__ == "nullcontext"
    menu.set_availability(ROLL_ID, "available", remaining=2)
    assert menu.counting().__class__.__name__ != "nullcontext"
    kept, refused, taken = count_ops(menu, OpStore(), ops)
    assert (kept, refused, taken) == (ops, [], {ROLL_ID: 1})


def test_a_voided_order_holds_nothing():
    store = OpStore(physical=lambda: T0 + 100_000)
    store.append(
        [
            op("a", "add_line", 0, line_id="L1", item="?", qty=3, priced={"variant_id": "X:1"}),
            op("b", "add_line", 1, line_id="L2", item="?", priced={"variant_id": "Y:1"}),
        ]
    )
    assert holds(store.state("o1"), {"X:1", "Z:1"}) == {"X:1": 3, "Z:1": 0}
    store.append([op("c", "void_order", 2)])
    assert holds(store.state("o1"), {"X:1"}) == {"X:1": 0}


def test_same_again_says_a_counted_out_dish_is_sold_out():
    menu = MenuService(load_definitions("restaurant"), now=Clock())
    menu.set_availability(ROLL_ID, "available", remaining=1)
    menu.take({ROLL_ID: 1})
    priced, problems = sellable(menu, ROLL)
    assert priced is None and [p["code"] for p in problems] == ["none_left"]
    assert _why(problems) == "It is sold out today."
    priced, problems = sellable(menu, ROLL, counted_out=False)  # a line arriving: weighed against the checks
    assert priced is not None and problems == [] and priced["problems"] == []
