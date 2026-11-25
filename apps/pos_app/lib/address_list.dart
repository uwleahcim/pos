/// A list of addresses while one is being typed (docs/delivery.md, "A list of addresses while typing"):
/// what the hub says the letters typed in an address box could become, which map service answered and how
/// much of its free amount for the month is left, and which map services the location turned on for it.
library;

/// One line of the list. [address] is what a tap puts in the box; [main] and [rest] are the same in two
/// parts where they are told apart ("12 Elm Street" and "Winchester, MA"). [from] says where it is from:
/// `customer` (an earlier delivery of the customer on the form), `orders` (another delivery of the
/// restaurant's) or the name of a map service.
class AddressSuggestion {
  const AddressSuggestion({required this.address, this.main = '', this.rest = '', this.from = 'orders'});

  /// Null for a line with no address in it.
  static AddressSuggestion? of(Object? json) {
    if (json is! Map) return null;
    final address = json['address'], main = json['main'], rest = json['rest'], from = json['from'];
    if (address is! String || address.trim().isEmpty) return null;
    return AddressSuggestion(
      address: address.trim(),
      main: main is String && main.trim().isNotEmpty ? main.trim() : address.trim(),
      rest: rest is String ? rest.trim() : '',
      from: from is String ? from : 'orders',
    );
  }

  final String address;
  final String main;
  final String rest;
  final String from;

  /// One of the restaurant's own earlier deliveries, not a map service's answer.
  bool get own => from == 'customer' || from == 'orders';

  /// An earlier delivery of the customer on the form.
  bool get theirs => from == 'customer';
}

/// A count with its thousands told apart: 94988 is "94,988".
String counted(int count) {
  final digits = count.abs().toString();
  final out = StringBuffer(count < 0 ? '-' : '');
  for (var at = 0; at < digits.length; at++) {
    if (at > 0 && (digits.length - at) % 3 == 0) out.write(',');
    out.write(digits[at]);
  }
  return out.toString();
}

/// The hub's answer for the letters typed (`POST /addresses/suggest`).
class AddressSuggestions {
  const AddressSuggestions({
    this.typed = '',
    this.suggestions = const [],
    this.credit,
    this.service,
    this.title,
    this.left,
    this.monthlyMost,
  });

  factory AddressSuggestions.fromJson(Map<String, dynamic> json) {
    final listed = json['suggestions'], credit = json['credit'], typed = json['typed'];
    final service = json['service'], title = json['title'], left = json['left'], most = json['monthly_most'];
    return AddressSuggestions(
      typed: typed is String ? typed : '',
      suggestions: [
        if (listed is List)
          for (final one in listed) ?AddressSuggestion.of(one),
      ],
      credit: credit is String && credit.isNotEmpty ? credit : null,
      service: service is String && service.isNotEmpty ? service : null,
      title: title is String && title.isNotEmpty ? title : null,
      left: left is int && left >= 0 ? left : null,
      monthlyMost: most is int && most > 0 ? most : null,
    );
  }

  /// The letters the list is for, on one line.
  final String typed;
  final List<AddressSuggestion> suggestions;

  /// The name a map service's terms want shown with a list that holds one of its answers ("Google Maps").
  final String? credit;

  /// Which map service answered (`google`, `mapbox`, `azure`), and what a screen calls it; null for a list
  /// of the restaurant's own addresses, and from a hub older than several services.
  final String? service;
  final String? title;

  /// How many lookups that service has left free this month, of how many, by the hub's own count; null
  /// where the hub did not say.
  final int? left;
  final int? monthlyMost;

  /// How much of the service's free amount is left, from 1 to 0, for the ring of its badge; null where the
  /// hub did not say.
  double? get share {
    final left = this.left, most = monthlyMost;
    if (left == null || most == null) return null;
    return (left / most).clamp(0.0, 1.0);
  }

  /// How much of the service's free amount is left, in words for the badge's tooltip and for a reader; null
  /// where the hub did not say.
  String? get leftWords {
    final left = this.left;
    if (left == null) return null;
    final most = monthlyMost;
    final lookups = left == 1 && most == null ? 'free lookup' : 'free lookups';
    final count = left == 0 && most == null ? 'no' : counted(left);
    return most == null ? '$count $lookups left this month' : '$count of ${counted(most)} $lookups left this month';
  }
}

