/// How long the kitchen takes over a span of days, as the hub reckons it from what the kitchen screens
/// marked (`GET /reports/kitchen`, docs/kitchen-times.md). A ticket is one station's dishes of one send of an
/// order, timed from when they were in the kitchen until the station marked the last of them made; a send
/// went out when its last dish did. The hub does every sum; this is its answer read into names. Times stay
/// the hub's milliseconds, and only [tookWords] turns one into minutes for a person.
library;

import 'sales_report.dart' show Change, minutesWords;

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
int? _maybe(Object? value) => value is num ? value.toInt() : null;
Map<String, dynamic> _map(Object? value) => value is Map ? value.cast<String, dynamic>() : const {};
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// How long something took, for a person: whole minutes ("12 min", "1 h 5 min"), "under 1 min" for less
/// than half of one, and a dash for nothing timed.
String tookWords(int? ms) {
  if (ms == null) return '–';
  final minutes = (ms / 60000).round();
  return minutes == 0 ? 'under 1 min' : minutesWords(minutes);
}

/// How a time stands against the one before, in the minutes [tookWords] shows: "2 min quicker" (up: less
/// time is the better figure), "3 min slower", "the same", or "nothing before". Empty where there is no
/// time now.
Change tookChange(int? now, int? before) {
  if (now == null) return (words: '', up: null);
  if (before == null) return (words: 'nothing before', up: null);
  final apart = (now / 60000).round() - (before / 60000).round();
  if (apart == 0) return (words: 'the same', up: null);
  return (words: '${minutesWords(apart.abs())} ${apart < 0 ? 'quicker' : 'slower'}', up: apart < 0);
}

/// The times of some tickets: how many were timed, their average, the middle one and the longest; how many
/// took the location's red minutes or more; and how many were sent and not marked through.
class Took {
  const Took({this.tickets = 0, this.avgMs, this.medianMs, this.longestMs, this.late = 0, this.open = 0});

  factory Took.fromJson(Map<String, dynamic> json) => Took(
    tickets: _i(json['tickets'] ?? json['count']),
    avgMs: _maybe(json['avg_ms']),
    medianMs: _maybe(json['median_ms']),
    longestMs: _maybe(json['longest_ms']),
    late: _i(json['late']),
    open: _i(json['open']),
  );

  final int tickets;
  final int? avgMs;

  /// Half of them took this long or less.
  final int? medianMs;
  final int? longestMs;
  final int late;

  /// Sent and not marked through: in none of the times.
  final int open;
}

/// One station's tickets, or the ones of an hour or a day, or one dish.
class TookRow {
  const TookRow({this.code = '', this.name = '', this.hour, this.day, this.took = const Took()});

  factory TookRow.fromJson(Map<String, dynamic> json) => TookRow(
    code: _s(json['code']),
    name: _s(json['name']),
    hour: _maybe(json['hour']),
    day: DateTime.tryParse(_s(json['day'])),
    took: Took.fromJson(json),
  );

  /// A station's code; empty for any other row.
  final String code;

  /// The station or the dish.
  final String name;

  /// The hour of the day the tickets were sent in.
  final int? hour;
  final DateTime? day;
  final Took took;
}

/// One of the longest tickets: whose it was, at which station, when it was sent and how long it took.
class SlowTicket {
  const SlowTicket({
    required this.orderId,
    this.table = '',
    this.tab = '',
    this.orderNo,
    this.customer = '',
    this.toGo = false,
    this.station = '',
    this.sentMs = 0,
    this.tookMs = 0,
  });

  factory SlowTicket.fromJson(Map<String, dynamic> json) => SlowTicket(
    orderId: _s(json['order_id']),
    table: _s(json['table']),
    tab: _s(json['tab']),
    orderNo: _maybe(json['order_no']),
    customer: _s(json['customer']),
    toGo: json['to_go'] == true,
    station: _s(json['station_name'], _s(json['station'])),
    sentMs: _i(json['sent_ms']),
    tookMs: _i(json['took_ms']),
  );

