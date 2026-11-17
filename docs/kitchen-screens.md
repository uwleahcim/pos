# Kitchen screens

A screen at a station in the kitchen that lists what the station has to make. Each ticket is the dishes of
one send of an order, in the words the paper ticket uses, coloured by how long it has waited. A cook taps a
dish when it is made, and the ticket leaves when its last dish is.

It is any device that runs the app: a tablet on the wall by the wok, a Mac with a television on it, a
phone. Nobody is signed in on it. It is off on every device to start, and **the paper tickets print exactly
as they do today**: a screen is beside the printer, not in its place.

## What a cook sees

The station's name at the top with how many tickets are waiting, and under it the tickets, **the longest in
the kitchen first**, read across and then down. A phone shows them one under the other; a tablet shows as
many side by side as fit.

Each ticket has:

- **Whose it is**: "Table 12", "Tab Priya", or a to-go order's number and name, "#14 Linda". Under it the
  server, the guests and the course of a table, or "Phone · ready 18:20" of a to-go order.
- **The minutes it has been in the kitchen**, and its colour: plain to start, **amber** after 10 minutes,
  **red** after 20. A manager sets the two numbers (see "The colours").
- **An allergy told on the order**, in a red band before anything else, and again under the dish of the
  seat it was told for.
- **Also at**: the other stations cooking for the same send, as the paper says it.
- **Its dishes**, as the station's paper ticket words them: how many, the kitchen's name of the dish, its
  choices (a choice on a choice stands further in), the note, the seat. A part of a combination says "with
  Pu Pu Platter". The choices a station does not read (`station-choices.md`) are left off, as on its paper.
- **VOID**, white on black as on paper, on a dish voided after it was sent, with its name struck out.
- **CHANGED** on a dish changed after it was sent.

## Marking what is made

- **Tap a dish** when it is made: it gets a green tick and goes grey. Tap it again to take that back.
- **Done** marks every dish of the ticket at once.
- When the last dish of a ticket is marked, **the ticket leaves the screen**.
- A **voided dish** stays on its ticket, struck out, until the cook taps it: that is "seen". A dish that
  was already marked made when it was voided does not come back.
- **Recall**, at the top, lists the last ten tickets the station finished. **Bring back** puts one back
  among the tickets, where it was.

A mark is the kitchen's own word. **It changes no dish, no price and no payment, prints nothing, and is not
a step in the check's history.** The servers' screens show nothing of it yet (see "Not built").

## What is on a screen, and when

A screen follows the paper, rule for rule:

| | On the station's screen |
| --- | --- |
| A dish rung up and not sent | Not on it |
| A dish sent | On the screen of the station that cooks it |
| A to-go order | Its dishes at the stations that cook them, and **the whole order at the takeout station** |
| An order sent ahead for a later time | On it when its paper ticket prints, not before |
| A dish sent from a screen that prints no ticket at that station (`ticket-skips.md`) | Not on that station's screen either |
| A table's check or a bar tab that was closed | Off it: the food was eaten |
| A to-go order paid and closed | **Still on it**, until it is marked Ready |
| A to-go order marked Ready or Picked up | Off it |
| An order voided whole | Off it |
| A dish moved to another check (`moves.md`) | On the ticket of the check it is on now, made if it was made |

- More dishes sent later for the same table are **a ticket of their own**, like on paper.
- **A ticket nobody marks leaves by itself after four hours**, so a screen nobody tends does not fill up.
- Each station marks its own. The wok finishing its part of a to-go order does not take it off the takeout
  station's screen: the packer marks the bag.

## Turning it on

On the device at the station: **Settings › Kitchen screen**, tap the station it stands at, then **Save**.
Each device keeps its own.

- From then on that device shows the station's tickets whenever nobody is signed in on it, where another
  device shows the sign-in pad.
- **One screen can stand for several stations** (two woks, the fryer and the range): tap each of them. Each
  dish then says which station makes it, and a dish is made when each of its stations on that screen has
  said so; a tap says it for all of them.
- **A device is a kitchen screen or the pickup board (`pickup-board.md`), never both**: picking a station
  turns the board off, and turning the board on takes the stations away.
- To make the device a plain screen again: **Staff**, the gear, tap the station off, **Save**.

Set the device itself never to sleep and keep it on its charger: the app does not hold the screen awake.
(iPad: Settings › Display & Brightness › Auto-Lock › Never. Mac: System Settings › Lock Screen. Android:
Settings › Display › Screen timeout.)

## The colours

**Location › Kitchen screens** (a manager): the minutes a ticket has been in the kitchen when it turns
amber, and when it turns red. 10 and 20 to start. 0 is never; red must come after amber. Every station's
screen follows at once.

## The staff's way in

The device is still a POS screen.

