/// The countdown on each table of the floor map: what a table is waiting on and since when (the hub reads
/// both from the order log), the location's times for each stage, and how the two make a ring at a moment.
library;

/// What an open check is waiting on, and since when, as the hub read it from the check's own history.
class TableTimer {
  const TableTimer({required this.stage, required this.sinceMs});

  /// Null for a hub that sends none (one older than the timers) or an answer this build cannot read.
  static TableTimer? fromJson(Object? json) {
    if (json is! Map) return null;
    final stage = json['stage'], since = json['since_ms'];
    return stage is String && since is num ? TableTimer(stage: stage, sinceMs: since.toInt()) : null;
  }

  /// `sat` (nothing ordered yet), `unsent` (dishes on the check the kitchen was not sent), `held` (a course
  /// waits its turn) or `fired` (everything was sent).
  final String stage;

  /// Wall-clock ms the wait started at, from the stamps in the order log.
  final int sinceMs;

  @override
  bool operator ==(Object other) => other is TableTimer && other.stage == stage && other.sinceMs == sinceMs;

  @override
  int get hashCode => Object.hash(stage, sinceMs);
}

/// How a countdown stands: running, running out (amber), or time is up (red).
enum TimerLevel { ok, warn, late }

/// The minutes one stage is given: [warn] until its ring turns amber, [late] until its time is up. 0 turns
/// that one off; with both off the stage is not timed.
class StageTimes {
  const StageTimes({this.warn = 0, this.late = 0});

  factory StageTimes.fromJson(Map<String, dynamic> json) =>
      StageTimes(warn: (json['warn'] as num? ?? 0).toInt(), late: (json['late'] as num? ?? 0).toInt());

  final int warn;
  final int late;

  bool get timed => warn > 0 || late > 0;

  /// The minutes the ring counts down: to time up, or to the amber nudge for a stage that never runs out.
  int get span => late > 0 ? late : warn;

  Map<String, dynamic> toJson() => {'warn': warn, 'late': late};

  @override
  bool operator ==(Object other) => other is StageTimes && other.warn == warn && other.late == late;

  @override
  int get hashCode => Object.hash(warn, late);
}

/// The stages a table can be waiting on, in the order a meal goes through them.
const timerStages = ['sat', 'unsent', 'held', 'fired'];

/// What a stage is called on the screen.
String timerStageLabel(String stage) => switch (stage) {
  'sat' => 'Seated, nothing ordered',
  'unsent' => 'Dishes not sent',
  'held' => 'Course held',
  'fired' => 'Everything sent',
  _ => stage,
};

/// The location's table timers (`GET /settings/table_timers`, and on `GET /floor`): whether the rings are
/// drawn, and the times of each stage.
class TableTimers {
  const TableTimers({this.enabled = true, this.stages = standard});

  factory TableTimers.fromJson(Map<String, dynamic> json) => TableTimers(
    enabled: json['enabled'] as bool? ?? true,
    stages: {
      ...standard,
      for (final e in (json['stages'] as Map? ?? const {}).entries)
        if (e.value is Map) e.key as String: StageTimes.fromJson((e.value as Map).cast<String, dynamic>()),
    },
  );

  /// What the hub starts a location with.
  static const standard = {
    'sat': StageTimes(warn: 5, late: 10),
    'unsent': StageTimes(warn: 5, late: 10),
    'held': StageTimes(warn: 15, late: 25),
    'fired': StageTimes(warn: 25),
  };

  /// No rings: what a hub older than the timers amounts to.
  static const off = TableTimers(enabled: false);

  final bool enabled;
  final Map<String, StageTimes> stages;

  StageTimes timesFor(String stage) => stages[stage] ?? const StageTimes();

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'stages': {for (final stage in timerStages) stage: timesFor(stage).toJson()},
  };

  /// Where [timer] stands at [nowMs], or null when its stage is not timed (or the rings are off).
  Countdown? countdown(TableTimer? timer, int nowMs) {
    if (!enabled || timer == null) return null;
    final times = timesFor(timer.stage);
    if (!times.timed) return null;
    final elapsed = nowMs > timer.sinceMs ? nowMs - timer.sinceMs : 0;
    final span = times.span * 60000;
    final level = times.late > 0 && elapsed >= times.late * 60000
        ? TimerLevel.late
        : times.warn > 0 && elapsed >= times.warn * 60000
        ? TimerLevel.warn
        : TimerLevel.ok;
    return Countdown(
      stage: timer.stage,
      level: level,
      left: elapsed >= span ? 0 : 1 - elapsed / span,
      // Minutes left round up (59 seconds to go is still "1m"), minutes over round down.
      minutes: elapsed >= span ? (elapsed - span) ~/ 60000 : (span - elapsed + 59999) ~/ 60000,
      elapsedMinutes: elapsed ~/ 60000,
    );
  }

  /// The countdown that most needs a look among several checks on one table: the highest level, then the
  /// one with the least time left.
  Countdown? mostUrgent(Iterable<TableTimer?> timers, int nowMs) {
    Countdown? worst;
    for (final timer in timers) {
      final here = countdown(timer, nowMs);
      if (here != null && (worst == null || here.moreUrgentThan(worst))) worst = here;
    }
    return worst;
  }
}

/// A table's countdown at one moment.
class Countdown {
  const Countdown({
    required this.stage,
    required this.level,
    required this.left,
    required this.minutes,
    required this.elapsedMinutes,
  });

  final String stage;
  final TimerLevel level;

  /// How much of the ring is left: 1 as the wait starts, 0 when time is up.
  final double left;

  /// Whole minutes left while [left] is above 0, whole minutes over once it is not.
  final int minutes;

  /// Whole minutes the table has waited on this stage.
  final int elapsedMinutes;

  /// Time ran out: the ring is drawn whole again, amber for a nudge, red (and flashing) for overdue.
  bool get isUp => left <= 0;

  /// What the badge on the table says: "3m" to go, "0m" as time runs out, "+2m" over.
  String get short => isUp && minutes > 0 ? '+${minutes}m' : '${minutes}m';

  bool moreUrgentThan(Countdown other) =>
      level.index > other.level.index ||
      (level.index == other.level.index &&
          (left < other.left || (left == other.left && isUp && minutes > other.minutes)));
}
