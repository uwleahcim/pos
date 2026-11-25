"""The staff as a manager changes them in the app (`pos.identity.staff_list`, docs/staff.md): who is on the
list, each one's role and PIN. The hub's own file is read until the first change; from then on the app's list
is the one that signs in. A PIN is kept as a salted hash, as before, and is never told back."""

from __future__ import annotations

import os
import re

import pytest

from pos.identity.staff import Directory, Locked, Staff, demo_directory, staff_from_env
from pos.identity.staff_list import (
    ROLES,
    STAFF_MOST,
    Actor,
    Member,
    PgStaffStore,
    Refused,
    StaffList,
    StaffStore,
)
from pos.identity.tokens import Tokens

DSN = os.environ.get("POS_TEST_DATABASE_URL")

MIKE = Actor("s3", "Mike")
AMY = Actor("s1", "Amy")


def hashed(salt: str, pin_hash: str) -> bool:
    """Whether what is kept of a PIN is a salted hash (or nothing, for somebody taken off): 16 and 64 letters
    of hex. Looked at by its shape and never for a PIN's digits, because random hex holds any four digits by
    chance now and then: about one run in a hundred, which is how this was found."""
    if not salt and not pin_hash:
        return True
    return bool(re.fullmatch(r"[0-9a-f]{16}", salt) and re.fullmatch(r"[0-9a-f]{64}", pin_hash))


def own() -> list[Staff]:
    return [
        Staff.with_pin("s1", "Amy", "server", "1111"),
        Staff.with_pin("s2", "Ben", "bartender", "2222"),
        Staff.with_pin("s3", "Mike", "manager", "9999"),
        Staff.with_pin("s4", "Holly", "host", "3333"),
    ]


def listed(
    staff: list[Staff] | None = None,
    store: StaffStore | None = None,
    source: str = "hub",
    clock: list[int] | None = None,
) -> StaffList:
    ticks = clock if clock is not None else [1_800_000_000_000]
    return StaffList(store, own=own() if staff is None else staff, source=source, now=lambda: ticks[0])


def signs_in(staff: StaffList, pin: str) -> str | None:
    people, _ = staff.in_force()
    found = Directory(people).by_pin(pin, device="t1")
    return None if found is None else found.name


def refusal(call) -> Refused:  # noqa: ANN001
    with pytest.raises(Refused) as caught:
        call()
    return caught.value


# --- whose list is in force ------------------------------------------------------------------------------------


def test_until_a_manager_changes_anything_the_hub_s_own_list_signs_in():
    staff = listed()
    assert staff.source() == "hub"
    assert [m.name for m in staff.members()] == ["Amy", "Ben", "Mike", "Holly"]
    assert {m.pin_from for m in staff.members()} == {"hub"}
    assert staff.store.all() == [], "nothing is stored for looking"
    assert signs_in(staff, "9999") == "Mike"
    assert listed(source="demo").members()[0].pin_from == "demo"


def test_the_first_change_takes_the_whole_list_over_and_nobody_types_a_pin_again():
    before = own()
    staff = listed(before)
    added = staff.add("Kim", "server", "4827", by=MIKE)
    assert staff.source() == "app"
    assert [m.name for m in staff.members()] == ["Amy", "Ben", "Mike", "Holly", "Kim"]
    kept = {m.staff_id: m for m in staff.store.all()}
    for person in before:  # the very hashes the hub's file gave: no PIN was typed, none was read
        assert (kept[person.staff_id].pin_salt, kept[person.staff_id].pin_hash) == (person.pin_salt, person.pin_hash)
        assert kept[person.staff_id].pin_from == "hub"
    for pin, name in (("1111", "Amy"), ("2222", "Ben"), ("9999", "Mike"), ("3333", "Holly"), ("4827", "Kim")):
        assert signs_in(staff, pin) == name
    assert added.pin_from == "app" and added.pin_by == "Mike" and added.by == "Mike"
    assert added.at_ms == added.pin_at_ms == 1_800_000_000_000


