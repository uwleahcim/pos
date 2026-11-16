"""A screen that prints no ticket at some stations: what is sent or voided from the bar's own screen prints
nothing at the bar, since the bartender who rings a drink in makes it. A manager's setting, per screen and per
station; every screen prints everywhere to start. The rest of the order prints where it always does."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pos.printing.service import Printer
from pos.settings import DEFAULTS, SettingStore, clean_ticket_skips, skipped_stations
from pos.sync.hlc import HLC

from ..conftest import T0, servers_void
from .fake_printer import decode
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen, said
from .test_stations import manager

BAR_SCREEN = {"screens": [{"device": "bar1", "stations": ["bar"]}]}


def skipping(setting: dict, *, voids: bool = False) -> SettingStore:
    settings = servers_void() if voids else SettingStore()
    settings.put("ticket_skips", clean_ticket_skips(setting))
    return settings


def op(device: str, op_id: str, kind: str, at: int, **data) -> dict:
    return {
        "op_id": op_id,
        "order_id": "o1",
        "hlc": str(HLC(T0 + at, 0, device)),
        "device": device,
        "kind": kind,
        "data": data,
    }


def send(c: TestClient, device: str, order_id: str, *dishes: dict, at: int = 0, **how) -> str:
    """Opens the order (once) from the screen `device` with these dishes and sends them; the id the tickets
    are kept under."""
    how = how or {"table": "12", "order_type": "dine_in"}
    ops = [] if at else [op(device, f"{order_id}-open", "create", 0, **how)]
    ops += [
        op(device, f"{order_id}-{at}-{n}", "add_line", at + n, line_id=f"L{at}-{n}", item="?", request=dish)
        for n, dish in enumerate(dishes, 1)
    ]
    ops.append(op(device, f"{order_id}-{at}-fire", "fire", at + 50, course="*"))
    assert c.post(f"/orders/{order_id}/ops", json=[{**o, "order_id": order_id} for o in ops]).status_code == 202
    return ops[-1]["op_id"]


def ticket(c: TestClient, key: str, printer: str) -> list[str] | None:
    job = c.app.state.printing.store.get(f"{key}:{printer}")
    return None if job is None else decode(job.data).text


def drawn(c: TestClient, key: str, printer: str) -> int:
    """How many dishes the ticket draws as a picture: the ones the kitchen reads in Chinese (the roll, the
    chicken). The beer is plain letters, a line of text."""
    return len(decode(c.app.state.printing.store.get(f"{key}:{printer}").data).images)


# The setting -----------------------------------------------------------------------------------------------


def test_every_screen_prints_everywhere_to_start():
    assert DEFAULTS["ticket_skips"] == {"screens": []}
    assert skipped_stations(DEFAULTS["ticket_skips"], "bar1") == frozenset()
    c = kitchen("wok", "bar")
    assert c.get("/settings/ticket_skips").json() == {"screens": []}
    key = send(c, "bar1", "o1", CHICKEN, BEER)
    assert ticket(c, key, "wok") is not None and ticket(c, key, "bar") is not None


def test_the_setting_is_checked_and_tidied():
    cleaned = clean_ticket_skips(
        {
            "screens": [
                {"device": " bar1 ", "stations": ["bar", "bar", " sushi ", ""]},
                {"device": "host1", "stations": []},  # none left: the screen prints everywhere, so it is not kept
            ]
        }
    )
    assert cleaned == {"screens": [{"device": "bar1", "stations": ["bar", "sushi"]}]}
    assert skipped_stations(cleaned, "BAR1") == {"bar", "sushi"}  # whatever the case of the name
    assert skipped_stations(cleaned, "host1") == frozenset()
    assert clean_ticket_skips({}) == {"screens": []}


@pytest.mark.parametrize(
    ("bad", "why"),
    [
        ({"screens": "bar1"}, "list of"),
        ({"screens": [{"stations": ["bar"]}]}, "device name"),
        ({"screens": [{"device": "bar 1", "stations": ["bar"]}]}, "letters and digits"),
        ({"screens": [{"device": "bar1", "stations": ["bar"]}, {"device": "BAR1", "stations": ["wok"]}]}, "twice"),
        ({"screens": [{"device": "bar1", "stations": "bar"}]}, "list of station codes"),
        ({"screens": [{"device": "bar1", "stations": ["the bar"]}]}, "short code"),
    ],
)
def test_a_bad_setting_is_refused(bad: dict, why: str):
    with pytest.raises(ValueError, match=why):
        clean_ticket_skips(bad)


def test_only_a_manager_sets_it_and_the_next_send_prints_by_it():
    c = kitchen("wok", "bar")
    assert c.put("/settings/ticket_skips", json=BAR_SCREEN).status_code == 401
    saved = c.put("/settings/ticket_skips", json=BAR_SCREEN, headers=manager(c))
    assert saved.status_code == 200 and saved.json() == BAR_SCREEN
    assert c.get("/settings/ticket_skips").json() == BAR_SCREEN
    key = send(c, "bar1", "o1", BEER)
    assert ticket(c, key, "bar") is None
    refused = c.put(
        "/settings/ticket_skips", json={"screens": [{"device": "b 1", "stations": ["bar"]}]}, headers=manager(c)
    )
    assert refused.status_code == 422 and "letters and digits" in refused.json()["detail"]["message"]
    # taken off again: the screen prints at the bar like any other
    assert c.put("/settings/ticket_skips", json={"screens": []}, headers=manager(c)).json() == {"screens": []}
    assert ticket(c, send(c, "bar1", "o1", BEER, at=100), "bar") is not None


# What prints -------------------------------------------------------------------------------------------------


def test_a_drink_rung_at_the_bars_own_screen_prints_no_ticket_at_the_bar():
    c = kitchen("wok", "sushi", "bar", settings=skipping(BAR_SCREEN))
    key = send(c, "bar1", "o1", BEER)
    assert ticket(c, key, "bar") is None
    assert c.app.state.printing.store.pending() == []  # and nowhere else either: nothing is waiting to print
    # the same drink from a server's screen prints at the bar as ever
    served = send(c, "t1", "o2", BEER)
    assert "Tsingtao" in " ".join(ticket(c, served, "bar"))


def test_the_food_of_the_same_send_still_prints_and_its_tickets_do_not_count_the_bar():
    c = kitchen("wok", "sushi", "bar", settings=skipping(BAR_SCREEN))
    key = send(c, "bar1", "o1", CHICKEN, ROLL, BEER)
    assert ticket(c, key, "bar") is None
    assert said(c, key, "wok") == ["Ticket 1 of 2", "Also at: Sushi bar"]
    assert said(c, key, "sushi") == ["Ticket 2 of 2", "Also at: Wok"]
    assert not any("Tsingtao" in line for line in ticket(c, key, "wok") + ticket(c, key, "sushi"))
    # one station left cooking: its ticket stands alone
    assert said(c, send(c, "bar1", "o2", CHICKEN, BEER), "wok") == []


def test_the_first_printer_does_not_take_a_skipped_station_that_has_no_printer():
    c = kitchen("wok", "sushi", settings=skipping(BAR_SCREEN))  # no bar printer: the wok's stands in for it
    assert "Tsingtao" in " ".join(ticket(c, send(c, "t1", "o1", BEER), "wok"))
    assert ticket(c, send(c, "bar1", "o2", BEER), "wok") is None
    food = ticket(c, send(c, "bar1", "o3", CHICKEN, BEER), "wok")
    assert food is not None and not any("Tsingtao" in line for line in food)


def test_a_printer_for_two_stations_leaves_only_the_skipped_ones_dishes_off():
    c = kitchen("wok", Printer("bar", "10.0.0.2", id="front", stations=("bar", "sushi")), settings=skipping(BAR_SCREEN))
    key = send(c, "bar1", "o1", ROLL, BEER)
    assert drawn(c, key, "front") == 1 and "1 x Tsingtao" not in ticket(c, key, "front")  # the roll alone
    key = send(c, "t1", "o2", ROLL, BEER)
    assert drawn(c, key, "front") == 1 and "1 x Tsingtao" in ticket(c, key, "front")  # both, from a server's


def test_a_screen_can_skip_several_stations_and_each_screen_has_its_own_list():
    both = {
        "screens": [
            {"device": "bar1", "stations": ["bar", "sushi"]},
            {"device": "sushi1", "stations": ["sushi"]},
        ]
    }
    c = kitchen("wok", "sushi", "bar", settings=skipping(both))
    key = send(c, "bar1", "o1", CHICKEN, ROLL, BEER)
    assert (ticket(c, key, "bar"), ticket(c, key, "sushi")) == (None, None) and ticket(c, key, "wok") is not None
    key = send(c, "sushi1", "o2", CHICKEN, ROLL, BEER)
    assert ticket(c, key, "sushi") is None
    assert said(c, key, "wok") == ["Ticket 1 of 2", "Also at: Bar"]


def test_the_bag_of_a_to_go_order_still_lists_the_drink():
    c = kitchen("wok", "bar", "takeout", settings=skipping(BAR_SCREEN))
    to_go = {"order_type": "takeout", "channel": "counter", "customer_name": "Linda"}
    key = send(c, "bar1", "o1", CHICKEN, BEER, **to_go)
    assert ticket(c, key, "bar") is None
    assert "1 x Tsingtao" in ticket(c, key, "takeout") and drawn(c, key, "takeout") == 1  # the beer and the chicken
    assert said(c, key, "takeout") == ["Also at: Wok"]
    # a screen that skips the takeout station prints no copy for the bag
    counter = {"screens": [{"device": "counter1", "stations": ["takeout"]}]}
    c = kitchen("wok", "bar", "takeout", settings=skipping(counter))
    key = send(c, "counter1", "o1", CHICKEN, BEER, **to_go)
    assert ticket(c, key, "takeout") is None
    assert ticket(c, key, "wok") is not None and ticket(c, key, "bar") is not None


def test_a_void_from_the_bars_screen_prints_nothing_at_the_bar_and_one_from_another_screen_does():
    c = kitchen("wok", "bar", settings=skipping(BAR_SCREEN, voids=True))
    send(c, "t1", "o1", CHICKEN, BEER)  # a server sent both: the bar has a ticket for the beer
    at_bar = [op("bar1", "v1", "void_line", 200, line_id="L0-2", reason="rung-in-wrong")]
    assert c.post("/orders/o1/ops", json=at_bar).status_code == 202
    assert ticket(c, "v1", "bar") is None  # the bartender took it off: nobody else needs telling
    send(c, "bar1", "o1", BEER, at=300)  # rung at the bar: no ticket
    elsewhere = [op("t1", "v2", "void_line", 500, line_id="L300-1", reason="rung-in-wrong")]
    assert c.post("/orders/o1/ops", json=elsewhere).status_code == 202
    assert "*** VOID *** BAR" in ticket(c, "v2", "bar")  # a server took it off: the bar hears of it
    # and the food voided from the bar's screen still tells the wok
    food = [op("bar1", "v3", "void_line", 600, line_id="L0-1", reason="kitchen-error")]
    assert c.post("/orders/o1/ops", json=food).status_code == 202
    assert "*** VOID *** WOK" in ticket(c, "v3", "wok")


def test_an_allergy_told_afterwards_still_prints_at_the_bar():
    c = kitchen("wok", "bar", settings=skipping(BAR_SCREEN))
    send(c, "bar1", "o1", CHICKEN, BEER)
    told = [op("bar1", "a1", "allergy", 200, seat=None, allergens=["peanut"], note="")]
    assert c.post("/orders/o1/ops", json=told).status_code == 202
    for station in ("wok", "bar"):
        text = " ".join(ticket(c, "a1", station))
        assert "ALLERGY" in text


def test_the_order_and_its_check_are_the_same_whichever_screen_sent_it():
    plain, skips = kitchen("wok", "bar"), kitchen("wok", "bar", settings=skipping(BAR_SCREEN))
    for c in (plain, skips):
        send(c, "bar1", "o1", CHICKEN, BEER)
    a, b = plain.get("/orders/o1").json(), skips.get("/orders/o1").json()
    assert a["lines"] == b["lines"] and all(line["fired"] for line in b["lines"].values())
    assert plain.get("/orders/o1/check").json() == skips.get("/orders/o1/check").json()
