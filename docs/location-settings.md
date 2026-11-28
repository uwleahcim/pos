# Location settings

What a manager changes for the whole restaurant, from any terminal, and every terminal follows. The
settings are data on the hub, never code: a `setting` row per set in PostgreSQL (replicated to the standby
hub like the orders and the menu; the cloud copy comes with the cloud slice), served to every terminal
and edited only with a manager's session token.

## How a setting is saved

Every setting is saved the same way, here and on the screens and dialogs this screen opens: **nothing
takes effect as it is changed.**

- **On the screen itself** (the courses, the seat numbers, the time clock, what the tickets say, the desk
  phones, face sign-in, the hands-free switching): flip a switch, type a name or pick from a list, and a bar
  comes up at the bottom of the screen with **Save** on it. The bar says what is waiting ("Not saved: courses, time
  clock") and stays at the bottom however the screen is scrolled, above the keyboard too. Scrolled all the
  way down it rests at the end of the screen; scrolled back up it follows. One **Save** keeps everything
  that waits. Put a thing back as it was and it waits no longer; with nothing waiting the bar goes.
- **A row with an arrow** opens a dialog or a screen of its own. A dialog has **Cancel** and **Save** at
  its foot, always in view. A screen (Printers, Who may do what) has the same bar as this one.
- **What the hub refuses** is said in the bar, above Save, with the name of what it is about ("Courses:
  Every course needs a name."). That part keeps waiting; the others are saved.
- **Leaving with something waiting asks first**: Keep editing, or Discard changes.
- What is not a setting does what it says at once: a test print, enrolling a face, forgetting a tag.

A device's own **Settings** (the gear) work the same way: the bar with Save comes up with the first change.

## Where

Orders screen › **Location** (the manager PIN again, like the menu editor). The settings are a manager's
and an owner's, always. The reports, the guest list, the waste log, the notes, the log and the hours can be
handed to other roles under **Who may do what** (see `roles.md`); whoever was handed one finds Location in
the menu, and behind their own PIN only the rows they may open. The screen holds:

- **Sold out and running low**, first, because it is what a manager looks at during service: how many
  dishes are sold out and how many have a number left, and the list of them with the fewest left at the top
  (see `eighty-six.md`). Not a setting: a dish is put on it from the order screen.
- **Today**, under it, for during service: the night as it stands on one screen, beside the same day last
  week at this time (see `today.md`). It is under **More** on the orders screen as well. Not a setting either.
- **The day**, under that, for when service is over: what is still open, the day's sales, the money taken and
  what came off the checks, for any day, with a print (see `day-report.md`). Not a setting either.
- **Sales**, under that: any days, from one to 92, with every figure beside the same days whole weeks
  earlier (see `sales-report.md`). Not a setting either.
- **Dishes sold**, under that: every dish of the same days, best to worst or worst first, with its sizes
  and its options (see `dishes-sold.md`). Not a setting either.
- **Suggestions taken**, under that: the dishes added from "Goes with" on the order screen in the same
  days, by person and under the dish each went with (see `goes-with.md`). Not a setting either.
- **Guests**, under that: every customer who ordered with a phone number in the last 12 months, with their
  visits, what they spent and their favourite dishes, and the regulars, the guests who stopped coming and
  the new ones each a list (see `guest-list.md`). Not a setting either.
- **Contests**, on the card under those: the contests for the staff, each with its whole board, and where
  a manager sets one up: the most sales, or the most of a dish or a category, over some days (see
  `contests.md`). Not a setting either.
- **Notes for the shift**, under it: what everybody sees once after signing in (the specials, what is
  out), who has seen each note, and the notes that came down (see `shift-notes.md`). Not a setting either.
- **Manager's log**, under that: what happened in a shift, by subject, for the next manager (see
  `shift-notes.md`).
- **Who may do what**: which roles besides the managers and the owners may approve a void, a discount or a
  tax-exempt check, read the reports and the rest: fourteen powers, each with a button per role (see
  `roles.md`).
- **Keys and connections**, on the same card: the hub's keys for the services outside the restaurant (the
  map service, Google Maps, GloriaFood, Apple's push key), typed here where they used to be put on the hub
  in its terminal. A manager's and an owner's only, never handed to another role (see `hub-keys.md`).
- **Course the dishes**: on or off.
- **The courses**, when on: as many as the kitchen serves, in the order it serves them. Rename, add,
  remove, drag to reorder; the star marks the course a new dish goes to.
- **Seat numbers**, on the same card, under the courses: on or off (on to start, as every table had seats
  before a location could say; see "Seats on the order screen" below).
- **Quote times**: the minutes per channel, which channels may pay at pickup, how long before its time a
  catering order's ticket prints, and how many more minutes an order of so many dishes takes (see
  `counter-mode.md`). Tonight's rush is not here: it is the flame on
  the orders screen, because it is set in the middle of service.
