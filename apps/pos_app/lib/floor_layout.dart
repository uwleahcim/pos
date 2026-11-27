/// Where the tables of a floor plan stand on a screen, and how large each is drawn there.
///
/// A plan drawn to scale is mostly aisle: the tables are small and what is written on them smaller still.
/// So the map keeps every table where the plan has it and lets each one grow into the room around it
/// ([FloorGrowth]): tables of a kind grow together, so a row of them stays a row of equals, until one of
/// them would come too near a neighbour. The grown plan is then fitted to the screen ([FloorLayout]), and a
/// table that would still be too small to read or to tap is drawn at a size that can be, with its
/// neighbours moved over just enough to make the room (seats along a bar, on a phone).
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'floor.dart';

/// How far each table of a plan can grow where it stands, by how many times its drawn size. It depends on
/// the plan alone, not on the screen, so it is worked out once for the tables shown.
class FloorGrowth {
  FloorGrowth._(this.tables, this._factors, this.reach, this.middling);

  /// The growth of [tables]: the tables of one room, or of the whole floor.
  factory FloorGrowth.of(List<TableSpot> tables) {
    if (tables.isEmpty) return FloorGrowth._(tables, const {}, Rect.zero, 1);
    final sides = [for (final table in tables) math.min(table.w, table.h)]..sort();
    final gap = _aisle * sides[sides.length ~/ 2];
    // Tables of one kind (the same size, shape and turn) grow as one.
    final kinds = <String, List<int>>{};
    for (var i = 0; i < tables.length; i++) {
      kinds.putIfAbsent(_kind(tables[i]), () => []).add(i);
    }
    final kindOf = [for (final table in tables) _kind(table)];
    final grown = {for (final kind in kinds.keys) kind: 1.0};
    final done = <String>{};
    final shapes = [for (final table in tables) _Shape(table)];
    for (var next = 1 + _step; next <= _most + 1e-9 && done.length < kinds.length; next += _step) {
      double at(int i) => done.contains(kindOf[i]) ? grown[kindOf[i]]! : next;
      final stopped = <String>{};
      for (var i = 0; i < tables.length; i++) {
        for (var j = i + 1; j < tables.length; j++) {
          final a = kindOf[i], b = kindOf[j];
          if (done.contains(a) && done.contains(b)) continue;
          // Between two rooms there is a wall: their tables keep further apart.
          final between = tables[i].room == tables[j].room ? gap : gap * _wall;
          if (shapes[i].hits(at(i), shapes[j], at(j), between)) {
            if (!done.contains(a)) stopped.add(a);
            if (!done.contains(b)) stopped.add(b);
          }
        }
      }
      for (final kind in kinds.keys) {
        if (done.contains(kind)) continue;
        if (stopped.contains(kind)) {
          done.add(kind);
        } else {
          grown[kind] = next;
        }
      }
    }
    // A table with nothing near it does not grow out of all proportion to the rest.
    final all = [for (final kind in kindOf) grown[kind]!]..sort();
    final most = all[all.length ~/ 2] * _apart;
    final factors = {for (var i = 0; i < tables.length; i++) tables[i].id: math.min(grown[kindOf[i]]!, most)};
    Rect? reach;
    for (var i = 0; i < tables.length; i++) {
      final bounds = shapes[i].bounds(factors[tables[i].id]!);
      reach = reach?.expandToInclude(bounds) ?? bounds;
    }
    final grownSides = [for (final table in tables) math.min(table.w, table.h) * factors[table.id]!]..sort();
    return FloorGrowth._(tables, factors, reach!, grownSides[grownSides.length ~/ 2]);
  }

  /// The most a table grows, the step it grows by, how many times the middling table's growth a table with
  /// room to spare may reach, the aisle kept between two tables as a part of the middling table's side, and
  /// how many aisles are kept between the tables of two rooms.
  static const _most = 3.0, _step = 0.02, _apart = 1.3, _aisle = 0.13, _wall = 3.0;

  final List<TableSpot> tables;
  final Map<String, double> _factors;

  /// The frame that holds every grown table, in the plan's own units.
  final Rect reach;

  /// The shorter side of the middling grown table, in the plan's own units.
  final double middling;

  /// How many times its drawn size the table is shown at.
  double of(String tableId) => _factors[tableId] ?? 1;

  static String _kind(TableSpot table) =>
      '${table.w}x${table.h}:${table.round ? 'o' : 'r'}:${(table.rotation % 180).toStringAsFixed(1)}';
}

