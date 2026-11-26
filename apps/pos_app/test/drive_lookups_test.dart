import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/delivery_fee.dart';
import 'package:pos_app/drive_lookups.dart';
import 'package:pos_app/screens/delivery_fee_dialog.dart';
import 'package:pos_app/screens/live_drive_dialog.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/service_badge.dart';

import 'catering_test.dart' show enabled, tapKey;
import 'delivery_distance_test.dart' show lindaTo, mapSaid, newbuild, oak, said;
import 'delivery_fee_test.dart' show pumpForm;
import 'delivery_test.dart' show elm, enterAddress, key;
import 'hub.dart';
import 'location_rows.dart';

/// Which map service is asked first for a delivery's drive (docs/delivery.md, "Which service is asked
/// first"): under Location, the Delivery fee's dialog lists the services that can say how far a delivery
/// goes and Live traffic's the ones that know the roads right now. A manager drags them into the order they
/// are asked and turns each on or off, and each row says how many of its day's lookups are left. On a
/// delivery's form a small badge before each figure says who gave it. The hub's side is in
/// backend/tests/orders/test_drive_lookups.py.

/// A hub with all four services as they stand before anybody changed a thing, with prices, the restaurant's
/// address and live traffic on.
void whole(Hub hub) {
  hub.deliveryFees = {
    ...Hub.liveFees,
    'services': ['geocodio', 'google'],
  };
  hub.liveDrive = Hub.liveOn;
  hub.driveLookups = Hub.driveLookupsUsual;
}

/// The services of a list as they stand on the screen, from the top. [mark] is `fee-services` or
/// `live-services`.
List<String> placed(WidgetTester tester, String mark) {
  final names = ['geocodio', 'google', 'mapbox', 'azure'].where((name) => key('$mark:$name').evaluate().isNotEmpty);
  return names.toList()..sort(
    (one, other) => tester.getTopLeft(key('$mark:$one')).dy.compareTo(tester.getTopLeft(key('$mark:$other')).dy),
  );
}

