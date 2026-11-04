"""The restaurant's own clock. Menu hours, order numbers and "today" are the location's local time
(`POS_TIMEZONE`, America/New_York unless set), whatever zone the hub or the cloud runs in."""

from __future__ import annotations

import os
from datetime import date, datetime
from zoneinfo import ZoneInfo


def zone() -> ZoneInfo:
    return ZoneInfo(os.environ.get("POS_TIMEZONE", "America/New_York"))


def now() -> datetime:
    return datetime.now(zone())


def today() -> date:
    return now().date()


def day_of(wall_ms: int) -> date:
    """The local calendar day a wall-clock stamp (milliseconds since the epoch) falls on."""
    return datetime.fromtimestamp(wall_ms / 1000, zone()).date()
