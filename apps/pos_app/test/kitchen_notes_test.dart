import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/kitchen_notes.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/kitchen_notes_dialog.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/menu_panel.dart';

import 'hub.dart';
import 'location_rows.dart';

/// One-tap notes to the kitchen (docs/kitchen-notes.md): the location lists short words ("Rush", "Split for
/// 2"), and a dish's sheet shows them as buttons over the box its note is typed in. A tap puts the words in
/// the note, another takes them out, and the dish goes to the hub with the note as any typed note does.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The menu with General Tso's sheet open, as a hold on its tile opens it. What it is added with comes back
/// in [chosen]. The hub lists [notes] (null: a hub older than the notes).
Future<Terminal> pumpSheet(
  WidgetTester tester,
  List<ChosenLine> chosen, {
  List<String>? notes = const ['Rush', 'Split for 2', 'Well done'],
  Size size = const Size(1100, 800),
}) async {
  final t = await terminal(tester);
  t.hub.kitchenNotes = notes == null ? null : [...notes];
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MenuPanel(api: t.api, onChosen: chosen.add, by: 'Amy'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text("Chef's Specials"));
  await tester.pumpAndSettle();
  await tester.longPress(find.text("General Tso's Chicken"));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 200)); // the price asked for
  await tester.pumpAndSettle();
  expect(find.byType(ItemSheet), findsOneWidget);
  return t;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

FilterChip chip(WidgetTester tester, String note) =>
    tester.widget<FilterChip>(find.byKey(ValueKey('kitchen-note:$note')));

/// What the box under [key] holds: the note as the kitchen will read it.
String noteIn(WidgetTester tester, [String key = 'line-note']) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

Future<void> add(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
}