/// Drags a service by its handle past this many of the rows under it (above it, when fewer than none), as a
/// finger does: a little at a time, since the list looks at where the row is at each move.
Future<void> dragPast(WidgetTester tester, String mark, String service, int rows) async {
  final order = placed(tester, mark), at = order.indexOf(service);
  final passed = rows > 0 ? order.sublist(at + 1, at + 1 + rows) : order.sublist(at + rows, at);
  final far = [for (final other in passed) tester.getSize(key('$mark-row:$other')).height]
      .fold(0.0, (sum, high) => sum + high);
  await tester.ensureVisible(key('$mark-handle:$service'));
  await tester.pumpAndSettle();
  final finger = await tester.startGesture(tester.getCenter(key('$mark-handle:$service')));
  const step = 8.0;
  for (var moved = 0.0; moved < far; moved += step) {
    await finger.moveBy(Offset(0, (rows > 0 ? 1 : -1) * (far - moved < step ? far - moved : step)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await finger.up();
  await tester.pumpAndSettle();
}

bool switched(WidgetTester tester, String mark, String service) =>
    tester.widget<SwitchListTile>(key('$mark:$service')).value;

Future<void> turn(WidgetTester tester, String mark, String service) async {
  await tester.ensureVisible(key('$mark:$service'));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: key('$mark:$service'), matching: find.byType(Switch)));
  await tester.pumpAndSettle();
}

/// What a badge says to a reader and in its tooltip.
String badgeSays(WidgetTester tester, String name) =>
    tester.widget<Tooltip>(find.descendant(of: key(name), matching: find.byType(Tooltip))).message!;

void main() {
  group('what the hub says', () {
    test('the services of each list in the order they are asked, and how each stands today', () {
      final lookups = DriveLookups.fromJson(Hub.driveLookupsUsual);
      expect([for (final one in lookups.distance.services) one.name], ['geocodio', 'google', 'mapbox', 'azure']);
      expect([for (final one in lookups.traffic.services) one.name], ['google', 'mapbox', 'azure']);
      expect([for (final one in lookups.distance.asking) one.title], ['Geocodio', 'Google Maps']);
      expect([for (final one in lookups.traffic.asking) one.title], ['Google Maps']);
      final geocodio = lookups.distance.named('geocodio')!;
      expect(
        (geocodio.on, geocodio.key, geocodio.asks, geocodio.left, geocodio.dailyMost),
        (true, true, true, 488, 500),
      );
      expect(geocodio.words, '488 of 500 lookups left today');
      expect(geocodio.share, closeTo(0.976, 0.0005));
      expect((geocodio.troubled, geocodio.usedUp), (false, false));
      expect(lookups.distance.named('here'), isNull);
    });

    test('a service with no key, one that is used up, and one that gave nothing the last time', () {
      DriveService of(Map<String, dynamic> json) => DriveService.of(json)!;
      final none = of(Hub.driveService('azure', key: false));
      expect(none.words, 'This hub has no key for it (Keys and connections, on this screen)');
      expect((none.asks, none.troubled, none.share, none.leftWords), (false, false, null, null));
      final used = of(Hub.driveService('azure', most: 15, left: 0));
      expect((used.words, used.troubled, used.usedUp), ('Asked as often as it may be today', true, true));
      final refused = of(Hub.driveService('mapbox', left: 499, failing: 'refused'));
      expect(refused.words, '499 of 500 lookups left today. Its key was refused the last time it was asked');
      expect(refused.troubled, isTrue);
      final silent = of(Hub.driveService('mapbox', failing: 'unreachable'));
      expect(silent.words, endsWith('It did not answer the last time it was asked'));
      // an address it could not find says nothing about the service
      final lost = of(Hub.driveService('mapbox', failing: 'not_found'));
      expect((lost.words, lost.troubled), ('500 of 500 lookups left today', false));
      // what names no service is none
      for (final odd in <Object?>[
        null,
        'google',
        <String, dynamic>{},
        {'name': ''},
        {'name': 5},
      ]) {
        expect(DriveService.of(odd), isNull, reason: '$odd');
      }
      expect(DriveService.of({'name': 'here'})!.title, 'here');
    });

    test('what is left today in words, and as a share of the day', () {
      expect(leftToday(1500, 2000), '1,500 of 2,000 lookups left today');
      expect(leftToday(0, 15), '0 of 15 lookups left today');
      expect((leftToday(1, null), leftToday(0, null)), ('1 lookup left today', 'no lookups left today'));
      expect(leftToday(null, 500), isNull);
      expect(
        (leftShare(250, 500), leftShare(600, 500), leftShare(null, 500), leftShare(5, null)),
        (0.5, 1.0, null, null),
      );
    });

    test('a dialog puts them in another order and turns one on, and that is what is saved', () {
      final distance = DriveLookups.fromJson(Hub.driveLookupsUsual).distance;
      expect(distance.turned(const {}, ['geocodio', 'google', 'mapbox', 'azure']).sameAs(distance), isTrue);
      final wanted = distance.turned({'mapbox': true, 'geocodio': false}, ['mapbox', 'google']);
      expect(wanted.sameAs(distance), isFalse);
      expect(wanted.toJson(), {
        'mapbox': true,
        'google': true,
        'geocodio': false,
        'azure': false,
        'order': ['mapbox', 'google', 'geocodio', 'azure'],
      });
      expect([for (final one in wanted.asking) one.name], ['mapbox', 'google']);
      // what the hub said of each stays with it
      expect(wanted.named('geocodio')!.left, 488);
      // a hub that says nothing of them lists none
      expect(DriveLookups.fromJson(const {}).distance.services, isEmpty);
      expect(DriveOrder.fromJson('soon').services, isEmpty);
    });

    test('an answer about an address says who measured it and who knows the roads, with what each has left', () {
      final found = FeeLookup.fromJson({
        ...mapSaid,
        'service': 'geocodio',
        'title': 'Geocodio',
        'left': 488,
        'daily_most': 500,
        'drive_now': {
          'minutes': 14,
          'before': 25,
          'credit': 'Google Maps',
          'service': 'google',
          'title': 'Google Maps',
          'left': 141,
          'daily_most': 150,
        },
      });
      final by = found.by!, roads = found.driveNow!.by!;
      expect((by.service, by.title, by.left, by.dailyMost), ('geocodio', 'Geocodio', 488, 500));
      expect((roads.service, roads.title, roads.left, roads.dailyMost), ('google', 'Google Maps', 141, 150));
      // the promise is the same figure whoever said it
      expect(found.driveNow, const DriveNow(minutes: 14, before: 25, credit: 'Google Maps'));
      // a hub from before the badge names the service and nothing more: no badge
      expect(FeeLookup.fromJson({...mapSaid, ...Hub.mapMark}).by, isNull);
      expect(DriveNow.of({'minutes': 14, 'before': 25, 'credit': 'Google Maps'})!.by, isNull);
      // a hub that has no key for the service any more says who it was and not what is left
      final gone = AnsweredBy.of({'service': 'geocodio', 'title': 'Geocodio', 'left': null, 'daily_most': null})!;
      expect((gone.left, gone.dailyMost), (null, null));
      expect(AnsweredBy.of({'service': 'geocodio', 'title': 'x' * 41}), isNull);
    });

    test('each service has its letter, and Geocodio two since Google has the G', () {
      expect(
        [
          for (final name in ['geocodio', 'google', 'mapbox', 'azure']) ServiceBadge.letterOf(name, ''),
        ],
        ['Ge', 'G', 'M', 'A'],
      );
      expect((mapServiceName('mapbox'), mapServiceName('azure')), ('Mapbox', 'Azure Maps'));
    });
  });

  group('under Location, the Delivery fee', () {
    const mark = 'fee-services';

    Future<Terminal> pumpLocation(WidgetTester tester, {void Function(Hub hub)? hub, Size? size, double? type}) async {
      final t = await terminal(tester);
      whole(t.hub);
      hub?.call(t.hub);
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
      await bringUp(tester, 'delivery-fee');
      return t;
    }

    testWidgets('lists who can say how far a delivery goes, in the order they are asked, with what is left', (
      tester,
    ) async {
      final t = await pumpLocation(tester);
      await tapKey(tester, 'delivery-fee');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      await tester.ensureVisible(key('fee-origin'));
      await tester.pumpAndSettle();
      expect(placed(tester, mark), ['geocodio', 'google', 'mapbox', 'azure']);
      expect(
        [for (final service in placed(tester, mark)) said(tester, '$mark-name:$service')],
        ['1. Geocodio', '2. Google Maps', '3. Mapbox', '4. Azure Maps'],
      );
      expect([for (final service in placed(tester, mark)) switched(tester, mark, service)], [true, true, false, false]);
      expect(said(tester, '$mark-state:geocodio'), '488 of 500 lookups left today');
      expect(said(tester, '$mark-state:google'), '97 of 100 lookups left today');
      expect(said(tester, '$mark-state:azure'), '15 of 15 lookups left today');
      expect(badgeSays(tester, '$mark-badge:geocodio'), 'Geocodio: 488 of 500 lookups left today');
      expect(said(tester, 'fee-maps'), contains('They are asked in this order'));
      expect(said(tester, 'fee-maps'), contains('Drag one by its handle'));
      expect(said(tester, 'fee-maps'), contains('sent the two addresses and nothing else'));
      expect(said(tester, 'fee-services-says'), isNot(contains('Mapbox')));
      for (final service in placed(tester, mark)) {
        // each handle stands before its badge, at the left edge of the words above it
        final handle = tester.getRect(key('$mark-handle:$service'));
        expect(handle.left, tester.getRect(key('fee-maps')).left);
        expect(handle.right, lessThanOrEqualTo(tester.getRect(key('$mark-badge:$service')).left));
        expect((handle.width >= 34, handle.height >= 44), (true, true));
      }
      // looking changes nothing: a save of the prices sends no order
      await tapKey(tester, 'fee-save');
      expect(t.hub.driveLookupsSaved, isEmpty);
      expect(t.hub.deliveryFeesAuth, 'Bearer tok-admin');
      await stop(tester);
    });

    testWidgets('a drag puts a service first and a switch turns one on, and Save keeps both with the prices', (
      tester,
    ) async {
      final t = await pumpLocation(tester);
      await tapKey(tester, 'delivery-fee');
      await dragPast(tester, mark, 'google', -1);
      expect(placed(tester, mark), ['google', 'geocodio', 'mapbox', 'azure']);
      expect(said(tester, '$mark-name:google'), '1. Google Maps');
      await turn(tester, mark, 'mapbox');
      expect(switched(tester, mark, 'mapbox'), isTrue);
      // Mapbox finds the address first, out of the Address list's free lookups: said once it is asked
      expect(said(tester, 'fee-services-says'), contains('same free lookups as the Address list'));
      await dragPast(tester, mark, 'mapbox', -2);
      expect(placed(tester, mark), ['mapbox', 'google', 'geocodio', 'azure']);
      expect(t.hub.driveLookupsSaved, isEmpty); // nothing is saved by a drag alone
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'fee-save');
      expect(find.byType(DeliveryFeeDialog), findsNothing);
      // the order of the distance alone: who is asked about the roads is left as it is
      expect(t.hub.driveLookupsSaved, [
        {
          'distance': {
            'mapbox': true,
            'google': true,
            'geocodio': true,
            'azure': false,
            'order': ['mapbox', 'google', 'geocodio', 'azure'],
          },
        },
      ]);
      expect(t.hub.driveLookupsAuth, 'Bearer tok-admin');
      expect(t.hub.deliveryFees?['services'], ['mapbox', 'google', 'geocodio']);
      expect(t.hub.driveAsking('traffic'), ['google']);
      // opened again, it stands as it was saved
      await tapKey(tester, 'delivery-fee');
      expect(placed(tester, mark), ['mapbox', 'google', 'geocodio', 'azure']);
      expect(said(tester, '$mark-name:mapbox'), '1. Mapbox');
      expect(switched(tester, mark, 'mapbox'), isTrue);
      await stop(tester);
    });

    testWidgets('Cancel keeps nothing, and an order the hub refuses is said and the dialog stays', (tester) async {
      final t = await pumpLocation(tester);
      await tapKey(tester, 'delivery-fee');
      await dragPast(tester, mark, 'geocodio', 1);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.driveLookupsSaved, isEmpty);
      await tapKey(tester, 'delivery-fee');
      expect(placed(tester, mark), ['geocodio', 'google', 'mapbox', 'azure']);
      await turn(tester, mark, 'geocodio');
      t.hub.refuseDriveLookups = 'order names a service there is none of';
      await tapKey(tester, 'fee-save');
      expect(said(tester, 'fee-problem'), 'order names a service there is none of');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      expect(t.hub.deliveryFeesAuth, isNull); // the prices were not sent after it
      t.hub.refuseDriveLookups = null;
      await tapKey(tester, 'fee-save');
      expect(find.byType(DeliveryFeeDialog), findsNothing);
      expect(t.hub.deliveryFees?['services'], ['google']);
      await stop(tester);
    });

    testWidgets('with every one turned off it says the price is picked by hand', (tester) async {
      final t = await pumpLocation(tester);
      await tapKey(tester, 'delivery-fee');
      expect(key('fee-services-none'), findsNothing);
      await turn(tester, mark, 'geocodio');
      await turn(tester, mark, 'google');
      expect(said(tester, 'fee-services-none'), 'None that is turned on has a key: the price is picked by hand.');
      await tapKey(tester, 'fee-save');
      expect((t.hub.deliveryFees?['maps'], t.hub.deliveryFees?['lookup']), (false, false));
      await stop(tester);
    });

    testWidgets('a hub with no key for any of them says so, and one that gave nothing is marked', (tester) async {
      await pumpLocation(
        tester,
        hub: (hub) => hub.driveLookups = {
          ...Hub.driveLookupsUsual,
          'distance': Hub.driveOrderOf([
            for (final name in ['geocodio', 'google', 'mapbox', 'azure']) Hub.driveService(name, key: false),
          ]),
        },
      );
      await tapKey(tester, 'delivery-fee');
      expect(said(tester, 'fee-maps'), startsWith('This hub has no key for a map service yet'));
      expect(said(tester, '$mark-state:geocodio'), startsWith('This hub has no key for it'));
      expect(key('fee-services-none'), findsNothing);
      await stop(tester);
      await pumpLocation(
        tester,
        hub: (hub) => hub.driveLookups = {
          ...Hub.driveLookupsUsual,
          'distance': Hub.driveOrderOf([
            Hub.driveService('mapbox', left: 499, failing: 'refused'),
            Hub.driveService('geocodio'),
          ]),
        },
      );
      await tapKey(tester, 'delivery-fee');
      final words = tester.widget<Text>(key('$mark-state:mapbox'));
      expect(words.data, '499 of 500 lookups left today. Its key was refused the last time it was asked');
      expect(words.style?.color, Theme.of(tester.element(key('$mark-state:mapbox'))).colorScheme.error);
      await stop(tester);
    });

    testWidgets('a hub older than the order shows the dialog as it was', (tester) async {
      final t = await pumpLocation(tester, hub: (hub) => hub.driveLookups = null);
      await tapKey(tester, 'delivery-fee');
      expect(key(mark), findsNothing);
      expect(said(tester, 'fee-maps'), contains('the hub asks Geocodio how far a delivery is, and Google Maps when'));
      await tapKey(tester, 'fee-save');
      expect(t.hub.driveLookupsSaved, isEmpty);
      expect(find.byType(DeliveryFeeDialog), findsNothing);
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the rows fit with large type and still drag', (tester) async {
      await pumpLocation(tester, size: const Size(320, 640), type: 1.3);
      await tapKey(tester, 'delivery-fee');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('fee-origin'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final service in ['geocodio', 'google', 'mapbox', 'azure']) {
        final row = tester.getRect(key('$mark-row:$service'));
        expect((row.left >= 0, row.right <= 320), (true, true), reason: service);
      }
      await dragPast(tester, mark, 'azure', -3);
      expect(placed(tester, mark), ['azure', 'geocodio', 'google', 'mapbox']);
      expect(tester.takeException(), isNull);
      expect(enabled(tester, 'fee-save'), isTrue);
      await stop(tester);
    });
  });

  group('under Location, Live traffic', () {
    const mark = 'live-services';

    Future<Terminal> pumpLocation(WidgetTester tester, {void Function(Hub hub)? hub, Size? size, double? type}) async {
      final t = await terminal(tester);
      whole(t.hub);
      hub?.call(t.hub);
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

    testWidgets('lists who knows the roads right now, and Save keeps their order and switches', (tester) async {
      final t = await pumpLocation(tester);
      await tapKey(tester, 'live-traffic');
      expect(find.byType(LiveDriveDialog), findsOneWidget);
      expect(placed(tester, mark), ['google', 'mapbox', 'azure']);
      expect(
        [for (final service in placed(tester, mark)) said(tester, '$mark-name:$service')],
        ['1. Google Maps', '2. Mapbox', '3. Azure Maps'],
      );
      expect([for (final service in placed(tester, mark)) switched(tester, mark, service)], [true, false, false]);
      expect(said(tester, '$mark-state:google'), '141 of 150 lookups left today');
      expect(badgeSays(tester, '$mark-badge:google'), 'Google Maps: 141 of 150 lookups left today');
      expect(said(tester, 'live-services-order'), contains('Drag one by its handle'));
      expect(said(tester, 'live-says'), startsWith('Each delivery for now asks one of them once'));
      await turn(tester, mark, 'mapbox');
      await dragPast(tester, mark, 'mapbox', -1);
      expect(placed(tester, mark), ['mapbox', 'google', 'azure']);
      expect(t.hub.driveLookupsSaved, isEmpty);
      await tapKey(tester, 'live-save');
      expect(find.byType(LiveDriveDialog), findsNothing);
      // who is asked about the roads alone: who measures the distance is left as it is
      expect(t.hub.driveLookupsSaved, [
        {
          'traffic': {
            'mapbox': true,
            'google': true,
            'azure': false,
            'order': ['mapbox', 'google', 'azure'],
          },
        },
      ]);
      expect(t.hub.driveAsking('traffic'), ['mapbox', 'google']);
      expect(t.hub.driveAsking('distance'), ['geocodio', 'google']);
      expect(t.hub.liveDriveAuth, 'Bearer tok-admin');
      await tapKey(tester, 'live-traffic');
      expect(placed(tester, mark), ['mapbox', 'google', 'azure']);
      await stop(tester);
    });

    testWidgets('with nobody turned on it says so at once, and the row says it after a save', (tester) async {
      final t = await pumpLocation(tester);
      await tapKey(tester, 'live-traffic');
      await turn(tester, mark, 'google');
      expect(
        said(tester, 'live-says'),
        startsWith('No map service that has a key on this hub is turned on for the roads'),
      );
      expect(
        tester.widget<Text>(key('live-says')).style?.color,
        Theme.of(tester.element(key('live-says'))).colorScheme.error,
      );
      await tapKey(tester, 'live-save');
      expect((t.hub.liveDrive?['traffic'], t.hub.liveDrive?['live']), (false, false));
      expect(
        rowWords(tester),
        startsWith('On, but not used yet. No map service that has a key on this hub is turned on'),
      );
      // and on again
      await tapKey(tester, 'live-traffic');
      await turn(tester, mark, 'google');
      expect(said(tester, 'live-says'), startsWith('Each delivery for now asks one of them once'));
      await tapKey(tester, 'live-save');
      expect(t.hub.liveDrive?['live'], isTrue);
      expect(rowWords(tester), startsWith('On: a delivery for now is promised'));
      await stop(tester);
    });

    testWidgets('a hub with no key for any of them names all three', (tester) async {
      await pumpLocation(
        tester,
        hub: (hub) {
          hub.liveDrive = {...Hub.liveOn, 'traffic': false, 'live': false};
          hub.driveLookups = {
            ...Hub.driveLookupsUsual,
            'traffic': Hub.driveOrderOf([
              for (final name in ['google', 'mapbox', 'azure'])
                Hub.driveService(name, key: false, on: name == 'google'),
            ]),
          };
        },
      );
      expect(
        rowWords(tester),
        'On, but not used yet. This hub has no key yet for a map service that knows the roads right now: '
        'Google Maps, Mapbox or Azure Maps (Keys and connections, on this screen).',
      );
      await tapKey(tester, 'live-traffic');
      expect(said(tester, 'live-says'), startsWith('This hub has no key yet for a map service that knows the roads'));
      expect(said(tester, '$mark-state:mapbox'), startsWith('This hub has no key for it'));
      await stop(tester);
    });

    testWidgets('a hub older than the order shows the dialog as it was', (tester) async {
      final t = await pumpLocation(tester, hub: (hub) => hub.driveLookups = null);
      await tapKey(tester, 'live-traffic');
      expect(key(mark), findsNothing);
      expect(said(tester, 'live-says'), startsWith('Each delivery for now asks Google Maps once'));
      await tapKey(tester, 'live-save');
      expect(t.hub.driveLookupsSaved, isEmpty);
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the rows fit with large type', (tester) async {
      await pumpLocation(tester, size: const Size(320, 640), type: 1.3);
      await tapKey(tester, 'live-traffic');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('live-says'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final service in ['google', 'mapbox', 'azure']) {
        final row = tester.getRect(key('$mark-row:$service'));
        expect((row.left >= 0, row.right <= 320), (true, true), reason: service);
      }
      await dragPast(tester, mark, 'azure', -2);
      expect(placed(tester, mark), ['azure', 'google', 'mapbox']);
      expect(tester.takeException(), isNull);
      expect(enabled(tester, 'live-save'), isTrue);
      await stop(tester);
    });
  });

  group('on a delivery\'s form', () {
    testWidgets('a badge before the distance says who measured it and what it has left today', (tester) async {
      final t = await pumpForm(tester, fees: Hub.twoMapFees);
      t.hub.driveLookups = Hub.driveLookupsUsual;
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(badgeSays(tester, 'fee-lookup-by'), 'Geocodio: 488 of 500 lookups left today');
      expect(find.descendant(of: key('fee-lookup-by'), matching: find.text('Ge')), findsOneWidget);
      // it leads its line: before the figures, where their length cannot move it
      final badge = tester.getRect(key('fee-lookup-by'));
      expect(badge.right, lessThan(tester.getRect(key('fee-lookup-found')).left));
      expect((badge.width, badge.height), (ServiceBadge.size, ServiceBadge.size));
      // a street the first one does not know: the next one measured it, and its badge stands in the same place
      await enterAddress(tester, newbuild);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(said(tester, 'fee-lookup-found'), '1.6 mi · 5 min drive');
      expect(badgeSays(tester, 'fee-lookup-by'), 'Google Maps: 97 of 100 lookups left today');
      expect(said(tester, 'fee-lookup-credit'), 'Google Maps');
      expect(tester.getRect(key('fee-lookup-by')).left, badge.left);
      // and a longer line leaves it where it is
      await enterAddress(tester, oak);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(said(tester, 'fee-lookup-found'), contains('further than the prices reach'));
      expect(tester.getRect(key('fee-lookup-by')).left, badge.left);
      await stop(tester);
    });

    testWidgets('with live traffic each figure has its own line, and its badge leads it', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      t.hub.driveLookups = Hub.driveLookupsUsual;
      t.hub.liveDrive = Hub.liveOn;
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect(badgeSays(tester, 'fee-lookup-by'), 'Geocodio: 488 of 500 lookups left today');
      expect(badgeSays(tester, 'fee-lookup-now-by'), 'Google Maps: 141 of 150 lookups left today');
      final measured = tester.getRect(key('fee-lookup-by')), roads = tester.getRect(key('fee-lookup-now-by'));
      expect(roads.left, measured.left);
      expect(roads.top, greaterThanOrEqualTo(measured.bottom));
      expect(said(tester, 'fee-lookup-now-credit'), 'Google Maps');
      expect(key('fee-lookup-credit'), findsNothing); // Geocodio asks for no name beside its figures
      await stop(tester);
    });

    testWidgets('where one service gave both, its name stands once, after the second', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees);
      t.hub.liveDrive = Hub.liveOn;
      t.hub.driveLookups = {
        ...Hub.driveLookupsUsual,
        'distance': Hub.driveOrderOf([Hub.driveService('google', most: 100, left: 97), Hub.driveService('geocodio')]),
      };
      await lindaTo(tester, elm);
      expect(badgeSays(tester, 'fee-lookup-by'), 'Google Maps: 97 of 100 lookups left today');
      expect(badgeSays(tester, 'fee-lookup-now-by'), 'Google Maps: 141 of 150 lookups left today');
      expect(find.text('Google Maps'), findsOneWidget);
      expect(
        tester.getRect(key('fee-lookup-credit')).top,
        greaterThanOrEqualTo(tester.getRect(key('fee-lookup-found')).bottom),
      );
      await stop(tester);
    });

    testWidgets('a hub older than the badge shows the line as it was', (tester) async {
      await pumpForm(tester, fees: Hub.liveFees);
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(said(tester, 'fee-lookup-now'), 'With traffic now: 14 min');
      expect(key('fee-lookup-by'), findsNothing);
      expect(key('fee-lookup-now-by'), findsNothing);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      final t = await pumpForm(tester, fees: Hub.liveFees, size: const Size(320, 640), type: 1.3);
      t.hub.driveLookups = Hub.driveLookupsUsual;
      t.hub.liveDrive = Hub.liveOn;
      await lindaTo(tester, elm);
      expect(tester.takeException(), isNull);
      for (final name in ['fee-lookup-by', 'fee-lookup-found', 'fee-lookup-now-by', 'fee-lookup-now']) {
        final box = tester.getRect(key(name));
        expect((box.left >= 0, box.right <= 320), (true, true), reason: name);
      }
      await stop(tester);
    });
  });
}
