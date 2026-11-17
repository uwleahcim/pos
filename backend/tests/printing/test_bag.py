"""What goes in the bag with a to-go order: one question before it is sent (chopsticks, forks, napkins, or
nothing), set per location, and its answer on the takeout station's ticket under the dishes. An answer
changed after the order went to the kitchen prints a slip there. Nothing about the check changes."""

from __future__ import annotations

from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from pos.orders.bag import bag_lines, bag_of, bag_ops
from pos.printing.ticket import DEMO, render
from pos.settings import clean_bag
from pos.sync.hlc import HLC
from pos.sync.oplog import Op

from ..conftest import T0
from ..orders.test_menu_orders import payload
from .fake_printer import Decoded, decode
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen, send
from .test_paid_tickets import HOUR, PHONE, future
from .test_stations import manager

CHOPSTICKS = {"id": "chopsticks", "name": "Chopsticks", "qty": 2}
FORKS = {"id": "forks", "name": "Forks", "qty": 1}
NAPKINS = {"id": "napkins", "name": "Napkins", "qty": 1}
RULE = "-" * 48


def answer(c: TestClient, op_id: str, *items: dict, at: int = 40, order_id: str = "o1", **more) -> dict:
    """The answer set on the order, by itself; what the hub said of the operation."""
    op = payload(op_id, "set_field", at, bag={"items": list(items)}, **more)
    told = c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id}])
    assert told.status_code == 202, told.text
    return told.json()


def ticket(c: TestClient, key: str, printer: str = "takeout") -> Decoded | None:
    job = c.app.state.printing.store.get(f"{key}:{printer}")
    return None if job is None else decode(job.data)


def bagged(c: TestClient, key: str, printer: str = "takeout") -> list[str] | None:
    """What the printer's ticket says goes in the bag: its lines from the heading on, None when it says nothing."""
    paper = ticket(c, key, printer)
    assert paper is not None, f"no ticket at {printer}"
    lines = [line.strip() for line in paper.text]
    for heading in ("ALSO IN THE BAG", "NOW IN THE BAG"):
        if heading in lines:
            start = lines.index(heading)
            return lines[start : lines.index(RULE, start)]
    return None


def to_go(c: TestClient, *items: dict | None, order_id: str = "o1") -> str:
    """A phone order with a chicken and a roll, answered with `items` and sent in one go, as the screen does."""
    ops = [
        payload("open", "create", 0, **PHONE),
        payload("a1", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
        payload("a2", "add_line", 2, line_id="L2", item="?", request=ROLL),
    ]
    if items != (None,):
        ops.append(payload("ask", "set_field", 3, bag={"items": list(items)}, by="Amy", by_id="s1"))
    ops.append(payload("fire", "fire", 4, course="*"))
    told = c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops])
    assert told.status_code == 202 and told.json()["refused"] == [], told.text
    return "fire"


def test_the_question_is_asked_to_start_with_what_the_old_pos_rang_as_free_dishes():
    c = kitchen("wok", "takeout")
    assert c.get("/settings/bag").json() == {
        "enabled": True,
        "question": "What goes in the bag?",
        "choices": [
            {"id": "chopsticks", "name": "Chopsticks"},
            {"id": "forks", "name": "Forks"},
            {"id": "napkins", "name": "Napkins"},
        ],
    }


def test_a_manager_words_the_question_and_lists_its_choices():
    c = kitchen("wok", "takeout")
    asked = {
        "enabled": True,
        "question": "  Chopsticks,   forks or sauce? ",
        "choices": [{"id": "chopsticks", "name": "Chopsticks"}, {"name": "Duck  sauce"}, {"name": "Soy Sauce"}],
    }
    assert c.put("/settings/bag", json=asked).status_code == 401
    server, _ = c.app.state.tokens.issue("s1", "Amy", "server")
    assert c.put("/settings/bag", json=asked, headers={"authorization": f"Bearer {server}"}).status_code == 403
    saved = c.put("/settings/bag", json=asked, headers=manager(c))
    assert saved.status_code == 200 and saved.json() == {
        "enabled": True,
        "question": "Chopsticks, forks or sauce?",
        # a new choice gets an id from its name, and keeps it: the answers on orders carry it
        "choices": [
            {"id": "chopsticks", "name": "Chopsticks"},
            {"id": "duck-sauce", "name": "Duck sauce"},
            {"id": "soy-sauce", "name": "Soy Sauce"},
        ],
    }
    assert c.get("/settings/bag").json() == saved.json()
    # turned off, the list may be empty; the question falls back to its own words when none are typed
    off = c.put("/settings/bag", json={"enabled": False, "question": "", "choices": []}, headers=manager(c))
    assert off.json() == {"enabled": False, "question": "What goes in the bag?", "choices": []}


