import 'customers.dart' show phoneDigits;
import 'phone.dart' show formatPhoneNumber;

/// The guest list as the hub reckons it (`GET /reports/guests`, docs/guest-list.md): every customer who
/// ordered with a phone number in the last year, with how often they came, what they spent, when they were
/// last here and what they order most, and who is a regular, new, or stopped coming. The hub does every
/// sum; this is its answer read into names, the lists picked out of it ([guestsOf]), the order the screen
/// puts them in ([sortedGuests]) and the ones a name or number finds ([guestsNamed]). Amounts stay the
/// hub's own words ("109.65"). Beside each guest stand the note and the tags the restaurant keeps about
/// them; a manager writes both from the list ([GuestKept] is what the hub then keeps), and a tag is a list
/// of its own ([guestsTagged]).

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
DateTime _day(Object? value) => DateTime.tryParse(_s(value)) ?? DateTime(2000);
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];
List<String> _words(Object? value) => [
  if (value is List)
    for (final word in value)
      if (word is String) word,
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
    this.tags = const [],
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
    tags: _words(json['tags']),
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

  /// The line the restaurant keeps about them, written on the to-go form or from the guest list.
  final String note;

  /// The tags a manager put on them ("VIP"), in the order of the alphabet.
  final List<String> tags;

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

  /// Whether they carry [tag], whatever its capitals.
  bool carries(String tag) => tags.any((mine) => mine.toLowerCase() == tag.toLowerCase());

  /// The same guest with the note and the tags as the hub keeps them now.
  Guest kept({required String note, required List<String> tags}) => Guest(
    phone: phone,
    name: name,
    note: note,
    tags: tags,
    visits: visits,
    spent: spent,
    perVisit: perVisit,
    last: last,
    first: first,
    sinceMs: sinceMs,
    ordersEver: ordersEver,
    lately: lately,
    regular: regular,
    lapsed: lapsed,
    isNew: isNew,
    favourites: favourites,
  );
}

/// A tag there is to offer, with how many guests of the list carry it.
class GuestTag {
  const GuestTag(this.tag, [this.guests = 0]);

  factory GuestTag.fromJson(Map<String, dynamic> json) => GuestTag(_s(json['tag']), _i(json['guests']));

  final String tag;
  final int guests;
}

/// What the hub keeps about a guest after a manager wrote it from the list (`PUT /reports/guests/<digits>`):
/// the note and the tags, each with who wrote it last and when.
class GuestKept {
  const GuestKept({
    required this.phone,
    this.note = '',
    this.noteBy = '',
    this.noteMs,
    this.tags = const [],
    this.tagsBy = '',
    this.tagsMs,
  });

  factory GuestKept.fromJson(Map<String, dynamic> json) => GuestKept(
    phone: _s(json['phone']),
    note: _s(json['note']),
    noteBy: _s(json['note_by']),
    noteMs: json['note_ms'] is num ? _i(json['note_ms']) : null,
    tags: _words(json['tags']),
    tagsBy: _s(json['tags_by']),
    tagsMs: json['tags_ms'] is num ? _i(json['tags_ms']) : null,
  );

  final String phone;
  final String note;
  final String noteBy;
  final int? noteMs;
  final List<String> tags;
  final String tagsBy;
  final int? tagsMs;
}

/// What the box that tags a guest is handed where the guest list was not read, at a reservation or a party
/// on the waitlist (`GET /reports/guests/tags`): the [tags] on offer, what a guest's tags are held to, and
/// the tags the number [carried] when it was asked. The number need not have ordered.
class TagBox {
  const TagBox({
    this.tags = const [],
    this.tagMax = 24,
    this.tagsMost = 6,
    this.phone = '',
    this.carried = const [],
    this.tagsBy = '',
    this.tagsMs,
  });

  factory TagBox.fromJson(Map<String, dynamic> json) => TagBox(
    tags: [for (final row in _rows(json['tags'])) GuestTag.fromJson(row)],
    tagMax: json['tag_max'] is num ? _i(json['tag_max']) : 24,
    tagsMost: json['tags_most'] is num ? _i(json['tags_most']) : 6,
    phone: _s(json['phone']),
    carried: _words(json['carried']),
    tagsBy: _s(json['tags_by']),
    tagsMs: json['tags_ms'] is num ? _i(json['tags_ms']) : null,
  );

  /// Every tag there is to offer, the one most numbers carry first.
  final List<GuestTag> tags;
  final int tagMax;
  final int tagsMost;

  /// The number's digits, as the hub read them.
  final String phone;

  /// The tags the number carries now, and who put them on last and when.
  final List<String> carried;
  final String tagsBy;
  final int? tagsMs;
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
    this.tags = const [],
    this.keeps = false,
    this.noteMax = 120,
    this.tagMax = 24,
    this.tagsMost = 6,
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
    tags: [
      for (final row in _rows(json['tags']))
        if (_s(row['tag']).isNotEmpty) GuestTag.fromJson(row),
    ],
    keeps: json['tags'] is List,
    noteMax: json['note_max'] is num ? _i(json['note_max']) : 120,
    tagMax: json['tag_max'] is num ? _i(json['tag_max']) : 24,
    tagsMost: json['tags_most'] is num ? _i(json['tags_most']) : 6,
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

