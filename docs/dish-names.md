# Dish names in Chinese on the screens

The menu holds most of the kitchen's dishes under two names, English and Chinese, and the kitchen's tickets
already print the Chinese. Now each person says which name they read on the screens. Someone who reads
Chinese sees **左宗棠鸡** as the big name on the dish's tile and on the check, with "General Tso's Chicken"
small under it on the tile. Everyone else sees what they saw before.

Since 17 November 2026 (the Toast comparison, the app in Chinese: the dish names). Hub and app. Nothing to
turn on and no menu import: the names are the ones the menu already holds.

## What the staff see

Orders screen › **Display** (under the three dots on a phone). Under the text size and High contrast there
is **Dish names**, with two buttons: **English** and **中文**.

- **A tap changes the screen at once**, and is kept with the person's text size. It follows them to every
  screen they sign in on. Nobody else's screens change.
- **A dish's tile on the menu:** the name they read is the big one, the other is the small line under it.
  For English this is what the tiles showed before.
- **A category's tile** is named in the language they read: **招牌菜** for Chef's Specials.
- **A dish's sheet** (the choices, the note) is headed by the name they read, then the other.
- **The check** on the order screen, and the two checks of **Split**, call each dish by the name they
  read: "左宗棠鸡 (Quart)".
- **A dish or a category the menu names in English only stays in English**, whoever reads it. Today 218
  of the 539 dishes and 32 of the 43 categories have a Chinese name. A manager adds the others in the menu
  editor, where a dish and a category each have a box for it (**中文名**).
- **The search** finds a dish by either name, as before, whatever the person reads.

When the person at a screen changes in the middle of an order, the menu and the check turn to the names
the new person reads. The order stays as it is.

A category's name typed in the menu editor, English or Chinese, now goes onto the category's tile on the
order screen with Save. Before, the tile kept the name the category had when it was put on the menu.

## What does not change

- **What is recorded.** A dish is rung in under its English name whoever rings it, so the bill, the
  reports, the check's history and the next person's screen all read one name.
- **The bill and the receipt** print in English.
- **The kitchen's tickets** print each dish's kitchen label, as before (`original-pos.md`): the Chinese
  name and the kitchen's own short name. A ticket does not depend on who rang the dish in.
- **The app's own words** stay in English: the buttons, "4 dishes", Send, Bill, the courses.
- **The prices.** Nothing here touches a price or the tax.

## Good to know

- The screen keeps one menu and turns the names round as it draws them, so changing the setting, or the
  person, reads nothing again from the hub and works while the hub is away.
- An app that is not rebuilt has no **Dish names** buttons and shows English. A hub that is not updated:
  the dishes follow the setting, and the categories stay in English until the hub is updated.
- A size of a dish (Quart, Lunch) and the choices on a dish (the sauce, the rice) stay in English: the
  menu holds a Chinese name for 12 of its 251 choices and for none of its sizes.

## Not built

- The app's own words in Chinese (buttons, headings, messages).
- The choices on a dish and its sizes in Chinese.
- Chinese names on the other lists of dishes: the count-down board, the reports, the check's history, the
  void and comp questions.
- Both names on one line of the check.
- A third language.

## For developers

- Hub: `MenuService._section_second_name` (`backend/src/pos/menu/service.py`): every section of `GET /menu`
  says `second_name`, the name in the other language, as an entry does (`null` where the menu has none). Nothing else on the hub changed. A person's choice is the `locale` of their
  preferences (`identity/preferences.py`), `en` or `zh`, which the hub already kept. `price_lines` still
  names every line from the menu in English, whatever `item` a screen sends.
- App: `lib/dish_names.dart` (`DishLanguage`, an `InheritedWidget` over the whole app in `main.dart`, so
  dialogs and the menu's kept tiles follow it; `namesShown`; `chineseLineName`, which reads a line's
  Chinese name from the `priced` the hub keeps with it). `MenuSection.secondName`; `Line.zhName`,
  `LocalLine.zhName` and `ChosenLine.zhName` (a dish just rung shows its Chinese name before the hub
  answers; none of them is sent). `_SectionButton`, `_EntryButton` and `ItemSheet` in
  `lib/screens/menu_panel.dart`; `_lineTile` in `order_screen.dart`; `split_screen.dart`;
  `DisplayDialog`.
- The menu editor: `renameCategorySections` (`lib/screens/menu_editor.dart`). The order screen names a
  category's tile from its section (`<menu>/<category>`), which has names of its own; a change in the
  category's box is carried to the section of every menu the category is on, unless the section was given
  a different name.
- The menu on the device is always the English one (`locale` is not passed to `GET /menu`), so `'item'`
  in an `add_line` is the English name.
- Tests: `backend/tests/menu/test_second_names.py`, `apps/pos_app/test/dish_names_test.dart`.
