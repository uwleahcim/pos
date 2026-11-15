"""Taking lines off, changing them, and what the kitchen is told: nothing before a line is sent, a VOID in
white on black after, and only the lines not sent yet on each fire."""

from __future__ import annotations

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.printing.service import Printer, PrintService
from pos.printing.ticket import Ticket, TicketLine, render
from pos.sync.oplog import OpStore, replay

from ..conftest import T0, servers_void
from .fake_printer import decode
from .test_service import op, payload

START = [
    op("a", "create", 0, table="A7", server="Amy", guests=2),
    op("b", "add_line", 1, line_id="L1", item="Sweet & Sour Chicken", course="2", seat=1),
    op("c", "add_line", 2, line_id="L2", item="Spring Roll", course="1", seat=2),
]


def setup():
    service = PrintService([Printer("kitchen", "10.0.0.1")], direct=False)
    client = TestClient(create_app(OpStore(physical=lambda: T0 + 100), printing=service, settings=servers_void()))
    client.post("/orders/o1/ops", json=[payload(o) for o in START])
    return client, service


def tickets(service: PrintService) -> list:
    return [decode(job.data) for job in service.store.all()]


def post(client: TestClient, *ops) -> dict:
    return client.post("/orders/o1/ops", json=[payload(o) for o in ops]).json()


def test_a_line_taken_off_before_it_is_fired_is_just_removed():
    client, service = setup()
    post(client, op("d", "void_line", 3, line_id="L1"))
    order = client.get("/orders/o1").json()
    assert order["lines"]["L1"]["status"] == "removed"
    assert [line["line_id"] for line in client.get("/orders/o1/check").json()["lines"]] == ["L2"]
    assert post(client, op("e", "fire", 4, course="*"))["print_jobs"] == ["e:kitchen"]
    (ticket,) = tickets(service)
    assert not any("Sweet & Sour" in t for t in ticket.text) and ticket.inverted == []


def test_a_fired_line_taken_off_prints_a_void_at_once_in_reverse():
    client, service = setup()
    post(client, op("d", "fire", 3, course="2"))
    assert post(client, op("e", "void_line", 4, line_id="L1", reason="kitchen-error"))["print_jobs"] == ["e:kitchen"]
    assert client.get("/orders/o1").json()["lines"]["L1"]["status"] == "void"
    fire, void = tickets(service)
    assert any("1 x Sweet & Sour" in t for t in fire.text) and fire.inverted == []
    assert void.text[0] == "*** VOID *** KITCHEN"
    assert void.inverted == ["VOID 1 x Sweet & Sour", "Chicken [s1]"]  # wrapped at double width, all reversed
    assert client.get("/orders/o1/check").json()["lines"][0]["line_id"] == "L2"


def test_each_fire_sends_only_the_lines_not_sent_yet():
    client, service = setup()
    post(client, op("d", "fire", 3, course="2"))
    post(client, op("e", "add_line", 4, line_id="L3", item="Fried Rice", course="2", seat=2))
    floor = client.get("/floor").json()["status"]["A7"][0]
    assert floor["fired"] == ["2"] and floor["held"] == ["1", "2"]  # entrees fired, but one more is waiting
    assert client.get("/orders/o1").json()["lines"]["L3"]["fired"] is False
    post(client, op("f", "fire", 5, course="2"))
    first, second = tickets(service)
    assert any("Sweet & Sour" in t for t in first.text)
    assert not any("Sweet & Sour" in t for t in second.text) and any("Fried Rice" in t for t in second.text)
    # firing a course with nothing new prints nothing
    assert post(client, op("g", "fire", 6, course="2"))["print_jobs"] == []


def test_changing_a_fired_line_prints_the_void_and_the_new_dish_on_one_ticket():
    client, service = setup()
    post(client, op("d", "fire", 3, course="2"))
    change = post(
        client,
        op("e", "void_line", 4, line_id="L1", reason="changed"),
        op(
            "f",
            "add_line",
            5,
            line_id="L4",
            item="Sweet & Sour Chicken - brown rice",
            course="2",
            seat=1,
            replaces="L1",
        ),
        op("g", "fire", 6, course="2"),
    )
    assert change["print_jobs"] == ["e:kitchen"]
    _, ticket = tickets(service)
    assert ticket.text[0] == "*** MODIFY *** KITCHEN"
    assert ticket.inverted[0] == "VOID 1 x Sweet & Sour"
    assert any("brown rice" in t for t in ticket.text)
    assert not any("brown rice" in t for t in ticket.inverted)


def test_the_order_keeps_what_was_chosen_so_a_screen_can_reopen_it():
    state = replay(
        [
            op("a", "create", 0),
            op("b", "add_line", 1, line_id="L1", item="X", request={"variant_id": "V", "selections": []}),
        ]
    )
    line = state.snapshot()["lines"]["L1"]
    assert line["request"] == {"variant_id": "V", "selections": []} and line["fired"] is False


def test_a_chinese_void_line_is_drawn_white_on_black():
    plain = TicketLine(1, "左宗鸡")
    void = TicketLine(1, "左宗鸡", void=True)
    for dialect in ("escpos", "star"):
        a = render(_ticket(plain), dialect=dialect)
        b = render(_ticket(void), dialect=dialect)
        # the reversed strip is mostly ink: the job has far more set bits
        assert _ink(b) > _ink(a) + 2000


def _ticket(line: TicketLine) -> Ticket:
    return Ticket(station="Wok", kind="void", order_id="o1", ticket_no=1, table="1", lines=(line,))


def _ink(data: bytes) -> int:
    return sum(bin(b).count("1") for b in data)
