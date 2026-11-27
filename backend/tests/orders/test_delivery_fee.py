"""What a delivery costs the customer (docs/delivery.md, "The delivery fee").

The location lists its prices by how far a delivery goes, or by how long the drive is: bands, each "up to so
far, this much". Whoever takes the order picks the band, the hub fills in what it costs, and the check
charges it while the order is a delivery. It is off until the owner lists the prices, it is a charge of its
own on the check and on the bill, and it is in the sales with the other charges."""

from __future__ import annotations

from decimal import Decimal

import pytest

from pos.orders.check import check_for
from pos.orders.delivery_fee import CHARGE_ID, band_of, fee_charged, fee_of, fee_ops
from pos.printing.bill import bill_for
from pos.settings import DEFAULTS, clean_delivery_fee
from pos.sync.oplog import replay
from pos.tax import massachusetts

from ..conftest import make_op
from ..printing.test_bill import AT, paper
from .test_counter import TEA, client, manager, payload, takeout
from .test_day import EGGROLL, Hub, at
from .test_delivery import ELM
from .test_history import steps

MILES = {
    "enabled": True,
    "by": "miles",
    "bands": [{"up_to": "2", "fee": "3.00"}, {"up_to": "4.5", "fee": "5.00"}, {"up_to": "8", "fee": "8.50"}],
    "taxed": False,
}
MINUTES = {"enabled": True, "by": "minutes", "bands": [{"up_to": 10, "fee": 3}, {"up_to": 20, "fee": "6.5"}]}
NO_LOOKUP = {"origin": "", "maps": False, "lookup": False, "services": [], "live": False}
"""What a hub with no map service says beside the prices (tests/orders/test_delivery_distance.py)."""


def priced(c, fee: dict = MILES) -> dict:
    """The location lists its prices."""
    saved = c.put("/settings/delivery_fee", json=fee, headers=manager(c))
    assert saved.status_code == 200, saved.text
    return saved.json()


def brought(c, order_id: str = "o1", when: int = 0, **fields) -> None:
    """A phone order with a pot of tea ($10.00, $0.71 tax) that is brought to Elm Street."""
    takeout(c, order_id, when, channel="phone", handover="delivery", address=ELM, **fields)


def pick(c, up_to, when: int = 50, order_id: str = "o1", **more) -> dict:
    """Whoever takes the order picks the band, as a screen says it; what the hub answered."""
    op = payload(f"{order_id}-fee-{when}", "set_field", when, order_id, delivery_fee=up_to, **more)
    answer = c.post(f"/orders/{order_id}/ops", json=[op])
    assert answer.status_code == 202, answer.text
    return answer.json()


def check(c, order_id: str = "o1") -> dict:
    return c.get(f"/orders/{order_id}/check").json()


def carried(c, order_id: str = "o1"):
    return c.get(f"/orders/{order_id}").json()["fields"].get("delivery_fee")


# The prices ---------------------------------------------------------------------------------------------------


def test_no_fee_is_charged_until_the_owner_lists_the_prices():
    c = client()
    off = {"enabled": False, "by": "miles", "bands": [], "taxed": False}
    assert c.get("/settings/delivery_fee").json() == {**off, **NO_LOOKUP}
    brought(c)
    assert check(c)["charges"] == [] and check(c)["total"] == "10.71"
    # and a band cannot be picked: there is none
    refused = pick(c, {"up_to": "2"})["refused"]
    assert [r["error"] for r in refused] == ["invalid_delivery_fee"] and "no delivery fee is charged" in str(refused)
    assert carried(c) is None and check(c)["total"] == "10.71"


