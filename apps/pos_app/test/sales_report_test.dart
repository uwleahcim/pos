import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/sales_report.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/sales_screen.dart';

import 'hub.dart';

/// Sales over any days (docs/sales-report.md): what a manager reads to see how a week went beside the one
/// before. The hub does every sum; these tests are about the screen saying what the hub said, asking for
/// the right days, and saying how far two figures are apart.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

Map<String, dynamic> day(String name, int checks, int guests, String net) => {
  'day': name,
  'checks': checks,
  'guests': guests,
  'gross': net,
  'net': net,
  'total': net,
};

/// The week of Monday 9 November beside the week before it, as a hub with the time clock answers.
Map<String, dynamic> week() => {
  'span': {
    'first': '2026-11-09',
    'last': '2026-11-15',
    'since_ms': ms(4, 0, 9),
    'until_ms': ms(4),
    'running': false,
    'checks': 412,
    'guests': 903,
    'sales': {
      'gross': '14210.50',
      'discounts': '310.25',
      'net': '13900.25',
      'charges': '45.00',
      'gratuity': '180.00',
      'tax': '973.02',
      'total': '15098.27',
    },
    'per_check': '33.74',
    'per_guest': '14.02',
    'turn': {'tables': 268, 'minutes': 62},
    'days': [
      day('2026-11-09', 41, 88, '1210.00'),
      day('2026-11-10', 38, 80, '1105.50'),
      day('2026-11-11', 45, 96, '1390.25'),
      day('2026-11-12', 52, 110, '1720.00'),
      day('2026-11-13', 84, 190, '3105.75'),
      day('2026-11-14', 96, 221, '3498.25'),
      day('2026-11-15', 56, 118, '1870.50'),
    ],
    'hours': [
      {'hour': 11, 'count': 120, 'amount': '1310.00'},
      {'hour': 18, 'count': 610, 'amount': '8200.50'},
      {'hour': 0, 'count': 40, 'amount': '4700.00'},
    ],
    'menus': [
      {'menu': 'dinner', 'name': 'Dinner', 'count': 1480, 'amount': '11000.50'},
      {'menu': 'drinks', 'name': 'Drinks', 'count': 520, 'amount': '3210.00'},
    ],
    'categories': [
      {'menu': 'dinner', 'code': 'rolls', 'name': 'Rolls', 'count': 610, 'amount': '6800.50'},
      {'menu': 'dinner', 'code': 'sides', 'name': 'Appetizers', 'count': 870, 'amount': '4200.00'},
      {'menu': 'drinks', 'code': 'beer', 'name': 'Beer', 'count': 400, 'amount': '2400.00'},
      {'menu': 'drinks', 'code': 'sake', 'name': 'Sake', 'count': 120, 'amount': '810.00'},
    ],
    'kinds': [
      {'kind': 'dine_in', 'guests': 903, 'count': 300, 'amount': '11200.50'},
      {'kind': 'takeout', 'guests': 0, 'count': 112, 'amount': '3010.00'},
    ],
    'discounts': [
      {'name': 'Manager comp', 'count': 6, 'amount': '246.25'},
      {'name': 'Loyalty reward', 'count': 32, 'amount': '64.00'},
    ],
    'money': {
      'taken': [
        {'method': 'cash', 'count': 140, 'amount': '4100.00'},
        {'method': 'card', 'count': 262, 'amount': '10600.27'},
        {'method': 'elsewhere', 'count': 11, 'amount': '398.00'},
      ],
      'taken_total': '15098.27',
    },
    'clock': {'worked_ms': 312 * 3600000, 'people': 14, 'unended': 0, 'net_per_hour': '44.55'},
  },
  'before': {
    'first': '2026-11-02',
    'last': '2026-11-08',
    'running': false,
    'checks': 398,
    'guests': 921,
    'sales': {
      'gross': '12700.00',
      'discounts': '290.00',
      'net': '12410.00',
      'charges': '0.00',
      'gratuity': '150.00',
      'tax': '868.70',
      'total': '13428.70',
    },
    'per_check': '31.18',
    'per_guest': '13.47',
    'turn': {'tables': 255, 'minutes': 58},
    'days': [
      day('2026-11-02', 40, 90, '1100.00'),
      day('2026-11-03', 39, 84, '1105.50'),
      day('2026-11-04', 44, 95, '1300.00'),
      day('2026-11-05', 50, 108, '1600.00'),
      day('2026-11-06', 80, 196, '2804.50'),
      day('2026-11-07', 92, 230, '3600.00'),
      day('2026-11-08', 53, 118, '900.00'),
    ],
    'hours': [
      {'hour': 11, 'count': 110, 'amount': '1200.00'},
      {'hour': 14, 'count': 30, 'amount': '300.00'},
      {'hour': 18, 'count': 590, 'amount': '7700.00'},
      {'hour': 0, 'count': 38, 'amount': '3500.00'},
    ],
    'menus': [
      {'menu': 'dinner', 'name': 'Dinner', 'count': 1400, 'amount': '10000.00'},
      {'menu': 'drinks', 'name': 'Drinks', 'count': 480, 'amount': '2700.00'},
    ],
    'categories': [
      {'menu': 'dinner', 'code': 'rolls', 'name': 'Rolls', 'count': 560, 'amount': '6000.00'},
      {'menu': 'dinner', 'code': 'sides', 'name': 'Appetizers', 'count': 840, 'amount': '4000.00'},
      {'menu': 'drinks', 'code': 'beer', 'name': 'Beer', 'count': 480, 'amount': '2700.00'},
    ],
    'kinds': [
      {'kind': 'dine_in', 'guests': 921, 'count': 290, 'amount': '10000.00'},
      {'kind': 'takeout', 'guests': 0, 'count': 108, 'amount': '2700.00'},
    ],
    'discounts': [
      {'name': 'Manager comp', 'count': 7, 'amount': '290.00'},
    ],
    'money': {
      'taken': [
        {'method': 'cash', 'count': 150, 'amount': '4100.00'},
        {'method': 'card', 'count': 240, 'amount': '9328.70'},
      ],
      'taken_total': '13428.70',
    },
    'clock': {'worked_ms': 300 * 3600000, 'people': 13, 'unended': 0, 'net_per_hour': '41.37'},
  },
  'max_days': 92,
  'now_ms': ms(21),
};

