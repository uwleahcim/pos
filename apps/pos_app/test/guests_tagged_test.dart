import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/guests_report.dart';

import 'guest_tags_test.dart' show buttons, keeps, marks, offer, openBox, pumpTagged, tagLists, tagged, tapIn;
import 'guests_report_test.dart' show about, chip, linda, listed, ms, omar, row, tapKey;
import 'hub.dart';

/// Tagged guests with no order, in the guest list (docs/guest-list.md, "A tagged guest who has not ordered
/// yet"): a guest tagged from their reservation or their line of the waitlist before their first order is
/// in the list too, after the guests who ordered, under the name they were tagged by. The hub lists them
/// apart (`tagged`) and counts them in none of its sums; these tests are about the screen showing them,
/// counting them in the lists it picks out, and changing their tags like anybody's.

const novak = '7815550199', zed = '7815550188', nobody = '7815550197';

/// The year of `guest_tags_test.dart` with three numbers that carry a tag and have no order in it: Novak,
/// tagged from a reservation and never here yet; Zed, whose one order is older than the year; and a number
/// tagged from a party that gave no name.
Map<String, dynamic> withTagged() => {
  ...tagged(),
  // the hub counts each tag over the guests who ordered
  'tags': [
    offer('VIP', 2),
    offer('Catering client', 1),
    offer('Friend of the house', 0),
    offer('Old friend', 0),
    offer('Wine club', 0),
  ],
  'tagged': [
    Hub.taggedRow(novak, 'Novak', ['VIP', 'Wine club'], note: 'likes the window'),
    Hub.taggedRow(zed, 'Zed', ['Old friend'], sinceMs: ms(2025, 9, 2), ordersEver: 1),
    Hub.taggedRow(nobody, '', ['VIP']),
  ],
};

/// One of them read closely: the same row, nothing to show for visits, and who put the tags on.
Map<String, dynamic> closely(Map<String, dynamic> row) => {
  ...about(),
  'guest': {...row},
  'note_by': (row['note'] as String).isEmpty ? '' : 'Olive',
  'note_ms': (row['note'] as String).isEmpty ? null : ms(2026, 11, 15),
  'tags_by': 'Mike',
  'tags_ms': ms(2026, 11, 14),
  'latest': <Map<String, dynamic>>[],
};

Future<Terminal> pumpWithTagged(WidgetTester tester, {Size size = const Size(1100, 3600)}) {
  final answer = withTagged();
  return pumpTagged(
    tester,
    guests: answer,
    size: size,
    before: (hub) {
      for (final row in (answer['tagged'] as List).cast<Map<String, dynamic>>()) {
        hub.guestDetails[row['phone'] as String] = closely(row);
      }
    },
  );
}

String shown(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('guests-shown'))).data!;

