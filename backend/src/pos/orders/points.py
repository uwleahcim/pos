"""Points: what the guest who pays a check earns on it (docs/points.md).

A guest is a phone number (`pos.orders.guests`), and the money of a check is one guest's, the one who pays
(`payer_of`). Where the owner set a rate, that guest earns points on the check: so many a dollar of what it
came to before tax, charges and tips, less comps and discounts. Nothing is kept for it: a guest's points
are read off the same orders as the guest list, so they are right whatever happened to a check afterwards.
A check that was reopened and changed earns what it comes to now; one voided earns nothing; one whose
payer is said afterwards earns for that guest from then on.

The rules are the owner's, and all of them are a setting (`points`, Location › Points):

- how many points a dollar earns (`per_dollar`; 0, as it is until somebody sets it, is off: nobody earns);
- what earns: tables, to-go orders, deliveries, catering orders, each on or off, and whether alcoholic
  drinks earn (the lines taxed as alcohol, `pos.orders.sales.class_net`; off unless turned on);
- how long points last (`days`): a check's points count for that many days from its day, a year at most,
  since that is as far back as the guest list reads.

A rule set counts from the day it was saved: every save that changes what earns is kept as a version with
its first day (`from`), and a check earns by the version in force on the day it counts on. So a rate
changed today moves no points already earned. How long points last is one figure for all of them.

A check earns once it is closed: an open one is still being rung, and says so. Points are whole: what a
check earns is rounded down.

Nothing here takes anything off a check, a bill or a sale: points are a count beside the guest list.
Spending them is not part of this.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import ROUND_FLOOR, Decimal, InvalidOperation
from typing import Any

from .day import ZERO

PER_DOLLAR_MOST = Decimal(100)
DAYS_LEAST = 30
DAYS_MOST = 365
"""How long points last at most: the days the guest list reads (`pos.orders.guests.LOOK_BACK_DAYS`)."""
VERSIONS_KEPT = 60
"""How many versions of the rules are kept at most; the oldest go first."""
VERSIONS_REACH = 400
"""A version that ended more days ago than this governs no check a guest's points are read off."""
EARLIER_SHOWN = 5
KINDS = ("dine_in", "takeout", "delivery")
"""The kinds of order a rule turns on or off; a bar tab counts with the tables."""
OFF = "off"
OPEN = "open"
OTHER = "other"
WAITS = "waits"
KIND = "kind"
CATERING = "catering"
NOTHING = "nothing"
GONE = "gone"
"""Why a visit earned nothing, for the guest list to say: no rate was set that day; the check is still open;
another guest paid it; nobody said who paid; that kind of order does not earn; catering does not earn;
nothing on it earns (comped, or drinks alone); or its points are older than they last."""


@dataclass(frozen=True)
class Rule:
    """What earns, from one day on."""

    since: date
    per_dollar: Decimal = ZERO
    alcohol: bool = False
    dine_in: bool = True
    takeout: bool = True
    delivery: bool = True
    catering: bool = True
    by: str = ""

    @property
    def on(self) -> bool:
        return self.per_dollar > ZERO

    def same_as(self, other: Rule) -> bool:
        """Whether both earn the same, whenever they began and whoever set them."""
        return self.earning() == other.earning()

    def earning(self) -> dict[str, Any]:
        return {
            "per_dollar": rate_text(self.per_dollar),
            "alcohol": self.alcohol,
            "dine_in": self.dine_in,
            "takeout": self.takeout,
            "delivery": self.delivery,
            "catering": self.catering,
        }

    def stored(self) -> dict[str, Any]:
        return {"from": self.since.isoformat(), **self.earning(), "by": self.by}

    def earns_kind(self, kind: str) -> bool:
        """Whether an order of this kind earns: a delivery, a table (a bar tab with them), or to go."""
        if kind == "delivery":
            return self.delivery
        if kind in ("dine_in", "tab"):
            return self.dine_in
        return self.takeout


def rate_text(rate: Decimal) -> str:
    """A rate as it is written: "1", "1.5", "0.25"."""
    text = format(rate.normalize(), "f")
    return text if text else "0"


