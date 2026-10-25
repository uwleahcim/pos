from __future__ import annotations

from datetime import UTC, datetime

import pytest

from pos.menu import MenuEngine
from pos.menu.fixtures.example import build_example

DINNER_TIME = datetime(2026, 10, 28, 18, 30, tzinfo=UTC)  # a Wednesday evening
LUNCH_TIME = datetime(2026, 10, 28, 12, 15, tzinfo=UTC)
WEEKEND_LUNCH = datetime(2026, 10, 31, 12, 15, tzinfo=UTC)  # a Saturday


@pytest.fixture
def defs():
    return build_example()


@pytest.fixture
def engine(defs):
    return MenuEngine(defs, now=lambda: DINNER_TIME)
