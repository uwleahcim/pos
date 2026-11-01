"""Texts to customers (architecture section 12, "Takeout and pickup"): the ready text when a takeout order is
marked ready, and a new time when a future order is pushed back. Phase 1 ships the adapter and a messenger
that only logs; a provider (Twilio in the integrations list) plugs in behind the same call in phase 2.

The texts are in the customer's language (`locale` on the order) with English as the fallback.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Protocol

from .sync.oplog import Op, OrderState, replay

log = logging.getLogger("pos.messaging")


@dataclass(frozen=True)
class Message:
    to: str  # the phone number as the order carries it
    body: str
    locale: str
    order_id: str
    kind: str  # ready | delayed

    def as_json(self) -> dict[str, Any]:
        return {"to": self.to, "body": self.body, "locale": self.locale, "order_id": self.order_id, "kind": self.kind}


class Messenger(Protocol):
    def send(self, message: Message) -> None: ...


class LogMessenger:
    """Writes every text to the log and keeps the last few hundred, so the bench (`GET /messages`) and the
    tests see what would have gone out."""

    def __init__(self, *, keep: int = 500) -> None:
        self.sent: list[Message] = []
        self._keep = keep

    def send(self, message: Message) -> None:
        log.info("text to %s (%s, %s): %s", message.to, message.kind, message.locale, message.body)
        self.sent.append(message)
        del self.sent[: -self._keep]


def messenger_from_env() -> Messenger:
    """`POS_MESSAGING` names the provider; only `log` exists yet, and anything else logs too, with a warning."""
    provider = os.environ.get("POS_MESSAGING", "log")
    if provider != "log":
        log.warning("messaging provider %r is not built yet: texts go to the log", provider)
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
    "pay": {"en": " Please pay at pickup.", "zh": "请在取餐时付款。"},
}


def text_for(
    kind: str, state: OrderState, *, location: str, unpaid: bool = False, at: datetime | None = None
) -> Message | None:
    """The text of `kind` for this order in its language, or None when the order has no phone number."""
    fields = state.fields
    phone = str(fields.get("phone") or "").strip()
    if not phone:
        return None
    locale = str(fields.get("locale") or "en")
    lang = locale if locale in TEMPLATES[kind] else "en"
    body = TEMPLATES[kind][lang].format(
        name=str(fields.get("customer_name") or "").strip() or ("there" if lang == "en" else "顾客"),
        no=fields.get("order_no", "?"),
        location=location,
        pay=TEMPLATES["pay"][lang] if unpaid else "",
        time=at.strftime("%H:%M") if at is not None else "",
    )
    return Message(to=phone, body=body, locale=lang, order_id=state.order_id, kind=kind)


class Notifier:
    """Watches the operations the hub stores: an order marked ready (`stage` set to `ready`) gets its ready
    text, once; a promised time moved later on an order the kitchen has not finished gets the new time."""

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
        if after.fields.get("stage") == "ready" and before.fields.get("stage") != "ready":
            return text_for("ready", after, location=self.location, unpaid=self._unpaid(after))
        was, now = before.fields.get("promised_at"), after.fields.get("promised_at")
        if before.first is not None and isinstance(was, int) and isinstance(now, int) and now > was:
            if after.fields.get("stage") not in ("ready", "picked_up"):
                return text_for("delayed", after, location=self.location, at=datetime.fromtimestamp(now / 1000))
        return None
