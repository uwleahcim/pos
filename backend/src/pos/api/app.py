"""A minimal API around the operation log: append, read, pull.

The same three calls serve a terminal talking to a hub, a hub talking to the cloud, and the cloud
talking back. Phase 1 puts the store in PostgreSQL and adds WebSocket pushes; the shape stays.
"""

from __future__ import annotations

import base64
import binascii
import os
import time
from typing import TYPE_CHECKING, Any

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from ..identity.photos import EventPhoto, PhotoStore
from ..identity.staff import Directory, Locked, demo_directory
from ..sync.hlc import HLC
from ..sync.oplog import KINDS, ClockDriftError, Op, OpStore

if TYPE_CHECKING:
    from ..sync.pgstore import PgOpStore

from ..sync.pgstore import ReadOnlyError


class OpIn(BaseModel):
    op_id: str
    order_id: str
    hlc: str = Field(description="wall_ms-counter-node, as HLC.__str__ writes it")
    device: str
    kind: str
    data: dict[str, Any] = Field(default_factory=dict)

    def to_op(self) -> Op:
        return Op(
            op_id=self.op_id,
            order_id=self.order_id,
            hlc=HLC.parse(self.hlc),
            device=self.device,
            kind=self.kind,
            data=self.data,
        )


_NEVER = HLC(0, 0, "")


def op_out(op: Op) -> dict[str, Any]:
    return {
        "op_id": op.op_id,
        "order_id": op.order_id,
        "hlc": str(op.hlc),
        "device": op.device,
        "kind": op.kind,
        "data": op.data,
    }


