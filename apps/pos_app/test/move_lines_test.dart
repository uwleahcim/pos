import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_order.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/line_ops.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'hub.dart';

/// Arranging the check: hold a dish and drag it to another place, or under another course. A line carries
/// its place (`set_line` with `rank`, and `course` when the course changes); a dish the kitchen already has
/// is voided and added again under the new course, after the operator confirms.

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

/// Holds a row of the check, drags it to [to] and lets go.
Future<void> dragRow(WidgetTester tester, Finder row, Offset to) async {
  final from = tester.getCenter(row);
  final gesture = await tester.startGesture(from);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  for (var i = 1; i <= 12; i++) {
    // in steps, so the list makes room as the row passes the others
    await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The whole row a dish's name is on.
Finder tileOf(Finder text) => find.ancestor(of: text, matching: find.byType(ListTile)).first;

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

  group('the operations a move sends', () {
    String newId() => 'N1';

    test('within its course: the place alone, sent or not', () {
      final egg = l('L1', 'Egg roll', course: '1', rank: 1, fired: true);
      final change = moveChange(egg, course: '1', rank: 2.5, newId: newId);
      expect(change.ops.map((op) => op.$1), ['set_line']);
      expect(change.ops.single.$2, {'line_id': 'L1', 'rank': 2.5});
      expect(change.voidsFired, isFalse);
      expect(moveChange(egg, course: '1', rank: 1, newId: newId).isEmpty, isTrue);
    });

    test('to another course before the kitchen has it: the course and the place', () {
      final egg = l('L1', 'Egg roll', course: '1', rank: 1);
      final change = moveChange(egg, course: '2', rank: 2.5, newId: newId);
      expect(change.ops.map((op) => op.$1), ['set_line']);
      expect(change.ops.single.$2, {'line_id': 'L1', 'course': '2', 'rank': 2.5});
      expect(change.voidsFired, isFalse);
      final none = moveChange(egg, course: null, rank: 1, newId: newId);
      expect(none.ops.single.$2, {'line_id': 'L1', 'course': null, 'rank': 1.0}); // the course comes off
    });

    test('to another course once sent: a void, and the dish again held for the new course', () {
      const egg = Line(
        lineId: 'L1',
        item: 'Egg roll',
        qty: 2,
        status: 'active',
        seat: 1,
        course: '1',
        rank: 1,
        note: 'crispy',
        fired: true,
      );
      final change = moveChange(egg, course: '2', rank: 2.5, newId: newId);
      expect(change.voidsFired, isTrue);
      expect(change.newLineId, 'N1');
      expect(change.ops.map((op) => op.$1), ['void_line', 'add_line']); // no fire: it goes when the entrees do
      expect(change.ops[0].$2, {'line_id': 'L1', 'reason': 'moved'});
      expect(change.ops[1].$2, {
        'line_id': 'N1',
        'item': 'Egg roll',
        'qty': 2,
        'seat': 1,
        'course': '2',
        'note': 'crispy',
        'rank': 2.5,
      });
      final uncoursed = moveChange(l('L2', 'x', course: '2', fired: true), course: null, rank: 9, newId: newId);
      expect(uncoursed.ops.last.$2.containsKey('course'), isFalse);
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

  testWidgets('a dish the kitchen has, dragged to another course, is voided and goes again with it', (tester) async {
    final t = await pumpOrder(tester, {
      'L1': line('Jasmine tea', course: 'drinks', rank: 1, fired: true),
      'L2': line('Walnut shrimp', course: '2', rank: 2),
    });
    final underDessert = tester.getCenter(header('3')) + const Offset(0, 30);
    await dragRow(tester, inCheck('Jasmine tea'), underDessert);
    expect(find.text('Void Jasmine tea and send it with Dessert?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty); // nothing changed, nothing sent
    expect(tester.getCenter(inCheck('Jasmine tea')).dy < tester.getCenter(header('1')).dy, isTrue); // back under Drinks

    await dragRow(tester, inCheck('Jasmine tea'), underDessert);
    await tester.tap(find.text('Void and move'));
    await tester.pumpAndSettle();
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['void_line', 'add_line']);
    expect(ops[0]['data'], {'line_id': 'L1', 'reason': 'moved'});
    final again = ops[1]['data'] as Map;
    expect((again['item'], again['course'], again['rank']), ('Jasmine tea', '3', 1.0));
    // the void stays on the check, struck through under Drinks; the new line waits under Dessert
    expect(inCheck('Jasmine tea'), findsNWidgets(2));
    expect(inCheck('void'), findsOneWidget);
    expect(tester.getCenter(inCheck('Jasmine tea').last).dy > tester.getCenter(header('3')).dy, isTrue);
    await stop(tester);
  });
}
