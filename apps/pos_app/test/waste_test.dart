import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/dish_names.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/waste_dialog.dart';
import 'package:pos_app/screens/waste_reasons_dialog.dart';
import 'package:pos_app/screens/waste_screen.dart';
import 'package:pos_app/waste.dart';

import 'hub.dart';
import 'location_rows.dart';

/// The waste log (docs/waste-log.md): anybody signed in writes down what was made and not sold (a dish
/// found on the menu, or something typed; how many; a reason of the location's list) and reads today's;
/// whoever wrote an entry strikes it out, and it stays readable; a manager, from Location, adds the days
/// up by reason, by dish and by day, strikes any entry and keeps the list of reasons. Nothing here is a
/// check or a sale.

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// The Waste screen as Amy (a server) has it from the orders screen, or as a manager has it from Location
/// ([token]).
Future<Terminal> pumpWaste(
  WidgetTester tester, {
  String staffId = 's1',
  String? token,
  bool chinese = false,
  Size? size,
  double textScale = 1,
  void Function(Hub hub)? hub,
}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  if (size != null) tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: DishLanguage(chinese: chinese, child: child!),
      ),
      home: WasteScreen(
        api: t.api,
        staffId: staffId,
        device: 't1',
        token: token,
        now: () => DateTime(2026, 11, 16, 21),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// Three entries of a Monday night: Amy's wings, Ben's tray of rice, Amy's two quarts (the newest).
void night(Hub hub) {
  hub.waste = [
    hub.wasteEntry('w3', "General Tso's Chicken (Quart)", 2, 'Burnt', each: '24.95', variantId: 'GTC:quart'),
    hub.wasteEntry('w2', 'Tray of white rice', 1, 'Expired', by: 'Ben', byId: 's2', note: 'left out overnight'),
    hub.wasteEntry('w1', 'Chicken wings', 1, 'Dropped', each: '8.95', variantId: 'WINGS:6pc'),
  ];
}

String words(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  group('the words', () {
    test('what a day comes to, said in one line', () {
      expect(wasteSummary(const WasteTotal()), 'Nothing wasted');
      expect(wasteSummary(const WasteTotal(entries: 2, count: 3, value: '58.85')), '3 wasted · \$58.85 at menu prices');
      expect(
        wasteSummary(const WasteTotal(entries: 3, count: 4, value: '58.85', unpriced: 1)),
        '4 wasted · \$58.85 at menu prices · 1 with no price',
      );
      expect(wasteSummary(const WasteTotal(entries: 1, count: 2, unpriced: 2)), '2 wasted · no price');
    });

    test('an older hub that says less is still read', () {
      final day = WasteDay.fromJson({
        'day': '2026-11-16',
        'entries': [
          {'id': 'w1', 'name': 'Rice', 'qty': 2, 'reason': 'Expired'},
        ],
      });
      expect((day.entries.single.value, day.entries.single.struck, day.today), (null, false, true));
      expect((day.total.count, day.reasons.length, day.qtyMax), (0, 0, 999));
    });
  });

  group('today', () {
    testWidgets('the entries are read newest first, with what they come to', (tester) async {
      await pumpWaste(tester, hub: night);
      expect(words(tester, 'waste-today'), '4 wasted · \$58.85 at menu prices · 1 with no price');
      final rows = tester.widgetList(
        find.byWidgetPredicate((w) => w is Padding && '${w.key}'.contains('waste-entry:')),
      );
      expect(
        [for (final row in rows) '${row.key}'],
        ["[<'waste-entry:w3'>]", "[<'waste-entry:w2'>]", "[<'waste-entry:w1'>]"],
      );
      expect(find.text("General Tso's Chicken (Quart)"), findsOneWidget);
      expect(find.text('2×'), findsOneWidget);
      expect(find.text('\$49.90'), findsOneWidget);
      expect(find.textContaining('Burnt · Amy · '), findsOneWidget);
      expect(find.text('left out overnight'), findsOneWidget);
      // no manager is here: no totals over days, and no other day
      expect(find.byKey(const ValueKey('waste-view')), findsNothing);
      expect(find.byKey(const ValueKey('waste-day-back')), findsNothing);
      expect(words(tester, 'waste-day'), 'Today');
    });

    testWidgets('an empty day says what the log is for', (tester) async {
      await pumpWaste(tester);
      expect(words(tester, 'waste-today'), 'Nothing wasted');
      expect(words(tester, 'waste-empty'), contains('It is not a sale and changes no check.'));
      expect(find.byKey(const ValueKey('waste-log')), findsOneWidget);
    });

    testWidgets('a hub older than the log says so, and nothing can be written', (tester) async {
      await pumpWaste(tester, hub: (hub) => hub.waste = null);
      expect(words(tester, 'waste-error'), 'This hub is older than the waste log. Update the hub to use it.');
      expect(find.byKey(const ValueKey('waste-log')), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('with the hub away it says so, and reads again when asked', (tester) async {
      final t = await pumpWaste(
        tester,
        hub: (hub) {
          night(hub);
          hub.down = true;
        },
      );
      expect(words(tester, 'waste-error'), 'The hub is not answering. The waste log is kept on the hub.');
      t.hub.down = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Chicken wings'), findsOneWidget);
    });
  });

  group('writing an entry', () {
    testWidgets('a dish is found by typing, as on the order screen, and goes to the hub by its size', (tester) async {
      final t = await pumpWaste(tester);
      await tapKey(tester, 'waste-log');
      expect(find.byType(WasteDialog), findsOneWidget);
      // nothing to write yet
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('waste-save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'general');
      await tester.pumpAndSettle();
      // one row a size, each with the menu's price
      expect(find.byKey(const ValueKey('waste-dish:GTC:pint')), findsOneWidget);
      expect(find.text('\$24.95'), findsOneWidget);
      await tapKey(tester, 'waste-dish:GTC:quart');
      expect(words(tester, 'waste-picked'), "General Tso's Chicken (Quart)");
      expect(find.byKey(const ValueKey('waste-what')), findsNothing);
      await tapKey(tester, 'waste-more');
      await tapKey(tester, 'waste-more');
      await tapKey(tester, 'waste-fewer');
      // still no reason: every entry says why
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('waste-save'))).onPressed, isNull);
      await tapKey(tester, 'waste-reason:Burnt');
      await tester.enterText(find.byKey(const ValueKey('waste-note')), 'left on the wok');
      await tapKey(tester, 'waste-save');
      expect(find.byType(WasteDialog), findsNothing);
      expect(t.hub.wasteWritten.single, {
        'staff_id': 's1',
        'variant_id': 'GTC:quart',
        'entry_id': 'dinner:87',
        'name': "General Tso's Chicken (Quart)",
        'qty': 2,
        'reason': 'Burnt',
        'note': 'left on the wok',
        'device': 't1',
      });
      // the list has it at once, and says so
      expect(find.text("Written down: 2 × General Tso's Chicken (Quart)"), findsOneWidget);
      expect(words(tester, 'waste-today'), '2 wasted · \$49.90 at menu prices');
      expect(find.text('left on the wok'), findsOneWidget);
    });

    testWidgets('another dish can be picked instead', (tester) async {
      await pumpWaste(tester);
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'egg roll');
      await tester.pumpAndSettle();
      await tapKey(tester, 'waste-dish:EGGROLL:regular');
      expect(words(tester, 'waste-picked'), 'Egg roll'); // one size: the name alone
      await tapKey(tester, 'waste-unpick');
      expect(find.byKey(const ValueKey('waste-picked')), findsNothing);
      expect(find.byKey(const ValueKey('waste-dish:EGGROLL:regular')), findsOneWidget); // what was typed is still there
    });

    testWidgets('something that is not a dish is written as typed, with no price', (tester) async {
      final t = await pumpWaste(tester);
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'Tray of white rice');
      await tester.pumpAndSettle();
      expect(words(tester, 'waste-typed'), 'Not a dish of the menu: it is written as typed, with no price.');
      await tester.enterText(find.byKey(const ValueKey('waste-qty')), '3');
      await tester.pumpAndSettle();
      await tapKey(tester, 'waste-reason:Expired');
      await tapKey(tester, 'waste-save');
      final sent = t.hub.wasteWritten.single;
      expect((sent['name'], sent['qty'], sent['reason']), ('Tray of white rice', 3, 'Expired'));
      expect(sent.containsKey('variant_id'), isFalse);
      expect(words(tester, 'waste-today'), '3 wasted · no price');
    });

    testWidgets('how many is a whole number from 1 up', (tester) async {
      await pumpWaste(tester);
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'Rice');
      await tapKey(tester, 'waste-reason:Dropped');
      FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('waste-save')));
      expect(save().onPressed, isNotNull);
      // one is the fewest
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('waste-fewer'))).onPressed, isNull);
      for (final bad in ['', '0']) {
        await tester.enterText(find.byKey(const ValueKey('waste-qty')), bad);
        await tester.pumpAndSettle();
        expect(save().onPressed, isNull, reason: 'how many: "$bad"');
      }
      await tester.enterText(find.byKey(const ValueKey('waste-qty')), '999');
      await tester.pumpAndSettle();
      expect(save().onPressed, isNotNull);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('waste-more'))).onPressed, isNull);
    });

    testWidgets('the reasons are the ones the location lists', (tester) async {
      await pumpWaste(tester, hub: (hub) => hub.wasteReasons = ['Dropped', 'Fell off the pass']);
      await tapKey(tester, 'waste-log');
      expect(find.byKey(const ValueKey('waste-reason:Fell off the pass')), findsOneWidget);
      expect(find.byKey(const ValueKey('waste-reason:Burnt')), findsNothing);
    });

    testWidgets('a person who reads Chinese finds the dish under its Chinese name', (tester) async {
      final t = await pumpWaste(tester, chinese: true);
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), '蛋卷');
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('waste-dish:EGGROLL:regular'));
      // the name they read first, the other after it
      final names = [
        for (final text in tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))) text.data,
      ];
      expect(names.take(2), ['蛋卷', 'Egg roll']);
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tapKey(tester, 'waste-reason:Dropped');
      await tapKey(tester, 'waste-save');
      // the hub is told the dish; it names it itself
      expect(t.hub.wasteWritten.single['variant_id'], 'EGGROLL:regular');
      expect(find.text('Egg roll'), findsOneWidget);
    });

    testWidgets('what the hub refuses is said, and the entry is still there to send', (tester) async {
      final t = await pumpWaste(tester);
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'Rice');
      await tapKey(tester, 'waste-reason:Dropped');
      t.hub.refuseWaste = 'Pick a reason from the list.';
      await tapKey(tester, 'waste-save');
      expect(words(tester, 'waste-problem'), 'Pick a reason from the list.');
      expect(find.byType(WasteDialog), findsOneWidget);
      // the hub away: nothing was written, and it says so
      t.hub
        ..refuseWaste = null
        ..down = true;
      await tapKey(tester, 'waste-save');
      expect(words(tester, 'waste-problem'), 'The hub is not answering, so this was not written down. Try again.');
      t.hub.down = false;
      await tapKey(tester, 'waste-save');
      expect(find.byType(WasteDialog), findsNothing);
      expect(find.text('Rice'), findsOneWidget);
    });

    testWidgets('the dialog fits a 320-wide phone with large text', (tester) async {
      await pumpWaste(tester, size: const Size(320, 568), textScale: 1.3);
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'general');
      await tester.pumpAndSettle();
      await tapKey(tester, 'waste-dish:GTC:quart');
      await tapKey(tester, 'waste-reason:Staff meal');
      expect(tester.takeException(), isNull);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('waste-save'))).onPressed, isNotNull);
    });
  });

  group('striking out', () {
    testWidgets('whoever wrote an entry strikes it out, and it stays, counted nowhere', (tester) async {
      final t = await pumpWaste(tester, hub: night);
      // Amy wrote the quarts and the wings; the rice is Ben's
      expect(find.byKey(const ValueKey('waste-strike:w3')), findsOneWidget);
      expect(find.byKey(const ValueKey('waste-strike:w1')), findsOneWidget);
      expect(find.byKey(const ValueKey('waste-strike:w2')), findsNothing);
      await tapKey(tester, 'waste-strike:w3');
      expect(find.text('Strike this out?'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(t.hub.wasteStruck, isEmpty);
      await tapKey(tester, 'waste-strike:w3');
      await tapKey(tester, 'waste-strike-yes');
      expect(t.hub.wasteStruck.single, ('w3', 's1', null));
      // still read, struck through, with who struck it; the total is without it
      expect(find.text("General Tso's Chicken (Quart)"), findsOneWidget);
      expect(words(tester, 'waste-struck:w3'), startsWith('Struck out by Amy, '));
      expect(find.byKey(const ValueKey('waste-strike:w3')), findsNothing);
      expect(words(tester, 'waste-today'), '2 wasted · \$8.95 at menu prices · 1 with no price');
    });

    testWidgets('what the hub refuses is said and nothing is struck', (tester) async {
      final t = await pumpWaste(tester, hub: night);
      t.hub.refuseWasteStrike = 'Ben wrote this one. They or a manager take it out.';
      await tapKey(tester, 'waste-strike:w1');
      await tapKey(tester, 'waste-strike-yes');
      expect(find.text('Ben wrote this one. They or a manager take it out.'), findsOneWidget);
      expect(find.byKey(const ValueKey('waste-struck:w1')), findsNothing);
    });

    testWidgets('a manager strikes anybody\'s entry, with their token', (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin', hub: night);
      // it opens on the totals: go to today's entries
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('waste-strike:w2')), findsOneWidget);
      await tapKey(tester, 'waste-strike:w2');
      await tapKey(tester, 'waste-strike-yes');
      expect(t.hub.wasteStruck.single, ('w2', 's3', 'Bearer tok-admin'));
      expect(words(tester, 'waste-struck:w2'), startsWith('Struck out by Mike, '));
    });
  });

  group('earlier days, for a manager', () {
    void sunday(Hub hub) {
      night(hub);
      hub.wasteDays['2026-11-15'] = [
        hub.wasteEntry(
          'y2',
          'Egg roll',
          99,
          'Dropped',
          each: '3.50',
          variantId: 'EGGROLL:regular',
          by: 'Wei',
          byId: 's5',
        ),
        hub.wasteEntry('y1', 'Chicken wings', 1, 'Burnt', each: '8.95', variantId: 'WINGS:6pc'),
      ];
    }

    testWidgets('the day before is read, and a mistake of it is struck out', (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin', hub: sunday);
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      expect(words(tester, 'waste-day'), 'Today');
      // today is the last day there is
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('waste-day-next'))).onPressed, isNull);
      await tapKey(tester, 'waste-day-back');
      expect(t.hub.wasteDayAsks.last, '2026-11-15');
      expect(words(tester, 'waste-day'), 'Sun, Nov 15');
      expect(words(tester, 'waste-today'), '100 wasted · \$355.45 at menu prices');
      // an entry is written into the day that is running, not into this one
      expect(find.byKey(const ValueKey('waste-log')), findsNothing);
      await tapKey(tester, 'waste-strike:y2');
      await tapKey(tester, 'waste-strike-yes');
      expect(t.hub.wasteStruck.single, ('y2', 's3', 'Bearer tok-admin'));
      expect(words(tester, 'waste-day'), 'Sun, Nov 15'); // still that day
      expect(words(tester, 'waste-today'), '1 wasted · \$8.95 at menu prices');
      // a day with nothing says so
      await tapKey(tester, 'waste-day-back');
      expect(words(tester, 'waste-day'), 'Sat, Nov 14');
      expect(words(tester, 'waste-empty'), 'Nothing was written down that day.');
      // and back to today, where an entry is written
      await tapKey(tester, 'waste-day-next');
      await tapKey(tester, 'waste-day-next');
      expect(t.hub.wasteDayAsks.last, isNull);
      expect(words(tester, 'waste-day'), 'Today');
      expect(find.byKey(const ValueKey('waste-log')), findsOneWidget);
    });

    testWidgets('a day of the totals opens its entries', (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin', hub: sunday);
      expect(find.text('A tap on a day opens its entries.'), findsOneWidget);
      await tapKey(tester, 'waste-day:2026-11-09');
      expect(t.hub.wasteDayAsks.last, '2026-11-09');
      expect(words(tester, 'waste-day'), 'Mon, Nov 9');
      expect(words(tester, 'waste-empty'), 'Nothing was written down that day.');
    });

    testWidgets('with the hub away a day says so, and is asked again', (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin', hub: sunday);
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      t.hub.down = true;
      await tapKey(tester, 'waste-day-back');
      expect(words(tester, 'waste-error'), 'The hub is not answering. The waste log is kept on the hub.');
      t.hub.down = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(words(tester, 'waste-day'), 'Sun, Nov 15');
    });
  });

  group('the totals', () {
    testWidgets('a manager reads the days added up by reason, by dish and by day', (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin', hub: night);
      // it opens on the totals of the seven days just gone
      expect(t.hub.wasteAuth, 'Bearer tok-admin');
      expect(t.hub.wasteAsks.single, {'from': '2026-11-09', 'to': '2026-11-15'});
      expect(words(tester, 'waste-total'), '4 wasted · \$58.85 at menu prices · 1 with no price');
      expect(words(tester, 'waste-about'), contains("The menu's prices, not what the food cost."));
      Finder inside(String part, String text) =>
          find.descendant(of: find.byKey(ValueKey('waste-by-$part')), matching: find.text(text));
      expect(inside('reason', 'Burnt'), findsOneWidget);
      expect(inside('reason', '\$49.90'), findsOneWidget);
      expect(inside('reason', 'no price'), findsOneWidget); // the tray of rice
      expect(inside('dish', "General Tso's Chicken (Quart)"), findsOneWidget);
      expect(inside('dish', '2×'), findsOneWidget);
      expect(inside('day', 'nothing'), findsOneWidget); // a day with nothing is still a line
      // other days are asked as the sales are
      await tapKey(tester, 'waste:today');
      expect(t.hub.wasteAsks.last, isEmpty);
      await tapKey(tester, 'waste:four-weeks');
      expect(t.hub.wasteAsks.last, {'from': '2026-10-19', 'to': '2026-11-15'});
    });

    testWidgets('struck entries are numbered and counted nowhere', (tester) async {
      await pumpWaste(
        tester,
        staffId: 's3',
        token: 'tok-admin',
        hub: (hub) {
          night(hub);
          hub.waste![0]
            ..['struck_ms'] = hub.clockNow
            ..['struck_by'] = 'Amy';
        },
      );
      expect(words(tester, 'waste-total'), '2 wasted · \$8.95 at menu prices · 1 with no price');
      expect(words(tester, 'waste-about'), endsWith('1 struck out, not counted.'));
    });

    testWidgets('days with nothing wasted say so and list nothing', (tester) async {
      await pumpWaste(tester, staffId: 's3', token: 'tok-admin');
      expect(words(tester, 'waste-total'), 'Nothing wasted');
      expect(find.byKey(const ValueKey('waste-by-reason')), findsNothing);
    });

    testWidgets('an entry written in the log is in the totals at once', (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin');
      // nothing stands over the numbers of the totals: an entry is written from the log
      expect(find.byKey(const ValueKey('waste-log')), findsNothing);
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'waste-log');
      await tester.enterText(find.byKey(const ValueKey('waste-what')), 'wings');
      await tester.pumpAndSettle();
      await tapKey(tester, 'waste-dish:WINGS:6pc');
      await tapKey(tester, 'waste-reason:Dropped');
      await tapKey(tester, 'waste-save');
      expect(t.hub.wasteWritten.single['staff_id'], 's3');
      await tester.tap(find.text('Totals'));
      await tester.pumpAndSettle();
      expect(words(tester, 'waste-total'), '1 wasted · \$8.95 at menu prices');
    });

    testWidgets("when the manager's hour is over it says how to come back", (tester) async {
      final t = await pumpWaste(tester, staffId: 's3', token: 'tok-admin', hub: (hub) => hub.refuseWasteReport = 401);
      expect(words(tester, 'waste-error'), "The manager's hour here is over: go back and open Location again.");
      // today's log is still read and written: it asks for no manager
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      expect(words(tester, 'waste-today'), 'Nothing wasted');
      t.hub.refuseWasteReport = null;
      await tester.tap(find.text('Totals'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(words(tester, 'waste-total'), 'Nothing wasted');
    });

    testWidgets('the totals fit a 320-wide phone with large text', (tester) async {
      await pumpWaste(
        tester,
        staffId: 's3',
        token: 'tok-admin',
        size: const Size(320, 568),
        textScale: 1.3,
        hub: night,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('waste-totals')), findsOneWidget);
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text("General Tso's Chicken (Quart)"), findsOneWidget);
    });
  });

  group('from the orders screen and from Location', () {
    testWidgets('anybody signed in opens Waste from the orders screen', (tester) async {
      final t = await pumpOrders(tester, [], role: 'server');
      t.hub.waste = [t.hub.wasteEntry('w1', 'Chicken wings', 1, 'Dropped', each: '8.95', byId: 's3', by: 'Mike')];
      await openHome(tester, 'waste');
      await tester.pumpAndSettle();
      expect(find.byType(WasteScreen), findsOneWidget);
      expect(find.text('Chicken wings'), findsOneWidget);
      // theirs to strike: the terminal is signed in as s3
      expect(find.byKey(const ValueKey('waste-strike:w1')), findsOneWidget);
      expect(find.byKey(const ValueKey('waste-view')), findsNothing);
      await stop(tester);
    });

    Future<Terminal> pumpLocation(WidgetTester tester, {bool older = false}) async {
      final t = await terminal(tester);
      if (older) t.hub.waste = null;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', staffId: 's3', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('a manager opens the totals from Location', (tester) async {
      final t = await pumpLocation(tester);
      night(t.hub);
      await bringUp(tester, 'waste-report');
      await tapKey(tester, 'waste-report');
      expect(find.byType(WasteScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('waste-totals')), findsOneWidget);
      expect(t.hub.wasteAuth, 'Bearer tok-admin');
    });

    testWidgets('a manager keeps the list of reasons under Location', (tester) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'waste-reasons');
      String row() => tester
          .widget<Text>(
            find.descendant(of: find.byKey(const ValueKey('waste-reasons')), matching: find.textContaining('Why food')),
          )
          .data!;
      expect(row(), 'Why food is written into the waste log: Dropped, Burnt, Made wrong, Expired, Spoiled, Staff meal');
      await tapKey(tester, 'waste-reasons');
      expect(find.byType(WasteReasonsDialog), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('waste-reason-words:2')), 'Wrong  dish made ');
      await tapKey(tester, 'waste-reason-remove:5');
      await tapKey(tester, 'waste-reason-add');
      await tester.enterText(find.byKey(const ValueKey('waste-reason-words:6')), 'Fell off the pass');
      await tapKey(tester, 'waste-reasons-save');
      expect(find.byType(WasteReasonsDialog), findsNothing);
      expect(t.hub.wasteReasons, ['Dropped', 'Burnt', 'Wrong dish made', 'Expired', 'Spoiled', 'Fell off the pass']);
      expect(t.hub.wasteReasonsAuth, 'Bearer tok-admin');
      expect(find.text('Waste reasons saved'), findsOneWidget);
      expect(row(), endsWith('Spoiled, Fell off the pass'));
    });

    testWidgets('the list needs a reason, each with words, none twice', (tester) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'waste-reasons');
      await tapKey(tester, 'waste-reasons');
      await tester.enterText(find.byKey(const ValueKey('waste-reason-words:1')), 'dropped');
      await tapKey(tester, 'waste-reasons-save');
      expect(words(tester, 'waste-reasons-problem'), 'Two reasons say the same');
      await tester.enterText(find.byKey(const ValueKey('waste-reason-words:1')), ' ');
      await tapKey(tester, 'waste-reasons-save');
      expect(words(tester, 'waste-reasons-problem'), 'Every reason needs its words');
      for (var row = 0; row < 6; row++) {
        await tapKey(tester, 'waste-reason-remove:$row');
      }
      await tapKey(tester, 'waste-reasons-save');
      expect(words(tester, 'waste-reasons-problem'), 'The log needs at least one reason to pick from');
      expect(t.hub.wasteReasonsAuth, isNull); // nothing went to the hub
      // and what the hub refuses is said
      await tapKey(tester, 'waste-reason-add');
      await tester.enterText(find.byKey(const ValueKey('waste-reason-words:6')), 'Dropped');
      t.hub.refuseWasteReasons = 'a reason is at most 24 characters';
      await tapKey(tester, 'waste-reasons-save');
      expect(words(tester, 'waste-reasons-problem'), 'a reason is at most 24 characters');
    });

    testWidgets('a hub older than the log: the row says so and opens nothing', (tester) async {
      await pumpLocation(tester, older: true);
      await bringUp(tester, 'waste-reasons');
      expect(
        find.descendant(of: find.byKey(const ValueKey('waste-reasons')), matching: find.textContaining('an older hub')),
        findsOneWidget,
      );
      await tapKey(tester, 'waste-reasons');
      expect(find.byType(WasteReasonsDialog), findsNothing);
    });
  });
}
