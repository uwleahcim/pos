import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/adjustments_screen.dart';
import 'package:pos_app/screens/check_history_screen.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';

import 'day_report_test.dart' show evening, pumpDay, tapKey;
import 'hub.dart';

/// A check's history (docs/check-history.md): every step the hub keeps of one check, for a manager. The hub
/// works the steps out; these tests are about the screen saying them, the ways in, and every step from this
/// build on naming who took it.

/// Monday 16 November 2026, on the device's own clock.
int ms(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute).millisecondsSinceEpoch;

/// A picture a screen can draw: one pixel.
final picture = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Map<String, dynamic> step(
  String what,
  int atMs, {
  String by = 'Amy',
  String? byId = 's1',
  String device = 'mac1',
  String approvedBy = '',
  bool offline = false,
  String? photo,
  Map<String, dynamic> said = const {},
}) => {
  'op_id': 'op-$what-$atMs',
  'at_ms': atMs,
  'device': device,
  'by': by,
  'by_id': byId,
  'approved_by': approvedBy,
  'offline': offline,
  'photo': photo,
  'what': what,
  ...said,
};

HistoryStep read(String what, [Map<String, dynamic> said = const {}]) =>
    HistoryStep.fromJson(step(what, 0, said: said));

/// The words of a step, its title first and then each line under it, with a time written as its hour.
List<String> words(String what, [Map<String, dynamic> said = const {}]) {
  final words = wordsOf(read(what, said), time: (ms) => 'at ${DateTime.fromMillisecondsSinceEpoch(ms).hour}');
  return [words.title, ...words.under];
}

/// The dinner the hub's own tests ring (backend/tests/orders/test_history.py): table 12, opened by Amy.
Map<String, dynamic> dinner() => {
  'order': {
    'order_id': 'o1',
    'status': 'closed',
    'table': '14',
    'order_no': null,
    'customer_name': '',
    'order_type': 'dine_in',
    'server': 'Ben',
    'guests': 2,
    'opened_ms': ms(18, 2),
    'merged_into': null,
  },
  'steps': [
    step(
      'opened',
      ms(18, 2),
      said: {
        'fields': {'table': '12', 'guests': 2, 'order_type': 'dine_in', 'server': 'Amy'},
      },
    ),
    step(
      'added',
      ms(18, 4),
      said: {
        'line_id': 'L1',
        'dish': 'Chicken wings',
        'options': ['Extra spicy'],
        'qty': 1,
        'seat': 1,
        'course': 'Appetizers',
        'note': '',
        'unit_price': '8.95',
        'changed': false,
      },
    ),
    step(
      'added',
      ms(18, 4),
      said: {
        'line_id': 'L2',
        'dish': 'Egg roll',
        'options': <String>[],
        'qty': 2,
        'seat': null,
        'course': 'Appetizers',
        'note': 'no sauce',
        'unit_price': '2.25',
        'changed': false,
      },
    ),
    step(
      'sent',
      ms(18, 5),
      photo: 'ph-sent',
      said: {
        'course': null,
        'dishes': [
          {'dish': 'Chicken wings', 'qty': 1},
          {'dish': 'Egg roll', 'qty': 2},
        ],
      },
    ),
    step(
      'voided',
      ms(18, 20),
      approvedBy: 'Mike',
      photo: 'ph-void',
      said: {'line_id': 'L2', 'dish': 'Egg roll', 'qty': 2, 'reason': 'Kitchen error'},
    ),
    step(
      'discount',
      ms(18, 40),
      approvedBy: 'Mike',
      photo: 'ph-gone',
      said: {'name': 'Loyalty reward', 'kind': 'amount', 'value': '2.00', 'dish': null, 'note': ''},
    ),
    step('table', ms(18, 45), by: '', byId: null, device: 'ipad1', said: {'was': '12', 'now': '14'}),
    step('server', ms(18, 46), by: 'Holly', byId: 's4', said: {'was': 'Amy', 'now': 'Ben'}),
    step(
      'paid',
      ms(19, 10),
      by: 'Ben',
      byId: 's2',
      said: {'method': 'cash', 'amount': '6.50', 'tendered': '20.00', 'check': null, 'note': ''},
    ),
    step('closed', ms(19, 11), by: 'Ben', byId: 's2'),
    step('reopened', ms(9, 30, 17), by: 'Mike', byId: 's3', offline: true),
  ],
};

