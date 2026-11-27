"""Texts that really go out: Twilio (docs/texts.md).

`pos.messaging` words the texts a to-go order gets (ready, on its way, a new time) and hands each to a
messenger. Until now the only messenger wrote them to the hub's log. `TwilioMessenger` sends them: one call
to Twilio's Messages API per text, with the restaurant's own Twilio account, which a manager types in the
app (Location, Keys and connections; the key `texts` of `pos.keys`).

**What leaves the building**, and only once a Twilio account is typed in: the customer's phone number and
the text itself (the customer's name as the order has it, the order's number, the restaurant's name), to
Twilio, which hands it to the phone company. Nothing else of the order.

**It never holds an order up.** `send` only puts the text in a line; one thread of the hub's works the line.
A press of Ready answers at once whether Twilio does or not.

**Tried again, a little.** A text Twilio could not be reached for, or answered with a fault of its own, is
tried twice more over half a minute. One that Twilio may have taken (it did not answer in time, or the line
dropped once the text was on its way) is not sent again: a customer is not told twice. What Twilio refuses
(a number that is none, a customer who answered STOP, a key it does not know) is not tried again at all.

**Whether it arrived.** Twilio takes a text and only then finds out whether the phone company delivers it.
The commonest fault of a new account shows only there: a number that is not registered for business texts
(A2P 10DLC) is taken by Twilio and thrown away by the carrier. So the hub asks Twilio after each text what
became of it, a few seconds on and once more later, and keeps the answer.

**What is kept** here (`about`, for the page Keys and connections): for each of the last few hundred texts
when it was, of which kind, for which order, and what became of it. Never the number and never the words:
those are the conversation's to keep (below). The log names the order and the outcome, nothing of the
customer.

**Two guards against a text gone wrong.** The same words to the same number are sent once in ten minutes
(a Ready pressed, taken back and pressed again tells the customer once), and no more than `MOST_AN_HOUR`
texts go out in an hour, whatever asks for them.

**The other way** (docs/text-inbox.md). The same account is asked for the texts that came to the
restaurant's number (`heard`: Twilio's list of the account's messages since a moment), which pictures a
text carries (`pictures_of`) and for a picture itself (`picture`). A hub has no address on the internet for
Twilio to call, so it asks. And a text a person typed at a terminal goes out by the same line as the POS's
own (`deliver`). With a `keeper` (`pos.texts.Texts`) every text that goes out is written down in its
conversation, and what becomes of it is told there: that is where the words are kept, and only there.
"""

from __future__ import annotations

import heapq
import logging
import re
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any, Protocol

import httpx

from .messaging import Message
from .texts import PICTURE_MAX, Picture, number_of

log = logging.getLogger("pos.messaging")

API = "https://api.twilio.com"
SERVICES = "https://messaging.twilio.com"
"""Where Twilio says which numbers a Messaging Service sends from and is texted at."""
ACCOUNT_SID = re.compile(r"^AC[0-9a-fA-F]{32}$")
"""A Twilio account's own name: AC and 32 letters and digits. It is on the first page of Twilio's console."""
KEY_SID = re.compile(r"^SK[0-9a-fA-F]{32}$")
"""An API key's name, where the account is used with one in place of its Auth Token."""
SERVICE_SID = re.compile(r"^MG[0-9a-fA-F]{32}$")
"""A Messaging Service's name: Twilio then picks the number to send from itself."""
ANY_SID = re.compile(r"^[A-Z]{2}[0-9a-fA-F]{32}$")
"""Any name Twilio gives a thing of its own. None of them is a secret."""
TEXT_SID = re.compile(r"^(SM|MM)[0-9a-fA-F]{32}$")
"""A text's own name at Twilio."""
PICTURE_SID = re.compile(r"^ME[0-9a-fA-F]{32}$")
"""The name of a picture a text carries."""
SECRET = re.compile(r"^[!-~]{20,128}$")
"""The Auth Token, or an API key's secret: 32 letters and digits today. Only what is plainly none is turned
away here. Whether it is the right one Twilio says, on a try."""

