/// What a delivery costs the customer (docs/delivery.md, "The delivery fee"): the location's prices by how
/// far a delivery goes or how long the drive is, and the fee an order carries. Whoever takes the order picks
/// the band; the hub fills in what it costs, so no amount is made up here.
library;

/// One price of the list: a delivery that goes up to so far costs this much.
class FeeBand {
  const FeeBand({required this.upTo, required this.fee});

  factory FeeBand.fromJson(Map<String, dynamic> json) =>
      FeeBand(upTo: json['up_to']?.toString() ?? '', fee: json['fee']?.toString() ?? '0.00');

  /// How far it reaches, as the hub writes it: "2", "2.5", "0.25" miles (to a hundredth), or "15" minutes.
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
    this.services = const [],
    this.live = false,
    this.custom,
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
    services: [
      if (json['services'] case final List names)
        for (final name in names)
          if (name is String && name.isNotEmpty) name,
    ],
    live: json['live'] == true,
    custom: json['custom'] is bool ? json['custom'] as bool : null,
  );

  /// The most bands a location lists, as the hub holds it.
  static const mostBands = 8;

  /// The most prices a form shows as a button each. A longer list is one line that opens the whole list
  /// (the owner's words, 2026-11-27: "delivery fees with lots of options (over 4) change it something that
  /// fit better on the screen than a bunch of buttons").
  static const mostButtons = 4;

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

  /// The hub's map services by the names it gives them, in the order it asks them: the first, and the one
  /// it asks when the first gives no distance ("A second map service"). Empty from a hub that says none.
  final List<String> services;

  /// Whether a delivery for now is promised by the roads as they are ("Live traffic"): a manager turned
  /// it on, and the hub has a map service that knows them and the restaurant's address. A form then asks
  /// for the drive right now beside the distance.
  final bool live;

  /// Whether whoever takes a delivery may type what it costs where it goes further than the last band
  /// reaches ("A custom fee for a delivery further away"); null from a hub older than that, which takes no
  /// typed amount.
  final bool? custom;

  /// Whether a delivery is asked what it costs: turned on, with a price to pick.
  bool get asks => enabled && bands.isNotEmpty;

  /// Whether a form offers the custom fee beside the prices.
  bool get offersCustom => asks && custom == true;

  /// Whether the prices are too many for a button each ([mostButtons]).
  bool get crowded => bands.length > mostButtons;

  /// The band that reaches furthest, which a custom fee is for deliveries beyond; null with no band.
  FeeBand? get furthest {
    FeeBand? last;
    for (final band in bands) {
      if (last == null || (double.tryParse(band.upTo) ?? 0) > (double.tryParse(last.upTo) ?? 0)) last = band;
    }
    return last;
  }

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

  /// As a manager saves it. What the hub says of its map service is the hub's to say, and is not sent. Nor
  /// is [custom] to a hub that said nothing of it: it would not know the word.
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'by': by,
    'bands': [for (final band in bands) band.toJson()],
    'taxed': taxed,
    'origin': origin,
    'custom': ?custom,
  };
}

/// What the map said of a delivery's address: how far along the road and how long the usual drive.
class Measured {
  const Measured({required this.miles, required this.minutes, this.service, this.from});

  /// Null for anything this build cannot read.
  static Measured? of(Object? value) {
    if (value is! Map) return null;
    final miles = value['miles']?.toString(), minutes = value['minutes'];
    if (miles == null || double.tryParse(miles) == null || minutes is! int) return null;
    final service = value['service'], from = value['from'];
    final marked = service is String && from is String;
    return Measured(miles: miles, minutes: minutes, service: marked ? service : null, from: marked ? from : null);
  }

  /// "3.2", "0.25": as the hub writes it, to a hundredth of a mile.
  final String miles;
  final int minutes;

  /// Which map service measured it, and the hub's mark of the restaurant's address it was measured from
  /// ("Customers who order again"). The hub says both and is sent both back with the pick, as they came:
  /// they are how it knows, the next time this customer orders, that the figures can be used again. Null
  /// from a hub that keeps no distances.
  final String? service;
  final String? from;

  /// "3.2 mi · 9 min".
  String get words => '$miles mi · $minutes min';

  Map<String, dynamic> toJson() => {
    'miles': miles,
    'minutes': minutes,
    if (service != null && from != null) ...{'service': service, 'from': from},
  };

  @override
  bool operator ==(Object other) =>
      other is Measured &&
      other.miles == miles &&
      other.minutes == minutes &&
      other.service == service &&
      other.from == from;

  @override
  int get hashCode => Object.hash(miles, minutes, service, from);
}

