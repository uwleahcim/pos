import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/delivery_fee.dart';
import 'package:pos_app/screens/live_drive_dialog.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/takeout.dart';

import 'catering_test.dart' show dataOf, enabled, tapKey;
import 'delivery_distance_test.dart' show lindaTo, main9, mapKept, mapSaid, newbuild, oak, said, typeAddress;
import 'delivery_fee_test.dart' show carried, delivery, picked, pumpForm, pumpOrder;
import 'delivery_test.dart' show created, elm, key, linda, lindaDigits, order, soon, stand, typeNumber, typed;
import 'hub.dart';
import 'location_rows.dart';

/// Live traffic for a delivery's promised time (docs/delivery.md, "Live traffic"): where a manager turned
/// it on and the hub has a map service that knows the roads right now, a delivery for now is promised the
/// minutes the kitchen needs and the drive as it is at that minute, in place of the minutes set for
/// Delivery. The fee does not go by it, an order for later is not asked about, and the drive is written
/// nowhere: the order keeps the time it was promised. The hub's side is in
/// backend/tests/orders/test_delivery_distance.py.

/// What the form is told of Elm Street tonight: fourteen minutes on the road, twenty-five in the kitchen.
const elmNow = {'minutes': 14, 'before': 25, 'credit': 'Google Maps'};

/// The bodies the hub was asked how far an address is with.
List<Map<String, dynamic>> asks(Terminal t) => t.hub.distanceAsks;

/// The minutes an order was promised in, from the time it was started.
int promisedIn(Map<String, dynamic> made) =>
    ((made['promised_at'] as int) - DateTime.now().millisecondsSinceEpoch + 30000) ~/ 60000;

