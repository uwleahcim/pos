import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/idle_lock.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/pickup_board.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/pickup_board_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';

import 'counter_test.dart' show cash;
import 'hub.dart';
import 'phone_test.dart' show FakeStack;
import 'quote_times_test.dart' show quoted;

/// The pickup board (docs/pickup-board.md): a device set to be one lists, while nobody is signed in on it,
/// the to-go orders the kitchen is making and the ones that are ready, each by its number and a first name
/// and nothing else. The staff reach the sign-in pad from its corner, and a pad left alone goes back to
/// the board.

final six = DateTime(2026, 11, 17, 18);
int at(int minutes) => six.add(Duration(minutes: minutes)).millisecondsSinceEpoch;

/// The counter at six: two orders waiting for their time (one of them sent ahead), three with the kitchen,
/// two on the shelf, one still being rung up, a table and a bar tab.
List<Map<String, dynamic>> evening() => [
  quoted('o1', no: 1, name: 'Rosa', channel: 'phone', quote: 20, at: at(180), forLater: true),
  quoted('o2', no: 2, name: 'Wei Zhang', channel: 'phone', quote: 20, at: at(21), forLater: true, fired: true),
  quoted('o12', no: 12, name: 'Dmitri Volkov', quote: 15, at: at(12), fired: true, payments: cash),
  quoted('o4', no: 4, name: 'Linda', channel: 'phone', quote: 20, at: at(5), forLater: true, fired: true),
  quoted('o9', no: 9, name: '', quote: 15, at: at(9), fired: true),
  quoted('o5', no: 5, name: 'Sam', channel: 'phone', quote: 20, at: at(-2), fired: true, stage: 'ready'),
  quoted('o3', no: 3, name: '  ana  maria ', quote: 15, at: at(-6), fired: true, stage: 'ready'),
  quoted('o6', no: 6, name: 'Omar', quote: 15, at: at(15)),
  table('t1', const {}),
  {
    'order_id': 'b1',
    'status': 'open',
    'fields': {'order_type': 'dine_in', 'tab': true, 'customer_name': 'Priya'},
    'lines': <String, dynamic>{},
    'fired': <String, dynamic>{},
  },
];

/// What the tiles of one list say, in the order they stand: "4 Linda".
List<String> tiles(WidgetTester tester, String list) => [
  for (final tile
      in find
          .descendant(
            of: find.byKey(ValueKey(list)),
            matching: find.byWidgetPredicate((w) => w is Container && '${w.key}'.contains('board-order:')),
          )
          .evaluate())
    [
      for (final text in find.descendant(of: find.byWidget(tile.widget), matching: find.byType(Text)).evaluate())
        if ((text.widget as Text).data case final said? when said.isNotEmpty) said,
    ].join(' '),
];

Future<Terminal> pumpBoard(
  WidgetTester tester, {
  Size? size,
  List<Map<String, dynamic>>? orders,
  DateTime Function()? now,
}) async {
  final t = await terminal(tester);
  t.hub.orders.addAll(orders ?? evening());
  if (size != null) tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      home: PickupBoardScreen(api: t.api, now: now ?? () => six, onStaff: () {}),
    ),
  );
  await tester.pump();
  await tester.pump();
  return t;
}

