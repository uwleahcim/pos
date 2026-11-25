"""Points: what the guest who pays a check earns on it (docs/points.md).

Where the owner set a rate, the guest whose money a check is (`pos.orders.guests.payer_of`) earns points on
it: so many a dollar of what it came to before tax, less comps and discounts, once the check is closed.
What earns and how long points last are the owner's rules, all of them a setting, and nobody earns until
somebody sets a rate. A rule set counts from the day it was saved, so no point already earned moves when the
rate does. Points are read off the orders like the guest list itself: nothing is kept for them, and nothing
is taken off any check, bill, sale or report by them."""

from __future__ import annotations

from datetime import date, timedelta
from decimal import Decimal

import pytest

from pos.orders.guests import Visit, visit_of
from pos.orders.points import (
    CATERING,
    DAYS_LEAST,
    DAYS_MOST,
    GONE,
    KIND,
    NOTHING,
    OFF,
    OPEN,
    OTHER,
    PER_DOLLAR_MOST,
    WAITS,
    Points,
    Rule,
    rate_text,
    tally,
)
from pos.orders.sales import class_net
from pos.reservations import Reservations
from pos.waitlist import Waitlist

from .test_check_guests import NOVAK, check
from .test_day import BEER, DSN, EGGROLL, WINGS, Hub, at
from .test_guest_tags import book_table, seat, wait
from .test_guests import GTC, LINDA, OMAR, SAM, TODAY, a_year, ago, guest, guests, one, order
from .test_who_paid_after import said_after
from .test_who_pays import said, who_sits

EVERY = ("l1", "l2", "l3", "l4", "l5", "m1", "m2", "m3", "m4", "p1", "p2", "p3", "s1", "s2", "t1", "t2")
"""Every order of the year's guests (`a_year`)."""


def rules(h: Hub) -> dict:
    answer = h.c.get("/settings/points")
    assert answer.status_code == 200, answer.text
    return answer.json()


def put(h: Hub, **body):
    """A manager saves the rules: the hub's answer as it came."""
    return h.c.put("/settings/points", json=body, headers=h.manager())


def save(h: Hub, **body) -> dict:
    answer = put(h, **body)
    assert answer.status_code == 200, answer.text
    return answer.json()


def close(h: Hub, *order_ids: str) -> None:
    for order_id in order_ids:
        h.op(order_id, "close", h.now + 1)


def a_year_of_points(rate: str = "1", **more) -> Hub:
    """The year's guests on a hub where the rate was set before any of them came, every check closed, read
    on Monday the 16th at nine in the evening."""
    h = Hub(now=ago(500))
    save(h, per_dollar=rate, **more)
    a_year(h)
    h.now = at(20)
    close(h, *EVERY)
    h.now = at(21)
    return h


def has(h: Hub, phone: str) -> int:
    """How many points the guest list says this guest has."""
    return guest(guests(h), phone)["points"]


def earned(h: Hub, phone: str) -> dict[str, tuple[int, str]]:
    """What each of their latest visits earned, and why nothing where it earned nothing."""
    return {visit["order_id"]: (visit["points"], visit["points_why"]) for visit in one(h, phone)["latest"]}


def looked_up(h: Hub, phone: str) -> dict:
    answer = h.c.get("/customers/lookup", params={"phone": phone})
    assert answer.status_code == 200, answer.text
    return answer.json()


def another(h: Hub, order_id: str, when: int, *dishes: dict | tuple[dict, int], **fields) -> None:
    """Linda's order of another kind than a phoned-in pickup: the fields say which."""
    made = {"order_type": "takeout", "customer_name": "Linda", "channel": "phone", "phone": LINDA, **fields}
    h.op(order_id, "create", when, **made)
    for i, rung in enumerate(dishes, 1):
        request, qty = rung if isinstance(rung, tuple) else (rung, 1)
        h.ring(order_id, f"L{i}", request, when + i * 1000, qty=qty)


# --- off until somebody sets a rate ----------------------------------------------------------------------------