/// A table's outline on the plan: a circle, or a rectangle turned about its middle.
class _Shape {
  _Shape(TableSpot table)
    : x = table.x,
      y = table.y,
      hw = table.w / 2,
      hh = table.h / 2,
      round = table.round,
      cos = math.cos(table.rotation * math.pi / 180),
      sin = math.sin(table.rotation * math.pi / 180);

  final double x, y, hw, hh, cos, sin;
  final bool round;

  double get radius => math.min(hw, hh);

  /// The upright frame that holds the shape at [factor] times its size.
  Rect bounds(double factor) {
    if (round) return Rect.fromCircle(center: Offset(x, y), radius: radius * factor);
    final w = (hw * cos.abs() + hh * sin.abs()) * factor, h = (hw * sin.abs() + hh * cos.abs()) * factor;
    return Rect.fromLTRB(x - w, y - h, x + w, y + h);
  }

  /// The corners at [factor] times its size, each pushed out by [by].
  List<Offset> _corners(double factor, double by) {
    final w = hw * factor + by, h = hh * factor + by;
    return [
      for (final (dx, dy) in [(-w, -h), (w, -h), (w, h), (-w, h)])
        Offset(x + dx * cos - dy * sin, y + dx * sin + dy * cos),
    ];
  }

  /// Whether this shape at [factor] and [other] at [otherFactor] come nearer than [gap].
  bool hits(double factor, _Shape other, double otherFactor, double gap) {
    if (round && other.round) {
      final reach = radius * factor + other.radius * otherFactor + gap;
      final dx = x - other.x, dy = y - other.y;
      return dx * dx + dy * dy < reach * reach;
    }
    if (round) return other._hitsCircle(otherFactor, x, y, radius * factor + gap);
    if (other.round) return _hitsCircle(factor, other.x, other.y, other.radius * otherFactor + gap);
    final mine = _corners(factor, gap / 2), theirs = other._corners(otherFactor, gap / 2);
    // Two shapes with no line between them overlap (the separating axis test).
    for (final corners in [mine, theirs]) {
      for (var i = 0; i < 4; i++) {
        final edge = corners[(i + 1) % 4] - corners[i];
        final nx = edge.dy, ny = -edge.dx;
        var aMin = double.infinity, aMax = -double.infinity, bMin = double.infinity, bMax = -double.infinity;
        for (final p in mine) {
          final d = p.dx * nx + p.dy * ny;
          aMin = math.min(aMin, d);
          aMax = math.max(aMax, d);
        }
        for (final p in theirs) {
          final d = p.dx * nx + p.dy * ny;
          bMin = math.min(bMin, d);
          bMax = math.max(bMax, d);
        }
        if (aMax < bMin || bMax < aMin) return false;
      }
    }
    return true;
  }

  /// Whether the rectangle at [factor] comes within [reach] of the point ([cx], [cy]).
  bool _hitsCircle(double factor, double cx, double cy, double reach) {
    // The point as the rectangle sees it, unturned.
    final dx = cx - x, dy = cy - y;
    final lx = dx * cos + dy * sin, ly = -dx * sin + dy * cos;
    final w = hw * factor, h = hh * factor;
    final ox = lx.abs() - w, oy = ly.abs() - h;
    final out = math.sqrt(math.pow(math.max(ox, 0), 2) + math.pow(math.max(oy, 0), 2));
    return out < reach;
  }
}

/// A table on the screen: where its middle is and how large it is drawn, before it is turned.
class TablePlace {
  const TablePlace({required this.table, required this.center, required this.w, required this.h});

  final TableSpot table;
  final Offset center;
  final double w, h;

  /// The shorter side: what the size of its words goes by.
  double get side => math.min(w, h);

  /// How far it is turned, in radians.
  double get turn => table.rotation * math.pi / 180;

  /// The frame it is drawn in, before it is turned.
  Rect get box => Rect.fromCenter(center: center, width: w, height: h);

  /// How round its corners are: a booth's more than a table's.
  double get corner => table.round ? side / 2 : (side * (table.kind == 'booth' ? 0.24 : 0.16)).clamp(5.0, 22.0);

  /// Half the width and half the height of the upright frame that holds it as it stands, turned.
  (double, double) get reach {
    if (table.round) return (side / 2, side / 2);
    final c = math.cos(turn).abs(), s = math.sin(turn).abs();
    return ((w * c + h * s) / 2, (w * s + h * c) / 2);
  }

  /// The upright frame that holds it as it stands, turned.
  Rect get bounds {
    final (rx, ry) = reach;
    return Rect.fromLTRB(center.dx - rx, center.dy - ry, center.dx + rx, center.dy + ry);
  }

