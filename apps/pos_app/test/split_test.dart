import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/split_screen.dart';
import 'package:pos_app/split.dart';

import 'bill_test.dart' show said;
import 'hub.dart';
import 'lot_test.dart' show priced;

/// Splitting a check (the Toast comparison's build list, row 2): a table pays on several checks without
/// becoming several orders. By seat in one tap, dishes picked and put on another check, a dish shared
/// between checks, the total in equal parts; a bill for each check. Which dish is on which check is worked
/// out here the hub's way so a tap shows at once; what a check comes to is the hub's to say.

Line dish(String id, String item, {int? seat, List<int>? checks, int qty = 1, String status = 'active'}) =>
    Line(lineId: id, item: item, qty: qty, status: status, seat: seat, checks: checks);

/// Tea for seat 1, duck for seat 2, two teas for seat 3 and a lobster for the table.
Order threeSeats({Object? split, Map<String, List<int>> checks = const {}, String status = 'open'}) => Order(
  orderId: 'o1',
  status: status,
  fields: {'table': '5', 'guests': 3, 'order_type': 'dine_in', 'split': ?split},
  lines: [
    dish('L1', 'Tea', seat: 1, checks: checks['L1']),
    dish('L2', 'Duck', seat: 2, checks: checks['L2']),
    dish('L3', 'Tea', seat: 3, qty: 2, checks: checks['L3']),
    dish('L4', 'Lobster', checks: checks['L4']),
  ],
  fired: const {},
);

const bySeat = {'by': 'seat'};
const byDish = {'by': 'dish'};

/// The hub's check for [threeSeats]: 75.00 and 5.25 tax, with whatever it says of the table's checks.
Check hubCheck({Object? split, List<Map<String, dynamic>> checks = const []}) => Check.fromJson({
  'lines': [
    priced('L1', 'Tea', '10.00'),
    priced('L2', 'Duck', '20.00'),
    {...priced('L3', 'Tea', '20.00'), 'qty': 2},
    priced('L4', 'Lobster', '25.00'),
  ],
  'subtotal': '75.00',
  'tax_lines': [
    {'name': 'Meals tax', 'rate_pct': '7.00', 'amount': '5.25'},
  ],
  'tax_rate_pct': '7.00',
  'tax': '5.25',
  'total': '80.25',
  'split': split,
  'checks': checks,
});

/// One check as the hub lists it: its number, total and dishes (line id -> the other checks it is shared with).
Map<String, dynamic> part(int number, String total, Map<String, List<int>> lines) => {
  'check': number,
  'total': total,
  'lines': [
    for (final MapEntry(:key, :value) in lines.entries) {'line_id': key, 'shared': value, 'total': '0.00'},
  ],
};

/// The hub's three checks of [threeSeats] by seat.
final seatChecks = [
  part(1, '19.63', {
    'L1': [],
    'L4': [2, 3],
  }),
  part(2, '30.31', {
    'L2': [],
    'L4': [1, 3],
  }),
  part(3, '30.31', {
    'L3': [],
    'L4': [1, 2],
  }),
];

/// The split screen over an order kept here: what it sends is laid over the order as the order screen does,
/// so the screen shows what its own taps did. The hub's check stays what the test says it is.
class Harness extends ChangeNotifier {
  Harness(this.order, this.check);

  Order order;
  Check? check;
  bool billing = false;
  final sent = <SplitOp>[];
  final billed = <int?>[];

  Future<void> append(List<SplitOp> ops) async {
    sent.addAll(ops);
    order = withLocalOps(order, [
      for (final (kind, data) in ops) {'kind': kind, 'data': data},
    ]);
    notifyListeners();
  }

  void hub(Check answer) {
    check = answer;
    notifyListeners();
  }
}

