# Restaurant POS

A point-of-sale system for a group of full-service restaurants: Flutter apps on every screen (Mac, iPad and iPhone), one Python
backend that runs on two hubs per location and in two cloud regions, and an append-only order log that
merges after any disconnect.

- Architecture (draft 8): `docs/architecture.html` (also published at https://claude.ai/artifact/NyhuxEexcTSdNhYkJ6n4ay)
- Menu engine specification: `docs/menu-engine-design.md` (the binding spec for the engine)
- Decisions: `docs/adr/`
- Offline runbook (the cards the app shows from its status icon, to print for every station): `docs/offline-runbook.md`
- Menus (Food, Drinks and Lunch as tabs on the order screen, what is on which, where a drink prints, moving a
  running hub's drinks to their menu): `docs/menus.md`
- Choices that are dishes (the soup with a lunch special, the rolls of a maki combination; a group that offers a
  whole category; a chosen dish's own choices asked under it; the check and the tickets): `docs/modifiers.md`
- What Extra, On the side and Light cost (Extra charges a paid option twice, a free one stays free; the
  location's rule and a group that charges otherwise, both in the menu editor): `docs/word-prices.md`
- Discounts, comps and service charges (reasons, who approves, a comp for several dishes picked up together,
  the rules file, the report): `docs/discounts.md`
- Voids of sent dishes (a reason, a manager's PIN unless the location lets servers void, several dishes
  voided together with one reason and one PIN, the report of who voided what and why, and of every dish
  taken off a check before it was sent): `docs/voids.md`
- Allergies told at the table (the Allergy chip for a seat or the whole table, the block on every station's
  ticket, the notice when one is told after dishes were sent, what the mark on the check does and does not
  know): `docs/allergies.md`
- Sold out, and a number left (86 a dish, or type how many are left: the tile counts down as it sells, the
  dish sells out at zero, the number clears overnight; the manager's list of what is out and running low):
  `docs/eighty-six.md`
- Counter mode and takeout (order numbers, pay first, future orders, quote times with the kitchen rush and
  big orders, ready texts): `docs/counter-mode.md`
- Delivery orders (Pickup or Delivery on the to-go form, the address and a note for the driver, the
  address of a customer's last delivery already filled in, Delivery's own quote, DELIVERY on every ticket
  and where it goes on the bill, Delivered in place of Picked up; an order handed to a driver is Out, the
  customer is told it is on its way, and the Deliveries screen says what waits and what each driver has
  out; Runs says what each driver took out over the day, run by run; a delivery fee by how far it goes or
  how long the drive is, picked on the order from the location's own prices, off until they are set; with a
  map service's key on the hub, the distance is looked up from the address and its price picked, and a
  customer who orders again to the same address is not looked up a second time; Google Maps can be a
  second map service, asked when the first gives no distance, whose figures pick the price and are not
  kept; with live traffic turned on, a delivery for now is promised the kitchen's minutes and the drive as
  the roads are at that minute, and the fee never goes by it): `docs/delivery.md`
- Finding a check (a search box on the list of checks: name, phone, table, order number or server, open
  and closed; another day's checks for a manager): `docs/finding-checks.md`
- Customers remembered by their phone number (who is calling on the to-go form, how often they ordered, one
  note line, the tags a manager put on them, their past orders with Same again at today's menu):
  `docs/customers.md`
- Location settings (coursing on or off, the courses by name, quote times; manager only) and arranging the check
  by dragging its lines: `docs/location-settings.md`
- Whose table it is (the server's name on each busy table, a server taking a table by opening it, the host
  giving a table to a server and handing one over, the `host` role, whose turn the next table is, and
  **Mine**, which fades the other servers' tables on the floor map): `docs/table-servers.md`
- Printers and stations (where a dish prints, the printers with their fallbacks set from the app, finding them on
  the network, to-go orders at the takeout counter with PAID or NOT PAID on the bag's ticket, tickets that say
  "Ticket 2 of 3" and name the other stations cooking): `docs/printing.md`
- The guest's bill (the Bill button beside the total, what the paper says, which printer it comes out of, a
  screen's own printer, the restaurant's lines at the top and the foot): `docs/bill.md`
- Splitting a check (by seat in one tap, dishes moved or shared between checks, evenly; what each check
  comes to and its bill; one order all along): `docs/split.md`
- Moving a table, merging two checks, moving dishes to another table's check and giving all of a server's
  tables to another (nothing voided, nothing rung in twice, a MOVED slip for the kitchen): `docs/moves.md`
- Bar tabs (a check with a name and no table, opened with the Tab button; found again under Tabs or by its
  name; on no floor map; given a table when the party sits down, onto that table's check or beside it):
  `docs/bar-tabs.md`
- The waitlist (the parties waiting for a table in the order they came: name, guests, the wait they were
  told, a phone number and a note; the wait turns amber, then red; the wait to tell the next party is
  suggested from how tonight's parties waited; Seat brings up the floor map and the table tapped is
  theirs; tonight's list only, and no names kept after it): `docs/waitlist.md`
- Reservations (the book of tables booked for today and the days ahead: name, guests, day and time, a
  table to hold, a phone number and a note; a time turns amber, then red; Seat brings up the floor map and
  the table tapped is theirs; cancelled and no-show, with a way back; a table booked for today says so on
  the floor map, and asks before somebody else is sat there; a table is booked from the form a call
  opens, and a caller's own reservations are on it; the waitlist's button counts the booked tables still
  to come; no deposit, and nothing sent to the guest):
  `docs/reservations.md`
- Who may do what (a table under Location where a manager or an owner hands any of fourteen powers to the
  servers, bartenders, hosts, cashiers or the kitchen, or takes them back: approving a void or a comp, the
  reports, the guest list, the hours, the menu; it starts as the rules always were, and a manager and an
  owner always may do everything): `docs/roles.md`
- Tax-exempt checks (a manager marks a check exempt from sales tax with their PIN; the organisation and its
  certificate number stay with the check, print on the bill and are listed in the day's report; every sale
  stays in the sales): `docs/tax-exempt.md`
- When a dish was sent (the check says when the kitchen got each course and how long ago; a dish that went
  later says its own time): `docs/time-sent.md`
- Locking an idle screen (minutes per device, off to start; the sign-in pad comes over what was open and
  nothing is closed): `docs/idle-lock.md`
- Back to sign-in after sending (a switch per device, for a screen several people share: leaving a check
  after a send signs out): `docs/sign-in-after-sending.md`
- The screen a device opens on (the floor map or the list of checks, picked per device: the host stand on the
  tables, the counter on the to-go orders): `docs/opening-screen.md`
- Screens that skip a station (a manager says which stations a screen prints no ticket at: drinks rung at the
  bar's own screen print nothing at the bar): `docs/ticket-skips.md`
- Off-menu dishes and market prices (Open Food and its like ask what the dish is and its price when rung; any
  dish can be set to ask its price; a report lists every typed price): `docs/off-menu-dish.md`
- What goes with a dish (a manager says on each dish which dishes go with it; once it is rung the order
  screen shows them under the menu, one tap each; nothing is added that nobody tapped; a report says how
  many were added, with which dish and by whom): `docs/goes-with.md`
- The time clock (off to start; staff clock in and out and take breaks with their PIN at any screen; a
  shift nobody ended is closed at 4 AM and marked; a manager reads the hours and corrects a shift with a
  reason the log keeps): `docs/time-clock.md`
- Today (the owner's phone view: net sales so far and whether tonight is ahead of or behind the same day last
  week at this time, the open checks, what came off, who is on the clock, 86 a dish and the kitchen rush from
  the phone, the night hour by hour; it reads again by itself): `docs/today.md`
- The day's report (what is still open, the sales, the money taken by how it was paid, the sales by category,
  kind of order, person and hour, what came off the checks; on the screen for any day, and on paper):
  `docs/day-report.md`
- Sales over any days (one day, the 7 or 28 just gone, or any days up to 92, each figure beside the same
  days whole weeks earlier: net sales, checks, guests, the averages, a table's time, and the sales by day,
  hour, category and kind of order; and the same days copied as a table for the accountant, a line a day
  with the tax, comps, voids and the money taken): `docs/sales-report.md`
- Dishes sold, best to worst (every dish over the same days, how many and for how much beside the days
  before, best or worst first, with the sizes it went out in and every choice made on it; a dish on the menu
  that sold none is listed too): `docs/dishes-sold.md`
- Kitchen times (how long the kitchen takes over the same days, read off what the kitchen screens mark:
  the average ticket, the middle one, the longest and how many were late, beside the days before; each
  station, hour and day, the dishes from the slowest, and the longest tickets by name):
  `docs/kitchen-times.md`
- The guest list (every customer who ordered with a phone number in the last 12 months: visits, what they
  spent, the last visit and favourite dishes; the regulars, the guests who stopped coming and the new ones
  each a list; tags on a guest ("VIP") and their note, written there, and the tags shown to whoever takes
  that guest's call or order, on the call while it rings, on their reservation, on their line of the
  waitlist and, once they are seated from either, on the check of their table, with the party's name and
  the note of the reservation or the party; a guest who only booked a table is tagged from the
  reservation or the waitlist with a manager's PIN, and is in the list from then on, before their first
  order; for a manager):
  `docs/guest-list.md`
- Contests for the staff (a manager sets one up: the most sales, or the most of a dish or a category, over
  some days, for the roles that take part; the hub adds the board up from the checks; each person sees their
  own place and who is in front, and every number only where the manager says so; it changes no sale and no
  pay): `docs/contests.md`
- Notes for the shift and the manager's log (a manager's note comes up once for each person after they
  sign in: the specials, what is out; a manager sees who has read it; the managers' own log is kept by
  subject, searched, and struck out, never deleted): `docs/shift-notes.md`
- The to-go question (before a to-go order is sent the screen asks once what goes in the bag: chopsticks,
  forks, napkins or nothing; the answer prints on the takeout station's ticket; a manager words it, lists
  what it offers or turns it off): `docs/to-go-question.md`
- One-tap notes to the kitchen (the words typed on a dish again and again, as buttons over the dish's note:
  Rush, Split for 2; a manager keeps the list; the ticket prints them as it prints a typed note):
  `docs/kitchen-notes.md`
- Dish names in Chinese on the screens (each person picks, under Display, which name of a dish they read:
  English or 中文; the menu's tiles and the check follow it and it follows them to every screen; what is
  recorded, the bill and the kitchen's tickets do not change): `docs/dish-names.md`
- The waste log (food that was made or bought and not sold: what it was, how many and why, with a reason
  from the location's list; struck out, never deleted; a manager reads it by reason, by dish and by day; it
  is beside the sales and never part of them): `docs/waste-log.md`
- The pickup board (a screen facing the pickup shelf lists the to-go orders being made and the ones ready,
  by number and first name and nothing else; a switch on the device, the board standing where the sign-in
  pad stands, with Staff in its corner for the pad): `docs/pickup-board.md`
- Kitchen screens (a screen at a station lists what the station has to make, in the words of its paper
  ticket, coloured by how long it has waited; a tap marks a dish made and Recall brings a finished ticket
  back; a mark changes nothing of the check; the paper prints as before; the pass shows each ticket whole
  with what every station has made, and All day counts the dishes still waited for; what the cooks mark
  reaches the servers: "ready" under the dish on its check, a strip with Went out, and a badge on the
  table on the floor map; a screen chimes when a ticket comes in): `docs/kitchen-screens.md`
- Catering orders and the orders ahead (a to-go order for any later day, with the guests, pickup or
  delivery, the address and a note; a deposit with the rest still due, and Pay for the rest; the list of
  checks says the day and what is left to pay; Orders ahead lists what was promised for a later time by
  day, with what was paid on each; each day's prep list adds its dishes up by station, on screen and on
  paper; a catering order prints a pack sheet with its tickets, every dish with a box to tick):
  `docs/catering.md`
- Online orders (a pickup or delivery order placed on the restaurant's GloriaFood site and accepted there
  goes on the POS by itself, as a to-go order with the website's prices, promotions, fee, tip and payment,
  and its kitchen tickets print; GloriaFood sends it the moment it is accepted, through a push door that
  is the only thing of the hub reachable from outside, `hubctl online push key`, and the hub also asks
  every minute as the net under that, `hubctl online key`, or this moment when a manager presses Ask now;
  an order that came both ways is one order; one that cannot go on prints a slip and is listed; what the
  website took is its own row, Paid online, in the day's money; a table booked on the website goes into
  the reservation book, once, marked online): `docs/online-orders.md`
- A check's history (every step of one check, oldest first: who did it, at which screen and when, who
  approved, and the picture taken with it; for a manager, from the check, The day or the voids report):
  `docs/check-history.md`
- Desk phones linked to screens (a call taken on a desk phone opens the caller's order on its screen; the hub's
  link to the PBX): `docs/desk-phones.md`
- Setting up a Mac for development (Xcode, Flutter, Android Studio, the backend, SSH to the hub and the PBX;
  what to copy from the old Mac and what to install fresh): `docs/developer-mac.md`
- Competitive review against Toast, Square, Clover, Lightspeed and TouchBistro (1 Nov 2026): `docs/competitive-review-2026-11-01.md`
- Phase 0 plan and spike status: `docs/phase0/README.md` and `spikes/`

## Layout

```
backend/   Python backend: menu engine, orders and sync, taxes, payments, APIs (FastAPI)
apps/      Flutter apps for macOS and iOS: POS, kitchen, admin portal (screens only, no business rules)
spikes/    Phase 0 spikes: one folder per question, each with its pass criteria and result
infra/     Hub install for the mini PCs (infra/hub); hub image and cloud deployment later
docs/      Architecture, spec, decisions, plans
```

## Backend quick start

```
cd backend
uv venv .venv && uv pip install -e '.[dev]'
.venv/bin/pytest
.venv/bin/python -m pos.sync.simulate --replicas 4 --rounds 300 --drop 0.3
.venv/bin/uvicorn pos.api.app:app --reload
```

The first spike, the order operation log with hybrid logical clocks, lives in `backend/src/pos/sync/`; the second,
the menu engine built from the specification, in `backend/src/pos/menu/`. Both pass in software; see `spikes/`.
