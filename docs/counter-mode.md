# Counter mode and takeout

What a to-go order does differently from a table (architecture page, section 12), as built for phase 1:
it is named and numbered, paid before the kitchen sees it, timed by a quote per channel, printed ahead of
its time when it is for later, and the customer is texted when it is ready.

## Taking one

Tap **To go** on the orders screen.

1. **Name and phone.** The name goes on the ticket and in the texts; the phone is where the ready text
   goes (leave it empty for a walk-up who waits). The language chips (English, 中文) pick the language
   of the texts.
2. **Channel.** Counter, phone or catering; online and delivery orders arrive on their own in phase 2.
   The hub's quote for the channel says when it will be ready ("Ready in about 15 min"). While a manager's
   rush is on, the quote is longer and the form says by how much ("Ready in about 35 min (busy kitchen:
   +20)"). A catering order asks for its day and time and what its event needs (`catering.md`).
3. **Pickup or Delivery.** Pickup unless you say otherwise. A delivery asks where to and has a note for
   the driver, and is quoted Delivery's minutes ("There in about 45 min"): see `delivery.md`.
4. **For later.** Today, tomorrow or another day off a calendar, and a time. The kitchen ticket prints
   ahead of that time by the channel's quote, so the kitchen sees the order when it is time to cook it,
   not when it was taken.

The check opens with no seats or courses. Add the dishes as on a table. The app bar shows the number the
hub gave the order and the time it is for (`#42 Linda · 18:05`). When the dishes make it a big order (see
"Quote times" below), the screen says so once ("Big order: ready at 18:15, 10 minutes later.") and the app
bar shows the later time, so the customer hears the right one before the order is sent.

### Phone orders

On a terminal that is a phone (the Phone section of the app README), picking up a call brings up the last
order the caller's number opened today, so a customer calling back about an order lands on it; with none,
the to-go form opens with the number, the phone channel and the caller-ID name filled in. The hub finds the
order (`GET /orders/last?phone=`): numbers match by their digits (`+17815551234` is `781 555 1234`), today is
the restaurant's day (`POS_TIMEZONE`), the last order is the one opened last whatever was done to the
others since, a voided order does not count and a closed one does. Whatever screen was open stays
underneath for afterwards, and **To go** on the call strip still starts a fresh order for the caller.

The form looks the number up as a customer: the name from their orders, how often they ordered, the note
kept about them and their latest orders, each with **Same again** (`docs/customers.md`).

## Paying first

**Pay & send** takes the money and sends everything to the kitchen at once; the screen comes back for the
next customer.

- **Cash**: exact, the next bill up ($15, $20, $50, $100), or a typed amount. The change shows before
  and after the send, so the operator can count it out.
- **Paid elsewhere**: a phone order paid through another system; an optional note says how.
- **At pickup**: offered only on channels the location allows (phone, by default). Nothing is taken; the
  order goes to the kitchen and the ready text asks the customer to pay at pickup.

Cards come with the payments phase. A paid order lists what was taken under the total, and what is still
due. When nothing is due the button is **Send**.

Where the order may go with money still to collect (a phone order, a catering order), a part of it can be
taken instead of the whole: a deposit. And once the kitchen has an order, **Pay** beside what is due takes
the rest, so an order that pays at pickup can be paid at pickup (`catering.md`, "A deposit, and the rest").

Either button first asks, once an order, **what goes in the bag** besides the food (chopsticks, forks,
napkins, or nothing), unless the location turned the question off. The answer stands on the check over the
totals and prints on the takeout counter's ticket (see `to-go-question.md`).

## The list

To-go orders sit in the list of checks with their number, name, channel, time and whether they are paid.
Once the kitchen has the order, **Ready** marks it ready (the hub texts the customer, once) and
**Picked up** closes the check. The kitchen ticket prints `#42  LINDA` large, `READY BY 18:05`, and the
channel where a table order shows its table. The takeout counter's copy, the one for the bag, also says
`PAID` or `NOT PAID  $45.20` under the name (see `printing.md`). An order that leaves in several bags gets
a slip for each from **Labels**, beside its total: `#42  LINDA`, `BAG 2 OF 3` (see `bag-labels.md`).

One row of chips above the list sorts the to-go orders by stage, each chip with its count:

- **Later**: orders waiting for a time the customer named, sent ahead or not. The kitchen has seen
  nothing of them yet.
- **Cooking**: orders the kitchen has, from the moment their ticket prints.
- **Ready**: orders on the shelf, waiting to be picked up.
- **Unpaid**: every open to-go order with money still to collect, whatever its stage: nothing paid on
  it, or a deposit and a rest.

Tapping a chip lists only its orders, the one due first at the top; tapping it again brings every check
back. The row shows once there is a to-go order to sort, and only on the list, not on the floor map. An
order still being rung up for now is under no stage yet (it is under Unpaid, and in the whole list). An
order sent ahead for a later time has no **Ready** button until its ticket prints, so a slip of the thumb
cannot text a customer whose food nobody has started.

A screen facing the pickup shelf can show the customers the same two stages, Cooking as "Being made" and
Ready, by number and first name: the pickup board (`pickup-board.md`).

An order the customer named a time for reads "for 18:30" where another reads "ready 18:05", and is marked
as its time to start cooking nears (its time less its quote):

- amber **Send by 18:10**, from a quarter of an hour before it must start, while nobody has sent it;
- amber **Starts 18:10** over the same quarter of an hour once it was sent: its ticket prints by itself;
- red **Not sent, due to start 18:10** when that time has come and it was never sent, so nothing printed.

