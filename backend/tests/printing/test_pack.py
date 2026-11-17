"""The pack sheet: a catering order's first tickets come with one paper for whoever packs it, and anyone can
print it again with the order as it stands. It says who the order is for and when, what its event needs, the
money, and every dish with a box to tick; the dishes nobody sent stand apart, since nobody is cooking them."""

from __future__ import annotations

from datetime import datetime

from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.printing.pack import PackSheet, render_pack
from pos.printing.service import Printer, PrintService
from pos.printing.ticket import Money, TicketLine
from pos.settings import SettingStore, clean_ticket_skips
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore

from ..conftest import T0, servers_void
from ..orders.test_menu_orders import payload
from .fake_printer import Decoded, decode
from .test_held import CATERING, DAY, SATURDAY, START, hub, post, release
from .test_other_stations import BEER, CHICKEN, ROLL, send
from .test_stations import manager, menu_with_takeout

TAKEOUT, WOK = "10.0.0.4", "10.0.0.1"  # where `hub` puts the takeout station's printer, and the wok's
EVENT = {
    **CATERING,
    "phone": "781 555 0101",
    "event_guests": 30,
    "handover": "delivery",
    "address": "12 Main St,  Winchester",
    "event_note": "Set up by 11:30, side door",
}
FOR = f"FOR {datetime.fromtimestamp(SATURDAY / 1000, localtime.zone()):%H:%M  %a %b} ".upper()


def sheets(c: TestClient) -> list[str]:
    return [job.job_id for job in c.app.state.printing.store.all() if job.job_id.endswith(":pack")]


def sheet(c: TestClient, job_id: str) -> Decoded:
    return decode(c.app.state.printing.store.get(job_id).data)


def again(c: TestClient, order_id: str = "o1", **body) -> Decoded:
    """The sheet printed again from the order's screen."""
    answer = c.post(f"/orders/{order_id}/pack-sheet", json=body)
    assert answer.status_code == 202, answer.text
    return sheet(c, answer.json()["job_id"])


def boxes(paper: Decoded) -> int:
    """How many dishes the sheet lists: the ones in letters; the chicken and the roll are drawn as pictures."""
    return sum(line.startswith("[ ] ") for line in paper.text)


def test_a_catering_orders_tickets_come_with_a_pack_sheet():
    clock = [T0 + 100]
    c = hub(clock)
    key = send(c, "o1", CHICKEN, ROLL, BEER, **EVENT)
    assert sheets(c) == []  # nothing is on paper while the order waits, the sheet neither
    clock[0] = START
    release(c)
    assert sheets(c) == [f"{key}:pack"]
    job = c.app.state.printing.store.get(f"{key}:pack")
    assert job.printer == TAKEOUT  # where the bag is packed
    paper = decode(job.data)
    text = [line.strip() for line in paper.text]
    assert text[0] == "PACK SHEET"
    assert text[1] == "#1  LINDA"
    assert text[2].startswith(FOR)  # with its day, always
    assert text[3:7] == [
        "DELIVERY",
        "12 Main St, Winchester",
        "Catering  30 guests  781 555 0101",
        "** Set up by 11:30, side door **",
    ]
    # the money, as on the takeout station's ticket: white on black while something is still to collect
    assert any(words.startswith("NOT PAID  $") for words in paper.inverted)
    # every dish with a box: the beer in letters, the chicken and the roll as the kitchen reads them
    assert "[ ] 1 x Tsingtao" in text and boxes(paper) == 1 and len(paper.images) == 2
    assert "3 dishes to pack" in text
    assert [line for line in text if line.startswith(("Packed by", "Checked by"))] == [
        "Packed by  ______________________________",
        "Checked by ______________________________",
    ]
    assert "NOT SENT TO THE KITCHEN" not in paper.inverted and paper.cuts == 1


def test_an_order_within_its_lead_gets_its_sheet_as_it_is_sent():
    clock = [T0 + 100]
    c = hub(clock)
    soon = {**EVENT, "promised_at": T0 + 30 * 60_000}
    key = send(c, "o1", CHICKEN, **soon)
    assert sheets(c) == ["o1-open:pack"]  # under the batch that sent it
    assert c.app.state.printing.store.get(f"{key}:wok") is not None  # with its tickets, not in their place
    assert c.app.state.printing.store.get(f"{key}:takeout") is not None


def test_dishes_added_later_print_their_tickets_and_no_second_sheet():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", CHICKEN, **EVENT)
    clock[0] = START
    release(c)
    first = sheets(c)
    more = send(c, "o1", BEER, at=100)
    assert c.app.state.printing.store.get(f"{more}:bar") is not None
    assert sheets(c) == first
    # printed again, it is the order as it stands now
    assert "[ ] 1 x Tsingtao" in again(c).text and "2 dishes to pack" in again(c).text


