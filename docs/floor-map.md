# The floor map at a glance

The floor map used to draw the plan to scale and write on each table whatever fitted, as small as it took.
On a tablet that was small; on a phone the names of the tables were a few points high and the rest could
not be read at all. Mike asked (2026-11-27) for the information to be larger and easy to take in at a
glance, without losing the shape of the room. This is how the map works now. It is all in the app: the hub
and the plan are as they were.

## What you see

**Every table stands where the plan has it, and is drawn larger.** A room has more aisle than table. Each
table grows into the aisle around it until it nearly meets its neighbour, and tables of one kind grow by
the same amount, so a row of four-tops is still a row of equal four-tops. Nothing moves: the bar is still
a row of stools under the dining rooms, and C and D are still left of the main dining room.

**What a table says is written at a size that reads.** The table's name is never under 12 points and the
other words never under about 10, on a phone as on a Mac. A larger table writes larger (a name up to 22
points), but no table writes smaller to fit more in.

**A table with no room for everything says less.** What matters least at a glance goes first:

1. what the table has run up,
2. the name of the party the host seated there,
3. the booking the table is wanted for next,
4. whose table it is (the server's name),
5. how many sit there and for how long.

Before a line goes it is shortened where it can be: "4p 42m" becomes "42m", a booking's time and name
become the time alone and then the calendar by itself, and a guest's name is cut to fewer letters. The
table's own name is never left out.

**Two things are never lost, however small the table.** That a table is **booked and wanted** (the small
calendar, plain, amber or red as the time would be, `reservations.md`), and that **a guest who sits there
carries a tag** (the star, `guest-list.md`). With no room for the line, the mark stands beside the table's
name. With no room there either, it is a small mark on the table's edge: the calendar on the left, the
star on the right. They sit at the upper corners, or at the lower ones on a table whose countdown badge is
above it.

**The countdown ring** (`location-settings.md`, table timers) runs round the table's own edge as before:
it starts at twelve o'clock, drains counter-clockwise, turns amber and then flashes red. On a small table
its badge is the minutes alone ("7m", "+2m"), and the badge for dishes waiting to be carried is the mark
and the count ("2").

**Rooms.** On the map of the whole floor each room has a faint frame with its name. Tap a room's name in
the bar above the map, or tap the room's frame on the map itself, and that room is shown by itself with
its tables as large as the screen allows. The tables glide from where they were to where they now stand,
so the eye keeps its place. **Whole floor** brings every room back. Somebody who has animations turned
off on the device gets the room at once.

**On a phone** the whole floor is the overview: every table by name and colour, its ring and badges, how
long the taller tables have sat, and the marks above. Its room is one tap away and says the rest.

| Screen                    | Whole floor: no table's shorter side under | A room by itself |
| ------------------------- | ------------------------------------------ | ---------------- |
| Phone (375 to 430 wide)   | 26 points                                  | 44 points        |
| The narrowest phone (320) | 22 points                                  | 44 points        |
| Tablet on its side        | 32 points                                  | 44 and more      |
| Mac                       | 38 points                                  | 44 and more      |

(On the plan drawn to scale, a four-top on a phone was about 10 points across.) Where a small screen
cannot give every table that much room in its own place, the tables in the way give a little, and none
changes its order in its row.

**Your own text size counts.** With the device's text set larger, the words on the tables are larger too,
up to a third: more than that a table has no room for, and it would say less instead.

**No table hides under the screen's buttons.** Where **Tab** and **To go** float over the corner of the
map, the map ends above them.

Two fingers still make the map larger, and a tap, a hold, moving a table, **Mine**, the colours of the
stages and the row under the map are as they were.

## Not done

- A table cannot be made larger than its neighbours allow, so on the map of the whole floor a table
  turned on its corner says two lines at most, on a tablet too: its name, and the party with its minutes.
  Its server's name is in its room.
- On a 320-point phone the names on the tables turned on their corners are drawn a little smaller than 12
  points, and one stool of the bar stands a little out of its row.
- None of this was tried on the restaurant's own devices: it was built and checked with pictures of the
  restaurant's real plan at the sizes of a phone, a tablet and a Mac, in light and dark.

## For whoever works on it

- `apps/pos_app/lib/floor_layout.dart`: where the tables stand and how large. `FloorGrowth` (how far
  each kind of table can grow, in the plan's own units, worked out once per set of tables), `FloorLayout`
  (the tables on a screen of a given size: the scale, the smallest size a table is given there, the
  spreading that keeps their order, each room's frame) and `TablePlace` (one table as it is drawn, with
  the room across it at any height, which is what a round table and one turned on its corner go by).
  No widgets in it.
- `apps/pos_app/lib/screens/floor_view.dart`: `_TableWords` decides what a table says. Each line is a
  `_Part` with a rank (the highest goes first), the room it takes, and the shorter form that takes its
  place before it goes. Widths are worked out by the letter (`_wide`), not measured, so the same table
  says the same on every device. `_EdgeMark` is the calendar and the star on a table's edge; `_Placed`
  is the glide; `_RoomOutline` is a room's frame.
- A new thing for a table to say is a new `_Part`, with a rank among the others and, where there is one,
  a shorter form. It is never made to fit by writing it smaller.
- Nothing here follows the clock except the few words and marks that show it (`_Ticking`), and the rings
  repaint in a layer of their own, as before.
- Tests: `test/floor_layout_test.dart` (growing, fitting, no two tables in each other's way on any screen,
  the rooms' frames, the room across a table), `test/floor_readable_test.dart` (the sizes of the words,
  what a table says on a phone and in its room, the glide, large type, the marks on the edge, the
  screen's buttons), and the tests of what a table says at a size with the room for all of it
  (`floor_test.dart`, `floor_guests_test.dart`, `booked_tables_test.dart`, `table_timers_test.dart`).
