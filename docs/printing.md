# Printers and stations

Where a dish prints, how the printers are set up, and what happens when one is down. The printers are data
on the hub, set from the app by a manager; the hub routes every ticket by them. Nothing here is code to
change for a new printer.

## Stations

Every dish prints at a **station**: the kitchen's wok 1, wok 2, broiler, range, fryer, sushi bar, soup,
soda, the bar, or the takeout counter (the original POS's stations, `backend/src/pos/menu/data/stations.json`
and `legacy_pos.json`). A dish inherits its station from its category unless it says otherwise; a
modifier option may print its own line at a station of its own ("Add fried rice" to a wok), or send the
**whole dish** to a second station as well (`routes_to`): the old POS's **Take out** under Preparation
sends the dish to the takeout counter, where it is bagged, while its own station still cooks it.

In the menu editor, each dish has a **Prints at** section: its station (the category's unless set), with
a line saying whether a printer serves that station, and **A new station…** to add one (Dessert, say) from
the dish itself. In an option group, the printer button on each option says where else the dish prints
when that option is chosen.

## Printers

**Location settings › Printers** (managers). Each printer:

- **Prints for the station**: one of the menu's stations, or a new station's code typed. Two printers on
  one station: the first in the list prints it; the second is useful as the first one's fallback.
- **IP address**, with `:port` when it is not 9100. The magnifier asks the printer what it is: a Star in
  StarPRNT mode sends its status to whoever connects, an Epson answers `GS I` with its model and maker; the
  language switches to what the printer said, and the model is shown. A printer that answers neither is
  listed as reachable with the language to pick.
- **Language**: ESC/POS (an Epson, and most others) or Star (StarPRNT).
- **When it is down, print its tickets at**: the fallbacks, from a list of the other printers, dragged into
  the order they are tried.
- **Test print**: the demo ticket, with the station's name on it.

**Find printers on the network** scans for port 9100 on the subnets of this terminal, the hub and the
printers already set, and lists what answers with its language and model; **Add** fills a new printer's
address and language. (The hub's API runs in a container that does not see the LAN's hardware addresses,
so the scan is by port, and the terminal tells the hub which subnets it is on.)

The screen lists every station the menu prints at that has **no printer** ("Fryer · 42 dishes", "Takeout ·
2 choices, to-go orders"); tapping one adds its printer, the address to be typed. Until then, that
station's dishes print on the first printer in the list, so nothing fired is lost.

**To-go orders** (counter, phone, online, delivery, catering) print **whole at the takeout station** too,
for the bag to be packed and checked, while each dish prints where it is cooked. The station is a setting
on the same screen (Takeout to start; Nowhere else turns it off).

## Fallbacks

A ticket is rendered for its printer and for each of its fallbacks when it is queued. The hub writes it to
the printer at once and retries every three seconds; after two failed attempts at a printer the job moves
to the next fallback, and round again when every one has failed, so a dead printer costs seconds, not the
ticket. A fallback's copy is headed with the station it is for and `WOK 1 PRINTER DOWN, PRINTED HERE`, so
whoever stands there carries it over. A relay terminal (the cloud path, `spikes/printing`) follows the same
list: a job it reports failed moves on in the same way.

## Setting up a hub

- A hub that has never had printers saved from the app prints as `POS_PRINTERS` in `/opt/pos/.env` says
  (`hubctl printers kitchen=172.19.1.162/escpos,bar=172.19.1.14/star`); the Printers screen shows those with
  a note, and the first save keeps them as the setting, which wins from then on.
- After this change: `sudo hubctl update`, then `sudo hubctl menu import --apply` (it gives the Take out
  options their takeout routing on a hub that already has them), rebuild the apps, and open Location
  settings › Printers: give each station its printer (the Epson at 172.19.1.162 speaks ESC/POS, the Star
  mC-Print3 at 172.19.1.14 StarPRNT), set the fallbacks, Save.

## The API

- `GET /settings/printers`, `PUT /settings/printers` (manager): `printers` as `{id, station, address,
  dialect, fallbacks}` in order, `takeout_station`; `source` says `settings`, `env` or `none`.
- `GET /print/stations`: every station with its name, how many dishes and choices print there, the id of
  its printer, and `missing`.
- `POST /print/discover` (manager): `addresses` the terminal has; the answer lists each printer found with
  its language and model. `POST /print/identify` (manager): one address.
- `GET /print/printers`, `POST /print/test` (by id or station) and the relay's job calls as before; a job
  lists its `fallbacks` and how often it `moved`.

Code: `backend/src/pos/printing/service.py` (routing), `jobs.py` (fallbacks), `discover.py` (the scan and
the languages), `pos/settings.py` (`clean_printers`), the engine's `routes_to` in `pos/menu/engine.py`;
`apps/pos_app/lib/screens/printers_screen.dart`, `printers.dart`, the editor's Prints at in
`screens/menu_editor.dart`. Tests: `backend/tests/printing/test_stations.py`, `test_discover.py`,
`apps/pos_app/test/printers_screen_test.dart`.
