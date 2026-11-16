"""The day's report on paper: the figures of `pos.orders.day.day_report`, block by block, so what a manager
staples to the night's slips says what the screen says, to the cent.

A `DayPaper` is data, like a `Bill`: `day_paper` makes one from the report and `render_day` turns it into
the bytes for a printer in its own language. Each block is a heading and rows of words with an amount at the
right; a row with no amount is words only. A block with nothing in it is left out, except the sales and the
money, which print their zeroes: a quiet day is still a day.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from .ticket import DIALECTS

ZERO = Decimal(0)
PAID_AS = {"cash": "Cash", "card": "Card", "elsewhere": "Paid elsewhere"}
KINDS = {"dine_in": "Tables", "tab": "Bar tabs", "takeout": "To go", "delivery": "Delivery"}


@dataclass(frozen=True)
class Block:
    title: str
    rows: tuple[tuple[str, str], ...]
    strong: int | None = None  # the row that prints bold: the block's own total


@dataclass(frozen=True)
class DayPaper:
    day: str  # "Monday, November 16, 2026"
    blocks: tuple[Block, ...]
    head: tuple[str, ...] = ()  # the restaurant's own lines, as on a bill
    notes: tuple[str, ...] = ()  # under the day: "Printed 9:41 PM by Mike", "The day is still running"
    at: datetime = field(default_factory=datetime.now)
    reprinted_from: str | None = None  # the printer this was for, on the copy a fallback printer gets


def _money(value: Any) -> Decimal:
    try:
        return Decimal(str(value))
    except InvalidOperation:
        return ZERO


def _amount(value: Any, *, off: bool = False) -> str:
    amount = _money(value)
    return f"-{amount:,.2f}" if off and amount else f"{amount:,.2f}"


def _clock(at: datetime) -> str:
    return f"{at.hour % 12 or 12}:{at:%M} {'AM' if at.hour < 12 else 'PM'}"


def _hour(hour: int | None) -> str:
    return "No time kept" if hour is None else f"{hour % 12 or 12} {'AM' if hour < 12 else 'PM'}"


def _hours(ms: int) -> str:
    """A length of time as people say it: "38 h 15 min", "45 min"."""
    minutes = max(ms, 0) // 60_000
    hours, left = divmod(minutes, 60)
    return f"{left} min" if hours == 0 else f"{hours} h" if left == 0 else f"{hours} h {left} min"


def _many(count: int, one: str, many: str | None = None) -> str:
    return f"{count} {one if count == 1 else many or one + 's'}"


def long_day(day: date) -> str:
    return f"{day:%A}, {day:%B} {day.day}, {day.year}"


def day_paper(
    report: Mapping[str, Any], *, head: tuple[str, ...] = (), at: datetime | None = None, by: str = ""
) -> DayPaper:
    at = at or datetime.now()
    sales, money = report["sales"], report["money"]
    blocks: list[Block] = []

    rows = [("Dishes sold", _amount(sales["gross"]))]
    if _money(sales["discounts"]):
        rows += [("Comps and discounts", _amount(sales["discounts"], off=True))]
    rows += [("Net sales", _amount(sales["net"]))]
    if _money(sales["charges"]):
        rows += [("Charges", _amount(sales["charges"]))]
    if _money(sales["gratuity"]):
        rows += [("Gratuity (paid over to staff)", _amount(sales["gratuity"]))]
    rows += [("Sales tax", _amount(sales["tax"])), ("TOTAL", _amount(sales["total"]))]
    rows += [(f"{_many(report['checks'], 'check')}, {_many(report['guests'], 'guest')}", "")]
    blocks.append(Block("SALES", tuple(rows), strong=len(rows) - 2))

    rows = [(f"{PAID_AS.get(t['method'], t['method'])} ({t['count']})", _amount(t["amount"])) for t in money["taken"]]
    rows += [("TAKEN THIS DAY", _amount(money["taken_total"]))]
    strong = len(rows) - 1
    if _money(money["for_other_days"]):
        rows += [("  of it for checks of other days", _amount(money["for_other_days"]))]
    if _money(money["on_voided"]):
        rows += [("  of it on checks voided since", _amount(money["on_voided"]))]
    blocks.append(Block("MONEY TAKEN", tuple(rows), strong=strong))

    rows = [("Come to", _amount(sales["total"])), ("Paid this day", _amount(money["paid_this_day"]))]
    if _money(money["paid_other_days"]):
        rows += [("Paid on other days", _amount(money["paid_other_days"]))]
    if _money(money["over"]):
        rows += [("Paid over", _amount(money["over"]))]
    rows += [("STILL OWED", _amount(money["due"]))]
    blocks.append(Block("THE DAY'S CHECKS", tuple(rows), strong=len(rows) - 1))

    menus = {m["menu"]: m for m in report["menus"]}
    for code, menu in menus.items():
        mine = [c for c in report["categories"] if c["menu"] == code]
        rows = [(f"{c['name']} ({c['count']})", _amount(c["amount"])) for c in mine]
        if len(menus) > 1:
            rows += [((menu["name"] or "Other").upper(), _amount(menu["amount"]))]
        title = f"BY CATEGORY: {(menu['name'] or 'Other').upper()}" if len(menus) > 1 else "BY CATEGORY"
        blocks.append(Block(title, tuple(rows), strong=len(rows) - 1 if len(menus) > 1 else None))

    blocks.append(
        Block(
            "BY KIND OF ORDER",
            tuple(
                (f"{KINDS.get(k['kind'], k['kind'])} ({_many(k['count'], 'check')})", _amount(k["amount"]))
                for k in report["kinds"]
            ),
        )
    )
    blocks.append(
        Block(
            "RUNG IN BY",
            tuple((s["name"] or "Nobody named", _amount(s["amount"])) for s in report["staff"]),
        )
    )
    blocks.append(Block("BY HOUR", tuple((_hour(h["hour"]), _amount(h["amount"])) for h in report["hours"])))

    rows = [(f"{d['name']} ({d['count']})", _amount(d["amount"], off=True)) for d in report["discounts"]]
    for name, words in (
        ("voids", "Voided after sending"),
        ("taken_off", "Taken off before sending"),
        ("voided_checks", "Checks voided whole"),
    ):
        if report[name]["count"]:
            rows += [(f"{words} ({report[name]['count']})", _amount(report[name]["amount"]))]
    blocks.append(Block("CAME OFF", tuple(rows)))

    rows = []
    if report["typed"]["count"]:
        rows += [(f"Typed prices ({report['typed']['count']})", _amount(report["typed"]["amount"]))]
    if report["later"]["count"]:
        rows += [(f"Rung for another day ({report['later']['count']})", _amount(report["later"]["amount"]))]
    if report.get("clock"):
        people = _many(report["clock"]["people"], "person", "people")
        rows += [(f"Hours worked ({people})", _hours(report["clock"]["worked_ms"]))]
    blocks.append(Block("ALSO", tuple(rows)))

    rows = []
    for name, one in (("open", "check still open"), ("unpaid", "closed check not paid in full")):
        listed = report[name]
        if listed:
            owed = sum((_money(r["due"]) for r in listed), ZERO)
            rows += [(_many(len(listed), one, one.replace("check", "checks", 1)), _amount(owed))]
    if report["earlier"]:
        owed = sum((_money(r["due"]) for r in report["earlier"]), ZERO)
        rows += [(_many(len(report["earlier"]), "open check", "open checks") + " from earlier days", _amount(owed))]
    if report["unsent"]:
        rows += [(_many(report["unsent"], "dish", "dishes") + " not sent to the kitchen", "")]
    clock = report.get("clock")
    if clock:
        if clock["on_now"]:
            rows += [("Still on the clock: " + ", ".join(p["name"] for p in clock["on_now"]), "")]
        if clock["unended"]:
            rows += [(_many(clock["unended"], "shift") + " nobody clocked out of", "")]
    if not rows:
        rows = [("Nothing: every check is closed and paid", "")]
    blocks.append(Block("STILL OPEN", tuple(rows)))

    notes = [f"Printed {_clock(at)}{' by ' + by if by else ''}"]
    if report.get("today"):
        notes.append("The day is still running")
    return DayPaper(
        day=long_day(date.fromisoformat(report["day"])),
        blocks=tuple(block for block in blocks if block.rows),
        head=head,
        notes=tuple(notes),
        at=at,
    )


def render_day(paper: DayPaper, *, dots: int = 576, font: str | None = None, dialect: str = "escpos") -> bytes:
    """The print job for one day's report (`dialect` escpos or star). Deterministic for the same inputs."""
    b = DIALECTS[dialect](dots=dots, font=font)
    if paper.reprinted_from:
        b.line(f"{paper.reprinted_from} printer down, printed here".upper(), center=True, bold=True, invert=True)
        b.feed(1)
    for text in paper.head[:1]:
        b.line(text, bold=True, center=True)
    b.line("THE DAY", big=True, bold=True, center=True)
    b.line(paper.day, bold=True, center=True)
    for note in paper.notes:
        b.line(note, center=True)
    for block in paper.blocks:
        b.rule()
        b.line(block.title, bold=True)
        for i, (words, amount) in enumerate(block.rows):
            if amount:
                b.columns(words, amount, bold=i == block.strong)
            else:
                b.line(words, bold=i == block.strong)
    b.rule()
    b.line(f"{paper.at:%Y-%m-%d %H:%M:%S}", center=True)
    b.feed(2).cut()
    return bytes(b)
