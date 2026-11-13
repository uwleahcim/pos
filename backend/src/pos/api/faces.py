"""Face sign-in on the wire: the frames a sign-in screen sends, a manager's enrollment of the staff, and the
location's switch. The rules live in `pos.identity.faces`; this is the shape of the calls.

- `GET /faces/status`: whether the location has it on, whether the hub's models are loaded, how many staff
  are enrolled; `active` when all three hold, which is when a sign-in screen starts looking.
- `POST /signin/face` `{device, jpeg_b64, current}`: one frame. The answer says whether a face was in it and,
  once the match is strong on its own or two frames in a row agree, `signed_in` with the same shape
  `POST /signin` gives for a PIN. With `current` (who is signed in on the screen) it says `same` while that
  person is the one at the screen and `present` while their face is in view at all, and signs in someone else
  once they clearly are the one at the screen.
- `GET /admin/staff` (manager token): the staff by name with each one's face enrollment and tag.
- `PUT /admin/staff/{id}/tag` `{tag_uid, device}` and `DELETE /admin/staff/{id}/tag` (manager token): the
  person's tag, as the reader typed it; a tag that is someone else's is refused with their name.
- `GET /settings/presence`, `PUT /settings/presence` `{switch, away_seconds}` (manager token): hands-free
  switching, for faces and tags alike.
- `POST /admin/staff/{id}/face/samples` `{device, jpeg_b64, replace}` (manager token): one view of the
  person; `accepted` or `reason` why not, and how many views are kept of the five wanted.
- `DELETE /admin/staff/{id}/face` (manager token): forgets the person's templates.
- `GET /settings/faces`, `PUT /settings/faces` `{enabled}` (manager token): the location's switch.
"""

from __future__ import annotations

import base64
import binascii
import time
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

from ..identity.faces import FaceSignIn, clean_faces, is_jpeg, photo_for
from ..identity.staff import Directory
from ..identity.tags import NO_TAG, TagStore, TagTaken, clean_tag_uid
from ..settings import clean_presence
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

MAX_FRAME = 400_000  # a 480 px JPEG is 30 to 60 KB; refuse anything that is clearly not a frame


class FrameIn(BaseModel):
    device: str
    jpeg_b64: str
    current: str | None = None  # who is signed in on the screen, while someone is


class SampleIn(FrameIn):
    replace: bool = False  # the first view of a fresh enrollment: the person's old templates go


class FacesIn(BaseModel):
    enabled: bool = False


class PresenceIn(BaseModel):
    switch: bool = True
    away_seconds: int = 60


class TagIn(BaseModel):
    tag_uid: str
    device: str | None = None


def _frame(jpeg_b64: str) -> bytes:
    try:
        jpeg = base64.b64decode(jpeg_b64, validate=True)
    except binascii.Error as err:
        raise HTTPException(422, {"error": "bad_base64"}) from err
    if not is_jpeg(jpeg):
        raise HTTPException(422, {"error": "not_jpeg"})
    if len(jpeg) > MAX_FRAME:
        raise HTTPException(413, {"error": "too_large"})
    return jpeg


