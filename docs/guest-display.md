# The guest display

A screen turned to the customer that shows their order as it is rung up: each dish with its choices and
what it comes to, the tax, the total, and what was paid. The customer at the register reads along instead
of asking what that came to. It greets them by name, welcomes back a guest who has been here before, thanks
them by name when they have paid, and, where the location turns it on, suggests a tip under the total.

It is any device that runs the app: a tablet on a stand beside the register, a second screen on the Mac's
counter, a phone. It is **linked to one other screen**, the one the order is taken on, and shows whatever
order is open there. Nobody is signed in on it. It is off on every device to start.

## What the guest sees

**While an order is open on the linked screen**, that order, as the printed bill would say it:

- At the top, large, the greeting: **"Welcome back, Linda"** for a guest who has been here before,
  **"Welcome, Linda"** for one who has not (see "Greeting the guest by name" below). Under it, smaller,
  what the order is: "Order #7", "Table 12", "Bar tab".
- Where the POS has no name it can greet with, the order alone, as before: "Order #7 · Linda", "Table 12",
  "Bar tab · Sam".
- Each dish: how many, its name, what it comes to. Under it its choices, with their price where they have
  one ("Brown rice +1.00"), and a comp or a discount on the dish by its name.
- The **subtotal**, each discount and charge, and the tax as one line ("Sales tax 7%").
- The **total**, large.
- Once money was taken: each payment, the change of one paid in cash ("50.00 handed over, 7.20 change"),
  and what is still **due**, or **"Paid in full. Thank you, Linda!"** in green ("Paid in full. Thank
  you!" for a guest with no name).
- Where the location suggests a tip (see "Suggesting a tip" below): under the total, **"Suggested tip"**
  and each percentage with what it comes to, side by side ("18% $8.15", "20% $9.06", "25% $11.33"), and
  under them what they are percentages of ("On $45.30 before tax").

A dish rung in on the linked screen is on the display a moment later, and the list goes to it, so the dish
the guest just asked for is the one in view. On a wide screen lying down the dishes are on the left and the
total stands beside them; on a phone, or a tablet standing up, the total is under the dishes and stays in
view however long the order is. Everything grows with the screen.

**While no order is open there** (the list of checks, the floor, any other screen), the restaurant's name
and "Welcome". The name is the first line of the top of the bill (Location › The bill › Top of the bill),
or the location's name until any line was typed there; with neither, "Welcome" alone.

**An order that was just opened and has no dish yet** greets its guest by name already, large in the middle
of the screen: "Welcome back, Linda", with the restaurant's name under it. That is the moment a caller's
order is opened from their card, or a number is typed on a new order. With nobody to name, the welcome
stays as it is.

**When a paid order is left**, **"Thank you, Linda!"**, under it "We hope to see you again soon." and the
restaurant's name, for eight seconds; then the welcome for the next guest. ("Thank you!" for a guest with
no name.) The next order's first dish cuts it short. An order left unpaid just goes.

**Nothing else of an order is on the display.** Not who the server is, no phone number, no address, no
family name ("Linda Chen" is "Linda"), no tag and no note on the guest, not the organisation or the
certificate of a tax-exempt check, no note to the kitchen, no course, no seat. The numbers are the hub's,
the same the bill prints: the display adds nothing up.

Nothing on it can be tapped or changed, and nothing on it takes a payment, a tip or a signature. The
suggested tips are amounts to read.

## Greeting the guest by name

The name tells the guest the order on the screen is theirs, and "welcome back" that they are known here.
Nothing has to be turned on: the display greets whoever the POS already knows.