TRIES = 3
WAITS = (5.0, 20.0)
"""How long after a try that did not get through the next one is made, in seconds."""
LOOKS = (8.0, 45.0)
"""How long after Twilio took a text the hub asks what became of it, in seconds."""
SAME_AGAIN_MS = 10 * 60 * 1000
MOST_AN_HOUR = 300
KEPT = 400
"""How many texts' outcomes are kept, the newest."""
TIMEOUT = 10.0

WAITING, SENT, DELIVERED, READ, FAILED = "waiting", "sent", "delivered", "read", "failed"
TYPED = "text"
"""The kind of a text a person typed at a terminal, among the outcomes kept for the page Keys and connections."""
LIST_PAGE = 100
"""How many messages Twilio is asked for at a time."""
LIST_PAGES = 5
"""The most pages one asking reads: a hub that was off for days catches up over a few askings."""
NUMBERS_FOR = 600.0
"""For how long the numbers of a Messaging Service are remembered before Twilio is asked again, in seconds."""

NOT_REACHED = "Twilio could not be reached"
NO_ANSWER = "Twilio did not answer: the text may or may not have gone"
NO_NUMBER = "the number on the order is not one a text can be sent to"
SAME_AGAIN = "the same text went to this number a few minutes ago: it was not sent twice"
NO_MOBILE = "that is not a phone number a text can go to"
NOT_DELIVERED = "the phone company did not deliver it"
TOO_MANY = f"more than {MOST_AN_HOUR} texts in an hour: this one was held back"
SAID = {
    20003: "Twilio does not know the key: type it again under Keys and connections",
    20404: "Twilio does not know the account or the number to send from",
    21211: NO_NUMBER,
    21217: NO_NUMBER,
    21408: "Twilio may not text that country (Geo permissions in Twilio's console)",
    21601: NO_NUMBER,
    21606: "the number to send from is not one of this Twilio account's that can text",
    21608: "this Twilio account is a trial: it texts only the numbers verified in its console",
    21610: "the customer answered STOP to an earlier text: Twilio sends them no more",
    21614: "the number on the order is no mobile number",
    21659: "the number to send from is not one of this Twilio account's",
    21660: "the number to send from is not one of this Twilio account's",
    30003: "the phone could not be reached",
    30004: "the phone company blocked it",
    30005: "the phone company does not know that number",
    30006: "that number is a landline, or its phone company takes no texts",
    30007: "the phone company took it for spam and did not deliver it",
    30032: "the toll-free number to send from is not verified yet (Twilio's console)",
    30034: "the number to send from is not registered for business texts yet (A2P 10DLC, in Twilio's console)",
}
"""Twilio's error numbers a restaurant is likely to meet, in words for a manager. Any other is said by its
number, which Twilio's own pages explain."""


def said_of(code: int | None) -> str:
    """Why a text did not go, for a manager: the words for Twilio's error number, with the number."""
    if code is None:
        return NOT_REACHED
    return f"{SAID.get(code, 'Twilio would not send it')} (Twilio's error {code})"


def _why(code: int | None) -> tuple[int | None, str]:
    """Twilio's own error number where it gave one, and why the text did not go, in words. `code` is what
    `TwilioMessenger._post` gives: None (Twilio was not reached), -1 (it may have taken the text and did not
    say), the web's own answer (below 1000: Twilio had no error number to give) or Twilio's error number."""
    if code == -1:
        return None, NO_ANSWER
    if code is not None and code < 1000:
        return None, f"Twilio answered with a fault of its own ({code})"
    return code, said_of(code)


def e164(phone: str) -> str | None:
    """A phone number as an order carries it, the way Twilio wants it (+17815550142); None for what is no
    number. Ten digits are a number of this country's (the United States and Canada, +1), eleven that begin
    with 1 are the same with the 1 dialled, and one written with a + is taken as it is."""
    text = str(phone or "").strip()
    digits = re.sub(r"\D", "", text)
    if text.startswith("+"):
        return f"+{digits}" if 8 <= len(digits) <= 15 else None
    if len(digits) == 10 and digits[0] not in "01":
        return f"+1{digits}"
    if len(digits) == 11 and digits[0] == "1" and digits[1] not in "01":
        return f"+{digits}"
    return None


