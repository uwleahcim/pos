# Shipday

The restaurant dispatches its deliveries in **Shipday**: GloriaFood hands an accepted delivery order to
Shipday, somebody gives it to a driver there, and the driver says in Shipday's app how far along it is. The
same order also arrives on the POS by GloriaFood's own road (`online-orders.md`), and until now the two knew
nothing of each other.

Mike asked for this on 2026-11-27: "I currently use shipday to handle delivery orders for gloriafood. I would
like to sync and potentially use shipday for delivery orders with this POS. Basically I want to be able to
perform both read and write with shipday API to perform tasks that is normally handled by the shipday app
(things like assign drivers, get delivery travel times, update order status, etc). This way I can do do
everything from the pos-app without using the shipday apps."

It is built in pieces. **The first piece reads.** The hub asks Shipday, with the restaurant's own key, for
its deliveries and its drivers, and the app shows them on a screen of their own, each delivery beside the
check it is on the POS. **The second gives a delivery to a driver, and takes it back**
("Giving a delivery to a driver"): the only two things the POS ever changes in Shipday, each by a tap that
says so and never by itself. Nothing Shipday says changes a check. Marking a delivery as it goes comes next
("What comes next").

Nothing here was ever tried against Shipday itself: see "Never tried for real" before relying on it.

## What you see

**More › Shipday** on the Orders screen, once the hub has a key for Shipday. The button says how things
stand without opening it: "2 need a driver", or "3 out". Anyone signed in sees it, as with Deliveries.

The screen, from the top:

- **Drivers on shift**: each driver who said in Shipday's app that they are working, with how many
  deliveries they have that are not finished, or "free". The one with the least comes first: that is who
  can take the next one. Under them, in small type, who is off shift.
- **Need a driver**: the deliveries nobody has been given yet.
- **With a driver**: given to a driver who has not picked it up. Shipday's own three steps show on each:
  *Not accepted yet* (offered, and the driver has not said yes), *Accepted*, *Started*.
- **On the way**: *Picked up*, and *Ready to deliver*.
- **Finished today**, folded shut until tapped: what left Shipday's list during this day of service, the
  last first, each with what became of it: *Delivered*, *Failed*, *Incomplete*, or *No longer listed* when
  Shipday did not say (a delivery that was deleted there, say).

Each delivery is a card:

- The customer's name, and where it stands, in Shipday's own words.
- The address.
- Who has it and the last thing that happened ("Tom Reyes · picked up 18:20"), and, where Shipday says,
  **when it is expected at the customer's** ("there about 18:38").
- The customer's number, what they pay and whether in cash or by card, and the time they wanted it for.
- The note for the driver.
- **Give to a driver** on one nobody has, and **Take it back** on one a driver has and has not picked up
  ("Giving a delivery to a driver").
- **The check it is on the POS** ("Check #12"): a tap opens it, and Back returns here. A check that was
  closed or voided says so. A delivery the hub finds no check for says **Not on the POS**.
- The number Shipday's own apps show it by, to find it there.

The circle arrow at the top asks Shipday now instead of waiting for the hub's next turn.

On a tablet or a Mac the lists stand side by side; on a phone one under the other.

When Shipday does not answer, a red line across the top says why (it refused the key, it cannot be reached,
it is asked too often), and the lists keep what Shipday last said.

## Giving a delivery to a driver

**Give to a driver**, on a delivery under Need a driver, opens **Who takes it?**: the drivers who are on
shift in Shipday, as buttons, each with how many deliveries they have that are not finished ("free",
"2 out"), the one with the least first. It is the picker the POS's own Deliveries screen has, with Shipday's
drivers. **A tap on a name gives the delivery to that driver**, and Shipday tells the driver as it does when
it is done in Shipday's own app. Cancel, or a tap beside the list, gives it to nobody. Who is off shift is
named under the buttons and cannot be picked: a driver goes on shift in Shipday's own app.

**Take it back**, on a delivery under With a driver, asks first ("Take it back from Tom Reyes?"). Then
nobody has it, it is under Need a driver again, and it can be given to somebody else. That is also how a
delivery goes from one driver to another: taken back, then given. One that was picked up has no such
button: what is on its way is not taken from the driver who carries it.

Anybody who is signed in can do both, as anybody hands a bag to a driver on the POS's own Deliveries screen.
The hub writes into its log who asked, with Shipday's own numbers for the delivery and the driver and
nothing of the customer.

What the hub does with a tap:

