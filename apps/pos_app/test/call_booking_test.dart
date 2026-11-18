import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/reservations.dart';
import 'package:pos_app/screens/booking_dialog.dart';
import 'package:pos_app/screens/reservations_screen.dart';
import 'package:pos_app/session.dart';

import 'hub.dart';
import 'phone_test.dart' show FakeStack, active;
import 'table_moves_test.dart' show floorThatMoves;
import 'table_servers_test.dart' show holly;

/// A table booked from a call (the Toast comparison's row 15, the rest): the form a call opens has **Book
/// a table**, which brings the reservation form up with the caller's name and number in it; and a number
/// that has tables booked lists them on the form, each with the way to it in the book.

const mon = '2026-11-16', tue = '2026-11-17', sat = '2026-11-21';
final day = DateTime(2026, 11, 16, 17);

/// Chen booked twice with one number, once without a table held; Garcia with another number; Okafor gave
/// none.
List<Map<String, dynamic>> book() => [
  Hub.booking('b1', 'Chen', 4, day: tue, time: '18:30', table: 'A8', phone: '781 555 1234', note: 'Booth'),
  Hub.booking('b2', 'Chen', 10, day: sat, time: '12:00', phone: '(781) 555-1234'),
  Hub.booking('b3', 'Garcia', 2, time: '19:00', phone: '617 555 0199'),
  Hub.booking('b4', 'Okafor', 6, time: '17:30', table: 'B5'),
];

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.ensureVisible(key(name));
  await tester.pumpAndSettle();
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

String typed(WidgetTester tester, String name) => tester.widget<TextField>(key(name)).controller!.text;

String says(WidgetTester tester, String name) => tester.widget<Text>(key(name)).data!;

/// What the bar at the bottom says, and the button on it.
String barSays(WidgetTester tester) =>
    tester.widget<Text>(find.descendant(of: key('call-booking'), matching: find.byType(Text)).first).data!;

/// The form with [phone] typed into it, and the hub asked about the number.
Future<void> typeNumber(WidgetTester tester, String phone) async {
  await tester.enterText(key('takeout-phone'), phone);
  await tester.pump(const Duration(milliseconds: 500)); // the typing pauses
  await tester.pumpAndSettle();
}