def test_a_manager_lists_the_prices_by_miles_or_by_minutes():
    c = client()
    asked = {
        "enabled": True,
        "by": "Miles",
        "bands": [{"up_to": 8, "fee": 8.5}, {"up_to": "2.0", "fee": "3"}, {"up_to": 4.5, "fee": "5.00"}],
    }
    assert c.put("/settings/delivery_fee", json=asked).status_code == 401
    server, _ = c.app.state.tokens.issue("s1", "Amy", "server")
    refused = c.put("/settings/delivery_fee", json=asked, headers={"authorization": f"Bearer {server}"})
    assert refused.status_code == 403
    # kept in order of how far they reach, each as "up to 2.5" and dollars and cents
    assert priced(c, asked) == {**MILES, **NO_LOOKUP}
    assert c.get("/settings/delivery_fee").json() == {**MILES, **NO_LOOKUP}
    assert priced(c, MINUTES) == {
        "enabled": True,
        "by": "minutes",
        "bands": [{"up_to": "10", "fee": "3.00"}, {"up_to": "20", "fee": "6.50"}],
        "taxed": False,
        **NO_LOOKUP,
    }
    # turned off, the prices may stay listed for the day it is turned on again, or go
    assert priced(c, {**MILES, "enabled": False})["bands"] == MILES["bands"]
    assert priced(c, {"enabled": False}) == {**DEFAULTS["delivery_fee"], **NO_LOOKUP}


def test_miles_may_be_a_fraction_of_a_mile_to_a_hundredth():
    """The owner's words, 2026-11-27: "Allow fractional miles like 0.25 miles"."""
    c = client()
    quarters = {
        "enabled": True,
        "bands": [
            {"up_to": 1, "fee": 4},
            {"up_to": "0.25", "fee": 0},
            {"up_to": 0.5, "fee": "2.5"},
            {"up_to": ".75", "fee": 3},
        ],
    }
    # kept nearest first, each as it is said: "0.25", never "0.250" or ".25"
    kept = priced(c, quarters)["bands"]
    assert kept == [
        {"up_to": "0.25", "fee": "0.00"},
        {"up_to": "0.5", "fee": "2.50"},
        {"up_to": "0.75", "fee": "3.00"},
        {"up_to": "1", "fee": "4.00"},
    ]
    assert clean_delivery_fee({"bands": [{"up_to": "0.01", "fee": 1}, {"up_to": "99.99", "fee": 2}]})["bands"] == [
        {"up_to": "0.01", "fee": "1.00"},
        {"up_to": "99.99", "fee": "2.00"},
    ]
    # a band is picked by it however a screen writes the number, and the order carries it
    assert band_of(c.get("/settings/delivery_fee").json(), "0.250") == {"up_to": "0.25", "fee": "0.00"}
    brought(c)
    assert pick(c, {"up_to": "0.75"})["refused"] == []
    assert carried(c) == {"by": "miles", "up_to": "0.75", "amount": "3.00", "taxed": False}
    assert fee_of({"delivery_fee": carried(c)})["up_to"] == "0.75"
    assert [(row["name"], row["amount"]) for row in check(c)["charges"]] == [("Delivery fee", "3.00")]
    # one the list does not hold is refused as ever
    refused = pick(c, {"up_to": "0.7"}, when=60)["refused"]
    assert [r["error"] for r in refused] == ["invalid_delivery_fee"] and carried(c)["up_to"] == "0.75"


