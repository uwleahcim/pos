import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/day_report.dart';
import 'package:pos_app/screens/adjustments_screen.dart';
import 'package:pos_app/screens/day_report_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/time_clock_screen.dart';

import 'hub.dart';

/// The day's report (docs/day-report.md): what a manager reads when service is over. The hub does every
/// sum; these tests are about the screen saying what the hub said, asking for the right day, and printing.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

Map<String, dynamic> openCheck(
  String id, {
  String? table,
  int? orderNo,
  String name = '',
  String server = '',
  String due = '0.00',
  int unsent = 0,
  String status = 'open',
  String type = 'dine_in',
  int? openedMs,
  String? day,
}) => {
  'order_id': id,
  'table': table,
  'order_no': orderNo,
  'customer_name': name,
  'server': server,
  'order_type': type,
  'status': status,
  'total': due,
  'paid': '0.00',
  'due': due,
  'unsent': unsent,
  'opened_ms': openedMs,
  'day': ?day,
};

/// The evening the hub's own tests ring (backend/tests/orders/test_day.py), read at nine: four checks, one
/// still open with a dish nobody sent, one closed and not paid, yesterday's table still open.
Map<String, dynamic> evening() => {
  'day': '2026-11-16',
  'since_ms': ms(4),
  'until_ms': ms(4, 0, 17),
  'now_ms': ms(21),
  'today': true,
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
  'menus': [
    {'menu': 'dinner', 'name': 'Dinner', 'count': 7, 'amount': '58.60'},
  ],
  'categories': [
    {'menu': 'dinner', 'code': 'sides', 'name': 'Appetizers', 'count': 5, 'amount': '36.15'},
    {'menu': 'dinner', 'code': 'rolls', 'name': 'Rolls', 'count': 1, 'amount': '15.95'},
    {'menu': 'dinner', 'code': 'beer', 'name': 'Beer', 'count': 1, 'amount': '6.50'},
  ],
  'kinds': [
    {'kind': 'dine_in', 'guests': 8, 'count': 3, 'amount': '41.65'},
    {'kind': 'takeout', 'guests': 0, 'count': 1, 'amount': '16.95'},
  ],
  'staff': [
    {'name': 'Amy', 'staff_id': 's1', 'count': 6, 'amount': '52.10'},
    {'name': 'Ben', 'staff_id': 's2', 'count': 1, 'amount': '6.50'},
  ],
  'hours': [
    {'hour': 17, 'count': 3, 'amount': '15.95'},
    {'hour': 18, 'count': 1, 'amount': '6.50'},
    {'hour': 19, 'count': 1, 'amount': '16.95'},
    {'hour': 20, 'count': 2, 'amount': '19.20'},
  ],
  'discounts': [
    {'name': 'Loyalty reward', 'count': 1, 'amount': '2.00'},
  ],
  'voids': {'count': 1, 'amount': '3.50'},
  'taken_off': {'count': 0, 'amount': '0.00'},
  'typed': {'count': 0, 'amount': '0.00'},
  'voided_checks': {'count': 1, 'amount': '2.95'},
  'later': {'count': 1, 'amount': '36.27'},
  'money': {
    'taken': [
      {'method': 'cash', 'count': 2, 'amount': '25.00'},
      {'method': 'card', 'count': 2, 'amount': '8.84'},
      {'method': 'elsewhere', 'count': 1, 'amount': '18.14'},
    ],
    'taken_total': '51.98',
    'for_other_days': '11.96',
    'on_voided': '0.00',
    'paid_this_day': '40.02',
    'paid_other_days': '0.00',
    'due': '20.54',
    'over': '0.00',
  },
  'open': [openCheck('o3', table: '5', server: 'Amy', due: '3.48', unsent: 1, openedMs: ms(20, 40))],
  'unpaid': [openCheck('o4', table: '7', due: '17.06', status: 'closed', openedMs: ms(20))],
  'earlier': [openCheck('y1', table: '3', due: '2.68', unsent: 1, openedMs: ms(19, 0, 15), day: '2026-11-15')],
  'unsent': 2,
  'clock': null,
};

