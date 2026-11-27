import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/settings.dart';

import 'booked_tables_test.dart' show markSays;
import 'floor_guests_test.dart' show key, lindaAtA7, named, pumpMap, starred;
import 'floor_test.dart' show floorJson;
import 'hub.dart';
import 'table_moves_test.dart' show floorThatMoves, seated;
import 'table_servers_test.dart' show serverTag;
import 'table_tags_test.dart' show seven;

/// The floor map at a glance (lib/screens/floor_view.dart, lib/floor_layout.dart). Every table stands where
/// the plan has it and is drawn as large as the aisles around it allow; what is written on it is written at
/// a size that reads, on a phone as on a Mac. A table with no room for everything says less, not the same
/// in smaller letters: its room, a tap away, has the room for the rest. What a table must never lose (that
/// it is wanted for a booking, that a guest at it carries a tag) stays as a mark on its edge.

/// A phone's screen, a tablet's on its side and a Mac's window.
const phone = Size(390, 760), tablet = Size(1180, 820), mac = Size(1440, 900);

final tableIds = [for (final table in FloorPlan.fromJson(floorJson()).tables) table.id];

Finder look(String table) => key('table-look:$table');

/// Every line written on the tables that are on the screen: whose table, what it says, and the size of
/// the letters in points.
List<(String, String, double)> written(WidgetTester tester) => [
  for (final table in tableIds)
    for (final text in tester.widgetList<Text>(find.descendant(of: look(table), matching: find.byType(Text))))
      (table, text.data ?? '', text.style?.fontSize ?? 0),
];

/// The lines written on [table], from the top down.
List<String> says(WidgetTester tester, String table) => [
  for (final (at, words, _) in written(tester))
    if (at == table) words,
];

/// The room [name] by itself, as a tap on its name above the map shows it, once the tables have arrived.
/// On a phone the names run off the side of the screen: the row is moved until the name is on it.
Future<void> open(WidgetTester tester, String name) async {
  final chip = find.widgetWithText(ChoiceChip, name);
  await tester.ensureVisible(chip);
  await tester.pump();
  await tester.tap(chip);
  await arrive(tester);
  expect(tester.widget<ChoiceChip>(chip).selected, isTrue, reason: name);
}

/// The tables glide to their new places, and the ones that left the screen are let go.
Future<void> arrive(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(FloorViewState.glideTime + const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 300)); // (the row of names has come to rest as well)
}

/// Ben's party of two at B5 and a booking of A8 for half past seven, beside Amy's A7.
void busy(Hub hub) => hub
  ..floor = floorThatMoves({
    'B5': [seated('o2', 'Ben', 's2')],
  })
  ..bookings = [Hub.booking('b2', 'Chen', 4, time: '19:30', table: 'A8', atMs: seven + 30 * 60000)];

