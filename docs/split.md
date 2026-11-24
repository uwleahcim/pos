# Splitting a check

A table can pay on several checks. Beside the total at the foot of every check, before the Bill button,
stands **Split**. It opens the split screen: how this table pays.

Splitting never makes a second order. The dishes stay on the one order the kitchen cooked from, and each
dish says which check it is on. So nothing prints in the kitchen when a dish changes checks, a dish keeps
its seat, and a split is undone with one tap.

## The split screen

Three ways stand at the top as buttons; the one in force is lit.

- **By seat**: one tap. Every seat with a dish of its own gets a check, numbered as the seat. A dish rung in
  for the table (no seat) is shared by every check in equal parts. A dish added later goes to its seat's
  check by itself. The button waits until at least one dish is on a seat.
- **Evenly**: the dishes stay together and the total is cut in equal parts, as many as there are guests to
  start with. − and + make it fewer or more (two at least, twenty at most). The odd cents go to the first
  parts, one each, so the parts add up to the total.
- **One check**: everything back together.

Below, each check is a card: its number, what it comes to, a button for its own bill, and its dishes. On a
phone the cards stand one under the other; on a tablet side by side.

**Moving dishes.** Tap a dish to pick it (any number of them; tap again to let one go). The foot of the
screen then offers where they go:

- **Check 2** (one button for each check there is) moves them there.
- **New check** opens the next number and puts them on it. This is also how a table on one check is first
  split by hand: pick what one guest had, tap New check.
- **Share** asks which checks share the dish. Each pays an equal part. "Another check" adds one more to
  share with.

A line of two of a dish moves as one. To put one on each of two checks, share the line between them: that
comes to one each.

Where a dish stands shows at once. What a check comes to is the hub's to reckon, and reads "…" for the
moment until it has.

On the check itself, each dish of a split table says where it is ("check 2", "shared by checks 1, 2"), and
the Split button says how many checks there are ("Split 3").

## What each check comes to

Every check carries its own part of everything, so nothing is lost in a split:

- **A dish** is on one check whole, or on several in equal parts (25.00 by three is 8.34, 8.33, 8.33).
- **A comp or a discount on a dish** follows the dish, shared the same way as the dish.
- **A discount on the whole check** goes to each check in proportion to what its dishes are worth.
- **A service charge** (the party's gratuity, a charge staff put on) goes to each check in proportion too.
  Whether a party's gratuity applies is still decided by the table as a whole: six guests on three checks
  are still a party of six.
- **Sales tax** is the table's tax, divided by what each check holds.

The checks add up to the cent to what the table owes as one check, so **splitting never changes what the
table owes**. The price of that: a check's tax can be a cent more or less than 7% of its own subtotal.

## The bills

The **Bill** button on a split table prints a bill for each check; a message says how many and where. On
the split screen each check (and each part of an even split) has a button for its own bill alone.

- **A check's bill** is headed "Table 12  Check 2" and says "One of 3 checks at this table". It lists that
  check's dishes. A shared dish shows this check's part with the whole under it ("1/3 of 25.00"); its
  choices are named without their prices, which are part of the whole dish. Then the check's own subtotal,
  its part of each discount and charge by name, its tax and its total.
- **A part of an even split** is the whole table's bill, every dish on it, with the table's total and then
  "PART 2 OF 4" in big type: the figure that guest pays.

Bills go to the printer as in [bill.md](bill.md): the screen's own, else the location's.

## Paying

Payments at the table are not built yet. The hub is ready for them: a payment can name the check it is for,
and each check then says what was paid on it and what it still owes (on its bill too). A payment that
names no check counts for the table and fills the checks in order.

## Not in this yet

- Splitting one line of two into two lines. Share it between two checks instead.
- Unequal shares of a dish (two thirds and one third).
- Paying or closing the checks of a table one by one: that comes with payments.
- The bill of an unsplit table grouped by seat.

## For developers

- The order: field `split` (`{by: seat}`, `{by: dish}`, `{by: even, ways: n}`; anything else is one check)
  and, on a line, `checks` (a list of check numbers 1 to 20; set with `set_line`, null puts the dish back
  where the split places it). `checks` is in `LINE_FIELDS` and not in `KITCHEN_FIELDS`. An `add_line` with
  `replaces` inherits the replaced line's `checks`. A `pay` may carry `check`.
- `backend/src/pos/orders/split.py`: `split_of(fields)`, `placed(state, split)` (which checks there are and
  which each dish is on), `parts` (equal parts), `prorate` (in proportion, largest remainder) and
  `split_checks`, which `check_for` calls. `GET /orders/{id}/check` gains `split` and `checks`: per check
  `check`, `lines` (`line_id`, `shared`, `of`, `total`, `discount`, ...), `subtotal`, `discounts`,
  `discount_total`, `charges`, `charge_total`, `tax`, `total`, `payments`, `paid`, `due`. `checks` is empty
  while the table is one check. The top-level totals are unchanged by a split.
- `bill_for(..., number=n)` makes one check's bill; `POST /orders/{id}/bill` takes `{printer?, check?}`,
  prints every check's bill without `check`, and answers `bills` and `jobs` beside the first job's fields;
  409 `no_such_check`.
- The app: `lib/split.dart` (`placedOn`, the hub's rule again so a tap shows at once; `putOps`, `bySeatOps`,
  `evenOps`, `oneCheckOps`), `lib/screens/split_screen.dart`, `SplitMode`, `CheckPart` and `Check.parts` in
  `lib/menu.dart`, `Line.checks` in `lib/api.dart`, the `_TotalFoot` on the order screen (its buttons reflow
  by measured width: icons and words, words alone, or the row above the total, where they wrap; a to-go
  order has Labels between Split and Bill, `bag-labels.md`). The Split button shows only
  when the hub's check carries `checks`, so an app ahead of its hub offers nothing that would not work.
- Tests: `backend/tests/orders/test_split.py`, `backend/tests/printing/test_split_bill.py`,
  `apps/pos_app/test/split_test.dart`. The sync simulation also splits and moves dishes between checks.
