"""The waitlist on the wire. The rules live in `pos.waitlist`; these are the calls.

- `GET /waitlist`: tonight's list. `waiting` are the parties still waiting, in the order they came, each with
  `id`, `name`, `size`, `phone`, `quoted_minutes` (null: no time was given), `note`, `at_ms`, `by`,
  `called_ms`, and the moments its wait changes colour: `amber_ms` and `due_ms` (red). `earlier` are the ones
  that went off the list tonight, the last to go first, with `status` (`seated` or `left`), `table`,
  `table_label`, `order_id`, `left_why`, `ended_by` and `waited_minutes`. `counts` has how many parties and
  guests wait, how many were seated or left, and the `average_wait_minutes` of the seated. `quotes` are the
  waits to offer as buttons. Every stamp is the hub's clock; the answer does not say what time it is now, so
  a list nobody changed reads as unchanged (304).
- `GET /waitlist/suggest`: the wait to tell a party that comes now (`pos.waitlist.suggestions`). `suggest` has
  a row for each band of sizes tonight's list says enough about: `from` and `to` (guests), `minutes` (the
  wait to mark, one of `quotes`), `about_minutes`, `by` (`pace` or `longest`), `ahead`, `each_minutes`,
  `longest_minutes`, `seated` and `like`. It reads the clock, names nobody and changes nothing; a screen
  asks it when a party is being added.
- `POST /waitlist` `{staff_id, name, size, phone, quoted_minutes, note}`: puts a party on the list.
  409 `too_many` past sixty waiting.
- `PUT /waitlist/{id}` (the same body): puts right what a waiting party told the host.
- `POST /waitlist/{id}/called` `{staff_id, on}`: the party was told its table is ready (or `on: false`).
- `POST /waitlist/{id}/seat` `{staff_id, table, order_id}`: the party sat down at that table; `order_id` is the
  check opened for it. 404 `unknown_table` for a table the floor plan does not have.
- `POST /waitlist/{id}/left` `{staff_id, why}`: it went off the list without a table (`left` or `no_show`).
- `POST /waitlist/{id}/back` `{staff_id}`: it is put back where it stood.

Staff have no token: a screen passes who is signed in, as it does for the notes for the shift. Anyone signed
in can keep the list (404 `unknown_staff` for an id the hub does not know). Every change answers with the list
as it stands now and the `party` that changed, and tells the screens on the change feed (`waitlist`).

A party that is not waiting any more answers 409 `not_waiting`; one that is not on tonight's list 404
`unknown_party`.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from ..floor import FloorPlan
from ..identity.staff import Directory, Staff
from ..waitlist import Party, ReadOnlyError, Refused, Waitlist


class WhoIn(BaseModel):
    staff_id: str = Field(max_length=120)


class PartyIn(WhoIn):
    name: str = Field(max_length=200)
    size: int
    phone: str = Field("", max_length=200)
    quoted_minutes: int | None = None
    note: str = Field("", max_length=400)


class CalledIn(WhoIn):
    on: bool = True


class SeatIn(WhoIn):
    table: str = Field(max_length=80)
    order_id: str = Field("", max_length=80)


class LeftIn(WhoIn):
    why: str = Field("left", max_length=40)


def add_waitlist(app: FastAPI) -> None:
    def waitlist() -> Waitlist:
        return app.state.waitlist

    def known(staff_id: str) -> Staff:
        directory: Directory = app.state.staff
        staff = directory.get(staff_id)
        if staff is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        return staff

    def refused(err: Refused) -> HTTPException:
        status = 404 if err.code.startswith("unknown_") else 409 if err.code in ("too_many", "not_waiting") else 422
        return HTTPException(status, {"error": err.code, "message": err.message})

    def done(change: Any) -> dict[str, Any]:
        """Makes a change, tells the screens, and answers with the list as it stands and the party changed."""
        try:
            party: Party = change()
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("waitlist")
        return {**waitlist().tonight(), "party": party.as_json()}

    @app.get("/waitlist")
    def read_waitlist() -> dict[str, Any]:
        """Tonight's waitlist: who is waiting, in the order they came, and who went off it earlier."""
        return waitlist().tonight()

    @app.get("/waitlist/suggest")
    def suggest_wait() -> dict[str, Any]:
        """The wait to tell a party that comes now, by how many they are, from how tonight's parties waited."""
        return waitlist().suggest()

    @app.post("/waitlist")
    def add_party(body: PartyIn) -> dict[str, Any]:
        """A party is put on the list, behind the ones already waiting."""
        staff = known(body.staff_id)
        return done(
            lambda: waitlist().add(
                body.name,
                body.size,
                phone=body.phone,
                quoted_minutes=body.quoted_minutes,
                note=body.note,
                by_id=staff.staff_id,
                by=staff.name,
            )
        )

    @app.put("/waitlist/{party_id}")
    def change_party(party_id: str, body: PartyIn) -> dict[str, Any]:
        """What a waiting party told the host is put right. Its place on the list stays."""
        known(body.staff_id)
        return done(
            lambda: waitlist().change(
                party_id, body.name, body.size, phone=body.phone, quoted_minutes=body.quoted_minutes, note=body.note
            )
        )

    @app.post("/waitlist/{party_id}/called")
    def call_party(party_id: str, body: CalledIn) -> dict[str, Any]:
        """The party was told its table is ready, or was not after all."""
        known(body.staff_id)
        return done(lambda: waitlist().call(party_id, body.on))

    @app.post("/waitlist/{party_id}/seat")
    def seat_party(party_id: str, body: SeatIn) -> dict[str, Any]:
        """The party sat down at a table of the floor plan."""
        staff = known(body.staff_id)
        plan: FloorPlan = app.state.floor
        table = plan.table(body.table)
        if table is None:
            raise HTTPException(404, {"error": "unknown_table", "message": "The floor plan has no such table."})
        return done(
            lambda: waitlist().seat(party_id, table.id, table_label=table.label, order_id=body.order_id, by=staff.name)
        )

    @app.post("/waitlist/{party_id}/left")
    def party_left(party_id: str, body: LeftIn) -> dict[str, Any]:
        """The party went off the list without a table: it left, or it did not show when called."""
        staff = known(body.staff_id)
        return done(lambda: waitlist().leave(party_id, body.why, by=staff.name))

    @app.post("/waitlist/{party_id}/back")
    def party_back(party_id: str, body: WhoIn) -> dict[str, Any]:
        """A party that went off the list tonight is put back where it stood."""
        known(body.staff_id)
        return done(lambda: waitlist().back(party_id))
