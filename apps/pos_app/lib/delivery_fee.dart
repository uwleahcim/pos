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
  const DeliveryFees({
    this.enabled = false,
    this.by = 'miles',
    this.bands = const [],
    this.taxed = false,
    this.origin = '',
    this.maps,
    this.lookup = false,
  });

  factory DeliveryFees.fromJson(Map<String, dynamic> json) => DeliveryFees(
    enabled: json['enabled'] == true,
    by: json['by'] == 'minutes' ? 'minutes' : 'miles',
    bands: [
      for (final band in json['bands'] as List? ?? const [])
        if (band is Map) FeeBand.fromJson(band.cast<String, dynamic>()),
    ],
    taxed: json['taxed'] == true,
    origin: json['origin'] is String ? json['origin'] as String : '',
    maps: json['maps'] is bool ? json['maps'] as bool : null,
    lookup: json['lookup'] == true,
  );

  /// The most bands a location lists, as the hub holds it: one screenful of buttons.
  static const mostBands = 8;

  final bool enabled;

  /// `miles` or `minutes`.
  final String by;
  final List<FeeBand> bands;
  final bool taxed;

  /// The restaurant's own address, where a looked-up distance starts ("Looking the distance up"); empty
  /// while nobody typed it.
  final String origin;

  /// Whether the hub has a map service to ask; null from a hub older than the lookup, which says neither.
  final bool? maps;

  /// Whether a form may ask the hub how far an address is: a map service, and [origin] to start from.
  final bool lookup;

  /// Whether a delivery is asked what it costs: turned on, with a price to pick.
  bool get asks => enabled && bands.isNotEmpty;

  /// Whether a form asks the hub how far an address is: only where there is a price to pick for the answer,
  /// so no address leaves the building for nothing.
  bool get looksUp => lookup && asks;

  /// The band that reaches [upTo], or null when the list has none.
  FeeBand? band(String? upTo) {
    for (final band in bands) {
      if (band.upTo == upTo) return band;
    }
    return null;
  }

  /// As a manager saves it. What the hub says of its map service is the hub's to say, and is not sent.
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'by': by,
    'bands': [for (final band in bands) band.toJson()],
    'taxed': taxed,
    'origin': origin,
  };
}

/// What the map said of a delivery's address: how far along the road and how long the usual drive.
class Measured {
  const Measured({required this.miles, required this.minutes});

  /// Null for anything this build cannot read.
  static Measured? of(Object? value) {
    if (value is! Map) return null;
    final miles = value['miles']?.toString(), minutes = value['minutes'];
    if (miles == null || double.tryParse(miles) == null || minutes is! int) return null;
    return Measured(miles: miles, minutes: minutes);
  }

  /// "3.2", as the hub writes it.
  final String miles;
  final int minutes;

  /// "3.2 mi · 9 min".
  String get words => '$miles mi · $minutes min';

  Map<String, dynamic> toJson() => {'miles': miles, 'minutes': minutes};

  @override
  bool operator ==(Object other) => other is Measured && other.miles == miles && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(miles, minutes);
}

/// The hub's answer about an address (`POST /delivery/distance`): what the map said and the band of the
/// fee it falls in.
class FeeLookup {
  const FeeLookup({required this.measured, this.band, this.beyond = false});

  /// Throws [FormatException] when the answer says no distance.
  factory FeeLookup.fromJson(Map<String, dynamic> json) {
    final measured = Measured.of(json);
    if (measured == null) throw const FormatException('no distance in the answer');
    final band = json['band'];
    return FeeLookup(
      measured: measured,
      band: band is Map ? FeeBand.fromJson(band.cast<String, dynamic>()) : null,
      beyond: json['beyond'] == true,
    );
  }

  final Measured measured;

  /// The band it falls in; null when it is further than the prices reach, or no fee is charged.
  final FeeBand? band;

  /// Further than the last band reaches.
  final bool beyond;
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
  const OrderFee({this.by, this.upTo, this.amount = '0.00', this.taxed = false, this.measured});

  /// Null while nobody said what the delivery costs, and for a field this build cannot read.
  static OrderFee? of(Object? value) {
    if (value is! Map) return null;
    final amount = value['amount']?.toString();
    if (amount == null || double.tryParse(amount) == null) return null;
    final by = value['by'], upTo = value['up_to']?.toString();
    final measured = Measured.of(value['measured']);
    if ((by != 'miles' && by != 'minutes') || upTo == null || upTo.isEmpty) {
      return double.parse(amount) == 0 ? OrderFee(measured: measured) : null;
    }
    return OrderFee(by: by as String, upTo: upTo, amount: amount, taxed: value['taxed'] == true, measured: measured);
  }

  final String? by;

  /// The band's reach; null for no fee on purpose.
  final String? upTo;
  final String amount;
  final bool taxed;

  /// What the map said of the address when the fee was picked; null when nobody asked it.
  final Measured? measured;

  /// No fee, on purpose.
  bool get none => upTo == null;

  /// How a form names it: the band's reach, or [FeePick.none].
  String get pick => upTo ?? FeePick.none;

  /// "$5.00 · up to 4.5 mi", or "No fee".
  String get words => none ? 'No fee' : '${feeWords(amount)} · ${reachWords(by!, upTo!).toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is OrderFee &&
      other.by == by &&
      other.upTo == upTo &&
      other.amount == amount &&
      other.taxed == taxed &&
      other.measured == measured;

  @override
  int get hashCode => Object.hash(by, upTo, amount, taxed, measured);
}

/// What a form holds of the fee: a band's reach ("2.5"), [none] for no fee on purpose, [kept] for the fee
/// the order already carries, or null while nobody picked.
abstract final class FeePick {
  static const none = '';
  static const kept = '=';

  /// What an order's `delivery_fee` field is sent as: the band alone, and what the map said of the
  /// address when it was asked ([measured]). The hub fills in what the band costs.
  static Map<String, dynamic> field(String pick, {Measured? measured}) => {
    'up_to': pick == none ? null : pick,
    'measured': ?measured?.toJson(),
  };

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
