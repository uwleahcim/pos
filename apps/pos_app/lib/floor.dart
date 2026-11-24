/// The floor plan as the backend serves it, with the open checks on each table.
library;

import 'coursing.dart';
import 'kitchen_word.dart';
import 'seated.dart';
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
    this.ready = 0,
    this.readyMs,
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
    ready: (json['ready'] as num?)?.toInt() ?? 0,
    readyMs: (json['ready_ms'] as num?)?.toInt(),
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

  /// How many of its dishes the kitchen marked made that have not gone out, and when the last of them was
  /// made: the food that waits for someone to carry it. None on a table whose kitchen marks nothing, and
  /// from a hub older than the mark.
  final int ready;
  final int? readyMs;

  /// The dishes ready for this check that the map still points at, at [nowMs]: none once they have waited
  /// past [readyShownMs] with nobody saying they went out.
  int readyAt(int nowMs) => ready > 0 && readyMs != null && nowMs - readyMs! < readyShownMs ? ready : 0;

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
    ready: ready,
    readyMs: readyMs,
  );
}

/// A table booked for today (docs/reservations.md): whose it is, how many and for when, as the hub told the
/// floor. The hub stamps every moment with its own clock, and the map counts them against that clock: an
/// answer nobody changed stays the same all day.
class TableHold {
  const TableHold({
    required this.id,
    required this.name,
    required this.size,
    required this.atMs,
    required this.heldMs,
    required this.soonMs,
    required this.lateMs,
    required this.untilMs,
    this.time = '',
    this.arrivedMs,
  });

  factory TableHold.fromJson(Map<String, dynamic> json) {
    int? ms(Object? value) => value is num ? value.toInt() : null;
    final at = ms(json['at_ms']) ?? 0;
    return TableHold(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: ms(json['size']) ?? 1,
      atMs: at,
      time: json['time'] as String? ?? '',
      arrivedMs: ms(json['arrived_ms']),
      heldMs: ms(json['held_ms']) ?? at - _kept,
      soonMs: ms(json['soon_ms']) ?? at - _near,
      lateMs: ms(json['late_ms']) ?? at + _near,
      untilMs: ms(json['until_ms']) ?? at + _kept,
    );
  }

  // What a hub that named no moments would mean: an hour and a half each way, a quarter of an hour near.
  static const _kept = 90 * 60000, _near = 15 * 60000;

  /// The reservation, as the book knows it.
  final String id;
  final String name;

  /// How many guests.
  final int size;

  /// The time the table is booked for, and that time on the restaurant's clock ("18:30").
  final int atMs;
  final String time;

  /// When the party came in, for one that waits for its table; null when it has not.
  final int? arrivedMs;

  /// The table is kept for the party from [heldMs], since whoever sat down there then would still be eating
  /// at its time, until [untilMs]; after that the map says no more about it.
  final int heldMs;
  final int untilMs;

  /// When its time is near (amber from then), and when it is past with nobody seated (red from then).
  final int soonMs;
  final int lateMs;

  bool get isHere => arrivedMs != null;

  /// "Chen, party of 4".
  String get label => '$name, party of $size';

  /// The table is being kept for this party at [nowMs]: somebody else sat there is in its way.
  bool keptAt(int nowMs) => nowMs >= heldMs && nowMs < untilMs;

