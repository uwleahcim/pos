# Keys and connections

The hub talks to a few services outside the restaurant, and each wants a key: the map service a delivery's
distance is asked of, Google Maps behind it, Mapbox and Azure Maps for the list of addresses while one is
typed, GloriaFood for the website's orders (a key for asking, and one
its own pushes carry), Cloudflare for the tunnel those pushes come in by, and Apple for waking a locked
iPhone. Until 2026-11-24 every one of them was put on the hub in its terminal (`sudo hubctl maps key` and
the like). Now a manager or an owner types them in the app, under **Location › Keys and connections**, and
the hub uses a typed key at once, with no restart.

The terminal still works exactly as it did. Nothing has to be typed again: a key that is on the hub today
shows on the page as set.

## The page

Orders screen › the three dots › **Location**, a manager's PIN, then **Keys and connections**. The row
itself says which keys are set and which are not ("Set: map service, GloriaFood · Not set: Google Maps,
Mapbox, Azure Maps, GloriaFood push, Cloudflare tunnel, Apple push"). Only a manager or an owner sees the row and opens the
page. It is not a power that can be handed to another role (`roles.md`).

Each key is a card:

- **How it stands**, in one line: "Set · ends in x7Qd · typed here by Mike, today", "Set in the hub's
  terminal · ends in m4Zk", "Not set", or "Not set · removed here by Mike, Nov 24".
- **What the hub does with it**, and while there is none, what goes without.
- **Type the key** (or **Replace** when one is set): a box for the key, shown as dots unless the eye is
  pressed (a key that is shown is shown whole, over as many lines as it takes), with a line on where the key
  is found. Save, and the hub checks it, keeps it and uses it. What
  the hub says is wrong with it (too short to be a key, a wrong id) shows in the same box with everything
  typed still there.
- **Try it**: asks the service something small, and says what came back in plain words.
- **Remove**: asks first, and says what stops.

A key is never shown again once it is saved, to anybody: only its last four characters, to tell one key
from another. A key shorter than sixteen characters shows none of itself.

## The keys

| Key | What the hub does with it | Where the key is found | Try it |
| --- | --- | --- | --- |
| **Map service (Geocodio)** | Asks how far a delivery is, so the form picks the fee (`delivery.md`, "Looking the distance up") | geocod.io: sign in, API Keys, a key with the Distance permission | Asks Geocodio alone how far an address you type is from the restaurant |
| **Google Maps** | Asked when the map service gives no distance, about the roads right now for live traffic, and, where a manager turned it on, for the list of addresses while one is typed (`delivery.md`, "A second map service", "Live traffic", "A list of addresses while typing") | Google Cloud console: Keys & Credentials, an API key restricted to the Routes API; for the list of addresses, Places API (New) ticked beside it | Asks Google alone how far an address you type is. (The list of addresses has its own Try it: Location › Address list) |
| **Mapbox** | Asked for the list of addresses while one is typed, once Google's free lookups for the month are used up or Google is not answering, where a manager turned it on (`delivery.md`, "Mapbox and Azure Maps behind Google"). Where a manager turned that on too, asked how far a delivery goes and how long the drive is right now (`delivery.md`, "Which service is asked first") | mapbox.com: the account page, Tokens, the default public token (starts with `pk.`), with no URL restriction | Asks Mapbox alone for addresses like the restaurant's own, and says how many free lookups are left this month |
| **Azure Maps** | The same, after Mapbox | Azure portal: an Azure Maps account, Settings › Authentication, the Primary Key | Asks Azure Maps alone, the same way |
| **GloriaFood (online orders)** | Asks GloriaFood every minute for the orders accepted on the website (`online-orders.md`) | GloriaFood's admin: Others, Third party integrations, the key of the integration "Poll Accepted Order v2" | Asks GloriaFood for orders now, as **Ask now** does |
| **GloriaFood push key** | Every order GloriaFood sends by itself, the moment it is accepted, must carry it; the push door opens for it and for nothing else (`online-orders.md`, "Push") | Yours to make: **Make one** in the box, **Copy**, Save, and the same key into GloriaFood's admin as the master key of the integration "Push Accepted Order" | Tries the way in: see below |
| **Cloudflare Tunnel (the way in)** | The hub holds a line open to Cloudflare, and GloriaFood's pushes come down it to the push door. Nothing is opened on the router | Cloudflare's dashboard: Zero Trust, Networks, Tunnels, your tunnel. The command it shows for installing it, pasted whole, or only the long word in it that starts with `eyJ` | Tries the way in: see below |
| **Apple push key** | Wakes a locked iPhone or iPad for a call or a desk-phone pick-up (`push-relay.md`) | Apple's developer account: Certificates, IDs & Profiles, Keys. The file `AuthKey_<key id>.p8`, which can be downloaded once | Sends a notification to an iPhone or iPad that registered with the hub |

Apple's key is a small text file. Open it in a text editor (TextEdit on a Mac), copy all of it with the two
dashed lines, and paste it into the box. It needs two ids beside it: the **Key ID** (the ten letters and
digits in the file's name) and the **Team ID** (ten more, under Membership details in the developer
account). The Bundle ID stays empty unless the app was renamed at Apple.

**Several GloriaFood accounts.** A restaurant with a second website, or an account it only tests with, adds
each under the GloriaFood card: **Add another GloriaFood account** asks for a name, that account's key and
whether it is for testing. Each account is then a card of its own ("GloriaFood · Sushi site"), with a pencil
beside its name for the name and the testing switch, and **Remove** takes a further account away whole, its
key with it.
The row under Location counts them ("GloriaFood (2 accounts)") and names the ones without a key. What the
hub does with several accounts, and what a testing account's orders look like, is in `online-orders.md`,
"Several accounts".

**The way in for GloriaFood's pushes** is the two cards together, and `online-orders.md`, "Turning push
on", walks through them.

- **Make one.** The key for pushes is the one key that is yours to make. The box makes forty letters and
  digits nobody could guess, shows them, and **Copy** puts them on the clipboard for GloriaFood's admin.
  This is the only moment the key can be seen: once saved, it is not shown again. A key of your own can be
  pasted instead.
- **The tunnel's card says how the tunnel stands**, under the line about its token ("Set · tunnel 6ff42ae2
  · typed here by Mike, today": the start of the tunnel's id at Cloudflare, never the token). "On its way
  to Cloudflare, not connected yet" right after the token is saved; the page looks again by itself every
  two seconds for half a minute, and then says "Connected to Cloudflare since 14:02", or in red why not:
  Cloudflare did not take the token, the hub cannot reach Cloudflare, or what Cloudflare's program last said.
- **Try it**, on either card, asks for the address GloriaFood sends to (`orders.example.com`; leave it
  empty to try the push door alone). The hub knocks at its own push door and, with an address, from outside
  at that address, and says "The whole way in works" or where it stops (`online-orders.md`, "Try it"). No
  key is sent anywhere, and nothing goes on the POS. The hub remembers the address, and the push key's card
  then shows it whole, with a button that copies it for GloriaFood's admin.
- **Remove** on the push key shuts the push door; on the tunnel it closes the tunnel. Orders still arrive
  by the asking.

Trying a map service takes the restaurant's own address (Location › Delivery fee › Restaurant address),
since that is where the distance starts. A try counts as one question of the day's allowance. Nothing of
a try is kept.

## The terminal and the app

Both can set every one of these keys, and **whichever was used last wins**. (A further GloriaFood
account's key is the exception: it is typed in the app only. `hubctl online key` is the first account's.)

- A key typed in the app is used in place of the one in the hub's own file (`/opt/pos/.env`).
- A key put on with `hubctl` (or taken off with `hubctl ... forget`) clears what the app typed for that key,
  so the terminal's word holds.
- **Remove** in the app means no key is in force, also when the hub's file still names one. The page then
  says "Not set · removed here by ...".

## What still needs the hub's terminal

| What | Why it stays |
| --- | --- |
| The first install of a hub, and `sudo hubctl update` after every merge | The app talks to the hub's program; this is what installs and replaces that program (and, with it, Cloudflare's tunnel program) |
| `sudo hubctl backup`, `hubctl psql`, `hubctl logs` | The database itself, and the hub's own log |
| Linking the PBX (`hubctl pbx key`, `hubctl pbx link`) | It makes an SSH key on the hub and changes the PBX, which the owner looks at first (`desk-phones.md`) |
| A new PIN for somebody when no manager can sign in any more (`sudo hubctl staff pin`) | The staff and their PINs are kept in the app now (Location › Staff and PINs, `staff.md`); this is the way back in |
| The location's name and time zone, the daily caps on map lookups | Rarely changed; in `/opt/pos/.env` |