def test_nobody_earns_a_point_until_somebody_sets_a_rate():
    h = a_year()
    close(h, *EVERY)
    told = rules(h)
    assert (told["on"], told["ever"], told["per_dollar"], told["days"]) == (False, False, "0", 365)
    assert (told["from"], told["by"], told["since"], told["earlier"]) == (None, "", None, [])
    # what would earn once a rate is set: everything but alcoholic drinks
    assert [told[name] for name in ("dine_in", "takeout", "delivery", "catering", "alcohol")] == [True] * 4 + [False]
    assert (told["per_dollar_most"], told["days_least"], told["days_most"]) == ("100", DAYS_LEAST, DAYS_MOST)
    assert told["today"] == "2026-11-16"
    report = guests(h)
    assert report["points"]["on"] is False and report["points"]["ever"] is False
    assert all(row["points"] == 0 for row in report["guests"]) and report["totals"]["points"] == 0
    close_up = one(h, LINDA)
    assert close_up["points_next"] is None
    assert {(visit["points"], visit["points_why"]) for visit in close_up["latest"]} == {(0, OFF)}
    # the staff's screens are told nothing: there is nothing to show
    assert looked_up(h, LINDA)["points"] is None


def test_the_rules_are_a_managers_to_set_and_anybodys_to_read():
    h = a_year()
    assert h.c.put("/settings/points", json={"per_dollar": "1"}).status_code == 401
    assert (
        h.c.put("/settings/points", json={"per_dollar": "1"}, headers={"authorization": "Bearer x"}).status_code == 401
    )
    assert rules(h)["on"] is False
    assert h.c.get("/settings/points").status_code == 200  # the screens read it without a token


@pytest.mark.parametrize(
    "body",
    [
        {"per_dollar": "-1"},
        {"per_dollar": "100.01"},
        {"per_dollar": "1.005"},
        {"per_dollar": "a lot"},
        {"per_dollar": "NaN"},
        {"per_dollar": "1", "days": DAYS_LEAST - 1},
        {"per_dollar": "1", "days": DAYS_MOST + 1},
        {"per_dollar": "1", "dine_in": False, "takeout": False, "delivery": False},
    ],
)
def test_a_rule_that_is_no_rule_is_refused_in_words(body):
    h = a_year()
    answer = put(h, **body)
    assert answer.status_code == 422, answer.text
    assert answer.json()["detail"]["error"] == "bad_value" and answer.json()["detail"]["message"]
    assert rules(h)["on"] is False  # nothing was saved


# --- earning ----------------------------------------------------------------------------------------------------


def test_the_guest_who_pays_earns_so_many_points_a_dollar_on_a_closed_check():
    h = a_year_of_points("1")
    told = rules(h)
    assert (told["on"], told["per_dollar"], told["by"]) == (True, "1", "Mike")
    assert told["from"] == told["since"] == (TODAY - timedelta(days=500)).isoformat()
    # each check rounded down: 17.45, 27.90, 20.95 of food beside a 6.50 beer, 22.90, 13.95
    assert earned(h, LINDA) == {"l5": (13, ""), "l4": (22, ""), "l3": (20, ""), "l2": (27, ""), "l1": (17, "")}
    assert has(h, LINDA) == 99
    report = guests(h)
    assert report["points"]["on"] is True and report["points"]["per_dollar"] == "1"
    assert report["totals"]["points"] == sum(row["points"] for row in report["guests"]) > 99
    # the staff's screens are told how many, and no more than that
    assert looked_up(h, LINDA)["points"] == 99
    assert looked_up(h, "7815550999")["points"] == 0  # a number that never ordered has none


def test_a_rate_can_be_a_part_of_a_point_and_a_check_is_rounded_down():
    h = a_year_of_points("1.5")
    # 17.45 * 1.5 = 26.175, 27.90 * 1.5 = 41.85, 20.95 * 1.5 = 31.425, 22.90 * 1.5 = 34.35, 13.95 * 1.5 = 20.925
    assert earned(h, LINDA) == {"l5": (20, ""), "l4": (34, ""), "l3": (31, ""), "l2": (41, ""), "l1": (26, "")}
    assert rules(h)["per_dollar"] == "1.5"


