/// The time clock as the hub keeps it (docs/time-clock.md): whether the location uses it
/// (`GET /settings/time_clock`), where a person stands after their PIN (`POST /timeclock/punch`), and the
/// hours a manager reads and corrects (`GET /timeclock/report`, `/timeclock/shifts`).
///
/// Every time here is the hub's: a screen never sends the time of a punch, and what a shift came to is
/// counted by the hub, so two screens never disagree about somebody's hours.
library;

/// Whether the location uses the clock, and how its hours are counted.
class ClockSetting {
  const ClockSetting({this.enabled = false, this.breaksPaid = false, this.weekStarts = 'mon'});

  factory ClockSetting.fromJson(Map<String, dynamic> json) => ClockSetting(
    enabled: json['enabled'] as bool? ?? false,
    breaksPaid: json['breaks_paid'] as bool? ?? false,
    weekStarts: json['week_starts'] == 'sun' ? 'sun' : 'mon',
  );

  /// Off until a manager turns it on: nobody is asked to clock in, and the sign-in pad shows no clock.
  final bool enabled;

  /// A break counts as time worked; off, it is taken out of the hours.
  final bool breaksPaid;

  /// The day the pay week starts on: `mon` or `sun`.
  final String weekStarts;

  ClockSetting copyWith({bool? enabled, bool? breaksPaid, String? weekStarts}) => ClockSetting(
    enabled: enabled ?? this.enabled,
    breaksPaid: breaksPaid ?? this.breaksPaid,
    weekStarts: weekStarts ?? this.weekStarts,
  );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'breaks_paid': breaksPaid, 'week_starts': weekStarts};
}

/// A break of a shift; [endMs] is null while it runs.
class ClockBreak {
  const ClockBreak({required this.startMs, this.endMs});

  factory ClockBreak.fromJson(Map<String, dynamic> json) =>
      ClockBreak(startMs: (json['start_ms'] as num).toInt(), endMs: (json['end_ms'] as num?)?.toInt());

  final int startMs;
  final int? endMs;

  Map<String, dynamic> toJson() => {'start_ms': startMs, 'end_ms': endMs};
}

/// One line of a shift's log: what happened, when the hub recorded it and who did it. A manager's change
/// carries its reason and the times before and after.
class ClockEntry {
  const ClockEntry({
    required this.action,
    required this.atMs,
    this.by = '',
    this.device = '',
    this.reason = '',
    this.before,
    this.after,
  });

  factory ClockEntry.fromJson(Map<String, dynamic> json) => ClockEntry(
    action: json['action'] as String? ?? '',
    atMs: (json['at_ms'] as num?)?.toInt() ?? 0,
    by: json['by'] as String? ?? '',
    device: json['device'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    before: (json['before'] as Map?)?.cast<String, dynamic>(),
    after: (json['after'] as Map?)?.cast<String, dynamic>(),
  );

  /// `in`, `out`, `break_start`, `break_end` by the person; `auto_out` by the hub when the night ended;
  /// `add`, `edit`, `remove` by a manager.
  final String action;
  final int atMs;
  final String by;
  final String device;
  final String reason;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  /// A manager did it, so it has a reason.
  bool get byManager => const {'add', 'edit', 'remove'}.contains(action);

  /// What the line says happened, in words.
  String get what => switch (action) {
    'in' => 'Clocked in',
    'out' => 'Clocked out',
    'break_start' => 'Started a break',
    'break_end' => 'Ended a break',
    'auto_out' => 'Closed when the night ended: nobody clocked out',
    'add' => 'Written in',
    'edit' => 'Corrected',
    'remove' => 'Taken off',
    _ => action,
  };
}

/// A shift: one stretch on the clock, with its breaks and what the hub counts it as.
class ClockShift {
  const ClockShift({
    required this.shiftId,
    required this.staffId,
    required this.name,
    required this.role,
    required this.inMs,
    this.outMs,
    this.breaks = const [],
    this.state = 'out',
    this.closedBy = '',
    this.edited = false,
    this.removed = false,
    this.unended = false,
    this.spanMs = 0,
    this.breakMs = 0,
    this.workedMs = 0,
    this.log = const [],
  });

