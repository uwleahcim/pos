import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/reservations.dart';
import 'package:pos_app/screens/reservations_screen.dart';
import 'package:pos_app/screens/waitlist_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'table_moves_test.dart' show floorThatMoves;
import 'table_servers_test.dart' show amy, holly, mike;

/// Today's booked tables on the waitlist's button (the Toast comparison's row 15, the last of it): the
/// tables booked for today that are still to sit down are counted under the parties waiting, amber when one
/// is near its time and red when one is past it; a phone's menu says the count, and the waitlist says how
/// many and which is next, with the way to the book.

const minute = 60000;
const mon = '2026-11-16', tue = '2026-11-17';

/// Seven in the evening on the hub's clock, for the tests that pump the waitlist by itself.
final seven = DateTime(2026, 11, 16, 19).millisecondsSinceEpoch;

/// Chen in an hour at A8 and Okafor in two, with Garcia booked for tomorrow.
List<Map<String, dynamic>> twoAhead(int now) => [
  Hub.booking('b1', 'Chen', 4, time: '18:30', atMs: now + 60 * minute, table: 'A8'),
  Hub.booking('b2', 'Okafor', 6, time: '19:30', atMs: now + 120 * minute),
  Hub.booking('b3', 'Garcia', 2, day: tue, time: '18:00', atMs: now + 24 * 60 * minute),
];

List<Map<String, dynamic>> twoWaiting(int now) => [
  Hub.waitParty('p1', 'Silva', 2, atMs: now - 5 * minute, quoted: 20),
  Hub.waitParty('p2', 'Lee', 3, atMs: now - 2 * minute, quoted: 20),
];

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

String words(WidgetTester tester, String name) => tester.widget<Text>(key(name)).data!;

/// The number on the mark of booked tables, under the waitlist's button.
String marked(WidgetTester tester, String level) =>
    tester.widget<Text>(find.descendant(of: key('waitlist-booked:$level'), matching: find.byType(Text))).data!;

