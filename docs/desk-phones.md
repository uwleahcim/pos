# Desk phones linked to screens

Taking a call in the app is not always possible: the phone at the host stand is a desk phone, the person
answering has a tray in the other hand. A desk phone can be linked to a screen, and then a call taken on the
phone does on that screen what taking it in the app does (Mike, 2026-11-04): the caller's most recent order
of the business day opens, or a new phone order with the caller's number filled in.

## How it works

```
caller ──▶ PBX (FreePBX) ──▶ ring group 600 ──▶ desk phone 200 picks up
                │
                │ manager interface (AMI), through the hub's SSH tunnel
                ▼
            hub: "200 answered +1 617 555 1234" ──▶ linked device tab1 ──▶ the order opens
```

- The hub keeps one connection to the PBX's manager interface (the same AMI user `pos` as the October
  probe) and watches the call events. The moment an extension answers an outside call, the hub looks the
  extension up in the links a manager keeps and holds the answer for that device.
- The app on every device keeps one request waiting at its hub for such answers; the hub answers it the
  moment one of the device's phones picks up (or after 15 seconds with nothing new) and the next request
  follows at once, so the pop comes a fraction of a second after the pick-up. A fresh answer (less than 45
  seconds old) does what picking up in the app does: the hub is asked for the number's last order of the day (`GET /orders/last`), which opens; with
  none, the to-go form opens with the number, the phone channel and the caller-ID name, when the trunk gave
  one (`<unknown>`, Anonymous and the like are no name). Only while someone
  is signed in on that device, as with a call taken in the app; a call picked up just before someone signs
  in still opens when the orders screen comes up, if it is fresh.
- The links are a location setting, like coursing and quote times: a manager links extensions to device
  names under Location settings, **Desk phones**, and the next call follows the new links. A phone rings
  one screen; a screen may have several phones.

What counts as an answer: a call that came in on a trunk and was picked up on an extension, once per call
and phone. A call transferred to another linked phone opens there too (a blind transfer; an attended
transfer, where the first phone talks to the second before handing over, does not, in this version). Calls
between extensions, calls out and follow-me to a cell open nothing. A call the device's own in-app phone
takes is left to the app, so one call opens one thing even when the app's extension is linked as a desk
phone.

## Setting it up

The hub reaches the manager interface the way the October probe did: an SSH tunnel to the PBX host, which
the hub now keeps up itself (the `pbx` service in `infra/hub/docker-compose.yml`), carrying only Asterisk's
manager port from the PBX's own loopback to the hub's containers. No port opens on the PBX and no FreePBX
setting changes; the PBX only has to accept the hub's SSH key.

On the hub:

1. `hubctl pbx link root@freepbx.chinasky.org` puts the hub's SSH key on the PBX (made on first use, kept in
   `/opt/pos/pbx`; the PBX asks for root's password this once, and from then on the key alone opens the
   tunnel). The line it adds to `/root/.ssh/authorized_keys` lets the key forward to the manager port and
   nothing else: no shell on the PBX. Then it asks for the AMI user's secret (FreePBX, Settings, Asterisk
   Manager Users, user `pos`; the user needs `call` among its read rights, which it has), writes the link to
   `/opt/pos/.env`, starts the tunnel and the watcher and waits until the hub reaches the PBX, which it says
   (or, after 45 seconds, shows where it stands). From then on `hubctl pbx status` shows the tunnel up and
   `"connected": true`, and `hubctl status` has a `pbx:` line. Run again later, it finds the key accepted and
   only asks for the secret (Enter keeps the saved one).

   To add the key by hand instead, `hubctl pbx key` prints the line and the one-line `ssh root@... 'echo
   ... >> ~/.ssh/authorized_keys'` command that appends it, with the key filled in: paste that whole command,
   not one from an example.
2. `hubctl pbx tail` prints each call as a desk phone answers it, with the extension and the caller, as the
   hub sees it: the quickest check that the PBX reports what the links need. Pick up a desk phone on a
   test call and the line appears.

In the app, on any terminal, as a manager: Orders, **Location**, the manager PIN, then **Desk phones**: the
card says how the hub stands with the PBX; **Add phone**, then pick the extension and the screen, **Save**.
The extension list is the PBX's extensions as the hub sees them (one with no phone registered reads
"(offline)"); until the hub is linked to the PBX the extension is typed instead. The screen list is the
screens the hub has heard from, by their device names (the name a screen shows under Settings), with the
screen you stand at first, marked "(this device)". **Other…** at the end of either list opens a field to
type what the list does not have, such as a screen that has not been on yet; the arrow in that field goes
back to the list. The second hub of a location gets the same `hubctl pbx` steps; a device takes the
answers from whichever hub it talks to, and the same call is one call on both.

## Limits

- The screen has to be on and someone signed in, as for a call taken in the app.
- A call that rang before the hub connected to the PBX still opens if the number is an outside one; one
  that rang while the hub was down does not.
- The answer reaches the screen a fraction of a second after the pick-up: the screen's request is already
  waiting at the hub for it. A screen running an app build from before this, or a hub from before it, asks
  once a second instead, so the pop takes up to a second or two there.
- An attended transfer does not open the order on the second phone's screen.

## On the wire

- `GET /settings/desk_phones`: `{"links": [{"extension": "200", "device": "tab1"}, ...]}`; nothing linked
  until a manager links a phone.
- `PUT /settings/desk_phones` with the manager Bearer token (`POST /admin/session`): the same shape. An
  extension is letters, digits, `.`, `_` or `-` (digits as a rule); a device name is letters and digits, as
  the app keeps it; an extension once. A bad body is 422 with `message` saying why; a standby hub is 503
  `read_only`.