- **Who is greeted.** The guest who pays the check, as the guest list has it (`guest-list.md`): the name
  on the order (a to-go order's, a phone order's, a tab's), or at a table the party that was seated from
  the reservation book or the waitlist. A table with several parties greets the one who was said to pay;
  with nobody said, nobody by name.
- **What they are called.** The first name: "Linda Chen" is greeted as Linda. With a title, the title and
  the last name: "Mr. Wong", "Dr. Patel". A name typed in small letters or in capitals is written as a name
  ("linda" and "LINDA" are Linda); one typed with care ("McKay") stays as it is.
- **Nobody is greeted by a wrong name.** "Walk in", "Guest", "Table 5", "#12", "DoorDash" and the like are
  what gets typed where a name goes when nobody gave one: the display then greets nobody by name.
- **"Welcome back"** is said when the guest's phone number ordered here before this order, or sat at a table
  here before. It needs the number on the order: a name alone is never taken for the same person. A number
  that ordered before with no name on it is greeted "Welcome back", without a name.
- A voided order of the past does not count as a visit.

## Suggesting a tip

Off until a manager turns it on: **Location › Guest display**.

- **Suggest a tip**: the switch. Off, the display says nothing about a tip.
- **Percentages**: one to three whole percentages, 18%, 20% and 25% to start. A box left empty suggests one
  fewer. The dialog says what they come to on a $50.00 check before it is saved.
- **A percentage of**: **the check before tax** (the food and drink, less comps and discounts: no tax and
  no charge in it; the start) or **the total with tax** (the total as the guest reads it, with tax and
  with a charge such as a delivery fee).

Saved, every guest display of the location follows at once. The amounts are worked out on the hub, to the
cent, like every other figure on the display.

**No tip is suggested**

- on a check that already carries a gratuity: the gratuity added for a large party, or the tip of an online
  order. Nobody is asked twice;
- on a check with nothing to tip on (everything on it comped);
- once the check is paid in full.

On a check that is part paid the amounts stay those of the whole check, not of what is still due.

**The display only suggests.** Nothing on it can be tapped, nothing is added to the check, and the guest
tips as they do today. Taking a tip on the display belongs with payments, which are parked.

## Turning it on

1. Start the app on the register's screen, so the hub knows it.
2. On the device that faces the guest: **Settings › Guest display**. The screens the hub hears from are
   listed by their device names ("mac1", "ipad1"). Tap the register's, then **Save**.

From then on that device shows the guest display whenever nobody is signed in on it, where another device
shows the sign-in pad. Each device keeps its own link. Tapping the picked screen again, then **Save**, makes
it an ordinary screen again.

A device is one thing only: a guest display, the pickup board (`pickup-board.md`) or a station's kitchen
screen (`kitchen-screens.md`). Picking a screen to face takes the other two away, and turning either of
them on takes the link away.

Several displays can be linked to one screen. A screen cannot be linked to itself.

Set the device itself never to sleep and keep it on its charger: the app does not hold the screen awake.
(iPad: Settings › Display & Brightness › Auto-Lock › Never. Mac: System Settings › Lock Screen. Android:
Settings › Display › Screen timeout.)

## The staff's way in

The device is still a POS screen.

- **Staff**, small in the bottom corner, brings up the sign-in pad. A PIN signs in as on any screen.
- The pad has **Guest display** in its bar (an icon on a phone) to go back, and **a pad nobody touches for
  a minute goes back by itself**.
- **Signing out** puts the display back.
- **If the device locks itself when idle** (`idle-lock.md`), the display comes over what was open.
- Beside Staff the display says what it is linked to ("Linked to mac1"), and in red what is wrong when
  something is (see below).

## Good to know

- **It shows whatever order is open on the linked screen**, whoever's it is. A cashier who opens another
  customer's phone order, or a table's check, shows that order to the guest standing there for as long as
  it is open. Link a display to a screen that rings up the guests in front of it.
- **A table with several checks shows the whole table**, as the bill for the whole table does, not one
  guest's part.
- **Nobody signed in on the linked screen, nothing shown.** When the register signs out, or locks itself
  for standing idle, the display goes to the welcome although the order is still open under the pad. It is
  back when somebody signs in again.
- **The linked screen switched off or closed**: the display greets, and says in its corner "Linked to mac1,
  which is not on." A screen the hub has not heard from for a minute counts as off.
- **With the hub away** the order stays up for ten seconds (a hub that restarts is back sooner), then the
  display greets and says "The hub is not answering." A guest is not shown a total that may be behind. It
  catches up by itself.
- **Before the hub is updated** the display greets and says "The hub is older than guest displays: update
  the hub."
- **The camera signs nobody in while the display shows**, whoever stands in front of it, as at the pickup
  board: the guest's face is no business of the POS. Tap **Staff** first.
- **Leave Phone off on this device.** A call ringing shows the caller over every screen of a device that is
  a phone, and it would show over the guest's.
- **A guest who can touch the screen** can tap Staff and reach the pad and the device's Settings, as on any
  screen where nobody is signed in. Nothing of an order is behind either without a PIN.
- **The link goes by the device's name** (Settings › Device name). Rename the register and the display has
  to be linked again.
- **The name is read by the room.** Whoever stands at the register may not be whose order is open: a
  cashier who opens Linda's phone order while Sam is paying shows "Welcome back, Linda" to Sam. It is the
  first name only, and never the number.
- **A guest is known by their phone number.** A walk-in who gives a name and no number is welcomed by name
  and never "back"; ask for the number (it is also what earns points) and the next visit says so.
- The display is in English. A name is written as a name ("linda" is Linda); nothing else is changed.
- Not tried on the real devices from here.

## Not built

- Paying, tipping or signing on the display: a suggested tip is read, not tapped. (Payments are parked.)
- Tips suggested for some kinds of order only (to-go and not tables, say): the switch is for every check.
- The guest's points, or how many visits they made, on the display.
- A birthday or another tag of the guest on the display: tags are the staff's.
- The restaurant's logo, pictures of the dishes, specials or adverts while nothing is open.
- A switch on the register to hide an order from the display.
- Chinese on the display.
- Asking for a phone number or points on it.
- One guest's part of a split table.
- A web page for a screen with no device running the app behind it.

## For developers

- **The linked screen says, the display reads.** Every running app tells the hub which order its order
  screen has open: `POST /guest-display/showing` `{device, order_id | null}` (`Showing` in
  `lib/guest_display.dart`, started by `main.dart`; `OrderScreen` calls `open` and `close`). It is a help
  and no more: no failover, never a reason to call the hub away, said again whenever the hub is found
  again, "nothing" when the app starts, and "nothing" while nobody is signed in.
- The hub keeps it in memory (`Showing` in `backend/src/pos/guest_display.py`): the last word of each
  screen, dropped when `DevicesSeen` has not heard that screen for a minute. A change is told on the feed
  as the topic `showing`.
- `GET /guest-display?of=<device>` answers `{of, known, head, showing, order, guest, left}`. `order` is
  `guest_view(bill_for(check_for(...)))`: the printed bill's own figures as data, minus what a guest has no
  business reading; null for an order with no dish, a voided one, or one not at the hub yet. `head` is the
  bill's heading lines. `left` is the order that screen had open before, whether it is paid in full now
  and what to call its guest (`name`): an order paid and left in one tap is thanked for, by name, although
  no read saw it paid. Needs nobody signed in; answers 304 while nothing changed.
- **The greeting.** `guest` is `{name, back}` or null (`host` in `backend/src/pos/api/guest_display.py`,
  `host_view` and `greeting_name` in `backend/src/pos/guest_display.py`). The guest is `payer_of` the
  check, as the guest list has it; `back` is read from the log's index (`store.index(phone=)`: an earlier
  order that is not void) and from `check_guests.of_phone`, and kept for a minute per order and number,
  since a display reads again with every dish. It is there before the first dish. What is no name is in
  `_NO_NAMES`, a title in `_TITLES`. The app words it in `guestGreeting` (`lib/guest_display.dart`).