Future<Terminal> pumpHistory(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? histories,
  bool older = false,
  Size size = const Size(1100, 2000),
  void Function(Hub hub)? before,
  String orderId = 'o1',
}) async {
  final t = await terminal(tester);
  t.hub.histories = older ? null : (histories ?? {'o1': dinner()});
  t.hub.eventPhotos
    ..['ph-sent'] = picture
    ..['ph-void'] = picture;
  before?.call(t.hub);
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      home: CheckHistoryScreen(api: t.api, token: 'tok-admin', orderId: orderId),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The texts inside a row of the history, top to bottom.
List<String> row(WidgetTester tester, int i) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey('history-step:$i')), matching: find.byType(Text)),
  ))
    text.data ?? '',
];

Future<Terminal> pumpOrder(WidgetTester tester, {Size size = const Size(1100, 800), String status = 'open'}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.hub.histories = {'o1': dinner()};
  t.hub.orders.add({
    ...table('o1', {'L1': line('Egg roll', fired: true)}),
    'status': status,
  });
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> typePin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byType(TextField).last, pin);
  await tester.tap(find.text('Show the history'));
  await tester.pumpAndSettle();
}

void main() {
  group('the words', () {
    test('a check opened says what it was opened with', () {
      expect(
        words('opened', {
          'fields': {'table': '12', 'guests': 2, 'order_type': 'dine_in', 'server': 'Amy'},
        }),
        ['Opened the check', 'Table 12 · 2 guests · server Amy'],
      );
      expect(
        words('opened', {
          'fields': {
            'order_no': 7,
            'order_type': 'takeout',
            'customer_name': 'Lee',
            'phone': '7815550100',
            'channel': 'phone',
            'promised_at': ms(18, 30),
            'quoted_minutes': 20,
            'note': 'ring the bell',
          },
        }),
        [
          'Opened the check',
          '#7 · To go · Lee · 7815550100 · taken by phone',
          'For at 18, quoted 20 minutes',
          'Note: ring the bell',
        ],
      );
    });

    test('a dish rung in, moved, changed, taken off and voided', () {
      expect(
        words('added', {
          'dish': 'Egg roll',
          'options': ['No cabbage', 'Extra sauce'],
          'qty': 2,
          'seat': 3,
          'course': 'Appetizers',
          'note': 'hot',
          'unit_price': '2.25',
          'changed': true,
        }),
        [
          'Rang in 2 × Egg roll',
          'No cabbage, Extra sauce',
          'seat 3 · Appetizers · \$2.25 each',
          'Note: hot',
          'In place of the one changed',
        ],
      );
      expect(words('added', {'dish': 'Beer', 'qty': 1, 'unit_price': '6.00'}), ['Rang in Beer', '\$6.00']);
      expect(
        words('moved_in', {
          'dish': 'Beer',
          'qty': 1,
          'other': 'o2',
          'other_table': '9',
          'sent': true,
          'rung_by': 'Ben',
        }),
        ['Beer came over from Table 9', 'Rung in by Ben', 'The kitchen already had it'],
      );
      expect(words('moved_out', {'dish': 'Beer', 'qty': 3, 'other': 'o2', 'other_table': null}), [
        '3 × Beer went to another check',
      ]);
      expect(
        words('changed', {
          'dish': 'Beer',
          'changes': [
            {'field': 'qty', 'was': 1, 'now': 2},
            {'field': 'seat', 'was': null, 'now': 2},
            {'field': 'course', 'was': 'Appetizers', 'now': 'Entrees'},
            {'field': 'note', 'was': '', 'now': 'cold'},
            {
              'field': 'checks',
              'was': null,
              'now': [1, 2],
            },
          ],
        }),
        [
          'Changed Beer',
          'Quantity from 1 to 2',
          'Put at seat 2',
          'Course from Appetizers to Entrees',
          'Note set to cold',
          'Now on checks 1 and 2',
        ],
      );
      expect(words('taken_off', {'dish': 'Beer', 'qty': 1}), ['Took off Beer', 'Before the kitchen was sent it']);
      expect(words('voided', {'dish': 'Egg roll', 'qty': 2, 'reason': 'Kitchen error'}), [
        'Voided 2 × Egg roll',
        'Kitchen error',
      ]);
    });

    test('what was sent, and the check closed, reopened and voided whole', () {
      expect(
        words('sent', {
          'course': null,
          'dishes': [
            {'dish': 'Chicken wings', 'qty': 1},
            {'dish': 'Egg roll', 'qty': 2},
          ],
        }),
        ['Sent to the kitchen', 'Chicken wings, 2 × Egg roll'],
      );
      expect(words('sent', {'course': 'Entrees', 'dishes': <Object>[]}), ['Sent Entrees to the kitchen']);
      expect(words('closed'), ['Closed the check']);
      expect(words('reopened'), ['Reopened the check']);
      expect(words('voided_check', {'reason': 'Walked out'}), ['Voided the whole check', 'Walked out']);
    });

    test('the table, the server, the guests and a to-go order on its way', () {
      expect(words('table', {'was': '12', 'now': '14'}), ['Moved from table 12 to table 14']);
      expect(words('table', {'was': null, 'now': '14'}), ['Put at table 14']);
      expect(words('server', {'was': 'Amy', 'now': 'Ben'}), ['Handed from Amy to Ben']);
      expect(words('server', {'was': null, 'now': 'Ben'}), ['Given to Ben']);
      expect(words('guests', {'was': 2, 'now': 4}), ['Guests changed from 2 to 4']);
      expect(words('stage', {'was': 'new', 'now': 'ready'}), ['Marked ready']);
      expect(words('stage', {'was': 'ready', 'now': 'picked_up'}), ['Marked picked up']);
      expect(words('stage', {'was': 'ready', 'now': 'new'}), ['No longer ready']);
      expect(words('promised', {'was': ms(18), 'now': ms(19)}), ['Time promised changed from at 18 to at 19']);
      expect(words('quoted', {'was': 15, 'now': 25}), ['Quoted 25 minutes', 'It was 15']);
      expect(
        words('split', {
          'was': null,
          'now': {'by': 'even', 'ways': 3},
        }),
        ['Split evenly in 3'],
      );
      expect(
        words('split', {
          'was': {'by': 'seat'},
          'now': null,
        }),
        ['Put back as one check', 'It was split by seat'],
      );
      expect(words('merged', {'other': 'o2', 'other_table': '14'}), [
        'Made one with Table 14',
        'Its dishes went to that check',
      ]);
      expect(words('field', {'field': 'customer_name', 'was': 'Lee', 'now': 'Li'}), ['Name changed from Lee to Li']);
      expect(words('field', {'field': 'phone', 'was': '', 'now': '7815550100'}), ['Phone set to 7815550100']);
      expect(words('field', {'field': 'order_type', 'was': 'dine_in', 'now': 'takeout'}), [
        'Made to go order',
        'It was a table order',
      ]);
    });

    test('comps, discounts, charges, payments and allergies', () {
      expect(
        words('discount', {
          'name': 'Manager comp',
          'kind': 'comp',
          'value': '100',
          'dish': 'Peking Duck',
          'note': 'late',
        }),
        ['Comped Peking Duck', 'Manager comp', 'Note: late'],
      );
      expect(words('discount', {'name': 'Staff meal', 'kind': 'percent', 'value': '50', 'dish': null}), [
        '50% off the whole check',
        'Staff meal',
      ]);
      expect(words('discount', {'name': 'Loyalty reward', 'kind': 'amount', 'value': '2', 'dish': null}), [
        '\$2.00 off the whole check',
        'Loyalty reward',
      ]);
      // one that came with its dish from another check was given there
      expect(
        words('discount', {'name': 'Manager comp', 'kind': 'comp', 'value': '100', 'dish': 'Beer', 'carried': true}),
        ['Comped Beer, as it came over', 'Manager comp'],
      );
      expect(words('discount_removed', {'name': 'Loyalty reward', 'dish': null}), [
        'Took the discount back off the whole check',
        'Loyalty reward',
      ]);
      expect(words('charge', {'name': 'Large party', 'kind': 'percent', 'value': '18'}), [
        'Added a charge: Large party',
        '18%',
      ]);
      expect(words('charge_removed', {'name': 'Large party'}), ['Took off the charge: Large party']);
      expect(
        words('paid', {'method': 'cash', 'amount': '6.50', 'tendered': '20.00', 'check': 2, 'note': 'tip in jar'}),
        ['Payment of \$6.50', 'Cash · \$20.00 handed over · for check 2', 'Note: tip in jar'],
      );
      expect(words('paid', {'method': 'elsewhere', 'amount': '31.00'}), ['Payment of \$31.00', 'Paid elsewhere']);
      expect(
        words('allergy', {
          'seat': 2,
          'allergens': ['Peanuts', 'Shellfish'],
          'note': 'carries a pen',
        }),
        ['Allergy at seat 2', 'Peanuts, Shellfish', 'carries a pen'],
      );
      expect(words('allergy_cleared', {'seat': null}), ['Allergy for the whole table cleared']);
    });

    test('a step this build has no words for is still shown, by its name', () {
      expect(words('tip_added', {'amount': '3.00'}), ['tip_added']);
    });

    test('who did it, where, who approved, and a step taken with no hub', () {
      expect(whoLine(HistoryStep.fromJson(step('voided', 0, approvedBy: 'Mike'))), 'Amy · mac1 · approved by Mike');
      expect(whoLine(HistoryStep.fromJson(step('table', 0, by: '', byId: null))), 'at mac1, nobody named');
      expect(
        whoLine(HistoryStep.fromJson(step('closed', 0, offline: true))),
        'Amy · mac1 · taken while the hub was not answering',
      );
    });

    test('what came off a check is told apart, and the check names itself', () {
      expect(
        [
          for (final what in ['voided', 'taken_off', 'voided_check', 'discount', 'added', 'paid']) read(what).cameOff,
        ],
        [true, true, true, true, false, false],
      );
      final history = CheckHistory.fromJson(dinner());
      expect((history.order.where, history.order.standing, history.steps.length), ('Table 14', 'Closed', 11));
      expect(history.steps[4].photo, 'ph-void');
      expect(CheckHistory.fromJson(const {}).steps, isEmpty);
    });
  });

  group('the screen', () {
    testWidgets('asks the hub with the manager\'s token, and names the check', (tester) async {
      final t = await pumpHistory(tester);
      expect(t.hub.historyAsks, ['o1']);
      expect(t.hub.historyAuth, 'Bearer tok-admin');
      expect(find.text('Table 14'), findsOneWidget);
      final time = TimeOfDay.fromDateTime(DateTime(2026, 11, 16, 18, 2)).format(tester.element(find.text('Table 14')));
      expect(find.text('Closed · server Ben · 2 guests · opened Nov 16, $time'), findsOneWidget);
      expect(find.text('11 steps, the oldest first. Nothing can be changed here.'), findsOneWidget);
    });

    testWidgets('every step: when, what, the rest of it, who and where', (tester) async {
      await pumpHistory(tester);
      String clock(int hour, int minute) =>
          TimeOfDay(hour: hour, minute: minute).format(tester.element(find.text('Table 14')));
      expect(row(tester, 0), [clock(18, 2), 'Opened the check', 'Table 12 · 2 guests · server Amy', 'Amy · mac1']);
      expect(row(tester, 1), [
        clock(18, 4),
        'Rang in Chicken wings',
        'Extra spicy',
        'seat 1 · Appetizers · \$8.95',
        'Amy · mac1',
      ]);
      expect(row(tester, 3), [clock(18, 5), 'Sent to the kitchen', 'Chicken wings, 2 × Egg roll', 'Amy · mac1']);
      expect(row(tester, 4), [clock(18, 20), 'Voided 2 × Egg roll', 'Kitchen error', 'Amy · mac1 · approved by Mike']);
      expect(row(tester, 6), [clock(18, 45), 'Moved from table 12 to table 14', 'at ipad1, nobody named']);
      expect(row(tester, 8), [clock(19, 10), 'Payment of \$6.50', 'Cash · \$20.00 handed over', 'Ben · mac1']);
    });

    testWidgets('what came off the check is in the colour of a void', (tester) async {
      await pumpHistory(tester);
      final error = Theme.of(tester.element(find.text('Table 14'))).colorScheme.error;
      expect(tester.widget<Text>(find.text('Voided 2 × Egg roll')).style?.color, error);
      expect(tester.widget<Text>(find.text('\$2.00 off the whole check')).style?.color, error);
      expect(tester.widget<Text>(find.text('Sent to the kitchen')).style?.color, isNull);
    });

    testWidgets('a new day gets its own heading', (tester) async {
      await pumpHistory(tester);
      expect(find.byKey(const ValueKey('history-day:2026-11-16')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-day:2026-11-17')), findsOneWidget);
      expect(find.text('Tuesday, November 17, 2026'), findsOneWidget);
      // the heading stands right above the step of that day
      final heading = tester.getTopLeft(find.byKey(const ValueKey('history-day:2026-11-17'))).dy;
      expect(heading, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('history-step:9'))).dy));
      expect(heading, lessThan(tester.getTopLeft(find.byKey(const ValueKey('history-step:10'))).dy));
    });

    testWidgets('the picture taken with a step is asked for once, and a tap shows it large', (tester) async {
      final t = await pumpHistory(tester);
      expect(t.hub.requests.where((r) => r.contains('/events/photos/')), [
        'GET /events/photos/ph-sent',
        'GET /events/photos/ph-void',
        'GET /events/photos/ph-gone',
      ]);
      expect(find.byKey(const ValueKey('history-photo:3')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-photo:0')), findsNothing); // no picture was taken with it
      // the hub no longer has the third: a quiet mark stands in its place
      expect(
        find.descendant(of: find.byKey(const ValueKey('history-photo:5')), matching: find.byType(Image)),
        findsNothing,
      );
      expect(find.byTooltip('The picture is no longer kept'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('history-photo:4')));
      await tester.pumpAndSettle();
      final large = find.byKey(const ValueKey('history-picture'));
      expect(large, findsOneWidget);
      expect(find.descendant(of: large, matching: find.text('Voided 2 × Egg roll')), findsOneWidget);
      expect(
        find.descendant(of: large, matching: find.textContaining('Amy · mac1 · approved by Mike')),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(large, findsNothing);
      // reading again asks for no picture twice
      await tester.tap(find.byKey(const ValueKey('history-refresh')));
      await tester.pumpAndSettle();
      expect(t.hub.historyAsks, ['o1', 'o1']);
      expect(t.hub.requests.where((r) => r.contains('/events/photos/')).length, 3);
    });

    testWidgets('a dish that went to another check opens that check\'s history', (tester) async {
      final other = {
        'order': {'order_id': 'o2', 'status': 'open', 'table': '9', 'order_type': 'dine_in'},
        'steps': [
          step(
            'moved_in',
            ms(18, 30),
            said: {'dish': 'Beer', 'qty': 1, 'other': 'o1', 'other_table': '12', 'sent': false, 'options': <String>[]},
          ),
        ],
      };
      final first = dinner();
      (first['steps'] as List).add(
        step('moved_out', ms(18, 30), said: {'dish': 'Beer', 'qty': 1, 'other': 'o2', 'other_table': '9'}),
      );
      final t = await pumpHistory(tester, histories: {'o1': first, 'o2': other});
      // a step about this check alone goes nowhere
      await tester.tap(find.text('Sent to the kitchen'));
      await tester.pumpAndSettle();
      expect(t.hub.historyAsks, ['o1']);
      await tester.tap(find.text('Beer went to Table 9'));
      await tester.pumpAndSettle();
      expect(t.hub.historyAsks, ['o1', 'o2']);
      expect(t.hub.historyAuth, 'Bearer tok-admin');
      expect(find.text('Table 9'), findsOneWidget);
      expect(find.text('Beer came over from Table 12'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Table 14'), findsOneWidget);
    });

    testWidgets('a check with nothing kept says so', (tester) async {
      await pumpHistory(
        tester,
        histories: {
          'o1': {
            'order': {
              'order_id': 'o1',
              'status': 'open',
              'order_no': 7,
              'customer_name': 'Lee',
              'order_type': 'takeout',
            },
            'steps': <Object>[],
          },
        },
      );
      expect(find.text('#7 · Lee'), findsOneWidget);
      expect(find.text('Nothing is kept of this check.'), findsOneWidget);
    });

    testWidgets('the manager\'s hour is over, the check is unknown, the hub is older, or nothing answers', (
      tester,
    ) async {
      final t = await pumpHistory(tester, before: (hub) => hub.refuseHistory = 401);
      expect(find.text("The manager's hour here is over: go back and ask for the history again."), findsOneWidget);
      // asked again once it answers
      t.hub.refuseHistory = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Table 14'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pumpHistory(tester, orderId: 'o9');
      expect(
        find.text('The hub has not heard of this check yet. If it was only just rung in, wait until it is sent.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await pumpHistory(tester, older: true);
      expect(find.text('This hub is older than the check history. Update the hub to see it here.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await pumpHistory(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
    });

    testWidgets('on a small phone every row fits', (tester) async {
      await pumpHistory(tester, size: const Size(320, 2600));
      expect(tester.takeException(), isNull);
      expect(find.text('Voided 2 × Egg roll'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-step:10')), findsOneWidget);
    });
  });

  group('the ways in', () {
    testWidgets('a check\'s History button asks for a manager, then shows the history', (tester) async {
      final t = await pumpOrder(tester);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      // a server's PIN is not enough, and nothing was read
      await typePin(tester, '1111');
      expect(find.byType(CheckHistoryScreen), findsNothing);
      expect(t.hub.historyAsks, isEmpty);
      await typePin(tester, '9999');
      expect(find.byType(CheckHistoryScreen), findsOneWidget);
      expect(t.hub.historyAsks, ['o1']);
      expect(t.hub.historyAuth, 'Bearer tok-admin');
      expect(find.text('Voided 2 × Egg roll'), findsOneWidget);
      // back on the check, as it was left
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(OrderScreen), findsOneWidget);
      expect(t.hub.sent, isEmpty); // reading a history sends nothing
      await stop(tester);
    });

    testWidgets('leaving the PIN unasked reads nothing', (tester) async {
      final t = await pumpOrder(tester);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckHistoryScreen), findsNothing);
      expect(t.hub.historyAsks, isEmpty);
      expect(t.hub.pins, isEmpty);
      await stop(tester);
    });

    testWidgets('a phone has no room for the button: the name of the check held opens it', (tester) async {
      final t = await pumpOrder(tester, size: const Size(390, 800));
      expect(find.byTooltip('History'), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('order-title')));
      await tester.pumpAndSettle();
      await typePin(tester, '9999');
      expect(find.byType(CheckHistoryScreen), findsOneWidget);
      expect(t.hub.historyAsks, ['o1']);
      await stop(tester);
    });

    testWidgets('a closed check on a phone opens it the same way, and keeps its whole name', (tester) async {
      final t = await pumpOrder(tester, size: const Size(390, 800), status: 'closed');
      expect(find.byTooltip('History'), findsNothing);
      expect(find.text('Table A1 · closed'), findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('order-title')));
      await tester.pumpAndSettle();
      await typePin(tester, '9999');
      expect(t.hub.historyAsks, ['o1']);
      await stop(tester);
    });

    testWidgets('a check in the day\'s report opens its history without asking again', (tester) async {
      final d = await pumpDay(
        tester,
        before: (hub) => hub.histories = {
          'o3': {
            'order': {'order_id': 'o3', 'status': 'open', 'table': '5', 'order_type': 'dine_in', 'server': 'Amy'},
            'steps': [
              step(
                'opened',
                ms(20, 40),
                said: {
                  'fields': {'table': '5'},
                },
              ),
            ],
          },
        },
      );
      expect(evening()['open'], isNotEmpty);
      expect(find.text('Tap a check to read its history.'), findsOneWidget);
      await tapKey(tester, 'day-check:o3');
      expect(find.byType(CheckHistoryScreen), findsOneWidget);
      expect(d.t.hub.historyAsks, ['o3']);
      expect(d.t.hub.historyAuth, 'Bearer tok-admin');
      expect(d.t.hub.pins, isEmpty);
      expect(find.text('Opened the check'), findsOneWidget);
    });

    testWidgets('a void in the voids report opens the history of its check, for a manager', (tester) async {
      final t = await terminal(tester);
      tester.view.physicalSize = const Size(1100, 2000);
      final noon = DateTime(2026, 11, 16, 12);
      t.hub.histories = {'o1': dinner()};
      t.hub.report = {
        'voids': [
          {
            'order_id': 'o1',
            'table': '12',
            'item': 'Egg roll',
            'qty': 2,
            'amount': '4.50',
            'reason': 'kitchen-error',
            'reason_name': 'Kitchen error',
            'by': 'Amy',
            'approved_by': {'staff_id': 's3', 'name': 'Mike'},
            'at_ms': noon.millisecondsSinceEpoch,
          },
        ],
        'void_total': '4.50',
        'void_count': 1,
      };
      // opened without a manager's session, a row is only read
      await tester.pumpWidget(
        MaterialApp(
          home: AdjustmentsScreen(api: t.api, now: () => noon),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Each void'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('void-row:0'))).onTap, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: AdjustmentsScreen(api: t.api, token: 'tok-admin', now: () => noon),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text("Each void (tap one for its check's history)"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('void-row:0')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckHistoryScreen), findsOneWidget);
      expect(t.hub.historyAsks, ['o1']);
      expect(t.hub.historyAuth, 'Bearer tok-admin');
    });
  });

  group('every step says who took it', () {
    Future<(Terminal, Outbox)> signedIn(WidgetTester tester, {bool anybody = true}) async {
      final t = await terminal(tester);
      t.session.staff = anybody ? const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin') : null;
      return (t, Outbox(t.api, t.settings, store: MemoryStore(), who: () => t.session.staff));
    }

    testWidgets('a step that names nobody is given the person signed in', (tester) async {
      final (t, outbox) = await signedIn(tester);
      await outbox.addAll('o1', [
        ('fire', {'course': '*'}),
        ('close', {}),
        ('set_field', {'table': '14'}),
      ]);
      await outbox.flush();
      expect(
        [for (final (_, op) in t.hub.sent) op['data']],
        [
          {'course': '*', 'by': 'Amy', 'by_id': 's1'},
          {'by': 'Amy', 'by_id': 's1'},
          {'table': '14', 'by': 'Amy', 'by_id': 's1'},
        ],
      );
    });

    testWidgets('a step that names somebody keeps its own word', (tester) async {
      final (t, outbox) = await signedIn(tester);
      await outbox.addAll('o1', [
        ('add_line', {'line_id': 'L1', 'item': 'Beer', 'by': 'Ben', 'by_id': 's2'}),
        ('void_line', {'line_id': 'L1', 'by': 'Ben'}),
        ('discount', {'discount_id': 'd1', 'applied_by': 'Ben'}),
      ]);
      await outbox.flush();
      expect(
        [for (final (_, op) in t.hub.sent) op['data']],
        [
          {'line_id': 'L1', 'item': 'Beer', 'by': 'Ben', 'by_id': 's2'},
          {'line_id': 'L1', 'by': 'Ben'},
          {'discount_id': 'd1', 'applied_by': 'Ben'},
        ],
      );
    });

    testWidgets('with nobody signed in nothing is made up', (tester) async {
      final (t, outbox) = await signedIn(tester, anybody: false);
      await outbox.add('o1', 'close');
      await outbox.flush();
      expect(t.hub.sent.single.$2['data'], <String, dynamic>{});
      // somebody signs in: the next step is theirs, without the outbox being told
      t.session.staff = const Staff(staffId: 's2', name: 'Ben', role: 'bartender', method: 'pin');
      await outbox.add('o1', 'reopen');
      await outbox.flush();
      expect(t.hub.sent.last.$2['data'], {'by': 'Ben', 'by_id': 's2'});
    });
  });
}
