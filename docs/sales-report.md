# Sales over any days

How a week went, a month, or any days you pick, with every figure beside the same days whole weeks earlier:
net sales, checks, guests, the average check and guest, how long a table stood, and the sales by day, by
hour, by category and by kind of order. It is for a manager, and it only reads.

Since 16 November 2026 (the Toast comparison, row 9, first step). The day's report (`day-report.md`) is one
day read closely, with what is still open and what came off; this is the longer look.

## Opening it

Orders screen › **Location** (manager PIN) › **Sales**, under The day.

- **7 days** is what it opens on: the seven whole days just gone, ending yesterday.
- **4 weeks** is the twenty-eight whole days just gone.
- **Today** is the day that is running, and **Yesterday** the one before.
- **Other days** opens a calendar: tap the first day and the last. One day, or up to 92.

The round arrow at the top reads the same days again.

A day is a day of service: **from 4 AM to 4 AM**, the restaurant's own time. "7 days" and "4 weeks" leave
today out on purpose, so that a day half over is not held beside whole ones.

## What it is held beside

The same number of days, **whole weeks earlier**, so that a Friday always stands beside a Friday:

| You read | It stands beside |
| --- | --- |
| one day | the same weekday a week before |
| 7 days | the 7 days before them |
| 4 weeks | the 4 weeks before them |
| 10 days | the same 10 days two weeks before |

