"""A minimal API around the operation log: append, read, pull.

The same three calls serve a terminal talking to a hub, a hub talking to the cloud, and the cloud
talking back. Phase 1 puts the store in PostgreSQL and adds WebSocket pushes; the shape stays.
"""

from __future__ import annotations

import base64
import binascii
import os
import time
from collections.abc import AsyncIterator, Callable, Mapping
from contextlib import asynccontextmanager
from dataclasses import replace
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import TYPE_CHECKING, Any

from fastapi import FastAPI, Header, HTTPException, Query, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .. import localtime
from ..devices import DevicesSeen
from ..floor import FloorPlan, load_floor, table_status
from ..identity.faces import FaceEngine, FaceSignIn, default_face_store
from ..identity.photos import EventPhoto, PhotoStore
from ..identity.preferences import PreferenceStore
from ..identity.staff import Directory, Locked, demo_directory
from ..identity.tokens import Tokens
from ..menu.service import MenuService
from ..messaging import LogMessenger, Messenger, Notifier, messenger_from_env
from ..orders.adjustments import APPROVAL_TTL, APPROVERS, PricingRules, load_rules
from ..orders.callers import last_order, phone_digits
from ..orders.check import charge_snapshot, check_for
from ..orders.numbers import OrderNumbers
from ..phones.deskphones import AmiWatcher, AnsweredCalls, watcher_from_env
from ..printing.jobs import PrintJob
from ..printing.service import PrintService
from ..printing.ticket import DEMO
from ..settings import SettingStore, clean_coursing, clean_desk_phones, clean_quotes, default_settings
from ..sync.hlc import HLC
from ..sync.oplog import KINDS, ClockDriftError, Op, OpStore, OrderState, apply
from ..tax import TaxProfile, load_profile
from .auth import manager_from
from .faces import add_face_signin
from .menu_admin import add_menu_admin

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


def default_menu() -> MenuService:
    """The menu in PostgreSQL when DATABASE_URL is set (seeded once from POS_MENU), else from POS_MENU alone."""
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        from ..menu.store import MenuStore

        return MenuService(store=MenuStore(dsn))
    return MenuService()


def default_preferences() -> PreferenceStore:
    """Staff preferences in PostgreSQL when DATABASE_URL is set, in memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        from ..identity.preferences import PgPreferenceStore

        return PgPreferenceStore(dsn)
    return PreferenceStore()


class SignInIn(BaseModel):
    device: str
    pin: str | None = None
    tag_uid: str | None = None
    photo_id: str | None = None


class PreferencesIn(BaseModel):
    """What a staff member sets for themselves; a key left out keeps its stored value."""

    text_scale: float | None = Field(None, description="1.0 is the normal size; 0.8 to 1.6")
    high_contrast: bool | None = None
    locale: str | None = None


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


class ApprovalIn(BaseModel):
    """A manager's PIN on the spot, for one purpose on one order."""

    device: str
    pin: str
    purpose: str = Field("adjust", pattern="^adjust$")
    order_id: str


class QuotesIn(BaseModel):
    """How many minutes each channel promises a takeout order, and which channels may pay at pickup."""

    minutes: dict[str, int] = Field(default_factory=dict)
    pay_at_pickup: list[str] = Field(default_factory=list)


class CourseIn(BaseModel):
    id: str | None = Field(None, description="left out for a course new on the screen: the hub names it from the name")
    name: str


class CoursingIn(BaseModel):
    """Whether dishes are coursed, the courses in kitchen order (any number), and where a new dish goes."""

    enabled: bool = True
    default: str | None = Field(None, description="the course a new dish goes to; the first one when left out")
    courses: list[CourseIn] = Field(default_factory=list)


class DeskPhoneLinkIn(BaseModel):
    extension: str = Field(description="the desk phone's extension on the PBX")
    device: str = Field(description="the device name the app shows under Settings")


class DeskPhonesIn(BaseModel):
    """Which screen each desk phone is linked to: a call taken on the phone opens the caller's order there."""

    links: list[DeskPhoneLinkIn] = Field(default_factory=list)


PAYMENT_METHODS = frozenset({"cash", "elsewhere", "card"})


