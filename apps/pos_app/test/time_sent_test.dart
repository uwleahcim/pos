import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_order.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'hub.dart';

/// Time sent, on the check ("where is my food"): each course's header says when the kitchen got it, and on
/// an open check how long ago; a dish that went later than its course says its own time under its name.
/// The time is the hub's (`sent_ms` on a line); a hub that does not say it changes nothing on the check.

int at(int hour, int minute, [int second = 0]) => DateTime(2026, 11, 16, hour, minute, second).millisecondsSinceEpoch;

Line l(String id, {String? course = '1', int? sent, String status = 'active'}) =>
    Line(lineId: id, item: id, qty: 1, status: status, course: course, fired: sent != null, sentMs: sent);

/// An order of [lines], on the check in the order they are listed.
Order orderOf(List<Line> lines) => Order(
  orderId: 'o1',
  status: 'open',
  fields: const {},
  lines: [for (final (i, line) in lines.indexed) line.copyWith(rank: i + 1.0)],
  fired: const {},
);

/// The time a course's header says, on the check.
Finder courseSent(String id) => find.byKey(ValueKey('course-sent:$id'));
String? saysCourse(WidgetTester tester, String id) =>
    courseSent(id).evaluate().isEmpty ? null : tester.widget<Text>(courseSent(id)).data;

/// The words under a dish that says its own time.
Finder lineSent(String lineId) =>
    find.descendant(of: find.byKey(ValueKey('sent:$lineId')), matching: find.byType(Text));
String? saysLine(WidgetTester tester, String lineId) =>
    lineSent(lineId).evaluate().isEmpty ? null : tester.widget<Text>(lineSent(lineId)).data;

