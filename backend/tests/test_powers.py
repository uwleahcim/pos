"""Who may do what: the table of powers a location hands to its roles (docs/roles.md). A manager and an owner
hold every power whatever the table says; only they change it; it starts as the hub always was; and every
check on the hub weighs a role against the table as it stands when the check is made."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.powers import (
    ALWAYS,
    HANDED,
    POWERS,
    SETTINGS,
    STANDARD,
    clean_powers,
    held,
    holds,
    opens_back_office,
    table,
)
from pos.identity.staff import Directory, Staff, roster
from pos.menu.service import MenuService, load_definitions
from pos.printing.service import PrintService
from pos.settings import DEFAULTS, PgSettingStore, SettingStore
from pos.sync.oplog import OpStore
from pos.tax import massachusetts

from .conftest import T0
from .orders.test_adjustments import DUCK, TEA, payload

STAFF = (
    ("s1", "Amy", "server", "1111"),
    ("s2", "Ben", "bartender", "2222"),
    ("s3", "Mike", "manager", "9999"),
    ("s4", "Holly", "host", "3333"),
    ("s5", "Cara", "cashier", "5555"),
    ("s6", "Ken", "kitchen", "6666"),
    ("s7", "Olive", "owner", "7777"),
)
PIN = {name: pin for _, name, _, pin in STAFF}
EVERY = [power.id for power in POWERS]


def client(settings: SettingStore | None = None) -> TestClient:
    """A hub with one person of every role."""
    return TestClient(
        create_app(
            OpStore(physical=lambda: T0 + 100),
            staff=Directory([Staff.with_pin(*person) for person in STAFF]),
            menu=MenuService(load_definitions("restaurant")),
            taxes=massachusetts(),
            printing=PrintService([]),
            settings=settings,
        )
    )


def session(c: TestClient, who: str, power: str | None = None):
    """The answer to a PIN at the back office's door, as it came."""
    body = {"device": "t1", "pin": PIN[who]} | ({"power": power} if power else {})
    return c.post("/admin/session", json=body)


def bearer(c: TestClient, who: str) -> dict[str, str]:
    answer = session(c, who)
    assert answer.status_code == 200, answer.text
    return {"authorization": f"Bearer {answer.json()['token']}"}


def hand(c: TestClient, who: str = "Mike", **roles: list[str]):
    """A manager hands powers out (or takes them back): the hub's answer as it came."""
    return c.put("/settings/powers", json={"roles": roles}, headers=bearer(c, who))


def approval(c: TestClient, who: str, purpose: str, order_id: str = "o1"):
    return c.post("/approvals", json={"device": "t1", "pin": PIN[who], "order_id": order_id, "purpose": purpose})


def supper(c: TestClient, order_id: str = "o1") -> None:
    """A table with tea (L1) and a duck (L2), both sent to the kitchen."""
    ops = [
        payload(f"{order_id}-a", "create", 0, order_id, table="12", guests=2, order_type="dine_in"),
        payload(f"{order_id}-b", "add_line", 1, order_id, line_id="L1", item="Tea", qty=1, priced=TEA, by="Amy"),
        payload(f"{order_id}-c", "add_line", 2, order_id, line_id="L2", item="Duck", qty=1, priced=DUCK, by="Amy"),
        payload(f"{order_id}-d", "fire", 3, order_id, course="*"),
    ]
    assert c.post(f"/orders/{order_id}/ops", json=ops).json()["refused"] == []


def send(c: TestClient, *ops: dict, order_id: str = "o1") -> dict:
    return c.post(f"/orders/{order_id}/ops", json=list(ops)).json()


def codes(answer: dict) -> list[list[str]]:
    return [[p["code"] for p in r["problems"]] for r in answer["refused"]]


# --- the table itself -------------------------------------------------------------------------------------


