"""Tax-exempt checks (the Toast comparison's row 19): a manager marks one check exempt from sales tax, for an
organisation and under the number of its certificate. The hub asks for the manager's PIN and keeps who it
was; the check is charged no tax and says for whom; the bill, the day, the sales and the check's history all
say so. Every dish on it is sold and counted as on any check: only the tax is not charged."""

from __future__ import annotations

from decimal import Decimal

import pytest

from pos.orders.check import check_for
from pos.orders.exempt import CERTIFICATE_MAX, ORGANISATION_MAX, exemption_of
from pos.printing.bill import bill_for
from pos.sync.hlc import HLC
from pos.sync.oplog import replay
from pos.tax import massachusetts

from ..conftest import make_op
from ..printing.fake_printer import decode
from ..printing.test_bill import paper
from .test_day import BEER, DSN, EGGROLL, PUPU, WINGS, Hub, _ids, at, money
from .test_history import said, steps
from .test_sales import sales

PTA = {"organisation": "Winchester PTA", "certificate": "E-123-456-789"}


def send(h: Hub, order_id: str, op_kind: str, when: int, /, **data) -> dict:
    """One operation as a screen sends it, and the hub's answer: what it took and what it refused."""
    h.now = max(h.now, when)
    body = {
        "op_id": f"{order_id}-{op_kind}-{next(_ids)}",
        "order_id": order_id,
        "hlc": str(HLC(when, next(_ids), "t1")),
        "device": "t1",
        "kind": op_kind,
        "data": data,
    }
    answer = h.c.post(f"/orders/{order_id}/ops", json=[body])
    assert answer.status_code == 202, answer.text
    return answer.json()


def pin(h: Hub, order_id: str = "o1", who: str = "9999", purpose: str = "exempt") -> str:
    body = {"device": "t1", "pin": who, "order_id": order_id, "purpose": purpose}
    answer = h.c.post("/approvals", json=body)
    assert answer.status_code == 200, answer.text
    return answer.json()["approval"]


def exempt(h: Hub, order_id: str, when: int, **said) -> dict:
    """Amy marks the check exempt for the PTA with the manager's PIN; `said` changes what is sent."""
    data = {"tax_exempt": PTA, "approval": pin(h, order_id), "by": "Amy", "by_id": "s1", **said}
    return send(h, order_id, "set_field", when, **data)


def codes(answer: dict) -> list[list[str]]:
    return [[p["code"] for p in r["problems"]] for r in answer["refused"]]


def supper(h: Hub | None = None, order_id: str = "o1", table: str = "12") -> Hub:
    """A table of two with wings and two egg rolls, sent: 15.95 of food, 1.12 of tax, 17.07 in all."""
    h = h or Hub(now=at(17))
    h.table(order_id, at(17), table=table)
    h.ring(order_id, "L1", WINGS, at(17, 5))
    h.ring(order_id, "L2", EGGROLL, at(17, 6), qty=2)
    h.op(order_id, "fire", at(17, 7), course="*")
    return h


def sums(check: dict) -> tuple[str, str, str]:
    return check["subtotal"], check["tax"], check["total"]


def test_a_manager_marks_a_check_exempt_and_it_is_charged_no_tax():
    h = supper()
    assert sums(h.check("o1")) == ("15.95", "1.12", "17.07") and "tax_exempt" not in h.check("o1")
    answer = exempt(h, "o1", at(17, 20), tax_exempt={"organisation": "  Winchester   PTA ", "certificate": " E-1 "})
    assert answer["refused"] == []
    check = h.check("o1")
    assert sums(check) == ("15.95", "0.00", "15.95") and check["due"] == "15.95"
    assert check["tax_exempt"] == {
        "organisation": "Winchester PTA",
        "certificate": "E-1",
        "approved_by": "Mike",
        "approved_by_id": "s3",
        "by": "Amy",
        "at_ms": at(17, 20),
        "tax": "1.12",  # what was not charged
    }
    # the rates are still named, at nothing, so a screen with no hub still knows them for its next check
    assert [(t["rate_pct"], t["base"], t["amount"]) for t in check["tax_lines"]] == [
        ("6.25", "0.00", "0.00"),
        ("0.75", "0.00", "0.00"),
    ]
    assert check["tax_rate_pct"] == "7.00" and check["exempts"] is True
    # every dish is still on it at its price, and more food is still not taxed
    assert [(row["name"], row["total"]) for row in check["lines"]] == [("Chicken wings", "8.95"), ("Egg roll", "7.00")]
    h.ring("o1", "L3", BEER, at(17, 30))
    assert sums(h.check("o1")) == ("22.45", "0.00", "22.45") and h.check("o1")["tax_exempt"]["tax"] == "1.57"
    # the order itself keeps the mark with the manager, and never the token
    kept = h.c.get("/orders/o1").json()["fields"]["tax_exempt"]
    assert kept["approved_by"] == {"staff_id": "s3", "name": "Mike"} and "approval" not in str(kept)


