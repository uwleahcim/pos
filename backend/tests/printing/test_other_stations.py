"""What a ticket says about the other tickets of the same send: "Ticket 2 of 3", and "Also at: Wok, Bar" for
the stations cooking the rest. Each is the location's to turn off. The takeout counter packs and does not
cook, so it is neither counted nor named, and reads where the food is coming from."""

from __future__ import annotations

from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.service import Printer, PrintService
from pos.printing.ticket import DEMO, render
from pos.settings import SettingStore, clean_tickets
from pos.sync.oplog import OpStore

from ..conftest import T0, servers_void
from ..orders.test_menu_orders import GTC_QUART, payload
from .fake_printer import decode
from .test_stations import manager, menu_with_takeout

CHICKEN = {"variant_id": "GTC:quart", "entry_id": "dinner:87", "selections": []}  # the wok
ROLL = {"variant_id": "CALROLL:roll"}  # the sushi bar
BEER = {"variant_id": "TSINGTAO:bottle"}  # the bar


def kitchen(*printers: Printer | str, settings: SettingStore | None = None) -> TestClient:
    """A hub with these printers (a station's code is a printer for it), their tickets kept and not sent."""
    made = [p if isinstance(p, Printer) else Printer(p, f"10.0.0.{n}", id=p) for n, p in enumerate(printers, 1)]
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=PrintService(made, direct=False),
            settings=settings or SettingStore(),
        )
    )


def send(c: TestClient, order_id: str, *dishes: dict, at: int = 0, **how) -> str:
    """Opens the order (once) with these dishes and sends them; the id the tickets are kept under."""
    how = how or {"table": "12", "order_type": "dine_in"}
    ops = [] if at else [payload(f"{order_id}-open", "create", 0, **how)]
    ops += [
        payload(f"{order_id}-{at}-{n}", "add_line", at + n, line_id=f"L{at}-{n}", item="?", request=dish)
        for n, dish in enumerate(dishes, 1)
    ]
    ops.append(payload(f"{order_id}-{at}-fire", "fire", at + 50, course="*"))
    assert c.post(f"/orders/{order_id}/ops", json=[{**op, "order_id": order_id} for op in ops]).status_code == 202
    return ops[-1]["op_id"]


def said(c: TestClient, key: str, printer: str) -> list[str]:
    """What the printer's ticket for that send says of the others: its "Ticket" and "Also at" lines."""
    job = c.app.state.printing.store.get(f"{key}:{printer}")
    assert job is not None, f"no ticket at {printer}"
    return [line for line in decode(job.data).text if line.startswith(("Ticket ", "Also at"))]


def test_each_ticket_says_which_it_is_and_names_the_other_stations():
    c = kitchen("wok", "sushi", "bar")
    key = send(c, "o1", CHICKEN, ROLL, BEER)
    assert said(c, key, "wok") == ["Ticket 1 of 3", "Also at: Sushi bar, Bar"]
    assert said(c, key, "sushi") == ["Ticket 2 of 3", "Also at: Wok, Bar"]
    assert said(c, key, "bar") == ["Ticket 3 of 3", "Also at: Wok, Sushi bar"]
    # last before the dishes, under the table and the course
    text = decode(c.app.state.printing.store.get(f"{key}:wok").data).text
    assert text[text.index("Also at: Sushi bar, Bar") + 1] == "-" * 48
    assert text.index("Table 12") < text.index("Ticket 1 of 3")


def test_a_send_with_one_station_cooking_says_neither():
    c = kitchen("wok", "sushi", "bar")
    assert said(c, send(c, "o1", CHICKEN, CHICKEN), "wok") == []


def test_only_the_tickets_of_the_same_send_count():
    c = kitchen("wok", "sushi", "bar")
    first = send(c, "o1", CHICKEN, ROLL)
    assert said(c, first, "wok") == ["Ticket 1 of 2", "Also at: Sushi bar"]
    later = send(c, "o1", BEER, at=100)  # the beer goes alone: the wok and the sushi bar had theirs
    assert said(c, later, "bar") == []
    assert c.app.state.printing.store.get(f"{later}:wok") is None


def test_a_printer_for_two_stations_is_one_ticket_named_by_what_it_cooks():
    c = kitchen(Printer("wok", "10.0.0.1", id="line", stations=("wok", "sushi")), "bar")
    key = send(c, "o1", CHICKEN, ROLL, BEER)
    assert said(c, key, "line") == ["Ticket 1 of 2", "Also at: Bar"]
    assert said(c, key, "bar") == ["Ticket 2 of 2", "Also at: Wok, Sushi bar"]
    # only the stations with a dish in this send are named, not every one the printer prints for
    assert said(c, send(c, "o2", ROLL, BEER), "bar") == ["Ticket 2 of 2", "Also at: Sushi bar"]


def test_a_station_with_no_printer_is_still_named():
    c = kitchen("wok", "bar")  # the first printer stands in for the sushi bar
    key = send(c, "o1", ROLL, BEER)
    assert said(c, key, "wok") == ["Ticket 1 of 2", "Also at: Bar"]
    assert said(c, key, "bar") == ["Ticket 2 of 2", "Also at: Sushi bar"]


