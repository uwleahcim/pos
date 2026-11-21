"""Contests for the staff: who rang in the most of a dish, of a category, or the most sales, between two days.

A manager sets a contest up (`clean_contests`: its name, what counts, the days it runs, the roles that take
part and who sees the numbers), and the hub says who is ahead (`boards`). Nothing is kept of the standings:
each reading adds them up from the same `Sale` of each check as the sales report and Dishes sold
(`pos.orders.sales`), so a contest can never say anything those reports do not, and nothing here changes a
sale, a price or anybody's pay. A contest is a board to look at.

What counts, exactly as in the reports:

- A dish counts for **whoever rang it in** (the line's `by_id`, else the name it carries), the way the day's
  report lists its sales by staff. Several people can ring on one check, and each gets their own dishes.
- It counts on the day its check counts on: the day the check was opened, or the day it is promised for
  when that is later. A contest runs over whole days of service, the first and the last included.
- A dish voided or taken off counts for nobody, and neither does anything on a check voided whole. A dish
  that was comped was still sold: it counts, at its price, before comps and discounts.
- `sales` adds up the money of every dish a person rang; `dish` counts one dish in all its sizes;
  `category` counts every dish of one category, by the menu as it stands now. A dish chosen inside another
  (the soup of a lunch special) is an option of that dish, not a dish sold, as in Dishes sold.

Who takes part is said by role (to start the servers and the bartenders), from the staff as it stands now:
a manager who rings in a table when it is busy does not top the board unless the contest lists managers.
What the others rang is added up apart (`others`), so the board can be held against the reports.

Who sees what is the manager's choice for each contest (`board`): `own`, each person their own number and
place and the name of whoever is in front; or `all`, everybody the whole board with every number. The whole
board of any contest is otherwise a report, read with the `reports` power.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from typing import Any

from ..identity.powers import ALWAYS, HANDED
from ..identity.staff import Staff
from ..menu.defs import Definitions
from .day import ZERO, _Menu
from .sales import MAX_DAYS, Sale

COUNTS = ("sales", "dish", "category")
"""What a contest can count: the money of every dish, one dish, or the dishes of one category."""
BOARDS = ("own", "all")
"""Who sees the numbers: each person their own, or everybody everybody's."""
ROLES = (*HANDED, *sorted(ALWAYS))
"""The roles that can take part, in the order the screen lists them."""
STANDARD_ROLES = ("server", "bartender")
"""Who takes part unless the contest says otherwise: the people who sell."""
CONTESTS_MAX = 12
"""How many contests the location keeps, old ones included: a manager takes one away to make room."""
CONTEST_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NAME_MAX = 40
"""A contest's name: one line on a phone."""
NOTE_MAX = 80
"""The words under the name: what the winner gets."""
CODE_MAX = 120
"""A dish's or a category's code, as the menu keeps it."""
RECENT_DAYS = 7
"""How long after its last day a contest stays on the staff's screens, so everybody sees how it ended."""


