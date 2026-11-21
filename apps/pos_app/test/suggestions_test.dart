import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/suggestions_screen.dart';
import 'package:pos_app/suggestions_report.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Suggestions taken (docs/goes-with.md, "Suggestions taken"): what a manager reads to see how often the
/// dishes a dish suggests were added, and by whom. The hub does every sum and every order; these tests are
/// about the screen saying what the hub said, and asking for the right days.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

Map<String, dynamic> added(String item, String name, int taken, String amount) => {
  'item': item,
  'name': name,
  'taken': taken,
  'amount': amount,
};

Map<String, dynamic> dish(
  String item,
  String name,
  int sold,
  int taken,
  String amount,
  List<Map<String, dynamic>> with_,
) => {'item': item, 'name': name, 'sold': sold, 'taken': taken, 'amount': amount, 'added': with_};

Map<String, dynamic> person(String? id, String name, int taken, String amount) => {
  'staff_id': id,
  'name': name,
  'taken': taken,
  'amount': amount,
};

/// The week of Monday 9 November, as the hub orders it: the dish that brought the most first, the ones
/// that went out with nothing added last.
Map<String, dynamic> week() => {
  'from': '2026-11-09',
  'to': '2026-11-15',
  'days': 7,
  'running': false,
  'taken': 42,
  'amount': '279.90',
  'dishes': [
    dish('PUPU', 'Pu Pu Platter', 31, 27, '225.00', [
      added('TSINGTAO', 'Tsingtao', 18, '117.00'),
      added('MAITAI', 'Mai Tai', 9, '108.00'),
      added('SODA', 'Soda', 0, '0.00'), // suggested today, and nobody took it
    ]),
    dish('WINGS', 'Chicken wings', 40, 15, '54.90', [
      added('SODA', 'Soda', 12, '35.40'),
      added('TSINGTAO', 'Tsingtao', 3, '19.50'),
    ]),
    dish('DUCK', 'Peking Duck', 1204, 0, '0.00', [
      added('TSINGTAO', 'Tsingtao', 0, '0.00'),
      added('TEA', 'Hot tea', 0, '0.00'),
    ]),
    dish('DRAGON', 'Dragon roll', 1, 0, '0.00', [added('TEA', 'Hot tea', 0, '0.00')]),
  ],
  'staff': [
    person('s1', 'Amy', 25, '170.40'),
    person('s2', 'Ben', 15, '98.50'),
    person(null, '', 2, '11.00'), // rung at a screen that named nobody
  ],
  'max_days': 92,
  'now_ms': ms(21),
};

/// The evening that is running: one beer with a platter.
Map<String, dynamic> today() => {
  'from': '2026-11-16',
  'to': '2026-11-16',
  'days': 1,
  'running': true,
  'taken': 1,
  'amount': '6.50',
  'dishes': [
    dish('PUPU', 'Pu Pu Platter', 2, 1, '6.50', [added('TSINGTAO', 'Tsingtao', 1, '6.50')]),
  ],
  'staff': [person('s1', 'Amy', 1, '6.50')],
  'max_days': 92,
  'now_ms': ms(21),
};

class Suggestions {
  Suggestions(this.t);
  final Terminal t;
  final picks = <DateTimeRange>[];
  final asked = <DateTimeRange?>[];

  Future<DateTimeRange?> pickSpan(BuildContext context, DateTimeRange? from) async {
    asked.add(from);
    return picks.isEmpty ? null : picks.removeAt(0);
  }
}

const theWeek = '2026-11-09..2026-11-15';

Future<Suggestions> pumpSuggestions(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? suggestions,
  bool older = false,
  Size size = const Size(1100, 2400),
  DateTime? now,
  ThemeData? theme,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.suggestions = older ? null : (suggestions ?? {theWeek: week(), '': today()});
  before?.call(t.hub);
  tester.view.physicalSize = size;
  final s = Suggestions(t);
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: SuggestionsScreen(api: t.api, token: 'tok-admin', now: () => now ?? at(21), pickSpan: s.pickSpan),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Every text inside the row with that key, in order.
List<String> row(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
];

/// The rows whose key begins with [prefix], top to bottom, by what follows it.
List<String> keyed(WidgetTester tester, String prefix) {
  final found = [
    for (final element in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate())
      if ((element.widget.key! as ValueKey<String>).value.startsWith(prefix))
        (
          tester.getTopLeft(find.byKey(element.widget.key!)).dy,
          (element.widget.key! as ValueKey<String>).value.substring(prefix.length),
        ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, id) in found) id];
}