Future<Terminal> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> lines, {
  required int Function() now,
  String status = 'open',
  Coursing coursing = Coursing.defaults,
  Size? size,
  Outbox Function(Terminal t)? outbox,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.hub.orders.add({...table('o1', lines), 'status': status});
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(
        api: t.api,
        outbox: outbox?.call(t) ?? t.outbox,
        photos: t.photos,
        orderId: 'o1',
        coursing: coursing,
        now: now,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('the words', () {
    test('say the time, and on an open check how long ago, in whole minutes by the clock', () {
      final sent = at(18, 42, 50);
      expect(sentWords(sent), 'sent 18:42');
      expect(sentWords(sent, nowMs: at(18, 42, 58)), 'sent 18:42, just now');
      expect(sentWords(sent, nowMs: at(18, 43, 5)), 'sent 18:42, 1 min ago'); // the clock says 18:43
      expect(sentWords(sent, nowMs: at(19, 5)), 'sent 18:42, 23 min ago');
      expect(sentWords(sent, nowMs: at(20, 41, 59)), 'sent 18:42, 119 min ago');
      expect(sentWords(sent, nowMs: at(20, 42)), 'sent 18:42, 2 h ago');
      expect(sentWords(sent, nowMs: at(20, 47)), 'sent 18:42, 2 h 5 min ago');
      expect(sentWords(at(9, 5), nowMs: at(9, 6)), 'sent 09:05, 1 min ago');
    });

    test('a screen whose clock is behind the one that sent says just now, never minutes to come', () {
      expect(sentWords(at(18, 42), nowMs: at(18, 40)), 'sent 18:42, just now');
    });
  });

  group('the rows of the check', () {
    List<String> said(List<CheckRow> rows) => [
      for (final row in rows)
        switch (row) {
          CourseRow r => '[${r.id} ${r.sentMs == null ? '-' : sentWords(r.sentMs!)}]',
          LineRow r => '${r.line.lineId} ${r.sentMs == null ? '-' : sentWords(r.sentMs!)}',
        },
    ];
    const two = Coursing(
      enabled: true,
      defaultCourse: '1',
      courses: [Course('1', 'Appetizers'), Course('2', 'Entrees')],
    );

    test('a header says when the first of its dishes went; a dish that went later says its own time', () {
      final rows = checkRows(
        orderOf([
          l('roll', sent: at(18, 42, 10)),
          l('soup', sent: at(18, 42, 40)), // a second fire within the minute: the header's time is its own
          l('wings', sent: at(18, 55)), // added after the appetizers went
          l('tea'), // not sent yet
          l('duck', course: '2'),
        ]),
        two,
      );
      expect(said(rows), ['[1 sent 18:42]', 'roll -', 'soup -', 'wings sent 18:55', 'tea -', '[2 -]', 'duck -']);
    });

    test('a void neither sets the header\'s time while a dish is left, nor says its own', () {
      final rows = checkRows(
        orderOf([
          l('roll', sent: at(18, 30), status: 'void'),
          l('soup', sent: at(18, 42)),
          l('duck', course: '2', sent: at(18, 50), status: 'void'),
        ]),
        two,
      );
      // the entrees hold only a void: the header still says when it went
      expect(said(rows), ['[1 sent 18:42]', 'roll -', 'soup -', '[2 sent 18:50]', 'duck -']);
    });

    test('a hub that does not say when a dish was sent leaves the check as it was', () {
      final sentOnly = Line(lineId: 'roll', item: 'roll', qty: 1, status: 'active', course: '1', fired: true);
      expect(said(checkRows(orderOf([sentOnly]), two)), ['[1 -]', 'roll -', '[2 -]']);
      expect(sentOf([sentOnly]), isNull);
    });

    test('a minute apart is what makes a dish say its own time', () {
      expect(sentApart(at(18, 42, 59), at(18, 42)), isFalse);
      expect(sentApart(at(18, 43), at(18, 42)), isTrue);
      expect(sentApart(null, at(18, 42)), isFalse);
      expect(sentApart(at(18, 43), null), isFalse);
    });
  });

  group('what the hub and the outbox say', () {
    test('a line reads when it was sent from the hub', () {
      final sent = Line.fromJson('L1', {'item': 'Duck', 'status': 'active', 'fired': true, 'sent_ms': at(18, 42)});
      expect((sent.fired, sent.sentMs), (true, at(18, 42)));
      final older = Line.fromJson('L1', {'item': 'Duck', 'status': 'active', 'fired': true});
      expect((older.fired, older.sentMs), (true, null));
    });

    test('a send still in the outbox is timed by this screen\'s stamp, and sends nothing twice', () {
      final order = orderOf([l('roll', sent: at(18, 42)), l('wings'), l('duck', course: '2')]);
      final stamp = '${at(18, 55).toString().padLeft(13, '0')}-0000-t1';
      final shown = withLocalOps(order, [
        {
          'kind': 'fire',
          'order_id': 'o1',
          'hlc': stamp,
          'data': {'course': '1'},
        },
      ]);
      final byId = {for (final line in shown.lines) line.lineId: line};
      expect(byId['roll']!.sentMs, at(18, 42)); // it had gone
      expect((byId['wings']!.fired, byId['wings']!.sentMs), (true, at(18, 55)));
      expect((byId['duck']!.fired, byId['duck']!.sentMs), (false, null));
    });
  });

  group('on the check', () {
    testWidgets('the header says when its course went and how long ago; a later dish says its own', (tester) async {
      await pumpOrder(tester, {
        'L1': line('Egg roll', course: '1', sentMs: at(18, 42)),
        'L2': line('Wonton soup', course: '1', sentMs: at(18, 42)),
        'L3': line('Wings', course: '1', sentMs: at(18, 55)),
        'L4': line('Spring roll', course: '1'),
        'L5': line('Duck', course: '2'),
      }, now: () => at(19, 5, 20));
      expect(saysCourse(tester, '1'), 'sent 18:42, 23 min ago');
      expect(find.text('1 to fire'), findsOneWidget); // the state keeps its badge beside the time
      expect(saysLine(tester, 'L3'), 'sent 18:55, 10 min ago');
      expect(saysLine(tester, 'L1'), isNull); // it went when the header says
      expect(saysLine(tester, 'L2'), isNull);
      expect(find.text('not sent yet'), findsOneWidget);
      expect(saysCourse(tester, '2'), isNull); // nothing of the entrees was sent
      expect(saysCourse(tester, '3'), isNull); // and nothing is under dessert
      await stop(tester);
    });

    testWidgets('how long ago moves on with the clock, while nothing about the order changes', (tester) async {
      var now = at(19, 5, 20);
      await pumpOrder(tester, {
        'L1': line('Egg roll', course: '1', sentMs: at(18, 42)),
        'L3': line('Wings', course: '1', sentMs: at(18, 55)),
      }, now: () => now);
      expect(saysCourse(tester, '1'), 'sent 18:42, 23 min ago');
      now = at(19, 6, 1);
      await tester.pump(const Duration(seconds: 5)); // the check looks at the clock every few seconds
      await tester.pump();
      expect(saysCourse(tester, '1'), 'sent 18:42, 24 min ago');
      expect(saysLine(tester, 'L3'), 'sent 18:55, 11 min ago');
      await stop(tester);
    });

    testWidgets('a dish says its time along with its other words', (tester) async {
      await pumpOrder(tester, {
        'L1': line('Egg roll', course: '1', sentMs: at(18, 42)),
        'L3': {...line('Wings', course: '1', sentMs: at(18, 55)), 'modified_after_fire': true, 'note': 'extra crispy'},
      }, now: () => at(19, 5));
      expect(saysLine(tester, 'L3'), 'sent 18:55, 10 min ago · added after fire · extra crispy');
      await stop(tester);
    });

    testWidgets('sending from this screen says the time at once, and the same once the hub has it', (tester) async {
      var now = at(18, 42, 5);
      final t = await pumpOrder(
        tester,
        {'L1': line('Egg roll', course: '1'), 'L2': line('Duck', course: '2')},
        now: () => now,
        outbox: (t) => Outbox(t.api, t.settings, store: MemoryStore(), now: () => now),
      );
      expect(saysCourse(tester, '1'), isNull);
      t.hub.down = true; // no hub answers: the send waits in the outbox
      await tester.tap(find.byTooltip('Fire'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fire Appetizers'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(saysCourse(tester, '1'), 'sent 18:42, just now');
      expect(saysCourse(tester, '2'), isNull);

      t.hub.down = false;
      now = at(18, 45);
      await tester.pump(const Duration(seconds: 30)); // the outbox tries again and the screen reads back
      await tester.pumpAndSettle();
      expect(((t.hub.orders.single['lines'] as Map)['L1'] as Map)['sent_ms'], at(18, 42, 5));
      expect(saysCourse(tester, '1'), 'sent 18:42, 3 min ago');
      await stop(tester);
    });

    testWidgets('a closed check says the time alone', (tester) async {
      await pumpOrder(
        tester,
        {'L1': line('Egg roll', course: '1', sentMs: at(18, 42)), 'L3': line('Wings', course: '1', sentMs: at(18, 55))},
        now: () => at(22, 0),
        status: 'closed',
      );
      expect(saysCourse(tester, '1'), 'sent 18:42');
      expect(saysLine(tester, 'L3'), 'sent 18:55');
      await stop(tester);
    });

    testWidgets('with coursing off the one header says it', (tester) async {
      await pumpOrder(
        tester,
        {'L1': line('Egg roll', sentMs: at(18, 42)), 'L2': line('Duck')},
        now: () => at(18, 50),
        coursing: const Coursing(enabled: false),
      );
      expect(find.text('Items'), findsOneWidget);
      expect(saysCourse(tester, ''), 'sent 18:42, 8 min ago');
      await stop(tester);
    });

    testWidgets('a hub that does not say the time leaves the header as it was', (tester) async {
      await pumpOrder(tester, {'L1': line('Egg roll', course: '1', fired: true)}, now: () => at(19, 5));
      expect(find.text('fired'), findsOneWidget);
      expect(find.textContaining('sent '), findsNothing);
      await stop(tester);
    });

    testWidgets('where the check is too narrow the time goes under the name, and nothing runs off', (tester) async {
      await pumpOrder(
        tester,
        {
          'L1': line('Egg roll', course: 'long', sentMs: at(16, 42)),
          'L2': line('Wings', course: 'long'),
          'L3': line('Wings', course: 'long'),
          'L4': line('Duck', course: 'none'),
        },
        now: () => at(19, 5),
        size: const Size(360, 740),
        coursing: const Coursing(
          enabled: true,
          defaultCourse: 'long',
          courses: [Course('long', 'Soups, salads and small plates to share'), Course('none', 'Entrees')],
        ),
      );
      await tester.tap(find.textContaining('Check'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // nothing overflowed
      expect(saysCourse(tester, 'long'), 'sent 16:42, 2 h 23 min ago');
      expect(find.text('2 to fire'), findsOneWidget);
      final row = tester.getRect(find.byKey(const ValueKey('course-row:long')));
      final name = tester.getRect(find.text('Soups, salads and small plates to share'));
      final time = tester.getRect(courseSent('long'));
      final badge = tester.getRect(find.text('2 to fire'));
      expect(time.top >= name.bottom, isTrue); // under the name
      for (final part in [name, time, badge]) {
        expect(part.left >= row.left && part.right <= row.right, isTrue);
        expect(part.top >= row.top && part.bottom <= row.bottom, isTrue);
      }
      expect(name.right <= badge.left && time.right <= badge.left, isTrue); // the state keeps its corner
      // a header with no time to say stays as low as it was
      expect(tester.getSize(find.byKey(const ValueKey('course-row:none'))).height, lessThan(row.height));
      await stop(tester);
    });
  });
}
