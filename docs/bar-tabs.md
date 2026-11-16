# Bar tabs

A check with a name and no table. A guest at the bar orders a round, the bartender opens a tab in their
name, and every later round goes on it. The tab is found again by the name, it is on no floor map, and when
the party is given a table the tab goes with them: nothing is rung in again and nothing is voided.

Since 16 November 2026 (the Toast comparison, row 13). Hub and app; nothing to turn on.

## Opening one

On the orders screen, the floor map or the list of checks: **Tab**, beside **To go**.

It asks for the **name on the tab** (it cannot be left empty, and takes 24 letters), and the tab opens. It
is rung in like a table's check: dishes and drinks from the same menu, the courses, **Fire** to send a
round and stay on the tab or to send and leave, discounts, the bill, a split, and **Close** when it is
paid. It is eaten in, so it is taxed as a table's check is.

What a tab does not have is seats: where a table's check has its seats, a tab has **Seat at a table**.

The name at the top of the tab, tapped, changes the name. The check's history keeps who changed it.

## Finding it again

- **The list of checks** shows every open tab among the other checks, with a glass where a table has its
  name: "Linda · tab".
- **Tabs**, the first button in the row over the list, says how many tabs are open and lists only them, by
  the name on each. It shows while a tab is open. Tapped again, every check is back.
- **The search** (the magnifying glass) finds a tab by any part of its name, or by who opened it; the word
  `tab` lists every tab, closed ones of the last day too (`finding-checks.md`).
- **It is on no floor map.** A tab has no table, so the map shows the tables only.

## When the party sits down

Open the tab and tap **Seat at a table**. The floor map comes up with a strip across the top ("Seating
Linda's tab. Tap their table."), and the next table tapped is theirs. **Cancel** on the strip, or going back
to the list, calls it off.

- **A free table** asks what it asks of any party: how many guests, and for a host or a manager whose table
  it is. A server who seats the tab takes the check, as with a table they open; a bartender who seats their
  own tab keeps it until a host or manager hands it over (hold the table down, `moves.md`).
- **A table that is seated** asks **One check** or **Keep apart**. One check puts every drink and dish of
  the tab on that table's check, and the tab is closed, empty, saying where its dishes went. Keep apart
  leaves the tab a check of its own at that table. Either way it is that table's server's from then on. A
  tab with a payment on it can only be kept apart: money taken on a check stays with that check.

From then on it is that table's check like any other: it is on the floor map, its tickets say the table,
and it keeps the name it had as a tab, so the search still finds it by the name.

Every dish keeps saying who rang it in, so the drinks the bartender poured stay the bartender's in the
day's sales by person, whoever has the check at the end.

## What prints

- **Tickets.** A tab's ticket is headed with the name in big letters where a table's has its table:
  `TAB LINDA`. It goes to the stations that make what is on it (the bar, the kitchen), as a table's does;
  it is not a bag for the takeout counter.
- **The slip when it sits down.** Drinks and dishes sent in the last 45 minutes may still be on their way.
  When the tab is given a table, or its dishes go onto a table's check, each station that has some of them
  prints a slip headed `*** MOVED ***` with `WAS TAB LINDA` and `NOW TABLE 12` and the dishes. It is the
  slip a table that moves prints, and the same switch turns it off (Location settings, on the Printers
  card: "Tell the kitchen when a table moves").
- **The bill** is headed `Bar tab` with the name beside it, and the server under it.
- An allergy told on a tab heads its tickets as `Tab: Peanuts`.

## In the reports

- **Every sale on a tab is in Sales and The day**, like any other check's. Nothing about a tab leaves a
  sale out, and a drink that goes from a tab to a table is sold once.
- **By kind of order** has a line of its own, **Bar tabs**, for the tabs that never sat down, beside Tables,
  To go and Delivery. A tab that was given a table counts with the tables from then on, with every drink
  it had at the bar. A tab emptied onto a table's check counts there too.
- A tab has no guests until it is seated, so it is left out of "a guest spends", as a to-go order is. It is
  no table's turn either: only a check that sat at a table counts in how long a table stays.
- **The day's open checks** list an open tab as "Tab · Linda". An open tab at closing time is a check
  somebody still has to settle.
- **A check's history** says it was opened as a bar tab, each change of its name, when it sat down
  ("Put at table 12"), whose it became, and on the table's check which drinks "came over from Linda's tab".

## Good to know

- A tab is not a to-go order: it gets no number of the day, no ready time and no ready text.
- Two tabs can have the same name. The list tells them apart by what is on them, and the search by who
  opened them.
- A tab is not a guest in the guest list (`guest-list.md`): that list goes by phone number, and a tab has
  none.
- An app that is not rebuilt shows a tab opened elsewhere as a to-go order with no number. Rebuild every
  device.
- With no hub answering, a tab can still be opened and rung in (it is sent on when a hub answers). Putting
  it on one check with a table needs the hub.

## Not built

- A card held for the tab. Payments are parked, so a tab is paid like any check, when it is closed.
- A short menu of the most-poured drinks for the bar's screens.
- A device that opens on the tabs.
- Going back from a table to the bar: a tab that sat down stays that table's check.
- Seats on a tab. Split a tab by dish or evenly; by seat only once it sat down.

## For developers

- A tab is an order created with `tab: true`, `order_type: dine_in`, `customer_name` and no `table`
  (`ORDER_FIELDS` in `pos/sync/oplog.py`). `is_tab(fields)` and `OrderState.is_tab` / `tab_name` say whether
  it is one now: opened as a tab, eaten in, at no table. Seating is a `set_field` of `table` (with
  `guests`, `server`, `server_id`); `tab` stays true and says how the check began.
- Joining a table's check is `mergeOps` (`lib/moves.dart`): `add_line` with `from` on the table's check,
  then `move_line`, `merged_into` and `close` on the tab. `pos.orders.moves.carry_ops` adds the name on the
  tab to what the hub stores as where a dish came from (`from.tab`, `Line.moved_from["tab"]`); a terminal
  cannot say it.
- Printing (`pos/printing`): `Ticket.tab` heads the ticket; `tab_changes(before, after, now_ms)` gives the
  dishes for the MOVED slip by the name on the tab, and `Ticket.was_tab` words it; `bill_for` heads the bill;
  `allergy_lines` says "Tab:".
- Reports: `kind_of(state, check)` in `pos/orders/day.py` is `tab` for a tab that never sat down and was
  not emptied onto another check, else the order type; `sale_of` uses it, and counts no turn for a check
  that is a tab. `/reports/day` rows of open checks and `/orders/{id}/history`'s `order` carry `tab: true`
  for a tab; the history's `opened` step lists `tab`, and a `moved_in` step `other_tab`.
- App: `Order.isTab`, `tabLabel`, `hasTable`; `isTakeout` is now "no table and not a tab". `TabDialog`
  (`lib/screens/tab_dialog.dart`), `ToGoChips` with `tabs` / `tabsPicked` / `onTabs`, `tabsByName`
  (`lib/to_go_stages.dart`), `checkMatches` (the word `tab`). The order screen closes with a `SeatTab`
  when "Seat at a table" is tapped, and `OrdersScreen._seatAt` does the rest; `MovingBar.words` and
  `LandingDialog.tab` are the strip and the question.
- Tests: `backend/tests/orders/test_tabs.py`, `apps/pos_app/test/tabs_test.dart`.
