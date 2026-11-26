import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/delivery_fee.dart';
import 'package:pos_app/screens/delivery_fee_dialog.dart';
import 'package:pos_app/screens/fee_lookup.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/theme.dart';

import 'catering_test.dart' show dataOf, enabled, kinds, tapKey;
import 'delivery_fee_test.dart' show carried, delivery, offered, picked, pumpForm, pumpOrder, websiteFee;
import 'delivery_test.dart' show addressOn, created, elm, enterAddress, key, linda, lindaDigits, typeNumber, typed;
import 'hub.dart';
import 'location_rows.dart';

/// Looking a delivery's distance up from its address (docs/delivery.md, "Looking the distance up"): where the
/// hub has a map service and the restaurant's own address, a form asks how far the address is once it is
/// typed, says what the map said, and picks the band it falls in. Any other price can still be tapped, and
/// what the map said travels with the pick. The hub's side is backend/tests/orders/test_delivery_distance.py.
///
/// A customer who had a delivery brought to the same address before is answered by the hub from that order
/// ("Customers who order again"): the form sends the number with the address, says "as last time", and
/// offers to look it up again.
///
/// Where the hub has a second map service ("A second map service"), its figures pick the price like any
/// other, carry its name beside them, and are not sent back with the pick: they are not to be kept.

const oak = '4 Oak Rd, Woburn';
const main9 = '9 Main St, Winchester';
const mapSaid = {'miles': '3.2', 'minutes': 9};

/// The same as this hub answers it and an order keeps it: with who measured it, and from where.
const mapKept = {...mapSaid, ...Hub.mapMark};

/// A street the first map service does not know, and one it does not know that is too far.
const newbuild = '3 Newbuild Way, Winchester';
const farEnd = '70 Far End Rd, Burlington';

/// How well [ink] reads on [paper]: the contrast ratio of the two, from 1 to 21.
double contrast(Color ink, Color paper) {
  final one = ink.computeLuminance(), other = paper.computeLuminance();
  return ((one > other ? one : other) + 0.05) / ((one > other ? other : one) + 0.05);
}