def test_only_a_managers_pin_for_this_check_and_this_purpose_marks_it():
    h = supper()
    supper(h, "o2", table="5")
    # a server's PIN is no approval at all
    refused = h.c.post("/approvals", json={"device": "t1", "pin": "1111", "order_id": "o1", "purpose": "exempt"})
    assert refused.status_code == 403
    for claim in (
        {"approval": None},  # nobody asked
        {"approval": "not-a-token"},
        {"approval": pin(h, "o2")},  # the manager approved another check
        {"approval": pin(h, "o1", purpose="void")},  # or something else on this one
        {"approval": pin(h, "o1", purpose="adjust")},
        # what a terminal says of approval itself counts for nothing
        {"approval": None, "approved_by": {"staff_id": "s3", "name": "Mike"}},
        {"approval": None, "tax_exempt": {**PTA, "approved_by": {"staff_id": "s3", "name": "Mike"}}},
    ):
        claim = {name: value for name, value in claim.items() if value is not None}
        answer = send(h, "o1", "set_field", at(17, 20), **{"tax_exempt": PTA, "by": "Amy", **claim})
        assert codes(answer) == [["needs_approval"]], claim
        assert answer["refused"][0]["error"] == "invalid_exemption"
        assert sums(h.check("o1")) == ("15.95", "1.12", "17.07") and "tax_exempt" not in h.check("o1")
        assert "tax_exempt" not in h.c.get("/orders/o1").json()["fields"]
    # an approval is good for the one check: the other is still taxed
    assert exempt(h, "o1", at(17, 21))["refused"] == []
    assert h.check("o1")["tax"] == "0.00" and h.check("o2")["tax"] == "1.12"


def test_it_names_the_organisation_and_the_number_of_its_certificate():
    h = supper()
    for wanted, problems in (
        ({"organisation": "", "certificate": "E-1"}, ["no_organisation"]),
        ({"organisation": "   ", "certificate": "E-1"}, ["no_organisation"]),
        ({"organisation": "Winchester PTA"}, ["no_certificate"]),
        ({"organisation": 7, "certificate": None}, ["no_organisation", "no_certificate"]),
        ({"organisation": "x" * (ORGANISATION_MAX + 1), "certificate": "E-1"}, ["bad_value"]),
        ({"organisation": "Winchester PTA", "certificate": "9" * (CERTIFICATE_MAX + 1)}, ["bad_value"]),
        ("the PTA", ["bad_request"]),
        (True, ["bad_request"]),
        ([], ["bad_request"]),
    ):
        assert codes(exempt(h, "o1", at(17, 20), tax_exempt=wanted)) == [problems], wanted
        assert h.check("o1")["tax"] == "1.12"
    longest = {"organisation": "x" * ORGANISATION_MAX, "certificate": "9" * CERTIFICATE_MAX}
    assert exempt(h, "o1", at(17, 21), tax_exempt=longest)["refused"] == []
    assert h.check("o1")["tax"] == "0.00"


