import 'customers.dart' show phoneDigits;
import 'phone.dart' show formatPhoneNumber;

/// The guest list as the hub reckons it (`GET /reports/guests`, docs/guest-list.md): every customer who
/// ordered with a phone number in the last year, with how often they came, what they spent, when they were
/// last here and what they order most, and who is a regular, new, or stopped coming. The hub does every
/// sum; this is its answer read into names, the lists picked out of it ([guestsOf]), the order the screen
/// puts them in ([sortedGuests]) and the ones a name or number finds ([guestsNamed]). Amounts stay the
/// hub's own words ("109.65").

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
DateTime _day(Object? value) => DateTime.tryParse(_s(value)) ?? DateTime(2000);
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// A dish with how many of it: one of a guest's favourites, or one dish of a visit.
class GuestDish {
  const GuestDish({required this.name, this.item, this.count = 0});

  factory GuestDish.fromJson(Map<String, dynamic> json) => GuestDish(
    name: _s(json['name']),
    item: json['item'] is String ? json['item'] as String : null,
    count: _i(json['count']),
  );

  final String name;

  /// The dish's code on the menu; null for one the menu no longer has, or one that was typed in.
  final String? item;
  final int count;
}

/// One guest: a phone number that ordered in the year the list reads.
class Guest {
  const Guest({
    required this.phone,
    this.name = '',
    this.note = '',
    this.visits = 0,
    this.spent = '0.00',
    this.perVisit,
    required this.last,
    required this.first,
    this.sinceMs = 0,
    this.ordersEver = 0,
    this.lately = 0,
    this.regular = false,
    this.lapsed = false,
    this.isNew = false,
    this.favourites = const [],
  });

  factory Guest.fromJson(Map<String, dynamic> json) => Guest(
    phone: _s(json['phone']),
    name: _s(json['name']),
    note: _s(json['note']),
    visits: _i(json['visits']),
    spent: _s(json['spent'], '0.00'),
    perVisit: json['per_visit'] is String ? json['per_visit'] as String : null,
    last: _day(json['last']),
    first: _day(json['first']),
    sinceMs: _i(json['since_ms']),
    ordersEver: _i(json['orders_ever']),
    lately: _i(json['lately']),
    regular: json['regular'] == true,
    lapsed: json['lapsed'] == true,
    isNew: json['new'] == true,
    favourites: [for (final row in _rows(json['favourites'])) GuestDish.fromJson(row)],
  );

  /// The number's digits: what tells one guest from another.
  final String phone;

  /// The name on their latest order that has one; empty when none has.
  final String name;

  /// The line the restaurant keeps about them, written on the to-go form.
  final String note;

  /// Their orders of the year that had a dish on them.
  final int visits;

  /// What those came to before tax, charges and tips, less comps and discounts.
  final String spent;
  final String? perVisit;

  /// The days of their latest and of their first visit of the year.
  final DateTime last;
  final DateTime first;

  /// When the first order they ever placed was opened, and how many they ever placed: these two look past
  /// the year, and are what the to-go form says of a caller.
  final int sinceMs;
  final int ordersEver;

  /// Their visits in the days a regular is reckoned over.
  final int lately;
  final bool regular;

  /// Stopped coming.
  final bool lapsed;
  final bool isNew;

  /// The dishes they ordered most, the most ordered first.
  final List<GuestDish> favourites;

  num get money => double.tryParse(spent) ?? 0;

  /// The number as people read it.
  String get number => formatPhoneNumber(phone);

  /// What the list calls them: their name, or their number when no order of theirs has a name.
  String get called => name.isEmpty ? number : name;
}

/// What the whole list comes to.
class GuestTotals {
  const GuestTotals({
    this.guests = 0,
    this.visits = 0,
    this.spent = '0.00',
    this.perVisit,
    this.regulars = 0,
    this.lapsed = 0,
    this.fresh = 0,
  });

  factory GuestTotals.fromJson(Map<String, dynamic> json) => GuestTotals(
    guests: _i(json['guests']),
    visits: _i(json['visits']),
    spent: _s(json['spent'], '0.00'),
    perVisit: json['per_visit'] is String ? json['per_visit'] as String : null,
    regulars: _i(json['regulars']),
    lapsed: _i(json['lapsed']),
    fresh: _i(json['new']),
  );

  final int guests;
  final int visits;
  final String spent;
  final String? perVisit;
  final int regulars;
  final int lapsed;

  /// The new guests.
  final int fresh;
}

class GuestsReport {
  const GuestsReport({
    required this.first,
    required this.last,
    this.days = 365,
    this.regularVisits = 3,
    this.regularDays = 90,
    this.lapsedDays = 60,
    this.newDays = 30,
    this.nowMs = 0,
    this.guests = const [],
    this.totals = const GuestTotals(),
  });

  factory GuestsReport.fromJson(Map<String, dynamic> json) => GuestsReport(
    first: _day(json['first']),
    last: _day(json['last']),
    days: json['days'] is num ? _i(json['days']) : 365,
    regularVisits: json['regular_visits'] is num ? _i(json['regular_visits']) : 3,
    regularDays: json['regular_days'] is num ? _i(json['regular_days']) : 90,
    lapsedDays: json['lapsed_days'] is num ? _i(json['lapsed_days']) : 60,
    newDays: json['new_days'] is num ? _i(json['new_days']) : 30,
    nowMs: _i(json['now_ms']),
    guests: [for (final row in _rows(json['guests'])) Guest.fromJson(row)],
    totals: GuestTotals.fromJson((json['totals'] as Map?)?.cast<String, dynamic>() ?? const {}),
  );