def test_dishes_added_at_the_last_minute_are_on_the_one_sheet():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", CHICKEN, **EVENT)
    clock[0] = START  # the hub's loop has not looked yet when the beer is sent
    send(c, "o1", BEER, at=100)
    made = sheets(c)
    assert len(made) == 1 and "2 dishes to pack" in sheet(c, made[0]).text
    assert release(c) == [] and sheets(c) == made


def test_only_a_catering_order_gets_one_by_itself():
    clock = [T0 + 100]
    c = hub(clock)
    phone = {**CATERING, "channel": "phone"}
    send(c, "o1", CHICKEN, **phone)
    send(c, "o2", CHICKEN, order_type="takeout", channel="counter", customer_name="Now")
    send(c, "o3", CHICKEN)  # a table
    clock[0] = START
    release(c)
    assert sheets(c) == []
    # asked for, any to-go order prints one; a table's does not
    assert "PACK SHEET" in again(c, "o1").text[0] and "PACK SHEET" in again(c, "o2").text[0]
    refused = c.post("/orders/o3/pack-sheet")
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "not_to_go"


def test_the_location_turns_the_sheet_off():
    clock = [T0 + 100]
    c = hub(clock)
    assert c.get("/settings/tickets").json()["pack"] is True
    assert c.put("/settings/tickets", json={"pack": False}).status_code == 401
    saved = c.put("/settings/tickets", json={"pack": False}, headers=manager(c))
    assert saved.status_code == 200 and saved.json()["pack"] is False
    key = send(c, "o1", CHICKEN, **EVENT)
    clock[0] = START
    assert release(c) == [f"{key}:wok", f"{key}:takeout"] and sheets(c) == []
    assert "PACK SHEET" in again(c).text[0]  # asked for, it still prints


def test_a_voided_order_prints_no_sheet_and_one_put_off_waits():
    clock = [T0 + 100]
    c = hub(clock, settings=servers_void())
    send(c, "o1", CHICKEN, **EVENT)
    send(c, "o2", CHICKEN, **{**EVENT, "customer_name": "Later"})
    post(c, payload("gone", "void_order", 200, reason="guest-changed-mind"))
    post(c, payload("later", "set_field", 300, promised_at=SATURDAY + DAY), order_id="o2")
    clock[0] = START
    release(c)
    assert sheets(c) == []
    clock[0] = START + DAY
    release(c)
    assert len(sheets(c)) == 1 and "#2  LATER" in sheet(c, sheets(c)[0]).text


def test_the_sheet_is_the_order_as_it_stands():
    clock = [T0 + 100]
    c = hub(clock, settings=servers_void())
    send(c, "o1", CHICKEN, ROLL, BEER, **EVENT)
    # on Wednesday the beer comes off, two more are rung in and nobody sends them, and a deposit is taken
    clock[0] = T0 + DAY
    post(
        c,
        payload("v1", "void_line", 300, line_id="L0-3", reason="guest-changed-mind"),
        payload("a9", "add_line", 310, line_id="L9", item="?", qty=2, request={**BEER, "qty": 2}),
        payload("p1", "pay", 320, payment_id="P1", method="cash", amount="10.00", by="Amy"),
        payload("al", "allergy", 330, allergens=["peanut"], note="no MSG"),
    )
    paper = again(c)
    text = [line.strip() for line in paper.text]
    assert text[0] == "PACK SHEET" and text[2].startswith(FOR)
    assert any(words.startswith("NOT PAID  $") for words in paper.inverted)
    assert any(line.startswith("$10.00 paid of $") for line in text)
    assert "ALLERGY" in paper.inverted and any(line.startswith("Order: ") and "no MSG" in line for line in text)
    # the chicken and the roll, which the kitchen has; then, under a black bar, the beers it has no ticket for
    bar = text.index("NOT SENT TO THE KITCHEN")
    assert "NOT SENT TO THE KITCHEN" in paper.inverted
    assert text[bar + 1] == "[ ] 2 x Tsingtao" and boxes(paper) == 1 and len(paper.images) == 2
    assert "4 dishes to pack" in text
    # reading and printing change nothing on the order, and nothing that waits
    assert c.get("/print/jobs").json()["held"][0]["lines"] == 2


def test_before_anything_is_sent_every_dish_stands_as_not_sent():
    clock = [T0 + 100]
    c = hub(clock)
    post(
        c,
        payload("open", "create", 0, **EVENT),
        payload("a1", "add_line", 1, line_id="L1", item="?", request=BEER),
    )
    paper = again(c)
    text = [line.strip() for line in paper.text]
    assert text[text.index("NOT SENT TO THE KITCHEN") + 1] == "[ ] 1 x Tsingtao" and "1 dish to pack" in text
    empty = post(c, payload("open2", "create", 5, **EVENT), order_id="o2")
    assert empty["refused"] == []
    refused = c.post("/orders/o2/pack-sheet")
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "nothing_on_order"
    assert c.post("/orders/nobody/pack-sheet").status_code == 404


