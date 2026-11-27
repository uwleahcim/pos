"""A paper written down step by step, in no printer's language: what the print log keeps of every print.

Every paper the hub prints (a kitchen ticket, a bill, a pack sheet, the day's report) is made by calling a
builder: a line, two columns, a rule, a feed, a cut. `ScriptBuilder` is a builder that prints nothing and
writes those calls down. What it writes is small, reads the same whichever printer the paper went to, and is
enough to do two things with later:

- show the paper on a screen, as it came out (the app draws the steps: the print log, docs/printing.md);
- print it again on any printer (`play`), headed REPRINT (`reprinted`), without the order it came from:
  a reprint says what the paper said, not what the order says now.

A script is a list of pages, since some papers are several (an order's bag labels, each cut off the next), and
a page is a list of steps:

    {"k": "line", "text": "WOK 1", "big": true, "bold": true, "center": true}
    {"k": "cols", "left": "#12  dine in", "right": "18:42"}
    {"k": "rule"}   {"k": "feed", "n": 2}   {"k": "cut"}   {"k": "beep", "n": 3}   {"k": "drawer", "pin": 0}

A step the reprint added carries `"re": true`, so printing a reprint again does not head it twice.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable, Sequence
from typing import Any

from PIL import Image

from .escpos import Builder

Step = dict[str, Any]
Page = list[Step]
Script = list[Page]

REPRINT = "*** REPRINT ***"
"""What heads a paper that was printed again from the print log, white on black."""


class ScriptBuilder(Builder):
    """The builder that writes the calls down. `bytes(builder)` is one page as a line of JSON, so the pages of
    a paper made with several builders (`pos.printing.labels`) can be told apart again (`pages`)."""

    def __init__(self, *, dots: int = 576, font: str | None = None, chars_per_line: int | None = None) -> None:
        self.dots = dots
        self.chars = chars_per_line or (48 if dots >= 576 else 32)
        self.steps: Page = []

    def __bytes__(self) -> bytes:
        return json.dumps(self.steps, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"

    @staticmethod
    def _flags(**flags: bool) -> Step:
        return {name: True for name, on in flags.items() if on}

    def line(
        self, text: str = "", *, bold: bool = False, big: bool = False, center: bool = False, invert: bool = False
    ) -> Builder:
        self.steps.append({"k": "line", "text": text, **self._flags(bold=bold, big=big, center=center, invert=invert)})
        return self

    def columns(self, left: str, right: str, *, bold: bool = False, big: bool = False, hang: str = "  ") -> Builder:
        step: Step = {"k": "cols", "left": left, "right": right, **self._flags(bold=bold, big=big)}
        if hang != "  ":
            step["hang"] = hang
        self.steps.append(step)
        return self

    def rule(self) -> Builder:
        self.steps.append({"k": "rule"})
        return self

    def feed(self, lines: int = 1) -> Builder:
        self.steps.append({"k": "feed", "n": max(0, min(lines, 255))})
        return self

    def image(self, img: Image.Image) -> Builder:
        return self  # no paper draws a picture of its own; one that did would be left off the screen

    def cut(self, *, feed: int = 4) -> Builder:
        self.steps.append({"k": "cut"})
        return self

    def drawer_kick(self, pin: int = 0) -> Builder:
        self.steps.append({"k": "drawer", "pin": pin})
        return self

    def beep(self, times: int = 2) -> Builder:
        self.steps.append({"k": "beep", "n": times})
        return self


def pages(written: bytes) -> Script:
    """The script a paper's renderer made with `ScriptBuilder`s: a page for each builder it used."""
    return [json.loads(line) for line in written.decode().splitlines() if line.strip()]


def clean(raw: Any) -> Script:
    """A script as it was kept, read back with nothing in it that `play` cannot take: pages that are lists
    of steps that are objects with a known `k`."""
    kinds = {"line", "cols", "rule", "feed", "cut", "beep", "drawer"}
    out: Script = []
    for page in raw if isinstance(raw, list) else ():
        steps = [dict(s) for s in page if isinstance(s, dict) and s.get("k") in kinds] if isinstance(page, list) else []
        if steps:
            out.append(steps)
    return out


def play(script: Sequence[Page], make: Callable[[], Builder]) -> bytes:
    """The print job for a script: each page played on a builder of its own (`make` gives one for the
    printer's language), one after the other, as the paper's own renderer made them."""
    out = []
    for page in script:
        b = make()
        for step in page:
            kind = step.get("k")
            if kind == "line":
                b.line(
                    str(step.get("text", "")),
                    bold=bool(step.get("bold")),
                    big=bool(step.get("big")),
                    center=bool(step.get("center")),
                    invert=bool(step.get("invert")),
                )
            elif kind == "cols":
                b.columns(
                    str(step.get("left", "")),
                    str(step.get("right", "")),
                    bold=bool(step.get("bold")),
                    big=bool(step.get("big")),
                    hang=str(step.get("hang", "  ")),
                )
            elif kind == "rule":
                b.rule()
            elif kind == "feed":
                b.feed(int(step.get("n", 1)))
            elif kind == "cut":
                b.cut()
            elif kind == "beep":
                b.beep(int(step.get("n", 1)))
            elif kind == "drawer":
                b.drawer_kick(int(step.get("pin", 0)))
        out.append(bytes(b))
    return b"".join(out)


def _headed(page: Page, added: Iterable[Step]) -> Page:
    """The page with `added` at its top: under the beeps it starts with, which make no mark on the paper, and
    under what a reprint already put there."""
    start = 0
    while start < len(page) and (page[start].get("k") == "beep" or page[start].get("re")):
        start += 1
    return [*page[:start], *({**step, "re": True} for step in added), *page[start:]]


def original(script: Sequence[Page]) -> Script:
    """The script without what a reprint added to it: the paper as it was first made."""
    return [[step for step in page if not step.get("re")] for page in script]


def _down(whose: str) -> Step:
    return {
        "k": "line",
        "text": f"{whose} printer down, printed here".upper(),
        "bold": True,
        "center": True,
        "invert": True,
    }


def reprinted(script: Sequence[Page], first: str, *, whose: str = "") -> Script:
    """The same paper headed REPRINT, white on black, on every page of it, with `first` under it: when the
    paper it repeats came out ("first printed Thu Nov 26 18:42"). Whoever holds it must be able to tell it
    from the first one: a cook who makes a reprinted ticket makes the dish twice. With `whose`, it is the
    copy a fallback printer gets, which says under that whose printer is down."""
    heading: list[Step] = [{"k": "line", "text": REPRINT, "big": True, "bold": True, "center": True, "invert": True}]
    if first:
        heading.append({"k": "line", "text": first, "bold": True, "center": True})
    if whose:
        heading.append(_down(whose))
    return [_headed(page, heading) for page in original(script)]


def carried(script: Sequence[Page], whose: str) -> Script:
    """The paper as the fallback printer it went to printed it, saying on every page whose it is: for the
    screen, since the log keeps a paper as it was made for its own printer."""
    return [_headed(page, [_down(whose)]) for page in script]
