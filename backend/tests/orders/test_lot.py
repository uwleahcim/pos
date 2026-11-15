"""Several dishes comped or voided in one go (the app's Comp and Void for the dishes picked up on the check):
one manager's approval covers every operation of the batch for that order, each dish keeps its own record,
and the kitchen gets one VOID ticket per station, not one per dish."""

from __future__ import annotations

from fastapi.testclient import TestClient

from ..printing.fake_printer import decode
from ..printing.test_other_stations import CHICKEN, ROLL, kitchen
from ..printing.test_other_stations import send as send_dishes
from .test_adjustments import client, payload, tea_and_duck
from .test_voids import approval, lines, send, table


def test_one_approval_voids_every_sent_dish_of_the_batch_and_the_unsent_one_just_comes_off():
    c = client()
    table(c)  # tea (L1) and a duck (L2), both sent
    send(c, payload("e", "add_line", 4, line_id="L3", item="Tea", qty=1, priced={"unit_price": "10.00", "name": "Tea"}))
    token = approval(c)
    word = {"reason": "guest-changed-mind", "by": "Amy", "by_id": "s1", "approval": token}
    answer = send(
        c,
        payload("v1", "void_line", 10, line_id="L1", **word),
        payload("v2", "void_line", 11, line_id="L2", **word),
        payload("v3", "void_line", 12, line_id="L3", by="Amy", by_id="s1"),  # never sent: nothing asked
    )
    assert answer["refused"] == [] and answer["accepted"] == ["v1", "v2", "v3"]
    now = lines(c)
    assert [now[i]["status"] for i in ("L1", "L2", "L3")] == ["void", "void", "removed"]
    report = c.get("/reports/adjustments").json()
    assert [(v["line_id"], v["reason"], v["by"], v["approved_by"]["name"]) for v in report["voids"]] == [
        ("L1", "guest-changed-mind", "Amy", "Mike"),
        ("L2", "guest-changed-mind", "Amy", "Mike"),
    ]
    assert [t["line_id"] for t in report["taken_off"]] == ["L3"]
    # the token never reaches the log, on any of them
    assert all("approval" not in op["data"] for op in c.get("/ops").json()["ops"])


def test_one_approval_comps_every_dish_of_the_batch_each_with_its_own_discount():
    c = client()
    tea_and_duck(c)
    token = approval(c, purpose="adjust")
    comp = {"reason": "comp", "kind": "comp", "applied_by": "Amy", "approval": token}
    answer = send(
        c,
        payload("d1", "discount", 10, discount_id="D1", line_id="L1", **comp),
        payload("d2", "discount", 11, discount_id="D2", line_id="L2", **comp),
    )
    assert answer["refused"] == []
    check = c.get("/orders/o1/check").json()
    assert [(d["discount_id"], d["line_id"], d["approved_by"]["name"]) for d in check["discounts"]] == [
        ("D1", "L1", "Mike"),
        ("D2", "L2", "Mike"),
    ]
    assert check["total"] == "0.00"
    # a dish of the lot that already has a comp is refused on its own; the others go through
    again = send(
        c,
        payload("d3", "discount", 20, discount_id="D3", line_id="L1", **comp),
    )
    assert [r["problems"][0]["code"] for r in again["refused"]] == ["no_stacking"]


def test_a_lot_voided_together_is_one_void_ticket_at_each_station():
    c: TestClient = kitchen("wok", "sushi")
    send_dishes(c, "o1", CHICKEN, CHICKEN, ROLL)
    token = approval(c)
    word = {"reason": "kitchen-error", "by": "Amy", "approval": token}
    voids = [payload(f"v{n}", "void_line", 200 + n, line_id=f"L0-{n}", **word) for n in (1, 2, 3)]
    answer = c.post("/orders/o1/ops", json=voids).json()
    assert answer["refused"] == []
    assert answer["print_jobs"] == ["v1:wok", "v1:sushi"]  # one ticket a station for the three voids
    store = c.app.state.printing.store
    wok, sushi = decode(store.get("v1:wok").data), decode(store.get("v1:sushi").data)
    assert "*** VOID *** WOK" in wok.text and "*** VOID *** SUSHI BAR" in sushi.text
    # the wok's two dishes are both on its one ticket (their names print as pictures: Chinese)
    assert len(wok.images) == 2 * len(sushi.images) > 0
