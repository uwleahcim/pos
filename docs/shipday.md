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
or failed ("Marking a delivery as it goes"). **The fourth lets Shipday move the check**: a delivery picked up
in Shipday takes its check Out on the POS, and one delivered there closes it, by itself ("Shipday moves the
check"). **The fifth says that a delivery is ready for pickup**: the food is made and waits for its driver.
The hub says it by itself when the delivery's check is marked Ready on the POS, and a button says it for the
odd one ("Saying it is ready for pickup"). Those four changes (a driver given, taken back, a mark, ready for
pickup) are all the POS ever changes in Shipday. The first three happen only by a tap that says so, never by
themselves; ready for pickup is the one thing the hub tells Shipday on its own.

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
- **Ready for pickup** on one that was not picked up yet: tells Shipday the food is made. Afterwards the card
  says "Ready for pickup · told 18:30" instead, and it says the same when the hub told Shipday by itself
  because the check was marked Ready ("Saying it is ready for pickup").
- **The check it is on the POS** ("Check #12"): a tap opens it, and Back returns here. A check that is marked
  Ready, is out with a driver, or was closed or voided, says so ("Check #12 · ready", "Check #12 · out"). A
  delivery the hub finds no check for says **Not on the POS**.
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

Giving a delivery to a driver and taking it back are never done by the hub on its own: not on a timer, not
when a check changes, not when a driver signs in on the POS.

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

## Saying it is ready for pickup

Shipday has a mark of its own for an order whose food is made and waits for its driver: "ready to pickup".
The POS sets it in two ways.

### By itself, when the check is marked Ready

The owner chose this on 2026-11-28, from three ways it could go: "By itself when the check is Ready. When a
delivery's check is marked Ready on the POS, the hub tells Shipday it is ready for pickup. A button on the
Shipday screen stays for the odd one."

So whoever bags a delivery marks its check **Ready** on the POS as ever, and that is all: the hub tells
Shipday. The card on the Shipday screen then says **"Ready for pickup · told 18:30"**, and the check's
history says "Told Shipday it is ready for pickup · By itself, as the check was marked Ready".

Which delivery the hub tells Shipday of:

- one Shipday lists that **was not picked up** there, with a driver or without one (the food can be made
  before a driver is found);
- that the hub **found a check for** ("Which check a delivery is");
- whose check is an **open delivery standing at Ready**. Who marked it makes no difference: a person at a
  screen, or the website's own word that the order is ready (`online-orders.md`);
- and that **was not told yet**.

**How soon.** A screen that marks a delivery Ready has the hub ask Shipday at once, so Shipday is told within
a few seconds. A check that became Ready another way (the website's word) is told at the hub's next asking
("How often Shipday is asked").

**Once.** That Shipday was told is written on the check, after Shipday answered yes. A hub that restarts
reads it there, and so does the location's other hub, so neither tells Shipday a second time. A check taken
back from Ready and marked Ready again is not told again either: Shipday has no call that takes the word
back, and it was told.

**When Shipday does not answer**, the hub tries again a minute later, three times in all. **When Shipday
refuses**, it does not ask the same again: only when the delivery stands elsewhere in Shipday (another driver
has it, the driver accepted or started) does it try afresh. Either way the delivery keeps its **Ready for
pickup** button on the Shipday screen, and nothing on the POS is held up: the check is Ready whatever Shipday
says. The hub's log says what happened, with the check's number and Shipday's number and nothing of the
customer.

**Nothing else moves.** No text is sent (a delivery that is ready is brought; nobody is asked to come for
it). The check is not changed beyond the line that says Shipday was told. A hub that stands by (the
location's second hub while the first serves) tells Shipday nothing.

**Turning it off.** **Location**, a manager's PIN, and under **Shipday moves the check**: **Ready tells
Shipday**. It is on to start, and saved with the Save bar like the rest of that screen. Off, Shipday is told
only by the button. Turned on again, the hub tells Shipday at its next asking of every delivery whose check
stands at Ready and was not told, also the ones marked meanwhile. Without a key for Shipday the switch does
nothing either way.

### The button, for the odd one

**Ready for pickup**, on a delivery that was not picked up yet, tells Shipday the same by hand: for a
delivery the hub found no check for, one whose check nobody marks, or one the hub could not tell. One tap
sends it, with no question first, like Started or Picked up: it ends nothing and takes nothing from anybody.
The screen says "Shipday was told it is ready for pickup."

It is offered on a delivery **with a driver or without one**. Where the delivery has its driver, it is the
button that stands out on the card and **Mark…** is the quiet one beside it; on one that still needs a
driver, **Give to a driver** stands out. It is not offered once the delivery was picked up, or finished, or
once Shipday was told (by the button or by the hub itself).

**Afterwards the card says "Ready for pickup · told 18:30"**, and the button is gone from it. The delivery
stands where it stood ("Accepted", "Started"): ready for pickup is no step of Shipday's, and its list is not
moved by it. Where the delivery has a check, the check's history says who told Shipday ("Told Shipday it is
ready for pickup", by Amy), and the hub does not tell Shipday again when that check is marked Ready later.

**The button tells Shipday and marks nothing on the POS.** The check is marked Ready on the POS itself.

The hub is as careful as with a mark: it asks Shipday for its list first and sends nothing for a delivery
that was picked up in the meantime ("It was picked up already. Nothing was changed.") or left the list; then
it sends the one thing, Shipday's number for the delivery and `readyToPickup: true`; then it asks for the
list again. Anybody who is signed in can do it, as anybody bags an order, and the hub's log has who did, with
Shipday's number and nothing of the customer.

### What "told" means

**That line is the hub's word, not Shipday's.** Nothing Shipday answers about a delivery says whether it was
marked ready, so the hub cannot read it back: it writes down that Shipday answered yes, and when. Three
things follow:

- **A delivery marked ready in Shipday's own app shows nothing here**, still has the button, and is told once
  more by the hub when its check is marked Ready. Telling Shipday twice does no harm as far as its pages say.
- **Of a delivery that has no check here, only the hub's memory knows.** A hub that restarts offers the
  button for it again. The same after midnight of the day of service, and with another key. One that has a
  check keeps the word on the check.
- **An answer that never came cannot be settled by looking.** After a tap the screen says "It may not have
  been told. Tap again to be sure.", and the button stays. The hub's own telling is simply tried again.

**It cannot be taken back from the POS**, like a mark.

What Shipday does with it (whether the driver's app rings, whether a driver not yet found is told later) is
not written on Shipday's pages ("Never tried for real").

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
  the POS says something there. (Ready is the one tap on a check that Shipday is told of: "Saying it is
  ready for pickup".)
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
mark it as it goes and say that it is ready for pickup. There is no switch that leaves the reading on and
turns those off. From then on the hub also does two things by itself, each with a switch of its own under
Location: it moves the checks as Shipday says ("Shipday moves the check"), and it tells Shipday that a
delivery is ready for pickup when its check is marked Ready ("Saying it is ready for pickup").

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

A screen that marks a delivery's check Ready also has Shipday asked at once, while the hub tells Shipday of
such checks by itself ("Saying it is ready for pickup").

All of it is kept in the hub's memory only. A hub that restarts asks again and knows nothing of what finished
before the restart. Nothing of a customer is written to the hub's log. What the hub writes onto a check for
Shipday is the exception to "memory only": it is in the order's own log like any tap, and stays. That
Shipday was told a delivery is ready for pickup is one of those things, where the delivery has a check; of a
delivery without one, only the hub's memory knows.

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
- **Ready for pickup.** The page gives the call and its one field, and nothing else: not who is told, not
  whether a delivery needs a driver first (the hub sends it for one without), not whether it can be taken
  back, not what a second telling does, and its example of a refusal is an empty answer. Nothing Shipday
  lists of a delivery says afterwards that it was marked, so "told 18:30" on the card means only that Shipday
  answered yes. **The hub sends it by itself from the moment it is updated**, for every delivery whose check
  is marked Ready, also the ones that stand at Ready at that moment. The first evening, mark one delivery's
  check Ready, see that the Shipday screen says "Ready for pickup · told …" within a few seconds, look at
  that delivery in Shipday's own app, and ask the driver what their phone showed. It also stands on the hub
  finding the right check for a delivery: if the matching does not work with the restaurant's account,
  nothing is told by itself and the button is the way. If drivers are told something they should not be,
  turn **Ready tells Shipday** off under Location and say what happened.
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
**Mark…**; on one from before ready for pickup there is no **Ready for pickup**. An app from before a button
on a newer hub goes on as it did.

A hub that moves the checks does so whatever app the terminals have: an app from before it shows the check
out with Shipday's driver and closes it like any other, and only lacks the words "Shipday: delivered …", the
"(Shipday)" behind a driver's name and the switch under Location. A hub from before it follows nothing, and
a newer app then shows no switch and says nothing of it.

A hub that tells Shipday of a check marked Ready does so whatever app the terminals have, too: Ready is
marked as ever. An app from before it shows "Ready for pickup · told …" on the card all the same (if it has
the button at all), and lacks the switch **Ready tells Shipday**, the words for it under the lists, and the
line in a check's history, which it shows as `shipday_ready`. Saving **Shipday moves the check** from such an
app leaves the other switch as it stands. A hub from before it tells Shipday only by the button, and a newer
app then shows the first switch alone.

## The calls

| Call | What it does |
| --- | --- |
| `GET /shipday` | The picture: `on`, `read`, `trouble` (null, or `since_ms`, `reason`, `said`), `eta` (`off`, `on`, `plan`), `can` (what this hub changes in Shipday when asked: `driver`, `status`, `ready`), `moves_checks` (whether what Shipday says moves the checks), `tells_ready` (whether a check marked Ready tells Shipday by itself), `orders`, `done`, `drivers`. Every delivery has Shipday's `id`, `number` and `state`, its `steps` (what it can be marked as from there, in Shipday's words; none on a finished one), `can_ready` (whether it can be said ready for pickup) and `ready_ms` (when Shipday was told so, by a tap or by the hub itself, as the hub remembers or the delivery's check says; or null), the customer's `name`, `address` and `phone`, its `driver` or null, its times in ms, `eta_ms` or `eta_said`, `total`, `fee`, `tip`, `payment`, `items`, `note`, `tracking`, `scheduled`, and `pos`: the check (`order_id`, `order_no`, `status`, `stage`, `by`) or null. `?looking=true` says a screen shows it. Anyone at a terminal reads it, like the list of orders |
| `POST /shipday/ask` | Asks Shipday now. Not passed on within ten seconds of the last asking (`soon`). 409 `no_key` |
| `POST /shipday/orders/{id}/driver` | `{staff_id, driver_id}`: gives the delivery with Shipday's id `{id}` to that driver. Answers `done`, `sent` (Shipday was asked to), `shown` (its list shows it), why not (`reason`, `said`, and `told`: Shipday's own words) and the picture after it (`shipday`). `reason` when nothing was sent: `not_listed`, `has_driver`, `unsure`, `unknown_driver`, or why Shipday could not be asked first; when it was: `rejected`, `not_found`, or why no answer came. 409 `no_key`, 404 `unknown_staff` |
| `POST /shipday/orders/{id}/driver/back` | `{staff_id, driver_id}`: takes it back from the driver the screen showed it with. The same answer; `reason` when nothing was sent: `not_listed`, `no_driver`, `other_driver`, `on_its_way`, `unsure` |
| `POST /shipday/orders/{id}/status` | `{staff_id, status, was}`: marks it `status` (`STARTED`, `PICKED_UP`, `READY_TO_DELIVER`, `ALREADY_DELIVERED`, `FAILED_DELIVERY`, `INCOMPLETE`), where `was` is the `state` the screen showed. The same answer; `reason` when nothing was sent: `not_listed`, `moved` (it stands elsewhere by now), `not_a_step` (not one of its `steps`). 422 for a word that is none of the six |
| `POST /shipday/orders/{id}/ready` | `{staff_id}`: tells Shipday it is ready for pickup. The same answer, except that `shown` is always false (Shipday's list has no place for it) and `done` is Shipday's own answer; `reason` when nothing was sent: `not_listed`, `on_its_way` (it was picked up), `unsure`. A delivery it was told of has `ready_ms` from then on, and where it has a check, the check is written on (below) |
| `GET /settings/shipday` | `{"moves_checks": true, "tells_ready": true}`: whether what Shipday says moves the checks, and whether a check marked Ready tells Shipday its delivery is ready for pickup. Each on until a manager says otherwise |
| `PUT /settings/shipday` | Either or both, a manager's (the Bearer token of Location); one that is left out stays as it stands. Answers both. 422 unless each is true or false, 503 on a hub that cannot write |
| `PUT` / `DELETE /hub/keys/shipday` | The key, a manager's (`hub-keys.md`) |
| `POST /hub/shipday/try` | A manager's try: asks once, answers like `GET /hub/keys` with `shipday_tried` (`ok`, `reason`, `said`, `orders`, `drivers`, `on_shift`). 409 `no_key` |

`GET /hub/keys` also carries `shipday`: how the asking goes (`on`, `running`, `asked_ms`, `answered_ms`,
`trouble`, `eta`, and how many `orders`, `drivers` and drivers `on_shift` were last listed). No order and no
customer is in it.

The change feed (`GET /live`) says `shipday` when the picture reads differently or the key changed, which
it does after a delivery was given to a driver, taken back, marked or said ready for pickup (by a tap or by
the hub itself), and when `moves_checks` or `tells_ready` is set. A check the hub moved or wrote on is in the
feed like any check that changed.

**What the hub writes onto a check** (`pos.shipday.follow`, `pos.shipday.ready`), as operations of the
order's own log by the device `shipday`, each with a fixed id so that it is written once:

| Operation | Id, after the order's | What it sets |
| --- | --- | --- |
| Out | `shipday-out-{delivery}-{driver}` | `stage: out`, `driver` (Shipday's name for them, or "Shipday driver"), `driver_id` (`shipday:{driver}`), `out_at`, `by: Shipday`, `shipday` |
| Delivered | `shipday-delivered-{delivery}`, then `shipday-closed-{delivery}` (a `close`) | `stage: picked_up`, `by: Shipday`, `shipday` |
| What Shipday said, the check left as it is | `shipday-said-{delivery}-{word}` | `shipday`, `by: Shipday` |
| Shipday was told it is ready for pickup | `shipday-ready-{delivery}` | `shipday_ready`, and `by`: Shipday where the hub told it by itself, else who tapped the button |

`shipday` is an order field of its own: `{id, number, state, at_ms}`, Shipday's id and number for the
delivery, its word (`PICKED_UP`, `ALREADY_DELIVERED`, `FAILED_DELIVERY`, `INCOMPLETE`) and the moment the
check keeps for it. Only the hub writes it: one a screen sends is dropped at the door. The hub's own
`Notifier` is not told of these operations, which is why no text goes out. A check's history
(`GET /orders/{id}/history`) has a step `shipday` (`state`, `said_ms`) where the field changed and the
stage did not.

`shipday_ready` is another: `{id, at_ms, auto}`, Shipday's id for the delivery, when Shipday answered that it
is ready for pickup, and whether the hub told it by itself (`auto`) or a person tapped the button. Only the
hub writes it, after Shipday answered yes; one a screen sends is dropped at the door. It is how a hub that
restarted, and the location's other hub, know not to tell Shipday again, and `ready_ms` in the picture is
read from it. The history has a step `shipday_ready` (`auto`, `told_ms`) for it.

**The hub's own telling** (`tell_ready` in `pos.api.shipday`, `ready_by_itself` in the board) runs after
every asking Shipday answered, on the list that asking read: for each delivery with `can_ready`, whose check
(`pos`) is open at stage `ready`, while `tells_ready` is on and the hub's database takes writes. Operations a
screen stores that set a delivery's `stage` to `ready` bring the next asking forward (`mark_ready`).

What the hub asks of Shipday for the four changes: `PUT /orders/assign/{orderId}/{carrierId}` and
`PUT /orders/unassign/{orderId}`, with nothing in them, `PUT /orders/{orderId}/status` with
`{"status": "PICKED_UP"}`, and `PUT /orders/{orderId}/meta` with `{"readyToPickup": true}`. The last is the
same call whether a person tapped or the hub tells by itself.

The code: `backend/src/pos/shipday/` (`client.py` asks, `read.py` reads what comes back, `match.py` finds the
check, `board.py` keeps the picture and paces the asking, `follow.py` says what a check is to be made to
say, `ready.py` what is written on a check that Shipday was told of) and `backend/src/pos/api/shipday.py`
(the calls, `follow`, which writes what Shipday says after every asking that was answered, and `tell_ready`,
which tells Shipday of the checks marked Ready); in the app `lib/shipday.dart`,
`lib/screens/shipday_screen.dart`, the card in `lib/screens/hub_keys_screen.dart`, the two switches in
`lib/screens/location_settings_screen.dart`, and `Order.shipdaySays` wherever a delivery's check is shown. The tests ask a pretend Shipday
(`backend/tests/shipday/fake.py`).
