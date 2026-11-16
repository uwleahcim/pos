import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/day_report.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/sales_report.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/tax_exempt_dialog.dart';
import 'package:pos_app/session.dart';

import 'hub.dart';

/// A check a manager marks exempt from sales tax (docs/tax-exempt.md). The hub decides everything: who may,
/// on which check, and what the check then comes to. These tests are about the screen asking for the
/// organisation, its certificate and the manager's PIN, sending them as the hub wants them, showing a check
/// that pays no tax for what it is, and putting the tax back.

const pta = {'organisation': 'Winchester PTA', 'certificate': 'E-123-456-789'};

/// Wings and two egg rolls at table A1, as the hub prices them: 15.95, 1.12 of tax.
Map<String, dynamic> supper({bool exempts = true}) => {
  'lines': [
    {'line_id': 'L1', 'name': 'Chicken wings', 'qty': 1, 'total': '8.95'},
    {'line_id': 'L2', 'name': 'Egg roll', 'qty': 2, 'total': '7.00'},
  ],
  'subtotal': '15.95',
  'tax_rate_pct': '7.00',
  'tax_lines': [
    {'name': 'MA meals tax', 'rate_pct': '6.25', 'base': '15.95', 'amount': '1.00'},
    {'name': 'Winchester local option', 'rate_pct': '0.75', 'base': '15.95', 'amount': '0.12'},
  ],
  'tax': '1.12',
  'total': '17.07',
  'exempts': ?(exempts ? true : null),
};

/// The same check once Mike marked it for the PTA.
Map<String, dynamic> marked() => {
  ...supper(),
  'tax_lines': [
    {'name': 'MA meals tax', 'rate_pct': '6.25', 'base': '0.00', 'amount': '0.00'},
    {'name': 'Winchester local option', 'rate_pct': '0.75', 'base': '0.00', 'amount': '0.00'},
  ],
  'tax': '0.00',
  'total': '15.95',
  'tax_exempt': {...pta, 'approved_by': 'Mike', 'approved_by_id': 's3', 'by': 'Amy', 'at_ms': 1, 'tax': '1.12'},
};

class SnapCamera extends EventCamera {
  @override
  bool get ready => true;
  @override
  String? get error => null;
  @override
  Widget preview() => const SizedBox();
  @override
  Future<Uint8List?> snap() async => Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
}

/// Amy at table A1's check, on a pretend hub that serves [check] and approves PIN 9999.
Future<Terminal> pumpCheck(
  WidgetTester tester, {
  Map<String, dynamic>? check,
  Size size = const Size(1100, 800),
  String status = 'open',
  Map<String, dynamic> more = const {},
  PhotoQueue Function(Terminal t)? photos,
}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.check = check ?? supper();
  t.hub.rules = {'discounts': <Object>[], 'charges': <Object>[]};
  t.hub.orders.add({
    ...table('o1', {'L1': line('Chicken wings', fired: true), 'L2': line('Egg roll', fired: true)..['qty'] = 2}),
    'status': status,
    ...more,
  });
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(
        api: t.api,
        outbox: t.outbox,
        photos: photos?.call(t) ?? t.photos,
        orderId: 'o1',
        session: t.session,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Discount, then "Tax exempt" on the sheet: the two things to type are asked next.
Future<void> askExempt(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Discount'));
  await tester.pumpAndSettle();
  await tapKey(tester, 'tax-exempt');
  expect(find.byType(TaxExemptDialog), findsOneWidget);
}

Future<void> typeWho(WidgetTester tester, {String? organisation, String? certificate}) async {
  await tester.enterText(find.byKey(const ValueKey('exempt-organisation')), organisation ?? pta['organisation']!);
  await tester.enterText(find.byKey(const ValueKey('exempt-certificate')), certificate ?? pta['certificate']!);
  await tester.pumpAndSettle();
}

Future<void> enterPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const ValueKey('approval-pin')), pin);
  await tester.tap(find.byKey(const ValueKey('approve')));
  await tester.pumpAndSettle();
}

/// What went to the hub for the order: each operation's kind and what it said.
List<(String, Map<String, dynamic>)> sent(Hub hub) => [
  for (final (_, op) in hub.sent) (op['kind'] as String, (op['data'] as Map).cast<String, dynamic>()),
];

