# Staff and PINs

Who signs in at a location, what each one's role is, and their PIN. Until 2026-11-24 the staff were one
line in the hub's own file (`POS_STAFF` in `/opt/pos/.env`), changed in the hub's terminal and in force
after `sudo hubctl update`. Now a manager or an owner keeps them in the app, under **Location › Staff and
PINs**, and a change is in force at once, with no restart.

Nothing has to be typed again. The people who sign in today show on the page as they are, each with the
PIN they have.

## The page

Orders screen › the three dots › **Location**, a manager's PIN, then **Staff and PINs**. The row itself
says how many people there are and what needs doing ("4 people · all with PINs from the guide, which
anybody can read"). Only a manager or an owner sees the row and opens the page. It is not a power that can
be handed to another role (`roles.md`).

The page lists everybody, each with their role and one line on their PIN: "PIN set by Mike today", "PIN
set in the hub's terminal on Nov 20", "PIN from the hub's terminal" (it came with the hub's own line), or
"PIN from the guide: change it". Your own row says "(you)".

- **Add a person**: a name, a role and a PIN. They sign in with that PIN at once, and take tables at once.
  Tell them the PIN: it is not shown again.
- **Tap a person** to change their name, their role or their PIN. The PIN box left empty keeps the PIN
  they have. A new PIN works at once, and the old one stops.
- **Take off the staff**, at the bottom of a person's box, asks first. They sign in no more, by PIN, tag
  or face, and the hub forgets their tag and their face. What they did (checks, hours, voids, history)
  stays under their name.

A PIN is never shown again once it is saved, to anybody. Somebody who forgot theirs gets a new one from a
manager.

## The rules the hub keeps

- **A PIN is four digits**, since the sign-in pad sends what was typed on the fourth.
- **Nobody else's PIN.** A PIN two people had would sign the wrong one in. The hub refuses it without
  saying whose it is.
- **A name of 1 to 40 characters, and nobody else's**, capitals aside: two people called Amy could not be
  told apart on a table or a ticket. Call the second one "Amy L".
- **The roles are the eight**: server, bartender, host, cashier, kitchen, driver, manager, owner. What
  each may do is under Location › Who may do what (`roles.md`).
- **There is always a manager or an owner.** The last one cannot be taken off the staff or given another
  role: nobody could open Location or approve a void after that.
- **Nobody takes themselves off the staff or changes their own role.** That is for another manager. Your
  own name and PIN are yours to change.
- **Only an owner changes an owner**, takes one off the staff, or makes somebody an owner. Anything else a
  manager and an owner do the same.
- **The first owner**: where nobody is an owner yet, a manager makes the first one, and that can be
  themselves. It is the one change of your own role the hub takes. Open your own row and tap **Owner**.
- **At most 200 people.**

## The first change takes the list over

Until somebody changes the staff in the app, the hub signs in whoever its own file names: the line
`POS_STAFF`, or the demo staff (Amy, Ben, Mike, Holly) where there is no line. The page says which.

The first change made in the app (or with `hubctl staff pin`, below) moves the whole list into the app as
it stands, everybody with the PIN they have. From then on:

- The app's list is the staff. `POS_STAFF` in `/opt/pos/.env` is not read any more, and editing it changes
  nothing. The line can be deleted. The hub's log and `sudo hubctl staff` both say so while it is there.
- Everybody keeps their id (`s1`, `s2`, ...), so tables, hours and history stay theirs. Somebody new gets
  the next number. An id is never used twice.

## The demo PINs

The demo staff's PINs (1111, 2222, 9999, 3333) are in this repository's guides, so anybody who has read
them can sign in as a manager. While anybody still signs in with one, the page shows a warning at the top
and Location's row says how many. Give each person a PIN of their own, the managers first.

## If no manager can sign in

Somebody who forgot their PIN gets a new one from any manager or owner. When no manager or owner can sign
in any more, the hub's terminal is the way back in:

1. `sudo hubctl staff` lists everybody: id, name, role and where their PIN is from. It never shows a PIN.
2. `sudo hubctl staff pin Mike` (a name, or an id such as `s3`) asks for the new PIN twice, without
   showing it. It works within a minute, with no restart, and the old one stops.

The same rules hold there: four digits, and nobody else's. Whoever can run this is root on the hub, so
this adds no way in that was not there. It is said in the list who set a PIN this way ("PIN set in the
hub's terminal").

## What stops when somebody leaves

- Their PIN, tag and face sign nobody in, from the moment of the change on this hub.
- A back-office session they had open (Location, the menu editor, reports) ends at once, and so does an
  approval they gave that was not used yet. The same holds for somebody whose role was changed: what they
  opened as a manager closes. (A manager made an owner, or an owner made a manager, goes on: the two may
  do the same.)
- A floor screen they are signed in on right now stays as it is until they sign out or the screen locks.
  What they do there is recorded under their name as before.

## Where it is kept

- **In the hub's database** (table `staff_member`), so a location's second hub has the same staff. A
  change made on one hub is in force there at once, and the other hub finds it within a minute. (The cloud
  copy comes with the cloud slice, as for the location's settings.)
- **A PIN is kept as a salted hash**, never as typed, and no call of the hub gives a PIN, a hash or a
  salt back. The hub's log says who was added, changed or taken off and by whom, never a PIN.
- **What that protects, honestly**: nobody reads a PIN off a screen, a log or a backup's text. But a PIN
  is four digits, so somebody who has a copy of the database can try all ten thousand against a hash in a
  moment. Treat a backup of the hub as you would the list of PINs itself. (The line in `/opt/pos/.env`
  held them in the clear.)
- **Not on the screens.** A terminal sends what the manager typed to the hub once and forgets it. The
  list of names and roles each device keeps for seating (`table-servers.md`) has no PINs in it.

## Good to know

- **The hub has to answer.** The staff are changed on the hub, so while no hub answers the page says so
  and nothing is changed. Signing in with a PIN needs the hub too, as before.
- **A location's standby hub** takes no change: the staff are changed on the hub in charge, and the
  standby has them within a minute.
- **An app newer than its hub** says on the row "This hub is older than the staff kept in the app: update
  it (sudo hubctl update)", and the staff stay as the hub's file has them until then.
- **A hub newer than an app** changes nothing for that app: it signs in as before, with whatever PINs are
  in force.
- Five wrong PINs on one device lock its pad for a minute, as before.

## Not built

- A person changing their own PIN at the sign-in pad. A manager does it.
- Bringing back somebody who was taken off. Add them again: they get a new id, and what they did before
  stays under the old one, with the same name.
- PINs longer than four digits.
- Signing somebody out of a floor screen the moment they are taken off the staff.
- A list of who changed what on the staff, in the app. The hub's log has it (`hubctl logs api`, lines that
  start `staff:`), and each person's line says who last set their PIN.
- Pay rates, phone numbers, schedules: a person here is a name, a role and a PIN.

## For developers

- Hub: `pos/identity/staff_list.py` is the list and its rules (`StaffList.add`, `change`, `remove`,
  `may`, `in_force`; `Refused` carries a code and words that never repeat a PIN). `StaffStore` keeps it in
  memory, `PgStaffStore` in `staff_member`; a take-over writes the hub's own people and the change in one
  transaction. `by=None` is the hub's terminal.
- `pos/api/staff.py`: `GET` and `POST /hub/staff`, `PUT` and `DELETE /hub/staff/{id}`, a manager's or an
  owner's token only. `use_staff(app)` puts the list in force by changing the one `Directory` every other
  module reads (`Directory.use`), and forgets the tag and face of whoever is gone. `watch_staff` looks
  every 60 seconds whether the stored list changed under this hub (`StaffList.mark`).
- Refusals: 422 `bad_value`; 409 `pin_taken`, `name_taken`, `last_manager`, `yourself`, `full`; 403
  `owner_only`, `not_allowed`; 404 `unknown_staff`; 503 `read_only` on a standby.
- Tokens: `Tokens.still` asks the directory whether a grant's holder is still on the staff in the role
  the grant names (a manager's and an owner's count as one), so sessions and approvals end with the person
  (`pos/identity/tokens.py`, `create_app`).
- Terminal: `infra/hub/hubctl staff` runs `python -m pos.identity.staffctl` in the API's container, the
  new PIN on standard input and never on the command line. CI's "hub's services together" step sets a PIN
  this way on the real services and waits for the API to take it.
- App: `lib/staff_list.dart` (`StaffList`, `StaffPerson`, the words of a PIN's line),
  `lib/screens/staff_screen.dart` (`StaffScreen`, `StaffPersonDialog`), the row in
  `lib/screens/location_settings_screen.dart`, the four calls in `lib/api.dart`.
- Tests: `backend/tests/identity/test_staff_list.py`, `backend/tests/test_staff_api.py`,
  `backend/tests/identity/test_staffctl.py`, `apps/pos_app/test/staff_screen_test.dart`.
