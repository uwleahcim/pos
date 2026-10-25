# Backend

One Python service that runs unchanged on a location hub and in the cloud. Phase 0 holds the first spike,
the order operation log (`pos/sync`), and a minimal API around it (`pos/api`). The menu engine package
(`pos/menu`) arrives next, built from `docs/menu-engine-design.md`.

```
src/pos/sync/hlc.py       hybrid logical clock: a timestamp that orders events across devices with drifting clocks
src/pos/sync/oplog.py     operations, replay into an order state, merge rules, the op store with pull cursors
src/pos/sync/simulate.py  terminals and a hub syncing over a lossy channel; converges when the cables are back
src/pos/api/app.py        FastAPI: append ops, read an order, pull ops since a cursor
tests/                    worked examples, Hypothesis property tests, the simulation as a test
```

Merge rules proven by the tests:

- An order is the replay of its operations in clock order; merging two copies is the union of their operations.
- Duplicates and arrival order never change the result.
- Order fields are last-writer-wins by clock; a void always wins over a concurrent edit; a voided order stays void.
- A line changed after its course was fired is flagged, so the kitchen gets a modify ticket.
- An operation stamped more than five minutes in the future is rejected: the device must resync its clock.