  final String orderId;
  final String table;
  final String tab;
  final int? orderNo;
  final String customer;
  final bool toGo;

  /// The station by its name.
  final String station;
  final int sentMs;
  final int tookMs;

  /// Whose it was, as the head of its ticket said it: "Table 12", "Tab Mike", "#14 Linda".
  String get title {
    if (toGo) {
      final name = [if (orderNo != null) '#$orderNo', if (customer.isNotEmpty) customer].join(' ');
      return name.isEmpty ? 'To go' : name;
    }
    if (tab.isNotEmpty) return 'Tab $tab';
    return table.isEmpty ? 'No table' : 'Table $table';
  }
}

/// The kitchen's times of one span of days. The days held beside it carry only [made] and [out].
class KitchenTimesSpan {
  const KitchenTimesSpan({
    required this.first,
    required this.last,
    this.running = false,
    this.made = const Took(),
    this.out = const Took(),
    this.stations = const [],
    this.silent = const [],
    this.hours = const [],
    this.days = const [],
    this.dishes = const [],
    this.slowest = const [],
  });

  factory KitchenTimesSpan.fromJson(Map<String, dynamic> json) => KitchenTimesSpan(
    first: DateTime.tryParse(_s(json['first'])) ?? DateTime(2000),
    last: DateTime.tryParse(_s(json['last'])) ?? DateTime(2000),
    running: json['running'] == true,
    made: Took.fromJson(_map(json['made'])),
    out: Took.fromJson(_map(json['out'])),
    stations: [for (final row in _rows(json['stations'])) TookRow.fromJson(row)],
    silent: [for (final row in _rows(json['silent'])) TookRow.fromJson(row)],
    hours: [for (final row in _rows(json['hours'])) TookRow.fromJson(row)],
    days: [for (final row in _rows(json['days'])) TookRow.fromJson(row)],
    dishes: [for (final row in _rows(json['dishes'])) TookRow.fromJson(row)],
    slowest: [for (final row in _rows(json['slowest'])) SlowTicket.fromJson(row)],
  );

  final DateTime first;
  final DateTime last;

  /// Its last day is still going on.
  final bool running;

  /// The tickets of every station that marks, together.
  final Took made;

  /// The sends that went out, each timed until its last dish did.
  final Took out;

  /// Each station that marked a ticket through, the most tickets first.
  final List<TookRow> stations;

  /// The stations that were sent tickets and marked none through: in no figure, each with how many.
  final List<TookRow> silent;

  /// By the hour the tickets were sent in, in the order of a night.
  final List<TookRow> hours;
  final List<TookRow> days;

  /// The dishes, the slowest first, each timed until the last station that cooks it made it.
  final List<TookRow> dishes;
  final List<SlowTicket> slowest;

  /// Nothing at all was timed: a kitchen that works off paper, or days nobody cooked.
  bool get timedNothing => made.tickets == 0 && out.tickets == 0;
}

class KitchenTimes {
  const KitchenTimes({required this.span, required this.before, this.lateMin = 0, this.maxDays = 92, this.nowMs = 0});

  factory KitchenTimes.fromJson(Map<String, dynamic> json) => KitchenTimes(
    span: KitchenTimesSpan.fromJson(_map(json['span'])),
    before: KitchenTimesSpan.fromJson(_map(json['before'])),
    lateMin: _i(json['late_min']),
    maxDays: json['max_days'] is num ? _i(json['max_days']) : 92,
    nowMs: _i(json['now_ms']),
  );

  final KitchenTimesSpan span;

  /// The same days whole weeks earlier.
  final KitchenTimesSpan before;

  /// The minutes from which a ticket counts as late: the ones it turns red at on the screens. 0: none do.
  final int lateMin;
  final int maxDays;
  final int nowMs;
}
