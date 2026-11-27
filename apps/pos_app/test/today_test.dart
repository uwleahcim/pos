import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/screens/adjustments_screen.dart';
import 'package:pos_app/screens/check_history_screen.dart';
import 'package:pos_app/screens/day_report_screen.dart';
import 'package:pos_app/screens/dish_finder.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/menu_panel.dart' show EightySixDialog;
import 'package:pos_app/screens/sales_screen.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/screens/today_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/today.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'day_report_test.dart' show evening, ms, openCheck, row, tapKey;
import 'hub.dart';
import 'location_rows.dart';
import 'powers_test.dart' show everything, pumpLocation, pumpMenu, typePin;

/// Today (docs/today.md): the night as it stands on one screen, made for the owner's phone. The hub does
/// every sum; these tests are about the screen saying what the hub said, reading again without being asked,
/// what each power opens on it, and what it says when it can read no more.

/// The whole of Monday 9 November, the day held beside tonight.
Map<String, dynamic> lastMonday({Map<String, dynamic>? clock}) => {
  'first': '2026-11-09',
  'last': '2026-11-09',
  'running': false,
  'checks': 41,
  'guests': 88,
  'sales': {
    'gross': '1250.00',
    'discounts': '40.00',
    'net': '1210.00',
    'charges': '0.00',
    'gratuity': '0.00',
    'tax': '84.70',
    'total': '1294.70',
  },
  'per_check': '29.51',
  'hours': [
    {'hour': 17, 'count': 4, 'amount': '24.40'},
    {'hour': 19, 'count': 2, 'amount': '12.00'},
    {'hour': 20, 'count': 1, 'amount': '4.95'},
    {'hour': 21, 'count': 2, 'amount': '9.00'},
  ],
  'clock': clock,
};

/// Monday 16 November at nine, as the hub answers Today: the evening of the day's report, beside the Monday
/// before. Two checks are open, yesterday's table and tonight's table 5.
Map<String, dynamic> tonight({
  String now = '58.60',
  String before = '41.35',
  Map<String, dynamic>? day,
  Map<String, dynamic>? clock,
  Map<String, dynamic>? clockBefore,
}) => {
  'now_ms': ms(21),
  'day': {...day ?? evening(), 'clock': ?clock},
  'before': lastMonday(clock: clockBefore),
  'per_check': '14.15',
  'hours': [
    {'hour': 17, 'now': '15.95', 'before': '24.40'},
    {'hour': 18, 'now': '6.50', 'before': '0.00'},
    {'hour': 19, 'now': '16.95', 'before': '12.00'},
    {'hour': 20, 'now': '19.20', 'before': '4.95'},
    {'hour': 21, 'now': '0.00', 'before': '9.00'},
  ],
  'open': {'count': 2, 'total': '6.16', 'due': '6.16'},
  'pace': {'now': now, 'before': before, 'before_ms': ms(21, 0, 9)},
};

/// A night with seven tables open, the oldest first.
Map<String, dynamic> busy() => {
  ...tonight(),
  'day': {
    ...evening(),
    'earlier': <Object>[],
    'open': [
      for (var n = 1; n <= 7; n++) openCheck('t$n', table: '$n', server: 'Amy', due: '$n.00', openedMs: ms(18, n * 5)),
    ],
    'unsent': 0,
  },
  'open': {'count': 7, 'total': '28.00', 'due': '28.00'},
};

