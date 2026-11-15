import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/to_go_stages.dart';

import 'counter_test.dart';
import 'hub.dart' show table;
import 'quote_times_test.dart' show inMinutes, quoted;

/// To-go orders by stage (the Toast comparison, 2026-11-15): one row of chips above the list of checks,
/// Later, Cooking, Ready and Unpaid, each with its count; a chip narrows the list to its orders, due first.

/// What the counter has on a busy evening: two orders waiting for their time (one sent ahead), two with the
/// kitchen, one on the shelf, one still being rung up, and a table.
List<Map<String, dynamic>> evening() => [
  quoted('o1', no: 1, name: 'Rosa', channel: 'phone', quote: 20, at: inMinutes(180), forLater: true),
  quoted('o2', no: 2, name: 'Wei', channel: 'phone', quote: 20, at: inMinutes(90), forLater: true, fired: true),
  quoted('o3', no: 3, name: 'Dmitri', quote: 15, at: inMinutes(12), fired: true, payments: cash),
  quoted('o4', no: 4, name: 'Linda', channel: 'phone', quote: 20, at: inMinutes(5), forLater: true, fired: true),
  quoted('o5', no: 5, name: 'Sam', channel: 'phone', quote: 20, at: inMinutes(-2), fired: true, stage: 'ready'),
  quoted('o6', no: 6, name: 'Ana', quote: 15, at: inMinutes(15)),
  table('t1', const {}),
];

