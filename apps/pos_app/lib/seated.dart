import 'package:flutter/foundation.dart';

/// Who sits at a table, as the hub knows it from the reservation book and the waitlist: what the check of
/// a table shows whoever serves it (docs/guest-list.md, "At the table"). A party is seated on a check when
/// the host sits it down from its reservation or from the waitlist, or lets it join a table that is seated.
/// None of it is on the check itself: it is read from the hub while the check is open.

/// One party seated on a check.
@immutable
class SeatedParty {
  const SeatedParty({required this.name, this.size = 0, this.note = '', this.tags = const [], this.booked = false});

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

  /// From a reservation; false for a party of the waitlist.
  final bool booked;

  /// Whether there is anything of this party to show.
  bool get says => name.isNotEmpty || note.isNotEmpty || tags.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SeatedParty &&
      other.name == name &&
      other.size == size &&
      other.note == note &&
      other.booked == booked &&
      listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(name, size, note, booked, Object.hashAll(tags));
}

/// The guests of one table's check: the parties seated on it, the first to sit first, and their tags
/// together. From a hub that says the tags and not yet who (`GET /orders/{id}/tags` alone), [parties] is
/// empty and [tags] is all there is.
@immutable
class TableGuests {
  const TableGuests({this.parties = const [], this.tags = const []});

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
  );

  /// Nobody was seated on the check, or the hub does not know.
  static const none = TableGuests();

  final List<SeatedParty> parties;
  final List<String> tags;

  bool get isEmpty => parties.isEmpty && tags.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is TableGuests && listEquals(other.parties, parties) && listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(Object.hashAll(parties), Object.hashAll(tags));
}