def test_what_the_prices_refuse():
    assert clean_delivery_fee({}) == DEFAULTS["delivery_fee"]
    free_close_by = clean_delivery_fee({"enabled": True, "bands": [{"up_to": 1, "fee": 0}]})
    assert free_close_by["bands"] == [{"up_to": "1", "fee": "0.00"}]
    for bad, why in [
        ({"enabled": "yes"}, "enabled must be true or false"),
        ({"taxed": 1}, "taxed must be true or false"),
        ({"by": "feet"}, "miles or minutes"),
        ({"enabled": True}, "at least one distance"),
        ({"bands": "2 miles"}, "a list of"),
        ({"bands": [{"up_to": n + 1, "fee": 1} for n in range(9)]}, "at most 8 bands"),
        ({"bands": [{"up_to": 0, "fee": 1}]}, "a number of miles"),
        ({"bands": [{"up_to": 2.255, "fee": 1}]}, "to a hundredth, from 0.01"),
        ({"bands": [{"up_to": "0.001", "fee": 1}]}, "to a hundredth"),
        ({"bands": [{"up_to": 101, "fee": 1}]}, "to 100"),
        ({"bands": [{"up_to": True, "fee": 1}]}, "a number of miles"),
        ({"by": "minutes", "bands": [{"up_to": 7.5, "fee": 1}]}, "a whole number of minutes"),
        ({"by": "minutes", "bands": [{"up_to": 241, "fee": 1}]}, "to 240"),
        ({"bands": [{"up_to": 2, "fee": 1}, {"up_to": "2.0", "fee": 2}]}, "up to 2 miles is listed twice"),
        ({"bands": [{"up_to": 0.25, "fee": 1}, {"up_to": ".250", "fee": 2}]}, "up to 0.25 miles is listed twice"),
        ({"bands": [{"up_to": 2, "fee": -1}]}, "dollars and cents"),
        ({"bands": [{"up_to": 2, "fee": "1.005"}]}, "dollars and cents"),
        ({"bands": [{"up_to": 2, "fee": "1000"}]}, "to 999.99"),
        ({"bands": [{"up_to": 2}]}, "dollars and cents"),
    ]:
        with pytest.raises(ValueError, match=why):
            clean_delivery_fee(bad)
    c = client()
    refused = c.put("/settings/delivery_fee", json={"enabled": True, "bands": []}, headers=manager(c))
    assert refused.status_code == 422 and refused.json()["detail"]["error"] == "bad_value"


# The band on an order -----------------------------------------------------------------------------------------


def test_the_band_picked_is_charged_as_a_fee_of_its_own_and_is_not_taxed():
    c = client()
    priced(c)
    brought(c)
    assert pick(c, {"up_to": 4.5}, by="Amy", by_id="s1")["refused"] == []
    # the hub filled in what that band costs here, what it goes by and whether it is taxed
    assert carried(c) == {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False}
    bill = check(c)
    assert bill["charges"] == [
        {
            "charge_id": CHARGE_ID,
            "name": "Delivery fee",
            "kind": "amount",
            "value": "5.00",
            "amount": "5.00",
            "gratuity": False,
            "automatic": False,
            "taxed": False,
            "delivery": {"by": "miles", "up_to": "4.5"},
        }
    ]
    # the dish is taxed as it was; the fee adds no tax
    assert (bill["subtotal"], bill["charge_total"], bill["tax"], bill["total"]) == ("10.00", "5.00", "0.71", "15.71")
    assert [(t["component"], t["base"]) for t in bill["tax_lines"]] == [
        ("ma_meals", "10.00"),
        ("ma_local_meals", "10.00"),
    ]
    assert bill["due"] == "15.71"


def test_a_fee_the_location_taxes_is_taxed_and_a_tax_exempt_check_is_not():
    c = client()
    priced(c, {**MILES, "taxed": True})
    brought(c)
    pick(c, {"up_to": "2"})
    bill = check(c)
    assert carried(c)["taxed"] is True and bill["charges"][0]["taxed"] is True
    assert (bill["tax"], bill["total"]) == ("0.91", "13.91")  # 7% of 13.00
    assert [t["base"] for t in bill["tax_lines"]] == ["13.00", "13.00"]
    # a check a manager marked exempt pays the fee and no tax on it
    asked = {"device": "t1", "pin": "9999", "order_id": "o1", "purpose": "exempt"}
    approval = c.post("/approvals", json=asked).json()["approval"]
    exempt = {"organisation": "Town of Winchester", "certificate": "E-123"}
    op = payload("ex", "set_field", 60, tax_exempt=exempt, approval=approval, by="Amy", by_id="s1")
    assert c.post("/orders/o1/ops", json=[op]).json()["refused"] == []
    bill = check(c)
    assert (bill["charge_total"], bill["tax"], bill["total"]) == ("3.00", "0.00", "13.00")
    assert bill["charges"][0]["taxed"] is False and bill["tax_exempt"]["tax"] == "0.91"


