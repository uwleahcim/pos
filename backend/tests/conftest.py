from __future__ import annotations

import itertools

import pytest

from pos.settings import DEFAULTS, SettingStore
from pos.sync.hlc import HLC
from pos.sync.oplog import Op

T0 = 1_800_000_000_000


def make_op(kind: str, order_id: str = "o1", at: int = 0, node: str = "a", **data) -> Op:
    """An op stamped `at` milliseconds after T0 on `node`."""
    return Op(
        op_id=f"{node}-{at}-{next(_seq)}",
        order_id=order_id,
        hlc=HLC(T0 + at, 0, node),
        device=node,
        kind=kind,
        data=data,
    )


_seq = itertools.count()


def servers_void() -> SettingStore:
    """Location settings that let a server void a sent dish with a reason alone: for the tests about what a
    void prints, which have no manager at hand. The default asks for a manager's PIN (tests/orders/test_voids.py)."""
    settings = SettingStore()
    settings.put("voids", {**DEFAULTS["voids"], "approval": "none"})
    return settings


@pytest.fixture
def op():
    return make_op
