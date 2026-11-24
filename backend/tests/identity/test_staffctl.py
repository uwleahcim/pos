"""The staff from the hub's terminal (`pos.identity.staffctl`, what `hubctl staff` runs): the list, and the way
back in when no manager can sign in any more. A PIN comes on standard input and is never printed."""

from __future__ import annotations

import io

from pos.identity.staff import Directory, Staff
from pos.identity.staff_list import Actor, StaffList, StaffStore
from pos.identity.staffctl import main

MIKE = Actor("s3", "Mike")


def own() -> list[Staff]:
    return [
        Staff.with_pin("s1", "Amy", "server", "1111"),
        Staff.with_pin("s2", "Ben", "bartender", "2222"),
        Staff.with_pin("s3", "Mike", "manager", "9999"),
    ]


def run(staff: StaffList, *args: str, typed: str = "", environ: dict[str, str] | None = None) -> tuple[int, str]:
    out = io.StringIO()
    code = main(list(args), staff=staff, stdin=io.StringIO(typed), out=out, environ=environ or {})
    return code, out.getvalue()


def signs_in(staff: StaffList, pin: str) -> str | None:
    found = Directory(staff.in_force()[0]).by_pin(pin, device="t1")
    return None if found is None else found.name


def test_the_list_says_who_is_on_the_staff_and_where_the_list_is_kept():
    staff = StaffList(own=own(), source="hub")
    code, said = run(staff)
    assert code == 0
    assert said.splitlines() == [
        "The staff are the hub's own list: POS_STAFF in /opt/pos/.env. Nothing was changed in the app yet.",
        "  s1  Amy   server     PIN from POS_STAFF",
        "  s2  Ben   bartender  PIN from POS_STAFF",
        "  s3  Mike  manager    PIN from POS_STAFF",
        "A new PIN for somebody: hubctl staff pin <id or name>",
    ]
    assert "DEMO staff" in run(StaffList(own=own(), source="demo"), "list")[1]
    staff.add("Kim", "server", "4827", by=MIKE)
    code, said = run(staff, "list", environ={"POS_STAFF": "s1:Amy:server:1111"})
    lines = said.splitlines()
    assert lines[0] == "The staff are kept in the app: Location, Staff and PINs."
    assert lines[1] == "POS_STAFF in /opt/pos/.env is not read any more: that line can go."
    assert lines[5] == "  s4  Kim   server     PIN set in the app"
    for pin in ("1111", "2222", "9999", "4827"):
        assert pin not in said


def test_a_list_with_no_manager_says_so():
    staff = StaffList(own=own()[:2])
    assert "Nobody here is a manager or an owner" in run(staff)[1]


def test_a_pin_set_in_the_terminal_is_the_way_back_in():
    store = StaffStore()
    staff = StaffList(store, own=own(), source="hub")
    code, said = run(staff, "pin", "s3", typed="4827\n")
    assert code == 0 and "4827" not in said
    assert said.splitlines()[0] == (
        "Mike's PIN is changed. It works within a minute, with no restart, and the old one does not."
    )
    assert "From now on the staff are kept in the app" in said and "POS_STAFF in /opt/pos/.env is not read" in said
    assert signs_in(staff, "4827") == "Mike" and signs_in(staff, "9999") is None
    assert signs_in(staff, "1111") == "Amy", "everybody else with the PIN they had"
    mike = next(m for m in staff.members() if m.staff_id == "s3")
    assert (mike.pin_from, mike.pin_by) == ("terminal", "the hub's terminal")
    # by name, written any way; and no word about the list the second time: it is the app's already
    code, said = run(staff, "pin", "amy", typed="5310\r\n")
    assert code == 0 and said.splitlines() == [
        "Amy's PIN is changed. It works within a minute, with no restart, and the old one does not."
    ]
    assert signs_in(staff, "5310") == "Amy"
    assert "  s1  Amy   server     PIN set here, in the terminal" in run(staff)[1]


def test_what_the_terminal_does_not_take_changes_nothing_and_never_repeats_the_pin():
    staff = StaffList(own=[*own(), Staff.with_pin("s4", "amy", "host", "3333")], source="hub")
    for who, typed, words in (
        ("s3", "48271\n", "A PIN is four digits. Nothing was changed."),
        ("s3", "\n", "A PIN is four digits. Nothing was changed."),
        ("s3", "", "A PIN is four digits. Nothing was changed."),
        ("s3", "2222\n", "Somebody else has that PIN. Pick another. Nothing was changed."),
        ("Zed", "4827\n", "Nobody on the staff is called Zed. `hubctl staff` lists everybody. Nothing was changed."),
        ("Amy", "4827\n", "2 people are called Amy. Say which by id: s1, s4. Nothing was changed."),
    ):
        code, said = run(staff, "pin", who, typed=typed)
        assert (code, said.strip()) == (1, words)
    assert staff.source() == "hub" and signs_in(staff, "9999") == "Mike"


def test_anything_else_is_told_how_it_is_used():
    staff = StaffList(own=own())
    for args in (("pin",), ("pin", "s3", "4827"), ("forget",), ("list", "all")):
        code, said = run(staff, *args, typed="4827\n")
        assert code == 2 and said.strip() == "usage: hubctl staff | hubctl staff pin <id or name>"
    assert signs_in(staff, "9999") == "Mike"
