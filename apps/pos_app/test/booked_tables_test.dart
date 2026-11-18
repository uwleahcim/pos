import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/reservations.dart';
import 'package:pos_app/screens/booked_table_dialog.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/takeout.dart' show clockTime;
import 'package:shared_preferences/shared_preferences.dart';

import 'floor_test.dart' show floorJson;
import 'hub.dart';
import 'table_moves_test.dart' show byAmy, byHolly, checkAt, floorThatMoves, sentTo;
import 'table_servers_test.dart' show amy, holly, sentOne;
import 'tabs_test.dart' show pumpSeating;
import 'waitlist_test.dart' show seatFromList;

/// Reservations on the floor map (the Toast comparison's row 15, part two): a table booked for today says
/// so on the map, with the time and whose it is; the time turns amber when it is near and red once it is
/// past; and a free table that is being kept for a party asks before somebody else sits down there.

const minute = 60000;

/// Five in the afternoon on Monday 16 November 2026.
final five = DateTime(2026, 11, 16, 17).millisecondsSinceEpoch;
int at(int hour, [int min = 0]) => DateTime(2026, 11, 16, hour, min).millisecondsSinceEpoch;

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

Finder mark(String table) => key('table-hold:$table');

/// What a table's mark reads, "18:30" or "here"; null for a table with none.
String? markSays(WidgetTester tester, String table) => mark(table).evaluate().isEmpty
    ? null
    : tester.widget<Text>(find.descendant(of: mark(table), matching: find.byType(Text)).first).data;

/// How the time on a table is drawn: the colour behind it, and whether it is only outlined.
(Color?, bool) markLook(WidgetTester tester, String table) {
  final box =
      tester.widget<Container>(find.descendant(of: mark(table), matching: find.byType(Container)).first).decoration!
          as BoxDecoration;
  return (box.color, box.border != null);
}

/// The map by itself on the clock [now], on a hub whose book holds [bookings].
Future<Hub> pumpMap(
  WidgetTester tester, {
  required List<Map<String, dynamic>> bookings,
  required int Function() now,
  Map<String, dynamic>? floor,
  Size size = const Size(1200, 900),
}) async {
  final hub = Hub()
    ..floor = floor ?? floorJson()
    ..bookings = bookings;
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient(hub.handle),
  );
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: PosTheme.light(),
      home: Scaffold(
        body: FloorView(api: api, onTable: (plan, table) {}, now: now),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return hub;
}

/// A table booked [inMinutes] from now by the real clock, which the orders screen goes by.
Map<String, dynamic> bookedIn(String id, String name, int size, int inMinutes, String table, {int? arrivedMs}) {
  final at = DateTime.now().millisecondsSinceEpoch + inMinutes * minute;
  return Hub.booking(id, name, size, time: clockTime(at), table: table, atMs: at, arrivedMs: arrivedMs);
}

