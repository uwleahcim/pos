import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/settings.dart';

import 'floor_test.dart' show floorJson;
import 'hub.dart';
import 'location_rows.dart';

const minute = 60000;

/// When A7's entrees began to wait, in the backend's own /floor answer (appetizers fired, entrees held).
const held = 1800000000003;

/// The lines the rings layer paints: how long each is, its colour and how wide.
List<(double, Color, double)> ringsPainted(WidgetTester tester) {
  final drawn = <(double, Color, double)>[];
  expect(
    find.byKey(const ValueKey('timer-rings')),
    paints..everything((Symbol method, List<dynamic> arguments) {
      if (method == #drawPath) {
        final path = arguments[0] as Path, paint = arguments[1] as Paint;
        expect(paint.style, PaintingStyle.stroke);
        final length = path.computeMetrics().fold(0.0, (sum, metric) => sum + metric.length);
        drawn.add((length, paint.color, paint.strokeWidth));
      }
      return true;
    }),
  );
  return drawn;
}

/// The one line the rings layer paints: where it starts, where it ends, and the box it fills.
(Offset, Offset, Rect) ringLine(WidgetTester tester) {
  final lines = <(Offset, Offset, Rect)>[];
  expect(
    find.byKey(const ValueKey('timer-rings')),
    paints..everything((Symbol method, List<dynamic> arguments) {
      if (method == #drawPath) {
        final path = arguments[0] as Path;
        final parts = path.computeMetrics().toList();
        lines.add((
          parts.first.getTangentForOffset(0)!.position,
          parts.last.getTangentForOffset(parts.last.length)!.position,
          path.getBounds(),
        ));
      }
      return true;
    }),
  );
  return lines.single;
}

