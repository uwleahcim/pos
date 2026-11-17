"""Notes for the shift and the manager's log on the wire. The rules live in `pos.notes`; these are the calls.

Notes for the shift:

- `GET /notes?staff_id=s1`: the notes that are up, the newest first, each with `id`, `text`, `by`, `at_ms`,
  `until_ms` (null: until taken down), `lasts` (`tonight` or `stays`), `edited_ms` and whether this person
  has `seen` it; `unseen` counts the ones they have not. Staff have no token: a screen passes who is signed
  in, as it does for their display settings. 404 `unknown_staff` for an id the hub does not know.
- `POST /notes/seen` `{staff_id, note_ids}`: this person has seen these; the answer is `GET /notes` again.
- `GET /notes/board` (manager token): the notes that are up, each with who has `seen` it (`staff_id`,
  `name`, `at_ms`) and who is `waiting`, and the `earlier` ones that came down in the last two weeks.
- `POST /notes` `{text, lasts}` (manager token): puts a note up. 409 `too_many` past twelve at once.
- `PUT /notes/{id}` `{text, lasts}` (manager token): changes one that is up; new words show it to everybody
  again. 409 `ended` for one that has come down.
- `DELETE /notes/{id}` (manager token): takes one down. It is kept.

The manager's log (all with a manager token):

- `GET /logbook?subject=&q=&before=&limit=`: the entries, the newest first, with the `subjects` and how
  many entries each has. `subject` narrows to one, `q` to the entries holding every word of it, `before`
  (an entry's id) reads the page before; `more` says there is one.
- `POST /logbook` `{subject, text, device}`: writes an entry.
- `POST /logbook/{id}/strike`: strikes one out. Nothing in the log is changed or deleted.

A change to the notes tells the screens on the change feed (`notes`), so a note written in the middle of
service reaches the people already signed in.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from ..identity.staff import Directory
from ..identity.tokens import Grant
from ..notes import ReadOnlyError, Refused, ShiftNotes
from .auth import manager_from


class NoteIn(BaseModel):
    text: str
    lasts: str = "tonight"


class SeenIn(BaseModel):
    staff_id: str
    note_ids: list[str] = Field(default_factory=list, max_length=100)


class EntryIn(BaseModel):
    subject: str
    text: str
    device: str = ""


def add_shift_notes(app: FastAPI) -> None:
    def notes() -> ShiftNotes:
        return app.state.notes

    def manager(authorization: str | None) -> Grant:
        return manager_from(app.state.tokens, authorization)

    def refused(err: Refused) -> HTTPException:
        status = 404 if err.code.startswith("unknown_") else 409 if err.code in ("too_many", "ended") else 422
        return HTTPException(status, {"error": err.code, "message": err.message})

    def known(staff_id: str) -> str:
        directory: Directory = app.state.staff
        if directory.get(staff_id) is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        return staff_id

    def staff() -> list[tuple[str, str]]:
        directory: Directory = app.state.staff
        return [(s.staff_id, s.name) for s in directory.all()]

    def told() -> None:
        app.state.feed.changed("notes")

    @app.get("/notes")
    def read_notes(staff_id: str = Query(..., max_length=120)) -> dict[str, Any]:
        """The notes that are up, each with whether this person has seen it."""
        return notes().for_staff(known(staff_id))

    @app.post("/notes/seen")
    def see_notes(body: SeenIn) -> dict[str, Any]:
        """This person has seen these notes: they are not shown them again."""
        try:
            return notes().saw(known(body.staff_id), body.note_ids)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err

    @app.get("/notes/board")
    def read_board(authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager's list of the notes: who has seen each one that is up, and the ones that came down."""
        manager(authorization)
        return notes().board(staff())

    @app.post("/notes")
    def write_note(body: NoteIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager puts a note up for everybody to see once."""
        grant = manager(authorization)
        try:
            note = notes().write(body.text, body.lasts, by_id=grant.staff_id, by=grant.name)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        told()
        return note.as_json()

    @app.put("/notes/{note_id}")
    def change_note(note_id: str, body: NoteIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager changes a note that is up. New words show it to everybody again."""
        grant = manager(authorization)
        try:
            note = notes().change(note_id, body.text, body.lasts, by_id=grant.staff_id, by=grant.name)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        told()
        return note.as_json()

    @app.delete("/notes/{note_id}")
    def take_note_down(note_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager takes a note down. It is kept, and nobody is shown it any more."""
        grant = manager(authorization)
        try:
            note = notes().take_down(note_id, by=grant.name)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        told()
        return {**note.as_json(), "removed_ms": note.removed_ms, "removed_by": note.removed_by}

    @app.get("/logbook")
    def read_log(
        subject: str | None = Query(None, max_length=40),
        q: str = Query("", max_length=120),
        before: str | None = Query(None, max_length=64),
        limit: int = Query(50, ge=1, le=200),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """The manager's log, the newest entry first, by subject, with a search."""
        manager(authorization)
        try:
            return notes().log_read(subject=subject or None, q=q, before=before or None, limit=limit)
        except Refused as err:
            raise refused(err) from err

    @app.post("/logbook")
    def write_entry(body: EntryIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager writes an entry in the log."""
        grant = manager(authorization)
        try:
            entry = notes().log_write(body.subject, body.text, by_id=grant.staff_id, by=grant.name, device=body.device)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return entry.as_json()

    @app.post("/logbook/{entry_id}/strike")
    def strike_entry(entry_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager strikes an entry out. It stays in the log, readable."""
        grant = manager(authorization)
        try:
            entry = notes().log_strike(entry_id, by=grant.name)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return entry.as_json()
