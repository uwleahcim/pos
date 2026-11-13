/// The floor plan as the backend serves it, with the open checks on each table.
library;

import 'coursing.dart';
import 'table_timers.dart';

export 'coursing.dart' show Course;
export 'table_timers.dart';

class Room {
  const Room({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
  factory Room.fromJson(Map<String, dynamic> json) => Room(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    x: (json['x'] as num? ?? 0).toDouble(),
    y: (json['y'] as num? ?? 0).toDouble(),
    w: (json['w'] as num? ?? 0).toDouble(),
    h: (json['h'] as num? ?? 0).toDouble(),
  );
  final String id;
  final String name;
  final double x, y, w, h;
}

class TableSpot {
  const TableSpot({
    required this.id,
    required this.label,
    required this.room,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.seats,
    this.shape = 'rect',
    this.rotation = 0,
    this.kind = 'table',
  });
  factory TableSpot.fromJson(Map<String, dynamic> json) => TableSpot(
    id: json['id'] as String,
    label: json['label'] as String? ?? json['id'] as String,
    room: json['room'] as String? ?? '',
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    w: (json['w'] as num).toDouble(),
    h: (json['h'] as num).toDouble(),
    seats: json['seats'] as int? ?? 2,
    shape: json['shape'] as String? ?? 'rect',
    rotation: (json['rotation'] as num? ?? 0).toDouble(),
    kind: json['kind'] as String? ?? 'table',
  );
  final String id;
  final String label;
  final String room;
  final double x, y, w, h;
  final int seats;
  final String shape;
  final double rotation;
  final String kind;

  bool get round => shape == 'round';
}

/// One open check on a table.
class TableCheck {
  const TableCheck({
    required this.orderId,
    this.guests,
    this.server,
    this.serverId,
    this.openedMs,
    this.items = 0,
    this.fired = const [],
    this.held = const [],
    this.total,
    this.timer,
  });
  factory TableCheck.fromJson(Map<String, dynamic> json) => TableCheck(
    orderId: json['order_id'] as String,
    guests: json['guests'] as int?,
    server: json['server'] as String?,
    serverId: json['server_id'] as String?,
    openedMs: json['opened_ms'] as int?,
    items: json['items'] as int? ?? 0,
    fired: List<String>.from(json['fired'] as List? ?? const []),
    held: List<String>.from(json['held'] as List? ?? const []),
    total: json['total'] as String?,
    timer: TableTimer.fromJson(json['timer']),
  );
  final String orderId;
  final int? guests;

  /// Whose table it is, by name and by id: whoever opened it, or whoever a host or manager gave it to.
  final String? server;
  final String? serverId;
  final int? openedMs;
  final int items;
  final List<String> fired;
  final List<String> held;
  final String? total;

  /// What the table is waiting on and since when, for its countdown ring; null from a hub that sends none.
  final TableTimer? timer;

  /// seated (nothing sent yet), waiting (some courses held after one was fired) or fired (everything sent).
  String get stage {
    if (fired.isEmpty) return 'seated';
    return held.isEmpty ? 'fired' : 'waiting';
  }

  /// Whole minutes since the check was opened, at [nowMs] (wall-clock ms, the hub's as near as it is known).
  int minutesOpen(int nowMs) => openedMs == null || nowMs < openedMs! ? 0 : (nowMs - openedMs!) ~/ 60000;

  /// The same check in another server's hands.
  TableCheck servedBy(String? name, String? id) => TableCheck(
    orderId: orderId,
    guests: guests,
    server: name,
    serverId: id,
    openedMs: openedMs,
    items: items,
    fired: fired,
    held: held,
    total: total,
    timer: timer,
  );
}

class FloorPlan {
  const FloorPlan({
    required this.width,
    required this.height,
    required this.rooms,
    required this.tables,
    required this.status,
    this.courses = Course.defaults,
    this.timers = TableTimers.off,
  });
  factory FloorPlan.fromJson(Map<String, dynamic> json) => FloorPlan(
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    rooms: (json['rooms'] as List? ?? const []).map((r) => Room.fromJson(r as Map<String, dynamic>)).toList(),
    tables: (json['tables'] as List? ?? const []).map((t) => TableSpot.fromJson(t as Map<String, dynamic>)).toList(),
    courses:
        (json['courses'] as List?)?.map((c) => Course.fromJson(c as Map<String, dynamic>)).toList() ?? Course.defaults,
    timers: json['timers'] is Map ? TableTimers.fromJson((json['timers'] as Map).cast()) : TableTimers.off,
    status: {
      for (final e in (json['status'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: (e.value as List).map((c) => TableCheck.fromJson(c as Map<String, dynamic>)).toList(),
    },
  );
  final double width, height;
  final List<Room> rooms;
  final List<TableSpot> tables;

  /// The courses a line can be coursed by now (`/settings/coursing`, as the backend applies it): empty
  /// while coursing is off. The order screen reads the setting itself; this is what the floor was told.
  final List<Course> courses;

  /// The location's table timers (`/settings/table_timers`, as the backend applies it): whether each table
  /// gets a countdown ring and the times of each stage. Off from a hub older than the timers.
  final TableTimers timers;
  final Map<String, List<TableCheck>> status;

  /// Where the table's countdown stands at [nowMs]: the most pressing of its checks', or null with no ring.
  Countdown? countdownAt(String tableId, int nowMs) =>
      timers.mostUrgent(checksAt(tableId).map((check) => check.timer), nowMs);

  List<TableCheck> checksAt(String tableId) => status[tableId] ?? const [];

  /// The same plan with more checks on its tables: the ones this device opened that no backend knows yet.
  FloorPlan withChecks(Map<String, List<TableCheck>> extra) {
    if (extra.isEmpty) return this;
    final merged = {
      for (final e in status.entries) e.key: [...e.value],
    };
    for (final MapEntry(key: table, value: checks) in extra.entries) {
      final here = merged.putIfAbsent(table, () => []);
      here.addAll(checks.where((c) => !here.any((h) => h.orderId == c.orderId)));
    }
    return _with(merged);
  }

  /// The plan with the checks in [given] (order id -> the server's name and id) in those servers' hands: a
  /// table handed over on this device shows its new server before a hub has heard of it.
  FloorPlan withServers(Map<String, (String?, String?)> given) {
    if (given.isEmpty) return this;
    return _with({
      for (final MapEntry(key: table, value: checks) in status.entries)
        table: [
          for (final check in checks)
            if (given[check.orderId] case (final name, final id)) check.servedBy(name, id) else check,
        ],
    });
  }

  FloorPlan _with(Map<String, List<TableCheck>> status) => FloorPlan(
    width: width,
    height: height,
    rooms: rooms,
    tables: tables,
    status: status,
    courses: courses,
    timers: timers,
  );
}
