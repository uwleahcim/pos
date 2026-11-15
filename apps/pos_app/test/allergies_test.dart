import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/allergies.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';

import 'hub.dart';

/// An allergy told at the table (the Toast comparison, 2026-11-15): the Allergy chip beside the seats notes
/// it for the whole table or for one seat, the order carries it in a red strip, and a dish the menu says
/// contains it is marked on the check. The kitchen's side (every station's ticket) is the hub's.

const names = {'peanut': 'Peanuts', 'sesame': 'Sesame', 'wheat': 'Wheat'};

/// General Tso's chicken on [seat], which the menu says has soy and wheat in it.
Map<String, dynamic> gtc({int seat = 1, bool fired = false}) => {
  'item': "General Tso's Chicken",
  'qty': 1,
  'seat': seat,
  'course': '2',
  'status': 'active',
  'fired': fired,
  'priced': {
    'item': 'GTC',
    'contains': ['soy', 'wheat'],
  },
};

/// A to-go order: no table, no seats.
Map<String, dynamic> toGo(String id) => {
  'order_id': id,
  'status': 'open',
  'fields': {'order_type': 'takeout', 'order_no': 7, 'customer_name': 'Linda', 'channel': 'phone'},
  'lines': <String, dynamic>{},
  'fired': <String, dynamic>{},
};

