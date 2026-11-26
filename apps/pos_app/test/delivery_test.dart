import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/address_parts.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/customers.dart';
import 'package:pos_app/orders_ahead.dart';
import 'package:pos_app/pickup_board.dart';
import 'package:pos_app/screens/event_fields.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/pay_dialog.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/takeout.dart';
import 'package:pos_app/to_go_stages.dart';

import 'catering_test.dart' show dataOf, enabled, eventAt, eventDay, kinds, platters, said, tapKey;
import 'hub.dart';

/// An order that is brought to the customer (docs/delivery.md): the to-go form asks Pickup or Delivery and
/// where to, a returning customer's address is already there, the order says how it leaves and can be
/// changed, and the list of checks says where it goes and that it was delivered. The hub marks the papers
/// and keeps the money as on any to-go order (backend/tests/orders/test_delivery.py); these tests are about
/// what the screens ask, say and send.

const elm = '12 Elm St, Winchester';
const bell = 'Ring twice, side door';
const lindaDigits = '7815550101';

/// When Linda's order for now was promised: twenty minutes from now, on the minute.
final soon = () {
  final at = DateTime.now().add(const Duration(minutes: 20));
  return DateTime(at.year, at.month, at.day, at.hour, at.minute);
}();

/// Linda as the hub knows her: three orders, the last one brought to Elm Street.
Map<String, dynamic> linda({String address = elm, String note = bell}) => {
  'phone': lindaDigits,
  'known': true,
  'name': 'Linda Chen',
  'note': '',
  'orders': 3,
  'first_ms': DateTime(2026, 9, 1, 18).millisecondsSinceEpoch,
  'last_ms': DateTime(2026, 11, 3, 18).millisecondsSinceEpoch,
  'recent': <Object>[],
  'address': address,
  'address_note': note,
};

/// Linda's phone order, number 7: a pot of tea, promised [soon] (or, [later], for [eventAt], a time she
/// named). [delivery] says it is brought to her.
Map<String, dynamic> order({
  String id = 'o1',
  bool delivery = false,
  bool sent = false,
  bool later = false,
  String stage = 'new',
  String status = 'open',
  String channel = 'phone',
  String address = elm,
  String note = bell,
}) => {
  'order_id': id,
  'status': status,
  'fields': {
    'order_type': 'takeout',
    'order_no': 7,
    'customer_name': 'Linda',
    'phone': '781 555 0101',
    'channel': channel,
    'stage': stage,
    'promised_at': (later ? eventAt : soon).millisecondsSinceEpoch,
    'quoted_minutes': delivery ? 45 : 20,
    if (later) 'for_later': true,
    if (delivery) ...{'handover': 'delivery', 'address': address, 'event_note': note},
  },
  'lines': {'L1': line('Pot of tea', fired: sent)},
  'fired': sent ? {'': '2026-11-16T18:00:00'} : <String, dynamic>{},
  'payments': <String, dynamic>{},
};

/// A terminal whose hub marks deliveries on its papers ([delivers]), or one older than that.
Future<Terminal> stand(WidgetTester tester, {bool delivers = true, Size? size}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.delivers = delivers;
  if (size != null) tester.view.physicalSize = size;
  return t;
}

/// The to-go form, opened from the list of checks.
Future<Terminal> pumpForm(
  WidgetTester tester, {
  bool delivers = true,
  Map<String, dynamic>? customer,
  Size? size,
  double? type,
}) async {
  final t = await stand(tester, delivers: delivers, size: size);
  if (customer != null) t.hub.customers[customer['phone'] as String] = customer;
  if (type != null) {
    tester.platformDispatcher.textScaleFactorTestValue = type;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await pumpOrdersOn(tester, t);
  await tapKey(tester, 'to-go');
  expect(find.text('To-go order'), findsOneWidget);
  return t;
}

/// Amy at [order], pushed over a page.
Future<Terminal> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  bool delivers = true,
  Size? size,
  double? type,
}) async {
  final t = await stand(tester, delivers: delivers, size: size);
  t.hub.check = platters();
  t.hub.orders.add(order);
  if (type != null) {
    tester.platformDispatcher.textScaleFactorTestValue = type;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('next customer'))),
    ),
  );
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => OrderScreen(
              api: t.api,
              outbox: t.outbox,
              photos: t.photos,
              orderId: order['order_id'] as String,
              session: t.session,
            ),
          ),
        ),
  );
  await tester.pumpAndSettle();
  return t;
}

