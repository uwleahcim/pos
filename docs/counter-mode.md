# Counter mode and takeout

What a to-go order does differently from a table (architecture page, section 12), as built for phase 1:
it is named and numbered, paid before the kitchen sees it, timed by a quote per channel, printed ahead of
its time when it is for later, and the customer is texted when it is ready.

## Taking one

Tap **To go** on the orders screen.

1. **Name and phone.** The name goes on the ticket and in the texts; the phone is where the ready text
   goes (leave it empty for a walk-up who waits). The language chips (English, 中文) pick the language
   of the texts.
2. **Channel.** Counter or phone; online and delivery orders arrive on their own in phase 2. The hub's
   quote for the channel says when it will be ready ("Ready in about 15 min").
3. **For later.** Today or tomorrow, and a time. The kitchen ticket prints ahead of that time by the
   channel's quote, so the kitchen sees the order when it is time to cook it, not when it was taken.

The check opens with no seats or courses. Add the dishes as on a table. The app bar shows the number the
hub gave the order and the time it is for (`#42 Linda · 18:05`).

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

## The list

To-go orders sit in the list of checks with their number, name, channel, time and whether they are paid.
Once the kitchen has the order, **Ready** marks it ready (the hub texts the customer, once) and
**Picked up** closes the check. The kitchen ticket prints `#42  LINDA` large, `READY BY 18:05`, and the
channel where a table order shows its table.

## Order numbers

The hub numbers each takeout, phone, online or delivery order when its `create` arrives (`order_no`,
from 1 each day), never the terminal, so two counters cannot pick the same number. A table order is
known by its table. Offline (ADR 6) the check shows `#…` until the create reaches a hub or the cloud.

## Quote times

A manager sets the minutes per channel, and which channels may pay at pickup, under **Location** ›
**Quote times** (manager PIN; see `location-settings.md`). The hub keeps them for every terminal:
`GET /settings/quotes`, `PUT` with a manager
session token. Defaults: counter 15, phone 20, online 25, delivery 45 minutes; phone orders may pay at
pickup. Kitchen pacing will quote the times itself in phase 2.

## Texts to the customer

The hub sends two texts, in the order's language (English or Chinese), to the phone number on the order:

- **Ready**, when the stage becomes `ready`: "Hi Linda, order #42 is ready for pickup at Golden Wok.
  Please pay at pickup." (the last sentence only while something is still due).
- **Delayed**, when a future order's promised time is moved later before it is ready (a `set_field` on
  `promised_at`; the app has no button for it yet).

Phase 1 ships the adapter and a messenger that only logs. `POS_MESSAGING=log` writes each text to the API
log, and `GET /messages` lists the last ones, newest first, so the bench can see what would have gone
out. `POS_LOCATION` names the restaurant in the texts. A provider (Twilio) plugs in behind the same call
in phase 2.

## On the wire

- `create` with an `order_type` other than `dine_in` carries `channel`, `customer_name`, `phone`,
  `locale`, `quoted_minutes`, `promised_at` (ms) and `stage`; the hub adds `order_no`.
- `pay` carries `payment_id`, `method` (`cash`, `elsewhere` or `card`), `amount`, for cash `tendered`
  (at least the amount), and `note` and `by`. A bad one is refused as `invalid_payment` with its
  problems. The first `pay` with a given id wins, so a retry cannot pay twice.
- `set_field` moves `stage`: `new`, `ready`, `picked_up`.
- The check carries `payments`, `paid` and `due`.
- A future order's print job carries `due_in`, the seconds until its ticket prints (`GET /print/jobs`); a
  void prints at once.