def test_no_fee_on_purpose_and_the_answer_taken_back():
    c = client()
    priced(c)
    brought(c)
    pick(c, {"up_to": "8"}, 50)
    assert check(c)["total"] == "19.21"
    assert pick(c, {"up_to": None}, 51)["refused"] == []
    assert carried(c) == {"up_to": None, "amount": "0.00"}
    assert check(c)["charges"] == [] and check(c)["total"] == "10.71"
    assert fee_of({"delivery_fee": carried(c)}) == {"by": None, "up_to": None, "amount": "0.00", "taxed": False}
    assert pick(c, None, 52)["refused"] == []
    assert carried(c) is None and check(c)["total"] == "10.71"


def test_a_band_the_location_does_not_list_is_refused_and_the_rest_of_what_was_said_is_kept():
    c = client()
    priced(c)
    brought(c)
    pick(c, {"up_to": "2"}, 50)
    unlisted = ({"up_to": "3"}, {"up_to": "far"}, {"up_to": 0}, "2", ["2"], {"up_to": {"miles": 2}})
    for when, wanted in enumerate(unlisted, start=60):
        answer = pick(c, wanted, when, note="Gate code 4411")
        assert [r["error"] for r in answer["refused"]] == ["invalid_delivery_fee"], wanted
    assert "no delivery fee is listed for up to 3 miles" in pick(c, {"up_to": "3"}, 70)["refused"][0]["message"]
    # the fee stands as it was picked, and the note that came with the refused one was kept
    assert carried(c)["up_to"] == "2" and check(c)["total"] == "13.71"
    assert c.get("/orders/o1").json()["fields"]["note"] == "Gate code 4411"
    # an operation that said nothing else is not stored at all
    before = c.get("/orders/o1").json()
    assert pick(c, {"up_to": "3"}, 71)["accepted"] == []
    assert c.get("/orders/o1").json() == before


def test_no_screen_makes_up_an_amount():
    c = client()
    priced(c)
    brought(c)
    cheap = {"up_to": "8", "amount": "0.01", "by": "minutes", "taxed": True}
    assert pick(c, cheap)["refused"] == []
    assert carried(c) == {"by": "miles", "up_to": "8", "amount": "8.50", "taxed": False}
    assert check(c)["total"] == "19.21"


def test_an_order_taken_with_its_fee_already_picked():
    c = client()
    priced(c)
    brought(c, delivery_fee={"up_to": "2"})
    assert carried(c) == {"by": "miles", "up_to": "2", "amount": "3.00", "taxed": False}
    assert check(c)["total"] == "13.71"
    # one whose band is not listed is taken all the same, with no fee, and the screen is told
    ops = [
        payload("o2-a", "create", 10, "o2", order_type="takeout", handover="delivery", delivery_fee={"up_to": 99}),
        payload("o2-b", "add_line", 11, "o2", line_id="L1", item="Tea", qty=1, priced=TEA),
    ]
    answer = c.post("/orders/o2/ops", json=ops).json()
    assert [r["op_id"] for r in answer["refused"]] == ["o2-a"] and len(answer["accepted"]) == 2
    assert carried(c, "o2") is None and check(c, "o2")["total"] == "10.71"


def test_an_order_keeps_the_fee_it_was_given_when_the_prices_change():
    c = client()
    priced(c)
    brought(c)
    pick(c, {"up_to": "4.5"})
    priced(c, {"enabled": True, "by": "minutes", "bands": [{"up_to": 15, "fee": 9}], "taxed": True})
    assert carried(c) == {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False}
    assert check(c)["total"] == "15.71"
    # the next delivery goes by the new prices
    brought(c, "o2", 100)
    assert pick(c, {"up_to": "4.5"}, 150, "o2")["refused"][0]["error"] == "invalid_delivery_fee"
    assert pick(c, {"up_to": 15}, 151, "o2")["refused"] == []
    assert carried(c, "o2") == {"by": "minutes", "up_to": "15", "amount": "9.00", "taxed": True}
    # and with the fee turned off, the one already charged stays on its check
    priced(c, {"enabled": False})
    assert check(c)["total"] == "15.71"


