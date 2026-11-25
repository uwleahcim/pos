"""Printers as the location's setting: each serving a station with fallbacks in order; a line prints at its
station's printer, a to-go order whole at the takeout station too, and a dead printer's tickets move on."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.menu import admin
from pos.menu.service import MenuService, load_definitions
from pos.printing.jobs import FALLBACK_AFTER
from pos.printing.service import Printer, PrintService, printers_from_setting
from pos.settings import SettingStore, clean_printers, fallback_loop
from pos.sync.oplog import OpStore

from ..conftest import T0
from ..orders.test_menu_orders import DINNER, GTC_QUART, payload
from .fake_printer import FakePrinter, decode
from .test_discover import closed_port
from .test_service import wait_for

TAKEOUT = {"kind": "station", "op": "put", "data": {"code": "takeout", "names": {"en": "Takeout"}}}
TAKE_OUT_CHOICE = {
    "kind": "option",
    "op": "put",
    "data": {
        "id": "spice:extra",
        "group": "spice",
        "code": "extra",
        "names": {"en": "Extra spicy"},
        "kitchen_label": "加辣",
        "routes_to": "takeout",
    },
}


def menu_with_takeout() -> MenuService:
    """The sample menu with a takeout station, where the Extra spicy choice also sends the dish (standing in
    for the old POS's "Take out" under Preparation)."""
    defs = admin.apply(load_definitions("restaurant"), [TAKEOUT, TAKE_OUT_CHOICE])
    return MenuService(defs, now=lambda: DINNER)


def app_with(printing: PrintService, settings: SettingStore | None = None) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=menu_with_takeout(),
            printing=printing,
            settings=settings or SettingStore(),
        )
    )


def manager(c: TestClient) -> dict[str, str]:
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    return {"authorization": f"Bearer {token}"}


def test_the_setting_names_each_printer_and_checks_its_fallbacks():
    cleaned = clean_printers(
        {
            "printers": [
                {"station": "wok1", "address": "172.19.1.162"},
                {"id": "bar", "station": "bar", "address": "172.19.1.14:9100", "dialect": "star", "fallbacks": ["p1"]},
            ],
            "takeout_station": "",
        }
    )
    assert cleaned == {
        "printers": [
            {
                "id": "p1",
                "station": "wok1",
                "stations": ["wok1"],
                "address": "172.19.1.162",
                "dialect": "escpos",
                "detected": None,
                "fallbacks": [],
                "tickets": "one",
                "groups": [],
            },
            {
                "id": "bar",
                "station": "bar",
                "stations": ["bar"],
                "address": "172.19.1.14:9100",
                "dialect": "star",
                "detected": None,
                "fallbacks": ["p1"],
                "tickets": "one",
                "groups": [],
            },
        ],
        "takeout_station": None,
    }
    printers = printers_from_setting(cleaned)
    assert printers == [
        Printer("wok1", "172.19.1.162", id="p1"),
        Printer("bar", "172.19.1.14:9100", "star", ("p1",), "bar"),
    ]
    assert printers[0].station == "wok1" and printers[0].as_setting() == cleaned["printers"][0]
    with pytest.raises(ValueError, match="own fallback"):
        clean_printers({"printers": [{"id": "a", "station": "wok1", "address": "10.0.0.1", "fallbacks": ["a"]}]})
    with pytest.raises(ValueError, match="not a printer"):
        clean_printers({"printers": [{"id": "a", "station": "wok1", "address": "10.0.0.1", "fallbacks": ["b"]}]})
    with pytest.raises(ValueError, match="language"):
        clean_printers({"printers": [{"station": "wok1", "address": "10.0.0.1", "dialect": "dotmatrix"}]})
    with pytest.raises(ValueError, match="address"):
        clean_printers({"printers": [{"station": "wok1", "address": "10.0.0.1:99999"}]})
    with pytest.raises(ValueError, match="needs the station"):
        clean_printers({"printers": [{"address": "10.0.0.1"}]})


