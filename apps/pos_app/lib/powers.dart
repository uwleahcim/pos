/// Who may do what (docs/roles.md): the powers the location hands to its roles, as the hub keeps them
/// (`GET /settings/powers`). The hub decides every time; the app reads the table to show each person what
/// they may open, and to say whose PIN a step takes.
library;

import 'package:flutter/foundation.dart';

/// The roles that hold every power, whatever the table says: nothing takes one from them.
const alwaysRoles = {'manager', 'owner'};

/// The roles a power can be handed to, in the order the screen lists them. A hub says which of them it
/// knows ([Powers.handed]): the drivers came with deliveries (docs/delivery.md).
const handedRoles = ['server', 'bartender', 'host', 'cashier', 'kitchen', 'driver'];

/// The roles every hub with a table of powers hands them to: what one older than drivers does not say.
const firstRoles = ['server', 'bartender', 'host', 'cashier', 'kitchen'];

/// The power no table hands out: the location's settings, and the table itself.
const settingsPower = 'settings';

/// One power as the screen words it.
class Power {
  const Power(this.id, this.name, this.about);
  final String id;

  /// What the person may do, as a few words: the title of its row.
  final String name;

  /// One line more on what that lets them do.
  final String about;
}

/// A handful of powers that belong together on the screen.
class PowerGroup {
  const PowerGroup(this.name, this.powers);
  final String name;
  final List<Power> powers;
}

/// Every power the app knows, in the order the screen shows them. A power the hub lists and the app does
/// not know is kept as it is and not shown.
const powerGroups = [
  PowerGroup('A PIN on a check', [
    Power('void', 'Approve a void', 'Their PIN takes a dish the kitchen already has off a check.'),
    Power(
      'adjust',
      'Approve a discount or a comp',
      'Their PIN gives a discount or a comp that asks for one, and takes a service charge off.',
    ),
    Power('exempt', 'Approve a tax-exempt check', 'Their PIN marks a check exempt from sales tax.'),
    Power('history', "Read a check's history", 'Every step of a check: who did it, on which screen and when.'),
  ]),
  PowerGroup('Tables', [
    Power('take_tables', 'Take tables', 'A table can be theirs, and a host can seat a party for them.'),
    Power('assign_tables', 'Give tables out', 'Seat a party for another server, and hand a table over.'),
  ]),
  PowerGroup('Deliveries', [
    Power('deliver', 'Take deliveries out', 'A delivery can be handed to them: they are offered as a driver.'),
  ]),
  PowerGroup('The shift', [
    Power('rush', 'Set the kitchen rush', 'Add minutes to every new quote while the kitchen is behind.'),
    Power('notes', 'Write the notes for the shift', 'Put a note up for everybody, change it, take it down.'),
    Power('logbook', "Keep the manager's log", 'Read and write what happened in a shift.'),
    Power('waste', 'Run the waste log', "Read the waste totals, and strike out anyone's entry."),
  ]),
  PowerGroup('The numbers', [
    Power('reports', 'See the reports', 'The day, sales, dishes sold, and what came off the checks.'),
    Power('guests', 'See the guest list', 'Phone customers: their numbers, visits and what they spent.'),
    Power('time_clock', 'See and correct the hours', "Everyone's hours, and corrections to a shift."),
    Power('menu', 'Edit the menu', 'Dishes, prices and options, in the menu editor.'),
  ]),
];

/// Every power the app knows, by id.
final powersById = {
  for (final group in powerGroups)
    for (final power in group.powers) power.id: power,
};

/// The powers a session at the back office is for (the rest are a PIN on a check, or the tables).
const sessionPowers = {'history', 'rush', 'notes', 'logbook', 'waste', 'reports', 'guests', 'time_clock', 'menu'};

/// What is under Location in the menu, besides the settings themselves.
const locationPowers = {'reports', 'guests', 'waste', 'notes', 'logbook', 'time_clock'};

/// A role as the screen names the people in it: "Servers".
String roleLabel(String role) => switch (role) {
  'server' => 'Servers',
  'bartender' => 'Bartenders',
  'host' => 'Hosts',
  'cashier' => 'Cashiers',
  'kitchen' => 'Kitchen',
  'driver' => 'Drivers',
  'manager' => 'Managers',
  'owner' => 'Owners',
  _ => role,
};

/// One of a role, for a sentence: "a bartender", "the kitchen".
String aRole(String role) => switch (role) {
  'kitchen' => 'the kitchen',
  'owner' => 'an owner',
  _ => 'a $role',
};

/// The location's table: for each power, the roles it is handed to besides the managers and the owners.
@immutable
class Powers {
  const Powers(this.roles, {this.handed = firstRoles});

