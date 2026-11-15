import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';

import 'floor_test.dart' show floorJson;
import 'hub.dart';
import 'table_servers_test.dart' show amy, holly;
import 'table_timers_test.dart' show minute, ringsPainted;

const amyOnStaff = StaffMember(staffId: 's1', name: 'Amy', role: 'server', takesTables: true);
const benOnStaff = StaffMember(staffId: 's2', name: 'Ben', role: 'bartender', takesTables: true);

/// The floor with three busy tables at [now]: A7 is Amy's (a course held 16 minutes: running out), A8 and B5
/// are Ben's (A8 sat half an hour ago and all sent 5 minutes ago: fine; B5 sat 14 minutes with no order: out
/// of time).
Map<String, dynamic> busyFloor(int now) => floorJson()
  ..['status'] = {
    'A7': [
      {
        'order_id': 'o1',
        'guests': 4,
        'server': 'Amy',
        'server_id': 's1',
        'opened_ms': now - 40 * minute,
        'items': 2,
        'fired': ['1'],
        'held': ['2'],
        'total': '36.86',
        'timer': {'stage': 'held', 'since_ms': now - 16 * minute},
      },
    ],
    'A8': [
      {
        'order_id': 'o2',
        'guests': 2,
        'server': 'Ben',
        'server_id': 's2',
        'opened_ms': now - 30 * minute,
        'items': 3,
        'fired': ['1', '2'],
        'held': <String>[],
        'total': '58.00',
        'timer': {'stage': 'fired', 'since_ms': now - 5 * minute},
      },
    ],
    'B5': [
      {
        'order_id': 'o3',
        'guests': 3,
        'server': 'Ben',
        'server_id': 's2',
        'opened_ms': now - 14 * minute,
        'items': 0,
        'fired': <String>[],
        'held': <String>[],
        'timer': {'stage': 'sat', 'since_ms': now - 14 * minute},
      },
    ],
  };

/// The floor map of a terminal [who] is signed in at, with three busy tables, on a screen of [size].
Future<Terminal> pumpMap(
  WidgetTester tester,
  Staff who, {
  DisplayPrefs prefs = const DisplayPrefs(),
  Size size = const Size(1100, 800),
  void Function(Hub hub)? hub,
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.session
    ..staff = who
    ..prefs = prefs;
  t.hub.floor = busyFloor(DateTime.now().millisecondsSinceEpoch);
  hub?.call(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return t;
}

/// The map by itself at the fixed moment [now], as [me] sees it with "Mine" on or off.
Future<List<String>> pumpMapAlone(
  WidgetTester tester, {
  required StaffMember me,
  required bool mine,
  required int Function() now,
  Size size = const Size(1200, 900),
}) async {
  final floor = busyFloor(now());
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient((request) async => http.Response.bytes(utf8.encode(jsonEncode(floor)), 200)),
  );
  final tapped = <String>[];
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FloorView(api: api, onTable: (plan, table) => tapped.add(table.id), me: me, mine: mine, now: now),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return tapped;
}

final mineChip = find.byKey(const ValueKey('mine-chip'));
final myTables = find.byKey(const ValueKey('my-tables'));

/// How much of a table is left to see: 1 as it always was, less once it has faded.
double seen(WidgetTester tester, String table) {
  final faded = find.descendant(of: find.byKey(ValueKey('table-look:$table')), matching: find.byType(Opacity));
  return faded.evaluate().isEmpty ? 1 : tester.widget<Opacity>(faded.first).opacity;
}

/// How many tables the pill at the end of the bar says need a look.
int needALook(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byKey(const ValueKey('attention')), matching: find.byType(Text)))
    .fold(0, (sum, text) => sum + int.parse(text.data!));

