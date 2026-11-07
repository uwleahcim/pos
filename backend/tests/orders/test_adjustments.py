"""Discounts, comps and service charges (architecture section 9): rules as data, a manager's PIN on the
spot, the check's order of operations, and the report of who took what off and why."""

from __future__ import annotations

import json
from dataclasses import replace

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.tokens import Tokens
from pos.menu.service import MenuService, load_definitions
from pos.orders.adjustments import APPROVAL_TTL, PricingRules, default_rules, load_rules
from pos.orders.check import check_for
from pos.printing.service import PrintService
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore, replay
from pos.tax import massachusetts

from ..conftest import T0, make_op

TEA = {"unit_price": "10.00", "tax_class": "prepared_food", "name": "Tea"}
DUCK = {"unit_price": "20.00", "tax_class": "prepared_food", "name": "Duck"}


def payload(op_id: str, op_kind: str, at: int, order_id: str = "o1", **data):
    return {
        "op_id": op_id,
        "order_id": order_id,
        "hlc": str(HLC(T0 + at, 0, "t1")),
        "device": "t1",
        "kind": op_kind,
        "data": data,
    }


def client(*, pricing: PricingRules | None = None, tokens: Tokens | None = None) -> TestClient:
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            menu=MenuService(load_definitions("restaurant")),
            taxes=massachusetts(),
            printing=PrintService([]),
            pricing=pricing,
            tokens=tokens,
        )
    )


def tea_and_duck(c: TestClient, order_id: str = "o1", **fields) -> None:
    fields = {"table": "12", "guests": 2, "order_type": "dine_in", **fields}
    ops = [
        payload(f"{order_id}-a", "create", 0, order_id, **fields),
        payload(f"{order_id}-b", "add_line", 1, order_id, line_id="L1", item="Tea", qty=1, priced=TEA),
        payload(f"{order_id}-c", "add_line", 2, order_id, line_id="L2", item="Duck", qty=1, priced=DUCK),
    ]
    assert c.post(f"/orders/{order_id}/ops", json=ops).json()["refused"] == []


def approval(c: TestClient, order_id: str = "o1", pin: str = "9999") -> str:
    return c.post("/approvals", json={"device": "t1", "pin": pin, "order_id": order_id}).json()["approval"]


# --- the rules ------------------------------------------------------------------------------------------


def test_the_rules_say_who_may_take_what_off():
    rules = default_rules()
    problems = lambda data, approved=False, existing=(): [  # noqa: E731
        p["code"] for p in rules.problems("discount", data, approved=approved, existing=existing)
    ]
    assert problems({"reason": "birthday", "kind": "percent", "value": "10"}) == ["unknown_reason"]
    assert problems({"reason": "comp", "kind": "percent", "value": "10"}, approved=True) == ["bad_kind"]
    assert problems({"reason": "comp", "kind": "comp"}) == ["needs_approval"]
    assert problems({"reason": "comp", "kind": "comp"}, approved=True) == []
    assert problems({"reason": "loyalty", "kind": "percent", "value": "25"}) == ["over_cap"]
    assert problems({"reason": "loyalty", "kind": "amount", "value": "0"}) == ["bad_value"]
    assert problems({"reason": "loyalty", "kind": "amount", "value": "abc"}) == ["bad_value"]
    assert problems({"reason": "loyalty", "kind": "percent", "value": "10"}) == []  # any server may
    assert problems({"reason": "staff_meal", "kind": "percent", "value": "40"}, approved=True) == ["bad_value"]
    assert problems({"reason": "staff_meal", "kind": "percent", "value": "50"}, approved=True) == []
    # Stacking: a second discount on the same dish, or over the whole check, is refused; another dish is fine.
    on_l1 = [{"reason": "comp", "line_id": "L1"}]
    assert problems({"reason": "loyalty", "kind": "percent", "value": "10", "line_id": "L1"}, existing=on_l1) == [
        "no_stacking"
    ]
    assert problems({"reason": "loyalty", "kind": "percent", "value": "10", "line_id": "L2"}, existing=on_l1) == []
    assert problems({"reason": "loyalty", "kind": "percent", "value": "10"}, existing=on_l1) == ["no_stacking"]
    whole = [{"reason": "promotion", "line_id": None}]
    assert problems({"reason": "loyalty", "kind": "percent", "value": "10", "line_id": "L2"}, existing=whole) == [
        "no_stacking"
    ]
    # Charges: only a rule's code goes on; the automatic gratuity comes off with a manager, the delivery fee freely.
    assert [p["code"] for p in rules.problems("charge", {"code": "valet"}, approved=False)] == ["unknown_charge"]
    assert [p["code"] for p in rules.problems("remove_charge", {"charge_id": "auto_gratuity"}, approved=False)] == [
        "needs_approval"
    ]
    assert rules.problems("remove_charge", {"charge_id": "auto_gratuity"}, approved=True) == []
    assert rules.problems("remove_charge", {"charge_id": "delivery_fee"}, approved=False) == []


