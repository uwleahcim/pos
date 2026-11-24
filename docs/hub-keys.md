# Keys and connections

The hub talks to a few services outside the restaurant, and each wants a key: the map service a delivery's
distance is asked of, Google Maps behind it, GloriaFood for the website's orders, and Apple for waking a
locked iPhone. Until 2026-11-24 every one of them was put on the hub in its terminal (`sudo hubctl maps
key` and the like). Now a manager or an owner types them in the app, under **Location › Keys and
connections**, and the hub uses a typed key at once, with no restart.

The terminal still works exactly as it did. Nothing has to be typed again: a key that is on the hub today
shows on the page as set.

## The page

Orders screen › the three dots › **Location**, a manager's PIN, then **Keys and connections**. The row
itself says which keys are set and which are not ("Set: map service · Not set: Google Maps, GloriaFood,
Apple push"). Only a manager or an owner sees the row and opens the page. It is not a power that can be
handed to another role (`roles.md`).

Each key is a card:

- **How it stands**, in one line: "Set · ends in x7Qd · typed here by Mike, today", "Set in the hub's
  terminal · ends in m4Zk", "Not set", or "Not set · removed here by Mike, Nov 24".
- **What the hub does with it**, and while there is none, what goes without.
- **Type the key** (or **Replace** when one is set): a box for the key, shown as dots unless the eye is
  pressed, with a line on where the key is found. Save, and the hub checks it, keeps it and uses it. What
  the hub says is wrong with it (too short to be a key, a wrong id) shows in the same box with everything
  typed still there.
- **Try it**: asks the service something small, and says what came back in plain words.
- **Remove**: asks first, and says what stops.

A key is never shown again once it is saved, to anybody: only its last four characters, to tell one key
from another. A key shorter than sixteen characters shows none of itself.

## The four keys

| Key | What the hub does with it | Where the key is found | Try it |
| --- | --- | --- | --- |
| **Map service (Geocodio)** | Asks how far a delivery is, so the form picks the fee (`delivery.md`, "Looking the distance up") | geocod.io: sign in, API Keys, a key with the Distance permission | Asks Geocodio alone how far an address you type is from the restaurant |
| **Google Maps** | Asked when the map service gives no distance, and about the roads right now for live traffic (`delivery.md`, "A second map service", "Live traffic") | Google Cloud console: Keys & Credentials, an API key restricted to the Routes API | Asks Google alone how far an address you type is |
| **GloriaFood (online orders)** | Asks GloriaFood every minute for the orders accepted on the website (`online-orders.md`) | GloriaFood's admin: Others, Third party integrations, the key of the integration "Poll Accepted Order v2" | Asks GloriaFood for orders now, as **Ask now** does |
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

Trying a map service takes the restaurant's own address (Location › Delivery fee › Restaurant address),
since that is where the distance starts. A try counts as one question of the day's allowance. Nothing of
a try is kept.

## The terminal and the app

Both can set every one of these four keys, and **whichever was used last wins**. (A further GloriaFood
account's key is the exception: it is typed in the app only. `hubctl online key` is the first account's.)

- A key typed in the app is used in place of the one in the hub's own file (`/opt/pos/.env`).
- A key put on with `hubctl` (or taken off with `hubctl ... forget`) clears what the app typed for that key,
  so the terminal's word holds.
- **Remove** in the app means no key is in force, also when the hub's file still names one. The page then
  says "Not set · removed here by ...".

## What still needs the hub's terminal

| What | Why it stays |
| --- | --- |
| The first install of a hub, and `sudo hubctl update` after every merge | The app talks to the hub's program; this is what installs and replaces that program |
| `sudo hubctl backup`, `hubctl psql`, `hubctl logs` | The database itself, and the hub's own log |
| Linking the PBX (`hubctl pbx key`, `hubctl pbx link`) | It makes an SSH key on the hub and changes the PBX, which the owner looks at first (`desk-phones.md`) |
| GloriaFood's own pushes: the push key and the Cloudflare Tunnel's token (`hubctl online push key`, `hubctl online tunnel token`) | Each starts another program beside the hub's. Planned for this page next |
| The staff and their PINs (`POS_STAFF` in `/opt/pos/.env`) | Planned for the app, as its own screen |
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

## The calls

All of them are a manager's or an owner's (the token from `POST /admin/session`); no setting hands them out.

| Call | What it does |
| --- | --- |
| `GET /hub/keys` | `keys`: each with `name` (`maps`, `maps_google`, `online`, `push_apple`), `set`, `source` (`app`, `hub` or null), `ending`, `shown` (Apple's ids), `by`, `at_ms`, `removed`, `unreadable`. And `kept`: false on a hub with nowhere to keep its sealing secret. Never a key |
| `PUT /hub/keys/{name}` | `{"key": "..."}`; for Apple's also `key_id`, `team_id` and, when not the usual one, `bundle_id`. Checked, sealed, stored and in force at once. Answers like the `GET`. 422 `bad_value` with words; 404 `unknown_key`; 503 `read_only` on a standby |
| `DELETE /hub/keys/{name}` | None is in force from now on. Answers like the `GET` |
| `POST /hub/online/accounts` | Another GloriaFood account: `{"name": "Sushi site", "key": "...", "test": false}`. The key is checked first, sealed under `online:<id>` and asked with at once. Answers like the `GET`, with the new account's `id` as `added`. 422 `bad_value` with words |
| `PUT /hub/online/accounts/{id}` | Its `name`, or whether it is for testing (`test`); what is left out stays, and its key is not touched. The first account is `main`. 404 `unknown_account` |
| `DELETE /hub/online/accounts/{id}` | The account is gone and its key forgotten; its orders stay. 409 `first_account` for `main` |

`GET /hub/keys` also lists `online_accounts`: each with `id`, `name`, `test` and its `key` as above (the
first account's is the key `online`; another's is named `online:<id>` and is set and removed with
`PUT`/`DELETE /hub/keys/online:<id>` like any key). The accounts themselves are the location setting
`online_accounts`; only their keys are sealed.

The code is `backend/src/pos/keys.py` (what is kept and how) and `backend/src/pos/api/keys.py` (the calls,
and putting a key to work without a restart); the page is `apps/pos_app/lib/screens/hub_keys_screen.dart`.

## An older hub, an older app

A hub from before this has no such calls: the row under Location says "This hub is older than keys typed in
the app: update it (sudo hubctl update)" and opens nothing. An app from before this has no row, and
everything else is as it was. Update the hub first, then the apps.