/// The address typed into a form that is a delivery, and the box left as Enter leaves it.
Future<void> typeAddress(WidgetTester tester, String address) async {
  await enterAddress(tester, address);
  await tester.showKeyboard(key('event-address:zip')); // the last of its boxes: Enter there says it is done
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

/// The to-go form of a hub that knows Linda, and how far Elm Street was the last time she had a delivery
/// brought there: [last], what the map said then.
Future<Terminal> pumpLinda(
  WidgetTester tester, {
  Map<String, dynamic> last = mapSaid,
  String address = elm,
  Size? size,
  double? type,
}) async {
  final t = await pumpForm(tester, fees: Hub.mapFees, size: size, type: type);
  t.hub.customers[lindaDigits] = linda(address: address);
  t.hub.savedDistances[lindaDigits] = {address: last};
  await tapKey(tester, 'channel:phone');
  await typeNumber(tester, '781 555 0101');
  await tapKey(tester, 'handover:delivery');
  return t;
}

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
        ..source = (address, {fresh = false, now = false}) async {
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
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      await stop(tester);
    });

    testWidgets('another price can still be tapped, and what the map said goes with it', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await lindaTo(tester, elm);
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'fee:2'); // a regular
      expect((picked(tester, '2'), picked(tester, '4.5')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '2', 'measured': mapKept});
      await stop(tester);
    });

    testWidgets('a price tapped while the map is asked is not moved by its answer', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      final waits = t.hub.distanceWaits = Completer<void>();
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await enterAddress(tester, elm);
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
        'measured': {'miles': '1.1', 'minutes': 4, ...Hub.mapMark},
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
      await enterAddress(tester, elm);
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
      await enterAddress(tester, elm);
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
      await enterAddress(tester, main9);
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
        'measured': {'miles': '1.1', 'minutes': 4, ...Hub.mapMark},
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
        'measured': {'miles': '9.3', 'minutes': 21, ...Hub.mapMark},
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
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
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
      expect(addressOn(tester), elm);
      // with the number, so the hub can look at her own earlier deliveries first
      expect(t.hub.distanceAsks, [
        {'address': elm, 'phone': '7815550101'},
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
      expect(addressOn(tester), elm);
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

  group('customers who order again', () {
    test('an answer says whether it was saved, and who measured it from where', () {
      final again = FeeLookup.fromJson({...mapKept, 'by': 'miles', 'band': null, 'beyond': false, 'saved': true});
      expect((again.saved, again.measured.service, again.measured.from), (true, 'geocodio', '0a1b2c3d'));
      // both go back with the pick, as they came
      expect(again.measured.toJson(), mapKept);
      expect(FeePick.field('4.5', measured: again.measured), {'up_to': '4.5', 'measured': mapKept});
      expect(OrderFee.of({...carried('4.5', '5.00'), 'measured': mapKept})?.measured, again.measured);
      // a hub that keeps no distances says neither, and one alone is nothing
      final plain = FeeLookup.fromJson({...mapSaid, 'by': 'miles', 'band': null, 'beyond': false});
      expect((plain.saved, plain.measured.service, plain.measured.from), (false, null, null));
      expect(plain.measured.toJson(), mapSaid);
      expect(Measured.of({...mapSaid, 'service': 'geocodio'})?.toJson(), mapSaid);
      expect(Measured.of({...mapSaid, 'from': 5, 'service': 'geocodio'})?.toJson(), mapSaid);
      expect(again.measured == plain.measured, isFalse);
    });

    testWidgets("the hub is sent the number's digits beside the address, and fresh only when asked", (tester) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = Hub.mapFees;
      t.hub.savedDistances[lindaDigits] = {elm: mapSaid};
      final saved = await tester.runAsync(() => t.api.deliveryDistance(elm, phone: '(781) 555-0101'));
      final fresh = await tester.runAsync(() => t.api.deliveryDistance(elm, phone: '781 555 0101', fresh: true));
      final nobody = await tester.runAsync(() => t.api.deliveryDistance(elm, phone: ' '));
      expect((saved?.saved, fresh?.saved, nobody?.saved), (true, false, false));
      expect(t.hub.distanceAsks, [
        {'address': elm, 'phone': lindaDigits},
        {'address': elm, 'phone': lindaDigits, 'fresh': true},
        {'address': elm},
      ]);
      await stop(tester);
    });

    test('asked again and fresh, the same address is asked about once more', () async {
      final asked = <(String, bool)>[];
      final asker = DistanceAsker()
        ..source = (address, {fresh = false, now = false}) async {
          asked.add((address, fresh));
          return FeeLookup(
            measured: const Measured(miles: '3.2', minutes: 9),
            saved: !fresh,
          );
        };
      expect((await asker.ask(elm))?.saved, isTrue);
      expect(await asker.ask(elm), isNull);
      expect((await asker.ask(elm, fresh: true))?.saved, isFalse);
      expect(asked, [(elm, false), (elm, true)]);
      asker.dispose();
    });

    testWidgets('her distance is not looked up again: the form says so and picks the price', (tester) async {
      final t = await pumpLinda(tester);
      expect(addressOn(tester), elm);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive, as last time');
      expect(key('fee-lookup-again'), findsOneWidget);
      expect(picked(tester, '4.5'), isTrue);
      expect(t.hub.distanceAsks, [
        {'address': elm, 'phone': lindaDigits},
      ]);
      await tapKey(tester, 'takeout-start');
      // the figures go on this order too, so the next one finds them on her newest
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      await stop(tester);
    });

    testWidgets('it answers while the map service does not', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      t.hub.refuseDistance = 'unreachable';
      t.hub.customers[lindaDigits] = linda();
      t.hub.savedDistances[lindaDigits] = {elm: mapSaid};
      await tapKey(tester, 'channel:phone');
      await typeNumber(tester, '781 555 0101');
      await tapKey(tester, 'handover:delivery');
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive, as last time');
      expect(key('fee-lookup-problem'), findsNothing);
      expect(picked(tester, '4.5'), isTrue);
      // asked to look it up again, the form says why it cannot, and the price stays as it was
      await tapKey(tester, 'fee-lookup-again');
      expect(key('fee-lookup-problem'), findsOneWidget);
      expect(picked(tester, '4.5'), isTrue);
      // "Try again" asks as the form first did, and her saved distance answers
      await tapKey(tester, 'fee-lookup');
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive, as last time');
      expect([for (final ask in t.hub.distanceAsks) ask['fresh']], [null, true, null]);
      await stop(tester);
    });

    testWidgets('looked up again, the map is asked and the price follows what it says now', (tester) async {
      final t = await pumpLinda(tester);
      t.hub.distances[elm] = {'miles': '1.8', 'minutes': 6}; // a new road since
      await tapKey(tester, 'fee-lookup-again');
      expect(t.hub.distanceAsks.last, {'address': elm, 'phone': lindaDigits, 'fresh': true});
      expect(said(tester, 'fee-lookup-found'), '1.8 mi · 6 min drive');
      expect(key('fee-lookup-again'), findsNothing); // it is the map's own answer now
      expect((picked(tester, '2'), picked(tester, '4.5')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'up_to': '2',
        'measured': {'miles': '1.8', 'minutes': 6, ...Hub.mapMark},
      });
      await stop(tester);
    });

    testWidgets('a price tapped by hand is not moved by looking it up again', (tester) async {
      final t = await pumpLinda(tester);
      await tapKey(tester, 'fee:none');
      t.hub.distances[elm] = {'miles': '1.8', 'minutes': 6};
      await tapKey(tester, 'fee-lookup-again');
      expect(said(tester, 'fee-lookup-found'), '1.8 mi · 6 min drive');
      expect((picked(tester, 'none'), picked(tester, '2')), (true, false));
      await stop(tester);
    });

    testWidgets('another address of hers is looked up, and somebody else at the number is not her', (tester) async {
      final t = await pumpLinda(tester);
      await typeAddress(tester, main9);
      expect(said(tester, 'fee-lookup-found'), '1.1 mi · 4 min drive');
      expect(key('fee-lookup-again'), findsNothing);
      expect(t.hub.distanceAsks.last, {'address': main9, 'phone': lindaDigits});
      // the number changes: the address she typed stays, and is asked about for the new number
      await typeNumber(tester, '781 555 0199');
      await typeAddress(tester, elm);
      expect(t.hub.distanceAsks.last, {'address': elm, 'phone': '7815550199'});
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      await stop(tester);
    });

    testWidgets('further than the prices reach is said of a saved distance too', (tester) async {
      await pumpLinda(tester, address: oak, last: const {'miles': '9.3', 'minutes': 21});
      expect(said(tester, 'fee-lookup-found'), '9.3 mi · 21 min drive, as last time: further than the prices reach');
      expect(key('fee-needed'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      await pumpLinda(tester, size: const Size(320, 640), type: 1.3);
      expect(key('fee-lookup-again'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
      await pumpLinda(
        tester,
        address: oak,
        last: const {'miles': '9.3', 'minutes': 21},
        size: const Size(320, 640),
        type: 1.3,
      );
      expect(key('fee-lookup-again'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets("on the order, the order's own number goes with the address", (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('2', '3.00')), fees: Hub.mapFees);
      t.hub.savedDistances[lindaDigits] = {elm: mapSaid};
      await tapKey(tester, 'when-strip');
      expect(t.hub.distanceAsks, isEmpty); // opening it asks nothing
      await tapKey(tester, 'fee-lookup');
      expect(t.hub.distanceAsks, [
        {'address': elm, 'phone': lindaDigits},
      ]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive, as last time');
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'fee-lookup-again');
      expect(t.hub.distanceAsks.last, {'address': elm, 'phone': lindaDigits, 'fresh': true});
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      await stop(tester);
    });
  });

  group('a second map service', () {
    test('an answer says whose name goes beside it and whether it may be kept', () {
      final google = FeeLookup.fromJson({'miles': '1.6', 'minutes': 5, 'band': null, ...Hub.secondSays});
      expect((google.credit, google.keep, google.measured.service), ('Google Maps', false, 'google'));
      // a service that asks for no name, and a hub from before there was a second
      final plain = FeeLookup.fromJson({...mapKept, 'credit': null, 'keep': true});
      expect((plain.credit, plain.keep), (null, true));
      final older = FeeLookup.fromJson(mapKept);
      expect((older.credit, older.keep), (null, true));
      // not a name
      for (final Object? odd in ['', 'x' * 41, 7]) {
        expect(FeeLookup.fromJson({...mapKept, 'credit': odd}).credit, isNull);
      }
    });

    test('which services the hub has, in the order it asks them, and what a person calls them', () {
      expect(DeliveryFees.fromJson(Hub.twoMapFees).services, ['geocodio', 'google']);
      expect(DeliveryFees.fromJson(Hub.mapFees).services, ['geocodio']);
      expect(DeliveryFees.fromJson(Hub.milesFees).services, isEmpty);
      expect(DeliveryFees.fromJson({...Hub.mapFees, 'services': 'google'}).services, isEmpty);
      expect(
        [
          for (final name in ['geocodio', 'google', 'atlas']) mapServiceName(name),
        ],
        ['Geocodio', 'Google Maps', 'atlas'],
      );
    });

    test('figures that may not be kept are not what a pick sends back', () async {
      final asker = DistanceAsker()
        ..source = (address, {fresh = false, now = false}) async =>
            FeeLookup.fromJson({'miles': '1.6', 'minutes': 5, ...Hub.secondSays});
      final found = await asker.ask(newbuild);
      expect(found?.measured.words, '1.6 mi · 5 min');
      expect(asker.found?.credit, 'Google Maps');
      expect(asker.measuredFor(newbuild), isNull);
      asker.dispose();
    });

    testWidgets("a street the first does not know: the second's figures pick the price, its name beside them", (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.twoMapFees);
      await lindaTo(tester, newbuild);
      expect(t.hub.distanceAsks, [
        {'address': newbuild},
      ]);
      expect(said(tester, 'fee-lookup-found'), '1.6 mi · 5 min drive');
      expect(said(tester, 'fee-lookup-credit'), 'Google Maps');
      expect(key('fee-lookup-again'), findsNothing);
      expect(picked(tester, '2'), isTrue);
      // beside the figures, on their line
      final found = tester.getRect(key('fee-lookup-found')), credit = tester.getRect(key('fee-lookup-credit'));
      expect(credit.left, greaterThan(found.right));
      expect(credit.center.dy, inInclusiveRange(found.top, found.bottom));
      await tapKey(tester, 'takeout-start');
      // the price is on the order, and the figures are not
      expect(created(t.hub)['delivery_fee'], {'up_to': '2'});
      await stop(tester);
    });

    testWidgets("the first service's figures carry no name, and go onto the order as before", (tester) async {
      final t = await pumpForm(tester, fees: Hub.twoMapFees);
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(key('fee-lookup-credit'), findsNothing);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      await stop(tester);
    });

    testWidgets('while the first is not answering, the second says how far any address is', (tester) async {
      final t = await pumpForm(tester, fees: Hub.twoMapFees);
      t.hub.refuseDistance = 'unreachable';
      t.hub.secondDistances[elm] = {'miles': '3.3', 'minutes': 10};
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-found'), '3.3 mi · 10 min drive');
      expect(said(tester, 'fee-lookup-credit'), 'Google Maps');
      expect(picked(tester, '4.5'), isTrue);
      // an address neither knows is said as before
      await typeAddress(tester, '1 Nowhere');
      expect(key('fee-lookup-problem'), findsOneWidget);
      expect(key('fee-lookup-credit'), findsNothing);
      await stop(tester);
    });

    testWidgets('a price tapped by hand is not moved by the second service either, and its name still shows', (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.twoMapFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await tapKey(tester, 'fee:none');
      await typeAddress(tester, newbuild);
      expect(said(tester, 'fee-lookup-credit'), 'Google Maps');
      expect((picked(tester, 'none'), picked(tester, '2')), (true, false));
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': null});
      await stop(tester);
    });

    testWidgets('further than the prices reach is said of it too, with the name under the words', (tester) async {
      await pumpForm(tester, fees: Hub.twoMapFees, size: const Size(360, 720));
      await lindaTo(tester, farEnd);
      expect(said(tester, 'fee-lookup-found'), '9.4 mi · 22 min drive: further than the prices reach');
      expect(key('fee-needed'), findsOneWidget);
      final found = tester.getRect(key('fee-lookup-found')), credit = tester.getRect(key('fee-lookup-credit'));
      expect(credit.top, greaterThanOrEqualTo(found.bottom));
      expect(credit.left, found.left);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type, and the name is never broken in two', (tester) async {
      for (final address in [newbuild, farEnd]) {
        await pumpForm(tester, fees: Hub.twoMapFees, size: const Size(320, 640), type: 1.3);
        await lindaTo(tester, address);
        expect(tester.takeException(), isNull);
        final credit = tester.getRect(key('fee-lookup-credit'));
        expect((credit.left >= 0, credit.right <= 320), (true, true));
        // one line of 12-point type at this reader's size, and no more
        expect(credit.height, lessThan(2 * 12 * 1.3));
        await stop(tester);
      }
    });

    testWidgets('the name is written as its owner asks: its own words, one line, plain, a colour that reads', (
      tester,
    ) async {
      for (final theme in [
        PosTheme.light(),
        PosTheme.dark(),
        PosTheme.light(highContrast: true),
        PosTheme.dark(highContrast: true),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(body: MapCredit('Google Maps')),
          ),
        );
        await tester.pumpAndSettle(); // a theme is faded into
        final text = tester.widget<Text>(key('fee-lookup-credit'));
        final style = text.style!, scheme = theme.colorScheme;
        expect((text.data, text.maxLines, text.softWrap), ('Google Maps', 1, false));
        expect(
          (style.fontFamily, style.fontWeight, style.fontStyle, style.fontSize),
          ('Roboto', FontWeight.w400, FontStyle.normal, 12.0),
        );
        expect(style.color, theme.brightness == Brightness.dark ? MapCredit.onDark : MapCredit.onLight);
        for (final behind in [
          scheme.surface,
          scheme.surfaceContainerLowest,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
        ]) {
          expect(contrast(style.color!, behind), greaterThanOrEqualTo(4.5), reason: '$behind');
        }
      }
    });

    testWidgets("on the order too: the second's figures pick the price and are not written down", (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.twoMapFees);
      await tapKey(tester, 'when-strip');
      await typeAddress(tester, newbuild);
      expect(said(tester, 'fee-lookup-found'), '1.6 mi · 5 min drive');
      expect(said(tester, 'fee-lookup-credit'), 'Google Maps');
      expect(picked(tester, '2'), isTrue);
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect(data['address'], newbuild);
      expect(data['delivery_fee'], {'up_to': '2'});
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
        'measured': {'miles': '1.1', 'minutes': 4, ...Hub.mapMark},
      });
      await stop(tester);
    });

    testWidgets('a fee the website charged is not moved by the map: it says how far, and a tap picks', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: websiteFee), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      await tapKey(tester, 'fee-lookup');
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect((picked(tester, 'kept'), picked(tester, '4.5')), (true, false));
      await typeAddress(tester, main9); // the customer rang: it goes somewhere else
      expect(said(tester, 'fee-lookup-found'), '1.1 mi · 4 min drive');
      expect((picked(tester, 'kept'), picked(tester, '2')), (true, false));
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect((data['address'], data.containsKey('delivery_fee')), (main9, false));
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
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
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

    testWidgets('a hub with a second map service names them both, in the order it asks them', (tester) async {
      final t = await pumpLocation(tester, Hub.twoMapFees);
      await tapKey(tester, 'delivery-fee');
      await tester.ensureVisible(key('fee-origin'));
      expect(
        said(tester, 'fee-maps'),
        'With the address below, the hub asks Geocodio how far a delivery is, and Google Maps when that gives '
        'no distance. The form picks the price. Each is sent the two addresses and nothing else.',
      );
      // and saving sends nothing of them: which services there are is the hub's to say
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees?['services'], ['geocodio', 'google']);
      await stop(tester);
    });

    testWidgets('a hub with the one service says what it said before', (tester) async {
      await pumpLocation(tester, Hub.mapFees);
      await tapKey(tester, 'delivery-fee');
      await tester.ensureVisible(key('fee-origin'));
      expect(
        said(tester, 'fee-maps'),
        'With the address below, the hub asks its map service how far a delivery is and the form picks the '
        'price. The service is sent the two addresses and nothing else.',
      );
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