void main() {
  group('what the hub says', () {
    test('whether a delivery for now is promised by the roads', () {
      expect(DeliveryFees.fromJson(Hub.liveFees).live, isTrue);
      expect(DeliveryFees.fromJson(Hub.quietFees).live, isFalse);
      expect(DeliveryFees.fromJson(Hub.twoMapFees).live, isFalse); // a hub from before live traffic
      // and it is the hub's to say: a save does not send it
      expect(DeliveryFees.fromJson(Hub.liveFees).toJson().containsKey('live'), isFalse);
    });

    test('an answer: the drive right now, the kitchen before it, and whose name goes beside it', () {
      final found = FeeLookup.fromJson({...mapSaid, 'drive_now': elmNow});
      expect(found.driveNow, const DriveNow(minutes: 14, before: 25, credit: 'Google Maps'));
      expect(found.driveNow?.promise, 39);
      expect(FeeLookup.fromJson({...mapSaid, 'drive_now': null}).driveNow, isNull);
      expect(FeeLookup.fromJson(mapSaid).driveNow, isNull);
    });

    test('an answer this build cannot read is no answer', () {
      for (final odd in <Object?>[
        'soon',
        {'minutes': '14', 'before': 25},
        {'minutes': 14},
        {'minutes': 0, 'before': 25},
        {'minutes': 14, 'before': -1},
        {'minutes': 5000, 'before': 25},
        {'minutes': 14.5, 'before': 25},
      ]) {
        expect(DriveNow.of(odd), isNull, reason: '$odd');
      }
      // a name too long to be a name is left off; the figure stands
      expect(DriveNow.of({'minutes': 14, 'before': 0, 'credit': 'x' * 41}), const DriveNow(minutes: 14, before: 0));
    });

    test('the setting: what a manager set and what the hub has for it', () {
      final live = LiveDrive.fromJson(Hub.liveOn);
      expect((live.enabled, live.before, live.traffic, live.origin, live.live), (true, 25, true, true, true));
      expect(live.toJson(), {'enabled': true, 'before': 25});
      final none = LiveDrive.fromJson(const {});
      expect((none.enabled, none.before, none.live), (false, 25, false));
    });

    test('the quote: the kitchen and the drive for a delivery for now, and for nothing else', () {
      const quotes = Quotes();
      const drive = DriveNow(minutes: 14, before: 25);
      final now = DateTime(2026, 11, 19, 18);
      expect(quotes.minutesFor('phone', at: now, delivery: true, drive: drive), 39);
      expect(quotes.minutesFor('phone', at: now, delivery: true), 45);
      // one the customer named a time for, one that is picked up, and a catering order
      expect(
        quotes.minutesFor('phone', at: now, promised: now.add(const Duration(hours: 3)), delivery: true, drive: drive),
        45,
      );
      expect(quotes.minutesFor('phone', at: now, drive: drive), 20);
      expect(quotes.minutesFor('catering', at: now, delivery: true, drive: drive), cateringLead);
      // the busy kitchen's minutes come on top
      final busy = Quotes(rush: Rush(minutes: 10, until: now.add(const Duration(hours: 4)).millisecondsSinceEpoch));
      expect(busy.minutesFor('phone', at: now, delivery: true, drive: drive), 49);
    });

    testWidgets('a hub older than live traffic has no setting to read', (tester) async {
      final t = await terminal(tester);
      expect(await tester.runAsync(t.api.liveDrive), isNull);
      t.hub.liveDrive = Hub.liveOn;
      expect((await tester.runAsync(t.api.liveDrive))?.live, isTrue);
    });
  });

  group('the to-go form', () {
    testWidgets('a delivery for now is promised the kitchen and the drive as it is, and the order keeps the promise', (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      // nowhere to go yet: the minutes set for Delivery
      expect(said(tester, 'takeout-quote'), 'There in about 45 min');
      await typeAddress(tester, elm);
      expect(asks(t), [
        {'address': elm, 'now': true},
      ]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect(said(tester, 'fee-lookup-now-credit'), 'Google Maps');
      expect(key('fee-lookup-credit'), findsNothing); // the distance is Geocodio's, which asks for no name
      expect(said(tester, 'takeout-quote'), 'There in about 39 min, with traffic');
      // the name stands beside its figure, on its line
      final figure = tester.getRect(key('fee-lookup-now')), name = tester.getRect(key('fee-lookup-now-credit'));
      expect(name.left, greaterThan(figure.right));
      expect(name.center.dy, inInclusiveRange(figure.top, figure.bottom));
      // the fee goes by the miles, as ever
      expect((picked(tester, '4.5'), picked(tester, '2')), (true, false));
      await tapKey(tester, 'takeout-start');
      final made = created(t.hub);
      expect((made['quoted_minutes'], promisedIn(made)), (39, 39));
      // and nothing of the drive is written down
      expect(made['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      expect(jsonEncode(made), isNot(anyOf(contains('drive'), contains('Google'))));
      await stop(tester);
    });

    testWidgets("priced by the minutes of the drive, the fee goes by the usual drive and not by tonight's", (
      tester,
    ) async {
      final t = await pumpForm(
        tester,
        fees: {
          ...Hub.liveFees,
          'by': 'minutes',
          'bands': [
            {'up_to': '10', 'fee': '3.00'},
            {'up_to': '20', 'fee': '6.00'},
          ],
        },
      );
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect((picked(tester, '10'), picked(tester, '20')), (true, false)); // nine minutes on a usual day
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '10', 'measured': mapKept});
      await stop(tester);
    });

    testWidgets("when nobody can say how the roads are, it is promised Delivery's minutes and nothing is said", (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      t.hub.noRoads = true;
      await lindaTo(tester, elm);
      expect(asks(t).single['now'], isTrue);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(key('fee-lookup-now'), findsNothing);
      expect(key('fee-lookup-problem'), findsNothing);
      expect(said(tester, 'takeout-quote'), 'There in about 45 min');
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['quoted_minutes'], 45);
      await stop(tester);
    });

    testWidgets('an address typed over is promised the usual minutes until the hub says again', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      await lindaTo(tester, elm);
      expect(said(tester, 'takeout-quote'), 'There in about 39 min, with traffic');
      await tester.enterText(key('event-address'), oak);
      await tester.pump();
      expect(said(tester, 'takeout-quote'), 'There in about 45 min');
      expect(key('fee-lookup-now'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 30 min');
      expect(said(tester, 'takeout-quote'), 'There in about 55 min, with traffic');
      expect(asks(t).length, 2);
      await stop(tester);
    });

    testWidgets('an order for later is not asked about the roads; made one for now after all, it is', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'takeout-later');
      await tapKey(tester, 'handover:delivery');
      await typeAddress(tester, elm);
      expect(asks(t), [
        {'address': elm},
      ]);
      expect(key('fee-lookup-now'), findsNothing);
      expect(picked(tester, '4.5'), isTrue);
      // for now after all
      await tester.ensureVisible(key('takeout-later'));
      await tapKey(tester, 'takeout-later');
      expect(asks(t), [
        {'address': elm},
        {'address': elm, 'now': true},
      ]);
      expect(said(tester, 'takeout-quote'), 'There in about 39 min, with traffic');
      // and for later again: what was asked is enough
      await tapKey(tester, 'takeout-later');
      expect(asks(t).length, 2);
      expect(said(tester, 'takeout-quote'), 'Prints ahead of its time by the quote');
      await stop(tester);
    });

    testWidgets('a catering order is not asked about the roads either', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:catering');
      await tester.ensureVisible(key('handover:delivery'));
      await tapKey(tester, 'handover:delivery');
      await tester.ensureVisible(key('event-address'));
      await typeAddress(tester, elm);
      expect(asks(t), [
        {'address': elm},
      ]);
      expect(key('fee-lookup-now'), findsNothing);
      expect(said(tester, 'takeout-quote'), 'The kitchen gets its ticket 60 min before its time.');
      await stop(tester);
    });

    testWidgets("the busy kitchen's minutes come on top of the kitchen and the drive", (tester) async {
      final t = await stand(tester);
      t.hub.deliveryFees = Hub.liveFees;
      t.hub.quotes = {
        ...t.hub.quotes,
        'rush': {'minutes': 10, 'until': DateTime.now().add(const Duration(hours: 4)).millisecondsSinceEpoch},
      };
      await pumpOrdersOn(tester, t);
      await tapKey(tester, 'to-go');
      await lindaTo(tester, elm);
      expect(said(tester, 'takeout-quote'), 'There in about 49 min, with traffic (busy kitchen: +10)');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['quoted_minutes'], 49);
      await stop(tester);
    });

    testWidgets("a returning customer's distance is hers from last time, and the roads are asked all the same", (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      t.hub.customers[lindaDigits] = linda();
      t.hub.savedDistances[lindaDigits] = {elm: mapSaid};
      await tapKey(tester, 'channel:phone');
      await typeNumber(tester, '781 555 0101');
      await tapKey(tester, 'handover:delivery');
      expect(asks(t), [
        {'address': elm, 'phone': lindaDigits, 'now': true},
      ]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive, as last time');
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect(said(tester, 'takeout-quote'), 'There in about 39 min, with traffic');
      // looked up again, it is still a delivery for now
      await tapKey(tester, 'fee-lookup-again');
      expect(asks(t).last, {'address': elm, 'phone': lindaDigits, 'fresh': true, 'now': true});
      expect(said(tester, 'takeout-quote'), 'There in about 39 min, with traffic');
      await stop(tester);
    });

    testWidgets('a street only the second service knows: one name serves both its figures', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      await lindaTo(tester, newbuild);
      expect(said(tester, 'fee-lookup-found'), '1.6 mi · 5 min drive');
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 6 min');
      expect(said(tester, 'fee-lookup-credit'), 'Google Maps');
      expect(key('fee-lookup-now-credit'), findsNothing);
      expect(said(tester, 'takeout-quote'), 'There in about 31 min, with traffic');
      await tapKey(tester, 'takeout-start');
      // neither of its figures is written down
      expect(created(t.hub)['delivery_fee'], {'up_to': '2'});
      expect(created(t.hub)['quoted_minutes'], 31);
      await stop(tester);
    });

    testWidgets('a price tapped by hand stays, and the time still goes by the roads', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await tester.ensureVisible(key('fee:none'));
      await tapKey(tester, 'fee:none');
      await typeAddress(tester, elm);
      expect(picked(tester, 'none'), isTrue);
      expect(said(tester, 'takeout-quote'), 'There in about 39 min, with traffic');
      await tapKey(tester, 'takeout-start');
      expect((created(t.hub)['delivery_fee'] as Map)['up_to'], isNull);
      expect(created(t.hub)['quoted_minutes'], 39);
      await stop(tester);
    });

    testWidgets('where live traffic is off, the form asks and promises as before', (tester) async {
      for (final fees in [Hub.quietFees, Hub.twoMapFees]) {
        final t = await pumpForm(tester, fees: fees);
        await lindaTo(tester, elm);
        expect(asks(t), [
          {'address': elm},
        ]);
        expect(key('fee-lookup-now'), findsNothing);
        expect(said(tester, 'takeout-quote'), 'There in about 45 min');
        await tapKey(tester, 'takeout-start');
        expect(created(t.hub)['quoted_minutes'], 45);
        await stop(tester);
      }
    });

    testWidgets('it fits a small phone with large type, and the name is never broken in two', (tester) async {
      await pumpForm(tester, fees: Hub.liveFees, size: const Size(320, 640), type: 1.3);
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect(tester.takeException(), isNull);
      final oneLine = tester.getSize(key('fee-lookup-now-credit')).height;
      await typeAddress(tester, newbuild);
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 6 min');
      expect(tester.getSize(key('fee-lookup-credit')).height, oneLine);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('takeout-quote'));
      await tester.pumpAndSettle();
      expect(said(tester, 'takeout-quote'), 'There in about 31 min, with traffic');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('on the order', () {
    testWidgets('a pickup for now made a delivery is promised by the roads', (tester) async {
      final t = await pumpOrder(tester, delivery(brought: false), fees: Hub.liveFees);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'handover:delivery');
      await typeAddress(tester, elm);
      expect(asks(t), [
        {'address': elm, 'phone': lindaDigits, 'now': true},
      ]);
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect(said(tester, 'fee-lookup-now-credit'), 'Google Maps');
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      // the kitchen and the drive, 39, in place of the phone's twenty
      final at = soon.millisecondsSinceEpoch + 19 * 60000;
      expect((data['quoted_minutes'], data['promised_at']), (39, at));
      expect(data['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      expect(jsonEncode(data), isNot(anyOf(contains('drive'), contains('Google'))));
      expect(said(tester, 'leaving-said-words'), 'Now a delivery: there about ${clockTime(at)}.');
      await stop(tester);
    });

    testWidgets("when nobody can say how the roads are, it is promised Delivery's minutes", (tester) async {
      final t = await pumpOrder(tester, delivery(brought: false), fees: Hub.liveFees);
      t.hub.noRoads = true;
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'handover:delivery');
      await typeAddress(tester, elm);
      expect(key('fee-lookup-now'), findsNothing);
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect((data['quoted_minutes'], data['promised_at']), (45, soon.millisecondsSinceEpoch + 25 * 60000));
      await stop(tester);
    });

    testWidgets('a delivery whose address is changed keeps its time, and the roads are not asked about', (
      tester,
    ) async {
      final t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.liveFees);
      await tapKey(tester, 'when-strip');
      await typeAddress(tester, main9);
      expect(asks(t), [
        {'address': main9, 'phone': lindaDigits},
      ]);
      expect(key('fee-lookup-now'), findsNothing);
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field', 'o1');
      expect(data.containsKey('quoted_minutes') || data.containsKey('promised_at'), isFalse);
      await stop(tester);
    });

    testWidgets('an order for later made a delivery is not asked about the roads', (tester) async {
      final t = await pumpOrder(tester, order(later: true), fees: Hub.liveFees);
      await tapKey(tester, 'when-strip');
      await tapKey(tester, 'handover:delivery');
      await typeAddress(tester, elm);
      expect(asks(t), [
        {'address': elm, 'phone': lindaDigits},
      ]);
      expect(key('fee-lookup-now'), findsNothing);
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['quoted_minutes'], 45);
      await stop(tester);
    });

    testWidgets('where live traffic is off the dialog asks as before', (tester) async {
      final t = await pumpOrder(tester, delivery(brought: false), fees: Hub.quietFees);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'handover:delivery');
      await typeAddress(tester, elm);
      expect(asks(t), [
        {'address': elm, 'phone': lindaDigits},
      ]);
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['quoted_minutes'], 45);
      await stop(tester);
    });
  });

  group('under Location', () {
    Future<Terminal> pumpLocation(
      WidgetTester tester, {
      Map<String, dynamic>? live,
      Map<String, dynamic>? fees,
      Size? size,
      double? type,
    }) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = fees ?? Hub.quietFees;
      t.hub.liveDrive = live;
      if (size != null) tester.view.physicalSize = size;
      if (type != null) {
        tester.platformDispatcher.textScaleFactorTestValue = type;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'live-traffic');
      return t;
    }

    String rowWords(WidgetTester tester) => ((tester.widget<ListTile>(key('live-traffic')).subtitle!) as Text).data!;

    testWidgets('it is off until a manager turns it on, and says how long the kitchen needs', (tester) async {
      final t = await pumpLocation(tester, live: Hub.liveOff);
      expect(rowWords(tester), 'Off: a delivery is promised the minutes set for Delivery');
      await tapKey(tester, 'live-traffic');
      expect(find.byType(LiveDriveDialog), findsOneWidget);
      expect(tester.widget<SwitchListTile>(key('live-enabled')).value, isFalse);
      expect(typed(tester, 'live-before'), '25');
      expect(said(tester, 'live-says'), contains('sent the two addresses and nothing else'));
      expect(said(tester, 'live-says'), contains('The fee does not change'));
      await tapKey(tester, 'live-enabled');
      await tester.enterText(key('live-before'), '30');
      await tapKey(tester, 'live-save');
      expect(t.hub.liveDriveAuth, 'Bearer tok-admin');
      expect((t.hub.liveDrive?['enabled'], t.hub.liveDrive?['before'], t.hub.liveDrive?['live']), (true, 30, true));
      expect(t.hub.deliveryFees?['live'], isTrue);
      expect(find.byType(LiveDriveDialog), findsNothing);
      expect(rowWords(tester), 'On: a delivery for now is promised 30 min and the drive as the roads are');
      // and off again
      await tapKey(tester, 'live-traffic');
      expect(typed(tester, 'live-before'), '30');
      await tapKey(tester, 'live-enabled');
      await tapKey(tester, 'live-save');
      expect((t.hub.liveDrive?['enabled'], t.hub.liveDrive?['before']), (false, 30));
      expect(rowWords(tester), startsWith('Off'));
      await stop(tester);
    });

    testWidgets('a hub with no Google Maps key says so, and keeps the switch for the day it has one', (tester) async {
      final t = await pumpLocation(tester, live: {...Hub.liveOff, 'traffic': false});
      await tapKey(tester, 'live-traffic');
      expect(said(tester, 'live-says'), startsWith('This hub has no Google Maps key yet'));
      await tapKey(tester, 'live-enabled');
      await tapKey(tester, 'live-save');
      expect((t.hub.liveDrive?['enabled'], t.hub.liveDrive?['live']), (true, false));
      expect(rowWords(tester), startsWith('On, but not used yet. This hub has no Google Maps key yet'));
      await stop(tester);
    });

    testWidgets("it says when the restaurant's address or the delivery fee is still missing", (tester) async {
      await pumpLocation(tester, live: {...Hub.liveOn, 'origin': false, 'live': false});
      expect(rowWords(tester), startsWith("On, but not used yet. The restaurant's address is not set yet"));
      await stop(tester);
      await pumpLocation(tester, live: Hub.liveOn, fees: {...Hub.liveFees, 'enabled': false});
      expect(rowWords(tester), startsWith('On, but not used yet. The delivery fee is off or has no prices'));
      await tapKey(tester, 'live-traffic');
      expect(said(tester, 'live-says'), startsWith('The delivery fee is off or has no prices'));
      await stop(tester);
    });

    testWidgets('minutes that are no whole number up to 240 are not sent, and what the hub refuses is said', (
      tester,
    ) async {
      final t = await pumpLocation(tester, live: Hub.liveOff);
      await tapKey(tester, 'live-traffic');
      for (final odd in ['', '241', '999']) {
        await tester.enterText(key('live-before'), odd);
        await tapKey(tester, 'live-save');
        expect(said(tester, 'live-problem'), 'The minutes are a whole number from 0 to 240');
      }
      expect(t.hub.liveDriveAuth, isNull);
      t.hub.refuseLiveDrive = 'the minutes before the drive are 240 at most';
      await tester.enterText(key('live-before'), '0');
      await tapKey(tester, 'live-save');
      expect(said(tester, 'live-problem'), 'the minutes before the drive are 240 at most');
      expect(find.byType(LiveDriveDialog), findsOneWidget);
      t.hub.refuseLiveDrive = null;
      await tapKey(tester, 'live-save');
      expect(t.hub.liveDrive?['before'], 0);
      await stop(tester);
    });

    testWidgets('a hub older than live traffic says so, and the row opens nothing', (tester) async {
      await pumpLocation(tester);
      expect(rowWords(tester), 'The hub has not answered about live traffic (an older hub: update it)');
      expect(tester.widget<ListTile>(key('live-traffic')).onTap, isNull);
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the dialog fits with large type', (tester) async {
      await pumpLocation(tester, live: Hub.liveOn, fees: Hub.liveFees, size: const Size(320, 640), type: 1.3);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'live-traffic');
      await tester.pumpAndSettle();
      expect(find.byType(LiveDriveDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('live-says'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(enabled(tester, 'live-save'), isTrue);
      await stop(tester);
    });
  });
}
