"""A station's screen (docs/kitchen-screens.md): what the station has to make, as its tickets say it, on a
screen beside the printer or in its place on the wall.

`kitchen_screen` reads the orders and gives the screen its tickets. One ticket is the dishes of one send of an
order that this screen's stations make, in the words the paper ticket has them, routed by the same rule: a
dish stands where it is cooked, the choices a station does not read are left off, a to-go order stands whole
at the station that packs it, and a screen told to print no ticket at a station (`ticket_skips`) sends that
station's screen nothing either.

A cook marks a dish made, or a whole ticket, with a `done` operation on the order (`pos.sync.oplog`): the
kitchen's own word beside the check, which changes no dish, price or payment. A ticket with every dish marked
leaves the screen and is kept among the last ones made, where a tap brings it back.

What is on the screen, and when:

- a dish is on it from the moment it is in the kitchen: when it was sent, or, for an order sent ahead of its
  time, when its paper ticket prints (`PrintService.not_yet`);
- a dish voided while it is still on the screen stays on its ticket, struck out, until the cook marks it
  seen; one that was made before it was voided does not come back;
- a table's check or a bar tab that was closed is off it (the food was eaten), and so is a to-go order marked
  ready or picked up, and an order voided whole;
- a ticket nobody marked leaves by itself after `KEEP_MS`: a screen nobody tends does not fill up for good.

The pass (`passing`) is the screen of whoever calls the orders: every dish of a send on one ticket, each with
the stations that cook it and whether they have made it. The pass has a word of its own, a `done` named `PASS`:
the dish went out. A ticket leaves the pass when all of it went out, and a dish that went out is made at its
stations too, unless a station says otherwise afterwards.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from typing import Any

from ..sync.oplog import Line, OrderState
from .service import SOON_MS, Takes, _ticket_lines, allergy_lines, allergy_words, is_to_go, order_note, starts_ms

KEEP_MS = 4 * 60 * 60 * 1000
"""How long a ticket stays on a screen when nobody marks it: past this the food is long gone from the kitchen."""
RECENT = 10
"""How many of the tickets a station finished last it keeps at hand, to bring one back."""
MINUTES = {"warn": 10, "late": 20}
"""After how many minutes a ticket turns amber and then red, until the location says otherwise."""
PASS = "*pass"
"""What a `done` of the pass names in place of a station: the dish went out to the guest. No station's code
can be this (`pos.settings.STATION`)."""


def _stations(line: Line) -> list[str | None]:
    return [k.get("station") for k in (line.priced or {}).get("kitchen") or [{}]]


def _said(line: Line, station: str) -> int | None:
    """When `station` said this dish is made, or when the pass sent it out with the station silent since; None
    while it is still the station's to make."""
    at = line.done.get(station)
    if at is not None:
        return at
    out = line.done.get(PASS)
    if out is None:
        return None
    word, passed = line.done_stamps.get(station), line.done_stamps.get(PASS)
    if word is not None and (passed is None or word > passed):
        return None  # the station took its word back after the dish went out: its later word stands
    return out


def _due(state: OrderState) -> int | None:
    """When the tickets of an order made for a time print (`lead_delay`); None for one that names no time."""
    start = starts_ms(state) if is_to_go(state) else None
    return None if start is None else start - SOON_MS