def test_fallbacks_that_go_round_in_a_loop_are_refused():
    def printers(**fallbacks: list[str]) -> dict:
        return {
            "printers": [
                {"id": ident, "station": f"st{n}", "address": f"10.0.0.{n}", "fallbacks": after}
                for n, (ident, after) in enumerate(fallbacks.items(), start=1)
            ]
        }

    # a chain, and two printers sharing a fallback, are no loop
    clean_printers(printers(a=["b", "c"], b=["c"], c=[]))
    clean_printers(printers(a=["c"], b=["c"], c=["d"], d=[]))
    assert fallback_loop({"a": ["b", "c"], "b": ["c"], "c": []}) is None
    assert fallback_loop({"a": ["b"], "b": ["a"]}) == ["a", "b", "a"]
    assert fallback_loop({"a": ["b"], "b": ["c"], "c": ["d"], "d": ["b"]}) == ["b", "c", "d", "b"]
    assert fallback_loop({"a": ["gone"], "b": []}) is None
    with pytest.raises(ValueError, match="loop: the st1 printer falls back to the st2 printer, which falls back to"):
        clean_printers(printers(a=["b"], b=["a"]))
    with pytest.raises(ValueError) as refused:
        clean_printers(printers(a=["b"], b=["c"], c=["a"], d=["a"]))
    assert str(refused.value) == (
        "the fallbacks go round in a loop: the st1 printer falls back to the st2 printer, which falls back to the "
        "st3 printer, which falls back to the st1 printer. Take one of them out"
    )


def test_a_printer_may_print_for_several_stations_and_an_address_is_one_printer():
    cleaned = clean_printers(
        {
            "printers": [
                {"stations": ["wok", " sushi ", "wok", ""], "address": "10.27.1.14"},
                {"station": "bar", "stations": [], "address": "10.27.1.166", "dialect": "star"},
            ]
        }
    )
    line, bar = cleaned["printers"]
    assert (line["station"], line["stations"]) == ("wok", ["wok", "sushi"])  # an older app reads the first
    assert (bar["station"], bar["stations"]) == ("bar", ["bar"])
    printers = printers_from_setting(cleaned)
    assert [(p.name, p.stations) for p in printers] == [("wok", ("wok", "sushi")), ("bar", ("bar",))]
    assert printers[0].as_setting() == line
    assert Printer("wok", "10.0.0.1").stations == ("wok",)  # one made by hand serves the station it is named for
    with pytest.raises(ValueError, match="same address, 10.27.1.14: one printer prints for several stations"):
        clean_printers(
            {"printers": [{"station": "wok", "address": "10.27.1.14"}, {"station": "sushi", "address": "10.27.1.14"}]}
        )
    with pytest.raises(ValueError, match="short code"):
        clean_printers({"printers": [{"stations": ["wok", "sushi bar"], "address": "10.0.0.1"}]})
    with pytest.raises(ValueError, match="list of station codes"):
        clean_printers({"printers": [{"stations": "wok", "address": "10.0.0.1"}]})


def test_a_printer_set_to_auto_prints_in_the_language_it_was_found_to_speak(monkeypatch):
    cleaned = clean_printers(
        {
            "printers": [
                {"station": "wok", "address": "10.27.1.166", "dialect": "auto", "detected": "star"},
                {"station": "bar", "address": "10.27.1.14", "dialect": "auto"},
                {"station": "sushi", "address": "10.27.1.15", "dialect": "escpos", "detected": "dotmatrix"},
            ]
        }
    )
    assert [(p["dialect"], p["detected"]) for p in cleaned["printers"]] == [
        ("auto", "star"),
        ("auto", None),
        ("escpos", None),  # what it was found to speak is one of the languages, or nothing
    ]
    star, unknown, epson = printers_from_setting(cleaned)
    assert (star.dialect, star.language, star.detected) == ("star", "auto", "star")
    assert (unknown.dialect, unknown.language) == ("escpos", "auto")  # ESC/POS until it has been told
    assert (epson.dialect, epson.language) == ("escpos", "escpos")
    assert star.as_setting() == cleaned["printers"][0]  # the setting keeps "auto", not what it resolved to
    monkeypatch.setenv("POS_PRINT_DIRECT", "0")
    monkeypatch.delenv("POS_PRINTERS", raising=False)
    c = TestClient(create_app(OpStore(physical=lambda: T0), menu=menu_with_takeout(), settings=SettingStore()))
    saved = c.put("/settings/printers", json=cleaned, headers=manager(c)).json()
    assert [(p["dialect"], p["detected"]) for p in saved["printers"]][:2] == [("auto", "star"), ("auto", None)]
    assert [p["dialect"] for p in c.get("/print/printers").json()["printers"]] == ["star", "escpos", "escpos"]


