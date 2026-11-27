# Texts to customers

The POS texts the customer of a to-go order: when it is ready, when it leaves with its driver, and when its
time is pushed back. Until 26 November 2026 those texts were only written to the hub's log, because the hub
had no texting service to send them with. Now it sends them through the restaurant's own **Twilio** account,
once a manager has typed that account in the app. Until then nothing changes: no text goes out.

It was asked for by Mike on 2026-11-26: "For ready orders, send a SMS text since gloriafood does not send SMS
text". So an order marked ready in GloriaFood's app gets the POS's ready text too.

## Which texts go, and when

| Text | When | The words |
| --- | --- | --- |
| **Ready** | A pickup order becomes Ready: somebody presses Ready on the POS, or the order is marked ready in GloriaFood's app | "Hi Linda, order #42 is ready for pickup at China Sky. Please pay at pickup." The last sentence only while something is still due |
| **On its way** | A delivery is handed to its driver (Out), the first time only | "Hi Linda, order #42 from China Sky is on its way." |
| **A new time** | The time of an order the kitchen has not finished is moved later | "Hi Linda, order #42 at China Sky will be ready at 18:40. Sorry for the wait." For a delivery: "will be with you around 18:40" |

- **Every to-go order that has a phone number gets them**, however it was taken: at the counter, by phone or
  on the website. Turning Twilio on turns the texts on for all of them, not for online orders alone.
- **An order without a phone number gets none**, and so does a table's check or a bar tab, whatever number
  is on it (`guest-list.md`).
- **A delivery gets no "ready" text**: nobody is told to come for an order that is brought. It hears "on its
  way" when a driver takes it (`delivery.md`).
- The time an order is given as it is first sent to the kitchen is its quote, not a delay: nothing is texted
  for it (`counter-mode.md`).
- The texts are in the customer's language, English or Chinese, as the order says.
- The restaurant's name in them is `POS_LOCATION` in the hub's own file.

## Ready in GloriaFood's app

