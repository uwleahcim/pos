# ADR 6: A terminal with no backend queues orders, and nothing more

Date: 2026-11-01 · Status: accepted (Mike) · Narrows the "do not work alone" consequence of ADR 1

## Decision
When no backend on a terminal's list answers (both hubs and the internet gone), the app enters capture-only
mode: it shows a red banner, keeps the last menu snapshot it read, and lets staff create orders and add, change
and remove lines, which go into the outbox like any other operation. Prices shown are the menu's, marked
estimated; tax uses the last rates read. Nothing prints, no card is charged, nothing is shared between
terminals, and the only tender is cash written on the check by hand. The mode ends the moment any backend
answers: the outbox drains, the backend prices the lines, and every ticket prints with a "late" header.

Nothing else changes. The terminal still holds no rules: only queued operations and a cached menu.

## Why
The second competitive review (`docs/competitive-review-2026-11-01.md`) found this the one offline case where
Toast beats the design: a Toast terminal with no network still rings orders, in a per-device silo, while ours
showed "No connection to server". The outbox, the hybrid-clock stamps and the local replay of operations already
exist in the app, and the menu is already read every five minutes; caching it on disk and accepting `create`
and `add_line` without an acknowledgement is a small change. A kitchen can run on handwritten tickets for ten
minutes; a register that refuses to take an order cannot.

## Consequences
- The app caches the last menu snapshot and tax rates on disk, per location, and shows their age in the status
  details.
- The status icon gains a third state, red for capturing only, beside green (hub) and amber (cloud); the
  banner names what does not work.
- Operations made in this mode carry a flag, so the backend prints their tickets with a "late" header, the
  kitchen screen shows them first, and the day's report lists them.
- The simulated-restaurant test gains a case: every backend killed mid-service, orders taken, backends
  returned, totals compared.
- The runbook card for "hubs and internet down" changes from "no new orders" to "take the order, write cash on
  the check, tell the kitchen by hand".