/// The same evening once everything is closed and paid.
Map<String, dynamic> closedUp() => {
  ...evening(),
  'open': <Object>[],
  'unpaid': <Object>[],
  'earlier': <Object>[],
  'unsent': 0,
  'money': {...evening()['money'] as Map<String, dynamic>, 'due': '0.00'},
};

class Day {
  Day(this.t);
  final Terminal t;
  final picks = <DateTime>[];
  final asked = <DateTime>[];

  Future<DateTime?> pickDay(BuildContext context, DateTime from) async {
    asked.add(from);
    return picks.isEmpty ? null : picks.removeAt(0);
  }
}

Future<Day> pumpDay(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? days,
  bool older = false,
  Size size = const Size(1100, 2400),
  DateTime? now,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.days = older ? null : (days ?? {'': evening()});
  before?.call(t.hub);
  tester.view.physicalSize = size;
  final day = Day(t);
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      home: DayReportScreen(
        api: t.api,
        token: 'tok-admin',
        device: 't1',
        now: () => now ?? at(21),
        pickDay: day.pickDay,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return day;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Every text inside the row with that key, in order.
List<String> row(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    text.data ?? '',
];

void main() {
  group('what the report reads', () {
    test('an amount of the hub\'s is written for a person', () {
      expect(dollars('58.60'), r'$58.60');
      expect(dollars('12345.5'), r'$12,345.50');
      expect(dollars('1000'), r'$1,000.00');
      expect(dollars('1234567.89'), r'$1,234,567.89');
      expect(dollars('-2.00'), r'-$2.00');
      expect(dollars('0'), r'$0.00');
      expect((isMoney('0.00'), isMoney(''), isMoney('0.01'), isMoney('-3')), (false, false, true, true));
    });

    test('a day of service starts at 4 AM, so the small hours are still the evening before', () {
      expect(serviceDay(at(21)), '2026-11-16');
      expect(serviceDay(at(1, 30, 17)), '2026-11-16');
      expect(serviceDay(at(3, 59, 17)), '2026-11-16');
      expect(serviceDay(at(4, 0, 17)), '2026-11-17');
      expect(serviceDay(DateTime(2027, 1, 1, 2)), '2026-12-31');
    });

    test('the hours, the kinds of order and the ways to pay are said in words', () {
      expect(
        [hourLabel(0), hourLabel(11), hourLabel(12), hourLabel(17), hourLabel(null)],
        ['12 AM', '11 AM', '12 PM', '5 PM', 'No time kept'],
      );
      expect(
        [kindLabel('dine_in'), kindLabel('takeout'), kindLabel('delivery'), kindLabel('drive')],
        ['Tables', 'To go', 'Delivery', 'drive'],
      );
      expect(
        [methodLabel('cash'), methodLabel('card'), methodLabel('elsewhere'), methodLabel('gift')],
        ['Cash', 'Card', 'Paid elsewhere', 'gift'],
      );
    });

    test('the hub\'s answer is read as it is written', () {
      final report = DayReport.fromJson(evening());
      expect((report.day, report.today, report.checks, report.guests), (DateTime(2026, 11, 16), true, 4, 8));
      expect(
        (report.gross, report.discountTotal, report.net, report.tax, report.total),
        ('58.60', '2.00', '56.60', '3.96', '60.56'),
      );
      expect(
        [for (final c in report.categoriesOf('dinner')) (c.name, c.count, c.amount)],
        [('Appetizers', 5, '36.15'), ('Rolls', 1, '15.95'), ('Beer', 1, '6.50')],
      );
      expect([for (final k in report.kinds) (k.name, k.count, k.guests)], [('dine_in', 3, 8), ('takeout', 1, 0)]);
      expect([for (final h in report.hours) h.hour], [17, 18, 19, 20]);
      expect(
        [for (final t in report.taken) (t.name, t.count, t.amount)],
        [('cash', 2, '25.00'), ('card', 2, '8.84'), ('elsewhere', 1, '18.14')],
      );
      expect(
        (report.takenTotal, report.forOtherDays, report.paidThisDay, report.due),
        ('51.98', '11.96', '40.02', '20.54'),
      );
      expect(
        (report.voids.count, report.voids.amount, report.voidedChecks.count, report.later.count),
        (1, '3.50', 1, 1),
      );
      expect([for (final c in report.open) (c.where, c.due, c.unsent)], [('Table 5', '3.48', 1)]);
      expect(
        (report.earlier.single.day, report.unsent, report.clock, report.allClosed),
        ('2026-11-15', 2, null, false),
      );
      expect(DayReport.fromJson(closedUp()).allClosed, isTrue);
    });

    test('a hub that says little reads as zeroes, and a check names itself', () {
      final report = DayReport.fromJson({'day': '2026-11-16', 'today': true});
      expect(
        (report.gross, report.total, report.takenTotal, report.due, report.allClosed),
        ('0.00', '0.00', '0.00', '0.00', true),
      );
      expect(DayCheck.fromJson(openCheck('a', orderNo: 7, name: 'Lee', type: 'takeout')).where, '#7 · Lee');
      expect(DayCheck.fromJson(openCheck('b', type: 'takeout')).where, 'To go');
      // somebody still on the clock is something to look at before going home
      final clocked = DayReport.fromJson({
        ...closedUp(),
        'clock': {
          'worked_ms': 0,
          'people': 1,
          'unended': 0,
          'on_now': [
            {'name': 'Amy'},
          ],
        },
      });
      expect(clocked.clock!.onNow, ['Amy']);
      expect(clocked.allClosed, isFalse);
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token and the day, and for a print the printer', (tester) async {
      final t = await terminal(tester);
      await t.api.dayReport('tok-admin');
      await t.api.dayReport('tok-admin', day: '2026-11-15');
      expect(t.hub.dayAsks, ['', '2026-11-15']);
      expect(t.hub.dayAuth, 'Bearer tok-admin');
      expect(await t.api.printDay('tok-admin'), 'Takeout');
      expect(await t.api.printDay('tok-admin', day: '2026-11-15', printer: 'bar'), 'Takeout');
      expect(t.hub.dayPrints, [
        <String, dynamic>{},
        {'day': '2026-11-15', 'printer': 'bar'},
      ]);
    });
  });

  group('the screen', () {
    testWidgets('Location settings opens The day with the manager\'s token', (tester) async {
      final t = await terminal(tester);
      t.hub.days = {'': evening()};
      tester.view.physicalSize = const Size(1100, 2600);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'day-report');
      expect(find.byType(DayReportScreen), findsOneWidget);
      expect(t.hub.dayAsks, ['']);
      expect(t.hub.dayAuth, 'Bearer tok-admin');
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
    });

    testWidgets('the running day: what is still open comes first', (tester) async {
      final d = await pumpDay(tester);
      expect(d.t.hub.dayAsks, ['']); // no day named: the hub knows which one is running
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      expect(find.textContaining('The day is still running: read at 9:00 PM'), findsOneWidget);
      expect(row(tester, 'day-open'), ['Still open', r'$20.54']);
      expect(find.text('1 check still open'), findsOneWidget);
      expect(row(tester, 'day-check:o3'), ['Table 5', 'Amy · opened 8:40 PM · 1 dish not sent', r'$3.48']);
      expect(find.text('Closed, but not paid in full'), findsOneWidget);
      expect(row(tester, 'day-check:o4'), ['Table 7', 'opened 8:00 PM', r'$17.06']);
      expect(find.text('Open from earlier days'), findsOneWidget);
      expect(row(tester, 'day-check:y1'), ['Table 3', 'Nov 15 · opened 7:00 PM · 1 dish not sent', r'$2.68']);
      expect(find.text('2 dishes were never sent to the kitchen.'), findsOneWidget);
      expect(find.byKey(const ValueKey('day-all-closed')), findsNothing);
    });

    testWidgets('the sales, and what the day\'s checks come to', (tester) async {
      await pumpDay(tester);
      expect(row(tester, 'day-sales'), ['Sales', r'$60.56']);
      expect(row(tester, 'day-gross'), ['Dishes sold', r'$58.60']);
      expect(row(tester, 'day-discounts'), ['Comps and discounts', r'-$2.00']);
      expect(row(tester, 'day-net'), ['Net sales', r'$56.60']);
      expect(row(tester, 'day-tax'), ['Sales tax', r'$3.96']); // one line, as a guest sees it
      expect(row(tester, 'day-total'), ['Total', r'$60.56']);
      expect(find.text('4 checks · 8 guests'), findsOneWidget);
      expect(find.text('Charges'), findsNothing); // nothing was charged, so no row of zeroes
      expect(find.text('Gratuity'), findsNothing);
    });

    testWidgets('the money taken, by how it was paid, and what is still owed', (tester) async {
      await pumpDay(tester);
      expect(row(tester, 'day-taken'), ['Money taken', r'$51.98']);
      expect(row(tester, 'day-taken:cash'), ['Cash', '2 payments', r'$25.00']);
      expect(row(tester, 'day-taken:card'), ['Card', '2 payments', r'$8.84']);
      expect(row(tester, 'day-taken:elsewhere'), ['Paid elsewhere', '1 payment', r'$18.14']);
      expect(row(tester, 'day-other-days'), ['Of it, for checks of other days', r'$11.96']);
      expect(row(tester, 'day-paid'), ['Paid this day', r'$40.02']);
      expect(row(tester, 'day-due'), ['Still owed', r'$20.54']);
      expect(find.byKey(const ValueKey('day-on-voided')), findsNothing);
      expect(find.byKey(const ValueKey('day-over')), findsNothing);
      expect(find.byKey(const ValueKey('day-paid-other')), findsNothing);
      expect(find.textContaining('The cash in the drawer is not counted here yet'), findsOneWidget);
    });

    testWidgets('money on a voided check, money paid over and money from other days are said', (tester) async {
      final report = evening();
      report['money'] = {
        ...report['money'] as Map<String, dynamic>,
        'on_voided': '3.00',
        'over': '10.00',
        'paid_other_days': '5.00',
      };
      await pumpDay(tester, days: {'': report});
      expect(row(tester, 'day-on-voided').first, 'Of it, on checks voided since');
      expect(row(tester, 'day-on-voided').last, r'$3.00');
      expect(row(tester, 'day-over'), ['Paid over', 'More was paid than the check comes to', r'$10.00']);
      expect(row(tester, 'day-paid-other'), ['Paid on other days', r'$5.00']);
    });

    testWidgets('the sales by category, by kind of order, by who rang them in and by hour', (tester) async {
      await pumpDay(tester);
      expect(row(tester, 'day-categories'), ['By category', r'$58.60']);
      expect(row(tester, 'day-category:dinner:Appetizers'), ['Appetizers', '5×', r'$36.15']);
      expect(row(tester, 'day-category:dinner:Beer'), ['Beer', '1×', r'$6.50']);
      expect(find.text('Dinner'), findsNothing); // one menu: no heading for it
      expect(row(tester, 'day-kind:dine_in'), ['Tables', '3 checks · 8 guests', r'$41.65']);
      expect(row(tester, 'day-kind:takeout'), ['To go', '1 check', r'$16.95']);
      expect(row(tester, 'day-staff:0'), ['Amy', '6×', r'$52.10']);
      expect(row(tester, 'day-staff:1'), ['Ben', '1×', r'$6.50']);
      expect(row(tester, 'day-hour:17'), ['5 PM', r'$15.95']);
      expect(row(tester, 'day-hour:20'), ['8 PM', r'$19.20']);
    });

    testWidgets('two menus: each heads its own categories with what it came to', (tester) async {
      final report = evening();
      report['menus'] = [
        {'menu': 'food', 'name': 'Food', 'count': 6, 'amount': '52.10'},
        {'menu': 'drinks', 'name': 'Drinks', 'count': 1, 'amount': '6.50'},
      ];
      report['categories'] = [
        {'menu': 'food', 'code': 'sides', 'name': 'Appetizers', 'count': 5, 'amount': '36.15'},
        {'menu': 'food', 'code': 'rolls', 'name': 'Rolls', 'count': 1, 'amount': '15.95'},
        {'menu': 'drinks', 'code': 'beer', 'name': 'Beer', 'count': 1, 'amount': '6.50'},
      ];
      await pumpDay(tester, days: {'': report});
      expect(find.text('Food'), findsOneWidget);
      expect(find.text(r'$52.10'), findsWidgets);
      expect(find.text('Drinks'), findsOneWidget);
      expect(row(tester, 'day-category:drinks:Beer'), ['Beer', '1×', r'$6.50']);
    });

    testWidgets('what came off the checks, with the way to each one', (tester) async {
      await pumpDay(tester);
      expect(row(tester, 'day-discount:Loyalty reward'), ['Loyalty reward', '1×', r'-$2.00']);
      expect(row(tester, 'day-voids'), ['Voided after sending', '1×', r'$3.50']);
      expect(row(tester, 'day-voided-checks'), ['Checks voided whole', '1×', r'$2.95']);
      expect(find.byKey(const ValueKey('day-taken-off')), findsNothing);
      expect(row(tester, 'day-later').first, 'Rung for another day');
      expect(find.byKey(const ValueKey('day-typed')), findsNothing);
      await tapKey(tester, 'day-adjustments');
      expect(find.byType(AdjustmentsScreen), findsOneWidget);
    });

    testWidgets('everything closed and paid: the screen says so', (tester) async {
      await pumpDay(tester, days: {'': closedUp()});
      expect(find.byKey(const ValueKey('day-all-closed')), findsOneWidget);
      expect(find.text('Nothing: every check is closed and paid.'), findsOneWidget);
      expect(row(tester, 'day-open'), ['Still open', '']);
      expect(row(tester, 'day-due'), ['Still owed', r'$0.00']);
    });

    testWidgets('a day with nothing on it reads as zeroes', (tester) async {
      await pumpDay(tester, days: {});
      expect(find.text('Nothing is open.'), findsOneWidget);
      expect(row(tester, 'day-sales'), ['Sales', r'$0.00']);
      expect(find.text('0 checks · 0 guests'), findsOneWidget);
      expect(find.text('No payment was recorded.'), findsOneWidget);
      expect(find.text('No comp, no discount and no void.'), findsOneWidget);
      expect(find.byKey(const ValueKey('day-categories')), findsNothing);
    });

    testWidgets('Yesterday asks for the day before by name, in the small hours too', (tester) async {
      final yesterday = {...closedUp(), 'day': '2026-11-15', 'today': false};
      final d = await pumpDay(tester, days: {'': evening(), '2026-11-15': yesterday});
      await tapKey(tester, 'day:yesterday');
      expect(d.t.hub.dayAsks, ['', '2026-11-15']);
      expect(find.text('Sunday, November 15, 2026'), findsOneWidget);
      expect(find.text('From 4 AM that morning to 4 AM the next.'), findsOneWidget);
      expect(row(tester, 'day-open').first, 'Still open from this day');
      await tapKey(tester, 'day:today');
      expect(d.t.hub.dayAsks.last, '');

      // at half past one in the morning the running day is still the 16th, and yesterday the 15th
      final late = await pumpDay(tester, days: {}, now: at(1, 30, 17));
      await tapKey(tester, 'day:yesterday');
      expect(late.t.hub.dayAsks, ['', '2026-11-15']);
    });

    testWidgets('Another day asks the calendar, and the chip then names the day', (tester) async {
      final d = await pumpDay(tester);
      await tapKey(tester, 'day:other'); // the calendar closed without a day: nothing changes
      expect(d.asked.single, at(21));
      expect(d.t.hub.dayAsks, ['']);
      d.picks.add(DateTime(2026, 11, 7));
      await tapKey(tester, 'day:other');
      expect(d.t.hub.dayAsks, ['', '2026-11-07']);
      expect(find.text('Nov 7'), findsOneWidget);
      expect(find.text('Saturday, November 7, 2026'), findsOneWidget);
      await tapKey(tester, 'day-refresh');
      expect(d.t.hub.dayAsks, ['', '2026-11-07', '2026-11-07']);
    });

    testWidgets('Print sends the day shown to the printer, and says where it went', (tester) async {
      final d = await pumpDay(tester);
      await tapKey(tester, 'day-print');
      expect(d.t.hub.dayPrints, [<String, dynamic>{}]);
      expect(find.text('The day is printing at Takeout'), findsOneWidget);
      // another day by its name, at the printer this screen keeps for its bills
      d.t.settings.billPrinter = 'bar';
      d.picks.add(DateTime(2026, 11, 7));
      await tapKey(tester, 'day:other');
      await tapKey(tester, 'day-print');
      expect(d.t.hub.dayPrints.last, {'day': '2026-11-07', 'printer': 'bar'});
    });

    testWidgets('no printer: the hub\'s words, and nothing else changes', (tester) async {
      final d = await pumpDay(tester, before: (hub) => hub.dayPrinter = null);
      await tapKey(tester, 'day-print');
      expect(find.text('No printer is set up for this location.'), findsOneWidget);
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      expect(d.t.hub.dayPrints.length, 1);
    });

    testWidgets('the manager\'s hour is over, the hub is older, or nothing answers: the screen says which', (
      tester,
    ) async {
      final over = await pumpDay(tester, before: (hub) => hub.refuseDay = 401);
      expect(find.text("The manager's hour here is over: go back and open Location again."), findsOneWidget);
      over.t.hub.refuseDay = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);

      await pumpDay(tester, older: true);
      expect(find.text("This hub is older than the day's report. Update the hub to see it here."), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('day-print'))).onPressed, isNull);

      await pumpDay(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
    });

    testWidgets('where the time clock is used: who is still on it, and the hours', (tester) async {
      final report = closedUp();
      report['clock'] = {
        'worked_ms': (38 * 60 + 15) * 60000,
        'people': 6,
        'unended': 1,
        'on_now': [
          {'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'state': 'in', 'in_ms': ms(16)},
          {'staff_id': 's2', 'name': 'Ben', 'role': 'bartender', 'state': 'break', 'in_ms': ms(17)},
        ],
      };
      final d = await pumpDay(tester, days: {'': report}, before: (hub) => hub.timeClock = {'enabled': true});
      expect(find.byKey(const ValueKey('day-all-closed')), findsNothing);
      expect(find.text('Still on the clock: Amy, Ben'), findsOneWidget);
      expect(find.text('1 shift nobody clocked out of: correct it under Hours.'), findsOneWidget);
      expect(row(tester, 'day-hours'), ['Hours worked', '6 people · open the hours', '38 h 15 min']);
      await tapKey(tester, 'day-hours');
      expect(find.byType(TimeClockScreen), findsOneWidget);
      expect(d.t.hub.clockAuth, 'Bearer tok-admin');
    });

    testWidgets('typed prices are pointed at when there were any', (tester) async {
      final report = evening();
      report['typed'] = {'count': 2, 'amount': '56.00'};
      await pumpDay(tester, days: {'': report});
      expect(row(tester, 'day-typed'), [
        'Typed prices',
        'Off-menu dishes and market prices, in the sales above',
        '2×',
        r'$56.00',
      ]);
    });

    testWidgets('on a small phone every row fits', (tester) async {
      final report = evening();
      report['sales'] = {...report['sales'] as Map<String, dynamic>, 'gross': '123456.78', 'total': '132098.75'};
      report['open'] = [
        openCheck(
          'o9',
          orderNo: 112,
          name: 'Bartholomew Featherstonehaugh',
          server: 'Alexandria',
          due: '1234.56',
          unsent: 12,
          type: 'takeout',
          openedMs: ms(20, 40),
        ),
      ];
      await pumpDay(tester, days: {'': report}, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      await tester.drag(find.byKey(const ValueKey('day-list')), const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byKey(const ValueKey('day-list')), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
