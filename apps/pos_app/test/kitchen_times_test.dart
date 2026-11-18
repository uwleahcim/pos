import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/kitchen_times.dart';
import 'package:pos_app/screens/kitchen_times_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/theme.dart';

import 'hub.dart';
import 'location_rows.dart';

/// How long the kitchen takes (docs/kitchen-times.md): what a manager reads to see where the tickets wait.
/// The hub does every sum; these tests are about the screen saying what the hub said, in minutes a person
/// reads, with less time as the better figure, and asking for the right days.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

/// Minutes as the hub writes a time.
int? m(num? minutes) => minutes == null ? null : (minutes * 60000).round();

Map<String, dynamic> took(int tickets, num? avg, num? median, num? longest, {int late = 0, int open = 0}) => {
  'tickets': tickets,
  'avg_ms': m(avg),
  'median_ms': m(median),
  'longest_ms': m(longest),
  'late': late,
  'open': open,
};

Map<String, dynamic> dish(String name, int count, num avg, num longest) => {
  'name': name,
  'count': count,
  'avg_ms': m(avg),
  'median_ms': m(avg),
  'longest_ms': m(longest),
  'late': 0,
  'open': 0,
};

Map<String, dynamic> slow(
  String order,
  String station,
  String stationName,
  int sentMs,
  num minutes, {
  String table = '',
  String tab = '',
  int? orderNo,
  String customer = '',
  bool toGo = false,
}) => {
  'order_id': order,
  'table': table,
  'tab': tab,
  'order_no': orderNo,
  'customer': customer,
  'to_go': toGo,
  'station': station,
  'station_name': stationName,
  'sent_ms': sentMs,
  'took_ms': m(minutes),
};

/// The week of Monday 9 November beside the week before it. Tickets turn red at 20 minutes.
Map<String, dynamic> week() => {
  'span': {
    'first': '2026-11-09',
    'last': '2026-11-15',
    'running': false,
    'made': took(412, 11.4, 9, 47, late: 31, open: 6),
    'out': took(228, 16.2, 14, 52, late: 60, open: 1),
    'stations': [
      {'code': 'wok', 'name': 'Wok', ...took(180, 12.6, 11, 47, late: 22, open: 4)},
      {'code': 'fryer', 'name': 'Fryer', ...took(150, 8.2, 7, 26, late: 3, open: 2)},
      {'code': 'sushi', 'name': 'Sushi bar', ...took(82, 14.9, 13, 41, late: 6)},
    ],
    'silent': [
      {'code': 'bar', 'name': 'Bar', 'open': 96},
      {'code': 'takeout', 'name': 'takeout', 'open': 1},
    ],
    'hours': [
      {'hour': 11, ...took(40, 7, 6, 15)},
      {'hour': 18, ...took(160, 10.6, 9, 33, late: 9)},
      {'hour': 19, ...took(200, 21.2, 12, 47, late: 22, open: 6)},
      {'hour': 0, ...took(12, 0.3, 0.3, 0.4)},
    ],
    'days': [
      {'day': '2026-11-09', ...took(40, 9, 8, 20, late: 1)},
      {'day': '2026-11-10', ...took(52, 10, 9, 22, late: 2)},
      {'day': '2026-11-11', ...took(0, null, null, null)},
      {'day': '2026-11-12', ...took(60, 11, 9, 30, late: 4)},
      {'day': '2026-11-13', ...took(90, 12, 10, 41, late: 8)},
      {'day': '2026-11-14', ...took(110, 22.5, 11, 47, late: 12, open: 6)},
      {'day': '2026-11-15', ...took(60, 10.5, 9, 28, late: 4)},
    ],
    'dishes': [
      dish('Peking duck', 6, 38.4, 47),
      dish('Dragon roll', 61, 14.9, 41),
      dish("General Tso's Chicken", 86, 12.2, 33),
      for (var i = 4; i <= 12; i++) dish('Dish number $i', 20 - i, 12 - i * 0.5, 20),
    ],
    'slowest': [
      slow('o1', 'wok', 'Wok', ms(19, 12, 14), 47, table: '12'),
      slow('o2', 'takeout', 'takeout', ms(18, 40, 13), 41.4, orderNo: 14, customer: 'Linda', toGo: true),
      slow('o3', 'sushi', 'Sushi bar', ms(20, 5, 14), 41, tab: 'Mike'),
    ],
  },
  'before': {
    'first': '2026-11-02',
    'last': '2026-11-08',
    'running': false,
    'made': took(390, 13.1, 10, 55, late: 44, open: 9),
    'out': took(0, null, null, null),
  },
  'late_min': 20,
  'max_days': 92,
  'now_ms': ms(21),
};

