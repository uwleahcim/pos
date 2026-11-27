import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/delivery_fee.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/delivery_fee_dialog.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'catering_test.dart' show dataOf, enabled, kinds, platters, tapKey;
import 'delivery_test.dart' show bell, created, elm, enterAddress, key, order, stand, typed;
import 'hub.dart';
import 'location_rows.dart';

/// What a delivery costs the customer (docs/delivery.md, "The delivery fee"): the location lists its prices
/// by miles or by the minutes of the drive, whoever takes a delivery picks the band on its form, and the
/// hub fills in what it costs. The hub charges it, taxes it or not and keeps it in the sales
/// (backend/tests/orders/test_delivery_fee.py); these tests are about what the screens ask, say and send.

/// A fee as an order carries it once the hub filled it in.
Map<String, dynamic> carried(String upTo, String amount, {String by = 'miles', bool taxed = false}) => {
  'by': by,
  'up_to': upTo,
  'amount': amount,
  'taxed': taxed,
};

/// The fee of an order placed on the restaurant's website, as the hub wrote it down (docs/online-orders.md).
const websiteFee = <String, dynamic>{'by': 'online', 'up_to': null, 'amount': '4.00', 'taxed': false};

/// Linda's delivery to Elm Street, with the [fee] it carries.
Map<String, dynamic> delivery({Map<String, dynamic>? fee, bool brought = true}) {
  final o = order(delivery: brought);
  if (fee != null) (o['fields'] as Map)['delivery_fee'] = fee;
  return o;
}