def kitchen_screen(
    states: Iterable[OrderState],
    stations: Iterable[str],
    *,
    now_ms: int,
    waiting: Callable[[OrderState], frozenset[str]] = lambda state: frozenset(),
    takeout: str | None = None,
    skips: Callable[[str], frozenset[str]] = lambda device: frozenset(),
    station_names: Mapping[str, str] | None = None,
    course_names: Mapping[str, str] | None = None,
    allergens: Mapping[str, str] | None = None,
    minutes: Mapping[str, int] | None = None,
    passing: bool = False,
) -> dict[str, Any]:
    """The screen of `stations` (one as a rule; a screen can stand for two woks): `tickets`, the ones still to
    make, the longest in the kitchen first, and `recent`, the last `RECENT` it finished, the latest first.

    A ticket says whose it is (`table`, `tab`, or `order_no` and `customer` of a to-go order with `channel`
    and `promised_ms`), `server`, `guests`, `course`, since when it is in the kitchen (`since_ms`), the
    allergies told on the order, what the customer wrote for the whole of it (`note`: an online order's
    instructions), the other stations cooking for the same send (`also_at`) and its `lines`.
    A line is a dish as the paper ticket words it (`qty`, `label`, `modifiers` with their `depths`, `note`,
    `seat`, `header`, `allergy`), the order line it stands for (`line_id`), the stations of this screen that
    make it (`stations`: what a `done` names) and the ones of them that said it is made (`made`), and whether
    it is `done` (all of them did), a `void`, or `changed` after it was sent. `warn` and `late` are the
    minutes after which a ticket turns amber and red.

    `waiting(state)` is the sent dishes of an order that are not in the kitchen yet; `skips(device)` the
    stations the screen that sent a dish prints no ticket at.

    `passing` makes it the pass: the dishes of `stations` (none named: of every station) whole on one ticket,
    never a to-go order a second time for the bag. A line's `stations` is then the pass itself (`PASS`: what
    its `done` names), `done` says it went out, and `cooks` lists where it is cooked (`code`, `name`) and
    whether that station has `made` it."""
    own = frozenset(stations)
    names = station_names or {}
    courses = course_names or {}
    open_: list[dict[str, Any]] = []
    made: list[dict[str, Any]] = []
    for state in states:
        to_go = is_to_go(state)
        if state.status == "void":
            continue
        if to_go and state.fields.get("stage") in ("ready", "out", "picked_up"):
            continue
        if not to_go and state.status != "open":
            continue
        held = waiting(state)
        whole = takeout if to_go and takeout in own and not passing else None
        by_seat = {
            told["seat"]: allergy_words(told, allergens or {}) for told in state.allergy_list() if told.get("seat")
        }
        # the dishes by the send they went with: all of them, to say who else cooks for it
        due = _due(state)
        sends: dict[int, list[Line]] = {}
        for line in state.ordered_lines():
            if line.fired_at is None or line.line_id in held or line.status == "removed":
                continue
            # in the kitchen since it was sent, or for an order sent ahead of its time, since that time came.
            # It does not move with the clock, so a ticket keeps its place
            sent = line.fired_at.wall_ms
            if due is not None and due > sent:
                if due > now_ms:
                    continue  # moved to a later time after it was sent: not the kitchen's until then
                sent = due
            sends.setdefault(sent, []).append(line)
        for since, lines in sends.items():
            if now_ms - since > KEEP_MS:
                continue
            rows: list[dict[str, Any]] = []
            others: dict[str, None] = {}
            for line in lines:
                skip = skips(line.fired_at.node) if line.fired_at is not None else frozenset()
                # (the pass with no station named stands for all of them, like a kitchen's one printer)
                takes = Takes(own=own, first=passing and not own, whole=None if whole in skip else whole, skip=skip)
                here = sorted({s for s in _stations(line) if s is not None and takes.cooks(s)})
                if takes.whole is not None and takes.whole not in here:
                    here.append(takes.whole)
                for station in _stations(line):
                    if station is not None and not takes.cooks(station) and station != takeout and station not in skip:
                        if line.active:
                            others.setdefault(names.get(station) or station)
                if not here and not passing:
                    continue
                void = line.status == "void"
                if passing:
                    marks, at = [PASS], line.done.get(PASS)
                    told = marks if at is not None else []
                    done = at is not None
                else:
                    marks = here
                    told = [station for station in here if _said(line, station) is not None]
                    done = len(told) == len(here)
                    at = max((_said(line, station) or 0 for station in here), default=0) if done else None
                if void and done:
                    continue  # made before it was voided: nothing for the cook to stop
                for said in _ticket_lines([line], takes, void=void, allergies=by_seat):
                    cooks = [
                        {"code": station, "name": names.get(station) or station, "made": station in line.done}
                        for station in said.stations
                        if takes.cooks(station)
                    ]
                    rows.append(
                        {
                            "line_id": line.line_id,
                            "stations": marks,
                            "made": told,
                            **({"cooks": cooks} if passing else {}),
                            "qty": said.qty,
                            "label": said.label,
                            "modifiers": list(said.modifiers),
                            "depths": list(said.depths),
                            "note": said.note,
                            "seat": said.seat,
                            "header": said.header or "",
                            "allergy": said.allergy,
                            "void": void,
                            "changed": said.changed,
                            "done": done,
                            "done_ms": at,
                        }
                    )
            if not rows:
                continue
            fields = state.fields
            course_ids = {line.course for line in lines if line.active}
            course = course_ids.pop() if len(course_ids) == 1 else None
            promised = fields.get("promised_at")
            ticket = {
                "id": f"{state.order_id}:{since}",
                "order_id": state.order_id,
                "since_ms": since,
                "table": str(fields.get("table") or ""),
                "tab": state.tab_name,
                "order_no": fields.get("order_no") if isinstance(fields.get("order_no"), int) else None,
                "customer": str(fields.get("customer_name") or "") if to_go else "",
                "to_go": to_go,
                "channel": str(fields.get("channel") or "") if to_go else "",
                "promised_ms": promised
                if to_go and isinstance(promised, int) and not isinstance(promised, bool)
                else None,
                "server": str(fields.get("server") or ""),
                "guests": fields.get("guests") if isinstance(fields.get("guests"), int) else None,
                "course": (courses.get(course) or course) if course else "",
                "allergies": list(allergy_lines(state, allergens or {})),
                # what the customer wrote for the whole order (an online order's instructions)
                "note": order_note(state),
                "also_at": list(others),
                "lines": rows,
            }
            if all(row["done"] for row in rows):
                ticket["done_ms"] = max(row["done_ms"] or 0 for row in rows)
                made.append(ticket)
            else:
                open_.append(ticket)
    open_.sort(key=lambda ticket: (ticket["since_ms"], ticket["id"]))
    made.sort(key=lambda ticket: (-ticket["done_ms"], ticket["id"]))
    times = {**MINUTES, **(minutes or {})}
    return {
        **({"pass": True} if passing else {}),
        "stations": [{"code": code, "name": names.get(code) or code} for code in sorted(own)],
        "warn": int(times["warn"]),
        "late": int(times["late"]),
        "tickets": open_,
        "recent": made[:RECENT],
    }
