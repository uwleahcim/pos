"""Notes for the shift and the manager's log: a manager puts a note up, each person sees it once, it comes
down when the night is over or when a manager takes it down, and changing its words shows it again; the
managers' own log keeps every entry under a subject and strikes out, never deletes."""

from __future__ import annotations

import os
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.fixtures.example import build_example
from pos.menu.service import MenuService
from pos.notes import LOG_TEXT_MAX, MOST_NOTES, SUBJECTS, TEXT_MAX, NoteStore, Refused, ShiftNotes
from pos.printing.service import PrintService
from pos.sync.oplog import OpStore

DSN = os.environ.get("POS_TEST_DATABASE_URL")

MINUTE = 60_000
HOUR = 60 * MINUTE
DAY = 24 * HOUR

STAFF = [("s1", "Amy"), ("s2", "Ben"), ("s3", "Mike"), ("s4", "Holly")]


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """A time on the restaurant's own clock in November 2026, in wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


class Wall:
    """The hub's clock, set by the test."""

    def __init__(self, now: int) -> None:
        self.now = now

    def __call__(self) -> int:
        return self.now


def notes_at(now: int = at(16), store: NoteStore | None = None) -> tuple[ShiftNotes, Wall]:
    wall = Wall(now)
    return ShiftNotes(store, now_ms=wall), wall


def hub(now: int = at(16)) -> tuple[TestClient, Wall]:
    notes, wall = notes_at(now)
    app = create_app(OpStore(), menu=MenuService(build_example()), printing=PrintService([]), notes=notes)
    return TestClient(app), wall


def manager(c: TestClient) -> dict[str, str]:
    token = c.post("/admin/session", json={"device": "office", "pin": "9999"}).json()["token"]
    return {"authorization": f"Bearer {token}"}


def server(c: TestClient) -> dict[str, str]:
    """A token that says who it is and is no manager's."""
    token, _ = c.app.state.tokens.issue("s1", "Amy", "server")
    return {"authorization": f"Bearer {token}"}


def put_up(c: TestClient, text: str = "Out tonight: lobster", lasts: str = "tonight") -> dict:
    r = c.post("/notes", json={"text": text, "lasts": lasts}, headers=manager(c))
    assert r.status_code == 200, r.text
    return r.json()


def mine(c: TestClient, staff_id: str = "s1") -> dict:
    r = c.get("/notes", params={"staff_id": staff_id})
    assert r.status_code == 200, r.text
    return r.json()


def unseen(c: TestClient, staff_id: str = "s1") -> list[str]:
    return [n["text"] for n in mine(c, staff_id)["notes"] if not n["seen"]]


def saw(c: TestClient, staff_id: str, *ids: str) -> dict:
    r = c.post("/notes/seen", json={"staff_id": staff_id, "note_ids": list(ids)})
    assert r.status_code == 200, r.text
    return r.json()


def board(c: TestClient) -> dict:
    r = c.get("/notes/board", headers=manager(c))
    assert r.status_code == 200, r.text
    return r.json()


def refused(r) -> tuple[int, str]:
    return r.status_code, r.json()["detail"]["error"]


# Notes for the shift ---------------------------------------------------------------------------------------


def test_each_person_sees_a_note_once():
    c, wall = hub()
    assert mine(c) == {"notes": [], "unseen": 0, "now_ms": at(16)}
    note = put_up(c, "Specials: salt and pepper squid.\nOut tonight: lobster.")
    assert note["by"] == "Mike" and note["at_ms"] == at(16) and note["lasts"] == "tonight"

    # everybody but the manager who wrote it has it waiting
    told = mine(c, "s1")
    assert told["unseen"] == 1
    assert [(n["text"], n["by"], n["seen"]) for n in told["notes"]] == [
        ("Specials: salt and pepper squid.\nOut tonight: lobster.", "Mike", False)
    ]
    assert mine(c, "s3")["unseen"] == 0

    # Amy has seen it: it stays up for her to read again, and is not shown to her a second time
    wall.now = at(16, 5)
    after = saw(c, "s1", note["id"])
    assert after["unseen"] == 0 and [n["seen"] for n in after["notes"]] == [True]
    assert unseen(c, "s1") == []
    assert unseen(c, "s2") == ["Specials: salt and pepper squid.\nOut tonight: lobster."]

    # a second note is the only one she has not seen, and the newest is first
    wall.now = at(18)
    put_up(c, "Table 12 is a birthday: candle with dessert.")
    assert unseen(c, "s1") == ["Table 12 is a birthday: candle with dessert."]
    assert [n["text"][:8] for n in mine(c, "s2")["notes"]] == ["Table 12", "Specials"]
    assert mine(c, "s2")["unseen"] == 2


