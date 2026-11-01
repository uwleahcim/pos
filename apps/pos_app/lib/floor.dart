/// The floor plan as the backend serves it, with the open checks on each table.
library;

class Course {
  const Course(this.id, this.name);
  factory Course.fromJson(Map<String, dynamic> json) => Course(json['id'] as String, json['name'] as String? ?? '');
  final String id;
  final String name;

  static const defaults = [
    Course('drinks', 'Drinks'),
    Course('1', 'Appetizers'),
    Course('2', 'Entrees'),
    Course('3', 'Dessert'),
  ];
}

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
    this.openedMs,
    this.items = 0,
    this.fired = const [],
    this.held = const [],
    this.total,
  });
  factory TableCheck.fromJson(Map<String, dynamic> json) => TableCheck(
    orderId: json['order_id'] as String,
    guests: json['guests'] as int?,
    server: json['server'] as String?,
    openedMs: json['opened_ms'] as int?,
    items: json['items'] as int? ?? 0,
    fired: List<String>.from(json['fired'] as List? ?? const []),
    held: List<String>.from(json['held'] as List? ?? const []),
    total: json['total'] as String?,
  );
  final String orderId;
  final int? guests;
  final String? server;
  final int? openedMs;
  final int items;
  final List<String> fired;
  final List<String> held;
  final String? total;

  /// seated (nothing sent yet), waiting (some courses held after one was fired) or fired (everything sent).
  String get stage {
    if (fired.isEmpty) return 'seated';
    return held.isEmpty ? 'fired' : 'waiting';
  }

  int minutesOpen(DateTime now) => openedMs == null ? 0 : (now.millisecondsSinceEpoch - openedMs!) ~/ 60000;
}

class FloorPlan {
  const FloorPlan({
    required this.width,
    required this.height,
    required this.rooms,
    required this.tables,
    required this.status,
    this.courses = Course.defaults,
  });
  factory FloorPlan.fromJson(Map<String, dynamic> json) => FloorPlan(
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    rooms: (json['rooms'] as List? ?? const []).map((r) => Room.fromJson(r as Map<String, dynamic>)).toList(),
    tables: (json['tables'] as List? ?? const []).map((t) => TableSpot.fromJson(t as Map<String, dynamic>)).toList(),
    courses:
        (json['courses'] as List?)?.map((c) => Course.fromJson(c as Map<String, dynamic>)).toList() ?? Course.defaults,
    status: {
      for (final e in (json['status'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: (e.value as List).map((c) => TableCheck.fromJson(c as Map<String, dynamic>)).toList(),
    },
  );
  final double width, height;
  final List<Room> rooms;
  final List<TableSpot> tables;
  final List<Course> courses;
  final Map<String, List<TableCheck>> status;

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
    return FloorPlan(width: width, height: height, rooms: rooms, tables: tables, status: merged, courses: courses);
  }
}
