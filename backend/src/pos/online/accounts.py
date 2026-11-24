"""The restaurant's accounts with GloriaFood: one for each of its websites, and one for trying things out.

A restaurant can have more than one website with GloriaFood (two storefronts, say), and an account it only
tests with. Each is a restaurant of its own at GloriaFood, with its own key for asking and its own orders.
The hub asks every one of them, and an order keeps which one brought it (docs/online-orders.md, "Several
accounts").

What an account is here:

- an `id` the hub gave it, never shown to anybody. The first account is `main`: the one a hub had before
  there could be several, whose key is the slot `online` of `pos.keys` (typed in the app, or put on the hub
  with `hubctl online key`). It is always there, with or without a key.
- a `name` the restaurant gave it ("Sushi site"), said on its orders and their tickets. The first may have
  none: then nothing is said, as before.
- `test`: it is the account the restaurant tries things out with. Its orders say so wherever they show.

The names and which one is for testing are a setting of the location (`online_accounts`), no secret. The
keys are sealed in `pos.keys`, the first under `online` and every other under `online:<id>`.
"""

from __future__ import annotations

import re
import secrets
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

SETTING = "online_accounts"
MAIN = "main"
"""The first account: the one every hub has, whose key is the slot `online`."""
SLOT = "online"
ID = re.compile(r"^[a-z0-9]{1,12}$")
NAME_MAX = 30
MOST = 8
"""More accounts than this is no restaurant's websites: every one is asked every minute."""
_ID_LETTERS = "abcdefghjkmnpqrstuvwxyz23456789"


@dataclass(frozen=True)
class Account:
    id: str
    name: str = ""
    test: bool = False

    @property
    def slot(self) -> str:
        """The name its key is kept under in `pos.keys`."""
        return slot_of(self.id)

    def about(self) -> dict[str, Any]:
        return {"id": self.id, "name": self.name, "test": self.test}


def slot_of(account: str) -> str:
    return SLOT if account == MAIN else f"{SLOT}:{account}"


def account_of_slot(slot: str) -> str | None:
    """The account a key's name belongs to: `online` is the first's, `online:<id>` another's. None for a
    name that is no account's."""
    if slot == SLOT:
        return MAIN
    head, colon, rest = slot.partition(":")
    if head == SLOT and colon and rest != MAIN and ID.fullmatch(rest):
        return rest
    return None


def name_of(text: Any) -> str:
    """A name as it is kept: on one line, its ends trimmed. ValueError for one that is too long."""
    if not isinstance(text, str):
        raise ValueError("the name must be words")
    name = " ".join(text.split())
    if len(name) > NAME_MAX:
        raise ValueError(f"the name is too long ({NAME_MAX} letters at most)")
    return name


def clean_accounts(data: Mapping[str, Any]) -> dict[str, Any]:
    """The accounts as they are stored, checked: a list of `id`, `name` and `test`, the first account
    first whether it was named or not. Every other account has a name, and no two share one. ValueError
    otherwise."""
    rows = data.get("accounts", [])
    if not isinstance(rows, list):
        raise ValueError("accounts must be a list")
    seen: set[str] = set()
    names: set[str] = set()
    cleaned: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, Mapping):
            raise ValueError("each account is an id, a name and whether it is for testing")
        account = row.get("id")
        if not isinstance(account, str) or not ID.fullmatch(account):
            raise ValueError("an account's id is a few small letters and digits")
        if account in seen:
            raise ValueError("two accounts have the same id")
        seen.add(account)
        name = name_of(row.get("name", ""))
        if not name and account != MAIN:
            raise ValueError("give the account a name: it is how its orders are told from the others'")
        if name:
            if name.lower() in names:
                raise ValueError(f"two accounts are named {name}")
            names.add(name.lower())
        test = row.get("test", False)
        if not isinstance(test, bool):
            raise ValueError("test must be true or false")
        cleaned.append({"id": account, "name": name, "test": test})
    if len([row for row in cleaned if row["id"] != MAIN]) > MOST - 1:
        raise ValueError(f"{MOST} accounts is the most a hub asks")
    first = [row for row in cleaned if row["id"] == MAIN] or [{"id": MAIN, "name": "", "test": False}]
    return {"accounts": [*first, *(row for row in cleaned if row["id"] != MAIN)]}


def accounts_of(setting: Mapping[str, Any] | None) -> list[Account]:
    """The accounts a stored setting names, the first account first. What is stored was checked when it was
    written; a row that does not read as an account all the same is left out rather than stop the hub."""
    out: list[Account] = []
    rows = (setting or {}).get("accounts")
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, Mapping):
            continue
        account, name = row.get("id"), row.get("name", "")
        if not isinstance(account, str) or not ID.fullmatch(account) or any(a.id == account for a in out):
            continue
        out.append(Account(account, " ".join(name.split()) if isinstance(name, str) else "", row.get("test") is True))
    first = [a for a in out if a.id == MAIN] or [Account(MAIN)]
    return [*first, *(a for a in out if a.id != MAIN)]


def new_id(taken: Sequence[str]) -> str:
    """An id for an account that is being added: four letters and digits nobody has to read."""
    while True:
        made = "".join(secrets.choice(_ID_LETTERS) for _ in range(4))
        if made != MAIN and made not in taken:
            return made


__all__ = [
    "ID",
    "MAIN",
    "MOST",
    "NAME_MAX",
    "SETTING",
    "SLOT",
    "Account",
    "account_of_slot",
    "accounts_of",
    "clean_accounts",
    "name_of",
    "new_id",
    "slot_of",
]
