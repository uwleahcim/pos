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
- The app on every device asks its hub for such answers: every second while a phone is linked to it, every
  ten seconds while none is. A fresh answer (less than 45 seconds old) does what picking up in the app
  does: the hub is asked for the number's last order of the day (`GET /orders/last`), which opens; with
  none, the to-go form opens with the number, the phone channel and the caller-ID name. Only while someone
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

1. `hubctl pbx key` prints the hub's public key (made on first use, kept in `/opt/pos/pbx`). Add it to
   `/root/.ssh/authorized_keys` on the PBX, from a machine that already reaches the PBX by SSH:

   ```
   ssh root@freepbx.chinasky.org 'echo "ssh-ed25519 AAAA... pos-pos-hub1" >> ~/.ssh/authorized_keys'
   ```

2. `hubctl pbx link root@freepbx.chinasky.org` asks for the AMI user's secret (FreePBX, Settings, Asterisk
   Manager Users, user `pos`; the user needs `call` among its read rights, which it has), writes the link to
   `/opt/pos/.env` and starts the tunnel and the watcher. `hubctl pbx status` a few seconds later shows
   the tunnel up and `"connected": true`; `hubctl status` has a `pbx:` line from then on.
3. `hubctl pbx tail` prints each call as a desk phone answers it, with the extension and the caller, as the
   hub sees it: the quickest check that the PBX reports what the links need. Pick up a desk phone on a
   test call and the line appears.

In the app, on any terminal, as a manager: Orders, **Location**, the manager PIN, then **Desk phones**: the
card says how the hub stands with the PBX; **Add phone**, the extension (200), the device name of the
screen (the name that screen shows under Settings; the phone-and-screen button fills in the screen you
stand at), **Save**. The second hub of a location gets the same `hubctl pbx` steps; a device takes the
answers from whichever hub it talks to, and the same call is one call on both.

## Limits

- The screen has to be on and someone signed in, as for a call taken in the app.
- A call that rang before the hub connected to the PBX still opens if the number is an outside one; one
  that rang while the hub was down does not.
- The answer reaches the screen within about a second of the pick-up (the app asks every second).
- An attended transfer does not open the order on the second phone's screen.

## On the wire

- `GET /settings/desk_phones`: `{"links": [{"extension": "200", "device": "tab1"}, ...]}`; nothing linked
  until a manager links a phone.
- `PUT /settings/desk_phones` with the manager Bearer token (`POST /admin/session`): the same shape. An
  extension is letters, digits, `.`, `_` or `-` (digits as a rule); a device name is letters and digits, as
  the app keeps it; an extension once. A bad body is 422 with `message` saying why; a standby hub is 503
  `read_only`.
- `GET /phones/answered?device=tab1`: `{"device": "tab1", "linked": true, "calls": [{"id":
  "1730000000.123:200", "extension": "200", "number": "+16175551234", "name": "LINDA CHEN", "dialed":
  "+17817296899", "at": 1730000010500, "age_ms": 1500}]}`: the calls answered on the device's phones in
  the last two minutes, oldest first, each once by `id` (the call's id on the PBX and the extension, the
  same on every hub) and with its age on the hub's clock, which the app uses rather than its own. Device
  names match regardless of case.
- `GET /phones/status`: `configured` (a PBX is set), `host`, `connected`, `since`, `attempts`,
  `connections`, `events`, `last_error`, plus `answers` seen on any extension, `pops` that reached a linked
  screen, and `links` as counted in the setting.
- Hub environment (`/opt/pos/.env`, written by `hubctl pbx link`): `POS_AMI_HOST` (`pbx` for the tunnel
  service; empty keeps the watcher off), `POS_AMI_PORT` (5038), `POS_AMI_USER` (`pos`), `POS_AMI_SECRET`,
  `POS_AMI_TLS` (`1` for Asterisk's TLS manager port, 5039, when a PBX is reached without the tunnel);
  `POS_PBX_SSH` (`user@host` for the tunnel) and `COMPOSE_PROFILES=pbx` to run it.
- The watcher logs in with `Events: call`, follows calls by `Linkedid` (every channel of a call shares
  it), reads the caller off the trunk's `Newchannel` (before FreePBX's caller-name rewrite) and counts a
  `DialEnd` with `DialStatus: ANSWER` whose dialed channel is an extension's (`PJSIP/200-...`, not a
  trunk's). It reconnects with a growing pause (1 to 30 seconds) after a drop, and runs for as long as the
  API does. Code: `backend/src/pos/phones/deskphones.py`; the app side: `apps/pos_app/lib/desk_phone.dart`,
  `desk_phone_watcher.dart`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `hubctl pbx status`: the tunnel restarts, log says `Permission denied (publickey)` | The hub's key is not on the PBX | Step 1 again; check `/root/.ssh/authorized_keys` on the PBX |
| Log says `Host key verification failed` | The PBX was reinstalled since the first connection | Delete `/opt/pos/pbx/known_hosts` on the hub, `hubctl restart` |
| `"connected": false`, `last_error` `Authentication failed` | The AMI secret | `hubctl pbx link` again with the secret from FreePBX |
| `last_error` `Connection refused` | The tunnel is down, or Asterisk's manager interface is off | `hubctl logs pbx`; on the PBX `asterisk -rx "manager show settings"` |
| Connected, `hubctl pbx tail` prints nothing on a pick-up | The AMI user lacks the `call` read right, or the phone is not a PJSIP/SIP extension | FreePBX, Settings, Asterisk Manager Users, `pos`, Read: `call` |
| `hubctl pbx tail` prints the answer, the screen does nothing | The extension is not linked to that device name, or nobody is signed in | Location settings, Desk phones: the device name as the screen's Settings show it |
| The app's own call and the desk phone both open an order | The app's extension is linked as a desk phone of another device | Link each extension to the screen it stands at; the app skips only its own extension |
