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

## For developers

- `GET /staff` lists `staff_id`, `name`, `role`, `takes_tables`, `assigns_tables` per person, and nothing
  anyone signs in with. It answers 304 to an `If-None-Match` that still holds.
- A check's server is its `server` and `server_id` fields, set by `create` and changed by `set_field`.
  `GET /floor` gives both on each check. `by` and `by_id` on those operations say who sat or handed over the
  table when that was not the server; they stay in the log and are not fields of the order.
- App: `lib/roster.dart` (the staff list, a server's load on the floor, the short name),
  `lib/screens/server_picker.dart` (the buttons), `OrdersScreen._onTable` and `_onTableHeld`. A hand-over
  still in the outbox is laid over the floor map by `queuedServers` and `FloorPlan.withServers`.
