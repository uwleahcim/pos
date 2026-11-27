"""The conversations by text on the wire (docs/text-inbox.md). The rules live in `pos.texts`; these are the calls.

Who may: the roles that hold the power `texts` at this location (docs/roles.md). Staff have no token: a
screen passes who is signed in (`staff_id`), as it does for the notes and for their display settings, and
the hub looks up that person's role. 404 `unknown_staff` for an id the hub does not know, 403 `not_allowed`
for a role without the power.

- `GET /texts?staff_id=&q=&limit=`: the conversations, the one with the newest text first, each with
  `phone` (+17815550142), `digits` (as the orders keep the number), `name`, `unread`, `stopped_ms` and its
  `last` text. `q` narrows to the ones that hold every word of it in the name, the number or a text. Beside
  them: `on` (the hub has a Twilio account: without one nothing comes and nothing goes), `number` (the
  number the restaurant texts from, where it is one), `unread` (how many conversations hold something
  nobody has opened) and `listening` (`ok`: whether Twilio answered when it was last asked for new texts;
  `at_ms`: when it last did; `said`: why not).
- `GET /texts/unread?staff_id=`: `on` and `unread` alone, for a button's badge.
- `GET /texts/with/{number}?staff_id=&before_ms=&limit=`: one conversation: `thread`, its `texts` the oldest
  first (the newest hundred, or those before `before_ms`), `more`, and `wrap` (`before`, `after`): what the
  first text to a number that has no conversation yet is sent with around it. Each text: `id`, `inbound`,
  `body`, `at_ms`, `state` (`received`, `waiting`, `sent`, `delivered`, `read`, `failed`), `channel` (`sms`,
  `mms`, `rcs`), `pictures` (`n`, `type`, `image`), `code` and `said` for one that failed, `kind` (empty: a
  person typed it; `ready`, `out`, `delayed`: the POS's own text to an order; `elsewhere`: sent from the
  restaurant's number by something else), `order_id` and `by`.
- `POST /texts/with/{number}` `{staff_id, body, device, id, name}`: sends a text. `id` is the screen's own
  name for it (so a tap sent twice is one text), `name` what the screen knows the customer by. The answer
  is the text, `waiting`: what becomes of it is told on the change feed. 409 `no_service` without a Twilio
  account, 409 `stopped` for a customer who answered STOP, 422 `no_number`, `no_text`, `too_long`.
- `POST /texts/with/{number}/read` `{staff_id}`: the conversation was opened: its texts are read.
- `GET /texts/picture/{id}/{n}?staff_id=`: a picture a text carries, fetched from Twilio the first time
  somebody looks and kept a month. 404 for a text or a picture there is none of, 502 `not_fetched`.

A change tells the screens on the change feed (`texts`): a text came, one went, one was delivered or was
not, a conversation was read.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ..identity.powers import holds
from ..identity.staff import Directory, Staff
from ..texts import BODY_MAX, PAGE, THREADS, Listener, ReadOnlyError, Refused, Texts, number_of
from ..twilio import SERVICE_SID, TwilioMessenger
from .auth import powers_of

POWER = "texts"
SHOWN = frozenset({"image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"})
"""What a picture is handed to a screen as. Anything else a text carries goes as plain bytes: a screen
shows that there is one and does not open it."""


class TextIn(BaseModel):
    staff_id: str = Field(max_length=120)
    body: str = Field(max_length=BODY_MAX * 2)
    device: str = Field("", max_length=120)
    id: str = Field("", max_length=64)
    name: str = Field("", max_length=200)


class ReadIn(BaseModel):
    staff_id: str = Field(max_length=120)


def add_texts(app: FastAPI) -> None:
    def texts() -> Texts:
        return app.state.texts

    def twilio() -> TwilioMessenger | None:
        messenger = app.state.messenger
        return messenger if isinstance(messenger, TwilioMessenger) else None

    def reader(staff_id: str) -> Staff:
        directory: Directory = app.state.staff
        person = directory.get(staff_id)
        if person is None:
            raise HTTPException(404, {"error": "unknown_staff", "message": "Nobody here has this id."})
        if not holds(powers_of(app.state), person.role, POWER):
            raise HTTPException(403, {"error": "not_allowed", "role": person.role, "power": POWER})
        return person

    def phone_of(number: str) -> str:
        phone = number_of(number)
        if phone is None:
            raise HTTPException(422, {"error": "no_number", "message": "That is not a number a text can go to."})
        return phone

    def refused(err: Refused) -> HTTPException:
        status = 409 if err.code == "stopped" else 422
        return HTTPException(status, {"error": err.code, "message": err.message})

    def listening() -> dict[str, Any]:
        listener: Listener = app.state.text_listener
        messenger = twilio()
        return {**listener.about(), "said": messenger.heard_fault if messenger is not None else ""}

    def number() -> str:
        """The number the restaurant texts from, where the account names one (a Messaging Service picks)."""
        messenger = twilio()
        if messenger is None or SERVICE_SID.fullmatch(messenger.config.sender):
            return ""
        return messenger.config.sender

    @app.get("/texts")
    def read_texts(
        staff_id: str = Query(..., max_length=120),
        q: str = Query("", max_length=120),
        limit: int = Query(THREADS, ge=1, le=THREADS),
    ) -> dict[str, Any]:
        """The conversations, the one with the newest text first."""
        reader(staff_id)
        return {
            "on": twilio() is not None,
            "number": number(),
            "listening": listening(),
            **texts().threads(q=q, limit=limit),
        }

    @app.get("/texts/unread")
    def read_unread(staff_id: str = Query(..., max_length=120)) -> dict[str, Any]:
        """How many conversations hold a text nobody has opened: the number on a screen's button."""
        reader(staff_id)
        return {"on": twilio() is not None, "unread": texts().store.unread()}

    @app.get("/texts/with/{number}")
    def read_thread(
        number: str,
        staff_id: str = Query(..., max_length=120),
        before_ms: int | None = Query(None, ge=0),
        limit: int = Query(PAGE, ge=1, le=PAGE),
    ) -> dict[str, Any]:
        """One conversation: its texts, the oldest first."""
        reader(staff_id)
        phone = phone_of(number)
        answer = texts().thread(phone, before_ms=before_ms, limit=limit)
        return {"on": twilio() is not None, **answer}

    @app.post("/texts/with/{number}")
    def send_text(number: str, body: TextIn) -> dict[str, Any]:
        """A person's text to a customer: written down in the conversation and handed to Twilio."""
        person = reader(body.staff_id)
        messenger = twilio()
        if messenger is None:
            message = "This hub has no Twilio account yet: Location, Keys and connections."
            raise HTTPException(409, {"error": "no_service", "message": message})
        try:
            text, new = texts().compose(
                number,
                body.body,
                by_id=person.staff_id,
                by_name=person.name,
                device=body.device,
                text_id=body.id,
                name=body.name,
            )
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        if new:
            messenger.deliver(text.text_id, text.phone, text.body)
        return text.as_json()

    @app.post("/texts/with/{number}/read")
    def mark_read(number: str, body: ReadIn) -> dict[str, Any]:
        """Somebody opened the conversation: what the customer wrote in it is read, for everybody."""
        person = reader(body.staff_id)
        phone = phone_of(number)
        try:
            thread = texts().read(phone, by=person.name)
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        if thread is None:
            raise HTTPException(404, {"error": "unknown_thread", "message": "There are no texts with this number."})
        return thread.as_json()

    @app.get("/texts/picture/{text_id}/{n}")
    def read_picture(text_id: str, n: int, staff_id: str = Query(..., max_length=120)) -> Response:
        """A picture a text carries. Twilio keeps it; the hub fetches it the first time somebody looks."""
        reader(staff_id)
        store = texts().store
        text = store.get(text_id)
        if text is None or not text.sid or not 0 <= n < len(text.pictures):
            raise HTTPException(404, {"error": "unknown_picture", "message": "There is no such picture."})
        kept = store.picture(text.sid, n)
        if kept is None:
            messenger = twilio()
            kept = messenger.picture(text.sid, text.pictures[n].sid) if messenger is not None else None
            if kept is None:
                raise HTTPException(502, {"error": "not_fetched", "message": "Twilio did not hand the picture over."})
            try:
                store.keep_picture(text.sid, n, kept[0], kept[1], app.state.store.now_ms())
            except Exception:  # noqa: BLE001 - a standby keeps nothing: the picture is shown all the same
                pass
        kind, data = kept
        return Response(
            data,
            media_type=kind if kind in SHOWN else "application/octet-stream",
            headers={"Cache-Control": "private, max-age=86400", "X-Content-Type-Options": "nosniff"},
        )