## Where a typed key is kept

- **Sealed, in the hub's database** (table `hub_key`), so the second hub of a location has it too. Beside
  the sealed key, in the clear: its last four characters, Apple's two ids, who typed it and when.
- **The secret that opens the seal is not in the database.** It is `POS_SECRET` where the hub has one, and
  otherwise a file the hub makes for itself the first time (`/keys/vault.key`, in the Docker volume
  `pos_pos-keys`, readable by the hub's program alone). So a backup of the database, or a copy of it
  somewhere, opens no key.
- **Never in a log, and never in an answer.** The hub's log says that a key was set or removed and by
  whom. No call of the hub gives a key back. What the hub says when it refuses one never repeats what was
  typed.
- **The push door and the tunnel are handed only what each needs**, each in a folder of the hub that no
  other program reads. The door gets a fingerprint of the key for pushes (its SHA-256), not the key: enough
  to tell a push that carries the key, and of no use to anybody who reads it. The tunnel's program gets its
  token as it is, since it has to show it to Cloudflare, in a file only the hub's own user can read. Neither
  is restarted for it, and the hub's program is given no power over the hub's other programs for it.
- **A key made in the app** is made on the screen it is typed at, shown there until the box is closed, and
  kept nowhere on that screen after.
- **Not on the screens.** A terminal holds no key. It sends what the manager typed to the hub once and
  forgets it.
- **On its way to the hub** a typed key travels over the restaurant's own network, as a manager's PIN does
  today. Type keys on the restaurant's network, not through a shared or public one.

If the hub's volume `pos_pos-keys` is lost (a new disk, a hub rebuilt from a database backup), the keys
typed in the app can no longer be opened. The page then says of each "this hub cannot read it. Type it
again here.", and a key in the hub's own file is used meanwhile.

## Two hubs

A key typed on one hub is used by the other within a minute: each hub looks once a minute whether the keys
changed under it. For the second hub to open what the first sealed, **both must carry the same
`POS_SECRET`** in `/opt/pos/.env` (`infra/hub/FAILOVER.md`). Where they do not, the second hub says so on
the page ("typed in the app, but on another hub") and goes on with the key in its own file, if it has one.
A standby that cannot write takes no typed key: the app then types it on the hub that can.

The tunnel's token is a key like the others, so with two hubs both hold a line to Cloudflare for the same
tunnel, and Cloudflare sends a push down either. That is how Cloudflare means a tunnel to be kept up by two
machines, but it has not been tried here with two hubs yet. **Try it** proves the way to the hub that was
asked: with two hubs behind one address it can say "answers, but not from this hub" when the knock came down
the other hub's line, and a second try may land on this one.

## The calls

All of them are a manager's or an owner's (the token from `POST /admin/session`); no setting hands them out.

| Call | What it does |
| --- | --- |
| `GET /hub/keys` | `keys`: each with `name` (`maps`, `maps_google`, `online`, `online_push`, `online_tunnel`, `push_apple`), `set`, `source` (`app`, `hub` or null), `ending`, `shown` (Apple's ids; of a tunnel's token `tunnel`, the start of the tunnel's id), `by`, `at_ms`, `removed`, `unreadable`. And `kept`: false on a hub with nowhere to keep its sealing secret. Never a key |
| `PUT /hub/keys/{name}` | `{"key": "..."}`; for Apple's also `key_id`, `team_id` and, when not the usual one, `bundle_id`. Checked, sealed, stored and in force at once. Answers like the `GET`. 422 `bad_value` with words; 404 `unknown_key`; 503 `read_only` on a standby |
| `DELETE /hub/keys/{name}` | None is in force from now on. Answers like the `GET` |
| `POST /hub/online/accounts` | Another GloriaFood account: `{"name": "Sushi site", "key": "...", "test": false}`. The key is checked first, sealed under `online:<id>` and asked with at once. Answers like the `GET`, with the new account's `id` as `added`. 422 `bad_value` with words |
| `PUT /hub/online/accounts/{id}` | Its `name`, or whether it is for testing (`test`); what is left out stays, and its key is not touched. The first account is `main`. 404 `unknown_account` |
| `DELETE /hub/online/accounts/{id}` | The account is gone and its key forgotten; its orders stay. 409 `first_account` for `main` |
| `PUT /hub/online/push/address` | `{"address": "orders.example.com"}`: the name GloriaFood sends its pushes to, kept as the location setting `online_push_address` for trying the way in; `https://` before it and a path after it are dropped, empty forgets it. Answers like the `GET`. 422 `bad_value` for what is not a name on the internet (a number, a port) |
| `POST /hub/online/push/try` | The hub knocks at its push door and, with an address, at `https://<address>/online/push`, with a word made for that try where the key would be. Answers like the `GET`, with `tried`: `door` (`ok`, `reason`: `no_answer`, `shut`, `api`, `other`; `code`) and `outside` (null without an address; else `address`, `ok`, `reason`: `no_answer`, `late`, `elsewhere`, `not_routed`, `blocked`, `tunnel_down`, `redirect`, `other`; `code`, `url`). 409 `no_key` on a hub with no key for pushes |

`GET /hub/keys` also lists `online_accounts`: each with `id`, `name`, `test` and its `key` as above (the
first account's is the key `online`; another's is named `online:<id>` and is set and removed with
`PUT`/`DELETE /hub/keys/online:<id>` like any key). The accounts themselves are the location setting
`online_accounts`; only their keys are sealed.

And `way_in`, the way in for GloriaFood's pushes as it stands: `address` (the one remembered, or empty),
`door` and `tunnel_told` (whether the push door and the tunnel's program could be handed their key and
token; null on a machine that runs neither), and `tunnel`: `there` (a tunnel program runs and speaks),
`state` (`off`, `starting`, `connected`, `failing`), `since_ms`, `reason` while it is failing (`refused`,
`unreachable`, `slow`, `missing`, `trouble`), `said` (Cloudflare's program's own last word, a line of plain
text) and `version`.

The code is `backend/src/pos/keys.py` (what is kept and how) and `backend/src/pos/api/keys.py` (the calls,
and putting a key to work without a restart); the page is `apps/pos_app/lib/screens/hub_keys_screen.dart`.

## An older hub, an older app

A hub from before this has no such calls: the row under Location says "This hub is older than keys typed in
the app: update it (sudo hubctl update)" and opens nothing. An app from before this has no row, and
everything else is as it was. Update the hub first, then the apps.

A hub from before the push key and the tunnel were typed here lists neither, and the page shows no card for
them. An app from before them shows the four cards it knew, on any hub.
