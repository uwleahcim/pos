/// A customer per phone number: who is calling, what they ordered before, and one line to remember them by
/// (`GET /customers/lookup`, `PUT /customers/{phone}`, `GET /orders/{id}/again` on the hub). Nothing here is
/// typed in for its own sake: the name, the count and the past orders are read from the orders the number
/// placed; only the note is kept on its own.
library;

import 'menu.dart';

/// How long the note about a customer may be; the hub cuts a longer one.
const customerNoteMax = 120;

/// A number with fewer digits is no customer's: an extension, a blocked caller ID, a number half typed.
const customerDigits = 7;

/// A phone number as the hub matches it: its digits, without the 1 in front of a ten-digit number.
String phoneDigits(String? raw) {
  final digits = (raw ?? '').replaceAll(RegExp(r'\D'), '');
  return digits.length == 11 && digits.startsWith('1') ? digits.substring(1) : digits;
}

/// One dish of a past order, as a line of the card reads it.
class PastItem {
  const PastItem({required this.qty, required this.item});

  factory PastItem.fromJson(Map<String, dynamic> json) =>
      PastItem(qty: (json['qty'] as num?)?.toInt() ?? 1, item: json['item'] as String? ?? '');

  final int qty;
  final String item;
}

/// An order the customer placed before: when, what it came to, and its dishes.
class PastOrder {
  const PastOrder({
    required this.orderId,
    this.openedMs,
    this.orderNo,
    this.channel = '',
    this.total = '',
    this.items = const [],
  });

  factory PastOrder.fromJson(Map<String, dynamic> json) => PastOrder(
    orderId: json['order_id'] as String,
    openedMs: (json['opened_ms'] as num?)?.toInt(),
    orderNo: (json['order_no'] as num?)?.toInt(),
    channel: json['channel'] as String? ?? '',
    total: json['total'] as String? ?? '',
    items: [for (final i in json['items'] as List? ?? const []) PastItem.fromJson(i as Map<String, dynamic>)],
  );

  final String orderId;
  final int? openedMs;
  final int? orderNo;
  final String channel;
  final String total;
  final List<PastItem> items;

  /// The dishes on one line: `2 General Tso's Chicken, California roll`. The same dish rung twice is counted
  /// together, in the order the dishes were first rung.
  String get dishes {
    final counts = <String, int>{};
    for (final i in items) {
      counts[i.item] = (counts[i.item] ?? 0) + i.qty;
    }
    return [for (final e in counts.entries) e.value > 1 ? '${e.value} ${e.key}' : e.key].join(', ');
  }
}

/// What the hub knows of the customer at a number.
class CustomerCard {
  const CustomerCard({
    required this.phone,
    this.known = false,
    this.name = '',
    this.note = '',
    this.tags = const [],
    this.orders = 0,
    this.firstMs,
    this.lastMs,
    this.recent = const [],
    this.address = '',
    this.addressNote = '',
  });

  factory CustomerCard.fromJson(Map<String, dynamic> json) => CustomerCard(
    phone: json['phone'] as String? ?? '',
    known: json['known'] as bool? ?? false,
    name: json['name'] as String? ?? '',
    note: json['note'] as String? ?? '',
    tags: [
      if (json['tags'] case final List tags)
        for (final tag in tags)
          if (tag is String && tag.trim().isNotEmpty) tag,
    ],
    orders: (json['orders'] as num?)?.toInt() ?? 0,
    firstMs: (json['first_ms'] as num?)?.toInt(),
    lastMs: (json['last_ms'] as num?)?.toInt(),
    recent: [for (final o in json['recent'] as List? ?? const []) PastOrder.fromJson(o as Map<String, dynamic>)],
    address: json['address'] as String? ?? '',
    addressNote: json['address_note'] as String? ?? '',
  );

  /// The number's digits, as the hub keeps them.
  final String phone;

  /// False for a number that never ordered and has no note.
  final bool known;

  /// The name on their latest order that has one.
  final String name;
  final String note;

  /// The tags a manager put on them in the guest list ("VIP"), for whoever takes their call or their order
  /// (docs/guest-list.md, "Tags and the note"). None from a hub older than tags.
  final List<String> tags;

  /// How many orders the number placed; voided ones do not count.
  final int orders;
  final int? firstMs;
  final int? lastMs;

  /// Their latest orders that have dishes on them, newest first.
  final List<PastOrder> recent;

  /// Where their latest delivery went, and what was said for the driver then (docs/delivery.md): what the
  /// form starts a new delivery with. Empty for a customer nothing was brought to, and from a hub older
  /// than deliveries.
  final String address;
  final String addressNote;

