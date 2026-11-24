"""The guest list on the wire. The figures live in `pos.orders.guests`; these are the calls.

- `GET /reports/guests` (manager token): every customer who ordered with a phone number in the last year
  (`first` to `last`, `days` of them), the one that spent most first. Each guest has `phone` (digits),
  `name`, `note`, `tags`, `visits`, `spent`, `per_visit`, `last` and `first` (the days of their latest and
  their first visit of the year), `since_ms` and `orders_ever` (of every order they ever placed), `lately`
  (their visits in the last `regular_days` days), whether they are `regular`, `lapsed` (stopped coming) or
  `new`, and their `favourites` (dishes, most ordered first). `totals` adds the list up. `regular_visits`,
  `regular_days`, `lapsed_days` and `new_days` say what the three words mean. `tags` is every tag there is
  to offer (`pos.guest_tags`), each with how many of the list's `guests` carry it, and `note_max`,
  `tag_max` and `tags_most` are what a note and the tags are held to. `tagged` is every number that carries
  a tag and has no visit in the year (tagged from a reservation or the waitlist before its first order, or
  a guest of long ago), apart from `guests` and counted in none of the figures: rows of the same shape
  with `visits` 0, `spent` "0.00", no `last`, `first` or `per_visit`, under the `name` the number was
  tagged by, by that name. An app that does not know `tagged` shows the list as before.
- `GET /reports/guests/{phone}` (manager token): one guest read closely: `guest` (the same row with more
  favourites), `latest` (their latest visits, each with its day, kind, net and dishes), who wrote the note
  and when (`note_by`, `note_ms`) and who last put the tags on (`tags_by`, `tags_ms`). A number of `tagged`
  is read the same way, with no visit in `latest`. 404 `no_guest` for a number with no visit in the year
  that carries no tag.
- `GET /reports/guests/tags` (manager token), with `?phone=` or without: what the box that tags a guest
  needs and no more, for a screen that has not read the list (a reservation, a party on the waitlist:
  docs/guest-list.md, "From a reservation or the waitlist"). `tags` is every tag there is to offer, each
  with how many numbers carry it (`guests`: every number, one that never ordered too), `tag_max` and
  `tags_most` what the tags are held to, and for a `phone` the tags it `carried` now with who put them on
  and when (`tags_by`, `tags_ms`). It reads no order. 422 `bad_value` for a `phone` that is no number.
- `PUT /reports/guests/{phone}` `{note, tags, name}` (manager token): what the restaurant keeps about the
  guest at this number, either or both; one left out stays as it is, an empty one is taken off. The answer
  is both as they are kept now, each with who wrote it and when. The name behind the token is who wrote it.
  `name` is what the guest is called where they are tagged (their reservation, their party): it is kept
  with the tags of a number that carries one, tidied to one line of `NAME_MAX` letters, so the list can
  call a number that never ordered something; left out, the name the number had stays, and a number with
  no tag keeps none. 422 `bad_value` for a number that is none, a tag too long or too many of them.
- `GET /orders/{order_id}/tags` (no token): the `tags` of the guests who were seated on this check, and
  nothing else about them: what the screen with a table's check open shows the server (docs/guest-list.md,
  "At the table"). They are found through the reservation or the waitlist party the host sat down on the
  check (`POST /reservations/{id}/seat`, `POST /waitlist/{id}/seat` keep its id), and through any party
  that joined the table after; the number is read there and never written onto the check. Each tag once,
  in the order of the alphabet; none for a check nobody was seated on. It reads no order and names nobody.
- `GET /orders/{order_id}/seated` (no token): who was seated on this check, for the same screen: `parties`,
  each reservation's and each waitlist party the host sat down on it, the first to sit first, with where
  it is `from` ("reservation" or "waitlist"), its `name`, its `size`, the `note` written on the reservation
  or the party, and the `tags` its number carries; and `tags`, all of theirs together, as the call above
  answers them. No phone number, and not the line kept about a customer. It reads the book and the
  waitlist, as `GET /reservations` and `GET /waitlist` do for any terminal; it reads no order, and nothing
  goes onto the check.
- The floor map is told the same people, by name and tags alone, with the floor (`GET /floor`, `seated`:
  `seated_by_check` below), so a table says whose it is and whether that guest carries a tag.
- The list of checks is told their names and no more (`GET /orders?brief=true`, `seated` on a check:
  `names_by_check` below), so a table's check says whose it is and is found by that name.
- Two tables put together: the parties seated on the check that was emptied sit on the check that was
  kept from then on (`follow_merges` below, called when the hub takes the merge's operations), so all of
  the above say them on that check.
- Every guest of a check counts in the list, not only the number typed on it: a party the host seated
  that left a number, and the number of a check that was merged in. Who sat on which check is noted as it
  happens (`note_guest`, `note_seated` and `follow_merges` below; kept in `pos.check_guests`), since the
  book and the waitlist forget long before the year the list reads is over. Each of them has the visit;
  the check's money is the one's who pays (`pos.orders.guests.shared_out`).

Reading changes nothing and nothing is written down. What each order comes to as a visit is remembered in
memory while its log stays as it was (`pos.orders.guests.VisitMemo`): the first reading after the hub
starts takes some seconds for a year of orders, the next ones do not. The write keeps a note and tags and
nothing else: no order, no sale and no figure of the list moves by it. When the tags changed, the screens
with the reservation book or the waitlist open are told to read again (the change feed's `reservations`
and `waitlist`), since both show a guest's tags; the feed says that something changed, never what.
"""