/// A map service as a person calls it: "Geocodio", "Google Maps". One this build has not heard of keeps
/// the name the hub gives it.
String mapServiceName(String service) => switch (service) {
  'geocodio' => 'Geocodio',
  'google' => 'Google Maps',
  'mapbox' => 'Mapbox',
  'azure' => 'Azure Maps',
  _ => service,
};

/// How a form asks the hub how far an address is (`PosApi.deliveryDistance`, with the customer's number
/// bound in by the form). [fresh] asks the map service even when the customer's own earlier order says how
/// far. [now] says the delivery is for now: where live traffic is on, the answer then also says how long
/// the drive is at this minute.
typedef DistanceSource = Future<FeeLookup> Function(String address, {bool fresh, bool now});

/// The drive to a delivery's address as the roads are at this minute, and the minutes the kitchen needs
/// before it (docs/delivery.md, "Live traffic"): what a delivery for now is promised, in place of the
/// minutes set for Delivery. It is for the promise alone. It picks no price, it is never put on the order
/// and it is not sent back to the hub: the order keeps the time it was promised, which is the
/// restaurant's own.
class DriveNow {
  const DriveNow({required this.minutes, required this.before, this.credit, this.by});

  /// Null for nothing, and for anything this build cannot read.
  static DriveNow? of(Object? value) {
    if (value is! Map) return null;
    final minutes = value['minutes'], before = value['before'], credit = value['credit'];
    if (minutes is! int || before is! int || minutes < 1 || minutes > most || before < 0 || before > most) return null;
    return DriveNow(
      minutes: minutes,
      before: before,
      credit: credit is String && credit.isNotEmpty && credit.length <= FeeLookup.creditMost ? credit : null,
      by: AnsweredBy.of(value),
    );
  }

  /// The longest either figure may be and still be believed: a day.
  static const most = 1440;

  /// The drive, in minutes, with the traffic there is.
  final int minutes;

  /// The minutes for the cooking and getting the order out of the door, as a manager set them.
  final int before;

  /// The name the service that knows the roads wants shown beside its figure ("Google Maps").
  final String? credit;

  /// Who said it and what that service has left today, for the badge beside the figure; null from a hub
  /// that does not say.
  final AnsweredBy? by;

  /// What the delivery is promised: the cooking and the drive.
  int get promise => before + minutes;

  @override
  bool operator ==(Object other) =>
      other is DriveNow && other.minutes == minutes && other.before == before && other.credit == credit;

  @override
  int get hashCode => Object.hash(minutes, before, credit);
}

/// Which map service gave a figure, for the badge beside it (docs/delivery.md, "Which service is asked
/// first"): the hub's name for it, what a screen calls it, and how many of its day's lookups it has left
/// by the hub's own count.
class AnsweredBy {
  const AnsweredBy({required this.service, required this.title, this.left, this.dailyMost});

  /// Null from a hub that does not say what a screen calls the service (one older than the badge).
  static AnsweredBy? of(Map value) {
    final service = value['service'], title = value['title'], left = value['left'], most = value['daily_most'];
    if (service is! String || service.isEmpty || title is! String || title.isEmpty) return null;
    if (title.length > FeeLookup.creditMost) return null;
    return AnsweredBy(
      service: service,
      title: title,
      left: left is int && left >= 0 ? left : null,
      dailyMost: most is int && most > 0 ? most : null,
    );
  }

  final String service;
  final String title;

  /// Null where the hub has no key for the service any more.
  final int? left;
  final int? dailyMost;
}

/// Live traffic for deliveries, as a manager sets it for the location (`/settings/live_drive`, "Live
/// traffic"): whether a delivery for now is promised by the roads as they are, and the minutes the kitchen
/// needs before the drive. The hub says beside it what it takes: a map service that knows the roads right
/// now ([traffic]) and the restaurant's own address ([origin]); [live] is all three.
class LiveDrive {
  const LiveDrive({
    this.enabled = false,
    this.before = 25,
    this.traffic = false,
    this.origin = false,
    this.live = false,
  });

  factory LiveDrive.fromJson(Map<String, dynamic> json) => LiveDrive(
    enabled: json['enabled'] == true,
    before: json['before'] is int ? json['before'] as int : 25,
    traffic: json['traffic'] == true,
    origin: json['origin'] == true,
    live: json['live'] == true,
  );

  /// The most minutes the kitchen may be given before the drive, as the hub holds it.
  static const mostBefore = 240;

  final bool enabled;
  final int before;
  final bool traffic;
  final bool origin;
  final bool live;

  /// As a manager saves it. What the hub has is the hub's to say, and is not sent.
  Map<String, dynamic> toJson() => {'enabled': enabled, 'before': before};
}