  factory ClockShift.fromJson(Map<String, dynamic> json) => ClockShift(
    shiftId: json['shift_id'] as String? ?? '',
    staffId: json['staff_id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    role: json['role'] as String? ?? '',
    inMs: (json['in_ms'] as num?)?.toInt() ?? 0,
    outMs: (json['out_ms'] as num?)?.toInt(),
    breaks: [for (final b in json['breaks'] as List? ?? const []) ClockBreak.fromJson(b as Map<String, dynamic>)],
    state: json['state'] as String? ?? 'out',
    closedBy: json['closed_by'] as String? ?? '',
    edited: json['edited'] as bool? ?? false,
    removed: json['removed'] as bool? ?? false,
    unended: json['unended'] as bool? ?? false,
    spanMs: (json['span_ms'] as num?)?.toInt() ?? 0,
    breakMs: (json['break_ms'] as num?)?.toInt() ?? 0,
    workedMs: (json['worked_ms'] as num?)?.toInt() ?? 0,
    log: [for (final e in json['log'] as List? ?? const []) ClockEntry.fromJson(e as Map<String, dynamic>)],
  );

  final String shiftId;
  final String staffId;
  final String name;

  /// The job worked: the person's role when they clocked in.
  final String role;
  final int inMs;
  final int? outMs;
  final List<ClockBreak> breaks;

  /// `in`, `break`, `out`, or `removed` for one a manager took off.
  final String state;

  /// Who ended it: `self`, `manager`, or `system` when nobody did and the hub closed it as the night ended.
  final String closedBy;

  /// A manager wrote it in or corrected it.
  final bool edited;

  /// A manager took it off: it is kept and listed, and counts for nothing.
  final bool removed;

  /// Nobody clocked out of it and no manager has put the real time on it: its hours stop when the night
  /// ended, which is more than was worked.
  final bool unended;

  /// From the clock-in to the clock-out (or to now), what of that was breaks, and what counts as worked.
  final int spanMs;
  final int breakMs;
  final int workedMs;

  /// What happened to it, oldest first; only the report carries it.
  final List<ClockEntry> log;

  bool get open => outMs == null && !removed;

  /// A manager wrote it in for somebody who never clocked in (the report's log says so).
  bool get writtenIn => log.isNotEmpty && log.first.action == 'add';
}

/// Where a person stands at the clock, as the hub answered their PIN: who they are (in the shape a sign-in
/// answers, so the screen can go on into the POS), `out`, `in` or `break` and since when, and the shift
/// they are on or have just ended.
class ClockStand {
  const ClockStand({
    required this.staff,
    required this.state,
    required this.nowMs,
    this.sinceMs,
    this.shift,
    this.unended,
    this.punched,
    this.breaksPaid = false,
  });

  factory ClockStand.fromJson(Map<String, dynamic> json) => ClockStand(
    staff: (json['staff'] as Map?)?.cast<String, dynamic>() ?? const {},
    state: json['state'] as String? ?? 'out',
    nowMs: (json['now_ms'] as num?)?.toInt() ?? 0,
    sinceMs: (json['since_ms'] as num?)?.toInt(),
    shift: json['shift'] is Map ? ClockShift.fromJson((json['shift'] as Map).cast<String, dynamic>()) : null,
    unended: json['unended'] is Map ? ClockShift.fromJson((json['unended'] as Map).cast<String, dynamic>()) : null,
    punched: json['punched'] as String?,
    breaksPaid: json['breaks_paid'] as bool? ?? false,
  );

  /// The person, as `POST /signin` answers: `staff_id`, `name`, `role`, `method`, `preferences`.
  final Map<String, dynamic> staff;
  final String state;

  /// The hub's clock when it answered: what "so far" is counted to.
  final int nowMs;

  /// When they clocked in, or when the break they are on began; null while they are off the clock.
  final int? sinceMs;
  final ClockShift? shift;

  /// Their latest shift nobody clocked out of, which a manager has not corrected yet.
  final ClockShift? unended;

  /// What this answer did (`in`, `out`, `break_start`, `break_end`); null when it only looked.
  final String? punched;
  final bool breaksPaid;

  String get name => staff['name'] as String? ?? '';
  String get role => staff['role'] as String? ?? '';
}

/// What one person worked in the stretch a report covers.
class ClockPerson {
  const ClockPerson({
    required this.staffId,
    required this.name,
    this.role = '',
    this.workedMs = 0,
    this.breakMs = 0,
    this.shifts = 0,
    this.unended = 0,
    this.open = 0,
  });

