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
- **IP address**, with `:port` when it is not 9100. The magnifier asks the printer what it is, and the
  language switches to what it said (see **How a printer is told apart**).
- **Language**: ESC/POS (an Epson, and most others) or Star (StarPRNT).
- **When it is down, print its tickets at**: the fallbacks, from a list of the other printers, dragged into
  the order they are tried.
- **Test print**: the demo ticket, with the station's name on it.

**Find printers on the network** scans for port 9100 on the subnets of this terminal, the hub and the
printers already set, and lists what answers: receipt printers first, each with its name and language and
an **Add** that fills a new printer's address and language; then anything that said nothing, to add and
set by hand; then whatever else listens on that port (an office printer: "Canon MF644C · not a receipt
printer"), named so it is not a mystery and not offered. (The hub's API runs in a container that does not
see the LAN's hardware addresses, so the scan is by port, and the terminal tells the hub which subnets it
is on.)

### How a printer is told apart

Without printing: nothing printable is sent to a printer that has not already answered as ESC/POS, since a
letter sent to the wrong printer waits in its buffer for the next ticket, or comes out of a laser as a page.

First its name, asked beside the printer port:

1. **SNMP** (UDP 161, community `public`), which office printers and Epsons answer: the IEEE 1284 device
   id, else the device description.
2. **Star's search** (UDP 22222), the question Star's SDK and utilities ask to list printers and read what
   each one is. A Star answers with its model, firmware, maker and command set ("mC-Print3", "3.81",
   "Star", "STAR"); Stars answer no SNMP, so this is where a Star's name comes from.

A printer whose device id lists a page language (a Canon laser: `CMD:LIPSLX,CPCA`) is listed by its name,
"not a receipt printer", and its printer port is sent nothing at all. Every other one is asked on its port:

3. **`ESC ACK SOH`**, StarPRNT's "send your status now", sent the moment the port opens: a Star answers
   with its status block in a few milliseconds (`29 8a 00 …`; an mC-Print3 says nothing on its own), an
   Epson ignores it.
4. **`DLE EOT 1`**, ESC/POS's: an ESC/POS printer of any make answers one byte, `0xx1xx10` (`16`). A
   TM-T88VII left waiting on an open connection takes two or three seconds over its first answer, so a
   printer still silent is asked a second time and given three seconds.
5. **`GS I`**, only once it is known to speak ESC/POS: the model and the maker.

Whatever arrives is read for whose it is: an Epson with automatic status on sends four bytes of its own
(`14 00 00 0f`), which is not a Star's block. A receipt printer that kept quiet on its port gets the
language its name implies ("mC-Print3 · Star (StarPRNT), going by its name").

A printer found silent is asked once more: some take one connection at a time and are still closing the
scan's. When the screen gets one wrong, `sudo hubctl print <ip> identify` on the hub prints the verdict
and every answer behind it:

```
10.27.1.14: EPSON TM-T88VII: ESC/POS
  ESC ACK SOH: nothing
  DLE EOT 1: 16
  GS I: 5f 54 4d 2d 54 38 38 56 49 49 00 5f 45 50 53 4f 4e 00
  SNMP id: MFG:EPSON;CMD:ESC/POS;MDL:TM-T88VII;CLS:PRINTER;DES:EPSON TM-T88VII;CID:EpsonTM00000001;
10.27.1.166: Star mC-Print3: Star (StarPRNT)
  ESC ACK SOH: 29 8a 00 00 00 00 00 04 00 00 00 06 00 00
  Star search: model mC-Print3, firmware 3.81, maker Star, commands STAR, device MCP31 (STR-001)
```

The hub must be able to send UDP to the printers (ports 161 and 22222) for the names; without it a Star is
still known as a Star by step 3, without its model.

## The API

- `GET /settings/printers`, `PUT /settings/printers` (manager): `printers` as `{id, station, address,
  dialect, fallbacks}` in order, `takeout_station`; `source` says `settings`, `env` or `none`.
- `GET /print/stations`: every station with its name, how many dishes and choices print there, the id of
  its printer, and `missing`.
- `POST /print/discover` (manager): `addresses` the terminal has; the answer lists each printer found with
  its `dialect`, `model`, `maker`, `kind` (`receipt`, `other` or null), whether the language is `guessed`
  from the name, and what was `heard`. `POST /print/identify` (manager): one address.
- `GET /print/printers`, `POST /print/test` (by id or station) and the relay's job calls as before; a job
  lists its `fallbacks` and how often it `moved`.

Code: `backend/src/pos/printing/service.py` (routing), `jobs.py` (fallbacks), `discover.py` (the scan and
the languages), `pos/settings.py` (`clean_printers`), the engine's `routes_to` in `pos/menu/engine.py`;
`apps/pos_app/lib/screens/printers_screen.dart`, `printers.dart`, the editor's Prints at in
`screens/menu_editor.dart`. Tests: `backend/tests/printing/test_stations.py`, `test_discover.py`,
`apps/pos_app/test/printers_screen_test.dart`.
