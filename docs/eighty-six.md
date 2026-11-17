# Sold out, and a number left

The kitchen has six ducks tonight. Since 2026-11-15 whoever 86s a dish can type that number instead of
waiting for the last one to go: the dish stays on sale, its tile says **6 left**, every one sold takes the
number down, and at zero the dish marks itself sold out. The number clears overnight, so yesterday's count
is never on today's menu.

This adds a count to the 86 rules of the Menu Engine Design (`menu-engine-design.md`, "86 state"), with the
owner's yes on 2026-11-15. The 86 itself is as it was: one switch, and the dish stays sold out until someone
brings it back.

## On the order screen

**Hold a dish**, then tap the 86 mark at the top of its sheet (holding a dish that is already sold out
opens the 86 sheet directly). For each size the sheet has:

- **Sold out**: the switch, as before. On, the dish cannot be sold until it is switched off.
- **Number left**: type how many can still be sold (1 to 999) and tap **Set**, or press Enter. The dish
  stays on sale with that number. Typing a new number starts again from it (the kitchen made more).
  **No number** takes the count off and leaves the dish on sale.

A dish with several sizes is counted per size: six pints and four quarts are two numbers.

What the screens show, on every terminal within a second or so:

- **The tile** shows `6 left` where the price normally is, in the place where `86` appears once none are
  left. The price is still on the dish's sheet and on the check. A dish with several sizes shows a number on
  its tile only when every size on sale is counted (the lowest one); otherwise the size buttons say it
  (`Size · 2 left`).
- **At zero** the tile says `86`, like any dish that ran out, and the dish cannot be added.
- **Asking for more than there are** is refused with the number: `Only 2 Peking Duck left.` This covers a
  new dish, a larger quantity on a dish already on the check, and the second of two screens ringing in the
  last one at the same moment.

## What takes the number down, and what gives it back

- A dish going on a check takes one, times its quantity, whether or not it has been sent to the kitchen.
- A dish that is another dish's choice counts too: a maki combination with a California roll takes one
  California roll, and a lunch special takes one of its soup. (A choice that is only a word, such as brown
  rice, cannot be counted: it can only be 86'd, by the hub, and the app has no screen for that yet.)
- A dish coming off a check gives it back: removed before it was sent, voided after, or its whole order
  voided. The number never goes above the one that was typed.
- **A void gives the dish back even if the kitchen had already made it.** If that one went in the bin, type
  the number again.
- Changing a dish that was already sent (its choices, its note) takes nothing, even when it was the last
  one and the tile already says 86. Asking for more of it than there are is refused, and the check stays as
  it was.
- A dish that was on a check before the number was typed is not part of the number: taking it off gives
  nothing back beyond the number typed.

## The list for the manager

Orders screen › **Location** › **Sold out and running low**, the first card. It says how many dishes are
sold out and how many have a number, and opens the list: what is sold out first, then every counted dish
with the fewest left at the top (`3 of 12 left`), and who set each one. **Bring back** puts a sold-out dish
on sale again; **No number** stops counting a dish and leaves it on sale. Setting one is done at the dish,
on the order screen.

The same list is a card on **Today** (`today.md`), where **86 a dish** finds a dish by name and sets it
from there: for an owner who is not at an order screen.

## When the number clears

At four in the morning, the restaurant's own time (`POS_TIMEZONE`). Not at midnight: a bar still pouring at
half past twelve keeps its counts until it has closed. A dish that reached zero is on sale again the next
day with no number. A dish marked **Sold out** by hand does not clear by itself.

## What it is not

- It is not inventory. Nothing is counted in the walk-in, no ingredient is tracked, and nothing is 86'd by
  itself unless someone typed a number for that dish. The design's auto-86 from stock is still to come and
  still opt-in.
- A terminal taking orders while no hub answers (the capture-only mode of the offline runbook) sells from
  the number it last saw. When its orders reach the hub, the ones beyond the number are refused with the
  message above, as an order for an 86'd dish already is.
- The number lives on the hub that takes the orders, with the 86 board. The standby hub has it in its
  database and shows it from its next start.

## For developers

- `POST /menu/86` takes `remaining` (1 to 999) with `status: available` for a variant; `available` without
  it takes the count off; `sold_out` drops it. 422 `bad_count` for a count on an option or with `sold_out`.
- `GET /menu/86` lists what is sold out and every counted dish: `status`, `left`, `total`, `until`, `by`.
- Every variant in `GET /menu` and `GET /menu/items/{id}` carries `left` (null when not counted). The app
  takes the key's presence to mean the hub keeps counts, and offers no number box otherwise.
- The count is two columns on `availability_state` (`remaining`, `total`); a counted row keeps `status`
  available and an `until` of the night's end (`pos.localtime.night_end`). `MenuEngine.status_of` says
  sold out at zero.
- A priced line carries `uses` (variant id to how many one of the line takes) when it holds other dishes;
  without it a line takes one of its own variant.
- `pos.orders.counts.count_ops` weighs each batch before it is stored, by the difference it makes to what
  its order holds, under `MenuService.counting()` so two requests cannot both take the last one; then
  `MenuService.take` moves the numbers and tells the screens the menu changed. With no dish counted nothing
  is locked and no order is read.
- The menu's problem code for a counted dish at zero is `none_left` (a hand 86 stays `sold_out`). The price
  preview (`POST /menu/price`) leaves it out, since the dish being previewed may be the last one, already
  on the check.
