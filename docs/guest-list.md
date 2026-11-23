# The guest list

Every customer who ordered with a phone number in the last 12 months, on one screen: how often they came,
what they spent, when they were last here and what they order most. Three lists are picked out of it: the
**regulars**, the guests who **stopped coming**, and the **new** ones. It is for a manager. It reads the
orders and changes none of them; the two things written here are a guest's **tags** and their **note**.

Since 16 November 2026 (the Toast comparison, row 30). Since 23 November 2026 the tags are put on here
and shown where that guest's call and order are taken, and the note is written here too; the tags also show
on the call while it rings, in the reservation book and on the waitlist, and a guest can be tagged from
their reservation or their line of the waitlist as well. It grows out of the customers the to-go form
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
has them open.

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
- A guest tagged this way who has never ordered is **not in this list** until they do, so their tags are
  changed from a reservation or a party of theirs, not from here. Their tag still counts as one to offer.
- The reservation and the party are not touched: no time, table, place in the line or wait changes.

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
- With a hub older than the tags, the list is what it was: it reads, and there is no button to write.
- The first reading after the hub starts takes it some seconds, as it reads a year of orders; after that
  it is quick until the hub is restarted. A year of 30,000 orders with a number adds up in a quarter of a
  second.

## Not built

- Sending the list out of the POS (a file, a print, an e-mail).
- A guest who was tagged from a reservation and never ordered, in this list: there is no row for a number
  with no order, so their tags are changed from a reservation or a party of theirs.
- Tags from a reservation that ended (cancelled, no-show, seated) or a party that left: the button is on
  the ones still standing. A reservation or a party with no phone number cannot be tagged.
- Writing the customer's one-line note from a reservation or the waitlist.
- The tags on the strip of a call once it is answered (the to-go form that opens shows them), on the
  iPhone's own call screen, on a table held on the floor map, on the check of a table once the party is
  seated, on the waitlist's row of booked tables, and in the list of to-go orders.
- The restaurant's own name for a caller on the ringing strip: it still says the phone company's.
- Renaming a tag for everybody who carries it in one go, or a colour for a tag.
- Tagging many guests at once, or a guest who has not ordered in the last 12 months.
- More notes than the one line.
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
- Tags: `backend/src/pos/guest_tags.py`. `GuestTags` (memory) and `PgGuestTags` (table `guest_tag`: `phone`,
  `tags` as JSON, `updated_by`, `updated_ms`), on `app.state.guest_tags` (`app.state.tags` is the sign-in
  tags of `face-signin.md`, another thing). `clean_tags(tags, known)` is the one place a tag is tidied: one
  line, each once whatever its capitals, spelt as `known` spells it, by the alphabet, `TAG_MAX = 24`,
  `TAGS_MOST = 6`. `offered(carried, listed)` is the tags on offer with how many of the listed numbers
  carry each; `STANDARD` is the two always offered. A standby reads and does not write (`ReadOnlyError`).
- Wire (`backend/src/pos/api/guests.py`), all with the token of a session that holds `guests`:
  `GET /reports/guests` answers `{first, last, days, regular_visits, regular_days, lapsed_days, new_days,
  note_max, tag_max, tags_most, now_ms, guests, totals, tags}`, each guest `{phone, name, note, tags,
  visits, spent, per_visit, last, first, since_ms, orders_ever, lately, regular, lapsed, new, favourites}`,
  the one who spent most first, and `tags` a list of `{tag, guests}`. `GET /reports/guests/{phone}` answers
  `{guest, note_by, note_ms, tags_by, tags_ms, latest}`, or 404 `no_guest` for a number with no visit in
  the year. `PUT /reports/guests/{phone}` takes `{note?, tags?}` (what is left out stays as it is) and
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
- A call that rings: `GET /customers/tags?phone=` answers `{phone, tags}` and nothing else of the customer
  (no name, no note, no orders), with no token, like the lookup. App: `PosApi.customerTags` (empty for a
  short number, no answer or an older hub); `PhoneBar.tagsOf`, which `lib/main.dart` hands over only while
  somebody is signed in; `_PhoneBarState._askTags` asks once for a ringing number and drops an answer that
  comes after the call moved on; `_RingingBanner.tags`.
- Tests: `backend/tests/orders/test_guests.py`, `backend/tests/orders/test_guest_tags.py`,
  `apps/pos_app/test/guests_report_test.dart`, `apps/pos_app/test/guest_tags_test.dart`,
  `apps/pos_app/test/customers_test.dart` (the form and the strip),
  `apps/pos_app/test/guest_tags_host_test.dart` (the call, the book and the waitlist),
  `apps/pos_app/test/tag_guest_test.dart` (tagging from a reservation or the waitlist).
