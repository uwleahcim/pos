# Today

The night as it stands, on one screen made for a phone: what was sold so far and whether that is ahead of
or behind the same day last week at this time, the checks still open, what came off, who is on the clock,
what is sold out, the kitchen's quote, and the night hour by hour. It reads again by itself.

Since 17 November 2026 (the Toast comparison, row 10: the owner's phone view). It is a screen of the same
app, so it works on any phone, tablet or Mac the POS runs on. Where it works from is under "Where it
reaches".

## Opening it

- Orders screen › menu › **Today**, then the PIN of somebody who may see the reports.
- Or Orders screen › **Location** › **Today**, the row above The day, with the PIN already typed there.

Who may see the reports is a manager and an owner to start with, and anyone else the location handed
**See the reports** under Who may do what (`roles.md`). Nobody else has Today in their menu.

The PIN is good for an hour, like every manager PIN. When the hour is over the figures stay on the screen,
a strip at the top says how old they are, and **Type a PIN** reads on.

## What it shows

On a phone the cards stand under each other in this order; on a tablet in two columns.

**Net sales so far**, in large figures: today's dishes less comps and discounts, as The day reckons them.
Under it the checks, the guests and the net sales for each check.

Then **the pace**, the line the screen is for: "13.6% ahead of last Monday at this time", in green, or
"behind", in red. It holds two figures side by side that are the same measure:

- the dishes rung in today up to this minute, and
- the dishes that had been rung in by the same time of day on the same weekday a week ago.

Both are what the dishes sell for, before comps, discounts and tax, because that is the only figure that
can be said for a moment gone by: a dish keeps the time it was rung in, and a discount belongs to the whole
check. The line under it names both figures. "Level" when they are the same; "Nothing had been rung in by
this time last Monday" when there is nothing to hold it against.

Under the pace, what the whole of that day came to last week, and two buttons: **The day in full**
(`day-report.md`) and **Sales by day** (`sales-report.md`).

**Open checks**: how many are open at this moment and what is not yet paid on them. The oldest come first:
a check left open from an earlier day stands at the top with the day it is from, then tonight's with the
server and how long each has been open. Five are listed; **Show all** lists the rest. A line in red says
how many dishes were never sent to the kitchen, and each check says how many of them it holds. A tap on a
check opens its history, for whoever may read a check's history (`check-history.md`).

**Came off the checks**: the voids, the comps and discounts, what was taken off before sending, and checks
voided whole, each with what it came to. **Voids and comps report** lists each one, with who and why.

**On the clock**, where the location uses the time clock (`time-clock.md`): who is on now, the hours
worked today, and the net sales for each hour worked, with the same figure for the whole of that day last
week under it.

**Sold out**: every dish that is sold out and every dish with a number left, with who set it.
**Bring back** puts a sold-out dish on sale again; **No number** stops counting a dish. **86 a dish** finds
a dish by its name, its number or what the kitchen calls it, and opens the same sheet a held dish opens on
the order screen: sold out, or a number left (`eighty-six.md`). It reaches every screen within seconds,
like an 86 made at any other screen.

**Kitchen**: what a new to-go order is quoted now, at the counter and by phone, and whether the rush is
on. Whoever may set the kitchen rush has **Kitchen is busy** here, which adds minutes to every new quote on
every screen until closing (`counter-mode.md`).

**Hour by hour**: for each hour, a bar and a figure for the dishes rung in today, and a thin bar and a
small figure for the same hour last week. The hours still to come show what last week did in them.

## How fresh it is

- The line at the top says when the figures are from.
- It reads again within twenty seconds of a change on any check, and every half minute by itself, because
  the figure of a week ago moves with the clock even when nothing is rung. The round arrow reads at once.
- When no hub answers, a strip at the top says so and the last figures stay. It reads on by itself when
  the hub is back.
- The strip stays in sight however far the screen is scrolled, so old figures are never mistaken for new
  ones.

## Where it reaches

Today asks the hub, like every screen. The phone has to reach the hub: on the restaurant's network, or
from elsewhere through a VPN into it. Reading it from anywhere with no VPN waits for the cloud copy of the
location, which is not built yet (`architecture.html`).

## What each power opens on it

| On the screen | Needs |
| --- | --- |
| Opening Today, and every figure on it | See the reports |
| The day in full, Sales by day, Voids and comps report | See the reports (the same PIN) |
| A tap on an open check | Read a check's history |
| Kitchen is busy | Set the kitchen rush |
| Bring back, No number, 86 a dish | Nothing more: anyone at an order screen can 86 a dish |

A manager and an owner hold all of them. The hub checks each one again on every call, so a button that is
shown and not allowed changes nothing.

## Good to know

- Every figure is the hub's, added up from the checks each time. Nothing is stored and nothing can be left
  out: a cash sale is in it like any other.
- "The same day last week" is the same weekday seven days earlier, at the same time on the restaurant's
  clock, also across the week the clocks change.
- A day is a day of service, from 4 AM to 4 AM. At half past midnight Today is still the evening before.
- An order rung on Tuesday for Saturday counts on Saturday, from the morning on, as in every report.
- A check voided whole is no sale and is in neither figure of the pace. A dish voided after it was rung is
  out of both as well.
- Net sales and the pace are not the same figure: net sales is after comps and discounts, the pace before.
  The line under the pace names its own figures so that the two are not confused.

## Not built

- **Alerts** on the phone for a large void, a large comp or a drawer that is short. The push relay is
  built and waits for its own setup (`push-relay.md`); alerts come after it.
- **Reading it away from the restaurant with no VPN**: that needs the cloud copy of the location.
- **Labour cost in dollars.** The POS knows the hours worked and not what anyone is paid, so it shows net
  sales for each hour worked.
- A setting that opens a device on Today, and a PIN that lasts longer than the hour.
- Several locations side by side.

## For developers

- Figures: `backend/src/pos/orders/today.py`. `rung_of(state, taxes, rules)` is one check's dishes with the
  time each was rung in (`Rung`: its day by `order_day`, and `(wall_ms, amount)` for each line of
  `check_for` that kept a time), None for an order voided whole; `rung_by(rungs, day, by_ms)` adds a day's
  up to a moment; `same_time(now_ms, day, other)` is the moment of another day's service as far into it,
  by `localtime.service_day`, so a week with a clock change is exact. `RungMemo` keeps each check's `Rung`
  under the state of its log, like `SaleMemo`.
- Wire (`backend/src/pos/api/today.py`): `GET /reports/today` with a token that holds `reports` answers
  `{now_ms, day, before, per_check, hours, open, pace}`. `day` is exactly `GET /reports/day` for the
  running day, with `clock.net_per_hour` added; `before` is exactly the `span` of `GET /reports/sales` for
  the day a week earlier; `hours` is `[{hour, now, before}]` in the order a night runs; `open` is
  `{count, total, due}` over `day.open` and `day.earlier`; `pace` is `{now, before, before_ms}`. One call
  reads the week's orders once: `orders_between`, `report_for` and `clock_part` in `api/day.py` and
  `api/sales.py` are the pieces the three reports share.
- App: `lib/today.dart` (`TodayReport`, `paceWords`, `sinceWords`), `lib/screens/today_screen.dart`
  (`TodayScreen`: one `Paced` reader with a gap of 20 seconds, a 30-second timer, and the change feed of
  `live.dart`), `lib/screens/dish_finder.dart` (`DishFinderDialog`, on `MenuSearch`), `PosApi.today`. The
  bars are `pairedBars` in `lib/screens/span_report.dart`, shared with Sales. The way in is `_today` in
  `lib/screens/orders_screen.dart` and the row `today` in `lib/screens/location_settings_screen.dart`.
- Tests: `backend/tests/orders/test_today.py`, `backend/tests/test_powers.py` (the door),
  `apps/pos_app/test/today_test.dart`.
