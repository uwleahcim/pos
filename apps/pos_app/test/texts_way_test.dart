import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/hub_keys.dart';
import 'package:pos_app/screens/hub_keys_screen.dart';
import 'package:pos_app/takeout.dart' show clockTime;

import 'hub.dart';
import 'hub_keys_test.dart' show clipboard, pumpKeys, tapKey, textOf;

/// Twilio's way in, on Keys and connections (docs/text-inbox.md, "Instant delivery and pictures"): a
/// manager turns it on, gives the hub's name on the internet, tries it, and copies the address into Twilio's
/// console. The address holds a word only the hub and Twilio know: the page copies it and never shows it.

// A made-up name in Twilio's shape, put together here so that no line of this file reads as a real one.
const _hex = '0123456789abcdef';
const _account = 'AC$_hex$_hex';

Finder key(String name) => find.byKey(ValueKey(name));

/// A hub whose texts go out through Twilio, and with [address] one that has a name on the internet.
void texting(Hub hub, {String address = '', bool on = false}) {
  hub
    ..hubKeys!['texts'] = {
      ...Hub.hubKey('texts'),
      'source': 'app',
      'shown': {'account': _account, 'sender': '+17815550100', 'key_sid': ''},
      'by': 'Mike',
      'at_ms': hub.keysAtMs,
    }
    ..texts = Hub.textsStand(sender: '+17815550100')
    ..wayIn = {...hub.wayIn!, 'address': address};
  if (on) {
    hub
      ..textsWayOn = true
      ..textsWayMade = 1;
  }
}