def test_the_table_starts_as_the_hub_always_was():
    roles = SettingStore().get("powers")["roles"]
    assert roles == STANDARD == DEFAULTS["powers"]["roles"]
    # nothing is handed out to start but the tables: servers and bartenders take them, hosts give them out
    assert {power: handed for power, handed in roles.items() if handed} == {
        "take_tables": ["server", "bartender"],
        "assign_tables": ["host"],
    }
    assert held(None, "server") == held(None, "bartender") == ["take_tables"]
    assert held(None, "host") == ["assign_tables"]
    assert held(None, "cashier") == held(None, "kitchen") == []
    assert clean_powers(DEFAULTS["powers"]) == DEFAULTS["powers"]


def test_a_manager_and_an_owner_hold_every_power_whatever_the_table_says():
    nothing = {"roles": {power: [] for power in EVERY}}
    for role in ("manager", "owner"):
        for setting in (None, nothing, {"roles": "nonsense"}, {}):
            assert held(setting, role) == [*EVERY, SETTINGS]
            assert opens_back_office(setting, role)
    # and the table cannot be made to say otherwise: listing them is refused, not kept as if it meant something
    for role in sorted(ALWAYS):
        with pytest.raises(ValueError, match="holds every power already"):
            clean_powers({"roles": {"void": [role]}})


def test_the_settings_are_never_handed_out():
    everything = {"roles": {power: list(HANDED) for power in EVERY}}
    for role in HANDED:
        assert held(everything, role) == EVERY  # every power there is to hand, and not the settings
        assert not holds(everything, role, SETTINGS)
    with pytest.raises(ValueError, match="stay with the managers"):
        clean_powers({"roles": {SETTINGS: ["server"]}})
    assert not holds({"roles": {SETTINGS: ["server"]}}, "server", SETTINGS)  # nor by a table that says so anyway


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ({"roles": []}, "for each power"),
        ({"roles": {"fly": ["server"]}}, "unknown power: fly"),
        ({"roles": {"void": "server"}}, "must be a list"),
        ({"roles": {"void": [7]}}, "must be a list"),
        ({"roles": {"void": ["chef"]}}, "unknown role: chef"),
        ({"roles": {"void": ["Server"]}}, "unknown role: Server"),
    ],
)
def test_a_bad_table_is_refused_with_the_reason(body, problem):
    with pytest.raises(ValueError, match=problem):
        clean_powers(body)


def test_the_table_is_tidied_and_a_power_left_out_is_the_standard_one():
    cleaned = clean_powers({"roles": {"void": ["kitchen", "server", "server"], "take_tables": []}})
    assert cleaned["roles"]["void"] == ["server", "kitchen"]  # in the screen's order, each once
    assert cleaned["roles"]["take_tables"] == []  # taken from the servers: a location's choice
    assert cleaned["roles"]["assign_tables"] == ["host"]
    assert list(cleaned["roles"]) == EVERY
    # a role this hub does not know holds nothing, and so does a power it does not know
    assert not holds(cleaned, "dishwasher", "void") and not holds(cleaned, "server", "fly")
    assert held(cleaned, "dishwasher") == [] and not opens_back_office(cleaned, "dishwasher")


def test_a_table_stored_by_an_older_hub_gains_the_powers_added_since():
    settings = SettingStore()
    settings.put("powers", {"roles": {"void": ["bartender"]}})  # as if `void` were all there was then
    roles = settings.get("powers")["roles"]
    assert roles["void"] == ["bartender"] and roles["take_tables"] == ["server", "bartender"]
    assert holds(settings.get("powers"), "bartender", "void") and holds(settings.get("powers"), "host", "assign_tables")


# --- reading and changing it ------------------------------------------------------------------------------