/// The evening that is running beside the Monday before, on a hub that does not use the time clock.
Map<String, dynamic> today() => {
  'span': {
    'first': '2026-11-16',
    'last': '2026-11-16',
    'running': true,
    'checks': 4,
    'guests': 8,
    'sales': {
      'gross': '58.60',
      'discounts': '2.00',
      'net': '56.60',
      'charges': '0.00',
      'gratuity': '0.00',
      'tax': '3.96',
      'total': '60.56',
    },
    'per_check': '14.15',
    'per_guest': '4.96',
    'turn': {'tables': 2, 'minutes': 61},
    'days': [day('2026-11-16', 4, 8, '56.60')],
    'hours': [
      {'hour': 17, 'count': 3, 'amount': '15.95'},
      {'hour': 20, 'count': 4, 'amount': '42.65'},
    ],
    'menus': [
      {'menu': 'dinner', 'name': 'Dinner', 'count': 7, 'amount': '58.60'},
    ],
    'categories': [
      {'menu': 'dinner', 'code': 'sides', 'name': 'Appetizers', 'count': 7, 'amount': '58.60'},
    ],
    'kinds': [
      {'kind': 'dine_in', 'guests': 8, 'count': 3, 'amount': '41.65'},
      {'kind': 'takeout', 'guests': 0, 'count': 1, 'amount': '16.95'},
    ],
    'discounts': [
      {'name': 'Loyalty reward', 'count': 1, 'amount': '2.00'},
    ],
    'money': {
      'taken': [
        {'method': 'cash', 'count': 2, 'amount': '25.00'},
      ],
      'taken_total': '25.00',
    },
    'clock': null,
  },
  'before': {
    'first': '2026-11-09',
    'last': '2026-11-09',
    'running': false,
    'checks': 2,
    'guests': 3,
    'sales': {'gross': '41.35', 'discounts': '0.00', 'net': '41.35', 'tax': '2.89', 'total': '44.24'},
    'per_check': '20.68',
    'per_guest': '8.13',
    'turn': {'tables': 1, 'minutes': 50},
    'days': [day('2026-11-09', 2, 3, '41.35')],
    'clock': null,
  },
  'max_days': 92,
  'now_ms': ms(21),
};