def test_an_open_check_earns_nothing_yet_and_a_voided_one_nothing_at_all():
    h = Hub(now=ago(40))
    save(h, per_dollar="1")
    order(h, "l1", ago(30), LINDA, "Linda", GTC, EGGROLL)
    order(h, "l2", ago(3), LINDA, "Linda", GTC)
    h.now = at(21)
    assert earned(h, LINDA) == {"l2": (0, OPEN), "l1": (0, OPEN)} and has(h, LINDA) == 0
    close(h, "l1")
    assert earned(h, LINDA) == {"l2": (0, OPEN), "l1": (17, "")} and has(h, LINDA) == 17
    # reopened and a dish added: it earns again when it is closed, by what it comes to then
    h.op("l1", "reopen", h.now + 1)
    assert has(h, LINDA) == 0
    h.ring("l1", "L9", WINGS, h.now + 1)
    close(h, "l1")
    assert earned(h, LINDA)["l1"] == (26, "")  # 17.45 + 8.95
    h.op("l1", "void_order", h.now + 1)
    assert "l1" not in earned(h, LINDA) and has(h, LINDA) == 0  # no visit, no points


def test_what_came_off_a_check_earns_nothing():
    h = Hub(now=ago(40))
    save(h, per_dollar="2")
    order(h, "l1", ago(3), LINDA, "Linda", GTC, EGGROLL)  # 17.45
    h.op("l1", "discount", h.now + 1, discount_id="D1", reason="loyalty", kind="amount", value="5.00", applied_by="Amy")
    close(h, "l1")
    h.now = at(21)
    assert earned(h, LINDA) == {"l1": (24, "")}  # 12.45 * 2 = 24.9
    h.op("l1", "reopen", h.now + 1)
    h.op("l1", "remove_discount", h.now + 1, discount_id="D1")
    approval = h.c.post("/approvals", json={"device": "t1", "pin": "9999", "order_id": "l1"}).json()["approval"]
    h.op("l1", "discount", h.now + 1, discount_id="D2", reason="comp", kind="comp", approval=approval, applied_by="Amy")
    close(h, "l1")
    assert earned(h, LINDA) == {"l1": (0, NOTHING)} and has(h, LINDA) == 0  # a check comped whole came to nothing


# --- a rule set counts from its day ----------------------------------------------------------------------------


def test_a_rate_changed_today_moves_no_point_already_earned():
    h = Hub(now=ago(150))
    first = save(h, per_dollar="1")
    assert first["from"] == first["since"] == (TODAY - timedelta(days=150)).isoformat()
    order(h, "l1", ago(120), LINDA, "Linda", (GTC, 2))  # 27.90
    h.now = ago(60)
    second = save(h, per_dollar="2")
    assert (second["per_dollar"], second["from"]) == ("2", (TODAY - timedelta(days=60)).isoformat())
    assert second["since"] == first["since"]  # points are earned since the first rate
    assert [(was["per_dollar"], was["from"], was["until"]) for was in second["earlier"]] == [
        ("1", first["from"], (TODAY - timedelta(days=61)).isoformat())
    ]
    order(h, "l2", ago(30), LINDA, "Linda", (GTC, 2))
    h.now = at(20)
    close(h, "l1", "l2")
    assert earned(h, LINDA) == {"l2": (55, ""), "l1": (27, "")}  # the same check: twice the points since the 60th day
    # turned off today: nothing more is earned, and what was earned stays
    off = save(h, per_dollar="0")
    assert (off["on"], off["ever"], off["from"]) == (False, True, "2026-11-16")
    order(h, "l3", at(20, 30), LINDA, "Linda", GTC)
    close(h, "l3")
    assert earned(h, LINDA) == {"l3": (0, OFF), "l2": (55, ""), "l1": (27, "")} and has(h, LINDA) == 82
    assert looked_up(h, LINDA)["points"] == 82


