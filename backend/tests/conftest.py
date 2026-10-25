from __future__ import annotations

import itertools

import pytest

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


@pytest.fixture
def op():
    return make_op
