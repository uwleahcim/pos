"""Face sign-in on the wire: the frames a sign-in screen sends, a manager's enrollment of the staff, and the
location's switch. The rules live in `pos.identity.faces`; this is the shape of the calls.

- `GET /faces/status`: whether the location has it on, whether the hub's models are loaded, how many staff
  are enrolled; `active` when all three hold, which is when a sign-in screen starts looking.
- `POST /signin/face` `{device, jpeg_b64}`: one frame. The answer says whether a face was in it and, once
  the match is strong on its own or two frames in a row agree, `signed_in` with the same shape `POST /signin`
  gives for a PIN.
- `GET /admin/staff` (manager token): the staff by name with each one's enrollment.
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
from ..sync.pgstore import ReadOnlyError
from .auth import manager_from

MAX_FRAME = 400_000  # a 480 px JPEG is 30 to 60 KB; refuse anything that is clearly not a frame


class FrameIn(BaseModel):
    device: str
    jpeg_b64: str


class SampleIn(FrameIn):
    replace: bool = False  # the first view of a fresh enrollment: the person's old templates go


class FacesIn(BaseModel):
    enabled: bool = False


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

    def manager(authorization: str | None):  # noqa: ANN202
        return manager_from(app.state.tokens, authorization)

    @app.get("/faces/status")
    def face_status() -> dict[str, Any]:
        """Whether a sign-in screen should look for faces at all."""
        return faces().status()

    @app.post("/signin/face")
    def sign_in_face(body: FrameIn) -> dict[str, Any]:
        """One frame off the sign-in screen's camera. `signed_in` comes once the match is strong on its own or
        two frames in a row agree."""
        app.state.devices.heard(body.device)
        jpeg = _frame(body.jpeg_b64)
        result = faces().identify(jpeg, device=body.device)
        out = result.as_json()
        if result.signed_in is not None:
            photo_for(result, jpeg, device=body.device, photo_store=app.state.photos, taken_at=time.time())
            out["signed_in"]["preferences"] = app.state.preferences.get(result.signed_in.staff_id)
        return out

    @app.get("/admin/staff")
    def list_staff(authorization: str | None = Header(None)) -> dict[str, Any]:
        """The staff by name, each with how many face views are enrolled and when the last was."""
        manager(authorization)
        directory: Directory = app.state.staff
        enrolled = faces().enrolled()
        return {
            "staff": [
                {
                    "staff_id": s.staff_id,
                    "name": s.name,
                    "role": s.role,
                    "face": enrolled.get(s.staff_id) or {"samples": 0, "updated_at": 0.0, "stale": 0},
                }
                for s in directory.all()
            ]
        }

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
            return app.state.settings.put("faces", cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