def test_only_a_manager_puts_a_note_up_changes_it_or_takes_it_down():
    c, _ = hub()
    note = put_up(c)
    body = {"text": "Out tonight: lobster and crab", "lasts": "tonight"}
    for headers, status, code in (({}, 401, "sign_in"), (server(c), 403, "not_allowed")):
        assert refused(c.post("/notes", json=body, headers=headers)) == (status, code)
        assert refused(c.put(f"/notes/{note['id']}", json=body, headers=headers)) == (status, code)
        assert refused(c.delete(f"/notes/{note['id']}", headers=headers)) == (status, code)
        assert refused(c.get("/notes/board", headers=headers)) == (status, code)
    assert [n["text"] for n in mine(c)["notes"]] == ["Out tonight: lobster"]
    # reading the notes takes no token, only somebody the hub knows
    assert refused(c.get("/notes", params={"staff_id": "nobody"})) == (404, "unknown_staff")
    assert refused(c.post("/notes/seen", json={"staff_id": "nobody", "note_ids": [note["id"]]})) == (
        404,
        "unknown_staff",
    )


def test_a_note_needs_words_and_not_too_many():
    c, _ = hub()
    h = manager(c)
    assert refused(c.post("/notes", json={"text": "  \n \n", "lasts": "tonight"}, headers=h)) == (422, "no_text")
    long = "x" * (TEXT_MAX + 1)
    assert refused(c.post("/notes", json={"text": long, "lasts": "tonight"}, headers=h)) == (422, "long_text")
    assert refused(c.post("/notes", json={"text": "Rush", "lasts": "a week"}, headers=h)) == (422, "bad_lasts")
    assert mine(c)["notes"] == []
    # the ends and the runs of blank lines come off; the lines themselves stay
    kept = put_up(c, "  Specials:  \r\n\r\n\r\n\r\nsquid\t(spicy)  \n")
    assert kept["text"] == "Specials:\n\nsquid (spicy)"
    assert put_up(c, "y" * TEXT_MAX)["text"] == "y" * TEXT_MAX


def test_a_note_for_tonight_comes_down_when_the_night_is_over():
    c, wall = hub(at(16))
    tonight = put_up(c, "Out tonight: lobster")
    stays = put_up(c, "Staff meeting Saturday at 3", lasts="stays")
    assert tonight["until_ms"] == at(4, day=17) and stays["until_ms"] is None and stays["lasts"] == "stays"

    wall.now = at(3, 59, day=17)  # the bar is still open
    assert len(mine(c)["notes"]) == 2
    wall.now = at(4, day=17)
    assert [n["text"] for n in mine(c)["notes"]] == ["Staff meeting Saturday at 3"]
    wall.now = at(16, day=20)
    assert [n["text"] for n in mine(c)["notes"]] == ["Staff meeting Saturday at 3"]

    # one written after midnight belongs to the night that is ending
    wall.now = at(1, 30, day=21)
    assert put_up(c, "Last call was 1:15")["until_ms"] == at(4, day=21)

    # what came down is in the manager's list for two weeks, the latest to come down first
    wall.now = at(16, day=21)
    told = board(c)
    assert [(n["text"], n["ended_ms"], n["removed_by"]) for n in told["earlier"]] == [
        ("Last call was 1:15", at(4, day=21), ""),
        ("Out tonight: lobster", at(4, day=17), ""),
    ]
    wall.now = at(16, day=17) + 14 * DAY + HOUR
    assert [n["text"] for n in board(c)["earlier"]] == ["Last call was 1:15"]


