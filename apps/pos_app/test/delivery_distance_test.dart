import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/delivery_fee.dart';
import 'package:pos_app/screens/delivery_fee_dialog.dart';
import 'package:pos_app/screens/fee_lookup.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

import 'catering_test.dart' show dataOf, enabled, kinds, tapKey;
import 'delivery_fee_test.dart' show carried, delivery, offered, picked, pumpForm, pumpOrder;
import 'delivery_test.dart' show created, elm, key, linda, typeNumber, typed;
import 'hub.dart';
import 'location_rows.dart';

/// Looking a delivery's distance up from its address (docs/delivery.md, "Looking the distance up"): where the
/// hub has a map service and the restaurant's own address, a form asks how far the address is once it is
/// typed, says what the map said, and picks the band it falls in. Any other price can still be tapped, and
/// what the map said travels with the pick. The hub's side is backend/tests/orders/test_delivery_distance.py.

const oak = '4 Oak Rd, Woburn';
const main9 = '9 Main St, Winchester';
const mapSaid = {'miles': '3.2', 'minutes': 9};

/// The address typed into a form that is a delivery, and the box left as Enter leaves it.
Future<void> typeAddress(WidgetTester tester, String address) async {
  await tester.enterText(key('event-address'), address);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

/// Linda's delivery on the form, as far as its address.
Future<void> lindaTo(WidgetTester tester, String address) async {
  await tester.enterText(key('takeout-name'), 'Linda');
  await tapKey(tester, 'channel:phone');
  await tapKey(tester, 'handover:delivery');
  await typeAddress(tester, address);
}

String said(WidgetTester tester, String name) => tester.widget<Text>(key(name)).data!;

void main() {
  group('what the hub says', () {
    test('whether it looks the distance up, and where from', () {
      final fees = DeliveryFees.fromJson(Hub.mapFees);
      expect((fees.origin, fees.maps, fees.lookup), ('1 Restaurant Row, Winchester', true, true));
      // what is saved is the address; whether there is a map service is the hub's to say
      expect(fees.toJson(), {...Hub.milesFees, 'origin': '1 Restaurant Row, Winchester'});
      // a hub older than the lookup says neither, and nothing is asked of it
      final older = DeliveryFees.fromJson(Hub.milesFees);
      expect((older.origin, older.maps, older.lookup), ('', null, false));
      final noService = DeliveryFees.fromJson({...Hub.milesFees, 'origin': 'x', 'maps': false, 'lookup': false});
      expect((noService.maps, noService.lookup), (false, false));
    });

    test('an answer: what the map said and the band it falls in', () {
      final near = FeeLookup.fromJson({
        ...mapSaid,
        'by': 'miles',
        'band': {'up_to': '4.5', 'fee': '5.00'},
        'beyond': false,
      });
      expect(
        (near.measured.words, near.band?.upTo, near.band?.fee, near.beyond),
        ('3.2 mi · 9 min', '4.5', '5.00', false),
      );
      final far = FeeLookup.fromJson({'miles': '9.3', 'minutes': 21, 'by': 'miles', 'band': null, 'beyond': true});
      expect((far.band, far.beyond), (null, true));
      expect(() => FeeLookup.fromJson(const {'band': null}), throwsFormatException);
      expect(Measured.of(const {'miles': 'far', 'minutes': 9}), isNull);
      expect(Measured.of(const {'miles': '3.2', 'minutes': '9'}), isNull);
      expect(Measured.of(mapSaid), const Measured(miles: '3.2', minutes: 9));
    });

    test('what the map said travels with the pick, and an order carries it', () {
      const measured = Measured(miles: '3.2', minutes: 9);
      expect(FeePick.field('4.5', measured: measured), {'up_to': '4.5', 'measured': mapSaid});
      expect(FeePick.field(FeePick.none, measured: measured), {'up_to': null, 'measured': mapSaid});
      expect(FeePick.field('4.5'), {'up_to': '4.5'});
      final fee = OrderFee.of({...carried('4.5', '5.00'), 'measured': mapSaid});
      expect((fee?.upTo, fee?.measured), ('4.5', measured));
      expect(OrderFee.of(carried('4.5', '5.00'))?.measured, isNull);
      expect(OrderFee.of({'up_to': null, 'amount': '0.00', 'measured': mapSaid})?.measured, measured);
    });

    test('the history shows a fee picked against the map', () {
      final words = wordsOf(
        HistoryStep.fromJson({
          'op_id': 'x',
          'what': 'delivery_fee',
          'now': {...carried('2', '3.00'), 'measured': mapSaid},
          'was': carried('4.5', '5.00'),
        }),
        time: (ms) => '$ms',
      );
      expect(words.title, r'Delivery fee $3.00');
      expect(words.under, ['Up to 2 mi', 'The map said 3.2 mi · 9 min', r'It was $5.00 · up to 4.5 mi']);
    });

    testWidgets('the hub is sent the address and nothing else', (tester) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = Hub.mapFees;
      final answer = await tester.runAsync(() => t.api.deliveryDistance(elm));
      expect((answer?.measured.words, answer?.band?.upTo), ('3.2 mi · 9 min', '4.5'));
      expect(t.hub.distanceAsks, [
        {'address': elm},
      ]);
      // where nothing is looked up, and where the map knows no such address, there is no distance
      Future<int?> refused(String address) async {
        try {
          await t.api.deliveryDistance(address);
          return 200;
        } on ApiException catch (err) {
          return err.status;
        }
      }

      expect(await tester.runAsync(() => refused('1 Nowhere')), 424);
      t.hub.deliveryFees = {...Hub.mapFees, 'lookup': false};
      expect(await tester.runAsync(() => refused(elm)), 409);
      t.hub.deliveryFees = Hub.milesFees; // a hub older than the lookup
      expect(await tester.runAsync(() => refused(elm)), 404);
      await stop(tester);
    });

    test('an address is asked once, and one that failed only when somebody says so', () async {
      final asked = <String>[];
      var fails = false;
      final asker = DistanceAsker()
        ..source = (address) async {
          asked.add(address);
          if (fails) throw ApiException('no', status: 424, detail: {'message': 'The map service is not answering.'});
          return const FeeLookup(measured: Measured(miles: '3.2', minutes: 9));
        };
      expect((await asker.ask('  12 Elm St,  Winchester '))?.measured.miles, '3.2');
      expect(await asker.ask(elm), isNull); // the same address, known already
      expect(asked, [elm]);
      expect((asker.measuredFor(elm)?.minutes, asker.measuredFor(oak)), (9, null));
      asker.typed(oak);
      expect((asker.found, asker.measuredFor(elm)), (null, null));
      fails = true;
      expect(await asker.ask(oak), isNull);
      expect(asker.problem, 'The map service is not answering.');
      expect(await asker.ask(oak), isNull);
      expect(asked, [elm, oak]); // not again by itself
      fails = false;
      expect((await asker.ask(oak, again: true))?.measured.miles, '3.2');
      expect(asked, [elm, oak, oak]);
      expect(asker.problem, isNull);
      // nothing to ask where the hub looks nothing up, and nothing of an empty box
      expect(await (DistanceAsker()).ask(elm), isNull);
      expect(await asker.ask('   '), isNull);
      asker.dispose();
    });
  });

  group('the to-go form', () {
    testWidgets('an address typed is looked up, its band is picked, and the order says what the map said', (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      // nothing to look up yet: the button waits for an address
      expect(tester.widget<TextButton>(key('fee-lookup')).onPressed, isNull);
      expect(t.hub.distanceAsks, isEmpty);
      await typeAddress(tester, elm);
      expect(t.hub.distanceAsks, [
        {'address': elm},
      ]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect((picked(tester, '4.5'), picked(tester, '2')), (true, false));
      expect(key('fee-needed'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapSaid});
      await stop(tester);
    });

    testWidgets('another price can still be tapped, and what the map said goes with it', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await lindaTo(tester, elm);
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'fee:2'); // a regular
      expect((picked(tester, '2'), picked(tester, '4.5')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '2', 'measured': mapSaid});
      await stop(tester);
    });

    testWidgets('a price tapped while the map is asked is not moved by its answer', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      final waits = t.hub.distanceWaits = Completer<void>();
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await tester.enterText(key('event-address'), elm);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(key('fee-lookup-asking'), findsOneWidget);
      await tapKey(tester, 'fee:none');
      waits.complete();
      await tester.pumpAndSettle();
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect((picked(tester, 'none'), picked(tester, '4.5')), (true, false));
      await stop(tester);
    });

    testWidgets('a price tapped by hand stays: the map says how far another address is and picks nothing', (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await lindaTo(tester, elm);
      await tapKey(tester, 'fee:none'); // a regular
      await typeAddress(tester, main9);
      expect(said(tester, 'fee-lookup-found'), '1.1 mi · 4 min drive');
      expect((picked(tester, 'none'), picked(tester, '2')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'up_to': null,
        'measured': {'miles': '1.1', 'minutes': 4},
      });
      await stop(tester);
    });

    testWidgets('a price tapped before the address is typed is not moved either', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await tapKey(tester, 'fee:8');
      await typeAddress(tester, elm);
      expect(t.hub.distanceAsks.length, 1);
      expect((picked(tester, '8'), picked(tester, '4.5')), (true, false));
      await stop(tester);
    });

    testWidgets('the address box left for the next one is an address done: it is looked up', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await tester.tap(key('event-address'));
      await tester.pump();
      await tester.enterText(key('event-address'), elm);
      await tester.pump();
      expect(t.hub.distanceAsks, isEmpty);
      await tester.tap(key('event-note')); // on to the note for the driver
      await tester.pumpAndSettle();
      expect([for (final ask in t.hub.distanceAsks) ask['address']], [elm]);
      expect(picked(tester, '4.5'), isTrue);
      await stop(tester);
    });

    testWidgets('a form closed with the address still in its box asks nothing on the way out', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await tester.tap(key('event-address'));
      await tester.pump();
      await tester.enterText(key('event-address'), elm);
      await tester.pump();
      expect(t.hub.distanceAsks, isEmpty); // not while it is being typed
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('To-go order'), findsNothing);
      expect(t.hub.distanceAsks, isEmpty);
      await stop(tester);
    });

    testWidgets('with the fee turned off there is no price to pick, and nothing is asked', (tester) async {
      final t = await pumpForm(tester, fees: {...Hub.mapFees, 'enabled': false});
      await lindaTo(tester, elm);
      expect(key('fee-picker'), findsNothing);
      expect(t.hub.distanceAsks, isEmpty);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await stop(tester);
    });

    testWidgets('an address typed over is asked about again, and the same one is not asked twice', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await lindaTo(tester, elm);
      await typeAddress(tester, elm); // left again as it was
      expect(t.hub.distanceAsks.length, 1);
      await tester.enterText(key('event-address'), main9);
      await tester.pump();
      // what the map said was about the other address: it is gone until this one is asked
      expect(key('fee-lookup-found'), findsNothing);
      expect(key('fee-lookup'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect([for (final ask in t.hub.distanceAsks) ask['address']], [elm, main9]);
      expect(said(tester, 'fee-lookup-found'), '1.1 mi · 4 min drive');
      expect((picked(tester, '2'), picked(tester, '4.5')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'up_to': '2',
        'measured': {'miles': '1.1', 'minutes': 4},
      });
      await stop(tester);
    });

    testWidgets('further than the prices reach is said, and somebody has to pick', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await lindaTo(tester, oak);
      expect(said(tester, 'fee-lookup-found'), '9.3 mi · 21 min drive: further than the prices reach');
      expect(offered(tester).length, 4);
      expect([
        for (final band in ['2', '4.5', '8', 'none']) picked(tester, band),
      ], everyElement(isFalse));
      expect(key('fee-needed'), findsOneWidget);
      expect(enabled(tester, 'takeout-start'), isFalse);
      await tapKey(tester, 'fee:8');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'up_to': '8',
        'measured': {'miles': '9.3', 'minutes': 21},
      });
      await stop(tester);
    });

    testWidgets('a lookup that fails says so; the fee is picked by hand, or the map is tried again', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      t.hub.refuseDistance = 'unreachable';
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-problem'), 'The map service is not answering. Pick the fee by hand.');
      expect(enabled(tester, 'takeout-start'), isFalse);
      await tapKey(tester, 'fee:4.5');
      expect(enabled(tester, 'takeout-start'), isTrue);
      t.hub.refuseDistance = null;
      await tapKey(tester, 'fee-lookup'); // "Try again"
      expect(t.hub.distanceAsks.length, 2);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapSaid});
      await stop(tester);
    });

    testWidgets('an order taken while the map gave nothing says nothing of the map', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await lindaTo(tester, '1 Nowhere');
      expect(said(tester, 'fee-lookup-problem'), contains('could not find that address'));
      await tapKey(tester, 'fee:2');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '2'});
      await stop(tester);
    });

    testWidgets("a returning customer's address is looked up as soon as the order is a delivery", (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      t.hub.customers['7815550101'] = linda();
      await tapKey(tester, 'channel:phone');
      await typeNumber(tester, '781 555 0101');
      expect(t.hub.distanceAsks, isEmpty); // a pickup goes nowhere
      await tapKey(tester, 'handover:delivery');
      expect(typed(tester, 'event-address'), elm);
      expect(t.hub.distanceAsks, [
        {'address': elm},
      ]);
      expect(picked(tester, '4.5'), isTrue);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await stop(tester);
    });

    testWidgets('the number typed after Delivery was tapped: the address it fills in is looked up too', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      t.hub.customers['7815550101'] = linda();
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await typeNumber(tester, '781 555 0101');
      expect(typed(tester, 'event-address'), elm);
      expect([for (final ask in t.hub.distanceAsks) ask['address']], [elm]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      await stop(tester);
    });

    testWidgets('where the hub looks nothing up the form asks nothing of it', (tester) async {
      for (final fees in [
        Hub.milesFees, // a hub older than the lookup
        {...Hub.mapFees, 'maps': false, 'lookup': false}, // no map service
        {...Hub.mapFees, 'origin': '', 'lookup': false}, // nowhere to start from
      ]) {
        final t = await pumpForm(tester, fees: fees);
        await lindaTo(tester, elm);
        expect(key('fee-picker'), findsOneWidget);
        expect(key('fee-lookup'), findsNothing);
        expect(key('fee-lookup-found'), findsNothing);
        expect(t.hub.distanceAsks, isEmpty);
        expect(key('fee-needed'), findsOneWidget);
        await stop(tester);
      }
    });

    testWidgets('it fits a small phone with large type, found or not', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees, size: const Size(320, 640), type: 1.3);
      await lindaTo(tester, oak);
      expect(key('fee-lookup-found'), findsOneWidget);
      expect(tester.takeException(), isNull);
      t.hub.refuseDistance = 'unreachable';
      await typeAddress(tester, elm);
      expect(key('fee-lookup-problem'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('on the order', () {
    testWidgets('opening the dialog asks nothing: an order that has its fee keeps it', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      expect(key('fee-picker'), findsOneWidget);
      expect(t.hub.distanceAsks, isEmpty);
      expect(key('fee-lookup'), findsOneWidget); // but it can be asked
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await stop(tester);
    });

    testWidgets('a new address is looked up, and the fee follows it', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      await typeAddress(tester, main9);
      expect([for (final ask in t.hub.distanceAsks) ask['address']], [main9]);
      expect(said(tester, 'fee-lookup-found'), '1.1 mi · 4 min drive');
      expect(picked(tester, '2'), isTrue);
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect(data['address'], main9);
      expect(data['delivery_fee'], {
        'up_to': '2',
        'measured': {'miles': '1.1', 'minutes': 4},
      });
      await stop(tester);
    });

    testWidgets('asked by hand for the address as it stands; the same band again writes nothing', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      await tapKey(tester, 'fee-lookup');
      expect([for (final ask in t.hub.distanceAsks) ask['address']], [elm]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty); // the fee it had is the one the map says
      await stop(tester);
    });

    testWidgets('a pickup made a delivery is looked up once it has its address', (tester) async {
      final t = await pumpOrder(tester, delivery(brought: false), fees: Hub.mapFees);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'handover:delivery');
      expect(t.hub.distanceAsks, isEmpty); // nowhere to go yet
      await typeAddress(tester, elm);
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '4.5', 'measured': mapSaid});
      await stop(tester);
    });

    testWidgets('where the hub looks nothing up the dialog is as it was', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.milesFees);
      await tapKey(tester, 'when-strip');
      await typeAddress(tester, main9);
      expect(key('fee-lookup'), findsNothing);
      expect(t.hub.distanceAsks, isEmpty);
      await stop(tester);
    });
  });

  group('under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, Map<String, dynamic> fees) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = fees;
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

    testWidgets("a manager types the restaurant's own address, and the row says the distance is looked up", (
      tester,
    ) async {
      final t = await pumpLocation(tester, {...Hub.mapFees, 'origin': '', 'lookup': false});
      expect(rowWords(tester), r'$3.00 up to 2 mi, $5.00 up to 4.5 mi, $8.50 up to 8 mi');
      await tapKey(tester, 'delivery-fee');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      await tester.ensureVisible(key('fee-origin'));
      expect(said(tester, 'fee-maps'), contains('sent the two addresses and nothing else'));
      await tester.enterText(key('fee-origin'), '  1 Restaurant Row,  Winchester ');
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees?['origin'], '1 Restaurant Row, Winchester');
      expect(t.hub.deliveryFees?['bands'], Hub.milesFees['bands']); // the prices as they were
      expect(rowWords(tester), endsWith('· distance looked up'));
      // and it is there when the dialog is opened again
      await tapKey(tester, 'delivery-fee');
      expect(typed(tester, 'fee-origin'), '1 Restaurant Row, Winchester');
      await stop(tester);
    });

    testWidgets('a hub with no map service says so, and keeps the address for the day it has one', (tester) async {
      final t = await pumpLocation(tester, {...Hub.milesFees, 'origin': '', 'maps': false, 'lookup': false});
      await tapKey(tester, 'delivery-fee');
      await tester.ensureVisible(key('fee-origin'));
      expect(said(tester, 'fee-maps'), contains('no map service yet'));
      await tester.enterText(key('fee-origin'), '1 Restaurant Row, Winchester');
      await tapKey(tester, 'fee-save');
      expect((t.hub.deliveryFees?['origin'], t.hub.deliveryFees?['lookup']), ('1 Restaurant Row, Winchester', false));
      expect(rowWords(tester), isNot(contains('looked up')));
      await stop(tester);
    });

    testWidgets('a hub older than the lookup shows no box for the address', (tester) async {
      final t = await pumpLocation(tester, Hub.milesFees);
      await tapKey(tester, 'delivery-fee');
      expect(key('fee-origin'), findsNothing);
      expect(key('fee-maps'), findsNothing);
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees, Hub.milesFees);
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the dialog fits with the address and large type', (tester) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = Hub.mapFees;
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'delivery-fee');
      await tapKey(tester, 'delivery-fee');
      await tester.ensureVisible(key('fee-origin'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