  /// How its time stands at [nowMs]: still ahead, near (amber), or past with nobody seated (red).
  TimerLevel levelAt(int nowMs) => nowMs >= lateMs
      ? TimerLevel.late
      : nowMs >= soonMs
      ? TimerLevel.warn
      : TimerLevel.ok;
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
    this.moves = false,
    this.holds = const {},
    this.turn,
    this.seated = const {},
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
    moves: json['moves'] == true,
    holds: {
      if (json['holds'] case final Map<dynamic, dynamic> holds)
        for (final e in holds.entries)
          if (e.value case final List<dynamic> rows when rows.isNotEmpty)
            '${e.key}': [
              for (final row in rows)
                if (row is Map) TableHold.fromJson(row.cast()),
            ],
    },
    turn: json['turn'] is List ? [for (final id in json['turn'] as List) '$id'] : null,
    seated: {
      if (json['seated'] case final Map<dynamic, dynamic> seated)
        for (final e in seated.entries)
          if (_parties(e.value) case final parties when parties.isNotEmpty) '${e.key}': parties,
    },
  );

  /// The parties among [rows] that have something to show: a name, or a tag.
  static List<SeatedParty> _parties(Object? rows) => [
    if (rows case final List<dynamic> rows)
      for (final row in rows)
        if (row is Map)
          if (SeatedParty.fromJson(row.cast()) case final party when party.says) party,
  ];
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

  /// Whether a table's check can move to another table and merge with its check: the hub says so, and one
  /// older than moving does not.
  final bool moves;

  /// The tables booked for today, by table id: the reservations still standing that hold each, the earliest
  /// first. Empty from a hub older than the book on the map, and for a table nobody booked.
  final Map<String, List<TableHold>> holds;

  /// Tonight's turn for a table (docs/table-servers.md): the staff ids of the people in it, whose turn it is
  /// first. Empty while nobody was said to be on; null from a hub older than the turn.
  final List<String>? turn;

  /// Who sits at the tables (docs/guest-list.md, "On the floor map"): by the id of each open check the host
  /// seated a party on, from its reservation or the waitlist, its parties, the first to sit first, each by
  /// its name with the tags its number carries. Empty from a hub older than it, and a walk-in's check is
  /// not in it.
  final Map<String, List<SeatedParty>> seated;

  /// The parties seated at the table, over all its checks: whose table it is.
  List<SeatedParty> guestsAt(String tableId) => guestsOf(checksAt(tableId));

  /// The parties seated on these checks, the first check's first.
  List<SeatedParty> guestsOf(Iterable<TableCheck> checks) => [for (final check in checks) ...?seated[check.orderId]];

  /// What is still to come of the table's reservations at [nowMs], the earliest first: the ones whose
  /// table is still kept. One an hour and a half past its time with nobody seated is no longer among them.
  List<TableHold> holdsAt(String tableId, int nowMs) => [
    for (final hold in holds[tableId] ?? const <TableHold>[])
      if (nowMs < hold.untilMs) hold,
  ];

  /// The reservations the table is being kept for at [nowMs]: whoever else sits there now is in their
  /// way. Empty for a table that is not booked, or booked for a time still far off.
  List<TableHold> keptAt(String tableId, int nowMs) => [
    for (final hold in holds[tableId] ?? const <TableHold>[])
      if (hold.keptAt(nowMs)) hold,
  ];

  /// The table each open check is at, by order id.
  Map<String, String> get tableOf => {
    for (final MapEntry(key: table, value: checks) in status.entries)
      for (final check in checks) check.orderId: table,
  };

  /// Where the table's countdown stands at [nowMs]: the most pressing of its checks', or null with no ring.
  Countdown? countdownAt(String tableId, int nowMs) =>
      timers.mostUrgent(checksAt(tableId).map((check) => check.timer), nowMs);

  List<TableCheck> checksAt(String tableId) => status[tableId] ?? const [];

  /// How many dishes are ready for the table at [nowMs], over all its checks: what its badge counts.
  int readyAt(String tableId, int nowMs) => checksAt(tableId).fold(0, (n, check) => n + check.readyAt(nowMs));

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

  /// The plan with the checks in [moved] (order id -> table id) at those tables and the checks in [gone]
  /// off the floor: a table moved or merged on this device shows where it went before a hub has heard.
  FloorPlan withTables(Map<String, String> moved, Set<String> gone) {
    if (moved.isEmpty && gone.isEmpty) return this;
    final next = <String, List<TableCheck>>{};
    final landing = <String, List<TableCheck>>{};
    for (final MapEntry(key: table, value: checks) in status.entries) {
      for (final check in checks) {
        if (gone.contains(check.orderId)) continue;
        final to = moved[check.orderId];
        (to == null || to == table ? next : landing).putIfAbsent(to ?? table, () => []).add(check);
      }
    }
    for (final MapEntry(key: table, value: checks) in landing.entries) {
      next.putIfAbsent(table, () => []).addAll(checks);
    }
    return _with(next);
  }

  FloorPlan _with(Map<String, List<TableCheck>> status) => FloorPlan(
    width: width,
    height: height,
    rooms: rooms,
    tables: tables,
    status: status,
    courses: courses,
    timers: timers,
    moves: moves,
    holds: holds,
    turn: turn,
    seated: seated,
  );
}
