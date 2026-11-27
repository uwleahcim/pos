import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/floor_editor.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/theme.dart';

import 'hub.dart';
import 'ticket_words_test.dart' show show;

/// The floor editor's screen (lib/screens/floor_editor.dart, docs/floor-editor.md): a manager picks tables
/// on the plan, drags, sizes and turns them there, and does the rest in the list beside it (under it on a
/// phone). Nothing reaches the hub before Save. The rules of editing themselves are in floor_edit_test.dart.

const phone = Size(390, 844), tablet = Size(1180, 820);

Finder key(String name) => find.byKey(ValueKey(name));

/// The editor on a screen of [size], with the hub's plan read; [setUp] says how the hub stands first.
Future<(Hub, FloorEditorScreenState)> pumpEditor(
  WidgetTester tester, {
  Size size = tablet,
  void Function(Hub hub)? setUp,
  bool dark = false,
}) async {
  final t = await terminal(tester);
  setUp?.call(t.hub);
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? PosTheme.dark() : PosTheme.light(),
      home: FloorEditorScreen(api: t.api, token: 'tok-admin'),
    ),
  );
  await tester.pumpAndSettle();
  return (t.hub, tester.state<FloorEditorScreenState>(find.byType(FloorEditorScreen)));
}

/// Where the middle of [table] is on the screen.
Offset at(WidgetTester tester, FloorEditorScreenState state, String table) =>
    tester.getTopLeft(key('floor-canvas')) + state.toScreen(state.editor!.table(table)!.center);

/// How many points of the screen one unit of the plan is.
double scaleOf(FloorEditorScreenState state) => (state.toScreen(const Offset(1, 0)) - state.toScreen(Offset.zero)).dx;

Future<void> pick(WidgetTester tester, FloorEditorScreenState state, String table) async {
  await tester.tapAt(at(tester, state, table));
  await tester.pump();
}

/// A finger (or the mouse) comes down at [from], goes [by] in two steps and is lifted.
Future<void> drag(
  WidgetTester tester,
  Offset from,
  Offset by, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final finger = await tester.startGesture(from, kind: kind);
  await finger.moveBy(by / 2);
  await finger.moveBy(by / 2);
  await finger.up();
  await tester.pump();
}

/// Taps Save, once the Save bar has come up, and waits for the hub's answer.
Future<void> save(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(key('floor-save'));
  await tester.pumpAndSettle();
}

