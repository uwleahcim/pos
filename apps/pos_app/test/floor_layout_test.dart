import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/floor_layout.dart';

import 'floor_test.dart' show floorJson;

/// Where the floor map puts its tables, and how large (lib/floor_layout.dart): every table stays where the
/// plan has it and grows into the aisle around it, tables of one kind by the same amount; on a small
/// screen no table is drawn smaller than reads and takes a tap, and the tables in its way give a little.

/// A phone's map, a tablet's on its side, and a Mac's: the room left under the bar of rooms.
const phone = Size(390, 640), tablet = Size(1180, 690), mac = Size(1440, 760);

List<TableSpot> tablesOf(FloorPlan plan, [String? room]) => [
  for (final table in plan.tables)
    if (room == null || table.room == room) table,
];

FloorLayout layoutOf(FloorPlan plan, Size view, [String? room]) =>
    FloorLayout.of(FloorGrowth.of(tablesOf(plan, room)), view);

/// Whether two tables as the map draws them run into each other. Exact for two upright tables, two round
/// ones and two turned on their corners; for any other pair, whether the upright frames that hold them do,
/// which is the stricter question.
bool touch(TablePlace a, TablePlace b, [double slack = 0.5]) {
  final by = b.center - a.center;
  if (a.table.round && b.table.round) return by.distance < a.side / 2 + b.side / 2 - slack;
  if (a.diamond && b.diamond) return by.dx.abs() + by.dy.abs() < a.above + b.above - slack;
  if (a.table.round || b.table.round || a.turned || b.turned) {
    // a round table against a square one, or one turned: the corners of the frames do not count
    final (round, other) = a.table.round ? (a, b) : (b, a);
    if (round.table.round && !other.turned) {
      final box = other.bounds;
      final nearest = Offset(round.center.dx.clamp(box.left, box.right), round.center.dy.clamp(box.top, box.bottom));
      return (nearest - round.center).distance < round.side / 2 - slack;
    }
    return false; // (a turned table beside another shape: left to the pictures)
  }
  return a.bounds.deflate(slack).overlaps(b.bounds.deflate(slack));
}