- `GET /phones/answered?device=tab1&wait=15&after=41`: `{"device": "tab1", "linked": true, "calls": [{"id":
  "1730000000.123:200", "extension": "200", "number": "+16175551234", "name": "LINDA CHEN", "dialed":
  "+17817296899", "at": 1730000010500, "age_ms": 1500, "seq": 42}], "cursor": 42}`: the calls answered on
  the device's phones in the last two minutes, oldest first, each once by `id` (the call's id on the PBX and
  the extension, the same on every hub), with its age on the hub's clock, which the app uses rather than its
  own, and its `seq` on this hub. With `wait` (seconds, 30 at most) the hub holds the request until a call
  newer than `after` (the `cursor` of the last answer, 0 at first) is there, or a manager changes the links,
  or the time is up, and answers at once a cursor beyond its own (its other hub's, or from before a restart).
  Without `wait` it answers at once. Device names match regardless of case.
- `GET /phones/status`: `configured` (a PBX is set), `host`, `connected`, `since`, `attempts`,
  `connections`, `events`, `last_error`, plus `answers` seen on any extension, `pops` that reached a linked
  screen, `waiting` screens with a request held at the hub right now, and `links` as counted in the setting.
- `GET /phones/extensions`: `{"extensions": [{"extension": "200", "online": true}, ...], "connected": true}`:
  the PBX's PJSIP (or SIP) endpoints whose name is a number, lowest first, asked of the PBX over the
  watcher's connection (`PJSIPShowEndpoints`, else `SIPpeers`; the AMI user needs the `system` or
  `reporting` read right for them), `online` when a phone is registered on it; empty with `connected` false
  while the hub is not watching a PBX. The app's Desk phones card picks extensions from it.
- `GET /devices`: `{"devices": [{"device": "mac1", "seen_ms": 1730000000000}, ...]}`: the screens the hub
  has heard from since it started (a sign-in, or the app's `GET /phones/answered` requests), by name, each
  with when it last did; kept in memory, so a hub just restarted lists only the screens that have spoken
  since. The card picks a phone's screen from it.
- Hub environment (`/opt/pos/.env`, written by `hubctl pbx link`): `POS_AMI_HOST` (`pbx` for the tunnel
  service; empty keeps the watcher off), `POS_AMI_PORT` (5038), `POS_AMI_USER` (`pos`), `POS_AMI_SECRET`,
  `POS_AMI_TLS` (`1` for Asterisk's TLS manager port, 5039, when a PBX is reached without the tunnel);
  `POS_PBX_SSH` (`user@host` for the tunnel) and `COMPOSE_PROFILES=pbx` to run it.
- The watcher logs in with `Events: call`, follows calls by `Linkedid` (every channel of a call shares
  it), reads the caller off the trunk's `Newchannel` (before FreePBX's caller-name rewrite) and counts a
  `DialEnd` with `DialStatus: ANSWER` whose dialed channel is an extension's (`PJSIP/200-...`, not a
  trunk's). It reconnects with a growing pause (1 to 10 seconds) after a drop, and runs for as long as the
  API does. Code: `backend/src/pos/phones/deskphones.py`; the app side: `apps/pos_app/lib/desk_phone.dart`,
  `desk_phone_watcher.dart`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `hubctl pbx status`: tunnel `restarting`, last words `Permission denied (publickey)` | The hub's key is not on the PBX (a line pasted from an example, `AAAA...`, is not the key) | `hubctl pbx link` again: it puts the key on the PBX; or check `/root/.ssh/authorized_keys` there holds the line `hubctl pbx key` prints |
| `"connected": false`, `last_error` `pbx does not resolve ...: the tunnel service is probably down` | The tunnel container is not running (as a rule the row above), so its name `pbx` resolves to nothing | `hubctl pbx status` shows the tunnel's log; fix what it says and the watcher connects on its own |
| Log says `Host key verification failed` | The PBX was reinstalled since the first connection | Delete `/opt/pos/pbx/known_hosts` on the hub, `hubctl restart` |
| `"connected": false`, `last_error` `Authentication failed` | The AMI secret | `hubctl pbx link` again with the secret from FreePBX |
| `last_error` `Connection refused` | The tunnel is down, or Asterisk's manager interface is off | `hubctl logs pbx`; on the PBX `asterisk -rx "manager show settings"` |
| Connected, `hubctl pbx tail` prints nothing on a pick-up | The AMI user lacks the `call` read right, or the phone is not a PJSIP/SIP extension | FreePBX, Settings, Asterisk Manager Users, `pos`, Read: `call` |
| `hubctl pbx tail` prints the answer, the screen does nothing | The extension is not linked to that device name, or nobody is signed in | Location settings, Desk phones: the device name as the screen's Settings show it |
| The card's Extension is typed, not a list, though the hub is connected | The AMI user may not list endpoints (the hub log says `did not list its extensions: Permission denied`), or the hub is from before the lists | FreePBX, Settings, Asterisk Manager Users, `pos`, Read: `reporting` (or `system`); `hubctl update` |
| A screen is missing from the Device list | The hub has not heard from it since the hub started (the app signs in or waits for calls on the other hub, or the screen has not been on) | Open the app on that screen, or pick **Other…** and type its device name |
| The order opens a second or two after the pick-up, not at once | The app on that screen, or its hub, is from before the waiting request: the screen asks once a second | `hubctl update` on the hub and the current app build on the screen; `hubctl pbx status` then counts the screen under `waiting` |
| The order opens late and `hubctl pbx tail` prints the answer late too | The delay is before the hub: the PBX reported the answer late (the tunnel adds milliseconds) | The hub does nothing in between, so look at the PBX: its load, and how the ring group dials the phone |
| The app's own call and the desk phone both open an order | The app's extension is linked as a desk phone of another device | Link each extension to the screen it stands at; the app skips only its own extension |
