"""Whose turn the next table is (docs/table-servers.md, "Whose turn it is").

A host who seats a party picks the server, and the floor map shows what each server has on the floor right
now. This says the other thing a host keeps in their head: of the people taking tables tonight, who has
waited longest for one.

**Who is in the turn.** Nobody the hub would have to guess at. A turn that points at somebody who went home
at three is worse than no turn, so a person is in it only when something said so today:

- **A host's word.** Whoever gives tables out puts anybody who takes tables in for tonight, or takes them
  out: cut for the night, on a break, gone home. It holds until the night is over or another word is said.
- **The time clock**, where the location uses it. A server who clocks in is in; whoever clocks out is out.
  A bartender or a manager who clocks in is not put in by that: they take a table when a host gives them
  one, and are in the turn when a host says so.

The later of the two stands. With neither, a person is not in the turn. Where the time clock is off, the
turn is the list the host keeps.

**Whose turn it is.** First the ones who have had no table today, in the order they came in. Then the
others, the one sat longest ago first. A table counts for whoever it is with now, from the moment it was
opened: one handed over counts for the one who took it. A host who passes somebody over changes nothing:
they are still next.

Nothing here is pay, and nothing is kept past the night: the host's words are one location setting (`turn`),
the words of one day of service, written over by the next day's first word. The rest is read from the order
log and the time clock each time it is asked.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date
from typing import Any

from ..sync.oplog import OrderState
from ..timeclock import Shift

TURN_ROLES = ("server",)
"""The roles the time clock puts in the turn by itself."""
NOBODY: dict[str, Any] = {"day": "", "said": {}}
"""The setting before any host has said a word."""


@dataclass(frozen=True)
class Word:
    """The last thing said of one person and tonight's turn: in it (`on`) or out of it, and since when."""

    on: bool
    at_ms: int


def said(stored: Mapping[str, Any], day: date) -> dict[str, Word]:
    """What the hosts have said for `day`, by staff id. Words of another day are nobody's any more, and
    whatever cannot be read was never said."""
    words = stored.get("said")
    if stored.get("day") != day.isoformat() or not isinstance(words, Mapping):
        return {}
    out: dict[str, Word] = {}
    for staff_id, word in words.items():
        if not isinstance(word, Mapping):
            continue
        on, at_ms = word.get("on"), word.get("at_ms")
        if isinstance(on, bool) and isinstance(at_ms, int) and not isinstance(at_ms, bool):
            out[str(staff_id)] = Word(on, at_ms)
    return out


def say(
    stored: Mapping[str, Any], day: date, staff_id: str, on: bool, *, at_ms: int, by_id: str, by: str
) -> dict[str, Any]:
    """The setting with one more word in it: `staff_id` is in tonight's turn, or out of it, as `by` said at
    `at_ms`. The words of an earlier day are dropped with it."""
    kept = stored.get("said") if stored.get("day") == day.isoformat() else None
    words = dict(kept) if isinstance(kept, Mapping) else {}
    words[staff_id] = {"on": on, "at_ms": at_ms, "by_id": by_id, "by": by}
    return {"day": day.isoformat(), "said": words}


def punched(shifts: Iterable[Shift]) -> dict[str, Word]:
    """What the time clock says of each person, from the shifts of one day of service: on the clock in a job
    that takes its turn (`TURN_ROLES`) is in, since they clocked in; clocked out is out, whatever the job.
    A person's latest shift is the one that counts, and one a manager took off counts for nothing."""
    latest: dict[str, Shift] = {}
    for shift in shifts:
        known = latest.get(shift.staff_id)
        if not shift.removed and (known is None or shift.in_ms >= known.in_ms):
            latest[shift.staff_id] = shift
    out: dict[str, Word] = {}
    for staff_id, shift in latest.items():
        if shift.out_ms is not None:
            out[staff_id] = Word(False, shift.out_ms)
        elif shift.role in TURN_ROLES:
            out[staff_id] = Word(True, shift.in_ms)
    return out


def last_sat(orders: Iterable[OrderState], since_ms: int) -> dict[str, int]:
    """When each person's latest table of today was opened (wall-clock ms), by staff id: the checks at a
    table that were opened at or after `since_ms` and are theirs now. A check voided whole was no table, and
    one with no table (a tab at the bar, an order to go) is nobody's turn."""
    out: dict[str, int] = {}
    for state in orders:
        server_id = state.fields.get("server_id")
        if state.status == "void" or state.first is None or state.fields.get("table") in (None, ""):
            continue
        if not isinstance(server_id, str) or not server_id or state.first.wall_ms < since_ms:
            continue
        out[server_id] = max(out.get(server_id, 0), state.first.wall_ms)
    return out


def in_turn(
    takers: Sequence[Mapping[str, Any]],
    words: Mapping[str, Word],
    punches: Mapping[str, Word],
    sat: Mapping[str, int],
) -> list[str]:
    """Tonight's turn: the staff ids of the people in it, whose turn it is first. `takers` are the people a
    table can be given to (`staff_id`, `name`), `words` what the hosts said, `punches` what the time clock
    says (nothing where the location does not use it) and `sat` when each one's latest table was opened."""
    ranked: list[tuple[int, int, str, str]] = []
    for person in takers:
        staff_id = str(person["staff_id"])
        heard = [word for word in (words.get(staff_id), punches.get(staff_id)) if word is not None]
        if not heard:
            continue
        stands = max(heard, key=lambda word: word.at_ms)  # at the same moment the host's word stands
        if not stands.on:
            continue
        sat_ms = sat.get(staff_id)
        waiting = (0, stands.at_ms) if sat_ms is None else (1, sat_ms)
        ranked.append((*waiting, str(person.get("name") or ""), staff_id))
    return [staff_id for *_, staff_id in sorted(ranked)]


__all__ = ["NOBODY", "TURN_ROLES", "Word", "in_turn", "last_sat", "punched", "said", "say"]
