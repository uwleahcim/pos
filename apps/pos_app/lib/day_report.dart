import 'voids.dart' show checkName;

/// The day's report as the hub reckons it (`GET /reports/day`, docs/day-report.md): what was sold on a day of
/// service, the money taken for it, what came off the checks and what is still open. The hub does every
/// sum; this is its answer read into names. Amounts stay the hub's own words ("58.60") so that nothing is
/// rounded twice; [dollars] writes one for a person.

/// "58.60" as "$58.60", "12345.5" as "$12,345.50", "-2.00" as "-$2.00".
String dollars(String amount) {
  final negative = amount.startsWith('-');
  final parts = (negative ? amount.substring(1) : amount).split('.');
  final whole = parts[0].isEmpty ? '0' : parts[0];
  final cents = (parts.length > 1 ? parts[1] : '').padRight(2, '0').substring(0, 2);
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '${negative ? '-' : ''}\$$grouped.$cents';
}

/// Whether an amount of the hub's is anything at all: "0.00" and "" are not.
bool isMoney(String amount) => (double.tryParse(amount) ?? 0) != 0;

/// How a payment was taken, as the report says it.
String methodLabel(String method) => switch (method) {
  'cash' => 'Cash',
  'card' => 'Card',
  'elsewhere' => 'Paid elsewhere',
  _ => method,
};

/// A kind of order, as the report says it.
String kindLabel(String kind) => switch (kind) {
  'dine_in' => 'Tables',
  'tab' => 'Bar tabs',
  'takeout' => 'To go',
  'delivery' => 'Delivery',
  _ => kind,
};

/// An hour of the day as a clock says it: 17 is "5 PM", 0 is "12 AM".
String hourLabel(int? hour) =>
    hour == null ? 'No time kept' : '${hour % 12 == 0 ? 12 : hour % 12} ${hour < 12 ? 'AM' : 'PM'}';

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// One line of a split of the sales: a name, how many, and what they came to.
class DayRow {
  const DayRow({required this.name, required this.amount, this.count = 0, this.group = '', this.guests = 0, this.hour});

  factory DayRow.fromJson(Map<String, dynamic> json, {String name = 'name', String group = 'menu'}) => DayRow(
    name: _s(json[name]),
    amount: _s(json['amount'], '0.00'),
    count: _i(json['count']),
    group: _s(json[group]),
    guests: _i(json['guests']),
    hour: json['hour'] is num ? (json['hour'] as num).toInt() : null,
  );

  final String name;
  final String amount;

  /// How many: dishes for a category or a person, checks for a kind of order, payments for a method.
  final int count;

  /// The menu a category belongs to (its code), so that categories can be listed under their menu.
  final String group;
  final int guests;
  final int? hour;
}

/// How many of something and what they were worth.
class DayCount {
  const DayCount({this.count = 0, this.amount = '0.00'});

  factory DayCount.fromJson(Object? json) =>
      json is Map ? DayCount(count: _i(json['count']), amount: _s(json['amount'], '0.00')) : const DayCount();

  final int count;
  final String amount;
}

/// A check the report points at: one still open, or closed without being paid in full.
class DayCheck {
  const DayCheck({
    required this.orderId,
    required this.total,
    required this.due,
    this.table,
    this.orderNo,
    this.customerName = '',
    this.server = '',
    this.orderType = 'dine_in',
    this.tab = false,
    this.status = 'open',
    this.unsent = 0,
    this.openedMs,
    this.day = '',
  });

  factory DayCheck.fromJson(Map<String, dynamic> json) => DayCheck(
    orderId: _s(json['order_id']),
    total: _s(json['total'], '0.00'),
    due: _s(json['due'], '0.00'),
    table: json['table']?.toString(),
    orderNo: json['order_no'] is num ? (json['order_no'] as num).toInt() : null,
    customerName: _s(json['customer_name']),
    server: _s(json['server']),
    orderType: _s(json['order_type'], 'dine_in'),
    tab: json['tab'] == true,
    status: _s(json['status'], 'open'),
    unsent: _i(json['unsent']),
    openedMs: json['opened_ms'] is num ? (json['opened_ms'] as num).toInt() : null,
    day: _s(json['day']),
  );