void main() {
  group('what the list reads', () {
    test('the tagged numbers with no order are a list of their own, and each tag counts everybody shown', () {
      final report = GuestsReport.fromJson(withTagged());
      expect([for (final guest in report.guests) guest.phone], hasLength(5));
      expect([for (final guest in report.tagged) guest.called], ['Novak', 'Zed', '781 555 0197']);
      expect(report.everyone, hasLength(8));
      expect(report.totals.guests, 5); // the sums are of the guests who ordered
      final novakRow = report.tagged.first;
      expect((novakRow.ordered, novakRow.visits, novakRow.spent, novakRow.perVisit), (false, 0, '0.00', null));
      expect(novakRow.tags, ['VIP', 'Wine club']);
      expect((novakRow.note, novakRow.ordersEver), ('likes the window', 0));
      expect((report.tagged[1].ordersEver, report.tagged[1].sinceMs), (1, ms(2025, 9, 2)));
      expect(report.guests.every((guest) => guest.ordered), isTrue);
      expect(
        [for (final tag in report.tags) '${tag.tag} ${tag.guests}'],
        ['VIP 4', 'Catering client 1', 'Old friend 1', 'Wine club 1', 'Friend of the house 0'],
      );
      expect([for (final tag in report.carried) tag.tag], ['VIP', 'Catering client', 'Old friend', 'Wine club']);
    });

    test('a hub older than listing them reads as it did, and a row that is no tagged guest is left out', () {
      final older = GuestsReport.fromJson(tagged());
      expect(older.tagged, isEmpty);
      expect(older.everyone, same(older.guests));
      expect(
        [for (final tag in older.tags) '${tag.tag} ${tag.guests}'],
        ['VIP 2', 'Catering client 1', 'Friend of the house 0'],
      );
      final odd = GuestsReport.fromJson({
        ...tagged(),
        'tagged': [
          Hub.taggedRow('7815550150', 'No tag', []),
          {
            ...Hub.taggedRow('7815550151', 'Ordered', ['VIP']),
            'visits': 2,
          },
          'words',
          Hub.taggedRow(novak, 'Novak', ['VIP']),
        ],
      });
      expect([for (final guest in odd.tagged) guest.name], ['Novak']);
    });

    test('they stand after the guests who ordered in every order, by what they are called', () {
      final report = GuestsReport.fromJson(withTagged());
      for (final sort in GuestSort.values) {
        final sorted = sortedGuests(report.everyone, sort);
        expect([for (final guest in sorted.take(5)) guest.ordered], everyElement(isTrue), reason: sort.name);
        expect([for (final guest in sorted.skip(5)) guest.called], ['781 555 0197', 'Novak', 'Zed'], reason: sort.name);
      }
      expect([for (final guest in guestsOf(report.everyone, GuestList.regulars)) guest.ordered], everyElement(isTrue));
      expect(
        [for (final guest in guestsTagged(report.everyone, 'vip')) guest.called],
        ['Omar Haddad', 'Linda Chen', 'Novak', '781 555 0197'],
      );
      expect([for (final guest in guestsNamed(report.everyone, 'nov')) guest.phone], [novak]);
      expect([for (final guest in guestsNamed(report.everyone, '0188')) guest.phone], [zed]);
    });

    test('what the hub kept stands beside them, and one left with no tag is out of the list', () {
      final report = GuestsReport.fromJson(withTagged());
      final more = report.withKept(const GuestKept(phone: novak, note: 'window', tags: ['Regular', 'VIP']));
      expect(more.tagged.first.tags, ['Regular', 'VIP']);
      expect(more.tagged.first.note, 'window');
      expect(more.tagged, hasLength(3));
      expect(
        [for (final tag in more.tags) '${tag.tag} ${tag.guests}'],
        ['VIP 4', 'Catering client 1', 'Old friend 1', 'Regular 1', 'Friend of the house 0', 'Wine club 0'],
      );
      // the last tag off: nothing keeps them in the list, whatever the note
      final fewer = more.withKept(const GuestKept(phone: novak, note: 'window'));
      expect([for (final guest in fewer.tagged) guest.phone], [zed, nobody]);
      expect(fewer.tags.firstWhere((tag) => tag.tag == 'VIP').guests, 3);
      expect(fewer.guests, hasLength(5));
      // a guest who ordered stays, tags or none
      final untagged = fewer.withKept(const GuestKept(phone: omar));
      expect(untagged.guests, hasLength(5));
      expect(untagged.tags.firstWhere((tag) => tag.tag == 'VIP').guests, 2);
    });
  });

  group('the call', () {
    testWidgets('the name a guest is tagged by goes with the tags, and none where none is said', (tester) async {
      final t = await terminal(tester);
      t.hub.guests = withTagged();
      await tester.runAsync(() async {
        await t.api.keepGuest('tok', novak, tags: ['VIP'], name: 'Novak');
        await t.api.keepGuest('tok', novak, tags: ['VIP']);
      });
      expect(keeps(t.hub), [
        [
          novak,
          {
            'tags': ['VIP'],
            'name': 'Novak',
          },
        ],
        [
          novak,
          {
            'tags': ['VIP'],
          },
        ],
      ]);
    });
  });

  group('the screen', () {
    testWidgets('a tagged guest with no order stands after the others and says so in place of visits and money', (
      tester,
    ) async {
      final t = await pumpWithTagged(tester);
      expect(t.hub.guestAsks, isEmpty);
      expect(listed(tester), [
        'Omar Haddad',
        'Linda Chen',
        '781 555 0104',
        'Priya Patel',
        'Tess Moreau',
        '781 555 0197',
        'Novak',
        'Zed',
      ]);
      expect(row(tester, 'guest-row:$novak'), ['7', 'Novak', '', '781 555 0199 · no order yet', 'VIP', 'Wine club']);
      expect(row(tester, 'guest-row:$zed'), [
        '8',
        'Zed',
        '',
        '781 555 0188 · no visit in the last 12 months',
        'Old friend',
      ]);
      // no name where they were tagged: the number is what they are called, and it is not said twice
      expect(row(tester, 'guest-row:$nobody'), ['6', '781 555 0197', '', 'no order yet', 'VIP']);
      expect(marks(tester, novak), ['VIP', 'Wine club']);
      // everybody shown is counted where the list is counted; what the guests spent is as it was
      expect(chip(tester, 'all'), 'All 8');
      expect(shown(tester), '8 guests');
      expect(row(tester, 'guests-total'), ['Guests', '8', '2 regulars · 1 stopped coming · 1 new · 3 with no order']);
      expect(row(tester, 'guests-spent'), ['They spent', r'$306.45', r'15 visits · $20.43 a visit']);
      expect(
        find.text(
          'Everyone who ordered with a phone number, Nov 17, 2025 to Nov 16, 2026, and the tagged guests who did not.',
        ),
        findsOneWidget,
      );
      expect(tagLists(tester), ['VIP 4', 'Catering client 1', 'Old friend 1', 'Wine club 1']);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guests-note'))).data,
        contains('has no order in that time'),
      );
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('they are on no list of regulars, and on the list of each tag they carry, found by name or number', (
      tester,
    ) async {
      await pumpWithTagged(tester);
      for (final (key, count) in [('regulars', 2), ('lapsed', 1), ('new', 1)]) {
        await tapKey(tester, 'guests:$key');
        expect(listed(tester), hasLength(count), reason: key);
        expect(listed(tester), isNot(contains('Novak')));
      }
      await tapKey(tester, 'guests:all');
      await tapKey(tester, 'guests-tag:VIP');
      expect(listed(tester), ['Omar Haddad', 'Linda Chen', '781 555 0197', 'Novak']);
      expect(shown(tester), '4 guests: tagged VIP');
      await tapKey(tester, 'guests-tag:Wine club'); // a tag only a guest with no order carries is a list too
      expect(listed(tester), ['Novak']);
      expect(row(tester, 'guest-row:$novak').first, '1');
      await tapKey(tester, 'guests-tag:Wine club');
      // every order keeps them after the guests who ordered
      for (final sort in ['visits', 'latest', 'spent']) {
        await tapKey(tester, 'guests-by:$sort');
        expect(listed(tester).skip(5), ['781 555 0197', 'Novak', 'Zed'], reason: sort);
      }
      await tester.enterText(find.byKey(const ValueKey('guests-find')), 'zed');
      await tester.pumpAndSettle();
      expect(listed(tester), ['Zed']);
      await tester.enterText(find.byKey(const ValueKey('guests-find')), '555 0199');
      await tester.pumpAndSettle();
      expect(listed(tester), ['Novak']);
      await stop(tester);
    });

    testWidgets('opened, one says their tags, who put them on and that there is no order, and no visits', (
      tester,
    ) async {
      final t = await pumpWithTagged(tester);
      await tapKey(tester, 'guest-row:$novak');
      expect(t.hub.guestAsks, [novak]); // read closely for who put the tags on
      expect(row(tester, 'guest-more:$novak'), [
        'Tags: VIP, Wine club (Mike, Nov 14)',
        'Note: likes the window (Olive, Nov 15)',
        'Change tags and note',
        'No order from this number yet. They are in the list for the tags they carry.',
      ]);
      expect(find.text('Latest visits'), findsNothing);
      expect(find.text('Favourite dishes'), findsNothing);
      expect(find.byKey(const ValueKey('guest-rate:$novak')), findsNothing);
      expect(find.byKey(const ValueKey('guest-reading:$novak')), findsNothing);
      // a guest of long ago says since when, and that the year has no order of theirs
      await tapKey(tester, 'guest-row:$zed');
      expect(row(tester, 'guest-more:$zed'), [
        'Tags: Old friend (Mike, Nov 14)',
        'Change tags and note',
        'A guest since Sep 2, 2025 · 1 order in all · no visit in the last 12 months',
      ]);
      // a guest who ordered is opened as before
      await tapKey(tester, 'guest-row:$linda');
      expect(find.text('Latest visits'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-rate:$linda')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('while one is read closely nothing spins, and a hub that does not answer says so with a way back', (
      tester,
    ) async {
      final t = await pumpWithTagged(tester);
      t.hub.refuseGuest = 500;
      await tapKey(tester, 'guest-row:$novak');
      expect(find.byKey(const ValueKey('guest-error:$novak')), findsOneWidget);
      expect(row(tester, 'guest-more:$novak').first, 'Tags: VIP, Wine club'); // what the list said stands
      t.hub.refuseGuest = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-error:$novak')), findsNothing);
      expect(row(tester, 'guest-more:$novak').first, 'Tags: VIP, Wine club (Mike, Nov 14)');
      await stop(tester);
    });

    testWidgets('their tags and note are changed from the list like anybody\'s, and no name is sent from here', (
      tester,
    ) async {
      final t = await pumpWithTagged(tester);
      await openBox(tester, novak);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-edit-title'))).data, 'Novak');
      expect(buttons(tester), {
        'VIP': true,
        'Catering client': false,
        'Old friend': false,
        'Wine club': true,
        'Friend of the house': false,
      });
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('guest-note-words'))).controller!.text,
        'likes the window',
      );
      await tapIn(tester, 'guest-tag:Wine club');
      await tapIn(tester, 'guest-tag:Old friend');
      await tapIn(tester, 'guest-edit-save');
      expect(keeps(t.hub), [
        [
          novak,
          {
            'note': 'likes the window',
            'tags': ['VIP', 'Old friend'],
          },
        ],
      ]);
      expect(marks(tester, novak), ['Old friend', 'VIP']);
      expect(row(tester, 'guest-more:$novak').first, 'Tags: Old friend, VIP (Mike, Nov 16)');
      expect(tagLists(tester), ['VIP 4', 'Old friend 2', 'Catering client 1']);
      expect(chip(tester, 'all'), 'All 8');
      expect(find.byKey(const ValueKey('guest-left')), findsNothing);
      await stop(tester);
    });

    testWidgets('with their last tag off they leave the list, and the screen says why', (tester) async {
      final t = await pumpWithTagged(tester);
      await openBox(tester, nobody);
      await tapIn(tester, 'guest-tag:VIP');
      await tapIn(tester, 'guest-edit-save');
      expect(t.hub.guestKeeps.single.$2['tags'], isEmpty);
      expect(find.byKey(const ValueKey('guest:$nobody')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('guest-left')),
          matching: find.text(
            '781 555 0197 carries no tag now and has no order yet, so the list no longer shows them.',
          ),
        ),
        findsOneWidget,
      );
      expect(listed(tester).skip(5), ['Novak', 'Zed']);
      expect(chip(tester, 'all'), 'All 7');
      expect(row(tester, 'guests-total'), ['Guests', '7', '2 regulars · 1 stopped coming · 1 new · 2 with no order']);
      expect(tagLists(tester), ['VIP 3', 'Catering client 1', 'Old friend 1', 'Wine club 1']);
      // a guest who ordered stays in the list with no tag
      await openBox(tester, omar);
      await tapIn(tester, 'guest-tag:VIP');
      await tapIn(tester, 'guest-edit-save');
      expect(find.byKey(const ValueKey('guest:$omar')), findsOneWidget);
      expect(chip(tester, 'all'), 'All 7');
      // read again, the hub lists who is left
      await tapKey(tester, 'guests-refresh');
      expect(listed(tester).skip(5), ['Novak', 'Zed']);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a hub older than listing them shows the list as it did', (tester) async {
      await pumpTagged(tester);
      expect(listed(tester), hasLength(5));
      expect(chip(tester, 'all'), 'All 5');
      expect(row(tester, 'guests-total'), ['Guests', '5', '2 regulars · 1 stopped coming · 1 new']);
      expect(find.text('Everyone who ordered with a phone number, Nov 17, 2025 to Nov 16, 2026.'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guests-note'))).data,
        isNot(contains('has no order in that time')),
      );
      await stop(tester);
    });

    testWidgets('on a small phone the row, the opened guest and the box fit, in the dark and with large type', (
      tester,
    ) async {
      for (final (dark, scale) in [(false, 1.0), (true, 1.0), (false, 1.6)]) {
        tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await pumpWithTagged(tester, size: const Size(320, 568));
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'guest-row:$zed');
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('guest-since:$zed')), findsOneWidget);
        await openBox(tester, zed);
        expect(tester.takeException(), isNull);
        await tapIn(tester, 'guest-tag:Old friend');
        await tapIn(tester, 'guest-edit-save');
        expect(find.byKey(const ValueKey('guest-left')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await stop(tester);
      }
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
  });
}
