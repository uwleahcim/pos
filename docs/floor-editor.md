# The floor editor

Mike asked (2026-11-27) for a full featured floor editor. A manager draws the floor in the app: tables are
moved, sized and turned on the plan itself, new ones come ready-made, and rooms are added, named and taken
off. Until now the plan was a file on the hub that only a developer changed.

**Location › Floor plan.** A manager's PIN opens Location, as for every setting there.

Nothing reaches the floor until **Save**. The Save bar comes up at the bottom as soon as something is
changed, and leaving with changes waiting asks first. Once saved, every floor map on every device redraws
at once. The plan stays where it is on the screen all the while: as the bar comes up, as it goes, and
after Save, made larger or not.

## On the plan

- **Tap a table to pick it.** It is outlined, and the list beside the plan (under it on a phone) shows
  everything about it.
- **Drag a picked table to move it.** It goes as far as the finger does. Near a neighbour it settles on the
  neighbour's line (its edge or its middle) and a thin line shows what it lined up with; with no neighbour
  near, it settles on a fine grid. Only the tables around it count: a table does not line up with one at
  the other end of the building.
- **Drag the handle at its corner to size it**, about its middle. A round table stays round.
- **Drag the knob above it to turn it.** It stops on every fifteenth degree it comes near. Where a table
  stands at the top edge of the screen the knob is under it.
- **A finger on a table that is not picked moves the plan**, not the table, so looking round a full floor
  moves nothing by accident. **Two fingers make the plan larger**; the buttons at the bottom left do too,
  and the middle one shows the whole plan again.
- **With a mouse**, a drag on any table picks it and moves it, the wheel makes the plan larger, and holding
  Command (or Control) lets a table stand anywhere, off every line.
- **Undo and Redo** are at the top: every change can be taken back, as far as the plan that was opened.

## In the list

**One table picked:**

- its **name** (up to 8 letters and figures, `-` and `_`),
- **seats**,
- **shape** (straight sides or round), and **kind** (table, booth, bar seat),
- its **room**,
- its **size** by the number, and its **turn**: 15° either way, Straight, On its corner,
- **Copy** (the copy stands beside it, as large and turned the same, with the next name of its room) and
  **Take off**.

**Several tables picked.** The button with the ticked squares at the top makes each tap add a table to
what is picked; a room's tables are picked together from the list of rooms, and **Pick every table** is in
the menu. Dragging one of them moves them all. The list then has:

- **Line up**: left edges, middles, right edges; top edges, middles, bottom edges.
- **Space evenly**, across or down (three tables or more), and **Same size as the first**.
- Their room and their turn, Copy and Take off.

**Nothing picked:**

- **Add a table**, ready-made: a table for 2, for 4, a table for 4 on its corner, a long table for 6, round
  tables for 4 and 8, a booth for 4, a long booth for 8, a round booth for 6, a seat at the bar. It is put
  down on free floor in the middle of what the screen shows, in the room there, named next in that room
  (A10 after A9), and picked: bring the bar to the middle of the screen first, and the new seat is at the
  bar.
- **Rooms**: add one, tap its name to rename it, move it earlier or later in the row of rooms above the
  floor map, pick its tables, and take it off once it has none. The plan keeps at least one room. A room
  has no outline of its own to draw: it is as large as its tables reach.

On a phone the bar between the plan and the list puts the list away, so the plan has the whole screen, and
brings it back.

## A table in use

A table with an open check, or one a reservation still to come holds, wears a small lock. It **can be
moved, sized and turned**. It **cannot be renamed or taken off**, and the list says why ("A7 has an open
check"). Close or move the check, or give the booking another table, first.

This is because **a table's name is what its orders carry**. A table that is renamed is a new table by its
new name to the hub: the checks of the past keep the old name, as they were printed.

The hub checks the same thing at the moment of saving: if somebody opened a check at a table while it was
being taken off the plan, the save is refused and the Save bar says which table.

## What keeps a plan from being saved

The Save bar says it in words, and Save waits: two tables with one name (in any letters: A9 and a9 are
one), a table with no name, a name too long or with other characters, two rooms with one name, a room with
no name. Tables standing on each other's ground are outlined in red, and may be saved: a plan is sometimes
drawn that way on purpose.

## The original plan

**Put back the original plan**, in the menu at the top, takes the floor back to the plan the hub came
with, after asking. It is refused while a table that plan does not have is in use.

## To install

The hub first, then the apps:

1. On the hub: `sudo hubctl update`
2. Rebuild the apps on every device.

An app on a hub older than the editor says so on the Floor plan page ("update it first") and changes
nothing.

## Not done

- A room has no walls to draw, and there are no doors, plants or labels to place: the plan is tables and
  rooms.
- A table is not dragged from the list onto the plan: a new one is put down on free floor and moved from
  there.
- There is no box drawn round tables to pick them: several are picked one tap at a time, by room, or all.
- A long press does not pick a table up: a tap picks it, and then a drag moves it.
- The size of a table is in the plan's own units, as the hub's file has them (a four-top is 55 across).
  They are not feet or inches.
- None of this was tried on the restaurant's own devices or its hub: it was built and checked with the
  restaurant's real plan in tests, and with pictures at the sizes of a phone, a tablet and a Mac.

## For whoever works on it

- **Hub.** The edited plan is a location setting, `floor_plan` (`pos.settings`), so it is kept and copied
  like the others; `pos.floor.plan_of` gives the plan as it stands (the setting when there is one, the
  file otherwise) and everything that reads the floor goes through it. `pos.floor.clean_floor_plan` checks
  a plan and works out its size and each room's frame.
  - `GET /settings/floor_plan`: `width`, `height`, `rooms`, `tables` as `GET /floor` gives them, with
    `edited`, `by`, `saved_ms`, and the tables in use: `busy` (an open check) and `booked` (a reservation
    still to come).
  - `PUT /settings/floor_plan` (manager): `{rooms: [{id?, name}], tables: [{id, label, room, x, y, w, h,
    seats, shape, rotation, kind}]}`. `x`, `y` are a table's middle. A room with no `id` yet gets one from
    its name, and its tables say `"#<its place in rooms>"`. 422 `bad_value` with the reason; 409
    `table_busy` or `table_booked` when a table in use would go.
  - `DELETE /settings/floor_plan` (manager): back to the file.
  - A change tells the change feed `floor`, so every map redraws.
- **App.** `lib/floor_edit.dart` is the editor with no widgets in it: `FloorEditor` (a `ChangeNotifier`)
  holds the rooms and tables being drawn, what is picked, undo and redo, and every change the screen can
  make; `toJson` is what is sent. A table that keeps its name keeps its id; a new or renamed one is sent
  with its name as its id. `lib/screens/floor_editor.dart` is the screen: one painter draws the plan and
  one gesture moves it (`_down`, `_dragged`), the two handles are widgets over it, and `_Panel` is the
  list. It saves through `SaveBarScaffold`, as every settings page does. The room for that bar is kept
  free under the plan from the start, and the plan is not fitted again while the bar is on its way
  (`_barMoves`); the hub hands a saved plan back a margin from its corner, and the screen moves with it
  (`_save`).
- **Tests.** Hub: `backend/tests/test_floor_plan.py`. App: `test/floor_edit_test.dart` (the rules of
  editing), `test/floor_editor_test.dart` (the screen: picking, dragging with a finger and a mouse, two
  fingers, the handles, the list, rooms, a table in use, what the Save bar says, the original plan, the
  keys of a Mac, a phone).
