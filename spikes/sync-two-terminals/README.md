# Spike: two terminals and a hub survive pulled cables

**Question.** When two terminals edit the same orders while cut off from the hub and from each other, do
all three end with the same orders once reconnected, with no lost line, no duplicate and every void honored?

**In software (done first).** `backend/src/pos/sync` holds the operation log, the merge rules and a
simulation of terminals syncing with a hub over a channel that drops, duplicates and reorders messages.
`pytest` runs the worked examples and the property tests; `python -m pos.sync.simulate` runs the
simulation from the command line.

**On hardware (week 2).** Two tablets running the Flutter app in `apps/pos_app` (orders list, one order,
settings; operations go through an on-disk outbox that resends on reconnect), hub 1 running the backend.
Setup: `flutter run` on each tablet, name them `ipad1` and `android1`, backend address
`http://172.19.1.179:8000`. Script: open three orders, pull the Wi-Fi on tablet A, edit on both, void a
line on B that A is changing, fire a course, reconnect, compare the three (`curl http://172.19.1.179:8000/orders`
is the hub's view).

**Pass.** Both tablets and the hub show identical orders after reconnecting; the simulation converges on
every seed with 40% drops and 20% duplicates; a change after firing shows as a modify ticket.

**Result.** Software part: passed 2026-10-25 (17 tests, simulation converges). App ready 2026-10-26 (7 tests: outbox survives an outage and a restart, failover between addresses, refused ops dropped). Hardware part: pending the tablets and a Mac with the Flutter SDK.
