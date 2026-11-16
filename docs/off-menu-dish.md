# Off-menu dishes and market prices

Two kinds of dish have no price on the menu. Whoever rings one in types it:

- **An off-menu dish** asks **what it is** and **its price**: a special the chef made up tonight, something
  a regular asks for. The menu has four of them, as the old POS did: **Open Food**, **Open Soup**,
  **Open Sushi** and **Open Drink**.
- **A market price** asks **its price** alone and keeps its own name: the fish of the day, lobster by the
  pound. No dish is set that way to start; a manager turns it on for a dish in the menu editor.

Since 16 November 2026 (the Toast comparison, row 7).

## Ringing one in

1. Its tile says **Ask** where the others say a price. Tap it.
2. The dish's sheet opens with the boxes: **What is it** (an off-menu dish only) and **Price**. Type them.
   The price takes `18.5`, `18.50` or `18`.
3. **Add**, or Enter in the price box. Until the boxes are filled the button stays off, and nothing goes on
   the check.

On the check the dish stands under what was typed, at the price typed. A tap on its line opens the sheet
again with both in the boxes, to change either. The quantity, the seat, the course, a note to the kitchen,
a comp, a void, a split and a move all work as for any dish. Two off-menu dishes are two lines, each with
its own name and price.

## What the kitchen, the bill and the books see

- **The kitchen ticket prints what was typed** ("1 Lobster ginger scallion"), at the dish's station:
  Open Food at Wok 1, Open Soup at the soup station, Open Sushi at the sushi bar, Open Drink at the bar.
  Ring a special from the open dish of the station that cooks it.
- **The bill prints what was typed**, at its price.
- **It is a sale like any other.** The price is in the check's subtotal, taxed at the dish's rate (Open
  Drink as alcohol, the others as food), and in the sales.
- **The report lists every one.** Orders screen › Location › **Voids and comps report** › **Typed
  prices**: what they came to and how many, added up by who rang them in, then each one: when, the table or
  order number, what was typed, the dish it was rung as, the price and who rang it. A manager can see at a
  glance who types prices and how much. One voided since stays on the list, marked, and counts for nothing
  (the voids above it value it).

## What can be typed

- A price above zero, up to $9,999.99, in dollars and cents. **A free dish is a comp**, not a price of
  zero: ring it at its price and comp it, so it shows as given away.
- A name up to 40 letters, about a line of a kitchen ticket.
- The hub takes a typed price **only for a dish that asks**. A price sent with any other dish is refused,
  so no screen can ring an Egg roll at a price of its own.

## Making a dish ask

A manager, in the menu editor: the dish › **Sizes and prices**:

- **Its price is typed when it is rung**: a market price. The prices listed under it are no longer used.
- **Its name is typed too**: an off-menu dish. Turning it on turns the first on as well.

Save, and every screen shows **Ask** on the dish within seconds. Turn them off and the dish sells at its
listed price again. A new off-menu dish for another station (Open Fryer, say) is a new dish in the editor
with both switches on and its station picked.

## Good to know

- **Anybody signed in can ring one**, as on the old POS. No manager's PIN is asked: the report is the
  check on it. Say so if a PIN or a list of roles is wanted.
- With no hub answering, the dish still goes on the check at the price typed, marked "estimated" like any
  dish, and the hub prices it for real once it is back.
- **Same again** on a to-go order rings a typed dish as it was, name and price.
- The choices of a dish that asks its price (a size, an add-on) add to the price typed, as they add to a
  listed price.
- Not built: a gift certificate of any amount (the old POS's "Gift Cert $XX"), and picking the station
  while ringing.
- An app that is not rebuilt yet shows the open dishes at $0.00 and cannot ring them: the hub answers that
  the price is needed. Rebuild the apps the same day as the hub.
- Not tried on the real printers from here.

## For developers

- Menu data: `Item.attrs["asks_price"]` and `["asks_name"]` (`Item.asks_price`, `asks_name`; a dish that
  asks its name asks its price). `/menu` entries and `/menu/items/<code>` carry `asks_price` / `asks_name`
  when true; `needs_choice` is true for such a dish.
- A line's `request` carries `price` (dollars, a string) and `name`. `MenuEngine._typed` checks them:
  `price_needed`, `bad_price`, `name_needed`, `bad_name`, and `price_fixed` / `name_fixed` for a dish that
  does not ask. The price becomes the line's unit price with `price_source: "typed"`; the name replaces
  every name of the dish on that line, the kitchen label included. `POST /menu/price` previews it.
- `priced.typed` on a line is `{price, menu_name, name?}`. `pos/orders/typed.py` lists such lines for
  `GET /reports/adjustments`: `typed`, `typed_total`, `typed_count`, `typed_by_staff`.
- The four open dishes are rows of `menu/data/legacy_pos.json` with `"asks": "name"`; a running hub takes
  them with `hubctl menu import --apply`.
- App: `MenuEntry.asksPrice` / `asksName`, `LineRequest.price` / `name`, `typedPrice()` in `lib/menu.dart`;
  the boxes are in `ItemSheet` (`lib/screens/menu_panel.dart`); the switches in
  `lib/screens/menu_editor.dart` (`setAsks`); the report section in `lib/screens/adjustments_screen.dart`.
- Tests: `backend/tests/orders/test_typed.py`, `apps/pos_app/test/typed_dish_test.dart`.
