"""The reservation book on the wire. The rules live in `pos.reservations`; these are the calls.

- `GET /reservations?day=2026-11-21`: a day's book (today's without `day`). `booked` are the reservations
  still standing, in the order of their times, each with `id`, `name`, `size`, `phone`, `note`, `at_ms`,
  `day`, `time` ("18:30" on the restaurant's clock), `table` and `table_label` (the table held, or empty),
  `by`, `arrived_ms` (the party is here and waits), `soon_ms` and `late_ms` (when its time is near, and
  when it is past with nobody seated), and `clash` (another reservation holding the same table within
  `hold_minutes`, or null). `earlier` are the ones that ended, the last first, with `status` (`seated`,
  `cancelled` or `no_show`), `seated_table`, `seated_label`, `order_id` and `ended_by`. `counts` adds the
  day up, and `ahead` lists every day from `today` on with a reservation standing (`parties`, `guests`).
  The answer does not say what time it is, so a book nobody changed reads as unchanged (304).
- `POST /reservations` `{staff_id, name, size, day, time, phone, note, table}`: books a table. 422
  `past_day` for a day that is over, `too_far` past a year ahead.
- `PUT /reservations/{id}` (the same body): puts a standing reservation right.
- `POST /reservations/{id}/arrived` `{staff_id, on}`: the party is here and waits (or `on: false`).
- `POST /reservations/{id}/seat` `{staff_id, table, order_id}`: the party sat down at that table;
  `order_id` is the check opened for it.
- `POST /reservations/{id}/cancel` `{staff_id, why}`: it ended without a table (`cancelled` or `no_show`).
- `POST /reservations/{id}/back` `{staff_id}`: it stands in the book again.

Staff have no token: a screen passes who is signed in, as it does for the waitlist. Anyone signed in keeps
the book (404 `unknown_staff` for an id the hub does not know). Every change answers with the book of the
reservation's day as it stands now and the `booking` that changed, and tells the screens on the change feed
(`reservations`).

The floor map reads the tables held today with the floor itself (`holds` of `GET /floor`), and reads it again
when the feed says `reservations`.

404 `unknown_booking`, `unknown_table`; 409 `not_booked` (it sat down or was taken out; put it back first),
`not_today` (seating, here and no-show are for today's reservations), `day_over`, `too_many`.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from ..floor import FloorPlan
from ..identity.staff import Directory, Staff
from ..reservations import Booking, ReadOnlyError, Refused, Reservations, day_of


class WhoIn(BaseModel):
    staff_id: str = Field(max_length=120)


class BookingIn(WhoIn):
    name: str = Field(max_length=200)
    size: int
    day: str = Field(max_length=40)
    time: str = Field(max_length=40)
    phone: str = Field("", max_length=200)
    note: str = Field("", max_length=400)
    table: str = Field("", max_length=80)


class ArrivedIn(WhoIn):
    on: bool = True


class SeatIn(WhoIn):
    table: str = Field(max_length=80)
    order_id: str = Field("", max_length=80)


class CancelIn(WhoIn):
    why: str = Field("cancelled", max_length=40)


def add_reservations(app: FastAPI) -> None:
    def book() -> Reservations:
        return app.state.reservations

    def known(staff_id: str) -> Staff:
        directory: Directory = app.state.staff
        staff = directory.get(staff_id)
        if staff is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        return staff

    def refused(err: Refused) -> HTTPException:
        status = (
            404
            if err.code.startswith("unknown_")
            else 409
            if err.code in ("too_many", "not_booked", "not_today", "day_over")
            else 422
        )
        return HTTPException(status, {"error": err.code, "message": err.message})

    def held(table_id: str) -> tuple[str, str]:
        """The table a reservation holds, as the floor plan has it; none when it holds none."""
        if not table_id:
            return "", ""
        plan: FloorPlan = app.state.floor
        table = plan.table(table_id)
        if table is None:
            raise HTTPException(404, {"error": "unknown_table", "message": "The floor plan has no such table."})
        return table.id, table.label

    def done(change: Any) -> dict[str, Any]:
        """Makes a change, tells the screens, and answers with the book of that day and the reservation
        changed."""
        try:
            booking: Booking = change()
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("reservations")
        return book().book(booking.day, changed=booking)

    @app.get("/reservations")
    def read_reservations(day: str | None = None) -> dict[str, Any]:
        """A day's reservations (today's without `day`), and the days ahead that have any."""
        try:
            return book().book(None if day is None else day_of(day))
        except Refused as err:
            raise refused(err) from err

    @app.post("/reservations")
    def add_booking(body: BookingIn) -> dict[str, Any]:
        """A table is booked for a day and a time."""
        staff = known(body.staff_id)
        table, label = held(body.table)
        return done(
            lambda: book().add(
                body.name,
                body.size,
                body.day,
                body.time,
                phone=body.phone,
                note=body.note,
                table=table,
                table_label=label,
                by_id=staff.staff_id,
                by=staff.name,
            )
        )

    @app.put("/reservations/{booking_id}")
    def change_booking(booking_id: str, body: BookingIn) -> dict[str, Any]:
        """A standing reservation is put right."""
        known(body.staff_id)
        table, label = held(body.table)
        return done(
            lambda: book().change(
                booking_id,
                body.name,
                body.size,
                body.day,
                body.time,
                phone=body.phone,
                note=body.note,
                table=table,
                table_label=label,
            )
        )

    @app.post("/reservations/{booking_id}/arrived")
    def booking_arrived(booking_id: str, body: ArrivedIn) -> dict[str, Any]:
        """The party is here and waits for its table, or is not after all."""
        known(body.staff_id)
        return done(lambda: book().arrive(booking_id, body.on))

    @app.post("/reservations/{booking_id}/seat")
    def seat_booking(booking_id: str, body: SeatIn) -> dict[str, Any]:
        """The party sat down at a table of the floor plan."""
        staff = known(body.staff_id)
        table, label = held(body.table)
        return done(lambda: book().seat(booking_id, table, table_label=label, order_id=body.order_id, by=staff.name))

    @app.post("/reservations/{booking_id}/cancel")
    def cancel_booking(booking_id: str, body: CancelIn) -> dict[str, Any]:
        """The reservation ended without a table: it was called off, or nobody came."""
        staff = known(body.staff_id)
        return done(lambda: book().cancel(booking_id, body.why, by=staff.name))

    @app.post("/reservations/{booking_id}/back")
    def booking_back(booking_id: str, body: WhoIn) -> dict[str, Any]:
        """A reservation that ended stands in the book again."""
        known(body.staff_id)
        return done(lambda: book().back(booking_id))
