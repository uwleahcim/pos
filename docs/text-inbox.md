# Texts with customers

A customer can text the restaurant's number, and the staff read it and answer on the POS. It was asked for
by Mike on 2026-11-27: "since I use twilio for sip trunking, might as well implement full feature messaging
on the POS. I want my POS to support two way SMS/MMS/RCS messaging", and what it is for: "allow two way
communication other than phone calls", "thus it can be used to take orders", "make reservations".

It uses the Twilio account the hub already sends the order texts with (`texts.md`). Nothing new is typed:
a hub that has the account has the conversations.

## What is on the screens

- **Texts**, on the Orders screen: a speech bubble in the bar with the number of conversations that hold
  something nobody has read. On a phone it stands in the bar while something waits, and in the three-dot
  menu otherwise.
- **The list**: one line for each customer, the one with the newest text on top: their name where the POS
  knows the number (from an order, a reservation or the guest list), the number otherwise, the newest text,
  and a dot while something of theirs is not read. The box above it finds a name, a number or a word of a
  text.
- **A conversation**: the customer's texts on the left, the restaurant's on the right, the newest at the
  bottom. Under each of ours: who sent it, when, and what became of it (Sending, Sent, Delivered, Read, or
  Not sent with the reason). A picture the customer sent shows small; a tap shows it large. On a Mac or an
  iPad the list stays beside the conversation; on a phone the conversation comes over the list.
- **Answering**: type in the box at the bottom, Send. **New text** (the bubble with a plus) starts a
  conversation with a number that has none.
- **Start order** and **Book a table**, at the top of a conversation: the to-go form, or the reservation
  form, comes up with that customer's number and name filled in. This is how an order or a table is taken
  by text: read what they want, tap, ring it in.
- **On a to-go order**: a line under the title, "Text Pat". It opens the conversation with that order's
  customer, and says "New text: ..." in colour while they wrote something nobody has read.
- The POS's own texts to an order (ready, on its way, a new time: `texts.md`) are in the same
  conversation, marked "The POS: order ready". So a customer who answers "5 minutes away" to the ready text
  is answering in a place somebody reads.

Opening a conversation reads it for everybody: the dot goes on every screen.

## Who may

A power, **Text with customers**, in Location › Who may do what (`roles.md`). To start: servers,
bartenders, hosts and cashiers, and a manager and an owner as always. The kitchen and the drivers do not
see the button. A manager changes that table like any other row of it.

Nobody types a PIN to read the texts: the screen says who is signed in, as it does for the notes of the
shift. The hub writes down who sent each text and who opened a conversation.

## How a text reaches the hub

Twilio would rather call the restaurant the moment a text comes: it wants an address on the internet to
call. The hub has none: it stands behind the restaurant's router, and the tunnel that would give it one
(`online-orders.md`, "Push") is not set up.

So the hub asks instead. Every **5 seconds** while a screen is on (every 30 with none), it asks Twilio for
the account's texts since a little before it last asked, and writes down the ones it does not have. A
customer's text therefore shows on the POS within a few seconds, and nothing outside the building has to
be set up for it.

- A hub that was off, or had no internet, catches up when it is back: it asks for everything since it last
  heard, three days back at the most.
- A hub that cannot reach Twilio says so over the list ("Twilio is not answering the hub"), with Twilio's
  reason where it gave one.
- Only the texts of the number the POS texts from are taken: another number of the same Twilio account
  (the fax line) is none of the POS's business. Where **Send from** is a Messaging Service, every number
  of that service is the restaurant's.
- A text the restaurant's number sent that the POS did not (from Twilio's console, another program,
  Twilio's own answer to STOP) is shown in the conversation too, marked "From the restaurant's number, not
  the POS".
- With two hubs, the one that has the database asks. Both show the same conversations.

Instant delivery (Twilio calling the hub through the tunnel) is the next piece: see "What is not built".

## The first text to a number

A text somebody types to a number that never texted the restaurant, and was never texted by the POS, goes
out with who it is from in front and how to stop it behind:

    China Sky: Your order is on the shelf.
    Reply STOP to opt out.

The screen shows it that way before Send is tapped. Every text after it, and every answer to a customer
who wrote first, goes exactly as typed. The POS's own order texts are not changed: they are the words they
always were.

## STOP

