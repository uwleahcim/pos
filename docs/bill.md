# The guest's bill

Every check has a **Bill** button beside its total, at the foot of the check. A tap prints the bill: the
check as the hub reckons it at that moment, to the cent, so the paper says what the screen says. Anything
just rung in goes to the hub first, so the last dish is on the paper too. A message at the foot of the
screen says which printer it is coming out of.

The bill reads, from the top:

- **The restaurant's own lines**: its name (big), then address, phone or whatever the manager typed.
- **The table and the time**: "Table 12  4 guests" with the time, the server's name with the date. A to-go
  order is headed with its number and the customer's name ("Order #42  Linda") and how it came in.
- **Each dish** with its quantity and what it comes to. Its choices stand under it, each with what it adds
  ("Brown rice +1.00"); a comp or a discount on the dish is said under it too ("Manager comp -48.00").
- **Subtotal**, then every discount and charge by name, then **sales tax as one line** ("Sales tax 7%").
- **TOTAL**, twice the size of the rest.
- **What was paid** ("Paid cash -20.00", with what was handed over and the change when that was typed)
  and **DUE**, or **PAID IN FULL**. A check nobody has paid on says nothing about paying.
- **The closing lines** the manager typed ("Thank you!").

Only the right-hand column adds up. A choice's own price and a comp on a dish are words under the dish,
because the dish's amount already holds its choices and the comp comes off under the subtotal, where the
screen takes it off too. So nobody reading the paper counts anything twice.

A table that pays on several checks gets a bill for each: see [split.md](split.md).

A check with nothing on it has no Bill button. A closed check still has one: the paper then says PAID IN
FULL and serves as the guest's copy.

## Where a bill prints

In this order:

1. **The printer the screen keeps for its bills.** Hold the Bill button: a sheet lists the printers by the
   names on their tickets. Pick one and this bill prints there, and the screen keeps it for its next bills
   (the bar's screen prints at the bar, the host stand's at the front). The first choice on the sheet, "The
   location's", gives the screen back to the location's printer. This is kept on the device, like its name.
2. **The location's printer for bills**, set under Location settings (below).
3. **The takeout station's printer**: the counter, where people pay.
4. **The first printer** on the list.

A printer that is no longer there is passed over, so a bill is never refused because of an old choice. When
the printer does not answer, the bill goes to its fallbacks like any ticket, and that copy starts with a
black strip saying whose printer is down, to be torn off before it goes to the table.

## Setting it up

**Location settings › The bill** (managers; on the Printers card):

- **Bills print at**: a printer, or the usual one (the takeout printer, else the first).
- **Top of the bill**: one line each; the first prints big. Until anything is typed, the bill is headed
  with the hub's `POS_LOCATION` when that is set, and with nothing otherwise. An empty line between two
  others is a gap on the paper.
- **Foot of the bill**: "Thank you!" to start with.
- **Print a sample** prints a made-up bill under the lines as typed, at the printer chosen, before anything
  is saved.

Up to 8 lines each, 64 characters a line; a line longer than the paper is wide goes on over the next.

## Not in this yet

- A logo, and the size of the type.
- A tip line or suggested tips (payments are parked).
- Dishes grouped by seat on the bill of a table that pays on one check.
- A record in the order's log that a bill was printed, and by whom.
- Printing a bill from the floor map without opening the check.

## For developers

- `backend/src/pos/printing/bill.py`: `Bill` and `BillLine` (data, like a `Ticket`), `bill_for(check, fields,
  head=, foot=, at=)` from `check_for`'s answer and the order's fields, `render_bill` for ESC/POS or
  StarPRNT, and `SAMPLE`.
- `PrintService.bill_printer(asked, location=True)` picks the printer; `queue` and `_rendered` take a
  `Bill` as they take a `Ticket` (fallback copies get `reprinted_from`). No buzzer on a bill.
- The builders: `Builder.columns(left, right, bold=, big=, hang=)` keeps `right` at the edge, wraps a long
  `left` onto the next lines and draws the line when it is not plain ASCII (`image_columns`, which a Star
  uses for every line). `image_line` now wraps a drawn line that is wider than the paper instead of
  cutting it off at the edge (`fit`), which also holds for kitchen tickets on a Star; `_split` no longer
  cuts at a line's own indent.
- The setting `bill` (`pos/settings.py`, `clean_bill`): `{printer, header, footer}`.
  `GET /settings/bill` adds `printers` (`{id, name}`), `prints_at` and `usual`; `PUT /settings/bill`
  (manager) takes any of the three and leaves the rest. `POST /orders/{id}/bill` (`{printer?, check?}`) answers 202
  with the job, `bills` (how many went: one for each check of a split table), `jobs` and `printed_at`
  (`{id, name}`), 404 for no such order, 409 `nothing_on_check`, `no_such_check` or `no_printer`. `POST /print/bill-sample` (manager) prints `SAMPLE` under the lines sent.
- The app: `BillSettings` in `lib/printers.dart`, `billSettings`, `saveBillSettings`, `printBill`,
  `printBillSample` in `lib/api.dart`, `Settings.billPrinter` (the screen's own printer),
  `screens/bill_dialog.dart`, the `_BillButton` on the total's row in `screens/order_screen.dart`.
- Tests: `backend/tests/printing/test_bill.py`, `apps/pos_app/test/bill_test.dart`.
