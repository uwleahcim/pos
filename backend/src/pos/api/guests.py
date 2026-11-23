"""The guest list on the wire. The figures live in `pos.orders.guests`; these are the calls.

- `GET /reports/guests` (manager token): every customer who ordered with a phone number in the last year
  (`first` to `last`, `days` of them), the one that spent most first. Each guest has `phone` (digits),
  `name`, `note`, `tags`, `visits`, `spent`, `per_visit`, `last` and `first` (the days of their latest and
  their first visit of the year), `since_ms` and `orders_ever` (of every order they ever placed), `lately`
  (their visits in the last `regular_days` days), whether they are `regular`, `lapsed` (stopped coming) or
  `new`, and their `favourites` (dishes, most ordered first). `totals` adds the list up. `regular_visits`,
  `regular_days`, `lapsed_days` and `new_days` say what the three words mean. `tags` is every tag there is
  to offer (`pos.guest_tags`), each with how many of the list's `guests` carry it, and `note_max`,
  `tag_max` and `tags_most` are what a note and the tags are held to.
- `GET /reports/guests/{phone}` (manager token): one guest read closely: `guest` (the same row with more
  favourites), `latest` (their latest visits, each with its day, kind, net and dishes), who wrote the note
  and when (`note_by`, `note_ms`) and who last put the tags on (`tags_by`, `tags_ms`). 404 `no_guest` for a
  number with no visit in the year.
- `PUT /reports/guests/{phone}` `{note, tags}` (manager token): what the restaurant keeps about the guest
  at this number, either or both; one left out stays as it is, an empty one is taken off. The answer is
  both as they are kept now, each with who wrote it and when. The name behind the token is who wrote it.
  422 `bad_value` for a number that is none, a tag too long or too many of them.

Reading changes nothing and nothing is written down. What each order comes to as a visit is remembered in
memory while its log stays as it was (`pos.orders.guests.VisitMemo`): the first reading after the hub
starts takes some seconds for a year of orders, the next ones do not. The write keeps a note and tags and
nothing else: no order, no sale and no figure of the list moves by it. When the tags changed, the screens
with the reservation book or the waitlist open are told to read again (the change feed's `reservations`
and `waitlist`), since both show a guest's tags; the feed says that something changed, never what.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from ..customers import SHORTEST, clean_note
from ..customers import ReadOnlyError as NotesReadOnly
from ..guest_tags import ReadOnlyError as TagsReadOnly
from ..guest_tags import clean_tags, offered
from ..identity.tokens import Grant
from ..orders.guests import VisitMemo, guest_report, guests_report, in_window, window
from ..sync.oplog import phone_digits
from .auth import holder_from


class GuestIn(BaseModel):
    """What the restaurant keeps about a guest, written from the guest list: the note and the tags. One left
    out stays as it is; an empty one is taken off."""

    note: str | None = Field(None, max_length=400)
    tags: list[str] | None = Field(None, max_length=50)


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
            visits_of(entries, now_ms),
            entries,
            app.state.customers.all(),
            defs=app.state.menu.defs,
            now_ms=now_ms,
            tags=app.state.guest_tags.all(),
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
            tags=app.state.guest_tags.get(digits) if digits else None,
        )
        if report is None:
            raise HTTPException(404, {"error": "no_guest", "message": "No visit from this number in the last year."})
        return report

    @app.put("/reports/guests/{phone}")
    def write_guest(phone: str, body: GuestIn, authorization: str | None = Header(None)) -> dict[str, Any]:
        """Whoever may read the guest list keeps the note and the tags of the guest at this number: either
        or both, and only what is not as it was is written, so each keeps who wrote it last."""
        grant = manager(authorization)
        digits = phone_digits(phone)
        if len(digits) < SHORTEST:
            raise HTTPException(422, {"error": "bad_value", "message": "That is not a phone number."})
        notes, kept_tags = app.state.customers, app.state.guest_tags
        try:
            # a tag is spelt as the guests who carry it spell it, the spelling most of them carry first
            known = [row["tag"] for row in offered(kept_tags.all())]
            tags = None if body.tags is None else clean_tags(body.tags, known)
        except ValueError as err:
            raise HTTPException(422, {"error": "bad_value", "message": str(err)}) from err
        note = None if body.note is None else clean_note(body.note)
        now_ms = app.state.store.now_ms()
        try:
            if tags is not None and tags != (kept_tags.get(digits) or {}).get("tags", []):
                kept_tags.put(digits, tags, by=grant.name, at_ms=now_ms)
                # The book and the waitlist show a number's tags on its reservation and its party: the
                # screens that have one open read it again. Only that something changed is told, never what.
                for topic in ("reservations", "waitlist"):
                    app.state.feed.changed(topic)
            if note is not None and note != (notes.get(digits) or {}).get("note", ""):
                notes.put(digits, note, by=grant.name, at_ms=now_ms)
        except (NotesReadOnly, TagsReadOnly) as err:
            # A standby hub: the terminal moves to the next address, as for an order.
            raise HTTPException(503, {"error": "read_only"}) from err
        about, carried = notes.get(digits) or {}, kept_tags.get(digits) or {}
        return {
            "phone": digits,
            "note": str(about.get("note") or ""),
            "note_by": str(about.get("by") or ""),
            "note_ms": about.get("at_ms") if about.get("note") else None,
            "tags": list(carried.get("tags") or ()),
            "tags_by": str(carried.get("by") or ""),
            "tags_ms": carried.get("at_ms") if carried.get("tags") else None,
        }
