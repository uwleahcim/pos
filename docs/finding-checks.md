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
  - digits: the start of the order number (`4` finds #4, #41, #42), or, with three digits or more, any part
    of the phone number, however either was punctuated (`555-1234` finds `(781) 555 1234`);
  - `#42`: the order number and nothing else;
  - `table`: any check that is at a table (`table b` finds the B tables).
- **What a row says.** Besides what the list always says, a check that is looked for starts with when it
  was opened ("19:42", "yesterday 19:42", "14 Nov 19:42") and ends with its server's name.
- **Leaving.** The cross at the end of the row, or Escape, closes the box: the list is the open checks
  again.

Tapping a check opens it as ever; a closed one can be reopened from its own screen.

The words are matched on the terminal, over the checks it has read, so typing costs nothing on the network,
and with no hub in reach the box still narrows the list the screen last read.

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