/// The evening that is running, beside the Monday before: a little slower.
Map<String, dynamic> today() => {
  'span': {
    'first': '2026-11-16',
    'last': '2026-11-16',
    'running': true,
    'made': took(18, 9.6, 9, 22, late: 1, open: 3),
    'out': took(0, null, null, null),
    'stations': [
      {'code': 'wok', 'name': 'Wok', ...took(18, 9.6, 9, 22, late: 1, open: 3)},
    ],
    'silent': <Object>[],
    'hours': [
      {'hour': 18, ...took(18, 9.6, 9, 22, late: 1, open: 3)},
    ],
    'days': [
      {'day': '2026-11-16', ...took(18, 9.6, 9, 22, late: 1, open: 3)},
    ],
    'dishes': [dish('Egg roll', 9, 7, 9)],
    'slowest': [slow('o9', 'wok', 'Wok', ms(18, 40), 22, table: '4')],
  },
  'before': {
    'first': '2026-11-09',
    'last': '2026-11-09',
    'running': false,
    'made': took(21, 8.4, 9, 31, late: 2),
    'out': took(0, null, null, null),
  },
  'late_min': 20,
  'max_days': 92,
  'now_ms': ms(21),
};

class Times {
  Times(this.t);
  final Terminal t;
  final picks = <DateTimeRange>[];
  final asked = <DateTimeRange?>[];

  Future<DateTimeRange?> pickSpan(BuildContext context, DateTimeRange? from) async {
    asked.add(from);
    return picks.isEmpty ? null : picks.removeAt(0);
  }
}

const theWeek = '2026-11-09..2026-11-15';

Future<Times> pumpTimes(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? times,
  bool older = false,
  Size size = const Size(1100, 4200),
  DateTime? now,
  ThemeData? theme,
  double textScale = 1,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.kitchenTimes = older ? null : (times ?? {theWeek: week(), '': today()});
  before?.call(t.hub);
  tester.view.physicalSize = size;
  final k = Times(t);
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: KitchenTimesScreen(api: t.api, token: 'tok-admin', now: () => now ?? at(21), pickSpan: k.pickSpan),
    ),
  );
  await tester.pumpAndSettle();
  return k;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle(); // where it scrolled to is laid out before the tap is aimed
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Every text inside the row with that key, in order (a line in two colours as the one line it reads as).
List<String> row(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey('kitchen-times-$key')), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
];

/// The rows whose key begins so, in the order they stand in, each by what follows.
List<String> keyed(WidgetTester tester, String begins) => [
  for (final element in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate())
    if ((element.widget.key! as ValueKey<String>).value.startsWith('kitchen-times-$begins'))
      (element.widget.key! as ValueKey<String>).value.substring('kitchen-times-$begins'.length),
];

/// The bar of an hour or a day: how long it is drawn, and in what colour.
(double, Color?) bar(WidgetTester tester, String key) {
  final box = find.descendant(
    of: find.byKey(ValueKey('kitchen-times-$key')),
    matching: find.byType(FractionallySizedBox),
  );
  final drawn = tester.widget<Container>(find.descendant(of: box, matching: find.byType(Container)));
  return (tester.widget<FractionallySizedBox>(box).widthFactor!, (drawn.decoration! as BoxDecoration).color);
}