def number_orders(numbers: OrderNumbers, ops: list[Op]) -> list[Op]:
    """A takeout, counter or delivery order gets its number of the day when its `create` arrives (a table
    order is known by its table). The hub gives the number, never the terminal, so two counters cannot pick
    the same one; a terminal's own guess is dropped."""
    out = []
    for op in ops:
        if op.kind == "create" and op.data.get("order_type", "dine_in") != "dine_in":
            op = replace(op, data={**op.data, "order_no": numbers.next(), "stage": op.data.get("stage") or "new"})
        out.append(op)
    return out


def pay_ops(ops: list[Op]) -> tuple[list[Op], list[dict[str, Any]]]:
    """A `pay` names its method and an amount above zero; cash may say what was tendered (at least the
    amount). A bad one is refused with its problems; the rest of the batch goes through."""
    out: list[Op] = []
    refused: list[dict[str, Any]] = []
    for op in ops:
        if op.kind != "pay":
            out.append(op)
            continue
        problems = []
        data = op.data
        if not isinstance(data.get("payment_id"), str) or not data["payment_id"]:
            problems.append({"code": "bad_request", "message": "a payment needs its id"})
        if data.get("method", "cash") not in PAYMENT_METHODS:
            problems.append({"code": "bad_method", "message": f"no payment method called {data.get('method')!r}"})
        amount = _money(data.get("amount"))
        if amount is None or amount <= 0:
            problems.append({"code": "bad_value", "message": "an amount above zero is needed"})
        elif data.get("tendered") is not None:
            tendered = _money(data["tendered"])
            if tendered is None or tendered < amount:
                problems.append({"code": "bad_value", "message": "what was tendered is less than the amount"})
        if problems:
            refused.append({"op_id": op.op_id, "error": "invalid_payment", "problems": problems})
            continue
        out.append(op)
    return out, refused


def _money(value: Any) -> Decimal | None:
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return None


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

ADJUSTMENTS = frozenset({"discount", "remove_discount", "charge", "remove_charge"})


def adjust_ops(
    rules: PricingRules, tokens: Tokens, store: OpStore | PgOpStore, ops: list[Op]
) -> tuple[list[Op], list[dict[str, Any]]]:
    """Check every new discount and charge against the location's rules before it is stored. A manager's
    approval travels as a token (`approval`, from POST /approvals, good for one order) and is swapped for
    `approved_by`, who it was, so the check and the reports name the manager; nothing a terminal says about
    approval on its own is kept. An adjustment the rules refuse (an unknown reason, over its cap, no manager
    when one is needed, a second discount on a dish that does not stack) is left out and reported with its
    problems, like a refused line; the rest of the batch goes through. The line operations earlier in the
    same batch count (a terminal back from an outage sends a void and a later discount together)."""
    out: list[Op] = []
    refused: list[dict[str, Any]] = []
    active: dict[str, dict[str, dict[str, Any]]] = {}  # order -> live discounts by id, as this batch leaves them
    states: dict[str, OrderState] = {}  # order -> its state, with this batch's line operations so far
    earlier: dict[str, list[Op]] = {}  # this batch's line operations on orders whose state is not loaded yet
    for op in ops:
        if op.kind not in ADJUSTMENTS:
            out.append(op)
            if op.order_id in states:
                apply(states[op.order_id], op)
            else:
                earlier.setdefault(op.order_id, []).append(op)
            continue
        data = {k: v for k, v in op.data.items() if k not in ("approval", "approved_by")}
        grant = tokens.verify(op.data["approval"]) if isinstance(op.data.get("approval"), str) else None
        approved = grant is not None and grant.role in APPROVERS and grant.scope == f"adjust:{op.order_id}"
        if grant is not None and approved:
            data["approved_by"] = {"staff_id": grant.staff_id, "name": grant.name}
        ident = data.get("discount_id" if op.kind.endswith("discount") else "charge_id")
        if not isinstance(ident, str) or not ident:
            problems = [{"code": "bad_request", "message": f"a {op.kind} needs its id"}]
            refused.append({"op_id": op.op_id, "error": "invalid_adjustment", "problems": problems})
            continue
        if op.order_id not in active:
            # a discount on a dish follows the dish through its edits: stacking is judged on the line that
            # stands for each discounted line now, and a discount whose dish is off the check (removed or
            # voided, nothing in its place) no longer counts
            state = states[op.order_id] = store.state(op.order_id)
            for line_op in earlier.pop(op.order_id, ()):
                apply(state, line_op)
            active[op.order_id] = {
                d.discount_id: {"reason": d.reason, "line_id": _current(state, d.line_id)}
                for d in state.discounts.values()
                if d.active and _standing(state, d.line_id)
            }
        state = states[op.order_id]
        live = active[op.order_id]
        if op.kind == "remove_discount":
            live.pop(ident, None)
        else:
            judged = {**data, "line_id": _current(state, data.get("line_id"))}
            # a dish voided earlier in this batch takes its discount out of the stacking too
            existing = [d for d in live.values() if _standing(state, d["line_id"])]
            problems = rules.problems(op.kind, judged, approved=approved, existing=existing)
            if problems:
                refused.append({"op_id": op.op_id, "error": "invalid_adjustment", "problems": problems})
                continue
            if op.kind == "discount":
                live[ident] = {"reason": data.get("reason"), "line_id": judged["line_id"]}
            elif op.kind == "charge":
                data.update(charge_snapshot(rules.charges[str(data["code"])]))
        out.append(replace(op, data=data))
    return out, refused