def test_a_day_has_one_version_and_a_save_that_changes_nothing_makes_none():
    h = Hub(now=ago(10))
    kept = lambda: h.c.app.state.settings.get("points")["rules"]  # noqa: E731
    save(h, per_dollar="1")
    save(h, per_dollar="3")  # the same day: in its place
    assert [(rule["per_dollar"], rule["from"]) for rule in kept()] == [("3", (TODAY - timedelta(days=10)).isoformat())]
    h.now = ago(5)
    save(h, per_dollar="3", days=90)  # how long they last is no version
    assert len(kept()) == 1 and rules(h)["days"] == 90
    save(h, per_dollar="4", alcohol=True)
    save(h, per_dollar="3", alcohol=False)  # and back, the same day: the version of that day is gone again
    assert len(kept()) == 1 and rules(h)["earlier"] == []
    save(h, takeout=False)  # what is left out stays as it is
    now = rules(h)
    assert (now["per_dollar"], now["takeout"], now["dine_in"], now["days"]) == ("3", False, True, 90)
    assert len(kept()) == 2
    # a rate of nothing where there never was one is no version either
    fresh = Hub()
    assert save(fresh, per_dollar="0", days=60)["days"] == 60
    assert fresh.c.app.state.settings.get("points")["rules"] == []


# --- what earns --------------------------------------------------------------------------------------------------


def test_alcoholic_drinks_earn_only_where_the_owner_said_so():
    h = a_year_of_points("1")
    assert rules(h)["alcohol"] is False and earned(h, LINDA)["l3"] == (20, "")  # 27.45 with a 6.50 beer
    h = a_year_of_points("1", alcohol=True)
    assert earned(h, LINDA)["l3"] == (27, "") and has(h, LINDA) == 106


def test_a_check_of_drinks_alone_earns_nothing_unless_drinks_earn():
    h = Hub(now=ago(10))
    save(h, per_dollar="1")
    order(h, "l1", ago(3), LINDA, "Linda", (BEER, 2))
    close(h, "l1")
    h.now = at(21)
    assert earned(h, LINDA) == {"l1": (0, NOTHING)}


def test_a_discount_on_the_whole_check_comes_off_food_and_drinks_alike():
    lines = [
        {"total": "20.00", "discount": "0.00", "tax_class": "prepared_food"},
        {"total": "10.00", "discount": "2.00", "tax_class": "alcohol"},
        {"total": "12.00", "discount": "0.00", "tax_class": "alcohol"},
    ]
    assert class_net({"lines": lines, "discount_total": "2.00"}, "alcohol") == Decimal("20.00")
    # 10.00 more off the check: half of what is left is drinks, so 5.00 of it is theirs
    assert class_net({"lines": lines, "discount_total": "12.00"}, "alcohol") == Decimal("15.00")
    assert class_net({"lines": lines, "discount_total": "12.00"}, "prepared_food") == Decimal("15.00")
    assert class_net({"lines": lines[:1], "discount_total": "0.00"}, "alcohol") == 0
    assert class_net({"lines": [], "discount_total": "0.00"}, "alcohol") == 0
    everything = {"lines": lines[1:], "discount_total": "22.00"}  # comped whole
    assert class_net(everything, "alcohol") == 0


def test_each_kind_of_order_earns_or_does_not_as_the_owner_set_it():
    h = Hub(now=ago(40))
    save(h, per_dollar="1", takeout=False)
    order(h, "g1", ago(20), LINDA, "Linda", GTC)  # to go: 13.95
    another(h, "d1", ago(19), GTC, order_type="delivery", address="12 Elm St")
    h.table("t1", ago(18), table="A7")
    h.ring("t1", "L1", GTC, ago(18) + 1)
    h.op("t1", "set_field", ago(18) + 2, phone=LINDA, customer_name="Linda")
    another(h, "c1", ago(17), (GTC, 10), channel="catering")  # to go, and catering: 139.50
    h.now = at(20)
    close(h, "g1", "d1", "t1", "c1")
    assert earned(h, LINDA) == {"c1": (0, KIND), "t1": (13, ""), "d1": (13, ""), "g1": (0, KIND)}
    h.now = at(21)
    save(h, takeout=True, delivery=False, dine_in=False, catering=False)
    another(h, "g2", h.now + 1, GTC)
    another(h, "d2", h.now + 1, GTC, order_type="delivery", address="12 Elm St")
    another(h, "c2", h.now + 1, (GTC, 10), channel="catering")
    h.table("t2", h.now + 1, table="A8")
    h.ring("t2", "L1", GTC, h.now + 1)
    h.op("t2", "set_field", h.now + 1, phone=LINDA, customer_name="Linda")
    close(h, "g2", "d2", "c2", "t2")
    told = earned(h, LINDA)
    assert (told["g2"], told["d2"], told["c2"], told["t2"]) == ((13, ""), (0, KIND), (0, CATERING), (0, KIND))
    assert (told["t1"], told["g1"]) == ((13, ""), (0, KIND))  # the earlier days as they were earned