  /// The days the list reads, the running one the last of them.
  final DateTime first;
  final DateTime last;
  final int days;

  /// What the three lists mean: a regular came [regularVisits] times or more in the last [regularDays]
  /// days; a guest who stopped coming came that often in the year and not for [lapsedDays] days; a new
  /// guest placed their first order ever in the last [newDays] days.
  final int regularVisits;
  final int regularDays;
  final int lapsedDays;
  final int newDays;
  final int nowMs;

  /// The one who spent most first.
  final List<Guest> guests;
  final GuestTotals totals;
}

/// One visit of a guest.
class GuestVisit {
  const GuestVisit({
    required this.orderId,
    required this.day,
    this.orderNo,
    this.openedMs = 0,
    this.kind = '',
    this.net = '0.00',
    this.dishes = const [],
  });

  factory GuestVisit.fromJson(Map<String, dynamic> json) => GuestVisit(
    orderId: _s(json['order_id']),
    day: _day(json['day']),
    orderNo: json['order_no'] is num ? _i(json['order_no']) : null,
    openedMs: _i(json['opened_ms']),
    kind: _s(json['kind']),
    net: _s(json['net'], '0.00'),
    dishes: [for (final row in _rows(json['dishes'])) GuestDish.fromJson(row)],
  );

  final String orderId;
  final DateTime day;
  final int? orderNo;
  final int openedMs;

  /// The kind of order ("takeout", "delivery", "dine_in").
  final String kind;
  final String net;
  final List<GuestDish> dishes;

  /// "2 Egg roll, General Tso's Chicken".
  String get dishWords =>
      [for (final dish in dishes) dish.count > 1 ? '${dish.count} ${dish.name}' : dish.name].join(', ');
}

/// One guest read closely (`GET /reports/guests/{phone}`).
class GuestDetail {
  const GuestDetail({required this.guest, this.noteBy = '', this.noteMs, this.latest = const []});

  factory GuestDetail.fromJson(Map<String, dynamic> json) => GuestDetail(
    guest: Guest.fromJson((json['guest'] as Map?)?.cast<String, dynamic>() ?? const {}),
    noteBy: _s(json['note_by']),
    noteMs: json['note_ms'] is num ? _i(json['note_ms']) : null,
    latest: [for (final row in _rows(json['latest'])) GuestVisit.fromJson(row)],
  );

  /// The row of the list, with more favourite dishes.
  final Guest guest;

  /// Who wrote the note and when; [noteMs] is null where there is no note.
  final String noteBy;
  final int? noteMs;

  /// Their latest visits, the newest first.
  final List<GuestVisit> latest;
}

/// The lists the screen picks out of all the guests.
enum GuestList {
  all('All'),
  regulars('Regulars'),
  lapsed('Stopped coming'),
  fresh('New');

  const GuestList(this.words);

  final String words;
}

/// The guests of one list.
List<Guest> guestsOf(Iterable<Guest> guests, GuestList list) => [
  for (final guest in guests)
    if (switch (list) {
      GuestList.all => true,
      GuestList.regulars => guest.regular,
      GuestList.lapsed => guest.lapsed,
      GuestList.fresh => guest.isNew,
    })
      guest,
];

/// The orders the list can stand in.
enum GuestSort {
  spent('Spent'),
  visits('Visits'),
  latest('Latest');

  const GuestSort(this.words);

  final String words;
}

/// [guests] in the order [sort] asks: by what they spent, by how often they came, or by who was here last,
/// the other figures telling equals apart and then the name.
List<Guest> sortedGuests(Iterable<Guest> guests, GuestSort sort) {
  int compare(Guest a, Guest b) {
    final spent = b.money.compareTo(a.money), visits = b.visits.compareTo(a.visits), last = b.last.compareTo(a.last);
    final order = switch (sort) {
      GuestSort.spent => [spent, visits, last],
      GuestSort.visits => [visits, spent, last],
      GuestSort.latest => [last, spent, visits],
    };
    for (final one in order) {
      if (one != 0) return one;
    }
    final named = a.called.toLowerCase().compareTo(b.called.toLowerCase());
    return named != 0 ? named : a.phone.compareTo(b.phone);
  }

  return guests.toList()..sort(compare);
}

/// The guests [words] find: every word in their name, whatever the case and the order, or, for words that
/// are a number, those digits anywhere in theirs ("555 0101", "0101").
List<Guest> guestsNamed(Iterable<Guest> guests, String words) {
  final wanted = words.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (wanted.isEmpty) return guests.toList();
  final digits = RegExp(r'^[\d\s().+-]+$').hasMatch(words.trim()) ? phoneDigits(words) : '';
  return [
    for (final guest in guests)
      if (digits.isNotEmpty ? guest.phone.contains(digits) : wanted.every(guest.name.toLowerCase().contains)) guest,
  ];
}
