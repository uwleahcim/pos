"""What the order client sends: the customer's choices and nothing else. A price or a name comes with them
only for a dish the menu says asks for it."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ComponentRequest:
    """Customization of an item nested in a recipe."""

    component_id: str
    selections: tuple[Selection, ...] = ()
    components: tuple[ComponentRequest, ...] = ()
    notes: str | None = None


@dataclass(frozen=True)
class Selection:
    group_id: str
    option_id: str
    qty: int = 1
    children: tuple[Selection, ...] = ()  # nested groups, or a slot's linked item's groups
    components: tuple[ComponentRequest, ...] = ()  # a slot's linked item's nested components
    prefix: str | None = None  # a one-tap instruction on the option: no | extra | side | light
    notes: str | None = None  # a kitchen note on the dish behind a slot option ("no sesame" on a roll)


@dataclass(frozen=True)
class LineRequest:
    variant_id: str
    qty: int = 1
    menu_entry_id: str | None = None
    selections: tuple[Selection, ...] = ()
    components: tuple[ComponentRequest, ...] = ()
    notes: str | None = None
    price: str | None = None  # typed at the order, for a dish that asks its price (`Item.asks_price`)
    name: str | None = None  # typed at the order, for an off-menu dish (`Item.asks_name`)