Finder key(String name) => find.byKey(ValueKey(name));

String typed(WidgetTester tester, String name) => tester.widget<TextField>(key(name)).controller!.text;

/// The boxes a delivery's address is typed in (docs/delivery.md, "The address in its parts"): the street's,
/// and after it the unit's, the town's, the state's and the ZIP's.
const addressBoxes = [
  'event-address',
  'event-address:unit',
  'event-address:city',
  'event-address:state',
  'event-address:zip',
];

/// What the address's boxes hold, the street's first.
List<String> addressParts(WidgetTester tester) => [for (final box in addressBoxes) typed(tester, box)];

/// The address the form holds, as its boxes say it on one line.
String addressOn(WidgetTester tester) {
  final [street, unit, city, state, zip] = addressParts(tester);
  return AddressParts(street: street, unit: unit, city: city, state: state, zip: zip).line;
}

/// Types an address into its boxes, each part into its own: whatever a box held is typed over.
Future<void> enterAddress(WidgetTester tester, String address) async {
  final parts = AddressParts.parse(address);
  for (final (index, part) in [parts.street, parts.unit, parts.city, parts.state, parts.zip].indexed) {
    if (typed(tester, addressBoxes[index]) != part) await tester.enterText(key(addressBoxes[index]), part);
  }
  await tester.pump();
}

String label(WidgetTester tester, String name) => tester.widget<TextField>(key(name)).decoration!.labelText!;

/// Types a number in the form and lets the hub be asked about it.
Future<void> typeNumber(WidgetTester tester, String phone) async {
  await tester.enterText(key('takeout-phone'), phone);
  await tester.pump(const Duration(milliseconds: 500)); // the typing pauses
  await tester.pumpAndSettle();
}

Map<String, dynamic> created(Hub hub) => (hub.sent.first.$2['data'] as Map).cast<String, dynamic>();

