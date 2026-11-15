# Choices that are dishes

A choice on a dish can be another dish. The soup that comes with a lunch special is the Miso Soup from the
Soup category, not a word that happens to read "Miso Soup"; each roll of the maki combination is the roll
itself, from the Roll (Maki) category. Because the choice is a dish, it has what the dish has: its own
price, its own station, its own choices (the sauce on a roll), its own 86. The Menu Engine Design calls this
a slot: "a combo is an item whose modifier groups offer other items as choices" (`menu-engine-design.md`,
"Combos"), and an option carries `linked_variant` to say which dish it is.

## Two ways to link

- **An option linked to a dish.** Any option in any group can point at a size of a dish. It is then called
  what the dish is called (a rename follows; a name typed on the option wins), and it is offered only while
  the dish is on sale: a dish 86'd on the board is 86'd as a choice too. The soup groups of the lunch
  specials work this way: "Miso Soup", "Wonton Soup", "Hot & Sour Soup" and "Egg Drop Soup" are the soups
  801 to 804; "No Soup" stays a word.
- **A group whose options come from a category** (`source_category`). The group offers every dish on sale
  in the category, and in the categories under it, one option per dish and one per size when a dish has
  several. The hub keeps the options in step on every save and import (`pos.menu.linked.sync`): a roll added
  to the Roll category is offered in the maki combination the moment it is on the menu; one taken off sale
  or deleted goes. Options typed by hand stay beside the dishes, and a price, default or sort set on a dish's
  option is kept. The Roll group of the maki combination (J55, pick 3) works this way.

## What the customer and the kitchen see

- **Ordering.** A choice that is a dish behaves like the dish's own tile. A tap chooses it as it comes: its
  defaults are filled in, and only what they leave open is asked right under it, so a roll with a sauce to
  pick opens that one question under the roll (a block titled with the dish in the sheet, a tray button
  named "Kappa Maki · Sauce" in the tray), and a roll that needs nothing is simply chosen. A hold on the
  button or the tray button opens the dish's own sheet: every choice on it, as its tile would show them, and a
  note to the kitchen ("no sesame"), even when the dish has no choices at all; Done chooses the dish as made
  there, and the button shows a tune mark once the dish differs from how it comes. The line goes on the check
  only when every question down the levels is answered. Nesting goes as deep as the menu does (the hub stops
  at eight levels, and refuses a menu where a dish offers itself).
- **Layout.** The item sheet shows a dish's sizes and choices as the menu shows categories and dishes: a
  grid of buttons of the same shape, as many across as the screen takes, with the price in a badge. The tray
  under the tiles uses the same buttons.
- **Several of the same choice.** A group with "Several of the same option" switched on (the Platter group of
  the appetizer platters, the add-ons) takes a count per choice. In the sheet a tap on a chosen button adds one
  more ("2x Chicken fingers") and the minus on the button takes one off, the last one taking the choice off; in
  the tray a tap on a chosen button adds one more while the group has room. Each one counts toward the
  group's least and most and is charged. "No" still means none of it: tap No, then the choice ("NO Crab
  rangoon"). The kitchen reads the count in front: "NO RANGOON · 2x CHKN FINGR".
- **A dish that comes with several things.** A group can need a number of picks and mark the ones the dish
  comes with as defaults: the appetizer platters' Platter group needs six and comes with spring roll, chicken
  wings, chicken fingers, boneless ribs, beef teriyaki and crab rangoon. The dish goes on the check with all
  six chosen, the sheet shows them chosen with the count in the heading ("Platter (6/6)"), and the hub
  refuses fewer or more. To swap, mark one "No" or take it off and tap another: a choice marked "No" takes
  no place, so "NO Crab rangoon" leaves room for a second chicken finger. The kitchen and the check read
  only the changes, and a default that was taken off reads as "NO" even when nobody tapped the word.
- **The check.** The dish line is the full price, choices included. Each choice is its own line under the
  dish with what it changes ("+1.00"); a choice that is a dish shows what the slot charges for it; the
  choices on that dish follow one step further in, and so does a note made on it ("no sesame"). A default
  choice is not listed, unless one of its own choices changed: then it is listed above the change, so
  "Spicy mayo" reads under the roll it is on.
