"""Twilio's way in: how a call of Twilio's reaches a hub behind the restaurant's router (docs/text-inbox.md,
"Instant delivery and pictures").

Twilio would rather tell than be asked: it calls an address on the internet the moment a customer's text
comes, and again whenever a text the restaurant sent is delivered or is not. And a picture the restaurant
sends is not handed to Twilio: Twilio is given an address and fetches the picture from it. A hub has no
address on the internet. The push door (`pos.online.door`) and the tunnel that brings GloriaFood's pushes to
it (`pos.online.wayin`) give it one, and this module is what the door, the API and the texts share of
Twilio's side of it.

**Three calls, under one word.** The hub makes a long word nobody could guess (`make`). Every address Twilio
is given has it in its path:

- `POST /twilio/<word>/text`: a text came to the restaurant's number.
- `POST /twilio/<word>/status`: something became of a text the restaurant sent.
- `GET /twilio/<word>/media/<text>/<n>/<until>/<mark>`: a picture of a text the restaurant is sending.

The door is handed the word's SHA-256 and lets through only a call whose path carries the word; everything
else stays "not found", as before. The API behind it checks the word again.

**Nothing is taken from a call but a text's name.** A call says which text it is about (Twilio's own name
for it, `MessageSid`). The hub then asks Twilio itself for that text, with the account's key, exactly as it
does when it asks for the list (`pos.texts.Listener`). So the words and the sender of a text only ever come
from Twilio's own answer to the hub's own question, and somebody who learned the address and calls it gets
nothing onto the POS: at the most the hub asks Twilio about a text that does not exist. That is why the
signature Twilio puts on its calls is not what is relied on here, and why this works the same with an
account that is used with an API key, which cannot check that signature.

**A picture's address** says which text and which of its pictures, until when it is good (an hour: Twilio
fetches within seconds) and a mark (`TwilioWay.mark`): an HMAC over those three with a second secret of the
hub's (`seal`), which is in no address. Whoever sees one picture's address cannot make another's, nor one
that is good for longer.

**The word stays out of the logs.** A server writes a line for every call, with its path, and the word is in
the path. `hush` takes it out of those lines, at the door and at the API, before they are written.

**Trying it** (`Knocks`): the hub calls its own text address with a word made for that one try, at the door
and from outside, and knows the word when it arrives, as it does for GloriaFood's way in.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import re
import secrets
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field

WORD = re.compile(r"^[A-Za-z0-9_-]{32,64}$")
"""The hub's word for Twilio, and its second secret: letters, digits, `-` and `_`, 43 as the hub makes them."""
TEXT_ID = r"[A-Za-z0-9_-]{8,64}"
MARK = r"[A-Za-z0-9_-]{22,64}"
PATHS = re.compile(rf"^/twilio/([A-Za-z0-9_-]{{32,64}})/(text|status|media/{TEXT_ID}/\d{{1,2}}/\d{{1,11}}/{MARK})$")
"""Every path of Twilio's way in: the word, and which of the three calls it is. The door goes by this."""
CALL_MOST = 64_000
"""The most a call of Twilio's about a text may weigh, in bytes: they are a few hundred letters."""
PICTURE_FOR_SECONDS = 3600
"""For how long a picture's address is good. Twilio fetches a picture as soon as it is told of the text."""
KNOCK_SECONDS = 60
TWIML = b'<?xml version="1.0" encoding="UTF-8"?><Response/>'
"""What Twilio is answered: "nothing to send back". The staff answer a customer, not the hub."""
SENT_KINDS = ("image/jpeg", "image/png", "image/gif")
"""What a picture the restaurant sends may be: the three kinds every phone company takes in a text."""


_IN_A_LINE = re.compile(r"/twilio/[A-Za-z0-9_-]{8,}")


class _Hushed(logging.Filter):
    """Takes the hub's word for Twilio out of a server's line about a call before the line is written."""

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.args, tuple):
            record.args = tuple(
                _IN_A_LINE.sub("/twilio/-", part) if isinstance(part, str) else part for part in record.args
            )
        if isinstance(record.msg, str):
            record.msg = _IN_A_LINE.sub("/twilio/-", record.msg)
        return True


