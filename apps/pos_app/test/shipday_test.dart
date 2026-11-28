import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/hub_keys.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/hub_keys_screen.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/shipday_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/shipday.dart';
import 'package:pos_app/takeout.dart' show clockTime;
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';

/// Shipday in the app (docs/shipday.md): the hub reads the restaurant's deliveries and drivers there, and
/// the app shows them, each delivery beside the check it is on the POS. A delivery is given to a driver,
/// taken back and marked as it goes by a tap that says so, through the hub. Every Shipday here is the test
/// hub's own picture: nothing in these tests goes anywhere near Shipday.

int at(int hour, [int minute = 0]) => DateTime(2026, 11, 16, hour, minute).millisecondsSinceEpoch;

const shipdayKey = 'MadeUpKey0.NobodysShipdayKey123456';

final tom = Hub.shipdayDriver(501, 'Tom Reyes', orders: 2);
final wei = Hub.shipdayDriver(502, 'Wei Zhang');
final ana = Hub.shipdayDriver(503, 'Ana Silva', onShift: false);

/// An evening in Shipday: one delivery nobody has, one a driver was offered, one on its way with a time
/// of arrival, one nothing on the POS matches, and one delivered.
Map<String, dynamic> evening() => Hub.shipdayStands(
  eta: 'on',
  drivers: [tom, wei, ana],
  orders: [
    Hub.shipdayOrder(
      7001,
      '1270166229',
      placedMs: at(18),
      dueMs: at(18, 45),
      note: 'Side door',
      check: Hub.shipdayCheck('gf-1270166229', 12),
    ),
    Hub.shipdayOrder(
      7002,
      '1270166230',
      state: 'NOT_ACCEPTED',
      name: 'Raj Patel',
      address: '4 Oak Rd, Winchester, MA 01890',
      phone: '+17815550102',
      driver: tom,
      placedMs: at(18, 2),
      assignedMs: at(18, 6),
      total: '31.10',
      payment: 'CASH',
      check: Hub.shipdayCheck('o-7', 14, by: 'phone'),
    ),
    Hub.shipdayOrder(
      7003,
      '1270166231',
      state: 'PICKED_UP',
      name: 'Mei Lin',
      address: '9 Pine Ave, Winchester, MA 01890',
      phone: '+17815550103',
      driver: tom,
      placedMs: at(17, 40),
      assignedMs: at(17, 45),
      startedMs: at(17, 50),
      pickedUpMs: at(18, 10),
      etaMs: at(18, 24),
      check: Hub.shipdayCheck('gf-1270166231', 9, status: 'closed'),
    ),
    Hub.shipdayOrder(
      7004,
      'A-55',
      state: 'STARTED',
      name: '',
      address: '',
      phone: '',
      driver: {'id': 777, 'name': '', 'phone': ''},
      startedMs: at(18, 12),
      etaSaid: '12 min',
      total: null,
    ),
  ],
  done: [
    Hub.shipdayOrder(
      6990,
      '1270166200',
      state: 'ALREADY_DELIVERED',
      name: 'Sam Ortiz',
      driver: wei,
      deliveredMs: at(17, 55),
      endedMs: at(17, 56),
      check: Hub.shipdayCheck('gf-1270166200', 5, status: 'closed'),
    ),
  ],
);

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

String richOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).textSpan!.toPlainText();

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// The Shipday screen by itself, on a terminal whose hub answers [picture]. What it opens goes to [opened].
Future<Terminal> pumpShipday(
  WidgetTester tester, {
  Map<String, dynamic>? picture,
  bool older = false,
  Size size = const Size(390, 844),
  double textScale = 1,
  List<String>? opened,
  String? staffId,
}) async {
  final t = await terminal(tester);
  t.hub.shipday = older ? null : picture ?? evening();
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ShipdayScreen(api: t.api, onOpen: (orderId) async => opened?.add(orderId), staffId: staffId),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('what the hub says of Shipday, read', () {
    test('the deliveries by how far along they are, and the drivers by who can take the next one', () {
      final board = ShipdayBoard.fromJson(evening());
      expect((board.on, board.read, board.eta, board.trouble), (true, true, 'on', null));
      expect([for (final order in board.needDriver) order.id], [7001]);
      expect([for (final order in board.withDriver) order.id], [7002, 7004]);
      expect([for (final order in board.onTheWay) order.id], [7003]);
      expect(board.others, isEmpty);
      expect([for (final order in board.done) order.id], [6990]);
      // on shift, the one with nothing first; the one off shift apart
      expect([for (final driver in board.onShift) driver.called], ['Wei Zhang', 'Tom Reyes']);
      expect([for (final driver in board.offShift) driver.called], ['Ana Silva']);
      expect(board.note, '1 needs a driver');
    });

    test('a few words for the button: who needs a driver, else how many are out, else nothing', () {
      ShipdayBoard of(List<Map<String, dynamic>> orders) => ShipdayBoard.fromJson(Hub.shipdayStands(orders: orders));
      expect(of([Hub.shipdayOrder(1, 'a'), Hub.shipdayOrder(2, 'b')]).note, '2 need a driver');
      expect(of([Hub.shipdayOrder(1, 'a', state: 'PICKED_UP', driver: tom)]).note, '1 out');
      expect(of([]).note, isNull);
    });

    test('a delivery in words: who has it, what happened last, when it is there, and what is owed', () {
      final board = ShipdayBoard.fromJson(evening());
      final [waiting, offered, out, bare] = board.orders;
      expect(waiting.title, 'Linda Chen');
      expect(waiting.progress, 'No driver · placed ${clockTime(at(18))}');
      expect(waiting.expected, isNull);
      expect(waiting.facts, '781 555 0101 · \$42.75 card · wanted for ${clockTime(at(18, 45))}');
      expect(waiting.check!.words, 'Check #12');
      expect(offered.progress, 'Tom Reyes · offered ${clockTime(at(18, 6))}');
      expect(offered.facts, '781 555 0102 · \$31.10 cash');
      expect(offered.check!.by, 'phone');
      expect(out.progress, 'Tom Reyes · picked up ${clockTime(at(18, 10))}');
      expect(out.expected, 'there about ${clockTime(at(18, 24))}');
      expect(out.check!.words, 'Check #9 · closed');
      // a delivery with next to nothing on it: Shipday's number for a name, its driver by number
      expect(bare.title, 'Order A-55');
      expect(bare.progress, 'Driver 777 · started ${clockTime(at(18, 12))}');
      expect(bare.expected, 'Shipday says 12 min');
      expect(bare.facts, '');
      expect(bare.check, isNull);
      expect(board.done.single.progress, 'Wei Zhang · delivered ${clockTime(at(17, 55))}');
      expect(board.done.single.finished, isTrue);
      expect(out.finished, isFalse);
      // what Shipday gives no time for is told by when the hub saw it gone
      ShipdayOrder ended(String state) =>
          ShipdayOrder.fromJson(Hub.shipdayOrder(1, 'a', state: state, driver: tom, endedMs: at(17, 30)))!;
      expect(ended('FAILED_DELIVERY').progress, 'Tom Reyes · failed about ${clockTime(at(17, 30))}');
      expect(ended('INCOMPLETE').progress, 'Tom Reyes · ended about ${clockTime(at(17, 30))}');
      expect(ended('GONE').progress, 'Tom Reyes · off the list about ${clockTime(at(17, 30))}');
    });

    test('where it stands is said in Shipday\'s own words, and a word nobody knows says so', () {
      expect(shipdayStateWords('NOT_ASSIGNED'), 'No driver yet');
      expect(shipdayStateWords('READY_TO_DELIVER'), 'Ready to deliver');
      expect(shipdayStateWords('ALREADY_DELIVERED'), 'Delivered');
      expect(shipdayStateWords('GONE'), 'No longer listed');
      expect(shipdayStateWords('UNKNOWN'), 'Shipday does not say');
      expect(shipdayStateWords('SOMETHING_NEW'), 'Shipday does not say');
      final odd = ShipdayBoard.fromJson(
        Hub.shipdayStands(
          orders: [Hub.shipdayOrder(1, 'a', state: 'UNKNOWN', check: Hub.shipdayCheck('o-1', null))],
        ),
      );
      expect([for (final order in odd.others) order.id], [1]);
      expect(odd.orders.single.check!.words, 'Its check');
      expect(Hub.shipdayCheck('o-1', 3, status: 'void'), containsPair('status', 'void'));
      expect(ShipdayCheck.fromJson(Hub.shipdayCheck('o-1', 3, status: 'void'))!.words, 'Check #3 · voided');
    });

    test('what is no delivery and no driver is left out, and an empty answer is a hub without a key', () {
      final board = ShipdayBoard.fromJson({
        'on': true,
        'read': true,
        'orders': [
          {'number': 'no id'},
          'junk',
          Hub.shipdayOrder(1, 'a'),
        ],
        'done': 'nothing',
        'drivers': [
          {'name': 'no id'},
          tom,
        ],
      });
      expect([for (final order in board.orders) order.id], [1]);
      expect(board.done, isEmpty);
      expect([for (final driver in board.drivers) driver.id], [501]);
      final none = ShipdayBoard.fromJson(const {});
      expect((none.on, none.read, none.note), (false, false, null));
      expect(none.orders, isEmpty);
    });

    test('why Shipday did not answer, for a person', () {
      expect(shipdayTroubleWords('refused', ''), startsWith('Shipday refused the key.'));
      expect(shipdayTroubleWords('limit', ''), contains('asked too often'));
      expect(shipdayTroubleWords('unreachable', ''), contains('no way out to the internet'));
      expect(shipdayTroubleWords('error', 'it answered 500'), 'Shipday did not answer: it answered 500.');
      expect(shipdayTroubleWords('error', ''), 'Shipday did not answer.');
    });

    test('how the asking goes, for the page of the keys, and what a try came to', () {
      final about = ShipdayAbout.fromJson({
        'on': true,
        'running': true,
        'answered_ms': at(18, 30),
        'trouble': null,
        'eta': 'plan',
        'orders': 3,
        'drivers': 4,
        'on_shift': 2,
      });
      expect(
        about.words,
        'Shipday last answered at ${clockTime(at(18, 30))}: 3 deliveries out, 4 drivers, 2 on shift.',
      );
      expect(about.planWords, contains('how far away a delivery is'));
      expect(ShipdayAbout.fromJson(const {'on': true}).words, isNull, reason: 'not asked yet');
      expect(ShipdayAbout.fromJson(const {'on': true, 'eta': 'on'}).planWords, isNull);
      expect(ShipdayAbout.listed(1, 1, 0), '1 delivery out, 1 driver, 0 on shift');
      expect(ShipdayAbout.listed(0, 0, 0), 'no delivery out, no driver');
      final worked = ShipdayTried.fromJson(const {'ok': true, 'orders': 2, 'drivers': 3, 'on_shift': 1});
      expect(
        worked.words,
        'Shipday answered: the key works. It lists 2 deliveries out, 3 drivers, 1 on shift. Nothing was changed in '
        'Shipday.',
      );
      expect(worked.bad, isFalse);
      final refused = ShipdayTried.fromJson(const {'ok': false, 'reason': 'refused', 'said': 'refused the key'});
      expect(refused.bad, isTrue);
      expect(refused.words, startsWith('Shipday refused the key.'));
    });
  });

  group('the key, under Keys and connections', () {
    Future<Terminal> pumpKeys(WidgetTester tester, {void Function(Hub hub)? hub, List<HubKeys>? told}) async {
      final t = await terminal(tester);
      hub?.call(t.hub);
      tester.view.physicalSize = const Size(700, 2600);
      await tester.pumpWidget(
        MaterialApp(
          home: HubKeysScreen(
            api: t.api,
            token: 'tok-admin',
            keys: HubKeys.fromJson(t.hub.hubKeysSaid()),
            onChanged: told?.add,
            clock: () => DateTime.fromMillisecondsSinceEpoch(t.hub.keysAtMs),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('it is typed like any key, and from then on the hub reads Shipday', (tester) async {
      final told = <HubKeys>[];
      final t = await pumpKeys(tester, told: told);
      expect(find.text('Shipday (deliveries)'), findsOneWidget);
      expect(textOf(tester, 'key-shipday-state'), 'Not set');
      expect(find.textContaining('there is no Shipday screen'), findsOneWidget);
      expect(find.byKey(const ValueKey('key-shipday-try')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-state')), findsNothing);

      await tapKey(tester, 'key-shipday-type');
      expect(find.textContaining('under My Account'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('key-field')), shipdayKey);
      await tapKey(tester, 'key-save');
      expect(t.hub.keysTyped.single.$1, 'shipday');
      expect(t.hub.keysTyped.single.$2, {'key': shipdayKey});
      expect(textOf(tester, 'key-shipday-state'), 'Set · ends in 3456 · typed here by Mike, today');
      expect(
        textOf(tester, 'key-shipday-said'),
        'Saved. The hub reads Shipday with it from now on. Press Try it to see that it works.',
      );
      expect(find.textContaining(shipdayKey), findsNothing);
      expect(told.last.shipday!.on, isTrue);
      // not asked yet: nothing is said of how it goes
      expect(find.byKey(const ValueKey('shipday-state')), findsNothing);
    });

    testWidgets('Try it asks Shipday once and says what it listed', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          hub.hubKeys!['shipday'] = Hub.hubKey('shipday', ending: '3456');
          hub.shipday = evening();
          hub.shipdayTried = {'ok': true, 'reason': null, 'said': '', 'orders': 4, 'drivers': 3, 'on_shift': 2};
        },
      );
      expect(
        textOf(tester, 'shipday-state'),
        'Shipday last answered at ${clockTime(t.hub.shipdayAnsweredMs)}: 4 deliveries out, 3 drivers, 2 on shift.',
      );
      expect(find.byKey(const ValueKey('shipday-plan')), findsNothing);
      await tapKey(tester, 'key-shipday-try');
      expect(t.hub.shipdayTries, 1);
      expect(
        textOf(tester, 'key-shipday-said'),
        'Shipday answered: the key works. It lists 4 deliveries out, 3 drivers, 2 on shift. Nothing was changed in '
        'Shipday.',
      );
    });

    testWidgets('a key Shipday refuses says so in the card and under the try, and a plan without times says that', (
      tester,
    ) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          hub.hubKeys!['shipday'] = Hub.hubKey('shipday', ending: '3456');
          hub.shipday = Hub.shipdayStands(
            read: false,
            eta: 'plan',
            trouble: {'since_ms': at(18, 20), 'reason': 'refused', 'said': 'Shipday refused the key'},
          );
          hub.shipdayTried = {
            'ok': false,
            'reason': 'refused',
            'said': 'Shipday refused the key',
            'orders': null,
            'drivers': null,
            'on_shift': null,
          };
        },
      );
      expect(textOf(tester, 'shipday-state'), startsWith('Shipday refused the key.'));
      final state = tester.widget<Text>(find.byKey(const ValueKey('shipday-state')));
      expect(state.style!.color, Theme.of(tester.element(find.byType(HubKeysScreen))).colorScheme.error);
      expect(textOf(tester, 'shipday-plan'), contains("Shipday's higher plans"));
      await tapKey(tester, 'key-shipday-try');
      expect(t.hub.shipdayTries, 1);
      expect(textOf(tester, 'key-shipday-said'), startsWith('Shipday refused the key.'));
    });

    testWidgets('removing it stops the asking, and a hub from before Shipday has no such card', (tester) async {
      final t = await pumpKeys(
        tester,
        hub: (hub) {
          hub.hubKeys!['shipday'] = Hub.hubKey('shipday', ending: '3456');
          hub.shipday = evening();
        },
      );
      await tapKey(tester, 'key-shipday-remove');
      expect(find.textContaining('the Shipday screen goes away'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(t.hub.keysRemoved, ['shipday']);
      expect(textOf(tester, 'key-shipday-state'), 'Not set · removed here by Mike, today');
      expect(find.byKey(const ValueKey('shipday-state')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pumpKeys(tester, hub: (hub) => hub.shipday = null);
      expect(find.byKey(const ValueKey('key-shipday')), findsNothing);
      expect(find.byKey(const ValueKey('key-texts')), findsOneWidget);
    });
  });

  group('the Shipday screen', () {
    // a phone's width, and tall enough that the whole list is laid out at once
    const tall = Size(390, 2600);

    testWidgets('on a phone: the drivers, then the deliveries by how far along they are', (tester) async {
      final t = await pumpShipday(tester, size: tall);
      expect(t.hub.shipdayLooks, greaterThan(0), reason: 'the hub is told somebody is looking');
      expect(find.text('Drivers on shift · 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-driver-502')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('shipday-driver-502')), matching: find.text('free')),
        findsOne,
      );
      expect(find.descendant(of: find.byKey(const ValueKey('shipday-driver-501')), matching: find.text('2')), findsOne);
      expect(textOf(tester, 'shipday-off-shift'), 'Off shift: Ana Silva');
      expect(find.text('Need a driver · 1'), findsOneWidget);
      expect(find.text('With a driver · 2'), findsOneWidget);
      expect(find.text('On the way · 1'), findsOneWidget);
      expect(find.text('Other · 0'), findsNothing);

      // the first card whole
      final first = find.byKey(const ValueKey('shipday-order-7001'));
      expect(find.descendant(of: first, matching: find.text('Linda Chen')), findsOne);
      expect(find.descendant(of: first, matching: find.text('No driver yet')), findsOne);
      expect(find.descendant(of: first, matching: find.text('12 Elm St, Winchester, MA 01890')), findsOne);
      expect(richOf(tester, 'shipday-progress-7001'), 'No driver · placed ${clockTime(at(18))}');
      expect(find.descendant(of: first, matching: find.text('Side door')), findsOne);
      expect(find.descendant(of: first, matching: find.text('Check #12')), findsOne);
      expect(find.descendant(of: first, matching: find.text('Shipday no. 1270166229')), findsOne);

      // one matched by the customer's number says so; one on its way says when it is there
      await tester.ensureVisible(find.byKey(const ValueKey('shipday-order-7003')));
      expect(find.text('Shipday no. 1270166230 · matched by phone number'), findsOneWidget);
      expect(
        richOf(tester, 'shipday-progress-7003'),
        'Tom Reyes · picked up ${clockTime(at(18, 10))} · there about ${clockTime(at(18, 24))}',
      );
      // one the hub finds no check for says so, and has nothing to open
      expect(find.byKey(const ValueKey('shipday-nocheck-7004')), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-check-7004')), findsNothing);
      expect(find.text('No address was given'), findsOneWidget);

      // what is still done in Shipday's own app, said under the lists
      expect(textOf(tester, 'shipday-foot'), startsWith('A delivery is given to a driver and marked as it goes'));
      expect(textOf(tester, 'shipday-foot'), isNot(contains('higher plans')));
      // with nobody signed in nothing is offered
      expect(find.byKey(const ValueKey('shipday-give-7001')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsNothing);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a tap on the check opens it, and what finished today is under a fold', (tester) async {
      final opened = <String>[];
      final t = await pumpShipday(tester, opened: opened, size: tall);
      await tapKey(tester, 'shipday-check-7001');
      expect(opened, ['gf-1270166229']);
      // back from the check, the picture is read again
      final asks = t.hub.shipdayAsks;
      await tester.pump(const Duration(seconds: 3));
      expect(t.hub.shipdayAsks, greaterThan(asks));

      expect(find.text('Finished today · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-order-6990')), findsNothing);
      await tapKey(tester, 'shipday-done');
      final done = find.byKey(const ValueKey('shipday-order-6990'));
      expect(find.descendant(of: done, matching: find.text('Delivered')), findsOne);
      // of one that finished, who had it and how it ended: not the number to call or what is owed
      expect(find.descendant(of: done, matching: find.textContaining('781 555')), findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('shipday-order-7001')), matching: find.textContaining('781 555')),
        findsOne,
      );
      expect(richOf(tester, 'shipday-progress-6990'), 'Wei Zhang · delivered ${clockTime(at(17, 55))}');
      await tapKey(tester, 'shipday-check-6990');
      expect(opened.last, 'gf-1270166200');
      await tapKey(tester, 'shipday-done');
      expect(find.byKey(const ValueKey('shipday-order-6990')), findsNothing);
      await stop(tester);
    });

    testWidgets('Ask now asks Shipday out of turn and says what came of it', (tester) async {
      final t = await pumpShipday(tester, size: tall);
      t.hub.shipdayOnAsk = () => t.hub.shipday = Hub.shipdayStands(drivers: [tom]);
      await tester.tap(find.byKey(const ValueKey('shipday-ask')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayAskCount, 1);
      expect(textOf(tester, 'shipday-said-words'), 'Shipday answered. This is how it stands now.');
      expect(find.text('Need a driver · 0'), findsOneWidget);
      expect(find.text('Every delivery has a driver.'), findsOneWidget);
      expect(find.text('Nothing is on its way.'), findsOneWidget);
      expect(find.text('Nothing has finished yet.'), findsOneWidget);

      // asked a moment ago: said so, and nothing is wrong
      t.hub.shipdayAsked = {'asked': false, 'answered': false, 'soon': true, 'reason': null, 'said': ''};
      await tester.tap(find.byKey(const ValueKey('shipday-ask')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'shipday-said-words'), 'Shipday was asked a moment ago. This is what it said.');

      // Shipday did not answer: why, in words
      t.hub.shipdayAsked = {'asked': true, 'answered': false, 'soon': false, 'reason': 'unreachable', 'said': 'x'};
      await tester.tap(find.byKey(const ValueKey('shipday-ask')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'shipday-said-words'), contains('no way out to the internet'));
      await stop(tester);
    });

    testWidgets('while Shipday does not answer the screen says why and keeps what it last heard', (tester) async {
      final picture = evening()
        ..['trouble'] = {'since_ms': at(18, 20), 'reason': 'unreachable', 'said': 'no answer'}
        ..['eta'] = 'plan';
      await pumpShipday(tester, picture: picture, size: tall);
      final banner = find.byKey(const ValueKey('shipday-trouble'));
      expect(
        tester.widget<Text>(find.descendant(of: banner, matching: find.byType(Text))).data,
        'Shipday is not answering. The hub may have no way out to the internet right now. What is listed here is '
        'what it said before ${clockTime(at(18, 20))}.',
      );
      expect(find.text('Need a driver · 1'), findsOneWidget);
      expect(textOf(tester, 'shipday-foot'), contains("part of Shipday's higher plans"));
      await stop(tester);
    });

    testWidgets('a key Shipday never answered with, no key, an older hub and no hub each say what is the matter', (
      tester,
    ) async {
      await pumpShipday(
        tester,
        picture: Hub.shipdayStands(read: false, trouble: {'since_ms': at(18), 'reason': 'refused', 'said': ''}),
      );
      expect(find.byKey(const ValueKey('shipday-trouble')), findsOneWidget);
      expect(find.text('Shipday has not answered yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-ask')), findsOneWidget);
      await stop(tester);

      await pumpShipday(tester, picture: Hub.shipdayStands(read: false));
      expect(find.text('Asking Shipday…'), findsOneWidget);
      await stop(tester);

      await pumpShipday(tester, picture: Hub.shipdayStands(on: false));
      expect(
        find.text('This hub has no key for Shipday. A manager types it under Location, Keys and connections.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shipday-ask')), findsNothing);
      await stop(tester);

      await pumpShipday(tester, older: true);
      expect(find.textContaining('older than reading Shipday'), findsOneWidget);
      await stop(tester);

      final t = await terminal(tester);
      t.hub.shipdayDown = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ShipdayScreen(api: t.api, onOpen: (_) async {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The hub is not answering.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub that stops answering leaves the picture up and says it may be behind', (tester) async {
      final t = await pumpShipday(tester);
      expect(find.byKey(const ValueKey('shipday-away')), findsNothing);
      t.hub.shipdayDown = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byKey(const ValueKey('shipday-away')), findsOneWidget);
      expect(find.text('Need a driver · 1'), findsOneWidget);
      t.hub.shipdayDown = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byKey(const ValueKey('shipday-away')), findsNothing);
      await stop(tester);
    });

    testWidgets('it fits the narrowest phone with large type, and a tablet gets two lists side by side', (
      tester,
    ) async {
      await pumpShipday(tester, size: const Size(320, 640), textScale: 1.6);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('shipday-list')), findsOneWidget);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-foot')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
      await stop(tester);

      await pumpShipday(tester, size: const Size(1100, 800));
      expect(find.byKey(const ValueKey('shipday-list')), findsNothing);
      final left = tester.getRect(find.byKey(const ValueKey('shipday-left')));
      final right = tester.getRect(find.byKey(const ValueKey('shipday-right')));
      expect(left.right, lessThanOrEqualTo(right.left));
      // what waits for a driver beside the drivers; what the drivers have on the other side
      for (final (side, title) in [
        ('shipday-left', 'Drivers on shift · 2'),
        ('shipday-left', 'Need a driver · 1'),
        ('shipday-right', 'With a driver · 2'),
        ('shipday-right', 'On the way · 1'),
        ('shipday-right', 'Finished today · 1'),
      ]) {
        expect(
          find.descendant(of: find.byKey(ValueKey(side)), matching: find.text(title)),
          findsOne,
          reason: title,
        );
      }
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('nothing is drawn again while the hub says the same', (tester) async {
      final t = await pumpShipday(tester);
      final asks = t.hub.shipdayAsks;
      final drawn = tester.state(find.byType(ShipdayScreen));
      var builds = 0;
      // a rebuild of the screen marks its element dirty: counted by asking after each pump
      for (var n = 0; n < 5; n++) {
        await tester.pump(const Duration(seconds: 2));
        if (tester.element(find.byType(ShipdayScreen)).dirty) builds += 1;
      }
      expect(t.hub.shipdayAsks, greaterThan(asks), reason: 'with no feed the screen asks by itself');
      expect(builds, 0);
      expect(tester.state(find.byType(ShipdayScreen)), same(drawn));
      await stop(tester);
    });
  });

  group('a delivery is given to a driver, and taken back', () {
    const tall = Size(390, 2600);

    String said(WidgetTester tester) => textOf(tester, 'shipday-said-words');

    test('what came of a change, in words', () {
      final board = ShipdayBoard.fromJson(evening());
      expect(board.givesToDrivers, isTrue);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(can: null)).givesToDrivers, isFalse);
      expect(ShipdayBoard.fromJson({...evening(), 'can': 'driver'}).givesToDrivers, isFalse);
      expect([for (final order in board.orders) order.canBeGiven], [true, false, false, false]);
      expect([for (final order in board.orders) order.canBeTakenBack], [false, true, false, true]);
      expect(board.done.single.canBeGiven || board.done.single.canBeTakenBack, isFalse);

      String words(Map<String, dynamic> answer, {ShipdayOrder? order}) =>
          ShipdayChanged.fromJson(answer).words('Given to Wei Zhang.', order: order);
      final withTom = board.orders[1];
      expect(words({'done': true, 'sent': true, 'shown': true}), 'Given to Wei Zhang.');
      expect(words({'done': true, 'sent': true}), 'Shipday took it. Its list does not show it yet.');
      expect(words({'reason': 'not_listed'}), "It is no longer on Shipday's list. Nothing was changed.");
      expect(words({'reason': 'has_driver'}), 'It has a driver already. Nothing was changed.');
      expect(words({'reason': 'has_driver'}, order: withTom), 'Tom Reyes has it already. Nothing was changed.');
      expect(words({'reason': 'other_driver'}, order: withTom), 'Tom Reyes has it now. Nothing was changed.');
      expect(words({'reason': 'no_driver'}), 'Nobody has it any more. Nothing was changed.');
      expect(words({'reason': 'on_its_way'}), 'It was picked up already. Nothing was changed.');
      expect(words({'reason': 'unknown_driver'}), 'Shipday no longer lists that driver. Nothing was changed.');
      expect(words({'reason': 'unsure'}), endsWith('this app does not know. Nothing was changed.'));
      expect(words({'reason': 'unreachable'}), endsWith('no way out to the internet right now. Nothing was changed.'));
      expect(words({'reason': 'refused'}), allOf(startsWith('Shipday refused the key.'), endsWith('changed.')));
      // asked, and it would not: its own words where it gave any
      expect(words({'sent': true, 'reason': 'rejected'}), 'Shipday would not do it.');
      expect(
        words({'sent': true, 'reason': 'rejected', 'told': ' Carrier is off shift. '}),
        'Shipday would not do it: "Carrier is off shift."',
      );
      expect(words({'sent': true, 'reason': 'not_found'}), 'Shipday would not do it.');
      // asked, no answer, and the list does not show it
      expect(
        words({'sent': true, 'reason': 'slow'}),
        "Shipday is taking too long to answer. Shipday's list does not show the change.",
      );
      expect(ShipdayChanged.fromJson({'done': true}).bad, isFalse);
      expect(ShipdayChanged.fromJson({'sent': true, 'reason': 'slow'}).bad, isTrue);
    });

    testWidgets('one nobody has is given to the driver tapped, the free one offered first', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      expect(find.byKey(const ValueKey('shipday-give-7001')), findsOneWidget);
      // only what nobody has can be given, and only what was not picked up can be taken back
      for (final id in [7002, 7003, 7004]) {
        expect(find.byKey(ValueKey('shipday-give-$id')), findsNothing);
      }
      expect(find.byKey(const ValueKey('shipday-take-7001')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-take-7003')), findsNothing, reason: 'it is on its way');
      expect(find.byKey(const ValueKey('shipday-take-7004')), findsOneWidget);

      await tapKey(tester, 'shipday-give-7001');
      expect(find.byKey(const ValueKey('shipday-picker')), findsOneWidget);
      expect(find.text('Who takes it?'), findsOneWidget);
      expect(textOf(tester, 'shipday-picker-order'), 'Linda Chen · 12 Elm St, Winchester, MA 01890');
      final wei = find.byKey(const ValueKey('shipday-pick-502'));
      final tom = find.byKey(const ValueKey('shipday-pick-501'));
      expect(find.descendant(of: wei, matching: find.text('free')), findsOne);
      expect(find.descendant(of: tom, matching: find.text('2 out')), findsOne);
      // who has the least comes first: beside the other where there is the width, above it on a phone
      final (first, second) = (tester.getTopLeft(wei), tester.getTopLeft(tom));
      expect(first.dy < second.dy || (first.dy == second.dy && first.dx < second.dx), isTrue);
      expect(find.byKey(const ValueKey('shipday-pick-503')), findsNothing, reason: 'Ana is off shift');
      expect(
        textOf(tester, 'shipday-picker-hint'),
        'A tap gives it to that driver, and Shipday tells them. Off shift: Ana Silva.',
      );
      expect(t.hub.shipdayChanges, isEmpty, reason: 'opening the list asks for nothing');

      await tester.tap(wei);
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['give 7001 502 s3']);
      expect(find.byKey(const ValueKey('shipday-picker')), findsNothing);
      expect(said(tester), 'Given to Wei Zhang.');
      // the picture the hub answered with is on the screen at once
      expect(find.text('Need a driver · 0'), findsOneWidget);
      expect(find.text('With a driver · 3'), findsOneWidget);
      final card = find.byKey(const ValueKey('shipday-order-7001'));
      expect(find.descendant(of: card, matching: find.text('Not accepted yet')), findsOne);
      expect(find.byKey(const ValueKey('shipday-take-7001')), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-give-7001')), findsNothing);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('closing the list of drivers gives it to nobody', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      await tapKey(tester, 'shipday-give-7001');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'shipday-give-7001');
      await tester.tapAt(const Offset(5, 5)); // beside the list
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shipday-picker')), findsNothing);
      expect(t.hub.shipdayChanges, isEmpty);
      expect(find.text('Need a driver · 1'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('with no driver on shift the list says so and offers nobody', (tester) async {
      final picture = evening()..['drivers'] = [Hub.shipdayDriver(501, 'Tom Reyes', onShift: false), ana];
      final t = await pumpShipday(tester, picture: picture, size: tall, staffId: 's3');
      await tapKey(tester, 'shipday-give-7001');
      expect(textOf(tester, 'shipday-picker-none'), startsWith('No driver is on shift in Shipday.'));
      expect(textOf(tester, 'shipday-picker-hint'), 'Off shift: Tom Reyes, Ana Silva.');
      expect(find.byKey(const ValueKey('shipday-pick-501')), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, isEmpty);
      await stop(tester);
    });

    testWidgets('one a driver has not picked up is taken back, after a tap that says so', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      await tapKey(tester, 'shipday-take-7002');
      expect(find.text('Take it back from Tom Reyes?'), findsOneWidget);
      expect(
        textOf(tester, 'shipday-back-words'),
        "Raj Patel's delivery goes back to Need a driver. Shipday tells Tom Reyes.",
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, isEmpty);

      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['back 7002 501 s3']);
      expect(said(tester), 'Taken back from Tom Reyes. Nobody has it now.');
      expect(find.text('Need a driver · 2'), findsOneWidget);
      expect(find.text('With a driver · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-give-7002')), findsOneWidget);
      // Tom has one fewer
      expect(find.descendant(of: find.byKey(const ValueKey('shipday-driver-501')), matching: find.text('1')), findsOne);
      await stop(tester);
    });

    testWidgets('while the hub asks Shipday the card says so and takes no second tap', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      t.hub.shipdayChangeHeld = Completer<void>();
      await tapKey(tester, 'shipday-give-7001');
      await tester.tap(find.byKey(const ValueKey('shipday-pick-502')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('shipday-busy-7001')), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-give-7001')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsOneWidget, reason: 'the others are as they were');
      t.hub.shipdayChangeHeld!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shipday-busy-7001')), findsNothing);
      expect(t.hub.shipdayChanges, ['give 7001 502 s3']);
      expect(said(tester), 'Given to Wei Zhang.');
      await stop(tester);
    });

    testWidgets('what the hub or Shipday would not do is said, with the list as it now stands', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      // somebody gave it to Tom in Shipday's own app a moment ago: the hub looked first and sent nothing
      t.hub.shipdayOnChange = () {
        final orders = [...(t.hub.shipday!['orders'] as List).cast<Map<String, dynamic>>()];
        orders[0] = {...orders[0], 'state': 'NOT_ACCEPTED', 'driver': tom};
        t.hub.shipday = {...t.hub.shipday!, 'orders': orders};
      };
      t.hub.shipdayChangeSays = {'reason': 'has_driver'};
      await tapKey(tester, 'shipday-give-7001');
      await tester.tap(find.byKey(const ValueKey('shipday-pick-502')));
      await tester.pumpAndSettle();
      expect(said(tester), 'Tom Reyes has it already. Nothing was changed.');
      expect(find.text('Need a driver · 0'), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-take-7001')), findsOneWidget);

      // Shipday itself would not: its own words
      t.hub.shipdayOnChange = null;
      t.hub.shipdayChangeSays = {
        'sent': true,
        'reason': 'rejected',
        'said': 'Shipday would not do it (400)',
        'told': 'Order already accepted.',
      };
      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pumpAndSettle();
      expect(said(tester), 'Shipday would not do it: "Order already accepted."');
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsOneWidget, reason: 'Tom still has it');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a hub that does not answer, or cannot do it, is said plainly', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      t.hub.shipdayChangeStatus = 409;
      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pumpAndSettle();
      expect(said(tester), 'This hub has no key for Shipday. Nothing was changed.');

      t.hub.shipdayChangeStatus = 422;
      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pumpAndSettle();
      expect(said(tester), startsWith('Nothing was changed: '));

      // somebody the hub does not know
      t.hub
        ..shipdayChangeStatus = null
        ..roster = [];
      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pumpAndSettle();
      expect(said(tester), 'The hub does not know who is signed in. Nothing was changed.');
      expect(t.hub.shipdayChanges.length, 2, reason: 'the last one was refused before anything was asked');

      // a hub that breaks on it, or no answer at all: it may or may not have been done, and the screen does
      // not pretend to know
      t.hub
        ..roster = [
          {'staff_id': 's3', 'name': 'Mike', 'role': 'manager'},
        ]
        ..shipdayChangeStatus = 500;
      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pumpAndSettle();
      expect(said(tester), 'The hub did not answer. Look at the list before trying again: it may have been done.');
      t.hub.shipdayDown = true;
      await tapKey(tester, 'shipday-take-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-back-yes')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 70));
      await tester.pump();
      expect(said(tester), 'The hub did not answer. Look at the list before trying again: it may have been done.');
      t.api.dispose();
      await tester.pump();
    });

    testWidgets('a hub that only reads Shipday offers nothing, and says where it is done', (tester) async {
      final picture = evening()..remove('can');
      final t = await pumpShipday(tester, picture: picture, size: tall, staffId: 's3');
      expect(find.byKey(const ValueKey('shipday-give-7001')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsNothing);
      expect(textOf(tester, 'shipday-foot'), startsWith('This screen only reads Shipday.'));
      expect(t.hub.shipdayChanges, isEmpty);
      await stop(tester);
    });

    testWidgets('the buttons and the list of drivers fit the narrowest phone with large type', (tester) async {
      await pumpShipday(tester, size: const Size(320, 640), textScale: 1.6, staffId: 's3');
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-foot')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-give-7001')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, 300),
      );
      await tapKey(tester, 'shipday-give-7001');
      expect(find.byKey(const ValueKey('shipday-pick-502')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-take-7002')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, -200),
      );
      await tapKey(tester, 'shipday-take-7002');
      expect(find.byKey(const ValueKey('shipday-back-yes')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('a delivery is marked as it goes', () {
    const tall = Size(390, 2600);
    const ends = ['ALREADY_DELIVERED', 'FAILED_DELIVERY', 'INCOMPLETE'];

    String said(WidgetTester tester) => textOf(tester, 'shipday-said-words');

    /// The steps the open list offers, in the order of Shipday's own.
    List<String> offered(WidgetTester tester) => [
      for (final step in shipdaySteps)
        if (find.byKey(ValueKey('shipday-step-$step')).evaluate().isNotEmpty) step,
    ];

    test('what a delivery can be marked as is what the hub says, and what came of a mark is said in words', () {
      final board = ShipdayBoard.fromJson(evening());
      expect(board.marks, isTrue);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(can: ['driver'])).marks, isFalse);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(can: null)).marks, isFalse);
      expect(
        [for (final order in board.orders) order.steps],
        [
          ['FAILED_DELIVERY', 'INCOMPLETE'],
          ['STARTED', 'PICKED_UP', ...ends],
          ['READY_TO_DELIVER', ...ends],
          ['PICKED_UP', ...ends],
        ],
      );
      expect([for (final order in board.orders) order.canBeMarked], everyElement(isTrue));
      expect(board.done.single.canBeMarked, isFalse);
      // a hub from before marking says nothing of steps, and a word this build has no button for is left out
      final bare = Hub.shipdayOrder(1, 'A-1', state: 'STARTED', driver: tom)..remove('steps');
      expect(ShipdayOrder.fromJson(bare)!.canBeMarked, isFalse);
      final newer = Hub.shipdayOrder(1, 'A-1', state: 'STARTED', driver: tom)
        ..['steps'] = ['PICKED_UP', 'TELEPORTED', 7];
      expect(ShipdayOrder.fromJson(newer)!.steps, ['PICKED_UP']);

      expect(
        [for (final step in shipdaySteps) shipdayMarkedWords(step)],
        [
          'Marked started.',
          'Marked picked up.',
          'Marked ready to deliver.',
          'Marked delivered.',
          'Marked failed.',
          'Marked incomplete.',
        ],
      );
      String words(Map<String, dynamic> answer, {ShipdayOrder? order}) =>
          ShipdayChanged.fromJson(answer).words('Marked picked up.', order: order);
      expect(words({'done': true, 'sent': true, 'shown': true}), 'Marked picked up.');
      expect(words({'done': true, 'sent': true}), 'Shipday took it. Its list does not show it yet.');
      expect(
        words({'reason': 'moved'}, order: board.orders[2]),
        'Shipday has it as "Picked up" by now. Nothing was changed.',
      );
      expect(words({'reason': 'moved'}), 'It stands elsewhere in Shipday by now. Nothing was changed.');
      expect(words({'reason': 'not_a_step'}), 'It cannot be marked as that from where it stands. Nothing was changed.');
      expect(words({'reason': 'not_listed'}), "It is no longer on Shipday's list. Nothing was changed.");
    });

    testWidgets('one a driver has is marked as the step tapped, and stands there at once', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      for (final id in [7001, 7002, 7003, 7004]) {
        expect(find.byKey(ValueKey('shipday-mark-$id')), findsOneWidget);
      }
      await tapKey(tester, 'shipday-done');
      expect(find.byKey(const ValueKey('shipday-order-6990')), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-mark-6990')), findsNothing, reason: 'it is finished');

      await tapKey(tester, 'shipday-mark-7002');
      expect(find.byKey(const ValueKey('shipday-steps')), findsOneWidget);
      expect(find.text('Mark it as…'), findsOneWidget);
      expect(textOf(tester, 'shipday-steps-order'), 'Raj Patel · Tom Reyes has it · now: not accepted yet');
      expect(offered(tester), ['STARTED', 'PICKED_UP', ...ends]);
      // in Shipday's own words, the ones that say it will not be delivered apart and under the others
      final steps = find.byKey(const ValueKey('shipday-steps'));
      for (final words in ['Started', 'Picked up', 'Delivered', 'Failed', 'Incomplete']) {
        expect(find.descendant(of: steps, matching: find.text(words)), findsOne);
      }
      expect(find.text('It will not be delivered:'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('shipday-step-FAILED_DELIVERY'))).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const ValueKey('shipday-step-ALREADY_DELIVERED'))).dy),
      );
      expect(
        textOf(tester, 'shipday-steps-hint'),
        "A tap marks it in Shipday at once, as the driver's app does. Delivered, Failed, Incomplete end the "
        'delivery and ask first.',
      );
      expect(t.hub.shipdayChanges, isEmpty, reason: 'opening the list asks for nothing');

      await tester.tap(find.byKey(const ValueKey('shipday-step-PICKED_UP')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['mark 7002 PICKED_UP s3 was NOT_ACCEPTED']);
      expect(find.byKey(const ValueKey('shipday-steps')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-end')), findsNothing, reason: 'it goes on: nothing to ask');
      expect(said(tester), 'Marked picked up.');
      // the picture the hub answered with is on the screen at once
      expect(find.text('With a driver · 1'), findsOneWidget);
      expect(find.text('On the way · 2'), findsOneWidget);
      final card = find.byKey(const ValueKey('shipday-order-7002'));
      expect(find.descendant(of: card, matching: find.text('Picked up')), findsOne);
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsNothing, reason: 'it is on its way');
      // and what it can be marked as next is another list
      await tapKey(tester, 'shipday-mark-7002');
      expect(offered(tester), ['READY_TO_DELIVER', ...ends]);
      expect(textOf(tester, 'shipday-steps-order'), 'Raj Patel · Tom Reyes has it · now: picked up');
      await tester.tap(find.byKey(const ValueKey('shipday-step-READY_TO_DELIVER')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges.last, 'mark 7002 READY_TO_DELIVER s3 was PICKED_UP');
      expect(said(tester), 'Marked ready to deliver.');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a mark that ends the delivery asks first', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      await tapKey(tester, 'shipday-mark-7003');
      expect(offered(tester), ['READY_TO_DELIVER', ...ends]);
      await tester.tap(find.byKey(const ValueKey('shipday-step-ALREADY_DELIVERED')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shipday-steps')), findsNothing);
      expect(find.text('Mark it delivered?'), findsOneWidget);
      expect(
        textOf(tester, 'shipday-end-words'),
        "Mei Lin's delivery leaves Shipday's active deliveries as Delivered. That cannot be taken back from the POS.",
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, isEmpty);
      expect(find.text('On the way · 1'), findsOneWidget);

      await tapKey(tester, 'shipday-mark-7003');
      await tester.tap(find.byKey(const ValueKey('shipday-step-ALREADY_DELIVERED')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byKey(const ValueKey('shipday-end-yes')), matching: find.text('Mark delivered')),
        findsOne,
      );
      await tester.tap(find.byKey(const ValueKey('shipday-end-yes')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['mark 7003 ALREADY_DELIVERED s3 was PICKED_UP']);
      expect(said(tester), 'Marked delivered.');
      expect(find.text('On the way · 0'), findsOneWidget);
      expect(find.text('Finished today · 2'), findsOneWidget);
      // Tom has one fewer out
      expect(find.descendant(of: find.byKey(const ValueKey('shipday-driver-501')), matching: find.text('1')), findsOne);

      // one nobody has can only be ended as not delivered
      await tapKey(tester, 'shipday-mark-7001');
      expect(offered(tester), ['FAILED_DELIVERY', 'INCOMPLETE']);
      expect(textOf(tester, 'shipday-steps-order'), 'Linda Chen · nobody has it · now: no driver yet');
      expect(textOf(tester, 'shipday-steps-hint'), 'Failed, Incomplete end the delivery and ask first.');
      await tester.tap(find.byKey(const ValueKey('shipday-step-INCOMPLETE')));
      await tester.pumpAndSettle();
      expect(find.text('Mark it incomplete?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shipday-end-yes')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges.last, 'mark 7001 INCOMPLETE s3 was NOT_ASSIGNED');
      expect(said(tester), 'Marked incomplete.');
      expect(find.text('Need a driver · 0'), findsOneWidget);
      expect(find.text('Finished today · 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('closing the list of steps marks nothing', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      await tapKey(tester, 'shipday-mark-7004');
      expect(offered(tester), ['PICKED_UP', ...ends]);
      expect(textOf(tester, 'shipday-steps-order'), 'Order A-55 · Driver 777 has it · now: started');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'shipday-mark-7004');
      await tester.tapAt(const Offset(5, 5)); // beside the list
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shipday-steps')), findsNothing);
      expect(t.hub.shipdayChanges, isEmpty);
      await stop(tester);
    });

    testWidgets('what the hub or Shipday would not mark is said, with the list as it now stands', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      // the driver's app said picked up a moment ago: the hub looked first and sent nothing
      t.hub.shipdayOnChange = () {
        final orders = [...(t.hub.shipday!['orders'] as List).cast<Map<String, dynamic>>()];
        orders[1] = {
          ...orders[1],
          'state': 'PICKED_UP',
          'steps': ['READY_TO_DELIVER', ...ends],
        };
        t.hub.shipday = {...t.hub.shipday!, 'orders': orders};
      };
      t.hub.shipdayChangeSays = {'reason': 'moved'};
      await tapKey(tester, 'shipday-mark-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-step-STARTED')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['mark 7002 STARTED s3 was NOT_ACCEPTED']);
      expect(said(tester), 'Shipday has it as "Picked up" by now. Nothing was changed.');
      expect(find.text('On the way · 2'), findsOneWidget);

      // Shipday itself would not: its own words
      t.hub.shipdayOnChange = null;
      t.hub.shipdayChangeSays = {
        'sent': true,
        'reason': 'rejected',
        'said': 'Shipday would not do it (400)',
        'told': 'Order is not picked up.',
      };
      await tapKey(tester, 'shipday-mark-7004');
      await tester.tap(find.byKey(const ValueKey('shipday-step-ALREADY_DELIVERED')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shipday-end-yes')));
      await tester.pumpAndSettle();
      expect(said(tester), 'Shipday would not do it: "Order is not picked up."');
      expect(find.byKey(const ValueKey('shipday-mark-7004')), findsOneWidget, reason: 'it stands where it stood');

      // a hub that does not answer: it may or may not have been done
      t.hub
        ..shipdayChangeSays = null
        ..shipdayChangeStatus = 500;
      await tapKey(tester, 'shipday-mark-7004');
      await tester.tap(find.byKey(const ValueKey('shipday-step-PICKED_UP')));
      await tester.pumpAndSettle();
      expect(said(tester), 'The hub did not answer. Look at the list before trying again: it may have been done.');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('while the hub asks Shipday the card says so and takes no second tap', (tester) async {
      final t = await pumpShipday(tester, size: tall, staffId: 's3');
      t.hub.shipdayChangeHeld = Completer<void>();
      await tapKey(tester, 'shipday-mark-7002');
      await tester.tap(find.byKey(const ValueKey('shipday-step-STARTED')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('shipday-busy-7002')), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-mark-7002')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsNothing);
      t.hub.shipdayChangeHeld!.complete();
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['mark 7002 STARTED s3 was NOT_ACCEPTED']);
      expect(said(tester), 'Marked started.');
      expect(find.byKey(const ValueKey('shipday-take-7002')), findsOneWidget, reason: 'started is not picked up');
      await stop(tester);
    });

    testWidgets('a hub that marks nothing offers no mark, and nobody signed in is offered nothing', (tester) async {
      final picture = evening()..['can'] = ['driver'];
      final t = await pumpShipday(tester, picture: picture, size: tall, staffId: 's3');
      expect(find.byKey(const ValueKey('shipday-give-7001')), findsOneWidget);
      for (final id in [7001, 7002, 7003, 7004]) {
        expect(find.byKey(ValueKey('shipday-mark-$id')), findsNothing);
      }
      expect(textOf(tester, 'shipday-foot'), startsWith('A delivery is given to a driver here or in Shipday'));
      expect(textOf(tester, 'shipday-foot'), contains("in Shipday's app for now"));
      // a hub that would, and nobody signed in at this terminal
      t.hub.shipday = evening();
      await tester.pumpWidget(const SizedBox());
      await pumpShipday(tester, size: tall);
      for (final id in [7001, 7002, 7003, 7004]) {
        expect(find.byKey(ValueKey('shipday-mark-$id')), findsNothing);
        expect(find.byKey(ValueKey('shipday-give-$id')), findsNothing);
      }
      await stop(tester);
    });

    testWidgets('the button, the steps and the asking fit the narrowest phone with large type', (tester) async {
      await pumpShipday(tester, size: const Size(320, 640), textScale: 1.6, staffId: 's3');
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-foot')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-mark-7002')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, 200),
      );
      await tapKey(tester, 'shipday-mark-7002');
      expect(offered(tester), ['STARTED', 'PICKED_UP', ...ends]);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'shipday-step-FAILED_DELIVERY');
      expect(find.text('Mark it failed?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await stop(tester);
    });
  });

  group('the Shipday screen under the hub\'s change feed', () {
    Future<(LiveHub, Terminal)> liveTerminal(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      final session = Session(api)..staff = const Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin');
      final outbox = Outbox(api, settings, store: MemoryStore());
      final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      return (live, Terminal(hub, api, outbox, photos, session, settings));
    }

    testWidgets('it reads when the hub says Shipday changed, or a check did, and otherwise waits', (tester) async {
      final (live, t) = await liveTerminal(tester);
      t.hub.shipday = evening();
      await tester.pumpWidget(
        MaterialApp(
          home: ShipdayScreen(api: t.api, onOpen: (_) async {}),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      expect(t.api.live.isLive, isTrue);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // twenty seconds of nothing: not one read
      var asks = t.hub.shipdayAsks;
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(t.hub.shipdayAsks, asks);

      // Shipday reads differently: told, read, shown
      t.hub.shipday = Hub.shipdayStands(
        drivers: [tom],
        orders: [Hub.shipdayOrder(7009, 'Z-1', name: 'Ada Wong')],
      );
      live.changed(topics: ['shipday']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(t.hub.shipdayAsks, asks + 1);
      expect(find.text('Ada Wong'), findsOneWidget);
      expect(find.byKey(const ValueKey('shipday-nocheck-7009')), findsOneWidget);

      // its check is rung up on the POS: the hub says an order changed, and the delivery has its check
      asks = t.hub.shipdayAsks;
      t.hub.shipday = Hub.shipdayStands(
        drivers: [tom],
        orders: [
          Hub.shipdayOrder(
            7009,
            'Z-1',
            name: 'Ada Wong',
            check: Hub.shipdayCheck('o-9', 21, by: 'phone'),
          ),
        ],
      );
      live.changed(orders: ['o-9']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(t.hub.shipdayAsks, asks + 1);
      expect(find.text('Check #21'), findsOneWidget);

      // another topic is nothing to this screen
      asks = t.hub.shipdayAsks;
      live.changed(topics: ['texts']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(t.hub.shipdayAsks, asks);

      // and every half minute it asks anyway, which also tells the hub somebody is still looking
      final looks = t.hub.shipdayLooks;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(t.hub.shipdayLooks, greaterThan(looks));

      await stop(tester);
      live.close();
      t.api.dispose();
      await tester.pump();
    });
  });

  group('on the home screen', () {
    testWidgets('there is no Shipday button while the hub has no key, or is older than Shipday', (tester) async {
      final t = await pumpOrders(tester, []);
      expect(t.hub.shipdayAsks, greaterThan(0));
      expect(t.hub.shipdayLooks, 0, reason: 'the home screen is not somebody looking at Shipday');
      expect(homeIds(tester), isNot(contains('shipday')));
      await stop(tester);

      final older = await terminal(tester);
      older.hub.shipday = null;
      await pumpOrdersOn(tester, older);
      expect(homeIds(tester), isNot(contains('shipday')));
      await stop(tester);
    });

    testWidgets('with a key the button says who needs a driver, and a check tapped there opens on top', (tester) async {
      final t = await terminal(tester, role: 'server');
      t.hub.shipday = evening();
      t.hub.orders.add({
        'order_id': 'gf-1270166229',
        'status': 'open',
        'fields': {
          'order_type': 'takeout',
          'handover': 'delivery',
          'customer_name': 'Linda Chen',
          'order_no': 12,
          'address': '12 Elm St, Winchester, MA 01890',
        },
        'lines': {'L1': line('Egg Roll')},
        'fired': {},
      });
      await pumpOrdersOn(tester, t);
      expect(homeIds(tester), contains('shipday'));
      await openMore(tester);
      expect(find.descendant(of: homeTile('shipday'), matching: find.text('Shipday')), findsOne);
      expect(find.descendant(of: homeTile('shipday'), matching: find.text('1 needs a driver')), findsOne);
      await tester.tap(homeTile('shipday'));
      await tester.pumpAndSettle();
      expect(find.byType(ShipdayScreen), findsOneWidget);
      // the picture the home screen had is there at once
      expect(find.text('Need a driver · 1'), findsOneWidget);
      expect(t.hub.shipdayLooks, greaterThan(0));

      await tapKey(tester, 'shipday-check-7001');
      expect(find.byType(OrderScreen), findsOneWidget);
      expect(find.text('Egg Roll'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ShipdayScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ShipdayScreen), findsNothing);
      await stop(tester);
    });
  });
}
