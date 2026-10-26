# POS app (Flutter)

The terminal app for phase 0: one app for Mac, iPad and iPhone (macOS and iOS only, ADR 4). It is a
screen only. It signs in with a device name, lists orders from the backend, and appends operations to the
order log. No pricing, tax or menu rule ever lives here; the backend owns every rule.

```
flutter pub get
flutter run -d macos          # or an iPad/iPhone id from `flutter devices`; add --release to keep it installed
flutter test
```

On first start the app asks for the backend addresses. Give it the hub first and the cloud after, one per
line, for example `http://172.19.1.179:8000`. It talks to the first address that answers and moves down the
list when one stops answering, then back up when it returns.

Sign-in is a PIN pad with the front camera beside it; the backend checks the PIN (demo staff: Amy 1111,
Ben 2222, Mike 9999, or `POS_STAFF` on the backend). The camera thumbnail in the orders screen is the sign
that a small photo is taken when an order is created, fired, closed, reopened or a line is voided; the
photos queue on disk like the operations and go to the backend when it answers.

Sign-in is a PIN pad with the front camera beside it; the backend checks the PIN (demo staff: Amy 1111,
Ben 2222, Mike 9999, or `POS_STAFF` on the backend). The camera thumbnail in the orders screen is the sign
that a small photo is taken when an order is created, fired, closed, reopened or a line is voided; the
photos queue on disk like the operations and go to the backend when it answers.

Layout:

- `lib/api.dart` the backend client: the three order log calls, with the failover between addresses.
- `lib/outbox.dart` the in-flight queue: operations are stamped with a hybrid logical clock, kept on disk
  until the backend accepts them, and resent on reconnect. Duplicates are harmless; the backend ignores them.
- `lib/settings.dart` device name and backend addresses, saved on the device.
- `lib/session.dart` who is signed in; `lib/camera.dart` the front camera on macOS and iOS; `lib/photos.dart` the
  event photo queue.
- `lib/session.dart` who is signed in; `lib/camera.dart` the front camera on macOS and iOS; `lib/photos.dart` the
  event photo queue.
- `lib/screens/` orders list, one order, settings.
