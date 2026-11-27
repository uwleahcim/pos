# The screen a device opens on

Each device says what whoever signs in on it sees first: the **floor map** or the **list of checks**. The
host stand and a server station want the tables; the counter wants the list, where the to-go orders are by
stage (Later, Cooking, Ready, Unpaid).

Every device opens on the floor map to start, as it always has.

## Setting it

On the device itself: **Settings › This screen opens on**, tap **Floor map** or **List of checks**, then
**Save**. Each device keeps its own pick.

## What it does

- **Each sign-in starts there**, by PIN, face or tag, whatever the last person was looking at.
- **The Floor | Checks switch in the row at the top still switches** between the map and the list
  (`home-screen.md`), and the screen stays on what the person picked: opening a check and leaving it comes back to the same one.
- **When another person takes the screen over** without a sign-out in between (a hands-free switch, or
  signing in on a locked screen), the screen under an open order goes back to the device's pick.
- **The person who comes back to a locked screen** finds it as they left it (`idle-lock.md`).
- **A new pick shows as soon as it is saved**, so whoever set it sees it took.

## Good to know

- The list of checks holds every open check, the tables' too; the to-go orders are picked out with the
  chips above it (`counter-mode.md`). There is no list of to-go orders alone.
- Anybody who can open the device's Settings can change the pick, as with the device's name.
- Not tried on the real devices from here.

## For developers

- `Settings.opensOn` (the preference `opens_on`: `floor`, or absent, and `checks`), `Settings.opensOnChoices`,
  `cleanOpensOn` (anything unknown is the floor map), `opensOnFloor`, `saveOpensOn`.
- `OrdersScreen` takes its first view from it in `initState` (the app builds the screen anew with each
  sign-in) and listens to the settings and the session (`_onOpensOn`): another pick, or another person
  signed in on the same screen, shows the device's pick.
- Tests: `apps/pos_app/test/opening_screen_test.dart`.
