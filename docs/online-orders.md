# Online orders

An order a customer places on the restaurant's own website (GloriaFood) goes on the POS by itself, as a
to-go order like any other (`counter-mode.md`, `delivery.md`): numbered, with the customer's name and
number, its dishes, what it cost, and whether it was paid. Its kitchen tickets print by themselves. Nobody
types it in.

This is the hub's half. The screens show such an order as they show any to-go order; what they do not show
yet is listed under [What is not built](#what-is-not-built).

A **table booked on the website** goes into the reservation book the same way
([Tables booked on the website](#tables-booked-on-the-website)).

**Nothing here was tried against GloriaFood itself**, and nothing against Cloudflare. It was written from
GloriaFood's own description of how a POS gets orders, and tested against orders made up in that shape from
the restaurant's real menu. The first real orders are the test: see [The first days](#the-first-days).

## How it works

Staff accept an online order in GloriaFood's own app, as they do today. That does not change.

An accepted order reaches the hub in two ways, and both are on at once:

- **GloriaFood sends it** (a push), the moment it is accepted. The order is on the POS a second or two
  later. This is the first way, and it needs a way in from the internet to the hub: see [Push](#push).
- **The hub asks for it.** Once a minute the hub asks GloriaFood: "any orders accepted since I last asked?"
  The question carries the restaurant's key and nothing else, and GloriaFood answers with the orders. This
  is the net under the push: an order whose push was lost on the way is on the POS within the minute.

**An order that came both ways is one order.** Whichever way brings it first puts it on the POS; when it
comes the other way too, the hub knows GloriaFood's number for it and does nothing. The same holds for an
order GloriaFood sends twice, which its pages say can happen.

Either way, the first thing the hub does with an order is write it down as it came (when it asks,
GloriaFood hands an order over **once**). Only then does it put it on the POS:

- It becomes a to-go order, channel **Online**, with the next order number of the day.
- It is sent to the kitchen at once, so each station's ticket prints, and the takeout counter's copy of
  the whole order with PAID or NOT PAID on it.
- An order the customer wants **later** is sent too, and its tickets wait: they print as long before its
  time as the location's quote for online orders says (25 minutes unless changed; 45 for a delivery), as
  any order taken ahead does (`catering.md`).

The asking works from behind the restaurant's router by itself: the hub calls out, nothing calls in. Only
the push needs more.

## Turning it on

Start with the asking: it needs nothing but a key, and it stays on as the net once push is added. Three
steps. The first is yours alone: the key is made in your GloriaFood account.

1. **Make the key.** In GloriaFood's restaurant admin, open the list of integrations (under "Others",
   "Third party integrations" as GloriaFood's pages describe it; the labels may read a little differently
   in your admin), add a custom integration, and pick the template **Poll Accepted Order v2**. Where the
   form asks which **order status** to send, tick **Accepted** and nothing else, and for how often, once,
   when the order is accepted. (With Pending ticked too, GloriaFood hands every order over before anybody
   accepted it: see [An order that comes before it is accepted](#an-order-that-comes-before-it-is-accepted).)
   Saving it shows a key. Copy it.
2. **Give it to the hub.** In the app: Location › **Keys and connections** › GloriaFood (online orders) ›
   **Type the key**, paste it, Save. The hub starts asking at once, and **Try it** on the same card asks
   GloriaFood now (`hub-keys.md`). Or in the hub's terminal, after `sudo hubctl update`:

   ```
   sudo hubctl online key
   ```

   It asks for the key and does not show it as you paste it. The key is written to `/opt/pos/.env`
   (`POS_GLORIAFOOD_KEY`), the API restarts, and the command prints how things stand.
3. **Look.** `sudo hubctl online status` says whether GloriaFood answered. Place a small test order on the
   website, accept it in GloriaFood's app, and within the minute it is on the list of checks and its
   tickets print.

Without a key the hub asks nobody, and everything is as it was. Then add the push: [Push](#push).

| Command | What it does |
| --- | --- |
| `sudo hubctl online key` | Puts the key for asking on the hub (asked for, never shown, never on the command line) |
| `sudo hubctl online status` | Whether pushes are taken and when the last one came, whether the hub asks and when GloriaFood last answered, pushes turned away, today's online orders by how they came and what became of them, and the ones to look at |
| `sudo hubctl online fetch` | Asks GloriaFood now instead of within the minute, as **Ask now** on the screen Online orders does. Not within fifteen seconds of the last asking |
| `sudo hubctl online show 123456` | One order as GloriaFood sent it, by GloriaFood's number, with everything of the customer taken out: for looking at an order that went on wrong |
| `sudo hubctl online forget` | Takes the key for asking off the hub: it asks nobody. Orders already on the POS stay |
| `sudo hubctl online push key` | Puts the key GloriaFood's pushes carry on the hub, which opens the push door for it. Asked for and never shown; press Enter alone and the hub makes one, shown once, for you to put into GloriaFood's admin |
| `sudo hubctl online push test` | Sends an empty push through the door and says whether it got in. With an address (`sudo hubctl online push test https://orders.example.com/online/push`) it goes out to the internet and back in, the whole way GloriaFood's pushes will take. Nothing is put on the POS |
| `sudo hubctl online push forget` | Takes that key and the tunnel's token off the hub: the door is shut, the tunnel closed, and the hub only asks |
| `sudo hubctl online tunnel token` | Puts a Cloudflare Tunnel's token on the hub (asked for, never shown) and waits until the tunnel has reached Cloudflare |
| `sudo hubctl online tunnel status` | Whether the tunnel is connected, and its last words when it is not |
| `sudo hubctl online tunnel forget` | Closes the tunnel and takes its token off the hub |

The key for asking, the key for pushes and the tunnel's token are all typed in the app as well, under
Location › **Keys and connections**, and that is the shorter way (`hub-keys.md`). The terminal and the app
set the same thing, and whichever was used last wins.

## Push

GloriaFood can send an order to the POS the moment it is accepted, instead of waiting to be asked. It
sends it to an address on the internet, over HTTPS, with a key of yours in it. The hub checks the key,
writes the order down, puts it on the POS and only then answers. The asking stays on beside it.

Three things are needed, and each is turned on by itself:

1. **A key** that GloriaFood's pushes carry, so that the hub takes orders from GloriaFood and from nobody
   else.
2. **A way in** from the internet to the hub, which sits behind your router.
3. **The integration** in GloriaFood's admin that says where to send.

### The door

Whatever brings pushes in from outside must never be pointed at the POS itself. So the hub has a **push
door**: a second, tiny server that does one thing. A push that carries the key is handed on to the POS;
everything else, any other address, any other kind of call, gets an empty "not found". The way in is
pointed at the door (`door:8090`), and behind the door there is nothing to find but the one call.

A push without the key is not read at all. The hub counts it and `hubctl online status` says so ("turned
away"), because a wrong key in GloriaFood's admin looks exactly like that. Strangers knocking at an address
on the internet look like that too, so a few of these now and then mean nothing.

The door runs all the time and is **shut until there is a key**: without one it answers "not found" to
everything, a push too. It opens the moment a key is typed, in the app or the terminal, with nothing
restarted. It listens only on the hub itself. And it never holds the key: the hub hands it a fingerprint of
the key (its SHA-256), which is enough to tell a push that carries the key from one that does not, and is of
no use to anybody who reads it.

### The way in

**Built in: a Cloudflare Tunnel.** The hub calls out to Cloudflare and holds the line open; GloriaFood
sends to an address at Cloudflare, and the push comes down the line to the door. Nothing is opened on your
router. As this is written Cloudflare does not charge for it; look when you make the account. It needs a
Cloudflare account, which is yours to make, and a domain name whose DNS is kept at Cloudflare (a name you
own that is not there yet has to be moved there, or another name bought there). Orders pass through
Cloudflare's machines on their way: see [What is kept](#what-is-kept-and-what-leaves-the-building).

The hub runs Cloudflare's own program for it (`cloudflared`) and keeps an eye on it: it starts the program
when a token is set, starts it again when it stops, and says how it stands, on the page Keys and connections
and in `sudo hubctl online tunnel status`: connected and since when, on its way, or not connected and why
(Cloudflare did not take the token; the hub cannot reach Cloudflare). Without a token the program is not
run at all.

**Or your own.** Anything that brings an HTTPS address to the door works: another tunnel program installed
on the hub (pointed at `http://127.0.0.1:8090`), or your own router and a proxy that holds the certificate.
For a proxy on another machine, put `POS_DOOR_BIND=0.0.0.0` into `/opt/pos/.env` and run `sudo hubctl
update`: the door then listens on the restaurant's network too, at the hub's address, port 8090. The door
speaks plain HTTP; the HTTPS must end at the proxy. Forward to port 8090 only, never to 8000.

### Turning push on

After `sudo hubctl update` and the apps rebuilt, and with the asking already on. All of it is on one page
of the app: Orders screen › the three dots › Location › **Keys and connections** (`hub-keys.md`). The
hub's terminal does the same, and its command is under each step.

1. **The key.** On the card **GloriaFood push key**: **Type the key**, then **Make one**, **Copy**, and
   Save. The key is shown while that box is open and never again, to anybody, so copy it before you save:
   it goes into GloriaFood's admin in step 4. (If GloriaFood's admin turns out to show a master key of its
   own instead of asking for one, paste GloriaFood's into the box instead.) The push door is open for the
   key from that moment.

   In the terminal: `sudo hubctl online push key`, and Enter alone. The hub makes a key and shows it once.
2. **The tunnel, at Cloudflare.** In Cloudflare's dashboard, under Zero Trust, Networks, Tunnels, create a
   tunnel of the kind "Cloudflared" and give it a name (`pos-hub1`). Cloudflare shows a command to install
   it, with one very long word in it that starts with `eyJ`. That word is the tunnel's token. Nothing is
   installed by hand: the hub has the program already. On the card **Cloudflare Tunnel (the way in)**:
   **Paste the token**, paste the whole command or only that word, and Save. The card says "On its way to
   Cloudflare, not connected yet" and, a few seconds later and by itself, "Connected to Cloudflare since
   14:02". If Cloudflare does not take the token, the card says that instead.

   In the terminal: `sudo hubctl online tunnel token`. It asks for the token, does not show it, and says
   when the tunnel has reached Cloudflare.
3. **The address.** Back at Cloudflare, give the tunnel a public hostname: a subdomain (`orders`), your
   domain, the path `online/push`, the service type **HTTP** and the address **`door:8090`**. Exactly
   that address: it is the door, and the only thing of the hub the tunnel should ever be told about. Then
   **Try it**, on either of the two cards. It asks for the address (`orders.example.com`, your own name),
   which the hub remembers, and should say "The whole way in works". See [Try it](#try-it) for what it
   does and what else it can say.

   In the terminal: `sudo hubctl online push test https://orders.example.com/online/push`.
4. **GloriaFood.** In GloriaFood's restaurant admin, where the integrations are, add a custom integration
   with the template **Push Accepted Order**: the address from step 3 as the endpoint (the push key's card
   shows it whole, "GloriaFood sends to https://orders.example.com/online/push", with a button that copies
   it), the key from step 1 as the master key, the format **JSON**, version 2. Leave "Poll Accepted Order
   v2" as it is: that is the net.
5. **Look.** Place a small test order and accept it. It is on the POS before you have put the phone down,
   and the screen Online orders (and `sudo hubctl online status`) counts it as "sent by GloriaFood".

The labels in Cloudflare's and GloriaFood's pages may read a little differently from these.

A hub that was set up in the terminal before this goes on as it did: its key and its token show on the page
as "Set in the hub's terminal", and nothing has to be typed again.

### Try it

**Try it** proves the way in from end to end without GloriaFood: the hub knocks at its own push door, and,
with an address, at that address from outside, the way GloriaFood comes: out to the internet, to Cloudflare,
down the tunnel, through the door, and back to this hub. It knocks with a word made for that one try in
place of the key, and knows its own word when it arrives. So **the key for pushes is sent nowhere**, a try
puts nothing on the POS, and it is not counted as a push turned away.

| It says | What that means, and where to look |
| --- | --- |
| "The whole way in works" | A call to that address reached this very hub. The address is the one for GloriaFood's admin |
| "The push door is open and leads to this hub. Give the address ..." | No address was given, so only the door was tried |
| "The push door is not running on this hub" / "is shut" | The hub is older than this, or could not hand the door its key: `sudo hubctl update` |
| "nothing answers at orders.example.com" | The name does not exist yet. At Cloudflare, the tunnel needs a public hostname of that name (it makes the DNS record itself) |
| "answers, but not from this hub" | The name leads somewhere else: to another hub, or to a website of yours. The public hostname's service must be `http://door:8090` on this hub's tunnel |
| "is known, but leads nowhere for /online/push" | The public hostname's path is not `online/push`, or its service is not the door |
| "Cloudflare answers ... but cannot get to the push door" | The tunnel is not connected (look at its card), or its service is not `http://door:8090` |
| "turned the call away (403)" | A security rule at Cloudflare stops the call before the tunnel. It would stop GloriaFood's server too |
| "sends callers on to another address" | Something redirects (a rule that forces another name, say). GloriaFood does not follow a redirect |

The address has to be a name (`orders.example.com`): the hub tries no bare number, no port and nothing but
HTTPS, follows no redirect, and says of the answer only its number. Only a manager or an owner can set the
address or try it.

### What is not known yet

GloriaFood's pages leave these open, and the first real orders will answer them. None of them can lose an
order while the asking is on.

- **Whether its admin asks for the master key or shows its own.** The card and the command take either.
- **How a push is wrapped.** The hub reads what GloriaFood answers when asked (`{"count": 1, "orders":
  [...]}`), one order by itself, and a bare list. Anything else is kept as it came and listed in the
  status with what it looked like, and the order arrives by the asking.
- **What GloriaFood does when a push does not get through**, and for how long it tries again. Nothing
  depends on it: the asking brings the order within the minute.
- **Whether an order that was pushed is also handed over when asked.** If it is, the hub sees it twice and
  it is one order. If it is not, the asking brings only what the push missed, which is all it is for.
- **Whether a pushed order carries the restaurant's key.** It matters only with
  [several accounts](#several-accounts): it is how the hub tells which account a pushed order is from. If
  it does not, the hub goes by GloriaFood's number for the restaurant, which it learns from the first order
  it asked that account for.
- **Whether GloriaFood sends anything a second time when an order changes** after it was accepted. The
  first arrival stands; a later one with the same number changes nothing on the POS.
- **How a booked table reads.** GloriaFood's pages say `persons` is how many sit down. They do not say in so
  many words that `fulfill_at` is the time of the table, though it is the only time a reservation carries.
  Hold the first few reservations in the book against GloriaFood's app: the name, how many, and above all
  the time.
- **Whether GloriaFood tells the hub when a guest changes or cancels a table.** Its pages do not say that
  it does. Until a real one shows otherwise, a change or a cancellation made on the website does not reach
  the book.

## Several accounts

A restaurant can have more than one account with GloriaFood: a second website (the sushi bar's own, say),
and an account it only tests with. The hub asks **every** account, each with its own key, and every order
goes on the same POS.

**Adding one.** In the app: Location › **Keys and connections**. Under the GloriaFood card is **Add another
GloriaFood account**. It asks for:

- **A name**, yours to choose ("Sushi site"). It is how that account's orders are told from the others'.
- **The key**, made in *that* account's GloriaFood admin exactly as the first one was
  ([Turning it on](#turning-it-on), step 1).
- **For testing**, a switch: on for the account you only test with.

The hub asks the new account at once and every minute after, and is not restarted. Each account then has
its own card: **Replace** its key, **Try it**, **Remove**, and a pencil beside its name for the name and the
switch. The account that was there first is the **first account**; give it a name too (the pencil on its
card) once there are several, or its orders say no website. Its key is the one `sudo hubctl online key` sets. A further account's key is
typed in the app only, and removing the account forgets its key; the orders it brought stay. A hub asks up
to eight accounts.

**What tells them apart.** With a name on each account:

- The order's strip reads "From the website · Sushi site", and so does what a tap shows.
- The takeout counter's copy and each station's ticket print `Online: Sushi site` where they print the
  channel, and a kitchen screen says "Online · Sushi site".
- The screen **Online orders** has a line for each account under "Asked for every minute" (when GloriaFood
  last answered it, how many orders it brought today, or why it does not answer), and each order to look at
  says which account brought it: its number is found in *that* account's GloriaFood app.
- An account whose key is refused does not hide behind the others: it has a box of its own, by name, and
  the others go on arriving. `sudo hubctl online status` lists each account the same way.

**The account for testing.** Its orders go the whole way a customer's does, which is the point of a test:
on the POS, numbered, sent to the kitchen, printed. So that nobody cooks one:

- Every ticket and the takeout counter's copy print **TEST ORDER** and **DO NOT MAKE**, large, white on
  black, under the first line.
- A kitchen screen heads the ticket with a black bar, "TEST ORDER · DO NOT MAKE".
- The order's strip carries the same mark, and its globe in the list of checks is white on black.

A test order is **an order like any other in the reports** until it is voided: void it when you are done,
as you would any order rung in by mistake (`voids.md`). If the testing account stops answering, no screen
turns red for it: no customer's order is held up.

**The same order twice.** GloriaFood's number for an order is what the hub knows it by, across all the
accounts: an order is one order however often and by whichever way it comes.

**Push with several accounts.** The push door has **one key** for the whole hub: put the same push key into
each account's integration, and each sends to the same address ([Push](#push)). The hub tells which account
a pushed order belongs to by the restaurant's key the order carries, and when it carries none, by the
restaurant's number that account's earlier orders had. An order it cannot put to an account is taken all the
same, as one from no named website: nothing is lost, it only does not say "Sushi site".

That leaves **one gap, and it is worth a look on the first day**: an account's very first order, if GloriaFood
pushes it and it carries no key the hub knows, names no account. For the testing account that is a test
order **without** its TEST mark. The cure is simple: **place each account's first order while its
integration does not push yet** (add the account's key, test it, then turn its push on). That order comes by
the asking, the hub notes GloriaFood's number for that restaurant, and every later order of the account is
told right, pushed or asked for, also after the hub restarts. (When the asking brings an order a push
brought first without an account, the hub notes whose it is then too; the order on the POS is not changed.)
Whether GloriaFood's pushed orders carry the restaurant's key at all is not known until a real one comes
([What is not known yet](#what-is-not-known-yet)).

**The dishes of a second website.** The menu import (`menus.md`) keeps GloriaFood's numbers for the dishes
of **one** menu, the first account's. Another account numbers its dishes by itself, so the hub finds them
**by name**: a dish called exactly what one dish on the POS is called goes on as that dish, at its station.
One whose name matches nothing, or matches two, goes on **as written** ([The dishes](#the-dishes)), which
still prints. Its sizes and choices are found by GloriaFood's numbers alone, so on a second website a dish
with a size or a choice the POS does not know by that number goes on as written too. Importing a second
website's menu is not built.

## Two things to change once it is on

- **Do not also ring online orders in by hand.** The sale would be on the POS twice.
- **GloriaFood's own printing.** If GloriaFood prints the kitchen's tickets today, leave that on for the
  first days and hold its paper against the POS's. Once they agree, turn GloriaFood's printing off, or
  every online order prints twice.

## What arrives

**Pickup and delivery orders that were accepted** go on the POS. **Tables that were booked** go into the
reservation book ([Tables booked on the website](#tables-booked-on-the-website)). Nothing else:

- An order placed from a table (a QR code on the table) is left where it is, in GloriaFood's app.
- An order nobody accepted, or one that was rejected, is never put on the POS. With the integration set to
  send accepted orders only, it never reaches the hub at all.

### An order that comes before it is accepted

GloriaFood's integration can be set to send more than accepted orders: with **Pending** among its order
statuses, it hands an order to the hub the moment the customer places it, and the same order a second time
when somebody accepts it. The hub takes that as it comes:

- The order as it was placed is written down and **not put on the POS**: nobody accepted it yet, and it may
  still be turned down. The screen Online orders lists it as "it waits to be accepted in GloriaFood's app".
  No alert, no slip: this is an order on its way, not one that went wrong.
- When GloriaFood hands the same order over again as **accepted**, it goes on the POS and to the kitchen
  like any accepted order, once, and leaves the list. A table that was booked goes into the book the same
  way.
- When it comes again as rejected, or as missed (nobody answered it in GloriaFood's app in time), the list
  says so, and it stays off the POS.
- An order that still waits **a quarter of an hour** after it came alerts a manager. An order for now is
  answered in GloriaFood's app within minutes, or missed there. So one that still waits was most likely
  answered and the hub was never told: the integration hands orders over when they are placed and not
  again when they are accepted. Tick **Accepted** alone in the integration, as above, and ring the order in
  by hand if it was made. (The other case is an order for later, placed while the restaurant was shut:
  nobody could answer it yet, and it goes on the POS when somebody does.)

An order that is on the POS stays there whatever GloriaFood says of it later (cancelled in its app, say):
taking it off is a void, by a person, with its reason.

The plainest setting is the one under [Turning it on](#turning-it-on): Accepted alone. Then every order
reaches the hub once, when it is accepted, and nothing waits.

### The dishes

Each dish is found on the POS's menu by GloriaFood's own number for it, which the menu import kept
(`menus.md`). Its size and its choices are found the same way. So the kitchen's ticket reads as if the
dish had been rung in at a screen: the kitchen's own name for it, at its own station.

- **The price is the website's**, always. The customer was shown it and agreed to it, and the dining
  room's price can differ.
- **A dish whose number the POS does not know** is looked for by its **name**: when exactly one dish on the
  POS is called that, it is that dish. That is how the dishes of a second website are found
  ([Several accounts](#several-accounts)).
- **A dish the POS's menu cannot make** goes on **as written**: under GloriaFood's own name for it, with its
  size and choices as words, at the price it was sold for. That happens for a dish that is on the website
  and not on the POS, or a choice the POS's menu does not take. It still prints: where the dish is cooked
  when the POS knows the dish, otherwise at the first printer. `hubctl online status` lists such orders, so
  the menu can be mended.
- **A dish the kitchen is out of** goes on all the same: it was sold, and somebody accepted it. A dish with
  a number left is counted down (`eighty-six.md`).
- **What the customer wrote** for a dish is the dish's note. What they wrote for the whole order prints on
  every station's ticket under a bar, **CUSTOMER'S NOTE**, before the dishes, and on the pack sheet: it may
  say "no onions in anything".

### The money

The check on the POS comes to what the customer was charged on the website, to the cent.

| On the website | On the POS |
| --- | --- |
| A promotion on a dish | A discount on that dish, named **Online promotion**, with the promotion's name as its note |
| A promotion or a coupon on the whole order | One discount on the check, **Online promotion** |
| The delivery fee | The order's delivery fee (`delivery.md`), marked as charged on the website. It is taxed or not as the website taxed it |
| A tip | A charge named **Tip**, kept apart from the sales as a gratuity, never taxed |
| A service fee | A charge of that name |
| Paid on the website, whichever way it took the money: a card, Apple Pay, Google Pay, PayPal | A payment, **Paid online**, recorded on the day as money taken outside the POS. The ticket says PAID |
| Paid in more than one way (GloriaFood names two ways of paying on the order) | No payment: the hub does not guess how much each part was. The order is listed to look at, and GloriaFood's app says what is still to collect |
| Cash or card at the door | No payment: the ticket says NOT PAID and what is owed, and it is paid on the POS when the customer comes |

A charge the POS would add by itself to a to-go order is left off: the customer was not charged it.

**Rounding.** The POS rounds the state's part and the town's part of the meals tax each by itself;
GloriaFood rounds 7% once. On about one order in four that is a cent apart. A row named **Rounding** (a
cent up or down, never taxed) makes the check equal what the customer paid. It shows on the check and the
bill, and nothing is changed quietly.

**Online total difference.** If the two totals are further apart than a few cents, something came that
this build does not know (a new kind of fee, say). The check is still made equal to what the customer was
charged, by a row with that name, and the order is listed in `hubctl online status` for somebody to look
at.

### Delivery

A delivery is a delivery as `delivery.md` describes it: DELIVERY on every paper, the address on the bill
that goes with the bag and not on the kitchen's tickets, the apartment, floor and intercom in the note for
the driver. The fee is the one the website charged. On the order's form it shows as **On the website**;
the map does not move it, and nobody is asked to pick another. A manager or server can still tap another
price, or No fee, as with any fee. A screen cannot make up a website fee.

## Tables booked on the website

Since 22 November 2026. A table a guest books on the website, once it is accepted in GloriaFood's app, is
written into the reservation book by the hub (`reservations.md`): the name, how many they are, the day and
the time, the phone number, and what the guest wrote as the note. It comes the same two ways an order does,
pushed or asked for, and is in the book once however often it comes. Nothing has to be turned on beyond
online orders themselves.

- **In the book** it stands among the others in the order of the times, with a small **online** beside its
  time: the guest booked it themselves, and nobody here spoke to them. A tap shows "booked on the website
  (GloriaFood 1234567)", the number to find it by in GloriaFood's app.
- **It is a reservation like any other from then on.** A host holds a table for it, changes it, seats it,
  cancels it. Somebody who calls about it is found by the number they gave the website. No table is held
  for it until a host picks one.
- **It is no check and no sale**, and no money is taken for it.
- **Only what the book needs is copied.** No e-mail address, no consent to marketing.
- **Made to fit the book.** A name longer than the book's 24 letters is shortened to the family name, or
  the first name. A note longer than 80 letters is cut and ends in "…": the whole of it is in GloriaFood's
  app. A phone number the book would not take is left out, and the list To look at says so.
- **A table booked with its dishes ordered ahead** goes into the book too. Its note begins "Ordered ahead:
  dishes in GloriaFood." **The dishes are not put on the POS**, and nothing is recorded for them, paid on
  the website or not: every one is listed under To look at, for a manager, to be rung in from GloriaFood's
  app when the party sits, so the sale is in the POS's figures.

When it does not go as it should:

| What happened | What the hub does |
| --- | --- |
| **It does not say for how many, or for when**, or it is for more than 60 | It is **not in the book**. A slip prints, NOT IN THE BOOK, a manager's screen is alerted, and it is listed under To look at: look at it in GloriaFood's app and write it into the book by hand |
| **The day is full** (200 reservations), or it is more than a year ahead | The same, in the book's own words |
| **It reaches the hub after its time, the same day** (the hub was off) | It goes into the book, late as it is. A slip says RESERVATION CAME LATE, and it is listed: see whether the party is here |
| **It is for a day that is over** | It is not put in the book: there is nothing left to do about it. It is listed under To look at that day, and no slip prints |
| **The book cannot be written just then** | It is tried again each minute, five times, like an order |
| **A host cancelled it in the book, and GloriaFood hands it over again** | Nothing: the first one stands as the host left it |

Not built: a change or a cancellation the guest makes on the website afterwards does not reach the book
(cancel it there by hand); the dishes of a table booked with them going on the POS by themselves; a table
that reached the hub before it was updated to this (it is in GloriaFood's app and is not put in the book
afterwards; one that came earlier on the day of the update is listed under To look at as "Not in the
book"); and telling the guest anything back.

## On the screens

An online order is a to-go order like any other: it is in the list of checks, it has its Ready and Picked
up (or Out and Delivered) steps, it is on the orders-ahead list when it is for later, and on a kitchen
screen. Four things say that it came from the website.

- **In the list of checks**, a small globe on the corner of the order's number. Only an order the hub took
  from the website has it; one rung in by hand under the channel Online does not.
- **How it is paid**, in the list and on the order, as the customer chose on the website: **paid online**,
  **pays cash at pickup**, **pays by card at the door**, **pays by card over the phone**. Once money is
  taken for it on the POS it reads as any order does: "paid", or what is still due. If the website took
  money the hub did not record (it was paid in more than one way there), it says to check GloriaFood for
  what was paid.
- **On the order's own screen**, a slim strip under the bar: "From the website · paid online", and under it
  what the customer wrote for the whole order, "Customer wrote: no onions in anything". A long note shows
  two lines; a tap shows every word, with GloriaFood's own number for the order (what to find it by in
  GloriaFood's app) and what the website charged. The strip is to read: nothing on it can be changed.
- **The payment on the check** reads **Paid online**, where it read "Paid elsewhere". The check's history
  says the same.
- **In the day's report and in Sales**, the money the website took is a row of its own, **Paid online**,
  under Money taken, and a column of the accountant's sheet: the figure to hold against the statement of
  the payment company the website uses. It was under Paid elsewhere before; no total changed
  ([day-report.md](day-report.md)).

**On a kitchen screen** the customer's note heads the ticket in a dark band, "Customer's note · …", under
any allergy and before the dishes, as the paper has it under CUSTOMER'S NOTE. It is shown whole, however
long it is: it may say an allergy. It is on every station's ticket for the order, and on the pass.

The note is what the customer typed. It is not the allergy block: nobody at the restaurant has read it and
picked the allergens, so it does not turn any dish red. Read it.

A restaurant with several websites reads **which one** in each of these places, and an order from its
account for testing wears **TEST ORDER**: see [Several accounts](#several-accounts).

## Under Location, and the alert

What `sudo hubctl online status` says is on a screen too, and a manager is told when there is something to
look at without anybody running a command.

**The alert.** While a manager or an owner is signed in, one slim line stands above the checks when:

- there is something about an online order **to look at**: it could not be put on the POS; it went on
  late and was not sent to the kitchen; it went on with a dish as written, or with a total that differs
  from the website's; or something the website sent could not be read. "Online orders: 1 to look at". An
  order the hub is still trying to put on does not alert until the hub gives up on it, which is when its
  slip prints;
- **no online order is reaching the POS**: the hub has asked GloriaFood for five minutes and got no answer,
  and nothing says the orders GloriaFood sends by itself are getting in. The line is red: "Online orders
  are not reaching the POS since 18:40". Until it is over, new orders are in GloriaFood's own app.

A tap opens **Online orders**. Opening it is the looking: the hub writes down that somebody looked, and the
line goes away **on every manager's screen**, not only this one. Nothing is taken off the list by that. The
red line is different: it stays until GloriaFood answers again, whoever looked, and goes by itself within
half a minute of that.

Servers, bartenders and hosts see no such line. An order that comes in the normal way alerts nobody: its
ticket prints and it is in the list of checks.

**Online orders** opens from that line, from the menu of the list of checks (managers and owners, on a hub
that takes online orders) and from **Location › Online orders**, whose row says in one line how they stand.
It shows:

- **what is wrong right now**, in a box at the top, with what to do about it. Besides the red one there
  are two that alert nobody because the orders still arrive: GloriaFood does not answer the hub's asking
  while its own sending works, and GloriaFood's sending is turned away while the asking works (the orders
  come a minute late; the key in GloriaFood's admin is probably not the hub's);
- **how they arrive**: sent by GloriaFood and asked for by the hub, each on or off, with when the last one
  came and when GloriaFood last answered. Under the asking is **Ask now** (below);
- **today**: how many came, how many are on the POS, how many were not for the POS, how many could not be
  put on, how many wait, and how many came each way;
- **to look at**: each by GloriaFood's own number (what to find it by in GloriaFood's app), with the time,
  what became of it and why. The ones nobody has looked at yet are marked **New**. One that is a check on
  the POS opens that check with a tap (from the list of checks; under Location the screen is to read).

**Ask now** has the hub ask GloriaFood for orders this moment instead of at its next minute, for when a
customer says they just ordered and the order is not on the POS yet, or when the box at the top says
GloriaFood has not answered. It does exactly what the hub does by itself every minute: an order GloriaFood
gives goes on the POS, is numbered and prints its tickets as always, and one that is here already is not put
on twice. Under the button the screen says what came of it: "1 order came. 1 put on the POS.", "GloriaFood
has no new order.", or why GloriaFood did not answer, in red. The figures under **Today** move with it.

- Only an order **accepted** in GloriaFood's app can come. One still waiting to be accepted there is not
  GloriaFood's to give yet.
- GloriaFood asks a POS not to ask too often, so the hub passes on **one asking in fifteen seconds** at
  most, whoever presses and on whichever screen: a press sooner than that asks nobody and says "GloriaFood
  was asked a few seconds ago. Wait a moment and ask again." The hub's own minute is never held back by it.
- The button is there on a hub that has the key for asking. A hub that only takes what GloriaFood sends
  has nothing to ask with.
- It is on this screen only, so for managers and owners. `sudo hubctl online fetch` does the same from the
  hub.

Nothing of a customer is on this screen. Nothing on it changes an order that is on the POS: Ask now can
only bring one that would have come within the minute anyway.

## When something is off

Nothing is dropped quietly. An order that is not on the POS as a normal order prints a slip, **LOOK**,
where the to-go orders print, alerts a manager's screen, and is listed on the screen Online orders and by
`sudo hubctl online status`. (For a table that was booked, the same is said under
[Tables booked on the website](#tables-booked-on-the-website).)

| What happened | What the hub does |
| --- | --- |
| **The hub was off, or the internet was**, and an order reaches it more than 15 minutes after its time, the same day | It goes on the POS, so the sale is recorded, but it is **not sent to the kitchen**: it was probably made from GloriaFood's app already. The slip says NOT SENT TO THE KITCHEN. Send it from the order if it still has to be cooked; if somebody rang it in by hand meanwhile, void one of the two |
| **An order from an earlier day** reaches the hub (the key was put on days after the integration was made, or the hub was off overnight) | It is **not put on the POS**: it would land in the wrong day's sales. The slip says NOT ON THE POS and it is listed. It is in GloriaFood's own records; ring it in by hand if it should be in the POS's sales. Several of them at once share one slip |
| **An order cannot be put on the POS** (something in it this build cannot read) | It is tried again each minute, five times. Then the slip says NOT ON THE POS: look at it in GloriaFood's app and ring it in by hand |
| **Orders are listed as "it waits to be accepted in GloriaFood's app"** and stay that way after they were accepted | GloriaFood hands them over when they are placed and does not say again that they were accepted. Nothing of them is on the POS; after a quarter of an hour each alerts a manager. In GloriaFood's admin, set the integration's order status to **Accepted** alone ([An order that comes before it is accepted](#an-order-that-comes-before-it-is-accepted)); ring in by hand the ones that were made meanwhile |
| **GloriaFood's answer cannot be read at all** | It is kept as it came, and a slip says to look at GloriaFood's app (at most one slip a quarter of an hour) |
| **GloriaFood does not answer** when asked | Nothing is lost: it keeps the orders until the hub asks again. `hubctl online status` says since when and why ("refused the key", "did not answer in time") |
| **Pushes are turned away** (the key in GloriaFood's admin is not the one on the hub) | Nothing of them is read or kept. The orders arrive by the asking, a minute later than they could. `hubctl online status` counts the pushes turned away, and says so in plain words when orders come only by asking while pushes are turned away. Replace the key on the card GloriaFood push key (or `sudo hubctl online push key`) with the one in GloriaFood's admin, or make a new one and put it into both |
| **The door or the tunnel is down**, or the internet is | The same: the asking brings the orders once the hub can call out again. The tunnel's card under Keys and connections says whether it is connected and why not, as does `sudo hubctl online tunnel status`, and **Try it** says where the way in stops |
| **The test works, but GloriaFood's pushes never arrive**: nothing "sent by GloriaFood" and nothing "turned away" | The orders arrive by the asking. Something before the door is stopping the pushes. Look at the address in GloriaFood's admin first. With Cloudflare, look at its security log for that hostname: a setting that stops robots can stop GloriaFood's server too |
| **A push cannot be read** (the integration was set to XML, say) | It is kept as it came and listed with what it looked like. Where the hub also asks, no slip prints: the order is on its way by the asking, and a slip would have somebody ring it in a second time. On a hub that only takes pushes, a slip says to look at GloriaFood's app |
| **A push arrives and the hub cannot write it down** | GloriaFood is answered with an error, the order is held, and it is written down and put on the POS within the minute |

If the same order comes twice, by either way or both, it is one order on the POS.

## The first days

- Keep GloriaFood's own printing on, and hold each online order's tickets against GloriaFood's.
- Compare the check's total with GloriaFood's receipt. They should be equal to the cent, with at most a
  row named Rounding.
- Run `sudo hubctl online status` now and then. "To look at" should be empty or short. With push on, nearly
  every order should be counted as "sent by GloriaFood"; orders that keep arriving as "asked for" mean the
  push is not getting through.
- If an order went on wrong, `sudo hubctl online show <number>` prints it as GloriaFood sent it without the
  customer in it. That is what to send along when asking for a fix.

## What is kept, and what leaves the building

- **To GloriaFood goes the key for asking**, in a header, once a minute. No order, no customer, nothing of
  the POS. A push is answered with a count ("received: 1") or one word of error, and nothing else.
- **The keys** (for asking, for pushes, and the tunnel's token) live on the hub: sealed in its database
  when typed in the app (`hub-keys.md`, "Where a typed key is kept"), in `/opt/pos/.env` when put on in the
  terminal. They are in no log, no status, and not in the repository. A key made for pushes is shown once,
  on the screen it was made at. GloriaFood's own keys, which it puts on every order, are dropped before an
  order is written down.
- **The push door is handed a fingerprint of the key for pushes, not the key.** The tunnel's program is
  handed its token as it is, since it has to show it to Cloudflare: in a folder only the hub's own programs
  can read.
- **A try of the way in sends no key.** It sends one made-up word, good for half a minute and for that one
  try, to the address a manager typed.
- **With a tunnel, every pushed order passes through Cloudflare** on its way from GloriaFood to the hub,
  with the customer's name, number and address in it, as it already rests at GloriaFood. The tunnel is
  there to carry it, and nothing here asks Cloudflare to keep it; what Cloudflare itself does with what it
  carries is in its own terms, which are yours to read when you make the account.
- **A push without the key is not read**, not kept and not logged: only that it happened, when, and
  whether it carried no key or the wrong one.
- **Nothing of the POS is reachable through the way in but the door**, and the door answers one call.
- **Each order as it came** (name, number, address, e-mail, what the customer wrote) is kept on the hub
  for 30 days, in case an order has to be looked at again, and then dropped. What became of it stays.
- **On the POS order** go the name, the number, the address and the customer's notes: what a to-go order
  holds. The e-mail address and the customer's marketing consent are not copied.
- **Into the reservation book**, for a table that was booked, go the name, how many, the time, the number
  and the note, and they are kept as the book keeps any reservation: 30 days after its day
  (`reservations.md`). Nothing of it is sent anywhere, and nothing is sent to the guest.
- **The status, the slips and the hub's log** name no customer: an order is told of by its number.
- The customer's address is sent to no map service by this. (Staff can look the distance up from the
  order's form, as for any delivery.)
- The "ready" text goes to an online customer as to any other, where texting is set up
  (`counter-mode.md`).

## What is not built

- The alert is for managers and owners. Showing it to a host or a server would be a new line in **Who may
  do what**; it is not built. It makes no sound, and it is on the list of checks and the floor only: not on
  a kitchen screen, and not over an open check.
- A button on a screen to try an order again that would not go on the POS: it is rung in by hand.
- The screen names an order by GloriaFood's number, not by the number on the POS's check.
- Typing a note for the whole order on a screen (for a phone order, say). The strip shows one that came
  with the order; a dish's own note is typed as before.
- For a table booked on the website: what is listed at the end of
  [Tables booked on the website](#tables-booked-on-the-website).
- Telling GloriaFood anything back (that an order is ready, that a dish ran out).
- A second built-in way in beside the tunnel (a small receiver in the cloud that the hub collects from).
- Noticing that the door or the tunnel is down. The hub cannot see either from where it runs, so no screen
  says so: the orders arrive by the asking, and `sudo hubctl online status` and
  `sudo hubctl online tunnel status` say what is down. On a hub that only takes what GloriaFood sends and
  does not ask, nothing on a screen says when orders stop.
- With two hubs, sending pushes to whichever hub is taking the orders: a push to the hub in waiting is
  answered with an error, and the asking brings the order.
- An order from an earlier day is not put into that day's sales automatically.
- For several accounts ([Several accounts](#several-accounts)): a push key for each account (one opens the
  door for all of them); importing a second website's menu, so its dishes are found by number; keeping the
  testing account's orders out of the sales by themselves (they count until voided); a testing account's
  order on the pickup board and in a "ready" text reads as any order does; and a second account's key typed
  in the hub's terminal (it is typed in the app).

## For developers

Code: `backend/src/pos/online/` (`gloriafood.py` asks and reads, `inbox.py` writes down, `place.py` turns
an order into operations, `book.py` reads a booked table for the reservation book, `service.py` is the
minute's round and the push, `door.py` is the push door, `tunnel.py` keeps Cloudflare's program, `wayin.py`
is what the API hands the two and how it tries them), `backend/src/pos/api/online.py` (the calls, and
how an order is stored, numbered and printed). Tests: `backend/tests/online/`.

- **The way in, set in the app.** The API has no hold on the hub's containers and is given none (no Docker
  socket). So the door and the tunnel **run all the time**, idle without their secret, and the API hands
  each what it needs through a folder it shares with that one service (`pos.online.wayin.WayIn.hand`, called
  at start and by `pos.api.keys.use_keys` whenever `online_push` or `online_tunnel` changes, on the other
  hub of a pair within the minute):
  - `/door/key.json` (volume `pos-door`, read-only in the door): `{"sha256": "<hex>"}` or `{"sha256": null}`.
    `door.Told` looks at the file on every call (a stat, re-read when it changed), and `Door._judge` compares
    the SHA-256 of what a push carries in constant time. No file: the door goes by `POS_GLORIAFOOD_PUSH_KEY`,
    as before. A file it cannot read: shut.
  - `/tunnel/token` (volume `pos-tunnel`, mode 0600): the token as it is. `python -m pos.online.tunnel`
    (stdlib only, the compose service `tunnel`, in the hub's own image, which carries `cloudflared` copied
    from Cloudflare's image at build: build arg `CLOUDFLARED_IMAGE`, `POS_TUNNEL_IMAGE` in `.env`) looks
    every two seconds, runs `cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run` with the
    token in `TUNNEL_TOKEN` (never on the command line), asks its `/ready` whether it has a line, starts it
    again after 5, 10, 20 ... 300 seconds when it stops, and writes `/tunnel/status.json`: `{state, since_ms,
    reason, said, mark, version, beat_ms}`. `state` is `off`, `starting`, `connected` or `failing`; `reason`
    `refused`, `unreachable`, `slow`, `missing` or `trouble`; `mark` says which token it is about (the start
    of its SHA-256), so the API can tell a word about the token before; `beat_ms` every ten seconds, and no
    beat for 45 means no tunnel program (`WayIn.tunnel`). Cloudflare's program's lines go to the container's
    log with the token taken out of them.
  The keys are the slots `online_push` and `online_tunnel` of `pos.keys` (`tunnel_token` finds the token in
  a pasted command; `tunnel_of` reads the tunnel's id out of it for `shown.tunnel`). `GET /hub/keys` says
  `way_in`: `{address, door, tunnel_told, tunnel: {there, state, since_ms, reason, said, version}}`, and
  `GET /online/status` says `push.tunnel` (no `said`). `PUT /hub/online/push/address` keeps the setting
  `online_push_address` (`wayin.clean_address`: a DNS name only). `POST /hub/online/push/try` knocks
  (`WayIn.knock`) at `POS_DOOR_URL` and, with an address, at `https://<address>/online/push`, no redirect
  followed, with `OnlineOrders.expect()` (a word `try-...`, good for 30 seconds and once) where the key
  would be. The door hands a call without the key on with its header and an empty body, as it does for
  anybody; `OnlineOrders.admit` knows the word, answers the usual 401 and counts nothing; the call says in
  `tried` what `knocked_at_door` and `knocked_outside` made of what came back. `hubctl` puts a key in
  `.env` and takes the app's off (`app_key_off`), so the terminal's word holds. In the app: `WayIn`,
  `TunnelState`, `WayTried` (`lib/hub_keys.dart`), `PosApi.savePushAddress`, `tryWayIn`, `WayInDialog`,
  `makePushKey` and the page's own look at a tunnel on its way (`lib/screens/hub_keys_screen.dart`). Tests:
  `backend/tests/online/test_wayin.py`, `test_tunnel.py`, `apps/pos_app/test/hub_keys_test.dart` ("the way
  in for GloriaFood's pushes"), and CI's step "The hub's services together" runs the compose file.

- **An order that comes before it is accepted.** The inbox keys an order by GloriaFood's number, and a
  second arrival with a number it has is nothing (`Inbox.add` answers False). One exception:
  `Inbox.again(arrival)`, tried by `OnlineOrders._write_down` for every arrival that was here already. Where
  the row is `kept` or still `new`, its stored `raw` says another `status` than the arrival
  (`inbox.status_of`: no status reads as `accepted`), and the arrival does not say `pending`, the arrival's
  `raw` and `kind` are written over the row's and its state goes back to `new`, so the same round puts it
  on the POS or into the book; `fetched_ms`, `via` and `account` stay. It is then not counted as `known`.
  A row that is `placed`, `booked` or `failed` is never touched, and an order never goes back to pending.
  `place.unaccepted(order)` words an order that is not accepted, for `place.ops_for` and `book.wanted`:
  `place.WAITS` for `pending`, "it was not accepted (<status>)" otherwise. In the status a `kept` row whose
  `raw` says `pending` is listed (`look`) and is `new` only from `service.UNANSWERED_MS` (15 minutes)
  after it came, until somebody looks. Tests: `backend/tests/online/test_pending.py`, `test_inbox.py`.
  This was found on the restaurant's hub in November 2026: every order of an evening had come as `pending`
  with `accepted_at` and `fulfill_at` empty, seconds after it was placed. GloriaFood's pages list the
  statuses (`accepted`, `rejected`, `timed_out`, `pending`, `canceled`) and do not say when each is sent;
  that the accepted order follows the pending one is from other integrators' reports, not from its pages.

- **A booked table.** An arrival whose `type` is `table_reservation` or `order_ahead`
  (`book.RESERVATION_TYPES`) is handed to `OnlineOrders.book` instead of `put`. `book.wanted(order,
  now_ms=)` reads it (`persons`, `fulfill_at`, the name, `client_phone`, `instructions`) and raises
  `CannotPlace` (no size, no time: `failed` at once, with a slip) or `NotAnOrder` (not accepted, or its day
  is over: `kept`). `pos.api.online` hands what it read to `Reservations.take(booking_id, name, size,
  at_ms, phone=, note=, by_id="online", by="the website")`: the booking's id is `gf-<GloriaFood's id>`
  (`Booking.online` is the number after `gf-`, sent as `online` on every booking), one that is in the book
  under that id stands as it is, and what the book refuses (`too_many`, `too_far`) becomes `CannotPlace`
  with the book's words. The arrival's state is `booked`, counted as `booked` in a round's answer and in
  `today` of the status; its `order_id` stays empty. A `booked` row is to look at when there is something
  to say of it (`said`): it came after its time (`late`, which also prints a slip), its dishes were ordered
  ahead, or its phone number was left out. A `kept` row of these kinds is listed the day it came. The feed
  says `reservations` when one went into the book. No call on the wire writes a booking under such an id.
  In the app: `OnlineLook.isTable`, `inTheBook`, `lost`; `OnlineStatus.booked`, `OnlineAsked.booked`;
  `Booking.online`, `isOnline`, `bookedBy` (`lib/reservations.dart`); the row's mark is
  `booking-online:<id>` in `reservations_screen.dart`. Tests: `backend/tests/online/test_book.py`,
  `test_service.py` ("Tables booked on the website"), `backend/tests/test_reservations.py` (`take`),
  `apps/pos_app/test/online_status_test.dart`, `reservations_test.dart`.

- **Several accounts.** `pos.online.accounts`: the location setting `online_accounts`
  (`{"accounts": [{"id", "name", "test"}]}`, cleaned by `clean_accounts`; `accounts_of` always gives the
  first account, `main`, first), `slot_of`/`account_of_slot` between an account and the name its key is
  sealed under in `hub_key` (`online` for `main`, `online:<id>` for another; `pos.keys.slot_for`,
  `HubKeys.forget`). `pos.api.keys.online_setup(keys, settings)` gives a `GloriaFood(key, account=)` for
  every account that has a key, and `OnlineOrders(sources, inbox, accounts=)` asks each in `_round`, keeping
  when each was asked and answered (`_Asked`) and saying each in `accounts` of a round's answer and of the
  status (`id, name, test, configured, asked_ms, answered_ms, last_failure, came`). `use(sources, accounts)`
  exchanges them in place and keeps what is known of an account whose key did not change. An arrival keeps
  its `account` (column `account` of `online_order`, added on the fly); `(source, ext_id)` stays the one key,
  so an order two accounts hand over is one. A push is put to an account by `gloriafood.pushed_by(body,
  online.whose)`: `GloriaFood.owns(order)` compares the order's `restaurant_key` with the account's key in
  constant time (before the keys are taken out of what is written down), else `Inbox.account_of(restaurant
  id)` says which account an earlier order of that restaurant came from, else a hub with one account takes
  it for that one, else it names none (`""`). `Inbox.add` of an order that is here without an account and
  comes again with one (the asking, after such a push) writes the account beside it and changes nothing
  else, so `account_of` knows that restaurant from then on. `place.ops_for(..., origin=)` writes `account`, `store` and
  `test` into the order's `online` field, and `_Matcher` finds a dish by `gloriafood_id`, then by its exact
  name when one dish has it. `printing.service.online_store(state)` gives `(store, test)` for `Ticket`,
  `PackSheet` and the kitchen screen's ticket (`store`, `test`); `ticket.TEST_WORDS` are the two lines.
  `not_answering` in `trouble` is per account (`account`, `store`, `test`) when there are several, and never
  urgent for a testing account. Calls: `pos.api.keys` (`GET /hub/keys` lists `online_accounts`, `POST`,
  `PUT`, `DELETE /hub/online/accounts`). In the app: `OnlineAccount`, `HubKeys.accounts`
  (`lib/hub_keys.dart`), `OnlineAccountDialog` and the cards (`lib/screens/hub_keys_screen.dart`),
  `OnlineOrder.store`/`test`, `fromWhere`, `OnlineAccountAsked`, `OnlineStatus.severalAccounts`,
  `OnlineAsked.wordsFor` (`lib/online_orders.dart`), `TestOrderMark` (`lib/screens/online_strip.dart`),
  `KitchenTicket.store`/`test`. Tests: `backend/tests/online/test_accounts.py`, `backend/tests/test_keys.py`,
  `apps/pos_app/test/hub_keys_test.dart` ("several GloriaFood accounts"), `online_orders_test.dart`,
  `online_status_test.dart`.

- **The screens** read what the hub already sends and write nothing. `apps/pos_app/lib/online_orders.dart`:
  `OnlineOrder.of(fields)` is the order's `online` field (`Order.online`; null for an order rung in on a
  screen), `Order.note` its `note`, `paysHow` and `moneyWords` (`to_go_stages.dart`) the words for its
  money, `paidOnline` the hub's own payment (`elsewhere`, noted "Paid online"). The strip and what a tap
  shows are `lib/screens/online_strip.dart`; the list's globe is `_marked` in `orders_screen.dart`. A
  kitchen ticket's `note` (`GET /kitchen/screen`, `GET /kitchen/pass`) is `KitchenTicket.note`. Tests:
  `apps/pos_app/test/online_orders_test.dart`.

- **How they are doing, on the screens.** `GET /online/status` also says, on each `look` row, since when
  it is as it is (`at_ms`) and whether that is after somebody last looked (`new`; a row still being tried
  is not new until it is given up on, the moment its slip prints, and a push that could not be read is
  never new on a hub that also asks, as it prints no slip there), with `news` (how many are) and `seen_ms`;
  and `trouble`, what is wrong right now: `{code, since_ms, reason, urgent}`, `not_answering` once the
  asking has failed for `STALE_MS` (urgent unless a push got in and none was turned away after it) and
  `pushes_refused` (today's orders came only by the asking and a push was turned away after the last one
  that got in; never urgent, with `count`). `POST /online/seen` `{"by": "Mike"}` keeps when somebody
  looked and who in the setting `online_seen` and answers the status after it; like a screen's operations
  it takes no token, since it changes no order, no money and no setting anybody chose (503 `read_only` on
  a hub that cannot write). The change feed says the topic `online` when there is a new one to look at
  (`OnlineOrders.news`), slip or none, and when somebody looked. In the app: `OnlineStatus`, `OnlineLook`, `OnlineTrouble` (`lib/online_orders.dart`),
  `PosApi.onlineStatus` (null from an older hub) and `onlineSeen`, `LiveChange.online`,
  `lib/screens/online_orders_screen.dart` (the screen, and `OnlineAlertStrip`), `_readOnline` in
  `orders_screen.dart` (managers and owners only: told by the feed, and every half minute by the screen's
  own timer, since nothing announces that GloriaFood stopped answering). Tests:
  `backend/tests/online/test_look.py`, `apps/pos_app/test/online_status_test.dart`.

- **A push.** `POST /online/push` on the API, header `Authorization: <the key>` (`POS_GLORIAFOOD_PUSH_KEY`,
  compared in constant time, before the body is read), body as the answer to asking, at most 2 MB. 200
  `{"received": n}` once every order in it is written down and tried; 401 `refused`, 404 without a key on
  the hub, 413 `too_big`, 422 `unreadable`, 503 `standby` or `not_written`. `OnlineOrders.admit` lets it
  in, `OnlineOrders.push` takes it.
- **One path.** A push and a round both end in `_take` (write down, `Inbox.add` is False for one already
  here) and `_settle` (place what waits), under one lock. Asking GloriaFood happens outside that lock, so a
  push never waits for GloriaFood's answer. The order's fixed operation ids are the last line of defence.
- **The door.** `pos.online.door` (`uvicorn --factory pos.online.door:door_from_env`), the compose service
  `door` under the profile `push`, port 8090, published on `${POS_DOOR_BIND:-127.0.0.1}`. It hands
  `POST /online/push` with the key on to `http://api:8000/online/push`, and for one without the key only
  its header with an empty body, so the API counts it. Everything else is 404 with no body.
- **The tunnel.** The compose service `tunnel` (`cloudflare/cloudflared`, profile `tunnel`,
  `POS_TUNNEL_TOKEN`), on a network of its own with the door.
- **Asking.** `POST https://pos.globalfoodsoft.com/pos/order/pop`, headers `Authorization: <key>`,
  `Accept: application/json`, `Glf-Api-Version: 2`, no body. Answer `{"count": n, "orders": [...]}`.
  Only a hub whose database is writable asks, since an order is handed over once.
- **The inbox.** Table `online_order`: the order as it came (`raw`, dropped after 30 days), how it came
  first (`via`: `push` or `poll`), its state (`new`, `placed`, `booked`, `kept`, `failed`), the POS order it became,
  what there is to say of it, and how often it was tried.
- **The order.** `gf-<GloriaFood's id>`, written by the device `online`. Its operations have fixed ids
  (`gf-<id>:create`, `:line-N`, `:off`, `:tip`, `:difference`, `:paid`, `:fire`, ...), so the same order
  can never be written twice. Fields: `order_type: takeout`, `channel: online`, `customer_name`, `phone`,
  `promised_at`, `quoted_minutes`, `note`, and for a delivery `handover`, `address`, `event_note`,
  `delivery_fee: {by: "online", up_to: null, amount, taxed}`. `online: {source, id, type, payment,
  total}` says where it came from; only the hub can write that field (`place.own_word`).
- **A line** carries `priced` as the menu engine made it, with `unit_price` and each choice's price
  replaced by GloriaFood's (`priced.online.menu_price` keeps the POS's own when it differs). A line as
  written has `priced.online.as_written` and no `request`, so a screen does not offer to change its
  choices.
- **Charges.** The evening rows use the tax class `untaxed` (`orders/check.py`), codes `online_rounding`
  and `online_difference`.
- **The website's payment.** GloriaFood sends `payment` (`ONLINE`, `CASH`, `CARD`, `CARD_PHONE`) and
  `used_payment_methods`, a **list of those same words**: one as a rule, two for a payment that was split
  (`place._ways_paid` takes both together). `gateway_type` ("Apple Pay") is only the name of how the
  website took it. Nothing but `ONLINE`: the `pay` operation `:paid`, for the order's whole total.
  `ONLINE` beside another way, or beside something that is none of GloriaFood's words: no payment is
  written, and the order says which of the two it is. The list was once read as a count, and every order
  paid on the website came out not paid.
- **Calls.** `POST /online/push`, `GET /online/status` (with `push`: `configured`, `pushed_ms`, `refused`;
  `today.by_push`, `today.by_poll`, `today.unread`), `POST /online/fetch` (409 `no_key`; `known` counts the
  orders that were here already; `answered` and `reason` say whether GloriaFood answered; `soon` is a
  press within `ASK_GAP_MS` of the last asking, which asks nobody: `OnlineOrders.ask_now`; the app's
  `PosApi.onlineFetch` and `OnlineAsked`), `GET /online/orders/{id}` (404 `unknown_order`, 410 `forgotten`).
- **Printing.** `Ticket.note` and `PackSheet.said` carry the customer's note; a `notice` ticket is the
  slip (`PrintService.notice`). The kitchen screen's tickets carry `note` too.
