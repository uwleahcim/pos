# Online orders

An order a customer places on the restaurant's own website (GloriaFood) goes on the POS by itself, as a
to-go order like any other (`counter-mode.md`, `delivery.md`): numbered, with the customer's name and
number, its dishes, what it cost, and whether it was paid. Its kitchen tickets print by themselves. Nobody
types it in.

This is the hub's half. The screens show such an order as they show any to-go order; what they do not show
yet is listed under [What is not built](#what-is-not-built).

**Nothing here was tried against GloriaFood itself.** It was written from GloriaFood's own description of
how a POS collects orders, and tested against orders made up in that shape from the restaurant's real
menu. The first real orders are the test: see [The first days](#the-first-days).

## How it works

Staff accept an online order in GloriaFood's own app, as they do today. That does not change.

Once a minute the hub asks GloriaFood: "any orders accepted since I last asked?" The question carries the
restaurant's key and nothing else. GloriaFood answers with the orders, and hands each one over **once**. So
the first thing the hub does with an order is write it down as it came. Only then does it put it on the
POS:

- It becomes a to-go order, channel **Online**, with the next order number of the day.
- It is sent to the kitchen at once, so each station's ticket prints, and the takeout counter's copy of
  the whole order with PAID or NOT PAID on it.
- An order the customer wants **later** is sent too, and its tickets wait: they print as long before its
  time as the location's quote for online orders says (25 minutes unless changed; 45 for a delivery), as
  any order taken ahead does (`catering.md`).

It works from behind the restaurant's router: the hub calls out, nothing calls in.

## Turning it on

Three steps. The first is yours alone: the key is made in your GloriaFood account.

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

Without a key the hub asks nobody, and everything is as it was.

| Command | What it does |
| --- | --- |
| `sudo hubctl online key` | Puts the key on the hub (asked for, never shown, never on the command line) |
| `sudo hubctl online status` | Whether the hub has the key, when GloriaFood last answered and why it did not, today's online orders by what became of them, and the ones to look at |
| `sudo hubctl online fetch` | Asks GloriaFood now instead of within the minute |
| `sudo hubctl online show 123456` | One order as GloriaFood sent it, by GloriaFood's number, with everything of the customer taken out: for looking at an order that went on wrong |
| `sudo hubctl online forget` | Takes the key off the hub: it asks nobody. Orders already on the POS stay |

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

## When something is off

Nothing is dropped quietly. Whatever is not on the POS as a normal order prints a slip, **LOOK**, where the
to-go orders print, and is listed by `sudo hubctl online status`.

| What happened | What the hub does |
| --- | --- |
| **The hub was off, or the internet was**, and an order reaches it more than 15 minutes after its time, the same day | It goes on the POS, so the sale is recorded, but it is **not sent to the kitchen**: it was probably made from GloriaFood's app already. The slip says NOT SENT TO THE KITCHEN. Send it from the order if it still has to be cooked; if somebody rang it in by hand meanwhile, void one of the two |
| **An order from an earlier day** reaches the hub (the key was put on days after the integration was made, or the hub was off overnight) | It is **not put on the POS**: it would land in the wrong day's sales. The slip says NOT ON THE POS and it is listed. It is in GloriaFood's own records; ring it in by hand if it should be in the POS's sales. Several of them at once share one slip |
| **An order cannot be put on the POS** (something in it this build cannot read) | It is tried again each minute, five times. Then the slip says NOT ON THE POS: look at it in GloriaFood's app and ring it in by hand |
| **GloriaFood's answer cannot be read at all** | It is kept as it came, and a slip says to look at GloriaFood's app (at most one slip a quarter of an hour) |
| **GloriaFood does not answer** | Nothing is lost: it keeps the orders until the hub asks again. `hubctl online status` says since when and why ("refused the key", "did not answer in time") |

GloriaFood sends an order once. If the same order ever comes twice, it is one order on the POS.

## The first days

- Keep GloriaFood's own printing on, and hold each online order's tickets against GloriaFood's.
- Compare the check's total with GloriaFood's receipt. They should be equal to the cent, with at most a
  row named Rounding.
- Run `sudo hubctl online status` now and then. "To look at" should be empty or short.
- If an order went on wrong, `sudo hubctl online show <number>` prints it as GloriaFood sent it without the
  customer in it. That is what to send along when asking for a fix.

## What is kept, and what leaves the building

- **To GloriaFood goes the key**, in a header, once a minute. No order, no customer, nothing of the POS.
- **The key** lives in `/opt/pos/.env` on the hub. It is in no log, no status, and not in the repository.
  GloriaFood's own keys, which it puts on every order, are dropped before an order is written down.
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

- On the screens: a mark that says an order came from the website, "Paid online" in words, the customer's
  note on the order's own screen, how online orders are doing under Location, and an alert when one comes
  in or needs looking at. An online order shows today as any to-go order does, under the channel Online.
- Reservations from GloriaFood into the reservation book.
- Telling GloriaFood anything back (that an order is ready, that a dish ran out).
- An order from an earlier day is not put into that day's sales automatically.

## For developers

Code: `backend/src/pos/online/` (`gloriafood.py` asks, `inbox.py` writes down, `place.py` turns an order
into operations, `service.py` is the minute's round), `backend/src/pos/api/online.py` (the calls, and how
an order is stored, numbered and printed). Tests: `backend/tests/online/`.

- **Asking.** `POST https://pos.globalfoodsoft.com/pos/order/pop`, headers `Authorization: <key>`,
  `Accept: application/json`, `Glf-Api-Version: 2`, no body. Answer `{"count": n, "orders": [...]}`.
  Only a hub whose database is writable asks, since an order is handed over once.
- **The inbox.** Table `online_order`: the order as it came (`raw`, dropped after 30 days), its state
  (`new`, `placed`, `kept`, `failed`), the POS order it became, what there is to say of it, and how often
  it was tried.
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
- **Calls.** `GET /online/status`, `POST /online/fetch` (409 `no_key`), `GET /online/orders/{id}` (404
  `unknown_order`, 410 `forgotten`).
- **Printing.** `Ticket.note` and `PackSheet.said` carry the customer's note; a `notice` ticket is the
  slip (`PrintService.notice`). The kitchen screen's tickets carry `note` too.