/// The floor map of [who] on a hub with [bookings] in its book, nobody on its waitlist unless [parties]
/// says so, and A7 seated (Amy's).
Future<Terminal> pumpFloor(
  WidgetTester tester,
  Staff who, {
  required List<Map<String, dynamic>> bookings,
  List<Map<String, dynamic>> parties = const [],
  Size? size,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.session.staff = who;
  t.hub
    ..clockNow = DateTime.now().millisecondsSinceEpoch
    ..floor = floorThatMoves()
    ..parties = [...parties]
    ..bookings = bookings;
  await pumpOrdersOn(tester, t);
  await tester.tap(find.byTooltip('Floor map'));
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('the words', () {
    test('a hold is read with the moments the hub stamped, and counted against the clock', () {
      final hub = Hub()
        ..bookings = [Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8', phone: '781 555 0101', note: 'Booth')];
      final told = hub.tableHolds['A8']!.single;
      expect(told.keys, isNot(contains('phone')));
      expect(told.keys, isNot(contains('note')));
      final hold = TableHold.fromJson(told);
      expect((hold.id, hold.name, hold.size, hold.time, hold.atMs), ('b2', 'Chen', 4, '18:30', at(18, 30)));
      expect((hold.heldMs, hold.soonMs, hold.lateMs, hold.untilMs), (at(17), at(18, 15), at(18, 45), at(20)));
      expect((hold.label, hold.isHere), ('Chen, party of 4', false));
      // the table is kept from an hour and a half before until an hour and a half after
      expect([at(16, 59), at(17), at(19, 59), at(20)].map(hold.keptAt), [false, true, true, false]);
      // plain until a quarter before, amber then, red a quarter after
      expect([at(18, 14), at(18, 15), at(18, 44), at(18, 45)].map(hold.levelAt), [
        TimerLevel.ok,
        TimerLevel.warn,
        TimerLevel.warn,
        TimerLevel.late,
      ]);
      // a hub that names no moments means the same ones
      final bare = TableHold.fromJson({'id': 'b2', 'name': 'Chen', 'size': 4, 'at_ms': at(18, 30)});
      expect((bare.heldMs, bare.soonMs, bare.lateMs, bare.untilMs), (at(17), at(18, 15), at(18, 45), at(20)));
      expect((bare.time, bare.arrivedMs), ('', null));
    });

    test('the plan says what is still to come at a table and whom it is kept for now', () {
      final hub = Hub()
        ..bookings = [
          Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8'),
          Hub.booking('b1', 'Okafor', 6, time: '16:00', table: 'A8'),
          Hub.booking('b3', 'Garcia', 2, time: '21:00', table: 'A8'),
          Hub.booking('b4', 'Silva', 2, time: '18:00'), // no table held
          Hub.booking('b5', 'Park', 4, day: '2026-11-21', time: '19:00', table: 'B5'), // another day
          Hub.booking('b6', 'Lee', 2, time: '18:00', table: 'B6')..['status'] = 'cancelled',
        ];
      final plan = FloorPlan.fromJson({...floorJson(), 'holds': hub.tableHolds});
      expect(plan.holds.keys, ['A8']);
      List<String> coming(int now) => [for (final hold in plan.holdsAt('A8', now)) hold.name];
      List<String> kept(int now) => [for (final hold in plan.keptAt('A8', now)) hold.name];
      expect(coming(at(15)), ['Okafor', 'Chen', 'Garcia']);
      expect(kept(at(14)), isEmpty); // two hours ahead: a party sat now is long gone by then
      expect(kept(at(15)), ['Okafor']);
      expect(kept(at(17, 15)), ['Okafor', 'Chen']); // Okafor has not come, Chen is next
      expect(coming(at(17, 30)), ['Chen', 'Garcia']); // an hour and a half past its time, Okafor's is let go
      expect(kept(at(17, 30)), ['Chen']);
      expect(coming(at(22, 30)), isEmpty);
      expect(plan.holdsAt('A1', five), isEmpty);
      expect(plan.keptAt('A1', five), isEmpty);
      // a check this device opened and no hub knows yet changes nothing about the tables booked
      final seated = plan.withChecks({
        'A8': [const TableCheck(orderId: 'n1', guests: 2, items: 0)],
      });
      expect(seated.holds, same(plan.holds));
      // a hub older than this says nothing, and one that says nonsense is read as nothing
      expect(FloorPlan.fromJson(floorJson()).holds, isEmpty);
      expect(FloorPlan.fromJson({...floorJson(), 'holds': 'none'}).holds, isEmpty);
      expect(
        FloorPlan.fromJson({
          ...floorJson(),
          'holds': {'A8': <Object>[], 'A9': 7},
        }).holds,
        isEmpty,
      );
    });

    test('how far off a booked time is, in words', () {
      final chen = TableHold.fromJson(Hub.holdOf(Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8')));
      expect(holdWhenWords(chen, at(18, 5)), 'in 25 min');
      expect(holdWhenWords(chen, at(18, 5) + 20000), 'in 25 min'); // part of a minute counts as one to go
      expect(holdWhenWords(chen, at(17, 20)), 'in 1 h 10 min');
      expect(holdWhenWords(chen, at(17, 30)), 'in 1 h');
      expect(holdWhenWords(chen, at(18, 30)), 'now');
      expect(holdWhenWords(chen, at(18, 30) + 59000), 'now');
      expect(holdWhenWords(chen, at(18, 50)), '20 min ago');
      expect(holdWhenWords(chen, at(19, 45)), '1 h 15 min ago');
      final here = TableHold.fromJson(
        Hub.holdOf(Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8', arrivedMs: at(18, 22))),
      );
      expect(holdWhenWords(here, at(18, 50)), 'here since 18:22');
    });

    test('a hold is seated as the reservation it is', () {
      final hold = TableHold.fromJson(
        Hub.holdOf(Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8', arrivedMs: at(18, 22))),
      );
      const a8 = TableSpot(id: 'A8', label: 'A8', room: 'AB', x: 0, y: 0, w: 1, h: 1, seats: 4);
      final booking = Booking.ofHold(hold, a8);
      expect((booking.id, booking.name, booking.size, booking.label), ('b2', 'Chen', 4, 'Chen, party of 4'));
      expect((booking.table, booking.tableLabel, booking.time, booking.isHere), ('A8', 'A8', '18:30', true));
      expect(booking.isBooked, isTrue);
    });
  });

  group('on the map', () {
    testWidgets('a free table booked for today says the time and whose it is; one nobody booked says nothing', (
      tester,
    ) async {
      await pumpMap(
        tester,
        bookings: [Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8')],
        now: () => five,
      );
      expect(markSays(tester, 'A8'), '18:30');
      expect(find.descendant(of: mark('A8'), matching: find.text('Chen 4p')), findsOneWidget);
      expect(mark('A9'), findsNothing);
      expect(mark('A7'), findsNothing);
      // the legend says what the mark means, on a day with a table booked
      expect(find.descendant(of: key('legend-booked'), matching: find.text('Booked')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('with no table booked the map is as it was, and the legend keeps its room', (tester) async {
      await pumpMap(
        tester,
        bookings: [Hub.booking('b4', 'Silva', 2, time: '18:00')],
        now: () => five,
      );
      expect(find.byWidgetPredicate((w) => '${w.key}'.contains('table-hold:')), findsNothing);
      expect(key('legend-booked'), findsNothing);
      await stop(tester);
    });

    testWidgets('the time is plain while it is ahead, amber when it is near and red once it has passed, by the '
        'clock alone; an hour and a half past, the map lets it go', (tester) async {
      var now = at(17);
      final hub = await pumpMap(
        tester,
        bookings: [Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8')],
        now: () => now,
      );
      final pos = PosColors.light;
      expect(markLook(tester, 'A8'), (null, true)); // outlined, in the table's own colours
      Future<void> clock(int to) async {
        now = to;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }

      await clock(at(18, 14));
      expect(markLook(tester, 'A8'), (null, true));
      await clock(at(18, 15));
      expect(markLook(tester, 'A8'), (pos.timerWarn, false));
      await clock(at(18, 45));
      expect(markLook(tester, 'A8'), (pos.timerLate, false));
      expect(markSays(tester, 'A8'), '18:30');
      await clock(at(19, 59));
      expect(mark('A8'), findsOneWidget);
      await clock(at(20));
      expect(mark('A8'), findsNothing);
      // all the while the hub's answer stayed the one the map already had: nothing in it follows the clock
      expect(hub.unchanged, hub.requests.where((request) => request == 'GET /floor').length - 1);
      await stop(tester);
    });

    testWidgets('a party that is here and waits says so in a colour of its own', (tester) async {
      await pumpMap(
        tester,
        bookings: [Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8', arrivedMs: at(18, 40))],
        now: () => at(18, 50), // past its time: the party is here, so nothing is late
      );
      expect(markSays(tester, 'A8'), 'here');
      final scheme = PosTheme.light().colorScheme;
      expect(markLook(tester, 'A8'), (scheme.primaryContainer, false));
      expect(
        tester.widget<Text>(find.descendant(of: mark('A8'), matching: find.byType(Text)).first).semanticsLabel,
        'booked for 18:30, Chen, party of 4, the party is here',
      );
      await stop(tester);
    });

    testWidgets('a table that is seated says the time under its check, without the name', (tester) async {
      // A7 is Amy's on this floor, and booked for half past six
      await pumpMap(
        tester,
        bookings: [Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A7')],
        now: () => five,
      );
      expect(markSays(tester, 'A7'), '18:30');
      expect(find.text('Chen 4p'), findsNothing);
      expect(find.descendant(of: key('table-server:A7'), matching: find.text('Amy')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a table that is seated says nothing of a reservation hours away, and says it once the table '
        'is wanted', (tester) async {
      var now = at(15);
      await pumpMap(
        tester,
        bookings: [
          Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A7'),
          Hub.booking('b3', 'Garcia', 2, time: '18:30', table: 'A8'),
        ],
        now: () => now,
      );
      expect(mark('A7'), findsNothing); // whoever sits there at three is gone by half past six
      expect(markSays(tester, 'A8'), '18:30'); // a free table says it from the morning on
      now = at(17);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(markSays(tester, 'A7'), '18:30');
      await stop(tester);
    });

    testWidgets('a narrow table keeps its name as large: the booking is drawn smaller', (tester) async {
      // B5 is 45 wide and B7, beside it, is booked by nobody
      await pumpMap(
        tester,
        bookings: [
          Hub.booking('b1', 'Okafor', 6, time: '17:45', table: 'B5'),
          Hub.booking('b4', 'Kim', 4, time: '19:30', table: 'B5'),
        ],
        now: () => five,
      );
      expect(markSays(tester, 'B5'), '17:45 +1');
      expect(tester.getSize(find.text('B5')), tester.getSize(find.text('B7')));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a table booked twice says the next one and that one more follows', (tester) async {
      var now = at(15, 30);
      await pumpMap(
        tester,
        bookings: [
          Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8'),
          Hub.booking('b1', 'Okafor', 6, time: '16:00', table: 'A8'),
        ],
        now: () => now,
      );
      expect(markSays(tester, 'A8'), '16:00 +1');
      expect(find.text('Okafor 6p'), findsOneWidget);
      // Okafor never came: an hour and a half on, the table says Chen
      now = at(17, 30);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(markSays(tester, 'A8'), '18:30');
      expect(find.text('Chen 4p'), findsOneWidget);
      expect(find.text('Okafor 6p'), findsNothing);
      await stop(tester);
    });

    testWidgets('a long name is cut to what a table has the room for', (tester) async {
      await pumpMap(
        tester,
        bookings: [Hub.booking('b2', 'Featherstonehaugh', 12, time: '18:30', table: 'A8')],
        now: () => five,
      );
      expect(find.text('Feathers… 12p'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a table another screen booked shows when the hub says the book changed', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()
        ..clockNow = five
        ..floor = floorJson()
        ..bookings = [];
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      tester.view
        ..physicalSize = const Size(1200, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloorView(api: api, onTable: (plan, table) {}, now: () => five),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      live.hello();
      live.beats();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.live.isLive, isTrue);
      expect(mark('A8'), findsNothing);

      hub.bookings!.add(Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A8'));
      live.changed(topics: ['reservations']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // told reads are a second apart at the least
      await tester.pump();
      await tester.pump();
      expect(markSays(tester, 'A8'), '18:30');
      // and it goes when the party sat down somewhere, or the reservation was taken out of the book
      hub.bookings!.single['status'] = 'cancelled';
      live.changed(topics: ['reservations']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      expect(mark('A8'), findsNothing);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('on a phone, with large type, in the dark: the booked tables are drawn and nothing runs over', (
      tester,
    ) async {
      final hub = Hub()
        ..floor = floorJson()
        ..bookings = [
          Hub.booking('b2', 'Featherstonehaugh', 12, time: '18:30', table: 'A8'),
          Hub.booking('b3', 'Garcia', 2, time: '17:10', table: 'A7'),
          Hub.booking('b1', 'Okafor', 6, time: '16:00', table: 'K1', arrivedMs: at(16, 50)),
        ];
      final api = PosApi(
        Settings(device: 't1', endpoints: ['http://hub:8000']),
        client: MockClient(hub.handle),
      );
      tester.view
        ..physicalSize = const Size(320, 640)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: PosTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: FloorView(api: api, onTable: (plan, table) {}, now: () => five),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect([markSays(tester, 'A8'), markSays(tester, 'A7'), markSays(tester, 'K1')], ['18:30', '17:10', 'here']);
      expect(key('legend-booked'), findsNothing); // the row under the map is full on a phone
      await stop(tester);
    });
  });

  group('the question', () {
    testWidgets('a party walking in to a booked table is asked about: Seat seats the party it is booked for', (
      tester,
    ) async {
      final t = await pumpFloor(tester, amy, bookings: [bookedIn('b2', 'Chen', 4, 25, 'A8')]);
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('A8 is booked'), findsOneWidget);
      expect(tester.widget<Text>(key('booked-for:b2')).data, 'Chen, party of 4');
      expect(tester.widget<Text>(key('booked-when:b2')).data, 'in 25 min');
      expect(find.text('Seat A8'), findsNothing); // nobody is seated before the answer

      await tapKey(tester, 'booked-seat:b2');
      expect(find.text('Seat Chen at A8'), findsOneWidget);
      expect(find.text('4 guests'), findsOneWidget); // as the book has them
      await tapKey(tester, 'seat');
      final (orderId, data) = sentOne(t.hub, 'create');
      expect(data, {'table': 'A8', 'guests': 4, 'order_type': 'dine_in', 'server': 'Amy', 'server_id': 's1'});
      // the book is told, as when the party is seated out of the book
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b2/seat');
      expect(t.hub.bookPosts.single.$2, {'staff_id': 's1', 'table': 'A8', 'order_id': orderId});
      expect(t.hub.bookings!.single['status'], 'seated');
      expect(find.byType(OrderScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(key('seating-party-bar'), findsNothing);
      expect(mark('A8'), findsNothing); // the table is theirs now, and kept for nobody
      await stop(tester);
    });

    testWidgets('Seat a walk-in goes on: the table is seated and the reservation keeps standing', (tester) async {
      final t = await pumpFloor(tester, holly, bookings: [bookedIn('b2', 'Chen', 4, 25, 'A8')]);
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: key('booked-anyway'), matching: find.text('Seat a walk-in')), findsOneWidget);
      await tapKey(tester, 'booked-anyway');
      expect(find.text('Seat A8'), findsOneWidget); // the question a free table always asks
      await tester.tap(find.widgetWithText(ActionChip, '2'));
      await tester.pump();
      await tester.tap(key('server:s1'));
      await tester.pump();
      await tapKey(tester, 'seat');
      expect(sentOne(t.hub, 'create').$2, {
        'table': 'A8',
        'guests': 2,
        'order_type': 'dine_in',
        'server': 'Amy',
        'server_id': 's1',
        ...byHolly,
      });
      expect(t.hub.bookPosts, isEmpty);
      expect(t.hub.bookings!.single['status'], 'booked');
      expect(markSays(tester, 'A8'), isNotNull); // seated by somebody else, and still booked
      await stop(tester);
    });

    testWidgets('Cancel leaves the table alone', (tester) async {
      final t = await pumpFloor(tester, amy, bookings: [bookedIn('b2', 'Chen', 4, 25, 'A8')]);
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booked-cancel');
      expect(find.text('A8 is booked'), findsNothing);
      expect(find.text('Seat A8'), findsNothing);
      expect(t.hub.sent, isEmpty);
      expect(t.hub.bookPosts, isEmpty);
      await stop(tester);
    });

    testWidgets('a table booked for hours from now, or let go, and a table nobody booked, ask nothing', (tester) async {
      await pumpFloor(
        tester,
        amy,
        bookings: [
          bookedIn('b2', 'Chen', 4, 120, 'A8'), // two hours ahead: a party sat now is gone by then
          bookedIn('b1', 'Okafor', 6, -95, 'A9'), // never came
        ],
      );
      expect(markSays(tester, 'A8'), isNotNull); // the map says it is booked all the same
      expect(mark('A9'), findsNothing);
      for (final table in ['A8', 'A9', 'B5']) {
        await tester.tap(find.text(table));
        await tester.pumpAndSettle();
        expect(find.text('$table is booked'), findsNothing);
        expect(find.text('Seat $table'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      await stop(tester);
    });

    testWidgets('a party that is late is still asked about, and a table kept for two names both', (tester) async {
      await pumpFloor(
        tester,
        amy,
        bookings: [bookedIn('b2', 'Chen', 4, 60, 'A8'), bookedIn('b1', 'Okafor', 6, -20, 'A8')],
      );
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('booked-when:b1')).data, '20 min ago');
      expect(tester.widget<Text>(key('booked-when:b2')).data, anyOf('in 1 h', 'in 59 min'));
      // the earlier one first, each with its own Seat
      expect(tester.getTopLeft(key('booked-for:b1')).dy, lessThan(tester.getTopLeft(key('booked-for:b2')).dy));
      expect(key('booked-seat:b1'), findsOneWidget);
      expect(key('booked-seat:b2'), findsOneWidget);
      await tapKey(tester, 'booked-seat:b2');
      expect(find.text('Seat Chen at A8'), findsOneWidget); // asked once: not again for Okafor
      expect(find.text('A8 is booked'), findsNothing);
      await stop(tester);
    });

    testWidgets('a party off the waitlist is asked about at a table booked for somebody else, with no other '
        'party to pick', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final t = await pumpFloor(
        tester,
        amy,
        bookings: [bookedIn('b2', 'Chen', 4, 25, 'A8')],
        parties: [Hub.waitParty('p1', 'Garcia', 2, atMs: now - 10 * minute, quoted: 20)],
      );
      await seatFromList(tester, 'p1');
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('A8 is booked'), findsOneWidget);
      expect(key('booked-seat:b2'), findsNothing);
      expect(find.descendant(of: key('booked-anyway'), matching: find.text('Seat Garcia here')), findsOneWidget);
      // thought better of: Garcia is still being seated, and another table can be tapped
      await tapKey(tester, 'booked-cancel');
      expect(key('seating-party-bar'), findsOneWidget);
      expect(t.hub.sent, isEmpty);
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booked-anyway');
      expect(find.text('Seat Garcia at A8'), findsOneWidget);
      await tapKey(tester, 'seat');
      expect(sentOne(t.hub, 'create').$2['table'], 'A8');
      expect(t.hub.waitPosts.single.$1, 'POST /waitlist/p1/seat');
      expect(t.hub.bookings!.single['status'], 'booked'); // Chen's reservation stands
      await stop(tester);
    });

    testWidgets('the booked party itself is seated at its table with no question; at another party\'s it is asked', (
      tester,
    ) async {
      final t = await pumpFloor(
        tester,
        amy,
        bookings: [bookedIn('b2', 'Chen', 4, 25, 'A8'), bookedIn('b3', 'Garcia', 2, 40, 'A9')],
      );
      await tapKey(tester, 'waitlist-open');
      await tapKey(tester, 'waitlist-reservations');
      await tapKey(tester, 'booking-seat:b2');
      await tester.tap(find.text('A9')); // Garcia's
      await tester.pumpAndSettle();
      expect(find.text('A9 is booked'), findsOneWidget);
      expect(find.descendant(of: key('booked-anyway'), matching: find.text('Seat Chen here')), findsOneWidget);
      await tapKey(tester, 'booked-cancel');
      await tester.tap(find.text('A8')); // their own
      await tester.pumpAndSettle();
      expect(find.text('A8 is booked'), findsNothing);
      expect(find.text('Seat Chen at A8'), findsOneWidget);
      await tapKey(tester, 'seat');
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b2/seat');
      await stop(tester);
    });

    testWidgets('a check moved to a booked table is asked about', (tester) async {
      final t = await pumpFloor(tester, amy, bookings: [bookedIn('b2', 'Chen', 4, 25, 'A8')]);
      await tester.longPress(find.text('A7'));
      await tester.pumpAndSettle();
      expect(find.text('Moving A7. Tap the table it goes to.'), findsOneWidget);
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('A8 is booked'), findsOneWidget);
      expect(key('booked-seat:b2'), findsNothing);
      expect(find.descendant(of: key('booked-anyway'), matching: find.text('Move A7 here')), findsOneWidget);
      await tapKey(tester, 'booked-cancel');
      expect(t.hub.sent, isEmpty);
      expect(find.text('Moving A7. Tap the table it goes to.'), findsOneWidget); // still moving
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booked-anyway');
      expect(sentTo(t.hub), [
        [
          'o1',
          'set_field',
          {'table': 'A8', ...byAmy},
        ],
      ]);
      expect(find.text('A7 moved to A8'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a bar tab seated at a booked table is asked about', (tester) async {
      final t = await pumpSeating(
        tester,
        amy,
        hub: (hub) => hub
          ..clockNow = DateTime.now().millisecondsSinceEpoch
          ..bookings = [bookedIn('b2', 'Chen', 4, 25, 'A8')],
      );
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('A8 is booked'), findsOneWidget);
      expect(find.descendant(of: key('booked-anyway'), matching: find.text("Seat Linda's tab here")), findsOneWidget);
      await tapKey(tester, 'booked-anyway');
      expect(find.text("Seat Linda's tab at A8"), findsOneWidget);
      expect(t.hub.sent, isEmpty);
      await stop(tester);
    });

    testWidgets('a table that is seated opens its check, booked or not', (tester) async {
      final t = await pumpFloor(tester, amy, bookings: [bookedIn('b2', 'Chen', 4, 25, 'A7')]);
      t.hub.orders.add(checkAt('o1', 'A7', {'M1': line('Egg roll', rank: 1)}, guests: 4));
      expect(markSays(tester, 'A7'), isNotNull);
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      expect(find.text('A7 is booked'), findsNothing);
      expect(find.byType(OrderScreen), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a 320-wide phone with large type: the question fits, with a long name and two parties', (
      tester,
    ) async {
      await pumpFloor(
        tester,
        holly,
        size: const Size(320, 640),
        bookings: [
          bookedIn('b2', 'Bartholomew-Featherstone', 12, 25, 'A8'),
          bookedIn('b1', 'Okafor', 6, -20, 'A8', arrivedMs: DateTime.now().millisecondsSinceEpoch - 5 * minute),
        ],
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('A8 is booked'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final screen = tester.getRect(find.byType(Scaffold).first);
      for (final name in ['booked-seat:b1', 'booked-seat:b2', 'booked-anyway', 'booked-cancel']) {
        final button = tester.getRect(key(name));
        expect(
          button.left >= screen.left && button.right <= screen.right && button.bottom <= screen.bottom,
          isTrue,
          reason: '$name $button',
        );
      }
      expect(tester.widget<Text>(key('booked-when:b1')).data, startsWith('here since '));
      await stop(tester);
    });
  });
}
