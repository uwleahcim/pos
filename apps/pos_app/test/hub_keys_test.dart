import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/hub_keys.dart';
import 'package:pos_app/screens/hub_keys_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/takeout.dart' show clockTime;

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
  if (target.evaluate().isEmpty) {
    // the page is a list that builds only what is near the window, and it is longer than the window:
    // from the top, down to it
    final page = find.byType(Scrollable).first;
    tester.state<ScrollableState>(page).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(target, 200, scrollable: page);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

/// What the page puts on the clipboard from here on, in order.
List<String> clipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// The page's next look at a tunnel that is on its way, two seconds on, and what it shows after it.
Future<void> nextLook(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// The page as Location opens it for a manager, on the day the pretend hub stamps a typed key with.
/// Whatever it reports back comes to [told].
Future<Terminal> pumpKeys(
  WidgetTester tester, {
  void Function(Hub hub)? hub,
  Size size = const Size(700, 2200),
  double textScale = 1,
  String token = 'tok-admin',
  List<HubKeys>? told,
  String Function()? makeKey,
}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  tester.view.physicalSize = size;
  final keys = HubKeys.fromJson(t.hub.hubKeysSaid());
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
        makeKey: makeKey ?? makePushKey,
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
        of({'online': true, 'online_push': true, 'online_tunnel': false, 'push_apple': false}).summary,
        'Set: GloriaFood, GloriaFood push · Not set: Cloudflare tunnel, Apple push',
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

    testWidgets('Mapbox and Azure Maps are tried by listing addresses for the restaurant\'s own address', (
      tester,
    ) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          hub.addressList = Hub.addressListOf([
            Hub.addressService('google', key: false),
            Hub.addressService('mapbox'),
            Hub.addressService('azure'),
          ]);
          hub.hubKeys!['maps_mapbox'] = Hub.hubKey('maps_mapbox', ending: 'qrst');
          hub.hubKeys!['maps_azure'] = Hub.hubKey('maps_azure', ending: 'klmn');
        },
      );
      expect(textOf(tester, 'key-maps_mapbox-state'), "Set in the hub's terminal · ends in qrst");
      await tester.ensureVisible(find.byKey(const ValueKey('key-maps_mapbox-try')));
      await tapKey(tester, 'key-maps_mapbox-try');
      expect(t.hub.addressTried, ['mapbox']); // no address is asked for: the restaurant's own is used
      expect(
        textOf(tester, 'key-maps_mapbox-said'),
        'Mapbox answered: the key works. 9,411 free lookups are left this month. It is asked for addresses once it '
        'is turned on under Location, Address list.',
      );
      t.hub.addressTry = {
        'ok': false,
        'found': 0,
        'reason': 'refused',
        'message':
            "Azure Maps refused the hub's key. Copy the primary key again from your Maps account in the Azure "
            'portal.',
        'left': 47499,
      };
      await tester.ensureVisible(find.byKey(const ValueKey('key-maps_azure-try')));
      await tapKey(tester, 'key-maps_azure-try');
      expect(t.hub.addressTried, ['mapbox', 'azure']);
      expect(textOf(tester, 'key-maps_azure-said'), startsWith("Azure Maps refused the hub's key."));
      // where to find each key, in the dialog that takes it
      await tester.ensureVisible(find.byKey(const ValueKey('key-maps_mapbox-type')));
      await tapKey(tester, 'key-maps_mapbox-type');
      expect(textOf(tester, 'key-where'), contains('the default public token (it starts with pk.)'));
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

  group('several GloriaFood accounts', () {
    const sushiKey = 'sushi-site-key-000000009876';

    /// A hub that asks two storefronts and an account for testing, the first one set in its terminal.
    void three(Hub hub) {
      hub
        ..firstAccountName = 'China Sky'
        ..hubKeys!['online'] = Hub.hubKey('online', ending: 'wxyz')
        ..onlineAccounts = [
          {'id': 'su01', 'name': 'Sushi site', 'test': false},
          {'id': 'te01', 'name': 'Testing', 'test': true},
        ]
        ..accountKeys['online:su01'] = {...Hub.hubKey('online:su01', ending: '9876'), 'source': 'app', 'by': 'Mike'}
        ..accountKeys['online:te01'] = Hub.noKey('online:te01');
    }

    test('the hub lists them, the first account first, each with how its key stands', () {
      final hub = Hub();
      three(hub);
      final keys = HubKeys.fromJson(hub.hubKeysSaid());
      expect([for (final account in keys.accounts) account.id], ['main', 'su01', 'te01']);
      expect([for (final account in keys.accounts) account.called], ['China Sky', 'Sushi site', 'Testing']);
      expect([for (final account in keys.accounts) account.key.name], ['online', 'online:su01', 'online:te01']);
      expect([for (final account in keys.accounts) account.key.set], [true, true, false]);
      expect(keys.accounts.last.test, isTrue);
      // the keys of the page are as many as they were: an account's key is not one of them
      expect(
        [for (final key in keys.keys) key.name],
        [
          'maps',
          'maps_google',
          'maps_mapbox',
          'maps_azure',
          'online',
          'online_push',
          'online_tunnel',
          'push_apple',
          'texts',
          'shipday',
        ],
      );
      expect(
        keys.summary,
        'Set: GloriaFood (2 accounts) · Not set: map service, Google Maps, Mapbox, Azure Maps, GloriaFood (Testing), '
        'GloriaFood push, Cloudflare tunnel, Apple push, Twilio texts, Shipday',
      );
    });

    test('a hub from before there could be several has the one account, by the key online', () {
      final hub = Hub()
        ..onlineAccounts = null
        ..wayIn = null
        ..texts = null
        ..shipday = null
        ..hubKeys!['online'] = Hub.hubKey('online', ending: 'wxyz');
      final keys = HubKeys.fromJson(hub.hubKeysSaid());
      expect(keys.onlineAccounts, isNull);
      expect(keys.accounts.single.id, 'main');
      expect(keys.accounts.single.key.ending, 'wxyz');
      expect(keys.summary, 'Set: GloriaFood · Not set: map service, Google Maps, Mapbox, Azure Maps, Apple push');
    });

    testWidgets('one account looks as it did, with the way to add another under it', (tester) async {
      await pumpKeys(tester);
      expect(find.text('GloriaFood (online orders)'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-add')), findsOneWidget);
      expect(find.text('Add another GloriaFood account'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-main-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-first-unnamed')), findsNothing);
    });

    testWidgets('an older hub offers no second account', (tester) async {
      await pumpKeys(tester, hub: (hub) => hub.onlineAccounts = null);
      expect(find.text('GloriaFood (online orders)'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-add')), findsNothing);
      expect(find.byKey(const ValueKey('account-main-edit')), findsNothing);
    });

    testWidgets('each account is a card by its name, and the one for testing says so', (tester) async {
      await pumpKeys(tester, hub: three);
      for (final title in ['GloriaFood · China Sky', 'GloriaFood · Sushi site', 'GloriaFood · Testing']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('GloriaFood (online orders)'), findsNothing);
      expect(textOf(tester, 'key-online-state'), "Set in the hub's terminal · ends in wxyz");
      expect(textOf(tester, 'key-online:su01-state'), startsWith('Set · ends in 9876 · typed here by Mike'));
      expect(textOf(tester, 'key-online:te01-state'), 'Not set');
      expect(find.byKey(const ValueKey('account-te01-test')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-su01-test')), findsNothing);
      expect(find.textContaining('Its orders say TEST ORDER on every ticket and screen.'), findsOneWidget);
      // a further account can be taken away whole, with or without a key; the first one only loses its key
      for (final key in ['key-online-remove', 'key-online:su01-remove', 'key-online:te01-remove']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('key-online:te01-try')), findsNothing);
      expect(find.byKey(const ValueKey('account-first-unnamed')), findsNothing);
    });

    testWidgets('another account is added with its name and its key, which is nowhere on the page', (tester) async {
      final told = <HubKeys>[];
      final t = await pumpKeys(
        tester,
        told: told,
        hub: (hub) => hub.hubKeys!['online'] = Hub.hubKey('online', ending: 'wxyz'),
      );
      await tapKey(tester, 'account-add');
      expect(find.text('Add a GloriaFood account'), findsOneWidget);
      // nothing typed: nothing is sent, and the dialog says what is missing
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), startsWith('Give the account a name'));
      await tester.enterText(find.byKey(const ValueKey('account-name')), ' Sushi site ');
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Type or paste the key first.');
      expect(t.hub.accountsAdded, isEmpty);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).obscureText, isTrue);
      await tester.enterText(find.byKey(const ValueKey('key-field')), ' $sushiKey ');
      await tapKey(tester, 'key-save');
      expect(find.byType(OnlineAccountDialog), findsNothing);
      expect(t.hub.accountsAdded.single, {'name': 'Sushi site', 'key': sushiKey, 'test': false});
      expect(find.text('GloriaFood · Sushi site'), findsOneWidget);
      expect(textOf(tester, 'key-online:a1-state'), 'Set · ends in 9876 · typed here by Mike, today');
      expect(textOf(tester, 'key-online:a1-said'), 'Added. The hub asks it every minute from now on.');
      expect(find.textContaining(sushiKey), findsNothing);
      // the first account is now one of two, and still has no name
      expect(find.text('GloriaFood · First account'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-first-unnamed')), findsOneWidget);
      expect(told.last.accounts.length, 2);
    });

    testWidgets('an account for testing is added with the switch on', (tester) async {
      final t = await pumpKeys(tester);
      await tapKey(tester, 'account-add');
      await tester.enterText(find.byKey(const ValueKey('account-name')), 'Testing');
      await tester.enterText(find.byKey(const ValueKey('key-field')), sushiKey);
      await tapKey(tester, 'account-test');
      await tapKey(tester, 'key-save');
      expect(t.hub.accountsAdded.single['test'], isTrue);
      expect(find.byKey(const ValueKey('account-a1-test')), findsOneWidget);
    });

    testWidgets('what the hub refuses of an account is said in the dialog, with the boxes as typed', (tester) async {
      final t = await pumpKeys(tester, hub: (hub) => hub.refuseAccount = 'another account is called that already');
      await tapKey(tester, 'account-add');
      await tester.enterText(find.byKey(const ValueKey('account-name')), 'Sushi site');
      await tester.enterText(find.byKey(const ValueKey('key-field')), sushiKey);
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Another account is called that already.');
      expect(find.byType(OnlineAccountDialog), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('account-name'))).controller!.text, 'Sushi site');
      expect(t.hub.onlineAccounts, isEmpty);
    });

    testWidgets('an account is named and marked for testing without its key being touched', (tester) async {
      final t = await pumpKeys(tester, hub: three);
      // the first account gets its name here too
      await tapKey(tester, 'account-main-edit');
      expect(find.text('GloriaFood account'), findsOneWidget);
      expect(find.byKey(const ValueKey('key-field')), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('account-name'))).controller!.text, 'China Sky');
      await tester.enterText(find.byKey(const ValueKey('account-name')), 'Chinese site');
      await tapKey(tester, 'key-save');
      expect(t.hub.accountsChanged.single.$1, 'main');
      expect(t.hub.accountsChanged.single.$2, {'name': 'Chinese site', 'test': false});
      expect(find.text('GloriaFood · Chinese site'), findsOneWidget);
      expect(textOf(tester, 'key-online-said'), 'Saved. Orders that come from now on say so.');
      expect(textOf(tester, 'key-online-state'), "Set in the hub's terminal · ends in wxyz");
      // and the sushi site becomes one for testing
      await tapKey(tester, 'account-su01-edit');
      await tapKey(tester, 'account-test');
      await tapKey(tester, 'key-save');
      expect(t.hub.accountsChanged.last.$1, 'su01');
      expect(t.hub.accountsChanged.last.$2, {'name': 'Sushi site', 'test': true});
      expect(find.byKey(const ValueKey('account-su01-test')), findsOneWidget);
      expect(t.hub.keysTyped, isEmpty);
    });

    testWidgets('an account\'s own key is typed, replaced and tried under its own name', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          three(hub);
          hub.online = Hub.onlineStatus();
        },
      );
      await tapKey(tester, 'key-online:te01-type');
      await tester.enterText(find.byKey(const ValueKey('key-field')), 'testing-key-00000001111');
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$1, 'online:te01');
      expect(t.hub.keysTyped.single.$2, {'key': 'testing-key-00000001111'});
      expect(textOf(tester, 'key-online:te01-state'), 'Set · ends in 1111 · typed here by Mike, today');
      // trying one account asks them all, and says what this one answered
      t.hub.onlineFetched = {
        ...t.hub.onlineFetched,
        'answered': false,
        'reason': 'Sushi site: GloriaFood refused the key',
        'accounts': [
          {'id': 'main', 'name': 'China Sky', 'answered': true, 'reason': null, 'came': 2},
          {'id': 'su01', 'name': 'Sushi site', 'answered': false, 'reason': 'GloriaFood refused the key', 'came': 0},
          {'id': 'te01', 'name': 'Testing', 'answered': true, 'reason': null, 'came': 0},
        ],
      };
      await tapKey(tester, 'key-online:te01-try');
      expect(t.hub.onlineFetches, 1);
      expect(textOf(tester, 'key-online:te01-said'), 'GloriaFood answered: no new order. The key works.');
      await tapKey(tester, 'key-online:su01-try');
      expect(textOf(tester, 'key-online:su01-said'), 'GloriaFood refused the key.');
      await tapKey(tester, 'key-online-try');
      expect(textOf(tester, 'key-online-said'), 'GloriaFood answered: 2 orders came. The key works.');
    });

    testWidgets('removing a further account asks first, and takes its key with it', (tester) async {
      final t = await pumpKeys(tester, hub: three);
      await tapKey(tester, 'key-online:su01-remove');
      expect(find.text('Remove this account?'), findsOneWidget);
      expect(find.textContaining('Sushi site. The hub stops asking GloriaFood for its orders'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(t.hub.accountsRemoved, isEmpty);
      await tapKey(tester, 'key-online:su01-remove');
      await tapKey(tester, 'key-remove-sure');
      expect(t.hub.accountsRemoved, ['su01']);
      expect(t.hub.keysRemoved, isEmpty);
      expect(find.text('GloriaFood · Sushi site'), findsNothing);
      expect(textOf(tester, 'accounts-said'), 'Removed Sushi site. The hub no longer asks it.');
      // the first account only loses its key: it stays on the page
      await tapKey(tester, 'key-online-remove');
      expect(find.text('Remove this key?'), findsOneWidget);
      await tapKey(tester, 'key-remove-sure');
      expect(t.hub.keysRemoved, ['online']);
      expect(find.text('GloriaFood · China Sky'), findsOneWidget);
    });

    testWidgets('three accounts fit a 320-wide phone with large text, and so does the dialog', (tester) async {
      await pumpKeys(tester, size: const Size(320, 568), textScale: 1.3, hub: three);
      expect(tester.takeException(), isNull);
      final scrollable = find.descendant(of: find.byType(HubKeysScreen), matching: find.byType(Scrollable)).first;
      for (final key in ['key-online:su01-type', 'account-su01-edit', 'key-online:su01-remove', 'account-add']) {
        await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200, scrollable: scrollable);
        final button = tester.getRect(find.byKey(ValueKey(key)));
        expect(button.left >= 0 && button.right <= 320, isTrue, reason: key);
        expect(tester.takeException(), isNull, reason: key);
      }
      await tapKey(tester, 'account-add');
      expect(tester.takeException(), isNull);
      final save = tester.getRect(find.byKey(const ValueKey('key-save')));
      expect(save.right <= 320 && save.bottom <= 568, isTrue);
    });
  });

  group("the way in for GloriaFood's pushes", () {
    const madeKey = 'Qw3rTyUiOpAsDfGhJkLzXcVbNm0123456789AbCd';
    const token = 'eyJhIjoiMDAwMCIsInQiOiI2ZmY0MmFlMi0wMDAwIiwicyI6Ik1EQXdNREF3TURBd01EQXdNREF3TURBd01EQXcifQ==';
    final now = DateTime(2026, 11, 24, 15);

    /// A hub whose key for pushes and tunnel's token were typed in the app, the tunnel connected.
    void bothSet(Hub hub) {
      hub
        ..hubKeys!['online_push'] = {...Hub.hubKey('online_push', ending: 'AbCd'), 'source': 'app', 'by': 'Mike'}
        ..hubKeys!['online_tunnel'] = {
          ...Hub.hubKey('online_tunnel', ending: 'fQ=='),
          'source': 'app',
          'by': 'Mike',
          'shown': {'tunnel': '6ff42ae2'},
        }
        ..wayIn = {...hub.wayIn!, 'tunnel': Hub.tunnelStands('connected', sinceMs: hub.keysAtMs)};
    }

    test('how the tunnel stands, in words', () {
      TunnelState stands(String state, {bool there = true, int? sinceMs, String? reason, String said = ''}) =>
          TunnelState.fromJson(Hub.tunnelStands(state, there: there, sinceMs: sinceMs, reason: reason, said: said));
      final nine = DateTime(2026, 11, 24, 9, 5).millisecondsSinceEpoch;
      expect(stands('connected', sinceMs: nine).words(now), 'Connected to Cloudflare since 09:05.');
      expect(
        stands('connected', sinceMs: DateTime(2026, 11, 23, 22).millisecondsSinceEpoch).words(now),
        'Connected to Cloudflare since yesterday.',
      );
      expect(stands('connected').words(now), 'Connected to Cloudflare.');
      expect(stands('connected', sinceMs: nine).connected, isTrue);
      expect(stands('connected', sinceMs: nine).bad, isFalse);
      expect(stands('starting').words(now), 'On its way to Cloudflare, not connected yet.');
      expect(stands('starting').bad, isFalse);
      expect(stands('failing', reason: 'refused').words(now), startsWith('Not connected: Cloudflare did not take'));
      expect(stands('failing', reason: 'refused').bad, isTrue);
      expect(stands('failing', reason: 'unreachable').words(now), contains("the restaurant's internet"));
      expect(stands('failing', reason: 'slow').words(now), 'Not connected yet: it is taking long to reach Cloudflare.');
      expect(stands('failing', reason: 'missing').words(now), contains('this hub has no tunnel program'));
      expect(
        stands('failing', reason: 'trouble', said: 'failed to dial to edge').words(now),
        "Not connected. Cloudflare's program says: failed to dial to edge",
      );
      expect(stands('failing', reason: 'trouble').words(now), 'Not connected to Cloudflare.');
      // a hub whose tunnel program does not speak
      final silent = stands('off', there: false);
      expect(silent.words(now), "The hub's tunnel program is not running. Update the hub (sudo hubctl update).");
      expect(silent.bad, isTrue);
      expect(silent.connected, isFalse);
    });

    test('what a try came to, in words', () {
      WayTried tried(Map<String, dynamic> door, [Map<String, dynamic>? outside]) =>
          WayTried.fromJson({'door': door, 'outside': outside});
      const open = {'ok': true, 'reason': null, 'code': 401};
      Map<String, dynamic> from(String? reason, {int? code}) => {
        'address': 'orders.example.com',
        'ok': reason == null,
        'reason': reason,
        'code': code,
        'url': 'https://orders.example.com/online/push',
      };
      // the door
      expect(
        tried({'ok': false, 'reason': 'no_answer', 'code': null}).words,
        startsWith('The push door is not running'),
      );
      expect(tried({'ok': false, 'reason': 'shut', 'code': 404}).words, startsWith('The push door is shut'));
      expect(tried({'ok': false, 'reason': 'api', 'code': 502}).words, contains('could not hand a push on'));
      expect(tried({'ok': false, 'reason': 'other', 'code': 500}).words, contains('(500)'));
      expect(tried({'ok': false, 'reason': 'shut', 'code': 404}).bad, isTrue);
      // the door alone, with no address to try from outside, is no fault
      expect(tried(open).words, startsWith('The push door is open and leads to this hub. Give the address'));
      expect(tried(open).bad, isFalse);
      // from outside
      final whole = tried(open, from(null, code: 401));
      expect(whole.ok, isTrue);
      expect(
        whole.words,
        'The whole way in works: https://orders.example.com/online/push reaches this hub. That is the address for '
        "GloriaFood's admin. No key was sent anywhere.",
      );
      final said = {
        'no_answer': 'nothing answers at orders.example.com',
        'late': 'orders.example.com did not answer in time',
        'elsewhere': 'answers, but not from this hub',
        'not_routed': 'leads nowhere for /online/push',
        'blocked': 'turned the call away (403)',
        'tunnel_down': 'cannot get to the push door (502)',
        'redirect': 'sends callers on to another address (301)',
        'other': 'answered 418',
      };
      final codes = {
        'elsewhere': 200,
        'not_routed': 404,
        'blocked': 403,
        'tunnel_down': 502,
        'redirect': 301,
        'other': 418,
      };
      for (final entry in said.entries) {
        final failed = tried(open, from(entry.key, code: codes[entry.key]));
        expect(failed.bad, isTrue, reason: entry.key);
        expect(failed.words, startsWith('The push door is open, but from outside '), reason: entry.key);
        expect(failed.words, contains(entry.value), reason: entry.key);
      }
    });

    test("a tunnel's token is told by the start of its tunnel's id, and an older hub says nothing of the way in", () {
      final hub = Hub();
      bothSet(hub);
      final keys = HubKeys.fromJson(hub.hubKeysSaid());
      expect(
        keys.named('online_tunnel')!.words(DateTime.fromMillisecondsSinceEpoch(hub.keysAtMs)),
        'Set · tunnel 6ff42ae2 · typed here by Mike',
      );
      expect(keys.wayIn!.address, '');
      expect(keys.wayIn!.endpoint, isNull);
      expect(keys.wayIn!.door, isTrue);
      expect(keys.wayIn!.tunnel.connected, isTrue);
      hub.wayIn = {...hub.wayIn!, 'address': 'orders.example.com'};
      expect(HubKeys.fromJson(hub.hubKeysSaid()).wayIn!.endpoint, 'https://orders.example.com/online/push');
      hub
        ..wayIn = null
        ..texts = null
        ..shipday = null;
      final older = HubKeys.fromJson(hub.hubKeysSaid());
      expect(older.wayIn, isNull);
      expect(
        [for (final key in older.keys) key.name],
        ['maps', 'maps_google', 'maps_mapbox', 'maps_azure', 'online', 'push_apple'],
      );
    });

    testWidgets('the two are cards of their own, and say what is lost without them', (tester) async {
      await pumpKeys(tester);
      expect(find.text('GloriaFood push key'), findsOneWidget);
      expect(find.text('Cloudflare Tunnel (the way in)'), findsOneWidget);
      expect(textOf(tester, 'key-online_push-state'), 'Not set');
      expect(textOf(tester, 'key-online_tunnel-state'), 'Not set');
      expect(find.textContaining('Without it every push is turned away'), findsOneWidget);
      expect(find.textContaining('Without it nothing from outside reaches the hub'), findsOneWidget);
      // nothing of a tunnel that has no token, and nothing to try
      expect(find.byKey(const ValueKey('tunnel-state')), findsNothing);
      expect(find.byKey(const ValueKey('way-in-endpoint')), findsNothing);
      expect(find.byKey(const ValueKey('key-online_push-try')), findsNothing);
      expect(find.byKey(const ValueKey('key-online_tunnel-try')), findsNothing);
    });

    testWidgets('a hub from before them shows the four cards it always did', (tester) async {
      await pumpKeys(
        tester,
        hub: (hub) => hub
          ..wayIn = null
          ..texts = null,
      );
      expect(find.text('GloriaFood push key'), findsNothing);
      expect(find.text('Cloudflare Tunnel (the way in)'), findsNothing);
      expect(find.text('Texts to customers (Twilio)'), findsNothing);
      for (final title in ['Map service (Geocodio)', 'Google Maps', 'GloriaFood (online orders)', 'Apple push key']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
    });

    testWidgets('a key for pushes is made here, copied, saved, and never shown again', (tester) async {
      final copied = clipboard(tester);
      final made = [madeKey, 'Zz${madeKey.substring(2)}'];
      final t = await pumpKeys(tester, makeKey: () => made.removeAt(0));
      await tapKey(tester, 'key-online_push-type');
      expect(find.textContaining('Yours to make'), findsOneWidget);
      expect(find.byKey(const ValueKey('key-copy')), findsNothing);
      expect(find.byKey(const ValueKey('key-made-note')), findsNothing);
      // nothing typed and nothing made: nothing is sent
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Paste the key, or press Make one, first.');
      await tapKey(tester, 'key-make');
      final field = find.byKey(const ValueKey('key-field'));
      expect(tester.widget<TextField>(field).controller!.text, madeKey);
      // a made key is shown, since it has to be copied
      expect(tester.widget<TextField>(field).obscureText, isFalse);
      expect(find.byKey(const ValueKey('key-problem')), findsNothing);
      expect(textOf(tester, 'key-made-note'), startsWith("Copy it now, for GloriaFood's admin."));
      expect(find.text('Make another'), findsOneWidget);
      await tapKey(tester, 'key-copy');
      expect(copied, [madeKey]);
      expect(find.text('Copied'), findsOneWidget);
      // another one is another key, still to be copied
      await tapKey(tester, 'key-make');
      expect(tester.widget<TextField>(field).controller!.text, 'Zz${madeKey.substring(2)}');
      expect(find.text('Copy'), findsOneWidget);
      await tapKey(tester, 'key-copy');
      await tapKey(tester, 'key-save');
      expect(find.byType(HubKeyDialog), findsNothing);
      expect(t.hub.keysTyped.single.$1, 'online_push');
      expect(t.hub.keysTyped.single.$2, {'key': 'Zz${madeKey.substring(2)}'});
      expect(copied.last, 'Zz${madeKey.substring(2)}');
      expect(textOf(tester, 'key-online_push-state'), 'Set · ends in AbCd · typed here by Mike, today');
      expect(
        textOf(tester, 'key-online_push-said'),
        "Saved. The push door is open for it. Put the same key into GloriaFood's admin.",
      );
      expect(find.textContaining(madeKey.substring(2)), findsNothing);
      expect(find.byKey(const ValueKey('key-online_push-try')), findsOneWidget);
      // replacing it starts from an empty box: the key in force is not brought back
      await tapKey(tester, 'key-online_push-type');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(find.text('Make one'), findsOneWidget);
    });

    testWidgets('a key of your own can be pasted for pushes instead', (tester) async {
      final t = await pumpKeys(tester);
      await tapKey(tester, 'key-online_push-type');
      await tester.enterText(find.byKey(const ValueKey('key-field')), ' $madeKey ');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).obscureText, isTrue);
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$2, {'key': madeKey});
      expect(find.byKey(const ValueKey('key-made-note')), findsNothing);
    });

    testWidgets("the tunnel's token is pasted as Cloudflare's command, and the card follows it to Cloudflare", (
      tester,
    ) async {
      final told = <HubKeys>[];
      final t = await pumpKeys(tester, told: told);
      await tapKey(tester, 'key-online_tunnel-type');
      expect(find.text("The token, or Cloudflare's command"), findsOneWidget);
      expect(find.textContaining('Zero Trust, Networks, Tunnels'), findsOneWidget);
      expect(find.byKey(const ValueKey('key-make')), findsNothing);
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Paste the token, or the command Cloudflare shows, first.');
      // the hub finds the token in the command: the app sends what was pasted
      await tester.enterText(find.byKey(const ValueKey('key-field')), 'sudo cloudflared service install $token');
      t.hub.tunnelNext.addAll([Hub.tunnelStands('starting'), Hub.tunnelStands('connected', sinceMs: t.hub.keysAtMs)]);
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$1, 'online_tunnel');
      expect(t.hub.keysTyped.single.$2, {'key': 'sudo cloudflared service install $token'});
      expect(textOf(tester, 'key-online_tunnel-state'), 'Set · tunnel 6ff42ae2 · typed here by Mike, today');
      expect(textOf(tester, 'key-online_tunnel-said'), 'Saved. The tunnel is started with it.');
      expect(textOf(tester, 'tunnel-state'), 'On its way to Cloudflare, not connected yet.');
      expect(find.textContaining('eyJ'), findsNothing);
      // nobody presses anything: the page looks again by itself until the tunnel says how it went
      expect(t.hub.hubKeysAsks, 0);
      await nextLook(tester);
      expect(t.hub.hubKeysAsks, 1);
      expect(textOf(tester, 'tunnel-state'), 'On its way to Cloudflare, not connected yet.');
      await nextLook(tester);
      expect(t.hub.hubKeysAsks, 2);
      expect(textOf(tester, 'tunnel-state'), 'Connected to Cloudflare since ${clockTime(t.hub.keysAtMs)}.');
      expect(told.last.wayIn!.tunnel.connected, isTrue);
      // and then it is left alone
      await nextLook(tester);
      await nextLook(tester);
      expect(t.hub.hubKeysAsks, 2);
      expect(find.byKey(const ValueKey('key-online_tunnel-try')), findsOneWidget);
    });

    testWidgets('a token Cloudflare does not take is said on the card, and the looking stops', (tester) async {
      final t = await pumpKeys(tester);
      await tapKey(tester, 'key-online_tunnel-type');
      await tester.enterText(find.byKey(const ValueKey('key-field')), token);
      t.hub.tunnelNext.add(Hub.tunnelStands('failing', sinceMs: t.hub.keysAtMs, reason: 'refused'));
      await tapKey(tester, 'key-save');
      await nextLook(tester);
      expect(textOf(tester, 'tunnel-state'), startsWith('Not connected: Cloudflare did not take the token.'));
      final theme = Theme.of(tester.element(find.byType(HubKeysScreen)));
      expect(tester.widget<Text>(find.byKey(const ValueKey('tunnel-state'))).style!.color, theme.colorScheme.error);
      await nextLook(tester);
      expect(t.hub.hubKeysAsks, 1);
    });

    testWidgets('a tunnel that stays on its way is looked at for half a minute, not for ever', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          bothSet(hub);
          hub.wayIn = {...hub.wayIn!, 'tunnel': Hub.tunnelStands('starting')};
        },
      );
      for (var n = 0; n < 20; n++) {
        await nextLook(tester);
      }
      expect(t.hub.hubKeysAsks, 15);
      expect(textOf(tester, 'tunnel-state'), 'On its way to Cloudflare, not connected yet.');
    });

    testWidgets('a hub that does not answer one look is asked again at the next', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          bothSet(hub);
          hub.wayIn = {...hub.wayIn!, 'tunnel': Hub.tunnelStands('starting')};
        },
      );
      t.hub.down = true;
      await nextLook(tester);
      expect(tester.takeException(), isNull);
      expect(textOf(tester, 'tunnel-state'), 'On its way to Cloudflare, not connected yet.');
      t.hub
        ..down = false
        ..tunnelNext.add(Hub.tunnelStands('connected', sinceMs: t.hub.keysAtMs));
      await nextLook(tester);
      expect(textOf(tester, 'tunnel-state'), startsWith('Connected to Cloudflare'));
    });

    testWidgets('a hub whose tunnel program is not running says so under a token that is set', (tester) async {
      await pumpKeys(
        tester,
        hub: (hub) {
          bothSet(hub);
          hub.wayIn = {...hub.wayIn!, 'door': false, 'tunnel': Hub.tunnelStands('off', there: false)};
        },
      );
      expect(
        textOf(tester, 'tunnel-state'),
        "The hub's tunnel program is not running. Update the hub (sudo hubctl update).",
      );
      // and a push door that could not be told the key
      expect(textOf(tester, 'door-not-told'), startsWith('The hub could not tell the push door its key'));
    });

    testWidgets('the way in is tried with the address GloriaFood sends to, which the hub remembers', (tester) async {
      final copied = clipboard(tester);
      final told = <HubKeys>[];
      final t = await pumpKeys(
        tester,
        told: told,
        hub: (hub) {
          bothSet(hub);
          hub.wayTried = {
            'door': {'ok': true, 'reason': null, 'code': 401},
            'outside': {
              'address': 'orders.example.com',
              'ok': true,
              'reason': null,
              'code': 401,
              'url': 'https://orders.example.com/online/push',
            },
          };
        },
      );
      expect(find.byKey(const ValueKey('way-in-endpoint')), findsNothing);
      await tapKey(tester, 'key-online_push-try');
      expect(find.text('Try the way in'), findsOneWidget);
      expect(find.textContaining('No key is sent anywhere'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('way-in-address')), 'https://Orders.Example.com/online/push');
      await tapKey(tester, 'way-in-try');
      expect(find.byType(WayInDialog), findsNothing);
      expect(t.hub.addressesTyped, ['https://Orders.Example.com/online/push']);
      expect(t.hub.wayTries, 1);
      expect(
        textOf(tester, 'key-online_push-said'),
        'The whole way in works: https://orders.example.com/online/push reaches this hub. That is the address for '
        "GloriaFood's admin. No key was sent anywhere.",
      );
      // the address stays on the card, to copy into GloriaFood's admin
      expect(textOf(tester, 'way-in-endpoint'), 'GloriaFood sends to https://orders.example.com/online/push');
      await tapKey(tester, 'way-in-copy');
      expect(copied, ['https://orders.example.com/online/push']);
      expect(told.last.wayIn!.address, 'orders.example.com');
      // tried again from the tunnel's card: the address is there already and is not saved a second time
      t.hub.wayTried = {
        'door': {'ok': true, 'reason': null, 'code': 401},
        'outside': {'address': 'orders.example.com', 'ok': false, 'reason': 'elsewhere', 'code': 200},
      };
      await tapKey(tester, 'key-online_tunnel-try');
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('way-in-address'))).controller!.text,
        'orders.example.com',
      );
      await tapKey(tester, 'way-in-try');
      expect(t.hub.addressesTyped.length, 1);
      expect(t.hub.wayTries, 2);
      expect(
        textOf(tester, 'key-online_tunnel-said'),
        'The push door is open, but from outside orders.example.com answers, but not from this hub. At Cloudflare, '
        'the public hostname must be handed to http://door:8090.',
      );
      final theme = Theme.of(tester.element(find.byType(HubKeysScreen)));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('key-online_tunnel-said'))).style!.color,
        theme.colorScheme.error,
      );
    });

    testWidgets('with no address the push door alone is tried, and Cancel tries nothing', (tester) async {
      final t = await pumpKeys(tester, hub: bothSet);
      await tapKey(tester, 'key-online_push-try');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.wayTries, 0);
      expect(find.byKey(const ValueKey('key-online_push-said')), findsNothing);
      await tapKey(tester, 'key-online_push-try');
      await tapKey(tester, 'way-in-try');
      expect(t.hub.addressesTyped, isEmpty);
      expect(t.hub.wayTries, 1);
      expect(
        textOf(tester, 'key-online_push-said'),
        startsWith('The push door is open and leads to this hub. Give the address GloriaFood sends to'),
      );
    });

    testWidgets('what is no address is said in the dialog, and nothing is tried', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          bothSet(hub);
          hub.refuseAddress = 'that does not look like an address on the internet (a name such as orders.example.com)';
        },
      );
      await tapKey(tester, 'key-online_push-try');
      await tester.enterText(find.byKey(const ValueKey('way-in-address')), '192.168.1.20:8090');
      await tapKey(tester, 'way-in-try');
      expect(
        textOf(tester, 'way-in-problem'),
        'That does not look like an address on the internet (a name such as orders.example.com).',
      );
      expect(find.byType(WayInDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('way-in-address'))).controller!.text,
        '192.168.1.20:8090',
      );
      expect(t.hub.wayTries, 0);
    });

    testWidgets('a tunnel with no key for pushes behind it says the key comes first', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          bothSet(hub);
          hub.hubKeys!['online_push'] = Hub.noKey('online_push');
        },
      );
      expect(find.byKey(const ValueKey('key-online_push-try')), findsNothing);
      await tapKey(tester, 'key-online_tunnel-try');
      await tapKey(tester, 'way-in-try');
      expect(t.hub.wayTries, 1);
      expect(textOf(tester, 'key-online_tunnel-said'), startsWith('This hub has no key for pushes yet.'));
    });

    testWidgets('removing the token closes the tunnel, and says what stops', (tester) async {
      final t = await pumpKeys(tester, hub: bothSet);
      await tapKey(tester, 'key-online_tunnel-remove');
      expect(find.textContaining('The tunnel is closed: nothing from outside reaches the hub.'), findsOneWidget);
      await tapKey(tester, 'key-remove-sure');
      expect(t.hub.keysRemoved, ['online_tunnel']);
      expect(textOf(tester, 'key-online_tunnel-state'), 'Not set · removed here by Mike, today');
      expect(find.byKey(const ValueKey('tunnel-state')), findsNothing);
    });

    testWidgets('both cards and their dialogs fit a 320-wide phone with large text', (tester) async {
      await pumpKeys(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        hub: (hub) {
          bothSet(hub);
          hub.wayIn = {
            ...hub.wayIn!,
            'address': 'orders.a-long-name-of-a-restaurant.example.com',
            'tunnel': Hub.tunnelStands('failing', sinceMs: hub.keysAtMs, reason: 'refused'),
          };
        },
      );
      final page = find.descendant(of: find.byType(HubKeysScreen), matching: find.byType(Scrollable)).first;
      for (final name in ['online_push', 'online_tunnel']) {
        await tester.scrollUntilVisible(find.byKey(ValueKey('key-$name-remove')), 200, scrollable: page);
        expect(tester.takeException(), isNull, reason: name);
        for (final button in ['type', 'try', 'remove']) {
          final at = tester.getRect(find.byKey(ValueKey('key-$name-$button')));
          expect(at.left >= 0 && at.right <= 320, isTrue, reason: '$name $button');
        }
      }
      await tester.scrollUntilVisible(find.byKey(const ValueKey('way-in-copy')), -100, scrollable: page);
      final copy = tester.getRect(find.byKey(const ValueKey('way-in-copy')));
      expect(copy.right <= 320, isTrue);
      // the key's dialog with a key made in it
      await tapKey(tester, 'key-online_push-type');
      await tapKey(tester, 'key-make');
      expect(tester.takeException(), isNull);
      for (final key in ['key-make', 'key-copy', 'key-save']) {
        final at = tester.getRect(find.byKey(ValueKey(key)));
        expect(at.left >= 0 && at.right <= 320 && at.bottom <= 568, isTrue, reason: key);
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // the token's
      await tapKey(tester, 'key-online_tunnel-type');
      expect(tester.takeException(), isNull);
      final save = tester.getRect(find.byKey(const ValueKey('key-save')));
      expect(save.right <= 320 && save.bottom <= 568, isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // and the try's
      await tapKey(tester, 'key-online_tunnel-try');
      expect(tester.takeException(), isNull);
      final go = tester.getRect(find.byKey(const ValueKey('way-in-try')));
      expect(go.right <= 320 && go.bottom <= 568, isTrue);
    });
  });

  group('texts to customers', () {
    // Made-up names in Twilio's shapes, put together here so that no line of this file reads as a real one.
    const hex = '0123456789abcdef';
    const sid = 'AC$hex$hex';
    const apiKey = 'SK$hex$hex';
    const service = 'MG$hex$hex';
    const authToken = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';

    /// A hub whose texts go out through Twilio, from a made-up number.
    void texting(Hub hub, {int texts = 0, int failed = 0, Map<String, dynamic>? lastFailed}) {
      hub
        ..hubKeys!['texts'] = {
          ...Hub.hubKey('texts'),
          'source': 'app',
          'shown': {'account': sid, 'sender': '+17815550100', 'key_sid': ''},
          'by': 'Mike',
          'at_ms': hub.keysAtMs,
        }
        ..texts = Hub.textsStand(sender: '+17815550100', texts: texts, failed: failed, lastFailed: lastFailed);
    }

    test('how the texts are doing, in words, with nothing of a customer in them', () {
      final at = DateTime(2026, 11, 26, 18, 20).millisecondsSinceEpoch;
      TextsState of(Map<String, dynamic> said) => TextsState.fromJson(said);
      expect(of(Hub.textsStand()).on, isFalse);
      final quiet = of(Hub.textsStand(sender: '+17815550100'));
      expect(quiet.on, isTrue);
      expect(quiet.dayWords, 'No text has gone out in the last 24 hours.');
      expect(quiet.failedWords, isNull);
      expect(of(Hub.textsStand(sender: 'x', texts: 1)).dayWords, '1 text in the last 24 hours. None failed.');
      final busy = of(
        Hub.textsStand(
          sender: 'x',
          texts: 14,
          failed: 2,
          lastFailed: {
            'at_ms': at,
            'kind': 'ready',
            'order_id': 'gf-301',
            'order_no': 12,
            'state': 'failed',
            'code': 30034,
            'said': 'the number to send from is not registered for business texts yet (Twilio\'s error 30034)',
          },
        ),
      );
      expect(busy.dayWords, '14 texts in the last 24 hours. 2 did not go.');
      expect(
        busy.failedWords,
        'The last one that did not go: the ready text for order #12, at ${clockTime(at)}. The number to send from is '
        "not registered for business texts yet (Twilio's error 30034).",
      );
      // an order without a number of its own, and a text the app does not know the kind of
      final bare = of(Hub.textsStand(sender: 'x', texts: 1, failed: 1, lastFailed: {'kind': 'thanks', 'said': ''}));
      expect(bare.failedWords, 'The last one that did not go: a text.');
      // a hub from before texts went out says nothing of them
      expect(HubKeys.fromJson((Hub()..texts = null).hubKeysSaid()).texts, isNull);
    });

    test('what a try came to, in words', () {
      TextTried of(Map<String, dynamic> said) => TextTried.fromJson(said);
      final delivered = of({'ok': true, 'state': 'delivered', 'code': null, 'said': ''});
      expect(delivered.bad, isFalse);
      expect(delivered.words, 'Delivered. Look at that phone: the text is there. The account works.');
      final sent = of({'ok': true, 'state': 'sent', 'code': null, 'said': ''});
      expect(sent.bad, isFalse);
      expect(sent.words, startsWith('Twilio took the text, and the phone company has not said yet'));
      expect(sent.words, contains('A2P 10DLC'));
      final failed = of({
        'ok': false,
        'state': 'failed',
        'code': 21608,
        'said':
            'this Twilio account is a trial: it texts only the numbers verified in its console (Twilio\'s error 21608)',
      });
      expect(failed.bad, isTrue);
      expect(
        failed.words,
        'The text did not go. This Twilio account is a trial: it texts only the numbers verified in its console '
        "(Twilio's error 21608).",
      );
      expect(of({'ok': false}).words, 'The text did not go.');
      // the two tries answer under the same name, and neither is read as the other
      final hub = Hub();
      expect(HubKeys.fromJson({...hub.hubKeysSaid(), 'tried': hub.textTried}).tried, isNull);
      expect(HubKeys.fromJson({...hub.hubKeysSaid(), 'tried': hub.wayTried}).textTried, isNull);
    });

    testWidgets('the card says no text goes out until the account is typed', (tester) async {
      await pumpKeys(tester);
      expect(find.text('Texts to customers (Twilio)'), findsOneWidget);
      expect(textOf(tester, 'key-texts-state'), 'Not set');
      expect(find.textContaining('Without it no text goes out'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('key-texts-type')), matching: find.text('Type the account')),
        findsOne,
      );
      expect(find.byKey(const ValueKey('key-texts-try')), findsNothing);
      expect(find.byKey(const ValueKey('texts-day')), findsNothing);
    });

    testWidgets('the account is typed in three boxes, and the token is nowhere on the page', (tester) async {
      final told = <HubKeys>[];
      final t = await pumpKeys(tester, told: told);
      await tapKey(tester, 'key-texts-type');
      expect(find.textContaining("In Twilio's console"), findsOneWidget);
      expect(textOf(tester, 'key-texts-note'), contains('A2P 10DLC'));
      expect(find.text('Auth Token'), findsOneWidget);
      // nothing typed, and then the token alone: nothing is sent
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Paste the Auth Token first.');
      await tester.enterText(find.byKey(const ValueKey('key-field')), ' $authToken ');
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'Twilio needs the Account SID and the number the texts are sent from.');
      expect(t.hub.keysTyped, isEmpty);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).obscureText, isTrue);
      await tester.enterText(find.byKey(const ValueKey('key-account')), ' $sid ');
      await tester.enterText(find.byKey(const ValueKey('key-sender')), '781 555 0100');
      await tapKey(tester, 'key-save');
      expect(find.byType(HubKeyDialog), findsNothing);
      expect(t.hub.keysTyped.single.$1, 'texts');
      expect(t.hub.keysTyped.single.$2, {'key': authToken, 'account': sid, 'sender': '781 555 0100', 'key_sid': ''});
      expect(textOf(tester, 'key-texts-state'), 'Set · sent from 781 555 0100 · typed here by Mike, today');
      expect(
        textOf(tester, 'key-texts-said'),
        'Saved. Texts to customers go out through Twilio from now on. Try it with your own phone.',
      );
      expect(textOf(tester, 'texts-day'), 'No text has gone out in the last 24 hours.');
      expect(find.textContaining(authToken), findsNothing);
      expect(told.last.texts!.on, isTrue);
      // replacing it starts from the account and the number in force, and never from the token
      await tapKey(tester, 'key-texts-type');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-account'))).controller!.text, sid);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-sender'))).controller!.text, '781 555 0100');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-field'))).controller!.text, isEmpty);
    });

    testWidgets('an API key goes with its SID, and what Twilio\'s account lacks is said in the dialog', (tester) async {
      final t = await pumpKeys(tester, hub: (hub) => hub.refuseHubKey = 'the Account SID begins with AC');
      await tapKey(tester, 'key-texts-type');
      await tester.enterText(find.byKey(const ValueKey('key-account')), 'my login');
      await tester.enterText(find.byKey(const ValueKey('key-field')), authToken);
      await tester.enterText(find.byKey(const ValueKey('key-sender')), service);
      await tester.enterText(find.byKey(const ValueKey('key-sid')), apiKey);
      await tapKey(tester, 'key-save');
      expect(textOf(tester, 'key-problem'), 'The Account SID begins with AC.');
      expect(find.byType(HubKeyDialog), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('key-account'))).controller!.text, 'my login');
      expect(t.hub.keysTyped.single.$2['key_sid'], apiKey);
      expect(t.hub.keysTyped.single.$2['sender'], service);
    });

    testWidgets('the card counts the last day, and names the last text that did not go by its order', (tester) async {
      final at = DateTime.fromMillisecondsSinceEpoch(1795000000000).millisecondsSinceEpoch;
      await pumpKeys(
        tester,
        hub: (hub) => texting(
          hub,
          texts: 9,
          failed: 1,
          lastFailed: {
            'at_ms': at,
            'kind': 'out',
            'order_id': 'o-77',
            'order_no': 31,
            'state': 'failed',
            'code': 21610,
            'said': 'the customer answered STOP to an earlier text: Twilio sends them no more (Twilio\'s error 21610)',
          },
        ),
      );
      expect(textOf(tester, 'key-texts-state'), 'Set · sent from +17815550100 · typed here by Mike, today');
      expect(textOf(tester, 'texts-day'), '9 texts in the last 24 hours. 1 did not go.');
      expect(
        textOf(tester, 'texts-failed'),
        'The last one that did not go: the "on its way" text for order #31, at ${clockTime(at)}. The customer '
        "answered STOP to an earlier text: Twilio sends them no more (Twilio's error 21610).",
      );
      expect(find.textContaining('Without it no text goes out'), findsNothing);
    });

    testWidgets('it is tried with one text to a number the manager types', (tester) async {
      final t = await pumpKeys(tester, hub: texting);
      await tapKey(tester, 'key-texts-try');
      expect(find.text('Try it with a text'), findsOneWidget);
      expect(find.textContaining('The number is kept nowhere.'), findsOneWidget);
      // nothing typed sends nothing, and Cancel sends nothing
      await tapKey(tester, 'key-try-send');
      expect(find.text('Try it with a text'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.textTries, isEmpty);
      await tapKey(tester, 'key-texts-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-number')), ' 781 555 0142 ');
      await tapKey(tester, 'key-try-send');
      expect(t.hub.textTries, ['781 555 0142']);
      expect(t.hub.hubKeysAuth, 'Bearer tok-admin');
      expect(textOf(tester, 'key-texts-said'), 'Delivered. Look at that phone: the text is there. The account works.');
      expect(find.textContaining('0142'), findsNothing);
      // what Twilio refuses is said under the card, in the hub's words
      t.hub.textTried = {
        'ok': false,
        'state': 'failed',
        'code': 20003,
        'said': "Twilio does not know the key: type it again under Keys and connections (Twilio's error 20003)",
      };
      await tapKey(tester, 'key-texts-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-number')), '781 555 0142');
      await tapKey(tester, 'key-try-send');
      expect(
        textOf(tester, 'key-texts-said'),
        "The text did not go. Twilio does not know the key: type it again under Keys and connections (Twilio's "
        'error 20003).',
      );
      // a text the phone company has not answered for yet is not called delivered
      t.hub.textTried = {'ok': true, 'state': 'sent', 'code': null, 'said': ''};
      await tapKey(tester, 'key-texts-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-number')), '781 555 0142');
      await tapKey(tester, 'key-try-send');
      expect(textOf(tester, 'key-texts-said'), contains('has not said yet whether it arrived'));
    });

    testWidgets('a hub whose account went meanwhile says so when it is tried', (tester) async {
      final t = await pumpKeys(tester, hub: texting);
      t.hub.hubKeys!['texts'] = Hub.noKey('texts');
      await tapKey(tester, 'key-texts-try');
      await tester.enterText(find.byKey(const ValueKey('key-try-number')), '781 555 0142');
      await tapKey(tester, 'key-try-send');
      expect(textOf(tester, 'key-texts-said'), 'This hub has no Twilio account in force. Type it again here.');
    });

    testWidgets('removing it asks first, and says the hub stops texting', (tester) async {
      final t = await pumpKeys(tester, hub: texting);
      await tapKey(tester, 'key-texts-remove');
      expect(find.textContaining('The hub stops texting customers.'), findsOneWidget);
      await tapKey(tester, 'key-remove-sure');
      expect(t.hub.keysRemoved, ['texts']);
      expect(textOf(tester, 'key-texts-state'), 'Not set · removed here by Mike, today');
      expect(find.byKey(const ValueKey('texts-day')), findsNothing);
      expect(find.byKey(const ValueKey('key-texts-try')), findsNothing);
    });

    testWidgets('the card and its dialogs fit a 320-wide phone with large text', (tester) async {
      await pumpKeys(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        hub: (hub) => texting(
          hub,
          texts: 120,
          failed: 3,
          lastFailed: {
            'at_ms': hub.keysAtMs,
            'kind': 'delayed',
            'order_no': 104,
            'said':
                'the number to send from is not registered for business texts yet (A2P 10DLC, in Twilio\'s console) '
                "(Twilio's error 30034)",
          },
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('key-texts-type')),
        300,
        scrollable: find.descendant(of: find.byType(HubKeysScreen), matching: find.byType(Scrollable)).first,
      );
      expect(tester.takeException(), isNull);
      for (final key in ['key-texts-type', 'key-texts-try', 'key-texts-remove']) {
        final button = tester.getRect(find.byKey(ValueKey(key)));
        expect(button.left >= 0 && button.right <= 320, isTrue, reason: key);
      }
      await tapKey(tester, 'key-texts-type');
      expect(tester.takeException(), isNull);
      var save = tester.getRect(find.byKey(const ValueKey('key-save')));
      expect(save.right <= 320 && save.bottom <= 568, isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'key-texts-try');
      expect(tester.takeException(), isNull);
      save = tester.getRect(find.byKey(const ValueKey('key-try-send')));
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
      expect(
        row(tester),
        'Set: map service · Not set: Google Maps, Mapbox, Azure Maps, GloriaFood, GloriaFood push, Cloudflare tunnel, '
        'Apple push, Twilio texts, Shipday',
      );
      await tapKey(tester, 'hub-keys');
      expect(find.byType(HubKeysScreen), findsOneWidget);
      await tapKey(tester, 'key-online-type');
      await tester.enterText(find.byKey(const ValueKey('key-field')), 'gloria-key-0001');
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$1, 'online');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        row(tester),
        'Set: map service, GloriaFood · Not set: Google Maps, Mapbox, Azure Maps, GloriaFood push, Cloudflare tunnel, '
        'Apple push, Twilio texts, Shipday',
      );
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
