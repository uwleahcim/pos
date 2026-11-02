import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_order.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/line_ops.dart';
import 'package:pos_app/screens/check_list.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'hub.dart';

/// Arranging the check: hold a dish and it lifts into a stack in hand; drag it to another place, or under
/// another course; while it is held, tap other dishes and they fold out of the list and stack under it, each
/// a little behind and below the one before, so the stack stays short. The rows make room for the stack
/// where it would land, and once let go it comes down onto that room and unstacks into full rows, the rows
/// around it moving apart to fit them, the lines taking their places in the order they are stacked. A line
/// carries its place (`set_line` with `rank`, and `course` when the course changes), sent to the kitchen or
/// not: a dish the kitchen has keeps its place on the ticket it went out on (Mike, 2026-11-02).

Line l(String id, String item, {String? course, double rank = 0, bool fired = false}) =>
    Line(lineId: id, item: item, qty: 1, status: 'active', course: course, rank: rank, fired: fired);

Order orderOf(List<Line> lines) =>
    Order(orderId: 'o1', status: 'open', fields: const {}, lines: lines, fired: const {});

String rowOf(CheckRow row) => switch (row) {
  CourseRow r => '[${r.name}${r.state.isEmpty ? '' : ' ${r.state}'}]',
  LineRow r => r.line.item,
};

Finder header(String id) => find.byKey(ValueKey('course-row:$id'));

/// Text on the check: in its rows, or in the stack in hand.
Finder inCheck(String text) => find.descendant(of: find.byKey(const ValueKey('check-rows')), matching: find.text(text));

/// Text in the rows of the check (the list under a stack in hand).
Finder inList(String text) => find.descendant(of: find.byKey(const ValueKey('check-list')), matching: find.text(text));

/// Text in the stack in hand.
Finder inStack(String text) => find.descendant(of: stack(), matching: find.text(text));

Finder stack() => find.byKey(const ValueKey('check-stack'));

/// The dishes on the check that can be held and dragged (none while one is in hand).
Finder holdable() => find.descendant(of: find.byKey(const ValueKey('check-rows')), matching: find.byType(HoldToDrag));

/// How tall a line's row on the check is: nothing while the line is in hand.
double rowHeight(WidgetTester tester, String lineId) =>
    tester.getSize(find.byKey(ValueKey('check-row:line:$lineId'))).height;

/// How much room the rows leave between a course's header and the line under it.
double roomUnder(WidgetTester tester, String courseId, String lineId) =>
    tester.getTopLeft(find.byKey(ValueKey('check-row:line:$lineId'))).dy - tester.getBottomLeft(header(courseId)).dy;

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

