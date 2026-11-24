import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/guests_report.dart';
import 'package:pos_app/screens/tag_guest.dart';

import 'guest_tags_host_test.dart' show booked, linda, omar, tagsIn, waiting;
import 'hub.dart';
import 'reservations_test.dart' show pumpBook;
import 'waitlist_test.dart' show pumpList;

/// Tagging a guest from their reservation or their line of the waitlist (docs/guest-list.md, "From a
/// reservation or the waitlist"): a Tags button on the opened sheet, the PIN of whoever may read the guest
/// list, and the guest list's own box of tag buttons with the tags alone. The guest need not have ordered:
/// the hub keeps tags by the number. These tests are about the screens; the hub's side is in
/// `backend/tests/orders/test_guest_tags.py`.

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.ensureVisible(key(name));
  await tester.pumpAndSettle();
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

/// The PIN typed into the box that asks for it, and its button pressed.
Future<void> typePin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byType(TextField).last, pin);
  await tester.tap(find.widgetWithText(FilledButton, 'Tag the guest'));
  await tester.pumpAndSettle();
}

/// A hub that keeps tags by the number: Linda is a catering client and a VIP, nobody else carries one.
void keepsTags(Terminal t, {List<String> lindas = const ['Catering client', 'VIP']}) {
  t.hub
    ..guests = {'guests': <Map<String, dynamic>>[], 'tags': <Map<String, dynamic>>[]}
    ..ringTags = {linda: lindas};
}

/// The tag buttons of the box, in the order they stand, and the ones that are on.
List<String> offeredIn(WidgetTester tester) => [
  for (final chip in tester.widgetList<FilterChip>(find.byType(FilterChip))) (chip.label as Text).data!,
];

List<String> onIn(WidgetTester tester) => [
  for (final chip in tester.widgetList<FilterChip>(find.byType(FilterChip)))
    if (chip.selected) (chip.label as Text).data!,
];

