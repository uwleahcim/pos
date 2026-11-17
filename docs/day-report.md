# The day's report

What a manager reads when service is over: what is still open, what the day sold, the money that was taken
for it, and what came off the checks. It is on the screen for any day and prints where the bills print.

Since 16 November 2026 (the Toast comparison, row 6). It counts no cash drawer: see "Not built".
For more than one day at a time, held beside the days before, see `sales-report.md`; for each dish and how
it sold, `dishes-sold.md`.

## Opening it

Orders screen › **Location** (manager PIN) › **The day**, the third row from the top, under Today.

- **Today** is the day that is running. **Yesterday** and **Another day** (a calendar) read any other.
- The **printer** button at the top puts the same figures on paper where the location's bills print, or at
  the printer this screen keeps for its own bills. The round arrow reads the day again.

A day is a day of service: **from 4 AM to 4 AM**, the restaurant's own time. A check opened at half past
midnight belongs to the evening before.

## What it shows

**Still open** comes first, because it is what has to be dealt with before going home:

- the checks of the day that are still open, each with what it owes and any dish on it that was never sent
  to the kitchen;
- checks that were closed without being paid in full;
- for the running day, checks from earlier days that are still open;
- where the time clock is used, who is still on the clock, and shifts nobody clocked out of.

When there is nothing, it says so with a green tick. A tap on a check opens its whole history, step by
step (see `check-history.md`).

**Sales**, the day's checks added up:

| Line | What it is |
| --- | --- |
| Dishes sold | every dish on the day's checks at the price it was sold at |
| Comps and discounts | what was taken off, shown with a minus |
| Net sales | dishes sold less comps and discounts |
| Charges | service charges that are the restaurant's (only when there were any) |
| Gratuity | charges paid over to staff (only when there were any) |
| Sales tax | one line, as a guest sees it: the tax that was charged. Under it, how much was not charged on tax-exempt checks, when there were any |
| Total | what the day's checks come to |

**Money taken** is every payment recorded during the day, by how it was paid: cash, card, and paid
elsewhere (a phone order settled through another system). It counts a payment on the day it was taken,
whatever check it was for, so it is what should be in the drawer and on the card slips that night. When
some of it was for a check of another day (a deposit on Saturday's catering, last night's tab), a line says
how much.

Under it, **The day's checks** settles them: what they come to, what was paid this day, what was paid on
other days, and what is **still owed**.

Then the dishes sold, split four ways. Each list adds up to the "Dishes sold" figure:

- **By category**, under each menu when there are several (Food, Drinks), with how many dishes;
- **By kind of order**: tables, bar tabs that never sat down (`bar-tabs.md`) and to-go, with the checks
  and guests;
- **Rung in by**: who rang the dishes in;
- **By hour**, by the hour each dish was rung in.

**Came off the checks**: each comp and discount by its reason, the dishes voided after the kitchen had them,
the dishes taken off before sending, and checks voided whole. "Each one, with who and why" opens the Voids
and comps report.

**Tax exempt** (only when there were any): what the checks a manager marked exempt from sales tax came to,
the tax that was not charged, and each check with the organisation, its certificate number and who approved
(`tax-exempt.md`). Their sales are in every figure above.

**Also**: dishes sold at a typed price, orders rung during the day for a later one, and the hours worked
(a tap opens the Hours).

## How a day is counted

- **A check counts on the day it was opened.** An order rung for a later day (a catering order taken on
  Tuesday for Saturday) counts on the day it is for, also when it was paid and closed on the Tuesday. During
  the day it was rung it shows under "Rung for another day" and is in no total.
- **A payment counts on the day it was taken.** So a deposit is in that day's money and in the other day's
  sales, and the lines "for checks of other days" and "paid on other days" join the two.
- **A void counts on the day it happened**, whatever check it was on.
- **A check voided whole is no sale.** It is counted under "Came off". Money taken on it before it was
  voided stays in the money taken, on a red line of its own, until somebody sees that it went back.
- **Every sale and every payment is in it**, cash like any other. Nothing here can be left out or switched
  off.
- **Nothing is stored and no day is closed.** The report is added up from the checks each time it is asked,
  so a payment or a void made afterwards is in the next reading, and a day reads the same a month later.
- A dish that has left the menu since is listed under "Off the menu now": its sale stays a sale.

## Good to know

- Categories and menus are named as the menu stands today, so a category renamed last week reads by its
  new name for older days too.
- "Rung in by" goes by who rang each dish, not by whose table it was.
- Money is counted as it was recorded on the check. Card payments are typed in, not charged by the POS, so
  the card total is what staff recorded.
- The report needs the hub.

## Not built

- **Counting the cash drawer**, so no "over or short": count the drawer against the Cash line by hand.
  Payments at the table are parked, and the drawer count belongs with them.
- Averages (per check, per guest) and a comparison with last week: Today (`today.md`) has both for the
  running day, and Sales (`sales-report.md`) for any days. The cost of the hours worked.
- A file for the bookkeeper, and a report sent by e-mail.
- Tips, since none are recorded yet.

## On paper

```
                    THE DAY
           Monday, November 16, 2026
             Printed 9:41 PM by Mike
            The day is still running
------------------------------------------------
SALES
Dishes sold                                58.60
Comps and discounts                        -2.00
Net sales                                  56.60
Sales tax                                   3.96
TOTAL                                      60.56
4 checks, 8 guests
------------------------------------------------
MONEY TAKEN
Cash (2)                                   25.00
Card (2)                                    8.84
Paid elsewhere (1)                         18.14
TAKEN THIS DAY                             51.98
  of it for checks of other days           11.96
------------------------------------------------
THE DAY'S CHECKS
Come to                                    60.56
Paid this day                              40.02
STILL OWED                                 20.54
------------------------------------------------
BY CATEGORY
Appetizers (5)                             36.15
...
------------------------------------------------
STILL OPEN
1 check still open                          3.47
1 closed check not paid in full            17.07
2 dishes not sent to the kitchen
```

The first line of the bill's own heading, when the location has one, prints above "THE DAY".

## For developers

- Figures: `backend/src/pos/orders/day.py`. `order_day(state)` says which day a check counts on;
  `day_report(states, day, taxes=, rules=, defs=, now_ms=)` adds everything up from `check_for`, the void,
  taken-off and typed rows and each order's payments. Its docstring states the sums that have to hold:
  `menus`, `categories`, `kinds`, `staff` and `hours` each add up to `sales.gross`; `sales.total` = net +
  charges + gratuity + tax = `money.paid_this_day` + `paid_other_days` + `due` - `over`.
- Wire (`backend/src/pos/api/day.py`): `GET /reports/day?day=YYYY-MM-DD` and `POST /reports/day/print`
  `{day, printer}`, both with a manager's token; no `day` is the running one (`localtime.service_day_of`).
  The orders read are those opened before the day ended and changed since it began, those promised for the
  day (the orders index keeps each order's `promised_ms` for this: `index(promised=(since, until))`), and
  every open order.
  `clock` is the time clock's part, null where the location does not use it.
- Paper: `backend/src/pos/printing/day.py` (`DayPaper`, `day_paper`, `render_day`); `PrintService.queue`
  takes it like a bill.
- App: `lib/day_report.dart` (`DayReport`, `dollars`, `serviceDay`), `lib/screens/day_report_screen.dart`
  (`DayReportScreen`), its row in `lib/screens/location_settings_screen.dart`, `PosApi.dayReport` and
  `printDay`.
- Tests: `backend/tests/orders/test_day.py`, `apps/pos_app/test/day_report_test.dart`.