def _rate(value: Any) -> Decimal | None:
    """A rate read: a number from 0 to `PER_DOLLAR_MOST` with two decimals at most. None for anything else."""
    if isinstance(value, bool) or not isinstance(value, int | float | str | Decimal):
        return None
    try:
        rate = Decimal(str(value).strip() or "0")
    except InvalidOperation:
        return None
    if not rate.is_finite() or rate < ZERO or rate > PER_DOLLAR_MOST or rate != rate.quantize(Decimal("0.01")):
        return None
    return rate


def _rule(held: Any) -> Rule | None:
    """One stored version, read with care: a hand-edited or half-written one is no rule."""
    if not isinstance(held, Mapping):
        return None
    try:
        since = date.fromisoformat(str(held.get("from") or ""))
    except ValueError:
        return None
    rate = _rate(held.get("per_dollar", "0"))
    if rate is None:
        return None
    return Rule(
        since=since,
        per_dollar=rate,
        alcohol=held.get("alcohol") is True,
        dine_in=held.get("dine_in") is not False,
        takeout=held.get("takeout") is not False,
        delivery=held.get("delivery") is not False,
        catering=held.get("catering") is not False,
        by=" ".join(str(held.get("by") or "").split())[:120],
    )


@dataclass(frozen=True)
class Points:
    """The rules as they stand: every version, the oldest first, and how long points last."""

    rules: tuple[Rule, ...] = ()
    days: int = DAYS_MOST

    @classmethod
    def of(cls, setting: Mapping[str, Any] | None) -> Points:
        """The setting `points` read; anything in it that is no rule is left out."""
        held = (setting or {}).get("rules")
        rules = sorted(
            (rule for rule in map(_rule, held if isinstance(held, list) else ()) if rule is not None),
            key=lambda rule: rule.since,
        )
        days = (setting or {}).get("days")
        if isinstance(days, bool) or not isinstance(days, int) or not DAYS_LEAST <= days <= DAYS_MOST:
            days = DAYS_MOST
        return cls(tuple(rules), days)

    def stored(self) -> dict[str, Any]:
        return {"rules": [rule.stored() for rule in self.rules], "days": self.days}

    def on(self, day: date) -> Rule | None:
        """The rules in force on a day: the newest version that began by then. None before the first."""
        found = None
        for rule in self.rules:
            if rule.since > day:
                break
            found = rule
        return found

    @property
    def ever(self) -> bool:
        """Whether some version earns: there can be points to show."""
        return any(rule.on for rule in self.rules)

    def counts(self, day: date, today: date) -> bool:
        """Whether points of a check of `day` still count on `today`."""
        return 0 <= (today - day).days < self.days

    def good_until(self, day: date) -> date:
        """The last day on which points of a check of `day` count."""
        return day + timedelta(days=self.days - 1)

    def earned(self, visit: Any, today: date) -> tuple[int, str]:
        """What this visit (`pos.orders.guests.Visit`) earns its guest as of `today`, and why nothing when
        it is nothing (one of the words at the head of this file; empty when it earns)."""
        rule = self.on(visit.day)
        if rule is None or not rule.on:
            return 0, OFF
        if not visit.paid:
            return 0, WAITS if visit.waits else OTHER
        if not visit.closed:
            return 0, OPEN
        if visit.catering and not rule.catering:
            return 0, CATERING
        if not rule.earns_kind(visit.kind):
            return 0, KIND
        base = visit.net - (ZERO if rule.alcohol else visit.alcohol)
        points = int((max(base, ZERO) * rule.per_dollar).to_integral_value(rounding=ROUND_FLOOR))
        if points <= 0:
            return 0, NOTHING
        if not self.counts(visit.day, today):
            return 0, GONE
        return points, ""

    def about(self, today: date) -> dict[str, Any]:
        """The rules in force today, for whoever reads a guest's points: whether anybody earns (`on`),
        whether there can be points at all (`ever`), what earns, and how long points last."""
        rule = self.on(today)
        now = rule if rule is not None else Rule(today)
        return {"on": now.on, "ever": self.ever, **now.earning(), "days": self.days}

    def setting(self, today: date) -> dict[str, Any]:
        """The setting as Location › Points reads it: the rules in force today, since when (`from`) and who
        set them (`by`), since when anything earned at all (`since`), the versions before (`earlier`, the
        newest first, each with its last day), and what a save is held to."""
        rule = self.on(today)
        first = next((one.since for one in self.rules if one.on), None)
        earlier = []
        for at, one in enumerate(self.rules):
            after = self.rules[at + 1] if at + 1 < len(self.rules) else None
            if one is rule or after is None or one.since > today:
                continue
            earlier.append({**one.stored(), "until": (after.since - timedelta(days=1)).isoformat()})
        return {
            **self.about(today),
            "from": rule.since.isoformat() if rule is not None else None,
            "by": rule.by if rule is not None else "",
            "since": first.isoformat() if first is not None else None,
            "earlier": list(reversed(earlier))[:EARLIER_SHOWN],
            "today": today.isoformat(),
            "per_dollar_most": rate_text(PER_DOLLAR_MOST),
            "days_least": DAYS_LEAST,
            "days_most": DAYS_MOST,
        }

    def saved(self, data: Mapping[str, Any], *, today: date, by: str = "") -> Points:
        """The rules after a manager saved `data` today: `per_dollar`, what earns and `days`, each left out
        staying as it is. What earns counts from today: a version of its own, in place of one saved earlier
        today, and none at all when nothing about earning changed. Raises ValueError on a bad value."""
        now = self.on(today)
        was = now if now is not None else Rule(today)
        rate = was.per_dollar
        if data.get("per_dollar") is not None:
            read = _rate(data["per_dollar"])
            if read is None:
                raise ValueError(
                    f"points a dollar is a number from 0 to {rate_text(PER_DOLLAR_MOST)}, to two decimals; 0 is off"
                )
            rate = read
        switches: dict[str, bool] = {}
        for name in ("alcohol", *KINDS, "catering"):
            value = data.get(name)
            if value is None:
                value = getattr(was, name)
            if not isinstance(value, bool):
                raise ValueError(f"{name} is true or false")
            switches[name] = value
        if rate > ZERO and not any(switches[kind] for kind in KINDS):
            raise ValueError("pick at least one kind of order that earns, or set the points a dollar to 0")
        days = self.days if data.get("days") is None else data["days"]
        if isinstance(days, bool) or not isinstance(days, int) or not DAYS_LEAST <= days <= DAYS_MOST:
            raise ValueError(f"points last a whole number of days, from {DAYS_LEAST} to {DAYS_MOST}")
        wanted = Rule(today, rate, by=" ".join(by.split())[:120], **switches)
        # what was saved for a day still to come has no say once today's is saved
        rules = [rule for rule in self.rules if rule.since < today]
        before = rules[-1] if rules else None
        if before is None:
            if wanted.on:
                rules.append(wanted)
        elif not wanted.same_as(before):
            rules.append(wanted)
        return Points(_pruned(rules, today), days)


