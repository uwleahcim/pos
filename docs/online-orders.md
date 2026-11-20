# Online orders

An order a customer places on the restaurant's own website (GloriaFood) goes on the POS by itself, as a
to-go order like any other (`counter-mode.md`, `delivery.md`): numbered, with the customer's name and
number, its dishes, what it cost, and whether it was paid. Its kitchen tickets print by themselves. Nobody
types it in.

This is the hub's half. The screens show such an order as they show any to-go order; what they do not show
yet is listed under [What is not built](#what-is-not-built).

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
   in your admin), add a custom integration, and pick the template **Poll Accepted Order v2**. Saving it
   shows a key. Copy it.
2. **Put it on the hub.** On the hub, after `sudo hubctl update`:

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
| `sudo hubctl online fetch` | Asks GloriaFood now instead of within the minute |
| `sudo hubctl online show 123456` | One order as GloriaFood sent it, by GloriaFood's number, with everything of the customer taken out: for looking at an order that went on wrong |
| `sudo hubctl online forget` | Takes the key for asking off the hub: it asks nobody. Orders already on the POS stay |
| `sudo hubctl online push key` | Puts the key GloriaFood's pushes carry on the hub and opens the push door. Asked for and never shown; press Enter alone and the hub makes one, shown once, for you to put into GloriaFood's admin |
| `sudo hubctl online push test` | Sends an empty push through the door and says whether it got in. With an address (`sudo hubctl online push test https://orders.example.com/online/push`) it goes out to the internet and back in, the whole way GloriaFood's pushes will take. Nothing is put on the POS |
| `sudo hubctl online push forget` | Takes that key off the hub and shuts the door and the tunnel: the hub only asks |
| `sudo hubctl online tunnel token` | Puts a Cloudflare Tunnel's token on the hub (asked for, never shown) and starts the tunnel |
| `sudo hubctl online tunnel status` | Whether the tunnel is connected, and its last words when it is not |
| `sudo hubctl online tunnel forget` | Stops the tunnel and takes its token off the hub |

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

The door starts when the key is put on, and listens only on the hub itself.

### The way in

**Built in: a Cloudflare Tunnel.** The hub calls out to Cloudflare and holds the line open; GloriaFood
sends to an address at Cloudflare, and the push comes down the line to the door. Nothing is opened on your
router. As this is written Cloudflare does not charge for it; look when you make the account. It needs a
Cloudflare account, which is yours to make, and a domain name whose DNS is kept at Cloudflare (a name you
own that is not there yet has to be moved there, or another name bought there). Orders pass through
Cloudflare's machines on their way: see [What is kept](#what-is-kept-and-what-leaves-the-building).

**Or your own.** Anything that brings an HTTPS address to the door works: another tunnel program installed
on the hub (pointed at `http://127.0.0.1:8090`), or your own router and a proxy that holds the certificate.
For a proxy on another machine, put `POS_DOOR_BIND=0.0.0.0` into `/opt/pos/.env` and run `sudo hubctl
update`: the door then listens on the restaurant's network too, at the hub's address, port 8090. The door
speaks plain HTTP; the HTTPS must end at the proxy. Forward to port 8090 only, never to 8000.

### Turning push on

After `sudo hubctl update`, and with the asking already on.