- **Prices.** A slot charges by its price mode: the option's own price (`delta`, the usual: the soup adds
  nothing, a roll adds nothing), the dish's menu price (`linked`), or nothing (`free`). The choices made on
  the dish add what they add. The app's offline estimate follows the same rules.
- **The kitchen ticket.** A dish cooked at the same station as the dish it comes with is named among that
  dish's choices and prints no line of its own: the maki combination prints one line at the sushi station,
  "Maki Combination · Kappa Maki · Kanikyu · Tekka Maki". A dish cooked elsewhere prints its own line at its
  own station with a header naming the dish it belongs to: the soup station gets "1 Miso Soup" with
  "with L01 Sweet & Sour Chicken" under it, while the wok line reads "Sweet & Sour Chicken · White Rice ·
  Miso Soup". A note made on the dish travels with it: the wok line reads "Miso Soup (extra hot)" and the
  soup station prints "** extra hot **" under its own line, together with the order line's note when there
  is one. A void prints inverse at both.

## A choice that sends the dish elsewhere

An option may also send the **whole dish** to a second station (`routes_to`): the original POS's **Take
out** under Preparation sends the dish, with its choices, to the takeout counter to be bagged, while its own
station still cooks it. The printer button on an option in the menu editor sets it; `docs/printing.md` has
the printers and the stations.

## A choice a station does not read

An option group names the stations whose tickets leave its picks off (`hidden_at`): the rice and the soup
that come with a dish are of no use to the cook at the wok. The dish prints there without them; the check,
the other stations and the takeout counter's whole-order ticket still list them. A choice that is a dish
keeps printing at its own station (the soup station still gets "1 Hot & Sour Soup" with the dish it goes
with under it), and when that station is the very one that does not read the group, the dish prints there
as its own line rather than as a pick. `docs/printing.md` has how the hub decides it per printer.

## In the menu editor

- **Option groups › a group › On the tickets at.** One button per station, ticked while that station's
  ticket lists what is picked in the group. Tap a station off and its ticket prints the dish without it;
  the line underneath says in words who still reads it. Nothing ticked off is how every group starts.
- **Option groups › a group › Several of the same option.** Lets a choice go on a dish more than once, each
  one counted and charged.
- **Option groups › a group › Options come from.** Pick a category and the group offers its dishes; the
  dish rows show the dish's name read-only (it is the dish's), with the price it adds, Default and On sale
  editable. They cannot be removed, since the category puts them back; options typed by hand can.
- **A typed option › the link button** turns it into a dish from the menu (search by name); the unlink
  button makes it a word again, keeping the name it showed.
- **A dish › Option groups › Add a group › "A new group offering the dishes of a category…"** makes a new
  group named like the category, one pick, with the category's dishes as its options, and asks for it on
  the dish. Set "Pick at least / at most" on the group afterwards (3 and 3 for a maki combination).

The hub checks on save that a sourced group's category exists and that no dish offers itself through its
groups; either is refused with the reason.

## The data and a running hub

- `backend/src/pos/menu/data/groups.json` says what the import links: a group whose options are matched by
  name to the dishes of a category (`{"items_from": "Soup"}`; an option that matches no dish stays a word),
  or a group that offers a category outright (`{"category": "Roll (Maki)"}`; the export's own copies of the
  rolls are dropped). The bundled menu links 28 options this way: four soups in each of the two soup
  groups, and the twenty rolls.
- A hub seeded before any of this catches up with `hubctl menu import --apply` (`pos.menu.seed`): the soup
  options take their links, the Roll group takes the Roll category and loses the export's numbered copies
  of the rolls, and the editor's own changes stay. Without `--apply` it lists what it would do.
- The same file's `hidden_at` names, by group, the stations whose tickets leave the group off (the two rice
  groups and the two soup groups, off the seven cooking stations). The import gives a running hub those
  stations on a group nobody has set (`hidden_at` still empty of any answer); once a manager has touched
  the buttons in the editor, even to tick every station back on, the import leaves that group alone.
- The database gained one column, `modifier_group.source_category_id`; the hub adds it on start.