def test_a_printer_serving_two_stations_prints_their_dishes_on_one_ticket():
    line, bar = FakePrinter("epson"), FakePrinter("epson")
    try:
        printing = PrintService(
            [Printer("wok", line.address, id="p1", stations=("wok", "sushi")), Printer("bar", bar.address, id="p2")]
        )
        c = app_with(printing)
        by_code = {s["code"]: s for s in c.get("/print/stations").json()["stations"]}
        assert by_code["wok"]["printer"] == "p1" and by_code["sushi"]["printer"] == "p1"
        assert "sushi" not in c.get("/print/stations").json()["missing"]
        assert c.get("/print/printers").json()["printers"][0]["stations"] == ["wok", "sushi"]
        rice = {"variant_id": "GTC:quart", "entry_id": "dinner:87", "selections": []}
        c.post(
            "/orders/o1/ops",
            json=[
                payload("a", "create", 0, table="12"),
                payload("b", "add_line", 1, line_id="L1", item="?", request=rice),
                payload("c", "add_line", 2, line_id="L2", item="?", request={"variant_id": "CALROLL:roll"}),
                payload("d", "fire", 3, course="*"),
            ],
        )
        wait_for(lambda: len(line.jobs) == 1)
        ticket = decode(line.jobs[0])
        assert ticket.text[0] == "WOK + SUSHI BAR" and ticket.cuts == 1  # one ticket, headed with both
        assert [j["job_id"] for j in c.get("/print/jobs").json()["jobs"]] == ["d:p1"] and bar.jobs == []
        assert c.post("/print/test", json={"printer": "sushi"}).status_code == 202  # by any of its stations
        wait_for(lambda: len(line.jobs) == 2)
        assert printing.head(Printer("a", "x", stations=("wok", "sushi", "bar", "takeout"))) == "Wok + 3 more"
    finally:
        line.close()
        bar.close()


def test_the_env_seeds_a_hub_until_a_manager_saves_printers(monkeypatch):
    monkeypatch.setenv("POS_PRINTERS", "kitchen=172.19.1.162/escpos,bar=172.19.1.14/star")
    monkeypatch.setenv("POS_PRINT_DIRECT", "0")
    c = TestClient(create_app(OpStore(physical=lambda: T0), menu=menu_with_takeout(), settings=SettingStore()))
    seeded = c.get("/settings/printers").json()
    assert seeded["source"] == "env" and [p["station"] for p in seeded["printers"]] == ["kitchen", "bar"]
    assert seeded["printers"][1] == {
        "id": "bar",
        "station": "bar",
        "stations": ["bar"],
        "address": "172.19.1.14",
        "dialect": "star",
        "detected": None,
        "fallbacks": [],
        "tickets": "one",
        "groups": [],
    }
    assert [p["name"] for p in c.get("/print/printers").json()["printers"]] == ["kitchen", "bar"]

    body = {
        "printers": [
            {"station": "wok", "address": "172.19.1.162", "dialect": "escpos", "fallbacks": []},
            {"id": "bar", "station": "bar", "address": "172.19.1.14", "dialect": "star", "fallbacks": ["p1"]},
        ],
        "takeout_station": "takeout",
    }
    assert c.put("/settings/printers", json=body).status_code == 401  # a manager's call
    saved = c.put("/settings/printers", json=body, headers=manager(c)).json()
    assert saved["source"] == "settings" and saved["printers"][0]["id"] == "p1"
    assert saved["printers"][1]["fallbacks"] == ["p1"]
    # the next ticket prints by the new list: the service reads the setting each time
    listed = c.get("/print/printers").json()["printers"]
    assert [(p["id"], p["name"], p["fallbacks"]) for p in listed] == [("p1", "wok", []), ("bar", "bar", ["p1"])]
    bad = c.put("/settings/printers", json={"printers": [{"station": "x", "address": ""}]}, headers=manager(c))
    assert bad.status_code == 422 and "address" in bad.json()["detail"]["message"]


