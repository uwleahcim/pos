"""A check's history on the wire. The steps are worked out in `pos.orders.history`; this is the call.

- `GET /orders/{order_id}/history` (manager token): `order`, what the check is (its table or number, whose
  it is, where it stands, when it was opened), and `steps`, everything that happened to it, oldest first.
  404 for an order the log has never heard of.

Reading a history changes nothing: it is the log of the order, said in steps.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Header, HTTPException

from ..identity.photos import PhotoStore
from ..identity.staff import Directory
from ..menu.service import MenuService
from ..orders.history import history
from .auth import manager_from


def add_history(app: FastAPI) -> None:
    @app.get("/orders/{order_id}/history")
    def read_history(order_id: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Everything that happened to one check, oldest first: who did what, at which screen and when."""
        manager_from(app.state.tokens, authorization)
        store = app.state.store
        state = store.view(order_id)
        if state is None:
            raise HTTPException(404, {"error": "unknown_id", "message": "There is no such check."})
        photos: PhotoStore = app.state.photos
        staff: Directory = app.state.staff
        menu: MenuService = app.state.menu

        def photo_of(op_id: str) -> tuple[str, str | None] | None:
            photo = photos.for_op(op_id)
            return None if photo is None else (photo.photo_id, photo.staff_id)

        def name_of(staff_id: str) -> str | None:
            person = staff.get(staff_id)
            return None if person is None else person.name

        def table_of(other: str) -> Any:
            there = store.view(other)
            return None if there is None else there.fields.get("table")

        steps = history(
            store.for_order(order_id),
            order_id,
            rules=app.state.pricing,
            allergens={a.code: menu.defs.localizer.text(a.names, "en") for a in menu.defs.allergens.values()},
            courses={str(c["id"]): str(c["name"]) for c in app.state.settings.get("coursing")["courses"]},
            photo_of=photo_of,
            name_of=name_of,
            table_of=table_of,
        )
        fields = state.fields
        return {
            "order": {
                "order_id": order_id,
                "status": state.status,
                "table": fields.get("table"),
                "order_no": fields.get("order_no"),
                "customer_name": fields.get("customer_name") or "",
                **({"tab": True} if state.is_tab else {}),  # a bar tab, called by its name
                "order_type": fields.get("order_type") or "dine_in",
                "server": fields.get("server") or "",
                "guests": fields.get("guests"),
                "opened_ms": state.first.wall_ms if state.first is not None else None,
                "merged_into": fields.get("merged_into"),
            },
            "steps": steps,
        }
