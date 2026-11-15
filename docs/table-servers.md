# Whose table it is

Every busy table on the floor map says who serves it: a small name tag under the table's name, in the
table's own colour. It is the server's first name, with an initial when there is more to the name ("Amy",
"Mike W"). A free table has no tag: nobody has it until a party sits.

A table gets its server in one of two ways (Mike, 2026-11-13).

## A server opens their own table

A server or bartender taps a free table, says how many guests, and presses **Seat**. The check is theirs and
they are taken into it. Nothing is asked about whose table it is: opening it is taking it.

## The host gives a table to a server

Someone signed in as a **host** (or a manager or owner) taps a free table and sees one more thing under the
guests: **Server**, a button for everyone who takes tables, each with what they have on the floor right now
("3 tables · 11 guests", "No tables"), so the next party goes where there is room for it.

- A host has nobody picked, and **Seat** waits until they pick: a host does not serve tables.
- A manager or owner starts on their own name, so **Seat** alone makes the table theirs as before. Picking
  someone else gives it away.
- When the table goes to someone else, the screen stays on the floor map for the next party and says
  "A8 is Ben's". The check is Ben's from its first line; the order's history keeps who sat it.

## Handing a table over

A host, manager or owner **holds a busy table down** on the floor map. "Who serves A7?" lists the same
buttons, the present server marked. A tap on someone else hands the table over: every check on the table
becomes theirs, the name tag changes on every screen, and the history keeps who handed it over. A tap on
the present server changes nothing. A server who holds a table down gets nothing: tables are given out by
the host or a manager.

The dishes already on the check keep the name of whoever rang them in; only the check's server changes.

## Mine: picking out your own tables

The bar above the floor map starts with a chip, **Mine**, and the number of tables that are yours right now
("Mine 3"). It is there for everyone a table can be theirs (servers, bartenders, managers, owners), and not
for a host.

A tap turns it on:

- Your tables stay as they are. Every other server's table **fades**: it stays where it is, still shows whose
  it is, and still opens on a tap. Nothing is hidden, so a server can still help at a colleague's table.
- A free table never fades: anyone may seat it.
- The count of tables that need a look (the timer pill at the end of the bar) and the list it opens are of
  your tables only.
- On a screen with the room for it (a tablet on its side, a Mac; 840 points wide or more) your tables are also
  **listed beside the map**: the one that most needs a look first, each with its guests, how long it has sat,
  what it waits on ("Held 16 min · 9 min left") and what it has run up. A tap opens the table. A phone and a
  tablet held upright keep the whole width for the map.

A second tap shows every table the same again.

The choice is yours and follows you: the hub keeps it with your text size and contrast, so the map opens the
way you left it on whichever device you sign in on next. It changes nothing for anyone else.

## Who is who

The hub decides who takes tables and who gives them out, by each person's role:

| Role | Takes tables | Gives tables out |
| --- | --- | --- |
| server, bartender | yes | no |
| host | no | yes |
| manager, owner | yes | yes |
| kitchen, cashier | no | no |

The demo staff has a host to try it with: **Holly, PIN 3333** (beside Amy 1111, Ben 2222 and Mike 9999).
A location's own staff is the hub's `POS_STAFF` (`id:name:role:pin`, comma-separated, in `/opt/pos/.env`):
give the person at the host stand the role `host`.

## Without a hub, and on an older hub

- The staff list is kept on each device, so a host can seat for a server while no hub answers. The table
  shows its server at once on that device and reaches the others when a hub is back.
- An app newer than its hub finds no staff list there: everyone seats their own tables, as before, and no
  table can be handed over. Update the hub first.
- **Mine** on a hub older than it works until you sign out: that hub does not keep the choice. With no staff
  list to say who takes tables, the chip is offered to everyone.

## For developers

- `GET /staff` lists `staff_id`, `name`, `role`, `takes_tables`, `assigns_tables` per person, and nothing
  anyone signs in with. It answers 304 to an `If-None-Match` that still holds.
- A check's server is its `server` and `server_id` fields, set by `create` and changed by `set_field`.
  `GET /floor` gives both on each check. `by` and `by_id` on those operations say who sat or handed over the
  table when that was not the server; they stay in the log and are not fields of the order.
- App: `lib/roster.dart` (the staff list, a server's load on the floor, the short name),
  `lib/screens/server_picker.dart` (the buttons), `OrdersScreen._onTable` and `_onTableHeld`. A hand-over
  still in the outbox is laid over the floor map by `queuedServers` and `FloorPlan.withServers`.
- **Mine** is the staff preference `my_tables` (`PUT /staff/{id}/preferences`, default false; it comes back in
  the sign-in answer with the display settings). App: `DisplayPrefs.myTables`, `FloorView(me:, mine:, onMine:)`,
  `tablesOf` (the tables with a check of someone's), `_MyTables` (the list beside the map, shown by the width
  the map really has). A faded table is the same widget under an `Opacity`; its ring and badge fade with it.
  The list follows the clock the way the map does: a row is rebuilt when its minute or its words change, and
  the list is put in order again only when the clock moves a table up or down.
