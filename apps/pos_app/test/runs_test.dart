import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/runs.dart';
import 'package:pos_app/screens/runs_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catering_test.dart' show tapKey;
import 'delivery_test.dart' show elm, key;
import 'drivers_test.dart' show bag, pumpDeliveries, tom, words;
import 'hub.dart';

/// A driver's runs (docs/delivery.md, "Runs"): what each driver took out over a day of service, run by run
/// and bag by bag. The hub reads it off the orders' logs (backend/tests/orders/test_runs.py); these tests
/// are about what the screen says of it.

const oak = '4 Oak Rd, Winchester';
const monday = '2026-11-16';
const sunday = '2026-11-15';

/// That time on Monday the 16th, on the terminal's own clock, in ms.
int at(int hour, int minute, {int day = 16}) => DateTime(2026, 11, day, hour, minute).millisecondsSinceEpoch;

/// A bag as the hub says it: order [no] for [name], which left at [left] and, at [end], became [outcome].
Map<String, dynamic> leg(
  String id,
  int no,
  String name,
  int left, {
  String address = elm,
  String outcome = 'out',
  int? end,
  String? to,
}) => {
  'order_id': id,
  'order_no': no,
  'customer_name': name,
  'address': address,
  'left_ms': left,
  'outcome': outcome,
  'at_ms': end,
  'minutes': end == null ? null : (end - left) ~/ 60000,
  'to': ?to,
};

Map<String, dynamic> run(List<Map<String, dynamic>> bags) {
  final left = bags.first['left_ms'] as int;
  final ends = [for (final each in bags) each['at_ms'] as int?];
  final ended = ends.contains(null) ? null : ends.whereType<int>().reduce((a, b) => a > b ? a : b);
  return {'left_ms': left, 'ended_ms': ended, 'minutes': ended == null ? null : (ended - left) ~/ 60000, 'bags': bags};
}

int _count(List<Map<String, dynamic>> runs, String outcome) => [
  for (final each in runs)
    for (final b in each['bags'] as List)
      if ((b as Map)['outcome'] == outcome) b,
].length;

Map<String, dynamic> driver(String id, String name, List<Map<String, dynamic>> runs) => {
  'driver_id': id,
  'driver': name,
  'runs': runs.length,
  'delivered': _count(runs, 'delivered'),
  'back': _count(runs, 'back'),
  'out': _count(runs, 'out'),
  'list': runs,
};

Map<String, dynamic> report(String day, List<Map<String, dynamic>> drivers, {int noDriver = 0}) => {
  'day': day,
  for (final count in ['runs', 'delivered', 'back', 'out'])
    count: drivers.fold<int>(0, (sum, each) => sum + (each[count] as int)),
  'no_driver': noDriver,
  'drivers': drivers,
};

/// Monday evening: Tom is on his third run with two bags out, one of his came back; Wei made two runs, with
/// an order voided on the way; Mike took one over himself.
Map<String, dynamic> evening() => report(monday, [
  driver('d1', 'Tom', [
    run([
      leg('o1', 1, 'Linda', at(17, 35), outcome: 'delivered', end: at(17, 52)),
      leg('o2', 2, 'Raj', at(17, 35), address: oak, outcome: 'delivered', end: at(18, 5)),
    ]),
    run([
      leg('o4', 4, 'Chen', at(18, 40), outcome: 'delivered', end: at(18, 58)),
      leg('o5', 5, 'Park', at(18, 40), address: oak, outcome: 'back', end: at(19, 2)),
    ]),
    run([leg('o8', 8, 'Dana', at(19, 30)), leg('o9', 9, 'Sam', at(19, 31), address: oak)]),
  ]),
  driver('d2', 'Wei', [
    run([leg('o3', 3, 'Maria', at(18, 10), outcome: 'delivered', end: at(19, 21))]),
    run([
      leg('o6', 6, 'Lee', at(19, 5), outcome: 'void', end: at(19, 12)),
      leg('o7', 7, 'Kim', at(19, 5), address: oak, outcome: 'handed', end: at(19, 14), to: 'Mike'),
    ]),
  ]),
  driver('s3', 'Mike', [
    run([leg('o7', 7, 'Kim', at(19, 14), address: oak, outcome: 'delivered', end: at(19, 33))]),
  ]),
], noDriver: 2);