A customer who answers STOP (or STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT, REVOKE, OPTOUT) gets no more
texts. Twilio stops them by itself, for every text of the account. The POS reads the word and says so: the
conversation is marked STOP in the list, and where the box to type in was it says "Pat answered STOP. No
text goes to them until they text START." A text sent to them anyway (an order's ready text) comes back
"the customer answered STOP", and marks the conversation too.

START, UNSTOP or YES from that customer opens it again.

## What it is for, and what it is not for

One customer at a time, about their order, their table, their question. **There is no way to text many
customers at once, and none is planned without Mike's word:** a text that sells something needs the
customer's written consent first under the phone companies' rules and the law (the TCPA), and the
registration of the restaurant's number at Twilio (A2P 10DLC) names what kind of texts it sends. Look at
it in Twilio's console under Messaging › Regulatory Compliance: its campaign should cover conversations
with customers (Twilio calls that use Customer Care; a Low Volume Mixed campaign covers it as well). If
it names order updates alone, the phone companies may filter the staff's answers.

## Pictures (MMS)

- **Coming in**: a picture a customer sends shows in the conversation. Twilio keeps it; the hub fetches it
  the first time somebody looks, and keeps its own copy for 30 days so the next look is quick. A file that
  is no picture (a contact card, a video) is named and not opened.
- **Going out**: not yet. Twilio fetches a picture to send from an address on the internet, which the hub
  does not have until the tunnel is set up. It comes with instant delivery.

## RCS

RCS is the newer kind of text: the restaurant's name and logo at the top instead of a number, "read"
under a text, and no cutting of long texts. Nothing more is built for it than this, because Twilio does
the rest:

- The POS sends through whatever **Send from** says (`texts.md`, "Setting it up"). Where that is a
  Messaging Service (it begins with `MG`) that has an RCS sender, Twilio sends by RCS to a phone that takes
  it, and as a plain text to one that does not. Nothing changes on the POS.
- A text that came or went by RCS says "RCS" under it, and "Read" when the customer's phone said so.

**What the restaurant must do at Twilio, which nobody can do for it:**

1. In Twilio's console, under Messaging, create an RCS sender. It asks for the name to show, a logo (224
   by 224 pixels, under 50 KB), a banner (1140 by 448), a colour, a description, a phone number and
   website for customers, and links to a privacy policy and terms of service that mention text messages.
2. Twilio and the phone companies check it against the business's legal name and EIN. **Four to six weeks
   at the least**, and each phone company approves by itself.
3. Add the approved sender to the Messaging Service, and put that service's SID (`MG...`) in **Send from**
   on the POS (Location › Keys and connections › Texts to customers) if the number is there now.

Until then every text is a plain SMS or MMS, which is what the POS does today. On iPhones RCS from a
business depends on Apple and the phone company as well: some customers will get plain texts for a long
time.

Rich RCS (cards with buttons, carousels) is not built.

## One thing to check at Twilio

