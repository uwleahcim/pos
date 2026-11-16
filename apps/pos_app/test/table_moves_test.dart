import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/allergies.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/moves.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/table_moves.dart';
import 'package:pos_app/settings.dart';

import 'comp_test.dart' as comps show rules;
import 'floor_test.dart' show floorJson;
import 'hub.dart';
import 'lot_test.dart' as lot show check, dropOn, pickUp, target;
import 'table_servers_test.dart' show amy, holly, mike, pumpFloor, serverTag;
import 'voids_test.dart' as voids show rules;

/// Move, merge and hand over (the Toast comparison, 2026-11-16): hold a seated table and move its check to
/// another table; on a table that is seated, the two become one check or stay two checks at one table;
/// dishes in hand on the check go to another table's check; and a host or manager gives every table of one
/// server to another in one go. A dish that changes checks is never voided and rung in again: the check that
/// takes it names where it comes from, and the hub fills it in.

/// A check as a hub lists it on a table of the floor.
Map<String, dynamic> seated(String orderId, String server, String serverId, {int guests = 2, String total = '10.70'}) =>
    {
      'order_id': orderId,
      'guests': guests,
      'server': server,
      'server_id': serverId,
      'opened_ms': 1800000000000,
      'items': 1,
      'fired': <String>[],
      'held': <String>[],
      'total': total,
    };

/// The floor of a hub that moves tables: A7 is Amy's (the fixture's check o1), and [more] seats others.
Map<String, dynamic> floorThatMoves([Map<String, List<Map<String, dynamic>>> more = const {}]) {
  final json = floorJson()..['moves'] = true;
  (json['status'] as Map<String, dynamic>).addAll(more);
  return json;
}

/// An order as a hub reads it back, at the table [at].
Map<String, dynamic> checkAt(
  String id,
  String at,
  Map<String, dynamic> lines, {
  int guests = 2,
  Map<String, dynamic> more = const {},
}) => {
  'order_id': id,
  'status': 'open',
  'fields': {'table': at, 'guests': guests, 'order_type': 'dine_in'},
  'lines': lines,
  'fired': <String, dynamic>{},
  ...more,
};

/// A7's check (two dishes, the duck at the kitchen, four guests) and B5's (Ben's: a soup, two guests).
void seatBoth(Hub hub, {Map<String, dynamic> a7 = const {}}) {
  hub.floor = floorThatMoves({
    'B5': [seated('o2', 'Ben', 's2')],
  });
  hub.orders.addAll([
    checkAt(
      'o1',
      'A7',
      {
        'L1': {...line('Egg roll', rank: 1), 'seat': 1},
        'L2': {...line('Peking Duck', fired: true, rank: 2), 'seat': 3},
      },
      guests: 4,
      more: a7,
    ),
    checkAt('o2', 'B5', {'M1': line('Wonton soup', rank: 1)}),
  ]);
}

/// Every operation in [queue] as [order id, kind, data], in the order it is queued.
List<List<Object>> flat(List<OrderOps> queue) => [
  for (final (id, ops) in queue)
    for (final (kind, data) in ops) [id, kind, data],
];

/// What the terminal sent, the same way.
List<List<Object?>> sentTo(Hub hub) => [
  for (final (id, op) in hub.sent) [id, op['kind'], op['data']],
];

/// New ids in order: N1, N2, ...
String Function() counter() {
  var n = 0;
  return () => 'N${++n}';
}

Order a7() => const Order(
  orderId: 'o1',
  status: 'open',
  fields: {'table': 'A7', 'guests': 3},
  fired: {},
  lines: [
    Line(
      lineId: 'L1',
      item: 'Egg roll',
      qty: 2,
      status: 'active',
      seat: 1,
      course: '1',
      rank: 1,
      by: 'Amy',
      byId: 's1',
    ),
    Line(
      lineId: 'L2',
      item: 'Peking Duck',
      qty: 1,
      status: 'active',
      seat: 2,
      course: '2',
      rank: 2,
      fired: true,
      note: 'no skin',
      by: 'Ben',
      byId: 's2',
    ),
    Line(lineId: 'L3', item: 'Hot tea', qty: 1, status: 'void', rank: 3, fired: true),
    Line(lineId: 'L4', item: 'Fried rice', qty: 1, status: 'active', rank: 4),
  ],
  allergies: [
    Allergy(allergens: ['sesame', 'peanut'], note: 'no oyster sauce'),
    Allergy(seat: 2, allergens: ['egg']),
  ],
  discounts: [(discountId: 'D1', lineId: 'L2'), (discountId: 'D2', lineId: null)],
);

