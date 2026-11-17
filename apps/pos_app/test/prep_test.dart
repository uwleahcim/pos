import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/prep_list.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

import 'catering_test.dart' show chen, deposit, platters, pumpOrder, said, tapKey, week;
import 'hub.dart';
import 'ticket_words_test.dart' show show;

/// The prep list and the pack sheet (docs/catering.md): a day's orders ahead added up dish by dish for each
/// station, and the paper a catering order is packed by. The hub reckons the list and prints both
/// (backend/tests/orders/test_prep.py, backend/tests/printing/test_pack.py); these tests are about what the
/// screens ask, say and send.

int _at(int hour) => DateTime(2026, 11, 21, hour).millisecondsSinceEpoch;

/// Saturday the 21st as the hub adds it up: Chen's catering at noon, Park's at six, and Ann's phone order
/// at noon, which nobody sent yet.
Map<String, dynamic> saturday() => {
  'day': '2026-11-21',
  'today': '2026-11-16',
  'count': 3,
  'guests': 38,
  'dishes': 17,
  'unsent': 2,
  'orders': [
    {
      'order_id': 'c1',
      'order_no': 12,
      'customer_name': 'Chen',
      'channel': 'catering',
      'promised_ms': _at(12),
      'guests': 30,
      'handover': 'delivery',
      'dishes': 11,
      'unsent': 0,
    },
    {
      'order_id': 'p9',
      'order_no': 14,
      'customer_name': 'Ann',
      'channel': 'phone',
      'promised_ms': _at(12),
      'guests': null,
      'handover': null,
      'dishes': 2,
      'unsent': 2,
    },
    {
      'order_id': 'c2',
      'order_no': 13,
      'customer_name': 'Park',
      'channel': 'catering',
      'promised_ms': _at(18),
      'guests': 8,
      'handover': 'pickup',
      'dishes': 4,
      'unsent': 0,
    },
  ],
  'stations': [
    {
      'station': 'wok',
      'name': 'Wok',
      'rows': [
        {
          'label': "General Tso's Chicken (Qt)",
          'header': '',
          'qty': 10,
          'first_ms': _at(12),
          'ways': [
            {
              'qty': 3,
              'choices': ['Extra spicy', 'Brown rice'],
              'depths': [0, 0],
              'note': '',
            },
            {'qty': 1, 'choices': <String>[], 'depths': <int>[], 'note': 'no onions'},
          ],
        },
        {'label': 'Pork Fried Rice (Qt)', 'header': '', 'qty': 2, 'first_ms': _at(18), 'ways': <dynamic>[]},
      ],
    },
    {
      'station': 'fryer',
      'name': 'Fryer',
      'rows': [
        {'label': 'Egg roll', 'header': '4 Pu Pu Platter', 'qty': 3, 'first_ms': _at(12), 'ways': <dynamic>[]},
        {'label': 'Pu Pu Platter', 'header': '', 'qty': 3, 'first_ms': _at(12), 'ways': <dynamic>[]},
      ],
    },
    {
      'station': 'bar',
      'name': 'Bar',
      'rows': [
        {'label': 'Tsingtao', 'header': '', 'qty': 2, 'first_ms': _at(12), 'ways': <dynamic>[]},
      ],
    },
  ],
};

