"""The waste log on the wire. The rules live in `pos.waste`; these are the calls.

- `GET /waste?day=YYYY-MM-DD`: one day of service (the one that is running when no day is asked): its
  `entries`, the newest first, each with `id`, `at_ms`, `name`, `qty`, `reason`, `each` and `value` (the
  menu's price of one and of all of them; null for something typed), `note`, `by`, `by_id` and, when it was
  struck out, `struck_ms` and `struck_by`; `total` (what stands: `entries`, `count`, `value`, `unpriced`);
  and what the screen needs to write a new one: `reasons` (the location's list) and the `limits`.
- `POST /waste` `{staff_id, variant_id, entry_id, name, qty, reason, note, device}`: writes an entry. With
  `variant_id` the dish is the menu's: the hub names it and prices it from the menu, whatever `name` says.
  Without one, `name` is what was typed, and there is no price. Staff have no token: a screen passes who is
  signed in, as it does for the notes. 422 with the reason for a bad value, 404 `unknown_staff`.
- `POST /waste/{id}/strike` `{staff_id}`: strikes an entry out. The person who wrote it may, on the day
  they wrote it (409 `not_yours`, `past`); a manager's token may strike any. Nothing is changed or deleted.
- `GET /reports/waste?from=YYYY-MM-DD&to=YYYY-MM-DD` (manager token): the span added up, `days`, `reasons`
  and `dishes`, each with `count` and `value`; `total`; and how many entries were `struck`. Without `from`
  and `to`, the day that is running; with one of them, that one day.
- `GET /settings/waste`: `reasons`, the words on the buttons. `PUT /settings/waste` (manager token) sets
  them.

Nothing here reads or writes an order: the waste log is words beside the sales, never part of them.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from .. import localtime
from ..identity.powers import holds
from ..identity.staff import Directory
from ..settings import WASTE_REASON_MAX, WASTE_REASONS_MAX, SettingStore, clean_waste
from ..sync.pgstore import ReadOnlyError as SettingsReadOnly
from ..waste import MAX_DAYS, NAME_MAX, NOTE_MAX, QTY_MAX, ReadOnlyError, Refused, WasteLog
from .auth import holder_from, manager_from, powers_of, session_of

DAY = r"^\d{4}-\d{2}-\d{2}$"


class WastedIn(BaseModel):
    staff_id: str = Field(max_length=120)
    variant_id: str | None = Field(None, max_length=120)
    entry_id: str | None = Field(None, max_length=120)
    name: str = ""
    qty: int = 1
    reason: str = ""
    note: str = ""
    device: str = ""


class StrikeIn(BaseModel):
    staff_id: str = Field("", max_length=120)


class WasteReasonsIn(BaseModel):
    """Why food goes into the waste log: short words, in the order the buttons show."""

    reasons: list[str] = Field(default_factory=list)


def add_waste_log(app: FastAPI) -> None:
    def log() -> WasteLog:
        return app.state.waste

    def reasons() -> list[str]:
        return list(app.state.settings.get("waste")["reasons"])

    def refused(err: Refused) -> HTTPException:
        status = (
            404 if err.code.startswith("unknown_") else 409 if err.code in ("not_yours", "past", "too_many") else 422
        )
        return HTTPException(status, {"error": err.code, "message": err.message})

    def known(staff_id: str) -> tuple[str, str]:
        directory: Directory = app.state.staff
        person = directory.get(staff_id)
        if person is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        return person.staff_id, person.name

    def a_day(asked: str) -> date:
        try:
            return date.fromisoformat(asked)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": "That is not a day."}) from err

    def dish(variant_id: str, entry_id: str | None) -> tuple[str, str, Decimal | None]:
        """A dish of the menu as the log keeps it: its name as a check would say it, its code, and the
        menu's price of one (none for a dish whose price is typed when it is rung)."""
        defs = app.state.menu.defs
        variant = defs.variants.get(variant_id)
        item = defs.items.get(variant.item) if variant is not None else None
        if variant is None or item is None:
            raise HTTPException(
                422, {"error": "unknown_dish", "message": "That dish is not on the menu any more. Type what it was."}
            )
        name = defs.localizer.text(item.names, "en")
        if len(defs.variants_of(item.code)) > 1:
            name = f"{name} ({defs.localizer.text(variant.names, 'en')})"
        price: Decimal | None = variant.base_price
        entry = defs.entry(entry_id) if entry_id else None
        if entry is not None and entry.item == item.code and variant_id in entry.price_overrides:
            price = entry.price_overrides[variant_id]
        return name, item.code, None if item.asks_price else price

    @app.get("/waste")
    def read_waste(day: str | None = Query(None, pattern=DAY, description="a day of service")) -> dict[str, Any]:
        """One day of the waste log, the newest entry first, with what stands of it added up."""
        return {
            **log().day(a_day(day) if day else None),
            "reasons": reasons(),
            "limits": {"name": NAME_MAX, "note": NOTE_MAX, "qty": QTY_MAX},
        }

    @app.post("/waste")
    def write_waste(body: WastedIn) -> dict[str, Any]:
        """Somebody writes down food that was wasted: a dish of the menu or something typed, how many, and
        why. It is no sale and touches none."""
        staff_id, staff_name = known(body.staff_id)
        name, item, each = (body.name, None, None) if not body.variant_id else dish(body.variant_id, body.entry_id)
        try:
            entry = log().log(
                name=name,
                qty=body.qty,
                reason=body.reason,
                reasons=reasons(),
                note=body.note,
                item=item,
                variant_id=body.variant_id or None,
                each=each,
                by_id=staff_id,
                by=staff_name,
                device=body.device,
            )
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return entry.as_json()

    @app.post("/waste/{entry_id}/strike")
    def strike_waste(entry_id: str, body: StrikeIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Strikes an entry out: the person who wrote it, the same day, or a manager. It stays readable."""
        grant = session_of(app.state.tokens, authorization)
        try:
            if grant is not None and holds(powers_of(app.state), grant.role, "waste"):
                entry = log().strike(entry_id, by_id=grant.staff_id, by=grant.name, manager=True)
            else:
                staff_id, staff_name = known(body.staff_id)
                entry = log().strike(entry_id, by_id=staff_id, by=staff_name, manager=False)
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        return entry.as_json()

    @app.get("/reports/waste")
    def read_waste_report(
        first: str | None = Query(None, alias="from", pattern=DAY, description="the first day of service"),
        last: str | None = Query(None, alias="to", pattern=DAY, description="the last day of service"),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """The waste of a span of days added up by day, by reason and by dish."""
        holder_from(app.state, authorization, "waste")
        if first is None and last is None:
            today = localtime.service_day_of(log().now_ms())
            span = (today, today)
        else:
            span = (a_day(first or last or ""), a_day(last or first or ""))
        try:
            return log().report(*span)
        except Refused as err:
            if err.code == "too_long":
                raise HTTPException(422, {"error": err.code, "message": err.message, "max_days": MAX_DAYS}) from err
            raise HTTPException(422, {"error": "bad_value", "message": err.message}) from err

    @app.get("/settings/waste")
    def read_waste_reasons() -> dict[str, Any]:
        """Why food goes into the waste log: `reasons`, the words on the buttons, in their order; and the
        `limits` of the list."""
        return {**app.state.settings.get("waste"), "limits": {"reasons": WASTE_REASONS_MAX, "reason": WASTE_REASON_MAX}}

    @app.put("/settings/waste")
    def write_waste_reasons(body: WasteReasonsIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """A manager lists the reasons. Entries carry the words themselves, so a reason reworded or dropped
        changes nothing in the log as it stands."""
        manager_from(app.state.tokens, authorization)
        try:
            cleaned = clean_waste(body.model_dump())
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        settings: SettingStore = app.state.settings
        try:
            saved = settings.put("waste", cleaned)
        except SettingsReadOnly as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        app.state.feed.changed("settings")
        return {**saved, "limits": {"reasons": WASTE_REASONS_MAX, "reason": WASTE_REASON_MAX}}
