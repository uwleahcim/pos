"""The restaurant's own clock. Menu hours, order numbers and "today" are the location's local time
(`POS_TIMEZONE`, America/New_York unless set), whatever zone the hub or the cloud runs in."""

from __future__ import annotations

import os
from datetime import date, datetime, time, timedelta
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


def start_ms(day: date) -> int:
    """The wall-clock stamp (milliseconds since the epoch) at which a local calendar day begins."""
    return int(datetime.combine(day, time.min, zone()).timestamp() * 1000)


NIGHT_ENDS = time(4, 0)
"""When a night's service is over for sure. What was set "for tonight" (a number left on a dish) stops then,
not at midnight: a bar still pouring at half past twelve keeps its counts until it has closed."""


def night_end(at: datetime | None = None) -> datetime:
    """The next time the location's clock reads `NIGHT_ENDS`: when what was set for tonight clears."""
    at = (at or now()).astimezone(zone())
    end = datetime.combine(at.date(), NIGHT_ENDS, zone())
    return end if at < end else datetime.combine(at.date() + timedelta(days=1), NIGHT_ENDS, zone())
