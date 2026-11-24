# The guest list

Every customer who ordered with a phone number in the last 12 months, on one screen: how often they came,
what they spent, when they were last here and what they order most. Three lists are picked out of it: the
**regulars**, the guests who **stopped coming**, and the **new** ones. It is for a manager. It reads the
orders and changes none of them; the two things written here are a guest's **tags** and their **note**.

Since 16 November 2026 (the Toast comparison, row 30). Since 23 November 2026 the tags are put on here
and shown where that guest's call and order are taken, and the note is written here too; the tags also show
on the call while it rings, in the reservation book and on the waitlist, and a guest can be tagged from
their reservation or their line of the waitlist as well. Since 24 November 2026 a guest tagged that way
who has not ordered yet is in the list too, after the others. It grows out of the customers the to-go form
already remembers by their number (`customers.md`): nothing is typed in for the list itself.

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
  in red, or **new**;
- under that, the **tags** they carry, each a small label ("VIP").

After them come the **tagged guests with no order**: somebody tagged from their reservation or the waitlist
before their first order. Their line says **no order yet** where the others say their last visit, and has
no visits and no money ([A tagged guest who has not ordered yet](#a-tagged-guest-who-has-not-ordered-yet)).

What stands above the list changes it:

| Control | What it does |
| --- | --- |
| **All / Regulars / Stopped coming / New** | every guest, or one of the three lists; each button says how many are on it |
| **Spent / Visits / Latest** | ranks by what they spent, by how often they came, or by who was here last |
| **A tag** ("VIP 2") | only the guests who carry it; the button says how many do. A second tap shows everybody again |
| **Find a name or a number** | any words of the name in any order, or any digits of the number ("0142") |

The tags are one line of buttons that slides sideways, the one most guests carry first. The line is there
once a guest carries a tag. A tag works together with the rest: "Regulars" and "VIP" is the regulars who
are VIPs.

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

- **Their tags** and **the note** the restaurant keeps about them ("Peanut allergy, side door"), each with
  who wrote it and when, and the button **Add a tag or a note** (**Change tags and note** once there is
  one). See below.
- **A guest since** the day of the first order they ever placed, and how many orders in all. These two look
  past the 12 months, and say what the to-go form says of a caller.
- What they spend a visit, and their visits in the last 90 days.
- **Favourite dishes**: the ten they ordered most in the year, with how many.
- **Latest visits**: the last ten, each with its day, whether it was to go, delivery or a table, what it
  came to and its dishes. **A tap on a visit opens that check's history** (`check-history.md`).

Any number of guests can be open at once.

## Tags and the note

A **tag** is a word or two put on a guest to pick them out by: "VIP", "Friend of the house", "Catering
client", "Regular at the bar". The **note** is the one line the to-go form has always shown to whoever
takes their call. Both are kept by the guest's phone number.

Open a guest and tap **Add a tag or a note**. A box opens with their name on it:

- **Tags** are buttons. A tap puts one on, a second tap takes it off. The buttons are every tag some guest
  carries, and two that are always offered: **VIP** and **Friend of the house**.
- **Another tag**: type one that is no button yet and tap **+** (or Enter). It goes on this guest, and it
  is a button for every guest from then on. A tag typed and not added is still saved with **Save**.
- **Note**: the one line, 120 letters at most. Emptying it takes the note away.
- **Save** keeps both; **Cancel** keeps nothing.

Good to know about tags:

- **There is no list of tags to look after.** A tag exists while some guest carries it. Take it off the
  last guest and its list is gone, and its button too the next time the guest list is read (VIP and Friend
  of the house stay).
- **A tag is spelt one way.** Typing "vip" where "VIP" is in use puts "VIP" on. To spell a tag another way,
  take it off everybody who carries it and type it again.
- A guest carries **6 tags** at most, each **24 letters** at most. With six on, the other buttons wait
  until one is taken off.
- The hub writes down **who** put the tags on and **when**, and the same for the note, each by itself:
  changing the tags does not put your name on a note someone else wrote. The name is the one of whoever
  opened the guest list with their PIN.
- Another device that has the guest list open shows the change the next time it reads the list (the round
  arrow).
- **Find** looks at names and numbers, not at tags: use the tag's button.

Who may write them: whoever may see the guest list, so a manager and an owner, and anybody the owner hands
"See the guest list" to (`roles.md`). The same people tag a guest from a reservation or the waitlist, with
their PIN ([From a reservation or the waitlist](#from-a-reservation-or-the-waitlist)). The note can still
be written on the to-go form by whoever takes the call, as before.

### Where the tags show

- **Here**, under the guest's name and as a list of its own.
- **On the to-go form**, the moment that guest's call is answered or their number is typed: small labels
  under the line that says how often they ordered, over the note (`customers.md`, "On the to-go form").
- **On their order**, in the slim strip under the app bar, before the note, for whoever rings the dishes
  in (`customers.md`, "On the order").
- **On their call while it still rings**, under the number and the phone company's name, on every screen
  where somebody is signed in. So whoever picks up knows it is a VIP before saying hello. The sign-in pad
  and a locked screen show the number alone, as before.
- **On their reservation**, in the book: small labels on the row, after the time and the table and before
  the note, and under the number when the reservation is opened (`reservations.md`, "Reading the book").
- **On their line of the waitlist**, the same way: on the row before the note, and under the number when
  the party is opened (`waitlist.md`, "Reading the list").
- **On the check of their table**, once the host seated them from their reservation or the waitlist, in
  the same slim strip under the app bar: [At the table](#at-the-table).

The book and the waitlist know a guest by the **phone number** written on the reservation or the party: a
table booked or a party added without a number shows no tag, whoever they are. The tags are the number's,
not the reservation's: nothing is copied into the book, so a tag put on today shows on a table booked last
week, and a tag taken off is gone from it.

In all of these places they are only read, by anyone who takes the call, the order or the door. So **keep
a tag to what the staff may read**: "VIP" and "Catering client" are good tags, and an opinion of a guest
is not. A tag is never printed, on no kitchen ticket and no bill, and nothing sends it out of the hub.

A screen asks for a customer once, when the form looks the number up or the order is opened: a tag put on
while an order is open shows the next time that order is opened. A call asks once, when it starts to ring.
The book and the waitlist are told when a guest's tags change, and show it at once on every screen that
has them open. So is the check of a table whose party was seated from one of them.

### At the table

A tag helps most where the guest sits. So when a tagged guest is **seated from their reservation or from
the waitlist**, their tags are on the check of that table: small labels in the slim strip under the app
bar, the same strip a to-go order has. Whoever opens the check to ring the dishes in sees `VIP` before
they walk over.

- Nothing is done for it. The host seats the party as always (**Seat**, then the table), and the check
  that opens knows whose it is.
- **The check shows the tags and nothing else**: no name, no phone number and no note of the guest. The
  guest's number stays in the book or on the waitlist; it is not written onto the check. So the check is
  what it always was: the same on the bill, in Sales and in this list, where a table still counts as a
  visit only when somebody types a number on it.
- **A party that joins a table** (the host taps a seated table and **Join**) adds its tags to that table's
  check. Each tag shows once, whoever of them carries it.
- A check that has a number of its own (typed on it) shows that customer's tags and note first, then the
  tags of the guests seated on it.
- The tags follow the check: move the table to another one and they are still on it, and a check that is
  split is still that check.
- **They are read each time, not copied.** A tag a manager puts on or takes off while the party eats shows
  on the open check at once, and a party that sits down on a check somebody already has open shows its
  tags there at once. Without the hub's live updates it takes up to half a minute.
- Put the party back in the book or on the list (**Put back**) and its tags leave the check.
- The party needs a **phone number** on its reservation or its line of the waitlist: that is what the
  tags are kept by. A walk-in seated straight from the floor map has neither, and its check shows no tag.
- As everywhere, the tags are only read here, they print on no kitchen ticket and no bill, and nothing
  sends them out of the hub.

### From a reservation or the waitlist

This list holds the numbers that **ordered**. Somebody who only ever books a table, or waits for one, is
not in it. They are tagged where they stand:

1. Open their reservation in the book, or their party on the waitlist, with a tap on the row.
2. Tap **Tags**, the last of the buttons. It is there when the reservation or the party has a phone
   number: the tags are kept by the number, so without one there is nothing to keep them by.
3. Type the **PIN** of somebody who may see the guest list: a manager's or an owner's, and that of anybody
   the owner handed "See the guest list" to. The host's own PIN is not taken unless hosts were handed it.
   The PIN is asked every time: the host stand is nobody's back office.
4. The box of tag buttons opens with the guest's name on it, the same box as here, with the tags they
   carry already on. Tap tags on or off, or type **Another tag**, and **Save**.

The bar at the bottom says what was kept ("Novak is tagged VIP"), and the tag is on the row at once, on
every screen. From then on it shows wherever that number turns up: on their next reservation, their next
wait, their call while it rings and their first order.

- The box has **the tags alone**. The note of a reservation is the reservation's own ("Window table"), and
  the one line the restaurant keeps about a customer is written here or on the to-go form.
- It works for a guest who is in this list too: it is the same tags either way.
- A guest tagged this way who has never ordered **is in this list from then on**, after the guests who
  ordered, under the name on the reservation or the party (below). Their tags are changed from here or
  from a reservation or a party of theirs, whichever is at hand.
- The reservation and the party are not touched: no time, table, place in the line or wait changes.

### A tagged guest who has not ordered yet

The list reads orders, and somebody who only ever booked a table has none. So that every VIP is in one
place, a number that **carries a tag** is listed even with no order in the 12 months:

- They stand **after the guests who ordered**, whichever way the list is ranked, by name.
- Their line has their name, their number and **no order yet**, and their tags. There are no visits and
  no money on it. A guest whose orders are all older than the 12 months says **no visit in the last 12
  months** instead.
- **The name** is the one on the reservation or the party they were tagged from: the hub keeps it with
  their tags, because there is no order to read a name from. Tagged again from a reservation under another
  name, they are called by the newer one. A party that gave no name is called by the number.
- They are counted in **All**, in the line "Guests" (which says how many of them have no order) and on the
  list of each tag they carry. They are on none of the three lists, and nothing of theirs is in "They
  spent" or the visits.
- **Open one** and it says their tags with who put them on, their note, and that there is no order yet.
  **Change tags and note** works as for anybody.
- **Take their last tag off and they leave the list**: there is nothing left to list them for. The bar at
  the bottom says so. The name kept with the tags goes with them; a note stays with the number, and shows
  on the to-go form if they ever call.
- **Once they order**, they are a guest like the others, with their tags on, under the name on their
  order.
- A guest who was tagged before the hub kept names (before 24 November 2026) is called by their number,
  until they are tagged again from a reservation or a party: open it, tap **Tags**, type the PIN and tap
  **Save**. Nothing about their tags changes by it.

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
- A tag or a note changes no order, no sale and no figure: not on this screen and not on any report. It
  changes no reservation and no party on the waitlist either: they only show it.
- Seeing a guest's tags on the check of their table changes nothing either: no dish, no price, no
  payment, no reservation and no party. With a hub that is not updated, or a device that is not rebuilt,
  a table's check shows no tags, as before.
- With a hub older than the tags, the list is what it was: it reads, and there is no button to write.
  With a hub older than listing tagged guests with no order, the list holds the guests who ordered, as
  before. A device that is not rebuilt shows that list too, whatever the hub.
- The name kept with a guest's tags is on the hub only, behind the manager's PIN like the rest of the
  list. It is kept for as long as the number carries a tag, shown only here and only while the number has
  no order in the 12 months, and never printed or sent anywhere.
- The first reading after the hub starts takes it some seconds, as it reads a year of orders; after that
  it is quick until the hub is restarted. A year of 30,000 orders with a number adds up in a quarter of a
  second.

## Not built

- Sending the list out of the POS (a file, a print, an e-mail).
- Typing or correcting the name of a tagged guest with no order from this list: it is the name on the
  reservation or the party they were last tagged from.
- A number with a note and no tag, and no order in the 12 months, in this list: it is the tag that lists
  them.
- Tags from a reservation that ended (cancelled, no-show, seated) or a party that left: the button is on
  the ones still standing. A reservation or a party with no phone number cannot be tagged.
- Writing the customer's one-line note from a reservation or the waitlist.
- The tags on the strip of a call once it is answered (the to-go form that opens shows them), on the
  iPhone's own call screen, on a table held on the floor map, on the waitlist's row of booked tables, and
  in the list of to-go orders.
- At the table: the guest's name or the reservation's note on the check; the tags on the table itself on
  the floor map or in the list of checks; saying which of two parties at one table carries which tag;
  the tags of a walk-in (type their number on the check and it shows what that number carries); the tags
  on a check that the party's check was merged into. Putting the party's number on the check by itself,
  so that the table counts as their visit in this list, is not done: say so if you want it.
- The restaurant's own name for a caller on the ringing strip: it still says the phone company's.
- Renaming a tag for everybody who carries it in one go, or a colour for a tag.
- Tagging many guests at once. Putting a first tag, from this list, on a number with no order in the
  last 12 months: such a guest is tagged from their reservation or their party.
- More notes than the one line.
- Messages or offers to guests, points, birthdays.
- A guest without a phone number, or joining two numbers into one guest.
- Changing what "regular", "stopped coming" and "new" mean from the app. They are five numbers in the hub
  (below).

## For developers

- Figures: `backend/src/pos/orders/guests.py`. `visit_of(state, taxes, rules)` turns one order into a
  `Visit` (phone, day, net, name, kind, dishes) or None; it reads the order's `Sale`
  (`pos/orders/sales.py`), so a visit's day and money are the sales report's. `guests_report(visits,
  entries, notes, defs=, now_ms=, tags=, names=)` is the list and `guest_report(phone, ...)` one guest. The numbers:
  `LOOK_BACK_DAYS = 365`, `REGULAR_VISITS = 3`, `REGULAR_DAYS = 90`, `LAPSED_DAYS = 60`, `NEW_DAYS = 30`,
  `FAVOURITES = 3` in the list and `MORE_FAVOURITES = 10` for one guest, `LATEST = 10`.
- Memory: `VisitMemo` remembers each order's `Visit` while its log stays as it was, as `SaleMemo` does for
  the sales (both are an `OrderMemo` now). It is a memo of its own so that a year of visits does not push
  the remembered sales out.
- Which orders: `store.with_phone()` (every index entry that carries a number; `orders.phone <> ''` in
  PostgreSQL) gives "since" and "orders in all" without replaying anything; `in_window` keeps the ones that
  can count in the year, and only those are replayed. Notes: `CustomerNotes.all()`.
- Tags: `backend/src/pos/guest_tags.py`. `GuestTags` (memory) and `PgGuestTags` (table `guest_tag`: `phone`,
  `tags` as JSON, `updated_by`, `updated_ms`), on `app.state.guest_tags` (`app.state.tags` is the sign-in
  tags of `face-signin.md`, another thing). `clean_tags(tags, known)` is the one place a tag is tidied: one
  line, each once whatever its capitals, spelt as `known` spells it, by the alphabet, `TAG_MAX = 24`,
  `TAGS_MOST = 6`. `offered(carried, listed)` is the tags on offer with how many of the listed numbers
  carry each; `STANDARD` is the two always offered. A standby reads and does not write (`ReadOnlyError`).
- A tagged number with no order: `guests_report` answers `tagged` beside `guests`: every number of
  `GuestTags.all()` with no visit in the window, as a row of a guest's shape with `visits` 0, `spent`
  "0.00", `per_visit`, `last` and `first` null, `since_ms` and `orders_ever` of its older orders (null and
  0 with none), the flags false and no favourites, by name and the nameless by number after them.
  `guests`, `totals` and each tag's `guests` are as they were (of the numbers with a visit), so an app
  that does not know `tagged` is not touched. The name is kept with the tags: column `name` of `guest_tag`
  (added by `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`), `clean_name` (one line, `NAME_MAX = 40`),
  `GuestTags.put(..., name=)` (no name said keeps the one it had; no tags, no name), `rename` (the name
  alone, for a number that carries a tag) and `names()`. `PUT /reports/guests/{phone}` takes `name?` (at
  most 200 letters, tidied; with unchanged tags it is `rename`, so who put the tags on stays) and answers
  as before. `GET /reports/guests/{phone}` answers a tagged number with no visit as 200 with its row and
  an empty `latest`; 404 `no_guest` is for a number with neither a visit nor a tag. App:
  `GuestsReport.tagged` and `everyone`, `Guest.ordered`; each `GuestTag.guests` is counted over both
  lists as the answer is read; `withKept` drops a tagged guest left with no tag; `PosApi.keepGuest(name:)`
  and `GuestEditDialog.tags(name:)`, which `tagGuestHere` hands the name of the reservation or the party.
- Wire (`backend/src/pos/api/guests.py`), all with the token of a session that holds `guests`:
  `GET /reports/guests` answers `{first, last, days, regular_visits, regular_days, lapsed_days, new_days,
  note_max, tag_max, tags_most, now_ms, guests, totals, tags}`, each guest `{phone, name, note, tags,
  visits, spent, per_visit, last, first, since_ms, orders_ever, lately, regular, lapsed, new, favourites}`,
  the one who spent most first, and `tags` a list of `{tag, guests}` (and `tagged`, below).
  `GET /reports/guests/{phone}` answers `{guest, note_by, note_ms, tags_by, tags_ms, latest}`, or 404
  `no_guest` for a number with no visit in the year and no tag. `PUT /reports/guests/{phone}` takes
  `{note?, tags?, name?}` (what is left out stays as it is) and
  answers `{phone, note, note_by, note_ms, tags, tags_by, tags_ms}`; it writes only what changed, under
  the session's name; 422 `bad_value` for a tag too long, too many tags or no phone number (nothing is
  written then), 503 `read_only` on a standby. Tags that changed tell the change feed `reservations` and
  `waitlist` (the screens that show them read again); a note alone tells nobody.
- App: `lib/guests_report.dart` (`GuestsReport`, `Guest`, `GuestDetail`, `GuestVisit`, `GuestList`,
  `guestsOf`, `GuestSort`, `sortedGuests`, `guestsNamed`; for the tags `GuestTag`, `GuestKept`,
  `guestsTagged`, `tidyTags`, `GuestsReport.keeps` and `withKept`), `lib/screens/guests_screen.dart`
  (`GuestsScreen`), `lib/screens/guest_edit_dialog.dart` (`GuestEditDialog`), `PosApi.guestsReport` (which
  waits 90 seconds), `PosApi.guestDetail` and `PosApi.keepGuest`. The lists, the order and the search are
  worked out in the app from the one answer; a guest is read closely when opened; what was saved is put
  into the list on the screen without reading the year again. `keeps` is false with a hub that sends no
  `tags`, and then nothing offers to write.
- Where the order is taken: `customer_card` (`backend/src/pos/customers.py`) reads the number's tags from
  the same store for `GET /customers/lookup`, the words alone; the app's `CustomerCard.tags`
  (`lib/customers.dart`) shows them with `GuestTagMark` (`lib/screens/guest_tag_mark.dart`) on the to-go
  form and in the order screen's strip. That call has no token, as it never had, and it writes nothing.
- At the host stand: `with_tags(rows, carried)` (`guest_tags.py`) answers each row with the `tags` its
  `phone` carries, compared by `phone_digits`, from one reading of `GuestTags.all()`. `tagged()` in
  `backend/src/pos/api/reservations.py` and in `backend/src/pos/api/waitlist.py` puts them on every
  reservation (`booked`, `earlier`, `booking`, and `booked` of `GET /reservations/caller`) and every party
  (`waiting`, `earlier`, `party`) as the answer is made; nothing is stored with either, and the floor's
  `holds` carry none. App: `Booking.tags` and `WaitParty.tags` (empty from an older hub), shown with
  `GuestTagMark` by `_BookingCard`, `_BookingSheet`, `_PartyCard` and `_PartySheet`.
- Tagging from the host stand: `GET /reports/guests/tags?phone=` (the same token; declared before
  `/reports/guests/{phone}`, which would take "tags" for a number) answers `{tags, tag_max, tags_most,
  phone, carried, tags_by, tags_ms}`: the tags on offer counted over every number that carries one, and
  what this number carries now. It reads no order, and the number need not have ordered; 422 `bad_value`
  for a `phone` that is no number. The save is `PUT /reports/guests/{phone}` with `tags` alone, as from the
  list. App: `TagBox` (`lib/guests_report.dart`), `PosApi.tagBox` (null from an older hub, which answers
  404); `lib/screens/tag_guest.dart` (`tagGuestHere`: `ManagerPinDialog` with the power `guests`, then
  `GuestEditDialog.tags`, the box without the note; `canTagGuest`, `tagsSavedWords`); `_Do.tags` in
  `reservations_screen.dart` and `waitlist_screen.dart`, which take the `device` the PIN is asked with and
  read again after a save.
- At the table: `GET /orders/{order_id}/tags` (`backend/src/pos/api/guests.py`, no token, like the call
  below) answers `{order_id, tags}`: the tags of the numbers of every reservation and every waitlist
  party that was seated with this check's id, each once, by the alphabet (`tags_together` in
  `guest_tags.py`). Seating already keeps the id (`POST /reservations/{id}/seat` and
  `POST /waitlist/{id}/seat` take `order_id`; a party that joins a table is seated with that table's
  check); `Reservations.seated_on(order_id)` and `Waitlist.seated_on(order_id)` find them among today's
  and yesterday's, so a check still open after the night is found. It reads no order, writes nothing and
  answers no tags for an id it does not know. App: `PosApi.tableTags` (empty from an older hub, which
  answers 404; null when nothing answers, so the screen keeps what it has); `_OrderScreenState
  ._readTableTags` asks for a check with a table when it opens or is first read, when the change feed
  says `reservations` or `waitlist` (seating and a tag change both tell them), and every 30 seconds;
  `_guestTags` puts them after the tags of the check's own number in `_CustomerStrip`.
- A call that rings: `GET /customers/tags?phone=` answers `{phone, tags}` and nothing else of the customer
  (no name, no note, no orders), with no token, like the lookup. App: `PosApi.customerTags` (empty for a
  short number, no answer or an older hub); `PhoneBar.tagsOf`, which `lib/main.dart` hands over only while
  somebody is signed in; `_PhoneBarState._askTags` asks once for a ringing number and drops an answer that
  comes after the call moved on; `_RingingBanner.tags`.
- Tests: `backend/tests/orders/test_guests.py`, `backend/tests/orders/test_guest_tags.py`,
  `apps/pos_app/test/guests_report_test.dart`, `apps/pos_app/test/guest_tags_test.dart`,
  `apps/pos_app/test/customers_test.dart` (the form and the strip),
  `apps/pos_app/test/guest_tags_host_test.dart` (the call, the book and the waitlist),
  `apps/pos_app/test/tag_guest_test.dart` (tagging from a reservation or the waitlist),
  `apps/pos_app/test/guests_tagged_test.dart` (tagged guests with no order, in the list),
  `apps/pos_app/test/table_tags_test.dart` (the tags on the check of a table).
