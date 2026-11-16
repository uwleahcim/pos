import 'day_report.dart' show DayRow, TaxExempts, dayName, serviceDay;

/// Sales over a span of days as the hub reckons them (`GET /reports/sales`, docs/sales-report.md): the days
/// asked for, and the same figures for as many days whole weeks earlier to hold beside them. The hub does
/// every sum; this is its answer read into names. Amounts stay the hub's own words ("58.60") so that nothing
/// is rounded twice; only [changeWords] works anything out, and only to say how far two figures are apart.

String _s(Object? value, [String or = '']) => value is String ? value : or;
String? _maybe(Object? value) => value is String && value.isNotEmpty ? value : null;
int _i(Object? value) => value is num ? value.toInt() : 0;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// How many days [first] to [last] are, counted on the calendar, so a night the clocks change is still one
/// day.
int calendarDays(DateTime first, DateTime last) =>
    DateTime.utc(last.year, last.month, last.day).difference(DateTime.utc(first.year, first.month, first.day)).inDays +
    1;

/// One day of a span.
class SalesDay {
  const SalesDay({required this.day, this.checks = 0, this.guests = 0, this.gross = '0.00', this.net = '0.00'});

  factory SalesDay.fromJson(Map<String, dynamic> json) => SalesDay(
    day: DateTime.tryParse(_s(json['day'])) ?? DateTime(2000),
    checks: _i(json['checks']),
    guests: _i(json['guests']),
    gross: _s(json['gross'], '0.00'),
    net: _s(json['net'], '0.00'),
  );

  final DateTime day;
  final int checks;
  final int guests;
  final String gross;

  /// The dishes sold that day less comps and discounts: what the days of a span are compared by.
  final String net;
}

/// The time clock's part of a span, where the location uses it.
class SalesClock {
  const SalesClock({this.workedMs = 0, this.people = 0, this.unended = 0, this.netPerHour});

  factory SalesClock.fromJson(Map<String, dynamic> json) => SalesClock(
    workedMs: _i(json['worked_ms']),
    people: _i(json['people']),
    unended: _i(json['unended']),
    netPerHour: _maybe(json['net_per_hour']),
  );

  final int workedMs;
  final int people;

  /// Shifts nobody clocked out of: their hours run to 4 AM until a manager corrects them.
  final int unended;

  /// Net sales for each hour worked; null when nobody worked an hour.
  final String? netPerHour;
}

/// The sales of one span of days.
class SalesSpan {
  const SalesSpan({
    required this.first,
    required this.last,
    this.running = false,
    this.checks = 0,
    this.guests = 0,
    this.gross = '0.00',
    this.discountTotal = '0.00',
    this.net = '0.00',
    this.charges = '0.00',
    this.gratuity = '0.00',
    this.tax = '0.00',
    this.total = '0.00',
    this.exempt = const TaxExempts(),
    this.perCheck,
    this.perGuest,
    this.turnTables = 0,
    this.turnMinutes,
    this.days = const [],
    this.hours = const [],
    this.menus = const [],
    this.categories = const [],
    this.kinds = const [],
    this.discounts = const [],
    this.taken = const [],
    this.takenTotal = '0.00',
    this.clock,
  });

  factory SalesSpan.fromJson(Map<String, dynamic> json) {
    final sales = (json['sales'] as Map?)?.cast<String, dynamic>() ?? const {};
    final money = (json['money'] as Map?)?.cast<String, dynamic>() ?? const {};
    final turn = (json['turn'] as Map?)?.cast<String, dynamic>() ?? const {};
    String of(Map<String, dynamic> from, String key) => _s(from[key], '0.00');
    return SalesSpan(
      first: DateTime.tryParse(_s(json['first'])) ?? DateTime(2000),
      last: DateTime.tryParse(_s(json['last'])) ?? DateTime(2000),
      running: json['running'] == true,
      checks: _i(json['checks']),
      guests: _i(json['guests']),
      gross: of(sales, 'gross'),
      discountTotal: of(sales, 'discounts'),
      net: of(sales, 'net'),
      charges: of(sales, 'charges'),
      gratuity: of(sales, 'gratuity'),
      tax: of(sales, 'tax'),
      total: of(sales, 'total'),
      exempt: TaxExempts.fromJson(json['tax_exempt']),
      perCheck: _maybe(json['per_check']),
      perGuest: _maybe(json['per_guest']),
      turnTables: _i(turn['tables']),
      turnMinutes: turn['minutes'] is num ? (turn['minutes'] as num).toInt() : null,
      days: [for (final row in _rows(json['days'])) SalesDay.fromJson(row)],
      hours: [for (final row in _rows(json['hours'])) DayRow.fromJson(row)],
      menus: [for (final row in _rows(json['menus'])) DayRow.fromJson(row)],
      categories: [for (final row in _rows(json['categories'])) DayRow.fromJson(row)],
      kinds: [for (final row in _rows(json['kinds'])) DayRow.fromJson(row, name: 'kind')],
      discounts: [for (final row in _rows(json['discounts'])) DayRow.fromJson(row)],
      taken: [for (final row in _rows(money['taken'])) DayRow.fromJson(row, name: 'method')],
      takenTotal: of(money, 'taken_total'),
      clock: json['clock'] is Map ? SalesClock.fromJson((json['clock'] as Map).cast<String, dynamic>()) : null,
    );
  }

