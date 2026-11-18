import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/kitchen_word.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/settings.dart';

import 'hub.dart';
import 'my_tables_test.dart' show amyOnStaff, busyFloor, myTables;
import 'table_timers_test.dart' show minute;
import 'time_sent_test.dart' show at, lineSent, pumpOrder, saysLine;

/// What the servers see of the kitchen (docs/kitchen-screens.md): a dish every station that cooks it marked
/// made says "ready" on its check and is counted on its table, until the pass or the server who carried it
/// says it went out. The hub reads the cooks' marks (`kitchen` on a line, `ready` on a table's check); a
/// kitchen that marks nothing, and a hub older than the words, leave every screen as it was.

/// The kitchen's word on a line as the hub sends it: ready at [ready], gone out at [out], cooked at [cooks]
/// (a name alone has made its part; one that ends in "?" is still working on it).
Map<String, dynamic> word({int? ready, int? out, List<String> cooks = const ['Wok']}) => {
  'cooks': [
    for (final cook in cooks)
      {
        'code': cook.replaceAll('?', '').toLowerCase(),
        'name': cook.replaceAll('?', ''),
        'made': out != null || !cook.endsWith('?'),
      },
  ],
  'ready_ms': ?ready,
  'out_ms': ?out,
};

Map<String, dynamic> dish(String item, {int qty = 1, int? sent, Map<String, dynamic>? kitchen}) => {
  ...line(item, course: '1', sentMs: sent),
  'qty': qty,
  'kitchen': ?kitchen,
};

final strip = find.byKey(const ValueKey('ready-strip'));
final wentOut = find.byKey(const ValueKey('went-out'));

String? stripSays(WidgetTester tester) => strip.evaluate().isEmpty
    ? null
    : tester.widget<Text>(find.descendant(of: strip, matching: find.textContaining('Ready:'))).data;

/// The kitchen's word under a dish on the check, and whether it is the green of food that waits.
Finder saidOf(String lineId) =>
    find.descendant(of: find.byKey(ValueKey('kitchen:$lineId')), matching: find.byType(Text));
String? says(WidgetTester tester, String lineId) =>
    saidOf(lineId).evaluate().isEmpty ? null : tester.widget<Text>(saidOf(lineId)).data;
bool green(WidgetTester tester, String lineId) =>
    tester.widget<Text>(saidOf(lineId)).style?.fontWeight == FontWeight.w700;

/// The `done` operations the terminal sent the hub, in words: who is named, the dishes, and "back" for
/// one that takes the word back.
List<String> marksSent(Hub hub) => [
  for (final op in hub.opsFor('o1'))
    if (op['kind'] == 'done')
      [
        (op['data'] as Map)['station'],
        ((op['data'] as Map)['line_ids'] as List).join('+'),
        if ((op['data'] as Map)['done'] == false) 'back',
      ].join(' '),
];

/// The floor at [now] with dishes ready at Amy's A7 ([a7], made [a7Ago] minutes ago) and at Ben's A8.
Map<String, dynamic> floorWith(int now, {int a7 = 0, int a7Ago = 1, int a8 = 0, int a8Ago = 1}) {
  final floor = busyFloor(now);
  void put(String table, int ready, int ago) {
    if (ready == 0) return;
    ((floor['status'] as Map)[table] as List).first
      ..['ready'] = ready
      ..['ready_ms'] = now - ago * minute;
  }

  put('A7', a7, a7Ago);
  put('A8', a8, a8Ago);
  return floor;
}

Finder badge(String table) => find.byKey(ValueKey('ready-badge:$table'));
String? badgeSays(WidgetTester tester, String table) => badge(table).evaluate().isEmpty
    ? null
    : tester.widget<Text>(find.descendant(of: badge(table), matching: find.byType(Text))).data;

/// The map by itself on the clock [now], reading [floor] from a hub that names its answers as hubs do:
/// asked again with nothing new, it says "the one you have" and the map keeps it. The hub is handed back,
/// for a test that changes what is on the floor.
Future<Hub> pumpMap(
  WidgetTester tester, {
  required Map<String, dynamic> floor,
  required int Function() now,
  StaffMember? me,
  bool mine = false,
  Size size = const Size(1200, 900),
  ThemeData? theme,
}) async {
  final hub = Hub()..floor = floor;
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient(hub.handle),
  );
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? PosTheme.light(),
      home: Scaffold(
        body: FloorView(api: api, onTable: (plan, table) {}, me: me, mine: mine, now: now),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return hub;
}

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers

void main() {
  group('the word', () {
    test('reads what the hub says of a dish, and nothing where it says nothing', () {
      final ready = KitchenWord.fromJson(word(ready: at(18, 50)))!;
      expect((ready.readyMs, ready.outMs, ready.isReady, ready.isOut), (at(18, 50), null, true, false));
      expect(ready.cooks.single, (name: 'Wok', made: true));
      expect(ready.words, 'ready 18:50');
      final out = KitchenWord.fromJson(word(ready: at(18, 50), out: at(18, 52)))!;
      expect((out.isReady, out.isOut, out.words), (false, true, 'went out 18:52'));
      expect(KitchenWord.fromJson(null), isNull);
      expect(KitchenWord.fromJson('made'), isNull);
      expect(Line.fromJson('L1', line('Duck')).kitchen, isNull); // a kitchen on paper, an older hub
      expect(Line.fromJson('L1', dish('Duck', kitchen: word(ready: at(18, 50)))).kitchen?.words, 'ready 18:50');
    });

    test('a dish of two stations says which has made its part and which it waits on', () {
      final half = KitchenWord.fromJson(word(cooks: ['Sushi bar?', 'Wok']))!;
      expect((half.isReady, half.words), (false, 'Wok ready · waiting on Sushi bar'));
      final three = KitchenWord.fromJson(word(cooks: ['Fryer', 'Sushi bar?', 'Wok']))!;
      expect(three.words, 'Fryer, Wok ready · waiting on Sushi bar');
      // nothing made anywhere and nothing gone: nothing to say (the hub sends no such word)
      expect(KitchenWord.fromJson(word(cooks: ['Wok?']))!.words, isNull);
      // sent out from the pass with nowhere it is cooked: it went out all the same
      expect(KitchenWord.fromJson(word(out: at(19, 5), cooks: const []))!.words, 'went out 19:05');
    });

    test('is pointed at for a quarter of an hour after the dish was made, and not once it went out', () {
      final ready = KitchenWord.fromJson(word(ready: at(18, 50)))!;
      expect(ready.waitsAt(at(18, 50)), isTrue);
      expect(ready.waitsAt(at(19, 4, 59)), isTrue);
      expect(ready.waitsAt(at(19, 5)), isFalse); // eaten long ago, or nobody is coming: the dish keeps its words
      expect(readyShownMs, 15 * minute);
      expect(ready.out(at(18, 52)).waitsAt(at(18, 53)), isFalse);
      expect(KitchenWord.fromJson(word(cooks: ['Sushi bar?', 'Wok']))!.waitsAt(at(18, 50)), isFalse);
    });

    test('a server\'s "went out" still in the outbox shows on the check at once, and so does taking it back', () {
      final order = Order.fromJson(
        table('o1', {
          'L1': dish(
            'Duck',
            sent: at(18, 42),
            kitchen: word(ready: at(18, 50)),
          ),
          'L2': dish(
            'Rice',
            sent: at(18, 42),
            kitchen: word(ready: at(18, 51)),
          ),
          'L3': dish('Tea', sent: at(18, 42)),
        }),
      );
      Map<String, dynamic> said(int when, List<String> ids, {bool done = true, String station = passStation}) => {
        'kind': 'done',
        'order_id': 'o1',
        'hlc': '${when.toString().padLeft(13, '0')}-0000-t1',
        'data': {'station': station, 'line_ids': ids, if (!done) 'done': false},
      };
      Map<String, KitchenWord?> words(List<Map<String, dynamic>> ops) => {
        for (final line in withLocalOps(order, ops).lines) line.lineId: line.kitchen,
      };

      final gone = words([
        said(at(18, 53), ['L1', 'L3', 'nothing-of-this-check']),
      ]);
      expect((gone['L1']!.outMs, gone['L1']!.readyMs), (at(18, 53), at(18, 50)));
      expect(gone['L2']!.isReady, isTrue); // not named: still waiting
      expect(gone['L3'], isNull); // the kitchen never spoke of it: a server's word alone makes none up
      final back = words([
        said(at(18, 53), ['L1']),
        said(at(18, 54), ['L1'], done: false),
      ]);
      expect(back['L1']!.isReady, isTrue);
      // a station's own word is the hub's to read: this screen guesses nothing from it
      expect(
        words([
          said(at(18, 53), ['L2'], station: 'wok', done: false),
        ])['L2']!.isReady,
        isTrue,
      );
    });
  });

  group('on the check', () {
    testWidgets('a dish the kitchen made says ready, in green, and a strip names what waits to be carried', (
      tester,
    ) async {
      final t = await pumpOrder(tester, {
        'L1': dish(
          'Peking duck',
          sent: at(18, 42),
          kitchen: word(ready: at(18, 50)),
        ),
        'L2': dish(
          'Fried rice',
          qty: 2,
          sent: at(18, 42),
          kitchen: word(ready: at(18, 51)),
        ),
        'L3': dish('Wonton soup', sent: at(18, 42)),
      }, now: () => at(18, 53));
      expect(stripSays(tester), 'Ready: Peking duck, 2 × Fried rice');
      expect(says(tester, 'L1'), 'ready 18:50');
      expect(green(tester, 'L1'), isTrue);
      expect(says(tester, 'L2'), 'ready 18:51');
      expect(says(tester, 'L3'), isNull); // still in the kitchen: its words are as they always were
      expect(saidOf('L3'), findsNothing);
      expect(marksSent(t.hub), isEmpty); // looking marks nothing
      await stop(tester);
    });

    testWidgets('how long ago a dish was sent stops counting once it is ready', (tester) async {
      await pumpOrder(tester, {
        // (dishes that went later than the first of their course say their own time)
        'L0': dish('Tea', sent: at(18, 40)),
        'L1': dish(
          'Peking duck',
          sent: at(18, 42),
          kitchen: word(ready: at(18, 50)),
        ),
        'L2': dish('Wonton soup', sent: at(18, 44)),
        'L3': dish(
          'Egg roll',
          sent: at(18, 46),
          kitchen: word(cooks: ['Fryer', 'Wok?']),
        ),
        'L4': dish(
          'Fried rice',
          sent: at(18, 47),
          kitchen: word(ready: at(18, 49), out: at(18, 51)),
        ),
      }, now: () => at(18, 53));
      expect(saysLine(tester, 'L1'), 'sent 18:42');
      expect(saysLine(tester, 'L2'), 'sent 18:44, 9 min ago'); // the table still waits for it
      expect(saysLine(tester, 'L3'), 'sent 18:46, 7 min ago'); // and for this one: half of it is not made
      expect(says(tester, 'L3'), 'Fryer ready · waiting on Wok');
      expect(green(tester, 'L3'), isFalse); // nothing to carry yet
      expect(saysLine(tester, 'L4'), 'sent 18:47');
      expect(says(tester, 'L4'), 'went out 18:51');
      expect(stripSays(tester), 'Ready: Peking duck');
      expect(lineSent('L1'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Went out says so with the pass\'s word, at once, and Undo takes it back', (tester) async {
      // (a terminal somebody is signed in at: the word says who carried the dishes)
      final t = await terminal(tester);
      t.hub.orders.add(
        table('o1', {
          'L1': dish(
            'Peking duck',
            sent: at(18, 42),
            kitchen: word(ready: at(18, 50)),
          ),
          'L2': dish(
            'Fried rice',
            qty: 2,
            sent: at(18, 42),
            kitchen: word(ready: at(18, 51)),
          ),
          'L3': dish('Wonton soup', sent: at(18, 42)),
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(
            api: t.api,
            outbox: t.outbox,
            photos: t.photos,
            orderId: 'o1',
            coursing: Coursing.defaults,
            session: t.session,
            now: () => at(18, 53),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = t.hub.check;
      await tester.tap(wentOut);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(strip, findsNothing);
      expect(marksSent(t.hub), ['*pass L1+L2']);
      final sent = t.hub.opsFor('o1').single;
      expect(((sent['data'] as Map)['by'], (sent['data'] as Map)['by_id']), ('Mike', 's3')); // who carried it
      expect(find.text('3 dishes went out.'), findsOneWidget);
      expect(says(tester, 'L1'), startsWith('went out '));
      expect(green(tester, 'L1'), isFalse); // history now, not a call for a hand
      expect(t.hub.check, same(before)); // nothing of the check is touched

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(marksSent(t.hub), ['*pass L1+L2', '*pass L1+L2 back']);
      expect(stripSays(tester), 'Ready: Peking duck, 2 × Fried rice');
      expect(says(tester, 'L1'), 'ready 18:50');
      await stop(tester);
    });

    testWidgets('a dish that waited a quarter of an hour leaves the strip by itself and keeps its words', (
      tester,
    ) async {
      var now = at(18, 53);
      await pumpOrder(tester, {
        'L1': dish(
          'Peking duck',
          sent: at(18, 42),
          kitchen: word(ready: at(18, 50)),
        ),
        'L2': dish(
          'Fried rice',
          sent: at(18, 42),
          kitchen: word(ready: at(18, 58)),
        ),
      }, now: () => now);
      expect(stripSays(tester), 'Ready: Peking duck, Fried rice');
      now = at(19, 5);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(stripSays(tester), 'Ready: Fried rice');
      expect(says(tester, 'L1'), 'ready 18:50');
      now = at(19, 13);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(strip, findsNothing);
      expect(says(tester, 'L2'), 'ready 18:58');
      await stop(tester);
    });

    testWidgets('the kitchen\'s word arrives on an open check without a tap', (tester) async {
      final t = await pumpOrder(tester, {'L1': dish('Peking duck', sent: at(18, 42))}, now: () => at(18, 53));
      expect(strip, findsNothing);
      ((t.hub.orders.single['lines'] as Map)['L1'] as Map)['kitchen'] = word(ready: at(18, 52));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump();
      expect(stripSays(tester), 'Ready: Peking duck');
      expect(says(tester, 'L1'), 'ready 18:52');
      await stop(tester);
    });

    testWidgets('a closed check, a voided dish and a kitchen that says nothing show no strip', (tester) async {
      await pumpOrder(
        tester,
        {
          'L1': dish(
            'Peking duck',
            sent: at(18, 42),
            kitchen: word(ready: at(18, 50)),
          ),
        },
        now: () => at(18, 53),
        status: 'closed',
      );
      expect(strip, findsNothing);
      expect(says(tester, 'L1'), 'ready 18:50'); // what the kitchen said stays on the record of the evening
      expect(green(tester, 'L1'), isFalse); // and calls nobody: the table has left
      await stop(tester);
    });

    testWidgets('on a small phone with large text the strip keeps its button and wraps its dishes', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpOrder(
        tester,
        {
          'L1': dish(
            "General Tso's chicken with broccoli",
            sent: at(18, 42),
            kitchen: word(ready: at(18, 50)),
          ),
          'L2': dish(
            'House special fried rice',
            qty: 2,
            sent: at(18, 42),
            kitchen: word(ready: at(18, 51)),
          ),
          'L3': dish(
            'Beef chow fun',
            sent: at(18, 42),
            kitchen: word(ready: at(18, 51)),
          ),
        },
        now: () => at(18, 53),
        size: const Size(320, 568),
      );
      expect(tester.takeException(), isNull);
      expect(stripSays(tester), startsWith("Ready: General Tso's chicken"));
      final button = tester.getRect(wentOut);
      expect(button.right, lessThanOrEqualTo(320));
      expect(tester.getSize(strip).height, lessThan(80)); // two lines of dishes at most: the check keeps the screen
      await stop(tester);
    });
  });

  group('on the floor map', () {
    test('a check says how many dishes are ready, and the map points at them for a quarter of an hour', () {
      final now = at(18, 53);
      final plan = FloorPlan.fromJson(floorWith(now, a7: 2, a7Ago: 3, a8: 1, a8Ago: 20));
      final a7 = plan.checksAt('A7').single;
      expect((a7.ready, a7.readyMs), (2, now - 3 * minute));
      expect((plan.readyAt('A7', now), plan.readyAt('A7', now + 11 * minute)), (2, 2));
      expect(plan.readyAt('A7', now + 12 * minute), 0);
      expect(plan.readyAt('A8', now), 0); // made twenty minutes ago: nobody is still looking for it
      expect(plan.readyAt('B5', now), 0);
      expect(plan.checksAt('B5').single.ready, 0); // a hub that says nothing: nothing ready
      // handed to another server, the check keeps what is ready for it
      expect(a7.servedBy('Ben', 's2').readyAt(now), 2);
    });

    testWidgets('a table with food ready wears a badge on its lower edge, beside its countdown\'s', (tester) async {
      var now = DateTime(2026, 11, 16, 18, 53).millisecondsSinceEpoch;
      final start = now;
      await pumpMap(tester, floor: floorWith(start, a7: 2, a7Ago: 13), now: () => now);
      expect(badgeSays(tester, 'A7'), '2 ready');
      expect(badge('A8'), findsNothing);
      expect(badge('B5'), findsNothing);
      // under the table, clear of the countdown's badge on its upper edge
      final table = tester.getRect(find.byKey(const ValueKey('A7')));
      final ready = tester.getRect(badge('A7'));
      expect(ready.center.dy, greaterThan(table.center.dy));
      expect((ready.center.dx - table.center.dx).abs(), lessThan(1));
      final countdown = find.byKey(const ValueKey('timer-badge:A7'));
      expect(countdown, findsOneWidget); // a course held 16 minutes: the table wears both at once
      expect(tester.getRect(countdown).overlaps(ready), isFalse);

      // only the badge follows the clock: once the food has waited a quarter of an hour it is gone, and no
      // table was drawn again for it
      final rebuilt = <String>{};
      debugOnRebuildDirtyWidget = (element, builtOnce) => rebuilt.add(element.widget.runtimeType.toString());
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      now = start + minute;
      await tester.pump(const Duration(seconds: 1));
      expect(badgeSays(tester, 'A7'), '2 ready');
      now = start + 2 * minute;
      await tester.pump(const Duration(seconds: 1));
      expect(badge('A7'), findsNothing);
      expect(rebuilt, isNot(contains('_TablePositioned')));
      debugOnRebuildDirtyWidget = null;
      await stop(tester);
    });

    testWidgets('the badge goes when the dishes went out, and a floor with none is as it was', (tester) async {
      final now = DateTime(2026, 11, 16, 18, 53).millisecondsSinceEpoch;
      final hub = await pumpMap(tester, floor: floorWith(now, a7: 1, a8: 3), now: () => now);
      expect((badgeSays(tester, 'A7'), badgeSays(tester, 'A8')), ('1 ready', '3 ready'));
      hub.floor = floorWith(now, a8: 1); // A7's went out, and two of A8's
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump();
      expect((badgeSays(tester, 'A7'), badgeSays(tester, 'A8')), (null, '1 ready'));
      hub.floor = busyFloor(now); // a kitchen on paper
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('ready'), findsNothing);
      await stop(tester);
    });

    testWidgets('with "Mine" on, her list says her food is ready and another server\'s badge fades', (tester) async {
      final now = DateTime(2026, 11, 16, 18, 53).millisecondsSinceEpoch;
      await pumpMap(tester, floor: floorWith(now, a7: 2, a8: 1), now: () => now, me: amyOnStaff, mine: true);
      expect(myTables, findsOneWidget);
      final row = find.byKey(const ValueKey('my-table-ready:A7'));
      expect(find.descendant(of: row, matching: find.text('2 dishes ready')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-table-ready:A8')), findsNothing); // Ben's table is not in her list
      double seen(String table) {
        final faded = find.ancestor(of: badge(table), matching: find.byType(Opacity));
        return faded.evaluate().isEmpty ? 1 : tester.widget<Opacity>(faded.first).opacity;
      }

      expect(seen('A7'), 1);
      expect(seen('A8'), lessThan(1));
      await stop(tester);
    });

    testWidgets('one dish reads "1 dish ready" in the list, and the badge reads in the dark', (tester) async {
      final now = DateTime(2026, 11, 16, 18, 53).millisecondsSinceEpoch;
      await pumpMap(
        tester,
        floor: floorWith(now, a7: 1),
        now: () => now,
        me: amyOnStaff,
        mine: true,
        theme: PosTheme.dark(),
      );
      expect(find.text('1 dish ready'), findsOneWidget);
      final text = tester.widget<Text>(find.descendant(of: badge('A7'), matching: find.byType(Text)));
      expect(text.style?.color, isSameColorAs(PosColors.dark.fired)); // dark ink on the bright green
      await stop(tester);
    });
  });
}
