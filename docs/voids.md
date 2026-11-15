# Voids of sent dishes

Taking a dish off after the kitchen has it is money leaving the register after the food was made. Since
2026-11-15 it takes a reason, by default a manager's PIN, and it shows in a report. The rules are a location
setting on the hub; the app asks first and the hub refuses anything the rules do not allow.

**A dish the kitchen has not seen is not a void.** It comes off the check with nothing asked, as before
(the log keeps it as `removed`), and the report lists it under "Taken off before sending" (see "The
report"). Everything else below is about dishes already sent.

## On the order screen

A sent dish is voided the same ways as before: the bin on its line (a tap for one fewer, a hold for all of
it), Delete or Backspace with the keyboard, or a smaller quantity typed.

1. **Why.** A box names the dish and shows the location's reasons as buttons, two across on a phone. A tap
   on a reason is the operator's word for the void. **Keep it** walks away; the keyboard's focus starts
   there, so Enter never voids a dish by accident. The reasons to start with: Guest changed mind, Rung in
   wrong, Kitchen error, Out of stock.
2. **Manager PIN**, unless the location lets servers void. The manager types their PIN on the spot, as for
   a comp. The hub checks it (five misses lock the terminal for a minute, as at sign-in); a server's PIN is
   refused. The approval is good for voids on that one order for ten minutes, and for nothing else.
3. The VOID ticket prints as before, in reverse, at once.

The voided line stays on the check, struck through, with its reason: "void · Kitchen error".

**Fewer of a sent dish** is a void of the difference: three teas down to one asks the same two questions,
then voids the three and sends one again on the same ticket. The report counts two.

**Changing a sent dish** (its choices, a note) is not a void. It still voids the line and sends the changed
dish in its place on one ticket, and nothing is asked, as long as the quantity does not go down. A change
that lowers the price a little (a smaller size, an add-on taken off) is not treated as a void either.

**With no hub or cloud answering**, a sent dish cannot be voided where a manager must approve: nobody can
check the PIN. The screen says so. Tell the kitchen by hand and void the dish when the connection is back.
Where the location lets servers void, the void is queued with its reason like any other operation.

## Setting the rules

Orders screen › **Location** › **Voids** (manager PIN).

- **A manager approves each void**: on to start. Off, whoever is on the check voids a sent dish with a
  reason alone.
- **Reasons**: rename, remove, add, up to twelve (a screenful of buttons on a phone), at least one.

The hub keeps them as the `voids` setting (`GET`/`PUT /settings/voids`) and holds every void to them from
the next one on. A void in the order log carries its reason's id and the name it had then, so renaming or
removing a reason changes nothing already recorded.

## The report

Orders screen › **Location** › **Voids and comps report**, for today, the last 7 days or the last 30.

- **Voids**: what they came to and how many, added up three ways (by reason, by who voided, by the manager
  who approved), then every void: when, the table or order number, the dish and how many, the reason, who
  voided it and who approved it.
- **Taken off before sending**: dishes rung in and taken off again before the kitchen saw them. Nothing
  printed and nothing was asked, so no other report shows them. What they came to and how many, added up by
  who took them off and by check, then every one: when, the table or order number, the dish and how many,
  who took it off and how long it had been on the check. The list starts with the dish that was on its check
  the longest, because a dish taken off an hour after it was rung in is worth a question and one taken off
  ten seconds later is a slip of the finger.
- **Comps and discounts**: the same three totals for what is on the checks (see `discounts.md`).

What counts as taken off: the whole line removed, and fewer of an unsent dish (three teas made one counts
two). What does not: a dish changed for the same dish with other choices, and more of a dish. Nothing new is
asked on the order screen: the app says who is signed in when a dish comes off, no more. A dish taken off by
an app older than this list has no name on it, so its row says who rang it in instead ("rung in by Amy").
An app newer than its hub shows "This hub is older than this list" in the section's place.

It reads `GET /reports/adjustments?since=<ms>`, which now also returns `voids`, `void_total`, `void_count`,
`voids_by_reason`, `voids_by_staff` and `voids_by_approver`. Voids are counted from `since` by when they were
made, whatever the age of their order. A void made before reasons were asked shows under "No reason
given". The audit photo of each void is in `/events/photos` under the operation's id, as before.

For dishes taken off it returns `taken_off` (one row for each time: `order_id`, `table`, `order_no`,
`customer_name`, `line_id`, `item`, `qty`, `amount` before tax, `by`, `by_id`, `rung_by`, `device`, `at_ms`,
`on_check_ms`, `status` of the order), `taken_off_total`, `taken_off_count`, `taken_off_by_staff` and
`taken_off_by_check`, counted from `since` the same way. The rows come from `pos/orders/taken_off.py`, which
reads what the log's replay keeps on each line: `removed` (who took an unsent line off, and when) and `cuts`
(each time its quantity went down before it was sent). The app puts `by` and `by_id` on every `void_line`
and on every `set_line` that changes a quantity; the hub takes them as said, as it does for who rang a dish
in. The older key `removed` of the same report is something else: discounts taken off a check.

## How the hub checks a void

`pos/orders/voids.py`, called for every batch a terminal appends, before anything is stored:

- A `void_line` on a line that is active and already sent needs `reason`, the id of a reason on the
  location's list, and, with `approval: manager`, an `approval` token from `POST /approvals` with purpose
  `void` for that order. The hub swaps the token for `approved_by` (who it was) and adds `reason_name`;
  nothing a terminal says about approval itself is kept, and the token never reaches the log.
- It is not a void when the same batch adds a line that `replaces` the voided one and holds at least as
  many: that is a change. Fewer in its place is a void of the difference.
- A void the rules refuse is left out and reported back with its problems (`unknown_reason`,
  `needs_approval`), like a refused discount. The line that would have replaced the dish is left out with
  it, so the check stays as it was.
- A void of a line the hub does not know yet is stored as it comes: a void always wins in the log.

An app that has not been rebuilt since this change still sends voids without a reason. The hub refuses
them and the dish stays on the check, with the refusal in the status bar: rebuild the app.

Not covered: `void_order` (no screen offers it) and a quantity lowered on a sent line by `set_line` (the
app never sends one; it voids and sends again).