void main() {
  test('"Mine" is one of a person\'s own settings, and a table is theirs by any check on it', () {
    expect(const DisplayPrefs().myTables, isFalse);
    expect(DisplayPrefs.fromJson({'text_scale': 1.15}).myTables, isFalse); // a hub older than "Mine"
    final on = DisplayPrefs.fromJson({'my_tables': true});
    expect((on.myTables, on.toJson()['my_tables'], on == const DisplayPrefs()), (true, true, false));
    expect(on.copyWith(textScale: 1.3).myTables, isTrue);
    expect(on.copyWith(myTables: false), const DisplayPrefs());

    final plan = FloorPlan.fromJson(busyFloor(0));
    expect(tablesOf(plan, amyOnStaff), {'A7'});
    expect(tablesOf(plan, benOnStaff), {'A8', 'B5'});
    expect(tablesOf(plan, const StaffMember(staffId: 's4', name: 'Holly')), isEmpty);
  });

  testWidgets('"Mine" fades the other servers\' tables, counts only hers, and is kept with her settings', (
    tester,
  ) async {
    final t = await pumpMap(tester, amy);
    expect(find.descendant(of: mineChip, matching: find.text('Mine 1')), findsOneWidget);
    expect(tester.widget<FilterChip>(mineChip).selected, isFalse);
    expect(
      [
        for (final table in ['A7', 'A8', 'B5', 'D8']) seen(tester, table),
      ],
      [1, 1, 1, 1],
    );
    expect(needALook(tester), 2); // hers is running out, one of Ben's is out of time
    expect(myTables, findsNothing);

    await tester.tap(mineChip);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<FilterChip>(mineChip).selected, isTrue);
    // Ben's are faint and still there, hers is as it was, and so is a free table: anyone may seat it.
    expect(seen(tester, 'A7'), 1);
    expect(seen(tester, 'D8'), 1);
    expect(seen(tester, 'A8'), lessThan(0.6));
    expect(seen(tester, 'B5'), lessThan(0.6));
    expect(find.text('A8'), findsOneWidget);
    expect(needALook(tester), 1);
    // Kept by the hub with the rest of what she set for herself, so it is on wherever she signs in next.
    expect(t.session.prefs.myTables, isTrue);
    final (who, saved) = t.hub.prefsSaved.single;
    expect((who, saved['my_tables'], saved['text_scale']), ('s1', true, 1.0));

    // The list of tables that need a look is of hers too.
    await tester.tap(find.byKey(const ValueKey('attention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('attention:A7')), findsOneWidget);
    expect(find.byKey(const ValueKey('attention:B5')), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tap(mineChip);
    await tester.pump();
    await tester.pump();
    expect((seen(tester, 'A8'), seen(tester, 'B5'), needALook(tester)), (1, 1, 2));
    expect((t.session.prefs.myTables, t.hub.prefsSaved.last.$2['my_tables']), (false, false));
    await stop(tester);
  });

  testWidgets('a screen with the room lists her tables beside the map; a phone keeps the map whole', (tester) async {
    await pumpMap(tester, amy, prefs: const DisplayPrefs(myTables: true));
    // On from the first frame: it came with her sign-in.
    expect(tester.widget<FilterChip>(mineChip).selected, isTrue);
    expect(seen(tester, 'A8'), lessThan(0.6));
    expect(find.descendant(of: myTables, matching: find.text('My tables')), findsOneWidget);
    expect(find.descendant(of: myTables, matching: find.text('1 table · 4 guests')), findsOneWidget);
    final row = find.byKey(const ValueKey('my-table:A7'));
    expect(find.descendant(of: row, matching: find.text('4 guests · 40 min')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('\$36.86')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Held 16 min · 9 min left')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-table:A8')), findsNothing);
    await stop(tester);

    await pumpMap(tester, amy, prefs: const DisplayPrefs(myTables: true), size: const Size(390, 800));
    expect(tester.widget<FilterChip>(mineChip).selected, isTrue);
    expect(seen(tester, 'A8'), lessThan(0.6));
    expect(myTables, findsNothing);
    expect(tester.takeException(), isNull);
    // Narrower still, the bar holds the chip, the rooms and the count without running over.
    await stop(tester);
    await pumpMap(tester, amy, prefs: const DisplayPrefs(myTables: true), size: const Size(320, 640));
    expect(mineChip, findsOneWidget);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  testWidgets('"Mine" is offered to whoever a table can be theirs: not to a host', (tester) async {
    await pumpMap(tester, holly);
    expect(mineChip, findsNothing);
    expect(seen(tester, 'A7'), 1);
    await stop(tester);

    // A hub older than the staff list cannot say who takes tables: everyone is offered it.
    await pumpMap(tester, holly, hub: (hub) => hub.roster = null);
    expect(find.descendant(of: mineChip, matching: find.text('Mine 0')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a faded table still opens, and its ring is as faint as it is', (tester) async {
    const now = 1800000000000;
    final tapped = await pumpMapAlone(tester, me: amyOnStaff, mine: true, now: () => now);
    await tester.tap(find.text('A8'));
    expect(tapped, ['A8']);
    // Three rings: hers in full, Ben's two faint.
    final rings = ringsPainted(tester);
    expect(rings.length, 3);
    expect(rings.where((ring) => ring.$2.a == 1.0).length, 1);
    expect(rings.where((ring) => ring.$2.a < 0.5).length, 2);
    await stop(tester);

    await pumpMapAlone(tester, me: amyOnStaff, mine: false, now: () => now);
    expect(ringsPainted(tester).where((ring) => ring.$2.a < 0.3).length, 0);
    await stop(tester);
  });

  testWidgets('the list beside the map puts the table that most needs a look first and follows the clock', (
    tester,
  ) async {
    var now = 1800000000000;
    final tapped = await pumpMapAlone(tester, me: benOnStaff, mine: true, now: () => now);
    expect(find.descendant(of: myTables, matching: find.text('2 tables · 5 guests')), findsOneWidget);
    final late = find.byKey(const ValueKey('my-table:B5')), fine = find.byKey(const ValueKey('my-table:A8'));
    expect(tester.getTopLeft(late).dy, lessThan(tester.getTopLeft(fine).dy)); // sat later, but out of time
    expect(find.descendant(of: late, matching: find.text('3 guests · 14 min')), findsOneWidget);
    expect(find.descendant(of: late, matching: find.text('Seated 14 min with no order · 4 min over')), findsOneWidget);
    expect(find.descendant(of: fine, matching: find.text('2 guests · 30 min')), findsOneWidget);
    expect(find.descendant(of: fine, matching: find.text('\$58.00')), findsOneWidget);

    now += 3 * minute;
    await tester.pump(const Duration(seconds: 1));
    expect(find.descendant(of: fine, matching: find.text('2 guests · 33 min')), findsOneWidget);
    expect(find.descendant(of: late, matching: find.text('Seated 17 min with no order · 7 min over')), findsOneWidget);

    await tester.tap(late);
    expect(tapped, ['B5']);
    await stop(tester);
  });
}
