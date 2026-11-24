# Finding a check

The list of checks shows what is open. To find one check among them, or one that is already closed, tap the
magnifier at the start of the row above the list (with no to-go orders to sort, the row is a button that
says **Find a check**).

## The search box

The box takes the place of the row of chips, and the list narrows as the words are typed.

- **What it looks through.** Every open check, however old, and every check that was opened or changed in
  the last 24 hours: closed and voided ones too.
- **What finds a check.** Every word typed has to be somewhere on it, in any order, capitals or not:
  - the customer's name, the table, or the server's name;
  - the name of a party the host seated at the table, from its reservation or the waitlist
    ([Whose table it is](#whose-table-it-is)): `chen` finds the Chens' table;
  - digits: the start of the order number (`4` finds #4, #41, #42), or, with three digits or more, any part
    of the phone number, however either was punctuated (`555-1234` finds `(781) 555 1234`);
  - `#42`: the order number and nothing else;
  - `table`: any check that is at a table (`table b` finds the B tables);
  - `tab`: any bar tab that has not sat down (`bar-tabs.md`). A tab is also found by the name on it, before
    and after it is given a table.
- **What a row says.** Besides what the list always says, a check that is looked for starts with when it
  was opened ("19:42", "yesterday 19:42", "14 Nov 19:42") and ends with its server's name.
- **Leaving.** The cross at the end of the row, or Escape, closes the box: the list is the open checks
  again.

Tapping a check opens it as ever; a closed one can be reopened from its own screen.

The words are matched on the terminal, over the checks it has read, so typing costs nothing on the network,
and with no hub in reach the box still narrows the list the screen last read.

## Whose table it is

"Which check is the Chens'?" The host knows the party by its name, and the list of checks knew the table
alone. So the check of a table whose party was **seated from its reservation or from the waitlist** says
the party's name after the table, in the list and in what the search finds: **Table A7 · Chen**. Since 24
November 2026. Nothing to turn on.

- Nothing is done for it. The host seats the party as always (**Seat**, then the table;
  `reservations.md`, `waitlist.md`).
- **The name** is the one on the reservation or on the line of the waitlist, whole.
- **Two parties at one table**: both names, the first to sit first ("Omar, Wu"). With more, the first two
  and how many more ("Garcia, Okafor +1"). The search finds the check by any of them, the ones behind the
  count too.
- **A bar tab that sat down** says the name it was opened with the same way ("Table B2 · Linda"). The
  search found it by that name already (`bar-tabs.md`); now the row says why.
- **A walk-in** seated straight from the floor map has no reservation and no party behind it: its row says
  the table alone, as before. So does every to-go order and every tab, whose rows already lead with a name.
- **A closed check still says it**, for the night and the day after: "the Patels paid an hour ago, which
  check was it?" is answered by typing `patel`. After that the hub no longer looks the party up, and the
  row says the table alone. So does every check of **another day** a manager picks from the calendar.
- **It follows the check.** **Put back** (the party goes back in the book or on the list) takes the name
  off the row. A party seated while the list is open is named on it at once; without the hub's live
  updates it takes as long as the list takes to read again.
- **What the list is told**: for each check, the names of its parties. Never the phone number, never the
  note of the reservation, and no tag: the floor map has the star for a tagged guest and the check itself
  says the tags and the note (`guest-list.md`, "At the table"). Everybody who is signed in and sees the
  list reads the name, as they read it on the floor map.
- **Nothing is written onto the check.** The name is read from the book and the waitlist each time the
  list is read. No bill, no kitchen ticket, no report and no figure changes, and a table still counts as a
  visit in the guest list only when somebody types a number on its check.
- A device that is not rebuilt shows the list as it was. A rebuilt device with a hub that is not updated
  does too.

## Another day (managers)

Signed in as a manager or an owner, the row has a calendar. Pick a day (up to a year back): the list is
then every check **opened during that day's service**, four in the morning to four the next, the
restaurant's own time, so a check opened at half past midnight is under the evening it belongs to. The
day shows beside the box; its cross comes back to now. The words narrow that day's checks the same way.

## On the wire

- `GET /orders?day=2026-11-14&brief=true`: the orders opened from 04:00 on the 14th to 04:00 on the 15th
  (`POS_TIMEZONE`), any status unless `status` says one. `hours` adds nothing to `day`. A day that is not
  one is refused (422).
- Every order of a `brief` list carries `opened_ms`, the wall-clock time it was opened. An app on a hub
  from before this shows no opening time, and a day picked from the calendar lists nothing (the app sends
  `hours=24` along with `day`, so such a hub answers with a day of orders, not all it ever took, and the
  app leaves out what carries no opening time).
- The search itself asks for `GET /orders?hours=24&brief=true`, the list "Show closed" already used, and is
  answered `304` until something changes.
- A check of a `brief` list that a party was seated on carries `seated`: the names of its parties, the
  first to sit first, each once (`names_by_check` in `backend/src/pos/api/guests.py`). A check nobody was
  seated on has no `seated`, and neither has an order read by itself or a list that is not `brief`. The
  names come from `Reservations.seated()` and `Waitlist.seated()`, which look at today's and yesterday's
  parties; the number, the note and the tags are not told. App: `Order.seated` and `Order.tableNames`
  (`lib/api.dart`), `checkMatches` (`lib/check_search.dart`), `_whose` in
  `lib/screens/orders_screen.dart`; the list reads again when the change feed says `reservations` or
  `waitlist`. Tests: `backend/tests/orders/test_guest_tags.py` ("in the list of checks"),
  `apps/pos_app/test/check_by_guest_test.dart`.