def test_new_words_show_a_note_to_everybody_again():
    c, wall = hub()
    h = manager(c)
    note = put_up(c, "Out tonight: lobster")
    saw(c, "s1", note["id"])
    saw(c, "s2", note["id"])

    # only how long it is up: nobody is shown it again
    wall.now = at(17)
    kept = c.put(f"/notes/{note['id']}", json={"text": "Out tonight: lobster", "lasts": "stays"}, headers=h).json()
    assert kept["until_ms"] is None and kept["edited_ms"] is None
    assert unseen(c, "s1") == []

    # new words: everybody but the manager who wrote them
    wall.now = at(18)
    body = {"text": "Out tonight: lobster and crab", "lasts": "stays"}
    changed = c.put(f"/notes/{note['id']}", json=body, headers=h).json()
    assert changed["id"] == note["id"] and changed["edited_ms"] == at(18) and changed["at_ms"] == at(16)
    assert unseen(c, "s1") == ["Out tonight: lobster and crab"]
    assert unseen(c, "s2") == ["Out tonight: lobster and crab"]
    assert unseen(c, "s3") == []
    assert len(mine(c)["notes"]) == 1

    assert refused(c.put("/notes/none", json=body, headers=h)) == (404, "unknown_note")
    assert refused(c.put(f"/notes/{note['id']}", json={"text": "", "lasts": "stays"}, headers=h)) == (422, "no_text")
    c.delete(f"/notes/{note['id']}", headers=h)
    assert refused(c.put(f"/notes/{note['id']}", json=body, headers=h)) == (409, "ended")


def test_a_note_taken_down_is_kept_and_shown_to_nobody():
    c, wall = hub()
    h = manager(c)
    note = put_up(c, "Out tonight: lobster")
    saw(c, "s1", note["id"])
    wall.now = at(19)
    down = c.delete(f"/notes/{note['id']}", headers=h)
    assert down.status_code == 200 and down.json()["removed_ms"] == at(19) and down.json()["removed_by"] == "Mike"
    assert mine(c, "s2") == {"notes": [], "unseen": 0, "now_ms": at(19)}

    told = board(c)
    assert told["notes"] == []
    assert [(n["text"], n["ended_ms"], n["removed_by"], n["seen_count"]) for n in told["earlier"]] == [
        ("Out tonight: lobster", at(19), "Mike", 2)  # Mike, who wrote it, and Amy
    ]
    # taking it down again changes nothing, and one nobody wrote is not there
    wall.now = at(20)
    assert c.delete(f"/notes/{note['id']}", headers=h).json()["removed_ms"] == at(19)
    assert refused(c.delete("/notes/none", headers=h)) == (404, "unknown_note")


def test_twelve_notes_at_most_are_up_at_once():
    c, _ = hub()
    h = manager(c)
    ids = [put_up(c, f"Note {n}")["id"] for n in range(MOST_NOTES)]
    assert refused(c.post("/notes", json={"text": "One more", "lasts": "tonight"}, headers=h)) == (409, "too_many")
    c.delete(f"/notes/{ids[0]}", headers=h)
    assert put_up(c, "One more")["text"] == "One more"
    assert len(mine(c)["notes"]) == MOST_NOTES == board(c)["most"]


def test_the_managers_list_says_who_has_seen_each_note_and_who_has_not():
    c, wall = hub()
    note = put_up(c, "Out tonight: lobster")
    wall.now = at(16, 30)
    saw(c, "s2", note["id"])
    wall.now = at(16, 10)  # a hub whose clock was set back: the order is by when each saw it
    saw(c, "s1", note["id"], "no-such-note")
    wall.now = at(17)
    saw(c, "s2", note["id"])  # seeing it again keeps the first time

    told = board(c)
    assert told["staff"] == 4 and told["text_max"] == TEXT_MAX and told["earlier"] == []
    (row,) = told["notes"]
    assert [(s["name"], s["at_ms"]) for s in row["seen"]] == [
        ("Mike", at(16)),
        ("Amy", at(16, 10)),
        ("Ben", at(16, 30)),
    ]
    assert row["waiting"] == ["Holly"]


def test_the_screens_are_told_when_the_notes_change():
    c, _ = hub()
    h = manager(c)
    said: list[str] = []
    c.app.state.feed.changed = said.append
    note = put_up(c)
    c.put(f"/notes/{note['id']}", json={"text": "Out: lobster, crab", "lasts": "tonight"}, headers=h)
    c.delete(f"/notes/{note['id']}", headers=h)
    assert said == ["notes", "notes", "notes"]
    # what is refused, and somebody having seen a note, tells nobody
    c.post("/notes", json={"text": "", "lasts": "tonight"}, headers=h)
    saw(c, "s1", note["id"])
    c.post("/logbook", json={"subject": "bar", "text": "Keg changed"}, headers=h)
    assert said == ["notes", "notes", "notes"]


