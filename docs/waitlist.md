# The waitlist

The parties waiting for a table, in the order they came: a name, how many they are, the wait they were
told, and a phone number or a note when there is one. The wait counts up beside each name and turns amber,
then red, as the time they were told comes up. When their table is free, **Seat** brings up the floor map
and the next table tapped is theirs, with the guests already filled in.

Since 17 November 2026 (the Toast comparison, row 14). Hub and app; nothing to turn on.

## Where it is

On the orders screen, in the bar at the top: the button with the group of people. A number on it says how
many parties are waiting. The number turns amber when a party's time is nearly up and red once one has
waited longer than it was told, so the whole floor sees it without opening the list.

- **Tablets and Macs** always have the button.
- **A phone** has it while a party is waiting, and always for a host, a manager or an owner. A server's
  phone with nobody waiting keeps the room for their name: the list is then under the three dots,
  **Waitlist**.

Anyone signed in can open the list, add a party and seat one. No PIN is asked: on a busy night whoever is
at the door keeps it.

**Reservations**, at the top right of the list, opens the reservation book (`reservations.md`): the tables
booked for today and the days ahead. The book has **Waitlist** at its top right, to come back.

**Booked tables are on the button and on the list too.** A second, square number at the bottom left of the
button counts the tables booked for today that are still to come, amber when one is near its time and red
when one is past it. At the top of the list a row says how many and which is next ("5 booked tables to
come", "Next at 18:30: Chen, 4 guests · table A8"), and a tap on it opens the book. With nothing booked for
today neither shows (`reservations.md`, "On the waitlist's button").

## Adding a party

**Add party**, at the bottom of the list.

- **Name.** It cannot be left empty, and takes 24 letters.
- **How many guests.** A tap on 1 to 6 or 8, or minus and plus for any number up to 60. It starts at 2.
- **Wait told.** No time, or 5, 10, 15, 20, 30, 45 minutes, 1 hour, 1 hour 30. It starts at no time.
- **Phone**, if they give one. Seven digits or more.
- **Note**: high chair, booth, birthday. 60 letters.

**Add to the list** puts them at the end. The list keeps who added them and when.

## Reading the list

Each party is a row: how many they are in the square, the name, and under it how long they have waited so
far, what they were told ("told 20 min", or "no time told"), and the note.

- **The wait is plain** while there is time.
- **Amber** in the last 5 minutes before the time they were told.
- **Red** from that time on.
- A party that was told no time is never coloured: nothing was promised.

The minutes count on their own, by the hub's clock, so every screen shows the same wait. The top of the
screen says how the list adds up: "4 parties · 14 guests".

## A party's buttons

A tap on a row opens the party: when they came, how long they have waited, who added them, the phone
number and the note, over a grid of buttons.

- **Seat**: the same as the Seat button on the row (below).
- **Called**: they were told their table is ready. The row then says "called just now", "called 3 min
  ago", so the next person at the door knows not to call them twice. The button becomes **Not called**, to
  take the mark off. Nothing is sent to the guest: it is a mark for the staff.
- **Change**: the name, the guests, the wait told, the phone, the note. The party keeps its place, and the
  wait still counts from when they came.
- **Left**: they gave up waiting.
- **No-show**: they were called and nobody came.

Left and No-show take the party off the list. The bar at the bottom says so with **Put back**, for the tap
that was a slip.

## Seating a party

**Seat**, on the row or among the party's buttons. The floor map comes up with a strip across the top
("Seating Chen, party of 4. Tap their table."), and the next table tapped is theirs. **Cancel** on the
strip, or going to the list of checks, calls it off: the party is still waiting.

- **A free table** asks what it asks of any party, with the guests already filled in ("Seat Chen at A8",
  4 guests). A host or a manager picks the server and stays on the floor map for the next party
  (`table-servers.md`); a server who seats the party takes the check and is taken into it.
- **A table that is seated** asks whether the party joins it: "Does Chen, party of 4 join the table? Its
  check then counts 8 guests." **Join A7** adds their guests to that table's check; no second check is
  opened. For a table of their own, tap a free one.

The party goes off the list, and the list keeps the table, who seated them and how long they waited.

Two screens seating the same party: the first table counts. The second screen says "Chen was already
seated at B5. The list keeps that table."

## Earlier tonight

Under the waiting parties: **Earlier tonight**, with how many were seated and how many left, and how long
the seated ones waited on average ("Seated after 20 min on average"). A tap opens the rows, the last to go
first: "Seated at B5 · after 20 min · Holly", "No-show · after 45 min · Holly".

**Put back** on a row returns the party to the place it had, with its wait still counting from when it
came. For a party that was seated by mistake, the check opened at the table stays as it is: close or void
it as any check opened by mistake.

## Good to know

- **The list is tonight's.** A night ends at 4 AM, like the day's report. The next night starts empty.
- **Names and numbers are not kept.** When the next night's first party is added, the names, phone numbers
  and notes of the nights before are taken off the hub. How many they were, how long they waited and how it
  ended stay, for a report of waits later.
- **A party is not a check and not a sale.** Nothing on the list is in the sales, the day's report or the
  guest list. The check opened when a party sits down is a table's check like any other.
- **The list is kept on the hub.** With the hub away the screen shows the list as it was last read and
  says so; adding, changing and taking off wait for the hub. Seating still opens the check at the table,
  and the screen says the list could not be told: take the party off when the hub is back.
- **Sixty parties** can wait at once.
- An app that is not rebuilt has no button. A hub that is not updated: the app shows no button.

## Not built

- **A text when the table is ready**, and the guest's reply to confirm or cancel. It needs a texting
  service the hub can send through, and the hub has none yet (its texts go to its log). Called is the mark
  for a call made by voice or by phone.
- Dragging a party onto a table (it is Seat, then a tap on the table).
- Server rotation: suggesting whose turn it is by guests or by who was sat last. The seat question already
  shows what every server has on the floor.
- A suggested wait worked out from the tables.
- The party's name on the check or on the table.
- A report of waits over many days.
- A booked party on this list: reservations have their own book (`reservations.md`), one tap from here.
- Waitlist guests going onto the guest list.

## For developers

- Hub: `backend/src/pos/waitlist.py` (`Waitlist`, `Party`, `WaitStore`, `PgWaitStore` with the table
  `waitlist_party`; the rules, the limits and `tonight()`), `backend/src/pos/api/waitlist.py`
  (`GET /waitlist`, `POST /waitlist`, `PUT /waitlist/{id}`, `POST /waitlist/{id}/called`, `/seat`, `/left`,
  `/back`; each takes `staff_id`, answers the whole list with the party changed under `party`, and tells
  the change feed `waitlist`). Refusals: 404 `unknown_staff`, `unknown_party`, `unknown_table`; 409
  `too_many`, `not_waiting`; 422 `no_name`, `long_text`, `bad_size`, `bad_quote`, `bad_phone`; 503
  `read_only`. The answer carries no clock, so an unchanged list is a 304; `due_ms` and `amber_ms` are
  stamped by the hub and the app counts against `PosApi.nowMs()`.
- App: `lib/waitlist.dart` (`Waitlist`, `WaitParty`, `WaitCounts`, `waitWords`),
  `lib/screens/waitlist_screen.dart` (`WaitlistScreen`, pops a `SeatParty`, or an `OpenReservations` for
  the reservation book),
  `lib/screens/party_dialog.dart` (`PartyDialog`), `PosApi.waitlist`, `addParty`, `changeParty`,
  `partyCalled`, `seatParty`, `partyLeft`, `partyBack`; `LiveChange.waitlist`; in
  `lib/screens/orders_screen.dart` the button, `_seatingParty`, `_seatPartyAt` and `_partySeated`.
- Tests: `backend/tests/test_waitlist.py`, `apps/pos_app/test/waitlist_test.dart`.
