# Screens that skip a station

A drink rung in at the bar's own screen needs no ticket at the bar: the bartender who rings it in makes it.
A manager can tell any screen to print no ticket at some stations. The rest of the order prints where it
always does.

No screen skips anything to start: every screen prints at every station.

## Setting it

A manager: **Location settings › Printers card › Screens that skip a station**.

1. Under **Add a screen**, tap the screen: this device, one of the screens the hub hears from, or
   **Other…** to type a device name (the name the screen shows under its own Settings).
2. Tap the stations it prints no ticket at. They are buttons; a picked one is tinted.
3. **Save**. The next send prints by it.

The bin takes a screen off the list. A screen left with no station picked drops off when it is saved.

## What it does

For dishes **sent or voided from a listed screen**:

- **No ticket prints at the picked stations.** A beer rung at `bar1` prints nothing at the bar.
- **Everything else prints as usual.** Food on the same check still goes to the wok and the sushi bar.
  Their tickets do not count the bar ("Ticket 1 of 2") or name it ("Also at"), since no ticket of it is
  on its way.
- **The bag's copy of a to-go order still lists the drink**, so whoever packs it checks it. Pick the
  takeout station too for a screen that should print no copy for the bag.
- **A void follows the same rule.** A drink voided at the bar's own screen prints no VOID ticket at the
  bar. A drink a server voids from another screen does, even when the bartender rang it in.
- **The same drink from any other screen prints at the bar as ever.**

The dish is on the check and is charged exactly as before: only the paper changes.

## What still prints everywhere

- An **ALLERGY** notice (an allergy told after dishes were sent).
- A **MOVED** slip (food on its way that changes table).

## Good to know

- It is a manager's setting for the location, not a switch on the device: a device's own Settings can be
  opened by anybody, and this one decides whether a station hears about a dish at all.
- A screen is known by its device name, whatever the case it is typed in. Rename a device and its entry
  no longer applies: list it again under the new name.
- A station with no printer of its own prints at the first printer. A screen that skips that station
  prints its dishes nowhere, the first printer included.
- A printer serving two stations ("Bar + Sushi Bar") still prints the station that is not skipped.
- An app that is not rebuilt yet works as before: the hub does the skipping.
- Not tried on the real printers from here.

## For developers

- Hub setting `ticket_skips`: `{"screens": [{"device": "bar1", "stations": ["bar"]}]}`
  (`pos.settings.clean_ticket_skips`, `skipped_stations`); `GET /settings/ticket_skips`, and `PUT` with a
  manager's token.
- `PrintService.skips(device)` gives the stations for the screen an operation came from (`op.device`).
  `on_ops` passes them to `send` for what was sent or voided, never for the ALLERGY notice or the MOVED
  slip. `routing(..., skip=)` puts them in each printer's `Takes`, whose `cooks` refuses a skipped
  station (the first printer's stand-in included) and whose `whole` is dropped when the takeout station
  is skipped.
- App: `TicketSkips` (`lib/printers.dart`), `PosApi.ticketSkips` (null from an older hub: no row) and
  `saveTicketSkips`, `lib/screens/ticket_skips_dialog.dart`, the row on the printers' card of
  `location_settings_screen.dart`.
- Tests: `backend/tests/printing/test_ticket_skips.py`, `apps/pos_app/test/ticket_skips_test.dart`.
