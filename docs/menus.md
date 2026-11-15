# Menus: Food, Drinks, Lunch

The order screen shows one tab per menu open right now: **Food** and **Drinks** all day, **Lunch** at lunch
(Monday to Saturday, 11 to 3). A tab shows that menu's categories; tapping a category opens its dishes
below the tiles, the same on every screen. A menu with a single category has no tile to tap: its dishes show
straight away where the tiles would be, so the Lunch tab opens on the specials themselves (a single category
with sub-categories shows those as the tiles). Switching tabs closes whatever was open on the other menu. The
search finds a dish on every menu open, whichever tab shows, so a soda typed on the Food tab is found at
the bar too. With one menu open there are no tabs.

## The search

What is typed in the search field is taken word by word, and the best match comes first: `beef broccoli`
lists **Beef with Broccoli** first, then the other beef dishes, then the other broccoli dishes. Down or
Enter in the field lands on the best match.

- **Any order, no filler.** `broccoli beef` finds the same dish; `with`, `and`, `&`, `in`, `of`, `the`,
  `a`, `an`, `or`, `on`, `w`, `n` are not looked for (`sweet sour chicken`, `sex beach`).
- **One or several.** `egg rolls` finds Egg Roll, `dumpling` finds Dumplings, `general tso` finds General
  Tso's.
- **Still typing.** The start of a word already finds it: `chick broc` is Chicken with Broccoli.
- **Slips of the keyboard.** A word that is in no dish name at all is taken for the closest words:
  `brocoli`, `chiken`, `lo mien`, `szechwan`. One letter wrong, missing, too many or swapped (two in a word
  of eight letters or more); the first letter has to be right, and the word at least four letters long. A
  word the menu does have is never taken for another: `beef` does not find the beer.
- **Accents and apostrophes** need not be typed: `patron`, `pina colada`, `titos`.
- **One word or two.** `lomein`, `maitai` and `tsingtao` find Lo Mein, Mai Tai and Tsing Tao; `won ton` finds
  Wonton.
- **The Chinese name** on the button finds the dish, and so does **the kitchen's label**, the abbreviation
  the original POS printed (`shmp cashew`, `chkn`). Its marks are not words: the single letters (`r`) and
  what stands before a colon (`sa:`, `LUN:`).
- **A number** typed whole (`A15`, `802`) puts that dish first.

The order of what is found:

1. the dish whose number was typed;
2. the dishes with every word typed, then the dishes with at least half of them as whole words (so
   `general tso tofu` still finds the General Tso's dishes, and `lo mein` lists the chow mein after the lo
   mein but not the lobster);
3. a name on the button before the kitchen's label;
4. a whole word before the start of a word, that before letters inside a word (`berry` in Strawberry), that
   before a slip of the keyboard;
5. the word typed first before the word typed after it (the beef dishes before the broccoli dishes);
6. the shortest name: the one with the least beside what was typed;
7. the menu's own order, so a lunch special stays ahead of the same dish at dinner.

Whatever the plain text match of before found is still found (`f with b` still finds Beef with Broccoli),
only after the better matches. Categories are not searched: `vodka` finds no bottle, because no bottle is
named vodka.

The search runs in the app, over the menu it already holds (`apps/pos_app/lib/menu_search.dart`): it needs
no hub, and the dishes are prepared once when the menu is read, so a key pressed costs far less than a
frame (about a third of a millisecond for the restaurant's 535 dishes in the test runner; not measured on
the tablets). The hub sends each dish's kitchen label with the menu
(`kitchen_name`) for it; with an older hub the search does without. The hub's own `GET /menu/search` (the
menu engine's `search`) is a different, simpler lookup that no screen uses.

This is the Menu Engine Design's model as written (`menu-engine-design.md`, "Menus"): a menu is a
presentation, with its own sections and entries, of the one catalog. "When two menus are active at once,
the POS shows both as tabs." The drinks are not a flag on dishes or categories: they are a menu.

## What is on which menu

