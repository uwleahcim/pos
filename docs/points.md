# Points

The guest who pays a check earns points on it: so many a dollar of what the check came to. The points
are counted and shown to the staff and in the guest list. **Nobody earns a point until a manager sets how
many a dollar earns**, and until then no screen says a word about points.

Since 25 November 2026 (the Toast comparison; the owner's pick "Points for the guest who pays"). Hub and
app. This is earning and showing. **Spending points is not built**: nothing here takes anything off a
check, a bill or a sale.

## Turning it on

Orders screen › **Location** (manager PIN) › **Points**.

- **Points a dollar.** From 0 to 100, to two decimals: 1 is one point a dollar, 1.5 is three points for
  two dollars, 0.5 is one point for two dollars. **0, or an empty box, is off.** Under the box it says what
  a $20.00 check would earn.
- **What earns**, each a switch:
  - **Tables and bar tabs**, **To-go orders**, **Deliveries**: on to start.
  - **Catering orders**: on to start. A catering order earns when this is on and its own kind (picked up
    or delivered) earns too.
  - **Alcoholic drinks**: **off to start**. Off, the drinks on a check earn nothing and the food on it
    does. On, drinks earn like food. Whether a reward may be earned on alcoholic drinks is for your
    licence and your town to say; nothing here is legal advice.
- **Points last (days).** From 30 to 365, 365 to start. A check's points count from the day of the check
  for that many days. A year is the most, because the guest list reads a year of checks.

**Save** keeps it on the hub; every screen goes by it from then on. The row under Location says the rules
in one line.

## What a check earns

- **What it came to before tax, charges and tips, less comps and discounts**, times the points a dollar.
  That is the same money the guest list says the guest spent. A delivery fee, a gratuity and the tax earn
  nothing.
- **Rounded down to whole points, check by check.** $17.45 at 1 point a dollar is 17 points; at 1.5 it is
  26.
- **Once the check is closed.** An open check is still being rung and earns nothing yet. A check that is
  reopened earns nothing while it is open, and earns by what it comes to when it is closed again. A check
  voided whole earns nothing.
- A discount on the whole check comes off the food and the drinks in proportion, so a check of $20.00 of
  food and $20.00 of drinks with $10.00 off earns on $15.00 of food where drinks do not earn.
- A check comped whole, or a check of drinks alone where drinks do not earn, earns nothing.

## Who earns

**The guest who pays.** A guest is a phone number, as in the guest list (`guest-list.md`):

- the number typed on a to-go order, a delivery or a catering order;
- a party seated from its **reservation** or from the **waitlist** that left a number.

A check with one guest is that guest's. Where several guests sit on one check, the points go to **the one
somebody said pays**: a tap on the name on the check, or afterwards from the guest list (`guest-list.md`,
"Who pays"). Until somebody says it, the check's money counts for nobody, and so do its points. When it is
said afterwards, or said otherwise, the points go with the money.

A walk-in with no number is no guest of the list and earns nothing.

## How long points last

A check's points count from the day of the check through the last day you set: with 365 days, a check of
3 March counts through 2 March of the next year. After that they are gone from the guest's count.

The number of days is one figure for all points. Make it shorter and older points stop counting at once;
make it longer again and they count again, because nothing is thrown away: points are read off the checks
each time.

## Changing the rate

**What you change about earning counts from today** (the day of service that is running). A check of an
earlier day keeps what it earned under the rules of its day. So raising the rate gives nobody points for
last month, and lowering it takes none away.

- Two saves on one day are one change: the later one stands for that day.
- **Setting the points a dollar to 0 stops earning.** What was earned before still counts until it is as
  old as points last.
- The dialog says since when the rules it shows have counted and who set them, and lists the rules of
  before with their days (the five latest).
- Checks from **before a rate was first set earn nothing**. Counting starts the day you turn it on.

## Where the points show

- **In the guest list** (Location › Guests): what all the guests have between them, with the rule in a
  line under it; each guest's points on their row; **Points** as an order to put the list in, the guest
  with the most first. Under an open guest: how many they have, which of them stop counting first and on
  what day, and beside each visit what it earned or why it earned nothing ("no points until the check is
  closed", "its points ran out", "this kind of order earns no points", "catering earns no points",
  "nothing on it earns points", "no points were given that day").
- **At the table**: on the check of a table, beside the name of each seated party that left a number:
  "99 pts". A party that left no number has none to show.
- **On the to-go form**: under how often the customer ordered: "They have 99 points", or "No points yet".

The guest list is behind the manager's PIN (or whoever you gave the guest list to). The check of a table
and the to-go form are seen by whoever serves the table or takes the call. They see **a count and
nothing else**: no number, no money. Mind that a count says roughly what a guest paid: 240 points at one
point a dollar is about $240 in a year.

Points are not printed on a bill or a kitchen ticket and are sent nowhere.

## Good to know

- **Nothing is kept for points.** The hub reads each guest's points off their checks every time, the way
  the guest list reads what they spent. So a void, a reopened check, a check merged into another and a
  word about who paid are all in the count the moment they happen, and there is nothing to put right by
  hand.
- **No sale moves.** Points take nothing off any check and change no report. The one thing written is the
  setting.
- An order for a later day earns on the day it is for, as it is that day's sale.
- When two tables are put together, the guests of both are guests of the check that is kept, and the
  points go to the one who pays it.
- A device that is not rebuilt shows no points and works as before. A hub that is not updated answers
  nothing about points: the row under Location says so, and no screen says points.

## Not built

- **Spending points**: taking money off a check for them. It is the next piece, on the owner's word.
- Points printed on the bill, or told to the guest by text or e-mail. A guest asks, and whoever has the
  check or the form reads it off.
- Typing a walk-in's number on a table's check, so that a guest with no reservation earns at a table.
- Points on the screen of a to-go order once it is open (the form says them when the call is taken).
- Giving or taking points by hand, and wiping everybody's points at once.
- Points for the checks from before the rate was set, and points that never run out.
- Another rate for some days, hours, dishes or tagged guests; levels ("gold"); a bonus for a first visit
  or a birthday.
- A page where a guest looks up their own points.

## For developers

- Rules and figures: `backend/src/pos/orders/points.py`. `Points.of(setting)` reads the setting with
  care; `Points.earned(visit, today)` is `(points, why)` for one `Visit` of the guest list
  (`pos/orders/guests.py`), by the `Rule` in force on the visit's day; `tally(visits, rules, today)` adds
  a guest's visits up and says which points run out first. `Points.saved(data, today=, by=)` is a
  manager's save: a version from today, in place of one saved earlier today, and none when nothing about
  earning changed. Versions older than 400 days that govern no check any more are dropped, 60 are kept at
  most.
- A visit knows what it needs: `Visit.closed`, `Visit.alcohol` (the net of the lines taxed `alcohol`,
  `pos/orders/sales.py` `class_net`) and `Visit.catering`. The money is `Visit.net`, which is the guest
  who pays alone (`shared_out`).
- Setting `points` (`pos/settings.py`): `{"rules": [{"from", "per_dollar", "alcohol", "dine_in",
  "takeout", "delivery", "catering", "by"}], "days": 365}`. No table, nothing else stored.
- API (`pos/api/guests.py`): `GET /settings/points` (no token), `PUT /settings/points` (manager; 422
  `bad_value` with words). `GET /reports/guests`: `points` on each guest, `totals.points`, and the rules
  (`points`). `GET /reports/guests/{phone}`: `points` and `points_why` on each visit, `points_next`.
  `GET /orders/{id}/seated`: `points` on each party (null where no rate was ever set, or no number).
  `GET /customers/lookup`: `points` likewise.
- App: `lib/points.dart` (the rules and the words), `screens/points_dialog.dart`, the row in
  `screens/location_settings_screen.dart`, `guests_report.dart` and `screens/guests_screen.dart`,
  `seated.dart` and the strip in `screens/order_screen.dart`, `customers.dart` and the card in
  `screens/orders_screen.dart`.
- Tests: `backend/tests/orders/test_points.py`, `apps/pos_app/test/points_test.dart`.