def test_any_screen_reads_the_table_with_what_it_needs_to_draw_it():
    c = client()
    read = c.get("/settings/powers").json()
    assert read["roles"] == STANDARD
    assert [power["id"] for power in read["powers"]] == EVERY
    assert all(power["about"] for power in read["powers"])
    assert read["handed"] == list(HANDED) and read["always"] == ["manager", "owner"]
    assert read == table(None)
    by_door = {power["id"]: power["session"] for power in read["powers"]}
    assert [power for power, session in by_door.items() if not session] == [
        "void",
        "adjust",
        "exempt",
        "take_tables",
        "assign_tables",
    ]


def test_only_a_manager_or_an_owner_changes_the_table():
    c = client()
    assert c.put("/settings/powers", json={"roles": {"void": ["server"]}}).status_code == 401
    assert hand(c, void=["bartender"]).json()["roles"]["void"] == ["bartender"]
    assert hand(c, "Olive", adjust=["bartender"]).json()["roles"]["adjust"] == ["bartender"]
    # a power named changes; the ones left out stay as they are, not as they started
    now = c.get("/settings/powers").json()["roles"]
    assert (now["void"], now["adjust"], now["take_tables"]) == (["bartender"], ["bartender"], ["server", "bartender"])
    # hand a role everything there is to hand: it still cannot hand anything on
    everything = {power: list(HANDED) for power in EVERY}
    assert hand(c, **everything).status_code == 200
    for who in ("Amy", "Ben", "Holly", "Cara", "Ken"):
        refused = c.put("/settings/powers", json={"roles": {"void": []}}, headers=bearer(c, who))
        assert (refused.status_code, refused.json()["detail"]["power"]) == (403, SETTINGS)
    assert c.get("/settings/powers").json()["roles"] == everything


@pytest.mark.parametrize(
    "roles",
    [{"fly": ["server"]}, {"void": ["manager"]}, {"void": ["chef"]}, {"settings": ["server"]}],
)
def test_a_bad_change_is_refused_and_changes_nothing(roles):
    c = client()
    answer = hand(c, **roles)
    assert (answer.status_code, answer.json()["detail"]["error"]) == (422, "bad_value")
    assert c.get("/settings/powers").json()["roles"] == STANDARD


def test_a_change_tells_every_screen(monkeypatch):
    c = client()
    told: list[str] = []
    monkeypatch.setattr(c.app.state.feed, "changed", told.append)
    assert hand(c, rush=["host"]).status_code == 200
    assert told == ["settings"]  # the screens read the table again, and the staff list with it
    assert hand(c, rush=["chef"]).status_code == 422
    assert told == ["settings"]


# --- a PIN on the spot: voids, discounts, tax-exempt checks ---------------------------------------------------


def test_only_a_manager_or_an_owner_approves_until_the_power_is_handed_out():
    c = client()
    for purpose in ("void", "adjust", "exempt"):
        for who in ("Amy", "Ben", "Holly", "Cara", "Ken"):
            refused = approval(c, who, purpose)
            assert refused.status_code == 403
            assert refused.json()["detail"] == {"error": "not_allowed", "role": dict(_roles())[who], "power": purpose}
        for who in ("Mike", "Olive"):
            assert approval(c, who, purpose).status_code == 200


def _roles() -> list[tuple[str, str]]:
    return [(name, role) for _, name, role, _ in STAFF]


def test_a_bartender_handed_voids_approves_a_void_and_nothing_else():
    c = client()
    supper(c)
    assert hand(c, void=["bartender"]).status_code == 200
    assert approval(c, "Amy", "void").status_code == 403  # a server's PIN still approves nothing
    assert approval(c, "Ben", "adjust").status_code == 403  # and a bartender's no discount
    assert approval(c, "Ben", "exempt").status_code == 403
    granted = approval(c, "Ben", "void")
    assert (granted.status_code, granted.json()["name"], granted.json()["role"]) == (200, "Ben", "bartender")
    token = granted.json()["approval"]

    # the approval is for voids on this order alone, like a manager's
    comp = {"discount_id": "d1", "scope": "check", "reason": "comp", "kind": "comp", "by": "Amy"}
    assert codes(send(c, payload("e", "discount", 4, **comp, approval=token))) == [["needs_approval"]]
    void = payload("f", "void_line", 5, line_id="L2", reason="kitchen-error", by="Amy", by_id="s1", approval=token)
    answer = send(c, void)
    assert answer["accepted"] == ["f"] and answer["refused"] == []
    voided = c.get("/orders/o1").json()["lines"]["L2"]["voided"]
    assert voided["approved_by"] == {"staff_id": "s2", "name": "Ben"} and voided["by"] == "Amy"
    # and the report of what came off names who approved it
    report = c.get("/reports/adjustments").json()
    assert [(row["approved_by"]["name"], row["by"]) for row in report["voids"]] == [("Ben", "Amy")]


