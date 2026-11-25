/// Which map service is asked first for a delivery's drive (docs/delivery.md, "Which service is asked
/// first"): the services the hub can ask how far a delivery goes, and the ones it can ask how long the
/// drive is right now, each list in the order a manager put it, with whether each is turned on, whether the
/// hub has its key, and how many of its day's lookups it has left by the hub's own count.
library;

import 'address_list.dart' show counted;

/// One map service of a list, as the hub says it stands (`services` of `/settings/drive_lookups`).
class DriveService {
  const DriveService({
    required this.name,
    this.title = '',
    this.on = false,
    this.key = false,
    this.left,
    this.dailyMost,
    this.failing,
  });

  /// Null for what names no service.
  static DriveService? of(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], title = json['title'], left = json['left'], most = json['daily_most'];
    final failing = json['failing'];
    if (name is! String || name.isEmpty) return null;
    return DriveService(
      name: name,
      title: title is String && title.isNotEmpty ? title : name,
      on: json['on'] == true,
      key: json['key'] == true,
      left: left is int && left >= 0 ? left : null,
      dailyMost: most is int && most > 0 ? most : null,
      failing: failing is String && failing.isNotEmpty ? failing : null,
    );
  }

  /// The hub's name for it (`geocodio`, `google`, `mapbox`, `azure`), and what a screen calls it.
  final String name;
  final String title;

  /// A manager has it turned on for this, and the hub has a key for it. It is asked with both.
  final bool on;
  final bool key;

  /// How many of its day's lookups it has left, of how many, by the hub's own count; null where the hub has
  /// no key for it.
  final int? left;
  final int? dailyMost;

  /// Why its last asking gave nothing (`refused`, `unreachable`, `limit`, `not_found`); null once it
  /// answered again, and where it was never asked.
  final String? failing;

  bool get asks => on && key;

  /// Asked as often as it may be today.
  bool get usedUp => key && left == 0;

  /// How much of the day's lookups is left, from 1 to 0, for the ring of its badge; null where the hub did
  /// not say.
  double? get share => leftShare(left, dailyMost);

  /// What is left today, for the badge's tooltip and for a reader; null where the hub did not say.
  String? get leftWords => leftToday(left, dailyMost);

  /// How it stands, in a line under its name.
  String get words {
    if (!key) return 'This hub has no key for it (Keys and connections, on this screen)';
    final gave = switch (failing) {
      'refused' => 'Its key was refused the last time it was asked',
      'unreachable' => 'It did not answer the last time it was asked',
      'limit' when !usedUp => 'Its account was at its limit the last time it was asked',
      _ => null,
    };
    final left = usedUp ? 'Asked as often as it may be today' : leftWords;
    return [?left, ?gave].join('. ');
  }

  /// Whether [words] says something is wrong with it.
  bool get troubled => key && (usedUp || failing == 'refused' || failing == 'unreachable' || failing == 'limit');

  DriveService turned(bool on) =>
      DriveService(name: name, title: title, on: on, key: key, left: left, dailyMost: dailyMost, failing: failing);
}

/// How much of a day's lookups is left, from 1 to 0; null where either figure is missing.
double? leftShare(int? left, int? most) => left == null || most == null ? null : (left / most).clamp(0.0, 1.0);

/// "488 of 500 lookups left today"; null where the hub did not say how many are left.
String? leftToday(int? left, int? most) {
  if (left == null) return null;
  if (most == null) return '${left == 0 ? 'no' : counted(left)} ${left == 1 ? 'lookup' : 'lookups'} left today';
  return '${counted(left)} of ${counted(most)} lookups left today';
}

/// The services asked one thing, in the order they are asked.
class DriveOrder {
  const DriveOrder({this.services = const []});

  factory DriveOrder.fromJson(Object? json) => DriveOrder(
    services: [
      if (json is Map)
        if (json['services'] case final List listed)
          for (final one in listed) ?DriveService.of(one),
    ],
  );

  final List<DriveService> services;

  DriveService? named(String name) {
    for (final service in services) {
      if (service.name == name) return service;
    }
    return null;
  }

  /// The ones that are asked, in the order they are: turned on, with a key on the hub.
  List<DriveService> get asking => [
    for (final service in services)
      if (service.asks) service,
  ];

  /// The same services as a dialog left them: in [order] (names it leaves out follow as they stood), each
  /// turned on or off as [on] says, and as it was where that says nothing.
  DriveOrder turned(Map<String, bool> on, List<String> order) {
    final placed = [
      for (final name in order) ?named(name),
      for (final service in services)
        if (!order.contains(service.name)) service,
    ];
    return DriveOrder(services: [for (final service in placed) service.turned(on[service.name] ?? service.on)]);
  }

  /// Whether [other] asks the same services in the same order.
  bool sameAs(DriveOrder other) =>
      services.length == other.services.length &&
      [
        for (final (index, service) in services.indexed)
          service.name == other.services[index].name && service.on == other.services[index].on,
      ].every((same) => same);

  /// As a manager saves it: each service's switch, and their names in the order they are asked.
  Map<String, dynamic> toJson() => {
    for (final service in services) service.name: service.on,
    'order': [for (final service in services) service.name],
  };
}

/// Who is asked how far a delivery goes ([distance]) and who the drive right now ([traffic]), as the hub
/// has it (`/settings/drive_lookups`).
class DriveLookups {
  const DriveLookups({this.distance = const DriveOrder(), this.traffic = const DriveOrder()});

  factory DriveLookups.fromJson(Map<String, dynamic> json) =>
      DriveLookups(distance: DriveOrder.fromJson(json['distance']), traffic: DriveOrder.fromJson(json['traffic']));

  final DriveOrder distance;
  final DriveOrder traffic;
}
