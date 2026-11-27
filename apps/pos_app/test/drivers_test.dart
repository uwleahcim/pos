import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/deliveries.dart';
import 'package:pos_app/powers.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/deliveries_screen.dart';
import 'package:pos_app/screens/driver_picker.dart';
import 'package:pos_app/screens/powers_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/takeout.dart';

import 'catering_test.dart' show dataOf, eventAt, kinds, said, tapKey;
import 'delivery_test.dart' show bell, elm, key, order, pumpOrder, soon, stand;
import 'hub.dart';
import 'powers_test.dart' show lit, pumpPowers, wholeTable;

/// Drivers (docs/delivery.md): a delivery is handed to a driver and is out with them until it was delivered
/// or came back. The list of checks asks who takes it, and the Deliveries screen says what waits to leave
/// and what each driver has out. The hub keeps who delivers, texts the customer once and writes the
/// history (backend/tests/orders/test_drivers.py); these tests are about what the screens say and send.

const tom = StaffMember(staffId: 'd1', name: 'Tom', role: 'driver', delivers: true);
const wei = StaffMember(staffId: 'd2', name: 'Wei', role: 'driver', delivers: true);
const mike = StaffMember(staffId: 's3', name: 'Mike', role: 'manager', takesTables: true, delivers: true);

/// A delivery as the hub lists it: number [no], for [name] at [address], and where it stands. One that is
/// out says with whom ([driver]) and since when ([left], minutes before [soon]).
Map<String, dynamic> bag(
  String id,
  int no, {
  String name = 'Linda',
  String address = elm,
  String stage = 'ready',
  bool sent = true,
  bool later = false,
  StaffMember? driver,
  int left = 30,
  String? due,
}) {
  final o = order(
    id: id,
    delivery: true,
    sent: sent,
    later: later,
    stage: driver == null ? stage : 'out',
    address: address,
  );
  final fields = o['fields'] as Map<String, dynamic>;
  fields['order_no'] = no;
  fields['customer_name'] = name;
  if (driver != null) {
    fields['driver'] = driver.name;
    fields['driver_id'] = driver.staffId;
    fields['out_at'] = soon.subtract(Duration(minutes: left)).millisecondsSinceEpoch;
  }
  if (due != null) o['due'] = due;
  return o;
}

Order read(Map<String, dynamic> json) => Order.fromJson(json);

/// The Deliveries screen, opened from the menu of the list of checks, with [who] signed in on a hub whose
/// staff has drivers.
Future<Terminal> pumpDeliveries(
  WidgetTester tester,
  List<Map<String, dynamic>> orders, {
  Staff who = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin'),
  Size? size,
  double? type,
}) async {
  final t = await stand(tester, size: size);
  t.session.staff = who;
  t.hub
    ..withDrivers()
    ..keepsStages = true
    ..orders.addAll(orders);
  if (type != null) {
    tester.platformDispatcher.textScaleFactorTestValue = type;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await pumpOrdersOn(tester, t);
  await openDeliveries(tester);
  return t;
}

/// Deliveries, from the row of a wide screen or from More on a phone.
Future<void> openDeliveries(WidgetTester tester) async {
  await openHome(tester, 'deliveries');
  await tester.pumpAndSettle();
  expect(find.byType(DeliveriesScreen), findsOneWidget);
}

/// The cards the screen shows, top to bottom: the ids of the orders [kind] ("waiting" or "out").
List<String> cards(WidgetTester tester, String kind) => [
  for (final card in tester.widgetList(
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('$kind-')),
  ))
    (card.key! as ValueKey<String>).value.substring(kind.length + 1),
];

String words(WidgetTester tester, String name) => [
  for (final text in tester.widgetList<Text>(find.descendant(of: key(name), matching: find.byType(Text))))
    text.data ?? '',
].join(' | ');

/// The title of one of the two lists: "Waiting · 3".
String heading(WidgetTester tester, String name) =>
    tester.widget<Text>(find.descendant(of: key(name), matching: find.byType(Text)).first).data!;

