/// Kitchen printers as the location's setting: each prints for one station or several (wok1, fryer, bar,
/// takeout), speaks ESC/POS or StarPRNT (set, or found out from the printer: "auto") and names the printers
/// that take its tickets when it fails, in order. The hub
/// keeps them (`GET/PUT /settings/printers`; a manager sets them under Location settings › Printers) and
/// routes every ticket by them; `GET /print/stations` says which stations the menu prints at and which have
/// no printer yet.
library;

import 'package:flutter/foundation.dart';

/// The languages a printer may speak, as the hub names them, with what the screen calls each.
const dialectLabels = {'escpos': 'ESC/POS (Epson and most)', 'star': 'Star (StarPRNT)'};

/// The same in a word or two, for a button.
const dialectShort = {'escpos': 'ESC/POS', 'star': 'Star'};

/// A printer's language setting that is no language: the hub prints in the one the printer was found to
/// speak ([PrinterConfig.detected]).
const autoDialect = 'auto';

/// One printer: its id (the hub's, once saved; the other printers' fallbacks name it), the stations it prints
/// for, its address (host or IP, with :port when it is not 9100), its language ([dialect]: `escpos`, `star`,
/// or `auto` with [detected], what the printer itself answered) and its fallbacks in order.
@immutable
class PrinterConfig {
  const PrinterConfig({
    this.id,
    required this.stations,
    required this.address,
    this.dialect = autoDialect,
    this.detected,
    this.fallbacks = const [],
  });

  factory PrinterConfig.fromJson(Map<String, dynamic> json) {
    final stations = [
      for (final s in json['stations'] as List? ?? const [])
        if (s is String && s.isNotEmpty) s,
    ];
    final one = json['station'] as String? ?? '';
    return PrinterConfig(
      id: json['id'] as String?,
      stations: stations.isNotEmpty ? stations : [if (one.isNotEmpty) one], // an older hub: one station each
      address: json['address'] as String? ?? '',
      dialect: json['dialect'] as String? ?? 'escpos',
      detected: json['detected'] as String?,
      fallbacks: [for (final f in json['fallbacks'] as List? ?? const []) f as String],
    );
  }

  final String? id;
  final List<String> stations;
  final String address;
  final String dialect;
  final String? detected;
  final List<String> fallbacks;

  /// The first station it prints for; empty when it has none yet.
  String get station => stations.isEmpty ? '' : stations.first;

  Map<String, dynamic> toJson() => {
    'id': id,
    'station': station,
    'stations': stations,
    'address': address,
    'dialect': dialect,
    'detected': detected,
    'fallbacks': fallbacks,
  };

  @override
  bool operator ==(Object other) =>
      other is PrinterConfig &&
      other.id == id &&
      listEquals(other.stations, stations) &&
      other.address == address &&
      other.dialect == dialect &&
      other.detected == detected &&
      listEquals(other.fallbacks, fallbacks);

  @override
  int get hashCode => Object.hash(id, Object.hashAll(stations), address, dialect, detected, Object.hashAll(fallbacks));
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
/// which language it spoke (null when it could not be told), the model and maker it gave, and whether it is
/// a receipt printer at all ([kind] `other`: it has a name and speaks neither language, an office printer).
@immutable
class FoundPrinter {
  const FoundPrinter({
    required this.address,
    this.reachable = true,
    this.dialect,
    this.model,
    this.maker,
    this.kind,
    this.guessed = false,
  });

  factory FoundPrinter.fromJson(Map<String, dynamic> json) => FoundPrinter(
    address: json['address'] as String? ?? '',
    reachable: json['reachable'] as bool? ?? true,
    dialect: json['dialect'] as String?,
    model: json['model'] as String?,
    maker: json['maker'] as String?,
    kind: json['kind'] as String?,
    guessed: json['guessed'] as bool? ?? false,
  );

  final String address;
  final bool reachable;
  final String? dialect;
  final String? model;
  final String? maker;
  final String? kind;

  /// The language comes from the printer's name, not from an answer on its port.
  final bool guessed;

  /// Tickets cannot be printed on it: it answers on the printer port and is something else.
  bool get other => kind == 'other';

  /// "EPSON TM-T88VII", "Canon MF644C"; empty when it gave no name.
  String get name => [maker, model].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  /// For a list to pick from: "10.27.1.14 · EPSON TM-T88VII", or the address alone when it gave no name.
  String get pick => name.isEmpty ? address : '$address · $name';