  factory ClockPerson.fromJson(Map<String, dynamic> json) => ClockPerson(
    staffId: json['staff_id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    role: json['role'] as String? ?? '',
    workedMs: (json['worked_ms'] as num?)?.toInt() ?? 0,
    breakMs: (json['break_ms'] as num?)?.toInt() ?? 0,
    shifts: (json['shifts'] as num?)?.toInt() ?? 0,
    unended: (json['unended'] as num?)?.toInt() ?? 0,
    open: (json['open'] as num?)?.toInt() ?? 0,
  );

  final String staffId;
  final String name;
  final String role;
  final int workedMs;
  final int breakMs;
  final int shifts;

  /// How many of the shifts nobody clocked out of: their hours are too long until a manager corrects them.
  final int unended;

  /// How many are still running, counted up to now.
  final int open;
}

/// The hours for a stretch of time: who is on the clock now, what each person worked, and every shift that
/// began in it with its log.
class ClockReport {
  const ClockReport({
    this.nowMs = 0,
    this.breaksPaid = false,
    this.onNow = const [],
    this.people = const [],
    this.workedMs = 0,
    this.breakMs = 0,
    this.unended = 0,
    this.shifts = const [],
    this.enabled = true,
    this.weekStarts = 'mon',
  });

  factory ClockReport.fromJson(Map<String, dynamic> json) => ClockReport(
    nowMs: (json['now_ms'] as num?)?.toInt() ?? 0,
    breaksPaid: json['breaks_paid'] as bool? ?? false,
    onNow: [for (final s in json['on_now'] as List? ?? const []) ClockShift.fromJson(s as Map<String, dynamic>)],
    people: [for (final p in json['people'] as List? ?? const []) ClockPerson.fromJson(p as Map<String, dynamic>)],
    workedMs: (json['worked_ms'] as num?)?.toInt() ?? 0,
    breakMs: (json['break_ms'] as num?)?.toInt() ?? 0,
    unended: (json['unended'] as num?)?.toInt() ?? 0,
    shifts: [for (final s in json['shifts'] as List? ?? const []) ClockShift.fromJson(s as Map<String, dynamic>)],
    enabled: json['enabled'] as bool? ?? true,
    weekStarts: json['week_starts'] == 'sun' ? 'sun' : 'mon',
  );

  final int nowMs;
  final bool breaksPaid;
  final List<ClockShift> onNow;
  final List<ClockPerson> people;
  final int workedMs;
  final int breakMs;
  final int unended;
  final List<ClockShift> shifts;
  final bool enabled;
  final String weekStarts;

  /// The shifts with the one that began last first: what a manager looks for is usually tonight's.
  List<ClockShift> get newestFirst => [...shifts]..sort((a, b) => b.inMs.compareTo(a.inMs));
}

/// The hour the restaurant's night ends, as on the hub (`localtime.NIGHT_ENDS`): a day of the clock runs
/// from it to the next one, so a bartender closing at 1 AM is still on yesterday.
const nightEndsHour = 4;

/// The start of the clock's day [at] falls in: 4 AM that morning, or the morning before for the small hours.
DateTime clockDay(DateTime at) {
  final start = DateTime(at.year, at.month, at.day, nightEndsHour);
  return at.isBefore(start) ? DateTime(at.year, at.month, at.day - 1, nightEndsHour) : start;
}

/// The start of the pay week [at] falls in, for a week that starts on [weekStarts] (`mon` or `sun`).
DateTime clockWeek(DateTime at, String weekStarts) {
  final day = clockDay(at);
  final first = weekStarts == 'sun' ? DateTime.sunday : DateTime.monday;
  final back = (day.weekday - first) % 7;
  return DateTime(day.year, day.month, day.day - back, nightEndsHour);
}

/// A length of time as people say it: `7 h 32 min`, `45 min`. Whole minutes, the seconds dropped.
String hoursMinutes(int ms) {
  final minutes = (ms < 0 ? 0 : ms) ~/ 60000;
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The same as payroll takes it: hours with two decimals, `7.53`.
String decimalHours(int ms) => ((ms < 0 ? 0 : ms) / 3600000).toStringAsFixed(2);

/// The first moment at or after [from] whose time of day is [hour]:[minute]: where a time picked for a
/// clock-out or a break falls, for a shift that began at [from] and may run past midnight.
DateTime firstAfter(DateTime from, int hour, int minute) {
  final sameDay = DateTime(from.year, from.month, from.day, hour, minute);
  return sameDay.isBefore(from) ? DateTime(from.year, from.month, from.day + 1, hour, minute) : sameDay;
}

/// What the hub's refusal of a punch or a correction means, for the person looking at the screen.
String clockRefusal(String code, {String? message}) => switch (code) {
  'off' => 'The time clock is off at this location.',
  'already_in' => message ?? 'Already on the clock.',
  'not_in' => message ?? 'Not on the clock.',
  'on_break' => message ?? 'Already on a break.',
  'not_on_break' => message ?? 'Not on a break.',
  'reason_needed' => 'Say why: the log keeps the reason.',
  'no_change' => 'Nothing was changed.',
  'read_only' => 'This hub is standing by and cannot write. Try again in a moment.',
  _ => message ?? code,
};