/// The to-go form on a terminal whose hub charges [fees] for delivery (null: a hub older than the fee).
Future<Terminal> pumpForm(WidgetTester tester, {Map<String, dynamic>? fees, Size? size, double? type}) async {
  final t = await stand(tester, size: size);
  t.hub.deliveryFees = fees;
  if (type != null) {
    tester.platformDispatcher.textScaleFactorTestValue = type;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await pumpOrdersOn(tester, t);
  await tapKey(tester, 'to-go');
  expect(find.text('To-go order'), findsOneWidget);
  return t;
}

/// Amy at [order], on a terminal whose hub charges [fees].
Future<Terminal> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  Map<String, dynamic>? fees,
  Map<String, dynamic>? check,
  Size? size,
  double? type,
}) async {
  final t = await stand(tester, size: size);
  t.hub.deliveryFees = fees;
  t.hub.check = check ?? platters();
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

/// Linda's delivery, typed into the form as far as its address.
Future<void> typeDelivery(WidgetTester tester) async {
  await tester.enterText(key('takeout-name'), 'Linda');
  await tapKey(tester, 'channel:phone');
  await tapKey(tester, 'handover:delivery');
  await enterAddress(tester, elm);
  await tester.pumpAndSettle();
}

bool picked(WidgetTester tester, String fee) => tester.widget<ChoiceTile>(key('fee:$fee')).selected;

/// The buttons of the picker, as they read: what it costs over how far it reaches.
List<String> offered(WidgetTester tester) => [
  for (final tile in tester.widgetList<ChoiceTile>(find.byType(ChoiceTile)))
    [if (tile.groupLabel.isNotEmpty) tile.groupLabel, tile.name].join(', '),
];

void main() {
  group('the prices and what an order carries', () {
    test('the list as the hub keeps it', () {
      final fees = DeliveryFees.fromJson(Hub.milesFees);
      expect((fees.enabled, fees.by, fees.taxed, fees.asks), (true, 'miles', false, true));
      expect([for (final band in fees.bands) (band.upTo, band.fee)], [('2', '3.00'), ('4.5', '5.00'), ('8', '8.50')]);
      expect((fees.band('4.5')?.fee, fees.band('4'), fees.band(null)), ('5.00', null, null));
      expect(fees.toJson(), {...Hub.milesFees, 'origin': ''}); // the address a lookup starts from: none yet
      // off, or on with nothing listed, nothing is asked
      expect(DeliveryFees.fromJson({...Hub.milesFees, 'enabled': false}).asks, isFalse);
      expect(const DeliveryFees().asks, isFalse);
      expect(DeliveryFees.fromJson(const {'enabled': true, 'by': 'minutes'}).asks, isFalse);
      // anything but minutes is miles
      expect(DeliveryFees.fromJson(const {'by': 'feet'}).by, 'miles');
    });

    test('the words of a band', () {
      expect((reachWords('miles', '2.5'), reachWords('minutes', '15')), ('Up to 2.5 mi', 'Up to 15 min'));
      expect((reachShort('miles', '2.5'), reachShort('minutes', '15')), ('2.5 mi', '15 min'));
      expect((feeWords('5.00'), feeWords('0.00'), feeWords('12.50')), (r'$5.00', 'Free', r'$12.50'));
    });

    test('what an order carries is read with care', () {
      final fee = OrderFee.of(carried('4.5', '5.00'));
      expect((fee?.by, fee?.upTo, fee?.amount, fee?.taxed, fee?.none), ('miles', '4.5', '5.00', false, false));
      expect(fee?.words, r'$5.00 · up to 4.5 mi');
      expect(OrderFee.of(carried('15', '9.00', by: 'minutes', taxed: true))?.words, r'$9.00 · up to 15 min');
      // no fee on purpose, as the hub stores it and as its history says it
      for (final none in [
        {'up_to': null, 'amount': '0.00'},
        {'by': null, 'up_to': null, 'amount': '0.00', 'taxed': false},
      ]) {
        final read = OrderFee.of(none);
        expect((read?.none, read?.pick, read?.words), (true, FeePick.none, 'No fee'));
      }
      // charged on the website: it has no band, and it is not "no fee"
      final online = OrderFee.of({...websiteFee, 'taxed': true});
      expect((online?.onWebsite, online?.none, online?.upTo), (true, false, null));
      expect((online?.amount, online?.taxed, online?.pick), ('4.00', true, FeePick.kept));
      expect((online?.words, online?.reach), (r'$4.00 · charged on the website', 'Charged on the website'));
      expect(fee?.onWebsite, isFalse);
      // delivered for nothing by the website is no fee like any other
      expect(OrderFee.of({...websiteFee, 'amount': '0.00'})?.none, isTrue);
      // nobody said, or nothing this build can read
      for (final unreadable in [
        null,
        '5.00',
        <String, dynamic>{},
        {'up_to': '2'}, // as a screen sends it: the hub has not filled it in
        {'amount': '5.00'},
        {'amount': 'five', 'by': 'miles', 'up_to': '2'},
        {'amount': '5.00', 'by': 'feet', 'up_to': '2'},
      ]) {
        expect(OrderFee.of(unreadable), isNull, reason: '$unreadable');
      }
      expect(Order.fromJson(delivery(fee: carried('2', '3.00'))).deliveryFee, OrderFee.of(carried('2', '3.00')));
      expect(Order.fromJson(delivery()).deliveryFee, isNull);
    });

    test('a form sends the band alone, and only what changed', () {
      expect(FeePick.field('4.5'), {'up_to': '4.5'});
      expect(FeePick.field(FeePick.none), {'up_to': null});
      final fees = DeliveryFees.fromJson(Hub.milesFees);
      final taken = OrderFee.of(carried('4.5', '5.00'))!;
      expect(FeePick.listed(taken, fees), isTrue);
      expect(FeePick.changed(FeePick.kept, taken, fees), isNull);
      expect(FeePick.changed('4.5', taken, fees), isNull); // the same band at the same price
      expect(FeePick.changed('8', taken, fees), '8');
      expect(FeePick.changed(FeePick.none, taken, fees), FeePick.none);
      expect(FeePick.changed(null, null, fees), isNull);
      expect(FeePick.changed('2', null, fees), '2');
      // the band costs something else now, or the list goes by minutes: picking it again is a change
      final dearer = OrderFee.of(carried('4.5', '4.00'))!;
      expect(FeePick.listed(dearer, fees), isFalse);
      expect(FeePick.changed('4.5', dearer, fees), '4.5');
      expect(FeePick.listed(OrderFee.of(carried('8', '8.50', by: 'minutes'))!, fees), isFalse);
      expect(FeePick.listed(taken, null), isFalse);
      // no fee on purpose is always as the list has it
      expect(FeePick.changed(FeePick.none, const OrderFee(), null), isNull);
      // the website's fee is no band of any list: it is kept until a band, or no fee, is picked
      final online = OrderFee.of(websiteFee)!;
      expect((FeePick.listed(online, fees), FeePick.listed(online, null)), (false, false));
      expect(FeePick.changed(FeePick.kept, online, fees), isNull);
      expect((FeePick.changed('2', online, fees), FeePick.changed(FeePick.none, online, fees)), ('2', FeePick.none));
    });

    test('the history says what was picked and what it was before', () {
      StepWords words(Object? now, Object? was) => wordsOf(
        HistoryStep.fromJson({'op_id': 'x', 'what': 'delivery_fee', 'now': now, 'was': was}),
        time: (ms) => '$ms',
      );
      const none = {'by': null, 'up_to': null, 'amount': '0.00', 'taxed': false};
      var said = words(carried('4.5', '5.00'), null);
      expect(said.title, r'Delivery fee $5.00');
      expect(said.under, ['Up to 4.5 mi']);
      said = words(carried('8', '8.50'), carried('4.5', '5.00'));
      expect(said.title, r'Delivery fee $8.50');
      expect(said.under, ['Up to 8 mi', r'It was $5.00 · up to 4.5 mi']);
      said = words(none, carried('8', '8.50'));
      expect(said.title, 'No delivery fee');
      expect(said.under, [r'It was $8.50 · up to 8 mi']);
      said = words(null, none);
      expect(said.title, 'Delivery fee taken back');
      expect(said.under, ['It was no fee']);
      said = words(websiteFee, null);
      expect(said.title, r'Delivery fee $4.00');
      expect(said.under, ['Charged on the website']);
      said = words(carried('2', '3.00'), websiteFee);
      expect(said.under, ['Up to 2 mi', r'It was $4.00 · charged on the website']);
    });

    test('the fee on a check is told from a charge staff put on', () {
      CheckCharge row(String id) =>
          CheckCharge.fromJson({'charge_id': id, 'name': 'Delivery fee', 'kind': 'amount', 'value': '5.00'});
      expect((row('fee:delivery').isDeliveryFee, row('delivery_fee').isDeliveryFee), (true, false));
    });

    testWidgets('a hub older than the fee has none; a manager saves the list with their token', (tester) async {
      final t = await terminal(tester);
      expect(await t.api.deliveryFees(), isNull);
      t.hub.deliveryFees = {'enabled': false, 'by': 'miles', 'bands': <Object>[], 'taxed': false};
      expect((await t.api.deliveryFees())?.asks, isFalse);
      final saved = await t.api.saveDeliveryFees(
        'tok-admin',
        const DeliveryFees(
          enabled: true,
          by: 'minutes',
          bands: [
            FeeBand(upTo: '20', fee: '6.5'),
            FeeBand(upTo: '10.0', fee: '3'),
          ],
        ),
      );
      expect(t.hub.deliveryFeesAuth, 'Bearer tok-admin');
      expect([for (final band in saved.bands) (band.upTo, band.fee)], [('10', '3.00'), ('20', '6.50')]);
      expect((await t.api.deliveryFees())?.by, 'minutes');
    });
  });

  group('the to-go form', () {
    testWidgets('a delivery picks what it costs, and Start waits for it', (tester) async {
      final t = await pumpForm(tester, fees: Hub.milesFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      expect(key('fee-picker'), findsNothing); // a pickup costs nothing to bring
      await tapKey(tester, 'handover:delivery');
      expect(key('fee-picker'), findsOneWidget);
      expect(find.text('Delivery fee'), findsOneWidget);
      expect(offered(tester), [r'$3.00, Up to 2 mi', r'$5.00, Up to 4.5 mi', r'$8.50, Up to 8 mi', 'No fee']);
      expect(key('address-needed'), findsOneWidget); // first things first
      expect(key('fee-needed'), findsNothing);
      await enterAddress(tester, elm);
      await tester.pumpAndSettle();
      expect(key('fee-needed'), findsOneWidget);
      expect(enabled(tester, 'takeout-start'), isFalse);

      await tapKey(tester, 'fee:4.5');
      expect((picked(tester, '4.5'), picked(tester, '2'), picked(tester, 'none')), (true, false, false));
      expect(key('fee-needed'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tapKey(tester, 'fee:8'); // further than was thought
      expect((picked(tester, '8'), picked(tester, '4.5')), (true, false));
      await tapKey(tester, 'takeout-start');

      final data = created(t.hub);
      expect((data['handover'], data['address']), ('delivery', elm));
      expect(data['delivery_fee'], {'up_to': '8'}); // the band alone: the hub fills in what it costs
      await stop(tester);
    });

    testWidgets('"No fee" is a pick', (tester) async {
      final t = await pumpForm(tester, fees: Hub.milesFees);
      await typeDelivery(tester);
      await tapKey(tester, 'fee:none');
      expect(picked(tester, 'none'), isTrue);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': null});
      await stop(tester);
    });

    testWidgets('an order the customer comes for after all carries no fee', (tester) async {
      final t = await pumpForm(tester, fees: Hub.milesFees);
      await typeDelivery(tester);
      await tapKey(tester, 'fee:2');
      await tapKey(tester, 'handover:pickup');
      expect(key('fee-picker'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub).containsKey('delivery_fee'), isFalse);
      await stop(tester);
    });

    testWidgets('prices by the minutes of the drive read so, and a band that costs nothing is Free', (tester) async {
      await pumpForm(
        tester,
        fees: {
          'enabled': true,
          'by': 'minutes',
          'bands': [
            {'up_to': '5', 'fee': '0.00'},
            {'up_to': '15', 'fee': '4.00'},
          ],
          'taxed': true,
        },
      );
      await typeDelivery(tester);
      expect(offered(tester), ['Free, Up to 5 min', r'$4.00, Up to 15 min', 'No fee']);
      await stop(tester);
    });

    testWidgets('where no fee is charged nothing is asked: turned off, or a hub older than the fee', (tester) async {
      for (final fees in [
        {...Hub.milesFees, 'enabled': false},
        null,
      ]) {
        final t = await pumpForm(tester, fees: fees);
        await typeDelivery(tester);
        expect(key('fee-picker'), findsNothing);
        expect(key('fee-needed'), findsNothing);
        expect(enabled(tester, 'takeout-start'), isTrue);
        await tapKey(tester, 'takeout-start');
        expect(created(t.hub).containsKey('delivery_fee'), isFalse);
        await stop(tester);
      }
    });

    testWidgets('a catering order may say its fee, and may be told later', (tester) async {
      await pumpForm(tester, fees: Hub.milesFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:catering');
      await tapKey(tester, 'handover:delivery');
      expect(key('fee-picker'), findsOneWidget);
      expect(key('fee-needed'), findsNothing); // like its address: the event is days away
      await tapKey(tester, 'fee:4.5');
      expect(picked(tester, '4.5'), isTrue);
      await stop(tester);
    });

    testWidgets('prices by a fraction of a mile are buttons like any other, on a small phone too', (tester) async {
      const quarters = {
        'enabled': true,
        'by': 'miles',
        'bands': [
          {'up_to': '0.25', 'fee': '0.00'},
          {'up_to': '0.5', 'fee': '2.00'},
          {'up_to': '12.75', 'fee': '9.00'},
        ],
        'taxed': false,
      };
      var t = await pumpForm(tester, fees: quarters);
      await typeDelivery(tester);
      expect(offered(tester), ['Free, Up to 0.25 mi', r'$2.00, Up to 0.5 mi', r'$9.00, Up to 12.75 mi', 'No fee']);
      await tapKey(tester, 'fee:0.25');
      expect((picked(tester, '0.25'), picked(tester, '0.5')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '0.25'});
      await stop(tester);

      t = await pumpForm(tester, fees: quarters, size: const Size(320, 640), type: 1.3);
      await typeDelivery(tester);
      expect(offered(tester), ['Free, 0.25 mi', r'$2.00, 0.5 mi', r'$9.00, 12.75 mi', 'No fee']);
      await tapKey(tester, 'fee:12.75');
      expect(tester.takeException(), isNull);
      expect(picked(tester, '12.75'), isTrue);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      await pumpForm(tester, fees: Hub.milesFees, size: const Size(320, 640), type: 1.3);
      await typeDelivery(tester);
      // buttons too narrow for "Up to 4.5 mi" on a line say the reach alone, under a heading that says the rest
      expect(find.text('Delivery fee, up to'), findsOneWidget);
      expect(offered(tester), [r'$3.00, 2 mi', r'$5.00, 4.5 mi', r'$8.50, 8 mi', 'No fee']);
      await tapKey(tester, 'fee:8');
      expect(tester.takeException(), isNull);
      expect(picked(tester, '8'), isTrue);
      await stop(tester);
    });
  });

  group('on the order', () {
    testWidgets('the fee it carries is the one picked; saved as it was, nothing is written', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.milesFees);
      await tapKey(tester, 'leaving-chip');
      expect(find.text('Pickup or delivery'), findsOneWidget);
      expect((picked(tester, '4.5'), picked(tester, '8'), picked(tester, 'none')), (true, false, false));
      expect(key('fee:kept'), findsNothing); // the list still has it at that price
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);

      // another band: sent alone, with who picked it
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:8');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1'), {
        'delivery_fee': {'up_to': '8'},
        'by': 'Amy',
        'by_id': 's1',
      });
      // the hub filled it in, and the dialog opens on it
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tapKey(tester, 'leaving-chip');
      expect((picked(tester, '8'), picked(tester, '4.5')), (true, false));
      await stop(tester);
    });

    testWidgets('a delivery nobody priced is asked, and "No fee" answers', (tester) async {
      final t = await pumpOrder(tester, delivery(), fees: Hub.milesFees);
      await tapKey(tester, 'when-strip');
      expect(key('fee-needed'), findsOneWidget);
      expect(enabled(tester, 'when-save'), isFalse);
      await tapKey(tester, 'fee:none');
      expect(key('fee-needed'), findsNothing);
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1'), {
        'delivery_fee': {'up_to': null},
        'by': 'Amy',
        'by_id': 's1',
      });
      await stop(tester);
    });

    testWidgets('a pickup made a delivery says where to and what it costs at once', (tester) async {
      final t = await pumpOrder(tester, delivery(brought: false), fees: Hub.milesFees);
      await tapKey(tester, 'leaving-chip');
      expect(key('fee-picker'), findsNothing);
      await tapKey(tester, 'handover:delivery');
      await enterAddress(tester, elm);
      await tester.enterText(key('event-note'), bell);
      await tester.pumpAndSettle();
      expect(enabled(tester, 'when-save'), isFalse);
      await tapKey(tester, 'fee:2');
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect((data['handover'], data['address'], data['event_note']), ('delivery', elm, bell));
      expect(data['delivery_fee'], {'up_to': '2'});
      await stop(tester);
    });

    testWidgets('a delivery made a pickup keeps what it carried: no fee is sent', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.milesFees);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:8'); // looked at, and then it is a pickup after all
      await tapKey(tester, 'handover:pickup');
      expect(key('fee-picker'), findsNothing);
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect((data['handover'], data.containsKey('delivery_fee')), ('pickup', false));
      await stop(tester);
    });

    testWidgets('a fee the list no longer offers stays as it was taken until another is picked', (tester) async {
      // it was three miles for four dollars when the order was taken; the list has changed since
      final t = await pumpOrder(tester, delivery(fee: carried('3', '4.00')), fees: Hub.milesFees);
      await tapKey(tester, 'leaving-chip');
      expect(offered(tester).first, r'$4.00 · as taken, Up to 3 mi');
      expect((picked(tester, 'kept'), picked(tester, '2'), picked(tester, 'none')), (true, false, false));
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:2');
      expect((picked(tester, 'kept'), picked(tester, '2')), (false, true));
      await tapKey(tester, 'fee:kept'); // back to what it was
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:2');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '2'});
      await stop(tester);
    });

    testWidgets('a fee the website charged stays until somebody picks another, and nobody is asked to', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: websiteFee), fees: Hub.milesFees);
      await tapKey(tester, 'leaving-chip');
      expect(offered(tester).first, r'$4.00, On the website');
      expect((picked(tester, 'kept'), picked(tester, '2'), picked(tester, 'none')), (true, false, false));
      expect(enabled(tester, 'when-save'), isTrue); // the order has its fee: none of the list's has to be picked
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:2');
      expect((picked(tester, 'kept'), picked(tester, '2')), (false, true));
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '2'});
      await stop(tester);
    });

    testWidgets('where the location charges no fee, what the website charged still shows', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: websiteFee));
      await tapKey(tester, 'leaving-chip');
      expect(key('fee-picker'), findsOneWidget);
      expect((picked(tester, 'kept'), picked(tester, 'none')), (true, false));
      expect(key('fee:2'), findsNothing);
      await tapKey(tester, 'fee:none'); // taken off by hand, as any fee can be
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': null});
      await stop(tester);
    });

    testWidgets('the same band at a new price: the order keeps its own until it is picked again', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '4.00')), fees: Hub.milesFees);
      await tapKey(tester, 'leaving-chip');
      expect((picked(tester, 'kept'), picked(tester, '4.5')), (true, false));
      await tapKey(tester, 'fee:4.5');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '4.5'});
      await stop(tester);
    });

    testWidgets('with the fee turned off since, the one on the order can still be taken off', (tester) async {
      final off = {...Hub.milesFees, 'enabled': false};
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: off);
      await tapKey(tester, 'leaving-chip');
      expect(offered(tester), [r'$5.00 · as taken, Up to 4.5 mi', 'No fee']);
      expect(enabled(tester, 'when-save'), isTrue);
      await tapKey(tester, 'fee:none');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': null});
      await stop(tester);
    });

    testWidgets('the fee is a row of the check, and a tap opens how the order leaves', (tester) async {
      final check = {
        ...platters(),
        'charges': [
          {
            'charge_id': 'fee:delivery',
            'name': 'Delivery fee',
            'kind': 'amount',
            'value': '5.00',
            'amount': '5.00',
            'gratuity': false,
            'automatic': false,
            'taxed': false,
            'delivery': {'by': 'miles', 'up_to': '4.5'},
          },
        ],
        'charge_total': '5.00',
        'total': '70.01',
        'due': '70.01',
      };
      final t = await pumpOrder(
        tester,
        delivery(fee: carried('4.5', '5.00')),
        fees: Hub.milesFees,
        check: check,
      );
      expect(find.text('Delivery fee'), findsOneWidget);
      await tapKey(tester, 'charge-fee:delivery');
      expect(find.text('Pickup or delivery'), findsOneWidget);
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'fee:none');
      await tapKey(tester, 'when-save');
      // it is taken off as it was put on: as the order's fee, not as a charge
      expect(kinds(t.hub, 'o1'), ['set_field']);
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': null});
      await stop(tester);
    });

    testWidgets('the dialog fits a small phone with large type', (tester) async {
      await pumpOrder(
        tester,
        delivery(fee: carried('3', '4.00')),
        fees: Hub.milesFees,
        size: const Size(320, 640),
        type: 1.3,
      );
      await tapKey(tester, 'when-strip');
      expect(key('fee-picker'), findsOneWidget);
      expect(find.text('Delivery fee, up to'), findsOneWidget);
      expect(offered(tester).first, r'$4.00 · as taken, 3 mi');
      await tapKey(tester, 'fee:8');
      expect(tester.takeException(), isNull);
      expect(enabled(tester, 'when-save'), isTrue);
      await stop(tester);
    });
  });

  group('the prices under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {Map<String, dynamic>? fees, Size? size}) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = fees;
      if (size != null) tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'delivery-fee');
      return t;
    }

    String rowWords(WidgetTester tester) => ((tester.widget<ListTile>(key('delivery-fee')).subtitle!) as Text).data!;

    const off = {'enabled': false, 'by': 'miles', 'bands': <Object>[], 'taxed': false};

    testWidgets('off to start; a manager turns it on and lists the prices', (tester) async {
      final t = await pumpLocation(tester, fees: off);
      expect(rowWords(tester), 'Off: nothing is added to a delivery for the trip');
      await tapKey(tester, 'delivery-fee');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      expect(find.text('Nothing is added to a delivery for the trip'), findsOneWidget);
      await tapKey(tester, 'fee-enabled');
      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:0'), '4.5');
      await tester.enterText(key('fee-band-fee:0'), '5');
      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:1'), '2');
      await tester.enterText(key('fee-band-fee:1'), r'$3.00');
      await tapKey(tester, 'fee-save');
      expect(find.byType(DeliveryFeeDialog), findsNothing);
      expect(t.hub.deliveryFeesAuth, 'Bearer tok-admin');
      expect(t.hub.deliveryFees, {
        'enabled': true,
        'by': 'miles',
        // nearest first, as the hub keeps them
        'bands': [
          {'up_to': '2', 'fee': '3.00'},
          {'up_to': '4.5', 'fee': '5.00'},
        ],
        'taxed': false,
      });
      expect(find.text('Delivery fee saved'), findsOneWidget);
      expect(rowWords(tester), r'$3.00 up to 2 mi, $5.00 up to 4.5 mi');
      await stop(tester);
    });

    testWidgets('by the minutes of the drive, taxed, and a price removed', (tester) async {
      final t = await pumpLocation(tester, fees: Hub.milesFees);
      expect(rowWords(tester), r'$3.00 up to 2 mi, $5.00 up to 4.5 mi, $8.50 up to 8 mi');
      await tapKey(tester, 'delivery-fee');
      await tester.tap(find.text('Minutes of the drive'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'fee-band-remove:1'); // four and a half is no number of minutes
      await tester.enterText(key('fee-band-reach:0'), '10');
      await tester.enterText(key('fee-band-reach:2'), '20');
      await tapKey(tester, 'fee-taxed');
      expect(find.text('The fee is taxed like the food. Ask your accountant which is right for you'), findsOneWidget);
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees, {
        'enabled': true,
        'by': 'minutes',
        'bands': [
          {'up_to': '10', 'fee': '3.00'},
          {'up_to': '20', 'fee': '8.50'},
        ],
        'taxed': true,
      });
      expect(rowWords(tester), r'$3.00 up to 10 min, $8.50 up to 20 min · taxed');
      await stop(tester);
    });

    testWidgets("what cannot be saved is said in the dialog, the hub's own words too", (tester) async {
      final t = await pumpLocation(tester, fees: Hub.milesFees);
      await tapKey(tester, 'delivery-fee');
      await tester.enterText(key('fee-band-reach:1'), '2.0');
      await tapKey(tester, 'fee-save');
      expect(find.text('Two prices reach the same number of miles'), findsOneWidget);
      // a fraction of a mile goes to a hundredth and no finer
      for (final finer in ['2.255', '0.001', '0', 'two']) {
        await tester.enterText(key('fee-band-reach:1'), finer);
        await tapKey(tester, 'fee-save');
        expect(find.text('How far a price reaches is a number of miles, such as 2, 2.5 or 0.25'), findsOneWidget);
      }
      await tester.enterText(key('fee-band-reach:1'), '4.5');
      await tester.enterText(key('fee-band-fee:1'), 'five');
      await tapKey(tester, 'fee-save');
      expect(find.text('A fee is dollars and cents, such as 5 or 4.50'), findsOneWidget);
      await tester.tap(find.text('Minutes of the drive'));
      await tester.pumpAndSettle();
      await tester.enterText(key('fee-band-fee:1'), '5');
      await tapKey(tester, 'fee-save');
      expect(find.text('How far a price reaches is a whole number of minutes, such as 15'), findsOneWidget);
      for (final row in [0, 1, 2]) {
        await tapKey(tester, 'fee-band-remove:$row');
      }
      await tapKey(tester, 'fee-save');
      expect(find.text('List at least one distance and what it costs, or turn the fee off'), findsOneWidget);
      expect(t.hub.deliveryFeesAuth, isNull); // none of it reached the hub

      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:3'), '15');
      await tester.enterText(key('fee-band-fee:3'), '4');
      t.hub.refuseDeliveryFees = 'at most 8 bands, so they fit one screen';
      await tapKey(tester, 'fee-save');
      expect(find.text('at most 8 bands, so they fit one screen'), findsOneWidget);
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      // eight prices at most: the button to add one goes off
      for (var n = 0; n < 7; n++) {
        await tapKey(tester, 'fee-band-add');
      }
      expect(enabled(tester, 'fee-band-add'), isFalse);
      await stop(tester);
    });

    /// How far each row of the dialog reaches as it reads, from the top row down.
    List<String> reaches(WidgetTester tester) {
      final boxes =
          [
            for (final box in find.byType(TextField).evaluate())
              if (box.widget.key case ValueKey<String>(:final value) when value.startsWith('fee-band-reach:')) box,
          ]..sort(
            (a, b) =>
                tester.getTopLeft(find.byWidget(a.widget)).dy.compareTo(tester.getTopLeft(find.byWidget(b.widget)).dy),
          );
      return [for (final box in boxes) (box.widget as TextField).controller!.text];
    }

    testWidgets('miles may be a fraction of a mile, to a hundredth', (tester) async {
      // the owner's words, 2026-11-27: "Allow fractional miles like 0.25 miles"
      final t = await pumpLocation(tester, fees: Hub.milesFees);
      await tapKey(tester, 'delivery-fee');
      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:3'), '0.25');
      await tester.enterText(key('fee-band-fee:3'), '0');
      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:4'), '.75');
      await tester.enterText(key('fee-band-fee:4'), '1.50');
      await tester.enterText(key('fee-band-reach:1'), '4.25');
      await tapKey(tester, 'fee-save');
      expect(find.byType(DeliveryFeeDialog), findsNothing);
      expect(t.hub.deliveryFees!['bands'], [
        {'up_to': '0.25', 'fee': '0.00'},
        {'up_to': '0.75', 'fee': '1.50'},
        {'up_to': '2', 'fee': '3.00'},
        {'up_to': '4.25', 'fee': '5.00'},
        {'up_to': '8', 'fee': '8.50'},
      ]);
      expect(
        rowWords(tester),
        r'Free up to 0.25 mi, $1.50 up to 0.75 mi, $3.00 up to 2 mi, $5.00 up to 4.25 mi, $8.50 up to 8 mi',
      );
      // and it opens again as it was saved
      await tapKey(tester, 'delivery-fee');
      expect(reaches(tester), ['0.25', '0.75', '2', '4.25', '8']);
      await stop(tester);
    });

    testWidgets('the prices keep themselves nearest first as they are typed', (tester) async {
      // the owner's words, 2026-11-27: "the list of the delivery distance should auto sort by distance"
      final t = await pumpLocation(tester, fees: Hub.milesFees);
      await tapKey(tester, 'delivery-fee');
      expect(reaches(tester), ['2', '4.5', '8']);
      // a new row waits under them all, and stays where it is while it is typed in
      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:3'), '0.25');
      await tester.pump();
      expect(reaches(tester), ['2', '4.5', '8', '0.25']);
      await tester.enterText(key('fee-band-fee:3'), '0'); // its own fee: still the same row
      await tester.pump();
      expect(reaches(tester), ['2', '4.5', '8', '0.25']);
      // on to another row: it goes to its place
      await tester.showKeyboard(key('fee-band-fee:0'));
      await tester.pumpAndSettle();
      expect(reaches(tester), ['0.25', '2', '4.5', '8']);
      expect(tester.takeException(), isNull);
      // a distance changed goes to its new place once the keyboard is put away, and not before
      await tester.enterText(key('fee-band-reach:0'), '6');
      await tester.pump();
      expect(reaches(tester), ['0.25', '6', '4.5', '8']);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(reaches(tester), ['0.25', '4.5', '6', '8']);
      // "Add a price" puts the row typed last in its place too, with the new one under them all
      await tester.enterText(key('fee-band-reach:1'), '9');
      await tapKey(tester, 'fee-band-add');
      expect(reaches(tester), ['0.25', '6', '8', '9', '']);
      // what is no distance yet waits at the foot, in the order it was added; the same distance twice stays put
      await tester.enterText(key('fee-band-reach:4'), 'far');
      await tapKey(tester, 'fee-band-add');
      await tester.enterText(key('fee-band-reach:5'), '6.0');
      await tester.showKeyboard(key('fee-band-reach:3'));
      await tester.pumpAndSettle();
      expect(reaches(tester), ['0.25', '6', '6.0', '8', '9', 'far']);
      // each row kept its own fee on the way
      expect(typed(tester, 'fee-band-fee:3'), '0');
      expect(typed(tester, 'fee-band-fee:0'), '3.00');
      // removing one moves no other
      await tapKey(tester, 'fee-band-remove:5');
      await tapKey(tester, 'fee-band-remove:4');
      expect(reaches(tester), ['0.25', '6', '8', '9']);
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees!['bands'], [
        {'up_to': '0.25', 'fee': '0.00'},
        {'up_to': '6', 'fee': '3.00'},
        {'up_to': '8', 'fee': '8.50'},
        {'up_to': '9', 'fee': '5.00'},
      ]);
      await stop(tester);
    });

    testWidgets('by minutes they sort the same way, and a list the hub hands over out of order is put right', (
      tester,
    ) async {
      await pumpLocation(
        tester,
        fees: {
          'enabled': true,
          'by': 'minutes',
          'bands': [
            {'up_to': '20', 'fee': '6.00'},
            {'up_to': '5', 'fee': '2.00'},
            {'up_to': '10', 'fee': '4.00'},
          ],
          'taxed': false,
        },
      );
      await tapKey(tester, 'delivery-fee');
      expect(reaches(tester), ['5', '10', '20']);
      await tester.enterText(key('fee-band-reach:1'), '25');
      await tester.showKeyboard(key('fee-band-reach:0'));
      await tester.pumpAndSettle();
      expect(reaches(tester), ['10', '20', '25']);
      await stop(tester);
    });

    testWidgets('a hub older than the fee says so on the row', (tester) async {
      await pumpLocation(tester);
      expect(rowWords(tester), 'The hub has not answered about the delivery fee (an older hub: update it)');
      expect(tester.widget<ListTile>(key('delivery-fee')).onTap, isNull);
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the dialog fits with eight prices and large type', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpLocation(
        tester,
        size: const Size(320, 568),
        fees: {
          'enabled': true,
          'by': 'minutes',
          'bands': [
            for (var n = 1; n <= 8; n++) {'up_to': '${n * 5}', 'fee': '${n + 2}.50'},
          ],
          'taxed': true,
        },
      );
      await tapKey(tester, 'delivery-fee');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      await tapKey(tester, 'fee-taxed');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
