import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/idle_lock.dart';
import 'package:pos_app/kitchen_screen.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/kitchen_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'location_rows.dart';
import 'phone_test.dart' show FakeStack;

/// A station's screen (docs/kitchen-screens.md): a device set to be one lists, while nobody is signed in on
/// it, the tickets its stations still have to make, the longest in the kitchen first, in the words the paper
/// uses and coloured by how long they have waited. A tap marks a dish made, Done the whole ticket; Recall
/// brings one of the last ones back. The mark is the kitchen's own word on the order and nothing else of it.

final six = DateTime(2026, 11, 17, 18);
int ago(int minutes) => six.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

/// A dish on the hub's list of the kitchen: the order line it stands for and the stations that make it.
Map<String, dynamic> dish(
  String lineId,
  String label, {
  int qty = 1,
  List<String> stations = const ['wok'],
  List<String> made = const [],
  List<String> modifiers = const [],
  List<int>? depths,
  String note = '',
  int? seat,
  String header = '',
  String allergy = '',
  bool isVoid = false,
  bool changed = false,
}) => {
  'line_id': lineId,
  'stations': stations,
  'made': [...made],
  'qty': qty,
  'label': label,
  'modifiers': modifiers,
  'depths': depths ?? [for (final _ in modifiers) 0],
  'note': note,
  'seat': seat,
  'header': header,
  'allergy': allergy,
  'void': isVoid,
  'changed': changed,
  'done_ms': made.isEmpty ? null : ago(0),
};

/// One send of an order, in the kitchen for [minutes].
Map<String, dynamic> ticket(
  String orderId,
  int minutes,
  List<Map<String, dynamic>> lines, {
  String table = '',
  String tab = '',
  int? orderNo,
  String customer = '',
  String channel = '',
  int? promisedMs,
  String server = '',
  int? guests,
  String course = '',
  List<String> allergies = const [],
  List<String> alsoAt = const [],
}) => {
  'order_id': orderId,
  'since_ms': ago(minutes),
  'table': table,
  'tab': tab,
  'order_no': orderNo,
  'customer': customer,
  'to_go': orderNo != null || customer.isNotEmpty,
  'channel': channel,
  'promised_ms': promisedMs,
  'server': server,
  'guests': guests,
  'course': course,
  'allergies': allergies,
  'also_at': alsoAt,
  'lines': lines,
};

/// The kitchen at six: a table that has waited long, a phone order with an allergy, a table just sent with
/// sushi too, and a bar tab's food.
List<Map<String, dynamic>> evening() => [
  ticket(
    'o1',
    22,
    [
      dish('a', 'General Tso Chicken', qty: 2, modifiers: ['Extra spicy', 'Brown rice'], seat: 1),
      dish('b', 'Beef Lo Mein', note: 'no onions', seat: 2),
    ],
    table: '12',
    server: 'Amy',
    guests: 4,
    course: 'Entrees',
  ),
  ticket(
    'o2',
    12,
    [
      dish('a', 'Kung Pao Shrimp', modifiers: ['No peanuts'], allergy: 'Peanuts'),
      dish('b', 'Egg Roll', qty: 4, stations: ['fryer']),
    ],
    orderNo: 14,
    customer: 'Linda',
    channel: 'phone',
    promisedMs: six.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
    allergies: ['Order: Peanuts'],
    alsoAt: ['Fryer'],
  ),
  ticket(
    'o3',
    3,
    [
      dish('a', 'Crab Rangoon', header: 'Pu Pu Platter', stations: ['fryer']),
      dish('a', 'Beef Teriyaki', header: 'Pu Pu Platter', qty: 2),
      dish('b', 'California Roll', stations: ['sushi']),
    ],
    table: '7',
    server: 'Ben',
    guests: 2,
    alsoAt: ['Sushi bar'],
  ),
  ticket('o4', 1, [
    dish('a', 'Chicken Wings', modifiers: ['Sauce', 'Hot'], depths: [0, 1]),
  ], tab: 'Priya'),
];

const names = {
  'stations': [
    {'code': 'wok', 'name': 'Wok'},
    {'code': 'fryer', 'name': 'Fryer'},
    {'code': 'sushi', 'name': 'Sushi bar'},
    {'code': 'takeout', 'name': 'Takeout'},
  ],
  'missing': <String>[],
  'takeout_station': 'takeout',
};

