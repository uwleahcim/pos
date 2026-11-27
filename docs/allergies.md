# Allergies told at the table

A guest says "I'm allergic to peanuts". Since 2026-11-15 the server notes it on the order, for the whole
table or for one seat, and from then on every kitchen ticket of that order says so in a block of its own.
It is the menu engine design's rule ("the kitchen ticket prints the order's allergy note in bold on every
station's copy; the POS shows a badge when a line conflicts with an allergy noted on the order"), built.

**What it is not.** It does not decide what a guest can eat. The kitchen is always told. A dish is marked
on the check only when the menu data says what is in it, and a dish with no mark is not a promise. Today
the restaurant's menu lists what is in almost no dish (535 dishes, no recipes, five with an imported
allergen tag that the engine does not read), so the marks will be rare until that is filled in. The ticket
does not depend on it.

## On the order screen

**The Allergy chip** leads the seat row (on a to-go order, which has no seats, it stands alone above the
menu). A tap opens one box:

- **Who**: Table, or a seat. It opens on the seat the next dish goes to. Each seat keeps its own, so two
  guests' allergies are noted in one visit. A to-go order has no seats: the allergy is the order's.
  Where the location turned **Seat numbers** off (`location-settings.md`, "Seats on the order screen") a
  table's allergy is the whole table's and the box does not ask who; a seat that has one noted all the same
  can still be picked, to change it or take it off.
- **The allergens** the menu names, as buttons that stay down, red, while the guest cannot have them:
  Milk, Eggs, Fish, Crustacean shellfish, Tree nuts, Peanuts, Wheat, Soybeans, Sesame, and anything else
  the menu's allergen list is given. Three across on a phone, so the box fits without scrolling.
- **Anything else, in words** (80 characters): "no oyster sauce", "severe", an allergen the menu does not
  list.
- **No allergy** empties the one on screen; **Save** sends what changed.

Once an order carries an allergy:

- A **red strip** under the app bar reads it out, over the check and the menu alike (on a phone they are
  two tabs): `ALLERGY  Table: Peanuts · Seat 2: Sesame - no oyster sauce`. A tap opens the box again.
- The chip turns red, and each **seat with an allergy carries a warning mark** in the seat row.
- A dish the menu says contains it reads **ALLERGY: contains Wheat** in red on the check, and the screen
  says so once in a red message when the mark first shows (a phone has the check behind the menu). A
  table's allergy is held against every dish, a seat's against that seat's dishes.
- A seat with an allergy stays in the seat row even if the party is made smaller, and cannot be removed
  until its allergy is taken off.

Nothing is asked when a table is opened: the chip is there when a guest speaks up.

With no hub answering, an allergy is noted like any other tap: it shows at once and is sent when a hub is
back. The kitchen's ticket prints then, headed LATE like everything taken offline, so tell the kitchen by
hand meanwhile.

## On the kitchen's tickets

Every ticket of the order (a send, a change, a void, and the copy a fallback printer gets) at every
station carries the block, right under the header, the word ALLERGY big and white on black:

```
WOK 1
#3412  dine in                             18:42
Table 12  2 guests
Server Amy
------------------------------------------------
                    ALLERGY
Table: Sesame
Seat 2: Peanuts, Crustacean shellfish - no
  oyster sauce
------------------------------------------------
1 x General Tso's Chicken (Qt) [s2]
    ** ALLERGY: Peanuts, Crustacean shellfish -
  no oyster sauce **
```

- **Every station reads every allergy**, the seat's too, though the wok may cook nothing for seat 2: a
  wok, a fryer and a cutting board are shared by every dish.
- **Under each dish of a seat with an allergy** the seat's own allergy prints again, so the cook who makes
  that guest's plate sees it on the dish. The table's allergy is in the block only.
- The words are plain English, whatever language the station's dishes print in, as the old POS's
  `*NUT ALRGY` lines were.
- A **to-go order** says `Order: Peanuts`, on the cooks' tickets and on the takeout counter's.

**Told, changed or taken off after dishes were sent**, each station that has dishes of the order gets a
ticket of its own, with three beeps:

```
*** ALLERGY *** WOK 1
...
                    ALLERGY
Seat 2: Peanuts
For the dishes you already have:
------------------------------------------------
1 x General Tso's Chicken (Qt) [s2]
    ** ALLERGY: Peanuts **
```

It lists that station's dishes already sent and still on the order (a voided dish is not listed; a
station with none left is not told). Taken off, it reads **NO ALLERGY NOW** and "The allergy told before
was taken off." A station whose dishes go out in the same send is not told twice: its ticket carries the
block. The same allergy saved again, or saved by someone else, prints nothing.

## How it is kept

An `allergy` operation in the order log: `seat` (left out for the table), `allergens` (the menu's codes),
`note`, `by`, `by_id`. The latest word on a seat stands (by the operation's clock), each seat on its own,
so two screens noting two seats both count. One with no allergens and no words takes that seat's allergy
off. A code the menu does not name is kept and shown as it is, never dropped.

`GET /orders/{id}` returns `allergies` (the table's first, then by seat) and, on each line, `allergy`: the
codes its seat or the table told that the dish's `priced.contains` has. `GET /menu/allergens` lists the
menu's allergens with their names, in the menu's order; the app saves the answer for when no hub answers.
An app on a hub older than this gets a 404 there and shows no chip.

"May contain" (a shared fryer, the engine's cross-contact by station) is not marked yet: the order keeps
only what a dish contains.

Code: `backend/src/pos/sync/oplog.py` (`allergy`, `allergy_conflicts`), `pos/printing/service.py`
(`allergy_lines`, the notice in `on_ops`), `pos/printing/ticket.py`; `apps/pos_app/lib/allergies.dart`,
`screens/allergy_dialog.dart`, the chip and the strip in `screens/order_screen.dart`. Tests:
`backend/tests/orders/test_allergies.py`, `backend/tests/printing/test_allergy_tickets.py`,
`apps/pos_app/test/allergies_test.dart`.
