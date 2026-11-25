"""A printer that prints for several stations puts one send on one ticket, or on a ticket for each station
when it is set to; the stations a manager grouped (wok 1 with wok 2) share a ticket all the same."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pos.printing.service import Printer, PrintService, printers_from_setting
from pos.settings import SettingStore, clean_printers

from ..conftest import servers_void
from ..orders.test_menu_orders import payload
from .fake_printer import decode
from .test_other_stations import BEER, CHICKEN, ROLL, kitchen, said, send
from .test_stations import manager

TO_GO = {"order_type": "takeout", "channel": "phone", "customer_name": "Linda"}


def line(*stations: str, groups: tuple[tuple[str, ...], ...] = (), tickets: str = "each") -> Printer:
    """One printer, id `line`, for these stations, printing a ticket for each unless told otherwise."""
    return Printer(stations[0], "10.0.0.1", id="line", stations=stations, tickets=tickets, groups=groups)


def tickets(c: TestClient, key: str) -> dict[str, list[str]]:
    """The tickets of that send by their job's id (less the send's own), each as the text it prints."""
    jobs = [job for job in c.app.state.printing.store.all() if job.job_id.startswith(f"{key}:")]
    return {job.job_id.removeprefix(f"{key}:"): decode(job.data).text for job in jobs}  # in the order they were made


def test_the_setting_keeps_how_a_printer_prints_its_stations_and_which_share_a_ticket():
    cleaned = clean_printers(
        {
            "printers": [
                {
                    "stations": ["wok1", "wok2", "fryer", "broiler"],
                    "address": "10.0.0.1",
                    "tickets": "each",
                    # in the order the stations stand on the printer; one no longer on it takes itself out,
                    # and a group of one is no group
                    "groups": [["wok2", "wok1", "range"], ["fryer", "sushi"], []],
                },
                {"station": "bar", "address": "10.0.0.2"},
            ]
        }
    )
    kitchen_printer, bar = cleaned["printers"]
    assert (kitchen_printer["tickets"], kitchen_printer["groups"]) == ("each", [["wok1", "wok2"]])
    assert (bar["tickets"], bar["groups"]) == ("one", [])  # what a printer starts on: one ticket, as before
    made = printers_from_setting(cleaned)
    assert made[0].sets() == (("wok1", "wok2"), ("fryer",), ("broiler",))
    assert made[0].as_setting() == kitchen_printer and made[1].as_setting() == bar
    with pytest.raises(ValueError, match="'one' ticket or a ticket for 'each'"):
        clean_printers({"printers": [{"station": "wok1", "address": "10.0.0.1", "tickets": "two"}]})
    with pytest.raises(ValueError, match="wok2 is in two groups"):
        clean_printers(
            {
                "printers": [
                    {
                        "stations": ["wok1", "wok2", "fryer"],
                        "address": "10.0.0.1",
                        "groups": [["wok1", "wok2"], ["wok2", "fryer"]],
                    }
                ]
            }
        )
    with pytest.raises(ValueError, match="list of lists"):
        clean_printers({"printers": [{"station": "wok1", "address": "10.0.0.1", "groups": ["wok1", "wok2"]}]})


def test_which_stations_share_a_ticket():
    assert line("wok", "sushi", "bar", tickets="one").sets() == (("wok", "sushi", "bar"),)
    assert line("wok", "sushi", "bar").sets() == (("wok",), ("sushi",), ("bar",))
    # a group prints where the first of its stations stands
    assert line("wok", "sushi", "bar", groups=(("wok", "bar"),)).sets() == (("wok", "bar"), ("sushi",))
    assert line("wok", "sushi", "bar", groups=(("sushi", "bar"),)).sets() == (("wok",), ("sushi", "bar"))
    # the groups wait while the printer prints one ticket, and a printer for one station has nothing to part
    assert line("wok", "sushi", groups=(("wok", "sushi"),), tickets="one").sets() == (("wok", "sushi"),)
    assert line("wok").sets() == (("wok",),) and not line("wok").separate
    assert line("wok", "sushi").set_of("sushi") == ("sushi",) and line("wok", "sushi").set_of("bar") == ()
    assert line("wok", "sushi", tickets="one").set_of("sushi") == ()


def test_a_printer_set_to_prints_a_ticket_for_each_station():
    c = kitchen(line("wok", "sushi", "bar"))
    key = send(c, "o1", CHICKEN, ROLL, BEER)
    printed = tickets(c, key)
    assert list(printed) == ["line:wok", "line:sushi", "line:bar"]  # one job each, in the order they stand
    assert [text[0] for text in printed.values()] == ["WOK", "SUSHI BAR", "BAR"]
    assert "1 x Tsingtao" in printed["line:bar"] and "1 x Tsingtao" not in printed["line:wok"]
    # they are numbered and name each other like the tickets of three printers
    assert said(c, key, "line:wok") == ["Ticket 1 of 3", "Also at: Sushi bar, Bar"]
    assert said(c, key, "line:bar") == ["Ticket 3 of 3", "Also at: Wok, Sushi bar"]
    # a station with nothing in the send prints nothing
    assert list(tickets(c, send(c, "o2", BEER))) == ["line:bar"]


def test_a_printer_left_as_it_was_prints_one_ticket_for_all_its_stations():
    c = kitchen(line("wok", "sushi", "bar", tickets="one"))
    printed = tickets(c, send(c, "o1", CHICKEN, ROLL, BEER))
    assert list(printed) == ["line"] and printed["line"][0] == "WOK + SUSHI BAR + BAR"


def test_the_stations_of_a_group_share_a_ticket():
    c = kitchen(line("wok", "sushi", "bar", groups=(("wok", "sushi"),)))
    key = send(c, "o1", CHICKEN, ROLL, BEER)
    printed = tickets(c, key)
    assert list(printed) == ["line:wok", "line:bar"]
    assert printed["line:wok"][0] == "WOK + SUSHI BAR" and printed["line:bar"][0] == "BAR"
    assert said(c, key, "line:wok") == ["Ticket 1 of 2", "Also at: Bar"]
    assert said(c, key, "line:bar") == ["Ticket 2 of 2", "Also at: Wok, Sushi bar"]
    # the group's ticket is headed with the group whichever of its stations cooks
    assert tickets(c, send(c, "o2", ROLL))["line:wok"][0] == "WOK + SUSHI BAR"


def test_a_void_goes_to_the_ticket_of_the_station_that_has_the_dish():
    c = kitchen(line("wok", "sushi", "bar"), settings=servers_void())
    send(c, "o1", CHICKEN, BEER)
    gone = payload("v1", "void_line", 200, line_id="L0-2", reason="kitchen-error")
    assert c.post("/orders/o1/ops", json=[gone]).status_code == 202
    printed = tickets(c, "v1")
    assert list(printed) == ["line:bar"] and printed["line:bar"][0] == "*** VOID *** BAR"


def test_the_takeout_station_s_ticket_is_the_whole_order_and_the_cooks_get_their_own():
    c = kitchen(line("wok", "sushi", "takeout"))
    key = send(c, "o1", CHICKEN, ROLL, **TO_GO)
    jobs = {job.job_id: decode(job.data) for job in c.app.state.printing.store.all()}
    wok, sushi, bag = (jobs[f"{key}:line:{station}"] for station in ("wok", "sushi", "takeout"))
    assert (wok.text[0], sushi.text[0], bag.text[0]) == ("WOK", "SUSHI BAR", "TAKEOUT")
    assert len(bag.images) == len(wok.images) + len(sushi.images)  # the bag's copy lists both dishes
    assert "#1  LINDA" in bag.text
    # the counter packs and does not cook: it is not numbered, and reads where the food is coming from
    assert said(c, key, "line:wok") == ["Ticket 1 of 2", "Also at: Sushi bar"]
    assert said(c, key, "line:takeout") == ["Also at: Wok, Sushi bar"]


def test_a_first_printer_that_prints_apart_does_so_for_the_stations_it_stands_in_for():
    c = kitchen(line("wok", "bar"))  # no printer for the sushi bar: the first printer takes it
    key = send(c, "o1", CHICKEN, ROLL, BEER)
    printed = tickets(c, key)
    assert list(printed) == ["line:wok", "line:bar", "line:sushi"]
    assert printed["line:sushi"][0] == "SUSHI BAR"
    assert said(c, key, "line:sushi") == ["Ticket 3 of 3", "Also at: Wok, Bar"]
    # a first printer that prints one ticket keeps them on it, as before
    one = kitchen(line("wok", "bar", tickets="one"))
    assert list(tickets(one, send(one, "o1", CHICKEN, ROLL, BEER))) == ["line"]


def test_a_station_the_sending_screen_skips_gets_no_ticket_of_its_own():
    printing = PrintService([line("wok", "sushi"), Printer("bar", "10.0.0.2", id="bar")], direct=False)
    routes = printing.routing(printing.printers, to_go=False, skip=frozenset({"sushi"}), cooked=["wok", "sushi", "tea"])
    assert [(printer.id, takes.named) for printer, takes in routes] == [
        ("line", ("wok",)),
        ("line", ("sushi",)),
        ("line", ("tea",)),  # a station with no printer, at the first printer under its own name
        ("bar", ()),
    ]
    wok, sushi, tea, bar = (takes for _, takes in routes)
    assert wok.cooks("wok") and wok.cooks(None) and not wok.cooks("tea") and not wok.cooks("sushi")
    assert not sushi.cooks("sushi") and not sushi.cooks(None)  # skipped by the screen that sent it
    assert tea.cooks("tea") and not tea.cooks("wok") and not bar.cooks("tea")


def test_a_fallback_s_copy_says_which_station_s_ticket_it_is():
    c = kitchen(
        Printer("wok", "10.0.0.1", id="line", stations=("wok", "sushi"), tickets="each", fallbacks=("bar",)),
        Printer("bar", "10.0.0.2", id="bar"),
    )
    key = send(c, "o1", CHICKEN, ROLL)
    job = c.app.state.printing.store.get(f"{key}:line:sushi")
    address, copy = job.fallbacks[0]
    assert address == "10.0.0.2" and "SUSHI BAR PRINTER DOWN, PRINTED HERE" in decode(copy).inverted


def test_the_app_sets_it_and_an_app_that_does_not_know_of_it_leaves_it_alone():
    settings = SettingStore()
    # saved before a printer could print its stations apart: no word of it in what is kept
    settings.put(
        "printers",
        {
            "printers": [{"id": "p1", "station": "wok", "stations": ["wok", "sushi", "bar"], "address": "10.0.0.1"}],
            "takeout_station": "takeout",
        },
    )
    c = kitchen("wok", settings=settings)
    c.app.state.printing.printers = lambda: printers_from_setting(settings.get("printers"))
    read = c.get("/settings/printers").json()["printers"][0]
    assert (read["tickets"], read["groups"]) == ("one", [])  # always said, so a screen knows it can be set
    asked = {**read, "tickets": "each", "groups": [["wok", "sushi"]]}
    saved = c.put("/settings/printers", headers=manager(c), json={"printers": [asked]}).json()["printers"][0]
    assert (saved["tickets"], saved["groups"]) == ("each", [["wok", "sushi"]])
    assert list(tickets(c, send(c, "o1", CHICKEN, ROLL, BEER))) == ["p1:wok", "p1:bar"]

    # an app not rebuilt yet saves the printers without either: what was set stays
    older = {key: value for key, value in read.items() if key not in ("tickets", "groups")}
    kept = c.put("/settings/printers", headers=manager(c), json={"printers": [older]}).json()["printers"][0]
    assert (kept["tickets"], kept["groups"]) == ("each", [["wok", "sushi"]])
    # taking a station off the printer takes it out of its group
    fewer = {**read, "stations": ["wok", "bar"], "tickets": "each", "groups": [["wok", "sushi"]]}
    less = c.put("/settings/printers", headers=manager(c), json={"printers": [fewer]}).json()["printers"][0]
    assert (less["tickets"], less["groups"]) == ("each", [])
    back = c.put("/settings/printers", headers=manager(c), json={"printers": [{**read, "tickets": "one"}]}).json()
    assert back["printers"][0]["tickets"] == "one"
    bad = c.put("/settings/printers", headers=manager(c), json={"printers": [{**read, "tickets": "many"}]})
    assert bad.status_code == 422 and "ticket" in bad.json()["detail"]["message"]


def test_the_test_print_shows_the_tickets_as_they_are_set():
    c = kitchen(line("wok", "sushi", "bar", groups=(("wok", "sushi"),)), Printer("tea", "10.0.0.2", id="tea"))
    tried = c.post("/print/test", json={"printer": "line"})
    assert tried.status_code == 202 and tried.json()["tickets"] == 2
    heads = [decode(job.data).text[0] for job in c.app.state.printing.store.all()]
    assert heads == ["WOK + SUSHI BAR", "BAR"]
    assert c.post("/print/test", json={"printer": "tea"}).json()["tickets"] == 1