void main() {
  group('what the report reads', () {
    test('the hub\'s answer, read into names', () {
      final report = SuggestionsReport.fromJson(week());
      expect((report.first, report.last, report.running), (DateTime(2026, 11, 9), DateTime(2026, 11, 15), false));
      expect((report.taken, report.amount, report.maxDays, report.nowMs), (42, '279.90', 92, ms(21)));
      expect(report.took.map((d) => d.item), ['PUPU', 'WINGS']);
      expect(report.tookNothing.map((d) => d.item), ['DUCK', 'DRAGON']);
      final platter = report.dishes.first;
      expect((platter.name, platter.sold, platter.taken, platter.amount), ('Pu Pu Platter', 31, 27, '225.00'));
      expect(platter.added.map((a) => (a.item, a.name, a.taken, a.amount)), [
        ('TSINGTAO', 'Tsingtao', 18, '117.00'),
        ('MAITAI', 'Mai Tai', 9, '108.00'),
        ('SODA', 'Soda', 0, '0.00'),
      ]);
      expect(platter.words, '31 sold · 27 added with it');
      expect(report.dishes[2].words, '1,204 sold · nothing added with it');
      expect(report.staff.map((s) => (s.staffId, s.called, s.taken, s.amount)), [
        ('s1', 'Amy', 25, '170.40'),
        ('s2', 'Ben', 15, '98.50'),
        (null, 'Nobody named', 2, '11.00'),
      ]);
    });

    test('an answer with nothing in it reads as nothing', () {
      final report = SuggestionsReport.fromJson({'from': '2026-11-16', 'to': '2026-11-16'});
      expect((report.taken, report.amount, report.running, report.maxDays), (0, '0.00', false, 92));
      expect(report.dishes, isEmpty);
      expect(report.staff, isEmpty);
      expect(report.took, isEmpty);
      expect(report.tookNothing, isEmpty);
      // and one that is not what was expected loses nothing else
      final odd = SuggestionsReport.fromJson({
        'dishes': 'none',
        'staff': [7, null],
        'taken': '4',
      });
      expect(odd.dishes, isEmpty);
      expect(odd.staff, isEmpty);
      expect(odd.taken, 0);
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token and the days', (tester) async {
      final t = await terminal(tester);
      final running = await t.api.suggestionsReport('tok-admin');
      await t.api.suggestionsReport('tok-admin', from: '2026-11-09', to: '2026-11-15');
      await t.api.suggestionsReport('tok-admin', from: '2026-11-12');
      expect(t.hub.suggestionsAsks, ['', theWeek, '2026-11-12..2026-11-12']);
      expect(t.hub.suggestionsAuth, 'Bearer tok-admin');
      expect((running.first, running.running, running.taken), (DateTime(2026, 11, 16), true, 0));
    });
  });

  group('the screen', () {
    testWidgets('Location settings opens it with the manager\'s token', (tester) async {
      final t = await terminal(tester);
      t.hub.suggestions = {theWeek: week()};
      tester.view.physicalSize = const Size(1100, 2800);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'suggestions-report');
      expect(find.text('What was added from "Goes with", by person and by dish'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suggestions-report')));
      await tester.pumpAndSettle();
      expect(find.byType(SuggestionsScreen), findsOneWidget);
      expect(t.hub.suggestionsAsks, hasLength(1)); // the seven days before the device's own today
      expect(t.hub.suggestionsAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('suggestions-total')), findsOneWidget);
    });

    testWidgets('it opens on the seven days just gone: the total, who added them, and under which dish', (
      tester,
    ) async {
      final s = await pumpSuggestions(tester);
      expect(s.t.hub.suggestionsAsks, [theWeek]);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('suggestions:week'))).selected, isTrue);
      expect(find.text('Mon, Nov 9 to Sun, Nov 15, 2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestions-running')), findsNothing);
      expect(row(tester, 'suggestions-total'), ['Suggested dishes added', '42']);
      expect(row(tester, 'suggestions-money'), ['They were sold for', r'$279.90']);

      // who added them, in the hub's order, a screen that named nobody last and said so
      expect(keyed(tester, 'suggestion-staff:'), ['s1', 's2', '']);
      expect(row(tester, 'suggestion-staff:s1'), ['Amy', '25×', r'$170.40']);
      expect(row(tester, 'suggestion-staff:s2'), ['Ben', '15×', r'$98.50']);
      expect(row(tester, 'suggestion-staff:'), ['Nobody named', '2×', r'$11.00']);

      // under the dish each went with: how many of it went out, and each dish added
      expect(keyed(tester, 'suggestion-dish:'), ['PUPU', 'WINGS', 'DUCK', 'DRAGON']);
      expect(row(tester, 'suggestion-dish:PUPU'), ['Pu Pu Platter', '31 sold · 27 added with it', '27×', r'$225.00']);
      expect(keyed(tester, 'suggestion-added:PUPU:'), ['TSINGTAO', 'MAITAI', 'SODA']);
      expect(row(tester, 'suggestion-added:PUPU:TSINGTAO'), ['Tsingtao', '18×', r'$117.00']);
      expect(row(tester, 'suggestion-added:PUPU:MAITAI'), ['Mai Tai', '9×', r'$108.00']);
      expect(row(tester, 'suggestion-added:PUPU:SODA'), ['Soda', 'none']); // suggested, and nobody took it
      expect(row(tester, 'suggestion-dish:WINGS'), ['Chicken wings', '40 sold · 15 added with it', '15×', r'$54.90']);

      // and the dishes that suggest something and went out with nothing added, after their own heading
      final nothing = tester.getTopLeft(find.byKey(const ValueKey('suggestions-nothing'))).dy;
      expect(tester.getTopLeft(find.byKey(const ValueKey('suggestion-dish:WINGS'))).dy, lessThan(nothing));
      expect(tester.getTopLeft(find.byKey(const ValueKey('suggestion-dish:DUCK'))).dy, greaterThan(nothing));
      expect(row(tester, 'suggestion-dish:DUCK'), ['Peking Duck', 'Suggests Tsingtao, Hot tea', '1,204 sold']);
      expect(row(tester, 'suggestion-dish:DRAGON'), ['Dragon roll', 'Suggests Hot tea', '1 sold']);
      expect(find.byKey(const ValueKey('suggestions-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestions-none')), findsNothing);
    });

    testWidgets('Today is the day running; Yesterday and 4 weeks ask for whole days by name', (tester) async {
      final s = await pumpSuggestions(tester);
      await tapKey(tester, 'suggestions:today');
      expect(s.t.hub.suggestionsAsks.last, '');
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestions-running')), findsOneWidget);
      expect(row(tester, 'suggestions-total'), ['Suggested dishes added', '1']);
      expect(keyed(tester, 'suggestion-dish:'), ['PUPU']);
      expect(find.byKey(const ValueKey('suggestions-nothing')), findsNothing);
      await tapKey(tester, 'suggestions:yesterday');
      await tapKey(tester, 'suggestions:four-weeks');
      expect(s.t.hub.suggestionsAsks.skip(2), ['2026-11-15..2026-11-15', '2026-10-19..2026-11-15']);
      // days with nothing taken and no dish to show: said once, with how to set a dish up
      expect(row(tester, 'suggestions-total'), ['Suggested dishes added', '0']);
      expect(find.byKey(const ValueKey('suggestions-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestions-by-staff')), findsNothing);
      expect(find.byKey(const ValueKey('suggestions-by-dish')), findsNothing);
      // in the small hours the day of service is still the one before
      final late = await pumpSuggestions(tester, now: at(2, 30, 17));
      await tapKey(tester, 'suggestions:yesterday');
      expect(late.t.hub.suggestionsAsks, [theWeek, '2026-11-15..2026-11-15']);
    });

    testWidgets('dishes that sold with nothing added are listed even when nothing at all was taken', (tester) async {
      final quiet = week()
        ..['taken'] = 0
        ..['amount'] = '0.00'
        ..['staff'] = <Object>[];
      quiet['dishes'] = (quiet['dishes'] as List).skip(2).toList();
      await pumpSuggestions(tester, suggestions: {theWeek: quiet});
      expect(row(tester, 'suggestions-total'), ['Suggested dishes added', '0']);
      expect(find.byKey(const ValueKey('suggestions-none')), findsNothing);
      expect(find.byKey(const ValueKey('suggestions-by-staff')), findsNothing);
      expect(find.byKey(const ValueKey('suggestions-by-dish')), findsNothing);
      expect(find.byKey(const ValueKey('suggestions-nothing')), findsOneWidget);
      expect(keyed(tester, 'suggestion-dish:'), ['DUCK', 'DRAGON']);
    });

    testWidgets('Other days asks the calendar, and more days than the hub adds up are said', (tester) async {
      final s = await pumpSuggestions(tester);
      await tapKey(tester, 'suggestions:other'); // the calendar closed without any day: nothing changes
      expect(s.asked, [null]);
      expect(s.t.hub.suggestionsAsks, [theWeek]);
      s.picks.add(DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'suggestions:other');
      expect(s.t.hub.suggestionsAsks, [theWeek, '2026-10-01..2026-10-10']);
      expect(find.text('Oct 1 to Oct 10'), findsOneWidget);
      expect(find.text('Thu, Oct 1 to Sat, Oct 10, 2026'), findsOneWidget);
      s.picks.add(DateTimeRange(start: DateTime(2026, 7, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'suggestions:other');
      expect(find.byKey(const ValueKey('suggestions-too-long')), findsOneWidget);
      expect(find.text('At most 92 days at a time: that was 102. Pick fewer days.'), findsOneWidget);
      expect(s.t.hub.suggestionsAsks, hasLength(2));
    });

    testWidgets('Read again asks the hub for the same days', (tester) async {
      final s = await pumpSuggestions(tester);
      s.t.hub.suggestions![theWeek] = week()..['taken'] = 43;
      await tapKey(tester, 'suggestions-refresh');
      expect(s.t.hub.suggestionsAsks, [theWeek, theWeek]);
      expect(row(tester, 'suggestions-total'), ['Suggested dishes added', '43']);
    });

    testWidgets('while the hub adds up, the screen says so', (tester) async {
      final s = await pumpSuggestions(tester);
      final held = s.t.hub.suggestionsHeld = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('suggestions:yesterday')));
      await tester.pump();
      expect(find.text('Adding up the days'), findsOneWidget);
      expect(find.text('Many days can take some seconds the first time.'), findsNothing);
      expect(find.byKey(const ValueKey('suggestions-total')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('suggestions:four-weeks')));
      await tester.pump();
      expect(find.text('Many days can take some seconds the first time.'), findsOneWidget);
      held.complete();
      s.t.hub.suggestionsHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('suggestions-reading')), findsNothing);
      expect(find.text('Mon, Oct 19 to Sun, Nov 15, 2026'), findsOneWidget);
    });

    testWidgets('the manager\'s hour is over, the hub is older, refuses or does not answer: the screen says which', (
      tester,
    ) async {
      await pumpSuggestions(tester, before: (hub) => hub.refuseSuggestions = 401);
      expect(find.text("The manager's hour here is over: go back and open Location again."), findsOneWidget);
      await pumpSuggestions(tester, older: true);
      expect(
        find.text('This hub is older than the report of suggestions taken. Update the hub to see it here.'),
        findsOneWidget,
      );
      final refused = await pumpSuggestions(
        tester,
        before: (hub) => hub
          ..refuseSuggestions = 422
          ..salesRefusal = 'At most 92 days at a time.',
      );
      expect(find.text('At most 92 days at a time.'), findsOneWidget);
      refused.t.hub.refuseSuggestions = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('suggestions-error')), findsNothing);
      expect(row(tester, 'suggestions-total').last, '42');
      final down = await pumpSuggestions(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
      down.t.hub.down = false;
    });

    testWidgets('on a small phone long names and large figures fit, in the dark too', (tester) async {
      final big = week()
        ..['taken'] = 1234567
        ..['amount'] = '12345678.90';
      big['dishes'] = [
        for (var i = 0; i < 30; i++)
          dish(
            'D$i',
            'Chef\'s seasonal speciality number $i with three delights',
            123456,
            i < 20 ? 123456 : 0,
            i < 20 ? '1234567.89' : '0.00',
            [
              added('A', 'A long drink with a very long name indeed, on the rocks', i < 20 ? 123456 : 0, '1234567.89'),
              added('B', 'Another long drink with a longer name, no ice at all', 0, '0.00'),
            ],
          ),
      ];
      big['staff'] = [
        for (var i = 0; i < 12; i++) person('s$i', 'Somebody with a very long name number $i', 123456, '1234567.89'),
      ];
      for (final dark in [false, true]) {
        await pumpSuggestions(
          tester,
          suggestions: {theWeek: big},
          size: const Size(320, 568),
          theme: dark ? ThemeData.dark() : null,
        );
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 12; i++) {
          await tester.drag(find.byKey(const ValueKey('suggestions-list')), const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}