- **To-go question**, on the same card: whether a to-go order is asked what goes in the bag before it is
  sent (on to start), the question's words and the things it offers, eight at most (see
  `to-go-question.md`).
- **Shipday moves the check**, on the same card: on or off (on to start). Whether a delivery picked up or
  delivered in Shipday takes its check Out or closes it by itself (see `shipday.md`, "Shipday moves the
  check"). A hub from before it shows no such switch.
- **Ready tells Shipday**, under it: on or off (on to start). Whether a delivery's check marked Ready on the
  POS tells Shipday it is ready for pickup by itself; off, Shipday is told only by the button on the Shipday
  screen (see `shipday.md`, "Saying it is ready for pickup"). The two are saved as one part, "Shipday", and
  only the one that was turned is sent. A hub from before it shows the first switch alone.
- **Kitchen notes**, on the same card: the one-tap notes a dish's sheet offers over its note ("Rush",
  "Split for 2"), twelve at most (see `kitchen-notes.md`).
- **Floor plan**: the floor the map shows, drawn in the app: tables moved, sized and turned, new ones
  ready-made, rooms added, named and taken off (see `floor-editor.md`).
- **Table timers**: the countdown ring on each table of the floor map, on or off, and the minutes each thing
  a table can be waiting on is given (see "Table timers" below).
- **Kitchen screens**: the minutes a ticket has been in the kitchen when a station's screen turns it amber,
  and red (see `kitchen-screens.md`).
- **Voids**: whether voiding a dish the kitchen already has takes a manager's PIN, and the reasons to pick
  from; under it, the **Voids and comps report**, which also lists the dishes taken off a check before they
  were sent (see `voids.md`).
- **Time clock**: whether the location uses it (off to start), whether a break counts as time worked, and
  the day the pay week starts on; under them **Hours**: who is on the clock, what each person worked, and
  a manager's corrections (see `time-clock.md`).
- **Printers**: its own screen: each printer with the station it prints for, its address and language, its
  fallbacks in order, a test print; the stations the menu prints at with no printer yet, to add with a tap;
  finding the printers on the network; the station a to-go order prints whole at (see `printing.md`).
  At its top, **Print log**: every paper the hub printed in the last 14 days, how it went, the paper itself
  on the screen (one at a tap, or every one with **Expand all**), and **Reprint**; read by printer, by kind
  of print (kitchen, bar, bills, reprints, the rest) or by a search of the papers, which marks the words it
  found on them (see `printing.md`, "The print log").
  On the same card, two switches for what the tickets of one send say about each other: **Number the
  tickets of one send** ("Ticket 2 of 3") and **Name the other stations on each ticket** ("Also at: Wok 2,
  Sushi Bar"). A third switch, **Print PAID or NOT PAID on to-go orders**, is for the takeout station's
  ticket, and a fourth, **Tell the kitchen when a table moves**, for the MOVED slip (see `moves.md`). A
  fifth, **Print a pack sheet with a catering order**, is for the sheet that comes with a catering
  order's first tickets, every dish with a box to tick (see `catering.md`). All
  on to start; once a flip is saved the next ticket prints by it. The row **Screens that skip a
  station** says which stations a screen prints no ticket at (the bar's own screen and the bar printer;
  none to start; see `ticket-skips.md`).
- **Desk phones**: which screen each desk phone is linked to, so a call taken on the phone opens the
  caller's order on that screen (see `desk-phones.md`); the card says how the hub stands with the PBX.
- **Sign in by face**: the location's switch (off to start), how the hub stands with its face models (and,
  with the switch off, that no screen looks until it is on), and the staff by name with each one's
  enrollment: Enroll (this screen's camera), Enroll again, the bin to forget a face, the tag button to give
  the person a tag held to this screen's reader (or typed), the crossed-out one to forget it (see
  `face-signin.md`).
