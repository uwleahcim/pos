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
  `at_ms`: when it last did; `said`: why not) and `send` (`pictures`: a text can carry pictures, because
  Twilio can fetch them from this hub; `most`: how many; `bytes`: how big together).
- `GET /texts/unread?staff_id=`: `on` and `unread` alone, for a button's badge.
- `GET /texts/with/{number}?staff_id=&before_ms=&limit=`: one conversation: `thread`, its `texts` the oldest
  first (the newest hundred, or those before `before_ms`), `more`, and `wrap` (`before`, `after`): what the
  first text to a number that has no conversation yet is sent with around it. Each text: `id`, `inbound`,
  `body`, `at_ms`, `state` (`received`, `waiting`, `sent`, `delivered`, `read`, `failed`), `channel` (`sms`,
  `mms`, `rcs`), `pictures` (`n`, `type`, `image`), `code` and `said` for one that failed, `kind` (empty: a
  person typed it; `ready`, `out`, `delayed`: the POS's own text to an order; `elsewhere`: sent from the
  restaurant's number by something else), `order_id` and `by`.
- `POST /texts/with/{number}` `{staff_id, body, device, id, name, pictures}`: sends a text. `id` is the
  screen's own name for it (so a tap sent twice is one text), `name` what the screen knows the customer by,
  `pictures` up to five pictures to go with it, each a JPEG, a PNG or a GIF as base64 (the words may then be
  empty). The answer is the text, `waiting`: what becomes of it is told on the change feed. 409 `no_service`
  without a Twilio account, 409 `stopped` for a customer who answered STOP, 409 `no_way` for a picture on a
  hub Twilio cannot fetch it from, 422 `no_number`, `no_text`, `too_long`, `too_many`, `too_big`,
  `bad_picture`.
- `POST /texts/with/{number}/read` `{staff_id}`: the conversation was opened: its texts are read.
- `GET /texts/picture/{id}/{n}?staff_id=`: a picture a text carries. A customer's is fetched from Twilio
  the first time somebody looks and kept a month; one the staff sent is on the hub from the moment it was
  sent, and fetched from Twilio once the hub keeps it no longer. 404 for a text or a picture there is none
  of, 502 `not_fetched`.

A change tells the screens on the change feed (`texts`): a text came, one went, one was delivered or was
not, a conversation was read.

**Twilio's own calls** (`pos.online.twilio_way`; they come through the push door, and nothing of the POS
calls them). None is in the list of the API's calls, and each answers "not found" and nothing else unless
its path carries the hub's word for Twilio.

- `POST /twilio/{word}/text` and `POST /twilio/{word}/status`: a text came, or something became of one. The
  hub takes the text's name from the call (`MessageSid`) and nothing else, answers Twilio at once with
  "nothing to send back", and then asks Twilio for that text (`Listener.hear`).
- `GET /twilio/{word}/media/{text}/{n}/{until}/{mark}`: Twilio fetches a picture the staff are sending. The
  address is good for an hour and only as the hub made it.