double middle(Iterable<double> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

void main() {
  final plan = FloorPlan.fromJson(floorJson());

  group('growing', () {
    test('tables of one kind grow by the same amount, and none shrinks', () {
      final growth = FloorGrowth.of(plan.tables);
      final byKind = <String, Set<String>>{};
      for (final table in plan.tables) {
        expect(growth.of(table.id), inInclusiveRange(1.0, 3.0), reason: table.id);
        final kind = '${table.w}x${table.h} ${table.round} ${table.rotation % 180}';
        byKind.putIfAbsent(kind, () => {}).add(growth.of(table.id).toStringAsFixed(3));
      }
      for (final MapEntry(key: kind, value: factors) in byKind.entries) {
        expect(factors, hasLength(1), reason: 'tables of $kind');
      }
      // the dining rooms have aisles to grow into
      expect(growth.of('A7'), greaterThan(1.4));
      expect(growth.of('B5'), greaterThan(1.4));
    });

    test('no two grown tables run into each other, on any screen', () {
      for (final view in [phone, tablet, mac, const Size(820, 1050), const Size(320, 400)]) {
        for (final room in [null, 'D', 'AB', 'JK']) {
          final places = layoutOf(plan, view, room).places.toList();
          for (var i = 0; i < places.length; i++) {
            for (var j = i + 1; j < places.length; j++) {
              expect(
                touch(places[i], places[j]),
                isFalse,
                reason: '${places[i].table.id} and ${places[j].table.id} on $view, room $room',
              );
            }
          }
        }
      }
    });
  });

  group('on the screen', () {
    test('the whole floor on a phone: far larger tables than the plan drawn to fit, all of them on the screen', () {
      final layout = layoutOf(plan, phone);
      final fitted = math.min(phone.width / plan.width, phone.height / plan.height);
      final before = middle(plan.tables.map((table) => math.min(table.w, table.h) * fitted));
      final after = middle(layout.places.map((place) => place.side));
      expect(after, greaterThan(before * 1.6));
      expect(layout.smallest, greaterThanOrEqualTo(26));
      for (final place in layout.places) {
        expect(place.side, greaterThanOrEqualTo(layout.smallest - 0.01), reason: place.table.id);
        final bounds = place.bounds;
        expect(bounds.left >= 0 && bounds.top >= 0, isTrue, reason: place.table.id);
        expect(bounds.right <= phone.width && bounds.bottom <= phone.height, isTrue, reason: place.table.id);
      }
    });

    test('a table stays where the plan has it wherever there is the room', () {
      for (final (view, room) in [(tablet, 'D'), (tablet, 'AB'), (mac, 'JK'), (phone, 'D')]) {
        final layout = layoutOf(plan, view, room);
        for (final place in layout.places) {
          final home = layout.origin + Offset(place.table.x, place.table.y) * layout.scale;
          expect((place.center - home).distance, lessThan(0.01), reason: '${place.table.id} on $view');
        }
      }
    });

    test('tables that are made larger than their place allows keep their order: the bar is still a row', () {
      for (final view in [phone, const Size(375, 470), tablet]) {
        final layout = layoutOf(plan, view);
        final seats = [
          for (final id in ['K1', 'K2', 'K3', 'K4', 'K5']) layout[id]!,
        ];
        for (var i = 1; i < seats.length; i++) {
          expect(seats[i].center.dx, greaterThan(seats[i - 1].center.dx), reason: '${seats[i].table.id} on $view');
          expect((seats[i].center.dy - seats.first.center.dy).abs(), lessThan(seats.first.side / 2), reason: '$view');
        }
        // and every room is still where it was: the bar under the dining rooms, C & D left of main dining
        expect(layout['K1']!.center.dy, greaterThan(layout['A1']!.center.dy));
        expect(layout['D5']!.center.dx, lessThan(layout['B5']!.center.dx));
      }
    });

    test('a room by itself on a phone has tables a thumb can find; on a Mac none is drawn huge', () {
      for (final room in ['D', 'AB']) {
        expect(layoutOf(plan, phone, room).smallest, 44, reason: room);
      }
      expect(layoutOf(plan, phone, 'JK').smallest, greaterThanOrEqualTo(38));
      for (final room in ['D', 'AB', 'JK']) {
        final layout = layoutOf(plan, const Size(2560, 1300), room);
        expect(middle(layout.places.map((place) => place.side)), lessThanOrEqualTo(132.5), reason: room);
      }
    });

    test('the map ends above what the screen keeps clear at its edges', () {
      final layout = FloorLayout.of(FloorGrowth.of(tablesOf(plan, 'D')), phone, bottom: 90);
      for (final place in layout.places) {
        expect(place.bounds.bottom, lessThanOrEqualTo(phone.height - 90 + 0.01), reason: place.table.id);
      }
    });

    test('a table that is not laid out can still be told where it would stand', () {
      final layout = layoutOf(plan, tablet, 'AB');
      expect(layout['K1'], isNull);
      final elsewhere = layout.project(plan.tables.firstWhere((table) => table.id == 'K1'));
      expect(elsewhere.center.dy, greaterThan(layout['A1']!.center.dy));
    });

    test('nothing to lay out, or nowhere to: no tables and no error', () {
      expect(FloorLayout.of(FloorGrowth.of(const []), tablet).places, isEmpty);
      expect(layoutOf(plan, Size.zero).places, isEmpty);
    });
  });

  group('the rooms', () {
    test('each room has a frame round its own tables, and no two frames share ground', () {
      for (final view in [phone, tablet, mac]) {
        final layout = layoutOf(plan, view);
        final frames = layout.rooms();
        expect(frames.keys.toSet(), {'D', 'AB', 'JK'});
        for (final a in frames.keys) {
          for (final b in frames.keys) {
            if (a.compareTo(b) >= 0) continue;
            final shared = frames[a]!.intersect(frames[b]!);
            expect(shared.width <= 0.01 || shared.height <= 0.01, isTrue, reason: '$a and $b on $view');
          }
        }
      }
      // with the room for it, a frame holds every table of its room whole
      final layout = layoutOf(plan, tablet);
      final frames = layout.rooms();
      for (final place in layout.places) {
        final frame = frames[place.table.room]!.inflate(0.5), bounds = place.bounds;
        expect(frame.contains(bounds.topLeft) && frame.contains(bounds.bottomRight), isTrue, reason: place.table.id);
      }
    });
  });

  group('the room across a table', () {
    TablePlace place(TableSpot table, double w, double h) => TablePlace(table: table, center: Offset.zero, w: w, h: h);
    final upright = plan.tables.firstWhere((table) => table.id == 'B5');
    final round = plan.tables.firstWhere((table) => table.round);
    final corner = plan.tables.firstWhere((table) => table.id == 'A7');

    test('an upright table is as wide all the way down', () {
      final table = place(upright, 60, 120);
      expect(table.roomAt(-50, -30), closeTo(60, 0.01));
      expect(table.roomAt(-10, 10, inset: 4), closeTo(52, 0.01));
      expect(table.roomAt(50, 70), 0); // the line would stand below the table
    });

    test('a round table is widest across its middle', () {
      final table = place(round, 100, 100);
      expect(table.roomAt(-5, 5), closeTo(2 * math.sqrt(50 * 50 - 5 * 5), 0.01));
      expect(table.roomAt(-40, -30), closeTo(2 * math.sqrt(50 * 50 - 40 * 40), 0.01));
      expect(table.roomAt(-40, -30), lessThan(table.roomAt(-5, 5)));
      expect(table.roomAt(-60, -45), 0);
    });

    test('so is a table turned on its corner, down to nothing at its points', () {
      final table = place(corner, 100, 100);
      expect(table.diamond && table.turned, isTrue);
      final half = 100 / math.sqrt2;
      expect(table.above, closeTo(half, 0.01));
      expect(table.roomAt(-5, 5), closeTo(2 * (half - 5), 0.05));
      expect(table.roomAt(20, 40), closeTo(2 * (half - 40), 0.05));
      expect(table.roomAt(half - 1, half + 10), 0);
    });
  });
}
