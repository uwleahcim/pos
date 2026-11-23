import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/reservations.dart';
import 'package:pos_app/screens/guest_tag_mark.dart';
import 'package:pos_app/screens/phone_bar.dart';
import 'package:pos_app/waitlist.dart';

import 'hub.dart';
import 'phone_test.dart' show FakeStack, active;
import 'reservations_test.dart' show five, pumpBook;
import 'waitlist_test.dart' show pumpList, seven;

/// A guest's tags at the host stand (docs/guest-list.md, "Where the tags show"): on the banner of their
/// call while it still rings, on their reservation in the book and on their party on the waitlist. The
/// hub says which tags a number carries; these tests are about the screens asking and showing them, and
/// showing nothing more where nobody is signed in or the hub is older.

const minute = 60000;
const linda = '7815550101', omar = '7815550102';

/// As many tags as a guest may carry, each as long as a tag may be.
final sixLong = [for (var i = 1; i <= 6; i++) 'Regular at the bar no. $i'.padRight(24, '!')];

Finder key(String name) => find.byKey(ValueKey(name));

/// Whether [later] comes after [earlier] as a line of words is read: further along the same line, or on a
/// line below.
bool readsAfter(Offset earlier, Offset later) =>
    later.dy > earlier.dy + 2 || ((later.dy - earlier.dy).abs() <= 2 && later.dx > earlier.dx);

/// The tags marked inside [within], in the order they stand.
List<String> tagsIn(WidgetTester tester, Finder within) => [
  for (final mark in tester.widgetList<GuestTagMark>(find.descendant(of: within, matching: find.byType(GuestTagMark))))
    mark.tag,
];

/// Monday at five: Linda at 18:30 at A7 with a note, a VIP and a catering client; Okafor at 19:00, a
/// number nobody tagged; Wu at 19:30, who left no number.
List<Map<String, dynamic>> booked({List<String> lindas = const ['Catering client', 'VIP']}) => [
  Hub.booking(
    'b1',
    'Linda P.',
    2,
    time: '18:30',
    table: 'A7',
    phone: '781 555 0101',
    note: 'Window table',
    tags: lindas,
  ),
  Hub.booking('b2', 'Okafor', 6, time: '19:00', phone: '781 555 0102', tags: const []),
  Hub.booking('b3', 'Wu', 4, time: '19:30', tags: const []),
];

/// Seven in the evening: Linda came 12 minutes ago and was told 20, with a note; Garcia 31 minutes ago;
/// Okafor just now, with no number.
List<Map<String, dynamic>> waiting({List<String> lindas = const ['VIP']}) => [
  Hub.waitParty('p1', 'Garcia', 2, atMs: seven - 31 * minute, quoted: 30, phone: '781 555 0102', tags: const []),
  Hub.waitParty(
    'p2',
    'Linda P.',
    4,
    atMs: seven - 12 * minute,
    quoted: 20,
    phone: '781 555 0101',
    note: 'High chair',
    tags: lindas,
  ),
  Hub.waitParty('p3', 'Okafor', 6, atMs: seven - 4 * minute, tags: const []),
];

