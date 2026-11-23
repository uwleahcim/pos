"""Who may do what: the powers each role holds at this location (docs/roles.md).

A power is one thing the hub lets some of the staff do and refuses the rest: approve the void of a dish the
kitchen has, read the sales, change the menu. The location's setting `powers` says which roles hold each one
(`pos/settings.py`, `clean_powers`), and every check on the hub asks `holds`.

Two rules keep the table safe to change:

- **A manager and an owner hold every power, always.** Nothing in the setting takes one from them, so no
  mistake on the screen can leave the location with nobody who may void a dish or open the settings.
- **The settings themselves are never handed out** (`SETTINGS`): the location's settings, the printers, the
  staff's tags and faces, and this table. Only a manager or an owner changes who may do what.

So the setting only ever hands a power to more roles: the servers, the bartenders, the hosts, the cashiers,
the kitchen and the drivers (`HANDED`). To start, the table says what the hub did before there was one;
a driver, a role that came with deliveries (docs/delivery.md), starts with the one power that came with it.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

ALWAYS = frozenset({"manager", "owner"})
"""The roles that hold every power, whatever the setting says."""
HANDED = ("server", "bartender", "host", "cashier", "kitchen", "driver")
"""The roles a power can be handed to, in the order the screen lists them."""
SETTINGS = "settings"
"""The power no setting hands out: the location's settings and this table."""


@dataclass(frozen=True)
class Power:
    id: str
    about: str
    """What holding it lets a person do, for whoever reads the code or the API."""
    roles: tuple[str, ...] = ()
    """The roles besides a manager and an owner that hold it to start."""
    session: bool = True
    """Whether it is used with a session from `POST /admin/session` (the back office). The others are a PIN
    on the spot for one check (`POST /approvals`) or say who the floor map offers."""


POWERS: tuple[Power, ...] = (
    Power("void", "their PIN approves the void of a dish the kitchen already has", session=False),
    Power("adjust", "their PIN approves a discount, a comp, or taking a service charge off", session=False),
    Power("exempt", "their PIN approves marking a check tax exempt", session=False),
    Power("history", "read a check's whole history: every step, who did it and when"),
    Power(
        "take_tables", "a table can be theirs: the floor map offers them as a server", ("server", "bartender"), False
    ),
    Power(
        "assign_tables",
        "seat a party for someone else, hand a table over and say who is in tonight's turn for a table",
        ("host",),
        False,
    ),
    Power(
        "deliver", "a delivery can be handed to them: the Deliveries screen offers them as a driver", ("driver",), False
    ),
    Power("rush", "say the kitchen is behind: minutes on every new quote for tonight"),
    Power("notes", "write, change and take down the notes for the shift, and see who has read them"),
    Power("logbook", "read and write the manager's log"),
    Power("waste", "read the waste totals and strike out anyone's entry of any day"),
    Power("reports", "read the day's report, the sales and the dishes sold, and print the day"),
    Power(
        "guests",
        "read the guest list: the phone customers, their visits and what they spent; keep each one's note and tags",
    ),
    Power("time_clock", "read everyone's hours and correct a shift"),
    Power("menu", "change the menu in the menu editor"),
)
BY_ID = {power.id: power for power in POWERS}
APPROVALS = frozenset({"void", "adjust", "exempt"})
"""The powers that are a PIN on the spot for one check."""
STANDARD = {power.id: list(power.roles) for power in POWERS}
"""The table to start with: what the hub did before it could be changed."""


def clean_powers(data: Mapping[str, Any]) -> dict[str, Any]:
    """The table as the app may set it, checked: `roles`, for each power the roles it is handed to. A power
    left out keeps its standard roles. A manager and an owner are never listed: they hold every power
    anyway, so listing them is refused rather than kept as if it meant something. Raises ValueError on a
    power or a role this hub does not know."""
    raw = data.get("roles")
    if raw is None:
        raw = {}
    if not isinstance(raw, Mapping):
        raise ValueError("roles must say, for each power, the roles that hold it")
    roles = {power: list(standard) for power, standard in STANDARD.items()}
    for power, handed in raw.items():
        if power == SETTINGS:
            raise ValueError("the settings stay with the managers and the owners")
        if power not in BY_ID:
            raise ValueError(f"unknown power: {power}")
        if not isinstance(handed, list | tuple) or not all(isinstance(role, str) for role in handed):
            raise ValueError(f"{power}: the roles must be a list of words")
        for role in handed:
            if role in ALWAYS:
                raise ValueError(f"{power}: a {role} holds every power already")
            if role not in HANDED:
                raise ValueError(f"{power}: unknown role: {role}")
        roles[power] = [role for role in HANDED if role in handed]  # in the screen's order, each once
    return {"roles": roles}


def holds(setting: Mapping[str, Any] | None, role: str, power: str) -> bool:
    """Whether `role` holds `power` under the location's `setting` (None: the standard table)."""
    if role in ALWAYS:
        return True
    if power == SETTINGS or power not in BY_ID or role not in HANDED:
        return False
    roles = (setting or {}).get("roles")
    handed = roles.get(power) if isinstance(roles, Mapping) else None
    if handed is None:
        handed = STANDARD[power]
    return role in handed


def standard(role: str, power: str) -> bool:
    """Whether `role` holds `power` under the standard table: what a check falls back to when nobody tells it
    the location's own."""
    return holds(None, role, power)


May = Callable[[str, str], bool]
"""A check of the location's table as it stands now: `may(role, power)`."""


def held(setting: Mapping[str, Any] | None, role: str) -> list[str]:
    """Every power `role` holds, in the table's order; a manager's and an owner's end with `settings`."""
    powers = [power.id for power in POWERS if holds(setting, role, power.id)]
    return [*powers, SETTINGS] if role in ALWAYS else powers


def opens_back_office(setting: Mapping[str, Any] | None, role: str) -> bool:
    """Whether `role` holds anything a session is for, so `POST /admin/session` gives them one."""
    return role in ALWAYS or any(power.session and holds(setting, role, power.id) for power in POWERS)


def table(setting: Mapping[str, Any] | None) -> dict[str, Any]:
    """The table as `GET /settings/powers` answers it: `roles` (each power's handed roles), and what the
    screen needs to draw it without knowing this hub's list by heart: the `powers` in order with what each
    is for, the roles a power can be `handed` to and the ones that `always` hold everything."""
    return {
        "roles": {power.id: [role for role in HANDED if holds(setting, role, power.id)] for power in POWERS},
        "powers": [{"id": power.id, "about": power.about, "session": power.session} for power in POWERS],
        "handed": list(HANDED),
        "always": sorted(ALWAYS),
    }
