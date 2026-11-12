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

Reads that the screens poll (the open orders, the floor, an open check, every two seconds from every
terminal) must cost the same on the hub's thousandth day as on its first:

- The store keeps an index of its orders (`orders` in PostgreSQL, written in the same transaction as the
  operations): status, when opened, when last changed, and how far the order's history goes. A read picks
  its orders with `store.index(...)` and gets them with `store.views(...)`, which replays an order only when
  it changed since it was last read. Never loop over `store.order_ids()` calling `store.state()`: that
  replays every order ever taken, and took eight seconds after a month of service.
- What `view` and `views` return is shared between requests: read it, never change it. `store.state()` is
  the caller's own copy.
- Every JSON answer to a GET carries an `ETag`, and a client that sends it back gets `304` with no body while
  the answer is the same (`pos/api/conditional.py`). `GET /orders?hours=24&brief=true` is what a list on a
  screen asks for: the open orders and the day's, without each line's choices and price.