  /// How far its edge is from its middle straight up the screen, and straight down: where the badges on
  /// its edge stand.
  double get above {
    if (table.round) return side / 2;
    final c = math.cos(turn).abs(), s = math.sin(turn).abs();
    return math.min(s < 1e-6 ? double.infinity : w / 2 / s, c < 1e-6 ? double.infinity : h / 2 / c);
  }

  /// Where its edge is, from its middle, towards [way] (which way only: how long [way] is does not count):
  /// where a mark on its edge stands. Towards a corner of the frame that holds it, that is the corner of an
  /// upright table and the middle of a side of one turned on its corner.
  Offset edgeToward(Offset way) {
    final to = way / way.distance;
    if (table.round) return to * (side / 2);
    final c = math.cos(turn), s = math.sin(turn);
    // the same way as the table has it, unturned
    final across = (to.dx * c + to.dy * s).abs(), down = (to.dy * c - to.dx * s).abs();
    return to *
        math.min(across < 1e-9 ? double.infinity : w / 2 / across, down < 1e-9 ? double.infinity : h / 2 / down);
  }

  /// Turned so that a corner, not an edge, is uppermost.
  bool get turned => !table.round && (table.rotation % 90).abs() > 0.5;

  /// Square and turned on its corner: a diamond, which two of in a row touch only at their points.
  bool get diamond => !table.round && (w - h).abs() < 0.5 && ((table.rotation % 90) - 45).abs() < 1;

  /// How wide a line of words centred on the table can be when it stands between [top] and [bottom] (both
  /// measured down from the table's middle) and keeps [inset] from the edge: all of an upright table's
  /// width, and less towards the top and bottom of a round one or one turned on its corner. Nothing when
  /// the line would not be inside the table at all.
  double roomAt(double top, double bottom, {double inset = 0}) => math.min(_half(top, inset), _half(bottom, inset)) * 2;

  double _half(double y, double inset) {
    if (table.round) {
      final r = side / 2 - inset;
      return r <= y.abs() ? 0 : math.sqrt(r * r - y * y);
    }
    final hw = w / 2 - inset, hh = h / 2 - inset;
    if (hw <= 0 || hh <= 0) return 0;
    final c = math.cos(turn), s = math.sin(turn);
    final corners = [
      for (final (dx, dy) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]) Offset(dx * c - dy * s, dx * s + dy * c),
    ];
    // Where the level line at y crosses the table's edge: a line of words centred on the table reaches as
    // far as the nearer crossing.
    var left = double.infinity, right = -double.infinity;
    for (var i = 0; i < 4; i++) {
      final p = corners[i], q = corners[(i + 1) % 4];
      if ((p.dy - y) * (q.dy - y) > 0) continue;
      if ((p.dy - q.dy).abs() < 1e-9) {
        left = math.min(left, math.min(p.dx, q.dx));
        right = math.max(right, math.max(p.dx, q.dx));
      } else {
        final x = p.dx + (y - p.dy) * (q.dx - p.dx) / (q.dy - p.dy);
        left = math.min(left, x);
        right = math.max(right, x);
      }
    }
    if (left > right) return 0;
    return math.max(0, math.min(right, -left));
  }
}

/// The tables of a plan on a screen of a given size.
class FloorLayout {
  FloorLayout._(this.view, this.scale, this.origin, this._places, this._growth, this.smallest);

  /// [growth]'s tables in [view], keeping [left], [top], [right] and [bottom] clear at its edges.
  factory FloorLayout.of(
    FloorGrowth growth,
    Size view, {
    double left = 12,
    double top = 16,
    double right = 12,
    double bottom = 12,
  }) {
    final tables = growth.tables;
    if (tables.isEmpty || view.isEmpty) return FloorLayout._(view, 1, Offset.zero, const {}, growth, 0);
    final reach = growth.reach;
    final wide = math.max(view.width - left - right, 1.0), high = math.max(view.height - top - bottom, 1.0);
    var scale = math.min(wide / reach.width, high / reach.height);
    // On a large screen showing a few tables, they are not drawn larger than their words can use.
    scale = math.min(scale, _largest / growth.middling);
    // Centred from side to side; nearer the top than the bottom, where the screen's own buttons float.
    final origin = Offset(
      left + (wide - reach.width * scale) / 2 - reach.left * scale,
      top + (high - reach.height * scale) * _above - reach.top * scale,
    );
    List<_Spot> spots(double least) => [
      for (final table in tables)
        _Spot.of(
          table,
          Offset(origin.dx + table.x * scale, origin.dy + table.y * scale),
          growth.of(table.id) * scale,
          least,
        ),
    ];
    // The largest size the smallest tables can be given without moving any table far from its place. A
    // room shown by itself has no other room to keep clear of, so its tables may move further; so may
    // any, sooner than be drawn too small to read or to tap.
    final oneRoom = tables.every((table) => table.room == tables.first.room);
    List<_Spot>? placed;
    var smallest = _wanted.last;
    for (final least in _wanted) {
      final trial = spots(least);
      if (trial.every((spot) => !spot.raised)) {
        placed = trial;
        smallest = least;
        break;
      }
      final (moved, clear) = _spread(trial, view, left, top, right, bottom);
      final stray = oneRoom || least <= _needed ? _strayAtNeed : _stray;
      if ((clear && moved <= least * stray) || least == _wanted.last) {
        placed = trial;
        smallest = least;
        break;
      }
    }
    return FloorLayout._(
      view,
      scale,
      origin,
      {for (final spot in placed!) spot.table.id: spot.place},
      growth,
      smallest,
    );
  }

