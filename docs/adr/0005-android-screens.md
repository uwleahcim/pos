# ADR 5: Android screens are back

Date: 2026-10-29 · Status: accepted (Mike) · Supersedes the Android part of ADR 4

## Decision
Android phones and tablets can be screens again, next to the Macs, iPads and iPhones of ADR 4. They run the same
Flutter app from the same code. Windows, Linux and web screens stay out of scope, and the hubs stay Linux mini PCs.

## Why
Mike asked for Android support on 2026-10-29. Android tablets and handhelds cost less than iPads. Many have NFC
built in, so staff tags work without a USB reader. Kitchen-display hardware is also often Android.

## Consequences
- The app has an `android/` project again (`org.chinasky.pos_app`). It may call the hub over plain HTTP on the
  LAN and use the front camera for the audit photo. Android takes that photo as an ordinary silent still,
  while iOS takes it off the preview stream.
- CI builds an Android APK on every push. Linux runners have the Android SDK, so this costs nothing extra.
- Every hardware spike that involves a screen (sign-in, NFC, printing relay, failover) needs an Android test
  device as well as Apple ones.
- Devices are managed in two systems: Apple Business Manager, plus Android Enterprise / zero-touch for Android.
- A developer Mac needs Android Studio (for the SDK) to build and run on Android.
