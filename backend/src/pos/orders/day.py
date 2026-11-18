"""The day's report: what was sold, what was taken for it, what came off the checks and what is still open.

A day is a day of service: from the hour the night ends (4 AM) to that hour the next morning, the location's
own time. A check counts on the day it was opened, or on the day it is promised for when that is a later one
(a catering order rung on Tuesday for Saturday is Saturday's sale). A check voided whole is no sale.

Everything is reckoned from the operation log at the moment it is asked, like a check, so a late void or a
payment taken afterwards is in the next reading. Nothing is stored and no day is ever "closed": the same day
reads the same a month later, and nothing a manager does here changes a sale.

The figures add up, and the report is laid out so that anybody can check them:

- `sales.gross` is every dish on the day's checks at the price it was sold at. `menus`, `categories`,
  `kinds`, `staff` and `hours` each split that one figure, so each of them adds up to it.
- `sales.net` = gross - discounts. `sales.total` = net + charges + gratuity + tax: what the day's checks come
  to. The tax is one figure, as a guest sees it.
- `money.taken` is every payment recorded during the day, by how it was paid, whatever check it was for:
  what should be in the drawer and on the card slips that night. Every payment is in it, cash like any other.
- `money` then settles the day's own checks: total = `paid_this_day` + `paid_other_days` + `due` - `over`.

What the report cannot know is said rather than guessed: the money counted in the drawer (nobody types it in
yet, so there is no over or short), and what a card company paid out.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from datetime import date, datetime
from decimal import Decimal
from typing import Any

from .. import localtime
from ..menu.defs import Definitions
from ..sync.oplog import OrderState, promised_ms
from ..tax import TaxProfile
from .adjustments import PricingRules
from .check import check_for
from .taken_off import taken_off_rows
from .typed import typed_rows
from .voids import void_rows

ZERO = Decimal("0.00")
METHODS = ("cash", "card", "elsewhere")
"""How a payment can have been taken, in the order the report lists them; anything else follows by name."""
PAID_AS = {"cash": "Cash", "card": "Card", "elsewhere": "Paid elsewhere"}
"""What each is called on paper and in a table."""


def order_day(state: OrderState) -> date | None:
    """The day of service a check counts on: the one it was opened in, or the one it is promised for when
    that is later. None for an order with nothing in its log."""
    if state.first is None:
        return None
    opened = localtime.service_day_of(state.first.wall_ms)
    promised = promised_ms(state.fields.get("promised_at"))
    if promised is not None:
        wanted = localtime.service_day_of(promised)
        if wanted > opened:
            return wanted
    return opened


class _Tally:
    """Amounts and counts under a key, in the order the keys first came up."""

    def __init__(self) -> None:
        self.rows: dict[Any, dict[str, Any]] = {}

    def add(self, key: Any, amount: Decimal, count: int = 1, **about: Any) -> None:
        row = self.rows.setdefault(key, {**about, "count": 0, "amount": ZERO})
        row["count"] += count
        row["amount"] += amount

    def listed(self, order: Callable[[dict[str, Any]], Any] | None = None) -> list[dict[str, Any]]:
        rows = sorted(self.rows.values(), key=order) if order is not None else list(self.rows.values())
        return [{**row, "amount": str(row["amount"])} for row in rows]


def _most_first(row: dict[str, Any]) -> Any:
    return (-row["amount"], str(row.get("name") or ""))


def _oldest_first(row: dict[str, Any]) -> Any:
    return (row["opened_ms"] or 0, row["order_id"])


TAB = "tab"
"""The kind a sale counts under when its check is a bar tab that never sat down: neither a table nor to go."""


def kind_of(state: OrderState, check: Mapping[str, Any]) -> str:
    """The kind of order a check's sales count under: how it was eaten (`order_type`), with the bar's tabs
    apart from the tables. A tab that was given a table is that table's check, and counts with the tables;
    so does one whose drinks all went onto a table's check (`merged_into`), which is left empty."""
    return TAB if state.is_tab and not state.fields.get("merged_into") else str(check["order_type"])


def _guests(state: OrderState) -> int:
    guests = state.fields.get("guests")
    return guests if isinstance(guests, int) and not isinstance(guests, bool) and guests > 0 else 0