  /// The sizes tried for the smallest tables (their shorter side, in points), the largest first; the last
  /// is given whatever it moves.
  static const _wanted = [44.0, 38.0, 32.0, 26.0, 22.0];

  /// How far a table may be moved from its place to make room, in times the smallest table's side: on a
  /// floor of several rooms, and where there is the need ([_needed], or a room by itself).
  static const _stray = 1.25, _strayAtNeed = 1.9;

  /// The smallest table that still reads at a glance and takes a tap well, in points.
  static const _needed = 26.0;

  /// The space kept between two tables that were moved apart.
  static const _between = 3.0;

  /// The shorter side of the middling table is drawn no larger than this.
  static const _largest = 132.0;

  /// How much of the height the tables do not need is left above them.
  static const _above = 0.3;

  final Size view;

  /// Screen points to a unit of the plan, and where the plan's own corner falls on the screen.
  final double scale;
  final Offset origin;
  final Map<String, TablePlace> _places;
  final FloorGrowth _growth;

  /// What the layout was worked out from.
  FloorGrowth get growth => _growth;

  /// The shorter side no table is drawn smaller than, in points.
  final double smallest;

  Iterable<TablePlace> get places => _places.values;

  TablePlace? operator [](String tableId) => _places[tableId];

  /// Where a table that is not among this layout's would stand, at this layout's scale: off the screen as
  /// often as not. It is where a table comes from, or goes to, when the tables shown change.
  TablePlace project(TableSpot table) {
    final by = _growth.of(table.id) * scale;
    final side = math.min(table.w, table.h) * by;
    return TablePlace(
      table: table,
      center: Offset(origin.dx + table.x * scale, origin.dy + table.y * scale),
      w: table.round ? side : table.w * by,
      h: table.round ? side : table.h * by,
    );
  }

