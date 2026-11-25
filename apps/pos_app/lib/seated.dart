import 'package:flutter/foundation.dart';

/// Who sits at a table, as the hub knows it from the reservation book and the waitlist: what the check of
/// a table shows whoever serves it (docs/guest-list.md, "At the table"). A party is seated on a check when
/// the host sits it down from its reservation or from the waitlist, or lets it join a table that is seated.
/// None of it is on the check itself: it is read from the hub while the check is open.

/// One party seated on a check.
@immutable
class SeatedParty {
  const SeatedParty({
    required this.name,
    this.size = 0,
    this.note = '',
    this.tags = const [],
    this.booked = false,
    this.key = '',
    this.listed = false,
    this.pays = false,
    this.points,
  });

  factory SeatedParty.fromJson(Map<String, dynamic> json) => SeatedParty(
    name: (json['name'] as String? ?? '').trim(),
    size: (json['size'] as num?)?.toInt() ?? 0,
    note: (json['note'] as String? ?? '').trim(),
    tags: [
      if (json['tags'] case final List tags)
        for (final tag in tags)
          if (tag is String && tag.trim().isNotEmpty) tag,
    ],
    booked: json['from'] == 'reservation',
    key: json['key'] is String ? json['key'] as String : '',
    listed: json['listed'] == true,
    pays: json['pays'] == true,
    points: json['points'] is num ? (json['points'] as num).toInt() : null,
  );

  /// The name on the reservation or on the line of the waitlist.
  final String name;

  /// How many they were booked or listed as.
  final int size;

  /// The note written on the reservation or the party ("Window table, birthday"); not the one line the
  /// restaurant keeps about a customer.
  final String note;

  /// The tags their number carries in the guest list ("VIP").
  final List<String> tags;

  /// From a reservation; false for a party of the waitlist, and for a guest whose number was typed on a
  /// check that was merged into this one.
  final bool booked;

  /// What the hub knows this party by when it is told who pays (`PosApi.sayPayer`); empty from a hub that
  /// takes no such word. It is no phone number and says nothing of the guest.
  final String key;

  /// The party left a phone number, so it is a guest of the guest list and can be the one who pays. The
  /// number itself is not told.
  final bool listed;

  /// Somebody said this party pays the check: its money counts for them in the guest list.
  final bool pays;

  /// The points the party's guest has now (docs/points.md): a count, and nothing else of them. Null where
  /// no rate was ever set, for a party that left no number, and from a hub older than points.
  final int? points;

  /// Whether there is anything of this party to show.
  bool get says => name.isNotEmpty || note.isNotEmpty || tags.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SeatedParty &&
      other.name == name &&
      other.size == size &&
      other.note == note &&
      other.booked == booked &&
      other.key == key &&
      other.listed == listed &&
      other.pays == pays &&
      other.points == points &&
      listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(name, size, note, booked, key, listed, pays, points, Object.hashAll(tags));
}

/// The guests of one table's check: the parties seated on it, the first to sit first, and their tags
/// together. From a hub that says the tags and not yet who (`GET /orders/{id}/tags` alone), [parties] is
/// empty and [tags] is all there is.
@immutable
class TableGuests {
  const TableGuests({this.parties = const [], this.tags = const [], this.takesPayer = false});

  factory TableGuests.fromJson(Map<String, dynamic> json) => TableGuests(
    parties: [
      if (json['parties'] case final List parties)
        for (final party in parties)
          if (party is Map<String, dynamic>) SeatedParty.fromJson(party),
    ].where((party) => party.says).toList(),
    tags: [
      if (json['tags'] case final List tags)
        for (final tag in tags)
          if (tag is String && tag.trim().isNotEmpty) tag,
    ],
    takesPayer: json['payer'] == true,
  );

  /// Nobody was seated on the check, or the hub does not know.
  static const none = TableGuests();

  final List<SeatedParty> parties;
  final List<String> tags;

  /// The hub can be told which guest pays the check; false from a hub older than that.
  final bool takesPayer;

  /// The guests who can be said to pay: the ones that left a number. Worth saying only when they are two or
  /// more: a check's only guest pays it without a word (docs/guest-list.md, "Who pays").
  List<SeatedParty> get payers => [
    for (final party in parties)
      if (party.listed && party.key.isNotEmpty) party,
  ];

  /// Whether this check's strip lets a tap say who pays: the hub takes the word, and two or more of its
  /// guests could be the one.
  bool get asksPayer => takesPayer && payers.length > 1;

  bool get isEmpty => parties.isEmpty && tags.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is TableGuests &&
      other.takesPayer == takesPayer &&
      listEquals(other.parties, parties) &&
      listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(takesPayer, Object.hashAll(parties), Object.hashAll(tags));
}
