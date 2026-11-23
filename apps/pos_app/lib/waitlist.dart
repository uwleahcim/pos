import 'table_timers.dart' show TimerLevel;

/// The waitlist as the hub answers it (docs/waitlist.md): the parties waiting for a table tonight, in the
/// order they came, and the ones that went off the list earlier. The hub makes every rule and stamps every
/// time with its own clock; this is its answers read into names, and the words the screens say about them.

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value, [int or = 0]) => value is num ? value.toInt() : or;
int? _ms(Object? value) => value is num ? value.toInt() : null;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];
List<String> _words(Object? value) => [
  if (value is List)
    for (final word in value)
      if (word is String && word.trim().isNotEmpty) word,
];

/// A party that is about to sit down: one off the waitlist, or one with a reservation
/// (docs/reservations.md). The floor map seats either the same way.
abstract interface class ArrivingParty {
  String get id;
  String get name;

  /// How many guests.
  int get size;

  /// "Chen, party of 4".
  String get label;
}

/// One party on the list.
class WaitParty implements ArrivingParty {
  const WaitParty({
    required this.id,
    required this.name,
    required this.size,
    this.phone = '',
    this.quotedMinutes,
    this.note = '',
    this.tags = const [],
    this.atMs = 0,
    this.by = '',
    this.calledMs,
    this.status = 'waiting',
    this.dueMs,
    this.amberMs,
    this.table = '',
    this.tableLabel = '',
    this.orderId = '',
    this.leftWhy = '',
    this.endedBy = '',
    this.waitedMinutes,
  });

  factory WaitParty.fromJson(Map<String, dynamic> json) => WaitParty(
    id: _s(json['id']),
    name: _s(json['name']),
    size: _i(json['size'], 1),
    phone: _s(json['phone']),
    quotedMinutes: _ms(json['quoted_minutes']),
    note: _s(json['note']),
    tags: _words(json['tags']),
    atMs: _i(json['at_ms']),
    by: _s(json['by']),
    calledMs: _ms(json['called_ms']),
    status: _s(json['status'], 'waiting'),
    dueMs: _ms(json['due_ms']),
    amberMs: _ms(json['amber_ms']),
    table: _s(json['table']),
    tableLabel: _s(json['table_label']),
    orderId: _s(json['order_id']),
    leftWhy: _s(json['left_why']),
    endedBy: _s(json['ended_by']),
    waitedMinutes: _ms(json['waited_minutes']),
  );

  @override
  final String id;
  @override
  final String name;

  /// How many guests.
  @override
  final int size;
  final String phone;

  /// The wait they were told, counted from when they came; null when no time was given.
  final int? quotedMinutes;
  final String note;

  /// The tags a manager put on [phone] in the guest list ("VIP"; docs/guest-list.md, "Where the tags
  /// show"): the number's, read by the hub each time, not kept with the party. None for a party that left
  /// no number, and from a hub older than this.
  final List<String> tags;

  /// When they were put on the list, and who by.
  final int atMs;
  final String by;

  /// When they were told their table is ready; null when they were not.
  final int? calledMs;

  /// `waiting`, `seated` or `left`.
  final String status;

  /// When the wait they were told is up (red from then), and when it is nearly up (amber from then).
  final int? dueMs;
  final int? amberMs;

  /// Where they sat down, and the check opened for them.
  final String table;
  final String tableLabel;
  final String orderId;

  /// `left` or `no_show`, for a party that went off the list without a table.
  final String leftWhy;

  /// Who sat them down or took them off the list.
  final String endedBy;

  /// How long they waited, for a party that is off the list.
  final int? waitedMinutes;

  bool get isWaiting => status == 'waiting';
  bool get isSeated => status == 'seated';

  /// "Chen, party of 4".
  @override
  String get label => '$name, party of $size';

  /// The whole minutes they have waited at [nowMs] (the hub's clock).
  int waitedAt(int nowMs) => nowMs <= atMs ? 0 : (nowMs - atMs) ~/ 60000;

  /// How their wait stands at [nowMs]: running, nearly the time they were told (amber), or past it (red).
  /// A party that was told no time is never late.
  TimerLevel levelAt(int nowMs) {
    final due = dueMs, amber = amberMs;
    if (due != null && nowMs >= due) return TimerLevel.late;
    if (amber != null && nowMs >= amber) return TimerLevel.warn;
    return TimerLevel.ok;
  }