1. **The key.** On the hub:

   ```
   sudo hubctl online push key
   ```

   Press Enter alone. The hub makes a key and shows it once: copy it for step 4. (If GloriaFood's admin
   turns out to show a master key of its own instead of asking for one, run the command again and paste
   GloriaFood's.) The door is open from now on, and the command tries it.
2. **The tunnel, at Cloudflare.** In Cloudflare's dashboard, under Zero Trust, Networks, Tunnels, create a
   tunnel of the kind "Cloudflared" and give it a name (`pos-hub1`). Cloudflare shows a command to install
   it, with one very long word in it that starts with `eyJ`. That word is the tunnel's token; copy only
   that. Then on the hub:

   ```
   sudo hubctl online tunnel token
   ```

   It asks for the token, does not show it, and says when the tunnel has reached Cloudflare.
3. **The address.** Back at Cloudflare, give the tunnel a public hostname: a subdomain (`orders`), your
   domain, the path `online/push`, the service type **HTTP** and the address **`door:8090`**. Exactly
   that address: it is the door, and the only thing of the hub the tunnel should ever be told about. Then
   try the whole way in:

   ```
   sudo hubctl online push test https://orders.example.com/online/push
   ```

   with your own name in it. It should say "the whole way in works".
4. **GloriaFood.** In GloriaFood's restaurant admin, where the integrations are, add a custom integration
   with the template **Push Accepted Order**: the address from step 3 as the endpoint, the key from step 1
   as the master key, the format **JSON**, version 2. Leave "Poll Accepted Order v2" as it is: that is the
   net.
5. **Look.** Place a small test order and accept it. It is on the POS before you have put the phone down,
   and `sudo hubctl online status` counts it as "sent by GloriaFood".

The labels in Cloudflare's and GloriaFood's pages may read a little differently from these.

### What is not known yet

GloriaFood's pages leave these open, and the first real orders will answer them. None of them can lose an
order while the asking is on.

- **Whether its admin asks for the master key or shows its own.** The command takes either.
- **How a push is wrapped.** The hub reads what GloriaFood answers when asked (`{"count": 1, "orders":
  [...]}`), one order by itself, and a bare list. Anything else is kept as it came and listed in the
  status with what it looked like, and the order arrives by the asking.
- **What GloriaFood does when a push does not get through**, and for how long it tries again. Nothing
  depends on it: the asking brings the order within the minute.
- **Whether an order that was pushed is also handed over when asked.** If it is, the hub sees it twice and
  it is one order. If it is not, the asking brings only what the push missed, which is all it is for.
- **Whether GloriaFood sends anything a second time when an order changes** after it was accepted. The
  first arrival stands; a later one with the same number changes nothing on the POS.

## Two things to change once it is on

- **Do not also ring online orders in by hand.** The sale would be on the POS twice.
- **GloriaFood's own printing.** If GloriaFood prints the kitchen's tickets today, leave that on for the
  first days and hold its paper against the POS's. Once they agree, turn GloriaFood's printing off, or
  every online order prints twice.

## What arrives

**Pickup and delivery orders that were accepted.** Nothing else:

- A table reservation, a table booked with its dishes ordered ahead, and an order placed from a table are
  left where they are, in GloriaFood's app. (Reservations into the book is a later piece.)
- An order nobody accepted, or one that was rejected, never reaches the hub.

### The dishes

Each dish is found on the POS's menu by GloriaFood's own number for it, which the menu import kept
(`menus.md`). Its size and its choices are found the same way. So the kitchen's ticket reads as if the
dish had been rung in at a screen: the kitchen's own name for it, at its own station.

- **The price is the website's**, always. The customer was shown it and agreed to it, and the dining
  room's price can differ.
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
| Paid on the website | A payment, **Paid online**, recorded on the day as money taken outside the POS. The ticket says PAID |
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

**On a kitchen screen** the customer's note heads the ticket in a dark band, "Customer's note · …", under
any allergy and before the dishes, as the paper has it under CUSTOMER'S NOTE. It is shown whole, however
long it is: it may say an allergy. It is on every station's ticket for the order, and on the pass.

The note is what the customer typed. It is not the allergy block: nobody at the restaurant has read it and
picked the allergens, so it does not turn any dish red. Read it.

## When something is off

Nothing is dropped quietly. Whatever is not on the POS as a normal order prints a slip, **LOOK**, where the
to-go orders print, and is listed by `sudo hubctl online status`.

| What happened | What the hub does |
| --- | --- |
| **The hub was off, or the internet was**, and an order reaches it more than 15 minutes after its time, the same day | It goes on the POS, so the sale is recorded, but it is **not sent to the kitchen**: it was probably made from GloriaFood's app already. The slip says NOT SENT TO THE KITCHEN. Send it from the order if it still has to be cooked; if somebody rang it in by hand meanwhile, void one of the two |
| **An order from an earlier day** reaches the hub (the key was put on days after the integration was made, or the hub was off overnight) | It is **not put on the POS**: it would land in the wrong day's sales. The slip says NOT ON THE POS and it is listed. It is in GloriaFood's own records; ring it in by hand if it should be in the POS's sales. Several of them at once share one slip |
| **An order cannot be put on the POS** (something in it this build cannot read) | It is tried again each minute, five times. Then the slip says NOT ON THE POS: look at it in GloriaFood's app and ring it in by hand |
| **GloriaFood's answer cannot be read at all** | It is kept as it came, and a slip says to look at GloriaFood's app (at most one slip a quarter of an hour) |
| **GloriaFood does not answer** when asked | Nothing is lost: it keeps the orders until the hub asks again. `hubctl online status` says since when and why ("refused the key", "did not answer in time") |
| **Pushes are turned away** (the key in GloriaFood's admin is not the one on the hub) | Nothing of them is read or kept. The orders arrive by the asking, a minute later than they could. `hubctl online status` counts the pushes turned away, and says so in plain words when orders come only by asking while pushes are turned away. `sudo hubctl online push key` puts the right key on |
| **The door or the tunnel is down**, or the internet is | The same: the asking brings the orders once the hub can call out again. The status says when the door is not running, and `sudo hubctl online tunnel status` what the tunnel last said |
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
- **The keys** (for asking, for pushes, and the tunnel's token) live in `/opt/pos/.env` on the hub. They
  are in no log, no status, and not in the repository. A key the hub makes is shown once, on the screen it
  was made at. GloriaFood's own keys, which it puts on every order, are dropped before an order is written
  down.
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
- **The status, the slips and the hub's log** name no customer: an order is told of by its number.
- The customer's address is sent to no map service by this. (Staff can look the distance up from the
  order's form, as for any delivery.)
- The "ready" text goes to an online customer as to any other, where texting is set up
  (`counter-mode.md`).

## What is not built

- On the screens: how online orders are doing under Location, and an alert when one comes in or needs
  looking at. Today only `hubctl online status` and the LOOK slips say.
- The day's report and Sales count money paid on the website under **Paid elsewhere**, with whatever else
  was paid outside the POS. A row of its own for it is not built.
- Typing a note for the whole order on a screen (for a phone order, say). The strip shows one that came
  with the order; a dish's own note is typed as before.
- Reservations from GloriaFood into the reservation book.
- Telling GloriaFood anything back (that an order is ready, that a dish ran out).
- A second built-in way in beside the tunnel (a small receiver in the cloud that the hub collects from).
- Telling the staff on a screen when pushes stop getting through: today only `hubctl online status` says.
- With two hubs, sending pushes to whichever hub is taking the orders: a push to the hub in waiting is
  answered with an error, and the asking brings the order.
- An order from an earlier day is not put into that day's sales automatically.

## For developers

Code: `backend/src/pos/online/` (`gloriafood.py` asks and reads, `inbox.py` writes down, `place.py` turns
an order into operations, `service.py` is the minute's round and the push, `door.py` is the push door),
`backend/src/pos/api/online.py` (the calls, and how an order is stored, numbered and printed). Tests:
`backend/tests/online/`.

- **The screens** read what the hub already sends and write nothing. `apps/pos_app/lib/online_orders.dart`:
  `OnlineOrder.of(fields)` is the order's `online` field (`Order.online`; null for an order rung in on a
  screen), `Order.note` its `note`, `paysHow` and `moneyWords` (`to_go_stages.dart`) the words for its
  money, `paidOnline` the hub's own payment (`elsewhere`, noted "Paid online"). The strip and what a tap
  shows are `lib/screens/online_strip.dart`; the list's globe is `_marked` in `orders_screen.dart`. A
  kitchen ticket's `note` (`GET /kitchen/screen`, `GET /kitchen/pass`) is `KitchenTicket.note`. Tests:
  `apps/pos_app/test/online_orders_test.dart`.

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
  first (`via`: `push` or `poll`), its state (`new`, `placed`, `kept`, `failed`), the POS order it became,
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
- **Calls.** `POST /online/push`, `GET /online/status` (with `push`: `configured`, `pushed_ms`, `refused`;
  `today.by_push`, `today.by_poll`, `today.unread`), `POST /online/fetch` (409 `no_key`; `known` counts the
  orders that were here already), `GET /online/orders/{id}` (404 `unknown_order`, 410 `forgotten`).
- **Printing.** `Ticket.note` and `PackSheet.said` carry the customer's note; a `notice` ticket is the
  slip (`PrintService.notice`). The kitchen screen's tickets carry `note` too.