def _about(state: OrderState, check: Mapping[str, Any]) -> dict[str, Any]:
    """A check as a list of open ones names it."""
    unsent = sum(1 for line in state.lines.values() if line.active and line.fired_at is None and not line.arrived_sent)
    return {
        "order_id": state.order_id,
        "table": state.fields.get("table"),
        "order_no": state.fields.get("order_no"),
        "customer_name": state.fields.get("customer_name"),
        **({"tab": True} if state.is_tab else {}),  # a bar tab, called by its name
        "server": state.fields.get("server"),
        "order_type": check["order_type"],
        "status": state.status,
        "total": check["total"],
        "paid": check["paid"],
        "due": check["due"],
        "unsent": unsent,
        "opened_ms": state.first.wall_ms if state.first is not None else None,
    }


class _Menu:
    """Which menu and category a sold dish belongs to, by the menu as it stands now. A dish that has left
    the menu since is listed under "Off the menu now": its sale is a sale all the same."""

    def __init__(self, defs: Definitions) -> None:
        self.defs = defs
        self.entries = {entry.id: entry for entry in defs.entries}
        self.first: dict[str, str] = {}  # item -> the first menu it is on
        for entry in defs.entries:
            self.first.setdefault(entry.item, entry.menu)

    def _text(self, names: Mapping[str, str] | None, fallback: str) -> str:
        return (self.defs.localizer.text(names, "en") if names else "") or fallback

    def of(self, priced: Mapping[str, Any]) -> tuple[str, str, str, str]:
        """(menu code, menu name, category code, category name) for a line's snapshot."""
        code = priced.get("item")
        item = self.defs.items.get(code) if isinstance(code, str) else None
        if item is None:
            return ("", "", "", "Off the menu now")
        entry = self.entries.get(str(priced.get("entry_id") or ""))
        menu_code = entry.menu if entry is not None and entry.item == item.code else self.first.get(item.code, "")
        menu = self.defs.menus.get(menu_code)
        category = self.defs.categories.get(item.category)
        return (
            menu_code,
            self._text(menu.names if menu is not None else None, ""),
            item.category,
            self._text(category.names if category is not None else None, item.category),
        )