  /// The next moment after [nowMs] at which what is shown of this party changes by the clock alone: a minute
  /// of its wait, or its colour.
  int nextChange(int nowMs) {
    var next = nowMs < atMs ? atMs + 60000 : atMs + (waitedAt(nowMs) + 1) * 60000;
    for (final at in [amberMs, dueMs]) {
      if (at != null && at > nowMs && at < next) next = at;
    }
    return next;
  }
}

/// How the night's list adds up.
class WaitCounts {
  const WaitCounts({this.waiting = 0, this.guests = 0, this.seated = 0, this.left = 0, this.averageWaitMinutes});

  factory WaitCounts.fromJson(Map<String, dynamic> json) => WaitCounts(
    waiting: _i(json['waiting']),
    guests: _i(json['guests']),
    seated: _i(json['seated']),
    left: _i(json['left']),
    averageWaitMinutes: _ms(json['average_wait_minutes']),
  );

  /// The parties waiting, and the guests in them.
  final int waiting;
  final int guests;

  /// The parties that sat down tonight, and the ones that went off the list without a table.
  final int seated;
  final int left;

  /// How long the parties that sat down waited, on average.
  final int? averageWaitMinutes;
}

/// Tonight's waitlist.
class Waitlist {
  const Waitlist({
    this.waiting = const [],
    this.earlier = const [],
    this.counts = const WaitCounts(),
    this.quotes = standardQuotes,
    this.mostGuests = 60,
    this.nameMax = 24,
    this.noteMax = 60,
    this.party,
  });

  factory Waitlist.fromJson(Map<String, dynamic> json) {
    final quotes = [
      if (json['quotes'] is List)
        for (final minutes in json['quotes'] as List)
          if (minutes is num && minutes > 0) minutes.toInt(),
    ];
    final party = json['party'];
    return Waitlist(
      waiting: [for (final row in _rows(json['waiting'])) WaitParty.fromJson(row)],
      earlier: [for (final row in _rows(json['earlier'])) WaitParty.fromJson(row)],
      counts: json['counts'] is Map ? WaitCounts.fromJson((json['counts'] as Map).cast()) : const WaitCounts(),
      quotes: quotes.isEmpty ? standardQuotes : quotes,
      mostGuests: _i(json['most_guests'], 60),
      nameMax: _i(json['name_max'], 24),
      noteMax: _i(json['note_max'], 60),
      party: party is Map ? WaitParty.fromJson(party.cast()) : null,
    );
  }

  static const standardQuotes = [5, 10, 15, 20, 30, 45, 60, 90];

  /// The parties still waiting, in the order they came.
  final List<WaitParty> waiting;

  /// The ones that went off the list tonight, the last to go first.
  final List<WaitParty> earlier;
  final WaitCounts counts;

  /// The waits to offer as buttons, in minutes.
  final List<int> quotes;
  final int mostGuests;
  final int nameMax;
  final int noteMax;

  /// The party a change was made to, as it stands after it: only on the answer to that change.
  final WaitParty? party;

  /// The worst any waiting party stands at [nowMs]: red when one is past the time it was told.
  TimerLevel levelAt(int nowMs) {
    var worst = TimerLevel.ok;
    for (final party in waiting) {
      final level = party.levelAt(nowMs);
      if (level.index > worst.index) worst = level;
    }
    return worst;
  }

  /// The next moment after [nowMs] at which a waiting party's colour changes; null when none will.
  int? nextLevelChange(int nowMs) {
    int? next;
    for (final party in waiting) {
      for (final at in [party.amberMs, party.dueMs]) {
        if (at != null && at > nowMs && (next == null || at < next)) next = at;
      }
    }
    return next;
  }

  /// The next moment after [nowMs] at which anything shown of the waiting parties changes by the clock
  /// alone; null with nobody waiting.
  int? nextChange(int nowMs) {
    int? next;
    for (final party in waiting) {
      final at = party.nextChange(nowMs);
      if (next == null || at < next) next = at;
    }
    return next;
  }
}