/// Lets the rows fold away, make room or come back after a tap: the frame that starts it, then its time.
Future<void> settleRows(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Holds a row by the dish's name until it lifts.
Future<TestGesture> holdRow(WidgetTester tester, Finder row) async {
  final gesture = await tester.startGesture(tester.getCenter(row));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  return gesture;
}

/// Carries what is in hand from [from] to [to] in steps, so the rows make room as it passes them.
Future<void> moveTo(WidgetTester tester, TestGesture gesture, Offset from, Offset to) async {
  for (var i = 1; i <= 12; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Carries what is in hand from [from] to [to] and lets go.
Future<void> carry(WidgetTester tester, TestGesture gesture, Offset from, Offset to) async {
  await moveTo(tester, gesture, from, to);
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Taps a dish stacked in hand on the part of its card that shows under the one in front of it.
Future<void> tapStacked(WidgetTester tester, String text) async {
  final card = tileOf(inStack(text));
  final size = tester.getSize(card);
  await tester.tapAt(tester.getBottomLeft(card) + Offset(size.width / 2, -(size.height - CheckList.cover) / 2));
}

/// Holds a row of the check, drags it to [to] and lets go.
Future<void> dragRow(WidgetTester tester, Finder row, Offset to) async {
  final from = tester.getCenter(row);
  await carry(tester, await holdRow(tester, row), from, to);
}

/// The whole row a dish's name is on.
Finder tileOf(Finder text) => find.ancestor(of: text, matching: find.byType(ListTile)).first;

/// Where to let go of a dish held by its name so that its row lands just before [target]'s: the room the
/// rows open for it there (above the target going down, in the target's place going up).
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

    test('tell a course from a line', () {
      final rows = checkRows(orderOf([l('L1', 'Duck', course: '2')]), Coursing.defaults);
      expect(rows.map((r) => r.rowId), ['course:drinks', 'course:1', 'course:2', 'line:L1', 'course:3']);
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

  group('where a stack in hand lands', () {
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

    test('the lines land in the order they are stacked, spread between the neighbours of the room', () {
      // the duck in hand with the spring roll under it, let go between the egg roll and the wonton
      final drop = dropOf(rows, held: 'L4', picked: ['L2'], at: 3);
      expect(drop.course, '1');
      expect(ids(drop), ['L4', 'L2']);
      expect(drop.ranks, [2.0, 3.0]); // between the egg roll (1) and the wonton (4)
      expect(drop.at, 3);
    });

    test('as they were picked up, not as the check had them', () {
      final drop = dropOf(rows, held: 'L4', picked: ['L3', 'L1'], at: 5); // under Dessert
      expect(drop.course, '3');
      expect(ids(drop), ['L4', 'L3', 'L1']);
      expect(drop.ranks, [6.0, 7.0, 8.0]); // alone under the header: the first keeps its rank, the rest follow
    });

    test('at the top of a course: all before its first dish', () {
      final drop = dropOf(rows, held: 'L4', picked: ['L1'], at: 2); // before the spring roll
      expect(ids(drop), ['L4', 'L1']);
      expect(drop.ranks, [0.0, 1.0]);
      expect(drop.at, 2);
    });

    test('let go where it was, with others picked up: they gather to it', () {
      final drop = dropOf(rows, held: 'L2', picked: ['L4'], at: 3); // the spring roll held in place
      expect(drop.course, '1');
      expect(ids(drop), ['L2', 'L4']);
      expect(drop.ranks, [2.0, 3.0]); // between the egg roll (1) and the wonton (4)
    });

    test('one line alone lands as a plain drop', () {
      final drop = dropOf(rows, held: 'L4', at: 3);
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

  testWidgets('a held dish lifts into a stack; dishes tapped join it, the rows make room, and all land together', (
    tester,
  ) async {
    final t = await pumpOrder(tester, {
      'L1': line('Pot stickers', course: '1', rank: 1),
      'L2': line('Walnut shrimp', course: '2', rank: 2),
      'L3': line('Jasmine tea', course: 'drinks', rank: 3, fired: true),
      'L4': line('Scallion pancake', course: '1', rank: 4),
    });
    final pot = inCheck('Pot stickers');
    final from = tester.getCenter(pot);
    final potHeight = rowHeight(tester, 'L1');
    final teaHeight = rowHeight(tester, 'L3');
    final pancakeHeight = rowHeight(tester, 'L4');

    // held, the dish lifts off the check into a stack in hand, its room left behind under it
    final hold = await holdRow(tester, pot);
    expect(inStack('Pot stickers'), findsOneWidget);
    expect(rowHeight(tester, 'L1'), 0);
    expect(roomUnder(tester, '1', 'L4'), moreOrLessEquals(potHeight, epsilon: 0.5));
    expect(holdable(), findsNothing); // nothing else can be held while one is

    // a tap on another dish picks it up instead of opening it: its row folds away and it stacks behind the
    // one in hand, its top edge under that card and the rest showing, so the stack grows by less than a row
    // and the dish's name can still be read; the rows make room for the stack
    await tester.tap(inList('Jasmine tea'));
    await settleRows(tester);
    expect(find.text(noChoices), findsNothing);
    expect(inStack('Jasmine tea'), findsOneWidget);
    expect(rowHeight(tester, 'L3'), 0);
    final stackHeight = tester.getSize(stack()).height;
    expect(stackHeight, moreOrLessEquals(potHeight + teaHeight - CheckList.cover, epsilon: 0.5));
    final potCardBottom = tester.getBottomLeft(tileOf(inStack('Pot stickers'))).dy;
    expect(
      tester.getBottomLeft(tileOf(inStack('Jasmine tea'))).dy - potCardBottom,
      moreOrLessEquals(teaHeight - CheckList.cover, epsilon: 0.5),
    );
    expect(tester.getTopLeft(inStack('Jasmine tea')).dy, greaterThanOrEqualTo(potCardBottom - 4)); // readable
    // the room stays where it was, and the stack stays on its room as the rows above close over the tea's
    expect(roomUnder(tester, '1', 'L4'), moreOrLessEquals(stackHeight, epsilon: 0.5));
    expect(tester.getTopLeft(stack()).dy, moreOrLessEquals(tester.getBottomLeft(header('1')).dy, epsilon: 0.5));

    // a tap on the showing part of a stacked dish puts it back
    await tester.tap(inList('Scallion pancake'));
    await settleRows(tester);
    expect(inStack('Scallion pancake'), findsOneWidget);
    expect(rowHeight(tester, 'L4'), 0);
    // each card behind adds all but its covered top edge
    final deck = potHeight + (teaHeight - CheckList.cover) + (pancakeHeight - CheckList.cover);
    expect(tester.getSize(stack()).height, moreOrLessEquals(deck, epsilon: 0.5));
    await tapStacked(tester, 'Scallion pancake');
    await settleRows(tester);
    expect(inStack('Scallion pancake'), findsNothing);
    expect(rowHeight(tester, 'L4'), moreOrLessEquals(pancakeHeight, epsilon: 0.5));
    expect(tester.getSize(stack()).height, moreOrLessEquals(stackHeight, epsilon: 0.5));

    // let go with the foot of the stack just above the shrimp: it comes down there, under Entrees, and
    // unstacks into full rows, the room opening for them as it does; the tea lands under the pot stickers
    // as stacked
    final shrimpTop = tester.getTopLeft(tileOf(inList('Walnut shrimp'))).dy;
    final stackTop = tester.getTopLeft(stack()).dy;
    await moveTo(tester, hold, from, from + Offset(0, shrimpTop - stackHeight - stackTop));
    await hold.up();
    await tester.pump();
    await tester.pump(CheckList.land ~/ 2);
    final flat = potHeight + teaHeight;
    expect(tester.getSize(stack()).height, inExclusiveRange(stackHeight, flat));
    expect(
      tester.getTopLeft(tileOf(inList('Walnut shrimp'))).dy - tester.getBottomLeft(header('2')).dy,
      inExclusiveRange(stackHeight, flat),
    );
    await tester.pumpAndSettle();
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['set_line', 'set_line']);
    expect(ops[0]['data'], {'line_id': 'L1', 'course': '2', 'rank': 0.0});
    expect(ops[1]['data'], {'line_id': 'L3', 'course': '2', 'rank': 1.0});
    final ys = [
      for (final f in [header('2'), inCheck('Pot stickers'), inCheck('Jasmine tea'), inCheck('Walnut shrimp')])
        tester.getCenter(f).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(stack(), findsNothing);
    expect(holdable(), findsWidgets);
    // and a tap opens a dish again
    await tester.tap(inCheck('Scallion pancake'));
    await tester.pump();
    expect(find.text(noChoices), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hold that is cut short puts every dish back', (tester) async {
    final t = await pumpOrder(tester, {
      'L1': line('Pot stickers', course: '1', rank: 1),
      'L3': line('Jasmine tea', course: 'drinks', rank: 3, fired: true),
    });
    final potHeight = rowHeight(tester, 'L1');
    final teaHeight = rowHeight(tester, 'L3');
    final hold = await holdRow(tester, inCheck('Pot stickers'));
    await tester.tap(inList('Jasmine tea'));
    await settleRows(tester);
    expect(inStack('Jasmine tea'), findsOneWidget);
    // the room (under Appetizers, above the Entrees header) is still there, grown for the tea's card
    expect(
      tester.getTopLeft(header('2')).dy - tester.getBottomLeft(header('1')).dy,
      moreOrLessEquals(potHeight + teaHeight - CheckList.cover, epsilon: 0.5),
    );
    expect(tester.getTopLeft(stack()).dy, moreOrLessEquals(tester.getBottomLeft(header('1')).dy, epsilon: 0.5));
    // put back, the tea opens its row above the stack again, and the stack goes down with its room
    await tapStacked(tester, 'Jasmine tea');
    await settleRows(tester);
    expect(inStack('Jasmine tea'), findsNothing);
    expect(rowHeight(tester, 'L3'), moreOrLessEquals(teaHeight, epsilon: 0.5));
    expect(tester.getSize(stack()).height, moreOrLessEquals(potHeight, epsilon: 0.5));
    expect(tester.getTopLeft(stack()).dy, moreOrLessEquals(tester.getBottomLeft(header('1')).dy, epsilon: 0.5));
    await tester.tap(inList('Jasmine tea'));
    await settleRows(tester);
    expect(inStack('Jasmine tea'), findsOneWidget);
    await hold.cancel();
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty);
    expect(stack(), findsNothing);
    expect(rowHeight(tester, 'L3'), moreOrLessEquals(teaHeight, epsilon: 0.5));
    expect(holdable(), findsWidgets);
    await stop(tester);
  });
}
