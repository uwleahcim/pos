# The guest list

Every customer who ordered with a phone number in the last 12 months, on one screen: how often they came,
what they spent, when they were last here and what they order most. Three lists are picked out of it: the
**regulars**, the guests who **stopped coming**, and the **new** ones. It is for a manager. It reads the
orders and changes none of them; the two things written here are a guest's **tags** and their **note**.

Since 16 November 2026 (the Toast comparison, row 30). Since 23 November 2026 the tags are put on here
and shown where that guest's call and order are taken, and the note is written here too. It grows out of
the customers the to-go form already remembers by their number (`customers.md`): nothing is typed in for
the list itself.

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
"See the guest list" to (`roles.md`). The note can still be written on the to-go form by whoever takes
the call, as before.

### Where the tags show

- **Here**, under the guest's name and as a list of its own.
- **On the to-go form**, the moment that guest's call is answered or their number is typed: small labels
  under the line that says how often they ordered, over the note (`customers.md`, "On the to-go form").
- **On their order**, in the slim strip under the app bar, before the note, for whoever rings the dishes
  in (`customers.md`, "On the order").

On the form and on the order they are only read, by anyone who takes the call or the order. So **keep a
tag to what the staff may read**: "VIP" and "Catering client" are good tags, and an opinion of a guest
is not. A tag is never printed, on no kitchen ticket and no bill, and nothing sends it out of the hub.

A screen asks for a customer once, when the form looks the number up or the order is opened: a tag put on
while an order is open shows the next time that order is opened.

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
- A tag or a note changes no order, no sale and no figure: not on this screen and not on any report.
- With a hub older than the tags, the list is what it was: it reads, and there is no button to write.
- The first reading after the hub starts takes it some seconds, as it reads a year of orders; after that
  it is quick until the hub is restarted. A year of 30,000 orders with a number adds up in a quarter of a
  second.

## Not built

- Sending the list out of the POS (a file, a print, an e-mail).
- The tags on the strip of a call that is still ringing (it says the number and the phone company's
  name, as before; the tags come up with the to-go form when the call is answered), in the reservation
  book, on the waitlist and in the list of to-go orders.
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
  written then), 503 `read_only` on a standby. It does not go on the change feed.
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
- Tests: `backend/tests/orders/test_guests.py`, `backend/tests/orders/test_guest_tags.py`,
  `apps/pos_app/test/guests_report_test.dart`, `apps/pos_app/test/guest_tags_test.dart`,
  `apps/pos_app/test/customers_test.dart` (the form and the strip).