/// The hub's answer about an address (`POST /delivery/distance`): what the map said and the band of the
/// fee it falls in.
class FeeLookup {
  const FeeLookup({
    required this.measured,
    this.band,
    this.beyond = false,
    this.saved = false,
    this.credit,
    this.keep = true,
    this.driveNow,
    this.by,
  });

  /// Throws [FormatException] when the answer says no distance.
  factory FeeLookup.fromJson(Map<String, dynamic> json) {
    final measured = Measured.of(json);
    if (measured == null) throw const FormatException('no distance in the answer');
    final band = json['band'], credit = json['credit'];
    return FeeLookup(
      measured: measured,
      band: band is Map ? FeeBand.fromJson(band.cast<String, dynamic>()) : null,
      beyond: json['beyond'] == true,
      saved: json['saved'] == true,
      credit: credit is String && credit.isNotEmpty && credit.length <= creditMost ? credit : null,
      keep: json['keep'] != false,
      driveNow: DriveNow.of(json['drive_now']),
      by: AnsweredBy.of(json),
    );
  }

  /// The longest name a service is credited by; anything longer is not a name.
  static const creditMost = 40;

  final Measured measured;

  /// The band it falls in; null when it is further than the prices reach, or no fee is charged.
  final FeeBand? band;

  /// Further than the last band reaches.
  final bool beyond;

  /// Nobody was asked: the hub read the figures off this customer's own earlier delivery to the address.
  final bool saved;

  /// The name the service that measured it wants shown beside its figures, in its own words ("Google
  /// Maps"); null for a service that asks for none.
  final String? credit;

  /// Whether the figures may go onto the order with the pick. False for a service whose terms do not let
  /// its distances be kept (Google): they pick the price on this form and go nowhere else, so they are not
  /// sent back to the hub and never sit in this device's own list of what is still to be sent.
  final bool keep;

  /// The drive as the roads are at this minute, where the form said the delivery is for now and live
  /// traffic is on; null where it is off, and when nobody could say: the delivery is then promised its
  /// usual minutes.
  final DriveNow? driveNow;

  /// Who measured the distance and what that service has left today, for the badge beside the figures;
  /// null from a hub that does not say.
  final AnsweredBy? by;
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

/// "Past 8 mi", "Past 20 min": what a custom fee is for, by the band that reaches furthest.
String pastWords(String by, String upTo) => 'Past ${reachShort(by, upTo)}';

/// The fee an order carries, read from its `delivery_fee` field: the band it was picked by and what that
/// band cost then. An order placed on the restaurant's website carries the fee the website charged, which
/// has no band ([onWebsite], docs/online-orders.md). Nor has a fee that was typed for a delivery further
/// than the bands reach ([custom]).
class OrderFee {
  const OrderFee({this.by, this.upTo, this.amount = '0.00', this.taxed = false, this.measured});

  /// What [by] says of a fee the website charged.
  static const website = 'online';

  /// What [by] says of a fee that was typed: the amount alone, for a delivery further than the bands reach.
  static const typed = 'custom';

  /// Null while nobody said what the delivery costs, and for a field this build cannot read.
  static OrderFee? of(Object? value) {
    if (value is! Map) return null;
    final amount = value['amount']?.toString();
    if (amount == null || double.tryParse(amount) == null) return null;
    final by = value['by'], upTo = value['up_to']?.toString();
    if (by == website && double.parse(amount) > 0) {
      return OrderFee(by: website, amount: amount, taxed: value['taxed'] == true);
    }
    final measured = Measured.of(value['measured']);
    if (by == typed && double.parse(amount) > 0) {
      return OrderFee(by: typed, amount: amount, taxed: value['taxed'] == true, measured: measured);
    }
    if ((by != 'miles' && by != 'minutes') || upTo == null || upTo.isEmpty) {
      return double.parse(amount) == 0 ? OrderFee(measured: measured) : null;
    }
    return OrderFee(by: by as String, upTo: upTo, amount: amount, taxed: value['taxed'] == true, measured: measured);
  }

  final String? by;

  /// The band's reach; null for no fee on purpose, for a fee the website charged and for one that was typed.
  final String? upTo;
  final String amount;
  final bool taxed;

  /// What the map said of the address when the fee was picked; null when nobody asked it.
  final Measured? measured;

  /// Charged on the restaurant's website when the order was placed there: no band of the location's list.
  bool get onWebsite => by == website;

  /// Typed by whoever took the order, for a delivery further than the bands reach: no band of the list.
  bool get custom => by == typed;

  /// No fee, on purpose.
  bool get none => upTo == null && !onWebsite && !custom;

  /// How a form names it: the band's reach, [FeePick.none], the amount that was typed ([FeePick.typed]),
  /// or [FeePick.kept] for the website's fee, which no button of the list stands for.
  String get pick => onWebsite
      ? FeePick.kept
      : custom
      ? FeePick.typed(amount)
      : upTo ?? FeePick.none;

