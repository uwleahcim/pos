import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_search.dart';

import 'counter_test.dart';
import 'hub.dart' show table;
import 'quote_times_test.dart' show inMinutes, quoted;

/// Finding any check (the Toast comparison, 2026-11-15): a search box on the list of checks finds a check
/// by name, phone, table, order number or server, among the open ones and the closed ones of the last
/// day; a manager can look through another day's.

/// A check as a list gives it: when it was opened, and whatever else the test says of it.
Map<String, dynamic> check(
  Map<String, dynamic> order, {
  String status = 'open',
  String? server,
  String? phone,
  String? tableName,
  int? openedMs,
}) => {
  ...order,
  'status': status,
  'fields': <String, dynamic>{
    ...order['fields'] as Map<String, dynamic>,
    'server': ?server,
    'phone': ?phone,
    'table': ?tableName,
  },
  'opened_ms': openedMs ?? inMinutes(-30),
};

List<Map<String, dynamic>> open() => [
  check(
    quoted('o1', no: 41, name: 'Linda Chen', channel: 'phone'),
    phone: '(781) 555-1234',
    server: 'Amy',
  ),
  check(
    quoted('o2', no: 42, name: 'Wei', channel: 'counter'),
    server: 'Ben',
  ),
  check(table('t1', const {}), server: 'Amy', tableName: 'A1'),
  check(table('t2', const {}), server: 'Ben', tableName: 'B12'),
];

List<Map<String, dynamic>> closed() => [
  check(
    quoted('c1', no: 7, name: 'Linda Park', channel: 'phone', fired: true, payments: cash),
    status: 'closed',
    phone: '617 555 0100',
    server: 'Amy',
    openedMs: inMinutes(-300),
  ),
  check(table('c2', const {}), status: 'closed', server: 'Mike', tableName: 'C3', openedMs: inMinutes(-200)),
];

