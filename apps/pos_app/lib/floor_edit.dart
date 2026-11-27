/// The floor plan while a manager draws it (the floor editor, lib/screens/floor_editor.dart): the rooms and
/// tables as they stand now, what is picked, and every change that can be made to them, each of which can
/// be undone. No widgets here: the screen draws this and tells it what the finger did.
///
/// Everything is in the plan's own units, the ones the hub stores (`x`, `y` are a table's middle). What is
/// saved is [FloorEditor.toJson]; the hub checks it again (`clean_floor_plan`) and works out the plan's
/// size and each room's frame from the tables.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import 'floor.dart';

/// A room of the plan being drawn. [key] names it for as long as the editor is open; [id] is the hub's name
/// for it, which a room added here does not have until it is saved.
@immutable
class EditRoom {
  const EditRoom({required this.key, this.id, required this.name});

  final String key;
  final String? id;
  final String name;

  EditRoom named(String name) => EditRoom(key: key, id: id, name: name);

  @override
  bool operator ==(Object other) => other is EditRoom && other.key == key && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(key, id, name);
}

/// A table of the plan being drawn. [key] names it for as long as the editor is open; [id] is the name
/// orders carry for it on the hub, which a table added here does not have until it is saved.
@immutable
class EditTable {
  const EditTable({
    required this.key,
    this.id,
    required this.label,
    required this.room,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.seats,
    this.round = false,
    this.rotation = 0,
    this.kind = 'table',
  });

  final String key;
  final String? id;

  /// What the map writes on it, and what orders carry once it is saved.
  final String label;

  /// The [EditRoom.key] of the room it stands in.
  final String room;

  /// Its middle, and its width and depth before it is turned.
  final double x, y, w, h;
  final int seats;
  final bool round;

  /// How far it is turned, in degrees, from -180 up to 180.
  final double rotation;

  /// table, booth or counter (a seat at the bar).
  final String kind;

  Offset get center => Offset(x, y);

  /// Half the width and half the height of the upright frame that holds it as it stands, turned.
  (double, double) get reach {
    if (round) return (w / 2, w / 2);
    final turn = rotation * math.pi / 180;
    final c = math.cos(turn).abs(), s = math.sin(turn).abs();
    return ((w * c + h * s) / 2, (w * s + h * c) / 2);
  }

  /// The upright frame that holds it as it stands, turned.
  Rect get bounds {
    final (across, down) = reach;
    return Rect.fromLTRB(x - across, y - down, x + across, y + down);
  }

