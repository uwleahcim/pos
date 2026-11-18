# Delivery orders

An order that is brought to the customer by the restaurant's own driver. It is a to-go order like any
other (`counter-mode.md`): named, numbered, rung in from the menu, paid the same ways. What it adds is
**where it goes**, a **note for the driver**, a quote that allows for the drive, and the word DELIVERY on
every paper, so nobody packs it for the shelf.

This is the first step of delivery. Handing an order to a driver, seeing what each driver has out, and a
driver's runs for a shift come next. Nothing here is about money: there is no delivery fee and no tip
(payments are parked), and a delivery is a sale like any other, counted in every report as a to-go order
is.

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
address at the end. Its steps are **Ready** and then **Delivered** in place of "Picked up". While nothing
was taken for it the row says **pay at the door** in place of "pay at pickup", and where an order may be
sent to the kitchen unpaid (a phone order), that choice is called **At the door**.

- **Ready** texts nobody. The ready text says "ready for pickup", and nobody is coming. (A pickup order
  still gets its text.)
- **Delivered** closes the check. If money is still due it asks for it first, as "Picked up" does: Cash,
  Paid elsewhere, or Not now.
- A delivery whose time is pushed back gets a text that says when it will be there, not when to come for
  it. An order that was just changed from pickup to delivery gets none: the customer asked for that.

(Texts go to the hub's log until a texting service is set up; none is connected yet.)

A delivery is **not on the pickup board** (`pickup-board.md`): nobody stands at the shelf waiting for it.

## What it does not do

- **No fee and no tip.** Nothing is added to the check for the trip. (The pricing rules have had an
  automatic delivery fee since discounts were built, `discounts.md`, but it is for orders of the type
  `delivery`, which no screen makes. An order taken here stays a to-go order, so no fee goes on by itself.
  Whether the restaurant charges for delivery, and how much, is the owner's to say.)
- **No drivers yet.** Nobody is assigned, nothing says an order is out. That is the next step.
- **No map, no distance, no delivery area.** The address is the words that were typed. It is never sent
  to a service outside the restaurant.
- **The sale is the same.** A delivery is counted in the sales, the day's report and the accountant's
  table exactly as a to-go order is, and every payment on it is recorded on the day it is taken.

## An app on an older hub

Delivery is offered only when the hub says it marks deliveries on its papers. An app rebuilt before the
hub was updated shows the to-go form as it was, with no Pickup or Delivery. Update the hub first.

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
