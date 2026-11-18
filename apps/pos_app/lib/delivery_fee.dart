/// What a delivery costs the customer (docs/delivery.md, "The delivery fee"): the location's prices by how
/// far a delivery goes or how long the drive is, and the fee an order carries. Whoever takes the order picks
/// the band; the hub fills in what it costs, so no amount is made up here.
library;

/// One price of the list: a delivery that goes up to so far costs this much.
class FeeBand {
  const FeeBand({required this.upTo, required this.fee});

  factory FeeBand.fromJson(Map<String, dynamic> json) =>
      FeeBand(upTo: json['up_to']?.toString() ?? '', fee: json['fee']?.toString() ?? '0.00');

  /// How far it reaches, as the hub writes it: "2", "2.5" miles, or "15" minutes.
  final String upTo;

  /// Dollars and cents, "5.00". A band may cost nothing.
  final String fee;

  Map<String, dynamic> toJson() => {'up_to': upTo, 'fee': fee};

  @override
  bool operator ==(Object other) => other is FeeBand && other.upTo == upTo && other.fee == fee;

  @override
  int get hashCode => Object.hash(upTo, fee);
}

/// The location's prices for a delivery: whether a fee is charged at all, whether it goes by miles or by
/// the minutes of the drive, the bands in order of how far they reach, and whether the fee is taxed.
class DeliveryFees {
  const DeliveryFees({this.enabled = false, this.by = 'miles', this.bands = const [], this.taxed = false});

  factory DeliveryFees.fromJson(Map<String, dynamic> json) => DeliveryFees(
    enabled: json['enabled'] == true,
    by: json['by'] == 'minutes' ? 'minutes' : 'miles',
    bands: [
      for (final band in json['bands'] as List? ?? const [])
        if (band is Map) FeeBand.fromJson(band.cast<String, dynamic>()),
    ],
    taxed: json['taxed'] == true,
  );

  /// The most bands a location lists, as the hub holds it: one screenful of buttons.
  static const mostBands = 8;

  final bool enabled;

  /// `miles` or `minutes`.
  final String by;
  final List<FeeBand> bands;
  final bool taxed;

  /// Whether a delivery is asked what it costs: turned on, with a price to pick.
  bool get asks => enabled && bands.isNotEmpty;

  /// The band that reaches [upTo], or null when the list has none.
  FeeBand? band(String? upTo) {
    for (final band in bands) {
      if (band.upTo == upTo) return band;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'by': by,
    'bands': [for (final band in bands) band.toJson()],
    'taxed': taxed,
  };
}

/// "mi" or "min": what a band's reach is counted in, short enough for a button.
String feeUnit(String by) => by == 'minutes' ? 'min' : 'mi';

/// "Up to 2.5 mi", "Up to 15 min".
String reachWords(String by, String upTo) => 'Up to $upTo ${feeUnit(by)}';

/// "2.5 mi", "15 min": the reach alone, for a button too narrow for [reachWords] under a heading that says
/// "up to".
String reachShort(String by, String upTo) => '$upTo ${feeUnit(by)}';

/// "$5.00", and "Free" for a band that costs nothing.
String feeWords(String fee) => (double.tryParse(fee) ?? 0) == 0 ? 'Free' : '\$$fee';

/// The fee an order carries, read from its `delivery_fee` field: the band it was picked by and what that
/// band cost then.
class OrderFee {
  const OrderFee({this.by, this.upTo, this.amount = '0.00', this.taxed = false});

  /// Null while nobody said what the delivery costs, and for a field this build cannot read.
  static OrderFee? of(Object? value) {
    if (value is! Map) return null;
    final amount = value['amount']?.toString();
    if (amount == null || double.tryParse(amount) == null) return null;
    final by = value['by'], upTo = value['up_to']?.toString();
    if ((by != 'miles' && by != 'minutes') || upTo == null || upTo.isEmpty) {
      return double.parse(amount) == 0 ? const OrderFee() : null;
    }
    return OrderFee(by: by as String, upTo: upTo, amount: amount, taxed: value['taxed'] == true);
  }

  final String? by;

  /// The band's reach; null for no fee on purpose.
  final String? upTo;
  final String amount;
  final bool taxed;

  /// No fee, on purpose.
  bool get none => upTo == null;

  /// How a form names it: the band's reach, or [FeePick.none].
  String get pick => upTo ?? FeePick.none;

  /// "$5.00 · up to 4.5 mi", or "No fee".
  String get words => none ? 'No fee' : '${feeWords(amount)} · ${reachWords(by!, upTo!).toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is OrderFee && other.by == by && other.upTo == upTo && other.amount == amount && other.taxed == taxed;

  @override
  int get hashCode => Object.hash(by, upTo, amount, taxed);
}

/// What a form holds of the fee: a band's reach ("2.5"), [none] for no fee on purpose, [kept] for the fee
/// the order already carries, or null while nobody picked.
abstract final class FeePick {
  static const none = '';
  static const kept = '=';

  /// What an order's `delivery_fee` field is sent as: the band alone. The hub fills in what it costs.
  static Map<String, dynamic> field(String pick) => {'up_to': pick == none ? null : pick};

  /// Whether the fee an order carries ([taken]) is one the list ([fees]) still offers at that price. One
  /// that is not stays on the order as it was taken, until somebody picks another.
  static bool listed(OrderFee taken, DeliveryFees? fees) =>
      taken.none || (fees != null && fees.asks && fees.by == taken.by && fees.band(taken.upTo)?.fee == taken.amount);

  /// What a form picked, as it is to be sent: null when it leaves the order's fee ([taken]) as it is.
  static String? changed(String? pick, OrderFee? taken, DeliveryFees? fees) {
    if (pick == null || pick == kept) return null;
    if (taken != null && listed(taken, fees) && pick == taken.pick) return null;
    return pick;
  }
}