  final String orderId;
  final String total;
  final String due;
  final String? table;
  final int? orderNo;
  final String customerName;
  final String server;
  final String orderType;

  /// A bar tab that has not sat down: called by the name on it.
  final bool tab;
  final String status;

  /// Dishes on it the kitchen was never sent.
  final int unsent;
  final int? openedMs;

  /// For a check from an earlier day: that day, as the hub writes it ("2026-11-15").
  final String day;

  /// "Table 12", "#7 · Lee", "Tab · Linda", or what kind of order it is when it has none of these.
  String get where {
    final named = checkName(table, orderNo);
    final base = named.isNotEmpty
        ? named
        : tab
        ? 'Tab'
        : kindLabel(orderType);
    return customerName.isEmpty ? base : '$base · $customerName';
  }
}

/// The time clock's part of a day, where the location uses it.
class DayClock {
  const DayClock({this.workedMs = 0, this.people = 0, this.unended = 0, this.onNow = const []});

  factory DayClock.fromJson(Map<String, dynamic> json) => DayClock(
    workedMs: _i(json['worked_ms']),
    people: _i(json['people']),
    unended: _i(json['unended']),
    onNow: [for (final row in _rows(json['on_now'])) _s(row['name'])],
  );

  final int workedMs;
  final int people;

  /// Shifts nobody clocked out of: their hours run to 4 AM until a manager corrects them.
  final int unended;

  /// Who is on the clock at this moment (only for the day that is running).
  final List<String> onNow;
}

class DayReport {
  const DayReport({
    required this.day,
    required this.today,
    this.nowMs = 0,
    this.checks = 0,
    this.guests = 0,
    this.gross = '0.00',
    this.discountTotal = '0.00',
    this.net = '0.00',
    this.charges = '0.00',
    this.gratuity = '0.00',
    this.tax = '0.00',
    this.total = '0.00',
    this.menus = const [],
    this.categories = const [],
    this.kinds = const [],
    this.staff = const [],
    this.hours = const [],
    this.discounts = const [],
    this.voids = const DayCount(),
    this.takenOff = const DayCount(),
    this.typed = const DayCount(),
    this.voidedChecks = const DayCount(),
    this.later = const DayCount(),
    this.taken = const [],
    this.takenTotal = '0.00',
    this.forOtherDays = '0.00',
    this.onVoided = '0.00',
    this.paidThisDay = '0.00',
    this.paidOtherDays = '0.00',
    this.due = '0.00',
    this.over = '0.00',
    this.open = const [],
    this.unpaid = const [],
    this.earlier = const [],
    this.unsent = 0,
    this.clock,
  });