void main() {
  group('what a delivery is', () {
    test('a to-go order is one by how it leaves; a table never is', () {
      expect(Order.fromJson(order(delivery: true)).isDelivery, isTrue);
      expect(Order.fromJson(order()).isDelivery, isFalse);
      final table = Order.fromJson({
        'order_id': 't1',
        'status': 'open',
        'fields': {'table': '12', 'order_type': 'dine_in', 'handover': 'delivery'},
        'lines': <String, dynamic>{},
        'fired': <String, dynamic>{},
      });
      expect(table.isDelivery, isFalse);
      final event = Order.fromJson(order(delivery: true)).event;
      expect((event.delivered, event.address, event.note, event.guests), (true, elm, bell, null));
      expect(event.words, 'Delivery · $elm · $bell');
    });

    test('money still to take is paid at the door, not at pickup', () {
      expect(moneyWords(Order.fromJson(order(delivery: true))), 'pay at the door');
      expect(moneyWords(Order.fromJson(order())), 'pay at pickup');
      final paid = order(delivery: true)
        ..['payments'] = {
          'p1': <String, dynamic>{'method': 'cash', 'amount': '3.21'},
        };
      expect(moneyWords(Order.fromJson(paid)), 'paid');
    });

    testWidgets('sending one unpaid: "At the door", and no ready text is promised', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: PayDialog(due: '3.21', channel: 'phone', payAtPickup: true, delivery: true),
        ),
      );
      expect(find.text('At the door'), findsOneWidget);
      expect(find.text('At pickup'), findsNothing);
      await tapKey(tester, 'pay:later');
      expect(find.text('Nothing taken now: it is paid at the door.'), findsOneWidget);
      // an order the customer comes for, and a catering order, say what they said
      await tester.pumpWidget(
        const MaterialApp(
          home: PayDialog(due: '3.21', channel: 'phone', payAtPickup: true),
        ),
      );
      expect(find.text('At pickup'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: PayDialog(due: '3.21', channel: 'catering', payAtPickup: true, delivery: true),
        ),
      );
      expect(find.text('Later'), findsOneWidget);
    });

    test('it is quoted the minutes set for Delivery, whoever took it; a catering order keeps its lead', () {
      final quotes = Quotes.fromJson({
        'minutes': {'counter': 15, 'phone': 20, 'delivery': 50, 'catering': 90},
        'pay_at_pickup': ['phone'],
        'delivers': true,
      });
      expect(quotes.delivers, isTrue);
      expect((quotes.baseFor('phone'), quotes.baseFor('phone', delivery: true)), (20, 50));
      expect(quotes.baseFor('counter', delivery: true), 50);
      expect(quotes.baseFor('catering', delivery: true), 90);
      // a hub that names no minutes for it: three quarters of an hour
      final bare = Quotes.fromJson({
        'minutes': {'phone': 20},
      });
      expect((bare.delivers, bare.minutesFor('phone', delivery: true)), (false, deliveryMinutes));
      // the rush comes on top, as on any quote
      final now = DateTime(2026, 11, 16, 18);
      final busy = Quotes(rush: Rush(minutes: 10, until: now.add(const Duration(hours: 4)).millisecondsSinceEpoch));
      expect(busy.minutesFor('phone', at: now, delivery: true), 55);
      expect(const Quotes().delivers, isFalse); // until a hub says so
    });

    test('it was delivered, not picked up', () {
      expect(stageLabel('picked_up', delivery: true), 'Delivered');
      expect((stageLabel('picked_up'), stageLabel('ready', delivery: true)), ('Picked up', 'Ready'));
    });

    test('the customer comes with where their last delivery went', () {
      final card = CustomerCard.fromJson(linda());
      expect((card.address, card.addressNote), (elm, bell));
      final older = CustomerCard.fromJson({'phone': lindaDigits, 'known': true});
      expect((older.address, older.addressNote), ('', '')); // a hub older than deliveries says neither
    });

    test('an order the customer comes for carries no note for the driver', () {
      final address = TextEditingController(text: '  $elm '), note = TextEditingController(text: bell);
      addTearDown(address.dispose);
      addTearDown(note.dispose);
      final brought = EventFields.read(address: address, note: note, handover: 'delivery');
      expect(brought.toFields(), {'event_guests': null, 'handover': 'delivery', 'address': elm, 'event_note': bell});
      final fetched = EventFields.read(address: address, note: note, handover: 'pickup');
      expect(fetched.toFields(), {'event_guests': null, 'handover': 'pickup', 'address': '', 'event_note': ''});
    });

    test('the history says it was delivered, and whose the note is', () {
      String title(Map<String, dynamic> step) =>
          wordsOf(HistoryStep.fromJson({'op_id': 'x', ...step}), time: (ms) => '$ms').title;
      expect(title({'what': 'stage', 'was': 'ready', 'now': 'picked_up', 'delivery': true}), 'Marked delivered');
      expect(title({'what': 'stage', 'was': 'ready', 'now': 'picked_up'}), 'Marked picked up');
      expect(title({'what': 'stage', 'was': 'picked_up', 'now': 'new', 'delivery': true}), 'No longer delivered');
      Map<String, dynamic> note(bool? catering) => {
        'what': 'field',
        'field': 'event_note',
        'was': '',
        'now': bell,
        'catering': ?catering,
      };
      expect(title(note(false)), 'Note for the driver set to $bell');
      expect(title(note(true)), 'Note for the event set to $bell');
      expect(title(note(null)), 'Note for the event set to $bell'); // a hub that does not say
      final opened = wordsOf(
        HistoryStep.fromJson({
          'op_id': 'x',
          'what': 'opened',
          'fields': {'order_type': 'takeout', 'channel': 'phone', 'handover': 'delivery', 'address': elm},
        }),
        time: (ms) => '$ms',
      );
      expect(opened.under, contains('Delivery · $elm'));
    });

    test('nobody waits at the shelf for it: the pickup board leaves it off', () {
      final now = DateTime.now();
      final orders = [
        Order.fromJson(order(id: 'a', sent: true)),
        Order.fromJson(order(id: 'b', sent: true, delivery: true)),
        Order.fromJson(order(id: 'c', sent: true, stage: 'ready')),
        Order.fromJson(order(id: 'd', sent: true, stage: 'ready', delivery: true)),
      ];
      final board = boardOf(orders, now);
      expect([for (final o in board.made) o.orderId], ['a']);
      expect([for (final o in board.ready) o.orderId], ['c']);
    });

    test('the list of orders ahead says where one for later goes', () {
      final ahead = AheadOrder.fromJson({
        'order_id': 'p1',
        'channel': 'phone',
        'promised_ms': eventAt.millisecondsSinceEpoch,
        'handover': 'delivery',
        'address': elm,
        'event_note': bell,
      });
      expect((ahead.isCatering, ahead.eventWords), (false, 'Delivery · $elm · $bell'));
      final fetched = AheadOrder.fromJson({
        'order_id': 'p2',
        'channel': 'phone',
        'promised_ms': eventAt.millisecondsSinceEpoch,
        'handover': 'pickup',
      });
      expect(fetched.eventWords, '');
    });
  });

  group('the to-go form', () {
    testWidgets('asks Pickup or Delivery, and a delivery needs its address', (tester) async {
      final t = await pumpForm(tester);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      expect(key('delivery-fields'), findsOneWidget);
      expect(key('event-fields'), findsNothing); // no guests to count: it is no catering order
      expect(key('event-address'), findsNothing); // a pickup has no address, and no note for a driver
      expect(key('event-note'), findsNothing);
      expect(said(tester, 'takeout-quote'), 'Ready in about 20 min');
      expect(label(tester, 'takeout-phone'), 'Phone (for the ready text)');
      expect(enabled(tester, 'takeout-start'), isTrue);

      await tapKey(tester, 'handover:delivery');
      expect(said(tester, 'takeout-quote'), 'There in about 45 min'); // the cooking and the drive
      expect(label(tester, 'takeout-phone'), 'Phone (for the driver to call)');
      expect(label(tester, 'event-note'), 'Note for the driver');
      expect(key('address-needed'), findsOneWidget);
      expect(enabled(tester, 'takeout-start'), isFalse);

      await tester.enterText(key('event-address'), '  12 Elm St,   Winchester ');
      await tester.pumpAndSettle();
      expect(key('address-needed'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tester.enterText(key('event-note'), bell);
      await tester.enterText(key('takeout-phone'), '781 555 0101');
      final before = DateTime.now();
      await tapKey(tester, 'takeout-start');

      final data = created(t.hub);
      expect((data['order_type'], data['channel'], data['customer_name']), ('takeout', 'phone', 'Linda'));
      expect((data['handover'], data['address'], data['event_note']), ('delivery', elm, bell));
      expect(data['quoted_minutes'], 45);
      final promised = DateTime.fromMillisecondsSinceEpoch(data['promised_at'] as int);
      expect(promised.difference(before).inMinutes, inInclusiveRange(44, 45));
      expect(data.containsKey('event_guests'), isFalse);
      expect(data.containsKey('for_later'), isFalse);
      await stop(tester);
    });

    testWidgets('an order the customer comes for says nothing of how it leaves, as before', (tester) async {
      final t = await pumpForm(tester);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      // Delivery looked at and put back: nothing of it stays
      await tapKey(tester, 'handover:delivery');
      await enterAddress(tester, elm);
      await tester.enterText(key('event-note'), bell);
      await tapKey(tester, 'handover:pickup');
      expect(said(tester, 'takeout-quote'), 'Ready in about 20 min');
      await tapKey(tester, 'takeout-start');
      final data = created(t.hub);
      expect(data['quoted_minutes'], 20);
      for (final field in ['event_guests', 'handover', 'address', 'event_note']) {
        expect(data.containsKey(field), isFalse, reason: field);
      }
      await stop(tester);
    });

    testWidgets('a returning customer: the address of their last delivery is already there', (tester) async {
      final t = await pumpForm(tester, customer: linda());
      await tapKey(tester, 'channel:phone');
      await typeNumber(tester, '781 555 0101');
      expect(typed(tester, 'takeout-name'), 'Linda Chen');
      expect(key('event-address'), findsNothing); // nothing is asked until it is a delivery
      await tapKey(tester, 'handover:delivery');
      expect((addressOn(tester), typed(tester, 'event-note')), (elm, bell));
      expect(key('address-needed'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tapKey(tester, 'takeout-start');
      final data = created(t.hub);
      expect((data['handover'], data['address'], data['event_note']), ('delivery', elm, bell));
      await stop(tester);
    });

    testWidgets("one customer's address never goes on another's order, and a typed one is kept", (tester) async {
      final t = await pumpForm(tester, customer: linda());
      await tapKey(tester, 'handover:delivery');
      await typeNumber(tester, '781 555 0101');
      expect((addressOn(tester), typed(tester, 'event-note')), (elm, bell));
      // the number was somebody else's after all: Linda's street is not theirs
      await typeNumber(tester, '781 555 0199');
      expect((addressOn(tester), typed(tester, 'event-note')), ('', ''));
      expect(enabled(tester, 'takeout-start'), isFalse);
      // an address somebody typed stays, whoever the number turns out to be
      await enterAddress(tester, '4 Oak Rd, Woburn');
      await typeNumber(tester, '781 555 0101');
      expect(addressOn(tester), '4 Oak Rd, Woburn');
      expect(typed(tester, 'event-note'), bell); // nobody typed a note: hers is offered
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['address'], '4 Oak Rd, Woburn');
      await stop(tester);
    });

    testWidgets('a delivery for later keeps the time the customer named and starts cooking sooner', (tester) async {
      final t = await pumpForm(tester);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await enterAddress(tester, elm);
      await tapKey(tester, 'takeout-later');
      await tapKey(tester, 'day:tomorrow');
      await tapKey(tester, 'takeout-time');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'takeout-start');
      final data = created(t.hub);
      expect((data['for_later'], data['quoted_minutes'], data['handover']), (true, 45, 'delivery'));
      await stop(tester);
    });

    testWidgets('a catering order asks it among what its event needs, as before', (tester) async {
      await pumpForm(tester, customer: linda());
      await tester.enterText(key('takeout-name'), 'Linda');
      await typeNumber(tester, '781 555 0101');
      await tapKey(tester, 'channel:catering');
      expect(key('delivery-fields'), findsNothing);
      expect(key('event-fields'), findsOneWidget);
      expect(said(tester, 'takeout-quote'), 'The kitchen gets its ticket 60 min before its time.');
      await tapKey(tester, 'handover:delivery');
      expect(said(tester, 'takeout-quote'), 'The kitchen gets its ticket 60 min before its time.');
      expect(label(tester, 'event-note'), 'Note for the event');
      expect(addressOn(tester), elm); // where their last delivery went
      expect(typed(tester, 'event-note'), ''); // what was said for a driver is not about an event
      expect(key('address-needed'), findsNothing); // it may be given later: the event is days away
      await stop(tester);
    });

    testWidgets('a hub older than deliveries is not asked: the form is what it was', (tester) async {
      final t = await pumpForm(tester, delivers: false, customer: linda());
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await typeNumber(tester, '781 555 0101');
      expect(key('delivery-fields'), findsNothing);
      expect(key('handover:delivery'), findsNothing);
      await tapKey(tester, 'takeout-start');
      final data = created(t.hub);
      for (final field in ['handover', 'address', 'event_note']) {
        expect(data.containsKey(field), isFalse, reason: field);
      }
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      await pumpForm(tester, customer: linda(), size: const Size(320, 640), type: 1.3);
      await typeNumber(tester, '781 555 0101');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      expect(addressOn(tester), elm);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the list of checks', () {
    testWidgets('a delivery says so, where to, and that it was delivered', (tester) async {
      final t = await stand(tester);
      t.hub.orders.addAll([
        order(id: 'o1', delivery: true, sent: true, stage: 'ready'),
        order(id: 'o2', sent: true, stage: 'ready')..['fields']['order_no'] = 8,
        order(id: 'o3', delivery: true, sent: true)..['fields']['order_no'] = 9,
      ]);
      await pumpOrdersOn(tester, t);
      expect(find.text('Linda · phone · delivery'), findsNWidgets(2));
      expect(find.text('Linda · phone'), findsOneWidget);
      final at = clockTime(soon.millisecondsSinceEpoch);
      expect(find.text('1 items · open · fired · there $at · pay at the door · READY · $elm'), findsOneWidget);
      expect(find.text('1 items · open · fired · ready $at · pay at pickup · READY'), findsOneWidget);
      expect(find.text('1 items · open · fired · there $at · pay at the door · $elm'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delivered'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Picked up'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Ready'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      final t = await stand(tester, size: const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      t.hub.orders.add(order(delivery: true, sent: true, stage: 'ready'));
      await pumpOrdersOn(tester, t);
      expect(find.widgetWithText(FilledButton, 'Delivered'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('on the order', () {
    testWidgets('a chip says how it leaves, and a tap makes it a delivery, quoted again', (tester) async {
      final t = await pumpOrder(tester, order());
      expect(find.widgetWithText(ActionChip, 'Pickup'), findsOneWidget);
      expect(key('when-strip'), findsNothing); // nothing to say of an order that is picked up now
      await tapKey(tester, 'leaving-chip');
      expect(find.text('Pickup or delivery'), findsOneWidget);
      expect(key('day:today'), findsNothing); // its time is not the customer's to name here
      expect(key('event-guests'), findsNothing);
      await tapKey(tester, 'handover:delivery');
      expect(key('address-needed'), findsOneWidget);
      expect(enabled(tester, 'when-save'), isFalse);
      await enterAddress(tester, elm);
      await tester.enterText(key('event-note'), bell);
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');

      final at = soon.millisecondsSinceEpoch + 25 * 60000;
      expect(dataOf(t.hub, 'set_field', 'o1'), {
        'handover': 'delivery',
        'address': elm,
        'event_note': bell,
        'quoted_minutes': 45, // Delivery's minutes in place of the phone's twenty
        'promised_at': at,
        'by': 'Amy',
        'by_id': 's1',
      });
      expect(said(tester, 'leaving-said-words'), 'Now a delivery: there about ${clockTime(at)}.');
      await stop(tester);
    });

    testWidgets('a delivery says where it goes under the bar, and can be made a pickup again', (tester) async {
      final t = await pumpOrder(tester, order(delivery: true));
      expect(find.widgetWithText(ActionChip, 'Delivery'), findsOneWidget);
      expect(find.text('Delivery · $elm · $bell'), findsOneWidget);
      await tapKey(tester, 'when-strip');
      expect(find.text('Pickup or delivery'), findsOneWidget);
      expect((addressOn(tester), typed(tester, 'event-note')), (elm, bell));
      await tapKey(tester, 'handover:pickup');
      expect(key('event-address'), findsNothing);
      await tapKey(tester, 'when-save');
      final at = soon.millisecondsSinceEpoch - 25 * 60000;
      expect(dataOf(t.hub, 'set_field', 'o1'), {
        'handover': 'pickup',
        'address': '',
        'event_note': '',
        'quoted_minutes': 20,
        'promised_at': at,
        'by': 'Amy',
        'by_id': 's1',
      });
      expect(said(tester, 'leaving-said-words'), 'Now a pickup: ready about ${clockTime(at)}.');
      await stop(tester);
    });

    testWidgets('only the address changed: nothing else is written', (tester) async {
      final t = await pumpOrder(tester, order(delivery: true));
      await tapKey(tester, 'leaving-chip');
      await enterAddress(tester, '4 Oak Rd, Woburn');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1'), {'address': '4 Oak Rd, Woburn', 'by': 'Amy', 'by_id': 's1'});
      expect(key('leaving-said'), findsNothing);
      // and saved as it was: nothing at all
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), ['set_field']);
      await stop(tester);
    });

    testWidgets('once the kitchen has it, its time is not moved by how it leaves', (tester) async {
      final t = await pumpOrder(tester, order(sent: true));
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'handover:delivery');
      await enterAddress(tester, elm);
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1'), {'handover': 'delivery', 'address': elm, 'by': 'Amy', 'by_id': 's1'});
      expect(key('leaving-said'), findsNothing);
      await stop(tester);
    });

    testWidgets('an order for later keeps its time and starts cooking sooner', (tester) async {
      final t = await pumpOrder(tester, order(later: true));
      expect(find.text('For $eventDay 12:00'), findsOneWidget);
      await tapKey(tester, 'when-strip');
      expect(find.text('When it is for'), findsOneWidget);
      expect(key('day:today'), findsOneWidget); // its day and time, and how it leaves
      expect(key('delivery-fields'), findsOneWidget);
      await tapKey(tester, 'handover:delivery');
      await enterAddress(tester, elm);
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1'), {
        'handover': 'delivery',
        'address': elm,
        'quoted_minutes': 45,
        'by': 'Amy',
        'by_id': 's1',
      });
      expect(said(tester, 'leaving-said-words'), 'Now a delivery: the kitchen starts it 25 minutes sooner.');
      await stop(tester);
    });

    testWidgets('a delivery for later says its time and where it goes on one line', (tester) async {
      await pumpOrder(tester, order(later: true, delivery: true, note: ''));
      expect(find.text('For $eventDay 12:00 · Delivery · $elm'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a delivery with no address yet says so', (tester) async {
      await pumpOrder(tester, order(delivery: true, address: '', note: ''));
      expect(find.text('Delivery · no address yet'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub older than deliveries offers no chip; a delivery made elsewhere still says so', (tester) async {
      await pumpOrder(tester, order(), delivers: false);
      expect(key('leaving-chip'), findsNothing);
      expect(key('when-strip'), findsNothing);
      await stop(tester);
      await pumpOrder(tester, order(delivery: true), delivers: false);
      expect(find.widgetWithText(ActionChip, 'Delivery'), findsOneWidget);
      expect(find.text('Delivery · $elm · $bell'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a closed delivery still says where it went, and is not changed by a tap', (tester) async {
      final t = await pumpOrder(tester, order(delivery: true, sent: true, stage: 'picked_up', status: 'closed'));
      expect(find.text('Delivery · $elm · $bell'), findsOneWidget);
      expect(key('leaving-chip'), findsNothing);
      await tapKey(tester, 'when-strip');
      expect(find.text('Pickup or delivery'), findsNothing);
      expect(t.hub.opsFor('o1'), isEmpty);
      await stop(tester);
    });

    testWidgets('the chip, the line and the dialog fit a small phone with large type', (tester) async {
      await pumpOrder(tester, order(delivery: true), size: const Size(320, 568), type: 1.3);
      expect(key('leaving-chip'), findsOneWidget);
      expect(key('when-strip'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'when-strip');
      expect(find.text('Pickup or delivery'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