from __future__ import annotations

import logging
from collections.abc import Iterable
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from .. import localtime
from ..check_guests import CheckGuest, guest_of
from ..check_guests import ReadOnlyError as GuestsReadOnly
from ..customers import SHORTEST, clean_note
from ..customers import ReadOnlyError as NotesReadOnly
from ..guest_tags import TAG_MAX, TAGS_MOST, clean_name, clean_tags, offered, tags_together
from ..guest_tags import ReadOnlyError as TagsReadOnly
from ..identity.tokens import Grant
from ..orders.guests import CheckMemo, VisitMemo, guest_report, guests_report, in_window, shared_out, window
from ..sync.oplog import phone_digits
from .auth import holder_from

MERGES_FOLLOWED = 20
"""How many merges in a row a party is followed through: far more than a night puts tables together."""

_log = logging.getLogger(__name__)


def kept_check(store: Any, emptied: str) -> str | None:
    """The check that holds the dishes of `emptied` now, as the log says it: the one it was merged into
    (its `merged_into`), and the one that was merged into in its turn, to the end. None when `emptied` was
    merged into nothing, into a check this hub never heard of, or round in a ring."""
    seen = {emptied}
    at = emptied
    for _ in range(MERGES_FOLLOWED):
        view = store.view(at)
        if view is None:
            return None
        onto = view.fields.get("merged_into")
        if not isinstance(onto, str) or not onto:
            return at if at != emptied else None
        if onto in seen:
            return None
        seen.add(onto)
        at = onto
    return None


def follow_merges(state: Any, ops: Iterable[Any]) -> list[str]:
    """Two tables were put together: one check took the other's dishes, and the emptied one was closed
    saying where they went (`set_field {merged_into}`, docs/moves.md). A party the host seated on the
    emptied check, from its reservation or the waitlist, sits on the check that was kept from now on, so
    that check, its table on the floor map and its row in the list of checks say whose it is. Called with
    the operations the log just took; it reads where the log says the emptied check went, so a merge
    told twice, or two merges that arrive the wrong way round, end at the same check.

    It writes which check the party sits on, in the book or on the waitlist, as seating it did: nothing
    on any check. The screens with the book or the waitlist open are told to read again (the feed's
    `reservations`, `waitlist`), and the topics told are handed back. Taking the operations must not fail
    because the book could not be written: that is logged, without a guest's name, and left."""
    told: list[str] = []
    for emptied in dict.fromkeys(op.order_id for op in ops if op.kind == "set_field" and op.data.get("merged_into")):
        try:
            kept = kept_check(state.store, emptied)
            if kept is None:
                continue
            _guests_follow(state, emptied, kept)
            for topic, book in (("reservations", state.reservations), ("waitlist", state.waitlist)):
                if book.follow(emptied, kept) and topic not in told:
                    told.append(topic)
        except Exception:  # noqa: BLE001 - the operations were taken: a book that cannot be written is left
            _log.exception("the parties of a merged check were not moved to the check that was kept")
    for topic in told:
        state.feed.changed(topic)
    return told