void main() {
  final now = soon.subtract(const Duration(minutes: 20));

  group('what is out', () {
    test('an order is out when it is a delivery that left, and says with whom and since when', () {
      final out = read(bag('o1', 7, driver: tom));
      expect((out.isOut, out.driver, out.driverId), (true, 'Tom', 'd1'));
      expect(out.outAt, soon.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch);
      final ready = read(bag('o2', 8));
      expect((ready.isOut, ready.driver, ready.driverId, ready.outAt), (false, '', '', null));
      // an order the customer comes for is never out, whatever its step was written as
      final pickup = read(order(stage: 'out', sent: true));
      expect(pickup.isOut, isFalse);
      expect(stageLabel('out', delivery: true), 'Out');
      expect(stageLabel('out'), '');
    });

    test('the staff list says who a delivery can be handed to; an older hub says nobody', () {
      final roster = Roster.fromJson({
        'staff': [
          {'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'takes_tables': true, 'delivers': false},
          {'staff_id': 's3', 'name': 'Mike', 'role': 'manager', 'takes_tables': true, 'delivers': true},
          {'staff_id': 'd1', 'name': 'Tom', 'role': 'driver', 'delivers': true},
        ],
      });
      expect([for (final d in roster.drivers) d.name], ['Mike', 'Tom']);
      expect([for (final s in roster.servers) s.name], ['Amy', 'Mike']);
      final older = Roster.fromJson({
        'staff': [
          {'staff_id': 's3', 'name': 'Mike', 'role': 'manager', 'takes_tables': true},
        ],
      });
      expect(older.drivers, isEmpty);
    });

    test('handing one over says who has it and since when; taking it back says nobody has', () {
      expect(outFields(tom, 1234), {'stage': 'out', 'driver': 'Tom', 'driver_id': 'd1', 'out_at': 1234});
      expect(backFields, {'stage': 'ready', 'driver': null, 'driver_id': null});
    });

    test('where a delivery that has not left stands', () {
      final ready = read(bag('o1', 7));
      final cooking = read(bag('o2', 8, stage: 'new'));
      final unsent = read(bag('o3', 9, stage: 'new', sent: false));
      final later = read(bag('o4', 10, stage: 'new', sent: false, later: true));
      expect(
        [
          for (final o in [ready, cooking, unsent, later]) waitingStage(o, now),
        ],
        [Waiting.ready, Waiting.cooking, Waiting.later, Waiting.later],
      );
      expect(
        [
          for (final o in [ready, cooking, unsent, later]) canLeave(o, now),
        ],
        [true, true, false, false],
      );
      expect(waitingWords(ready, now), 'READY');
      expect(waitingWords(cooking, now), 'cooking');
      expect(waitingWords(unsent, now), 'not sent yet');
      expect(waitingWords(later, now), 'for ${whenFor(eventAt.millisecondsSinceEpoch, now)}');
    });

    test('the deliveries: what waits, packed first, and what each driver has out, the longest out first', () {
      final all = deliveriesOf([
        read(bag('w1', 11, stage: 'new')),
        read(bag('w2', 12)),
        read(bag('w3', 13, stage: 'new', sent: false)),
        read(bag('t1', 14, driver: tom, left: 10)),
        read(bag('t2', 15, driver: tom, left: 25)),
        read(bag('x1', 16, driver: wei, left: 40)),
        // none of these is one: the customer comes for it, it was delivered, it is a table's check
        read(order(id: 'p1', sent: true, stage: 'ready')),
        read(bag('c1', 17, stage: 'picked_up')),
        read(bag('c2', 18, driver: tom)..['status'] = 'closed'),
        read({
          'order_id': 'tb',
          'status': 'open',
          'fields': {'table': '12', 'order_type': 'dine_in'},
          'lines': <String, dynamic>{},
          'fired': <String, dynamic>{},
        }),
      ], now);
      expect([for (final o in all.waiting) o.orderId], ['w2', 'w1', 'w3']);
      expect(
        [
          for (final load in all.out) '${load.name}: ${[for (final o in load.orders) o.orderId].join(' ')}',
        ],
        ['Wei: x1', 'Tom: t2 t1'],
      );
      expect((all.outCount, all.has('d1'), all.has('d2'), all.has('s3'), all.isEmpty), (3, 2, 1, 0, false));
      expect(all.out.last.since, soon.subtract(const Duration(minutes: 25)).millisecondsSinceEpoch);
      // a driver looks for their own
      expect([for (final load in all.mineFirst('d1')) load.name], ['Tom', 'Wei']);
      expect([for (final load in all.mineFirst('s1')) load.name], ['Wei', 'Tom']);
      expect(deliveriesOf(const [], now).isEmpty, isTrue);
    });

    test('one that left with nobody named is still out, under no name', () {
      final nameless = bag('o1', 7)..['fields']['stage'] = 'out';
      final all = deliveriesOf([read(nameless)], now);
      expect(all.waiting, isEmpty);
      expect(
        [for (final load in all.out) (load.driverId, load.name, load.orders.length, load.since)],
        [('', '', 1, null)],
      );
    });

    test('how long a bag has been out, in words', () {
      final left = now.millisecondsSinceEpoch;
      expect(outFor(left, now.add(const Duration(seconds: 40))), 'just now');
      expect(outFor(left, now.add(const Duration(minutes: 12))), '12 min');
      expect(outFor(left, now.add(const Duration(minutes: 65))), '1 h 05');
    });

    test('the history says who it left with, a hand-over, and that it came back', () {
      String title(Map<String, dynamic> step) =>
          wordsOf(HistoryStep.fromJson({'op_id': 'x', ...step}), time: (ms) => '$ms').title;
      Map<String, dynamic> stage(String was, String now, [String? driver]) => {
        'what': 'stage',
        'was': was,
        'now': now,
        'delivery': true,
        'driver': ?driver,
      };
      expect(title(stage('ready', 'out', 'Tom')), 'Left with Tom');
      expect(title(stage('ready', 'out')), 'Left with a driver');
      expect(title(stage('out', 'ready')), 'Came back from the driver');
      expect(title(stage('out', 'picked_up')), 'Marked delivered');
      expect(title({'what': 'driver', 'was': 'Tom', 'now': 'Wei'}), 'Handed from Tom to Wei');
      expect(title({'what': 'driver', 'was': '', 'now': 'Wei'}), 'Handed to Wei');
    });
  });

  group('who takes deliveries out', () {
    test('a hub that knows of drivers hands them the deliveries; an older one is told nothing of them', () {
      expect(Powers.standard.holds('driver', 'deliver'), isTrue);
      expect(Powers.standard.holds('manager', 'deliver'), isTrue);
      expect(Powers.standard.holds('server', 'deliver'), isFalse);
      expect(Powers.standard.offered, handedRoles);
      expect(roleLabel('driver'), 'Drivers');

      final older = Powers.fromJson({
        'roles': {
          'void': <String>[],
          'take_tables': ['server', 'bartender'],
          'assign_tables': ['host'],
        },
        'handed': firstRoles,
      });
      expect((older.knows('deliver'), older.knows('void')), (false, true));
      expect(older.offered, firstRoles);
      expect(older.holds('driver', 'deliver'), isFalse);
      // as it started is what that hub hands out: no power and no role it has never heard of
      expect(older.asItStarted.roles.keys, isNot(contains('deliver')));
      expect(older.asItStarted.roles['take_tables'], ['server', 'bartender']);
      expect(older.summary, 'As it started: managers and owners approve and open the back office');
      // a hub that says nothing of its roles knows the first five
      expect(Powers.fromJson({'roles': <String, dynamic>{}}).offered, firstRoles);
      // handing a power out keeps what the hub knows
      expect(older.hand('void', 'bartender', on: true).offered, firstRoles);
    });

    testWidgets('the table offers the drivers and the deliveries on a hub that knows them', (tester) async {
      final t = await pumpPowers(tester, size: wholeTable);
      expect(find.text('Deliveries'), findsOneWidget);
      expect(find.text('Take deliveries out'), findsOneWidget);
      expect(lit(tester, 'deliver', 'driver'), isTrue);
      expect(lit(tester, 'deliver', 'server'), isFalse);
      // the servers take deliveries out here too
      await tapKey(tester, 'power:deliver:server');
      await tapKey(tester, 'powers-save');
      expect(t.hub.powers!['deliver'], ['server', 'driver']);
    });

    testWidgets('on a hub older than drivers it shows neither, and saves nothing that hub would refuse', (
      tester,
    ) async {
      final t = await pumpPowers(tester, size: wholeTable, hub: (hub) => hub.olderThanDrivers());
      expect(find.byType(PowersScreen), findsOneWidget);
      expect(find.text('Take deliveries out'), findsNothing);
      expect(find.text('Deliveries'), findsNothing);
      expect(find.widgetWithText(FilterChip, 'Drivers'), findsNothing);
      expect(find.widgetWithText(FilterChip, 'Bartenders'), findsNWidgets(16));
      await tapKey(tester, 'power:void:bartender');
      await tapKey(tester, 'powers-save');
      expect(t.hub.powers!['void'], ['bartender']);
      expect(t.hub.powers!.keys, isNot(contains('deliver')));
      for (final roles in t.hub.powers!.values) {
        expect(roles, isNot(contains('driver')));
      }
    });

    testWidgets('the picker: a button per driver with what they have out', (tester) async {
      StaffMember? picked;
      final out = deliveriesOf([read(bag('t1', 14, driver: tom)), read(bag('t2', 15, driver: tom))], now);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const ValueKey('ask'),
                onPressed: () async =>
                    picked = await DriverPicker.ask(context, drivers: const [mike, tom, wei], deliveries: out, bags: 2),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'ask');
      expect(find.text('Who takes these 2?'), findsOneWidget);
      expect(words(tester, 'driver:d1'), 'Tom | 2 out');
      expect(words(tester, 'driver:d2'), 'Wei | nothing out');
      expect(words(tester, 'driver:s3'), 'Mike | nothing out');
      expect(key('driver-picker-hint'), findsNothing); // drivers were named
      await tapKey(tester, 'driver:d2');
      expect(picked?.name, 'Wei');
      // Cancel hands it to nobody
      await tapKey(tester, 'ask');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(picked, isNull);
    });

    testWidgets('with only a manager to offer it says where drivers are named', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DriverPicker(drivers: const [mike], deliveries: deliveriesOf(const [], now)),
        ),
      );
      expect(find.text('Who takes it?'), findsOneWidget);
      expect(said(tester, 'driver-picker-hint'), 'Who takes deliveries out is set under Location › Who may do what.');
    });
  });

  group('the list of checks', () {
    testWidgets('a packed delivery goes Out with a driver, then is Delivered', (tester) async {
      final t = await stand(tester);
      t.hub
        ..withDrivers()
        ..keepsStages = true
        ..orders.addAll([bag('o1', 7), order(id: 'o2', sent: true, stage: 'ready')..['fields']['order_no'] = 8]);
      await pumpOrdersOn(tester, t);
      // the delivery leaves; the order the customer comes for is picked up, as before
      expect(find.widgetWithText(FilledButton, 'Out'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Picked up'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delivered'), findsNothing);

      await tapKey(tester, 'out-o1');
      expect(find.text('Who takes it?'), findsOneWidget);
      expect(words(tester, 'driver:d1'), 'Tom | nothing out');
      await tapKey(tester, 'driver:d1');
      expect(kinds(t.hub, 'o1'), ['set_field']);
      final left = dataOf(t.hub, 'set_field', 'o1');
      expect(
        (left['stage'], left['driver'], left['driver_id'], left['by'], left['by_id']),
        ('out', 'Tom', 'd1', 'Amy', 's1'),
      );
      expect(left['out_at'], isA<int>());

      // the list reads it back: who has it and since when, and the step left is that it was delivered
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      final at = clockTime(soon.millisecondsSinceEpoch);
      expect(
        find.text(
          '1 items · open · fired · there $at · pay at the door · OUT · Tom since ${clockTime(left['out_at'] as int)} · $elm',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Out'), findsNothing);
      await tapKey(tester, 'picked-up-o1');
      expect(kinds(t.hub, 'o1'), ['set_field', 'set_field', 'close']);
      expect(t.hub.opsFor('o1')[1]['data'], containsPair('stage', 'picked_up'));
      await stop(tester);
    });

    testWidgets('nobody picked: nothing is written', (tester) async {
      final t = await stand(tester);
      t.hub
        ..withDrivers()
        ..orders.add(bag('o1', 7));
      await pumpOrdersOn(tester, t);
      await tapKey(tester, 'out-o1');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.opsFor('o1'), isEmpty);
      await stop(tester);
    });

    testWidgets('the menu opens Deliveries where the hub says who delivers, and nowhere else', (tester) async {
      final t = await stand(tester);
      t.hub.withDrivers();
      await pumpOrdersOn(tester, t);
      expect(homeIds(tester), contains('deliveries'));
      await stop(tester);

      // a hub older than drivers: no entry, and a packed delivery is Delivered in one step, as it was
      final older = await stand(tester);
      older.hub
        ..olderThanDrivers()
        ..orders.add(bag('o1', 7));
      await pumpOrdersOn(tester, older);
      expect(homeIds(tester), isNot(contains('deliveries')));
      expect(find.widgetWithText(FilledButton, 'Out'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Delivered'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('one that another screen sent out still says so on a hub older than drivers', (tester) async {
      final t = await stand(tester);
      t.hub
        ..olderThanDrivers()
        ..orders.add(bag('o1', 7, driver: tom));
      await pumpOrdersOn(tester, t);
      expect(find.textContaining('OUT · Tom since'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delivered'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      final t = await stand(tester, size: const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      t.hub
        ..withDrivers()
        ..orders.add(bag('o1', 7));
      await pumpOrdersOn(tester, t);
      expect(find.widgetWithText(FilledButton, 'Out'), findsOneWidget);
      await tapKey(tester, 'out-o1');
      expect(find.text('Who takes it?'), findsOneWidget);
      expect(key('driver:d2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);

      // and one that is out, with its driver's name in the line under it
      final out = await stand(tester, size: const Size(320, 640));
      out.hub
        ..withDrivers()
        ..orders.add(bag('o2', 8, name: 'Diaz-Montgomery', driver: tom));
      await pumpOrdersOn(tester, out);
      expect(find.widgetWithText(FilledButton, 'Delivered'), findsOneWidget);
      expect(find.textContaining('OUT · Tom since'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('on the order', () {
    testWidgets('one that is out says with whom and since when', (tester) async {
      final o = bag('o1', 7, driver: tom);
      await pumpOrder(tester, o);
      final left = clockTime((o['fields'] as Map)['out_at'] as int);
      expect(find.textContaining('out with Tom since $left'), findsOneWidget);
    });
  });

  group('the Deliveries screen', () {
    testWidgets('what waits to leave, and what each driver has out', (tester) async {
      await pumpDeliveries(tester, [
        bag('w1', 11, name: 'Chen', address: '4 Oak Rd', stage: 'new'),
        bag('w2', 12, name: 'Park', address: '9 Main St'),
        bag('w3', 13, name: 'Lee', stage: 'new', sent: false),
        bag('t1', 14, name: 'Diaz', address: '1 Pond St', driver: tom, left: 10, due: '21.40'),
        bag('x1', 16, name: 'Shah', address: '7 Hill Ave', driver: wei, left: 40),
        order(id: 'p1', sent: true, stage: 'ready')..['fields']['order_no'] = 19,
      ]);
      expect(heading(tester, 'deliveries-waiting'), 'Waiting · 3');
      expect(heading(tester, 'deliveries-out'), 'Out · 2');
      expect(cards(tester, 'waiting'), ['w2', 'w1', 'w3']);
      expect(cards(tester, 'out'), ['x1', 't1']);
      final at = clockTime(soon.millisecondsSinceEpoch);
      expect(words(tester, 'waiting-w2'), '#12 Park | READY | 9 Main St | $bell | there $at · pay at the door');
      expect(words(tester, 'waiting-w1'), '#11 Chen | cooking | 4 Oak Rd | $bell | there $at · pay at the door');
      expect(words(tester, 'waiting-w3'), contains('not sent yet'));
      final left = clockTime(soon.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch);
      expect(
        words(tester, 'out-t1'),
        '#14 Diaz | 1 Pond St | $bell | 781 555 0101 · left $left · \$21.40 due | Delivered | Came back',
      );
      expect(words(tester, 'driver-load:d1'), 'Tom · 1 out · since $left');
      expect(find.text('#19 Linda'), findsNothing); // the customer comes for that one
      expect(key('deliveries-send'), findsNothing); // nothing was tapped to leave
      await stop(tester);
    });

    testWidgets('bags tapped together leave with one driver, as one run', (tester) async {
      final t = await pumpDeliveries(tester, [
        bag('w1', 11, stage: 'new'),
        bag('w2', 12),
        bag('w3', 13, stage: 'new', sent: false),
        bag('t1', 14, driver: tom),
      ]);
      // one the kitchen has not got cannot leave
      await tapKey(tester, 'waiting-w3');
      expect(key('deliveries-send'), findsNothing);
      await tapKey(tester, 'waiting-w2');
      expect(find.text('Out with…'), findsOneWidget);
      await tapKey(tester, 'waiting-w1');
      expect(find.text('2 out with…'), findsOneWidget);
      // a second tap lets one go again, and a third takes it back in
      await tapKey(tester, 'waiting-w1');
      expect(find.text('Out with…'), findsOneWidget);
      await tapKey(tester, 'waiting-w1');

      await tapKey(tester, 'deliveries-send');
      expect(find.text('Who takes these 2?'), findsOneWidget);
      expect(words(tester, 'driver:d1'), 'Tom | 1 out');
      await tapKey(tester, 'driver:d2');
      final first = dataOf(t.hub, 'set_field', 'w2');
      final second = dataOf(t.hub, 'set_field', 'w1');
      for (final sent in [first, second]) {
        expect(
          (sent['stage'], sent['driver'], sent['driver_id'], sent['by'], sent['by_id']),
          ('out', 'Wei', 'd2', 'Amy', 's1'),
        );
      }
      expect(first['out_at'], second['out_at']); // one run
      expect(t.hub.opsFor('w3'), isEmpty);
      expect(said(tester, 'deliveries-said-words'), '2 orders out with Wei.');

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(cards(tester, 'waiting'), ['w3']);
      expect(cards(tester, 'out'), ['t1', 'w1', 'w2']); // Wei's two in the order they were promised
      expect(words(tester, 'driver-load:d2'), 'Wei · 2 out · since ${clockTime(first['out_at'] as int)}');
      expect(key('deliveries-send'), findsNothing);
      await stop(tester);
    });

    testWidgets('one bag: the words say its number', (tester) async {
      await pumpDeliveries(tester, [bag('w2', 12)]);
      await tapKey(tester, 'waiting-w2');
      await tapKey(tester, 'deliveries-send');
      expect(find.text('Who takes it?'), findsOneWidget);
      await tapKey(tester, 'driver:d1');
      expect(said(tester, 'deliveries-said-words'), '#12 out with Tom.');
      await stop(tester);
    });

    testWidgets('Delivered closes the check; one with nothing due asks nothing', (tester) async {
      final t = await pumpDeliveries(tester, [bag('t1', 14, driver: tom), bag('t2', 15, driver: tom)]);
      await tapKey(tester, 'delivered-t1');
      expect(find.byType(AlertDialog), findsNothing);
      expect(kinds(t.hub, 't1'), ['set_field', 'close']);
      expect(dataOf(t.hub, 'set_field', 't1'), containsPair('stage', 'picked_up'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(cards(tester, 'out'), ['t2']);
      expect(heading(tester, 'deliveries-out'), 'Out · 1');
      await stop(tester);
    });

    testWidgets('Delivered with money still due asks for it first, as Picked up does', (tester) async {
      final t = await pumpDeliveries(tester, [bag('t1', 14, driver: tom, due: '21.40')]);
      await tapKey(tester, 'delivered-t1');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(t.hub.opsFor('t1'), isEmpty); // nothing until the money was answered
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.opsFor('t1'), isEmpty);
      expect(cards(tester, 'out'), ['t1']);
      await stop(tester);
    });

    testWidgets('Came back: it waits again, packed, and is nobody\'s', (tester) async {
      final t = await pumpDeliveries(tester, [bag('t1', 14, driver: tom)]);
      await tapKey(tester, 'back-t1');
      final back = dataOf(t.hub, 'set_field', 't1');
      expect((back['stage'], back['driver'], back['driver_id'], back['by']), ('ready', null, null, 'Amy'));
      expect(back.containsKey('driver'), isTrue);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(cards(tester, 'waiting'), ['t1']);
      expect(cards(tester, 'out'), isEmpty);
      expect(find.text('No driver has anything out.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a driver signed in finds their own bags first, as "You"', (tester) async {
      await pumpDeliveries(tester, [
        bag('t1', 14, driver: tom, left: 10),
        bag('x1', 16, driver: wei, left: 40),
      ], who: const Staff(staffId: 'd1', name: 'Tom', role: 'driver', method: 'pin'));
      expect(cards(tester, 'out'), ['t1', 'x1']);
      expect(words(tester, 'driver-load:d1'), startsWith('You · 1 out'));
      expect(words(tester, 'driver-load:d2'), startsWith('Wei · 1 out'));
      await stop(tester);
    });

    testWidgets('nothing to deliver: it says so', (tester) async {
      await pumpDeliveries(tester, []);
      expect(find.text('Nothing is waiting to leave.'), findsOneWidget);
      expect(find.text('No driver has anything out.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the arrow opens the order', (tester) async {
      final t = await pumpDeliveries(tester, [bag('w2', 12)]);
      t.hub.check = {'lines': <Object>[], 'subtotal': '0.00', 'tax': '0.00', 'total': '0.00'};
      await tapKey(tester, 'open-w2');
      expect(find.byType(DeliveriesScreen, skipOffstage: true), findsNothing);
      await stop(tester);
    });

    testWidgets('what another screen did shows here: a bag sent out at the counter, one delivered', (tester) async {
      final t = await pumpDeliveries(tester, [bag('w2', 12), bag('t1', 14, driver: tom)]);
      expect(cards(tester, 'waiting'), ['w2']);
      expect(cards(tester, 'out'), ['t1']);
      t.hub.orders[0]['fields'] = {...t.hub.orders[0]['fields'] as Map, ...outFields(wei, soon.millisecondsSinceEpoch)};
      t.hub.orders[1]['status'] = 'closed';
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      expect(cards(tester, 'waiting'), isEmpty);
      expect(cards(tester, 'out'), ['w2']);
      expect(words(tester, 'driver-load:d2'), startsWith('Wei · 1 out'));
      await stop(tester);
    });

    testWidgets('with the hub away it keeps its picture and says it may be behind', (tester) async {
      final t = await pumpDeliveries(tester, [bag('t1', 14, driver: tom)]);
      expect(key('deliveries-away'), findsNothing);
      t.hub.down = true;
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      expect(key('deliveries-away'), findsOneWidget);
      expect(cards(tester, 'out'), ['t1']);
      t.hub.down = false;
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      expect(key('deliveries-away'), findsNothing);
      await stop(tester);
    });

    testWidgets('a phone has one list, a tablet two side by side', (tester) async {
      await pumpDeliveries(tester, [bag('w2', 12), bag('t1', 14, driver: tom)], size: const Size(390, 844));
      expect(key('deliveries-list'), findsOneWidget);
      final waiting = tester.getRect(key('waiting-w2'));
      final out = tester.getRect(key('out-t1'));
      expect(out.top, greaterThan(waiting.bottom));
      await stop(tester);

      await pumpDeliveries(tester, [bag('w2', 12), bag('t1', 14, driver: tom)], size: const Size(1100, 800));
      expect(key('deliveries-list'), findsNothing);
      expect(tester.getRect(key('out-t1')).left, greaterThan(tester.getRect(key('waiting-w2')).right));
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      await pumpDeliveries(
        tester,
        [
          bag('w2', 12, name: 'Park', address: '128 Washington Street, Apartment 4B, Winchester'),
          bag('t1', 14, name: 'Diaz-Montgomery', address: '1 Pond St', driver: tom, due: '121.40'),
        ],
        size: const Size(320, 640),
        type: 1.3,
      );
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'waiting-w2');
      await tapKey(tester, 'deliveries-send');
      expect(find.text('Who takes it?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'driver:d1');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(cards(tester, 'out'), ['t1', 'w2']);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