def test_an_approval_is_weighed_when_it_is_used_not_when_it_was_given():
    c = client()
    supper(c)
    assert hand(c, void=["bartender"]).status_code == 200
    token = approval(c, "Ben", "void").json()["approval"]
    assert hand(c, void=[]).status_code == 200  # the manager takes it back before the void is sent
    void = payload("e", "void_line", 4, line_id="L2", reason="kitchen-error", approval=token)
    assert codes(send(c, void)) == [["needs_approval"]]
    assert c.get("/orders/o1").json()["lines"]["L2"]["status"] == "active"
    assert approval(c, "Ben", "void").status_code == 403


def test_a_power_handed_out_approves_a_comp_and_a_tax_exempt_check():
    c = client()
    supper(c)
    assert hand(c, adjust=["server"], exempt=["cashier"]).status_code == 200
    comp = {"discount_id": "d1", "scope": "check", "reason": "comp", "kind": "comp", "by": "Amy"}
    token = approval(c, "Amy", "adjust").json()["approval"]
    assert send(c, payload("e", "discount", 4, **comp, approval=token))["refused"] == []
    stored = next(op for op in c.get("/ops").json()["ops"] if op["op_id"] == "e")["data"]
    assert "approval" not in stored and stored["approved_by"] == {"staff_id": "s1", "name": "Amy"}

    supper(c, "o2")
    pta = {"organisation": "Lincoln School PTA", "certificate": "E-042-881-552"}
    assert approval(c, "Amy", "exempt", "o2").status_code == 403
    token = approval(c, "Cara", "exempt", "o2").json()["approval"]
    mark = payload("g", "set_field", 5, "o2", tax_exempt=pta, approval=token, by="Amy", by_id="s1")
    assert send(c, mark, order_id="o2")["refused"] == []
    check = c.get("/orders/o2/check").json()
    assert check["tax"] == "0.00" and check["tax_exempt"]["approved_by"] == "Cara"
    # the sale is whole in the day's figures either way: an exemption takes off the tax, never the sale
    assert check["subtotal"] == "30.00"


# --- the back office: a session, and what it opens ----------------------------------------------------------

DOORS = [
    ("history", "get", "/orders/o1/history", None),
    ("rush", "put", "/settings/rush", {"minutes": 10}),
    ("notes", "get", "/notes/board", None),
    ("notes", "post", "/notes", {"text": "Duck is out", "lasts": "today"}),
    ("logbook", "get", "/logbook", None),
    ("logbook", "post", "/logbook", {"subject": "Guests", "text": "Table 12 waited", "device": "t1"}),
    ("waste", "get", "/reports/waste", None),
    ("reports", "get", "/reports/day", None),
    ("reports", "get", "/reports/sales", None),
    ("reports", "get", "/reports/sales/sheet", None),
    ("reports", "get", "/reports/dishes", None),
    ("reports", "get", "/reports/today", None),
    ("guests", "get", "/reports/guests", None),
    ("time_clock", "get", f"/timeclock/report?since={T0}&until={T0 + 1000}", None),
    ("menu", "get", "/admin/menu", None),
    ("menu", "get", "/admin/menu/audit", None),
]
LOCKED = [
    ("put", "/settings/quotes", {"minutes": {"counter": 5}, "pay_at_pickup": []}),
    ("put", "/settings/voids", DEFAULTS["voids"]),
    ("put", "/settings/time_clock", {"enabled": True}),
    ("put", "/settings/powers", {"roles": {}}),
    ("get", "/admin/staff", None),
    ("post", "/print/discover", {}),
]


