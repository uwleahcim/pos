import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/guests_report.dart';

import 'guests_report_test.dart'
    show chip, guest, linda, lindaClosely, listed, ms, omar, picked, priya, pumpGuests, row, sam, tapKey, year;
import 'hub.dart';

/// Tags on a guest, and the note written from the guest list (docs/guest-list.md, "Tags and the note"): a
/// manager puts a few words on a guest ("VIP") and writes the one line the restaurant keeps about them.
/// The hub keeps both and spells the tags; these tests are about the screen showing what is kept, each tag
/// as a list of its own, and the box that changes them sending what was picked.

Map<String, dynamic> offer(String tag, int guests) => {'tag': tag, 'guests': guests};

/// The year of `guests_report_test.dart` on a hub that keeps tags: Linda is a VIP and a catering client,
/// Omar a VIP, and nobody is a friend of the house yet.
Map<String, dynamic> tagged({int tagsMost = 6}) {
  final answer = year();
  for (final row in (answer['guests'] as List).cast<Map<String, dynamic>>()) {
    row['tags'] = switch (row['phone']) {
      linda => ['Catering client', 'VIP'],
      omar => ['VIP'],
      _ => <String>[],
    };
  }
  return {
    ...answer,
    'tags': [offer('VIP', 2), offer('Catering client', 1), offer('Friend of the house', 0)],
    'note_max': 120,
    'tag_max': 24,
    'tags_most': tagsMost,
  };
}

/// Linda read closely on that hub: Mike tagged her on the 12th.
Map<String, dynamic> lindaTagged() {
  final closely = lindaClosely();
  (closely['guest'] as Map<String, dynamic>)['tags'] = ['Catering client', 'VIP'];
  return {...closely, 'tags_by': 'Mike', 'tags_ms': ms(2026, 11, 12)};
}

Future<Terminal> pumpTagged(
  WidgetTester tester, {
  Map<String, dynamic>? guests,
  Size size = const Size(1100, 3600),
  void Function(Hub hub)? before,
}) => pumpGuests(
  tester,
  guests: guests ?? tagged(),
  size: size,
  before: (hub) {
    hub.guestDetails = {linda: lindaTagged()};
    before?.call(hub);
  },
);

/// The tags marked under a guest's name in the list.
List<String> marks(WidgetTester tester, String phone) =>
    find.byKey(ValueKey('guest-marks:$phone')).evaluate().isEmpty ? [] : row(tester, 'guest-marks:$phone');

/// The lists of tags over the guests, as their buttons read.
List<String> tagLists(WidgetTester tester) => [
  for (final chip in tester.widgetList<FilterChip>(
    find.descendant(of: find.byKey(const ValueKey('guests-tags')), matching: find.byType(FilterChip)),
  ))
    (chip.label as Text).data!,
];

FilterChip button(WidgetTester tester, String tag) => tester.widget<FilterChip>(find.byKey(ValueKey('guest-tag:$tag')));

/// The buttons of the box, each with whether it is on.
Map<String, bool> buttons(WidgetTester tester) => {
  for (final chip in tester.widgetList<FilterChip>(
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilterChip)),
  ))
    (chip.label as Text).data!: chip.selected,
};

/// What the hub was asked to keep, each as the number and what was sent (a list, which is compared by
/// what is in it; a record of a map is not).
List<List<Object>> keeps(Hub hub) => [
  for (final (phone, sent) in hub.guestKeeps) [phone, sent],
];

String? problem(WidgetTester tester) {
  final found = find.byKey(const ValueKey('guest-edit-problem'));
  return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
}

