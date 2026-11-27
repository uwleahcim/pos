# The pickup board

A screen facing the pickup shelf that tells the customers where their order is. It lists the to-go orders
the kitchen is making and the ones that are ready, each by its **number** and a **first name**. A customer
waiting reads it instead of asking at the counter.

It is any device that runs the app: a tablet on the shelf, a Mac with a television on it, a phone. Nobody
is signed in on it. It is off on every device to start.

## What the customers see

Two lists:

- **Being made**: the orders the kitchen has.
- **Ready**: the orders on the shelf, in green.

On a wide screen the two stand side by side, Being made on the left. On a narrow one (a phone) Ready is
first, because that is what a customer looks for, and Being made is under it.

Each order is one tile: its number large, the first name under it. The tiles are in the order of their
numbers, the lowest first, so a customer finds theirs where they expect it. Everything grows with the
screen, so a television across the room reads as well as a tablet at arm's length. A list with nothing in
it says so ("Nothing is ready yet.").

**Nothing else of an order is on the board.** No dishes, no prices, no paid or not paid, no phone number,
no family name. "Linda Chen" is "Linda"; "Mr. Wong" is "Mr.". An order with no name is its number alone.

## What is on it, and when

The board follows the stages the staff already use on the list of checks (`counter-mode.md`):

| On the list of checks | On the board |
| --- | --- |
| Being rung up, not sent yet | Not on it |
| Sent ahead for a later time, its ticket not printed yet (**Later**) | Not on it |
| With the kitchen (**Cooking**) | **Being made** |
| Marked **Ready** | **Ready** |
| **Picked up** | Off it |

- It changes by itself, a moment after the staff tap **Ready** or **Picked up** on any screen.
- An order sent ahead for 6:30 comes onto the board when its ticket prints in the kitchen, with nobody
  touching anything.
- A table's check and a bar tab are never on it. Nor is an order that is delivered (`delivery.md`):
  nobody stands at the shelf waiting for it.
- Nothing on the board can be tapped or changed. It only shows.

## Turning it on

On the device that faces the shelf: **Settings › Pickup board**, turn the switch on, then **Save**. Each
device keeps its own switch. A device is the pickup board or a station's kitchen screen
(`kitchen-screens.md`), never both: turning the board on takes the device's stations away.

From then on that device shows the board whenever nobody is signed in on it, where another device shows
the sign-in pad.

Set the device itself never to sleep and keep it on its charger: the app does not hold the screen awake.
(iPad: Settings › Display & Brightness › Auto-Lock › Never. Mac: System Settings › Lock Screen. Android:
Settings › Display › Screen timeout.)

## The staff's way in

The device is still a POS screen.

- **Staff**, small in the board's bottom corner, brings up the sign-in pad. A PIN signs in as on any screen,
  and so does a face where the location signs in by face: the camera looks for as long as the pad is up.
- The pad has **Pickup board** in its bar (an icon on a phone) to go back.
- **A pad nobody touches for a minute goes back to the board by itself**, so the shelf's screen never
  stays on a PIN pad because somebody tapped Staff and walked off.
- **Signing out** puts the board back.
- **If the device locks itself when idle** (`idle-lock.md`), the board comes over what was open. Staff and a
  PIN bring it back as it was.
- To turn the board off: **Staff**, the gear, the switch, **Save**.

## Good to know

- **With the hub away** the board keeps its last picture and says at the bottom "This board may be behind:
  the hub is not answering." It catches up by itself when the hub is back.
- **The camera signs nobody in while the board shows**, whoever stands in front of it: a server walking
  past the shelf is not signing in, and a board that signed them in would show the customers the orders
  screen. No picture leaves the device meanwhile. Tap **Staff** first; a sign-out, or the camera no longer
  seeing the person, puts the board back, and it stays. A board that locked itself is not unlocked by a
  face walking by either.
- **A tag held to the reader** signs in straight from the board: that is somebody asking.
- **Leave Phone off on this device.** A call ringing shows the caller over every screen of a device that is
  a phone, and it would show over the board.
- **A customer who can touch the screen** can tap Staff and reach the pad and the device's Settings, as on
  any screen where nobody is signed in. Nothing of an order is behind either without a PIN. Put the screen
  out of reach, or behind glass, if that matters.
- **Every to-go order has a number.** Should one have none, its first name stands where the number would.
- **Two customers with the same first name** are told apart by their numbers, which is why the number is
  the large one.
- The board is in English. The names are as they were typed on the order.
- Not tried on the real devices from here.

## Not built

- The time an order was promised for, or how long it has waited.
- A sound or a flash when an order turns ready.
- The restaurant's name or logo on the board.
- Taking an order off the board when it has sat ready for a long time: it leaves with **Picked up**.
- Chinese on the board.
- A board for the dining room's tables.
- A web page for a television with no device running the app behind it.

## For developers

- App only: the hub is not changed. The board reads `GET /orders?status=open&brief=true`, which needs
  nobody signed in, when the hub's change feed (`GET /live`) says an order changed, and every few seconds
  while the feed is away.
- `lib/pickup_board.dart`: `boardOf(orders, now)` (the two lists, from `inChip(ToGoChip.cooking | ready)`
  of `to_go_stages.dart`, so the board and the chips can never disagree), `firstName`, `boardChanges`
  (the next moment an order sent ahead starts cooking: the board looks again then, not by the second).
- `lib/screens/pickup_board_screen.dart`: `PickupBoardScreen` (draws again only when what the board says
  changed). `lib/screens/standing_gate.dart`: `StandingGate`, which stands where the sign-in pad stands, in
  the home and in the `LockLayer`, and shows the board (or a station's kitchen screen) or the pad.
- `Settings.pickupBoard` (the preference `pickup_board`), `savePickupBoard`. `SignInScreen.onBoard` is the
  pad's way back.
- The camera and the board: `FaceSignIn.standing` (`kitchen-screens.md`, For developers).
- Tests: `apps/pos_app/test/pickup_board_test.dart`, and `standing_faces_test.dart` for the camera.