  /// One line about it: "EPSON TM-T88VII · ESC/POS", "Star (StarPRNT)", "Canon MF644C · not a receipt printer".
  String get line {
    if (!reachable) return 'does not answer';
    if (other) return '$name · not a receipt printer';
    var language = dialect == null ? 'language unknown: pick it' : dialectLabels[dialect] ?? dialect!;
    if (guessed) language = '$language, going by its name';
    return name.isEmpty ? language : '$name · $language';
  }
}

/// What a kitchen ticket says about the other tickets of the same send, as the hub keeps it
/// (`GET/PUT /settings/tickets`; a manager sets it under Location settings): [numbered] for "Ticket 2 of 3"
/// when more than one station is cooking, [alsoAt] for the other stations by name ("Also at: Wok 2, Sushi
/// Bar"). And [paid]: whether the takeout station's ticket of a to-go order says PAID, or NOT PAID with what
/// is still to collect; null from a hub that does not print it yet, which gets no word about it back. And
/// [moved]: whether the stations cooking for a table get a MOVED slip when it changes tables; null the same
/// way from a hub that does not move tables yet.
@immutable
class TicketWords {
  const TicketWords({this.numbered = true, this.alsoAt = true, this.paid, this.moved});

  factory TicketWords.fromJson(Map<String, dynamic> json) => TicketWords(
    numbered: json['numbered'] as bool? ?? true,
    alsoAt: json['also_at'] as bool? ?? true,
    paid: json['paid'] as bool?,
    moved: json['moved'] as bool?,
  );

  final bool numbered;
  final bool alsoAt;
  final bool? paid;
  final bool? moved;

  Map<String, dynamic> toJson() => {'numbered': numbered, 'also_at': alsoAt, 'paid': ?paid, 'moved': ?moved};

  TicketWords copyWith({bool? numbered, bool? alsoAt, bool? paid, bool? moved}) => TicketWords(
    numbered: numbered ?? this.numbered,
    alsoAt: alsoAt ?? this.alsoAt,
    paid: paid ?? this.paid,
    moved: moved ?? this.moved,
  );

  @override
  bool operator ==(Object other) =>
      other is TicketWords &&
      other.numbered == numbered &&
      other.alsoAt == alsoAt &&
      other.paid == paid &&
      other.moved == moved;

  @override
  int get hashCode => Object.hash(numbered, alsoAt, paid, moved);
}

/// A printer as the bill's settings name it: its id and the name that heads its tickets ("Takeout").
@immutable
class BillPrinter {
  const BillPrinter({required this.id, required this.name});

  factory BillPrinter.fromJson(Map<String, dynamic> json) =>
      BillPrinter(id: json['id'] as String, name: json['name'] as String? ?? json['id'] as String);

  final String id;
  final String name;
}

/// The guest's bill as the location has it (`GET/PUT /settings/bill`): [printer], the id of the printer the
/// location's bills print at (null for the usual one: the takeout station's printer, else the first), and
/// the lines at its top ([header]: the restaurant's name, address and phone; the first prints big) and at
/// its foot ([footer]). With them, from the hub: every printer by name ([printers]), the one a bill comes
/// out of when a screen asks for none ([printsAt]) and the one it would be if the location named none
/// ([usual]). A screen may keep a printer of its own for its bills (`Settings.billPrinter`).
@immutable
class BillSettings {
  const BillSettings({
    this.printer,
    this.header = const [],
    this.footer = const [],
    this.printers = const [],
    this.printsAt,
    this.usual,
  });

  factory BillSettings.fromJson(Map<String, dynamic> json) => BillSettings(
    printer: json['printer'] as String?,
    header: [for (final line in json['header'] as List? ?? const []) line as String],
    footer: [for (final line in json['footer'] as List? ?? const []) line as String],
    printers: [
      for (final p in json['printers'] as List? ?? const []) BillPrinter.fromJson((p as Map).cast<String, dynamic>()),
    ],
    printsAt: json['prints_at'] as String?,
    usual: json['usual'] as String?,
  );

  final String? printer;
  final List<String> header;
  final List<String> footer;
  final List<BillPrinter> printers;
  final String? printsAt;
  final String? usual;

  /// The printer's name as its tickets are headed; null for an id that is no printer (any more).
  String? nameOf(String? id) => printers.where((p) => p.id == id).firstOrNull?.name;

  /// The location's own printer for bills, when it names one that is still there.
  String? get chosen => nameOf(printer) == null ? null : printer;
}