  /// The first and the last day of service, as calendar days (a day runs from 4 AM to 4 AM the next).
  final DateTime first;
  final DateTime last;

  /// The day that is running is one of them: its figures will still move.
  final bool running;
  final int checks;
  final int guests;

  /// Every dish on the span's checks at the price it was sold at; every split below adds up to it.
  final String gross;
  final String discountTotal;
  final String net;
  final String charges;
  final String gratuity;
  final String tax;

  /// What the span's checks come to: net + charges + gratuity + tax.
  final String total;

  /// The checks a manager marked tax exempt: in every figure above, with [tax] the tax that was charged.
  final TaxExempts exempt;

  /// Net sales over the checks; null for a span with no check.
  final String? perCheck;

  /// The net of the checks that say how many guests they were, over those guests.
  final String? perGuest;

  /// How long a table's check stood, opened to closed: how many closed table checks, and the middle one of
  /// their times in minutes (null with none).
  final int turnTables;
  final int? turnMinutes;
  final List<SalesDay> days;
  final List<DayRow> hours;
  final List<DayRow> menus;
  final List<DayRow> categories;
  final List<DayRow> kinds;
  final List<DayRow> discounts;

  /// Every payment recorded in the span, by how it was paid, whatever check it was for.
  final List<DayRow> taken;
  final String takenTotal;
  final SalesClock? clock;

  /// How many days it is.
  int get dayCount => calendarDays(first, last);

  /// The categories of one menu, in the hub's order (the most sold first).
  List<DayRow> categoriesOf(String menu) => [
    for (final row in categories)
      if (row.group == menu) row,
  ];
}

class SalesReport {
  const SalesReport({required this.span, required this.before, this.maxDays = 92, this.nowMs = 0});

  factory SalesReport.fromJson(Map<String, dynamic> json) => SalesReport(
    span: SalesSpan.fromJson((json['span'] as Map?)?.cast<String, dynamic>() ?? const {}),
    before: SalesSpan.fromJson((json['before'] as Map?)?.cast<String, dynamic>() ?? const {}),
    maxDays: json['max_days'] is num ? (json['max_days'] as num).toInt() : 92,
    nowMs: _i(json['now_ms']),
  );

  final SalesSpan span;

  /// As many days, whole weeks earlier: a Friday stands beside a Friday.
  final SalesSpan before;

  /// The longest span the hub adds up at once.
  final int maxDays;
  final int nowMs;

  /// How many weeks back [before] lies.
  int get weeksBack => (span.dayCount + 6) ~/ 7;
}

/// How a figure stands against the one before: [words] ("up 12.4%", "down 3%", "the same", "nothing
/// before"), and [up] true, false, or null when it is neither or cannot be said.
typedef Change = ({String words, bool? up});

/// How far [now] is from [before], for a person. Empty words when neither is anything.
Change changeWords(num now, num before) {
  if (now == 0 && before == 0) return (words: '', up: null);
  if (before == 0) return (words: 'nothing before', up: null);
  if (now == before) return (words: 'the same', up: null);
  final percent = (now - before) / before * 100;
  final size = percent.abs();
  final said = size >= 99.95
      ? size.toStringAsFixed(0)
      : size < 0.05
      ? 'under 0.1'
      : size.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return (words: '${percent > 0 ? 'up' : 'down'} $said%', up: percent > 0);
}

/// Minutes as a person says a table's time: "45 min", "1 h 5 min".
String minutesWords(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The spans the screen offers by name. Each is whole days of service, named as the hub names them.
enum SalesChoice { today, yesterday, week, fourWeeks, other }

/// The first and last day of [choice] as the hub names them, for a device whose clock reads [now]. Today
/// is (null, null): the hub knows best which day of service is running. "7 days" and "4 weeks" are the
/// whole days just gone (they end yesterday), so that a day half over is not held beside whole ones.
(String?, String?) spanOf(SalesChoice choice, DateTime now, {DateTime? first, DateTime? last}) {
  final today = DateTime.parse(serviceDay(now));
  String back(int days) => dayName(DateTime(today.year, today.month, today.day - days));
  return switch (choice) {
    SalesChoice.today => (null, null),
    SalesChoice.yesterday => (back(1), back(1)),
    SalesChoice.week => (back(7), back(1)),
    SalesChoice.fourWeeks => (back(28), back(1)),
    SalesChoice.other => (dayName(first ?? today), dayName(last ?? first ?? today)),
  };
}
