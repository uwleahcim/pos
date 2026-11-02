import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_order.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/line_ops.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'hub.dart';

/// Arranging the check: hold a dish and drag it to another place, or under another course; while it is
/// held, tap other dishes to take them along. A line carries its place (`set_line` with `rank`, and `course`
/// when the course changes), sent to the kitchen or not: a dish the kitchen has keeps its place on the
/// ticket it went out on (Mike, 2026-11-02).

Line l(String id, String item, {String? course, double rank = 0, bool fired = false}) =>
    Line(lineId: id, item: item, qty: 1, status: 'active', course: course, rank: rank, fired: fired);

Order orderOf(List<Line> lines) =>
    Order(orderId: 'o1', status: 'open', fields: const {}, lines: lines, fired: const {});

String rowOf(CheckRow row) => switch (row) {
  CourseRow r => '[${r.name}${r.state.isEmpty ? '' : ' ${r.state}'}]',
  LineRow r => r.line.item,
};

Finder header(String id) => find.byKey(ValueKey('course-row:$id'));

Finder inCheck(String text) => find.descendant(of: find.byKey(const ValueKey('check-rows')), matching: find.text(text));

/// The dishes on the check that can be held and dragged (the one in hand, drawn over the list, is not one).
Finder holdable() => find.descendant(
  of: find.byKey(const ValueKey('check-rows')),
  matching: find.byType(ReorderableDelayedDragStartListener),
);

const noChoices = 'This line has no menu choices to change. Remove it and add it again.';

