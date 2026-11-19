# Delivery orders

An order that is brought to the customer by the restaurant's own driver. It is a to-go order like any
other (`counter-mode.md`): named, numbered, rung in from the menu, paid the same ways. What it adds is
**where it goes**, a **note for the driver**, a quote that allows for the drive, and the word DELIVERY on
every paper, so nobody packs it for the shelf.

When the bag leaves, it is **handed to a driver**: the order says who has it and since when, and the
**Deliveries** screen shows what is waiting to leave and what each driver has out (see
[Drivers](#drivers)). **Runs** says what each driver took out over the day, run by run (see
[Runs](#runs)). A location that charges for the trip lists its prices, and the order says which one
applies (see [The delivery fee](#the-delivery-fee)). Where the hub has a map service, the form looks up how
far the address is and picks the price for it (see [Looking the distance up](#looking-the-distance-up)),
and a customer who orders again to the same address is not looked up a second time (see
[Customers who order again](#customers-who-order-again)).
Nothing else here is about money: there is no tip yet, and a delivery is a sale like any other, counted in
every report as a to-go order is.

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

## The delivery fee

A location that charges for delivery lists its prices, and whoever takes a delivery picks the one that
applies. **It is off until a manager lists the prices.** Until then nothing is added to anybody's check,
and the forms are what they were.

### Setting the prices

Back office › Location › **Delivery fee**:

- **Charge for delivery**: on or off.
- **The fee goes by**: **Miles**, or **Minutes of the drive**.
- **The prices**: each one is "up to so far, this much". For instance: up to 2 miles $3.00, up to 4.5
  miles $5.00, up to 8 miles $8.50. Miles go to a tenth of a mile and minutes are whole. There can be up
  to eight prices, and a price can be 0 for a free delivery close by. The hub keeps them nearest first.
- **Charge sales tax on the fee**: off to start. Whether a delivery fee is taxed is for your accountant
  to say. (Massachusetts leaves a delivery charge out of the sales tax when it is stated on its own on the
  bill and is a fair price for the trip, DOR Directive 04-5; that directive does not speak of meals, so
  ask. Nothing here is tax advice.)

The row under Location says what is set: "$3.00 up to 2 mi, $5.00 up to 4.5 mi, $8.50 up to 8 mi".

### Picking it on an order

With the fee on, the to-go form shows the prices as buttons under the note for the driver once
**Delivery** is tapped: each is headed by what it costs, over how far it reaches ("$5.00, Up to 4.5 mi"),
and the last one is **No fee**. On a small phone, or with large type, a button has no room for "Up to 4.5
mi" on one line: there it says "4.5 mi" and the heading says "Delivery fee, up to". The order cannot start
until one is tapped, and the form says "Pick the delivery fee." **No fee** is an answer: for a regular, or
to make up for a mistake. A catering order may leave it for later, like its address.

On the order the same buttons are in **Pickup or delivery** (the chip beside Allergy, or the line under
the bar). The fee is a line of the check, **Delivery fee**, under the subtotal, and a tap on that line
opens the same buttons.

- **The hub sets the amount.** A screen says only which price was picked, and the hub writes what that
  price costs. Nobody types an amount.
- **An order keeps the fee it was given.** When the prices are changed later, an order already taken is
  charged what it was told. Its own fee then shows as a button of its own, "as taken", until another is
  picked.
- **Only a delivery is charged.** An order made a pickup is charged nothing for the trip. Made a delivery
  again, the fee picked before is charged again.
- **Anybody who takes orders picks the price**, and may pick No fee. It is not behind a manager's PIN. The
  check's history says who picked what, and what it was before: "Delivery fee $8.50, up to 8 mi. It was
  $5.00 · up to 4.5 mi."
- **It is on the bill and in the sales.** The bill lists "Delivery fee" under the subtotal. The day's
  report and the sales count it under **Charges**, never as a gratuity. A table that pays on several
  checks shares it between them like any charge.
- **Tax**: with the switch off the fee adds no tax, and the food is taxed as before. With it on, the fee
  is taxed with the food. A check a manager marked tax exempt pays the fee and no tax.

The price is tapped by hand unless the hub looks the distance up, which is the next section.

## Looking the distance up

With a map service set up on the hub, nobody has to know how far an address is. The form asks the hub, the
hub asks the map service, and the price for that distance is picked. **Nothing is looked up until the hub
has a key for the map service and the restaurant's own address is typed in** (see
[Setting it up](#setting-it-up)). Until then the price is tapped by hand, as above.

### On the form

- Tap **Delivery**, type the address, and press Enter (Done on a phone's keyboard) or go on to the next
  box. A line over the prices says "Looking up how far it is…", then what the map said: **3.2 mi · 9 min
  drive**. The price that distance falls in is picked: with $3.00 up to 2 mi and $5.00 up to 4.5 mi, 3.2
  miles is $5.00. A distance right at a price's reach is that price (4.5 miles is "up to 4.5 mi"). Until
  the address has been asked about, the line is a button, **Look up the distance**, that asks.
- **A returning customer's address** is asked about as soon as the order is a delivery, without a tap.
  Where they had a delivery brought there before, the map service is not asked at all (see
  [Customers who order again](#customers-who-order-again)).
- **Any other price can still be tapped**, and No fee too. **A price tapped by hand stays.** From that tap
  on the map only says how far, on this form: it does not move the price when its answer comes late, nor
  when the address is typed again. Nobody's "No fee" turns into a charge by itself.
- **Too far**: "9.3 mi · 21 min drive: further than the prices reach". Nothing is picked. Whoever takes
  the order decides (the last price, No fee, or no delivery that far), and the order cannot start until a
  price is tapped.
- **No answer**: the line says why and ends "Pick the fee by hand.", over a **Try again** button. The
  address could not be found (check the spelling, add the town); the map service is not answering, which
  is also what a restaurant without internet sees; the map service refused the hub's key; or it has been
  asked as often as it may be today. An order is never held up by the map: tap a price.
- **An address is asked about once**, when it is done being typed, never letter by letter, and not by a
  form that is being closed. The same address again, on this order or the next, is answered by the hub from
  what it was told that day.
- **Only where there is a price to pick.** With the fee turned off, or on a pickup, nothing is asked.

On the order (**Pickup or delivery**) it is the same line. Opening it asks nothing, and the order keeps the
fee it has. Type another address and that one is looked up and its price picked (unless a price was tapped
there first); or tap **Look up the distance** to ask about the address as it stands.

The lookup gives both the miles and the minutes whichever the fee goes by, and the price is picked by the
one the fee goes by. Miles are along the road, to a tenth of a mile. Minutes are the usual drive, to the
nearest minute: the map service does not know about tonight's traffic.

**The map suggests, a person decides.** What the map said is kept beside the pick, and the check's history
shows it: "Delivery fee $3.00, up to 2 mi. The map said 3.2 mi · 9 min", with who picked it. It never
changes what a price costs.

### Customers who order again

The map service is asked about a customer's address **once**. What it said, the miles and the minutes of
the drive, is kept on that order beside the fee. The next time the same phone number orders a delivery to
the same address, the hub reads the two numbers off that earlier order and asks nobody.

- **On the form** the line then reads **3.2 mi · 9 min drive, as last time**, and the price that distance
  falls in is picked, at the prices as they are today. It comes at once, since nothing outside the
  building is asked.
- **Look it up again**: the small round arrow at the end of that line asks the map service all the same,
  for a new road or a distance that looks wrong. What it says then is kept on this order, and is the one
  used from then on.
- **The same customer** is the same phone number, however it is typed: "(781) 555-0101" and "781 555 0101"
  are one. An order with no number is looked up, as before.
- **The same address** is the same letters, capitals and spaces aside. "12 Elm St" and "12 Elm Street" are
  two addresses to the hub: the second is looked up once, and remembered too. The address of a customer's
  last delivery is filled in by the form exactly as it was, so this seldom comes up.
- **It works when the map service does not**: with no internet, with the service down, or past the day's
  500, a returning customer's distance is still there.
- **Not used**: a distance from an order that was voided or was picked up after all; a delivery whose
  price was tapped before the map had answered (that order has no distance on it); and every distance
  measured from another address of the restaurant's. Change the restaurant's address under Location, and
  each customer is looked up once more, from the new one.
- **They do not go stale by themselves.** A distance is used however old it is, until somebody looks it up
  again. Houses do not move, and the map service is spared.
- **Nothing is counted against the day's 500**, and `sudo hubctl maps status` says how often a customer's
  own earlier order spared the asking today.

Nothing new is stored for this. There is no list of customers and distances anywhere: the two numbers are
on the customer's own orders, where the fee already was, and they go wherever the orders go (the second
hub, the cloud). The phone number goes from the screen to the hub, as it does with every order, and no
further: the map service is still sent the two addresses and nothing else.

### What leaves the building

- **The two addresses**: the restaurant's own and the delivery's. Nothing else: no name, no phone number,
  nothing of what was ordered.
- **The hub asks, not the screens.** The key is on the hub and nowhere else: not in an app and not in
  the database.
- **The hub writes no address down for this.** Its log names no address and no key. The answers are held in
  memory for a day, 500 at most, and a restart of the hub forgets them.
- **The miles and the minutes are kept on the customer's own order**, beside the fee that was picked with
  them, and nowhere else. That is how a returning customer is not looked up again. Geocodio's terms said on
  2026-11-18 that its results may be kept; a service whose terms forbid that would have its numbers used
  for the pick and not kept.
- **The customer's phone number stays on the hub.** The form sends it with the address so the hub can
  look at that customer's earlier orders. It is never sent to the map service.
- **The map service keeps its own records.** Geocodio's pages said this on 2026-11-18: a log of requests,
  which can hold what was asked, is kept for 45 days and then deleted
  (<https://www.geocod.io/data-retention-policy>); customers' data is disclosed only where the law requires
  it or in a form that names nobody, and results may be kept (<https://www.geocod.io/terms-of-use>). Read
  both before signing up: they are the service's to change.
- **At most 500 lookups a day** (`POS_MAPS_DAILY` in `/opt/pos/.env`), so a screen gone wrong cannot run up
  a bill. Past that the form says so and the price is tapped by hand until the next day.

### Setting it up

The hub is built for one map service so far, **Geocodio** (<https://www.geocod.io>), which knows addresses
in the United States and Canada. The account is the owner's to make: nothing here makes one.

1. **Make an account** at <https://dash.geocod.io>. On 2026-11-18 its pages said the first 2,500 credits
   of each day are free and no card is asked for under that. A new address costs 4 credits (2 for the
   drive, 1 for each of the two addresses), so about 600 new addresses a day are free, and the hub stops at
   500 by itself.
2. **Make a key** at <https://dash.geocod.io/apikey> and **turn on its Distance permission** there. A new
   key can only find addresses until that is on, and the form would say the map service refused the key.
3. **Put the key on the hub.** On the hub: `sudo hubctl maps key`, and paste the key when asked. It is not
   shown as it is pasted and is never part of a command, so it is in no command history. The hub keeps it
   in `/opt/pos/.env` and restarts its API (a few seconds).
4. **Type the restaurant's own address** in the app: Back office › Location › **Delivery fee** ›
   **Restaurant address**, in full, with the town and the state. Save. The row under Location then ends
   "· distance looked up".
5. **Try it**: `sudo hubctl maps test "12 Elm St, Winchester, MA"` answers like "3.2 mi, 9 min: $5.00 (up
   to 4.5 miles)", or says why not in the form's own words. When every address "could not be found", the one
   to check is the restaurant's own.

`sudo hubctl maps status` says whether the hub has a key, whether the address is set, how often the
service was asked today and gave nothing, and how often it did not have to be asked because a customer's
own earlier order said how far. `sudo hubctl maps forget` takes the key off the hub: nothing is
looked up and the price is tapped by hand again. (The key itself is deleted on the service's own page.)

Until the hub has a key, the dialog under Location says "This hub has no map service yet, so the price is
picked by hand (hubctl maps key)." The address can be typed all the same, and is used from the day the hub
has one.

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

- **The map's price is a suggestion.** Nothing stops another price or No fee being tapped, and nothing
  refuses an address for being too far. The history says what the map said and who picked what.
- **No map on the screen, no route, no delivery area drawn.** The lookup answers with two numbers.
- **No traffic.** The minutes are the usual drive, whatever the hour.
- **A saved distance is not checked again by itself.** It is used until somebody taps the round arrow, and
  there is no screen that lists customers' distances or clears them all. (Changing the restaurant's own
  address under Location has every customer looked up once more.)
- **"12 Elm St" is not "12 Elm Street".** Two spellings of one address are two addresses, each looked up
  once.
- **One map service.** Geocodio is the one built. Another is a small piece of the hub
  (`pos.maps.Maps`), not a setting.
- **Nothing looked up without the internet.** The hub needs to reach the map service. The form says so and
  the price is tapped by hand.
- **No fee by itself, and no tip.** A fee goes on a check only when somebody picked one. (The pricing
  rules have had an automatic delivery fee since discounts were built, `discounts.md`, but it is for
  orders of the type `delivery`, which no screen makes. It stays as it was, and is not this fee.)
- **No amount typed by hand.** A delivery costs one of the listed prices or nothing.
- **No line of its own in the reports.** Delivery fees are in **Charges** with any other charge.
- **With no hub answering, the total on the screen leaves out a fee just picked** and says "Total
  (updating)". The price is on the button that was tapped; the check adds it when the hub answers.
- **The runs are on the screen only.** They are not printed, and there is no file of them.
- **No money with the driver.** Nothing counts what a driver collected at doors or owes the drawer, and
  there is no driver's fee or tip. Taking the money for a delivery is recorded as on any to-go order, by
  whoever marks it delivered.
- **The address goes nowhere else.** It is sent to the map service for the distance, alone, and only
  where the owner set that up ([What leaves the building](#what-leaves-the-building)). No texting
  service, no delivery app and no other service is told it.
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

The fee likewise: on a hub from before the fee, the forms show no prices, and the row under Location says
"The hub has not answered about the delivery fee (an older hub: update it)". An app from before the fee on
a new hub shows the fee on the check and cannot pick one; a tap on that line does nothing there.

The lookup likewise: on a hub from before the lookup the forms have no line about the distance and the
dialog under Location has no box for the restaurant's address. An app from before the lookup on a new hub
picks the price by hand; saving the prices from it keeps the address the hub has.

Saved distances likewise: on a hub from before them every address is looked up, and no line says "as last
time". An app from before them on a new hub does not send the customer's number, so its deliveries are
looked up each time, and the distances it sends with a pick are kept as a note and not used again. Rebuild
the apps after the hub and both stop.

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
  was delivered, came back, changed driver or was voided; it left at the `out_at` carried by the operation
  that sent it out (at that operation's own time when it carries none, as one handed on along the way) and
  counts on the day of service it left in. A **run** is one
  driver's legs that each left within `RUN_GAP_MS` (five minutes) of the one before, with none of them
  delivered yet. Drivers are told apart by `driver_id`, by name only for one named without an id.
- The answer does not say when it was read, so an answer that has not changed keeps its `ETag` and a
  screen that asks again is sent nothing.
- App: `lib/runs.dart` (the answer and its words), `lib/screens/runs_screen.dart`, `PosApi.runs` (null
  from a hub older than the runs), opened by `deliveries-runs` on the Deliveries screen.
- Tests: `backend/tests/orders/test_runs.py`, `apps/pos_app/test/runs_test.dart`.

The delivery fee:

- The setting `delivery_fee` (`pos.settings.clean_delivery_fee`, `GET/PUT /settings/delivery_fee`, a
  manager's token to write): `enabled` (false to start), `by` (`miles` | `minutes`), `bands` (each
  `{up_to, fee}`, `up_to` a string such as `"2"` or `"2.5"`, kept in order of reach, at most 8) and `taxed`.
- The order field `delivery_fee` (`pos.orders.delivery_fee`). A screen sends the band alone,
  `{"up_to": "4.5"}`, `{"up_to": null}` for no fee on purpose, or null to take the answer back. `fee_ops`
  (in `append_ops`, after `bag_ops`) fills it in from the setting as it arrives:
  `{by, up_to, amount, taxed}`. A band the setting does not list is refused (`invalid_delivery_fee`) and
  left out, and whatever else the operation said is kept. Anything a screen sends beside `up_to` is
  dropped, so no screen sets an amount.
- The check (`pos.orders.check.check_for`): `fee_charged(fields)` gives the fee only while
  `is_delivery(fields)` and the amount is above zero. It is a row of `charges` with the id `fee:delivery`
  (not the pricing rule's code `delivery_fee`), `automatic: false`, `taxed`, and `delivery: {by, up_to}`.
  Taxed, it is a taxable line of the class `delivery_fee` (the profile's own rule for it, else its default
  rule); not taxed, it adds no base, on the order and on each check of a split (`pos.orders.split`).
- History (`pos.orders.history`): a `delivery_fee` step with `now` and `was`, each the fee as
  `fee_of` reads it or null. An order opened with its fee says it in a step after `opened`.
- App: `lib/delivery_fee.dart` (`DeliveryFees`, `FeeBand`, `OrderFee`, `FeePick`),
  `PosApi.deliveryFees` (null from a hub older than the fee) and `saveDeliveryFees`,
  `lib/screens/fee_picker.dart` (the buttons, inside `EventFields`), `WhenDialog.fees` and `.fee`,
  `TakeoutRequest.fee`, `CheckCharge.isDeliveryFee` (a tap opens `_changeWhen`),
  `lib/screens/delivery_fee_dialog.dart` and the row `delivery-fee` under Location.
- Tests: `backend/tests/orders/test_delivery_fee.py`, `apps/pos_app/test/delivery_fee_test.dart`.

Looking the distance up:

- `pos.maps`: `Maps` (a service: `trip(origin, destination) -> Trip`, or `LookupFailed` with a `reason`
  of `not_found`, `unreachable`, `refused` or `limit`), `Geocodio` (the one service: `GET /distance` with
  `origin`, `destinations[]` and `mode=driving`, the key in the `Authorization` header and never in the
  address of the request) and `Lookups` (the answers of a day in memory, the daily most, `status()`).
  `POS_MAPS_KEY`, `POS_MAPS` (`geocodio`), `POS_MAPS_URL` and `POS_MAPS_DAILY` in the environment;
  `create_app(lookups=...)` in a test.
- The setting `delivery_fee` gains `origin` (the restaurant's own address, one line, at most 200 letters).
  A `PUT` that says none keeps the one stored, so an app from before the lookup does not wipe it. The
  answers of `GET` and `PUT` add `maps` (the hub has a service) and `lookup` (a service and an origin):
  worked out, never stored.
- `POST /delivery/distance` `{"address"}` answers `miles` (a string, to a tenth), `minutes`, `by`, `band`
  (`{up_to, fee}` or null) and `beyond`. 409 `no_lookup` with no service or no origin; 422 for no address;
  424 `lookup_failed` with `reason` and a `message` for the form. It is not a 5xx on purpose: the hub is
  well, and a terminal reads a 5xx as a hub to turn away from. `GET /maps/status` is what `hubctl maps
  status` prints; no address is in it.
- `pos.orders.delivery_fee.band_for(setting, miles, minutes)` is the band a measure falls in: the nearest
  whose reach is not short of it. A pick may carry `measured: {"miles": "3.2", "minutes": 9}`; `fee_ops`
  keeps it beside the fee when it reads, and it never changes the amount.
- App: `PosApi.deliveryDistance`, `FeeLookup` and `Measured` (`lib/delivery_fee.dart`), `DistanceAsker`
  and `FeeLookupLine` (`lib/screens/fee_lookup.dart`: once per address, an answer for an address typed
  over is dropped), `FeePick.field(pick, measured:)`, `EventFields.asker`, `onAddressDone` and `onLookUp`,
  `WhenDialog.distance`, `TakeoutRequest.measured`, `DeliveryFees.origin`, `maps` (null from a hub older
  than the lookup), `lookup` and `looksUp` (a lookup and a price to pick: the one a form goes by).
- Tests: `backend/tests/orders/test_delivery_distance.py`, `apps/pos_app/test/delivery_distance_test.dart`.
  The service itself is never called in a test (`httpx.MockTransport`).

Customers who order again:

- Nothing is stored but the order field. `POST /delivery/distance` answers, beside the distance, `service`
  (the name of the service that measured it), `from` (`pos.maps.origin_mark`: eight hex digits of a hash
  of the restaurant's address as one line, lower case, so it says nothing of the address) and `saved`. A
  pick sends them back inside `measured`, `{"miles", "minutes", "service", "from"}`, and
  `pos.orders.delivery_fee.measured_of` keeps the two marks only together and only in the hub's own
  spelling. Figures without them are a note (an older app's) and are never handed on.
- The body may carry `phone` and `fresh`. With a phone and without `fresh`,
  `pos.customers.saved_trip(store, phone, address, mark)` reads the customer's newest orders (the index
  by phone, at most 40, voided ones aside, as `customer_card` does) for a delivery to the same address
  (`pos.maps.same_address`: the case and the spaces aside) whose `measured.from` is today's mark. Found,
  it is the answer, with `saved: true`: the service is not asked, the day's count does not move, and
  `Lookups.spared()` counts it for `saved_today` in `GET /maps/status`. Saved figures come before the
  day's answers in memory, so a customer is told the figure their own order carries.
- The band is always worked out from today's setting (`band_for`), never read off the old order.
- The phone number is used on the hub alone: `Maps.trip` takes the two addresses and nothing else.
- A service whose terms do not allow its results to be kept is not built. When one is, its figures must be
  left off the order in `fee_ops` (by `measured.service`), which is why the service's name is kept.
- App: `PosApi.deliveryDistance(address, phone:, fresh:)` (the digits only, and `fresh` only when true, so
  an older hub is sent what it knows), `DistanceSource`, `FeeLookup.saved`, `Measured.service` and `.from`
  (sent back as they came), `DistanceAsker.ask(fresh:)`, `LookUp` (`onLookUp(fresh: true)` from the button
  `fee-lookup-again`). The to-go form binds the number in its box, the order's dialog the order's own.
- Tests: the same two files ("Customers who order again", `customers who order again`).
