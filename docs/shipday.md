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
("Giving a delivery to a driver"). **The third marks a delivery as it goes**: started, picked up, delivered,
or failed ("Marking a delivery as it goes"). Those three are all the POS ever changes in Shipday, each by a
tap that says so and never by itself. **The fourth lets Shipday move the check**: a delivery picked up in
Shipday takes its check Out on the POS, and one delivered there closes it, by itself ("Shipday moves the
check").

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
- **Mark…** on one that is not finished: says in Shipday how far along it is ("Marking a delivery as it
  goes").
- **The check it is on the POS** ("Check #12"): a tap opens it, and Back returns here. A check that is out
  with a driver, or was closed or voided, says so ("Check #12 · out"). A delivery the hub finds no check
  for says **Not on the POS**.
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

## Marking a delivery as it goes

A driver says in Shipday's app how far along a delivery is. **Mark…**, on a delivery that is not finished,
says it from the POS instead: for a driver whose phone is dead, one who forgot, or a delivery that will not
be made. It opens **Mark it as…**, which names the delivery, who has it and where it stands now, and shows
as buttons only what it can be marked as from there, in Shipday's own words:

| Where it stands | What it can be marked as |
| --- | --- |
| A driver has it: *Not accepted yet*, *Accepted* | Started, Picked up, Delivered, Failed, Incomplete |
| *Started* | Picked up, Delivered, Failed, Incomplete |
| *Picked up* | Ready to deliver, Delivered, Failed, Incomplete |
| *Ready to deliver* | Delivered, Failed, Incomplete |
| Nobody has it | Failed, Incomplete |

It goes forward only. A delivery is not marked back to an earlier step from the POS, and one nobody has is
not marked started, picked up or delivered: it is given to a driver first. Those rules are the hub's, and
they are a careful reading: Shipday's page names the six words and says nothing about which may follow
which ("Never tried for real").

**Started, Picked up and Ready to deliver are sent on the tap**, as in the driver's app. **Delivered,
Failed and Incomplete end the delivery and ask first** ("Mark it delivered? Mei Lin's delivery leaves
Shipday's active deliveries as Delivered. That cannot be taken back from the POS."). Failed and Incomplete
stand apart under "It will not be delivered:". What an ended delivery was marked as shows on it under
Finished today.

**A mark made by mistake is put right in Shipday's own app.** The POS has no way back, on purpose: it would
have to guess what Shipday allows.

The hub is as careful as with a driver:

1. **It asks Shipday for its list first**, and sends nothing if the delivery no longer stands where the
   screen showed it: the driver marked it in the meantime, it was given to somebody or taken back, it left
   the list. The screen says so ("Shipday has it as "Picked up" by now. Nothing was changed.") and shows the
   list as it now is. A second look and a second tap mark it from where it really stands.
2. **It asks Shipday for the one change**: Shipday's number for the delivery and the one word.
3. **It asks for the list again.** The screen that asked says "Marked picked up."

What Shipday refuses, an answer that never comes and a hub that does not answer are told as with a driver.
Anybody who is signed in can mark a delivery, and the hub's log has who did, with Shipday's number and the
word and nothing of the customer.

**A mark made here moves the check like the driver's own.** The hub follows what Shipday says, whoever said
it: a delivery marked Picked up from the POS takes its check Out, and one marked Delivered closes it unless
money is still due ("Shipday moves the check"). Where that is so, the asking before Delivered says it:
"Check #9 follows: it is closed as delivered, unless money is still due on it." Whether Shipday sends the
customer its own text when a delivery is marked from here, as it may when the driver marks it, is not
written on Shipday's pages.

## Shipday moves the check

The owner chose this on 2026-11-28, from three ways the two could go together: "Shipday moves the check.
When a driver marks picked up or delivered in Shipday, the check goes Out or Delivered by itself. The POS
sends no second text, and a check with money due stays open."

So nobody taps Out and Delivered on the POS for a delivery that Shipday's driver carries. Each time the hub
has asked Shipday ("How often Shipday is asked"), it looks at every delivery it found a check for ("Which
check a delivery is") and makes the check say the same:

| Shipday says | The check on the POS |
| --- | --- |
| *Picked up*, *Ready to deliver* | goes **Out**, with Shipday's driver and the time Shipday says it was picked up |
| *Delivered*, nothing left to pay | is marked **delivered** and **closed** |
| *Delivered*, money still due | **stays open**, out with its driver, and says "Shipday: delivered 18:55" |
| *Failed*, *Incomplete* | stays where it is, and says "Shipday: failed 19:02" |
| anything before picked up | nothing |

**Out.** The check stands under Out on the Deliveries screen and in the list of checks like one somebody
sent out, under the driver's name as Shipday has it with "(Shipday)" behind it ("Tom Reyes (Shipday)"), so
nobody takes them for a Tom on the POS's own staff. Shipday's drivers are not added to the POS's staff: they
have no PIN and cannot be picked on the POS. The day's **Runs** count them like any driver (`delivery.md`).

**No second text.** A check somebody sends out on the POS texts its customer that the order is on its way.
One that Shipday takes out texts nobody: Shipday tells the customer itself. That is the only difference.

**Delivered.** A check with nothing left to pay (paid online, or paid at the counter before it left) is
marked delivered and closed, as when somebody taps Delivered. One the hub never saw leave goes Out first in
the same moment, so its history and the day's runs say who took it.

**Money still due.** The check is not closed behind the money. It stays open and out with its driver, and
every place that shows it says what Shipday said: the card on the Deliveries screen ("$21.40 due" and under
it "Shipday: delivered 18:55"), its line in the list of checks, and the strip at the top of the order.
Whoever takes the money taps **Delivered** as ever, which asks for the payment first. If the payment is
taken on the order itself and the check left open, the hub closes it the next time it asks Shipday.

**Failed, Incomplete.** A person decides what becomes of the bag and of the check: **Came back** on the
Deliveries screen puts it with the waiting ones again, or the check is voided. The check says "Shipday:
failed 19:02" until then.

What keeps it from doing harm:

- **Only forward, and only an open delivery.** A check that is closed or voided, one that is no delivery any
  more (the customer comes for it after all), and one somebody marked delivered already stay as they are. A
  check that is out already, with whoever, is not sent out again.
- **Only what a person could have tapped.** A check the kitchen never had (nothing sent, not marked ready)
  is not moved, as the POS's own Out refuses it. It says "Shipday: picked up 18:40" so somebody sees that
  the bag is gone and the check never went to the kitchen.
- **Once.** The hub writes each step of a delivery one time, however often it asks. What a person does
  afterwards stands: a bag that came back is not sent out again because Shipday still says picked up
  (another driver picking it up is a new step), and a check a manager opened again is not closed again.
- **One way.** Out or Delivered tapped on the POS tells Shipday nothing. Mark… on the Shipday screen is how
  the POS says something there.
- **Only a check the hub is sure of.** A delivery it found no check for moves nothing.

**How soon.** At the hub's next asking: within twenty seconds while the Shipday screen is open somewhere,
within about a minute while any terminal is on, and up to five minutes when none is.

**The time on it.** The check keeps the moment Shipday names, where that is within the last 45 minutes;
otherwise the moment the hub heard. Shipday's times come without a zone ("Never tried for real"), and a
time read in the wrong zone would be off by hours, which this catches.

**A check's history** (`check-history.md`) says what the hub did for Shipday as Shipday's: "Left with Tom
Reyes", "Marked delivered", "Closed the check", each by **Shipday**. Where the check stayed as it was, a
step of its own says what Shipday said: "Shipday says it was delivered", "Shipday says the delivery failed".

**Turning it off.** **Location**, a manager's PIN, and in the card with the delivery fee: **Shipday moves the
check**. It is on to start, and saved with the Save bar like the rest of that screen. Off, a check stays
where it is whatever Shipday says, Out and Delivered are tapped on the POS as before, and the Shipday screen
goes on showing and changing Shipday. Without a key for Shipday the switch does nothing either way.

What it cannot do:

- **A hub that restarts** knows nothing of what finished in Shipday before the restart. A delivery that was
  delivered while the hub was down stays Out on the POS until somebody taps Delivered.
- **A delivery of yesterday.** Only today's checks are matched.
- **The POS's own deliveries** (phone and counter orders) are not in Shipday yet, so nothing moves them
  ("What comes next").

## Setting it up

1. In Shipday's Dispatch Dashboard (dispatch.shipday.com), under **My Account**, copy the **API key**.
2. On a terminal: the Orders screen, **More**, **Location**, a manager's PIN, **Keys and connections**, and
   the card **Shipday (deliveries)**. **Type the key**, paste it, Save.
3. **Try it**. The hub asks Shipday once and says what it listed: "Shipday answered: the key works. It lists
   2 deliveries out, 4 drivers, 1 on shift." Or why not.

The key is sealed on the hub like every other (`hub-keys.md`) and never shown again. **Remove** on the same
card stops the asking, and the Shipday button goes away. Never send the key to anybody in a message: it lets
its holder change the restaurant's deliveries.

With the key on the hub, whoever is signed in at a terminal can give a delivery to a driver, take it back,
and mark it as it goes. There is no switch that leaves the reading on and turns those off. From then on the
hub also moves the checks as Shipday says, unless that is turned off under Location ("Shipday moves the
check").

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
before the restart. Nothing of a customer is written to the hub's log. What the hub writes onto a check for
Shipday is the exception to "memory only": it is in the order's own log like any tap, and stays.

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

In this order, each its own piece:

- **Say that it is ready** for its driver to pick up.
- **Send the POS's own deliveries to Shipday** (the phone and counter ones, which Shipday does not know).

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
- **Marking a delivery.** The page gives the call, the six words and one example answer. It does not say
  which word may follow which, whether a delivery nobody has can be marked, whether a mark can be taken
  back, what Shipday answers when it refuses (the example is an empty answer, so the screen may only say
  "Shipday would not do it."), or whether Shipday texts the customer on a mark that came from here. The
  first time, mark one delivery **Started** (the mark that matters least), look at it in Shipday's own app,
  and only then try Delivered on one that really was.
- **The form of the arrival time on the order itself.** One that is not a time is shown as Shipday wrote it
  ("Shipday says 12 min").
- **Shipday moving the check.** It stands on everything above: that the hub finds the right check for a
  delivery, that Shipday's words for picked up and delivered are the ones on its pages, and that a finished
  delivery can be asked after by its number. If the matching does not work with the restaurant's account,
  no check moves, and Out and Delivered are tapped as before. If a check ever moves that should not have,
  turn **Shipday moves the check** off under Location and say what happened: a manager can open a closed
  check again, and Came back takes one back from its driver. The first evening, watch one delivery: its
  check should go Out within a minute or so of the driver's Picked up, and the customer should get no text
  from the POS.

## An older hub, an older app

A hub from before this lists no Shipday key and has no Shipday button: nothing changes. An app from before
this on a new hub has no card and no button, and the hub asks Shipday all the same once it has a key.

A hub says to the app what it changes in Shipday when asked, and the app shows a button only for that: on a
hub that reads and does no more there is no button, and the line under the lists says it is done in
Shipday's own app; on a hub that gives deliveries to drivers and does not yet mark them there is no
**Mark…**. An app from before a button on a newer hub goes on as it did.

A hub that moves the checks does so whatever app the terminals have: an app from before it shows the check
out with Shipday's driver and closes it like any other, and only lacks the words "Shipday: delivered …", the
"(Shipday)" behind a driver's name and the switch under Location. A hub from before it follows nothing, and
a newer app then shows no switch and says nothing of it.

## The calls

| Call | What it does |
| --- | --- |
| `GET /shipday` | The picture: `on`, `read`, `trouble` (null, or `since_ms`, `reason`, `said`), `eta` (`off`, `on`, `plan`), `can` (what this hub changes in Shipday when asked: `driver`, `status`), `moves_checks` (whether what Shipday says moves the checks), `orders`, `done`, `drivers`. Every delivery has Shipday's `id`, `number` and `state`, its `steps` (what it can be marked as from there, in Shipday's words; none on a finished one), the customer's `name`, `address` and `phone`, its `driver` or null, its times in ms, `eta_ms` or `eta_said`, `total`, `fee`, `tip`, `payment`, `items`, `note`, `tracking`, `scheduled`, and `pos`: the check (`order_id`, `order_no`, `status`, `stage`, `by`) or null. `?looking=true` says a screen shows it. Anyone at a terminal reads it, like the list of orders |
| `POST /shipday/ask` | Asks Shipday now. Not passed on within ten seconds of the last asking (`soon`). 409 `no_key` |
| `POST /shipday/orders/{id}/driver` | `{staff_id, driver_id}`: gives the delivery with Shipday's id `{id}` to that driver. Answers `done`, `sent` (Shipday was asked to), `shown` (its list shows it), why not (`reason`, `said`, and `told`: Shipday's own words) and the picture after it (`shipday`). `reason` when nothing was sent: `not_listed`, `has_driver`, `unsure`, `unknown_driver`, or why Shipday could not be asked first; when it was: `rejected`, `not_found`, or why no answer came. 409 `no_key`, 404 `unknown_staff` |
| `POST /shipday/orders/{id}/driver/back` | `{staff_id, driver_id}`: takes it back from the driver the screen showed it with. The same answer; `reason` when nothing was sent: `not_listed`, `no_driver`, `other_driver`, `on_its_way`, `unsure` |
| `POST /shipday/orders/{id}/status` | `{staff_id, status, was}`: marks it `status` (`STARTED`, `PICKED_UP`, `READY_TO_DELIVER`, `ALREADY_DELIVERED`, `FAILED_DELIVERY`, `INCOMPLETE`), where `was` is the `state` the screen showed. The same answer; `reason` when nothing was sent: `not_listed`, `moved` (it stands elsewhere by now), `not_a_step` (not one of its `steps`). 422 for a word that is none of the six |
| `GET /settings/shipday` | `{"moves_checks": true}`: whether what Shipday says moves the checks. On until a manager says otherwise |
| `PUT /settings/shipday` | The same body, a manager's (the Bearer token of Location). 422 unless `moves_checks` is true or false, 503 on a hub that cannot write |
| `PUT` / `DELETE /hub/keys/shipday` | The key, a manager's (`hub-keys.md`) |
| `POST /hub/shipday/try` | A manager's try: asks once, answers like `GET /hub/keys` with `shipday_tried` (`ok`, `reason`, `said`, `orders`, `drivers`, `on_shift`). 409 `no_key` |

`GET /hub/keys` also carries `shipday`: how the asking goes (`on`, `running`, `asked_ms`, `answered_ms`,
`trouble`, `eta`, and how many `orders`, `drivers` and drivers `on_shift` were last listed). No order and no
customer is in it.

The change feed (`GET /live`) says `shipday` when the picture reads differently or the key changed, which
it does after a delivery was given to a driver, taken back or marked, and when `moves_checks` is set. A
check the hub moved is in the feed like any check that changed.

**What the hub writes onto a check** (`pos.shipday.follow`), as operations of the order's own log by the
device `shipday`, each with a fixed id so that it is written once:

| Operation | Id, after the order's | What it sets |
| --- | --- | --- |
| Out | `shipday-out-{delivery}-{driver}` | `stage: out`, `driver` (Shipday's name for them, or "Shipday driver"), `driver_id` (`shipday:{driver}`), `out_at`, `by: Shipday`, `shipday` |
| Delivered | `shipday-delivered-{delivery}`, then `shipday-closed-{delivery}` (a `close`) | `stage: picked_up`, `by: Shipday`, `shipday` |
| What Shipday said, the check left as it is | `shipday-said-{delivery}-{word}` | `shipday`, `by: Shipday` |

`shipday` is an order field of its own: `{id, number, state, at_ms}`, Shipday's id and number for the
delivery, its word (`PICKED_UP`, `ALREADY_DELIVERED`, `FAILED_DELIVERY`, `INCOMPLETE`) and the moment the
check keeps for it. Only the hub writes it: one a screen sends is dropped at the door. The hub's own
`Notifier` is not told of these operations, which is why no text goes out. A check's history
(`GET /orders/{id}/history`) has a step `shipday` (`state`, `said_ms`) where the field changed and the
stage did not.

What the hub asks of Shipday for the three changes: `PUT /orders/assign/{orderId}/{carrierId}` and
`PUT /orders/unassign/{orderId}`, with nothing in them, and `PUT /orders/{orderId}/status` with
`{"status": "PICKED_UP"}`.

The code: `backend/src/pos/shipday/` (`client.py` asks, `read.py` reads what comes back, `match.py` finds the
check, `board.py` keeps the picture and paces the asking, `follow.py` says what a check is to be made to
say) and `backend/src/pos/api/shipday.py` (the calls, and `follow`, which writes it after every asking that
was answered); in the app `lib/shipday.dart`, `lib/screens/shipday_screen.dart`, the card in
`lib/screens/hub_keys_screen.dart`, the switch in `lib/screens/location_settings_screen.dart`, and
`Order.shipdaySays` wherever a delivery's check is shown. The tests ask a pretend Shipday
(`backend/tests/shipday/fake.py`).
