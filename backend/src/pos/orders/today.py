"""How far the day has come, beside the same day a week ago at the same time of day.

The day's report says what today's checks come to so far, and the sales report what the same weekday came to
a week ago, the whole of it. Neither says whether tonight is ahead or behind: half past six tonight against
all of last Monday tells nothing. `rung_by` does: the dishes on a day's checks that had been rung in by a
given moment, at the price each is sold at. Asked for today up to now, and for the day a week before up to
the same time of its evening (`same_time`), the two figures are the same measure and can be held side by
side.

It is the dishes sold, before comps, discounts and tax (the day's report's `sales.gross` once the day is
over): the only figure that can be said for a moment gone by, because a dish keeps the time it was rung in
and a discount belongs to the whole check. A check counts on the day the other reports count it on
(`order_day`), so a catering order rung on Tuesday for Saturday is in Saturday's figure from the morning on.
A check voided whole is no sale; a dish with no time kept is left out on both sides.

Like every report, it is reckoned from the log and changes nothing. What each check's dishes come to is
remembered under the exact state of its log (`RungMemo`), so a screen that reads this again every half
minute replays only the checks that changed.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable
from datetime import date
from decimal import Decimal
from typing import Any, NamedTuple

from .. import localtime
from ..sync.oplog import OrderState
from ..tax import TaxProfile
from .adjustments import PricingRules
from .check import check_for
from .day import ZERO, order_day
from .sales import OrderMemo


class Rung(NamedTuple):
    """The dishes on one check: the day it counts on, and for each dish when it was rung in (wall-clock ms)
    and what it sells for."""

    day: date
    lines: tuple[tuple[int, Decimal], ...]


def rung_of(
    state: OrderState,
    taxes: TaxProfile,
    rules: PricingRules | None,
    one: Callable[[Any], Any] | None = None,
) -> Rung | None:
    """The dishes on this check with the time each was rung in, or None for an order that is no sale: one
    with nothing in its log, or voided whole. `one` is `OrderMemo`'s and has nothing to keep here."""
    its_day = order_day(state)
    if its_day is None or state.status == "void":
        return None
    lines = []
    for row in check_for(state, taxes, rules)["lines"]:
        at = state.lines[row["line_id"]].added_at
        if at is not None:
            lines.append((at.wall_ms, Decimal(row["total"])))
    return Rung(its_day, tuple(lines))


class RungMemo(OrderMemo):
    """Each check's `Rung`, remembered (`OrderMemo`): a week of checks is read to hold two of its days side
    by side, so a few thousand, a few hundred bytes each."""

    def __init__(self, keep: int = 6_000, at_once: int = 500) -> None:
        super().__init__(rung_of, keep, at_once)


def rung_by(rungs: Iterable[Rung], day: date, by_ms: int) -> Decimal:
    """What the dishes on `day`'s checks come to that had been rung in before `by_ms`."""
    total = ZERO
    for rung in rungs:
        if rung.day == day:
            for at_ms, amount in rung.lines:
                if at_ms < by_ms:
                    total += amount
    return total


def same_time(now_ms: int, day: date, other: date) -> int:
    """The moment of `other`'s service that is as far into it as `now_ms` is into `day`'s: the same time on
    the restaurant's clock, also across a week in which the clocks were put forward or back."""
    return localtime.service_day(other)[0] + (now_ms - localtime.service_day(day)[0])
