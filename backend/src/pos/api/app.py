"""A minimal API around the operation log: append, read, pull.

The same three calls serve a terminal talking to a hub, a hub talking to the cloud, and the cloud
talking back. Phase 1 puts the store in PostgreSQL and adds WebSocket pushes; the shape stays.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import os
import threading
import time
from collections.abc import AsyncIterator, Callable, Mapping
from contextlib import asynccontextmanager
from dataclasses import replace
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import TYPE_CHECKING, Any

from fastapi import FastAPI, Header, HTTPException, Query, Response
from fastapi.encoders import jsonable_encoder
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .. import localtime
from ..addresses import Suggester, default_asked, order_of, suggester_from_env
from ..check_guests import CheckGuests, default_check_guests
from ..customers import (
    NOTE_MAX,
    SHORTEST,
    CustomerNotes,
    clean_note,
    customer_card,
    default_notes,
    same_again,
    saved_trip,
)
from ..customers import ReadOnlyError as NotesReadOnly
from ..devices import DevicesSeen
from ..floor import FloorPlan, in_turn, last_sat, load_floor, punched, said, say, table_status
from ..guest_tags import GuestTags, default_guest_tags
from ..identity.faces import FaceEngine, FaceSignIn, default_face_store
from ..identity.photos import EventPhoto, PhotoStore
from ..identity.powers import ALWAYS, May, clean_powers, holds, standard, table
from ..identity.preferences import PreferenceStore
from ..identity.staff import Directory, Locked, roster, staff_from_env
from ..identity.staff_list import StaffList, default_staff_store
from ..identity.tags import TagStore, default_tag_store, sign_in_by_tag
from ..identity.tokens import Grant, Tokens
from ..keys import HubKeys, keys_from_env
from ..maps import (
    ADDRESS_MAX,
    PURPOSES,
    LookupFailed,
    Lookups,
    Trip,
    credit_of,
    lookups_from_env,
    may_keep,
    origin_mark,
    turned_on,
)
from ..menu.service import MenuService
from ..messaging import LogMessenger, Messenger, Notifier
from ..notes import ShiftNotes, default_note_store
from ..online.gloriafood import push_key_from_env
from ..online.inbox import default_inbox
from ..online.place import own_word
from ..online.service import OnlineOrders
from ..online.wayin import WayIn, wayin_from_env
from ..orders.adjustments import APPROVAL_TTL, PricingRules, load_rules
from ..orders.ahead import orders_ahead
from ..orders.bag import bag_ops
from ..orders.callers import last_order, phone_digits
from ..orders.check import charge_snapshot, check_for
from ..orders.counts import count_ops
from ..orders.delivery_fee import band_for, fee_ops
from ..orders.exempt import exempt_ops
from ..orders.moves import carried, carry_ops
from ..orders.numbers import OrderNumbers
from ..orders.taken_off import by_check, taken_off_rows
from ..orders.typed import typed_rows
from ..orders.voids import void_ops, void_rows
from ..phones.deskphones import AmiWatcher, AnsweredCalls, watcher_from_env
from ..phones.recordings import Recordings, default_recording_store, pbx_from_env
from ..printing import discover
from ..printing.bill import SAMPLE, bill_for
from ..printing.held import default_held
from ..printing.jobs import PrintJob
from ..printing.log import default_log
from ..printing.made import kitchen_words, ready_of, with_kitchen
from ..printing.service import Printer, PrintService, printers_from_env, printers_from_setting
from ..printing.ticket import DEMO
from ..push.apns import ApnsSender
from ..push.devices import PushDevices, clean_device, default_push_devices
from ..push.relay import PushRelay
from ..reservations import Reservations, default_book_store
from ..settings import (
    DEVICE,
    EXTENSION,
    SettingStore,
    clean_bag,
    clean_bill,
    clean_coursing,
    clean_delivery_fee,
    clean_desk_phones,
    clean_drive_lookups,
    clean_kitchen_notes,
    clean_live_drive,
    clean_printers,
    clean_quotes,
    clean_rush,
    clean_table_timers,
    clean_ticket_skips,
    clean_tickets,
    clean_time_clock,
    clean_voids,
    default_settings,
    rush_now,
    skipped_stations,
)
from ..sync.hlc import HLC
from ..sync.oplog import KINDS, ClockDriftError, Discount, Op, OpStore, OrderState, apply
from ..tax import TaxProfile, load_profile
from ..texts import Listener, Texts, default_text_store
from ..timeclock import TimeClock, default_clock_store
from ..twilio import TwilioMessenger
from ..waitlist import Waitlist, default_wait_store
from ..waste import WasteLog, default_waste_store
from .addresses import add_address_list
from .auth import holder_from, manager_from, powers_of
from .calls import add_calls
from .conditional import ConditionalGet
from .contests import add_contests
from .day import add_day_report
from .faces import add_face_signin
from .feed import ChangeFeed, end_on_stop
from .guests import add_guest_list, follow_merges, names_by_check, seated_by_check
from .history import add_history
from .keys import add_hub_keys, hand_way_in, keys_mark, online_setup, sender_for, texts_for, watch_keys
from .kitchen import add_kitchen
from .menu_admin import add_menu_admin
from .notes import add_shift_notes
from .online import add_online_orders
from .prep import add_prep
from .prints import add_print_log
from .reservations import add_reservations
from .runs import add_runs
from .sales import add_sales_report
from .staff import add_staff_list, use_staff, watch_staff
from .texts import add_texts
from .timeclock import add_time_clock
from .today import add_today
from .waitlist import add_waitlist
from .waste import add_waste_log

if TYPE_CHECKING:
    from ..sync.pgstore import PgOpStore

from ..sync.pgstore import ReadOnlyError

log = logging.getLogger(__name__)


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
_NO_LATER = 10**14  # wall-clock ms some three thousand years on: later than any order is for


def polled(content: Any) -> Response:
    """The answer to a read the screens poll, written straight to JSON. Handing FastAPI the same dict has it
    walk and validate every value first, which for forty open checks took ten times as long as writing them
    (21 ms against 2 ms, measured 2026-11-12); the bytes are the same."""
    body = json.dumps(content, ensure_ascii=False, allow_nan=False, separators=(",", ":"), default=jsonable_encoder)
    return Response(body.encode("utf-8"), media_type="application/json")


_LIST_LEAVES_OUT = ("request", "priced")


def listed(state: OrderState) -> dict[str, Any]:
    """An order as a list of orders needs it: the snapshot without what each line was configured as and
    priced at, which is nine tenths of it and which only the order's own screen reads; and `opened_ms`, when
    it was opened (wall-clock ms), which a list of older checks is read by."""
    snapshot = state.snapshot()
    snapshot["lines"] = {
        line_id: {k: v for k, v in line.items() if k not in _LIST_LEAVES_OUT}
        for line_id, line in snapshot["lines"].items()
    }
    snapshot["opened_ms"] = state.first.wall_ms if state.first is not None else None
    return snapshot


class Dues:
    """What is still to pay on a to-go order that took money (`due`, as its check reckons it), for a list
    of orders: a deposit is money taken and not the whole of it, and a list that knew only "something was
    paid" would call such an order paid. Remembered under the exact state of the order's log, so a list read
    every few seconds reckons a check once; let go when the taxes or the rules are other objects, and past a
    few thousand orders."""

    def __init__(self) -> None:
        self._kept: dict[str, tuple[Any, int, str]] = {}
        self._under: tuple[Any, Any] = (None, None)
        self._lock = threading.Lock()

    def of(self, state: OrderState, taxes: TaxProfile, rules: PricingRules | None) -> str | None:
        """None for a table's check and for an order nothing was paid on: all of it is due, and a list says
        so without being told."""
        if not state.payments or str(state.fields.get("order_type") or "dine_in") == "dine_in":
            return None
        stands = (state.last, len(state.applied))
        with self._lock:
            if self._under[0] is not taxes or self._under[1] is not rules or len(self._kept) > 5000:
                self._kept.clear()
                self._under = (taxes, rules)
            kept = self._kept.get(state.order_id)
            if kept is not None and (kept[0], kept[1]) == stands:
                return kept[2]
        due = str(check_for(state, taxes, rules)["due"])
        with self._lock:
            self._kept[state.order_id] = (*stands, due)
        return due


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
    my_tables: bool | None = Field(None, description="the floor map picks out this person's own tables")


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


class PrintBillIn(BaseModel):
    """A guest's bill for an order. `printer` is the one this screen keeps for its bills, by id; without it
    the bill prints where the location's bills do. `check` asks for one of a split table's bills, by the
    check's number; without it every check of the table prints."""

    printer: str | None = Field(None, max_length=64)
    check: int | None = Field(None, ge=1)


class BillIn(BaseModel):
    """The guest's bill as a manager sets it. One left out stays as it is; `printer` null is the usual one."""

    printer: str | None = Field(None, description="the id of the printer bills print at")
    header: list[str] | None = Field(None, description="the restaurant's own lines at the top; the first big")
    footer: list[str] | None = Field(None, description="the lines that close the bill")


class AvailabilityIn(BaseModel):
    target_id: str = Field(description="a variant id (one size) or an option id")
    status: str = Field(pattern="^(available|sold_out)$")
    by: str | None = None
    reason: str | None = None
    remaining: int | None = Field(
        None, ge=1, le=999, description="with `available`, for a size: how many are left to sell tonight"
    )


class PriceIn(BaseModel):
    variant_id: str
    entry_id: str | None = None
    selections: list[dict[str, Any]] = Field(default_factory=list)
    components: list[dict[str, Any]] = Field(default_factory=list)
    notes: str | None = None
    price: str | None = Field(None, description="typed when rung, for a dish that asks its price")
    name: str | None = Field(None, description="typed when rung, for an off-menu dish")


class ApprovalIn(BaseModel):
    """A PIN on the spot, for one purpose on one order: a discount or a charge (`adjust`), the void of a dish
    the kitchen already has (`void`), or marking the check tax exempt (`exempt`). A manager's, an owner's,
    or that of anyone whose role the location handed that power to."""

    device: str
    pin: str
    purpose: str = Field("adjust", pattern="^(adjust|void|exempt)$")
    order_id: str


class QuotesIn(BaseModel):
    """How many minutes each channel promises a takeout order, and which channels may pay at pickup."""

    minutes: dict[str, int] = Field(default_factory=dict)
    pay_at_pickup: list[str] = Field(default_factory=list)
    big_orders: dict[str, int] | None = Field(
        None, description="dishes and minutes; left out (an app from before the rule) keeps what is stored"
    )


class RushIn(BaseModel):
    """The kitchen is behind: minutes added to every new quote until the night is over. 0 takes it off."""

    minutes: int = 0


class TurnIn(BaseModel):
    """A host's word on tonight's turn for a table: `server_id` is in it (`on`) or out of it, says `staff_id`."""

    staff_id: str = Field(max_length=120)
    server_id: str = Field(max_length=120)
    on: bool


class CourseIn(BaseModel):
    id: str | None = Field(None, description="left out for a course new on the screen: the hub names it from the name")
    name: str


class CoursingIn(BaseModel):
    """Whether dishes are coursed, the courses in kitchen order (any number), and where a new dish goes."""

    enabled: bool = True
    default: str | None = Field(None, description="the course a new dish goes to; the first one when left out")
    courses: list[CourseIn] = Field(default_factory=list)


class VoidReasonIn(BaseModel):
    id: str | None = Field(None, description="left out for a reason new on the screen: the hub names it from the name")
    name: str


class BagChoiceIn(BaseModel):
    id: str | None = Field(None, description="left out for a choice new on the screen: the hub names it from the name")
    name: str


class PowersIn(BaseModel):
    """Who may do what: for each power named, the roles it is handed to besides the managers and the owners.
    A power left out stays as it is."""

    roles: dict[str, list[str]] = Field(default_factory=dict)


class KitchenNotesIn(BaseModel):
    """The one-tap notes to the kitchen: short words, in the order the buttons show."""

    notes: list[str] = Field(default_factory=list)


class BagIn(BaseModel):
    """The one question asked before a to-go order is sent: whether it is asked, its words and its choices."""

    enabled: bool = True
    question: str = Field("", description="the question's words; the standard ones when left empty")
    choices: list[BagChoiceIn] = Field(default_factory=list)


class FeeBandIn(BaseModel):
    up_to: float | str = Field(description="how far the band reaches: miles to a hundredth, or whole minutes")
    fee: float | str = Field(description="what a delivery within it costs, in dollars and cents")


class DeliveryFeeIn(BaseModel):
    """What a delivery costs the customer: whether a fee is charged, what it goes by and the prices."""

    enabled: bool = False
    by: str = Field("miles", description="miles: by how far it goes; minutes: by how long the drive is")
    bands: list[FeeBandIn] = Field(default_factory=list)
    taxed: bool = Field(False, description="whether sales tax is charged on the fee")
    origin: str | None = Field(
        None,
        max_length=1000,
        description="the restaurant's own address, where a looked-up distance starts; left out: kept as it is",
    )
    custom: bool | None = Field(
        None,
        description="whether the fee of a delivery further than the last band may be typed; left out: kept as it is",
    )


