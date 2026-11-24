"""The staff list on the wire. What is kept and the rules are `pos.identity.staff_list`; these are the calls
(docs/staff.md).

Every call is a manager's or an owner's (the token from `/admin/session`): no setting hands them out.

- `GET /hub/staff`: everybody on the staff: `staff`, each with `staff_id`, `name`, `role`, whether that is
  the person asking (`you`), where their PIN is from and who set it when (`pin`: `from` is `demo` for the
  demo staff's, which are in the guide, `hub` for the hub's own file, `app`, `terminal` for `hubctl staff
  pin`; `by`; `at_ms`), and what the person asking may do to them (`can`: `change`, `role`, `remove`, and
  `why` not: `owner_only`, `yourself`). And `source` (whose list signs in: `app`, or the hub's own, `hub` or
  `demo`), the `roles` the person asking can give, and `demo_pins`: how many people still sign in with a
  PIN from the guide. No answer of any call here has a PIN in it, or anything one could be worked out from.
- `POST /hub/staff`: somebody new: `{"name": "Kim", "role": "server", "pin": "4827"}`. They sign in with
  that PIN at once. Answers like the `GET`, with the new person's id as `added`.
- `PUT /hub/staff/{id}`: a name, a role or a PIN, each only when it is given. Answers like the `GET`.
- `DELETE /hub/staff/{id}`: taken off the staff: they sign in no more, by PIN, tag or face, and their tag
  and their face are forgotten. What they did keeps their name. Answers like the `GET`.

What is refused: 422 `bad_value` (a PIN that is not four digits, no name, a role the hub does not know) in
words that never repeat a PIN; 409 `pin_taken`, `name_taken`, `last_manager`, `yourself`, `full`; 403
`owner_only`; 404 `unknown_staff`; 503 `read_only` on a standby.

The first change made here takes the list over from the hub's own file as it stands, PINs and all, and the
file is not read after that. A change is in force at once on this hub (`use_staff`), and the location's
other hub finds it within the minute (`watch_staff`), as it finds one made with `hubctl staff pin`.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from ..identity.faces import FaceSignIn
from ..identity.staff import Directory
from ..identity.staff_list import Actor, Refused, StaffList
from ..identity.tags import TagStore
from ..identity.tokens import Grant
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

log = logging.getLogger(__name__)

WATCH_SECONDS = 60.0
"""How often a hub looks whether the staff changed under it."""
TYPED_MOST = 200
"""The most a call may carry in one box."""
_STATUS = {
    "bad_value": 422,
    "unknown_staff": 404,
    "owner_only": 403,
    "not_allowed": 403,
}
"""What a refusal answers with; every other one is a 409: the list as it stands does not allow it."""


class PersonIn(BaseModel):
    """What a manager typed about one person. To change somebody, what is left out stays as it is. No
    limits are set here, and a PIN may be anything on its way in: a refusal by the framework would hand the
    box back in its words, and a PIN typed here is never handed back."""

    name: Any = None
    role: Any = None
    pin: Any = None


def use_staff(app: FastAPI, *, sweep: bool = True) -> None:
    """Puts the staff in force into the hub's directory, where everything that asks who somebody is finds
    them: after a change, and when the list was found changed. With `sweep`, the tag and the face of
    whoever was taken off are forgotten too, whichever hub or terminal took them off."""
    staff: StaffList = app.state.staff_list
    mark = staff.mark()  # first: a change that lands in between is found at the next look
    people, gone = staff.in_force()
    directory: Directory = app.state.staff
    directory.use(people, gone)
    app.state.staff_mark = mark
    if sweep and gone:
        _forget_gone(app, gone)


def _forget_gone(app: FastAPI, gone: dict[str, str]) -> None:
    """Somebody who left has no tag and no face here any more. Neither would sign them in (the directory
    says they are gone), and neither is kept of a person who is not on the staff."""
    tags: TagStore | None = getattr(app.state, "tags", None)
    faces: FaceSignIn | None = getattr(app.state, "faces", None)
    try:
        enrolled = faces.enrolled() if faces is not None else {}
        for staff_id in gone:
            if tags is not None and tags.for_staff(staff_id) is not None:
                tags.forget(staff_id)
            if faces is not None and staff_id in enrolled:
                faces.forget(staff_id)
    except ReadOnlyError:
        pass  # a standby: the hub in charge forgets them, and this one reads that
    except Exception as err:  # noqa: BLE001 - the staff are in force all the same; the next look tries again
        log.warning("staff: could not forget the tag or the face of somebody who left (%s)", type(err).__name__)
        app.state.staff_mark = ""


async def watch_staff(app: FastAPI, every: float = WATCH_SECONDS) -> None:
    """For as long as the API runs: when the stored staff are not the ones this hub last put in force, they
    are put in force. A hub that cannot read its database for a while tries again at the next turn."""
    while True:
        await asyncio.sleep(every)
        try:
            staff: StaffList = app.state.staff_list
            if await run_in_threadpool(staff.mark) != app.state.staff_mark:
                await run_in_threadpool(use_staff, app)
                app.state.feed.changed("settings")  # the screens that list the staff read them again
                log.warning("staff: the list changed under this hub; the one in force now is in use")
        except asyncio.CancelledError:
            raise
        except Exception as err:  # noqa: BLE001 - never the last look
            log.warning("staff: could not look whether the list changed (%s)", type(err).__name__)


def add_staff_list(app: FastAPI) -> None:
    def actor(grant: Grant) -> Actor:
        return Actor(grant.staff_id, grant.name)

    def said(grant: Grant, **more: Any) -> dict[str, Any]:
        staff: StaffList = app.state.staff_list
        by = actor(grant)
        people = staff.members()
        try:
            return {
                "staff": [
                    {
                        "staff_id": m.staff_id,
                        "name": m.name,
                        "role": m.role,
                        "you": m.staff_id == grant.staff_id,
                        "pin": {"from": m.pin_from, "by": m.pin_by, "at_ms": m.pin_at_ms or None},
                        "can": staff.may(by, m),
                    }
                    for m in people
                ],
                "source": staff.source(),
                "roles": staff.roles_for(by),
                "demo_pins": sum(1 for m in people if m.pin_from == "demo"),
                **more,
            }
        except Refused as err:  # no manager any more, since a moment ago
            raise HTTPException(403, {"error": err.code, "message": err.message}) from None

    def typed(body: PersonIn) -> dict[str, str | None]:
        """The boxes as text. Anything else in one, and anything far too long, is refused in words that do
        not say what it was."""
        boxes: dict[str, str | None] = {}
        for box, value in (("name", body.name), ("role", body.role), ("pin", body.pin)):
            if value is not None and (not isinstance(value, str) or len(value) > TYPED_MOST):
                words = "A PIN is four digits." if box == "pin" else f"That is not a {box}."
                raise HTTPException(422, {"error": "bad_value", "message": words})
            boxes[box] = value
        return boxes

    def changed(change: Any) -> Any:
        """Makes one change and puts the staff in force, or answers why not."""
        try:
            made = change()
            use_staff(app)
        except Refused as err:
            raise HTTPException(_STATUS.get(err.code, 409), {"error": err.code, "message": err.message}) from None
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")  # the screens that list the staff read them again
        return made

    @app.get("/hub/staff")
    def read_staff_list(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Everybody on the staff, and what the person asking may do to each. Never a PIN."""
        grant = manager_from(app.state.tokens, authorization)
        return said(grant)

    @app.post("/hub/staff")
    def add_person(body: PersonIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Somebody new on the staff, who signs in with that PIN at once."""
        grant = manager_from(app.state.tokens, authorization)
        boxes = typed(body)
        staff: StaffList = app.state.staff_list
        made = changed(lambda: staff.add(boxes["name"] or "", boxes["role"] or "", boxes["pin"] or "", by=actor(grant)))
        return said(grant, added=made.staff_id)

    @app.put("/hub/staff/{staff_id}")
    def change_person(staff_id: str, body: PersonIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A name, a role or a PIN changed, each only when it is given: in force at once."""
        grant = manager_from(app.state.tokens, authorization)
        boxes = typed(body)
        staff: StaffList = app.state.staff_list
        changed(lambda: staff.change(staff_id, **boxes, by=actor(grant)))
        return said(grant)

    @app.delete("/hub/staff/{staff_id}")
    def remove_person(staff_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Somebody left: they sign in no more, and their tag and face are forgotten."""
        grant = manager_from(app.state.tokens, authorization)
        staff: StaffList = app.state.staff_list
        changed(lambda: staff.remove(staff_id, by=actor(grant)))
        return said(grant)
