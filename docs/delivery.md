# Delivery orders

An order that is brought to the customer by the restaurant's own driver. It is a to-go order like any
other (`counter-mode.md`): named, numbered, rung in from the menu, paid the same ways. What it adds is
**where it goes**, a **note for the driver**, a quote that allows for the drive, and the word DELIVERY on
every paper, so nobody packs it for the shelf.

When the bag leaves, it is **handed to a driver**: the order says who has it and since when, and the
**Deliveries** screen shows what is waiting to leave and what each driver has out (see
[Drivers](#drivers)). **Runs** says what each driver took out over the day, run by run (see
[Runs](#runs)). Nothing here is about money: there is no delivery fee and no tip yet, and a delivery is a
sale like any other, counted in every report as a to-go order is.

(Orders that come from a delivery app are something else: they arrive on their own channel, in a later
phase.)

A **catering order** has had Pickup or Delivery since it was built, among what its event needs
(`catering.md`). One that is delivered is now marked in the same places as any other delivery: its tickets
and its bill say DELIVERY, its row on the list of checks says where it goes and ends with **Delivered**,
it is not on the pickup board, and nobody is texted to come for it. Its form, its time and its quote are
as they were.

## Taking one

On the list of checks, tap **To go**. Under the channels (Counter, Phone, Catering) the form asks
**Pickup** or **Delivery**. Pickup is picked, and the form is what it always was.

Tap **Delivery** and the form asks for:

- **Deliver to**: the address. The order cannot start without one.
- **Note for the driver**: whatever helps at the door ("ring twice, side door"). It can be left empty.

The phone number is the one the driver calls from the door, and the form says so. It is not required, but
ask for it.

**The quote is Delivery's.** The form says "There in about 45 min" in place of "Ready in about 20 min":
the minutes are the ones set for Delivery under the quote times (Location › Quote times), whoever took the
order, and they are meant for the cooking and the drive together. A rush and a big order add their minutes
as on any quote. For an order **for later**, the time the customer named is the time at their door, and the
kitchen starts that many minutes before it.

### A customer who had one before

When a number is typed, or a call is answered, the form looks the customer up as it always did
(`customers.md`). If that number had an order delivered before, the **address of their latest delivery**
and **what was said for the driver** are already in the boxes when Delivery is tapped. Read the address
back to the customer and change it if they have moved.

- An address somebody typed is never replaced.
- When the number in the box becomes another customer's, an address the form filled in goes away again:
  one customer's address never goes on another's order.
- Nothing new is kept for this. The address is read off the customer's own past order, like their name.
  It is shown to whoever is taking the order and to nobody else.

## On the order

A to-go order has a chip beside **Allergy** that says how it leaves: **Pickup**, or **Delivery** (filled in,
so it is not missed). Tap it to change it: make a pickup a delivery, change the address or the note, or
make a delivery a pickup again.

A delivery also says where it goes on a line under the bar:
**Delivery · 12 Elm St, Winchester · Ring twice, side door**. A tap on that line changes it too. (On an
order for later the same line starts with its day and time.)

**Changing it moves the quote**, as long as the kitchen does not have the ticket yet:

- An order for now that becomes a delivery is promised later by the difference between the two quotes
  (25 minutes with the times as they come), and the screen says the new time so you can tell the
  customer: "Now a delivery: there about 19:25." Back to a pickup, it is promised that much sooner.
- An order the customer named a time for keeps its time, and the kitchen starts sooner: "Now a delivery:
  the kitchen starts it 25 minutes sooner."
- Once the kitchen has the ticket, the time stays as it is. Tell the customer yourself.

The check's history keeps who changed what.

## The papers

- **Every station's ticket says DELIVERY**, beside how the order was taken ("Phone  DELIVERY"), so the
  kitchen and whoever packs know it does not go on the pickup shelf. A ticket does not say the address or
  the phone number: a cook has no use for them.
- **The bill says where it goes.** Under the order's number and name there is a block: DELIVERY, the
  address, "Phone" with the number, and the note for the driver. Print the bill and send it with the bag:
  it is the driver's paper. With no address on the order it says "No address was given", so the driver
  asks before leaving.
- The **pack sheet** (`catering.md`) says DELIVERY and the address too, as it did for a catering order. Its
  button is at the end of the delivery's line under the bar.

## The list of checks

A delivery's row says **delivery** after the name, **there 19:25** in place of "ready 19:25", and the
address at the end. Its steps are **Ready**, **Out** and then **Delivered** in place of "Picked up". While
nothing was taken for it the row says **pay at the door** in place of "pay at pickup", and where an order
may be sent to the kitchen unpaid (a phone order), that choice is called **At the door**.

- **Ready** texts nobody. The ready text says "ready for pickup", and nobody is coming. (A pickup order
  still gets its text.)
- **Out** asks who takes it (see [Drivers](#drivers)). The row then says **OUT** and "Tom since 18:40".
- **Delivered** closes the check. If money is still due it asks for it first, as "Picked up" does: Cash,
  Paid elsewhere, or Not now.
- A delivery whose time is pushed back gets a text that says when it will be there, not when to come for
  it. An order that was just changed from pickup to delivery gets none: the customer asked for that.

(Texts go to the hub's log until a texting service is set up; none is connected yet.)

A delivery is **not on the pickup board** (`pickup-board.md`): nobody stands at the shelf waiting for it.

## Drivers

### Who takes deliveries out

A delivery can be handed to anybody who holds the power **Take deliveries out**. To start, those are the
people whose role is **driver**, and, as with everything, a manager and an owner. Nobody who was on the
staff before holds anything new.

- **To add a driver**, put them on the hub's staff list with the role `driver` (the steps are under
  [Adding a driver](#adding-a-driver) below). A driver signs in with their PIN like everybody else.
- **If your servers or hosts take deliveries out too**, hand them the power under Location › **Who may do
  what** (`roles.md`): the row is "Take deliveries out", in the group Deliveries. They are then offered
  beside the drivers.
- With the demo staff nobody is a driver, so only the manager (Mike) is offered, and the picker says where
  drivers are named.

Handing a bag out is not a power: whoever is signed in can do it, as anybody can tap Ready. Who did it is
kept in the check's history.

### Adding a driver

There is no screen for the staff yet: the list is one line on the hub. On the hub:

1. `sudo nano /opt/pos/.env`
2. Add one line that names **everybody**, a manager among them, each as `id:name:role:pin`, with commas
   between and no spaces. With the demo staff and two drivers it reads:

   `POS_STAFF=s1:Amy:server:1111,s2:Ben:bartender:2222,s3:Mike:manager:9999,s4:Holly:host:3333,d1:Tom:driver:4444,d2:Wei:driver:5555`

   Keep the ids people already have (`s1` to `s4`): tables, hours and history are kept under them. The
   drivers' names and PINs here are made up: type your own, a different PIN for each person.
3. Save (Ctrl+O, Enter, Ctrl+X), then `sudo hubctl update`.

Good to know:

- **The line is the whole staff.** Whoever is not in it can no longer sign in. Without the line the hub
  uses the demo staff (Amy, Ben, Mike, Holly).
- **Name a manager or an owner.** A list without one leaves nobody who can approve a void or open
  Location; the hub says so in its log (`hubctl logs api`) and keeps the list as typed.
- **A slip does not stop the hub.** An entry that does not have its four parts, or repeats an id, is left
  out and the log says which one (by its place in the line, never its PIN). If nothing in the line reads,
  the demo staff signs in.
- A PIN is a secret: the line lives only in `/opt/pos/.env` on the hub, never in the app or the repository.
- Before this version the hub did not read `POS_STAFF` from that file at all (the line was never handed to
  the hub's program), so a staff of your own starts with this update.

### Sending one out

On the list of checks, a delivery that is **Ready** has the button **Out**. Tap it and the screen asks
**Who takes it?**, with a button for each person who delivers and what they have out right now ("2 out",
"nothing out"), so the next bag goes to whoever is free. Tap a name. The order is out with that driver,
from that minute.

- The customer is texted once that the order is **on its way**. The text says nothing of the address or of
  who brings it. (Like every text, it goes to the hub's log until a texting service is connected.) An
  order with no phone number gets none, and one that came back and leaves again gets no second text.
- The order leaves the **kitchen screens**: it is no longer the kitchen's.
- A text about a delay is no longer sent once it is out.
- The order itself says "out with Tom since 18:40" on the line under its bar.

### The Deliveries screen

The three dots of the list of checks › **Deliveries** (on a wide screen it is in the bar). It has two lists,
one under the other on a phone and side by side on a tablet:

- **Waiting**: the deliveries that have not left, the packed ones first and then by the time promised.
  Each says its number and name, **READY** or "cooking", where it goes, the note for the driver, when it
  was promised and whether it is paid. Tap the bags that are leaving together (they light up), then
  **Out with…** at the foot and the driver's name. Bags sent in one go are **one run** (see
  [Runs](#runs)). One the kitchen does not have yet ("not sent yet", or one for a later
  time) cannot be tapped. A bag can leave while it still says "cooking": nobody has to tap Ready first.
- **Out**: under each driver's name, what they have out and since when, the bag that left first at the
  top, the driver who has been out the longest first. Each card says where it goes, the customer's phone
  number, when it left and what is still to pay, and has two buttons:
  - **Delivered** closes the check, and asks for money still due first, exactly as on the list of checks.
  - **Came back** puts it under Waiting again, packed and nobody's: the customer was not home, or the bag
    went to the wrong driver. Send it out again when it leaves.

A driver who is signed in finds their own bags first, under **You**. The arrow on a card opens the order.

The screen follows the hub: what another screen does shows here within a moment. With no hub answering it
keeps its last picture and says it may be behind; what is tapped is kept and sent when the hub is back,
like any change to a check.

### Runs

**Runs**, in the bar of the Deliveries screen, says what each driver took out over the day.

- At the top, the day and what it came to: "6 runs · 5 delivered · 1 came back · 2 out".
- Under each driver's name, their runs in the order they left: "Run 1 · left 17:35 · 2 bags · 30 min".
  Under each run, every bag with its number, the customer's name, where it went and what became of it:
  - **delivered 17:52 · 17 min**: when it was marked delivered, and how long after it left.
  - **came back 19:02**: it was brought back. If it left again, it is a bag of that later run as well,
    with whoever took it then.
  - **handed to Mike 19:14**: another driver took it over on the way. From then on it is in a run of
    theirs.
  - **voided 19:12**: the order was voided while it was out.
  - **still out**. A run with a bag still out says "out now" and has a coloured edge.
- Whoever left first is first. A driver who is signed in finds their own runs first, under **You**.
- The arrows beside the day step to the days before and back. A day is a day of service, four in the
  morning to four the next: a bag that left at half past midnight belongs to the evening before.

**What a run is.** The bags a driver left with in one go: the ones sent together on the Deliveries
screen, and the ones tapped **Out** one after the other on the list of checks, each within five minutes
of the one before. Once one of them has been delivered, the next bag that leaves with that driver starts
a new run, however soon it leaves.

**What the times are.** They are when somebody tapped. "Delivered" is the moment the bag was marked
delivered: at the door, on the driver's phone, or back at the counter. A run's time is from its first bag
leaving to its last one being marked. To read how long the drives take, have Delivered tapped at the door.

**What is in no run.** A delivery marked delivered with nobody named as its driver (straight from Ready to
Delivered, or its check closed at the counter) is counted in a line under the totals: "2 deliveries were
marked delivered with no driver named." A check closed while its bag was out counts as delivered at the
moment it was closed.

**No money.** No amount is on this screen: not what the bags came to and not what was collected. Anyone
signed in can open it, as anyone can open the list of checks, which says the same names and addresses.

Nothing is stored for the runs. The hub reads them off each order's own history every time, so they cannot
disagree with the history of a check.

### The history

The check's history (`check-history.md`) says "Left with Tom", "Handed from Tom to Wei" when an order that
is out is given to somebody else, "Came back from the driver" and "Marked delivered", each with who tapped
it and when.

## What it does not do

- **No fee and no tip.** Nothing is added to the check for the trip. (The pricing rules have had an
  automatic delivery fee since discounts were built, `discounts.md`, but it is for orders of the type
  `delivery`, which no screen makes. An order taken here stays a to-go order, so no fee goes on by itself.
  A delivery fee by distance or by the time of the drive is the next step.)
- **The runs are on the screen only.** They are not printed, and there is no file of them.
- **No money with the driver.** Nothing counts what a driver collected at doors or owes the drawer, and
  there is no driver's fee or tip. Taking the money for a delivery is recorded as on any to-go order, by
  whoever marks it delivered.
- **No map, no distance, no delivery area.** The address is the words that were typed. It is never sent
  to a service outside the restaurant.
- **The sale is the same.** A delivery is counted in the sales, the day's report and the accountant's
  table exactly as a to-go order is, and every payment on it is recorded on the day it is taken.

## An app on an older hub

Delivery is offered only when the hub says it marks deliveries on its papers. An app rebuilt before the
hub was updated shows the to-go form as it was, with no Pickup or Delivery. Update the hub first.

Drivers likewise: an app on a hub from before drivers has no **Out** step and no **Deliveries** in the
menu (that hub's staff list names nobody who delivers), a delivery goes from Ready to Delivered as it did,
and Who may do what shows no Drivers button and no "Take deliveries out", so nothing is saved that the hub
would refuse.

Runs likewise: on a hub from before the runs, the Runs screen says "This hub does not list runs yet.
Update the hub."

## For developers

- A delivery is a to-go order (`order_type` takeout) whose `handover` is `delivery`. `address` is where it
  goes and `event_note` the note for the driver: the fields a catering order already had
  (`pos.sync.oplog.is_delivery`; a table's check never is one).
- `GET /settings/quotes` answers `delivers: true`. The app offers Delivery on a hand-taken order only then
  (`Quotes.delivers`), and quotes it `minutes.delivery` (`Quotes.baseFor(channel, delivery: true)`).
- `GET /customers/lookup` answers `address` and `address_note`: read off the customer's latest order that
  was delivered and has an address (voided orders are not read). The note of a catering order is about
  its event and is not handed back.
- Tickets: `Ticket.order_type` is `delivery` (`pos.printing.service.ticket_for`), and the channel line
  says `DELIVERY` (`pos.printing.ticket`). The bill: `Bill.deliver` (`pos.printing.bill`).
- Texts (`pos.messaging.Notifier`): no `ready` text for a delivery; the `delayed` text of a delivery uses
  the words of `delayed_delivery`; a promised time that moves in the batch that makes the order a delivery
  is no delay.
- History (`pos.orders.history`): a `stage` step of a delivery says `delivery: true`; an `event_note` step
  says `catering` (false: the note is the driver's).
- App: `Order.isDelivery`, `moneyWords` (`lib/to_go_stages.dart`), `PayDialog.delivery`, `EventFields`
  without a guests box (`lib/screens/event_fields.dart`),
  `WhenDialog` without a time for an order for now, `_LeavingChip` and `_changeWhen` in
  `lib/screens/order_screen.dart`, the form in `lib/screens/orders_screen.dart`.
- Tests: `backend/tests/orders/test_delivery.py`, `apps/pos_app/test/delivery_test.dart`.

Drivers:

- A to-go order's `stage` is `new | ready | out | picked_up`; `out` means something only on a delivery.
  Handing one over is one `set_field`: `stage: out`, `driver` (the name), `driver_id` (the staff id) and
  `out_at` (wall-clock ms; bags handed over in one go carry the same one, which is what a run is). Coming
  back is `stage: ready` with `driver` and `driver_id` null; `out_at` stays as the last time it left.
- Who delivers: the power `deliver` (`pos.identity.powers`), standard roles `("driver",)`, and `driver` is
  one of the roles a power can be handed to. `GET /staff` says `delivers` per person. Nothing checks the
  power when an order is handed over: it says who is offered, not who may tap.
- The staff: `POS_STAFF` reaches the API's container through `infra/hub/docker-compose.yml` (it did not
  before), and `pos.identity.staff.demo_directory` leaves out what does not read instead of failing at
  start (`backend/tests/identity/test_identity.py`).
- Texts: `out` ("on its way"), once per order (`out_at` already there means it left before). No `delayed`
  text once the stage is `out`.
- Kitchen screens (`pos.printing.screen`): a to-go order that is `ready`, `out` or `picked_up` is off them.
- History: a delivery's `stage` step to `out` carries `driver`; a `driver` step (`was`, `now`) when the
  driver changes while it stays out.
- App: `lib/deliveries.dart` (`deliveriesOf`, `Waiting`, `outFields`, `backFields`),
  `lib/screens/deliveries_screen.dart`, `lib/screens/driver_picker.dart`, `lib/screens/hand_over.dart`
  (`setToGoStage`, the step shared by the list of checks and the Deliveries screen), `Roster.drivers`,
  `Order.isOut`, and `Powers.handed`, `knows` and `offered` for a hub older than drivers. The Deliveries
  screen is worked out from `GET /orders?status=open`; there is no endpoint of its own.
- Tests: `backend/tests/orders/test_drivers.py`, `apps/pos_app/test/drivers_test.dart`.

Runs:

- `GET /deliveries/runs?day=YYYY-MM-DD` (`pos.api.runs`; the running day of service without `day`), with
  no token, like `GET /orders`, which says the same names and addresses. It answers `drivers` (each with
  `runs`, `delivered`, `back`, `out` and the `list` of runs), the same counts over everybody, and
  `no_driver`. A run has `left_ms`, `ended_ms` (null while a bag is out), `minutes` and `bags`; a bag has
  the order's id, number, name and address, `left_ms`, `outcome` (`delivered`, `back`, `out`, `handed`
  with `to`, `void`), `at_ms` and `minutes`. No amount of money is in it.
- Nothing is stored: `pos.orders.runs.runs_report` replays the log of every order of the day that is or
  was a delivery (`legs_of`). A **leg** is each time an order became `stage: out` with a driver, until it
  was delivered, came back, changed driver or was voided; it left at the `out_at` the screen said (at the
  operation's own time for one handed on) and counts on the day of service it left in. A **run** is one
  driver's legs that each left within `RUN_GAP_MS` (five minutes) of the one before, with none of them
  delivered yet. Drivers are told apart by `driver_id`, by name only for one named without an id.
- The answer does not say when it was read, so an answer that has not changed keeps its `ETag` and a
  screen that asks again is sent nothing.
- App: `lib/runs.dart` (the answer and its words), `lib/screens/runs_screen.dart`, `PosApi.runs` (null
  from a hub older than the runs), opened by `deliveries-runs` on the Deliveries screen.
- Tests: `backend/tests/orders/test_runs.py`, `apps/pos_app/test/runs_test.dart`.