  /// "Up to 4.5 mi", "Charged on the website" or "Custom fee"; nothing for no fee.
  String get reach => none
      ? ''
      : onWebsite
      ? 'Charged on the website'
      : custom
      ? 'Custom fee'
      : reachWords(by!, upTo!);

  /// "$5.00 · up to 4.5 mi", "$4.00 · charged on the website", "$12.50 · custom fee", or "No fee".
  String get words => none ? 'No fee' : '${feeWords(amount)} · ${reach.toLowerCase()}';

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
/// the order already carries, a custom fee with what was typed of it so far ([typed]), or null while nobody
/// picked.
abstract final class FeePick {
  static const none = '';
  static const kept = '=';

  /// The custom fee, picked and nothing typed yet. What is typed follows it: "+12.50". No band's reach
  /// starts so.
  static const custom = '+';

  /// The custom fee with [amount] as far as it is typed.
  static String typed(String amount) => '$custom${amount.trim()}';

  /// Whether [pick] is the custom fee, whatever is typed of it.
  static bool isCustom(String? pick) => pick != null && pick.startsWith(custom);

  /// What is typed of a custom fee, as it was typed; nothing for any other pick.
  static String typedOf(String? pick) => isCustom(pick) ? pick!.substring(custom.length) : '';

  /// A typed fee as the hub takes it, "12.50": dollars and cents (a "$" before them is let be), above
  /// nothing and under a thousand. Null while it is no such amount.
  static String? money(String text) {
    final said = text.trim().replaceFirst(RegExp(r'^\$\s*'), '');
    if (!RegExp(r'^(\d{1,3}(\.\d{0,2})?|\.\d{1,2})$').hasMatch(said)) return null;
    final amount = double.parse(said.startsWith('.') ? '0$said' : said);
    return amount > 0 ? amount.toStringAsFixed(2) : null;
  }

  /// The amount of a custom fee, once it is one ([money]); null for any other pick, and while it is not.
  static String? amountOf(String? pick) => isCustom(pick) ? money(typedOf(pick)) : null;

  /// The custom fee was picked and what it costs is not typed yet: nothing to send, and nothing to start
  /// a delivery on.
  static bool unfinished(String? pick) => isCustom(pick) && amountOf(pick) == null;

  /// Whether going from [was] to [pick] is somebody picking by hand. Typing the amount of a custom fee
  /// that is already picked is not: where the map asked for it, the map still picks for the next address.
  static bool byHand(String? was, String pick) => !(isCustom(was) && isCustom(pick));

  /// What the map's [answer] about an address picks on a form that holds [pick]: the band the address
  /// falls in, or the custom fee where it is further than the bands reach and the location offers one (what
  /// is typed of one already stays). Null leaves the form as it is.
  static String? found(FeeLookup? answer, DeliveryFees? fees, String? pick) {
    if (answer == null) return null;
    if (answer.band case final band?) return band.upTo;
    if (!answer.beyond || !(fees?.offersCustom ?? false)) return null;
    return isCustom(pick) ? pick : custom;
  }

  /// What an order's `delivery_fee` field is sent as: the band alone, and what the map said of the
  /// address when it was asked ([measured]). The hub fills in what the band costs. A custom fee is sent as
  /// its amount, the one amount a screen says.
  static Map<String, dynamic> field(String pick, {Measured? measured}) => {
    if (isCustom(pick)) 'custom': amountOf(pick) else 'up_to': pick == none ? null : pick,
    'measured': ?measured?.toJson(),
  };

  /// Whether the fee an order carries ([taken]) is one the list ([fees]) still offers at that price. One
  /// that is not stays on the order as it was taken, until somebody picks another. A custom fee is offered
  /// for as long as the location lets one be typed.
  static bool listed(OrderFee taken, DeliveryFees? fees) =>
      taken.none ||
      (fees != null &&
          fees.asks &&
          (taken.custom ? fees.offersCustom : fees.by == taken.by && fees.band(taken.upTo)?.fee == taken.amount));

  /// What a form picked, as it is to be sent: null when it leaves the order's fee ([taken]) as it is, and
  /// for a custom fee whose amount is not typed.
  static String? changed(String? pick, OrderFee? taken, DeliveryFees? fees) {
    if (pick == null || pick == kept || unfinished(pick)) return null;
    if (taken != null && listed(taken, fees)) {
      if (pick == taken.pick) return null;
      if (taken.custom && amountOf(pick) == money(taken.amount)) return null; // "12.5" is the 12.50 it carries
    }
    return pick;
  }
}