def default_store() -> OpStore | PgOpStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise (tests, a laptop)."""
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        from ..sync.pgstore import PgOpStore

        return PgOpStore(dsn)
    return OpStore()


class SignInIn(BaseModel):
    device: str
    pin: str | None = None
    tag_uid: str | None = None
    photo_id: str | None = None


class PhotoIn(BaseModel):
    photo_id: str
    device: str
    event: str
    jpeg_b64: str
    op_id: str | None = None
    staff_id: str | None = None
    taken_at: float | None = None


def create_app(
    store: OpStore | PgOpStore | None = None,
    *,
    staff: Directory | None = None,
    photos: PhotoStore | None = None,
) -> FastAPI:
    app = FastAPI(title="POS backend", version="0.0.1 (phase 0)")
    app.state.store = store if store is not None else default_store()
    app.state.staff = staff if staff is not None else demo_directory()
    app.state.photos = photos if photos is not None else PhotoStore()
    # Phase 0: the Flutter web build runs from another origin; phase 1 narrows this to the apps' origins.
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    @app.get("/health")
    def health() -> dict[str, Any]:
        """`role` is primary (takes orders), replica (reads only, a standby hub) or memory (no database)."""
        store = app.state.store
        role = getattr(store, "role", "memory")
        return {"status": "ok", "cursor": store.cursor, "role": role, "node": os.environ.get("POS_NODE", "")}

    @app.post("/orders/{order_id}/ops", status_code=202)
    def append_ops(order_id: str, ops: list[OpIn]) -> dict[str, Any]:
        store: OpStore | PgOpStore = app.state.store
        for op in ops:
            if op.order_id != order_id:
                raise HTTPException(400, f"op {op.op_id} belongs to order {op.order_id}")
            if op.kind not in KINDS:
                raise HTTPException(422, {"error": "unknown_kind", "op_id": op.op_id})
            if not op.device or not op.hlc.endswith(f"-{op.device}"):
                raise HTTPException(422, {"error": "bad_stamp", "op_id": op.op_id})
        try:
            accepted = store.append(op.to_op() for op in ops)
        except ClockDriftError as err:
            raise HTTPException(422, {"error": "clock_drift", "op_id": err.op.op_id}) from err
        except ReadOnlyError as err:
            # A standby hub: the terminal moves to the next address and comes back when this one is promoted.
            raise HTTPException(503, {"error": "read_only"}) from err
        return {"accepted": [op.op_id for op in accepted], "cursor": store.cursor}

    @app.get("/orders")
    def list_orders(status: str | None = Query(None, pattern="^(open|closed|void)$")) -> dict[str, Any]:
        """Every order the store knows, newest activity first; `status` filters."""
        store: OpStore | PgOpStore = app.state.store
        states = [store.state(order_id) for order_id in store.order_ids()]
        if status is not None:
            states = [state for state in states if state.status == status]
        states.sort(key=lambda state: state.last or _NEVER, reverse=True)
        return {"orders": [state.snapshot() for state in states], "cursor": store.cursor}

    @app.get("/orders/{order_id}")
    def read_order(order_id: str) -> dict[str, Any]:
        store: OpStore | PgOpStore = app.state.store
        ops = store.for_order(order_id)
        if not ops:
            raise HTTPException(404, "no such order")
        return store.state(order_id).snapshot()

    @app.get("/ops")
    def pull_ops(since: int = Query(0, ge=0), limit: int = Query(500, ge=1, le=5000)) -> dict[str, Any]:
        store: OpStore | PgOpStore = app.state.store
        ops = store.since(since, limit)
        return {"ops": [op_out(op) for op in ops], "cursor": since + len(ops)}

    @app.post("/signin")
    def sign_in(body: SignInIn) -> dict[str, Any]:
        """Who this PIN or tag belongs to. The app shows the name; it never sees the staff list."""
        directory: Directory = app.state.staff
        try:
            if body.pin is not None:
                found = directory.by_pin(body.pin, device=body.device)
            elif body.tag_uid is not None:
                found = directory.by_tag(body.tag_uid, device=body.device)
            else:
                raise HTTPException(422, {"error": "no_credential"})
        except Locked as err:
            raise HTTPException(423, {"error": "locked", "seconds": round(err.seconds_left)}) from err
        if found is None:
            raise HTTPException(401, {"error": "unknown_credential"})
        return {"staff_id": found.staff_id, "name": found.name, "role": found.role, "method": found.method}

    @app.post("/events/photos", status_code=202)
    def put_photo(body: PhotoIn) -> dict[str, Any]:
        try:
            jpeg = base64.b64decode(body.jpeg_b64, validate=True)
        except binascii.Error as err:
            raise HTTPException(422, {"error": "bad_base64"}) from err
        if not jpeg.startswith(b"\xff\xd8"):
            raise HTTPException(422, {"error": "not_jpeg"})
        photo = EventPhoto(
            photo_id=body.photo_id,
            device=body.device,
            op_id=body.op_id,
            event=body.event,
            staff_id=body.staff_id,
            taken_at=body.taken_at or time.time(),
            jpeg=jpeg,
        )
        try:
            app.state.photos.put(photo)
        except ValueError as err:
            raise HTTPException(413, {"error": "too_large"}) from err
        return {"photo_id": photo.photo_id, "bytes": len(jpeg)}

    @app.get("/events/photos")
    def list_photos(limit: int = Query(50, ge=1, le=500)) -> dict[str, Any]:
        photos: PhotoStore = app.state.photos
        return {
            "photos": [
                {
                    "photo_id": p.photo_id,
                    "device": p.device,
                    "event": p.event,
                    "op_id": p.op_id,
                    "staff_id": p.staff_id,
                    "taken_at": p.taken_at,
                    "bytes": len(p.jpeg),
                }
                for p in photos.recent(limit)
            ]
        }

    @app.get("/events/photos/{photo_id}")
    def get_photo(photo_id: str) -> Response:
        """The picture itself. Viewing is a manager action in phase 1; open in phase 0."""
        photo = app.state.photos.get(photo_id)
        if photo is None:
            raise HTTPException(404, "no such photo")
        return Response(photo.jpeg, media_type="image/jpeg")

    return app


app = create_app()