def test_once_the_app_has_the_list_the_hub_s_file_is_not_read_any_more():
    store = StaffStore()
    listed(store=store).remove("s2", by=MIKE)
    # the hub restarts, and its file names Ben still, and somebody new
    later = listed([*own(), Staff.with_pin("x9", "Zed", "manager", "7777")], store=store)
    assert later.source() == "app"
    assert [m.name for m in later.members()] == ["Amy", "Mike", "Holly"]
    assert signs_in(later, "2222") is None and signs_in(later, "7777") is None


def test_a_list_taken_over_at_the_same_moment_on_two_hubs_holds_everybody_once():
    store = StaffStore()
    one, two = listed(store=store), listed(store=store)
    one.add("Kim", "server", "4827", by=MIKE)
    two.add("Lee", "driver", "5310", by=MIKE)
    assert [m.name for m in one.members()] == ["Amy", "Ben", "Mike", "Holly", "Kim", "Lee"]
    assert [m.staff_id for m in one.members()] == ["s1", "s2", "s3", "s4", "s5", "s6"]


# --- adding ----------------------------------------------------------------------------------------------------


def test_an_id_is_never_given_twice_not_even_after_its_owner_left():
    staff = listed()
    kim = staff.add("Kim", "server", "4827", by=MIKE)
    assert kim.staff_id == "s5"
    staff.remove("s5", by=MIKE)
    assert staff.add("Lee", "driver", "5310", by=MIKE).staff_id == "s6"
    # a hub whose file named its people some other way starts counting at one
    named = listed([Staff.with_pin("amy", "Amy", "server", "1111"), Staff.with_pin("boss", "Mike", "owner", "9999")])
    assert named.add("Kim", "server", "4827", by=Actor("boss", "Mike")).staff_id == "s1"
    # and one that named somebody s7 goes on after it
    seven = listed([Staff.with_pin("s7", "Mike", "manager", "9999")])
    assert seven.add("Kim", "server", "4827", by=Actor("s7", "Mike")).staff_id == "s8"


@pytest.mark.parametrize("pin", ["", "123", "12345", "12a4", "١٢٣٤", " 1234", "12 34"])
def test_a_pin_is_four_digits_and_a_refusal_never_repeats_it(pin):
    staff = listed()
    said = refusal(lambda: staff.add("Kim", "server", pin, by=MIKE))
    assert said.code == "bad_value" and "four digits" in said.message
    assert not pin.strip() or pin.strip() not in said.message
    assert staff.source() == "hub", "a refused change takes nothing over"


def test_a_pin_is_one_person_s():
    staff = listed()
    said = refusal(lambda: staff.add("Kim", "server", "2222", by=MIKE))
    assert said.code == "pin_taken" and "2222" not in said.message and "Ben" not in said.message
    said = refusal(lambda: staff.change("s1", pin="9999", by=MIKE))
    assert said.code == "pin_taken"
    staff.change("s1", pin="1111", by=MIKE)  # one's own again is fine
    staff.remove("s2", by=MIKE)
    assert staff.add("Kim", "server", "2222", by=MIKE).name == "Kim", "a PIN is free once its owner has left"


@pytest.mark.parametrize("name", ["", "   ", "x" * 41, "Kim\nLee", "Kim\x00"])
def test_a_name_is_a_short_line(name):
    staff = listed()
    assert refusal(lambda: staff.add(name, "server", "4827", by=MIKE)).code == "bad_value"


