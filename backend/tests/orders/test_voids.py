"""Voids of dishes the kitchen already has: a reason from the location's list, a manager's PIN on the spot
unless the location lets servers void, and a report of who voided what and why. A dish the kitchen has not
seen still just comes off the check, with nothing asked."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pos.identity.tokens import Tokens
from pos.orders.adjustments import APPROVAL_TTL
from pos.orders.voids import void_rows
from pos.settings import DEFAULTS, SettingStore, clean_voids
from pos.sync.hlc import HLC
from pos.sync.oplog import Op, OpStore

from ..conftest import T0
from .test_adjustments import DUCK, TEA, client, payload


def table(c: TestClient, order_id: str = "o1", *, tea: int = 1) -> None:
    """A table with tea (L1) and a duck (L2), both sent to the kitchen."""
    ops = [
        payload(f"{order_id}-a", "create", 0, order_id, table="12", guests=2, order_type="dine_in"),
        payload(f"{order_id}-b", "add_line", 1, order_id, line_id="L1", item="Tea", qty=tea, priced=TEA, by="Amy"),
        payload(f"{order_id}-c", "add_line", 2, order_id, line_id="L2", item="Duck", qty=1, priced=DUCK, by="Amy"),
        payload(f"{order_id}-d", "fire", 3, order_id, course="*"),
    ]
    assert c.post(f"/orders/{order_id}/ops", json=ops).json()["refused"] == []


def approval(c: TestClient, order_id: str = "o1", pin: str = "9999", purpose: str = "void") -> str:
    body = {"device": "t1", "pin": pin, "order_id": order_id, "purpose": purpose}
    return c.post("/approvals", json=body).json()["approval"]


def manager(c: TestClient) -> dict[str, str]:
    token = c.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()["token"]
    return {"authorization": f"Bearer {token}"}


def send(c: TestClient, *ops: dict, order_id: str = "o1") -> dict:
    return c.post(f"/orders/{order_id}/ops", json=list(ops)).json()


def codes(answer: dict) -> list[list[str]]:
    return [[p["code"] for p in r["problems"]] for r in answer["refused"]]


def lines(c: TestClient, order_id: str = "o1") -> dict:
    return c.get(f"/orders/{order_id}").json()["lines"]


# --- the setting ----------------------------------------------------------------------------------------


def test_a_manager_approves_voids_by_default_and_the_usual_reasons_are_listed():
    voids = SettingStore().get("voids")
    assert voids["approval"] == "manager"
    assert [(r["id"], r["name"]) for r in voids["reasons"]] == [
        ("guest-changed-mind", "Guest changed mind"),
        ("rung-in-wrong", "Rung in wrong"),
        ("kitchen-error", "Kitchen error"),
        ("out-of-stock", "Out of stock"),
    ]
    assert clean_voids(DEFAULTS["voids"]) == DEFAULTS["voids"]


def test_a_new_reason_gets_its_id_from_its_name_and_never_one_an_edit_uses():
    cleaned = clean_voids(
        {
            "approval": "none",
            "reasons": [
                {"id": "kitchen-error", "name": " Kitchen mistake "},  # renamed: it keeps its id
                {"name": "Dropped on the floor"},
                {"name": "Changed"},  # `changed` is what the void half of an edit says
                {"name": "Void"},
            ],
        }
    )
    assert cleaned == {
        "approval": "none",
        "reasons": [
            {"id": "kitchen-error", "name": "Kitchen mistake"},
            {"id": "dropped-on-the-floor", "name": "Dropped on the floor"},
            {"id": "changed-2", "name": "Changed"},
            {"id": "void-2", "name": "Void"},
        ],
    }


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ({"approval": "manager", "reasons": []}, "at least one reason"),
        ({"approval": "anyone", "reasons": [{"name": "Oops"}]}, "manager or none"),
        ({"approval": "manager", "reasons": [{"name": "Oops"}, {"name": "oops"}]}, "listed twice"),
        ({"approval": "manager", "reasons": [{"name": " "}]}, "needs a name"),
        ({"approval": "manager", "reasons": [{"name": "x" * 41}]}, "at most 40"),
        ({"approval": "manager", "reasons": [{"id": "a b", "name": "Oops"}]}, "letters, digits"),
        ({"approval": "manager", "reasons": [{"id": "changed", "name": "Oops"}]}, "is taken"),
        ({"approval": "manager", "reasons": [{"id": "a", "name": "One"}, {"id": "a", "name": "Two"}]}, "listed twice"),
        ({"approval": "manager", "reasons": [{"name": f"Reason {n}"} for n in range(13)]}, "at most 12"),
        ({"approval": "manager", "reasons": "oops"}, "list of"),
    ],
)
def test_a_bad_void_setting_is_refused_with_the_reason(body, problem):
    with pytest.raises(ValueError, match=problem):
        clean_voids(body)


def test_only_a_manager_changes_the_void_rules():
    c = client()
    assert c.get("/settings/voids").json() == DEFAULTS["voids"]
    body = {"approval": "none", "reasons": [{"id": "kitchen-error", "name": "Kitchen error"}, {"name": "Spilled"}]}
    assert c.put("/settings/voids", json=body).status_code == 401
    saved = c.put("/settings/voids", json=body, headers=manager(c))
    assert saved.status_code == 200
    assert saved.json()["reasons"][1] == {"id": "spilled", "name": "Spilled"}
    assert c.get("/settings/voids").json() == saved.json()
    bad = c.put("/settings/voids", json={"approval": "manager", "reasons": []}, headers=manager(c))
    assert bad.status_code == 422 and "at least one reason" in bad.json()["detail"]["message"]


# --- the hub checks a void before it stores it ----------------------------------------------------------


def test_a_dish_the_kitchen_has_not_seen_still_just_comes_off():
    c = client()
    table(c)
    send(c, payload("e", "add_line", 4, line_id="L3", item="Tea", qty=1, priced=TEA))
    answer = send(c, payload("f", "void_line", 5, line_id="L3"))
    assert answer["accepted"] == ["f"] and answer["refused"] == []
    assert lines(c)["L3"]["status"] == "removed" and lines(c)["L3"]["voided"] is None


def test_a_void_of_a_sent_dish_needs_a_reason_from_the_list_and_a_manager():
    c = client()
    table(c)
    assert codes(send(c, payload("e", "void_line", 4, line_id="L2"))) == [["unknown_reason", "needs_approval"]]
    assert codes(send(c, payload("f", "void_line", 5, line_id="L2", reason="void"))) == [
        ["unknown_reason", "needs_approval"]
    ]
    assert codes(send(c, payload("g", "void_line", 6, line_id="L2", reason="kitchen-error"))) == [["needs_approval"]]
    assert lines(c)["L2"]["status"] == "active"

    # A server's PIN approves nothing; an approval is for voids on this order alone.
    wrong = {"device": "t1", "pin": "1111", "order_id": "o1", "purpose": "void"}
    assert c.post("/approvals", json=wrong).status_code == 403
    for token in (approval(c, "o2"), approval(c, "o1", purpose="adjust"), "forged"):
        answer = send(c, payload("h", "void_line", 7, line_id="L2", reason="kitchen-error", approval=token))
        assert codes(answer) == [["needs_approval"]]
    forged = {"approved_by": {"staff_id": "s3", "name": "Mike"}}
    assert codes(send(c, payload("i", "void_line", 8, line_id="L2", reason="kitchen-error", **forged))) == [
        ["needs_approval"]
    ]

    void = payload(
        "j", "void_line", 9, line_id="L2", reason="kitchen-error", by="Amy", by_id="s1", approval=approval(c)
    )
    answer = send(c, void)
    assert answer["accepted"] == ["j"] and answer["refused"] == []
    stored = next(op for op in c.get("/ops").json()["ops"] if op["op_id"] == "j")["data"]
    assert "approval" not in stored and stored["approved_by"] == {"staff_id": "s3", "name": "Mike"}
    assert stored["reason_name"] == "Kitchen error"
    line = lines(c)["L2"]
    assert line["status"] == "void" and line["void_reason"] == "kitchen-error"
    assert line["voided"] == {
        "reason": "kitchen-error",
        "reason_name": "Kitchen error",
        "by": "Amy",
        "by_id": "s1",
        "approved_by": {"staff_id": "s3", "name": "Mike"},
        "at_ms": T0 + 9,
    }
    assert c.get("/orders/o1/check").json()["subtotal"] == "10.00"


def test_an_approval_for_a_void_expires():
    now = [1000.0]
    c = client(tokens=Tokens("secret", clock=lambda: now[0]))
    table(c)
    token = approval(c)
    now[0] += APPROVAL_TTL + 1
    void = payload("e", "void_line", 4, line_id="L2", reason="kitchen-error", approval=token)
    assert codes(send(c, void)) == [["needs_approval"]]


def test_a_location_can_let_servers_void_with_a_reason_alone():
    c = client()
    table(c)
    body = {**DEFAULTS["voids"], "approval": "none"}
    assert c.put("/settings/voids", json=body, headers=manager(c)).status_code == 200
    assert codes(send(c, payload("e", "void_line", 4, line_id="L2"))) == [["unknown_reason"]]
    answer = send(c, payload("f", "void_line", 5, line_id="L2", reason="out-of-stock", by="Amy"))
    assert answer["accepted"] == ["f"]
    voided = lines(c)["L2"]["voided"]
    assert (voided["reason_name"], voided["by"], voided["approved_by"]) == ("Out of stock", "Amy", None)


def test_changing_a_sent_dish_is_not_a_void():
    """An edit voids the line and sends the changed dish in its place, in one batch: nothing is asked."""
    c = client()
    table(c)
    answer = send(
        c,
        payload("e", "void_line", 4, line_id="L2", reason="changed"),
        payload("f", "add_line", 5, line_id="L3", item="Duck", qty=1, priced=DUCK, replaces="L2"),
        payload("g", "fire", 6, course="*"),
    )
    assert answer["accepted"] == ["e", "f", "g"] and answer["refused"] == []
    assert lines(c)["L2"]["status"] == "void" and lines(c)["L3"]["status"] == "active"
    # ...but the word alone, with nothing sent in the dish's place, is a void like any other
    assert codes(send(c, payload("h", "void_line", 7, line_id="L3", reason="changed"))) == [
        ["unknown_reason", "needs_approval"]
    ]


def test_fewer_of_a_sent_dish_is_a_void_of_the_difference():
    c = client()
    table(c, tea=3)
    fewer = [
        payload("e", "void_line", 4, line_id="L1", reason="rung-in-wrong", by="Amy"),
        payload("f", "add_line", 5, line_id="L3", item="Tea", qty=1, priced=TEA, replaces="L1"),
        payload("g", "fire", 6, course="*"),
    ]
    # Refused, the three teas stay as they were: the one that would take their place is not added beside them.
    answer = send(c, *fewer)
    assert answer["accepted"] == ["g"]
    assert [r["op_id"] for r in answer["refused"]] == ["e", "f"]
    assert codes(answer) == [["needs_approval"], ["void_refused"]]
    assert lines(c)["L1"]["status"] == "active" and lines(c)["L1"]["qty"] == 3 and "L3" not in lines(c)

    fewer[0]["data"]["approval"] = approval(c)
    fewer = [{**op, "op_id": op["op_id"] + "2"} for op in fewer]
    assert send(c, *fewer)["refused"] == []
    assert lines(c)["L1"]["status"] == "void" and lines(c)["L3"]["qty"] == 1
    report = c.get("/reports/adjustments").json()
    assert [(v["line_id"], v["qty"], v["amount"]) for v in report["voids"]] == [("L1", 2, "20.00")]


def test_a_void_that_arrives_before_its_dish_is_kept():
    """A void always wins (the log's rule): one that reaches the hub before the line it names is stored."""
    c = client()
    send(c, payload("a", "create", 0, table="12"))
    answer = send(c, payload("b", "void_line", 2, line_id="L9", approval="whatever"))
    assert answer["accepted"] == ["b"]
    stored = next(op for op in c.get("/ops").json()["ops"] if op["op_id"] == "b")["data"]
    assert "approval" not in stored  # a token is never kept in the log


# --- the report -----------------------------------------------------------------------------------------


def test_the_report_says_who_voided_what_and_why():
    c = client()
    table(c, "o1", tea=2)
    table(c, "o2")
    send(
        c,
        payload("e", "void_line", 10, "o1", line_id="L2", reason="kitchen-error", by="Amy", approval=approval(c, "o1")),
    )
    send(
        c,
        payload("f", "void_line", 20, "o2", line_id="L1", reason="rung-in-wrong", by="Ben", approval=approval(c, "o2")),
        order_id="o2",
    )
    send(
        c,
        payload("g", "void_line", 30, "o1", line_id="L1", reason="kitchen-error", by="Amy", approval=approval(c, "o1")),
    )
    # an edit is not a void, and a dish taken off before the kitchen saw it is not one either
    send(
        c,
        payload("h", "void_line", 40, "o2", line_id="L2", reason="changed"),
        payload("i", "add_line", 41, "o2", line_id="L3", item="Duck", qty=1, priced=DUCK, replaces="L2"),
        payload("j", "add_line", 42, "o2", line_id="L4", item="Tea", qty=1, priced=TEA),
        payload("k", "void_line", 43, "o2", line_id="L4"),
        order_id="o2",
    )

    report = c.get("/reports/adjustments").json()
    assert [(v["order_id"], v["line_id"], v["item"], v["qty"], v["amount"]) for v in report["voids"]] == [
        ("o1", "L2", "Duck", 1, "20.00"),
        ("o2", "L1", "Tea", 1, "10.00"),
        ("o1", "L1", "Tea", 2, "20.00"),
    ]
    first = report["voids"][0]
    assert (first["table"], first["reason_name"], first["by"]) == ("12", "Kitchen error", "Amy")
    assert first["at_ms"] == T0 + 10
    assert first["approved_by"] == {"staff_id": "s3", "name": "Mike"}
    assert report["void_total"] == "50.00" and report["void_count"] == 3
    assert report["voids_by_reason"] == [
        {"key": "Kitchen error", "amount": "40.00", "count": 2},
        {"key": "Rung in wrong", "amount": "10.00", "count": 1},
    ]
    assert report["voids_by_staff"] == [
        {"key": "Amy", "amount": "40.00", "count": 2},
        {"key": "Ben", "amount": "10.00", "count": 1},
    ]
    assert report["voids_by_approver"] == [{"key": "Mike", "amount": "50.00", "count": 3}]
    # only the voids made since then, whatever the age of their order
    later = c.get("/reports/adjustments", params={"since": T0 + 15}).json()
    assert [v["line_id"] for v in later["voids"]] == ["L1", "L1"] and later["void_total"] == "30.00"


def test_a_void_from_before_reasons_were_asked_is_reported_without_one():
    """The log keeps voids made before this rule: they count, under no reason and no approver."""
    store = OpStore(physical=lambda: T0 + 100)
    stamp = lambda at: HLC(T0 + at, 0, "t1")  # noqa: E731
    store.append(
        [
            Op("a", "o1", stamp(0), "t1", "create", {"table": "3"}),
            Op("b", "o1", stamp(1), "t1", "add_line", {"line_id": "L1", "item": "Tea", "qty": 3, "priced": TEA}),
            Op("c", "o1", stamp(2), "t1", "fire", {"course": "*"}),
            Op("d", "o1", stamp(3), "t1", "void_line", {"line_id": "L1", "reason": "fewer"}),
            Op(
                "e",
                "o1",
                stamp(4),
                "t1",
                "add_line",
                {"line_id": "L2", "item": "Tea", "qty": 2, "priced": TEA, "replaces": "L1"},
            ),
        ]
    )
    rows = void_rows(store.state("o1"))
    assert [(r["line_id"], r["qty"], r["amount"], r["reason_name"], r["by"], r["approved_by"]) for r in rows] == [
        ("L1", 1, "10.00", "", "", None)
    ]