# The manager's log -----------------------------------------------------------------------------------------


def write(c: TestClient, subject: str, text: str) -> dict:
    r = c.post("/logbook", json={"subject": subject, "text": text, "device": "office"}, headers=manager(c))
    assert r.status_code == 200, r.text
    return r.json()


def log(c: TestClient, **params) -> dict:
    r = c.get("/logbook", params=params, headers=manager(c))
    assert r.status_code == 200, r.text
    return r.json()


def counts(told: dict) -> dict[str, int]:
    return {s["id"]: s["count"] for s in told["subjects"] if s["count"]}


def test_a_manager_writes_in_the_log_under_a_subject():
    c, wall = hub(at(22))
    first = write(c, "repairs", "Walk-in cooler read 45F at close.\nCalled Tom, he comes Tuesday.")
    assert first["subject_name"] == "Repairs" and first["by"] == "Mike" and first["at_ms"] == at(22)
    assert first["day"] == "2026-11-16" and first["struck_ms"] is None
    wall.now = at(0, 40, day=17)
    second = write(c, "guests", "Table 12 waited 40 minutes for the duck. Took the dessert off.")
    assert second["day"] == "2026-11-16"  # after midnight it is still that night's entry

    told = log(c)
    assert [s["name"] for s in told["subjects"]] == [name for _, name in SUBJECTS]
    assert counts(told) == {"guests": 1, "repairs": 1} and told["count"] == 2
    assert [e["id"] for e in told["entries"]] == [second["id"], first["id"]]  # the newest first
    assert told["more"] is False and told["text_max"] == LOG_TEXT_MAX


def test_the_log_is_the_managers_own():
    c, _ = hub()
    entry = write(c, "staff", "Ben came in 30 minutes late.")
    body = {"subject": "staff", "text": "Nothing"}
    for headers, status, code in (({}, 401, "sign_in"), (server(c), 403, "not_allowed")):
        assert refused(c.get("/logbook", headers=headers)) == (status, code)
        assert refused(c.post("/logbook", json=body, headers=headers)) == (status, code)
        assert refused(c.post(f"/logbook/{entry['id']}/strike", headers=headers)) == (status, code)
    assert log(c)["count"] == 1


def test_an_entry_needs_a_subject_of_the_list_and_words():
    c, _ = hub()
    h = manager(c)
    assert refused(c.post("/logbook", json={"subject": "gossip", "text": "x"}, headers=h)) == (422, "bad_subject")
    assert refused(c.post("/logbook", json={"subject": "bar", "text": " \n"}, headers=h)) == (422, "no_text")
    long = "x" * (LOG_TEXT_MAX + 1)
    assert refused(c.post("/logbook", json={"subject": "bar", "text": long}, headers=h)) == (422, "long_text")
    assert refused(c.get("/logbook", params={"subject": "gossip"}, headers=h)) == (422, "bad_subject")
    assert log(c)["entries"] == []
    assert write(c, "bar", "z" * LOG_TEXT_MAX)["text"] == "z" * LOG_TEXT_MAX


def test_the_log_is_read_by_subject_and_searched():
    c, wall = hub()
    write(c, "repairs", "Walk-in cooler read 45F. Called Tom.")
    wall.now += MINUTE
    write(c, "deliveries", "Fish order came 2 cases short of salmon. 100% credited.")
    wall.now += MINUTE
    write(c, "repairs", "Tom fixed the cooler: a fan belt.")
    wall.now += MINUTE
    write(c, "staff", "Holly covers Saturday for Amy.")

    told = log(c, subject="repairs")
    assert [e["text"][:10] for e in told["entries"]] == ["Tom fixed ", "Walk-in co"]
    assert counts(told) == {"repairs": 2, "deliveries": 1, "staff": 1}  # the chips count every subject

    # every word, in any order and any case, in the entry or in who wrote it
    assert [e["text"][:10] for e in log(c, q="COOLER tom")["entries"]] == ["Tom fixed ", "Walk-in co"]
    assert counts(log(c, q="cooler tom")) == {"repairs": 2}
    assert [e["text"][:10] for e in log(c, q="cooler", subject="staff")["entries"]] == []
    assert log(c, q="mike")["count"] == 4
    assert log(c, q="lobster")["entries"] == []
    # a sign that means "anything" to a database is only itself here
    assert [e["subject"] for e in log(c, q="100%")["entries"]] == ["deliveries"]
    assert log(c, q="1_0")["entries"] == []