def test_a_name_is_kept_tidy_and_is_one_person_s():
    staff = listed()
    assert staff.add("  Kim   Lee ", "server", "4827", by=MIKE).name == "Kim Lee"
    said = refusal(lambda: staff.add("amy", "host", "5310", by=MIKE))
    assert said.code == "name_taken" and "Amy" in said.message
    assert refusal(lambda: staff.change("s2", name="AMY", by=MIKE)).code == "name_taken"
    assert staff.change("s1", name="amy", by=MIKE).name == "amy", "a person's own name, written another way"
    staff.remove("s2", by=MIKE)
    assert staff.add("Ben", "bartender", "5310", by=MIKE).staff_id == "s6", "a name is free once its owner has left"


def test_a_role_is_one_the_hub_knows():
    staff = listed()
    said = refusal(lambda: staff.add("Kim", "waiter", "4827", by=MIKE))
    assert said.code == "bad_value" and "server" in said.message
    assert refusal(lambda: staff.change("s1", role="", by=MIKE)).code == "bad_value"
    assert ROLES == ("server", "bartender", "host", "cashier", "kitchen", "driver", "manager", "owner")
    for role in ROLES[:-1]:
        staff.change("s1", role=role, by=MIKE)


def test_a_list_is_never_longer_than_a_hub_checks_pins_for():
    crowd = [Staff("s3", "Mike", "manager", "", ""), *(Staff(f"p{n}", f"P{n}", "server", "", "") for n in range(199))]
    staff = listed(crowd)
    assert len(staff.members()) == STAFF_MOST
    assert refusal(lambda: staff.add("Kim", "server", "4827", by=MIKE)).code == "full"


# --- changing --------------------------------------------------------------------------------------------------


def test_a_name_a_role_and_a_pin_change_each_alone():
    clock = [1_800_000_000_000]
    staff = listed(clock=clock)
    clock[0] += 1000
    renamed = staff.change("s1", name="Amy W", by=MIKE)
    assert (renamed.name, renamed.role, renamed.pin_from, renamed.pin_by) == ("Amy W", "server", "hub", "")
    assert renamed.by == "Mike" and renamed.at_ms == clock[0]
    assert signs_in(staff, "1111") == "Amy W"
    clock[0] += 1000
    moved = staff.change("s1", role="host", by=MIKE)
    assert (moved.name, moved.role, moved.pin_from) == ("Amy W", "host", "hub")
    clock[0] += 1000
    keyed = staff.change("s1", pin="4827", by=MIKE)
    assert (keyed.pin_from, keyed.pin_by, keyed.pin_at_ms) == ("app", "Mike", clock[0])
    assert signs_in(staff, "4827") == "Amy W" and signs_in(staff, "1111") is None
    assert staff.change("s1", by=MIKE) == keyed, "nothing asked, nothing changed"


def test_a_pin_is_kept_as_a_salted_hash_and_nowhere_in_clear():
    staff = listed()
    staff.add("Kim", "server", "4827", by=MIKE)
    staff.change("s1", pin="5310", by=MIKE)
    for row in staff.store.all():
        assert "4827" not in repr(row) and "5310" not in repr(row) and hashed(row.pin_salt, row.pin_hash)
    kim, amy = (m for m in staff.store.all() if m.staff_id in ("s5", "s1"))
    assert kim.pin_salt != amy.pin_salt and len(kim.pin_hash) == 64


def test_nobody_changes_somebody_who_is_not_there():
    staff = listed()
    assert refusal(lambda: staff.change("s9", name="Zed", by=MIKE)).code == "unknown_staff"
    assert refusal(lambda: staff.remove("s9", by=MIKE)).code == "unknown_staff"
    staff.remove("s2", by=MIKE)
    assert refusal(lambda: staff.change("s2", name="Ben again", by=MIKE)).code == "unknown_staff"
    assert refusal(lambda: staff.remove("s2", by=MIKE)).code == "unknown_staff"


# --- removing --------------------------------------------------------------------------------------------------