/// Opens [phone] in the list and then the box that changes their tags and note.
Future<void> openBox(WidgetTester tester, String phone) async {
  if (find.byKey(ValueKey('guest-more:$phone')).evaluate().isEmpty) await tapKey(tester, 'guest-row:$phone');
  await tapKey(tester, 'guest-edit:$phone');
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<void> tapIn(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('what the list reads', () {
    test('the tags of each guest, every tag there is to offer, and what a note and the tags are held to', () {
      final report = GuestsReport.fromJson(tagged(tagsMost: 4));
      expect(report.keeps, isTrue);
      expect(
        [for (final guest in report.guests) guest.tags],
        [
          ['VIP'],
          ['Catering client', 'VIP'],
          <String>[],
          <String>[],
          <String>[],
        ],
      );
      expect(
        [for (final tag in report.tags) (tag.tag, tag.guests)],
        [('VIP', 2), ('Catering client', 1), ('Friend of the house', 0)],
      );
      expect([for (final tag in report.carried) tag.tag], ['VIP', 'Catering client']);
      expect((report.noteMax, report.tagMax, report.tagsMost), (120, 24, 4));
      expect(report.guests[1].carries('vip'), isTrue);
      expect(report.guests[1].carries('VI'), isFalse);
      // a hub older than tags says none of it: the list is only read
      final older = GuestsReport.fromJson(year());
      expect(older.keeps, isFalse);
      expect(older.tags, isEmpty);
      expect(older.guests.every((guest) => guest.tags.isEmpty), isTrue);
      expect((older.noteMax, older.tagMax, older.tagsMost), (120, 24, 6));
    });

    test('one guest read closely says who put the tags on, and what the hub kept reads into names', () {
      final closely = GuestDetail.fromJson(lindaTagged());
      expect(closely.guest.tags, ['Catering client', 'VIP']);
      expect((closely.tagsBy, closely.tagsMs), ('Mike', ms(2026, 11, 12)));
      expect(GuestDetail.fromJson(lindaClosely()).tagsMs, isNull);
      final kept = GuestKept.fromJson({
        'phone': linda,
        'note': 'side door',
        'note_by': 'Olive',
        'note_ms': 5,
        'tags': ['Bar', 7, 'VIP'],
        'tags_by': 'Mike',
        'tags_ms': null,
      });
      expect((kept.phone, kept.note, kept.noteBy, kept.noteMs), (linda, 'side door', 'Olive', 5));
      expect(kept.tags, ['Bar', 'VIP']);
      expect((kept.tagsBy, kept.tagsMs), ('Mike', null));
      final now = closely.withKept(kept);
      expect((now.guest.note, now.noteBy, now.noteMs), ('side door', 'Olive', 5));
      expect(now.guest.tags, ['Bar', 'VIP']);
      expect((now.tagsBy, now.tagsMs), ('Mike', null));
      expect(now.latest, same(closely.latest));
      expect(now.guest.spent, closely.guest.spent);
    });

    test('what the hub kept stands beside the guest and every tag is counted again', () {
      final report = GuestsReport.fromJson(tagged());
      final now = report.withKept(const GuestKept(phone: omar, note: 'calls ahead', tags: ['Bar', 'Catering client']));
      final byPhone = {for (final guest in now.guests) guest.phone: guest};
      expect(byPhone[omar]!.note, 'calls ahead');
      expect(byPhone[omar]!.tags, ['Bar', 'Catering client']);
      expect(byPhone[linda]!.tags, ['Catering client', 'VIP']);
      // most guests first, then by the alphabet; a tag nobody carries now is still one to offer
      expect(
        [for (final tag in now.tags) (tag.tag, tag.guests)],
        [('Catering client', 2), ('Bar', 1), ('VIP', 1), ('Friend of the house', 0)],
      );
      expect(now.totals, same(report.totals));
      expect((byPhone[omar]!.visits, byPhone[omar]!.spent, byPhone[omar]!.lapsed), (4, '131.60', true));
      final off = now.withKept(const GuestKept(phone: linda)).withKept(const GuestKept(phone: omar));
      expect([for (final tag in off.carried) tag.tag], isEmpty);
      expect([for (final tag in off.tags) tag.tag], ['Bar', 'Catering client', 'Friend of the house', 'VIP']);
      // a number that is not on the list changes nobody on it
      expect(report.withKept(const GuestKept(phone: '7815550199', tags: ['VIP'])).carried.first.guests, 2);
    });

    test('the guests who carry a tag, and tags tidied as the hub keeps them', () {
      final guests = GuestsReport.fromJson(tagged()).guests;
      expect([for (final guest in guestsTagged(guests, 'VIP')) guest.name], ['Omar Haddad', 'Linda Chen']);
      expect([for (final guest in guestsTagged(guests, 'catering CLIENT')) guest.name], ['Linda Chen']);
      expect(guestsTagged(guests, 'Bar'), isEmpty);
      expect(guestsTagged(guests, null), hasLength(5));
      expect(tidyTags(['  regular  at\nthe bar ', 'VIP', '', 'vip', 'Catering']), [
        'Catering',
        'regular at the bar',
        'VIP',
      ]);
      expect(tidyTags(['vip', 'friend of the house'], ['VIP', 'Friend of the house']), ['Friend of the house', 'VIP']);
    });
  });

  group('the call', () {
    testWidgets('carries the token and the digits of the number, and sends only what was given', (tester) async {
      final t = await terminal(tester);
      t.hub.guests = tagged();
      final kept = await tester.runAsync(
        () => t.api.keepGuest('tok', '+1 (781) 555-0101', note: 'side door', tags: ['VIP']),
      );
      expect(t.hub.guestsAuth, 'Bearer tok');
      expect(keeps(t.hub).single, [
        linda,
        {
          'note': 'side door',
          'tags': ['VIP'],
        },
      ]);
      expect((kept!.note, kept.noteBy, kept.tagsBy), ('side door', 'Mike', 'Mike'));
      expect(kept.tags, ['VIP']);
      await tester.runAsync(() => t.api.keepGuest('tok', linda, tags: []));
      await tester.runAsync(() => t.api.keepGuest('tok', linda, note: ''));
      expect(keeps(t.hub).sublist(1), [
        [
          linda,
          {'tags': <String>[]},
        ],
        [
          linda,
          {'note': ''},
        ],
      ]);
      await stop(tester);
    });
  });

  group('the screen', () {
    testWidgets('a guest\'s tags stand under their name, and each tag guests carry is a list of its own', (
      tester,
    ) async {
      await pumpTagged(tester);
      expect(marks(tester, linda), ['Catering client', 'VIP']);
      expect(marks(tester, omar), ['VIP']);
      expect(marks(tester, sam), isEmpty);
      // a tag nobody carries is offered in the box and is no list
      expect(tagLists(tester), ['VIP 2', 'Catering client 1']);
      expect(listed(tester), hasLength(5));

      await tapKey(tester, 'guests-tag:VIP');
      expect(listed(tester), ['Omar Haddad', 'Linda Chen']);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guests-shown'))).data, '2 guests: tagged VIP');
      expect(tagLists(tester), ['VIP 2', 'Catering client 1']);
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('guests-tag:VIP'))).selected, isTrue);
      // with one of the three lists, the guests who are on both
      await tapKey(tester, 'guests:regulars');
      expect(picked(tester, 'regulars'), isTrue);
      expect(listed(tester), ['Linda Chen']);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guests-shown'))).data,
        '1 guest: 3 visits or more in the last 90 days, tagged VIP',
      );
      expect(chip(tester, 'regulars'), 'Regulars 2'); // the counts are of every guest, as they were
      await tapKey(tester, 'guests-tag:Catering client');
      expect(listed(tester), ['Linda Chen']);
      expect(tagLists(tester), ['Catering client 1', 'VIP 2']); // the one picked first in the line
      // a tap on the tag that is picked lets it go
      await tapKey(tester, 'guests-tag:Catering client');
      expect(listed(tester), ['Linda Chen', 'Priya Patel']);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guests-shown'))).data,
        '2 guests: 3 visits or more in the last 90 days',
      );
      await stop(tester);
    });

    testWidgets('an open guest says their tags and who put them on, over the way to change them', (tester) async {
      await pumpTagged(tester);
      await tapKey(tester, 'guest-row:$linda');
      expect(row(tester, 'guest-more:$linda').take(3), [
        'Tags: Catering client, VIP (Mike, Nov 12)',
        'Note: Allergic to peanuts (Amy, Nov 3)',
        'Change tags and note',
      ]);
      // a guest with neither is asked for one
      await tapKey(tester, 'guest-row:$sam');
      expect(find.byKey(const ValueKey('guest-tags:$sam')), findsNothing);
      expect(row(tester, 'guest-more:$sam').first, 'Add a tag or a note');
      await stop(tester);
    });

    testWidgets('a tap puts a tag on or takes it off, another is typed, and the note is written under it', (
      tester,
    ) async {
      final t = await pumpTagged(tester);
      await openBox(tester, linda);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-edit-title'))).data, 'Linda Chen');
      expect(buttons(tester), {'VIP': true, 'Catering client': true, 'Friend of the house': false});
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('guest-note-words'))).controller!.text,
        'Allergic to peanuts',
      );

      await tapIn(tester, 'guest-tag:Friend of the house');
      await tapIn(tester, 'guest-tag:VIP');
      await tester.enterText(find.byKey(const ValueKey('guest-tag-new')), '  regular at  the BAR ');
      await tapIn(tester, 'guest-tag-add');
      expect(buttons(tester), {
        'VIP': false,
        'Catering client': true,
        'Friend of the house': true,
        'regular at the BAR': true,
      });
      expect(tester.widget<TextField>(find.byKey(const ValueKey('guest-tag-new'))).controller!.text, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('guest-note-words')), 'Allergic to peanuts, side door');
      expect(t.hub.guestKeeps, isEmpty); // nothing is kept until Save
      await tapIn(tester, 'guest-edit-save');

      expect(find.byType(AlertDialog), findsNothing);
      expect(t.hub.guestsAuth, 'Bearer tok-admin');
      expect(keeps(t.hub).single, [
        linda,
        {
          'note': 'Allergic to peanuts, side door',
          'tags': ['Catering client', 'Friend of the house', 'regular at the BAR'],
        },
      ]);
      // what the hub kept stands on the screen at once, and the list was not read again for it
      expect(marks(tester, linda), ['Catering client', 'Friend of the house', 'regular at the BAR']);
      expect(tagLists(tester), ['Catering client 1', 'Friend of the house 1', 'regular at the BAR 1', 'VIP 1']);
      expect(row(tester, 'guest-more:$linda').take(3), [
        'Tags: Catering client, Friend of the house, regular at the BAR (Mike, Nov 16)',
        'Note: Allergic to peanuts, side door (Mike, Nov 16)',
        'Change tags and note',
      ]);
      expect(t.hub.guestsAsks, 1);
      expect(t.hub.guestAsks, [linda]);
      // and the box opens on it the next time, the new tag a button like the others
      await openBox(tester, omar);
      expect(buttons(tester), {
        'Catering client': false,
        'Friend of the house': false,
        'regular at the BAR': false,
        'VIP': true,
      });
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await stop(tester);
    });

    testWidgets('a tag typed and not added is saved too, and one typed in other capitals is the button it is', (
      tester,
    ) async {
      final t = await pumpTagged(tester);
      await openBox(tester, priya);
      await tester.enterText(find.byKey(const ValueKey('guest-tag-new')), 'friend OF the house');
      await tapIn(tester, 'guest-edit-save');
      expect(keeps(t.hub).single, [
        priya,
        {
          'note': '',
          'tags': ['Friend of the house'],
        },
      ]);
      expect(marks(tester, priya), ['Friend of the house']);
      // Enter in the box for another tag adds it and saves nothing yet
      await openBox(tester, priya);
      await tester.enterText(find.byKey(const ValueKey('guest-tag-new')), 'Bar');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(buttons(tester)['Bar'], isTrue);
      expect(t.hub.guestKeeps, hasLength(1));
      // and a tag that is on already is not put on twice
      await tester.enterText(find.byKey(const ValueKey('guest-tag-new')), 'BAR');
      await tapIn(tester, 'guest-tag-add');
      expect(buttons(tester).keys.where((tag) => tag.toLowerCase() == 'bar'), ['Bar']);
      await tapIn(tester, 'guest-edit-save');
      expect(t.hub.guestKeeps.last.$2['tags'], ['Friend of the house', 'Bar']);
      expect(marks(tester, priya), ['Bar', 'Friend of the house']);
      await stop(tester);
    });

    testWidgets('a guest carries only as many tags as the hub allows', (tester) async {
      final t = await pumpTagged(tester, guests: tagged(tagsMost: 2));
      await openBox(tester, linda);
      // two are on: the third waits until one is taken off
      expect(button(tester, 'Friend of the house').onSelected, isNull);
      expect(button(tester, 'VIP').onSelected, isNotNull);
      await tester.enterText(find.byKey(const ValueKey('guest-tag-new')), 'Bar');
      await tapIn(tester, 'guest-tag-add');
      expect(problem(tester), 'A guest carries 2 tags at most. Take one off first.');
      expect(buttons(tester).containsKey('Bar'), isFalse);
      // Save with it still typed keeps nothing and says the same
      await tapIn(tester, 'guest-edit-save');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(t.hub.guestKeeps, isEmpty);
      await tapIn(tester, 'guest-tag:VIP');
      expect(problem(tester), isNull);
      expect(button(tester, 'Friend of the house').onSelected, isNotNull);
      await tapIn(tester, 'guest-edit-save');
      expect(t.hub.guestKeeps.single.$2['tags'], ['Catering client', 'Bar']);
      await stop(tester);
    });

    testWidgets('taking a tag off the last guest who carries it ends its list', (tester) async {
      await pumpTagged(tester);
      await tapKey(tester, 'guests-tag:VIP');
      expect(listed(tester), ['Omar Haddad', 'Linda Chen']);
      await openBox(tester, omar);
      await tapIn(tester, 'guest-tag:VIP');
      await tapIn(tester, 'guest-edit-save');
      // Omar is no VIP any more: the list of them is Linda alone
      expect(listed(tester), ['Linda Chen']);
      expect(tagLists(tester), ['VIP 1', 'Catering client 1']); // the tag that is picked stands first
      await openBox(tester, linda);
      await tapIn(tester, 'guest-tag:VIP');
      await tapIn(tester, 'guest-edit-save');
      // and with nobody left on it the screen is back on every guest
      expect(tagLists(tester), ['Catering client 1']);
      expect(listed(tester), hasLength(5));
      expect(tester.widget<Text>(find.byKey(const ValueKey('guests-shown'))).data, '5 guests');
      await stop(tester);
    });

    testWidgets('Cancel keeps nothing', (tester) async {
      final t = await pumpTagged(tester);
      await openBox(tester, linda);
      await tapIn(tester, 'guest-tag:VIP');
      await tester.enterText(find.byKey(const ValueKey('guest-note-words')), 'something else');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.guestKeeps, isEmpty);
      expect(marks(tester, linda), ['Catering client', 'VIP']);
      expect(row(tester, 'guest-more:$linda')[1], 'Note: Allergic to peanuts (Amy, Nov 3)');
      await stop(tester);
    });

    testWidgets('what the hub will not keep is said in the box, which stays with what was picked', (tester) async {
      final t = await pumpTagged(tester);
      await openBox(tester, linda);
      await tapIn(tester, 'guest-tag:Friend of the house');
      t.hub.refuseKeep = 422;
      await tapIn(tester, 'guest-edit-save');
      expect(problem(tester), 'a guest carries 6 tags at most');
      expect(buttons(tester)['Friend of the house'], isTrue);
      t.hub
        ..refuseKeep = 401
        ..keepRefusal = 'sign in with a manager PIN';
      await tapIn(tester, 'guest-edit-save');
      expect(problem(tester), "The manager's hour here is over: go back and open Location again.");
      t.hub
        ..refuseKeep = null
        ..down = true;
      await tapIn(tester, 'guest-edit-save');
      expect(problem(tester), 'The hub is not answering, so nothing was saved.');
      expect(marks(tester, linda), ['Catering client', 'VIP']); // nothing on the list moved meanwhile
      t.hub.down = false;
      await tapIn(tester, 'guest-edit-save');
      expect(find.byType(AlertDialog), findsNothing);
      expect(marks(tester, linda), ['Catering client', 'Friend of the house', 'VIP']);
      await stop(tester);
    });

    testWidgets('Save is pressed once: the box waits for the hub', (tester) async {
      final t = await pumpTagged(tester);
      await openBox(tester, linda);
      final held = t.hub.keepHeld = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('guest-edit-save')));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('guest-edit-save'))).onPressed, isNull);
      expect(button(tester, 'VIP').onSelected, isNull);
      held.complete();
      t.hub.keepHeld = null;
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.hub.guestKeeps, hasLength(1));
      await stop(tester);
    });

    testWidgets('a hub older than tags reads the list as it did: no tag, no list of them and nothing to write', (
      tester,
    ) async {
      final t = await pumpGuests(tester);
      expect(find.byKey(const ValueKey('guests-tags')), findsNothing);
      await tapKey(tester, 'guest-row:$linda');
      expect(find.byKey(const ValueKey('guest-edit:$linda')), findsNothing);
      expect(row(tester, 'guest-more:$linda').first, 'Note: Allergic to peanuts (Amy, Nov 3)');
      expect(tester.widget<Text>(find.byKey(const ValueKey('guests-note'))).data, isNot(contains('put a tag')));
      expect(t.hub.guestKeeps, isEmpty);
      await stop(tester);
    });

    testWidgets('on a small phone many tags run on in one line and the box fits, in the dark too', (tester) async {
      final many = tagged();
      many['tags'] = [
        offer('Friends and family of the house', 2),
        for (var i = 0; i < 14; i++) offer('Catering client number $i', 1),
      ];
      final rows = (many['guests'] as List).cast<Map<String, dynamic>>();
      rows[0]['tags'] = ['Friends and family of the house', for (var i = 0; i < 5; i++) 'Catering client number $i'];
      rows[1]['tags'] = ['Friends and family of the house'];
      rows.add(
        guest(
          '7815550301',
          'Bartholomew Maximilian Featherstonehaugh-Cholmondeley',
          9,
          '12345.60',
          '1371.73',
          '2026-11-01',
          '2026-01-05',
          sinceMs: ms(2026, 1, 5),
        )..['tags'] = [for (var i = 5; i < 11; i++) 'Catering client number $i'],
      );
      for (final dark in [false, true]) {
        tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        final t = await pumpTagged(tester, guests: many, size: const Size(320, 568));
        expect(tester.takeException(), isNull);
        // one line of lists, however many tags: the list under it keeps its room
        expect(tester.getSize(find.byKey(const ValueKey('guests-tags'))).height, lessThan(60));
        await tapKey(tester, 'guest-row:$omar');
        expect(marks(tester, omar), hasLength(6));
        expect(tester.takeException(), isNull);
        await openBox(tester, omar);
        expect(tester.takeException(), isNull);
        expect(buttons(tester), hasLength(15));
        await tester.enterText(find.byKey(const ValueKey('guest-note-words')), 'x' * 120);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tapIn(tester, 'guest-edit-save');
        expect(t.hub.guestKeeps.single.$2['note'], 'x' * 120);
        expect(tester.takeException(), isNull);
        await stop(tester);
      }
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });
  });
}
