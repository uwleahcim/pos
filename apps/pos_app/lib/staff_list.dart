/// The staff as a manager keeps them in the app (docs/staff.md): who is on the list, each one's role, and
/// where each one's PIN is from. The hub keeps the list and checks every PIN; this app never has a PIN to
/// show, only who set one and when.
library;

import 'package:flutter/foundation.dart';

import 'hub_keys.dart' show keyDay;

/// A PIN as the hub takes one: four digits. The sign-in pad sends what was typed on the fourth.
final pinPattern = RegExp(r'^[0-9]{4}$');

/// One person of a role, as their line on the list says it: "Server".
String roleName(String role) => switch (role) {
  'server' => 'Server',
  'bartender' => 'Bartender',
  'host' => 'Host',
  'cashier' => 'Cashier',
  'kitchen' => 'Kitchen',
  'driver' => 'Driver',
  'manager' => 'Manager',
  'owner' => 'Owner',
  '' => 'No role',
  _ => role,
};

/// One person on the staff, as the hub lists them for a manager.
@immutable
class StaffPerson {
  const StaffPerson({
    required this.staffId,
    required this.name,
    required this.role,
    this.you = false,
    this.pinFrom = 'app',
    this.pinBy = '',
    this.pinAt,
    this.canChange = true,
    this.canRole = true,
    this.canRemove = true,
    this.why,
  });

  factory StaffPerson.fromJson(Map<String, dynamic> json) {
    final pin = json['pin'] as Map<String, dynamic>? ?? const {};
    final can = json['can'] as Map<String, dynamic>? ?? const {};
    final at = (pin['at_ms'] as num?)?.toInt();
    return StaffPerson(
      staffId: json['staff_id'] as String,
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      you: json['you'] as bool? ?? false,
      pinFrom: pin['from'] as String? ?? 'app',
      pinBy: pin['by'] as String? ?? '',
      pinAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      canChange: can['change'] as bool? ?? true,
      canRole: can['role'] as bool? ?? true,
      canRemove: can['remove'] as bool? ?? true,
      why: can['why'] as String?,
    );
  }

  final String staffId;
  final String name;
  final String role;

  /// This is the person whose PIN opened the screen.
  final bool you;

  /// Where the PIN is from: `demo` (the demo staff's, which are in the guide), `hub` (the hub's own file),
  /// `app` (a manager set it here), `terminal` (set with `hubctl staff pin`).
  final String pinFrom;

  /// Who set the PIN, by name, and when; neither for one the hub's own file gave.
  final String pinBy;
  final DateTime? pinAt;

  /// What the person looking may do to this one: change the name and the PIN, change the role, take them
  /// off the staff. And [why] not: `owner_only` (only an owner touches an owner), `yourself`. For
  /// themselves [canRole] is only ever making themselves the owner, where the location has none yet.
  final bool canChange;
  final bool canRole;
  final bool canRemove;
  final String? why;

  /// The PIN is one anybody can read in the guide.
  bool get demoPin => pinFrom == 'demo';

  /// One line on the person's PIN: "PIN set by Mike today", never the PIN.
  String pinLine(DateTime now) {
    final when = pinAt == null ? '' : ' ${_on(keyDay(pinAt!, now))}';
    return switch (pinFrom) {
      'demo' => 'PIN from the guide: change it',
      'hub' => "PIN from the hub's terminal",
      'terminal' => "PIN set in the hub's terminal$when",
      _ => 'PIN set${pinBy.isEmpty ? '' : ' by $pinBy'}$when',
    };
  }

  /// Why the person looking cannot change this one, in words; null when they can do everything.
  String? get whyNot => switch (why) {
    'owner_only' => 'Only an owner changes an owner or takes one off the staff.',
    'yourself' =>
      canRole
          ? 'Nobody is an owner here yet: you can make yourself the owner. Any other role for you, and '
                'taking you off the staff, is for another manager.'
          : 'Your own role is for another manager to change, and so is taking you off the staff.',
    _ => null,
  };
}

String _on(String day) => day == 'today' || day == 'yesterday' ? day : 'on $day';

/// The staff list as the hub answers it (`GET /hub/staff`).
@immutable
class StaffList {
  const StaffList({required this.people, this.source = 'app', this.roles = const [], this.demoPins = 0, this.added});

  factory StaffList.fromJson(Map<String, dynamic> json) => StaffList(
    people: [for (final p in json['staff'] as List? ?? const []) StaffPerson.fromJson(p as Map<String, dynamic>)],
    source: json['source'] as String? ?? 'app',
    roles: [...(json['roles'] as List? ?? const []).cast<String>()],
    demoPins: (json['demo_pins'] as num?)?.toInt() ?? 0,
    added: json['added'] as String?,
  );

  final List<StaffPerson> people;

  /// Whose list signs in: `app` (kept in the app), or the hub's own: `hub` (its terminal's `POS_STAFF`) or
  /// `demo` (the demo staff, where the hub names nobody).
  final String source;

  /// The roles the person looking can give, in the order to offer them.
  final List<String> roles;

  /// How many people still sign in with a PIN from the guide.
  final int demoPins;

  /// The id of the person a call just added.
  final String? added;

  StaffPerson? byId(String staffId) => people.where((p) => p.staffId == staffId).firstOrNull;

  /// One line for Location's row: how many, and what needs doing.
  String get summary {
    final count = people.length;
    final head = '$count ${count == 1 ? 'person' : 'people'}';
    if (demoPins > 0) {
      final who = demoPins == count ? (count == 1 ? 'with a PIN' : 'all with PINs') : '$demoPins still with a PIN';
      return '$head · $who from the guide, which anybody can read';
    }
    return source == 'hub' ? "$head, from the hub's terminal" : head;
  }
}
