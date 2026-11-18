# Reservations

The reservation book: the tables booked for today and for the days ahead, in the order of their times. A
table is booked with a name, how many they are, a day and a time, and a phone number, a note and a table to
hold when there is one. When the party comes, **Seat** brings up the floor map and the next table tapped is
theirs, with the guests already filled in.

Since 18 November 2026 (the Toast comparison, row 15). Hub and app; nothing to turn on.

## Where it is

- **A phone**: on the orders screen, under the three dots, **Reservations**.
- **Tablets and Macs**: open the waitlist (the button with the group of people in the bar at the top), then
  **Reservations** at its top right. The bar itself has no room for one more button. The book has
  **Waitlist** at its top right, so the two are one tap apart at the door.

Anyone signed in can open the book, book a table and seat a party. No PIN is asked: whoever answers the
phone takes the booking.

## Booking a table

**Book a table**, at the bottom of the book.

- **Name.** It cannot be left empty, and takes 24 letters.
- **How many guests.** A tap on 1 to 6 or 8, or minus and plus for any number up to 60. It starts at 2.
- **When.** Today, Tomorrow, or **Another day** off a calendar, up to a year ahead. Then **Time**: a grid of
  buttons, a row for each hour and a button for each quarter. It opens at five in the afternoon. Times are
  on the 24-hour clock, like the rest of the app.
- **Hold a table**, if they should have a certain one: a grid of the tables, each with its seats. A table
  that is already held close to that time says for whom ("18:30 Chen"). It can still be picked. **No
  table** takes the hold off.
- **Phone**, if they give one. Seven digits or more.
- **Note**: birthday, high chair, by the window. 80 letters.

**Book** puts it in the book of its day, and the book opens at that day. The book keeps who took the
booking and when.