void main() {
  group('in words', () {
    final now = DateTime(2026, 11, 27, 16, 30);

    test('how it stands: off, on without a name, waiting for Twilio, and when Twilio last called', () {
      expect(const TextsWay().words(now), startsWith('Off. The hub asks Twilio for new texts every few seconds'));
      expect(const TextsWay(on: true).words(now), contains("the hub's name on the internet is not known here yet"));
      const ready = TextsWay(on: true, address: 'orders.example.com', url: 'https://orders.example.com/twilio/W/text');
      expect(ready.ready, isTrue);
      expect(ready.words(now), startsWith('On. Twilio has not called yet.'));
      final at = DateTime(2026, 11, 27, 16, 2).millisecondsSinceEpoch;
      final called = TextsWay.fromJson({
        'on': true,
        'address': 'orders.example.com',
        'url': 'https://orders.example.com/twilio/W/text',
        'door': true,
        'called_ms': at,
      });
      expect(called.words(now), 'On. Twilio last called at ${clockTime(at)}.');
      final before = DateTime(2026, 11, 26, 9).millisecondsSinceEpoch;
      expect(
        TextsWay(on: true, address: 'a.example.com', url: 'u', calledMs: before).words(now),
        'On. Twilio last called yesterday.',
      );
    });

    test('the address is shown with the word left out', () {
      const way = TextsWay(on: true, address: 'orders.example.com', url: 'https://orders.example.com/twilio/W0rd/text');
      expect(way.shown, 'https://orders.example.com/twilio/…/text');
      expect(way.shown, isNot(contains('W0rd')));
    });

    test('a hub from before it says nothing of it', () {
      final keys = HubKeys.fromJson({'keys': <Object>[]});
      expect(keys.textsWay, isNull);
      expect(keys.textsWayTried, isNull);
    });

    test('what a try came to', () {
      TextsWayTried tried(Map<String, dynamic> door, [Map<String, dynamic>? outside]) =>
          TextsWayTried.fromJson({'door': door, 'outside': outside});
      const open = {'ok': true, 'reason': null, 'code': 200};
      Map<String, dynamic> out(String? reason, [int? code]) => {
        'address': 'orders.example.com',
        'ok': reason == null,
        'reason': reason,
        'code': code,
      };
      final shut = tried({'ok': false, 'reason': 'shut', 'code': 404});
      expect(shut.bad, isTrue);
      expect(shut.words, contains('Update the hub (sudo hubctl update)'));
      expect(tried({'ok': false, 'reason': 'no_answer', 'code': null}).words, contains('is not running on this hub'));
      final alone = tried(open);
      expect(alone.bad, isFalse, reason: 'a door that opens with no name to try from outside is not wrong');
      expect(alone.words, contains("Give the hub's name on the internet"));
      final whole = tried(open, out(null, 200));
      expect(whole.ok, isTrue);
      expect(whole.words, startsWith('The whole way in works'));
      final path = tried(open, out('not_routed', 404));
      expect(path.bad, isTrue);
      expect(path.words, contains('empty its Path box'));
      expect(path.words, contains('the path twilio and the service http://door:8090'));
      expect(tried(open, out('tunnel_down', 502)).words, contains('cannot get to the push door (502)'));
      expect(tried(open, out('elsewhere', 200)).words, contains('but not from this hub'));
      expect(tried(open, out('late')).words, contains('did not answer in time'));
    });
  });

  group('on the page', () {
    testWidgets('it is not there without a Twilio account, nor on a hub from before it', (tester) async {
      await pumpKeys(tester);
      expect(key('texts-way-state'), findsNothing);
      await pumpKeys(
        tester,
        hub: (hub) {
          texting(hub);
          hub.textsWayOn = null;
        },
      );
      expect(key('key-texts'), findsOneWidget);
      expect(key('texts-way-state'), findsNothing);
      expect(key('texts-way-on'), findsNothing);
    });

    testWidgets('turned on, given the name, tried and copied: the word is never on the page', (tester) async {
      final copied = clipboard(tester);
      final told = <HubKeys>[];
      final t = await pumpKeys(tester, hub: texting, told: told);
      expect(textOf(tester, 'texts-way-state'), startsWith('Off.'));
      expect(key('texts-way-copy'), findsNothing);
      expect(key('texts-way-try'), findsNothing);
      await tapKey(tester, 'texts-way-on');
      expect(t.hub.textsWayOn, isTrue);
      expect(textOf(tester, 'texts-way-state'), contains("the hub's name on the internet is not known here yet"));
      expect(textOf(tester, 'texts-way-said'), contains('press Try it'));
      expect(key('texts-way-copy'), findsNothing, reason: 'there is no address for Twilio without a name');
      expect(told.last.textsWay!.on, isTrue);

      await tapKey(tester, 'texts-way-try');
      expect(find.text("Try Twilio's way in"), findsOneWidget);
      expect(find.text("The hub's name on the internet"), findsOneWidget);
      await tester.enterText(key('way-in-address'), 'https://Orders.Example.com/');
      await tapKey(tester, 'way-in-try');
      expect(t.hub.addressesTyped, ['https://Orders.Example.com/']);
      expect(t.hub.textsWayTries, 1);
      expect(textOf(tester, 'texts-way-said'), startsWith('The whole way in works'));
      expect(textOf(tester, 'texts-way-state'), startsWith('On. Twilio has not called yet.'));
      expect(textOf(tester, 'texts-way-url'), 'For Twilio: https://orders.example.com/twilio/…/text');
      expect(find.textContaining(t.hub.textsWayWord), findsNothing);

      await tapKey(tester, 'texts-way-copy');
      expect(copied, ['https://orders.example.com/twilio/${t.hub.textsWayWord}/text']);
      expect(textOf(tester, 'texts-way-said'), contains('"A message comes in": Webhook, HTTP POST.'));
      expect(find.textContaining(t.hub.textsWayWord), findsNothing);
      await stop(tester);
    });

    testWidgets('a name that leads nowhere for Twilio says what to change at Cloudflare', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          texting(hub, address: 'orders.example.com', on: true);
          hub.textsWayTried = {
            'door': {'ok': true, 'reason': null, 'code': 200},
            'outside': {'ok': false, 'reason': 'not_routed', 'code': 404},
          };
        },
      );
      await tapKey(tester, 'texts-way-try');
      expect(tester.widget<TextField>(key('way-in-address')).controller!.text, 'orders.example.com');
      await tapKey(tester, 'way-in-try');
      expect(t.hub.addressesTyped, isEmpty, reason: 'the name did not change: it is not saved again');
      final said = textOf(tester, 'texts-way-said');
      expect(said, contains("orders.example.com is known, but lets only GloriaFood's path through"));
      expect(said, contains('empty its Path box'));
      final line = tester.widget<Text>(key('texts-way-said'));
      expect(line.style!.color, Theme.of(tester.element(key('texts-way-said'))).colorScheme.error);
      await stop(tester);
    });

    testWidgets('a door that does not let Twilio in, and a hub that could not tell its door, say to update', (
      tester,
    ) async {
      await pumpKeys(
        tester,
        hub: (hub) {
          texting(hub, address: 'orders.example.com', on: true);
          hub
            ..textsWayDoor = false
            ..textsWayTried = {
              'door': {'ok': false, 'reason': 'shut', 'code': 404},
              'outside': null,
            };
        },
      );
      expect(textOf(tester, 'texts-way-door'), contains('Update the hub (sudo hubctl update)'));
      await tapKey(tester, 'texts-way-try');
      await tapKey(tester, 'way-in-try');
      expect(textOf(tester, 'texts-way-said'), contains("does not let Twilio in yet"));
      await stop(tester);
    });

    testWidgets('it says when Twilio last called', (tester) async {
      late int at;
      await pumpKeys(
        tester,
        hub: (hub) {
          texting(hub, address: 'orders.example.com', on: true);
          at = hub.keysAtMs - 4 * 60 * 1000;
          hub.textsWayCalledMs = at;
        },
      );
      expect(textOf(tester, 'texts-way-state'), 'On. Twilio last called at ${clockTime(at)}.');
      await stop(tester);
    });

    testWidgets('a new address is asked about first, and kills the one Twilio has', (tester) async {
      final copied = clipboard(tester);
      final t = await pumpKeys(tester, hub: (hub) => texting(hub, address: 'orders.example.com', on: true));
      final first = t.hub.textsWayWord;
      await tapKey(tester, 'texts-way-more');
      await tapKey(tester, 'texts-way-again');
      expect(find.text('Make a new address?'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(t.hub.textsWayWord, first);
      await tapKey(tester, 'texts-way-more');
      await tapKey(tester, 'texts-way-again');
      await tapKey(tester, 'texts-way-sure');
      expect(t.hub.textsWayWord, isNot(first));
      expect(textOf(tester, 'texts-way-said'), "A new address is made. Copy it into Twilio's console now.");
      await tapKey(tester, 'texts-way-copy');
      expect(copied.single, contains(t.hub.textsWayWord));
      await stop(tester);
    });

    testWidgets('turning it off asks first, and says what to empty at Twilio', (tester) async {
      final t = await pumpKeys(tester, hub: (hub) => texting(hub, address: 'orders.example.com', on: true));
      await tapKey(tester, 'texts-way-more');
      await tapKey(tester, 'texts-way-off');
      expect(find.text('Turn it off?'), findsOneWidget);
      await tester.tap(find.text('Keep it on'));
      await tester.pumpAndSettle();
      expect(t.hub.textsWayOn, isTrue);
      await tapKey(tester, 'texts-way-more');
      await tapKey(tester, 'texts-way-off');
      await tapKey(tester, 'texts-way-sure');
      expect(t.hub.textsWayOn, isFalse);
      expect(textOf(tester, 'texts-way-state'), startsWith('Off.'));
      expect(textOf(tester, 'texts-way-said'), contains('"A message comes in"'));
      expect(key('texts-way-copy'), findsNothing);
      expect(key('texts-way-on'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub that lost its Twilio account meanwhile says so, and nothing is turned on', (tester) async {
      final t = await pumpKeys(tester, hub: texting);
      t.hub.hubKeys!['texts'] = Hub.noKey('texts');
      await tapKey(tester, 'texts-way-on');
      expect(textOf(tester, 'texts-way-said'), 'This hub has no Twilio account in force. Type it again here.');
      expect(t.hub.textsWayOn, isFalse);
      await stop(tester);
    });

    testWidgets('How to set it up lists what is done at Cloudflare and at Twilio', (tester) async {
      await pumpKeys(tester, hub: texting);
      await tapKey(tester, 'texts-way-how');
      expect(key('texts-way-help'), findsOneWidget);
      for (final title in ['The tunnel', 'The public hostname, at Cloudflare', "The address, in Twilio's console"]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.textContaining('door:8090. Leave the Path box empty.'), findsOneWidget);
      expect(find.textContaining('"A message comes in": Webhook, paste the address, HTTP POST'), findsOneWidget);
      await tapKey(tester, 'texts-way-help-close');
      expect(key('texts-way-help'), findsNothing);
      await stop(tester);
    });

    testWidgets('it fits a 320-wide phone with large text, and so do its boxes', (tester) async {
      await pumpKeys(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        hub: (hub) => texting(hub, address: 'a-long-name-for-the-hub.restaurant-example.com', on: true),
      );
      await tester.scrollUntilVisible(
        key('texts-way-more'),
        300,
        scrollable: find.descendant(of: find.byType(HubKeysScreen), matching: find.byType(Scrollable)).first,
      );
      expect(tester.takeException(), isNull);
      for (final name in ['texts-way-copy', 'texts-way-try', 'texts-way-how', 'texts-way-more']) {
        final button = tester.getRect(key(name));
        expect(button.left >= 0 && button.right <= 320, isTrue, reason: name);
      }
      await tapKey(tester, 'texts-way-how');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'texts-way-help-close');
      await tapKey(tester, 'texts-way-try');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'way-in-try');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'texts-way-more');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'texts-way-off');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