void main() {
  group('the words', () {
    test('a day is read as the hub added it up', () {
      final list = PrepList.fromJson(saturday());
      expect(list.day, '2026-11-21');
      expect(list.summed, '3 orders · 38 guests · 17 dishes');
      expect(list.unsentWords, '2 dishes are not sent to the kitchen yet. They are counted here.');
      expect(list.manyTimes, isTrue); // noon and six: each dish says by when its first
      expect(
        [for (final order in list.orders) order.words],
        ['Chen · 30 guests · delivery', 'Ann', 'Park · 8 guests · pickup'],
      );
      final chicken = list.stations.first.rows.first;
      expect((chicken.qty, chicken.label), (10, "General Tso's Chicken (Qt)"));
      expect([for (final way in chicken.ways) '${way.qty} ${way.words}'], ['3 Extra spicy, Brown rice', '1 no onions']);
      expect(list.stations[1].rows.first.header, '4 Pu Pu Platter');
    });

    test('one order, one dish, and nothing said that is not there', () {
      final list = PrepList.fromJson({
        'day': '2026-11-22',
        'guests': 0,
        'dishes': 1,
        'unsent': 1,
        'orders': [
          {'order_id': 'p1', 'promised_ms': _at(12), 'dishes': 1, 'unsent': 1},
        ],
      });
      expect(list.summed, '1 order · 1 dish');
      expect(list.unsentWords, '1 dish is not sent to the kitchen yet. It is counted here.');
      expect(list.manyTimes, isFalse);
      expect(list.orders.single.words, 'To go');
      expect(PrepList.fromJson(const {}).stations, isEmpty);
    });

    test('the switch for the pack sheet is kept and said back only when the hub has it', () {
      final older = TicketWords.fromJson(const {'numbered': true, 'also_at': true, 'paid': true, 'moved': true});
      expect(older.pack, isNull);
      expect(older.toJson().containsKey('pack'), isFalse);
      final newer = TicketWords.fromJson(const {
        'numbered': true,
        'also_at': true,
        'paid': true,
        'moved': true,
        'pack': true,
      });
      expect(newer.copyWith(pack: false).toJson()['pack'], isFalse);
      expect(newer.copyWith(paid: false).pack, isTrue);
      expect(newer == older, isFalse);
    });
  });

  group('the prep list of a day', () {
    Future<Terminal> pumpAhead(WidgetTester tester, {Size? size}) async {
      final t = await terminal(tester);
      t.hub.ahead = week();
      t.hub.prep = {'2026-11-21': saturday()};
      t.hub.check = platters(paid: '20.00');
      t.hub.orders.add(chen(sent: true, payments: deposit, due: '45.01'));
      if (size != null) tester.view.physicalSize = size;
      await pumpOrdersOn(tester, t);
      return t;
    }

    Future<void> open(WidgetTester tester, String day) async {
      await tester.tap(find.byTooltip('Orders ahead'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'ahead-prep:$day');
    }

    testWidgets('each day of Orders ahead opens its prep list, the dishes added up by station', (tester) async {
      final t = await pumpAhead(tester);
      await open(tester, '2026-11-21');
      expect(t.hub.requests, contains('GET /orders/ahead/prep?day=2026-11-21'));
      expect(find.text('Sat 21 Nov · Prep list'), findsOneWidget);
      expect(said(tester, 'prep-summed'), '3 orders · 38 guests · 17 dishes');
      expect(said(tester, 'prep-unsent'), '2 dishes are not sent to the kitchen yet. They are counted here.');

      Finder inOrder(String id, String text) =>
          find.descendant(of: find.byKey(ValueKey('prep-order:$id')), matching: find.text(text));
      expect(inOrder('c1', '12:00'), findsOneWidget);
      expect(inOrder('c1', 'Chen · 30 guests · delivery'), findsOneWidget);
      expect(inOrder('c1', '11 dishes'), findsOneWidget);
      expect(inOrder('c2', '18:00'), findsOneWidget);

      // the stations in the hub's order, each with its dishes
      final stations = ['wok', 'fryer', 'bar'].map((code) => said(tester, 'prep-station:$code'));
      expect(stations, ['Wok', 'Fryer', 'Bar']);
      expect(find.text("General Tso's Chicken (Qt)"), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('3 × Extra spicy, Brown rice'), findsOneWidget);
      expect(find.text('1 × no onions'), findsOneWidget);
      expect(find.text('with 4 Pu Pu Platter'), findsOneWidget);
      // the day has two times: a dish says by when its first
      expect(find.text('by 12:00'), findsNWidgets(4));
      expect(find.text('by 18:00'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Print sends the list to paper and says where', (tester) async {
      final t = await pumpAhead(tester);
      await open(tester, '2026-11-21');
      await tapKey(tester, 'prep-print');
      expect(t.hub.prepPrints, [('2026-11-21', null)]);
      expect(said(tester, 'prep-printed'), 'The prep list is printing at Takeout');
      // a screen that keeps a printer of its own for its bills prints there
      await t.settings.saveBillPrinter('kitchen');
      await tapKey(tester, 'prep-print');
      expect(t.hub.prepPrints.last, ('2026-11-21', 'kitchen'));
      // and what the hub says when it cannot
      t.hub.refusePrep = 'No printer is set up for this location.';
      await tapKey(tester, 'prep-print');
      expect(said(tester, 'prep-printed'), 'No printer is set up for this location.');
      await stop(tester);
    });

    testWidgets('a day with one time says it once, and a day with no dish says so', (tester) async {
      final t = await pumpAhead(tester);
      final oneTime = saturday();
      for (final order in oneTime['orders'] as List) {
        (order as Map<String, dynamic>)['promised_ms'] = _at(12);
      }
      t.hub.prep = {'2026-11-21': oneTime};
      await open(tester, '2026-11-21');
      expect(find.textContaining('by 1'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      // tonight's order has its day on the list, and the hub has no dish for it
      await tapKey(tester, 'ahead-prep:2026-11-16');
      expect(find.text('Today · Prep list'), findsOneWidget);
      expect(find.byKey(const ValueKey('prep-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('prep-print')), findsNothing);
      await stop(tester);
    });

    testWidgets('a hub older than the list says to update it, and a hub away keeps its last picture', (tester) async {
      final t = await pumpAhead(tester);
      t.hub.prep = null;
      await open(tester, '2026-11-21');
      expect(find.text('This hub does not make prep lists yet. Update the hub.'), findsOneWidget);
      expect(find.byKey(const ValueKey('prep-print')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();

      t.hub.prep = {'2026-11-21': saturday()};
      await tapKey(tester, 'ahead-prep:2026-11-21');
      expect(find.text('Tsingtao'), findsOneWidget);
      t.hub.down = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('prep-away')), findsOneWidget);
      expect(find.text('Tsingtao'), findsOneWidget);
      await tapKey(tester, 'prep-print');
      expect(said(tester, 'prep-printed'), 'The hub is not answering: nothing was printed');
      await stop(tester);
    });

    testWidgets('the list and the way to it fit a small phone with large type', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpAhead(tester, size: const Size(320, 568));
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Orders ahead'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('ahead-prep:2026-11-21')), 200);
      await tapKey(tester, 'ahead-prep:2026-11-21');
      expect(find.byKey(const ValueKey('prep-list')), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Tsingtao'), 200, scrollable: find.byType(Scrollable).last);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the pack sheet', () {
    testWidgets('the line that says what the order is for prints its pack sheet', (tester) async {
      final t = await pumpOrder(tester, chen(sent: true, payments: deposit), paid: '20.00');
      expect(find.byTooltip('Print the pack sheet'), findsOneWidget);
      await tapKey(tester, 'pack-sheet');
      expect(t.hub.packSheets, ['c1']);
      expect(find.text('The pack sheet is printing at Takeout'), findsOneWidget);
      // the order is not touched: nothing was sent for it
      expect(t.hub.sent, isEmpty);
      await stop(tester);
    });

    testWidgets('a closed order still prints one; an order with no dish has nothing to pack', (tester) async {
      final t = await pumpOrder(tester, chen(sent: true, status: 'closed'));
      await tapKey(tester, 'pack-sheet');
      expect(t.hub.packSheets, ['c1']);
      await stop(tester);

      final empty = chen(id: 'c2')..['lines'] = <String, dynamic>{};
      final t2 = await pumpOrder(tester, empty);
      await tester.tap(find.byKey(const ValueKey('pack-sheet')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(t2.hub.packSheets, isEmpty);
      await stop(tester);
    });

    testWidgets('what the hub says when it cannot, and a hub older than pack sheets', (tester) async {
      final t = await pumpOrder(tester, chen(sent: true));
      t.hub.refusePack = 'No printer is set up for this location.';
      await tapKey(tester, 'pack-sheet');
      expect(find.text('No printer is set up for this location.'), findsOneWidget);
      expect(t.hub.packSheets, isEmpty);
      t.hub.packSheets = null;
      ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('pack-sheet')))).clearSnackBars();
      await tester.pumpAndSettle();
      await tapKey(tester, 'pack-sheet');
      expect(find.text('This hub does not print pack sheets yet: update it'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('an order for now has no such line, and so no button', (tester) async {
      final now = chen(sent: true, channel: 'phone');
      (now['fields'] as Map<String, dynamic>)
        ..remove('for_later')
        ..remove('promised_at');
      await pumpOrder(tester, now);
      expect(find.byKey(const ValueKey('when-strip')), findsNothing);
      expect(find.byKey(const ValueKey('pack-sheet')), findsNothing);
      await stop(tester);
    });

    testWidgets('the button fits the line on a small phone with large type', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final t = await pumpOrder(tester, chen(sent: true), size: const Size(320, 568));
      expect(find.byKey(const ValueKey('pack-sheet')), findsOneWidget);
      await tapKey(tester, 'pack-sheet');
      expect(t.hub.packSheets, ['c1']);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group("the location's switch", () {
    Future<Terminal> pumpSettings(WidgetTester tester, Map<String, dynamic> words) async {
      final t = await terminal(tester);
      t.hub.ticketWords = words;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('a manager turns the pack sheet with a catering order off', (tester) async {
      final t = await pumpSettings(tester, {
        'numbered': true,
        'also_at': true,
        'paid': true,
        'moved': true,
        'pack': true,
      });
      final pack = find.byKey(const ValueKey('tickets-pack'));
      await show(tester, pack);
      expect(tester.widget<SwitchListTile>(pack).value, isTrue);
      expect(find.text('Print a pack sheet with a catering order'), findsOneWidget);
      await tester.tap(pack);
      await tester.pumpAndSettle();
      expect(t.hub.ticketWords, {'numbered': true, 'also_at': true, 'paid': true, 'moved': true, 'pack': false});
      expect(tester.widget<SwitchListTile>(pack).value, isFalse);
      await stop(tester);
    });

    testWidgets('a hub that prints no pack sheet shows no switch for it', (tester) async {
      await pumpSettings(tester, {'numbered': true, 'also_at': true, 'paid': true, 'moved': true});
      await show(tester, find.byKey(const ValueKey('tickets-moved')));
      expect(find.byKey(const ValueKey('tickets-pack')), findsNothing);
      await stop(tester);
    });
  });
}
