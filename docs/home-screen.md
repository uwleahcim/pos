# The home screen

What everybody sees after signing in: the floor map or the list of checks, under one row of buttons. The
row holds what a service needs in one tap, and one button, **More**, opens everything else as a menu of
named tiles.

Since 27 November 2026. App only; nothing to turn on.

Before that the row held every button there was. A manager's tablet had seventeen icons with no words, an
upright iPad ran the last of them off the edge of the screen, and a phone had one long list. Each new
feature added one more.

## The row at the top

From left to right:

- **The camera's picture and your name.** The picture is the sign that the person at the screen may be
  photographed, as before. A tablet or a Mac names the device under your name
  and has **Sign out** right beside it, one tap. A small phone set to large type has room for the first
  letter of the name only, or for none; the menu says who is signed in on every screen.
- **Floor | Checks.** The switch between the floor map and the list of checks. The half that is up is
  raised and red, so the row says where the screen is; a tap on the other half goes there. A phone shows
  the two icons, a wider screen the words too. It opens on what the device is set to open on
  (`opening-screen.md`), as before.
- **Reservations, Orders ahead, Deliveries** on a tablet or a Mac: with their words while the row has the
  room for all of them (an iPad on its side, a Mac), as icons while it does not (an upright iPad). Where
  even the icons do not fit, the last of them are in the menu only. Deliveries shows where somebody takes
  deliveries out (`delivery.md`).
- **Waitlist**, with its two counts as before (`waitlist.md`): parties waiting in the round badge, booked
  tables still to come in the square one. A tablet or a Mac always has it; a phone has it while a party
  waits, and always for whoever gives tables out.
- **The connection** (the cloud), as before: a tap says what answers and what still waits to be sent.
- **More** (four squares). A red dot on it says something in the menu wants a look that nothing in the row
  says: online orders to look at, for a manager.

The row never runs off the screen: what does not fit is in the menu.

## More

On a phone the menu comes up from the bottom, where the thumb is. On a tablet or a Mac it opens under the
button, at the top right. A tap beside it, or Escape, closes it.

At its top: your name, your role and the device, and **Sign out**.

Under that, every way out of the screen as a tile with its icon and its name, in four groups. A tile is
there only where the thing is in use and the person signed in may open it, as the old buttons were.

| Group | Tiles |
| --- | --- |
| **Guests & orders** | Waitlist, Reservations, Orders ahead, Deliveries, Online orders, Shipday, Texts, Kitchen rush |
| **Shift** | Time clock, Notes, Contests, Waste |
| **Manager** | Today, Location, Menu editor |
| **This device** | Closed checks, Display, Settings |

Some tiles say what is going on behind them:

- **Waitlist** and **Reservations** carry their count on the icon ("3 waiting", "2 to come"), in amber
  when a party or a table is near its time and red when one is past it.
- **Kitchen rush** is filled while a rush runs, and says how many minutes it adds and until when.
- **Online orders** has a red dot and "Take a look" while there is something to look at.
- **Shipday** is there once the hub has a key for Shipday, and says how its deliveries stand ("2 need a
  driver", "3 out"): `shipday.md`.
- **Texts** carries the number of conversations that hold something nobody has read ("2 not read"), and
  puts the red dot on **More** while one waits (`text-inbox.md`).
- **Notes** says how many are up.
- **Closed checks** is a switch: "Hidden", or filled and "Shown in the list" (it used to be "Show closed"
  and "Hide closed"). Turned on from the floor map, the list of checks comes up, since the map shows
  nothing of them.

The tiles stand two across on a phone and three across on a tablet. Larger type (Display) gives each tile
more width and fewer to a row, so the names are never cut short; the smallest phones (320 points wide)
have one to a row for the same reason, and the menu scrolls.

## What moved

| Before | Now |
| --- | --- |
| The title "Orders · name · device" | Your name by the camera's picture; the device under it on a tablet, and in the menu |
| One button that flipped between the map and the list, showing the one it would go to | The **Floor \| Checks** switch, showing the one that is up |
| Sign out: an icon in a tablet's row, the first line of a phone's list | The same icon beside your name on a tablet; at the top of the menu on every screen |
| Waitlist | Where it was, with its word on a wide screen; also a tile |
| Reservations: in a phone's list, behind the waitlist on a tablet | A button in a tablet's row and a tile on every screen |
| Orders ahead, Deliveries: icons in a tablet's row, lines of a phone's list | Buttons with their words in a tablet's row; tiles on every screen |
| Show closed / Hide closed | The **Closed checks** tile |
| Notes, Contests, Time clock, Waste, Kitchen rush, Online orders, Shipday, Today, Location, Menu editor, Display, Settings | Tiles in the menu |

**To go** and **Tab**, at the bottom right, are where they were. So are the search and the to-go stages
over the list of checks, and the rooms over the floor map.

What costs one tap more than before, on a tablet or a Mac only: **Closed checks** and the eleven things in
the last row of the table, which are now two taps (More, then the tile) where each was an icon in the row.
**Reservations** costs one tap fewer there. A phone needs the same two taps as before for everything.

## With a keyboard

Arrows move between the buttons of the row and, in the menu, between the tiles; Enter presses the one with
the focus; Escape closes the menu. The menu opens with the focus on its first tile. A badge reader's Enter
presses nothing here either (`reader_keys.dart`).

## For developers

- `apps/pos_app/lib/screens/home_bar.dart`: `HomeBar` (the row), `ViewSwitch`, `HomePill`, and
  `HomeEntry`, one way out of the screen.
- `apps/pos_app/lib/screens/home_menu.dart`: `showHomeMenu`, `HomeMenu`, `HomeTile`.
- `orders_screen.dart` builds the list of `HomeEntry` in `build`. **A new feature adds one line there** and
  nothing else: its id, name, icon, what a tap does, and its group (`HomeSection`). `note`, `count` with
  `level`, `on` and `attention` are what its tile says; `quick: true` also puts it in a wide row, after
  the ones already there, so think twice: the row is for what a service needs in one tap.
- Tests reach an entry with `openHome(tester, 'location')` (`test/hub.dart`), which taps its button in the
  row where it stands there and its tile in the menu otherwise. The keys are `home-more`,
  `home-quick:<id>`, `home-tile:<id>`, `home-view:floor`, `home-view:checks`, `home-sign-out` and
  `home-menu-sign-out`.
- The row measures the words of its buttons with the screen's own type to decide between words and icons,
  so it adapts to the text size a person picked; nothing in it redraws on a timer.