def test_rules_are_data_from_a_file(tmp_path, monkeypatch):
    path = tmp_path / "pricing.json"
    path.write_text(
        json.dumps(
            {
                "discounts": [{"code": "happy_hour", "name": "Happy hour", "max_percent": "30", "approval": "none"}],
                "charges": [{"code": "room", "name": "Room fee", "kind": "amount", "value": "150"}],
            }
        )
    )
    monkeypatch.setenv("POS_PRICING", str(path))
    rules = load_rules()
    assert list(rules.discounts) == ["happy_hour"] and list(rules.charges) == ["room"]
    assert PricingRules.from_json(rules.as_json()).as_json() == rules.as_json()
    assert rules.charges["room"].applies("dine_in", 10) is False  # not automatic: staff put it on


# --- the check ------------------------------------------------------------------------------------------


def adj(op_kind: str, at: int, **data):
    """A discount or charge operation; its data carries a `kind` of its own, so make_op cannot take it."""
    return replace(make_op(op_kind, at=at), data=data)


def state_with(*ops):
    return replay(list(ops), "o1")


def test_line_discounts_then_check_discounts_then_charges_then_tax():
    ops = [
        make_op("create", at=0, table="5", guests=6, order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Tea", qty=1, priced=TEA),
        make_op("add_line", at=3, line_id="L3", item="Tea", qty=1, priced=TEA),
        adj("discount", 4, discount_id="D1", reason="loyalty", kind="percent", value="10", line_id="L1"),
        adj("discount", 5, discount_id="D2", reason="promotion", kind="amount", value="0.10"),
    ]
    check = check_for(state_with(*ops), massachusetts(), default_rules())
    assert check["subtotal"] == "30.00"
    # 10% off L1 is 1.00; the 0.10 off the check is spread over 9.00, 10.00 and 10.00 with the odd cent on
    # the largest line (the last of equals), so each line's tax base is right.
    assert [line["discount"] for line in check["lines"]] == ["1.00", "0.00", "0.00"]
    assert [(d["discount_id"], d["amount"], d["name"]) for d in check["discounts"]] == [
        ("D1", "1.00", "Loyalty reward"),
        ("D2", "0.10", "Promotion"),
    ]
    assert check["discount_total"] == "1.10"
    # The party of six carries the automatic gratuity on the discounted 28.90; it is not taxed.
    assert [(c["charge_id"], c["amount"], c["gratuity"], c["automatic"], c["taxed"]) for c in check["charges"]] == [
        ("auto_gratuity", "5.20", True, True, False)
    ]
    assert check["charge_total"] == "5.20"
    assert [(t["component"], t["base"], t["amount"]) for t in check["tax_lines"]] == [
        ("ma_meals", "28.90", "1.81"),
        ("ma_local_meals", "28.90", "0.22"),
    ]
    assert check["total"] == "36.13"  # 28.90 + 5.20 + 2.03


def test_a_comp_takes_the_whole_line_and_its_tax_and_a_removal_puts_it_back():
    ops = [
        make_op("create", at=0, table="5", guests=2, order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=2, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
        adj("discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L1", applied_by="Amy"),
    ]
    check = check_for(state_with(*ops), massachusetts(), default_rules())
    assert check["lines"][0]["discount"] == "20.00" and check["discount_total"] == "20.00"
    assert check["tax_lines"][0]["base"] == "20.00" and check["total"] == "21.40"
    assert check["charges"] == [] and check["charge_total"] == "0.00"

    check = check_for(state_with(*ops, adj("remove_discount", 4, discount_id="D1")), massachusetts())
    assert check["discounts"] == [] and check["total"] == "42.80"
    # A removal that reaches a replica before the discount itself still wins.
    early = adj("remove_discount", 2, discount_id="D1")
    state = state_with(*ops[:3], early, ops[3])
    assert state.discounts["D1"].active is False and state.snapshot()["discounts"]["D1"]["reason"] == ""


def test_an_amount_never_exceeds_the_line_and_a_taxed_charge_is_taxed():
    rules = PricingRules.from_json(
        {
            "discounts": [{"code": "promotion", "name": "Promotion", "approval": "none"}],
            "charges": [
                {
                    "code": "delivery_fee",
                    "name": "Delivery",
                    "kind": "amount",
                    "value": "4.00",
                    "order_types": ["delivery"],
                    "automatic": True,
                },
            ],
        }
    )
    ops = [
        make_op("create", at=0, order_type="delivery"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        adj("discount", 2, discount_id="D1", reason="promotion", kind="amount", value="50", line_id="L1"),
    ]
    check = check_for(state_with(*ops), massachusetts(), rules)
    assert check["discount_total"] == "10.00" and check["lines"][0]["discount"] == "10.00"
    assert [(c["charge_id"], c["amount"], c["taxed"]) for c in check["charges"]] == [("delivery_fee", "4.00", True)]
    assert [(t["component"], t["base"]) for t in check["tax_lines"]] == [
        ("ma_meals", "4.00"),
        ("ma_local_meals", "4.00"),
    ]
    assert check["total"] == "4.28"


# --- the API: approvals, refusals, the report ----------------------------------------------------------


def test_a_comp_needs_a_manager_on_the_spot_who_is_named_on_the_check():
    c = client()
    tea_and_duck(c)
    comp = dict(discount_id="D1", reason="comp", kind="comp", line_id="L1", applied_by="Amy")
    r = c.post("/orders/o1/ops", json=[payload("d", "discount", 3, **comp)]).json()
    assert r["accepted"] == [] and r["refused"][0]["problems"][0]["code"] == "needs_approval"

    assert c.post("/approvals", json={"device": "t1", "pin": "1111", "order_id": "o1"}).status_code == 403
    assert c.post("/approvals", json={"device": "t1", "pin": "0000", "order_id": "o1"}).status_code == 401
    granted = c.post("/approvals", json={"device": "t1", "pin": "9999", "order_id": "o1"}).json()
    assert (granted["name"], granted["role"]) == ("Mike", "manager")

    # An approval is for one order; and a terminal cannot name the approver itself.
    elsewhere = approval(c, "o2")
    r = c.post("/orders/o1/ops", json=[payload("e", "discount", 4, **comp, approval=elsewhere)]).json()
    assert r["refused"][0]["problems"][0]["code"] == "needs_approval"
    forged = {**comp, "approved_by": {"staff_id": "s3", "name": "Mike"}}
    r = c.post("/orders/o1/ops", json=[payload("f", "discount", 5, **forged)]).json()
    assert r["refused"][0]["problems"][0]["code"] == "needs_approval"

    r = c.post("/orders/o1/ops", json=[payload("g", "discount", 6, **forged, approval=granted["approval"])]).json()
    assert r["accepted"] == ["g"] and r["refused"] == []
    stored = next(op for op in c.get("/ops").json()["ops"] if op["op_id"] == "g")["data"]
    assert "approval" not in stored and stored["approved_by"] == {"staff_id": "s3", "name": "Mike"}
    check = c.get("/orders/o1/check").json()
    assert check["lines"][0]["discount"] == "10.00" and check["discount_total"] == "10.00"
    assert check["discounts"][0]["approved_by"]["name"] == "Mike" and check["discounts"][0]["applied_by"] == "Amy"
    assert (check["subtotal"], check["tax"], check["total"]) == ("30.00", "1.40", "21.40")

    # The same approval does not stretch to a second discount that does not stack on the first.
    r = c.post(
        "/orders/o1/ops",
        json=[
            payload(
                "h",
                "discount",
                7,
                discount_id="D2",
                reason="comp",
                kind="comp",
                line_id="L1",
                approval=granted["approval"],
            )
        ],
    ).json()
    assert r["refused"][0]["problems"][0]["code"] == "no_stacking"
    # Taking it off needs nobody; the check goes back up.
    assert c.post("/orders/o1/ops", json=[payload("i", "remove_discount", 8, discount_id="D1")]).json()["accepted"] == [
        "i"
    ]
    assert c.get("/orders/o1/check").json()["total"] == "32.11"


def test_an_approval_expires():
    clock = [T0 / 1000]
    c = client(tokens=Tokens("test", clock=lambda: clock[0]))
    tea_and_duck(c)
    token = approval(c)
    clock[0] += APPROVAL_TTL + 1
    r = c.post(
        "/orders/o1/ops",
        json=[payload("d", "discount", 3, discount_id="D1", reason="comp", kind="comp", approval=token)],
    ).json()
    assert r["refused"][0]["problems"][0]["code"] == "needs_approval"


def test_a_loyalty_reward_needs_no_manager_and_a_bad_one_does_not_stop_the_rest():
    c = client()
    tea_and_duck(c)
    ops = [
        payload("d", "discount", 3, discount_id="D1", reason="loyalty", kind="percent", value="10", applied_by="Amy"),
        payload("e", "discount", 4, discount_id="D2", reason="loyalty", kind="percent", value="90"),
        payload("f", "discount", 5, reason="loyalty", kind="percent", value="5"),
        payload("g", "set_field", 6, note="window seat"),
    ]
    r = c.post("/orders/o1/ops", json=ops).json()
    assert r["accepted"] == ["d", "g"]
    assert [(x["op_id"], x["problems"][0]["code"]) for x in r["refused"]] == [("e", "over_cap"), ("f", "bad_request")]
    check = c.get("/orders/o1/check").json()
    assert check["discount_total"] == "3.00" and check["discounts"][0]["approved_by"] is None
    assert [line["discount"] for line in check["lines"]] == ["0.00", "0.00"]  # a check discount is its own row


def test_the_automatic_gratuity_comes_off_only_with_a_manager():
    c = client()
    tea_and_duck(c, guests=6)
    check = c.get("/orders/o1/check").json()
    assert [(x["charge_id"], x["amount"]) for x in check["charges"]] == [("auto_gratuity", "5.40")]
    assert check["total"] == "37.51"  # 30.00 + 5.40 + 2.11
    r = c.post("/orders/o1/ops", json=[payload("d", "remove_charge", 3, charge_id="auto_gratuity")]).json()
    assert r["refused"][0]["problems"][0]["code"] == "needs_approval"
    ops = [payload("e", "remove_charge", 4, charge_id="auto_gratuity", approval=approval(c))]
    assert c.post("/orders/o1/ops", json=ops).json()["accepted"] == ["e"]
    check = c.get("/orders/o1/check").json()
    assert check["charges"] == [] and check["total"] == "32.11"
    assert c.get("/orders/o1").json()["charges"]["auto_gratuity"]["approved_by"]["name"] == "Mike"
    assert c.get("/floor").json()["status"]["12"][0]["total"] == "32.11"


def test_staff_put_on_a_charge_from_the_rules_and_the_hub_fills_it_in():
    rules = default_rules()
    rules.charges["catering"] = rules.charges["auto_gratuity"].__class__.from_json(
        {
            "code": "catering",
            "name": "Catering service",
            "kind": "percent",
            "value": "18",
            "tax_class": "service_charge",
        }
    )
    c = client(pricing=rules)
    assert [x["code"] for x in c.get("/pricing/rules").json()["charges"]] == [
        "auto_gratuity",
        "delivery_fee",
        "catering",
    ]
    tea_and_duck(c)
    ops = [
        payload("d", "charge", 3, charge_id="C1", code="valet"),
        payload("e", "charge", 4, charge_id="C2", code="catering", name="forged", value="99", applied_by="Amy"),
    ]
    r = c.post("/orders/o1/ops", json=ops).json()
    assert r["accepted"] == ["e"] and r["refused"][0]["problems"][0]["code"] == "unknown_charge"
    check = c.get("/orders/o1/check").json()
    assert [(x["charge_id"], x["name"], x["amount"], x["automatic"], x["applied_by"]) for x in check["charges"]] == [
        ("C2", "Catering service", "5.40", False, "Amy")
    ]
    assert check["tax_lines"][0]["base"] == "35.40" and check["total"] == "37.88"  # a taxed service charge
    assert c.post("/orders/o1/ops", json=[payload("f", "remove_charge", 5, charge_id="C2")]).json()["accepted"] == ["f"]
    assert c.get("/orders/o1/check").json()["charges"] == []


def test_the_report_says_who_took_what_off_and_why():
    c = client()
    tea_and_duck(c, "o1")
    tea_and_duck(c, "o2", guests=6)
    comp = payload(
        "d", "discount", 3, "o1", discount_id="D1", reason="comp", kind="comp", line_id="L2", applied_by="Amy"
    )
    comp["data"]["approval"] = approval(c, "o1")
    loyalty = payload(
        "e", "discount", 4, "o2", discount_id="D2", reason="loyalty", kind="amount", value="5", applied_by="Ben"
    )
    c.post("/orders/o1/ops", json=[comp])
    c.post(
        "/orders/o2/ops",
        json=[loyalty, payload("f", "discount", 5, "o2", discount_id="D3", reason="loyalty", kind="amount", value="1")],
    )
    c.post("/orders/o2/ops", json=[payload("g", "remove_discount", 6, "o2", discount_id="D2")])
    c.post(
        "/orders/o2/ops",
        json=[
            payload(
                "h", "discount", 7, "o2", discount_id="D4", reason="loyalty", kind="amount", value="2", applied_by="Ben"
            )
        ],
    )

    report = c.get("/reports/adjustments").json()
    assert [(d["order_id"], d["discount_id"], d["amount"]) for d in report["discounts"]] == [
        ("o1", "D1", "20.00"),
        ("o2", "D4", "2.00"),
    ]
    assert report["discount_total"] == "22.00" and report["removed"] == 1
    assert report["by_reason"] == [{"key": "comp", "amount": "20.00"}, {"key": "loyalty", "amount": "2.00"}]
    assert report["by_staff"] == [{"key": "Amy", "amount": "20.00"}, {"key": "Ben", "amount": "2.00"}]
    assert report["by_approver"] == [{"key": "Mike", "amount": "20.00"}, {"key": "", "amount": "2.00"}]
    assert [(x["order_id"], x["charge_id"]) for x in report["charges"]] == [("o2", "auto_gratuity")]
    assert report["charge_total"] == "5.04"  # 18% of 28.00
    assert c.get("/reports/adjustments", params={"since": T0 + 8}).json()["discounts"] == []


# --- a comp follows an edited line; the check lists each choice with what it adds -----------------------


def test_a_comp_follows_the_line_that_replaces_its_line():
    """Changing a dish's options or note voids its line and adds the changed one in its place (`replaces`);
    the comp on the old line goes on the new one (Mike, 2026-11-03), through any number of changes, and
    comes off with the same removal."""
    milk = {**TEA, "unit_price": "11.00"}
    ops = [
        make_op("create", at=0, table="5", guests=2, order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=2, priced=TEA),
        adj("discount", 2, discount_id="D1", reason="comp", kind="comp", line_id="L1", applied_by="Amy"),
        make_op("void_line", at=3, line_id="L1", reason="changed"),
        make_op("add_line", at=4, line_id="L2", item="Tea", qty=2, priced=milk, replaces="L1"),
    ]
    state = state_with(*ops)
    assert (state.current_line("L1"), state.current_line("L2"), state.current_line("L9")) == ("L2", "L2", "L9")
    assert state.snapshot()["lines"]["L2"]["replaces"] == "L1"
    check = check_for(state, massachusetts(), default_rules())
    assert [(line["line_id"], line["total"], line["discount"]) for line in check["lines"]] == [("L2", "22.00", "22.00")]
    assert (check["discounts"][0]["line_id"], check["discount_total"], check["total"]) == ("L2", "22.00", "0.00")

    ops += [
        make_op("void_line", at=5, line_id="L2", reason="changed"),
        make_op("add_line", at=6, line_id="L3", item="Tea", qty=1, priced=TEA, replaces="L2"),
    ]
    check = check_for(state_with(*ops), massachusetts(), default_rules())
    assert (check["lines"][0]["discount"], check["total"]) == ("10.00", "0.00")
    check = check_for(state_with(*ops, adj("remove_discount", 7, discount_id="D1")), massachusetts(), default_rules())
    assert check["discounts"] == [] and check["total"] == "10.71"  # 10.00 + 0.63 + 0.08


def test_a_comp_comes_off_with_the_dish_it_was_on():
    """A comp on a dish that comes off the check, removed before the kitchen saw it or voided after, comes
    off with it (Mike, 2026-11-03): no row under the subtotal, nothing off the total. The log keeps the
    comp as it was approved."""
    ops = [
        make_op("create", at=0, table="5", guests=2, order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
        adj("discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L1", applied_by="Amy"),
    ]
    check = check_for(state_with(*ops), massachusetts(), default_rules())
    assert (check["discount_total"], check["total"]) == ("10.00", "21.40")  # 20.00 + 1.25 + 0.15

    removed = state_with(*ops, make_op("void_line", at=4, line_id="L1", reason="changed mind"))
    assert removed.lines["L1"].status == "removed" and removed.discounts["D1"].active
    check = check_for(removed, massachusetts(), default_rules())
    assert (check["discounts"], check["discount_total"], check["total"]) == ([], "0.00", "21.40")

    sent = make_op("fire", at=4, course="*")
    voided = state_with(*ops, sent, make_op("void_line", at=5, line_id="L1", reason="void"))
    assert voided.lines["L1"].status == "void"
    check = check_for(voided, massachusetts(), default_rules())
    assert (check["discounts"], check["total"]) == ([], "21.40")


def test_a_comp_on_a_removed_dish_does_not_block_a_discount_on_the_check():
    """Even in one batch, as a terminal back from an outage sends them: the void of the comped dish counts
    for the discount after it."""
    c = client()
    tea_and_duck(c)
    ops = [
        payload("d", "discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L1", approval=approval(c)),
        payload("e", "void_line", 4, line_id="L1", reason="changed mind"),
        # on the whole check: it could not go over the comp while the tea was on the check
        payload("f", "discount", 5, discount_id="D2", reason="loyalty", kind="percent", value="10"),
    ]
    assert c.post("/orders/o1/ops", json=ops).json()["refused"] == []
    check = c.get("/orders/o1/check").json()
    assert [d["discount_id"] for d in check["discounts"]] == ["D2"]
    assert ([line["line_id"] for line in check["lines"]], check["discount_total"]) == (["L2"], "2.00")


def test_a_discount_on_the_replacing_line_does_not_stack_on_the_comp_that_followed():
    c = client()
    tea_and_duck(c)
    ops = [
        payload("d", "discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L1", approval=approval(c)),
        payload("e", "void_line", 4, line_id="L1", reason="changed"),
        payload("f", "add_line", 5, line_id="L3", item="Tea", qty=1, priced=TEA, replaces="L1"),
    ]
    assert c.post("/orders/o1/ops", json=ops).json()["refused"] == []
    check = c.get("/orders/o1/check").json()
    assert [(line["line_id"], line["discount"]) for line in check["lines"]] == [("L2", "0.00"), ("L3", "10.00")]
    assert c.get("/orders/o1").json()["lines"]["L3"]["replaces"] == "L1"
    second = payload("g", "discount", 6, discount_id="D2", reason="loyalty", kind="percent", value="10", line_id="L3")
    r = c.post("/orders/o1/ops", json=[second]).json()
    assert r["refused"][0]["problems"][0]["code"] == "no_stacking"


def test_the_check_lists_each_choice_with_what_it_adds_for_the_quantity():
    priced = {
        **TEA,
        "unit_price": "11.75",
        "modifiers": [
            {"label": "Oat milk", "price": "0.75", "defaulted": False},
            {"label": "Hot", "price": "0", "defaulted": True},
            {"label": "Large", "price": "1.00", "defaulted": False},
        ],
    }
    ops = [make_op("create", at=0), make_op("add_line", at=1, line_id="L1", item="Tea", qty=2, priced=priced)]
    line = check_for(state_with(*ops), massachusetts())["lines"][0]
    assert line["total"] == "23.50"
    assert line["modifiers"] == [
        {"label": "Oat milk", "price": "0.75", "amount": "1.50", "depth": 0},
        {"label": "Large", "price": "1.00", "amount": "2.00", "depth": 0},
    ]