def test_where_a_sheet_prints():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", BEER, **EVENT)

    def at(**body) -> tuple[str, str]:
        answer = c.post("/orders/o1/pack-sheet", json=body).json()
        return answer["printed_at"]["id"], c.app.state.printing.store.get(answer["job_id"]).printer

    assert at() == ("takeout", TAKEOUT)  # where the bag is packed
    assert at(printer="wok") == ("wok", WOK)  # the one a screen asks for
    assert at(printer="gone") == ("takeout", TAKEOUT)  # a printer that is no longer there is passed over

    # no takeout station: where the location's bills print, which is the first printer until one is chosen
    def location(*printers: Printer) -> TestClient:
        settings = SettingStore()
        settings.put("printers", {"printers": [], "takeout_station": None})
        service = PrintService(list(printers), direct=False, now=lambda: clock[0])
        c = TestClient(
            create_app(
                OpStore(physical=lambda: T0 + 100), menu=menu_with_takeout(), printing=service, settings=settings
            )
        )
        send(c, "o1", BEER, **EVENT)
        return c

    plain = location(Printer("wok", WOK, id="wok"), Printer("bar", "10.0.0.3", id="bar"))
    assert plain.post("/orders/o1/pack-sheet").json()["printed_at"]["id"] == "wok"
    none = location()
    refused = none.post("/orders/o1/pack-sheet")
    assert refused.status_code == 409 and refused.json()["detail"]["error"] == "no_printer"


def test_a_screen_that_prints_nothing_at_the_takeout_station_gets_no_sheet():
    clock = [T0 + 100]
    settings = SettingStore()
    settings.put("ticket_skips", clean_ticket_skips({"screens": [{"device": "bar1", "stations": ["takeout"]}]}))
    c = hub(clock, settings=settings)

    def op(op_id: str, kind: str, at: int, **data) -> dict:
        return {
            "op_id": op_id,
            "order_id": "o1",
            "hlc": str(HLC(T0 + at, 0, "bar1")),
            "device": "bar1",
            "kind": kind,
            "data": data,
        }

    post(
        c,
        op("open", "create", 0, **EVENT),
        op("a1", "add_line", 1, line_id="L1", item="?", request=BEER),
        op("bar-fire", "fire", 2, course="*"),
    )
    clock[0] = START
    assert release(c) == ["bar-fire:bar"] and sheets(c) == []


def test_the_sheet_in_both_printer_languages_and_on_a_fallback():
    paper = PackSheet(
        order_id="0193f2a7-demo-pack",
        lines=(
            TicketLine(2, "General Tso's Chicken (Qt)", ("Extra spicy", "Brown rice"), depths=(0, 1), note="no onions"),
            TicketLine(1, "左宗鸡 (Qt)", ("加辣",), header="Dinner for four"),
        ),
        unsent=(TicketLine(3, "Egg roll", allergy="Peanuts"),),
        count=6,
        order_no=12,
        customer="Chen",
        phone="781 555 0101",
        channel="catering",
        promised=datetime(2026, 11, 21, 12, 0),
        guests=1,
        handover="pickup",
        money=Money("PAID"),
        bag=("2 x Chopsticks",),
        at=datetime(2026, 11, 19, 9, 41),
        reprinted_from="Takeout",
    )
    printed = decode(render_pack(paper))
    text = [line.strip() for line in printed.text]
    assert printed.inverted[0] == "TAKEOUT PRINTER DOWN, PRINTED HERE"
    assert text[1:5] == ["PACK SHEET", "#12  CHEN", "FOR 12:00  SAT NOV 21", "PICKUP"]
    assert "Catering  1 guest  781 555 0101" in text and "PAID" in text and "PAID" not in printed.inverted
    at = text.index("[ ] 2 x General Tso's")  # a long dish goes on over the next line
    assert text[at + 1 : at + 5] == ["Chicken (Qt)", "+ Extra spicy", "+ Brown rice", "** no onions **"]
    assert printed.text[printed.text.index("        + Extra spicy") + 1] == "            + Brown rice"
    assert text[text.index("[ ] 3 x Egg roll") + 1] == "** ALLERGY: Peanuts **"
    assert text[text.index("6 dishes to pack") + 1 :][:2] == ["ALSO IN THE BAG", "2 x Chopsticks"]
    assert "emo-pack  2026-11-19 09:41:00" in text
    star = render_pack(paper, dialect="star")
    assert star and star != render_pack(paper) and render_pack(paper) == render_pack(paper)
