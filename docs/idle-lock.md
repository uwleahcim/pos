# Locking an idle screen

A screen that someone left signed in can lock itself. After the minutes the device was given, with nobody
touching it, the sign-in pad comes over whatever was open, and the next touch has to say who is there.

It is off on every device to start.

## Turning it on

On the device itself: **Settings › Lock this screen when idle**. Tap the minutes (1, 2, 3, 5, 10, 15 or 30)
or **Never**, then **Save**. Each device keeps its own pick, so the bar's screen can lock after two minutes
and the one in the office never.

## What counts as somebody being there

A finger on the screen, a click, the mouse moving over the app, the wheel, and any key on the keyboard (a
badge reader types, so a badge counts). The minutes start over with each of them, and with every sign-in.

A call ringing, an order changing on another screen and a ticket printing are not somebody at this screen.

## What a locked screen looks like

The sign-in pad, headed **Locked**, with one line above it: "Locked after 5 minutes untouched. Amy was signed
in. Nothing was closed." It unlocks the way the sign-in screen signs in: a PIN, a face where the location
signs in by face, a tag held to the reader. The call banner still shows over it, as it does over the
sign-in screen.

## What happens to what was open

Nothing is closed and nothing is lost.

- **The person who was there** signs in and finds the screen exactly as it was: the same order, the same
  sheet or dialog over it, what was typed in a box.
- **Somebody else** signs in and carries on with the order that was open, as in a hands-free switch
  (`face-signin.md`): the order stays, whatever sat over it closes (a sheet, a dialog), every dish they add
  is theirs on the check, and the screen says "Hi Ben". This is so with a PIN as well.
- **With no order open**, somebody else lands on the orders screen: a manager's screen (Location settings,
  the menu editor) never passes to the next person.

Dishes that were on the check and not sent stay on the check, not sent: locking sends nothing.

## Good to know

- The lock is counted on the device: a screen locks at most five seconds after its minutes are up. A phone
  or tablet that slept through its minutes is locked when it wakes.
- Anybody who can open the device's Settings can change the minutes, as with the device's name. Settings
  cannot be opened from a locked screen.
- While a manager's PIN box for an approval is open under the lock, a face or a tag does not unlock the
  screen (the camera and the reader are held for the approval): the PIN does.
- Where the location signs people out when the camera no longer sees them (`face-signin.md`, away
  seconds), that still happens first and still closes what was open, as before.
- Not tried on the real devices from here.

## For developers

- `Settings.lockMinutes` (the preference `lock_minutes`, 0 or absent for never), `Settings.lockChoices`,
  `saveLockMinutes`.
- `lib/idle_lock.dart`: `IdleLock` notes each touch (`touched`, and a `HardwareKeyboard` handler for keys)
  and looks at the clock every five seconds while somebody is signed in and minutes are set, and on the
  app's resume (`check`). When the minutes are up it calls `Session.lock()`.
- `Session.lock()` signs nobody in (`staff` null, so face and tag sign-in look as on the sign-in screen)
  and keeps who was there in `lockedFrom`; `locked` is true until the next `applySignIn` or `signOut`.
- `lib/screens/lock_layer.dart`: `Touches` tells the lock of pointer events from the top of the app;
  `LockLayer` lays the pad (`SignInScreen` with `lockedNote`) over the navigator while `session.locked`, and
  keeps the screens under it built, without pointer, focus or semantics. The pad is over the navigator, not
  a route in it, so a route pushed while locked cannot cover it.
- `SessionWatcher` (`lib/switching.dart`) closes nothing on a lock; on the sign-in that ends it, the same
  person changes nothing and another person is a switch (the order route stays, the rest pops, "Hi …").
- The app's first screen stays the orders screen while locked (`main.dart`).
- Tests: `apps/pos_app/test/idle_lock_test.dart`, one more in `face_signin_test.dart`.
