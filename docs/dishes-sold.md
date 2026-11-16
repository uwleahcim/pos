# Dishes sold, best to worst

Every dish and how it sold over a week, a month, or any days you pick: how many, for how much, and beside
it the same days whole weeks earlier. Best first or worst first, by how many or by the money. Under a dish:
the sizes it went out in and every choice made on it, with how many times. It is for a manager, and it only
reads.

Since 16 November 2026 (the Toast comparison, row 9, second step). Sales (`sales-report.md`) says what the
days came to; this says what was sold in them.

## Opening it

Either way:

- Orders screen › **Location** (manager PIN) › **Dishes sold**, under Sales.
- From **Sales**, under By category: **Each dish of these days, best to worst**. It opens on the days Sales
  was reading.

The days are picked as in Sales: **7 days** (what it opens on from Location: the seven whole days just gone),
**4 weeks**, **Today**, **Yesterday**, and **Other days** for a calendar, one day or up to 92. A day is a day
of service, from 4 AM to 4 AM. The round arrow at the top reads the same days again.

## The list

At the top: how many dishes were sold and what they were sold for, each with the days before.

Then every dish, one line each, numbered from the top:

- its name, **how many** were sold and **what they were sold for**;
- under the name, its category and the figure of the days before ("41 before"), with "up 12%" in green or
  "down 30%" in red;
- a bar, as long as the dish stands against the best one in the list.

What stands above the list changes it:

| Control | What it does |
| --- | --- |
| **How many / Money** | ranks by the number sold, or by the money they were sold for |
| **Worst first** | turns the list over: what sold least is at the top |
| **All dishes** | opens the categories, each with what its dishes came to; tap one to see only its dishes |
| **Find a dish** | type any words of the name, in any order |

**Every dish the menu shows is in the list, sold or not.** So Worst first begins with what nobody ordered
in those days, and the line over the list says how many there are ("3 on the menu sold none").

## Under a dish

A dish with an arrow opens with a tap:

- **Sizes**, where the dish has more than one (Pint, Quart): how many of each and for how much. They add up
  to the dish.
- **As it was typed**, for an off-menu dish such as Open Food: each name that was typed for it, with how
  many and for how much.
- **Each group of choices** (Choice of rice, Spice level, Add-ons), in the order the dish asks them, the most
  picked first: how many times each choice went out, and what it added where it costs something. A choice
  of a choice is under the choice it belongs to ("Hot and Sour Soup · Spice level").

Each of them has the days before beside it as well. For a size, up is green and down is red, as for the
dish. For a choice the change is in plain letters: more Mild is not better than more Medium, it is only how
the dish went out.

## Good to know

- What a dish was sold for has its options in the price, and is **before comps and discounts**. All the
  dishes together are the "Dishes sold" of Sales, and the dishes of a category are that category's figure
  in Sales. The two screens can never disagree: both are added up from the same checks.
- An option counts what the dish **comes with** as well as what was picked: white rice that nobody changed
  is counted as white rice. Together the choices of a group say how the dish went out. Two egg rolls on
  each of three platters are six.
- An option's money is **part of the dish's**, not on top of it.
- A dish chosen inside another (the soup of a lunch special, a roll of a combination) is counted under that
  dish, as one of its choices. Its own line counts only the ones rung by themselves.
- A dish voided or taken off is not counted, nor a check voided whole. A dish that was comped is counted: it
  was sold and then taken off the bill, which is in Sales under Comps and discounts.
- A check counts on the day it was opened, or on the day it is for when that is later: the rules of Sales
  and of The day.
- A dish is one line however many menus it is on, under the first menu it stands on today.
- Everything is called what the menu calls it today. A dish the menu no longer has keeps the name it was
  sold under and stands under **Off the menu now**; with Worst first those come after the dishes the menu
  still shows.
- Every sale is in these figures. Nothing can be left out of them or switched off.
- The first reading of many days takes the hub some seconds; after that it is quick until the hub is
  restarted, as in Sales.

## Not built

- What a dish costs to make, and so what it earns. The POS knows prices, not costs.
- Printing the list, or sending it by e-mail.
- Dishes by who rang them in, or by the hour.
- Holding the days beside the same days a year before.

## For developers

- Figures: `backend/src/pos/orders/dishes.py`, `dishes_report(sales, span, before, defs=, now_ms=)`. It reads
  the same `Sale` of each order as the sales report (`pos/orders/sales.py`), whose lines (`Sold`) now carry
  the variant, the name as sold, the size, the name typed and every choice (`Picked`: group, option, word,
  qty, label, price, depth). `SaleMemo` shares one copy of each `Picked` between the orders it remembers.
- A dish is keyed by its item code while `Definitions.items` has it, else by `("gone", code or name)`. An
  option is keyed by its path of `(group, option, word)` from the top choice down; its count is its qty
  times the qty of the choices above it times the line's.
- Wire (`backend/src/pos/api/sales.py`): `GET /reports/dishes?from=YYYY-MM-DD&to=YYYY-MM-DD` with a manager's
  token answers `{span, before, dishes, categories, max_days, now_ms}`; the days, the limits and the errors
  are those of `/reports/sales`. `dishes` is most sold first; the app sorts it again as asked.
- App: `lib/dishes_report.dart` (`DishesReport`, `DishSold`, `SoldRow`, `DishSort`, `sortedDishes`,
  `dishesNamed`), `lib/screens/dishes_screen.dart` (`DishesScreen`), `PosApi.dishesReport` (which waits 90
  seconds). What it shares with Sales is in `lib/screens/span_report.dart`: the day chips, the heading, the
  calendar and `ReportLine`.
- Tests: `backend/tests/orders/test_dishes.py`, `apps/pos_app/test/dishes_report_test.dart`.
