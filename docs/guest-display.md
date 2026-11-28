# The guest display

A screen turned to the customer that shows their order as it is rung up: each dish with its choices and
what it comes to, the tax, the total, and what was paid. The customer at the register reads along instead
of asking what that came to.

It is any device that runs the app: a tablet on a stand beside the register, a second screen on the Mac's
counter, a phone. It is **linked to one other screen**, the one the order is taken on, and shows whatever
order is open there. Nobody is signed in on it. It is off on every device to start.

## What the guest sees

**While an order is open on the linked screen**, that order, as the printed bill would say it:

- At the top, what the order is: "Order #7 · Linda", "Table 12", "Bar tab · Sam".
- Each dish: how many, its name, what it comes to. Under it its choices, with their price where they have
  one ("Brown rice +1.00"), and a comp or a discount on the dish by its name.
- The **subtotal**, each discount and charge, and the tax as one line ("Sales tax 7%").
- The **total**, large.
- Once money was taken: each payment, the change of one paid in cash ("50.00 handed over, 7.20 change"),
  and what is still **due**, or **"Paid in full. Thank you!"** in green.

A dish rung in on the linked screen is on the display a moment later, and the list goes to it, so the dish
the guest just asked for is the one in view. On a wide screen lying down the dishes are on the left and the
total stands beside them; on a phone, or a tablet standing up, the total is under the dishes and stays in
view however long the order is. Everything grows with the screen.

**While no order is open there** (the list of checks, the floor, any other screen), the restaurant's name
and "Welcome". The name is the first line of the top of the bill (Location › The bill › Top of the bill),
or the location's name until any line was typed there; with neither, "Welcome" alone. An order that was
just opened and has no dish yet still shows the welcome.

**When a paid order is left**, "Thank you!" for eight seconds, then the welcome for the next guest. The
next order's first dish cuts it short. An order left unpaid just goes.

**Nothing else of an order is on the display.** Not who the server is, no phone number, no address, no
family name ("Linda Chen" is "Linda"), not the organisation or the certificate of a tax-exempt check, no
note to the kitchen, no course, no seat. The numbers are the hub's, the same the bill prints: the display
adds nothing up.

Nothing on it can be tapped or changed, and nothing on it takes a payment, a tip or a signature.

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
- The display is in English. Names are as they were typed.
- Not tried on the real devices from here.

## Not built

- Paying, tipping or signing on the display. (Payments are parked.)
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
- `GET /guest-display?of=<device>` answers `{of, known, head, showing, order, left}`. `order` is
  `guest_view(bill_for(check_for(...)))`: the printed bill's own figures as data, minus what a guest has no
  business reading; null for an order with no dish, a voided one, or one not at the hub yet. `head` is the
  bill's heading lines. `left` is the order that screen had open before and whether it is paid in full
  now: an order paid and left in one tap is thanked for although no read saw it paid. Needs nobody signed
  in; answers 304 while nothing changed.
- `lib/screens/guest_display_screen.dart`: `GuestDisplayScreen`. It reads when the feed says `showing`,
  `settings`, the order it watches (or the one left within the last five seconds, whose payment may still
  be on its way), or everything; every two seconds while the feed is away, every thirty otherwise. It draws
  again only when the answer changed.
- `Settings.guestDisplayOf` (the preference `guest_display_of`), `Settings.guestDisplay`,
  `saveGuestDisplayOf`; `Settings.stands` covers it, so `StandingGate` shows it where the pad stands and
  `FaceSignIn.standing` keeps the camera from signing anybody in.
- Tests: `backend/tests/test_guest_display.py`, `apps/pos_app/test/guest_display_test.dart`.