  /// Every tag there is to offer: the ones some guest carries and the standard ones, the one most guests
  /// of the list carry first.
  final List<GuestTag> tags;

  /// Whether this hub keeps tags, and takes a note written from the list. One older than that does not
  /// say [tags] at all: the list is then only read, as it was.
  final bool keeps;

  /// What the hub holds a note and the tags to: the letters of a note, the letters of a tag, and how many
  /// tags a guest carries at most.
  final int noteMax;
  final int tagMax;
  final int tagsMost;

  /// The tags some guest of the list carries: each is a list of its own.
  List<GuestTag> get carried => [
    for (final tag in tags)
      if (tag.guests > 0) tag,
  ];

  /// The list after the hub kept [now] about one of its guests: that guest with the note and the tags as
  /// they are kept, and every tag counted again. A tag nobody of the list carries any more is still one to
  /// offer until the list is read again.
  GuestsReport withKept(GuestKept now) {
    final changed = [
      for (final guest in guests) guest.phone == now.phone ? guest.kept(note: now.note, tags: now.tags) : guest,
    ];
    final names = <String>[for (final tag in tags) tag.tag];
    for (final tag in now.tags) {
      if (names.every((known) => known.toLowerCase() != tag.toLowerCase())) names.add(tag);
    }
    final counted = [for (final name in names) GuestTag(name, changed.where((guest) => guest.carries(name)).length)]
      ..sort((a, b) {
        final most = b.guests.compareTo(a.guests);
        return most != 0 ? most : a.tag.toLowerCase().compareTo(b.tag.toLowerCase());
      });
    return GuestsReport(
      first: first,
      last: last,
      days: days,
      regularVisits: regularVisits,
      regularDays: regularDays,
      lapsedDays: lapsedDays,
      newDays: newDays,
      nowMs: nowMs,
      guests: changed,
      totals: totals,
      tags: counted,
      keeps: keeps,
      noteMax: noteMax,
      tagMax: tagMax,
      tagsMost: tagsMost,
    );
  }
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
  const GuestDetail({
    required this.guest,
    this.noteBy = '',
    this.noteMs,
    this.tagsBy = '',
    this.tagsMs,
    this.latest = const [],
  });

  factory GuestDetail.fromJson(Map<String, dynamic> json) => GuestDetail(
    guest: Guest.fromJson((json['guest'] as Map?)?.cast<String, dynamic>() ?? const {}),
    noteBy: _s(json['note_by']),
    noteMs: json['note_ms'] is num ? _i(json['note_ms']) : null,
    tagsBy: _s(json['tags_by']),
    tagsMs: json['tags_ms'] is num ? _i(json['tags_ms']) : null,
    latest: [for (final row in _rows(json['latest'])) GuestVisit.fromJson(row)],
  );

  /// The row of the list, with more favourite dishes.
  final Guest guest;

  /// Who wrote the note and when; [noteMs] is null where there is no note.
  final String noteBy;
  final int? noteMs;

  /// Who last put the tags on and when; [tagsMs] is null where there is no tag.
  final String tagsBy;
  final int? tagsMs;

  /// Their latest visits, the newest first.
  final List<GuestVisit> latest;

  /// The same reading with the note and the tags as the hub keeps them now.
  GuestDetail withKept(GuestKept now) => GuestDetail(
    guest: guest.kept(note: now.note, tags: now.tags),
    noteBy: now.noteBy,
    noteMs: now.noteMs,
    tagsBy: now.tagsBy,
    tagsMs: now.tagsMs,
    latest: latest,
  );
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

/// The guests who carry [tag]; every guest with none asked for.
List<Guest> guestsTagged(Iterable<Guest> guests, String? tag) => [
  for (final guest in guests)
    if (tag == null || guest.carries(tag)) guest,
];

/// The tags as a manager picked and typed them, tidied the way the hub keeps them: each on one line, each
/// once whatever its capitals (one of [known] spelt as it is known), in the order of the alphabet.
List<String> tidyTags(Iterable<String> tags, [Iterable<String> known = const []]) {
  final spelt = <String, String>{};
  for (final tag in known) {
    spelt.putIfAbsent(tag.toLowerCase(), () => tag);
  }
  final kept = <String, String>{};
  for (final tag in tags) {
    final words = tag.trim().split(RegExp(r'\s+')).join(' ');
    if (words.isEmpty) continue;
    kept.putIfAbsent(words.toLowerCase(), () => spelt[words.toLowerCase()] ?? words);
  }
  return kept.values.toList()..sort((a, b) {
    final order = a.toLowerCase().compareTo(b.toLowerCase());
    return order != 0 ? order : a.compareTo(b);
  });
}

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
