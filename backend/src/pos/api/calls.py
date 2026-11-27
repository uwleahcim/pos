"""An order's recorded calls on the wire (docs/call-recordings.md). The work is in `pos.phones.recordings`.

- `GET /orders/{order_id}/calls`: the recorded calls that go with the order, oldest first: the ones with its
  phone number, from the day it was opened to the day it is wanted for. Each has its `id`, `direction` (`in`:
  the customer called; `out`: the restaurant called them), `started_ms`, `seconds`, `stereo` (the caller on
  the left, the restaurant on the right) and `opened` (the order was opened during it). `linked` says
  whether this hub reads a PBX's recordings at all; `problem` is a word for why the list may be behind (the
  PBX did not answer the last look). Open like the order itself: it says when the number called, and plays
  nothing. 404 for an order the log has never heard of.
- `GET /orders/{order_id}/calls/{call_id}/audio` (a session whose holder has the power `calls`): that call
  as an MP3. 404 `unknown_call` for a call that is not one of the order's, 404 `gone` for a recording the
  PBX no longer has, 424 `pbx_unreachable` when the PBX is away (`pbx_failed` when it answered and could
  not hand the recording over).
- `GET /phones/recordings`: how the hub stands with the PBX's recordings, for `hubctl pbx recordings
  status`: linked or not, how many calls it knows, when it last looked, what the program on the PBX found
  there (its tools, whether the stereo step is in place).
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Response

from ..phones.recordings import PbxError, Recordings
from .auth import holder_from

log = logging.getLogger("pos.phones.recordings")


def add_calls(app: FastAPI) -> None:
    def order_of(order_id: str) -> Any:
        entry = app.state.store.entry(order_id)
        if entry is None:
            raise HTTPException(404, {"error": "unknown_id", "message": "There is no such check."})
        return entry

    @app.get("/orders/{order_id}/calls")
    def read_calls(order_id: str) -> dict[str, Any]:
        """The recorded calls that go with an order: who called whom, when and for how long."""
        entry = order_of(order_id)
        recordings: Recordings = app.state.recordings
        if entry.phone:
            recordings.refresh()  # the call that just ended is on the list
        status = recordings.status()
        problem = status.get("problem")
        return {
            "order_id": order_id,
            "phone": entry.phone,
            "linked": recordings.configured,
            "problem": problem["code"] if problem else None,
            "calls": recordings.for_order(entry.phone, entry.first_ms, entry.promised_ms),
        }

    @app.get("/orders/{order_id}/calls/{call_id}/audio")
    def read_call_audio(order_id: str, call_id: str, authorization: str | None = Header(None)) -> Response:
        """One of the order's calls as an MP3, for whoever may listen to them."""
        grant = holder_from(app.state, authorization, "calls")
        entry = order_of(order_id)
        recordings: Recordings = app.state.recordings
        if not recordings.belongs(call_id, entry.phone, entry.first_ms, entry.promised_ms):
            raise HTTPException(404, {"error": "unknown_call", "message": "That call is not one of this order's."})
        try:
            data = recordings.audio(call_id)
        except PbxError as err:
            if err.code == "gone":
                raise HTTPException(
                    404, {"error": "gone", "message": "The phone server no longer has that recording."}
                ) from err
            # 424, never a 5xx: the hub is well, and a screen must not take it for one that is down
            if err.code == "unreachable":
                raise HTTPException(
                    424, {"error": "pbx_unreachable", "message": "The phone server did not answer. Try again."}
                ) from err
            raise HTTPException(
                424, {"error": "pbx_failed", "message": "The phone server could not hand that recording over."}
            ) from err
        log.info("%s (%s) listened to call %s on order %s", grant.name, grant.staff_id, call_id, order_id)
        return Response(content=data, media_type="audio/mpeg", headers={"Cache-Control": "no-store"})

    @app.get("/phones/recordings")
    def read_recordings_status() -> dict[str, Any]:
        """How the hub stands with the PBX's call recordings."""
        recordings: Recordings = app.state.recordings
        return recordings.status(ask=True)