void main() {
  test('a check is found by its name, phone, table, order number or server, whatever the order of the words', () {
    final orders = {
      for (final json in [...open(), ...closed()]) json['order_id'] as String: Order.fromJson(json),
    };
    Set<String> found(String words) => {
      for (final order in orders.values)
        if (checkMatches(order, words)) order.orderId,
    };
    expect(found(''), orders.keys.toSet());
    expect(found('   '), orders.keys.toSet());
    expect(found('linda'), {'o1', 'c1'});
    expect(found('LINDA chen'), {'o1'});
    expect(found('chen linda'), {'o1'}); // every word, in any order
    expect(found('amy'), {'o1', 't1', 'c1'}); // the server's name
    expect(found('amy linda'), {'o1', 'c1'});
    expect(found('a1'), {'t1'});
    expect(found('table'), {'t1', 't2', 'c2'}); // any check at a table
    expect(found('table b'), {'t2'});
    expect(found('42'), {'o2'}); // the order number from its start
    expect(found('4'), {'o1', 'o2'});
    expect(found('#4'), {'o1', 'o2'});
    expect(found('#7'), {'c1'});
    expect(found('#'), <String>{});
    expect(found('12'), {'t2'}); // table B12; two digits are too few for a phone number
    expect(found('555'), {'o1', 'c1'}); // three digits or more: anywhere in the phone number
    expect(found('781-555-1234'), {'o1'}); // however it was punctuated
    expect(found('(781) 555 1234'), {'o1'});
    expect(found('5551234'), {'o1'});
    expect(found('zebra'), <String>{});
    expect(found('linda zebra'), <String>{});
    expect(Order.fromJson(open().first).openedMs, isNotNull);
    expect(Order.fromJson(quoted('o9')).openedMs, isNull); // a hub from before the search says no time
  });

  testWidgets('the search box finds open and closed checks as the words are typed, and Escape closes it', (
    tester,
  ) async {
    final past = closed(); // read once: its times are counted from now, and the minute may turn during the test
    final t = await pumpOrders(tester, open(), role: 'server', before: (hub) async => hub.past.addAll(past));
    expect(find.text('Linda Park · phone'), findsNothing); // closed: not on the list of open checks
    expect(t.hub.listsAsked.last['status'], 'open');

    await tester.tap(find.byKey(const ValueKey('find-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('to-go-chips')), findsNothing); // the box has the chips' row
    expect((t.hub.listsAsked.last['status'], t.hub.listsAsked.last['hours']), (null, '24.0'));
    expect(find.text('Linda Park · phone'), findsOneWidget); // nothing typed yet: every check of the day
    expect(find.byKey(const ValueKey('find-day')), findsNothing); // a server gets no calendar

    await tester.enterText(find.byKey(const ValueKey('find-check')), 'linda');
    await tester.pumpAndSettle();
    expect(find.text('Linda Chen · phone'), findsOneWidget);
    expect(find.text('Linda Park · phone'), findsOneWidget);
    expect(find.text('Wei · counter'), findsNothing);
    expect(find.text('Table A1'), findsNothing);
    // A check that is looked for says when it was opened and whose it is.
    expect(find.textContaining('· closed · fired'), findsOneWidget);
    expect(find.textContaining('${clockTimeOf(past.first)} · 2 items · closed'), findsOneWidget);
    expect(find.textContaining('· paid · Amy'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('find-check')), 'ben');
    await tester.pumpAndSettle();
    expect(find.text('Wei · counter'), findsOneWidget);
    expect(find.text('Table B12'), findsOneWidget);
    expect(find.text('Linda Chen · phone'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('find-check')), 'zebra');
    await tester.pumpAndSettle();
    expect(find.text('No check matches.'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-check')), findsNothing);
    expect(find.byKey(const ValueKey('to-go-chips')), findsOneWidget);
    expect(t.hub.listsAsked.last['status'], 'open');
    expect(find.text('Linda Park · phone'), findsNothing);
    expect(find.text('Wei · counter'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a manager looks through another day\'s checks from the calendar, and comes back to now', (tester) async {
    final today = DateTime.now();
    final first = DateTime(today.year, today.month, 1);
    // The first of this month, unless that is today: then the first of last month.
    final day = first.day == today.day ? DateTime(today.year, today.month - 1, 1) : first;
    final opened = DateTime(day.year, day.month, day.day, 19, 42).millisecondsSinceEpoch;
    final t = await pumpOrders(
      tester,
      open(),
      before: (hub) async {
        hub.past.addAll(closed());
        hub.byDay[isoDay(day)] = [
          check(
            quoted('d1', no: 3, name: 'Rosa', channel: 'phone', fired: true, payments: cash),
            status: 'closed',
            server: 'Holly',
            openedMs: opened,
          ),
        ];
      },
    );
    await tester.tap(find.byKey(const ValueKey('find-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('find-day')));
    await tester.pumpAndSettle();
    expect(find.text('Checks opened on'), findsOneWidget);
    if (day.month != today.month) {
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('1').first);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(t.hub.listsAsked.last['day'], isoDay(day));
    expect(find.text('Rosa · phone'), findsOneWidget);
    expect(find.text('Wei · counter'), findsNothing); // today's are not that day's
    expect(find.textContaining('19:42 · 2 items · closed'), findsOneWidget); // the day it was, then the time
    expect(find.textContaining('· paid · Holly'), findsOneWidget);

    // The cross on the day comes back to now: the open checks and the last day's.
    await tester.tap(find.byTooltip('Back to now'));
    await tester.pumpAndSettle();
    expect(t.hub.listsAsked.last.containsKey('day'), isFalse);
    expect(find.text('Wei · counter'), findsOneWidget);
    expect(find.text('Rosa · phone'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('find-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-check')), findsNothing);
    await stop(tester);
  });

  testWidgets('a hub from before days answers a day with the last day\'s checks: none of them is shown', (
    tester,
  ) async {
    final today = DateTime.now();
    final t = await pumpOrders(tester, const []);
    // What such a hub does with a `day` it does not know: the list `hours` asks for, with no opening times.
    t.hub.byDay[isoDay(today)] = [quoted('o1', name: 'Wei')];
    await tester.tap(find.byKey(const ValueKey('find-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('find-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // today
    await tester.pumpAndSettle();
    expect((t.hub.listsAsked.last['day'], t.hub.listsAsked.last['hours']), (isoDay(today), '24.0'));
    expect(find.text('Wei · counter'), findsNothing);
    expect(find.text('No checks were opened that day.'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('with no to-go order the row is the way into the search, saying what it does', (tester) async {
    await pumpOrders(tester, [check(table('t1', const {}), tableName: 'A1')]);
    expect(find.byKey(const ValueKey('to-go-chips')), findsNothing);
    expect(find.text('Find a check'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('find-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-check')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-day')), findsOneWidget); // a manager: the calendar
    await stop(tester);

    await pumpOrders(tester, open(), showList: false); // the floor map has no such row
    expect(find.byKey(const ValueKey('find-open')), findsNothing);
    await stop(tester);
  });
}

/// "19:42" for when a test check was opened.
String clockTimeOf(Map<String, dynamic> order) {
  final at = DateTime.fromMillisecondsSinceEpoch(order['opened_ms'] as int);
  return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}
