"""Texts to customers (architecture section 12, "Takeout and pickup"; docs/texts.md): the ready text when a
takeout order is marked ready, "on its way" when a delivery leaves with its driver, and a new time when an
order is pushed back. This module words the texts and decides when one is due; a messenger sends it. A hub
without a texting service has the messenger that only logs; with a Twilio account typed in the app it has
`pos.twilio.TwilioMessenger`, behind the same call.

The texts are in the customer's language (`locale` on the order) with English as the fallback.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Protocol

from .sync.oplog import Op, OrderState, is_delivery, replay

log = logging.getLogger("pos.messaging")


@dataclass(frozen=True)
class Message:
    to: str  # the phone number as the order carries it
    body: str
    locale: str
    order_id: str
    kind: str  # ready | delayed | out
    name: str = ""  # the customer's name as the order has it: what their conversation is listed under

    def as_json(self) -> dict[str, Any]:
        return {"to": self.to, "body": self.body, "locale": self.locale, "order_id": self.order_id, "kind": self.kind}


class Messenger(Protocol):
    def send(self, message: Message) -> None: ...


class LogMessenger:
    """Writes every text to the log and keeps the last few hundred, so the bench (`GET /messages`) and the
    tests see what would have gone out. Nothing leaves the hub: it is what a hub has until a texting service
    is typed in."""

    name = "log"

    def __init__(self, *, keep: int = 500) -> None:
        self.sent: list[Message] = []
        self._keep = keep

    def send(self, message: Message) -> None:
        log.info("text to %s (%s, %s): %s", message.to, message.kind, message.locale, message.body)
        self.sent.append(message)
        del self.sent[: -self._keep]


def about_of(messenger: Messenger) -> dict[str, Any]:
    """How the texts are doing, for the page Keys and connections: `provider` (`log`: no texting service, the
    texts go nowhere; `twilio`), and with a service what it sends from (`sender`), the last day's count
    (`day`) and the last text that failed (`last_failed`). Nothing of a customer."""
    about = getattr(messenger, "about", None)
    if callable(about):
        return dict(about())
    return {"provider": str(getattr(messenger, "name", "log")), "sender": "", "day": None, "last_failed": None}


def messenger_from_env() -> Messenger:
    """The messenger of a hub without a texting service: it logs. `POS_MESSAGING` in the hub's own file names
    no service: Twilio is typed in the app (Location, Keys and connections), and anything but `log` there is
    warned about once and logs too."""
    provider = os.environ.get("POS_MESSAGING", "log")
    if provider != "log":
        log.warning("POS_MESSAGING=%r names no service: Twilio is typed in the app; texts go to the log", provider)
    return LogMessenger()


TEMPLATES: dict[str, dict[str, str]] = {
    "ready": {
        "en": "Hi {name}, order #{no} is ready for pickup at {location}.{pay}",
        "zh": "{name}您好，订单 #{no} 已准备好，请到{location}取餐。{pay}",
    },
    "delayed": {
        "en": "Hi {name}, order #{no} at {location} will be ready at {time}. Sorry for the wait.",
        "zh": "{name}您好，{location}的订单 #{no} 将于{time}准备好，请见谅。",
    },
    # an order that is brought to the customer is not waited for at the counter: the text says when it comes
    "delayed_delivery": {
        "en": "Hi {name}, order #{no} from {location} will be with you around {time}. Sorry for the wait.",
        "zh": "{name}您好，{location}的订单 #{no} 预计{time}送到，请见谅。",
    },
    # a delivery that left with its driver: the text a delivery gets in place of "ready for pickup"
    "out": {
        "en": "Hi {name}, order #{no} from {location} is on its way.",
        "zh": "{name}您好，{location}的订单 #{no} 已出发，正在配送途中。",
    },
    "pay": {"en": " Please pay at pickup.", "zh": "请在取餐时付款。"},
}


def text_for(
    kind: str, state: OrderState, *, location: str, unpaid: bool = False, at: datetime | None = None
) -> Message | None:
    """The text of `kind` for this order in its language, or None when the order has no phone number. A
    delivery that is pushed back is told when it will be there, not when to come for it."""
    fields = state.fields
    phone = str(fields.get("phone") or "").strip()
    if not phone:
        return None
    locale = str(fields.get("locale") or "en")
    words = TEMPLATES["delayed_delivery" if kind == "delayed" and is_delivery(fields) else kind]
    lang = locale if locale in words else "en"
    body = words[lang].format(
        name=str(fields.get("customer_name") or "").strip() or ("there" if lang == "en" else "顾客"),
        no=fields.get("order_no", "?"),
        location=location,
        pay=TEMPLATES["pay"][lang] if unpaid else "",
        time=at.strftime("%H:%M") if at is not None else "",
    )
    name = str(fields.get("customer_name") or "").strip()
    return Message(to=phone, body=body, locale=lang, order_id=state.order_id, kind=kind, name=name)


class Notifier:
    """Watches the operations the hub stores: an order marked ready (`stage` set to `ready`) gets its ready
    text, once (an order that is delivered gets none: the text says to come for it; it is told that it is
    on its way when it leaves with its driver, `stage` set to `out`, the first time only); a promised time
    moved later on an order the kitchen has not finished gets the new time. The time an order is given as it is
    first sent to the kitchen is its quote, not a delay: the terminal settles it then (a big order takes
    longer), and whoever took the order has told the customer. Nor is the later time of an order that was
    just changed from pickup to delivery: the customer asked for that."""

    def __init__(self, messenger: Messenger, *, location: str, unpaid: Callable[[OrderState], bool]) -> None:
        self.messenger = messenger
        self.location = location
        self._unpaid = unpaid

    def on_ops(self, ops_of: Callable[[str], list[Op]], ops: Iterable[Op]) -> list[Message]:
        by_order: dict[str, list[Op]] = {}
        for op in ops:
            by_order.setdefault(op.order_id, []).append(op)
        out: list[Message] = []
        for order_id, batch in by_order.items():
            new = {op.op_id for op in batch}
            everything = ops_of(order_id)
            before = replay([op for op in everything if op.op_id not in new], order_id)
            after = replay(everything, order_id)
            message = self._change(before, after)
            if message is not None:
                self.messenger.send(message)
                out.append(message)
        return out

    def _change(self, before: OrderState, after: OrderState) -> Message | None:
        if str(after.fields.get("order_type") or "dine_in") == "dine_in":
            # a table's check or a bar tab: the guests are in the room. A number typed on it is for the
            # guest list (docs/guest-list.md, "A walk-in's number") and is never sent a text.
            return None
        if after.fields.get("stage") == "ready" and before.fields.get("stage") != "ready":
            if is_delivery(after.fields):
                return None  # it is brought to them: nobody is told to come and get it
            return text_for("ready", after, location=self.location, unpaid=self._unpaid(after))
        if after.fields.get("stage") == "out" and before.fields.get("stage") != "out" and is_delivery(after.fields):
            # taken back and handed to a driver again, it has been told already: `out_at` says it left before
            return None if before.fields.get("out_at") else text_for("out", after, location=self.location)
        was, now = before.fields.get("promised_at"), after.fields.get("promised_at")
        if before.first is not None and isinstance(was, int) and isinstance(now, int) and now > was:
            first_send = not before.fired and bool(after.fired)
            # an order that just became a delivery takes longer because the customer asked for that
            asked = is_delivery(after.fields) and not is_delivery(before.fields)
            if not first_send and not asked and after.fields.get("stage") not in ("ready", "out", "picked_up"):
                return text_for("delayed", after, location=self.location, at=datetime.fromtimestamp(now / 1000))
        return None