def test_the_log_is_read_a_page_at_a_time():
    c, _ = hub()
    ids = []
    for n in range(5):
        ids.append(write(c, "kitchen", f"Entry {n}")["id"])  # all in the same millisecond: the order still holds
    first = log(c, limit=2)
    assert [e["text"] for e in first["entries"]] == ["Entry 4", "Entry 3"] and first["more"] is True
    second = log(c, limit=2, before=first["entries"][-1]["id"])
    assert [e["text"] for e in second["entries"]] == ["Entry 2", "Entry 1"] and second["more"] is True
    last = log(c, limit=2, before=second["entries"][-1]["id"])
    assert [e["text"] for e in last["entries"]] == ["Entry 0"] and last["more"] is False
    assert log(c, limit=2, before=ids[0])["entries"] == []
    assert log(c, before="no-such-entry")["entries"] == []


def test_an_entry_is_struck_out_never_deleted():
    c, wall = hub(at(22))
    h = manager(c)
    wrong = write(c, "money", "Deposit was 20 short.")
    write(c, "money", "Deposit matched.")
    wall.now = at(22, 30)
    struck = c.post(f"/logbook/{wrong['id']}/strike", headers=h)
    assert struck.status_code == 200
    assert (struck.json()["struck_ms"], struck.json()["struck_by"]) == (at(22, 30), "Mike")

    told = log(c)
    assert counts(told) == {"money": 1}  # it is not counted
    assert [(e["text"], e["struck_ms"]) for e in told["entries"]] == [
        ("Deposit matched.", None),
        ("Deposit was 20 short.", at(22, 30)),  # and is still there to read, and to find
    ]
    assert [e["id"] for e in log(c, q="short")["entries"]] == [wrong["id"]]
    wall.now = at(23)
    assert c.post(f"/logbook/{wrong['id']}/strike", headers=h).json()["struck_ms"] == at(22, 30)
    assert refused(c.post("/logbook/none/strike", headers=h)) == (404, "unknown_entry")
    # nothing takes an entry out or rewrites one
    assert c.delete(f"/logbook/{wrong['id']}", headers=h).status_code in (404, 405)
    assert c.put(f"/logbook/{wrong['id']}", json={"subject": "money", "text": "x"}, headers=h).status_code in (
        404,
        405,
    )


def test_the_rules_hold_without_the_wire():
    notes, wall = notes_at(at(16))
    with pytest.raises(Refused) as err:
        notes.write(None, "tonight", by_id="s3", by="Mike")
    assert err.value.code == "no_text"
    note = notes.write("Rush on wok 2", "tonight", by_id="s3", by="Mike")
    assert notes.change(note.note_id, "Rush on wok 2", "tonight", by_id="s3", by="Mike") == note
    assert notes.for_staff("s1")["unseen"] == 1
    assert notes.board(STAFF)["notes"][0]["waiting"] == ["Amy", "Ben", "Holly"]
    # somebody who has left is not listed among those who saw it
    notes.saw("s9", [note.note_id])
    assert [s["name"] for s in notes.board(STAFF)["notes"][0]["seen"]] == ["Mike"]