def call(c: TestClient, method: str, path: str, body: dict | None, headers: dict[str, str]) -> int:
    answer = c.request(method.upper(), path, json=body, headers=headers)
    return answer.status_code


def test_nobody_but_a_manager_or_an_owner_gets_a_session_to_start():
    c = client()
    supper(c)
    for who in ("Amy", "Ben", "Holly", "Cara", "Ken"):
        assert session(c, who).status_code == 403
    for who in ("Mike", "Olive"):
        answer = session(c, who)
        assert answer.status_code == 200 and answer.json()["powers"] == [*EVERY, SETTINGS]
        headers = {"authorization": f"Bearer {answer.json()['token']}"}
        for _, method, path, body in DOORS:
            assert call(c, method, path, body, headers) not in (401, 403), path
        for method, path, body in LOCKED:
            assert call(c, method, path, body, headers) not in (401, 403), path
    assert session(c, "Mike").json().keys() >= {"token", "staff_id", "name", "role", "expires", "powers"}
    assert c.post("/admin/session", json={"device": "t1", "pin": "0000"}).status_code == 401


@pytest.mark.parametrize("power", sorted({door[0] for door in DOORS}))
def test_a_power_opens_its_own_doors_and_no_others(power):
    c = client()
    supper(c)
    assert hand(c, **{power: ["host"]}).status_code == 200
    answer = session(c, "Holly")
    assert answer.status_code == 200 and answer.json()["powers"] == sorted(["assign_tables", power], key=EVERY.index)
    headers = {"authorization": f"Bearer {answer.json()['token']}"}
    for door, method, path, body in DOORS:
        status = call(c, method, path, body, headers)
        if door == power:
            assert status not in (401, 403), path
        else:
            assert status == 403, path
    for method, path, body in LOCKED:
        assert call(c, method, path, body, headers) == 403, path
    # the other roles are where they were
    assert session(c, "Amy").status_code == 403


def test_a_power_that_is_no_session_opens_no_session():
    c = client()
    assert hand(c, void=["server"], adjust=["server"], exempt=["server"], assign_tables=["server"]).status_code == 200
    assert session(c, "Amy").status_code == 403  # Amy approves and seats; the back office is not hers
    assert held(c.app.state.settings.get("powers"), "server") == [
        "void",
        "adjust",
        "exempt",
        "take_tables",
        "assign_tables",
    ]


def test_a_session_asked_for_one_power_is_refused_to_a_role_without_it():
    c = client()
    assert hand(c, reports=["host"]).status_code == 200
    assert session(c, "Holly").status_code == 200
    assert session(c, "Holly", "reports").status_code == 200
    refused = session(c, "Holly", "rush")
    assert refused.status_code == 403
    assert refused.json()["detail"] == {"error": "not_allowed", "role": "host", "power": "rush"}
    assert session(c, "Holly", SETTINGS).status_code == 403
    assert session(c, "Holly", "fly").status_code == 403
    for power in (*EVERY, SETTINGS):
        assert session(c, "Mike", power).status_code == 200


def test_a_session_is_weighed_on_every_call():
    c = client()
    assert hand(c, reports=["host"]).status_code == 200
    headers = bearer(c, "Holly")
    assert c.get("/reports/day", headers=headers).status_code == 200
    assert hand(c, reports=[]).status_code == 200  # taken back while her session is open
    assert c.get("/reports/day", headers=headers).status_code == 403
    assert session(c, "Holly").status_code == 403
    # and handed to her again, the session she had is good again until it runs out
    assert hand(c, reports=["host"]).status_code == 200
    assert c.get("/reports/day", headers=headers).status_code == 200


