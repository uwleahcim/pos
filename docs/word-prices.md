# What Extra, On the side and Light cost

The item sheet has a row of one-tap words that go in front of any choice: **No**, **Extra**, **On the side**
and **Light** ("no peanuts", "extra shrimp", "sauce on the side"). Since 15 November 2026 (the Toast
comparison, item 10, Mike's yes) the word can change what the choice costs:

| Word | What the choice costs | Why |
| --- | --- | --- |
| No | nothing | the guest is not getting it |
| Extra | the option **twice** | a second portion goes on the dish |
| On the side | the option once | the same portion, in a cup |
| Light | the option once | less of it, but the price of the dish did not count on that |

So with "Add shrimp" at $4.00, **Extra Add shrimp** adds $8.00 to the dish, and "Add shrimp" on the side or
light adds $4.00 as before. The option's button on the item sheet shows what it will add (`+8.00`) as soon
as the word is on it, and the check lists the choice at that price.

What does not change:

- **A free option stays free.** Extra spicy, extra scallions, extra of anything with no price costs nothing:
  twice nothing is nothing.
- **A pick the group gives free stays free.** Where a group's first picks are free ("Free picks" in the
  editor), Extra on one of the free ones is free too; the word multiplies what the pick adds, not the
  option's list price.
- **A choice that is a dish** (the soup of a lunch special, a roll of the maki combination: see
  `docs/modifiers.md`) is charged once whatever the word. The kitchen makes one soup.
- **Several of the same option** are each charged with the word: two Extra shrimp add-ons are four shrimp
  prices.
- **A dish already on a check keeps its price.** The rule prices dishes as they are rung in (and a dish
  changed afterwards, which is taken off and put back, is priced again).
- The recipe side (what a choice uses up) is as before: Extra counts the option once.

## Changing the rule

In the menu editor, under **Option groups**:

- **Extra, On the side, Light** (the first row of the list) is the location's rule: for each word, **½×**,
  **1×**, **1½×** or **2×** the option's price. It holds for every option group that does not say
  otherwise, and the line under the buttons says the rule in words. Set Extra to 1× and Extra never costs
  more anywhere; set Light to ½× and a light portion of a paid option is half price.
- **A group › Extra, On the side, Light** says the same for the choices of that one group, with **As the
  location** to go back to the location's rule. This is where a group is set not to charge: open the group
  and tap **1×** beside Extra. The location's page lists the groups that charge otherwise.

A change is saved with the menu (Save), and every screen takes it up when the menu's revision moves, like
any other menu change. Amounts are rounded to the cent (half of $0.75 is $0.38).

On the bundled menu the rule matters for the seven groups that have a priced option that is not a dish:
Ingredients (Cashew +2.00, so **EXTRA CASHEW is $4.00** where it was $2.00), Sushi options (Avocado, Fish
egg, Inside out, Hand roll, Soy paper), Extra Lettuce, Extra Pancake, Platter (Spare ribs), Wings (Salt &
pepper) and Charge. No group is set apart by the import: the location's rule holds for all of them until a
manager says otherwise in the editor.

## For developers

- The hub prices every dish (`price_lines` in `api/app.py`), so the rule takes effect with the hub alone.
  The engine applies it in `_apply_group` (`menu/engine.py`): after the option's amount is known (free, a
  delta after the group's free picks, or an absolute price) it is multiplied by
  `Definitions.word_factor(group, prefix)` and rounded with `money()`. A slot is not multiplied.
- `Definitions.word_factor` reads, in order: the group's own `Group.word_factors` (a map of word to
  factor, or `None` for "as the location"), the location's `Word` row for the word, and the standing rule
  `STANDING_FACTORS` in `menu/defs.py` (extra 2, side 1, light 1). A hub with no row and no map charges
  the standing rule, so nothing has to be imported.
- The database gained the table `option_word (code, factor)` and the column `modifier_group.word_factors`
  (jsonb); the hub adds both on start. A standby hub on newer code than its primary reads a missing
  `option_word` as empty (`LATER_TABLES` in `menu/store.py`).
- The editor's API has a kind `word` (key = the word) beside `group`; `check()` refuses a word that is not
  one of the three (`bad_word`) and a factor outside 0 to 10 (`bad_factor`). The editor's buttons offer
  four factors; the API takes any in that range.
- `GET /menu/items/{code}` carries `words` on each group (`{"extra": "2", "side": "1", "light": "1"}`), so
  the app shows the price on the option's button and estimates a line offline with the same rule
  (`choiceCents` in `lib/menu.dart`). An app from before reads the price off the hub's answer and is right
  on the check; only its button badge and its offline estimate show the option once.
- Tests: `backend/tests/menu/test_word_prices.py`, `apps/pos_app/test/word_prices_test.dart`.
