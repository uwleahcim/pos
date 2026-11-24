# Whose table it is

Every busy table on the floor map says who serves it: a small name tag under the table's name, in the
table's own colour. It is the server's first name, with an initial when there is more to the name ("Amy",
"Mike W"). A free table has no tag: nobody has it until a party sits.

Under the server's tag, a table whose party the host seated from a reservation or the waitlist also says
the party's name, with a small star for a guest who carries a tag (`guest-list.md`, "On the floor map").

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

A party off the waitlist is seated the same way, with its guests already filled in: **Seat** on the party,
then a tap on its table (`waitlist.md`).

## Whose turn it is

The buttons under **Server** say what each person has on the floor now. They can also say whose turn the
next table is: the names of the people in tonight's turn stand first, in the order they take their tables,
and the first of them carries a small **Next**.

- **Next is whoever has waited longest for a table.** First the ones who have had no table today, in the
  order they came in; then the others, the one sat longest ago first. A table a server opened themselves
  counts as their turn, and a table handed over counts for the one who took it.
- **It marks; it does not pick.** The host still taps a name. Giving the table to somebody else is the
  host's call (a regular asks for Amy, a big party goes to whoever has the room), and whoever was passed
  over is still next.
- **Nobody is in the turn that nothing said was working.** The hub does not guess from the staff list who
  is in tonight: a mark on somebody who went home at three would be worse than none. A person is in the
  turn in one of two ways:
  - **A host says so.** Beside **Server** is the button **Tonight's turn**. It lists everyone who takes
    tables, each with their place ("Next", "2nd", "3rd") or "Not in it". A tap on a name puts that person
    in, at their place; a tap on somebody who is in takes them out: cut for the night, on a long break,
    gone home. A bartender or a manager working the floor tonight is put in the same way.
  - **The time clock says so**, where the location uses it ([time-clock.md](time-clock.md)). A **server**
    who clocks in is in the turn from that moment, and whoever clocks out is out of it. A bartender or a
    manager who clocks in is not put in by that: they are in when a host says so.
- **The later word stands.** A host who takes Amy out at half past eight has cut her, though she is on the
  clock until her tables have paid. If she clocks in again tomorrow, she is in again.
- **It is for tonight.** The turn starts empty each day of service (the night ends at four in the morning).
  Without the time clock, the first host of the day taps in who is on; with it, the names are there as
  people clock in.
- Somebody on a break is still on the clock and still in the turn: the host passes them over, or takes
  them out and puts them back.

While nobody is in the turn, nothing is marked and the buttons stand as they always did.

Only whoever gives tables out says who is in the turn (the hosts, a manager, an owner). Handing a seated
table over is nobody's turn: that dialog shows no mark.

**Not built:** sections (which tables are whose for the night), counting guests and not tables, a turn kept
apart for each room, and the time each person was last sat shown on the button.

## Handing a table over

A host, manager or owner **holds a busy table down** on the floor map. "Who serves A7?" lists the same
buttons, the present server marked. A tap on someone else hands the table over: every check on the table
becomes theirs, the name tag changes on every screen, and the history keeps who handed it over. A tap on
the present server changes nothing. A server who holds a table down hands nothing over: tables are given
out by the host or a manager. (What a server gets is moving the table: see [moves.md](moves.md).)

The dishes already on the check keep the name of whoever rang them in; only the check's server changes.

**A whole section at once.** When the present server has more than one table, a chip under the names reads
"All 3 of Amy's tables". Ticked, the name tapped next takes every check Amy has on the floor: a shift
change in two taps.

The same sheet starts with **Move A7 to another table**: moving a table, and merging it with another, is in
[moves.md](moves.md).

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
- A table whose food the kitchen has made says so in green on its row ("2 dishes ready"), as its badge on
  the map does (`kitchen-screens.md`, "What the servers see").
- A table whose party was seated from a reservation or the waitlist has a line with the party's name and
  the tags that guest carries ("Linda P." `VIP`), so you know whose table you walk up to
  (`guest-list.md`, "On the floor map").

A second tap shows every table the same again.