def test_only_a_delivery_is_charged():
    c = client()
    priced(c)
    brought(c)
    pick(c, {"up_to": "2"})
    assert check(c)["total"] == "13.71"
    # the customer comes for it after all: what was picked stays on the order and nothing is charged
    change = payload("p", "set_field", 60, handover="pickup")
    assert c.post("/orders/o1/ops", json=[change]).json()["refused"] == []
    assert carried(c)["amount"] == "3.00" and check(c)["charges"] == [] and check(c)["total"] == "10.71"
    back = payload("d", "set_field", 61, handover="delivery")
    c.post("/orders/o1/ops", json=[back])
    assert check(c)["total"] == "13.71"
    # a table's check never is, whatever it carries
    table = {"order_type": "dine_in", "table": "12", "handover": "delivery", "delivery_fee": carried(c)}
    assert fee_charged(table) is None and fee_charged({**table, "order_type": "takeout"})["amount"] == "3.00"


def test_what_an_order_carries_is_read_with_care():
    good = {"by": "minutes", "up_to": 15, "amount": "9", "taxed": True}
    assert fee_of({"delivery_fee": good}) == {"by": "minutes", "up_to": "15", "amount": "9.00", "taxed": True}
    for unreadable in (
        None,
        "3.00",
        {},
        {"amount": "three"},
        {"amount": "-1.00", "by": "miles", "up_to": "2"},
        {"amount": "3.00"},  # an amount with no band: nobody listed that
        {"amount": "3.00", "by": "feet", "up_to": "2"},
        {"amount": "3.00", "by": "miles", "up_to": "2.255"},
        {"amount": "3.00", "by": "minutes", "up_to": "2.5"},
    ):
        assert fee_of({"delivery_fee": unreadable}) is None, unreadable
        assert fee_charged({"order_type": "takeout", "handover": "delivery", "delivery_fee": unreadable}) is None
    assert band_of(MILES, "4.50") == {"up_to": "4.5", "fee": "5.00"}
    assert band_of(MILES, "4") is None and band_of({**MILES, "enabled": False}, "2") is None
    # the prices are read only when an operation picks a band
    ops = [make_op("set_field", at=1, note="Side door"), make_op("set_field", at=2, delivery_fee={"up_to": None})]
    kept, refused = fee_ops(lambda: pytest.fail("nobody picked a band"), ops)
    assert refused == [] and kept[1].data == {"delivery_fee": {"up_to": None, "amount": "0.00"}}


# On the papers and in the figures ---------------------------------------------------------------------------------


def test_the_bill_lists_the_fee_by_name():
    fee = {"by": "miles", "up_to": "4.5", "amount": "5.00", "taxed": False}
    state = replay(
        [
            make_op("create", at=0, order_type="takeout", handover="delivery", address=ELM, order_no=7),
            make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
            make_op("set_field", at=2, delivery_fee=fee),
        ],
        "o1",
    )
    lines = paper(bill_for(check_for(state, massachusetts()), state.fields, at=AT))
    at = lines.index(next(line for line in lines if line.startswith("Subtotal")))
    assert lines[at + 1].startswith("Delivery fee") and lines[at + 1].endswith(" 5.00")  # under the subtotal
    assert any(line.startswith("TOTAL") and line.endswith("$15.71") for line in lines)