def _guests_follow(state: Any, emptied: str, kept: str) -> None:
    """The guests noted on a merged check are guests of the check that was kept, for the guest list: the
    parties seated on it, and the customer whose number is typed on it. That number stays on the emptied
    check, which has no dish left and so is nobody's visit any more; here it is noted as a guest of the
    kept check, from when the emptied one was opened. Nothing is written on either check."""
    try:
        state.check_guests.follow(emptied, kept)
        view = state.store.view(emptied)
        phone = phone_digits(view.fields.get("phone")) if view is not None else ""
        if view is not None and len(phone) >= SHORTEST:
            at_ms = view.first.wall_ms if view.first is not None else state.store.now_ms()
            state.check_guests.put(guest_of("check", emptied, kept, phone, view.fields.get("customer_name"), at_ms))
    except GuestsReadOnly:
        pass  # a standby hub takes no operations of its own; the primary noted it
    except Exception:  # noqa: BLE001 - the operations were taken, and the parties are still to be moved
        _log.exception("the guests of a merged check were not noted on the check that was kept")


def note_guest(state: Any, source: str, row: Any) -> None:
    """A reservation (`source` "reservation") or a party of the waitlist ("waitlist") was changed: the note
    of who sat on which check (`pos.check_guests`) is brought in step with it. Seated on a check with a
    number left: a guest of that check, under the name and the number written there. Anything else (put
    back, no number, not seated): no guest of any. It is called after every change the host stand makes, so
    the note cannot fall behind the book. It must not stop that change: a failure is logged, without the
    guest's name, and left."""
    try:
        source_id = str(row.booking_id if source == "reservation" else row.party_id)
        phone = phone_digits(row.phone)
        if row.seated_ms is not None and row.order_id and len(phone) >= SHORTEST:
            state.check_guests.put(guest_of(source, source_id, row.order_id, phone, row.name, row.seated_ms))
        else:
            state.check_guests.drop(source, source_id)
    except GuestsReadOnly:
        pass  # a standby hub: the primary noted it, and this database is its copy
    except Exception:  # noqa: BLE001 - the host's change was made: the note of it is left
        _log.exception("a guest of a check was not noted")


def note_seated(state: Any) -> None:
    """Every party that sits on a check is noted as its guest: what a hub does when it starts, so the tables
    seated before it was updated count in the guest list too. Today's and yesterday's parties, as the book
    and the waitlist hand them out."""
    for source, book in (("reservation", state.reservations), ("waitlist", state.waitlist)):
        try:
            for row in book.seated():
                note_guest(state, source, row)
        except Exception:  # noqa: BLE001 - a book that cannot be read now is read at the next seating
            _log.exception("the seated parties were not noted as guests of their checks")


def seated_by_check(state: Any, order_ids: Iterable[str]) -> dict[str, list[dict[str, Any]]]:
    """Who sits at the tables, for the floor map (`GET /floor`, `seated`): under the id of each of these
    checks that the host seated somebody on, its parties, the first to sit first, each with the `name` on
    its reservation or its line of the waitlist and the `tags` its number carries. A check nobody was seated
    on (a walk-in's) is not in it. The name and the tags and no more: not the number, not the note. It reads
    the book, the waitlist and the tags, and no order."""
    seated = _seated_on(state, order_ids)
    carried = state.guest_tags.all() if any(row.phone for row in seated) else {}
    by_check: dict[str, list[dict[str, Any]]] = {}
    for row in seated:
        by_check.setdefault(row.order_id, []).append({"name": row.name, "tags": tags_together([row.phone], carried)})
    return by_check


