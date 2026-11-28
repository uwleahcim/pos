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
  its own is still named, though its dishes come out of the first printer. A printer set to print a ticket
  for each station (see **Tickets** under Printers) counts and names each of them like a printer of its
  own: Wok 1's ticket reads "Ticket 1 of 2" and "Also at: Fryer" though both come out of one printer.

Both count one send, not the whole order: appetizers fired earlier are not on the entrees' tickets. With
one station cooking, neither line prints. A void ticket says the same of the other stations it reaches,
and the copy a fallback printer gets is the same ticket.

The **takeout counter packs and does not cook**. Its ticket for a to-go order (the whole order, for the
bag) is not numbered and the cooks' tickets do not name it; it reads "Also at: Wok 1, Sushi Bar" itself, so
whoever packs knows where the food is coming from. A counter printer that also prints for a station that
cooks is counted for that station.

Each line is a switch, on to start: **Location settings**, on the Printers card, **Number the tickets of
one send** and **Name the other stations on each ticket** (`GET`/`PUT /settings/tickets`).

**DELIVERY.** An order that is brought to the customer says so on every station's ticket: the head reads
"delivery" and the line that says how it came in reads "Phone  DELIVERY". No ticket says the address or the
phone number; they are on the bill, which goes with the bag (`delivery.md`).

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
with what is owed now. An order **sent ahead for later** is not on paper until its time, so its ticket
says the money as it stands then (see "Orders sent ahead" below).

The switch is the third on the Printers card, **Print PAID or NOT PAID on to-go orders**, on to start.

**What goes in the bag.** The same copy says, under the dishes, what the customer wants in the bag besides
the food, as answered before the order was sent: `ALSO IN THE BAG`, then a large line for each thing
(`2 x Chopsticks`), or `NOTHING`. An answer changed after the order was sent prints the takeout station a
slip headed BAG with the answer as it stands; an order still waiting for its time is not on paper, so its
ticket says the latest answer and no slip prints. See `to-go-question.md`.

### Orders sent ahead

