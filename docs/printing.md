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

**What a ticket lists under a dish.** Only what was asked for. A choice the dish comes with (the group's
default: white rice with an entree, miso soup with a lunch special) is left off while nobody changes it,
whether the hub filled it in or the screen sent it; the station knows the dish. A word on it (NO White Rice)
or more than one of it is a change and prints. A default that is a dish of another station (the miso soup,
at the soup station) still prints its own line there, so that station hears of it. A choice's own choices
(the ginger on one roll of a maki combination, a note on the soup) print on the lines under that choice, one
step further in, and bring a default choice back onto the ticket so the change reads under it:

```
1 x sr:MAKI COMBO s
    + sr:KAPPA MAKI
        + GINGER
        + cut in 8
    + sr:KANIYU
```

An order line keeps the ticket words it was sold with (`priced.kitchen`: `labels` and, beside them,
`depths`), so a dish sold before this prints as it did.

**What a station does not read.** An option group names the stations whose tickets leave its picks off
(`Group.hidden_at`): the cooks have no use for the rice or the soup a dish comes with. The dish prints at
that station all the same, only without those lines, and with everything under them (the note on a soup
goes with the soup). Everyone else still reads the pick: the check, every station not named, and the
takeout counter, which bags a to-go order whole and scoops the rice. A pick that is a dish (the soup with a
lunch special) keeps printing at its own station, under the dish it goes with, and a dish cooked at a
station that does not read its group prints there as a line of its own instead of as a pick, so a station
never loses a dish it cooks.

```
Wok 1, before                         Wok 1, with Lunch Rice and Soup left off
1 x L甜酸雞 LUN:SWEET & SOUR CHKN      1 x L甜酸雞 LUN:SWEET & SOUR CHKN
    + Brown Rice
    + 酸辣湯 HOT & SOUR SOUP           Soup (unchanged)
                                      with L01 L甜酸雞 LUN:SWEET & SOUR CHKN
                                      1 x 酸辣湯 HOT & SOUR SOUP
```

The order line keeps every pick and, beside `labels`, where each is left off (`priced.kitchen[].hidden`,
one list of station codes per label, there only when something is hidden). The hub decides at print time,
per printer, for which stations a line prints there (`Takes.readers`): the line's own station on the
printer that prints that station's tickets (the first printer too, when it stands in for a station with no
printer), and the takeout station on the printer that takes a to-go order whole. A pick prints unless every
one of them leaves it off, and a printer that has the same dish for two stations says it once, with what
either reads. A line sold before this carries no `hidden` and prints as it did.

The bundled menu leaves **Rice**, **Lunch Rice**, **Soup** and **Sushi Soup** off the tickets of wok 1, wok 2,
wok 3, the broiler, the range, the fryer and the sushi bar (`backend/src/pos/menu/data/groups.json`,
`hidden_at`). `hubctl menu import --apply` gives a running hub the same on each of those groups nobody has
set; a group a manager has set in the editor, to anything, is left alone.

**What a ticket says about the other stations.** One send (a fire, or a void of sent dishes) often has
more than one station cooking. Each of their tickets then says so, last before the dishes:

```
WOK 1
#3412  dine in                             18:42
Table 12  4 guests
Server Amy
Course: Entrees
Ticket 1 of 3
Also at: Fryer, Sushi Bar
------------------------------------------------
```

- **Ticket 1 of 3** numbers the tickets that have something to cook, in the order the printers stand under
  Location settings › Printers.
- **Also at** names the other stations cooking for the same send, so a cook can time a dish against them.
  It names stations, not printers: a printer that prints for Wok 1 and the Fryer is one ticket, and the
  sushi bar's ticket reads "Also at: Wok 1, Fryer" only when both have a dish. A station with no printer of
  its own is still named, though its dishes come out of the first printer.

Both count one send, not the whole order: appetizers fired earlier are not on the entrees' tickets. With
one station cooking, neither line prints. A void ticket says the same of the other stations it reaches,
and the copy a fallback printer gets is the same ticket.

The **takeout counter packs and does not cook**. Its ticket for a to-go order (the whole order, for the
bag) is not numbered and the cooks' tickets do not name it; it reads "Also at: Wok 1, Sushi Bar" itself, so
whoever packs knows where the food is coming from. A counter printer that also prints for a station that
cooks is counted for that station.

Each line is a switch, on to start: **Location settings**, on the Printers card, **Number the tickets of
one send** and **Name the other stations on each ticket** (`GET`/`PUT /settings/tickets`).

**PAID or NOT PAID.** Orders paid first and orders paid at pickup sit on the same shelf, so the takeout
counter's ticket of a to-go order says which it is, under the number and the name:

- `PAID` when nothing is owed.
- `NOT PAID  $45.20`, large and white on black, when there is money to collect: the sum is what is still
  owed, tax and charges in. Part paid, a line under it says both sums (`$100.00 paid of $412.40`).
- `PAID` with `$10.00 more than the check, now $35.20` under it when a dish was voided after the order was
  paid, so whoever hands the bag over knows money goes back.
- `NOTHING TO PAY` for an order that comes to nothing (all of it comped).

Only the copy for the bag says it: the cooks' tickets never do, nor does a table's order, nor the notice
for an allergy told late. With no printer at the takeout station no ticket says it. It is what the hub knew
when the ticket was made: a ticket on paper stays as it printed, and the list of checks is where an order
paid since shows as paid (the **Unpaid** chip, `counter-mode.md`). A dish added later prints its own ticket
with what is owed now. One case is kept right on paper: the ticket of an order **sent ahead for later** is
made at once and waits for its time, so the hub makes it again whenever the order is paid or changed while
it waits, and it prints with the money as it stands then.

