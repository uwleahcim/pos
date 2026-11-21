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

## What it does not do

- It adds nothing by itself, changes no price and gives no discount. A suggested dish that is tapped is a
  dish on the check like any other: on the kitchen ticket, on the bill and in the sales.
- It prints nothing and shows nothing to the customer.
- It does not count how often a suggestion was taken. Dishes sold (`dishes-sold.md`) says what sold.
- It does not suggest by time of day, by table or by what is already on the check. One dish, one list.
- A choice inside a dish (the rice that comes with it, an extra) is not this: that is an option group
  (`modifiers.md`).

## Installing

1. On the hub: `sudo hubctl update` (first: the hub changes).
2. Rebuild the app on every device.

Nothing to import and nothing to turn on. Then set the dishes in the menu editor. An app on an older hub
suggests nothing; an app that is not rebuilt yet rings as before and leaves the lists alone.

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