/// The screen as [holds] opens it (null: a manager), on a phone unless a [size] is named.
Future<Terminal> pumpToday(
  WidgetTester tester, {
  Map<String, dynamic>? today,
  bool older = false,
  Set<String>? holds,
  Size size = const Size(390, 3200),
  double textScale = 1,
  bool dark = false,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.today = older ? null : (today ?? tonight());
  before?.call(t.hub);
  tester.view.physicalSize = size;
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? PosTheme.dark() : PosTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: TodayScreen(api: t.api, token: 'tok-admin', holds: holds, by: 'Mike', device: 't1'),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

String said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data ?? '';

Rect card(WidgetTester tester, String name) => tester.getRect(find.byKey(ValueKey('today-$name')));

void main() {
  group('what the hub said', () {
    test('is read into names', () {
      final report = TodayReport.fromJson(tonight());
      expect(report.nowMs, ms(21));
      expect((report.day.net, report.day.checks, report.day.guests), ('56.60', 4, 8));
      expect((report.before.net, report.before.checks, report.before.first), ('1210.00', 41, DateTime(2026, 11, 9)));
      expect((report.paceNow, report.paceBefore, report.perCheck), ('58.60', '41.35', '14.15'));
      expect((report.openCount, report.openTotal, report.openDue), (2, '6.16', '6.16'));
      expect(report.hours.first, (hour: 17, now: '15.95', before: '24.40'));
      expect(report.hours.length, 5);
      // the checks left from an earlier day come first: they are the ones somebody forgot
      expect([for (final check in report.openChecks) check.orderId], ['y1', 'o3']);
    });

    test('an answer with nothing in it reads as a day with nothing sold', () {
      final report = TodayReport.fromJson(const {});
      expect((report.day.net, report.paceNow, report.paceBefore, report.perCheck), ('0.00', '0.00', '0.00', null));
      expect(report.openCount, 0);
      expect(report.hours, isEmpty);
      expect(report.openChecks, isEmpty);
    });

    test('a dish with no time kept has no hour', () {
      final report = TodayReport.fromJson({
        ...tonight(),
        'hours': [
          {'hour': null, 'now': '4.00', 'before': '0.00'},
          'nonsense',
        ],
      });
      expect(report.hours, [(hour: null, now: '4.00', before: '0.00')]);
    });
  });

  group('the words', () {
    final monday = DateTime(2026, 11, 9);

    test('the day held beside today is named as a person names it', () {
      expect(lastWeekday(monday), 'last Monday');
      expect(lastWeekday(DateTime(2026, 11, 14)), 'last Saturday');
      expect(lastWeekday(DateTime(2026, 11, 15)), 'last Sunday');
    });

    test('ahead, behind, level, and when there is nothing to hold it against', () {
      expect(paceWords('58.60', '41.35', monday), (words: '41.7% ahead of last Monday at this time', up: true));
      expect(paceWords('30.00', '40.00', monday), (words: '25% behind last Monday at this time', up: false));
      expect(paceWords('40.00', '40.00', monday), (words: 'Level with last Monday at this time', up: null));
      expect(paceWords('12.00', '0.00', monday), (
        words: 'Nothing had been rung in by this time last Monday',
        up: null,
      ));
      expect(paceWords('0.00', '0.00', monday), (words: '', up: null));
      expect(paceWords('0.00', '40.00', monday), (words: '100% behind last Monday at this time', up: false));
      expect(paceWords('', 'nonsense', monday), (words: '', up: null));
    });

    test('how long a check has been open', () {
      expect(sinceWords(ms(21), ms(20, 40)), '20 min');
      expect(sinceWords(ms(21), ms(19, 40)), '1 h 20 min');
      expect(sinceWords(ms(21), ms(21)), '0 min');
      expect(sinceWords(ms(21), ms(19, 0, 15)), '26 h');
      expect(sinceWords(ms(21), ms(19, 0, 14)), '2 days');
      expect(sinceWords(ms(21), ms(22)), '0 min'); // a clock that ran ahead says no nonsense
    });

    test('hours worked', () {
      expect(workedWords(45 * 60000), '45 min');
      expect(workedWords(31 * 3600000 + 30 * 60000), '31 h 30 min');
      expect(workedWords(0), '0 min');
    });
  });

  group('the screen', () {
    testWidgets('says what was sold so far and where that stands beside last week', (tester) async {
      final t = await pumpToday(tester);
      expect(find.text('Today'), findsOneWidget);
      expect(said(tester, 'today-asof'), 'As of 9:00 PM. It reads again by itself.');
      expect(said(tester, 'today-net'), r'$56.60');
      expect(said(tester, 'today-counts'), r'4 checks · 8 guests · $14.15 a check');
      expect(said(tester, 'today-pace'), '41.7% ahead of last Monday at this time');
      expect(
        said(tester, 'today-pace-figures'),
        r'Dishes rung in by 9:00 PM, before comps and tax: $58.60 today, $41.35 then.',
      );
      expect(said(tester, 'today-before'), r'The whole of last Monday came to $1,210.00 net sales on 41 checks.');
      expect(find.byIcon(Icons.trending_up), findsOneWidget);
      // one call brought all of it, with the token the PIN gave
      expect((t.hub.todayAsks, t.hub.todayAuth), (1, 'Bearer tok-admin'));
      await stop(tester);
    });

    testWidgets('says behind, level, and nothing rung in before', (tester) async {
      await pumpToday(
        tester,
        today: tonight(now: '30.00', before: '40.00'),
      );
      expect(said(tester, 'today-pace'), '25% behind last Monday at this time');
      expect(find.byIcon(Icons.trending_down), findsOneWidget);

      await pumpToday(
        tester,
        today: tonight(now: '40.00', before: '40.00'),
      );
      expect(said(tester, 'today-pace'), 'Level with last Monday at this time');
      expect(find.byIcon(Icons.trending_up), findsNothing);
      expect(find.byIcon(Icons.trending_down), findsNothing);

      await pumpToday(tester, today: tonight(before: '0.00'));
      expect(said(tester, 'today-pace'), 'Nothing had been rung in by this time last Monday');

      // before the first dish of the day, and with nothing a week ago either, there is nothing to say
      await pumpToday(
        tester,
        today: {
          ...tonight(now: '0.00', before: '0.00'),
          'day': {'day': '2026-11-16', 'today': true, 'now_ms': ms(11)},
          'before': {'first': '2026-11-09', 'last': '2026-11-09'},
          'per_check': null,
          'hours': <Object>[],
          'open': {'count': 0, 'total': '0.00', 'due': '0.00'},
        },
      );
      expect(find.byKey(const ValueKey('today-pace')), findsNothing);
      expect(said(tester, 'today-net'), r'$0.00');
      expect(said(tester, 'today-counts'), '0 checks');
      expect(said(tester, 'today-before'), 'Nothing was sold last Monday.');
      expect(said(tester, 'today-open-due'), 'No check is open.');
      expect(find.byKey(const ValueKey('today-off-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-hours')), findsNothing);
      await stop(tester);
    });

    testWidgets('opens the day in full and the sales by day with the same PIN', (tester) async {
      final t = await pumpToday(tester, before: (hub) => hub.days = {'': evening()});
      await tapKey(tester, 'today-day');
      expect(find.byType(DayReportScreen), findsOneWidget);
      expect(t.hub.dayAuth, 'Bearer tok-admin');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapKey(tester, 'today-sales-full');
      expect(find.byType(SalesScreen), findsOneWidget);
      expect(t.hub.salesAuth, 'Bearer tok-admin');
      await stop(tester);
    });

    testWidgets('lists the open checks, the ones left from an earlier day first', (tester) async {
      final t = await pumpToday(tester);
      expect(row(tester, 'today-open'), containsAllInOrder(['Open checks', '2', r'$6.16 not paid yet']));
      expect(said(tester, 'today-unsent'), '2 dishes were never sent to the kitchen.');
      expect(said(tester, 'today-unpaid'), '1 check was closed without being paid in full: see The day.');
      final top = tester.getTopLeft(find.byKey(const ValueKey('today-check:y1'))).dy;
      expect(top < tester.getTopLeft(find.byKey(const ValueKey('today-check:o3'))).dy, isTrue);
      expect(row(tester, 'today-check:y1'), containsAll(['Table 3', r'$2.68']));
      expect(find.textContaining('from Nov 15 · open 26 h · 1 not sent', findRichText: true), findsOneWidget);
      expect(row(tester, 'today-check:o3'), containsAll(['Table 5', r'$3.48']));
      expect(find.textContaining('Amy · open 20 min · 1 not sent', findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('today-open-all')), findsNothing);

      // a tap reads the check's history, with the same PIN
      expect(find.text('Tap a check to read its history.'), findsOneWidget);
      await tapKey(tester, 'today-check:o3');
      expect(find.byType(CheckHistoryScreen), findsOneWidget);
      expect(t.hub.historyAsks, ['o3']);
      expect(t.hub.historyAuth, 'Bearer tok-admin');
      await stop(tester);
    });

    testWidgets('lists five open checks until asked for all', (tester) async {
      await pumpToday(tester, today: busy());
      expect(row(tester, 'today-open'), containsAllInOrder(['Open checks', '7', r'$28.00 not paid yet']));
      expect(find.byKey(const ValueKey('today-unsent')), findsNothing);
      for (var n = 1; n <= 5; n++) {
        expect(find.byKey(ValueKey('today-check:t$n')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('today-check:t6')), findsNothing);
      expect(find.text('Show all 7'), findsOneWidget);
      await tapKey(tester, 'today-open-all');
      expect(find.byKey(const ValueKey('today-check:t7')), findsOneWidget);
      expect(find.text('Show the oldest 5'), findsOneWidget);
      await tapKey(tester, 'today-open-all');
      expect(find.byKey(const ValueKey('today-check:t6')), findsNothing);
      await stop(tester);
    });

    testWidgets('opens no history for a PIN that may not read it', (tester) async {
      final t = await pumpToday(tester, holds: {'reports'});
      expect(find.text('Tap a check to read its history.'), findsNothing);
      await tapKey(tester, 'today-check:o3');
      expect(find.byType(CheckHistoryScreen), findsNothing);
      expect(t.hub.historyAsks, isEmpty);
      await stop(tester);
    });

    testWidgets('says what came off the checks, with the report behind it', (tester) async {
      final t = await pumpToday(tester);
      expect(row(tester, 'today-voids'), containsAll(['Voids', '1', r'$3.50']));
      expect(row(tester, 'today-discounts'), containsAll(['Comps and discounts', r'$2.00']));
      expect(row(tester, 'today-off'), containsAll(['Checks voided whole', r'$2.95']));
      expect(find.text('Taken off before sending'), findsNothing);
      expect(find.byKey(const ValueKey('today-off-none')), findsNothing);
      await tapKey(tester, 'today-adjustments');
      expect(find.byType(AdjustmentsScreen), findsOneWidget);
      expect(t.hub.requests.where((r) => r.contains('/reports/adjustments')), isNotEmpty);
      await stop(tester);
    });

    testWidgets('says who is on the clock only where a time clock runs', (tester) async {
      await pumpToday(tester);
      expect(find.byKey(const ValueKey('today-clock')), findsNothing);

      await pumpToday(
        tester,
        today: tonight(
          clock: {
            'worked_ms': 6 * 3600000 + 30 * 60000,
            'people': 3,
            'unended': 1,
            'on_now': [
              {'name': 'Amy'},
              {'name': 'Ben'},
            ],
            'net_per_hour': '8.71',
          },
          clockBefore: {'worked_ms': 117 * 3600000, 'people': 9, 'unended': 0, 'net_per_hour': '10.34'},
        ),
      );
      expect(row(tester, 'today-clock'), containsAllInOrder(['On the clock', '2', 'Amy, Ben']));
      expect(row(tester, 'today-worked'), containsAll(['Hours worked today', '6 h 30 min']));
      expect(find.textContaining('3 people', findRichText: true), findsOneWidget);
      expect(row(tester, 'today-per-hour'), containsAll(['Net sales per hour worked', r'$8.71']));
      expect(find.textContaining(r'The whole of last Monday: $10.34', findRichText: true), findsOneWidget);
      expect(find.text('1 shift nobody clocked out of.'), findsOneWidget);

      // before anybody has worked an hour there is no figure per hour, and nobody may be on
      await pumpToday(tester, today: tonight(clock: {'worked_ms': 0, 'people': 0, 'unended': 0, 'on_now': <Object>[]}));
      expect(said(tester, 'today-on-now'), 'Nobody is on the clock.');
      expect(find.byKey(const ValueKey('today-per-hour')), findsNothing);
      await stop(tester);
    });

    testWidgets('lists what is sold out and brings a dish back', (tester) async {
      final t = await pumpToday(
        tester,
        before: (hub) => hub.board = [
          {'target_id': 'DRAGON:roll', 'name': 'Dragon roll', 'status': 'sold_out', 'by': 'Amy'},
          {'target_id': 'EGGROLL:regular', 'name': 'Egg roll', 'status': 'available', 'left': 3, 'total': 12},
        ],
      );
      expect(row(tester, 'today-86').take(2), ['Sold out', '1']);
      expect(row(tester, 'today-86:DRAGON:roll'), ['Dragon roll', 'Sold out · Amy', 'Bring back']);
      expect(row(tester, 'today-86:EGGROLL:regular'), ['Egg roll', '3 of 12 left', 'No number']);

      await tapKey(tester, 'today-86-back:DRAGON:roll');
      expect(t.hub.boardChanges.last, {'target_id': 'DRAGON:roll', 'status': 'available', 'by': 'Mike'});
      expect(find.byKey(const ValueKey('today-86:DRAGON:roll')), findsNothing);
      expect(row(tester, 'today-86').take(2), ['Sold out', '0']);

      await tapKey(tester, 'today-86-back:EGGROLL:regular');
      expect(t.hub.boardChanges.last, {'target_id': 'EGGROLL:regular', 'status': 'available', 'by': 'Mike'});
      expect(find.byKey(const ValueKey('today-86-none')), findsOneWidget);
      await stop(tester);
    });

    testWidgets('86es a dish found by its name or its number', (tester) async {
      final t = await pumpToday(tester);
      expect(find.byKey(const ValueKey('today-86-none')), findsOneWidget);
      await tapKey(tester, 'today-86-add');
      expect(find.byType(DishFinderDialog), findsOneWidget);
      expect(find.text('86 a dish'), findsNWidgets(2)); // the button behind, and the box's title
      expect(find.byType(ListTile), findsNothing); // nothing is offered before something is typed

      await tester.enterText(find.byKey(const ValueKey('dish-finder-typed')), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dish-finder-none')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('dish-finder-typed')), '87');
      await tester.pumpAndSettle();
      expect(find.text("87 · General Tso's Chicken"), findsOneWidget);

      // any word order, as on the order screen
      await tester.enterText(find.byKey(const ValueKey('dish-finder-typed')), 'chicken tso');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dish-found:GTC:pint')));
      await tester.pumpAndSettle();
      expect(find.byType(DishFinderDialog), findsNothing);
      expect(find.byType(EightySixDialog), findsOneWidget);
      expect(find.text("86 General Tso's Chicken"), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('out:GTC:pint')));
      await tester.pumpAndSettle();
      expect(t.hub.boardChanges.last, {'target_id': 'GTC:pint', 'status': 'sold_out', 'by': 'Mike'});
      t.hub.board = [
        {'target_id': 'GTC:pint', 'name': "General Tso's Chicken (Pint)", 'status': 'sold_out', 'by': 'Mike'},
      ];
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // the card reads the board again when the sheet closes
      expect(row(tester, 'today-86:GTC:pint'), ["General Tso's Chicken (Pint)", 'Sold out · Mike', 'Bring back']);
      await stop(tester);
    });

    testWidgets('leaves the board alone when no dish is picked', (tester) async {
      final t = await pumpToday(tester);
      await tapKey(tester, 'today-86-add');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(EightySixDialog), findsNothing);
      expect(t.hub.boardChanges, isEmpty);
      await stop(tester);
    });

    testWidgets('says what the kitchen quotes and sets the rush', (tester) async {
      final t = await pumpToday(tester, before: (hub) => hub.quotes = {...hub.quotes, 'rush': null});
      expect(said(tester, 'today-rush'), 'No rush: new to-go orders get the usual quote.');
      expect(said(tester, 'today-quotes'), 'Quoted now: 15 min at the counter, 20 min by phone.');
      expect(find.text('Kitchen is busy'), findsOneWidget);

      await tapKey(tester, 'today-rush-set');
      await tester.tap(find.byKey(const ValueKey('rush:15')));
      await tester.pumpAndSettle();
      expect(t.hub.rushSet, [15]);
      expect(t.hub.rushAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('today-rush-said')), findsOneWidget);
      expect(
        said(tester, 'today-rush'),
        'The rush is on: every new to-go quote is 15 minutes longer, until closing (Mike).',
      );
      expect(said(tester, 'today-quotes'), 'Quoted now: 30 min at the counter, 35 min by phone.');
      expect(row(tester, 'today-kitchen').take(2), ['Kitchen', '+15 min']);
      expect(find.text('Change the rush'), findsOneWidget);

      // the same minutes again change nothing; Off takes it away
      await tapKey(tester, 'today-rush-set');
      await tester.tap(find.byKey(const ValueKey('rush:15')));
      await tester.pumpAndSettle();
      expect(t.hub.rushSet, [15]);
      await tapKey(tester, 'today-rush-set');
      await tester.tap(find.byKey(const ValueKey('rush:0')));
      await tester.pumpAndSettle();
      expect(t.hub.rushSet, [15, 0]);
      expect(said(tester, 'today-rush'), 'No rush: new to-go orders get the usual quote.');
      await stop(tester);
    });

    testWidgets('offers no rush to a PIN without it, or on a hub that has none', (tester) async {
      await pumpToday(tester, holds: {'reports'}, before: (hub) => hub.quotes = {...hub.quotes, 'rush': null});
      expect(said(tester, 'today-quotes'), 'Quoted now: 15 min at the counter, 20 min by phone.');
      expect(find.byKey(const ValueKey('today-rush-set')), findsNothing);

      await pumpToday(tester, holds: {'reports', 'rush'}, before: (hub) => hub.quotes = {...hub.quotes, 'rush': null});
      expect(find.byKey(const ValueKey('today-rush-set')), findsOneWidget);

      await pumpToday(tester); // a hub from before the rush
      expect(find.byKey(const ValueKey('today-rush-set')), findsNothing);
      await stop(tester);
    });

    testWidgets('lays the night hour by hour beside last week', (tester) async {
      await pumpToday(tester);
      expect(find.text('Hour by hour'), findsOneWidget);
      expect(find.textContaining('The thin bar and the small figure are last Monday.'), findsOneWidget);
      expect(row(tester, 'today-hour:17'), ['5 PM', r'$15.95', r'$24.40']);
      expect(row(tester, 'today-hour:18'), ['6 PM', r'$6.50', r'$0.00']);
      expect(row(tester, 'today-hour:21'), ['9 PM', r'$0.00', r'$9.00']);
      // on a phone the hours close the screen
      expect(card(tester, 'hours').top >= card(tester, 'kitchen').bottom, isTrue);
      await stop(tester);
    });

    testWidgets('reads again when asked and every half minute by itself', (tester) async {
      final t = await pumpToday(tester);
      expect(t.hub.todayAsks, 1);
      t.hub.today = {
        ...tonight(now: '70.00'),
        'day': {
          ...evening(),
          'checks': 5,
          'sales': {...evening()['sales'] as Map<String, dynamic>, 'net': '68.00'},
        },
      };
      await tester.tap(find.byKey(const ValueKey('today-refresh')));
      await tester.pumpAndSettle();
      expect(t.hub.todayAsks, 2);
      expect(said(tester, 'today-net'), r'$68.00');
      expect(said(tester, 'today-pace'), '69.3% ahead of last Monday at this time');

      // nothing is rung, and still it reads: the figure of a week ago moves with the clock
      t.hub.today = tonight(now: '70.00', before: '77.00');
      t.hub.board = [
        {'target_id': 'DRAGON:roll', 'name': 'Dragon roll', 'status': 'sold_out'},
      ];
      await tester.pump(const Duration(seconds: 15));
      expect(t.hub.todayAsks, 2);
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(t.hub.todayAsks, 3);
      expect(said(tester, 'today-pace'), '9.1% behind last Monday at this time');
      expect(find.byKey(const ValueKey('today-86:DRAGON:roll')), findsOneWidget);
      await stop(tester);
      final asks = t.hub.todayAsks;
      await tester.pump(const Duration(minutes: 2));
      expect(t.hub.todayAsks, asks); // a screen that is gone reads no more
    });

    testWidgets('reads again when the hub says a check changed, and not once per change', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()
        ..today = tonight()
        ..quotes['rush'] = null;
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      addTearDown(tester.view.reset);
      tester.view
        ..physicalSize = const Size(390, 3200)
        ..devicePixelRatio = 1;
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: TodayScreen(api: api, token: 'tok-admin', by: 'Mike', device: 't1'),
        ),
      );
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.live.isLive, isTrue);
      final first = hub.todayAsks;

      // a burst of changes right after a read waits for the gap, and is one read
      hub.today = tonight(now: '80.00');
      for (var n = 0; n < 5; n++) {
        live.changed(orders: ['o$n']);
        await tester.pump(const Duration(seconds: 1));
      }
      expect(hub.todayAsks, first);
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      await tester.pump();
      expect(hub.todayAsks, first + 1);
      expect(said(tester, 'today-pace'), '93.5% ahead of last Monday at this time');

      // the board and the rush come by their own topics
      hub.board = [
        {'target_id': 'DRAGON:roll', 'name': 'Dragon roll', 'status': 'sold_out'},
      ];
      live.changed(topics: ['menu']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('today-86:DRAGON:roll')), findsOneWidget);
      hub.quotes = {
        ...hub.quotes,
        'rush': {
          'minutes': 20,
          'until': DateTime.now().add(const Duration(hours: 3)).millisecondsSinceEpoch,
          'by': 'Ben',
        },
      };
      live.changed(topics: ['settings']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        said(tester, 'today-rush'),
        'The rush is on: every new to-go quote is 20 minutes longer, until closing (Ben).',
      );

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('keeps the figures when the hour of the PIN is over, and reads on with another', (tester) async {
      final t = await pumpToday(tester);
      t.hub.refuseToday = 401;
      await tester.tap(find.byKey(const ValueKey('today-refresh')));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-stopped'), 'The hour of this PIN is over.');
      expect(find.text('These are the figures of 9:00 PM.'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-asof')), findsNothing);
      expect(said(tester, 'today-net'), r'$56.60');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('today-refresh'))).onPressed, isNull);
      // and it asks no more until somebody types a PIN
      final asks = t.hub.todayAsks;
      await tester.pump(const Duration(seconds: 65));
      expect(t.hub.todayAsks, asks);

      await tapKey(tester, 'today-pin');
      expect(find.text('Manager PIN'), findsOneWidget);
      t.hub.refuseToday = null;
      t.hub.today = tonight(now: '70.00');
      await typePin(tester, '9999', 'Open Today');
      expect(t.hub.sessionsFor, ['reports']);
      expect(find.byKey(const ValueKey('today-stopped')), findsNothing);
      expect(said(tester, 'today-pace'), '69.3% ahead of last Monday at this time');
      expect(said(tester, 'today-asof'), 'As of 9:00 PM. It reads again by itself.');
      expect(t.hub.todayAsks, asks + 1);
      await stop(tester);
    });

    testWidgets('says so when the reports were taken back from the role', (tester) async {
      final t = await pumpToday(tester, holds: {'reports'});
      t.hub.refuseToday = 403;
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-stopped'), 'This PIN may no longer see the reports.');
      expect(said(tester, 'today-net'), r'$56.60');

      // a PIN that may not see them is turned away at the box, and the screen stays as it was
      await tapKey(tester, 'today-pin');
      await typePin(tester, '1111', 'Open Today');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(t.hub.sessionsFor, ['reports']);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-stopped'), 'This PIN may no longer see the reports.');
      await stop(tester);
    });

    testWidgets('asks for a PIN when the first reading is refused', (tester) async {
      final t = await pumpToday(tester, before: (hub) => hub.refuseToday = 401);
      expect(said(tester, 'today-stopped'), 'The hour of this PIN is over.');
      expect(find.byKey(const ValueKey('today-list')), findsNothing);
      t.hub.refuseToday = null;
      await tapKey(tester, 'today-pin');
      await typePin(tester, '9999', 'Open Today');
      expect(said(tester, 'today-net'), r'$56.60');
      await stop(tester);
    });

    testWidgets('says so on a hub older than Today', (tester) async {
      final t = await pumpToday(tester, older: true);
      expect(said(tester, 'today-older'), 'This hub is older than Today. Update the hub to see it here.');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('today-refresh'))).onPressed, isNull);
      final asks = t.hub.requests.length;
      await tester.pump(const Duration(seconds: 65));
      expect(t.hub.requests.length, asks);
      await stop(tester);
    });

    testWidgets('says so when no hub answers, before the first figures and after', (tester) async {
      final t = await pumpToday(tester, before: (hub) => hub.down = true);
      expect(said(tester, 'today-error'), 'The hub is not answering');
      t.hub.down = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-net'), r'$56.60');

      t.hub.down = true;
      await tester.tap(find.byKey(const ValueKey('today-refresh')));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-asof'), 'The hub is not answering. These are the figures of 9:00 PM.');
      expect(said(tester, 'today-net'), r'$56.60');
      expect(find.byKey(const ValueKey('today-standing')), findsOneWidget);

      t.hub.down = false;
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-asof'), 'As of 9:00 PM. It reads again by itself.');
      expect(find.byKey(const ValueKey('today-standing')), findsNothing);
      await stop(tester);
    });

    testWidgets('keeps what stands in the way in sight however far the list is scrolled', (tester) async {
      final t = await pumpToday(tester, size: const Size(390, 700));
      final list = find.descendant(of: find.byKey(const ValueKey('today-list')), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('today-hour:21')), 300, scrollable: list.first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-asof')), findsNothing); // the line of the hour scrolled away
      double scrolled() => tester.state<ScrollableState>(list.first).position.pixels;
      final where = scrolled();
      expect(where > 300, isTrue);

      t.hub.down = true;
      await tester.tap(find.byKey(const ValueKey('today-refresh')));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-asof'), 'The hub is not answering. These are the figures of 9:00 PM.');
      expect(find.byKey(const ValueKey('today-asof')).hitTestable(), findsOneWidget);
      expect(scrolled(), where); // and the list stays where it was

      t.hub.down = false;
      t.hub.refuseToday = 401;
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(said(tester, 'today-stopped'), 'The hour of this PIN is over.');
      expect(find.byKey(const ValueKey('today-pin')).hitTestable(), findsOneWidget);
      final strip = tester.getRect(find.byKey(const ValueKey('today-standing')));
      expect(strip.top, 56); // right under the bar, above the list
      expect(strip.bottom < 350, isTrue);
      expect(scrolled(), where);
      await stop(tester);
    });

    testWidgets('fits a 320-wide phone with large text', (tester) async {
      final t = await pumpToday(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        today: {
          ...busy(),
          'day': {
            ...(busy()['day'] as Map<String, dynamic>),
            'sales': {...evening()['sales'] as Map<String, dynamic>, 'net': '12345.67'},
            'clock': {
              'worked_ms': 31 * 3600000 + 30 * 60000,
              'people': 12,
              'unended': 0,
              'on_now': [
                for (final name in ['Amy', 'Ben', 'Holly', 'Mike', 'Christopher', 'Alexandria']) {'name': name},
              ],
              'net_per_hour': '391.92',
            },
          },
          'before': lastMonday(clock: {'worked_ms': 1, 'people': 9, 'unended': 0, 'net_per_hour': '310.34'}),
        },
        before: (hub) {
          hub.quotes = {...hub.quotes, 'rush': null};
          hub.board = [
            {
              'target_id': 'PUPU:regular',
              'name': 'Pu Pu Platter for two with extra spare ribs',
              'status': 'sold_out',
              'by': 'Christopher',
            },
          ];
        },
      );
      final list = find.descendant(of: find.byKey(const ValueKey('today-list')), matching: find.byType(Scrollable));
      for (final key in ['today-86-back:PUPU:regular', 'today-86-add', 'today-rush-set', 'today-hour:21']) {
        await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200, scrollable: list.first);
        await tester.pumpAndSettle();
        final box = tester.getRect(find.byKey(ValueKey(key)));
        expect(box.left >= 0 && box.right <= 320, isTrue, reason: key);
        if (key == 'today-86-add') {
          // the finder fits as well, with the dishes it offers
          await tester.tap(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const ValueKey('dish-finder-typed')), 'roll');
          await tester.pumpAndSettle();
          expect(find.byType(ListTile), findsWidgets);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
      }
      // and so does the strip that says the PIN's hour is over, with its button whole
      t.hub.refuseToday = 401;
      await tester.tap(find.byKey(const ValueKey('today-refresh')));
      await tester.pumpAndSettle();
      final pin = tester.getRect(find.byKey(const ValueKey('today-pin')));
      expect(pin.left >= 0 && pin.right <= 320, isTrue);
      await stop(tester);
    });

    testWidgets('stands in two columns on a tablet, and in one on a phone', (tester) async {
      await pumpToday(tester, size: const Size(1100, 1600));
      expect(card(tester, 'open').left > card(tester, 'sales').right, isTrue);
      expect((card(tester, 'open').top - card(tester, 'sales').top).abs() < 1, isTrue);
      expect(card(tester, 'hours').left, card(tester, 'sales').left);
      expect(card(tester, 'hours').top >= card(tester, 'sales').bottom, isTrue);

      await pumpToday(tester);
      expect(card(tester, 'open').left, card(tester, 'sales').left);
      expect(card(tester, 'open').top >= card(tester, 'sales').bottom, isTrue);
      await stop(tester);
    });

    testWidgets('reads in the dark as well', (tester) async {
      await pumpToday(tester, dark: true);
      expect(said(tester, 'today-pace'), '41.7% ahead of last Monday at this time');
      await stop(tester);
    });
  });

  group('the way in', () {
    testWidgets('is in the menu of whoever may see the reports, behind their PIN', (tester) async {
      final t = await pumpMenu(tester, 'manager', hub: (hub) => hub.today = tonight());
      await openHome(tester, 'today');
      await tester.pumpAndSettle();
      expect(find.text('Manager PIN'), findsOneWidget);
      await typePin(tester, '9999', 'Open Today');
      expect(t.hub.sessionsFor, ['reports']);
      final screen = tester.widget<TodayScreen>(find.byType(TodayScreen));
      expect((screen.token, screen.by, screen.device), ('tok-admin', 'Mike', 't1'));
      expect(screen.holds, containsAll(['reports', 'rush', 'history']));
      expect(said(tester, 'today-net'), r'$56.60');
      expect(t.hub.todayAuth, 'Bearer tok-admin');
      await stop(tester);
    });

    testWidgets('is not there for a role without the reports, and is for one handed them', (tester) async {
      await pumpMenu(tester, 'host');
      expect(homeIds(tester), isNot(contains('today')));
      await stop(tester);
      await pumpMenu(tester, 'server', hub: (hub) => hub.powers = null); // a hub from before the table
      expect(homeIds(tester), isNot(contains('today')));
      await stop(tester);

      final t = await pumpMenu(
        tester,
        'host',
        hub: (hub) => hub
          ..powers!['reports'] = ['host']
          ..today = tonight(),
      );
      await openHome(tester, 'today');
      await tester.pumpAndSettle();
      // a server's PIN opens nothing; the host's own does, with what a host may do and no more
      await typePin(tester, '1111', 'Open Today');
      expect(find.byType(TodayScreen), findsNothing);
      await typePin(tester, '3333', 'Open Today');
      expect(t.hub.sessionsFor, ['reports', 'reports']);
      final screen = tester.widget<TodayScreen>(find.byType(TodayScreen));
      expect(screen.token, 'tok-s4');
      expect(screen.holds, containsAll(['reports', 'assign_tables']));
      expect(screen.holds!.contains('rush') || screen.holds!.contains('history'), isFalse);
      expect(find.byKey(const ValueKey('today-rush-set')), findsNothing);
      expect(find.text('Tap a check to read its history.'), findsNothing);
      await stop(tester);
    });

    testWidgets('is a row in Location for the same people, with no second PIN', (tester) async {
      final t = await pumpLocation(tester, holds: everything, hub: (hub) => hub.today = tonight());
      await bringUp(tester, 'today');
      expect(find.text('The night as it stands, beside the same day last week'), findsOneWidget);
      await tapKey(tester, 'today');
      final screen = tester.widget<TodayScreen>(find.byType(TodayScreen));
      expect((screen.token, screen.device), ('tok-admin', 't1'));
      expect(screen.holds, everything);
      expect(t.hub.pins, isEmpty);
      await stop(tester);

      await pumpLocation(tester, holds: {'guests', 'waste'});
      expect(find.byKey(const ValueKey('today')), findsNothing);
      expect(find.byType(LocationSettingsScreen), findsOneWidget);
      await stop(tester);
    });
  });
}