def test_somebody_removed_signs_in_no_more_and_keeps_their_name_in_the_history():
    staff = listed()
    gone = staff.remove("s2", by=MIKE)
    assert gone.removed and gone.by == "Mike" and (gone.pin_salt, gone.pin_hash) == ("", "")
    assert [m.name for m in staff.members()] == ["Amy", "Mike", "Holly"]
    people, left = staff.in_force()
    assert [p.staff_id for p in people] == ["s1", "s3", "s4"] and left == {"s2": "Ben"}
    assert signs_in(staff, "2222") is None


# --- what keeps a location from locking itself out ---------------------------------------------------------------


def test_the_last_manager_is_neither_removed_nor_given_another_role():
    staff = listed()
    # from the hub's terminal nobody is signed in, so only this rule stands in the way
    assert refusal(lambda: staff.remove("s3", by=None)).code == "last_manager"
    assert refusal(lambda: staff.change("s3", role="server", by=None)).code == "last_manager"
    staff.change("s1", role="owner", by=None)
    staff.change("s3", role="server", by=None)  # there is an owner now
    assert refusal(lambda: staff.remove("s1", by=None)).code == "last_manager"


def test_nobody_removes_themselves_or_changes_their_own_role():
    staff = listed()
    staff.change("s1", role="manager", by=MIKE)
    assert refusal(lambda: staff.remove("s3", by=MIKE)).code == "yourself"
    assert refusal(lambda: staff.change("s3", role="server", by=MIKE)).code == "yourself"
    assert staff.change("s3", name="Michael", pin="4827", role="manager", by=MIKE).name == "Michael"
    staff.change("s3", role="server", by=AMY)  # the other manager does it
    assert refusal(lambda: staff.add("Kim", "server", "5310", by=MIKE)).code == "not_allowed"


def test_only_a_manager_or_an_owner_on_the_list_changes_it():
    staff = listed()
    for nobody in (AMY, Actor("s9", "Zed")):
        assert refusal(lambda who=nobody: staff.add("Kim", "server", "4827", by=who)).code == "not_allowed"
        assert refusal(lambda who=nobody: staff.change("s2", name="B", by=who)).code == "not_allowed"
        assert refusal(lambda who=nobody: staff.remove("s2", by=who)).code == "not_allowed"
    assert staff.source() == "hub"


def test_what_touches_an_owner_takes_an_owner():
    staff = listed([*own(), Staff.with_pin("s5", "Olive", "owner", "8080")])
    olive = Actor("s5", "Olive")
    for call in (
        lambda: staff.change("s5", name="O", by=MIKE),
        lambda: staff.change("s5", pin="4827", by=MIKE),
        lambda: staff.change("s5", role="manager", by=MIKE),
        lambda: staff.remove("s5", by=MIKE),
        lambda: staff.change("s1", role="owner", by=MIKE),
        lambda: staff.add("Kim", "owner", "4827", by=MIKE),
    ):
        assert refusal(call).code == "owner_only"
    assert staff.change("s1", role="owner", by=olive).role == "owner"
    assert staff.change("s1", name="Amy W", by=olive).name == "Amy W"
    staff.remove("s1", by=olive)
    assert staff.add("Kim", "owner", "4827", by=olive).role == "owner"


def test_a_manager_makes_the_first_owner_where_there_is_none():
    staff = listed()
    assert staff.change("s1", role="owner", by=MIKE).role == "owner"
    assert refusal(lambda: staff.change("s2", role="owner", by=MIKE)).code == "owner_only"
    assert refusal(lambda: staff.change("s1", role="server", by=MIKE)).code == "owner_only"


def test_the_first_owner_may_be_the_manager_themselves():
    staff = listed()

    def mine() -> dict[str, object]:
        return staff.may(MIKE, next(m for m in staff.members() if m.staff_id == "s3"))

    assert mine() == {"change": True, "role": True, "remove": False, "why": "yourself"}
    assert refusal(lambda: staff.change("s3", role="server", by=MIKE)).code == "yourself"
    assert staff.change("s3", role="owner", by=MIKE).role == "owner"
    assert mine() == {"change": True, "role": False, "remove": False, "why": "yourself"}
    assert refusal(lambda: staff.change("s3", role="manager", by=MIKE)).code == "yourself"
    # and where there is an owner, a manager does not make themselves another
    other = listed([*own(), Staff.with_pin("s5", "Olive", "owner", "8080")])
    assert refusal(lambda: other.change("s3", role="owner", by=MIKE)).code == "yourself"