/// The wait the hub suggests telling a party of [from] to [to] guests that comes now, and what it goes by
/// (`GET /waitlist/suggest`; docs/waitlist.md, "A suggested wait"). The hub works it out from how tonight's
/// parties waited; this is its answer read into names, and the words the screen says about it.
class WaitSuggestion {
  const WaitSuggestion({
    required this.from,
    required this.to,
    required this.minutes,
    int? aboutMinutes,
    this.byLongest = false,
    this.ahead = 0,
    this.eachMinutes = 1,
    this.longestMinutes,
    this.seated = 0,
    this.like = true,
  }) : aboutMinutes = aboutMinutes ?? minutes;

  factory WaitSuggestion.fromJson(Map<String, dynamic> json) => WaitSuggestion(
    from: _i(json['from'], 1),
    to: _i(json['to'], 1),
    minutes: _i(json['minutes']),
    aboutMinutes: _ms(json['about_minutes']),
    byLongest: json['by'] == 'longest',
    ahead: _i(json['ahead']),
    eachMinutes: _i(json['each_minutes'], 1),
    longestMinutes: _ms(json['longest_minutes']),
    seated: _i(json['seated']),
    like: json['like'] != false,
  );

  /// The sizes it is for.
  final int from;
  final int to;

  /// The wait to mark: one of the waits the screen offers.
  final int minutes;

  /// What it was worked out as; more than [minutes] where the wait is longer than the longest on offer.
  final int aboutMinutes;

  /// It goes by a party ahead that has already waited that long, and not by the pace of the line.
  final bool byLongest;

  /// The parties in line ahead of whoever comes now: waiting, and not yet told their table is ready.
  final int ahead;

  /// What a place in line took for the last [seated] parties that sat down.
  final int eachMinutes;

  /// The longest any party of these sizes ahead has waited; null with none of them ahead.
  final int? longestMinutes;
  final int seated;

  /// The parties counted for the pace are of these sizes; false where too few of them have sat down tonight
  /// and every size was counted, the ones [ahead] too.
  final bool like;

  bool fits(int size) => size >= from && size <= to;

  /// "30 min", or "1 h 30 or more (about 1 h 50)" past the longest wait on offer.
  String get words =>
      aboutMinutes > minutes ? '${waitWords(minutes)} or more (about ${waitWords(aboutMinutes)})' : waitWords(minutes);

  /// Why, in a sentence: "3 parties of 3 to 4 are ahead, at about 6 min a party tonight." [most] is the
  /// largest party the list takes: a band that reaches it is "7 or more".
  String why({int most = 60}) {
    final own = to >= most
        ? ' of $from or more'
        : from == to
        ? ' of $from'
        : ' of $from to $to';
    if (byLongest) return 'A party$own ahead has waited ${waitWords(longestMinutes ?? aboutMinutes)} already.';
    final sizes = like ? own : '';
    final each = waitWords(eachMinutes);
    if (ahead == 0) {
      final nobody = like ? 'No party$sizes is' : 'Nobody is';
      return '$nobody waiting ahead. Tonight the first in line sat after about $each.';
    }
    return '$ahead ${ahead == 1 ? 'party$sizes is' : 'parties$sizes are'} ahead, at about $each a party tonight.';
  }
}

/// The waits the hub suggests right now, by how many the party is. Nothing where tonight's list says too
/// little, from a hub older than the suggestion, and with no hub answering.
class WaitSuggestions {
  const WaitSuggestions(this.rows);

  factory WaitSuggestions.fromJson(Map<String, dynamic> json) => WaitSuggestions([
    for (final row in _rows(json['suggest']))
      if (row['minutes'] is num && (row['minutes'] as num) > 0) WaitSuggestion.fromJson(row),
  ]);

  static const none = WaitSuggestions([]);

  final List<WaitSuggestion> rows;

  /// The suggestion for a party of [size]; null where there is none.
  WaitSuggestion? forSize(int size) => rows.where((row) => row.fits(size)).firstOrNull;
}

/// A wait in words: "8 min", "1 h 05".
String waitWords(int minutes) =>
    minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';

/// How many guests in words: "1 guest", "4 guests".
String guestWords(int guests) => guests == 1 ? '1 guest' : '$guests guests';

/// Why a party went off the list without a table, in words.
String leftWords(String why) => why == 'no_show' ? 'No-show' : 'Left';