def add_face_signin(app: FastAPI) -> None:
    def faces() -> FaceSignIn:
        return app.state.faces

    def tags() -> TagStore:
        return app.state.tags

    def manager(authorization: str | None):  # noqa: ANN202
        return manager_from(app.state.tokens, authorization)

    @app.get("/faces/status")
    def face_status() -> dict[str, Any]:
        """Whether a sign-in screen should look for faces at all."""
        return faces().status()

    @app.post("/signin/face")
    def sign_in_face(body: FrameIn) -> dict[str, Any]:
        """One frame off a screen's camera. `signed_in` comes once the match is strong on its own or two frames
        in a row agree; with `current`, only for someone other than the person signed in."""
        app.state.devices.heard(body.device)
        jpeg = _frame(body.jpeg_b64)
        result = faces().identify(jpeg, device=body.device, current=body.current)
        out = result.as_json()
        if result.signed_in is not None:
            photo_for(result, jpeg, device=body.device, photo_store=app.state.photos, taken_at=time.time())
            out["signed_in"]["preferences"] = app.state.preferences.get(result.signed_in.staff_id)
        return out

    @app.get("/admin/staff")
    def list_staff(authorization: str | None = Header(None)) -> dict[str, Any]:
        """The staff by name, each with how many face views are enrolled and when the last was, and their tag."""
        manager(authorization)
        directory: Directory = app.state.staff
        enrolled = faces().enrolled()
        owned = tags().all()
        return {
            "staff": [
                {
                    "staff_id": s.staff_id,
                    "name": s.name,
                    "role": s.role,
                    "face": enrolled.get(s.staff_id) or {"samples": 0, "updated_at": 0.0, "stale": 0},
                    "tag": owned[s.staff_id].summary() if s.staff_id in owned else dict(NO_TAG),
                }
                for s in directory.all()
            ]
        }

    @app.put("/admin/staff/{staff_id}/tag")
    def set_tag(staff_id: str, body: TagIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """The person's tag, as the reader at the manager's screen typed it. Replaces the one they had."""
        manager(authorization)
        directory: Directory = app.state.staff
        if directory.get(staff_id) is None:
            raise HTTPException(404, {"error": "unknown_staff"})
        try:
            uid = clean_tag_uid(body.tag_uid)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_tag", "message": str(err)}) from err
        try:
            tag = tags().assign(staff_id, uid, device=body.device)
        except TagTaken as err:
            owner = directory.get(err.staff_id)
            name = owner.name if owner is not None else err.staff_id
            raise HTTPException(409, {"error": "tag_taken", "name": name, "message": f"That tag is {name}'s"}) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return {"staff_id": staff_id, "tag": tag.summary()}

    @app.delete("/admin/staff/{staff_id}/tag")
    def forget_tag(staff_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Forgets the person's tag; they sign in by PIN or face until given another."""
        manager(authorization)
        try:
            removed = tags().forget(staff_id)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return {"staff_id": staff_id, "removed": removed}

    @app.post("/admin/staff/{staff_id}/face/samples")
    def enroll_face(staff_id: str, body: SampleIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """One view of the person from the enrollment screen: kept when it is good and new."""
        manager(authorization)
        directory: Directory = app.state.staff
        if directory.get(staff_id) is None:
            raise HTTPException(404, {"error": "unknown_staff"})
        jpeg = _frame(body.jpeg_b64)
        try:
            result = faces().enroll(staff_id, jpeg, device=body.device, replace=body.replace)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return result.as_json()

    @app.delete("/admin/staff/{staff_id}/face")
    def forget_face(staff_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Forgets the person's templates; they sign in by PIN until enrolled again."""
        manager(authorization)
        try:
            removed = faces().forget(staff_id)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return {"staff_id": staff_id, "removed": removed}

    @app.get("/settings/faces")
    def read_faces_setting() -> dict[str, Any]:
        """Whether this location signs staff in by face."""
        return app.state.settings.get("faces")

    @app.put("/settings/faces")
    def write_faces_setting(body: FacesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager switches face sign-in on or off for every terminal of the location."""
        manager(authorization)
        try:
            cleaned = clean_faces(body.model_dump())
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = app.state.settings.put("faces", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return saved

    @app.get("/settings/presence")
    def read_presence_setting() -> dict[str, Any]:
        """Whether a face or tag seen while someone is signed in switches the screen to that person, and how
        long the camera may miss the signed-in person before the screen signs them out."""
        return app.state.settings.get("presence")

    @app.put("/settings/presence")
    def write_presence_setting(body: PresenceIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets the hands-free switching for every terminal of the location."""
        manager(authorization)
        try:
            cleaned = clean_presence(body.model_dump())
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        try:
            saved = app.state.settings.put("presence", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return saved
