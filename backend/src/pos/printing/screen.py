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
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from typing import Any

from ..sync.oplog import Line, OrderState
from .service import SOON_MS, Takes, _ticket_lines, allergy_lines, allergy_words, is_to_go, starts_ms

KEEP_MS = 4 * 60 * 60 * 1000
"""How long a ticket stays on a screen when nobody marks it: past this the food is long gone from the kitchen."""
RECENT = 10
"""How many of the tickets a station finished last it keeps at hand, to bring one back."""
MINUTES = {"warn": 10, "late": 20}
"""After how many minutes a ticket turns amber and then red, until the location says otherwise."""


def _stations(line: Line) -> list[str | None]:
    return [k.get("station") for k in (line.priced or {}).get("kitchen") or [{}]]


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
) -> dict[str, Any]:
    """The screen of `stations` (one as a rule; a screen can stand for two woks): `tickets`, the ones still to
    make, the longest in the kitchen first, and `recent`, the last `RECENT` it finished, the latest first.

    A ticket says whose it is (`table`, `tab`, or `order_no` and `customer` of a to-go order with `channel`
    and `promised_ms`), `server`, `guests`, `course`, since when it is in the kitchen (`since_ms`), the
    allergies told on the order, the other stations cooking for the same send (`also_at`) and its `lines`.
    A line is a dish as the paper ticket words it (`qty`, `label`, `modifiers` with their `depths`, `note`,
    `seat`, `header`, `allergy`), the order line it stands for (`line_id`), the stations of this screen that
    make it (`stations`: what a `done` names) and the ones of them that said it is made (`made`), and whether
    it is `done` (all of them did), a `void`, or `changed` after it was sent. `warn` and `late` are the
    minutes after which a ticket turns amber and red.

    `waiting(state)` is the sent dishes of an order that are not in the kitchen yet; `skips(device)` the
    stations the screen that sent a dish prints no ticket at."""
    own = frozenset(stations)
    names = station_names or {}
    courses = course_names or {}
    open_: list[dict[str, Any]] = []
    made: list[dict[str, Any]] = []
    for state in states:
        to_go = is_to_go(state)
        if state.status == "void":
            continue
        if to_go and state.fields.get("stage") in ("ready", "picked_up"):
            continue
        if not to_go and state.status != "open":
            continue
        held = waiting(state)
        whole = takeout if to_go and takeout in own else None
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
                takes = Takes(own=own, whole=None if whole in skip else whole, skip=skip)
                here = sorted({s for s in _stations(line) if s is not None and takes.cooks(s)})
                if takes.whole is not None and takes.whole not in here:
                    here.append(takes.whole)
                for station in _stations(line):
                    if station is not None and station not in own and station != takeout and station not in skip:
                        if line.active:
                            others.setdefault(names.get(station) or station)
                if not here:
                    continue
                done = all(station in line.done for station in here)
                void = line.status == "void"
                if void and done:
                    continue  # made before it was voided: nothing for the cook to stop
                at = max((line.done[station] for station in here), default=0) if done else None
                for said in _ticket_lines([line], takes, void=void, allergies=by_seat):
                    rows.append(
                        {
                            "line_id": line.line_id,
                            "stations": here,
                            "made": [station for station in here if station in line.done],
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
        "stations": [{"code": code, "name": names.get(code) or code} for code in sorted(own)],
        "warn": int(times["warn"]),
        "late": int(times["late"]),
        "tickets": open_,
        "recent": made[:RECENT],
    }