void main() {
  group('the words', () {
    test('a tap puts the words at the end of the note, and a tap again takes them out', () {
      expect(toggleNote('', 'Rush'), 'Rush');
      expect(toggleNote('Rush', 'Split for 2'), 'Rush, Split for 2');
      expect(toggleNote('Rush, Split for 2', 'Rush'), 'Split for 2');
      expect(toggleNote('Rush', 'Rush'), '');
      // what was typed around them stays, in its place
      expect(toggleNote('no onions', 'Rush'), 'no onions, Rush');
      expect(toggleNote('no onions, Rush, sauce on the side', 'Rush'), 'no onions, sauce on the side');
      // whatever the capitals and the spaces somebody typed them with
      expect(toggleNote('no onions ,  RUSH', 'Rush'), 'no onions');
      expect(hasNote('rush, no onions', 'Rush'), isTrue);
      // only the whole words between two commas count: "Rush" is not in "Rush the soup"
      expect(hasNote('Rush the soup', 'Rush'), isFalse);
      expect(toggleNote('Rush the soup', 'Rush'), 'Rush the soup, Rush');
      expect(noteParts(' a ,, b '), ['a', 'b']);
    });

    test('the list is read as the hub keeps it; a hub older than the notes has none', () async {
      expect(
        KitchenNotes.fromJson({
          'notes': ['Rush', ' Split for 2 ', '', 7],
        }).notes,
        ['Rush', 'Split for 2'],
      );
      expect(KitchenNotes.fromJson({}).notes, isEmpty);
      expect(const KitchenNotes(['Rush']).toJson(), {
        'notes': ['Rush'],
      });
    });

    testWidgets('the terminal keeps the last list it read, for a sheet opened before the hub answers', (tester) async {
      final t = await terminal(tester);
      expect(t.api.kitchenNotesKnown, isEmpty);
      expect(await t.api.kitchenNotes(), isNull); // an older hub
      t.hub.kitchenNotes = Hub.standardKitchenNotes;
      expect((await t.api.kitchenNotes())!.notes, Hub.standardKitchenNotes);
      expect(t.api.kitchenNotesKnown, Hub.standardKitchenNotes);
      final saved = await t.api.saveKitchenNotes('tok-admin', const KitchenNotes(['Rush', 'Cut in half']));
      expect(saved.notes, ['Rush', 'Cut in half']);
      expect(t.hub.kitchenNotesAuth, 'Bearer tok-admin');
      expect(t.api.kitchenNotesKnown, ['Rush', 'Cut in half']);
    });
  });

  group("on a dish's sheet", () {
    testWidgets('the notes are buttons over the note; a tap puts the words in, and the dish goes with them', (
      tester,
    ) async {
      final chosen = <ChosenLine>[];
      await pumpSheet(tester, chosen);
      // in the location's order, none of them on yet
      expect(
        [for (final found in tester.widgetList<FilterChip>(find.byType(FilterChip))) (found.label as Text).data],
        ['Rush', 'Split for 2', 'Well done'],
      );
      expect(chip(tester, 'Rush').selected, isFalse);
      expect(noteIn(tester), '');

      await tapKey(tester, 'kitchen-note:Rush');
      expect(noteIn(tester), 'Rush');
      expect(chip(tester, 'Rush').selected, isTrue);
      await tapKey(tester, 'kitchen-note:Well done');
      await tapKey(tester, 'kitchen-note:Split for 2');
      expect(noteIn(tester), 'Rush, Well done, Split for 2'); // in the order tapped
      await tapKey(tester, 'kitchen-note:Well done'); // tapped again: out
      expect(noteIn(tester), 'Rush, Split for 2');
      expect(chip(tester, 'Well done').selected, isFalse);

      await add(tester);
      expect(chosen.single.note, 'Rush, Split for 2');
    });

    testWidgets('what is typed stays around what is tapped, and typing a listed note lights its button', (
      tester,
    ) async {
      final chosen = <ChosenLine>[];
      await pumpSheet(tester, chosen);
      await tester.enterText(find.byKey(const ValueKey('line-note')), 'no onions');
      await tester.pumpAndSettle();
      await tapKey(tester, 'kitchen-note:Rush');
      expect(noteIn(tester), 'no onions, Rush');
      await tester.enterText(find.byKey(const ValueKey('line-note')), 'no onions, Rush, well done');
      await tester.pumpAndSettle();
      expect(chip(tester, 'Well done').selected, isTrue); // typed, whatever the capitals
      await tapKey(tester, 'kitchen-note:Rush');
      expect(noteIn(tester), 'no onions, well done');
      await add(tester);
      expect(chosen.single.note, 'no onions, well done');
    });

    testWidgets('a hub older than the notes shows no button: the note is typed, as before', (tester) async {
      final chosen = <ChosenLine>[];
      await pumpSheet(tester, chosen, notes: null);
      expect(find.byType(FilterChip), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('line-note')), 'no onions');
      await add(tester);
      expect(chosen.single.note, 'no onions');
    });

    testWidgets('a location that lists no note shows no button either', (tester) async {
      await pumpSheet(tester, [], notes: const []);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byKey(const ValueKey('line-note')), findsOneWidget);
    });

    testWidgets('a dish reopened from the check shows which of its words are one-tap notes', (tester) async {
      final t = await terminal(tester);
      t.hub.kitchenNotes = ['Rush', 'Split for 2'];
      final detail = ItemDetail.fromJson(fixture('item_gtc'));
      final entry = MenuEntry.fromDetail(detail);
      ChosenLine? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog<ChosenLine>(
                context: context,
                builder: (_) => ItemSheet(
                  api: t.api,
                  entry: entry,
                  initial: ChosenLine(
                    name: detail.name,
                    request: LineRequest(variantId: detail.variants.first.variantId, entryId: entry.entryId),
                    note: 'extra crispy, Split for 2',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      // this terminal had not read the list before: the buttons come as the sheet reads it
      expect(chip(tester, 'Split for 2').selected, isTrue);
      expect(chip(tester, 'Rush').selected, isFalse);
      await tapKey(tester, 'kitchen-note:Split for 2');
      await tapKey(tester, 'kitchen-note:Rush');
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pumpAndSettle();
      expect(result!.note, 'extra crispy, Rush');
    });

    testWidgets('a dish chosen inside another dish has the buttons over its own note', (tester) async {
      final plate = ItemDetail.fromJson(fixture('item_c5'));
      final entree = plate.groups.first.options.firstWhere((o) => o.optionId == 'entree_slot:gtc');
      Choices? result;
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog<Choices>(
                context: context,
                builder: (_) => DishChoicesSheet(option: entree, kitchenNotes: const ['Rush', 'Split for 2']),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'kitchen-note:Split for 2');
      expect(noteIn(tester, 'dish-note'), 'Split for 2');
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();
      expect(result!.notes, 'Split for 2');
    });

    testWidgets('on a 320-wide phone twelve long notes wrap and the sheet still fits', (tester) async {
      final chosen = <ChosenLine>[];
      await pumpSheet(
        tester,
        chosen,
        size: const Size(320, 568),
        notes: [for (var n = 0; n < 12; n++) 'Twenty-four letters ${n.toString().padLeft(4, '0')}'],
      );
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'kitchen-note:Twenty-four letters 0011');
      await tapKey(tester, 'kitchen-note:Twenty-four letters 0000');
      expect(noteIn(tester), 'Twenty-four letters 0011, Twenty-four letters 0000');
      expect(tester.takeException(), isNull);
    });
  });

  group('the list under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {List<String>? notes, Size? size}) async {
      final t = await terminal(tester);
      t.hub.kitchenNotes = notes;
      if (size != null) tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'kitchen-notes');
      return t;
    }

    String rowWords(WidgetTester tester) =>
        ((tester.widget<ListTile>(find.byKey(const ValueKey('kitchen-notes'))).subtitle!) as Text).data!;

    testWidgets('the row says what is listed; a manager rewords a note, adds one and removes one', (tester) async {
      final t = await pumpLocation(tester, notes: ['Rush', 'Split for 2', 'Well done']);
      expect(rowWords(tester), 'One tap on a dish: Rush, Split for 2, Well done');
      await tapKey(tester, 'kitchen-notes');
      expect(find.byType(KitchenNotesDialog), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('kitchen-note-words:1')), 'Cut  in half ');
      await tapKey(tester, 'kitchen-note-remove:2');
      await tapKey(tester, 'kitchen-note-add');
      await tester.enterText(find.byKey(const ValueKey('kitchen-note-words:3')), 'See server');
      await tapKey(tester, 'kitchen-notes-save');
      expect(find.byType(KitchenNotesDialog), findsNothing);
      expect(t.hub.kitchenNotes, ['Rush', 'Cut in half', 'See server']);
      expect(t.hub.kitchenNotesAuth, 'Bearer tok-admin');
      expect(find.text('Kitchen notes saved'), findsOneWidget);
      expect(rowWords(tester), 'One tap on a dish: Rush, Cut in half, See server');
      // the next dish opened on this terminal has the new buttons at once
      expect(t.api.kitchenNotesKnown, ['Rush', 'Cut in half', 'See server']);
    });

    testWidgets('with every note removed nothing is offered, and the row says so', (tester) async {
      final t = await pumpLocation(tester, notes: ['Rush']);
      await tapKey(tester, 'kitchen-notes');
      await tapKey(tester, 'kitchen-note-remove:0');
      expect(find.text('No note is listed: a note to the kitchen is typed.'), findsOneWidget);
      await tapKey(tester, 'kitchen-notes-save');
      expect(t.hub.kitchenNotes, isEmpty);
      expect(rowWords(tester), 'None listed: a note to the kitchen is typed');
    });

    testWidgets("what cannot be saved is said in the dialog, the hub's own words too", (tester) async {
      final t = await pumpLocation(tester, notes: ['Rush', 'Split for 2']);
      await tapKey(tester, 'kitchen-notes');
      String problem() => tester.widget<Text>(find.byKey(const ValueKey('kitchen-notes-problem'))).data!;

      await tapKey(tester, 'kitchen-note-add');
      await tapKey(tester, 'kitchen-notes-save');
      expect(problem(), 'Every note needs its words');
      await tester.enterText(find.byKey(const ValueKey('kitchen-note-words:2')), 'Rush, please');
      await tapKey(tester, 'kitchen-notes-save');
      expect(problem(), contains('no comma'));
      await tester.enterText(find.byKey(const ValueKey('kitchen-note-words:2')), 'rush');
      await tapKey(tester, 'kitchen-notes-save');
      expect(problem(), 'Two notes say the same');
      expect(t.hub.kitchenNotesAuth, isNull); // nothing was sent

      await tester.enterText(find.byKey(const ValueKey('kitchen-note-words:2')), 'Hurry');
      t.hub.refuseKitchenNotes = 'at most 12 notes, so they stay one tap away';
      await tapKey(tester, 'kitchen-notes-save');
      expect(problem(), 'at most 12 notes, so they stay one tap away');
      expect(find.byType(KitchenNotesDialog), findsOneWidget);
      expect(t.hub.kitchenNotes, ['Rush', 'Split for 2']);
    });

    testWidgets('twelve notes are the most: Add note goes grey', (tester) async {
      await pumpLocation(tester, notes: [for (var n = 0; n < 11; n++) 'Note $n']);
      await tapKey(tester, 'kitchen-notes');
      bool canAdd() =>
          tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('kitchen-note-add'))).onPressed != null;
      expect(canAdd(), isTrue);
      await tapKey(tester, 'kitchen-note-add');
      expect(canAdd(), isFalse);
    });

    testWidgets('a hub older than the notes says so on the row, which opens nothing', (tester) async {
      await pumpLocation(tester);
      expect(rowWords(tester), 'The hub has not answered about the kitchen notes (an older hub: update it)');
      await tapKey(tester, 'kitchen-notes');
      expect(find.byType(KitchenNotesDialog), findsNothing);
    });

    testWidgets('on a 320-wide phone the dialog fits with twelve notes', (tester) async {
      await pumpLocation(
        tester,
        size: const Size(320, 568),
        notes: [for (var n = 0; n < 12; n++) 'Twenty-four letters ${n.toString().padLeft(4, '0')}'],
      );
      await tapKey(tester, 'kitchen-notes');
      expect(find.byType(KitchenNotesDialog), findsOneWidget);
      await tapKey(tester, 'kitchen-note-remove:11');
      expect(tester.takeException(), isNull);
    });
  });
}
