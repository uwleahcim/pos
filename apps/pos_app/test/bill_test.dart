import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/bill_dialog.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'hub.dart';
import 'lot_test.dart' show check;
import 'ticket_words_test.dart' show show;

/// The guest's bill (the Toast comparison's build list, row 1): a Bill button beside the total on every
/// check prints the check as the hub reckons it. It comes out of the printer the screen keeps for its bills
/// (a hold on the button picks it), else where the location's bills print; a manager sets that and the lines
/// at the top and the foot of the bill under Location settings, on the printers' card.

final button = find.byKey(const ValueKey('bill'));

/// Lets the message at the foot of the screen go, so the next tap reaches the check under it.
Future<void> said(WidgetTester tester) async {
  ScaffoldMessenger.of(tester.element(button)).clearSnackBars();
  await tester.pumpAndSettle();
}

Future<Terminal> pumpOrder(WidgetTester tester, {Size? size, bool empty = false}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  if (!empty) t.hub.check = check;
  t.hub.orders.add(
    table(
      'o1',
      empty
          ? {}
          : {
              'L1': line('Egg roll', rank: 1),
              'L2': line('Peking Duck', fired: true, rank: 2),
              'L3': line('Hot tea', fired: true, rank: 3),
              'L4': line('Fried rice', rank: 4),
            },
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> pumpSettings(WidgetTester tester, Terminal t) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
    ),
  );
  await tester.pumpAndSettle();
  await show(tester, find.byKey(const ValueKey('bill')));
}