class Sales {
  Sales(this.t);
  final Terminal t;
  final picks = <DateTimeRange>[];
  final asked = <DateTimeRange?>[];

  Future<DateTimeRange?> pickSpan(BuildContext context, DateTimeRange? from) async {
    asked.add(from);
    return picks.isEmpty ? null : picks.removeAt(0);
  }
}

const theWeek = '2026-11-09..2026-11-15';

Future<Sales> pumpSales(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? sales,
  bool older = false,
  Size size = const Size(1100, 3600),
  DateTime? now,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.sales = older ? null : (sales ?? {theWeek: week(), '': today()});
  before?.call(t.hub);
  tester.view.physicalSize = size;
  final s = Sales(t);
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      home: SalesScreen(api: t.api, token: 'tok-admin', now: () => now ?? at(21), pickSpan: s.pickSpan),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Every text inside the row with that key, in order (a line in two colours as the one line it reads as).
List<String> row(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
];

void main() {
  group('what the report reads', () {
    test('the hub\'s answer, read into names', () {
      final report = SalesReport.fromJson(week());
      final span = report.span, before = report.before;
      expect((span.first, span.last, span.dayCount), (DateTime(2026, 11, 9), DateTime(2026, 11, 15), 7));
      expect((before.first, before.last, report.weeksBack), (DateTime(2026, 11, 2), DateTime(2026, 11, 8), 1));
      expect((span.checks, span.guests, span.net, span.total), (412, 903, '13900.25', '15098.27'));
      expect((span.perCheck, span.perGuest, span.turnTables, span.turnMinutes), ('33.74', '14.02', 268, 62));
      expect([for (final d in span.days) d.net].first, '1210.00');
      expect(span.days.map((d) => d.day.day), [9, 10, 11, 12, 13, 14, 15]);
      expect(span.hours.map((h) => h.hour), [11, 18, 0]);
      expect(span.categoriesOf('drinks').map((c) => c.name), ['Beer', 'Sake']);
      expect(span.kinds.map((k) => (k.name, k.count, k.guests)), [('dine_in', 300, 903), ('takeout', 112, 0)]);
      expect(span.taken.map((m) => m.name), ['cash', 'card', 'elsewhere']);
      expect((span.clock!.workedMs, span.clock!.people, span.clock!.netPerHour), (312 * 3600000, 14, '44.55'));
      expect((report.maxDays, report.nowMs, span.running), (92, ms(21), false));
    });

    test('an answer with nothing in it reads as zeroes, and no average is no figure', () {
      final report = SalesReport.fromJson({
        'span': {
          'first': '2026-11-16',
          'last': '2026-11-16',
          'per_check': null,
          'turn': {'tables': 0, 'minutes': null},
        },
        'before': <String, dynamic>{},
      });
      final span = report.span;
      expect((span.checks, span.net, span.perCheck, span.perGuest, span.turnMinutes), (0, '0.00', null, null, null));
      expect(span.days, isEmpty);
      expect((span.clock, span.dayCount, report.weeksBack, report.maxDays), (null, 1, 1, 92));
    });

    test('how many weeks back the days beside lie', () {
      SalesReport of(String first, String last) => SalesReport.fromJson({
        'span': {'first': first, 'last': last},
        'before': <String, dynamic>{},
      });
      expect(of('2026-11-16', '2026-11-16').weeksBack, 1);
      expect(of('2026-11-09', '2026-11-15').weeksBack, 1);
      expect(of('2026-11-09', '2026-11-16').weeksBack, 2); // eight days
      expect(of('2026-10-19', '2026-11-15').weeksBack, 4);
      // the night the clocks go back (1 November 2026) is one day like any other
      expect(of('2026-10-26', '2026-11-01').span.dayCount, 7);
      expect(of('2026-03-02', '2026-03-08').span.dayCount, 7); // and the night they go forward
    });

    test('how far two figures are apart, for a person', () {
      expect(changeWords(13900.25, 12410), (words: 'up 12%', up: true));
      expect(changeWords(412, 398), (words: 'up 3.5%', up: true));
      expect(changeWords(903, 921), (words: 'down 2%', up: false));
      expect(changeWords(33.74, 31.18), (words: 'up 8.2%', up: true));
      expect(changeWords(50, 100), (words: 'down 50%', up: false));
      expect(changeWords(350, 100), (words: 'up 250%', up: true));
      expect(changeWords(100000, 100001), (words: 'down under 0.1%', up: false));
      expect(changeWords(40, 40), (words: 'the same', up: null));
      expect(changeWords(40, 0), (words: 'nothing before', up: null));
      expect(changeWords(0, 40), (words: 'down 100%', up: false));
      expect(changeWords(0, 0), (words: '', up: null));
    });

    test('a table\'s time in words', () {
      expect(
        [minutesWords(45), minutesWords(60), minutesWords(62), minutesWords(0)],
        ['45 min', '1 h', '1 h 2 min', '0 min'],
      );
    });

    test('the days each choice asks for', () {
      expect(spanOf(SalesChoice.today, at(21)), (null, null)); // the hub knows which day is running
      expect(spanOf(SalesChoice.yesterday, at(21)), ('2026-11-15', '2026-11-15'));
      expect(spanOf(SalesChoice.week, at(21)), ('2026-11-09', '2026-11-15')); // the seven whole days just gone
      expect(spanOf(SalesChoice.fourWeeks, at(21)), ('2026-10-19', '2026-11-15'));
      // at half past one in the morning the day running is still the 15th
      expect(spanOf(SalesChoice.yesterday, at(1, 30)), ('2026-11-14', '2026-11-14'));
      expect(spanOf(SalesChoice.week, at(1, 30)), ('2026-11-08', '2026-11-14'));
      expect(spanOf(SalesChoice.other, at(21), first: DateTime(2026, 10, 1), last: DateTime(2026, 10, 31)), (
        '2026-10-01',
        '2026-10-31',
      ));
      expect(spanOf(SalesChoice.other, at(21), first: DateTime(2026, 10, 1)), ('2026-10-01', '2026-10-01'));
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token and the days', (tester) async {
      final t = await terminal(tester);
      final running = await t.api.salesReport('tok-admin');
      await t.api.salesReport('tok-admin', from: '2026-11-09', to: '2026-11-15');
      await t.api.salesReport('tok-admin', from: '2026-11-12');
      expect(t.hub.salesAsks, ['', theWeek, '2026-11-12..2026-11-12']);
      expect(t.hub.salesAuth, 'Bearer tok-admin');
      expect((running.span.first, running.before.first), (DateTime(2026, 11, 16), DateTime(2026, 11, 9)));
    });
  });

  group('the screen', () {
    testWidgets('Location settings opens Sales with the manager\'s token', (tester) async {
      final t = await terminal(tester);
      tester.view.physicalSize = const Size(1100, 2800);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'sales-report');
      expect(find.byType(SalesScreen), findsOneWidget);
      expect(t.hub.salesAsks, hasLength(1));
      expect(t.hub.salesAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('sales-net')), findsOneWidget);
    });

    testWidgets('it opens on the seven days just gone, beside the seven before them', (tester) async {
      final s = await pumpSales(tester);
      expect(s.t.hub.salesAsks, [theWeek]);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('sales:week'))).selected, isTrue);
      expect(find.text('Mon, Nov 9 to Sun, Nov 15, 2026'), findsOneWidget);
      expect(find.text('Beside the same days a week before: Mon, Nov 2 to Sun, Nov 8.'), findsOneWidget);
      expect(find.byKey(const ValueKey('sales-running')), findsNothing);
      expect(row(tester, 'sales-net'), ['Net sales', r'$12,410.00 before · up 12%', r'$13,900.25']);
      expect(row(tester, 'sales-checks'), ['Checks', '398 before · up 3.5%', '412']);
      expect(row(tester, 'sales-guests'), ['Guests', '921 before · down 2%', '903']);
      expect(row(tester, 'sales-per-check'), ['Average check', r'$31.18 before · up 8.2%', r'$33.74']);
      expect(row(tester, 'sales-per-guest'), ['Average per guest', r'$13.47 before · up 4.1%', r'$14.02']);
      expect(row(tester, 'sales-turn'), [
        'A table, opened to closed',
        '268 tables · 58 min before · up 6.9%',
        '1 h 2 min',
      ]);
    });

    testWidgets('what the checks come to', (tester) async {
      await pumpSales(tester);
      expect(row(tester, 'sales-sales'), ['Sales', r'$15,098.27']);
      expect(row(tester, 'sales-gross'), ['Dishes sold', r'$14,210.50']);
      expect(row(tester, 'sales-discounts'), ['Comps and discounts', r'-$310.25']);
      expect(find.text('Charges'), findsOneWidget);
      expect(find.text('Paid over to staff'), findsOneWidget);
      expect(row(tester, 'sales-tax'), ['Sales tax', r'$973.02']);
      expect(row(tester, 'sales-total'), ['Total', r'$15,098.27']);
    });

    testWidgets('each day beside the same day a week before', (tester) async {
      await pumpSales(tester);
      expect(row(tester, 'sales-by-day'), ['By day', r'$13,900.25']);
      expect(row(tester, 'sales-day:2026-11-09'), ['Mon, Nov 9', r'$1,210.00', r'$1,100.00']);
      expect(row(tester, 'sales-day:2026-11-14'), ['Sat, Nov 14', r'$3,498.25', r'$3,600.00']);
      expect(row(tester, 'sales-day:2026-11-15'), ['Sun, Nov 15', r'$1,870.50', r'$900.00']);
      expect(find.byKey(const ValueKey('sales-day:2026-11-16')), findsNothing);
      // both bars of every row are drawn to one scale: the longest is the best day of either week
      double width(String key, int which) => tester
          .widget<FractionallySizedBox>(
            find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(FractionallySizedBox)).at(which),
          )
          .widthFactor!;
      expect(width('sales-day:2026-11-14', 1), 1.0); // the Saturday before, 3,600.00
      expect(width('sales-day:2026-11-14', 0), closeTo(3498.25 / 3600, 0.0001));
      expect(width('sales-day:2026-11-15', 1), 0.25);
    });

    testWidgets('each hour in the order of a night, with an hour only the days before sold in', (tester) async {
      await pumpSales(tester);
      final hours = [
        for (final key in tester.widgetList<Padding>(
          find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('sales-hour:'),
          ),
        ))
          (key.key! as ValueKey<String>).value,
      ];
      expect(hours, ['sales-hour:11', 'sales-hour:14', 'sales-hour:18', 'sales-hour:0']);
      expect(row(tester, 'sales-hour:18'), ['6 PM', r'$8,200.50', r'$7,700.00']);
      expect(row(tester, 'sales-hour:14'), ['2 PM', r'$0.00', r'$300.00']);
      expect(row(tester, 'sales-hour:0'), ['12 AM', r'$4,700.00', r'$3,500.00']);
    });

    testWidgets('each category under its menu, each kind of order, the money and the comps', (tester) async {
      await pumpSales(tester);
      expect(row(tester, 'sales-categories'), ['By category', r'$14,210.50']);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('Drinks'), findsOneWidget);
      expect(row(tester, 'sales-category:dinner:Rolls'), [
        'Rolls',
        r'$6,000.00 before · up 13.3%',
        '610×',
        r'$6,800.50',
      ]);
      expect(row(tester, 'sales-category:drinks:Beer'), [
        'Beer',
        r'$2,700.00 before · down 11.1%',
        '400×',
        r'$2,400.00',
      ]);
      expect(row(tester, 'sales-category:drinks:Sake'), ['Sake', 'nothing before', '120×', r'$810.00']);
      expect(row(tester, 'sales-kind:dine_in'), [
        'Tables',
        r'300 checks · 903 guests · $10,000.00 before · up 12%',
        r'$11,200.50',
      ]);
      expect(row(tester, 'sales-kind:takeout'), ['To go', r'112 checks · $2,700.00 before · up 11.5%', r'$3,010.00']);
      expect(row(tester, 'sales-taken'), ['Money taken', r'$15,098.27']);
      expect(find.text('Every payment recorded in these days, whatever check it was for.'), findsOneWidget);
      expect(row(tester, 'sales-taken:cash'), ['Cash', r'140 payments · $4,100.00 before · the same', r'$4,100.00']);
      expect(row(tester, 'sales-taken:elsewhere'), ['Paid elsewhere', '11 payments · nothing before', r'$398.00']);
      expect(row(tester, 'sales-off'), ['Comps and discounts', r'-$310.25']);
      expect(row(tester, 'sales-discount:Manager comp'), [
        'Manager comp',
        r'-$290.00 before · down 15.1%',
        '6×',
        r'-$246.25',
      ]);
      expect(row(tester, 'sales-discount:Loyalty reward'), ['Loyalty reward', 'nothing before', '32×', r'-$64.00']);
      expect(find.byKey(const ValueKey('sales-note')), findsOneWidget);
    });

    testWidgets('more sold is green and less is red; a table\'s time and the comps are neither', (tester) async {
      await pumpSales(tester);
      Color? moved(String key) {
        final line = tester
            .widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))
            .firstWhere((text) => text.textSpan != null);
        return ((line.textSpan! as TextSpan).children!.last as TextSpan).style!.color;
      }

      final context = tester.element(find.byKey(const ValueKey('sales-net')));
      expect(moved('sales-net'), isNot(Theme.of(context).colorScheme.error));
      expect(moved('sales-net'), isNotNull);
      expect(moved('sales-guests'), Theme.of(context).colorScheme.error);
      expect(moved('sales-turn'), isNull);
      expect(moved('sales-discount:Manager comp'), isNull);
      expect(moved('sales-taken:cash'), isNull);
    });

    testWidgets('where the time clock is used: the hours worked and the sales for each', (tester) async {
      await pumpSales(tester);
      expect(row(tester, 'sales-hours'), ['Hours worked', '14 people · 300 h before · up 4%', '312 h']);
      expect(row(tester, 'sales-per-hour'), ['Net sales per hour worked', r'$41.37 before · up 7.7%', r'$44.55']);
      expect(find.byKey(const ValueKey('sales-unended')), findsNothing);
      // a shift nobody clocked out of makes the hours too many: said, with where to correct it
      final unended = week();
      ((unended['span'] as Map)['clock'] as Map)['unended'] = 2;
      await pumpSales(tester, sales: {theWeek: unended});
      expect(find.textContaining('2 shifts nobody clocked out of'), findsOneWidget);
      // and a location without the time clock has neither row
      await pumpSales(tester, sales: {theWeek: today()});
      expect(find.byKey(const ValueKey('sales-hours')), findsNothing);
      expect(find.byKey(const ValueKey('sales-per-hour')), findsNothing);
    });

    testWidgets('Today: the day running beside the same day a week before, and no list by day', (tester) async {
      final s = await pumpSales(tester);
      await tapKey(tester, 'sales:today');
      expect(s.t.hub.salesAsks, [theWeek, '']); // no day named: the hub knows which one is running
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      expect(find.text('Beside the same day a week before: Mon, Nov 9.'), findsOneWidget);
      expect(find.text('The day is still running: read at 9:00 PM. Its figures will still move.'), findsOneWidget);
      expect(row(tester, 'sales-net'), ['Net sales', r'$41.35 before · up 36.9%', r'$56.60']);
      expect(row(tester, 'sales-turn'), [
        'A table, opened to closed',
        '2 tables · 50 min before · up 22%',
        '1 h 1 min',
      ]);
      expect(find.byKey(const ValueKey('sales-by-day')), findsNothing);
      expect(find.text('Every payment recorded in the day, whatever check it was for.'), findsOneWidget);
      expect(row(tester, 'sales-hour:17'), ['5 PM', r'$15.95', r'$0.00']);
    });

    testWidgets('Yesterday and 4 weeks ask for whole days by name, in the small hours too', (tester) async {
      final s = await pumpSales(tester);
      await tapKey(tester, 'sales:yesterday');
      await tapKey(tester, 'sales:four-weeks');
      await tapKey(tester, 'sales:week');
      expect(s.t.hub.salesAsks, [theWeek, '2026-11-15..2026-11-15', '2026-10-19..2026-11-15', theWeek]);
      // four weeks of nothing: beside the same days four weeks before
      await tapKey(tester, 'sales:four-weeks');
      expect(find.text('Mon, Oct 19 to Sun, Nov 15, 2026'), findsOneWidget);
      expect(find.text('Beside the same days 4 weeks before: Mon, Sep 21 to Sun, Oct 18.'), findsOneWidget);
      // at half past one in the morning the day running is still the 15th: the week ends on the 14th
      final late = await pumpSales(tester, sales: {}, now: at(1, 30));
      await tapKey(tester, 'sales:yesterday');
      expect(late.t.hub.salesAsks, ['2026-11-08..2026-11-14', '2026-11-14..2026-11-14']);
    });

    testWidgets('other days are read from their top, and reading the same days again stays where it was', (
      tester,
    ) async {
      await pumpSales(tester, size: const Size(390, 844));
      double offset() => tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
      await tester.drag(find.byKey(const ValueKey('sales-list')), const Offset(0, -700));
      await tester.pumpAndSettle();
      final scrolled = offset();
      expect(scrolled, greaterThan(500));
      await tester.tap(find.byKey(const ValueKey('sales-refresh')));
      await tester.pumpAndSettle();
      expect(offset(), scrolled);
      await tester.tap(find.byKey(const ValueKey('sales:today')));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
    });

    testWidgets('Other days asks the calendar, and the chip then names the days', (tester) async {
      final s = await pumpSales(tester);
      await tapKey(tester, 'sales:other'); // the calendar closed without any day: nothing changes
      expect(s.asked, [null]);
      expect(s.t.hub.salesAsks, [theWeek]);
      expect(find.text('Other days'), findsOneWidget);
      s.picks.add(DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'sales:other');
      expect(s.t.hub.salesAsks, [theWeek, '2026-10-01..2026-10-10']);
      expect(find.text('Oct 1 to Oct 10'), findsOneWidget);
      expect(find.text('Thu, Oct 1 to Sat, Oct 10, 2026'), findsOneWidget);
      expect(find.text('Beside the same days 2 weeks before: Thu, Sep 17 to Sat, Sep 26.'), findsOneWidget);
      await tapKey(tester, 'sales-refresh');
      expect(s.t.hub.salesAsks.last, '2026-10-01..2026-10-10');
      // the calendar opens on the days read last; one day picked is one day asked for
      s.picks.add(DateTimeRange(start: DateTime(2026, 11, 7), end: DateTime(2026, 11, 7)));
      await tapKey(tester, 'sales:other');
      expect(s.asked.last, DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      expect(s.t.hub.salesAsks.last, '2026-11-07..2026-11-07');
      expect(find.text('Nov 7'), findsOneWidget);
      expect(find.text('Saturday, November 7, 2026'), findsOneWidget);
    });

    testWidgets('more days than the hub adds up at once: said, and nothing is asked', (tester) async {
      final s = await pumpSales(tester);
      s.picks.add(DateTimeRange(start: DateTime(2026, 8, 1), end: DateTime(2026, 11, 15)));
      await tapKey(tester, 'sales:other');
      expect(find.text('At most 92 days at a time: that was 107. Pick fewer days.'), findsOneWidget);
      expect(s.t.hub.salesAsks, [theWeek]);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('sales:week'))).selected, isTrue);
      expect(find.byKey(const ValueKey('sales-net')), findsOneWidget); // the week read before is still there
      // ninety-two days exactly are asked for, across the night the clocks go back
      s.picks.add(DateTimeRange(start: DateTime(2026, 8, 16), end: DateTime(2026, 11, 15)));
      await tapKey(tester, 'sales:other');
      expect(s.t.hub.salesAsks.last, '2026-08-16..2026-11-15');
    });

    testWidgets('days with nothing on them read as zeroes, and what cannot be said is a dash', (tester) async {
      await pumpSales(tester, sales: {});
      expect(tester.takeException(), isNull);
      expect(row(tester, 'sales-net'), ['Net sales', r'$0.00 before', r'$0.00']);
      expect(row(tester, 'sales-checks'), ['Checks', '0 before', '0']);
      expect(row(tester, 'sales-per-check'), ['Average check', '–']);
      expect(row(tester, 'sales-turn'), ['A table, opened to closed', '0 tables', '–']);
      expect(find.text('No payment was recorded.'), findsOneWidget);
      expect(find.text('No comp and no discount.'), findsOneWidget);
      expect(find.byKey(const ValueKey('sales-by-hour')), findsNothing);
      expect(find.byKey(const ValueKey('sales-categories')), findsNothing);
      expect(find.byKey(const ValueKey('sales-by-day')), findsNothing); // the hub named no day of the span
    });

    testWidgets('while the hub adds up, the screen says so', (tester) async {
      final s = await pumpSales(tester);
      final held = s.t.hub.salesHeld = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('sales:yesterday')));
      await tester.pump();
      expect(find.text('Adding up the days'), findsOneWidget);
      expect(find.text('Many days can take some seconds the first time.'), findsNothing);
      expect(find.byKey(const ValueKey('sales-net')), findsNothing);
      // a longer span is asked for before the first answer came: the screen waits for the one asked last
      await tester.tap(find.byKey(const ValueKey('sales:four-weeks')));
      await tester.pump();
      expect(find.text('Many days can take some seconds the first time.'), findsOneWidget);
      held.complete();
      s.t.hub.salesHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sales-reading')), findsNothing);
      expect(find.text('Mon, Oct 19 to Sun, Nov 15, 2026'), findsOneWidget);
    });

    testWidgets('the manager\'s hour is over, the hub is older, refuses or does not answer: the screen says which', (
      tester,
    ) async {
      await pumpSales(tester, before: (hub) => hub.refuseSales = 401);
      expect(find.text("The manager's hour here is over: go back and open Location again."), findsOneWidget);
      await pumpSales(tester, older: true);
      expect(find.text('This hub is older than the sales report. Update the hub to see it here.'), findsOneWidget);
      final refused = await pumpSales(
        tester,
        before: (hub) => hub
          ..refuseSales = 422
          ..salesRefusal = 'At most 92 days at a time.',
      );
      expect(find.text('At most 92 days at a time.'), findsOneWidget);
      // Try again asks again, and the answer takes the message away
      refused.t.hub.refuseSales = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sales-error')), findsNothing);
      expect(row(tester, 'sales-net').last, r'$13,900.25');
      final down = await pumpSales(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
      down.t.hub.down = false;
    });

    testWidgets('on a small phone every row fits, in the dark too', (tester) async {
      final big = week();
      final span = big['span'] as Map<String, dynamic>;
      span['sales'] = {...span['sales'] as Map<String, dynamic>, 'gross': '1234567.89', 'net': '1234567.89'};
      span['days'] = [
        for (var d = 9; d <= 15; d++) day('2026-11-${d.toString().padLeft(2, '0')}', 900, 2100, '123456.78'),
      ];
      span['categories'] = [
        {
          'menu': 'dinner',
          'code': 'x',
          'name': 'Chef\'s seasonal specialities and platters',
          'count': 12345,
          'amount': '123456.78',
        },
      ];
      for (final dark in [false, true]) {
        final t = await terminal(tester);
        t.hub.sales = {theWeek: big};
        tester.view.physicalSize = const Size(320, 568);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? ThemeData.dark() : null,
            home: SalesScreen(api: t.api, token: 'tok-admin', now: () => at(21)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byKey(const ValueKey('sales-list')), const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}
