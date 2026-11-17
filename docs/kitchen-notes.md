# One-tap notes to the kitchen

The words a server types on a dish again and again, as buttons: **Rush**, **Split for 2**, **Well done**.
The location keeps a short list, and a dish's sheet shows it over the box where the note is typed. A tap
puts the words in the dish's note; the kitchen ticket prints them under the dish, as it prints a typed note.

Since 17 November 2026 (the Toast comparison, one-tap kitchen notes). Hub and app. The list starts with
Rush, Split for 2, Well done, Less oil, Less salt and See server; a manager makes it the location's own
under Location.

## What the staff see

A dish's sheet is what opens on a hold on its tile in the menu, or on a tap on its line of the check. Under
the choices, over **Note to the kitchen**, there is a row of buttons, one for each note the location lists.

- **A tap puts the words in the note.** The box shows the note as the kitchen will read it: "Rush".
- **Several notes** join with commas, in the order tapped: "Rush, Split for 2".
- **A tap again takes the words out.** A lit button says the note is on the dish.
- **Typing still works**, with the buttons or without: what is typed stays around what is tapped ("no
  onions, Rush"). Typing a listed note lights its button too.
- **A dish chosen inside another dish** (the entree of a combination plate, opened by a hold) has the same
  buttons over its own note.

Nothing else changes. The note is the dish's note: it prints in bold under the dish on the ticket of every
station that gets the dish, shows on the check, and is in the check's history. Changing the note of a dish
the kitchen already has prints the change, as before.

These notes are for the dish as a whole. **No**, **Extra**, **On the side** and **Light** stay where they
are, at the top of the sheet: they go on one choice ("No peanuts"), and Extra can charge.

A note never changes a price. Something the kitchen makes for money that is not on the menu is rung as
**Open Food** with its price (`off-menu-dish.md`), so it is on the bill and in the sales.

## The list (a manager)

Orders screen › **Location** (manager PIN) › **Kitchen notes**, on the card with the quote times and the
to-go question.

- One row a note, in the order the buttons show. Reword a note in its box, remove it with the bin, **Add
  note** for another.
- Twelve notes at most, 24 letters each, no two the same.
- A note holds no comma: two notes on a dish are told apart by the comma between them.
- With every note removed no button shows, and a note is typed as before.

**Save** sends the list to the hub. Every screen has the new buttons on the next dish it opens.

Rewording or removing a note changes nothing on the dishes already rung in: a dish carries the words
themselves.

## Good to know

- A screen remembers the last list it read, so the buttons are there while the hub is away.
- An app that is not rebuilt shows no buttons; its notes are typed. A hub that is not updated: the app
  shows no buttons, and Location's row says the hub is older.
- The buttons light by the whole words between two commas: "Rush" is not lit by "Rush the soup".

## Not built

- A note with a price, or one that changes where the dish prints.
- Notes that differ by station, by category or by dish (the sushi bar's own list).
- A note for the whole order in one tap (these notes go on a dish).
- Dragging the notes into another order (remove and add).
- Notes in a second language for the kitchen.

## For developers

- The setting: `kitchen_notes` in `backend/src/pos/settings.py` (`clean_kitchen_notes`): `{"notes": [...]}`.
  `GET /settings/kitchen_notes` (no token) and `PUT /settings/kitchen_notes` (manager token; 422
  `bad_value` with the reason). Nothing else on the hub changed: a tapped note is the line's `note`.
- App: `lib/kitchen_notes.dart` (`KitchenNotes`, `noteParts`, `hasNote`, `toggleNote`);
  `KitchenNoteChips` in `lib/screens/menu_panel.dart`, used by `ItemSheet` and `DishChoicesSheet`;
  `PosApi.kitchenNotes`, `saveKitchenNotes` and `kitchenNotesKnown` (the last list read, so a sheet has its
  buttons before the hub answers again; the menu panel reads it ahead once, each sheet as it opens);
  `KitchenNotesDialog` (`lib/screens/kitchen_notes_dialog.dart`).
- Tests: `backend/tests/printing/test_kitchen_notes.py`, `apps/pos_app/test/kitchen_notes_test.dart`.
