# Contests for the staff

A contest ranks the staff by what they ring in over some days: the most sales, the most of one dish, or the
most of one category. A manager sets it up; the hub adds the board up from the checks; each person sees
where they stand.

Since 21 November 2026 (the Toast comparison, row 32). Hub and app. There is no contest until a manager sets
one up. A contest reads the sales. It changes no check, no sale and nobody's pay.

## What the staff see

While a contest is on the staff's screens, the orders screen's menu has **Contests** (a cup in the bar on a
tablet, under **More** on a phone). With no contest there is no such entry.

Each contest is a card: its name, what counts, the days, who takes part, what the winner gets if the manager
wrote it, and how long is left ("3 days left", "Ends today", "Starts Fri Nov 20", "Ended yesterday").

Under that, what the person signed in may see:

- **Their own place and number**: "2nd of 6 · 14" (second of the six who take part, with 14 sold), or
  "1st of 6 · $1,052.10" in a contest on sales. With nothing yet: "Nothing yet · 6 take part".
- **Who is in front**, by name and without a number: "In front: Ben". Once it is over: "Won by Ben".
- **The whole board**, every name and number, only if the manager turned that on for this contest.
- Somebody whose role is not in the contest sees who is in front and "You are not in this one".

A contest is on the staff's screens from the moment it is set up until a week after its last day, so
everybody sees who won. While it is open the screen reads again by itself when a dish is rung in anywhere,
at most every ten seconds.

## Setting one up (a manager or an owner)

Either way leads to the same screen:

- Orders screen › **Location** (manager PIN) › **Contests**, or
- **Contests** in the orders screen's menu, when one is on, then **Set up or change contests** and the PIN.

**Set up a contest** asks for:

- **A name**, 40 letters at most: "Mai Tai month".
- **What counts**: **Sales** (the money of every dish a person rings in), **One dish** (found by typing its
  name or number, as on the order screen) or **One category** (picked from the menu's categories). A dish or
  a category is ranked by how many were sold.
- **The days it runs**: a first and a last day, both counted, 92 days at most. A new contest starts as a week
  from today. Moving the first day keeps the length.
- **Who takes part**, by role. Servers and bartenders to start.
- **Everybody sees the whole board**: off to start. Off, each person sees only their own number and place,
  and who is in front. On, every name and number is on every screen.
- **What the winner gets**, if you want to say: 80 letters at most.

The manager's screen lists every contest with its **whole board**: each person who takes part, the one in
front first, with both figures (how many, and for how much). Under the board it says what the people who are
**not in it** rang of the same, so nothing that was sold is out of sight. It also says who set the contest up
and when.

- **Change**: any part of it. The board is added up again from the checks; nothing is lost.
- **Take away**: after a question. It is gone from every screen, with its board. No sale is touched, and
  the same contest set up again shows the same board.
- A contest that ended more than a week ago stays in the manager's list with **Show the board**, until it
  is taken away. Twelve contests are kept at most.

Somebody who may **see the reports** but is not a manager (see `roles.md`) reads every board from Location
and sets nothing up.

## What counts

- **A dish counts for whoever rang it in**, not for the server the table belongs to. Two people ringing on
  one check each get their own dishes. These are the same figures as "by person" in the day's report.
- **On the day of its check.** A day runs to 4 AM, as in the reports: a drink rung at 1 AM belongs to the
  night before.
- **A voided dish does not count**, and neither does a voided check. Changing how many of a dish is on a
  check changes the count with it.
- **A comped or discounted dish counts at its menu price.** It was sold and made; who paid is another
  matter. A check's discount, the tax and the tip are not in the numbers.
- **A platter or a combo counts as itself**: once, as the dish that was rung.
- **People level on the number share a place** ("1st" twice, then "3rd"). Somebody with nothing yet has no
  place.
- **Ranked by what counts**: money in a contest on sales, how many otherwise. Level on that, the other
  figure decides the order on the board, not the place.

## Good to know

- Nothing of a board is stored. It is added up from the checks each time somebody looks, so a check that
  syncs late, a void or a correction shows the next time.
- A contest needs the hub or the cloud. With nothing answering the screen says so and offers to try again.
- Somebody who rang in the contest's days and has left the staff list since is counted with the people who
  are not in it.
- A dish taken off the menu after the contest was set up leaves the contest as it was, under the name it
  had.
- A contest on a category counts the dishes that are in that category today.
- An app that is not rebuilt has no Contests. A hub that is not updated: the app shows nothing new, and
  Location's row says the hub is older.

## Not built

- A contest on several dishes at once, or on a whole menu (Food, Drinks).
- Counting for the table's server instead of whoever rang it in.
- A contest on the add-ons the app suggests. Which suggestions were taken, and by whom, is a report of
  its own (`goes-with.md`, "Suggestions taken").
- Prizes, points or pay. The contest says who is in front; what the winner gets is the manager's to give.
- A message or a sound when somebody takes the lead, and printing a board.
- Teams, and a board across several locations.

## Installing it

1. On the hub: `sudo hubctl update`. Nothing to import.
2. Rebuild the app on every device.
3. Location › **Contests** › **Set up a contest**.

## For developers

- Rules: `backend/src/pos/orders/contest.py` (`Contest`, `clean_contests`, `boards`). The calls:
  `backend/src/pos/api/contests.py`. The setting is `contests` in the location's settings
  (`{"contests": [...]}`), empty by default.
- `GET /settings/contests` (open, no number in it): the contests, each with its `state` and whether the
  staff's screens show it, the roles, the categories one can count and the limits.
  `PUT /settings/contests` (a manager's or an owner's token): the whole list; the hub writes down who saved
  a contest and when, and what its dish or category is called.
- `GET /contests?staff_id=`: the contests on the staff's screens as that person may see each: `me`, `of`,
  `front`, and `standings` only where the contest's board is for everybody. The whole board is never given
  on the strength of a staff id. Like the other everyday calls it carries no token: the hub trusts the
  screen to say who is signed in, and the app only ever asks as that person.
- `GET /reports/contests/{id}` (the `reports` power): the whole board, `total` and `others`.
- The boards read the same remembered sales as the sales report (`pos.orders.sales.SaleMemo`). Each sold
  line now says who rang it (`Sold.by_id`, `Sold.by`).
- App: `lib/contests.dart` (the model and the words), `lib/screens/contests_screen.dart` (both screens and
  the form), the entry in `orders_screen.dart` and the row in `location_settings_screen.dart`.
- Tests: `backend/tests/orders/test_contests.py`, `apps/pos_app/test/contests_test.dart`.
