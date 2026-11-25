/// A list of addresses while one is being typed (docs/delivery.md, "A list of addresses while typing"):
/// what the hub says the letters typed in an address box could become.
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

/// The hub's answer for the letters typed (`POST /addresses/suggest`).
class AddressSuggestions {
  const AddressSuggestions({this.typed = '', this.suggestions = const [], this.credit});

  factory AddressSuggestions.fromJson(Map<String, dynamic> json) {
    final listed = json['suggestions'], credit = json['credit'], typed = json['typed'];
    return AddressSuggestions(
      typed: typed is String ? typed : '',
      suggestions: [
        if (listed is List)
          for (final one in listed) ?AddressSuggestion.of(one),
      ],
      credit: credit is String && credit.isNotEmpty ? credit : null,
    );
  }

  /// The letters the list is for, on one line.
  final String typed;
  final List<AddressSuggestion> suggestions;

  /// The name a map service's terms want shown with a list that holds one of its answers ("Google Maps").
  final String? credit;
}

/// How a box asks for its list: the letters typed so far. Null when there is nothing to list from (an
/// older hub).
typedef AddressSource = Future<AddressSuggestions?> Function(String typed);

/// Whether the list asks a map service as well as the restaurant's own deliveries, as the location has it
/// (`/settings/address_list`).
class AddressListSetting {
  const AddressListSetting({this.google = false, this.service = false, this.asks = false, this.credit = 'Google Maps'});

  factory AddressListSetting.fromJson(Map<String, dynamic> json) => AddressListSetting(
    google: json['google'] == true,
    service: json['service'] == true,
    asks: json['asks'] == true,
    credit: json['credit'] is String ? json['credit'] as String : 'Google Maps',
  );

  /// A manager turned the map service on for the list.
  final bool google;

  /// The hub has a map service that lists addresses (a Google Maps key).
  final bool service;

  /// Both: what is typed in an address box is sent to the service.
  final bool asks;

  /// The service's name in its own words.
  final String credit;

  /// As a manager saves it. What the hub has is the hub's to say, and is not sent.
  Map<String, dynamic> toJson() => {'google': google};
}

/// How one try of the map service went (`POST /settings/address_list/try`).
class AddressListTry {
  const AddressListTry({this.ok = false, this.found = 0, this.message = ''});

  factory AddressListTry.fromJson(Map<String, dynamic> json) => AddressListTry(
    ok: json['ok'] == true,
    found: json['found'] is int ? json['found'] as int : 0,
    message: json['message'] is String ? json['message'] as String : '',
  );

  final bool ok;

  /// How many addresses the service listed.
  final int found;

  /// Why it gave none, in words for the manager.
  final String message;
}
