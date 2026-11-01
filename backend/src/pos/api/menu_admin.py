"""The menu editor's calls: read the whole menu, save checked changes, the spreadsheet round-trip, the
audit log. Managers only: a manager signs in with a PIN at /admin/session and sends the token after that.

Every save is checked first (`pos.menu.admin.problems`): a change that would leave a dish without a size,
point at a missing group or break a recipe is refused with the reasons, and nothing is written. A save
names the revision the editor started from, so two managers editing at once cannot overwrite each other.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from ..identity.staff import Directory, Locked
from ..identity.tokens import Grant, Tokens
from ..menu import admin
from ..menu.defs import Definitions, StaleMenu
from ..menu.service import MenuService
from ..menu.sheet import export_workbook, import_workbook
from .auth import manager_from

MENU_EDITORS = frozenset({"manager", "owner"})
XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


class SessionIn(BaseModel):
    device: str
    pin: str


class ChangesIn(BaseModel):
    changes: list[dict[str, Any]]
    revision: int | None = Field(None, description="the revision the editor read; refused if the menu moved")
    dry_run: bool = False


def _checked(defs: Definitions) -> dict[str, Any]:
    errors, warnings = admin.problems(defs)
    return {
        "errors": [admin.problem_out(p) for p in errors],
        "warnings": [admin.problem_out(p) for p in warnings],
    }


def add_menu_admin(app: FastAPI) -> None:
    app.state.tokens = getattr(app.state, "tokens", None) or Tokens()

    def manager(authorization: str | None) -> Grant:
        return manager_from(app.state.tokens, authorization)

    def save(menu: MenuService, defs: Definitions, grant: Grant, revision: int | None) -> dict[str, Any]:
        checked = _checked(defs)
        if checked["errors"]:
            raise HTTPException(422, {"error": "menu_problems", **checked})
        try:
            saved = menu.save(defs, actor=f"{grant.name} ({grant.staff_id})", expect=revision)
        except StaleMenu as err:
            raise HTTPException(409, {"error": "stale", "revision": err.current}) from err
        except ValueError as err:  # a reference the database refused, which the checks above missed
            raise HTTPException(
                422, {"error": "menu_problems", "errors": [{"code": "store", "message": str(err)}]}
            ) from err
        return {**saved, **checked}

    @app.post("/admin/session")
    def start_session(body: SessionIn) -> dict[str, Any]:
        """A manager's PIN for a token the editor sends with each call. Lasts an hour."""
        directory: Directory = app.state.staff
        try:
            found = directory.by_pin(body.pin, device=body.device)
        except Locked as err:
            raise HTTPException(423, {"error": "locked", "seconds": round(err.seconds_left)}) from err
        if found is None:
            raise HTTPException(401, {"error": "unknown_credential"})
        if found.role not in MENU_EDITORS:
            raise HTTPException(403, {"error": "not_allowed", "role": found.role})
        token, grant = app.state.tokens.issue(found.staff_id, found.name, found.role)
        return {
            "token": token,
            "staff_id": grant.staff_id,
            "name": grant.name,
            "role": grant.role,
            "expires": grant.expires,
        }

    @app.get("/admin/menu")
    def read_catalog(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Every definition by kind, the revision to send back with a save, and what `menu check` finds."""
        manager(authorization)
        menu: MenuService = app.state.menu
        menu.refresh(force=True)
        return {"revision": menu.revision, "catalog": admin.catalog(menu.defs), **_checked(menu.defs)}

    @app.post("/admin/menu/changes")
    def change_menu(body: ChangesIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Apply a list of changes. `dry_run` reports what `menu check` would say without saving."""
        grant = manager(authorization)
        menu: MenuService = app.state.menu
        menu.refresh(force=True)
        try:
            new = admin.apply(menu.defs, body.changes)
        except admin.ChangeError as err:
            raise HTTPException(422, {"error": "bad_change", "message": str(err)}) from err
        if body.revision is not None and body.revision != menu.revision:
            raise HTTPException(409, {"error": "stale", "revision": menu.revision})
        if body.dry_run:
            return {"revision": menu.revision, "dry_run": True, **_checked(new)}
        return save(menu, new, grant, body.revision)

    @app.get("/admin/menu/audit")
    def read_audit(limit: int = Query(100, ge=1, le=1000), authorization: str | None = Header(None)) -> dict[str, Any]:
        """Who changed what, newest first, with each row before and after."""
        manager(authorization)
        menu: MenuService = app.state.menu
        return {"changes": menu.store.audit(limit) if menu.store is not None else []}

    @app.get("/admin/menu/workbook")
    def download_workbook(authorization: str | None = Header(None)) -> Response:
        """Items, sizes and menu entries as a spreadsheet, for bulk price changes."""
        manager(authorization)
        menu: MenuService = app.state.menu
        menu.refresh(force=True)
        with tempfile.TemporaryDirectory() as tmp:
            data = export_workbook(menu.defs, Path(tmp) / "menu.xlsx").read_bytes()
        return Response(
            data,
            media_type=XLSX,
            headers={
                "Content-Disposition": 'attachment; filename="menu.xlsx"',
                "X-Menu-Revision": str(menu.revision),
            },
        )

    @app.post("/admin/menu/workbook")
    async def upload_workbook(
        request: Request,
        dry_run: bool = True,
        revision: int | None = None,
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        """An edited spreadsheet. By default a dry run that lists every change; `dry_run=false` saves it."""
        grant = manager(authorization)
        data = await request.body()
        return await run_in_threadpool(_import, data, dry_run, revision, grant)

    def _import(data: bytes, dry_run: bool, revision: int | None, grant: Grant) -> dict[str, Any]:
        menu: MenuService = app.state.menu
        menu.refresh(force=True)
        if revision is not None and revision != menu.revision:
            raise HTTPException(409, {"error": "stale", "revision": menu.revision})
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "menu.xlsx"
            path.write_bytes(data)
            try:
                report, new = import_workbook(menu.defs, path, dry_run=False)
            except Exception as err:  # openpyxl raises many kinds for a file that is not a workbook
                raise HTTPException(422, {"error": "bad_workbook", "message": str(err)}) from err
        out: dict[str, Any] = {"changes": report.changes, "summary": report.summary(), "revision": menu.revision}
        if not report.ok:
            raise HTTPException(422, {"error": "bad_workbook", "errors": report.errors, **out})
        if dry_run or not report.changes:
            return {**out, "dry_run": dry_run, **_checked(new)}
        return {**out, **save(menu, new, grant, revision)}
