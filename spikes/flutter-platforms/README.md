# Spike: one Flutter app on Mac, iPad and iPhone

**Question.** Does one Flutter codebase build and run on a Mac, an iPad and an iPhone, with a front camera
preview and a live connection to the backend? (Scope narrowed to macOS and iOS on 2026-10-26, ADR 4.)

**Setup.** `apps/pos_app`, targets macOS and iOS. Orders list, one order and settings screens fed by the
backend's order log, with an on-disk outbox and failover between backend addresses. The camera preview is
exercised in the sign-in spike.

**Pass.** The same commit runs on a Mac, an iPad and an iPhone, and the app reconnects to the backend after
Wi-Fi is cut and restored without being restarted.

**Result: PASSED 2026-10-26.** The same commit runs on Mike's Mac, iPad and iPhone, all built from the Mac;
reconnect after a Wi-Fi cut was proven in the sync spike's cable-pull test. The camera preview is checked
in the sign-in spike.
