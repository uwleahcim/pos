# Back to sign-in after sending

On a screen several people share, the person who just sent an order should not stay signed in for the next
one who walks up. A device can be set so that sending ends with the sign-in pad.

It is off on every device to start. Off, leaving a check goes back to the tables, still signed in, as it
always has.

## Turning it on

On the device itself: **Settings › Back to sign-in after sending**, then **Save**. Each device keeps its own
switch: on for the screen at the server station, off for a phone one server carries.

## What it does

Once dishes were sent to the kitchen from a check, **leaving that check signs out**:

- **Fire everything and leave** reads **Fire everything and sign out** on such a device, and does both.
- **A course fired on its own** (Fire Appetizers) still stays on the check, signed in, for the next round.
  Going back from the check after that signs out.
- **A to-go order** that is sent (Send, or Pay & send) signs out once it is sent.
- **A check that was only looked at**, or one with dishes rung in and nothing sent, is left as ever: back to
  the tables, still signed in.

The next person signs in by PIN, face or tag and starts on the tables, not in the last check.

## Good to know

- What was sent is sent: signing out does not wait for the kitchen's printers, and an order that could not
  reach the hub yet still goes when the hub is back, as before.
- Where the location signs people out when the camera no longer sees them (`face-signin.md`), that goes on
  as before; this switch only adds the sign-out after a send.
- An idle screen can lock itself as well (`idle-lock.md`). The two are separate: this one signs out and
  closes the check, the lock keeps what was open.
- Anybody who can open the device's Settings can change the switch, as with the device's name.
- Not tried on the real devices from here.

## For developers

- `Settings.signOutAfterSend` (the preference `sign_out_after_send`), `saveSignOutAfterSend`.
- `OrderScreen` notes a send from itself (`_sentHere`: a `fire` from the Fire menu, Send, or Pay & send) and
  hears of its own leaving through a `PopScope`. Leaving after a send on such a device calls
  `Session.signOut()` in a microtask, since the navigator is still busy with the pop; `SessionWatcher`
  then closes whatever else is open and the app's first screen is the sign-in pad.
- Tests: `apps/pos_app/test/sign_out_after_send_test.dart`.
