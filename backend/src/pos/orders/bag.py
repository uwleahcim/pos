"""What goes in the bag with a to-go order: the one question asked before it is sent, and its answer.

Chopsticks, forks, napkins: the old POS rang them as free dishes, and an order went out with none when
nobody thought to ask. Here the location lists what to offer (the `bag` setting: the question's words and
its choices, `pos.settings.clean_bag`) and the screen asks once, before a to-go order is first sent. It is
one question, since every question is a tap more on every order, and "nothing" is an answer.

The answer is an order field, `bag`, set like any field (`set_field`), so a hub that does not know it
simply keeps nothing. It is `{"items": [{"id", "name", "qty"}, ...]}` in the order the choices were picked;
no items means nothing was wanted, and no field at all means nobody was asked. Each item keeps the name it
was offered under, so a choice renamed or dropped later still reads as it was asked.

Before it is stored the hub tidies it (`bag_ops`): an answer it cannot read is left out and reported, like a
refused discount. Whether the question was asked at all is the screen's business: an order taken while no
hub answered, or by a screen that was not rebuilt, is sent all the same.

The takeout station's ticket, the copy that goes with the bag, lists the answer under the dishes
(`pos.printing.service`). An answer that changes after the order went to the kitchen prints a slip there.
Nothing about the check changes: these cost nothing and are in no total.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import replace
from typing import Any

from ..sync.oplog import ORDER_FIELDS, Op

FIELD = "bag"
CHOICE_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
NAME_MAX = 24
"""How long a choice's name may be: a button on a phone, and a line of the ticket in big letters."""
ITEMS_MAX = 8
"""As many choices as a location may list (`pos.settings.BAG_CHOICES_MAX`): one screenful of buttons."""
QTY_MAX = 99


def bag_of(fields: Mapping[str, Any]) -> dict[str, Any] | None:
    """The answer an order carries, or None while nobody answered: `items`, each `{id, name, qty}`, in the
    order they were picked. No items: nothing was wanted."""
    value = fields.get(FIELD)
    if not isinstance(value, Mapping):
        return None
    items, problem = _items(value.get("items"))
    return None if problem else {"items": items}


def bag_lines(answer: Mapping[str, Any]) -> tuple[str, ...]:
    """The answer as a ticket lists it, a line a choice: "2 x Chopsticks", "Forks". No line: nothing was wanted."""
    return tuple(f"{item['qty']} x {item['name']}" if item["qty"] > 1 else item["name"] for item in answer["items"])


def bag_ops(ops: list[Op]) -> tuple[list[Op], list[dict[str, Any]]]:
    """Tidy every new answer before it is stored. One the hub cannot read is left out and reported with what
    is wrong with it; whatever else its operation says of the order goes through without it."""
    if not any(_answers(op) for op in ops):
        return ops, []
    kept: list[Op] = []
    refused: list[dict[str, Any]] = []
    for op in ops:
        if _answers(op):
            data = dict(op.data)
            wanted = data[FIELD]
            if wanted is None or wanted is False:
                data[FIELD] = None  # the answer taken back: the order is asked about again
            else:
                listed = wanted.get("items") if isinstance(wanted, Mapping) else wanted
                items, problem = _items(listed)
                if problem:
                    refused.append({"op_id": op.op_id, "error": "invalid_bag", "message": problem})
                    del data[FIELD]
                    if op.kind != "create" and not any(name in ORDER_FIELDS for name in data):
                        continue  # it said nothing else of the order
                else:
                    data[FIELD] = {"items": items}
            op = replace(op, data=data)
        kept.append(op)
    return kept, refused


def _answers(op: Op) -> bool:
    return op.kind in ("create", "set_field") and FIELD in op.data


def _items(listed: Any) -> tuple[list[dict[str, Any]], str | None]:
    """The items of an answer, tidied, or what is wrong with them."""
    if not isinstance(listed, list | tuple):
        return [], "an answer lists what goes in the bag"
    if len(listed) > ITEMS_MAX:
        return [], f"at most {ITEMS_MAX} things go on the list"
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in listed:
        if not isinstance(entry, Mapping):
            return [], "each thing in the bag is {id, name, qty}"
        ident = entry.get("id")
        if not isinstance(ident, str) or not CHOICE_ID.match(ident):
            return [], f"a choice's id is letters, digits, - or _, not {ident!r}"
        if ident in seen:
            return [], f"{ident} is listed twice"
        seen.add(ident)
        name = " ".join(entry["name"].split()) if isinstance(entry.get("name"), str) else ""
        if len(name) > NAME_MAX:
            return [], f"a choice's name takes {NAME_MAX} letters"
        qty = entry.get("qty", 1)
        if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= QTY_MAX:
            return [], f"how many is a number from 1 to {QTY_MAX}"
        items.append({"id": ident, "name": name or ident, "qty": qty})
    return items, None


__all__ = ["FIELD", "ITEMS_MAX", "NAME_MAX", "QTY_MAX", "bag_lines", "bag_of", "bag_ops"]