def hush(name: str = "uvicorn.access") -> None:
    """From now on the server's lines about its calls say `/twilio/-/text` where the word was. Once is
    enough, and more often does no harm."""
    lines = logging.getLogger(name)
    if not any(isinstance(known, _Hushed) for known in lines.filters):
        lines.addFilter(_Hushed())


def make() -> dict[str, str]:
    """A new word for Twilio's calls and a new secret for the marks on pictures' addresses, as they are
    kept (`pos.keys`, the key `texts_way`)."""
    return {"key": secrets.token_urlsafe(32), "seal": secrets.token_urlsafe(32)}


def clean(typed: object) -> dict[str, str]:
    """What is kept of the hub's word for Twilio. It is made by the hub and never typed: anything else is
    turned away, in words that do not say it back."""
    held = typed if isinstance(typed, dict) else {}
    word, seal = str(held.get("key") or ""), str(held.get("seal") or "")
    if not WORD.fullmatch(word) or not WORD.fullmatch(seal):
        raise ValueError("the address for Twilio is made by the hub: turn it on under Texts to customers")
    return {"key": word, "seal": seal}


def same(one: str, other: str) -> bool:
    """Whether two secrets are the same, taking as long whatever they are."""
    return hmac.compare_digest(one.encode("utf-8"), other.encode("utf-8"))


@dataclass(frozen=True)
class TwilioWay:
    """The hub as Twilio reaches it: its name on the internet, the word in every address, and the secret
    the pictures' addresses are marked with."""

    address: str
    word: str = field(repr=False)
    seal: str = field(repr=False)

    def _url(self, rest: str) -> str:
        return f"https://{self.address}/twilio/{self.word}/{rest}"

    @property
    def text_url(self) -> str:
        """What goes into Twilio's console as "A message comes in"."""
        return self._url("text")

    @property
    def status_url(self) -> str:
        """Where Twilio says what became of a text: handed to it with every text the hub sends."""
        return self._url("status")

    def mark(self, text_id: str, n: int, until: int) -> str:
        """The mark on one picture's address: nobody without the hub's second secret can make it."""
        said = f"{text_id}/{n}/{until}".encode()
        made = hmac.new(self.seal.encode("utf-8"), said, hashlib.sha256).digest()
        return base64.urlsafe_b64encode(made).rstrip(b"=").decode()

    def picture_url(self, text_id: str, n: int, now: float) -> str:
        """Where Twilio fetches picture `n` of a text from, good for an hour from `now` (seconds)."""
        until = int(now) + PICTURE_FOR_SECONDS
        return self._url(f"media/{text_id}/{n}/{until}/{self.mark(text_id, n, until)}")

    def good(self, text_id: str, n: int, until: int, mark: str, now: float) -> bool:
        """Whether a picture's address is one the hub made, and still good."""
        return until >= now and same(self.mark(text_id, n, until), mark)


class Knocks:
    """The hub's own tries of Twilio's way in: a word for each, good for a minute, known when it arrives."""

    def __init__(self, now: Callable[[], float] = time.time) -> None:
        self._now = now
        self._lock = threading.Lock()
        self._held: dict[str, list[float | bool]] = {}

    def expect(self) -> str:
        now = self._now()
        word = secrets.token_urlsafe(24)
        with self._lock:
            self._held = {k: told for k, told in self._held.items() if float(told[0]) > now}
            self._held[word] = [now + KNOCK_SECONDS, False]
        return word

    def came(self, word: str) -> bool:
        """A call carries this word as a knock: whether it is one of the hub's own, still good."""
        with self._lock:
            told = self._held.get(word)
            if told is None or float(told[0]) <= self._now():
                return False
            told[1] = True
            return True

    def arrived(self, word: str) -> bool:
        """Whether the hub's knock with this word reached it. The word is used up by asking."""
        with self._lock:
            told = self._held.pop(word, None)
        return bool(told and told[1])


__all__ = [
    "CALL_MOST",
    "PATHS",
    "PICTURE_FOR_SECONDS",
    "SENT_KINDS",
    "TWIML",
    "WORD",
    "Knocks",
    "TwilioWay",
    "clean",
    "hush",
    "make",
    "same",
]
