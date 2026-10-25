"""The spreadsheet round-trip for the sell layer."""

from __future__ import annotations

from decimal import Decimal as D

from openpyxl import load_workbook

from pos.menu import LineRequest, MenuEngine
from pos.menu.sheet import export_workbook, import_workbook


def test_export_then_import_reports_no_changes(defs, tmp_path):
    path = export_workbook(defs, tmp_path / "menu.xlsx")
    report, same = import_workbook(defs, path)
    assert report.ok and report.changes == [], report.changes
    assert same is defs


def test_a_price_change_is_reported_then_applied(defs, tmp_path):
    path = export_workbook(defs, tmp_path / "menu.xlsx")
    wb = load_workbook(path)
    sheet = wb["Variants"]
    for row in sheet.iter_rows(min_row=2):
        if row[0].value == "GTC:quart":
            row[5].value = "25.95"
    entries = wb["Menu entries"]
    for row in entries.iter_rows(min_row=2):
        if row[0].value == "lunch:L12":
            row[6].value = "GTC:lunch=11.50"
    wb.save(path)

    dry, unchanged = import_workbook(defs, path)
    assert dry.ok and sorted(dry.changes) == [
        "price GTC:quart: 24.95 -> 25.95",
        "price lunch:L12 GTC:lunch: 10.95 -> 11.50",
    ]
    assert unchanged is defs and dry.summary().startswith("2 prices changed, 0 new items")

    applied, new = import_workbook(defs, path, dry_run=False)
    assert applied.ok and new is not defs
    engine = MenuEngine(new)
    assert engine.resolve(LineRequest("GTC:quart", 1, "dinner:87")).unit_price == D("25.95")
    assert engine.resolve(LineRequest("GTC:lunch", 1, "lunch:L12")).unit_price == D("11.50")
    assert MenuEngine(defs).resolve(LineRequest("GTC:quart", 1, "dinner:87")).unit_price == D("24.95"), (
        "the originals are untouched"
    )


def test_errors_block_the_import(defs, tmp_path):
    path = export_workbook(defs, tmp_path / "menu.xlsx")
    wb = load_workbook(path)
    wb["Variants"].append(["NEW:x", "NOPE", "x", "Nothing", "", "-1", "1", "", "yes"])
    wb["Menu entries"].append(["dinner:dup", "dinner", "87", "dinner/chefs", "BB", "", "", "yes", "no"])
    wb.save(path)
    report, same = import_workbook(defs, path, dry_run=False)
    assert not report.ok and same is defs
    assert any("negative price" in e for e in report.errors) and any("duplicate number" in e for e in report.errors)
