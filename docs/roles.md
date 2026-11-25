# Who may do what

Each person on the staff has a role: server, bartender, host, cashier, kitchen, driver, manager or owner. Until
2026-11-17 what a role could do was fixed: only a manager or an owner approved a void or a discount and
opened the back office, the servers and the bartenders took tables, and the hosts gave them out.

Now the location has a table, **Location › Who may do what**, where a manager or an owner hands any of
fifteen powers to the other roles, or takes them back. It starts exactly as the rules were, so nothing
changes for anybody until somebody changes it. (The drivers and the power to take deliveries out came with
deliveries, `delivery.md`: nobody who was on the staff before holds anything new.)

## Two rules that do not change

- **A manager and an owner may do everything, always.** They have no buttons on the screen, and nothing on
  it takes anything from them. No mistake there can leave the restaurant with nobody who may void a dish or
  open the settings.
- **Only a manager or an owner changes the table**, and only they change the location's other settings
  (courses, quote times, printers, the time clock's switches, the staff's tags and faces). That is never
  handed out, whatever the table says.

So the table only ever lets more people do something. It cannot lock anybody out.

## The screen

Orders screen › the three dots › **Location**, a manager's PIN, then **Who may do what**. The row itself
says what is handed out beyond how it started ("Approve a void: Bartenders").