A Twilio number can be set to answer every text by itself, and a new number is: it answers "Thanks for
the message. Configure your number's SMS URL to change this message." Twilio's console › Phone Numbers ›
Manage › Active numbers › the number › Messaging › "A message comes in": if an address is named there
(Twilio's own starts with `demo.twilio.com`), or a Studio flow that answers, customers get that answer as
well as the staff's, and it shows in the conversation as "From the restaurant's number, not the POS".
Empty the box and save, unless that answer is wanted. Where the number is in a Messaging Service, look at
the service's Integration page too: "Defer to sender's webhook" leaves it to the number's own box.

## What the hub keeps

This is new. Until now the hub kept no number and no words of a text (`texts.md` said so). A conversation
cannot be shown without them, so the hub now keeps, in its own database in the building:

- every text of the restaurant's number, in and out: the customer's number, the words, when, what became
  of it, who typed it and on which device, and for an order's text which order;
- for each customer's number: the name the POS knows it by, who last opened the conversation, and whether
  they answered STOP;
- a copy of each picture somebody looked at, for 30 days.

They are kept until somebody decides otherwise: there is no button that deletes a conversation yet, and
nothing is removed by itself except the pictures. The database is copied to the second hub like everything
else in it. Twilio keeps its own record of every text and picture, under its own terms.

## What leaves the building

Only to Twilio, and only what a text is: the customer's number, the words somebody typed, and for the
first text the restaurant's name. The hub asks Twilio for the account's list of messages with the same key
it sends with.

## When something does not go

- **A text that was not sent** stays in the conversation in red with the reason ("Not sent: the customer
  answered STOP"). The reasons are the ones in `texts.md`, "When a text does not go". It is not sent again
  by itself: type it again once the reason is gone.
- **The hub cannot be reached** as Send is tapped: the words stay in the box.
- **A tap sent twice** (a slow network) is one text: each carries the screen's own name for it.
- **No more than 300 texts an hour** leave the hub, the order texts counted in: the same guard as before.
  The guard against the same words to the same number within ten minutes is for the order texts only: a
  person may say "Yes" twice.
- A hub with no Twilio account shows the Texts button to a manager alone, and says there where the account
  is typed.

## What it costs

Twilio bills each text sent and each one received, and more for a picture. Asking Twilio for the list of
messages costs nothing.

## What is not built

- **Instant delivery, and sending pictures.** Both need Twilio to reach the hub from the internet: the
  Cloudflare tunnel of `online-orders.md`, with Twilio's signature checked on every call. Next.
- **Texting many customers at once**, offers, a newsletter. See above.
- A text to a party on the waitlist that its table is ready, or to confirm a reservation, sent by itself.
  Somebody can type either.
- Ready-made answers ("We open at 11"), and an answer when the restaurant is closed.
- A sound or a notification when a text comes: the number on the button is all.
- Deleting a conversation, or keeping texts only so long.
- Blocking a number.
- Group texts: each person's texts are their own conversation.
- Rich RCS: cards, buttons, carousels.
- WhatsApp and other channels of Twilio's.
- Texting with no hub answering: the conversations are kept there.

## Not yet tried against the real Twilio

The tests stand a pretend Twilio in for the real one, answering as Twilio's pages say it does. Nothing was
read from or sent through a real account from here. The first text from a real phone is the proof. If it
does not show within half a minute, the line over the list says whether Twilio answers the hub, and
`sudo hubctl logs api` says what the hub heard.

## The calls

Who may: the roles that hold the power `texts`. Staff have no token: a screen passes who is signed in
(`staff_id`). 404 `unknown_staff`, 403 `not_allowed`.

| Call | What it does |
| --- | --- |
| `GET /texts?staff_id=&q=&limit=` | The conversations, the one with the newest text first: `phone` (+17815550142), `digits`, `name`, `unread`, `stopped_ms`, `last`. Beside them `on` (the hub has a Twilio account), `number` (what the restaurant texts from), `unread` (conversations not read) and `listening` (`ok`, `at_ms`, `said`) |
| `GET /texts/unread?staff_id=` | `on` and `unread` alone, for the button |
| `GET /texts/with/{number}?staff_id=&before_ms=&limit=` | One conversation: `thread`, `texts` the oldest first (the newest hundred, or those before `before_ms`), `more`, and `wrap` (`before`, `after`): what a first text goes with around it. A text: `id`, `inbound`, `body`, `at_ms`, `state` (`received`, `waiting`, `sent`, `delivered`, `read`, `failed`), `channel` (`sms`, `mms`, `rcs`), `pictures` (`n`, `type`, `image`), `code`, `said`, `kind` (empty: typed; `ready`, `out`, `delayed`: the POS's own; `elsewhere`), `order_id`, `by` |
| `POST /texts/with/{number}` | `{staff_id, body, device, id, name}`: sends. The answer is the text, `waiting`. 409 `no_service`, 409 `stopped`, 422 `no_number`, `no_text`, `too_long`, `bad_id` |
| `POST /texts/with/{number}/read` | `{staff_id}`: the conversation was opened |
| `GET /texts/picture/{id}/{n}?staff_id=` | A picture of a text. 404 `unknown_picture`, 502 `not_fetched` |

The change feed says `texts` when a text came, one went, one was delivered or was not, or a conversation
was read (`GET /live`).

The code: `backend/src/pos/texts.py` keeps the conversations and makes the rules (`Texts`), and asks Twilio
(`Listener`); `backend/src/pos/twilio.py` reads Twilio's list and its pictures (`heard`, `pictures_of`,
`picture`) and sends a typed text (`deliver`); `backend/src/pos/api/texts.py` is the calls. In the app:
`lib/texts.dart`, `lib/screens/texts_screen.dart`, and the button on `lib/screens/orders_screen.dart`.
Tests: `backend/tests/test_text_inbox.py`, `apps/pos_app/test/texts_test.dart`.

## An older hub, an older app

An app newer than its hub shows no Texts button and no line on a to-go order. A hub newer than its apps
keeps the conversations all the same, and the order texts go as before. Update the hub first.
