# The to-go question: what goes in the bag

Before a to-go order is sent, the screen asks once what the customer wants in the bag besides the food:
chopsticks, forks, napkins, or nothing. The order is not sent until somebody answers, and "Nothing" is an
answer. The answer prints on the takeout station's ticket, where the bag is packed.

Since 17 November 2026 (the Toast comparison, row 26). Hub and app. It is on to start, with Chopsticks,
Forks and Napkins; a manager changes or turns it off under Location. The old POS rang these as free dishes;
here they are one question, cost nothing and are in no total.

## What the staff see

**Send** or **Pay & send** on a to-go order brings up a sheet from the foot of the screen. Its title is the
question, and under it is one button for each thing the location offers.

- **A tap puts one in the bag.** Another tap on the same button makes it two ("2x Chopsticks"), and so on
  up to 99. The minus on a picked button takes one out again.
- **Nothing** answers in one tap, and the order goes.
- **Send** (beside it) takes what was picked, and the order goes. It is grey until something is picked.
  Before a payment the button says **Next**, and the payment follows.
- **Closing the sheet without an answer sends nothing.** The order stays as it was, and the next Send asks
  again.
- **Once.** An order that carries an answer is not asked about again: not when more dishes are sent later,
  and not when a payment was called off after the answer.

The answer then stands on the check, over the totals: **In the bag: 2x Chopsticks, Forks**, or **In the
bag: Nothing**. A tap on that line asks again, with the answer filled in and the button reading **Save**.
A change after the kitchen has the order prints a slip at the takeout station (below), and the screen says
so.

Only a to-go order is asked: pickup, phone, counter, delivery. A table's check never is.

## The setting (a manager)

Orders screen › **Location** (manager PIN) › **To-go question**, on the card with the quote times.

- **Ask before a to-go order is sent**: the switch. Off, a to-go order is sent with nothing asked.
- **The question**: its words, 60 letters at most. Left empty it reads "What goes in the bag?".
- **What it offers**: one row a button, in the order the buttons show. Rename, remove with the bin, **Add
  choice** for another. Eight at most, 24 letters each, no two with the same name. With the switch on there
  must be at least one.

**Save** sends it to the hub. Every screen asks by it from its next to-go order.

Renaming or removing a choice changes nothing on the orders already answered: an order keeps the names it
was asked under. Something an order carries that is no longer offered still shows as a button when that
order's answer is changed, until it is taken out.

## On paper

- **The takeout station's ticket** (the one that takes a to-go order whole, for the bag) says the answer
  under the dishes, after a rule: **ALSO IN THE BAG**, then a large line for each thing ("2 x Chopsticks",
  "Forks"), or **NOTHING** when the customer wanted none. An order nobody was asked about says neither.
- **No cook's ticket says it.** It is the bagger's business.
- **Changed after the order was sent**: the takeout station gets a short slip headed **BAG**, with the
  order's number and name, no dishes, and **NOW IN THE BAG** with the answer as it stands. The printer beeps
  as it does for a change to the dishes.
- **An order for later** still waiting for its time: nothing of it is on paper yet, so its ticket says the
  latest answer when it prints, and no slip prints.
- **More dishes sent later**: that send's ticket for the bag says the answer as it stands, not more of the
  same.
- **No printer at the takeout station**: no ticket says the answer. It is still on the check.

## Good to know

- The hub does not refuse a send that carries no answer. An order taken while the hub was away, or by a
  screen that is not rebuilt yet, is sent all the same. The question is the screen's.
- A screen reads the question when a to-go order is opened and remembers the last one it read, so it still
  asks while the hub is away.
- An app that is not rebuilt asks nothing and shows no answer. A hub that is not updated: the app asks
  nothing, and Location's row says the hub is older.
- The check's history (a manager, from the check) says what was answered, by whom and when, and each change
  after it.
- The answer is not a dish. It is on no bill, in no sales figure and in no report.

## Not built

- A different question for delivery than for pickup, or more than one question.
- A choice that costs something. A paid extra is a dish on the menu, so it is on the bill and in the sales.
- Typing the number instead of tapping it up.
- The answer on the text sent to the customer, or on the guest's bill.
- A question for a table's check that is packed to go at the end.

## For developers

- The answer: order field `bag` (`ORDER_FIELDS` in `backend/src/pos/sync/oplog.py`), written with
  `set_field` (or on `create`), last writer wins. Shape `{"items": [{"id", "name", "qty"}]}`; an empty list
  is "nothing"; no field is "not asked". `backend/src/pos/orders/bag.py`: `bag_of`, `bag_lines`, and
  `bag_ops`, which `append_ops` runs on every batch: it tidies the answer (ids `[A-Za-z0-9_-]{1,32}`, each
  once, 8 at most, names 24, qty 1 to 99) and answers a bad one in `refused` with `invalid_bag`.
- The setting: `bag` in `backend/src/pos/settings.py` (`clean_bag`): `{enabled, question, choices: [{id,
  name}]}`. `GET /settings/bag` (no token) and `PUT /settings/bag` (manager token; a new choice sends no id
  and the hub makes one from its name; 422 `bad_value` with the reason).
- Printing: `PrintService.bag`, `bag_slip` and `_keep_current` in `backend/src/pos/printing/service.py`;
  `Ticket.bag` and the kind `bag` in `ticket.py`. The slip's job id is `<op_id>:bag:<printer>`.
- History: the step `bag` (`items`, `changed`) in `backend/src/pos/orders/history.py`.
- App: `lib/bag.dart` (`BagQuestion`, `BagItem`, `bagAnswer`, `bagField`, `bagWords`); `askBag` and
  `BagSheet` (`lib/screens/bag_sheet.dart`); `_askBag` and `_changeBag` in the order screen;
  `BagQuestionDialog` (`lib/screens/bag_question_dialog.dart`); `PosApi.bagQuestion` and `saveBagQuestion`.
- Tests: `backend/tests/printing/test_bag.py`, `apps/pos_app/test/bag_test.dart`.
