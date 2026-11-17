/// The waste log as the hub tells it (docs/waste-log.md): food that was made or bought and not sold. The
/// kitchen writes down what it was, how many and why; a manager reads the totals. It stands beside the
/// sales and is never part of them: nothing here is a check, a void or a comp.
library;

/// What a set of entries comes to: how many things, what they would have sold for at the menu's prices,
/// and how many of them have no price to add (something typed, a dish priced when it is rung).
class WasteTotal {
  const WasteTotal({this.entries = 0, this.count = 0, this.value = '0.00', this.unpriced = 0});

  factory WasteTotal.fromJson(Map<String, dynamic>? json) => WasteTotal(
    entries: json?['entries'] as int? ?? 0,
    count: json?['count'] as int? ?? 0,
    value: json?['value'] as String? ?? '0.00',
    unpriced: json?['unpriced'] as int? ?? 0,
  );

  final int entries;
  final int count;
  final String value;
  final int unpriced;
}

/// One entry of the log.
class WasteEntry {
  const WasteEntry({
    required this.id,
    required this.atMs,
    required this.name,
    required this.qty,
    required this.reason,
    this.value,
    this.note = '',
    this.byId = '',
    this.by = '',
    this.struckMs,
    this.struckBy = '',
  });

  factory WasteEntry.fromJson(Map<String, dynamic> json) => WasteEntry(
    id: json['id'] as String,
    atMs: json['at_ms'] as int? ?? 0,
    name: json['name'] as String? ?? '',
    qty: json['qty'] as int? ?? 1,
    reason: json['reason'] as String? ?? '',
    value: json['value'] as String?,
    note: json['note'] as String? ?? '',
    byId: json['by_id'] as String? ?? '',
    by: json['by'] as String? ?? '',
    struckMs: json['struck_ms'] as int?,
    struckBy: json['struck_by'] as String? ?? '',
  );

  final String id;
  final int atMs;

  /// The dish as the menu named it then, or what was typed.
  final String name;
  final int qty;
  final String reason;

  /// What these would have sold for at the menu's price; null for something typed.
  final String? value;
  final String note;
  final String byId;
  final String by;

  /// When it was struck out; it stays readable and counts in no total.
  final int? struckMs;
  final String struckBy;

  bool get struck => struckMs != null;
}

/// One day of service: its entries, the newest first, what stands of them added up, and what a screen
/// needs to write the next one.
class WasteDay {
  const WasteDay({
    required this.day,
    this.today = true,
    this.entries = const [],
    this.total = const WasteTotal(),
    this.reasons = const [],
    this.nameMax = 60,
    this.noteMax = 120,
    this.qtyMax = 999,
  });

  factory WasteDay.fromJson(Map<String, dynamic> json) {
    final limits = json['limits'] as Map<String, dynamic>? ?? const {};
    return WasteDay(
      day: json['day'] as String? ?? '',
      today: json['today'] as bool? ?? true,
      entries: [for (final e in json['entries'] as List? ?? const []) WasteEntry.fromJson(e as Map<String, dynamic>)],
      total: WasteTotal.fromJson(json['total'] as Map<String, dynamic>?),
      reasons: List<String>.from(json['reasons'] as List? ?? const []),
      nameMax: limits['name'] as int? ?? 60,
      noteMax: limits['note'] as int? ?? 120,
      qtyMax: limits['qty'] as int? ?? 999,
    );
  }

  final String day;
  final bool today;
  final List<WasteEntry> entries;
  final WasteTotal total;

  /// The location's reasons, in the order the buttons show.
  final List<String> reasons;
  final int nameMax;
  final int noteMax;
  final int qtyMax;
}

/// One line of a report: a day, a reason or a dish, with how many and what they would have sold for.
class WasteRow {
  const WasteRow({required this.name, this.total = const WasteTotal(), this.typed = false});

  factory WasteRow.fromJson(Map<String, dynamic> json, {String key = 'name'}) => WasteRow(
    name: json[key] as String? ?? '',
    total: WasteTotal.fromJson(json),
    typed: json['typed'] as bool? ?? false,
  );

  /// The reason's words, the dish's name, or the day ("2026-11-16").
  final String name;
  final WasteTotal total;

  /// Something typed, not a dish of the menu: it has no price.
  final bool typed;
}

/// A span of days added up.
class WasteReport {
  const WasteReport({
    required this.from,
    required this.to,
    this.total = const WasteTotal(),
    this.struck = 0,
    this.days = const [],
    this.reasons = const [],
    this.dishes = const [],
    this.maxDays = 92,
    this.nowMs = 0,
  });

  factory WasteReport.fromJson(Map<String, dynamic> json) {
    List<WasteRow> rows(String part, {String key = 'name'}) => [
      for (final row in json[part] as List? ?? const []) WasteRow.fromJson(row as Map<String, dynamic>, key: key),
    ];
    return WasteReport(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      total: WasteTotal.fromJson(json['total'] as Map<String, dynamic>?),
      struck: json['struck'] as int? ?? 0,
      days: rows('days', key: 'day'),
      reasons: rows('reasons'),
      dishes: rows('dishes'),
      maxDays: json['max_days'] as int? ?? 92,
      nowMs: json['now_ms'] as int? ?? 0,
    );
  }

  final String from;
  final String to;
  final WasteTotal total;

  /// Entries of these days that were struck out: they count nowhere.
  final int struck;
  final List<WasteRow> days;
  final List<WasteRow> reasons;
  final List<WasteRow> dishes;
  final int maxDays;
  final int nowMs;
}

/// The location's reasons for the waste log, and how long the list and a reason may be.
class WasteReasons {
  const WasteReasons(this.reasons, {this.most = 12, this.reasonMax = 24});

  factory WasteReasons.fromJson(Map<String, dynamic> json) {
    final limits = json['limits'] as Map<String, dynamic>? ?? const {};
    return WasteReasons(
      List<String>.from(json['reasons'] as List? ?? const []),
      most: limits['reasons'] as int? ?? 12,
      reasonMax: limits['reason'] as int? ?? 24,
    );
  }

  final List<String> reasons;
  final int most;
  final int reasonMax;
}

/// "9 wasted · $31.90 at menu prices", and how many of them have no price where some have none.
String wasteSummary(WasteTotal total) {
  if (total.count == 0) return 'Nothing wasted';
  final priced = total.count - total.unpriced;
  final parts = ['${total.count} wasted'];
  if (priced > 0) parts.add('\$${total.value} at menu prices');
  if (total.unpriced > 0) parts.add(priced > 0 ? '${total.unpriced} with no price' : 'no price');
  return parts.join(' · ');
}
