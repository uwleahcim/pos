# Spike: two terminals and a hub survive pulled cables

**Question.** When two terminals edit the same orders while cut off from the hub and from each other, do
all three end with the same orders once reconnected, with no lost line, no duplicate and every void honored?

**In software (done first).** `backend/src/pos/sync` holds the operation log, the merge rules and a
simulation of terminals syncing with a hub over a channel that drops, duplicates and reorders messages.
`pytest` runs the worked examples and the property tests; `python -m pos.sync.simulate` runs the
simulation from the command line.

**On hardware (week 2).** Two tablets running a throwaway Flutter screen that appends operations through
the API, one laptop running the backend as the hub. Script: open three orders, pull the Wi-Fi on tablet A,
edit on both, void a line on B that A is changing, fire a course, reconnect, compare.

**Pass.** Both tablets and the hub show identical orders after reconnecting; the simulation converges on
every seed with 40% drops and 20% duplicates; a change after firing shows as a modify ticket.

**Result.** Software part: in progress (tests passing). Hardware part: pending the devices.
