# Catering orders and the orders ahead

An order taken today for another day: Saturday's lunch for thirty, a party tray for next Friday, or just a
phone order for tomorrow at noon. It is rung up like any to-go order, with the day it is for, what the
event needs, and a deposit if one is taken. One screen, **Orders ahead**, lists everything that was
promised for a later time, by day, with what was paid on each. Each day has a **prep list**: what its
orders need made, added up dish by dish for each station. And a catering order prints a **pack sheet**
with its tickets: every dish with a box to tick as it goes in the bag.

## Taking a catering order

On the list of checks, tap **To go**. The form is the to-go form (`counter-mode.md`), with one more
channel beside Counter and Phone: **Catering**.

With Catering picked, the form asks for:

- **The day and the time it is for.** Today, Tomorrow, or **Another day**, which opens a calendar (up to a
  year ahead). Then the time. A catering order always names its time, so the "For later" switch is not
  asked.
- **Guests**: how many it feeds.
- **Pickup** or **Delivery**. For a delivery, the address (already filled in when the number had an order
  delivered before, `delivery.md`).
- **A note for the event**: whatever the kitchen or the driver must know ("set up by 11:30, side door").

Only the name and the time must be filled in. **Start** opens the order, and the dishes are rung in from
the menu as on any order.

Any other to-go order can be for a later day too: turn **For later** on, and the same three day buttons
are there.

## The order's screen

An order for later has a line under its bar: **For Sat 21 Nov 12:00**, and on a catering order the guests,
pickup or delivery, the address and the note. Tap the line to change any of it: the day, the time, or the
event's details. The check's history keeps who changed what.

At the right end of that line is the button that prints the order's **pack sheet** (see below): the
ticked list on a phone, the same with the words **Pack sheet** on a wide screen.

The title says the day too when the order is not for today.

## A deposit, and the rest

**Pay & send** sends the order to the kitchen. On a catering order, and on any channel that may pay at
pickup, the box **Amount taken now** starts at the whole amount and can be changed: anything less is a
deposit, and the dialog says what stays due. Choose **Cash** or **Paid elsewhere** (a card taken on the
card machine, a check), or **Later** to send it with nothing taken.

A catering order can always be sent with money still to collect. A counter order still pays the whole
before it is sent, as before.

After that, the foot of the check says what is **Due**, with a **Pay** button beside it:

- on an order for later, also before it is sent, so a deposit can be taken on Monday and the order sent
  on Thursday once the menu is final;
- on any to-go order the kitchen already has, so a phone order that pays at pickup can be paid at pickup.

**Pay** takes money and does nothing else. Any part of what is due can be taken, as often as needed. Each
payment is its own line on the check, with who took it.

Every payment is recorded on the day it is taken. Nothing here takes a payment back: giving a deposit
back is not built (payments are parked).

## What the list of checks says

- An order for another day says the day: `for Sat 21 Nov 12:00`, `for tomorrow 12:00`.
- An order a deposit was taken on says what is left: `$45.01 due`. Paid up, it says `paid`; with nothing
  taken, `pay at pickup`, as before.
- The **Unpaid** chip counts every open to-go order with money still to collect, a part-paid one included.
- **Picked up** on an order with a deposit and a balance asks for the rest first: **Cash**, **Paid
  elsewhere**, or **Not now**, which hands the order over with the rest still due. Either way the check
  closes. (An order nothing was paid on closes at once, as before: open it and tap **Pay** to take its
  money first.)

## Orders ahead

On the list of checks: the menu (or the button in the bar on a wide screen), **Orders ahead**. Anyone
signed in can open it.

It lists every to-go order a customer named a time for that has not been handed over, by the day it is for,
the earliest first.

Each day says how many orders and guests it has, and adds its orders up: **Total**, and once money was
taken, **paid** and **due**. At the right of each day is **Prep list**, which opens what that day's
orders need made (see below).

Each order says:

- the time, the name, how it was taken and its number, and what it comes to;
- on a catering order, the guests, pickup or delivery, the address and the note;
- its dishes, and the phone number;
- **Not sent** in red when nobody sent it to the kitchen (or `2 not sent` when some dishes were added
  later and not sent): no ticket prints for those when the time comes;
