# Location settings

What a manager changes for the whole restaurant, from any terminal, and every terminal follows. The
settings are data on the hub, never code: a `setting` row per set in PostgreSQL (replicated to the standby
hub like the orders and the menu; the cloud copy comes with the cloud slice), served to every terminal
and edited only with a manager's session token.

## Where

Orders screen › **Location** (managers and owners only, the manager PIN again, like the menu editor). The
screen holds:

- **Course the dishes**: on or off.
- **The courses**, when on: as many as the kitchen serves, in the order it serves them. Rename, add,
  remove, drag to reorder; the star marks the course a new dish goes to.
- **Quote times**: the minutes per channel and which channels may pay at pickup (see `counter-mode.md`).
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

**Save** sends the courses to the hub, which checks them (a name on every course, no name twice, at least
one course while coursing is on) and keeps them. Every terminal reads the setting when it opens an order,
so a change reaches the floor on the next check anyone opens.

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
- An order line's `course` and a `fire`'s `course` are ids; the hub never refuses a line for its course,
  so a terminal with an older list can still send what it took.
- `GET /settings/quotes` and `PUT /settings/quotes` as before.
- `GET /settings/desk_phones` and `PUT /settings/desk_phones` (the manager Bearer token): `{"links":
  [{"extension": "200", "device": "tab1"}]}`, each extension once; details in `desk-phones.md`.
- `GET /settings/faces` and `PUT /settings/faces` (the manager Bearer token): `{"enabled": false}`; the
  enrollment calls are in `face-signin.md`.
- `GET /settings/presence` and `PUT /settings/presence` (the manager Bearer token): `{"switch": true,
  "away_seconds": 60}`, the seconds 0 (never) to 3600; the tag calls are in `face-signin.md`.
- A line carries `rank`, its place on the check: `GET /orders/{id}` lists the lines in rank order and each
  carries its `rank`. An `add_line` without one goes after everything on the check; a drag is a `set_line`
  with `rank` (and `course` when the course changes, `null` taking the course off), halfway between the
  lines it lands between (several dropped together take ranks spread evenly between them). A rank that is
  not a number is ignored. Moving a sent line, within its course or to another, does not mark it modified
  and does not touch when it was fired: it stays as it went out. A line not yet sent is marked a late
  addition while it sits under a course that has already fired, wherever it came from.