- **Hands-free**: **Switch to whoever steps up** (on to start: a face the camera knows or a tag held to the
  reader makes the screen that person's at once; an open order stays open and each dish added from then on
  is theirs), and how long the
  camera may go without seeing the signed-in person before the screen signs them out (never, 30 seconds, 1,
  2, 5 or 10 minutes; a minute to start), once it has recognised them.

**Save**, in the bar at the bottom of the screen, sends the courses to the hub, which checks them (a name
on every course, no name twice, at least one course while coursing is on) and keeps them. Every terminal
reads the setting when it opens an order, so a change reaches the floor on the next check anyone opens.

## Finding a setting

The screen is long and half of its settings are inside the pages and dialogs its rows open, so it has a
search. The **magnifier** at the top right opens it (**⌘F** on a Mac, **Ctrl+F** on another keyboard): the
title becomes a box with the keyboard in it, and what is typed lists what it finds, as it is typed, in the
place of the screen. The cross, **Escape** or Back closes it and the screen is as it was.

- **What is searched**: the name of every row of the screen, and of every setting inside a row's page or
  dialog ("Charge sales tax on the fee" in Delivery fee, each power of Who may do what, each key of Keys and
  connections, the fallback of a printer). Also the words people say for a setting that its name does not
  have: "receipt" finds The bill, "employees" and "password" find Staff and PINs, "payroll" finds the hours
  and the pay week, "86" finds Sold out and running low. Not searched: what a setting is set to (a person's
  name, a void reason, a printer's address), and a device's own Settings (the gear).
- **How it reads what is typed**: capitals do not matter, nor the order of the words, nor small words
  ("the fee for a delivery" is "fee delivery"). Every word typed must be found. A start of a word is
  enough ("deliv"); "togo", "to go" and "to-go" are the same; "taxes" finds "tax". When nothing is found as
  typed, one typing mistake in a word is forgiven ("recipt", "delviery"). Nothing found says so, with what
  to try.
- **The order**: the best match first. A name that is what was typed comes before one that only has it in
  it, a row before a setting inside one, and of two as good the one that is higher on the screen.
- **What a result shows**: the name with the part that was typed in bold, the icon of its row, and under it
  what the row is for, or "In Delivery fee" for a setting inside that row. An arrow where a tap opens
  something.
- **A tap on a result** (Enter takes the first):
  - a setting **on the screen itself** (Seat numbers, the time clock, the ticket switches): the search
    closes, the screen scrolls to the setting and it is **lit** for a moment, a ring in the theme's colour
    that fades. The keyboard's focus goes to it.
  - a row that **opens a page or a dialog**: it opens, over the results. A setting inside it: the page
    opens scrolled to that setting, lit there. Closed again, the results are still there for the next one.
  - a row the hub has not answered for (an older hub) is shown where it stands, where it says why.
- **Who finds what**: only the rows that are on the screen for whoever opened it. Someone who was handed
  the reports and no settings finds the reports and nothing else.
- **What waits to be saved** waits through a search: the bar with Save stays where it is, the search open
  or not, and Back closes the search before it asks about leaving.

### For whoever adds a row or a setting

The search reads one list, `locationSettings` in `apps/pos_app/lib/setting_search.dart`, in the order of
the screen. A line is a row (its key on the screen and its name), a setting inside a row's page or dialog
(the row's key, its name, and a `Spot`: the key the setting's widget already has, or the words that head
it), or a setting that shows under another on the screen (`under`). `also` holds the other words for it.
Nothing else is written down: whether a row is there for this person and this hub, its icon, and what a tap
on it does are read from the screen as it is built (the list builds all its rows for that), and a result
opens a page by the row's own tap. A page opened that way is wrapped in `Spotlight`
(`screens/spotlight.dart`), which finds the spot, scrolls to it and lights it; the page knows nothing of it.
A function that opens a page takes `final lit = _lit;` as its first line and shows `lit(page)`.

Two tests keep the list and the screen together (`test/location_search_test.dart`): every row of the screen
with a key must be in the list, and every line of the list must open and land on its setting on a
phone-sized screen. A new row without a line fails the first; a line whose key or heading has changed fails
the second.

## Coursing on the order screen

With coursing **on**, the bar above the menu offers the seats and the courses by name, the star's course
chosen for a new dish; the check groups its lines by course in kitchen order with each course's state
(held, fired, N to fire); **Fire** lists each held course by name, then "everything"; the kitchen ticket
says `Course: Appetizers` as the manager named it.

With coursing **off**, the bar shows the seats alone, a dish goes to the kitchen with no course, the check
is one group ("Items"), and **Fire** sends everything (and stays on the check, or leaves it). The button
counts the dishes still to send.

A course taken off the list keeps its id on the lines that already carry it: they show under that id on the
check and on the ticket, and still fire. Turning coursing off keeps the courses for when it comes back.

## Seats on the order screen

**Seat numbers** is the other half of how a table's order is taken, and its own switch: a location may
course without seats, seat without courses, do both or neither. It is on to start.

With seat numbers **on**, the bar above the menu offers **Table** and a chip for each seat, with **−** and
**+** to take the last seat away or add one; the seats are the party's size. Each dish on the check says
its seat, or "table"; an allergy is the table's or a seat's; a check can be split **By seat**; the kitchen
ticket marks a seat's dish `[s2]`.

With seat numbers **off**, for a house that rings every dish in for the table:

- The bar has no seats. A dish goes to the kitchen with no seat, and says none on the check (the quantity
  stands alone in its box) or on its ticket.
- **The party's size stays**, since the seats were where it was set and the sales per guest, an even split
  and any charge that goes by the size of the party read it: `Party 4` with the same **−** and **+**. On a
  tablet it stands where the seats were. On a phone, where the bar is one line, it comes after the courses:
  a course is picked for every dish and the party is changed now and then, so the courses are the ones in
  reach without scrolling.
- **An allergy is the whole table's**: the box does not ask whose it is.
- **Split** offers Evenly and One check, and dishes are still moved between checks by hand; By seat is left
  out.

Nothing already on a check is lost by the switch. A dish that was rung in on a seat keeps it: the check
still says "seat 2" under it, its ticket still says `[s2]`, and By seat is still offered for that check. An
allergy noted for a seat stays in the red strip and can still be changed and taken off. The hub refuses
nothing for the setting, so a screen that has an order open while a manager flips the switch finishes that
order the way it started; the next order it opens follows. Turning the seats back on brings everything
back as it was.

Not touched by the switch: a to-go order (it never had seats), a bar tab (it has none until it sits down at
a table), the floor map, reservations and the waitlist, which count guests, not seats.

## Table timers

Every busy table on the floor map wears a countdown on its edge: a ring that starts whole and unwinds as the
table waits, like the dial of a kitchen timer going back to zero. What is left runs clockwise from twelve
o'clock (the top of the table on the screen, however the table is turned), and its far end draws back
counter-clockwise until nothing is left. It is the table's own colour while there is time, turns amber when
it is running out, and when time is up it stands whole again in red and flashes. An amber or red table carries a
badge with a mark for what it is waiting on and the minutes left ("7m") or over ("+2m"). The number inside
the table is still the minutes since it was sat. Beside the count of open tables, a pill counts the tables
out of time (red) and running out (amber) on the whole floor, whichever room is shown; a tap lists them in
words ("A7 · Course held · Held 18 min · 7 min left") and a tap on one opens the table.

What a table waits on is read by the hub from the check's own history, so every screen shows the same:

| The table is | Counted from | Amber | Red |
| --- | --- | --- | --- |
| Seated, nothing ordered (a seat) | the check being opened | 5 min | 10 min |
| Dishes not sent (an arrow) | the first dish on the check nobody sent | 5 min | 10 min |
| Course held (a pause) | the course before it going to the kitchen | 15 min | 25 min |
| Everything sent (a bell) | the last dish sent | 25 min | never |

- "Dishes not sent" is the forgotten Fire: nothing has gone to the kitchen at all, or a dish was added to a
  course that had already gone. It shows before a held course, since it wants a hand sooner.
- A held course counts from when the course before it (in the kitchen's order of courses) went, not from
  when it was put on the check, so dessert entered with the starters starts counting when the mains go. A
  drink sent in between does not start it over. A course ordered later than that counts from when it was
  ordered.
- Everything sent only nudges: the hub does not hear when food reaches the table, so this is how long the
  table has been left to itself. It turns amber as a reminder to look in, and never red.

A manager sets the minutes under Location › **Table timers**: two numbers per row, amber and red, 0 for
never (both 0 and that row is not timed), and one switch for the rings altogether. Red must come after
amber. Every floor map follows the moment it is saved.

The times are measured on the hub's clock: a terminal reads the time off the hub's answers and, when its own
clock is more than two seconds away, corrects by the difference, so two screens draw the same ring. A check
taken while no hub answers is timed by the terminal from its own operations until a hub has it.

## Arranging the check

Every line has a place on the check: the order it was added, until someone moves it. Hold a dish by its
name and drag it to another place, or under another course's header. Every course the location serves has
a header on the check (dimmed while nothing is under it), so a dish can go into a course that is still
empty. The kitchen ticket, the check on every terminal and the receipt list the lines in that order.

- Within its course, a line just moves, sent to the kitchen or not: the kitchen is not told.
- Into another course, a line takes the new course with it. Before the kitchen has it, it goes when that
  course fires (into a course already fired, it waits there as "1 to fire", like any dish added late). Once
  the kitchen has it, it moves just the same and stays sent: nothing is voided or sent again, and it is not
  on the ticket of the course it joins (Mike, 2026-11-02). The course a sent dish shows under is the check's
  business; the kitchen keeps it on the ticket it went out on.
- To move several at once, hold one and, with another finger, tap the others: each tap folds a dish out of
  the list and stacks it behind the one in hand like a fanned deck of cards, showing all but its top edge,
  so the dish and its quantity can still be read and the stack stays shorter than the rows (a tap on the
  showing part of a card puts that dish back). The rows open room for the stack where it would land and
  move out of its way as it passes them, and once let go the stack comes down onto that room and spreads
  into full rows, the rows around it moving apart to fit them; the dishes take their places in the order
  stacked: the one held, then the others as they were tapped. This takes a second finger, so it is for the
  phones and the iPads; on the Mac, dishes move one at a time.
- While a dish is in hand, two places show at the foot of the check: **Comp** and **Void**, with the number
  in hand when there is more than one ("Comp 3", "Void 3"). Letting go over one of them moves nothing: it
  comps or voids every dish in hand with one reason and one manager PIN (`discounts.md` and `voids.md`,
  "Several dishes at once"). The place under the finger lights up, the check stops scrolling while the
  finger is on one, and letting go anywhere else is a move as before. Void reads **Take off** when the
  kitchen has seen none of the dishes in hand.

## On the wire

- `GET /settings/coursing`: `{"enabled": true, "default": "1", "courses": [{"id": "drinks", "name":
  "Drinks"}, {"id": "1", "name": "Appetizers"}, ...]}`. The defaults are the standard four (drinks,
  appetizers, entrees, dessert), a new dish going to the appetizers.
- `PUT /settings/coursing` with the manager Bearer token (`POST /admin/session`): the same shape. A course
  without an `id` is new and gets one from its name (`Soup & Salad` becomes `soup-salad`, numbered when
  taken); the app names its own new courses the same way. Ids are letters, digits, `-` and `_` (never
  `*`, which a `fire` uses for every course); names are at most 40 characters. A bad body is 422 with
  `message` saying why; a standby hub is 503 `read_only`.
- `GET /floor` carries `courses`: the list while coursing is on, empty while it is off.
- `GET /settings/seats` and `PUT /settings/seats` (the manager Bearer token): `{"enabled": true}`, whether
  a table's dishes are rung in on seats. A `PUT` has to say `enabled`; a bad body is 422, a standby hub 503
  `read_only`. The terminal reads it beside the coursing as it opens an order, keeps the last answer for
  when no hub answers, and takes a hub that has no such setting (404) as one whose tables have seats. An
  order line's `seat` is never refused for the setting.
- `GET /settings/table_timers` and `PUT /settings/table_timers` (the manager Bearer token): `{"enabled":
  true, "stages": {"sat": {"warn": 5, "late": 10}, "unsent": {"warn": 5, "late": 10}, "held": {"warn": 15,
  "late": 25}, "fired": {"warn": 25, "late": 0}}}`, whole minutes, 0 for never, at most 1440, `late` after
  `warn`; a stage left out keeps its default. `GET /floor` carries the same as `timers`, and each open
  check there carries `timer`: `{"stage": "held", "since_ms": 1800000000003}`, the stage it waits on and
  the wall-clock ms it began (from the stamps in the order log). Nothing in the floor's answer moves with
  the clock, so it is still answered `304` until an order or a setting changes; the terminal runs the
  countdown.
- `GET /settings/floor_plan`, `PUT /settings/floor_plan` and `DELETE /settings/floor_plan` (the manager
  Bearer token for the last two): the floor as the floor editor reads and saves it; details in
  `floor-editor.md`.
- `GET /settings/kitchen_screens` and `PUT /settings/kitchen_screens` (the manager Bearer token): `{"warn":
  10, "late": 20}`, the minutes after which a ticket on a station's screen turns amber and red; details in
  `kitchen-screens.md`.
- An order line's `course` and a `fire`'s `course` are ids; the hub never refuses a line for its course,
  so a terminal with an older list can still send what it took.
- `GET /settings/quotes`, `PUT /settings/quotes` and `PUT /settings/rush`: see "On the wire" in
  `counter-mode.md`.
- `GET /settings/desk_phones` and `PUT /settings/desk_phones` (the manager Bearer token): `{"links":
  [{"extension": "200", "device": "tab1"}]}`, each extension once; details in `desk-phones.md`.
- `GET /settings/faces` and `PUT /settings/faces` (the manager Bearer token): `{"enabled": false}`; the
  enrollment calls are in `face-signin.md`.
- `GET /settings/presence` and `PUT /settings/presence` (the manager Bearer token): `{"switch": true,
  "away_seconds": 60}`, the seconds 0 (never) to 3600; the tag calls are in `face-signin.md`.
- `GET /settings/time_clock` and `PUT /settings/time_clock` (the manager Bearer token): `{"enabled":
  false, "breaks_paid": false, "week_starts": "mon"}`, the week's first day `mon` or `sun`; a key left out
  of a `PUT` keeps what it was. The clock's own calls are in `time-clock.md`.
- A line carries `rank`, its place on the check: `GET /orders/{id}` lists the lines in rank order and each
  carries its `rank`. An `add_line` without one goes after everything on the check; a drag is a `set_line`
  with `rank` (and `course` when the course changes, `null` taking the course off), halfway between the
  lines it lands between (several dropped together take ranks spread evenly between them). A rank that is
  not a number is ignored. Moving a sent line, within its course or to another, does not mark it modified
  and does not touch when it was fired: it stays as it went out. A line not yet sent is marked a late
  addition while it sits under a course that has already fired, wherever it came from.
