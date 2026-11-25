import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/address_list.dart';
import 'package:pos_app/screens/address_box.dart';
import 'package:pos_app/screens/address_list_dialog.dart';
import 'package:pos_app/screens/delivery_fee_dialog.dart';
import 'package:pos_app/screens/fee_lookup.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/service_badge.dart';
import 'package:pos_app/screens/tap_focus.dart';
import 'package:pos_app/screens/text_arrows.dart';
import 'package:pos_app/screens/theme.dart';

import 'catering_test.dart' show dataOf, tapKey;
import 'delivery_distance_test.dart' show mapKept, said;
import 'delivery_fee_test.dart' show carried, delivery, picked, pumpForm, pumpOrder;
import 'delivery_test.dart' show created, elm, key, lindaDigits, typeNumber, typed;
import 'hub.dart';
import 'location_rows.dart';

/// A list of addresses while one is being typed (docs/delivery.md, "A list of addresses while typing"):
/// under every box a street address is typed in, the hub's list of what the letters could become. The
/// restaurant's own earlier deliveries come first, a map service's answers after them where a manager
/// turned that on, and a tap puts a line in the box. The hub's side, what is listed and what a map service
/// is sent, is backend/tests/orders/test_address_list.py; these tests are about the box, the forms it is
/// on and the switch under Location.

const elmCt = '12 Elm Ct, Woburn';
const elmMedford = '12 Elm Street, Medford, MA';
const elmwood = '12 Elmwood Road, Winchester, MA';