def _current(state: OrderState, line_id: Any) -> str | None:
    return state.current_line(line_id) if isinstance(line_id, str) and line_id else None


def _standing(state: OrderState, line_id: Any) -> bool:
    """Whether a discount on `line_id` still counts: on the whole check, or on a dish still on the check."""
    current = _current(state, line_id)
    if current is None:
        return True
    line = state.lines.get(current)
    return line is not None and line.active


def _tally(totals: dict[str, Decimal], key: str, amount: Decimal) -> None:
    totals[key] = totals.get(key, Decimal(0)) + amount


def _totals(totals: dict[str, Decimal]) -> list[dict[str, str]]:
    return [{"key": key, "amount": str(amount)} for key, amount in sorted(totals.items(), key=lambda kv: -kv[1])]


def job_out(job: PrintJob, *, with_data: bool = False, due_in: float = 0.0) -> dict[str, Any]:
    out: dict[str, Any] = {
        "job_id": job.job_id,
        "printer": job.printer,
        "status": job.status,
        "attempts": job.attempts,
        "bytes": len(job.data),
        "leased_to": job.leased_to,
        "done_by": job.done_by,
        "last_error": job.last_error,
        "due_in": round(due_in),  # seconds until a future order's ticket may print; 0 for the rest
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
    tokens: Tokens | None = None,
    preferences: PreferenceStore | None = None,
    pricing: PricingRules | None = None,
    settings: SettingStore | None = None,
    messenger: Messenger | None = None,
    location: str | None = None,
    numbers: OrderNumbers | None = None,
    today: Callable[[], date] | None = None,
    answered: AnsweredCalls | None = None,
    watcher: AmiWatcher | None = None,
    devices: DevicesSeen | None = None,
    faces: FaceSignIn | None = None,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        """The PBX watcher runs for as long as the API does, when a PBX is configured; the face models load
        on a thread meanwhile, when the hub has them (POS_FACE_MODELS)."""
        pbx: AmiWatcher | None = app.state.watcher
        if pbx is not None:
            pbx.start()
        if faces is None:
            app.state.faces.start(FaceEngine.from_env)
        try:
            yield
        finally:
            if pbx is not None:
                await pbx.stop()

    app = FastAPI(title="POS backend", version="0.1.0 (phase 1)", lifespan=lifespan)
    app.state.menu = menu if menu is not None else default_menu()
    app.state.taxes = taxes if taxes is not None else load_profile()
    app.state.pricing = pricing if pricing is not None else load_rules()
    app.state.floor = floor if floor is not None else load_floor()
    app.state.store = store if store is not None else default_store()
    app.state.staff = staff if staff is not None else demo_directory()
    app.state.photos = photos if photos is not None else PhotoStore()
    app.state.preferences = preferences if preferences is not None else default_preferences()
    app.state.printing = printing if printing is not None else PrintService.from_env()
    app.state.tokens = tokens if tokens is not None else Tokens()
    app.state.settings = settings if settings is not None else default_settings()
    app.state.messenger = messenger if messenger is not None else messenger_from_env()
    app.state.location = location if location is not None else os.environ.get("POS_LOCATION") or "the restaurant"
    # The location's day (POS_TIMEZONE): order numbers count through it, and a caller's orders are looked up in it.
    app.state.today = today if today is not None else localtime.today
    app.state.numbers = numbers if numbers is not None else OrderNumbers(app.state.store, today=app.state.today)
    # Desk phones: the links are the manager's setting, read when a phone answers; the watcher needs POS_AMI_HOST.
    app.state.answered = (
        answered
        if answered is not None
        else AnsweredCalls(
            lambda: {link["extension"]: link["device"] for link in app.state.settings.get("desk_phones")["links"]}
        )
    )
    app.state.watcher = watcher if watcher is not None else watcher_from_env(app.state.answered)
    app.state.devices = devices if devices is not None else DevicesSeen()  # the screens the hub hears from
    # Face sign-in: templates in the database, the location's switch in its settings, the models from the image.
    app.state.faces = (
        faces
        if faces is not None
        else FaceSignIn(
            default_face_store(), app.state.staff.get, enabled=lambda: app.state.settings.get("faces")["enabled"]
        )
    )
    app.state.notifier = Notifier(
        app.state.messenger,
        location=app.state.location,
        unpaid=lambda state: Decimal(check_for(state, app.state.taxes, app.state.pricing)["due"]) > 0,
    )
    # The kitchen ticket says "Course: Appetizers", as the manager named it, where a line only carries the id.
    app.state.printing.course_names = lambda: {
        c["id"]: c["name"] for c in app.state.settings.get("coursing")["courses"]
    }
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
        app.state.menu.refresh()
        fresh, refused = price_lines(app.state.menu, [op.to_op() for op in ops if op.op_id not in store])
        fresh, refused_adjustments = adjust_ops(app.state.pricing, app.state.tokens, store, fresh)
        fresh, refused_payments = pay_ops(fresh)
        fresh = number_orders(app.state.numbers, fresh)
        refused += refused_adjustments + refused_payments
        try:
            accepted = store.append(fresh)
        except ClockDriftError as err:
            raise HTTPException(422, {"error": "clock_drift", "op_id": err.op.op_id}) from err
        except ReadOnlyError as err:
            # A standby hub: the terminal moves to the next address and comes back when this one is promoted.
            raise HTTPException(503, {"error": "read_only"}) from err
        printing: PrintService = app.state.printing
        jobs = printing.on_ops(store.for_order, list(accepted))
        texts = app.state.notifier.on_ops(store.for_order, list(accepted))
        return {
            "accepted": [op.op_id for op in accepted],
            "cursor": store.cursor,
            "print_jobs": [j.job_id for j in jobs],
            "texts": [m.as_json() for m in texts],
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

    @app.get("/orders/last")  # before /orders/{order_id}, which would take "last" for an id
    def read_last_order(phone: str = Query(min_length=1)) -> dict[str, Any]:
        """The order this number opened last today, for the terminal that picks up its call: numbers match by
        their digits, today is the location's day, a voided order does not count. `order` is null when the
        number opened none today."""
        store: OpStore | PgOpStore = app.state.store
        day = app.state.today()
        state = last_order(store, phone, day=day)
        order = None if state is None else state.snapshot()
        return {"phone": phone_digits(phone), "day": day.isoformat(), "order": order}

    @app.get("/orders/{order_id}")
    def read_order(order_id: str) -> dict[str, Any]:
        store: OpStore | PgOpStore = app.state.store
        ops = store.for_order(order_id)
        if not ops:
            raise HTTPException(404, "no such order")
        return store.state(order_id).snapshot()

    @app.get("/orders/{order_id}/check")
    def read_check(order_id: str) -> dict[str, Any]:
        """What the table owes: priced lines, discounts, charges, subtotal, tax lines by jurisdiction, total."""
        store: OpStore | PgOpStore = app.state.store
        if not store.for_order(order_id):
            raise HTTPException(404, "no such order")
        return check_for(store.state(order_id), app.state.taxes, app.state.pricing)

    @app.get("/floor")
    def read_floor() -> dict[str, Any]:
        """The floor plan with the open checks on each table, for the floor map."""
        store: OpStore | PgOpStore = app.state.store
        states = [store.state(order_id) for order_id in store.order_ids()]
        open_states = [s for s in states if s.status == "open"]
        totals = {s.order_id: Decimal(check_for(s, app.state.taxes, app.state.pricing)["total"]) for s in open_states}
        plan: FloorPlan = app.state.floor
        coursing = app.state.settings.get("coursing")
        return {
            **plan.as_json(),
            "courses": coursing["courses"] if coursing["enabled"] else [],  # what a line can be coursed by now
            "status": table_status(open_states, totals),
            "cursor": store.cursor,
        }

    # Location settings: a manager (token from /admin/session) sets them, every terminal reads them ---------
    def write_setting(key: str, data: Mapping[str, Any], clean: Callable[[Mapping[str, Any]], dict[str, Any]]) -> Any:
        try:
            cleaned = clean(data)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        settings: SettingStore = app.state.settings
        try:
            return settings.put(key, cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err

    @app.get("/settings/quotes")
    def read_quotes() -> dict[str, Any]:
        """Minutes each channel promises a takeout order, and which channels may pay at pickup."""
        settings: SettingStore = app.state.settings
        return settings.get("quotes")

    @app.put("/settings/quotes")
    def write_quotes(body: QuotesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets the quote times by hand; kitchen pacing takes over in phase 2."""
        manager_from(app.state.tokens, authorization)
        return write_setting("quotes", body.model_dump(), clean_quotes)

    @app.get("/settings/coursing")
    def read_coursing() -> dict[str, Any]:
        """Whether dishes are coursed, the courses by name in kitchen order, and which one a new dish goes to."""
        settings: SettingStore = app.state.settings
        return settings.get("coursing")

    @app.put("/settings/coursing")
    def write_coursing(body: CoursingIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns coursing on or off and names the courses, as many as the kitchen serves. A course
        sent without an id is new and gets one from its name; the rest keep theirs, since order lines carry
        them. Every terminal follows on its next order."""
        manager_from(app.state.tokens, authorization)
        return write_setting("coursing", body.model_dump(), clean_coursing)

    @app.get("/settings/desk_phones")
    def read_desk_phones() -> dict[str, Any]:
        """Which screen each desk phone is linked to: `links`, a list of `{extension, device}`."""
        settings: SettingStore = app.state.settings
        return settings.get("desk_phones")

    @app.put("/settings/desk_phones")
    def write_desk_phones(body: DeskPhonesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager links desk phones to screens; each extension once. The next call answered on a linked
        phone opens the caller's order on that screen."""
        manager_from(app.state.tokens, authorization)
        saved = write_setting("desk_phones", body.model_dump(), clean_desk_phones)
        app.state.answered.links_changed()  # every screen waiting for a call hears where it stands now
        return saved

    # Desk phones: what the screens collect, and how the hub stands with the PBX ---------------------------------
    @app.get("/phones/answered")
    async def read_answered(
        device: str = Query(min_length=1),
        wait: float = Query(0, ge=0, le=30, description="seconds to hold the request for a call newer than `after`"),
        after: int = Query(0, ge=0, description="the `cursor` of this screen's last answer"),
    ) -> dict[str, Any]:
        """The outside calls answered in the last two minutes on the desk phones linked to this device, oldest
        first, each once by `id` and with its `age_ms` on the hub's clock; `linked` says whether any phone is
        linked to the device at all. With `wait`, the request is held until a call newer than `after` (the
        `cursor` of the last answer) is there, or the links change, so a pick-up reaches the screen at once.
        The app opens the caller's last order of the day for a fresh one, as it does when it picks up a call
        itself."""
        app.state.devices.heard(device)
        answered: AnsweredCalls = app.state.answered
        calls = await answered.wait(device, after=after, timeout=wait) if wait > 0 else answered.for_device(device)
        return {"device": device, "linked": answered.linked(device), "calls": calls, "cursor": answered.cursor}

    @app.get("/phones/status")
    def read_phone_status() -> dict[str, Any]:
        """The hub's link to the PBX: configured (`POS_AMI_HOST`), connected and since when, what it has seen;
        `links` counts the desk phones a manager linked."""
        answered: AnsweredCalls = app.state.answered
        pbx: AmiWatcher | None = app.state.watcher
        status = pbx.status() if pbx is not None else {"configured": False, "connected": False}
        links = app.state.settings.get("desk_phones")["links"]
        return {**status, **answered.counts, "links": len(links)}

    @app.get("/phones/extensions")
    async def read_extensions() -> dict[str, Any]:
        """The PBX's extensions, lowest first, each with `online` (a phone is registered on it), for a manager
        linking desk phones to pick from; `connected` says whether the hub reaches the PBX right now (nothing
        is listed otherwise)."""
        pbx: AmiWatcher | None = app.state.watcher
        if pbx is None:
            return {"extensions": [], "connected": False}
        return {"extensions": await pbx.extensions(), "connected": bool(pbx.status().get("connected"))}

    @app.get("/devices")
    def read_devices() -> dict[str, Any]:
        """The screens this hub hears from (every running app asks it for desk-phone answers; a sign-in counts
        too), by name with when each was last heard, for a manager to pick a screen from."""
        devices: DevicesSeen = app.state.devices
        return {"devices": devices.listed()}

    # Counter mode and takeout: the texts that went out -----------------------------------------------------

    @app.get("/messages")
    def read_messages(limit: int = Query(50, ge=1, le=500)) -> dict[str, Any]:
        """The texts this backend sent (or would have: the log messenger keeps them), newest first."""
        messenger = app.state.messenger
        sent = list(reversed(messenger.sent)) if isinstance(messenger, LogMessenger) else []
        return {"messages": [m.as_json() for m in sent[:limit]], "provider": type(messenger).__name__}

    # Discounts and charges: the rules are data, a manager approves on the spot, reports say who and why ----
    @app.get("/pricing/rules")
    def read_pricing_rules() -> dict[str, Any]:
        """The discount reasons and service charges this location allows, with their limits and who may apply them."""
        rules: PricingRules = app.state.pricing
        return rules.as_json()

    @app.post("/approvals")
    def approve(body: ApprovalIn) -> dict[str, Any]:
        """A manager's PIN for a discount or a charge on one order. The answer is a short-lived token the
        terminal puts on the operation as `approval`; the hub records who it was, never the token."""
        directory: Directory = app.state.staff
        try:
            found = directory.by_pin(body.pin, device=body.device)
        except Locked as err:
            raise HTTPException(423, {"error": "locked", "seconds": round(err.seconds_left)}) from err
        if found is None:
            raise HTTPException(401, {"error": "unknown_credential"})
        if found.role not in APPROVERS:
            raise HTTPException(403, {"error": "not_allowed", "role": found.role})
        token, grant = app.state.tokens.issue(
            found.staff_id, found.name, found.role, APPROVAL_TTL, scope=f"{body.purpose}:{body.order_id}"
        )
        return {
            "approval": token,
            "staff_id": grant.staff_id,
            "name": grant.name,
            "role": grant.role,
            "expires": grant.expires,
        }

    @app.get("/reports/adjustments")
    def report_adjustments(
        since: int = Query(0, ge=0, description="orders active since this wall-clock ms"),
    ) -> dict[str, Any]:
        """Every discount and charge on the orders, with totals by reason, by who applied it and by who
        approved it: the manager's look at what came off the register and why (architecture section 9).
        Discounts taken off again are counted, not valued."""
        store: OpStore | PgOpStore = app.state.store
        discounts: list[dict[str, Any]] = []
        charges: list[dict[str, Any]] = []
        by_reason: dict[str, Decimal] = {}
        by_staff: dict[str, Decimal] = {}
        by_approver: dict[str, Decimal] = {}
        removed = 0
        for order_id in store.order_ids():
            state = store.state(order_id)
            if state.last is None or state.last.wall_ms < since:
                continue
            check = check_for(state, app.state.taxes, app.state.pricing)
            about = {"order_id": order_id, "table": state.fields.get("table"), "status": state.status}
            for row in check["discounts"]:
                discounts.append({**about, **row})
                amount = Decimal(row["amount"])
                _tally(by_reason, row["reason"], amount)
                _tally(by_staff, row["applied_by"] or "", amount)
                _tally(by_approver, (row["approved_by"] or {}).get("name", ""), amount)
            charges.extend({**about, **row} for row in check["charges"])
            removed += sum(1 for d in state.discounts.values() if not d.active)
        return {
            "discounts": discounts,
            "charges": charges,
            "discount_total": str(sum(by_reason.values(), Decimal(0))),
            "charge_total": str(sum((Decimal(c["amount"]) for c in charges), Decimal(0))),
            "by_reason": _totals(by_reason),
            "by_staff": _totals(by_staff),
            "by_approver": _totals(by_approver),
            "removed": removed,
            "cursor": store.cursor,
        }

    # Menu: the apps show it and send choices back; prices and tax come from here --------------------------
    @app.get("/menu")
    def read_menu(channel: str = "pos", locale: str = "en") -> dict[str, Any]:
        """The menus open now for a channel. `revision` moves whenever the menu is edited."""
        menu: MenuService = app.state.menu
        menu.refresh()
        return {"menus": menu.menus(channel, locale), "revision": menu.revision}

    @app.get("/menu/revision")
    def menu_revision() -> dict[str, Any]:
        """What a terminal polls to know when to reload its menu: the revision moves on every save."""
        menu: MenuService = app.state.menu
        menu.refresh()
        return {"revision": menu.revision}

    @app.get("/menu/items")
    def read_items(channel: str = "pos", locale: str = "en") -> dict[str, Any]:
        """Every dish on the menus open now with its sizes and choices, in one read. A terminal saves them
        with the menu, so it can still take orders when no backend answers (ADR 6, capture-only mode)."""
        menu: MenuService = app.state.menu
        menu.refresh()
        return {"revision": menu.revision, "items": menu.details(channel, locale)}

    @app.get("/menu/items/{item_id}")
    def read_item(item_id: str, entry: str | None = None, locale: str = "en") -> dict[str, Any]:
        menu: MenuService = app.state.menu
        menu.refresh()
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
        """86 a size or an option (`sold_out`), or bring it back (`available`). Stored with the menu, so a
        restart keeps the board."""
        menu: MenuService = app.state.menu
        if body.target_id not in menu.defs.variants and body.target_id not in menu.defs.options:
            raise HTTPException(404, {"error": "unknown_id", "id": body.target_id})
        menu.set_availability(body.target_id, body.status, reason=body.reason, by=body.by)
        return {"items": menu.eighty_sixed()}

    @app.post("/menu/price")
    def price_line(body: PriceIn) -> dict[str, Any]:
        """A preview of one configured line, so the screen can show the price before adding it."""
        menu: MenuService = app.state.menu
        menu.refresh()
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
        app.state.devices.heard(body.device)
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
        return {
            "staff_id": found.staff_id,
            "name": found.name,
            "role": found.role,
            "method": found.method,
            "preferences": app.state.preferences.get(found.staff_id),
        }

    @app.get("/staff/{staff_id}/preferences")
    def read_preferences(staff_id: str) -> dict[str, Any]:
        """Text size, contrast and language as this staff member set them, with defaults filled in."""
        preferences: PreferenceStore = app.state.preferences
        return {"staff_id": staff_id, "preferences": preferences.get(staff_id)}

    @app.put("/staff/{staff_id}/preferences")
    def write_preferences(staff_id: str, body: PreferencesIn) -> dict[str, Any]:
        """Sets the keys given and keeps the rest, so they follow the person to the next device."""
        preferences: PreferenceStore = app.state.preferences
        try:
            saved = preferences.put(staff_id, body.model_dump(exclude_none=True))
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_preference", "message": str(err)}) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return {"staff_id": staff_id, "preferences": saved}

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
        return {"jobs": [job_out(j, due_in=printing.store.due_in(j)) for j in jobs[:200]]}

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

    add_menu_admin(app)
    add_face_signin(app)
    return app


app = create_app()