def test_the_stations_the_menu_prints_at_are_listed_with_the_ones_missing_a_printer():
    printing = PrintService([Printer("wok", "10.0.0.9", id="p1")], direct=False)
    c = app_with(printing)
    listed = c.get("/print/stations").json()
    by_code = {s["code"]: s for s in listed["stations"]}
    assert by_code["wok"]["printer"] == "p1" and by_code["wok"]["dishes"] > 0 and by_code["wok"]["name"] == "Wok"
    assert by_code["sushi"]["printer"] is None and by_code["sushi"]["dishes"] > 0
    assert by_code["takeout"] == {
        "code": "takeout",
        "name": "Takeout",
        "known": True,
        "dishes": 0,
        "choices": 1,  # Extra spicy sends the dish there as well
        "printer": None,
        "takeout": True,
    }
    assert listed["takeout_station"] == "takeout"
    assert set(listed["missing"]) >= {"sushi", "bar", "takeout"} and "wok" not in listed["missing"]


def test_a_to_go_order_prints_whole_at_the_takeout_printer_and_a_dine_in_order_does_not():
    wok, sushi, takeout = FakePrinter("epson"), FakePrinter("epson"), FakePrinter("epson")
    try:
        printing = PrintService(
            [
                Printer("wok", wok.address, id="p1"),
                Printer("sushi", sushi.address, id="p2"),
                Printer("takeout", takeout.address, id="p3"),
            ]
        )
        c = app_with(printing)
        c.put("/settings/printers", headers=manager(c), json={"printers": [], "takeout_station": "takeout"})
        rice = {"variant_id": "GTC:quart", "entry_id": "dinner:87", "selections": []}
        roll = {"variant_id": "CALROLL:roll"}
        c.post(
            "/orders/o1/ops",
            json=[
                payload("a", "create", 0, order_type="takeout", channel="phone", customer_name="Linda"),
                payload("b", "add_line", 1, line_id="L1", item="?", request=rice),
                payload("c", "add_line", 2, line_id="L2", item="?", request=roll),
                payload("d", "fire", 3, course="*"),
            ],
        )
        wait_for(lambda: len(wok.jobs) == 1 and len(sushi.jobs) == 1 and len(takeout.jobs) == 1)
        # the wok and the sushi bar each cook their own dish; the takeout counter sees both, once each
        # (every Chinese line is one image: the dish and each of its choices)
        cooked, rolled, bag = decode(wok.jobs[0]), decode(sushi.jobs[0]), decode(takeout.jobs[0])
        assert cooked.text[0] == "WOK" and rolled.text[0] == "SUSHI BAR" and bag.text[0] == "TAKEOUT"
        assert len(bag.images) == len(cooked.images) + len(rolled.images) and "#1  LINDA" in bag.text
        assert sorted(j["job_id"] for j in c.get("/print/jobs").json()["jobs"]) == ["d:p1", "d:p2", "d:p3"]

        c.post(
            "/orders/o2/ops",
            json=[
                {**payload("e", "create", 4, table="12", order_type="dine_in"), "order_id": "o2"},
                {**payload("f", "add_line", 5, line_id="L1", item="?", request=rice), "order_id": "o2"},
                {**payload("g", "fire", 6, course="*"), "order_id": "o2"},
            ],
        )
        wait_for(lambda: len(wok.jobs) == 2)
        assert len(takeout.jobs) == 1  # a table's order is cooked and served, not bagged
    finally:
        wok.close()
        sushi.close()
        takeout.close()