@dataclass(frozen=True)
class Contest:
    """One contest as the setting keeps it."""

    id: str
    name: str
    counts: str
    first: date
    last: date
    roles: tuple[str, ...] = STANDARD_ROLES
    board: str = "own"
    note: str = ""
    item: str | None = None  # the dish, when it counts one
    category: str | None = None  # the category, when it counts one
    what: str = ""  # what that dish or category was called when the contest was saved
    set_by: str = ""  # the manager who saved it last, and when
    set_ms: int = 0

    @classmethod
    def of(cls, stored: Mapping[str, Any]) -> Contest | None:
        """A stored contest, or None for one that does not read (the setting is checked when it is saved, so
        that is one written by something else)."""
        try:
            first, last = date.fromisoformat(str(stored["first"])), date.fromisoformat(str(stored["last"]))
            counts, ident = str(stored["counts"]), str(stored["id"])
        except (KeyError, ValueError):
            return None
        if counts not in COUNTS or not ident or first > last:
            return None
        roles = stored.get("roles")
        return cls(
            id=ident,
            name=str(stored.get("name") or ""),
            counts=counts,
            first=first,
            last=last,
            roles=tuple(str(role) for role in roles) if isinstance(roles, list | tuple) else STANDARD_ROLES,
            board=stored.get("board") if stored.get("board") in BOARDS else "own",
            note=str(stored.get("note") or ""),
            item=str(stored["item"]) if counts == "dish" and stored.get("item") else None,
            category=str(stored["category"]) if counts == "category" and stored.get("category") else None,
            what=str(stored.get("what") or ""),
            set_by=str(stored.get("set_by") or ""),
            set_ms=stored["set_ms"] if isinstance(stored.get("set_ms"), int) else 0,
        )

    @property
    def by_money(self) -> bool:
        """Whether the board goes by the money (`sales`) and not by how many (`dish`, `category`)."""
        return self.counts == "sales"

    def state(self, today: date) -> str:
        """`coming`, `running` or `over`, by the day of service that is running."""
        return "coming" if today < self.first else "over" if today > self.last else "running"

    def shown(self, today: date) -> bool:
        """Whether the staff's screens still show it: until a week after its last day."""
        return today <= self.last + timedelta(days=RECENT_DAYS)

    def stored(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "note": self.note,
            "counts": self.counts,
            "item": self.item,
            "category": self.category,
            "what": self.what,
            "first": self.first.isoformat(),
            "last": self.last.isoformat(),
            "roles": list(self.roles),
            "board": self.board,
            "set_by": self.set_by,
            "set_ms": self.set_ms,
        }

    def about(self, today: date, defs: Definitions | None = None) -> dict[str, Any]:
        """The contest as a screen is told it: what is stored, with what it counts called as the menu calls
        it today, where it stands (`state`) and whether the staff's screens show it."""
        return {
            **self.stored(),
            "what": self.what_now(defs),
            "state": self.state(today),
            "shown": self.shown(today),
            "days": (self.last - self.first).days + 1,
        }

    def what_now(self, defs: Definitions | None) -> str:
        """What its dish or category is called on the menu today; the name it was saved under for one the
        menu no longer has. Empty for a contest on sales."""
        if defs is None:
            return self.what
        names = None
        if self.item is not None and self.item in defs.items:
            names = defs.items[self.item].names
        elif self.category is not None and self.category in defs.categories:
            names = defs.categories[self.category].names
        return (defs.localizer.text(names, "en") if names else "") or self.what

    def same_rules(self, other: Contest) -> bool:
        """Whether two contests count the same thing over the same days for the same people, shown the same
        way: everything but who saved it and when."""
        mine, theirs = self.stored(), other.stored()
        return all(mine[key] == theirs[key] for key in mine if key not in ("set_by", "set_ms", "what"))


def categories_on(defs: Definitions) -> list[dict[str, str]]:
    """The categories a contest can count: every one with a dish on sale, in the menu's order, each with its
    `code`, its `name` and the `menu` it stands on (Food, Drinks), as the reports name them."""
    menu = _Menu(defs)
    shown = {entry.item for entry in defs.entries if entry.visible}
    place = {code: i for i, code in enumerate(defs.menus)}
    found: dict[str, tuple[Any, dict[str, str]]] = {}
    for code, item in defs.items.items():
        if not item.active or code not in shown or item.category in found:
            continue
        menu_code, menu_name, category_code, category_name = menu.of({"item": code})
        category = defs.categories.get(category_code)
        order = (place.get(menu_code, len(place)), category.sort if category is not None else 0, category_name)
        found[category_code] = (order, {"code": category_code, "name": category_name, "menu": menu_name})
    return [about for _, about in sorted(found.values(), key=lambda pair: pair[0])]


def contests_of(setting: Mapping[str, Any] | None) -> list[Contest]:
    """The contests a stored setting holds, in its order."""
    listed = (setting or {}).get("contests")
    read = (Contest.of(entry) for entry in listed or () if isinstance(entry, Mapping))
    return [contest for contest in read if contest is not None]


def _words(value: Any, what: str, most: int, *, needed: bool = False) -> str:
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise ValueError(f"{what} is words")
    words = " ".join(value.split())
    if needed and not words:
        raise ValueError(f"a contest needs {what}")
    if len(words) > most:
        raise ValueError(f"{what} is at most {most} characters")
    if not words.isprintable():
        raise ValueError(f"{what} has a character that cannot be shown")
    return words


