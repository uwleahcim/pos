# Kitchen times

How long the kitchen takes over a week, a month, or any days you pick: the average ticket, the middle one,
the longest and how many were late, beside the same days whole weeks earlier. Then each station, each hour,
each day, the dishes from the slowest, and the longest tickets by name. It is for a manager, and it only
reads.

Since 18 November 2026 (the Toast comparison, row 16, the last step of the kitchen screens). It is read off
what the kitchen screens mark (`kitchen-screens.md`), so **a station has times once a cook taps the dishes
made on its screen.** A kitchen that works off paper alone has none, and the report says so.

## Opening it

Orders screen › **Location** (manager PIN) › **Kitchen times**, under Dishes sold. It is one of the reports:
whoever was handed **See the reports** under Who may do what can open it (`roles.md`).

The days are picked as in Sales: **7 days** (what it opens on: the seven whole days just gone), **4 weeks**,
**Today**, **Yesterday**, and **Other days** for a calendar, one day or up to 92. A day is a day of service,
from 4 AM to 4 AM. The round arrow at the top reads the same days again.

## What a ticket is

**A ticket is one station's dishes of one send of an order**, as that station's screen shows it: the wok's
dishes of table 12's main course are one ticket, the fryer's are another. A to-go order is one more ticket at
the station that packs it.

**It is timed from when it was sent until that station marked the last of its dishes made.** An order sent
ahead of its time (a pickup at 6) is timed from when its time came, as on the screens.

## At the top

| Line | What it says |
| --- | --- |
| **Average ticket** | all the times added up, divided by how many |
| **Half were made within** | the middle one: half the tickets took this long or less |
| **Longest** | the one that took longest |
| **Took 20 min or more** | how many were late, and what part of all of them |
| **Tickets timed** | how many tickets the times are of |

Under each is the figure of the days before, and how far apart the two are: **"2 min quicker" in green,
"3 min slower" in red.** How many tickets there were is in plain letters: more is neither better nor worse.

**Late is the minutes a ticket turns red at on the kitchen screens** (Location › Kitchen screens; 20 to
start). Where that is set to never, no ticket counts as late and the line is not shown.

Under them: **how many more were sent and not marked made.** Those are in none of the times. On the day that
is running they are mostly what is being cooked now.

## Until it went out

Shown where somebody marks dishes gone out: the pass, or a server tapping **Went out** on their check.

**A send is each time an order goes to the kitchen.** It is timed from then until the last dish of it was
marked gone out, with the same lines as above. This is the nearest figure to how long the guest waited.

## By station

Each station that marked tickets, the most tickets first: how many, its average, and under it the middle
one, the longest, how many were late, and how many it did not finish marking.

**A station that was sent tickets and marked none is named under them with how many**, and is in none of the
times: the bar with no screen, or a screen nobody taps. That way a station without a screen does not make
the kitchen look slow, or fast.

## By hour, by day

One row for each hour of the day the tickets were sent in (every day of the span together), in the order of
a night, and one for each day: a bar as long as its average stands against the slowest, the average, and how
many tickets. **A bar is red where the average is late.** A day with nothing marked keeps its row and says
"none timed".

## Dishes, slowest first

Each dish with its average, how many times it was timed, and its longest. **A dish is timed from when it was
sent until the last station that cooks it marked it made** (a platter the fryer and the wok both work on is
made when both said so). The ten slowest are shown; **All 34 dishes**, under them, shows the rest, up to a hundred.

A dish made a handful of times can stand at the top on one bad night: the count beside it says how much its
average is worth.

## Longest tickets

The ten that took longest: whose it was ("Table 12", "Tab Mike", "#14 Linda"), the station, when it was
sent, and how long it took.

## Good to know

- **Only what was marked is timed.** A cook who taps Done on a whole ticket marks every dish of it. A dish
  the pass sent out while its station never marked it is not timed for that station.
- **A cook who marks late makes the ticket look slow.** Somebody clearing the screen at the end of the night
  marks an hour-old ticket made at that moment. That is why the middle time stands beside the average: a few
  tickets marked late pull the average up and leave the middle one where it was.
- A dish voided or taken off is left out, and so is a check voided whole. A dish that was comped was cooked:
  it is in.
- A dish taken back to "not made" and marked again counts from the last time it was marked.
- A ticket counts on the day and in the hour it was sent, or for an order sent ahead, when its time came.
- A screen that skips a station (Location › Screens that skip a station) sends that station no ticket, so
  none is counted there.
- Reading the report changes nothing, and nothing about the sales is in it or leaves through it.
- The first reading of many days takes the hub some seconds; after that it is quick until the hub is
  restarted, as in Sales.

## Not built

- The times of one cook: the kitchen screens have no sign-in, so a mark is the station's, not a person's.
- How long a dish waited at the pass by itself, and a goal in minutes for each station or dish.
- Opening the check from a ticket in the list.
- Printing the report, or sending it by e-mail.
- Holding the days beside the same days a year before.

## For developers

- Figures: `backend/src/pos/printing/took.py`. `kitchen_of(state)` reads an order's log into a `Kitchen`: its
  sent dishes that still stand (`Cooked`: name, `sent_ms`, the device that sent it, the stations the menu
  cooks it at, each station's own word from `Line.done`, and the pass's word `out_ms`). `kitchen_times(
  kitchens, span, before, now_ms=, takeout=, skips=, station_names=, late_min=)` groups each order's dishes
  by the moment they were sent, makes a ticket of each station's share, and adds them up.
- A station is `silent` when it finished marking no ticket in the span; its tickets are in no figure, and
  `made` is the tickets of the other stations together. `open` counts the tickets (or sends) with a dish
  nobody marked. A send no station cooks (a beer rung at the bar's own screen) is no send.
- Wire (`backend/src/pos/api/kitchen.py`): `GET /reports/kitchen?from=YYYY-MM-DD&to=YYYY-MM-DD` with a token
  that holds `reports` answers `{span, before, late_min, max_days, now_ms}`; the days, the limits and the
  errors are those of `/reports/sales`. `span` has `made`, `out`, `stations`, `silent`, `hours`, `days`,
  `dishes` and `slowest`; `before` has `made` and `out` only. Each figure is `{tickets, avg_ms, median_ms,
  longest_ms, late, open}` (a dish says `count` for `tickets`). The hub remembers each order's `Kitchen`
  while its log stays as it was (`OrderMemo`, as the sales reports do).
- App: `lib/kitchen_times.dart` (`KitchenTimes`, `KitchenTimesSpan`, `Took`, `TookRow`, `SlowTicket`,
  `tookWords`, `tookChange`), `lib/screens/kitchen_times_screen.dart` (`KitchenTimesScreen`),
  `PosApi.kitchenTimes` (which waits 90 seconds). The day chips, the heading, the calendar and `ReportLine`
  are those of Sales (`lib/screens/span_report.dart`).
- Tests: `backend/tests/printing/test_took.py`, `apps/pos_app/test/kitchen_times_test.dart`.
