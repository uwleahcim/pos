import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/check_search.dart';
import 'package:pos_app/day_report.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/to_go_chips.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/to_go_stages.dart';

import 'hub.dart';
import 'table_moves_test.dart' show byAmy, byHolly, byMike, checkAt, floorThatMoves, sentTo;
import 'table_servers_test.dart' show amy, holly, mike, sentOne, serverTag;

/// Bar tabs (the Toast comparison's row 13): a check opened with a name and no table. It is rung in and sent
/// like a table's check, found again in the list of checks by its name, on no floor map, and given a table
/// when the party sits down: a free table seats it, a seated one takes it onto its check or beside it.

const ben = Staff(staffId: 's2', name: 'Ben', role: 'bartender', method: 'pin');

/// A drink on a tab: for nobody's seat, since a tab has none.
Map<String, dynamic> drink(String item, {bool fired = false, double? rank}) => {
  ...line(item, course: 'drinks', fired: fired, rank: rank),
  'seat': null,
};

/// A bar tab as a hub lists it: Ben's, at no table.
Map<String, dynamic> tab(
  String id,
  String name, {
  Map<String, dynamic> lines = const {},
  Map<String, dynamic> more = const {},
}) => {
  'order_id': id,
  'status': 'open',
  'fields': {'order_type': 'dine_in', 'tab': true, 'customer_name': name, 'server': 'Ben', 'server_id': 's2'},
  'lines': {...lines},
  'fired': <String, dynamic>{},
  ...more,
};

Map<String, dynamic> toGo(String id, String name, int number) => {
  'order_id': id,
  'status': 'open',
  'fields': {'order_type': 'takeout', 'order_no': number, 'customer_name': name, 'channel': 'phone', 'stage': 'new'},
  'lines': {'L1': line('Egg roll')},
  'fired': <String, dynamic>{},
};

Order order(Map<String, dynamic> json) => Order.fromJson(json);

/// The titles of the checks listed, top to bottom.
List<String?> listed(WidgetTester tester) => [
  for (final tile in tester.widgetList<ListTile>(
    find.descendant(of: find.byKey(const ValueKey('orders-list')), matching: find.byType(ListTile)),
  ))
    (tile.title! as Text).data,
];

Finder chip(String name) => find.byKey(ValueKey('chip:$name'));
Finder seatingBar() => find.byKey(const ValueKey('seating-bar'));

