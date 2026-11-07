"""Modifier options that are dishes: a group's options linked to the catalog, or sourced from a category.

The Menu Engine Design makes a combo "an item whose modifier groups offer other items as choices": an option
carries `linked_variant`, and the engine resolves the dish behind it as a child line with its own station,
price mode, recipe and modifier groups. This module keeps two kinds of such groups right:

- An option linked by hand (the soup choice on a lunch special points at the real Miso Soup) needs nothing
  here; `Definitions.option_names` lets it borrow the dish's names so a rename follows.
- A group whose options come from a whole category (`Group.source_category`: the maki combination offers
  the Roll category) is kept in step by `sync`: every dish on sale in the category, and in the categories
  under it, is an option linked to it, one per size when the dish has several; an option whose dish left the
  category, went off sale or was deleted goes; options added by hand stay; prices, defaults and sort set on
  the options already there are left alone. `sync` runs on every save and import, so a new roll is offered in
  the combination the moment it is on the menu.

`relink` brings a stored menu seeded before any of this up to date with the bundled files
(`hubctl menu import --apply`): it links the options the files link, sources the groups the files source,
and drops the export's own copies of the dishes (the numbered options a category-sourced group used to hold).
"""

from __future__ import annotations

import re
from dataclasses import replace

from .defs import Definitions, Group, Item, Option, Variant


def option_code(item: Item, variant: Variant, several: bool) -> str:
    """The code of the option standing for a dish in a sourced group: the dish's code, with the size when the
    dish has several (`K01`, `Y21-medium`). Deterministic, so a hub and the editor agree on the ids."""
    return f"{item.code}-{variant.code}" if several else item.code


def wanted_options(defs: Definitions, group: Group) -> list[Option]:
    """The options a sourced group should hold for its category's dishes, as they would be created fresh."""
    if not group.source_category:
        return []
    out: list[Option] = []
    for item in defs.items_in(group.source_category):
        if not item.active:
            continue
        variants = [v for v in defs.variants_of(item.code) if v.active]
        several = len(variants) > 1
        for n, variant in enumerate(variants):
            code = option_code(item, variant, several)
            out.append(
                Option(
                    f"{group.code}:{code}",
                    group.code,
                    code,
                    {},  # named after the dish (Definitions.option_names)
                    None,
                    "delta",
                    linked_variant=variant.id,
                    sort=item.sort * 10 + n,
                )
            )
    return out


def sync(defs: Definitions) -> list[str]:
    """Make every sourced group's options match its category, in place; what changed, as text."""
    changed: list[str] = []
    for group in list(defs.groups.values()):
        if not group.source_category:
            continue
        if group.source_category not in defs.categories:
            continue  # reported by the checks; nothing to sync against
        wanted = {o.id: o for o in wanted_options(defs, group)}
        held = {o.id: o for o in defs.options_of(group.code)}
        for oid, fresh in wanted.items():
            have = held.get(oid)
            if have is None:
                defs.options[oid] = fresh
                changed.append(f"option {oid} added: {defs.option_names(fresh).get('en', oid)}")
            elif have.linked_variant != fresh.linked_variant or have.sort != fresh.sort:
                defs.options[oid] = replace(have, linked_variant=fresh.linked_variant, sort=fresh.sort)
        for oid, have in held.items():
            if have.linked_variant and oid not in wanted:
                del defs.options[oid]
                changed.append(f"option {oid} removed: its dish is no longer in {group.source_category}")
    return changed


def _norm(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def relink(stored: Definitions, bundled: Definitions) -> list[str]:
    """Give `stored` the links the bundled files have, in place; what changed, as text.

    A stored group the files now source from a category takes the category, and loses the options that were
    the export's own copies of its dishes (numbered codes, or a name that is a dish of the category); options
    the editor added stay. A stored option the files link to a dish, still unlinked, takes the link, and
    drops its own names when they are the dish's, so the dish's names show from then on. Nothing the editor
    set otherwise moves. Run `sync` after."""
    changed: list[str] = []
    for code, wanted in bundled.groups.items():
        held = stored.groups.get(code)
        if held is None or not wanted.source_category or held.source_category:
            continue
        if wanted.source_category not in stored.categories:
            continue
        stored.groups[code] = replace(held, source_category=wanted.source_category)
        changed.append(f"group {code} now offers the dishes of {wanted.source_category}")
        dishes = {_norm(stored.localizer.text(i.names, "en")) for i in stored.items_in(wanted.source_category)}
        for opt in stored.options_of(code):
            if opt.linked_variant:
                continue
            name = _norm(stored.localizer.text(opt.names, "en"))
            if opt.code.isdigit() or name in dishes:
                del stored.options[opt.id]
                changed.append(f"option {opt.id} removed: the export's copy of a dish, replaced by the dish itself")
    for oid, wanted in bundled.options.items():
        held = stored.options.get(oid)
        if held is None or not wanted.linked_variant or held.linked_variant:
            continue
        if wanted.linked_variant not in stored.variants:
            continue
        item = stored.items[stored.variants[wanted.linked_variant].item]
        same_name = _norm(stored.localizer.text(held.names, "en")) == _norm(stored.localizer.text(item.names, "en"))
        stored.options[oid] = replace(
            held,
            linked_variant=wanted.linked_variant,
            names={} if same_name else held.names,
            kitchen_label=None if same_name else held.kitchen_label,
        )
        changed.append(f"option {oid} linked to {wanted.linked_variant}")
    return changed
