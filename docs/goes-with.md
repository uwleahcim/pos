# What goes with a dish

A manager can say, dish by dish, what goes with it: a beer with the Pu Pu Platter, rice with a dish that
comes without. Once that dish is rung in, the order screen shows those dishes right under the menu, each as
its own tile. One tap adds one.

It is only ever a suggestion. **Nothing goes on a check that nobody tapped**, and no price changes.

Since November 2026 (the Toast comparison, row 32, first half). No dish suggests anything until a manager
sets it.

## On the order screen

1. Ring a dish as always. If the menu says something goes with it, a tray opens under the dishes: **Goes
   with Pu Pu Platter**, and under that line up to four tiles.
2. **Tap a tile** to add that dish. The tile is the dish's own, as in its category: its number, its price,
   and how many of it are on the order. Tap again for another.
3. **Hold a tile** for the dish's sheet, to pick its options, a quantity or a note, as on any tile.
4. Carry on. Ringing the next dish replaces the tray with what goes with that one, or closes it when
   nothing does.

The tray also closes with its **×**, by pulling it down, by opening another category or another menu's tab,
and by typing in the search. Nobody has to answer it.

Good to know:

- A dish that asks its size or a choice first (General Tso's: pint or quart) asks as always. The
  suggestions come once it is on the order.
- A suggested dish that asks its size asks in the same tray, and the suggestions are back after the answer.
- A dish that was added from the tray suggests nothing itself. The tray stays about the dish that was rung
  from the menu, so a table that wants two of the suggestions gets both from the one tray.
- Another of the same dish leaves the tray as it is.
- A dish that is **sold out** (86), **off sale**, or on a menu that is not open now (a lunch dish at dinner)
  is not suggested. When the last suggestion sells out while the tray is open, the tray closes.
- A suggestion can come from another menu: a beer from Drinks while Food is on screen.
- While the tray slides open it takes no tap, so a quick second tap for two of the dish above cannot land
  on a suggestion.
- With a keyboard: **Down** from the dishes goes into the tray, **Enter** adds, **Escape** goes back to the
  dish and closes the tray.
- It works the same on a table's order, a to-go order, a phone order and at the counter.

## Setting it, in the menu editor

A manager: the menu editor › the dish › **Goes with**.

- **Add a dish** opens the list of every dish, with a search. Pick one.
- Up to **four** per dish: two rows of tiles on a phone. With four, the Add button is gone until one is
  taken away.
- They are shown on the order screen **in the order they were added**. To change the order, take one away
  with its **×** and add it again.
- A dish that is off sale stays in the list, marked "(not on sale)", and is suggested again once it is back
  on sale.
- A dish cannot go with itself, and not twice with the same dish.
- **Save**, and every screen suggests it within seconds.

Deleting a dish takes it out of every other dish's list.

## Suggestions taken (a report)

Since 21 November 2026. Whoever may **see the reports** (managers and owners to start, see `roles.md`):
orders screen › **Location** (PIN) › **Suggestions taken**.

It answers, for any days from one to 92: did the suggestions bring anything, with which dish, and who
takes them.

- **The days**: Today, Yesterday, 7 days, 4 weeks, or other days from the calendar. It opens on the seven
  days just gone.
- **Suggested dishes added**, and what **they were sold for**: every dish that was added from the tray
  "Goes with" in those days.
- **Who added them**: each person who rang suggested dishes in, the most first, with how many and for how
  much.
- **With which dish**: each dish something was added with, the one that brought the most first. Under its
  name: how many of it went out in those days, and how many dishes were added with it ("31 sold · 27 added
  with it"). Under that, each dish that was added, and each dish it suggests today that nobody took
  ("none").
- **Sold with nothing added**: the dishes that suggest something today and went out in those days without
  anybody adding anything. These are the suggestions to change, or to talk to the staff about.

What counts:

- **A dish added from the tray**, by a tap or from its sheet after a hold. The same dish rung from the menu
  is not counted, even on the same check: the report says what the tray brought, not what was sold. Dishes
  sold (`dishes-sold.md`) says that.
- **For whoever rang it in**, on the day of its check, at its menu price, as in "by person" in the day's
  report. A comp or a discount takes nothing from it.
- **As many as the line holds.** Two of it rung with the quantity count as two. Changing how many, or its
  options, keeps it a suggested dish, and so does moving it to another check. More of it added later from
  the check, once the kitchen has it, is a new line and not counted.
- **Not a voided dish**, not one taken off before it was sent, and nothing on a voided check.
- **"Sold"** counts every one of that dish in those days, on every kind of order. An online order has no
  tray, so a dish that sells mostly online will look as if nobody takes its suggestions.
- More than one dish can be added with one, so more can be added than were sold.
- **Counting starts with this update.** Nothing was marked before, so earlier days read as nothing added.
- A dish taken off the menu since stays in the report under the name it was sold by.

It is a report and nothing else: a suggested dish is a sale like any other, on the same ticket, bill and
sales figures as before, and reading the report changes nothing. It names the staff, so it sits behind the
manager's PIN with the other reports.

## What it does not do

- It adds nothing by itself, changes no price and gives no discount. A suggested dish that is tapped is a
  dish on the check like any other: on the kitchen ticket, on the bill and in the sales.
- It prints nothing and shows nothing to the customer.
- It does not show the report to the staff, hold it beside the days before, or count for a contest
  (`contests.md`).
- It does not say how often a person rang a dish that suggests something and added nothing: the report
  counts what was added, by person, and what was sold, by dish.
- It does not suggest by time of day, by table or by what is already on the check. One dish, one list.
- A choice inside a dish (the rice that comes with it, an extra) is not this: that is an option group
  (`modifiers.md`).

## Installing

1. On the hub: `sudo hubctl update` (first: the hub changes).
2. Rebuild the app on every device.

Nothing to import and nothing to turn on. Then set the dishes in the menu editor. An app on an older hub
suggests nothing; an app that is not rebuilt yet rings as before and leaves the lists alone.

For the report the same two steps, hub first. A screen that is not rebuilt yet still suggests, and what is
added at it is not counted until it is. On a hub that is not updated, Location's row opens a screen that
says the hub is older.

## For developers

- Menu data: `Item.attrs["goes_with"]`, a list of item codes in the order shown (`Item.goes_with` reads it
  tolerantly; `GOES_WITH_MOST = 4` in `menu/defs.py`).
- `GET /menu` says `goes_with` on that dish's entries, only dishes on sale, and only when there are any, so
  the menu reads as before for every other dish. Whether a suggestion is on a menu open now and not sold
  out is the screen's to see.
- A save refuses a list that is not a list of codes (`bad_goes_with`: also the dish itself, or a dish
  twice) and more than four (`too_many_goes_with`). `admin.apply` drops a deleted dish from every list
  (`_forget_gone_dishes`), so an app that knows nothing of the lists can delete a dish. `hubctl menu import`
  leaves a stored dish's list alone.
- App: `MenuEntry.goesWith` in `lib/menu.dart`. In `lib/screens/menu_panel.dart` the tray is the slot of
  the required-choices tray (one tray, so the two never stack on a phone): `_rung` opens it once a dish is
  on the order, `_Offer` holds what it shows, `_GoesWithSection` draws it, the grid `offer` holds its
  tiles and their focus. The editor's part is in `lib/screens/menu_editor.dart`: `goesWith`,
  `setGoesWith`, `wholeDishes`, and `removeItem` cleans the lists.
- Tests: `backend/tests/menu/test_goes_with.py`, `apps/pos_app/test/goes_with_test.dart`.
- The report. A dish added from the tray carries `went_with` on its `add_line`: the item code of the dish
  whose suggestions the tray showed (`ChosenLine.wentWith`, read in `_offeredWith` when the tile is tapped,
  sent by the order screen's `_lineData`). The hub keeps it on the line (`Line.went_with` in
  `sync/oplog.py`; anything that is not a short string is dropped), hands it on to the line that replaces
  it and to the line a move makes on another check (`CARRIED` in `orders/moves.py`), and shows it in the
  order's view. It changes no figure. `Sold.went_with` remembers it with the sale, and
  `orders/suggested.py` (`suggestions_report`) adds it up over the same remembered sales as the sales
  report: `GET /reports/suggestions?from=&to=` (the `reports` power) answers `taken`, `amount`, `dishes`
  (each with `sold`, `taken`, `amount` and `added`), `staff` and `running`. A dish that suggests something
  on the menu as it stands and sold with nothing taken is among `dishes` with `taken` 0. App:
  `lib/suggestions_report.dart`, `lib/screens/suggestions_screen.dart`, the row in
  `location_settings_screen.dart`. Tests: `backend/tests/orders/test_suggested.py`,
  `apps/pos_app/test/suggestions_test.dart`.
