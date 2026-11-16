# Tax-exempt checks

Some buyers pay no meals tax: a school, a church, a town office, each with a certificate of exemption. A
manager marks such a check exempt. The check keeps who it is for and the number of their certificate, no
sales tax is charged on it, and the reports say on how many checks, on how much, and how much tax that was.

Since 16 November 2026 (the Toast comparison, row 19). Hub and app; nothing to turn on.

Whether a buyer and a meal qualify is for the restaurant and its accountant to decide, under the state's
rules. The POS keeps the record: the organisation, the certificate's number, the manager who approved, who
marked it and when.

## Marking a check

On an open check: **Discount**, then **Tax exempt** under "Sales tax" at the foot of the sheet (it has a
lock, like a reason that needs a manager).

1. **Who it is for.** Type the **organisation** (60 letters at most) and the **certificate number** (40 at
   most), from their certificate of exemption. Neither can be left empty.
2. **Manager PIN.** A manager types their PIN on the spot, as for a comp. A server's PIN is refused.

The check then says **Tax exempt · Winchester PTA** where "Sales tax 7%" stood, with 0.00, and its total is
without the tax. Whatever is rung in afterwards is not taxed either, nor is a charge on the check (a
delivery fee). A table that splits its check owes no tax on any of them.

- **Mark it before any money is taken.** What was paid was paid with the tax in it, so a check with a
  payment on it is refused: "Money has been taken on this check. A check is marked exempt before it is paid."
- **Only an open check.** A closed check is reopened first.
- **It needs the hub or the cloud.** With nothing answering, the Discount button says so, as for a comp.
- **A device that takes audit photos** takes one of whoever is at the screen when the mark goes on.

## Taking it off

Tap the **Tax exempt** row on the check. It asks "Charge sales tax again?", and **Charge tax** puts the tax
back. Anyone with the check open may: it only ever adds tax, and the check's history keeps who did it.
Marking it exempt again needs a manager again. A closed check's row does nothing.

## What prints

**The bill** says, where it has "Sales tax 7%" on other checks:

```
Tax exempt                          0.00
  Winchester PTA
  Certificate E-123-456-789
```

Kitchen tickets are the same as for any check.

## In the reports

- **Every sale on a tax-exempt check is in Sales and The day**, in every figure: dishes sold, net sales,
  the total, by category, by kind of order, by person, by hour. Only the tax is not charged. "Sales tax" in
  both reports is the tax that was charged.
- **The day** (`day-report.md`): under "Sales tax", a line says "Not charged on 2 tax-exempt checks: $8.12".
  Lower down, a section **Tax exempt** has what those checks came to, the tax not charged, and each check:
  the organisation, which table or order, the certificate number and who approved. The printed day has the
  same block, `TAX EXEMPT`.
- **Sales** over any days (`sales-report.md`): the same line under "Sales tax", for the days shown.
- **A check's history** (`check-history.md`): "Marked tax exempt" with the organisation and the certificate,
  who marked it, at which screen, when, and "approved by" the manager, in red like a comp. "Put the sales
  tax back on" when it came off, with who did that.

## Good to know

- A buyer's exemption is per check: nothing remembers an organisation for next time, so the number is
  typed each time.
- The exemption stays with the check when it moves to another table or is handed to another server. Dishes
  moved onto another check are taxed as that check is.
- An app that is not rebuilt shows a tax-exempt check with "Sales tax 7%" and 0.00, and cannot mark one. A
  hub that is not updated leaves the tax on: update the hub first.

## Not built

- A list of organisations with their certificates on file, to pick from.
- A picture or scan of the certificate kept with the check.
- Exempting some dishes of a check and not others, or one of a split table's checks only.
- An expiry date on a certificate, and a warning when it has passed.
- Marking a check exempt after it was paid, with the tax handed back: payments are parked.

## For developers

- The mark is an order field, `tax_exempt` (`ORDER_FIELDS` in `pos/sync/oplog.py`), set by `set_field`, so
  a hub older than this ignores it. A terminal sends `{"tax_exempt": {"organisation", "certificate"},
  "approval": <token>, "by", "by_id"}`; `"tax_exempt": null` takes it off.
- `pos.orders.exempt.exempt_ops(tokens, store, ops)` runs in `append_ops` after `void_ops`. It checks the
  two words and their lengths, that the check is open and has no payment, and that `approval` is a token
  from `POST /approvals` with purpose `exempt` for this order and a role in `APPROVERS`. It then writes
  the mark itself: `{organisation, certificate, by, by_id, at_ms, approved_by: {staff_id, name}}`, with
  `approved_by` beside it on the operation for the history. A refused mark is left out and reported as
  `{"op_id", "error": "invalid_exemption", "problems": [{"code", "message"}]}` (`closed`, `no_organisation`,
  `no_certificate`, `bad_value`, `paid`, `needs_approval`, `bad_request`).
- `exemption_of(fields)` reads a mark, and only one with the hub's `approved_by.staff_id` counts, so
  nothing a terminal writes on its own takes the tax off.
- `check_for` (`pos/orders/check.py`) keeps the tax lines with their rates at 0.00, does not tax charges,
  and answers `tax_exempt: {organisation, certificate, approved_by, approved_by_id, by, at_ms, tax}`, where
  `tax` is what was not charged. `GET /orders/{id}/check` says `exempts: true`, so an app knows the hub can.
- Reports: `tax_exempt: {count, sales, tax}` in `GET /reports/sales` (per span) and in `GET /reports/day`,
  which adds `checks`. History steps `tax_exempt` and `tax_exempt_removed` (`pos/orders/history.py`).
- App: `TaxExempt`, `Check.exempt` and `Check.exempts` (`lib/menu.dart`); `DiscountSheet.taxExempt` and
  `DiscountSheet.exemptOp`; `TaxExemptDialog`; `_markExempt` and `_removeExempt` in the order screen;
  `TaxExempts` and `DayExempt` (`lib/day_report.dart`). `estimateCheck` charges no tax on an exempt check
  while a new dish waits for the hub's price.
- Tests: `backend/tests/orders/test_exempt.py`, `apps/pos_app/test/tax_exempt_test.dart`.
