/// The orders ahead (docs/catering.md): what was promised for a time still to come, by the day it is for,
/// each with what it comes to, what was paid on it and what is still to collect, as the hub reckons them
/// (`GET /orders/ahead`). Nothing here is worked out on the terminal but the words.
library;

import 'takeout.dart';

/// One order on the list.
class AheadOrder {
  const AheadOrder({
    required this.orderId,
    this.orderNo,
    this.customerName = '',
    this.phone = '',
    this.channel = '',
    required this.promisedMs,
    this.event = const EventDetails(),
    this.status = 'open',
    this.stage = 'new',
    this.dishes = 0,
    this.unsent = 0,
    this.items = const [],
    this.total = '0.00',
    this.paid = '0.00',
    this.due = '0.00',
  });

  factory AheadOrder.fromJson(Map<String, dynamic> json) => AheadOrder(
    orderId: json['order_id'] as String,
    orderNo: (json['order_no'] as num?)?.toInt(),
    customerName: json['customer_name'] as String? ?? '',
    phone: json['phone'] as String? ?? '',
    channel: json['channel'] as String? ?? '',
    promisedMs: (json['promised_ms'] as num).toInt(),
    event: EventDetails(
      guests: (json['guests'] as num?)?.toInt(),
      handover: json['handover'] == 'delivery' ? 'delivery' : 'pickup',
      address: json['address'] as String? ?? '',
      note: json['event_note'] as String? ?? '',
    ),
    status: json['status'] as String? ?? 'open',
    stage: json['stage'] as String? ?? 'new',
    dishes: (json['dishes'] as num? ?? 0).toInt(),
    unsent: (json['unsent'] as num? ?? 0).toInt(),
    items: [
      for (final item in json['items'] as List? ?? const [])
        if (item is Map) (name: item['name']?.toString() ?? '', qty: (item['qty'] as num? ?? 0).toInt()),
    ],
    total: json['total'] as String? ?? '0.00',
    paid: json['paid'] as String? ?? '0.00',
    due: json['due'] as String? ?? '0.00',
  );

  final String orderId;
  final int? orderNo;
  final String customerName;
  final String phone;
  final String channel;
  final int promisedMs;

  /// The guests, how it leaves, where to and the note. A catering order has them; any other order says
  /// how it leaves, and a delivery where to.
  final EventDetails event;
  final String status; // open | closed
  final String stage; // new | ready
  final int dishes;

  /// Dishes nobody sent to the kitchen: no ticket prints for them when the order's time comes.
  final int unsent;
  final List<({String name, int qty})> items;
  final String total;
  final String paid;
  final String due;

  bool get isCatering => channel == 'catering';

  /// "2 Pu Pu Platter, 3 Chicken wings", as far as [most] dishes go, then "and 2 more".
  String dishWords({int most = 4}) {
    final named = [for (final item in items.take(most)) '${item.qty} ${item.name}'];
    final more = items.length - named.length;
    return [...named, if (more > 0) 'and $more more'].join(', ');
  }

  /// What the event needs, for the list, and of any other order that is brought to the customer where it
  /// goes (docs/delivery.md): nothing for an order that is neither.
  String get eventWords => isCatering || event.delivered ? event.words : '';
}

/// One day of service with its orders, the earliest first, and what they add up to.
class AheadDay {
  const AheadDay({
    required this.day,
    this.orders = const [],
    this.guests = 0,
    this.unsent = 0,
    this.total = '0.00',
    this.paid = '0.00',
    this.due = '0.00',
  });

  factory AheadDay.fromJson(Map<String, dynamic> json) => AheadDay(
    day: json['day'] as String,
    orders: [
      for (final order in json['orders'] as List? ?? const []) AheadOrder.fromJson(order as Map<String, dynamic>),
    ],
    guests: (json['guests'] as num? ?? 0).toInt(),
    unsent: (json['unsent'] as num? ?? 0).toInt(),
    total: json['total'] as String? ?? '0.00',
    paid: json['paid'] as String? ?? '0.00',
    due: json['due'] as String? ?? '0.00',
  );

  /// The day of service, as the hub names it: 2026-11-21.
  final String day;
  final List<AheadOrder> orders;
  final int guests;

  /// How many of the day's orders have a dish nobody sent.
  final int unsent;
  final String total;
  final String paid;
  final String due;
}

/// The whole list, with the hub's own day, so "today" is the restaurant's and not the device's.
class OrdersAhead {
  const OrdersAhead({this.today = '', this.days = const []});

  factory OrdersAhead.fromJson(Map<String, dynamic> json) => OrdersAhead(
    today: json['today'] as String? ?? '',
    days: [for (final day in json['days'] as List? ?? const []) AheadDay.fromJson(day as Map<String, dynamic>)],
  );

  final String today;
  final List<AheadDay> days;

  int get count => days.fold(0, (n, day) => n + day.orders.length);

  /// The heading of [day]: "Today", "Tomorrow", "Sat 21 Nov", and for a day that is over, whose order nobody
  /// closed, "Sat 14 Nov · not closed".
  String heading(AheadDay day) {
    final at = DateTime.tryParse(day.day);
    final from = DateTime.tryParse(today);
    if (at == null || from == null) return day.day;
    if (at.isBefore(from)) return '${dayName(at)} · not closed';
    final words = dayAhead(at, from);
    return words[0].toUpperCase() + words.substring(1);
  }
}
