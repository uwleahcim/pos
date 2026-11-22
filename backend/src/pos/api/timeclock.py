"""The time clock on the wire. The rules live in `pos.timeclock`; this is the shape of the calls.

- `GET /settings/time_clock`, `PUT /settings/time_clock` `{enabled, breaks_paid, week_starts}` (manager
  token): whether the location uses the clock, whether a break counts as time worked, and the day the pay
  week starts on.
- `POST /timeclock/punch` `{device, pin | tag_uid, action, punch_id}`: a person at the clock, known by
  their own PIN or tag exactly as at sign-in (and locked out the same way after too many wrong PINs).
  `action` is `state` (only look), `in`, `out`, `break_start` or `break_end`. The answer says who it is in
  the shape `POST /signin` gives, so the screen can go on into the POS without asking the PIN twice, and
  where they stand now: `state` (`out`, `in`, `break`), `since_ms`, the hub's `now_ms`, their `shift`, and
  `unended`, a shift of theirs nobody clocked out of. 409 `off` while the location does not use the clock,
  409 with the reason when the punch does not fit (`already_in`, `not_in`, `on_break`, `not_on_break`).
- `GET /timeclock/report?since=<ms>&until=<ms>` (manager token): the shifts that began in that time, each
  with its log, the hours of each person, and who is on the clock now.
- `POST /timeclock/shifts` `{staff_id, in_ms, out_ms, breaks, reason, device}` (manager token): a shift
  written in for somebody who never clocked in.
- `PUT /timeclock/shifts/{id}` `{in_ms, out_ms, breaks, reason, device}` (manager token): a correction; the
  whole of the shift's times as they should be. The log keeps what they were, who changed them and why.
- `DELETE /timeclock/shifts/{id}?reason=...` (manager token): takes a shift off; it is kept, marked.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from ..identity.staff import Directory, Locked, SignIn
from ..identity.tags import sign_in_by_tag
from ..identity.tokens import Grant
from ..settings import SettingStore
from ..timeclock import PUNCHES, ReadOnlyError, Refused, Shift, TimeClock
from .auth import holder_from

WINDOW_MAX_MS = 400 * 86_400_000
"""The longest stretch one report reads: a little over a year."""


class PunchIn(BaseModel):
    device: str
    pin: str | None = None
    tag_uid: str | None = None
    action: str = "state"
    punch_id: str | None = Field(None, max_length=64, description="names the punch: sent twice, it counts once")


class BreakIn(BaseModel):
    start_ms: int
    end_ms: int | None = None


class ShiftIn(BaseModel):
    """A shift's times as a manager wants them, and why."""

    in_ms: int
    out_ms: int | None = None
    breaks: list[BreakIn] = Field(default_factory=list)
    reason: str = ""
    device: str = ""


class NewShiftIn(ShiftIn):
    staff_id: str