- the money: **Nothing paid**, **Paid $20.00 · due $45.01**, or **Paid**.

Tap an order to open it.

What stays on the list, and how long:

- An order paid in full and closed stays until its time has passed: it is still Saturday's food.
- An order that is late and still open stays under the day it was for, marked **not closed**, until
  somebody closes it.
- **Picked up** takes an order off it. So does voiding it.
- A time after midnight and before four in the morning belongs to the evening before, as in the reports.

The list changes by itself when an order changes on any screen.

## The kitchen ticket

An order sent ahead prints nothing when it is sent. The hub keeps it and prints its tickets when the time
comes (`printing.md`, "Orders sent ahead"). For a catering order that is **60 minutes before its time**
to start with. A manager changes it under **Location › Quote times**, in the row **Catering**.

A ticket for another day says the day: `READY BY 12:00  SAT NOV 21`. The takeout station's copy says
`NOT PAID  $45.01` with what was paid so far, or `PAID`.

## The pack sheet

The paper a catering order is packed and checked by. It is one sheet for the whole order, beside the
kitchen's tickets, which are as they were.

It says, from the top:

- `PACK SHEET`, the order's number and the name, large;
- `FOR 12:00  SAT NOV 21`, always with the day;
- `DELIVERY` or `PICKUP`, large, and for a delivery the address;
- how it was taken, the guests and the phone number;
- the note for the event;
- the money, as on the takeout ticket: `NOT PAID  $45.01` white on black with what was paid so far, or
  `PAID`;
- the allergies on the order, white on black;
- **every dish with a box to tick**, `[ ] 6 x 左宗鸡 (Qt)`, in the kitchen's own words as its tickets
  have them, each with its choices, its note and its allergy;
- under a black bar `NOT SENT TO THE KITCHEN`, any dish on the order that nobody sent: it is on the sheet
  so it is not forgotten, and under the bar so nobody waits for the kitchen to make it;
- how many dishes there are to pack;
- `ALSO IN THE BAG`: the answers to the to-go question (chopsticks, forks, sauces), or `NOTHING`;
- `Packed by ____` and `Checked by ____`, to sign.

**When it prints by itself.** With a catering order's first tickets: when the hub prints them at the
order's time less its quote, or at once for a catering order sent inside that time. One sheet an order:
dishes added after that print their own tickets and no second sheet.

**Where.** At the station to-go orders are packed at (the takeout station under **Location › Printers**),
else where the bills print.

**Printing one again, or for another order.** The button at the end of the line under the order's bar
prints the sheet as the order stands at that moment, as often as wanted, also before the order was sent
and after it was closed. It works on any to-go order for later, a phone order for tomorrow included; only
a catering order gets one by itself. An order for now has no such line: its takeout ticket already lists
the whole order.

**Turning it off.** **Location › Printers**, the switch **Print a pack sheet with a catering order**. On
to start. Off, none prints by itself; the button still prints one.

A voided order prints none. A screen set to skip the takeout station (`ticket-skips.md`) gets no sheet by
itself either.

**A label for each box or bag.** **Labels** beside the order's total prints a slip for each one, "BAG 2 OF
9", at the same printer: see `bag-labels.md`.

## The prep list

What one day's orders ahead need made, added up. Chen's six quarts of General Tso's and Park's four are
one line, `10 x`, at the station that cooks them.

**Orders ahead**, then **Prep list** at the right of a day. Anyone signed in can open it: it says dishes,
never money.

- The top line adds the day up: `3 orders · 38 guests · 17 dishes`.
- A red line says when dishes on the day's orders were **not sent to the kitchen yet**. They are counted
  in the list all the same, since somebody has to make them: the line is there so someone sends them.
- The day's orders, the earliest first: the time, the name, the guests, pickup or delivery, and how many
  dishes.
- Then one block for each station that cooks for the day, in the order the menu has them: each dish with
  how many, in the kitchen's own words. Under a dish, **how some of them are wanted** when not plain
  (`3 × Extra spicy, Brown rice`, `1 × no onions`); the rest are plain. A dish that is a part of a
  combination says which (`with 4 Pu Pu Platter`).