void main() {
  group('what the hub says', () {
    test('a reservation and a party carry the tags of their number, and none from an older hub', () {
      final tagged = Booking.fromJson(booked().first);
      expect(tagged.tags, ['Catering client', 'VIP']);
      expect(Booking.fromJson(Hub.booking('b9', 'Chen', 2, time: '18:00')).tags, isEmpty);
      expect(Booking.fromJson({...booked().first, 'tags': 'VIP'}).tags, isEmpty); // not a list: nothing
      expect(
        Booking.fromJson({
          ...booked().first,
          'tags': ['VIP', '', 7, '  '],
        }).tags,
        ['VIP'],
      );
      expect(WaitParty.fromJson(waiting()[1]).tags, ['VIP']);
      expect(WaitParty.fromJson(Hub.waitParty('p9', 'Chen', 2, atMs: seven)).tags, isEmpty);
    });

    testWidgets('the tags of a number are asked by its digits, and nothing is asked for a number too short', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.ringTags = {
        linda: ['Catering client', 'VIP'],
      };
      expect(await t.api.customerTags('+1 (781) 555-0101'), ['Catering client', 'VIP']);
      expect(await t.api.customerTags(omar), isEmpty);
      expect(t.hub.tagAsks, [linda, omar]);
      expect(await t.api.customerTags('301'), isEmpty); // an extension
      expect(await t.api.customerTags(null), isEmpty);
      expect(await t.api.customerTags('anonymous'), isEmpty);
      expect(t.hub.tagAsks, [linda, omar]);
      t.hub.tagsDown = true; // no hub answers
      expect(await t.api.customerTags(linda), isEmpty);
      t.hub.ringTags = null; // a hub older than the call
      expect(await t.api.customerTags(linda), isEmpty);
    });
  });

  group('a call that rings', () {
    late FakeStack stack;
    late PhoneClient phone;

    setUp(() {
      stack = FakeStack();
      phone = PhoneClient(stack);
    });

    /// The bar over a screen, with the softphone registered. [tagsOf] is what main.dart hands it while
    /// somebody is signed in.
    Future<void> pumpBar(
      WidgetTester tester, {
      Future<List<String>> Function(String number)? tagsOf,
      Size size = const Size(1100, 800),
      ThemeData? theme,
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: PhoneBar(
            client: phone,
            tagsOf: tagsOf,
            child: const Scaffold(body: Text('orders')),
          ),
        ),
      );
      if (phone.state == PhoneState.off) {
        await phone.apply(active);
        stack.events!.registered();
      }
      await tester.pump();
    }

    testWidgets('shows the tags of its number under it, asked once', (tester) async {
      final t = await terminal(tester);
      t.hub.ringTags = {
        linda: ['Catering client', 'VIP'],
      };
      await pumpBar(tester, tagsOf: t.api.customerTags);
      expect(t.hub.tagAsks, isEmpty); // nothing rings: nothing is asked
      stack.events!.incomingCall('c1', number: '+17815550101', name: 'WIRELESS CALLER');
      await tester.pumpAndSettle();
      expect(find.text('781 555 0101'), findsOneWidget);
      expect(find.text('WIRELESS CALLER'), findsOneWidget); // the phone system's name for the caller stays
      expect(tagsIn(tester, key('ringing-tags')), ['Catering client', 'VIP']);
      // under the number, beside nothing: Answer and Decline are where they were
      expect(
        tester.getTopLeft(key('ringing-tags')).dy,
        greaterThan(tester.getBottomLeft(find.text('781 555 0101')).dy),
      );
      expect(find.text('Answer'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      // the bar is told about the phone many times while it rings: one question a call
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(t.hub.tagAsks, [linda]);
      expect(stack.answered, ['c1']);
    });

    testWidgets('once it is answered the strip is the number, and the next call asks for its own', (tester) async {
      final t = await terminal(tester);
      t.hub.ringTags = {
        linda: ['VIP'],
        omar: ['Friend of the house'],
      };
      await pumpBar(tester, tagsOf: t.api.customerTags);
      stack.events!.incomingCall('c1', number: linda);
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('ringing-tags')), ['VIP']);
      stack.events!.callAccepted('c1');
      await tester.pumpAndSettle();
      expect(find.byType(GuestTagMark), findsNothing);
      expect(find.text('781 555 0101'), findsOneWidget);
      stack.events!.callEnded('c1', 'Terminated');
      await tester.pumpAndSettle();
      stack.events!.incomingCall('c2', number: omar);
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('ringing-tags')), ['Friend of the house']); // and none of the call before
      // the same number again is asked again: a tag may have been put on or taken off since
      stack.events!.callEnded('c2', 'Canceled');
      await tester.pumpAndSettle();
      t.hub.ringTags = {};
      stack.events!.incomingCall('c3', number: omar);
      await tester.pumpAndSettle();
      expect(find.byType(GuestTagMark), findsNothing);
      expect(t.hub.tagAsks, [linda, omar, omar]);
    });

    testWidgets('an answer that comes after its call is not shown on the next one', (tester) async {
      final asked = <String, Completer<List<String>>>{};
      await pumpBar(tester, tagsOf: (number) => (asked[number] = Completer()).future);
      stack.events!.incomingCall('c1', number: linda);
      await tester.pump();
      stack.events!.callEnded('c1', 'Canceled'); // the caller gave up before the hub answered
      await tester.pump();
      stack.events!.incomingCall('c2', number: omar);
      await tester.pump();
      asked[linda]!.complete(['VIP']);
      await tester.pumpAndSettle();
      expect(find.byType(GuestTagMark), findsNothing);
      asked[omar]!.complete(['Friend of the house']);
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('ringing-tags')), ['Friend of the house']);
    });

    testWidgets('nobody signed in: the banner is the number, and nothing is asked', (tester) async {
      final t = await terminal(tester);
      t.hub.ringTags = {
        linda: ['VIP'],
      };
      await pumpBar(tester); // main.dart hands the bar no way to ask at the sign-in pad and on a locked screen
      stack.events!.incomingCall('c1', number: linda);
      await tester.pumpAndSettle();
      expect(find.text('781 555 0101'), findsOneWidget);
      expect(find.byType(GuestTagMark), findsNothing);
      expect(t.hub.tagAsks, isEmpty);
      // somebody signs in while it rings: now they are asked for and shown
      await pumpBar(tester, tagsOf: t.api.customerTags);
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('ringing-tags')), ['VIP']);
      expect(t.hub.tagAsks, [linda]);
      // and put away again when the screen locks under the ringing call
      await pumpBar(tester);
      await tester.pumpAndSettle();
      expect(find.byType(GuestTagMark), findsNothing);
      expect(find.text('Answer'), findsOneWidget);
    });

    testWidgets('a number nobody tagged, a call with no number and a hub with no answer ring as they did', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.ringTags = {};
      await pumpBar(tester, tagsOf: t.api.customerTags);
      stack.events!.incomingCall('c1', number: omar);
      await tester.pumpAndSettle();
      expect(find.byType(GuestTagMark), findsNothing);
      expect(key('ringing-tags'), findsNothing);
      stack.events!.callEnded('c1', 'Canceled');
      await tester.pumpAndSettle();

      stack.events!.incomingCall('c2', number: ''); // a blocked caller ID
      await tester.pumpAndSettle();
      expect(find.text('Answer'), findsOneWidget);
      expect(t.hub.tagAsks, [omar]);
      stack.events!.callEnded('c2', 'Canceled');
      await tester.pumpAndSettle();

      t.hub.ringTags = null; // a hub older than the call
      stack.events!.incomingCall('c3', number: linda);
      await tester.pumpAndSettle();
      expect(find.text('781 555 0101'), findsOneWidget);
      expect(find.byType(GuestTagMark), findsNothing);
      stack.events!.callEnded('c3', 'Canceled');
      await tester.pumpAndSettle();

      // whatever goes wrong with the question, the call still rings and is answered
      await pumpBar(tester, tagsOf: (_) => Future.error(StateError('no hub')));
      stack.events!.incomingCall('c4', number: linda);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Answer'));
      expect(stack.answered, ['c4']);
    });

    testWidgets('on a small phone six long tags wrap inside the banner, in the dark too', (tester) async {
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        await pumpBar(tester, tagsOf: (_) async => sixLong, size: const Size(320, 568), theme: theme);
        stack.events!.incomingCall('c1', number: linda, name: 'WIRELESS CALLER');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tagsIn(tester, key('ringing-tags')), sixLong);
        for (final tag in sixLong) {
          final box = tester.getRect(key('ringing-tag:$tag'));
          expect(box.left, greaterThanOrEqualTo(0));
          expect(box.right, lessThanOrEqualTo(320));
        }
        // both buttons are on the screen and take a tap
        expect(tester.getRect(find.text('Decline')).right, lessThanOrEqualTo(320));
        await tester.tap(find.text('Decline'));
        expect(stack.declined, isNotEmpty);
        stack.events!.callEnded('c1', 'Declined');
        await tester.pumpAndSettle();
        stack.declined.clear();
      }
    });
  });

  group('the reservation book', () {
    testWidgets('a reservation shows the tags of its number, before its note', (tester) async {
      await pumpBook(tester, bookings: booked());
      expect(tagsIn(tester, key('booking:b1')), ['Catering client', 'VIP']);
      expect(tagsIn(tester, key('booking:b2')), isEmpty); // a number nobody tagged
      expect(tagsIn(tester, key('booking:b3')), isEmpty); // no number
      // in the line under the name: after the time and the table, before what the guest asked for
      final table = tester.getTopLeft(key('booking-table:b1'));
      final first = tester.getTopLeft(key('booking-tag:b1:Catering client'));
      final second = tester.getTopLeft(key('booking-tag:b1:VIP'));
      final note = tester.getTopLeft(find.text('Window table'));
      expect(readsAfter(table, first), isTrue);
      expect(readsAfter(first, second), isTrue);
      expect(readsAfter(second, note), isTrue);
      expect(find.widgetWithText(FilledButton, 'Seat'), findsNWidgets(3)); // every row still seats
    });

    testWidgets('the reservation\'s own sheet says them too, under the number', (tester) async {
      await pumpBook(tester, bookings: booked());
      await tester.tap(key('booking:b1'));
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('booking-sheet-tags')), ['Catering client', 'VIP']);
      expect(
        tester.getTopLeft(key('booking-sheet-tags')).dy,
        greaterThan(tester.getBottomLeft(key('booking-sheet-phone')).dy),
      );
      expect(
        tester.getTopLeft(key('booking-sheet-note')).dy,
        greaterThan(tester.getBottomLeft(key('booking-sheet-tags')).dy),
      );
      expect(key('booking-do:seat'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // away from the sheet
      await tester.pumpAndSettle();
      await tester.tap(key('booking:b2'));
      await tester.pumpAndSettle();
      expect(key('booking-sheet-phone'), findsOneWidget);
      expect(key('booking-sheet-tags'), findsNothing);
    });

    testWidgets('one that ended still says them on its sheet', (tester) async {
      final ended = Hub.booking('b4', 'Linda P.', 2, time: '17:00', phone: linda, tags: const ['VIP'])
        ..['status'] = 'no_show'
        ..['ended_ms'] = five - 10 * minute
        ..['ended_by'] = 'Holly';
      await pumpBook(
        tester,
        bookings: [
          ...booked(lindas: const []),
          ended,
        ],
      );
      await tester.tap(key('book-earlier'));
      await tester.pumpAndSettle();
      await tester.tap(key('earlier:b4'));
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('booking-sheet-tags')), ['VIP']);
    });

    testWidgets('a hub older than this reads the book as it did', (tester) async {
      final old = [
        for (final row in booked()) {...row}..remove('tags'),
      ];
      await pumpBook(tester, bookings: old);
      expect(find.byType(GuestTagMark), findsNothing);
      expect(find.text('Window table'), findsOneWidget);
      await tester.tap(key('booking:b1'));
      await tester.pumpAndSettle();
      expect(key('booking-sheet-tags'), findsNothing);
      expect(key('booking-sheet-note'), findsOneWidget);
    });

    testWidgets('on a small phone six long tags wrap under the name, on the row and on the sheet', (tester) async {
      await pumpBook(
        tester,
        bookings: booked(lindas: sixLong),
        size: const Size(320, 568),
      );
      expect(tester.takeException(), isNull);
      expect(tagsIn(tester, key('booking:b1')), sixLong);
      final card = tester.getRect(key('booking:b1'));
      for (final tag in sixLong) {
        final box = tester.getRect(key('booking-tag:b1:$tag'));
        expect(box.left, greaterThanOrEqualTo(card.left));
        expect(box.right, lessThanOrEqualTo(tester.getRect(key('booking-seat:b1')).left));
      }
      await tester.tap(find.text('Linda P.'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tagsIn(tester, key('booking-sheet-tags')), sixLong);
      expect(tester.getRect(key('booking-sheet-tags')).right, lessThanOrEqualTo(320));
    });
  });

  group('the waitlist', () {
    testWidgets('a party shows the tags of its number, before its note', (tester) async {
      await pumpList(tester, parties: waiting());
      expect(tagsIn(tester, key('party:p2')), ['VIP']);
      expect(tagsIn(tester, key('party:p1')), isEmpty); // a number nobody tagged
      expect(tagsIn(tester, key('party:p3')), isEmpty); // no number
      final wait = tester.getTopLeft(key('party-wait:p2'));
      final tag = tester.getTopLeft(key('party-tag:p2:VIP'));
      final note = tester.getTopLeft(find.text('High chair'));
      expect(readsAfter(wait, tag), isTrue);
      expect(readsAfter(tag, note), isTrue);
    });

    testWidgets('the party\'s own sheet says them too, under the number', (tester) async {
      await pumpList(tester, parties: waiting(lindas: const ['Catering client', 'VIP']));
      await tester.tap(key('party:p2'));
      await tester.pumpAndSettle();
      expect(tagsIn(tester, key('party-sheet-tags')), ['Catering client', 'VIP']);
      expect(
        tester.getTopLeft(key('party-sheet-tags')).dy,
        greaterThan(tester.getBottomLeft(key('party-sheet-phone')).dy),
      );
      expect(
        tester.getTopLeft(key('party-sheet-note')).dy,
        greaterThan(tester.getBottomLeft(key('party-sheet-tags')).dy),
      );
      expect(key('party-do:seat'), findsOneWidget);
    });

    testWidgets('a hub older than this reads the list as it did', (tester) async {
      final old = [
        for (final row in waiting()) {...row}..remove('tags'),
      ];
      await pumpList(tester, parties: old);
      expect(find.byType(GuestTagMark), findsNothing);
      expect(find.text('High chair'), findsOneWidget);
      await tester.tap(key('party:p2'));
      await tester.pumpAndSettle();
      expect(key('party-sheet-tags'), findsNothing);
    });

    testWidgets('on a small phone six long tags wrap under the name, on the row and on the sheet', (tester) async {
      await pumpList(
        tester,
        parties: waiting(lindas: sixLong),
        size: const Size(320, 568),
      );
      expect(tester.takeException(), isNull);
      expect(tagsIn(tester, key('party:p2')), sixLong);
      for (final tag in sixLong) {
        final box = tester.getRect(key('party-tag:p2:$tag'));
        expect(box.left, greaterThanOrEqualTo(tester.getRect(key('party:p2')).left));
        expect(box.right, lessThanOrEqualTo(tester.getRect(key('party-seat:p2')).left));
      }
      await tester.tap(find.text('Linda P.'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tagsIn(tester, key('party-sheet-tags')), sixLong);
      expect(tester.getRect(key('party-sheet-tags')).right, lessThanOrEqualTo(320));
    });
  });
}