Future<Harness> pumpSplit(WidgetTester tester, Order order, {Check? check, Size size = const Size(390, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final table = Harness(order, check ?? hubCheck());
  await tester.pumpWidget(
    MaterialApp(
      home: SplitScreen(
        changes: table,
        read: () => SplitView(order: table.order, check: table.check, billing: table.billing),
        onOps: table.append,
        onBill: (check) async => table.billed.add(check),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return table;
}

Finder card(int number) => find.byKey(ValueKey('split-check:$number'));
Finder row(int number, String lineId) => find.byKey(ValueKey('split-line:$number:$lineId'));
Finder key(String name) => find.byKey(ValueKey(name));

/// The dishes on a check's card, by line id, top to bottom.
List<String> onCard(WidgetTester tester, int number) => [
  for (final element
      in find
          .descendant(
            of: card(number),
            matching: find.byWidgetPredicate((w) => w is InkWell && w.key is ValueKey<String>),
          )
          .evaluate())
    ((element.widget.key! as ValueKey<String>).value).split(':').last,
];

/// Operations as plain lists, to compare by what they say: a record holding a map is equal only to itself.
List<List<Object?>> plain(List<SplitOp> ops) => [
  for (final (kind, data) in ops) [kind, data],
];

String totalOf(WidgetTester tester, int number) => tester.widget<Text>(key('split-total:$number')).data!;

/// Whether one of the ways at the top of the screen can be tapped.
bool offered(WidgetTester tester, String name) =>
    tester
        .widget<ButtonStyleButton>(find.descendant(of: key(name), matching: find.bySubtype<ButtonStyleButton>()))
        .onPressed !=
    null;

Future<void> tap(WidgetTester tester, Finder what) async {
  // on the split screen a check further down is scrolled to first (on the order screen that would move
  // its two tabs as well)
  if (find.byType(SplitScreen).evaluate().isNotEmpty) {
    await tester.ensureVisible(what);
    await tester.pumpAndSettle();
  }
  await tester.tap(what);
  await tester.pumpAndSettle();
}

void main() {
  group('which dish is on which check', () {
    test('a table is one check until its order says otherwise', () {
      expect(placedOn(threeSeats()).isSplit, isFalse);
      expect(checksOf(threeSeats()), 1);
      // dishes put on checks count for nothing while the order is not split
      expect(
        placedOn(
          threeSeats(
            checks: {
              'L2': [2],
            },
          ),
        ).numbers,
        isEmpty,
      );
      // and whatever cannot be read is one check
      for (final junk in [
        'seat',
        3,
        {'by': 'table'},
        {'by': 'even', 'ways': 1},
        {'by': 'even', 'ways': 21},
      ]) {
        expect(SplitMode.of(junk), SplitMode.one, reason: '$junk');
      }
    });

    test('by seat: a check for each seat, the dishes for the table shared by all', () {
      final placed = placedOn(threeSeats(split: bySeat));
      expect(placed.numbers, [1, 2, 3]);
      expect(placed.on, {
        'L1': [1],
        'L2': [2],
        'L3': [3],
        'L4': [1, 2, 3],
      });
      expect(checksOf(threeSeats(split: bySeat)), 3);
    });

    test('a seat with nothing of its own has no check, and a table with no dish on a seat no checks', () {
      final order = Order(
        orderId: 'o1',
        status: 'open',
        fields: const {'table': '5', 'guests': 4, 'split': bySeat},
        lines: [dish('L1', 'Tea', seat: 1), dish('L2', 'Duck', seat: 4), dish('L3', 'Lobster')],
        fired: const {},
      );
      expect(placedOn(order).numbers, [1, 4]);
      expect(placedOn(order).on['L3'], [1, 4]);
      final unseated = Order(
        orderId: 'o1',
        status: 'open',
        fields: const {'table': '5', 'split': bySeat},
        lines: [dish('L1', 'Tea'), dish('L2', 'Duck')],
        fired: const {},
      );
      expect(placedOn(unseated).isSplit, isFalse);
      expect(checksOf(unseated), 1);
    });

    test('by hand: a dish is where it was put, the rest on check 1; a dish taken off is on none', () {
      final order = Order(
        orderId: 'o1',
        status: 'open',
        fields: const {'table': '5', 'split': byDish},
        lines: [
          dish('L1', 'Tea', seat: 3),
          dish('L2', 'Duck', checks: [2]),
          dish('L3', 'Lobster', checks: [1, 2]),
          dish('L4', 'Soup', checks: [5], status: 'removed'),
        ],
        fired: const {},
      );
      final placed = placedOn(order);
      expect(placed.numbers, [1, 2]);
      expect(placed.on, {
        'L1': [1],
        'L2': [2],
        'L3': [1, 2],
      });
      expect(placed.next, 3);
    });

    test('an even split has parts, not checks of dishes', () {
      final order = threeSeats(split: {'by': 'even', 'ways': 4});
      expect(placedOn(order).numbers, isEmpty);
      expect(checksOf(order), 4);
    });

    test('equal parts add up, the odd cents on the first', () {
      expect(equalParts(2500, 3), [834, 833, 833]);
      expect(equalParts(2, 3), [1, 1, 0]);
      expect(partOf('25.00', [1, 2, 3], 1), '8.34');
      expect(partOf('25.00', [1, 2, 3], 3), '8.33');
      expect(partOf('25.00', [2], 2), '25.00');
      expect(partOf('25.00', [2], 1), '0.00');
    });

    test('the numbers a dish is put on are kept as the hub keeps them', () {
      expect(checkNumbers([3, 3, 2]), [2, 3]);
      expect(checkNumbers(4), [4]);
      for (final junk in [
        null,
        <int>[],
        '2',
        [0, -1, 21],
        [true],
      ]) {
        expect(checkNumbers(junk), isNull, reason: '$junk');
      }
    });
  });

  group('what a gesture sends', () {
    test('the first dish put on another check starts the split by hand', () {
      final order = threeSeats(
        checks: {
          'L1': [3], // left over from a split undone on an older app: forgotten as this one starts
        },
      );
      expect(
        plain(putOps(order, [order.lines[1]], [2])),
        plain([
          ('set_line', {'line_id': 'L1', 'checks': null}),
          (
            'set_field',
            {
              'split': {'by': 'dish'},
            },
          ),
          (
            'set_line',
            {
              'line_id': 'L2',
              'checks': [2],
            },
          ),
        ]),
      );
    });

    test('on a split table a dish just changes checks, or is shared between several', () {
      final order = threeSeats(split: bySeat);
      expect(
        plain(putOps(order, [order.lines[0], order.lines[1]], [3])),
        plain([
          (
            'set_line',
            {
              'line_id': 'L1',
              'checks': [3],
            },
          ),
          (
            'set_line',
            {
              'line_id': 'L2',
              'checks': [3],
            },
          ),
        ]),
      );
      expect(
        plain(putOps(order, [order.lines[3]], [2, 1])),
        plain([
          (
            'set_line',
            {
              'line_id': 'L4',
              'checks': [1, 2],
            },
          ),
        ]),
      );
      expect(putOps(order, [order.lines[3]], const []), isEmpty);
    });

    test('by seat, evenly and one check each start from the dishes as they were rung in', () {
      final order = threeSeats(
        split: byDish,
        checks: {
          'L2': [2],
        },
      );
      const back = ('set_line', {'line_id': 'L2', 'checks': null});
      expect(
        plain(bySeatOps(order)),
        plain([
          back,
          (
            'set_field',
            {
              'split': {'by': 'seat'},
            },
          ),
        ]),
      );
      expect(
        plain(evenOps(order, 4)),
        plain([
          back,
          (
            'set_field',
            {
              'split': {'by': 'even', 'ways': 4},
            },
          ),
        ]),
      );
      expect(evenOps(order, 1).last.$2, {
        'split': {'by': 'even', 'ways': 2},
      });
      expect(
        plain(oneCheckOps(order)),
        plain([
          back,
          ('set_field', {'split': null}),
        ]),
      );
    });

    test('this screen shows a dish on its new check before the hub answers', () {
      final order = threeSeats(split: bySeat);
      final moved = withLocalOps(order, [
        {
          'kind': 'set_line',
          'data': {
            'line_id': 'L2',
            'checks': [1],
          },
        },
      ]);
      expect(moved.lines[1].checks, [1]);
      expect(moved.lines[1].seat, 2); // the dish keeps its seat: nothing for the kitchen
      expect(placedOn(moved).numbers, [1, 3]);
      final back = withLocalOps(moved, [
        {
          'kind': 'set_line',
          'data': {'line_id': 'L2', 'checks': null},
        },
      ]);
      expect(back.lines[1].checks, isNull);
      // an edit voids a dish and adds the changed one, which stays on the check the dish was put on
      final edited = withLocalOps(moved, [
        {
          'kind': 'void_line',
          'data': {'line_id': 'L2'},
        },
        {
          'kind': 'add_line',
          'data': {'line_id': 'L2b', 'item': 'Duck', 'seat': 2, 'replaces': 'L2'},
        },
      ]);
      expect(edited.lines.last.checks, [1]);
    });

    test('the check says how the table is split and what each check comes to', () {
      final check = hubCheck(split: bySeat, checks: seatChecks);
      expect(check.splits, isTrue);
      expect(check.split, const SplitMode('seat'));
      expect([for (final p in check.parts) (p.number, p.total)], [(1, '19.63'), (2, '30.31'), (3, '30.31')]);
      expect(check.part(2)!.lines.last.shared, [1, 3]);
      expect(check.part(9), isNull);
      // a hub older than splitting says nothing of checks
      final old = Check.fromJson(const {'lines': [], 'subtotal': '0.00', 'tax': '0.00', 'total': '0.00'});
      expect(old.splits, isFalse);
      expect(old.parts, isEmpty);
      expect(old.split, SplitMode.one);
    });
  });

  group('the split screen', () {
    testWidgets('a table on one check lists its dishes and says how to split them', (tester) async {
      final table = await pumpSplit(tester, threeSeats());
      expect(find.text('One check'), findsNWidgets(2)); // the way in force at the top, and the card
      expect(onCard(tester, 1), ['L1', 'L2', 'L3', 'L4']);
      expect(totalOf(tester, 1), '\$80.25');
      expect(find.textContaining('Tap dishes to pick them'), findsOneWidget);
      expect(find.text('Print the bill'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, key('split-bill-all'));
      expect(table.billed, [null]);
    });

    testWidgets('by seat is one tap: a check for each seat, the table\'s dish shared', (tester) async {
      final table = await pumpSplit(tester, threeSeats());
      await tap(tester, key('split-by-seat'));
      expect(
        plain(table.sent),
        plain([
          (
            'set_field',
            {
              'split': {'by': 'seat'},
            },
          ),
        ]),
      );
      expect(
        [onCard(tester, 1), onCard(tester, 2), onCard(tester, 3)],
        [
          ['L1', 'L4'],
          ['L2', 'L4'],
          ['L3', 'L4'],
        ],
      );
      // each check's part of the lobster, and who else has it
      expect(find.descendant(of: row(1, 'L4'), matching: find.text('8.34')), findsOneWidget);
      expect(find.descendant(of: row(2, 'L4'), matching: find.text('8.33')), findsOneWidget);
      expect(
        find.descendant(of: row(2, 'L4'), matching: find.text('1/3 of 25.00, shared with checks 1, 3')),
        findsOneWidget,
      );
      // what a check comes to is the hub's to say: nothing until it has reckoned these same checks
      expect(totalOf(tester, 2), '…');
      table.hub(hubCheck(split: bySeat, checks: seatChecks));
      await tester.pumpAndSettle();
      expect([totalOf(tester, 1), totalOf(tester, 2), totalOf(tester, 3)], ['\$19.63', '\$30.31', '\$30.31']);
      expect(find.text('The table, on 3 checks'), findsOneWidget);
      expect(find.text('Print 3 bills'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picked dishes go to another check, and its total waits for the hub again', (tester) async {
      final table = await pumpSplit(
        tester,
        threeSeats(split: bySeat),
        check: hubCheck(split: bySeat, checks: seatChecks),
      );
      await tap(tester, row(1, 'L1'));
      await tap(tester, row(3, 'L3'));
      expect(find.text('2 dishes picked. Put them on:'), findsOneWidget);
      await tap(tester, key('split-to:2'));
      expect(
        plain(table.sent),
        plain([
          (
            'set_line',
            {
              'line_id': 'L1',
              'checks': [2],
            },
          ),
          (
            'set_line',
            {
              'line_id': 'L3',
              'checks': [2],
            },
          ),
        ]),
      );
      // seats 1 and 3 have nothing of their own now: the table is one check again, with every dish on it
      expect(find.text('One check'), findsNWidgets(2));
      expect(onCard(tester, 2), ['L1', 'L2', 'L3', 'L4']);
      expect(find.textContaining('picked'), findsNothing);
    });

    testWidgets('a dish in hand can be put back down', (tester) async {
      final table = await pumpSplit(tester, threeSeats(split: bySeat));
      await tap(tester, row(1, 'L1'));
      expect(find.text('1 dish picked. Put it on:'), findsOneWidget);
      await tap(tester, row(1, 'L1')); // a second tap lets it go
      expect(find.textContaining('picked'), findsNothing);
      await tap(tester, row(2, 'L2'));
      await tap(tester, key('split-clear'));
      expect(find.textContaining('picked'), findsNothing);
      expect(table.sent, isEmpty);
    });

    testWidgets('a new check takes the dishes in hand', (tester) async {
      final table = await pumpSplit(tester, threeSeats());
      await tap(tester, row(1, 'L2'));
      // a table on one check has no other check to go to yet
      expect(key('split-to:1'), findsNothing);
      await tap(tester, key('split-to:new'));
      expect(
        plain(table.sent),
        plain([
          (
            'set_field',
            {
              'split': {'by': 'dish'},
            },
          ),
          (
            'set_line',
            {
              'line_id': 'L2',
              'checks': [2],
            },
          ),
        ]),
      );
      expect(
        [onCard(tester, 1), onCard(tester, 2)],
        [
          ['L1', 'L3', 'L4'],
          ['L2'],
        ],
      );
      // and a third
      await tap(tester, row(1, 'L3'));
      await tap(tester, key('split-to:new'));
      expect(
        plain([table.sent.last]),
        plain([
          (
            'set_line',
            {
              'line_id': 'L3',
              'checks': [3],
            },
          ),
        ]),
      );
      expect(onCard(tester, 3), ['L3']);
    });

    testWidgets('a dish is shared between the checks picked, a new one among them', (tester) async {
      final table = await pumpSplit(
        tester,
        threeSeats(
          split: byDish,
          checks: {
            'L2': [2],
          },
        ),
      );
      await tap(tester, row(1, 'L4'));
      await tap(tester, key('split-share'));
      expect(find.text('Share between'), findsOneWidget);
      // it starts as shared by every check there is
      expect(find.text('Share between 2'), findsOneWidget);
      await tap(tester, key('share-more'));
      expect(find.text('Check 3'), findsOneWidget);
      await tap(tester, key('share:1')); // not check 1 after all
      expect(find.text('Share between 2'), findsOneWidget);
      await tap(tester, key('share:1'));
      await tap(tester, key('share-done'));
      expect(
        plain(table.sent),
        plain([
          (
            'set_line',
            {
              'line_id': 'L4',
              'checks': [1, 2, 3],
            },
          ),
        ]),
      );
      expect(onCard(tester, 3), ['L4']);
      expect(find.descendant(of: row(3, 'L4'), matching: find.text('8.33')), findsOneWidget);
    });

    testWidgets('one check alone cannot share a dish: two or more', (tester) async {
      await pumpSplit(tester, threeSeats());
      await tap(tester, row(1, 'L4'));
      await tap(tester, key('split-share'));
      expect(find.text('Pick two checks or more'), findsOneWidget);
      expect(tester.widget<FilledButton>(key('share-done')).onPressed, isNull);
    });

    testWidgets('evenly: as many parts as guests to start, more or fewer by a tap', (tester) async {
      final table = await pumpSplit(tester, threeSeats());
      await tap(tester, key('split-evenly'));
      expect(
        plain([table.sent.single]),
        plain([
          (
            'set_field',
            {
              'split': {'by': 'even', 'ways': 3},
            },
          ),
        ]),
      );
      expect(find.text('3 ways'), findsOneWidget);
      // 80.25 in three is 26.75 each
      expect(find.descendant(of: key('even-part:1'), matching: find.text('\$26.75')), findsOneWidget);
      await tap(tester, key('even-more'));
      expect(table.sent.last.$2, {
        'split': {'by': 'even', 'ways': 4},
      });
      // in four: the odd cent on the first part
      expect(find.descendant(of: key('even-part:1'), matching: find.text('\$20.07')), findsOneWidget);
      expect(find.descendant(of: key('even-part:4'), matching: find.text('\$20.06')), findsOneWidget);
      expect(find.text('Print 4 bills'), findsOneWidget);
      await tap(tester, key('split-bill:2'));
      await tap(tester, key('split-bill-all'));
      expect(table.billed, [2, null]);
      await tap(tester, key('even-less'));
      await tap(tester, key('even-less'));
      expect(find.text('2 ways'), findsOneWidget);
      expect(tester.widget<IconButton>(key('even-less')).onPressed, isNull); // two is the least
      expect(tester.takeException(), isNull);
    });

    testWidgets('the hub\'s own parts stand once it has cut the total', (tester) async {
      final table = await pumpSplit(tester, threeSeats(split: {'by': 'even', 'ways': 2}));
      expect(find.descendant(of: key('even-part:1'), matching: find.text('\$40.13')), findsOneWidget);
      table.hub(hubCheck(split: {'by': 'even', 'ways': 2}, checks: [part(1, '40.13', {}), part(2, '40.12', {})]));
      await tester.pumpAndSettle();
      expect(find.descendant(of: key('even-part:2'), matching: find.text('\$40.12')), findsOneWidget);
    });

    testWidgets('one check puts everything back together', (tester) async {
      final table = await pumpSplit(
        tester,
        threeSeats(
          split: bySeat,
          checks: {
            'L2': [1],
          },
        ),
      );
      expect(card(3), findsOneWidget);
      await tap(tester, key('split-one'));
      expect(
        plain(table.sent),
        plain([
          ('set_line', {'line_id': 'L2', 'checks': null}),
          ('set_field', {'split': null}),
        ]),
      );
      expect(find.text('One check'), findsNWidgets(2));
      expect(card(3), findsNothing);
    });

    testWidgets('each check has its own bill', (tester) async {
      final table = await pumpSplit(
        tester,
        threeSeats(split: bySeat),
        check: hubCheck(split: bySeat, checks: seatChecks),
      );
      await tap(tester, key('split-bill:2'));
      await tap(tester, key('split-bill-all'));
      expect(table.billed, [2, null]);
      // while a bill is on its way the buttons wait
      table
        ..billing = true
        ..hub(table.check!);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(key('split-bill:2')).onPressed, isNull);
      expect(tester.widget<FilledButton>(key('split-bill-all')).onPressed, isNull);
    });

    testWidgets('by seat waits for dishes rung in on seats', (tester) async {
      final order = Order(
        orderId: 'o1',
        status: 'open',
        fields: const {'table': '5', 'guests': 2},
        lines: [dish('L1', 'Tea'), dish('L2', 'Duck')],
        fired: const {},
      );
      await pumpSplit(tester, order);
      expect(offered(tester, 'split-by-seat'), isFalse);
      expect(offered(tester, 'split-evenly'), isTrue);
      expect(find.textContaining('By seat needs dishes rung in on seats.'), findsOneWidget);
    });

    testWidgets('a to-go order has no seats to split by', (tester) async {
      final order = Order(
        orderId: 'o1',
        status: 'open',
        fields: const {'order_type': 'takeout', 'order_no': 7},
        lines: [dish('L1', 'Tea'), dish('L2', 'Duck')],
        fired: const {},
      );
      final table = await pumpSplit(tester, order);
      expect(key('split-by-seat'), findsNothing);
      await tap(tester, key('split-evenly'));
      expect(table.sent.single.$2, {
        'split': {'by': 'even', 'ways': 2},
      });
    });

    testWidgets('a closed check shows its split and prints its bills, and changes nothing', (tester) async {
      final table = await pumpSplit(
        tester,
        threeSeats(split: bySeat, status: 'closed'),
        check: hubCheck(split: bySeat, checks: seatChecks),
      );
      await tap(tester, row(1, 'L1'));
      expect(find.textContaining('picked'), findsNothing);
      expect((offered(tester, 'split-evenly'), offered(tester, 'split-one')), (false, false));
      await tap(tester, key('split-bill:3'));
      expect(table.sent, isEmpty);
      expect(table.billed, [3]);
    });

    testWidgets('a dish another screen took off leaves the hand', (tester) async {
      final table = await pumpSplit(tester, threeSeats(split: bySeat));
      await tap(tester, row(2, 'L2'));
      expect(find.text('1 dish picked. Put it on:'), findsOneWidget);
      table.order = withLocalOps(table.order, [
        {
          'kind': 'void_line',
          'data': {'line_id': 'L2'},
        },
      ]);
      table.hub(table.check!);
      await tester.pumpAndSettle();
      expect(find.textContaining('picked'), findsNothing);
      expect(card(2), findsNothing); // seat 2 has nothing left: no check
    });

    testWidgets('the checks stand side by side on a tablet and one under the other on a phone', (tester) async {
      await pumpSplit(tester, threeSeats(split: bySeat), size: const Size(1100, 800));
      expect(tester.getTopLeft(card(2)).dy, tester.getTopLeft(card(1)).dy);
      expect(tester.getTopLeft(card(2)).dx, greaterThan(tester.getTopRight(card(1)).dx));
      expect(tester.takeException(), isNull);
      await pumpSplit(tester, threeSeats(split: bySeat), size: const Size(360, 640));
      expect(tester.getTopLeft(card(2)).dy, greaterThan(tester.getBottomLeft(card(1)).dy));
      expect(tester.getTopLeft(card(2)).dx, tester.getTopLeft(card(1)).dx);
      expect(tester.takeException(), isNull);
    });
  });

  group('on the order screen', () {
    final split = find.byKey(const ValueKey('split'));

    /// Table A1 with an egg roll and a duck for seat 1 and a tea for seat 2, on a hub that knows of splitting.
    Future<Terminal> pumpOrder(
      WidgetTester tester, {
      Size size = const Size(390, 800),
      bool old = false,
      bool bySeats = false,
    }) async {
      final t = await terminal(tester);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      t.hub.check = {
        'lines': [
          priced('L1', 'Egg roll', '3.00'),
          priced('L2', 'Peking Duck', '48.00'),
          priced('L3', 'Hot tea', '2.50'),
        ],
        'subtotal': '53.50',
        'tax_lines': [
          {'name': 'Meals tax', 'rate_pct': '7.00', 'amount': '3.75'},
        ],
        'tax_rate_pct': '7.00',
        'tax': '3.75',
        'total': '57.25',
        if (!old) 'split': bySeats ? bySeat : null,
        if (!old)
          'checks': [
            if (bySeats) ...[
              part(1, '54.57', {'L1': [], 'L2': []}),
              part(2, '2.68', {'L3': []}),
            ],
          ],
      };
      t.hub.orders.add(
        table('o1', {
          'L1': line('Egg roll', rank: 1),
          'L2': line('Peking Duck', fired: true, rank: 2),
          'L3': {...line('Hot tea', fired: true, rank: 3), 'seat': 2},
        }),
      );
      if (bySeats) (t.hub.orders.single['fields'] as Map)['split'] = bySeat;
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
        ),
      );
      await tester.pumpAndSettle();
      if (size.width < 720) {
        await tester.tap(find.textContaining('Check '));
        await tester.pumpAndSettle();
      }
      return t;
    }

    testWidgets('a Split button stands beside the total, before the Bill button', (tester) async {
      await pumpOrder(tester);
      expect(split, findsOneWidget);
      expect(find.descendant(of: split, matching: find.text('Split')), findsOneWidget);
      final bill = find.byKey(const ValueKey('bill'));
      expect(tester.getCenter(split).dy, tester.getCenter(bill).dy);
      expect(tester.getTopRight(split).dx, lessThan(tester.getTopLeft(bill).dx));
      // the amount keeps the right edge, as on every other row of the foot
      expect(tester.getTopRight(find.text('57.25')).dx, tester.getTopRight(find.text('53.50')).dx);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a check too narrow for them the buttons take the row above the total', (tester) async {
      await pumpOrder(tester, size: const Size(800, 900), bySeats: true);
      expect(find.descendant(of: split, matching: find.text('Split 2')), findsOneWidget);
      expect(find.byKey(const ValueKey('bill')), findsOneWidget);
      // no room beside the total there (the test's type is twice as wide as the real one): the buttons
      // take the row above it, and nothing runs off the check
      final bill = find.byKey(const ValueKey('bill'));
      expect(tester.getBottomLeft(split).dy, lessThanOrEqualTo(tester.getTopLeft(find.text('57.25')).dy));
      expect(tester.getTopRight(bill).dx, tester.getTopRight(find.text('57.25')).dx);
      expect(tester.getTopRight(find.text('57.25')).dx, tester.getTopRight(find.text('53.50')).dx);
      final panel = tester.getRect(find.byKey(const ValueKey('check-rows')));
      expect(tester.getTopLeft(split).dx, greaterThanOrEqualTo(panel.left));
      expect(tester.getTopRight(bill).dx, lessThanOrEqualTo(panel.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hub older than splitting gets no Split button', (tester) async {
      await pumpOrder(tester, old: true);
      expect(split, findsNothing);
      expect(find.byKey(const ValueKey('bill')), findsOneWidget);
    });

    testWidgets('a split made on the split screen goes to the hub and shows on the check', (tester) async {
      final t = await pumpOrder(tester);
      await tap(tester, split);
      expect(find.text('Split · Table A1'), findsOneWidget);
      await tap(tester, key('split-by-seat'));
      await tester.pumpAndSettle();
      expect(t.hub.batches.last, hasLength(1));
      expect(t.hub.batches.last.single['kind'], 'set_field');
      expect(t.hub.batches.last.single['data'], {
        'split': {'by': 'seat'},
      });
      expect(
        [onCard(tester, 1), onCard(tester, 2)],
        [
          ['L1', 'L2'],
          ['L3'],
        ],
      );
      // the duck goes on seat 2's check: the kitchen has it, and hears nothing
      await tap(tester, row(1, 'L2'));
      await tap(tester, key('split-to:2'));
      await tester.pumpAndSettle();
      final moved = t.hub.batches.last.single;
      expect(moved['kind'], 'set_line');
      expect(moved['data'], {
        'line_id': 'L2',
        'checks': [2],
      });
      expect(t.hub.sent.where((s) => s.$2['kind'] == 'void_line' || s.$2['kind'] == 'add_line'), isEmpty);
      expect(onCard(tester, 2), ['L2', 'L3']);

      await tap(tester, find.byTooltip('Close'));
      // back on the check: each dish says its check, and the button how many there are
      expect(find.descendant(of: split, matching: find.text('Split 2')), findsOneWidget);
      expect(find.textContaining('check 1'), findsOneWidget);
      expect(find.textContaining('check 2'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Bill button on a split table prints a bill for each check', (tester) async {
      final t = await pumpOrder(tester, bySeats: true);
      expect(find.descendant(of: split, matching: find.text('Split 2')), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('bill')));
      expect(find.text('2 bills are printing at Takeout'), findsOneWidget);
      expect(t.hub.bills, [('o1', null)]);
      expect(t.hub.billChecks, [null]);
      await said(tester);

      // one check's bill, from the split screen
      await tap(tester, split);
      expect([totalOf(tester, 1), totalOf(tester, 2)], ['\$54.57', '\$2.68']);
      await tap(tester, key('split-bill:2'));
      expect(find.text("Check 2's bill is printing at Takeout"), findsOneWidget);
      expect(t.hub.billChecks, [null, 2]);
    });
  });
}
