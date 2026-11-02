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
- Into another course before the kitchen has it, the line takes the new course with it and goes when that
  course fires (into a course already fired, it waits there as "1 to fire", like any dish added late).
- Into another course once the kitchen has it, the rule for every change to a fired line applies: the app
  asks first, then voids the line (a VOID ticket prints) and adds the same dish again under the new course,
  held until that course fires. "Keep it" leaves everything as it was.

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
- A line carries `rank`, its place on the check: `GET /orders/{id}` lists the lines in rank order and each
  carries its `rank`. An `add_line` without one goes after everything on the check; a drag is a `set_line`
  with `rank` (and `course` when the course changes, `null` taking the course off), halfway between the
  lines it lands between. A rank that is not a number is ignored. Moving a sent line within its course
  does not mark it modified; changing its course does.
