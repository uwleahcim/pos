/// Counter mode and takeout (architecture section 12): the quote times a manager sets per channel, what the
/// to-go dialog collects, and what the pay-first dialog hands back.
library;

/// How many minutes each channel promises a takeout order, and which channels may pay at pickup instead of
/// before the kitchen sees the order (`GET /settings/quotes`).
class Quotes {
  const Quotes({
    this.minutes = const {'counter': 15, 'phone': 20, 'online': 25, 'delivery': 45},
    this.payAtPickup = const ['phone'],
  });

  factory Quotes.fromJson(Map<String, dynamic> json) => Quotes(
    minutes: {for (final e in (json['minutes'] as Map? ?? const {}).entries) e.key as String: (e.value as num).toInt()},
    payAtPickup: List<String>.from(json['pay_at_pickup'] as List? ?? const []),
  );

  final Map<String, int> minutes;
  final List<String> payAtPickup;

  int minutesFor(String channel) => minutes[channel] ?? 15;
  bool mayPayAtPickup(String channel) => payAtPickup.contains(channel);

  Map<String, dynamic> toJson() => {'minutes': minutes, 'pay_at_pickup': payAtPickup};
}

/// The channels an operator takes orders on by hand; online and delivery orders come in on their own.
const handChannels = ['counter', 'phone'];

/// What the to-go dialog collects: name and phone first, the channel, and when the order is for.
class TakeoutRequest {
  const TakeoutRequest({
    required this.name,
    required this.phone,
    required this.channel,
    this.locale = 'en',
    this.promisedAt,
  });

  final String name;
  final String phone;
  final String channel;
  final String locale; // the customer's language for texts

  /// A future order's time; null means as soon as the channel's quote allows.
  final DateTime? promisedAt;
}

/// What the pay-first dialog hands back: cash with what was tendered, paid elsewhere with a note, or
/// nothing taken yet (pay at pickup, where the location allows it for the channel).
class PayChoice {
  const PayChoice({this.method, this.tendered, this.note = ''});

  final String? method; // cash | elsewhere | null: pay at pickup
  final String? tendered;
  final String note;

  bool get takesMoney => method != null;
}

String channelLabel(String channel) => switch (channel) {
  'counter' => 'Counter',
  'phone' => 'Phone',
  'online' => 'Online',
  'delivery' => 'Delivery',
  'catering' => 'Catering',
  _ => channel,
};

/// 18:05 for a promised time, on the terminal's clock.
String clockTime(int ms) {
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

String stageLabel(String stage) => switch (stage) {
  'ready' => 'Ready',
  'picked_up' => 'Picked up',
  _ => '',
};