/// How a box asks for its list: the letters typed so far. Null when there is nothing to list from (an
/// older hub).
typedef AddressSource = Future<AddressSuggestions?> Function(String typed);

/// One map service the list can ask, as the hub says it stands (`services` of `/settings/address_list`).
class AddressService {
  const AddressService({
    required this.name,
    this.title = '',
    this.credit = '',
    this.on = false,
    this.key = false,
    this.left,
    this.monthlyMost,
    this.usedUp = false,
    this.resting = false,
  });

  /// Null for what names no service.
  static AddressService? of(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], title = json['title'], credit = json['credit'];
    final left = json['left'], most = json['monthly_most'];
    if (name is! String || name.isEmpty) return null;
    return AddressService(
      name: name,
      title: title is String && title.isNotEmpty ? title : name,
      credit: credit is String ? credit : '',
      on: json['on'] == true,
      key: json['key'] == true,
      left: left is int && left >= 0 ? left : null,
      monthlyMost: most is int && most >= 0 ? most : null,
      usedUp: json['used_up'] == true,
      resting: json['resting'] == true,
    );
  }

  /// The hub's name for it: `google`, `mapbox`, `azure`.
  final String name;

  /// What a screen calls it ("Google Maps").
  final String title;

  /// The words its terms want under a list with one of its answers.
  final String credit;

  /// A manager turned it on for the list.
  final bool on;

  /// The hub has a key for it.
  final bool key;

  /// Both: its turn comes, and what is typed in an address box is sent to it.
  bool get asks => on && key;

  /// How many lookups it has left free this month, of how many, by the hub's own count; null where the hub
  /// has no key for it, and from a hub older than the count.
  final int? left;
  final int? monthlyMost;

  /// Its free lookups for the month are used up: the next service is asked until the month turns.
  final bool usedUp;

  /// It gave no answer a moment ago, and the next service is asked meanwhile.
  final bool resting;

  AddressService turned({required bool on}) => AddressService(
    name: name,
    title: title,
    credit: credit,
    on: on,
    key: key,
    left: left,
    monthlyMost: monthlyMost,
    usedUp: usedUp,
    resting: resting,
  );

  /// How it stands, in a line for the setting.
  String get words {
    if (!key) return 'No key on this hub yet (Keys and connections)';
    final free = left == null
        ? null
        : monthlyMost == null
        ? '${counted(left!)} free lookups left this month'
        : '${counted(left!)} of ${counted(monthlyMost!)} free lookups left this month';
    if (usedUp) return 'Its free lookups for this month are used up: the next one is asked until the month turns';
    if (on && resting) return 'Not answering right now: the next one is asked meanwhile';
    if (!on) return free == null ? 'Off' : 'Off · $free';
    return free ?? 'On';
  }
}

/// Which map services the list asks as well as the restaurant's own deliveries, as the location has it
/// (`/settings/address_list`): every service the hub knows, in the order they are asked. The first that is
/// turned on and has a key is asked, and the next only when the one before it gave no answer. The order is
/// the location's own where the hub keeps one ([ordered]).
class AddressListSetting {
  const AddressListSetting({this.services = const [], this.nearMiles, this.originSet, this.ordered = false});

  factory AddressListSetting.fromJson(Map<String, dynamic> json) {
    final listed = json['services'];
    final near = json['near_miles'];
    final nearMiles = near is num && near > 0 ? near.toDouble() : null;
    final originSet = json['origin_set'] is bool ? json['origin_set'] as bool : null;
    if (listed is List) {
      return AddressListSetting(
        services: [for (final one in listed) ?AddressService.of(one)],
        nearMiles: nearMiles,
        originSet: originSet,
        ordered: json['order'] is List,
      );
    }
    // a hub from before there were several: Google alone, and no count of what is left
    final credit = json['credit'];
    final name = credit is String && credit.isNotEmpty ? credit : 'Google Maps';
    return AddressListSetting(
      services: [
        AddressService(
          name: 'google',
          title: name,
          credit: name,
          on: json['google'] == true,
          key: json['service'] == true,
        ),
      ],
      nearMiles: nearMiles,
      originSet: originSet,
    );
  }

  final List<AddressService> services;

  /// How far around the restaurant a map service's addresses come first, in miles: a preference, and
  /// further ones are still listed. Null on a hub that does not say (an older one, with its own distance).
  final double? nearMiles;

  /// Whether the hub knows the restaurant's own address (Location, Delivery fee), which "near" is near to;
  /// null on a hub that does not say.
  final bool? originSet;

