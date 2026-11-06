# Push relay: calls and pick-ups on a locked or sleeping screen

A terminal at its station stays on and unlocked, and takes calls as [the phone in the app](../apps/pos_app/README.md#phone)
and [a desk phone linked to it](desk-phones.md) describe. The relay is for the rest: the iPhone in a pocket, the
iPad someone locked, the Galaxy whose screen went off, the Mac left alone. Each gets what its platform allows;
Apple's push service is the only outside service in it, and Android and the Mac need none.

| Screen | Locked or asleep, before | With the relay | Through |
| --- | --- | --- | --- |
| iPhone, iPad: the phone in the app | Silent: iOS suspends the app seconds after the lock, so the PBX finds no phone to ring | The system's call screen rings with the caller's number; slide to answer and the call runs in the app | A VoIP push from the hub (PushKit, CallKit) |
| iPhone, iPad: a desk phone linked to it | Nothing opens | A time-sensitive notification, "Phone 200 picked up · (781) 555-1234 · LINDA CHEN"; a tap opens the order | A notification push from the hub |
| Galaxy tablet or phone: the phone in the app | Android freezes the app minutes after the screen goes off | Rings, and the screen lights up with the call banner over the lock screen | The app keeps itself running with the screen off (a foreground service) |
| Galaxy: a desk phone linked to it | Nothing opens | The screen lights up and the order opens | The same |
| Mac, display off | Works, as long as the Mac itself is awake | The app keeps the Mac from sleeping on its own while the phone is on or a desk phone is linked; a call lights the display | A sleep hold in the app |
| Mac asleep (lid closed, Sleep chosen) | Silent | Still silent: a sleeping Mac takes nothing | |

## How it works

### Why the PBX has to wait for an iPhone

A push on its own would wake the iPhone too late. When the restaurant's number rings, ring group 600 dials
every listed extension at once; an iPhone whose app is suspended holds no registration on the PBX, so its leg
fails the instant it is dialed while the desk phones ring on. The push wakes the app a second later and the
app registers two seconds after that, and by then nobody is calling it; the ring group's second pass, 30
seconds later, would reach it, far too late for a restaurant.

So the PBX does two small things for an extension the hub can wake, in FreePBX's own pre-dial hook
(`macro-dialout-one-predial-hook`, which FreePBX runs just before it dials any extension): it tells the hub
to send the push, as an event on the manager interface the hub already watches, and it gives the phone up
to 8 seconds to register before the dial goes on. Only extensions the hub has marked in Asterisk's database
(`POSPUSH/302`) take this path; every other extension is dialed exactly as before, and the other members of
the ring group ring at once, since each member's dial runs in a channel of its own. The hook is step 7
below; it is a change to the PBX and is yours to make.

A call to a locked iPhone, step by step: the trunk rings (1); the ring group dials every member, the desk
phones ring (2); the hook finds 302 marked and unregistered, says `PosPush` and waits (3); the hub pushes
(4); iOS wakes the app, which hands the call to the system's call screen and registers with the PBX (5); the
hook sees 302 registered and dials it (6); the app matches the PBX's invitation to the call on the screen
(7), about four seconds after the call came in. Somebody picks up a desk phone in between: the iPhone's
screen ends on its own ("answered elsewhere"), since while it waits the app asks the hub every two seconds
whether the call still rings.

Android and the Mac need none of this: their app stays registered with the screen off, so the PBX finds
them as it does today.

### iPhone and iPad

Apple allows exactly one way to ring a locked device: a VoIP push (PushKit), which the app must hand to the
system's call screen (CallKit) the moment it arrives. So the app does both, and a locked iPhone rings the way
it rings for a cell call: the caller's number on the lock screen, slide to answer, mute and end on the
system's screen, the call itself in the app as today (hold, keypad, transfer, To go on the call strip once
the app is opened).

- The app asks Apple for a VoIP push token while the phone is switched on and tells the hub the token with
  its device name and extension (`PUT /push/devices`); the hub then marks the extension on the PBX as one
  it can wake. Phone off: the token is taken back and the mark removed. The Phone card under Settings says
  where this stands ("Woken when locked for calls to 302 and desk-phone pick-ups").