def test_a_bar_tab_counts_with_the_tables():
    rule = Rule(date(2026, 1, 1), Decimal(1), dine_in=True, takeout=False, delivery=False)
    assert rule.earns_kind("dine_in") and rule.earns_kind("tab")
    assert not rule.earns_kind("takeout") and not rule.earns_kind("delivery") and not rule.earns_kind("pickup")


# --- how long points last --------------------------------------------------------------------------------------


def test_points_last_as_long_as_the_owner_set_and_a_year_at_most():
    h = a_year_of_points("1")
    assert rules(h)["days"] == 365 and has(h, LINDA) == 99
    # of her points the ones of her oldest check stop counting first: its day, and 364 more
    assert one(h, LINDA)["points_next"] == {"points": 17, "until": "2027-04-29"}
    save(h, days=100)
    assert earned(h, LINDA) == {"l5": (13, ""), "l4": (22, ""), "l3": (20, ""), "l2": (0, GONE), "l1": (0, GONE)}
    assert has(h, LINDA) == 55 and looked_up(h, LINDA)["points"] == 55
    assert one(h, LINDA)["points_next"] == {"points": 20, "until": "2027-01-24"}  # the 17th of October and 99 days
    # Omar came last in April: he is in the list, and has none left
    assert has(h, OMAR) == 0 and one(h, OMAR)["points_next"] is None
    save(h, days=365)
    assert has(h, LINDA) == 99 and has(h, OMAR) > 0  # nothing was thrown away: they are read off the orders


def test_the_last_day_points_count_is_the_day_before_they_are_as_old_as_they_last():
    kept = Points((Rule(date(2026, 1, 1), Decimal(1)),), days=30)
    day = date(2026, 3, 1)
    assert kept.good_until(day) == date(2026, 3, 30)
    assert kept.counts(day, date(2026, 3, 30)) and not kept.counts(day, date(2026, 3, 31))
    assert not kept.counts(day, date(2026, 2, 28))  # a check for a day still to come


# --- who pays ---------------------------------------------------------------------------------------------------


def a_table_of_two(h: Hub) -> tuple[str, str]:
    """Linda (from her reservation) and the Novaks (from the waitlist) on one check of 17.45, closed: what
    the hub knows each party by."""
    state = h.c.app.state
    state.reservations = Reservations(now_ms=lambda: h.now)
    state.waitlist = Waitlist(now_ms=lambda: h.now)
    check(h, "t-1", "A7", GTC, EGGROLL)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1", table="A7")
    h.now += 60_000
    seat(h, wait(h, "Novak", NOVAK)["party"], "t-1", table="A7", book="waitlist")
    linda, novak = who_sits(h, "t-1")["parties"]
    return linda["key"], novak["key"]


def test_at_a_table_of_several_guests_the_points_are_the_one_who_pays():
    h = a_year_of_points("1")
    linda, novak = a_table_of_two(h)
    close(h, "t-1")
    # nobody said who pays: the check's money is nobody's, and so are its points
    assert has(h, LINDA) == 99 and has(h, NOVAK) == 0
    assert earned(h, NOVAK) == {"t-1": (0, WAITS)} and earned(h, LINDA)["t-1"] == (0, WAITS)
    said(h, "t-1", novak)
    assert has(h, NOVAK) == 17 and has(h, LINDA) == 99
    assert earned(h, NOVAK) == {"t-1": (17, "")} and earned(h, LINDA)["t-1"] == (0, OTHER)
    # the table's check says how many each guest has, to whoever serves it: a count and no number
    told = h.c.get("/orders/t-1/seated")
    assert [(party["name"], party["points"]) for party in told.json()["parties"]] == [("Linda P.", 99), ("Novak", 17)]
    assert not any(phone in told.text for phone in (LINDA, NOVAK, "555"))
    # no, Linda paid: said afterwards from the guest list, and the points go with the money
    said_after(h, "t-1", linda)
    assert has(h, LINDA) == 116 and has(h, NOVAK) == 0
    assert earned(h, LINDA)["t-1"] == (17, "") and earned(h, NOVAK) == {"t-1": (0, OTHER)}