class DistanceIn(BaseModel):
    address: str = Field(max_length=1000, description="where a delivery goes, as it was typed")
    phone: str = Field(
        "",
        max_length=40,
        description="the customer's number, to read the distance off their own earlier order; it stays on the hub",
    )
    fresh: bool = Field(False, description="ask the map service even when the customer's earlier order says how far")
    via: str = Field(
        "",
        max_length=24,
        description="the one map service to ask, by name, to try its key out; nothing saved or remembered answers",
    )
    now: bool = Field(
        False,
        description="the delivery is for now: also say how long the drive is at this minute, where that is turned on",
    )


class LiveDriveIn(BaseModel):
    """Live traffic for deliveries: whether a delivery for now is promised by the roads as they are."""

    enabled: bool = False
    before: int = Field(25, description="minutes for the cooking and getting the order out of the door")


class LookupServicesIn(BaseModel):
    """The map services asked one thing: which of them, and in which order. One that is left out stays as it
    is, and so does the order."""

    geocodio: bool | None = None
    google: bool | None = None
    mapbox: bool | None = None
    azure: bool | None = None
    order: list[str] | None = Field(
        None, max_length=8, description="the services' names in the order they are asked, each once"
    )


class DriveLookupsIn(BaseModel):
    """Who is asked how far a delivery goes, and who the drive right now. One that is left out stays as it is."""

    distance: LookupServicesIn | None = None
    traffic: LookupServicesIn | None = None


class VoidsIn(BaseModel):
    """What voiding a dish the kitchen already has takes: a manager's PIN or not, and the reasons to pick from."""

    approval: str = Field("manager", description="manager: a manager's PIN on the spot; none: the reason alone")
    reasons: list[VoidReasonIn] = Field(default_factory=list)


class StageTimesIn(BaseModel):
    warn: int = Field(0, description="minutes until the ring warns; 0 for never")
    late: int = Field(0, description="minutes until it is overdue; 0 for never")


class TableTimersIn(BaseModel):
    """The timer ring around each table on the floor map: whether it is drawn, and when each stage a table can
    be waiting on (sat, unsent, held, fired) warns and is overdue. A stage left out keeps the default."""

    enabled: bool = True
    stages: dict[str, StageTimesIn] = Field(default_factory=dict)


class DeskPhoneLinkIn(BaseModel):
    extension: str = Field(description="the desk phone's extension on the PBX")
    device: str = Field(description="the device name the app shows under Settings")


class PushDeviceIn(BaseModel):
    """A screen's push token: `voip` for the phone in the app (with the extension it registers as), `alert`
    for a desk-phone pick-up."""

    device: str
    platform: str
    kind: str
    token: str
    extension: str = ""


class PushTestIn(BaseModel):
    device: str
    kind: str = "alert"


class DeskPhonesIn(BaseModel):
    """Which screen each desk phone is linked to: a call taken on the phone opens the caller's order there."""

    links: list[DeskPhoneLinkIn] = Field(default_factory=list)


class PrinterIn(BaseModel):
    id: str | None = Field(None, description="left out for a printer new on the screen: the hub names it")
    station: str = Field("", description="the kitchen station it prints for, by its code, when it is only one")
    stations: list[str] = Field(default_factory=list, description="the stations it prints for (wok1, bar, takeout)")
    address: str = Field(description="host or IP, with :port when it is not 9100")
    dialect: str = Field("escpos", description="escpos, star, or auto: the language the printer was found to speak")
    detected: str | None = Field(None, description="what /print/identify said it speaks; printed in when auto")
    fallbacks: list[str] = Field(default_factory=list, description="ids of the printers that take over, in order")
    tickets: str | None = Field(
        None, description="one: its stations' dishes on one ticket; each: a ticket for each station. Left out: as saved"
    )
    groups: list[list[str]] | None = Field(
        None, description="with each: the stations that share a ticket all the same. Left out: as saved"
    )


class PrintersIn(BaseModel):
    """The location's printers in the order they stand, and the station a to-go order prints whole at."""

    printers: list[PrinterIn] = Field(default_factory=list)
    takeout_station: str | None = "takeout"


class CustomerNoteIn(BaseModel):
    """The line a person keeps about a customer ("no MSG", "side door"); empty takes it off."""

    note: str = Field(max_length=400)
    by: str | None = Field(None, max_length=80, description="who wrote it, by name")


class TicketsIn(BaseModel):
    """What a kitchen ticket says about the other tickets of the same send. One left out stays as it is."""

    numbered: bool | None = Field(None, description='"Ticket 2 of 3" when more than one station is cooking')
    also_at: bool | None = Field(None, description='"Also at: Wok 2, Sushi Bar": the other stations cooking')
    paid: bool | None = Field(None, description="PAID or NOT PAID on the takeout station's ticket of a to-go order")
    moved: bool | None = Field(None, description="a MOVED slip at the stations when food on its way changes table")
    pack: bool | None = Field(None, description="a pack sheet with a catering order's first tickets")


class TicketSkipIn(BaseModel):
    device: str = Field(description="the device name the app shows under Settings")
    stations: list[str] = Field(default_factory=list, description="the stations it prints no ticket at, by code")


class TicketSkipsIn(BaseModel):
    """The stations each screen prints no ticket at. A screen with none listed prints everywhere."""

    screens: list[TicketSkipIn] = Field(default_factory=list)


class TimeClockIn(BaseModel):
    """The time clock's setting; a key left out keeps its stored value."""

    enabled: bool | None = None
    breaks_paid: bool | None = None
    week_starts: str | None = None


class DiscoverIn(BaseModel):
    """Where to look for printers: the addresses the terminal has (its own and the hub's) name the subnets,
    with any given outright; the hub adds its printers' and its own."""

    addresses: list[str] = Field(default_factory=list)
    subnets: list[str] = Field(default_factory=list)
    port: int = Field(9100, ge=1, le=65535)