The second line of the screen names those days. Under each figure is the figure of those days ("$12,410.00
before") and how far apart the two are ("up 12%", "down 2%", "the same"). Where there was nothing before,
it says "nothing before". Up is green and down is red where more is better (sales, checks, guests, the
averages); a table's time, the hours worked, the money by how it was paid and the comps are in plain
letters, because more of those is not simply better.

## What it shows

**The headline figures:**

| Figure | What it is |
| --- | --- |
| Net sales | every dish sold at the price it was sold at, less comps and discounts |
| Checks | how many checks, not counting a check voided whole |
| Guests | the guests the checks say they had |
| Average check | net sales over the checks |
| Average per guest | the net sales of the checks that say their guests, over those guests; a to-go order says none and is left out |
| A table, opened to closed | how long a table's check stood, for the tables closed: the middle one of them, so that half stood longer and half not as long. One table forgotten open overnight does not move it |
| Hours worked | where the time clock is used: the hours of the shifts that began in those days |
| Net sales per hour worked | net sales over those hours |

**Sales:** dishes sold, comps and discounts, net sales, charges, gratuity, the sales tax as one line, and
the total, exactly as in The day. When checks of those days were marked tax exempt, a line under the sales
tax says on how many and how much tax was not charged (`tax-exempt.md`).

**By day** (for more than one day): the net sales of each day as a bar, with the same day of the weeks
before as a thin bar and a small figure under it.

**By hour:** the dishes sold by the hour of the day they were rung in, every day of the span added up, in
the order a night runs (4 AM round to 3 AM), again with the days before as the thin bar.

**By category** under each menu, and **by kind of order** (tables, bar tabs that never sat down, to go,
delivery; `bar-tabs.md`), each with the days before. Under the categories, **Each dish of these days, best to worst** opens the list of dishes sold for
the same days (`dishes-sold.md`).

**Money taken:** every payment recorded in those days, by how it was paid, whatever check it was for. What
the restaurant's website took for its orders is a row of its own, **Paid online**, as in The day
([day-report.md](day-report.md)).

**Comps and discounts:** each kind, how many times and how much.

## For the accountant

Since 18 November 2026 (the Toast comparison, row 29, first step). Under the total of **Sales** is a row,
**Copy each day for the accountant**. A tap copies the days the screen shows as a table: one line for each
day, and a line of totals under them. Then:

1. Open a spreadsheet (Numbers, Excel, Google Sheets) and **paste**. Each figure lands in a cell of its own,
   with the names of the columns in the first line.
2. Save it and send it to whoever keeps the books.

For a month, pick it under **Other days** first (the 1st to the last day), then copy. The row says what it
did: "Copied 30 days and the totals." When today is one of the days it says so, because today's line is not
finished.

| Column | What it is |
| --- | --- |
| Day | the day of service, written 2026-11-16 so that a spreadsheet reads it as a date |
| Checks, Guests | as on the screen |
| one column for each menu | the dishes sold on that menu (Food, Lunch, Drinks). Dishes that have left the menu since are under "Off the menu now". Together they are Dishes sold. A location with one menu has no such columns |
| Dishes sold | every dish at the price it was sold at |
| Comps and discounts | what came off, written without a minus sign |
| Net sales | Dishes sold less Comps and discounts |
| Charges, Gratuity | as on the screen |
| Sales tax | the tax charged, as one figure |
| Total | Net sales + Charges + Gratuity + Sales tax |
| Tax-exempt checks, Tax-exempt sales, Tax not charged | the checks a manager marked tax exempt: how many, what they came to, and the tax that was left off. Their sales are in every column before |
| Voids after sending, and its amount | dishes voided after the kitchen had them, on the day they were voided |
| Checks voided whole, and its amount | checks voided whole. They are no sale and are in no other column |
| Cash, Card, Paid online, Paid elsewhere | the money taken that day, by how it was paid. Paid online is what the restaurant's website took for its orders; the column is on every sheet, zeroes where there was none |
| Money taken | all of it together |

- Every day of the span has its line, a day with nothing sold too (a line of zeroes), so a month is always
  as many lines as it has days.
- **Every sale and every payment of those days is in the table.** There is no way to leave any out.
- A line says what **The day** says for that day, and the line of totals what this screen says for the
  days. They are the same figures, added up by the hub from the same checks.
- Amounts are plain figures (1234.56, no $ and no comma), so the spreadsheet can add them.
- The money counts on the day it was taken and a sale on the day of its check, so on a day when a check was
  paid later, or an order was paid ahead, Money taken and Total differ. That is how The day reads too.
- It needs the same manager PIN as the rest of Location, and whoever may see the reports
  (`roles.md`) may copy it.
- The table is copied, not saved: nothing is written on the device or on the hub, and nothing is sent
  anywhere. It goes where you paste it. It stays on that device's clipboard until something else is copied,
  so copy it on a device that is yours (the office Mac, your phone) rather than on a terminal in the dining
  room.

## Good to know

- A check counts on the day it was opened, or on the day it is for when that is later (a catering order rung
  on Tuesday for Saturday is Saturday's sale). A payment counts on the day it was taken. Both are the rules
  of The day: one day read here says the same sales as The day does.
- Every sale and every payment is in these figures. Nothing can be left out of them or switched off.
- Nothing is closed and nothing is written down: the figures are added up from the checks each time. A void
  or a payment made afterwards is in the next reading.
- The first reading of many days takes the hub some seconds (four weeks beside four weeks is several
  thousand checks). After that it is quick, until the hub is restarted: the hub remembers what each check
  came to for as long as nobody touches it.
- A shift nobody clocked out of counts until 4 AM, so the hours worked are too many until a manager
  corrects it under Hours. The screen says when there is one.
- Categories and discounts are called by the names they have today.

## Not built

- Labour cost against sales. The POS knows the hours worked but not what anyone is paid, so it shows net
  sales for each hour worked instead.
- Sales by who rang them in over many days (The day has it for one day).
- Printing it, or sending it by e-mail. E-mail needs a mail service outside the restaurant, which is the
  owner's choice to set up.
- Saving the accountant's table as a file (a .csv to attach), or handing it to Mail or AirDrop from the
  app: today it is copied and pasted. A file made by itself every night.
- A column for taxable sales in the accountant's table. Total less Sales tax less Tax-exempt sales is close
  to it; whether a gratuity or a charge is taxed is the accountant's to say.
- The comps by kind, the sales by category and the hours worked in that table. The screen has them.
- Holding the days beside the same days a year before.

## For developers

- Figures: `backend/src/pos/orders/sales.py`. `sale_of(state, taxes, rules)` is what one order comes to
  (`Sale`: its day by `order_day`, its payments, the figures of `check_for`, and its dishes added up by
  dish, menu entry, hour, size and the choices made, which is what `dishes-sold.md` reads).
  `sales_reports(sales, spans, defs=, now_ms=)` adds any spans up in one pass; `comparison(first, last)`
  names the days to hold beside a span; `MAX_DAYS` is 92. `sales_report` reckons one span straight from
  order states, for a test or a script.
- `SaleMemo` keeps each order's `Sale` in memory under the index's `version` and `tip` of its log, so only
  the orders that changed are replayed again. It is dropped whole when the taxes or the rules are other
  objects, and holds 40,000 orders at most. It can never make a reading differ from one reckoned afresh:
  `test_a_check_is_replayed_again_only_when_it_changed_and_reads_the_same_either_way` holds it to that.
- `OrderState.closed_at` (`pos/sync/oplog.py`) is the stamp of the close that closed an open check, for
  the time a table stood.
- The accountant's table: `day_sheet(sales, first, last, defs=, now_ms=)` in the same module, from the same
  `Sale`s (`_Span.sheet`). A `Sale` keeps each void of a sent dish (`voids`: when, how much) and, for a
  check voided whole, what its dishes came to (`voided`); `_Span` adds each day up with its tax, charges,
  gratuity, exempt checks, voids, the money by how it was paid and the dishes by menu. `GET
  /reports/sales/sheet?from=&to=` (the `reports` power) answers `{first, last, running, columns, rows,
  total, max_days, now_ms}`, every cell a string. The hub decides the columns; the app only joins the
  cells with tabs (`SalesSheet.text`) and puts them on the clipboard (`SalesScreen._copy`,
  `PosApi.salesSheet`). `PAID_AS` (the names of the ways to pay) moved to `pos/orders/day.py`, where the
  paper of The day reads it too. Tests: the eight about the sheet in `test_sales.py`, which hold each line to The day's
  report and the totals to the sales, and `apps/pos_app/test/sales_sheet_test.dart`.
- Wire (`backend/src/pos/api/sales.py`): `GET /reports/sales?from=YYYY-MM-DD&to=YYYY-MM-DD` with a
  manager's token answers `{span, before, max_days, now_ms}`; neither day is the running one, one of them
  is that one day; 422 `bad_value` or `too_long`. Each of the two carries `clock` (`worked_ms`, `people`,
  `unended`, `net_per_hour`), null where the location does not use the time clock.
- App: `lib/sales_report.dart` (`SalesReport`, `SalesSpan`, `changeWords`, `spanOf`),
  `lib/screens/sales_screen.dart` (`SalesScreen`), its row in `lib/screens/location_settings_screen.dart`,
  `PosApi.salesReport` (which waits 90 seconds, not 2). The day chips, the heading, the calendar and the
  rows (`ReportLine`) are in `lib/screens/span_report.dart`, shared with Dishes sold.
- Tests: `backend/tests/orders/test_sales.py`, `apps/pos_app/test/sales_report_test.dart`.
