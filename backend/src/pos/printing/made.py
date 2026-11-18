"""What the floor hears of the kitchen (docs/kitchen-screens.md): the cooks' marks, as the screens of the
people who carry the food read them.

A cook marks a dish made at a station's screen, and the pass marks it gone out (`pos.printing.screen`). Here
those marks are read for a check and for the floor map:

- a dish is **ready** once every station that cooks it has said it is made: a dish of the wok and the sushi
  bar is not ready while one of them still works on it, and says which. The stations are the ones its tickets
  go to, less the ones the screen that sent it prints no ticket at (`ticket_skips`): those never hear of it;
- a dish **went out** once the pass said so, or the server who carried it (the same word, a `done` named
  `PASS`).

A dish the kitchen has said nothing of has no word at all, so a kitchen that works off paper alone changes
nothing on the floor's screens. The words are read off the order's log and change nothing in it: no dish, no
price, no payment.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from typing import Any

from ..sync.oplog import Line, OrderState
from .screen import PASS, _said, _stations


def kitchen_word(
    line: Line, *, skip: Iterable[str] = (), station_names: Mapping[str, str] | None = None
) -> dict[str, Any] | None:
    """What the kitchen has said of a dish that was sent, or None while it has said nothing (and for a dish
    that was not sent, or is off the check).

    `cooks` lists the stations that cook it (`code`, `name`) and whether each has `made` its part. `ready_ms`
    is when the last of them did, there once all of them have. `out_ms` is when it went out."""
    if line.fired_at is None or not line.active:
        return None
    names = station_names or {}
    left = frozenset(skip)
    cooks = sorted({station for station in _stations(line) if station is not None and station not in left})
    said = {station: _said(line, station) for station in cooks}
    out = line.done.get(PASS)
    if out is None and all(at is None for at in said.values()):
        return None
    word: dict[str, Any] = {
        "cooks": [
            {"code": station, "name": names.get(station) or station, "made": said[station] is not None}
            for station in cooks
        ]
    }
    if cooks and all(at is not None for at in said.values()):
        word["ready_ms"] = max(at or 0 for at in said.values())
    if out is not None:
        word["out_ms"] = out
    return word


def _word(
    line: Line, skips: Callable[[str], frozenset[str]], station_names: Mapping[str, str] | None = None
) -> dict[str, Any] | None:
    """The word on one dish, with nothing looked up for a dish nobody marked: most dishes, most of the time."""
    if line.fired_at is None or not line.done:
        return None
    return kitchen_word(line, skip=skips(line.fired_at.node), station_names=station_names)


def kitchen_words(
    state: OrderState,
    *,
    skips: Callable[[str], frozenset[str]] = lambda device: frozenset(),
    station_names: Mapping[str, str] | None = None,
) -> dict[str, dict[str, Any]]:
    """The kitchen's word on each dish of an order it has one for, by line id. `skips(device)` is the stations
    the screen that sent a dish prints no ticket at."""
    words = {line.line_id: _word(line, skips, station_names) for line in state.lines.values()}
    return {line_id: word for line_id, word in words.items() if word is not None}


def with_kitchen(order: dict[str, Any], words: Mapping[str, dict[str, Any]]) -> dict[str, Any]:
    """An order as it is read (`OrderState.snapshot`), each dish the kitchen spoke of with its word under
    `kitchen`. The order handed in is left as it was."""
    if not words:
        return order
    lines = {
        line_id: {**line, "kitchen": words[line_id]} if line_id in words else line
        for line_id, line in order["lines"].items()
    }
    return {**order, "lines": lines}


def ready_of(
    state: OrderState, *, skips: Callable[[str], frozenset[str]] = lambda device: frozenset()
) -> dict[str, int]:
    """For the floor map: how many dishes of a check are ready and have not gone out (`ready`), and when the
    last of them was made (`ready_ms`). Nothing at all for a check with none, which is most of them."""
    count, at = 0, 0
    for line in state.lines.values():
        word = _word(line, skips)
        if word is None or "ready_ms" not in word or "out_ms" in word:
            continue
        count += line.qty if isinstance(line.qty, int) and not isinstance(line.qty, bool) else 0
        at = max(at, word["ready_ms"])
    return {"ready": count, "ready_ms": at} if count else {}