The switch is the third on the Printers card, **Print PAID or NOT PAID on to-go orders**, on to start.

**Allergies.** An allergy noted on the order prints in a block of its own, white on black, on every
station's ticket, and again under each dish of the seat it was told for. Told after dishes were sent, each
station that has some gets an ALLERGY ticket listing them. See `allergies.md`.

In the menu editor, each dish has a **Prints at** section: its station (the category's unless set), with
a line saying whether a printer serves that station, and **A new station…** to add one (Dessert, say) from
the dish itself. In an option group, the printer button on each option says where else the dish prints
when that option is chosen, and **On the tickets at** has one button per station: ticked, that station's
ticket lists what is picked in the group; tap it off and the dish prints there without it.

## Printers

**Location settings › Printers** (managers). One card per printer:

- **Prints for**: the stations it prints for, each a chip with its own bin. **Add a station** lists the
  menu's stations that no printer has yet, and **A new station…** takes a code typed. Several stations may
  share one printer: their dishes come out on one ticket, headed with every station's name ("WOK 1 +
  FRYER"; past three, "WOK 1 + 3 MORE").
- **IP address**, typed, with `:port` when it is not 9100. The **magnifier** turns the field into a list of
  the printers the hub finds on the network ("10.27.1.14 · EPSON TM-T88VII"), each with the stations it
  prints for already when another card has it; an office printer is listed and cannot be picked. **Look
  again** in the list has the hub look once more; **Other** turns the field back into one to type in.
  Picking a printer that has a card already moves this card's stations onto that one: one printer, one
  card.
- **Language**: **Auto** (what a new printer starts on), **ESC/POS** (an Epson, and most others) or **Star**
  (StarPRNT). Auto prints in the language the printer itself answered with and shows it ("Auto: Star"); a
  tap on Auto asks the printer again (see **How a printer is told apart**). A printer on Auto that has not
  been asked yet is asked on Save, and one that has not answered prints in ESC/POS until it does. A language
  set by hand that is not what the printer said is pointed out under it.
- **When it is down, print its tickets at**: the fallbacks, from a list of the other printers, dragged into
  the order they are tried. Fallbacks may not go round in a loop (Wok 1 falls back to Bar, Bar to Wok 1, or
  the same through a third printer): a printer that already falls back to this one is greyed out in the list
  with "would loop back here", a loop saved earlier is marked "loops back here" on its cards, and Save waits
  until one of them is taken out. The hub refuses such a save too.
- **Test print**: the demo ticket, with the stations' names on it.

**Find printers on the network** scans for port 9100 on the subnets of this terminal, the hub and the
printers already set, and lists what answers: receipt printers first, each with its name and language and
an **Add** that makes a new card with its address (or the stations it prints for, when it has a card);
then anything that said nothing, to add and set by hand; then whatever else listens on that port (an
office printer: "Canon MF644C · not a receipt printer"), named so it is not a mystery and not offered. The
magnifier's list is the same scan. (The hub's API runs in a container that does not see the LAN's hardware
addresses, so the scan is by port, and the terminal tells the hub which subnets it is on.)

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

- `GET /settings/printers`, `PUT /settings/printers` (manager): `printers` as `{id, stations, address,
  dialect, detected, fallbacks}` in order, `takeout_station`; `source` says `settings`, `env` or `none`.
  A `PUT` whose fallbacks go round in a loop is refused with 422 and the loop in words.
  `stations` is the list of station codes the printer prints for (`station`, the first, is still sent and
  still accepted alone, for an app not yet rebuilt). `dialect` is `escpos`, `star` or `auto`; with `auto` the
  hub prints in `detected`, the language `POST /print/identify` or the scan heard, and in ESC/POS while that
  is null. Two printers with one address are refused: one printer prints for several stations.
- `GET /settings/tickets`, `PUT /settings/tickets` (manager): `numbered` and `also_at`, the two lines a
  ticket says about the other tickets of its send, and `paid`, PAID or NOT PAID on the takeout station's
  ticket (`PrintService.money`, from the order's check). Each true or false; one left out of a `PUT` stays
  as it is.
- `GET /print/stations`: every station with its name, how many dishes and choices print there, the id of
  its printer, and `missing`.
- `POST /print/discover` (manager): `addresses` the terminal has; the answer lists each printer found with
  its `dialect`, `model`, `maker`, `kind` (`receipt`, `other` or null), whether the language is `guessed`
  from the name, and what was `heard`. `POST /print/identify` (manager): one address.
- `GET /print/printers`, `POST /print/test` (by id or station) and the relay's job calls as before; a job
  lists its `fallbacks` and how often it `moved`.
- The guest's bill is not routed by station: `GET/PUT /settings/bill`, `POST /orders/{id}/bill` and
  `POST /print/bill-sample` are in `docs/bill.md`.

Code: `backend/src/pos/printing/service.py` (routing; `send` and `cooking` for the two lines above), `jobs.py` (fallbacks), `discover.py` (the scan and
the languages), `pos/settings.py` (`clean_printers`), the engine's `routes_to` in `pos/menu/engine.py`;
`apps/pos_app/lib/screens/printers_screen.dart`, `printers.dart`, the editor's Prints at in
`screens/menu_editor.dart`. Tests: `backend/tests/printing/test_stations.py`, `test_other_stations.py`, `test_discover.py`,
`apps/pos_app/test/printers_screen_test.dart`, `ticket_words_test.dart`.
