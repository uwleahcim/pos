/// The staff by name and role (`GET /staff`): who a table can be given to, who may give one, and who a
/// delivery can be handed to.
library;

import 'floor.dart';

/// One person on the staff, as the screens that put a name to a table need them.
class StaffMember {
  const StaffMember({
    required this.staffId,
    required this.name,
    this.role = '',
    this.takesTables = false,
    this.assignsTables = false,
    this.delivers = false,
  });

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
    staffId: json['staff_id'] as String,
    name: json['name'] as String? ?? '',
    role: json['role'] as String? ?? '',
    takesTables: json['takes_tables'] as bool? ?? false,
    assignsTables: json['assigns_tables'] as bool? ?? false,
    delivers: json['delivers'] as bool? ?? false,
  );

  final String staffId;
  final String name;
  final String role;

  /// A table can be this person's: the servers, the bartenders, a manager.
  final bool takesTables;

  /// This person seats a party for someone else and hands a table over: the hosts, a manager.
  final bool assignsTables;

  /// A delivery can be handed to this person (docs/delivery.md): the drivers, a manager. A hub older than
  /// drivers says it of nobody.
  final bool delivers;
}

/// The location's staff. The hub says who takes tables and who gives them out; the app only asks.
class Roster {
  const Roster(this.staff);

  factory Roster.fromJson(Map<String, dynamic> json) =>
      Roster([for (final s in json['staff'] as List? ?? const []) StaffMember.fromJson(s as Map<String, dynamic>)]);

  /// Nobody: a hub older than the list, or one that has not answered yet. Everyone seats their own tables.
  static const none = Roster([]);

  final List<StaffMember> staff;

  StaffMember? byId(String? staffId) => staff.where((s) => s.staffId == staffId).firstOrNull;

  /// The people a table can be given to, as the hub lists them.
  List<StaffMember> get servers => [
    for (final s in staff)
      if (s.takesTables) s,
  ];

  /// The people a delivery can be handed to, as the hub lists them. Nobody on a hub older than drivers:
  /// a delivery is then marked delivered with no driver named, as before.
  List<StaffMember> get drivers => [
    for (final s in staff)
      if (s.delivers) s,
  ];

  /// Whether this person picks the server as a party is sat, rather than taking the table themselves.
  bool assigns(String? staffId) => byId(staffId)?.assignsTables ?? false;
}

/// What a server has on the floor right now: a host reads it to seat the next party fairly.
class ServerLoad {
  const ServerLoad({this.tables = 0, this.guests = 0});

  /// The open tables that are [server]'s on [plan], and the guests at them.
  factory ServerLoad.of(FloorPlan plan, StaffMember server) {
    var tables = 0, guests = 0;
    for (final checks in plan.status.values) {
      final theirs = checks.where((c) => c.isServedBy(server)).toList();
      if (theirs.isEmpty) continue;
      tables++;
      guests += theirs.fold(0, (sum, c) => sum + (c.guests ?? 0));
    }
    return ServerLoad(tables: tables, guests: guests);
  }

  final int tables;
  final int guests;

  /// "No tables", "1 table · 4 guests", "3 tables · 11 guests".
  String get inWords => tables == 0
      ? 'No tables'
      : '$tables ${tables == 1 ? 'table' : 'tables'} · $guests ${guests == 1 ? 'guest' : 'guests'}';
}

extension ServedBy on TableCheck {
  /// Whether this check is [server]'s: by id, or by name on a check that carries no id (an older hub's).
  bool isServedBy(StaffMember server) => serverId != null ? serverId == server.staffId : this.server == server.name;
}

/// A server's name in the room a table has: "Amy" stays, "Mike Wu" is "Mike W".
String shortName(String? name) {
  final words = (name ?? '').trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return '';
  return words.length == 1 ? words.single : '${words.first} ${words.last.substring(0, 1).toUpperCase()}';
}