def test_a_party_that_left_no_number_has_no_points_to_show():
    h = a_year_of_points("1")
    state = h.c.app.state
    state.reservations = Reservations(now_ms=lambda: h.now)
    state.waitlist = Waitlist(now_ms=lambda: h.now)
    check(h, "t-1", "A7", GTC)
    seat(h, book_table(h, "Wu")["booking"], "t-1", table="A7")
    assert [(party["name"], party["points"]) for party in who_sits(h, "t-1")["parties"]] == [("Wu", None)]


def test_a_check_still_open_at_its_table_says_what_the_guest_had_before_it():
    h = a_year_of_points("1")
    state = h.c.app.state
    state.reservations = Reservations(now_ms=lambda: h.now)
    state.waitlist = Waitlist(now_ms=lambda: h.now)
    check(h, "t-1", "A7", GTC, EGGROLL)
    seat(h, book_table(h, "Linda P.", LINDA)["booking"], "t-1", table="A7")
    assert who_sits(h, "t-1")["parties"][0]["points"] == 99  # the open check is not in it yet
    close(h, "t-1")
    assert who_sits(h, "t-1")["parties"][0]["points"] == 116


# --- nothing else moves ---------------------------------------------------------------------------------------


def test_points_take_nothing_off_any_check_and_move_no_figure():
    h = a_year()
    close(h, *EVERY)
    before = (h.check("l3"), h.report(), {key: value for key, value in guests(h).items() if key != "points"})
    kept = dict(h.c.app.state.settings._data)
    save(h, per_dollar="5", alcohol=True, days=200)
    # the setting, and nothing else, was written
    now = dict(h.c.app.state.settings._data)
    assert set(now) - set(kept) == {"points"} and all(now[key] == kept[key] for key in kept)
    after = (h.check("l3"), h.report(), {key: value for key, value in guests(h).items() if key != "points"})
    assert after == before  # the rate was set tonight: the year's checks earned under no rule


def test_the_list_reads_the_same_as_the_visits_reckoned_one_by_one():
    h = a_year_of_points("1.25", alcohol=True)
    state = h.c.app.state
    held = Points.of(state.settings.get("points"))
    report = guests(h)
    for phone in (LINDA, OMAR, SAM):
        visits = [visit_of(h.store.view(order_id), state.taxes, state.pricing) for order_id in EVERY]
        mine = [visit for visit in visits if visit is not None and visit.phone == phone]
        assert guest(report, phone)["points"] == tally(mine, held, TODAY).points > 0
    assert guests(h) == report  # read again from what the hub remembers


# --- the rules themselves ---------------------------------------------------------------------------------------


def a_visit(day: date, net: str = "20.00", **more) -> Visit:
    fields = {"paid": True, "closed": True, **more}
    return Visit(LINDA, "o1", 1, day, 0, Decimal(net), "Linda", fields.pop("kind", "takeout"), (), **fields)