- When the day's orders are for more than one time, each dish says by when the first is wanted
  (`by 12:00`).

The orders on it are the day's orders of **Orders ahead**, no more and no fewer: an order handed over or
voided is gone from both. The list changes by itself as orders change.

**Printing it.** The printer button in the bar prints the same list where this screen prints its bills
(the screen's own choice under Settings, else the location's bill printer). The paper has the day, the
orders, and each station's dishes under the station's name.

The station that packs to-go orders is not on the list for dishes another station cooks: it packs them,
it does not make them.

## In the reports

Nothing new, and nothing left out. The sale counts on the day the order is for; a deposit is money on the
day it was taken, and the day report says how much of a day's money was "for checks of other days"
(`day-report.md`). The number of guests on a catering order is not counted as covers, and no automatic
charge goes by it.

## What it does not do

- No invoice or quote by email, and no contract to sign.
- No delivery fee by itself: add a charge on the check where one is due.
- No refund of a deposit.
- No orders coming in from a catering website.
- The prep list is one paper for the day: it does not print each station its own part at that station's
  printer, and it counts dishes, not ingredients (no recipes, no pounds of chicken).
- The pack sheet and the prep list print at one printer each: no picker to send one somewhere else.
- No labels for the trays.

## For developers

- Order fields (`backend/src/pos/sync/oplog.py`, `ORDER_FIELDS`): `event_guests`, `handover` (`pickup` |
  `delivery`), `address`, `event_note`. The head count is not `guests`, which the reports count as covers
  and the automatic charges go by.
- `GET /orders/ahead` (`backend/src/pos/orders/ahead.py`): `{today, days: [{day, orders, count, guests,
  unsent, total, paid, due}]}`. No token, like the list of orders. Nothing is stored for it: every figure
  is the check as the hub reckons it.
- `GET /orders?brief=true` adds `due` to a to-go order that took money (`Dues` in `api/app.py`, a memo by
  the state of the order's log).
- Quote times: `minutes.catering`, 60 by default; a location that saved its quote times before keeps the
  default.
- App: `lib/orders_ahead.dart`, `lib/screens/orders_ahead_screen.dart`, `lib/screens/event_fields.dart`
  (`WhenPicker`, `EventFields`, `WhenDialog`), `PayDialog` (`partial`, `sends`, `handover`), `EventDetails`
  and `whenFor` in `lib/takeout.dart`, `owes` and `moneyWords` in `lib/to_go_stages.dart`.
- The pack sheet: `backend/src/pos/printing/pack.py` (`PackSheet`, `render_pack`); `PrintService.pack_sheet`,
  `print_pack`, `pack_printer` and `_pack_with` (the one that comes by itself, from `on_ops` and
  `release_due`; its job id is the send's key with `:pack`). `POST /orders/{id}/pack-sheet` `{printer}`
  answers 202 `{job_id, printed_at}`; 409 `not_to_go`, `nothing_on_order`, `no_printer`. The switch is
  `pack` in `GET/PUT /settings/tickets`.
- The prep list: `backend/src/pos/printing/prep.py` (`prep_list`, `render_prep`), `api/prep.py`.
  `GET /orders/ahead/prep?day=` answers `{day, today, orders, count, guests, dishes, unsent, stations:
  [{station, name, rows: [{label, header, qty, first_ms, ways: [{qty, choices, depths, note}]}]}]}`; no
  token, and nothing stored. `POST /orders/ahead/prep/print` `{day, printer}` answers 202; 409
  `nothing_to_prep`, `no_printer`. Its orders are those of `is_ahead` whose time falls on the day of
  service.
- App: `lib/prep_list.dart`, `lib/screens/prep_list_screen.dart`, `_WhenStrip` in
  `lib/screens/order_screen.dart` (the pack sheet button), `PosApi.prepList`, `printPrep`, `printPackSheet`.
- Tests: `backend/tests/orders/test_ahead.py`, `test_prep.py`, `backend/tests/printing/test_pack.py`,
  `apps/pos_app/test/catering_test.dart`, `prep_test.dart`.
