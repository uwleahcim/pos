# Labels for the bags of a to-go order

An order that leaves in three bags is three things on the shelf, and the ticket that says whose they are is
stapled to one of them. **Labels** on a to-go order prints a short slip for each bag: the order's number and
name, which bag of how many it is, and when it is due. Whoever hands the order over, or drives it, counts
the bags against the slip and leaves none behind.

Since 24 November 2026 (the Toast comparison, row 27). Hub and app. Nothing to turn on, and **nothing prints
by itself**: a label prints when somebody taps the button, and only then.

The slips come out of the receipt printers the location has, on their own paper. That paper is not sticky:
a slip is stapled or taped to its bag, as a ticket is.

## Printing them

On a to-go order's screen, beside the total, between **Split** and **Bill**: **Labels**. On a phone the
total is on the **Check** tab.

1. Tap **Labels**. The screen asks **How many bags?** and says whose they are ("#12 Linda P.").
2. Tap the number. The numbers 1 to 12 are there at once; **More** shows 13 to 24.
3. The labels print, and the screen says where: "3 labels are printing at Takeout".

**Cancel**, Escape or a tap beside the question prints nothing.

- **Every to-go order has the button** once it has a dish: pickup, phone, counter, online, delivery,
  catering. A table's check has none, and neither has a bar tab.
- **Any time.** Before the order is sent, while it is cooked, when it is packed, after it is paid, picked up
  and closed. A label that tore is printed again the same way.
- **Asked again, it prints what it is asked for.** The hub does not keep how many bags an order had. A
  fourth bag after three labels: tap Labels and 4, and throw the first three away, since they say "of 3".
- What was just rung in goes to the hub first, so the labels are headed with the order as it stands. While
  the hub is away the screen says the labels did not print. Nothing is kept to print later.

## What a label says

From the top, each line only when the order has it:

- `#12  LINDA P.`, large: the number the order is called by and the name on it, as its ticket heads it. An
  order with no name says the number alone. A name that is not in the printer's own letters (陈) is drawn.
- `BAG 2 OF 3`, large, white on black: the one thing that tells a label from the next.
- `DELIVERY`, large, when the restaurant's driver brings it (`delivery.md`).
- `READY BY 18:30`, as the ticket says it, with the day when it is not today: `READY BY 12:00  SAT NOV 28`.
  An order for now with no time on it says no time.
- A small line with the end of the order's id and when the labels were printed.

What a label does **not** say: the phone number, the address, the note for the driver, the money, and any
dish. The shelf is where other customers stand. Where a delivery goes is on the bill that travels with the
bag (`delivery.md`), and what is in the order is on the takeout station's ticket and the pack sheet
(`catering.md`). Nobody tells the POS which dish went into which bag, so no label lists one.

All the labels of one asking are one print job, each cut off the next. The printer's bell does not ring.

## Where they print

Where the pack sheet prints: at the **takeout station's printer**, which is where the bag is packed. A
location with no takeout station gets them where its bills print (`bill.md`), and one with no printer at
all is told so.

When that printer does not answer, its fallback printer takes the labels like any other paper
(`printing.md`), each headed `TAKEOUT PRINTER DOWN, PRINTED HERE`.

## Good to know

- **Printing labels changes nothing.** Nothing is written on the order: not its stage, not a payment, not
  its history. No ticket, bill or report is touched. The pickup board and the text to the customer follow
  the order's stage as before, and Labels does not move it.
- **Twenty-four bags at most** at one asking, so a slip of the thumb does not empty the roll. A larger
  order is asked twice, and the second set starts at "BAG 1" again.
- **No PIN.** Anybody signed in who can open the order can print its labels, like the bill and the pack
  sheet.
- An app that is not rebuilt has no button. A rebuilt app with a hub that is not updated has the button and
  says "This hub does not print bag labels yet: update it".
- Not tried on a real printer. On a Star printer each label is sent as a page of its own, because a Star
  cuts where a page ends; on an Epson a cut is sent after each.

## Not built

- Labels by themselves: when the order is sent, when the takeout station's ticket prints, or when the order
  is marked ready. Nobody has counted the bags then.
- Keeping how many bags an order had: on the pickup board, on the driver's run, on the bill.
- A dish, a drink or "sauce inside" on a label, or a label for each dish or each container.
- Sticky labels from a label printer. These are slips on receipt paper.
- Printing them at a printer picked on the spot. The hub's call takes a printer; no screen asks for one.
- The button anywhere but on the order's own screen: not in the list of checks, not on Orders ahead.
- Labels for a table's leftovers packed to go.
- A larger or smaller label, a logo, or the location's name on it.

## For developers

- The paper: `backend/src/pos/printing/labels.py`. `BagLabels` is data like a `Ticket`; `render_labels`
  makes the bytes for a printer's language, each label a document of its own inside the one job (a Star
  printer cuts only where a raster page ends, `star.py`). `BAGS_MOST` is 24.
- The service: `PrintService.bag_labels(state, bags)` makes the paper from an order (None for a table's
  order or one with no dish) and `print_labels` queues it at `pack_printer(asked)`: the printer asked for,
  else the takeout station's, else where bills print.
- The call: `POST /orders/{order_id}/bag-labels` `{bags, printer}` in `backend/src/pos/api/prep.py`. 202
  `{job_id, bags, printed_at}`. 404 for no such order; 409 `not_to_go`, `nothing_on_order`, `no_printer`;
  422 when `bags` is not a whole number from 1 to 24. No token, like the pack sheet. It writes nothing.
- App: `PosApi.printBagLabels` and `PosApi.bagsMost` (`lib/api.dart`); `BagLabelsDialog`
  (`lib/screens/bag_labels_dialog.dart`, keys `bag-labels-dialog`, `bags:<n>`, `bags-more`, `bags-cancel`);
  `_printLabels`, `_LabelsButton` (key `bag-labels`) and `_TotalFoot` in `lib/screens/order_screen.dart`.
  The foot's buttons are a `Wrap` where they take the row above the total, so three buttons too wide for a
  narrow check in large type take two rows.
- Tests: `backend/tests/printing/test_labels.py`, `apps/pos_app/test/bag_labels_test.dart`; the tests' hub
  answers the call (`bagLabels`, `refuseLabels` in `test/hub.dart`).