  /// The hub keeps the order the services are asked in as the location's own, and a manager may change it
  /// ([services] stand in it). False on a hub older than that, which asks them in its own order.
  final bool ordered;

  /// The distances the slider for [nearMiles] stops at, each stop as wide as the next: a quarter of a mile
  /// apart up to three miles, half a mile up to six, a mile up to twelve, and two miles up to twenty. So
  /// what is close by takes most of the slider and is set finest (the owner's words, 2026-11-25). A hub
  /// starts on four miles, a delivery's usual reach.
  static final List<double> nearStops = List.unmodifiable([
    for (var miles = 0.25; miles <= 3; miles += 0.25) miles,
    for (var miles = 3.5; miles <= 6; miles += 0.5) miles,
    for (var miles = 7.0; miles <= 12; miles += 1) miles,
    for (var miles = 14.0; miles <= 20; miles += 2) miles,
  ]);

  /// The distances the slider's scale names under it.
  static const nearMarks = [1.0, 3.0, 6.0, 10.0, 20.0];

  /// Where a distance stands on the slider, counted in stops from its start: one between two stops stands
  /// between them, and one past either end at that end.
  static double nearPlace(double miles) {
    final stops = nearStops;
    if (miles <= stops.first) return 0;
    for (var at = 1; at < stops.length; at++) {
      if (miles <= stops[at]) return at - 1 + (miles - stops[at - 1]) / (stops[at] - stops[at - 1]);
    }
    return stops.length - 1.0;
  }

  /// The distance at a place on the slider: the stop nearest to it.
  static double nearAt(double place) => nearStops[place.round().clamp(0, nearStops.length - 1)];

  /// A number of miles in words: "4 miles", "2.5 miles", "0.25 miles", "1 mile".
  static String miles(double miles) {
    final said = miles.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$said ${miles == 1 ? 'mile' : 'miles'}';
  }

  AddressService? named(String name) {
    for (final service in services) {
      if (service.name == name) return service;
    }
    return null;
  }

  /// A manager turned Google on for the list.
  bool get google => named('google')?.on ?? false;

  /// The services a manager turned on, and of those the ones the hub has a key for, in their order.
  List<AddressService> get on => [
    for (final service in services)
      if (service.on) service,
  ];
  List<AddressService> get asking => [
    for (final service in services)
      if (service.asks) service,
  ];

  /// What is typed in an address box is sent to a map service.
  bool get asks => asking.isNotEmpty;

  /// The same with these services turned on or off; one that is not named stays as it is. With [near],
  /// what is near reaches that far. With [order], the services' names in the order they are to be asked:
  /// one it leaves out keeps its place after those it names, and a hub that keeps no order keeps its own.
  AddressListSetting turned(Map<String, bool> on, {double? near, List<String>? order}) {
    final first = [
      if (ordered && order != null)
        for (final name in order.toSet()) ?named(name),
    ];
    return AddressListSetting(
      services: [
        for (final service in first) service.turned(on: on[service.name] ?? service.on),
        for (final service in services)
          if (!first.contains(service)) service.turned(on: on[service.name] ?? service.on),
      ],
      nearMiles: nearMiles == null ? null : near ?? nearMiles, // a hub that does not say is sent none
      originSet: originSet,
      ordered: ordered,
    );
  }

  /// As a manager saves it. What the hub has is the hub's to say, and is not sent; the order goes only to a
  /// hub that keeps one.
  Map<String, dynamic> toJson() => {
    for (final service in services) service.name: service.on,
    'near_miles': ?nearMiles,
    if (ordered) 'order': [for (final service in services) service.name],
  };
}

/// How one try of a map service went (`POST /settings/address_list/try`).
class AddressListTry {
  const AddressListTry({this.ok = false, this.found = 0, this.message = '', this.left});

  factory AddressListTry.fromJson(Map<String, dynamic> json) => AddressListTry(
    ok: json['ok'] == true,
    found: json['found'] is int ? json['found'] as int : 0,
    message: json['message'] is String ? json['message'] as String : '',
    left: json['left'] is int ? json['left'] as int : null,
  );

  final bool ok;

  /// How many addresses the service listed.
  final int found;

  /// Why it gave none, in words for the manager.
  final String message;

  /// How many lookups the service has left free this month after this one; null where the hub did not say.
  final int? left;
}