void main() {
  testWidgets('no word on the map is written too small to read: on a phone, a tablet and a Mac, the whole floor '
      'and a room', (tester) async {
    for (final view in [phone, tablet, mac]) {
      await pumpMap(tester, size: view, setUp: busy);
      for (final room in [null, 'Main dining', 'Dining room C & D', 'Bar and lounge']) {
        if (room != null) await open(tester, room);
        final lines = written(tester);
        expect(lines, isNotEmpty);
        for (final (table, words, size) in lines) {
          // a table's own name is the largest thing on it; nothing else is under ten points, near enough
          expect(size, greaterThanOrEqualTo(words == table ? 12 : 9.5), reason: '"$words" on $table, $view, $room');
          expect(size, lessThanOrEqualTo(22.01), reason: '"$words" on $table, $view, $room');
        }
        expect(tester.takeException(), isNull, reason: '$view, $room');
      }
      await stop(tester);
    }
  });

  testWidgets('on the whole floor of a phone a table says what matters most; its room says the rest', (tester) async {
    await pumpMap(tester, size: phone, setUp: busy);
    // B5 is a narrow table for six: the whole floor has the room for its name and how long it has sat
    expect(says(tester, 'B5'), ['B5', '0m']);
    expect(serverTag('B5'), findsNothing);
    // A8 is free and booked: no room for the time, so it wears the mark of a booking on its edge
    expect(says(tester, 'A8'), ['A8']);
    expect(markSays(tester, 'A8'), 'booked for 19:30, Chen, party of 4');

    // A tap on the room's frame on the map opens the room, as a tap on its name above the map does.
    await tester.tapAt(tester.getRect(key('room:AB')).topLeft + const Offset(36, 11)); // on the room's name
    await arrive(tester);
    expect(find.text('K1'), findsNothing);
    expect(key('room:AB'), findsNothing); // a room by itself needs no frame
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Main dining')).selected, isTrue);
    // whose table, how many and for how long, and what it has run up
    expect(says(tester, 'B5'), ['B5', 'Ben', '2p 0m', '\$10.70']);
    expect(markSays(tester, 'A8'), '19:30');
    expect(tester.takeException(), isNull);

    // And back: every room is on the map again.
    await open(tester, 'Whole floor');
    expect(find.text('K1'), findsOneWidget);
    expect(says(tester, 'B5'), ['B5', '0m']);
    await stop(tester);
  });

  testWidgets('a table is larger in its room than on the whole floor, and stays inside the map', (tester) async {
    for (final view in [phone, tablet]) {
      await pumpMap(tester, size: view, setUp: busy);
      final before = tester.getSize(look('A7'));
      await open(tester, 'Main dining');
      final after = tester.getRect(look('A7'));
      expect(after.width, greaterThan(before.width * 1.2), reason: '$view');
      expect(after.shortestSide, greaterThanOrEqualTo(44), reason: 'a table a thumb finds, $view');
      for (final table in ['A1', 'A7', 'B1', 'B5', 'B8']) {
        final rect = tester.getRect(look(table));
        expect(rect.left >= 0 && rect.right <= view.width, isTrue, reason: '$table on $view');
        expect(rect.top >= 0 && rect.bottom <= view.height, isTrue, reason: '$table on $view');
      }
      await stop(tester);
    }
  });

  testWidgets('between the whole floor and a room the tables glide; with animations off they are there at once', (
    tester,
  ) async {
    await pumpMap(tester, size: tablet, setUp: busy);
    final whole = tester.getRect(look('A7'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Main dining'));
    await tester.pump();
    await tester.pump(FloorViewState.glideTime ~/ 2);
    // half way: A7 is between where it was and where it goes, and a table of another room is still leaving
    final half = tester.getRect(look('A7'));
    expect(find.text('K1'), findsOneWidget);
    await tester.pump(FloorViewState.glideTime);
    final there = tester.getRect(look('A7'));
    expect(there.width, greaterThan(whole.width));
    expect(half.width, inExclusiveRange(whole.width, there.width));
    expect(find.text('K1'), findsNothing);
    await stop(tester);

    // Somebody who has animations turned off on the device sees the room at once.
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpMap(tester, size: tablet, setUp: busy);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Main dining'));
    await tester.pump();
    expect(find.text('K1'), findsNothing);
    expect(tester.getRect(look('A7')).width, there.width);
    await stop(tester);
  });

  testWidgets('with large type the words are larger as far as a table can give it, and nothing runs over', (
    tester,
  ) async {
    await pumpMap(tester, size: phone, setUp: busy);
    await open(tester, 'Main dining');
    final plain = {
      for (final (table, words, size) in written(tester))
        if (words == table) table: size,
    };
    await stop(tester);
    for (final scale in [1.2, 2.0]) {
      await pumpMap(tester, size: phone, setUp: busy, textScale: scale);
      await open(tester, 'Main dining');
      expect(tester.takeException(), isNull, reason: 'type $scale');
      for (final (table, words, size) in written(tester)) {
        // (twice as large is more than a table has the room for: a third larger is where it stops)
        if (words == table) expect(size, closeTo(plain[table]! * (scale > 1.3 ? 1.3 : scale), 0.01), reason: table);
      }
      // a table still says first what matters most: B5 keeps its name and how long it has sat
      expect(says(tester, 'B5').first, 'B5');
      expect(says(tester, 'B5').any((words) => words.endsWith('0m')), isTrue, reason: 'type $scale');
      await stop(tester);
    }
  });

  testWidgets('a guest who carries a tag keeps the star on a table too small for the name', (tester) async {
    // On a Mac's whole floor A7 has the room to say whose it is.
    await pumpMap(tester, size: const Size(3400, 2200), setUp: lindaAtA7);
    expect((named(tester, 'A7'), starred(tester, 'A7')), ('Linda P.', true));
    await stop(tester);
    // On a phone's it has not: the name is left out, the star stays, and says who sits there when read out.
    await pumpMap(tester, size: phone, setUp: lindaAtA7);
    expect((named(tester, 'A7'), starred(tester, 'A7')), (null, true));
    expect(
      tester.widget<Icon>(key('table-guest-tagged:A7')).semanticLabel,
      'seated here: Linda P., tagged Catering client, VIP',
    );
    // a walk-in's table, and a free one, have no star
    expect(starred(tester, 'A8'), isFalse);
    await stop(tester);
  });

  testWidgets('no table stands under the buttons a screen floats over the map\'s corner', (tester) async {
    // A phone on its side: the floor reaches the bottom of the map, where the orders screen has Tab and To go.
    const view = Size(580, 430);
    Future<List<Rect>> tables({required bool buttons}) async {
      final hub = Hub()
        ..clockNow = seven
        ..floor = floorThatMoves()
        ..bookings = []
        ..parties = [];
      final api = PosApi(
        Settings(device: 't1', endpoints: ['http://hub:8000']),
        client: MockClient(hub.handle),
      );
      tester.view
        ..physicalSize = view
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: PosTheme.light(),
          home: Scaffold(
            floatingActionButton: buttons
                ? const SizedBox(
                    key: ValueKey('buttons'),
                    width: 216,
                    height: 56,
                    child: ColoredBox(color: Colors.red),
                  )
                : null,
            body: FloorView(api: api, onTable: (plan, table) {}, now: () => seven),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return [for (final table in tableIds) tester.getRect(look(table))];
    }

    final clear = await tables(buttons: true);
    final under = tester.getRect(key('buttons'));
    expect(clear.where((table) => table.overlaps(under)), isEmpty);
    for (final table in clear) {
      expect(table.left >= 0 && table.top >= 0 && table.right <= view.width, isTrue);
    }
    expect(tester.takeException(), isNull);
    await stop(tester);
    // (and on a screen with no buttons the map has that corner too: a table stands there)
    final all = await tables(buttons: false);
    expect(all.where((table) => table.overlaps(under)), isNotEmpty);
    await stop(tester);
  });
}