def test_a_take_out_choice_sends_the_dish_to_the_takeout_station_as_well():
    wok, takeout = FakePrinter("epson"), FakePrinter("epson")
    try:
        printing = PrintService([Printer("wok", wok.address, id="p1"), Printer("takeout", takeout.address, id="p2")])
        c = app_with(printing)
        priced = c.post("/menu/price", json=GTC_QUART).json()  # Extra spicy routes to takeout here
        stations = [(k["station"], k["label"]) for k in priced["kitchen"]]
        assert stations == [("wok", "左宗鸡 (Qt)"), ("takeout", "左宗鸡 (Qt)")]
        assert priced["kitchen"][1]["labels"] == priced["kitchen"][0]["labels"] == ["加辣", "糙米"]
        c.post(
            "/orders/o1/ops",
            json=[
                payload("a", "create", 0, table="12", order_type="dine_in"),
                payload("b", "add_line", 1, line_id="L1", item="?", request=GTC_QUART),
                payload("c", "fire", 2, course="*"),
            ],
        )
        wait_for(lambda: len(wok.jobs) == 1 and len(takeout.jobs) == 1)
        cooked, bagged = decode(wok.jobs[0]), decode(takeout.jobs[0])
        assert bagged.text[0] == "TAKEOUT" and cooked.text[0] == "WOK"
        assert len(bagged.images) == len(cooked.images) == 3  # the dish and its two choices, the same at both
    finally:
        wok.close()
        takeout.close()


def test_a_dead_printer_s_ticket_moves_to_its_fallback_headed_with_whose_it_is():
    bar = FakePrinter("epson")
    try:
        dead = closed_port()
        printing = PrintService(
            [Printer("wok", dead, id="p1", fallbacks=("p2",)), Printer("bar", bar.address, "escpos", (), "p2")]
        )
        c = app_with(printing)
        c.post(
            "/orders/o1/ops",
            json=[
                payload("a", "create", 0, table="12", order_type="dine_in"),
                payload("b", "add_line", 1, line_id="L1", item="?", request=GTC_QUART),
                payload("c", "fire", 2, course="*"),
            ],
        )
        job = printing.store.get("c:p1")
        assert job is not None and job.fallbacks and job.fallbacks[0][0] == bar.address
        wait_for(lambda: job.failures == 1 and job.status == "queued")  # the first write failed
        for _ in range(FALLBACK_AFTER - 1):
            printing.retry_pending()
        assert job.moved == 1 and job.printer == bar.address and job.failures == 0
        assert printing.retry_pending() == 1 and job.status == "done"
        copy = decode(bar.jobs[0])
        assert copy.text[0] == "WOK" and "WOK PRINTER DOWN, PRINTED HERE" in copy.inverted
        listed = c.get("/print/jobs").json()["jobs"][0]
        assert listed["moved"] == 1 and listed["fallbacks"] == [dead] and listed["printer"] == bar.address
    finally:
        bar.close()


def test_a_test_print_goes_by_id_or_station_with_the_station_s_name_on_it():
    printer = FakePrinter("epson")
    try:
        printing = PrintService([Printer("wok", printer.address, id="p1")])
        c = app_with(printing)
        assert c.post("/print/test", json={"printer": "p1"}).status_code == 202
        assert c.post("/print/test", json={"printer": "wok"}).status_code == 202
        assert c.post("/print/test", json={"printer": "nope"}).json()["detail"]["printers"] == ["p1"]
        wait_for(lambda: len(printer.jobs) == 2)
        assert decode(printer.jobs[0]).text[0] == "WOK"
    finally:
        printer.close()