# PostgreSQL ------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_the_notes_and_the_log_are_kept_in_postgres():
    import psycopg

    from pos.notes import PgNoteStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS shift_note")
        conn.execute("DROP TABLE IF EXISTS shift_note_seen")
        conn.execute("DROP TABLE IF EXISTS manager_log")
    store = PgNoteStore(DSN)
    try:
        notes, wall = notes_at(at(16), store)
        tonight = notes.write("Out tonight: lobster", "tonight", by_id="s3", by="Mike")
        wall.now = at(16, 1)
        notes.write("Staff meeting Saturday at 3", "stays", by_id="s3", by="Mike")
        wall.now = at(16, 10)
        assert notes.saw("s1", [tonight.note_id, "no-such-note"])["unseen"] == 1
        wall.now = at(17)
        notes.saw("s1", [tonight.note_id])  # again: the first time stays
        gone = notes.write("Wrong note", "tonight", by_id="s3", by="Mike")
        notes.take_down(gone.note_id, by="Mike")
        first = notes.log_write("repairs", "Walk-in cooler read 45F. Called Tom.", by_id="s3", by="Mike")
        notes.log_write("deliveries", "Salmon 2 cases short. 100% credited.", by_id="s3", by="Mike", device="office")
        wrong = notes.log_write("repairs", "Tom fixed the freezer", by_id="s3", by="Mike")
        notes.log_strike(wrong.entry_id, by="Mike")

        again = PgNoteStore(DSN)  # another process: the hub after a restart
        try:
            later, wall2 = notes_at(at(18), again)
            told = later.for_staff("s1")
            assert [(n["text"], n["seen"]) for n in told["notes"]] == [
                ("Staff meeting Saturday at 3", False),
                ("Out tonight: lobster", True),
            ]
            seen = later.board(STAFF)
            assert [(n["text"], [(s["name"], s["at_ms"]) for s in n["seen"]], n["waiting"]) for n in seen["notes"]] == [
                ("Staff meeting Saturday at 3", [("Mike", at(16, 1))], ["Amy", "Ben", "Holly"]),
                ("Out tonight: lobster", [("Mike", at(16)), ("Amy", at(16, 10))], ["Ben", "Holly"]),
            ]
            assert [(n["text"], n["removed_by"]) for n in seen["earlier"]] == [("Wrong note", "Mike")]

            # new words show it again; only the manager who wrote them has seen it
            changed = later.change(tonight.note_id, "Out tonight: lobster, crab", "tonight", by_id="s3", by="Mike")
            assert changed.edited_ms == at(18) and changed.at_ms == at(16)
            assert later.for_staff("s1")["unseen"] == 2 and later.for_staff("s3")["unseen"] == 0

            # the night ends: tonight's note is among the earlier ones, the other stays up
            wall2.now = at(4, day=17)
            assert [n["text"] for n in later.for_staff("s1")["notes"]] == ["Staff meeting Saturday at 3"]
            earlier = later.board(STAFF)["earlier"]
            assert [(n["text"], n["ended_ms"]) for n in earlier] == [
                ("Out tonight: lobster, crab", at(4, day=17)),
                ("Wrong note", at(17)),
            ]
            wall2.now = at(17, 1) + 14 * DAY
            assert [n["text"] for n in later.board(STAFF)["earlier"]] == ["Out tonight: lobster, crab"]
            wall2.now = at(4, 1, day=17) + 14 * DAY
            assert later.board(STAFF)["earlier"] == []
            with pytest.raises(Refused) as err:
                later.change(tonight.note_id, "Too late", "tonight", by_id="s3", by="Mike")
            assert err.value.code == "ended"

            # the log: counts without the struck entry, a search, a subject, a page at a time
            read = later.log_read()
            assert {s["id"]: s["count"] for s in read["subjects"] if s["count"]} == {"repairs": 1, "deliveries": 1}
            assert [(e["text"][:9], e["struck_by"]) for e in read["entries"]] == [
                ("Tom fixed", "Mike"),
                ("Salmon 2 ", ""),
                ("Walk-in c", ""),
            ]
            assert [e["id"] for e in later.log_read(q="TOM cooler")["entries"]] == [first.entry_id]
            assert [e["subject"] for e in later.log_read(q="100%")["entries"]] == ["deliveries"]
            assert later.log_read(q="1_0")["entries"] == []
            assert later.log_read(q="mike")["count"] == 2
            assert [e["text"][:9] for e in later.log_read(subject="repairs")["entries"]] == ["Tom fixed", "Walk-in c"]
            page = later.log_read(limit=2)
            assert page["more"] is True and len(page["entries"]) == 2
            rest = later.log_read(limit=2, before=page["entries"][-1]["id"])
            assert [e["id"] for e in rest["entries"]] == [first.entry_id] and rest["more"] is False
            assert later.log_read(before="no-such-entry")["entries"] == []
            assert later.log_strike(wrong.entry_id, by="Amy").struck_by == "Mike"  # struck once
        finally:
            again.close()
    finally:
        store.close()
        with psycopg.connect(DSN) as conn:
            conn.execute("DROP TABLE IF EXISTS shift_note")
            conn.execute("DROP TABLE IF EXISTS shift_note_seen")
            conn.execute("DROP TABLE IF EXISTS manager_log")
