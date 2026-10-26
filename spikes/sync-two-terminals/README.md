# Spike: two terminals and a hub survive pulled cables

**Question.** When two terminals edit the same orders while cut off from the hub and from each other, do
all three end with the same orders once reconnected, with no lost line, no duplicate and every void honored?

**In software (done first).** `backend/src/pos/sync` holds the operation log, the merge rules and a
simulation of terminals syncing with a hub over a channel that drops, duplicates and reorders messages.
`pytest` runs the worked examples and the property tests; `python -m pos.sync.simulate` runs the
simulation from the command line.

**On hardware (week 2).** Two tablets running the Flutter app in `apps/pos_app` (orders list, one order,
settings; operations go through an on-disk outbox that resends on reconnect), hub 1 running the backend.
Setup: `flutter run` on each device, name them `ipad1` and `mac1`, backend address
`http://172.19.1.179:8000`. Script: open three orders, pull the Wi-Fi on tablet A, edit on both, void a
line on B that A is changing, fire a course, reconnect, compare the three (`curl http://172.19.1.179:8000/orders`
is the hub's view).

**Pass.** Both tablets and the hub show identical orders after reconnecting; the simulation converges on
every seed with 40% drops and 20% duplicates; a change after firing shows as a modify ticket.

**Result: PASSED.** Software part 2026-10-25 (17 tests, simulation converges). Hardware part 2026-10-26: Mike
ran the app on a Mac (`mac1`) and an iPad (`ipad1`, release build) against hub 1 (order log in PostgreSQL).
Script as above: table 7 opened on the Mac, fired from the iPad, iPad Wi-Fi off, Fried rice added and Rolls
voided on the iPad while Soup was added on the Mac, Wi-Fi back on. The hub's replay, identical on both
screens: Tsingtao 2, Rolls void, Fried rice and Soup present, all three changes marked `modified_after_fire`.
The iPad's queue showed "2 waiting to send" offline and drained within seconds of reconnecting. Not yet
covered: the kitchen ticket (printing spike) and a third terminal; both are later spikes, not this one.