/// Cancel in the dialog that is open (the seating strip has a Cancel of its own).
Future<void> cancelDialog(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// The list of checks of [who], whose hub lists Linda's tab (a beer at the bar, a plate of wings not sent)
/// beside what [hub] sets up; the tab is opened and "Seat at a table" tapped, so the floor map is up.
Future<Terminal> pumpSeating(
  WidgetTester tester,
  Staff who, {
  void Function(Hub hub)? hub,
  Map<String, dynamic> more = const {},
  Size? size,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.session.staff = who;
  t.hub.floor = floorThatMoves();
  t.hub.orders.add(
    tab(
      'b1',
      'Linda',
      lines: {'L1': drink('Tsingtao', fired: true, rank: 1), 'L2': drink('Chicken wings', rank: 2)},
      more: more,
    ),
  );
  hub?.call(t.hub);
  await pumpOrdersOn(tester, t);
  await tester.tap(find.text('Linda · tab'));
  await tester.pumpAndSettle();
  expect(find.text("Linda's tab"), findsOneWidget);
  await tapKey(tester, 'seat-tab');
  expect(find.byType(OrderScreen), findsNothing);
  return t;
}

void main() {
  test('a tab is a check with a name and no table, until it is given one', () {
    final linda = order(tab('b1', 'Linda'));
    expect((linda.isTab, linda.isTakeout, linda.hasTable, linda.tabLabel), (true, false, false, "Linda's tab"));
    expect(order(tab('b2', '  ')).tabLabel, 'A tab');
    // sat down: a table's check that keeps its name
    final sat = order(tab('b1', 'Linda')..['fields'] = {...tab('b1', 'Linda')['fields'] as Map, 'table': 'A5'});
    expect((sat.isTab, sat.isTakeout, sat.hasTable, sat.customerName), (false, false, true, 'Linda'));
    // a to-go order and a table's check are no tabs, and a to-go order is still one
    final lee = order(toGo('g1', 'Lee', 7));
    expect((lee.isTab, lee.isTakeout), (false, true));
    final a1 = order(table('o1', {}));
    expect((a1.isTab, a1.isTakeout, a1.hasTable), (false, false, true));
    expect(const Order.empty('new').isTab, isFalse);
  });

  test('a tab is found by the name on it and by the word, and is no to-go order for the chips', () {
    final linda = order(tab('b1', 'Linda Wu'));
    expect(checkMatches(linda, 'linda'), isTrue);
    expect(checkMatches(linda, 'wu lin'), isTrue);
    expect(checkMatches(linda, 'tab'), isTrue);
    expect(checkMatches(linda, 'tabs ben'), isTrue); // whose it is
    expect(checkMatches(linda, 'table'), isFalse);
    expect(checkMatches(order(toGo('g1', 'Lee', 7)), 'tab'), isFalse);
    expect(checkMatches(order(table('o1', {})), 'tab'), isFalse);
    final now = DateTime(2026, 11, 16, 19);
    for (final one in ToGoChip.values) {
      expect(inChip(one, linda, now), isFalse, reason: one.name);
    }
  });

  test('the tabs are listed by the name on each, whatever its case', () {
    final tabs = [
      for (final (id, name) in [('b1', 'linda'), ('b2', 'Adam'), ('b3', 'Linda'), ('b4', ' ben')]) order(tab(id, name)),
    ];
    expect(tabsByName(tabs, (o) => o).map((o) => o.orderId), ['b2', 'b4', 'b1', 'b3']);
  });

  test('the reports and the history call a tab a tab', () {
    expect(kindLabel('tab'), 'Bar tabs');
    final open = DayCheck.fromJson({
      'order_id': 'b1',
      'total': '13.91',
      'due': '13.91',
      'table': null,
      'customer_name': 'Linda',
      'tab': true,
      'order_type': 'dine_in',
    });
    expect(open.where, 'Tab · Linda');
    expect(const DayCheck(orderId: 'x', total: '0', due: '0').where, 'Tables'); // an older hub says no "tab"
    final history = HistoryOrder.fromJson({'order_id': 'b1', 'customer_name': 'Linda', 'tab': true});
    expect(history.where, 'Tab · Linda');
    expect(
      HistoryOrder.fromJson({'order_id': 'b1', 'customer_name': 'Linda', 'table': 'A5'}).where,
      'Table A5 · Linda',
    );

    String time(int ms) => '$ms';
    HistoryStep step(String what, Map<String, dynamic> said) =>
        HistoryStep.fromJson({'op_id': 'x', 'at_ms': 1, 'what': what, ...said});
    final opened = wordsOf(
      step('opened', {
        'fields': {'order_type': 'dine_in', 'tab': true, 'customer_name': 'Linda', 'server': 'Ben'},
      }),
      time: time,
    );
    expect(opened.under, ['Bar tab · Linda · server Ben']);
    final sat = wordsOf(step('table', {'was': null, 'now': 'A5'}), time: time);
    expect(sat.title, 'Put at table A5');
    final came = wordsOf(
      step('moved_in', {'dish': 'Tsingtao', 'qty': 1, 'other': 'b1', 'other_table': null, 'other_tab': 'Linda'}),
      time: time,
    );
    expect(came.title, contains("came over from Linda's tab"));
    final nameless = wordsOf(
      step('moved_in', {'dish': 'Tsingtao', 'qty': 1, 'other': 'b1', 'other_tab': ''}),
      time: time,
    );
    expect(nameless.title, contains('came over from a bar tab'));
  });

  testWidgets('Tab asks for the name and opens a check with no table, rung in like a table\'s', (tester) async {
    final t = await terminal(tester);
    t.session.staff = ben;
    await pumpOrdersOn(tester, t);
    await tapKey(tester, 'new-tab');
    expect(find.text('Open a tab'), findsOneWidget);
    // a tab is found again by its name: there is none without one
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('tab-open'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('tab-name')), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('tab-open'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('tab-name')), '  Linda   Wu ');
    await tester.pump();
    await tapKey(tester, 'tab-open');

    final (_, data) = sentOne(t.hub, 'create');
    expect(data, {
      'order_type': 'dine_in',
      'tab': true,
      'customer_name': 'Linda Wu',
      'server': 'Ben',
      'server_id': 's2',
    });
    // he is in the tab: the name at the top, the courses, and the way to a table where a table has its seats
    expect(find.byType(OrderScreen), findsOneWidget);
    expect(find.text("Linda Wu's tab"), findsOneWidget);
    expect(find.byKey(const ValueKey('seat-tab')), findsOneWidget);
    expect(find.text('Seat  '), findsNothing);
    expect(find.text('Course  '), findsOneWidget);
    expect(find.byTooltip('Fire'), findsOneWidget); // sent in rounds, and paid at the end
    expect(find.text('Pay & send'), findsNothing);
    await stop(tester);
  });

  testWidgets('the name can be given up, and nothing is opened', (tester) async {
    final t = await pumpOrders(tester, []);
    await tapKey(tester, 'new-tab');
    await tester.enterText(find.byKey(const ValueKey('tab-name')), 'Linda');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.hub.sent, isEmpty);
    expect(find.byType(OrderScreen), findsNothing);
    // the keyboard's own Done opens it too
    await tapKey(tester, 'new-tab');
    await tester.enterText(find.byKey(const ValueKey('tab-name')), 'Kim');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(sentOne(t.hub, 'create').$2['customer_name'], 'Kim');
    await stop(tester);
  });

  testWidgets('a tab is in the list by its name, and Tabs narrows the list to the tabs by name', (tester) async {
    await pumpOrders(tester, [
      tab('b1', 'Linda', lines: {'L1': drink('Tsingtao', fired: true)}),
      table('o1', {'L1': line('Egg roll')}),
      toGo('g1', 'Lee', 7),
      tab('b2', 'adam'),
    ]);
    expect(listed(tester), ['Linda · tab', 'Table A1', 'Lee · phone', 'adam · tab']);
    expect(find.byIcon(Icons.local_bar), findsNWidgets(2)); // a glass where a table has its name
    // Tabs stands before the to-go orders' four
    expect(find.descendant(of: chip('tabs'), matching: find.text('Tabs 2', findRichText: true)), findsOneWidget);
    expect(tester.getTopLeft(chip('tabs')).dx, lessThan(tester.getTopLeft(chip('later')).dx));

    await tester.tap(chip('tabs'));
    await tester.pumpAndSettle();
    expect(listed(tester), ['adam · tab', 'Linda · tab']);
    await tester.tap(chip('tabs'));
    await tester.pumpAndSettle();
    expect(listed(tester).length, 4);

    // one chip at a time: a to-go chip takes over from Tabs, and Tabs from it
    await tester.tap(chip('tabs'));
    await tester.pumpAndSettle();
    await tester.tap(chip('unpaid'));
    await tester.pumpAndSettle();
    expect(listed(tester), ['Lee · phone']);
    await tester.tap(chip('tabs'));
    await tester.pumpAndSettle();
    expect(listed(tester), ['adam · tab', 'Linda · tab']);
    await stop(tester);
  });

  testWidgets('Tabs shows only while a tab is open, alone where there is no to-go order', (tester) async {
    final t = await pumpOrders(tester, [table('o1', {})]);
    expect(find.byType(ToGoChips), findsNothing);
    await stop(tester);

    t.hub.orders.add(tab('b1', 'Linda'));
    await pumpOrdersOn(tester, t);
    expect(chip('tabs'), findsOneWidget);
    expect(chip('later'), findsNothing);
    expect(tester.getSize(chip('tabs')).width, lessThan(120)); // a button, not a bar across the screen
    await stop(tester);

    t.hub.orders
      ..clear()
      ..add(toGo('g1', 'Lee', 7));
    await pumpOrdersOn(tester, t);
    expect(chip('tabs'), findsNothing);
    expect(chip('later'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('the search finds a tab by its name, among the checks at tables', (tester) async {
    await pumpOrders(tester, [tab('b1', 'Linda'), table('o1', {}), tab('b2', 'Adam')]);
    await tapKey(tester, 'find-open');
    await tester.enterText(find.byKey(const ValueKey('find-check')), 'lin');
    await tester.pumpAndSettle();
    expect(listed(tester), ['Linda · tab']);
    await tester.enterText(find.byKey(const ValueKey('find-check')), 'tab');
    await tester.pumpAndSettle();
    expect(listed(tester), ['Linda · tab', 'Adam · tab']);
    await stop(tester);
  });

  testWidgets('a server seats the tab at a free table and takes the check', (tester) async {
    final t = await pumpSeating(tester, amy);
    // the floor map is up, and says what the next tap does
    expect(seatingBar(), findsOneWidget);
    expect(find.text("Seating Linda's tab. Tap their table."), findsOneWidget);
    expect(serverTag('A8'), findsNothing);

    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    expect(find.text("Seat Linda's tab at A8"), findsOneWidget);
    expect(find.text('Server'), findsNothing); // a server takes the table she seats
    await tester.tap(find.widgetWithText(ActionChip, '2'));
    await tester.pump();
    await tapKey(tester, 'seat');

    expect(sentTo(t.hub), [
      [
        'b1',
        'set_field',
        {'table': 'A8', 'guests': 2, 'server': 'Amy', 'server_id': 's1', ...byAmy},
      ],
    ]);
    expect(t.hub.sent.map((s) => s.$2['kind']), isNot(contains('void_line'))); // nothing rung in again
    expect(find.text("Linda's tab sat down at A8"), findsOneWidget);
    expect(seatingBar(), findsNothing);
    expect(find.byType(OrderScreen), findsNothing);
    // it is on the floor map now, at A8, and hers
    expect(find.descendant(of: serverTag('A8'), matching: find.text('Amy')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('the host seats the tab for a server, who has to be named', (tester) async {
    final t = await pumpSeating(tester, holly);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    expect(find.text('Server'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('seat'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('server:s1')));
    await tester.pump();
    await tapKey(tester, 'seat');
    final (id, data) = sentOne(t.hub, 'set_field');
    expect(id, 'b1');
    expect(
      (data['table'], data['server'], data['server_id'], data['by'], data['by_id']),
      ('A8', 'Amy', 's1', 'Holly', 's4'),
    );
    expect(seatingBar(), findsNothing);
    await stop(tester);
  });

  testWidgets('the bartender who seats his own tab keeps it', (tester) async {
    final t = await pumpSeating(tester, ben);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'seat');
    final (_, data) = sentOne(t.hub, 'set_field');
    expect((data['table'], data['server'], data['server_id']), ('A8', 'Ben', 's2'));
    await stop(tester);
  });

  testWidgets('seating can be called off, by Cancel or by going back to the list', (tester) async {
    final t = await pumpSeating(tester, amy);
    await tapKey(tester, 'move-cancel');
    expect(seatingBar(), findsNothing);
    // the floor map is the floor map again: a tap on a free table seats a party
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    expect(find.text('Seat A8'), findsOneWidget);
    await cancelDialog(tester);

    await tester.tap(find.byTooltip('List of checks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Linda · tab'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'seat-tab');
    expect(seatingBar(), findsOneWidget);
    // the question given up leaves the tab in hand for another table
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    await cancelDialog(tester);
    expect(seatingBar(), findsOneWidget);
    await tester.tap(find.byTooltip('List of checks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Floor map'));
    await tester.pumpAndSettle();
    expect(seatingBar(), findsNothing);
    expect(t.hub.sent, isEmpty);
    expect(listedTabStillThere(t), isTrue);
    await stop(tester);
  });

  group('at a table that is seated', () {
    /// A7 is Amy's, with an egg roll on its check.
    void a7(Hub hub) => hub.orders.add(checkAt('o1', 'A7', {'M1': line('Egg roll', rank: 1)}, guests: 4));

    testWidgets('the tab joins the table\'s check: every drink goes over and none is voided', (tester) async {
      final t = await pumpSeating(tester, mike, hub: a7);
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      expect(find.text('A7 is seated'), findsOneWidget);
      expect(find.text("Put Linda's tab and A7 on one check, or keep two checks at A7?"), findsOneWidget);
      await tapKey(tester, 'one-check');

      final ops = sentTo(t.hub);
      expect(ops.map((op) => '${op[0]} ${op[1]}'), [
        'o1 add_line',
        'o1 add_line',
        'b1 move_line',
        'b1 move_line',
        'b1 set_field',
        'b1 close',
      ]);
      final beer = ops[0][2]! as Map, wings = ops[1][2]! as Map;
      // a tab has no seats: its drinks are the table's, and the one at the bar already is not sent again
      expect((beer['item'], beer['seat'], beer['sent']), ('Tsingtao', null, 'sent'));
      expect(beer['from'], {'order_id': 'b1', 'line_id': 'L1'});
      expect((wings['item'], wings['seat'], wings.containsKey('sent')), ('Chicken wings', null, false));
      expect((ops[2][2]! as Map)['to'], {'order_id': 'o1', 'line_id': beer['line_id']});
      expect(ops[4][2], {'merged_into': 'o1', ...byMike});
      expect(t.hub.sent.map((s) => s.$2['kind']), isNot(contains('void_line')));
      expect(find.text("Linda's tab is on A7's check now"), findsOneWidget);
      expect(seatingBar(), findsNothing);
      // the hub's own reading: the drinks are on A7's check, the beer still as the bar has it
      final lines = (t.hub.orders.firstWhere((o) => o['order_id'] == 'o1')['lines'] as Map).values.cast<Map>();
      expect(lines.map((l) => (l['item'], l['fired'])), [
        ('Egg roll', false),
        ('Tsingtao', true),
        ('Chicken wings', false),
      ]);
      await stop(tester);
    });

    testWidgets('or stays a check of its own there, the table\'s server\'s from then on', (tester) async {
      final t = await pumpSeating(tester, holly, hub: a7);
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'keep-apart');
      expect(sentTo(t.hub), [
        [
          'b1',
          'set_field',
          {'table': 'A7', 'server': 'Amy', 'server_id': 's1', ...byHolly},
        ],
      ]);
      expect(find.text("Linda's tab sat down at A7"), findsOneWidget);
      final checks = (t.hub.floor!['status'] as Map)['A7'] as List;
      expect(checks.map((check) => ((check as Map)['order_id'], check['server'])), [('o1', 'Amy'), ('b1', 'Amy')]);
      await stop(tester);
    });

    testWidgets('a tab with a payment on it can only be kept apart', (tester) async {
      final t = await pumpSeating(
        tester,
        mike,
        hub: a7,
        more: {
          'payments': {
            'P1': {'method': 'cash', 'amount': '5.00'},
          },
        },
      );
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      expect(find.text("Linda's tab has a payment on it, so it stays a check of its own."), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('one-check'))).onPressed, isNull);
      await tapKey(tester, 'keep-apart');
      expect(sentTo(t.hub).single[1], 'set_field');
      await stop(tester);
    });

    testWidgets('the question given up leaves the tab in hand for another table', (tester) async {
      final t = await pumpSeating(tester, mike, hub: a7);
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      await cancelDialog(tester);
      expect(seatingBar(), findsOneWidget);
      expect(t.hub.sent, isEmpty);
      await stop(tester);
    });
  });

  testWidgets('the name at the top of a tab, tapped, changes the name on it', (tester) async {
    final t = await pumpOrders(tester, [tab('b1', 'Linda')]);
    await tester.tap(find.text('Linda · tab'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'order-title');
    expect(find.text('Name on the tab'), findsNWidgets(2)); // the title, and the field's own label
    expect(tester.widget<TextField>(find.byKey(const ValueKey('tab-name'))).controller!.text, 'Linda');
    await tester.enterText(find.byKey(const ValueKey('tab-name')), 'Linda W');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(sentTo(t.hub), [
      [
        'b1',
        'set_field',
        {'customer_name': 'Linda W', ...byMike},
      ],
    ]);
    expect(find.text("Linda W's tab"), findsOneWidget);
    // a table's title changes nothing
    await stop(tester);
  });

  testWidgets('on a device that goes back to sign-in after sending, seating a tab signs out once it sat down', (
    tester,
  ) async {
    final t = await terminal(tester);
    await t.settings.saveSignOutAfterSend(true);
    t.session.staff = ben;
    t.hub.floor = floorThatMoves();
    t.hub.orders.add(tab('b1', 'Linda', lines: {'L1': drink('Tsingtao')}));
    await pumpOrdersOn(tester, t);
    await tester.tap(find.text('Linda · tab'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fire'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fire everything'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'seat-tab');
    // on his way to the table: still him
    expect(t.session.signedIn, isTrue);
    expect(seatingBar(), findsOneWidget);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'seat');
    expect(sentTo(t.hub).map((op) => op[1]), ['fire', 'set_field']);
    expect(t.session.signedIn, isFalse);
    await stop(tester);
  });

  testWidgets('a phone: the two buttons, the chips and the seating strip fit', (tester) async {
    final t = await terminal(tester);
    tester.view.physicalSize = const Size(320, 640);
    t.session.staff = amy;
    t.hub.floor = floorThatMoves();
    t.hub.orders.addAll([
      tab('b1', 'Linda', lines: {'L1': drink('Tsingtao', fired: true)}),
      toGo('g1', 'Lee', 7),
      table('o1', {}),
    ]);
    await pumpOrdersOn(tester, t);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('new-tab')), findsOneWidget);
    expect(find.byKey(const ValueKey('to-go')), findsOneWidget);
    expect(chip('tabs'), findsOneWidget);
    expect(chip('unpaid'), findsOneWidget);
    final screen = tester.getRect(find.byType(Scaffold).first);
    for (final key in ['new-tab', 'to-go', 'chip:tabs', 'chip:unpaid']) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.left >= 0 && rect.right <= screen.right, isTrue, reason: '$key $rect');
    }
    await tester.tap(find.text('Linda · tab'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tapKey(tester, 'seat-tab');
    expect(seatingBar(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });
}

/// Whether the hub still lists Linda's tab as one: nothing gave it a table.
bool listedTabStillThere(Terminal t) => t.hub.orders.any((o) => o['order_id'] == 'b1' && Order.fromJson(o).isTab);
