"""Labels for the bags of a to-go order: somebody at the takeout counter says how many bags the order went
into, and a short slip prints for each, to stick on it: the order's number and name, which bag of how many it
is, and when it is due. Nothing prints by itself, and printing changes nothing on the order."""

from __future__ import annotations

from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.labels import BAGS_MOST, BagLabels, render_labels
from pos.printing.service import Printer, PrintService
from pos.printing.star import RASTER_IN, RASTER_OUT
from pos.settings import SettingStore
from pos.sync.oplog import OpStore

from ..conftest import T0
from ..orders.test_menu_orders import payload
from .fake_printer import Decoded, decode
from .test_held import HOUR, hub, post
from .test_other_stations import BEER, CHICKEN, send
from .test_stations import menu_with_takeout

TAKEOUT, WOK = "10.0.0.4", "10.0.0.1"  # where `hub` puts the takeout station's printer, and the wok's
PICKUP = {
    "order_type": "takeout",
    "channel": "phone",
    "customer_name": "Linda P.",
    "phone": "781 555 0101",
    "promised_at": T0 + HOUR,
}
DELIVERY = {**PICKUP, "handover": "delivery", "address": "12 Main St, Winchester", "delivery_note": "Ring twice"}
READY = f"READY BY {datetime.fromtimestamp((T0 + HOUR) / 1000):%H:%M}"


def labels(c: TestClient, bags: int, order_id: str = "o1", **body) -> Decoded:
    """The labels as somebody at the counter asks for them: what came out on paper."""
    answer = c.post(f"/orders/{order_id}/bag-labels", json={"bags": bags, **body})
    assert answer.status_code == 202, answer.text
    assert answer.json()["bags"] == bags
    return decode(c.app.state.printing.store.get(answer.json()["job_id"]).data)


def refused(c: TestClient, order_id: str = "o1", **body) -> tuple[int, str]:
    answer = c.post(f"/orders/{order_id}/bag-labels", json=body)
    detail = answer.json().get("detail")
    return answer.status_code, detail.get("error", "") if isinstance(detail, dict) else ""


def words(paper: Decoded) -> list[str]:
    return [line.strip() for line in paper.text if line.strip()]


def test_a_label_for_each_bag_says_whose_it_is_which_bag_and_when():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", CHICKEN, BEER, **PICKUP)
    before = len(c.app.state.printing.store.all())
    paper = labels(c, 3)
    # one job, three labels, each cut off the next, and nothing in it the printer does not know
    assert len(c.app.state.printing.store.all()) == before + 1 and paper.cuts == 3 and not paper.unknown
    text = words(paper)
    assert [line for line in text if line.startswith("BAG ")] == ["BAG 1 OF 3", "BAG 2 OF 3", "BAG 3 OF 3"]
    assert paper.inverted == ["BAG 1 OF 3", "BAG 2 OF 3", "BAG 3 OF 3"]  # white on black: what tells them apart
    # every label is the same but for its number: the order as its ticket heads it, and when it is due
    assert text.count("#1  LINDA P.") == 3 and text.count(READY) == 3
    first = text[: text.index("BAG 2 OF 3") - 1]
    assert first[:3] == ["#1  LINDA P.", "BAG 1 OF 3", READY]
    # a label is no ticket: no dish, no money, nothing in the bag, and it does not ring the printer's bell
    assert not paper.images and paper.beeps == 0
    assert not any("x " in line or "PAID" in line or "$" in line or "BAG" in line[4:] for line in text)
    # and nothing of the customer but the name: the shelf is where other customers stand
    assert not any("555" in line or "Main St" in line for line in text)


def test_one_bag_is_one_label_and_a_delivery_says_so():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", BEER, **DELIVERY)
    paper = labels(c, 1)
    text = words(paper)
    assert paper.cuts == 1 and text[:4] == ["#1  LINDA P.", "BAG 1 OF 1", "DELIVERY", READY]
    # where it goes is on the bill that travels with the bag, not on a label anybody at the shelf reads
    assert not any("Main St" in line or "Ring twice" in line or "555" in line for line in text)


def test_an_order_for_another_day_says_the_day_and_one_with_no_name_its_number():
    clock = [T0 + 100]
    c = hub(clock)
    saturday = T0 + 4 * 24 * HOUR
    send(c, "o1", BEER, order_type="takeout", channel="counter", promised_at=saturday, for_later=True)
    text = words(labels(c, 2))
    due = datetime.fromtimestamp(saturday / 1000)
    assert text[0] == "#1" and text[2] == f"READY BY {due:%H:%M}  {due:%a %b} {due.day}".upper()
    # an order for now with no time on it says no time
    send(c, "o2", BEER, order_type="takeout", channel="counter", customer_name="Omar")
    assert words(labels(c, 1, "o2"))[:2] == ["#2  OMAR", "BAG 1 OF 1"]
    assert not any(line.startswith("READY BY") for line in words(labels(c, 1, "o2")))