Future<Terminal> pumpOrder(WidgetTester tester, Map<String, dynamic> lines) async {
  final t = await terminal(tester);
  t.hub.orders.add(table('o1', lines));
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1'),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// Holds a row by the dish's name until the list picks it up.
Future<TestGesture> holdRow(WidgetTester tester, Finder row) async {
  final gesture = await tester.startGesture(tester.getCenter(row));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  return gesture;
}

/// Carries a held row from [from] to [to] in steps, so the list makes room as it passes the others, and
/// lets go.
Future<void> carry(WidgetTester tester, TestGesture gesture, Offset from, Offset to) async {
  for (var i = 1; i <= 12; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Holds a row of the check, drags it to [to] and lets go.
Future<void> dragRow(WidgetTester tester, Finder row, Offset to) async {
  final from = tester.getCenter(row);
  await carry(tester, await holdRow(tester, row), from, to);
}

/// The whole row a dish's name is on.
Finder tileOf(Finder text) => find.ancestor(of: text, matching: find.byType(ListTile)).first;

/// Whether a dish on the check is picked up, to go with the one in hand.
bool pickedUp(WidgetTester tester, String dish) => tester.widget<ListTile>(tileOf(inCheck(dish))).selected;

/// Where to let go of a dish held by its name so that its row lands just before [target]'s: the slot the
/// list opens for it there (above the target going down, in the target's place going up).
Offset dropBefore(WidgetTester tester, Finder text, Finder target) {
  final row = tileOf(text);
  final height = tester.getSize(row).height;
  final grab = tester.getCenter(text).dy - tester.getTopLeft(row).dy; // where the finger holds the row
  final top = tester.getTopLeft(tileOf(target)).dy;
  final downward = tester.getTopLeft(row).dy < top;
  return Offset(tester.getCenter(text).dx, (downward ? top - height : top) + grab);
}

void main() {
  group('the rows of the check', () {
    test('list every course the location serves, then courses off the list, then lines with none', () {
      final order = orderOf([
        l('L1', 'Duck', course: '2', rank: 2),
        l('L2', 'Egg roll', course: '1', rank: 1),
        l('L3', 'Soup', course: 'old', rank: 3, fired: true),
        l('L4', 'Mint', rank: 4),
      ]);
      expect(checkRows(order, Coursing.defaults).map(rowOf), [
        '[Drinks]',
        '[Appetizers held]',
        'Egg roll',
        '[Entrees held]',
        'Duck',
        '[Dessert]',
        '[old fired]',
        'Soup',
        '[No course held]',
        'Mint',
      ]);
    });

    test('with coursing off the check is one group, in rank order', () {
      const off = Coursing(enabled: false);
      final order = orderOf([l('L1', 'Duck', rank: 2), l('L2', 'Egg roll', rank: 1)]);
      expect(checkRows(order, off).map(rowOf), ['[Items held]', 'Egg roll', 'Duck']);
    });
  });

  group('where a dropped row lands', () {
    // 0 [Drinks] 1 [Appetizers] 2 Egg roll 3 Spring roll 4 [Entrees] 5 Duck 6 [Dessert]
    final rows = checkRows(
      orderOf([
        l('L1', 'Egg roll', course: '1', rank: 1),
        l('L2', 'Spring roll', course: '1', rank: 2),
        l('L3', 'Duck', course: '2', rank: 3),
      ]),
      Coursing.defaults,
    );

    test('between two dishes of a course: halfway between them', () {
      expect(placement(rows, 5, 3), (course: '1', rank: 1.5)); // the duck up between the rolls
    });

    test('at the top of a course: before its first dish', () {
      expect(placement(rows, 5, 2), (course: '1', rank: 0.0));
    });

    test('at the end of a course, just above the next header: after its last dish', () {
      expect(placement(rows, 2, 3), (course: '1', rank: 3.0));
    });

    test('into a course with nothing in it: the same rank, under that header', () {
      expect(placement(rows, 2, 6), (course: '3', rank: 1.0));
    });

    test('above the first header: the top of the first course', () {
      expect(placement(rows, 5, 0), (course: 'drinks', rank: 3.0));
    });

    test('under "No course": the course comes off', () {
      final rows = checkRows(
        orderOf([l('L1', 'Egg roll', course: '1', rank: 1), l('L2', 'Mint', rank: 2)]),
        Coursing.defaults,
      );
      expect(placement(rows, 2, 6), (course: null, rank: 3.0));
    });
  });

  group('where rows picked up together land', () {
    // 0 [Drinks] 1 [Appetizers] 2 Egg roll 3 Spring roll 4 Wonton 5 [Entrees] 6 Duck 7 [Dessert]
    final rows = checkRows(
      orderOf([
        l('L1', 'Egg roll', course: '1', rank: 1),
        l('L2', 'Spring roll', course: '1', rank: 2),
        l('L3', 'Wonton', course: '1', rank: 4),
        l('L4', 'Duck', course: '2', rank: 6),
      ]),
      Coursing.defaults,
    );
    List<String> ids(Drop drop) => [for (final line in drop.lines) line.lineId];

    test('they go with the held one, in the order the check had them, spread between its neighbours', () {
      final drop = dropOf(rows, 6, 3, picked: {'L2'}); // the duck up to where the spring roll is
      expect(drop.course, '1');
      expect(ids(drop), ['L2', 'L4']);
      expect(drop.ranks, [2.0, 3.0]); // between the egg roll (1) and the wonton (4)
      expect(drop.at, 3);
    });

    test('a dish picked up is not counted as a neighbour of the drop', () {
      final drop = dropOf(rows, 6, 2, picked: {'L1'}); // the top of the appetizers, where the egg roll was
      expect(ids(drop), ['L1', 'L4']);
      expect(drop.ranks, [0.0, 1.0]); // before the spring roll (2), the egg roll being in hand
      expect(drop.at, 2);
    });

    test('alone under a header, the first keeps its rank and the rest follow', () {
      final drop = dropOf(rows, 6, 7, picked: {'L1'}); // under Dessert
      expect(drop.course, '3');
      expect(ids(drop), ['L1', 'L4']);
      expect(drop.ranks, [1.0, 2.0]);
      expect(drop.at, 6); // the Dessert header is row 5 once the egg roll and the duck have left
    });

    test('let go where it was, the others gather to it', () {
      final drop = dropOf(rows, 3, 3, picked: {'L4'}); // the spring roll held in place, the duck picked up
      expect(drop.course, '1');
      expect(ids(drop), ['L2', 'L4']);
      expect(drop.ranks, [2.0, 3.0]);
    });

    test('one line alone lands as a plain drop', () {
      final drop = dropOf(rows, 6, 3);
      expect(drop.course, '1');
      expect(ids(drop), ['L4']);
      expect(drop.ranks, [1.5]);
    });
  });

  group('the operations a move sends', () {
    test('within its course: the place alone, sent or not', () {
      final egg = l('L1', 'Egg roll', course: '1', rank: 1, fired: true);
      final change = moveChange(egg, course: '1', rank: 2.5);
      expect(change.ops.map((op) => op.$1), ['set_line']);
      expect(change.ops.single.$2, {'line_id': 'L1', 'rank': 2.5});
      expect(change.voidsFired, isFalse);
      expect(moveChange(egg, course: '1', rank: 1).isEmpty, isTrue);
    });

    test('to another course before the kitchen has it: the course and the place', () {
      final egg = l('L1', 'Egg roll', course: '1', rank: 1);
      final change = moveChange(egg, course: '2', rank: 2.5);
      expect(change.ops.map((op) => op.$1), ['set_line']);
      expect(change.ops.single.$2, {'line_id': 'L1', 'course': '2', 'rank': 2.5});
      expect(change.voidsFired, isFalse);
      final none = moveChange(egg, course: null, rank: 1);
      expect(none.ops.single.$2, {'line_id': 'L1', 'course': null, 'rank': 1.0}); // the course comes off
    });

    test('to another course once sent: the same, and nothing is voided: the kitchen keeps it as it went', () {
      final egg = l('L1', 'Egg roll', course: '1', rank: 1, fired: true);
      final change = moveChange(egg, course: '2', rank: 2.5);
      expect(change.ops.map((op) => op.$1), ['set_line']);
      expect(change.ops.single.$2, {'line_id': 'L1', 'course': '2', 'rank': 2.5});
      expect(change.voidsFired, isFalse);
      expect(change.newLineId, isNull);
      final uncoursed = moveChange(l('L2', 'x', course: '2', fired: true), course: null, rank: 9);
      expect(uncoursed.ops.single.$2, {'line_id': 'L2', 'course': null, 'rank': 9.0});
    });
  });

  testWidgets('the check shows every course the location serves; a dish dragged under another goes there', (
    tester,
  ) async {
    final t = await pumpOrder(tester, {
      'L1': line('Pot stickers', course: '1', rank: 1),
      'L2': line('Walnut shrimp', course: '2', rank: 2),
      'L3': line('Jasmine tea', course: 'drinks', rank: 3, fired: true),
    });
    for (final id in const ['drinks', '1', '2', '3']) {
      expect(header(id), findsOneWidget);
    }
    expect(find.descendant(of: header('3'), matching: find.byType(Icon)), findsNothing); // nothing in it: no state

    // hold the pot stickers and drop them just under the Entrees header
    await dragRow(
      tester,
      inCheck('Pot stickers'),
      dropBefore(tester, inCheck('Pot stickers'), inCheck('Walnut shrimp')),
    );
    final op = t.hub.opsFor('o1').single;
    expect(op['kind'], 'set_line');
    expect(op['data'], {'line_id': 'L1', 'course': '2', 'rank': 1.0}); // above the shrimp (2): one less
    // the check shows them there, above the shrimp; the appetizers stand empty
    final ys = [
      for (final f in [header('1'), header('2'), inCheck('Pot stickers'), inCheck('Walnut shrimp')])
        tester.getCenter(f).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.descendant(of: header('1'), matching: find.byType(Icon)), findsNothing);
    await stop(tester);
  });

  testWidgets('within its course a dish changes its place; the kitchen is not told', (tester) async {
    final t = await pumpOrder(tester, {
      'L1': line('Pot stickers', course: '1', rank: 1, fired: true),
      'L2': line('Scallion pancake', course: '1', rank: 2, fired: true),
    });
    await dragRow(
      tester,
      inCheck('Scallion pancake'),
      dropBefore(tester, inCheck('Scallion pancake'), inCheck('Pot stickers')),
    );
    final op = t.hub.opsFor('o1').single;
    expect(op['kind'], 'set_line');
    expect(op['data'], {'line_id': 'L2', 'rank': 0.0}); // above the pot stickers (1): one less, no new course
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.getCenter(inCheck('Scallion pancake')).dy < tester.getCenter(inCheck('Pot stickers')).dy, isTrue);
    await stop(tester);
  });

  testWidgets('a dish the kitchen has, dragged to another course, just goes there: still sent, nothing voided', (
    tester,
  ) async {
    final t = await pumpOrder(tester, {
      'L1': line('Jasmine tea', course: 'drinks', rank: 1, fired: true),
      'L2': line('Walnut shrimp', course: '2', rank: 2),
    });
    final underDessert = tester.getCenter(header('3')) + const Offset(0, 30);
    await dragRow(tester, inCheck('Jasmine tea'), underDessert);
    expect(find.byType(AlertDialog), findsNothing); // nothing to confirm: no VOID ticket
    final op = t.hub.opsFor('o1').single;
    expect(op['kind'], 'set_line');
    expect(op['data'], {'line_id': 'L1', 'course': '3', 'rank': 1.0});
    // the one line, under Dessert, which now shows as fired: the tea went when the drinks did
    expect(inCheck('Jasmine tea'), findsOneWidget);
    expect(tester.getCenter(inCheck('Jasmine tea')).dy > tester.getCenter(header('3')).dy, isTrue);
    expect(find.descendant(of: header('3'), matching: find.byIcon(Icons.local_fire_department)), findsOneWidget);
    expect(inCheck('void'), findsNothing);
    await stop(tester);
  });

  testWidgets('while a dish is held, tapping others picks them up; they land together where it is let go', (
    tester,
  ) async {
    final t = await pumpOrder(tester, {
      'L1': line('Pot stickers', course: '1', rank: 1),
      'L2': line('Walnut shrimp', course: '2', rank: 2),
      'L3': line('Jasmine tea', course: 'drinks', rank: 3, fired: true),
      'L4': line('Scallion pancake', course: '1', rank: 4),
    });
    final from = tester.getCenter(inCheck('Pot stickers'));
    final to = dropBefore(tester, inCheck('Pot stickers'), inCheck('Walnut shrimp'));
    final hold = await holdRow(tester, inCheck('Pot stickers'));

    // while one is in hand, a tap picks a dish up instead of opening it, and a second tap puts it down
    await tester.tap(inCheck('Jasmine tea'));
    await tester.pump();
    expect(pickedUp(tester, 'Jasmine tea'), isTrue);
    expect(find.text(noChoices), findsNothing);
    expect(find.text('+1'), findsOneWidget); // on the dish in hand
    await tester.tap(inCheck('Scallion pancake'));
    await tester.pump();
    expect(find.text('+2'), findsOneWidget);
    await tester.tap(inCheck('Scallion pancake'));
    await tester.pump();
    expect(pickedUp(tester, 'Scallion pancake'), isFalse);
    expect(find.text('+1'), findsOneWidget);

    await carry(tester, hold, from, to);
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['set_line', 'set_line']);
    expect(ops[0]['data'], {'line_id': 'L3', 'course': '2', 'rank': 0.0}); // the tea first: it was above
    expect(ops[1]['data'], {'line_id': 'L1', 'course': '2', 'rank': 1.0});
    // under Entrees: the tea, the pot stickers, the shrimp; nothing is picked up any more
    final ys = [
      for (final f in [header('2'), inCheck('Jasmine tea'), inCheck('Pot stickers'), inCheck('Walnut shrimp')])
        tester.getCenter(f).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('+1'), findsNothing);
    expect(tester.widgetList<ListTile>(find.byType(ListTile)).any((tile) => tile.selected), isFalse);
    // and a tap opens a dish again
    await tester.tap(inCheck('Scallion pancake'));
    await tester.pump();
    expect(find.text(noChoices), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hold that is cut short puts every dish down', (tester) async {
    final t = await pumpOrder(tester, {
      'L1': line('Pot stickers', course: '1', rank: 1),
      'L3': line('Jasmine tea', course: 'drinks', rank: 3, fired: true),
    });
    final hold = await holdRow(tester, inCheck('Pot stickers'));
    await tester.tap(inCheck('Jasmine tea'));
    await tester.pump();
    expect(pickedUp(tester, 'Jasmine tea'), isTrue);
    expect(holdable(), findsNothing); // nothing else can be held while one is
    await hold.cancel();
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty);
    expect(pickedUp(tester, 'Jasmine tea'), isFalse);
    expect(holdable(), findsWidgets);
    await stop(tester);
  });
}
