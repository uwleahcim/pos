"""Whose table it is: the server a table is given to, by opening it or by a host, and the staff a screen
can pick one from."""

from __future__ import annotations

from pos.identity.powers import holds
from pos.identity.staff import Directory, Staff, demo_directory, roster

from .test_menu_orders import client, payload


def test_the_staff_list_says_who_takes_tables_and_who_gives_them_out():
    c = client()
    staff = {s["name"]: s for s in c.get("/staff").json()["staff"]}
    assert set(staff) == {"Amy", "Ben", "Mike", "Holly"}
    assert staff["Amy"] == {
        "staff_id": "s1",
        "name": "Amy",
        "role": "server",
        "takes_tables": True,
        "assigns_tables": False,
    }
    assert (staff["Ben"]["takes_tables"], staff["Ben"]["assigns_tables"]) == (True, False)  # the bartender
    assert (staff["Mike"]["takes_tables"], staff["Mike"]["assigns_tables"]) == (True, True)  # a manager does both
    assert (staff["Holly"]["takes_tables"], staff["Holly"]["assigns_tables"]) == (False, True)  # the host

    # a screen that has the list is told so until the staff changes
    first = c.get("/staff")
    assert c.get("/staff", headers={"if-none-match": first.headers["etag"]}).status_code == 304


def test_the_staff_list_holds_nothing_a_sign_in_is_checked_against():
    amy = Staff.with_pin("s1", "Amy", "server", "1111", tag_uid="04A1B2C3")
    (listed,) = roster(Directory([amy]))
    assert set(listed) == {"staff_id", "name", "role", "takes_tables", "assigns_tables"}
    assert not {amy.pin_hash, amy.pin_salt, amy.tag_uid, "1111"} & {str(v) for v in listed.values()}


def test_kitchen_and_cashier_neither_take_nor_give_tables():
    listed = roster(
        Directory([Staff.with_pin("k", "Wok", "kitchen", "1"), Staff.with_pin("c", "Till", "cashier", "2")])
    )
    assert all(not s["takes_tables"] and not s["assigns_tables"] for s in listed)
    assert holds(None, "host", "assign_tables") and not holds(None, "host", "take_tables")
    assert any(s.role == "host" for s in demo_directory().all())  # the demo staff has one to try it with


def test_a_table_is_its_servers_by_opening_it_or_by_the_host_giving_it():
    c = client()
    # Amy opens her own table: the terminal stamps the check with who is signed in
    c.post("/orders/o1/ops", json=[payload("a", "create", 0, table="A7", guests=4, server="Amy", server_id="s1")])
    (check,) = c.get("/floor").json()["status"]["A7"]
    assert (check["server"], check["server_id"]) == ("Amy", "s1")

    # the host seats a party at B2 for Ben: the check is Ben's, and the log keeps who sat it
    sat = payload("b", "create", 10, table="B2", guests=2, server="Ben", server_id="s2", by="Holly", by_id="s4")
    c.post("/orders/o2/ops", json=[{**sat, "order_id": "o2"}])
    (check,) = c.get("/floor").json()["status"]["B2"]
    assert (check["server"], check["server_id"]) == ("Ben", "s2")
    assert check["timer"]["stage"] == "sat"  # and it waits on Ben from the moment it was sat
    order = c.get("/orders/o2").json()
    assert "by" not in order["fields"] and "by_id" not in order["fields"]  # who sat it is not the check's own
    (stored,) = c.app.state.store.for_order("o2")
    assert (stored.data["by"], stored.data["by_id"]) == ("Holly", "s4")


def test_a_seated_table_is_handed_to_another_server():
    c = client()
    c.post("/orders/o1/ops", json=[payload("a", "create", 0, table="A7", guests=4, server="Amy", server_id="s1")])
    c.post("/orders/o1/ops", json=[payload("b", "set_field", 20, server="Ben", server_id="s2", by="Mike", by_id="s3")])
    (check,) = c.get("/floor").json()["status"]["A7"]
    assert (check["server"], check["server_id"]) == ("Ben", "s2")
    assert check["timer"] == {"stage": "sat", "since_ms": check["opened_ms"]}  # handing it over starts no clock
