"""Spreadsheet round-trip for the sell layer: items, variants and menu entries.

Export the catalog to a workbook, edit it, import with a dry run that reports the diff. Recipes
and modifiers join in phase 1; this is enough for the initial load from the current item list and
for a seasonal price change.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field, replace
from decimal import Decimal, InvalidOperation
from pathlib import Path

from openpyxl import Workbook, load_workbook

from .defs import Definitions, Entry, Item, Variant, money

ITEM_COLUMNS = (
    "code",
    "category",
    "name_en",
    "name_zh",
    "kitchen",
    "aliases",
    "tax_class",
    "station",
    "tags",
    "active",
)
VARIANT_COLUMNS = ("id", "item", "code", "name_en", "kitchen", "base_price", "recipe_scale", "plu", "active")
ENTRY_COLUMNS = ("id", "menu", "number", "section", "item", "variants", "price_overrides", "visible", "featured")


@dataclass
class ImportReport:
    changes: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def summary(self) -> str:
        prices = sum(1 for c in self.changes if c.startswith("price"))
        new = sum(1 for c in self.changes if c.startswith("new"))
        other = len(self.changes) - prices - new
        return f"{prices} prices changed, {new} new items, {other} other changes, {len(self.errors)} errors"


def _join(values) -> str:
    return ";".join(values or ())


def _split(text) -> tuple[str, ...]:
    return tuple(s.strip() for s in str(text or "").split(";") if s.strip())


def export_workbook(defs: Definitions, path: Path | str) -> Path:
    wb = Workbook()
    items = wb.active
    items.title = "Items"
    items.append(ITEM_COLUMNS)
    for item in sorted(defs.items.values(), key=lambda i: (i.sort, i.code)):
        items.append(
            [
                item.code,
                item.category,
                item.names.get("en", ""),
                item.names.get("zh", ""),
                item.names.get("kitchen", ""),
                _join(item.aliases),
                item.tax_class or "",
                item.station or "",
                _join(item.tags),
                "yes" if item.active else "no",
            ]
        )
    variants = wb.create_sheet("Variants")
    variants.append(VARIANT_COLUMNS)
    for v in sorted(defs.variants.values(), key=lambda v: (v.item, v.sort, v.code)):
        variants.append(
            [
                v.id,
                v.item,
                v.code,
                v.names.get("en", ""),
                v.names.get("kitchen", ""),
                str(money(v.base_price)),
                str(v.recipe_scale),
                v.plu or "",
                "yes" if v.active else "no",
            ]
        )
    entries = wb.create_sheet("Menu entries")
    entries.append(ENTRY_COLUMNS)
    for e in sorted(defs.entries, key=lambda e: (e.menu, e.sort, e.number or "")):
        overrides = ";".join(f"{vid}={money(price)}" for vid, price in sorted(e.price_overrides.items()))
        entries.append(
            [
                e.id,
                e.menu,
                e.number or "",
                e.section,
                e.item,
                _join(e.variants or ()),
                overrides,
                "yes" if e.visible else "no",
                "yes" if e.featured else "no",
            ]
        )
    path = Path(path)
    wb.save(path)
    return path


def _rows(sheet, columns):
    header = [str(c.value).strip() if c.value is not None else "" for c in sheet[1]]
    if tuple(header[: len(columns)]) != columns:
        raise ValueError(f"{sheet.title}: expected columns {columns}, found {tuple(header)}")
    for row in sheet.iter_rows(min_row=2, values_only=True):
        if row is None or all(v in (None, "") for v in row):
            continue
        yield dict(zip(columns, row, strict=False))


def _yes(value) -> bool:
    return str(value).strip().lower() in ("yes", "y", "true", "1")


def import_workbook(defs: Definitions, path: Path | str, dry_run: bool = True) -> tuple[ImportReport, Definitions]:
    """Compare a workbook with the definitions; apply it when dry_run is False. Returns the report and
    the definitions to use afterwards (the originals on a dry run or on any error)."""
    report = ImportReport()
    wb = load_workbook(Path(path), read_only=True, data_only=True)
    new = copy.copy(defs)
    new.items, new.variants, new.entries = dict(defs.items), dict(defs.variants), list(defs.entries)
    try:
        item_rows = list(_rows(wb["Items"], ITEM_COLUMNS))
        variant_rows = list(_rows(wb["Variants"], VARIANT_COLUMNS))
        entry_rows = list(_rows(wb["Menu entries"], ENTRY_COLUMNS))
    except (KeyError, ValueError) as err:
        report.errors.append(str(err))
        return report, defs

    for row in item_rows:
        code = str(row["code"]).strip()
        names = {k: v for k, v in (("en", row["name_en"]), ("zh", row["name_zh"]), ("kitchen", row["kitchen"])) if v}
        if row["category"] not in defs.categories:
            report.errors.append(f"item {code}: unknown category {row['category']}")
            continue
        current = defs.items.get(code)
        if current is None:
            report.changes.append(f"new item {code}")
            new.items[code] = Item(
                code,
                str(row["category"]),
                names,
                aliases=_split(row["aliases"]),
                tax_class=row["tax_class"] or None,
                station=row["station"] or None,
                tags=_split(row["tags"]),
                active=_yes(row["active"]),
            )
            continue
        updated = replace(
            current,
            names=names,
            aliases=_split(row["aliases"]),
            category=str(row["category"]),
            tax_class=row["tax_class"] or None,
            station=row["station"] or None,
            tags=_split(row["tags"]),
            active=_yes(row["active"]),
        )
        if updated != current:
            for attr in ("names", "aliases", "category", "tax_class", "station", "tags", "active"):
                if getattr(updated, attr) != getattr(current, attr):
                    report.changes.append(
                        f"item {code}: {attr} {getattr(current, attr)!r} -> {getattr(updated, attr)!r}"
                    )
            new.items[code] = updated

    for row in variant_rows:
        vid = str(row["id"]).strip()
        try:
            price = money(row["base_price"])
            scale = Decimal(str(row["recipe_scale"] or 1))
        except (InvalidOperation, ValueError):
            report.errors.append(f"variant {vid}: bad price or scale")
            continue
        if price < 0:
            report.errors.append(f"variant {vid}: negative price")
            continue
        names = {k: v for k, v in (("en", row["name_en"]), ("kitchen", row["kitchen"])) if v}
        current = defs.variants.get(vid)
        if current is None:
            if str(row["item"]) not in new.items:
                report.errors.append(f"variant {vid}: unknown item {row['item']}")
                continue
            report.changes.append(f"new variant {vid} at {price}")
            new.variants[vid] = Variant(
                vid,
                str(row["item"]),
                str(row["code"]),
                names,
                price,
                scale,
                plu=row["plu"] or None,
                active=_yes(row["active"]),
            )
            continue
        if money(current.base_price) != price:
            report.changes.append(f"price {vid}: {money(current.base_price)} -> {price}")
        updated = replace(
            current,
            names=names,
            base_price=price,
            recipe_scale=scale,
            plu=row["plu"] or None,
            active=_yes(row["active"]),
        )
        if updated != current:
            for attr in ("names", "recipe_scale", "plu", "active"):
                if getattr(updated, attr) != getattr(current, attr):
                    report.changes.append(
                        f"variant {vid}: {attr} {getattr(current, attr)!r} -> {getattr(updated, attr)!r}"
                    )
            new.variants[vid] = updated

    seen_numbers: set[tuple[str, str]] = set()
    entries: list[Entry] = []
    for row in entry_rows:
        eid = str(row["id"]).strip()
        number = str(row["number"]).strip() or None
        if number and (row["menu"], number) in seen_numbers:
            report.errors.append(f"entry {eid}: duplicate number {number} on {row['menu']}")
            continue
        if number:
            seen_numbers.add((row["menu"], number))
        overrides = {}
        for pair in _split(row["price_overrides"]):
            vid, _, price = pair.partition("=")
            try:
                overrides[vid.strip()] = money(price)
            except (InvalidOperation, ValueError):
                report.errors.append(f"entry {eid}: bad override {pair!r}")
        if row["item"] not in new.items or row["menu"] not in defs.menus or row["section"] not in defs.sections:
            report.errors.append(f"entry {eid}: unknown item, menu or section")
            continue
        variants = _split(row["variants"]) or None
        current = defs.entry(eid)
        updated = Entry(
            eid,
            str(row["menu"]),
            str(row["section"]),
            str(row["item"]),
            number,
            variants,
            overrides,
            visible=_yes(row["visible"]),
            featured=_yes(row["featured"]),
            sort=current.sort if current else 0,
        )
        if current is None:
            report.changes.append(f"new entry {eid}")
        else:
            for attr in ("number", "section", "item", "variants", "visible", "featured"):
                if getattr(updated, attr) != getattr(current, attr):
                    report.changes.append(
                        f"entry {eid}: {attr} {getattr(current, attr)!r} -> {getattr(updated, attr)!r}"
                    )
            for vid in set(current.price_overrides) | set(overrides):
                before, after = current.price_overrides.get(vid), overrides.get(vid)
                if (before is None) != (after is None) or (before is not None and money(before) != after):
                    report.changes.append(f"price {eid} {vid}: {before} -> {after}")
        entries.append(updated)
    for current in defs.entries:
        if not any(e.id == current.id for e in entries):
            report.changes.append(f"removed entry {current.id}")
    new.entries = entries
    if dry_run or report.errors:
        return report, defs
    return report, new