class IdentifyIn(BaseModel):
    address: str


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
    the batch is kept, so a terminal's outbox never loses good operations behind a bad one. A dish that came
    from another check (`pos.orders.moves`) keeps the price it was sold at there, whatever the menu says now."""
    out: list[Op] = []
    refused: list[dict[str, Any]] = []
    for op in ops:
        if op.kind == "add_line" and isinstance(op.data.get("request"), dict) and not carried(op):
            data = {k: v for k, v in op.data.items() if k != "priced"}
            priced, blocking = sellable(menu, data["request"], counted_out=False)
            if priced is None:
                refused.append({"op_id": op.op_id, "error": "invalid_line", "problems": blocking})
                continue
            data["priced"] = priced
            data["item"] = priced["name"]
            op = replace(op, data=data)
        out.append(op)
    return out, refused


WARNINGS: frozenset[str] = frozenset()
"""Problem codes a line may still be sold with; none yet, so every problem stops the sale."""


COUNTED_OUT = "none_left"
"""The menu's problem for a dish whose number left is at zero. It stops a new sale, but a line arriving at
the hub is not judged by it: whether one is left for that line is weighed against what the checks hold
(`pos.orders.counts`), so the last one of a dish can still be changed after it sold out."""


def sellable(
    menu: MenuService, request: dict[str, Any], *, counted_out: bool = True
) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    """The line as the menu prices it now, or None with the problems that stop its sale (a required choice
    missing, an 86'd dish, an id the menu does not know). With `counted_out` false a dish whose number left
    is at zero is priced all the same, and the caller weighs it (`count_ops`)."""
    try:
        priced = menu.priced(request)
        if not counted_out:
            priced["problems"] = [p for p in priced["problems"] if p["code"] != COUNTED_OUT]
        blocking = [p for p in priced["problems"] if p["code"] not in WARNINGS]
    except (KeyError, ValueError, TypeError) as err:
        return None, [{"code": "bad_request", "message": str(err)}]
    return (None, blocking) if blocking else (priced, [])


ADJUSTMENTS = frozenset({"discount", "remove_discount", "charge", "remove_charge"})


def adjust_ops(
    rules: PricingRules, tokens: Tokens, store: OpStore | PgOpStore, ops: list[Op], may: May = standard
) -> tuple[list[Op], list[dict[str, Any]]]:
    """Check every new discount and charge against the location's rules before it is stored. A manager's
    approval travels as a token (`approval`, from POST /approvals, good for one order) and is swapped for
    `approved_by`, who it was, so the check and the reports name the manager; nothing a terminal says about
    approval on its own is kept. `may` says whether a role holds the power to approve one (`adjust`) at this
    location: a manager and an owner always, and whoever the location handed it to. An adjustment the rules
    refuse (an unknown reason, over its cap, no manager when one is needed, a second discount on a dish that
    does not stack) is left out and reported with its problems, like a refused line; the rest of the batch
    goes through. The line operations earlier in the same batch count (a terminal back from an outage sends
    a void and a later discount together)."""
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
        approved = grant is not None and grant.scope == f"adjust:{op.order_id}" and may(grant.role, "adjust")
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
        elif op.kind == "discount" and "from" in op.data:
            # the discount of a dish that came from another check: it was judged when it was given there, and
            # comes along as it is (its reason, what it takes off, who approved it), on that dish alone
            source = _came_along(store, state, data)
            if source is None:
                problems = [{"code": "unknown_source", "message": "That discount is not on the dish as it came over."}]
                refused.append({"op_id": op.op_id, "error": "invalid_adjustment", "problems": problems})
                continue
            # who brought it over and whether a hub answered then are the terminal's to say (a check's history
            # tells them); the rest is read from where it comes from
            told = {k: data[k] for k in ("by", "by_id", "offline") if k in data}
            data = {"discount_id": ident, "line_id": data["line_id"], "from": data["from"], **told, **source}
            live[ident] = {"reason": data["reason"], "line_id": data["line_id"]}
            state.discounts[ident] = Discount(discount_id=ident, line_id=data["line_id"], carried_from=data["from"])
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


def _came_along(store: OpStore | PgOpStore, state: OrderState, data: dict[str, Any]) -> dict[str, Any] | None:
    """What the discount a `discount` operation says it continues (`from`: order_id, discount_id) reads on the
    check it comes from, to be written on this one: None unless that discount stands there on the very dish
    this operation's line came from, and has not been brought over already."""
    came = data.get("from")
    line = state.lines.get(data.get("line_id")) if isinstance(data.get("line_id"), str) else None
    if not isinstance(came, dict) or line is None or not line.active or line.moved_from is None:
        return None
    order_id, discount_id = came.get("order_id"), came.get("discount_id")
    if not isinstance(order_id, str) or not isinstance(discount_id, str) or order_id != line.moved_from["order_id"]:
        return None
    source = store.view(order_id)
    there = source.discounts.get(discount_id) if source is not None else None
    if source is None or there is None or not there.active or not there.line_id:
        return None
    if source.current_line(there.line_id) != line.moved_from["line_id"]:
        return None
    again = {"order_id": order_id, "discount_id": discount_id}
    if any(d.active and d.carried_from == again for d in state.discounts.values()):
        return None
    data["from"] = again
    return {
        "reason": there.reason,
        "kind": there.kind,
        "value": there.value,
        "note": there.note,
        "applied_by": there.applied_by,
        "approved_by": there.approved_by,
    }


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


def _void_totals(voids: list[dict[str, Any]], key: Callable[[dict[str, Any]], str]) -> list[dict[str, Any]]:
    """The voids added up under `key` (a reason, a name): what they were worth and how many, the most first."""
    totals: dict[str, tuple[Decimal, int]] = {}
    for row in voids:
        amount, count = totals.get(key(row), (Decimal(0), 0))
        totals[key(row)] = (amount + Decimal(row["amount"]), count + 1)
    ranked = sorted(totals.items(), key=lambda kv: (-kv[1][0], kv[0]))
    return [{"key": name, "amount": str(amount), "count": count} for name, (amount, count) in ranked]


NO_NAME = "the restaurant"
"""What a location is called in a text to a customer until `POS_LOCATION` names it; never printed on a bill."""


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
        "fallbacks": [address for address, _ in job.fallbacks],
        "moved": job.moved,
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
    lookups: Lookups | None = None,
    suggester: Suggester | None = None,
    location: str | None = None,
    numbers: OrderNumbers | None = None,
    today: Callable[[], date] | None = None,
    answered: AnsweredCalls | None = None,
    watcher: AmiWatcher | None = None,
    devices: DevicesSeen | None = None,
    faces: FaceSignIn | None = None,
    tags: TagStore | None = None,
    push_devices: PushDevices | None = None,
    pusher: ApnsSender | None = None,
    relay: PushRelay | None = None,
    feed: ChangeFeed | None = None,
    customers: CustomerNotes | None = None,
    guest_tags: GuestTags | None = None,
    check_guests: CheckGuests | None = None,
    clock: TimeClock | None = None,
    notes: ShiftNotes | None = None,
    waste: WasteLog | None = None,
    waitlist: Waitlist | None = None,
    reservations: Reservations | None = None,
    online: OnlineOrders | None = None,
    keys: HubKeys | None = None,
    wayin: WayIn | None = None,
    staff_list: StaffList | None = None,
    recordings: Recordings | None = None,
    texts: Texts | None = None,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        """The PBX watcher runs for as long as the API does, when a PBX is configured; the face models load
        on a thread meanwhile, when the hub has them (POS_FACE_MODELS); GloriaFood is asked for online orders
        every minute, when the hub has its key (with only the key for its pushes the round still runs, for
        the orders to try again); the push relay's connection to Apple closes with the API; the screens'
        streams end when the server is told to stop, so it can."""
        pbx: AmiWatcher | None = app.state.watcher
        if pbx is not None:
            pbx.start()
        if recordings is None:
            app.state.recordings.start()  # looks at the PBX's call recordings, where the hub is linked to them
        if faces is None:
            app.state.faces.start(FaceEngine.from_env)
        if texts is None and messenger is None:
            # Twilio is asked for the texts that came to the restaurant's number (docs/text-inbox.md), only
            # where the API is serving. Nothing without a Twilio account; one typed in the app later starts
            # the asking (`use_texts`).
            app.state.listens_texts = True
            if isinstance(app.state.messenger, TwilioMessenger):
                app.state.text_listener.start()
        if online is None:
            # Only where the API is serving, never where this module is merely loaded: an order GloriaFood
            # hands over is put on the POS and printed by the one that asked. Nothing without a key.
            app.state.online.start()
            app.state.asks_online = True  # and a key typed in the app later starts the asking (`use_keys`)
            # The push door and the tunnel run beside the API and are told their secrets by it: the key for
            # pushes and the tunnel's token in force now, from the app or from the hub's own file.
            try:
                hand_way_in(app)
            except Exception as err:  # noqa: BLE001 - the API starts without it, and tries again within the minute
                log.warning(
                    "the way in: the door and the tunnel could not be told at the start (%s)", type(err).__name__
                )
                app.state.keys_mark = ""  # so that the next look at the keys puts them all to work (`watch_keys`)
        # A key typed on the location's other hub, or taken back with hubctl, is found within the minute.
        watching = asyncio.create_task(watch_keys(app)) if keys is None else None
        # So is a change of the staff: made on the other hub, or a PIN set with `hubctl staff pin`.
        watching_staff = asyncio.create_task(watch_staff(app)) if staff is None and staff_list is None else None
        unhook = end_on_stop(app.state.feed)
        try:
            yield
        finally:
            unhook()
            if watching is not None:
                watching.cancel()
            if watching_staff is not None:
                watching_staff.cancel()
            if pbx is not None:
                await pbx.stop()
            await app.state.relay.close()
            await app.state.wayin.close()
            hang_up = getattr(app.state.messenger, "close", None)
            if callable(hang_up):
                hang_up()  # the texts still in the line are dropped with the hub

    app = FastAPI(title="POS backend", version="0.1.0 (phase 1)", lifespan=lifespan)
    app.state.menu = menu if menu is not None else default_menu()
    app.state.taxes = taxes if taxes is not None else load_profile()
    app.state.pricing = pricing if pricing is not None else load_rules()
    app.state.floor = floor if floor is not None else load_floor()
    app.state.store = store if store is not None else default_store()
    # The staff: the list a manager keeps in the app once anything was changed there, and until then the
    # hub's own (`POS_STAFF`, or the demo staff). One directory for as long as the hub runs: a change of the
    # staff is put into it where it stands (`pos.identity.staff_list`, `use_staff`; docs/staff.md).
    if staff_list is not None:
        app.state.staff_list = staff_list
        app.state.staff = staff if staff is not None else Directory([])
    elif staff is not None:  # a directory handed in is the staff, and what is changed is kept in memory
        app.state.staff_list = StaffList(own=staff.all())
        app.state.staff = staff
    else:
        own, source = staff_from_env()
        app.state.staff_list = StaffList(default_staff_store(), own=own, source=source)
        app.state.staff = Directory(own)
    try:
        use_staff(app, sweep=False)
        if staff is None and app.state.staff_list.source() == "app" and (os.environ.get("POS_STAFF") or "").strip():
            log.warning("staff: the list is kept in the app; POS_STAFF in the hub's file is not read any more")
    except Exception as err:  # noqa: BLE001 - the hub starts with its own list, and looks again within the minute
        log.warning("staff: the list could not be read at the start (%s)", type(err).__name__)
        app.state.staff_mark = ""
    app.state.photos = photos if photos is not None else PhotoStore()
    app.state.preferences = preferences if preferences is not None else default_preferences()
    app.state.tokens = tokens if tokens is not None else Tokens()

    def on_staff(grant: Grant) -> bool:
        person = app.state.staff.get(grant.staff_id)
        if person is None:
            return False
        # a manager made an owner (or an owner a manager) may do everything either way: their session goes on
        return person.role == grant.role or {person.role, grant.role} <= ALWAYS

    app.state.tokens.still = on_staff
    app.state.dues = Dues()  # what is still to pay on the to-go orders a list names
    app.state.settings = settings if settings is not None else default_settings()
    # The change feed: what the screens hold open instead of polling (see `feed`). It tells what arrives in
    # the log, whoever wrote it, and what the menu says changed: a save, one made on another hub, the 86 board.
    app.state.feed = feed if feed is not None else ChangeFeed()
    app.state.feed.follow(app.state.store, also=lambda: app.state.menu.refresh())
    app.state.menu.on_change = lambda: app.state.feed.changed("menu")

    def printers_now() -> list[Printer]:
        """The manager's printers; a hub whose setting is still empty prints as POS_PRINTERS says."""
        return printers_from_setting(app.state.settings.get("printers")) or printers_from_env()

    app.state.printing = (
        printing
        if printing is not None
        # what waits of the orders sent ahead of their time is kept in the database: a restart loses nothing;
        # so is the log of what was printed (`pos.printing.log`)
        else PrintService(
            printers_now,
            direct=os.environ.get("POS_PRINT_DIRECT", "1") != "0",
            held=default_held(),
            log=default_log(),
        )
    )
    # The keys for the services outside the building: a manager's, typed in the app, over the hub's own file
    # (`pos.keys`, docs/hub-keys.md). `outside` is the hub's environment as it reads with them in it.
    app.state.keys = keys if keys is not None else keys_from_env()
    # The texts to customers go out through Twilio once a manager typed the restaurant's account in the app,
    # and are only written to the log until then (docs/texts.md). The messenger is exchanged where it stands
    # when the account changes (`use_texts`), unless one was handed in here.
    app.state.texts_given = messenger is not None
    app.state.texts_made_with = {}
    app.state.messenger = messenger if messenger is not None else texts_for(app.state.keys)
    # The conversations by text (docs/text-inbox.md): every text to and from the restaurant's number, by the
    # customer's number. The messenger writes down in them what it sends (it is their `keeper`), and what
    # Twilio says came is written down by the listener, which asks it every few seconds.
    app.state.texts = (
        texts
        if texts is not None
        else Texts(
            default_text_store(),
            # what the orders call a number, for a conversation that begins with the customer's own text
            name_of=lambda digits: str(
                customer_card(app.state.store, app.state.customers, digits, total=lambda state: "")["name"]
            ),
            on_change=lambda: app.state.feed.changed("texts"),
            now=lambda: app.state.store.now_ms() / 1000,  # the clock the orders go by
        )
    )
    if isinstance(app.state.messenger, TwilioMessenger) and app.state.messenger.keeper is None:
        app.state.messenger.keeper = app.state.texts
    app.state.text_listener = Listener(
        app.state.texts,
        lambda: app.state.messenger if isinstance(app.state.messenger, TwilioMessenger) else None,
        now=lambda: app.state.store.now_ms() / 1000,
        screens=lambda: app.state.feed.screens,
    )
    app.state.listens_texts = False
    outside = app.state.keys.environ()
    app.state.keys_mark = keys_mark(app.state.keys, app.state.settings)
    app.state.asks_online = False
    # how far a delivery goes, asked of a map service when the hub has a key for one (docs/delivery.md)
    app.state.lookups = lookups if lookups is not None else lookups_from_env(outside)
    # the list of addresses under a box that is being typed in asks the same Google key, and Mapbox and Azure
    # Maps when Google gives no answer; how often each was asked this month is counted in the database
    # (pos.addresses)
    app.state.suggester = suggester if suggester is not None else suggester_from_env(outside, asked=default_asked())
    # Mapbox may not be asked where the restaurant stands (nothing of its answers may be kept): it is told what
    # Geocodio says, whose answers may be kept and used with anybody's map
    app.state.suggester.place_with(app.state.lookups.locate)
    # Mapbox and Azure Maps search for where a delivery's address stands before they can say the drive to it:
    # counted against the same month's free amount as the list's own askings
    app.state.lookups.count_with(app.state.suggester.spend)
    app.state.location = location if location is not None else os.environ.get("POS_LOCATION") or NO_NAME
    if texts is None:
        # who the first text to a number says it is from; a hub without a name says nothing there
        app.state.texts.location = app.state.location if app.state.location != NO_NAME else ""
    # The location's day (POS_TIMEZONE): order numbers count through it, and a caller's orders are looked up in it.
    app.state.today = today if today is not None else localtime.today
    app.state.numbers = numbers if numbers is not None else OrderNumbers(app.state.store, today=app.state.today)
    # The one line kept about a customer, by phone number; the rest of a customer is read from the order log.
    app.state.customers = customers if customers is not None else default_notes()
    # The tags a manager puts on a guest, by phone number too (docs/guest-list.md).
    app.state.guest_tags = guest_tags if guest_tags is not None else default_guest_tags()
    # Who sat on which check, by phone number: what the guest list counts a seated party's visit from.
    app.state.check_guests = check_guests if check_guests is not None else default_check_guests()
    # Desk phones: the links are the manager's setting, read when a phone answers; the watcher needs POS_AMI_HOST.
    app.state.answered = (
        answered
        if answered is not None
        else AnsweredCalls(
            lambda: {link["extension"]: link["device"] for link in app.state.settings.get("desk_phones")["links"]}
        )
    )
    # Push relay: the screens' push tokens, the Apple key (`hubctl push apple`) and what turns a ring into a push.
    app.state.push_devices = push_devices if push_devices is not None else default_push_devices()
    app.state.relay = (
        relay
        if relay is not None
        else PushRelay(app.state.push_devices, pusher if pusher is not None else sender_for(app.state.keys))
    )
    app.state.watcher = watcher if watcher is not None else watcher_from_env(app.state.answered, app.state.relay)
    # Call recordings on phone orders (docs/call-recordings.md): the PBX records, the hub reads what it has
    # (POS_PBX_RECORDINGS, written by `hubctl pbx recordings link`). The watcher says when a call has ended,
    # so its recording is found a few seconds later.
    app.state.recordings = (
        recordings if recordings is not None else Recordings(default_recording_store(), pbx_from_env())
    )
    if app.state.watcher is not None:
        app.state.watcher.on_call_end = app.state.recordings.call_ended
    app.state.recordings.on_change = lambda: app.state.feed.changed("calls")  # an open order shows its new call
    app.state.devices = devices if devices is not None else DevicesSeen()  # the screens the hub hears from
    # Face sign-in: templates in the database, the location's switch in its settings, the models from the image.
    app.state.faces = (
        faces
        if faces is not None
        else FaceSignIn(
            default_face_store(), app.state.staff.get, enabled=lambda: app.state.settings.get("faces")["enabled"]
        )
    )
    # The time clock: who is on the clock, their breaks, and the log of every change to them.
    app.state.clock = clock if clock is not None else TimeClock(default_clock_store())
    # Notes for the shift (each person sees one once) and the manager's log.
    app.state.notes = notes if notes is not None else ShiftNotes(default_note_store())
    # The waste log: food that was not sold, written down beside the orders and never part of them.
    app.state.waste = waste if waste is not None else WasteLog(default_waste_store())
    # The waitlist: the parties waiting for a table tonight, and how each went off the list.
    app.state.waitlist = waitlist if waitlist is not None else Waitlist(default_wait_store())
    # The reservation book: the tables booked ahead, a day at a time, and how each booking ended.
    app.state.reservations = reservations if reservations is not None else Reservations(default_book_store())
    # Online orders: asked of GloriaFood every minute when the hub has its key, and put on the POS.
    # Sent by GloriaFood itself too, the moment one is accepted, when the hub has the key its pushes carry.
    # A restaurant with several accounts there has a key for each, and every one is asked (`online_setup`).
    if online is not None:
        app.state.online = online
    else:
        sources, accounts = online_setup(app.state.keys, app.state.settings)
        pushes = push_key_from_env(outside)  # typed in the app, or in the hub's own file
        app.state.online = OnlineOrders(sources, default_inbox(), push_key=pushes, accounts=accounts)
    # What the API hands the push door and the tunnel, and hears back (`pos.online.wayin`). Nothing on a
    # machine that runs neither.
    app.state.wayin = wayin if wayin is not None else wayin_from_env()
    # Staff tags: a badge held to a reader at the terminal, kept by the person's id, never by name.
    app.state.tags = tags if tags is not None else default_tag_store()
    app.state.notifier = Notifier(
        app.state.messenger,
        location=app.state.location,
        unpaid=lambda state: Decimal(check_for(state, app.state.taxes, app.state.pricing)["due"]) > 0,
    )
    # The kitchen ticket says "Course: Appetizers", as the manager named it, where a line only carries the id.
    app.state.printing.course_names = lambda: {
        c["id"]: c["name"] for c in app.state.settings.get("coursing")["courses"]
    }
    # The ticket is headed with the station's name as the menu has it, and a to-go order prints whole at the
    # takeout station the manager chose.
    app.state.printing.station_names = lambda: {
        code: app.state.menu.defs.localizer.text(st.names, "en") for code, st in app.state.menu.defs.stations.items()
    }
    app.state.printing.takeout_station = lambda: app.state.settings.get("printers")["takeout_station"]
    # An allergy told at the table prints by the allergen's name as the menu has it.
    app.state.printing.allergen_names = lambda: {
        code: app.state.menu.defs.localizer.text(a.names, "en") for code, a in app.state.menu.defs.allergens.items()
    }
    # Whether a ticket says "Ticket 2 of 3" and "Also at: Wok 2, Sushi Bar" is the manager's to say.
    app.state.printing.ticket_words = lambda: app.state.settings.get("tickets")
    # A screen can be told to print no ticket at some stations: the bar's own screen and the bar printer.
    app.state.printing.skips = lambda device: skipped_stations(app.state.settings.get("ticket_skips"), device)
    # The takeout counter's copy of a to-go order says PAID or NOT PAID, by the check as the hub reckons it.
    app.state.printing.check_of = lambda state: check_for(state, app.state.taxes, app.state.pricing)
    # A guest's bill prints at the printer the manager chose for bills, unless the screen asks for its own.
    app.state.printing.bill_place = lambda: app.state.settings.get("bill")["printer"]
    # A ticket that waited for its order's time is made from the order as the log has it then.
    app.state.printing.state_of = lambda order_id: app.state.store.view(order_id)
    if printing is None:
        if app.state.printing.held.fresh:
            try:
                # orders sent ahead before this hub wrote down what waits: their tickets were in its memory
                ahead = app.state.store.index(promised=(app.state.store.now_ms(), _NO_LATER))
                app.state.printing.adopt(app.state.store.views(ahead))
            except Exception:  # noqa: BLE001 - a hub starts whatever its printing does
                pass
        app.state.printing.start_retrying()
    # Phase 0: the Flutter web build runs from another origin; phase 1 narrows this to the apps' origins.
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    # A read that is the same as the one a screen already has is answered 304, with no body (see the module).
    app.add_middleware(ConditionalGet)
    # Every dish's choices at once (`/menu/items`) is over ten megabytes of JSON for this menu and a couple of
    # hundred kilobytes compressed (the same rolls over and over); the menu itself a couple of hundred kilobytes.
    # A client that accepts gzip (the app does) gets it compressed; one that does not gets it as before. Level
    # 5, not the default 9: the open orders go out to every screen whenever one of them changes, and the last
    # levels cost the hub four times the work for a twentieth off the size (7.5 ms against 1.9 ms for forty
    # checks, measured 2026-11-12).
    app.add_middleware(GZipMiddleware, minimum_size=1024, compresslevel=5)

    @app.get("/health")
    def health() -> dict[str, Any]:
        """`role` is primary (takes orders), replica (reads only, a standby hub) or memory (no database);
        `screens` counts the terminals holding the change feed open (`/live`) on this process."""
        store = app.state.store
        role = getattr(store, "role", "memory")
        return {
            "status": "ok",
            "cursor": store.cursor,
            "role": role,
            "node": os.environ.get("POS_NODE", ""),
            "screens": app.state.feed.screens,
        }

    @app.get("/live")
    def live(device: str = Query("", max_length=120)) -> StreamingResponse:
        """The change feed: a stream of server-sent events a screen holds open instead of polling. `hello`
        first, with the log's cursor, the menu's revision and how often the hub writes when there is no news
        (`heartbeat`, seconds); then a `changed` naming the orders that changed and the `topics` (`menu`,
        `settings`) whenever something does, and a comment line every `heartbeat` seconds otherwise. The
        screen reads what changed with the calls it always used, and reads everything once on `hello` (and
        on a `changed` with `everything`). See `pos.api.feed`."""
        if device:
            app.state.devices.heard(device)
        store = app.state.store
        hello = {
            "cursor": store.cursor,
            "menu": app.state.menu.revision,
            "role": getattr(store, "role", "memory"),
            "node": os.environ.get("POS_NODE", ""),
        }
        return StreamingResponse(
            app.state.feed.stream(hello),
            media_type="text/event-stream",
            # Not kept by anything on the way, and not held back by a proxy that buffers (nginx reads the last).
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )

    def may(role: str, power: str) -> bool:
        """Whether a role holds a power at this location now (`pos/identity/powers.py`)."""
        return holds(powers_of(app.state), role, power)

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
        # a dish changing checks first: it is filled in from the check it comes from, and keeps its price
        # where an order came from online is the hub's to say (pos.online.place): a screen's word is dropped
        fresh = [own_word(op.to_op()) for op in ops if op.op_id not in store]
        fresh, refused_moves = carry_ops(store, fresh)
        fresh, refused = price_lines(app.state.menu, fresh)
        refused = refused_moves + refused
        fresh, refused_voids = void_ops(lambda: app.state.settings.get("voids"), app.state.tokens, store, fresh, may)
        # a check marked tax exempt: a manager's PIN, the organisation and its certificate, before any money
        fresh, refused_exemptions = exempt_ops(app.state.tokens, store, fresh, may)
        # what goes in the bag with a to-go order: the answer is tidied, or left out when it cannot be read
        fresh, refused_bags = bag_ops(fresh)
        # what a delivery costs: a screen names the band, the hub fills in what that band costs here now
        fresh, refused_fees = fee_ops(lambda: app.state.settings.get("delivery_fee"), fresh)
        refused += refused_exemptions + refused_bags + refused_fees
        # The numbers left on counted dishes: weighed, stored and taken off as one step, so two screens cannot
        # both sell the last one. While no dish has a number nothing is held and nothing is read.
        with app.state.menu.counting():
            fresh, refused_counts, taken = count_ops(app.state.menu, store, fresh)
            fresh, refused_adjustments = adjust_ops(app.state.pricing, app.state.tokens, store, fresh, may)
            fresh, refused_payments = pay_ops(fresh)
            fresh = number_orders(app.state.numbers, fresh)
            refused += refused_voids + refused_counts + refused_adjustments + refused_payments
            try:
                accepted = store.append(fresh)
            except ClockDriftError as err:
                raise HTTPException(422, {"error": "clock_drift", "op_id": err.op.op_id}) from err
            except ReadOnlyError as err:
                # A standby hub: the terminal moves to the next address and comes back when this one is promoted.
                raise HTTPException(503, {"error": "read_only"}) from err
            app.state.menu.take(taken)
        if accepted:
            # two tables put together: the party seated on the emptied check sits on the one that was kept
            follow_merges(app.state, accepted)
            app.state.feed.poke()  # the other screens hear of it now, before the tickets print
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
    def list_orders(
        status: str | None = Query(None, pattern="^(open|closed|void)$"),
        hours: float | None = Query(None, gt=0, le=24 * 366, description="only orders changed this recently"),
        day: str | None = Query(None, pattern=r"^\d{4}-\d{2}-\d{2}$", description="only that day's service"),
        brief: bool = Query(False, description="lines without `request` and `priced`, with `opened_ms`"),
    ) -> Response:
        """Every order the store knows, newest activity first; `status` filters. With `hours`, the orders
        that changed within that many hours and, whatever their age, the ones still open: what a screen
        lists, the same size on the hub's thousandth day as on its first. With `day` (which `hours` then
        adds nothing to), the orders opened during that day's service, four in the morning to four the next,
        the location's time: what a manager looks through to find an older check. With `brief`, each line
        comes without what it was configured as and priced at: a list shows neither, and they are most of
        the answer. A `brief` check the host seated a party on, from its reservation or the waitlist, says
        whose it is: `seated`, the names of its parties, the first to sit first
        (`pos.api.guests.names_by_check`). The names are read from the book and the waitlist each time and
        are on no order; the number and the note are not told. The orders come from the log's index and are
        replayed only when they changed, so a screen asking every two seconds costs a query."""
        store: OpStore | PgOpStore = app.state.store
        if day is not None:
            try:
                start, end = localtime.service_day(date.fromisoformat(day))
            except ValueError as err:
                raise HTTPException(422, {"error": "bad_value", "message": "That is not a day."}) from err
            opened = store.index(status=status, opened_since=start)
            entries = [entry for entry in opened if entry.first_ms is not None and entry.first_ms < end]
        elif hours is None:
            entries = store.index(status=status)
        else:
            entries = store.index(status=status, active_since=store.now_ms() - int(hours * 3_600_000))
            if status in (None, "open"):
                recent = {entry.order_id for entry in entries}
                entries += [entry for entry in store.index(status="open") if entry.order_id not in recent]
        states = sorted(store.views(entries), key=lambda state: state.last or _NEVER, reverse=True)
        if not brief:
            return polled({"orders": [state.snapshot() for state in states], "cursor": store.cursor})
        # whose table it is, where the host seated a party from the book or the waitlist: read, not kept
        named = names_by_check(app.state, (state.order_id for state in states))
        orders = []
        for state in states:
            order = listed(state)
            # a to-go order that took money says what is still to pay: a deposit is not the whole of it
            due = app.state.dues.of(state, app.state.taxes, app.state.pricing)
            if due is not None:
                order["due"] = due
            if state.order_id in named:
                order["seated"] = named[state.order_id]
            orders.append(order)
        return polled({"orders": orders, "cursor": store.cursor})

    @app.get("/orders/ahead")  # before /orders/{order_id}, which would take "ahead" for an id
    def read_orders_ahead() -> Response:
        """The orders still to come, by the day each is for (`pos.orders.ahead`): every to-go order the
        customer named a time for that was not voided or handed over, an open one however late it is, a
        closed one while its time is still ahead. `days` is `[{day, orders, count, guests, unsent, total,
        paid, due}]`, the earliest first; an order says who and when, how it leaves (`handover`, `address`,
        `event_note`, `guests`), its `dishes` and how many of them nobody sent (`unsent`), `items` by name,
        and `total`, `paid` and `due` as its check reckons them. Anyone at a terminal may read it, like the
        list of orders."""
        store: OpStore | PgOpStore = app.state.store
        now_ms = store.now_ms()
        entries = {entry.order_id: entry for entry in store.index(status="open")}
        for entry in store.index(promised=(now_ms, _NO_LATER)):
            entries.setdefault(entry.order_id, entry)
        states = store.views(list(entries.values()))
        return polled(orders_ahead(states, now_ms=now_ms, taxes=app.state.taxes, rules=app.state.pricing))

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
    def read_order(order_id: str) -> Response:
        """An order as the log replays it. A dish the kitchen has spoken of carries its word under `kitchen`
        (`pos.printing.made`): the stations that cook it and whether each has `made` its part (`cooks`), when
        it was ready (`ready_ms`: every one of them has) and when it went out (`out_ms`). A dish nobody
        marked has none, so a kitchen that works off paper answers as it always did."""
        store: OpStore | PgOpStore = app.state.store
        state = store.view(order_id)
        if state is None:
            raise HTTPException(404, "no such order")
        printing: PrintService = app.state.printing
        words = kitchen_words(state, skips=printing.skips, station_names=printing.station_names())
        return polled(with_kitchen(state.snapshot(), words))

    @app.get("/orders/{order_id}/again")
    def read_same_again(order_id: str) -> dict[str, Any]:
        """A past order's dishes for a new order to start from ("same again"): `lines`, each with its
        choices as they were (`request`), what one costs today (`unit_price`) and what it cost then
        (`was`); and `missing`, the dishes the menu no longer sells that way, each with `why`. Nothing is
        added here: the terminal appends an `add_line` for each line, and the hub prices them again."""
        store: OpStore | PgOpStore = app.state.store
        state = store.view(order_id)
        if state is None:
            raise HTTPException(404, "no such order")
        app.state.menu.refresh()
        return same_again(state, lambda request: sellable(app.state.menu, request))

    @app.get("/customers/lookup")
    def read_customer(phone: str = Query(min_length=1, max_length=40)) -> dict[str, Any]:
        """The customer at this number, for the screen that takes their call: `name` (from their latest
        order), `orders` (how many, voided ones apart), `first_ms` and `last_ms`, the `note` kept about
        them, the `tags` a manager put on them in the guest list, and `recent`, their latest orders with
        dishes, each with its `total` and `items`. Numbers match by their digits. `known` is false for a
        number that never ordered and has no note and no tag. `points` is how many points they have
        (`pos.orders.points`), or null where the owner never set a rate."""
        store: OpStore | PgOpStore = app.state.store
        card = customer_card(
            store,
            app.state.customers,
            phone,
            total=lambda state: check_for(state, app.state.taxes, app.state.pricing)["total"],
            tags=app.state.guest_tags,
        )
        # how many points they have, where the owner set a rate (docs/points.md); null where none was ever set
        try:
            card["points"] = app.state.points_of(card["phone"])
        except Exception:  # noqa: BLE001 - the card is told whether or not the points can be read
            log.exception("a customer's points could not be read")
            card["points"] = None
        return card

    @app.get("/customers/tags")
    def read_customer_tags(phone: str = Query(min_length=1, max_length=40)) -> dict[str, Any]:
        """The `tags` a manager put on this number in the guest list, and nothing else about it: what a
        screen shows while the number's call still rings, before anybody has picked it up. Numbers match
        by their digits (`phone`); none for a number nobody tagged. It opens no order and names nobody,
        so every screen that rings can ask it."""
        digits = phone_digits(phone)
        carried = app.state.guest_tags.get(digits) if digits else None
        return {"phone": digits, "tags": list(carried["tags"]) if carried else []}

    @app.put("/customers/{phone}")
    def save_customer(phone: str, body: CustomerNoteIn) -> dict[str, Any]:
        """Keeps the one line about the customer at this number (an empty one takes it off). Anyone at a
        terminal may write it, as anyone may take the order; it records who did."""
        digits = phone_digits(phone)
        if len(digits) < SHORTEST:
            raise HTTPException(422, {"error": "bad_value", "message": "That is not a phone number."})
        note = clean_note(body.note)
        store: OpStore | PgOpStore = app.state.store
        try:
            kept = app.state.customers.put(digits, note, by=(body.by or "").strip(), at_ms=store.now_ms())
        except NotesReadOnly as err:
            # A standby hub: the terminal moves to the next address, as for an order.
            raise HTTPException(503, {"error": "read_only"}) from err
        return {"phone": digits, "note": kept["note"], "max": NOTE_MAX}

    @app.get("/orders/{order_id}/check")
    def read_check(order_id: str) -> Response:
        """What the table owes: priced lines, discounts, charges, subtotal, tax lines by jurisdiction, total."""
        store: OpStore | PgOpStore = app.state.store
        state = store.view(order_id)
        if state is None:
            raise HTTPException(404, "no such order")
        # `moves`: this hub can pass a dish from one check to another (pos.orders.moves), so a screen may offer it;
        # `exempts`: it can mark a check tax exempt (pos.orders.exempt)
        return polled({**check_for(state, app.state.taxes, app.state.pricing), "moves": True, "exempts": True})

    @app.post("/orders/{order_id}/bill", status_code=202)
    def print_bill(order_id: str, body: PrintBillIn | None = None) -> dict[str, Any]:
        """Prints the guest's bill for the order: its check as `GET /orders/{id}/check` reckons it at this
        moment, under the location's own lines. It prints at the printer asked for, else where the location's
        bills print; `printed_at` says which (its id and name). An order of any status prints (a closed one
        is a copy for the guest). A table that pays on several checks gets a bill for each (`bills` says how
        many, `jobs` lists them), or the one asked for by `check`. 409 `nothing_on_check` for a check with
        no dish, `no_such_check` for a number the table has no check for, `no_printer` when the location
        has none."""
        store: OpStore | PgOpStore = app.state.store
        state = store.view(order_id)
        if state is None:
            raise HTTPException(404, "no such order")
        check = check_for(state, app.state.taxes, app.state.pricing)
        if not check["lines"]:
            raise HTTPException(409, {"error": "nothing_on_check", "message": "There is nothing on this check yet."})
        printing: PrintService = app.state.printing
        printer = printing.bill_printer(body.printer if body is not None else None)
        if printer is None:
            raise HTTPException(409, {"error": "no_printer", "message": "No printer is set up for this location."})
        numbers: list[int | None] = [part["check"] for part in check["checks"]]
        asked = body.check if body is not None else None
        if asked is not None and asked not in numbers:
            raise HTTPException(409, {"error": "no_such_check", "message": f"There is no check {asked} here."})
        setting = app.state.settings.get("bill")
        head, foot, at = bill_head(setting), tuple(setting["footer"]), localtime.now()
        jobs = [
            job_out(printing.queue(bill_for(check, state.fields, head=head, foot=foot, at=at, number=n), printer))
            for n in ([asked] if asked is not None else numbers or [None])
        ]
        return {**jobs[0], "jobs": jobs, "bills": len(jobs), "printed_at": printer_out(printer)}

    @app.get("/floor")
    def read_floor() -> Response:
        """The floor plan with the open checks on each table, for the floor map. Each check says what its table
        is waiting on and since when (`timer`: a stage and `since_ms`, from the order log), and `timers` holds
        the location's warning times for each stage, so the map can draw a ring that drains as the time runs.
        Each check names its server (`server`, `server_id`): whoever opened the table, or whoever it was given to.
        A check with dishes the kitchen marked made that have not gone out says how many (`ready`) and when the
        last of them was made (`ready_ms`), for the mark that tells a server the food is up; how long the map
        shows it is the map's to say.
        `holds` are the tables booked for today: under each table's id, the reservations still standing that
        hold it, the earliest first, each with its `name`, `size` and `time` and the moments the map counts
        against (`pos.reservations.Booking.as_hold`); a table nobody booked is not in it.
        `turn` is tonight's turn for a table (`pos.floor.turn`): the staff ids of the people in it, whose
        turn it is first; nobody until a host says who is on, or the time clock does.
        `seated` is who sits at the tables: under the id of each open check the host seated a party on, from
        its reservation or the waitlist, its parties, the first to sit first, each by its `name` with the
        `tags` its number carries (`pos.api.guests.seated_by_check`); a walk-in's check is not in it. The
        number and the note are not told, and nothing of it is on the check.
        Nothing here moves with the clock: an answer stays the same until an order, a setting, the
        reservation book, the waitlist, a guest's tags or who is on the time clock changes (and when a new
        day of service begins)."""
        store: OpStore | PgOpStore = app.state.store
        open_states = store.views(store.index(status="open"))
        totals = {s.order_id: Decimal(check_for(s, app.state.taxes, app.state.pricing)["total"]) for s in open_states}
        plan: FloorPlan = app.state.floor
        coursing = app.state.settings.get("coursing")
        return polled(
            {
                **plan.as_json(),
                "courses": coursing["courses"] if coursing["enabled"] else [],  # what a line can be coursed by now
                "timers": app.state.settings.get("table_timers"),
                "status": table_status(
                    open_states,
                    totals,
                    [c["id"] for c in coursing["courses"]],
                    ready=lambda state: ready_of(state, skips=app.state.printing.skips),
                ),
                "moves": True,  # a table's check can move and merge here (pos.orders.moves)
                "holds": app.state.reservations.holds(),
                "turn": turn_now(),
                "seated": seated_by_check(app.state, (state.order_id for state in open_states)),
                "cursor": store.cursor,
            }
        )

    def turn_now() -> list[str]:
        """Tonight's turn for a table as it stands: the people in it by staff id, whose turn it is first."""
        store: OpStore | PgOpStore = app.state.store
        settings: SettingStore = app.state.settings
        day = localtime.service_day_of(store.now_ms())
        since, until = localtime.service_day(day)
        words = said(settings.get("turn"), day)
        clock: TimeClock = app.state.clock
        punches = punched(clock.store.began(since, until)) if settings.get("time_clock")["enabled"] else {}
        if not words and not punches:
            return []  # nobody was said to be on: the day's checks need no reading
        takers = [person for person in roster(app.state.staff, powers_of(app.state)) if person["takes_tables"]]
        return in_turn(takers, words, punches, last_sat(store.views(store.index(opened_since=since)), since))

    @app.post("/floor/turn")
    def say_turn(body: TurnIn) -> dict[str, Any]:
        """A host's word on tonight's turn for a table: `server_id` is in it (`on`) or out of it. Whoever gives
        tables out says it (`assign_tables`: 403 `not_allowed` from anybody else), of somebody who takes them
        (422 `no_tables` for putting in one who does not; anybody can be taken out). 404 `unknown_staff` for
        an id the hub does not know. Staff have no token: the screen passes who is signed in, as it does when
        a party is sat. The word holds until the night is over or another is said, and the time clock's later
        word counts over it (`pos.floor.turn`). Answers with the `turn` as it stands now."""
        directory: Directory = app.state.staff
        host, server = directory.get(body.staff_id), directory.get(body.server_id)
        if host is None or server is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        powers = powers_of(app.state)
        if not holds(powers, host.role, "assign_tables"):
            raise HTTPException(
                403, {"error": "not_allowed", "message": "Whoever gives tables out says who is in the turn."}
            )
        if body.on and not holds(powers, server.role, "take_tables"):
            raise HTTPException(422, {"error": "no_tables", "message": f"{server.name} does not take tables."})
        store: OpStore | PgOpStore = app.state.store
        settings: SettingStore = app.state.settings
        now = store.now_ms()
        word = say(
            settings.get("turn"),
            localtime.service_day_of(now),
            server.staff_id,
            body.on,
            at_ms=now,
            by_id=host.staff_id,
            by=host.name,
        )
        try:
            settings.put("turn", word)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("floor")
        return {"turn": turn_now()}

    # Location settings: a manager (token from /admin/session) sets them, every terminal reads them ---------
    def write_setting(key: str, data: Mapping[str, Any], clean: Callable[[Mapping[str, Any]], dict[str, Any]]) -> Any:
        try:
            cleaned = clean(data)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        settings: SettingStore = app.state.settings
        try:
            saved = settings.put(key, cleaned)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")  # the floor carries the courses, the order screen the quotes
        return saved

    def quotes_now() -> dict[str, Any]:
        settings: SettingStore = app.state.settings
        rush = rush_now(settings.get("rush"), int(time.time() * 1000))
        # `delivers`: this hub marks an order that is brought to the customer on its tickets and its bill
        # (docs/delivery.md), so a form may offer Delivery on any to-go order
        return {**settings.get("quotes"), "rush": rush, "delivers": True}

    @app.get("/settings/quotes")
    def read_quotes() -> dict[str, Any]:
        """Minutes each channel promises a takeout order, which channels may pay at pickup, the minutes a big
        order adds (`big_orders`), and `rush`: the minutes a manager added to every new quote for tonight,
        with when that ends and who set it; null while there is none. `delivers` is true: an order taken by
        hand may be a delivery (it is quoted the minutes of `delivery`), and this hub prints it as one."""
        return quotes_now()

    @app.put("/settings/quotes")
    def write_quotes(body: QuotesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets the quote times by hand; kitchen pacing takes over in phase 2."""
        manager_from(app.state.tokens, authorization)
        data = body.model_dump()
        if data["big_orders"] is None:
            data["big_orders"] = app.state.settings.get("quotes")["big_orders"]
        write_setting("quotes", data, clean_quotes)
        return quotes_now()

    @app.put("/settings/rush")
    def write_rush(body: RushIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager, or whoever holds the power `rush`, says the kitchen is behind: `minutes` more on every
        quote made from now on, on every terminal, until the night is over (four in the morning, the
        location's time); 0 takes it off. Orders already promised keep their time. Answers with the quotes as
        `GET /settings/quotes` now gives them."""
        manager = holder_from(app.state, authorization, "rush")
        until = int(localtime.night_end().timestamp() * 1000)
        write_setting("rush", body.model_dump(), lambda data: {**clean_rush(data), "until": until, "by": manager.name})
        return quotes_now()

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

    @app.get("/settings/table_timers")
    def read_table_timers() -> dict[str, Any]:
        """The timer rings on the floor map: `enabled`, and per stage (`sat`, `unsent`, `held`, `fired`) the
        minutes until the ring warns and until it is overdue (0 for never). `GET /floor` carries the same."""
        settings: SettingStore = app.state.settings
        return settings.get("table_timers")

    @app.put("/settings/table_timers")
    def write_table_timers(body: TableTimersIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets when a table's ring warns and when it is overdue, or turns the rings off. Every
        floor map follows at once (the change feed tells them a setting changed)."""
        manager_from(app.state.tokens, authorization)
        return write_setting("table_timers", body.model_dump(exclude_unset=True), clean_table_timers)

    @app.get("/settings/voids")
    def read_voids() -> dict[str, Any]:
        """What voiding a dish the kitchen already has takes: `approval` (`manager` for a manager's PIN on the
        spot, `none` for the reason alone) and `reasons`, the list the person voiding picks from."""
        settings: SettingStore = app.state.settings
        return settings.get("voids")

    @app.put("/settings/voids")
    def write_voids(body: VoidsIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager says whether a void of a sent dish needs a manager, and names the reasons. A reason sent
        without an id is new and gets one from its name; the rest keep theirs, since voids in the order log
        carry them. The hub holds every void to this from the next one on."""
        manager_from(app.state.tokens, authorization)
        return write_setting("voids", body.model_dump(), clean_voids)

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

    @app.get("/settings/printers")
    def read_printers() -> dict[str, Any]:
        """The kitchen printers: each with its stations, address, language (`dialect`: escpos, star or auto, with
        `detected`) and fallbacks, in the order they stand, and the station a to-go order prints whole at.
        `tickets` says whether a printer with several stations prints a send on `one` ticket or on one for
        `each` station, and `groups` the stations that share a ticket all the same; both are always there, so
        a screen knows this hub prints either way (a printer saved before it could reads `one`).
        `source` says where they come from: the setting, or `env` (POS_PRINTERS on a hub whose setting is
        still empty, shown so a save keeps them)."""
        settings: SettingStore = app.state.settings
        setting = settings.get("printers")
        if setting["printers"]:
            listed = [p.as_setting() for p in printers_from_setting(setting)]
            return {**setting, "printers": listed, "source": "settings"}
        seeded = printers_from_env()
        return {
            "printers": [p.as_setting() for p in seeded],
            "takeout_station": setting["takeout_station"],
            "source": "env" if seeded else "none",
        }

    @app.put("/settings/printers")
    def write_printers(body: PrintersIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets the printers for the location. A printer sent without an id is new and gets one;
        the rest keep theirs, since fallbacks name them. The next ticket prints by the new list. A printer sent
        without `tickets` or `groups` (an app not rebuilt since printers could print a ticket a station) keeps
        what is saved for it, so a save from an old screen does not put the tickets back together."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        asked = body.model_dump()
        saved = {p.get("id"): p for p in settings.get("printers")["printers"]}
        for printer in asked["printers"]:
            was = saved.get(printer["id"]) or {}
            for name in ("tickets", "groups"):
                if printer[name] is None:
                    printer[name] = was.get(name)
        return {**write_setting("printers", asked, clean_printers), "source": "settings"}

    @app.get("/settings/tickets")
    def read_tickets() -> dict[str, Any]:
        """What a kitchen ticket says about the other tickets of the same send: `numbered` ("Ticket 2 of 3",
        when more than one station is cooking) and `also_at` ("Also at: Wok 2, Sushi Bar", the other stations
        cooking). And `paid`: the takeout station's ticket of a to-go order says PAID, or NOT PAID with what
        is still to collect. And `moved`: food on its way that changes table prints a MOVED slip at its
        stations. And `pack`: a catering order's first tickets come with a pack sheet."""
        settings: SettingStore = app.state.settings
        return settings.get("tickets")

    @app.put("/settings/tickets")
    def write_tickets(body: TicketsIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns any of the lines on or off; one left out of the call stays as it is. The next
        ticket prints by it."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        asked = body.model_dump(exclude_none=True)
        return write_setting("tickets", {**settings.get("tickets"), **asked}, clean_tickets)

    @app.get("/settings/ticket_skips")
    def read_ticket_skips() -> dict[str, Any]:
        """The stations each screen prints no ticket at: `screens`, a list of `{device, stations}`. Dishes sent
        or voided from such a screen print nothing at those stations (the person ringing them in makes them:
        the bar's own screen and the bar printer); the rest of the order prints where it always does. A screen
        that is not listed prints everywhere."""
        settings: SettingStore = app.state.settings
        return settings.get("ticket_skips")

    @app.put("/settings/ticket_skips")
    def write_ticket_skips(body: TicketSkipsIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager says which stations each screen prints no ticket at; the whole list at once, each screen
        once. A screen sent with no station is dropped from it. The next send prints by it."""
        manager_from(app.state.tokens, authorization)
        return write_setting("ticket_skips", body.model_dump(), clean_ticket_skips)

    @app.get("/settings/time_clock")
    def read_time_clock() -> dict[str, Any]:
        """The time clock: `enabled`, whether the location uses it (off to start: the sign-in pad shows no
        clock until a manager turns it on); `breaks_paid`, whether a break counts as time worked (off: a
        break is the meal break, off the clock); `week_starts`, the day the pay week starts on (`mon` or
        `sun`)."""
        settings: SettingStore = app.state.settings
        return settings.get("time_clock")

    @app.put("/settings/time_clock")
    def write_time_clock(body: TimeClockIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns the clock on or off and says how breaks and the pay week count. A key left out
        keeps what it was. Hours already on the clock are not touched: `breaks_paid` only changes how they
        are added up."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        asked = body.model_dump(exclude_none=True)
        return write_setting("time_clock", {**settings.get("time_clock"), **asked}, clean_time_clock)

    def bill_head(setting: Mapping[str, Any]) -> tuple[str, ...]:
        """The top of the bill: the lines the manager typed, or the location's name until any are."""
        named = (app.state.location,) if app.state.location != NO_NAME else ()
        return tuple(setting["header"]) or named

    def printer_out(printer: Printer) -> dict[str, str]:
        return {"id": printer.id, "name": app.state.printing.head(printer)}

    def bill_setting() -> dict[str, Any]:
        printing: PrintService = app.state.printing
        now, usual = printing.bill_printer(), printing.bill_printer(location=False)
        return {
            **app.state.settings.get("bill"),
            "printers": [printer_out(p) for p in printing.printers],
            "prints_at": now.id if now is not None else None,
            "usual": usual.id if usual is not None else None,
        }

    @app.get("/settings/bill")
    def read_bill() -> dict[str, Any]:
        """The guest's bill: `printer`, the id of the printer the location's bills print at (null: the takeout
        station's, else the first), `header` and `footer`, the lines at its top and its foot. With them, for
        the screens: `printers`, every printer by id and the name that heads its tickets; `prints_at`, the id
        of the printer a bill comes out of when a screen asks for none (null with no printer at all); and
        `usual`, the one it would come out of if the location named none."""
        return bill_setting()

    @app.put("/settings/bill")
    def write_bill(body: BillIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager sets where bills print and what stands at their top and foot; one left out of the call
        stays as it is. The next bill prints by it."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        write_setting("bill", {**settings.get("bill"), **body.model_dump(exclude_unset=True)}, clean_bill)
        return bill_setting()

    @app.get("/settings/bag")
    def read_bag() -> dict[str, Any]:
        """The one question asked before a to-go order is first sent: `enabled`, whether it is asked;
        `question`, its words; `choices`, what the customer may want in the bag, each `{id, name}` in the
        order the buttons show. "Nothing" is always an answer. The answer is the order's `bag` field
        (`pos.orders.bag`), and the takeout station's ticket lists it."""
        settings: SettingStore = app.state.settings
        return settings.get("bag")

    @app.put("/settings/bag")
    def write_bag(body: BagIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns the question on or off, words it and lists its choices. A choice sent without an id
        is new and gets one from its name; the rest keep theirs, since answers on orders carry them. Every
        screen asks by it from its next to-go order."""
        manager_from(app.state.tokens, authorization)
        return write_setting("bag", body.model_dump(), clean_bag)

    def delivery_fee_now(setting: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """The fee's setting as a screen is told it: with `maps`, whether this hub has a map service to ask,
        `lookup`, whether a delivery's distance is looked up (a service, and the restaurant's own address
        to start from), and `services`, the names of the hub's map services in the order they are asked."""
        settings: SettingStore = app.state.settings
        told = dict(setting if setting is not None else settings.get("delivery_fee"))
        asked = asking("distance")
        return {
            **told,
            "maps": bool(asked),
            "lookup": bool(asked) and bool(told.get("origin")),
            "services": asked,
            "live": live_drive_now()["live"] and bool(asked),
        }

    def asking(purpose: str) -> list[str]:
        """The map services this hub asks for a purpose (`distance` or `traffic`), in the order it asks them:
        the ones the location has turned on that the hub has a key for, as the location ordered them. One the
        setting has no name for (a hub set up with another service) is asked where it stands among them."""
        settings: SettingStore = app.state.settings
        lookups: Lookups = app.state.lookups
        has = lookups.traffics if purpose == "traffic" else lookups.names
        named = iter([name for name in turned_on(settings.get("drive_lookups"), purpose) if name in has])
        places = [name if name not in PURPOSES[purpose] else next(named, None) for name in has]
        return [name for name in places if name is not None]

    def drive_lookups_now(setting: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """Who is asked how far a delivery goes and who the drive right now, as a screen is told it: under
        `distance` and under `traffic`, `order` and `services`, every service of that kind in the order they
        are asked, each with whether it is turned on, whether the hub has its key, and how many of its
        day's lookups are left (`Lookups.standing`)."""
        settings: SettingStore = app.state.settings
        lookups: Lookups = app.state.lookups
        told = setting if setting is not None else settings.get("drive_lookups")
        return {
            purpose: {
                "order": [one["name"] for one in standing],
                "services": standing,
            }
            for purpose in PURPOSES
            for standing in [lookups.standing(purpose, told)]
        }

    @app.get("/settings/drive_lookups")
    def read_drive_lookups() -> dict[str, Any]:
        """Which map services are asked how far a delivery goes (`distance`) and how long the drive is right
        now (`traffic`), in the order they are asked: the first that is turned on and has a key, and the next
        one only when the one before it gives nothing. Each service says `on`, `key`, `asks` (both), and how
        today went: `asked_today`, `daily_most` and `left`. The hub counts by the day, on its own; a service
        does not say what its account has left."""
        return drive_lookups_now()

    @app.put("/settings/drive_lookups")
    def write_drive_lookups(body: DriveLookupsIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns a service on or off for the distance or for the drive right now, and puts them in
        the order they are asked. One that is left out stays as it is. The next delivery is looked up by it."""
        manager_from(app.state.tokens, authorization)
        settings: SettingStore = app.state.settings
        had = settings.get("drive_lookups")
        sent = body.model_dump(exclude_none=True)
        wanted = {purpose: {**(had.get(purpose) or {}), **(sent.get(purpose) or {})} for purpose in PURPOSES}
        return drive_lookups_now(write_setting("drive_lookups", wanted, clean_drive_lookups))

    def live_drive_now(setting: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """Live traffic's setting as a screen is told it: with `traffic`, whether this hub has a map service
        that knows the roads right now, `origin`, whether the restaurant's own address is set (the fee's
        setting holds it), and `live`, whether a delivery for now is promised by the roads as they are:
        turned on, with both."""
        settings: SettingStore = app.state.settings
        told = dict(setting if setting is not None else settings.get("live_drive"))
        traffic = bool(asking("traffic"))
        origin = bool(settings.get("delivery_fee").get("origin"))
        return {
            **told,
            "traffic": traffic,
            "origin": origin,
            "live": told.get("enabled") is True and traffic and origin,
        }

    @app.get("/settings/live_drive")
    def read_live_drive() -> dict[str, Any]:
        """Live traffic for deliveries: `enabled`, whether a manager turned it on, and `before`, the minutes
        for the cooking and getting an order out of the door. Where it is on, a delivery for now is promised
        `before` and the drive as it is at this minute (`drive_now` in the answer of `POST
        /delivery/distance`), in place of the minutes set for Delivery. `traffic` says whether this hub has
        a map service that knows the roads right now, `origin` whether the restaurant's own address is set,
        and `live` whether all three hold. The delivery fee never goes by it."""
        return live_drive_now()

    @app.put("/settings/live_drive")
    def write_live_drive(body: LiveDriveIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns live traffic on or off and says how long the kitchen needs before the drive. Orders
        already taken keep the time they were promised."""
        manager_from(app.state.tokens, authorization)
        return live_drive_now(write_setting("live_drive", body.model_dump(), clean_live_drive))

    @app.get("/settings/delivery_fee")
    def read_delivery_fee() -> dict[str, Any]:
        """What a delivery costs the customer: `enabled`, whether a fee is charged at all; `by`, whether it
        goes by `miles` or by the `minutes` of the drive; `bands`, the prices in order of how far they
        reach, each `{up_to, fee}`; `taxed`, whether sales tax is charged on it; `origin`, the restaurant's
        own address; `custom`, whether whoever takes an order may type the fee of a delivery that goes further
        than the last band reaches. The band picked for an order is its `delivery_fee` field
        (`pos.orders.delivery_fee`): a screen names the band and the hub fills in what it costs, or, for such
        a delivery, says the amount that was typed. `maps` says whether this hub has a map
        service, and `lookup` whether a form may ask how far an address is (`POST /delivery/distance`)."""
        return delivery_fee_now()

    @app.put("/settings/delivery_fee")
    def write_delivery_fee(body: DeliveryFeeIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager turns the fee on or off, says what it goes by and lists the prices. Orders already taken
        keep the fee they were given; every screen offers the new prices from its next delivery. An app
        older than the lookup says no `origin`, and the one that is stored stays; so does `custom` (whether
        the fee of a delivery further than the last band may be typed) from an app older than that."""
        manager_from(app.state.tokens, authorization)
        data = body.model_dump()
        settings: SettingStore = app.state.settings
        if data["origin"] is None:
            data["origin"] = settings.get("delivery_fee").get("origin") or ""
        if data["custom"] is None:
            data["custom"] = settings.get("delivery_fee").get("custom") is not False
        return delivery_fee_now(write_setting("delivery_fee", data, clean_delivery_fee))

    @app.post("/delivery/distance")
    def delivery_distance(body: DistanceIn) -> dict[str, Any]:
        """How far a delivery's address is from the restaurant, asked of the hub's map service
        (`pos.maps`), and the band of the fee it falls in: `miles` (along the road, to a hundredth), `minutes`
        (the usual drive), `by` (what the fee goes by here), `band` (`{up_to, fee}`, or null) and `beyond`
        (true when the address is further than the last band reaches). The form picks that band, and whoever
        takes the order can still tap another. For an address beyond them all the form asks for the fee to be
        typed, where the location allows that (`custom` in the setting).

        A customer who had a delivery brought to this address before is not asked about again: with their
        `phone`, the figures are read off that order (`pos.customers.saved_trip`) and `saved` is true.
        `fresh` asks the service all the same. `service` (who measured it) and `from` (the mark of the
        restaurant's address it was measured from) go back to the hub with the pick, in `measured`, which
        is how the figures get onto the order for the next time.

        Where the hub has a second service, it is asked when the first gives no distance. `credit` is what
        that service's terms want shown beside its figures ("Google Maps"), or null. `keep` is false for
        figures of a service whose terms do not let them be kept: a screen shows them, picks the price by
        them and does not send them back, and they are not put on the order whatever a screen sends. `via`
        names the one service to ask, for `hubctl maps test`.

        The services are asked in the order the location set (`/settings/drive_lookups`), the ones it has
        turned on. `title` is what a screen calls the one that measured it, and `left` of `daily_most` how
        many of its day's lookups it has left by the hub's own count, for the badge beside the figures
        (both null where the hub has no key for it now).

        `now` says the delivery is for now. Where live traffic is turned on (`/settings/live_drive`), the
        answer then carries `drive_now`: `{minutes, before, credit, service, title, left, daily_most}`, the
        drive as the roads are at this minute, the minutes the kitchen needs before it, the name to show
        beside the figure, and who said it with what it has left today; or null
        when nobody could say, which is no failure: the delivery is promised its usual minutes. It is asked
        beside the distance, never remembered, and never kept. The band and the fee do not go by it.

        Only the two addresses go to the service: no name, no phone number, nothing of the order. The
        number is used on the hub alone. 409 `no_lookup` when this hub has no map service that is turned on
        or no address of its own to start from; 424 `lookup_failed`, with a `reason` and words for the form,
        when the service gave no distance. Not a 5xx: the hub itself is well, and a terminal reads a 5xx as
        a hub to turn away from."""
        settings: SettingStore = app.state.settings
        lookups: Lookups = app.state.lookups
        setting = settings.get("delivery_fee")
        origin = str(setting.get("origin") or "")
        asked = asking("distance")
        via = body.via.strip().lower() or None
        # a key is tried out whether its service is turned on or not
        if not (asked or via in lookups.names) or not origin:
            raise HTTPException(
                409,
                {
                    "error": "no_lookup",
                    "message": "the restaurant's own address is not set (Location, Delivery fee)"
                    if asked or via in lookups.names
                    else "no map service is turned on for the distance (Location, Delivery fee)"
                    if lookups.ready
                    else "this hub has no map service to ask",
                },
            )
        address = " ".join(body.address.split())
        if not address or len(address) > ADDRESS_MAX:
            raise HTTPException(422, {"error": "bad_value", "message": "an address of at most 200 letters"})
        if via is not None and via not in lookups.names:
            raise HTTPException(422, {"error": "bad_value", "message": f"this hub has no map service {via!r}"})
        mark = origin_mark(origin)
        live = settings.get("live_drive")
        waiting = (
            lookups.drive_ahead(origin, address, among=asking("traffic"))
            if body.now and live.get("enabled") is True and not via
            else None
        )
        kept = None if body.fresh or via else saved_trip(app.state.store, body.phone, address, mark)
        if kept is not None:
            trip = Trip(Decimal(kept["miles"]), kept["minutes"], kept["service"])
            lookups.spared()
        else:
            try:
                trip = lookups.trip(origin, address, via=via, among=asked)
            except LookupFailed as err:
                raise HTTPException(424, {"error": "lookup_failed", "reason": err.reason, "message": str(err)}) from err
        band = band_for(setting, trip.miles, trip.minutes)
        charged = setting.get("enabled") is True and bool(setting.get("bands"))
        drive = waiting() if waiting is not None else None
        return {
            **trip.as_json(),
            "by": setting.get("by"),
            "band": band,
            "beyond": charged and band is None,
            "service": trip.service,
            "credit": credit_of(trip.service),
            "keep": may_keep(trip.service),
            "from": mark,
            "saved": kept is not None,
            # for the badge beside the figures: what a screen calls who measured it, and how many of its day's
            # lookups are left
            **lookups.left("distance", trip.service),
            "drive_now": None
            if drive is None
            else {
                "minutes": drive.minutes,
                "before": live.get("before"),
                "credit": credit_of(drive.service),
                "service": drive.service,
                **lookups.left("traffic", drive.service),
            },
        }

    @app.get("/maps/status")
    def maps_status() -> dict[str, Any]:
        """For `hubctl maps status`: whether the hub has a map service, whether the restaurant's own address
        is set, and how often the service was asked today; the same of a second service under `fallback`, and
        under `traffic` how often the drive right now was asked and whether live traffic is turned on; under
        `suggests`, of each map service the list of addresses can ask, in the order they are asked: how often
        it was asked this month and today, the most it is asked in a month, and whether a manager turned it
        on (`enabled`); and under `suggest` the first of those (None on a hub with no key for any). No
        address is in it."""
        settings: SettingStore = app.state.settings
        lookups: Lookups = app.state.lookups
        status = lookups.status()
        live = settings.get("live_drive").get("enabled") is True
        for roads in status["traffics"]:  # `traffic` is the first of them
            roads["enabled"] = live
        looked = settings.get("drive_lookups")
        # every service there is for each, in the order the location asks them, with whether it is turned on
        status["distance"] = lookups.standing("distance", looked)
        status["drive_now"] = lookups.standing("traffic", looked)
        status["live"] = live
        turned_on = settings.get("address_list")
        order = order_of(turned_on)
        listings = sorted(app.state.suggester.statuses(), key=lambda listing: order.index(listing["service"]))
        for listing in listings:
            listing["enabled"] = turned_on.get(listing["service"]) is True
        return {
            **status,
            "origin_set": bool(settings.get("delivery_fee").get("origin")),
            "suggest": listings[0] if listings else None,
            "suggests": listings,
        }

    @app.get("/settings/kitchen_notes")
    def read_kitchen_notes() -> dict[str, Any]:
        """The one-tap notes to the kitchen: `notes`, short words in the order the dish's sheet shows them as
        buttons ("Rush", "Split for 2"). A tap puts the words in the dish's note, which prints under the dish
        as a typed note does."""
        settings: SettingStore = app.state.settings
        return settings.get("kitchen_notes")

    @app.put("/settings/kitchen_notes")
    def write_kitchen_notes(body: KitchenNotesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager lists the one-tap notes. Orders carry the words themselves, so a note reworded or dropped
        changes nothing on a dish already rung in. An empty list offers none."""
        manager_from(app.state.tokens, authorization)
        return write_setting("kitchen_notes", body.model_dump(), clean_kitchen_notes)

    @app.get("/settings/powers")
    def read_powers() -> dict[str, Any]:
        """Who may do what: `roles`, for each power the roles it is handed to; the `powers` in order with what
        each is for; the roles a power can be `handed` to; and the ones that `always` hold every power (the
        managers and the owners, whom no setting takes one from). Open like the other settings: a screen reads
        it to show each person what they may open."""
        return table(powers_of(app.state))

    @app.put("/settings/powers")
    def write_powers(body: PowersIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager or an owner hands powers to the other roles, or takes them back. Only they change this
        table, whatever it says. It holds from the next call on: a session or an approval already given is
        weighed against the table as it stands when it is used."""
        manager_from(app.state.tokens, authorization)
        current = app.state.settings.get("powers")["roles"]
        return table(write_setting("powers", {"roles": {**current, **body.roles}}, clean_powers))

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

    @app.get("/phones/calls/{call_id}")
    def read_call(call_id: str) -> dict[str, Any]:
        """Where a call stands, by the id a push carried (`call`): `ringing`, `answered` (and on which
        extensions), `ended` or `unknown`. A phone woken for a call asks this to take its ringing screen down
        when the call was answered elsewhere or the caller gave up before its own invite arrived."""
        pbx: AmiWatcher | None = app.state.watcher
        if pbx is None:
            return {"call": call_id, "state": "unknown", "answered": [], "number": "", "name": "", "dialed": ""}
        return pbx.tracker.state(call_id)

    # Push relay: the screens register their tokens, the hub wakes them (docs/push-relay.md) ----------------------
    @app.put("/push/devices")
    def register_push(body: PushDeviceIn) -> dict[str, Any]:
        """A screen registers a push token, on every start and whenever it changes: `kind` is `voip` for the
        phone in the app (with the `extension` it registers as, which the hub marks on the PBX so the dial
        waits for the phone) or `alert` for a desk-phone pick-up. `configured` says whether this hub has an
        Apple key to push with; `env` is where Apple took the token, once known."""
        try:
            device = clean_device(body.model_dump(), device_pattern=DEVICE, extension_pattern=EXTENSION)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        registry: PushDevices = app.state.push_devices
        try:
            saved = registry.put(device)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.devices.heard(device.device)
        relay: PushRelay = app.state.relay
        relay.marks_changed()
        return {
            "ok": True,
            "configured": relay.configured,
            "kind": saved.kind,
            "extension": saved.extension,
            "env": saved.env,
        }

    @app.delete("/push/devices/{token}")
    def unregister_push(token: str) -> dict[str, Any]:
        """The phone was turned off in the app, or signed out: no more pushes to this token."""
        registry: PushDevices = app.state.push_devices
        try:
            removed = registry.remove(token.strip().lower())
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.relay.marks_changed()
        return {"ok": True, "removed": removed}

    @app.get("/push/status")
    def read_push_status() -> dict[str, Any]:
        """The hub's push relay: whether an Apple key is on it, what went out, the tokens registered (shortened),
        the extensions marked on the PBX (and any trouble marking them), and when the PBX's hook last spoke."""
        relay: PushRelay = app.state.relay
        registry: PushDevices = app.state.push_devices
        return {**relay.status(), "list": registry.listed()}

    @app.post("/push/test")
    async def test_push(body: PushTestIn) -> dict[str, Any]:
        """A push to a screen by hand: a notification (`alert`), or a test call (`voip`) the phone shows."""
        if body.kind not in ("alert", "voip"):
            raise HTTPException(422, {"error": "bad_value", "message": "kind must be alert or voip"})
        relay: PushRelay = app.state.relay
        return await relay.test(body.device.strip(), body.kind)

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
        """A PIN on the spot for one thing on one order: a discount or a charge (`adjust`), the void of a sent
        dish (`void`), marking the check tax exempt (`exempt`). A manager's or an owner's always, and that of
        anyone whose role the location handed that power to (`GET /settings/powers`); 403 `not_allowed` for
        anyone else. The answer is a short-lived token the terminal puts on the operation as `approval`; the
        hub records who it was, never the token."""
        directory: Directory = app.state.staff
        try:
            found = directory.by_pin(body.pin, device=body.device)
        except Locked as err:
            raise HTTPException(423, {"error": "locked", "seconds": round(err.seconds_left)}) from err
        if found is None:
            raise HTTPException(401, {"error": "unknown_credential"})
        if not holds(powers_of(app.state), found.role, body.purpose):
            raise HTTPException(403, {"error": "not_allowed", "role": found.role, "power": body.purpose})
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
        Discounts taken off again are counted, not valued. `voids` lists every dish voided after the kitchen
        had it (since `since`, whatever the age of its order), oldest first, with the same three totals:
        by reason, by who voided and by who approved. `taken_off` lists every dish taken off a check before
        it was sent, and every time fewer of an unsent dish were kept (since `since`, oldest first): what it
        was worth, who took it off (`by`; empty from an app that did not say) and who rang it in
        (`rung_by`), on which screen, and how long it had been on the check (`on_check_ms`); added up by
        who took it off and by check. A dish changed before it was sent is not one. `typed` lists every dish
        sold at a typed price (an off-menu dish, a market price; rung in since `since`, oldest first): what
        it was called, for how much, who rang it in, on which check; added up by who rang it in. One voided
        since is marked and counts for nothing here."""
        store: OpStore | PgOpStore = app.state.store
        discounts: list[dict[str, Any]] = []
        charges: list[dict[str, Any]] = []
        voids: list[dict[str, Any]] = []
        taken_off: list[dict[str, Any]] = []
        typed: list[dict[str, Any]] = []
        by_reason: dict[str, Decimal] = {}
        by_staff: dict[str, Decimal] = {}
        by_approver: dict[str, Decimal] = {}
        removed = 0
        for state in store.views(store.index(active_since=since)):  # by order id; only the ones that recent
            check = check_for(state, app.state.taxes, app.state.pricing)
            about = {"order_id": state.order_id, "table": state.fields.get("table"), "status": state.status}
            for row in check["discounts"]:
                discounts.append({**about, **row})
                amount = Decimal(row["amount"])
                _tally(by_reason, row["reason"], amount)
                _tally(by_staff, row["applied_by"] or "", amount)
                _tally(by_approver, (row["approved_by"] or {}).get("name", ""), amount)
            charges.extend({**about, **row} for row in check["charges"])
            removed += sum(1 for d in state.discounts.values() if not d.active)
            voids.extend({**row, "status": state.status} for row in void_rows(state, since))
            taken_off.extend({**row, "status": state.status} for row in taken_off_rows(state, since))
            typed.extend({**row, "status": state.status} for row in typed_rows(state, since))
        voids.sort(key=lambda row: (row["at_ms"], row["order_id"], row["line_id"]))
        taken_off.sort(key=lambda row: (row["at_ms"], row["order_id"], row["line_id"]))
        typed.sort(key=lambda row: (row["at_ms"], row["order_id"], row["line_id"]))
        sold = [row for row in typed if not row["voided"]]
        return {
            "typed": typed,
            "typed_total": str(sum((Decimal(t["amount"]) for t in sold), Decimal("0.00"))),
            "typed_count": len(sold),
            "typed_by_staff": _void_totals(sold, lambda t: t["by"]),
            "taken_off": taken_off,
            "taken_off_total": str(sum((Decimal(t["amount"]) for t in taken_off), Decimal("0.00"))),
            "taken_off_count": len(taken_off),
            "taken_off_by_staff": _void_totals(taken_off, lambda t: t["by"]),
            "taken_off_by_check": by_check(taken_off),
            "voids": voids,
            "void_total": str(sum((Decimal(v["amount"]) for v in voids), Decimal("0.00"))),
            "void_count": len(voids),
            "voids_by_reason": _void_totals(voids, lambda v: v["reason_name"]),
            "voids_by_staff": _void_totals(voids, lambda v: v["by"]),
            "voids_by_approver": _void_totals(voids, lambda v: (v["approved_by"] or {}).get("name", "")),
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
    def read_menu(channel: str = "pos", locale: str = "en") -> Response:
        """The menus open now for a channel. `revision` moves whenever the menu is edited. Every screen with
        a menu open reads this at once when the feed says the menu changed (a save, an 86), so it is written
        straight to JSON like the reads the screens poll."""
        menu: MenuService = app.state.menu
        menu.refresh()
        return polled({"menus": menu.menus(channel, locale), "revision": menu.revision})

    @app.get("/menu/revision")
    def menu_revision() -> dict[str, Any]:
        """What a terminal polls to know when to reload its menu: the revision moves on every save."""
        menu: MenuService = app.state.menu
        menu.refresh()
        return {"revision": menu.revision}

    @app.get("/menu/allergens")
    def read_allergens(locale: str = "en") -> dict[str, Any]:
        """The allergens the menu lists, in its order: what a server picks from when a guest tells of an
        allergy (an `allergy` operation on the order names them by `code`)."""
        menu: MenuService = app.state.menu
        menu.refresh()
        listed = sorted(menu.defs.allergens.values(), key=lambda a: (a.sort, a.code))
        return {"allergens": [{"code": a.code, "name": menu.defs.localizer.text(a.names, locale)} for a in listed]}

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
        """The 86 board: what the kitchen is out of right now (`status` sold_out), and every dish with a
        number left (`left` of the `total` typed; `status` available while any is left), the ones that are
        out first, then the fewest left."""
        menu: MenuService = app.state.menu
        return {"items": menu.eighty_sixed()}

    @app.post("/menu/86")
    def set_86(body: AvailabilityIn) -> dict[str, Any]:
        """86 a size or an option (`sold_out`), or bring it back (`available`). Stored with the menu, so a
        restart keeps the board. `available` with `remaining` puts a number left on a size instead: every
        one sold takes it down, one removed or voided gives it back, at zero the dish is sold out, and the
        count clears when the night is over. Setting it again starts from the new number; `available`
        without it takes the count off."""
        menu: MenuService = app.state.menu
        if body.target_id not in menu.defs.variants and body.target_id not in menu.defs.options:
            raise HTTPException(404, {"error": "unknown_id", "id": body.target_id})
        if body.remaining is not None and (body.status != "available" or body.target_id not in menu.defs.variants):
            # a number left is for a dish that is on sale; a choice that is only a word has none
            raise HTTPException(422, {"error": "bad_count", "id": body.target_id})
        menu.set_availability(body.target_id, body.status, reason=body.reason, by=body.by, remaining=body.remaining)
        return {"items": menu.eighty_sixed()}

    @app.post("/menu/price")
    def price_line(body: PriceIn) -> dict[str, Any]:
        """A preview of one configured line, so the screen can show the price before adding it. It does
        not say that a counted dish has none left: the dish being previewed may be the last one, already on
        a check and now being changed, and that is settled when the line arrives (`count_ops`)."""
        menu: MenuService = app.state.menu
        menu.refresh()
        try:
            priced = menu.priced(body.model_dump())
            priced["problems"] = [p for p in priced["problems"] if p["code"] != COUNTED_OUT]
            return priced
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
                found = sign_in_by_tag(app.state.tags, directory, body.tag_uid, device=body.device)
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

    @app.get("/staff")
    def read_staff() -> Response:
        """The staff by name and role: who a table can be given to (`takes_tables`: to start the servers,
        bartenders and managers) and who may seat a party for someone else or hand a table over
        (`assigns_tables`: to start the hosts and managers). The location's table of powers says who it is
        now (`GET /settings/powers`, `take_tables` and `assign_tables`). A server is given a table by opening
        it; a host picks the server as the party is sat."""
        return polled({"staff": roster(app.state.staff, powers_of(app.state))})

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
        """The printers as they stand: `name` is the station each prints for (the first of `stations`), `dialect`
        the language its tickets are in (resolved when the setting says auto); a relay prints to `address`."""
        printing: PrintService = app.state.printing
        return {
            "printers": [
                {
                    "id": p.id,
                    "name": p.name,
                    "station": p.name,
                    "stations": list(p.stations),
                    "address": p.address,
                    "dialect": p.dialect,
                    "fallbacks": list(p.fallbacks),
                }
                for p in printing.printers
            ],
            "direct": printing.direct,
        }

    @app.get("/print/stations")
    def list_stations() -> dict[str, Any]:
        """Every station the menu knows, with how many dishes print there (their own or their category's), how
        many choices send a dish there as well, and the id of the printer serving it, if any; `missing` lists
        the stations with dishes and no printer, the takeout station among them when to-go orders print there.
        The printer settings screen shows these as the printers to add."""
        printing: PrintService = app.state.printing
        menu: MenuService = app.state.menu
        defs = menu.defs
        served: dict[str, str] = {}
        for p in printing.printers:
            for station in p.stations:
                served.setdefault(station, p.id)
        takeout = app.state.settings.get("printers")["takeout_station"]
        dishes: dict[str, int] = {}
        for item in defs.items.values():
            station = defs.inherited(item, "station") if item.active else None
            if station:
                dishes[station] = dishes.get(station, 0) + 1
        routed: dict[str, int] = {}
        for option in defs.options.values():
            if option.routes_to and option.active:
                routed[option.routes_to] = routed.get(option.routes_to, 0) + 1
        codes = list(defs.stations) + [c for c in (*dishes, *routed, *served, takeout) if c and c not in defs.stations]
        stations = [
            {
                "code": code,
                "name": defs.localizer.text(defs.stations[code].names, "en") if code in defs.stations else code,
                "known": code in defs.stations,
                "dishes": dishes.get(code, 0),
                "choices": routed.get(code, 0),
                "printer": served.get(code),
                "takeout": code == takeout,
            }
            for code in dict.fromkeys(codes)
        ]
        missing = [
            st["code"] for st in stations if st["printer"] is None and (st["dishes"] or st["choices"] or st["takeout"])
        ]
        return {"stations": stations, "takeout_station": takeout, "missing": missing}

    @app.post("/print/discover")
    async def discover_printers(body: DiscoverIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Looks for printers (port 9100 open) on the subnets of the addresses given, of the printers already
        set and of this machine, and tells each one's language. A few seconds."""
        manager_from(app.state.tokens, authorization)
        printing: PrintService = app.state.printing
        hints = [*body.addresses, *(p.address for p in printing.printers), *discover.own_addresses()]
        subnets = [*body.subnets, *discover.subnets_for(hints)][: discover.MAX_SUBNETS]
        found = await discover.discover(subnets, port=body.port)
        return {"subnets": subnets, "found": [f.as_json() for f in found]}

    @app.post("/print/identify")
    async def identify_printer(body: IdentifyIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Whether the printer at an address answers, and which language it speaks, without printing."""
        manager_from(app.state.tokens, authorization)
        return (await discover.identify(body.address)).as_json()

    @app.get("/print/jobs")
    def list_jobs(status: str | None = Query(None, pattern="^(queued|leased|done|failed)$")) -> dict[str, Any]:
        """The newest print jobs, and `held`: the orders sent ahead of their time whose tickets are not made
        yet, each with when they print (`starts_ms`) and how many dishes wait."""
        printing: PrintService = app.state.printing
        jobs = sorted(printing.store.all(), key=lambda j: j.created, reverse=True)
        if status is not None:
            jobs = [j for j in jobs if j.status == status]
        held = [{"order_id": h.order_id, "starts_ms": h.start_ms, "lines": len(h.lines)} for h in printing.held.all()]
        return {"jobs": [job_out(j, due_in=printing.store.due_in(j)) for j in jobs[:200]], "held": held}

    @app.post("/print/jobs/claim")
    def claim_job(body: ClaimIn) -> dict[str, Any]:
        """A relay asks for one job for a printer it can reach; the bytes come with it. The tickets of orders
        sent ahead whose time has come are made first, so a relay finds them whether or not the hub's own
        loop got to them."""
        printing: PrintService = app.state.printing
        printing.release_due()
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
        """The demo ticket to a configured printer, by id or station: the settings screen's test button. A
        printer that prints a ticket for each station prints the demo once for each, headed as its tickets
        will be, so the paper shows what was set; `tickets` says how many."""
        printing: PrintService = app.state.printing
        printer = printing.printer(body.printer)
        if printer is None:
            raise HTTPException(404, {"error": "no_such_printer", "printers": [p.id for p in printing.printers]})
        jobs = [
            printing.queue(replace(DEMO, station=printing.head(printer, stations)), printer, title="Test print")
            for stations in printer.sets()
        ]
        return {**job_out(jobs[0]), "tickets": len(jobs)}

    @app.post("/print/bill-sample", status_code=202)
    def print_bill_sample(body: BillIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A made-up bill under the lines given (the saved ones for any left out), at the printer given: what
        the bill settings' sample button prints, so a manager reads the heading on paper before saving it."""
        manager_from(app.state.tokens, authorization)
        printing: PrintService = app.state.printing
        try:
            tried = clean_bill({**app.state.settings.get("bill"), **body.model_dump(exclude_unset=True)})
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        printer = printing.bill_printer(tried["printer"], location=False)
        if printer is None:
            raise HTTPException(409, {"error": "no_printer", "message": "No printer is set up for this location."})
        sample = replace(SAMPLE, head=bill_head(tried), foot=tuple(tried["footer"]), at=localtime.now())
        job = printing.queue(sample, printer, title="Sample bill")
        return {**job_out(job), "printed_at": printer_out(printer)}

    add_print_log(app)
    add_menu_admin(app)
    add_face_signin(app)
    add_time_clock(app)
    add_shift_notes(app)
    add_waste_log(app)
    add_waitlist(app)
    add_reservations(app)
    add_day_report(app)
    add_prep(app)
    add_kitchen(app)
    add_sales_report(app)
    add_contests(app)  # after the sales: it reads through their remembered checks
    add_today(app)
    add_guest_list(app)
    add_history(app)
    add_calls(app)
    add_texts(app)
    add_runs(app)
    add_online_orders(app, number_orders)
    add_hub_keys(app)
    add_address_list(app)
    add_staff_list(app)
    return app


app = create_app()
