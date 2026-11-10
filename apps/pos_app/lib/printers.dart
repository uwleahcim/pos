/// Kitchen printers as the location's setting: each prints for one station (wok1, fryer, bar, takeout),
/// speaks ESC/POS or StarPRNT and names the printers that take its tickets when it fails, in order. The hub
/// keeps them (`GET/PUT /settings/printers`; a manager sets them under Location settings › Printers) and
/// routes every ticket by them; `GET /print/stations` says which stations the menu prints at and which have
/// no printer yet.
library;

import 'package:flutter/foundation.dart';

/// The languages a printer may speak, as the hub names them, with what the screen calls each.
const dialectLabels = {'escpos': 'ESC/POS (Epson and most)', 'star': 'Star (StarPRNT)'};

/// One printer: its id (the hub's, once saved; the other printers' fallbacks name it), the station it prints
/// for, its address (host or IP, with :port when it is not 9100), its language and its fallbacks in order.
@immutable
class PrinterConfig {
  const PrinterConfig({
    this.id,
    required this.station,
    required this.address,
    this.dialect = 'escpos',
    this.fallbacks = const [],
  });

  factory PrinterConfig.fromJson(Map<String, dynamic> json) => PrinterConfig(
    id: json['id'] as String?,
    station: json['station'] as String? ?? '',
    address: json['address'] as String? ?? '',
    dialect: json['dialect'] as String? ?? 'escpos',
    fallbacks: [for (final f in json['fallbacks'] as List? ?? const []) f as String],
  );

  final String? id;
  final String station;
  final String address;
  final String dialect;
  final List<String> fallbacks;

  Map<String, dynamic> toJson() => {
    'id': id,
    'station': station,
    'address': address,
    'dialect': dialect,
    'fallbacks': fallbacks,
  };

  PrinterConfig copyWith({String? id, String? station, String? address, String? dialect, List<String>? fallbacks}) =>
      PrinterConfig(
        id: id ?? this.id,
        station: station ?? this.station,
        address: address ?? this.address,
        dialect: dialect ?? this.dialect,
        fallbacks: fallbacks ?? this.fallbacks,
      );

  @override
  bool operator ==(Object other) =>
      other is PrinterConfig &&
      other.id == id &&
      other.station == station &&
      other.address == address &&
      other.dialect == dialect &&
      listEquals(other.fallbacks, fallbacks);

  @override
  int get hashCode => Object.hash(id, station, address, dialect, Object.hashAll(fallbacks));
}

/// The printers as the hub keeps them, in the order they stand (the first takes whatever has no printer of
/// its own), the station a to-go order prints whole at, and where they came from: `settings`, `env` (the
/// hub's POS_PRINTERS, shown until a manager saves) or `none`.
class PrinterSettings {
  const PrinterSettings({this.printers = const [], this.takeoutStation = 'takeout', this.source = 'settings'});

  factory PrinterSettings.fromJson(Map<String, dynamic> json) => PrinterSettings(
    printers: [
      for (final p in json['printers'] as List? ?? const []) PrinterConfig.fromJson((p as Map).cast<String, dynamic>()),
    ],
    takeoutStation: json['takeout_station'] as String?,
    source: json['source'] as String? ?? 'settings',
  );

  final List<PrinterConfig> printers;
  final String? takeoutStation;
  final String source;

  Map<String, dynamic> toJson() => {
    'printers': [for (final p in printers) p.toJson()],
    'takeout_station': takeoutStation,
  };
}

/// A station as the hub lists it: its code and name, how many dishes print there and how many choices send
/// a dish there as well, the id of the printer serving it (null for none), whether it is the takeout
/// station, and whether the menu knows it at all (a printer may name a station no dish uses yet).
@immutable
class StationInfo {
  const StationInfo({
    required this.code,
    required this.name,
    this.known = true,
    this.dishes = 0,
    this.choices = 0,
    this.printer,
    this.takeout = false,
  });

  factory StationInfo.fromJson(Map<String, dynamic> json) => StationInfo(
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? json['code'] as String? ?? '',
    known: json['known'] as bool? ?? true,
    dishes: (json['dishes'] as num?)?.toInt() ?? 0,
    choices: (json['choices'] as num?)?.toInt() ?? 0,
    printer: json['printer'] as String?,
    takeout: json['takeout'] as bool? ?? false,
  );

  final String code;
  final String name;
  final bool known;
  final int dishes;
  final int choices;
  final String? printer;
  final bool takeout;

  /// Why the menu needs this station, in a few words: "42 dishes", "1 choice", "to-go orders".
  String get why {
    final parts = <String>[
      if (dishes > 0) '$dishes ${dishes == 1 ? 'dish' : 'dishes'}',
      if (choices > 0) '$choices ${choices == 1 ? 'choice' : 'choices'}',
      if (takeout) 'to-go orders',
    ];
    return parts.join(', ');
  }
}

/// The stations the hub lists, with the ones that print something and have no printer (`missing`).
class StationList {
  const StationList({this.stations = const [], this.missing = const [], this.takeoutStation});

  factory StationList.fromJson(Map<String, dynamic> json) => StationList(
    stations: [
      for (final s in json['stations'] as List? ?? const []) StationInfo.fromJson((s as Map).cast<String, dynamic>()),
    ],
    missing: [for (final m in json['missing'] as List? ?? const []) m as String],
    takeoutStation: json['takeout_station'] as String?,
  );

  final List<StationInfo> stations;
  final List<String> missing;
  final String? takeoutStation;

  StationInfo? byCode(String code) => stations.where((s) => s.code == code).firstOrNull;

  /// The station's name as the menu has it, or its code when the menu does not know it.
  String nameOf(String code) => byCode(code)?.name ?? code;
}

/// A printer the hub found on the LAN, or the answer about one address: whether it answers on port 9100,
/// which language it spoke (null when it could not be told) and the model and maker it gave.
@immutable
class FoundPrinter {
  const FoundPrinter({required this.address, this.reachable = true, this.dialect, this.model, this.maker});

  factory FoundPrinter.fromJson(Map<String, dynamic> json) => FoundPrinter(
    address: json['address'] as String? ?? '',
    reachable: json['reachable'] as bool? ?? true,
    dialect: json['dialect'] as String?,
    model: json['model'] as String?,
    maker: json['maker'] as String?,
  );

  final String address;
  final bool reachable;
  final String? dialect;
  final String? model;
  final String? maker;

  /// One line about it: "TM-T88VII · ESC/POS", "Star (StarPRNT)", "answers, language unknown".
  String get line {
    if (!reachable) return 'does not answer';
    final language = dialect == null ? 'language unknown: pick it' : dialectLabels[dialect] ?? dialect!;
    final name = [maker, model].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    return name.isEmpty ? language : '$name · $language';
  }
}
