# What the original POS knew

The GloriaFood export (`backend/src/pos/menu/data/gloriafood_menu.json`) is the online menu: English names,
online prices, the few option groups the website asks. The restaurant's original POS carried the rest of
what a dining room needs, and Mike's merged sheet of 2026-11-10 (`menu_pos_gloriafood_merged.csv`, 840 rows:
the export beside the original POS's item records, decoded) put the two side by side. What the original POS
had and the export did not is in `backend/src/pos/menu/data/legacy_pos.json`; `legacy.py` adds it to the
definitions after the export and the bar (`bar.py`), so `load_restaurant_menu()` gives a hub all three
(`gloriafood.py`). Nothing of it is in code: the file is data, like the export and `bar.json`, and the menu
editor changes whatever it seeds.

## What the kitchen reads

A dish the original POS knew keeps three names: the English one from the export (`names.en`), its Chinese
name (`names.zh`) and a **kitchen label** (`names.kitchen`), which is what prints on the ticket. The label
is the Chinese name followed by the label the original POS printed, when it had both, and whichever it had
otherwise (`legacy.kitchen_label`): the wok reads `腰果蝦 SHMP CASHEW r`, the sushi bar `sr:KAPPA MAKI`. The
original POS's label is kept verbatim, with its side flags (`r` rice, `p` pancakes, `s` soup or salad, `f`
lettuce leaves, `sr:`/`su:`/`sa:`/`sp:` for a roll, sushi, sashimi and a sushi platter), because the cooks
read them already. A
dish the original POS did not have prints in English, as before. 266 dishes got a label this way.

The categories have Chinese names too (`categories[].zh`, on the category and on each of its sections), so
the order screen in Chinese (`locale=zh`) shows 頭抬, 湯, 大廚菜, 壽司, 調酒 and so on.

## Where a dish cooks

The original POS printed each dish to a printer bitmask (1 wok, 2 appetizer/fryer, 4 sushi bar, 8 takeout
counter, 128 bar). Where its primary printer belongs to another family than the station the dish inherits
from its category (wok: `wok1`/`wok2`/`wok3`/`range`; fryer: `fryer`/`broiler`; `sushi`; bar: `bar`/`soda`;
counter: `takeout`/`soup`), the file sets the dish's own station (`items[code].station`), and the dish
prints there whatever its category says. Thirteen dishes:

| Dish | Category's station | Prints at |
| --- | --- | --- |
| C01 Sweet & Sour Chicken, H29 Peking Duck | wok1 | fryer |
| A15 Chicken Soong, A16 Lobster Soong, A17 Five Special Shrimp | fryer | wok1 |
| 805 to 808, the soups for two | soup | wok1 |
| L21 California Roll & Tempura Roll, L22 Sushi & Spicy Tuna Roll (lunch) | wok1 | sushi |
| Y13 Sushi Rice, Y43 Spicy Mayo | takeout | sushi |

A dish that moved within its family (wok1 to wok2, say) keeps the category's station: the wok stations are
one printer until the kitchen says otherwise (`stations.json`).

## Dishes only the original POS sold

89 dishes and drinks the export never had are on the menu under the original POS's own numbers, in the
export's categories, after the export's own dishes (sort `AFTER_THE_EXPORT` + position, like the bar's
additions), each in one Regular size at the original POS's dinner price and marked `attrs.legacy_pos`:

- **Appetizers**: A18 Crispy Calamari with Salt & Pepper (wok), A23 Appetizer Platter for 3, A24 Add One
  Leaf, A25 Fried Shrimp, A27 Teriyaki Chicken appetizer.
- **Soup**: 811 to 814, the quart soups; 822 Chicken Noodle Soup, 823 Chicken Rice Soup, 824 Wonton Broth
  (wok).
- **Extras**: 831 to 833 Sweet & Sour, Brown and Sesame Sauce; Y00 Pan Fried Noodle; Y02 Lettuce Wrap; Y26,
  Y27 Soy Sauce; Y32 to Y36 fortune cookies, chopsticks, flatware, napkins, paper plates (free, so the
  kitchen can be told); Y41 Wasabi, Y42 Sushi Ginger, Y44 Unagi Sauce (sushi bar).
- **Kitchen**: C11 Chicken with Snow Peas, S10 Calamari with Hunan Sauce, S16 Stir-Fried Seafood, V10
  Vegetable Chow Mein, V30 Steamed Broccoli, N27 Plain Chow Fun.