- A push means "a call for 302 is coming": the app reports it to the call screen at once (the number from
  the trunk, before FreePBX's caller-name rewrite), registers with the PBX in the background and waits for
  the PBX's invitation, which the hook sends within 2 to 4 seconds. Answered on the lock screen before it
  is there: the answer is held until the invitation arrives. Nothing arrives within 45 seconds, or the hub
  says the call was taken elsewhere: the call screen ends on its own.
- With the app open in front, every call goes through the system's call screen as well, so that Answer and
  End on either side mean the same; the app's own ring stays quiet while the system's screen shows the call.
- A desk phone linked to the iPhone or iPad picks up: the hub sends an ordinary notification, time-sensitive
  so it comes through a Focus, "Phone 200 picked up · (781) 555-1234 · LINDA CHEN". Tapping it opens the
  app, which asks the hub for the pick-up and opens the order as it does today. With the app open in front,
  no notification shows: the pick-up reaches it the way it does now.
- Audio: the app answers the call on the PBX only once iOS has the call's audio session up, so the voice
  path starts on the session the system prepared.

A development build from Xcode (`flutter run`) takes pushes from Apple's sandbox service and a distribution
build from the production one; the hub does not need to know which: it tries production first and moves a
token to the sandbox when Apple answers that it is not one of its own, in the same send, then remembers.

What it takes from Apple: the paid Apple Developer Program, because the Push Notifications capability is not
available to a free Apple ID; an APNs authentication key (one key serves every app of the team, and does not
expire); and the Xcode project set up for it, which is in the repository (the `voip` background mode, the
push entitlement). The iPhone and iPad part cannot be run where the app is built and tested, so the first
end-to-end test is on a real iPhone, step 8 below.

### Android tablets and phones

Android lets an app keep running with the screen off, so no push service is needed: the app starts a
foreground service (Android's term for "this app is doing something the user knows about", shown as a small
permanent notification, "POS phone is on") while the phone is on or a desk phone is linked to the screen.
With it, Android neither freezes the app nor cuts its network, so the registration with the PBX and the
request waiting at the hub both stay up with the screen off, and the PBX dials the tablet as it does today.

- A call: the app rings as now (on the ring volume) and posts a full-screen call notification, which turns
  the screen on and brings the app up over the lock screen with its banner; Answer and Decline are on the
  banner and on the notification. The POS shows over the lock screen whenever it is the app in front, as a
  terminal should (pressing power twice brings the POS back without the device's own unlock); the POS PIN
  is the lock that counts.
- A desk-phone pick-up: the screen turns on, the app comes up and the order opens, as it does today when the
  screen is on.
- Firebase (Google's push service) is not needed, so no Google project and nothing to create. It stays an
  option for later if a device ever has to reach the app with the app closed or force-stopped.

What it takes on the device: allow notifications (Android 13 and later ask), the app running in the
background without battery limits (a system dialog), and on Android 14 and later the full-screen
notification (a settings page). The Phone card under Settings lists what is still missing with an **Allow**
button that asks for each in turn. A tablet on its charger never enters Android's deep sleep, so the service
alone is enough there; a Galaxy phone in a pocket does, and the battery exemption keeps the network up
through it. On a Samsung, also Settings, Battery, Background usage limits, Never sleeping apps: add POS, so
Samsung's own sleeping rules leave it alone.

### Mac

A Mac takes calls whenever it is awake, display on or off, so the only thing to prevent is the Mac going to
sleep on its own. The app asks macOS not to idle-sleep the system while the phone is on or a desk phone is
linked (the same request a video player makes); the display still goes dark after its usual minutes, and a
call or a desk-phone pick-up lights it again and brings the app to the front. No push service, nothing to set
up: keep the Mac on power. A Mac put to sleep by hand, or a laptop with the lid closed and no external
display, is asleep and takes nothing, as a desk phone unplugged would.

### The hub

The hub sends every push, since it already watches the PBX and reaches the internet; the cloud, running the
same image, will send them the same way once it exists.

- **Push tokens.** The app tells the hub its tokens (`PUT /push/devices`: device name, platform, VoIP or
  notification, the token, the extension), stored in the hub's database like the location settings, so the
  second hub reads the same list. A token Apple reports as gone is dropped; the phone switched off takes its
  VoIP token back.
- **The Apple sender.** The APNs key lives on the hub in `/opt/pos/apns`, readable by the API alone;
  `hubctl push apple AuthKey_XXXX.p8 <key id> <team id>` puts it there, writes the ids to `/opt/pos/.env`
  and restarts the API. The hub talks to Apple over HTTP/2 with a signed token it renews every 50 minutes.
- **What triggers a push.** A `DialBegin` to a marked extension (the ring group's dial of it, or the hook's
  `PosPush` event, whichever comes first; the two count once per call) sends a VoIP push to the extension's
  tokens. An answer kept for a screen with a desk phone linked sends a notification push to that screen's
  tokens, one per call (`apns-collapse-id`), dropped by Apple if not delivered within a minute.
- **The mark on the PBX.** While it watches the PBX, the hub keeps `POSPUSH/<extension>` in Asterisk's
  database for every extension with a VoIP token, through the manager interface (`DBPut`, `DBDelTree`): at
  connect and on every change. The manager user needs the `system` write right for it, and the `user` read
  right to see the hook's event; `hubctl push status` says when either is missing.
- **The call's state.** `GET /phones/calls/<id>` answers ringing, answered or ended for a call the hub is
  following, so a woken iPhone whose invitation never comes can end its call screen as "answered elsewhere"
  instead of ringing on.
- **Status and test.** `GET /push/status` (also in `hubctl status` and `hubctl push status`): the key
  configured, the tokens by kind, pushes sent and failed, Apple's last error, the marks on the PBX, whether
  the hook has spoken. `hubctl push test <device>` sends a test notification to a screen and prints Apple's
  answer; `hubctl push test <device> voip` a test call the phone shows and ends by itself.

With two hubs each one sends its own pushes; the phone shows one call (the second push for the same call is
taken down at once) and one notification (the same collapse id).

## Setting it up

About an hour in all, in this order. Steps 1 to 3 are at Apple and can be done first; 4 to 7 need the merged
code on the hub (`hubctl update`) and in the app build.

1. **Apple Developer Program.** Sign in at [developer.apple.com/account](https://developer.apple.com/account)
   with the Apple ID of team N46M58VZD4 (the one in the Xcode project). If the page offers "Join the Apple
   Developer Program", the membership is missing: it is $99 a year, and push is not available without it. The
   Team ID is on the Membership details page.
2. **The APNs key.** Certificates, Identifiers & Profiles, **Keys**, +: name `POS push`, tick **Apple Push
   Notifications service (APNs)**, Continue, Register, **Download**. The file is `AuthKey_<KEYID>.p8`; Apple
   lets you download it once, so keep it with your other keys, and never in the repository. Note the Key ID
   shown beside it. One key serves every app of the team and does not expire.
3. **The App ID.** Identifiers, `org.chinasky.posApp`: Push Notifications ticked. Xcode ticks it on its own
   when it signs the project with the entitlement in it; if a build complains that the capability is
   missing, tick it here and build again.
4. **Xcode.** `git pull`, open `apps/pos_app/ios/Runner.xcworkspace`, Runner, Signing & Capabilities: your
   team, and Push Notifications plus Background Modes (Voice over IP, Audio) already listed. Then
   `flutter run -d <iphone> --release` as before. The Mac and the Galaxy need no Xcode step:
   `flutter run -d macos --release` and the CI APK as before.
5. **The hub.** Copy the key to the hub, `scp AuthKey_XXXX.p8 <user>@172.19.1.179:`, then on the hub
   `hubctl update` and `hubctl push apple ~/AuthKey_XXXX.p8 XXXX N46M58VZD4`. It moves the key to
   `/opt/pos/apns`, restarts the API and prints the push status, `key: XXXX, team N46M58VZD4, ...`. The
   second hub gets the same two commands when it exists.
6. **FreePBX, the manager user.** Settings, Asterisk Manager Users, `pos`: under Read add **user** (keep
   call and reporting), under Write add **system**. Submit, Apply Config. The hub needs them to see the
   hook's event and to mark the extensions it can wake; until then `hubctl push status` reports
   `TROUBLE marking the PBX: Permission denied`.
7. **FreePBX, the hook.** Admin, Config Edit, `extensions_custom.conf` (or
   `nano /etc/asterisk/extensions_custom.conf` over SSH). If a `[macro-dialout-one-predial-hook]` section is
   already there, add the lines below inside it, after its last line; otherwise paste the whole block at the
   end. Save, then **Apply Config** (or `fwconsole reload`). Check with
   `asterisk -rx "dialplan show macro-dialout-one-predial-hook"`, which must list the lines.

   ```
   [macro-dialout-one-predial-hook]
   ; POS: an extension the hub can wake (marked POSPUSH by the hub) that has no phone registered:
   ; ask the hub for the push, then give the phone up to 8 seconds to register before the dial goes on.
   exten => s,1,ExecIf($[${DB_EXISTS(POSPUSH/${DEXTEN})} = 0]?MacroExit())
   exten => s,n,ExecIf($["${DEVICE_STATE(${DB(DEVICE/${DEXTEN}/dial)})}" != "UNAVAILABLE"]?MacroExit())
   exten => s,n,UserEvent(PosPush,Extension: ${DEXTEN},Linkedid: ${CHANNEL(linkedid)})
   exten => s,n,Set(POSWAIT=16)
   exten => s,n,While($[${POSWAIT} > 0 & "${DEVICE_STATE(${DB(DEVICE/${DEXTEN}/dial)})}" = "UNAVAILABLE"])
   exten => s,n,Wait(0.5)
   exten => s,n,Set(POSWAIT=$[${POSWAIT} - 1])
   exten => s,n,EndWhile
   exten => s,n,MacroExit()
   ```

   Without the hook the hub still pushes and the iPhone's screen still rings, but its registration comes
   after its leg of the ring group failed: the call reaches the app only on the ring group's next pass, 30
   seconds later, if nobody picked up by then.
8. **The iPhone.** Open the app, Settings, Phone on, Save; allow notifications when the Phone card asks
   (**Allow**). The card reads "Woken when locked for calls to 302 and desk-phone pick-ups" once the hub
   holds the tokens (`hubctl push status` lists them; `hubctl push test iphone1` sends a test notification,
   `hubctl push test iphone1 voip` a test call). Lock the iPhone and call 781 729 6899 from a cell: the lock
   screen rings with the number; slide to answer, talk, End.
9. **The Galaxy.** Open the app, Settings, Phone on, Save, then **Allow** on the Phone card: notifications,
   then "Allow" in the battery dialog, then the full-screen notification switch on Android 14 and later.
   Settings, Battery, Background usage limits, Never sleeping apps: add POS. Lock the tablet and call: the
   screen lights up with the call banner.
10. **The Mac.** Nothing: with the phone on, the app keeps the Mac awake. Keep it on power.

## Limits

- The iPhone and iPad part is compiled on CI (the apple-build workflow) and first run on a real iPhone.
- A Focus (Do Not Disturb) on the iPhone silences VoIP calls unless the app is allowed under the Focus's
  Apps; the notification for a desk-phone pick-up is time-sensitive, which a Focus lets through by default.
- A desk phone picking up while the iPhone's screen rings ends that screen within two seconds. An attended
  transfer still opens nothing on the second phone, as before.
- Reinstalling the app on an iPhone changes its token; the app sends the new one at the next start, so
  nothing to do, but a call in that minute would be missed.
- The Mac put to sleep by hand stays asleep; an Android app force-stopped from the app info screen does
  nothing until it is opened again.
- An iPad or Galaxy that stands at a station is best left as it is, Auto-Lock off (or Guided Access),
  plugged in: the relay is for the phone in a pocket, the tablet someone locked, the Mac left alone.

## On the wire

- `PUT /push/devices` with `{"device": "iphone1", "platform": "ios", "kind": "voip", "token": "<hex>",
  "extension": "302"}` (`kind` `alert` for the notification token, no extension): `{"ok": true,
  "configured": true, "kind": "voip", "extension": "302", "env": null}`, `configured` saying whether the
  hub has an Apple key, `env` where Apple took the token once known. A bad value is 422 with `message`
  saying why; a standby hub is 503 `read_only`. The app sends its tokens at every start and on every
  change, and `DELETE /push/devices/<token>` (`{"ok": true, "removed": true}`) when the phone is turned
  off, so the VoIP token lasts only while the phone is on.
- `GET /push/status`: `configured`, `key_id`, `team_id`, `bundle`, `sent`, `failed`, `last_error`,
  `last_sent`, `by_env`; `devices` (`{"voip": 1, "alert": 2}`), `pushes` (`{"ring": 3, "pop": 1, "test":
  2}`), `pbx` (connected), `marks` (the extensions marked on the PBX), `marks_error`, `marked_at`,
  `hook_seen` (when the hook last spoke), and `list`, the tokens (shortened) with their device, kind,
  extension and environment.
- `POST /push/test` with `{"device": "iphone1", "kind": "alert"}` (or `voip`): `{"device", "kind",
  "configured", "tokens", "sent", "results": [{"device", "platform", "kind", "ok", "env", "reason"}]}`.
- `GET /phones/calls/<id>`: `{"call": "1730000000.123", "state": "ringing", "answered": [], "number":
  "+16175551234", "name": "LINDA CHEN", "dialed": "+17817296899"}`; `state` is `ringing`, `answered` (with
  the extensions that did), `ended`, or `unknown` for a call the hub has not seen (or saw more than ten
  minutes ago).
- The VoIP push: `{"kind": "ring", "call": "<linkedid>", "extension": "302", "number": "+16175551234",
  "name": "LINDA CHEN", "dialed": "+17817296899", "at": <ms>}` (`apns-push-type: voip`, topic
  `org.chinasky.posApp.voip`, expiration 0). The pick-up notification: `aps.alert` title "Phone 200 picked
  up", body "(781) 555-1234 · LINDA CHEN", sound default, `interruption-level` time-sensitive, `thread-id`
  `desk-phone`, plus `kind: pop` and the pick-up's `id`, `extension`, `number`, `name`; collapse id the
  pick-up's id, expiration a minute. A test: `kind: test` either way.
- The PBX side: the hub logs in with `Events: call,user` when the relay is on, takes `UserEvent: PosPush`
  (`Extension`, `Linkedid`) and `DialBegin` to `Local/<ext>@` or `PJSIP/<ext>-` as a ring, once per (call,
  extension) in 45 seconds, and keeps the `POSPUSH` family with `DBDelTree` and `DBPut`. Hub environment
  (`/opt/pos/.env`, written by `hubctl push apple`): `POS_APNS_KEY` (the .p8 inside the container,
  `/apns/AuthKey_XXXX.p8`), `POS_APNS_KEY_ID`, `POS_APNS_TEAM_ID`, `POS_APNS_BUNDLE_ID`
  (`org.chinasky.posApp`); `hubctl push forget` removes them.
- The device's part is one method channel, `org.chinasky.pos/calls` (`apps/pos_app/lib/call_screen.dart`):
  the app says `ready`, `keepAwake`, `incoming`, `answer`, `end`, `connected`, `ended`, `wake`,
  `readiness`, `prepare`; the device says `token`, `pushed`, `answer`, `end`, `mute`, `gone`, `opened`.
  iOS: `ios/Runner/AppDelegate.swift` (the engine runs from launch so a push can wake the app with no
  screen; `SceneDelegate.swift` puts the screen on it); Android: `CallChannel.kt`, `PhoneService.kt`,
  `MainActivity.kt`; Mac: `macos/Runner/MainFlutterWindow.swift`. The hub side:
  `backend/src/pos/push/` (`apns.py` the sender, `devices.py` the tokens, `relay.py` the triggers and the
  marks); the app's registration: `lib/push.dart`; the pushed call in the phone: `lib/phone.dart`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The Phone card says "Waiting for the push token from iOS" | The build has no push entitlement, or runs in the simulator | Step 4: the team signed in, Push Notifications under Signing & Capabilities; a real iPhone |
| "Push not registered with the hub: ..." on the card | The hub is from before the relay, or cannot be reached | `hubctl update`; the hub address under Settings |
| `hubctl push status`: `key: none` | No key on the hub | Step 5 |
| `hubctl push test iphone1`: `FAILED: BadDeviceToken` on both environments | The key or the Team ID belongs to another team than the app's signing | Step 1 and 2: the key from team N46M58VZD4, the same team in Xcode |
| `FAILED: TopicDisallowed` or `InvalidProviderToken` | The App ID has no push capability, or the key id is wrong | Step 3; `hubctl push apple` again with the right id |
| `TROUBLE marking the PBX: Permission denied` | The manager user lacks the `system` write right | Step 6 |
| `hubctl push status`: "the pre-dial hook has not spoken yet" after a locked iPhone was called | The hook is not in place, or the manager user lacks the `user` read right | Step 7; step 6 |
| The iPhone rings 30 seconds after the desk phones | The hook is missing: the PBX reached the iPhone only on the ring group's second pass | Step 7 |
| The lock screen rang, but "connecting" never became a call | The PBX's invitation did not reach the app: the iPhone's network did not come up, or the PBX refused the registration | The app's status icon once open says why; the PBX's Intrusion Detection whitelist, as in the softphone guide |
| The Galaxy does not ring with the screen off | The service is not running, or Samsung put the app to sleep | Settings, Phone, **Allow**; Never sleeping apps (step 9); the "POS phone is on" notification must show |
| The Galaxy rings but the screen stays dark | The full-screen notification is not allowed (Android 14+) | Step 9, the full-screen switch; **Allow** on the Phone card opens it |
| The Mac went to sleep with the phone on | The Mac was put to sleep by hand, or the lid closed | Keep it awake and on power |