void main() {
  late FakeStack stack;
  late PhoneClient phone;

  setUp(() async {
    stack = FakeStack();
    phone = PhoneClient(stack, clock: () => day);
    await phone.apply(active);
    stack.events!.registered();
  });

  /// The list of checks of [who], on a hub with [bookings] in its book (none: a hub older than the book).
  Future<Terminal> pump(
    WidgetTester tester, {
    Staff who = holly,
    List<Map<String, dynamic>>? bookings,
    bool older = false,
    Size? size,
  }) async {
    final t = await terminal(tester);
    if (size != null) tester.view.physicalSize = size;
    t.session.staff = who;
    t.hub
      ..clockNow = day.millisecondsSinceEpoch
      ..floor = floorThatMoves()
      ..parties = [];
    if (!older) t.hub.bookings = bookings ?? book();
    await pumpOrdersOn(tester, t, phone: phone);
    return t;
  }

  /// A call rings and is answered here: the form opens for the caller, whose number opened no order today.
  Future<void> pickUp(WidgetTester tester, {String number = '+17815551234', String? name = 'WEI CHEN'}) async {
    stack.events!.incomingCall('c1', number: number, name: name);
    await tester.pump();
    phone.answer();
    stack.events!.callAccepted('c1');
    await tester.pumpAndSettle();
    expect(find.text('To-go order'), findsOneWidget);
  }

  /// The form as the To go button opens it, with nobody on the phone.
  Future<void> openForm(WidgetTester tester) async {
    await tapKey(tester, 'to-go'); // its words name a caller while one is on the phone, or just off it
    expect(find.text('To-go order'), findsOneWidget);
  }

  group('what the hub says of who calls', () {
    testWidgets('the tables a number has booked are read, the soonest first; a short number is not asked about', (
      tester,
    ) async {
      final t = await pump(tester);
      final theirs = (await t.api.callerTables('+1 (781) 555-1234'))!;
      expect(theirs.today, mon);
      expect(
        [for (final b in theirs.booked) (b.id, b.name, b.size, b.day, b.time, b.tableLabel)],
        [('b1', 'Chen', 4, tue, '18:30', 'A8'), ('b2', 'Chen', 10, sat, '12:00', '')],
      );
      expect((await t.api.callerTables('781 555 0000'))!.booked, isEmpty);
      expect(t.hub.callersAsked, ['7815551234', '7815550000']);
      expect(await t.api.callerTables('555 12'), isNull);
      expect(await t.api.callerTables(null), isNull);
      expect(t.hub.callersAsked, hasLength(2)); // neither was asked
      await stop(tester);
    });

    testWidgets('a hub without the call, one older than the book and one that is away all answer nothing', (
      tester,
    ) async {
      final t = await pump(tester);
      t.hub.callersOld = true;
      expect(await t.api.callerTables('781 555 1234'), isNull);
      t.hub
        ..callersOld = false
        ..bookDown = true;
      expect(await t.api.callerTables('781 555 1234'), isNull);
      t.hub
        ..bookDown = false
        ..bookings = null;
      expect(await t.api.callerTables('781 555 1234'), isNull);
      await stop(tester);
    });

    test('a reservation in two lines: when it is for, and what it is', () {
      final b = Booking.fromJson(book().first), lunch = Booking.fromJson(book()[1]);
      expect(callerTableWhen(b, mon), 'Tomorrow at 18:30');
      expect(callerTableWhen(b, tue), 'Today at 18:30');
      expect(callerTableWhen(lunch, mon), 'Sat 21 Nov at 12:00');
      // whose it is only when the caller goes by another name
      expect(callerTableWhat(b, asName: ' chen '), 'Table A8 booked · 4 guests');
      expect(callerTableWhat(b, asName: 'Wei Chen'), 'Table A8 booked for Chen · 4 guests');
      expect(callerTableWhat(lunch), 'Table booked for Chen · 10 guests');
      expect(callerTableWhat(lunch, asName: 'Chen'), 'Table booked · 10 guests');
    });
  });

  group('Book a table on the form of a call', () {
    testWidgets('books the caller a table with the name and the number the call came with', (tester) async {
      final t = await pump(tester, bookings: []);
      await pickUp(tester, number: '+17815550142', name: 'Dana Whitfield');
      expect(key('takeout-book'), findsOneWidget);
      expect(key('caller-tables'), findsNothing); // the number has no table booked
      await tapKey(tester, 'takeout-book');

      // the to-go form is gone and the reservation form is up, filled in
      expect(find.text('To-go order'), findsNothing);
      expect(find.byType(BookingDialog), findsOneWidget);
      expect(typed(tester, 'booking-name'), 'Dana Whitfield');
      expect(typed(tester, 'booking-phone'), '781 555 0142');
      expect(tester.widget<TextField>(key('booking-name')).autofocus, isFalse); // the name is there to read
      expect(tester.widget<FilledButton>(key('booking-save')).onPressed, isNull); // no time yet

      await tapKey(tester, 'booking-time');
      await tapKey(tester, 'time:19:30');
      await tapKey(tester, 'booking-save');
      expect(find.byType(BookingDialog), findsNothing);
      final (call, body) = t.hub.bookPosts.single;
      expect(call, 'POST /reservations');
      expect(
        (body['staff_id'], body['name'], body['phone'], body['size'], body['day'], body['time']),
        ('s4', 'Dana Whitfield', '781 555 0142', 2, mon, '19:30'),
      );
      expect(barSays(tester), 'Dana Whitfield is booked for today at 19:30');
      expect(t.hub.sent, isEmpty); // no order was started: a reservation is no check
      expect(t.hub.requests.where((r) => r.startsWith('POST /orders')), isEmpty);
      await stop(tester);
    });

    testWidgets('the bar that says so leads to the book of the day the table is for', (tester) async {
      await pump(tester);
      await pickUp(tester, number: '+17815550142', name: 'Dana Whitfield');
      await tapKey(tester, 'takeout-book');
      await tapKey(tester, 'booking-day:tomorrow');
      await tapKey(tester, 'booking-time');
      await tapKey(tester, 'time:18:00');
      await tapKey(tester, 'booking-save');
      expect(barSays(tester), 'Dana Whitfield is booked for tomorrow at 18:00');

      await tester.tap(find.widgetWithText(SnackBarAction, 'The book'));
      await tester.pumpAndSettle();
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(says(tester, 'book-count'), startsWith('Tomorrow, Tue 17 Nov'));
      expect(find.text('Dana Whitfield'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing); // the book, with nothing opened in it
      await stop(tester);
    });

    testWidgets('a name the book cannot keep whole is cut, and the form closed leaves nothing behind', (tester) async {
      final t = await pump(tester, bookings: []);
      await pickUp(tester, number: '+17815550142', name: '  WINCHESTER   FAMILY DENTAL ASSOCIATES ');
      await tapKey(tester, 'takeout-book');
      expect(typed(tester, 'booking-name'), 'WINCHESTER FAMILY DENTAL'); // 24 letters, as the book keeps
      await tester.tap(find.descendant(of: find.byType(BookingDialog), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(BookingDialog), findsNothing);
      expect(find.text('To-go order'), findsNothing);
      expect(key('call-booking'), findsNothing);
      expect(t.hub.bookPosts, isEmpty);
      await stop(tester);
    });

    testWidgets('a caller with no name leaves the name to type', (tester) async {
      await pump(tester, bookings: []);
      await pickUp(tester, number: '+17815550142', name: null);
      await tapKey(tester, 'takeout-book');
      expect(typed(tester, 'booking-name'), '');
      expect(typed(tester, 'booking-phone'), '781 555 0142');
      expect(tester.widget<TextField>(key('booking-name')).autofocus, isTrue);
      await stop(tester);
    });

    testWidgets('it is offered while the order is by phone, with or without a call', (tester) async {
      await pump(tester, bookings: []);
      await openForm(tester);
      expect(key('takeout-book'), findsNothing); // at the counter the order is the point
      await tapKey(tester, 'channel:phone');
      expect(key('takeout-book'), findsOneWidget);
      await tapKey(tester, 'channel:catering');
      expect(key('takeout-book'), findsNothing);
      await tapKey(tester, 'channel:phone');

      // what was typed so far goes along
      await tester.enterText(key('takeout-name'), 'Priya');
      await typeNumber(tester, '781 555 0177');
      await tapKey(tester, 'takeout-book');
      expect(typed(tester, 'booking-name'), 'Priya');
      expect(typed(tester, 'booking-phone'), '781 555 0177');
      await stop(tester);
    });

    testWidgets('a hub older than reservations says so, and so does one that is away', (tester) async {
      final t = await pump(tester, older: true);
      await pickUp(tester);
      await tapKey(tester, 'takeout-book');
      expect(find.byType(BookingDialog), findsNothing);
      expect(barSays(tester), 'This hub is older than reservations. Update the hub for them.');

      t.hub
        ..bookings = []
        ..bookDown = true;
      await openForm(tester);
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'takeout-book');
      expect(find.byType(BookingDialog), findsNothing);
      expect(barSays(tester), startsWith('The hub cannot be reached'));
      await stop(tester);
    });
  });

  group('a caller who has a table booked', () {
    testWidgets('sees it on the form the moment the call is answered', (tester) async {
      final t = await pump(tester);
      await pickUp(tester);
      expect(t.hub.callersAsked, ['7815551234']);
      expect(key('caller-tables'), findsOneWidget);
      expect(says(tester, 'caller-table:b1'), 'Tomorrow at 18:30');
      expect(
        says(tester, 'caller-table-what:b1'),
        'Table A8 booked for Chen · 4 guests',
      ); // the caller ID says WEI CHEN
      expect(says(tester, 'caller-table:b2'), 'Sat 21 Nov at 12:00');
      expect(says(tester, 'caller-table-what:b2'), 'Table booked for Chen · 10 guests');
      expect(key('caller-table:b3'), findsNothing); // Garcia's, with another number
      // once the name in the box is the one the table is booked under, it is not said twice
      await tester.enterText(key('takeout-name'), 'Chen');
      await tester.pump();
      expect(says(tester, 'caller-table-what:b1'), 'Table A8 booked · 4 guests');
      expect(key('takeout-start'), findsOneWidget); // and the order can be started as ever
      await stop(tester);
    });

    testWidgets('Open brings the reservation up in the book of its day', (tester) async {
      final t = await pump(tester);
      await pickUp(tester);
      await tapKey(tester, 'caller-table-open:b1');
      expect(find.text('To-go order'), findsNothing);
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(t.hub.bookAsks.last, tue);
      expect(says(tester, 'book-count'), startsWith('Tomorrow, Tue 17 Nov'));
      // the reservation is open as if it had been tapped: what is known of it, over what can be done
      expect(tester.widget<SelectableText>(key('booking-sheet-phone')).data, contains('781 555 1234'));
      expect(says(tester, 'booking-sheet-note'), 'Booth');
      expect(key('booking-do:change'), findsOneWidget);
      expect(key('booking-do:cancel'), findsOneWidget);

      // cancelled while they are on the phone
      await tapKey(tester, 'booking-do:cancel');
      expect(t.hub.bookPosts.single.$1, 'POST /reservations/b1/cancel');
      expect(t.hub.sent, isEmpty);
      await stop(tester);
    });

    testWidgets('a table booked for today opens today\'s book, with Seat among what can be done', (tester) async {
      final t = await pump(tester);
      await pickUp(tester, number: '+16175550199', name: 'Garcia');
      expect(says(tester, 'caller-table:b3'), 'Today at 19:00');
      expect(says(tester, 'caller-table-what:b3'), 'Table booked · 2 guests');
      await tapKey(tester, 'caller-table-open:b3');
      expect(says(tester, 'book-count'), startsWith('Today, Mon 16 Nov'));
      expect(key('booking-do:seat'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // the sheet is put away: today's book is under it
      await tester.pumpAndSettle();
      expect(key('booking:b4'), findsOneWidget);
      // today's book is the one the app keeps for when no hub answers: it is asked for as today's from here on
      t.hub.bookAsks.clear();
      await tester.pump(const Duration(seconds: 40));
      expect(t.hub.bookAsks.toSet(), {null});
      await stop(tester);
    });

    testWidgets('one that stands no longer opens the book of its day with nothing up', (tester) async {
      final t = await pump(tester);
      await pickUp(tester);
      t.hub.bookings!.firstWhere((b) => b['id'] == 'b1').addAll({'status': 'cancelled', 'ended_ms': t.hub.clockNow});
      await tapKey(tester, 'caller-table-open:b1');
      expect(find.byType(ReservationsScreen), findsOneWidget);
      expect(says(tester, 'book-count'), startsWith('Tomorrow, Tue 17 Nov'));
      expect(key('booking-do:change'), findsNothing);
      expect(key('book-earlier'), findsOneWidget); // it is among the ones that ended
      await stop(tester);
    });

    testWidgets('a number typed is looked up as it is typed, and a number changed loses the tables', (tester) async {
      final t = await pump(tester);
      await openForm(tester);
      expect(key('caller-tables'), findsNothing);
      await typeNumber(tester, '781 555 1234');
      expect(key('caller-table:b1'), findsOneWidget);
      await typeNumber(tester, '617 555 0199');
      expect(key('caller-table:b1'), findsNothing);
      expect(says(tester, 'caller-table:b3'), 'Today at 19:00');
      await typeNumber(tester, '617 555');
      expect(key('caller-tables'), findsNothing);
      expect(t.hub.callersAsked, ['7815551234', '6175550199']); // six digits are no number: not asked
      await stop(tester);
    });

    testWidgets('a hub without the call leaves the form as it was', (tester) async {
      final t = await pump(tester);
      t.hub.callersOld = true;
      await pickUp(tester);
      expect(key('caller-tables'), findsNothing);
      expect(key('takeout-book'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('on a small phone', () {
    testWidgets('Book a table is its calendar alone, and by its name where there is room', (tester) async {
      await pump(tester, size: const Size(390, 800), bookings: []);
      await pickUp(tester);
      expect(tester.widget(key('takeout-book')), isA<IconButton>());
      expect(find.byTooltip('Book a table'), findsOneWidget);
      expect(find.text('Book a table'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(820, 1100);
      await tester.pumpAndSettle();
      await tapKey(tester, 'to-go');
      expect(find.widgetWithText(TextButton, 'Book a table'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('320 wide with large type: the form, the tables booked and Book a table fit', (tester) async {
      await pump(tester, size: const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await pickUp(tester);
      expect(key('caller-table:b1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'takeout-book');
      expect(find.byType(BookingDialog), findsOneWidget);
      expect(typed(tester, 'booking-phone'), '781 555 1234');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