  /// One line on how well the restaurant knows them: `12 orders since Mar 2025, the last on 3 Nov`.
  String summary(DateTime now) {
    final first = firstMs, last = lastMs;
    if (orders <= 0 || first == null || last == null) return 'No orders from this number yet';
    if (orders == 1) return '1 order, ${_on(dayLabel(last, now))}';
    return '$orders orders since ${monthLabel(first)}, the last ${_on(dayLabel(last, now))}';
  }

  static String _on(String day) => day == 'today' || day == 'yesterday' ? day : 'on $day';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A day as a person says it on the terminal's clock: `today`, `yesterday`, `3 Nov`, or `3 Nov 2025` for
/// a day of another year.
String dayLabel(int ms, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
  if (days == 0) return 'today';
  if (days == 1) return 'yesterday';
  final day = '${at.day} ${_months[at.month - 1]}';
  return at.year == now.year ? day : '$day ${at.year}';
}

/// `Mar 2025`.
String monthLabel(int ms) {
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_months[at.month - 1]} ${at.year}';
}

/// A dish of a past order as the menu sells it today, ready to go on a new order.
class AgainLine {
  const AgainLine({
    required this.item,
    required this.qty,
    required this.request,
    this.note = '',
    this.unitPrice,
    this.was,
  });

  factory AgainLine.fromJson(Map<String, dynamic> json) => AgainLine(
    item: json['item'] as String? ?? '',
    qty: (json['qty'] as num?)?.toInt() ?? 1,
    request: (json['request'] as Map).cast<String, dynamic>(),
    note: json['note'] as String? ?? '',
    unitPrice: json['unit_price'] as String?,
    was: json['was'] as String?,
  );

  final String item;
  final int qty;

  /// The dish and its choices as they were picked then, as the hub prices a line.
  final Map<String, dynamic> request;
  final String note;

  /// What one costs today, and what one cost on the past order.
  final String? unitPrice;
  final String? was;

  bool get priceMoved {
    final now = double.tryParse(unitPrice ?? ''), then = double.tryParse(was ?? '');
    return now != null && then != null && now != then;
  }

  /// Whether this app reads the dish's choices as they were kept. An order from long ago may hold them in
  /// a shape the order screen cannot draw; such a dish is left off and named, not put on a check it breaks.
  bool get readable {
    try {
      LineRequest.fromJson(request);
      return true;
    } on TypeError {
      return false;
    }
  }
}

/// A dish of a past order that cannot be had again as it was, and why.
class AgainMissing {
  const AgainMissing({required this.item, required this.qty, required this.why});

  factory AgainMissing.fromJson(Map<String, dynamic> json) => AgainMissing(
    item: json['item'] as String? ?? '',
    qty: (json['qty'] as num?)?.toInt() ?? 1,
    why: json['why'] as String? ?? '',
  );

  final String item;
  final int qty;
  final String why;
}

/// "Same again": a past order's dishes at today's menu, and the ones that are not added.
class Again {
  const Again({this.lines = const [], this.missing = const []});

  factory Again.fromJson(Map<String, dynamic> json) {
    final all = [for (final l in json['lines'] as List? ?? const []) AgainLine.fromJson(l as Map<String, dynamic>)];
    return Again(
      lines: [
        for (final l in all)
          if (l.readable) l,
      ],
      missing: [
        for (final m in json['missing'] as List? ?? const []) AgainMissing.fromJson(m as Map<String, dynamic>),
        for (final l in all)
          if (!l.readable)
            AgainMissing(item: l.item, qty: l.qty, why: 'Its choices could not be read. Ring it in by hand.'),
      ],
    );
  }

  final List<AgainLine> lines;
  final List<AgainMissing> missing;

  /// What the operator is told once the dishes are on the new order: how many went on, which prices are
  /// not what they were, and which dishes were left off and why, so the customer hears it on the call.
  String get said {
    final dishes = lines.fold<int>(0, (n, l) => n + l.qty);
    final parts = <String>[
      if (lines.isEmpty) 'Nothing was added.' else 'Same again: $dishes ${dishes == 1 ? 'dish' : 'dishes'} added.',
      for (final l in lines)
        if (l.priceMoved) '${l.item} is \$${l.unitPrice} now, was \$${l.was}.',
      for (final m in missing) 'NOT added: ${m.qty > 1 ? '${m.qty} ' : ''}${m.item}. ${m.why}',
    ];
    return parts.join(' ');
  }

  /// Whether [said] tells of anything but dishes added: a price that moved or a dish left off.
  bool get needsTelling => missing.isNotEmpty || lines.any((l) => l.priceMoved);
}
