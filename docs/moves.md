# Moving tables, merging checks, moving dishes

A party changes tables. Two tables push together. A drink was rung in on the wrong check. One server goes
home and another takes their section. All four are done on the floor map and on the check, with no void and
nothing rung in twice.

**A dish that changes checks is never voided and added again.** It goes over as it is: what it is, its
choices, the price it was sold at, who rang it in, its comp if it has one, and whether the kitchen has it.
The kitchen cooks nothing twice, the Voids and comps report lists nothing, and no sale can drop out of the
books by moving it: the hub lets a dish leave a check only once it stands on the other one.

## Moving a table

**Hold a busy table down** on the floor map.

- A **server or bartender** goes straight into moving: a strip above the map says "Moving A7. Tap the table
  it goes to." and A7 gets an outline.
- A **host, manager or owner** gets a sheet first: **Move A7 to another table** at the top, and under it
  "Who serves A7?" as before (see [table-servers.md](table-servers.md)).

Then **tap the table it goes to**.

- **A free table** takes every check of the table as it is: same dishes, same server. The message says
  "A7 moved to A8".
- **A seated table** asks first: "B5 is seated. Put A7 and B5 on one check, or keep two checks at B5?"
  - **Keep apart**: both checks sit at B5, each with its own dishes and its own server. A tap on B5 then
    asks which check to open, as with any table that has two.
  - **One check**: see "Merging" below.
  - **Cancel** leaves the table in hand, so another table can be tapped.

**Cancel** on the strip, or a tap on the table itself, calls the move off. Leaving the floor map does too.

## Merging two checks into one

**One check** empties the table that moved into the check of the table it landed on (its oldest check, when
it has several):

- Every dish goes over, sent or not, and stays with whoever rang it in.
- **Seats**: the guests who came sit after the ones already there. With four guests at B5, seat 1 of A7 is
  seat 5 at B5. Dishes rung in for the table stay for the table.
- **Guests** are added up.
- **The party the host seated** goes over too: a party seated at A7 from its reservation or from the
  waitlist is named on B5's check from then on, with its tags and its note, on B5 on the floor map and on
  B5's row in the list of checks, beside whoever was seated at B5. Nothing is written onto a check for
  it: the hub notes in the book or on the waitlist which check the party sits on (`guest-list.md`, "When
  two tables are put together").
- **In the guest list** the guests of both tables are guests of the joined check, the customer whose
  number was typed on A7's check too: each has the visit. The money counts for the number on B5's check;
  with no number on it, type the payer's (`guest-list.md`, "Every guest of a check").
- **Allergies** are told again on the joined check: a seat's on its new seat, the table's together with the
  other table's. The kitchen hears of them as of any allergy told on a check (see
  [allergies.md](allergies.md)).
- **A comp or a discount on a dish** goes with the dish, with the name of the manager who approved it.
- **A discount on the whole check** stays behind: it was given on that check's own total. The question says
  so before you choose; put it on the joined check again if it should count.
- The emptied check is closed with nothing on it and keeps a note of where its dishes went.

**A check with a payment on it is not merged.** Money taken on a check stays with that check; the question
says why and offers only Keep apart.

The joined check is the server's who had the table it landed on. Hand it over afterwards if it should be
someone else's.

## Moving dishes to another table's check

On the check, **hold a dish** (and tap others to stack them, as for Comp and Void). While dishes are in hand
the foot of the check offers three places: **Move**, **Comp** and **Void**. Let go over **Move** and a sheet
asks "Move 2 dishes to", with a button for every other table that has a check, in table order: the table,
its server and its guests. A table with two checks has a button for each, with what is on it. Tap one and
the dishes are on that check: "2 dishes moved to table B5".

- Nothing is asked: no reason and no manager. Nothing came off the register.
- A dish goes over for the table (no seat), since its seat here means nothing there. Set the seat on the
  other check if it matters.
- Tapping beside the sheet keeps every dish where it was.
- A table with no check yet has no button: seat it first.

To move a dish to another check of the **same** table, use **Split** ([split.md](split.md)).

## Giving all of a server's tables to another

A host, manager or owner holds down **any one** of the server's tables. When that server has more than one
table, a chip under the names reads **All 3 of Amy's tables**. Tick it, the question becomes "Who takes
Amy's 3 tables?", and a tap on a name hands over every check Amy has on the floor at once. Checks of other
servers at the same tables are left alone.

## What the kitchen hears