def add_time_clock(app: FastAPI) -> None:
    def clock() -> TimeClock:
        return app.state.clock

    def setting() -> dict[str, Any]:
        settings: SettingStore = app.state.settings
        return settings.get("time_clock")

    def manager(authorization: str | None) -> Grant:
        return holder_from(app.state, authorization, "time_clock")

    def refused(err: Refused) -> HTTPException:
        status = 404 if err.code == "unknown_shift" else 422 if err.code.startswith("bad_") else 409
        return HTTPException(status, {"error": err.code, "message": err.message})

    def out(shift: Shift) -> dict[str, Any]:
        return shift.as_json(clock().now_ms(), breaks_paid=setting()["breaks_paid"])

    def told() -> None:
        """Who is on the clock changed, and with it who is in tonight's turn for a table (`pos.floor.turn`):
        the floor maps read again."""
        app.state.feed.changed("floor")

    def who(body: PunchIn) -> SignIn:
        """The person at the clock, by their own PIN or tag: the checks of `POST /signin`."""
        app.state.devices.heard(body.device)
        directory: Directory = app.state.staff
        try:
            if body.pin is not None:
                found = directory.by_pin(body.pin, device=body.device)
            elif body.tag_uid is not None:
                found = sign_in_by_tag(app.state.tags, directory, body.tag_uid, device=body.device)
            else:
                raise HTTPException(422, {"error": "no_credential"})
        except Locked as err:
            raise HTTPException(423, {"error": "locked", "seconds": round(err.seconds_left)}) from err
        if found is None:
            raise HTTPException(401, {"error": "unknown_credential"})
        return found

    @app.post("/timeclock/punch")
    def punch(body: PunchIn) -> dict[str, Any]:
        """A person at the clock: looks at where they stand (`state`), or clocks in or out, or starts or
        ends a break. The time is the hub's, taken when the punch arrives."""
        chosen = setting()
        if not chosen["enabled"]:
            raise HTTPException(409, {"error": "off", "message": "This location does not use the time clock"})
        if body.action != "state" and body.action not in PUNCHES:
            raise HTTPException(
                422, {"error": "bad_action", "message": f"{body.action!r} is not something the clock does"}
            )
        found = who(body)
        paid = chosen["breaks_paid"]
        try:
            if body.action == "state":
                stands = {**clock().state(found.staff_id, breaks_paid=paid), "punched": None}
            else:
                stands = clock().punch(
                    found.staff_id,
                    found.name,
                    found.role,
                    body.action,
                    device=body.device,
                    punch_id=body.punch_id,
                    breaks_paid=paid,
                )
                told()
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return {
            "staff": {
                "staff_id": found.staff_id,
                "name": found.name,
                "role": found.role,
                "method": found.method,
                "preferences": app.state.preferences.get(found.staff_id),
            },
            "breaks_paid": paid,
            **stands,
        }

    @app.get("/timeclock/report")
    def report(
        since: int = Query(..., ge=0, description="shifts that began at or after this wall-clock ms"),
        until: int = Query(..., ge=0, description="and before this one"),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """The hours for a stretch of time: every shift that began in it with its log, what each person
        worked, and who is on the clock now. A shift nobody ended counts to the hour the night ended, and
        is marked until a manager corrects it."""
        manager(authorization)
        if until <= since or until - since > WINDOW_MAX_MS:
            raise HTTPException(422, {"error": "bad_window", "message": "until is after since, by a year at most"})
        chosen = setting()
        return {
            **clock().report(since, until, breaks_paid=chosen["breaks_paid"]),
            "enabled": chosen["enabled"],
            "week_starts": chosen["week_starts"],
        }

    @app.post("/timeclock/shifts")
    def add_shift(body: NewShiftIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager writes a shift in for somebody who never clocked in. With no `out_ms` the person is on
        the clock from `in_ms`."""
        grant = manager(authorization)
        directory: Directory = app.state.staff
        person = directory.get(body.staff_id)
        if person is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody on the staff has that id"})
        try:
            shift = clock().add(
                person.staff_id,
                person.name,
                person.role,
                in_ms=body.in_ms,
                out_ms=body.out_ms,
                breaks=[b.model_dump() for b in body.breaks],
                reason=body.reason,
                by_id=grant.staff_id,
                by=grant.name,
                device=body.device,
            )
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        told()
        return out(shift)

    @app.put("/timeclock/shifts/{shift_id}")
    def edit_shift(shift_id: str, body: ShiftIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager's correction: the shift's times as they should be, all of them, and why."""
        grant = manager(authorization)
        try:
            shift = clock().edit(
                shift_id,
                in_ms=body.in_ms,
                out_ms=body.out_ms,
                breaks=[b.model_dump() for b in body.breaks],
                reason=body.reason,
                by_id=grant.staff_id,
                by=grant.name,
                device=body.device,
            )
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        told()
        return out(shift)

    @app.delete("/timeclock/shifts/{shift_id}")
    def remove_shift(
        shift_id: str,
        reason: str = Query("", description="why: the log keeps it"),
        device: str = Query(""),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """A manager takes a shift off (a punch made by mistake). It stays in the report, marked, and counts
        for nothing."""
        grant = manager(authorization)
        try:
            shift = clock().remove(shift_id, reason=reason, by_id=grant.staff_id, by=grant.name, device=device)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        told()
        return out(shift)