/// Taps [name] in the list, which is brought into sight first.
/// (The first change brings the Save bar up, and a list at its end is kept there while it rises: each tap
/// waits for that.)
Future<void> tapIn(WidgetTester tester, String name) async {
  await tester.ensureVisible(key(name));
  await tester.pumpAndSettle();
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

Map<String, dynamic> sentTable(Hub hub, String label) => (hub.floorPlansSent.last['tables'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((table) => table['label'] == label);

void main() {
  testWidgets('the plan opens as the floor has it, with nothing to save', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    expect(find.text('Floor plan'), findsOneWidget);
    expect(state.editor!.tables, hasLength(42));
    expect(state.editor!.changed, isFalse);
    expect(key('floor-save'), findsNothing);
    expect(find.text('ADD A TABLE'), findsOneWidget);
    // the whole of it is on the canvas
    final canvas = tester.getRect(key('floor-canvas'));
    for (final table in state.editor!.tables) {
      expect(canvas.contains(canvas.topLeft + state.toScreen(table.center)), isTrue, reason: table.label);
    }
    expect(hub.floorPlansSent, isEmpty);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  testWidgets('a tap picks a table, a drag moves it, and Save sends the plan as the manager', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    await pick(tester, state, 'A9');
    expect(state.editor!.picked, {'A9'});
    expect(find.text('TABLE A9'), findsOneWidget);
    expect(tester.widget<TextField>(key('table-name')).controller!.text, 'A9');

    final before = state.editor!.table('A9')!.center, scale = scaleOf(state);
    await drag(tester, at(tester, state, 'A9'), const Offset(80, -30));
    final after = state.editor!.table('A9')!.center;
    // it went as far as the finger did, and settled on the grid or on a neighbour's line near there
    final off = after - (before + const Offset(80, -30) / scale);
    expect(off.dx.abs(), lessThanOrEqualTo(7 / scale + 0.01));
    expect(off.dy.abs(), lessThanOrEqualTo(7 / scale + 0.01));
    expect(state.editor!.guides, isEmpty); // the lines go when the finger is lifted
    await tester.pumpAndSettle();
    expect(find.text('Floor plan not saved'), findsOneWidget);
    final shown = at(tester, state, 'A9'), a8 = state.editor!.table('A8')!.center;

    await save(tester);
    expect(hub.floorPlanAuth, 'Bearer tok-admin');
    final sent = sentTable(hub, 'A9');
    expect((sent['id'], sent['x'], sent['y']), ('A9', after.dx, after.dy));
    expect((hub.floorPlansSent.single['tables'] as List), hasLength(42));
    expect(find.text('Floor plan saved'), findsOneWidget);
    expect(state.editor!.changed, isFalse);
    // The hub keeps a plan a margin from its corner, and may hand it back with every table moved by the
    // same amount. On the screen nothing has moved.
    expect((at(tester, state, 'A9') - shown).distance, lessThan(1));
    expect(state.editor!.table('A9')!.center - state.editor!.table('A8')!.center, after - a8);
    await stop(tester);
  });

  testWidgets('a finger on a table that is not picked moves the plan; a mouse picks the table and moves it', (
    tester,
  ) async {
    final (_, state) = await pumpEditor(tester);
    final before = state.editor!.table('A9')!.center, where = state.toScreen(Offset.zero);
    await drag(tester, at(tester, state, 'A9'), const Offset(120, 0));
    expect(state.editor!.table('A9')!.center, before);
    expect(state.editor!.picked, isEmpty);
    expect(state.toScreen(Offset.zero).dx, greaterThan(where.dx + 40));
    expect(state.editor!.changed, isFalse);

    await drag(tester, at(tester, state, 'A9'), const Offset(60, 0), kind: PointerDeviceKind.mouse);
    expect(state.editor!.picked, {'A9'});
    expect(state.editor!.table('A9')!.center.dx, greaterThan(before.dx + 40));
    // one step back, and it is where it was
    await tester.tap(key('floor-undo'));
    await tester.pump();
    expect(state.editor!.table('A9')!.center, before);
    await tester.tap(key('floor-redo'));
    await tester.pump();
    expect(state.editor!.table('A9')!.center.dx, greaterThan(before.dx + 40));
    await stop(tester);
  });

  testWidgets('two fingers make the plan larger about where they are, and the buttons do too', (tester) async {
    final (_, state) = await pumpEditor(tester);
    final scale = scaleOf(state);
    final middle = tester.getCenter(key('floor-canvas'));
    final one = await tester.startGesture(middle - const Offset(40, 0), pointer: 5);
    final two = await tester.startGesture(middle + const Offset(40, 0), pointer: 6);
    await one.moveBy(const Offset(-40, 0));
    await two.moveBy(const Offset(40, 0));
    await one.up();
    await two.up();
    await tester.pump();
    expect(scaleOf(state), greaterThan(scale * 1.2));
    expect(state.editor!.changed, isFalse);

    await tester.tap(key('zoom-fit'));
    await tester.pump();
    expect(scaleOf(state), closeTo(scale, 0.001));
    await tester.tap(key('zoom-in'));
    await tester.pump();
    expect(scaleOf(state), closeTo(scale * 1.3, 0.001));
    await tester.tap(key('zoom-out'));
    await tester.pump();
    expect(scaleOf(state), closeTo(scale, 0.001));
    await stop(tester);
  });

  testWidgets('the corner sizes the picked table about its middle and the knob above it turns it', (tester) async {
    final (_, state) = await pumpEditor(tester);
    await pick(tester, state, 'B6');
    final b6 = state.editor!.table('B6')!, scale = scaleOf(state);
    await drag(tester, tester.getCenter(key('handle-size')), const Offset(30, 40));
    final sized = state.editor!.table('B6')!;
    expect(sized.center, b6.center);
    expect(sized.w, closeTo(b6.w + 2 * 30 / scale, 1));
    expect(sized.h, closeTo(b6.h + 2 * 40 / scale, 1));

    // The knob is straight above a table, or straight under one that stands at the top edge of the plan, as
    // B6 does. Taken a quarter of the way round, the table has turned a quarter.
    final middle = at(tester, state, 'B6'), knob = tester.getCenter(key('handle-turn'));
    expect(knob.dx, closeTo(middle.dx, 0.01));
    expect(knob.dy, greaterThan(middle.dy));
    final reach = (knob - middle).distance;
    await drag(tester, knob, Offset(-reach, -reach));
    expect(state.editor!.table('B6')!.rotation, 90);
    expect(find.text('TURN (90°)'), findsOneWidget);
    // two changes, two steps back
    await tester.tap(key('floor-undo'));
    await tester.tap(key('floor-undo'));
    await tester.pump();
    expect(state.editor!.changed, isFalse);
    await stop(tester);
  });

  testWidgets('the list has the rest of a table: its name, seats, shape, kind, room, size and turn', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    await pick(tester, state, 'A9');
    await tester.enterText(key('table-name'), 'W1');
    await tester.pump();
    expect(find.text('TABLE W1'), findsOneWidget);
    await tapIn(tester, 'seats-more');
    await tapIn(tester, 'seats-more');
    expect(tester.widget<Text>(key('seats-value')).data, '6');
    await tester.tap(find.descendant(of: key('table-kind'), matching: find.text('Booth')));
    await tester.pump();
    await tapIn(tester, 'table-room:JK');
    await tapIn(tester, 'width-more');
    await tapIn(tester, 'depth-less');
    await tapIn(tester, 'turn-straight');
    await tapIn(tester, 'turn-right');
    final a9 = state.editor!.table('A9')!;
    expect((a9.label, a9.seats, a9.kind, a9.room, a9.w, a9.h, a9.rotation), ('W1', 6, 'booth', 'JK', 56, 54, 15));

    // round: one size, and nothing to turn
    await tester.ensureVisible(key('table-shape'));
    await tester.pump();
    await tester.tap(find.descendant(of: key('table-shape'), matching: find.text('Round')));
    await tester.pump();
    expect(state.editor!.table('A9')!.round, isTrue);
    expect(key('depth-more'), findsNothing);
    expect(key('turn-right'), findsNothing);
    expect(key('handle-turn'), findsNothing);
    expect(find.text('Across'), findsOneWidget);

    await save(tester);
    final sent = sentTable(hub, 'W1');
    // a renamed table is a new table to the hub, by the name on it
    expect((sent['id'], sent['seats'], sent['kind'], sent['room'], sent['shape']), ('W1', 6, 'booth', 'JK', 'round'));
    expect((hub.floorPlansSent.last['tables'] as List).any((table) => (table as Map)['id'] == 'A9'), isFalse);
    await stop(tester);
  });

  testWidgets('a copy, a new table ready-made, and a table taken off', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    await pick(tester, state, 'A9');
    await tapIn(tester, 'table-duplicate');
    // the copy is what is picked now, named next in its room
    expect(find.text('TABLE A10'), findsOneWidget);
    expect(state.editor!.tables, hasLength(43));

    await tapIn(tester, 'pick-none');
    expect(state.editor!.picked, isEmpty);
    await tapIn(tester, 'preset:Round for 8');
    final made = state.editor!.only!;
    expect((made.round, made.seats, made.w), (true, 8, 75));
    expect(state.editor!.crowded, isNot(contains(made.key)));
    // (it stands where it can be seen)
    final canvas = tester.getRect(key('floor-canvas'));
    expect(canvas.contains(canvas.topLeft + state.toScreen(made.center)), isTrue);

    await tapIn(tester, 'pick-none');
    await pick(tester, state, 'B8');
    await tapIn(tester, 'table-delete');
    expect(state.editor!.table('B8'), isNull);
    expect(find.text('ADD A TABLE'), findsOneWidget);

    await save(tester);
    final labels = [for (final table in hub.floorPlansSent.single['tables'] as List) (table as Map)['label']];
    expect(labels, hasLength(43));
    expect(labels, containsAll(['A10', made.label]));
    expect(labels, isNot(contains('B8')));
    await stop(tester);
  });

  testWidgets('a table in use keeps its name and stays on the plan, and says why', (tester) async {
    final (_, state) = await pumpEditor(
      tester,
      setUp: (hub) => hub
        ..floorBusy = ['A7']
        ..floorBooked = ['A8'],
    );
    await pick(tester, state, 'A7');
    expect(tester.widget<TextField>(key('table-name')).enabled, isFalse);
    expect(find.text('A7 has an open check: it keeps its name'), findsOneWidget);
    await tapIn(tester, 'table-delete');
    expect(state.editor!.table('A7'), isNotNull);
    expect(find.text('A7 has an open check. It stays on the plan until that is done with.'), findsOneWidget);
    expect(state.editor!.changed, isFalse);
    // it can still be moved
    await drag(tester, at(tester, state, 'A7'), const Offset(0, 60));
    expect(state.editor!.changed, isTrue);

    await pick(tester, state, 'A8');
    expect(find.text('A8 is held by a reservation: it keeps its name'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('several tables are picked one tap at a time, lined up and spaced evenly', (tester) async {
    final (_, state) = await pumpEditor(tester);
    await tester.tap(key('floor-several'));
    await tester.pump();
    for (final table in ['A1', 'A2', 'A3']) {
      await pick(tester, state, table);
    }
    expect(state.editor!.picked, {'A1', 'A2', 'A3'});
    expect(find.text('3 TABLES'), findsOneWidget);
    // one of them dragged takes the others along
    final apart = state.editor!.table('A3')!.center - state.editor!.table('A1')!.center;
    await drag(tester, at(tester, state, 'A2'), const Offset(0, 50));
    expect(state.editor!.table('A3')!.center - state.editor!.table('A1')!.center, apart);
    expect(state.editor!.changed, isTrue);

    state.editor!.pick('A2', more: true); // (A2 let go: A1 and A3 stay picked)
    await tester.pump();
    expect(find.text('2 TABLES'), findsOneWidget);
    state.editor!.nudge(const Offset(0, 9));
    state.editor!.pick('A2', more: true);
    await tester.pump();
    await tapIn(tester, 'line-top');
    final tops = {for (final table in state.editor!.pickedTables) table.bounds.top};
    expect(tops, hasLength(1));
    await tapIn(tester, 'spread-across');
    final xs = [for (final table in state.editor!.pickedTables) table.x]..sort();
    expect(xs[1] - xs[0], closeTo(xs[2] - xs[1], 0.011));

    // a tap on the plan's floor lets nothing go while several are being picked; Done does
    await tester.tapAt(tester.getRect(key('floor-canvas')).bottomRight - const Offset(8, 8));
    await tester.pump();
    expect(state.editor!.picked, hasLength(3));
    await tapIn(tester, 'pick-none');
    expect(state.editor!.picked, isEmpty);
    await stop(tester);
  });

  testWidgets('a room is added, named, moved in the list and taken off; a table goes to a new room', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    await tapIn(tester, 'add-room');
    await tester.pumpAndSettle();
    await tester.enterText(key('room-name-field'), 'Patio');
    await tester.tap(key('room-name-ok'));
    await tester.pumpAndSettle();
    expect(find.text('Patio'), findsOneWidget);
    final patio = state.editor!.rooms.last;
    expect((patio.name, patio.id), ('Patio', null));
    expect(tester.widget<IconButton>(key('room-remove:${patio.key}')).onPressed, isNotNull);

    await pick(tester, state, 'A9');
    await tapIn(tester, 'table-room:${patio.key}');
    await tapIn(tester, 'pick-none');
    // a room with a table in it stays, and says how many it has
    await tester.ensureVisible(key('room-row:${patio.key}'));
    await tester.pump();
    expect(find.descendant(of: key('room-row:${patio.key}'), matching: find.text('1 table')), findsOneWidget);
    expect(tester.widget<IconButton>(key('room-remove:${patio.key}')).onPressed, isNull);
    await tapIn(tester, 'room-up:${patio.key}');
    expect(state.editor!.rooms.indexOf(patio), state.editor!.rooms.length - 2);

    // renamed with a tap on its name
    await tapIn(tester, 'room-name:${patio.key}');
    await tester.pumpAndSettle();
    await tester.enterText(key('room-name-field'), 'Garden');
    await tester.tap(key('room-name-ok'));
    await tester.pumpAndSettle();

    await save(tester);
    final sent = hub.floorPlansSent.single;
    final at = (sent['rooms'] as List).indexWhere((room) => (room as Map)['name'] == 'Garden');
    expect(at, (sent['rooms'] as List).length - 2);
    expect((sent['rooms'] as List)[at], {'name': 'Garden'}); // no id yet: the hub gives it one
    expect(sentTable(hub, 'A9')['room'], '#$at');
    // read back from the hub, the room has its id and the table is in it
    final garden = state.editor!.rooms.firstWhere((room) => room.name == 'Garden');
    expect(garden.id, 'garden');
    expect(state.editor!.table('A9')!.room, garden.key);
    expect(state.editor!.changed, isFalse);
    await stop(tester);
  });

  testWidgets('what keeps the plan from being saved is said in the Save bar, and Save waits for it', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    await pick(tester, state, 'A9');
    await tester.enterText(key('table-name'), 'A8');
    await tester.pumpAndSettle();
    expect(find.text('Two tables are called "A8".'), findsOneWidget);
    expect(tester.widget<FilledButton>(key('floor-save')).onPressed, isNull);
    await tester.enterText(key('table-name'), 'A90');
    await tester.pumpAndSettle();
    expect(find.text('Two tables are called "A8".'), findsNothing);
    expect(tester.widget<FilledButton>(key('floor-save')).onPressed, isNotNull);

    // The hub's own reason, when it refuses: somebody opened a check at A9 while the plan was being drawn.
    hub.refuseFloorPlan = (
      409,
      'table_busy',
      'Table A9 has an open check: close it or move it to another table first.',
    );
    await save(tester);
    expect(find.text('Table A9 has an open check: close it or move it to another table first.'), findsOneWidget);
    expect(state.editor!.changed, isTrue);
    expect(hub.floorDrawn, isNull);
    // the next change is a new plan: what the hub said about the last one goes
    await tapIn(tester, 'seats-more');
    await tester.pumpAndSettle();
    expect(find.text('Table A9 has an open check: close it or move it to another table first.'), findsNothing);
    await stop(tester);
  });

  testWidgets('the original plan is put back only when asked twice, and only when there is a drawn one', (
    tester,
  ) async {
    final (hub, state) = await pumpEditor(tester);
    await tester.tap(key('floor-more'));
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuItem<String>>(key('floor-put-back')).enabled, isFalse);
    await tester.tapAt(const Offset(5, 400));
    await tester.pumpAndSettle();

    await pick(tester, state, 'B8');
    await tapIn(tester, 'table-delete');
    await save(tester);
    expect(hub.floorDrawn, isNotNull);
    expect(state.editor!.tables, hasLength(41));

    await tester.tap(key('floor-more'));
    await tester.pumpAndSettle();
    await tester.tap(key('floor-put-back'));
    await tester.pumpAndSettle();
    expect(find.text('Put back the original plan?'), findsOneWidget);
    expect(hub.floorDrawn, isNotNull);
    await tester.tap(key('floor-put-back-yes'));
    await tester.pumpAndSettle();
    expect(hub.floorDrawn, isNull);
    expect(state.editor!.tables, hasLength(42));
    expect(state.editor!.table('B8'), isNotNull);
    expect(find.text('The original plan is back'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('the keys of a Mac: arrows move, Delete takes off, Command-Z undoes, Escape lets go', (tester) async {
    final (_, state) = await pumpEditor(tester);
    await pick(tester, state, 'A9');
    final before = state.editor!.table('A9')!.center;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(state.editor!.table('A9')!.center, before + const Offset(1, 10));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(state.editor!.tables, hasLength(43));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(state.editor!.tables, hasLength(42));
    expect(state.editor!.table('A9'), isNotNull);

    for (var step = 0; step < 4; step++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    }
    await tester.pump();
    expect(state.editor!.changed, isFalse);
    expect(state.editor!.table('A9')!.center, before);

    await pick(tester, state, 'A9');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.editor!.picked, isEmpty);
    // a letter typed in the name's field is a letter, not a key of the plan
    await pick(tester, state, 'A9');
    await tester.tap(key('table-name'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(state.editor!.table('A9'), isNotNull);
    await stop(tester);
  });

  testWidgets('on a phone the list is under the plan and can be put away, and nothing runs over', (tester) async {
    for (final dark in [false, true]) {
      final (_, state) = await pumpEditor(tester, size: phone, dark: dark);
      final plan = tester.getRect(key('floor-canvas'));
      expect(tester.getRect(key('floor-panel')).top, greaterThan(plan.bottom));
      expect(plan.width, phone.width);
      await pick(tester, state, 'D4');
      expect(find.text('TABLE D4'), findsOneWidget);
      // put away, the bar says what the list is about and the plan has the room
      await tester.tap(key('panel-toggle'));
      await tester.pumpAndSettle();
      expect(key('floor-panel'), findsNothing);
      expect(find.text('Table D4'), findsOneWidget);
      expect(tester.getRect(key('floor-canvas')).height, greaterThan(plan.height + 200));
      await tester.tap(key('panel-toggle'));
      await tester.pumpAndSettle();
      expect(key('floor-panel'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      await stop(tester);
    }
  });

  testWidgets('with something changed the whole plan is still on the screen above the Save bar', (tester) async {
    for (final size in [phone, tablet]) {
      final (_, state) = await pumpEditor(tester, size: size);
      await pick(tester, state, 'A9');
      await tapIn(tester, 'seats-more');
      await tester.pumpAndSettle();
      expect(key('floor-save'), findsOneWidget);
      final canvas = tester.getRect(key('floor-canvas'));
      for (final table in state.editor!.tables) {
        expect(canvas.contains(canvas.topLeft + state.toScreen(table.center)), isTrue, reason: '${table.label}, $size');
      }
      await stop(tester);
    }
  });

  testWidgets('the plan stands still while the Save bar comes up, and while it goes', (tester) async {
    for (final size in [phone, tablet]) {
      final (_, state) = await pumpEditor(tester, size: size);
      await pick(tester, state, 'A9');
      await tester.ensureVisible(key('seats-more'));
      await tester.pumpAndSettle();
      final shown = at(tester, state, 'C3'), scale = scaleOf(state);

      /// Frame by frame for as long as the bar takes, and a while after: nothing is seen to move.
      Future<void> still(String when) async {
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect((at(tester, state, 'C3') - shown).distance, lessThan(1), reason: '$when, frame $frame, $size');
          expect(scaleOf(state) / scale, closeTo(1, 0.004), reason: '$when, frame $frame, $size');
        }
        await tester.pumpAndSettle();
        expect((at(tester, state, 'C3') - shown).distance, lessThan(1), reason: '$when, at rest, $size');
      }

      // a change made in the list, with no finger on the plan
      await tester.tap(key('seats-more'));
      await still('the bar comes up');
      expect(key('floor-save'), findsOneWidget);
      // the only change is taken back, and the bar goes
      await tester.tap(key('floor-undo'));
      await still('the bar goes');
      expect(key('floor-save'), findsNothing);
      await stop(tester);
    }
  });

  testWidgets('after Save the plan is where it was on the screen, made larger and moved or not', (tester) async {
    final (hub, state) = await pumpEditor(tester);
    // (the hub keeps a plan a margin from its corner: it hands this one back with every table moved)
    await pick(tester, state, 'D8');
    await drag(tester, at(tester, state, 'D8'), const Offset(-60, -40));
    await tester.pumpAndSettle();
    var shown = at(tester, state, 'A9');
    await save(tester);
    expect(hub.floorPlansSent, hasLength(1));
    expect((at(tester, state, 'A9') - shown).distance, lessThan(1));

    // made larger and moved by hand: to the point
    // "Floor plan saved" is said in the middle of the foot, off the list and off the plan's buttons: the
    // manager goes on at once
    expect(find.text('Floor plan saved'), findsOneWidget);
    final said = tester.getRect(find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);
    expect(said.overlaps(tester.getRect(key('floor-panel'))), isFalse);
    expect(said.overlaps(tester.getRect(key('zoom-in'))), isFalse);
    await pick(tester, state, 'D8');
    await tapIn(tester, 'table-delete');
    expect(state.editor!.table('D8'), isNull);
    final whole = scaleOf(state);
    await tester.tap(key('zoom-in'));
    await tester.pump();
    await pick(tester, state, 'A9');
    await drag(tester, at(tester, state, 'A9'), const Offset(40, 20));
    await tester.pumpAndSettle();
    shown = at(tester, state, 'A9');
    final larger = scaleOf(state);
    expect(larger, greaterThan(whole));
    await save(tester);
    expect(hub.floorPlansSent, hasLength(2));
    expect(scaleOf(state), larger);
    expect((at(tester, state, 'A9') - shown).distance, lessThan(0.01));
    await stop(tester);
  });

  testWidgets('Location has the way in, and a hub older than the editor says so', (tester) async {
    final t = await terminal(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    await show(tester, key('floor-plan'));
    await tester.tap(key('floor-plan'));
    await tester.pumpAndSettle();
    final state = tester.state<FloorEditorScreenState>(find.byType(FloorEditorScreen));
    expect(state.editor!.tables, hasLength(42));

    // changed and left: it asks first, and nothing was sent
    await pick(tester, state, 'A9');
    await tapIn(tester, 'seats-more');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('The floor plan you drew is not saved.'), findsOneWidget);
    expect(t.hub.floorPlansSent, isEmpty);
    await stop(tester);

    t.hub.floorEditor = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FloorEditorScreen(api: t.api, token: 'tok-admin'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('This hub is older than the floor editor'), findsOneWidget);
    expect(find.textContaining('sudo hubctl update'), findsOneWidget);
    // updated, it reads at the next try
    t.hub.floorEditor = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('ADD A TABLE'), findsOneWidget);
    await stop(tester);
  });
}