- **The tips.** `order.tips` is `{base, of, rows: [{percent, amount}]}` or null (`tips_of`): worked out on
  the hub from the check (`subtotal` less `discount_total`, or `total`) and the setting `guest_display`
  (`tips`, `tip_percents`, `tip_base`; `clean_guest_display` in `pos.settings`), null with a gratuity
  charge on the check, nothing to tip on, or the check paid in full. `GET`/`PUT /settings/guest_display`
  (manager token) reads and writes it; a save is told on the feed as `settings`, which the display reads
  again on. In the app: `GuestTips`, `GuestDisplayRules`, `PosApi.guestDisplayRules` and
  `saveGuestDisplayRules`, `lib/screens/guest_display_dialog.dart` (Location › Guest display).
- `lib/screens/guest_display_screen.dart`: `GuestDisplayScreen`. It reads when the feed says `showing`,
  `settings`, the order it watches (or the one left within the last five seconds, whose payment may still
  be on its way), or everything; every two seconds while the feed is away, every thirty otherwise. It draws
  again only when the answer changed.
- `Settings.guestDisplayOf` (the preference `guest_display_of`), `Settings.guestDisplay`,
  `saveGuestDisplayOf`; `Settings.stands` covers it, so `StandingGate` shows it where the pad stands and
  `FaceSignIn.standing` keeps the camera from signing anybody in.
- Tests: `backend/tests/test_guest_display.py`, `apps/pos_app/test/guest_display_test.dart`.
