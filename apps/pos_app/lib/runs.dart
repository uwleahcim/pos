/// A driver's runs (docs/delivery.md, "Runs"): what each driver took out over a day of service, as the hub
/// reads it off the orders' own logs (`GET /deliveries/runs`). A run is the bags a driver left with in one
/// go. Nothing here is worked out on the terminal but the words, and no money is in any of it.
library;

import 'api.dart';
import 'takeout.dart';

String _many(int count, String one, [String? many]) => '$count ${count == 1 ? one : many ?? '${one}s'}';

/// "15 min", "1 h 05": how long a bag or a run took.
String tookWords(int minutes) =>
    minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';

/// One bag of a run: the order, when it left, and what became of it.
class RunBag {
  const RunBag({
    required this.orderId,
    this.orderNo,
    this.customerName = '',
    this.address = '',
    required this.leftMs,
    this.outcome = 'out',
    this.atMs,
    this.minutes,
    this.to = '',
  });

  factory RunBag.fromJson(Map<String, dynamic> json) => RunBag(
    orderId: json['order_id'] as String? ?? '',
    orderNo: (json['order_no'] as num?)?.toInt(),
    customerName: json['customer_name'] as String? ?? '',
    address: json['address'] as String? ?? '',
    leftMs: (json['left_ms'] as num?)?.toInt() ?? 0,
    outcome: json['outcome'] as String? ?? 'out',
    atMs: (json['at_ms'] as num?)?.toInt(),
    minutes: (json['minutes'] as num?)?.toInt(),
    to: json['to'] as String? ?? '',
  );

  final String orderId;
  final int? orderNo;
  final String customerName;
  final String address;

  /// When it left with the driver, and when what became of it was marked (null while it is out), in ms.
  final int leftMs;
  final int? atMs;

  /// `delivered`, `back` (it came back to the restaurant), `handed` (another driver took it over: [to]),
  /// `void` (the order was voided on the way) or `out`.
  final String outcome;
  final int? minutes;
  final String to;

  bool get isOut => outcome == 'out';
  bool get isDelivered => outcome == 'delivered';

  /// "#12 Linda"
  String get title => ['#${orderNo ?? '…'}', if (customerName.trim().isNotEmpty) customerName.trim()].join(' ');

  /// What became of it: "delivered 18:55 · 15 min", "came back 18:50", "handed to Wei 18:50", "voided 18:45",
  /// "still out". The minutes are from leaving to the moment somebody marked it.
  String get words {
    final at = atMs;
    final when = at == null ? '' : ' ${clockTime(at)}';
    return switch (outcome) {
      'delivered' => ['delivered$when', if (minutes != null) tookWords(minutes!)].join(' · '),
      'back' => 'came back$when',
      'handed' => to.isEmpty ? 'handed on$when' : 'handed to $to$when',
      'void' => 'voided$when',
      _ => 'still out',
    };
  }
}

/// The bags a driver left with in one go.
class DriverRun {
  const DriverRun({required this.leftMs, this.endedMs, this.minutes, this.bags = const []});

  factory DriverRun.fromJson(Map<String, dynamic> json) => DriverRun(
    leftMs: (json['left_ms'] as num?)?.toInt() ?? 0,
    endedMs: (json['ended_ms'] as num?)?.toInt(),
    minutes: (json['minutes'] as num?)?.toInt(),
    bags: [for (final bag in json['bags'] as List? ?? const []) RunBag.fromJson((bag as Map).cast<String, dynamic>())],
  );

  /// When the first bag left, and when the last one was marked (null while one is out), in ms.
  final int leftMs;
  final int? endedMs;
  final int? minutes;
  final List<RunBag> bags;

  bool get isOut => endedMs == null;

  /// "left 18:40 · 2 bags · 25 min", "left 18:40 · 1 bag · out now"
  String get words => [
    'left ${clockTime(leftMs)}',
    _many(bags.length, 'bag'),
    if (isOut) 'out now' else if (minutes != null) tookWords(minutes!),
  ].join(' · ');
}

/// One driver's day: their runs in the order they left.
class DriverRuns {
  const DriverRuns({
    this.driverId = '',
    this.driver = '',
    this.runs = 0,
    this.delivered = 0,
    this.back = 0,
    this.out = 0,
    this.list = const [],
  });