/// The screen of [stations], with the hub's kitchen as [kitchen] (the evening's when none is given).
Future<Terminal> pumpScreen(
  WidgetTester tester, {
  List<String> stations = const ['wok'],
  bool pass = false,
  List<Map<String, dynamic>>? kitchen,
  bool older = false,
  Size? size,
  DateTime Function()? now,
}) async {
  final t = await terminal(tester);
  t.session.signOut();
  t.hub.stations = {...names};
  t.hub.kitchen = older ? null : (kitchen ?? evening());
  if (size != null) tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      home: KitchenScreen(
        api: t.api,
        outbox: t.outbox,
        stations: stations,
        pass: pass,
        now: now ?? () => six,
        onStaff: () {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return t;
}

/// The orders whose tickets stand on the screen, as they are read: across, then down. (Each column packs its
/// own tickets, so a ticket's place is its column and how many stand above it there.)
List<String> standing(WidgetTester tester) {
  final cards = find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-ticket:'));
  final placed = [
    for (final card in cards.evaluate())
      (
        '${card.widget.key}'.split('kitchen-ticket:').last.split(':').first,
        tester.getTopLeft(find.byWidget(card.widget)),
      ),
  ];
  int above((String, Offset) card) => placed.where((o) => o.$2.dx == card.$2.dx && o.$2.dy < card.$2.dy).length;
  placed.sort((a, b) => above(a) != above(b) ? above(a).compareTo(above(b)) : a.$2.dx.compareTo(b.$2.dx));
  return [for (final (orderId, _) in placed) orderId];
}

/// Every word of one ticket, top to bottom.
List<String> words(WidgetTester tester, String orderId) => [
  for (final text
      in find
          .descendant(
            of: find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-ticket:$orderId:')),
            matching: find.byType(Text),
          )
          .evaluate())
    if ((text.widget as Text).data case final said? when said.isNotEmpty) said,
];

Finder head(String orderId, String age) =>
    find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-head:$orderId:') && '${w.key}'.contains(':$age'));

Finder row(String orderId, String lineId, [int index = 0]) =>
    find.byWidgetPredicate((w) => RegExp('kitchen-line:$orderId:\\d+:$lineId:$index\\b').hasMatch('${w.key}'));

Finder button(String kind, String orderId) =>
    find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-$kind:$orderId:'));

/// The marks the hub was sent, in words: "o1 wok a,b made", "o1 wok a not made".
List<String> marks(Hub hub) => [
  for (final (orderId, op) in hub.sent)
    if (op['kind'] == 'done')
      [
        orderId,
        (op['data'] as Map)['station'],
        ((op['data'] as Map)['line_ids'] as List).join(','),
        (op['data'] as Map)['done'] == false ? 'not made' : 'made',
      ].join(' '),
];

Future<void> away(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
}

KitchenBoard board(List<Map<String, dynamic>> tickets, {List<Map<String, dynamic>> recent = const []}) =>
    KitchenBoard.fromJson({
      'stations': [
        {'code': 'wok', 'name': 'Wok'},
        {'code': 'fryer', 'name': 'Fryer'},
      ],
      'warn': 10,
      'late': 20,
      'tickets': [
        for (final t in tickets) {...t, 'id': '${t['order_id']}:${t['since_ms']}'},
      ],
      'recent': [
        for (final t in recent) {...t, 'id': '${t['order_id']}:${t['since_ms']}', 'done_ms': ago(0)},
      ],
    });

void main() {
  group('what a screen reads', () {
    test('a ticket says whose it is as the head of the paper does', () {
      final read = board(evening());
      expect(read.title, 'Wok · Fryer');
      expect([for (final t in read.tickets) t.title], ['Table 12', '#14 Linda', 'Table 7', 'Tab Priya']);
      expect(read.tickets[0].detail, 'Amy · 4 guests · Entrees');
      expect(read.tickets[1].detail, 'Phone · ready 18:20');
      expect(read.tickets[3].detail, '');
      expect(
        board([
          ticket('x', 1, [dish('a', 'Soup')]),
        ]).tickets.single.title,
        'No table',
      );
      expect(
        board([
          ticket('x', 1, [dish('a', 'Soup')], customer: 'Sam', guests: 1),
        ]).tickets.single.title,
        'Sam',
      );
    });

    test('its minutes are whole and never below zero, and they give it its colour', () {
      final read = board(evening());
      expect([for (final t in read.tickets) t.minutes(six)], [22, 12, 3, 1]);
      expect(
        [for (final t in read.tickets) read.age(t, six)],
        [TicketAge.late, TicketAge.warn, TicketAge.fresh, TicketAge.fresh],
      );
      // a terminal whose clock is behind the one that sent the dish
      expect(read.tickets[3].minutes(six.subtract(const Duration(minutes: 5))), 0);
      // 0 is never
      final plain = KitchenBoard(warn: 0, late: 0, tickets: read.tickets);
      expect(plain.age(read.tickets[0], six), TicketAge.fresh);
      final amberOnly = KitchenBoard(warn: 10, late: 0, tickets: read.tickets);
      expect(amberOnly.age(read.tickets[0], six), TicketAge.warn);
    });

    test('a mark names each station once with its dishes, and only what would change', () {
      final lines = board([
        ticket('o', 1, [
          dish('a', 'Wings', stations: ['fryer', 'wok'], made: ['wok']),
          dish('b', 'Rice'),
          dish('b', 'Rice, part two'),
          dish('c', 'Soup', made: ['wok']),
        ]),
      ]).tickets.single.lines;
      List<String> said(bool made) => [for (final (kind, data) in markOps(lines, made: made)) '$kind $data'];
      expect(said(true), ['done {station: fryer, line_ids: [a]}', 'done {station: wok, line_ids: [b]}']);
      expect(said(false), ['done {station: wok, line_ids: [a, c], done: false}']);
      expect(markOps(const [], made: true), isEmpty);
    });

    test('its own marks are laid over what the hub said until the hub shows them', () {
      final read = board([
        ticket('o1', 5, [dish('a', 'Soup'), dish('b', 'Rice')]),
        ticket('o2', 2, [dish('a', 'Wings')]),
      ]);
      Map<String, dynamic> made(List<String> ids, {bool done = true}) => {
        'kind': 'done',
        'data': {'station': 'wok', 'line_ids': ids, if (!done) 'done': false},
      };
      // nothing of its own: the very same board
      expect(identical(read.withLocal((_) => const [], nowMs: ago(0)), read), isTrue);
      final one = read.withLocal(
        (id) => id == 'o1'
            ? [
                made(['a']),
              ]
            : const [],
        nowMs: ago(0),
      );
      expect([for (final t in one.tickets) t.orderId], ['o1', 'o2']);
      expect([for (final l in one.tickets.first.lines) l.done], [true, false]);
      // the last dish of a ticket: among the finished at once
      final all = read.withLocal(
        (id) => id == 'o1'
            ? [
                made(['a']),
                made(['b']),
              ]
            : const [],
        nowMs: ago(0),
      );
      expect([for (final t in all.tickets) t.orderId], ['o2']);
      expect([for (final t in all.recent) (t.orderId, t.doneMs)], [('o1', ago(0))]);
      // and taken back, in the order it was said
      final back = read.withLocal(
        (id) => id == 'o1'
            ? [
                made(['a', 'b']),
                made(['a'], done: false),
              ]
            : const [],
        nowMs: ago(0),
      );
      expect([for (final t in back.tickets) t.orderId], ['o1', 'o2']);
      // other kinds of operation, and a mark that says nothing usable, change nothing
      final odd = read.withLocal(
        (_) => [
          {
            'kind': 'set_field',
            'data': {'stage': 'ready'},
          },
          {
            'kind': 'done',
            'data': {
              'station': 'sushi',
              'line_ids': ['a'],
            },
          },
          {'kind': 'done', 'data': <String, dynamic>{}},
        ],
        nowMs: ago(0),
      );
      expect(identical(odd, read), isTrue);
    });

    test('the location\'s minutes say themselves in a line', () {
      expect(const KitchenMinutes().summary, 'Amber after 10 min, red after 20 min');
      expect(const KitchenMinutes(warn: 0, late: 15).summary, 'Red after 15 min');
      expect(const KitchenMinutes(warn: 8, late: 0).summary, 'Amber after 8 min');
      expect(const KitchenMinutes(warn: 0, late: 0).summary, 'Tickets keep one colour however long they wait');
      expect(KitchenMinutes.fromJson(const {'warn': 5, 'late': 9}).toJson(), {'warn': 5, 'late': 9});
    });
  });

  group('the screen of a station', () {
    testWidgets('lists its tickets, the longest in the kitchen first, in the words of the paper', (tester) async {
      final t = await pumpScreen(tester);
      expect(t.hub.requests, contains('GET /kitchen/screen?stations=wok'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Wok');
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-count'))).data, '4 tickets');
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      expect(words(tester, 'o1'), [
        'Table 12',
        'Amy · 4 guests · Entrees',
        '22 min',
        '2 × General Tso Chicken',
        'Extra spicy',
        'Brown rice',
        'Seat 1',
        '1 × Beef Lo Mein',
        'no onions',
        'Seat 2',
        'Done',
      ]);
      // the allergy before anything else, who else cooks for it, and only the wok's own dishes
      expect(words(tester, 'o2'), [
        '#14 Linda',
        'Phone · ready 18:20',
        '12 min',
        'Allergy · Order: Peanuts',
        'Also at: Fryer',
        '1 × Kung Pao Shrimp',
        'No peanuts',
        'Allergy: Peanuts',
        'Done',
      ]);
      expect(words(tester, 'o3'), [
        'Table 7',
        'Ben · 2 guests',
        '3 min',
        'Also at: Sushi bar',
        '2 × Beef Teriyaki',
        'with Pu Pu Platter',
        'Done',
      ]);
      // a choice on a choice stands further in
      final sauce = tester.getTopLeft(find.text('Sauce')).dx, hot = tester.getTopLeft(find.text('Hot')).dx;
      expect(hot - sauce, 12);
      await away(tester);
    });

    testWidgets('a ticket turns amber and then red by its minutes, and the clock alone moves it on', (tester) async {
      var now = six;
      await pumpScreen(tester, now: () => now);
      expect(head('o1', 'late'), findsOneWidget);
      expect(head('o2', 'warn'), findsOneWidget);
      expect(head('o3', 'fresh'), findsOneWidget);
      expect(find.text('3 min'), findsOneWidget);
      now = six.add(const Duration(minutes: 7, seconds: 5));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.text('10 min'), findsOneWidget);
      expect(head('o3', 'warn'), findsOneWidget);
      expect(head('o2', 'warn'), findsOneWidget); // 19 minutes: not red yet
      now = six.add(const Duration(minutes: 8));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(head('o2', 'late'), findsOneWidget);
      await away(tester);
    });

    testWidgets('the location\'s own minutes colour it', (tester) async {
      final t = await terminal(tester);
      t.hub.kitchenMinutes = {'warn': 2, 'late': 0};
      t.hub.kitchen = evening();
      await tester.pumpWidget(
        MaterialApp(
          home: KitchenScreen(api: t.api, outbox: t.outbox, stations: const ['wok'], now: () => six),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(head('o1', 'warn'), findsOneWidget); // red is off: amber however long
      expect(head('o3', 'warn'), findsOneWidget);
      expect(head('o4', 'fresh'), findsOneWidget);
      expect(find.byKey(const ValueKey('kitchen-staff')), findsNothing); // nowhere to go: no button
      await away(tester);
    });

    testWidgets('a tap marks a dish made and another takes it back; the ticket stays until its last dish', (
      tester,
    ) async {
      final t = await pumpScreen(tester);
      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub), ['o1 wok a made']);
      // the kitchen's own word: no name on it, and nothing else of the order is said
      final op = t.hub.sent.single.$2;
      expect((op['data'] as Map).keys, ['station', 'line_ids']);
      expect(op['device'], 't1');
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      expect(find.byKey(const ValueKey('kitchen-recall')), findsNothing);

      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub).last, 'o1 wok a not made');
      expect(find.byIcon(Icons.check_circle), findsNothing);

      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.tap(row('o1', 'b', 1));
      await tester.pump();
      await tester.pump();
      expect(standing(tester), ['o2', 'o3', 'o4']);
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-count'))).data, '3 tickets');
      expect(find.byKey(const ValueKey('kitchen-recall')), findsOneWidget);
      await away(tester);
    });

    testWidgets('Done marks the whole ticket in one change, and Recall brings it back', (tester) async {
      final t = await pumpScreen(tester);
      await tester.tap(button('done', 'o1'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub), ['o1 wok a,b made']);
      expect(t.hub.batches.last, hasLength(1));
      expect(standing(tester), ['o2', 'o3', 'o4']);

      await tester.tap(find.byKey(const ValueKey('kitchen-recall')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Finished at Wok');
      expect(standing(tester), ['o1']);
      expect(words(tester, 'o1'), containsAll(['Table 12', '2 × General Tso Chicken', 'Bring back']));
      expect(find.text('22 min'), findsNothing); // a finished ticket counts no minutes
      // looking is not changing: a dish there takes no tap
      await tester.tap(row('o1', 'a'));
      await tester.pump();
      expect(marks(t.hub), hasLength(1));

      await tester.tap(button('bring-back', 'o1'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub).last, 'o1 wok a,b not made');
      // nothing finished is left: back among the tickets, the one brought back where it was
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Wok');
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      expect(find.byKey(const ValueKey('kitchen-recall')), findsNothing);
      await away(tester);
    });

    testWidgets('Back leaves the finished ones as they are', (tester) async {
      await pumpScreen(tester);
      await tester.tap(button('done', 'o4'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kitchen-recall')));
      await tester.pump();
      expect(standing(tester), ['o4']);
      await tester.tap(find.byKey(const ValueKey('kitchen-back')));
      await tester.pump();
      expect(standing(tester), ['o1', 'o2', 'o3']);
      expect(find.byKey(const ValueKey('kitchen-recall')), findsOneWidget);
      await away(tester);
    });

    testWidgets('a screen for two stations says each station\'s word, and a dish of parts is one dish', (tester) async {
      final t = await pumpScreen(tester, stations: const ['wok', 'fryer']);
      expect(t.hub.requests, contains('GET /kitchen/screen?stations=wok%2Cfryer'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Fryer · Wok');
      // one screen for two stations: each dish says whose it is
      expect(
        words(tester, 'o3'),
        containsAllInOrder(['1 × Crab Rangoon', 'with Pu Pu Platter', 'Fryer', '2 × Beef Teriyaki', 'Wok']),
      );
      // the platter is one line of the order: a tap on either part marks it at both stations
      await tester.tap(row('o3', 'a', 1));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub), ['o3 fryer a made', 'o3 wok a made']);
      expect(t.hub.batches.last, hasLength(2)); // together, as one change
      expect(standing(tester), ['o1', 'o2', 'o4']); // the roll is the sushi bar's: nothing of o3 is left here
      await tester.tap(button('done', 'o2'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub).sublist(2), ['o2 wok a made', 'o2 fryer b made']);
      await away(tester);
    });

    testWidgets('a dish voided while it cooks stays struck until the cook has seen it', (tester) async {
      final t = await pumpScreen(
        tester,
        kitchen: [
          ticket('o1', 4, [
            dish('a', 'Beef Lo Mein', isVoid: true),
            dish('b', 'Fried Rice', changed: true),
          ], table: '3'),
        ],
      );
      expect(words(tester, 'o1'), containsAllInOrder(['VOID', '1 × Beef Lo Mein', 'CHANGED', '1 × Fried Rice']));
      final struck = tester.widget<Text>(find.text('1 × Beef Lo Mein')).style!.decoration;
      expect(struck, TextDecoration.lineThrough);
      expect(tester.widget<Text>(find.text('1 × Fried Rice')).style!.decoration, isNot(TextDecoration.lineThrough));
      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2)); // the next read: the hub has dropped the void that was seen
      await tester.pump();
      expect(marks(t.hub), ['o1 wok a made']);
      expect(find.text('1 × Beef Lo Mein'), findsNothing);
      expect(standing(tester), ['o1']);
      await away(tester);
    });

    testWidgets('a ticket that comes in while it stands shows on the next read', (tester) async {
      final t = await pumpScreen(tester);
      t.hub.kitchen!.add(ticket('o9', 0, [dish('a', 'Hot and Sour Soup')], table: '21'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4', 'o9']);
      // and a read that brings nothing new costs a "nothing new"
      final before = t.hub.unchanged;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(t.hub.unchanged, greaterThan(before));
      await away(tester);
    });

    testWidgets('with the hub away it keeps its picture, says so, and a tap is not lost', (tester) async {
      final t = await pumpScreen(tester);
      t.hub.down = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('kitchen-away')), findsOneWidget);
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      await tester.tap(button('done', 'o4'));
      await tester.pump();
      await tester.pump();
      expect(standing(tester), ['o1', 'o2', 'o3']); // drawn at once
      expect(marks(t.hub), isEmpty);
      expect(t.outbox.pending, 1);
      t.hub.down = false;
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(marks(t.hub), ['o4 wok a made']);
      expect(t.outbox.pending, 0);
      expect(find.byKey(const ValueKey('kitchen-away')), findsNothing);
      expect(standing(tester), ['o1', 'o2', 'o3']);
      expect(t.outbox.localOps('o4'), isEmpty); // the hub shows it: no longer this screen's to lay over
      await away(tester);
    });

    testWidgets('a mark the hub refuses is taken back: the dish is to make again', (tester) async {
      final t = await pumpScreen(tester);
      t.hub.refuseMarks = 'this hub only reads';
      await tester.tap(button('done', 'o4'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub), ['o4 wok a made']); // it was sent
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']); // and is back where it was
      expect(find.byKey(const ValueKey('kitchen-recall')), findsNothing);
      expect(t.outbox.localOps('o4'), isEmpty);
      await away(tester);
    });

    testWidgets('nothing to make says so; a hub older than the screens says to update it', (tester) async {
      await pumpScreen(tester, kitchen: []);
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-none'))).data, 'Nothing to make right now.');
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-count'))).data, '0 tickets');
      await away(tester);
      await pumpScreen(tester, older: true);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('kitchen-none'))).data,
        startsWith('This hub is older than the kitchen screens.'),
      );
      await away(tester);
    });

    testWidgets('on a phone the tickets stand one under the other, on a wide screen side by side', (tester) async {
      await pumpScreen(tester, size: const Size(390, 844));
      Offset at(String orderId) =>
          tester.getTopLeft(find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-ticket:$orderId:')));
      expect(at('o2').dx, at('o1').dx);
      expect(at('o2').dy, greaterThan(at('o1').dy));
      expect(tester.takeException(), isNull);
      await away(tester);
      await pumpScreen(tester, size: const Size(1180, 820));
      expect(at('o2').dy, at('o1').dy);
      expect(at('o2').dx, greaterThan(at('o1').dx));
      expect(at('o3').dy, at('o1').dy); // three across, the fourth under the first
      expect(at('o4').dx, at('o1').dx);
      await away(tester);
    });

    testWidgets('a small phone with large text still fits every word', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpScreen(tester, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(button('done', 'o4')); // the list scrolls: the last ticket's button is reached
      await tester.pump();
      await tester.tap(button('done', 'o4'));
      await tester.pump();
      await tester.pump();
      // an icon where there is no room for the word
      expect(tester.widget(find.byKey(const ValueKey('kitchen-recall'))), isA<IconButton>());
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('kitchen-count'))).data,
        '3',
      ); // and a number for "3 tickets"
      expect(tester.takeException(), isNull);
      await away(tester);
    });
  });

  group('the device that is a kitchen screen', () {
    Future<Terminal> pumpDevice(
      WidgetTester tester, {
      List<String> stations = const ['wok'],
      int lockMinutes = 0,
    }) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveKitchenStations(stations);
      await t.settings.saveLockMinutes(lockMinutes);
      t.hub.stations = {...names};
      t.hub.kitchen = evening();
      final lock = IdleLock(t.settings, t.session)..start();
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        PosApp(
          settings: t.settings,
          api: t.api,
          outbox: t.outbox,
          session: t.session,
          camera: NoCamera(),
          photos: t.photos,
          relay: PrintRelay(t.api, t.settings),
          phone: PhoneClient(FakeStack()),
          deskPhones: DeskPhoneWatcher(t.api, t.settings),
          idleLock: lock,
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    Future<void> pin(WidgetTester tester, String digits) async {
      for (final digit in digits.split('')) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a device with no station shows the sign-in pad, as before', (tester) async {
      await pumpDevice(tester, stations: const []);
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(KitchenScreen), findsNothing);
      expect(find.byKey(const ValueKey('board-back')), findsNothing);
      await away(tester);
    });

    testWidgets('the screen stands while nobody is signed in; Staff brings the pad, and a PIN the orders', (
      tester,
    ) async {
      final t = await pumpDevice(tester);
      expect(find.byType(KitchenScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(KitchenScreen), findsNothing);
      expect(find.widgetWithText(TextButton, 'Kitchen screen'), findsOneWidget); // the way back, by its name
      await pin(tester, '1111');
      expect(t.session.staff?.name, 'Amy');
      expect(find.byType(OrdersScreen), findsOneWidget);
      t.session.signOut();
      await tester.pumpAndSettle();
      expect(find.byType(KitchenScreen), findsOneWidget);
      await away(tester);
    });

    testWidgets('the pad goes back to the screen from its bar, and by itself when left alone', (tester) async {
      await pumpDevice(tester);
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('board-back')));
      await tester.pumpAndSettle();
      expect(find.byType(KitchenScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.byType(KitchenScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      await away(tester);
    });

    testWidgets('a mark from the standing screen names nobody: nobody is signed in', (tester) async {
      final t = await pumpDevice(tester);
      await tester.tap(button('done', 'o4'));
      await tester.pumpAndSettle();
      expect(marks(t.hub), ['o4 wok a made']);
      expect((t.hub.sent.single.$2['data'] as Map).containsKey('by'), isFalse);
      await away(tester);
    });

    testWidgets('a screen that locked itself shows its tickets over the lock, and a tap still marks', (tester) async {
      final t = await pumpDevice(tester, lockMinutes: 5);
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      await pin(tester, '1111');
      expect(find.byType(OrdersScreen), findsOneWidget);
      t.session.lock(); // nobody touched it for five minutes
      await tester.pumpAndSettle();
      expect(t.session.locked, isTrue);
      expect(find.byType(KitchenScreen), findsOneWidget);
      await tester.tap(button('done', 'o1'));
      await tester.pumpAndSettle();
      expect(marks(t.hub), ['o1 wok a,b made']);
      // (the lock keeps who was signed in, but the kitchen's word is still nobody's)
      await tester.tap(find.byKey(const ValueKey('kitchen-recall')));
      await tester.pumpAndSettle();
      expect(standing(tester), ['o1']); // Recall opens nothing over the lock: it is the screen itself
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      await pin(tester, '1111');
      expect((t.session.signedIn, t.session.locked), (true, false));
      expect(find.byType(KitchenScreen), findsNothing);
      t.session.signOut();
      await tester.pumpAndSettle();
      await away(tester);
    });

    testWidgets('the stations are picked in the device\'s Settings, none to start, and kept with Save', (tester) async {
      final t = await terminal(tester);
      t.hub.stations = {...names};
      expect(t.settings.kitchenStations, isEmpty);
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('kitchen-screen-line'));
      expect(tester.widget<Text>(line).data, startsWith('For a screen at a station in the kitchen: while nobody'));
      await tester.tap(find.byKey(const ValueKey('kitchen-station:wok')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, startsWith('While nobody is signed in, this screen lists what Wok has'));
      await tester.tap(find.byKey(const ValueKey('kitchen-station:fryer')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, contains('what Wok and Fryer have to make'));
      expect(t.settings.kitchenStations, isEmpty); // not before Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(t.settings.kitchenStations, ['wok', 'fryer']);
      expect((await SharedPreferences.getInstance()).getStringList('kitchen_stations'), ['wok', 'fryer']);
    });

    testWidgets('a screen is a kitchen screen or the pickup board, never both', (tester) async {
      final t = await terminal(tester);
      t.hub.stations = {...names};
      await t.settings.savePickupBoard(true);
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      bool boardOn() => tester.widget<SwitchListTile>(find.byKey(const ValueKey('pickup-board-switch'))).value;
      bool picked(String code) => tester.widget<FilterChip>(find.byKey(ValueKey('kitchen-station:$code'))).selected;
      expect(boardOn(), isTrue);
      await tester.tap(find.byKey(const ValueKey('kitchen-station:sushi')));
      await tester.pumpAndSettle();
      expect((boardOn(), picked('sushi')), (false, true));
      await tester.tap(find.byKey(const ValueKey('pickup-board-switch')));
      await tester.pumpAndSettle();
      expect((boardOn(), picked('sushi')), (true, false));
      await tester.tap(find.byKey(const ValueKey('kitchen-station:sushi')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(t.settings.pickupBoard, isFalse);
      expect(t.settings.kitchenStations, ['sushi']);
      // and the device keeps it so, whichever was saved last
      await t.settings.savePickupBoard(true);
      expect((t.settings.pickupBoard, t.settings.stands), (true, true));
      expect(t.settings.kitchenStations, isEmpty);
      await t.settings.saveKitchenStations(const [' wok ', 'wok', '']);
      expect(t.settings.pickupBoard, isFalse);
      expect(t.settings.kitchenStations, ['wok']);
      await t.settings.saveKitchenStations(const []);
      expect(t.settings.stands, isFalse);
    });

    testWidgets('a device keeps its stations from one start to the next, and a hub that does not answer loses none', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'device': 't1',
        'endpoints': ['http://hub:8000'],
        'kitchen_stations': ['wok', 'grill'],
      });
      final kept = await Settings.load();
      expect(kept.kitchenStations, ['wok', 'grill']);
      final t = await terminal(tester);
      await t.settings.saveKitchenStations(const ['wok', 'grill']);
      t.hub.down = true;
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      // the stations it has are offered by their codes, to take one off
      expect(find.byKey(const ValueKey('kitchen-station:wok')), findsOneWidget);
      expect(find.byKey(const ValueKey('kitchen-station:grill')), findsOneWidget);
      expect(find.byKey(const ValueKey('kitchen-station:sushi')), findsNothing);
    });
  });

  group('the colours under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {bool older = false}) async {
      final t = await terminal(tester);
      if (older) t.hub.kitchen = null;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'kitchen-screens');
      return t;
    }

    String rowWords(WidgetTester tester) =>
        ((tester.widget<ListTile>(find.byKey(const ValueKey('kitchen-screens'))).subtitle!) as Text).data!;

    testWidgets('a manager sets when a ticket turns amber and red', (tester) async {
      final t = await pumpLocation(tester);
      expect(rowWords(tester), startsWith('Amber after 10 min, red after 20 min.'));
      await tester.tap(find.byKey(const ValueKey('kitchen-screens')));
      await tester.pumpAndSettle();
      // red before amber is caught here, and what the hub refuses is shown in its words
      await tester.enterText(find.byKey(const ValueKey('kitchen-warn')), '25');
      await tester.tap(find.byKey(const ValueKey('kitchen-minutes-save')));
      await tester.pumpAndSettle();
      expect(find.text('Red must come after amber'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('kitchen-warn')), 'soon');
      await tester.tap(find.byKey(const ValueKey('kitchen-minutes-save')));
      await tester.pumpAndSettle();
      expect(find.text('The minutes must be whole numbers, 0 for never'), findsOneWidget);
      expect(t.hub.kitchenMinutesAuth, isNull);
      await tester.enterText(find.byKey(const ValueKey('kitchen-warn')), '8');
      await tester.enterText(find.byKey(const ValueKey('kitchen-late')), '15');
      t.hub.refuseKitchenMinutes = 'the red time is 0 (never) to 1440 minutes';
      await tester.tap(find.byKey(const ValueKey('kitchen-minutes-save')));
      await tester.pumpAndSettle();
      expect(find.text('the red time is 0 (never) to 1440 minutes'), findsOneWidget);
      t.hub.refuseKitchenMinutes = null;
      await tester.tap(find.byKey(const ValueKey('kitchen-minutes-save')));
      await tester.pumpAndSettle();
      expect(t.hub.kitchenMinutesAuth, 'Bearer tok-admin');
      expect(t.hub.kitchenMinutes, {'warn': 8, 'late': 15});
      expect(find.text('Kitchen screens saved'), findsOneWidget);
      expect(rowWords(tester), startsWith('Amber after 8 min, red after 15 min.'));
    });

    testWidgets('a hub older than the screens says so and has nothing to open', (tester) async {
      await pumpLocation(tester, older: true);
      expect(rowWords(tester), startsWith('The hub has not answered about kitchen screens'));
      await tester.tap(find.byKey(const ValueKey('kitchen-screens')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('kitchen-minutes-save')), findsNothing);
    });
  });
}
