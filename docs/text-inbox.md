# Texts with customers

A customer can text the restaurant's number, and the staff read it and answer on the POS. It was asked for
by Mike on 2026-11-27: "since I use twilio for sip trunking, might as well implement full feature messaging
on the POS. I want my POS to support two way SMS/MMS/RCS messaging", and what it is for: "allow two way
communication other than phone calls", "thus it can be used to take orders", "make reservations".

It uses the Twilio account the hub already sends the order texts with (`texts.md`). Nothing new is typed:
a hub that has the account has the conversations.

## What is on the screens

- **Texts**, a tile behind **More** on the home screen, under Guests & orders (`home-screen.md`). Its icon
  carries the number of conversations that hold something nobody has read, the tile says "2 not read", and
  **More** itself shows a red dot while one waits, on a phone and on a tablet alike.
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
- **A picture in an answer**: the button left of the box. On a phone or a tablet it asks "Choose from the
  photos" or "Take a photo"; on a Mac it opens a file. What was chosen shows small over the box, each with
  a cross that takes it off again, and goes with Send, with or without words. See
  [Instant delivery and pictures](#instant-delivery-and-pictures): it has to be set up once.
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
call. The hub has none by itself: it stands behind the restaurant's router.

So the hub asks. Every **5 seconds** while a screen is on (every 30 with none), it asks Twilio for the
account's texts since a little before it last asked, and writes down the ones it does not have. A
customer's text therefore shows on the POS within a few seconds, and nothing outside the building has to
be set up for it. That is how it works from the first day, and it stays on as the net when Twilio's calls
are let in as well ([Instant delivery and pictures](#instant-delivery-and-pictures)).

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
- **Going out**: up to **5 pictures** in one text, with or without words. Twilio does not take a picture
  from the hub: it is given an address and fetches the picture from it, so this works once Twilio can
  reach the hub ([Instant delivery and pictures](#instant-delivery-and-pictures)). Until then the picture
  button says so and opens nothing.
- A photo is made to fit before it leaves the device: no wider or taller than 1600 dots, as a JPEG (a
  phone's photo is ten times what a phone company carries). A small GIF goes as it is. What is no picture
  the device can read (a PDF, a video, a HEIC file on a Mac) is left out, and it is said.
- The hub takes JPEG, PNG and GIF, the three kinds every phone company carries, and 4.5 MB for the pictures
  of one text (Twilio's own limit is 5 MB with the words).
- The first text to a number that is only a picture still says who it is from: "China Sky" and, under it,
  "Reply STOP to opt out."
- The hub keeps what was sent for 30 days, like a picture somebody looked at; after that it shows it from
  Twilio's copy.

## Instant delivery and pictures

Two things need Twilio to reach the hub from the internet:

- **Instant delivery.** Twilio calls the hub the moment a customer's text comes, and again when a text the
  restaurant sent is delivered or is not. The text is on the screen at once, not up to 5 seconds later, and
  "Delivered" shows under an answer by itself.
- **Pictures in the staff's texts.** Twilio fetches each picture from the hub.

Twilio comes the way GloriaFood's pushes do (`online-orders.md`, "Push"): through the **Cloudflare tunnel**
to the hub's **push door**. Nothing is opened on the router. It is off until a manager turns it on, and
without it everything else on this page works as before.

### Setting it up

All of it is on Orders screen › More › Location › **Keys and connections**, on the card **Texts to
customers (Twilio)**, under **Instant delivery and pictures**. **How to set it up** there lists the same
steps.

1. **The tunnel.** The card **Cloudflare Tunnel (the way in)** on the same page has to say "Connected to
   Cloudflare". If it has no token yet, follow `online-orders.md`, "Turning push on", step 2: a Cloudflare
   account (free), a domain name whose DNS is at Cloudflare, a tunnel of the kind "Cloudflared", and its
   token pasted on that card. GloriaFood's push key is not needed for Twilio.
2. **The public hostname, at Cloudflare.** Give the tunnel a public hostname: a subdomain (`orders`), your
   domain, the service type **HTTP** and the address **`door:8090`**. Leave the **Path** box empty. If it
   says `online/push` from GloriaFood's pushes, empty it: the door lets in GloriaFood's pushes and Twilio's
   calls and answers "not found" to everything else. (Whoever would rather keep that path adds a second
   public hostname with the same name, the path `twilio` and the same service.)
3. **Turn on**, then **Try it**. It asks for the hub's name on the internet (`orders.example.com`, your
   own: the same name GloriaFood's pushes use, and remembered in the same place). The hub then calls its
   own address for Twilio, at its door and from outside, and should say "The whole way in works". Nothing
   is sent to Twilio and nothing goes on the POS. If something is in the way it says what: "lets only
   GloriaFood's path through" is the Path box of step 2.
4. **Copy the address**, and paste it at Twilio. In Twilio's console (console.twilio.com): Phone Numbers ›
   Manage › Active numbers › the restaurant's number › Messaging › **"A message comes in"**: **Webhook**,
   the address, **HTTP POST**, Save. Where the POS sends from a Messaging Service (`MG...`), it goes on the
   service instead: Integration › **Send a webhook**, the same address.
5. **Look.** Text the restaurant from your own phone. It is on the Texts screen at once, and the card says
   "Twilio last called at 14:02". Then answer with a picture.

Nothing has to be typed at Twilio for the delivery reports or the pictures: the hub hands Twilio the
address for each with every text it sends.

The labels in Cloudflare's and Twilio's pages may read a little differently from these.

### How it is kept safe

- **The address is the key.** The hub makes a long word nobody could guess, and every address Twilio is
  given has it in its path (`https://orders.example.com/twilio/<the word>/text`). The door lets in a call
  whose path carries the word and no other. The page shows the address with the word left out and
  **copies** it whole: paste it into Twilio's console and give it to nobody else. The word is taken out of
  the hub's logs.
- **Nothing a call says is believed.** A call names a text. The hub then asks Twilio itself for that text,
  with the account's key, exactly as it does when it asks for the list. So the words and the sender of a
  text only ever come from Twilio's own answer to the hub's own question. Somebody who learned the address
  can get nothing onto the POS: at the most the hub asks Twilio about a text that does not exist, and no
  more than 120 times a minute.
- **That is why Twilio's signature on a call is not what is relied on.** Twilio signs its calls
  (`X-Twilio-Signature`) with the account's Auth Token. The hub does not check it: it could not be tried
  against the real Twilio from here, it does not work at all with an account used through an API key, and
  with the rule above a forged call gains nothing. It can be added on top once the real thing is running.
- **A picture's address** is good for one hour and carries a mark only the hub can make (an HMAC with a
  second secret that is in no address). Whoever sees one cannot make another's, nor one that lasts longer.
  The door hands out a picture and nothing else of the hub.
- **Make a new address** (behind the three dots) kills the old one at once: for when it may have been
  seen. Twilio's console then wants the new one. **Turn off** forgets it: the door turns Twilio away, and
  the box "A message comes in" at Twilio should be emptied too.
- With two hubs, the word is kept with the keys and copied to the other hub like them.

### When the tunnel is down

Nothing is lost. The hub goes on asking Twilio every few seconds, so a text shows a few seconds later, as
before. Twilio reports a call it could not make in its own console (error 11200), which is harmless here.
A picture is the one thing that needs the way in at the moment of sending: if Twilio cannot fetch it, the
text comes back "Not sent" with the reason (Twilio's error 63019), and is sent again by hand.

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
- a copy of each picture somebody looked at, and of each picture the staff sent, for 30 days;
- the word in the address for Twilio and the secret the pictures' addresses are marked with, sealed with
  the hub's other keys (`hub-keys.md`).

They are kept until somebody decides otherwise: there is no button that deletes a conversation yet, and
nothing is removed by itself except the pictures. The database is copied to the second hub like everything
else in it. Twilio keeps its own record of every text and picture, under its own terms.

## What leaves the building

Only to Twilio, and only what a text is: the customer's number, the words somebody typed, the pictures
somebody chose, and for the first text the restaurant's name. The hub asks Twilio for the account's list
of messages with the same key it sends with. A picture is not uploaded: Twilio fetches it from the hub,
through the tunnel, at an address made for that one picture. With instant delivery on, Cloudflare carries
Twilio's calls to the hub, as it carries GloriaFood's.

## When something does not go

- **A text that was not sent** stays in the conversation in red with the reason ("Not sent: the customer
  answered STOP"). The reasons are the ones in `texts.md`, "When a text does not go". It is not sent again
  by itself: type it again once the reason is gone.
- **The hub cannot be reached** as Send is tapped: the words stay in the box, and so do the pictures.
- **A picture that cannot go** says why and stays by the box: more than five, too big together, not a
  picture a text carries, or a hub Twilio cannot fetch it from yet.
- **A tap sent twice** (a slow network) is one text: each carries the screen's own name for it.
- **No more than 300 texts an hour** leave the hub, the order texts counted in: the same guard as before.
  The guard against the same words to the same number within ten minutes is for the order texts only: a
  person may say "Yes" twice.
- A hub with no Twilio account shows the Texts tile to a manager alone, and says there where the account
  is typed.

## What it costs

Twilio bills each text sent and each one received, and more for a text with pictures (an MMS), whatever
the number of pictures in it. Asking Twilio for the list of messages costs nothing, and neither do its
calls to the hub. Cloudflare's tunnel is free; the domain name is a few dollars a year.

## What is not built

- **Texting many customers at once**, offers, a newsletter. See above.
- Sending a video, a PDF or a contact card. Pictures only.
- Checking Twilio's signature on its calls, and putting the address into Twilio's console by itself: see
  "How it is kept safe". The address is pasted by hand, once.
- A way in without a domain name of your own (Cloudflare's throwaway addresses change with every start,
  and Twilio would have to be told each time).
- A text to a party on the waitlist that its table is ready, or to confirm a reservation, sent by itself.
  Somebody can type either.
- Ready-made answers ("We open at 11"), and an answer when the restaurant is closed.
- A sound or a notification when a text comes: the dot on More and the number on the tile are all.
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

The same goes for instant delivery and pictures: no call of the real Twilio's has reached a hub, no picture
was fetched by it, and the tunnel was never set up on a real hub. **Try it** proves the way from the
internet to the hub; the first text and the first picture prove the rest. What to look at when one does
not: the card says when Twilio last called; Twilio's console › Monitor › Logs › Errors says what Twilio
could not reach (11200) or fetch (63019); `sudo hubctl logs door` and `sudo hubctl logs api` say what
arrived, with the word in the address left out.

## The calls

Who may: the roles that hold the power `texts`. Staff have no token: a screen passes who is signed in
(`staff_id`). 404 `unknown_staff`, 403 `not_allowed`.

| Call | What it does |
| --- | --- |
| `GET /texts?staff_id=&q=&limit=` | The conversations, the one with the newest text first: `phone` (+17815550142), `digits`, `name`, `unread`, `stopped_ms`, `last`. Beside them `on` (the hub has a Twilio account), `number` (what the restaurant texts from), `unread` (conversations not read), `listening` (`ok`, `at_ms`, `said`) and `send` (`pictures`: a picture can go now; `most`, `bytes`: how many and how heavy) |
| `GET /texts/unread?staff_id=` | `on` and `unread` alone, for the button |
| `GET /texts/with/{number}?staff_id=&before_ms=&limit=` | One conversation: `thread`, `texts` the oldest first (the newest hundred, or those before `before_ms`), `more`, `send` as above, and `wrap` (`before`, `after`): what a first text goes with around it. A text: `id`, `inbound`, `body`, `at_ms`, `state` (`received`, `waiting`, `sent`, `delivered`, `read`, `failed`), `channel` (`sms`, `mms`, `rcs`), `pictures` (`n`, `type`, `image`), `code`, `said`, `kind` (empty: typed; `ready`, `out`, `delayed`: the POS's own; `elsewhere`), `order_id`, `by` |
| `POST /texts/with/{number}` | `{staff_id, body, device, id, name, pictures}`: sends. `pictures` are JPEG, PNG or GIF as base64, five at the most; with one, `body` may be empty. The answer is the text, `waiting`. 409 `no_service`, 409 `stopped`, 409 `no_way` (a picture, and Twilio cannot reach the hub), 422 `no_number`, `no_text`, `too_long`, `bad_id`, `too_many`, `too_big`, `bad_picture` |
| `POST /texts/with/{number}/read` | `{staff_id}`: the conversation was opened |
| `GET /texts/picture/{id}/{n}?staff_id=` | A picture of a text, a customer's or one the staff sent. 404 `unknown_picture`, 502 `not_fetched` |

Twilio's own calls, which come through the push door and are in no list of the API's (`<word>` is the
hub's word; a wrong one is 404):

| Call | What it does |
| --- | --- |
| `POST /twilio/<word>/text` | A text came. Only `MessageSid` is read: the hub asks Twilio for that text. Answers an empty TwiML `<Response/>` at once |
| `POST /twilio/<word>/status` | Something became of a text the restaurant sent. The same |
| `GET /twilio/<word>/media/<text>/<n>/<until>/<mark>` | A picture of a text that is being sent, while `until` has not passed and `mark` is the hub's. 404 otherwise |

A manager's, on Keys and connections (`hub-keys.md`): `POST /hub/texts/way` turns it on (`{"again": true}`
makes a new address), `DELETE /hub/texts/way` turns it off, `POST /hub/texts/way/try` tries it
(`way_tried.door`, `way_tried.outside`). `GET /hub/keys` says how it stands under `texts_way`: `on`,
`address`, `url` (the address for Twilio, word and all: a manager's alone), `door`, `called_ms`.

The change feed says `texts` when a text came, one went, one was delivered or was not, or a conversation
was read (`GET /live`).

The code: `backend/src/pos/texts.py` keeps the conversations and makes the rules (`Texts`), and asks Twilio
(`Listener`; `hear` for one text Twilio called about); `backend/src/pos/twilio.py` reads Twilio's list and
its pictures (`heard`, `one`, `pictures_of`, `picture`) and sends a typed text (`deliver`);
`backend/src/pos/api/texts.py` is the calls. Twilio's way in: `backend/src/pos/online/twilio_way.py` (the
word, the addresses, the marks), `online/door.py` (what the door lets through), `online/wayin.py` (telling
the door), `api/keys.py` (turning it on, trying it). In the app: `lib/texts.dart`, `lib/text_pictures.dart`
(choosing a picture and making it fit), `lib/screens/texts_screen.dart`, its `HomeEntry` in
`lib/screens/orders_screen.dart`, and `lib/screens/hub_keys_screen.dart` for the card.
Tests: `backend/tests/test_text_inbox.py`, `backend/tests/test_text_way.py`,
`apps/pos_app/test/texts_test.dart`, `text_pictures_test.dart`, `texts_way_test.dart`.

## An older hub, an older app

An app newer than its hub shows no Texts tile and no line on a to-go order. A hub newer than its apps
keeps the conversations all the same, and the order texts go as before. Update the hub first.

The picture button shows only on a hub that knows of pictures in the staff's texts, and the part
**Instant delivery and pictures** of the card only on a hub that knows of Twilio's way in. The hub's push
door is updated with the hub (`sudo hubctl update`): an older door turns Twilio away, and **Try it** says
so.