def test_what_the_setting_refuses():
    assert clean_bag({})["enabled"] is True and len(clean_bag({"choices": [{"name": "Forks"}]})["choices"]) == 1
    for bad, why in [
        ({"enabled": "yes"}, "true or false"),
        ({"enabled": True, "choices": []}, "at least one thing to offer"),
        ({"choices": "forks"}, "a list of"),
        ({"choices": [{"name": f"Thing {n}"} for n in range(9)]}, "at most 8 choices"),
        ({"choices": [{"name": " "}]}, "needs a name"),
        ({"choices": [{"name": "x" * 25}]}, "at most 24 characters"),
        ({"choices": [{"name": "Forks"}, {"name": "forks"}]}, "listed twice"),
        ({"choices": [{"id": "a b", "name": "Forks"}]}, "letters, digits"),
        ({"choices": [{"id": "f", "name": "Forks"}, {"id": "f", "name": "Spoons"}]}, "listed twice"),
        ({"question": "x" * 61, "choices": [{"name": "Forks"}]}, "takes 60 letters"),
    ]:
        with pytest.raises(ValueError, match=why):
            clean_bag(bad)
    # two names that make the same id: the second is numbered
    two = clean_bag({"choices": [{"name": "Soy sauce"}, {"name": "Soy-sauce"}]})["choices"]
    assert [choice["id"] for choice in two] == ["soy-sauce", "soy-sauce-2"]
    c = kitchen("wok", "takeout")
    refused = c.put("/settings/bag", json={"enabled": True, "choices": []}, headers=manager(c))
    assert refused.status_code == 422 and refused.json()["detail"]["error"] == "bad_value"


def test_the_answer_is_on_the_bags_ticket_under_the_dishes_and_on_no_cooks_ticket():
    c = kitchen("wok", "sushi", "takeout")
    key = to_go(c, CHOPSTICKS, FORKS)
    assert c.get("/orders/o1").json()["fields"]["bag"] == {"items": [CHOPSTICKS, FORKS]}
    assert bagged(c, key) == ["ALSO IN THE BAG", "2 x Chopsticks", "Forks"]
    paper = [line.strip() for line in ticket(c, key).text]
    # under the dishes, over the foot of the ticket: a rule under the head, one over the bag, one over the foot
    rules = [n for n, line in enumerate(paper) if line == RULE]
    assert len(rules) == 3 and rules[1] < paper.index("ALSO IN THE BAG") < rules[2]
    assert bagged(c, key, "wok") is None and bagged(c, key, "sushi") is None
    # nothing on the check: these cost nothing
    check = c.get("/orders/o1/check").json()
    assert len(check["lines"]) == 2 and "bag" not in check


def test_nothing_is_an_answer_and_the_ticket_says_it():
    c = kitchen("wok", "takeout")
    key = to_go(c)
    assert c.get("/orders/o1").json()["fields"]["bag"] == {"items": []}
    assert bagged(c, key) == ["ALSO IN THE BAG", "NOTHING"]


def test_an_order_nobody_was_asked_about_prints_as_before():
    c = kitchen("wok", "takeout")
    key = to_go(c, None)
    assert "bag" not in c.get("/orders/o1").json()["fields"]
    assert bagged(c, key) is None
    assert [line.strip() for line in ticket(c, key).text].count(RULE) == 2


def test_a_tables_order_says_nothing_of_a_bag():
    c = kitchen("wok", "takeout")
    send(c, "o1", CHICKEN)  # table 12
    answer(c, "ask", FORKS)
    key = send(c, "o1", BEER, at=1000)
    assert bagged(c, key, "wok") is None and ticket(c, "ask:bag") is None
    # one printer for the cooks and the bag: the to-go order's whole ticket is the bag's, and says it
    one = kitchen(replace(c.app.state.printing.printers[0], id="k", stations=("wok", "takeout")))
    assert bagged(one, to_go(one, FORKS), "k") == ["ALSO IN THE BAG", "Forks"]


def test_with_no_printer_at_the_counter_no_ticket_says_it():
    c = kitchen("wok")
    key = to_go(c, CHOPSTICKS)
    assert bagged(c, key, "wok") is None
    answer(c, "again", FORKS, at=900)
    assert [job.job_id for job in c.app.state.printing.store.all()] == [f"{key}:wok"]