/// The orders screen of [who], the clock of the hub and of the screen reading now, on a hub with a waitlist
/// ([parties], nobody unless said) and a book ([bookings], [twoAhead] unless said).
Future<Terminal> pumpFloor(
  WidgetTester tester,
  Staff who, {
  List<Map<String, dynamic>> Function(int now)? parties,
  List<Map<String, dynamic>>? Function(int now) bookings = twoAhead,
  Size? size,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.session.staff = who;
  final now = DateTime.now().millisecondsSinceEpoch;
  t.hub
    ..clockNow = now
    ..floor = floorThatMoves()
    ..parties = (parties ?? (_) => <Map<String, dynamic>>[])(now)
    ..bookings = bookings(now);
  await pumpOrdersOn(tester, t);
  return t;
}

/// The waitlist by itself, at seven, on a hub with the book [bookings] (none: a hub older than the book).
Future<(Terminal, List<Object?>)> pumpList(
  WidgetTester tester, {
  List<Map<String, dynamic>>? bookings,
  List<Map<String, dynamic>>? parties,
  Size size = const Size(1100, 800),
  double textScale = 1,
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.session.staff = holly;
  t.hub
    ..clockNow = seven
    ..parties = parties ?? []
    ..bookings = bookings;
  final popped = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => popped.add(
                await Navigator.of(context).push<Object?>(
                  MaterialPageRoute(
                    builder: (_) => WaitlistScreen(api: t.api, staffId: holly.staffId, nowMs: () => seven),
                  ),
                ),
              ),
              child: const Text('open the list'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open the list'));
  await tester.pumpAndSettle();
  return (t, popped);
}

/// Tonight's book for the waitlist by itself: Chen at half past seven at A8, Okafor at eight.
List<Map<String, dynamic>> tonight() => [
  Hub.booking('b1', 'Chen', 4, time: '19:30', table: 'A8'),
  Hub.booking('b2', 'Okafor', 6, time: '20:00'),
];

void main() {
  group('the words', () {
    test('how many booked tables are still to come', () {
      expect(bookedToComeWords(1), '1 booked table to come');
      expect(bookedToComeWords(5), '5 booked tables to come');
    });

    test('the next one: its time first, then who and how many, and the table held', () {
      Booking of(Map<String, dynamic> json) => Booking.fromJson(json);
      final at = Hub.bookedAt(mon, '18:30');
      final chen = of(Hub.booking('b1', 'Chen', 4, time: '18:30', table: 'A8'));
      expect(nextBookedWords(chen, at - 60 * minute), 'Next at 18:30: Chen, 4 guests · table A8');
      expect(nextBookedWords(chen, at - 5 * minute), 'Next at 18:30: Chen, 4 guests · table A8');
      expect(nextBookedWords(chen, at + 5 * minute), 'Next at 18:30: Chen, 4 guests · table A8');
      // a quarter of an hour past its time with nobody seated, it is due
      expect(nextBookedWords(chen, at + 15 * minute), 'Due since 18:30: Chen, 4 guests · table A8');
      // no table held, and a party of one
      final lee = of(Hub.booking('b2', 'Lee', 1, time: '18:30'));
      expect(nextBookedWords(lee, at - minute), 'Next at 18:30: Lee, 1 guest');
      // a party that came in and waits for its table is here, however late the hour
      final here = of(Hub.booking('b3', 'Okafor', 6, time: '18:30', arrivedMs: at - 2 * minute));
      expect(nextBookedWords(here, at - minute), 'Here for 18:30: Okafor, 6 guests');
      expect(nextBookedWords(here, at + 40 * minute), 'Here for 18:30: Okafor, 6 guests');
    });

    test('only the book of today has tables to come', () {
      final hub = Hub()
        ..bookings = [
          Hub.booking('b1', 'Chen', 4, time: '18:30'),
          Hub.booking('b2', 'Okafor', 6, time: '17:00'),
          Hub.booking('b3', 'Garcia', 2, day: tue, time: '18:00'),
          Hub.booking('b4', 'Silva', 2, time: '12:00')
            ..['status'] = 'seated'
            ..['seated_ms'] = 1,
        ];
      final today = Book.fromJson(hub.bookFor(mon));
      expect([for (final b in today.toCome) b.name], ['Okafor', 'Chen']); // the earliest first, the seated one not
      final tomorrow = Book.fromJson(hub.bookFor(tue));
      expect(tomorrow.booked.single.name, 'Garcia');
      expect(tomorrow.toCome, isEmpty);
      expect(const Book().toCome, isEmpty);
    });
  });

  group('on the waitlist\'s button', () {
    testWidgets('the tables booked for today that are still to come are counted under the button', (tester) async {
      final t = await pumpFloor(tester, mike);
      expect(marked(tester, 'ok'), '2'); // Garcia is tomorrow's
      // nobody waits: the round badge has no number, and the button says what the square one counts
      expect(find.byTooltip('Waitlist · 2 booked tables to come'), findsOneWidget);
      expect(find.descendant(of: key('waitlist-badge:ok'), matching: find.text('2')), findsOneWidget);
      expect(find.descendant(of: key('waitlist-open'), matching: find.byType(Text)), findsOneWidget);
      expect(t.hub.bookAsks, contains(null)); // today's book was asked for
      expect(t.hub.bookPosts, isEmpty);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('with parties waiting the button carries both numbers', (tester) async {
      await pumpFloor(tester, mike, parties: twoWaiting);
      expect(find.byTooltip('Waitlist: 2 waiting · 2 booked tables to come'), findsOneWidget);
      expect(marked(tester, 'ok'), '2');
      expect(find.descendant(of: key('waitlist-open'), matching: find.text('2')), findsNWidgets(2));
      // the square mark sits under the round one
      final both = find.descendant(of: key('waitlist-open'), matching: find.text('2'));
      final heights = [tester.getCenter(both.at(0)).dy, tester.getCenter(both.at(1)).dy]..sort();
      final square = tester.getCenter(key('waitlist-booked:ok')).dy;
      expect((square - heights.last).abs() < 2, isTrue, reason: '$heights $square');
      expect(heights.last - heights.first > 8, isTrue, reason: '$heights');
      await stop(tester);
    });

    testWidgets('amber when a booked table is near its time, red when one is past it with nobody seated', (
      tester,
    ) async {
      await pumpFloor(
        tester,
        mike,
        bookings: (now) => [
          Hub.booking('b1', 'Chen', 4, time: '18:30', atMs: now + 10 * minute),
          Hub.booking('b2', 'Okafor', 6, time: '19:30', atMs: now + 70 * minute),
        ],
      );
      expect(marked(tester, 'warn'), '2');
      expect(key('waitlist-badge:ok'), findsOneWidget); // nobody on the waitlist is late
      await stop(tester);

      await pumpFloor(
        tester,
        mike,
        bookings: (now) => [
          Hub.booking('b1', 'Chen', 4, time: '18:30', atMs: now - 20 * minute),
          Hub.booking('b2', 'Okafor', 6, time: '19:30', atMs: now + 40 * minute),
        ],
      );
      expect(marked(tester, 'late'), '2');
      await stop(tester);
    });

    testWidgets('a table that sat down or was called off is not to come, and with none there is no mark', (
      tester,
    ) async {
      await pumpFloor(
        tester,
        mike,
        bookings: (now) => [
          Hub.booking('b1', 'Chen', 4, time: '18:30', atMs: now - 30 * minute)
            ..['status'] = 'seated'
            ..['seated_ms'] = now - 25 * minute,
          Hub.booking('b2', 'Okafor', 6, time: '19:30', atMs: now - 40 * minute)
            ..['status'] = 'no_show'
            ..['ended_ms'] = now - 5 * minute,
          Hub.booking('b3', 'Garcia', 2, day: tue, time: '18:00', atMs: now + 24 * 60 * minute),
        ],
      );
      expect(key('waitlist-open'), findsOneWidget);
      expect(find.byTooltip('Waitlist'), findsOneWidget);
      expect(find.descendant(of: key('waitlist-open'), matching: find.byType(Text)), findsNothing);
      await stop(tester);
    });

    testWidgets('a hub older than the book leaves the button as it was', (tester) async {
      final t = await pumpFloor(tester, mike, parties: twoWaiting, bookings: (_) => null);
      expect(find.byTooltip('Waitlist: 2 waiting'), findsOneWidget);
      expect(find.descendant(of: key('waitlist-open'), matching: find.byType(Text)), findsOneWidget);
      expect(t.hub.requests.where((r) => r.startsWith('GET /reservations')), isNotEmpty); // it asked
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a reservation called off in the book is off the count the moment the book is left', (tester) async {
      final t = await pumpFloor(tester, holly);
      expect(marked(tester, 'ok'), '2');
      await tapKey(tester, 'waitlist-open');
      await tapKey(tester, 'waitlist-booked'); // the row of the waitlist leads to the book
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(find.byType(WaitlistScreen), findsNothing);
      await tester.tap(find.text('Okafor'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-do:cancel');
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b2/cancel');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ReservationsScreen), findsNothing);
      expect(marked(tester, 'ok'), '1');
      expect(find.byTooltip('Waitlist · 1 booked table to come'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('on a phone the menu says how many are to come, and the bar keeps its room', (tester) async {
      const phone = Size(390, 800);
      // a server with nobody waiting: no button for booked tables alone, the count is on the menu's row
      await pumpFloor(tester, amy, size: phone);
      expect(key('waitlist-open'), findsNothing);
      await openMore(tester);
      expect(homeTile('waitlist'), findsOneWidget);
      expect(find.descendant(of: homeTile('reservations'), matching: find.text('2 to come')), findsOneWidget);
      expect(key('home-count:reservations:ok'), findsOneWidget);
      await tester.tap(homeTile('reservations'));
      await tester.pumpAndSettle();
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);

      // nothing booked for today: the tile has its name and no count
      await pumpFloor(tester, amy, size: phone, bookings: (_) => []);
      await openMore(tester);
      expect(find.descendant(of: homeTile('reservations'), matching: find.byType(Text)), findsOneWidget);
      await stop(tester);

      // the host's button, and everybody's while a party waits, carries the mark
      await pumpFloor(tester, holly, size: phone);
      expect(marked(tester, 'ok'), '2');
      expect(tester.takeException(), isNull);
      await stop(tester);
      await pumpFloor(tester, amy, size: phone, parties: twoWaiting);
      expect(marked(tester, 'ok'), '2');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a 320-wide phone with large text: the button with both numbers stays on the screen', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpFloor(
        tester,
        holly,
        size: const Size(320, 640),
        parties: twoWaiting,
        bookings: (now) => [
          for (var i = 0; i < 12; i++) Hub.booking('b$i', 'Party $i', 4, time: '19:00', atMs: now + (30 + i) * minute),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(marked(tester, 'ok'), '12');
      final mark = tester.getRect(key('waitlist-booked:ok'));
      expect(mark.left >= 0 && mark.right <= 320 && mark.top >= 0, isTrue, reason: '$mark');
      // across the icon from the round badge: the two numbers do not meet, large type or not
      final round = tester.getRect(find.descendant(of: key('waitlist-open'), matching: find.text('2')));
      expect(mark.overlaps(round), isFalse, reason: '$mark $round');
      await stop(tester);
    });
  });

  group('on the waitlist', () {
    testWidgets('a row says how many booked tables are to come and which is next, and leads to the book', (
      tester,
    ) async {
      final (t, popped) = await pumpList(tester, bookings: tonight());
      expect(words(tester, 'waitlist-booked-count'), '2 booked tables to come');
      expect(words(tester, 'waitlist-booked-next'), 'Next at 19:30: Chen, 4 guests · table A8');
      // above whoever waits, and above the word that nobody does
      expect(tester.getTopLeft(key('waitlist-booked')).dy < tester.getTopLeft(key('waitlist-empty')).dy, isTrue);
      expect(t.hub.bookAsks, [null]);
      await tapKey(tester, 'waitlist-booked');
      expect(popped.single, isA<OpenReservations>());
      expect(t.hub.bookPosts, isEmpty);
      expect(t.hub.waitPosts, isEmpty);
    });

    testWidgets('the next one is said as it stands: here, or due since its time', (tester) async {
      await pumpList(
        tester,
        bookings: [
          Hub.booking('b1', 'Chen', 4, time: '18:40'), // twenty minutes ago
          Hub.booking('b2', 'Okafor', 6, time: '20:00'),
        ],
      );
      expect(words(tester, 'waitlist-booked-next'), 'Due since 18:40: Chen, 4 guests');
      await stop(tester);

      await pumpList(
        tester,
        bookings: [Hub.booking('b1', 'Chen', 4, time: '18:40', arrivedMs: seven - 3 * minute)],
      );
      expect(words(tester, 'waitlist-booked-count'), '1 booked table to come');
      expect(words(tester, 'waitlist-booked-next'), 'Here for 18:40: Chen, 4 guests');
      await stop(tester);
    });

    testWidgets('no row with nothing booked for today, and none from a hub older than the book', (tester) async {
      await pumpList(
        tester,
        bookings: [Hub.booking('b3', 'Garcia', 2, day: tue, time: '18:00')],
      );
      expect(key('waitlist-booked'), findsNothing);
      expect(key('waitlist-empty'), findsOneWidget);
      await stop(tester);

      final (t, _) = await pumpList(tester);
      expect(key('waitlist-booked'), findsNothing);
      expect(key('waitlist-empty'), findsOneWidget);
      expect(key('waitlist-older'), findsNothing); // the waitlist itself works as before
      expect(t.hub.requests.where((r) => r.startsWith('GET /reservations')), isNotEmpty);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a book that cannot be read leaves the waitlist working', (tester) async {
      final (t, _) = await pumpList(
        tester,
        bookings: tonight(),
        parties: [Hub.waitParty('p1', 'Silva', 2, atMs: seven - 5 * minute, quoted: 20)],
      );
      expect(key('waitlist-booked'), findsOneWidget);
      await stop(tester);

      final t2 = await terminal(tester);
      tester.view.physicalSize = const Size(1100, 800);
      t2.hub
        ..clockNow = seven
        ..parties = [Hub.waitParty('p1', 'Silva', 2, atMs: seven - 5 * minute, quoted: 20)]
        ..bookings = tonight()
        ..bookDown = true;
      await tester.pumpWidget(
        MaterialApp(
          home: WaitlistScreen(api: t2.api, staffId: holly.staffId, nowMs: () => seven),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('waitlist-booked'), findsNothing);
      expect(key('waitlist-away'), findsNothing);
      expect(find.text('Silva'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(t.hub.bookPosts, isEmpty);
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
        ..clockNow = seven
        ..parties = []
        ..bookings = [Hub.booking('b2', 'Okafor', 6, time: '20:00')];
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: WaitlistScreen(api: api, staffId: 's4', nowMs: () => seven),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      expect(api.live.isLive, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(words(tester, 'waitlist-booked-count'), '1 booked table to come');
      expect(words(tester, 'waitlist-booked-next'), 'Next at 20:00: Okafor, 6 guests');

      hub.bookings!.add(Hub.booking('b1', 'Chen', 4, time: '19:30', table: 'A8'));
      live.changed(topics: ['reservations']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // told reads are a second apart at the least
      await tester.pumpAndSettle();
      expect(words(tester, 'waitlist-booked-count'), '2 booked tables to come');
      expect(words(tester, 'waitlist-booked-next'), 'Next at 19:30: Chen, 4 guests · table A8');
      // and it goes with the last of them
      for (final b in hub.bookings!) {
        b['status'] = 'cancelled';
        b['ended_ms'] = seven;
      }
      live.changed(topics: ['reservations']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(key('waitlist-booked'), findsNothing);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('a 320-wide phone with large text: the row fits, on a second line before anything is cut', (
      tester,
    ) async {
      await pumpList(
        tester,
        size: const Size(320, 640),
        textScale: 1.3,
        bookings: [
          Hub.booking('b1', 'Bartholomew-Fitzgerald', 12, time: '19:30', table: 'A8'),
          for (var i = 2; i < 12; i++) Hub.booking('b$i', 'Party $i', 4, time: '20:00'),
        ],
        parties: [Hub.waitParty('p1', 'Silva', 2, atMs: seven - 5 * minute, quoted: 20)],
      );
      expect(tester.takeException(), isNull);
      expect(words(tester, 'waitlist-booked-count'), '11 booked tables to come');
      expect(words(tester, 'waitlist-booked-next'), startsWith('Next at 19:30: Bartholomew-Fitzgerald, 12 guests'));
      final row = tester.getRect(key('waitlist-booked'));
      expect(row.left >= 0 && row.right <= 320, isTrue, reason: '$row');
      // two lines at the most, and the whole of it is inside the row
      final next = tester.getRect(key('waitlist-booked-next'));
      expect(next.height < 60 && next.right <= row.right && next.bottom <= row.bottom, isTrue, reason: '$next');
      await stop(tester);
    });
  });
}
