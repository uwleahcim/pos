"""A minimal API around the operation log: append, read, pull.

The same three calls serve a terminal talking to a hub, a hub talking to the cloud, and the cloud
talking back. Phase 1 puts the store in PostgreSQL and adds WebSocket pushes; the shape stays.
"""

from __future__ import annotations

import base64
import binascii
import os
import time
from dataclasses import replace
from decimal import Decimal
from typing import TYPE_CHECKING, Any

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from ..floor import FloorPlan, load_floor, table_status
from ..identity.photos import EventPhoto, PhotoStore
from ..identity.staff import Directory, Locked, demo_directory
from ..menu.service import MenuService
from ..orders.check import check_for
from ..printing.jobs import PrintJob
from ..printing.service import PrintService
from ..printing.ticket import DEMO
from ..sync.hlc import HLC
from ..sync.oplog import KINDS, ClockDriftError, Op, OpStore
from ..tax import TaxProfile, load_profile

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


class ClaimIn(BaseModel):
    relay: str
    printers: list[str]


class ReportIn(BaseModel):
    by: str
    error: str | None = None


class TestPrintIn(BaseModel):
    printer: str


class AvailabilityIn(BaseModel):
    target_id: str = Field(description="a variant id (one size) or an option id")
    status: str = Field(pattern="^(available|sold_out)$")
    by: str | None = None
    reason: str | None = None


class PriceIn(BaseModel):
    variant_id: str
    entry_id: str | None = None
    selections: list[dict[str, Any]] = Field(default_factory=list)
    components: list[dict[str, Any]] = Field(default_factory=list)
    notes: str | None = None


def price_lines(menu: MenuService, ops: list[Op]) -> tuple[list[Op], list[dict[str, Any]]]:
    """Price every new `add_line` that carries a menu request. The terminal's own `priced`, if any, is
    dropped: prices come from the hub's menu, never from a screen. A line the menu refuses (a required
    choice missing, an 86'd dish, an unknown id) is left out and reported with its problems; the rest of
    the batch is kept, so a terminal's outbox never loses good operations behind a bad one."""
    out: list[Op] = []
    refused: list[dict[str, Any]] = []
    for op in ops:
        if op.kind == "add_line" and isinstance(op.data.get("request"), dict):
            data = {k: v for k, v in op.data.items() if k != "priced"}
            try:
                priced = menu.priced(data["request"])
                blocking = [p for p in priced["problems"] if p["code"] not in WARNINGS]
            except (KeyError, ValueError, TypeError) as err:
                blocking = [{"code": "bad_request", "message": str(err)}]
            if blocking:
                refused.append({"op_id": op.op_id, "error": "invalid_line", "problems": blocking})
                continue
            data["priced"] = priced
            data["item"] = priced["name"]
            op = replace(op, data=data)
        out.append(op)
    return out, refused


WARNINGS: frozenset[str] = frozenset()
"""Problem codes a line may still be sold with; none yet, so every problem stops the sale."""


def job_out(job: PrintJob, *, with_data: bool = False) -> dict[str, Any]:
    out: dict[str, Any] = {
        "job_id": job.job_id,
        "printer": job.printer,
        "status": job.status,
        "attempts": job.attempts,
        "bytes": len(job.data),
        "leased_to": job.leased_to,
        "done_by": job.done_by,
        "last_error": job.last_error,
    }
    if with_data:
        out["data_b64"] = base64.b64encode(job.data).decode("ascii")
    return out