void main() {
  group('the words and what the hub says', () {
    test('a guest is tagged by a phone number, so one with too few digits cannot be', () {
      expect(canTagGuest('781 555 0101'), isTrue);
      expect(canTagGuest('+1 (781) 555-0101'), isTrue);
      expect(canTagGuest(''), isFalse);
      expect(canTagGuest('555'), isFalse);
      expect(canTagGuest('ask at the bar'), isFalse);
    });

    test('what the bar at the bottom says once the tags are saved', () {
      expect(tagsSavedWords('Okafor', const ['VIP']), 'Okafor is tagged VIP');
      expect(tagsSavedWords(' Chen ', const ['Catering client', 'VIP']), 'Chen is tagged Catering client, VIP');
      expect(tagsSavedWords('Okafor', const []), 'Okafor carries no tags now');
      expect(tagsSavedWords('', const ['VIP']), 'This guest is tagged VIP');
    });

    test('the box reads what the hub hands it, and what a hub leaves out is the usual', () {
      final box = TagBox.fromJson({
        'tags': [
          {'tag': 'VIP', 'guests': 2},
          {'tag': 'Friend of the house', 'guests': 0},
        ],
        'tag_max': 20,
        'tags_most': 4,
        'phone': linda,
        'carried': ['VIP'],
        'tags_by': 'Mike',
        'tags_ms': 5,
      });
      expect([for (final tag in box.tags) (tag.tag, tag.guests)], [('VIP', 2), ('Friend of the house', 0)]);
      expect((box.tagMax, box.tagsMost, box.phone, box.tagsBy, box.tagsMs), (20, 4, linda, 'Mike', 5));
      expect(box.carried, ['VIP']);
      final bare = TagBox.fromJson(const {});
      expect(bare.tags, isEmpty);
      expect(bare.carried, isEmpty);
      expect((bare.tagMax, bare.tagsMost, bare.phone, bare.tagsMs), (24, 6, '', null));
    });

    testWidgets('it is asked for by the number\'s digits with the session, and an older hub has none', (tester) async {
      final t = await terminal(tester);
      keepsTags(t);
      final box = await t.api.tagBox('tok-admin', '+1 (781) 555-0101');
      expect(box!.carried, ['Catering client', 'VIP']);
      expect([for (final tag in box.tags) tag.tag], ['Catering client', 'VIP', 'Friend of the house']);
      expect(t.hub.tagBoxAsks.single, (linda, 'Bearer tok-admin'));
      expect((await t.api.tagBox('tok-admin', omar))!.carried, isEmpty); // a number nobody tagged
      t.hub.tagBox = false; // it takes "tags" for a guest's number and knows none
      expect(await t.api.tagBox('tok-admin', linda), isNull);
      t.hub
        ..tagBox = true
        ..refuseTagBox = 403;
      await expectLater(t.api.tagBox('tok-s1', linda), throwsA(isA<ApiException>()));
      await stop(tester);
    });
  });

  group('from a reservation', () {
    testWidgets('Tags is among the buttons of a reservation that has a number, and of no other', (tester) async {
      await pumpBook(tester, bookings: booked(), device: 't1');
      await tapKey(tester, 'booking:b1');
      expect(key('booking-do:tags'), findsOneWidget);
      expect(find.descendant(of: key('booking-do:tags'), matching: find.text('Tags')), findsOneWidget);
      expect(key('booking-do:seat'), findsOneWidget); // beside the others, which are all still there
      expect(key('booking-do:no_show'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // away from the sheet
      await tester.pumpAndSettle();
      await tapKey(tester, 'booking:b3'); // Wu left no number: nothing to keep a tag by
      expect(key('booking-do:change'), findsOneWidget);
      expect(key('booking-do:tags'), findsNothing);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a screen that was handed no device offers none', (tester) async {
      await pumpBook(tester, bookings: booked());
      await tapKey(tester, 'booking:b1');
      expect(key('booking-do:change'), findsOneWidget);
      expect(key('booking-do:tags'), findsNothing);
      await stop(tester);
    });

    testWidgets('a manager\'s PIN, a tap on a tag, and the guest who only booked a table is tagged', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      await tapKey(tester, 'booking:b2'); // Okafor: a number nobody tagged, and no order ever
      await tapKey(tester, 'booking-do:tags');
      // the PIN of whoever may read the guest list, asked for that and nothing wider
      expect(find.text('Manager PIN'), findsOneWidget);
      expect(t.hub.tagBoxAsks, isEmpty);
      await typePin(tester, '9999');
      expect(t.hub.sessionsFor.last, 'guests');
      expect(t.hub.tagBoxAsks.single, (omar, 'Bearer tok-admin'));
      // the guest list's box, with their name, the tags there are and none of theirs on; no note to write
      expect(tester.widget<Text>(key('guest-edit-title')).data, 'Okafor');
      expect(offeredIn(tester), ['Catering client', 'VIP', 'Friend of the house']);
      expect(onIn(tester), isEmpty);
      expect(key('guest-note-words'), findsNothing);
      expect(find.text('Note'), findsNothing);
      expect(find.text('Whoever takes this guest\'s call, order or table sees their tags.'), findsOneWidget);
      await tapKey(tester, 'guest-tag:VIP');
      await tapKey(tester, 'guest-edit-save');
      // the tags alone went to the hub, by the number, under the manager's session
      final (phone, sent) = t.hub.guestKeeps.single;
      expect(phone, omar);
      expect(sent, {
        'tags': ['VIP'],
        'name': 'Okafor', // what the reservation calls them: the guest list has no order to read a name from
      });
      expect(t.hub.guestsAuth, 'Bearer tok-admin');
      // the book says so and shows the tag on the reservation at once
      expect(find.descendant(of: key('guest-tagged'), matching: find.text('Okafor is tagged VIP')), findsOneWidget);
      expect(tagsIn(tester, key('booking:b2')), ['VIP']);
      expect(tagsIn(tester, key('booking:b1')), ['Catering client', 'VIP']); // Linda's are as they were
      expect(t.hub.bookPosts, isEmpty); // the reservation itself was not touched
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('the box starts from what the number carries, and takes a tag off', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      await tapKey(tester, 'booking:b1');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      expect(tester.widget<Text>(key('guest-edit-title')).data, 'Linda P.');
      expect(onIn(tester), ['Catering client', 'VIP']);
      await tapKey(tester, 'guest-tag:VIP');
      await tapKey(tester, 'guest-edit-save');
      expect(t.hub.guestKeeps.single.$2, {
        'tags': ['Catering client'],
        'name': 'Linda P.',
      });
      expect(find.text('Linda P. is tagged Catering client'), findsOneWidget);
      expect(tagsIn(tester, key('booking:b1')), ['Catering client']);
      // and the last one: the PIN is asked again, each time
      await tapKey(tester, 'booking:b1');
      await tapKey(tester, 'booking-do:tags');
      expect(find.text('Manager PIN'), findsOneWidget);
      await typePin(tester, '9999');
      expect(onIn(tester), ['Catering client']);
      await tapKey(tester, 'guest-tag:Catering client');
      await tapKey(tester, 'guest-edit-save');
      expect(t.hub.guestKeeps.last.$2, {'tags': <String>[], 'name': 'Linda P.'});
      expect(find.text('Linda P. carries no tags now'), findsOneWidget);
      expect(tagsIn(tester, key('booking:b1')), isEmpty);
      await stop(tester);
    });

    testWidgets('a tag that is no button yet is typed, and saved with Save', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      await tester.enterText(key('guest-tag-new'), ' wine  club ');
      await tapKey(tester, 'guest-edit-save'); // typed and not added: it is meant too
      expect(t.hub.guestKeeps.single.$2, {
        'tags': ['wine club'],
        'name': 'Okafor',
      });
      expect(tagsIn(tester, key('booking:b2')), ['wine club']);
      await stop(tester);
    });

    testWidgets('the host\'s own PIN does not open it, and Cancel keeps nothing', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '3333'); // Holly keeps the book, and may not read the guest list
      expect(find.text('Only a manager can tag a guest'), findsOneWidget);
      expect(key('guest-edit-title'), findsNothing);
      expect(t.hub.tagBoxAsks, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(key('guest-tagged'), findsNothing);
      // the PIN given and the box cancelled: nothing is kept either
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      await tapKey(tester, 'guest-tag:VIP');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.guestKeeps, isEmpty);
      expect(key('guest-tagged'), findsNothing);
      expect(tagsIn(tester, key('booking:b2')), isEmpty);
      await stop(tester);
    });

    testWidgets('a role handed the guest list tags with their own PIN', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      t.hub.powers!['guests'] = ['host'];
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '3333');
      expect(t.hub.tagBoxAsks.single, (omar, 'Bearer tok-s4'));
      await tapKey(tester, 'guest-tag:VIP');
      await tapKey(tester, 'guest-edit-save');
      expect(t.hub.guestsAuth, 'Bearer tok-s4');
      expect(tagsIn(tester, key('booking:b2')), ['VIP']);
      await stop(tester);
    });

    testWidgets('a hub older than this says so, and so does no hub; nothing is kept', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      t.hub.tagBox = false;
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      expect(key('guest-edit-title'), findsNothing);
      expect(
        find.descendant(of: key('tag-guest-problem'), matching: find.textContaining('older than tagging a guest')),
        findsOneWidget,
      );
      t.hub
        ..tagBox = true
        ..tagBoxDown = true;
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(key('guest-edit-title'), findsNothing);
      expect(
        find.descendant(of: key('tag-guest-problem'), matching: find.textContaining('The hub is not answering')),
        findsOneWidget,
      );
      expect(t.hub.guestKeeps, isEmpty);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a hub that refuses the save says why in the box, and the box stays', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1');
      keepsTags(t);
      await tapKey(tester, 'booking:b2');
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      t.hub.refuseKeep = 401; // the session ran out while the box was open
      await tapKey(tester, 'guest-tag:VIP');
      await tapKey(tester, 'guest-edit-save');
      expect(
        tester.widget<Text>(key('guest-edit-problem')).data,
        "The manager's PIN is no longer good here: close this and tap Tags again.",
      );
      expect(key('guest-edit-title'), findsOneWidget);
      expect(tagsIn(tester, key('booking:b2')), isEmpty);
      await stop(tester);
    });

    testWidgets('on a small phone the six buttons and the box fit', (tester) async {
      final (t, _) = await pumpBook(tester, bookings: booked(), device: 't1', size: const Size(320, 568));
      keepsTags(t);
      await tapKey(tester, 'booking:b1');
      for (final name in ['seat', 'here', 'change', 'cancel', 'no_show', 'tags']) {
        expect(key('booking-do:$name'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'booking-do:tags');
      await typePin(tester, '9999');
      expect(onIn(tester), ['Catering client', 'VIP']);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'guest-edit-save'); // nothing changed: saved as it was
      expect(tagsIn(tester, key('booking:b1')), ['Catering client', 'VIP']);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('from the waitlist', () {
    testWidgets('Tags is among the buttons of a party that has a number, and of no other', (tester) async {
      await pumpList(tester, parties: waiting(), device: 't1');
      await tapKey(tester, 'party:p2');
      expect(key('party-do:tags'), findsOneWidget);
      expect(key('party-do:seat'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tapKey(tester, 'party:p3'); // Okafor gave no number
      expect(key('party-do:change'), findsOneWidget);
      expect(key('party-do:tags'), findsNothing);
      await stop(tester);
    });

    testWidgets('a screen that was handed no device offers none', (tester) async {
      await pumpList(tester, parties: waiting());
      await tapKey(tester, 'party:p2');
      expect(key('party-do:change'), findsOneWidget);
      expect(key('party-do:tags'), findsNothing);
      await stop(tester);
    });

    testWidgets('a manager\'s PIN, a tap on a tag, and the party\'s guest is tagged', (tester) async {
      final (t, _) = await pumpList(
        tester,
        parties: waiting(lindas: const []),
        device: 't1',
      );
      keepsTags(t, lindas: const []);
      await tapKey(tester, 'party:p1'); // Garcia, whose number nobody tagged
      await tapKey(tester, 'party-do:tags');
      expect(find.text('Manager PIN'), findsOneWidget);
      await typePin(tester, '9999');
      expect(t.hub.sessionsFor.last, 'guests');
      expect(tester.widget<Text>(key('guest-edit-title')).data, 'Garcia');
      expect(offeredIn(tester), ['Friend of the house', 'VIP']); // nobody carries one: the two always offered
      expect(key('guest-note-words'), findsNothing);
      await tapKey(tester, 'guest-tag:Friend of the house');
      await tapKey(tester, 'guest-edit-save');
      final (phone, sent) = t.hub.guestKeeps.single;
      expect(phone, omar);
      expect(sent, {
        'tags': ['Friend of the house'],
        'name': 'Garcia', // what the waitlist calls the party
      });
      expect(
        find.descendant(of: key('guest-tagged'), matching: find.text('Garcia is tagged Friend of the house')),
        findsOneWidget,
      );
      expect(tagsIn(tester, key('party:p1')), ['Friend of the house']);
      expect(t.hub.waitPosts, isEmpty); // the party itself was not touched: it keeps its place and its wait
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('on a small phone the six buttons and the box fit', (tester) async {
      final (t, _) = await pumpList(tester, parties: waiting(), device: 't1', size: const Size(320, 568));
      keepsTags(t, lindas: const ['VIP']);
      await tapKey(tester, 'party:p2');
      for (final name in ['seat', 'called', 'change', 'left', 'no_show', 'tags']) {
        expect(key('party-do:$name'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'party-do:tags');
      await typePin(tester, '9999');
      expect(onIn(tester), ['VIP']);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