The colours are the floor map's timer colours. The list redraws at the moment a mark changes, not by the
second. While a rush is on, one line above the checks says so on every screen ("Kitchen is busy: new
quotes +20 min").

## Order numbers

The hub numbers each takeout, phone, online or delivery order when its `create` arrives (`order_no`,
from 1 each day), never the terminal, so two counters cannot pick the same number. A table order is
known by its table. Offline (ADR 6) the check shows `#…` until the create reaches a hub or the cloud.

## Quote times

A manager sets the minutes per channel, and which channels may pay at pickup, under **Location** ›
**Quote times** (manager PIN; see `location-settings.md`). The hub keeps them for every terminal:
`GET /settings/quotes`, `PUT` with a manager
session token. Defaults: counter 15, phone 20, online 25, delivery 45 minutes; phone orders may pay at
pickup. Catering has a row of its own, 60 minutes: how long before its time the kitchen gets a catering
order's ticket. Kitchen pacing will quote the times itself in phase 2; until then two things move a quote with the
kitchen.

### The rush

When the kitchen is behind, a manager taps **More** on the orders screen, then **Kitchen rush** (the
flame), gives the PIN and picks **+10, +15, +20, +30 or +45 min**, or **Off**. From then on every
new to-go quote on every screen is that much longer, and one line above the checks says so. Tapping that
line changes the rush the same way (it asks for a manager's PIN, whoever taps). The Kitchen card on Today
(`today.md`) sets it too, with the PIN that opened Today.

- The rush is set, not added to: +30 after +20 is 30 minutes, not 50.
- Orders already promised keep their time. Nobody is texted.
- It ends by itself at the end of the night (04:00, `POS_TIMEZONE`), like the numbers left on a dish, so a
  rush left on does not make tomorrow's lunch late.
- An order for later takes the rush only when its time falls inside the rush's night; then its ticket
  prints that much sooner, and its time stays the one the customer named.
- With no hub in reach the screens keep the rush they last read.

### Big orders

Under **Location** › **Quote times** › **Big orders** a manager can say that an order of N dishes or more
takes M more minutes (both boxes empty: no such rule, which is how it starts). Dishes are counted with
their quantities: three egg rolls are three dishes.

- The order screen says it when an order becomes big, and when it stops being one, and shows the later
  time in the app bar.
- The time is settled when the order is first sent (**Pay & send** or **Send**): the quote grows by the
  extra minutes and so does the promised time, in the same batch as the send, so the ticket prints
  `READY BY` the later time and the ready text is not a "delayed" one.
- A time the customer named does not move: the kitchen starts sooner instead ("Big order: the kitchen
  starts it 10 minutes sooner. Still for 18:30.").
- Dishes added after the first send do not move the time again.

## Texts to the customer

The hub sends these texts, in the order's language (English or Chinese), to the phone number on the order
(a delivery's own text, "on its way", is in `delivery.md`):

- **Ready**, when the stage becomes `ready`: "Hi Linda, order #42 is ready for pickup at Golden Wok.
  Please pay at pickup." (the last sentence only while something is still due).
- **Delayed**, when a future order's promised time is moved later before it is ready (a `set_field` on
  `promised_at`; the app has no button for it yet). The time a big order is given as it is first sent is
  its quote, not a delay: nothing is texted for it.

The texts really go out once a manager has typed the restaurant's Twilio account in the app (Location › Keys
and connections; `texts.md` says how, what it sends where, and what happens when a text does not go). A hub
without an account only writes each text to its log, and `GET /messages` lists the last ones, newest first,
so the bench can see what would have gone out. `POS_LOCATION` names the restaurant in the texts.

## On the wire

- `create` with an `order_type` other than `dine_in` carries `channel`, `customer_name`, `phone`,
  `locale`, `quoted_minutes`, `promised_at` (ms) and `stage`; the hub adds `order_no`. `for_later: true`
  says the customer named the time (an order made before 2026-11-15 does not say; the app then goes by
  whether its time is further off than its quote).
- `GET /settings/quotes` answers `{"minutes": {...}, "pay_at_pickup": [...], "big_orders": {"dishes": 8,
  "minutes": 10}, "rush": {"minutes": 20, "until": 1800000000000, "by": "Mike"}}`; `rush` is `null` while
  there is none or its night is over. `PUT /settings/quotes` (the manager Bearer token) takes `minutes`,
  `pay_at_pickup` and `big_orders` (left out, the rule stays as it was, so an app from before it does not
  wipe it; 0 for either number takes the rule off) and never touches the rush.
- `PUT /settings/rush` (the manager Bearer token) with `{"minutes": 20}`, 0 to 120, 0 for off: the hub
  stamps when the night ends and who set it, tells every screen on the change feed (`settings`), and
  answers like `GET /settings/quotes`.
- A big order's first send is one batch: `set_field` with `quoted_minutes` and (unless the time was named)
  `promised_at`, then `fire`.
- `pay` carries `payment_id`, `method` (`cash`, `elsewhere` or `card`), `amount`, for cash `tendered`
  (at least the amount), and `note` and `by`. A bad one is refused as `invalid_payment` with its
  problems. The first `pay` with a given id wins, so a retry cannot pay twice.
- `set_field` moves `stage`: `new`, `ready`, `picked_up`.
- The check carries `payments`, `paid` and `due`.
- A future order's tickets are not made until its time (`printing.md`, "Orders sent ahead"). Until then
  `GET /print/jobs` lists it under `held`: `order_id`, `starts_ms` (when its tickets print) and `lines`
  (how many dishes wait). The `fire` that sends it answers with no `print_jobs`.
