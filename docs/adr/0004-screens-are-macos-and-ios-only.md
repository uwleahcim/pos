# ADR 4: Screen devices are macOS and iOS only

Date: 2026-10-26 · Status: accepted (Mike)

## Decision
Every screen the restaurant uses runs on an Apple device: Macs and iPads at fixed stations, iPhones and iPads
in hand, iPads or a Mac mini on the kitchen walls, and the admin portal as the same Flutter app on a Mac. The
Flutter project targets macOS and iOS only. Android, Windows, Linux and web app targets are dropped from the
repository and from phase 0. The location hubs stay Linux mini PCs; they are servers, not screens.

## Why
One hardware family means one device-management system (Apple Business Manager), one signing and release
pipeline, one camera and NFC story to test, and far fewer device combinations in every hardware spike. The
first real two-terminal test ran on a Mac and an iPad on 2026-10-26 and both built from one Mac in an hour.

## Consequences
The "Flutter on every device" spike shrinks to Mac, iPad and iPhone, which already run. Android tablets, Windows
all-in-ones and a web build are out of scope; adding one later is a `flutter create --platforms` away but
needs its own testing round. iPads have no NFC reader, so an iPad station signs in with a USB reader, face or
PIN. Sign-in and printing spikes need only Apple devices.
