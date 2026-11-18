import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/reservations.dart';
import 'package:pos_app/screens/booking_dialog.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/reservations_screen.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/screens/waitlist_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'table_moves_test.dart' show byHolly, byMike, checkAt, floorThatMoves, sentTo;
import 'table_servers_test.dart' show amy, holly, mike, sentOne;

/// Reservations (the Toast comparison's row 15): the tables booked for a day, in the order of their times. A
/// table is booked with a name, a size, a day and a time; a party of today sits down at a table tapped on
/// the floor map; a reservation is cancelled or marked a no-show, and one taken out by mistake is put back.

const minute = 60000;
const mon = '2026-11-16', tue = '2026-11-17', sat = '2026-11-21';

/// Five in the afternoon on the hub's clock, on Monday 16 November 2026.
final five = DateTime(2026, 11, 16, 17).millisecondsSinceEpoch;

/// Monday: Okafor at 17:30 at B5, Chen at 18:30 at A7 with a note and a number, Garcia at 19:15 at A7 too
/// (three quarters of an hour after Chen). Tuesday: Silva at 18:00. Saturday: Nguyen at 12:00, Park at 19:00.
List<Map<String, dynamic>> week() => [
  Hub.booking('b2', 'Chen', 4, time: '18:30', table: 'A7', phone: '781 555 0101', note: 'Birthday'),
  Hub.booking('b1', 'Okafor', 6, time: '17:30', table: 'B5', by: 'Amy'),
  Hub.booking('b3', 'Garcia', 2, time: '19:15', table: 'A7'),
  Hub.booking('b4', 'Silva', 2, day: tue, time: '18:00'),
  Hub.booking('b5', 'Nguyen', 8, day: sat, time: '12:00'),
  Hub.booking('b6', 'Park', 4, day: sat, time: '19:00', table: 'A8'),
];

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