1. **It asks Shipday for its list first**, and sends nothing if the delivery no longer stands as the screen
   showed it: it left the list, somebody gave it to a driver in Shipday's own app a moment ago, another
   driver has it, it was picked up. The screen then says which ("Wei Zhang has it already. Nothing was
   changed.") and shows the list as it now is.
2. **It asks Shipday for the one change.** Only Shipday's own numbers for the delivery and the driver go
   with it. Nothing of the POS does.
3. **It asks for the list again**, so every screen shows what Shipday now says. The screen that asked says
   "Given to Tom Reyes."

When Shipday will not do it, the screen says so, with Shipday's own words where it gave any ("Shipday would
not do it: ..."). When Shipday's answer never comes, the list read after it settles whether it was done.
When the hub itself does not answer, the screen says that it may have been done and to look at the list.
While the hub is asking, the card says "Asking Shipday…" and takes no second tap.

Nothing here is ever done by the hub on its own: not on a timer, not when a check changes, not when a
driver signs in on the POS.

## Setting it up

1. In Shipday's Dispatch Dashboard (dispatch.shipday.com), under **My Account**, copy the **API key**.
2. On a terminal: the Orders screen, **More**, **Location**, a manager's PIN, **Keys and connections**, and
   the card **Shipday (deliveries)**. **Type the key**, paste it, Save.
3. **Try it**. The hub asks Shipday once and says what it listed: "Shipday answered: the key works. It lists
   2 deliveries out, 4 drivers, 1 on shift." Or why not.

The key is sealed on the hub like every other (`hub-keys.md`) and never shown again. **Remove** on the same
card stops the asking, and the Shipday button goes away. Never send the key to anybody in a message: it lets
its holder change the restaurant's deliveries.

With the key on the hub, whoever is signed in at a terminal can give a delivery to a driver and take it
back. There is no switch that leaves the reading on and turns that off.

## Which check a delivery is

GloriaFood gives the same order to the POS and to Shipday, and neither tells the other. The hub puts the two
together by what both carry, each time a screen asks:

1. **GloriaFood's number for the order.** The POS keeps it with an online order. Where the number Shipday
   shows the delivery by is that number, or has it in it ("#1270166229"), it is the same order.
2. **The customer's phone number**, among today's deliveries on the POS the first rule left over. The card
   then says "matched by phone number". A customer with two deliveries today is told apart by the house
   number of the address; where that does not settle it, **nothing is matched**. A wrong check beside a
   delivery is worse than none.

Whether Shipday's GloriaFood link numbers its deliveries with GloriaFood's own number could not be read
anywhere. If it does not, the phone number carries the matching. Either way a check is on one delivery at
most.

Only today's deliveries on the POS are looked at (the day of service that is running), voided ones too: a
delivery still out in Shipday whose check was voided is worth seeing.

## How often Shipday is asked

The hub sits behind the restaurant's router, where Shipday cannot reach it, so the hub asks:

| When | How often |
| --- | --- |
| The Shipday screen is open somewhere | every 20 seconds |
| A terminal is on, the screen is not open | once a minute, for the words on the button |
| No terminal has asked the hub for ten minutes (the restaurant is shut) | every 5 minutes |

A screen that opens after a quiet spell has Shipday asked at once. The drivers are asked for once a minute.
A delivery that leaves the list is asked after by its number, so the screen can say what became of it.

**When it is there** comes from a call Shipday's pages say is "only available for customer having premium
plans". The hub tries it for the deliveries a driver has started, each once a minute. If Shipday refuses,
the hub stops trying for an hour, the card under Keys and connections says the plan leaves it out, and the
screen shows whatever arrival time Shipday put on the order itself, which may be none.

Shipday is never hurried: told that it is asked too often, the hub waits a minute, then two, up to ten.

All of it is kept in the hub's memory only. A hub that restarts asks again and knows nothing of what finished
before the restart. Nothing of a customer is written to the hub's log.

## What Shipday's API cannot do

Read from Shipday's reference (docs.shipday.com/reference) on 2026-11-28. These stay in Shipday's own apps,
whatever is built here, because the API has no call for them:

- the **live map** of the drivers (there is a driver's last place, and a webhook Shipday sets up by hand
  for "priority customers");
- **chat** with a driver;
- putting a driver **on or off shift**, and changing a driver's details;
- **routes and automatic dispatch** and their settings;
- the **texts and the tracking page** Shipday sends the customer;
- **driver pay** and Shipday's reports;
- adding a **proof of delivery** (a photo, a signature).

And one thing the hub cannot use: Shipday can **push** every change of a delivery to an address on the
internet (webhooks). The hub has none without a tunnel, so it asks instead; a change shows within twenty
seconds while the screen is open.

## What comes next

What the API does have, and the next pieces will put on this screen, each behind a tap that says what it
does:

- **Say how far along it is**: started, picked up, delivered, failed.
- **Say that it is ready** for its driver to pick up.
- **Send the POS's own deliveries to Shipday** (the phone and counter ones, which Shipday does not know).

Still to be decided with the owner, not built: whether what a driver marks in Shipday should also move the
check on the POS (Out, Delivered). That would send the POS's own "on its way" text and close checks by
itself, so it is not done on a guess.

## Never tried for real

This was written from Shipday's reference pages and tested against answers built from the examples on them.
No request has ever been sent to Shipday, and the first press of **Try it** on the real key is the first
real one. What may turn out otherwise:

- **The key's header.** The pages send it as `Authorization: Basic <key>`; their machine-readable part
  names `x-api-key`. The hub sends both.
- **Times.** The pages say the times are UTC and show them without a zone. If the clock times on the
  screen are off by a few hours, this is why.
- **The number matching** (above).
- **When it is there**: where the id for that call comes from is not written. The hub takes it from the end
  of the delivery's tracking link.
- **What Shipday says of a finished delivery** when asked for it by its number.
- **Giving a delivery to a driver and taking it back.** The pages give the two calls and one example answer
  each. They do not say when Shipday refuses (a driver who is off shift, a delivery a driver has accepted
  or started), what it answers then, or where a delivery stands right after it was given: the screen shows
  whatever Shipday's list says. The first time, do it with one delivery and look at it in Shipday's own app
  too.
- **The form of the arrival time on the order itself.** One that is not a time is shown as Shipday wrote it
  ("Shipday says 12 min").

## An older hub, an older app

A hub from before this lists no Shipday key and has no Shipday button: nothing changes. An app from before
this on a new hub has no card and no button, and the hub asks Shipday all the same once it has a key.

A hub that reads Shipday and does not yet give deliveries to drivers says so to the app, which then shows
neither button and says under the lists that it is done in Shipday's own app. An app from before the
buttons on a newer hub reads as it did.

## The calls

| Call | What it does |
| --- | --- |
| `GET /shipday` | The picture: `on`, `read`, `trouble` (null, or `since_ms`, `reason`, `said`), `eta` (`off`, `on`, `plan`), `can` (what this hub changes in Shipday when asked: `driver`), `orders`, `done`, `drivers`. Every delivery has Shipday's `id`, `number` and `state`, the customer's `name`, `address` and `phone`, its `driver` or null, its times in ms, `eta_ms` or `eta_said`, `total`, `fee`, `tip`, `payment`, `items`, `note`, `tracking`, `scheduled`, and `pos`: the check (`order_id`, `order_no`, `status`, `stage`, `by`) or null. `?looking=true` says a screen shows it. Anyone at a terminal reads it, like the list of orders |
| `POST /shipday/ask` | Asks Shipday now. Not passed on within ten seconds of the last asking (`soon`). 409 `no_key` |
| `POST /shipday/orders/{id}/driver` | `{staff_id, driver_id}`: gives the delivery with Shipday's id `{id}` to that driver. Answers `done`, `sent` (Shipday was asked to), `shown` (its list shows it), why not (`reason`, `said`, and `told`: Shipday's own words) and the picture after it (`shipday`). `reason` when nothing was sent: `not_listed`, `has_driver`, `unsure`, `unknown_driver`, or why Shipday could not be asked first; when it was: `rejected`, `not_found`, or why no answer came. 409 `no_key`, 404 `unknown_staff` |
| `POST /shipday/orders/{id}/driver/back` | `{staff_id, driver_id}`: takes it back from the driver the screen showed it with. The same answer; `reason` when nothing was sent: `not_listed`, `no_driver`, `other_driver`, `on_its_way`, `unsure` |
| `PUT` / `DELETE /hub/keys/shipday` | The key, a manager's (`hub-keys.md`) |
| `POST /hub/shipday/try` | A manager's try: asks once, answers like `GET /hub/keys` with `shipday_tried` (`ok`, `reason`, `said`, `orders`, `drivers`, `on_shift`). 409 `no_key` |

`GET /hub/keys` also carries `shipday`: how the asking goes (`on`, `running`, `asked_ms`, `answered_ms`,
`trouble`, `eta`, and how many `orders`, `drivers` and drivers `on_shift` were last listed). No order and no
customer is in it.

The change feed (`GET /live`) says `shipday` when the picture reads differently or the key changed, which
it does after a delivery was given to a driver or taken back.

What the hub asks of Shipday for the two changes: `PUT /orders/assign/{orderId}/{carrierId}` and
`PUT /orders/unassign/{orderId}`, with nothing in them.

The code: `backend/src/pos/shipday/` (`client.py` asks, `read.py` reads what comes back, `match.py` finds the
check, `board.py` keeps the picture and paces the asking) and `backend/src/pos/api/shipday.py` (the calls);
in the app `lib/shipday.dart`, `lib/screens/shipday_screen.dart`, and the card in
`lib/screens/hub_keys_screen.dart`. The tests ask a pretend Shipday (`backend/tests/shipday/fake.py`).