void main() {
  group('what the report reads', () {
    test('a time is said in whole minutes', () {
      expect(tookWords(null), '–');
      expect(tookWords(0), 'under 1 min');
      expect(tookWords(29000), 'under 1 min');
      expect(tookWords(30000), '1 min');
      expect(tookWords(m(11.4)), '11 min');
      expect(tookWords(m(59.6)), '1 h');
      expect(tookWords(m(65)), '1 h 5 min');
    });

    test('less time is the better figure, in the minutes that are shown', () {
      expect(tookChange(m(11.4), m(13.1)), (words: '2 min quicker', up: true));
      expect(tookChange(m(9.6), m(8.4)), (words: '2 min slower', up: false));
      expect(tookChange(m(90), m(20)), (words: '1 h 10 min slower', up: false));
      // the same minute on the screen is the same, whatever the seconds
      expect(tookChange(m(9.4), m(8.6)), (words: 'the same', up: null));
      expect(tookChange(m(9), null), (words: 'nothing before', up: null));
      expect(tookChange(null, m(9)), (words: '', up: null));
      expect(tookChange(null, null), (words: '', up: null));
    });

    test('the hub\'s answer, read into names', () {
      final report = KitchenTimes.fromJson(week());
      final span = report.span;
      expect((span.first, span.last, span.running), (DateTime(2026, 11, 9), DateTime(2026, 11, 15), false));
      expect((report.lateMin, report.maxDays, report.nowMs), (20, 92, ms(21)));
      expect(
        (span.made.tickets, span.made.avgMs, span.made.medianMs, span.made.longestMs, span.made.late, span.made.open),
        (412, 684000, 540000, 2820000, 31, 6),
      );
      expect((span.out.tickets, span.out.open, span.timedNothing), (228, 1, false));
      expect(span.stations.map((s) => (s.code, s.name, s.took.tickets)), [
        ('wok', 'Wok', 180),
        ('fryer', 'Fryer', 150),
        ('sushi', 'Sushi bar', 82),
      ]);
      expect(span.silent.map((s) => (s.name, s.took.open, s.took.tickets)), [('Bar', 96, 0), ('takeout', 1, 0)]);
      expect(span.hours.map((h) => h.hour), [11, 18, 19, 0]);
      expect((span.days.length, span.days[2].day, span.days[2].took.avgMs), (7, DateTime(2026, 11, 11), null));
      // a dish says how many times it was timed where a ticket says how many tickets
      expect((span.dishes.first.name, span.dishes.first.took.tickets, span.dishes.length), ('Peking duck', 6, 12));
      expect(span.slowest.map((s) => (s.title, s.station)), [
        ('Table 12', 'Wok'),
        ('#14 Linda', 'takeout'),
        ('Tab Mike', 'Sushi bar'),
      ]);
      expect(
        (report.before.first, report.before.made.tickets, report.before.out.avgMs),
        (DateTime(2026, 11, 2), 390, null),
      );
      expect(report.before.stations, isEmpty);
    });

    test('an answer with nothing in it timed nothing', () {
      final report = KitchenTimes.fromJson({
        'span': {'first': '2026-11-16', 'last': '2026-11-16'},
      });
      expect(report.span.timedNothing, isTrue);
      expect((report.span.made.tickets, report.span.made.avgMs), (0, null));
      expect(report.span.stations, isEmpty);
      expect((report.lateMin, report.maxDays, report.before.made.tickets), (0, 92, 0));
    });

    test('whose a ticket was', () {
      SlowTicket of(Map<String, dynamic> json) => SlowTicket.fromJson({'order_id': 'o', ...json});
      expect(of({'table': '12'}).title, 'Table 12');
      expect(of({}).title, 'No table');
      expect(of({'tab': 'Mike', 'table': '3'}).title, 'Tab Mike');
      expect(of({'to_go': true, 'order_no': 14, 'customer': 'Linda'}).title, '#14 Linda');
      expect(of({'to_go': true, 'order_no': 14}).title, '#14');
      expect(of({'to_go': true}).title, 'To go');
      // a station with no name of its own goes by its code
      expect(of({'station': 'wok'}).station, 'wok');
      expect(of({'station': 'wok', 'station_name': 'Wok'}).station, 'Wok');
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token and the days', (tester) async {
      final t = await terminal(tester);
      final running = await t.api.kitchenTimes('tok-admin');
      await t.api.kitchenTimes('tok-admin', from: '2026-11-09', to: '2026-11-15');
      await t.api.kitchenTimes('tok-admin', from: '2026-11-12');
      expect(t.hub.kitchenTimesAsks, ['', theWeek, '2026-11-12..2026-11-12']);
      expect(t.hub.kitchenTimesAuth, 'Bearer tok-admin');
      expect((running.span.first, running.before.first), (DateTime(2026, 11, 16), DateTime(2026, 11, 9)));
      expect(running.span.timedNothing, isTrue);
    });
  });

  group('the screen', () {
    testWidgets('Location settings opens Kitchen times with the manager\'s token', (tester) async {
      final t = await terminal(tester);
      t.hub.kitchenTimes = {theWeek: week()};
      tester.view.physicalSize = wholeLocation;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'kitchen-times-report');
      expect(find.text('How long tickets take, by station, hour and dish'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kitchen-times-report')));
      await tester.pumpAndSettle();
      expect(find.byType(KitchenTimesScreen), findsOneWidget);
      expect(t.hub.kitchenTimesAsks, hasLength(1));
      expect(t.hub.kitchenTimesAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('kitchen-times-days')), findsOneWidget); // (the days of the real clock)
    });

    testWidgets('it opens on the seven days just gone: the tickets, beside the week before', (tester) async {
      final k = await pumpTimes(tester);
      expect(k.t.hub.kitchenTimesAsks, [theWeek]);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('kitchen-times:week'))).selected, isTrue);
      expect(find.text('Mon, Nov 9 to Sun, Nov 15, 2026'), findsOneWidget);
      expect(find.text('Beside the same days a week before: Mon, Nov 2 to Sun, Nov 8.'), findsOneWidget);
      expect(find.byKey(const ValueKey('kitchen-times-running')), findsNothing);
      expect(row(tester, 'made-avg'), ['Average ticket', '13 min before · 2 min quicker', '11 min']);
      expect(row(tester, 'made-median'), ['Half were made within', '10 min before · 1 min quicker', '9 min']);
      expect(row(tester, 'made-longest'), ['Longest', '55 min before · 8 min quicker', '47 min']);
      expect(row(tester, 'made-late'), ['Took 20 min or more', '8% of them · 11% before', '31']);
      expect(row(tester, 'made-count'), ['Tickets timed', '390 before · up 5.6%', '412']);
      expect(row(tester, 'made-open'), ['6 more were sent and not marked made: in none of these times.']);
      expect(find.byKey(const ValueKey('kitchen-times-nothing')), findsNothing);
      expect(find.byKey(const ValueKey('kitchen-times-note')), findsOneWidget);
    });

    testWidgets('how long a send took to go out, where the pass or the servers said so', (tester) async {
      await pumpTimes(tester);
      expect(row(tester, 'out'), ['Until it went out', '16 min']);
      // nothing went out the week before: said once, with no figure made up for it
      expect(row(tester, 'out-avg'), ['Average', 'nothing before', '16 min']);
      expect(row(tester, 'out-median'), ['Half went out within', 'nothing before', '14 min']);
      expect(row(tester, 'out-late'), ['Took 20 min or more', '26% of them', '60']);
      expect(row(tester, 'out-count'), ['Sends timed', 'nothing before', '228']);
      expect(row(tester, 'out-open'), ['1 more was not marked gone out: in none of these times.']);
      // a kitchen where nobody marks a dish gone out has no such section
      await pumpTimes(tester, times: {theWeek: today()});
      expect(find.byKey(const ValueKey('kitchen-times-out')), findsNothing);
      expect(find.byKey(const ValueKey('kitchen-times-out-avg')), findsNothing);
    });

    testWidgets('each station that marks, and the ones that were sent tickets and marked none', (tester) async {
      await pumpTimes(tester);
      expect(keyed(tester, 'station:'), ['wok', 'fryer', 'sushi']);
      expect(row(tester, 'station:wok'), [
        'Wok',
        '180 tickets',
        '13 min',
        'half within 11 min · longest 47 min · 22 took 20 min or more · 4 not marked',
      ]);
      expect(row(tester, 'station:sushi'), [
        'Sushi bar',
        '82 tickets',
        '15 min',
        'half within 13 min · longest 41 min · 6 took 20 min or more',
      ]);
      expect(keyed(tester, 'silent:'), ['bar', 'takeout']);
      expect(row(tester, 'silent:bar'), ['Bar: 96 tickets sent, none marked made. In none of the times.']);
      expect(row(tester, 'silent:takeout'), ['takeout: 1 ticket sent, none marked made. In none of the times.']);
    });

    testWidgets('each hour and each day: a bar against the slowest, red where the average is late', (tester) async {
      await pumpTimes(tester);
      final heading = tester.element(find.byKey(const ValueKey('kitchen-times-by-hour')));
      final quiet = Theme.of(heading).colorScheme.outline, red = PosColors.of(heading).timerLate;
      // in the order of a night: the hour after midnight is the last
      expect(keyed(tester, 'hour:'), ['11', '18', '19', '0']);
      expect(row(tester, 'hour:19'), ['7 PM', '21 min', '200 tickets']);
      expect(row(tester, 'hour:0'), ['12 AM', 'under 1 min', '12 tickets']);
      expect(bar(tester, 'hour:19'), (1, red));
      expect(bar(tester, 'hour:18').$1, closeTo(10.6 / 21.2, 0.001));
      expect(bar(tester, 'hour:18').$2, quiet);
      expect(find.textContaining('A red bar is an average of 20 min or more.'), findsOneWidget);
      expect(keyed(tester, 'day:'), [for (var day = 9; day <= 15; day++) '2026-11-${day.toString().padLeft(2, '0')}']);
      expect(row(tester, 'day:2026-11-14'), ['Sat, Nov 14', '23 min', '110 tickets']);
      expect(bar(tester, 'day:2026-11-14'), (1, red));
      // a day the kitchen marked nothing has its row all the same, with no bar
      expect(row(tester, 'day:2026-11-11'), ['Wed, Nov 11', '–', 'none timed']);
      expect(bar(tester, 'day:2026-11-11'), (0, quiet));
    });

    testWidgets('the dishes from the slowest: ten of them, then all on asking', (tester) async {
      await pumpTimes(tester);
      expect(keyed(tester, 'dish:'), hasLength(10));
      expect(keyed(tester, 'dish:').take(3), ['Peking duck', 'Dragon roll', "General Tso's Chicken"]);
      expect(row(tester, 'dish:Peking duck'), ['Peking duck', 'longest 47 min', '6×', '38 min']);
      expect(find.text('All 12 dishes'), findsOneWidget);
      await tapKey(tester, 'kitchen-times-every-dish');
      expect(keyed(tester, 'dish:'), hasLength(12));
      expect(keyed(tester, 'dish:').last, 'Dish number 12');
      expect(find.byKey(const ValueKey('kitchen-times-every-dish')), findsNothing);
      // other days begin with the slowest few again
      await tapKey(tester, 'kitchen-times:today');
      await tapKey(tester, 'kitchen-times:week');
      expect(keyed(tester, 'dish:'), hasLength(10));
    });

    testWidgets('the longest tickets by name, with their station and when they were sent', (tester) async {
      await pumpTimes(tester);
      expect(keyed(tester, 'slow:'), ['0', '1', '2']);
      expect(row(tester, 'slow:0'), ['Table 12', '47 min', 'Wok · sent Sat, Nov 14, 7:12 PM']);
      expect(row(tester, 'slow:1'), ['#14 Linda', '41 min', 'takeout · sent Fri, Nov 13, 6:40 PM']);
      expect(row(tester, 'slow:2'), ['Tab Mike', '41 min', 'Sushi bar · sent Sat, Nov 14, 8:05 PM']);
      // of a single day the hour is enough
      await tapKey(tester, 'kitchen-times:today');
      expect(row(tester, 'slow:0'), ['Table 4', '22 min', 'Wok · sent 6:40 PM']);
    });

    testWidgets('quicker is green and slower is red, and how many tickets is neither', (tester) async {
      await pumpTimes(tester);
      Color? moved(String key) {
        final line = tester
            .widgetList<Text>(
              find.descendant(of: find.byKey(ValueKey('kitchen-times-$key')), matching: find.byType(Text)),
            )
            .firstWhere((text) => text.textSpan != null);
        return ((line.textSpan! as TextSpan).children!.last as TextSpan).style!.color;
      }

      final error = Theme.of(tester.element(find.byKey(const ValueKey('kitchen-times-made-avg')))).colorScheme.error;
      final quicker = moved('made-avg');
      expect(quicker, isNotNull);
      expect(quicker, isNot(error));
      expect(moved('made-longest'), quicker);
      expect(moved('made-count'), isNull);
      expect(moved('out-avg'), isNull);
      await tapKey(tester, 'kitchen-times:today');
      expect(row(tester, 'made-avg'), ['Average ticket', '8 min before · 2 min slower', '10 min']);
      expect(moved('made-avg'), error);
      expect(row(tester, 'made-median'), ['Half were made within', '9 min before · the same', '9 min']);
      expect(moved('made-median'), isNull);
      expect(moved('made-longest'), quicker);
    });

    testWidgets('Today is the day running; Yesterday and 4 weeks ask for whole days by name', (tester) async {
      final k = await pumpTimes(tester);
      await tapKey(tester, 'kitchen-times:today');
      expect(k.t.hub.kitchenTimesAsks.last, '');
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      expect(find.text('Beside the same day a week before: Mon, Nov 9.'), findsOneWidget);
      expect(find.byKey(const ValueKey('kitchen-times-running')), findsOneWidget);
      expect(row(tester, 'made-open'), ['3 more were sent and not marked made: in none of these times.']);
      // one day has no list of days, and its hours are its own
      expect(find.byKey(const ValueKey('kitchen-times-by-day')), findsNothing);
      expect(
        find.text('The average ticket by the hour it was sent in. A red bar is an average of 20 min or more.'),
        findsOneWidget,
      );
      await tapKey(tester, 'kitchen-times:yesterday');
      await tapKey(tester, 'kitchen-times:four-weeks');
      expect(k.t.hub.kitchenTimesAsks.skip(2), ['2026-11-15..2026-11-15', '2026-10-19..2026-11-15']);
      // in the small hours the day of service is still the one before
      final late = await pumpTimes(tester, now: at(2, 30, 17));
      await tapKey(tester, 'kitchen-times:yesterday');
      expect(late.t.hub.kitchenTimesAsks, [theWeek, '2026-11-15..2026-11-15']);
    });

    testWidgets('a kitchen that marks nothing has no times, and the screen says why', (tester) async {
      // nothing was sent at all
      await pumpTimes(tester, times: {});
      expect(row(tester, 'nothing').first, 'No ticket was marked made on these days, so there is nothing to time.');
      expect(row(tester, 'nothing').last, contains('A kitchen that works off paper alone has none.'));
      for (final key in ['made-avg', 'out', 'by-station', 'by-hour', 'by-day', 'dishes', 'slowest']) {
        expect(find.byKey(ValueKey('kitchen-times-$key')), findsNothing, reason: key);
      }
      expect(find.byKey(const ValueKey('kitchen-times-note')), findsOneWidget);
      // tickets were sent and none marked: how many, and to which stations
      final paper = <String, dynamic>{
        'span': {
          'first': '2026-11-09',
          'last': '2026-11-15',
          'silent': [
            {'code': 'wok', 'name': 'Wok', 'open': 200},
            {'code': 'bar', 'name': 'Bar', 'open': 96},
          ],
        },
        'before': {'first': '2026-11-02', 'last': '2026-11-08'},
        'late_min': 20,
        'max_days': 92,
        'now_ms': ms(21),
      };
      await pumpTimes(tester, times: {theWeek: paper});
      expect(
        row(tester, 'nothing').first,
        'No ticket was marked made on these days, so there is nothing to time. 296 tickets were sent.',
      );
      expect(keyed(tester, 'silent:'), ['wok', 'bar']);
      // one day says "this day", and one ticket is one
      (paper['span'] as Map<String, dynamic>)
        ..['last'] = '2026-11-09'
        ..['silent'] = [
          {'code': 'wok', 'name': 'Wok', 'open': 1},
        ];
      await pumpTimes(tester, times: {theWeek: paper});
      expect(
        row(tester, 'nothing').first,
        'No ticket was marked made on this day, so there is nothing to time. 1 ticket was sent.',
      );
    });

    testWidgets('servers say what went out and no cook marks: the sends have times, the stations none', (tester) async {
      final carried = week();
      (carried['span'] as Map<String, dynamic>)
        ..['made'] = took(0, null, null, null)
        ..['stations'] = <Object>[]
        ..['silent'] = [
          {'code': 'wok', 'name': 'Wok', 'open': 228},
        ]
        ..['hours'] = <Object>[]
        ..['dishes'] = <Object>[]
        ..['slowest'] = <Object>[];
      await pumpTimes(tester, times: {theWeek: carried});
      expect(
        row(tester, 'nothing').first,
        'No ticket was marked made on these days, so no station has a time. 228 tickets were sent.',
      );
      expect(find.byKey(const ValueKey('kitchen-times-made-avg')), findsNothing);
      expect(row(tester, 'out-avg'), ['Average', 'nothing before', '16 min']);
      expect(keyed(tester, 'silent:'), ['wok']);
    });

    testWidgets('a location whose tickets never turn red counts none late', (tester) async {
      final plain = week()..['late_min'] = 0;
      await pumpTimes(tester, times: {theWeek: plain});
      expect(find.byKey(const ValueKey('kitchen-times-made-late')), findsNothing);
      expect(find.byKey(const ValueKey('kitchen-times-out-late')), findsNothing);
      expect(row(tester, 'station:wok').last, 'half within 11 min · longest 47 min · 4 not marked');
      final scheme = Theme.of(tester.element(find.byKey(const ValueKey('kitchen-times-by-hour')))).colorScheme;
      expect(bar(tester, 'hour:19'), (1, scheme.outline));
      expect(find.textContaining('A red bar'), findsNothing);
    });

    testWidgets('Other days asks the calendar, and more days than the hub adds up are said', (tester) async {
      final k = await pumpTimes(tester);
      await tapKey(tester, 'kitchen-times:other'); // the calendar closed without any day: nothing changes
      expect(k.asked, [null]);
      expect(k.t.hub.kitchenTimesAsks, [theWeek]);
      k.picks.add(DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'kitchen-times:other');
      expect(k.t.hub.kitchenTimesAsks, [theWeek, '2026-10-01..2026-10-10']);
      expect(find.text('Oct 1 to Oct 10'), findsOneWidget);
      expect(find.text('Thu, Oct 1 to Sat, Oct 10, 2026'), findsOneWidget);
      k.picks.add(DateTimeRange(start: DateTime(2026, 7, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'kitchen-times:other');
      expect(find.byKey(const ValueKey('kitchen-times-too-long')), findsOneWidget);
      expect(find.text('At most 92 days at a time: that was 102. Pick fewer days.'), findsOneWidget);
      expect(k.t.hub.kitchenTimesAsks, hasLength(2));
    });

    testWidgets('other days start the list from its top; reading again stays where it was', (tester) async {
      await pumpTimes(tester, size: const Size(390, 844));
      double offset() => tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
      await tester.drag(find.byKey(const ValueKey('kitchen-times-list')), const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrolled = offset();
      expect(scrolled, greaterThan(100));
      await tester.tap(find.byKey(const ValueKey('kitchen-times-refresh')));
      await tester.pumpAndSettle();
      expect(offset(), scrolled);
      await tester.tap(find.byKey(const ValueKey('kitchen-times:today')));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
    });

    testWidgets('while the hub adds up, the screen says so', (tester) async {
      final k = await pumpTimes(tester);
      final held = k.t.hub.kitchenTimesHeld = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('kitchen-times:yesterday')));
      await tester.pump();
      expect(find.text('Adding up the days'), findsOneWidget);
      expect(find.text('Many days can take some seconds the first time.'), findsNothing);
      expect(find.byKey(const ValueKey('kitchen-times-made-avg')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('kitchen-times:four-weeks')));
      await tester.pump();
      expect(find.text('Many days can take some seconds the first time.'), findsOneWidget);
      held.complete();
      k.t.hub.kitchenTimesHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('kitchen-times-reading')), findsNothing);
      expect(find.text('Mon, Oct 19 to Sun, Nov 15, 2026'), findsOneWidget);
    });

    testWidgets('the manager\'s hour is over, the hub is older, refuses or does not answer: the screen says which', (
      tester,
    ) async {
      await pumpTimes(tester, before: (hub) => hub.refuseKitchenTimes = 401);
      expect(find.text("The manager's hour here is over: go back and open Location again."), findsOneWidget);
      await pumpTimes(tester, older: true);
      expect(find.text('This hub is older than the kitchen times. Update the hub to see it here.'), findsOneWidget);
      final refused = await pumpTimes(
        tester,
        before: (hub) => hub
          ..refuseKitchenTimes = 422
          ..salesRefusal = 'At most 92 days at a time.',
      );
      expect(find.text('At most 92 days at a time.'), findsOneWidget);
      refused.t.hub.refuseKitchenTimes = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('kitchen-times-error')), findsNothing);
      expect(row(tester, 'made-count').last, '412');
      final down = await pumpTimes(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
      down.t.hub.down = false;
    });

    testWidgets('on a small phone with large text everything fits, in the dark too', (tester) async {
      final big = week();
      final span = big['span'] as Map<String, dynamic>;
      span['made'] = took(123456, 185.4, 170, 1439, late: 99999, open: 12345);
      span['stations'] = [
        {
          'code': 'wok',
          'name': 'The wok line at the back of the kitchen',
          ...took(123456, 185.4, 170, 1439, late: 99999, open: 12345),
        },
      ];
      span['dishes'] = [
        dish('Lobster with ginger and scallion over pan-fried noodles, family size', 1234, 185.4, 1439),
      ];
      span['slowest'] = [
        slow(
          'o1',
          'wok',
          'The wok line at the back of the kitchen',
          ms(19, 12, 14),
          1439,
          orderNo: 1234,
          customer: 'Bartholomew Featherstonehaugh',
          toGo: true,
        ),
      ];
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        await pumpTimes(
          tester,
          times: {theWeek: big, '': today()},
          size: const Size(320, 568),
          theme: theme,
          textScale: 1.6,
        );
        final list = find.byType(Scrollable).first;
        for (final key in ['made-open', 'out-open', 'silent:takeout', 'hour:0', 'day:2026-11-15', 'slow:0', 'note']) {
          await tester.scrollUntilVisible(find.byKey(ValueKey('kitchen-times-$key')), 200, scrollable: list);
          expect(tester.takeException(), isNull, reason: key);
        }
        await tapKey(tester, 'kitchen-times:today');
        expect(tester.takeException(), isNull);
      }
    });
  });
}
