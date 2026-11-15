import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/adjustments_screen.dart';
import 'package:pos_app/voids.dart';

import 'hub.dart';

/// Dishes taken off before sending (the Toast comparison, 2026-11-15): an unsent dish still comes off the
/// check with nothing asked, and the manager's report lists every one of them: by who took it off, by check,
/// and one by one, the dish that was longest on its check first. (That the order screen names who takes a
/// dish off is in voids_test.dart and keyboard_test.dart.)

const minute = 60000;
final noon = DateTime(2026, 11, 15, 12);

Map<String, dynamic> tookOff(
  String item, {
  int qty = 1,
  String amount = '10.00',
  String? table,
  int? orderNo,
  String by = '',
  String rungBy = 'Amy',
  required int at,
  required int onCheck,
}) => {
  'order_id': table ?? 'o$orderNo',
  'table': table,
  'order_no': orderNo,
  'customer_name': null,
  'line_id': 'L$at',
  'item': item,
  'qty': qty,
  'amount': amount,
  'by': by,
  'by_id': null,
  'rung_by': rungBy,
  'device': 't1',
  'at_ms': noon.millisecondsSinceEpoch + at * minute,
  'on_check_ms': onCheck,
  'status': 'open',
};

/// The report of a hub that lists them: three rows on two checks.
Map<String, dynamic> report() => {
  'voids': <Map<String, dynamic>>[],
  'void_total': '0.00',
  'taken_off': [
    tookOff('Spring roll', table: '12', by: 'Amy', at: 1, onCheck: 8000), // a slip of the finger
    tookOff('Hot tea', qty: 2, amount: '5.00', table: '12', by: 'Amy', at: 5, onCheck: 47 * minute),
    tookOff('Peking Duck', amount: '48.00', orderNo: 7, at: 9, onCheck: 65 * minute), // an app that said no name
  ],
  'taken_off_total': '63.00',
  'taken_off_count': 3,
  'taken_off_by_staff': [
    {'key': '', 'amount': '48.00', 'count': 1},
    {'key': 'Amy', 'amount': '15.00', 'count': 2},
  ],
  'taken_off_by_check': [
    {'order_id': 'o7', 'table': null, 'order_no': 7, 'customer_name': 'Linda', 'amount': '48.00', 'count': 1},
    {'order_id': '12', 'table': '12', 'order_no': null, 'customer_name': null, 'amount': '15.00', 'count': 2},
  ],
  'discounts': <Map<String, dynamic>>[],
  'discount_total': '0.00',
};

Future<Terminal> pumpReport(WidgetTester tester, Map<String, dynamic> answer, {Size? size}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.hub.report = answer;
  await tester.pumpWidget(
    MaterialApp(
      home: AdjustmentsScreen(api: t.api, now: () => noon.add(const Duration(hours: 3))),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The words under a row of the list, by its place in it.
String wordsOf(WidgetTester tester, int row) =>
    (tester.widget<ListTile>(find.byKey(ValueKey('taken-off-row:$row'))).subtitle! as Text).data!;

String dishOf(WidgetTester tester, int row) =>
    (tester.widget<ListTile>(find.byKey(ValueKey('taken-off-row:$row'))).title! as Text).data!;

void main() {
  test('the report reads who took a dish off, how long it was on the check, and puts the longest first', () {
    final read = AdjustmentsReport.fromJson(report());
    expect((read.hasTakenOff, read.takenOffTotal, read.takenOff.length, read.takenOffDishes), (true, '63.00', 3, 4));
    expect(read.takenOffLongestFirst.map((row) => row.item), ['Peking Duck', 'Hot tea', 'Spring roll']);
    expect(read.takenOff.map((row) => row.onCheck), [
      'under a minute on the check',
      '47 min on the check',
      '1 h 5 min on the check',
    ]);
    // who took it off; from an app that did not say, at least who rang it in
    expect(read.takenOff.map((row) => row.who), ['by Amy', 'by Amy', 'rung in by Amy']);
    expect(read.takenOff.map((row) => row.where), ['Table 12', 'Table 12', '#7']);
    expect(read.takenOffByCheck.map((total) => (total.key, total.amount, total.count)), [
      ('#7 Linda', '48.00', 1),
      ('Table 12', '15.00', 2),
    ]);

    final older = AdjustmentsReport.fromJson({'voids': <Map<String, dynamic>>[]});
    expect((older.hasTakenOff, older.takenOff.length, older.takenOffTotal), (false, 0, '0.00'));
  });

  testWidgets('the report lists what was taken off before sending, by person, by check and one by one', (tester) async {
    await pumpReport(tester, report());
    final section = find.text('Taken off before sending');
    await tester.ensureVisible(section);
    await tester.pumpAndSettle();
    expect(find.text('\$63.00'), findsOneWidget);
    expect(find.text('4 dishes'), findsOneWidget);
    expect(find.text('By who took it off'), findsOneWidget);
    expect(find.text('Not recorded'), findsOneWidget);
    expect(find.text('By check'), findsOneWidget);
    expect(find.text('Table 12'), findsOneWidget);
    expect(find.text('#7 Linda'), findsOneWidget);

    // one by one, the dish that sat longest on its check first; the slip of the finger last
    await tester.ensureVisible(find.byKey(const ValueKey('taken-off-row:2')));
    await tester.pumpAndSettle();
    expect([for (var i = 0; i < 3; i++) dishOf(tester, i)], ['1 × Peking Duck', '2 × Hot tea', '1 × Spring roll']);
    expect(wordsOf(tester, 0), '12:09 PM · #7 · rung in by Amy · 1 h 5 min on the check');
    expect(wordsOf(tester, 1), '12:05 PM · Table 12 · by Amy · 47 min on the check');
    expect(wordsOf(tester, 2), '12:01 PM · Table 12 · by Amy · under a minute on the check');
    expect(find.text('\$48.00'), findsNWidgets(3)); // under its person, under its check and on its row
    await stop(tester);
  });

  testWidgets('with nothing taken off the report says so, and it reads the same on a phone', (tester) async {
    await pumpReport(tester, {
      ...report(),
      'taken_off': <Map<String, dynamic>>[],
      'taken_off_total': '0.00',
      'taken_off_by_staff': <Map<String, dynamic>>[],
      'taken_off_by_check': <Map<String, dynamic>>[],
    });
    expect(find.text('No dish was taken off a check before it was sent.'), findsOneWidget);
    expect(find.text('0 dishes'), findsNWidgets(2)); // no voids either
    await stop(tester);

    await pumpReport(tester, report(), size: const Size(320, 640));
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('taken-off-row:0')), 120, scrollable: list);
    expect(wordsOf(tester, 0), '12:09 PM · #7 · rung in by Amy · 1 h 5 min on the check');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('taken-off-row:2')), 120, scrollable: list);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  testWidgets('a hub older than the list says to update it, and the rest of the report is there', (tester) async {
    final older = report()..removeWhere((key, _) => key.startsWith('taken_off'));
    await pumpReport(tester, older);
    expect(find.text('Taken off before sending'), findsOneWidget);
    expect(find.text('This hub is older than this list. Update the hub to see it here.'), findsOneWidget);
    expect(find.text('No dish was voided after it went to the kitchen.'), findsOneWidget);
    await stop(tester);
  });
}