Order b5() => const Order(
  orderId: 'o2',
  status: 'open',
  fields: {'table': 'B5', 'guests': 2},
  fired: {},
  lines: [Line(lineId: 'M1', item: 'Wonton soup', qty: 1, status: 'active', seat: 3, rank: 1)],
  allergies: [
    Allergy(allergens: ['peanut'], note: 'severe'),
    Allergy(seat: 1, allergens: ['milk']),
  ],
);

const byMike = {'by': 'Mike', 'by_id': 's3'};
const byHolly = {'by': 'Holly', 'by_id': 's4'};
const byAmy = {'by': 'Amy', 'by_id': 's1'};

Finder bar() => find.byKey(const ValueKey('moving-bar'));

void main() {
  test('a table that moves takes each of its checks along as it is', () {
    expect(flat(moveTableOps(['o1', 'o3'], 'B5', by: amy)), [
      [
        'o1',
        'set_field',
        {'table': 'B5', ...byAmy},
      ],
      [
        'o3',
        'set_field',
        {'table': 'B5', ...byAmy},
      ],
    ]);
    expect(flat(moveTableOps(['o1'], 'B5')).single.last, {'table': 'B5'});
  });

  test('a dish that changes checks is taken by the other check first, then let go: never voided', () {
    final from = a7();
    final byId = {for (final line in from.lines) line.lineId: line};
    final queue = moveLinesOps(
      from: from,
      onto: 'o2',
      lines: [byId['L4']!, byId['L3']!, byId['L2']!], // in any order, and one that is no longer on the check
      newId: counter(),
      by: mike,
    );
    expect(queue.map((entry) => entry.$1), ['o2', 'o1']); // the check that takes them is queued first
    expect(flat(queue), [
      [
        'o2',
        'add_line',
        {
          'line_id': 'N1',
          'item': 'Peking Duck',
          'qty': 1,
          'seat': null, // for the table, on a check where nobody knows its seat
          'course': '2',
          'note': 'no skin',
          'from': {'order_id': 'o1', 'line_id': 'L2'},
          'sent': 'sent', // the kitchen has it: the hub says since when
          'by': 'Ben', // whoever rang it in still did
          'by_id': 's2',
          'moved_by': 'Mike', // and who brought it over is said beside, for the check's history
          'moved_by_id': 's3',
        },
      ],
      [
        // the comp on the duck goes with the duck; the discount on the whole check does not
        'o2',
        'discount',
        {
          'discount_id': 'N2',
          'line_id': 'N1',
          'from': {'order_id': 'o1', 'discount_id': 'D1'},
          ...byMike,
        },
      ],
      [
        'o2',
        'add_line',
        {
          'line_id': 'N3',
          'item': 'Fried rice',
          'qty': 1,
          'seat': null,
          'from': {'order_id': 'o1', 'line_id': 'L4'},
          'moved_by': 'Mike',
          'moved_by_id': 's3',
        },
      ],
      [
        'o1',
        'move_line',
        {
          'line_id': 'L2',
          'to': {'order_id': 'o2', 'line_id': 'N1'},
          ...byMike,
        },
      ],
      [
        'o1',
        'move_line',
        {
          'line_id': 'L4',
          'to': {'order_id': 'o2', 'line_id': 'N3'},
          ...byMike,
        },
      ],
    ]);
    expect(queue.expand((entry) => entry.$2).map((op) => op.$1), isNot(contains('void_line')));
    // nothing that is still on the check: nothing to queue
    expect(moveLinesOps(from: from, onto: 'o2', lines: [byId['L3']!], newId: counter()), isEmpty);
  });

  test('two checks become one: seats after the guests already there, guests added, allergies told again', () {
    final from = a7();
    final onto = b5();
    expect(seatShift(onto), 3); // two guests, but somebody sits at seat 3
    expect(seatShift(const Order(orderId: 'x', status: 'open', fields: {'guests': 6}, lines: [], fired: {})), 6);
    expect(hasCheckDiscount(from), isTrue);
    expect(hasCheckDiscount(onto), isFalse);
    expect(cannotMerge(from), isNull);

    final queue = flat(mergeOps(from: from, onto: onto, newId: counter(), by: holly));
    final taken = queue.where((op) => op[0] == 'o2').toList();
    final let = queue.where((op) => op[0] == 'o1').toList();
    expect(queue.indexOf(taken.last) < queue.indexOf(let.first), isTrue);
    expect(taken.map((op) => op[1]), [
      'add_line',
      'add_line',
      'discount',
      'add_line',
      'set_field',
      'allergy',
      'allergy',
    ]);
    final seats = [
      for (final op in taken.where((op) => op[1] == 'add_line')) ((op[2] as Map)['item'], (op[2] as Map)['seat']),
    ];
    expect(seats, [('Egg roll', 4), ('Peking Duck', 5), ('Fried rice', null)]);
    expect(taken[4][2], {'guests': 5, ...byHolly});
    // the moved table's allergy joins the other table's; a seat's is told for the seat its guest has now
    expect(taken[5][2], {
      'seat': null,
      'allergens': ['peanut', 'sesame'],
      'note': 'severe; no oyster sauce',
      ...byHolly,
    });
    expect(taken[6][2], {
      'seat': 5,
      'allergens': ['egg'],
      'note': '',
      ...byHolly,
    });
    // the emptied check says where its dishes went and is closed
    expect(let.map((op) => op[1]), ['move_line', 'move_line', 'move_line', 'set_field', 'close']);
    expect(let[3][2], {'merged_into': 'o2', ...byHolly});
    expect(let[4][2], byHolly);
  });

  test('a check with money on it is not emptied into another', () {
    final paid = Order.fromJson(
      checkAt(
        'o1',
        'A7',
        {'L1': line('Egg roll')},
        more: {
          'payments': {
            'P1': {'method': 'cash', 'amount': '5.00'},
          },
        },
      ),
    );
    expect(cannotMerge(paid), 'has a payment on it, so it stays a check of its own');
  });

  test('a dish taken from another check shows as the kitchen has it; one let go is off with no void', () {
    final onto = withLocalOps(b5(), [
      {
        'kind': 'add_line',
        'data': {
          'line_id': 'N1',
          'item': 'Peking Duck',
          'qty': 1,
          'from': {'order_id': 'o1', 'line_id': 'L2'},
          'sent': 'sent',
        },
      },
      {
        'kind': 'add_line',
        'data': {
          'line_id': 'N2',
          'item': 'Fried rice',
          'qty': 1,
          'from': {'order_id': 'o1', 'line_id': 'L4'},
        },
      },
    ]);
    final came = {for (final line in onto.activeLines) line.item: line.fired};
    expect(came, {'Wonton soup': false, 'Peking Duck': true, 'Fried rice': false});

    final from = withLocalOps(a7(), [
      {
        'kind': 'move_line',
        'data': {
          'line_id': 'L2',
          'to': {'order_id': 'o2', 'line_id': 'N1'},
        },
      },
    ]);
    expect(from.activeLines.map((line) => line.item), ['Egg roll', 'Fried rice']);
    // a sent dish that is voided reads "void"; this one was not voided
    expect(from.lines.firstWhere((line) => line.lineId == 'L2').status, 'removed');
  });

  test('a table moved or merged on this device shows where it went before a hub has heard', () async {
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
    final api = PosApi(settings, client: MockClient((request) async => http.Response('', 503)));
    final outbox = Outbox(api, settings, store: MemoryStore());
    await outbox.add('o1', 'set_field', {'table': 'A8', ...byAmy});
    await outbox.add('o1', 'set_field', {'guests': 5}); // some other change to the check is no move
    await outbox.add('o2', 'set_field', {'merged_into': 'o1'});
    await outbox.add('o2', 'close');
    // a check opened here and moved before the hub heard of it is on the map from its own operations
    await outbox.add('n1', 'create', {'table': 'K1', 'order_type': 'dine_in'});
    await outbox.add('n1', 'set_field', {'table': 'K2'});
    final (moved, gone) = queuedTables(outbox);
    expect(moved, {'o1': 'A8'});
    expect(gone, {'o2'});
    expect(queuedChecks(outbox).keys, ['K2']);

    final plan = FloorPlan.fromJson(
      floorThatMoves({
        'B5': [seated('o2', 'Ben', 's2')],
        'A8': [seated('o3', 'Ben', 's2')],
      }),
    );
    final now = plan.withTables(moved, gone);
    expect(now.checksAt('A7'), isEmpty);
    expect(now.checksAt('A8').map((check) => check.orderId), ['o3', 'o1']); // after the check that was there
    expect(now.checksAt('B5'), isEmpty);
    expect(now.tableOf, {'o3': 'A8', 'o1': 'A8'});
    expect(now.moves, isTrue);
    expect(FloorPlan.fromJson(floorJson()).moves, isFalse); // a hub older than moving
    await outbox.flush(); // nothing answers: it stays queued, and nothing is left running
    outbox.dispose();
    api.dispose();
  });

  testWidgets('the checks dishes can go to are buttons, table by table as a person counts them', (tester) async {
    expect(['A10', 'B1', 'A2', 'Bar 3', 'A1', 'Patio'].toList()..sort(compareLabels), [
      'A1',
      'A2',
      'A10',
      'B1',
      'Bar 3',
      'Patio',
    ]);
    final plan = FloorPlan.fromJson(
      floorThatMoves({
        'B5': [seated('o2', 'Ben', 's2'), seated('o3', 'Amy Wu', 's1', guests: 1, total: '21.40')],
        'A3': [seated('o4', '', '', guests: 3)],
      }),
    );
    expect(CheckPicker.places(plan, 'o1').map((place) => '${place.$1.label} ${place.$2.orderId}'), [
      'A3 o4',
      'B5 o2',
      'B5 o3',
    ]);
    final picked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CheckPicker(plan: plan, except: 'o1', onPicked: (table, check) => picked.add(check.orderId)),
        ),
      ),
    );
    Finder on(String order, String text) =>
        find.descendant(of: find.byKey(ValueKey('move-to:$order')), matching: find.text(text));
    expect(on('o4', '3 guests'), findsOneWidget); // nobody's yet: the guests alone
    expect(on('o4', '1 dish · \$10.70'), findsNothing); // one check at the table: no need to tell it apart
    // two checks at B5: each says whose it is and what is on it
    expect(on('o2', 'Ben · 2 guests'), findsOneWidget);
    expect(on('o2', '1 dish · \$10.70'), findsOneWidget);
    expect(on('o3', 'Amy W · 1 guest'), findsOneWidget);
    expect(on('o3', '1 dish · \$21.40'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('move-to:o3')));
    expect(picked, ['o3']);
  });

  testWidgets('a server holds a table down and taps the free table it goes to', (tester) async {
    final t = await pumpFloor(tester, amy, hub: (hub) => hub.floor = floorThatMoves());
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A7?'), findsNothing); // a server hands nothing over
    expect(bar(), findsOneWidget);
    expect(find.text('Moving A7. Tap the table it goes to.'), findsOneWidget);

    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    expect(sentTo(t.hub), [
      [
        'o1',
        'set_field',
        {'table': 'A8', ...byAmy},
      ],
    ]);
    expect(find.text('A7 moved to A8'), findsOneWidget);
    expect(bar(), findsNothing);
    expect(find.text('Seat A8'), findsNothing); // the tap placed the table: it seated nobody
    expect(find.byType(OrderScreen), findsNothing);
    // the check is at A8 now, still Amy's
    expect(find.descendant(of: serverTag('A8'), matching: find.text('Amy')), findsOneWidget);
    expect(serverTag('A7'), findsNothing);
    await stop(tester);
  });

  testWidgets('a move can be called off, and the table it came from is no place to move it to', (tester) async {
    final t = await pumpFloor(tester, amy, hub: (hub) => hub.floor = floorThatMoves());
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-cancel')));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);

    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A7'));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
    expect(find.byType(OrderScreen), findsNothing); // the tap ended the move: it opened no check
    expect(t.hub.sent, isEmpty);

    // holding a free table moves nothing
    await tester.longPress(find.text('A8'));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
    await stop(tester);
  });

  testWidgets('the host moves a table onto a seated one and keeps the two checks apart', (tester) async {
    final t = await pumpFloor(tester, holly, hub: seatBoth);
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    // her sheet: move it, or say who serves it
    expect(find.text('Who serves A7?'), findsOneWidget);
    expect(find.text('Move A7 to another table'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('move-table')));
    await tester.pumpAndSettle();
    expect(bar(), findsOneWidget);

    await tester.tap(find.text('B5'));
    await tester.pumpAndSettle();
    expect(find.text('B5 is seated'), findsOneWidget);
    expect(find.text('Put A7 and B5 on one check, or keep two checks at B5?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keep-apart')));
    await tester.pumpAndSettle();

    expect(sentTo(t.hub), [
      [
        'o1',
        'set_field',
        {'table': 'B5', ...byHolly},
      ],
    ]);
    expect(find.text('A7 moved to B5'), findsOneWidget);
    expect(bar(), findsNothing);
    // both checks sit at B5 now, each still its own server's
    final b5Checks = (t.hub.floor!['status'] as Map)['B5'] as List;
    expect(b5Checks.map((check) => ((check as Map)['order_id'], check['server'])), [('o2', 'Ben'), ('o1', 'Amy')]);
    await stop(tester);
  });

  testWidgets('a manager puts two tables on one check: every dish goes over and none is voided', (tester) async {
    final t = await pumpFloor(tester, mike, hub: seatBoth);
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-table')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B5'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('one-check'))).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('one-check')));
    await tester.pumpAndSettle();

    final ops = sentTo(t.hub);
    expect(ops.map((op) => '${op[0]} ${op[1]}'), [
      'o2 add_line',
      'o2 add_line',
      'o2 set_field',
      'o1 move_line',
      'o1 move_line',
      'o1 set_field',
      'o1 close',
    ]);
    final first = ops[0][2]! as Map;
    final second = ops[1][2]! as Map;
    // B5 has two guests: A7's seat 1 is seat 3 there, and its seat 3 is seat 5
    expect((first['item'], first['seat'], first.containsKey('sent')), ('Egg roll', 3, false));
    expect(first['from'], {'order_id': 'o1', 'line_id': 'L1'});
    expect((second['item'], second['seat'], second['sent']), ('Peking Duck', 5, 'sent'));
    expect(ops[2][2], {'guests': 6, ...byMike});
    expect((ops[3][2]! as Map)['to'], {'order_id': 'o2', 'line_id': first['line_id']});
    expect(ops[5][2], {'merged_into': 'o2', ...byMike});
    expect(t.hub.sent.map((s) => s.$2['kind']), isNot(contains('void_line')));
    expect(find.text("A7 is on B5's check now"), findsOneWidget);

    // the hub's own reading: the dishes are on B5's check, the duck still at the kitchen, and A7 is free
    final b5Lines = (t.hub.orders.firstWhere((o) => o['order_id'] == 'o2')['lines'] as Map).values.cast<Map>();
    expect(b5Lines.map((l) => (l['item'], l['fired'])), [
      ('Wonton soup', false),
      ('Egg roll', false),
      ('Peking Duck', true),
    ]);
    expect(serverTag('A7'), findsNothing);
    expect(find.descendant(of: serverTag('B5'), matching: find.text('Ben')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a check with a payment on it can only be kept apart', (tester) async {
    final t = await pumpFloor(
      tester,
      mike,
      hub: (hub) => seatBoth(
        hub,
        a7: {
          'payments': {
            'P1': {'method': 'cash', 'amount': '5.00'},
          },
        },
      ),
    );
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-table')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B5'));
    await tester.pumpAndSettle();
    expect(find.text("A7's check has a payment on it, so it stays a check of its own."), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('one-check'))).onPressed, isNull);

    // walking away from the question moves nothing, and the table is still in hand
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(t.hub.sent, isEmpty);
    expect(bar(), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a discount on the whole check is said to stay behind before the two become one', (tester) async {
    await pumpFloor(
      tester,
      mike,
      hub: (hub) => seatBoth(
        hub,
        a7: {
          'discounts': {
            'D9': {'reason': 'loyalty', 'kind': 'percent', 'value': '10', 'line_id': null, 'active': true},
          },
        },
      ),
    );
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-table')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B5'));
    await tester.pumpAndSettle();
    expect(
      find.text("The discount on A7's whole check stays behind. Put it on B5's check again if it should count."),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  testWidgets('at shift change the host gives every table of one server to another in one go', (tester) async {
    final t = await pumpFloor(
      tester,
      holly,
      hub: (hub) => hub.floor = floorThatMoves({
        'B5': [seated('o2', 'Amy', 's1')],
        'K3': [seated('o3', 'Amy', 's1'), seated('o4', 'Ben', 's2')],
      }),
    );
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    final all = find.byKey(const ValueKey('all-tables'));
    expect(find.descendant(of: all, matching: find.text("All 3 of Amy's tables")), findsOneWidget);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(find.text("Who takes Amy's 3 tables?"), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('server:s2')));
    await tester.pumpAndSettle();

    // each of her checks, wherever it is; Ben's own check at K3 is left alone
    const toBen = {'server': 'Ben', 'server_id': 's2', ...byHolly};
    expect(sentTo(t.hub), [
      ['o1', 'set_field', toBen],
      ['o2', 'set_field', toBen],
      ['o3', 'set_field', toBen],
    ]);
    expect(find.text("Amy's 3 tables are Ben's now"), findsOneWidget);
    await stop(tester);
  });

  testWidgets('with one table in a server\'s hands there is nothing to tick', (tester) async {
    await pumpFloor(tester, holly, hub: (hub) => hub.floor = floorThatMoves());
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A7?'), findsOneWidget);
    expect(find.byKey(const ValueKey('all-tables')), findsNothing);
    await stop(tester);
  });

  testWidgets('a hub older than moving offers no move: a server holds nothing, a host only hands over', (tester) async {
    final t = await pumpFloor(tester, amy); // the fixture floor says nothing of moving
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);

    t.session.staff = holly;
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A7?'), findsOneWidget);
    expect(find.byKey(const ValueKey('move-table')), findsNothing);
    await stop(tester);
  });

  testWidgets('the sheet and the question fit a phone', (tester) async {
    final t = await terminal(tester);
    tester.view.physicalSize = const Size(390, 844);
    t.session.staff = holly;
    seatBoth(t.hub);
    await pumpOrdersOn(tester, t);
    await tester.tap(find.byTooltip('Floor map'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('move-table')));
    await tester.pumpAndSettle();
    expect(bar(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('B5'));
    await tester.pumpAndSettle();
    expect(find.text('B5 is seated'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  group('dishes in hand on the check', () {
    /// Four dishes on Amy's table A7 (the duck and the tea at the kitchen), and Ben's B5 across the floor.
    Future<Terminal> pumpCheck(WidgetTester tester, {bool moves = true, bool others = true, Size? size}) async {
      final t = await terminal(tester);
      if (size != null) tester.view.physicalSize = size;
      t.session.staff = amy;
      t.hub.voids = voids.rules;
      t.hub.rules = comps.rules;
      t.hub.check = {...lot.check, 'discounts': <Map<String, dynamic>>[], 'discount_total': '0.00', 'moves': moves};
      t.hub.floor = floorThatMoves({
        if (others) 'B5': [seated('o2', 'Ben', 's2')],
      });
      t.hub.orders.addAll([
        checkAt('o1', 'A7', {
          'L1': line('Egg roll', rank: 1),
          'L2': line('Peking Duck', fired: true, rank: 2),
          'L3': line('Hot tea', fired: true, rank: 3),
          'L4': line('Fried rice', rank: 4),
        }),
        checkAt('o2', 'B5', {'M1': line('Wonton soup', rank: 1)}),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('are let go over Move and go to another table\'s check, sent or not', (tester) async {
      final t = await pumpCheck(tester);
      expect(lot.target('move'), findsNothing); // nothing in hand: nothing offered
      final (gesture, from) = await lot.pickUp(tester, 'Peking Duck', ['Egg roll']);
      expect(find.descendant(of: lot.target('move'), matching: find.text('Move 2')), findsOneWidget);
      expect(lot.target('comp'), findsOneWidget);
      expect(lot.target('void'), findsOneWidget);
      await lot.dropOn(tester, gesture, from, 'move');

      // which table: the others that have a check, each with who serves it
      expect(find.text('Move 2 dishes to'), findsOneWidget);
      final b5Check = find.byKey(const ValueKey('move-to:o2'));
      expect(find.descendant(of: b5Check, matching: find.text('B5')), findsOneWidget);
      expect(find.descendant(of: b5Check, matching: find.text('Ben · 2 guests')), findsOneWidget);
      expect(find.byKey(const ValueKey('move-to:o1')), findsNothing); // not its own check
      await tester.tap(find.byKey(const ValueKey('move-to:o2')));
      await tester.pumpAndSettle();

      final ops = sentTo(t.hub);
      expect(ops.map((op) => '${op[0]} ${op[1]}'), ['o2 add_line', 'o2 add_line', 'o1 move_line', 'o1 move_line']);
      final taken = [for (final op in ops.take(2)) op[2]! as Map];
      expect(taken.map((d) => (d['item'], d['seat'], d['sent'])), [
        ('Egg roll', null, null),
        ('Peking Duck', null, 'sent'),
      ]);
      expect(taken.map((d) => d['from']), [
        {'order_id': 'o1', 'line_id': 'L1'},
        {'order_id': 'o1', 'line_id': 'L2'},
      ]);
      expect((ops[2][2]! as Map)['by'], 'Amy');
      // no reason, no manager, no void: nothing came off the register
      expect(t.hub.purposes, isEmpty);
      expect(find.text('2 dishes moved to table B5'), findsOneWidget);
      expect(find.text('Peking Duck'), findsNothing);
      expect(find.text('Hot tea'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('stay on the check when nobody says which table', (tester) async {
      final t = await pumpCheck(tester);
      final (gesture, from) = await lot.pickUp(tester, 'Egg roll');
      expect(find.descendant(of: lot.target('move'), matching: find.text('Move')), findsOneWidget);
      await lot.dropOn(tester, gesture, from, 'move');
      expect(find.text('Move Egg roll to'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // beside the sheet
      await tester.pumpAndSettle();
      expect(t.hub.sent, isEmpty);
      expect(find.text('Egg roll'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('have nowhere to go when no other table has a check', (tester) async {
      final t = await pumpCheck(tester, others: false);
      final (gesture, from) = await lot.pickUp(tester, 'Egg roll');
      await lot.dropOn(tester, gesture, from, 'move');
      expect(find.text('No other table has a check to move them to.'), findsOneWidget);
      expect(t.hub.sent, isEmpty);
      await stop(tester);
    });

    testWidgets('are offered Comp and Void alone on a hub older than moving', (tester) async {
      await pumpCheck(tester, moves: false);
      final (gesture, _) = await lot.pickUp(tester, 'Egg roll');
      expect(lot.target('move'), findsNothing);
      expect(lot.target('comp'), findsOneWidget);
      expect(lot.target('void'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      await stop(tester);
    });

    testWidgets('fit a phone: three places at the foot of the check, and the list of tables', (tester) async {
      await pumpCheck(tester, size: const Size(390, 844));
      await tester.tap(find.textContaining('Check')); // a phone shows the check and the menu as two tabs
      await tester.pumpAndSettle();
      final (gesture, from) = await lot.pickUp(tester, 'Egg roll');
      expect(lot.target('move'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await lot.dropOn(tester, gesture, from, 'move');
      expect(find.text('Move Egg roll to'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