def test_a_check_is_marked_before_it_is_paid_and_while_it_is_open():
    h = supper()
    h.pay("o1", at(17, 30), "5.00")
    assert codes(exempt(h, "o1", at(17, 31))) == [["paid"]]  # what was paid was paid with the tax in it
    assert sums(h.check("o1")) == ("15.95", "1.12", "17.07")
    supper(h, "o2", table="5")
    h.op("o2", "close", at(17, 40))
    assert codes(exempt(h, "o2", at(17, 41))) == [["closed"]]
    h.op("o2", "reopen", at(17, 42))
    assert exempt(h, "o2", at(17, 43))["refused"] == [] and h.check("o2")["tax"] == "0.00"
    # a payment and the mark sent together (a screen back from an outage) are a mark on a paid check
    supper(h, "o3", table="7")
    batch = [
        {"kind": "pay", "data": {"payment_id": "P1", "method": "cash", "amount": "5.00"}},
        {"kind": "set_field", "data": {"tax_exempt": PTA, "approval": pin(h, "o3"), "by": "Amy"}},
    ]
    ops = [
        {"op_id": f"o3-x{n}", "order_id": "o3", "hlc": str(HLC(at(17, 50), n, "t1")), "device": "t1", **op}
        for n, op in enumerate(batch)
    ]
    h.now = at(17, 50)
    answer = h.c.post("/orders/o3/ops", json=ops).json()
    assert codes(answer) == [["paid"]] and h.check("o3")["paid"] == "5.00" and h.check("o3")["tax"] == "1.12"


def test_taking_the_mark_off_puts_the_tax_back_and_needs_no_manager():
    h = supper()
    exempt(h, "o1", at(17, 20))
    assert h.check("o1")["tax"] == "0.00"
    assert send(h, "o1", "set_field", at(17, 30), tax_exempt=None, by="Amy", by_id="s1")["refused"] == []
    assert sums(h.check("o1")) == ("15.95", "1.12", "17.07") and "tax_exempt" not in h.check("o1")
    # marked again, paid without the tax and closed: the closed check is left as it was settled
    exempt(h, "o1", at(17, 40))
    h.pay("o1", at(17, 41), "15.95", "card")
    h.op("o1", "close", at(17, 42))
    assert codes(send(h, "o1", "set_field", at(17, 50), tax_exempt=None, by="Amy")) == [["closed"]]
    assert h.check("o1")["tax"] == "0.00" and h.check("o1")["due"] == "0.00"
    # taken off a paid check that is still open, the tax is owed again: nothing is hidden
    supper(h, "o2", table="5")
    exempt(h, "o2", at(18))
    h.pay("o2", at(18, 1), "15.95", "card")
    assert send(h, "o2", "set_field", at(18, 2), tax_exempt=None)["refused"] == []
    assert h.check("o2")["total"] == "17.07" and h.check("o2")["due"] == "1.12"


def test_whatever_else_the_operation_says_of_the_order_goes_through_without_the_mark():
    h = Hub(now=at(17))
    opened = send(h, "o1", "create", at(17), table="12", guests=2, order_type="dine_in", tax_exempt=PTA)
    assert codes(opened) == [["needs_approval"]]
    fields = h.c.get("/orders/o1").json()["fields"]
    assert fields["table"] == "12" and "tax_exempt" not in fields  # the table is open, and taxed
    moved = send(h, "o1", "set_field", at(17, 1), table="14", tax_exempt={"organisation": "PTA"})
    assert codes(moved) == [["no_certificate", "needs_approval"]]
    assert h.c.get("/orders/o1").json()["fields"]["table"] == "14"
    alone = send(h, "o1", "set_field", at(17, 2), tax_exempt=PTA)
    assert codes(alone) == [["needs_approval"]] and alone["accepted"] == []


def test_a_mark_with_no_manager_behind_it_is_no_exemption():
    manager = {"staff_id": "s3", "name": "Mike"}
    assert exemption_of({"tax_exempt": {**PTA, "approved_by": manager, "by": "Amy", "at_ms": 5}}) == {
        **PTA,
        "approved_by": "Mike",
        "approved_by_id": "s3",
        "by": "Amy",
        "at_ms": 5,
    }
    for value in (None, True, "PTA", PTA, {**PTA, "approved_by": "Mike"}, {**PTA, "approved_by": {"name": "Mike"}}):
        assert exemption_of({"tax_exempt": value}) is None, value
    assert exemption_of({"tax_exempt": {"organisation": " ", "certificate": "E-1", "approved_by": manager}}) is None
    # a log that holds such a mark all the same (it could only come from somewhere that is not the hub) is taxed
    state = replay(
        [
            make_op("create", at=0, table="5", order_type="dine_in"),
            make_op("add_line", at=1, line_id="L1", item="Tea", priced={"unit_price": "10.00", "name": "Tea"}),
            make_op("set_field", at=2, tax_exempt=PTA),
        ],
        "o1",
    )
    check = check_for(state, massachusetts())
    assert check["tax"] == "0.71" and "tax_exempt" not in check