void main() {
  test('the setting names the printers and tells a printer that is gone from one that is there', () {
    final bill = BillSettings.fromJson(const {
      'printer': 'p9',
      'header': ['China Sky', '', 'Winchester'],
      'footer': ['Thank you!'],
      'printers': [
        {'id': 'p1', 'name': 'Takeout'},
        {'id': 'p2', 'name': 'Bar'},
      ],
      'prints_at': 'p1',
      'usual': 'p1',
    });
    expect(bill.header, ['China Sky', '', 'Winchester']);
    expect((bill.nameOf('p2'), bill.nameOf('p9'), bill.nameOf(null)), ('Bar', null, null));
    expect(bill.chosen, isNull); // the location's choice is no longer a printer: the usual one it is
    expect(BillSettings.fromJson(const {}).printers, isEmpty);
  });

  test('the lines typed are the lines kept: gaps inside stay, the ones at either end go', () {
    expect(billLines('\n China Sky \n\n1 Main Street\n\n'), ['China Sky', '', '1 Main Street']);
    expect(billLines('   '), isEmpty);
  });

  testWidgets('the Bill button beside the total prints the check where the location prints bills', (tester) async {
    final t = await pumpOrder(tester);
    expect(button, findsOneWidget);
    // beside the total, on its row: the check is no taller for it than the button itself
    final total = tester.getRect(find.text('Total'));
    final bill = tester.getRect(button);
    expect(bill.center.dy, closeTo(total.center.dy, 1));
    expect(bill.left, greaterThan(total.right));

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(t.hub.bills, [('o1', null)]);
    expect(find.text('The bill is printing at Takeout'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('what was just rung in reaches the hub before the bill prints', (tester) async {
    final t = await pumpOrder(tester);
    await t.outbox.add('o1', 'set_field', {'guests': 3});
    await tester.tap(button);
    await tester.pumpAndSettle();
    final sent = t.hub.requests.where((r) => r.startsWith('POST /orders/o1/')).toList();
    expect(sent.indexOf('POST /orders/o1/ops'), lessThan(sent.indexOf('POST /orders/o1/bill')));
    await stop(tester);
  });

  testWidgets('a hold on the button prints the bill at another printer, which the screen then keeps', (tester) async {
    final t = await pumpOrder(tester);
    await tester.longPress(button);
    await tester.pumpAndSettle();
    expect(find.text('Print this bill at'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('bill-at:'))).selected, isTrue);
    expect(find.text("The location's: Takeout"), findsOneWidget);
    expect(t.hub.bills, isEmpty); // nothing prints until a printer is picked

    await tester.tap(find.byKey(const ValueKey('bill-at:p2')));
    await tester.pumpAndSettle();
    expect(t.settings.billPrinter, 'p2');
    expect(t.hub.bills, [('o1', 'p2')]);
    expect(find.text("The bill is printing at Bar. This screen's bills print there from now on"), findsOneWidget);
    await said(tester);

    // the next bill from this screen: a tap, and it is the bar's again
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(t.hub.bills, [('o1', 'p2'), ('o1', 'p2')]);
    expect(find.text('The bill is printing at Bar'), findsOneWidget);
    await said(tester);

    // and back to the location's
    await tester.longPress(button);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('bill-at:p2'))).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('bill-at:')));
    await tester.pumpAndSettle();
    expect(t.settings.billPrinter, '');
    expect(t.hub.bills.last, ('o1', null));
    expect(
      find.text("The bill is printing at Takeout. This screen's bills print where the location's do again"),
      findsOneWidget,
    );

    // closed without a pick: nothing prints, nothing changes
    await said(tester);
    await tester.longPress(button);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(t.hub.bills.length, 3);
    await stop(tester);
  });

  testWidgets('a screen whose own printer is gone prints where the location does', (tester) async {
    final t = await pumpOrder(tester);
    await t.settings.saveBillPrinter('p9');
    await tester.longPress(button);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('bill-at:'))).selected, isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(t.hub.bills, [('o1', 'p9')]); // the hub passes a printer it does not know over
    expect(find.text('The bill is printing at Takeout'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('what the hub cannot print is said in its words, and the button comes back', (tester) async {
    final t = await pumpOrder(tester);
    t.hub.refuseBill = 'No printer is set up for this location.';
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('No printer is set up for this location.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);

    // a hub older than the bill
    t.hub
      ..refuseBill = null
      ..bill = null;
    await said(tester);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('This hub does not print bills yet: update it'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('an empty check has no bill to print', (tester) async {
    await pumpOrder(tester, empty: true);
    expect(find.text('Nothing ordered yet.'), findsOneWidget);
    expect(button, findsNothing);
    await stop(tester);
  });

  testWidgets('the button fits beside the total on a phone', (tester) async {
    await pumpOrder(tester, size: const Size(390, 844));
    await tester.tap(find.textContaining('Check'));
    await tester.pumpAndSettle();
    expect(button, findsOneWidget);
    final bill = tester.getRect(button);
    expect(bill.left, greaterThan(tester.getRect(find.text('Total')).right));
    expect(bill.right, lessThan(tester.getRect(find.text('15.52').last).left));
    expect(bill.height, greaterThanOrEqualTo(36));
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  testWidgets('a manager sets where bills print and what heads them, after reading a sample', (tester) async {
    final t = await terminal(tester);
    await pumpSettings(tester, t);
    expect(find.text('Prints at Takeout · no heading yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bill')));
    await tester.pumpAndSettle();
    expect(find.text('The bill'), findsWidgets);
    expect(find.text('Takeout (usual)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('bill-header')), 'China Sky\n1 Main Street\n\n(781) 555-0100\n');
    await tester.enterText(find.byKey(const ValueKey('bill-footer')), 'See you soon');

    // the sample prints what is typed, and saves nothing
    await tester.tap(find.byKey(const ValueKey('bill-sample')));
    await tester.pumpAndSettle();
    expect(t.hub.billSamples.single, {
      'printer': null,
      'header': ['China Sky', '1 Main Street', '', '(781) 555-0100'],
      'footer': ['See you soon'],
    });
    expect(find.text('A sample is printing at Takeout. Nothing is saved yet.'), findsOneWidget);
    expect(t.hub.bill!['header'], isEmpty);

    // the bar's printer for the bills
    await tester.tap(find.byKey(const ValueKey('bill-printer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bar').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bill-save')));
    await tester.pumpAndSettle();
    expect(t.hub.billAuth, 'Bearer tok-admin');
    expect(t.hub.bill!['printer'], 'p2');
    expect(t.hub.bill!['header'], ['China Sky', '1 Main Street', '', '(781) 555-0100']);
    expect(t.hub.bill!['footer'], ['See you soon']);
    expect(find.text('Prints at Bar · headed "China Sky"'), findsOneWidget);
    expect(find.text('The bill is saved'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a line too long or too many of them is said before anything is sent', (tester) async {
    final t = await terminal(tester);
    await pumpSettings(tester, t);
    await tester.tap(find.byKey(const ValueKey('bill')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bill-header')), 'x' * (maxBillLine + 1));
    await tester.tap(find.byKey(const ValueKey('bill-save')));
    await tester.pumpAndSettle();
    expect(find.text('A line at the top of the bill is at most $maxBillLine characters'), findsOneWidget);
    expect(t.hub.billAuth, isNull);

    await tester.enterText(find.byKey(const ValueKey('bill-header')), 'China Sky');
    await tester.enterText(find.byKey(const ValueKey('bill-footer')), List.filled(maxBillLines + 1, 'x').join('\n'));
    await tester.tap(find.byKey(const ValueKey('bill-sample')));
    await tester.pumpAndSettle();
    expect(find.text('The foot of the bill takes at most $maxBillLines lines'), findsOneWidget);
    expect(t.hub.billSamples, isEmpty);

    // what the hub refuses is said in its words
    await tester.enterText(find.byKey(const ValueKey('bill-footer')), 'Thank you!');
    t.hub.refuseBill = "the bill's printer is a printer's id";
    await tester.tap(find.byKey(const ValueKey('bill-save')));
    await tester.pumpAndSettle();
    expect(find.text("the bill's printer is a printer's id"), findsOneWidget);
    expect(find.byType(BillDialog), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hub older than the bill shows no row for it', (tester) async {
    final t = await terminal(tester);
    t.hub.bill = null;
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('printers')));
    expect(find.byKey(const ValueKey('bill')), findsNothing);
    await stop(tester);
  });

  testWidgets('the bill dialog fits a phone', (tester) async {
    final t = await terminal(tester);
    tester.view.physicalSize = const Size(390, 844);
    await pumpSettings(tester, t);
    await tester.tap(find.byKey(const ValueKey('bill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bill-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('bill-save')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });
}