void main() {
  const timers = TableTimers();

  test('a countdown starts whole, turns amber at the warning and runs out when time is up', () {
    const timer = TableTimer(stage: 'held', sinceMs: 1000); // 15 min to amber, 25 to red
    final start = timers.countdown(timer, 1000)!;
    expect((start.level, start.left, start.short), (TimerLevel.ok, 1.0, '25m'));
    final mid = timers.countdown(timer, 1000 + 10 * minute)!;
    expect((mid.level, mid.left, mid.short, mid.elapsedMinutes), (TimerLevel.ok, 0.6, '15m', 10));
    final amber = timers.countdown(timer, 1000 + 15 * minute)!;
    expect((amber.level, amber.isUp, amber.short), (TimerLevel.warn, false, '10m'));
    // 59 seconds to go still reads as a minute; the moment time is up it reads over by nothing yet
    expect(timers.countdown(timer, 1000 + 25 * minute - 59000)!.short, '1m');
    final up = timers.countdown(timer, 1000 + 25 * minute)!;
    expect((up.level, up.left, up.isUp, up.short), (TimerLevel.late, 0.0, true, '0m'));
    expect(timers.countdown(timer, 1000 + 28 * minute + 30000)!.short, '+3m');
    // a clock behind the stamp (two devices a little apart) is the start, never a negative wait
    expect(timers.countdown(timer, 0)!.left, 1.0);
  });

  test('a stage that only nudges runs out in amber and is never late', () {
    const timer = TableTimer(stage: 'fired', sinceMs: 0); // amber at 25, never red
    expect(timers.countdown(timer, 20 * minute)!.level, TimerLevel.ok);
    expect(timers.countdown(timer, 20 * minute)!.left, closeTo(0.2, 1e-9));
    final nudged = timers.countdown(timer, 31 * minute)!;
    expect((nudged.level, nudged.isUp, nudged.short), (TimerLevel.warn, true, '+6m'));
    expect(countdownInWords(nudged), '31 min since the last dish was sent · 6 min over');
  });

  test('a stage with both times off, a hub that sends no timer, and timers switched off draw no ring', () {
    const quiet = TableTimers(stages: {'sat': StageTimes()});
    expect(quiet.countdown(const TableTimer(stage: 'sat', sinceMs: 0), minute), isNull);
    expect(timers.countdown(null, minute), isNull);
    expect(TableTimers.off.countdown(const TableTimer(stage: 'sat', sinceMs: 0), minute), isNull);
    expect(TableTimer.fromJson(null), isNull);
    expect(TableTimer.fromJson({'stage': 'held'}), isNull);
    // only red set: calm until time is up
    const redOnly = TableTimers(stages: {'sat': StageTimes(late: 8)});
    expect(redOnly.countdown(const TableTimer(stage: 'sat', sinceMs: 0), 7 * minute)!.level, TimerLevel.ok);
    expect(redOnly.countdown(const TableTimer(stage: 'sat', sinceMs: 0), 8 * minute)!.level, TimerLevel.late);
  });

  test('a table with several checks shows the most pressing one', () {
    const fresh = TableTimer(stage: 'sat', sinceMs: 9 * minute);
    const overdue = TableTimer(stage: 'unsent', sinceMs: 0);
    const running = TableTimer(stage: 'held', sinceMs: 0);
    final worst = timers.mostUrgent([fresh, running, overdue, null], 12 * minute)!;
    expect((worst.stage, worst.level, worst.short), ('unsent', TimerLevel.late, '+2m'));
    // between two that are both fine, the one with less of its ring left
    expect(timers.mostUrgent([fresh, running], 10 * minute)!.stage, 'held');
  });

  test('the floor carries the location\'s times and what each table waits on; an older hub\'s has neither', () {
    final plan = FloorPlan.fromJson(floorJson());
    expect(plan.timers.enabled, isTrue);
    expect(plan.timers.timesFor('held'), const StageTimes(warn: 15, late: 25));
    expect(plan.timers.timesFor('fired'), const StageTimes(warn: 25));
    expect(plan.checksAt('A7').single.timer, const TableTimer(stage: 'held', sinceMs: held));
    expect(plan.countdownAt('A7', held + 18 * minute)!.short, '7m');
    expect(plan.countdownAt('A8', held), isNull); // a free table

    final older = floorJson()..remove('timers');
    ((older['status'] as Map)['A7'] as List).single.remove('timer');
    final was = FloorPlan.fromJson(older);
    expect((was.timers.enabled, was.checksAt('A7').single.timer, was.countdownAt('A7', held)), (false, null, null));
    // what a manager saves goes back as the hub reads it
    expect(TableTimers.fromJson(plan.timers.toJson()).stages, plan.timers.stages);
  });

  test('a check still in the outbox is timed from its own operations until the hub has it', () async {
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
    final api = PosApi(settings, client: MockClient((request) async => http.Response('', 503)));
    var clock = 1000;
    final outbox = Outbox(api, settings, store: MemoryStore(), now: () => clock);
    TableTimer? timer() => queuedChecks(outbox)['B5']!.single.timer;

    await outbox.add('q1', 'create', {'table': 'B5', 'guests': 2});
    expect(timer(), const TableTimer(stage: 'sat', sinceMs: 1000));
    clock = 1005;
    await outbox.add('q1', 'add_line', {'line_id': 'L1', 'item': 'x', 'course': '1'});
    clock = 1007;
    await outbox.add('q1', 'add_line', {'line_id': 'L2', 'item': 'y', 'course': '2'});
    expect(timer(), const TableTimer(stage: 'unsent', sinceMs: 1005));
    clock = 1009;
    await outbox.add('q1', 'fire', {'course': '1'});
    expect(timer(), const TableTimer(stage: 'held', sinceMs: 1009));
    clock = 1012;
    await outbox.add('q1', 'fire', {'course': '2'});
    expect(timer(), const TableTimer(stage: 'fired', sinceMs: 1012));
    await outbox.flush(); // nothing answers: it all stays queued, and nothing is left running
    outbox.dispose();
    api.dispose();
  });

  test('the clock follows the hub\'s when the device is more than two seconds off it', () async {
    expect(httpDateMs('Fri, 13 Nov 2026 11:32:36 GMT'), DateTime.utc(2026, 11, 13, 11, 32, 36).millisecondsSinceEpoch);
    expect(httpDateMs('yesterday'), isNull);
    expect(httpDateMs(null), isNull);

    String header(DateTime at) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      String two(int n) => n.toString().padLeft(2, '0');
      return '${days[at.weekday - 1]}, ${two(at.day)} ${months[at.month - 1]} ${at.year} '
          '${two(at.hour)}:${two(at.minute)}:${two(at.second)} GMT';
    }

    var ahead = const Duration(minutes: 5);
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient(
        (request) async => http.Response('{}', 200, headers: {'date': header(DateTime.now().toUtc().add(ahead))}),
      ),
    );
    int off() => api.nowMs() - DateTime.now().millisecondsSinceEpoch;
    expect(off().abs(), lessThan(50)); // nothing heard yet: the device's own clock
    await api.health();
    expect(off(), closeTo(5 * minute, 1500)); // the hub is five minutes ahead: so are the countdowns
    ahead = const Duration(milliseconds: 800);
    await api.health();
    expect(off().abs(), lessThan(50)); // within two seconds the device is taken to be right
    api.dispose();
  });

  testWidgets('a table\'s ring drains, turns amber with a badge, then flashes red; a second redraws no table', (
    tester,
  ) async {
    var now = held;
    // A hub that names its answers, as hubs do: asked again, it says "the one you have" and the map keeps it.
    final hub = Hub();
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient(hub.handle),
    );
    final tapped = <String>[];
    tester.view
      ..physicalSize = const Size(1200, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: PosTheme.light(),
        home: Scaffold(
          body: FloorView(api: api, onTable: (plan, table) => tapped.add(table.id), now: () => now),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final colors = PosColors.light;

    // The wait has just begun: the whole ring, in the table's own colour, and nothing asking for a look.
    final (whole, calm, thin) = ringsPainted(tester).single;
    final middle = ringLine(tester).$3.center; // of A7, a square table that stands on its corner
    expect(calm, isSameColorAs(colors.waitingBorder));
    expect(thin, 4.0);
    expect(find.byKey(const ValueKey('timer-badge:A7')), findsNothing);
    expect(find.byKey(const ValueKey('attention')), findsNothing);
    expect(find.text('4p 0m'), findsOneWidget);

    // Every second from here on, only the parts that show the clock may be rebuilt.
    final rebuilt = <String>{};
    debugOnRebuildDirtyWidget = (element, builtOnce) => rebuilt.add(element.widget.runtimeType.toString());
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // Ten of its twenty-five minutes gone: three fifths of the ring is left, still calm.
    now = held + 10 * minute;
    await tester.pump(const Duration(seconds: 1));
    final (left, still, _) = ringsPainted(tester).single;
    expect(left / whole, closeTo(0.6, 0.01));
    expect(still, isSameColorAs(colors.waitingBorder));
    // What is left starts at twelve o'clock, straight above the table's middle though the table is turned,
    // and runs clockwise: three fifths of the way round ends low on the left.
    var (from, to, _) = ringLine(tester);
    expect(from.dx, closeTo(middle.dx, 0.01));
    expect(from.dy, lessThan(middle.dy));
    expect((to.dx < middle.dx, to.dy > middle.dy), (true, true));
    expect(find.text('4p 10m'), findsOneWidget); // the minutes since the table was sat follow the clock too
    expect(find.byKey(const ValueKey('timer-badge:A7')), findsNothing);

    // Eighteen: amber, a thicker line, a badge with the minutes left, and the count of tables to look at.
    now = held + 18 * minute;
    await tester.pump(const Duration(seconds: 1));
    final (short, amber, thicker) = ringsPainted(tester).single;
    expect(short / whole, closeTo(7 / 25, 0.01));
    // Its far end has drawn back counter-clockwise, past six o'clock to the right side; twelve has not moved.
    (from, to, _) = ringLine(tester);
    expect(from.dx, closeTo(middle.dx, 0.01));
    expect(from.dy, lessThan(middle.dy));
    expect((to.dx > middle.dx, to.dy > middle.dy), (true, true));
    expect(amber, isSameColorAs(colors.timerWarn));
    expect(thicker, 5.0);
    final badge = find.byKey(const ValueKey('timer-badge:A7'));
    expect(find.descendant(of: badge, matching: find.text('7m')), findsOneWidget);
    expect(find.descendant(of: badge, matching: find.byIcon(Icons.pause_rounded)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('attention')), matching: find.text('1')), findsOneWidget);

    // A second in which nothing would look different repaints nothing.
    final layer = tester.renderObject(find.byKey(const ValueKey('timer-rings')));
    now += 200;
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(layer.debugNeedsPaint, isFalse);
    now += 30000; // half a minute is a visible step of this ring
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(layer.debugNeedsPaint, isTrue);
    await tester.pump();

    // Twenty-six: time is up. The whole ring again, red, bright one second and dim the next.
    final second = (held + 26 * minute) ~/ 1000 + 1;
    now = (second.isEven ? second : second + 1) * 1000; // on an even second: the bright half of the flash
    await tester.pump(const Duration(seconds: 1));
    final (full, red, thickest) = ringsPainted(tester).single;
    expect(full / whole, closeTo(1, 0.001));
    expect(red, isSameColorAs(colors.timerLate));
    expect(thickest, 5.5);
    expect(find.descendant(of: badge, matching: find.text('+1m')), findsOneWidget);
    now += 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(ringsPainted(tester).single.$2, isSameColorAs(colors.timerLate.withValues(alpha: 0.35)));

    expect(hub.unchanged, greaterThan(0)); // the map went on asking all the while
    // The clock rebuilt its own few words (the minutes, the badge, the count) and nothing of the map.
    expect(rebuilt, contains('_Ticking<int>'));
    for (final part in const [
      'FloorView',
      '_TablePositioned',
      '_RoomOutline',
      'InteractiveViewer',
      'AnimatedContainer',
    ]) {
      expect(rebuilt, isNot(contains(part)), reason: 'the clock rebuilt $part');
    }
    debugOnRebuildDirtyWidget = null;

    // The count opens the list of tables to look at, in words; a tap opens the table.
    await tester.tap(find.byKey(const ValueKey('attention')));
    await tester.pumpAndSettle();
    expect(find.text('A7 · Course held'), findsOneWidget);
    expect(find.text('Held 26 min · 1 min over'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('attention:A7')));
    await tester.pumpAndSettle();
    expect(tapped, ['A7']);

    await tester.pumpWidget(const SizedBox()); // stops the timers
    api.dispose();
  });

  testWidgets('with the timers off, or on a hub older than them, the map is as it was', (tester) async {
    final off = floorJson();
    (off['timers'] as Map)['enabled'] = false;
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async => http.Response.bytes(utf8.encode(jsonEncode(off)), 200)),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloorView(api: api, onTable: (plan, table) {}, now: () => held + 40 * minute),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('4p 40m'), findsOneWidget);
    expect(find.byKey(const ValueKey('timer-rings')), findsNothing);
    expect(find.byKey(const ValueKey('timer-badge:A7')), findsNothing);
    expect(find.byKey(const ValueKey('attention')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('a manager sets the table timers for every floor map', (tester) async {
    final t = await pumpOrders(tester, const []);
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
    await tester.pumpAndSettle();
    await bringUp(tester, 'table-timers');
    expect(find.text('Seated 5/10 · Not sent 5/10 · Held 15/25 · All sent 25/– min'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('table-timers')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('timer-late:held'))).controller!.text, '25');

    // red before amber is caught here, and what the hub refuses is shown in its words
    await tester.enterText(find.byKey(const ValueKey('timer-warn:held')), '30');
    await tester.tap(find.byKey(const ValueKey('timers-save')));
    await tester.pumpAndSettle();
    expect(find.text('For "course held", red must come after amber'), findsOneWidget);
    expect(t.hub.tableTimersAuth, isNull);
    await tester.enterText(find.byKey(const ValueKey('timer-warn:held')), '12');
    await tester.enterText(find.byKey(const ValueKey('timer-late:held')), '20');
    await tester.enterText(find.byKey(const ValueKey('timer-warn:fired')), '0');
    t.hub.refuseTableTimers = 'the late time for held is 0 (never) to 1440 minutes';
    await tester.tap(find.byKey(const ValueKey('timers-save')));
    await tester.pumpAndSettle();
    expect(find.text('the late time for held is 0 (never) to 1440 minutes'), findsOneWidget);

    t.hub.refuseTableTimers = null;
    await tester.tap(find.byKey(const ValueKey('timers-save')));
    await tester.pumpAndSettle();
    expect(t.hub.tableTimersAuth, 'Bearer tok-admin');
    expect(t.hub.tableTimers, {
      'enabled': true,
      'stages': {
        'sat': {'warn': 5, 'late': 10},
        'unsent': {'warn': 5, 'late': 10},
        'held': {'warn': 12, 'late': 20},
        'fired': {'warn': 0, 'late': 0},
      },
    });
    expect(find.text('Table timers saved'), findsOneWidget);
    expect(find.text('Seated 5/10 · Not sent 5/10 · Held 12/20 · All sent –/– min'), findsOneWidget);

    // off altogether (the row is brought up from under the "saved" line at the foot of the screen)
    await tester.ensureVisible(find.byKey(const ValueKey('table-timers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('table-timers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timers-enabled')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timers-save')));
    await tester.pumpAndSettle();
    expect(t.hub.tableTimers!['enabled'], isFalse);
    expect(find.text('Off: the tables show no countdown'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hub older than the timers says so in the settings and has nothing to open', (tester) async {
    final t = await terminal(tester);
    t.hub.tableTimers = null;
    await pumpOrdersOn(tester, t);
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
    await tester.pumpAndSettle();
    await bringUp(tester, 'table-timers');
    expect(find.textContaining('The hub has not answered about table timers'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-timers')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timers-save')), findsNothing);
    await stop(tester);
  });
}
