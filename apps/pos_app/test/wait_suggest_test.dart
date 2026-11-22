import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/waitlist.dart';

import 'hub.dart';
import 'waitlist_test.dart' show carried, key, pumpList, tapKey, three, seven;

/// The suggested wait (docs/waitlist.md, "A suggested wait"): when a party is added to the waitlist the hub
/// says what wait to tell it, from how tonight's parties waited. The dialog outlines that wait's button and
/// says why in a line; the wait told is still the one the host taps.

/// The line under the waits, as it reads; null when there is none.
String? line(WidgetTester tester) {
  final found = find.byWidgetPredicate(
    (w) => w is Text && w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('party-suggested:'),
  );
  if (found.evaluate().isEmpty) return null;
  return tester.widget<Text>(found).textSpan!.toPlainText();
}

/// The waits whose buttons are outlined as suggested.
List<String> outlined(WidgetTester tester) => [
  for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)))
    if (chip.side != null) '${(chip.key! as ValueKey).value}',
];

void main() {
  group('the words', () {
    test('say the wait, who is ahead and what a place in line took', () {
      const some = WaitSuggestion(from: 3, to: 4, minutes: 30, aboutMinutes: 24, ahead: 3, eachMinutes: 6);
      expect(some.words, '30 min');
      expect(some.why(), '3 parties of 3 to 4 are ahead, at about 6 min a party tonight.');
      const one = WaitSuggestion(from: 1, to: 2, minutes: 15, ahead: 1, eachMinutes: 7);
      expect(one.why(), '1 party of 1 to 2 is ahead, at about 7 min a party tonight.');
      const none = WaitSuggestion(from: 5, to: 6, minutes: 10, eachMinutes: 8);
      expect(none.why(), 'No party of 5 to 6 is waiting ahead. Tonight the first in line sat after about 8 min.');
      const large = WaitSuggestion(from: 7, to: 60, minutes: 60, ahead: 2, eachMinutes: 20);
      expect(large.why(), '2 parties of 7 or more are ahead, at about 20 min a party tonight.');
      expect(large.why(most: 80), '2 parties of 7 to 60 are ahead, at about 20 min a party tonight.');
    });

    test('name no size where every size was counted', () {
      const all = WaitSuggestion(from: 3, to: 4, minutes: 20, ahead: 2, eachMinutes: 6, like: false);
      expect(all.why(), '2 parties are ahead, at about 6 min a party tonight.');
      const nobody = WaitSuggestion(from: 3, to: 4, minutes: 5, eachMinutes: 4, like: false);
      expect(nobody.why(), 'Nobody is waiting ahead. Tonight the first in line sat after about 4 min.');
    });

    test('say so when a party ahead has waited longer, and when the wait is past the longest on offer', () {
      const slow = WaitSuggestion(
        from: 3,
        to: 4,
        minutes: 45,
        aboutMinutes: 41,
        byLongest: true,
        ahead: 1,
        longestMinutes: 41,
      );
      expect(slow.words, '45 min');
      expect(slow.why(), 'A party of 3 to 4 ahead has waited 41 min already.');
      // the party that has waited longer is always one of the same size, whatever was counted for the pace
      const mixed = WaitSuggestion(
        from: 7,
        to: 60,
        minutes: 60,
        byLongest: true,
        ahead: 4,
        longestMinutes: 60,
        like: false,
      );
      expect(mixed.why(), 'A party of 7 or more ahead has waited 1 h 00 already.');
      const long = WaitSuggestion(from: 1, to: 2, minutes: 90, aboutMinutes: 110, ahead: 17, eachMinutes: 6);
      expect(long.words, '1 h 30 or more (about 1 h 50)');
    });

    test('the hub answer is read by size, and a row with no wait is no suggestion', () {
      final told = WaitSuggestions.fromJson({
        'suggest': [
          Hub.suggested(1, 2, 15, about: 12, ahead: 1, each: 6),
          Hub.suggested(3, 4, 45, about: 41, by: 'longest', ahead: 1, longest: 41),
          {'from': 5, 'to': 6, 'minutes': null},
          'not a row',
        ],
      });
      expect(told.rows, hasLength(2));
      expect(told.forSize(2)!.minutes, 15);
      expect(told.forSize(2)!.aboutMinutes, 12);
      expect(told.forSize(3)!.byLongest, isTrue);
      expect(told.forSize(3)!.longestMinutes, 41);
      expect(told.forSize(5), isNull);
      expect(told.forSize(9), isNull);
      expect(WaitSuggestions.fromJson(const {}).rows, isEmpty);
    });
  });

  group('Add party', () {
    testWidgets('outlines the wait the hub suggests for the size and says why; nothing is told until it is tapped', (
      tester,
    ) async {
      final (t, _) = await pumpList(tester);
      t.hub.waitSuggest = [
        Hub.suggested(1, 2, 15, about: 12, ahead: 1, each: 6),
        Hub.suggested(3, 4, 30, about: 24, ahead: 3, each: 6),
      ];
      await tapKey(tester, 'party-add');
      expect(t.hub.suggestAsks, 1);
      // a party starts at 2 guests: the wait for two is outlined, and no wait is picked
      expect(outlined(tester), ['party-quote:15']);
      expect(tester.widget<ChoiceChip>(key('party-quote:15')).tooltip, 'Suggested');
      expect(tester.widget<ChoiceChip>(key('party-quote:15')).selected, isFalse);
      expect(tester.widget<ChoiceChip>(key('party-quote:none')).selected, isTrue);
      expect(line(tester), 'Suggested: 15 min. 1 party of 1 to 2 is ahead, at about 6 min a party tonight.');
      // four guests wait for another kind of table
      await tester.tap(key('party-size:4'));
      await tester.pump();
      expect(outlined(tester), ['party-quote:30']);
      expect(line(tester), 'Suggested: 30 min. 3 parties of 3 to 4 are ahead, at about 6 min a party tonight.');
      // and for six the hub suggested nothing
      await tester.tap(key('party-size:6'));
      await tester.pump();
      expect(outlined(tester), isEmpty);
      expect(line(tester), isNull);

      // saved as it stands, no time was told: the outline is not a pick
      await tester.tap(key('party-size:4'));
      await tester.pump();
      await tester.enterText(key('party-name'), 'Silva');
      await tester.pump();
      await tapKey(tester, 'party-save');
      expect(carried(t.hub), {'name': 'Silva', 'size': 4, 'phone': '', 'quoted_minutes': null, 'note': ''});

      // the next party is asked for again, and a tap on the outlined wait tells it
      await tapKey(tester, 'party-add');
      expect(t.hub.suggestAsks, 2);
      await tester.tap(key('party-size:3'));
      await tester.pump();
      await tester.tap(key('party-quote:30'));
      await tester.pump();
      expect(tester.widget<ChoiceChip>(key('party-quote:30')).selected, isTrue);
      expect(outlined(tester), ['party-quote:30']);
      await tester.enterText(key('party-name'), 'Moreau');
      await tester.pump();
      await tapKey(tester, 'party-save');
      expect(carried(t.hub), {'name': 'Moreau', 'size': 3, 'phone': '', 'quoted_minutes': 30, 'note': ''});
      await stop(tester);
    });

    testWidgets('says when it goes by a party that has waited longer, and when the wait is past the longest', (
      tester,
    ) async {
      final (t, _) = await pumpList(tester);
      t.hub.waitSuggest = [
        Hub.suggested(1, 2, 45, about: 41, by: 'longest', ahead: 1, longest: 41),
        Hub.suggested(7, 60, 90, about: 110, ahead: 17, each: 6, like: false),
      ];
      await tapKey(tester, 'party-add');
      expect(line(tester), 'Suggested: 45 min. A party of 1 to 2 ahead has waited 41 min already.');
      await tester.tap(key('party-size:8'));
      await tester.pump();
      expect(outlined(tester), ['party-quote:90']);
      expect(
        line(tester),
        'Suggested: 1 h 30 or more (about 1 h 50). 17 parties are ahead, at about 6 min a party tonight.',
      );
      await stop(tester);
    });

    testWidgets('with nothing to go by the question is as it was', (tester) async {
      final (t, _) = await pumpList(tester, parties: []);
      t.hub.waitSuggest = [];
      await tapKey(tester, 'party-add');
      expect(t.hub.suggestAsks, 1);
      expect(outlined(tester), isEmpty);
      expect(line(tester), isNull);
      await stop(tester);
    });

    testWidgets('a hub older than the suggestion adds a party as before', (tester) async {
      final (t, _) = await pumpList(tester, parties: []);
      expect(t.hub.waitSuggest, isNull);
      await tapKey(tester, 'party-add');
      expect(t.hub.suggestAsks, 1);
      expect(outlined(tester), isEmpty);
      expect(line(tester), isNull);
      expect(find.byKey(const ValueKey('party-problem')), findsNothing);
      await tester.enterText(key('party-name'), 'Chen');
      await tester.pump();
      await tester.tap(key('party-quote:20'));
      await tester.pump();
      await tapKey(tester, 'party-save');
      expect(carried(t.hub), {'name': 'Chen', 'size': 2, 'phone': '', 'quoted_minutes': 20, 'note': ''});
      expect(find.byType(AlertDialog), findsNothing);
      await stop(tester);
    });

    testWidgets('with the hub away nothing is suggested and the question still opens', (tester) async {
      final (t, _) = await pumpList(tester);
      t.hub.waitSuggest = [Hub.suggested(1, 2, 15)];
      t.hub.waitDown = true;
      await tapKey(tester, 'party-add');
      expect(find.text('Add to the waitlist'), findsOneWidget);
      expect(outlined(tester), isEmpty);
      expect(line(tester), isNull);
      expect(find.byKey(const ValueKey('party-problem')), findsNothing);
      await stop(tester);
    });

    testWidgets('fits a small phone', (tester) async {
      final (t, _) = await pumpList(tester, size: const Size(320, 568));
      t.hub.waitSuggest = [
        Hub.suggested(1, 2, 90, about: 110, ahead: 17, each: 6),
        Hub.suggested(7, 60, 45, about: 41, by: 'longest', ahead: 1, longest: 41),
      ];
      await tapKey(tester, 'party-add');
      expect(line(tester), startsWith('Suggested: 1 h 30 or more (about 1 h 50).'));
      expect(tester.takeException(), isNull);
      await tester.tap(key('party-size:8'));
      await tester.pump();
      expect(line(tester), 'Suggested: 45 min. A party of 7 or more ahead has waited 41 min already.');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('Change', () {
    testWidgets('a party that is being put right is suggested nothing: its wait was told when it came', (tester) async {
      final (t, _) = await pumpList(tester, parties: three(seven));
      t.hub.waitSuggest = [Hub.suggested(3, 4, 30, ahead: 3, each: 6)];
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'party-do:change');
      expect(find.text('Change Chen'), findsOneWidget);
      expect(t.hub.suggestAsks, 0);
      expect(outlined(tester), isEmpty);
      expect(line(tester), isNull);
      await stop(tester);
    });
  });
}