def test_a_charge_on_an_exempt_check_is_not_taxed_either():
    h = Hub(now=at(17))
    h.op("o1", "create", at(17), order_type="delivery", customer_name="Winchester PTA", channel="phone")
    h.ring("o1", "L1", PUPU, at(17, 1))
    before = h.check("o1")
    assert [(c["name"], c["amount"], c["taxed"]) for c in before["charges"]] == [("Delivery fee", "4.00", True)]
    assert sums(before) == ("16.95", "1.47", "22.42")  # the fee is taxed like the food
    exempt(h, "o1", at(17, 5))
    after = h.check("o1")
    assert [(c["name"], c["amount"], c["taxed"]) for c in after["charges"]] == [("Delivery fee", "4.00", False)]
    assert sums(after) == ("16.95", "0.00", "20.95") and after["tax_exempt"]["tax"] == "1.47"


def test_a_split_table_that_is_exempt_owes_no_tax_on_any_of_its_checks():
    h = Hub(now=at(17))
    h.table("o1", at(17))
    h.op("o1", "add_line", at(17, 1), line_id="L1", item="?", request=WINGS, seat=1, by="Amy", by_id="s1")
    h.op("o1", "add_line", at(17, 2), line_id="L2", item="?", request=BEER, seat=2, by="Amy", by_id="s1")
    h.op("o1", "set_field", at(17, 3), split={"by": "seat"})
    assert [(c["tax"], c["total"]) for c in h.check("o1")["checks"]] == [("0.63", "9.58"), ("0.46", "6.96")]
    exempt(h, "o1", at(17, 5))
    check = h.check("o1")
    assert [(c["tax"], c["total"]) for c in check["checks"]] == [("0.00", "8.95"), ("0.00", "6.50")]
    assert check["total"] == "15.45" == str(sum(Decimal(c["total"]) for c in check["checks"]))
    h.op("o1", "set_field", at(17, 6), split={"by": "even", "ways": 2})
    assert [c["total"] for c in h.check("o1")["checks"]] == ["7.73", "7.72"]


def test_the_bill_says_tax_exempt_for_whom_and_under_which_certificate():
    h = supper()
    taxed = paper(bill_for(h.check("o1"), {"table": "12", "guests": 2}))
    assert any(line.startswith("Sales tax 7%") and line.endswith("1.12") for line in taxed)
    assert not any("exempt" in line.lower() or "Certificate" in line for line in taxed)
    exempt(h, "o1", at(17, 20))
    lines = paper(bill_for(h.check("o1"), {"table": "12", "guests": 2}))
    place = next(i for i, line in enumerate(lines) if line.startswith("Tax exempt"))
    assert lines[place].endswith("0.00")
    assert lines[place + 1 : place + 3] == ["  Winchester PTA", "  Certificate E-123-456-789"]
    assert not any(line.startswith("Sales tax") for line in lines)
    assert any(line.startswith("TOTAL") and line.endswith("$15.95") for line in lines)
    # and the bill a guest is handed from the hub's own printer says the same
    answer = h.c.post("/orders/o1/bill", json={})
    assert answer.status_code == 202, answer.text
    printed = [line.strip() for line in decode(h.printing.store.get(answer.json()["job_id"]).data).text]
    assert "Winchester PTA" in printed and "Certificate E-123-456-789" in printed


def night(h: Hub | None = None) -> Hub:
    """Monday the 16th: o1, the PTA's table, exempt, paid by card and closed; o2, a table that pays its tax."""
    h = supper(h)
    exempt(h, "o1", at(17, 20))
    h.pay("o1", at(18), "15.95", "card")
    h.op("o1", "close", at(18, 1))
    supper(h, "o2", table="5")
    h.pay("o2", at(18, 30), "17.07", "cash")
    h.op("o2", "close", at(18, 31))
    h.now = at(21)
    return h