def names_by_check(state: Any, order_ids: Iterable[str]) -> dict[str, list[str]]:
    """Whose check it is, for the list of checks (`GET /orders?brief=true`, `seated` on a check): under the
    id of each of these checks that the host seated somebody on, the names of its parties, the first to sit
    first, each name once. A check nobody was seated on (a walk-in's, a to-go order) is not in it, and
    neither is one whose parties gave no name. The names and no more: not the number, not the note, not a
    tag. Today's and yesterday's parties are looked at, as for the floor map, so a check closed earlier in
    the day still says whose it was. It reads the book and the waitlist, and no order."""
    by_check: dict[str, list[str]] = {}
    for row in _seated_on(state, order_ids):
        name = " ".join(str(row.name or "").split())
        if name and name not in by_check.get(row.order_id, ()):
            by_check.setdefault(row.order_id, []).append(name)
    return by_check


def _seated_on(state: Any, order_ids: Iterable[str]) -> list[Any]:
    """The reservations and the waitlist parties the host sat down on these checks, the first to sit first."""
    wanted = set(order_ids)
    if not wanted:
        return []
    rows = [row for row in (*state.reservations.seated(), *state.waitlist.seated()) if row.order_id in wanted]
    return sorted(rows, key=lambda row: row.seated_ms or 0)


class GuestIn(BaseModel):
    """What the restaurant keeps about a guest, written from the guest list: the note and the tags. One left
    out stays as it is; an empty one is taken off. `name` is what the guest is called where they are tagged
    (their reservation, their party): kept only with the tags of a number that carries one."""

    note: str | None = Field(None, max_length=400)
    tags: list[str] | None = Field(None, max_length=50)
    name: str | None = Field(None, max_length=200)