/// The texts of the row where the check's tax stands.
List<String> taxRow(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    text.data ?? '',
];

void main() {
  group('what the app reads', () {
    test('a check says whether it is tax exempt, for whom, and whether the hub can mark one', () {
      final plain = Check.fromJson(supper());
      expect((plain.exempt, plain.exempts, plain.tax), (null, true, '1.12'));
      expect(Check.fromJson(supper(exempts: false)).exempts, isFalse); // a hub older than this

      final exempt = Check.fromJson(marked());
      expect((exempt.tax, exempt.total), ('0.00', '15.95'));
      expect(
        (exempt.exempt!.organisation, exempt.exempt!.certificate, exempt.exempt!.approvedBy, exempt.exempt!.by),
        ('Winchester PTA', 'E-123-456-789', 'Mike', 'Amy'),
      );
      expect(exempt.exempt!.tax, '1.12'); // what it would have paid
      expect(exempt.taxLines.map((t) => t.ratePct), ['6.25', '0.75']); // the rates stay for the next check
    });

    test('a mark that names nobody is no exemption', () {
      expect(TaxExempt.of(null), isNull);
      expect(TaxExempt.of(true), isNull);
      expect(TaxExempt.of({'certificate': 'E-1'}), isNull);
      expect(TaxExempt.of({'organisation': ''}), isNull);
    });

    test('a dish added to a tax-exempt check is not taxed while the hub has yet to price it', () {
      final order = Order.fromJson({
        ...table('o1', {
          'L1': line('Chicken wings', fired: true),
          'L2': line('Egg roll', fired: true)..['qty'] = 2,
          'L3': line('Peking Duck'),
        }),
      });
      final local = {'L3': const LocalLine(unitPrice: '30.00')};
      final estimate = estimateCheck(Check.fromJson(marked()), order, local);
      expect((estimate.subtotal, estimate.tax, estimate.total), ('45.95', '0.00', '45.95'));
      expect(estimate.exempt!.organisation, 'Winchester PTA');
      // the same dish on the check that pays its tax
      final taxed = estimateCheck(Check.fromJson(supper()), order, local);
      expect((taxed.tax, taxed.exempt), ('3.21', null)); // 2.87 and 0.34: each rate rounds on its own
    });

    test('the reports say how many checks, what they came to and the tax not charged', () {
      final day = DayReport.fromJson({
        'day': '2026-11-16',
        'tax_exempt': {
          'count': 2,
          'sales': '115.95',
          'tax': '8.12',
          'checks': [
            {
              'order_id': 'o1',
              'table': '12',
              'total': '15.95',
              'due': '0.00',
              ...pta,
              'approved_by': 'Mike',
              'tax': '1.12',
            },
            {'order_id': 'o2', 'order_no': 7, 'order_type': 'takeout', 'total': '100.00', 'organisation': 'Town Hall'},
          ],
        },
      });
      expect((day.exempt.count, day.exempt.sales, day.exempt.tax), (2, '115.95', '8.12'));
      expect(day.exempt.words, r'Not charged on 2 tax-exempt checks: $8.12');
      final first = day.exempt.checks.first;
      expect(
        (first.organisation, first.certificate, first.approvedBy, first.tax),
        ('Winchester PTA', 'E-123-456-789', 'Mike', '1.12'),
      );
      expect((first.check.where, day.exempt.checks.last.check.where), ('Table 12', '#7'));
      expect(const TaxExempts(count: 1, tax: '1.12').words, r'Not charged on 1 tax-exempt check: $1.12');

      // a hub older than this says nothing, and the reports read as none
      expect(DayReport.fromJson({'day': '2026-11-16'}).exempt.count, 0);
      final span = SalesSpan.fromJson({
        'first': '2026-11-16',
        'last': '2026-11-16',
        'tax_exempt': {'count': 1, 'sales': '15.95', 'tax': '1.12'},
      });
      expect((span.exempt.count, span.exempt.sales, span.exempt.tax), (1, '15.95', '1.12'));
      expect(span.exempt.checks, isEmpty); // a span of days names no check
      expect(SalesSpan.fromJson({'first': '2026-11-16', 'last': '2026-11-16'}).exempt.count, 0);
    });
  });

  group('marking a check', () {
    testWidgets('the sheet offers it, asks who it is for and then the manager, and the hub gets all three', (
      tester,
    ) async {
      final t = await pumpCheck(tester);
      expect(taxRow(tester, 'tax-exempt-row'), isEmpty);
      expect(find.text('Sales tax 7%'), findsOneWidget);

      await askExempt(tester);
      expect(
        find.text('No sales tax is charged on this check. Both are kept with it and print on the bill.'),
        findsOneWidget,
      );
      // nothing goes on until both are typed
      FilledButton next() => tester.widget<FilledButton>(find.byKey(const ValueKey('exempt-next')));
      expect(next().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('exempt-organisation')), '  Winchester   PTA ');
      await tester.pumpAndSettle();
      expect(next().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('exempt-certificate')), '   ');
      await tester.pumpAndSettle();
      expect(next().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('exempt-certificate')), ' E-123-456-789 ');
      await tester.pumpAndSettle();
      expect(next().onPressed, isNotNull);
      await tapKey(tester, 'exempt-next');

      expect(find.text('Marking this check tax exempt needs a manager.'), findsOneWidget);
      await enterPin(tester, '1111'); // Amy's own PIN is no manager's
      expect(find.text('Only a manager can approve this'), findsOneWidget);
      expect(sent(t.hub), isEmpty);
      await enterPin(tester, '9999');

      expect(t.hub.pins, ['1111', '9999']);
      expect(t.hub.purposes, ['exempt', 'exempt']); // an approval for this and nothing else
      final (kind, data) = sent(t.hub).single;
      expect(kind, 'set_field');
      expect(data, {'tax_exempt': pta, 'approval': 'tok-o1', 'by': 'Amy', 'by_id': 's1'}); // tidied of spaces

      // the check now says for whom where its tax was, and owes none
      expect(taxRow(tester, 'tax-exempt-row'), ['Tax exempt · Winchester PTA', '0.00']);
      expect(find.text('Sales tax 7%'), findsNothing);
      expect(find.text('15.95'), findsWidgets);
      expect(find.text('17.07'), findsNothing);
    });

    testWidgets('a check already exempt is not offered it again, and a hub older than this never offers it', (
      tester,
    ) async {
      await pumpCheck(tester, check: marked());
      await tester.tap(find.widgetWithText(TextButton, 'Discount'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tax-exempt')), findsNothing);
      expect(find.text('Sales tax'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pumpCheck(tester, check: supper(exempts: false));
      await tester.tap(find.widgetWithText(TextButton, 'Discount'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tax-exempt')), findsNothing);
    });

    testWidgets('walking away from the form or from the PIN sends nothing', (tester) async {
      final t = await pumpCheck(tester);
      await askExempt(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TaxExemptDialog), findsNothing);

      await askExempt(tester);
      await typeWho(tester);
      await tapKey(tester, 'exempt-next');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(sent(t.hub), isEmpty);
      expect(find.text('Sales tax 7%'), findsOneWidget);
    });

    testWidgets('Enter in the certificate goes on to the manager; the name takes 60 letters, the number 40', (
      tester,
    ) async {
      await pumpCheck(tester);
      await askExempt(tester);
      await tester.enterText(find.byKey(const ValueKey('exempt-organisation')), 'x' * 80);
      await tester.enterText(find.byKey(const ValueKey('exempt-certificate')), '9' * 60);
      await tester.pumpAndSettle();
      TextField field(String key) => tester.widget<TextField>(find.byKey(ValueKey(key)));
      expect(field('exempt-organisation').controller!.text.length, TaxExempt.organisationMax);
      expect(field('exempt-certificate').controller!.text.length, TaxExempt.certificateMax);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Marking this check tax exempt needs a manager.'), findsOneWidget);
    });

    testWidgets('a check with money taken on it is told so before anything is asked', (tester) async {
      final t = await pumpCheck(
        tester,
        more: {
          'payments': {
            'P1': {'method': 'cash', 'amount': '5.00'},
          },
        },
      );
      await tester.tap(find.widgetWithText(TextButton, 'Discount'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'tax-exempt');
      expect(find.byType(TaxExemptDialog), findsNothing);
      expect(
        find.text('Money has been taken on this check. A check is marked tax exempt before it is paid.'),
        findsOneWidget,
      );
      expect(sent(t.hub), isEmpty);
      expect(t.hub.pins, isEmpty);
    });

    testWidgets('what the hub refuses is said in its words, and the tax stays', (tester) async {
      final t = await pumpCheck(tester);
      t.hub.refuseExempt = ('closed', 'This check is closed. Reopen it to change its tax.');
      await askExempt(tester);
      await typeWho(tester);
      await tapKey(tester, 'exempt-next');
      await enterPin(tester, '9999');
      expect(sent(t.hub).single.$1, 'set_field');
      expect(t.outbox.lastRefusal, 'This check is closed. Reopen it to change its tax.');
      expect(find.textContaining('This check is closed. Reopen it to change its tax.'), findsOneWidget);
      expect(find.text('Sales tax 7%'), findsOneWidget);
      expect(find.byKey(const ValueKey('tax-exempt-row')), findsNothing);
    });

    testWidgets('the manager is photographed with it, where the device takes audit photos', (tester) async {
      late PhotoQueue queue;
      final t = await pumpCheck(
        tester,
        photos: (t) => queue = PhotoQueue(t.api, t.settings, SnapCamera(), t.session, store: MemoryStore()),
      );
      await askExempt(tester);
      await typeWho(tester);
      await tapKey(tester, 'exempt-next');
      await enterPin(tester, '9999');
      expect(queue.taken, 1);
      expect(t.hub.photosPut.single['event'], 'tax_exempt');
      expect(t.hub.photosPut.single['op_id'], t.hub.sent.single.$2['op_id']);
    });
  });

  group('a tax-exempt check', () {
    testWidgets('a tap on its row asks before the tax goes back on, and anyone may', (tester) async {
      final t = await pumpCheck(tester, check: marked());
      expect(taxRow(tester, 'tax-exempt-row'), ['Tax exempt · Winchester PTA', '0.00']);

      await tapKey(tester, 'tax-exempt-row');
      expect(find.text('Charge sales tax again?'), findsOneWidget);
      expect(
        find.text(
          'This check is tax exempt for Winchester PTA. Taking that off puts the sales tax back on it. '
          'Marking it exempt again needs a manager.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep it exempt'));
      await tester.pumpAndSettle();
      expect(sent(t.hub), isEmpty);

      await tapKey(tester, 'tax-exempt-row');
      await tapKey(tester, 'exempt-remove');
      final (kind, data) = sent(t.hub).single;
      expect(kind, 'set_field');
      expect(data, {'tax_exempt': null, 'by': 'Amy', 'by_id': 's1'});
      expect(t.hub.pins, isEmpty); // no manager: it only ever adds tax
      expect(find.byKey(const ValueKey('tax-exempt-row')), findsNothing);
      expect(find.text('Sales tax 7%'), findsOneWidget);
      expect(find.text('17.07'), findsWidgets);
    });

    testWidgets('once closed it reads the same and nothing takes the mark off', (tester) async {
      final t = await pumpCheck(tester, check: marked(), status: 'closed');
      expect(taxRow(tester, 'tax-exempt-row'), ['Tax exempt · Winchester PTA', '0.00']);
      expect(
        find.descendant(of: find.byKey(const ValueKey('tax-exempt-row')), matching: find.byIcon(Icons.close)),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('tax-exempt-row')));
      await tester.pumpAndSettle();
      expect(find.text('Charge sales tax again?'), findsNothing);
      expect(sent(t.hub), isEmpty);
    });

    testWidgets('on a small phone the form, the PIN and a long name all fit', (tester) async {
      final long = {
        ...marked(),
        'tax_exempt': {
          ...marked()['tax_exempt'] as Map<String, dynamic>,
          'organisation': 'The Winchester Association of Parents, Teachers and Friends of Music',
        },
      };
      await pumpCheck(tester, check: long, size: const Size(320, 568));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      final t = await pumpCheck(tester, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Discount')); // the icon alone on a phone
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'tax-exempt');
      expect(tester.takeException(), isNull);
      await typeWho(tester, organisation: 'x' * 60, certificate: '9' * 40);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'exempt-next');
      await enterPin(tester, '9999');
      expect(tester.takeException(), isNull);
      expect(sent(t.hub).single.$1, 'set_field');
    });
  });
}
