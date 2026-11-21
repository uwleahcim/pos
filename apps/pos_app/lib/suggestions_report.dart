/// Suggestions taken over a span of days as the hub reckons them (`GET /reports/suggestions`,
/// docs/goes-with.md): the dishes added from the tray "Goes with ..." on the order screen, under the dish
/// each went with, and who rang them in. The hub does every sum and puts every list in its order; this is
/// its answer read into names, and the words the screen says. Amounts stay the hub's own words ("19.50").
library;

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// "1,204"
String manyWords(int n) {
  final digits = '$n';
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return grouped.toString();
}

/// One dish that was suggested with another: how many were added from the tray, and for how much.
class SuggestionAdded {
  const SuggestionAdded({required this.item, required this.name, this.taken = 0, this.amount = '0.00'});

  factory SuggestionAdded.fromJson(Map<String, dynamic> json) => SuggestionAdded(
    item: _s(json['item']),
    name: _s(json['name']),
    taken: _i(json['taken']),
    amount: _s(json['amount'], '0.00'),
  );

  final String item;
  final String name;

  /// None: the menu suggests it with that dish today, and nobody took it in these days.
  final int taken;
  final String amount;
}

/// A dish that suggests others: how many of it went out, and what was added with it.
class SuggestingDish {
  const SuggestingDish({
    required this.item,
    required this.name,
    this.sold = 0,
    this.taken = 0,
    this.amount = '0.00',
    this.added = const [],
  });

  factory SuggestingDish.fromJson(Map<String, dynamic> json) => SuggestingDish(
    item: _s(json['item']),
    name: _s(json['name']),
    sold: _i(json['sold']),
    taken: _i(json['taken']),
    amount: _s(json['amount'], '0.00'),
    added: [for (final row in _rows(json['added'])) SuggestionAdded.fromJson(row)],
  );

  final String item;
  final String name;

  /// How many of the dish itself were sold in the days, with or without anything.
  final int sold;

  /// How many suggested dishes were added with it, and what they came to.
  final int taken;
  final String amount;

  /// Each dish added with it, the most first, then what it suggests today that nobody took.
  final List<SuggestionAdded> added;

  /// "31 sold · 12 added with it", "14 sold · nothing added with it"
  String get words => [
    '${manyWords(sold)} sold',
    taken == 0 ? 'nothing added with it' : '${manyWords(taken)} added with it',
  ].join(' · ');
}

/// Somebody who rang suggested dishes in.
class SuggestionStaff {
  const SuggestionStaff({this.staffId, this.name = '', this.taken = 0, this.amount = '0.00'});

  factory SuggestionStaff.fromJson(Map<String, dynamic> json) => SuggestionStaff(
    staffId: json['staff_id'] is String ? json['staff_id'] as String : null,
    name: _s(json['name']),
    taken: _i(json['taken']),
    amount: _s(json['amount'], '0.00'),
  );

  final String? staffId;
  final String name;
  final int taken;
  final String amount;

  /// A dish rung by a screen that named nobody still counts, under these words.
  String get called => name.trim().isEmpty ? 'Nobody named' : name.trim();
}

class SuggestionsReport {
  const SuggestionsReport({
    required this.first,
    required this.last,
    this.running = false,
    this.taken = 0,
    this.amount = '0.00',
    this.dishes = const [],
    this.staff = const [],
    this.maxDays = 92,
    this.nowMs = 0,
  });

  factory SuggestionsReport.fromJson(Map<String, dynamic> json) => SuggestionsReport(
    first: DateTime.tryParse(_s(json['from'])) ?? DateTime(2000),
    last: DateTime.tryParse(_s(json['to'])) ?? DateTime(2000),
    running: json['running'] == true,
    taken: _i(json['taken']),
    amount: _s(json['amount'], '0.00'),
    dishes: [for (final row in _rows(json['dishes'])) SuggestingDish.fromJson(row)],
    staff: [for (final row in _rows(json['staff'])) SuggestionStaff.fromJson(row)],
    maxDays: json['max_days'] is num ? (json['max_days'] as num).toInt() : 92,
    nowMs: _i(json['now_ms']),
  );

  final DateTime first;
  final DateTime last;

  /// One of the days is not over: the figures will still move.
  final bool running;

  /// How many suggested dishes were added in the days, and what they came to at their price.
  final int taken;
  final String amount;

  /// The dishes that suggest others, the one that brought the most first; one that went out with nothing
  /// added is among them, after the others.
  final List<SuggestingDish> dishes;

  /// Who rang the suggested dishes in, the most first.
  final List<SuggestionStaff> staff;
  final int maxDays;
  final int nowMs;

  /// The dishes something was added with, and the ones that went out with nothing.
  List<SuggestingDish> get took => [
    for (final dish in dishes)
      if (dish.taken > 0) dish,
  ];
  List<SuggestingDish> get tookNothing => [
    for (final dish in dishes)
      if (dish.taken == 0) dish,
  ];
}