def test_an_answer_the_hub_cannot_read_is_left_out_and_the_rest_goes_through():
    c = kitchen("wok", "takeout")
    c.post("/orders/o1/ops", json=[payload("open", "create", 0, **PHONE)])
    for n, (bad, why) in enumerate(
        [
            ("forks", "lists what goes in the bag"),
            ({"items": "forks"}, "lists what goes in the bag"),
            ({"items": ["forks"]}, "{id, name, qty}"),
            ({"items": [{"id": "a b", "name": "Forks"}]}, "letters, digits"),
            ({"items": [FORKS, FORKS]}, "listed twice"),
            ({"items": [{**FORKS, "qty": 0}]}, "from 1 to 99"),
            ({"items": [{**FORKS, "qty": 100}]}, "from 1 to 99"),
            ({"items": [{**FORKS, "qty": True}]}, "from 1 to 99"),
            ({"items": [{**FORKS, "name": "x" * 25}]}, "takes 24 letters"),
            ({"items": [{"id": f"c{i}", "name": "Thing"} for i in range(9)]}, "at most 8"),
        ]
    ):
        op = payload(f"bad{n}", "set_field", 10 + n, bag=bad, customer_name=f"Linda {n}")
        told = c.post("/orders/o1/ops", json=[op]).json()
        assert [(r["op_id"], r["error"]) for r in told["refused"]] == [(f"bad{n}", "invalid_bag")], bad
        assert why in told["refused"][0]["message"]
        fields = c.get("/orders/o1").json()["fields"]
        assert "bag" not in fields and fields["customer_name"] == f"Linda {n}"
    # an operation that said nothing else is not kept at all
    alone = c.post("/orders/o1/ops", json=[payload("alone", "set_field", 60, bag="forks")]).json()
    assert alone["accepted"] == [] and alone["refused"][0]["error"] == "invalid_bag"
    # what the hub keeps is tidy: a bare list, a name's spaces, no name, no count
    loose = [{"id": "chopsticks", "name": "  Chop   sticks "}, {"id": "forks"}]
    assert c.post("/orders/o1/ops", json=[payload("ok", "set_field", 70, bag=loose)]).json()["refused"] == []
    assert c.get("/orders/o1").json()["fields"]["bag"] == {
        "items": [{"id": "chopsticks", "name": "Chop sticks", "qty": 1}, {"id": "forks", "name": "forks", "qty": 1}]
    }
    # and taking the answer back asks again: the order carries none
    assert c.post("/orders/o1/ops", json=[payload("back", "set_field", 80, bag=None)]).json()["refused"] == []
    assert c.get("/orders/o1").json()["fields"]["bag"] is None
    assert bag_of(c.get("/orders/o1").json()["fields"]) is None


def test_an_answer_changed_after_the_order_was_sent_prints_a_slip_at_the_counter_alone():
    c = kitchen("wok", "sushi", "takeout")
    to_go(c, CHOPSTICKS)
    answer(c, "more", CHOPSTICKS, FORKS, NAPKINS, at=900)
    slip = ticket(c, "more:bag")
    assert slip is not None
    lines = [line.strip() for line in slip.text]
    assert lines[0] == "*** BAG *** TAKEOUT" and "#1  LINDA" in lines
    assert bagged(c, "more:bag") == ["NOW IN THE BAG", "2 x Chopsticks", "Forks", "Napkins"]
    assert slip.images == [] and lines.count(RULE) == 2  # no dish on it
    assert not [line for line in lines if "PAID" in line]  # nor the money: the bag's ticket has it
    assert ticket(c, "more:bag", "wok") is None and ticket(c, "more:bag", "sushi") is None
    # down to nothing is a change too
    answer(c, "none", at=950)
    assert bagged(c, "none:bag") == ["NOW IN THE BAG", "NOTHING"]
    # the same answer again changes nothing, and prints nothing
    answer(c, "same", at=960)
    assert ticket(c, "same:bag") is None


def test_an_answer_before_the_order_is_sent_prints_with_the_order_and_not_before():
    c = kitchen("wok", "takeout")
    ops = [payload("open", "create", 0, **PHONE), payload("a1", "add_line", 1, line_id="L1", item="?", request=CHICKEN)]
    c.post("/orders/o1/ops", json=ops)
    answer(c, "first", FORKS, at=5)
    answer(c, "second", CHOPSTICKS, at=6)  # the customer thinks again while paying
    assert c.app.state.printing.store.all() == []
    c.post("/orders/o1/ops", json=[payload("fire", "fire", 10, course="*")])
    assert bagged(c, "fire") == ["ALSO IN THE BAG", "2 x Chopsticks"]
    assert [job.job_id for job in c.app.state.printing.store.all()] == ["fire:wok", "fire:takeout"]


def test_an_order_first_asked_about_after_it_was_sent_gets_the_slip_too():
    c = kitchen("wok", "takeout")
    to_go(c, None)  # sent by a screen that does not ask
    answer(c, "late", NAPKINS, at=900)
    assert bagged(c, "late:bag") == ["NOW IN THE BAG", "Napkins"]


