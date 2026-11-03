# POS app (Flutter)

The terminal app: one app for Mac, iPad, iPhone and Android phones and tablets (ADR 4, ADR 5). It is a
screen only. It signs in with a device name, lists orders from the backend, and appends operations to the
order log. No pricing, tax or menu rule ever lives here; the backend owns every rule.

```
flutter pub get
flutter run -d macos          # or an iPad, iPhone or Android id from `flutter devices`; add --release to keep it installed
flutter test
```

Flutter and Xcode rewrite some files for the machine they run on: `build/`, `.dart_tool/`, every `ephemeral/`
folder and `android/local.properties`. They are ignored and must stay out of git, because a tracked copy makes
`git pull` refuse on every other machine. `ios/Runner.xcodeproj/project.pbxproj` is tracked and carries the
iOS signing team on purpose, so Xcode has no reason to rewrite it. If a pull is still refused over a generated
file, run `git checkout -- <the paths it lists>` from the repository root and pull again.

On first start the app asks for the backend addresses. Give it the hub first and the cloud after, one per
line, for example `http://172.19.1.179:8000`. It talks to the first address that answers and moves down the
list when one stops answering, then back up when it returns.

Sign-in is a PIN pad with the front camera beside it; the backend checks the PIN (demo staff: Amy 1111,
Ben 2222, Mike 9999, or `POS_STAFF` on the backend). The camera thumbnail in the orders screen is the sign
that a small photo is taken when an order is created, fired, closed, reopened or a line is voided; the
photos queue on disk like the operations and go to the backend when it answers.

A manager sees a menu editor button on the orders screen. It asks for the manager PIN again, then shows
every dish by category: names in English and Chinese, the kitchen ticket name, the station it cooks at,
its sizes and prices, where it sits on the menus and its option groups. Option groups and categories edit
the same way. Save sends only what changed; the backend checks the whole menu and either saves it or says
what is wrong. Screens showing the menu ask every five seconds whether it changed and reload when it has.

## Android tablets and phones

Two ways to put the app on a Galaxy tablet or phone. Neither needs a signing key: the APK is signed with the
debug key (the TODO in `android/app/build.gradle.kts`), which is fine for the restaurant's own devices.

1. **No cable: the APK that CI builds.** Every push builds `app-release.apk` and keeps it for 30 days as the
   `pos-app-apk` artifact of the `ci` workflow. On the tablet, signed in to GitHub, open the latest green run under
   Actions, download the artifact (a zip), open it from My Files and tap the APK inside. Android asks once to let
   that app install unknown apps. A Samsung with Auto Blocker on (Settings, Security and privacy) refuses the
   install until it is off.
2. **From a Mac with a USB cable.** On the tablet turn on Developer options (Settings, About tablet, Software
   information, tap Build number seven times) and USB debugging, plug it in, accept the prompt on the tablet, then
   from `apps/pos_app` run `flutter devices` and `flutter run --release -d <its id>`. A release build stays installed
   when the cable comes out. `flutter build apk --release` writes the same APK to `build/app/outputs/flutter-apk/`.

Then set it up like any terminal: a device name (letters and digits), the hub address, Save, sign in with a PIN.
The tablet must be on the Wi-Fi that reaches the hub; the hub answers plain HTTP, which the Android manifest
allows. The sign-in screen asks for the camera the first time ("While using the app"); without it the audit photos
are skipped and the dot by the preview stays orange. A tablet gets the same layout as an iPad (anything 600 px wide
or more); a Galaxy phone gets the phone layout. Android takes the audit photo as an ordinary silent still, so a
device that plays a shutter sound should be reported: iOS already takes the frame off the preview instead.

Layout:

- `lib/api.dart` the backend client: the three order log calls, with the failover between addresses.
- `lib/outbox.dart` the in-flight queue: operations are stamped with a hybrid logical clock, kept on disk
  until the backend accepts them, and resent on reconnect. Duplicates are harmless; the backend ignores them.
- `lib/settings.dart` device name and backend addresses, saved on the device.
- `lib/session.dart` who is signed in; `lib/camera.dart` the front camera on macOS and iOS; `lib/photos.dart` the
  event photo queue.
- `lib/print_relay.dart` the print relay: with the switch on in settings, this terminal claims queued print
  jobs from the backend and writes them to the printers on the LAN when the hub cannot.
- `lib/menu_admin.dart` the menu as the editor holds it, and the changes it sends back.
- `lib/coursing.dart` the location's coursing as the hub serves it: on or off, the courses, the default.
- `lib/check_order.dart` the check as the order screen lays it out: a header per course, the lines under each
  by rank, and where a stack of lines dragged to another row lands (the course, and a rank for each, in the
  order stacked).
- `lib/screens/` orders list, one order, settings, the menu editor, the location settings.
- `lib/screens/check_list.dart` the check's rows as a list arranged by hand: a held dish lifts into a stack,
  dishes tapped fold out of the list and stack behind it like a fanned deck of cards (each still readable),
  the rows open room where it would land, and once let go it comes down onto that room and spreads into
  full rows.
- `lib/screens/comp_menu.dart` the comp menu a held price opens: the reasons the rules allow on one dish,
  what each gives, how much when the reason has a range, and taking a comp off again. On the check each
  choice on a dish is a line of its own with what it adds, and a comp follows the dish through an edit: the
  new line says which line it replaces (`Line.replaces`), on the hub and in the estimate here.