An order for later (tonight at seven, Saturday's catering) is sent when it is taken and cooked when its
time comes. Sending it prints nothing. The hub keeps which dishes wait, and makes the tickets when the
order's time less its quote has come, from the order as it stands at that moment:

- **One ticket a station**, however many times dishes were added and sent while it waited. None of them
  is marked as a change: the kitchen sees the order for the first time.
- **A dish taken off while it waits** is not on the ticket, and no VOID prints for it: no ticket of it was
  ever on paper. An order with every dish taken off, or voided whole, prints nothing.
- **An order moved to another time** waits for the new one. Moved up to now, it prints with the change.
- **The allergies, PAID or NOT PAID and what goes in the bag** are what the order says when it prints.
- **Closing the check does not cancel the food**: an order paid in full on Tuesday and closed prints on
  Saturday all the same. Voiding it does.
- **It outlives the hub.** What waits is kept in the hub's database, not in its memory, so a hub that is
  updated or loses power in between prints all the same, and the hub that takes over has the same list.
  A hub that was off when a ticket was due prints it as soon as it is back. The first start with this list
  also takes on the orders that were sent ahead before hubs kept it.
- **A ticket for another day says the day**: `READY BY 12:00  SAT NOV 21`. On its own day it says the
  time alone.

Once its tickets have printed, the order is like any other: a dish added prints at once, a dish taken off
prints a VOID.

**The pack sheet.** A catering order's first tickets come with one more paper at the takeout station's
printer (else where the bills print): the whole order as it stands, every dish with a box to tick, who it
is for and when, the money and what goes in the bag, with a line to sign for who packed and who checked.
The kitchen's tickets are as they were. Dishes added later print their tickets and no second sheet; the
button on the order's screen prints one again. The fifth switch on the Printers card, **Print a pack sheet
with a catering order**, turns the one that comes by itself off. **The prep list** of a day (what its
orders ahead need made, by station) prints from its own screen where the bills print. See `catering.md`.

**Labels for the bags.** **Labels** beside the total of a to-go order asks how many bags the order went
into and prints a short slip for each at the takeout station's printer (else where the bills print): the
order's number and name, `BAG 2 OF 3`, DELIVERY when it is one, and when it is due. None prints by itself.
See `bag-labels.md`.

**A table that moves.** Moving a table, merging two, or moving dishes to another table's check prints no
order ticket and no void. Each station with dishes sent in the last 45 minutes gets a MOVED slip instead:
the table the dishes were sent for, the table they go to now, and the dishes. The fourth switch on the
Printers card, **Tell the kitchen when a table moves**, turns it off. See `moves.md`.

**A screen that skips a station.** A manager can tell a screen to print no ticket at some stations: what
is sent or voided from the bar's own screen then prints nothing at the bar, since whoever rings a drink in
there makes it. The row **Screens that skip a station** on the Printers card; none to start. See
`ticket-skips.md`.

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
  FRYER"; past three, "WOK 1 + 3 MORE"), unless the printer is told otherwise:
- **Tickets**, on a printer with more than one station: **One for all** (what a printer starts on, and what
  every printer did before) or **One per station**. With one per station, a send prints a ticket for each
  station that has a dish in it, each headed with that station alone and cut off by itself, so a ticket
  can be torn off and handed to its cook. A line under the choice says what will come out ("A ticket for
  each of: Wok 1 + Wok 2 · Fryer · Broiler").
- **Print together**, under it once the printer has three stations or more: the stations that share a
  ticket all the same. **Group stations** opens the printer's stations to tick (Wok 1 and Wok 2); they
  then print on one ticket headed "WOK 1 + WOK 2" while the fryer keeps its own. A group is a chip: a tap
  changes its stations, its bin sets them apart again. A station is in one group; a station taken off the
  printer leaves its group. Groups belong to one printer, since stations on two printers cannot share a
  ticket.
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
  the order they are tried. The top one is tried first, which a line says once there are two; no number is
  put before a name. Fallbacks may not go round in a loop (Wok 1 falls back to Bar, Bar to Wok 1, or
  the same through a third printer): a printer that already falls back to this one is greyed out in the list
  with "would loop back here", a loop saved earlier is marked "loops back here" on its cards, and Save waits
  until one of them is taken out. The hub refuses such a save too.
- **Test print**: the demo ticket, with the stations' names on it. A printer set to one per station prints
  it once for each ticket it would print, headed as they will be, so the paper shows what was set.

What separate tickets change, and what they do not:

- Each ticket is a job of its own: it is numbered and names the others ("Ticket 2 of 3", "Also at"), and
  when the printer is down each goes to the fallback headed with whose it is ("FRYER PRINTER DOWN, PRINTED
  HERE").
- A dish that prints at two of the printer's stations (cooked at the wok and sent to the takeout counter
  by a **Take out** choice) is on both tickets; on one ticket for all it is said once.
- The takeout station's ticket of a to-go order is still the whole order, for the bag; the printer's other
  stations get tickets with their own dishes.
- The **first** printer stands in for every station with no printer. Set to one per station, it prints
  each of those on a ticket of its own too, headed with that station's name.
- Bills, the day's report, pack sheets, prep lists and bag labels are not kitchen tickets and print as
  before.

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

## The print log

**Location settings › Printers › Print log** (managers), and the paper button on each printer's card for
that printer's prints alone. The hub writes down every paper it makes, whatever it is (a kitchen ticket, a
change or a void, a bill, the day's report, a pack sheet, a prep list, bag labels, a test print), and keeps
it for 14 days (`KEEP_DAYS` in `pos.printing.log`):

- **The list**, newest first, by day: the time, what it was and what for ("Ticket · Table 12", "Bill ·
  Table 5 (4 guests)"), the printer it was made for and how it ended: **Printed**; **Printed after 2 failed
  tries**; **Printed at Bar instead: Wok did not answer** (it went to a fallback); **Not printed yet: the
  printer did not answer (3 failed tries). Still trying**; **Never printed: the hub restarted before it came
  out** (a print waits in the hub's memory, so one still waiting when the hub stops is gone; the log is how
  that is seen, and Reprint how it is mended). The list can be read for one printer, and for **Problems**
  alone: everything that did not print first time at its own printer. It follows what the printers do
  without a tap (the change feed's `prints`). A print made while the top of the list is on the screen
  shows there as it comes; one made while an older print is being read comes in above the screen and moves
  nothing on it, and is there when the list is scrolled back up.
- **By kind of print**, the line of chips under the printer: **All**, **Kitchen**, **Bar**, **Bills**,
  **Reprints**, **Other**. Kitchen and Bar are an order's tickets (new, changed, voided, moved, an allergy
  notice, a bag slip) by where their dishes are made; a ticket with dishes of both, on a printer that prints
  for both, is under both. Other is everything else: the day's report, pack sheets, prep lists, bag labels,
  notices, test prints. A reprint is under Reprints and still under what it repeats, so the bar's reprints
  are among the bar's tickets. The chips work together with the printer and with Problems, and on a narrow
  phone the line slides sideways.
- **Search**, the magnifier in the bar: the box takes the place of the title, and the log is searched when
  the typing stops. The hub looks for the words as they were typed, in either case, in the print's line of
  the log (what it is, what for, its stations, its printer, who asked for a reprint) and on every line of
  the paper itself: a dish, a choice, a server, a guest's name, an order's number, a price. A number typed is
  a whole number: "table 1" is not table 12, "#45" is not order 451. A print found by its paper shows the
  line it was found on under it ("On the paper: 1 Peking Duck 48.00"). The words are **marked**, as with
  a marker pen, wherever a print has them: in what it is called and in its printer's name in the list, in
  the line it was found on, and on its paper once it is open, on every line that has them. What is marked
  is what the hub found and no more: "table 1" marks Table 1 and leaves Table 12 alone. The search works
  together with the printer, the kind and Problems; when nothing has the words, **Show all prints** drops
  the kind, Problems and the search.
- **The paper on the screen**: a tap on a print opens its paper as it came out, line for line: big where
  the paper is big, white on black where the paper is, the rules, the cut. Under it, what happened to it one
  thing after the other (sent, each reason it failed and how often, passed on to which printer, printed,
  printed again by whom). Another tap closes it. The paper is drawn from what the hub wrote down, in the
  screen's own letters: it says what the paper said, in the same order and sizes, and is not a photograph of
  it (a long line may break at another word than on the paper, and Chinese is drawn in the screen's font).
- **Expand all**, in the bar (its two arrows alone on a phone): every print opens at once, each as a tap
  opens it, one paper under the other like the roll at the printer, to be read by scrolling. It stays that
  way for the prints that come after: the older ones brought by **Older prints**, another printer or kind,
  a search, a print made meanwhile. A tap still closes one print and opens it again. The button then reads
  **Collapse all**, which closes every one, the ones opened by a tap as well.
- **Reprint**, under every paper: prints it again at the printer it was made for, or **At another
  printer** at any printer on the list. The paper that comes out is headed `*** REPRINT ***`, white on black,
  with a line under it saying when the first came out ("FIRST PRINTED THU NOV 26 19:05") or that it never did
  ("FIRST SENT THU NOV 26 19:05, DID NOT PRINT"), so a cook cannot take it for a new order. The log lists it as
  "Reprint · Ticket · Table 12" with who asked for it, and the first print's story says it was printed
  again. A reprint is the paper as it was, not the order as it is now: a dish voided since is still on it.
  A reprint of a reprint repeats the first paper and is headed once.

How it is kept: every paper is made by calling a builder (a line, two columns, a rule, a feed, a cut), and
besides the printer's own language the hub makes each paper once with a builder that writes the calls down
(`pos.printing.script`, a few hundred bytes a ticket). That script is what the screen draws and what a
reprint plays back on the builder of whichever printer it goes to, so a paper first printed on the Epson
reprints on a Star. The log is the table `print_log` on the hub (in memory without a database); a failure
that repeats is written once a minute at most, so a printer that is off all night does not fill it. A log
that cannot be written never stops a paper from printing.

How the screen stays quick with every print open (`print_log_screen.dart`, `paper_shelf.dart`,
`paper_view.dart`): the list builds the prints on the screen and no others; the papers are asked of the
hub four at a time, the one on the screen first and the ones further down the list before they are scrolled
to, each once; a paper that arrives draws its own print again and not the screen; and a paper is drawn
once, however often the list around it is. What a search marks on a paper is worked out in the app
(`PrintFind` in `print_log.dart`) by the hub's own rule (`pattern_of`); the two are held to the same cases,
`backend/tests/printing/search_cases.json`, which both sides' tests read. A change to how the hub searches
goes into that file first.

A waiting print that is reprinted is not taken back: when its own printer answers again, it still comes
out there, without the REPRINT heading.

Which station is the bar's is not a setting: the hub reads it off the menu (`bar_stations` in
`pos.api.prints`). A station is the bar's when more than half of what is made there is a drink of the bar
(an item taxed as alcohol, or one from the bar's own shelves), so the station the liquor, the beer and the
cocktails print at is the bar's whatever it is called, and a sushi bar or a soda fountain is the
kitchen's. A restaurant whose menu has no such station is offered no Bar chip. Each ticket is filed as it
is queued, by the stations its dishes are made at (`Print.places`); the table keeps the types and the words
a search looks through beside each print (`types`, `words`), so reading by kind and searching 14 days of
paper is one query. The prints a hub wrote before it filed them are brought up to date once, as the updated
hub starts (`PrintService.catch_up_log`): their words from the paper that was kept, and a ticket's kitchen
or bar from the stations its printer prints for now, which is as near as an old print can be told.

## The API

- `GET /settings/printers`, `PUT /settings/printers` (manager): `printers` as `{id, stations, address,
  dialect, detected, fallbacks, tickets, groups}` in order, `takeout_station`; `source` says `settings`,
  `env` or `none`. A `PUT` whose fallbacks go round in a loop is refused with 422 and the loop in words.
  `tickets` is `one` (a send on one ticket for all the printer's stations) or `each` (a ticket for each
  station); `groups` is a list of lists of station codes, the stations that share a ticket when it is
  `each`. A group keeps the stations still on the printer and is dropped under two; a station in two
  groups is refused. Both are always in what is read, so a screen knows the hub prints either way; a
  printer sent without them (an app not rebuilt yet) keeps what is saved for it.
  `stations` is the list of station codes the printer prints for (`station`, the first, is still sent and
  still accepted alone, for an app not yet rebuilt). `dialect` is `escpos`, `star` or `auto`; with `auto` the
  hub prints in `detected`, the language `POST /print/identify` or the scan heard, and in ESC/POS while that
  is null. Two printers with one address are refused: one printer prints for several stations.
- `GET /settings/tickets`, `PUT /settings/tickets` (manager): `numbered` and `also_at`, the two lines a
  ticket says about the other tickets of its send, and `paid`, PAID or NOT PAID on the takeout station's
  ticket (`PrintService.money`, from the order's check), and `moved`, the MOVED slip for dishes already
  sent whose table changed (`table_changes`), and `pack`, the pack sheet that comes with a catering
  order's first tickets (`_pack_with`). Each true or false; one left out of a `PUT` stays as it is.
- `GET /settings/ticket_skips`, `PUT /settings/ticket_skips` (manager): `screens` as `{device, stations}`,
  the stations each screen prints no ticket at (`ticket-skips.md`).
- `GET /kitchen/screen?stations=`: what the screen of those stations has to make, routed by the same rules
  as the paper (`kitchen-screens.md`). The tickets print whether or not a station has a screen.
  `GET /kitchen/pass?stations=` is the pass: the same dishes whole on one ticket for whoever calls the orders.
- `GET /print/stations`: every station with its name, how many dishes and choices print there, the id of
  its printer, and `missing`.
- `POST /print/discover` (manager): `addresses` the terminal has; the answer lists each printer found with
  its `dialect`, `model`, `maker`, `kind` (`receipt`, `other` or null), whether the language is `guessed`
  from the name, and what was `heard`. `POST /print/identify` (manager): one address.
- `GET /print/printers`, `POST /print/test` (by id or station) and the relay's job calls as before; a job
  lists its `fallbacks` and how often it `moved`. A test print answers with `tickets`, how many it queued.
  A send's jobs are named `<op>:<printer id>`, and `<op>:<printer id>:<first station>` for each ticket of a
  printer that prints them apart.
- The guest's bill is not routed by station: `GET/PUT /settings/bill`, `POST /orders/{id}/bill` and
  `POST /print/bill-sample` are in `docs/bill.md`.
- The pack sheet and the prep list: `POST /orders/{id}/pack-sheet`, `GET /orders/ahead/prep` and
  `POST /orders/ahead/prep/print` are in `docs/catering.md`.
- The labels of a to-go order's bags: `POST /orders/{id}/bag-labels` is in `docs/bag-labels.md`.
- The print log (manager; `pos.api.prints`): `GET /print/log?printer=&only=trouble&type=&q=&before=&limit=`
  is a page of it, newest first, with `next` to send as `before` for the page after, the `printers` a reprint
  may go to, `keeps_days`, and `types`, the types this restaurant's log is read by (`kitchen`, `bar` where
  the menu has one, `bill`, `reprint`, `other`); each print says its `sort`, `kind`, `title`, the printer it
  was made for, its `status` (`printed`, `waiting`, `lost`), where it printed, its failed `tries` and last
  `error`, its `events`, the `places` a ticket is made at (`kitchen`, `bar`), and for a reprint `reprint_of`,
  `first_ms` and `by`. `type` keeps one type, `q` the prints that have its words (100 letters at most), and
  such a print says the line of its paper they were `found` on when its own line does not show them. A hub
  from before the types sends no `types`; a screen then offers neither. `GET /print/log/paper?job=` is one print
  with its `pages`, the steps a screen draws. `POST /print/log/reprint` `{job, printer}` prints it again
  (202 with the new `print`; 404 `no_such_print`, 409 `no_printer`). The change feed says `prints` when the
  log has something new.

Code: `backend/src/pos/printing/service.py` (routing, with `Printer.sets` for the tickets of one printer;
`send` and `cooking` for the two lines above; `_hold` and `release_due` for orders sent ahead), `held.py` (what waits: `HeldTickets` in memory, `PgHeldTickets`
in the table `held_ticket`), `jobs.py` (fallbacks), `discover.py` (the scan and
the languages), `pos/settings.py` (`clean_printers`), the engine's `routes_to` in `pos/menu/engine.py`;
`apps/pos_app/lib/screens/printers_screen.dart`, `printers.dart`, the editor's Prints at in
`screens/menu_editor.dart`. Tests: `backend/tests/printing/test_stations.py`, `test_other_stations.py`, `test_separate_tickets.py`,
`test_held.py`, `test_discover.py`, `apps/pos_app/test/printers_screen_test.dart`,
`printer_tickets_test.dart`, `ticket_words_test.dart`.
