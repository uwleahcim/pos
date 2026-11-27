import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/floor_edit.dart';

import 'floor_test.dart' show floorJson;

/// The floor plan while a manager draws it (lib/floor_edit.dart): what is picked, every change that can be
/// made to the rooms and tables, undoing them, what keeps a plan from being saved, and what is sent to the
/// hub. The restaurant's own plan is what is drawn on.

FloorEditor editor({Set<String> busy = const {}, Set<String> booked = const {}}) =>
    FloorEditor(FloorPlan.fromJson(floorJson()), busy: busy, booked: booked);

Map<String, dynamic> sent(FloorEditor editor, String label) =>
    (editor.toJson()['tables'] as List).cast<Map<String, dynamic>>().firstWhere((table) => table['label'] == label);

void main() {
  group('the plan as it is opened', () {
    test('nothing is changed, nothing is picked, and what would be saved is the plan itself', () {
      final plan = FloorPlan.fromJson(floorJson());
      final it = FloorEditor(plan);
      expect((it.changed, it.canUndo, it.canRedo), (false, false, false));
      expect(it.picked, isEmpty);
      expect(it.problems, isEmpty);
      final json = it.toJson();
      expect(json['rooms'], [
        for (final room in plan.rooms) {'id': room.id, 'name': room.name},
      ]);
      final tables = (json['tables'] as List).cast<Map<String, dynamic>>();
      expect(tables.length, plan.tables.length);
      for (final (at, table) in plan.tables.indexed) {
        expect(
          (tables[at]['id'], tables[at]['label'], tables[at]['room'], tables[at]['x'], tables[at]['y']),
          (table.id, table.label, table.room, table.x, table.y),
        );
        expect(
          (tables[at]['w'], tables[at]['seats'], tables[at]['shape'], tables[at]['rotation'], tables[at]['kind']),
          (table.w, table.seats, table.shape, table.rotation, table.kind),
        );
      }
    });

    test('a table is found where it stands: inside its own edge, turned or round, and near it for a finger', () {
      final it = editor();
      final a7 = it.table('A7')!; // a square on its corner
      expect(it.tableAt(a7.center)?.key, 'A7');
      // the corner of the frame round a table on its corner is not the table
      expect(it.tableAt(a7.bounds.topLeft + const Offset(3, 3)), isNull);
      expect(it.tableAt(a7.bounds.topLeft + const Offset(3, 3), within: 12)?.key, 'A7');
      final k1 = it.table('K1')!; // a round seat at the bar
      expect(it.tableAt(k1.center + Offset(k1.w / 2 - 1, 0))?.key, 'K1');
      expect(it.tableAt(k1.bounds.topLeft + const Offset(1, 1)), isNull);
      expect(it.tableAt(const Offset(-500, -500), within: 12), isNull);
    });
  });

  group('picking', () {
    test('one table, one more, one fewer, a whole room, every table, none', () {
      final it = editor();
      it.pick('A7');
      expect(it.picked, {'A7'});
      expect(it.only?.label, 'A7');
      it.pick('A8', more: true);
      expect(it.picked, {'A7', 'A8'});
      expect(it.only, isNull);
      it.pick('A7', more: true);
      expect(it.picked, {'A8'});
      it.pick('B5');
      expect(it.picked, {'B5'});
      it.pickRoom('JK');
      expect(it.pickedTables.every((table) => table.room == 'JK'), isTrue);
      expect(it.picked.length, it.tables.where((table) => table.room == 'JK').length);
      it.pickAll();
      expect(it.picked.length, it.tables.length);
      it.pickNone();
      expect(it.picked, isEmpty);
      expect(it.changed, isFalse); // picking changes nothing
    });
  });

  group('moving', () {
    test('a drag is one change however far it goes, and undo and redo take it back and forth', () {
      final it = editor()..pick('B5');
      final from = it.table('B5')!.center;
      it.hold();
      it.moveBy(const Offset(10, 0));
      it.moveBy(const Offset(40, 20));
      it.moveBy(const Offset(300, -40));
      it.release();
      expect(it.table('B5')!.center, from + const Offset(300, -40));
      expect((it.changed, it.canUndo, it.canRedo), (true, true, false));
      it.undo();
      expect(it.table('B5')!.center, from);
      expect((it.changed, it.canUndo, it.canRedo), (false, false, true));
      it.redo();
      expect(it.table('B5')!.center, from + const Offset(300, -40));
      // a new change after an undo leaves nothing to redo
      it.undo();
      it.nudge(const Offset(1, 0));
      expect(it.canRedo, isFalse);
    });

    test('a drag that ends where it began is no change', () {
      final it = editor()..pick('B5');
      it.hold();
      it.moveBy(const Offset(30, 30));
      it.moveBy(Offset.zero);
      it.release();
      expect((it.changed, it.canUndo), (false, false));
    });

    test('several tables move together and keep their places among themselves', () {
      final it = editor()
        ..pick('A7')
        ..pick('A8', more: true);
      final apart = it.table('A8')!.center - it.table('A7')!.center;
      it.hold();
      it.moveBy(const Offset(-200, 150));
      it.release();
      expect(it.table('A8')!.center - it.table('A7')!.center, apart);
      expect(it.table('A9')!.center, FloorEditor(FloorPlan.fromJson(floorJson())).table('A9')!.center);
    });

    test('a table brought near another table\'s line settles on it, and the line is shown while it is held', () {
      final it = editor()..pick('B6');
      final b5 = it.table('B5')!, b6 = it.table('B6')!;
      it.hold();
      // dropped two units off the height of B5's middle, a little to the right of where it stood
      final to = Offset(40, b5.y + 2 - b6.y);
      it.moveBy(to, within: 6);
      expect(it.table('B6')!.y, b5.y);
      final line = it.guides.singleWhere((guide) => !guide.upright);
      expect(line.at, anyOf(b5.y, b5.bounds.top, b5.bounds.bottom));
      it.release();
      expect(it.guides, isEmpty);
      expect(it.table('B6')!.y, b5.y);
    });

    test('with no table to line up with, its middle settles on the grid; with snapping off it stays put', () {
      final it = editor()..pick('B6');
      final b6 = it.table('B6')!;
      it.hold();
      it.moveBy(Offset(3000.3 - b6.x, 3000.7 - b6.y), within: 2);
      expect(it.table('B6')!.center, const Offset(3000, 3000));
      expect(it.guides, isEmpty);
      it.moveBy(Offset(3001.3 - b6.x, 3002.7 - b6.y));
      expect(it.table('B6')!.center, const Offset(3001.3, 3002.7));
      it.release();
    });

    test('an arrow key moves what is picked by a unit, and is undone by itself', () {
      final it = editor()..pick('K1');
      final from = it.table('K1')!.center;
      it.nudge(const Offset(0, -1));
      it.nudge(const Offset(10, 0));
      expect(it.table('K1')!.center, from + const Offset(10, -1));
      it.undo();
      expect(it.table('K1')!.center, from + const Offset(0, -1));
    });
  });

  group('sizing and turning', () {
    test('a table is sized about its middle, within what the hub takes; a round one stays round', () {
      final it = editor()..pick('B5');
      final middle = it.table('B5')!.center;
      it.hold();
      it.sizeTo('B5', 61.4, 5);
      it.release();
      expect((it.table('B5')!.w, it.table('B5')!.h, it.table('B5')!.center), (61, FloorEditor.sideMin, middle));
      it.pick('K1');
      it.size(w: 44);
      expect((it.table('K1')!.w, it.table('K1')!.h), (44, 44));
      it.size(h: 5000);
      expect((it.table('K1')!.w, it.table('K1')!.h), (FloorEditor.sideMax, FloorEditor.sideMax));
    });

    test('turning by the handle settles on every fifteenth degree; by the buttons it goes round', () {
      final it = editor()..pick('B5');
      it.hold();
      it.turnTo('B5', 43);
      expect(it.table('B5')!.rotation, 45);
      it.turnTo('B5', 38.4);
      expect(it.table('B5')!.rotation, 38);
      it.release();
      it.turn(170);
      it.turnBy(15);
      expect(it.table('B5')!.rotation, -175);
      // a round table has no way it is turned
      it.pick('K1');
      it.turnBy(45);
      expect(it.table('K1')!.rotation, 0);
      expect(it.canUndo, isTrue);
    });

    test('a table made round is as deep as it is wide and stands straight; made square again it keeps that', () {
      final it = editor()..pick('B5'); // 45 by 100
      it.turn(30);
      it.shape(round: true);
      final round = it.table('B5')!;
      expect((round.round, round.w, round.h, round.rotation), (true, 45, 45, 0));
      expect(sent(it, 'B5')['shape'], 'round');
      it.shape(round: false);
      expect((it.table('B5')!.round, it.table('B5')!.w, it.table('B5')!.h), (false, 45, 45));
    });

    test('seats, kind and room of everything picked at once', () {
      final it = editor()
        ..pick('A7')
        ..pick('A8', more: true);
      it.seats(6);
      it.kind('booth');
      it.toRoom('JK');
      for (final label in ['A7', 'A8']) {
        expect((sent(it, label)['seats'], sent(it, label)['kind'], sent(it, label)['room']), (6, 'booth', 'JK'));
      }
      it.seats(900);
      expect(it.table('A7')!.seats, FloorEditor.seatsMax);
      expect(sent(it, 'A9')['room'], 'AB');
    });
  });

  group('lining up', () {
    test('by an edge and by the middle', () {
      final it = editor()
        ..pick('B5')
        ..pick('A7', more: true)
        ..pick('K8', more: true);
      final left = it.pickedTables.map((table) => table.bounds.left).reduce((a, b) => a < b ? a : b);
      it.lineUp(LineUp.left);
      expect(it.pickedTables.map((table) => table.bounds.left), everyElement(closeTo(left, 0.01)));
      it.lineUp(LineUp.middle);
      expect(it.pickedTables.map((table) => table.y).toSet(), hasLength(1));
      it.undo();
      it.undo();
      expect(it.changed, isFalse);
    });

    test('three tables spread out have the same gap between them, and the outer two stay', () {
      final it = editor()..pick('K2');
      it.nudge(const Offset(7, 0)); // K2 is no longer half way between K1 and K3
      it
        ..pick('K1')
        ..pick('K2', more: true)
        ..pick('K3', more: true);
      final (first, last) = (it.table('K1')!.x, it.table('K3')!.x);
      it.spread(across: true);
      final k1 = it.table('K1')!, k2 = it.table('K2')!, k3 = it.table('K3')!;
      expect((k1.x, k3.x), (first, last));
      expect(k2.bounds.left - k1.bounds.right, closeTo(k3.bounds.left - k2.bounds.right, 0.02));
    });

    test('the same size as the first one picked', () {
      final it = editor()
        ..pick('B5')
        ..pick('A1', more: true);
      it.sameSize();
      final first = it.pickedTables.first;
      expect(it.pickedTables.map((table) => (table.w, table.h)).toSet(), {(first.w, first.h)});
    });
  });

  group('new tables', () {
    test('a table is put down on free floor beside what is picked, named next in its room, and picked', () {
      final it = editor()..pick('A9');
      final key = it.add(tablePresets.firstWhere((preset) => preset.name == 'Table for 4'))!;
      final made = it.table(key)!;
      expect((made.label, made.room, made.seats, made.id), ('A10', 'AB', 4, null));
      expect(it.picked, {key});
      expect(it.tables.where((table) => table.key != key && table.overlaps(made)), isEmpty);
      expect(it.crowded, isNot(contains(key)));
      // it is a new table to the hub, by the name on it
      expect((sent(it, 'A10')['id'], sent(it, 'A10')['room']), ('A10', 'AB'));
      it.undo();
      expect(it.table(key), isNull);
      expect(it.picked, isEmpty);
    });

    test('put down at a point, it is in the room there, on free floor, named next in that room', () {
      final it = editor();
      // in the middle of the bar, where K8 stands
      final k8 = it.table('K8')!;
      final key = it.add(tablePresets.firstWhere((preset) => preset.name == 'Seat at the bar'), at: k8.center)!;
      final made = it.table(key)!;
      expect((made.room, made.kind, made.round), ('JK', 'counter', true));
      expect(it.tables.where((table) => table.key != key && table.overlaps(made)), isEmpty);
      expect((made.center - k8.center).distance, lessThan(160));
      expect(it.tables.where((table) => table.key != key).map((table) => table.label), isNot(contains(made.label)));
      // a point off every room is in the room nearest to it
      expect(it.roomAt(const Offset(-500, -500)), isNotNull);
      expect(it.roomAt(it.table('D4')!.center), it.table('D4')!.room);
      expect(it.roomAt(it.table('A5')!.center), 'AB');
    });

    test('the next name follows how the room names its tables, and is one no table has', () {
      final it = editor();
      expect(it.nextName('AB'), 'A10');
      expect(it.nextName('D'), anyOf('D9', 'C7'));
      it.pick('A9');
      it.rename('A9', 'A10');
      expect(it.nextName('AB'), 'A11');
      final patio = it.addRoom('Patio')!;
      expect(it.nextName(patio), 'P1');
    });

    test('a copy stands beside its table with the next name, as large and turned the same', () {
      final it = editor()
        ..pick('A7')
        ..pick('K1', more: true);
      it.duplicate();
      final copies = it.pickedTables;
      expect(copies.map((table) => table.label).toSet(), hasLength(2));
      expect(copies.every((table) => table.id == null), isTrue);
      final ofA7 = copies.firstWhere((table) => !table.round);
      expect((ofA7.w, ofA7.h, ofA7.rotation, ofA7.seats, ofA7.room), (55, 55, 45, 4, 'AB'));
      expect(it.tables.length, FloorPlan.fromJson(floorJson()).tables.length + 2);
      expect(it.problems, isEmpty);
      it.undo(); // both copies are one change
      expect(it.tables.length, FloorPlan.fromJson(floorJson()).tables.length);
    });

    test('a table taken off is gone from what is saved, and back with undo', () {
      final it = editor()..pick('A9');
      expect(it.remove(), isEmpty);
      expect(it.table('A9'), isNull);
      expect((it.toJson()['tables'] as List).any((table) => (table as Map)['id'] == 'A9'), isFalse);
      it.undo();
      expect(it.table('A9'), isNotNull);
    });
  });

  group('a table in use', () {
    test('can be moved, sized and turned, and neither renamed nor taken off the plan', () {
      final it = editor(busy: {'A7'}, booked: {'A8'})
        ..pick('A7')
        ..pick('A8', more: true)
        ..pick('A9', more: true);
      expect(it.inUse(it.table('A7')!), 'A7 has an open check');
      expect(it.inUse(it.table('A8')!), 'A8 is held by a reservation');
      expect(it.inUse(it.table('A9')!), isNull);
      it.rename('A7', 'X1');
      expect(it.table('A7')!.label, 'A7');
      expect(it.remove(), ['A7 has an open check', 'A8 is held by a reservation']);
      expect([for (final table in it.tables) table.label], containsAll(['A7', 'A8']));
      expect(it.table('A9'), isNull);
      expect(it.picked, {'A7', 'A8'});
      it.nudge(const Offset(5, 5));
      it.turnBy(15);
      expect((sent(it, 'A7')['id'], sent(it, 'A7')['rotation']), ('A7', 60));
    });
  });

  group('names', () {
    test('a renamed table is a new table to the hub by its new name; named back, it is the old one again', () {
      final it = editor();
      it.rename('A9', 'W1');
      expect((sent(it, 'W1')['id'], it.table('A9')!.label), ('W1', 'W1'));
      it.rename('A9', 'A9');
      expect(sent(it, 'A9')['id'], 'A9');
      expect(it.changed, isFalse);
    });

    test('two tables that swap names are sent under the names they now have', () {
      final it = editor();
      it.rename('A8', 'tmp');
      it.rename('A9', 'A8');
      it.rename('A8', 'A9');
      expect(it.problems, isEmpty);
      final ids = [for (final table in it.toJson()['tables'] as List) (table as Map)['id']];
      expect(ids.toSet().length, ids.length);
      final where = {for (final table in it.tables) table.label: table.key};
      expect((where['A8'], where['A9']), ('A9', 'A8'));
      expect((sent(it, 'A8')['id'], sent(it, 'A9')['id']), ('A8', 'A9'));
    });

    test('what keeps a plan from being saved is said in words', () {
      final it = editor();
      it.rename('A8', 'A9');
      expect(it.problems, ['Two tables are called "A9".']);
      it.rename('A8', '');
      expect(it.problems, ['A table has no name.']);
      it.rename('A8', 'Window-12');
      expect(it.problems, ['The table name "Window-12" is longer than 8 letters.']);
      it.rename('A8', 'A 8');
      expect(it.problems, ['The table name "A 8" may have letters, figures, - and _ only.']);
      it.rename('A8', 'a9'); // the same name in other letters
      expect(it.problems, ['Two tables are called "A9".']);
      it.rename('A8', 'A8');
      it.renameRoom('AB', 'bar and lounge');
      expect(it.problems, ['Two rooms are called "Bar and lounge".']);
      it.renameRoom('AB', '');
      expect(it.problems, ['A room has no name.']);
      it.renameRoom('AB', 'Main dining');
      expect(it.problems, isEmpty);
      expect(it.changed, isFalse);
    });

    test('tables that stand on each other\'s ground are pointed out, and may be saved', () {
      final it = editor();
      expect(it.crowded, isEmpty);
      it.pick('A8');
      it.hold();
      it.moveBy(it.table('A7')!.center - it.table('A8')!.center + const Offset(20, 0));
      it.release();
      expect(it.crowded, {'A7', 'A8'});
      expect(it.problems, isEmpty);
      // two tables on their corners whose frames overlap and that do not touch are not crowded
      it.undo();
      final a7 = it.table('A7')!;
      it.hold();
      it.moveBy(a7.center + Offset(a7.reach.$1 * 1.2, a7.reach.$2 * 1.2) - it.table('A8')!.center);
      it.release();
      expect(it.table('A8')!.bounds.overlaps(it.table('A7')!.bounds), isTrue);
      expect(it.crowded, isEmpty);
    });
  });

  group('rooms', () {
    test('a new room has no id until it is saved: its tables are sent by its place in the list', () {
      final it = editor();
      final patio = it.addRoom('  Patio ')!;
      expect(it.rooms.last.name, 'Patio');
      it.pick('K9');
      it.toRoom(patio);
      final json = it.toJson();
      expect((json['rooms'] as List).last, {'name': 'Patio'});
      expect(sent(it, 'K9')['room'], '#3');
      final key = it.add(tablePresets.first, room: patio)!;
      expect((it.table(key)!.room, sent(it, it.table(key)!.label)['room']), (patio, '#3'));
    });

    test('renamed, moved in the order the map lists them, and taken off only when empty', () {
      final it = editor();
      it.renameRoom('JK', 'Bar');
      it.moveRoom('JK', -5);
      expect(it.rooms.map((room) => room.name), ['Bar', 'Dining room C & D', 'Main dining']);
      expect(it.removeRoom('JK'), isFalse); // its tables are still there
      final empty = it.addRoom('Patio')!;
      expect(it.removeRoom(empty), isTrue);
      expect(it.rooms.length, 3);
      it.pickRoom('JK');
      it.toRoom('AB');
      expect(it.removeRoom('JK'), isTrue);
      expect(it.frameOf('JK'), isNull);
      expect(it.frameOf('AB')!.contains(it.table('K9')!.center), isTrue);
      // the last room cannot go
      it.pickRoom('D');
      it.toRoom('AB');
      expect(it.removeRoom('D'), isTrue);
      expect(it.removeRoom('AB'), isFalse);
    });
  });
}
