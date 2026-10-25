# ADR 3: Orders are an append-only operation log merged by union

Date: 2026-10-25 · Status: accepted (Mike); prototype in `backend/src/pos/sync`

## Decision
Terminals append operations to an order; they never overwrite it. Each operation carries a hybrid logical
clock stamp and the device that made it. The current order is the replay of its operations in clock
order; merging two copies is the union of their operations. Order fields are last-writer-wins by stamp, a
void always wins over a concurrent edit, a voided order stays void, a line changed after its course was
fired is flagged so the kitchen gets a modify ticket, and an operation stamped more than five minutes in
the future is refused until the device resyncs its clock. Ticket numbers come from per-terminal blocks;
hubs hand out short editing leases so two servers rarely edit one check at once.

## Why
Hubs and the cloud both accept orders while disconnected from each other and must agree afterwards without
anyone resolving conflicts by hand. A log that merges by union makes the result independent of arrival
order, duplicates and partitions, and lets the rules be tested like a calculator.

## Consequences
Every screen shows the backend's replay, so pricing is never done on a terminal. Reports read a
materialized state; the log is the source of truth and the audit trail.
