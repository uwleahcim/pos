# Spike: one Flutter app on every device type

**Question.** Does one Flutter codebase build and run on an iPad, an Android tablet, a Windows touch
all-in-one, a Mac, and a Linux mini PC, with a front camera preview and a WebSocket to the backend?

**Setup.** `apps/pos_app` created with `flutter create` on a developer machine (all five platforms plus
web). One screen: sign-in placeholder with camera preview, an order list fed by the backend's `/ops` and a
button that appends an operation.

**Pass.** The same commit runs on all five device types, the camera preview works on each station type,
and the app reconnects to the backend after Wi-Fi is cut and restored without being restarted.

**Result.** Pending.