def test_what_is_kept_is_read_with_care():
    assert Points.of(None) == Points() and Points.of({}) == Points()
    junk = {
        "rules": [
            "one",
            {"from": "not a day", "per_dollar": "1"},
            {"from": "2026-03-01", "per_dollar": "many"},
            {"from": "2026-03-01", "per_dollar": "500"},
            {"from": "2026-05-01", "per_dollar": "2", "alcohol": "yes", "takeout": 0, "by": " Mike \n L. "},
            {"from": "2026-02-01", "per_dollar": 1},
        ],
        "days": "forever",
    }
    read = Points.of(junk)
    assert [(rule.since.isoformat(), rate_text(rule.per_dollar)) for rule in read.rules] == [
        ("2026-02-01", "1"),
        ("2026-05-01", "2"),
    ]
    assert read.days == DAYS_MOST
    late = read.rules[1]
    assert (late.alcohol, late.takeout, late.by) == (False, True, "Mike L.")  # only true and false are switches
    assert read.on(date(2026, 1, 31)) is None and read.on(date(2026, 2, 1)) is read.rules[0]
    assert read.on(date(2026, 4, 30)) is read.rules[0] and read.on(date(2026, 5, 1)) is late
    assert Points.of(read.stored()) == read
    assert (
        rate_text(Decimal("1.50")),
        rate_text(Decimal("0.25")),
        rate_text(Decimal("100")),
        rate_text(Decimal(0)),
    ) == (
        "1.5",
        "0.25",
        "100",
        "0",
    )
    assert PER_DOLLAR_MOST == 100


def test_why_a_visit_earned_nothing_is_said_in_one_word():
    kept = Points((Rule(date(2026, 6, 1), Decimal(2), catering=False, delivery=False),), days=60)
    today = date(2026, 8, 1)
    day = date(2026, 7, 20)
    assert kept.earned(a_visit(day), today) == (40, "")
    assert kept.earned(a_visit(date(2026, 5, 31)), today) == (0, OFF)  # before the first rule
    assert kept.earned(a_visit(day, paid=False, waits=True), today) == (0, WAITS)
    assert kept.earned(a_visit(day, paid=False), today) == (0, OTHER)
    assert kept.earned(a_visit(day, closed=False), today) == (0, OPEN)
    assert kept.earned(a_visit(day, catering=True), today) == (0, CATERING)
    assert kept.earned(a_visit(day, kind="delivery"), today) == (0, KIND)
    assert kept.earned(a_visit(day, net="0.40"), today) == (0, NOTHING)
    assert kept.earned(a_visit(day, alcohol=Decimal("20.00")), today) == (0, NOTHING)
    assert kept.earned(a_visit(day, alcohol=Decimal("5.50")), today) == (29, "")
    assert kept.earned(a_visit(date(2026, 6, 2)), today) == (0, GONE)  # sixty days and more ago
    assert kept.earned(a_visit(date(2026, 6, 3)), today) == (40, "")
    # a rule that earns nothing is off, whatever else it says
    assert Points((Rule(date(2026, 6, 1)),)).earned(a_visit(day), today) == (0, OFF)


def test_old_versions_are_dropped_once_no_check_can_count_under_them():
    kept = Points()
    day = date(2025, 1, 1)
    for n in range(70):
        kept = kept.saved({"per_dollar": str(1 + n % 3)}, today=day + timedelta(days=n * 10), by="Mike")
    last = day + timedelta(days=690)
    # the one in force four hundred days before the last save, and every later one
    assert kept.rules[0].since <= last - timedelta(days=400) < kept.rules[1].since
    assert kept.rules[-1].since == last and len(kept.rules) == 41
    assert kept.on(last - timedelta(days=399)) is kept.rules[0]


# --- PostgreSQL --------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_points_are_read_the_same_from_postgres():
    import psycopg

    from pos.settings import PgSettingStore

    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders, setting")
    h = Hub(now=ago(500), postgres=DSN)
    settings = PgSettingStore(DSN)
    try:
        h.c.app.state.settings = settings
        save(h, per_dollar="1")
        a_year(h)
        h.now = at(20)
        close(h, *EVERY)
        h.now = at(21)
        assert has(h, LINDA) == 99 and looked_up(h, LINDA)["points"] == 99
        save(h, per_dollar="2", days=100)
        assert has(h, LINDA) == 55  # the rate of today moves nothing; how long they last does
        assert [rule["per_dollar"] for rule in settings.get("points")["rules"]] == ["1", "2"]
    finally:
        settings.close()
        h.store.close()
        with psycopg.connect(DSN, autocommit=True) as conn:
            conn.execute("DROP TABLE IF EXISTS ops, orders, setting")
