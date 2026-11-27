import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/contests.dart';
import 'package:pos_app/screens/contests_screen.dart';
import 'package:pos_app/screens/dish_finder.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/session.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Contests for the staff (docs/contests.md): a manager sets one up (what counts, the days, who takes part,
/// who sees the numbers), and everybody reads where they stand from the menu of the list of checks. The hub
/// adds up who is ahead; the app words its answer. Each person sees their own number and place and who is in
/// front, and every name and number only where the manager said so. Nothing here is a sale.

final monday = DateTime(2026, 11, 16);

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

String words(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

bool enabled(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed != null;

/// The month of Mai Tais: Ben in front with 18, Amy on 14, Cara with none yet.
void maiTais(Hub hub, {String board = 'own', String first = '2026-11-01', String last = '2026-11-30'}) {
  hub.contests = [
    Hub.contest(
      'mai-tai-month',
      'Mai Tai month',
      counts: 'dish',
      item: 'MAITAI',
      what: 'Mai Tai',
      first: first,
      last: last,
      board: board,
      note: 'Winner picks the staff meal',
    ),
  ];
  hub.contestBoards['mai-tai-month'] = [
    Hub.contestRow('s2', 'Ben', 1, count: 18, amount: '216.00', role: 'bartender'),
    Hub.contestRow('s1', 'Amy', 2, count: 14, amount: '168.00'),
    Hub.contestRow('s6', 'Cara', null),
  ];
}

/// Monday's sales: Amy in front of Ben, and a manager's soda outside the board.
void mondaySales(Hub hub) {
  hub.contests = [Hub.contest('monday-night', 'Monday night')];
  hub.contestBoards['monday-night'] = [
    Hub.contestRow('s1', 'Amy', 1, count: 6, amount: '52.10'),
    Hub.contestRow('s2', 'Ben', 2, count: 1, amount: '6.50', role: 'bartender'),
  ];
  hub.contestOthers['monday-night'] = {'count': 1, 'amount': '2.95'};
}

/// The Contests screen as whoever is signed in has it from the menu ([who]: Amy the server unless said), or
/// as Location opens it with a manager's [token].
Future<Terminal> pumpContests(
  WidgetTester tester, {
  Staff? who = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin'),
  String? token,
  bool edits = true,
  Size size = const Size(390, 844),
  double textScale = 1,
  void Function(Hub hub)? hub,
}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ContestsScreen(
        api: t.api,
        device: 't1',
        staff: token == null ? who : null,
        token: token,
        edits: edits,
        now: () => DateTime(2026, 11, 16, 16, 2),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The contests the hub was last sent to keep.
List<Map<String, dynamic>> sent(Hub hub) => (hub.contestsSaved.last['contests'] as List).cast<Map<String, dynamic>>();

/// Picks [day] off the calendar behind the button [key], typed as a date.
Future<void> pickDay(WidgetTester tester, String key, DateTime day) async {
  await tapKey(tester, key);
  await tester.tap(find.byTooltip('Switch to input'));
  await tester.pumpAndSettle();
  String two(int n) => n.toString().padLeft(2, '0');
  await tester.enterText(
    find.descendant(of: find.byType(DatePickerDialog), matching: find.byType(TextField)),
    '${two(day.month)}/${two(day.day)}/${day.year}',
  );
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  group('the words', () {
    Contest on(Map<String, dynamic> stored, {String today = '2026-11-16', Map<String, dynamic> more = const {}}) {
      final first = DateTime.parse(stored['first'] as String), last = DateTime.parse(stored['last'] as String);
      final now = DateTime.parse(today);
      return Contest.fromJson({
        ...stored,
        'state': now.isBefore(first) ? 'coming' : (now.isAfter(last) ? 'over' : 'running'),
        ...more,
      });
    }

    test('a place is said as a person says it', () {
      expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map(placeWords).toList(), [
        '1st',
        '2nd',
        '3rd',
        '4th',
        '11th',
        '12th',
        '13th',
        '21st',
        '22nd',
        '23rd',
        '101st',
        '111th',
      ]);
    });

    test('what counts and the days it runs', () {
      final sales = on(Hub.contest('a', 'Monday night'));
      final dish = on(
        Hub.contest('b', 'Mai Tais', counts: 'dish', item: 'MAITAI', what: 'Mai Tai', last: '2026-11-30'),
      );
      final gone = on(Hub.contest('c', 'Old', counts: 'category', category: 'x', last: '2027-01-03'));
      expect((countsWords(sales), daysWords(sales, monday)), ('Most sales', 'Nov 16'));
      expect((countsWords(dish), daysWords(dish, monday)), ('Most Mai Tai sold', 'Nov 16 to Nov 30'));
      expect((countsWords(gone), daysWords(gone, monday)), ('Most sold', 'Nov 16 to Jan 3, 2027'));
      expect(rolesWords(const ['server', 'bartender', 'manager']), 'Servers, Bartenders, Managers');
      expect(boardWords(sales), 'Each person sees only their own number');
      expect(boardWords(on(Hub.contest('d', 'Open', board: 'all'))), 'Everybody sees the whole board');
    });

    test('where it stands in time is said against the day of the hub', () {
      Contest between(String first, String last) => on(Hub.contest('a', 'x', first: first, last: last));
      expect(stateWords(between('2026-11-17', '2026-11-20'), monday), 'Starts tomorrow');
      expect(stateWords(between('2026-11-20', '2026-11-22'), monday), 'Starts Fri Nov 20');
      expect(stateWords(between('2026-11-16', '2026-11-16'), monday), 'Ends today');
      expect(stateWords(between('2026-11-10', '2026-11-17'), monday), '1 day left');
      expect(stateWords(between('2026-11-01', '2026-11-30'), monday), '14 days left');
      expect(stateWords(between('2026-11-09', '2026-11-15'), monday), 'Ended yesterday');
      expect(stateWords(between('2026-11-03', '2026-11-09'), monday), 'Ended Mon Nov 9');
      // the clocks go back on the 1st of November: the days are still whole
      final autumn = on(
        Hub.contest('a', 'x', first: '2026-10-20', last: '2026-11-05'),
        today: '2026-10-30',
      );
      expect(stateWords(autumn, DateTime(2026, 10, 30)), '6 days left');
    });

    test('where a person stands, and who is in front', () {
      Contest seen(Map<String, dynamic> more, {String today = '2026-11-16', String counts = 'dish'}) => on(
        Hub.contest('a', 'x', counts: counts, item: counts == 'dish' ? 'MAITAI' : null, what: 'Mai Tai'),
        today: today,
        more: more,
      );
      final second = seen({
        'takes_part': true,
        'me': Hub.contestRow('s1', 'Amy', 2, count: 14, amount: '168.00'),
        'of': 6,
        'front': ['Ben'],
      });
      expect((mineWords(second), frontWords(second)), ('2nd of 6 · 14', 'In front: Ben'));
      final money = seen({
        'takes_part': true,
        'me': Hub.contestRow('s1', 'Amy', 1, count: 6, amount: '1052.10'),
        'of': 2,
        'front': ['Amy', 'Ben'],
      }, counts: 'sales');
      expect((mineWords(money), frontWords(money)), ('1st of 2 · \$1,052.10', 'Level in front: Amy and Ben'));
      final nothing = seen({'takes_part': true, 'me': Hub.contestRow('s1', 'Amy', null), 'of': 6, 'front': []});
      expect((mineWords(nothing), frontWords(nothing)), ('Nothing yet · 6 take part', 'Nobody has any yet'));
      final outside = seen({
        'takes_part': false,
        'me': null,
        'of': 6,
        'front': ['Ben'],
      });
      expect(mineWords(outside), 'You are not in this one');
      // over: the same answer says who won
      final won = seen({
        'takes_part': true,
        'me': Hub.contestRow('s1', 'Amy', 2, count: 14),
        'of': 3,
        'front': ['Ben', 'Cara', 'Dee'],
      }, today: '2026-11-18');
      expect(frontWords(won), 'Won by Ben, Cara and Dee');
      expect(frontWords(seen({'front': []}, today: '2026-11-18')), 'Nobody rang any');
      // not begun: nothing to be in front of
      final coming = on(
        Hub.contest('a', 'x', first: '2026-11-20', last: '2026-11-22'),
        more: {'takes_part': true, 'me': Hub.contestRow('s1', 'Amy', null), 'of': 4, 'front': []},
      );
      expect((mineWords(coming), frontWords(coming)), ('You are in · 4 take part', ''));
    });

    test('a row has the figure it is ranked by and the other one', () {
      final dish = on(Hub.contest('a', 'x', counts: 'dish', item: 'MAITAI', what: 'Mai Tai'));
      final sales = on(Hub.contest('b', 'y'));
      final row = ContestRow.fromJson(Hub.contestRow('s1', 'Amy', 1, count: 14, amount: '168.00'));
      expect((figureWords(dish, row), otherFigureWords(dish, row)), ('14', '\$168.00'));
      expect((figureWords(sales, row), otherFigureWords(sales, row)), ('\$168.00', '14 dishes'));
      expect(otherFigureWords(sales, const ContestRow(staffId: 's2', name: 'Ben', count: 1)), '1 dish');
      final whole = on(
        Hub.contest('b', 'y'),
        more: {
          'others': {'count': 1, 'amount': '2.95'},
        },
      );
      expect(othersWords(whole), 'Rung by people who are not in it: \$2.95');
      final counted = on(
        Hub.contest('a', 'x', counts: 'dish', item: 'MAITAI'),
        more: {
          'others': {'count': 3, 'amount': '36.00'},
        },
      );
      expect(othersWords(counted), 'Rung by people who are not in it: 3 · \$36.00');
      expect(othersWords(sales), '');
    });

    test('a contest is sent as it is set up, and an answer that says less is still read', () {
      final made = const Contest(
        name: 'Mai Tais',
        counts: 'dish',
        item: 'MAITAI',
        first: '2026-11-01',
        last: '2026-11-30',
      );
      expect(made.toJson(), {
        'name': 'Mai Tais',
        'note': '',
        'counts': 'dish',
        'item': 'MAITAI',
        'category': null,
        'first': '2026-11-01',
        'last': '2026-11-30',
        'roles': ['server', 'bartender'],
        'board': 'own',
      });
      final kept = Contest.fromJson(Hub.contest('mai', 'Mai Tais', counts: 'dish', item: 'MAITAI', what: 'Mai Tai'));
      expect(kept.copyWith(counts: 'sales').toJson(), containsPair('item', null));
      expect(kept.toJson()['id'], 'mai');
      final little = Contest.fromJson({'id': 'x', 'name': 'X', 'first': '2026-11-16', 'last': '2026-11-16'});
      expect(little.roles, ['server', 'bartender']);
      expect(
        (little.counts, little.board, little.shown, little.standings, little.me),
        ('sales', 'own', true, null, null),
      );
      final list = ContestList.fromJson({
        'contests': [
          {...Hub.contest('a', 'A'), 'shown': true},
          {...Hub.contest('b', 'B'), 'shown': false},
        ],
      });
      expect((list.shown, list.most, list.daysMax, list.roles.length), (1, 12, 92, 8));
      expect(list.categories, isEmpty);
    });
  });

  group('what everybody sees', () {
    testWidgets('a server sees their own number and place and who is in front, and nobody else\'s number', (
      tester,
    ) async {
      final t = await pumpContests(tester, hub: maiTais);
      expect(find.text('Mai Tai month'), findsOneWidget);
      expect(words(tester, 'contest-state:mai-tai-month'), '14 days left');
      expect(words(tester, 'contest-about:mai-tai-month'), 'Most Mai Tai sold · Nov 1 to Nov 30 · Servers, Bartenders');
      expect(find.text('Winner picks the staff meal'), findsOneWidget);
      expect(words(tester, 'contest-mine:mai-tai-month'), '2nd of 3 · 14');
      expect(words(tester, 'contest-front:mai-tai-month'), 'In front: Ben');
      // no board, and nothing of Ben's but his name
      expect(find.byKey(const ValueKey('contest-rows:mai-tai-month')), findsNothing);
      expect(find.text('18'), findsNothing);
      expect(find.textContaining('216'), findsNothing);
      // a server sets nothing up, and the hub was asked as Amy and never for a whole board
      expect(find.byKey(const ValueKey('contests-unlock')), findsNothing);
      expect(find.byKey(const ValueKey('contest-new')), findsNothing);
      expect(t.hub.contestAsks, ['s1']);
      expect(t.hub.contestBoardAsks, isEmpty);
      expect(words(tester, 'contests-how'), contains('whoever rang it in'));
    });

    testWidgets('where the manager said so, everybody sees the whole board', (tester) async {
      await pumpContests(tester, hub: (hub) => maiTais(hub, board: 'all'));
      expect(words(tester, 'contest-mine:mai-tai-month'), '2nd of 3 · 14');
      final rows = find.byKey(const ValueKey('contest-rows:mai-tai-month'));
      expect(rows, findsOneWidget);
      String row(String staffId) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey('contest-row:mai-tai-month:$staffId')),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .join(' | ');
      expect(row('s2'), '1 | Ben | 18');
      expect(row('s1'), '2 | Amy (you) | 14');
      expect(row('s6'), '– | Cara | 0');
      // how much money that was stays in the manager's report
      expect(find.textContaining('216'), findsNothing);
    });

    testWidgets('somebody who does not take part sees who is in front and no number', (tester) async {
      await pumpContests(
        tester,
        who: const Staff(staffId: 's4', name: 'Holly', role: 'host', method: 'pin'),
        hub: maiTais,
      );
      expect(words(tester, 'contest-mine:mai-tai-month'), 'You are not in this one');
      expect(words(tester, 'contest-front:mai-tai-month'), 'In front: Ben');
      expect(find.text('18'), findsNothing);
      expect(find.byKey(const ValueKey('contests-unlock')), findsNothing);
    });

    testWidgets('one that has not begun says when it starts, and one that is over who won', (tester) async {
      await pumpContests(
        tester,
        hub: (hub) {
          maiTais(hub, first: '2026-11-03', last: '2026-11-09');
          hub.contests!.add(Hub.contest('weekend', 'Weekend sales', first: '2026-11-20', last: '2026-11-22'));
          hub.contestBoards['weekend'] = [Hub.contestRow('s1', 'Amy', null), Hub.contestRow('s2', 'Ben', null)];
        },
      );
      expect(words(tester, 'contest-state:mai-tai-month'), 'Ended Mon Nov 9');
      expect(words(tester, 'contest-front:mai-tai-month'), 'Won by Ben');
      expect(words(tester, 'contest-mine:mai-tai-month'), '2nd of 3 · 14');
      expect(words(tester, 'contest-state:weekend'), 'Starts Fri Nov 20');
      expect(words(tester, 'contest-mine:weekend'), 'You are in · 2 take part');
      expect(find.byKey(const ValueKey('contest-front:weekend')), findsNothing);
    });

    testWidgets('a contest that ended more than a week ago is off the staff\'s screens', (tester) async {
      await pumpContests(
        tester,
        hub: (hub) => maiTais(hub, first: '2026-10-01', last: '2026-10-31'),
      );
      expect(find.text('Mai Tai month'), findsNothing);
      expect(words(tester, 'contests-none'), 'No contest is running.');
    });

    testWidgets('a hub older than contests says so, and one that does not answer offers to try again', (tester) async {
      await pumpContests(tester, hub: (hub) => hub.contests = null);
      expect(words(tester, 'contests-old'), contains('older than contests'));
      await tester.pumpWidget(const SizedBox()); // a screen of its own, not the one above read again
      final t = await pumpContests(tester, hub: (hub) => hub.down = true);
      expect(find.byKey(const ValueKey('contests-error')), findsOneWidget);
      t.hub.down = false;
      maiTais(t.hub);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Mai Tai month'), findsOneWidget);
    });

    testWidgets('it fits a phone with large type', (tester) async {
      await pumpContests(
        tester,
        size: const Size(320, 568),
        textScale: 1.5,
        hub: (hub) {
          maiTais(hub, board: 'all');
          hub.contests!.first['name'] = 'The longest Mai Tai month there ever was';
          hub.contests!.first['roles'] = ['server', 'bartender', 'host', 'cashier', 'manager'];
        },
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('contest-rows:mai-tai-month')), findsOneWidget);
    });

    testWidgets('a manager types their PIN there and has every board, and the setting up', (tester) async {
      final t = await pumpContests(
        tester,
        who: const Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin'),
        hub: maiTais,
      );
      // until then a manager sees what anybody would
      expect(words(tester, 'contest-mine:mai-tai-month'), 'You are not in this one');
      await tapKey(tester, 'contests-unlock');
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.text('Open the contests'));
      await tester.pumpAndSettle();
      expect(t.hub.sessionsFor.last, 'settings');
      expect(find.byKey(const ValueKey('contest-rows:mai-tai-month')), findsOneWidget);
      expect(find.text('18'), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-change:mai-tai-month')), findsOneWidget);
      expect(t.hub.contestBoardAuth, 'Bearer tok-admin');
    });
  });

  group('a manager', () {
    testWidgets('has every contest with its whole board: both figures, and what the others rang', (tester) async {
      final t = await pumpContests(tester, token: 'tok-admin', hub: mondaySales);
      expect(words(tester, 'contest-state:monday-night'), 'Ends today');
      expect(words(tester, 'contest-board:monday-night'), 'Each person sees only their own number');
      String row(String staffId) => tester
          .widgetList<Text>(
            find.descendant(of: find.byKey(ValueKey('contest-row:monday-night:$staffId')), matching: find.byType(Text)),
          )
          .map((text) => text.data)
          .join(' | ');
      expect(row('s1'), '1 | Amy | 6 dishes | \$52.10');
      expect(row('s2'), '2 | Ben | 1 dish | \$6.50');
      expect(words(tester, 'contest-others:monday-night'), 'Rung by people who are not in it: \$2.95');
      expect(find.textContaining('Set up by Mike, today 15:00'), findsOneWidget);
      expect(t.hub.contestBoardAsks, ['monday-night']);
      expect(t.hub.contestAsks, isEmpty);
    });

    testWidgets('an old contest keeps its board for whoever asks for it', (tester) async {
      final t = await pumpContests(
        tester,
        token: 'tok-admin',
        hub: (hub) => maiTais(hub, first: '2026-10-01', last: '2026-10-31'),
      );
      expect(find.text('Mai Tai month'), findsOneWidget);
      expect(find.textContaining("off the staff's screens"), findsOneWidget);
      expect(t.hub.contestBoardAsks, isEmpty, reason: 'not added up until somebody asks');
      await tapKey(tester, 'contest-show:mai-tai-month');
      expect(t.hub.contestBoardAsks, ['mai-tai-month']);
      expect(words(tester, 'contest-front:mai-tai-month'), 'Won by Ben');
      expect(find.byKey(const ValueKey('contest-rows:mai-tai-month')), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-show:mai-tai-month')), findsNothing);
    });

    testWidgets('sets a contest on sales up with a name: a week from today, the servers and the bartenders', (
      tester,
    ) async {
      final t = await pumpContests(tester, token: 'tok-admin');
      expect(words(tester, 'contests-none'), contains('changes no sale and nobody\'s pay'));
      await tapKey(tester, 'contest-new');
      expect(enabled(tester, 'contest-save'), isFalse);
      expect(words(tester, 'contest-missing'), 'Give it a name.');
      expect(words(tester, 'contest-days'), '7 days');
      await tester.enterText(find.byKey(const ValueKey('contest-name')), ' Thanksgiving week ');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('contest-missing')), findsNothing);
      await tapKey(tester, 'contest-save');
      expect(t.hub.contestsAuth, 'Bearer tok-admin');
      expect(sent(t.hub), [
        {
          'name': 'Thanksgiving week',
          'note': '',
          'counts': 'sales',
          'item': null,
          'category': null,
          'first': '2026-11-16',
          'last': '2026-11-22',
          'roles': ['server', 'bartender'],
          'board': 'own',
        },
      ]);
      expect(find.byKey(const ValueKey('contest-made')), findsOneWidget);
      expect(find.text('Thanksgiving week'), findsOneWidget);
      expect(words(tester, 'contest-state:thanksgiving-week'), '6 days left');
    });

    testWidgets('picks the dish that counts from the menu', (tester) async {
      final t = await pumpContests(tester, token: 'tok-admin');
      await tapKey(tester, 'contest-new');
      await tester.enterText(find.byKey(const ValueKey('contest-name')), 'Mai Tai month');
      await tapKey(tester, 'contest-counts:dish');
      expect(words(tester, 'contest-missing'), 'Pick the dish that counts.');
      expect(enabled(tester, 'contest-save'), isFalse);
      await tapKey(tester, 'contest-dish');
      expect(find.byType(DishFinderDialog), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('dish-finder-typed')), 'mai');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dish-found:MAITAI:glass')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const ValueKey('contest-dish')), matching: find.text('Mai Tai')), findsOne);
      await tapKey(tester, 'contest-save');
      expect(
        (sent(t.hub).single['counts'], sent(t.hub).single['item'], sent(t.hub).single['category']),
        ('dish', 'MAITAI', null),
      );
      expect(words(tester, 'contest-about:mai-tai-month'), startsWith('Most Mai Tai sold · '));
    });

    testWidgets('picks a category, who takes part, who sees the numbers and what the winner gets', (tester) async {
      final t = await pumpContests(tester, token: 'tok-admin');
      await tapKey(tester, 'contest-new');
      await tester.enterText(find.byKey(const ValueKey('contest-name')), 'Cocktail week');
      await tapKey(tester, 'contest-counts:category');
      expect(words(tester, 'contest-missing'), 'Pick the category that counts.');
      await tapKey(tester, 'contest-category');
      await tester.tap(find.text('Cocktails · Drinks').last);
      await tester.pumpAndSettle();
      await tapKey(tester, 'contest-role:server');
      await tapKey(tester, 'contest-role:bartender');
      expect(words(tester, 'contest-missing'), 'Somebody has to take part.');
      await tapKey(tester, 'contest-role:bartender');
      await tapKey(tester, 'contest-role:manager');
      await tapKey(tester, 'contest-board-all');
      await tester.enterText(find.byKey(const ValueKey('contest-note')), 'A bottle of the good sake');
      await tester.pumpAndSettle();
      await tapKey(tester, 'contest-save');
      final made = sent(t.hub).single;
      expect((made['counts'], made['category'], made['item']), ('category', 'cocktails', null));
      expect(made['roles'], ['bartender', 'manager']);
      expect((made['board'], made['note']), ('all', 'A bottle of the good sake'));
      expect(words(tester, 'contest-about:cocktail-week'), contains('Most Cocktails sold'));
      expect(words(tester, 'contest-board:cocktail-week'), 'Everybody sees the whole board');
    });

    testWidgets('picks the days: a new start keeps the length, and a quarter of a year is the most', (tester) async {
      final t = await pumpContests(tester, token: 'tok-admin');
      await tapKey(tester, 'contest-new');
      await tester.enterText(find.byKey(const ValueKey('contest-name')), 'December');
      await pickDay(tester, 'contest-first', DateTime(2026, 12, 1));
      expect(words(tester, 'contest-days'), '7 days'); // the 1st to the 7th
      await pickDay(tester, 'contest-last', DateTime(2026, 11, 30));
      expect(words(tester, 'contest-days'), 'The last day is before the first.');
      expect(enabled(tester, 'contest-save'), isFalse);
      await pickDay(tester, 'contest-last', DateTime(2027, 3, 31));
      expect(words(tester, 'contest-days'), '121 days');
      expect(words(tester, 'contest-missing'), 'A contest runs 92 days at most.');
      expect(enabled(tester, 'contest-save'), isFalse);
      await pickDay(tester, 'contest-last', DateTime(2026, 12, 31));
      expect(words(tester, 'contest-days'), '31 days');
      await tapKey(tester, 'contest-save');
      expect((sent(t.hub).single['first'], sent(t.hub).single['last']), ('2026-12-01', '2026-12-31'));
      expect(words(tester, 'contest-state:december'), 'Starts Tue Dec 1');
      // not begun: there is no board to show yet
      expect(find.byKey(const ValueKey('contest-show:december')), findsNothing);
    });

    testWidgets('a contest of years ago still opens on its own days', (tester) async {
      final t = await pumpContests(
        tester,
        token: 'tok-admin',
        hub: (hub) => maiTais(hub, first: '2024-06-01', last: '2024-06-30'),
      );
      await tapKey(tester, 'contest-change:mai-tai-month');
      await tapKey(tester, 'contest-last');
      expect(tester.takeException(), isNull);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      await pickDay(tester, 'contest-first', DateTime(2026, 11, 16));
      expect(words(tester, 'contest-days'), '30 days');
      await tapKey(tester, 'contest-save');
      expect((sent(t.hub).single['first'], sent(t.hub).single['last']), ('2026-11-16', '2026-12-15'));
    });

    testWidgets('changes a contest, and the others stay as they were', (tester) async {
      final t = await pumpContests(
        tester,
        token: 'tok-admin',
        hub: (hub) {
          maiTais(hub);
          mondaySalesAfter(hub);
        },
      );
      await tapKey(tester, 'contest-change:mai-tai-month');
      expect(find.text('Change the contest'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('contest-name'))).controller!.text, 'Mai Tai month');
      expect(find.descendant(of: find.byKey(const ValueKey('contest-dish')), matching: find.text('Mai Tai')), findsOne);
      expect(words(tester, 'contest-days'), '30 days');
      await tapKey(tester, 'contest-board-all');
      await tapKey(tester, 'contest-save');
      final [first, second] = sent(t.hub);
      expect(
        (first['id'], first['board'], first['item'], first['note']),
        ('mai-tai-month', 'all', 'MAITAI', 'Winner picks the staff meal'),
      );
      expect((second['id'], second['board']), ('monday-night', 'own'));
      expect(find.byKey(const ValueKey('contest-changed')), findsOneWidget);
      expect(words(tester, 'contest-board:mai-tai-month'), 'Everybody sees the whole board');
    });

    testWidgets('takes a contest away only after saying so', (tester) async {
      final t = await pumpContests(
        tester,
        token: 'tok-admin',
        hub: (hub) {
          maiTais(hub);
          mondaySalesAfter(hub);
        },
      );
      await tapKey(tester, 'contest-away:mai-tai-month');
      expect(find.text('Take "Mai Tai month" away?'), findsOneWidget);
      expect(find.textContaining('No sale is touched.'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(t.hub.contestsSaved, isEmpty);
      await tapKey(tester, 'contest-away:mai-tai-month');
      await tapKey(tester, 'contest-away-sure');
      expect([for (final c in sent(t.hub)) c['id']], ['monday-night']);
      expect(find.text('Mai Tai month'), findsNothing);
      expect(find.text('Monday night'), findsOneWidget);
    });

    testWidgets('is told why the hub would not keep a contest', (tester) async {
      final t = await pumpContests(tester, token: 'tok-admin');
      t.hub.refuseContests = 'Lobster week: that dish is not on the menu.';
      await tapKey(tester, 'contest-new');
      await tester.enterText(find.byKey(const ValueKey('contest-name')), 'Lobster week');
      await tester.pumpAndSettle();
      await tapKey(tester, 'contest-save');
      expect(find.text('Lobster week: that dish is not on the menu.'), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-refused')), findsOneWidget);
      expect(words(tester, 'contests-none'), isNotEmpty);
    });

    testWidgets('who may only read the reports reads every board and sets nothing up', (tester) async {
      await pumpContests(tester, token: 'tok-s4', edits: false, hub: mondaySales);
      expect(find.byKey(const ValueKey('contest-rows:monday-night')), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-new')), findsNothing);
      expect(find.byKey(const ValueKey('contest-change:monday-night')), findsNothing);
      expect(find.byKey(const ValueKey('contest-away:monday-night')), findsNothing);
    });

    testWidgets('with twelve kept, one is taken away before another is set up', (tester) async {
      await pumpContests(
        tester,
        token: 'tok-admin',
        hub: (hub) => hub.contests = [
          for (var n = 1; n <= 12; n++) Hub.contest('c$n', 'Contest $n', first: '2026-12-01', last: '2026-12-02'),
        ],
      );
      expect(enabled(tester, 'contest-new'), isFalse);
      expect(find.text('Take one away to set up another'), findsOneWidget);
    });

    testWidgets('the form fits a phone with large type', (tester) async {
      await pumpContests(tester, token: 'tok-admin', size: const Size(320, 568), textScale: 1.5, hub: maiTais);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'contest-change:mai-tai-month');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'contest-counts:category');
      // what is missing is in sight over the buttons, though the form is longer than the phone
      expect(find.text('Pick the category that counts.').hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-note')).hitTestable(), findsNothing);
      await tapKey(tester, 'contest-counts:sales');
      expect(find.byKey(const ValueKey('contest-missing')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('where it opens from', () {
    testWidgets('while a contest is on the staff\'s screens the menu of the checks offers it', (tester) async {
      final t = await terminal(tester, role: 'server');
      t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
      maiTais(t.hub);
      await pumpOrdersOn(tester, t);
      await openHome(tester, 'contests');
      await tester.pumpAndSettle();
      expect(find.byType(ContestsScreen), findsOneWidget);
      expect(words(tester, 'contest-mine:mai-tai-month'), '2nd of 3 · 14');
      expect(t.hub.contestAsks, ['s1']);
      await stop(tester);
    });

    testWidgets('with no contest, or only one long over, the menu does not', (tester) async {
      final t = await terminal(tester, role: 'server');
      await pumpOrdersOn(tester, t);
      expect(homeIds(tester), isNot(contains('contests')));
      await stop(tester);
      final old = await terminal(tester, role: 'server');
      maiTais(old.hub, first: '2026-10-01', last: '2026-10-31');
      await pumpOrdersOn(tester, old);
      expect(homeIds(tester), isNot(contains('contests')));
      await stop(tester);
      final older = await terminal(tester, role: 'server');
      older.hub.contests = null; // a hub older than contests
      await pumpOrdersOn(tester, older);
      expect(homeIds(tester), isNot(contains('contests')));
      await stop(tester);
    });

    testWidgets('a manager sets contests up from Location, which says what is running', (tester) async {
      final t = await terminal(tester);
      maiTais(t.hub);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', staffId: 's3', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'contests');
      expect(
        find.descendant(of: find.byKey(const ValueKey('contests')), matching: find.text('Running: Mai Tai month')),
        findsOneWidget,
      );
      await tapKey(tester, 'contests');
      expect(find.byType(ContestsScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('contest-rows:mai-tai-month')), findsOneWidget);
      expect(t.hub.contestBoardAuth, 'Bearer tok-admin');
    });

    testWidgets('Location says when none is set up, and when the hub is older than contests', (tester) async {
      Future<String> line({bool older = false}) async {
        final t = await terminal(tester);
        if (older) t.hub.contests = null;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: LocationSettingsScreen(api: t.api, token: 'tok-admin', staffId: 's3', device: 't1'),
          ),
        );
        await tester.pumpAndSettle();
        await bringUp(tester, 'contests');
        final row = tester.widget<ListTile>(find.byKey(const ValueKey('contests')));
        return (row.subtitle! as Text).data!;
      }

      expect(await line(), startsWith('None set up'));
      expect(await line(older: true), contains('older hub'));
    });
  });
}

/// Monday's sales as a second contest, after whatever the hub already keeps.
void mondaySalesAfter(Hub hub) {
  hub.contests!.add(Hub.contest('monday-night', 'Monday night'));
  hub.contestBoards['monday-night'] = [
    Hub.contestRow('s1', 'Amy', 1, count: 6, amount: '52.10'),
    Hub.contestRow('s2', 'Ben', 2, count: 1, amount: '6.50', role: 'bartender'),
  ];
}