def day_report(
    states: Iterable[OrderState],
    day: date,
    *,
    taxes: TaxProfile,
    rules: PricingRules | None,
    defs: Definitions,
    now_ms: int,
) -> dict[str, Any]:
    """The report for `day` from the orders given: every order that was opened before the day's service
    ended and changed since it began, and every order still open. Orders that turn out to belong nowhere
    near the day cost a look and count for nothing."""
    since, until = localtime.service_day(day)
    today = since <= now_ms < until
    menu = _Menu(defs)

    checks = guests = 0
    sums = dict.fromkeys(("gross", "discounts", "charges", "gratuity", "tax", "total"), ZERO)
    menus, categories, kinds, staff, hours = _Tally(), _Tally(), _Tally(), _Tally(), _Tally()
    discounts, taken = _Tally(), _Tally()
    off = {name: {"count": 0, "amount": ZERO} for name in ("voids", "taken_off", "typed", "voided_checks", "later")}
    money = dict.fromkeys(
        ("taken_total", "for_other_days", "on_voided", "paid_this_day", "paid_other_days", "due", "over"), ZERO
    )
    open_now: list[dict[str, Any]] = []
    unpaid: list[dict[str, Any]] = []
    earlier: list[dict[str, Any]] = []
    exempt: list[dict[str, Any]] = []  # the checks a manager marked tax exempt, each with for whom

    for state in states:
        its_day = order_day(state)
        if its_day is None:
            continue
        void = state.status == "void"
        mine = its_day == day and not void
        check = check_for(state, taxes, rules)

        # What came off, by when it came off: a dish voided tonight on yesterday's tab is tonight's void.
        for name, rows in (("voids", void_rows(state, since)), ("taken_off", taken_off_rows(state, since))):
            for row in rows:
                if row["at_ms"] < until:
                    off[name]["count"] += 1
                    off[name]["amount"] += Decimal(row["amount"])
        for row in typed_rows(state, since):
            if row["at_ms"] < until and not row["voided"] and not void:
                off["typed"]["count"] += 1
                off["typed"]["amount"] += Decimal(row["amount"])

        # The money, by when it was taken.
        paid_then = ZERO
        for payment in state.payments.values():
            amount = Decimal(payment.amount or "0")
            at_ms = payment.stamp.wall_ms if payment.stamp is not None else None
            if at_ms is not None and since <= at_ms < until:
                method = payment.method or "cash"
                taken.add(method, amount, method=method)
                money["taken_total"] += amount
                paid_then += amount
                if void:
                    money["on_voided"] += amount
                elif not mine:
                    money["for_other_days"] += amount

        if void:
            if its_day == day:
                off["voided_checks"]["count"] += 1
                off["voided_checks"]["amount"] += Decimal(check["subtotal"])
            continue
        if not mine:
            if state.status == "open" and its_day < day and today:
                earlier.append({**_about(state, check), "day": its_day.isoformat()})
            elif its_day > day and state.first is not None and since <= state.first.wall_ms < until:
                off["later"]["count"] += 1
                off["later"]["amount"] += Decimal(check["total"])
            continue

        checks += 1
        guests += _guests(state)
        total, paid = Decimal(check["total"]), Decimal(check["paid"])
        sums["gross"] += Decimal(check["subtotal"])
        sums["discounts"] += Decimal(check["discount_total"])
        sums["tax"] += Decimal(check["tax"])
        sums["total"] += total
        for charge in check["charges"]:
            sums["gratuity" if charge["gratuity"] else "charges"] += Decimal(charge["amount"])
        for row in check["discounts"]:
            discounts.add(row["name"], Decimal(row["amount"]), name=row["name"])
        money["paid_this_day"] += paid_then
        money["paid_other_days"] += paid - paid_then
        money["due"] += Decimal(check["due"])
        money["over"] += max(paid - total, ZERO)
        if check.get("tax_exempt"):
            said = check["tax_exempt"]
            who = {name: said[name] for name in ("organisation", "certificate", "approved_by", "by", "tax")}
            exempt.append({**_about(state, check), **who})

        kind = kind_of(state, check)
        kinds.add(kind, ZERO, kind=kind, guests=0)
        kinds.rows[kind]["guests"] += _guests(state)
        for row in check["lines"]:
            line = state.lines[row["line_id"]]
            amount = Decimal(row["total"])
            menu_code, menu_name, category_code, category_name = menu.of(line.priced or {})
            menus.add(menu_code, amount, row["qty"], menu=menu_code, name=menu_name)
            categories.add(
                (menu_code, category_code), amount, row["qty"], menu=menu_code, code=category_code, name=category_name
            )
            kinds.rows[kind]["amount"] += amount
            staff.add(line.by_id or line.by, amount, row["qty"], name=line.by, staff_id=line.by_id)
            if line.added_at is not None:
                at = datetime.fromtimestamp(line.added_at.wall_ms / 1000, localtime.zone())
                hours.add((at.date(), at.hour), amount, row["qty"], hour=at.hour, place=at.toordinal() * 24 + at.hour)
            else:
                hours.add(None, amount, row["qty"], hour=None, place=None)

        if state.status == "open":
            open_now.append(_about(state, check))
        elif Decimal(check["due"]) > ZERO:
            unpaid.append(_about(state, check))

    methods = {name: i for i, name in enumerate(METHODS)}
    net = sums["gross"] - sums["discounts"]
    return {
        "day": day.isoformat(),
        "since_ms": since,
        "until_ms": until,
        "now_ms": now_ms,
        "today": today,
        "checks": checks,
        "guests": guests,
        "sales": {
            "gross": str(sums["gross"]),
            "discounts": str(sums["discounts"]),
            "net": str(net),
            "charges": str(sums["charges"]),
            "gratuity": str(sums["gratuity"]),
            "tax": str(sums["tax"]),
            "total": str(sums["total"]),
        },
        "menus": menus.listed(_most_first),
        "categories": categories.listed(lambda row: (row["menu"], -row["amount"], row["name"])),
        "kinds": kinds.listed(_most_first),
        "staff": staff.listed(_most_first),
        "hours": [
            {k: v for k, v in row.items() if k != "place"}
            for row in hours.listed(lambda row: (row["place"] is None, row["place"] or 0))
        ],
        "discounts": discounts.listed(_most_first),
        **{name: {"count": row["count"], "amount": str(row["amount"])} for name, row in off.items()},
        "money": {
            "taken": taken.listed(lambda row: (methods.get(row["method"], len(methods)), row["method"])),
            **{name: str(amount) for name, amount in money.items()},
        },
        # Checks charged no tax: how many, what they came to, and the tax that was not charged. Their sales
        # are in every figure above; `sales.tax` is the tax that was charged.
        "tax_exempt": {
            "count": len(exempt),
            "sales": str(sum((Decimal(row["total"]) for row in exempt), ZERO)),
            "tax": str(sum((Decimal(row["tax"]) for row in exempt), ZERO)),
            "checks": sorted(exempt, key=_oldest_first),
        },
        "open": sorted(open_now, key=_oldest_first),
        "unpaid": sorted(unpaid, key=_oldest_first),
        "earlier": sorted(earlier, key=_oldest_first),
        "unsent": sum(row["unsent"] for row in open_now) + sum(row["unsent"] for row in earlier),
    }