  /// Its corners as it stands; a round table's edge as twelve points.
  List<Offset> get outline {
    if (round) {
      return [for (var i = 0; i < 12; i++) center + Offset.fromDirection(i * math.pi / 6, w / 2)];
    }
    final turn = rotation * math.pi / 180;
    final c = math.cos(turn), s = math.sin(turn);
    return [
      for (final (dx, dy) in [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)])
        Offset(x + dx * c - dy * s, y + dx * s + dy * c),
    ];
  }

  /// Whether [point] is on the table.
  bool holds(Offset point) {
    final from = point - center;
    if (round) return from.distance <= w / 2;
    final turn = -rotation * math.pi / 180;
    final c = math.cos(turn), s = math.sin(turn);
    return (from.dx * c - from.dy * s).abs() <= w / 2 && (from.dx * s + from.dy * c).abs() <= h / 2;
  }

  /// Whether this table and [other] stand on the same ground.
  bool overlaps(EditTable other) {
    if (!bounds.overlaps(other.bounds)) return false;
    if (round && other.round) return (center - other.center).distance < (w + other.w) / 2 - 0.01;
    final a = outline, b = other.outline;
    // Two shapes with no dent in them are apart exactly when a side of one has the other wholly beyond it.
    for (final shape in [a, b]) {
      for (var i = 0; i < shape.length; i++) {
        final side = shape[(i + 1) % shape.length] - shape[i];
        final across = Offset(-side.dy, side.dx);
        double along(Offset point) => point.dx * across.dx + point.dy * across.dy;
        final (aMin, aMax) = _span(a.map(along));
        final (bMin, bMax) = _span(b.map(along));
        if (aMax <= bMin + 0.01 || bMax <= aMin + 0.01) return false;
      }
    }
    return true;
  }

  static (double, double) _span(Iterable<double> values) =>
      values.fold((double.infinity, -double.infinity), (span, v) => (math.min(span.$1, v), math.max(span.$2, v)));

  EditTable copyWith({
    String? label,
    String? room,
    double? x,
    double? y,
    double? w,
    double? h,
    int? seats,
    bool? round,
    double? rotation,
    String? kind,
  }) {
    final isRound = round ?? this.round;
    final width = w ?? this.w, depth = h ?? this.h;
    return EditTable(
      key: key,
      id: id,
      label: label ?? this.label,
      room: room ?? this.room,
      x: x ?? this.x,
      y: y ?? this.y,
      // a round table is as deep as it is wide, and has no way it is turned
      w: isRound ? math.min(width, depth) : width,
      h: isRound ? math.min(width, depth) : depth,
      seats: seats ?? this.seats,
      round: isRound,
      rotation: isRound ? 0 : rotation ?? this.rotation,
      kind: kind ?? this.kind,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EditTable &&
      other.key == key &&
      other.id == id &&
      other.label == label &&
      other.room == room &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h &&
      other.seats == seats &&
      other.round == round &&
      other.rotation == rotation &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(key, id, label, room, x, y, w, h, seats, round, rotation, kind);
}

/// A table the editor puts down ready-made: the sizes the restaurant's own plan is drawn in.
@immutable
class TablePreset {
  const TablePreset(
    this.name,
    this.w,
    this.h,
    this.seats, {
    this.round = false,
    this.rotation = 0,
    this.kind = 'table',
  });

  final String name;
  final double w, h;
  final int seats;
  final bool round;
  final double rotation;
  final String kind;
}

const tablePresets = [
  TablePreset('Table for 2', 45, 45, 2),
  TablePreset('Table for 4', 55, 55, 4),
  TablePreset('Table for 4, on its corner', 55, 55, 4, rotation: 45),
  TablePreset('Long table for 6', 45, 100, 6),
  TablePreset('Round for 4', 60, 60, 4, round: true),
  TablePreset('Round for 8', 75, 75, 8, round: true),
  TablePreset('Booth for 4', 47, 72, 4, kind: 'booth'),
  TablePreset('Long booth for 8', 109, 53, 8, kind: 'booth'),
  TablePreset('Round booth for 6', 78, 78, 6, round: true, kind: 'booth'),
  TablePreset('Seat at the bar', 30, 30, 1, round: true, kind: 'counter'),
];

/// What a set of tables is lined up by.
enum LineUp { left, center, right, top, middle, bottom }

/// A line a table being moved has snapped to: across the plan at the height [at], or [upright] at the
/// distance [at] from its left, drawn from [from] to [to] along itself.
@immutable
class SnapGuide {
  const SnapGuide({required this.upright, required this.at, required this.from, required this.to});

  final bool upright;
  final double at, from, to;
}

/// The plan being drawn, with what is picked and what was done.
class FloorEditor extends ChangeNotifier {
  FloorEditor(FloorPlan plan, {this.busy = const {}, this.booked = const {}}) {
    _rooms = [for (final room in plan.rooms) EditRoom(key: room.id, id: room.id, name: room.name)];
    final known = {for (final room in _rooms) room.key};
    _tables = [
      for (final table in plan.tables)
        EditTable(
          key: table.id,
          id: table.id,
          label: table.label,
          // (a table of a room the plan does not list is put in the first one, so it can be seen and moved)
          room: known.contains(table.room) || _rooms.isEmpty ? table.room : _rooms.first.key,
          x: table.x,
          y: table.y,
          w: table.w,
          h: table.round ? table.w : table.h,
          seats: table.seats,
          round: table.round,
          rotation: table.round ? 0 : table.rotation,
          kind: table.kind,
        ),
    ];
    _roomsAtFirst = _rooms;
    _tablesAtFirst = _tables;
    _labelAtFirst = {for (final table in _tables) table.key: table.label};
  }

  /// The shortest and the longest a table's side may be, the most seats and letters of a name, as the hub
  /// has them (`backend/src/pos/floor/plan.py`).
  static const sideMin = 16.0, sideMax = 1200.0;
  static const seatsMax = 60, labelMax = 8, roomNameMax = 32, roomsMax = 24, tablesMax = 400;

  /// What a table's name is made of: it is the name orders carry.
  static final labelLetters = RegExp(r'^[A-Za-z0-9_-]+$');

  /// The lines of the grid a table's middle settles on when nothing nearer lines it up.
  static const grid = 5.0;

  /// The ids of the tables that cannot be renamed or taken off the plan just now: the ones with an open
  /// check, and the ones a reservation still to come holds.
  final Set<String> busy, booked;
  late List<EditRoom> _rooms, _roomsAtFirst;
  late List<EditTable> _tables, _tablesAtFirst;
  late final Map<String, String> _labelAtFirst;
  final _undo = <(List<EditRoom>, List<EditTable>)>[];
  final _redo = <(List<EditRoom>, List<EditTable>)>[];
  var _picked = <String>{};
  var _made = 0;

  // A finger is down: where the tables stood when it came down, which one undo goes back to.
  List<EditTable>? _held;
  List<SnapGuide> _guides = const [];

  List<EditRoom> get rooms => _rooms;
  List<EditTable> get tables => _tables;

  /// The keys of the tables that are picked.
  Set<String> get picked => _picked;

  /// The tables that are picked, in the plan's order.
  List<EditTable> get pickedTables => [
    for (final table in _tables)
      if (_picked.contains(table.key)) table,
  ];

  /// The one table that is picked; null with none or several.
  EditTable? get only => _picked.length == 1 ? table(_picked.single) : null;

  /// The lines the table being moved has snapped to, for as long as the finger is down.
  List<SnapGuide> get guides => _guides;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Whether anything is different from the plan that was opened.
  bool get changed => !listEquals(_rooms, _roomsAtFirst) || !listEquals(_tables, _tablesAtFirst);

  EditTable? table(String key) {
    for (final table in _tables) {
      if (table.key == key) return table;
    }
    return null;
  }

  EditRoom? room(String key) {
    for (final room in _rooms) {
      if (room.key == key) return room;
    }
    return null;
  }

  /// The table drawn on top at [point]; null on empty floor.
  EditTable? tableAt(Offset point, {double within = 0}) {
    for (final table in _tables.reversed) {
      if (table.holds(point)) return table;
    }
    if (within > 0) {
      // a finger is wider than a small table: the nearest table within reach will do
      EditTable? nearest;
      var best = within;
      for (final table in _tables) {
        final (across, down) = table.reach;
        final far = math.max(0.0, math.max((point.dx - table.x).abs() - across, (point.dy - table.y).abs() - down));
        if (far < best) (nearest, best) = (table, far);
      }
      return nearest;
    }
    return null;
  }

  /// Why a table cannot be renamed or taken off the plan just now; null when it can. The hub refuses a plan
  /// that takes a table in use off the floor, and a new name is a new table to it.
  String? inUse(EditTable table) {
    final id = table.id;
    if (id == null) return null;
    if (busy.contains(id)) return '${_labelAtFirst[table.key] ?? id} has an open check';
    if (booked.contains(id)) return '${_labelAtFirst[table.key] ?? id} is held by a reservation';
    return null;
  }

  /// The frame round the tables of [room], as the map will draw it; null for a room with none.
  Rect? frameOf(String room, {double around = 20}) {
    Rect? frame;
    for (final table in _tables) {
      if (table.room == room) frame = frame?.expandToInclude(table.bounds) ?? table.bounds;
    }
    return frame?.inflate(around);
  }

  /// The room whose tables stand round [point], or nearest to it; null in a plan with no table.
  String? roomAt(Offset point) {
    String? nearest;
    var least = double.infinity;
    for (final room in _rooms) {
      final frame = frameOf(room.key);
      if (frame == null) continue;
      final away = Offset(
        math.max(0, math.max(frame.left - point.dx, point.dx - frame.right)).toDouble(),
        math.max(0, math.max(frame.top - point.dy, point.dy - frame.bottom)).toDouble(),
      ).distance;
      if (away < least) (nearest, least) = (room.key, away);
    }
    return nearest;
  }

  /// The frame round every table; null for a plan with none.
  Rect? get frame {
    Rect? frame;
    for (final table in _tables) {
      frame = frame?.expandToInclude(table.bounds) ?? table.bounds;
    }
    return frame;
  }

  // ---- what is picked

  /// Picks [key] alone, or with [more] adds it to what is picked (and takes it out if it was).
  void pick(String key, {bool more = false}) {
    if (more) {
      _picked = {..._picked};
      if (!_picked.remove(key)) _picked.add(key);
    } else {
      _picked = {key};
    }
    notifyListeners();
  }

  void pickRoom(String room) {
    _picked = {
      for (final table in _tables)
        if (table.room == room) table.key,
    };
    notifyListeners();
  }

  void pickAll() {
    _picked = {for (final table in _tables) table.key};
    notifyListeners();
  }

  void pickNone() {
    if (_picked.isEmpty) return;
    _picked = {};
    notifyListeners();
  }

  // ---- undo

  void _keep() {
    _undo.add((_rooms, _tables));
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  /// Makes a change that one undo takes back. Nothing is kept for a change that changed nothing.
  void _change({List<EditRoom>? rooms, List<EditTable>? tables}) {
    final nextRooms = rooms ?? _rooms, nextTables = tables ?? _tables;
    if (listEquals(nextRooms, _rooms) && listEquals(nextTables, _tables)) return;
    if (_held == null) _keep();
    _rooms = nextRooms;
    _tables = nextTables;
    notifyListeners();
  }

  void _each(EditTable Function(EditTable) change, {Set<String>? of}) {
    final keys = of ?? _picked;
    _change(
      tables: [
        for (final table in _tables)
          if (keys.contains(table.key)) change(table) else table,
      ],
    );
  }

  void undo() => _step(_undo, _redo);
  void redo() => _step(_redo, _undo);

  void _step(List<(List<EditRoom>, List<EditTable>)> from, List<(List<EditRoom>, List<EditTable>)> to) {
    if (from.isEmpty || _held != null) return;
    to.add((_rooms, _tables));
    final (rooms, tables) = from.removeLast();
    _rooms = rooms;
    _tables = tables;
    final still = {for (final table in _tables) table.key};
    _picked = _picked.intersection(still);
    notifyListeners();
  }

  // ---- with a finger down: moving, sizing and turning are one change however long the finger drags

  /// A finger came down on what is picked, or on a handle.
  void hold() {
    if (_held != null) return;
    _keep();
    _held = _tables;
  }

  /// The finger is up. A drag that ended where it began was no change.
  void release() {
    final held = _held;
    if (held == null) return;
    _held = null;
    _guides = const [];
    if (listEquals(held, _tables) && _undo.isNotEmpty) _undo.removeLast();
    notifyListeners();
  }

  /// While held: the picked tables are [by] from where they stood when the finger came down. A table that
  /// comes [within] reach of lining up with another (its middle or an edge) settles on that line, which
  /// [guides] then shows; otherwise its middle settles on the grid. Only the tables no further than [near]
  /// along the line count: a table lines up with its neighbours.
  void moveBy(Offset by, {double within = 0, double near = 320}) {
    final held = _held;
    if (held == null || _picked.isEmpty) return;
    final moving = [
      for (final table in held)
        if (_picked.contains(table.key)) table,
    ];
    if (moving.isEmpty) return;
    var to = by;
    final guides = <SnapGuide>[];
    if (within > 0) {
      final frame = moving.map((table) => table.bounds).reduce((a, b) => a.expandToInclude(b)).shift(by);
      final others = [
        for (final table in held)
          if (!_picked.contains(table.key)) table.bounds,
      ];
      // the nearest line of another table for each way, upright lines first
      for (final upright in [true, false]) {
        var best = within;
        double? shift, at;
        Rect? beside;
        final mine = upright ? [frame.left, frame.center.dx, frame.right] : [frame.top, frame.center.dy, frame.bottom];
        for (final other in others) {
          // a table lines up with the tables around it, not with one at the other end of the building
          final apart = upright
              ? math.max(other.top - frame.bottom, frame.top - other.bottom)
              : math.max(other.left - frame.right, frame.left - other.right);
          if (apart > near) continue;
          final theirs = upright
              ? [other.left, other.center.dx, other.right]
              : [other.top, other.center.dy, other.bottom];
          for (final a in mine) {
            for (final b in theirs) {
              if ((b - a).abs() < best) (best, shift, at, beside) = ((b - a).abs(), b - a, b, other);
            }
          }
        }
        if (shift != null && at != null && beside != null) {
          to += upright ? Offset(shift, 0) : Offset(0, shift);
          final moved = frame.shift(upright ? Offset(shift, 0) : Offset(0, shift));
          guides.add(
            SnapGuide(
              upright: upright,
              at: at,
              from: upright ? math.min(moved.top, beside.top) : math.min(moved.left, beside.left),
              to: upright ? math.max(moved.bottom, beside.bottom) : math.max(moved.right, beside.right),
            ),
          );
        } else {
          // no table to line up with: the middle of the first table moved settles on the grid
          final first = moving.first;
          final middle = upright ? first.x + by.dx : first.y + by.dy;
          final settle = (middle / grid).round() * grid - middle;
          to += upright ? Offset(settle, 0) : Offset(0, settle);
        }
      }
    }
    _guides = guides;
    _tables = [
      for (final table in held)
        if (_picked.contains(table.key))
          table.copyWith(x: _tidy(table.x + to.dx), y: _tidy(table.y + to.dy))
        else
          table,
    ];
    notifyListeners();
  }

  /// While held: the table [key] is [w] wide and [h] deep, about its middle.
  void sizeTo(String key, double w, double h) {
    if (_held == null) return;
    _tables = [
      for (final table in _tables)
        if (table.key == key) _sized(table, w, h) else table,
    ];
    notifyListeners();
  }

  /// While held: the table [key] is turned to [degrees], settling on every fifteenth degree it comes
  /// [within] reach of.
  void turnTo(String key, double degrees, {double within = 4}) {
    if (_held == null) return;
    final settled = (degrees / 15).round() * 15.0;
    final to = (settled - degrees).abs() <= within ? settled : degrees.roundToDouble();
    _tables = [
      for (final table in _tables)
        if (table.key == key) table.copyWith(rotation: _turn(to)) else table,
    ];
    notifyListeners();
  }

  static double _tidy(double value) => (value * 100).round() / 100;
  static double _turn(double degrees) => ((degrees + 180) % 360) - 180;

  static EditTable _sized(EditTable table, double w, double h) {
    final width = w.clamp(sideMin, sideMax).roundToDouble(), depth = h.clamp(sideMin, sideMax).roundToDouble();
    return table.round
        ? table.copyWith(w: math.max(width, depth), h: math.max(width, depth))
        : table.copyWith(w: width, h: depth);
  }

  // ---- changes to what is picked

  /// Moves what is picked by [by], as an arrow key does.
  void nudge(Offset by) => _each((table) => table.copyWith(x: _tidy(table.x + by.dx), y: _tidy(table.y + by.dy)));

  /// The picked tables are [w] wide and [h] deep (either left as it is when null).
  void size({double? w, double? h}) => _each((table) => _sized(table, w ?? table.w, h ?? table.h));

  void turnBy(double degrees) => _each((table) => table.copyWith(rotation: _turn(table.rotation + degrees)));
  void turn(double degrees) => _each((table) => table.copyWith(rotation: _turn(degrees)));
  void seats(int seats) => _each((table) => table.copyWith(seats: seats.clamp(1, seatsMax)));
  void shape({required bool round}) => _each((table) => table.copyWith(round: round));
  void kind(String kind) => _each((table) => table.copyWith(kind: kind));
  void toRoom(String room) => _each((table) => table.copyWith(room: room));

  /// Names the table [key]. A table in use keeps its name ([inUse]). A name typed letter by letter is one
  /// change: the letters after the first are taken back with it.
  void rename(String key, String label) {
    final it = table(key);
    if (it == null || inUse(it) != null) return;
    final typing = _typing == (key, _undo.length);
    final before = _undo.length;
    if (typing) _held = _tables; // (as with a finger down: nothing more is kept to undo)
    _each((table) => table.copyWith(label: label.trim()), of: {key});
    if (typing) _held = null;
    if (typing || _undo.length > before) _typing = (key, _undo.length);
  }

  /// The table whose name was changed last, and how many changes there were to undo then.
  (String, int)? _typing;

  /// Makes every picked table the size of the first one picked.
  void sameSize() {
    final first = pickedTables.firstOrNull;
    if (first == null) return;
    _each((table) => table.round == first.round ? _sized(table, first.w, first.h) : table);
  }

  /// Lines the picked tables up by an edge or by their middles.
  void lineUp(LineUp by) {
    final all = pickedTables;
    if (all.length < 2) return;
    final frame = all.map((table) => table.bounds).reduce((a, b) => a.expandToInclude(b));
    _each((table) {
      final (across, down) = table.reach;
      return switch (by) {
        LineUp.left => table.copyWith(x: _tidy(frame.left + across)),
        LineUp.center => table.copyWith(x: _tidy(frame.center.dx)),
        LineUp.right => table.copyWith(x: _tidy(frame.right - across)),
        LineUp.top => table.copyWith(y: _tidy(frame.top + down)),
        LineUp.middle => table.copyWith(y: _tidy(frame.center.dy)),
        LineUp.bottom => table.copyWith(y: _tidy(frame.bottom - down)),
      };
    });
  }

  /// Spaces three or more picked tables evenly between the first and the last, [across] the plan or down
  /// it: the gaps between them are made the same.
  void spread({required bool across}) {
    final all = pickedTables..sort((a, b) => across ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    if (all.length < 3) return;
    double half(EditTable table) => across ? table.reach.$1 : table.reach.$2;
    double at(EditTable table) => across ? table.x : table.y;
    final from = at(all.first) - half(all.first), to = at(all.last) + half(all.last);
    final taken = all.fold(0.0, (sum, table) => sum + 2 * half(table));
    final gap = (to - from - taken) / (all.length - 1);
    final places = <String, double>{};
    var edge = from;
    for (final table in all) {
      places[table.key] = _tidy(edge + half(table));
      edge += 2 * half(table) + gap;
    }
    _each((table) => across ? table.copyWith(x: places[table.key]) : table.copyWith(y: places[table.key]));
  }

  // ---- tables added and taken off

  /// The next name in [room] as its tables are named: after A1 to A9, A10. A name no table has.
  String nextName(String room) {
    final pattern = RegExp(r'^(.*?)(\d+)$');
    final counts = <String, int>{}, highest = <String, int>{};
    for (final table in _tables) {
      final match = pattern.firstMatch(table.label);
      if (match == null) continue;
      final lead = match.group(1)!, number = int.parse(match.group(2)!);
      highest[lead] = math.max(highest[lead] ?? 0, number);
      if (table.room == room) counts[lead] = (counts[lead] ?? 0) + 1;
    }
    var lead = 'T';
    if (counts.isNotEmpty) {
      lead = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    } else if (this.room(room)?.name case final name? when RegExp('^[A-Za-z]').hasMatch(name)) {
      // an empty room names its first table after itself: "Patio" has P1
      lead = name[0].toUpperCase();
    }
    final taken = {for (final table in _tables) table.label.toLowerCase()};
    for (var number = (highest[lead] ?? 0) + 1; ; number++) {
      final name = '$lead$number';
      if (!taken.contains(name.toLowerCase())) return name;
    }
  }

  String _newKey() => 'new-${++_made}';

  /// A place for a table whose frame reaches [across] and [down] from its middle, as near [wanted] as
  /// there is free floor: to the right of it, then in the row under.
  Offset _free(Offset wanted, double across, double down) {
    bool taken(Offset at) {
      final frame = Rect.fromLTRB(at.dx - across, at.dy - down, at.dx + across, at.dy + down).inflate(4);
      return _tables.any((table) => table.bounds.overlaps(frame));
    }

    for (var row = 0; row < 12; row++) {
      for (var step = 0; step < 24; step++) {
        final at = wanted + Offset(step * (2 * across + 12), row * (2 * down + 12));
        if (!taken(at)) return at;
      }
    }
    return wanted;
  }

  /// Puts down a table of [preset] and picks it: at [at] (the middle of what the screen shows) or the
  /// nearest free floor to it, in the room there; with no [at], beside what is picked, in its room. [room]
  /// says the room otherwise, and the first room is the last resort. Returns its key; null in a plan with
  /// no room, or one that is full.
  String? add(TablePreset preset, {String? room, Offset? at}) {
    if (_rooms.isEmpty || _tables.length >= tablesMax) return null;
    final into = room ?? (at == null ? pickedTables.lastOrNull?.room : roomAt(at)) ?? _rooms.first.key;
    final beside = pickedTables.lastOrNull ?? _tables.where((table) => table.room == into).lastOrNull;
    final made = EditTable(
      key: _newKey(),
      label: nextName(into),
      room: into,
      x: 0,
      y: 0,
      w: preset.w,
      h: preset.round ? preset.w : preset.h,
      seats: preset.seats,
      round: preset.round,
      rotation: preset.round ? 0 : preset.rotation,
      kind: preset.kind,
    );
    final (across, down) = made.reach;
    final wanted =
        at ??
        (beside == null
            ? (frame?.bottomLeft ?? const Offset(100, 100)) + Offset(across, down + 40)
            : beside.center + Offset(beside.reach.$1 + across + 12, 0));
    final place = _free(wanted, across, down);
    final table = made.copyWith(x: _tidy(place.dx), y: _tidy(place.dy));
    _change(tables: [..._tables, table]);
    _picked = {table.key};
    notifyListeners();
    return table.key;
  }

  /// A copy of every picked table beside it, with the next name; the copies are picked.
  void duplicate() {
    final copies = <EditTable>[];
    var tables = _tables;
    for (final table in pickedTables) {
      if (tables.length >= tablesMax) break;
      final (across, down) = table.reach;
      _tables = tables; // (so the next name and the free floor count the copies made so far)
      final place = _free(table.center + Offset(2 * across + 12, 0), across, down);
      final copy = EditTable(
        key: _newKey(),
        label: nextName(table.room),
        room: table.room,
        x: _tidy(place.dx),
        y: _tidy(place.dy),
        w: table.w,
        h: table.h,
        seats: table.seats,
        round: table.round,
        rotation: table.rotation,
        kind: table.kind,
      );
      copies.add(copy);
      tables = [...tables, copy];
    }
    _tables = [
      for (final table in tables)
        if (!copies.contains(table)) table,
    ];
    if (copies.isEmpty) return;
    _change(tables: tables);
    _picked = {for (final copy in copies) copy.key};
    notifyListeners();
  }

  /// Takes the picked tables off the plan. A table in use stays ([inUse]): what is returned says why, one
  /// line for each.
  List<String> remove() {
    final kept = <String>[];
    final going = <String>{};
    for (final table in pickedTables) {
      if (inUse(table) case final why?) {
        kept.add(why);
      } else {
        going.add(table.key);
      }
    }
    _change(
      tables: [
        for (final table in _tables)
          if (!going.contains(table.key)) table,
      ],
    );
    _picked = _picked.difference(going);
    notifyListeners();
    return kept;
  }

  // ---- rooms

  /// Adds a room called [name] after the others. Returns its key; null when the plan has as many as it can.
  String? addRoom(String name) {
    if (_rooms.length >= roomsMax) return null;
    final room = EditRoom(key: _newKey(), name: name.trim());
    _change(rooms: [..._rooms, room]);
    return room.key;
  }

  void renameRoom(String key, String name) => _change(
    rooms: [
      for (final room in _rooms)
        if (room.key == key) room.named(name.trim()) else room,
    ],
  );

  /// Takes a room off the plan. Only an empty one: its tables go to another room or off the plan first.
  bool removeRoom(String key) {
    if (_tables.any((table) => table.room == key) || _rooms.length < 2) return false;
    _change(
      rooms: [
        for (final room in _rooms)
          if (room.key != key) room,
      ],
    );
    return true;
  }

  /// Moves a room [by] places in the order the map lists them.
  void moveRoom(String key, int by) {
    final from = _rooms.indexWhere((room) => room.key == key);
    if (from < 0) return;
    final to = (from + by).clamp(0, _rooms.length - 1);
    final rooms = [..._rooms];
    rooms.insert(to, rooms.removeAt(from));
    _change(rooms: rooms);
  }

  // ---- what is wrong with it, and what is saved

  /// What keeps the plan from being saved, in words; empty when nothing does.
  List<String> get problems {
    final said = <String>[];
    if (_rooms.isEmpty) said.add('The plan needs at least one room.');
    final roomNames = <String>{};
    for (final room in _rooms) {
      if (room.name.isEmpty) {
        said.add('A room has no name.');
      } else if (room.name.length > roomNameMax) {
        said.add('The room name "${room.name}" is longer than $roomNameMax letters.');
      } else if (!roomNames.add(room.name.toLowerCase())) {
        said.add('Two rooms are called "${room.name}".');
      }
    }
    final names = <String>{};
    for (final table in _tables) {
      if (table.label.isEmpty) {
        said.add('A table has no name.');
      } else if (table.label.length > labelMax) {
        said.add('The table name "${table.label}" is longer than $labelMax letters.');
      } else if (!labelLetters.hasMatch(table.label)) {
        said.add('The table name "${table.label}" may have letters, figures, - and _ only.');
      } else if (!names.add(table.label.toLowerCase())) {
        said.add('Two tables are called "${table.label}".');
      }
    }
    return said.toSet().toList();
  }

  /// The keys of the tables that stand on another table's ground: allowed, and worth a look.
  Set<String> get crowded {
    final keys = <String>{};
    for (var i = 0; i < _tables.length; i++) {
      for (var j = i + 1; j < _tables.length; j++) {
        if (_tables[i].overlaps(_tables[j])) keys.addAll([_tables[i].key, _tables[j].key]);
      }
    }
    return keys;
  }

  /// The plan as the hub takes it (`PUT /settings/floor_plan`). A table keeps the name orders carry for it
  /// while it keeps its name; a table that was renamed, and a new one, is a new table by its new name.
  Map<String, dynamic> toJson() {
    final place = {for (final (at, room) in _rooms.indexed) room.key: room.id ?? '#$at'};
    final ids = <String>{};
    String idOf(EditTable table) {
      final kept = table.id != null && _labelAtFirst[table.key] == table.label;
      var id = kept ? table.id! : table.label;
      for (var n = 2; !ids.add(id); n++) {
        id = '${table.label}-$n';
      }
      return id;
    }

    // (the tables that keep their ids are named first, so that a new table never takes one of theirs)
    final named = <String, String>{
      for (final table in _tables)
        if (table.id != null && _labelAtFirst[table.key] == table.label) table.key: idOf(table),
    };
    return {
      'rooms': [
        for (final room in _rooms) {'id': ?room.id, 'name': room.name},
      ],
      'tables': [
        for (final table in _tables)
          {
            'id': named[table.key] ?? idOf(table),
            'label': table.label,
            'room': place[table.room] ?? table.room,
            'x': table.x,
            'y': table.y,
            'w': table.w,
            'h': table.h,
            'seats': table.seats,
            'shape': table.round ? 'round' : 'rect',
            'rotation': table.rotation,
            'kind': table.kind,
          },
      ],
    };
  }
}