def test_the_screen_is_told_what_this_person_may_do_to_each():
    staff = listed([*own(), Staff.with_pin("s5", "Olive", "owner", "8080")])
    by_mike = {m.staff_id: staff.may(MIKE, m) for m in staff.members()}
    assert by_mike["s1"] == {"change": True, "role": True, "remove": True, "why": None}
    assert by_mike["s3"] == {"change": True, "role": False, "remove": False, "why": "yourself"}
    assert by_mike["s5"] == {"change": False, "role": False, "remove": False, "why": "owner_only"}
    assert staff.roles_for(MIKE) == list(ROLES[:-1])
    olive = Actor("s5", "Olive")
    assert staff.may(olive, staff.members()[2]) == {"change": True, "role": True, "remove": True, "why": None}
    assert staff.roles_for(olive) == list(ROLES)
    assert listed().roles_for(MIKE) == list(ROLES), "no owner yet: a manager may make the first"


# --- noticing a change -------------------------------------------------------------------------------------------


def test_the_mark_moves_with_every_change():
    clock = [1_800_000_000_000]
    staff = listed(clock=clock)
    marks = [staff.mark()]
    for change in (
        lambda: staff.add("Kim", "server", "4827", by=MIKE),
        lambda: staff.change("s1", name="Amy W", by=MIKE),
        lambda: staff.change("s1", role="host", by=MIKE),
        lambda: staff.change("s1", pin="5310", by=MIKE),
        lambda: staff.remove("s2", by=MIKE),
    ):
        clock[0] += 1
        change()
        marks.append(staff.mark())
    assert len(set(marks)) == len(marks)
    assert "4827" not in "".join(marks) and "5310" not in "".join(marks)


def test_the_directory_takes_a_new_list_where_it_stands():
    now = [0.0]
    directory = Directory(own(), clock=lambda: now[0])
    get = directory.get  # what the face sign-in holds on to
    for _ in range(5):
        directory.by_pin("0000", device="t1")
    staff = listed()
    staff.remove("s2", by=MIKE)
    staff.add("Kim", "server", "4827", by=MIKE)
    directory.use(*staff.in_force())
    assert get("s5").name == "Kim" and get("s2") is None and len(directory) == 4
    assert directory.name_of("s2") == "Ben" and directory.name_of("s5") == "Kim" and directory.name_of("s9") is None
    assert directory.sign_in("s2", "tag", device="t1") is None
    with pytest.raises(Locked):  # a pad that was locked stays locked
        directory.by_pin("4827", device="t1")
    assert directory.by_pin("4827", device="t2").name == "Kim" and directory.by_pin("2222", device="t2") is None


def test_a_tag_the_hub_s_own_list_gave_somebody_stays_theirs():
    tagged = [Staff.with_pin("s1", "Amy", "server", "1111", tag_uid="04A1B2C3D4E5F6"), *own()[1:]]
    staff = listed(tagged)
    assert staff.in_force()[0] == tagged, "the hub's own people, exactly as it named them"
    staff.change("s2", name="Benny", by=MIKE)
    people, _ = staff.in_force()
    assert Directory(people).by_tag("04A1B2C3D4E5F6", device="t1").name == "Amy"
    staff.change("s1", role="manager", by=MIKE)
    staff.remove("s1", by=MIKE)
    assert Directory(staff.in_force()[0]).by_tag("04A1B2C3D4E5F6", device="t1") is None