def test_more_dishes_sent_with_a_new_answer_carry_it_on_their_own_ticket():
    c = kitchen("wok", "bar", "takeout")
    to_go(c, CHOPSTICKS)
    ops = [
        payload("a3", "add_line", 1000, line_id="L3", item="?", request=BEER),
        payload("more", "set_field", 1001, bag={"items": [CHOPSTICKS, NAPKINS]}),
        payload("fire2", "fire", 1002, course="*"),
    ]
    assert c.post("/orders/o1/ops", json=ops).json()["refused"] == []
    assert bagged(c, "fire2") == ["ALSO IN THE BAG", "2 x Chopsticks", "Napkins"]
    assert ticket(c, "more:bag") is None


def test_an_order_sent_ahead_prints_with_the_answer_as_it_stands_at_its_time():
    clock = [T0 + 100]
    c = future(clock)
    printing = c.app.state.printing
    # sent ahead in the morning for tonight: nothing is made until its time, three hours on
    ops = [
        payload("open", "create", 0, **PHONE, promised_at=T0 + 4 * HOUR, quoted_minutes=60),
        payload("a1", "add_line", 1, line_id="L1", item="?", request=CHICKEN),
        payload("ask", "set_field", 2, bag={"items": [FORKS]}),
        payload("fire", "fire", 3, course="*"),
    ]
    assert c.post("/orders/o1/ops", json=ops).json()["refused"] == []
    answer(c, "noon", CHOPSTICKS, at=500)  # the customer calls back: nothing is on paper, so no slip
    assert printing.store.all() == []
    clock[0] = T0 + 3 * HOUR
    assert [job.job_id for job in printing.release_due()] == ["fire:wok", "fire:takeout"]
    assert bagged(c, "fire") == ["ALSO IN THE BAG", "2 x Chopsticks"]
    # the copy a fallback printer would get says the same
    assert "2 x Chopsticks" in [
        line.strip() for line in decode(printing.store.get("fire:takeout").fallbacks[0][1]).text
    ]
    # now that it is on paper, a change is a slip
    answer(c, "evening", NAPKINS, at=600)
    assert bagged(c, "fire") == ["ALSO IN THE BAG", "2 x Chopsticks"]
    assert bagged(c, "evening:bag") == ["NOW IN THE BAG", "Napkins"]


def test_the_checks_history_says_what_was_answered_and_by_whom():
    c = kitchen("wok", "takeout")
    to_go(c, CHOPSTICKS, FORKS)
    answer(c, "less", FORKS, at=900, by="Ben", by_id="s2")
    answer(c, "same", FORKS, at=950, by="Ben", by_id="s2")  # nothing changed: no step
    steps = c.get("/orders/o1/history", headers=manager(c)).json()["steps"]
    mine = [(s["by"], s["items"], s["changed"]) for s in steps if s["what"] == "bag"]
    assert mine == [
        ("Amy", [{"name": "Chopsticks", "qty": 2}, {"name": "Forks", "qty": 1}], False),
        ("Ben", [{"name": "Forks", "qty": 1}], True),
    ]


def test_the_answer_reads_the_same_wherever_it_is_read():
    assert bag_of({}) is None and bag_of({"bag": None}) is None and bag_of({"bag": "forks"}) is None
    assert bag_of({"bag": {"items": [{"id": "a b"}]}}) is None  # one the hub would not have kept
    assert bag_of({"bag": {"items": []}}) == {"items": []}
    assert bag_lines({"items": [CHOPSTICKS, FORKS]}) == ("2 x Chopsticks", "Forks") and bag_lines({"items": []}) == ()
    # operations that say nothing of a bag pass through as they came
    ops = [Op("x1", "o1", HLC(T0, 0, "t1"), "t1", "set_field", {"guests": 2})]
    assert bag_ops(ops) == (ops, [])


def test_it_prints_big_on_both_kinds_of_printer():
    asked = replace(DEMO, table="", order_no=42, customer="Linda", bag=("2 x Chopsticks", "Forks"))
    for dialect in ("escpos", "star"):
        assert render(asked, dialect=dialect) != render(replace(asked, bag=None), dialect=dialect)
        assert render(asked, dialect=dialect) != render(replace(asked, bag=()), dialect=dialect)
    assert "ALSO IN THE BAG" not in [line.strip() for line in decode(render(DEMO)).text]
    slip = decode(render(replace(asked, kind="bag", lines=())))
    assert [line.strip() for line in slip.text][0] == "*** BAG *** WOK" and "NOW IN THE BAG" in [
        line.strip() for line in slip.text
    ]