GloriaFood sends its customers no text message when an order is marked ready. With the integration set to
"Send every time an order is updated" the hub hears of it (`online-orders.md`, "What GloriaFood says of an
order afterwards"), makes the order Ready on the POS, and now sends the ready text as well.

- **Only while it is news.** The text goes when GloriaFood changed the order no longer than **a quarter of
  an hour** ago. A hub that was off, or had no internet, and hears at nine that an order was ready at six
  makes it Ready on the POS and texts nobody: the customer has come and gone.
- **An order that reaches the hub already marked ready** (the hub was off while the restaurant worked from
  GloriaFood's app) goes on the POS as Ready and gets the text by the same rule.
- **Once.** GloriaFood handing the same order over again texts nobody a second time.
- **One way.** Ready pressed on the POS texts the customer, and still tells GloriaFood nothing.

## Setting it up

You need a Twilio account with a number that can send texts and is registered for business texting (in the
United States the phone companies deliver a business's texts only from a registered number; Twilio calls it
A2P 10DLC). The restaurant has one already.

The registration at Twilio names what kind of texts the number sends. These are order updates to a customer
who gave their number with an order. If the registration was made for something else alone (offers, say),
add order updates to it in Twilio's console, or the phone companies may filter these.

1. On a terminal: the Orders screen, **More**, **Location**, a manager's PIN, **Keys and
   connections**, and the card **Texts to customers (Twilio)**.
2. **Type the account**:
   - **Account SID**: on the first page of Twilio's console (console.twilio.com). It begins with `AC`.
   - **Auth Token**: beside it on the same page. It shows as dots while typed.
   - **Send from**: the number the texts come from, one of the account's own that can text, typed any way
     (781 555 0100). Or the SID of the Messaging Service the business texting was registered with (Twilio's
     console, Messaging, Services; it begins with `MG`): Twilio then picks the number itself. Where the
     registration was done through a Messaging Service, its SID is the surer of the two.
   - **API key SID** stays empty, unless you would rather give the hub an API key than the account's own
     token (Twilio's console, Account, API keys). Then the key's SID (`SK...`) goes here and its secret into
     the Auth Token box. An API key can be taken away again without touching anything else that uses the
     account.
3. **Save.** The hub checks what was typed, seals the token and uses the account at once. The hub is not
   restarted.
4. **Try it**: type your own mobile number. The hub sends one text ("A test from the POS at China Sky:
   texts to customers are working.") and waits a few seconds to hear what became of it:
   - "Delivered": the phone company said it arrived. The account works.
   - "Twilio took the text, and the phone company has not said yet": look at the phone. Some phone companies
     never say.
   - "The text did not go", with why (see below).

From then on the card says how the texts are doing: how many went out in the last 24 hours, how many did not
go, and the last one that did not, by its order's number and with the reason.

**Remove** on the card stops the texts: the hub goes back to writing them down and sending nothing.

## When a text does not go

Sending never holds an order up. Ready answers at once on the screen; the text goes out behind it.

- **Twilio could not be reached** (the restaurant's internet is down): tried twice more over half a minute,
  then given up.
- **Twilio did not answer**, or the line dropped once the text was on its way: not sent again, because it
  may have gone, and a customer is not told twice.
- **Twilio refuses it**: not tried again. The reason is kept in words, with Twilio's own error number:

| What the card says | What to do |
| --- | --- |
| Twilio does not know the key (20003) | Type the account again: the token was changed at Twilio, or mistyped |
| The number to send from is not one of this Twilio account's that can text (21606, 21659, 21660) | Correct **Send from** |
| This Twilio account is a trial (21608) | A trial account texts only the numbers verified in its console: upgrade it |
| The customer answered STOP to an earlier text (21610) | Nothing: Twilio sends that number no more until they text START |
| The number on the order is not one a text can be sent to (21211, 21217, 21601), or is no mobile number (21614) | Nothing: it was typed wrong, or it is a landline |
| Twilio may not text that country (21408) | Twilio's console, Messaging, Settings, Geo permissions |
| The number to send from is not registered for business texts yet (30034) | Twilio's console, Messaging, Regulatory Compliance. Twilio takes such a text and the phone company drops it, which is why the hub asks after every text |
| The phone company took it for spam (30007), blocked it (30004), does not know the number (30005), or it is a landline (30006) | Mostly nothing. Many 30007s: look at the registration in Twilio's console |

- **Whether it arrived.** Twilio takes a text first and finds out afterwards whether the phone company
  delivers it. So the hub asks Twilio about each text a few seconds on, and once more later, and counts the
  ones that failed there too.
- **Two guards.** The same words to the same number go out once in ten minutes: Ready pressed, taken back
  and pressed again tells the customer once. And no more than 300 texts leave in an hour, whatever asks for
  them.
- **Where it shows.** On the card under Keys and connections only. Nobody is alerted when a text fails, and
  the order does not say whether its text went.
- A hub that is restarted (an update) drops the texts still waiting for a second try.

## What leaves the building

Only once an account is typed in, and only to Twilio:

- **The customer's phone number and the text itself**: the customer's name as the order has it, the order's
  number, and the restaurant's name. Nothing else of the order: no dishes, no prices, no address.
- For a try: the number the manager typed, used for that one text and kept nowhere.

What the hub keeps of a text is when it was, of which kind, for which order, and what became of it. **Never
the number and never the words.** The hub's log names the order and the outcome. The Auth Token is sealed
like every key (`hub-keys.md`, "Where a typed key is kept"), is never shown again, and is in no log and no
answer.

Twilio keeps its own record of every text in its console, under its own terms.

## Replies, and STOP

A customer who answers a text answers the Twilio number, not the POS: nobody reads replies at the POS.
Twilio handles STOP, START and HELP by itself, and the hub is told "the customer answered STOP" when it
tries such a number again. The texts themselves do not say "Reply STOP to opt out": they are the words the
POS always had.

## What it costs

Twilio bills the account for each text. A text in Chinese holds fewer characters per billed part than one in
English, so a long name can make it two.

## Two hubs

Each hub sends the texts for what its own screens write. Both use the same account when they carry the same
`POS_SECRET` (`hub-keys.md`, "Two hubs"). The guard against the same text twice is each hub's own.

## What is not built

- A text when a table is ready for a party on the waitlist (`waitlist.md`), and anything for a reservation.
- Reading what a customer answers.
- A switch for each kind of text: with an account all three go, without one none.
- An alert to a manager, or a mark on the order, when a text did not go.
- Setting the account from the hub's terminal: it is typed in the app only.

## Not yet tried against the real Twilio

The tests stand a pretend Twilio in for the real one, answering as Twilio's pages say it does. Nothing has
been sent through a real account from here. **Try it** on the card is the proof.

## The calls

All of them a manager's or an owner's, like every key's.

| Call | What it does |
| --- | --- |
| `PUT /hub/keys/texts` | `{"account": "AC...", "key": "<the Auth Token>", "sender": "<a number, or MG...>"}`, and with an API key its SID as `key_sid` and its secret as `key`. Checked, sealed, in force at once. 422 `bad_value` with words that never repeat what was typed |
| `DELETE /hub/keys/texts` | No text goes out from now on |
| `GET /hub/keys` | Beside the keys, `texts`: `provider` (`log`: nothing goes out; `twilio`), `sender`, `day` (`texts`, `delivered`, `failed` of the last 24 hours) and `last_failed` (`order_id`, `order_no`, `kind`, `at_ms`, `code`, `said`) |
| `POST /hub/texts/try` | `{"to": "781 555 0142"}`: one text now. Answers like the `GET`, with `tried`: `ok`, `state` (`delivered`, `sent`, `failed`), `code`, `said`. 409 `no_service` without an account |

`GET /messages` lists what a hub without a texting service would have sent (the bench's view). With an
account it lists nothing: no number is kept to show.

The code: `backend/src/pos/messaging.py` words the texts and decides when one is due,
`backend/src/pos/twilio.py` sends them, `backend/src/pos/api/keys.py` puts a typed account to work, and
`backend/src/pos/online/after.py` (`news`) says whether what GloriaFood tells of an order is still news.

## An older hub, an older app

A hub from before this lists no such key, and the page shows no card for it. An app from before this shows
the cards it knew, on any hub. Update the hub first, then the apps.