def create_app(
    store: OpStore | PgOpStore | None = None,
    *,
    staff: Directory | None = None,
    photos: PhotoStore | None = None,
    printing: PrintService | None = None,
    menu: MenuService | None = None,
    taxes: TaxProfile | None = None,
    floor: FloorPlan | None = None,
) -> FastAPI:
    app = FastAPI(title="POS backend", version="0.1.0 (phase 1)")
    app.state.menu = menu if menu is not None else MenuService()
    app.state.taxes = taxes if taxes is not None else load_profile()
    app.state.floor = floor if floor is not None else load_floor()
    app.state.store = store if store is not None else default_store()
    app.state.staff = staff if staff is not None else demo_directory()
    app.state.photos = photos if photos is not None else PhotoStore()
    app.state.printing = printing if printing is not None else PrintService.from_env()
    if printing is None:
        app.state.printing.start_retrying()
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
        fresh, refused = price_lines(app.state.menu, [op.to_op() for op in ops if op.op_id not in store])
        try:
            accepted = store.append(fresh)
        except ClockDriftError as err:
            raise HTTPException(422, {"error": "clock_drift", "op_id": err.op.op_id}) from err
        except ReadOnlyError as err:
            # A standby hub: the terminal moves to the next address and comes back when this one is promoted.
            raise HTTPException(503, {"error": "read_only"}) from err
        printing: PrintService = app.state.printing
        jobs = printing.on_ops(store.for_order, list(accepted))
        return {
            "accepted": [op.op_id for op in accepted],
            "cursor": store.cursor,
            "print_jobs": [j.job_id for j in jobs],
            "refused": refused,
        }

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

    @app.get("/orders/{order_id}/check")
    def read_check(order_id: str) -> dict[str, Any]:
        """What the table owes: priced lines, subtotal, tax lines by jurisdiction, total."""
        store: OpStore | PgOpStore = app.state.store
        if not store.for_order(order_id):
            raise HTTPException(404, "no such order")
        return check_for(store.state(order_id), app.state.taxes)

    @app.get("/floor")
    def read_floor() -> dict[str, Any]:
        """The floor plan with the open checks on each table, for the floor map."""
        store: OpStore | PgOpStore = app.state.store
        states = [store.state(order_id) for order_id in store.order_ids()]
        open_states = [s for s in states if s.status == "open"]
        totals = {s.order_id: Decimal(check_for(s, app.state.taxes)["total"]) for s in open_states}
        plan: FloorPlan = app.state.floor
        return {**plan.as_json(), "status": table_status(open_states, totals), "cursor": store.cursor}

    # Menu: the apps show it and send choices back; prices and tax come from here --------------------------
    @app.get("/menu")
    def read_menu(channel: str = "pos", locale: str = "en") -> dict[str, Any]:
        menu: MenuService = app.state.menu
        return {"menus": menu.menus(channel, locale)}

    @app.get("/menu/items/{item_id}")
    def read_item(item_id: str, entry: str | None = None, locale: str = "en") -> dict[str, Any]:
        menu: MenuService = app.state.menu
        if item_id not in menu.defs.items:
            raise HTTPException(404, "no such item")
        return menu.item(item_id, entry, locale)

    @app.get("/menu/search")
    def search_menu(q: str, channel: str = "pos", locale: str = "en") -> dict[str, Any]:
        menu: MenuService = app.state.menu
        return {"hits": menu.search(q, channel, locale)}

    @app.get("/menu/86")
    def eighty_sixed() -> dict[str, Any]:
        """What the kitchen is out of right now: the 86 board."""
        menu: MenuService = app.state.menu
        return {"items": menu.eighty_sixed()}

    @app.post("/menu/86")
    def set_86(body: AvailabilityIn) -> dict[str, Any]:
        """86 a size or an option (`sold_out`), or bring it back (`available`). Kept on this hub until the
        next restart; the cloud copy joins with slice 7."""
        menu: MenuService = app.state.menu
        if body.target_id not in menu.defs.variants and body.target_id not in menu.defs.options:
            raise HTTPException(404, {"error": "unknown_id", "id": body.target_id})
        menu.engine.set_availability(body.target_id, body.status, reason=body.reason, by=body.by)
        return {"items": menu.eighty_sixed()}

    @app.post("/menu/price")
    def price_line(body: PriceIn) -> dict[str, Any]:
        """A preview of one configured line, so the screen can show the price before adding it."""
        menu: MenuService = app.state.menu
        try:
            return menu.priced(body.model_dump())
        except KeyError as err:
            raise HTTPException(404, {"error": "unknown_id", "id": str(err)}) from err

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

    # Printing: the hub prints its own jobs; a terminal in relay mode claims what is left ------------------
    @app.get("/print/printers")
    def list_printers() -> dict[str, Any]:
        printing: PrintService = app.state.printing
        return {
            "printers": [{"name": p.name, "address": p.address, "dialect": p.dialect} for p in printing.printers],
            "direct": printing.direct,
        }

    @app.get("/print/jobs")
    def list_jobs(status: str | None = Query(None, pattern="^(queued|leased|done|failed)$")) -> dict[str, Any]:
        printing: PrintService = app.state.printing
        jobs = sorted(printing.store.all(), key=lambda j: j.created, reverse=True)
        if status is not None:
            jobs = [j for j in jobs if j.status == status]
        return {"jobs": [job_out(j) for j in jobs[:200]]}

    @app.post("/print/jobs/claim")
    def claim_job(body: ClaimIn) -> dict[str, Any]:
        """A relay asks for one job for a printer it can reach; the bytes come with it."""
        printing: PrintService = app.state.printing
        job = printing.store.claim(body.printers, body.relay)
        return {"job": job_out(job, with_data=True) if job else None}

    @app.post("/print/jobs/{job_id}/done")
    def job_done(job_id: str, body: ReportIn) -> dict[str, Any]:
        printing: PrintService = app.state.printing
        if printing.store.get(job_id) is None:
            raise HTTPException(404, "no such job")
        return job_out(printing.store.done(job_id, body.by))

    @app.post("/print/jobs/{job_id}/failed")
    def job_failed(job_id: str, body: ReportIn) -> dict[str, Any]:
        printing: PrintService = app.state.printing
        if printing.store.get(job_id) is None:
            raise HTTPException(404, "no such job")
        return job_out(printing.store.failed(job_id, body.by, body.error or "relay failed"))

    @app.post("/print/test", status_code=202)
    def test_print(body: TestPrintIn) -> dict[str, Any]:
        """The demo ticket to a configured printer, by name: the settings screen's test button."""
        printing: PrintService = app.state.printing
        printer = printing.printer(body.printer)
        if printer is None:
            raise HTTPException(404, {"error": "no_such_printer", "printers": [p.name for p in printing.printers]})
        job = printing.queue(replace(DEMO, station=printer.name), printer)
        return job_out(job)

    return app


app = create_app()
