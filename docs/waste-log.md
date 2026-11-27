# The waste log

Food that was made or bought and not sold: the quart that burnt, the egg rolls that hit the floor, the tray
of rice thrown out at the end of the night. The kitchen writes down what it was, how many and why. A
manager reads what it comes to by reason, by dish and by day.

Since 17 November 2026 (the Toast comparison, the waste log). Hub and app; nothing to turn on. The list of
reasons starts with Dropped, Burnt, Made wrong, Expired, Spoiled and Staff meal; a manager makes it the
location's own under Location.

**It is beside the sales and never part of them.** An entry is no check, no void and no comp. Writing one,
or striking one out, changes no order, no bill and no report of the sales, and nothing in the sales reads
the waste log. A dish given to a guest free is still a **comp** on the check, with its reason and who
approved it. A dish taken off a check is still a **void**. The log only says what food was lost.

## What the staff see

Orders screen › **More** › **Waste** (the bin). Anybody signed
in opens it: no PIN.

The screen is **today's log**: every entry of the day of service that is running, the newest first, and
over them what the day comes to ("8 wasted · $72.85 at menu prices · 1 with no price").

### Writing an entry

**Log waste**, at the bottom of the screen, asks what, how many and why:

- **What was wasted.** Type a few letters and the dishes of the menu come up under the box, as in the
  search of the order screen: any word, either name, a typo forgiven, one row for each size with its price.
  A tap picks the dish. The cross beside a picked dish gives the box back.
- **Or something that is not a dish.** A tray of white rice, five pounds of chicken: type it and leave it.
  The screen says it will be written as typed, with no price.
- **How many.** Minus and plus, or type the number. 1 to 999.
- **Why.** One button for each reason of the location's list. Every entry has one.
- **A note**, if it helps ("left on the wok"). 120 letters at most.

**Log** writes it. The hub stamps the time and who is signed in at the screen. The list shows it at once.

A dish is written with the price the menu has for it at that moment, so the totals say what the waste
would have sold for. That is the menu's price, not what the food cost: the hub does not know the cost. A
dish whose price is typed when it is rung (market price) has no price here either.

A person who reads the dishes in Chinese (Display › Dish names) finds them under their Chinese names. The
entry is kept under the English name, as a check is, so everybody reads the same log.

### A mistake

An entry is never changed and never deleted. The strike-through button on an entry **strikes it out**: it
stays in the list, crossed out, with who struck it and when, and counts in no total. Then the right one is
written.

- The person who wrote an entry strikes it out, the same day of service.
- A manager strikes out anybody's, of any day (from Location › Waste, below).

## The totals (a manager)

Orders screen › **Location** (manager PIN) › **Waste**, under the day's report, the sales, the dishes sold
and the guests.

It opens on the **Totals** of the seven days just gone. **Today**, **Yesterday**, **7 days**, **4 weeks**
and **Other days** work as they do on the sales (92 days at most at a time).

- **The span in one line:** how many things, what they would have sold for at the menu's prices, and how
  many have no price.
- **By reason** and **by dish**, the most money first, and **by day**, in the order of the days. What has
  no price says "no price"; a day with nothing still has its line.
- How many entries were struck out, when some were. They are counted nowhere.

**Entries**, beside Totals, is the list the staff see, one day at a time. It opens on today, where the
manager writes an entry with **Log waste** as anybody does.

- **The arrows** beside the day go to the day before and the day after. A tap on a day under **By day**
  opens that day's entries.
- **The manager strikes out any entry of any day**: the 40 egg rolls that were 4, found the next morning.
  The totals are right again at once.
- An entry is written into the day that is running only, so an earlier day has no Log waste button.

## The reasons (a manager)

Location › **Waste reasons**, on the card with the kitchen notes.

- One row a reason, in the order the buttons show. Reword one in its box, remove it with the bin, **Add
  reason** for another.
- Twelve reasons at most, 24 letters each, no two the same, at least one.
- An entry keeps the words it was written with. Rewording or removing a reason changes nothing in the log
  as it stands: the totals still list the old words for the old entries.

"Given away" is left off the list on purpose. A dish a guest gets free goes on the check as a comp, so it
is in the day's figures with its reason.

## Good to know

- **A day of service ends at 4 in the morning**, as everywhere else: an entry written at half past midnight
  belongs to the night before.
- **The log is kept on the hub** and needs it. With the hub away the screen says so and nothing is written;
  nothing is held on the device to send later.
- The list is read when the screen opens, after each entry, and on a pull down. A second screen that has
  the log open does not change by itself.
- A dish that was taken off the menu since can still be read in the log, under the name it had.
- 500 entries at most in one day of service.
- An app that is not rebuilt has no Waste entry. A hub that is not updated: the screen says the hub is
  older than the waste log, and Location's rows say the same.

## Not built

- What the food cost. The totals are at the menu's prices.
- A value typed for something that is not a dish.
- Waste in the day's report, or printed.
- Ingredients and stock: the log does not count anything down.
- A picture with an entry.
- Changing an entry (strike it out and write it again).
- Earlier days' entries for the staff (a manager reads them, under Entries).
- Writing an entry into an earlier day.
- Sending the totals out as a file.

## For developers

- Rules: `backend/src/pos/waste.py` (`WasteLog.log`, `strike`, `day`, `report`; `Wasted`; `WasteStore` in
  memory and `PgWasteStore`, table `waste_entry`, made by the primary on start). It imports nothing of the
  orders. The reasons are the setting `waste` in `backend/src/pos/settings.py` (`clean_waste`).
- Calls: `backend/src/pos/api/waste.py`. `GET /waste?day=` (the day, with `reasons` and `limits`), `POST
  /waste` (`staff_id`, and `variant_id` with `entry_id` for a dish, which the hub names and prices from the
  menu, or `name` for something typed), `POST /waste/{id}/strike` (`staff_id`, or a manager's token), `GET
  /reports/waste?from=&to=` (manager token), `GET` and `PUT /settings/waste`. Staff have no token: a screen
  says who is signed in, as for the notes. No topic of the change feed.
- App: `lib/waste.dart` (`WasteDay`, `WasteEntry`, `WasteReport`, `wasteSummary`),
  `lib/screens/waste_screen.dart` (`WasteScreen`; with a `token` it has the totals and the earlier days),
  `waste_dialog.dart` (`WasteDialog`, which searches the menu with `MenuSearch`),
  `waste_reasons_dialog.dart`; `PosApi.wasteDay`, `logWaste`, `strikeWaste`, `wasteReport`, `wasteReasons`,
  `saveWasteReasons`.
- Tests: `backend/tests/test_waste.py` (`test_the_waste_log_changes_nothing_in_the_sales` reads the check,
  the day and the reports before and after), `apps/pos_app/test/waste_test.dart`.
