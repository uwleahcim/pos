# Recorded calls on a phone order

A phone order is taken by ear, and when the bag is wrong the question is what was said. The PBX already
records every call. The hub reads those recordings and puts each one on the order it belongs to, so the
call can be played back from the order to check it (Mike, 2026-11-26). The recording is the PBX's own: the
app records nothing, so a call taken on a desk phone is there just like one taken in the app.

Transcripts were left out for now (Mike's choice, 2026-11-26): a transcript needs a speech service, and
with none, no call audio leaves the PBX and the hub. Stereo recordings (below) are what a transcript would
want later, so nothing here has to be done twice.

## What it looks like

- An order whose phone number has recorded calls shows one line under its header: **2 recorded calls ·
  Listen**. An order with no number, or a number with no calls, shows nothing.
- The line opens **Recorded calls**: every call with that number from the day the order was opened to the
  day it is wanted for, oldest first. Each says the time, who called whom (They called / We called them),
  how long it runs, and which call the order was opened during ("the order was opened on this call").
- Play asks for a PIN once: the PIN of someone who may listen. Then the call plays in the sheet, with
  pause and a bar to drag. One PIN plays every call of that order while the order stays open.
- A call that ends while the order is open shows up on it within a few seconds, without anyone looking
  again.

## Who may listen

Playing a recording is a power of its own, **Listen to recorded calls** (Location settings, **Who may do
what**, under "A PIN on a check"). It starts with managers and owners only; hand it to servers, hosts or
whoever takes the phone there. Each play is written to the hub's log with the name of whoever's PIN it
was, the call and the order.

That calls exist (when, how long, who called whom) is shown to anyone who can see the order; only the
sound is behind the PIN.

## How it works

```
caller ──▶ PBX (FreePBX) records the call ──▶ /var/spool/asterisk/monitor/2026/11/26/…
                                                     ▲
                                 the hub's recordings key: list, and hand one over as an MP3
                                                     │
 order with +1 617 555 1234 ◀── hub: the calls with that number that day ──▶ app: Recorded calls
```

- **The hub asks, the PBX answers.** The hub has an SSH key of its own for this (not the one of the
  desk-phone tunnel). On the PBX that key can run one small program, `/usr/local/sbin/pos-recordings`,
  and nothing else: no shell, no forwarding. The program only reads. It answers three things: what it is
  (`about`), which recordings changed since a moment (`list`), and one recording as an MP3 (`get`).
- **The list.** The hub keeps a list of the calls (number, direction, when, how long), never the sound.
  It looks at the PBX every ten minutes, a few seconds after every call the desk-phone watcher sees end,
  and when an order's calls are read. The first look goes back 90 days. Calls between extensions and
  numbers shorter than seven digits are left out.
- **Which calls go with an order.** The ones with the order's phone number, from the business day the
  order was opened to the business day it is wanted for (at most 40). The call during which the order was
  opened is marked.
- **The sound.** A recording is fetched only when someone plays it. FreePBX's own files are GSM inside a
  `.WAV`, which phones and tablets do not play, so the PBX program turns the one asked for into an MP3 on
  the way (about a quarter of a second). The hub keeps what was played for 30 days, up to 1 GB, so a
  second listen does not go back to the PBX. Nothing of it stays on the phone or tablet after the sheet
  closes.
- **The PBX stays the place the recordings live.** The hub deletes nothing there. A recording removed on
  the PBX drops off its order the next time someone tries to play it.

## Setting it up

In this order, after the pull request is merged:

1. On the hub: `sudo hubctl update`.
2. On the hub: `sudo hubctl pbx recordings link`. It says what it is about to put on the PBX and asks
   before doing it:
   - `/usr/local/sbin/pos-recordings` (the program above; it only reads),
   - `/usr/local/sbin/pos-stereo` (joins the two sides of a call into one stereo file; nothing runs it
     until the stereo step below is added),
   - one line in root's `~/.ssh/authorized_keys` for the hub's recordings key, limited to
     `pos-recordings`.

   No PBX setting is changed and FreePBX is not touched. The PBX is the one `hubctl pbx link` already
   knows; it asks for the PBX's root password once where the hub's desk-phone key is limited to its
   tunnel (`desk-phones.md`, "Limiting the hub's key"). At the end it says how many calls it found.
3. Rebuild the app on every device.
4. In the app: Location settings, **Who may do what**, **Listen to recorded calls**, if anyone besides
   managers should listen.

`sudo hubctl pbx recordings status` says at any time whether the hub reads the recordings, how many calls
it knows, when it last looked and whether the stereo step is in place.

Calls recorded before the link are there too (90 days back), so yesterday's phone orders show their calls
right away.

## Stereo: the caller in one ear, the restaurant in the other

FreePBX records both voices mixed into one channel. That plays fine, but two voices talking over each other
are hard to tell apart, and a transcript later could not say who said what. FreePBX has no switch for
stereo. The recording underneath (Asterisk's MixMonitor) can also write each side of a call to a file of
its own, and that is what the stereo step turns on, for the calls sent through it:

- FreePBX's own recording is made exactly as before, same name, same place.
- Beside it, each side is written to its own file while the call runs. When the call ends,
  `/usr/local/sbin/pos-stereo` joins the two into one MP3, the caller on the left and the restaurant on
  the right, and removes the two side files: `2026/11/26/pos-<the call's id>.mp3`.
- The hub plays the stereo file where there is one, and the sheet says so.

This is three changes on the PBX, all of them yours to make. None is made by the hub.

### 1. Add the step to the dialplan

On the PBX, as root, paste this as it is (it adds six lines to the end of FreePBX's file for custom
dialplan, which FreePBX itself never rewrites):

```sh
cat >> /etc/asterisk/extensions_custom.conf <<'EOF'

[pos-stereo]
exten => s,1,GotoIf($["${POS_LEGS}" != ""]?done)
 same => n,Set(__POS_LEGS=${STRFTIME(${EPOCH},,%Y/%m/%d)}/pos-${UNIQUEID})
 same => n,Set(__MONITOR_REC_OPTION=${MONITOR_REC_OPTION}r(${POS_LEGS}-in.wav)t(${POS_LEGS}-out.wav))
 same => n,Set(__MIXMON_POST=/usr/local/sbin/pos-stereo ${POS_LEGS})
 same => n(done),Return()
EOF
asterisk -rx "dialplan reload"
asterisk -rx "dialplan show pos-stereo"
```

The last command should print the five lines back. Nothing uses them yet. (The same lines are in
`infra/hub/pbx/pos-stereo.conf`.)

### 2. Make it a destination FreePBX can route to

FreePBX web page, **Admin › Custom Destinations › Add Destination**:

| Field | Value |
|---|---|
| Target | `pos-stereo,s,1` |
| Description | `POS stereo` |
| Return | **Yes** |
| Destination (after return) | **Call Recording** › **Record call** (where the inbound route points today) |

Submit.

### 3. Send incoming calls through it

**Connectivity › Inbound Routes › All incoming › Set Destination**: change it from Call Recording ›
Record call to **Custom Destinations › POS stereo**. Submit, then **Apply Config**.

The path of a call is then: All incoming, POS stereo, Record call, and on from there as today (the caller-ID
step, then ring group 600).

### Check it

1. Call the restaurant from a cell phone, pick up, say a few words on each side, hang up.
2. On the hub: `sudo hubctl pbx recordings status` should say "stereo: the step is in place".
3. On the PBX: `ls -l /var/spool/asterisk/monitor/$(date +%Y/%m/%d)/ | tail -3` should show the usual
   `.WAV` and a `pos-….mp3` beside it. No `-in.wav` or `-out.wav` should be left a few seconds after the
   call.
4. Open or start an order with that cell number and play the call: with headphones, the caller is on the
   left and the restaurant on the right, and the sheet says "Stereo".

If step 3 shows no `pos-….mp3`: `asterisk -rx "dialplan show customdests"` should show a line with
`Gosub(pos-stereo,s,1())` followed by a `Goto` to `ext-callrecording`. If the `-in.wav` and `-out.wav`
files are there but no MP3, run `/usr/local/sbin/pos-stereo 2026/11/26/pos-<id>` by hand (the path without
the ending) and see what it says; the PBX needs `sox` and `lame`, or `ffmpeg` (it has all three today).

### What stereo does not cover

- **Calls the restaurant places** stay mixed in one channel. They do not come in through the inbound
  route, and sending them through the step means editing FreePBX's outbound dialplan, which is more
  than it is worth for a call back. They still attach and play.
- **Calls recorded before the step** stay as they are.

### Disk

The stereo file is about 0.5 MB a minute on top of FreePBX's own recording (about 0.1 MB a minute). At
the roughly 31 hours of calls a month seen in November 2026 that is about 0.9 GB a month; the PBX had
35 GB free. Neither FreePBX nor the POS ever deletes recordings: when the disk gets tight, delete the
oldest month folders under `/var/spool/asterisk/monitor/`.

### Taking stereo off

**Connectivity › Inbound Routes › All incoming**: set the destination back to **Call Recording › Record
call**, Submit, Apply Config. Calls record as before from the next one. The Custom Destination and the
dialplan lines can stay; nothing runs them. To remove those too: delete the Custom Destination, and
delete the `[pos-stereo]` lines from `/etc/asterisk/extensions_custom.conf`, then
`asterisk -rx "dialplan reload"`.

## Telling callers they are recorded

Massachusetts is an all-party state: recording a phone call without the other person knowing is against
the law there (M.G.L. c. 272 § 99). In November 2026 the PBX recorded every call and played no notice.
This is the usual fix, and it is worth doing whether or not the POS reads the recordings. It is not legal
advice; ask your lawyer if in doubt.

1. **Admin › System Recordings › Add Recording.** Name it `Call recorded notice`. Upload a sound file or
   record it from an extension. Something like: "Thank you for calling. This call is recorded so we get
   your order right."
2. **Applications › Announcements › Add Announcement.** Description `Call recorded notice`, Recording:
   the one from step 1, Allow Skip: No, Destination after Playback: **Custom Destinations › POS stereo**
   (or **Call Recording › Record call** if stereo is not set up).
3. **Connectivity › Inbound Routes › All incoming › Set Destination**: **Announcements › Call recorded
   notice**. Submit, Apply Config.

A caller then hears the notice, and only after it does the recording start and the phones ring.

Two more things the notice does not cover:

- **Calls the restaurant places are recorded too**, and the customer hears no notice on those. Either
  whoever calls says so at the start ("this call is recorded"), or recording of outgoing calls is
  turned off in FreePBX.
- **Staff** are on every recording. Tell them, in writing.

## When something is off

| What you see | What it is |
|---|---|
| No "recorded calls" line on a phone order | The order has no phone number, the number has no recorded call that day, or the hub does not read the recordings: `sudo hubctl pbx recordings status` |
| "The phone server did not answer the hub just now" in the sheet | The hub's last look at the PBX failed; the list may miss a call of the last minutes. It looks again by itself |
| "The phone server did not answer. Try again in a moment." on Play | The PBX could not be reached for that recording. A call played before still plays (the hub kept it) |
| "The phone server no longer has that recording." | The file was deleted on the PBX |
| "Only managers can listen to recorded calls." | The PIN typed is not one that may listen: Who may do what |
| "This device could not play the recording." | The device's player refused the MP3; say which device |
| `status` says the program on the PBX is an older version | `sudo hubctl pbx recordings link` again after a hub update |
| `status` says the PBX has neither sox with lame nor ffmpeg | On the PBX: `apt install sox lame` |

`sudo hubctl pbx recordings unlink` makes the hub stop reading the recordings and says what to remove on
the PBX by hand. Nothing on the PBX is deleted by it.

## What has not been tried on the real PBX

The PBX was read once, with Mike's go-ahead, and not changed (2026-11-26: FreePBX 17, Asterisk 22.11,
Debian 12; recordings mono GSM `.WAV`, named `generic-<line>-<caller>-<date>-<time>-<id>.WAV` and
`out-<dialed>-<extension>-…`). Everything else was tried in a sandbox:

- The stereo step was proven on a test Asterisk 20.6 with FreePBX 17's own recording lines, not on
  Asterisk 22.11 and not through FreePBX's pages. That a Custom Destination with Return set to Yes runs
  the step and then goes on to the recording is read from FreePBX's source, not seen on a call.
- `hubctl pbx recordings link`, the key limited to one program, listing, fetching and turning a GSM
  recording into an MP3 were tried end to end against a local SSH server with made-up recordings, not
  against the PBX.
- Playback was tried in the app's tests with a stand-in player, not on a real iPad, iPhone, Mac or
  Android tablet.

## For developers

- Hub: `backend/src/pos/phones/recordings.py` (the list, the matching, the cache, the PBX over SSH) and
  `backend/src/pos/api/calls.py`:
  - `GET /orders/{id}/calls`: `{order_id, phone, linked, problem, calls: [{id, direction, started_ms,
    seconds, stereo, extension, opened}]}`; open like the order itself.
  - `GET /orders/{id}/calls/{call_id}/audio`: the MP3, for a session (`POST /admin/session`) whose holder
    has the power `calls`. 404 `unknown_call` when the call is not one of the order's, 404 `gone`, 424
    `pbx_unreachable` or `pbx_failed`. Never a 5xx for a PBX that is away: the app takes a 5xx for a hub
    that is down and changes hubs.
  - `GET /phones/recordings`: where the hub stands, for `hubctl pbx recordings status`.
  - A look that found something new tells the change feed (`GET /live`), topic `calls`, and an open
    order reads its calls again.
- PBX side: `infra/hub/pbx/pos-recordings`, `pos-stereo`, `pos-stereo.conf`. Settings on the hub:
  `POS_PBX_RECORDINGS` (user@host, written by `hubctl`), the key in `/opt/pos/pbx-recordings/`, the cache
  in the volume `pos-recordings`.
- App: `lib/calls.dart`, `lib/call_player.dart` (the speaker behind an interface, so tests stand in for
  it), `lib/screens/calls_sheet.dart`, and the line on `lib/screens/order_screen.dart`.
- Tests: `backend/tests/phones/test_recordings.py` (it runs the real `pos-recordings` and `pos-stereo`
  where `sox` and `lame` are installed, as in CI) and `apps/pos_app/test/calls_test.dart`.
- A transcript later: the stereo MP3 is what a speech service wants (one speaker a channel). It would be
  a step after a look finds a new stereo file, with the text kept beside the call's row and shown in the
  sheet.
