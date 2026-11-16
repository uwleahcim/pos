# The guest list

Every customer who ordered with a phone number in the last 12 months, on one screen: how often they came,
what they spent, when they were last here and what they order most. Three lists are picked out of it: the
**regulars**, the guests who **stopped coming**, and the **new** ones. It is for a manager, and it only
reads.

Since 16 November 2026 (the Toast comparison, row 30). It grows out of the customers the to-go form already
remembers by their number (`customers.md`): nothing new is typed in for it, and nothing new is kept.

## Opening it

Orders screen › **Location** (manager PIN) › **Guests**, under Dishes sold.

It reads the 365 days of service that end with the one running. The round arrow at the top reads them
again.

## The list

At the top: how many guests there are, how many of them are regulars, stopped coming or new, and what all
of them spent, over how many visits and how much a visit.

Then every guest, one line each, numbered from the top:

- their **name** (the one on their latest order that has a name; a number nobody ever gave a name for is
  called by the number), **how many visits** and **what they spent**;
- under the name, their number, the day of their last visit, and **regular** in green, **stopped coming**
  in red, or **new**.

What stands above the list changes it:

| Control | What it does |
| --- | --- |
| **All / Regulars / Stopped coming / New** | every guest, or one of the three lists; each button says how many are on it |
| **Spent / Visits / Latest** | ranks by what they spent, by how often they came, or by who was here last |
| **Find a name or a number** | any words of the name in any order, or any digits of the number ("0142") |

## The three lists

- **Regulars** came 3 times or more in the last 90 days.
- **Stopped coming**: 3 visits or more in the year, and none for 60 days. These are the ones worth a call
  or a card. A guest on this list is not counted as a regular as well.
- **New** placed their first order ever in the last 30 days. A new guest who has already come three times
  is a regular too, and the line says both.

The line over the list says what the picked list means, and the small print at the foot of the screen says
all of it, in the hub's own numbers.

## Under a guest

A tap opens a guest:

- **The note** the restaurant keeps about them ("Peanut allergy, side door"), with who wrote it and when.
  It is written on the to-go form, as before; here it is only read.
- **A guest since** the day of the first order they ever placed, and how many orders in all. These two look
  past the 12 months, and say what the to-go form says of a caller.
- What they spend a visit, and their visits in the last 90 days.
- **Favourite dishes**: the ten they ordered most in the year, with how many.
- **Latest visits**: the last ten, each with its day, whether it was to go, delivery or a table, what it
  came to and its dishes. **A tap on a visit opens that check's history** (`check-history.md`).

Any number of guests can be open at once.

## Good to know

- **A guest is a phone number that ordered.** Calls, to-go and delivery orders carry one; a table has one
  only when someone typed it on the check. A table with no number is not in the list, so the list is not
  all of the sales: the line "They spent" is the sales of the checks that carry a number. Numbers match by
  their digits, and one of fewer than seven digits is nobody's.
- **A visit** is an order with at least one dish on it. It counts on the day Sales counts it on: the day it
  was opened, or the day it is for when that is later, and only once that day has come (an order placed
  today for Saturday is not a visit yet). A check voided whole is no visit; a dish voided or taken off is
  not among the favourites.
- **What a guest spent** is what their checks came to before tax, charges and tips, less comps and
  discounts: the net sales of Sales. A table that split its check is still one visit.
- **Favourite dishes** are counted by how many were sold, under the name the menu gives the dish today. An
  off-menu dish is counted under the name that was typed for it.
- "Orders in all" can be more than the visits even within the year: it counts every order the number
  placed, as the to-go form does, and so one that was opened and left empty as well.
- Two people who share a number are one guest, and one person with two numbers is two.
- Every sale stays in Sales and The day whether or not it has a number. This screen leaves nothing out of
  them and changes nothing.
- The list holds names, numbers and what people spent, so it is behind the manager's PIN like the other
  reports. The to-go form shows a caller to whoever takes the order, as before.
- The first reading after the hub starts takes it some seconds, as it reads a year of orders; after that
  it is quick until the hub is restarted. A year of 30,000 orders with a number adds up in a quarter of a
  second.

## Not built

- Sending the list out of the POS (a file, a print, an e-mail).
- Tags on a guest, or more notes than the one line.
- Writing or changing the note from this screen.
- Messages or offers to guests, points, birthdays.
- A guest without a phone number, or joining two numbers into one guest.
- Changing what "regular", "stopped coming" and "new" mean from the app. They are five numbers in the hub
  (below).

## For developers

- Figures: `backend/src/pos/orders/guests.py`. `visit_of(state, taxes, rules)` turns one order into a
  `Visit` (phone, day, net, name, kind, dishes) or None; it reads the order's `Sale`
  (`pos/orders/sales.py`), so a visit's day and money are the sales report's. `guests_report(visits,
  entries, notes, defs=, now_ms=)` is the list and `guest_report(phone, ...)` one guest. The numbers:
  `LOOK_BACK_DAYS = 365`, `REGULAR_VISITS = 3`, `REGULAR_DAYS = 90`, `LAPSED_DAYS = 60`, `NEW_DAYS = 30`,
  `FAVOURITES = 3` in the list and `MORE_FAVOURITES = 10` for one guest, `LATEST = 10`.
- Memory: `VisitMemo` remembers each order's `Visit` while its log stays as it was, as `SaleMemo` does for
  the sales (both are an `OrderMemo` now). It is a memo of its own so that a year of visits does not push
  the remembered sales out.
- Which orders: `store.with_phone()` (every index entry that carries a number; `orders.phone <> ''` in
  PostgreSQL) gives "since" and "orders in all" without replaying anything; `in_window` keeps the ones that
  can count in the year, and only those are replayed. Notes: `CustomerNotes.all()`.
- Wire (`backend/src/pos/api/guests.py`), both with a manager's token: `GET /reports/guests` answers
  `{first, last, days, regular_visits, regular_days, lapsed_days, new_days, now_ms, guests, totals}`, each
  guest `{phone, name, note, visits, spent, per_visit, last, first, since_ms, orders_ever, lately, regular,
  lapsed, new, favourites}`, the one who spent most first. `GET /reports/guests/{phone}` answers `{guest,
  note_by, note_ms, latest}`, or 404 `no_guest` for a number with no visit in the year.
- App: `lib/guests_report.dart` (`GuestsReport`, `Guest`, `GuestDetail`, `GuestVisit`, `GuestList`,
  `guestsOf`, `GuestSort`, `sortedGuests`, `guestsNamed`), `lib/screens/guests_screen.dart`
  (`GuestsScreen`), `PosApi.guestsReport` (which waits 90 seconds) and `PosApi.guestDetail`. The lists, the
  order and the search are worked out in the app from the one answer; a guest is read closely when opened.
- Tests: `backend/tests/orders/test_guests.py`, `apps/pos_app/test/guests_report_test.dart`.