A table booked for after midnight (half past twelve, one o'clock) belongs to the evening before: the book's
day runs to 4 AM, like the day's report.

## Reading the book

Across the top are the days: **Today**, **Tomorrow**, then every later day that has a table booked, each
with how many ("Sat 21 Nov · 2"). **Another day** opens a calendar for any day. The line under the title
adds the day up: "Today, Mon 16 Nov · 3 reservations · 12 guests".

Each reservation is a row: how many they are in the square, the name, and under it the time, the table held
("table A7"), and the note.

- **The time is plain** until a quarter of an hour before it.
- **Amber** from a quarter of an hour before.
- **Red** from a quarter of an hour after it, with nobody seated: they are late, or they are not coming.
- Only today's times are coloured.

**Two reservations holding one table within an hour and a half** say so on both rows, in red: "A7 is also
held for Garcia at 19:15". The book warns and does not refuse: you may well mean it.

## A reservation's buttons

A tap on a row opens the reservation: the day and the time, the table held, who took the booking, the phone
number and the note, over a grid of buttons.

- **Seat**: the same as the Seat button on the row (below). Today's reservations only.
- **Here**: the party has come and waits for its table. The row then says "here since 18:22", so nobody
  takes them for a no-show. The button becomes **Not here**, to take the mark off. Today only.
- **Change**: the name, the guests, the day, the time, the table, the phone, the note. Moved to another
  day, the book follows it there.
- **Cancel it**: they called to cancel.
- **No-show**: the time passed and nobody came. Today only.

Cancel it and No-show take the reservation out of the standing ones. The bar at the bottom says so with
**Put back**, for the tap that was a slip.

## Seating a booked party

**Seat**, on the row or among the reservation's buttons. The floor map comes up with a strip across the top
("Seating Chen, party of 4. Table A7 is held for them: tap it, or another."), and the next table tapped is
theirs. **Cancel** on the strip calls it off: the reservation still stands.

It then goes as for a party off the waitlist (`waitlist.md`):

- **A free table** asks what it asks of any party, with the guests already filled in. A host or a manager
  picks the server and stays on the floor map; a server who seats the party takes the check and is taken
  into it.
- **A table that is seated** asks whether the party joins it, and adds their guests to that table's check.

The table tapped need not be the one held. The book keeps both: the table that was held and the table they
sat at, with who seated them.

Two screens seating the same party: the first table counts. The second screen says "Chen was already
seated at B5. The book keeps that table."

## The ones that ended

Under the standing reservations is a line that counts the day's others: "2 seated · 1 cancelled ·
1 no-show". A tap opens the rows, the last to end first: "Seated at B6 · booked for 17:30 · Holly".

**Put back** on a row returns the reservation to the book as it was. For a party that was seated by
mistake, the check opened at the table stays as it is: close or void it as any check opened by mistake.

## Good to know

- **A reservation is not a check and not a sale.** Nothing in the book is in the sales, the day's report or
  the guest list, and the book takes no money: there is no deposit. The check opened when the party sits
  down is a table's check like any other.
- **A day that is over can be read and not changed.** Pick it with Another day. A reservation nobody marked
  stays as it was.
- **Names and numbers are kept for 30 days after the day**, then taken off the hub the next time a table is
  booked. How many they were, the time and how it ended stay.
- **Nothing is sent to the guest.** The book sends no text and no e-mail, and nothing in it leaves the hub.
- **The book is kept on the hub.** With the hub away the screen shows today's book as it was last read and
  says so; booking and changing wait for the hub. Seating still opens the check at the table, and the
  screen says the book could not be told: take the reservation out when the hub is back.
- **A change on another screen shows at once** on every screen that has the book open.
- A day takes 200 standing reservations, and a table can be booked a year ahead.
- An app that is not rebuilt has no Reservations. A hub that is not updated: the screen says the hub is
  older than reservations.

## Not built

- **Booked tables marked on the floor map**, and a warning when a walk-in is sat at a table held for
  somebody soon. This is the next step.
- Tonight's reservations counted on the waitlist's button, and **Book a table** from the caller's popup
  when a guest phones.
- **Booking by the guests themselves** (a web page), and a **text or e-mail to confirm or remind**. Both
  need an outside service the hub does not have.
- **Deposits** and card holds: payments are parked.
- A suggested table by size, and turn times that say when a table will be free.
- Standing reservations (every Friday), and a list of regulars from the book.
- A reservation going onto the guest list, or showing what the guest had last time.
- A report of reservations, no-shows and covers over many days.

## For developers

- Hub: `backend/src/pos/reservations.py` (`Reservations`, `Booking`, `BookStore`, `PgBookStore` with the
  table `reservation`; the rules, the limits, `day_of` and `at_of` for the day of service),
  `backend/src/pos/api/reservations.py` (`GET /reservations?day=`, `POST /reservations`,
  `PUT /reservations/{id}`, `POST /reservations/{id}/arrived`, `/seat`, `/cancel`, `/back`; each takes
  `staff_id`, answers the day's book with the reservation changed under `booking`, and tells the change
  feed `reservations`). On the wire `day` is the day of service ("2026-11-21") and `time` the restaurant's
  clock ("18:30"); a time before 04:00 is after that day's midnight. Refusals: 404 `unknown_staff`,
  `unknown_booking`, `unknown_table`; 409 `too_many`, `not_booked`, `not_today`, `day_over`; 422 `no_name`,
  `long_text`, `bad_size`, `bad_phone`, `bad_day`, `bad_time`, `past_day`, `too_far`, `bad_why`,
  `no_table`; 503 `read_only`. `soon_ms`, `late_ms` and `clash` are stamped by the hub and the app counts
  against `PosApi.nowMs()`; "today" is the hub's `today`, never the device's clock.
- App: `lib/reservations.dart` (`Book`, `Booking`, `BookCounts`, `bookDayWords`, `serviceMinute`,
  `serviceHours`), `lib/screens/reservations_screen.dart` (`ReservationsScreen`, pops a `SeatBooking` or an
  `OpenWaitlist`), `lib/screens/booking_dialog.dart` (`BookingDialog`, `TimeGrid`, `TablePicker`),
  `lib/screens/guests_picker.dart` (`GuestsPicker`, shared with the waitlist's form), `PosApi.reservations`,
  `addBooking`, `changeBooking`, `bookingArrived`, `seatBooking`, `cancelBooking`, `bookingBack`;
  `LiveChange.reservations`; `ArrivingParty` in `lib/waitlist.dart` is what a `WaitParty` and a `Booking`
  share, so `lib/screens/orders_screen.dart` seats either with `_seatingParty`, `_seatPartyAt` and
  `_partySeated`.
- Tests: `backend/tests/test_reservations.py`, `apps/pos_app/test/reservations_test.dart`.