- **Staff**, at the top right, brings up the sign-in pad. A PIN signs in as on any screen.
- The pad has **Kitchen screen** in its bar (an icon on a phone) to go back.
- **A pad nobody touches for a minute goes back to the tickets by itself.**
- **Signing out** puts the tickets back.
- **If the device locks itself when idle** (`idle-lock.md`), the tickets come over what was open, and a tap
  still marks a dish. Staff and a PIN bring back what was open.

## Good to know

- **With the hub away** the screen keeps its last picture and says "This screen may be behind: the hub is
  not answering." A dish tapped meanwhile is shown as made at once and reaches the hub when it is back;
  no tap is lost. New tickets do not arrive until then: the paper is what the kitchen cooks from.
- **The minutes** are counted on the device's own clock from the moment the dish was sent. A device whose
  clock is a minute off shows the tickets a minute older or younger.
- **A location with no printer at all** can use the screens: an order sent ahead then comes onto them by
  the clock, when its ticket would have printed.
- **Signing in by face or by tag** does not run while the tickets show: the pad is not on the screen. Tap
  **Staff** first.
- **Leave Phone off on this device.** A call ringing shows the caller over every screen of a device that is
  a phone.
- The dishes are in the kitchen's words, as its paper has them (Chinese where the menu gives a kitchen
  name). The rest of the screen is in English.
- Not tried on the real devices from here.

## Not built

- **A screen in place of the paper**: turning a station's printer off because it has a screen.
- **The pass screen**: one screen for the person calling the orders, every ticket of every station with
  what each station has made. And the **all-day counts**: how many of each dish are waiting across all the
  tickets.
- **What the kitchen made, on the servers' screens**: the floor map and the check do not show a mark.
- **Ready by itself**: a to-go order is not marked Ready when its last dish is made; the staff tap Ready.
- A sound or a flash when a ticket comes in.
- How long the kitchen takes, as a report.
- Text as large as a television across the room needs: the screen follows the device's own text size.
- Chinese for the words of the screen itself.

## For developers

- **The mark** is an operation on the order, `done`, sent through `POST /orders/{id}/ops` like every other
  change (`pos.sync.oplog`): `{"station": "wok", "line_ids": ["L1", "L2"]}`, with `"done": false` to take
  it back. Each line keeps, for each station, the time of its latest word (`Line.done`, in the order's
  answer as `done: {"wok": 1800000000060}`); the latest word of a station on a dish stands, whatever order
  the operations arrive in. It syncs between hubs like the rest of the log. A line that changes checks
  carries its marks with it (`pos.orders.moves.carry_ops`).
- **A screen's list** is worked out on the hub by `pos.printing.screen.kitchen_screen`, with the paper's
  own routing (`Takes`, `_ticket_lines`, the ticket skips, the takeout station) and
  `PrintService.not_yet()` for the orders sent ahead whose tickets still wait.
- `GET /kitchen/screen?stations=wok,fryer` (one to eight station codes; nobody need be signed in, like the
  list of orders): `stations` (`code`, `name`), `warn` and `late` (minutes), `tickets` (the longest in the
  kitchen first) and `recent` (the last ten finished, the latest first). A ticket: `id` (the order and the
  moment its dishes reached the kitchen), `order_id`, `since_ms`, `table`, `tab`, `order_no`, `customer`,
  `to_go`, `channel`, `promised_ms`, `server`, `guests`, `course`, `allergies`, `also_at`, `lines` and,
  when finished, `done_ms`. A line: `line_id`, `stations` (the ones of this screen that make it), `made`
  (the ones of them that said so), `qty`, `label`, `modifiers`, `depths`, `note`, `seat`, `header`,
  `allergy`, `void`, `changed`, `done`, `done_ms`. Nothing in the answer moves with the clock, so a screen
  that asks again is answered `304` until an order or a setting changes; the terminal counts the minutes.
- `GET /settings/kitchen_screens`, `PUT /settings/kitchen_screens` (the manager Bearer token): `{"warn":
  10, "late": 20}`, whole minutes, 0 for never, at most 1440, `late` after `warn`; one left out of a `PUT`
  keeps what it was.
- App: `lib/kitchen_screen.dart` (`KitchenBoard`, `KitchenTicket`, `KitchenLine`, `markOps`, and
  `withLocal`, which lays this device's own marks over what was read until the hub shows them),
  `lib/screens/kitchen_screen.dart` (`KitchenScreen`: reads on the hub's change feed and every few seconds
  without it; opens nothing over itself, since it also stands over a locked screen),
  `lib/screens/standing_gate.dart` (`StandingGate`, which stands where the sign-in pad stands and shows the
  kitchen screen, the pickup board or the pad), `Settings.kitchenStations` (the preference
  `kitchen_stations`), `lib/screens/kitchen_minutes_dialog.dart`.
- Tests: `backend/tests/printing/test_screen.py`, `apps/pos_app/test/kitchen_screen_test.dart`. The sync
  simulations (`pos.sync.simulate`) mark dishes made among their random operations.
