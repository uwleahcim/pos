/// The prep list (docs/catering.md): what a day's orders ahead need made, added up dish by dish for each
/// station that cooks them, as the hub reckons it (`GET /orders/ahead/prep`). The dishes stand in the
/// kitchen's own words, as its tickets have them. Nothing here is worked out on the terminal but the words.
library;

import 'takeout.dart';

String _many(int count, String one, [String? many]) => '$count ${count == 1 ? one : many ?? '${one}s'}';

/// How some of a dish are wanted, when not plain: their choices and the note on them.
class PrepWay {
  const PrepWay({required this.qty, this.choices = const [], this.note = ''});

  factory PrepWay.fromJson(Map<String, dynamic> json) => PrepWay(
    qty: (json['qty'] as num?)?.toInt() ?? 0,
    choices: [for (final choice in json['choices'] as List? ?? const []) choice.toString()],
    note: json['note'] as String? ?? '',
  );

  final int qty;
  final List<String> choices;
  final String note;

  /// "Extra spicy, Brown rice · no onions"
  String get words => [if (choices.isNotEmpty) choices.join(', '), if (note.isNotEmpty) note].join(' · ');
}

/// One dish a station makes for the day: how many over all the orders, and by when the first.
class PrepRow {
  const PrepRow({
    required this.label,
    this.header = '',
    required this.qty,
    required this.firstMs,
    this.ways = const [],
  });

  factory PrepRow.fromJson(Map<String, dynamic> json) => PrepRow(
    label: json['label'] as String? ?? '',
    header: json['header'] as String? ?? '',
    qty: (json['qty'] as num?)?.toInt() ?? 0,
    firstMs: (json['first_ms'] as num?)?.toInt() ?? 0,
    ways: [for (final way in json['ways'] as List? ?? const []) PrepWay.fromJson((way as Map).cast<String, dynamic>())],
  );

  final String label;

  /// The combination this is a part of ("4 Pu Pu Platter"), when it is one.
  final String header;
  final int qty;
  final int firstMs;

  /// How many are wanted some other way than plain; the rest of [qty] are plain.
  final List<PrepWay> ways;
}

class PrepStation {
  const PrepStation({this.station, required this.name, this.rows = const []});

  factory PrepStation.fromJson(Map<String, dynamic> json) => PrepStation(
    station: json['station'] as String?,
    name: json['name'] as String? ?? '',
    rows: [for (final row in json['rows'] as List? ?? const []) PrepRow.fromJson((row as Map).cast<String, dynamic>())],
  );

  final String? station;
  final String name;
  final List<PrepRow> rows;
}

/// One of the day's orders, as the head of the list names it.
class PrepOrder {
  const PrepOrder({
    required this.orderId,
    this.orderNo,
    this.customerName = '',
    this.channel = '',
    required this.promisedMs,
    this.guests,
    this.handover,
    this.dishes = 0,
    this.unsent = 0,
  });

  factory PrepOrder.fromJson(Map<String, dynamic> json) => PrepOrder(
    orderId: json['order_id'] as String,
    orderNo: (json['order_no'] as num?)?.toInt(),
    customerName: json['customer_name'] as String? ?? '',
    channel: json['channel'] as String? ?? '',
    promisedMs: (json['promised_ms'] as num).toInt(),
    guests: (json['guests'] as num?)?.toInt(),
    handover: json['handover'] as String?,
    dishes: (json['dishes'] as num?)?.toInt() ?? 0,
    unsent: (json['unsent'] as num?)?.toInt() ?? 0,
  );

  final String orderId;
  final int? orderNo;
  final String customerName;
  final String channel;
  final int promisedMs;
  final int? guests;
  final String? handover;
  final int dishes;
  final int unsent;

  /// "Chen · 30 guests · delivery"
  String get words => [
    customerName.isEmpty ? 'To go' : customerName,
    if (guests case final guests?) _many(guests, 'guest'),
    if (handover case final handover?) handoverLabel(handover).toLowerCase(),
  ].join(' · ');
}

class PrepList {
  const PrepList({
    required this.day,
    this.orders = const [],
    this.guests = 0,
    this.dishes = 0,
    this.unsent = 0,
    this.stations = const [],
  });

  factory PrepList.fromJson(Map<String, dynamic> json) => PrepList(
    day: json['day'] as String? ?? '',
    orders: [
      for (final order in json['orders'] as List? ?? const [])
        PrepOrder.fromJson((order as Map).cast<String, dynamic>()),
    ],
    guests: (json['guests'] as num?)?.toInt() ?? 0,
    dishes: (json['dishes'] as num?)?.toInt() ?? 0,
    unsent: (json['unsent'] as num?)?.toInt() ?? 0,
    stations: [
      for (final station in json['stations'] as List? ?? const [])
        PrepStation.fromJson((station as Map).cast<String, dynamic>()),
    ],
  );

  /// The day of service, `2026-11-21`.
  final String day;
  final List<PrepOrder> orders;
  final int guests;

  /// How many dishes were rung in for the day, a platter once; [unsent] of them nobody sent to the kitchen.
  final int dishes;
  final int unsent;
  final List<PrepStation> stations;

  /// Whether the day's orders are for more than one time: each dish then says by when its first.
  bool get manyTimes => {for (final order in orders) order.promisedMs}.length > 1;

  /// "3 orders · 38 guests · 42 dishes"
  String get summed => [
    _many(orders.length, 'order'),
    if (guests > 0) _many(guests, 'guest'),
    _many(dishes, 'dish', 'dishes'),
  ].join(' · ');

  /// "2 dishes are not sent to the kitchen yet. They are counted here."
  String get unsentWords => unsent == 1
      ? '1 dish is not sent to the kitchen yet. It is counted here.'
      : '$unsent dishes are not sent to the kitchen yet. They are counted here.';
}