/// The names of the reservations standing on the screen, top to bottom.
List<String> standing(WidgetTester tester) {
  final cards = find.byWidgetPredicate(
    (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('booking:'),
  );
  final rows = [
    for (final element in cards.evaluate())
      (
        tester.getTopLeft(find.byWidget(element.widget)).dy,
        tester
            .widget<Text>(find.descendant(of: find.byWidget(element.widget), matching: find.byType(Text)).at(1))
            .data!,
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final row in rows) row.$2];
}

/// The words on the chips of the day strip, left to right.
List<String> days(WidgetTester tester) => [
  for (final chip in tester.widgetList<ChoiceChip>(
    find.descendant(of: key('book-days'), matching: find.byType(ChoiceChip)),
  ))
    (chip.label as Text).data!,
];

/// The colour behind a reservation's time.
Color? pill(WidgetTester tester, String id) =>
    (tester.widget<Container>(key('booking-time:$id')).decoration! as BoxDecoration).color;

/// The book by itself, for [who], on a hub whose clock (and the screen's) reads [now].
Future<(Terminal, List<Object?>)> pumpBook(
  WidgetTester tester, {
  Staff who = holly,
  List<Map<String, dynamic>>? bookings,
  int Function()? now,
  Size size = const Size(1100, 800),
  bool older = false,
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.session.staff = who;
  t.hub
    ..clockNow = (now ?? () => five)()
    ..floor = floorThatMoves();
  if (!older) t.hub.bookings = bookings ?? week();
  final popped = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => popped.add(
                await Navigator.of(context).push<Object?>(
                  MaterialPageRoute(
                    builder: (_) => ReservationsScreen(api: t.api, staffId: who.staffId, nowMs: now ?? () => five),
                  ),
                ),
              ),
              child: const Text('open the book'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open the book'));
  await tester.pumpAndSettle();
  return (t, popped);
}

/// What a change to the book carried, without who made it.
Map<String, dynamic> carried(Hub hub, [int at = -1]) {
  final (_, body) = at < 0 ? hub.bookPosts.last : hub.bookPosts[at];
  return {...body}..remove('staff_id');
}

/// A time is picked off the grid, which is scrolled to it first: the grid opens near the time picked before
/// (five in the afternoon when there is none), so an earlier time is above what it shows.
Future<void> pickTime(WidgetTester tester, String time) async {
  await tapKey(tester, 'booking-time');
  final shown = [
    for (final element
        in find
            .byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('time:'))
            .evaluate())
      serviceMinute('${(element.widget.key! as ValueKey).value}'.substring(5))!,
  ];
  final above = shown.isNotEmpty && shown.every((minute) => minute > serviceMinute(time)!);
  await tester.scrollUntilVisible(
    key('time:$time'),
    above ? -80 : 80,
    scrollable: find.descendant(of: key('time-grid'), matching: find.byType(Scrollable)),
  );
  await tester.pumpAndSettle(); // the grid is laid out where it was scrolled to
  await tapKey(tester, 'time:$time');
}

/// A button further down a form that scrolls on a small screen is brought up and tapped.
Future<void> reachKey(WidgetTester tester, String name) async {
  await tester.ensureVisible(key(name));
  await tester.pumpAndSettle();
  await tapKey(tester, name);
}

/// The orders screen of [who] on a hub that keeps a reservation book and a waitlist with nobody on it.
Future<Terminal> pumpFloorWith(
  WidgetTester tester,
  Staff who, {
  List<Map<String, dynamic>>? bookings,
  Size? size,
  void Function(Hub hub)? hub,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.session.staff = who;
  t.hub
    ..clockNow = DateTime.now().millisecondsSinceEpoch
    ..floor = floorThatMoves()
    ..parties = []
    ..bookings = bookings ?? week();
  hub?.call(t.hub);
  await pumpOrdersOn(tester, t);
  return t;
}

/// The book is opened from the floor by way of the waitlist, and Seat is tapped on [booking].
Future<void> seatFromBook(WidgetTester tester, String booking) async {
  await tapKey(tester, 'waitlist-open');
  await tapKey(tester, 'waitlist-reservations');
  expect(find.byType(ReservationsScreen), findsOneWidget);
  expect(find.byType(WaitlistScreen), findsNothing);
  await tapKey(tester, 'booking-seat:$booking');
  expect(find.byType(ReservationsScreen), findsNothing);
}

Finder seatingBar() => key('seating-party-bar');

void main() {
  group('the words', () {
    Booking booked(String time, {String day = mon, String table = ''}) =>
        Booking.fromJson(Hub.booking('b', 'Chen', 4, day: day, time: time, table: table));

    test('a time is plain until a quarter of an hour before it, amber then, and red a quarter after', () {
      final chen = booked('18:30');
      final at = DateTime(2026, 11, 16, 18, 30).millisecondsSinceEpoch;
      expect(chen.atMs, at);
      expect(chen.levelAt(at - 16 * minute), TimerLevel.ok);
      expect(chen.levelAt(at - 15 * minute), TimerLevel.warn);
      expect(chen.levelAt(at + 14 * minute), TimerLevel.warn);
      expect(chen.levelAt(at + 15 * minute), TimerLevel.late);
      expect(chen.label, 'Chen, party of 4');
      expect((chen.isBooked, chen.isSeated, chen.isHere), (true, false, false));
    });

    test('only today\'s book has a colour, and its next change is the nearest time that is near or past', () {
      final today = Book(day: mon, today: mon, booked: [booked('18:30'), booked('17:30')]);
      final at = DateTime(2026, 11, 16, 17, 30).millisecondsSinceEpoch;
      expect(today.levelAt(at - 20 * minute), TimerLevel.ok);
      expect(today.levelAt(at), TimerLevel.warn);
      expect(today.levelAt(at + 15 * minute), TimerLevel.late);
      expect(today.nextChange(at - 20 * minute), at - 15 * minute);
      expect(today.nextChange(at), at + 15 * minute);
      expect(today.nextChange(at + 100 * minute), isNull);
      final later = Book(
        day: sat,
        today: mon,
        booked: [booked('18:30', day: sat)],
      );
      expect(later.levelAt(at + 9999 * minute), TimerLevel.ok);
      expect(later.nextChange(0), isNull);
      expect((later.isToday, later.isOver, today.isToday), (false, false, true));
      expect(const Book(day: '2026-11-15', today: mon).isOver, isTrue);
    });

    test('a day in words, a time in its day of service, and how a day adds up', () {
      expect(bookDayWords(mon, mon), 'Today');
      expect(bookDayWords(tue, mon), 'Tomorrow');
      expect(bookDayWords('2026-11-15', mon), 'Yesterday');
      expect(bookDayWords(sat, mon), 'Sat 21 Nov');
      expect(bookDayWords('2027-01-01', '2026-12-31'), 'Tomorrow'); // over the turn of the year
      expect(bookDayWords('someday', mon), 'someday');
      // half past midnight comes after a quarter to twelve: it is the same night
      expect(serviceMinute('23:45')! < serviceMinute('00:30')!, isTrue);
      expect(serviceMinute('03:59')! > serviceMinute('23:59')!, isTrue);
      expect(serviceMinute('04:00')! < serviceMinute('06:00')!, isTrue);
      expect([serviceMinute('24:00'), serviceMinute('18'), serviceMinute('six')], [null, null, null]);
      expect(bookedWords(1, 1), '1 reservation · 1 guest');
      expect(bookedWords(3, 12), '3 reservations · 12 guests');
      expect(serviceHours.first, 6);
      expect(serviceHours.last, 3);
      expect(serviceHours.length, 22);
    });

    test('the hub\'s answer is read, and one this build does not know reads as an empty book', () {
      final hub = Hub()..bookings = week();
      hub.bookings![0].addAll({'arrived_ms': five});
      hub.bookings![1].addAll({
        'status': 'seated',
        'seated_ms': five,
        'seated_table': 'B6',
        'seated_label': 'B6',
        'order_id': 'o1',
        'ended_by': 'Holly',
      });
      final book = Book.fromJson({...hub.bookFor(mon), 'booking': hub.bookFor(mon)['booked'][1]});
      expect((book.day, book.today, book.isToday), (mon, mon, true));
      expect(
        [for (final b in book.booked) '${b.time} ${b.name} ${b.size} ${b.tableLabel}'],
        ['18:30 Chen 4 A7', '19:15 Garcia 2 A7'],
      );
      final chen = book.booked.first;
      expect(
        (chen.phone, chen.note, chen.by, chen.arrivedMs, chen.isHere),
        ('781 555 0101', 'Birthday', 'Holly', five, true),
      );
      expect((chen.clashName, chen.clashAtMs), ('Garcia', book.booked.last.atMs));
      final okafor = book.earlier.single;
      expect((okafor.status, okafor.seatedLabel, okafor.orderId, okafor.endedBy), ('seated', 'B6', 'o1', 'Holly'));
      expect(endedWords(okafor), 'Seated at B6');
      expect((okafor.clashName, okafor.clashAtMs), ('', null));
      expect((book.counts.booked, book.counts.guests, book.counts.seated), (2, 6, 1));
      expect(book.ahead, [
        (day: mon, parties: 2, guests: 6),
        (day: tue, parties: 1, guests: 2),
        (day: sat, parties: 2, guests: 12),
      ]);
      expect(
        (book.holdMinutes, book.mostGuests, book.mostAheadDays, book.nameMax, book.noteMax),
        (90, 60, 366, 24, 80),
      );
      expect(book.booking?.name, 'Garcia');

      final unknown = Book.fromJson({'booked': 'none', 'ahead': 7, 'counts': null});
      expect([unknown.booked.length, unknown.earlier.length, unknown.ahead.length], [0, 0, 0]);
      expect(unknown.booking, isNull);
      expect((unknown.holdMinutes, unknown.noteMax, unknown.counts.booked), (90, 80, 0));
    });

    test('tables are listed the way their names are read', () {
      TableSpot table(String label) => TableSpot(id: label, label: label, room: 'A', x: 0, y: 0, w: 1, h: 1, seats: 4);
      final sorted = [
        for (final label in ['B1', 'A10', 'A2', 'Bar 3', 'A1', 'Bar 12']) table(label),
      ]..sort(TablePicker.byName);
      expect([for (final t in sorted) t.label], ['A1', 'A2', 'A10', 'B1', 'Bar 3', 'Bar 12']);
    });
  });

  group('the book', () {
    testWidgets('today\'s tables stand in the order of their times, each with what the host should know', (
      tester,
    ) async {
      final (t, _) = await pumpBook(tester);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);
      expect(tester.widget<Text>(key('book-count')).data, 'Today, Mon 16 Nov · 3 reservations · 12 guests');
      expect(t.hub.bookAsks.first, isNull); // today's book is asked for as today's
      // the time, the table held, the note
      expect(find.descendant(of: key('booking-time:b2'), matching: find.text('18:30')), findsOneWidget);
      expect(tester.widget<Text>(key('booking-table:b2')).data, 'table A7');
      expect(find.descendant(of: key('booking:b2'), matching: find.text('Birthday')), findsOneWidget);
      // two reservations of one table close together say so, each of the other
      expect(tester.widget<Text>(key('booking-clash:b2')).data, 'A7 is also held for Garcia at 19:15');
      expect(tester.widget<Text>(key('booking-clash:b3')).data, 'A7 is also held for Chen at 18:30');
      expect(key('booking-clash:b1'), findsNothing);
      // the days: today and tomorrow, and each later day that has a table booked, with how many
      expect(days(tester), ['Today · 3', 'Tomorrow · 1', 'Sat 21 Nov · 2']);
      expect(tester.widget<ChoiceChip>(key('book-day:$mon')).selected, isTrue);
      // every reservation of today can be seated
      for (final id in ['b1', 'b2', 'b3']) {
        expect(key('booking-seat:$id'), findsOneWidget);
      }
      expect(key('book-earlier'), findsNothing);
      expect(key('booking-add'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('with no tables booked it says so', (tester) async {
      await pumpBook(tester, bookings: []);
      expect(find.text('No tables are booked for today.'), findsOneWidget);
      expect(tester.widget<Text>(key('book-count')).data, 'Today, Mon 16 Nov');
      expect(days(tester), ['Today', 'Tomorrow']);
      await tapKey(tester, 'book-day:$tue');
      expect(find.text('No tables are booked for tomorrow.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a time turns amber when it is near and red once it has passed, by the clock alone', (tester) async {
      var now = five;
      await pumpBook(tester, now: () => now);
      final scheme = Theme.of(tester.element(key('book'))).colorScheme;
      final pos = PosColors.of(tester.element(key('book')));
      expect(pill(tester, 'b1'), scheme.surfaceContainerHighest); // 17:30 is half an hour off
      now = five + 16 * minute;
      await tester.pump(const Duration(minutes: 16));
      expect(pill(tester, 'b1'), pos.timerWarn);
      expect(pill(tester, 'b2'), scheme.surfaceContainerHighest);
      now = five + 46 * minute;
      await tester.pump(const Duration(minutes: 30));
      expect(pill(tester, 'b1'), pos.timerLate); // a quarter of an hour late, and nobody sat them
      await stop(tester);
    });

    testWidgets('a tap on a day opens its book, where nobody is seated yet', (tester) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'book-day:$sat');
      expect(t.hub.bookAsks.last, sat);
      expect(standing(tester), ['Nguyen', 'Park']);
      expect(tester.widget<Text>(key('book-count')).data, 'Sat 21 Nov · 2 reservations · 12 guests');
      expect(tester.widget<ChoiceChip>(key('book-day:$sat')).selected, isTrue);
      expect(key('booking-seat:b5'), findsNothing);
      // a later day's time has no colour, whatever the clock says
      expect(pill(tester, 'b5'), Theme.of(tester.element(key('book'))).colorScheme.surfaceContainerHighest);
      // what can be done with it: change it, or cancel it
      await tester.tap(find.text('Park'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('booking-sheet-when')).data, 'Sat 21 Nov at 19:00 · table A8 · booked by Holly');
      for (final what in ['change', 'cancel']) {
        expect(key('booking-do:$what'), findsOneWidget);
      }
      for (final what in ['seat', 'here', 'no_show']) {
        expect(key('booking-do:$what'), findsNothing);
      }
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // and back to today
      await tapKey(tester, 'book-day:$mon');
      expect(t.hub.bookAsks.last, isNull);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);
      await stop(tester);
    });

    testWidgets('any other day is on the calendar, and a day with nothing booked gets its own chip while shown', (
      tester,
    ) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'book-day:pick');
      await tester.tap(find.text('19'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(t.hub.bookAsks.last, '2026-11-19');
      expect(days(tester), ['Today · 3', 'Tomorrow · 1', 'Thu 19 Nov', 'Sat 21 Nov · 2']);
      expect(find.text('No tables are booked for Thu 19 Nov.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Book a table asks the name, how many, the day, the time, a table, a phone and a note', (tester) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'booking-add');
      expect(find.text('Book a table'), findsNWidgets(2)); // the button underneath and the form's title
      expect(tester.widget<FilledButton>(key('booking-save')).onPressed, isNull); // no name and no time yet
      expect(tester.widget<Text>(key('booking-when')).data, 'Mon 16 Nov, pick a time');
      await tester.enterText(key('booking-name'), '  Silva  ');
      await tester.pump();
      expect(tester.widget<FilledButton>(key('booking-save')).onPressed, isNull); // still no time
      await tapKey(tester, 'booking-size:5');
      await tapKey(tester, 'booking-more');
      expect(tester.widget<Text>(key('booking-size')).data, '6 guests');
      // the time off the grid: it opens around five in the afternoon, a row for each hour
      await tapKey(tester, 'booking-time');
      expect(key('time:17:00'), findsOneWidget);
      expect(key('time:19:45'), findsOneWidget);
      await tapKey(tester, 'time:19:30');
      expect(tester.widget<Text>(key('booking-when')).data, 'Mon 16 Nov at 19:30');
      await tester.enterText(key('booking-phone'), '781 555 0199');
      await tester.enterText(key('booking-note'), 'High chair');
      await tester.pump();
      await tapKey(tester, 'booking-save');

      expect(t.hub.bookPosts.single.$1, 'POST /reservations');
      expect(t.hub.bookPosts.single.$2, {
        'staff_id': 's4',
        'name': 'Silva',
        'size': 6,
        'day': mon,
        'time': '19:30',
        'phone': '781 555 0199',
        'note': 'High chair',
        'table': '',
      });
      expect(find.byType(BookingDialog), findsNothing);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia', 'Silva']);
      expect(find.text('Silva is booked for today at 19:30'), findsOneWidget);
      expect(tester.widget<Text>(key('book-count')).data, 'Today, Mon 16 Nov · 4 reservations · 18 guests');
      await stop(tester);
    });

    testWidgets('a table booked for another day is shown in that day\'s book', (tester) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'booking-add');
      await tester.enterText(key('booking-name'), 'Adams');
      await tapKey(tester, 'booking-day:tomorrow');
      await pickTime(tester, '12:15');
      expect(tester.widget<Text>(key('booking-when')).data, 'Tue 17 Nov at 12:15');
      await tapKey(tester, 'booking-save');
      expect(carried(t.hub), containsPair('day', tue));
      expect(standing(tester), ['Adams', 'Silva']); // Tuesday's book, in the order of the times
      expect(tester.widget<ChoiceChip>(key('book-day:$tue')).selected, isTrue);
      expect(find.text('Adams is booked for tomorrow at 12:15'), findsOneWidget);
      // a new table starts on the day the book is open at
      await tapKey(tester, 'booking-add');
      expect(tester.widget<ChoiceChip>(key('booking-day:tomorrow')).selected, isTrue);
      // any later day comes off the calendar
      await tapKey(tester, 'booking-day:other');
      await tester.tap(find.text('27'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('booking-when')).data, 'Fri 27 Nov, pick a time');
      expect(find.descendant(of: key('booking-day:other'), matching: find.text('Fri 27 Nov')), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the small hours are the end of the evening before', (tester) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'booking-add');
      await tester.enterText(key('booking-name'), 'Night owls');
      await pickTime(tester, '00:30'); // the grid runs from six in the morning round to three at night
      await tapKey(tester, 'booking-save');
      expect(carried(t.hub), containsPair('time', '00:30'));
      expect(carried(t.hub), containsPair('day', mon));
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia', 'Night owls']); // after everybody of the evening
      await stop(tester);
    });

    testWidgets('a table is held off a grid of the tables, which says the ones held close to that time', (
      tester,
    ) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'booking-add');
      await tester.enterText(key('booking-name'), 'Adams');
      await pickTime(tester, '19:00');
      await tapKey(tester, 'booking-table');
      expect(find.text('Table to hold'), findsOneWidget);
      // A7 is Chen's at 18:30 and Garcia's at 19:15; B5 was Okafor's at 17:30, an hour and a half before
      expect(tester.widget<Text>(key('table-held:A7')).data, anyOf('18:30 Chen', '19:15 Garcia'));
      expect(key('table-held:B5'), findsNothing);
      expect(find.descendant(of: key('table:A8'), matching: find.textContaining('seat')), findsOneWidget);
      // a held table can still be picked: the form says whose it is as well
      await tapKey(tester, 'table:A7');
      expect(find.descendant(of: key('booking-table'), matching: find.text('Table A7')), findsOneWidget);
      expect(tester.widget<Text>(key('booking-held')).data, startsWith('A7 is also held for '));
      // another one, then none, then one again
      await tapKey(tester, 'booking-table');
      await tapKey(tester, 'table:A8');
      expect(key('booking-held'), findsNothing);
      await tapKey(tester, 'booking-no-table');
      expect(find.descendant(of: key('booking-table'), matching: find.text('Hold a table')), findsOneWidget);
      await tapKey(tester, 'booking-table');
      await tapKey(tester, 'table:A8');
      await tapKey(tester, 'booking-save');
      expect(carried(t.hub), containsPair('table', 'A8'));
      expect(tester.widget<Text>(key('booking-table:b7')).data, 'table A8');
      await stop(tester);
    });

    testWidgets('what the hub does not take is said in the form, which stays open', (tester) async {
      final (t, _) = await pumpBook(tester);
      await tapKey(tester, 'booking-add');
      await tester.enterText(key('booking-name'), 'Silva');
      await pickTime(tester, '19:00');
      await tester.enterText(key('booking-phone'), '555');
      t.hub.refuseBook = (422, 'bad_phone', 'A phone number has 7 digits or more, or is left empty.');
      await tapKey(tester, 'booking-save');
      expect(find.byType(BookingDialog), findsOneWidget);
      expect(
        tester.widget<Text>(key('booking-problem')).data,
        'A phone number has 7 digits or more, or is left empty.',
      );
      // and so is a hub that does not answer
      t.hub.bookDown = true;
      await tapKey(tester, 'booking-save');
      expect(tester.widget<Text>(key('booking-problem')).data, startsWith('The hub cannot be reached'));
      t.hub.bookDown = false;
      await tester.enterText(key('booking-phone'), '');
      await tapKey(tester, 'booking-save');
      expect(find.byType(BookingDialog), findsNothing);
      expect(standing(tester), contains('Silva'));
      await stop(tester);
    });

    testWidgets('a tap on a reservation offers the rest, and Here marks a party that waits for its table', (
      tester,
    ) async {
      final (t, _) = await pumpBook(tester);
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      expect(find.text('Chen, party of 4'), findsOneWidget);
      expect(tester.widget<Text>(key('booking-sheet-when')).data, 'Mon 16 Nov at 18:30 · table A7 · booked by Holly');
      expect(tester.widget<SelectableText>(key('booking-sheet-phone')).data, '781 555 0101');
      expect(tester.widget<Text>(key('booking-sheet-note')).data, 'Birthday');
      for (final what in ['seat', 'here', 'change', 'cancel', 'no_show']) {
        expect(key('booking-do:$what'), findsOneWidget);
      }
      await tapKey(tester, 'booking-do:here');
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b2/arrived');
      expect(carried(t.hub), {'on': true});
      expect(tester.widget<Text>(key('booking-here:b2')).data, 'here since 17:00');
      // and it was not them after all
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: key('booking-do:here'), matching: find.text('Not here')), findsOneWidget);
      await tapKey(tester, 'booking-do:here');
      expect(carried(t.hub), {'on': false});
      expect(key('booking-here:b2'), findsNothing);
      await stop(tester);
    });

    testWidgets('Change opens the reservation as it stands and puts it right', (tester) async {
      final (t, _) = await pumpBook(tester);
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-do:change');
      expect(find.text('Change Chen'), findsOneWidget);
      expect(tester.widget<TextField>(key('booking-name')).controller!.text, 'Chen');
      expect(tester.widget<Text>(key('booking-size')).data, '4 guests');
      expect(tester.widget<Text>(key('booking-when')).data, 'Mon 16 Nov at 18:30');
      expect(find.descendant(of: key('booking-table'), matching: find.text('Table A7')), findsOneWidget);
      expect(tester.widget<TextField>(key('booking-note')).controller!.text, 'Birthday');
      // its own hold of A7 is not held against it; Garcia's, three quarters of an hour later, is
      expect(tester.widget<Text>(key('booking-held')).data, 'A7 is also held for Garcia at 19:15.');
      await tapKey(tester, 'booking-size:8');
      await pickTime(tester, '20:45');
      expect(key('booking-held'), findsNothing); // an hour and a half after Garcia: the table is free again
      await tapKey(tester, 'booking-save');
      expect(t.hub.bookPosts.single.$1, 'PUT /reservations/b2');
      expect(carried(t.hub), {
        'name': 'Chen',
        'size': 8,
        'day': mon,
        'time': '20:45',
        'phone': '781 555 0101',
        'note': 'Birthday',
        'table': 'A7',
      });
      expect(standing(tester), ['Okafor', 'Garcia', 'Chen']);
      expect(find.text('Chen is put right'), findsOneWidget);
      expect(key('booking-clash:b2'), findsNothing);

      // moved to Saturday, the screen follows it there and says so
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-do:change');
      await tapKey(tester, 'booking-day:other');
      await tester.tap(find.text('21'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-save');
      expect(carried(t.hub), containsPair('day', sat));
      expect(standing(tester), ['Nguyen', 'Park', 'Chen']);
      expect(find.text('Chen is now booked for Sat 21 Nov at 20:45'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Cancel it and No-show take a reservation out of the book, and it can be put back at once', (
      tester,
    ) async {
      final (t, _) = await pumpBook(tester);
      await tester.tap(find.text('Garcia'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-do:cancel');
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b3/cancel');
      expect(carried(t.hub), {'why': 'cancelled'});
      expect(standing(tester), ['Okafor', 'Chen']);
      expect(find.text("Garcia's reservation is cancelled"), findsOneWidget);
      await tester.tap(find.text('Put back'));
      await tester.pumpAndSettle();
      expect(t.hub.bookPosts.last.$1, 'POST /reservations/b3/back');
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);

      await tester.tap(find.text('Okafor'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-do:no_show');
      expect(carried(t.hub), {'why': 'no_show'});
      expect(standing(tester), ['Chen', 'Garcia']);
      expect(find.text('Okafor is marked a no-show'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the reservations that ended are underneath, each with a way back into the book', (tester) async {
      final bookings = week();
      bookings[1].addAll({
        'status': 'seated',
        'seated_ms': five - 10 * minute,
        'seated_table': 'B6',
        'seated_label': 'B6',
        'order_id': 'o7',
        'ended_by': 'Holly',
      });
      bookings[2].addAll({'status': 'no_show', 'ended_ms': five - 5 * minute, 'ended_by': 'Amy'});
      final (t, _) = await pumpBook(tester, bookings: bookings);
      expect(standing(tester), ['Chen']);
      expect(find.text('1 seated · 1 no-show'), findsOneWidget);
      expect(key('earlier:b1'), findsNothing); // folded away until asked for
      await tapKey(tester, 'book-earlier');
      expect(find.text('No-show · booked for 19:15 · Amy'), findsOneWidget);
      expect(find.text('Seated at B6 · booked for 17:30 · Holly'), findsOneWidget);
      // the last to end is first
      expect(tester.getTopLeft(key('earlier:b3')).dy < tester.getTopLeft(key('earlier:b1')).dy, isTrue);
      // one that ended shows what the host knew of it, with nothing to do to it but put it back
      await tester.tap(find.text('Okafor'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('booking-sheet-when')).data, contains('Seated at B6'));
      expect(key('booking-do:change'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-back:b1');
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b1/back');
      expect(standing(tester), ['Okafor', 'Chen']);
      expect(find.text('Okafor is back in the book. The check at B6 stays as it is.'), findsOneWidget);
      await tapKey(tester, 'booking-back:b3');
      expect(find.text('Garcia is back in the book'), findsOneWidget);
      expect(key('book-earlier'), findsNothing);
      await stop(tester);
    });

    testWidgets('a day that is over is read, and nothing in it changes', (tester) async {
      final bookings = week()
        ..add(Hub.booking('y1', 'Lopez', 4, day: '2026-11-13', time: '18:00', phone: '781 555 0123'))
        ..add(
          Hub.booking('y2', 'Kim', 2, day: '2026-11-13', time: '19:00')
            ..addAll({'status': 'cancelled', 'ended_ms': five - 4000 * minute, 'ended_by': 'Holly'}),
        );
      final (t, _) = await pumpBook(tester, bookings: bookings);
      expect(days(tester), ['Today · 3', 'Tomorrow · 1', 'Sat 21 Nov · 2']); // no day that is over
      await tapKey(tester, 'book-day:pick');
      await tester.tap(find.text('13'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(t.hub.bookAsks.last, '2026-11-13');
      expect(key('book-over'), findsOneWidget);
      expect(tester.widget<Text>(key('book-count')).data, 'Fri 13 Nov · 1 reservation · 4 guests');
      expect(days(tester).first, 'Fri 13 Nov');
      expect(standing(tester), ['Lopez']); // nobody marked how it ended
      expect(key('booking-add'), findsNothing);
      expect(key('booking-seat:y1'), findsNothing);
      // its number is still there to call, and nothing else
      await tester.tap(find.text('Lopez'));
      await tester.pumpAndSettle();
      expect(tester.widget<SelectableText>(key('booking-sheet-phone')).data, '781 555 0123');
      expect(key('booking-do:change'), findsNothing);
      expect(key('booking-do:cancel'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tapKey(tester, 'book-earlier');
      expect(find.text('Cancelled · booked for 19:00 · Holly'), findsOneWidget);
      expect(key('booking-back:y2'), findsNothing);
      expect(t.hub.bookPosts, isEmpty);
      await stop(tester);
    });

    testWidgets('Seat hands the party to the floor map, and Waitlist leaves for the waitlist', (tester) async {
      final (t, popped) = await pumpBook(tester);
      await tapKey(tester, 'booking-seat:b2');
      expect(find.byType(ReservationsScreen), findsNothing);
      expect((popped.single! as SeatBooking).booking.name, 'Chen');
      expect(t.hub.bookPosts, isEmpty); // nothing is told until a table is tapped
      await tester.tap(find.text('open the book'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: key('book-waitlist'), matching: find.text('Waitlist')), findsOneWidget);
      await tapKey(tester, 'book-waitlist');
      expect(popped.last, isA<OpenWaitlist>());
      await stop(tester);
    });

    testWidgets('with no hub answering it is today\'s book as last read, and a change says why it cannot be made', (
      tester,
    ) async {
      final (t, _) = await pumpBook(tester);
      expect(key('book-away'), findsNothing);
      t.hub.bookDown = true;
      await tester.pump(const Duration(seconds: 3)); // the screen asks again, and nothing answers
      await tester.pumpAndSettle();
      expect(key('book-away'), findsOneWidget);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);
      await tester.tap(find.text('Garcia'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking-do:cancel');
      expect(find.textContaining('The hub cannot be reached'), findsNWidgets(2)); // the strip and the line
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);
      // the hub is back: the next reading takes the strip away
      t.hub.bookDown = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(key('book-away'), findsNothing);
      await stop(tester);
    });

    testWidgets('a hub older than reservations says so, with nothing to book', (tester) async {
      await pumpBook(tester, older: true);
      expect(key('book-older'), findsOneWidget);
      expect(key('booking-add'), findsNothing);
      expect(key('book-days'), findsNothing);
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
        ..bookings = week();
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: ReservationsScreen(api: api, staffId: 's4', nowMs: () => five),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      expect(api.live.isLive, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);

      hub.bookings!.add(Hub.booking('b9', 'Silva', 3, time: '20:00', by: 'Amy'));
      final asks = hub.bookAsks.length;
      live.changed(topics: ['reservations']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // told reads are a second apart at the least
      await tester.pumpAndSettle();
      expect(hub.bookAsks.length, asks + 1);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia', 'Silva']);
      // news of something else reads nothing here
      live.changed(topics: ['waitlist'], orders: ['o1']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(hub.bookAsks.length, asks + 1);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('a 320-wide phone: the book, a reservation\'s buttons, the form, the times and the tables fit', (
      tester,
    ) async {
      final bookings = week()
        ..[0]['name'] = 'Bartholomew-Featherstonehaugh'.substring(0, 24)
        ..[0]['note'] = 'Birthday, a cake is in the fridge, and a high chair for the baby please';
      await pumpBook(tester, bookings: bookings, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      final screen = tester.getRect(find.byType(Scaffold).last);
      final seat = tester.getRect(key('booking-seat:b2'));
      expect(seat.right <= screen.right, isTrue, reason: '$seat');
      // the way to the waitlist is its picture alone here
      expect(find.descendant(of: key('book-waitlist'), matching: find.text('Waitlist')), findsNothing);
      await tester.tap(key('booking:b2'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final what in ['seat', 'here', 'change', 'cancel', 'no_show']) {
        final button = tester.getRect(key('booking-do:$what'));
        expect(button.left >= 0 && button.right <= screen.right, isTrue, reason: '$what $button');
        expect(button.bottom <= screen.bottom, isTrue, reason: '$what $button');
      }
      await tapKey(tester, 'booking-do:change');
      expect(tester.takeException(), isNull);
      final save = tester.getRect(key('booking-save'));
      expect(save.right <= screen.right && save.bottom <= screen.bottom, isTrue, reason: '$save');
      await reachKey(tester, 'booking-time'); // the form scrolls under its buttons on a screen this small
      expect(tester.takeException(), isNull);
      for (final time in ['18:00', '18:45']) {
        final button = tester.getRect(key('time:$time'));
        expect(button.left >= 0 && button.right <= screen.right, isTrue, reason: '$time $button');
      }
      await tapKey(tester, 'time:18:45');
      await reachKey(tester, 'booking-table');
      expect(tester.takeException(), isNull);
      final table = tester.getRect(key('table:A7'));
      expect(table.left >= 0 && table.right <= screen.right, isTrue, reason: '$table');
      await stop(tester);
    });

    testWidgets('large type on a small phone: nothing runs over', (tester) async {
      final t = await terminal(tester);
      tester.view.physicalSize = const Size(360, 700);
      t.hub
        ..clockNow = five
        ..floor = floorThatMoves()
        ..bookings = week();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: ReservationsScreen(api: t.api, staffId: 's4', nowMs: () => five),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'booking-do:change');
      expect(tester.takeException(), isNull);
      await reachKey(tester, 'booking-time');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'time:18:30');
      await reachKey(tester, 'booking-table');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('on the floor', () {
    testWidgets('the book is one tap past the waitlist, and each leads to the other', (tester) async {
      final t = await pumpFloorWith(tester, holly);
      expect(find.byTooltip('Reservations'), findsNothing); // the bar keeps its room
      await tapKey(tester, 'waitlist-open');
      expect(find.descendant(of: key('waitlist-reservations'), matching: find.text('Reservations')), findsOneWidget);
      await tapKey(tester, 'waitlist-reservations');
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(find.byType(WaitlistScreen), findsNothing);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);
      expect(t.hub.bookAsks, isNotEmpty);
      await tapKey(tester, 'book-waitlist');
      expect(find.byType(WaitlistScreen), findsOneWidget);
      expect(find.byType(ReservationsScreen), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(WaitlistScreen), findsNothing);
      expect(seatingBar(), findsNothing);
      await stop(tester);
    });

    testWidgets('on a phone the book is in the menu', (tester) async {
      await pumpFloorWith(tester, amy, size: const Size(390, 800));
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reservations · 3 to come')); // today's, still to sit down
      await tester.pumpAndSettle();
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(standing(tester), ['Okafor', 'Chen', 'Garcia']);
      await stop(tester);
    });

    testWidgets('a server seats a booked party at the table held: the check opens with its guests, and the book '
        'is told', (tester) async {
      // A7 is seated on this floor: Garcia's table is A8 here
      final t = await pumpFloorWith(
        tester,
        amy,
        bookings: [Hub.booking('b3', 'Garcia', 2, time: '19:15', table: 'A8')],
      );
      await seatFromBook(tester, 'b3');
      // the floor map is up, and says what the next tap does and which table was held
      expect(seatingBar(), findsOneWidget);
      expect(find.text('Seating Garcia, party of 2. Table A8 is held for them: tap it, or another.'), findsOneWidget);
      expect(key('to-go'), findsNothing);
      expect(key('new-tab'), findsNothing);

      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat Garcia at A8'), findsOneWidget);
      expect(find.text('2 guests'), findsOneWidget); // as the book has them
      expect(find.text('Server'), findsNothing); // a server takes the table she seats
      await tapKey(tester, 'seat');

      final (orderId, data) = sentOne(t.hub, 'create');
      expect(data, {'table': 'A8', 'guests': 2, 'order_type': 'dine_in', 'server': 'Amy', 'server_id': 's1'});
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b3/seat');
      expect(t.hub.bookPosts.single.$2, {'staff_id': 's1', 'table': 'A8', 'order_id': orderId});
      expect(find.byType(OrderScreen), findsOneWidget); // her check is open, to take the order
      final garcia = t.hub.bookings!.firstWhere((b) => b['id'] == 'b3');
      expect((garcia['status'], garcia['seated_table']), ('seated', 'A8'));
      expect(t.hub.waitPosts, isEmpty); // the waitlist has nothing to do with it
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(seatingBar(), findsNothing);
      await stop(tester);
    });

    testWidgets('the host seats a booked party for a server, at another table than the one held, and stays on '
        'the floor', (tester) async {
      final t = await pumpFloorWith(tester, holly);
      await seatFromBook(tester, 'b2');
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat Chen at A8'), findsOneWidget);
      expect(find.text('4 guests'), findsOneWidget);
      await tester.tap(key('server:s1'));
      await tester.pump();
      await tapKey(tester, 'seat');

      final (orderId, data) = sentOne(t.hub, 'create');
      expect(data, {
        'table': 'A8',
        'guests': 4,
        'order_type': 'dine_in',
        'server': 'Amy',
        'server_id': 's1',
        ...byHolly,
      });
      expect(t.hub.bookPosts.single.$2, {'staff_id': 's4', 'table': 'A8', 'order_id': orderId});
      expect(find.byType(OrderScreen), findsNothing);
      expect(find.text("A8 is Amy's"), findsOneWidget);
      expect(seatingBar(), findsNothing);
      final chen = t.hub.bookings!.firstWhere((b) => b['id'] == 'b2');
      expect((chen['table'], chen['seated_table']), ('A7', 'A8')); // the book keeps both
      await stop(tester);
    });

    testWidgets('a booked party with no table held is asked for one like a party off the waitlist', (tester) async {
      await pumpFloorWith(tester, amy, bookings: [Hub.booking('b1', 'Okafor', 6, time: '17:30')]);
      await seatFromBook(tester, 'b1');
      expect(find.text('Seating Okafor, party of 6. Tap their table.'), findsOneWidget);
      // called off on the strip: nothing is opened and the reservation stands
      await tester.tap(find.descendant(of: seatingBar(), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(seatingBar(), findsNothing);
      await stop(tester);
    });

    testWidgets('a booked party that joins a table that is seated adds its guests to that table\'s check', (
      tester,
    ) async {
      final t = await pumpFloorWith(
        tester,
        mike,
        hub: (hub) => hub.orders.add(checkAt('o1', 'A7', {'M1': line('Egg roll', rank: 1)}, guests: 4)),
      );
      await seatFromBook(tester, 'b3');
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      expect(find.text('A7 is seated'), findsOneWidget);
      expect(find.textContaining('Does Garcia, party of 2 join the table? Its check then counts 6 guests.'), findsOne);
      await tapKey(tester, 'party-join');
      expect(sentTo(t.hub), [
        [
          'o1',
          'set_field',
          {'guests': 6, ...byMike},
        ],
      ]);
      expect(t.hub.bookPosts.single.$2, {'staff_id': 's3', 'table': 'A7', 'order_id': 'o1'});
      expect(find.text('Garcia joined A7'), findsOneWidget);
      expect(seatingBar(), findsNothing);
      await stop(tester);
    });

    testWidgets('the check opens even when the book cannot be told, and the screen says the reservation still '
        'stands', (tester) async {
      final t = await pumpFloorWith(tester, holly);
      await seatFromBook(tester, 'b3');
      t.hub.bookDown = true;
      await tester.tap(find.text('A8')); // A7, held for them, is still seated
      await tester.pumpAndSettle();
      await tester.tap(key('server:s1'));
      await tester.pump();
      await tapKey(tester, 'seat');
      expect(sentOne(t.hub, 'create').$2['table'], 'A8'); // the guests are at the table whatever the book says
      await tester.pump(const Duration(seconds: 5)); // the first line goes, the second comes
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Garcia is at A8, but the reservation book could not be told. '
          'Take the reservation out of the book when the hub is back.',
        ),
        findsOneWidget,
      );
      expect(t.hub.bookings!.firstWhere((b) => b['id'] == 'b3')['status'], 'booked');
      await stop(tester);
    });

    testWidgets('a booked party another screen sat first keeps that table, and the screen says so', (tester) async {
      final t = await pumpFloorWith(tester, mike);
      await seatFromBook(tester, 'b2');
      // meanwhile the host sat them at B5
      t.hub.bookings!.firstWhere((b) => b['id'] == 'b2').addAll({
        'status': 'seated',
        'seated_ms': t.hub.clockNow,
        'seated_table': 'B5',
        'seated_label': 'B5',
        'order_id': 'o9',
        'ended_by': 'Holly',
      });
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'seat');
      expect(find.text('Chen was already seated at B5. The book keeps that table.'), findsOneWidget);
      expect(t.hub.bookings!.firstWhere((b) => b['id'] == 'b2')['seated_table'], 'B5');
      await stop(tester);
    });

    testWidgets('a 320-wide phone: the menu\'s way in, the seating strip and the question fit', (tester) async {
      await pumpFloorWith(tester, holly, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // the row with its count fits the menu
      await tester.tap(find.text('Reservations · 3 to come'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'booking-seat:b2');
      expect(seatingBar(), findsOneWidget);
      expect(tester.takeException(), isNull);
      final screen = tester.getRect(find.byType(Scaffold).first);
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat Chen at A8'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final seat = tester.getRect(key('seat'));
      expect(seat.right <= screen.right && seat.bottom <= screen.bottom, isTrue, reason: '$seat');
      await stop(tester);
    });
  });
}
