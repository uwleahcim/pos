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
[Customers who order again](#customers-who-order-again)). Where a manager turned it on, a delivery for now
is promised by the roads as they are at that minute (see [Live traffic](#live-traffic)). While an address
is typed, a list under the box says what it could become, the restaurant's own earlier deliveries first
(see [A list of addresses while typing](#a-list-of-addresses-while-typing)), with Mapbox and Azure Maps
behind Google once its free lookups are used up.
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

- **Deliver to**: the address, in five boxes: the number and street, the apartment or unit, the city, the
  state and the ZIP ([The address in its parts](#the-address-in-its-parts)). The order cannot start
  without one, and the state by itself is none.
- **Note for the driver**: whatever helps at the door ("ring twice, side door"). It can be left empty.

The phone number is the one the driver calls from the door, and the form says so. It is not required, but
ask for it.

**The quote is Delivery's.** The form says "There in about 45 min" in place of "Ready in about 20 min":
the minutes are the ones set for Delivery under the quote times (Location › Quote times), whoever took the
order, and they are meant for the cooking and the drive together. A rush and a big order add their minutes
as on any quote. For an order **for later**, the time the customer named is the time at their door, and the
kitchen starts that many minutes before it. (With [live traffic](#live-traffic) turned on, a delivery for
now is promised the kitchen's minutes and the drive to that address as it is right then, in place of the
45.)

### The address in its parts

The address is typed in five boxes (the owner's words, 2026-11-26: break the address up into its core
fields, and the list of addresses fills all of them):

| Box | What goes in it |
| --- | --- |
| **Deliver to** | The number and the street: "12 Elm St". The [list of addresses](#a-list-of-addresses-while-typing) drops down from this one, over the boxes under it. |
| **Apt / unit** | The apartment, unit, suite or floor: "3B", "Apt 3B", "Ste 200". Empty for a house. |
| **City** | The town. |
| **State** | One of the fifty states by its two letters, off a list. It starts on the restaurant's own state (read off the restaurant's address under Location › **Delivery fee**), since nearly every delivery stays in it. Tap the box for the list, or type: [The State box](#the-state-box). |
| **ZIP** | Five digits, or nine with a dash. |

- **Where they stand.** On a phone the street has a line to itself, the unit and the city share the next,
  and the state and the ZIP the third. On a tablet or a Mac the unit stands beside the street and the
  city, the state and the ZIP share the second line. Large type takes the lines it needs, and the unit's
  box is named "Apt" where "Apt / unit" does not fit.
- **A tap on a line of the list fills every box**, and none keeps what it held before
  ([A list of addresses while typing](#a-list-of-addresses-while-typing)). Where the hub looks distances
  up, the tap also picks the delivery fee for how far that address is
  ([Looking the distance up](#looking-the-distance-up)).
- **Enter goes to the next box** (Next on a phone's keyboard). Once the street has its city or its ZIP,
  Enter also has the distance looked up, where the hub looks distances up; Enter in the ZIP's box, the
  last one, does that whatever is typed.
- **A whole address typed in the first box still works.** "12 Elm St, Apt 3B, Winchester, MA 01890", typed
  with its commas as it used to be, goes to its boxes when that box is left.
- **The order carries one line, as it always did**: "12 Elm St #3B, Winchester, MA 01890". The bill, the
  kitchen's ticket, the bag labels, the driver's list, the delivery fee's distance, live traffic and the
  customer's card all read that line and none of them changed. A unit that is its number alone is written
  with a number sign ("#3B"); one typed with its word is written as typed ("Apt 3B").
- **An older order's address is read into the boxes** as far as its parts can be told apart: a street, a
  unit named by its word or a number sign, a city, a state, a ZIP. What cannot be told apart stays in the
  street's box as it was written, so nothing of it is lost. The address stays exactly as it was written
  until somebody changes a box: opening an order and saving it never rewrites where it goes.
- **An order from the website** comes with its address on one line from GloriaFood, and reads into the
  boxes the same way when its dialog is opened.
- **The state alone is no address.** A form with nothing but the restaurant's state in its box still asks
  for the address.
- **The restaurant's own address** (Location › Delivery fee) is still one box.

#### The State box

The State box is a list of the fifty states by their two letters (the owner's words, 2026-11-26: a list
of the 50 states' two-letter abbreviations, typing is allowed and just shows the matching states, and
the list of addresses must still fill it).

- **A tap opens the list** under the box, over what stands there, moving nothing: each line is a state's
  two letters with its name beside them. It opens on the state the box holds, which is marked. Six
  states show and the rest is a scroll away, in the list itself. A tap on a line takes that state and
  closes the list. A small arrow in the box says it is a list.
- **Typing shows the states that match.** "M" shows the eight states that begin with M; "MI" is Michigan.
  The box takes no letter that no state begins with, so what stands in it is always a state or on its
  way to one. A letter typed where a state already stands starts another: with MA in the box, N shows
  the states that begin with N. Letters can always be taken away, and an empty box lists all fifty.
- **One letter is not a state yet.** Enter (Next on a phone's keyboard) takes the first state shown,
  which is the marked one, and goes on to the ZIP. A box that is left with one letter takes the state if
  only one begins with it (D is Delaware) and otherwise goes back to what it held. One letter alone is
  never written on the order.
- **The list of addresses fills it like every other box.** A tap on a line of the
  [list of addresses](#a-list-of-addresses-while-typing) puts its state here, whichever way the map
  service says it: by its letters ("MA"), spelled out ("Massachusetts"), with the country before it
  ("US-MA"), or only in the line itself. It does so over a state that was picked by hand before. A
  state's whole name from the keyboard's own suggestion, or a paste, is taken as its two letters too.
- **With a keyboard**: the arrow down opens the list, then goes to the marked state and on from line to
  line; Enter takes the line, the arrow up goes back and from the first line into the box, Escape closes
  the list.
- **On a phone the keyboard comes with the tap.** The form brings the box up so that five states show
  over the keyboard, and never so far that the box itself is out of sight.
- **Only the fifty.** The District of Columbia and the territories are not on the list and cannot be
  typed in this box. An address that already says one ("DC" off the list of addresses, on an older
  order, from the website, or typed whole in the first box) keeps it, and it is written on the order as
  before.

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
  miles $5.00, up to 8 miles $8.50. Miles can be a fraction of a mile, as fine as a hundredth: up to 0.25
  miles, up to 0.5, up to 1.75. Minutes are whole. There can be up to eight prices, and a price can be 0
  for a free delivery close by.
- **The list sorts itself, nearest first.** A new price starts at the foot of the list. Once its distance
  is typed and you move on (to another row, to **Add a price**, or the keyboard is put away), the row goes
  to its place by distance, and so does a row whose distance you change. Nothing moves while you are still
  typing in a row. The hub keeps the prices nearest first as well, so the buttons on a delivery are always
  in that order.
- **Custom fee past the last distance**: on to start. A delivery that goes further than your last price
  reaches is then charged what whoever takes the order types
  ([A custom fee for a delivery further away](#a-custom-fee-for-a-delivery-further-away)). Turn it off and
  a delivery costs one of the listed prices or nothing, as before.
- **Charge sales tax on the fee**: off to start. Whether a delivery fee is taxed is for your accountant
  to say. (Massachusetts leaves a delivery charge out of the sales tax when it is stated on its own on the
  bill and is a fair price for the trip, DOR Directive 04-5; that directive does not speak of meals, so
  ask. Nothing here is tax advice.)

The row under Location says what is set: "$3.00 up to 2 mi, $5.00 up to 4.5 mi, $8.50 up to 8 mi, custom
fee further out".

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
  price costs. The one amount anybody types is a
  [custom fee](#a-custom-fee-for-a-delivery-further-away), for a delivery further than the prices reach.
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

The price is tapped by hand unless the hub looks the distance up, which is the section after the next two.

### More than four prices

Up to four prices are a button each, as above. **With five or more, the prices are one line** (the owner's
words, 2026-11-27: "delivery fees with lots of options (over 4) change it something that fit better on the
screen than a bunch of buttons (maybe like a slider or something better)"):

- The line says the fee that is picked, "$5.00 · Up to 4 mi", or "Pick the fee" while nobody has. It
  takes one line of the form whatever the number of prices; eight prices as buttons took five rows on a
  phone.
- **A tap on the line opens the whole list**, up from the bottom of the screen: each price on a line of its
  own, how far it reaches on the left and what it costs on the right, nearest first, with a tick on the
  one that is picked. Where the hub looked the distance up, the list says it under its heading ("3.24 mi ·
  9 min drive"), so the right line is easy to find.
- **A tap on a line picks it** and puts the list away. A tap beside the list puts it away with nothing
  changed. The custom fee and **No fee** are its last two lines.
- Where the hub looks the distance up, the line is filled in by itself and is mostly something to read:
  the list is for the times somebody knows better than the map.
- The custom fee is not counted among the four, nor is No fee: four prices with both are six buttons, which
  is the three rows on a phone that four prices and No fee always were.

Why a list and not a slider: a slider has no place for "nobody picked yet", for No fee or for the custom
fee; it shows one price at a time, so the others have to be found by dragging; and a thumb that only meant
to scroll the form moves it. The list shows every price with its distance at once and takes a tap.

### A custom fee for a delivery further away

Your prices end somewhere: "up to 8 miles, $8.50". An address past that has no price on the list. **With
the custom fee on, whoever takes the order types what that delivery costs** (the owner's words, 2026-11-27:
"Allow custom delivery fee for distance more than the max delivery fee distance in the delivery fee
settings").

- **It is one more choice, after the prices**: a button "Custom fee, Past 8 mi", or the line "Custom fee ·
  past 8 mi" of a long list. Tap it and a box, **Custom fee**, opens under the choices with the keyboard
  in it. Type the dollars and cents ("12" or "12.50"). Once it is an amount, the button is headed by it
  like a price: "$12.50, Past 8 mi".
- **The order cannot start on half of one.** Until an amount is typed the form says "Type the delivery
  fee." and Start waits. Nothing, zero and "12.345" are no amount, and the box says so; the most is
  $999.99. For no charge at all, tap **No fee**: that is what it is for.
- **Where the hub looks the distance up, a far address asks for it by itself.** "9.3 mi · 21 min drive:
  further than the prices reach", the custom fee is picked, and the box waits for the amount. The keyboard
  is not moved there for you, since the answer may come while you are typing the note. Typing the amount
  is not "a price tapped by hand": if the address turns out wrong and a nearer one is typed, that one gets
  its own price.
- **It can be tapped for any delivery**, also one the map found within the prices (the bridge is closed
  and it is the long way round tonight), and with no map service at all, where only whoever takes the
  order knows how far it is. The hub does not check the distance: anybody who takes orders may already
  pick any price, or No fee.
- **Tap a price after all and the box goes away**; tap the custom fee again and what was typed is still
  there.
- **On the order** (**Pickup or delivery**) it is the same choice, with the amount it was given in the box.
  Type another amount and Save sends it; the same amount is no change.
- **It is a delivery fee like any other**: the same line of the check and of the bill, "Delivery fee", in
  the sales under **Charges**, taxed or not as the switch under Location says, charged only while the
  order is a delivery.
- **The history says who typed it**: "Delivery fee $12.50. Custom fee. The map said 9.3 mi · 21 min. It
  was $8.50 · up to 8 mi", with the name and the screen.
- **Turned off under Location**, the choice is gone from every form and the hub refuses a typed amount. An
  order that was given one before keeps it, shown "as taken" until another is picked.

## Looking the distance up

With a map service set up on the hub, nobody has to know how far an address is. The form asks the hub, the
hub asks the map service, and the price for that distance is picked. **Nothing is looked up until the hub
has a key for the map service and the restaurant's own address is typed in** (see
[Setting it up](#setting-it-up)). Until then the price is tapped by hand, as above.

### On the form

- Tap **Delivery**, type the address in its boxes, and press Enter (Done on a phone's keyboard) in the
  ZIP's box, or go on to the note or anything else on the form. Enter in an earlier box asks too, once
  the street has its city or its ZIP. A line over the prices says "Looking up how far it is…", then what the map said: **3.2 mi · 9 min
  drive**. The price that distance falls in is picked: with $3.00 up to 2 mi and $5.00 up to 4.5 mi, 3.2
  miles is $5.00. A distance right at a price's reach is that price (4.5 miles is "up to 4.5 mi"). Until
  the address has been asked about, the line is a button, **Look up the distance**, that asks.
- **A returning customer's address** is asked about as soon as the order is a delivery, without a tap.
  Where they had a delivery brought there before, the map service is not asked at all (see
  [Customers who order again](#customers-who-order-again)).
- **An address chosen off the list picks its price** (the owner's words, 2026-11-26: when an address is
  selected, the delivery fee for its distance is selected by itself). A tap on a line of the
  [list of addresses](#a-list-of-addresses-while-typing) fills the boxes, asks how far it is, and picks
  the price that distance falls in, without Enter and without another tap. It does so even after a price
  was tapped by hand for whatever stood in the boxes before: another address is another distance.
- **Any other price can still be tapped**, and No fee too. **A price tapped by hand stays** for the
  address it was tapped for. From that tap on the map only says how far: it does not move the price when
  its answer comes late, nor when the address is typed over or a box of it is changed. Nobody's "No fee"
  turns into a charge by itself. Only another address chosen off the list is priced anew, as above.
- **Too far**: "9.3 mi · 21 min drive: further than the prices reach". With the
  [custom fee](#a-custom-fee-for-a-delivery-further-away) on, it is picked and the form asks for the
  amount: "Type the delivery fee." With it off, nothing is picked: whoever takes the order decides (the
  last price, No fee, or no delivery that far), and the order cannot start until a price is tapped.
- **No answer**: the line says why and ends "Pick the fee by hand.", over a **Try again** button. The
  address could not be found (check the spelling, add the town); the map service is not answering, which
  is also what a restaurant without internet sees; the map service refused the hub's key; or it has been
  asked as often as it may be today. An order is never held up by the map: tap a price. (Where the hub has
  more than one map service, the others have been asked too by then:
  [Which service is asked first](#which-service-is-asked-first).)
- **An address is asked about once**, when it is done being typed, never letter by letter, and not by a
  form that is being closed. The same address again, on this order or the next, is answered by the hub from
  what it was told that day.
- **Only where there is a price to pick.** With the fee turned off, or on a pickup, nothing is asked.

On the order (**Pickup or delivery**) it is the same line. Opening it asks nothing, and the order keeps the
fee it has. Type another address and that one is looked up and its price picked (unless a price was tapped
there first); choose one off the list and its price is picked whatever was tapped before; or tap **Look up
the distance** to ask about the address as it stands. A fee the website charged is the one exception: the
customer was told it and may have paid it, so no address moves it, typed or chosen. The line says how far
the new address is, and a tap picks another price.

The lookup gives both the miles and the minutes whichever the fee goes by, and the price is picked by the
one the fee goes by. Miles are along the road, to a hundredth of a mile, as fine as a price can be listed:
with prices a quarter of a mile apart, an address 0.25 miles away is "up to 0.25" and one 0.26 miles away
is the next price. A distance with nothing in the hundredths reads the short way, "3.2 mi". Minutes are the
usual drive, to the nearest minute: the map service does not know about tonight's traffic.

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

### A second map service

The hub can have a second map service, **Google Maps**, which it asks **only when the first gives no
distance**: a street Geocodio does not know yet, Geocodio not answering, its key refused, or its day's 500
used up. Google is then asked about the same address before the form is told anything. Nobody at the form
does anything for it, and nothing changes until Google's key is on the hub
([Setting it up](#google-maps-as-the-second-service)).

- **The form reads the same, with the words Google Maps beside the figures**: "1.6 mi · 5 min drive" and,
  after it or under it, "Google Maps". Google's rules ask for its name wherever its figures are shown, in
  those words, on one line, in plain type. That is all the words are: nothing opens when they are tapped.
- **The price is picked the same way**, at the prices as they are, and a price tapped by hand still stays.
- **Google's figures are not kept.** Google's terms do not let its distances and drive times be stored. So
  what Google said picks the price on that form and is gone. The fee is on the order, as always; the miles
  and the minutes are not. The check's history says the fee and who picked it, without "The map said". The
  hub does not remember the answer for the day. And the customer is not "as last time" on their next
  order: that address is looked up again, by Geocodio first.
- **When neither gives a distance** the form says so as before: that the address could not be found when
  either of them said that (it is the one thing somebody at the form can do something about), and
  otherwise what the first one said.
- **At most 100 times a day** is Google asked (`POS_MAPS_GOOGLE_DAILY` in `/opt/pos/.env`), whatever goes
  wrong with the first service. Past that the form is told what the first one said.
- **Each service is waited for 4 seconds at most**, so with both the form hears back inside 8.
- **With Google's key alone on the hub**, Google is the one service. It works, and every delivery is then
  looked up each time, a returning customer's too, because nothing of Google's is kept.
- **Which is first is a setting** since 2026-11-25, and Mapbox and Azure Maps can be asked as well:
  [Which service is asked first](#which-service-is-asked-first). Until somebody changes it, it is
  Geocodio where it has a key, then Google.

### Live traffic

With Google Maps on the hub and **Live traffic** turned on under Location, a delivery that is **for now**
is promised by the roads as they are: **the minutes the kitchen needs, and the drive to that address at
this minute**. That takes the place of the one figure set for Delivery under Quote times, which is the
same 45 minutes for every address at every hour. It is **off until a manager turns it on**
([Turning live traffic on](#turning-live-traffic-on)).

Mapbox and Azure Maps know the roads too, and can be asked before Google or behind it
([Which service is asked first](#which-service-is-asked-first)). What follows says Google, which is the one
asked until somebody changes that.

- **On the form.** Tap **Delivery** and type the address, as always. Under what the map said of the
  distance there is a second line, **With traffic now: 14 min**, with the words Google Maps beside it. The
  line by the For later switch then reads "There in about 39 min, with traffic": 25 for the kitchen and 14
  on the road. Until the address is typed and answered it says the minutes set for Delivery.
- **The fee does not go by it.** The price is picked by the distance, or by the usual drive where the
  prices go by minutes: "3.2 mi · 9 min drive" picks the same price on a Friday at six as on a Tuesday at
  three. Traffic changes when the food is promised and never what the delivery costs.
- **The order keeps the promise and not the drive.** The time promised is on the order as always. The 14
  minutes are written nowhere: not on the order, not in its history, not on the hub. Google's terms do not
  let them be kept, and an hour later they are wrong anyway.
- **A rush and a big order add their minutes** on top, as on any quote: "There in about 49 min, with
  traffic (busy kitchen: +10)".
- **An order for later is not asked about.** The time the customer named is the time at their door, and
  the roads at this minute say nothing of then. The kitchen starts the minutes set for Delivery before it,
  as before. A catering order likewise. (Switch For later off again and the form asks then.)
- **A returning customer is asked about too.** Their distance is theirs from last time ("as last time"),
  and the drive is new every time. So with live traffic on, Google is asked once for each delivery for now.
- **On the order.** A pickup for now that is made a delivery (Pickup or delivery) is promised the same
  way, as long as the kitchen does not have its ticket yet. A delivery whose address is changed keeps the
  time it was promised, and nobody is asked.
- **When Google cannot say** (not answering, its key refused, the day's most used up, an address it does
  not find), the next service in the order is asked, where there is one that is turned on. When nobody can
  say, the form says nothing about it and the delivery is promised the minutes set for Delivery, as with
  live traffic off. `sudo hubctl maps status` says how often that happened today.
- **The promise is made once**, when the order is taken. Nothing asks again while the food cooks, and the
  time does not move by itself when the roads get worse.
- **At most 150 times a day** is Google asked about the roads (`POS_MAPS_TRAFFIC_DAILY` in
  `/opt/pos/.env`), counted apart from the 100 a day for distances. Past that, deliveries are promised the
  minutes set for Delivery until the next day.
- **It is asked about beside the distance**, not after it, so the form waits no longer than before.
- **What it takes**: a service that knows the roads, turned on for them and with its key on the hub
  (Google Maps until somebody changes it), the restaurant's own address, and a delivery fee that is turned
  on with at least one price, because the drive is asked about together with the distance for the fee. (A
  location that charges nothing for delivery lists one price of $0.) The dialog under Location says which
  of these is missing.

### Which service is asked first

The hub can ask four map services about a delivery's drive: **Geocodio**, **Google Maps**, **Mapbox** and
**Azure Maps**. A manager puts them in the order they are asked and turns each on or off, once for **how
far a delivery goes** and once for **the drive right now** (the owner's words, 2026-11-25: "allow dragging
provider arrangements/order to determine the priority of which service is used first. Apply these concepts
to other api services like live traffic travel time look ups (also show indicators and current usage)").

- **Where.** For the distance: Back office › Location › **Delivery fee**, under "Looking the distance up".
  For the drive right now: Location › **Live traffic**, under "Who is asked about the roads". Geocodio does
  not know the roads as they are at this minute, so that list has three services and the other four.
- **A row for each service**: a handle (two short lines), its badge, its name, a line on how it stands,
  and its switch. The top row is asked first: where a row stands says when its service is asked, so no
  number is put before a name (the owner's words, 2026-11-27: "There is no need to put a number label in
  front of the service name since the order implies the priority").
- **Drag a row by its handle** to put the service earlier or later.
  **Nothing is saved before Save**, and Cancel leaves the order and the switches as they were.
- **The first one that is turned on and has a key is asked. The next one only when the one before it gives
  nothing**: it does not find the address, does not answer in time, refuses its key, or was asked as often
  as it may be today. A service that is off, or that the hub has no key for, is passed over.
- **Until somebody changes it, the hub asks as it did before**: Geocodio and then Google Maps for the
  distance, Google Maps for the roads. **Mapbox and Azure Maps are off until a manager turns them on**,
  for the distance and for the roads each by its own switch. Turning one on for the address list
  ([below](#mapbox-and-azure-maps-behind-google)) turns it on for nothing else.
- **A service without a key has its switch all the same.** Its line says "This hub has no key for it
  (Keys and connections, on this screen)", and it is asked from the day the key is there.
- **With every service turned off**, nothing is looked up and the price is tapped by hand (the Delivery
  fee dialog says "None that is turned on has a key: the price is picked by hand."). With nobody turned on
  for the roads, a delivery is promised the minutes set for Delivery, and the row under Location says "No
  map service that has a key on this hub is turned on for the roads (Live traffic, on this screen)."

**How each stands** is the line under its name, and the ring around its badge:

- **"488 of 500 lookups left today"**: what is left of the most the hub asks that service in a day, by the
  hub's own count. The ring is whole in the morning and unwinds counter-clockwise as lookups are used, like
  the ring of the address list's badge; it turns amber when a fifth is left and red when nearly none is.
- **In red, when something is wrong with it**: "Asked as often as it may be today", "Its key was refused
  the last time it was asked", "It did not answer the last time it was asked", "Its account was at its
  limit the last time it was asked". The words go away when the service answers again, and the next day.
- **The count is the hub's, not the service's.** Google, Mapbox and Azure Maps do not tell the key the hub
  has how many free lookups the account has left (their pages, 2026-11-25; Geocodio's were not read for
  it), so the hub counts what it asked itself. The service's own page is the bill.
- **The count is for one day and held in the hub's memory.** The hub's day turns at midnight by the world
  clock (UTC), which is 7 in the evening in Massachusetts in winter and 8 in summer. A restart of the hub
  (`sudo hubctl update` is one) starts the day's count again.

**On a delivery's form** the badge of the service that answered stands before its figures: a tiny circle
with the service's letter (Ge, G, M or A) and the same ring. A tap on it (or the mouse over it) says it in
words: "Geocodio: 488 of 500 lookups left today". With live traffic on, the distance and the drive right
now each have a line of their own with their own badge, one under the other, so the badges stand at the
same place whatever the figures say and however long they are. Where one service gave both, its name
stands once, with the second line. Google's name and "© Mapbox © OpenStreetMap" stand with their figures
as their rules ask, as before.

**The most each is asked in a day**, unless a number in `/opt/pos/.env` says otherwise:

| Service | How far, a day | The drive right now, a day | In `/opt/pos/.env` |
| --- | --- | --- | --- |
| Geocodio | 500 | (does not know the roads right now) | `POS_MAPS_DAILY` |
| Google Maps | 100 | 150 | `POS_MAPS_GOOGLE_DAILY`, `POS_MAPS_TRAFFIC_DAILY` |
| Mapbox | 500 | 500 | `POS_MAPS_MAPBOX_ROUTES_DAILY`, `POS_MAPS_MAPBOX_TRAFFIC_DAILY` |
| Azure Maps | 15 | 15 | `POS_MAPS_AZURE_ROUTES_DAILY`, `POS_MAPS_AZURE_TRAFFIC_DAILY` |

**Mapbox and Azure Maps are asked in two steps.** Geocodio and Google are asked the drive between two
addresses. Mapbox and Azure Maps are asked the drive between two places on the map, so each first looks up
where the delivery's address is, with its own search, and then the drive.

- **That search uses the same free lookups as the address list**: one lookup of Mapbox's month, and one
  transaction of Azure's (which the list counts as ten lookups). It is counted before it is made. When the
  month has no room for it, the service is passed over, nothing is counted against its day, and the next
  one is asked.
- **Where the restaurant itself stands is asked of Geocodio**, once in about a month, as for the address
  list's Mapbox ([What the list sends out](#what-the-list-sends-out)). On a hub where Geocodio has not said
  it, Mapbox and Azure Maps look the restaurant's address up as well: a second search each time.
- **Nothing they say is kept**, like Google's figures: not on the order, not in the hub's memory for the
  day, and not for "as last time". A customer whose distance Mapbox or Azure Maps gave is looked up again
  the next time. Their pages on routes say nothing that lets a figure be kept (read 2026-11-25).
- **The form waits no longer than before.** For the distance each service is waited for 4 seconds, and all
  of them together for 8: once those are over nobody else is asked. A service that refuses or does not
  find the address says so at once, so the ones after it still have their turn. For the drive right now
  all of them together have the 4 seconds the one service had, and each but the last 2 of them at most.

**What Mapbox and Azure Maps cost here.** What their own pages said on 2026-11-25; the pages are theirs to
change.

- **Mapbox**, Directions API: up to 100,000 requests a month are free, then $2.00 for each 1,000
  (<https://www.mapbox.com/pricing>). The page has no line of its own for routes with traffic. The hub
  asks at most 500 a day for the distance and 500 for the roads, about 31,000 a month.
- **Azure Maps**, Routing: 1,000 transactions a month are free, one request is one transaction, and the
  price past that was not shown as a number on the page (<https://azure.microsoft.com/pricing/details/azure-maps/>).
  The hub asks at most 15 a day for the distance and 15 for the roads, 930 in a month of 31 days. That is
  few: Azure Maps is a last one to fall back on, not one to put first on a busy night.
- **Their rules** are the ones the address list has ([Their rules](#their-rules)): read their terms before
  turning one on.

The hub's side for Mapbox and Azure Maps was written from their own pages and **has not been tried against
either service**: the cloud this was built in may not reach them, and there was no key. `sudo hubctl maps
test mapbox "12 Elm St, Winchester, MA"` (or `azure`) is the first real try
([Mapbox and Azure Maps for the drive](#mapbox-and-azure-maps-for-the-drive)).

### What leaves the building

- **The two addresses**: the restaurant's own and the delivery's. Nothing else: no name, no phone number,
  nothing of what was ordered.
- **The hub asks, not the screens.** The key is on the hub and nowhere else: not in an app and not in
  the database.
- **The hub writes no address down for this.** Its log names no address and no key. The answers are held in
  memory for a day, 500 at most, and a restart of the hub forgets them.
- **The miles and the minutes are kept on the customer's own order**, beside the fee that was picked with
  them, and nowhere else. That is how a returning customer is not looked up again. Geocodio's terms said on
  2026-11-18 that its results may be kept. Google's said they may not, so Google's numbers are used for the
  pick and kept nowhere: not on the order, not in the hub's memory for the day, and not in the app's list of
  what is still to be sent to the hub.
- **Google is sent the same two addresses and nothing else**, and only for an address the first service
  gave no distance for. Its key is on the hub, in `/opt/pos/.env`, and travels in a header of the request,
  never in an address a log could show.
- **With live traffic on, Google is sent the two addresses for every delivery for now**, a returning
  customer's too, and still nothing else: no name, no number, nothing of the order. What it answers is
  used for the time promised and kept nowhere.
- **Mapbox and Azure Maps, where a manager turned one on, are sent the delivery's address** (for where it
  is), then the two places on the map (for the drive), and nothing else. The restaurant's own address is
  sent to them only on a hub where Geocodio has not said where it stands. Azure's key travels in a header.
  Mapbox takes its token and the address in the address of the request, and the hub keeps those requests
  out of its log. Nothing either answers is kept.
- **The customer's phone number stays on the hub.** The form sends it with the address so the hub can
  look at that customer's earlier orders. It is never sent to the map service.
- **The map service keeps its own records.** Geocodio's pages said this on 2026-11-18: a log of requests,
  which can hold what was asked, is kept for 45 days and then deleted
  (<https://www.geocod.io/data-retention-policy>); customers' data is disclosed only where the law requires
  it or in a form that names nobody, and results may be kept (<https://www.geocod.io/terms-of-use>). Read
  both before signing up: they are the service's to change. Google keeps its own records of what it is
  asked under its own terms (<https://cloud.google.com/maps-platform/terms>) and privacy policy
  (<https://policies.google.com/privacy>); read those too before giving the hub a Google key.
- **At most 500 lookups a day** (`POS_MAPS_DAILY` in `/opt/pos/.env`), so a screen gone wrong cannot run up
  a bill. Past that the form says so and the price is tapped by hand until the next day. Google has its own
  most for a day, 100 (`POS_MAPS_GOOGLE_DAILY`).

### Setting it up

The first map service is **Geocodio** (<https://www.geocod.io>), which knows addresses in the United
States and Canada. The account is the owner's to make: nothing here makes one. A second service, Google
Maps, can be added after it ([below](#google-maps-as-the-second-service)).

1. **Make an account** at <https://dash.geocod.io>. On 2026-11-18 its pages said the first 2,500 credits
   of each day are free and no card is asked for under that. A new address costs 4 credits (2 for the
   drive, 1 for each of the two addresses), so about 600 new addresses a day are free, and the hub stops at
   500 by itself.
2. **Make a key** at <https://dash.geocod.io/apikey> and **turn on its Distance permission** there. A new
   key can only find addresses until that is on, and the form would say the map service refused the key.
3. **Give the key to the hub.** In the app: Location › **Keys and connections** › Map service (Geocodio) ›
   **Type the key**, paste it, Save. The hub uses it at once (`hub-keys.md`). Or in the hub's terminal, as
   before: `sudo hubctl maps key`, and paste the key when asked. It is not shown as it is pasted and is
   never part of a command, so it is in no command history. The hub keeps it in `/opt/pos/.env` and
   restarts its API (a few seconds).
4. **Type the restaurant's own address** in the app: Back office › Location › **Delivery fee** ›
   **Restaurant address**, in full, with the town and the state. Save. The row under Location then ends
   "· distance looked up".
5. **Try it**: **Try it** on the key's card in the app asks the service how far an address is. In the
   terminal, `sudo hubctl maps test "12 Elm St, Winchester, MA"` answers like "3.2 mi, 9 min: $5.00 (up
   to 4.5 miles)", or says why not in the form's own words. When every address "could not be found", the one
   to check is the restaurant's own.

`sudo hubctl maps status` lists the services in the order they are asked, each on a line of its own:

```
how far a delivery goes, in the order the services are asked:
  1. Geocodio: on; asked 12 times today (at most 500, 488 left), 1 gave no distance (last: not_found)
  2. Google Maps: on; asked 3 times today (at most 100, 97 left), 0 gave no distance
  3. Mapbox: off (in the app: Location, Delivery fee)
  4. Azure Maps: no key on the hub (in the app: Location, Keys and connections)
```

Under them it says the same of the drive right now, then how often nobody had to be asked because a
customer's own earlier order said how far, and whether the restaurant's address is set. `sudo hubctl maps
forget` takes Geocodio's key off the hub: the next service in the order is asked first, and with no other
key nothing is looked up and the price is tapped by hand again. (The key itself is deleted on the service's
own page.)

Until the hub has a key, the dialog under Location says "This hub has no map service yet, so the price is
picked by hand (Keys and connections, on this screen)." The address can be typed all the same, and is used
from the day the hub has one.

#### Google Maps as the second service

Do this after the steps above, and **after the app was rebuilt on every device**: an app from before this
shows Google's figures without the words "Google Maps", which Google's rules ask for.

The Google account is the owner's to make, and so is the card Google asks for. What follows is what
Google's own pages said on 2026-11-18 and 2026-11-19 (<https://developers.google.com/maps/documentation/routes/get-api-key>,
<https://developers.google.com/maps/billing-and-pricing/pricing>); the pages are Google's to change.

1. **Sign in to the Google Cloud console** (<https://console.cloud.google.com>) and make a project for the
   restaurant, or pick one.
2. **Turn billing on for that project** (the console's Billing page, **Manage billing accounts**). Google
   wants a card on file before the Routes API can be used at all, also for the part that is free.
3. **Turn on the Routes API** for the project: find "Routes API" in the console and press **Enable**. It
   is the only Google service the hub calls.
4. **Make a key**: **Google Maps Platform › Keys & Credentials › Create credentials › API key**. Under
   **API restrictions** choose to restrict the key and leave only **Routes API** ticked, so the key is good
   for nothing else. Google's page warns that the owner pays for what anybody does with an unrestricted
   key.
5. **Give the key to the hub**: in the app, Location › **Keys and connections** › Google Maps › **Type the
   key** (`hub-keys.md`). Or in the terminal: `sudo hubctl maps google`, and paste the key when asked. Like
   the first key it is not shown, is never part of a command, and is kept in `/opt/pos/.env`. The hub
   restarts its API (a few seconds).
6. **Try it**: `sudo hubctl maps test google "12 Elm St, Winchester, MA"` asks Google alone and answers
   like "3.3 mi, 10 min: $5.00 (up to 4.5 miles) [Google Maps]", or says why not. (`sudo hubctl maps test
   "..."` without the word google asks as a form does, the first service and then Google, and ends with the
   name of the one that answered.)

**What it costs.** Google's price list said on 2026-11-18 that the first 10,000 plain route lookups of a
month are free and each 1,000 after that are $5. The hub asks Google at most 100 times a day, about 3,100
a month, and only for addresses the first service gave nothing for. A day's limit can also be set on
Google's side (**Google Maps Platform › Quotas**), which holds whatever the hub does.

**Google's other rule.** Google's rules for this service
(<https://developers.google.com/maps/documentation/routes/policies>) also say that whoever uses it has terms
of use and a privacy policy the public can read, which say that Google Maps is used and point to Google's
own. Whether and how that applies to a restaurant asking how far its deliveries go is the owner's to
settle, with a lawyer where in doubt. Nothing here is legal advice.

`sudo hubctl maps forget google` takes Google's key off the hub, and the hub is back to the one service.
(The key itself is deleted in the Google Cloud console.) `sudo hubctl maps forget` alone takes the first
service's key off and leaves Google's: Google is then asked about every address.

The dialog under Location lists both once the hub has both, as rows in the order they are asked
([Which service is asked first](#which-service-is-asked-first)).

The hub's side was written from Google's pages and has not been tried against Google itself: the first
`sudo hubctl maps test google` on the hub is the first real try. If it reads oddly, its words say why.

#### Turning live traffic on

Do this once Google's key is on the hub (the steps above) and the app was rebuilt on every device. There is
no new key and nothing new to turn on at Google: it is the same Routes API, asked in its other way.

1. In the app: Back office › Location › **Live traffic**. (The row is right under Delivery fee.)
2. Turn on **Promise a delivery by the roads right now**.
3. Set **Before the drive**: the minutes for the cooking, and getting the order out of the door. It
   starts at 25. It is not the 45 set for Delivery: those had the drive in them, and these do not.
4. **Save.** The row then reads "On: a delivery for now is promised 25 min and the drive as the roads
   are". If something is still missing it says what: no key on the hub for a service that knows the roads,
   none of them turned on, no restaurant address, or no delivery fee with prices.
5. **Try it** on the hub: `sudo hubctl maps test "12 Elm St, Winchester, MA"` (without the word google)
   answers like "3.2 mi, 9 min: $5.00 (up to 4.5 miles) [geocodio]; the drive right now: 14 min [Google
   Maps]". Each try is one of the day's 150.

The dialog also lists **Who is asked about the roads**: Google Maps, Mapbox and Azure Maps as rows, to
drag into order and to turn on or off ([Which service is asked first](#which-service-is-asked-first)).

`sudo hubctl maps status` has lines for it: "live traffic for the promised time: on; the drive right now,
in the order the services are asked:" and under it "1. Google Maps: on; asked 12 times today (at most 150,
138 left), 1 gave no answer".

Turning it off is the same switch. Deliveries are then promised the minutes set for Delivery again, and
orders already taken keep the time they were promised either way.

**What it costs.** Google counts a route with traffic at a dearer price than a plain one. Its price list
said on 2026-11-18 that the first 5,000 of a month are free and each 1,000 after that are $10. The hub
asks at most 150 times a day, about 4,650 a month, which stays inside the free 5,000. A restaurant with
more deliveries than that in a day raises `POS_MAPS_TRAFFIC_DAILY` in `/opt/pos/.env` and pays Google for
what goes over. A day's limit set on Google's side (**Google Maps Platform › Quotas**) holds whatever the
hub does.

Like the rest of the hub's side for Google, this was written from Google's pages and has not been tried
against Google itself. The first `sudo hubctl maps test "..."` with live traffic on is the first real try.

#### Mapbox and Azure Maps for the drive

Do this after the hub was updated and the app was rebuilt on every device. There is no new key: the hub
asks with the key each service already has for the address list.

1. **The key**, where the hub has none yet: Location › **Keys and connections** › **Mapbox** (or **Azure
   Maps**) › **Type the key** ([the accounts and the steps](#mapbox-and-azure-maps-behind-google)). A key
   that already serves the address list is the one used here.
2. **Try it on the hub**, before anything is turned on: `sudo hubctl maps test mapbox "12 Elm St,
   Winchester, MA"` (or `azure`) asks that one service alone, whether it is turned on or not, and answers
   like "3.4 mi, 11 min: $5.00 (up to 4.5 miles) [© Mapbox © OpenStreetMap]", or says why not. Where it
   says the service refused the hub's key, the key is not allowed this kind of request: for Mapbox, a
   public token without restrictions from its **Tokens** page; for Azure Maps, the account's Primary Key.
3. **For the distance**: Location › **Delivery fee**. Turn the service's switch on, drag it by its handle
   to where it should stand, **Save**.
4. **For the drive right now**: Location › **Live traffic**, the same under "Who is asked about the roads",
   **Save**.

Turning one off is the same switch. `sudo hubctl maps test "..."` without a service's name asks as a form
does, in the order as it is saved, and ends with the name of the one that answered.

## A list of addresses while typing

Wherever the app asks for a street address, a list drops down under the box while somebody types: what the
letters typed so far could become. **A tap fills the address in.** It is under **Deliver to**, the
street's box, on the to-go form and on an order's own dialog (a catering order's too), and under
**Restaurant address** in Location › Delivery fee.

- **The list lies over the form and moves nothing** (the owner's words, 2026-11-26: the list should not
  push the other fields down, it should drop down over them). It hangs from the box like a menu, as wide
  as the box and what stands beside it, with a shadow under it. The boxes and buttons it covers stay
  where they are and are back the moment it closes.

- **A tap fills every box of the address**: the street, the unit, the city, the state and the ZIP
  ([The address in its parts](#the-address-in-its-parts)). A box the line has nothing for is emptied, so
  nothing of another address is left standing. One of your own earlier deliveries is read into the boxes
  as it was written. Mapbox and Azure Maps say each part with their line; the state goes into its box as
  two letters whichever way a service says it ([The State box](#the-state-box)). **Google's list names no ZIP**,
  so the hub asks Google once more about the one line that was tapped and the ZIP is in its box a moment
  later; if Google does not answer, the boxes keep what the line said and the ZIP is typed by hand.

- **Your own deliveries come first.** The addresses the restaurant delivered to in the past year, read off
  its own orders. That costs nothing and asks nobody outside the building.
- **The customer's own lead the list.** With their number on the form, the addresses they had deliveries
  brought to before stand at the top, with a small person on a pin before each. Another customer's address
  has a clock arrow before it and is listed as an address and nothing else: no name, no number.
- **A map service comes after them, where a manager turned that on**
  ([Turning Google on for the list](#turning-google-on-for-the-list)). It is for an address the restaurant
  never delivered to. Its lines have a pin before them, the street in bold and the town beside it.
- **Google Maps is asked first; Mapbox and Azure Maps take over** once Google's free lookups for the month
  are used up, or while Google is not answering, each where it has a key and is turned on
  ([Mapbox and Azure Maps behind Google](#mapbox-and-azure-maps-behind-google)). One service answers a
  list, never two.
- **The order is yours to change.** Under Location › **Address list** each service has a handle (two
  short lines) before its badge. Drag one by it to put the service earlier or later, and **Save**: the
  first one in the list that is turned on and has a key is the one asked first, and the others take over
  in the order they stand in. Mapbox gives away ten times what Google does each month, so a restaurant
  that wants to keep Google's for something else puts Mapbox first.
- **Who answered stands at the top of the list**: a tiny round badge with the service's letter (G, M or A)
  and a ring around it for how much of that service's free lookups are left this month, and its name
  beside it ("Google Maps", "© Mapbox © OpenStreetMap", "Azure Maps"). The ring is whole at the start of a
  month and unwinds counter-clockwise to twelve o'clock as lookups are used, like a table's countdown on
  the floor plan; it turns amber when a fifth is left and red when nearly none is. A tap on the badge (or
  the mouse over it) says it in words: "Mapbox: 94,988 of 95,000 free lookups left this month". The badge
  stands under the box, in the column of the lines' little pictures, so it does not move while the list
  and its addresses change, and it stays there while a long list's lines scroll under it.
- **The list comes once the typing pauses**, about a third of a second: from the second letter for your
  own deliveries, from the fourth for a map service. Six lines at most. When a map service adds its own,
  three of yours stand above them.
- **What is near the restaurant comes first.** A map service's addresses within four miles of the
  restaurant come before the ones further out (the owner's words, 2026-11-25: deliveries go four miles as a
  rule, further for a big order). It is a preference and no wall: an address further out is still listed
  when the letters fit it. **Location › Address list › Nearby first** is a slider that sets another distance,
  from a quarter of a mile to 20 miles, in finer steps up close. It needs the restaurant's own address
  (Location › **Delivery fee**); the dialog says so in red
  where that is not set. Google takes the distance as a circle. Mapbox and Azure Maps take the place alone
  and put what is nearest to it first. Your own earlier deliveries stand above all of them either way.
- **How the letters are read.** Every word typed in full has to be a word of the address, and the word
  still being typed has to begin one. "12 el" lists 12 Elm St and not 120 Elmwood Ave. "elm" lists every
  Elm Street the restaurant went to, whatever the number. An address that begins with what was typed comes
  before one that has it further on, and of two like that the newer delivery comes first.
- **Nothing is put in the box by itself.** What was typed stands until somebody taps a line. **Enter**
  (Next on a phone's keyboard) closes the list, takes no line, and goes on to the next box.
- **A tap is the address done.** Its parts are in the boxes, the list closes, the keyboard stays in the
  street's box, and where the hub looks distances up, how far it is is asked at once and the delivery fee
  for that distance is picked, also over a price tapped earlier
  ([On the form](#on-the-form)). For one of Google's lines that is once the ZIP has come, so the whole
  address is asked about, one time.
- **With a keyboard**: the arrow down goes into the list and on from line to line, Enter takes the line
  the focus is on, the arrow up goes back a line and from the top line into the box, and Escape closes the
  list and leaves what was typed. A list longer than its room scrolls along with the arrows.
- **The list goes when the box is left, and at a touch on anything else.** A tap beside the list, or on
  what shows around it, puts the list away and leaves what was typed; the next tap reaches what it lay
  over. An address the form filled in by itself, such as a returning customer's last one, is not asked
  about.
- **The box stays in sight, and the list takes the room under it.** Where there is less room under the box
  than the list has lines for (a phone with its keyboard up), the form brings the box up by as much as is
  missing, at most to the top. If that is still not enough, the list is as tall as the room and its lines
  scroll inside it, under the name of the service that answered. Nothing of it is ever under the keyboard
  or off the bottom of the screen.
- **The list goes with its box.** When the form is scrolled the list moves along, and while the box is
  scrolled out of sight its list is not shown; it is back when the box is.
- **A list is a help and no more.** When the hub or the map services do not answer there is no list and
  no word about it, and the address is typed in full as before. A list never holds a form up, and never makes a
  screen turn away from its hub.
- **No map service is asked** about fewer than four letters, about a number alone ("12"), or about an
  address the restaurant already has in full.
- **The restaurant's own address** lists a map service's answers alone, where one is on. No customer's address
  is offered for it.
- **A delivery taken now is on the list about a minute later**, for the next customer in the same street.
- **An address that was tapped is the customer's address**, typed with fewer letters. It goes on the order
  like one typed in full, and nothing says it came off a list.

### What the list sends out

- **With every map service off, nothing.** The list is made on the hub from the restaurant's own orders.
- **With one on, the letters typed in an address box**, from the fourth letter, each time the typing
  pauses, to the one service whose turn it is. Nothing else: no name, no phone number, nothing of an order.
- **A tap on one of Google's lines sends Google its own name for that place**, a code Google gave with
  the line, and Google answers with the address's parts. Nothing else goes with it. A tap on any other
  line sends nothing.
- **The customer's phone number stays on the hub.** The form sends it with the letters so the hub can put
  that customer's own addresses first. It is never sent to a map service.
- **The restaurant's own address, once, to Google and to Azure Maps**, so that streets nearby come first.
  Each answers where that is, and the hub keeps it in memory for under thirty days and writes it nowhere.
  (Until then Google goes by where the hub's internet connection is, and Azure Maps by the whole country.)
- **Where the restaurant is, to Mapbox**, as a place on the map. Mapbox is never asked where the
  restaurant's address is, because its terms let none of its answers be kept. The hub asks **Geocodio**
  instead, the service a delivery's distance is measured with, once in about a month: Geocodio's terms let
  an answer be kept and used with anybody's map. That is one more lookup of Geocodio's for the day, about
  the restaurant's own address, which it is sent with every distance anyway. On a hub with no Geocodio
  key, or with one that may not look an address up (Geocodio's page says only its lists and its distances
  have to be turned on for a key specially), Mapbox goes by where the hub's internet connection is, which
  can be a town or more off. `sudo hubctl maps status` says for each service whether it knows where the
  restaurant is.
- **What a service answers is shown and then gone.** The hub keeps none of it, and neither does the app.
  Their terms do not let a list be kept.
- **Keys and letters.** Google's key travels in a header and the letters in the body of the request. Azure
  Maps' key travels in a header and the letters in the address of the request; Mapbox takes both, the token
  and the letters, in the address of the request alone. The hub keeps every one of those requests out of
  its log: the log names no address and no key.
- **The hub counts how often it asked each service this month**, in its database: the service's name, the
  month and a number, nothing else.
- **Anybody on the restaurant's network can ask the hub for a list**, as for a distance. The answer holds
  addresses and no names. With a phone number sent along it also says which of them were that customer's,
  like the card a form shows for a number.
- **Each service keeps its own records** of what it is asked, under its own terms: Google
  (<https://cloud.google.com/maps-platform/terms>, <https://policies.google.com/privacy>), Mapbox
  (<https://www.mapbox.com/legal/tos>, <https://www.mapbox.com/legal/privacy>) and Microsoft for Azure Maps
  (<https://www.microsoft.com/licensing/terms>, <https://privacy.microsoft.com>).

### Turning Google on for the list

Google's part is **off until a manager turns it on**, because it sends what is typed in an address box to
Google. It uses the Google key the hub already has ([Google Maps as the second
service](#google-maps-as-the-second-service)). That key has to be allowed one more of Google's services,
**Places API (New)**.

The Google account and its card are the owner's. What follows is what Google's own pages said on
2026-11-25 (<https://developers.google.com/maps/documentation/places/web-service/place-autocomplete>,
<https://developers.google.com/maps/billing-and-pricing/pricing>); the pages are Google's to change.

1. **Rebuild the app on every device first.** An app from before the list shows none, and asks nothing.
2. **In the Google Cloud console** (<https://console.cloud.google.com>), in the project the hub's key
   belongs to, find **Places API (New)** and press **Enable**. Not the older "Places API": the hub calls the
   new one.
3. **Allow the key to use it**: **Google Maps Platform › Keys & Credentials**, the hub's key, **API
   restrictions**, and tick **Places API (New)** beside Routes API. Save.
4. **Try it** in the app: Back office › Location › **Address list** › **Try it**. "Google answered: it
   lists addresses for this hub." says the key works. "Google refused the hub's key. Is Places API (New)
   turned on for it?" says step 2 or 3 is not done, or that Google needs a few more minutes. Trying asks
   Google about the restaurant's own address, never a customer's, and turns nothing on.
5. **Turn on "Google Maps"**, the top row, and **Save**. From the next letter typed, every screen lists
   Google's answers under your own.

The dialog lists the three services in the order they are asked, each with its own switch, its badge, a
line on how it stands ("Off · 9,500 of 9,500 free lookups left this month", "No key on this hub yet",
"Not answering right now: the next one is asked meanwhile") and, where the hub has its key, **Try it**.
Each also has a handle before its badge: a drag by it moves the service up or down the order, and nothing
is saved before Save (the owner's words, 2026-11-25: "dragging provider arrangements/order to determine
the priority of which service is used first"). The top row is asked first; no number is put before a name,
since the order of the rows says it. Until somebody drags them, Mapbox is the second row and Azure Maps
the third.

Under the three, **Nearby first** is how far around the restaurant a service's addresses come first: a
slider, with the distance in words beside its name ("4 miles"). Its steps are finer up close (the owner's
words, 2026-11-25): a quarter of a mile at a time up to 3 miles, half a mile up to 6, a mile up to 12, and
two miles up to 20. Every step is as wide as the next, so the first three miles take two fifths of the
slider; the numbers under it (1, 3, 6, 10, 20) show where those distances stand. It stands at four miles
until somebody moves it, and nothing is saved before Save.

The row under Location says how it stands: "Your own earlier deliveries are listed while an address is
typed", or "Your own earlier deliveries, then Google Maps, are listed while an address is typed. Mapbox and
Azure Maps take over when it gives no list". On a hub with no key for a service its switch can be turned
on all the same and is used from the day the key is there; the row then says "On, but not used yet: this
hub has no Google Maps key".

Turning one off is the same switch. With all three off, nothing typed leaves the building.

### Mapbox and Azure Maps behind Google

Google gives a set number of lookups away each month. Once those are used up, or while Google is not
answering, the hub asks **Mapbox**, and after it **Azure Maps** (the owner's words, 2026-11-25: they are a
fall back once the free Google usage is used up, or if Google is down). They stand in that order, Google,
Mapbox, Azure Maps, until somebody drags them into another. A service that is off, or that the hub has no
key for, is passed over.

- **The next one is asked only when the one before it gave no answer**: its month is used up, it did not
  answer within two seconds, it refused the key, or it said itself that it is asked too often. A service
  that answers with no address has answered, and nobody else is asked about the same letters.
- **A service that gave no answer is left alone for a while**: a minute when it did not answer, five when
  it refused the key or said it was asked too often. Somebody typing does not wait for it again at every
  letter. **Try it** asks it all the same, and an answer ends the wait.
- **All of them together are waited for no longer than three and a half seconds**, inside the four a form
  waits for the hub. Past that the list holds your own deliveries alone.
- **Mapbox's "Address Autofill"** is a kit for web pages and has no call a hub can make. The hub uses the
  call of Mapbox's that lists addresses while they are typed and that a server may make: its Geocoding API
  (version 6, with autocomplete).

The accounts and their cards are the owner's. What follows is what the services' own pages said on
2026-11-25; the pages are theirs to change. Nothing of either was tried from here: the cloud this was built
in may not reach Mapbox or Azure, and there was no key. **Try it** is the first real try.

**Mapbox:**

1. Make an account at <https://www.mapbox.com>.
2. On the account page, under **Tokens**, copy the **Default public token**. It starts with `pk.`. A token
   restricted to web addresses (URL restrictions) does not work from the hub: leave that empty, or make a
   new public token without it.
3. In the app: Location › **Keys and connections** › **Mapbox** › **Type the key**, paste it, **Save**.
   **Try it** on the card asks Mapbox about the restaurant's own address.
4. Location › **Address list** › turn on **Mapbox** › **Save**.

**Azure Maps:**

1. In the Azure portal (<https://portal.azure.com>), with an Azure account and a subscription, **Create a
   resource** › **Azure Maps** (pricing tier Gen2).
2. Open the new Maps account › **Settings › Authentication**, and copy the **Primary Key**.
3. In the app: Location › **Keys and connections** › **Azure Maps** › **Type the key**, paste it, **Save**,
   and **Try it**.
4. Location › **Address list** › turn on **Azure Maps** › **Save**.

Neither key is typed in the hub's terminal: there is no hubctl command for them. A hub's own file may hold
them all the same (`POS_MAPS_MAPBOX_KEY`, `POS_MAPS_AZURE_KEY` in `/opt/pos/.env`); a key typed in the app
wins.

`sudo hubctl maps status` has a line for each service: "the list of addresses while typing: google, on;
asked 9500 times this month (at most 9500, 0 left), 40 today, 2 gave no list (last: limit)", then "the
list of addresses while typing, when the one before it gives no list: mapbox, on; ...".

### What the list costs

Nothing, as the hub is set: it asks each service a little less often in a month than the service gives
away free, and the next one past that.

| Service | Free each month (their pages, 2026-11-25) | Past the free amount | The hub asks at most |
| --- | --- | --- | --- |
| Google Maps, Places API (New) Autocomplete | 10,000 requests | $2.83 for each 1,000 | 9,500 (`POS_MAPS_SUGGEST_MONTHLY`) |
| Mapbox, Geocoding API (temporary) | 100,000 requests | $0.75 for each 1,000 | 95,000 (`POS_MAPS_MAPBOX_MONTHLY`) |
| Azure Maps, Search (Geocode Autocomplete) | 5,000 transactions; ten lookups are one | not shown on the page when this was written: see <https://azure.microsoft.com/pricing/details/azure-maps/> | 47,500 lookups (`POS_MAPS_AZURE_MONTHLY`) |

- **Every pause in the typing is one lookup**, so one new address is often three or four.
- **A tap on one of Google's lines is one more**, for the ZIP its list leaves out. Google bills that one
  as Place Details Essentials: 10,000 free each month and $5.00 for each 1,000 past them (their page,
  2026-11-26). The hub counts it with the list's lookups, so the two together stay under 9,500 a month and
  neither goes past what Google gives away. The Places API (New) that the list needs covers it: there is
  nothing more to turn on. A tap on a line of Mapbox's or Azure's costs nothing more.
- **The hub stops a twentieth short** of each free amount: its month and a service's own do not turn at
  the same hour, and the hub counts only what it asked itself. Its month turns at midnight, Pacific time.
- **The count is kept in the hub's database**, so a hub that restarts goes on counting where it stopped,
  and two hubs count as one. Where the database does not answer, the hub counts in its memory meanwhile.
- **Finding where the restaurant stands** is two lookups of Google's and one transaction (ten lookups) of
  Azure's, once in about a month. For Mapbox it is one lookup of Geocodio's, of the 2,500 a day Geocodio
  gives away, and none of Mapbox's.
- **The numbers in `/opt/pos/.env` change what the hub asks at most** (`sudo hubctl update` puts a changed
  file in force). A restaurant that wants more raises one and pays the service for what goes over. A limit
  set on the service's own side (Google: **Google Maps Platform › Quotas**) holds whatever the hub does.
- **The badge counts what this hub asked**, not what the service's own bill says. The service's own page
  is the bill.

Until 2026-11-25 the hub asked Google at most 300 times a day (`POS_MAPS_SUGGEST_DAILY`); that number is no
longer read.

### Their rules

- **Google**: its name stands with every list that holds one of its answers, and nothing it answers is kept
  (<https://developers.google.com/maps/documentation/places/web-service/policies>). The rule about terms of
  use and a privacy policy the public can read ([above](#google-maps-as-the-second-service)) is in these
  rules too.
- **Mapbox**: "© Mapbox © OpenStreetMap" stands with its lists, and its temporary answers are not kept.
  Mapbox's pages do not say the same thing everywhere about showing its answers without a Mapbox map: one
  says they are for use with a Mapbox map, another that they may be shown in a user interface. Read
  <https://www.mapbox.com/legal/tos> or ask Mapbox before turning it on.
- **Azure Maps**: its name stands with its lists; the hub keeps only where the restaurant stands, in memory.
- **Geocodio** (where the restaurant stands, for Mapbox): its terms say its results "can be stored
  permanently without restrictions" in most cases, and its own pages that they may be used "on any map
  platform, including OpenStreetMaps, Mapbox, or Google Maps" (<https://www.geocod.io/terms-of-use>, read
  2026-11-25).
- Whether and how any of this applies is the owner's to settle, with a lawyer where in doubt. Nothing here
  is legal advice.

The hub's side was written from the services' pages and has not been tried against any of them: **Try it**
is the first real try. If it reads oddly, its words say why.

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
- The **labels of the bags** (`bag-labels.md`, **Labels** beside the total) say DELIVERY and "BAG 1 OF 2",
  and not the address: the driver counts the bags by them and reads where they go off the bill.

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

(Texts go out through the restaurant's Twilio account once a manager has typed it in the app, and only to
the hub's log until then: `texts.md`.)

A delivery is **not on the pickup board** (`pickup-board.md`): nobody stands at the shelf waiting for it.

## Drivers

### Who takes deliveries out

A delivery can be handed to anybody who holds the power **Take deliveries out**. To start, those are the
people whose role is **driver**, and, as with everything, a manager and an owner. Nobody who was on the
staff before holds anything new.

- **To add a driver**, add them to the staff with the role **Driver** (the steps are under
  [Adding a driver](#adding-a-driver) below). A driver signs in with their PIN like everybody else.
- **If your servers or hosts take deliveries out too**, hand them the power under Location › **Who may do
  what** (`roles.md`): the row is "Take deliveries out", in the group Deliveries. They are then offered
  beside the drivers.
- With the demo staff nobody is a driver, so only the manager (Mike) is offered, and the picker says where
  drivers are named.

Handing a bag out is not a power: whoever is signed in can do it, as anybody can tap Ready. Who did it is
kept in the check's history.

### Adding a driver

In the app: Orders screen › the three dots › **Location**, a manager's PIN, **Staff and PINs**, then **Add
a person**: the driver's name, the role **Driver** and a PIN of four digits that nobody else has. They
sign in with it at once, and are offered on the next delivery handed out. The whole of it is in
`staff.md`.

Good to know:

- Before 2026-11-24 the staff were one line in the hub's own file (`POS_STAFF` in `/opt/pos/.env`). A hub
  that still has the line signs those people in, each with the PIN they have, until the first change made
  in the app takes the list over as it stands. After that the line is not read, and can be deleted.
- A PIN is a secret: it is typed in the app once, kept on the hub as a salted hash, and never shown again.

### Sending one out

On the list of checks, a delivery that is **Ready** has the button **Out**. Tap it and the screen asks
**Who takes it?**, with a button for each person who delivers and what they have out right now ("2 out",
"nothing out"), so the next bag goes to whoever is free. Tap a name. The order is out with that driver,
from that minute.

- The customer is texted once that the order is **on its way**. The text says nothing of the address or of
  who brings it. (Like every text, it goes out through Twilio once the account is typed in the app, and to
  the hub's log until then: `texts.md`.) An order with no phone number gets none, and one that came back and
  leaves again gets no second text.
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
- **The State box lists the fifty states and nothing else.** No District of Columbia, no territories, no
  other country. The device's own address fill-in (a phone's saved addresses) is not asked for: the
  boxes are filled by the list of addresses under the street.
- **No map on the screen, no route, no delivery area drawn.** The lookup answers with two numbers.
- **Traffic never moves the fee.** The minutes beside the miles are the usual drive, whatever the hour,
  and they are what a price by minutes goes by. Live traffic is for the time promised alone, and only
  where a manager turned it on ([Live traffic](#live-traffic)).
- **Live traffic is asked about once, for one address.** The promise is not checked again while the food
  cooks, nothing moves it when the roads change, and a driver who takes three bags on one run is not
  planned for: each was promised as if it went alone.
- **No live traffic for an order for later or a catering order**, and none where the delivery fee is off:
  the drive is asked about together with the distance for the fee.
- **A saved distance is not checked again by itself.** It is used until somebody taps the round arrow, and
  there is no screen that lists customers' distances or clears them all. (Changing the restaurant's own
  address under Location has every customer looked up once more.)
- **"12 Elm St" is not "12 Elm Street".** Two spellings of one address are two addresses, each looked up
  once.
- **Four map services and no more**: Geocodio, Google Maps, Mapbox and Azure Maps, in the order a manager
  put them ([Which service is asked first](#which-service-is-asked-first)). Another service is a small
  piece of the hub (`pos.maps.Maps`).
- **What is left is the hub's own count for the day**, not what a service's bill says. No service is asked
  how much of its free amount is left, a restart of the hub starts the day's count again, and two hubs
  count each for itself.
- **No "Try it" button for the drive's services** in the app: `sudo hubctl maps test mapbox "..."` on the
  hub tries one.
- **Nothing of Google's, Mapbox's or Azure Maps' is kept**, so a customer whose distance one of them gave
  is looked up again the next time, and their check's history does not say what the map said.
- **Nothing looked up without the internet.** The hub needs to reach the map service. The form says so and
  the price is tapped by hand.
- **No fee by itself, and no tip.** A fee goes on a check only when somebody picked one. (The pricing
  rules have had an automatic delivery fee since discounts were built, `discounts.md`, but it is for
  orders of the type `delivery`, which no screen makes. It stays as it was, and is not this fee.)
- **No amount typed by hand but the custom fee.** A delivery costs one of the listed prices, nothing, or,
  where the location lets it, the custom fee that was typed for one further away. The custom fee has no
  least amount and is not behind a manager's PIN; nothing suggests what it should be (no price per extra
  mile), and a customer who orders again to the same far address is not offered what they paid last time.
- **No line of its own in the reports.** Delivery fees are in **Charges** with any other charge.
- **With no hub answering, the total on the screen leaves out a fee just picked** and says "Total
  (updating)". The price is on the button that was tapped; the check adds it when the hub answers.
- **The runs are on the screen only.** They are not printed, and there is no file of them.
- **No money with the driver.** Nothing counts what a driver collected at doors or owes the drawer, and
  there is no driver's fee or tip. Taking the money for a delivery is recorded as on any to-go order, by
  whoever marks it delivered.
- **The address goes nowhere else.** It is sent to the map service for the distance, alone, and only
  where the owner set that up ([What leaves the building](#what-leaves-the-building)), and the letters
  typed are sent to Google for the list where a manager turned that on
  ([What the list sends out](#what-the-list-sends-out)). No texting service, no delivery app and no other
  service is told it.
- **The list does not check an address.** A line of your own is an address somebody typed once, as they
  typed it, a misspelling included. Nothing says whether an address exists or can be delivered to.
- **No apartment or unit from the list.** Google is asked for streets and buildings. The unit is typed
  after the tap.
- **The list is for the United States**, and for nothing but street addresses: not for the lines at the
  head of the bill, and not for the network addresses in Settings.
- **No list without the hub.** With no hub answering the address is typed in full. One spelling of an
  address is one line: "12 Elm St" and "12 Elm Street" are listed as two.
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

The custom fee needs both: a hub from before it says nothing of one, so the forms offer none and the
dialog under Location shows no switch for it; an app from before it on a new hub offers none either, shows
no fee on the form of an order that carries one (the check still charges it) and leaves the switch as it
stands when it saves the prices. More than four prices as one line is the app's alone.

The fee likewise: on a hub from before the fee, the forms show no prices, and the row under Location says
"The hub has not answered about the delivery fee (an older hub: update it)". An app from before the fee on
a new hub shows the fee on the check and cannot pick one; a tap on that line does nothing there.

The address's parts likewise: an app with the five boxes on a hub from before them works, and a tap on
one of Google's lines fills the boxes with what the line says and leaves the ZIP to be typed. An app from
before the boxes on a new hub has its one box, and the address reads the same on both.

The lookup likewise: on a hub from before the lookup the forms have no line about the distance and the
dialog under Location has no box for the restaurant's address. An app from before the lookup on a new hub
picks the price by hand; saving the prices from it keeps the address the hub has.

Saved distances likewise: on a hub from before them every address is looked up, and no line says "as last
time". An app from before them on a new hub does not send the customer's number, so its deliveries are
looked up each time, and the distances it sends with a pick do not say who measured them, so the hub
leaves them off the order (the fee is kept; the history does not say what the map said). Rebuild the apps
after the hub and both stop.

The second map service likewise: a hub from before it has the one service, and `hubctl maps google` is not
a command there. An app from before it on a new hub shows Google's figures without the words "Google Maps"
and sends them back with the pick; the hub leaves them off the order all the same. So rebuild the apps
before Google's key goes on the hub.

Live traffic likewise: a hub from before it has no setting for it, and the row under Location says "The
hub has not answered about live traffic (an older hub: update it)". An app from before it on a new hub
never says a delivery is for now, so nothing is asked about the roads and its deliveries are promised the
minutes set for Delivery. Rebuild the apps after the hub, then turn it on.

The order of the map services likewise: a hub from before it asks Geocodio and then Google, and the two
dialogs under Location show their words as they were, with no rows. An app from before it on a new hub
shows the figures without a badge and cannot change the order; the hub asks in the order it has. Rebuild
the apps after the hub.

The list of addresses likewise: a hub from before it has none, an app asks it once in ten minutes and
shows a plain box, and the row under Location says "The hub has not answered about the list of addresses
(an older hub: update it)". An app from before the list on a new hub has plain boxes and asks nothing.

## For developers

The list of addresses while typing (the notes on live traffic, the second map service, the lookup and
saved distances are further down):

- `pos.addresses`: `fits(typed, address)` (each word typed whole is a word of the address, the word being
  typed begins one, and the address is more than what was typed; a trailing space or comma ends a word);
  `own_addresses(store, phone)` (that customer's newest 40 orders); `AddressBook.listed(store, now_ms=)`
  (deliveries of the last 400 days off `store.with_phone()`, the newest first, read in parts of 200
  through an `OrderMemo`, 5,000 addresses at most, rebuilt once a minute, in memory only); `known(typed,
  own, others, most=)` orders them. `Suggestion.as_json()` is `{address, main, rest, from}` with `from`
  one of `customer`, `orders`, `google`.
- `pos.addresses.Places`: Places API (New). `suggest` is `POST /v1/places:autocomplete` with `input`,
  `includedRegionCodes: ["us"]`, `languageCode: en`, `includedPrimaryTypes` (`street_address`, `premise`,
  `subpremise`, `route`; `POS_MAPS_SUGGEST_TYPES` changes them, `all` asks with none) and a `locationBias`
  circle of the setting's `near_miles` (four; in meters, 50 km at most) where the restaurant's place is
  known, never a `locationRestriction`; the key in `X-Goog-Api-Key`, the mask
  `suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat`. No session token: the
  hub never asks for a place's details after a pick, so each request is billed by itself. `locate` is one
  autocomplete for the place id and `GET /v1/places/{id}` with the mask `location`. 401 and 403 are
  `refused`, 429 `limit`, 404 `not_found`, anything else `unreachable` (`pos.maps.LookupFailed`).
- `pos.addresses.Mapbox`: Geocoding API v6, `GET /search/geocode/v6/forward` with `q`, `autocomplete=true`,
  `types=address,street`, `country=us`, `language=en`, `limit=5`, `proximity` and `access_token`. The
  state is shortened by `context.region.region_code`. 422 is `not_found` too. `locate` is never asked:
  `proximity` is `longitude,latitude` as Geocodio reads the restaurant's address
  (`Suggester.place_with(Lookups.locate)`, `pos.maps.Geocodio.locate`: `GET /v2.1/geocode?q=&limit=1`,
  `results[0].location`, one of the day's askings of the distance's service), and `ip` until that is known
  or where the hub has no Geocodio key.
- `pos.addresses.Azure`: `GET /geocode:autocomplete?api-version=2026-01-01` with `query`, `countryRegion=US`,
  `resultTypeGroups=Address`, `top=5` and `coordinates` (or `bbox` of the whole country until the place is
  known); the key in `subscription-key`. `locate` is `GET /geocode` with `top=1`, counted as ten lookups.
- `pos.addresses.Suggester`: the services in `ORDER` (google, mapbox, azure), the next only after
  `LookupFailed` that is not `not_found`; `REST` after a failure; `CHAIN_SECONDS` 3.5 in all and
  `SUGGEST_SECONDS` 2 for each. The month's most per service (`MONTHLY_MOST`, 95% of `FREE`; env
  `POS_MAPS_SUGGEST_MONTHLY`, `POS_MAPS_MAPBOX_MONTHLY`, `POS_MAPS_AZURE_MONTHLY`), counted in `Asked` /
  `PgAsked` (table `map_asked(service, month, asked)`, months by Pacific time, counted before each asking
  and taken back where the other hub filled the month meanwhile). `statuses()` for `/maps/status`
  (`suggests`, and `suggest` = the first, each with `enabled`). `POS_MAPS_GOOGLE_KEY`,
  `POS_MAPS_MAPBOX_KEY`, `POS_MAPS_AZURE_KEY` are the keys (`pos.keys` slots `maps_google`, `maps_mapbox`,
  `maps_azure`); `pos.api.keys.use_keys` hands a key typed in the app to it at once.
- The setting `address_list` (`pos.settings`): `google`, `mapbox`, `azure`, each false until a manager sets
  it, `near_miles` (0.25 to 30, to a hundredth; 4 unless set, and kept by a PUT that leaves it out) and
  `order`, the services' names in the order they are asked (`google`, `mapbox`, `azure` unless set; each
  name once, one left out comes after those named, a name of no service is refused; kept by a PUT that
  leaves it out; `pos.addresses.order_of`). The GET also says `origin_set`, whether the restaurant's own
  address is known. `GET/PUT /settings/address_list` (the PUT needs a manager; a service left out stays
  as it is) answers them with `services` in that order (each `{name, title, credit, on, key, asks, left,
  monthly_most, used_up, resting}`) and, for an older app, `service`, `asks` and `credit` of Google. An
  app shows the handles only where the answer has `order`, and sends none to a hub that has none. `POST /settings/address_list/try`
  `{service}` (a manager; Google unless named) asks that one service once about the restaurant's own
  address, or "1 Main St" where none is set: `{ok, found, reason, message, service, left}`, 409
  `no_service` with no key, 422 `bad_value` for a name that is no service's.
- `POST /addresses/suggest` `{typed, phone, own}`: `{typed, suggestions, credit, service, title, left,
  monthly_most}`. No token, like `/delivery/distance`. Own addresses always; a service only with its
  setting on, a key, four letters with a letter among them, and no known address equal to what was typed.
  With answers of a service the own lines are cut to three and the list to six. A failure of every service
  is a shorter list, never an error. `own: false` lists no delivery and sends no place. A service's line
  may carry `parts` `{street, unit, city, state, zip}` (Mapbox, Azure: `pos.addresses.Parts`, the state
  two letters, the ZIP five digits or nine) and `ref`, the service's own name for the place where its
  list has no ZIP (Google's `placeId`).
- `POST /addresses/whole` `{service, ref}`: `{parts}` or `{parts: null}`. No token. One Place Details
  (New) with the field mask `addressComponents`, for a service that is on, has a key and has more to say
  (`Lists.wholes`: Google 1, the others 0), counted in the service's month like a lookup. Every failure
  is `parts: null`, never an error (`Suggester.whole`, `Places.whole`).
- The address in its parts, app: `lib/address_parts.dart` (`AddressParts`: `parse` reads a line, `line`
  writes one, `of` reads the hub's `parts`, `stateOf` the restaurant's state);
  `lib/screens/address_fields.dart` (`AddressFields`: five boxes around the form's one `address`
  controller, which every reader of the form still reads; a line stays as written while the boxes say
  what it was read as; `_apart` tells a whole address typed in the first box into its parts);
  `AddressBox` takes `onPicked`, `onNext` and `beside` for it; `PosApi.wholeAddress` through `_aside`.
  No order, no setting and no table changed: the order's `address` is one line of at most 200 letters.
  Tests: `test/address_parts_test.dart`, `test/address_fields_test.dart`; other tests type an address
  with `enterAddress` and read it with `addressOn` (`test/delivery_test.dart`).
- The State box, app only: `lib/screens/state_box.dart` (`StateBox`: a `TextField` with the list of
  `usStates` under it, so every way of filling a text box still fills it, which a fixed dropdown would
  not; `StateBox.fits` is the formatter that takes only what a state begins with, by what was put into
  the text and not by where the cursor stands; `stateIn` is what the form's line reads, nothing for one
  letter; selection is off, so no handle or menu lies over the list). `lib/address_parts.dart`:
  `usStates` (the fifty, by their letters, with their names), `AddressParts.statesFrom` and
  `listedState`; `_stateOf` also reads "US-MA", and `AddressParts.of` a name spelled out.
  `AddressSuggestion.boxes` takes the state from the line where the parts name none. A tap on a line of
  addresses writes the boxes' controllers, which no formatter stands before, so "DC" is kept. No hub
  code, no order and no setting changed. Tests: `test/state_box_test.dart`.
- App: `lib/address_list.dart` (`AddressSuggestion`, `AddressSuggestions` with `share` and `leftWords`,
  `AddressSource`, `AddressService`, `AddressListSetting`, which reads an older hub's answer as Google alone,
  `AddressListTry`); `lib/screens/service_badge.dart` (`ServiceBadge`, at the top of the list and in the
  dialog); `PosApi.suggestAddresses` through `_aside`, which asks the hub
  the terminal talks to, waits four seconds and never changes `connection`, and leaves a hub that answered
  404 alone for ten minutes; `addressList`, `saveAddressList`, `tryAddressList`.
  `lib/screens/address_box.dart`: `AddressBox` around the text box and its list (a `Focus` around both, so
  the focus going into the list is not the box being left; a pause of 300 ms, answers for other letters
  dropped). The list is no child of the form's column: it is drawn in the screen's `Overlay` by
  `OverlayPortal.overlayChildLayoutBuilder` (`_float`, the way Flutter's own `RawAutocomplete` does it),
  moved to under the box by the box's paint transform, so it lays out nothing around it and follows the
  box through a scroll frame by frame. `_float` gives it the room down to the keyboard
  (`MediaQueryData.fromView`, since a `Dialog` hides the keyboard's inset from its children) and shows
  nothing while the box's lower edge is outside the form's `Scrollable`. Its lines scroll in `rolls`
  under the credit row; `_onKey` says which line an arrow goes to (the list overlaps other boxes, so
  where things stand on the screen cannot say it). The list is in a `TextFieldTapRegion`, so a click on
  a line is not a click away from the box, and its `onTapOutside` closes it. It is the box of
  `EventFields` (`addresses:`, handed in by the to-go form and by `WhenDialog`) and of `fee-origin` in
  `DeliveryFeeDialog`. `bringUp` scrolls the form by what the list lacks, and no further than the box
  at the top. `AddressListDialog` and the row `address-list` under Location.
- A list that drops down from a text box is `DropsList` (`lib/screens/drop_list.dart`), a mixin on the
  box's `State`: `_float`, `bringUp`, `_onKey`, `rolls` and the lines' focus live there, and `AddressBox`
  and `StateBox` both use it, each saying what its box and its list are (`buildList` on a `DropCard`,
  `listLines`, `closeList`) and building its box inside `dropUnder`. It is a mixin and not a widget
  because `OverlayPortalController.show` may not be called while the screen is built: the state shows
  and hides its list when something happens (`showList`, `hideList`). A list may be wider than its box
  (`listMinWidth`, moved left to stay on the screen), no taller than `listMost`, content with
  `listEnough` showing before the form is scrolled for it, and may take the arrow down wherever the
  cursor stands and open by it (`arrowDownIsTheLists`, `openListByArrow`). A list that opened before the
  keyboard came is given its room once the keyboard stands (`didChangeMetrics`, 200 ms after the last
  change: the text box moves itself into sight at every frame until then).
- The fee after a chosen address: `AddressFields.onChosen` (a line of the list was tapped and its parts
  are in the boxes) is `EventFields.onAddressChosen`; the to-go form's `_askDistance(chosen: true)` and
  `WhenDialog._lookUp(chosen: true)` forget `_feeByHand` before they ask, the dialog not for a fee the
  website charged. `onAddressDone` (Enter, the box left) asks as before and leaves `_feeByHand` alone.
- Tests: `backend/tests/orders/test_address_list.py` (all three services against `httpx.MockTransport`; none
  of them is ever called) and `apps/pos_app/test/address_list_test.dart`.

Which service is asked first:

- The setting `drive_lookups` (`pos.settings`, `clean_drive_lookups`): `distance` and `traffic`, each
  `{order, <name>: bool}`. `pos.maps.ORDER` (geocodio, google, mapbox, azure) and `TRAFFIC_ORDER` (google,
  mapbox, azure) are the orders unless set; `ON_UNLESS_SET` names the ones that are on until a manager
  says otherwise (the ones asked before the setting was there). `order_of`, `is_on`, `turned_on(setting,
  purpose)`. `GET/PUT /settings/drive_lookups` (the PUT needs a manager; a purpose or a service left out
  stays as it is; a name of no service is 422) answers `{purpose: {order, services}}`, each service
  `{name, title, credit, on, key, asks, asked_today, failed_today, daily_most, left, last_failure,
  failing}` (`Lookups.standing`). `failing` is why its last asking gave nothing, and null once it answered
  again and after the day turned; `last_failure` stays for `hubctl maps status`.
- `pos.roads`: `MapboxRoads` (Geocoding v6 forward for the place, then Directions v5, `mapbox/driving` and
  `mapbox/driving-traffic`) and `AzureRoads` (Get Geocoding, then `POST /route/directions`, api-version
  `ROUTE_VERSION`, `optimizeRoute` `fastestWithoutTraffic` and `fastestWithTraffic`, reading
  `durationTrafficInSeconds` for the drive right now). Each says `searches(told)`, how many searches a
  lookup makes first, and takes `start`, where the restaurant stands. `roads_from_env`, `others_from_env`
  and `lookups_from_env` build them from the keys the address list uses; `pos.api.keys.use_keys` hands a
  key typed in the app to the lookups at once.
- `pos.maps.Lookups`: `use(maps, fallback, *others)`; `trip(..., among=)` and `drive_ahead(..., among=)`
  ask the named services in that order (`pos.api.app.asking(purpose)`: the ones turned on that the hub has
  a key for). `trip` gives all of them `CHAIN_WAITS` (2) waits of `TIMEOUT_SECONDS` together and asks
  nobody past that; `drive_ahead` gives all of them one wait, and each but the last half of it at most.
  `start_of(origin)` is where the restaurant stands by Geocodio (`START_SECONDS` 25 days, asked behind the
  request, again after `START_AGAIN` where it gave nothing). `count_with(Suggester.spend)` counts a
  service's searches against
  its month before they are made; a month with no room is `LookupFailed("limit")`, and the asking is taken
  back off the day. The day's most: `OTHER_DAILY_MOST`, `OTHER_TRAFFIC_DAILY_MOST`
  (`POS_MAPS_<NAME>_ROUTES_DAILY`, `POS_MAPS_<NAME>_TRAFFIC_DAILY`). `NOT_KEPT` holds all three but
  Geocodio. `left(purpose, name)` is what a form is told.
- `POST /delivery/distance` adds `title`, `left` and `daily_most` of who measured, and `drive_now` is
  `{minutes, before, credit, service, title, left, daily_most}`. `via` asks one service whether it is
  turned on or not. With keys on the hub and nobody turned on it answers 409 with "no map service is
  turned on for the distance (Location, Delivery fee)". `/maps/status` adds `distance` and `drive_now`
  (the standing rows in the location's order), `live`, `others` and `traffics`; `service` and `fallback`
  stay as they were for an older `hubctl`.
- App: `lib/drive_lookups.dart` (`DriveService`, `DriveOrder`, `DriveLookups`, `leftToday`, `leftShare`);
  `PosApi.driveLookups()` (null from a hub that has none) and `saveDriveLookups(distance:, traffic:)`;
  `lib/screens/drive_services.dart` (`DriveServicesList`, a `ReorderableListView` of rows with
  `ReorderableDragStartListener` handles, in `DeliveryFeeDialog` and `LiveDriveDialog`, each of which saves
  the order before its own setting); `AnsweredBy`, `FeeLookup.by` and `DriveNow.by`
  (`lib/delivery_fee.dart`); `FeeLookupLine` leads each figure with a `ServiceBadge`, and gives each
  figure a line of its own where there are two.
- Tests: `backend/tests/orders/test_drive_lookups.py` (both adapters against `httpx.MockTransport`;
  neither service is ever called) and `apps/pos_app/test/drive_lookups_test.dart`.

Live traffic:

- The setting `live_drive` (`pos.settings`): `enabled` (false until a manager sets it) and `before`, whole
  minutes from 0 to 240 (25). `GET/PUT /settings/live_drive`; the PUT needs a manager. The answer adds
  `traffic` (the hub has a service that knows the roads right now), `origin` (the restaurant's address is
  set; the fee's setting holds it) and `live` (all three). `GET /settings/delivery_fee` adds `live` too,
  which is what a form reads.
- `pos.maps.Google.drive_now(origin, destination)`: the same `computeRoutes` with `routingPreference:
  TRAFFIC_AWARE` and the mask `routes.duration` alone; whole minutes, never less than one.
  `Lookups.traffic` names the service that has a `drive_now` (None where none does), and
  `Lookups.drive_soon(origin, destination)` starts asking on a thread of its own and hands back the
  waiting, so the roads are asked about beside the distance and both are heard inside `TIMEOUT_SECONDS`.
  It gives the minutes or None: no failure reaches a form. Its own day's most, `POS_MAPS_TRAFFIC_DAILY`
  (150), and its own counts under `traffic` in `Lookups.status()`. Nothing is remembered.
- `POST /delivery/distance` takes `now` (the delivery is for now) and answers `drive_now`: `{minutes,
  before, credit}` or null. It is asked only with `now`, the setting on, and no `via`; a saved distance
  does not spare it. The band never goes by it. No op carries it: `fee_ops` reads `up_to` and `measured`
  alone.
- `hubctl maps test "<address>"` (no service named) sends `now` and prints the drive; `hubctl maps status`
  prints the `traffic` line, with `enabled` from the setting.
- App: `DeliveryFees.live`, `DriveNow` and `FeeLookup.driveNow`, `LiveDrive` (`lib/delivery_fee.dart`);
  `PosApi.deliveryDistance(now:)`, `liveDrive()` and `saveLiveDrive()`; `DistanceAsker.ask(now:)`, which
  asks once more about an address that was last asked about without it, and `DistanceAsker.driveFor`;
  `FeeLookupLine` writes "With traffic now: 14 min" and the service's name (one name where the same
  service gave the distance too); `Quotes.minutesFor(drive:)` is `before + minutes` and the rush for a
  delivery for now; `TakeoutRequest.driveNow` reaches `_startOrder`, which writes `quoted_minutes` and
  `promised_at` and nothing else of it; `WhenDialog.live` and `_changeWhen` for a pickup made a delivery;
  `LiveDriveDialog` and the row `live-traffic` under Location.
- Tests: "Live traffic" in `backend/tests/orders/test_delivery_distance.py` (the adapter against
  `httpx.MockTransport`; Google itself is never called) and
  `apps/pos_app/test/delivery_live_traffic_test.dart`.

A second map service:

- `pos.maps.Google`: the Routes API, `POST /directions/v2:computeRoutes` with `origin.address`,
  `destination.address`, `travelMode: DRIVE`, `routingPreference: TRAFFIC_UNAWARE` (the plain price, and
  the usual drive like the first service's) and `regionCode: us`; the key in `X-Goog-Api-Key`, the mask
  `routes.distanceMeters,routes.duration` in `X-Goog-FieldMask`. `distanceMeters` is turned to miles to a
  hundredth and `duration` ("545s") to minutes; no route is `not_found`. `POS_MAPS_GOOGLE_KEY`,
  `POS_MAPS_GOOGLE_DAILY` (100 unless set) and `POS_MAPS_GOOGLE_URL` in the environment.
- `Lookups(maps, fallback=...)` asks the first and then, whatever the first's reason, the second; each
  within its own day's most, and each for `TIMEOUT_SECONDS` in all (`_within`: a thread that is waited for
  and no longer, because a request's own timeout bounds each of its steps and not their sum). It raises
  `not_found` when either said so, else the first one's reason. `Trip.service` names who answered.
  `status()` adds `fallback` (the second service's own counts, or null); with the second alone it is the
  one service. `GET /settings/delivery_fee` adds `services`, the names in the order they are asked.
- What may not be kept: `pos.maps.may_keep(service)` (`NOT_KEPT`). Such an answer is not held in the day's
  memory, `fee_ops` leaves its `measured` off the order (figures with no service named are left off too),
  and `pos.customers.saved_trip` passes over one that is on an order all the same. `credit_of(service)` is
  the name its terms want beside its figures.
- `POST /delivery/distance` answers `credit` ("Google Maps" or null) and `keep` (false for figures that
  may not be kept) beside `service`. `via` in the body names the one service to ask, for `hubctl maps test
  google "..."`: no saved figure and no remembered one answers for it; 422 for a service the hub has not.
- App: `FeeLookup.credit` and `.keep`; `DistanceAsker.measuredFor` gives nothing for figures that may not
  be kept, so a pick does not carry them and they never sit in the outbox; `MapCredit`
  (`lib/screens/fee_lookup.dart`) writes the name as Google's guide for its text asks (the words as they
  are, one line, Roboto where the device has it, regular, 12 points, its gray on light and white on dark),
  in a `Wrap` beside the figures; `DeliveryFees.services` and `mapServiceName` for the dialog under
  Location.
- Tests: "A second map service" in `backend/tests/orders/test_delivery_distance.py` (the adapter against
  `httpx.MockTransport`; Google itself is never called) and the group of that name in
  `apps/pos_app/test/delivery_distance_test.dart`, which also holds the name's colour to a contrast of 4.5
  on every surface of the app's themes.

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
- The staff: kept in the app since 2026-11-24 (`staff.md`). Until a hub's list is taken over, `POS_STAFF`
  reaches the API's container through `infra/hub/docker-compose.yml`, and
  `pos.identity.staff.staff_from_env` leaves out what does not read instead of failing at start
  (`backend/tests/identity/test_identity.py`).
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
  `{up_to, fee}`, `up_to` a string such as `"2"`, `"2.5"` or `"0.25"`: miles to a hundredth, whole
  minutes; kept in order of reach, at most 8), `taxed` and `custom` (true to start: a delivery may be
  charged an amount typed on it; an app that does not send `custom` leaves it as it is stored).
- The order field `delivery_fee` (`pos.orders.delivery_fee`). A screen sends the band alone,
  `{"up_to": "4.5"}`, `{"up_to": null}` for no fee on purpose, or null to take the answer back. `fee_ops`
  (in `append_ops`, after `bag_ops`) fills it in from the setting as it arrives:
  `{by, up_to, amount, taxed}`. A band the setting does not list is refused (`invalid_delivery_fee`) and
  left out, and whatever else the operation said is kept. Anything a screen sends beside `up_to` is
  dropped, so no screen sets the amount of a listed price.
- The custom fee: a screen sends `{"custom": "12.50"}` (and `measured`, as with a band) and `fee_ops`
  keeps `{by: "custom", up_to: null, amount, taxed}`, taxed as the setting says. It is refused
  (`invalid_delivery_fee`) while the fee is off, while the setting's `custom` is false
  (`custom_allowed`), with an amount outside 0.01 to 999.99, and with a band beside it. The hub does not
  ask how far the address is: the map only offers the custom fee (`beyond` in the answer of
  `/delivery/distance`), a person may pick it for any delivery. The check's row says
  `delivery: {by: "custom", up_to: null}`.
- The check (`pos.orders.check.check_for`): `fee_charged(fields)` gives the fee only while
  `is_delivery(fields)` and the amount is above zero. It is a row of `charges` with the id `fee:delivery`
  (not the pricing rule's code `delivery_fee`), `automatic: false`, `taxed`, and `delivery: {by, up_to}`.
  Taxed, it is a taxable line of the class `delivery_fee` (the profile's own rule for it, else its default
  rule); not taxed, it adds no base, on the order and on each check of a split (`pos.orders.split`).
- History (`pos.orders.history`): a `delivery_fee` step with `now` and `was`, each the fee as
  `fee_of` reads it or null. An order opened with its fee says it in a step after `opened`.
- App: `lib/delivery_fee.dart` (`DeliveryFees`, `FeeBand`, `OrderFee`, `FeePick`),
  `PosApi.deliveryFees` (null from a hub older than the fee) and `saveDeliveryFees`,
  `lib/screens/fee_picker.dart` (the choices, inside `EventFields`), `WhenDialog.fees` and `.fee`,
  `TakeoutRequest.fee`, `CheckCharge.isDeliveryFee` (a tap opens `_changeWhen`),
  `lib/screens/delivery_fee_dialog.dart` and the row `delivery-fee` under Location.
- What a screen holds while a fee is picked is one string (`FeePick`): a band's reach, `none`, `kept`,
  or `custom` (`+`) followed by what is typed, such as `+12.5`. `FeePick.field` turns it into what is
  sent, `FeePick.unfinished` says a custom fee has no amount yet (the order cannot be saved), and
  `FeePick.found` is what an answer of the map picks. `DeliveryFees.custom` is null from a hub older
  than the custom fee: no switch is shown, nothing is sent and no screen offers it.
- `FeePicker` shows a button for each choice up to `DeliveryFees.mostButtons` listed prices (4) and,
  past that (`crowded`), the line `fee-list` that opens the sheet `fee-list-sheet` of `FeeListLine`s.
  The custom fee and "No fee" are not counted. The box `fee-custom-amount` is under either.
- Tests: `backend/tests/orders/test_delivery_fee.py`, `apps/pos_app/test/delivery_fee_test.dart`,
  `apps/pos_app/test/delivery_fee_far_test.dart` (the custom fee and the list).

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
- `POST /delivery/distance` `{"address"}` answers `miles` (a string, to a hundredth: "0.25", and "3.2" where the
  hundredths are nothing), `minutes`, `by`, `band`
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
  spelling. Figures without them (an older app's) are never handed on, and since there has been a second
  map service they are left off the order altogether: nobody can tell whose terms they fall under.
- The body may carry `phone` and `fresh`. With a phone and without `fresh`,
  `pos.customers.saved_trip(store, phone, address, mark)` reads the customer's newest orders (the index
  by phone, at most 40, voided ones aside, as `customer_card` does) for a delivery to the same address
  (`pos.maps.same_address`: the case and the spaces aside) whose `measured.from` is today's mark. Found,
  it is the answer, with `saved: true`: the service is not asked, the day's count does not move, and
  `Lookups.spared()` counts it for `saved_today` in `GET /maps/status`. Saved figures come before the
  day's answers in memory, so a customer is told the figure their own order carries.
- The band is always worked out from today's setting (`band_for`), never read off the old order.
- The phone number is used on the hub alone: `Maps.trip` takes the two addresses and nothing else.
- A service whose terms do not allow its results to be kept has its figures left off the order in
  `fee_ops` (by `measured.service`), which is why the service's name is kept: "A second map service",
  below.
- App: `PosApi.deliveryDistance(address, phone:, fresh:)` (the digits only, and `fresh` only when true, so
  an older hub is sent what it knows), `DistanceSource`, `FeeLookup.saved`, `Measured.service` and `.from`
  (sent back as they came), `DistanceAsker.ask(fresh:)`, `LookUp` (`onLookUp(fresh: true)` from the button
  `fee-lookup-again`). The to-go form binds the number in its box, the order's dialog the order's own.
- Tests: the same two files ("Customers who order again", `customers who order again`).
