# Customers remembered by their phone number

Linda calls. Since 2026-11-15 the to-go form that opens for her call already says who she is: her name,
how often she has ordered, the line the restaurant keeps about her ("no MSG, side door"), and her latest
orders, each with a **Same again** button. It is the first slice of the customer records the architecture
plans for later, pulled forward because the phones are built in.

**What it is not.** Nothing about a customer is typed in for its own sake: no customer list to keep up, no
form to fill. There are no saved addresses (nothing delivers yet), no points, no messages to customers, and
the phone system is untouched: the caller's name on the ringing strip is still the phone company's. A
customer is a phone number that has ordered; a walk-in who gives no number is nobody to remember.

## On the to-go form

The form looks the number up when it opens for a caller, and whenever a number of seven digits or more is
typed into it (it waits for the typing to pause). Numbers match by their digits: `+1 (781) 555-1234` and
`781 555 1234` are the same customer. Under the phone box:

- **The name** from their latest order that has one fills the name box, unless a name was typed there.
  It replaces the phone company's caller-ID name ("WIRELESS CALLER"), which is rarely the person.
- **One line on how well the restaurant knows them**: `12 orders since Mar 2025, the last on 3 Nov`, or
  `No orders from this number yet`. A voided order does not count; one opened and left empty does.
- **Note about this customer**: one line, 120 characters. It is saved when the order starts, and the tick
  in the box saves it at once, so a note can be written or corrected without starting an order (type the
  number, write the note, tick, Cancel). An empty note takes it off. The hub keeps who wrote it and when.
- **Their latest five orders that had dishes on them**, newest first: the day, what it came to, the dishes,
  and **Same again**.

Picking up a call still opens the order the number placed earlier **today** when there is one (a customer
calling back about their order lands on it); the form with the customer on it opens when there is none.

When the call is about a table, the form has **Book a table** at its top right, and lists the tables the
number has booked already (docs/reservations.md, "When somebody calls").

## Same again

A tap starts the new order as **Start** would (the name, the channel, the language and the time as the form
has them) and puts the past order's dishes on it: each with the choices it had (brown rice, extra spicy),
its quantity and its note ("extra crispy"), on the course a dish rung in by hand would go to. Then the
screen says, while the customer is still on the call:

- `Same again: 3 dishes added.`
- **A price that is not what it was**: `General Tso's Chicken (Qt) is $13.95 now, was $12.95.` Dishes are
  always sold at today's menu, never at the old price.
- **A dish that was left off, and why**: `NOT added: California roll. It is sold out today.` The reasons:
  it is sold out or off the menu today, it is no longer on the menu, one of its choices is sold out or no
  longer offered, its choices have changed since, or it was typed in by hand and never came from the menu.
  Ring it in by hand or tell the customer.

Nothing is sent to the kitchen by Same again: the dishes are on the check like any others, to change, take
off, pay and send. A dish that was voided on the past order is not had again.

## On the order

A to-go order whose number has a note shows it in a slim strip under the app bar, `Customer note: no MSG,
side door`, for whoever rings the dishes in, on a new order and on one a caller comes back to. The note is
for the person taking the order. **It does not print in the kitchen**: what the kitchen must know goes on
the dish, as always.

## Who sees it

Anyone signed in at a terminal sees the customer and may write the note, as anyone may take the order. A
customer's name and number were already on every order they placed; the note is the one new thing kept
about them, so keep it to what serves the order.

All the customers on one screen, with their visits, what they spent and their favourite dishes, are for a
manager: Location › **Guests** (`guest-list.md`).

## When a hub is not answering

With no hub answering, or on a hub older than this, the form is what it was before: name, phone, channel,
time. The customer, the note and Same again need a hub, since the past orders are there.

## How it is kept

- **Nothing is copied.** The name, the count, the dates and the past orders are read from the order log
  each time. The orders index (`orders` in PostgreSQL, kept in step with the log in the same transaction)
  now keeps each order's phone number as digits, so a number's orders are found however old they are
  without replaying the log. A hub updated from before this works the column out for every order once, at
  start.
- **The note** is the one thing stored: `customer_note` (the number's digits, the note, who wrote it and
  when), in the hub's database like location settings, so the second hub has it too. A standby hub answers
  503 `read_only` to a save and the terminal moves on to the hub in charge.
- `GET /customers/lookup?phone=` answers `known`, `name`, `note`, `orders`, `first_ms`, `last_ms` and
  `recent` (each with `order_id`, `opened_ms`, `order_no`, `status`, `channel`, `total`, `items`). `known`
  is false for a number with no order and no note, and for one of fewer than seven digits.
- `PUT /customers/{phone}` with `note` and `by` keeps the note (on one line, cut to 120 characters).
- `GET /orders/{id}/again` answers `lines` (each with `item`, `qty`, `note`, `request`, `unit_price`, `was`)
  and `missing` (each with `item`, `qty`, `why`). It adds nothing: the terminal appends an `add_line` for
  each line, and the hub prices each one again as it does every dish.

Code: `backend/src/pos/customers.py`, the phone column in `pos/sync/oplog.py` and `pos/sync/pgstore.py`, the
three endpoints in `pos/api/app.py`; `apps/pos_app/lib/customers.dart`, the form in
`screens/orders_screen.dart`, the strip in `screens/order_screen.dart`. Tests:
`backend/tests/orders/test_customers.py`, `backend/tests/test_orders_index.py`,
`apps/pos_app/test/customers_test.dart`.