  /// The frame of each room with a table shown: round its tables, with room at the top for its name. Two
  /// rooms side by side share the wall between them.
  Map<String, Rect> rooms({double around = 8, double above = 14}) {
    final tight = <String, Rect>{};
    for (final place in places) {
      final bounds = place.bounds;
      tight[place.table.room] = tight[place.table.room]?.expandToInclude(bounds) ?? bounds;
    }
    final ids = tight.keys.toList();
    final frames = {
      for (final MapEntry(key: id, value: f) in tight.entries)
        id: Rect.fromLTRB(
          math.max(f.left - around, 1),
          math.max(f.top - above, 1),
          math.min(f.right + around, view.width - 1),
          math.min(f.bottom + around, view.height - 1),
        ),
    };
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final a = frames[ids[i]]!, b = frames[ids[j]]!;
        final over = a.intersect(b);
        if (over.width <= 0 || over.height <= 0) continue;
        // The wall goes halfway between the two rooms' tables where they stand apart, and through the
        // middle of what the frames share where they do not.
        final ta = tight[ids[i]]!, tb = tight[ids[j]]!;
        final beside = ta.right <= tb.left || tb.right <= ta.left;
        final under = ta.bottom <= tb.top || tb.bottom <= ta.top;
        if (beside || (!under && over.width <= over.height)) {
          final aLeft = a.center.dx <= b.center.dx;
          final wall = !beside ? over.center.dx : (aLeft ? (ta.right + tb.left) / 2 : (tb.right + ta.left) / 2);
          frames[ids[i]] = aLeft
              ? Rect.fromLTRB(a.left, a.top, wall, a.bottom)
              : Rect.fromLTRB(wall, a.top, a.right, a.bottom);
          frames[ids[j]] = aLeft
              ? Rect.fromLTRB(wall, b.top, b.right, b.bottom)
              : Rect.fromLTRB(b.left, b.top, wall, b.bottom);
        } else {
          final aTop = a.center.dy <= b.center.dy;
          // (the lower room's name stands above its tables, so the wall keeps to the upper room's side)
          final wall = !under
              ? over.center.dy
              : (aTop ? ta.bottom + (tb.top - ta.bottom) * 0.25 : tb.bottom + (ta.top - tb.bottom) * 0.25);
          frames[ids[i]] = aTop
              ? Rect.fromLTRB(a.left, a.top, a.right, wall)
              : Rect.fromLTRB(a.left, wall, a.right, a.bottom);
          frames[ids[j]] = aTop
              ? Rect.fromLTRB(b.left, wall, b.right, b.bottom)
              : Rect.fromLTRB(b.left, b.top, wall, b.bottom);
        }
      }
    }
    return frames;
  }

  /// Moves [spots] apart until none overlaps another, each no further than it must go and never past a
  /// neighbour it stood beside: a row stays a row, in its order. Says how far the one moved furthest went,
  /// and whether every overlap is gone.
  static (double, bool) _spread(List<_Spot> spots, Size view, double left, double top, double right, double bottom) {
    var clear = false;
    for (var round = 0; round < 80 && !clear; round++) {
      clear = true;
      for (var i = 0; i < spots.length; i++) {
        for (var j = i + 1; j < spots.length; j++) {
          if (_part(spots[i], spots[j])) clear = false;
        }
      }
      for (final spot in spots) {
        spot.x = spot.x.clamp(
          math.min(left + spot.rx, view.width / 2),
          math.max(view.width - right - spot.rx, view.width / 2),
        );
        spot.y = spot.y.clamp(
          math.min(top + spot.ry, view.height / 2),
          math.max(view.height - bottom - spot.ry, view.height / 2),
        );
      }
    }
    var moved = 0.0;
    for (final spot in spots) {
      moved = math.max(moved, (Offset(spot.x, spot.y) - spot.home).distance);
    }
    return (moved, clear);
  }

  /// Moves [a] and [b] apart if they overlap, each by half of what it takes; whether they did.
  static bool _part(_Spot a, _Spot b) {
    final needX = a.rx + b.rx + _between, needY = a.ry + b.ry + _between;
    final dx = b.x - a.x, dy = b.y - a.y;
    if (dx.abs() >= needX - 0.25 || dy.abs() >= needY - 0.25) return false;
    final round = a.round && b.round, diamonds = a.diamond && b.diamond;
    if (round && dx * dx + dy * dy >= (needX - 0.25) * (needX - 0.25)) return false;
    if (diamonds && dx.abs() + dy.abs() >= needX - 0.25) return false;
    // Apart along the line they are most apart on by the plan, and to the side each is on there.
    final homeX = b.home.dx - a.home.dx, homeY = b.home.dy - a.home.dy;
    if (needX - homeX.abs() <= needY - homeY.abs()) {
      final to = homeX == 0 ? 1.0 : homeX.sign;
      final want = round
          ? math.sqrt(math.max(needX * needX - dy * dy, 0))
          : diamonds
          ? needX - dy.abs()
          : needX;
      final push = (want - dx * to) / 2;
      a.x -= push * to;
      b.x += push * to;
    } else {
      final to = homeY == 0 ? 1.0 : homeY.sign;
      final want = round
          ? math.sqrt(math.max(needY * needY - dx * dx, 0))
          : diamonds
          ? needY - dx.abs()
          : needY;
      final push = (want - dy * to) / 2;
      a.y -= push * to;
      b.y += push * to;
    }
    return true;
  }
}

/// A table while the layout is worked out: where it stands now and where the plan has it.
class _Spot {
  _Spot(this.table, this.home, this.w, this.h, {required this.raised}) : x = home.dx, y = home.dy {
    final (rx, ry) = place.reach;
    this.rx = rx;
    this.ry = ry;
    diamond = place.diamond;
  }

  /// [table] at [home], [by] screen points to a unit of the plan, and no smaller than [least] on its
  /// shorter side.
  factory _Spot.of(TableSpot table, Offset home, double by, double least) {
    final side = math.min(table.w, table.h) * by;
    final up = side < least ? least / side : 1.0;
    return _Spot(
      table,
      home,
      (table.round ? side : table.w * by) * up,
      (table.round ? side : table.h * by) * up,
      raised: up > 1,
    );
  }

  final TableSpot table;
  final Offset home;
  final double w, h;

  /// It is drawn larger than the plan fitted to the screen would have it, to be large enough to read.
  final bool raised;
  double x, y;
  late final double rx, ry;
  late final bool diamond;

  bool get round => table.round;

  TablePlace get place => TablePlace(table: table, center: Offset(x, y), w: w, h: h);
}
