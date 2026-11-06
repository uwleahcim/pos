# Menus: Food, Drinks, Lunch

The order screen shows one tab per menu open right now: **Food** and **Drinks** all day, **Lunch** at lunch
(Monday to Saturday, 11 to 3). A tab shows that menu's categories; tapping a category opens its dishes
below the tiles, the same on every screen. A menu with a single category has no tile to tap: its dishes show
straight away where the tiles would be, so the Lunch tab opens on the specials themselves (a single category
with sub-categories shows those as the tiles). Switching tabs closes whatever was open on the other menu. The
search finds a dish on every menu open, whichever tab shows, so a soda typed on the Food tab is found at
the bar too. With one menu open there are no tabs.

This is the Menu Engine Design's model as written (`menu-engine-design.md`, "Menus"): a menu is a
presentation, with its own sections and entries, of the one catalog. "When two menus are active at once,
the POS shows both as tabs." The drinks are not a flag on dishes or categories: they are a menu.

## What is on which menu

| Menu | Code | Sells | Open |
| --- | --- | --- | --- |
| Food | `dinner` | Every category of the kitchen's menu, plus **Beverages** (tea, soda, juice) and Gift Certificates | Always |
| Lunch | `lunch` | Lunch Specials | Mon to Sat 11:00 to 15:00 |
| Drinks | `drinks` | Mixed Drinks (the cocktails), **Beverages**, Domestic Beer, Foreign Beer, White Wine, Red Wine, Sparkling Wine, Sake & Plum Wine, and the shelves from `bar.json`: Whiskey, Vodka, Gin, Rum, Tequila, Cognac & Brandy, Liqueurs & Cordials, Aperitifs & Vermouth | Always |

Beverages is on both menus: one category, two sections (`dinner/beverages`, `drinks/beverages`), and two
entries per dish with the same number. A soda ordered from either tab is the same dish on the check.

The menu code `dinner` stays what it was when there was one menu, so every stored section and entry id
keeps working; only its name changed, to Food. Tabs come in priority order, highest first: Lunch (10),
Food (0), Drinks (-10).

## Where a drink prints

Printing never looks at the menu. A dish prints at its **station**, inherited from its category
(`stations.json`, editable per category in the menu editor), and a kitchen printer named after a station
takes that station's lines; the first printer takes every station that has no printer of its own
(`docs/menu-engine-design.md`, "Kitchen routing"; `backend/src/pos/printing/service.py`). Every category
on the Drinks menu cooks at the `bar` station, except Beverages, at `soda`. So with the hub's printers set
as

```
hubctl printers kitchen=172.19.1.162/escpos,bar=172.19.1.14/star
```

the cocktails, beer, wine and spirits print at the bar and nothing else does; the soft drinks go to the
first printer (the kitchen) until a printer is named `soda`. A test keeps it so: everything on the Drinks
menu resolves to `bar` or `soda`, never to a wok.

## The data

- `backend/src/pos/menu/data/menus.json` names the menus the order screen tabs, with each one's names,
  priority, hours and the export's categories it sells. A category under two menus is on both; a category
  under none is on the default menu (Food). The bar's shelves name their menu in `bar.json` (`"menu":
  "drinks"`); a bar category marked `existing` (the cocktails into Mixed Drinks, a beer into Foreign Beer)
  joins the export's category on every menu that category is on.
- `gloriafood.py` builds one section per (menu, category) and one entry per (menu, dish); `bar.py` adds
  the shelves to the Drinks menu.
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
- then, as before, whatever the files have and the database lacks is added, and a price moves only while
  it is still the online export's.

Every terminal picks the change up within seconds, like any save from the editor.

## In the menu editor

A category's page has **On the menus**: a chip per menu, filled where the category is. Tapping an empty
chip puts the category on that menu with every dish in it (each dish brings the number and the sizes it has
on its other menu); tapping a filled one takes it off, dishes included. The dishes stay in the catalog and
on their other menus; a dish on no menu at all cannot be ordered until it is put back on one. A single
dish still goes on or off a menu from its own page ("Put on a menu", "Take off this menu").