The choice is yours and follows you: the hub keeps it with your text size and contrast, so the map opens the
way you left it on whichever device you sign in on next. It changes nothing for anyone else.

## Who is who

The hub decides who takes tables and who gives them out, by each person's role. This is how it starts; a
manager or an owner can change it for the servers, bartenders, hosts, cashiers and the kitchen under
Location › **Who may do what** (the powers "Take tables" and "Give tables out", see [roles.md](roles.md)):

| Role | Takes tables | Gives tables out |
| --- | --- | --- |
| server, bartender | yes | no |
| host | no | yes |
| manager, owner | yes | yes |
| kitchen, cashier, driver | no | no |

The demo staff has a host to try it with: **Holly, PIN 3333** (beside Amy 1111, Ben 2222 and Mike 9999).
A location's own staff is the hub's `POS_STAFF` (`id:name:role:pin`, comma-separated, in `/opt/pos/.env`):
give the person at the host stand the role `host`. The line is the whole staff and takes `sudo hubctl
update` to hold; the steps, and what the hub does with a slip in it, are in
[delivery.md](delivery.md#adding-a-driver).

## Without a hub, and on an older hub

- The staff list is kept on each device, so a host can seat for a server while no hub answers. The table
  shows its server at once on that device and reaches the others when a hub is back.
- An app newer than its hub finds no staff list there: everyone seats their own tables, as before, and no
  table can be handed over. Update the hub first.
- **Mine** on a hub older than it works until you sign out: that hub does not keep the choice. With no staff
  list to say who takes tables, the chip is offered to everyone.
- The turn is kept on the hub. With no hub answering, the names stand as the device last heard them and
  **Tonight's turn** says the hub cannot be reached; a party is still sat as always. A hub older than the
  turn shows no mark and no button.

## For developers

- `GET /staff` lists `staff_id`, `name`, `role`, `takes_tables`, `assigns_tables`, `delivers` per person, and nothing
  anyone signs in with. It answers 304 to an `If-None-Match` that still holds.
- A check's server is its `server` and `server_id` fields, set by `create` and changed by `set_field`.
  `GET /floor` gives both on each check. `by` and `by_id` on those operations say who sat or handed over the
  table when that was not the server; they stay in the log and are not fields of the order.
- **The turn** (`pos/floor/turn.py`): `GET /floor` carries `turn`, the staff ids of the people in it, whose
  turn it is first. `POST /floor/turn` `{staff_id, server_id, on}` is a host's word (403 `not_allowed` from
  somebody who does not hold `assign_tables`, 422 `no_tables` for putting in somebody who does not hold
  `take_tables`, 404 `unknown_staff`); it answers with the `turn` as it stands. The words of the day are the
  location setting `turn` (`{day, said: {staff_id: {on, at_ms, by_id, by}}}`), written over by the next
  day's first word; the time clock's part is read from the day's shifts (`punched`), and when each person
  was last sat from the day's checks at a table (`last_sat`). Nothing is kept past the night. The change
  feed says `floor` after a host's word and after every punch and correction on the time clock, and the
  floor map reads again. App: `FloorPlan.turn` (null from an older hub), `inTurnFirst`, `placeInTurn`,
  `ServerPicker(turn:)`, `NextMark`, `lib/screens/turn_dialog.dart`, `PosApi.sayTurn`.
- App: `lib/roster.dart` (the staff list, a server's load on the floor, the short name),
  `lib/screens/server_picker.dart` (the buttons), `OrdersScreen._onTable` and `_onTableHeld`. A hand-over
  still in the outbox is laid over the floor map by `queuedServers` and `FloorPlan.withServers`.
- **Mine** is the staff preference `my_tables` (`PUT /staff/{id}/preferences`, default false; it comes back in
  the sign-in answer with the display settings). App: `DisplayPrefs.myTables`, `FloorView(me:, mine:, onMine:)`,
  `tablesOf` (the tables with a check of someone's), `_MyTables` (the list beside the map, shown by the width
  the map really has). A faded table is the same widget under an `Opacity`; its ring and badge fade with it.
  The list follows the clock the way the map does: a row is rebuilt when its minute or its words change, and
  the list is put in order again only when the clock moves a table up or down.