/// The order screen with Amy signed in, on a hub that has [order] (a table for two unless given).
Future<Terminal> pumpOrder(
  WidgetTester tester, {
  Map<String, dynamic>? order,
  Map<String, dynamic> lines = const {},
  bool allergens = true,
  Size? screen,
}) async {
  final t = await terminal(tester);
  if (screen != null) tester.view.physicalSize = screen;
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  if (!allergens) t.hub.allergens = null;
  t.hub.orders.add(order ?? table('o1', {...lines}));
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

const chip = ValueKey('allergy-chip');
const strip = ValueKey('allergy-strip');
const save = ValueKey('allergy-save');

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> told(Terminal t) => [
  for (final op in t.hub.opsFor('o1'))
    if (op['kind'] == 'allergy') (op['data'] as Map).cast<String, dynamic>(),
];

void main() {
  test('an allergy is read the way the hub reads it, and worded the way the ticket words it', () {
    final read = Allergy.fromJson({
      'seat': 2,
      'allergens': ['peanut', ' sesame ', 'peanut', 7, ''],
      'note': '  no   oyster sauce ',
    });
    expect(read.seat, 2);
    expect(read.allergens, ['peanut', 'sesame']); // each once, as words
    expect(read.note, 'no oyster sauce');
    expect(read.words(names), 'Peanuts, Sesame - no oyster sauce');
    expect(const Allergy(allergens: ['celery-x']).words(names), 'celery-x'); // a code the menu does not name
    expect(const Allergy(note: 'severe').words(names), 'severe');
    expect(Allergy.fromJson({'seat': 0, 'note': 'x' * 200}).note.length, allergyNoteMax);
    expect(Allergy.fromJson({'seat': 0}).seat, isNull); // seat 0 is no seat: the table
    expect(read.toOp(by: 'Amy', byId: 's1'), {
      'seat': 2,
      'allergens': ['peanut', 'sesame'],
      'note': 'no oyster sauce',
      'by': 'Amy',
      'by_id': 's1',
    });
    expect(const Allergy().toOp().containsKey('seat'), isFalse);
    const both = [
      Allergy(allergens: ['peanut']),
      Allergy(seat: 2, allergens: ['sesame'], note: 'severe'),
    ];
    expect(allergySummary(both, names, seated: true), 'Table: Peanuts · Seat 2: Sesame - severe');
    expect(allergySummary(both.take(1).toList(), names, seated: false), 'Peanuts');
    expect(containsWords(['wheat', 'soy'], names), 'contains Wheat, soy');
  });

  test('an order carries its allergies and each dish what it has of them', () {
    final order = Order.fromJson({
      ...table('o1', {
        'L1': {
          ...gtc(),
          'allergy': ['wheat'],
        },
        'L2': gtc(seat: 2),
      }),
      'allergies': [
        {'seat': null, 'allergens': <String>[], 'note': 'celery'},
        {
          'seat': 1,
          'allergens': ['wheat'],
          'note': '',
          'by': 'Amy',
        },
      ],
    });
    expect([for (final a in order.allergies) (a.seat, a.words(names))], [(null, 'celery'), (1, 'Wheat')]);
    expect(order.lines.map((l) => l.allergy), [
      ['wheat'],
      <String>[],
    ]);
    expect(order.lines.first.copyWith(qty: 2).allergy, ['wheat']);
    expect(Order.fromJson(table('o1', {})).allergies, isEmpty); // a hub older than allergies
  });

  test('an allergy this screen has yet to send shows at once: the latest word on a seat stands', () {
    Map<String, dynamic> op(Map<String, dynamic> data) => {'kind': 'allergy', 'data': data};
    final base = Order.fromJson({
      ...table('o1', {}),
      'allergies': [
        {
          'seat': 1,
          'allergens': ['wheat'],
          'note': '',
        },
      ],
    });
    final shown = withLocalOps(base, [
      op({
        'seat': 2,
        'allergens': ['peanut'],
        'note': '',
      }),
      op({'allergens': <String>[], 'note': 'no msg'}),
      op({
        'seat': 2,
        'allergens': ['sesame'],
        'note': '',
      }),
      op({'seat': 1, 'allergens': <String>[], 'note': ''}), // nothing in it: seat 1's comes off
    ]);
    expect([for (final a in shown.allergies) (a.seat, a.words(names))], [(null, 'no msg'), (2, 'Sesame')]);
  });

  testWidgets('the Allergy chip notes an allergy for a seat, signed, and the order shows it in a strip', (
    tester,
  ) async {
    final t = await pumpOrder(tester);
    expect(find.byKey(strip), findsNothing);
    await tap(tester, find.byKey(chip));
    expect(find.text('The whole table cannot have'), findsOneWidget); // it opens on where the next dish goes
    expect(tester.widget<FilledButton>(find.byKey(save)).onPressed, isNull); // nothing to save yet
    await tap(tester, find.byKey(const ValueKey('allergy-who:2')));
    expect(find.text('Seat 2 cannot have'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('allergen:sesame')));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tester.enterText(find.byKey(const ValueKey('allergy-note')), ' no oyster  sauce ');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(save));

    expect(told(t), [
      {
        'seat': 2,
        'allergens': ['peanut', 'sesame'], // in the menu's order, whichever was tapped first
        'note': 'no oyster sauce',
        'by': 'Amy',
        'by_id': 's1',
      },
    ]);
    expect(find.text('ALLERGY  Seat 2: Peanuts, Sesame - no oyster sauce'), findsOneWidget);
    // seat 2's chip carries the mark, in the bar the next dish's seat is picked from
    final seat2 = find.ancestor(of: find.text('2'), matching: find.byType(ChoiceChip));
    expect(find.descendant(of: seat2, matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
    final seat1 = find.ancestor(of: find.text('1'), matching: find.byType(ChoiceChip));
    expect(find.descendant(of: seat1, matching: find.byIcon(Icons.warning_amber_rounded)), findsNothing);
    await stop(tester);
  });

  testWidgets('the table and a seat noted in one visit are one operation each, and the dialog opens on the seat '
      'the next dish goes to', (tester) async {
    final t = await pumpOrder(tester);
    await tap(tester, find.text('1')); // the next dish is seat 1's
    await tap(tester, find.byKey(chip));
    expect(find.text('Seat 1 cannot have'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('allergen:wheat')));
    await tap(tester, find.byKey(const ValueKey('allergy-who:0')));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tap(tester, find.byKey(const ValueKey('allergy-who:1')));
    // seat 1's is still as it was left
    expect(find.text('Seat 1 cannot have'), findsOneWidget);
    await tap(tester, find.byKey(save));
    expect([for (final a in told(t)) a['seat']], [null, 1]);
    expect(
      [for (final a in told(t)) a['allergens']],
      [
        ['peanut'],
        ['wheat'],
      ],
    );
    expect(find.text('ALLERGY  Table: Peanuts · Seat 1: Wheat'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a tap on the strip changes an allergy, and "No allergy" takes it off', (tester) async {
    final t = await pumpOrder(
      tester,
      order: {
        ...table('o1', {}),
        'allergies': [
          {
            'seat': null,
            'allergens': ['peanut', 'celery-x'],
            'note': 'severe',
          },
        ],
      },
    );
    expect(find.text('ALLERGY  Table: Peanuts, celery-x - severe'), findsOneWidget);
    await tap(tester, find.byKey(strip));
    // an allergen the menu no longer names can still be seen and taken off
    await tap(tester, find.byKey(const ValueKey('allergen:celery-x')));
    await tap(tester, find.byKey(save));
    expect(told(t).single, {
      'allergens': ['peanut'],
      'note': 'severe',
      'by': 'Amy',
      'by_id': 's1',
    });
    expect(find.text('ALLERGY  Table: Peanuts - severe'), findsOneWidget);

    await tap(tester, find.byKey(strip));
    await tap(tester, find.byKey(const ValueKey('allergy-clear')));
    await tap(tester, find.byKey(save));
    expect(told(t).last['allergens'], isEmpty);
    expect(told(t).last['note'], '');
    expect(find.byKey(strip), findsNothing);
    await stop(tester);
  });

  testWidgets('Cancel sends nothing, and so does Save with nothing changed', (tester) async {
    final t = await pumpOrder(tester);
    await tap(tester, find.byKey(chip));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tap(tester, find.text('Cancel'));
    expect(told(t), isEmpty);
    await tap(tester, find.byKey(chip));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut'))); // on and off again
    expect(tester.widget<FilledButton>(find.byKey(save)).onPressed, isNull);
    await stop(tester);
  });

  testWidgets('a dish the menu says contains it is marked on the check and said once, for its seat only', (
    tester,
  ) async {
    final t = await pumpOrder(tester, lines: {'L1': gtc(), 'L2': gtc(seat: 2)});
    expect(find.textContaining('ALLERGY: contains'), findsNothing);
    await tap(tester, find.text('2'));
    await tap(tester, find.byKey(chip));
    await tap(tester, find.byKey(const ValueKey('allergen:wheat')));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tap(tester, find.byKey(save));
    await tester.pump(const Duration(milliseconds: 600)); // the read that brings the hub's marks
    await tester.pump();
    expect(told(t).single['seat'], 2);
    expect(find.byKey(const ValueKey('allergy-mark:L2')), findsOneWidget);
    expect(find.text('ALLERGY: contains Wheat'), findsOneWidget); // seat 1's chicken is not seat 2's
    expect(find.text("ALLERGY: General Tso's Chicken contains Wheat."), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a check opened with a marked dish shows the mark and says nothing', (tester) async {
    await pumpOrder(
      tester,
      order: {
        ...table('o1', {
          'L1': {
            ...gtc(),
            'allergy': ['soy', 'wheat'],
          },
        }),
        'allergies': [
          {
            'seat': 1,
            'allergens': ['soy', 'wheat'],
            'note': '',
          },
        ],
      },
    );
    expect(find.text('ALLERGY: contains Soybeans, Wheat'), findsOneWidget);
    expect(find.byKey(const ValueKey('allergy-warning')), findsNothing);
    await stop(tester);
  });

  testWidgets('with dishes at the kitchen, the server is told the kitchen gets a ticket', (tester) async {
    await pumpOrder(tester, lines: {'L1': gtc(fired: true)});
    await tap(tester, find.byKey(chip));
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tester.tap(find.byKey(save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('The kitchen gets a ticket about it for the dishes it already has.'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a seat with an allergy stays in sight and cannot be taken away', (tester) async {
    final t = await pumpOrder(
      tester,
      order: {
        ...table('o1', {}),
        'allergies': [
          {
            'seat': 3,
            'allergens': ['peanut'],
            'note': '',
          },
        ],
      },
    );
    expect(find.text('3'), findsOneWidget); // a party of two on the order, and seat 3 still shows
    await tap(tester, find.byTooltip('Remove seat 3'));
    expect(find.text('Seat 3 has an allergy noted. Take the allergy off first.'), findsOneWidget);
    expect(t.hub.opsFor('o1').where((op) => op['kind'] == 'set_field'), isEmpty);
    await stop(tester);
  });

  testWidgets('a to-go order has no seats: the chip stands alone and the allergy is the order\'s', (tester) async {
    final t = await pumpOrder(tester, order: toGo('o1'));
    expect(find.text('Seat  '), findsNothing);
    await tap(tester, find.byKey(chip));
    expect(find.text('This order cannot have'), findsOneWidget);
    expect(find.byKey(const ValueKey('allergy-who:0')), findsNothing);
    await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
    await tap(tester, find.byKey(save));
    expect(told(t).single.containsKey('seat'), isFalse);
    expect(find.text('ALLERGY  Peanuts'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hub older than allergies offers no chip, on a table or a to-go order', (tester) async {
    await pumpOrder(tester, allergens: false);
    expect(find.byKey(chip), findsNothing);
    expect(find.text('Seat  '), findsOneWidget); // the seats are there as before
    await stop(tester);
    await pumpOrder(tester, order: toGo('o1'), allergens: false);
    expect(find.byKey(chip), findsNothing);
    await stop(tester);
  });

  testWidgets('with no hub answering, an allergy still shows at once and waits to be sent', (tester) async {
    final t = await pumpOrder(tester);
    t.hub.down = true;
    await tap(tester, find.byKey(chip));
    await tap(tester, find.byKey(const ValueKey('allergen:sesame')));
    await tester.tap(find.byKey(save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ALLERGY  Table: Sesame'), findsOneWidget);
    expect(told(t), isEmpty);
    expect(t.outbox.pendingOps.where((op) => op['kind'] == 'allergy'), hasLength(1));
    await stop(tester);
    t.outbox.dispose(); // it would try the hub again in three seconds
  });

  testWidgets('on a phone the chip leads the seat row, and the allergens and the line under them fit the screen', (
    tester,
  ) async {
    await pumpOrder(tester, screen: const Size(390, 844));
    expect(tester.getTopLeft(find.byKey(chip)).dx, lessThan(40)); // in sight without scrolling the row
    await tap(tester, find.byKey(chip));
    final note = tester.getRect(find.byKey(const ValueKey('allergy-note')));
    final button = tester.getRect(find.byKey(save));
    expect(note.bottom, lessThan(button.top)); // nothing to scroll to
    expect(button.bottom, lessThan(844));
    final first = tester.getRect(find.byKey(const ValueKey('allergen:milk')));
    final third = tester.getRect(find.byKey(const ValueKey('allergen:fish')));
    expect(first.top, third.top); // three across on a phone
    expect(first.height, greaterThanOrEqualTo(48)); // a finger's worth
    await stop(tester);
  });
}