def test_a_token_is_its_holder_s_only_while_the_hub_says_so():
    tokens = Tokens("test")
    token, _ = tokens.issue("s3", "Mike", "manager")
    approval, _ = tokens.issue("s3", "Mike", "manager", 600, scope="void:o1")
    assert tokens.verify(token).name == "Mike"
    directory = Directory(own())
    tokens.still = lambda grant: (who := directory.get(grant.staff_id)) is not None and who.role == grant.role
    assert tokens.verify(token).name == "Mike" and tokens.verify(approval).scope == "void:o1"
    staff = listed()
    staff.change("s1", role="manager", by=MIKE)
    staff.change("s3", role="server", by=AMY)
    directory.use(*staff.in_force())
    assert tokens.verify(token) is None and tokens.verify(approval) is None, "a manager no more"
    staff.remove("s3", by=AMY)
    directory.use(*staff.in_force())
    assert tokens.verify(token) is None


# --- the hub's own file --------------------------------------------------------------------------------------------


def test_the_hub_says_where_its_own_list_comes_from(monkeypatch):
    monkeypatch.setenv("POS_STAFF", "a:Ann:server:1234, b:Bo:manager:5678")
    people, source = staff_from_env()
    assert [p.name for p in people] == ["Ann", "Bo"] and source == "hub"
    assert len(demo_directory()) == 2
    monkeypatch.delenv("POS_STAFF")
    people, source = staff_from_env()
    assert [p.name for p in people] == ["Amy", "Ben", "Mike", "Holly"] and source == "demo"
    monkeypatch.setenv("POS_STAFF", "nothing that reads")
    assert staff_from_env()[1] == "demo"


# --- in PostgreSQL -------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_list_survives_in_postgres_in_its_order_and_holds_no_pin():
    store = PgStaffStore(DSN)
    try:
        with store._pool.connection() as conn:  # noqa: SLF001 - a clean table for the test
            conn.execute("DELETE FROM staff_member")
        clock = [1_800_000_000_000]
        staff = listed(store=store, clock=clock)
        assert staff.source() == "hub" and staff.mark() == ""
        staff.add("Kim", "server", "4827", by=MIKE)
        clock[0] += 5
        staff.change("s1", name="Amy W", pin="5310", by=MIKE)
        staff.remove("s2", by=MIKE)
        mark = staff.mark()
        with store._pool.connection() as conn:  # noqa: SLF001
            # every column there is, now or later, but the salt and the hash: those two by their shape
            dumped = conn.execute(
                "SELECT string_agg((to_jsonb(staff_member) - 'pin_salt' - 'pin_hash')::text, ' ') FROM staff_member"
            ).fetchone()[0]
            pins = conn.execute("SELECT pin_salt, pin_hash FROM staff_member").fetchall()
        assert "4827" not in dumped and "5310" not in dumped and "Amy W" in dumped
        assert len(pins) == 5 and all(hashed(*kept) for kept in pins)
        again = PgStaffStore(DSN)
        try:
            restarted = listed([Staff.with_pin("x9", "Zed", "manager", "7777")], store=again)
            assert restarted.source() == "app" and restarted.mark() == mark
            assert [m.name for m in restarted.members()] == ["Amy W", "Mike", "Holly", "Kim"]
            assert all(isinstance(m, Member) for m in again.all())
            assert signs_in(restarted, "5310") == "Amy W" and signs_in(restarted, "4827") == "Kim"
            assert signs_in(restarted, "2222") is None and signs_in(restarted, "7777") is None
            assert restarted.in_force()[1] == {"s2": "Ben"}
            amy = restarted.members()[0]
            assert (amy.pin_from, amy.pin_by, amy.pin_at_ms, amy.by) == ("app", "Mike", clock[0], "Mike")
            assert restarted.add("Lee", "driver", "6204", by=MIKE).staff_id == "s6"
            assert staff.mark() != mark and [m.name for m in staff.members()][-1] == "Lee"
        finally:
            again.close()
    finally:
        store.close()