  factory DayReport.fromJson(Map<String, dynamic> json) {
    final sales = (json['sales'] as Map?)?.cast<String, dynamic>() ?? const {};
    final money = (json['money'] as Map?)?.cast<String, dynamic>() ?? const {};
    String of(Map<String, dynamic> from, String key) => _s(from[key], '0.00');
    return DayReport(
      day: DateTime.tryParse(_s(json['day'])) ?? DateTime(2000),
      today: json['today'] == true,
      nowMs: _i(json['now_ms']),
      checks: _i(json['checks']),
      guests: _i(json['guests']),
      gross: of(sales, 'gross'),
      discountTotal: of(sales, 'discounts'),
      net: of(sales, 'net'),
      charges: of(sales, 'charges'),
      gratuity: of(sales, 'gratuity'),
      tax: of(sales, 'tax'),
      total: of(sales, 'total'),
      menus: [for (final row in _rows(json['menus'])) DayRow.fromJson(row)],
      categories: [for (final row in _rows(json['categories'])) DayRow.fromJson(row)],
      kinds: [for (final row in _rows(json['kinds'])) DayRow.fromJson(row, name: 'kind')],
      staff: [for (final row in _rows(json['staff'])) DayRow.fromJson(row)],
      hours: [for (final row in _rows(json['hours'])) DayRow.fromJson(row)],
      discounts: [for (final row in _rows(json['discounts'])) DayRow.fromJson(row)],
      voids: DayCount.fromJson(json['voids']),
      takenOff: DayCount.fromJson(json['taken_off']),
      typed: DayCount.fromJson(json['typed']),
      voidedChecks: DayCount.fromJson(json['voided_checks']),
      later: DayCount.fromJson(json['later']),
      taken: [for (final row in _rows(money['taken'])) DayRow.fromJson(row, name: 'method')],
      takenTotal: of(money, 'taken_total'),
      forOtherDays: of(money, 'for_other_days'),
      onVoided: of(money, 'on_voided'),
      paidThisDay: of(money, 'paid_this_day'),
      paidOtherDays: of(money, 'paid_other_days'),
      due: of(money, 'due'),
      over: of(money, 'over'),
      open: [for (final row in _rows(json['open'])) DayCheck.fromJson(row)],
      unpaid: [for (final row in _rows(json['unpaid'])) DayCheck.fromJson(row)],
      earlier: [for (final row in _rows(json['earlier'])) DayCheck.fromJson(row)],
      unsent: _i(json['unsent']),
      clock: json['clock'] is Map ? DayClock.fromJson((json['clock'] as Map).cast<String, dynamic>()) : null,
    );
  }

  /// The day of service, as a calendar day (its service runs from 4 AM to 4 AM the next morning).
  final DateTime day;

  /// The day is still running: the figures will move, and the list of what is open is about this moment.
  final bool today;
  final int nowMs;
  final int checks;
  final int guests;

  /// Every dish on the day's checks at the price it was sold at; every split below adds up to it.
  final String gross;
  final String discountTotal;
  final String net;
  final String charges;
  final String gratuity;
  final String tax;

  /// What the day's checks come to: net + charges + gratuity + tax.
  final String total;
  final List<DayRow> menus;
  final List<DayRow> categories;
  final List<DayRow> kinds;
  final List<DayRow> staff;
  final List<DayRow> hours;
  final List<DayRow> discounts;
  final DayCount voids;
  final DayCount takenOff;
  final DayCount typed;
  final DayCount voidedChecks;

  /// Orders rung during the day for a later one: not in this day's sales, in that day's.
  final DayCount later;

  /// Every payment recorded during the day, by how it was paid, whatever check it was for.
  final List<DayRow> taken;
  final String takenTotal;
  final String forOtherDays;
  final String onVoided;

  /// The day's own checks: total = paidThisDay + paidOtherDays + due - over.
  final String paidThisDay;
  final String paidOtherDays;
  final String due;
  final String over;
  final List<DayCheck> open;
  final List<DayCheck> unpaid;
  final List<DayCheck> earlier;

  /// Dishes on open checks the kitchen was never sent.
  final int unsent;
  final DayClock? clock;

  /// The categories of one menu, in the hub's order (the most sold first).
  List<DayRow> categoriesOf(String menu) => [
    for (final row in categories)
      if (row.group == menu) row,
  ];

  /// Nothing is left to look at before going home: no check open or owing, no dish unsent, nobody on the
  /// clock and no shift to correct.
  bool get allClosed =>
      open.isEmpty &&
      unpaid.isEmpty &&
      earlier.isEmpty &&
      unsent == 0 &&
      (clock == null || (clock!.onNow.isEmpty && clock!.unended == 0));
}

/// The day of service a moment on this device falls in, as the hub names it ("2026-11-16"): the calendar
/// day, or the one before for the small hours before the night ends at 4 AM.
String serviceDay(DateTime at) {
  final day = at.hour < 4 ? DateTime(at.year, at.month, at.day - 1) : at;
  return dayName(day);
}

/// A calendar day as the hub names one: "2026-11-16".
String dayName(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