def test_what_gets_no_label():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", BEER, **PICKUP)
    send(c, "t1", BEER)  # a table's order
    post(c, payload("open", "create", 5, **PICKUP), order_id="o3")  # a to-go order with no dish on it
    assert refused(c, "t1", bags=2) == (409, "not_to_go")
    assert refused(c, "o3", bags=2) == (409, "nothing_on_order")
    assert c.post("/orders/nobody/bag-labels", json={"bags": 2}).status_code == 404
    # how many bags is said, and is a number of bags
    for bags in (0, -1, BAGS_MOST + 1, "three", None, 1.5, True):
        assert c.post("/orders/o1/bag-labels", json={"bags": bags}).status_code == 422, bags
    assert c.post("/orders/o1/bag-labels", json={}).status_code == 422
    assert c.post("/orders/o1/bag-labels").status_code == 422
    assert labels(c, BAGS_MOST).cuts == BAGS_MOST


def test_printing_labels_changes_nothing_on_the_order():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", CHICKEN, **PICKUP)
    before = (c.get("/orders/o1").json(), c.get("/orders/o1/check").json(), c.get("/orders/o1/history").json())
    labels(c, 4)
    labels(c, 2)  # printed again with another number: nothing kept the first
    after = (c.get("/orders/o1").json(), c.get("/orders/o1/check").json(), c.get("/orders/o1/history").json())
    assert after == before
    # an order that is paid, picked up and closed still prints: a label that tore is printed again
    post(c, payload("close", "close", 900))
    assert labels(c, 1).cuts == 1


def test_where_the_labels_print():
    clock = [T0 + 100]
    c = hub(clock)
    send(c, "o1", BEER, **PICKUP)

    def at(**body) -> tuple[str, str]:
        answer = c.post("/orders/o1/bag-labels", json={"bags": 1, **body}).json()
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
        send(c, "o1", BEER, **PICKUP)
        return c

    plain = location(Printer("wok", WOK, id="wok"), Printer("bar", "10.0.0.3", id="bar"))
    assert plain.post("/orders/o1/bag-labels", json={"bags": 1}).json()["printed_at"]["id"] == "wok"
    assert refused(location(), bags=1) == (409, "no_printer")


@pytest.mark.parametrize("dialect", ["escpos", "star"])
def test_the_labels_in_both_printer_languages_and_on_a_fallback(dialect: str):
    paper = BagLabels(
        order_id="0193f2a7-demo-labels",
        bags=2,
        order_no=12,
        customer="陈 Chen",
        delivery=True,
        promised=datetime(2026, 11, 21, 12, 0),
        at=datetime(2026, 11, 19, 9, 41),
        reprinted_from="Takeout",
    )
    data = render_labels(paper, dialect=dialect)
    assert data == render_labels(paper, dialect=dialect)  # the same paper is the same bytes
    if dialect == "star":
        # a Star cuts where a drawn page ends, so each label is a page of its own: two labels, two cuts
        assert data != render_labels(paper, dialect="escpos")
        assert data.count(RASTER_IN) == 2 and data.count(RASTER_OUT) == 2
        return
    printed = decode(data)
    text = words(printed)
    # a name that is not in the printer's own letters is drawn, as a dish's is
    assert len(printed.images) == 2 and printed.cuts == 2
    down = "TAKEOUT PRINTER DOWN, PRINTED HERE"
    assert printed.inverted == [down, "BAG 1 OF 2", down, "BAG 2 OF 2"]
    assert text.count("DELIVERY") == 2 and text.count("READY BY 12:00  SAT NOV 21") == 2
    assert text[-1] == "o-labels  2026-11-19 09:41:00"


def test_a_fallback_printer_takes_the_labels_headed_with_whose_they_are():
    clock = [T0 + 100]
    printers = [Printer("takeout", TAKEOUT, id="takeout", fallbacks=("wok",)), Printer("wok", WOK, id="wok")]
    service = PrintService(printers, direct=False, now=lambda: clock[0])
    c = TestClient(create_app(OpStore(physical=lambda: T0 + 100), menu=menu_with_takeout(), printing=service))
    send(c, "o1", BEER, **PICKUP)
    answer = c.post("/orders/o1/bag-labels", json={"bags": 2}).json()
    job = c.app.state.printing.store.get(answer["job_id"])
    ((address, data),) = job.fallbacks
    assert address == WOK and decode(data).inverted.count("TAKEOUT PRINTER DOWN, PRINTED HERE") == 2