@dataclass(frozen=True)
class TwilioConfig:
    """The restaurant's Twilio account as a manager typed it: the account, its Auth Token (or an API key's
    secret, with that key's own name), and what the texts are sent from, a number of the account's or a
    Messaging Service."""

    account: str
    secret: str = field(repr=False)
    sender: str
    key_sid: str = ""

    @property
    def user(self) -> str:
        """Who the hub says it is to Twilio: the API key where there is one, else the account."""
        return self.key_sid or self.account

    @property
    def by_service(self) -> bool:
        return bool(SERVICE_SID.fullmatch(self.sender))


def clean(typed: Mapping[str, Any]) -> dict[str, str]:
    """What a manager typed for Twilio, checked: what is kept, or ValueError in words that never repeat what
    was typed. `key` is the Auth Token (or an API key's secret), `account` the Account SID, `sender` the
    number to send from or a Messaging Service's SID, and `key_sid` the API key's own SID where one is used."""

    def one(name: str) -> str:
        return "".join(str(typed.get(name) or "").split())  # a paste often brings a space or a line end

    account, secret, key_sid = one("account"), one("key"), one("key_sid")
    sender = str(typed.get("sender") or "").strip()
    if not ACCOUNT_SID.fullmatch(account):
        raise ValueError("the Account SID begins with AC and has 34 letters and digits (Twilio's console, first page)")
    if not secret:
        raise ValueError("no Auth Token was typed")
    if ANY_SID.fullmatch(secret):
        raise ValueError("that is an SID, not the Auth Token: the token is beside the Account SID, behind Show")
    if not SECRET.fullmatch(secret):
        raise ValueError("that does not look like an Auth Token (Twilio's has 32 letters and digits)")
    if key_sid and not KEY_SID.fullmatch(key_sid):
        raise ValueError("an API key's SID begins with SK and has 34 letters and digits; leave it empty without one")
    if SERVICE_SID.fullmatch("".join(sender.split())):
        sender = "".join(sender.split())
    else:
        number = e164(sender)
        if number is None:
            raise ValueError(
                "send from a phone number of the Twilio account's (such as 781 555 0100), "
                "or a Messaging Service's SID (it begins with MG)"
            )
        sender = number
    return {"key": secret, "account": account, "sender": sender, "key_sid": key_sid}


def config_of(data: Mapping[str, str] | None) -> TwilioConfig | None:
    """The account for what `clean` kept; None where the hub holds none."""
    if not data or not data.get("key") or not data.get("account") or not data.get("sender"):
        return None
    return TwilioConfig(data["account"], data["key"], data["sender"], data.get("key_sid", ""))


class Keeper(Protocol):
    """Where the texts that go out are written down (`pos.texts.Texts`): the conversations."""

    def wrote(self, *, to: str, body: str, kind: str, order_id: str = "", name: str = "") -> str | None: ...

    def became(self, text_id: str, *, state: str, sid: str = "", code: int | None = None, said: str = "") -> None: ...


@dataclass
class Outcome:
    """What became of one text. No number and no words: the order it was for, and how it went. `text_id`
    names it in its conversation, where there is a keeper."""

    at_ms: int
    kind: str
    order_id: str
    state: str = WAITING
    code: int | None = None
    said: str = ""
    sid: str = field(default="", repr=False)
    text_id: str = field(default="", repr=False)

    def about(self) -> dict[str, Any]:
        return {
            "at_ms": self.at_ms,
            "kind": self.kind,
            "order_id": self.order_id,
            "state": self.state,
            "code": self.code,
            "said": self.said,
        }