/// Letters typed in an address box, and the pause after which the hub is asked.
Future<void> type(WidgetTester tester, String letters, {String box = 'event-address'}) async {
  await tester.enterText(key(box), letters);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// The lines of the list under the box as they read, the top one first. Empty when there is no list.
List<String> lines(WidgetTester tester) => [
  for (final line in tester.widgetList<Text>(find.descendant(of: key('address-list'), matching: find.byType(Text))))
    if (line.textSpan != null) line.textSpan!.toPlainText(),
];

/// The little picture before a line: whose address it is.
IconData? pictured(WidgetTester tester, int line) =>
    tester.widget<Icon>(find.descendant(of: key('address-suggestion:$line'), matching: find.byType(Icon))).icon;

/// Whether the keyboard is in the box.
bool inBox(WidgetTester tester, String box) => tester.widget<TextField>(key(box)).focusNode!.hasPrimaryFocus;

Future<void> press(WidgetTester tester, LogicalKeyboardKey pressed) async {
  await tester.sendKeyEvent(pressed);
  await tester.pumpAndSettle();
}

/// An address box by itself over a hub, with another box under it to leave it for, and what it told the
/// form around it.
class Box {
  Box(this.t);

  final Terminal t;
  final controller = TextEditingController();
  int changed = 0;
  int done = 0;
  int left = 0;

  /// The letters the hub was asked about, in the order it was asked.
  List<String> get asked => [for (final ask in t.hub.addressAsks) ask['typed'] as String];
}

Future<Box> pumpBox(
  WidgetTester tester, {
  Map<String, List<Map<String, dynamic>>>? lists,
  bool listed = true,
  bool keys = false,
  String text = '',
  ThemeData? theme,
  Size? size,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size; // after the terminal, which sets its own
  t.hub.addressLists = listed ? (lists ?? Hub.elmLists) : null;
  final box = Box(t)..controller.text = text;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      // the rules of the keyboard's focus that sit around the whole app (main.dart)
      builder: keys ? (context, child) => TapTakesFocus(child: ArrowsLeaveTextBoxes(child: child!)) : null,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AddressBox(
                fieldKey: const ValueKey('address'),
                controller: box.controller,
                source: t.api.suggestAddresses,
                decoration: const InputDecoration(labelText: 'Deliver to'),
                onChanged: () => box.changed++,
                onDone: () => box.done++,
                onLeft: () => box.left++,
              ),
              const TextField(key: ValueKey('other')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return box;
}

void main() {
  group('what the hub says', () {
    test('a line: what a tap puts in the box, its two parts, and whose it is', () {
      final theirs = AddressSuggestion.of(Hub.addressLine(elm, from: 'customer'))!;
      expect((theirs.address, theirs.main, theirs.rest, theirs.own, theirs.theirs), (elm, elm, '', true, true));
      final ours = AddressSuggestion.of(Hub.addressLine(elmCt))!;
      expect((ours.own, ours.theirs), (true, false));
      final google = AddressSuggestion.of(
        Hub.addressLine(elmMedford, from: 'google', main: '12 Elm Street', rest: ' Medford, MA '),
      )!;
      expect((google.main, google.rest, google.own, google.theirs), ('12 Elm Street', 'Medford, MA', false, false));
      // a line with no word on its parts or on where it is from reads as the address, from an order
      final bare = AddressSuggestion.of(const {'address': ' 4 Oak Rd '})!;
      expect((bare.address, bare.main, bare.rest, bare.from), ('4 Oak Rd', '4 Oak Rd', '', 'orders'));
      expect(AddressSuggestion.of(const {'address': '4 Oak Rd', 'main': '  ', 'rest': 7})?.main, '4 Oak Rd');
      // and what is no line is none
      for (final odd in <Object?>[
        null,
        'an address',
        const <String, dynamic>{},
        const {'address': '   '},
        const {'address': 12},
      ]) {
        expect(AddressSuggestion.of(odd), isNull);
      }
    });

    test('a list: its lines in the order the hub gave them, and the name that goes under it', () {
      final list = AddressSuggestions.fromJson({
        'typed': '12 el',
        'suggestions': [
          Hub.addressLine(elm, from: 'customer'),
          'no line',
          {'address': ''},
          Hub.addressLine(elmMedford, from: 'google'),
        ],
        'credit': 'Google Maps',
      });
      expect((list.typed, list.credit), ('12 el', 'Google Maps'));
      expect([for (final one in list.suggestions) one.address], [elm, elmMedford]);
      // a hub from before there were several services says nothing of who answered or what is left
      expect((list.service, list.title, list.left, list.leftWords), (null, null, null, null));
      final none = AddressSuggestions.fromJson(const {'suggestions': 'none', 'credit': ''});
      expect((none.typed, none.suggestions.length, none.credit), ('', 0, null));
    });

    test('a list says which service answered and how many free lookups it has left this month', () {
      AddressSuggestions of(Object? left, {Object? most = 95000}) => AddressSuggestions.fromJson({
        'typed': '12 el',
        'suggestions': [Hub.addressLine(elmMedford, from: 'mapbox')],
        'credit': '\u00a9 Mapbox \u00a9 OpenStreetMap',
        'service': 'mapbox',
        'title': 'Mapbox',
        'left': left,
        'monthly_most': most,
      });
      final list = of(94988);
      expect((list.service, list.title, list.left, list.monthlyMost), ('mapbox', 'Mapbox', 94988, 95000));
      expect(list.leftWords, '94,988 of 95,000 free lookups left this month');
      expect(list.share, closeTo(0.99987, 0.00001));
      expect((of(0).share, of(0).leftWords), (0.0, '0 of 95,000 free lookups left this month'));
      expect(of(95000).share, 1.0);
      // without the month's most there is no ring, and the words say what is left alone
      expect((of(1, most: null).share, of(1, most: null).leftWords), (null, '1 free lookup left this month'));
      expect(of(0, most: 0).leftWords, 'no free lookups left this month');
      expect(of(999, most: 'x').leftWords, '999 free lookups left this month');
      for (final odd in <Object?>[null, -1, '12', 1.5]) {
        expect((of(odd).leftWords, of(odd).share), (null, null));
      }
      expect([counted(0), counted(12), counted(1234567), counted(-4500)], ['0', '12', '1,234,567', '-4,500']);
    });

    test('the setting: every service in the order they are asked, and what a save sends', () {
      final setting = AddressListSetting.fromJson(
        Hub.addressListOf([
          Hub.addressService('google', on: true, left: 0),
          Hub.addressService('mapbox', on: true, left: 94988, resting: true),
          Hub.addressService('azure', key: false),
        ]),
      );
      expect([for (final one in setting.services) one.name], ['google', 'mapbox', 'azure']);
      expect([for (final one in setting.services) one.title], ['Google Maps', 'Mapbox', 'Azure Maps']);
      expect(
        [for (final one in setting.services) (one.on, one.key, one.asks)],
        [(true, true, true), (true, true, true), (false, false, false)],
      );
      expect((setting.google, setting.asks), (true, true));
      expect([for (final one in setting.asking) one.name], ['google', 'mapbox']);
      final (google, mapbox, azure) = (setting.services[0], setting.services[1], setting.services[2]);
      expect((google.left, google.monthlyMost, google.usedUp), (0, 9500, true));
      expect(google.words, startsWith('Its free lookups for this month are used up'));
      expect(mapbox.words, 'Not answering right now: the next one is asked meanwhile');
      expect(azure.words, 'No key on this hub yet (Keys and connections)');
      expect(
        AddressService.of(Hub.addressService('mapbox', left: 94988))!.words,
        'Off · 94,988 of 95,000 free lookups left this month',
      );
      expect(
        AddressService.of(Hub.addressService('mapbox', on: true, left: 94988))!.words,
        '94,988 of 95,000 free lookups left this month',
      );
      // whether there is a key is the hub's to say: a save sends the switches alone, every one of them
      expect(setting.toJson(), {'google': true, 'mapbox': true, 'azure': false});
      expect(setting.turned({'google': false}).toJson(), {'google': false, 'mapbox': true, 'azure': false});
      // what names no service is none
      expect(AddressService.of(const {'title': 'Bing'}), isNull);
      expect(AddressService.of('google'), isNull);
    });

    test('the setting of a hub from before there were several is Google alone', () {
      final old = AddressListSetting.fromJson(const {
        'google': true,
        'service': true,
        'asks': true,
        'credit': 'Google Maps',
      });
      expect(
        [for (final one in old.services) (one.name, one.title, one.on, one.key)],
        [('google', 'Google Maps', true, true)],
      );
      expect((old.google, old.asks, old.services.single.left), (true, true, null));
      expect(old.services.single.words, 'On');
      expect(old.toJson(), {'google': true}); // what that hub understands
      final bare = AddressListSetting.fromJson(const {});
      expect((bare.google, bare.asks, bare.services.single.key), (false, false, false));
      final tried = AddressListTry.fromJson(const {
        'ok': true,
        'found': 3,
        'reason': null,
        'message': '',
        'left': 9411,
      });
      expect((tried.ok, tried.found, tried.message, tried.left), (true, 3, '', 9411));
      final failed = AddressListTry.fromJson(const {'ok': false, 'found': 'x', 'message': 'Google refused the key.'});
      expect((failed.ok, failed.found, failed.message, failed.left), (false, 0, 'Google refused the key.', null));
    });
  });

  group('asking the hub', () {
    testWidgets('the letters go as they were typed, with the digits of the number and nothing else', (tester) async {
      final t = await terminal(tester);
      t.hub.addressLists = Hub.elmLists;
      final list = await tester.runAsync(() => t.api.suggestAddresses('12 el', phone: '(781) 555-0101'));
      expect([for (final one in list!.suggestions) one.address], [elm, elmCt, elmMedford, elmwood]);
      expect(list.credit, 'Google Maps');
      await tester.runAsync(() => t.api.suggestAddresses('12 elm '));
      await tester.runAsync(() => t.api.suggestAddresses('12 el', own: false));
      expect(t.hub.addressAsks, [
        {'typed': '12 el', 'phone': lindaDigits},
        {'typed': '12 elm '}, // the space says the word is whole: it is the hub's to read
        {'typed': '12 el', 'own': false},
      ]);
      // the letters are in the body of the request, never in its address
      expect(t.hub.requests.where((one) => one.contains('addresses')).toSet(), {'POST /addresses/suggest'});
    });

    testWidgets('a hub older than the list is asked once in ten minutes', (tester) async {
      final t = await terminal(tester);
      expect(await tester.runAsync(() => t.api.suggestAddresses('12 el')), isNull);
      expect(await tester.runAsync(() => t.api.suggestAddresses('12 elm')), isNull);
      expect(t.hub.requests, ['POST /addresses/suggest']);
    });

    testWidgets('no answer is no list, and never a reason to turn away from the hub', (tester) async {
      final t = await terminal(tester);
      t.hub.addressLists = Hub.elmLists;
      await tester.runAsync(t.api.health); // the terminal talks to its hub
      final before = t.api.connection.value;
      expect(before.endpoint, 'http://hub:8000');
      final turns = <Object?>[];
      t.api.connection.addListener(() => turns.add(t.api.connection.value.endpoint));
      t.hub.addressesDown = true;
      expect(await tester.runAsync(() => t.api.suggestAddresses('12 el')), isNull);
      t.hub.addressesDown = false;
      t.hub.down = true;
      expect(await tester.runAsync(() => t.api.suggestAddresses('12 el')), isNull);
      expect((turns.length, identical(t.api.connection.value, before)), (0, true));
      // and it is asked again the next time: one that did not answer is not an older hub
      t.hub.down = false;
      expect((await tester.runAsync(() => t.api.suggestAddresses('12 el')))?.suggestions, hasLength(4));
    });

    testWidgets('the setting is read and saved with the manager\'s token, and each service is tried', (tester) async {
      final t = await terminal(tester);
      expect(await tester.runAsync(t.api.addressList), isNull); // an older hub
      t.hub.addressList = Hub.addressListOff;
      final off = await tester.runAsync(t.api.addressList);
      expect(
        [for (final one in off!.services) (one.name, one.on, one.key)],
        [('google', false, true), ('mapbox', false, true), ('azure', false, false)],
      );
      final saved = await tester.runAsync(
        () => t.api.saveAddressList('tok-admin', off.turned({'google': true, 'mapbox': true})),
      );
      expect([for (final one in saved!.services) one.asks], [true, true, false]);
      expect(t.hub.addressListAuth, 'Bearer tok-admin');
      final tried = await tester.runAsync(() => t.api.tryAddressList('tok-admin', service: 'mapbox'));
      expect((tried?.ok, tried?.found, tried?.left), (true, 3, 9411));
      expect(t.hub.addressTried, ['mapbox']);
      await tester.runAsync(() => t.api.tryAddressList('tok-admin'));
      expect(t.hub.addressTried, ['mapbox', 'google']);
    });
  });

  group('the box', () {
    testWidgets('once the typing pauses, the list is under it: own deliveries first, then the map service', (
      tester,
    ) async {
      final box = await pumpBox(tester);
      await tester.enterText(key('address'), '12 el');
      await tester.pump(const Duration(milliseconds: 250));
      expect((box.asked.length, lines(tester).length), (0, 0)); // still typing
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(box.asked, ['12 el']);
      expect(lines(tester), [elm, elmCt, '12 Elm Street  Medford, MA', '12 Elmwood Road  Winchester, MA']);
      expect(
        [for (var line = 0; line < 4; line++) pictured(tester, line)],
        [
          Icons.person_pin_circle_outlined, // the customer's own
          Icons.history, // another delivery of the restaurant's
          Icons.place_outlined,
          Icons.place_outlined,
        ],
      );
      // a list with a map service's answer carries its name, as its terms want, and what it has left free
      expect(said(tester, 'address-credit'), 'Google Maps');
      expect(tester.widget<Text>(key('address-credit')).style?.color, MapCredit.onLight);
      final badge = tester.widget<ServiceBadge>(key('address-badge'));
      expect((badge.service, badge.title), ('google', 'Google Maps'));
      expect(badge.words, '9,412 of 9,500 free lookups left this month');
      expect(badge.share, closeTo(0.9907, 0.0001));
      expect(ServiceBadge.letterOf('google', 'Google Maps'), 'G');
      // nothing is put in the box by itself, and the form was told of the typing alone
      expect((box.controller.text, box.changed, box.done, box.left), ('12 el', 1, 0, 0));
    });

    testWidgets('a list of the restaurant\'s own deliveries alone carries no name', (tester) async {
      await pumpBox(
        tester,
        lists: {
          '12 el': [Hub.addressLine(elm, from: 'customer'), Hub.addressLine(elmCt)],
        },
      );
      await type(tester, '12 el', box: 'address');
      expect(lines(tester), [elm, elmCt]);
      expect(key('address-credit'), findsNothing);
      expect(key('address-badge'), findsNothing);
    });

    testWidgets('once Google\'s free lookups are used up, the line under the list names the one that answered', (
      tester,
    ) async {
      final box = await pumpBox(
        tester,
        lists: {
          '12 el': [
            Hub.addressLine(elm, from: 'customer'),
            Hub.addressLine(elmMedford, from: 'mapbox', main: '12 Elm Street', rest: 'Medford, MA'),
          ],
          '12 elm': [Hub.addressLine(elmwood, from: 'azure', main: '12 Elmwood Road', rest: 'Winchester, MA')],
        },
      );
      box.t.hub.addressLeft = 94988;
      await type(tester, '12 el', box: 'address');
      expect(lines(tester), [elm, '12 Elm Street  Medford, MA']);
      expect(said(tester, 'address-credit'), '\u00a9 Mapbox \u00a9 OpenStreetMap');
      var badge = tester.widget<ServiceBadge>(key('address-badge'));
      expect((badge.service, ServiceBadge.letterOf(badge.service, badge.title)), ('mapbox', 'M'));
      expect(badge.words, '94,988 of 95,000 free lookups left this month');
      // a reader hears whose lookups they are, and a tap on the badge says it too
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Mapbox: 94,988 of 95,000 free lookups left this month'), findsOneWidget);
      handle.dispose();
      await tester.tap(key('address-badge'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Mapbox: 94,988 of 95,000 free lookups left this month'), findsOneWidget);
      // the list and the keyboard stay
      expect((inBox(tester, 'address'), key('address-suggestion:1').evaluate().length), (true, 1));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      // nearly nothing left: the ring is red
      box.t.hub.addressLeft = 1;
      await type(tester, '12 elm', box: 'address');
      expect(said(tester, 'address-credit'), 'Azure Maps');
      badge = tester.widget<ServiceBadge>(key('address-badge'));
      expect((badge.service, badge.words), ('azure', '1 of 47,500 free lookups left this month'));
      final context = tester.element(key('address-badge'));
      expect(ServiceBadge.ringColor(context, badge.share!), PosColors.of(context).timerLate);
      expect(ServiceBadge.ringColor(context, 0.15), PosColors.of(context).timerWarn);
      expect(ServiceBadge.ringColor(context, 0.5), Theme.of(context).colorScheme.primary);
    });

    testWidgets('a hub that does not say what is left shows the name alone', (tester) async {
      final box = await pumpBox(tester);
      box.t.hub.addressLeft = null; // a hub from before there were several services
      await type(tester, '12 el', box: 'address');
      expect(said(tester, 'address-credit'), 'Google Maps');
      expect(key('address-badge'), findsNothing);
    });

    testWidgets('the badge does not move while the list changes under it', (tester) async {
      await pumpBox(tester);
      await type(tester, '12 el', box: 'address');
      final at = tester.getTopLeft(key('address-badge'));
      // under the box, before the first line, in the column of the lines' pictures
      expect(at.dy, lessThan(tester.getTopLeft(key('address-suggestion:0')).dy));
      expect(at.dy, greaterThan(tester.getBottomLeft(key('address')).dy));
      final picture = find.descendant(of: key('address-suggestion:0'), matching: find.byType(Icon));
      expect(tester.getCenter(key('address-badge')).dx, closeTo(tester.getCenter(picture).dx, 1.5));
      await type(tester, '12 elm s', box: 'address'); // a shorter list, other addresses
      expect(lines(tester), hasLength(3));
      expect(tester.getTopLeft(key('address-badge')), at);
    });

    testWidgets('on a small phone with large type the badge stays tiny and the name is whole', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpBox(tester, size: const Size(320, 640));
      await type(tester, '12 el', box: 'address');
      expect(tester.takeException(), isNull);
      expect(tester.getSize(key('address-list')).width, 320 - 32);
      expect(tester.getSize(key('address-badge')), const Size(ServiceBadge.size, ServiceBadge.size)); // tiny still
      expect(tester.getRect(key('address-credit')).right, lessThanOrEqualTo(320 - 16 - 12));
    });

    testWidgets('a long name on a narrow screen with large type is made smaller, never cut or broken', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpBox(
        tester,
        size: const Size(240, 640),
        lists: {
          '12 el': [Hub.addressLine('12 Ellis Street, Woburn, MA', from: 'mapbox')],
        },
      );
      await type(tester, '12 el', box: 'address');
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(key('address-credit')).data, '\u00a9 Mapbox \u00a9 OpenStreetMap');
      final words = tester.renderObject<RenderParagraph>(key('address-credit'));
      // the whole name was laid out on one line (wider than there is room for)...
      expect(words.didExceedMaxLines, isFalse);
      expect(words.size.width, greaterThan(tester.getSize(key('address-list')).width));
      expect(words.size.width, moreOrLessEquals(words.getMaxIntrinsicWidth(double.infinity), epsilon: 1));
      // ...and is shown smaller, inside the list, after the badge
      final shown = tester.getRect(key('address-credit')), list = tester.getRect(key('address-list'));
      expect(shown.right, lessThanOrEqualTo(list.right - 12 + 0.01));
      expect(shown.left, greaterThan(tester.getRect(key('address-badge')).right));
      expect(tester.getSize(key('address-badge')), const Size(ServiceBadge.size, ServiceBadge.size));
    });

    testWidgets('a reader is told whose address a line is', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBox(tester);
      await type(tester, '12 el', box: 'address');
      expect(find.bySemanticsLabel(RegExp('^Their earlier delivery')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^An earlier delivery')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a tap puts the line in the box, says the address is done, and leaves the keyboard there', (
      tester,
    ) async {
      final box = await pumpBox(tester);
      await type(tester, '12 el', box: 'address');
      await tapKey(tester, 'address-suggestion:1');
      expect(box.controller.text, elmCt);
      expect(box.controller.selection, const TextSelection.collapsed(offset: elmCt.length));
      expect(lines(tester), isEmpty);
      expect((box.changed, box.done, box.left), (2, 1, 0));
      expect(inBox(tester, 'address'), isTrue);
      // the line that was tapped is not asked about
      await tester.pump(const Duration(seconds: 1));
      expect(box.asked, ['12 el']);
    });

    testWidgets('Enter says the address is done as it was typed, and takes no line', (tester) async {
      final box = await pumpBox(tester);
      await type(tester, '12 el', box: 'address');
      expect(lines(tester), isNotEmpty);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect((box.controller.text, box.done, lines(tester).length), ('12 el', 1, 0));
      // and Enter before the pause is over asks for no list at all
      await tester.enterText(key('address'), '12 elm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(seconds: 1));
      expect((box.asked.join('|'), box.done, lines(tester).length), ('12 el', 2, 0));
    });

    testWidgets('one letter asks nothing, and letters the hub knows nothing for show no list', (tester) async {
      final box = await pumpBox(tester);
      await type(tester, '1', box: 'address');
      expect(box.asked, isEmpty);
      await type(tester, '12 el', box: 'address');
      expect(lines(tester), hasLength(4));
      await type(tester, '12 elk', box: 'address');
      expect((box.asked.join('|'), lines(tester).length), ('12 el|12 elk', 0));
      await type(tester, '12 elm s', box: 'address');
      expect(lines(tester), hasLength(3));
      // back to a letter: the list goes without the hub being asked
      await type(tester, ' 1 ', box: 'address');
      expect((box.asked.length, lines(tester).length), (3, 0));
    });

    testWidgets('an address the form put in the box is not asked about', (tester) async {
      final box = await pumpBox(tester, text: elm);
      await tester.pump(const Duration(seconds: 1));
      box.controller.text = elmCt; // as a form fills in a customer's last address
      await tester.pump(const Duration(seconds: 1));
      expect((box.asked.length, lines(tester).length, box.changed), (0, 0, 0));
    });

    testWidgets('an answer for letters that were typed over is not shown', (tester) async {
      final box = await pumpBox(tester);
      final held = box.t.hub.addressWaits = Completer<void>();
      await tester.enterText(key('address'), '12 el');
      await tester.pump(const Duration(milliseconds: 300));
      expect(box.asked, ['12 el']); // asked, and the answer is on its way
      await tester.enterText(key('address'), '12 elm s');
      await tester.pump(const Duration(milliseconds: 100));
      box.t.hub.addressWaits = null;
      held.complete();
      await tester.pump();
      expect(lines(tester), isEmpty); // the four lines for "12 el" came and were dropped
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(box.asked, ['12 el', '12 elm s']);
      expect(lines(tester), hasLength(3));
    });

    testWidgets('the list goes when the box is left, and what was typed stands', (tester) async {
      final box = await pumpBox(tester);
      await type(tester, '12 el', box: 'address');
      await tester.tap(key('other'));
      await tester.pumpAndSettle();
      expect((lines(tester).length, box.controller.text, box.left, box.done), (0, '12 el', 1, 0));
      // left before the pause is over, the hub is not asked at all
      await tester.enterText(key('address'), '12 elm');
      await tester.tap(key('other'));
      await tester.pump(const Duration(seconds: 1));
      expect((box.asked.join('|'), box.left, lines(tester).length), ('12 el', 2, 0));
    });

    testWidgets('a hub that does not answer, or one older than the list, leaves a box that is a box', (tester) async {
      final box = await pumpBox(tester);
      box.t.hub.down = true;
      await type(tester, '12 el', box: 'address');
      expect((lines(tester).length, box.controller.text, box.changed), (0, '12 el', 1));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      box.t.hub.down = false;
      await type(tester, '12 elm', box: 'address');
      expect(lines(tester), hasLength(4)); // and it lists again once the hub answers
      await stop(tester);
      final older = await pumpBox(tester, listed: false);
      await type(tester, '12 el', box: 'address');
      await type(tester, '12 elm', box: 'address');
      expect((lines(tester).length, older.t.hub.requests.join('|')), (0, 'POST /addresses/suggest'));
    });

    testWidgets('where there is nothing to ask, it is a box and no more', (tester) async {
      final controller = TextEditingController();
      var changed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AddressBox(fieldKey: const ValueKey('address'), controller: controller, onChanged: () => changed++),
          ),
        ),
      );
      await type(tester, '12 el', box: 'address');
      expect((controller.text, changed, lines(tester).length), ('12 el', 1, 0));
    });

    testWidgets('with a keyboard: the arrow down goes into the list, Enter takes the line, Escape closes it', (
      tester,
    ) async {
      final box = await pumpBox(tester, keys: true);
      await type(tester, '12 el', box: 'address');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect((inBox(tester, 'address'), lines(tester).length, box.left), (false, 4, 0)); // in the list, not gone
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect((box.controller.text, box.done, box.left), (elmCt, 1, 0));
      expect((lines(tester).length, inBox(tester, 'address')), (0, true));
      // Escape closes the list from a line of it, and from the box
      await type(tester, '12 elm', box: 'address');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.escape);
      expect((lines(tester).length, box.controller.text, inBox(tester, 'address'), box.left), (0, '12 elm', true, 0));
      await type(tester, '12 elm s', box: 'address');
      expect(lines(tester), hasLength(3));
      await press(tester, LogicalKeyboardKey.escape);
      expect((lines(tester).length, box.controller.text, inBox(tester, 'address'), box.done), (0, '12 elm s', true, 1));
      // and the arrow up from the top line is back in the box, the list still open
      await type(tester, '12 el', box: 'address');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect((inBox(tester, 'address'), lines(tester).length, box.left), (true, 4, 0));
    });

    testWidgets('a click with the mouse on a Mac takes the line: the press is not a click away from the box', (
      tester,
    ) async {
      final box = await pumpBox(tester, keys: true);
      await type(tester, '12 el', box: 'address');
      final click = await tester.startGesture(
        tester.getCenter(key('address-suggestion:2')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect((lines(tester).length, box.left), (4, 0)); // the list is still there for the mouse to let go on
      await click.up();
      await tester.pumpAndSettle();
      expect((box.controller.text, box.done, box.left), (elmMedford, 1, 0));
      expect((lines(tester).length, inBox(tester, 'address')), (0, true));
      // a click on something else is a click away, as with any box on a Mac
      await type(tester, '12 el', box: 'address');
      await tester.tap(key('other'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect((lines(tester).length, box.left), (0, 1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('in the dark the map service\'s name is white, and a line reads on its ground', (tester) async {
      await pumpBox(tester, theme: PosTheme.dark());
      await type(tester, '12 el', box: 'address');
      expect(tester.widget<Text>(key('address-credit')).style?.color, MapCredit.onDark);
      expect(tester.takeException(), isNull);
    });
  });

  group('the to-go form', () {
    testWidgets('the number on the form goes with the letters, and a tap fills the address and asks how far', (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      t.hub.addressLists = Hub.elmLists;
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await typeNumber(tester, '781 555 0101');
      await tapKey(tester, 'handover:delivery');
      await type(tester, '12 el');
      expect(t.hub.addressAsks, [
        {'typed': '12 el', 'phone': lindaDigits},
      ]);
      expect(lines(tester).first, elm);
      expect(t.hub.distanceAsks, isEmpty); // a list is no lookup
      await tapKey(tester, 'address-suggestion:0');
      expect((typed(tester, 'event-address'), lines(tester).length), (elm, 0));
      // the address is done: how far it is was asked once, and its band is picked
      expect([for (final ask in t.hub.distanceAsks) ask['address']], [elm]);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(picked(tester, '4.5'), isTrue);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['address'], elm);
      expect(created(t.hub)['delivery_fee'], {'up_to': '4.5', 'measured': mapKept});
      expect(t.hub.distanceAsks, hasLength(1));
      expect(t.hub.addressAsks, hasLength(1));
      await stop(tester);
    });

    testWidgets('the list closes when the form moves on, and the address typed is looked up as before', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      t.hub.addressLists = Hub.elmLists;
      t.hub.distances['12 el'] = const {'miles': '1.1', 'minutes': 4};
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await type(tester, '12 el');
      expect(t.hub.addressAsks, [
        {'typed': '12 el'}, // no number on the form, none sent
      ]);
      expect(lines(tester), hasLength(4));
      await tester.tap(key('takeout-name'));
      await tester.pumpAndSettle();
      expect((lines(tester).length, typed(tester, 'event-address')), (0, '12 el'));
      expect([for (final ask in t.hub.distanceAsks) ask['address']], ['12 el']);
      await stop(tester);
    });

    testWidgets('on a hub older than the list the form is what it was', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await type(tester, '12 el');
      await type(tester, elm);
      expect(lines(tester), isEmpty);
      expect(t.hub.requests.where((one) => one.contains('addresses')), ['POST /addresses/suggest']);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      await stop(tester);
    });

    testWidgets('on a small phone with large type the box stays in sight over its list', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees, size: const Size(320, 568), type: 1.3);
      t.hub.addressLists = {
        '12 el': [...Hub.elmLists['12 el']!, Hub.addressLine('12 Ellis Street, Woburn, MA', from: 'google')],
      };
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await type(tester, '12 el');
      expect(lines(tester), hasLength(5));
      expect(tester.takeException(), isNull);
      // too short a screen for the box and five lines: the box went to the top, and what is typed can be read
      expect(key('event-address').hitTestable(), findsOneWidget);
      expect(key('address-suggestion:0').hitTestable(), findsOneWidget);
      expect(tester.getRect(key('address-list')).bottom, greaterThan(568 - 120)); // the list runs on under the fold
      for (var line = 0; line < 5; line++) {
        expect(tester.getSize(key('address-suggestion:$line')).height, greaterThanOrEqualTo(40));
      }
      // the rest of the list is a scroll away
      await tapKey(tester, 'address-suggestion:4');
      expect(typed(tester, 'event-address'), '12 Ellis Street, Woburn, MA');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('where there is room, the form scrolls the whole list into sight under the box', (tester) async {
      final t = await pumpForm(tester, fees: Hub.mapFees, size: const Size(390, 844));
      t.hub.addressLists = Hub.elmLists;
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      await type(tester, '12 el');
      expect(key('event-address').hitTestable(), findsOneWidget);
      for (var line = 0; line < 4; line++) {
        expect(key('address-suggestion:$line').hitTestable(), findsOneWidget);
      }
      expect(key('address-credit').hitTestable(), findsOneWidget);
      await stop(tester);
    });
  });

  group('the order', () {
    testWidgets("its own number goes with the letters, and a tap changes where it is brought", (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('2', '3.00')), fees: Hub.mapFees);
      t.hub.addressLists = {
        '4 oa': [Hub.addressLine('4 Oak Rd, Woburn', from: 'customer')],
      };
      await tapKey(tester, 'when-strip');
      await tester.pump(const Duration(seconds: 1));
      expect(t.hub.addressAsks, isEmpty); // the address it has is not asked about
      await type(tester, '4 oa');
      expect(t.hub.addressAsks, [
        {'typed': '4 oa', 'phone': lindaDigits},
      ]);
      await tapKey(tester, 'address-suggestion:0');
      expect(typed(tester, 'event-address'), '4 Oak Rd, Woburn');
      expect([for (final ask in t.hub.distanceAsks) ask['address']], ['4 Oak Rd, Woburn']);
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['address'], '4 Oak Rd, Woburn');
      await stop(tester);
    });
  });

  group('under Location', () {
    Future<Terminal> pumpLocation(
      WidgetTester tester, {
      Map<String, dynamic>? list,
      Size? size,
      double? type,
      String row = 'address-list',
    }) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = Hub.mapFees;
      t.hub.addressList = list;
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
      await bringUp(tester, row);
      return t;
    }

    String rowWords(WidgetTester tester) => ((tester.widget<ListTile>(key('address-list')).subtitle!) as Text).data!;

    bool switched(WidgetTester tester, String service) =>
        tester.widget<SwitchListTile>(key('address-list-$service')).value;

    testWidgets('every service is off until a manager turns it on, and they stand in the order they are asked', (
      tester,
    ) async {
      final t = await pumpLocation(tester, list: Hub.addressListOff);
      expect(rowWords(tester), 'Your own earlier deliveries are listed while an address is typed');
      await tapKey(tester, 'address-list');
      expect(find.byType(AddressListDialog), findsOneWidget);
      expect(find.text('1. Google Maps'), findsOneWidget);
      expect(find.text('2. Mapbox'), findsOneWidget);
      expect(find.text('3. Azure Maps'), findsOneWidget);
      final top = [
        for (final service in ['google', 'mapbox', 'azure']) tester.getTopLeft(key('address-list-$service')).dy,
      ];
      expect(top, orderedEquals([...top]..sort()));
      expect(
        [
          for (final service in ['google', 'mapbox', 'azure']) switched(tester, service),
        ],
        [false, false, false],
      );
      expect(said(tester, 'address-list-state:google'), 'Off · 9,500 of 9,500 free lookups left this month');
      expect(said(tester, 'address-list-state:mapbox'), 'Off · 95,000 of 95,000 free lookups left this month');
      expect(said(tester, 'address-list-state:azure'), 'No key on this hub yet (Keys and connections)');
      expect(key('address-list-try:azure'), findsNothing); // nothing to try it with
      expect(said(tester, 'address-list-order'), contains('the next one only once the one before it has used up'));
      expect(said(tester, 'address-list-says'), contains('costs nothing and asks nobody'));
      expect(said(tester, 'address-list-sent'), 'All off: nothing that is typed leaves the building.');
      await tapKey(tester, 'address-list-google');
      await tapKey(tester, 'address-list-mapbox');
      expect(said(tester, 'address-list-sent'), contains('no name, no phone number'));
      expect(said(tester, 'address-list-sent'), contains('stops a little short of what each gives away free'));
      expect(t.hub.addressListAuth, isNull); // nothing is saved by the switches alone
      await tapKey(tester, 'address-list-save');
      expect(t.hub.addressListAuth, 'Bearer tok-admin');
      expect(
        [
          for (final name in ['google', 'mapbox', 'azure']) t.hub.addressList?[name],
        ],
        [true, true, false],
      );
      expect(find.byType(AddressListDialog), findsNothing);
      expect(find.text('Address list saved'), findsOneWidget);
      expect(
        rowWords(tester),
        'Your own earlier deliveries, then Google Maps, are listed while an address is typed. Mapbox takes over '
        'when it gives no list',
      );
      // and Google off again: Mapbox is the first one asked
      await tapKey(tester, 'address-list');
      expect((switched(tester, 'google'), switched(tester, 'mapbox')), (true, true));
      await tapKey(tester, 'address-list-google');
      await tapKey(tester, 'address-list-save');
      expect((t.hub.addressList?['google'], t.hub.addressList?['mapbox']), (false, true));
      expect(rowWords(tester), 'Your own earlier deliveries, then Mapbox, are listed while an address is typed');
      await stop(tester);
    });

    testWidgets('Cancel saves nothing', (tester) async {
      final t = await pumpLocation(tester, list: Hub.addressListOff);
      await tapKey(tester, 'address-list');
      await tapKey(tester, 'address-list-google');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((t.hub.addressListAuth, t.hub.addressList?['google']), (null, false));
      expect(rowWords(tester), startsWith('Your own earlier deliveries are listed'));
      await stop(tester);
    });

    testWidgets('Try it asks that one service, before anything is turned on, and says what it has left', (
      tester,
    ) async {
      final t = await pumpLocation(tester, list: Hub.addressListOff);
      await tapKey(tester, 'address-list');
      await tapKey(tester, 'address-list-try:mapbox');
      expect(t.hub.addressTried, ['mapbox']);
      expect(said(tester, 'address-list-tried:mapbox'), 'Mapbox answered: it lists addresses for this hub.');
      // the try was counted: the line under it says what is left now
      expect(said(tester, 'address-list-state:mapbox'), 'Off · 9,411 of 95,000 free lookups left this month');
      expect(key('address-list-tried:google'), findsNothing);
      await tapKey(tester, 'address-list-try:google');
      expect(t.hub.addressTried, ['mapbox', 'google']);
      expect(said(tester, 'address-list-tried:google'), 'Google Maps answered: it lists addresses for this hub.');
      t.hub.addressTry = {'ok': true, 'found': 0, 'reason': null, 'message': '', 'left': 9410};
      await tapKey(tester, 'address-list-try:google');
      expect(said(tester, 'address-list-tried:google'), contains('listed nothing for the restaurant\'s own address'));
      t.hub.addressTry = {
        'ok': false,
        'found': 0,
        'reason': 'refused',
        'message':
            "Mapbox refused the hub's token. Copy it again from your Mapbox account; it must have no URL "
            'restriction.',
        'left': 94000,
      };
      await tapKey(tester, 'address-list-try:mapbox');
      expect(said(tester, 'address-list-tried:mapbox'), startsWith("Mapbox refused the hub's token."));
      final scheme = Theme.of(tester.element(key('address-list-tried:mapbox'))).colorScheme;
      expect(tester.widget<Text>(key('address-list-tried:mapbox')).style?.color, scheme.error);
      t.hub.down = true;
      await tapKey(tester, 'address-list-try:mapbox');
      expect(said(tester, 'address-list-tried:mapbox'), 'The hub is not answering.');
      t.hub.down = false;
      // trying turned nothing on and saved nothing
      expect((t.hub.addressTries, t.hub.addressListAuth, t.hub.addressList?['mapbox']), (4, null, false));
      await stop(tester);
    });

    testWidgets('a service used up for the month, or not answering, says so in red', (tester) async {
      await pumpLocation(
        tester,
        list: Hub.addressListOf([
          Hub.addressService('google', on: true, left: 0),
          Hub.addressService('mapbox', on: true, resting: true),
          Hub.addressService('azure', on: true, left: 47000),
        ]),
      );
      expect(
        rowWords(tester),
        'Your own earlier deliveries, then Google Maps, are listed while an address is typed. Mapbox and Azure '
        'Maps take over when it gives no list',
      );
      await tapKey(tester, 'address-list');
      final scheme = Theme.of(tester.element(key('address-list-state:google'))).colorScheme;
      expect(said(tester, 'address-list-state:google'), startsWith('Its free lookups for this month are used up'));
      expect(tester.widget<Text>(key('address-list-state:google')).style?.color, scheme.error);
      expect(said(tester, 'address-list-state:mapbox'), 'Not answering right now: the next one is asked meanwhile');
      expect(tester.widget<Text>(key('address-list-state:mapbox')).style?.color, scheme.error);
      expect(said(tester, 'address-list-state:azure'), '47,000 of 47,500 free lookups left this month');
      expect(tester.widget<Text>(key('address-list-state:azure')).style?.color, scheme.onSurfaceVariant);
      await stop(tester);
    });

    testWidgets('a service turned on with no key on this hub is kept for the day it has one', (tester) async {
      final t = await pumpLocation(tester, list: Hub.addressListOff);
      await tapKey(tester, 'address-list');
      await tapKey(tester, 'address-list-azure');
      await tapKey(tester, 'address-list-save');
      expect((t.hub.addressList?['azure'], t.hub.addressList?['google']), (true, false));
      expect(rowWords(tester), 'On, but not used yet: this hub has no key for Azure Maps');
      await stop(tester);
    });

    testWidgets('a hub from before there were several has the one Google switch', (tester) async {
      final t = await pumpLocation(tester, list: {...Hub.addressListOld, 'service': false});
      await tapKey(tester, 'address-list');
      expect(find.text('1. Google Maps'), findsOneWidget);
      expect(key('address-list-mapbox'), findsNothing);
      expect(said(tester, 'address-list-state:google'), 'No key on this hub yet (Keys and connections)');
      expect(key('address-list-try:google'), findsNothing);
      await tapKey(tester, 'address-list-google');
      await tapKey(tester, 'address-list-save');
      expect((t.hub.addressList?['google'], t.hub.addressList?['asks']), (true, false));
      expect(rowWords(tester), 'On, but not used yet: this hub has no Google Maps key');
      // with a key, it is tried as before: that hub tries Google whatever is named
      t.hub.addressList = {...Hub.addressListOld, 'google': true, 'asks': true};
      await stop(tester);
    });

    testWidgets('a hub older than the list says so, and the row opens nothing', (tester) async {
      await pumpLocation(tester);
      expect(rowWords(tester), 'The hub has not answered about the list of addresses (an older hub: update it)');
      expect(tester.widget<ListTile>(key('address-list')).onTap, isNull);
      await stop(tester);
    });

    testWidgets("the restaurant's own address lists the map service's answers alone", (tester) async {
      final t = await pumpLocation(
        tester,
        list: Hub.addressListOf([Hub.addressService('google', on: true)]),
        row: 'delivery-fee',
      );
      t.hub.addressLists = Hub.elmLists;
      await tapKey(tester, 'delivery-fee');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      await tester.ensureVisible(key('fee-origin'));
      await tester.pump(const Duration(seconds: 1));
      expect(t.hub.addressAsks, isEmpty); // the address it has is not asked about
      await type(tester, '12 el', box: 'fee-origin');
      expect(t.hub.addressAsks, [
        {'typed': '12 el', 'own': false},
      ]);
      expect(lines(tester), ['12 Elm Street  Medford, MA', '12 Elmwood Road  Winchester, MA']); // no customer's
      expect(said(tester, 'address-credit'), 'Google Maps');
      await tapKey(tester, 'address-suggestion:0');
      expect((typed(tester, 'fee-origin'), lines(tester).length), (elmMedford, 0));
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees?['origin'], elmMedford);
      await stop(tester);
    });

    testWidgets('on a small phone with large type the dialog is whole', (tester) async {
      await pumpLocation(tester, list: Hub.addressListOff, size: const Size(320, 640), type: 1.3);
      await tapKey(tester, 'address-list');
      await tapKey(tester, 'address-list-google');
      await tapKey(tester, 'address-list-try:mapbox');
      expect(said(tester, 'address-list-tried:mapbox'), startsWith('Mapbox answered'));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('address-list-azure'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'address-list-azure');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'address-list-save');
      expect(find.byType(AddressListDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
