"""Add what the bundled menu files have and a hub's database lacks: `python -m pos.menu.seed [--apply]`.

A hub seeds its menu from the bundled files (the GloriaFood export, `stations.json`, `bar.json`) once,
when its database is empty; from then on the database is the menu and the editor changes it. When the
files gain definitions later (a shelf of bottles, a modifier group), this adds the missing ones to the
stored menu and leaves every existing row as the editor has it: a price changed in the editor stays
changed. A price the files changed (`bar.json` carries the printed menu's beer prices) moves only while
the stored price is still the export's own. Without `--apply` it only lists what it would do. A row
deleted in the editor comes back if the files still carry it, so delete it from the files too. On a hub:
`hubctl menu import [--apply]`.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import replace

from . import admin
from .defs import Definitions
from .service import load_definitions


def missing(stored: Definitions, bundled: Definitions) -> tuple[Definitions, list[str]]:
    """`stored` plus every definition of `bundled` whose key it lacks, and what was added as "kind key"."""
    merged = admin.copy_of(stored)
    added: list[str] = []
    for kind in admin.KINDS.values():
        held = getattr(merged, kind.attr)
        wanted = getattr(bundled, kind.attr)
        if isinstance(held, dict):
            for key, obj in wanted.items():
                if key not in held:
                    held[key] = obj
                    added.append(f"{kind.name} {key}")
        else:
            have = {kind.key(obj) for obj in held}
            for obj in wanted:
                key = kind.key(obj)
                if key not in have:
                    held.append(obj)
                    have.add(key)
                    added.append(f"{kind.name} {key}")
    return merged, added


def reprice(merged: Definitions, bundled: Definitions, before: Definitions) -> list[str]:
    """Move each price in `merged` still at `before`'s value to `bundled`'s, in place; what moved, as text.

    `before` is the export alone, the prices a hub was seeded with before the files set any of their own;
    a price the editor changed since no longer equals it and stays."""
    updated: list[str] = []
    for variant_id, wanted in bundled.variants.items():
        held = merged.variants.get(variant_id)
        old = before.variants.get(variant_id)
        if held is None or old is None or held.base_price != old.base_price or wanted.base_price == old.base_price:
            continue
        merged.variants[variant_id] = replace(held, base_price=wanted.base_price)
        updated.append(f"variant {variant_id} price {old.base_price} -> {wanted.base_price}")
    return updated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m pos.menu.seed", description=__doc__.split("\n\n")[1])
    parser.add_argument("--apply", action="store_true", help="save the changes (without it, only list them)")
    parser.add_argument("--dsn", default=os.environ.get("DATABASE_URL"), help="PostgreSQL URL (default: DATABASE_URL)")
    parser.add_argument("--source", help="the bundled menu, as POS_MENU names it (default: POS_MENU, else gloriafood)")
    args = parser.parse_args(argv)
    if not args.dsn:
        parser.error("--dsn or DATABASE_URL is required")
    from .gloriafood import BUNDLED, STATIONS, load_gloriafood, settings_from
    from .store import MenuStore

    source = args.source if args.source is not None else os.environ.get("POS_MENU", "gloriafood")
    bundled = load_definitions(source)
    store = MenuStore(args.dsn)
    try:
        stored = store.load(bundled.localizer)
        merged, added = missing(stored, bundled)
        updated = []
        if source in ("", "gloriafood"):
            updated = reprice(merged, bundled, load_gloriafood(BUNDLED, settings_from(STATIONS))[0])
        if not added and not updated:
            print("nothing to add: the stored menu has everything the bundled menu has")
            return 0
        for line in added + updated:
            print(line)
        print(f"{len(added)} definitions to add, {len(updated)} prices to update")
        if not args.apply:
            print("dry run; add --apply to save them")
            return 0
        errors, _warnings = admin.problems(merged)
        if errors:
            for problem in errors:
                print(f"error: {problem.message}")
            print("nothing saved")
            return 1
        saved = store.save(merged, actor="import (pos.menu.seed)")
        print(f"saved: revision {saved.revision}, {saved.inserted} rows inserted, {saved.updated} updated")
        return 0
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