def _pruned(rules: Sequence[Rule], today: date) -> tuple[Rule, ...]:
    """The versions that can still govern a check whose points are read: the one in force
    `VERSIONS_REACH` days ago and every later one, `VERSIONS_KEPT` at most."""
    reach = today - timedelta(days=VERSIONS_REACH)
    first = 0
    for at, rule in enumerate(rules):
        if rule.since <= reach:
            first = at
    return tuple(rules[first:][-VERSIONS_KEPT:])


@dataclass
class Tally:
    """A guest's points as they stand: how many, and of those the ones that stop counting first."""

    points: int = 0
    next_day: date | None = None  # the last day the oldest of them count
    next_points: int = 0

    def add(self, points: int, until: date) -> None:
        if points <= 0:
            return
        self.points += points
        if self.next_day is None or until < self.next_day:
            self.next_day, self.next_points = until, points
        elif until == self.next_day:
            self.next_points += points

    def next(self) -> dict[str, Any] | None:
        if self.next_day is None:
            return None
        return {"points": self.next_points, "until": self.next_day.isoformat()}


def tally(visits: Iterable[Any], rules: Points, today: date) -> Tally:
    """What these visits of one guest come to in points as of `today`."""
    out = Tally()
    for visit in visits:
        points, _ = rules.earned(visit, today)
        out.add(points, rules.good_until(visit.day))
    return out


__all__ = [
    "CATERING",
    "DAYS_LEAST",
    "DAYS_MOST",
    "GONE",
    "KIND",
    "KINDS",
    "NOTHING",
    "OFF",
    "OPEN",
    "OTHER",
    "PER_DOLLAR_MOST",
    "WAITS",
    "Points",
    "Rule",
    "Tally",
    "rate_text",
    "tally",
]