def _day(value: Any, what: str) -> date:
    if isinstance(value, str) and DAY.match(value):
        try:
            return date.fromisoformat(value)
        except ValueError:
            pass  # the 30th of February
    raise ValueError(f"{what} is a day, as 2026-11-21")


def _new_id(name: str, taken: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:28] or "contest"
    if base not in taken:
        return base
    n = 2
    while f"{base}-{n}" in taken:
        n += 1
    return f"{base}-{n}"


def clean_contests(data: Mapping[str, Any]) -> dict[str, Any]:
    """The contests as the app may set them, checked: `contests`, a list, each with its `name`, what it
    `counts` (`sales`, or `dish` with the dish's `item`, or `category` with the `category`), its `first` and
    `last` day, the `roles` that take part (the servers and the bartenders when left out), who sees the
    numbers (`board`: `own` or `all`) and a `note` under the name (what the winner gets). A contest without
    an `id` is new and is given one from its name. Whether the dish or the category is on the menu is the
    caller's to check: this knows no menu. Raises ValueError on a bad value."""
    raw = data.get("contests")
    if raw is None:
        raw = []
    if not isinstance(raw, list | tuple) or not all(isinstance(entry, Mapping) for entry in raw):
        raise ValueError("contests must be a list")
    if len(raw) > CONTESTS_MAX:
        raise ValueError(f"at most {CONTESTS_MAX} contests are kept: take an old one away first")
    taken = {entry["id"] for entry in raw if isinstance(entry.get("id"), str) and entry["id"]}
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for entry in raw:
        name = _words(entry.get("name"), "a name", NAME_MAX, needed=True)
        ident = entry.get("id")
        if ident is None or ident == "":
            ident = _new_id(name, taken)
            taken.add(ident)
        elif not isinstance(ident, str) or not CONTEST_ID.match(ident):
            raise ValueError(f"{name}: its id is letters, digits, - and _")
        if ident in seen:
            raise ValueError(f"{name}: two contests have the id {ident!r}")
        seen.add(ident)
        counts = entry.get("counts")
        if counts not in COUNTS:
            raise ValueError(f"{name}: it counts sales, a dish or a category")
        code = entry.get({"dish": "item", "category": "category"}.get(counts, ""))
        if counts != "sales" and (not isinstance(code, str) or not code or len(code) > CODE_MAX):
            raise ValueError(f"{name}: say which {counts} it counts")
        first = _day(entry.get("first"), f"{name}: its first day")
        last = _day(entry.get("last"), f"{name}: its last day")
        if first > last:
            raise ValueError(f"{name}: its first day is after its last")
        if (last - first).days + 1 > MAX_DAYS:
            raise ValueError(f"{name}: a contest runs {MAX_DAYS} days at most")
        roles = entry.get("roles")
        if roles is None:
            roles = list(STANDARD_ROLES)
        if not isinstance(roles, list | tuple) or not all(isinstance(role, str) for role in roles):
            raise ValueError(f"{name}: the roles that take part must be a list of words")
        for role in roles:
            if role not in ROLES:
                raise ValueError(f"{name}: unknown role: {role}")
        if not roles:
            raise ValueError(f"{name}: somebody has to take part")
        board = entry.get("board")
        if board is None:
            board = "own"
        if board not in BOARDS:
            raise ValueError(f"{name}: the board is own or all")
        set_ms = entry.get("set_ms")
        out.append(
            {
                "id": ident,
                "name": name,
                "note": _words(entry.get("note"), f"{name}: its note", NOTE_MAX),
                "counts": counts,
                "item": code if counts == "dish" else None,
                "category": code if counts == "category" else None,
                "what": _words(entry.get("what"), f"{name}: what it counts", CODE_MAX) if counts != "sales" else "",
                "first": first.isoformat(),
                "last": last.isoformat(),
                "roles": [role for role in ROLES if role in roles],  # in the screen's order, each once
                "board": board,
                "set_by": _words(entry.get("set_by"), f"{name}: who set it", CODE_MAX),
                "set_ms": set_ms if isinstance(set_ms, int) and not isinstance(set_ms, bool) and set_ms > 0 else 0,
            }
        )
    return {"contests": out}


