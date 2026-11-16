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

**Money taken:** every payment recorded in those days, by how it was paid, whatever check it was for.

**Comps and discounts:** each kind, how many times and how much.

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
- Printing it, or sending it by e-mail.
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
- Wire (`backend/src/pos/api/sales.py`): `GET /reports/sales?from=YYYY-MM-DD&to=YYYY-MM-DD` with a
  manager's token answers `{span, before, max_days, now_ms}`; neither day is the running one, one of them
  is that one day; 422 `bad_value` or `too_long`. Each of the two carries `clock` (`worked_ms`, `people`,
  `unended`, `net_per_hour`), null where the location does not use the time clock.
- App: `lib/sales_report.dart` (`SalesReport`, `SalesSpan`, `changeWords`, `spanOf`),
  `lib/screens/sales_screen.dart` (`SalesScreen`), its row in `lib/screens/location_settings_screen.dart`,
  `PosApi.salesReport` (which waits 90 seconds, not 2). The day chips, the heading, the calendar and the
  rows (`ReportLine`) are in `lib/screens/span_report.dart`, shared with Dishes sold.
- Tests: `backend/tests/orders/test_sales.py`, `apps/pos_app/test/sales_report_test.dart`.
