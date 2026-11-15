/// Counter mode and takeout (architecture section 12): the quote times a manager sets per channel, what the
/// to-go dialog collects, and what the pay-first dialog hands back.
library;

/// The kitchen is behind tonight: [minutes] more on every quote made until [until] (the end of the night, as
/// the hub works it out), set by the manager [by]. Orders already promised keep their time.
class Rush {
  const Rush({required this.minutes, required this.until, this.by = ''});

  static Rush? fromJson(Object? json) => json is Map && (json['minutes'] as num? ?? 0) > 0
      ? Rush(
          minutes: (json['minutes'] as num).toInt(),
          until: (json['until'] as num? ?? 0).toInt(),
          by: json['by']?.toString() ?? '',
        )
      : null;

  final int minutes;
  final int until; // wall-clock ms
  final String by;

  /// Whether it still adds its minutes at [at]: a rush left on is over when its night is.
  bool runsAt(DateTime at) => minutes > 0 && at.millisecondsSinceEpoch < until;
}

/// How many minutes each channel promises a takeout order, and which channels may pay at pickup instead of
/// before the kitchen sees the order (`GET /settings/quotes`). On top of the channel's minutes come the
/// [rush] a manager set for tonight, and [bigMinutes] for an order of [bigDishes] dishes or more.
class Quotes {
  const Quotes({
    this.minutes = const {'counter': 15, 'phone': 20, 'online': 25, 'delivery': 45},
    this.payAtPickup = const ['phone'],
    this.rush,
    this.bigDishes = 0,
    this.bigMinutes = 0,
    this.takesRush = false,
    this.takesBigOrders = false,
  });

  factory Quotes.fromJson(Map<String, dynamic> json) {
    final big = json['big_orders'] as Map? ?? const {};
    return Quotes(
      minutes: {
        for (final e in (json['minutes'] as Map? ?? const {}).entries) e.key as String: (e.value as num).toInt(),
      },
      payAtPickup: List<String>.from(json['pay_at_pickup'] as List? ?? const []),
      rush: Rush.fromJson(json['rush']),
      bigDishes: (big['dishes'] as num? ?? 0).toInt(),
      bigMinutes: (big['minutes'] as num? ?? 0).toInt(),
      takesRush: json.containsKey('rush'),
      takesBigOrders: json.containsKey('big_orders'),
    );
  }

  final Map<String, int> minutes;
  final List<String> payAtPickup;

  /// The rush as the hub last gave it; it may have run out since (see [rushAt]).
  final Rush? rush;

  /// An order of this many dishes or more is promised [bigMinutes] later. 0 for either: no such rule.
  final int bigDishes;
  final int bigMinutes;

  /// Whether the hub that answered knows of the rush, and of big orders: one older than them is offered
  /// neither.
  final bool takesRush;
  final bool takesBigOrders;

  /// The channel's own minutes, as a manager set them.
  int baseFor(String channel) => minutes[channel] ?? 15;

  /// The minutes the rush adds to a quote made at [at]. An order the customer named a time for ([promised])
  /// takes them only when that time is still within the rush's night: tonight's rush says nothing about
  /// tomorrow's lunch.
  int rushAt(DateTime at, {DateTime? promised}) {
    final rush = this.rush;
    if (rush == null || !rush.runsAt(at)) return 0;
    if (promised != null && !rush.runsAt(promised)) return 0;
    return rush.minutes;
  }

  /// What a new order on [channel] is quoted at [at] (now, unless a test says otherwise): the channel's
  /// minutes and the rush.
  int minutesFor(String channel, {DateTime? at, DateTime? promised}) =>
      baseFor(channel) + rushAt(at ?? DateTime.now(), promised: promised);

  /// The minutes an order of [dishes] dishes takes on top of its quote.
  int extraFor(int dishes) => bigDishes > 0 && bigMinutes > 0 && dishes >= bigDishes ? bigMinutes : 0;

  bool mayPayAtPickup(String channel) => payAtPickup.contains(channel);

  /// What a manager's save sends: the rush is set by itself (`PUT /settings/rush`).
  Map<String, dynamic> toJson() => {
    'minutes': minutes,
    'pay_at_pickup': payAtPickup,
    if (takesBigOrders) 'big_orders': {'dishes': bigDishes, 'minutes': bigMinutes},
  };
}

/// How long before it must start cooking an order for later is marked on the list of checks.
const startsSoon = Duration(minutes: 15);

/// Where a to-go order for later stands against the clock, for the list of checks.
enum LaterStage {
  /// Not for later, already with the kitchen or done: nothing to mark.
  none,

  /// Its time to start cooking is more than [startsSoon] away.
  waiting,

  /// It starts cooking within [startsSoon].
  soon,

  /// Its time to start has come and it was never sent, so no ticket will print for it.
  unsent,
}

/// When an order for [promisedAt], quoted [quotedMinutes], must start cooking: the hub prints its ticket
/// then, if it was sent.
DateTime startsAt(int promisedAt, int quotedMinutes) =>
    DateTime.fromMillisecondsSinceEpoch(promisedAt).subtract(Duration(minutes: quotedMinutes));

/// Where an open to-go order stands at [now]. Only an order the customer named a time for ([forLater]) is
/// marked, and only until the kitchen has it: one sent in time prints by itself when it must start.
LaterStage laterStage({
  required bool forLater,
  required int? promisedAt,
  required int quotedMinutes,
  required bool sent,
  required DateTime now,
}) {
  if (!forLater || promisedAt == null) return LaterStage.none;
  final start = startsAt(promisedAt, quotedMinutes);
  if (!now.isBefore(start)) return sent ? LaterStage.none : LaterStage.unsent;
  return now.isBefore(start.subtract(startsSoon)) ? LaterStage.waiting : LaterStage.soon;
}

/// The next moment after [now] at which [laterStage] of such an order changes, or null when it will not.
DateTime? laterStageChanges({required int promisedAt, required int quotedMinutes, required DateTime now}) {
  final start = startsAt(promisedAt, quotedMinutes);
  final soon = start.subtract(startsSoon);
  if (now.isBefore(soon)) return soon;
  return now.isBefore(start) ? start : null;
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
    this.again,
    this.note,
  });

  final String name;
  final String phone;
  final String channel;
  final String locale; // the customer's language for texts

  /// A future order's time; null means as soon as the channel's quote allows.
  final DateTime? promisedAt;

  /// "Same again": the past order whose dishes the new one starts with; null starts it empty.
  final String? again;

  /// The line about the customer as the form leaves it, when it was changed there; null keeps what the hub
  /// has.
  final String? note;
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