  /// The table as the hub answers it. A role or a power this app does not know is kept, so a save sends it
  /// back as it came.
  factory Powers.fromJson(Map<String, dynamic> json) => Powers({
    for (final entry in (json['roles'] as Map<String, dynamic>? ?? const {}).entries)
      entry.key: List<String>.from(entry.value as List? ?? const []),
  }, handed: json['handed'] is List ? List<String>.from(json['handed'] as List) : firstRoles);

  /// What the hub did before the table could be changed, and what a hub older than the table still does:
  /// the servers and the bartenders take tables, the hosts give them out, and everything else is a
  /// manager's or an owner's. The drivers take deliveries out, where a hub knows of drivers.
  static const standard = Powers({
    'take_tables': ['server', 'bartender'],
    'assign_tables': ['host'],
    'deliver': ['driver'],
  }, handed: handedRoles);

  final Map<String, List<String>> roles;

  /// The roles this hub hands powers to. One older than drivers knows none: the screen offers it no
  /// button for them, and nothing is sent that it would refuse.
  final List<String> handed;

  /// The roles the screen has a button for: the ones this app words and this hub knows, in the screen's
  /// order.
  List<String> get offered => [
    for (final role in handedRoles)
      if (handed.contains(role)) role,
  ];

  /// Whether this hub has [power] in its table. One a hub has never heard of is not shown, and not sent.
  bool knows(String power) => roles.containsKey(power);

  /// Whether a person of [role] may do [power]. A manager and an owner may do everything.
  bool holds(String? role, String power) {
    if (role == null) return false;
    if (alwaysRoles.contains(role)) return true;
    if (power == settingsPower) return false;
    return roles[power]?.contains(role) ?? false;
  }

  /// Whether a person of [role] has anything to open under Location.
  bool opensLocation(String? role) => holds(role, settingsPower) || locationPowers.any((power) => holds(role, power));

  /// The roles [power] is handed to, in the screen's order.
  List<String> handedTo(String power) => [
    for (final role in handedRoles)
      if (roles[power]?.contains(role) ?? false) role,
  ];

  /// The table with [power] handed to [role], or taken back from it.
  Powers hand(String power, String role, {required bool on}) => Powers({
    ...roles,
    power: [
      for (final r in handedRoles)
        if (r == role ? on : (roles[power]?.contains(r) ?? false)) r,
    ],
  }, handed: handed);

  /// The table as it started, before anybody changed it: what the standard one hands out of the powers
  /// and to the roles this hub knows, and no more.
  Powers get asItStarted => Powers({
    ...roles,
    for (final power in powersById.keys)
      if (knows(power))
        power: [
          for (final role in standard.handedTo(power))
            if (handed.contains(role)) role,
        ],
  }, handed: handed);

  /// Whose PIN [power] takes, for a sentence: "a manager", "a manager or a bartender", "a manager, a host
  /// or a server". An owner's does too, and is not said: there is a manager wherever there is an owner.
  String whose(String power) {
    final who = ['a manager', for (final role in handedTo(power)) aRole(role)];
    if (who.length == 1) return who.single;
    return '${who.sublist(0, who.length - 1).join(', ')} or ${who.last}';
  }

  /// The title of the box that asks for the PIN: a manager's, until somebody else may give it too.
  String pinTitle(String? power) {
    final others = power == null ? locationPowers.any((p) => handedTo(p).isNotEmpty) : handedTo(power).isNotEmpty;
    return others ? 'PIN' : 'Manager PIN';
  }

  /// What the table hands out beyond the standard one, and what it takes from it, as one line for the
  /// row that opens the screen.
  String get summary {
    final changes = <String>[];
    for (final group in powerGroups) {
      for (final power in group.powers) {
        if (!knows(power.id)) continue; // a hub older than the power: nothing to say of it
        final now = handedTo(power.id);
        final usual = asItStarted.handedTo(power.id);
        if (listEquals(now, usual)) continue;
        changes.add('${power.name}: ${now.isEmpty ? 'managers only' : now.map(roleLabel).join(', ')}');
      }
    }
    if (changes.isEmpty) return 'As it started: managers and owners approve and open the back office';
    return changes.join(' · ');
  }

  Map<String, dynamic> toJson() => {'roles': roles};

  /// Two tables are the same when they hand the same powers to the same roles: a power one of them does
  /// not list is one it hands to nobody.
  @override
  bool operator ==(Object other) =>
      other is Powers &&
      {...roles.keys, ...other.roles.keys}.every((power) => setEquals({...?roles[power]}, {...?other.roles[power]}));

  @override
  int get hashCode => Object.hashAllUnordered([
    for (final entry in roles.entries)
      if (entry.value.isNotEmpty) Object.hash(entry.key, Object.hashAllUnordered(entry.value)),
  ]);
}