- **Sushi bar**: I07 Sunomono, I08 Sushi Appetizer, I09 Sashimi Appetizer, I46 Seafood Teriyaki, K21 Fire
  Dragon Roll, K22 Scallop Special, K23 Caterpillar Roll, J22 Inari.
- **Desserts**, a new category on the Food menu after Extras, at the takeout counter: D01 Ice Cream, D02
  Pineapple.
- **Gift Certificates**: G010, the $10 one (`gift_card`).
- **Beverages** (on the Food and the Drinks menu, at `soda`): the fountain drinks the export sells only as
  cans (W011 Coke, W012 Diet Coke, W10 Sprite, W013 Ginger Ale, W014 Tonic Water, W015 Soda Water, W016
  Lemonade, W017 Sweetened Iced Tea, W010 Cranberry Juice, W018 Cranberry Soda, W07 Shirley Temple), R06
  Green Tea, W49 Hot Tea, W08 Fiji Water; and the bar's non-alcoholic drinks (W05 Hawaiian Punch, W04
  Coconut Dream, W31 and W32, the virgin colada and daiquiri), which print at the bar.
- **Mixed Drinks**: 26 cocktails the printed list (`bar.json`) does not carry, W20 Koko Moko to Q05 Piña
  Colada Tini, all `alcohol`.
- **Foreign Beer**: X101 Tsing Tao in the can.

What the original POS also had but the menu did not take, and why:

- its wine list (X31 to X83, Q06 to Q10), beers (X01 to X16) and most cocktails (W11 to W39, Z02, Z08):
  the export and `bar.json` sell them already, under the printed list's names and prices;
- W47 Margarita: the printed list's China Sky Rita;
- Z04 Absolut and Z05 Stoli at 9.95: `bar.json` sells both by the 1.5 oz pour at 7.95; a cocktail-size pour
  would be a second size, not a price change (open);
- duplicates of dishes the export has: K51 to K55 (the J51 to J55 rolls), Y01 Moo Shu Pancake (the export's
  pancake group), Y03 Sweet & Sour Sauce (831), W02, W03, W06, W09 and W019 (R04, R03, R02, R07, R01);
- the $25 to $100 gift certificates the export has, and Gift Cert $XX, a certificate of any amount (open).

The open rows are on the menu since 16 November 2026: FF Open Food (Extras, Wok 1), 89 Open Soup (Soup),
SS Open Sushi (Sushi) and DD Open Drink (Mixed Drinks, `alcohol`). Each is an off-menu dish: whoever rings
it types what it is and its price (`"asks": "name"` on its row; see `off-menu-dish.md`).

## Prices

The export's prices are the online ones. Where the original POS's dining-room price differed, the dining
room's wins for ten dishes (`prices[]`, each with the online price kept for the record):

| Dish | Online | Dining room |
| --- | --- | --- |
| C13 Basil Chicken | 18.95 | 19.95 |
| N23 Beef Chow Fun | 14.50 | 14.95 |
| N25 Shrimp Chow Fun, N26 House Special Chow Fun | 17.95 | 16.95 |
| K19 Cucumber Avocado Roll | 7.95 | 8.50 |
| Y43 Spicy Mayo | 0.95 | 1.00 |
| R02 Bottled Spring Water | 1.95 | 2.00 |
| R03 Organic Milk, R04 Juice | 2.50 | 2.00 |
| R08 Ramune | 3.95 | 3.45 |

