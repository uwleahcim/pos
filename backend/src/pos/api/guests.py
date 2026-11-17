"""The guest list on the wire. The figures live in `pos.orders.guests`; these are the calls.

- `GET /reports/guests` (manager token): every customer who ordered with a phone number in the last year
  (`first` to `last`, `days` of them), the one that spent most first. Each guest has `phone` (digits),
  `name`, `note`, `visits`, `spent`, `per_visit`, `last` and `first` (the days of their latest and their
  first visit of the year), `since_ms` and `orders_ever` (of every order they ever placed), `lately` (their
  visits in the last `regular_days` days), whether they are `regular`, `lapsed` (stopped coming) or `new`,
  and their `favourites` (dishes, most ordered first). `totals` adds the list up. `regular_visits`,
  `regular_days`, `lapsed_days` and `new_days` say what the three words mean.
- `GET /reports/guests/{phone}` (manager token): one guest read closely: `guest` (the same row with more
  favourites), `latest` (their latest visits, each with its day, kind, net and dishes), and who wrote the
  note and when (`note_by`, `note_ms`). 404 `no_guest` for a number with no visit in the year.

Reading either changes nothing and nothing is written down. What each order comes to as a visit is
remembered in memory while its log stays as it was (`pos.orders.guests.VisitMemo`): the first reading after
the hub starts takes some seconds for a year of orders, the next ones do not.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Header, HTTPException

from ..identity.tokens import Grant
from ..orders.guests import VisitMemo, guest_report, guests_report, in_window, window
from ..sync.oplog import phone_digits
from .auth import holder_from


def add_guest_list(app: FastAPI, memo: VisitMemo | None = None) -> None:
    memo = memo if memo is not None else VisitMemo()
    app.state.visit_memo = memo

    def manager(authorization: str | None) -> Grant:
        return holder_from(app.state, authorization, "guests")

    def visits_of(entries: list[Any], now_ms: int) -> Any:
        """The visits among these orders that can count in the year the list reads."""
        store = app.state.store
        picked = in_window(entries, window(now_ms)[0])
        return memo.each(picked, store.views, taxes=app.state.taxes, rules=app.state.pricing)

    @app.get("/reports/guests")
    def read_guests(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Every customer who ordered with a phone number in the last year: how often, what they spent,
        when they were last here, what they order most, and who is a regular, new, or stopped coming."""
        manager(authorization)
        store = app.state.store
        now_ms = store.now_ms()
        entries = store.with_phone()
        return guests_report(
            visits_of(entries, now_ms), entries, app.state.customers.all(), defs=app.state.menu.defs, now_ms=now_ms
        )

    @app.get("/reports/guests/{phone}")
    def read_guest(phone: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """One guest of the list read closely: more of their favourite dishes and their latest visits."""
        manager(authorization)
        store = app.state.store
        now_ms = store.now_ms()
        digits = phone_digits(phone)
        entries = store.index(phone=digits) if digits else []
        report = guest_report(
            digits,
            visits_of(entries, now_ms),
            entries,
            app.state.customers.get(digits) if digits else None,
            defs=app.state.menu.defs,
            now_ms=now_ms,
        )
        if report is None:
            raise HTTPException(404, {"error": "no_guest", "message": "No visit from this number in the last year."})
        return report