void main() {
  test('an order is Later until its ticket prints, then Cooking, then Ready; Unpaid cuts across', () {
    final now = DateTime.now();
    final orders = {for (final json in evening()) json['order_id'] as String: Order.fromJson(json)};
    Set<String> under(ToGoChip chip) => {
      for (final order in orders.values)
        if (inChip(chip, order, now)) order.orderId,
    };
    expect(under(ToGoChip.later), {'o1', 'o2'}); // not sent, and sent ahead of its time
    expect(under(ToGoChip.cooking), {'o3', 'o4'}); // sent for now, and sent with its time to start come
    expect(under(ToGoChip.ready), {'o5'});
    expect(under(ToGoChip.unpaid), {'o1', 'o2', 'o4', 'o5', 'o6'}); // whatever the stage; never the table
    expect(chipCounts(orders.values, now), {
      ToGoChip.later: 2,
      ToGoChip.cooking: 2,
      ToGoChip.ready: 1,
      ToGoChip.unpaid: 5,
    });

    // The same order at three moments: 90 minutes out, a minute before its ticket prints, and after.
    final wei = orders['o2']!;
    final start = DateTime.fromMillisecondsSinceEpoch(wei.promisedAt!).subtract(const Duration(minutes: 20));
    expect(waitsForItsTime(wei, start.subtract(const Duration(minutes: 1))), isTrue);
    expect(waitsForItsTime(wei, start), isFalse);
    expect(inChip(ToGoChip.cooking, wei, start), isTrue);
    // One nobody sent stays Later past its start: it is the list's red mark, not the kitchen's work.
    expect(waitsForItsTime(orders['o1']!, now.add(const Duration(hours: 5))), isTrue);
    // One for now is never Later, sent or not.
    expect(waitsForItsTime(orders['o6']!, now), isFalse);

    // A closed order is under no chip.
    final closed = Order.fromJson({...evening()[4], 'status': 'closed'});
    expect(ToGoChip.values.any((chip) => inChip(chip, closed, now)), isFalse);
  });

  test('a chip lists the order due first at the top, and keeps the list\'s order within a minute', () {
    final rows = [
      for (final (id, at) in [('a', 30), ('b', 10), ('c', 30), ('d', 20)])
        Order.fromJson(quoted(id, at: DateTime(2026, 11, 15, 18, at).millisecondsSinceEpoch)),
    ];
    expect(dueFirst(rows, (order) => order).map((order) => order.orderId), ['b', 'd', 'a', 'c']);
    final untimed = Order.fromJson(table('t1', const {}));
    expect(dueFirst([untimed, ...rows], (order) => order).last.orderId, 't1');
  });

  testWidgets('the row counts the to-go orders by stage; a chip lists only its orders, due first', (tester) async {
    await pumpOrders(tester, evening());
    String said(ToGoChip chip) => tester
        .widget<Text>(find.descendant(of: find.byKey(ValueKey('chip:${chip.name}')), matching: find.byType(Text)))
        .textSpan!
        .toPlainText();
    expect([for (final chip in ToGoChip.values) said(chip)], ['Later 2', 'Cooking 2', 'Ready 1', 'Unpaid 5']);
    expect(find.text('Table A1'), findsOneWidget); // no chip picked: every check

    await tester.tap(find.byKey(const ValueKey('chip:cooking')));
    await tester.pumpAndSettle();
    expect(find.text('Linda · phone'), findsOneWidget);
    expect(find.text('Dmitri · counter'), findsOneWidget);
    for (final gone in ['Rosa · phone', 'Wei · phone', 'Sam · phone', 'Ana · counter', 'Table A1']) {
      expect(find.text(gone), findsNothing);
    }
    // Linda's is for five minutes from now, Dmitri's for twelve: hers is on top, whatever their numbers.
    expect(
      tester.getTopLeft(find.text('Linda · phone')).dy,
      lessThan(tester.getTopLeft(find.text('Dmitri · counter')).dy),
    );

    await tester.tap(find.byKey(const ValueKey('chip:ready')));
    await tester.pumpAndSettle();
    expect(find.text('Sam · phone'), findsOneWidget);
    expect(find.byKey(const ValueKey('picked-up-o5')), findsOneWidget);
    expect(find.text('Linda · phone'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chip:unpaid')));
    await tester.pumpAndSettle();
    expect(find.text('Dmitri · counter'), findsNothing); // paid at the counter
    expect(find.text('Ana · counter'), findsOneWidget); // still being rung up

    await tester.tap(find.byKey(const ValueKey('chip:unpaid'))); // the picked chip again: every check is back
    await tester.pumpAndSettle();
    expect(find.text('Dmitri · counter'), findsOneWidget);
    expect(find.text('Table A1'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('an order sent ahead for later has no Ready button until its ticket prints', (tester) async {
    await pumpOrders(tester, evening());
    expect(find.byKey(const ValueKey('ready-o2')), findsNothing); // Wei's, for ninety minutes from now
    expect(find.byKey(const ValueKey('ready-o3')), findsOneWidget); // sent for now
    expect(find.byKey(const ValueKey('ready-o4')), findsOneWidget); // for later, and its time to start has come
    await stop(tester);
  });

  testWidgets('a chip with nothing in it says so; with no to-go order there is no row', (tester) async {
    await pumpOrders(tester, [evening().first]);
    await tester.tap(find.byKey(const ValueKey('chip:ready')));
    await tester.pumpAndSettle();
    expect(find.text('No to-go orders are ready.'), findsOneWidget);
    expect(find.byKey(const ValueKey('to-go-chips')), findsOneWidget); // the way back
    await stop(tester);

    await pumpOrders(tester, [table('t1', const {})]);
    expect(find.text('Table A1'), findsOneWidget);
    expect(find.byKey(const ValueKey('to-go-chips')), findsNothing);
    await stop(tester);

    await pumpOrders(tester, evening(), showList: false); // the floor map: the row is the list's
    expect(find.byKey(const ValueKey('to-go-chips')), findsNothing);
    await stop(tester);
  });

  testWidgets('an order moves from Later to Cooking by itself when its ticket\'s time comes', (tester) async {
    // Quoted 20 and for 20 minutes and a second and a half from now: its ticket prints in a second and a half.
    final at = DateTime.now().add(const Duration(minutes: 20, milliseconds: 1500)).millisecondsSinceEpoch;
    await pumpOrders(tester, [quoted('o1', quote: 20, at: at, forLater: true, fired: true)]);
    String said(String chip) => tester
        .widget<Text>(find.descendant(of: find.byKey(ValueKey('chip:$chip')), matching: find.byType(Text)))
        .textSpan!
        .toPlainText();
    expect((said('later'), said('cooking')), ('Later 1', 'Cooking 0'));
    expect(find.byKey(const ValueKey('ready-o1')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1700)));
    await tester.pump(const Duration(seconds: 4));
    expect((said('later'), said('cooking')), ('Later 0', 'Cooking 1'));
    expect(find.byKey(const ValueKey('ready-o1')), findsOneWidget);
    await stop(tester);
  });
}