class TwilioMessenger:
    """Sends the POS's texts through Twilio. `transport` stands in for the internet in the tests; with
    `background` off nothing runs by itself and `run_due` works what is due, by the clock `now` (seconds)."""

    name = "twilio"

    def __init__(
        self,
        config: TwilioConfig,
        *,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], float] = time.time,
        background: bool = True,
        sleep: Callable[[float], None] = time.sleep,
        keeper: Keeper | None = None,
    ) -> None:
        self.config = config
        self.keeper = keeper
        self._numbers: tuple[float, frozenset[str]] | None = None  # of the Messaging Service, and when asked
        self.heard_fault = ""
        """Why Twilio's list of messages could not be read the last time it was asked; nothing when it was."""
        self._client = httpx.Client(
            base_url=API, auth=(config.user, config.secret), transport=transport, timeout=TIMEOUT
        )
        self._now = now
        self._sleep = sleep
        self._background = background
        self._lock = threading.Condition()
        self._due: list[tuple[float, int, Callable[[], None]]] = []
        self._n = 0
        self._thread: threading.Thread | None = None
        self._closed = False
        self._outcomes: deque[Outcome] = deque(maxlen=KEPT)
        self._went: deque[tuple[float, str, str]] = deque(maxlen=MOST_AN_HOUR * 2)  # when, to, the words

    # --- the line ----------------------------------------------------------------------------------------

    def send(self, message: Message) -> None:
        """Puts a text in the line. Answers at once; what becomes of it is kept (`about`), and with a keeper
        the text itself is written down in the customer's conversation."""
        outcome = Outcome(int(self._now() * 1000), message.kind, message.order_id)
        with self._lock:
            self._outcomes.append(outcome)
        to = e164(message.to)
        if to is None:
            self._settle(outcome, FAILED, said=NO_NUMBER)
            return
        held = self._held_back(to, message.body)
        if held:
            self._settle(outcome, FAILED, said=held)
            return
        if self.keeper is not None:
            try:
                outcome.text_id = (
                    self.keeper.wrote(
                        to=to, body=message.body, kind=message.kind, order_id=message.order_id, name=message.name
                    )
                    or ""
                )
            except Exception as err:  # noqa: BLE001 - an order's text goes whether or not it could be written down
                log.warning("texts: one could not be written down (%s)", type(err).__name__)
        self._later(0.0, lambda: self._try(outcome, to, message.body, 1))

    def deliver(self, text_id: str, to: str, body: str) -> None:
        """Puts a text a person typed in the line. It is in its conversation already (`pos.texts`), under
        `text_id`: what becomes of it is told there. The same words twice are a person's to send; the hour's
        limit holds for them as for every text."""
        outcome = Outcome(int(self._now() * 1000), TYPED, "", text_id=text_id)
        with self._lock:
            self._outcomes.append(outcome)
        number = e164(to)
        if number is None:
            self._settle(outcome, FAILED, said=NO_MOBILE)
            return
        held = self._held_back(number, body, twice=True)
        if held:
            self._settle(outcome, FAILED, said=held)
            return
        self._later(0.0, lambda: self._try(outcome, number, body, 1))

    def _held_back(self, to: str, body: str, *, twice: bool = False) -> str:
        """Why this text is not sent at all: the same went to the same number just now (unless it may go
        `twice`), or too many went out this hour. Nothing when it may go; it is then counted as one that
        went."""
        now = self._now()
        with self._lock:
            hour = [went for went in self._went if went[0] > now - 3600]
            same = any(went[1] == to and went[2] == body and went[0] > now - SAME_AGAIN_MS / 1000 for went in hour)
            if same and not twice:
                return SAME_AGAIN
            if len(hour) >= MOST_AN_HOUR:
                return TOO_MANY
            self._went.append((now, to, body))
        return ""

    def _forget(self, to: str, body: str) -> None:
        """A text that did not go is not held against the next try of the same one."""
        with self._lock:
            kept = [went for went in self._went if (went[1], went[2]) != (to, body)]
            self._went.clear()
            self._went.extend(kept)

    def _later(self, after: float, work: Callable[[], None]) -> None:
        with self._lock:
            if self._closed:
                return
            self._n += 1
            heapq.heappush(self._due, (self._now() + after, self._n, work))
            if self._background and self._thread is None:
                self._thread = threading.Thread(target=self._run, name="texts", daemon=True)
                self._thread.start()
            self._lock.notify()

    def _run(self) -> None:
        while True:
            with self._lock:
                while not self._closed and (not self._due or self._due[0][0] > self._now()):
                    wait = self._due[0][0] - self._now() if self._due else None
                    self._lock.wait(wait)
                if self._closed:
                    return
                _, _, work = heapq.heappop(self._due)
            self._do(work)

    def run_due(self) -> int:
        """Works everything that is due by the clock, in its order; gives how many. For the tests, and for
        a messenger that runs no thread of its own."""
        done = 0
        while True:
            with self._lock:
                if not self._due or self._due[0][0] > self._now():
                    return done
                _, _, work = heapq.heappop(self._due)
            self._do(work)
            done += 1

    @staticmethod
    def _do(work: Callable[[], None]) -> None:
        try:
            work()
        except Exception as err:  # noqa: BLE001 - one text that goes wrong must not stop the ones after it
            log.error("texts: one could not be worked (%s)", type(err).__name__)

    @property
    def waiting(self) -> int:
        with self._lock:
            return len(self._due)

    def close(self) -> None:
        """No more texts are taken, and the ones still in the line are dropped: the account was exchanged."""
        with self._lock:
            self._closed = True
            self._due.clear()
            self._lock.notify_all()
        self._client.close()

    # --- one text ----------------------------------------------------------------------------------------

    def _post(self, to: str, body: str) -> tuple[str, int | None, bool]:
        """One call to Twilio. Gives the text's own name at Twilio when it took it; else Twilio's error
        number (None when there was no answer to read), and whether another try could help."""
        data = {"To": to, "Body": body}
        data["MessagingServiceSid" if self.config.by_service else "From"] = self.config.sender
        try:
            answer = self._client.post(f"/2010-04-01/Accounts/{self.config.account}/Messages.json", data=data)
        except (httpx.ConnectError, httpx.ConnectTimeout):
            return "", None, True  # it never reached Twilio
        except httpx.HTTPError:
            # no answer in time, or the line dropped once the text was on its way: Twilio may have it. Not twice
            return "", -1, False
        except RuntimeError:
            return "", None, False  # the account was exchanged under this very text: its messenger is closed
        told = _json(answer)
        if answer.status_code in (200, 201) and isinstance(told.get("sid"), str):
            return told["sid"], None, False
        code = told.get("code")
        if answer.status_code == 401 and not isinstance(code, int):
            code = 20003
        again = answer.status_code == 429 or answer.status_code >= 500
        return "", code if isinstance(code, int) else answer.status_code, again

    def _try(self, outcome: Outcome, to: str, body: str, n: int) -> None:
        sid, code, again = self._post(to, body)
        if sid:
            outcome.sid = sid
            self._settle(outcome, SENT)
            self._later(LOOKS[0], lambda: self._look(outcome, 0))
            return
        if again and n < TRIES:
            self._later(WAITS[min(n, len(WAITS)) - 1], lambda: self._try(outcome, to, body, n + 1))
            return
        if code != -1:
            self._forget(to, body)  # it did not go: the same text may be tried again by hand at once
        number, said = _why(code)
        self._settle(outcome, FAILED, code=number, said=said)

    def _status(self, sid: str) -> tuple[str, int | None]:
        """What Twilio says became of a text it took: its word (`delivered`, `undelivered`, `failed`, or one
        for still on its way), and its error number where it has one. Nothing where it cannot be asked."""
        try:
            answer = self._client.get(f"/2010-04-01/Accounts/{self.config.account}/Messages/{sid}.json")
        except (httpx.HTTPError, RuntimeError):
            return "", None
        told = _json(answer)
        code = told.get("error_code")
        return str(told.get("status") or ""), code if isinstance(code, int) else None

    def _look(self, outcome: Outcome, n: int) -> None:
        status, code = self._status(outcome.sid)
        if status in ("delivered", "read"):
            self._settle(outcome, READ if status == "read" else DELIVERED)
        elif status in ("undelivered", "failed"):
            self._settle(outcome, FAILED, code=code, said=said_of(code) if code else NOT_DELIVERED)
        elif n + 1 < len(LOOKS):
            self._later(LOOKS[n + 1] - LOOKS[n], lambda: self._look(outcome, n + 1))
        # else it stays `sent`: not every phone company says that a text arrived

    def _settle(self, outcome: Outcome, state: str, *, code: int | None = None, said: str = "") -> None:
        with self._lock:
            outcome.state, outcome.code, outcome.said = state, code, said
        what = f"the {outcome.kind} text for order {outcome.order_id}" if outcome.order_id else "a typed text"
        if state == FAILED:
            log.warning("texts: %s did not go: %s", what, said)
        else:
            log.info("texts: %s: %s", what, state)
        if self.keeper is not None and outcome.text_id:
            try:
                self.keeper.became(outcome.text_id, state=state, sid=outcome.sid, code=code, said=said)
            except Exception as err:  # noqa: BLE001 - the text went as it went, written down or not
                log.warning("texts: what became of one could not be written down (%s)", type(err).__name__)

    # --- by hand -----------------------------------------------------------------------------------------

    def try_now(self, to: str, body: str, *, wait: float = 12.0, every: float = 2.0) -> dict[str, Any]:
        """Sends one text now and waits a little to hear what became of it: a manager's try of the account.
        `ok` when Twilio took it and did not say since that it failed; `state` is `delivered` when the phone
        company said it arrived within the wait."""
        number = e164(to)
        if number is None:
            return {"ok": False, "state": FAILED, "code": None, "said": NO_MOBILE}
        sid, code, _ = self._post(number, body)
        if not sid:
            fault, said = _why(code)
            return {"ok": False, "state": FAILED, "code": fault, "said": said}
        waited = 0.0
        while waited < wait:
            self._sleep(every)
            waited += every
            status, fault = self._status(sid)
            if status in ("delivered", "read"):
                return {"ok": True, "state": DELIVERED, "code": None, "said": ""}
            if status in ("undelivered", "failed"):
                return {"ok": False, "state": FAILED, "code": fault, "said": said_of(fault) if fault else NOT_DELIVERED}
        return {"ok": True, "state": SENT, "code": None, "said": ""}

    # --- for a screen ------------------------------------------------------------------------------------

    def about(self) -> dict[str, Any]:
        """How the texts are doing, for the page Keys and connections: what they are sent from, how many
        went in the last day and how many of those failed, and the last one that failed with why. No
        number of a customer's and no words of a text."""
        since = int((self._now() - 24 * 3600) * 1000)
        with self._lock:
            day = [outcome for outcome in self._outcomes if outcome.at_ms >= since]
            failed = [outcome for outcome in day if outcome.state == FAILED]
            # a text a person typed says in its conversation that it did not go: the page names an order's
            of_orders = [outcome for outcome in failed if outcome.order_id]
            return {
                "provider": self.name,
                "sender": self.config.sender,
                "day": {
                    "texts": len(day),
                    "delivered": sum(1 for outcome in day if outcome.state in (DELIVERED, READ)),
                    "failed": len(failed),
                },
                "last_failed": of_orders[-1].about() if of_orders else None,
            }

    # --- the other way: what came -------------------------------------------------------------------------

    def heard(self, since_ms: int) -> list[dict[str, Any]] | None:
        """The texts of the restaurant's number that Twilio has from `since_ms` on, in and out, the newest
        first, each as Twilio's list of messages describes it. None when Twilio could not be asked or would
        not say (`heard_fault` says why). Texts to and from the account's other numbers are left out."""
        since = datetime.fromtimestamp(since_ms / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        path = f"/2010-04-01/Accounts/{self.config.account}/Messages.json"
        params: dict[str, str] | None = {"DateSent>": since, "PageSize": str(LIST_PAGE)}
        numbers = self._service_numbers() if self.config.by_service else frozenset()
        found: list[dict[str, Any]] = []
        for _ in range(LIST_PAGES):
            try:
                answer = self._client.get(path, params=params)
            except (httpx.HTTPError, RuntimeError):
                self.heard_fault = NOT_REACHED
                return None
            told = _json(answer)
            rows = told.get("messages")
            if answer.status_code != 200 or not isinstance(rows, list):
                code = told.get("code")
                if answer.status_code == 401 and not isinstance(code, int):
                    code = 20003
                self.heard_fault = _why(code if isinstance(code, int) else answer.status_code)[1]
                return None
            older = False
            for row in rows:
                if not isinstance(row, dict):
                    continue
                if _sent_ms(row) is not None and _sent_ms(row) < since_ms - 60_000:  # type: ignore[operator]
                    older = True  # Twilio went by the day alone: the rest of the list is older still
                    continue
                if self._ours(row, numbers):
                    found.append(row)
            following = told.get("next_page_uri")
            if older or not rows or not isinstance(following, str) or not following.startswith("/2010-04-01/"):
                break
            path, params = following, None
        self.heard_fault = ""
        return found

    def _ours(self, row: Mapping[str, Any], numbers: frozenset[str]) -> bool:
        """Whether a message of the account's is one of this restaurant's texts: to or from the number the
        POS sends from, or through its Messaging Service (by the service's name on the message, by one of
        its numbers, or as a chat message, which only a service carries)."""
        inbound = str(row.get("direction") or "").startswith("inbound")
        mine = str((row.get("to") if inbound else row.get("from")) or "")
        if not self.config.by_service:
            return not mine.startswith("rcs:") and number_of(mine) == self.config.sender
        if row.get("messaging_service_sid") == self.config.sender:
            return True
        return mine.startswith("rcs:") or number_of(mine) in numbers

    def _service_numbers(self) -> frozenset[str]:
        """The numbers of the Messaging Service the POS sends through, asked of Twilio now and then: a text
        that came to one of them is the restaurant's. What was known last where Twilio does not say."""
        now = self._now()
        if self._numbers is not None and now - self._numbers[0] < NUMBERS_FOR:
            return self._numbers[1]
        known = self._numbers[1] if self._numbers is not None else frozenset()
        try:
            answer = self._client.get(
                f"{SERVICES}/v1/Services/{self.config.sender}/PhoneNumbers", params={"PageSize": "100"}
            )
            rows = _json(answer).get("phone_numbers") if answer.status_code == 200 else None
        except (httpx.HTTPError, RuntimeError):
            rows = None
        if isinstance(rows, list):
            listed = (number_of(row.get("phone_number")) for row in rows if isinstance(row, dict))
            known = frozenset(number for number in listed if number)
        self._numbers = (now, known)
        return known

    def pictures_of(self, sid: str) -> list[Picture] | None:
        """The pictures a text carries, as Twilio lists them: each one's name and what it is. None when
        Twilio could not be asked."""
        if not TEXT_SID.fullmatch(sid):
            return None
        try:
            answer = self._client.get(f"/2010-04-01/Accounts/{self.config.account}/Messages/{sid}/Media.json")
        except (httpx.HTTPError, RuntimeError):
            return None
        rows = _json(answer).get("media_list") if answer.status_code == 200 else None
        if not isinstance(rows, list):
            return None
        return [
            Picture(str(row["sid"]), str(row.get("content_type") or ""))
            for row in rows
            if isinstance(row, dict) and isinstance(row.get("sid"), str) and PICTURE_SID.fullmatch(row["sid"])
        ]

    def picture(self, sid: str, picture_sid: str) -> tuple[str, bytes] | None:
        """One picture of a text, fetched from Twilio: what it says it is, and the picture. None when it
        could not be had, and for one bigger than a screen is handed (`PICTURE_MAX`)."""
        if not TEXT_SID.fullmatch(sid) or not PICTURE_SID.fullmatch(picture_sid):
            return None
        url = f"/2010-04-01/Accounts/{self.config.account}/Messages/{sid}/Media/{picture_sid}"
        try:
            # Twilio answers with where the picture is kept: the account's key is not sent on there
            with self._client.stream("GET", url, follow_redirects=True) as answer:
                if answer.status_code != 200:
                    return None
                parts: list[bytes] = []
                size = 0
                for part in answer.iter_bytes():
                    size += len(part)
                    if size > PICTURE_MAX:
                        return None
                    parts.append(part)
                kind = answer.headers.get("content-type", "").split(";")[0].strip().lower()
        except (httpx.HTTPError, RuntimeError):
            return None
        return kind, b"".join(parts)


def _json(answer: httpx.Response) -> dict[str, Any]:
    try:
        told = answer.json()
    except ValueError:
        return {}
    return told if isinstance(told, dict) else {}


def _sent_ms(row: Mapping[str, Any]) -> int | None:
    """When Twilio says a message was sent, as wall-clock ms; None where it does not say (one still in
    its line)."""
    raw = row.get("date_sent")
    if not isinstance(raw, str) or not raw:
        return None
    try:
        at = parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=UTC)
    return int(at.timestamp() * 1000)


__all__ = [
    "MOST_AN_HOUR",
    "Keeper",
    "Outcome",
    "TwilioConfig",
    "TwilioMessenger",
    "clean",
    "config_of",
    "e164",
    "said_of",
]