"""

from __future__ import annotations

import base64
import binascii
from typing import Annotated, Any
from urllib.parse import parse_qsl

from fastapi import BackgroundTasks, FastAPI, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ..identity.powers import holds
from ..identity.staff import Directory, Staff
from ..online.twilio_way import CALL_MOST, TWIML, Knocks, TwilioWay, same
from ..texts import (
    BODY_MAX,
    OWN,
    PAGE,
    SEND_BYTES,
    SEND_MOST,
    THREADS,
    Listener,
    ReadOnlyError,
    Refused,
    Texts,
    number_of,
)
from ..twilio import SERVICE_SID, TEXT_SID, TwilioMessenger
from .auth import powers_of

POWER = "texts"
SHOWN = frozenset({"image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"})
"""What a picture is handed to a screen as. Anything else a text carries goes as plain bytes: a screen
shows that there is one and does not open it."""


PICTURE_TYPED = SEND_BYTES * 4 // 3 + 16
"""The most letters one picture may have as it comes from a screen (base64 of the most a text carries)."""


class TextIn(BaseModel):
    staff_id: str = Field(max_length=120)
    body: str = Field("", max_length=BODY_MAX * 2)
    device: str = Field("", max_length=120)
    id: str = Field("", max_length=64)
    name: str = Field("", max_length=200)
    pictures: list[Annotated[str, Field(max_length=PICTURE_TYPED)]] = Field(default_factory=list, max_length=SEND_MOST)


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

    def way() -> TwilioWay | None:
        """Twilio's way to this hub, where it is turned on and the hub has a name on the internet."""
        found: TwilioWay | None = app.state.texts_way()
        return found

    def clock() -> float:
        return float(app.state.store.now_ms()) / 1000

    def sends() -> dict[str, Any]:
        """What a text of the staff's can carry: pictures where Twilio can fetch them from this hub."""
        return {"pictures": twilio() is not None and way() is not None, "most": SEND_MOST, "bytes": SEND_BYTES}

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
            "send": sends(),
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
        return {"on": twilio() is not None, "send": sends(), **answer}

    @app.post("/texts/with/{number}")
    def send_text(number: str, body: TextIn) -> dict[str, Any]:
        """A person's text to a customer: written down in the conversation and handed to Twilio. Its
        pictures are kept on the hub, and Twilio is told where to fetch each."""
        person = reader(body.staff_id)
        messenger = twilio()
        if messenger is None:
            message = "This hub has no Twilio account yet: Location, Keys and connections."
            raise HTTPException(409, {"error": "no_service", "message": message})
        out = way()
        if body.pictures and out is None:
            message = "A picture needs the hub's way in from the internet: Location, Keys and connections."
            raise HTTPException(409, {"error": "no_way", "message": message})
        try:
            pictures = [base64.b64decode(typed, validate=True) for typed in body.pictures]
        except (binascii.Error, ValueError):
            message = "That picture did not arrive whole. Try it again."
            raise HTTPException(422, {"error": "bad_picture", "message": message}) from None
        try:
            text, new = texts().compose(
                number,
                body.body,
                by_id=person.staff_id,
                by_name=person.name,
                device=body.device,
                text_id=body.id,
                name=body.name,
                pictures=pictures,
            )
        except Refused as err:
            raise refused(err) from err
        except ReadOnlyError as err:
            raise HTTPException(503, {"error": "read_only"}) from err
        if new:
            media = (
                () if out is None else tuple(out.picture_url(text.text_id, n, clock()) for n in range(len(pictures)))
            )
            messenger.deliver(text.text_id, text.phone, text.body, media)
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
        """A picture a text carries. A customer's is Twilio's to keep: the hub fetches it the first time
        somebody looks. One the staff sent is on the hub, and fetched from Twilio once it is there no longer."""
        reader(staff_id)
        store = texts().store
        text = store.get(text_id)
        if text is None or not 0 <= n < len(text.pictures):
            raise HTTPException(404, {"error": "unknown_picture", "message": "There is no such picture."})
        own = not text.pictures[n].sid  # the hub's own: Twilio's name for it was never asked
        under = f"{OWN}{text.text_id}" if own else text.sid
        kept = store.picture(under, n) if under else None
        if kept is None:
            messenger = twilio()
            named = text.pictures[n].sid
            if own and text.sid and messenger is not None:
                listed = messenger.pictures_of(text.sid) or []
                named = listed[n].sid if n < len(listed) else ""
            kept = messenger.picture(text.sid, named) if messenger is not None and text.sid and named else None
            if kept is None:
                raise HTTPException(502, {"error": "not_fetched", "message": "Twilio did not hand the picture over."})
            try:
                store.keep_picture(under, n, kept[0], kept[1], app.state.store.now_ms())
            except Exception:  # noqa: BLE001 - a standby keeps nothing: the picture is shown all the same
                pass
        kind, data = kept
        return Response(
            data,
            media_type=kind if kind in SHOWN else "application/octet-stream",
            headers={"Cache-Control": "private, max-age=86400", "X-Content-Type-Options": "nosniff"},
        )

    # --- Twilio's own calls, which come through the push door (`pos.online.twilio_way`) ---------------------------

    def held(word: str) -> dict[str, str] | None:
        """The hub's word for Twilio and its second secret, where the call's path carries that word."""
        secret: dict[str, str] | None = app.state.way_secret
        return secret if secret and same(word, secret["key"]) else None

    async def called(word: str, request: Request, background: BackgroundTasks) -> Response:
        if held(word) is None:
            return Response(status_code=404)
        said = request.headers.get("content-length", "")
        if said.isdigit() and int(said) > CALL_MOST:
            return Response(status_code=413)
        raw = await request.body()
        if len(raw) > CALL_MOST:
            return Response(status_code=413)
        form = dict(parse_qsl(raw.decode("utf-8", "replace"), keep_blank_values=True))
        knock = form.get("Knock")
        if knock:
            knocks: Knocks = app.state.way_knocks
            knocks.came(knock)  # the hub's own try of the way in: nothing is asked of Twilio for it
            return Response(TWIML, media_type="text/xml")
        sid = form.get("MessageSid") or form.get("SmsSid") or ""
        if TEXT_SID.fullmatch(sid):
            listener: Listener = app.state.text_listener
            # Twilio is answered first and asked after: it waits for nobody, and nothing of its call is
            # believed but which text it is about
            background.add_task(listener.hear, sid)
        return Response(TWIML, media_type="text/xml")

    @app.post("/twilio/{word}/text", include_in_schema=False)
    async def twilio_says_a_text_came(word: str, request: Request, background: BackgroundTasks) -> Response:
        """Twilio's call the moment a text comes to the restaurant's number."""
        return await called(word, request, background)

    @app.post("/twilio/{word}/status", include_in_schema=False)
    async def twilio_says_what_became(word: str, request: Request, background: BackgroundTasks) -> Response:
        """Twilio's call when a text the restaurant sent was sent on, delivered, read or not delivered."""
        return await called(word, request, background)

    @app.get("/twilio/{word}/media/{text_id}/{n}/{until}/{mark}", include_in_schema=False)
    def twilio_fetches_a_picture(word: str, text_id: str, n: int, until: int, mark: str) -> Response:
        """A picture of a text the staff are sending, for Twilio, which was given this address for it."""
        secret = held(word)
        if secret is None or not TwilioWay("", secret["key"], secret["seal"]).good(text_id, n, until, mark, clock()):
            return Response(status_code=404)
        kept = texts().sent_picture(text_id, n)
        if kept is None:
            return Response(status_code=404)
        headers = {"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"}
        return Response(kept[1], media_type=kept[0], headers=headers)