const amy = Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');

/// The Runs screen by itself, with [who] signed in, on a hub that lists [days] (none: a hub older than the
/// runs) and says Monday is running.
Future<Terminal> pumpRuns(
  WidgetTester tester,
  Map<String, Map<String, dynamic>>? days, {
  Staff who = amy,
  Size? size,
  double? type,
}) async {
  final t = await terminal(tester);
  t.session.staff = who;
  t.hub.runs = days;
  if (size != null) tester.view.physicalSize = size;
  if (type != null) {
    tester.platformDispatcher.textScaleFactorTestValue = type;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(
    MaterialApp(
      home: RunsScreen(api: t.api, session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The drivers the screen lists, top to bottom (left to right on a wide one), by id.
List<String> listed(WidgetTester tester) => [
  for (final each in tester.widgetList(
    find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('runs-driver:'),
    ),
  ))
    (each.key! as ValueKey<String>).value.substring('runs-driver:'.length),
];

String said(WidgetTester tester, String name) => tester.widget<Text>(key(name)).data!;

void main() {
  group('the words', () {
    final read = RunsReport.fromJson(evening());

    test('a day says its runs and what became of the bags, with every driver together', () {
      expect(read.day, monday);
      expect((read.runs, read.delivered, read.back, read.out, read.noDriver), (6, 5, 1, 2, 2));
      expect(read.summed, '6 runs · 5 delivered · 1 came back · 2 out');
      expect(read.noDriverWords, '2 deliveries were marked delivered with no driver named. They are in no run.');
      expect(
        const RunsReport(day: monday, noDriver: 1).noDriverWords,
        '1 delivery was marked delivered with no driver named. It is in no run.',
      );
      // nothing came back and nothing is out: neither is said
      expect(runsSummed(runs: 1, delivered: 3, back: 0, out: 0), '1 run · 3 delivered');
      expect(runsSummed(runs: 2, delivered: 0, back: 0, out: 1), '2 runs · 0 delivered · 1 out');
    });

    test('a driver says their own, and a run when it left, how many bags and how long it took', () {
      final [tom, wei, mike] = read.drivers;
      expect((tom.driverId, tom.driver, tom.summed), ('d1', 'Tom', '3 runs · 3 delivered · 1 came back · 2 out'));
      expect(
        [for (final each in tom.list) each.words],
        ['left 17:35 · 2 bags · 30 min', 'left 18:40 · 2 bags · 22 min', 'left 19:30 · 2 bags · out now'],
      );
      expect([for (final each in tom.list) each.isOut], [false, false, true]);
      expect(wei.summed, '2 runs · 1 delivered');
      expect(wei.list.first.words, 'left 18:10 · 1 bag · 1 h 11');
      expect(mike.summed, '1 run · 1 delivered');
    });

    test('a bag says what became of it and when', () {
      final [tom, wei, _] = read.drivers;
      expect(
        [for (final each in tom.list[0].bags) '${each.title}: ${each.words}'],
        ['#1 Linda: delivered 17:52 · 17 min', '#2 Raj: delivered 18:05 · 30 min'],
      );
      expect(tom.list[1].bags[1].words, 'came back 19:02');
      expect([for (final each in tom.list[2].bags) each.words], ['still out', 'still out']);
      expect([for (final each in wei.list[1].bags) each.words], ['voided 19:12', 'handed to Mike 19:14']);
      expect(wei.list[0].bags.single.words, 'delivered 19:21 · 1 h 11');
      // a hub that says less, or something this app has not heard of
      final bare = RunBag.fromJson({'order_id': 'o1', 'left_ms': at(18, 0), 'outcome': 'handed', 'at_ms': at(18, 5)});
      expect((bare.title, bare.words), ('#…', 'handed on 18:05'));
      expect(RunBag.fromJson({'order_id': 'o1', 'left_ms': at(18, 0), 'outcome': 'lost'}).words, 'still out');
      expect((tookWords(0), tookWords(59), tookWords(60), tookWords(125)), ('0 min', '59 min', '1 h 00', '2 h 05'));
    });

    test('a driver finds their own runs first', () {
      expect([for (final each in read.mineFirst('d2')) each.driver], ['Wei', 'Tom', 'Mike']);
      expect([for (final each in read.mineFirst('s1')) each.driver], ['Tom', 'Wei', 'Mike']);
      expect([for (final each in read.mineFirst(null)) each.driver], ['Tom', 'Wei', 'Mike']);
      // one a screen named without an id is nobody's own
      final unnamed = RunsReport.fromJson(report(monday, [driver('', 'Tom', const [])]));
      expect(unnamed.mineFirst('').single.driver, 'Tom');
    });

    test('a day is called by what it is to today', () {
      expect(runsDayWords(monday, monday), 'Today');
      expect(runsDayWords(sunday, monday), 'Yesterday');
      expect(runsDayWords('2026-11-14', monday), 'Sat 14 Nov');
      expect(
        (dayFrom(monday, -1), dayFrom(monday, 1), dayFrom('2026-03-01', -1)),
        (sunday, '2026-11-17', '2026-02-28'),
      );
      expect((dayFrom('2026-11-01', -1), dayFrom('2026-12-31', 1)), ('2026-10-31', '2027-01-01'));
      expect((dayFrom('soon', -1), runsDayWords('soon', monday)), ('soon', 'soon'));
    });
  });

  group('the screen', () {
    testWidgets('says the day, what it came to, and every driver run by run', (tester) async {
      final t = await pumpRuns(tester, {monday: evening()});
      expect(t.hub.requests.where((r) => r.contains('/deliveries/runs')), ['GET /deliveries/runs']);
      expect(said(tester, 'runs-day'), 'Today · Mon 16 Nov');
      expect(said(tester, 'runs-summed'), '6 runs · 5 delivered · 1 came back · 2 out');
      expect(said(tester, 'runs-no-driver'), contains('2 deliveries were marked delivered with no driver named'));
      expect(listed(tester), ['d1', 'd2', 's3']); // whoever left first, first
      expect(
        words(tester, 'runs-driver:d1'),
        [
          'Tom',
          '3 runs · 3 delivered · 1 came back · 2 out',
          'Run 1 · left 17:35 · 2 bags · 30 min',
          '#1 Linda',
          'delivered 17:52 · 17 min',
          elm,
          '#2 Raj',
          'delivered 18:05 · 30 min',
          oak,
          'Run 2 · left 18:40 · 2 bags · 22 min',
          '#4 Chen',
          'delivered 18:58 · 18 min',
          elm,
          '#5 Park',
          'came back 19:02',
          oak,
          'Run 3 · left 19:30 · 2 bags · out now',
          '#8 Dana',
          'still out',
          elm,
          '#9 Sam',
          'still out',
          oak,
        ].join(' | '),
      );
      expect(words(tester, 'run:d2:2'), contains('#7 Kim | handed to Mike 19:14'));
      expect(
        words(tester, 'run:s3:1'),
        'Run 1 · left 19:14 · 1 bag · 19 min | #7 Kim | delivered 19:33 · 19 min | $oak',
      );
      // no amount of money anywhere on it
      final all = [for (final text in tester.widgetList<Text>(find.byType(Text))) text.data ?? ''].join(' ');
      expect(all, isNot(contains(r'$')));
      // the day that is running is the last there is
      expect(tester.widget<IconButton>(key('runs-later')).onPressed, isNull);
      await stop(tester);
    });

    testWidgets('a driver who is signed in sees their own runs first, as You', (tester) async {
      await pumpRuns(tester, {
        monday: evening(),
      }, who: const Staff(staffId: 'd2', name: 'Wei', role: 'driver', method: 'pin'));
      expect(listed(tester), ['d2', 'd1', 's3']);
      expect(words(tester, 'runs-driver:d2'), startsWith('You | 2 runs · 1 delivered | Run 1 · left 18:10'));
      expect(words(tester, 'runs-driver:d1'), startsWith('Tom | '));
      await stop(tester);
    });

    testWidgets('the arrows step to the days before and back, never past today', (tester) async {
      final t = await pumpRuns(tester, {
        monday: evening(),
        sunday: report(sunday, [
          driver('d1', 'Tom', [
            run([leg('y1', 31, 'Ada', at(23, 50, day: 15), outcome: 'delivered', end: at(0, 20))]),
          ]),
        ]),
      });
      await tapKey(tester, 'runs-earlier');
      expect(t.hub.requests.last, 'GET /deliveries/runs?day=$sunday');
      expect(said(tester, 'runs-day'), 'Yesterday · Sun 15 Nov');
      expect(said(tester, 'runs-summed'), '1 run · 1 delivered');
      expect(
        words(tester, 'run:d1:1'),
        'Run 1 · left 23:50 · 1 bag · 30 min | #31 Ada | delivered 00:20 · 30 min | $elm',
      );
      // a day nobody delivered on
      await tapKey(tester, 'runs-earlier');
      expect(t.hub.requests.last, 'GET /deliveries/runs?day=2026-11-14');
      expect(said(tester, 'runs-day'), 'Sat 14 Nov');
      expect(said(tester, 'runs-none'), 'No delivery left with a driver on this day.');
      expect(key('runs-summed'), findsNothing);
      // and forward again, to the day that is running and no further
      await tapKey(tester, 'runs-later');
      expect(said(tester, 'runs-day'), 'Yesterday · Sun 15 Nov');
      await tapKey(tester, 'runs-later');
      expect(t.hub.requests.last, 'GET /deliveries/runs');
      expect(said(tester, 'runs-day'), 'Today · Mon 16 Nov');
      expect(said(tester, 'runs-summed'), '6 runs · 5 delivered · 1 came back · 2 out');
      expect(tester.widget<IconButton>(key('runs-later')).onPressed, isNull);
      await stop(tester);
    });

    testWidgets('a day with no run says so, and still says what nobody was named for', (tester) async {
      await pumpRuns(tester, {monday: report(monday, const [], noDriver: 1)});
      expect(said(tester, 'runs-none'), 'No delivery has left with a driver today.');
      expect(said(tester, 'runs-no-driver'), '1 delivery was marked delivered with no driver named. It is in no run.');
      expect(listed(tester), isEmpty);
      await stop(tester);
    });

    testWidgets('it is read again when an order changes, and drawn again only when it says something new', (
      tester,
    ) async {
      final t = await pumpRuns(tester, {monday: evening()});
      final first = tester.widget<Text>(key('runs-summed'));
      await tester.pump(const Duration(seconds: 7)); // no feed on this hub: it asks now and then
      expect(t.hub.unchanged, greaterThan(0));
      expect(identical(tester.widget<Text>(key('runs-summed')), first), isTrue);
      // Tom is back: his last two were delivered
      final later = evening();
      final toms = ((later['drivers'] as List).first as Map<String, dynamic>)['list'] as List;
      toms[2] = run([
        leg('o8', 8, 'Dana', at(19, 30), outcome: 'delivered', end: at(19, 48)),
        leg('o9', 9, 'Sam', at(19, 31), address: oak, outcome: 'delivered', end: at(19, 55)),
      ]);
      t.hub.runs![monday] = report(monday, [
        driver('d1', 'Tom', toms.cast<Map<String, dynamic>>()),
        ...(later['drivers'] as List).skip(1).cast<Map<String, dynamic>>(),
      ], noDriver: 2);
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      expect(said(tester, 'runs-summed'), '6 runs · 7 delivered · 1 came back');
      expect(words(tester, 'run:d1:3'), startsWith('Run 3 · left 19:30 · 2 bags · 25 min | #8 Dana | delivered 19:48'));
      await stop(tester);
    });

    testWidgets('a hub older than the runs says to update it; one that is away says so', (tester) async {
      await pumpRuns(tester, null);
      expect(find.text('This hub does not list runs yet. Update the hub.'), findsOneWidget);
      expect(key('runs-day'), findsNothing);
      await stop(tester);
    });

    testWidgets('with the hub away it says so, and keeps what it read', (tester) async {
      final t = await pumpRuns(tester, {monday: evening()});
      t.hub.down = true;
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      expect(key('runs-away'), findsOneWidget);
      expect(said(tester, 'runs-summed'), '6 runs · 5 delivered · 1 came back · 2 out');
      t.hub.down = false;
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      expect(key('runs-away'), findsNothing);
      await stop(tester);
      // away from the start: nothing to show
      final cold = await terminal(tester);
      cold.hub.down = true;
      await tester.pumpWidget(
        MaterialApp(
          home: RunsScreen(api: cold.api, session: cold.session),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('The hub is not answering.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('on a small phone with large type every bag is there and nothing runs off the edge', (tester) async {
      await pumpRuns(tester, {monday: evening()}, size: const Size(320, 568), type: 1.3);
      expect(said(tester, 'runs-day'), 'Today · Mon 16 Nov');
      await tester.scrollUntilVisible(key('run:s3:1'), 200, scrollable: find.byType(Scrollable).first);
      expect(words(tester, 'run:s3:1'), contains('#7 Kim | delivered 19:33 · 19 min'));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('on a tablet the drivers stand side by side', (tester) async {
      await pumpRuns(tester, {monday: evening()}, size: const Size(1180, 820));
      final tomAt = tester.getTopLeft(key('runs-driver:d1'));
      final weiAt = tester.getTopLeft(key('runs-driver:d2'));
      final mikeAt = tester.getTopLeft(key('runs-driver:s3'));
      expect((tomAt.dy, weiAt.dy), (mikeAt.dy, mikeAt.dy));
      expect(tomAt.dx < weiAt.dx && weiAt.dx < mikeAt.dx, isTrue);
      // on a phone, one under the other
      await stop(tester);
      await pumpRuns(tester, {monday: evening()}, size: const Size(390, 844));
      final left = tester.getTopLeft(key('runs-driver:d1')).dx;
      await tester.scrollUntilVisible(key('runs-driver:d2'), 200, scrollable: find.byType(Scrollable).first);
      expect(tester.getTopLeft(key('runs-driver:d2')).dx, left);
      await stop(tester);
    });
  });

  group('from the Deliveries screen', () {
    testWidgets('Runs in the bar opens the runs of the day', (tester) async {
      final t = await pumpDeliveries(tester, [bag('o8', 8, name: 'Dana', driver: tom)]);
      t.hub.runs = {monday: evening()};
      await tapKey(tester, 'deliveries-runs');
      expect(find.byType(RunsScreen), findsOneWidget);
      expect(said(tester, 'runs-summed'), '6 runs · 5 delivered · 1 came back · 2 out');
      // and back to the deliveries
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(RunsScreen), findsNothing);
      expect(key('out-o8'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the bar fits it on a small phone with large type', (tester) async {
      await pumpDeliveries(
        tester,
        [bag('o8', 8, name: 'Dana', driver: tom)],
        size: const Size(320, 568),
        type: 1.3,
      );
      expect(find.text('Deliveries'), findsOneWidget);
      expect(key('deliveries-runs'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  test('the hub is asked for the day, and one older than the runs is told apart', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 't1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final hub = Hub()..runs = {monday: evening()};
    final t = PosApi(settings, client: MockClient(hub.handle));
    expect((await t.runs())!.day, monday);
    expect((await t.runs(day: sunday))!.drivers, isEmpty);
    expect(hub.requests, ['GET /deliveries/runs', 'GET /deliveries/runs?day=$sunday']);
    // asked again with nothing new, the same object comes back
    final first = await t.runs();
    expect(identical(await t.runs(), first), isTrue);
    hub.runs = null;
    expect(await t.runs(), isNull);
    hub.down = true;
    await expectLater(t.runs(), throwsA(isA<ApiException>()));
  });
}