def add_guest_list(app: FastAPI, memo: VisitMemo | None = None) -> None:
    memo = memo if memo is not None else VisitMemo()
    app.state.visit_memo = memo
    checks = CheckMemo()
    app.state.check_memo = checks
    note_seated(app.state)

    def manager(authorization: str | None) -> Grant:
        return holder_from(app.state, authorization, "guests")

    def visits_of(entries: list[Any], now_ms: int) -> Any:
        """The visits among these orders that can count in the year the list reads."""
        store = app.state.store
        picked = in_window(entries, window(now_ms)[0])
        return memo.each(picked, store.views, taxes=app.state.taxes, rules=app.state.pricing)

    def sat_on(seated: list[CheckGuest], now_ms: int) -> Any:
        """The checks these guests sat on, each as a visit, among the ones that can count in that year."""
        store = app.state.store
        picked = in_window(store.entries({guest.order_id for guest in seated}), window(now_ms)[0], numbered=False)
        return checks.each(picked, store.views, taxes=app.state.taxes, rules=app.state.pricing)

    def everybody(entries: list[Any], seated: list[CheckGuest], now_ms: int) -> Any:
        """The visits of the orders that carry a number and of the guests who sat on a check, each guest of
        a check with the visit and the one who pays with its money."""
        if not seated:
            return visits_of(entries, now_ms)
        return shared_out(visits_of(entries, now_ms), sat_on(seated, now_ms), seated)

    @app.get("/reports/guests")
    def read_guests(authorization: str | None = Header(None)) -> dict[str, Any]:
        """Every customer who ordered with a phone number in the last year: how often, what they spent,
        when they were last here, what they order most, and who is a regular, new, or stopped coming."""
        manager(authorization)
        store = app.state.store
        now_ms = store.now_ms()
        entries = store.with_phone()
        # who sat down on a check since the year began (a check opened the day before can count in it)
        began = localtime.service_day(window(now_ms)[0])[0] - 2 * 24 * 60 * 60 * 1000
        return guests_report(
            everybody(entries, app.state.check_guests.since(began), now_ms),
            entries,
            app.state.customers.all(),
            defs=app.state.menu.defs,
            now_ms=now_ms,
            tags=app.state.guest_tags.all(),
            names=app.state.guest_tags.names(),
        )

    # Before `/reports/guests/{phone}`, which would take "tags" for a number.
    @app.get("/reports/guests/tags")
    def read_tags_offered(
        phone: str | None = Query(None, max_length=40), authorization: str | None = Header(None)
    ) -> dict[str, Any]:
        """What the box that tags a guest needs where the list was not read: the tags on offer, what they
        are held to, and the tags this number carries now. The number need not have ordered."""
        manager(authorization)
        digits = phone_digits(phone) if phone is not None else ""
        if phone is not None and len(digits) < SHORTEST:
            raise HTTPException(422, {"error": "bad_value", "message": "That is not a phone number."})
        kept_tags = app.state.guest_tags
        carried = (kept_tags.get(digits) if digits else None) or {}
        return {
            "tags": offered(kept_tags.all()),
            "tag_max": TAG_MAX,
            "tags_most": TAGS_MOST,
            "phone": digits,
            "carried": list(carried.get("tags") or ()),
            "tags_by": str(carried.get("by") or ""),
            "tags_ms": carried.get("at_ms") if carried.get("tags") else None,
        }

    @app.get("/reports/guests/{phone}")
    def read_guest(phone: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        """One guest of the list read closely: more of their favourite dishes and their latest visits."""
        manager(authorization)
        store = app.state.store
        now_ms = store.now_ms()
        digits = phone_digits(phone)
        entries = store.index(phone=digits) if digits else []
        kept_tags = app.state.guest_tags
        # the checks this number sat on, with everybody else who sat on them: who pays depends on them
        mine = app.state.check_guests.of_phone(digits) if digits else []
        seated = app.state.check_guests.on({guest.order_id for guest in mine}) if mine else []
        report = guest_report(
            digits,
            everybody(entries, seated, now_ms),
            entries,
            app.state.customers.get(digits) if digits else None,
            defs=app.state.menu.defs,
            now_ms=now_ms,
            tags=kept_tags.get(digits) if digits else None,
            name=kept_tags.names().get(digits, "") if digits else "",
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
        name = clean_name(body.name)
        now_ms = app.state.store.now_ms()
        try:
            if tags is not None and tags != (kept_tags.get(digits) or {}).get("tags", []):
                kept_tags.put(digits, tags, by=grant.name, at_ms=now_ms, name=name)
                # The book and the waitlist show a number's tags on its reservation and its party: the
                # screens that have one open read it again. Only that something changed is told, never what.
                for topic in ("reservations", "waitlist"):
                    app.state.feed.changed(topic)
            elif name and name != kept_tags.names().get(digits, ""):
                # the same tags under another name: the name alone, so who put the tags on stays
                kept_tags.rename(digits, name)
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

    @app.get("/orders/{order_id}/tags")
    def read_table_tags(order_id: str) -> dict[str, Any]:
        """The `tags` of the guests who were seated on this check, and nothing else about them: what the
        screen with a table's check open shows the server. The guests are the reservation's or the waitlist
        party's the host sat down on it, and any that joined the table after; their number stays in the
        book and on the list and is not put on the check. It opens no order and names nobody, as the call
        for a number that rings does (`GET /customers/tags`)."""
        seated = [
            *app.state.reservations.seated_on(order_id),
            *app.state.waitlist.seated_on(order_id),
        ]
        phones = [row.phone for row in seated if row.phone]
        tags = tags_together(phones, app.state.guest_tags.all()) if phones else []
        return {"order_id": order_id, "tags": tags}

    @app.get("/orders/{order_id}/seated")
    def read_seated(order_id: str) -> dict[str, Any]:
        """Who was seated on this check: each reservation's and each waitlist party the host sat down on
        it, the first to sit first, with its name, how many they are, the note written on the reservation
        or the party and the tags its number carries; and all their `tags` together. For whoever serves the
        table. The number is not told, and nothing is put on the check: it opens no order."""
        seated = sorted(
            [
                *(("reservation", booking) for booking in app.state.reservations.seated_on(order_id)),
                *(("waitlist", party) for party in app.state.waitlist.seated_on(order_id)),
            ],
            key=lambda sat: sat[1].seated_ms or 0,
        )
        carried = app.state.guest_tags.all() if any(row.phone for _, row in seated) else {}
        return {
            "order_id": order_id,
            "parties": [
                {
                    "from": where,
                    "name": row.name,
                    "size": row.size,
                    "note": row.note,
                    "tags": tags_together([row.phone], carried),
                }
                for where, row in seated
            ],
            "tags": tags_together([row.phone for _, row in seated], carried),
        }
