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

/// One party on the list.
class WaitParty {
  const WaitParty({
    required this.id,
    required this.name,
    required this.size,
    this.phone = '',
    this.quotedMinutes,
    this.note = '',
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

  final String id;
  final String name;

  /// How many guests.
  final int size;
  final String phone;

  /// The wait they were told, counted from when they came; null when no time was given.
  final int? quotedMinutes;
  final String note;

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

/// A wait in words: "8 min", "1 h 05".
String waitWords(int minutes) =>
    minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';

/// How many guests in words: "1 guest", "4 guests".
String guestWords(int guests) => guests == 1 ? '1 guest' : '$guests guests';

/// Why a party went off the list without a table, in words.
String leftWords(String why) => why == 'no_show' ? 'No-show' : 'Left';