def test_the_takeout_counter_is_not_counted_and_reads_where_the_food_comes_from():
    c = kitchen("wok", "sushi", "takeout")
    to_go = {"order_type": "takeout", "channel": "phone", "customer_name": "Linda"}
    key = send(c, "o1", CHICKEN, ROLL, **to_go)
    assert said(c, key, "wok") == ["Ticket 1 of 2", "Also at: Sushi bar"]
    assert said(c, key, "sushi") == ["Ticket 2 of 2", "Also at: Wok"]
    assert said(c, key, "takeout") == ["Also at: Wok, Sushi bar"]
    # one station cooking: its ticket says nothing, the bag's still says where the food is coming from
    key = send(c, "o2", CHICKEN, **to_go)
    assert said(c, key, "wok") == [] and said(c, key, "takeout") == ["Also at: Wok"]
    # a table's dish with the "take out" choice prints at the counter too, and the counter is still not a cook
    key = send(c, "o3", GTC_QUART)
    assert said(c, key, "wok") == [] and said(c, key, "takeout") == ["Also at: Wok"]


def test_a_counter_that_also_cooks_is_counted_for_what_it_cooks():
    c = kitchen("wok", Printer("takeout", "10.0.0.2", id="front", stations=("takeout", "sushi")))
    key = send(c, "o1", CHICKEN, ROLL, order_type="takeout", channel="counter")
    assert said(c, key, "wok") == ["Ticket 1 of 2", "Also at: Sushi bar"]
    assert said(c, key, "front") == ["Ticket 2 of 2", "Also at: Wok"]


def test_a_void_names_the_other_stations_it_reaches():
    c = kitchen("wok", "sushi", settings=servers_void())
    send(c, "o1", CHICKEN, ROLL)
    voids = [
        payload("v1", "void_line", 200, line_id="L0-1", reason="kitchen-error"),
        payload("v2", "void_line", 201, line_id="L0-2", reason="kitchen-error"),
    ]
    assert c.post("/orders/o1/ops", json=voids).status_code == 202
    assert said(c, "v1", "wok") == ["Ticket 1 of 2", "Also at: Sushi bar"]
    assert "*** VOID *** WOK" in decode(c.app.state.printing.store.get("v1:wok").data).text
    one = [payload("v3", "void_line", 300, line_id="L0-1", reason="kitchen-error")]  # already void: nothing prints
    assert c.post("/orders/o1/ops", json=one).status_code == 202
    assert c.app.state.printing.store.get("v3:wok") is None


def test_the_copy_on_a_fallback_printer_says_the_same():
    c = kitchen(Printer("wok", "10.0.0.1", id="wok", fallbacks=("bar",)), "bar")
    key = send(c, "o1", CHICKEN, BEER)
    address, copy = c.app.state.printing.store.get(f"{key}:wok").fallbacks[0]
    text = decode(copy).text
    assert address == "10.0.0.2" and "Ticket 1 of 2" in text and "Also at: Bar" in text


def test_a_manager_turns_either_line_off():
    c = kitchen("wok", "sushi")
    assert c.get("/settings/tickets").json() == {"numbered": True, "also_at": True}
    assert c.put("/settings/tickets", json={"numbered": False}).status_code == 401
    headers = manager(c)
    saved = c.put("/settings/tickets", json={"numbered": False}, headers=headers).json()
    assert saved == {"numbered": False, "also_at": True}  # the one left out stays as it was
    assert said(c, send(c, "o1", CHICKEN, ROLL), "wok") == ["Also at: Sushi bar"]
    saved = c.put("/settings/tickets", json={"numbered": True, "also_at": False}, headers=headers).json()
    assert saved == {"numbered": True, "also_at": False}
    assert said(c, send(c, "o2", CHICKEN, ROLL), "sushi") == ["Ticket 2 of 2"]
    c.put("/settings/tickets", json={"numbered": False}, headers=headers)
    assert c.get("/settings/tickets").json() == {"numbered": False, "also_at": False}
    assert said(c, send(c, "o3", CHICKEN, ROLL), "wok") == []


def test_the_setting_is_two_switches():
    assert clean_tickets({}) == {"numbered": True, "also_at": True}
    assert clean_tickets({"numbered": False, "also_at": False, "more": 1}) == {"numbered": False, "also_at": False}
    with pytest.raises(ValueError, match="also_at must be true or false"):
        clean_tickets({"also_at": "yes"})


def test_a_print_service_nobody_told_prints_tickets_as_before():
    assert PrintService([Printer("wok", "10.0.0.1")], direct=False).ticket_words() == {}
    assert not [t for t in decode(render(DEMO)).text if t.startswith(("Ticket ", "Also at"))]


def test_a_long_list_of_stations_wraps_under_itself():
    names = ("Wok 1", "Wok 2", "Wok 3", "Broiler", "Range", "Fryer", "Sushi Bar", "Soup")
    for dialect in ("escpos", "star"):
        assert render(replace(DEMO, part=(2, 9), also_at=names), dialect=dialect)
    text = decode(render(replace(DEMO, part=(2, 9), also_at=names))).text
    at = text.index("Ticket 2 of 9")
    assert text[at + 1 : at + 4] == [
        "Also at: Wok 1, Wok 2, Wok 3, Broiler, Range,",
        "  Fryer, Sushi Bar, Soup",
        "-" * 48,
    ]
