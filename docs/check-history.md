# A check's history

Everything that happened to one check, from the moment it was opened: every dish rung in, sent, changed,
voided or taken off, every comp and discount, every move of the table, every payment, the close and any
reopening. Each step says when, who did it, at which screen, and which manager approved it where one was
asked. It is for a manager, and it only reads: nothing on the check can be changed from it.

Since 16 November 2026 (the Toast comparison, row 11). The POS always kept these steps; this is the screen
that shows them.

## Opening it

Three ways in, all for a manager:

- **From the check itself.** On a Mac or an iPad, the **History** button at the top of the check. On a
  phone the top of a check has no room for one more button, so **hold the check's name** at the top
  ("Table 12 · open") instead. Either way the manager's PIN is asked for first, so a server can call a
  manager over to the table. A closed check is found with the search on the list of checks, as before.
- **From The day** (Location › The day): a tap on any check under "Still open".
- **From the Voids and comps report** (Location): a tap on a void, or on a dish taken off before sending,
  opens the history of the check it was on.

The last two are already behind the manager's PIN and ask for nothing more.

## What it shows

At the top, the check as it stands now: its table or number, open or closed, its server, its guests and
when it was opened. Under it the steps, the oldest first, with the date as a heading whenever a new day
begins.

Each step is one row:

- the **time**;
- **what happened**, in a line ("Rang in 2 × Egg roll", "Sent to the kitchen", "Voided 2 × Egg roll",
  "Moved from table 12 to table 14", "Payment of $6.50"), and under it the rest: the choices on a dish, its
  seat, course and price, the reason of a void, how a payment was made and what was handed over;
- **who** did it and at **which screen** ("Amy · mac1"), with "approved by Mike" where a manager's PIN was
  asked;
- the small **picture** taken at that moment, where there is one. A tap shows it large.

What takes something off a check is written in red: a void, a dish taken off before it was sent, a comp or
a discount, a check voided whole, and a check marked tax exempt ("Marked tax exempt", with the organisation
and its certificate number; `tax-exempt.md`).

A dish that **went to another check** or **came from one** says which, and a tap on that row opens the other
check's history. The same for two tables made one. A dish that came over also says who rang it in on the
check it came from.

## What is a step and what is not

- Every operation the POS keeps on the check is a step: nothing can be left out, hidden or deleted.
- An operation that changed nothing is no step: the same dish arriving twice after a bad connection, or a
  field set to what it already was.
- A dish dragged up or down the check is not listed. A dish moved to another course is.
- A step taken while the hub was not answering says so. Its time is the time on the screen that took it.
- Printing a bill and printing a kitchen ticket are not steps of the check and are not listed (see "Not
  built").

## Who did it

From this update on, every step records who was signed in at the screen when it was taken.

Older steps do not all have a name. Dishes rung in, voids, dishes taken off, payments, comps and moves
always had one. A send to the kitchen, a close, a reopening and a change of guests did not. For those the
history takes the name from the picture taken with the step when there is one, and otherwise says "nobody
named" and the screen it was done at.

What the hub did by itself because a service said so is that service's: a delivery that Shipday's driver
picked up says "Left with Tom Reyes" by **Shipday**, and one delivered there "Marked delivered" and "Closed
the check" by Shipday. Where Shipday said something and the check stayed as it was (delivered while money
is still due, failed), a step of its own says so: "Shipday says it was delivered" (`shipday.md`).

What the hub told a service is a step too: "Told Shipday it is ready for pickup", with "By itself, as the
check was marked Ready" under it and **Shipday** as who, where the hub told Shipday because the check was
marked Ready; or by whoever tapped Ready for pickup on the Shipday screen (`shipday.md`, "Saying it is ready
for pickup").

## The pictures

The screens take a picture at the moments that matter (a send, a void, a comp, a payment, a close, a
reopening). The hub keeps the newest 2,000 of them in its memory, so a picture is there for recent steps
and gone for old ones, and all of them are gone when the hub restarts. A step whose picture is gone shows a
small crossed-out camera. The step itself, with its name and time, is never lost.

## Good to know

- Courses, discounts, charges and allergens are called by the names they have today.
- The history needs the hub. A check rung in while the hub was away has no history until its steps arrive.
- Reading a history changes nothing and leaves no step of its own.

## Not built

- Bill prints and kitchen ticket prints in the history.
- Pictures kept for good (on disk, across a hub restart).
- Printing a history, or sending one by e-mail.
- A search across all checks for one kind of step ("every reopening this week"). The Voids and comps report
  does this for voids, dishes taken off and comps.

## For developers

- `GET /orders/{order_id}/history` with a manager's token answers `{order, steps}`; 404 `unknown_id` for a
  check the log has never heard of. The steps are worked out in `backend/src/pos/orders/history.py`, whose
  first lines list what each kind of step carries; nothing is stored.
- The app stamps `by` and `by_id` on every operation that names nobody (`Outbox.who`). A dish brought over
  from another check keeps its ringer as `by` and names the mover as `moved_by`, `moved_by_id`.
- `PhotoStore.for_op` finds the audit photo of an operation.