/// Takes the board's timers down with the screen, so no test leaves one running.
Future<void> away(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  group('what the board lists', () {
    test('a first name is the first word of the name on the order', () {
      expect(firstName('Linda Chen'), 'Linda');
      expect(firstName('  ana  maria '), 'ana');
      expect(firstName('Wei'), 'Wei');
      expect(firstName(''), '');
      expect(firstName('   '), '');
    });

    test('the orders the kitchen has and the ones ready, by number; nothing else of the day', () {
      final orders = [for (final json in evening()) Order.fromJson(json)];
      final board = boardOf(orders, six);
      // sent and its time come, by number: 4, 9, 12 (not 2, whose ticket has not printed; not 6, not sent)
      expect([for (final o in board.made) (o.number, o.name)], [(4, 'Linda'), (9, ''), (12, 'Dmitri')]);
      expect([for (final o in board.ready) (o.number, o.name)], [(3, 'ana'), (5, 'Sam')]);
      // the table and the bar's tab are on neither
      expect([...board.made, ...board.ready].map((o) => o.orderId), isNot(anyOf(contains('t1'), contains('b1'))));
      // a closed order is off the board
      final closed = Order.fromJson({...evening()[5], 'status': 'closed'});
      expect(boardOf([closed], six).ready, isEmpty);
      // orders with no number keep the order they came in, after the numbered ones
      final loose = [
        for (final (id, no) in [('x', null), ('y', 8), ('z', null)])
          Order.fromJson(quoted(id, at: at(5), fired: true)..['fields']['order_no'] = no),
      ];
      expect(boardOf(loose, six).made.map((o) => o.orderId), ['y', 'x', 'z']);
    });

    test('an order sent ahead joins the board when its ticket prints, with nothing told by the hub', () {
      final orders = [for (final json in evening()) Order.fromJson(json)];
      // Wei's is for 18:21 with a quote of 20: it starts at 18:01
      expect(boardChanges(orders, six), six.add(const Duration(minutes: 1)));
      final after = six.add(const Duration(minutes: 1));
      expect(boardOf(orders, after).made.map((o) => o.number), [2, 4, 9, 12]);
      // Rosa's was never sent: no clock brings it on
      expect(boardChanges(orders, after), isNull);
    });
  });

  group('the screen', () {
    testWidgets('lists the two by number and first name, and nothing else of an order', (tester) async {
      await pumpBoard(tester);
      expect(tiles(tester, 'board-made'), ['4 Linda', '9', '12 Dmitri']);
      expect(tiles(tester, 'board-ready'), ['3 ana', '5 Sam']);
      expect(find.text('Being made'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      // no family name, no dish, no money, no channel, nobody who is not cooking or ready
      for (final hidden in ['Volkov', 'Egg roll', r'$', 'phone', 'Rosa', 'Omar', 'Priya', 'A1', 'Wei']) {
        expect(find.textContaining(hidden), findsNothing, reason: hidden);
      }
      expect(find.byKey(const ValueKey('board-away')), findsNothing);
      await away(tester);
    });

    testWidgets('every tile is as tall as the next, with a name, with none or with no number', (tester) async {
      await pumpBoard(
        tester,
        orders: [
          ...evening(),
          quoted('o20', name: 'Bartholomew Jones', at: at(9), fired: true)..['fields']['order_no'] = null,
        ],
      );
      expect(tiles(tester, 'board-made'), ['4 Linda', '9', '12 Dmitri', 'Bartholomew']);
      final heights = {
        for (final id in ['o4', 'o9', 'o12', 'o20']) tester.getSize(find.byKey(ValueKey('board-order:$id'))).height,
      };
      expect(heights, hasLength(1), reason: '$heights');
      expect(tester.takeException(), isNull);
      await away(tester);
    });

    testWidgets('an empty board says so in each list', (tester) async {
      await pumpBoard(tester, orders: [table('t1', const {})]);
      expect(find.text('Nothing is being made right now.'), findsOneWidget);
      expect(find.text('Nothing is ready yet.'), findsOneWidget);
      await away(tester);
    });

    testWidgets('follows the kitchen: ready moves an order across, picked up takes it off', (tester) async {
      final t = await pumpBoard(tester);
      (t.hub.orders[3]['fields'] as Map)['stage'] = 'ready'; // Linda's
      t.hub.orders[5]['status'] = 'closed'; // Sam picked his up
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(tiles(tester, 'board-made'), ['9', '12 Dmitri']);
      expect(tiles(tester, 'board-ready'), ['3 ana', '4 Linda']);
      await away(tester);
    });

    testWidgets('an order sent ahead comes on at its time by itself', (tester) async {
      var now = six;
      await pumpBoard(tester, now: () => now);
      expect(tiles(tester, 'board-made'), ['4 Linda', '9', '12 Dmitri']);
      now = six.add(const Duration(seconds: 62));
      await tester.pump(const Duration(seconds: 62));
      await tester.pump();
      expect(tiles(tester, 'board-made'), ['2 Wei', '4 Linda', '9', '12 Dmitri']);
      await away(tester);
    });

    testWidgets('with the hub away it keeps its picture and says it may be behind', (tester) async {
      final t = await pumpBoard(tester);
      t.hub.down = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('board-away'))).data,
        'This board may be behind: the hub is not answering.',
      );
      expect(tiles(tester, 'board-ready'), ['3 ana', '5 Sam']);
      t.hub.down = false;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('board-away')), findsNothing);
      await away(tester);
    });

    testWidgets('a change that is nothing to the board draws nothing again', (tester) async {
      final t = await pumpBoard(tester);
      final before = tester.firstElement(find.byKey(const ValueKey('board-order:o4'))).widget;
      t.hub.orders.add(table('t2', const {})); // a table sat down
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(identical(tester.firstElement(find.byKey(const ValueKey('board-order:o4'))).widget, before), isTrue);
      await away(tester);
    });

    testWidgets('on a phone the ready ones are first, and nothing runs off the screen', (tester) async {
      await pumpBoard(tester, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      final ready = tester.getTopLeft(find.byKey(const ValueKey('board-ready')));
      final made = tester.getTopLeft(find.byKey(const ValueKey('board-made')));
      expect(ready.dy, lessThan(made.dy));
      expect(tiles(tester, 'board-ready'), ['3 ana', '5 Sam']);
      await away(tester);
    });

    testWidgets('on a wide screen the two stand side by side, being made on the left', (tester) async {
      await pumpBoard(tester);
      final ready = tester.getTopLeft(find.byKey(const ValueKey('board-ready')));
      final made = tester.getTopLeft(find.byKey(const ValueKey('board-made')));
      expect((made.dx < ready.dx, made.dy), (true, ready.dy));
      await away(tester);
    });
  });

  group('the device that is a board', () {
    Future<Terminal> pumpDevice(WidgetTester tester, {bool board = true, int lockMinutes = 0}) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.savePickupBoard(board);
      await t.settings.saveLockMinutes(lockMinutes);
      t.hub.orders.addAll(evening());
      final lock = IdleLock(t.settings, t.session)..start();
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        PosApp(
          settings: t.settings,
          api: t.api,
          outbox: t.outbox,
          session: t.session,
          camera: NoCamera(),
          photos: t.photos,
          relay: PrintRelay(t.api, t.settings),
          phone: PhoneClient(FakeStack()),
          deskPhones: DeskPhoneWatcher(t.api, t.settings),
          idleLock: lock,
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    Future<void> pin(WidgetTester tester, String digits) async {
      for (final digit in digits.split('')) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a device that is not a board shows the sign-in pad, as before', (tester) async {
      await pumpDevice(tester, board: false);
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(PickupBoardScreen), findsNothing);
      expect(find.byKey(const ValueKey('board-back')), findsNothing);
      await away(tester);
    });

    testWidgets('the board stands while nobody is signed in; Staff brings the pad, and a PIN the orders', (
      tester,
    ) async {
      final t = await pumpDevice(tester);
      expect(find.byType(PickupBoardScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      expect(tiles(tester, 'board-ready'), isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('board-staff')));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(PickupBoardScreen), findsNothing);
      await pin(tester, '1111');
      expect(t.session.staff?.name, 'Amy');
      expect(find.byType(OrdersScreen), findsOneWidget);
      // signing out puts the board back, not the pad
      t.session.signOut();
      await tester.pumpAndSettle();
      expect(find.byType(PickupBoardScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      await away(tester);
    });

    testWidgets('the pad goes back to the board from its bar, and by itself when left alone', (tester) async {
      await pumpDevice(tester);
      await tester.tap(find.byKey(const ValueKey('board-staff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('board-back')));
      await tester.pumpAndSettle();
      expect(find.byType(PickupBoardScreen), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('board-staff')));
      await tester.pumpAndSettle();
      // somebody types half a PIN, slowly: each touch starts the minute over
      await tester.pump(const Duration(seconds: 50));
      await tester.tap(find.widgetWithText(FilledButton, '1'));
      await tester.pump(const Duration(seconds: 50));
      expect(find.byType(SignInScreen), findsOneWidget);
      // and walks off
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.byType(PickupBoardScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      await away(tester);
    });

    testWidgets('the switch is in the device\'s Settings, off to start, and kept with Save', (tester) async {
      final t = await terminal(tester);
      expect(t.settings.pickupBoard, isFalse);
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('pickup-board-line'));
      expect(tester.widget<Text>(line).data, startsWith('For a screen facing the pickup shelf'));
      await tester.tap(find.byKey(const ValueKey('pickup-board-switch')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, contains('Staff, in its corner, brings up the sign-in pad.'));
      expect(t.settings.pickupBoard, isFalse); // not before Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(t.settings.pickupBoard, isTrue);
    });

    testWidgets('a board that locked itself shows the board, and the PIN brings back what was open', (tester) async {
      final t = await pumpDevice(tester, lockMinutes: 5);
      await tester.tap(find.byKey(const ValueKey('board-staff')));
      await tester.pumpAndSettle();
      await pin(tester, '1111');
      expect(find.byType(OrdersScreen), findsOneWidget);
      t.session.lock(); // nobody touched it for five minutes
      await tester.pumpAndSettle();
      expect(t.session.locked, isTrue);
      expect(find.byType(PickupBoardScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-staff')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Locked'), findsWidgets);
      await pin(tester, '1111');
      expect((t.session.signedIn, t.session.locked), (true, false));
      expect(find.byType(PickupBoardScreen), findsNothing);
      t.session.signOut(); // (and the lock's own clock stops with it)
      await tester.pumpAndSettle();
      await away(tester);
    });
  });
}
