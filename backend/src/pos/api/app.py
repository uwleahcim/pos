"""A minimal API around the operation log: append, read, pull.

The same three calls serve a terminal talking to a hub, a hub talking to the cloud, and the cloud
talking back. Phase 1 puts the store in PostgreSQL and adds WebSocket pushes; the shape stays.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from ..sync.hlc import HLC
from ..sync.oplog import KINDS, ClockDriftError, Op, OpStore


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


def create_app(store: OpStore | None = None) -> FastAPI:
    app = FastAPI(title="POS backend", version="0.0.1 (phase 0)")
    app.state.store = store if store is not None else OpStore()
    # Phase 0: the Flutter web build runs from another origin; phase 1 narrows this to the apps' origins.
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"status": "ok", "cursor": app.state.store.cursor}

    @app.post("/orders/{order_id}/ops", status_code=202)
    def append_ops(order_id: str, ops: list[OpIn]) -> dict[str, Any]:
        store: OpStore = app.state.store
        for op in ops:
            if op.order_id != order_id:
                raise HTTPException(400, f"op {op.op_id} belongs to order {op.order_id}")
            if op.kind not in KINDS:
                raise HTTPException(422, {"error": "unknown_kind", "op_id": op.op_id})
        try:
            accepted = store.append(op.to_op() for op in ops)
        except ClockDriftError as err:
            raise HTTPException(422, {"error": "clock_drift", "op_id": err.op.op_id}) from err
        return {"accepted": [op.op_id for op in accepted], "cursor": store.cursor}

    @app.get("/orders")
    def list_orders(status: str | None = Query(None, pattern="^(open|closed|void)$")) -> dict[str, Any]:
        """Every order the store knows, newest activity first; `status` filters."""
        store: OpStore = app.state.store
        states = [store.state(order_id) for order_id in store.order_ids()]
        if status is not None:
            states = [state for state in states if state.status == status]
        states.sort(key=lambda state: state.last or _NEVER, reverse=True)
        return {"orders": [state.snapshot() for state in states], "cursor": store.cursor}

    @app.get("/orders/{order_id}")
    def read_order(order_id: str) -> dict[str, Any]:
        store: OpStore = app.state.store
        ops = store.for_order(order_id)
        if not ops:
            raise HTTPException(404, "no such order")
        return store.state(order_id).snapshot()

    @app.get("/ops")
    def pull_ops(since: int = Query(0, ge=0), limit: int = Query(500, ge=1, le=5000)) -> dict[str, Any]:
        store: OpStore = app.state.store
        ops = store.since(since, limit)
        return {"ops": [op_out(op) for op in ops], "cursor": since + len(ops)}

    return app


app = create_app()