def test_the_rush_says_who_set_it_whoever_holds_the_power():
    c = client()
    assert hand(c, rush=["host"]).status_code == 200
    answer = c.put("/settings/rush", json={"minutes": 15}, headers=bearer(c, "Holly"))
    assert answer.status_code == 200
    assert (answer.json()["rush"]["minutes"], answer.json()["rush"]["by"]) == (15, "Holly")


def test_whoever_holds_the_waste_power_strikes_anyones_entry():
    c = client()
    wings = next(iter(c.app.state.menu.defs.variants))
    entry = c.post("/waste", json={"staff_id": "s1", "variant_id": wings, "qty": 1, "reason": "Dropped"}).json()
    as_ken = {"staff_id": "s6"}
    assert c.post(f"/waste/{entry['id']}/strike", json=as_ken).json()["detail"]["error"] == "not_yours"
    # a token alone is nobody special: Ken's role has to hold the power
    token, _ = c.app.state.tokens.issue("s6", "Ken", "kitchen")
    headers = {"authorization": f"Bearer {token}"}
    assert c.post(f"/waste/{entry['id']}/strike", json=as_ken, headers=headers).status_code == 409
    assert hand(c, waste=["kitchen"]).status_code == 200
    struck = c.post(f"/waste/{entry['id']}/strike", json=as_ken, headers=headers)
    assert (struck.status_code, struck.json()["struck_by"]) == (200, "Ken")


# --- tables ---------------------------------------------------------------------------------------------------


def test_the_staff_list_follows_the_table():
    c = client()

    def listed() -> dict[str, tuple[bool, bool]]:
        staff = c.get("/staff").json()["staff"]
        return {s["name"]: (s["takes_tables"], s["assigns_tables"]) for s in staff}

    assert listed() == {
        "Amy": (True, False),
        "Ben": (True, False),
        "Mike": (True, True),
        "Holly": (False, True),
        "Cara": (False, False),
        "Ken": (False, False),
        "Olive": (True, True),
    }
    # the hosts take tables too on a slow night, a server may seat for others, the bartenders keep to the bar
    assert hand(c, take_tables=["server", "host"], assign_tables=["host", "server"]).status_code == 200
    assert listed() == {
        "Amy": (True, True),
        "Ben": (False, False),
        "Mike": (True, True),
        "Holly": (True, True),
        "Cara": (False, False),
        "Ken": (False, False),
        "Olive": (True, True),
    }
    # a list read without the table is the standard one
    plain = {s["name"]: s["takes_tables"] for s in roster(c.app.state.staff)}
    assert plain["Ben"] and not plain["Holly"]


# --- kept ---------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not os.environ.get("POS_TEST_DATABASE_URL"), reason="needs PostgreSQL (POS_TEST_DATABASE_URL)")
def test_the_table_is_kept_in_postgres():
    dsn = os.environ["POS_TEST_DATABASE_URL"]
    settings = PgSettingStore(dsn)
    try:
        with settings._pool.connection() as conn:
            conn.execute("DELETE FROM setting WHERE key = 'powers'")
        c = client(settings)
        assert c.get("/settings/powers").json()["roles"] == STANDARD
        assert hand(c, void=["bartender"], reports=["host"]).status_code == 200
        again = PgSettingStore(dsn)  # another hub on the same database, or this one after a restart
        try:
            roles = again.get("powers")["roles"]
            assert (roles["void"], roles["reports"], roles["take_tables"]) == (
                ["bartender"],
                ["host"],
                ["server", "bartender"],
            )
            assert approval(client(again), "Ben", "void").status_code == 200
        finally:
            again.close()
    finally:
        with settings._pool.connection() as conn:
            conn.execute("DELETE FROM setting WHERE key = 'powers'")
        settings.close()
