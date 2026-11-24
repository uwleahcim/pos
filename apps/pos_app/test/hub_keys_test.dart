import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/hub_keys.dart';
import 'package:pos_app/screens/hub_keys_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Keys and connections (docs/hub-keys.md): the hub's keys for the services outside the restaurant, typed
/// by a manager in the app. The hub keeps a key sealed and says only how it stands; the page shows that,
/// and never a key.

const mapKey = 'abcdefghijklmnopqrstuvwx1234';
const p8 =
    '-----BEGIN PRIVATE KEY-----\n'
    'MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgc2VjcmV0c2VjcmV0\n'
    '-----END PRIVATE KEY-----';

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

/// The page as Location opens it for a manager, on the day the pretend hub stamps a typed key with.
/// Whatever it reports back comes to [told].
Future<Terminal> pumpKeys(
  WidgetTester tester, {
  void Function(Hub hub)? hub,
  Size size = const Size(700, 1600),
  double textScale = 1,
  String token = 'tok-admin',
  List<HubKeys>? told,
}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  tester.view.physicalSize = size;
  final keys = HubKeys.fromJson({'keys': t.hub.hubKeys!.values.toList(), 'kept': t.hub.hubKeysKept});
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: HubKeysScreen(
        api: t.api,
        token: token,
        keys: keys,
        onChanged: told?.add,
        clock: () => DateTime.fromMillisecondsSinceEpoch(t.hub.keysAtMs),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('how a key stands, in words', () {
    final now = DateTime(2026, 11, 24, 15);
    HubKey key(Map<String, dynamic> more, {String name = 'maps'}) => HubKey.fromJson({...Hub.noKey(name), ...more});

    test('typed here, from the hub\'s terminal, removed, never set', () {
      final at = DateTime(2026, 11, 24, 9).millisecondsSinceEpoch;
      expect(
        key({'set': true, 'source': 'app', 'ending': '1234', 'by': 'Mike', 'at_ms': at}).words(now),
        'Set · ends in 1234 · typed here by Mike, today',
      );
      expect(
        key({'set': true, 'source': 'hub', 'ending': 'wxyz'}).words(now),
        "Set in the hub's terminal · ends in wxyz",
      );
      expect(key({'set': true, 'source': 'hub'}).words(now), "Set in the hub's terminal");
      expect(key({'removed': true, 'by': 'Mike', 'at_ms': at}).words(now), 'Not set · removed here by Mike, today');
      expect(key(const {}).words(now), 'Not set');
    });

    test('Apple\'s key is told by its ids, never by its end', () {
      final apple = key({
        'set': true,
        'source': 'app',
        'ending': 'zzzz',
        'shown': {'key_id': 'ABCDE12345', 'team_id': 'TEAM123456', 'bundle_id': 'org.chinasky.posApp'},
        'by': 'Mike',
        'at_ms': DateTime(2026, 11, 23, 23).millisecondsSinceEpoch,
      }, name: 'push_apple');
      expect(apple.words(now), 'Set · key ABCDE12345, team TEAM123456 · typed here by Mike, yesterday');
    });

    test('one typed on the other hub that this hub cannot open', () {
      expect(
        key({'unreadable': true, 'by': 'Mike'}).words(now),
        'Typed in the app by Mike, but on another hub, and this hub cannot read it. Type it again here.',
      );
      expect(
        key({'unreadable': true, 'by': 'Mike', 'set': true, 'source': 'hub', 'ending': 'wxyz'}).words(now),
        'Typed in the app by Mike, but on another hub, and this hub cannot read it. Type it again here. '
        "The one from this hub's terminal is used meanwhile · ends in wxyz.",
      );
    });

    test('the day: today, yesterday, a date, and the year when it is another', () {
      expect(keyDay(DateTime(2026, 11, 24, 0, 5), now), 'today');
      expect(keyDay(DateTime(2026, 11, 23, 23, 55), now), 'yesterday');
      expect(keyDay(DateTime(2026, 11, 2), now), 'Nov 2');
      expect(keyDay(DateTime(2025, 12, 31), now), 'Dec 31, 2025');
    });

    test('the row under Location names which are set and which are not', () {
      HubKeys of(Map<String, bool> set) => HubKeys.fromJson({
        'keys': [for (final entry in set.entries) entry.value ? Hub.hubKey(entry.key) : Hub.noKey(entry.key)],
      });
      expect(
        of({'maps': false, 'maps_google': false, 'online': false, 'push_apple': false}).summary,
        'None set yet: map service, Google Maps, GloriaFood, Apple push',
      );
      expect(
        of({'maps': true, 'maps_google': false, 'online': true, 'push_apple': false}).summary,
        'Set: map service, GloriaFood · Not set: Google Maps, Apple push',
      );
      expect(of({'maps': true, 'online': true}).summary, 'All set: map service, GloriaFood');
      // a key of a newer hub that this app has no words for is left out
      expect(of({'maps': true, 'something_new': false}).summary, 'All set: map service');
      expect(of({'something_new': true}).summary, 'This hub holds no keys the app knows');
    });
  });

  group('the calls', () {
    testWidgets('the keys are a manager\'s to read, and an older hub has none', (tester) async {
      final t = await terminal(tester);
      t.hub.hubKeys!['maps'] = Hub.hubKey('maps', ending: 'wxyz');
      final keys = (await t.api.hubKeys('tok-admin'))!;
      expect(t.hub.hubKeysAuth, 'Bearer tok-admin');
      expect(keys.named('maps')!.set, isTrue);
      expect(keys.named('maps')!.ending, 'wxyz');
      expect(keys.named('online')!.set, isFalse);
      expect(keys.kept, isTrue);
      await expectLater(t.api.hubKeys('tok-s1'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
      t.hub.hubKeys = null;
      expect(await t.api.hubKeys('tok-admin'), isNull);
    });
  });

  group('the page', () {
    testWidgets('every key is a card that says how it stands and what it is for', (tester) async {
      await pumpKeys(
        tester,
        hub: (hub) {
          hub.hubKeys!['maps'] = Hub.hubKey('maps', ending: 'wxyz');
        },
      );
      expect(find.text('Keys and connections'), findsOneWidget);
      for (final title in ['Map service (Geocodio)', 'Google Maps', 'GloriaFood (online orders)', 'Apple push key']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(textOf(tester, 'key-maps-state'), "Set in the hub's terminal · ends in wxyz");
      expect(textOf(tester, 'key-online-state'), 'Not set');
      // a key in force can be replaced, tried and removed; one that is not set can only be typed
      expect(
        find.descendant(of: find.byKey(const ValueKey('key-maps-type')), matching: find.text('Replace')),
        findsOne,
      );
      expect(find.byKey(const ValueKey('key-maps-try')), findsOneWidget);
      expect(find.byKey(const ValueKey('key-maps-remove')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('key-online-type')), matching: find.text('Type the key')),
        findsOne,
      );
      expect(find.byKey(const ValueKey('key-online-try')), findsNothing);
      expect(find.byKey(const ValueKey('key-online-remove')), findsNothing);
      // what is lost without it is said only while there is none
      expect(find.textContaining('Without it the hub asks GloriaFood for nothing.'), findsOneWidget);
      expect(find.textContaining('the delivery fee is picked by hand'), findsNothing);
      expect(find.byKey(const ValueKey('keys-not-kept')), findsNothing);
    });

    testWidgets('a typed key goes to the hub, is in force, and is nowhere on the page', (tester) async {
      final told = <HubKeys>[];
      final t = await pumpKeys(tester, told: told);
      await tapKey(tester, 'key-maps-type');
      expect(find.textContaining('At geocod.io'), findsOneWidget);
      // dots while it is typed, unless asked to show it
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).obscureText, isTrue);
      await tester.enterText(find.byKey(const ValueKey('key-field')), '  $mapKey ');
      await tapKey(tester, 'key-show');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).obscureText, isFalse);
      await tapKey(tester, 'key-save');
      expect(find.byType(HubKeyDialog), findsNothing);
      expect(t.hub.keysTyped.single.$1, 'maps');
      expect(t.hub.keysTyped.single.$2, {'key': mapKey});
      expect(t.hub.hubKeysAuth, 'Bearer tok-admin');
      expect(textOf(tester, 'key-maps-state'), 'Set · ends in 1234 · typed here by Mike, today');
      expect(textOf(tester, 'key-maps-said'), 'Saved. The hub uses it from now on.');
      expect(find.textContaining(mapKey), findsNothing);
      expect(find.byKey(const ValueKey('key-maps-try')), findsOneWidget);
      // whoever opened the page hears how the keys stand now
      expect(told.single.named('maps')!.source, 'app');
    });

    testWidgets('what the hub refuses is said in the dialog, with what was typed still there', (tester) async {
      final t = await pumpKeys(tester, hub: (hub) => hub.refuseHubKey = 'that does not look like a key (letters)');
      await tapKey(tester, 'key-online-type');
      // nothing typed: nothing is sent
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Type or paste the key first.');
      expect(t.hub.keysTyped, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('key-field')), 'not a key');
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'That does not look like a key (letters).');
      expect(find.byType(HubKeyDialog), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).controller!.text, 'not a key');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'key-online-state'), 'Not set');
      expect(find.byKey(const ValueKey('key-online-said')), findsNothing);
    });

    testWidgets('a token that is no manager is told only a manager changes the keys', (tester) async {
      final t = await pumpKeys(tester, token: 'tok-s1');
      await tapKey(tester, 'key-maps-type');
      await tester.enterText(find.byKey(const ValueKey('key-field')), mapKey);
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), "Only a manager or an owner changes the hub's keys.");
      expect(t.hub.hubKeys!['maps']!['set'], isFalse);
    });

    testWidgets('Apple\'s key is the text of its file with the two ids', (tester) async {
      final t = await pumpKeys(tester);
      await tapKey(tester, 'key-push_apple-type');
      expect(find.text('The text of the .p8 file'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('key-field')), p8);
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), "Apple's key needs its Key ID and the Team ID.");
      expect(t.hub.keysTyped, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('key-id')), 'abcde12345');
      await tester.enterText(find.byKey(const ValueKey('key-team')), 'TEAM123456');
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$1, 'push_apple');
      expect(t.hub.keysTyped.single.$2, {'key': p8, 'key_id': 'ABCDE12345', 'team_id': 'TEAM123456', 'bundle_id': ''});
      expect(
        textOf(tester, 'key-push_apple-state'),
        'Set · key ABCDE12345, team TEAM123456 · typed here by Mike, today',
      );
      expect(find.textContaining('BEGIN PRIVATE KEY'), findsNothing);
      // replacing it starts from the ids in force
      await tapKey(tester, 'key-push_apple-type');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-id'))).controller!.text, 'ABCDE12345');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).controller!.text, isEmpty);
    });

    testWidgets('removing asks first, and says what stops', (tester) async {
      final t = await pumpKeys(tester, hub: (hub) => hub.hubKeys!['online'] = Hub.hubKey('online', ending: 'wxyz'));
      await tapKey(tester, 'key-online-remove');
      expect(find.text('Remove this key?'), findsOneWidget);
      expect(find.textContaining('The hub stops asking GloriaFood for orders.'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(t.hub.keysRemoved, isEmpty);
      await tapKey(tester, 'key-online-remove');
      await tapKey(tester, 'key-remove-sure');
      expect(t.hub.keysRemoved, ['online']);
      expect(textOf(tester, 'key-online-state'), 'Not set · removed here by Mike, today');
      expect(textOf(tester, 'key-online-said'), 'Removed. The hub no longer uses it.');
      expect(find.byKey(const ValueKey('key-online-try')), findsNothing);
    });

    testWidgets('a map service is tried with an address, and only that service is asked', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          hub.deliveryFees = Hub.twoMapFees;
          hub.hubKeys!['maps'] = Hub.hubKey('maps', ending: 'wxyz');
          hub.hubKeys!['maps_google'] = Hub.hubKey('maps_google', ending: 'goog');
        },
      );
      await tapKey(tester, 'key-maps-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-address')), '12 Elm St, Winchester');
      await tapKey(tester, 'key-try-ask');
      expect(t.hub.distanceAsks.single, {'address': '12 Elm St, Winchester', 'via': 'geocodio'});
      expect(textOf(tester, 'key-maps-said'), 'Geocodio answered: 3.2 mi · 9 min from the restaurant. The key works.');
      // the service turns the key down
      t.hub.refuseDistance = 'refused';
      await tapKey(tester, 'key-maps_google-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-address')), '12 Elm St, Winchester');
      await tapKey(tester, 'key-try-ask');
      expect(t.hub.distanceAsks.last['via'], 'google');
      expect(
        textOf(tester, 'key-maps_google-said'),
        'Google Maps refused the key. Check it where it came from, and type it again.',
      );
      // an address it cannot find still says the key works
      t.hub.refuseDistance = null;
      await tapKey(tester, 'key-maps-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-address')), 'nowhere at all');
      await tapKey(tester, 'key-try-ask');
      expect(textOf(tester, 'key-maps-said'), 'Geocodio answered, so the key works, but it did not find that address.');
    });

    testWidgets('a hub with no address of its own says so when a map service is tried', (tester) async {
      await pumpKeys(
        tester,
        hub: (hub) {
          hub.deliveryFees = {...Hub.milesFees, 'maps': true, 'lookup': false};
          hub.hubKeys!['maps'] = Hub.hubKey('maps', ending: 'wxyz');
        },
      );
      await tapKey(tester, 'key-maps-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-address')), '12 Elm St, Winchester');
      await tapKey(tester, 'key-try-ask');
      expect(textOf(tester, 'key-maps-said'), 'This hub has no map service to ask.');
    });

    testWidgets('GloriaFood is tried by asking it for orders now', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          hub.online = Hub.onlineStatus();
          hub.hubKeys!['online'] = Hub.hubKey('online', ending: 'wxyz');
        },
      );
      await tapKey(tester, 'key-online-try');
      expect(t.hub.onlineFetches, 1);
      expect(textOf(tester, 'key-online-said'), 'GloriaFood has no new order. The key works.');
      t.hub.onlineFetched = {...t.hub.onlineFetched, 'answered': false, 'reason': 'GloriaFood refused the key'};
      await tapKey(tester, 'key-online-try');
      expect(
        textOf(tester, 'key-online-said'),
        'GloriaFood refused the key. The hub asks again by itself within the minute.',
      );
    });

    testWidgets('Apple\'s key is tried with a notification to a screen that registered', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) => hub.hubKeys!['push_apple'] = {
          ...Hub.hubKey('push_apple'),
          'shown': {'key_id': 'ABCDE12345', 'team_id': 'TEAM123456', 'bundle_id': 'org.chinasky.posApp'},
        },
      );
      expect(textOf(tester, 'key-push_apple-state'), "Set in the hub's terminal · key ABCDE12345, team TEAM123456");
      // nobody to send it to
      await tapKey(tester, 'key-push_apple-try');
      expect(textOf(tester, 'key-push_apple-said'), startsWith('No iPhone or iPad has registered with this hub yet.'));
      expect(t.hub.pushTests, isEmpty);
      // one screen: it goes there
      t.hub.pushDevices = ['iphone1'];
      await tapKey(tester, 'key-push_apple-try');
      expect(t.hub.pushTests, ['iphone1']);
      expect(textOf(tester, 'key-push_apple-said'), 'Apple took a notification for iphone1. It should show there now.');
      // two: the manager picks, and what Apple says of a refusal is shown
      t.hub
        ..pushDevices = ['iphone1', 'ipad1']
        ..pushRefused = 'InvalidProviderToken';
      await tapKey(tester, 'key-push_apple-try');
      expect(find.text('Which screen gets the test?'), findsOneWidget);
      await tapKey(tester, 'key-try-device-ipad1');
      expect(t.hub.pushTests, ['iphone1', 'ipad1']);
      expect(
        textOf(tester, 'key-push_apple-said'),
        'Apple did not take the notification for ipad1: InvalidProviderToken.',
      );
    });

    testWidgets('a hub with nowhere to keep a typed key says so', (tester) async {
      await pumpKeys(tester, hub: (hub) => hub.hubKeysKept = false);
      expect(textOf(tester, 'keys-not-kept'), contains('lasts until the hub restarts'));
    });

    testWidgets('it fits a 320-wide phone with large text', (tester) async {
      await pumpKeys(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        hub: (hub) {
          hub.hubKeys!['maps'] = {
            ...Hub.hubKey('maps', ending: 'wxyz'),
            'source': 'app',
            'by': 'Mike',
            'at_ms': hub.keysAtMs,
          };
        },
      );
      expect(tester.takeException(), isNull);
      for (final key in ['key-maps-type', 'key-maps-try', 'key-maps-remove']) {
        final button = tester.getRect(find.byKey(ValueKey(key)));
        expect(button.left >= 0 && button.right <= 320, isTrue, reason: key);
      }
      // the last card comes up, and its dialog fits with the keyboard's room to spare
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('key-push_apple-type')),
        300,
        scrollable: find.descendant(of: find.byType(HubKeysScreen), matching: find.byType(Scrollable)).first,
      );
      await tapKey(tester, 'key-push_apple-type');
      expect(tester.takeException(), isNull);
      final save = tester.getRect(find.byKey(const ValueKey('key-save')));
      expect(save.right <= 320 && save.bottom <= 568, isTrue);
    });
  });

  group('Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {Set<String>? holds, void Function(Hub hub)? hub}) async {
      final t = await terminal(tester);
      hub?.call(t.hub);
      tester.view.physicalSize = wholeLocation;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', holds: holds, staffId: 's3', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    String row(WidgetTester tester) => tester
        .widget<Text>(find.descendant(of: find.byKey(const ValueKey('hub-keys')), matching: find.byType(Text)).last)
        .data!;

    testWidgets('a manager finds the row, which keys are set, and the page behind it', (tester) async {
      final t = await pumpLocation(tester, hub: (hub) => hub.hubKeys!['maps'] = Hub.hubKey('maps', ending: 'wxyz'));
      await bringUp(tester, 'hub-keys');
      expect(row(tester), 'Set: map service · Not set: Google Maps, GloriaFood, Apple push');
      await tapKey(tester, 'hub-keys');
      expect(find.byType(HubKeysScreen), findsOneWidget);
      await tapKey(tester, 'key-online-type');
      await tester.enterText(find.byKey(const ValueKey('key-field')), 'gloria-key-0001');
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$1, 'online');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(row(tester), 'Set: map service, GloriaFood · Not set: Google Maps, Apple push');
    });

    testWidgets('an older hub has no keys to type: the row says so and opens nothing', (tester) async {
      await pumpLocation(tester, hub: (hub) => hub.hubKeys = null);
      await bringUp(tester, 'hub-keys');
      expect(row(tester), 'This hub is older than keys typed in the app: update it (sudo hubctl update)');
      await tapKey(tester, 'hub-keys');
      expect(find.byType(HubKeysScreen), findsNothing);
    });

    testWidgets('whoever was handed the reports and not the settings finds no keys', (tester) async {
      final t = await pumpLocation(tester, holds: {'reports'});
      expect(find.byKey(const ValueKey('hub-keys')), findsNothing);
      expect(t.hub.hubKeysAuth, isNull);
    });
  });
}