def read(h: Hub) -> None:
    report = h.report()
    # every dish of both tables is sold; the tax is the one table's
    assert report["checks"] == 2
    assert {name: money(amount) for name, amount in report["sales"].items()} == {
        "gross": money("31.90"),
        "discounts": money("0"),
        "net": money("31.90"),
        "charges": money("0"),
        "gratuity": money("0"),
        "tax": money("1.12"),
        "total": money("33.02"),
    }
    assert money(report["money"]["taken_total"]) == money("33.02") and money(report["money"]["due"]) == 0
    exempted = report["tax_exempt"]
    assert (exempted["count"], exempted["sales"], exempted["tax"]) == (1, "15.95", "1.12")
    assert [
        said(row, "order_id", "table", "total", "organisation", "certificate", "approved_by", "by", "tax")
        for row in exempted["checks"]
    ] == [("o1", "12", "15.95", "Winchester PTA", "E-123-456-789", "Mike", "Amy", "1.12")]
    span = sales(h, "2026-11-16", "2026-11-16")["span"]
    assert {name: money(amount) for name, amount in span["sales"].items()} == {
        name: money(amount) for name, amount in report["sales"].items()
    }
    assert span["tax_exempt"] == {"count": 1, "sales": "15.95", "tax": "1.12"}
    # a day with none says none
    for quiet in (h.report("2026-11-10"), sales(h, "2026-11-10", "2026-11-10")["span"]):
        none = quiet["tax_exempt"]
        assert (none["count"], money(none["sales"]), money(none["tax"])) == (0, 0, 0)
        assert none.get("checks", []) == []


def test_the_day_and_the_sales_count_every_sale_and_say_what_was_exempt():
    read(night())


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_same_from_postgresql():
    import psycopg

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS ops, orders")
    h = Hub(now=at(17), postgres=DSN)
    try:
        read(night(h))
        assert h.store.view("o1").fields["tax_exempt"]["approved_by"] == {"staff_id": "s3", "name": "Mike"}
    finally:
        h.store.close()


def test_the_printed_day_lists_each_exempt_check():
    h = night()
    answer = h.c.post("/reports/day/print", json={"day": "2026-11-16"}, headers=h.manager())
    assert answer.status_code == 202, answer.text
    text = [line.strip() for line in decode(h.printing.store.get(answer.json()["job_id"]).data).text if line.strip()]
    start = text.index("TAX EXEMPT")
    block = text[start : start + 5]
    assert block[1].startswith("Sales on 1 check") and block[1].endswith("15.95")
    assert block[2].startswith("Tax not charged") and block[2].endswith("1.12")
    assert block[3].startswith("Winchester PTA") and block[3].endswith("15.95")
    assert block[4] == "Certificate E-123-456-789, approved by Mike"
    # a day with none prints no such block
    quiet = h.c.post("/reports/day/print", json={"day": "2026-11-10"}, headers=h.manager())
    text = [line.strip() for line in decode(h.printing.store.get(quiet.json()["job_id"]).data).text]
    assert "TAX EXEMPT" not in text


def test_the_checks_history_says_who_marked_it_who_approved_and_when_it_came_off():
    h = supper()
    exempt(h, "o1", at(17, 20))
    send(h, "o1", "set_field", at(17, 30), tax_exempt=None, by="Ben", by_id="s2")
    send(h, "o1", "set_field", at(17, 31), tax_exempt=None, by="Ben", by_id="s2")  # nothing to take off: no step
    mine = [step for step in steps(h) if step["what"].startswith("tax_exempt")]
    assert [said(step, "what", "at_ms", "by", "approved_by", "organisation") for step in mine] == [
        ("tax_exempt", at(17, 20), "Amy", "Mike", "Winchester PTA"),
        ("tax_exempt_removed", at(17, 30), "Ben", "", "Winchester PTA"),
    ]
    assert mine[0]["certificate"] == "E-123-456-789" and "certificate" not in mine[1]