Three differences were left at the online price on purpose: J29 Tai sashimi (online 8.95, the original POS's
6.95 is the price of the same fish as sushi), R01 Can Soda (1.95 online and under the original POS's own
W019; its 2.00 under R01 is the stale one) and E14 Corona (4.50 online, 4.25 at the original POS: both are
to-go prices, and `bar.json` already sets the dining room's 6.50). The sauces Y21 to Y28 looked like
conflicts in the sheet (0.75 online, free at the original POS) but are not: the export sells them in sizes,
and the Small the original POS gave away is free and the default; the Medium, Pint and Quart stay as the
export has them. R07 Sparkling Water stays at the online 3.50 (the original POS's Perrier, W09, was 4.00).
The original POS's to-go beer prices (4.00 to 4.50 against the bar's 5.50 to 6.50) are a price per channel
the engine does not have yet (open).

## The original POS's modifier groups

The original POS asked its modifiers from lettered groups; the file carries them as groups with every option
labelled as the original POS printed it, and attaches them where the original POS offered them
(`groups`, `attachments`). None is required; a kitchen dish carries them after the export's own groups:

| Group | Options | On |
| --- | --- | --- |
| `spice` Spice (pick one) | NO SPICY, MILD SPICY, HOT, XXXhot | every kitchen category |
| `allergy` Allergy | *SHMP ALGY, *SHEL ALGY, *NUT ALRGY, *GLUT FREE | every kitchen and sushi category |
| `preparation` Preparation | 21 words: NO MSG, CRISPY, NO FRY, WELLdn, WHT MEAT, P/F, DRY NOODL, TAKE OUT, ... | every kitchen category |
| `sauces` Sauces | 16: BROWNSAUCE, HOSIN SA, DUCK SA, H.G.S., B.B.S., EFY/S, ... | every kitchen category |
| `ingredients` Ingredients | 39: BROCOL, MASHRO, CASHEW (+2.00), SNOWPEA, TOFU, CHICKN, LG SHRMP, ... | every kitchen category |
| `sushi_options` Sushi options | 35: GINGER, AVOCADO (+0.50), FISH EGG (+0.50), INSIDE OUT (+0.75), HAND ROLL (+1.00), SOY PAPER (+1.00), BROWN RICE, ... | Roll (Maki), Sushi, Sashimi, Sushi & Sashimi Entrees |
| `drink_options` Drink options | 35: ON ROCK, NEAT, UP, TALL, FROZEN, VIRGIN, XTRA DRY, OLIVE, TWIST, the mixers, TITOS, GREY GOOSE, ... | every drink category, the bar's shelves included |
| `platter` Platter (quantities) | VEG SPRING, SPRING ROL, CHKN WING, CHKN FINGR, SPARE RIBS (+2.00), BONLES RIB, BEEF TERIY, RANGOON | A19, A22, A23, the platters |
| `wings` Wings | SPICY, WELL DONE, SALT&PEPR (+2.00), TAKE OUT, WINGS, BOX | A04 Chicken Wings |
| `charge` Charge (pick one) | $0.10 to $5.00, no kitchen label | Y31, Y43 and the free extras |

The one-tap NO / EXTRA / SIDE / LIGHT of the modifier sheet (`Selection.prefix`, `docs/menu-engine-design.md`)
go in front of any of these, so NO BROCOL and EXTRA CASHEW print as the original POS printed them, and a
NO is free while an EXTRA charges the option's price twice (EXTRA CASHEW is 4.00; the rule and how a group
is set to charge once are in `docs/word-prices.md`). The export's pancake group of the Moo Shu dishes is
attached to the whole category. A few labels were read by eye from the original POS's abbreviations (H.G.S.
hot garlic sauce, B.B.S. black bean sauce, EFY/S egg foo young sauce, F DUCK S and F MUSD S as the free
duck and mustard sauce, Fry BK fry back; ABS WAND stays as written); the kitchen label is the original POS's
in every case, so a wrong English reading shows on the screen only.

## The data

`legacy_pos.json` has six parts, each optional:

- `categories`: by the export's English name, a Chinese name; or `"new": true` with the category's `menu`,
  `station`, `sort` and `zh` (Desserts).
- `items`: by dish code, `zh`, `kitchen` (the original POS's label) and `station` where it is not the
  category's.
- `new`: the dishes to add, each with `code`, `category` (by English name), `name`, `price`, and optionally
  `zh`, `kitchen`, `station`, `tax_class`, `description` and the `groups` the dish itself offers.
- `prices`: `variant` id and the dining room's `price` (`online` is a note).
- `groups`: by code, `name` (a string or `{"en", "zh"}`), `min`, `max`, `allow_quantity`, `sort` and the
  `options` (`code`, `name`, `kitchen_label`, `price` added, `default`).
- `attachments`: `{"category": name, "group": code}` or `{"item": code, "group": code}`.

The import refuses a dish, category, station, group or variant it cannot place, by name, and a code the
menu already has (`import_legacy`); `tests/menu/test_legacy.py` loads the whole menu and checks every entry
of the file against it, and that the engine's check and the admin's problem list stay empty.

## A running hub

A hub seeded before this still has the export's names and stations. After `hubctl update`, `hubctl menu
import` lists what the files would change and `hubctl menu import --apply` does it (`pos.menu.seed`):

- a stored dish, category or section takes the **names it lacks** (Chinese, kitchen) and a stored dish that
  inherits its station takes the file's; a name or station the editor set stays (`seed.fill`);
- the new groups, options, attachments, dishes and the Desserts category are **added**, like the bar's
  shelves were;
- a price **moves** only while it is still the online export's, as before: a price changed in the editor
  stays.

Every terminal picks the change up within seconds, like any save from the editor. The apps need no rebuild
for this: the menu is data.