  factory DriverRuns.fromJson(Map<String, dynamic> json) => DriverRuns(
    driverId: json['driver_id'] as String? ?? '',
    driver: json['driver'] as String? ?? '',
    runs: (json['runs'] as num?)?.toInt() ?? 0,
    delivered: (json['delivered'] as num?)?.toInt() ?? 0,
    back: (json['back'] as num?)?.toInt() ?? 0,
    out: (json['out'] as num?)?.toInt() ?? 0,
    list: [
      for (final run in json['list'] as List? ?? const []) DriverRun.fromJson((run as Map).cast<String, dynamic>()),
    ],
  );

  /// The driver's staff id, empty for one a screen named without an id.
  final String driverId;
  final String driver;
  final int runs;
  final int delivered;
  final int back;
  final int out;
  final List<DriverRun> list;

  /// "3 runs · 7 delivered · 1 came back · 2 out": what came back and what is out only when there is any.
  String get summed => runsSummed(runs: runs, delivered: delivered, back: back, out: out);
}

/// "3 runs · 7 delivered · 1 came back · 2 out"
String runsSummed({required int runs, required int delivered, required int back, required int out}) =>
    [_many(runs, 'run'), '$delivered delivered', if (back > 0) '$back came back', if (out > 0) '$out out'].join(' · ');

/// The runs of one day of service.
class RunsReport {
  const RunsReport({
    required this.day,
    this.runs = 0,
    this.delivered = 0,
    this.back = 0,
    this.out = 0,
    this.noDriver = 0,
    this.drivers = const [],
  });

  factory RunsReport.fromJson(Map<String, dynamic> json) => RunsReport(
    day: json['day'] as String? ?? '',
    runs: (json['runs'] as num?)?.toInt() ?? 0,
    delivered: (json['delivered'] as num?)?.toInt() ?? 0,
    back: (json['back'] as num?)?.toInt() ?? 0,
    out: (json['out'] as num?)?.toInt() ?? 0,
    noDriver: (json['no_driver'] as num?)?.toInt() ?? 0,
    drivers: [
      for (final driver in json['drivers'] as List? ?? const [])
        DriverRuns.fromJson((driver as Map).cast<String, dynamic>()),
    ],
  );

  /// The day of service, `2026-11-16`.
  final String day;
  final int runs;
  final int delivered;
  final int back;
  final int out;

  /// The deliveries marked delivered that day with nobody having taken them out: they are in no run.
  final int noDriver;

  /// Whoever left first, first.
  final List<DriverRuns> drivers;

  /// "5 runs · 12 delivered · 1 came back · 2 out", over all the drivers.
  String get summed => runsSummed(runs: runs, delivered: delivered, back: back, out: out);

  /// What to say of the deliveries no driver was named for.
  String get noDriverWords => noDriver == 1
      ? '1 delivery was marked delivered with no driver named. It is in no run.'
      : '$noDriver deliveries were marked delivered with no driver named. They are in no run.';

  /// The drivers with [staffId]'s own runs first: a driver looks for theirs.
  List<DriverRuns> mineFirst(String? staffId) => [
    for (final driver in drivers)
      if (staffId != null && driver.driverId == staffId) driver,
    for (final driver in drivers)
      if (staffId == null || driver.driverId != staffId) driver,
  ];
}

DateTime? _dayOf(String day) {
  final parts = day.split('-').map(int.tryParse).toList();
  if (parts.length != 3 || parts.contains(null)) return null;
  return DateTime(parts[0]!, parts[1]!, parts[2]!);
}

/// The day [by] days after [day] (`2026-11-16`), before it for a negative [by]; [day] itself when it is no day.
String dayFrom(String day, int by) {
  final at = _dayOf(day);
  return at == null ? day : isoDay(DateTime(at.year, at.month, at.day + by));
}

/// What a day of runs is called beside [today], the day of service that is running: "Today", "Yesterday",
/// "Sat 14 Nov".
String runsDayWords(String day, String today) {
  if (day == today) return 'Today';
  if (day == dayFrom(today, -1)) return 'Yesterday';
  final at = _dayOf(day);
  return at == null ? day : dayName(at);
}