| Menu | Code | Sells | Open |
| --- | --- | --- | --- |
| Food | `dinner` | Every category of the kitchen's menu, Desserts (from the original POS), plus **Beverages** (tea, soda, juice) and Gift Certificates | Always |
| Lunch | `lunch` | Lunch Specials | Mon to Sat 11:00 to 15:00 |
| Drinks | `drinks` | Mixed Drinks (the cocktails), **Beverages**, Domestic Beer, Foreign Beer, White Wine, Red Wine, Sparkling Wine, Sake & Plum Wine, and the shelves from `bar.json`: Whiskey, Vodka, Gin, Rum, Tequila, Cognac & Brandy, Liqueurs & Cordials, Aperitifs & Vermouth | Always |

Beverages is on both menus: one category, two sections (`dinner/beverages`, `drinks/beverages`), and two
entries per dish with the same number. A soda ordered from either tab is the same dish on the check.

The menu code `dinner` stays what it was when there was one menu, so every stored section and entry id
keeps working; only its name changed, to Food. Tabs come in priority order, highest first: Lunch (10),
Food (0), Drinks (-10).

## Where a drink prints

Printing never looks at the menu. A dish prints at its **station**, inherited from its category
(`stations.json`, editable per category and per dish in the menu editor), and the printer set for that
station under Location settings › Printers takes that station's lines; the first printer takes every station
that has no printer of its own (`docs/printing.md`; `backend/src/pos/printing/service.py`). Every category
on the Drinks menu cooks at the `bar` station, except Beverages, at `soda`. So with a printer for `bar` and
one for the kitchen stations, the cocktails, beer, wine and spirits print at the bar and nothing else does;
the soft drinks go to the first printer until a printer is set for `soda` (the Printers screen suggests it).
A test keeps it so: everything on the Drinks menu resolves to `bar` or `soda`, never to a wok.

## The data

- `backend/src/pos/menu/data/menus.json` names the menus the order screen tabs, with each one's names,
  priority, hours and the export's categories it sells. A category under two menus is on both; a category
  under none is on the default menu (Food). The bar's shelves name their menu in `bar.json` (`"menu":
  "drinks"`); a bar category marked `existing` (the cocktails into Mixed Drinks, a beer into Foreign Beer)
  joins the export's category on every menu that category is on.
- `gloriafood.py` builds one section per (menu, category) and one entry per (menu, dish); `bar.py` adds
  the shelves to the Drinks menu; `legacy.py` adds what the restaurant's original POS knew and the export
  did not (`legacy_pos.json`: Chinese names and kitchen labels, stations, 89 dishes, the dining room's
  prices, the original POS's modifier groups, `docs/original-pos.md`). A dish added to an export category
  goes on every menu that category is on, so a fountain soda is on Food and Drinks like the export's cans.
- A hub seeds its database from these files once. From then on the database is the menu and the editor
  changes it (`pos-menu-storage`, `menu_admin.py`).

## A running hub

After `hubctl update`, a hub that was seeded before the drinks had their own menu still sells everything
from the one menu. `hubctl menu import` lists what the files would change, `hubctl menu import --apply`
does it (`pos.menu.seed`):

- a category whose section the files now put on another menu **moves** there with every dish in it, the
  editor's own additions included, keeping the editor's name and colour for the section
  (`section drinks/mixed_drinks moved from dinner/mixed_drinks with 26 entries`);
- a category the files put on a second menu as well gets its section there and its dishes mirrored
  (`section drinks/beverages added beside dinner/beverages`);
- a menu still called "Menu" is renamed Food; one the editor renamed keeps its name;
- a stored dish, category or section takes the names it lacks (the Chinese name and kitchen label from the
  original POS) and a dish that inherits its station takes the one the original POS printed at; a name or
  station set in the editor stays (`docs/original-pos.md`);
- then, as before, whatever the files have and the database lacks is added, and a price moves only while
  it is still the online export's.

Every terminal picks the change up within seconds, like any save from the editor.

## In the menu editor

A category's page has **On the menus**: a chip per menu, filled where the category is. Tapping an empty
chip puts the category on that menu with every dish in it (each dish brings the number and the sizes it has
on its other menu); tapping a filled one takes it off, dishes included. The dishes stay in the catalog and
on their other menus; a dish on no menu at all cannot be ordered until it is put back on one. A single
dish still goes on or off a menu from its own page ("Put on a menu", "Take off this menu").