class _Rung:
    """What one person rang that counts: how many and for how much."""

    __slots__ = ("amount", "count")

    def __init__(self) -> None:
        self.count = 0
        self.amount = ZERO

    def add(self, count: int, amount: Decimal) -> None:
        self.count += count
        self.amount += amount

    def row(self) -> dict[str, Any]:
        return {"count": self.count, "amount": str(self.amount)}


@dataclass
class Board:
    """Where one contest stands: the people who take part, the one in front first, and what the others
    rang of the same."""

    contest: Contest
    rows: list[dict[str, Any]]
    total: dict[str, Any]
    others: dict[str, Any]

    @property
    def front(self) -> list[str]:
        """Who is in front, by name: several when they are level, nobody while nothing counts yet."""
        return [row["name"] for row in self.rows if row["place"] == 1]

    def of(self, staff_id: str) -> dict[str, Any] | None:
        """The row of one person, or None for somebody who does not take part."""
        return next((row for row in self.rows if row["staff_id"] == staff_id), None)

    def whole(self) -> dict[str, Any]:
        """The whole board, as a manager reads it."""
        return {"standings": self.rows, "total": self.total, "others": self.others, "front": self.front}

    def seen_by(self, staff_id: str) -> dict[str, Any]:
        """The board as one person at a screen may see it: their own row, how many take part and who is in
        front; and every row only where the contest says everybody sees the whole board."""
        mine = self.of(staff_id)
        return {
            "takes_part": mine is not None,
            "me": mine,
            "of": len(self.rows),
            "front": self.front,
            "standings": self.rows if self.contest.board == "all" else None,
        }


def boards(
    sales: Iterable[Sale],
    contests: Sequence[Contest],
    *,
    defs: Definitions,
    staff: Sequence[Staff],
) -> dict[str, Board]:
    """Where each of `contests` stands, by its id, from the sales of the orders given: at least every order
    that counts on a day of any of them. One reading of the sales serves them all."""
    by_id = {person.staff_id: person for person in staff}
    by_name: dict[str, Staff | None] = {}
    for person in staff:  # a line with a name and no id is its person's only when one person has that name
        key = person.name.casefold()
        by_name[key] = None if key in by_name else person
    category_of = {code: item.category for code, item in defs.items.items()}
    rung: dict[str, dict[str, _Rung]] = {contest.id: {} for contest in contests}
    others: dict[str, _Rung] = {contest.id: _Rung() for contest in contests}

    for sale in sales:
        if sale.void:
            continue
        running = [contest for contest in contests if contest.first <= sale.day <= contest.last]
        if not running:
            continue
        for line in sale.lines:
            person = by_id.get(line.by_id) if line.by_id else by_name.get(line.by.casefold())
            for contest in running:
                if contest.counts == "dish" and line.item != contest.item:
                    continue
                if contest.counts == "category" and (
                    line.item is None or category_of.get(line.item) != contest.category
                ):
                    continue
                if person is None or person.role not in contest.roles:
                    others[contest.id].add(line.qty, line.amount)
                    continue
                theirs = rung[contest.id].get(person.staff_id)
                if theirs is None:
                    theirs = rung[contest.id][person.staff_id] = _Rung()
                theirs.add(line.qty, line.amount)

    out: dict[str, Board] = {}
    for contest in contests:
        nothing = _Rung()
        ranked: list[tuple[Any, Staff, _Rung]] = []
        for person in staff:
            if person.role not in contest.roles:
                continue
            theirs = rung[contest.id].get(person.staff_id, nothing)
            score = theirs.amount if contest.by_money else theirs.count
            other = theirs.count if contest.by_money else theirs.amount
            ranked.append(((-score, -other, person.name.casefold(), person.staff_id), person, theirs))
        ranked.sort(key=lambda entry: entry[0])
        rows: list[dict[str, Any]] = []
        total = _Rung()
        place, last_score = 0, None
        for position, (order, person, theirs) in enumerate(ranked, 1):
            score = -order[0]
            if score != last_score:  # people level on what counts share a place, and the next one skips
                place, last_score = position, score
            total.add(theirs.count, theirs.amount)
            rows.append(
                {
                    "staff_id": person.staff_id,
                    "name": person.name,
                    "role": person.role,
                    **theirs.row(),
                    "place": place if score > 0 else None,  # nothing yet: no place
                }
            )
        out[contest.id] = Board(contest, rows, total.row(), others[contest.id].row())
    return out