Each power is a row: what it is, one line on what it lets a person do, and six buttons: **Servers,
Bartenders, Hosts, Cashiers, Kitchen, Drivers**. A lit button is filled and ticked, and means everybody of that role
holds it. Tap to hand it out or to take it back, then **Save** at the foot, which counts the changes ("Save
2 changes"). **Put it back as it started**, below the last row, puts every button back the way the table
began; that too holds only once it is saved. Leaving with changes not saved asks first.

A change holds on every screen from the moment it is saved.

## The fifteen powers

| Power | What it lets a person do | Who has it to start, besides managers and owners |
| --- | --- | --- |
| **Approve a void** | Their PIN takes a dish the kitchen already has off a check (`voids.md`) | Nobody |
| **Approve a discount or a comp** | Their PIN gives a discount or a comp that asks for one, and takes a service charge off (`discounts.md`) | Nobody |
| **Approve a tax-exempt check** | Their PIN marks a check exempt from sales tax (`tax-exempt.md`) | Nobody |
| **Read a check's history** | Every step of a check: who did it, on which screen and when (`check-history.md`) | Nobody |
| **Take tables** | A table can be theirs, and a host can seat a party for them (`table-servers.md`) | Servers, bartenders |
| **Give tables out** | Seat a party for another server, hand a table over, and say who is in tonight's turn (`table-servers.md`) | Hosts |
| **Take deliveries out** | A delivery can be handed to them: they are offered as a driver (`delivery.md`) | Drivers |
| **Set the kitchen rush** | Add minutes to every new quote while the kitchen is behind | Nobody |
| **Write the notes for the shift** | Put a note up for everybody, change it, take it down, and see who has read it (`shift-notes.md`) | Nobody |
| **Keep the manager's log** | Read and write what happened in a shift | Nobody |
| **Run the waste log** | Read the waste totals, and strike out anyone's entry of any day (`waste-log.md`) | Nobody |
| **See the reports** | Today, the day, sales, dishes sold, kitchen times, and what came off the checks; print the day; copy the sales of any days as a table for the accountant; every name and number of a staff contest's board; the suggestions taken, by person (`today.md`, `day-report.md`, `sales-report.md`, `dishes-sold.md`, `kitchen-times.md`, `contests.md`, `goes-with.md`) | Nobody |
| **See the guest list** | Phone customers: their numbers, visits and what they spent; tag a guest and write their note, tag a guest from their reservation or the waitlist with their PIN, and say afterwards which guest paid a check nobody was tapped on (`guest-list.md`) | Nobody |
| **See and correct the hours** | Everyone's hours on the time clock, and corrections to a shift (`time-clock.md`) | Nobody |
| **Edit the menu** | Dishes, prices and options, in the menu editor (`menus.md`) | Nobody |

Three of them deserve a thought before they are handed out. The guest list holds customers' names, phone
numbers and what they spent. The hours are what the staff is paid by, and a correction to a shift is logged
with who made it. And a person who approves voids and comps approves their own: the PIN is still typed, and
the voids and comps report still names who approved each one.

## What each person sees

- **In the menu of the Orders screen** (the three dots): **Kitchen rush** for whoever may set it, **Menu
  editor** for whoever may edit the menu, and **Location** for whoever has anything to open there.
- **Location** still asks for a PIN, as it always did. It then shows what that PIN's owner may open and
  nothing else: a host handed the reports finds Sold out and running low, The day, Sales, Dishes sold,
  Kitchen times and the Voids and comps report, and none of the settings. A manager finds everything, as before.
- **A PIN on a check.** Where a void, a discount or a tax-exempt check asks for a PIN, the box says whose it
  takes: "Voiding Duck (Kitchen error) needs a manager or a bartender." While nobody else holds the power it
  says "Manager PIN" and "needs a manager", as before. The check and the reports name whoever approved.
- **A wrong PIN** is told what it lacks: "Only a manager or a host can add minutes to the quotes."

The PIN is asked for every time, also of somebody who holds the power and is signed in. Typing it is the
approval, and it is what puts their name on the void.

## Good to know

- **A power goes to a whole role**, not to one person. To let one bartender approve voids and not the
  others, that bartender would need another role; there is no exception per person yet.
- **Taking a power back works at once.** A back-office session that is open, and an approval that was given
  and not used yet, are weighed against the table again when they are used.
- **An approval is not a sign-in.** The PIN typed on a check to approve one void, discount or tax-exempt
  check is good for that, on that one order, for ten minutes. It opens nothing in the back office: no
  report, no setting, no guest list, no menu. Those ask for the PIN at their own door, as they always did
  on the screens. (Since 23 November 2026 the hub itself turns such an approval away there; before, only
  the app kept the two apart.)
- **Take tables** is what puts a person in the list a host picks a server from, and gives them "Mine" on the
  floor map. **Give tables out** is what makes the floor map ask whose table it is when they seat a party,
  and lets them say who is in tonight's turn for a table (`table-servers.md`).
- **Take deliveries out** is what puts a person among the names offered when a delivery leaves. It limits
  nobody: whoever is signed in can hand a bag to a driver.
- **With an older hub** (one that has no table) the app does what it always did. On a hub that has the
  table and is older than drivers, the screen has no Drivers button and no "Take deliveries out".
- **With no hub or cloud answering**, nothing here can be changed, and a step that needs a PIN waits, as
  before.
- Not tried on the real devices from here.

## Not built

- Taking a power away from the managers, for example the sales for the owner alone.
- New limits where everybody may do something today: splitting a check, moving a table, reprinting a
  ticket, marking a dish sold out, opening a bar tab.
- A power for one person rather than for a role, and roles of your own beyond the eight.
- (Adding staff and changing somebody's role is built since: Location › Staff and PINs, `staff.md`.)
- A record of who changed the table and when.

## For developers

- Hub: `pos/identity/powers.py` (`POWERS`, `holds(setting, role, power)`, `held`, `clean_powers`, `table`).
  The setting is `powers` in `pos/settings.py`: `{"roles": {power: [role, ...]}}`, laid over the standard
  table one level deep, so a power added later starts with its standard roles.
- `GET /settings/powers` (open, like the other settings): `roles`, the `powers` in order with what each is
  for and whether a session is what uses it, the roles a power can be `handed` to, and the ones that `always`
  hold everything. `PUT /settings/powers` `{"roles": {...}}` with a manager's or an owner's token: the
  powers named change, the rest stay. 422 `bad_value` for a power or a role the hub does not know, for
  `manager` or `owner` in a list, and for `settings`.
- `pos/api/auth.py`: `holder_from(app.state, authorization, power)` is the check of a back-office call (401
  without a token, 403 `not_allowed` with `role` and `power`); `manager_from` stays the check of everything
  never handed out. Both read the table on every call. Both take a session alone (`session_of`): a token
  with a `scope` is an approval from `POST /approvals`, signed with the same key and naming the same
  person, and it is answered 401 `sign_in` like no token. `POST /waste/{id}/strike`, which reads the token
  itself, takes an approval for nobody special too. The other way round was always so: the operations ask
  for the scope ("void:o1"), so a session approves nothing.
- `POST /admin/session` takes `power` (what the session is for; without it, anything a session is for) and
  answers `powers`, what the PIN's owner holds. `POST /approvals` takes a PIN whose role holds the
  `purpose` (`void`, `adjust`, `exempt`). The checks of the operations themselves (`void_ops`, `exempt_ops`,
  `adjust_ops`) ask `may(role, power)` when the approval is used.
- `GET /staff`: `takes_tables` and `assigns_tables` follow `take_tables` and `assign_tables`, and `delivers`
  follows `deliver`.
- The app shows a role's button and a power's row only when the hub's table lists them (`Powers.handed`,
  `Powers.knows`), so one newer than its hub saves nothing that hub would refuse.
- App: `lib/powers.dart` (`Powers`, `powerGroups` with the screen's words, `whose`, `pinTitle`),
  `PosApi.powers` (the table as last read: with the quote times, when the hub's change feed says a setting
  changed), `lib/screens/powers_screen.dart`, `ManagerPinDialog.power`, `LocationSettingsScreen.holds`.
- Tests: `backend/tests/test_powers.py`, `apps/pos_app/test/powers_test.dart`.