A move prints **no order ticket and no void**: nothing is cooked again and nothing is thrown away. What the
kitchen does need to know is where the food goes now. So when dishes that were **sent in the last 45
minutes** change tables (a table moved, two tables merged, or dishes moved to another table's check), each
station that has some of them gets a short slip:

```
*** MOVED *** WOK 1
#131  dine_in                    18:42
Table B5
Server Amy
--------------------------------------
WAS TABLE A7
NOW TABLE B5
These dishes go to the new table:
--------------------------------------
1 x Peking Duck
    + No skin
2 x Fried Rice
```

WAS and NOW are in big type, NOW white on black, and the printer beeps three times as for a void.

Dishes sent longer ago are taken to be on the table already, and dishes not sent yet print with the new
table when they are sent. Keeping two checks apart at one table prints the slip too: the food still goes to
another table.

The slip has a switch under **Location settings**, on the Printers card: **Tell the kitchen when a table
moves**, on to start.

A bar tab that is given a table prints the same slip, with `WAS TAB LINDA` where a table's says the table
it left (`bar-tabs.md`).

## Without a hub, and on an older hub

- A move or merge made while no hub answers shows on that device's floor map at once and reaches the others
  when a hub is back. Merging and moving dishes need the hub for a moment (to read the other check, or the
  list of tables); with no hub the table can still be moved and kept apart.
- An app newer than its hub offers no Move anywhere: holding a table is as before, and the check has Comp
  and Void alone. Update the hub first.
- An app older than its hub shows a dish that moved away as taken off, which is how it should look there.

## Not in this yet

- Moving dishes to a table that has no check yet.
- Moving one of a line of two: the line moves as one.
- Two screens moving the same dish to two different checks in the same moment can leave it on both, and
  someone then has to take the extra one off. (A dish is never lost this way: it is on both, not on neither.)
- Undo. Move it back the same way.

## For developers

- A dish changes checks with two operations. On the check that takes it, `add_line` with
  `from: {order_id, line_id}`; the hub (`pos.orders.moves.carry_ops`) fills in `item`, `qty`, `note`,
  `course`, `request`, `priced`, `by`, `by_id` from the source line, adds the source's `table` to `from` and
  sets `sent` to the source line's fire stamp. On the check that lets it go, `move_line`
  `{line_id, to: {order_id, line_id}, by?, by_id?}`, which the hub stores only when the other check holds a
  line whose `moved_from` is this very line (else `invalid_move` / `not_arrived`). Other refusals:
  `invalid_line` / `unknown_source`, `gone`. The terminal queues the taking check first.
- Replay (`pos.sync.oplog`): a moved-away line has status `removed` and `moved_to`; a line that came has
  `moved_from`, and `arrived_sent` when it came already sent (so `kitchen_changes` prints nothing for it).
  `Line.moved` tells a moved line from one taken off; `taken_off` and the number left of a counted dish
  (`counts.py`) leave moved lines alone. A carried `add_line` is not priced again.
- A discount goes along as `discount` with `from: {order_id, discount_id}`; the hub copies the reason, kind,
  value and approval from the source, once, and only onto the line that came from the discounted dish
  (`_came_along` in `api/app.py`).
- Merging is those operations for every dish, then `set_field {guests}` and `allergy` on the taking check,
  and `set_field {merged_into}` and `close` on the emptied one. `merged_into` is an order field. When the
  hub takes that `set_field`, the parties seated on the emptied check are put on the check the log says
  was kept, in the book and on the waitlist (`follow_merges` in `backend/src/pos/api/guests.py`).
- Moving a table is `set_field {table}` on each of its checks.
- The MOVED slip: `table_changes(before, after, now_ms)` and `MOVED_SLIP_MS` in `printing/service.py`,
  ticket kind `moved` with `was_at` in `printing/ticket.py`, the setting `tickets.moved`.
- `GET /floor` and `GET /orders/{id}/check` answer `moves: true`; the app offers moving only then.
- App: `lib/moves.dart` (`moveTableOps`, `moveLinesOps`, `mergeOps`, `seatShift`, `cannotMerge`),
  `lib/screens/table_moves.dart` (the sheet, the strip, the question, `CheckPicker`),
  `OrdersScreen._onTableHeld` and
  `_moveTo`, `OrderScreen._moveLot`; a move still in the outbox is laid over the map by `queuedTables` and
  `FloorPlan.withTables`.
- Tests: `backend/tests/orders/test_moves.py`, `backend/tests/printing/test_moved_slip.py`,
  `apps/pos_app/test/table_moves_test.dart`. The sync simulation moves dishes between orders too.
