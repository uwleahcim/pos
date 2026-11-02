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
- `lib/screens/` orders list, one order, settings, the menu editor.