def test_a_delivery_paid_on_two_checks_shares_the_fee_and_its_tax_is_the_dishes_alone():
    def two_checks(**fields):
        ops = [
            make_op("create", at=0, order_type="takeout", handover="delivery", address=ELM, **fields),
            make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, seat=1, priced=TEA),
            make_op("add_line", at=2, line_id="L2", item="Tea", qty=1, seat=2, priced=TEA),
            make_op("set_field", at=3, split={"by": "seat"}),
        ]
        return check_for(replay(ops, "o1"), massachusetts())

    bare = two_checks()
    whole = two_checks(delivery_fee={"by": "miles", "up_to": "2", "amount": "3.00", "taxed": False})
    assert (whole["charge_total"], whole["tax"], whole["total"]) == ("3.00", "1.40", "24.40")
    assert [part["charge_total"] for part in whole["checks"]] == ["1.50", "1.50"]
    assert [part["charges"] for part in whole["checks"]] == [
        [{"charge_id": CHARGE_ID, "name": "Delivery fee", "amount": "1.50"}]
    ] * 2
    # each check's tax is what it was without the fee, and the checks add up to the order
    assert [part["tax"] for part in whole["checks"]] == [part["tax"] for part in bare["checks"]]
    assert sum(Decimal(part["total"]) for part in whole["checks"]) == Decimal(whole["total"])
    # taxed, the fee's tax is shared with it
    taxed = two_checks(delivery_fee={"by": "miles", "up_to": "2", "amount": "3.00", "taxed": True})
    assert (taxed["tax"], taxed["total"]) == ("1.61", "24.61")  # 1.44 and 0.17 on 23.00
    assert sum(Decimal(part["tax"]) for part in taxed["checks"]) == Decimal("1.61")
    assert sum(Decimal(part["total"]) for part in taxed["checks"]) == Decimal(taxed["total"])


def test_the_fee_is_in_the_days_sales_with_the_other_charges():
    h = Hub(now=at(17))
    saved = h.c.put("/settings/delivery_fee", json=MILES, headers=h.manager())
    assert saved.status_code == 200
    h.to_go("o1", at(17), handover="delivery", address=ELM)
    h.ring("o1", "L1", EGGROLL, at(17, 1))  # 3.50
    h.op("o1", "fire", at(17, 2))
    h.op("o1", "set_field", at(17, 3), delivery_fee={"up_to": "4.5"}, by="Amy", by_id="s1")
    bill = h.check("o1")
    assert (bill["subtotal"], bill["charge_total"], bill["tax"], bill["total"]) == ("3.50", "5.00", "0.25", "8.75")
    h.pay("o1", at(17, 30), bill["total"])
    h.op("o1", "close", at(17, 31))
    h.now = at(21)
    sales = h.report()["sales"]
    assert (sales["gross"], sales["charges"], sales["gratuity"], sales["tax"], sales["total"]) == (
        "3.50",
        "5.00",
        "0.00",
        "0.25",
        "8.75",
    )


def test_the_history_says_who_picked_the_fee_and_what_it_was_before():
    h = Hub(now=at(17))
    h.c.put("/settings/delivery_fee", json=MILES, headers=h.manager())
    h.to_go("o1", at(17), handover="delivery", address=ELM, delivery_fee={"up_to": "2"}, by="Amy", by_id="s1")
    h.op("o1", "set_field", at(17, 5), delivery_fee={"up_to": "8"}, by="Ben", by_id="s2")
    h.op("o1", "set_field", at(17, 6), delivery_fee={"up_to": "8"}, by="Ben", by_id="s2")  # the same: no step
    h.op("o1", "set_field", at(17, 7), delivery_fee={"up_to": None}, by="Mike", by_id="s3")
    h.op("o1", "set_field", at(17, 8), delivery_fee=None, by="Mike", by_id="s3")
    told = [(s["by"], s["was"], s["now"]) for s in steps(h) if s["what"] == "delivery_fee"]
    two = {"by": "miles", "up_to": "2", "amount": "3.00", "taxed": False}
    eight = {"by": "miles", "up_to": "8", "amount": "8.50", "taxed": False}
    none = {"by": None, "up_to": None, "amount": "0.00", "taxed": False}
    assert told == [("Amy", None, two), ("Ben", two, eight), ("Mike", eight, none), ("Mike", none, None)]
    assert [s["what"] for s in steps(h)][:2] == ["opened", "delivery_fee"]
